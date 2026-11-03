# shellcheck shell=bash
inherit base
PROFILE_DESC="Valve Steam Deck LCD/OLED: AMD Zen 2 APU, RDNA 2 graphics"
CARCH=x86_64
CPU_FLAGS="-march=znver2 -mtune=znver2"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" gaming handheld battery"
