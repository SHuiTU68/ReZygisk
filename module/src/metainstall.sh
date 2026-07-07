#!/system/bin/sh

# Hrezygisk metamodule install hook.
#
# This script is *sourced* by the KernelSU/APatch built-in installer right
# after a regular module's files are extracted but before installation
# completes. It inherits all installer variables/functions (MODPATH, TMPDIR,
# ui_print, install_module, ...).
#
# Hrezygisk does not need to customize how regular modules are installed — the
# stock installer already lays files out under $MODPATH/system exactly the way
# metamount.sh expects. We therefore simply delegate to the built-in installer.
#
# We keep the hook present (rather than omitting it) so that future
# customization (e.g. validating module compatibility, logging) has a natural
# place to live without re-adding the file.

# INFO: Call the built-in installation process. This performs the standard
# module layout that metamount.sh scans at boot.
install_module
