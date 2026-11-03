# shellcheck shell=bash
inherit base
PROFILE_DESC="This machine: -march/-mcpu=native and detected GPU (binaries may not run elsewhere)"
CARCH=$HOST_ARCH
CPU_FLAGS=native
VIDEO_CARDS=$HOST_VIDEO_CARDS
