#!/usr/bin/env bash
# CleanLinux bootstrap: build the system from source, from nothing but a host compiler.
#
#   toolchain  cross binutils -> gcc (pass 1) -> kernel headers -> glibc -> gcc (final)
#   base       the base system, cross-compiled and installed by broom into the rootfs
#   image      broom inside the rootfs, chroot/qemu test, rootfs tarball
#
# The rootfs doubles as the toolchain sysroot, so every package is built against the exact
# glibc it will run with. Nothing from the host ends up in the image.
#
# Usage: bootstrap/bootstrap.sh [--arch x86_64|aarch64] [--profile NAME] [--work DIR]
#                               [--recipes DIR] [-j N] [-v] [stage...]
set -euo pipefail
shopt -s nullglob

HERE=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
TOP=$(cd "$HERE/.." && pwd)
BROOM_BIN=$TOP/broom/broom
# shellcheck source=bootstrap/lib.sh
. "$HERE/lib.sh"

ARCH='' PROFILE='' WORK='' RECIPES=${BROOM_RECIPES:-} JOBS=$(nproc) VERBOSE=0
STAGES=()
while (($#)); do
	case $1 in
		--arch) ARCH=${2:?} && shift 2 ;;
		--profile) PROFILE=${2:?} && shift 2 ;;
		--work) WORK=${2:?} && shift 2 ;;
		--recipes) RECIPES=${2:?} && shift 2 ;;
		-j) JOBS=${2:?} && shift 2 ;;
		-v) VERBOSE=1 && shift ;;
		-h | --help)
			sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		toolchain | base | image | all) STAGES+=("$1") && shift ;;
		*) die "unknown argument: $1" ;;
	esac
done
((${#STAGES[@]})) || STAGES=(all)

if [[ -z $ARCH && -n $PROFILE ]]; then
	ARCH=$(BROOM_RECIPES='' "$BROOM_BIN" -p "$PROFILE" profile show | awk '$1 == "chost" { split($2, a, "-"); print a[1] }')
fi
ARCH=${ARCH:-$(uname -m)}
case $ARCH in
	x86_64) KARCH=x86 LOADER=/lib64/ld-linux-x86-64.so.2 ;;
	aarch64) KARCH=arm64 LOADER=/lib/ld-linux-aarch64.so.1 ;;
	*) die "unsupported architecture: $ARCH (x86_64 or aarch64)" ;;
esac
PROFILE=${PROFILE:-generic-$ARCH}
TRIPLE=$ARCH-cleanlinux-linux-gnu
WORK=$(readlink -m "${WORK:-$TOP/build/$ARCH}")
TOOLS=$WORK/tools ROOTFS=$WORK/rootfs SRCDIR=$WORK/src OBJ=$WORK/obj LOGS=$WORK/logs STAMPS=$WORK/stamps
export BROOM_CACHE=${BROOM_CACHE:-$TOP/build/cache}
export PATH=$TOOLS/bin:$PATH LC_ALL=C
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CC CXX
if [[ -z $RECIPES ]]; then
	for d in "$TOP/../CleanLinux-Recipes/packages" "$WORK/recipes/packages"; do
		if [[ -d $d ]]; then RECIPES=$d && break; fi
	done
fi
if [[ -z $RECIPES ]]; then
	git clone -q --depth 1 https://github.com/vovawees/CleanLinux-Recipes.git "$WORK/recipes"
	RECIPES=$WORK/recipes/packages
fi
RECIPES=$(readlink -f "$RECIPES")
mkdir -p "$TOOLS" "$ROOTFS" "$SRCDIR" "$OBJ" "$LOGS" "$STAMPS"

broom() { "$BROOM_BIN" -R "$RECIPES" -p "$PROFILE" --target "$TRIPLE" -j "$JOBS" "$@"; }

info "CleanLinux bootstrap: $TRIPLE, profile $PROFILE, $JOBS jobs"
info "work: $WORK"
info "recipes: $RECIPES"

for stage in "${STAGES[@]}"; do
	case $stage in
		toolchain) stage_toolchain ;;
		base) stage_base ;;
		image) stage_image ;;
		all)
			stage_toolchain
			stage_base
			stage_image
			;;
	esac
done
info "done"
