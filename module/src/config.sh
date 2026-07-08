# config.sh — rezygisk metamount configuration
# Ported from mountify (https://github.com/backslashxx/mountify)
# This file is sourced by metamount.sh on every boot.
# Lines starting with # are comments.

# mountify_mounts:
#   0 = disabled (no mounting)
#   1 = manual mode (only modules listed in modules.txt are mounted)
#   2 = auto mode (all modules with system/ dirs are mounted)
mountify_mounts=2

# FAKE_MOUNT_NAME: the staging folder name under /mnt or /mnt/vendor
FAKE_MOUNT_NAME="rezygisk"

# MOUNT_DEVICE_NAME / FS_TYPE_ALIAS: overlay mount source name
MOUNT_DEVICE_NAME="overlay"
FS_TYPE_ALIAS="overlay"

# use_ext4_sparse: 1 = use ext4 sparse image instead of tmpfs for staging
use_ext4_sparse=0

# spoof_sparse: 1 = mount ext4 image as fake apex (advanced stealth)
spoof_sparse=0

# sparse_size: ext4 image size in MB (only used if use_ext4_sparse=1)
sparse_size="2048"

# test_decoy_mount: 1 = test for decoy mount folder
test_decoy_mount=0

# DECOY_MOUNT_FOLDER: folder to use as decoy
DECOY_MOUNT_FOLDER="/oem"

# mountify_expert_mode: 1 = skip safety checks (dangerous)
mountify_expert_mode=0

# enable_lkm_nuke: 1 = load nuke.ko to unregister ext4 sysfs node
enable_lkm_nuke=0

# lkm_filename: name of the LKM file
lkm_filename="nuke.ko"
