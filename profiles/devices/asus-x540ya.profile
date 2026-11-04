# shellcheck shell=bash
inherit base
PROFILE_DESC="ASUS X540YA: AMD E2-6110 (Puma, family 16h), Radeon R2 (GCN 1.1)"
CARCH=x86_64
CPU_FLAGS="-march=btver2 -mtune=btver2"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" battery"
# GCN 1.1 (CIK) runs better on amdgpu than on radeon, and gets Vulkan (RADV)
KERNEL_CMDLINE="amdgpu.cik_support=1 radeon.cik_support=0"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Mullins GPU (amdgpu or radeon), Wi-Fi + Bluetooth of the shipped variants: RTL8821CE, QCA9377, older Realtek
FIRMWARE="amdgpu/mullins radeon/mullins amd-ucode/ rtw88/rtw8821c rtl_bt/rtl8821c ath10k/QCA9377 rtlwifi/"
