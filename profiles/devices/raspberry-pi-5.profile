# shellcheck shell=bash
inherit base
PROFILE_DESC="Raspberry Pi 5: BCM2712 (4x Cortex-A76), VideoCore VII"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a76"
VIDEO_CARDS=v3d
