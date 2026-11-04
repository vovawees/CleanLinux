# shellcheck shell=bash
inherit base
PROFILE_DESC="Lenovo Legion Go S: AMD Ryzen Z2 Go (Zen 3+), Radeon 680M (RDNA 2)"
CARCH=x86_64
CPU_FLAGS="-march=znver3 -mtune=znver3"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Z2 Go is Rembrandt (yellow_carp) or Phoenix silicon depending on the batch; MediaTek MT7922 Wi-Fi + Bluetooth
FIRMWARE="amdgpu/yellow_carp amdgpu/gc_11_0_1 amdgpu/psp_13_0_4 amdgpu/dcn_3_1_4 amdgpu/vcn_4_0_2 amdgpu/sdma_6_0_1 amdgpu/vpe_6_1 amd-ucode/ mediatek/WIFI_MT7922 mediatek/WIFI_RAM_CODE_MT7922 mediatek/BT_RAM_CODE_MT7922"
