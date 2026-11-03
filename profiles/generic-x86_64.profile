# shellcheck shell=bash
inherit base
PROFILE_DESC="Any x86-64 PC since ~2009 (x86-64-v2), for portable images"
CARCH=x86_64
CPU_FLAGS="-march=x86-64-v2 -mtune=generic"
VIDEO_CARDS="amd intel nouveau virgl"
