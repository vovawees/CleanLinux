# shellcheck shell=bash
inherit base
PROFILE_DESC="ASUS ROG Ally / Ally X: AMD Ryzen Z1 (Zen 4), RDNA 3 graphics"
CARCH=x86_64
CPU_FLAGS="-march=znver4 -mtune=znver4"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Phoenix GPU (GC 11.0.1), MediaTek MT7922 Wi-Fi + Bluetooth, Cirrus CS35L41 amps (subsystem 1043:17f3)
FIRMWARE="amdgpu/gc_11_0_1 amdgpu/psp_13_0_4 amdgpu/dcn_3_1_4 amdgpu/vcn_4_0_2 amdgpu/sdma_6_0_1 amdgpu/vpe_6_1 amd-ucode/ mediatek/WIFI_MT7922 mediatek/WIFI_RAM_CODE_MT7922 mediatek/BT_RAM_CODE_MT7922 cirrus/cs35l41-dsp1-spk-prot-104317f3"
# the device's own kernel options and quirks: profiles/devices/rog-ally/ (see HARDWARE.md)
KERNEL_FRAGMENT="$PROFILE_DIR/rog-ally/kernel.config"
