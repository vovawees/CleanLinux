# shellcheck shell=bash
inherit base
PROFILE_DESC="MSI Claw A1M: Intel Core Ultra 5 135H / 7 155H (Meteor Lake), Intel Arc graphics"
CARCH=x86_64
CPU_FLAGS="-march=meteorlake -mtune=meteorlake"
VIDEO_CARDS=intel
PROFILE_FEATURES+=" gaming handheld battery"
