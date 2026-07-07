#!/system/bin/sh

# Hrezygisk metamodule mount handler.
#
# Runs at the end of the post-fs-data stage (after all post-fs-data.sh scripts)
# and mounts every enabled module's system/ tree systemlessly.
#
# Only KernelSU and APatch drive the metamodule hooks; on Magisk this file is
# never invoked (Magisk ignores metamodule=1 in module.prop), so Hrezygisk
# falls back to being a regular module there.
#
# Three mount backends are supported (inspired by mountify):
#
#   tmpfs — stage module contents onto a tmpfs-backed /mnt/vendor/<fake_name>,
#           then overlay each partition using the tmpfs path as upperdir. No
#           files are created on /data's ext4/f2fs filesystem, making the mount
#           harder to detect via /proc/fs ext4 node scans.
#
#   ext4  — create a loop-mounted ext4 image at /data/adb/rezygisk/.rw/<name>.img
#           and mount it at /mnt/vendor/<fake_name>, then use it as upperdir.
#           This mimics how older KernelSU versions mounted modules. Creates
#           detectable ext4 device nodes on /proc/fs, but works when tmpfs is
#           unavailable and /data is not suitable for direct overlay.
#
#   direct — overlay upperdir/workdir live directly on /data (ext4/f2fs).
#            Simplest and most compatible, but the upperdir path is on a
#            detectable filesystem.
#
# Mode selection: if mount_mode=auto (default), the script probes tmpfs → ext4
# → direct in order and uses the first that works. A concrete mode is tried
# first; on failure it falls through to the remaining modes in the same order.
#
# The overlay source is set to "KSU" or "APatch" so that zygiskd's umount_root()
# can identify and detach these mounts for denylist apps (the source-name match
# in utils.c). This closes the mount/hide-mount loop entirely inside Hrezygisk.
#
# Robustness policy: a single failed mount must NEVER abort the script — a
# bootloop here would be catastrophic. Failures are logged and skipped.

MODDIR=${0%/*}

LOGFILE=/data/adb/rezygisk/.rz_meta.log
CFG=/data/adb/rezygisk/.rz_meta_cfg
RW_BASE=/data/adb/rezygisk/.rw
EXT4_IMG_SIZE_MB=256

# INFO: Best-effort logging. Never fail the script because of logging issues.
_meta_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null
}

# INFO: Detect which root implementation is driving us and pick the matching
# overlay source name. umount_root() matches mounts by this source name, so it
# MUST match what zygiskd expects ("KSU" for KernelSU, "APatch" for APatch).
if [ -x /data/adb/ksu/bin/busybox ]; then
  SOURCE=KSU
elif [ -x /data/adb/ap/bin/busybox ]; then
  SOURCE=APatch
else
  # Not running under KernelSU or APatch. The metamodule hooks should not have
  # been invoked in that case, but bail out silently just in case.
  exit 0
fi

# INFO: Read user configuration. Format (sourced):
#   enabled=true|false          (default: true)
#   mount_mode=tmpfs|ext4|direct|auto  (default: auto)
#   fake_mount_name=rezygisk    (default: rezygisk; used by tmpfs/ext4)
#   ext4_img_size_mb=256        (default: 256; size of ext4 image in MB)
#   skip_modules="id1 id2 id3"  (default: empty)
# Missing file => defaults.
ENABLED=true
MOUNT_MODE=auto
FAKE_MOUNT_NAME=rezygisk
EXT4_IMG_SIZE_MB=256
SKIP_MODULES=""
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi

# INFO: If the user disabled metamount via config, do nothing.
if [ "$ENABLED" != "true" ]; then
  _meta_log "metamount disabled by config (enabled=$ENABLED), exiting"
  exit 0
fi

_meta_log "metamount start: SOURCE=$SOURCE mode=$MOUNT_MODE fake_name=$FAKE_MOUNT_NAME skip=[$SKIP_MODULES]"

# INFO: Decide whether a module directory should be mounted. Returns 0 to
# mount, 1 to skip. A module is skipped if it is disabled, marked skip_mount,
# pending removal, explicitly excluded via .rz_meta_cfg, or has no system/ dir.
_should_mount_module() {
  mod="$1"
  [ -d "$mod" ] || return 1
  [ -d "$mod/system" ] || return 1
  [ -f "$mod/disable" ] && return 1
  [ -f "$mod/skip_mount" ] && return 1
  [ -f "$mod/remove" ] && return 1

  modid=$(basename "$mod")
  case " $SKIP_MODULES " in
    *" $modid "*) return 1;;
  esac

  return 0
}

# INFO: Collect the set of partitions that need an overlay. We scan every
# mountable module's system/ directory and union the top-level entry names
# (e.g. system, vendor, product, system_ext, odm, ...). Only partitions that
# actually exist on the device get mounted later.
PARTITIONS=""
for mod in /data/adb/modules/*; do
  _should_mount_module "$mod" || continue
  for entry in "$mod"/system/*; do
    [ -e "$entry" ] || continue
    pname=$(basename "$entry")
    case " $PARTITIONS " in
      *" $pname "*) ;;
      *) PARTITIONS="$PARTITIONS $pname";;
    esac
  done
done

_meta_log "partitions discovered:[$PARTITIONS]"

# INFO: Try to set up a tmpfs staging area. On success sets STAGE and returns 0.
# tmpfs is the stealthiest option — nothing touches /data's persistent fs.
_try_setup_tmpfs() {
  STAGE="/mnt/vendor/$FAKE_MOUNT_NAME"
  mkdir -p "$STAGE" 2>/dev/null || return 1
  if mount -t tmpfs tmpfs "$STAGE" 2>/dev/null; then
    return 0
  fi
  return 1
}

# INFO: Try to set up an ext4-image staging area. Creates (once) a fixed-size
# ext4 image at $RW_BASE/<name>.img, loop-mounts it at /mnt/vendor/<name>.
# Requires mke2fs (Android 8+ ships it at /system/bin/mke2fs) and loop mount
# support. On success sets STAGE and returns 0.
_try_setup_ext4() {
  local img mnt mke2fs_bin
  img="$RW_BASE/$FAKE_MOUNT_NAME.img"
  mnt="/mnt/vendor/$FAKE_MOUNT_NAME"

  # Locate an ext4 formatter: prefer system mke2fs, then busybox.
  mke2fs_bin=""
  for p in /system/bin/mke2fs /system/xbin/mke2fs /data/adb/ksu/bin/mke2fs /data/adb/ap/bin/mke2fs; do
    [ -x "$p" ] && mke2fs_bin="$p" && break
  done
  [ -z "$mke2fs_bin" ] && return 1

  mkdir -p "$RW_BASE" 2>/dev/null
  mkdir -p "$mnt" 2>/dev/null || return 1

  # Create the image once. On subsequent boots reuse it (its contents are wiped
  # and rebuilt every boot, but the image file itself is persistent to avoid
  # the slow mke2fs call on every boot).
  if [ ! -f "$img" ]; then
    _meta_log "ext4: creating image $img (${EXT4_IMG_SIZE_MB}MB)"
    if ! dd if=/dev/zero of="$img" bs=1M count="$EXT4_IMG_SIZE_MB" 2>/dev/null; then
      _meta_log "ext4: dd failed"
      return 1
    fi
    if ! "$mke2fs_bin" -t ext4 -F "$img" >/dev/null 2>&1; then
      _meta_log "ext4: mke2fs failed"
      rm -f "$img" 2>/dev/null
      return 1
    fi
  fi

  if ! mount -t ext4 -o loop "$img" "$mnt" 2>/dev/null; then
    _meta_log "ext4: loop mount failed"
    return 1
  fi

  STAGE="$mnt"
  return 0
}

# INFO: Probe mount backends in priority order and pick the first that works.
# The user-configured mode is tried first; on failure we fall through to the
# remaining modes. "auto" tries all three in tmpfs → ext4 → direct order.
# direct always succeeds (it uses /data which is guaranteed mounted), so this
# function never fails — worst case it degrades to direct mode.
# Sets: MOUNT_MODE (the actually-selected mode), STAGE (path or empty).
_probe_mount_mode() {
  local first rest order mode
  case "$MOUNT_MODE" in
    tmpfs)  order="tmpfs ext4 direct";;
    ext4)   order="ext4 tmpfs direct";;
    direct) order="direct";;
    *)      order="tmpfs ext4 direct";;  # auto or anything unknown
  esac

  STAGE=""
  for mode in $order; do
    case "$mode" in
      tmpfs)
        if _try_setup_tmpfs; then
          MOUNT_MODE=tmpfs
          _meta_log "probe: selected tmpfs mode (stage=$STAGE)"
          return 0
        fi
        _meta_log "probe: tmpfs unavailable"
        ;;
      ext4)
        if _try_setup_ext4; then
          MOUNT_MODE=ext4
          _meta_log "probe: selected ext4 mode (stage=$STAGE)"
          return 0
        fi
        _meta_log "probe: ext4 unavailable"
        ;;
      direct)
        MOUNT_MODE=direct
        STAGE=""
        _meta_log "probe: selected direct mode"
        return 0
        ;;
    esac
  done

  # Should be unreachable because direct always succeeds, but be safe.
  MOUNT_MODE=direct
  STAGE=""
  _meta_log "probe: fallback to direct mode (should not reach here)"
  return 0
}

_probe_mount_mode

# INFO: For each partition: merge every module's contribution into a single
# upperdir, then mount one overlay over the live partition. Later modules
# (alphabetical order) overwrite earlier ones on conflict — this matches the
# "last installed wins" expectation users have from Magisk/KSU.
for P in $PARTITIONS; do
  lower="/$P"
  if [ ! -d "$lower" ]; then
    _meta_log "skip $P: $lower is not a directory"
    continue
  fi

  # INFO: In direct mode the upperdir/workdir live on /data. In tmpfs/ext4 mode
  # they live inside the staging area (which is a fresh tmpfs or a wiped ext4
  # image). workdir MUST be on the same filesystem as upperdir for overlayfs.
  if [ "$MOUNT_MODE" = "direct" ] || [ -z "$STAGE" ]; then
    upper="$RW_BASE/$P/upper"
    work="$RW_BASE/$P/work"
  else
    upper="$STAGE/$P"
    work="$STAGE/.work/$P"
  fi

  mkdir -p "$upper" "$work" 2>/dev/null || {
    _meta_log "FAIL $P: cannot create upper/work dir"
    continue
  }

  # INFO: Wipe the upperdir so a previous boot's stale contents (e.g. a module
  # that has since been removed) don't linger. upperdir is rebuilt from scratch
  # every boot from the current module set. In tmpfs mode the staging area is
  # already empty (fresh tmpfs mount), so this is a fast no-op there.
  rm -rf "$upper"/* 2>/dev/null

  for mod in /data/adb/modules/*; do
    _should_mount_module "$mod" || continue
    src="$mod/system/$P"
    [ -d "$src" ] || continue
    # INFO: cp -a preserves ownership, mode, selinux context and directory
    # structure. "src/." copies contents rather than the dir itself.
    if ! cp -a "$src/." "$upper/" 2>/dev/null; then
      _meta_log "warn: merge failed for $src into $upper"
    fi
  done

  # INFO: The device argument ("$SOURCE") becomes the mount source recorded in
  # /proc/self/mountinfo. umount_root() matches on this exact string.
  if mount -t overlay -o "lowerdir=$lower,upperdir=$upper,workdir=$work" "$SOURCE" "$lower" 2>/dev/null; then
    _meta_log "mounted overlay on $lower (source=$SOURCE mode=$MOUNT_MODE upper=$upper)"
  else
    # INFO: Overlay mount can fail if the kernel rejects stacking an overlay on
    # top of certain filesystems, or if the partition is already an overlay.
    # Log and continue — do not abort.
    _meta_log "FAIL $P: mount -t overlay returned $?"
  fi
done

_meta_log "metamount done"
exit 0
