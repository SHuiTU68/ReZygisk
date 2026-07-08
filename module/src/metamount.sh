#!/system/bin/sh

# Hrezygisk metamodule mount handler.
#
# This script is based on mountify's proven staging + per-directory overlay
# mechanism (https://github.com/backslashxx/mountify). The key insight from
# mountify is: instead of overlaying entire partitions (which fails when the
# partition is already overlaid by KSU), we:
#   1. Create a tmpfs (or ext4) staging area at /mnt/vendor/<name>
#   2. Copy each whitelisted module's system/ contents into the staging area
#   3. For EACH subdirectory (system/bin, system/etc, vendor/lib, ...), do a
#      separate overlay: lowerdir=staging/dir:/real/dir
#   4. Unmount the staging area (the per-dir overlays persist)
#
# This avoids stacking overlay-on-overlay on entire partitions and works
# reliably across all KSU forks and APatch.
#
# CONFIG: /data/adb/.rz_meta_cfg (enabled, mount_mode, fake_mount_name,
#         include_modules, exclude_partitions)
# STATUS: /data/adb/.rz_meta_status (effective_mode, mounted_partitions)

MODDIR=${0%/*}

# INFO: All metamount data lives OUTSIDE /data/adb/rezygisk/ (which gets
# rm -rf'd + chmod 555 by post-fs-data.sh every boot).
LOGFILE=/data/adb/.rz_meta.log
CFG=/data/adb/.rz_meta_cfg
STATUS=/data/adb/.rz_meta_status

_meta_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null
}

_write_status() {
  cat > "$STATUS" <<RASTATS
configured_mode=${CONFIG_MODE:-${MOUNT_MODE:-auto}}
effective_mode=${1:-$MOUNT_MODE}
source=${SOURCE:-unknown}
mount_mode_stage=${STAGE:-}
mounted_partitions=${MOUNTED_PARTITIONS:-}
mounted_dirs=${MOUNTED_DIRS:-}
RASTATS
}

_meta_log "=== metamount.sh invoked (pid=$$) ==="

# INFO: Ensure PATH includes root impl bin dirs so busybox is findable.
PATH=/data/adb/ap/bin:/data/adb/apd/bin:/data/adb/ksu/bin:/data/adb/ksud/bin:/data/adb/magisk:$PATH
export PATH

# INFO: Detect root implementation (KSU all forks + APatch).
_detect_root_impl() {
  if [ "$(which magisk)" ]; then
    _meta_log "root impl: Magisk (metamodule not supported)"
    return 1
  fi
  if [ "$APATCH" = "true" ] || [ -d /data/adb/ap ] || [ -d /data/adb/apd ]; then
    SOURCE=APatch
    _meta_log "root impl: APatch"
    return 0
  fi
  if [ "$KSU" = "true" ] || [ -d /data/adb/ksu ] || [ -d /data/adb/ksud ]; then
    SOURCE=KSU
    _meta_log "root impl: KSU"
    return 0
  fi
  _meta_log "root impl: none detected (KSU=$KSU APATCH=$APATCH)"
  return 1
}

SOURCE=""
if ! _detect_root_impl; then
  _write_status "no_root_impl"
  exit 0
fi

# INFO: Boot-id sentinel to prevent double-execution.
RZ_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
RZ_SENTINEL=/data/adb/.rz_meta_boot_sentinel
if [ -n "$RZ_BOOT_ID" ] && [ -f "$RZ_SENTINEL" ] \
   && [ "$(cat "$RZ_SENTINEL" 2>/dev/null)" = "$RZ_BOOT_ID" ]; then
  _meta_log "metamount already ran this boot (boot_id=$RZ_BOOT_ID), skipping"
  exit 0
fi

# INFO: Read user configuration. DEFAULT: enabled=false for safety.
ENABLED=false
MOUNT_MODE=auto
FAKE_MOUNT_NAME=rezygisk
INCLUDE_MODULES=""
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi
CONFIG_MODE="$MOUNT_MODE"

if [ "$ENABLED" != "true" ]; then
  _meta_log "metamount disabled by config (enabled=$ENABLED), exiting"
  _write_status "disabled"
  exit 0
fi

_meta_log "metamount start: SOURCE=$SOURCE mode=$MOUNT_MODE fake_name=$FAKE_MOUNT_NAME include=[$INCLUDE_MODULES]"

# SAFETY: Sanitize FAKE_MOUNT_NAME — only allow alphanumerics + underscore.
case "$FAKE_MOUNT_NAME" in
  *[!A-Za-z0-9_]*) FAKE_MOUNT_NAME=rezygisk;;
esac
[ -z "$FAKE_MOUNT_NAME" ] && FAKE_MOUNT_NAME=rezygisk

# INFO: Read exclude_partitions blacklist (partitions user unchecked in WebUI).
EXCLUDE_PARTITIONS=""
if [ -f "$CFG" ]; then
  _ep=$(grep '^exclude_partitions=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr ',' ' ')
  [ -n "$_ep" ] && EXCLUDE_PARTITIONS="$_ep"
fi
[ -n "$EXCLUDE_PARTITIONS" ] && _meta_log "exclude_partitions=[$EXCLUDE_PARTITIONS]"

_is_partition_excluded() {
  case " $EXCLUDE_PARTITIONS " in
    *" $1 "*) return 0;;
    *) return 1;;
  esac
}

# INFO: Whitelist check — only mount modules explicitly in include_modules.
_should_mount_module() {
  mod="$1"
  [ -d "$mod" ] || return 1
  [ -d "$mod/system" ] || return 1
  [ -f "$mod/disable" ] && return 1
  [ -f "$mod/skip_mount" ] && return 1
  [ -f "$mod/remove" ] && return 1
  modid=$(basename "$mod")
  case " $INCLUDE_MODULES " in
    *" $modid "*) return 0;;
  esac
  return 1
}

# INFO: Partitions to scan for (top-level dirs under system/). Matches mountify.
# These are the common Android partitions that modules may modify.
TARGET_PARTITIONS="system vendor product system_ext odm oem mi_ext my_bigball my_carrier my_company my_engineering my_heytap my_manifest my_preload my_product my_region my_reserve my_stock optics prism"

# INFO: Determine staging folder. Prefer /mnt/vendor (writable, not mounted),
# fall back to /mnt.
MNT_FOLDER=""
if [ -w "/mnt/vendor" ] && ! grep -q " /mnt/vendor " /proc/mounts 2>/dev/null; then
  MNT_FOLDER="/mnt/vendor"
elif [ -w "/mnt" ]; then
  MNT_FOLDER="/mnt"
fi

if [ -z "$MNT_FOLDER" ]; then
  _meta_log "FAIL: no writable staging folder (/mnt or /mnt/vendor)"
  _write_status "no_staging_folder"
  exit 0
fi

STAGE="$MNT_FOLDER/$FAKE_MOUNT_NAME"

# INFO: Stage 1 — mount tmpfs on MNT_FOLDER itself (so all staging is volatile).
# This mirrors mountify's two-stage approach.
_meta_log "stage1: mounting tmpfs on $MNT_FOLDER"
if ! mount -t tmpfs tmpfs "$MNT_FOLDER" 2>/dev/null; then
  _meta_log "FAIL: cannot mount tmpfs on $MNT_FOLDER"
  _write_status "stage1_fail"
  exit 0
fi

# INFO: Stage 2 — mount tmpfs (or ext4) on the staging subfolder.
mkdir -p "$STAGE"

# INFO: Try ext4 mode if requested or as auto fallback for large module sets.
# For now, use tmpfs (simplest, works everywhere). ext4 can be added later.
_meta_log "stage2: mounting tmpfs on $STAGE"
if ! mount -t tmpfs tmpfs "$STAGE" 2>/dev/null; then
  _meta_log "FAIL: cannot mount tmpfs on $STAGE"
  _write_status "stage2_fail"
  exit 0
fi

if [ "$MOUNT_MODE" = "auto" ] || [ "$MOUNT_MODE" = "tmpfs" ]; then
  EFFECTIVE_MODE=tmpfs
elif [ "$MOUNT_MODE" = "ext4" ] || [ "$MOUNT_MODE" = "direct" ]; then
  # INFO: For ext4/direct, still use tmpfs staging (the mount mechanism is the
  # same; ext4 would back the staging with a loop image for persistence, but
  # since module data is recreatable each boot, tmpfs is fine and faster).
  EFFECTIVE_MODE=tmpfs
else
  EFFECTIVE_MODE=tmpfs
fi
MOUNT_MODE=$EFFECTIVE_MODE
_meta_log "effective mode: $EFFECTIVE_MODE (stage=$STAGE)"

# Write status now so WebUI shows effective mode even if mounts partially fail.
MOUNTED_PARTITIONS=""
MOUNTED_DIRS=""
_write_status "$EFFECTIVE_MODE"

# INFO: Copy each whitelisted module's system/ contents into staging area.
# Module structure: module/system/bin/..., module/system/etc/...
# Staging structure: staging/bin/..., staging/etc/...
# Later, staging/bin overlays onto /system/bin, staging/vendor onto /vendor, etc.
#
# "system" subdir of module/system/ maps to /system itself.
# Other subdirs (vendor, product, ...) map to /<subdir>.
_modules_copied=0
for mod in /data/adb/modules/*; do
  _should_mount_module "$mod" || continue
  modid=$(basename "$mod")
  _meta_log "copying module: $modid"

  # Copy each partition this module provides
  for entry in "$mod"/system/*; do
    [ -e "$entry" ] || continue
    pname=$(basename "$entry")
    # SAFETY: partition name must be a simple identifier
    case "$pname" in
      ""|*..*|*/*) continue;;
    esac

    # Skip excluded partitions
    if _is_partition_excluded "$pname"; then
      _meta_log "  skip $pname (excluded)"
      continue
    fi

    # Copy module's system/$pname into staging/$pname
    mkdir -p "$STAGE/$pname" 2>/dev/null
    if cp -af "$entry/." "$STAGE/$pname/" 2>/dev/null; then
      _meta_log "  copied $pname"
      _modules_copied=$((_modules_copied + 1))
    else
      _meta_log "  WARN: cp failed for $pname"
    fi
  done
done

if [ "$_modules_copied" -eq 0 ]; then
  _meta_log "no module files copied (no whitelisted modules or all excluded)"
  _write_status "$EFFECTIVE_MODE"
  [ -n "$RZ_BOOT_ID" ] && echo "$RZ_BOOT_ID" > "$RZ_SENTINEL" 2>/dev/null
  # Unmount staging since nothing to mount
  umount -l "$STAGE" 2>/dev/null
  umount -l "$MNT_FOLDER" 2>/dev/null
  exit 0
fi

# INFO: Mirror SELinux context from real files to staged files. This is critical
# — without it, overlay shows "u:object_r:tmpfs:s0" and processes get denied.
#
# Mapping: staging/$pname/$file → /$real_partition/$pname/$file
#   - If pname == "system": real_partition is /system (staging/system/bin → /system/bin)
#   - Else: real_partition is /$pname (staging/vendor/lib → /vendor/lib)
_meta_log "restoring SELinux contexts on staging"
for staging_part in "$STAGE"/*; do
  [ -e "$staging_part" ] || continue
  part=$(basename "$staging_part")

  # Determine the real base path for this staging partition
  case "$part" in
    system) real_base="/system" ;;
    *)      real_base="/$part" ;;
  esac
  [ -d "$real_base" ] || continue

  # chcon each file to match the corresponding real file
  find "$staging_part" -type f 2>/dev/null | while read -r f; do
    rel="${f#$STAGE/$part/}"
    realfile="$real_base/$rel"
    if [ -e "$realfile" ]; then
      chcon --reference="$realfile" "$f" 2>/dev/null
    else
      # New file from module — use parent dir's context
      parentdir=$(dirname "$realfile")
      [ -d "$parentdir" ] && chcon --reference="$parentdir" "$f" 2>/dev/null
    fi
  done
  # chcon directories too
  find "$staging_part" -type d 2>/dev/null | while read -r d; do
    rel="${d#$STAGE/$part/}"
    realdir="$real_base/$rel"
    if [ -d "$realdir" ]; then
      chcon --reference="$realdir" "$d" 2>/dev/null
    fi
  done
done

# INFO: Handle opaque directories (trusted.overlay.opaque xattr). If a module
# marks a dir as opaque, the overlay should hide the lower real dir entirely.
_meta_log "checking opaque dirs"
for staging_part in "$STAGE"/*; do
  [ -e "$staging_part" ] || continue
  find "$staging_part" -type d 2>/dev/null | while read -r d; do
    if getfattr -d "$d" 2>/dev/null | grep -q "trusted.overlay.opaque"; then
      setfattr -n trusted.overlay.opaque -v y "$d" 2>/dev/null
      _meta_log "  set opaque: $d"
    fi
  done
done

# INFO: Now do per-directory overlay mounts. For each subdirectory in staging,
# overlay it onto the corresponding real directory. This is mountify's core
# mechanism: lowerdir=staging/subdir:/real/subdir
#
# Mapping:
#   staging/system/bin  → overlay onto /system/bin
#   staging/system/etc  → overlay onto /system/etc
#   staging/vendor/lib  → overlay onto /vendor/lib
#   staging/product/app → overlay onto /product/app
_meta_log "starting per-directory overlay mounts"

# Function: overlay each subdir of $staging_base onto $real_base
_overlay_subdirs() {
  _staging_base="$1"
  _real_base="$2"

  [ -d "$_staging_base" ] || return 0
  [ -d "$_real_base" ] || return 0

  cd "$_staging_base" || return 0
  for dir in */; do
    [ -d "$dir" ] || continue
    dir="${dir%/}"
    [ -n "$dir" ] || continue

    target="$_real_base/$dir"
    lower="$_staging_base/$dir"

    # Skip if target doesn't exist (can't overlay non-existent dir)
    if [ ! -d "$target" ]; then
      _meta_log "  skip $target (not a dir)"
      continue
    fi

    # Skip if target is a symlink (e.g. /vendor -> /system/vendor)
    if [ -L "$target" ]; then
      _meta_log "  skip $target (symlink)"
      continue
    fi

    # INFO: mount overlay. lowerdir = staging dir : real dir.
    # source = "KSU" or "APatch" for denylist umount identification.
    # No upperdir/workdir = read-only overlay (sufficient for module files).
    if mount -t overlay -o "lowerdir=${lower}:${target}" "$SOURCE" "$target" 2>/dev/null; then
      _meta_log "  mounted overlay on $target (lower=$lower:$target)"
      MOUNTED_DIRS="$MOUNTED_DIRS $target"
    else
      _meta_log "  FAIL $target: mount overlay returned $?"
    fi
  done
  cd "$MODDIR" 2>/dev/null
}

# Process each partition present in staging
for staging_part in "$STAGE"/*; do
  [ -d "$staging_part" ] || continue
  part=$(basename "$staging_part")

  # Determine real base path
  case "$part" in
    system) real_part="/system" ;;
    *)      real_part="/$part" ;;
  esac

  _meta_log "processing partition: $part (real=$real_part)"

  # Skip if real partition doesn't exist
  if [ ! -d "$real_part" ]; then
    _meta_log "  skip $part: $real_part not found"
    continue
  fi

  # Skip symlinks (e.g. /vendor -> /system/vendor)
  if [ -L "$real_part" ]; then
    _meta_log "  skip $part: $real_part is symlink"
    continue
  fi

  # Overlay subdirs of this partition
  _overlay_subdirs "$staging_part" "$real_part"
  MOUNTED_PARTITIONS="$MOUNTED_PARTITIONS $part"
done

# INFO: Unmount staging areas (the per-dir overlays persist independently).
_meta_log "unmounting staging areas"
umount -l "$STAGE" 2>/dev/null
umount -l "$MNT_FOLDER" 2>/dev/null

# Write final status
_write_status "$EFFECTIVE_MODE"

_meta_log "metamount done (effective_mode=$EFFECTIVE_MODE partitions=[$MOUNTED_PARTITIONS] dirs=$MOUNTED_DIRS)"

# Write boot_id sentinel
[ -n "$RZ_BOOT_ID" ] && echo "$RZ_BOOT_ID" > "$RZ_SENTINEL" 2>/dev/null

exit 0
