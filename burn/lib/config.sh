# shellcheck shell=bash
# Configuration defaults, profiles and compiler flags.

config_defaults() {
	ROOT=${BURN_ROOT:-/}
	if [[ $(id -u) == 0 ]]; then
		CACHE_DIR=${BURN_CACHE:-/var/cache/burn}
		WORK_DIR=${BURN_WORK:-/var/tmp/burn}
	else
		CACHE_DIR=${BURN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/burn}
		WORK_DIR=${BURN_WORK:-$CACHE_DIR/work}
	fi
	RECIPE_REPOS=(https://github.com/vovawees/CleanLinux-Recipes.git)
	RECIPE_PATHS=()
	CHANNEL=main
	PROFILE=${BURN_PROFILE:-native}
	JOBS=$(nproc 2>/dev/null || echo 2)
	FETCH_JOBS=4
	FEATURES=''
	LOCALES='en ru'
	KEEP_DOCS=0 KEEP_INFO=0 KEEP_MAN=1
	STRIP_BINARIES=1 LTO=1 CHECK=0 HOST_DEPS=0
	MESON_AUTO_FEATURES=disabled
	OPT_FLAGS='-O2 -pipe'
	HARDENING_FLAGS='-fstack-clash-protection -Wp,-D_FORTIFY_SOURCE=3'
	LDFLAGS_BASE='-Wl,-O1 -Wl,--as-needed -Wl,--sort-common -Wl,-z,relro -Wl,-z,now -Wl,-z,pack-relative-relocs'
	GNU_MIRROR=https://ftpmirror.gnu.org/gnu
	KERNEL_MIRROR=https://cdn.kernel.org/pub/linux
	PKG_COMPRESS='zstd -q -T0 -10'
	ASSUME_INSTALLED=()
	ESSENTIAL=(filesystem glibc bash coreutils burn)
	CORE_PKGS=(glibc gcc binutils linux mesa llvm)
	CHOST=''
}

config_load() {
	local f
	for f in "${ROOT%/}/etc/burn/burn.conf" ${CONFIG_FILE:+"$CONFIG_FILE"}; do
		[[ -f $f ]] || continue
		# shellcheck source=/dev/null
		. "$f"
	done
	return 0
}

profile_dirs() {
	local d
	for d in ${BURN_PROFILE_DIR:+"$BURN_PROFILE_DIR"} "${ROOT%/}/etc/burn/profiles" "$BURN_HOME/../profiles" /usr/share/burn/profiles; do
		[[ -d $d ]] && readlink -f "$d"
	done | awk '!seen[$0]++'
}

profile_find() {
	local d f
	while IFS= read -r d; do
		for f in "$d/$1.profile" "$d/devices/$1.profile"; do
			if [[ -f $f ]]; then
				readlink -f "$f"
				return 0
			fi
		done
	done < <(profile_dirs)
	return 1
}

# GPU drivers of this machine, in VIDEO_CARDS words (amd intel nouveau freedreno panfrost v3d ...)
detect_video_cards() {
	local dev drv out=''
	for dev in /sys/class/drm/card[0-9]*/device; do
		[[ -e $dev/driver ]] || continue
		drv=$(readlink -f "$dev/driver")
		case ${drv##*/} in
			amdgpu | radeon) out+=' amd' ;;
			i915 | xe) out+=' intel' ;;
			nouveau) out+=' nouveau' ;;
			msm*) out+=' freedreno' ;;
			panfrost | panthor) out+=' panfrost' ;;
			v3d | vc4) out+=' v3d' ;;
			lima) out+=' lima' ;;
			etnaviv) out+=' etnaviv' ;;
			virtio*) out+=' virgl' ;;
		esac
	done
	tr ' ' '\n' <<<"$out" | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -
}

# Profiles may start with `inherit <parent>`.
inherit() {
	local p
	p=$(profile_find "$1") || die "inherited profile '$1' not found"
	# shellcheck source=/dev/null
	. "$p"
}

profile_load() {
	CARCH=$(uname -m) CPU_FLAGS=native VIDEO_CARDS='' PROFILE_FEATURES='' PROFILE_DESC=''
	EXTRA_CFLAGS='' EXTRA_LDFLAGS='' KERNEL_CMDLINE='' KERNEL_CONFIG=''
	PROFILE_FILE=$(profile_find "$PROFILE") || die "profile '$PROFILE' not found (see: burn profile list)"
	# shellcheck source=/dev/null
	. "$PROFILE_FILE"
	PROFILE_ARCH=$CARCH
}

flags_setup() {
	local host_arch cpu
	host_arch=$(uname -m)
	CBUILD=$({ cc -dumpmachine || gcc -dumpmachine; } 2>/dev/null) || CBUILD=$host_arch-pc-linux-gnu
	if [[ -z $CHOST ]]; then
		if [[ $PROFILE_ARCH == "$host_arch" ]]; then CHOST=$CBUILD; else CHOST=$PROFILE_ARCH-cleanlinux-linux-gnu; fi
	fi
	CARCH=${CHOST%%-*}
	[[ $CARCH == "$PROFILE_ARCH" ]] || die "profile '$PROFILE' is for $PROFILE_ARCH, but the target is $CHOST"
	CROSS=0
	if [[ $CHOST != "$CBUILD" ]]; then CROSS=1; fi
	case $CARCH in x86_64) KARCH=x86 ;; aarch64) KARCH=arm64 ;; *) KARCH=$CARCH ;; esac
	SYSROOT=$ROOT
	cpu=$CPU_FLAGS
	if [[ $cpu == native ]]; then
		[[ $CARCH == "$host_arch" ]] || die "CPU_FLAGS=native cannot target $CARCH from $host_arch; use a device profile"
		if [[ $CARCH == aarch64 ]]; then cpu='-mcpu=native'; else cpu='-march=native'; fi
	fi
	CPU_CFLAGS=$cpu
}

toolchain_env() {
	if ((CROSS)); then
		local p=$CHOST-
		CC=${p}gcc CXX=${p}g++ LD=${p}ld AS=${p}as AR=${p}ar NM=${p}nm RANLIB=${p}ranlib
		STRIP=${p}strip OBJCOPY=${p}objcopy OBJDUMP=${p}objdump READELF=${p}readelf
		export PKG_CONFIG_SYSROOT_DIR=$SYSROOT PKG_CONFIG_PATH=''
		export PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig
		have "$CC" || die "cross compiler $CC not found in PATH (build the toolchain first: bootstrap/bootstrap.sh)"
	else
		CC=${CC:-cc} CXX=${CXX:-c++} LD=${LD:-ld} AS=${AS:-as} AR=${AR:-ar} NM=${NM:-nm} RANLIB=${RANLIB:-ranlib}
		STRIP=${STRIP:-strip} OBJCOPY=${OBJCOPY:-objcopy} OBJDUMP=${OBJDUMP:-objdump} READELF=${READELF:-readelf}
	fi
	export CC CXX LD AS AR NM RANLIB STRIP OBJCOPY OBJDUMP READELF
}

# Drop linker flags the toolchain/libc cannot handle. DT_RELR (pack-relative-relocs) needs
# glibc >= 2.36: an older loader silently ignores it and binaries crash.
ldflags_probe() {
	local out=$LDFLAGS_BASE t ok=1
	if [[ $out == *pack-relative-relocs* ]]; then
		if ((CROSS)); then
			LC_ALL=C "$READELF" -V "$SYSROOT/usr/lib/libc.so.6" 2>/dev/null | grep GLIBC_ABI_DT_RELR >/dev/null || ok=0
		else
			t=$(mktemp -d)
			printf '%s\n' 'static int a = 1, b = 2;' 'static int *p[] = { &a, &b };' \
				'int main(void) { return *p[0] + *p[1] == 3 ? 0 : 1; }' >"$t/t.c"
			if ! "$CC" -fPIE -pie -Wl,-z,pack-relative-relocs "$t/t.c" -o "$t/t" >/dev/null 2>&1 || ! "$t/t" >/dev/null 2>&1; then
				ok=0
			fi
			rm -rf "$t"
		fi
		((ok)) || out=${out/ -Wl,-z,pack-relative-relocs/}
	fi
	printf '%s' "$out"
}

# Per-recipe CFLAGS/CXXFLAGS/LDFLAGS (needs recipe + toolchain_env).
flags_for_recipe() {
	CFLAGS="$OPT_FLAGS $CPU_CFLAGS"
	if ! has_option '!hardening'; then
		CFLAGS+=" $HARDENING_FLAGS"
		if [[ $CARCH == x86_64 ]]; then CFLAGS+=' -fcf-protection'; fi
	fi
	if [[ $CARCH == aarch64 ]]; then CFLAGS+=' -mbranch-protection=standard'; fi
	# GCC < 12 cannot do _FORTIFY_SOURCE=3 and warns on every file
	if [[ $CFLAGS == *_FORTIFY_SOURCE=3* ]] && (($("$CC" -dumpversion 2>/dev/null | cut -d. -f1) + 0 < 12)); then
		CFLAGS=${CFLAGS/_FORTIFY_SOURCE=3/_FORTIFY_SOURCE=2}
	fi
	if [[ -n $EXTRA_CFLAGS ]]; then CFLAGS+=" $EXTRA_CFLAGS"; fi
	LDFLAGS="$(ldflags_probe)${EXTRA_LDFLAGS:+ $EXTRA_LDFLAGS}"
	LTO_ON=0
	if ((LTO)) && ! has_option '!lto'; then
		LTO_ON=1
		CFLAGS+=' -flto=auto'
		LDFLAGS+=' -flto=auto'
		if has_option staticlibs; then CFLAGS+=' -ffat-lto-objects'; fi
		local pre=''
		((CROSS)) && pre=$CHOST-
		if have "${pre}gcc-ar"; then AR=${pre}gcc-ar NM=${pre}gcc-nm RANLIB=${pre}gcc-ranlib; fi
	fi
	if ((CROSS)); then
		CFLAGS+=" --sysroot=$SYSROOT"
		LDFLAGS+=" --sysroot=$SYSROOT"
	elif [[ -n $R ]]; then
		# staging root on a foreign host: let builds find what is already installed in ROOT
		CFLAGS+=" -isystem $R/usr/include"
		LDFLAGS+=" -L$R/usr/lib -Wl,-rpath-link,$R/usr/lib"
		export PKG_CONFIG_PATH=$R/usr/lib/pkgconfig:$R/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
	fi
	if [[ -n $cflags_append ]]; then CFLAGS+=" $cflags_append"; fi
	CXXFLAGS=$CFLAGS
	export CFLAGS CXXFLAGS LDFLAGS AR NM RANLIB
}