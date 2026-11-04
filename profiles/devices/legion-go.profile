# shellcheck shell=bash
# the same APU as the ROG Ally (Z1 Extreme)
inherit rog-ally
PROFILE_DESC="Lenovo Legion Go: AMD Ryzen Z1 Extreme (Zen 4), Radeon 780M (RDNA 3)"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Phoenix GPU (GC 11.0.1), MediaTek MT7922 Wi-Fi + Bluetooth, Cirrus CS35L41 amps (subsystem 17aa:38b*)
FIRMWARE="amdgpu/gc_11_0_1 amdgpu/psp_13_0_4 amdgpu/dcn_3_1_4 amdgpu/vcn_4_0_2 amdgpu/sdma_6_0_1 amdgpu/vpe_6_1 amd-ucode/ mediatek/WIFI_MT7922 mediatek/WIFI_RAM_CODE_MT7922 mediatek/BT_RAM_CODE_MT7922 cirrus/cs35l41-dsp1-spk-prot-17aa38b"
# the device's own kernel options and quirks: profiles/devices/legion-go/ (see HARDWARE.md)
KERNEL_FRAGMENT="$PROFILE_DIR/legion-go/kernel.config"
