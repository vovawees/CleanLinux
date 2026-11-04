# shellcheck shell=bash
inherit base
PROFILE_DESC="RK3566 handhelds (Anbernic RG353/RG503, PowKiddy...): 4x Cortex-A55, Mali-G52"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a55"
VIDEO_CARDS=panfrost
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# the RTL8821CS Wi-Fi + Bluetooth of most RK3566 handhelds
FIRMWARE="rtw88/rtw8821c rtl_bt/rtl8821c"
# U-Boot boots extlinux/extlinux.conf from the boot partition; it takes its own device tree
# ($fdtfile, e.g. rockchip/rk3566-anbernic-rg353p.dtb) from the rockchip/ directory of the kernel
BOOTLOADER=extlinux
DEVICE_TREE=rockchip/
