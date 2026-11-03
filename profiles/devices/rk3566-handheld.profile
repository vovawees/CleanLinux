# shellcheck shell=bash
inherit base
PROFILE_DESC="RK3566 handhelds (Anbernic RG353/RG503, PowKiddy...): 4x Cortex-A55, Mali-G52"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a55"
VIDEO_CARDS=panfrost
PROFILE_FEATURES+=" handheld battery"
