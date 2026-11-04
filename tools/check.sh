#!/usr/bin/env bash
# Local checks of CleanLinux: run them before every push (there is no hosted CI).
#   tools/check.sh [--recipes DIR]               shellcheck, tests/rolling.sh, tests/smoke.sh
#   tools/check.sh ... --kernel SRC              also tests/kernel-config.sh: the kernel options of every
#                                                profile and the device trees of its boards, in a kernel
#                                                source tree or linux-X.tar.xz (minutes per profile)
#   tools/check.sh [--recipes DIR] --full [ARCH] the same, then the whole bootstrap of ARCH (x86_64 by
#                                                default; hours of CPU), the kernel options against the
#                                                kernel it fetched, and the boot and install tests of its
#                                                disk image in QEMU (tests/boot.py, tests/install.py,
#                                                also with --encrypt)
#   tools/check.sh --quick                       shellcheck only (tools/hooks/pre-push)
# The recipes default to ../CleanLinux-Recipes/packages.
set -euo pipefail
cd "$(dirname "$0")/.."
RECIPES=../CleanLinux-Recipes/packages MODE=normal ARCH=x86_64 KERNEL=''
while (($#)); do
	case $1 in
		--recipes) RECIPES=$2 && shift 2 ;;
		--kernel) KERNEL=$2 && shift 2 ;;
		--quick) MODE=quick && shift ;;
		--full)
			MODE=full && shift
			if [[ ${1:-} == x86_64 || ${1:-} == aarch64 ]]; then ARCH=$1 && shift; fi
			;;
		-h | --help) sed -n '2,13p' "$0" | cut -c3- && exit 0 ;;
		*) echo "tools/check.sh: unknown argument: $1" >&2 && exit 2 ;;
	esac
done
step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

step shellcheck
shellcheck -x tests/*.sh bootstrap/*.sh tools/*.sh tools/hooks/pre-push profiles/*.profile profiles/devices/*.profile
python3 -m py_compile tools/*.py tests/*.py
[[ $MODE == quick ]] && exit 0

if [[ ! -d $RECIPES ]]; then
	echo "no recipes in $RECIPES: git clone https://github.com/vovawees/CleanLinux-Recipes ../CleanLinux-Recipes (or --recipes DIR)" >&2
	exit 1
fi
RECIPES=$(readlink -f "$RECIPES")
step "rolling release+++ test"
tests/rolling.sh
step "smoke test (real recipes)"
tests/smoke.sh "$RECIPES"
if [[ -n $KERNEL ]]; then
	step "kernel options of the profiles: $KERNEL"
	tests/kernel-config.sh --recipes "$RECIPES" "$KERNEL"
fi
[[ $MODE == full ]] || exit 0

step "bootstrap $ARCH: toolchain, base, native, image, disk"
bootstrap/bootstrap.sh --arch "$ARCH" --recipes "$RECIPES" all
if [[ -z $KERNEL ]]; then
	tarball=$(find build/cache/sources -maxdepth 1 -name 'linux-*.tar.xz' | sort -V | tail -1)
	step "kernel options of the profiles: $tarball"
	tests/kernel-config.sh --recipes "$RECIPES" "$tarball"
fi
img=build/$ARCH/cleanlinux-$ARCH-generic-$ARCH.img
step "boot test: $img"
python3 tests/boot.py "$img" --arch "$ARCH" --log "build/$ARCH/logs/boot.log"
step "install test"
python3 tests/install.py "$img" --arch "$ARCH"
step "install test, the root in LUKS2"
python3 tests/install.py "$img" --arch "$ARCH" --encrypt
