#!/system/bin/sh

# Hrezygisk metamodule uninstall hook.
#
# Called by KernelSU/APatch when a regular module is uninstalled, before its
# module directory is removed. $1 is the MODULE_ID being uninstalled.
#
# metamount.sh rebuilds its overlay upperdirs from scratch on every boot by
# scanning /data/adb/modules/*, so a removed module's files naturally stop
# being merged on the next boot. There is no per-module persistent state in
# /data/adb/rezygisk/.rw to clean up here.
#
# This hook exists mainly as a no-op placeholder so the metamodule contract is
# complete and future cleanup logic has a home. We intentionally do NOT wipe
# .rw/* here: that would invalidate the upperdirs of all *other* still-installed
# modules mid-boot-cycle, and the next metamount.sh run rebuilds everything
# anyway.

MODULE_ID="$1"
# shellcheck disable=SC2034
MODULE_ID="$MODULE_ID"  # referenced for clarity; intentionally unused.

exit 0
