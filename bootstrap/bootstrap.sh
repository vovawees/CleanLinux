#!/usr/bin/env bash
# CleanLinux bootstrap: build the system from source, from nothing but a host compiler.
#
#   toolchain  cross binutils -> gcc (pass 1) -> kernel headers -> glibc -> gcc (final)
#   base       the base system, cross-compiled and installed by burn into the rootfs
#   native     the compiler for the target, then the rootfs builds base-devel itself (perl,
#              python, cmake...): its own gcc and burn in a chroot, unprivileged (user namespace)
#   image      burn inside the rootfs, chroot/qemu test, rootfs tarball
#   disk       bootable disk image: GPT, ESP with systemd-boot + btrfs root (@, @home, @snapshots),
#              the kernel of the profile; no root needed (DISK_SIZE=4G, ESP_SIZE=512 MiB,
#              DISK_CMDLINE= replaces the console options); tests/boot.py boots it in QEMU;
#              --spin adds a spin (git URL or directory, docs/SPINS.md) on top of the base;
#              DISK_PACKAGE_FEATURES= lines for /etc/burn/package.features of the image
#              ('mesa -video_cards_intel': no LLVM for an image that does not need Intel GPUs)
#
# The rootfs doubles as the toolchain sysroot, so every package is built against the exact
# glibc it will run with. Nothing from the host ends up in the image.
#
# Usage: bootstrap/bootstrap.sh [--arch x86_64|aarch64] [--profile NAME] [--work DIR]
#                               [--recipes DIR] [--spin URL|DIR]... [-j N] [-v] [stage...]
set -euo pipefail
shopt -s nullglob inherit_errexit

HERE=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
TOP=$(cd "$HERE/.." && pwd)
# shellcheck source=bootstrap/lib.sh
. "$HERE/lib.sh"

ARCH='' PROFILE='' WORK='' RECIPES=${BURN_RECIPES:-} JOBS=$(nproc) VERBOSE=0
STAGES=() SPINS=()
while (($#)); do
	case $1 in
		--arch) ARCH=${2:?} && shift 2 ;;
		--profile) PROFILE=${2:?} && shift 2 ;;
		--work) WORK=${2:?} && shift 2 ;;
		--recipes) RECIPES=${2:?} && shift 2 ;;
		--spin) SPINS+=("${2:?}") && shift 2 ;;
		-j) JOBS=${2:?} && shift 2 ;;
		-v) VERBOSE=1 && shift ;;
		-h | --help)
			awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
			exit 0
			;;
		toolchain | base | native | image | disk | all) STAGES+=("$1") && shift ;;
		*) die "unknown argument: $1" ;;
	esac
done
((${#STAGES[@]})) || STAGES=(all)

export BURN_CACHE=${BURN_CACHE:-$TOP/build/cache} BURN_PROFILE_DIR=${BURN_PROFILE_DIR:-$TOP/profiles}
if [[ -z $RECIPES ]]; then
	for d in "$TOP/../CleanLinux-Recipes/packages" "$TOP/build/recipes/packages"; do
		if [[ -d $d ]]; then RECIPES=$d && break; fi
	done
fi
if [[ -z $RECIPES ]]; then
	git clone -q --depth 1 https://github.com/vovawees/CleanLinux-Recipes.git "$TOP/build/recipes"
	RECIPES=$TOP/build/recipes/packages
fi
RECIPES=$(readlink -f "$RECIPES")
# burn (github.com/vovawees/burn): the release the burn recipe pins, built for this host;
# BURN_BIN=path/to/burn takes another one (a development build, say)
BURN_BIN=${BURN_BIN:-$("$HERE/host-burn.sh" "$RECIPES" "$TOP/build/host")}

if [[ -z $ARCH && -n $PROFILE ]]; then
	ARCH=$(BURN_RECIPES='' "$BURN_BIN" -p "$PROFILE" profile show | awk '$1 == "chost" { split($2, a, "-"); print a[1] }')
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
export PATH=$TOOLS/bin:$PATH LC_ALL=C
# the pkg-config path of the build machine in meson's cross builds: the native wayland-scanner
export PKG_CONFIG_PATH_FOR_BUILD=$TOOLS/lib/pkgconfig
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CC CXX
mkdir -p "$TOOLS" "$ROOTFS" "$SRCDIR" "$OBJ" "$LOGS" "$STAMPS"

burn() { "$BURN_BIN" -R "$RECIPES" -p "$PROFILE" --target "$TRIPLE" -j "$JOBS" "$@"; }

info "CleanLinux bootstrap: $TRIPLE, profile $PROFILE, $JOBS jobs"
info "work: $WORK"
info "recipes: $RECIPES"
host_meson

for stage in "${STAGES[@]}"; do
	case $stage in
		toolchain) stage_toolchain ;;
		base) stage_base ;;
		native) stage_native ;;
		image) stage_image ;;
		disk) stage_disk ;;
		all)
			stage_toolchain
			stage_base
			stage_native
			stage_image
			stage_disk
			;;
	esac
done
info "done"
