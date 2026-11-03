# shellcheck shell=bash
inherit base
PROFILE_DESC="Lenovo Legion Go S: AMD Ryzen Z2 Go (Zen 3+), Radeon 680M (RDNA 2)"
CARCH=x86_64
CPU_FLAGS="-march=znver3 -mtune=znver3"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" handheld battery"
