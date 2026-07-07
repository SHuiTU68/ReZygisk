#!/system/bin/sh

# Hrezygisk metamodule mount handler.
#
# Runs at the end of the post-fs-data stage (after all post-fs-data.sh scripts)
# and mounts every enabled module's system/ tree systemlessly via overlayfs.
#
# Only KernelSU and APatch drive the metamodule hooks; on Magisk this file is
# never invoked (Magisk ignores metamodule=1 in module.prop), so Hrezygisk
# falls back to being a regular module there.
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
#   skip_modules="id1 id2 id3"
# Missing file => no exclusions.
SKIP_MODULES=""
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi

_meta_log "metamount start: SOURCE=$SOURCE skip_modules=[$SKIP_MODULES]"

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

  upper="$RW_BASE/$P/upper"
  work="$RW_BASE/$P/work"
  mkdir -p "$upper" "$work" 2>/dev/null || {
    _meta_log "FAIL $P: cannot create upper/work dir"
    continue
  }

  # INFO: Wipe the upperdir so a previous boot's stale contents (e.g. a module
  # that has since been removed) don't linger. upperdir is rebuilt from scratch
  # every boot from the current module set.
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
    _meta_log "mounted overlay on $lower (source=$SOURCE)"
  else
    # INFO: Overlay mount can fail if the kernel rejects stacking an overlay on
    # top of certain filesystems, or if the partition is already an overlay.
    # Log and continue — do not abort.
    _meta_log "FAIL $P: mount -t overlay returned $?"
  fi
done

_meta_log "metamount done"
exit 0
