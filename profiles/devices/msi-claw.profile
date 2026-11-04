# shellcheck shell=bash
inherit base
PROFILE_DESC="MSI Claw A1M: Intel Core Ultra 5 135H / 7 155H (Meteor Lake), Intel Arc graphics"
CARCH=x86_64
CPU_FLAGS="-march=meteorlake -mtune=meteorlake"
VIDEO_CARDS=intel
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Meteor Lake GPU (i915), Intel BE200/AX211-class Wi-Fi (iwlwifi gl) + Bluetooth
FIRMWARE="i915/mtl_ iwlwifi-gl- intel/iwlwifi/iwlwifi-gl intel/ibt-0291"
# the device's own kernel options and quirks: profiles/devices/msi-claw/ (see HARDWARE.md)
KERNEL_FRAGMENT="$PROFILE_DIR/msi-claw/kernel.config"
