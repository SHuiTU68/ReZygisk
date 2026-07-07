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
# The KSU/APatch manager app provides an interactive console for customize.sh,
# so `read` works there. If read times out or hits EOF (non-interactive flash),
# sensible defaults are used. All settings can be changed later via WebUI.
META_ENABLED=true
META_MOUNT_MODE=auto
META_FAKE_NAME=rezygisk

if [ "$KSU" ] || [ "$APATCH" ]; then
  ui_print "*********************************************************"
  ui_print " Metamodule Configuration"
  ui_print "*********************************************************"

  # INFO: Q1 — Enable metamount?
  ui_print "- Enable metamodule mount? (Y/n)"
  ui_print "  Enter = Yes (default), type n = No"
  _ans=""
  read -r -t 15 _ans 2>/dev/null || _ans=""
  case "$_ans" in
    [Nn]*) META_ENABLED=false; ui_print "  -> Disabled";;
    *) META_ENABLED=true; ui_print "  -> Enabled";;
  esac

  if [ "$META_ENABLED" = "true" ]; then
    # INFO: Q2 — Mount mode. auto probes tmpfs → ext4 → direct and picks the
    # first that works on this device. Concrete modes are tried first and fall
    # through to the others on failure.
    ui_print "- Mount mode:"
    ui_print "  1 = auto   (probe tmpfs/ext4/direct, pick best) [default]"
    ui_print "  2 = tmpfs  (stage on /mnt/vendor/<name>, hardest to detect)"
    ui_print "  3 = ext4   (loop-mounted ext4 image, mimics old KSU)"
    ui_print "  4 = direct (upperdir on /data, simplest)"
    ui_print "  Enter = auto (default)"
    _ans=""
    read -r -t 15 _ans 2>/dev/null || _ans=""
    case "$_ans" in
      2) META_MOUNT_MODE=tmpfs;  ui_print "  -> tmpfs";;
      3) META_MOUNT_MODE=ext4;   ui_print "  -> ext4";;
      4) META_MOUNT_MODE=direct; ui_print "  -> direct";;
      *) META_MOUNT_MODE=auto;   ui_print "  -> auto";;
    esac

    # INFO: Q3 — Custom fake mount name (used by tmpfs/ext4 modes as the
    # /mnt/vendor/<name> staging point). Always asked so the user can switch
    # modes via WebUI without reconfiguring.
    ui_print "- Fake mount name (default: rezygisk)"
    ui_print "  Becomes /mnt/vendor/<name> in tmpfs/ext4 modes."
    ui_print "  Enter = rezygisk (default)"
    _ans=""
    read -r -t 15 _ans 2>/dev/null || _ans=""
    if [ -n "$_ans" ]; then
      # Sanitize: only allow alphanumerics and underscore
      _clean=$(printf '%s' "$_ans" | tr -cd 'A-Za-z0-9_')
      if [ -n "$_clean" ]; then
        META_FAKE_NAME="$_clean"
      fi
    fi
    ui_print "  -> $META_FAKE_NAME"
  fi

  ui_print "*********************************************************"
  ui_print " You can change these later via WebUI > Hiding"
  ui_print "*********************************************************"

  # INFO: Persist the configuration so metamount.sh can source it on next boot.
  mkdir -p /data/adb/rezygisk
  cat > /data/adb/rezygisk/.rz_meta_cfg <<METACFG
enabled=$META_ENABLED
mount_mode=$META_MOUNT_MODE
fake_mount_name=$META_FAKE_NAME
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
