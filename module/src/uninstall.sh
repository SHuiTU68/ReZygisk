#!/system/bin/sh

set -e

export TMP_PATH=/data/adb/rezygisk
rm -rf "$TMP_PATH"

# INFO: Clean up metamodule data (config, status, staging, log, sentinel).
# These live OUTSIDE /data/adb/rezygisk so they survive the rm -rf above.
rm -rf /data/adb/.rz_meta_rw
rm -f /data/adb/.rz_meta_cfg /data/adb/.rz_meta_status /data/adb/.rz_meta.log /data/adb/.rz_meta_boot_sentinel

# INFO: Clean up mountify-style persistent dir (config.sh, modules.txt,
# explicit_I_want_a_bootloop, skipped_modules, count.sh fall-back lives in
# $MODDIR which is already removed above).
rm -rf /data/adb/rezygisk_meta

rm -f /data/adb/post-fs-data.d/rezygisk.sh
rm -f /data/adb/post-mount.d/rezygisk.sh

# INFO: Only removes if dir is empty
rmdir /data/adb/post-fs-data.d
rmdir /data/adb/post-mount.d

exit 0
