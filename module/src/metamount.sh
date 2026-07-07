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
# ROLE: As the active metamodule (module.prop metamodule=1), Hrezygisk
# REPLACES the root implementation's own module mounting. KSU/APatch do NOT
# overlay system partitions themselves when a metamodule is active — that is
# this script's job. So we must NOT skip partitions that happen to already be
# overlays (those are from earlier boot stages, not from KSU module mounting).
#
# WHITELIST MODEL: By default NO module is mounted. The user must explicitly
# add a module id to include_modules in .rz_meta_cfg (via WebUI) for it to be
# overlaid. This is safer than a blacklist and matches the WebUI "select which
# modules to mount" UX.
#
# SAFETY: Critical Android partitions (system, vendor, product, system_ext,
# odm, ...) are in DANGEROUS_PARTITIONS and excluded by default. The user must
# explicitly allow each partition via allow_partitions= to overlay it. This is
# the primary bootloop prevention — overlaying /system at post-fs-data can
# break system_server/zygote if the upperdir is not fully visible to all
# processes at that early stage.
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
# INFO: Runtime status file. Written AFTER probe so the WebUI/home page can
# show the ACTUAL effective mode (e.g. "auto" resolved to "ext4"). This is
# distinct from CFG (user intent) — STATUS reflects what really happened.
STATUS=/data/adb/rezygisk/.rz_meta_status
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
INCLUDE_MODULES=""
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi

if [ "$ENABLED" != "true" ]; then
  _meta_log "metamount disabled by config (enabled=$ENABLED), exiting"
  exit 0
fi

_meta_log "metamount start: SOURCE=$SOURCE mode=$MOUNT_MODE fake_name=$FAKE_MOUNT_NAME include=[$INCLUDE_MODULES]"

# SAFETY: Sanitize FAKE_MOUNT_NAME — only allow alphanumerics + underscore.
# This prevents path injection into staging paths.
case "$FAKE_MOUNT_NAME" in
  *[!A-Za-z0-9_]*) FAKE_MOUNT_NAME=rezygisk;;
esac
[ -z "$FAKE_MOUNT_NAME" ] && FAKE_MOUNT_NAME=rezygisk

# INFO: Whitelist check. A module is mounted ONLY if its id is in
# INCLUDE_MODULES. Default empty = no modules mounted (safest). This is the
# inverse of the old skip_modules blacklist.
_should_mount_module() {
  mod="$1"
  [ -d "$mod" ] || return 1
  [ -d "$mod/system" ] || return 1
  [ -f "$mod/disable" ] && return 1
  [ -f "$mod/skip_mount" ] && return 1
  [ -f "$mod/remove" ] && return 1

  modid=$(basename "$mod")
  # Whitelist: only mount if explicitly included
  case " $INCLUDE_MODULES " in
    *" $modid "*) return 0;;
  esac
  return 1
}

# INFO: allow_partitions is a comma-separated (or space-separated) list of
# partitions the user has explicitly allowed to be overlaid despite being in
# DANGEROUS_PARTITIONS. Default empty = no dangerous partitions are overlaid.
#
# For backward compatibility, allow_system=true is treated as
# allow_partitions=system.
ALLOW_PARTITIONS=""
if [ -f "$CFG" ]; then
  _ap=$(grep '^allow_partitions=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr ',' ' ')
  if [ -n "$_ap" ]; then
    ALLOW_PARTITIONS="$_ap"
  fi
  # Legacy: allow_system=true => allow system partition
  if grep -q '^allow_system=true' "$CFG" 2>/dev/null; then
    case " $ALLOW_PARTITIONS " in
      *" system "*) ;;
      *) ALLOW_PARTITIONS="$ALLOW_PARTITIONS system";;
    esac
  fi
fi
_meta_log "allow_partitions=[$ALLOW_PARTITIONS]"

# SAFETY: DANGEROUS_PARTITIONS contains ALL critical Android system partitions
# that are known to cause bootloops when overlaid at post-fs-data. Overlaying
# any of these can break system_server, zygote, surfaceflinger, vold, or
# SystemUI, causing black screen → hot reboot → bootloop.
DANGEROUS_PARTITIONS="system vendor product system_ext odm vendor_dlkm system_dlkm miui oppo my_preload my_region my_product my_stock my_engineering"

# INFO: Check if a partition name is in the allow list.
_is_partition_allowed() {
  _pn="$1"
  case " $ALLOW_PARTITIONS " in
    *" $_pn "*) return 0;;
    *) return 1;;
  esac
}

# INFO: Collect partitions to overlay. Only top-level entries under system/.
# Only partitions referenced by whitelisted modules are considered.
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

    # SAFETY: Skip dangerous partitions unless explicitly allowed by user.
    _is_dangerous=false
    case " $DANGEROUS_PARTITIONS " in
      *" $pname "*) _is_dangerous=true;;
    esac
    if [ "$_is_dangerous" = "true" ]; then
      if ! _is_partition_allowed "$pname"; then
        _meta_log "skip dangerous partition: $pname (add to allow_partitions to override)"
        continue
      fi
      _meta_log "WARNING: mounting dangerous partition $pname (user explicitly allowed)"
    fi

    case " $PARTITIONS " in
      *" $pname "*) ;;
      *) PARTITIONS="$PARTITIONS $pname";;
    esac
  done
done

_meta_log "partitions discovered:[$PARTITIONS]"

# SAFETY: If no partitions, nothing to do. Avoid any mount operations.
[ -z "$PARTITIONS" ] && { _meta_log "no partitions to mount (no whitelisted modules or all partitions excluded), exiting"; exit 0; }

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

  # INFO: Create a SPARSE image instead of writing 256MB of zeros.
  # `dd seek=` (or truncate) creates a sparse file: the filesystem reports
  # 256MB logical size but allocates blocks lazily as they are written. This
  # avoids writing 256MB of zeros upfront → far less flash wear, and faster
  # creation. mke2fs with sparse_super + uninit_bg keeps the on-disk metadata
  # sparse-friendly too.
  if [ ! -f "$img" ]; then
    _meta_log "ext4: creating sparse image $img (${EXT4_IMG_SIZE_MB}MB)"
    # Create sparse file: bs=1 count=0 seek=N grows it logically without
    # writing any data blocks. Equivalent to `truncate -s` but more portable.
    if ! dd if=/dev/null of="$img" bs=1M count=0 seek="$EXT4_IMG_SIZE_MB" 2>/dev/null; then
      _meta_log "ext4: sparse dd failed"
      return 1
    fi
    # INFO: Format with ext4 optimizations to reduce write amplification:
    #   -O sparse_super      fewer superblock backups → less metadata writes
    #   -O uninit_bg         uninitialized block groups → no zeroing needed
    #   -O extent            extent-based blocks → better locality, less fragmentation
    #   -O dir_index         htree directory indexing → faster lookups
    #   -O large_file         support large files
    #   -O huge_file          allow very large files
    #   -O dir_nlink          unlimited subdirectory links
    #   -O extra_isize        larger inodes for future features
    #   -E lazy_itable_init   lazy inode table init → less upfront writes
    #   -E lazy_journal_init  lazy journal init → less upfront writes
    #   -b 4096               4K block size (matches typical flash page size)
    #   -T largefile          fewer inodes, larger blocks (modules have few
    #                         large files, not many small ones)
    #   -m 0                  no reserved blocks (this is not a root fs)
    #   -J size=4             small 4MB journal (data is recreatable)
    if ! "$mke2fs_bin" -t ext4 -F -b 4096 -T largefile -m 0 -J size=4 \
      -O sparse_super,uninit_bg,extent,dir_index,large_file,huge_file,dir_nlink,extra_isize \
      -E lazy_itable_init,lazy_journal_init \
      "$img" >/dev/null 2>&1; then
      _meta_log "ext4: mke2fs failed"
      rm -f "$img" 2>/dev/null
      return 1
    fi
  fi

  # INFO: Mount with performance + wear-reduction options:
  #   noatime     don't update access times → eliminates a write per read
  #   nodiratime  don't update dir access times (subset of noatime, explicit)
  #   delalloc    delay block allocation → better layout, less fragmentation
  #   commit=60   flush journal every 60s instead of 5s default → fewer writes
  #   nobarrier   disable write barriers (safe here: data is recreatable from
  #               modules; barriers cost flush commands that add wear)
  #   errors=continue  don't remount-ro on error (keep system booting)
  if ! mount -t ext4 -o loop,noatime,nodiratime,delalloc,commit=60,nobarrier,errors=continue "$img" "$mnt" 2>/dev/null; then
    # Fallback: some kernels reject nobarrier; retry with safer options
    _meta_log "ext4: optimized mount failed, retrying with defaults"
    if ! mount -t ext4 -o loop,noatime,delalloc,errors=continue "$img" "$mnt" 2>/dev/null; then
      _meta_log "ext4: loop mount failed"
      return 1
    fi
  fi

  STAGE="$mnt"
  return 0
}

_probe_mount_mode() {
  local order mode
  # INFO: Remember the user's configured mode before probe overwrites
  # MOUNT_MODE with the actually-resolved mode. This lets us report
  # "configured=auto, effective=ext4" to the WebUI.
  CONFIG_MODE="$MOUNT_MODE"
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

# INFO: Write runtime status file so WebUI/home page can display the EFFECTIVE
# mount mode (e.g. "auto" resolved to "ext4"). Written here, after probe, so
# the actual mode is recorded even if later per-partition mounts fail.
cat > "$STATUS" <<RASTAT
configured_mode=$CONFIG_MODE
effective_mode=$MOUNT_MODE
source=$SOURCE
mount_mode_stage=$STAGE
RASTAT

# INFO: For each partition, merge whitelisted modules into upperdir and overlay
# mount. As the active metamodule, this is OUR job — KSU/APatch do not mount
# modules themselves when metamodule=1 is set.
MOUNTED_PARTITIONS=""
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
    MOUNTED_PARTITIONS="$MOUNTED_PARTITIONS $P"
  else
    _meta_log "FAIL $P: mount -t overlay returned $?"
  fi
done

# INFO: Append the list of actually-mounted partitions to the status file so
# the WebUI can show which partitions are currently overlaid.
cat >> "$STATUS" <<RASTAT2
mounted_partitions=$(echo $MOUNTED_PARTITIONS)
RASTAT2

_meta_log "metamount done (effective_mode=$MOUNT_MODE mounted=[$MOUNTED_PARTITIONS])"
exit 0
