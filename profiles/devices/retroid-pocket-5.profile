# shellcheck shell=bash
inherit base
PROFILE_DESC="Retroid Pocket 5 / Mini: Snapdragon 865 (4x Cortex-A77 + 4x Cortex-A55), Adreno 650"
CARCH=aarch64
# the A55 cores share the A77 instruction set (Armv8.2 + dotprod, fp16, rcpc)
CPU_FLAGS="-mcpu=cortex-a77"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" handheld battery"
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# Adreno 650 and the SM8250 DSPs, QCA6390 Wi-Fi (ath11k) + Bluetooth
FIRMWARE="qcom/a650 qcom/sm8250/ ath11k/QCA6390 qca/htbtfw20 qca/htnv20"
# mainline Snapdragon kernels still lack drivers for some clocks and power domains: keep them on
KERNEL_CMDLINE="clk_ignore_unused pd_ignore_unused"
