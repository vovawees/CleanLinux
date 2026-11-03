# shellcheck shell=bash
inherit base
PROFILE_DESC="This machine: -march/-mcpu=native and detected GPU (binaries may not run elsewhere)"
CARCH=$(uname -m)
CPU_FLAGS=native
VIDEO_CARDS=$(detect_video_cards)
