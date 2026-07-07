# shellcheck disable=SC2034
SKIPUNZIP=1

DEBUG=@DEBUG@
MIN_KSU_VERSION=@MIN_KSU_VERSION@
MIN_KSUD_VERSION=@MIN_KSUD_VERSION@
MIN_MAGISK_VERSION=@MIN_MAGISK_VERSION@
MIN_APATCH_VERSION=@MIN_APATCH_VERSION@

if [ "$BOOTMODE" ] && [ "$KSU" ]; then
  ui_print "- Installing from KernelSU app"
  ui_print "- KernelSU version: $KSU_KERNEL_VER_CODE (kernel) + $KSU_VER_CODE (ksud)"
  if ! [ "$KSU_KERNEL_VER_CODE" ] || [ "$KSU_KERNEL_VER_CODE" -lt "$MIN_KSU_VERSION" ]; then
    ui_print "*********************************************************"
    ui_print "! KernelSU version is too old!"
    ui_print "! Please update KernelSU to latest version"
    abort    "*********************************************************"
  fi
  if ! [ "$KSU_VER_CODE" ] || [ "$KSU_VER_CODE" -lt "$MIN_KSUD_VERSION" ]; then
    ui_print "*********************************************************"
    ui_print "! ksud version is too old!"
    ui_print "! Please update KernelSU Manager to latest version"
    abort    "*********************************************************"
  fi
  if [ "$(which magisk)" ]; then
    ui_print "*********************************************************"
    ui_print "! Multiple root implementation is NOT supported!"
    ui_print "! Please uninstall Magisk before installing ReZygisk"
    abort    "*********************************************************"
  fi
  elif [ "$BOOTMODE" ] && [ "$APATCH" ]; then
    ui_print "- Installing from APatch app"
    if ! [ "$APATCH_VER_CODE" ] || [ "$APATCH_VER_CODE" -lt "$MIN_APATCH_VERSION" ]; then
      ui_print "*********************************************************"
      ui_print "! APatch version is too old!"
      ui_print "! Please update APatch to latest version"
      abort    "*********************************************************"
    fi
elif [ "$BOOTMODE" ] && [ "$MAGISK_VER_CODE" ]; then
  ui_print "- Installing from Magisk app"
  if [ "$MAGISK_VER_CODE" -lt "$MIN_MAGISK_VERSION" ]; then
    ui_print "*********************************************************"
    ui_print "! Magisk version is too old!"
    ui_print "! Please update Magisk to latest version"
    abort    "*********************************************************"
  fi
else
  ui_print "*********************************************************"
  ui_print "! Install from recovery is not supported"
  ui_print "! Please install from KernelSU or Magisk app"
  abort    "*********************************************************"
fi

VERSION=$(grep_prop version "${TMPDIR}/module.prop")
ui_print "- Installing ReZygisk $VERSION"

# check android
if [ "$API" -lt 25 ]; then
  ui_print "! Unsupported sdk: $API"
  abort "! Minimal supported sdk is 25 (Android 7.1)"
else
  ui_print "- Device sdk: $API"
fi

# check architecture
if [ "$ARCH" != "arm" ] && [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86" ] && [ "$ARCH" != "x64" ]; then
  abort "! Unsupported platform: $ARCH"
else
  ui_print "- Device platform: $ARCH"
fi

ui_print "- Extracting verify.sh"
unzip -o "$ZIPFILE" 'verify.sh' -d "$TMPDIR" >&2
if [ ! -f "$TMPDIR/verify.sh" ]; then
  ui_print "*********************************************************"
  ui_print "! Unable to extract verify.sh!"
  ui_print "! This zip may be corrupted, please try downloading again"
  abort    "*********************************************************"
fi
. "$TMPDIR/verify.sh"
extract "$ZIPFILE" 'customize.sh'  "$TMPDIR/.vunzip"
extract "$ZIPFILE" 'verify.sh'     "$TMPDIR/.vunzip"
extract "$ZIPFILE" 'sepolicy.rule' "$TMPDIR"

if [ "$KSU" ]; then
  ui_print "- Checking SELinux patches"
  if ! check_sepolicy "$TMPDIR/sepolicy.rule"; then
    ui_print "*********************************************************"
    ui_print "! Unable to apply SELinux patches!"
    ui_print "! Your kernel may not support SELinux patch fully"
    abort    "*********************************************************"
  fi
fi

# INFO: KernelSU/APatch enforce a single-metamodule constraint at the framework
# level, but check here too for a clearer error message and for any fork that
# may not enforce it. /data/adb/metamodule is a symlink to the active
# metamodule's directory; if it points somewhere other than rezygisk, abort.
if [ -L /data/adb/metamodule ]; then
  meta_target=$(readlink /data/adb/metamodule 2>/dev/null)
  case "$meta_target" in
    */rezygisk) : ;;  # upgrading ourselves, allow
    *)
      ui_print "*********************************************************"
      ui_print "! Another metamodule is already installed:"
      ui_print "!   $meta_target"
      ui_print "! Only one metamodule can be active at a time."
      ui_print "! Uninstall it first, reboot, then install Hrezygisk."
      abort    "*********************************************************"
      ;;
  esac
fi

# INFO: Interactive metamodule configuration (KernelSU/APatch only).
# On Magisk the metamodule hooks are never invoked, so we skip this entirely.
#
# SAFETY: metamount defaults to DISABLED. The user must explicitly press
# volume-up to enable it. This prevents accidental bootloops/data loss from
# automated installs or users who don't understand the feature.
#
# Volume key selection: KSU/APatch provide getevent at install time. We use
# a simple chooseport helper that listens for the first volume key press.
# Volume Up = first option, Volume Down = second option. Timeout falls back
# to the safe default (disabled / first option).

# chooseport: wait for a volume key press. Returns "up" or "down".
# Timeout defaults to 15 seconds, returning "down" (safe/no choice) on timeout.
_meta_chooseport() {
  local timeout=${1:-15}
  local result="down"

  # Drain any pending events first
  getevent -qlc 1 >/dev/null 2>&1 &
  local drain_pid=$!
  sleep 0.3
  kill $drain_pid 2>/dev/null
  wait $drain_pid 2>/dev/null

  # Listen for volume keys with timeout
  result=$(
    timeout "$timeout" getevent -ql 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        *KEY_VOLUMEUP*)
          echo "up"
          exit 0
          ;;
        *KEY_VOLUMEDOWN*)
          echo "down"
          exit 0
          ;;
      esac
    done
  )

  # Empty result = timeout, default to down (safe)
  [ -z "$result" ] && result="down"
  printf '%s' "$result"
}

META_ENABLED=false
META_MOUNT_MODE=auto
META_FAKE_NAME=rezygisk

if [ "$KSU" ] || [ "$APATCH" ]; then
  ui_print "*********************************************************"
  ui_print " 元模块挂载配置"
  ui_print "*********************************************************"
  ui_print ""
  ui_print " 元模块挂载会在开机时接管所有模块的 system/ 挂载。"
  ui_print " 这是一个高级功能，配置不当可能导致无法开机或数据丢失。"
  ui_print ""

  # Q1 — 是否启用元模块挂载？音量上=启用，音量下=不启用（默认）
  ui_print " 是否启用元模块挂载？"
  ui_print "  [音量上] = 启用"
  ui_print "  [音量下] = 不启用（默认，推荐）"
  ui_print "  15秒无操作默认不启用"
  _key=$(_meta_chooseport 15)
  case "$_key" in
    up)
      META_ENABLED=true
      ui_print "  -> 已启用"
      ;;
    *)
      META_ENABLED=false
      ui_print "  -> 不启用"
      ;;
  esac

  if [ "$META_ENABLED" = "true" ]; then
    ui_print ""

    # Q2 — 挂载方式
    # 音量上=auto，音量下=tmpfs，需要4个选项用两轮选择
    # 简化为：第一轮选 auto vs 手动指定，手动指定时再选
    ui_print " 挂载方式（第一轮）："
    ui_print "  [音量上] = auto（自动探测，默认）"
    ui_print "  [音量下] = 手动指定"
    _key=$(_meta_chooseport 15)
    if [ "$_key" = "down" ]; then
      ui_print ""
      ui_print " 挂载方式（第二轮）："
      ui_print "  [音量上] = tmpfs（最难检测）"
      ui_print "  [音量下] = ext4（模拟旧版KSU）"
      _key=$(_meta_chooseport 15)
      case "$_key" in
        up)   META_MOUNT_MODE=tmpfs;  ui_print "  -> tmpfs";;
        down) META_MOUNT_MODE=ext4;   ui_print "  -> ext4";;
        *)    META_MOUNT_MODE=ext4;   ui_print "  -> ext4（超时默认）";;
      esac
      ui_print ""
      ui_print " 是否使用 direct 模式？"
      ui_print "  [音量上] = 是，使用 direct（最简单）"
      ui_print "  [音量下] = 否，使用上面选择的"
      _key=$(_meta_chooseport 15)
      case "$_key" in
        up) META_MOUNT_MODE=direct; ui_print "  -> direct";;
        *)  ui_print "  -> 保持之前选择: $META_MOUNT_MODE";;
      esac
    else
      META_MOUNT_MODE=auto
      ui_print "  -> auto"
    fi

    ui_print ""

    # Q3 — 自定义挂载名称（用于 tmpfs/ext4 模式）
    # 用音量键选择：使用默认 rezygisk，还是自定义（输入较复杂，音量键环境
    # 无法输入文本，所以提供两个预设选项）
    ui_print " 自定义挂载名称（tmpfs/ext4 模式使用）："
    ui_print "  [音量上] = rezygisk（默认）"
    ui_print "  [音量下] = system_overlay"
    _key=$(_meta_chooseport 15)
    case "$_key" in
      up)
        META_FAKE_NAME=rezygisk
        ui_print "  -> rezygisk"
        ;;
      down)
        META_FAKE_NAME=system_overlay
        ui_print "  -> system_overlay"
        ;;
      *)
        META_FAKE_NAME=rezygisk
        ui_print "  -> rezygisk（超时默认）"
        ;;
    esac
  fi

  ui_print "*********************************************************"
  ui_print " 配置已保存，可在 WebUI > 元模块挂载 中修改"
  ui_print "*********************************************************"

  # INFO: Persist the configuration so metamount.sh can source it on next boot.
  mkdir -p /data/adb/rezygisk
  cat > /data/adb/rezygisk/.rz_meta_cfg <<METACFG
enabled=$META_ENABLED
mount_mode=$META_MOUNT_MODE
fake_mount_name=$META_FAKE_NAME
allow_partitions=""
skip_modules=""
METACFG
fi

ui_print "- Extracting module files"
extract "$ZIPFILE" 'module.prop'     "$MODPATH"
extract "$ZIPFILE" 'post-fs-data.sh' "$MODPATH"
extract "$ZIPFILE" 'service.sh'      "$MODPATH"
extract "$ZIPFILE" 'uninstall.sh'    "$MODPATH"
extract "$ZIPFILE" 'metamount.sh'     "$MODPATH"
extract "$ZIPFILE" 'metainstall.sh'   "$MODPATH"
extract "$ZIPFILE" 'metauninstall.sh' "$MODPATH"
extract "$ZIPFILE" 'rezygisk.sh' "/data/adb/post-fs-data.d/"

# INFO: Metamodule hooks must be executable so KernelSU/APatch can invoke them.
chmod +x "$MODPATH/metamount.sh" "$MODPATH/metainstall.sh" "$MODPATH/metauninstall.sh"

# INFO: KernelSU 2.x.x and below runs post-fs-data.d before mounting
#         the modules. This disallows us to clean our own module.prop.
#         To work around this, we utilize post-mount.d which runs after
#         mounting, and copy our post-fs-data.d script there.
#
# SOURCES:
#  - https://github.com/tiann/KernelSU/blob/6615068a987a12bbc6a3ad272b285cec7f594964/userspace/ksud/src/init_event.rs#L123
#  - https://github.com/tiann/KernelSU/blob/6615068a987a12bbc6a3ad272b285cec7f594964/userspace/ksud/src/init_event.rs#L161
#  - https://github.com/tiann/KernelSU/blob/6615068a987a12bbc6a3ad272b285cec7f594964/userspace/ksud/src/init_event.rs#L212-L217
mkdir -p /data/adb/post-mount.d
cp "/data/adb/post-fs-data.d/rezygisk.sh" "/data/adb/post-mount.d/rezygisk.sh"

cp "$MODPATH/module.prop" "$MODPATH/module.prop.bak"

chmod +x "$MODPATH/uninstall.sh"

mv "$TMPDIR/sepolicy.rule" "$MODPATH"

mkdir "$MODPATH/bin"
mkdir "$MODPATH/webroot"

ui_print "- Extracting webroot"
unzip -o "$ZIPFILE" "webroot/*" -x "*.sha256" -d "$MODPATH"

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

SUPPORTS_32BIT=false
SUPPORTS_64BIT=false

if [[ "$CPU_ABIS" == *"x86"* && "$CPU_ABIS" != "x86_64" || "$CPU_ABIS" == *"armeabi"* ]]; then
  SUPPORTS_32BIT=true
  ui_print "- Device supports 32-bit"
fi

if [[ "$CPU_ABIS" == *"x86_64"* || "$CPU_ABIS" == *"arm64-v8a"* ]]; then
  SUPPORTS_64BIT=true
  ui_print "- Device supports 64-bit"
fi

if [ "$SUPPORTS_32BIT" = true ]; then
  mkdir "$MODPATH/lib"
fi

if [ "$SUPPORTS_64BIT" = true ]; then
  mkdir "$MODPATH/lib64"
fi

if [ "$ARCH" = "x86" ] || [ "$ARCH" = "x64" ]; then
  if [ "$SUPPORTS_32BIT" = true ]; then
    ui_print "- Extracting x86 libraries"
    extract "$ZIPFILE" 'bin/x86/zygiskd' "$MODPATH/bin" true
    mv "$MODPATH/bin/zygiskd" "$MODPATH/bin/zygiskd32"
    extract "$ZIPFILE" 'lib/x86/libzygisk.so' "$MODPATH/lib" true
    extract "$ZIPFILE" 'lib/x86/libzygisk_ptrace.so' "$MODPATH/bin" true
    mv "$MODPATH/bin/libzygisk_ptrace.so" "$MODPATH/bin/zygisk-ptrace32"

    extract "$ZIPFILE" 'machikado.x86' "$MODPATH" true
  fi

  if [ "$SUPPORTS_64BIT" = true ]; then
    ui_print "- Extracting x64 libraries"
    extract "$ZIPFILE" 'bin/x86_64/zygiskd' "$MODPATH/bin" true
    mv "$MODPATH/bin/zygiskd" "$MODPATH/bin/zygiskd64"
    extract "$ZIPFILE" 'lib/x86_64/libzygisk.so' "$MODPATH/lib64" true
    extract "$ZIPFILE" 'lib/x86_64/libzygisk_ptrace.so' "$MODPATH/bin" true
    mv "$MODPATH/bin/libzygisk_ptrace.so" "$MODPATH/bin/zygisk-ptrace64"

    extract "$ZIPFILE" 'machikado.x86_64' "$MODPATH" true
  fi
else
  if [ "$SUPPORTS_32BIT" = true ]; then
    ui_print "- Extracting arm libraries"
    extract "$ZIPFILE" 'bin/armeabi-v7a/zygiskd' "$MODPATH/bin" true
    mv "$MODPATH/bin/zygiskd" "$MODPATH/bin/zygiskd32"
    extract "$ZIPFILE" 'lib/armeabi-v7a/libzygisk.so' "$MODPATH/lib" true
    extract "$ZIPFILE" 'lib/armeabi-v7a/libzygisk_ptrace.so' "$MODPATH/bin" true
    mv "$MODPATH/bin/libzygisk_ptrace.so" "$MODPATH/bin/zygisk-ptrace32"

    extract "$ZIPFILE" 'machikado.arm' "$MODPATH" true
  fi

  if [ "$SUPPORTS_64BIT" = true ]; then
    ui_print "- Extracting arm64 libraries"
    extract "$ZIPFILE" 'bin/arm64-v8a/zygiskd' "$MODPATH/bin" true
    mv "$MODPATH/bin/zygiskd" "$MODPATH/bin/zygiskd64"
    extract "$ZIPFILE" 'lib/arm64-v8a/libzygisk.so' "$MODPATH/lib64" true
    extract "$ZIPFILE" 'lib/arm64-v8a/libzygisk_ptrace.so' "$MODPATH/bin" true
    mv "$MODPATH/bin/libzygisk_ptrace.so" "$MODPATH/bin/zygisk-ptrace64"

    extract "$ZIPFILE" 'machikado.arm64' "$MODPATH" true
  fi
fi

ui_print "- Setting permissions"
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755

if [ "$SUPPORTS_32BIT" = true ]; then
  set_perm_recursive "$MODPATH/lib" 0 0 0755 0644 u:object_r:system_lib_file:s0
fi

if [ "$SUPPORTS_64BIT" = true ]; then
  set_perm_recursive "$MODPATH/lib64" 0 0 0755 0644 u:object_r:system_lib_file:s0
fi

# If Huawei's Maple is enabled, system_server is created with a special way which is out of Zygisk's control
HUAWEI_MAPLE_ENABLED=$(grep_prop ro.maple.enable)
if [ "$HUAWEI_MAPLE_ENABLED" == "1" ]; then
  ui_print "- Add ro.maple.enable=0"
  echo "ro.maple.enable=0" >>"$MODPATH/system.prop"
fi
