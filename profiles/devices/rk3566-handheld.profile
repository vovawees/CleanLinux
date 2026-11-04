# shellcheck shell=bash
inherit base
PROFILE_DESC="RK3566 handhelds (Anbernic RG353/RG503, PowKiddy...): 4x Cortex-A55, Mali-G52"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a55"
VIDEO_CARDS=panfrost
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Wi-Fi + Bluetooth: RTL8821CS (Anbernic, PowKiddy RGB30, RK2023, X55) or RTL8723DS (RGB10MAX3, RGB20SX)
FIRMWARE="rtw88/rtw8821c rtl_bt/rtl8821c rtw88/rtw8723d rtl_bt/rtl8723d"
# the device's own kernel options and quirks: profiles/devices/rk3566-handheld/ (see HARDWARE.md)
KERNEL_FRAGMENT="$PROFILE_DIR/rk3566-handheld/kernel.config"
QUIRKS="$PROFILE_DIR/rk3566-handheld/quirks"
# U-Boot boots extlinux/extlinux.conf from the boot partition; it takes its own device tree
# ($fdtfile, e.g. rockchip/rk3566-anbernic-rg353p.dtb) from the rockchip/ directory of the kernel
BOOTLOADER=extlinux
DEVICE_TREE=rockchip/
