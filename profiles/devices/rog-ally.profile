# shellcheck shell=bash
inherit base
PROFILE_DESC="ASUS ROG Ally / Ally X: AMD Ryzen Z1 (Zen 4), RDNA 3 graphics"
CARCH=x86_64
CPU_FLAGS="-march=znver4 -mtune=znver4"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" gaming handheld battery"
