# shellcheck shell=bash
inherit base
PROFILE_DESC="MSI Claw 7 AI+ / 8 AI+: Intel Core Ultra 7 258V (Lunar Lake), Intel Arc 140V (Xe2)"
CARCH=x86_64
CPU_FLAGS="-march=lunarlake -mtune=lunarlake"
VIDEO_CARDS=intel
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Lunar Lake GPU (xe) and display (DMC), Intel BE201 Wi-Fi 7 (iwlwifi bz) + Bluetooth
FIRMWARE="xe/lnl_ i915/xe2lpd_dmc iwlwifi-bz- intel/iwlwifi/iwlwifi-bz intel/ibt-0291 intel/ibt-0190 intel/ibt-0040"
# the device's own kernel options and quirks: profiles/devices/msi-claw-ai-plus/ (see HARDWARE.md)
KERNEL_FRAGMENT="$PROFILE_DIR/msi-claw-ai-plus/kernel.config"
