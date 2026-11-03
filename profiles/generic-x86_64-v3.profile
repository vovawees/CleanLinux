# shellcheck shell=bash
inherit base
PROFILE_DESC="Modern x86-64 PCs (x86-64-v3: AVX2, FMA, BMI2): Intel Haswell+, AMD Zen+; not Atom/Celeron"
CARCH=x86_64
CPU_FLAGS="-march=x86-64-v3 -mtune=generic"
VIDEO_CARDS="amd intel nouveau virgl"
