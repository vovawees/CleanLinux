# shellcheck shell=bash
# Defaults shared by every profile (`inherit base`).
# A profile describes hardware only: CPU, GPU, kernel and hardware features (handheld, battery, ...).
# The software stack (wayland, x11, pipewire, pulseaudio, ...) is not chosen here: spins and
# /etc/burn/burn.conf choose it. Features apply only to recipes that declare them (burn info <pkg>).
PROFILE_DESC="Shared defaults"
PROFILE_FEATURES="nls -doc -debug"
