# shellcheck shell=bash
inherit base
PROFILE_DESC="Valve Steam Deck LCD/OLED: AMD Zen 2 APU, RDNA 2 graphics"
CARCH=x86_64
CPU_FLAGS="-march=znver2 -mtune=znver2"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# LCD: Realtek RTL8822CE Wi-Fi + Bluetooth; OLED: Qualcomm QCA2066 (ath11k); Cirrus CS35L41 speaker amps
FIRMWARE="amdgpu/vangogh_ amd-ucode/ rtw88/rtw8822c rtl_bt/rtl8822c ath11k/QCA2066 qca/hpbtfw21 qca/hpnv21 cirrus/cs35l41-dsp1-spk-prot."
