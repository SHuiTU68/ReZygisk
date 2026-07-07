#!/system/bin/sh

# Hrezygisk metamodule mount handler.
#
# SAFETY: This script runs at post-fs-data and handles mounting system
# partitions. A bug here can cause bootloops or data loss. Every path
# operation is guarded by non-empty / absolute-path checks. A single failed
# mount NEVER aborts the script — failures are logged and skipped.
#
# Only KernelSU and APatch drive the metamodule hooks; on Magisk this file is
# never invoked (Magisk ignores metamodule=1 in module.prop).
#
# Three mount backends (inspired by mountify):
#   tmpfs — stage on /mnt/vendor/<name> tmpfs, hardest to detect
#   ext4  — loop-mounted ext4 image at /data/adb/rezygisk/.rw/<name>.img
#   direct — upperdir on /data, simplest, always available
#
# Mode auto (default) probes tmpfs → ext4 → direct, picks first that works.
#
# The overlay source is set to "KSU" or "APatch" so zygiskd's umount_root() can
# identify and detach these mounts for denylist apps.

MODDIR=${0%/*}

LOGFILE=/data/adb/rezygisk/.rz_meta.log
CFG=/data/adb/rezygisk/.rz_meta_cfg
RW_BASE=/data/adb/rezygisk/.rw
EXT4_IMG_SIZE_MB=256

_meta_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null
}

if [ -x /data/adb/ksu/bin/busybox ]; then
  SOURCE=KSU
elif [ -x /data/adb/ap/bin/busybox ]; then
  SOURCE=APatch
else
  exit 0
fi

# INFO: Read user configuration. DEFAULT: enabled=false for safety.
# User must explicitly enable via WebUI or install-time prompt.
ENABLED=false
MOUNT_MODE=auto
FAKE_MOUNT_NAME=rezygisk
EXT4_IMG_SIZE_MB=256
SKIP_MODULES=""
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi

if [ "$ENABLED" != "true" ]; then
  _meta_log "metamount disabled by config (enabled=$ENABLED), exiting"
  exit 0
fi

_meta_log "metamount start: SOURCE=$SOURCE mode=$MOUNT_MODE fake_name=$FAKE_MOUNT_NAME skip=[$SKIP_MODULES]"

# SAFETY: Sanitize FAKE_MOUNT_NAME — only allow alphanumerics + underscore.
# This prevents path injection into staging paths.
case "$FAKE_MOUNT_NAME" in
  *[!A-Za-z0-9_]*) FAKE_MOUNT_NAME=rezygisk;;
esac
[ -z "$FAKE_MOUNT_NAME" ] && FAKE_MOUNT_NAME=rezygisk

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

# INFO: Collect partitions to overlay. Only top-level entries under system/.
#
# SAFETY: The "system" partition is EXCLUDED by default. Overlaying /system at
# post-fs-data breaks system_server/zygote startup — the overlay upperdir may
# not be fully visible to all processes at that early stage, causing missing
# framework JARs → black screen → hot reboot loop. This was the root cause of
# the bootloop users experienced. Only vendor/product/system_ext/odm and other
# non-critical partitions are safe to overlay here.
# The user can override this via allow_system=true in .rz_meta_cfg, but this is
# strongly discouraged and logged as a warning.
ALLOW_SYSTEM=false
if [ -f "$CFG" ]; then
  # re-read just this flag (already sourced above, but be explicit)
  grep -q '^allow_system=true' "$CFG" 2>/dev/null && ALLOW_SYSTEM=true
fi

# SAFETY: DANGEROUS_PARTITIONS contains partitions that are known to cause
# bootloops when overlaid at post-fs-data. "system" is the primary offender.
DANGEROUS_PARTITIONS="system"

PARTITIONS=""
for mod in /data/adb/modules/*; do
  _should_mount_module "$mod" || continue
  for entry in "$mod"/system/*; do
    [ -e "$entry" ] || continue
    pname=$(basename "$entry")
    # SAFETY: partition name must be a simple identifier (no .., no /, no empty)
    case "$pname" in
      ""|*..*|*/*) continue;;
    esac
    # SAFETY: skip dangerous partitions unless explicitly allowed
    if [ "$ALLOW_SYSTEM" != "true" ]; then
      case " $DANGEROUS_PARTITIONS " in
        *" $pname "*)
          _meta_log "skip dangerous partition: $pname (set allow_system=true to override)"
          continue
          ;;
      esac
    else
      _meta_log "WARNING: mounting dangerous partition $pname (user override)"
    fi
    case " $PARTITIONS " in
      *" $pname "*) ;;
      *) PARTITIONS="$PARTITIONS $pname";;
    esac
  done
done

_meta_log "partitions discovered:[$PARTITIONS]"

# SAFETY: If no partitions, nothing to do. Avoid any mount operations.
[ -z "$PARTITIONS" ] && { _meta_log "no partitions to mount, exiting"; exit 0; }

_try_setup_tmpfs() {
  STAGE="/mnt/vendor/$FAKE_MOUNT_NAME"
  # SAFETY: STAGE must be under /mnt/vendor/ and non-empty
  [ -n "$STAGE" ] || return 1
  case "$STAGE" in
    /mnt/vendor/*) ;;
    *) return 1;;
  esac
  mkdir -p "$STAGE" 2>/dev/null || return 1
  if mount -t tmpfs tmpfs "$STAGE" 2>/dev/null; then
    return 0
  fi
  return 1
}

_try_setup_ext4() {
  local img mnt mke2fs_bin
  img="$RW_BASE/$FAKE_MOUNT_NAME.img"
  mnt="/mnt/vendor/$FAKE_MOUNT_NAME"

  # SAFETY: validate paths are absolute and non-empty
  [ -n "$img" ] && [ -n "$mnt" ] || return 1
  case "$img" in /data/adb/rezygisk/.rw/*) ;; *) return 1;; esac
  case "$mnt" in /mnt/vendor/*) ;; *) return 1;; esac

  mke2fs_bin=""
  for p in /system/bin/mke2fs /system/xbin/mke2fs /data/adb/ksu/bin/mke2fs /data/adb/ap/bin/mke2fs; do
    [ -x "$p" ] && mke2fs_bin="$p" && break
  done
  [ -z "$mke2fs_bin" ] && return 1

  mkdir -p "$RW_BASE" 2>/dev/null
  mkdir -p "$mnt" 2>/dev/null || return 1

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

_probe_mount_mode() {
  local order mode
  case "$MOUNT_MODE" in
    tmpfs)  order="tmpfs ext4 direct";;
    ext4)   order="ext4 tmpfs direct";;
    direct) order="direct";;
    *)      order="tmpfs ext4 direct";;
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

  MOUNT_MODE=direct
  STAGE=""
  return 0
}

_probe_mount_mode

# INFO: For each partition, merge modules into upperdir and overlay mount.
for P in $PARTITIONS; do
  lower="/$P"

  # SAFETY: partition must be a simple name, no path traversal
  case "$P" in
    ""|*..*|*/*) _meta_log "skip unsafe partition name: [$P]"; continue;;
  esac
  [ -d "$lower" ] || { _meta_log "skip $P: $lower not a dir"; continue; }

  if [ "$MOUNT_MODE" = "direct" ] || [ -z "$STAGE" ]; then
    upper="$RW_BASE/$P/upper"
    work="$RW_BASE/$P/work"
  else
    upper="$STAGE/$P"
    work="$STAGE/.work/$P"
  fi

  # SAFETY: upper/work MUST be non-empty absolute paths before any operation.
  # An empty $upper here would turn "rm -rf $upper/*" into "rm -rf /*" which
  # would destroy the filesystem. This is the critical safety guard.
  if [ -z "$upper" ] || [ -z "$work" ]; then
    _meta_log "FAIL $P: empty upper or work path, skipping"
    continue
  fi
  case "$upper" in
    /*) ;;
    *) _meta_log "FAIL $P: upper not absolute: $upper"; continue;;
  esac
  case "$work" in
    /*) ;;
    *) _meta_log "FAIL $P: work not absolute: $work"; continue;;
  esac

  mkdir -p "$upper" "$work" 2>/dev/null || {
    _meta_log "FAIL $P: cannot create upper/work dir"
    continue
  }

  # SAFETY: Only wipe upper if it's a real non-root absolute path with content.
  # Double-check the path resolves under RW_BASE or STAGE before rm.
  case "$upper" in
    "$RW_BASE"/*|"$STAGE"/*)
      if [ -n "$upper" ] && [ "$upper" != "/" ]; then
        rm -rf "$upper"/* 2>/dev/null
      fi
      ;;
    *)
      _meta_log "FAIL $P: upper outside allowed prefix: $upper"
      continue
      ;;
  esac

  for mod in /data/adb/modules/*; do
    _should_mount_module "$mod" || continue
    src="$mod/system/$P"
    [ -d "$src" ] || continue
    if ! cp -a "$src/." "$upper/" 2>/dev/null; then
      _meta_log "warn: merge failed for $src into $upper"
    fi
  done

  if mount -t overlay -o "lowerdir=$lower,upperdir=$upper,workdir=$work" "$SOURCE" "$lower" 2>/dev/null; then
    _meta_log "mounted overlay on $lower (source=$SOURCE mode=$MOUNT_MODE upper=$upper)"
  else
    _meta_log "FAIL $P: mount -t overlay returned $?"
  fi
done

_meta_log "metamount done"
exit 0
