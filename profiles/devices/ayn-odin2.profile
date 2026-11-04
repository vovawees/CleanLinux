# shellcheck shell=bash
inherit base
PROFILE_DESC="AYN Odin 2 / Mini / Portal: Snapdragon 8 Gen 2 (Cortex-X3, A715, A710, A510), Adreno 740"
CARCH=aarch64
# Armv9 cores; SVE2 and MTE are left out: Snapdragon firmware does not reliably expose them
CPU_FLAGS="-march=armv8.6-a+fp16fml -mtune=cortex-a715"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Adreno 740 and the SM8550 DSPs, WCN7850 Wi-Fi 7 (ath12k) + Bluetooth
FIRMWARE="qcom/gmu_gen70200 qcom/a740 qcom/sm8550/ ath12k/WCN7850 qca/hmtbtfw20 qca/hmtnv20"
# the device's own kernel options and quirks: profiles/devices/ayn-odin2/ (see HARDWARE.md)
KERNEL_FRAGMENT="$PROFILE_DIR/ayn-odin2/kernel.config"
# mainline Snapdragon kernels still lack drivers for some clocks and power domains: keep them on
KERNEL_CMDLINE="clk_ignore_unused pd_ignore_unused"
# ABL (the Android boot loader) boots an Android boot image from the boot partition:
# cleanlinux-boot builds it (header 2, page size 4096) and flashes it with android.partition=.
# The device tree of the board is not in the mainline kernel yet: devicetree=/path/to/board.dtb in
# /etc/cleanlinux/boot.d (an absolute path inside the root)
BOOTLOADER=android
