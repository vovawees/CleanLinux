#!/usr/bin/env bash
# The native rebuild of base gives the packages of the cross build (ROADMAP, issue #3).
# After 'bootstrap/bootstrap.sh --arch ARCH ... native' the rootfs has its own gcc, make and burn.
# Inside it (an unprivileged user namespace and chroot, as in the native stage) every package of
# the rootfs that the cross build made (or the named ones) is built again with --rebuild, into a
# cache of its own (the sources are shared), and its payload is compared with the cross-built
# package, file by file: path, mode, sha256 or link target. .BURN/meta differs by design (build
# date, the flags with the sysroot) and is left out; the file list .BURN/files is compared.
# Usage: tests/native-repro.sh [--arch ARCH] [--recipes DIR] [PKG...]
#        tests/native-repro.sh --compare CROSS.pkg.tar.zst NATIVE.pkg.tar.zst
# The report goes to build/ARCH/native-repro/report.txt; the exit status is 1 when a package
# differs or does not build.
set -euo pipefail
TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCH=$(uname -m) RECIPES=$TOP/../CleanLinux-Recipes/packages COMPARE=()
while (($#)); do
	case $1 in
		--arch) ARCH=$2 && shift 2 ;;
		--recipes) RECIPES=$2 && shift 2 ;;
		--compare) COMPARE=("$2" "$3") && shift 3 ;;
		-h | --help) sed -n '2,13p' "$0" | cut -c3- && exit 0 ;;
		-*) echo "native-repro: unknown option $1" >&2 && exit 2 ;;
		*) break ;;
	esac
done
fail() { echo "native-repro: $*" >&2 && exit 1; }
T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT

# payload PKG: one line per file of the package: path, mode, sha256 (or -> link target)
payload() {
	local d
	d=$(mktemp -d -p "$T")
	zstd -dc "$1" | tar -xf - -C "$d"
	(
		cd "$d"
		find . -path ./.BURN/meta -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort |
			while IFS= read -r f; do
				if [[ -L $f ]]; then
					printf '%s -> %s\n' "${f#./}" "$(readlink "$f")"
				else
					printf '%s %s %s\n' "${f#./}" "$(stat -c %a "$f")" "$(sha256sum <"$f" | cut -d' ' -f1)"
				fi
			done
	)
	rm -rf "$d"
}

# compare CROSS NATIVE: prints the files that differ, status 1 when any do
compare() {
	payload "$1" >"$T/a" && payload "$2" >"$T/b"
	if cmp -s "$T/a" "$T/b"; then return 0; fi
	diff "$T/a" "$T/b" | sed -n 's/^[<>] \([^ ]*\) .*/\1/p' | LC_ALL=C sort -u
	return 1
}

if ((${#COMPARE[@]})); then
	compare "${COMPARE[@]}" && echo "identical" && exit 0
	exit 1
fi

WORK=$TOP/build/$ARCH ROOTFS=$TOP/build/$ARCH/rootfs CACHE=${BURN_CACHE:-$TOP/build/cache}
OUT=$WORK/native-repro
[[ -f $WORK/stamps/86-native-build ]] || fail "no native stage in $WORK: bootstrap/bootstrap.sh --arch $ARCH base native first"
[[ $ARCH == "$(uname -m)" ]] || [[ -e /proc/sys/fs/binfmt_misc/qemu-$ARCH ]] ||
	fail "$ARCH binaries do not run here (qemu-user with binfmt_misc)"
RECIPES=$(readlink -f "$RECIPES")
[[ -d $RECIPES ]] || fail "no recipes in $RECIPES (--recipes DIR)"
DB=$ROOTFS/var/lib/burn/installed

# field PKG KEY: a value of the meta of an installed package
field() { sed -n "s/^$2=//p" "$DB/$1/meta"; }
# the cross builds: their flags name the sysroot of the bootstrap
if (($# == 0)); then
	for d in "$DB"/*/; do
		p=$(basename "$d")
		if field "$p" cflags | grep -q -- --sysroot=; then set -- "$@" "$p"; fi
	done
fi
(($#)) || fail "no cross-built package in $ROOTFS"

mkdir -p "$OUT/cache/packages" "$OUT/cache/sources" "$ROOTFS/var/cache/burn" "$ROOTFS/var/lib/burn/bootstrap-recipes"
[[ -e $ROOTFS/etc/resolv.conf ]] || : >"$ROOTFS/etc/resolv.conf.bootstrap"
cleanup() {
	if [[ -e $ROOTFS/etc/resolv.conf.bootstrap ]]; then
		rm -f "$ROOTFS/etc/resolv.conf.bootstrap"
		[[ ! -L $ROOTFS/etc/resolv.conf ]] || rm -f "$ROOTFS/etc/resolv.conf"
	fi
	rm -rf "$T"
}
trap cleanup EXIT

# native_build PKG: burn of the rootfs builds it again, into $OUT/cache
native_build() {
	# shellcheck disable=SC2016
	unshare --map-root-user --mount -- /bin/sh -c '
		set -e
		r=$1 cache=$2 sources=$3 recipes=$4 jobs=$5
		shift 5
		mount --rbind /dev "$r/dev"
		mount --rbind /proc "$r/proc"
		mount --bind "$cache" "$r/var/cache/burn"
		mount --bind "$sources" "$r/var/cache/burn/sources"
		mount --bind "$recipes" "$r/var/lib/burn/bootstrap-recipes"
		if [ -f "$r/etc/resolv.conf.bootstrap" ]; then
			mount --bind /etc/resolv.conf "$r/etc/resolv.conf.bootstrap"
			ln -sf resolv.conf.bootstrap "$r/etc/resolv.conf"
		fi
		exec chroot "$r" /usr/bin/env -i PATH=/usr/bin HOME=/root TERM=dumb LC_ALL=C.UTF-8 \
			BURN_WORK=/var/cache/burn/work BURN_JOBS="$jobs" "$@"
	' sh "$ROOTFS" "$OUT/cache" "$CACHE/sources" "$RECIPES" "$(nproc)" \
		/usr/bin/burn -R /var/lib/burn/bootstrap-recipes --rebuild -y build "$1"
}

same=0 differ=0 failed=0
: >"$OUT/report.txt"
for p in "$@"; do
	[[ -f $DB/$p/meta ]] || fail "$p is not installed in $ROOTFS"
	v=$(field "$p" version)-$(field "$p" release)-$(field "$p" arch)
	cross=$CACHE/packages/$p-$v-$(field "$p" buildid).pkg.tar.zst
	[[ -f $cross ]] || fail "no package $cross"
	printf '%-24s ' "$p"
	rm -f "$OUT/cache/packages/$p-$v-"*.pkg.tar.zst
	if ! native_build "$p" >"$OUT/$p.log" 2>&1; then
		echo "does not build natively (log: $OUT/$p.log)" | tee -a "$OUT/report.txt"
		failed=$((failed + 1))
		continue
	fi
	native=$(find "$OUT/cache/packages" -name "$p-$v-*.pkg.tar.zst" | head -1)
	if [[ -z $native ]]; then
		echo "no native package (log: $OUT/$p.log)" | tee -a "$OUT/report.txt"
		failed=$((failed + 1))
	elif files=$(compare "$cross" "$native"); then
		echo identical
		echo "$p identical" >>"$OUT/report.txt"
		same=$((same + 1))
	else
		n=$(wc -l <<<"$files")
		echo "$n file(s) differ"
		{
			echo "$p: $n file(s) differ"
			while IFS= read -r f; do printf '  %s\n' "$f"; done <<<"$files"
		} >>"$OUT/report.txt"
		differ=$((differ + 1))
	fi
done
echo "native-repro: $same identical, $differ differ, $failed do not build (report: $OUT/report.txt)"
((differ == 0 && failed == 0))
