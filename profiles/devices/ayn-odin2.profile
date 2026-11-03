# shellcheck shell=bash
inherit base
PROFILE_DESC="AYN Odin 2 / Mini / Portal: Snapdragon 8 Gen 2 (Cortex-X3, A715, A710, A510), Adreno 740"
CARCH=aarch64
# Armv9 cores; SVE2 and MTE are left out: Snapdragon firmware does not reliably expose them
CPU_FLAGS="-march=armv8.6-a+fp16fml -mtune=cortex-a715"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" gaming handheld battery"
