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
# PARTITION SELECTION: A mounted module's partitions are derived from its
# system/ directory — every top-level entry (system, vendor, product, ...) is
# a partition that module wants to overlay. Since the user explicitly chose to
# mount the module, the partitions it needs are mounted UNCONDITIONALLY. There
# is no longer a DANGEROUS_PARTITIONS gate — the old allow_partitions permit
# model fought the whitelist model: a user would tick a module in the WebUI
# but the module silently did nothing because its /system partition was
# "dangerous" and not separately allowed. Choosing the module IS the consent.
# (allow_partitions is still read for backward compat but no longer gates
# anything; an OPTIONAL restrict_partitions= may limit which partitions mount.)
#
# Three mount backends (inspired by mountify):
#   tmpfs — stage on /mnt/vendor/<name> tmpfs, hardest to detect
#   ext4  — loop-mounted ext4 image at /data/adb/.rz_meta_rw/<name>.img
#   direct — upperdir on /data, simplest, always available
#
# Mode auto (default) probes tmpfs → ext4 → direct, picks first that works.
#
# The overlay source is set to "KSU" or "APatch" so zygiskd's umount_root() can
# identify and detach these mounts for denylist apps.

MODDIR=${0%/*}

# INFO: Log lives OUTSIDE /data/adb/rezygisk/ so it survives the rm -rf cleanup
# that post-fs-data.sh performs on /data/adb/rezygisk. This lets the user (and
# WebUI) read the log AFTER boot to diagnose why mounts did/didn't happen.
LOGFILE=/data/adb/.rz_meta.log
# INFO: CFG, STATUS, and RW_BASE live OUTSIDE /data/adb/rezygisk/ on purpose.
# post-fs-data.sh does `rm -rf /data/adb/rezygisk` every boot and then sets the
# dir to chmod 555 (no write). If our config/staging lived there, it would be
# wiped on every boot AND unwritable (555) on the 2nd+ boot — breaking ext4
# image creation and status writes. /data/adb/ itself is 755 and never wiped.
CFG=/data/adb/.rz_meta_cfg
# INFO: Runtime status file. Written AFTER probe so the WebUI/home page can
# show the ACTUAL effective mode (e.g. "auto" resolved to "ext4"). This is
# distinct from CFG (user intent) — STATUS reflects what really happened.
STATUS=/data/adb/.rz_meta_status
RW_BASE=/data/adb/.rz_meta_rw
EXT4_IMG_SIZE_MB=256

_meta_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null
}

# INFO: Write a minimal status file even on early-exit paths, so the WebUI can
# always display a state (instead of showing nothing when status file absent).
_write_status() {
  cat > "$STATUS" <<RASTATS
configured_mode=${MOUNT_MODE:-auto}
effective_mode=${1:-$MOUNT_MODE}
source=${SOURCE:-unknown}
mount_mode_stage=${STAGE:-}
mounted_partitions=${MOUNTED_PARTITIONS:-}
RASTATS
}

_meta_log "=== metamount.sh invoked (pid=$$) ==="

# INFO: Detect the root implementation and its bin directory.
#
# Supported implementations:
#   - KernelSU (official, tiann/KernelSU)           env: KSU=true, dir: /data/adb/ksu
#   - KernelSU-Next                                  env: KSU=true, dir: /data/adb/ksu
#   - SukiSU / Magic KSU / other KSU forks           env: KSU=true, dir: /data/adb/ksu
#   - APatch (bmax121/APatch)                        env: APATCH=true, dir: /data/adb/ap
#
# All KSU branches share the same KSU=true env var and /data/adb/ksu directory
# convention (they're API-compatible forks). APatch uses APATCH=true and
# /data/adb/ap. We set SOURCE to "KSU" or "APatch" (the literal string the
# overlay mount source must be, so zygiskd umount_root can identify them).
#
# ROOT_BIN_DIR points to the implementation's bundled busybox/mke2fs/etc, used
# for tool discovery later. We search multiple candidate paths for robustness.
_detect_root_impl() {
  if [ "$(which magisk)" ]; then
    _meta_log "root impl: Magisk (metamodule not supported)"
    return 1
  fi

  # INFO: APatch detection. APATCH env var is set by APatch's post-fs-data
  # runner. APatch uses /data/adb/ap (main) and /data/adb/apd (daemon).
  if [ "$APATCH" = "true" ] || [ -d /data/adb/ap ] || [ -d /data/adb/apd ]; then
    SOURCE=APatch
    for d in /data/adb/ap/bin /data/adb/apd/bin; do
      [ -d "$d" ] && ROOT_BIN_DIR="$d" && break
    done
    _meta_log "root impl: APatch (ROOT_BIN_DIR=${ROOT_BIN_DIR:-none})"
    return 0
  fi

  # INFO: KSU detection — covers official KernelSU, KernelSU-Next, SukiSU,
  # Magic KSU, Kowsu, and all other API-compatible forks. They all set
  # KSU=true and use /data/adb/ksu. Some forks may use /data/adb/ksud.
  if [ "$KSU" = "true" ] || [ -d /data/adb/ksu ]; then
    SOURCE=KSU
    for d in /data/adb/ksu/bin /data/adb/ksud/bin /data/adb/magisk/bin; do
      [ -d "$d" ] && ROOT_BIN_DIR="$d" && break
    done
    _meta_log "root impl: KSU (variant via env/dir, ROOT_BIN_DIR=${ROOT_BIN_DIR:-none})"
    return 0
  fi

  # INFO: Fallback — scan /data/adb/ for known root impl directories. This
  # catches forks that don't set the env var and use non-standard dir names.
  for d in /data/adb/ksu /data/adb/ksud /data/adb/ap /data/adb/apd; do
    if [ -d "$d" ]; then
      case "$d" in
        */ap|*/apd)
          SOURCE=APatch
          ROOT_BIN_DIR="$d/bin"
          ;;
        *)
          SOURCE=KSU
          ROOT_BIN_DIR="$d/bin"
          ;;
      esac
      _meta_log "root impl: $SOURCE (fallback dir scan: $d, ROOT_BIN_DIR=${ROOT_BIN_DIR:-none})"
      return 0
    fi
  done

  _meta_log "root impl: none detected (KSU=$KSU APATCH=$APATCH)"
  return 1
}

ROOT_BIN_DIR=""
if ! _detect_root_impl; then
  _write_status "no_root_impl"
  exit 0
fi

# INFO: Boot-id sentinel to prevent double-execution. post-fs-data.sh calls
# metamount.sh as a fallback; KernelSU-Next may ALSO call it directly later.
# The first successful run writes the sentinel; subsequent calls in the same
# boot skip. The sentinel is stored OUTSIDE /data/adb/rezygisk (survives rm-rf).
RZ_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
RZ_SENTINEL=/data/adb/.rz_meta_boot_sentinel
if [ -n "$RZ_BOOT_ID" ] && [ -f "$RZ_SENTINEL" ] \
   && [ "$(cat "$RZ_SENTINEL" 2>/dev/null)" = "$RZ_BOOT_ID" ]; then
  _meta_log "metamount already ran this boot (boot_id=$RZ_BOOT_ID), skipping"
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
  _write_status "disabled"
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

# INFO: allow_partitions is kept ONLY for backward compatibility with existing
# config files written by older builds / the WebUI. It no longer gates any
# partition — choosing a module in include_modules is sufficient consent. We
# still log it so old configs don't break and the value is traceable in logs.
ALLOW_PARTITIONS=""
if [ -f "$CFG" ]; then
  _ap=$(grep '^allow_partitions=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr ',' ' ')
  [ -n "$_ap" ] && ALLOW_PARTITIONS="$_ap"
  # Legacy: allow_system=true => allow system partition (now a no-op but parsed)
  grep -q '^allow_system=true' "$CFG" 2>/dev/null && ALLOW_PARTITIONS="$ALLOW_PARTITIONS system"
fi
_meta_log "allow_partitions=[$ALLOW_PARTITIONS] (legacy, no longer gates mounting)"

# INFO: Optional exclude_partitions — a blacklist of partitions the user has
# unchecked in the WebUI. Partitions in this list are NOT mounted even if a
# selected module references them. Empty (default) = mount ALL partitions the
# included modules reference. This is the clean inverse of the old
# allow_partitions permit model and matches the WebUI "checked = mount" UX
# (all partitions checked by default, uncheck to exclude).
EXCLUDE_PARTITIONS=""
if [ -f "$CFG" ]; then
  _ep=$(grep '^exclude_partitions=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr ',' ' ')
  [ -n "$_ep" ] && EXCLUDE_PARTITIONS="$_ep"
fi
[ -n "$EXCLUDE_PARTITIONS" ] && _meta_log "exclude_partitions=[$EXCLUDE_PARTITIONS] (these will NOT mount)"

# INFO: Check if a partition is excluded by the user's blacklist.
_is_partition_excluded() {
  case " $EXCLUDE_PARTITIONS " in
    *" $1 "*) return 0;;
    *) return 1;;
  esac
}

# INFO: Collect partitions to overlay. Only top-level entries under system/.
# Only partitions referenced by whitelisted modules are considered.
# NOTE: partitions are NO LONGER filtered by DANGEROUS_PARTITIONS. The user
# explicitly opted each module in via include_modules, so every partition that
# module ships under system/ is mounted. This fixes the bug where a module
# modifying /system was selected but silently did nothing because "system" was
# dangerous and not separately allowed.
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

    # INFO: respect user's exclude blacklist (unchecked in WebUI)
    if _is_partition_excluded "$pname"; then
      _meta_log "skip $pname: in exclude_partitions blacklist"
      continue
    fi

    case " $PARTITIONS " in
      *" $pname "*) ;;
      *) PARTITIONS="$PARTITIONS $pname";;
    esac
  done
done

_meta_log "partitions discovered:[$PARTITIONS]"

# INFO: If no partitions need mounting, we still MUST write the status file so
# the WebUI/home page can show the (effective) mode and "no partitions" state.
# Previously this branch exit-0'd without writing STATUS, which left the WebUI
# unable to display the effective mode after "auto" — the user saw no suffix
# even though metamount had run. Now we write STATUS with effective=configured
# (no probe needed since nothing mounts) and record empty mounted_partitions.
if [ -z "$PARTITIONS" ]; then
  _meta_log "no partitions to mount (no whitelisted modules), writing status and exiting"
  _write_status "$MOUNT_MODE"
  [ -n "$RZ_BOOT_ID" ] && echo "$RZ_BOOT_ID" > "$RZ_SENTINEL" 2>/dev/null
  exit 0
fi

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

# INFO: Create (or recreate) an ext4 sparse image at $img with size
# $EXT4_IMG_SIZE_MB. Uses JOURNAL-LESS ext4 (no has_journal feature) because
# the overlay upperdir data is fully recreatable from the modules' system/
# dirs on every boot — there is nothing precious to journal. Removing the
# journal eliminates ALL journal write traffic → maximum flash-wear reduction.
# This is the single biggest wear improvement available for a recreatable fs.
#
# If the journal-less format is rejected by an older mke2fs, falls back to a
# journaled ext4 with a tiny journal.
_ext4_create_image() {
  local img="$1"
  # Create sparse file: bs=1 count=0 seek=N grows it logically without
  # writing any data blocks (equivalent to `truncate -s`).
  if ! dd if=/dev/null of="$img" bs=1M count=0 seek="$EXT4_IMG_SIZE_MB" 2>/dev/null; then
    return 1
  fi
  # INFO: Try journal-less ext4 first (best wear profile). -O ^has_journal
  # disables the journal feature. Combined with the other optimizations:
  #   sparse_super   fewer superblock backups → less metadata writes
  #   uninit_bg      uninitialized block groups → no zeroing needed
  #   extent         extent-based blocks → better locality, less fragmentation
  #   dir_index      htree directory indexing → faster lookups
  #   -b 4096        4K block size (matches typical flash page size)
  #   -T largefile   fewer inodes (modules have few large files)
  #   -m 0           no reserved blocks (this is not a root fs)
  #   -E lazy_itable_init  lazy inode table init → less upfront writes
  if "$mke2fs_bin" -t ext4 -F -b 4096 -T largefile -m 0 \
    -O sparse_super,uninit_bg,extent,dir_index,large_file,huge_file,dir_nlink,extra_isize,^has_journal \
    -E lazy_itable_init \
    "$img" >/dev/null 2>&1; then
    _meta_log "ext4: created journal-less image"
    return 0
  fi
  # Fallback: older mke2fs may not support ^has_journal via -O. Use a tiny
  # journal + lazy_journal_init to minimize journal write traffic instead.
  _meta_log "ext4: journal-less create failed, falling back to tiny-journal"
  if "$mke2fs_bin" -t ext4 -F -b 4096 -T largefile -m 0 -J size=4 \
    -O sparse_super,uninit_bg,extent,dir_index,large_file,huge_file,dir_nlink,extra_isize \
    -E lazy_itable_init,lazy_journal_init \
    "$img" >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$img" 2>/dev/null
  return 1
}

_try_setup_ext4() {
  local img mnt mke2fs_bin resize2fs_bin e2fsck_bin
  img="$RW_BASE/$FAKE_MOUNT_NAME.img"
  mnt="/mnt/vendor/$FAKE_MOUNT_NAME"

  # SAFETY: validate paths are absolute and non-empty
  [ -n "$img" ] && [ -n "$mnt" ] || return 1
  case "$img" in /data/adb/.rz_meta_rw/*) ;; *) return 1;; esac
  case "$mnt" in /mnt/vendor/*) ;; *) return 1;; esac

  # INFO: Search for e2fsprogs tools in: system paths, ROOT_BIN_DIR (detected
  # root impl's bin dir, covers all KSU forks + APatch), and PATH.
  mke2fs_bin=""
  for p in /system/bin/mke2fs /system/xbin/mke2fs "${ROOT_BIN_DIR}/mke2fs" "$(which mke2fs 2>/dev/null)"; do
    [ -x "$p" ] && mke2fs_bin="$p" && break
  done
  [ -z "$mke2fs_bin" ] && return 1

  resize2fs_bin=""
  for p in /system/bin/resize2fs /system/xbin/resize2fs "${ROOT_BIN_DIR}/resize2fs" "$(which resize2fs 2>/dev/null)"; do
    [ -x "$p" ] && resize2fs_bin="$p" && break
  done

  e2fsck_bin=""
  for p in /system/bin/e2fsck /system/xbin/e2fsck "${ROOT_BIN_DIR}/e2fsck" "$(which e2fsck 2>/dev/null)"; do
    [ -x "$p" ] && e2fsck_bin="$p" && break
  done

  mkdir -p "$RW_BASE" 2>/dev/null
  mkdir -p "$mnt" 2>/dev/null || return 1

  if [ ! -f "$img" ]; then
    # INFO: Create a SPARSE, JOURNAL-LESS image. Sparse = no 256MB zero write
    # upfront. Journal-less = no journal write traffic at all (data is
    # recreatable from modules on every boot). Together these give the
    # minimum possible flash wear for an ext4 staging area.
    _meta_log "ext4: creating sparse journal-less image $img (${EXT4_IMG_SIZE_MB}MB)"
    if ! _ext4_create_image "$img"; then
      _meta_log "ext4: image creation failed"
      return 1
    fi
  else
    # INFO: Image exists. Auto-grow if size config increased.
    if [ -n "$resize2fs_bin" ]; then
      _want_bytes=$((EXT4_IMG_SIZE_MB * 1024 * 1024))
      _cur_bytes=$(stat -c %s "$img" 2>/dev/null || echo 0)
      if [ "${_cur_bytes:-0}" -gt 0 ] && [ "$_want_bytes" -gt "$_cur_bytes" ]; then
        _meta_log "ext4: growing image ${_cur_bytes} → ${_want_bytes} bytes"
        dd if=/dev/null of="$img" bs=1M count=0 seek="$EXT4_IMG_SIZE_MB" 2>/dev/null
        "$resize2fs_bin" "$img" >/dev/null 2>&1 || _meta_log "ext4: resize2fs failed (continuing with old size)"
      fi
    fi
    # INFO: Run e2fsck to auto-repair any corruption from a previous bad
    # shutdown BEFORE attempting mount. -y = auto-yes to all repairs,
    # -f = force check even if clean. This preserves existing module data
    # instead of blindly recreating the image.
    if [ -n "$e2fsck_bin" ]; then
      "$e2fsck_bin" -y -f "$img" >/dev/null 2>&1 || _meta_log "ext4: e2fsck reported errors (auto-repaired if possible)"
    fi
  fi

  # INFO: Mount with maximum wear-reduction options. Since the staging fs is
  # journal-less (when supported) or has a tiny journal, the main write
  # sources are: data writes (unavoidable), atime updates, and barriers.
  #   noatime      don't update access times → eliminates a write per read
  #   nodiratime   don't update dir access times (subset of noatime)
  #   delalloc     delay block allocation → better layout, less fragmentation
  #   commit=600   flush every 600s (10 min) — with journal-less or tiny
  #                journal, this barely matters; large value minimizes syncs
  #   nobarrier    disable write barriers (data is recreatable; barriers add
  #                FLUSH CACHE commands that cost wear + latency)
  #   init_itable=0  defer inode table initialization maximally
  #   nodiscard    on a loop device, discard passes TRIM to the backing /data
  #                file → extra underlying flash writes; disabled to reduce wear
  #   errors=continue  don't remount-ro on error (keep system booting)
  if ! mount -t ext4 -o loop,noatime,nodiratime,delalloc,commit=600,nobarrier,init_itable=0,nodiscard,errors=continue "$img" "$mnt" 2>/dev/null; then
    # Fallback 1: some kernels reject nobarrier/nodiscard/init_itable/commit=600
    _meta_log "ext4: full-optimized mount failed, retrying with fewer opts"
    if ! mount -t ext4 -o loop,noatime,delalloc,errors=continue "$img" "$mnt" 2>/dev/null; then
      # Fallback 2: image is unrecoverably corrupt. Recreate from scratch.
      _meta_log "ext4: mount failed after e2fsck, recreating corrupt image"
      rm -f "$img" 2>/dev/null
      if ! _ext4_create_image "$img"; then
        return 1
      fi
      if ! mount -t ext4 -o loop,noatime,delalloc,errors=continue "$img" "$mnt" 2>/dev/null; then
        _meta_log "ext4: loop mount failed after recreate"
        return 1
      fi
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

# INFO: For each partition, build the overlay with the correct lowerdir stack.
# This follows the meta-overlayfs reference implementation:
#   lowerdir = module1/system/$P : module2/system/$P : ... : /$P (real partition LAST)
#   source   = "KSU"  (literal, so zygiskd umount_root() can detach for denylist)
#   dest     = /$P    (mount ON TOP of the real partition)
#
# CRITICAL: the module content directories MUST be in lowerdir. Previously
# lowerdir was ONLY /$P (the real partition), which stacked /system on itself —
# the module files never entered the overlay, so modules did nothing. The cp of
# module files into upperdir was also wrong: overlay reads lowerdir directly,
# there is no need (and it's incorrect) to copy files into upperdir. upperdir
# is only for runtime WRITES, which module mounts don't need.
MOUNTED_PARTITIONS=""
for P in $PARTITIONS; do
  lower="/$P"

  # SAFETY: partition must be a simple name, no path traversal
  case "$P" in
    ""|*..*|*/*) _meta_log "skip unsafe partition name: [$P]"; continue;;
  esac
  [ -d "$lower" ] || { _meta_log "skip $P: $lower not a dir"; continue; }

  # INFO: Skip if this partition is ALREADY an overlay mounted by KSU/APatch.
  # On non-Next KernelSU (which doesn't support metamodule=1 and mounts modules
  # itself), the partition would already be overlaid by the time we run. We
  # detect this by checking mount info for an overlay with source KSU/APatch on
  # this mountpoint. This avoids stacking a second overlay on top.
  if mount 2>/dev/null | grep -q "on ${lower} .*overlay.*\\(KSU\\|APatch\\)"; then
    _meta_log "skip $P: already overlaid by $SOURCE (root impl mounted it)"
    MOUNTED_PARTITIONS="$MOUNTED_PARTITIONS $P"
    continue
  fi

  # INFO: Skip partitions that are symlinks (e.g. /vendor -> /system/vendor on
  # some devices). Overlaying a symlink target double-mounts and can break.
  # meta-overlayfs does the same check.
  if [ -L "$lower" ]; then
    _meta_log "skip $P: $lower is a symlink (already covered by another partition)"
    continue
  fi

  # INFO: Build lowerdir stack: collect each whitelisted module's system/$P dir.
  # The real partition /$P is ALWAYS the last (lowest) element so module files
  # take precedence over the real system files.
  lowerdirs=""
  for mod in /data/adb/modules/*; do
    _should_mount_module "$mod" || continue
    src="$mod/system/$P"
    [ -d "$src" ] || continue
    lowerdirs="${lowerdirs}${lowerdirs:+:}$src"
  done

  # SAFETY: if no module has this partition, skip (shouldn't happen since
  # PARTITIONS was derived from modules, but guard anyway).
  [ -z "$lowerdirs" ] && { _meta_log "skip $P: no module provides system/$P"; continue; }

  # Full lowerdir = module dirs : real partition (real partition LAST)
  full_lower="${lowerdirs}:${lower}"

  # INFO: Build mount options. We use an upperdir/workdir on /data so the
  # overlay is writable (some modules/system code may write to /system at
  # runtime; without upperdir the overlay is read-only and writes fail).
  # For 'direct' mode upperdir is directly on /data; for tmpfs/ext4 modes
  # upperdir is inside the staged tmpfs/ext4 image.
  if [ "$MOUNT_MODE" = "direct" ] || [ -z "$STAGE" ]; then
    upper="$RW_BASE/$P/upper"
    work="$RW_BASE/$P/work"
  else
    upper="$STAGE/$P"
    work="$STAGE/.work/$P"
  fi

  # SAFETY: upper/work MUST be non-empty absolute paths.
  if [ -z "$upper" ] || [ -z "$work" ]; then
    _meta_log "FAIL $P: empty upper or work path, skipping"
    continue
  fi
  case "$upper" in /*) ;; *) _meta_log "FAIL $P: upper not absolute: $upper"; continue;; esac
  case "$work" in /*) ;; *) _meta_log "FAIL $P: work not absolute: $work"; continue;; esac

  mkdir -p "$upper" "$work" 2>/dev/null || {
    _meta_log "FAIL $P: cannot create upper/work dir"
    continue
  }

  # INFO: Attempt the overlay mount. source MUST be the literal "KSU" (or
  # "APatch") so zygiskd's umount_root() can identify and detach these mounts
  # for denylist apps. lowerdir lists module dirs first, real partition last.
  if mount -t overlay -o "lowerdir=${full_lower},upperdir=${upper},workdir=${work}" "$SOURCE" "$lower" 2>/dev/null; then
    _meta_log "mounted overlay on $lower (source=$SOURCE mode=$MOUNT_MODE lower=${full_lower})"
    MOUNTED_PARTITIONS="$MOUNTED_PARTITIONS $P"
  else
    # Fallback: try read-only overlay without upperdir/workdir (some kernels
    # reject upperdir on certain filesystems). Read-only overlay only needs
    # lowerdir — module files are still applied.
    _meta_log "overlay with upperdir failed, retrying read-only (lowerdir only)"
    if mount -t overlay -o "lowerdir=${full_lower}" "$SOURCE" "$lower" 2>/dev/null; then
      _meta_log "mounted READ-ONLY overlay on $lower (source=$SOURCE lower=${full_lower})"
      MOUNTED_PARTITIONS="$MOUNTED_PARTITIONS $P"
    else
      _meta_log "FAIL $P: mount -t overlay returned $? (lower=${full_lower})"
    fi
  fi
done

# INFO: Write final status with effective mode and mounted partitions list.
_write_status "$MOUNT_MODE"
# Append mounted_partitions (already in _write_status via MOUNTED_PARTITIONS,
# but explicitly re-write to be safe after the mount loop).
cat >> "$STATUS" <<RASTAT2
mounted_partitions=$(echo $MOUNTED_PARTITIONS)
RASTAT2

_meta_log "metamount done (effective_mode=$MOUNT_MODE mounted=[$MOUNTED_PARTITIONS])"

# INFO: Write the boot_id sentinel so KSU-Next's direct invocation of
# metamount.sh (if it happens later this boot) skips re-execution.
[ -n "$RZ_BOOT_ID" ] && echo "$RZ_BOOT_ID" > "$RZ_SENTINEL" 2>/dev/null

exit 0
