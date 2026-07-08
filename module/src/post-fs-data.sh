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
# We call metamount.sh from here as a FALLBACK. KernelSU-Next may also call
# metamount.sh directly at a later boot stage — metamount.sh internally uses a
# boot_id sentinel to detect and skip double-execution. This dual-invocation
# strategy ensures metamount.sh runs regardless of whether the KSU version
# supports direct metamodule hook invocation.
#
# Magisk does NOT support metamodule=1 — it mounts modules itself. So we skip
# metamount.sh entirely on Magisk to avoid double-mounting.
if ! [ "$(which magisk)" ]; then
  if [ -f "$MODDIR/metamount.sh" ]; then
    sh "$MODDIR/metamount.sh" || log -p w -t "zygisk-sh" "metamount.sh returned non-zero, continuing"
  fi
fi

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
