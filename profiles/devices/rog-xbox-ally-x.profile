# shellcheck shell=bash
inherit base
PROFILE_DESC="ASUS ROG Xbox Ally X, Lenovo Legion Go 2: AMD Ryzen AI Z2 Extreme (Zen 5), Radeon 890M (RDNA 3.5)"
CARCH=x86_64
CPU_FLAGS="-march=znver5 -mtune=znver5"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Strix Point GPU (GC 11.5.0), MediaTek MT7925 Wi-Fi + Bluetooth
FIRMWARE="amdgpu/gc_11_5_0 amdgpu/psp_14_0_0 amdgpu/dcn_3_5_dmcub amdgpu/vcn_4_0_5 amdgpu/sdma_6_1_0 amdgpu/vpe_6_1 amd-ucode/ mediatek/mt7925"
