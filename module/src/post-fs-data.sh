#!/system/bin/sh

set -e

MODDIR=${0%/*}
if [ "$ZYGISK_ENABLED" ]; then
  exit 0
fi

cd "$MODDIR"

if [ "$(which magisk)" ]; then
  for file in ../*; do
    if [ -d "$file" ] && [ -d "$file/zygisk" ] && ! [ -f "$file/disable" ]; then
      if [ -f "$file/post-fs-data.sh" ]; then
        cd "$file"
        log -p i -t "zygisk-sh" "Manually trigger post-fs-data.sh for $file"
        sh "$(realpath ./post-fs-data.sh)"
        cd "$MODDIR"
      fi
    fi
  done
fi

# INFO: As the active metamodule (metamodule=1 in module.prop), Hrezygisk is
# responsible for mounting other modules' system/ dirs via overlay.
#
# IMPORTANT: Do NOT call metamount.sh from here. KernelSU/APatch invoke
# metamount.sh DIRECTLY as the metamodule mount hook (after ALL post-fs-data.sh
# scripts — both metamodule's and regular modules' — have run, and after
# system.prop is loaded). This is the documented KSU boot sequence:
#   1. post-fs-data.d scripts
#   2. prune modules, restorecon, sepolicy
#   3. metamodule's post-fs-data.sh   ← we are here
#   4. regular modules' post-fs-data.sh
#   5. load system.prop
#   6. metamodule's metamount.sh      ← KSU calls this directly, ONCE
#   7. post-mount.d
#
# Calling metamount.sh here would run it at step 3 (too early — regular module
# content may not be ready) AND KSU would call it again at step 6 (double exec
# → second overlay over an already-overlaid /system fails). So metamount.sh is
# intentionally NOT invoked from post-fs-data.sh.

create_sys_perm() {
  mkdir -p $1
  chmod 555 $1
  chcon u:object_r:system_file:s0 $1
}

# INFO: /data/adb/rezygisk is Hrezygisk's own temp dir for zygisk-ptrace.
# metamount.sh does NOT use this dir (its data lives at /data/adb/.rz_meta_*),
# so this rm -rf is safe and won't affect metamodule config or staging.
export TMP_PATH=/data/adb/rezygisk
rm -rf "$TMP_PATH"

create_sys_perm $TMP_PATH

sh /data/adb/post-fs-data.d/rezygisk.sh

# INFO: Utilize the one with the biggest output, as some devices with Tango have the full list
#         in ro.product.cpu.abilist but others only have a subset there, and the full list in
#         ro.system.product.cpu.abilist
CPU_ABIS_PROP1=$(getprop ro.system.product.cpu.abilist)
CPU_ABIS_PROP2=$(getprop ro.product.cpu.abilist)

if [ "${#CPU_ABIS_PROP2}" -gt "${#CPU_ABIS_PROP1}" ]; then
  CPU_ABIS=$CPU_ABIS_PROP2
else
  CPU_ABIS=$CPU_ABIS_PROP1
fi

if [[ "$CPU_ABIS" == *"arm64-v8a"* || "$CPU_ABIS" == *"x86_64"* ]]; then
  ./bin/zygisk-ptrace64 monitor &
else
  # INFO: Device is 32-bit only

  ./bin/zygisk-ptrace32 monitor &
fi

exit 0
