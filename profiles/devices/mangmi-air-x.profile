# shellcheck shell=bash
inherit base
PROFILE_DESC="Mangmi Air X: Snapdragon 662 (SM6115, 4x Cortex-A73 + 4x Cortex-A53), Adreno 610"
CARCH=aarch64
# big.LITTLE tuning plus the Cortex-A53 errata workarounds
CPU_FLAGS="-mcpu=cortex-a73.cortex-a53 -mfix-cortex-a53-835769 -mfix-cortex-a53-843419"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Adreno 610 (a630 microcode) and the SM6115 DSPs (QRB4210 is the same SoC), WCN3990 Wi-Fi (ath10k) + Bluetooth
FIRMWARE="qcom/a630_sqe qcom/qrb4210/ ath10k/WCN3990 qca/crbtfw qca/crnv"
# mainline Snapdragon kernels still lack drivers for some clocks and power domains: keep them on
KERNEL_CMDLINE="clk_ignore_unused pd_ignore_unused"
