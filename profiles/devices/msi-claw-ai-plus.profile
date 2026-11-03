# shellcheck shell=bash
inherit base
PROFILE_DESC="MSI Claw 7 AI+ / 8 AI+: Intel Core Ultra 7 258V (Lunar Lake), Intel Arc 140V (Xe2)"
CARCH=x86_64
CPU_FLAGS="-march=lunarlake -mtune=lunarlake"
VIDEO_CARDS=intel
PROFILE_FEATURES+=" handheld battery"
