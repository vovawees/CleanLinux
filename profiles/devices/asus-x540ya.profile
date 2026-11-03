# shellcheck shell=bash
inherit base
PROFILE_DESC="ASUS X540YA: AMD E2-6110 (Puma, family 16h), Radeon R2 (GCN 1.1)"
CARCH=x86_64
CPU_FLAGS="-march=btver2 -mtune=btver2"
VIDEO_CARDS=amd
PROFILE_FEATURES+=" battery"
# GCN 1.1 (CIK) runs better on amdgpu than on radeon, and gets Vulkan (RADV)
KERNEL_CMDLINE="amdgpu.cik_support=1 radeon.cik_support=0"
