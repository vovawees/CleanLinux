# shellcheck shell=bash
# Defaults shared by every profile (`inherit base`).
# Features are only applied to recipes that declare them (see: broom info <pkg>).
PROFILE_DESC="Shared defaults"
PROFILE_FEATURES="wayland vulkan opengl pipewire nls -x11 -pulseaudio -doc -debug"
