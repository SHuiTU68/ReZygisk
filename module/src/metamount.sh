#!/bin/sh
# metamount.sh
# Ported from mountify (https://github.com/backslashxx/mountify)
# No warranty. No rights reserved. The Unlicense.
PATH=/data/adb/ap/bin:/data/adb/apd/bin:/data/adb/ksu/bin:/data/adb/ksud/bin:/data/adb/magisk:$PATH
# variables
MODDIR="/data/adb/modules/rezygisk"
# config
mountify_mounts=2
FAKE_MOUNT_NAME="rezygisk"
MOUNT_DEVICE_NAME="overlay"
FS_TYPE_ALIAS="overlay"
use_ext4_sparse=0
spoof_sparse=0
FAKE_APEX_NAME="com.android.mntservice"
sparse_size="2048"
test_decoy_mount=0
DECOY_MOUNT_FOLDER="/oem"
mountify_expert_mode=0
enable_lkm_nuke=0
lkm_filename="nuke.ko"
nuke_mount_point=""
# read config
PERSISTENT_DIR="/data/adb/rezygisk_meta"
. $PERSISTENT_DIR/config.sh
# exit if disabled
if [ $mountify_mounts = 0 ]; then
        string="description=mode: disabled"
        sed -i "s/^description=.*/$string/g" "$MODDIR/module.prop"
        exit 0
fi

# set prefix
DMESG_PREFIX="rezygisk/post-fs-data"
if [ -f "$MODDIR/metamount.sh" ]; then
        DMESG_PREFIX="rezygisk/metamount"
fi

# single instance run
MOUNTIFY_LOCK="/dev/rezygisk_single_instance"
if [ -f "$MOUNTIFY_LOCK" ]; then
        echo "$DMESG_PREFIX: metamount already ran!" >> /dev/kmsg
        exit 1
fi
touch "$MOUNTIFY_LOCK"

# add simple anti bootloop logic
BOOTCOUNT=0
[ -f "$MODDIR/count.sh" ] && . "$MODDIR/count.sh"

BOOTCOUNT=$(( BOOTCOUNT + 1))

if [ ! -f "$PERSISTENT_DIR/explicit_I_want_a_bootloop" ] && [ $BOOTCOUNT -gt 2 ]; then
        touch $MODDIR/disable
        rm "$MODDIR/count.sh"
        string="description=anti-bootloop triggered. module disabled."
        sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
        exit 1
else
        echo "BOOTCOUNT=$BOOTCOUNT" > "$MODDIR/count.sh"
fi

# grab start time
echo "$DMESG_PREFIX: start!" >> /dev/kmsg

# find MNT_FOLDER
[ -w "/mnt" ] && MNT_FOLDER="/mnt"
[ -w "/mnt/vendor" ] && ! busybox grep -q " /mnt/vendor " "/proc/mounts" && MNT_FOLDER="/mnt/vendor"

# create logging folder
LOG_FOLDER="/dev/rezygisk_logs"
mkdir -p "$LOG_FOLDER"
# log before
cat /proc/mounts > "$LOG_FOLDER/before"

# module mount section
IFS="
"
targets="odm
product
system_ext
vendor
apex
mi_ext
my_bigball
my_carrier
my_company
my_engineering
my_heytap
my_manifest
my_preload
my_product
my_region
my_reserve
my_stock
oem
optics
prism"

decoy_folder_candidates="/oem
/second_stage_resources
/patch_hw
/postinstall
/system_dlkm
/oem_dlkm
/acct
"

# check if fake alias exists, if fail use overlay
if ! grep "nodev" /proc/filesystems | grep -q "$FS_TYPE_ALIAS" > /dev/null 2>&1; then
        FS_TYPE_ALIAS="overlay"
fi

if [ "$test_decoy_mount" = "1" ] && [ ! -f "$MODDIR/no_tmpfs_xattr" ]; then
        # test for decoy mount
        # it needs to be a blank folder
        for dir in $decoy_folder_candidates; do
                if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null | wc -l)" -eq 0 ]; then
                        DECOY_MOUNT_FOLDER="$dir"
                        echo "$DMESG_PREFIX: decoy folder $DECOY_MOUNT_FOLDER" >> /dev/kmsg
                        decoy_mount_enabled="1"
                        break
                fi
        done
fi

# functions

# controlled depth ($targets fuckery)
controlled_depth() {
        if [ -z "$1" ] || [ -z "$2" ]; then return ; fi
        mount_success=0
        for DIR in $(ls -d $1/*/ | sed 's/.$//' ); do
                if [ "$decoy_mount_enabled" = "1" ] && [ -w "$DECOY_MOUNT_FOLDER" ]; then
                        mkdir -p "$DECOY_MOUNT_FOLDER/$2$DIR"
                        busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$DECOY_MOUNT_FOLDER$2$DIR:$(pwd)/$DIR:$2$DIR" "$MOUNT_DEVICE_NAME" "$2$DIR" && mount_success=1
                else
                        busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$(pwd)/$DIR:$2$DIR" "$MOUNT_DEVICE_NAME" "$2$DIR" && mount_success=1
                fi
                [ "$mount_success" = 1 ] && echo "$2$DIR" >> "$LOG_FOLDER/mountify_mount_list"
        done
}

# handle single depth (/system/bin, /system/etc, et. al)
single_depth() {
        mount_success=0
        for DIR in $( ls -d */ | sed 's/.$//'  | grep -vE "^(odm|product|system_ext|vendor)$" 2>/dev/null ); do
                if [ "$decoy_mount_enabled" = "1" ] && [ -w "$DECOY_MOUNT_FOLDER" ]; then
                        mkdir -p "$DECOY_MOUNT_FOLDER/system/$DIR"
                        busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$DECOY_MOUNT_FOLDER/system/$DIR:$(pwd)/$DIR:/system/$DIR" "$MOUNT_DEVICE_NAME" "/system/$DIR" && mount_success=1
                else
                        busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$(pwd)/$DIR:/system/$DIR" "$MOUNT_DEVICE_NAME" "/system/$DIR" && mount_success=1
                fi
                [ "$mount_success" = 1 ] && echo "/system/$DIR" >> "$LOG_FOLDER/mountify_mount_list"
        done
}

# handle getfattr, it is sometimes not symlinked on /system/bin yet toybox has it
if /system/bin/getfattr -d /system/bin > /dev/null 2>&1; then
        getfattr() { /system/bin/getfattr "$@"; }
else
        getfattr() { /system/bin/toybox getfattr "$@"; }
fi

mountify_copy() {
        # return for missing args
        if [ -z "$1" ]; then
                echo "$DMESG_PREFIX: missing arguments" >> /dev/kmsg
                return
        fi

        MODULE_ID="$1"

        # return for certain modules
        if [ "$MODULE_ID" = "De-bloater" ]; then
                echo "$DMESG_PREFIX: module with name $MODULE_ID is blacklisted" >> /dev/kmsg
                return
        fi

        # test for various stuff
        TARGET_DIR="/data/adb/modules/$MODULE_ID"
        if [ ! -d "$TARGET_DIR/system" ] || [ -f "$TARGET_DIR/disable" ] || [ -f "$TARGET_DIR/remove" ] ||
                [ -f "$TARGET_DIR/skip_mountify" ] || [ -f "$TARGET_DIR/system/etc/hosts" ]; then
                echo "$DMESG_PREFIX: module with name $MODULE_ID not meant to be mounted" >> /dev/kmsg
                return
        fi

        # on metamodule mode, we can actually respect skip_mount
        if [ -f "$MODDIR/metamount.sh" ] && [ -f "$TARGET_DIR/skip_mount" ]; then
                echo "$DMESG_PREFIX: module with name $MODULE_ID has skip_mount" >> /dev/kmsg
                return
        fi

        echo "$DMESG_PREFIX: processing $MODULE_ID" >> /dev/kmsg

        # skip_mount is also not needed for litemode APatch
        if { [ "$APATCH_BIND_MOUNT" = "true" ] && [ -f /data/adb/.litemode_enable ]; } ||
                [ -f "$MODDIR/metamount.sh" ]; then
                [ -f "$TARGET_DIR/skip_mount" ] && rm "$TARGET_DIR/skip_mount"
                [ -f "$PERSISTENT_DIR/skipped_modules" ] && rm "$PERSISTENT_DIR/skipped_modules"
        else
                if [ ! -f "$TARGET_DIR/skip_mount" ]; then
                        touch "$TARGET_DIR/skip_mount"
                        echo "$MODULE_ID" >> $PERSISTENT_DIR/skipped_modules
                fi
        fi

        # we can copy over contents of system folder only
        BASE_DIR="/data/adb/modules/$MODULE_ID/system"

        # copy over our files, archive
        cd "$MNT_FOLDER" && cp -af "$BASE_DIR"/* "$FAKE_MOUNT_NAME"

        # go inside
        cd "$MNT_FOLDER/$FAKE_MOUNT_NAME"

        # make sure to mirror selinux context
        for file in $( busybox find -L $BASE_DIR | sed "s|$BASE_DIR||g" ) ; do
                busybox chcon --reference="$BASE_DIR$file" "$MNT_FOLDER/$FAKE_MOUNT_NAME$file"
        done

        # catch opaque dirs, requires getfattr
        for dir in $( busybox find -L $BASE_DIR -type d ) ; do
                if getfattr -d "$dir" | grep -q "trusted.overlay.opaque" ; then
                        opaque_dir=$(echo "$dir" | sed "s|$BASE_DIR|.|")
                        busybox setfattr -n trusted.overlay.opaque -v y "$opaque_dir"
                fi
        done

        # if it reached here, module probably copied, log it
        echo "$MODULE_ID" >> "$LOG_FOLDER/modules"
}

# prevent this fuckup since on expert mode this isnt checked
if [ "$FAKE_MOUNT_NAME" = "persist" ]; then
        echo "$DMESG_PREFIX: folder name named $FAKE_MOUNT_NAME is not allowed!" >> /dev/kmsg
        exit 1
fi

# make sure its not there
if [ ! "$mountify_expert_mode" = 1 ] && [ -d "$MNT_FOLDER/$FAKE_MOUNT_NAME" ]; then
        echo "$DMESG_PREFIX: exiting since fake folder name $FAKE_MOUNT_NAME already exists!" >> /dev/kmsg
        exit 1
fi

# lets also mount our own /mnt folder
# so hierarchy becomes
# stage1 /mnt or /mnt/vendor always tmpfs
# stage2 /mnt/fake_folder_name or /mnt/vendor/fake_folder_name is either tmpfs or ext4
if [ -d "$MNT_FOLDER" ]; then
        echo "$DMESG_PREFIX: stage1: mounting $(realpath "$MNT_FOLDER")" >> /dev/kmsg

        # mount and test, if it fails fuck it, we bail
        if ! busybox mount -t tmpfs tmpfs "$(realpath "$MNT_FOLDER")"; then
                echo "$DMESG_PREFIX: mounting $MNT_FOLDER fail! bail out!" >> /dev/kmsg
                exit 1
        fi

fi

# create it
mkdir -p "$MNT_FOLDER/$FAKE_MOUNT_NAME"
if [ ! -f "$MODDIR/no_tmpfs_xattr" ] && [ ! "$use_ext4_sparse" = "1" ]; then
        echo "$DMESG_PREFIX: stage2/tmpfs: mounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")" >> /dev/kmsg
        busybox mount -t tmpfs tmpfs "$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
fi
touch "$MNT_FOLDER/$FAKE_MOUNT_NAME/placeholder"

# then make sure its there
if [ ! -d "$MNT_FOLDER/$FAKE_MOUNT_NAME" ]; then
        echo "$DMESG_PREFIX: failed creating folder with fake_folder_name $FAKE_MOUNT_NAME !" >> /dev/kmsg
        exit 1
fi

if [ "$decoy_mount_enabled" = "1" ] && [ -d "$DECOY_MOUNT_FOLDER" ] && [ "$(ls -A "$DECOY_MOUNT_FOLDER" 2>/dev/null | wc -l)" -eq 0 ]; then
        echo "$DMESG_PREFIX: mounting $DECOY_MOUNT_FOLDER" >> /dev/kmsg
        mount -t tmpfs tmpfs "$DECOY_MOUNT_FOLDER"
fi

if [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; then
        # create sparse ext4 image
        busybox dd if=/dev/zero of="$MNT_FOLDER/rezygisk-ext4" bs=1M count=0 seek="$sparse_size"
        /system/bin/mkfs.ext4 -O ^has_journal "$MNT_FOLDER/rezygisk-ext4"

        [ "$KSU" = "true" ] && busybox chcon "u:object_r:ksu_file:s0" "$MNT_FOLDER/rezygisk-ext4"

        echo "$DMESG_PREFIX: stage2/ext4: mounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")" >> /dev/kmsg
        busybox mount -o loop,rw,noatime,nodiratime "$MNT_FOLDER/rezygisk-ext4" "$MNT_FOLDER/$FAKE_MOUNT_NAME"
fi

# if manual mode and modules.txt has contents
if [ $mountify_mounts = 1 ] && grep -qv "#" "$PERSISTENT_DIR/modules.txt" >/dev/null 2>&1 ; then
        # manual mode
        for line in $( sed '/#/d' "$PERSISTENT_DIR/modules.txt" ); do
                module_id=$( echo $line | awk {'print $1'} )
                mountify_copy "$module_id"
        done
else
        # auto mode — mount all modules that have system/ dirs
        for module in /data/adb/modules/*/system; do
                module_id="$(echo $module | cut -d / -f 5 )"
                mountify_copy "$module_id"
        done
fi

if [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; then
        # unmount and remount ext4 image as ro
        busybox umount -l "$MNT_FOLDER/$FAKE_MOUNT_NAME"

        echo "$DMESG_PREFIX: stage2/ext4: remounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")" >> /dev/kmsg

        if [ "$spoof_sparse" = "1" ] && [ -w "/apex" ] && [ ! -e "/apex/$FAKE_APEX_NAME" ]; then
                mkdir -p "/apex/$FAKE_APEX_NAME@1"
                busybox mount -o loop,ro,dirsync,seclabel,nodev,noatime "$MNT_FOLDER/rezygisk-ext4" "/apex/$FAKE_APEX_NAME@1"
                mkdir -p "/apex/$FAKE_APEX_NAME"
                busybox mount --bind,ro "/apex/$FAKE_APEX_NAME@1" "/apex/$FAKE_APEX_NAME"
                rm -rf "$MNT_FOLDER/$FAKE_MOUNT_NAME"
                busybox ln -sf "/apex/$FAKE_APEX_NAME" "$MNT_FOLDER/$FAKE_MOUNT_NAME"
        else
                busybox mount -o loop,ro,noatime,nodiratime "$MNT_FOLDER/rezygisk-ext4" "$MNT_FOLDER/$FAKE_MOUNT_NAME"
        fi

fi

# mount
cd "$MNT_FOLDER/$FAKE_MOUNT_NAME"
single_depth
# handle this stance when /product is a symlink to /system/product
for folder in $targets ; do
        # reset cwd due to loop
        cd "$MNT_FOLDER/$FAKE_MOUNT_NAME"
        if [ -L "/$folder" ] && [ ! -L "/system/$folder" ]; then
                # legacy, so we mount at /system
                controlled_depth "$folder" "/system/"
        else
                # modern, so we mount at root
                controlled_depth "$folder" "/"
        fi
done

if [ "$decoy_mount_enabled" = "1" ] && [ -d "$DECOY_MOUNT_FOLDER" ]; then
        echo "$DMESG_PREFIX: unmounting $DECOY_MOUNT_FOLDER" >> /dev/kmsg
        busybox umount -l "$DECOY_MOUNT_FOLDER"
fi

# insmod compat
if command -v /system/bin/insmod > /dev/null 2>&1; then
        insmod() { /system/bin/insmod "$@"; }
else
        insmod() { busybox insmod "$@"; }
fi

# nuke ext4 sysfs
ko_loaded=0
if [ ! -f "$MODDIR/ksud_has_nuke_ext4" ] && [ $enable_lkm_nuke = 1 ] && [ -f "$MODDIR/lkm/$lkm_filename" ] &&
        { [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; } &&
        [ "$spoof_sparse" = "0" ]; then

        # Determine which ext4 mount to nuke. If nuke_mount_point is set in
        # config.sh, use it; otherwise auto-detect the staging mount.
        if [ -n "$nuke_mount_point" ]; then
                mnt="$nuke_mount_point"
        else
                mnt="$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
        fi
        kptr_set=$(cat /proc/sys/kernel/kptr_restrict)
        echo 1 > /proc/sys/kernel/kptr_restrict
        ptr_address=$(grep " ext4_unregister_sysfs$" /proc/kallsyms | awk {'print "0x"$1'})
        echo "$DMESG_PREFIX: stage2/ext4: loading LKM with mount_point=$mnt symaddr=$ptr_address" >> /dev/kmsg
        if insmod "$MODDIR/lkm/$lkm_filename" mount_point="$mnt" symaddr="$ptr_address" 2>>"$LOG_FOLDER/nuke_err"; then
                ko_loaded=1
                echo "$DMESG_PREFIX: stage2/ext4: LKM loaded, nuked $mnt" >> /dev/kmsg
        else
                echo "$DMESG_PREFIX: stage2/ext4: LKM load FAILED for $mnt" >> /dev/kmsg
        fi
        echo $kptr_set > /proc/sys/kernel/kptr_restrict

fi

# ksud kernel nuke-ext4-sysfs
if [ -f "$MODDIR/ksud_has_nuke_ext4" ] && [ "$spoof_sparse" = "0" ] &&
        { [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; }; then

        if [ -n "$nuke_mount_point" ]; then
                mnt="$nuke_mount_point"
        else
                mnt="$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
        fi
        echo "$DMESG_PREFIX: stage2/ext4: ksud kernel nuke-ext4-sysfs $mnt" >> /dev/kmsg
        if /data/adb/ksud kernel nuke-ext4-sysfs "$mnt" 2>>"$LOG_FOLDER/nuke_err"; then
                ko_loaded=1
        fi

fi

# unmount stage2
if [ "$spoof_sparse" = "0" ]; then
        echo "$DMESG_PREFIX: stage2: unmounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")" >> /dev/kmsg
        busybox umount -l "$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
fi

# delete the sparse
if [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; then
        [ -f "$MNT_FOLDER/rezygisk-ext4" ] && rm "$MNT_FOLDER/rezygisk-ext4"
fi

# unmount stage1
echo "$DMESG_PREFIX: stage1: unmounting $(realpath "$MNT_FOLDER")" >> /dev/kmsg
busybox umount -l "$MNT_FOLDER"

# handle operating mode
case $mountify_mounts in
        1) mode="manual" ;;
        2) mode="auto" ;;
        *) mode="disabled" ;;
esac

if [ "$use_ext4_sparse" = "1" ] || [ -f "$MODDIR/no_tmpfs_xattr" ]; then
        staging_mode="ext4"
else
        staging_mode="tmpfs"
fi

# combined mode string for module.prop description
mode_full="$mode | $staging_mode"

# display if on litemode
if [ "$APATCH_BIND_MOUNT" = "true" ] && [ -f /data/adb/.litemode_enable ]; then
        mode_full="$mode_full | litemode"
fi

# generate description accordingly
string="description=mode: $mode_full | no modules mounted"
if [ -f $LOG_FOLDER/modules ]; then
        module_list=$( for module in $(cat "$LOG_FOLDER/modules" ) ; do printf "$module " ; done )
        string="description=mode: $mode_full | modules: $module_list "
fi

# only update when generated string is different
desc_current=$(grep "^description=" "$MODDIR/module.prop")
if [ "$desc_current" != "$string" ]; then
        sed -i "s/^description=.*/$string/g" "$MODDIR/module.prop"
fi

# write status file for WebUI — separate fields so the UI can display each
# independently (e.g. "auto (ext4)" on the home page, ko status, etc.)
STATUS=/data/adb/.rz_meta_status
cat > "$STATUS" <<RASTATS
configured_mode=$mountify_mounts
effective_mode=$mode
staging_mode=$staging_mode
ko_enabled=$enable_lkm_nuke
ko_loaded=$ko_loaded
ko_mount_point=$mnt
source=${KSU:+KSU}${APATCH:+APatch}
mounted_partitions=$(cat "$LOG_FOLDER/mountify_mount_list" 2>/dev/null | tr '\n' ' ')
RASTATS

# log after
cat /proc/mounts > "$LOG_FOLDER/after"
echo "$DMESG_PREFIX: finished!" >> /dev/kmsg

# EOF
