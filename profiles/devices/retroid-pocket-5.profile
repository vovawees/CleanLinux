# shellcheck shell=bash
inherit base
PROFILE_DESC="Retroid Pocket 5 / Mini: Snapdragon 865 (4x Cortex-A77 + 4x Cortex-A55), Adreno 650"
CARCH=aarch64
# the A55 cores share the A77 instruction set (Armv8.2 + dotprod, fp16, rcpc)
CPU_FLAGS="-mcpu=cortex-a77"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" handheld battery"
