# shellcheck shell=bash
inherit base
PROFILE_DESC="ASUS ROG Xbox Ally X, Lenovo Legion Go 2: AMD Ryzen AI Z2 Extreme (Zen 5), Radeon 890M (RDNA 3.5)"
CARCH=x86_64
CPU_FLAGS="-march=znver5 -mtune=znver5"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" handheld battery"
