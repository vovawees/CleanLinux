# shellcheck shell=bash
inherit base
PROFILE_DESC="Any 64-bit ARM board or handheld (ARMv8.0-A), for portable images"
CARCH=aarch64
CPU_FLAGS="-march=armv8-a"
VIDEO_CARDS="freedreno panfrost v3d lima etnaviv virgl"
