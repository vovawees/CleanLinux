# shellcheck shell=bash
# Stages and steps of the bootstrap. Every step runs in a subshell with errexit, logs to
# $LOGS/<step>.log and leaves a stamp, so an interrupted bootstrap resumes where it stopped.

info() { printf '\033[1;36m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
	exit 1
}

step() {
	local name=$1 rc t0=$SECONDS
	shift
	if [[ -f $STAMPS/$name ]]; then
		info "$name (done)"
		return 0
	fi
	info "$name ..."
	set +e
	if ((VERBOSE)); then
		(
			set -e
			"$@"
		) 2>&1 | tee "$LOGS/$name.log"
		rc=${PIPESTATUS[0]}
	else
		(
			set -e
			"$@"
		) >"$LOGS/$name.log" 2>&1
		rc=$?
	fi
	set -e
	if ((rc)); then
		tail -n 60 "$LOGS/$name.log" >&2
		die "$name failed (exit $rc), log: $LOGS/$name.log"
	fi
	touch "$STAMPS/$name"
	info "$name ok ($((SECONDS - t0))s)"
}

# unpack PKG: sources from the recipe (checksums verified, patches applied); prints the dir
unpack() {
	local d=''
	[[ -f $SRCDIR/$1/.dir ]] && d=$(<"$SRCDIR/$1/.dir")
	if [[ -z $d || ! -d $d ]]; then
		rm -rf "${SRCDIR:?}/$1"
		d=$(burn unpack "$1" "$SRCDIR/$1") || die "unpacking $1 failed, see $SRCDIR/$1/unpack.log"
		[[ -d $d ]] || die "unpacking $1 printed no source directory"
		printf '%s\n' "$d" >"$SRCDIR/$1/.dir"
	fi
	printf '%s\n' "$d"
}

host_check() {
	local c missing=()
	for c in gcc g++ make bison gawk m4 python3 perl tar xz zstd patch sed grep find git meson ninja cmake pkg-config; do
		command -v "$c" >/dev/null || missing+=("$c")
	done
	if ! command -v curl >/dev/null && ! command -v wget >/dev/null; then missing+=(curl); fi
	((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]}"
	# Perl modules of the builds (libxcrypt: open; OpenSSL: IPC::Cmd, File::Compare, Time::Piece...):
	# part of perl itself, but Fedora, RHEL and Amazon Linux split them out (dnf install perl-core)
	local m
	for m in 'open qw(:std :utf8)' FindBin IPC::Cmd File::Compare File::Copy Time::Piece Digest::SHA English; do
		perl -e "use $m; 1" 2>/dev/null || missing+=("${m%% *}")
	done
	((${#missing[@]} == 0)) || die "missing Perl modules: ${missing[*]} (Fedora, RHEL, Amazon Linux: dnf install perl-core)"
	command -v makeinfo >/dev/null || info "note: makeinfo (texinfo) not found, info pages are skipped"
	gcc --version | head -n1
}

# merged /usr from the start: /bin /sbin /lib /lib64 and /usr/sbin /usr/lib64 are symlinks
rootfs_skeleton() {
	mkdir -p "$ROOTFS"/{etc,var,tmp,usr/bin,usr/lib,usr/include}
	local l
	for l in bin:usr/bin sbin:usr/bin lib:usr/lib lib64:usr/lib usr/sbin:bin usr/lib64:lib; do
		[[ -L $ROOTFS/${l%%:*} ]] || ln -s "${l#*:}" "$ROOTFS/${l%%:*}"
	done
}

cross_binutils() {
	local src
	src=$(unpack binutils)
	rm -rf "$OBJ/binutils" && mkdir -p "$OBJ/binutils" && cd "$OBJ/binutils"
	"$src/configure" --prefix="$TOOLS" --target="$TRIPLE" --with-sysroot="$ROOTFS" \
		--disable-nls --disable-werror --enable-gprofng=no --enable-new-dtags \
		--enable-default-hash-style=gnu --enable-deterministic-archives --enable-plugins
	make -j"$JOBS"
	make install
}

gcc_arch_args() {
	if [[ $ARCH == aarch64 ]]; then printf '%s\n' --enable-fix-cortex-a53-835769 --enable-fix-cortex-a53-843419; fi
}

cross_gcc_pass1() {
	local src glibc_ver
	src=$(unpack gcc)
	glibc_ver=$(burn query glibc version)
	rm -rf "$OBJ/gcc1" && mkdir -p "$OBJ/gcc1" && cd "$OBJ/gcc1"
	# shellcheck disable=SC2046
	"$src/configure" --prefix="$TOOLS" --target="$TRIPLE" --with-sysroot="$ROOTFS" \
		--with-glibc-version="$glibc_ver" --with-newlib --without-headers \
		--enable-default-pie --enable-default-ssp --disable-nls --disable-shared --disable-multilib \
		--disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp \
		--disable-libvtv --disable-libstdcxx --disable-libsanitizer --enable-languages=c,c++ \
		$(gcc_arch_args)
	make -j"$JOBS"
	make install
	# pass 1 has no libc headers: install the full limits.h (as gcc would with a libc)
	cd "$src"
	cat gcc/limitx.h gcc/glimits.h gcc/limity.h >"$(dirname "$("$TRIPLE-gcc" -print-libgcc-file-name)")/include/limits.h"
}

kernel_headers() {
	local src
	src=$(unpack linux-headers)
	cd "$src"
	make ARCH="$KARCH" mrproper
	make ARCH="$KARCH" headers
	find usr/include -type f ! -name '*.h' -delete
	cp -r usr/include "$ROOTFS/usr/"
}

cross_glibc() {
	local src
	src=$(unpack glibc)
	rm -rf "$OBJ/glibc" && mkdir -p "$OBJ/glibc" && cd "$OBJ/glibc"
	printf '%s\n' slibdir=/usr/lib rtlddir=/usr/lib sbindir=/usr/bin rootsbindir=/usr/bin >configparms
	CFLAGS='-O2 -pipe' CXXFLAGS='-O2 -pipe' "$src/configure" --prefix=/usr --host="$TRIPLE" \
		--build="$("$src/scripts/config.guess")" --libdir=/usr/lib --libexecdir=/usr/lib \
		--with-headers="$ROOTFS/usr/include" --enable-kernel=5.15 --enable-stack-protector=strong \
		--enable-bind-now --disable-nscd --disable-werror --disable-profile libc_cv_slibdir=/usr/lib
	make -j"$JOBS"
	make DESTDIR="$ROOTFS" install
	rm -f "$ROOTFS/etc/ld.so.cache"
}

cross_gcc_final() {
	local src
	src=$(unpack gcc)
	rm -rf "$OBJ/gcc2" && mkdir -p "$OBJ/gcc2" && cd "$OBJ/gcc2"
	# shellcheck disable=SC2046
	"$src/configure" --prefix="$TOOLS" --target="$TRIPLE" --with-sysroot="$ROOTFS" \
		--enable-languages=c,c++ --enable-shared --enable-threads=posix --enable-__cxa_atexit \
		--enable-clocale=gnu --enable-default-pie --enable-default-ssp --enable-gnu-unique-object \
		--enable-linker-build-id --enable-lto --enable-plugin --enable-checking=release \
		--disable-nls --disable-multilib --disable-libsanitizer --disable-libvtv --disable-libstdcxx-pch \
		--disable-werror --with-linker-hash-style=gnu $(gcc_arch_args)
	make -j"$JOBS"
	make install
}

# target runtime libraries of the compiler (libgcc_s, libstdc++, ...) into the rootfs
gcc_runtime() {
	local f
	for f in "$TOOLS/$TRIPLE"/lib{,64}/lib{gcc_s,stdc++,atomic,gomp,quadmath}.so*; do
		[[ $f == *.py ]] && continue
		cp -a "$f" "$ROOTFS/usr/lib/"
	done
}

# run_target PROGRAM [ARGS]: run a target binary against the rootfs libraries
run_target() {
	if [[ $ARCH == "$(uname -m)" ]]; then
		"$ROOTFS/usr/lib/${LOADER##*/}" --library-path "$ROOTFS/usr/lib" "$@"
	elif command -v "qemu-$ARCH" >/dev/null; then
		"qemu-$ARCH" -L "$ROOTFS" "$@"
	elif command -v "qemu-$ARCH-static" >/dev/null; then
		"qemu-$ARCH-static" -L "$ROOTFS" "$@"
	else
		return 77
	fi
}

toolchain_test() {
	local t=$OBJ/test rc
	rm -rf "$t" && mkdir -p "$t" && cd "$t"
	printf '#include <stdio.h>\nint main(void) { puts("hello from CleanLinux C"); return 0; }\n' >hello.c
	printf '#include <iostream>\nint main() { std::cout << "hello from CleanLinux C++" << std::endl; }\n' >hello.cpp
	"$TRIPLE-gcc" -O2 hello.c -o hello-c
	"$TRIPLE-g++" -O2 hello.cpp -o hello-cpp
	"$TRIPLE-readelf" -l hello-c | grep -F "[Requesting program interpreter: $LOADER]"
	"$TRIPLE-readelf" -d hello-cpp | grep -F 'libstdc++.so.6'
	set +e
	run_target ./hello-c && run_target ./hello-cpp
	rc=$?
	set -e
	if ((rc == 77)); then
		echo "no way to run $ARCH binaries here (install qemu-user); only link checks were done"
	elif ((rc)); then
		exit "$rc"
	fi
	cat >"$WORK/env.sh" <<ENV
# source this file to use the CleanLinux cross toolchain
export PATH="$TOOLS/bin:\$PATH"
export CLEANLINUX_TRIPLE=$TRIPLE CLEANLINUX_SYSROOT="$ROOTFS"
ENV
}

stage_toolchain() {
	info "== stage toolchain"
	step 00-host-check host_check
	step 01-rootfs-skeleton rootfs_skeleton
	step 10-binutils cross_binutils
	step 20-gcc-pass1 cross_gcc_pass1
	step 30-linux-headers kernel_headers
	step 40-glibc cross_glibc
	step 50-gcc-final cross_gcc_final
	step 60-gcc-runtime gcc_runtime
	step 70-toolchain-test toolchain_test
}

base_install() {
	mkdir -p "$ROOTFS/etc/burn"
	printf 'PROFILE=%s\n' "$PROFILE" >"$ROOTFS/etc/burn/burn.conf"
	# glibc and the kernel headers again, this time as tracked packages built with the profile flags
	burn -r "$ROOTFS" --host-deps -y install filesystem linux-headers glibc
	burn -r "$ROOTFS" --host-deps -y install base
	# a rerun of the stage brings what is installed up to the recipes (install only adds)
	burn -r "$ROOTFS" --host-deps -y --no-sync update
	burn -r "$ROOTFS" doctor
}

stage_base() {
	info "== stage base"
	[[ -f $STAMPS/70-toolchain-test ]] || die "run the toolchain stage first"
	step 80-base base_install
}

# ---- native: CleanLinux builds the rest of itself ----
#
# perl and python do not cross-compile. The cross toolchain builds the compiler and the basic
# build tools for the target (NATIVE_TOOLCHAIN); then the rootfs builds NATIVE_PACKAGES with its
# own gcc, make and burn, the way a device builds its updates: chroot inside an unprivileged user
# namespace (the mapped root, no root rights on the host), the host's /dev and /proc bind-mounted,
# the bootstrap's cache and recipes mounted where burn looks for them, no host tool on PATH.

NATIVE_TOOLCHAIN=${NATIVE_TOOLCHAIN:-binutils gcc linux-headers make patch m4 bison flex pkgconf}
NATIVE_PACKAGES=${NATIVE_PACKAGES:-base-devel}

native_toolchain() {
	local -a pkgs
	read -ra pkgs <<<"$NATIVE_TOOLCHAIN"
	burn -r "$ROOTFS" --host-deps -y install "${pkgs[@]}"
}

# in_rootfs COMMAND...: run a command of the rootfs inside it, as its root, with a clean
# environment; sources are downloaded by the rootfs's own curl (the host's resolv.conf)
in_rootfs() {
	[[ $ARCH == "$(uname -m)" ]] || [[ -e /proc/sys/fs/binfmt_misc/qemu-$ARCH ]] ||
		die "the native stage runs $ARCH binaries: same architecture or qemu-user with binfmt_misc"
	mkdir -p "$ROOTFS/var/cache/burn" "$ROOTFS/var/lib/burn/bootstrap-recipes" "$BURN_CACHE"
	[[ -e $ROOTFS/etc/resolv.conf ]] || : >"$ROOTFS/etc/resolv.conf.bootstrap"
	# shellcheck disable=SC2016
	unshare --map-root-user --mount -- /bin/sh -c '
		set -e
		r=$1 cache=$2 recipes=$3 jobs=$4
		shift 4
		mount --rbind /dev "$r/dev"
		mount --rbind /proc "$r/proc"
		mount --bind "$cache" "$r/var/cache/burn"
		mount --bind "$recipes" "$r/var/lib/burn/bootstrap-recipes"
		if [ -f "$r/etc/resolv.conf.bootstrap" ]; then
			mount --bind /etc/resolv.conf "$r/etc/resolv.conf.bootstrap"
			ln -sf resolv.conf.bootstrap "$r/etc/resolv.conf"
		fi
		exec chroot "$r" /usr/bin/env -i PATH=/usr/bin HOME=/root TERM=dumb LC_ALL=C.UTF-8 \
			BURN_WORK=/var/cache/burn/work BURN_JOBS="$jobs" "$@"
	' sh "$ROOTFS" "$BURN_CACHE" "$RECIPES" "$JOBS" "$@"
}

native_cleanup() {
	if [[ -e $ROOTFS/etc/resolv.conf.bootstrap ]]; then
		rm -f "$ROOTFS/etc/resolv.conf.bootstrap"
		[[ ! -L $ROOTFS/etc/resolv.conf ]] || rm -f "$ROOTFS/etc/resolv.conf"
	fi
	rmdir "$ROOTFS/var/lib/burn/bootstrap-recipes" 2>/dev/null || true
}

native_build() {
	local -a pkgs
	read -ra pkgs <<<"$NATIVE_PACKAGES"
	install_profiles
	trap native_cleanup EXIT
	in_rootfs /usr/bin/burn -R /var/lib/burn/bootstrap-recipes -j "$JOBS" -y install "${pkgs[@]}"
	in_rootfs /usr/bin/burn doctor
}

stage_native() {
	info "== stage native"
	[[ -f $STAMPS/80-base ]] || die "run the base stage first"
	rm -f "$STAMPS/86-native-build"
	step 85-native-toolchain native_toolchain
	step 86-native-build native_build
}

# burn itself is a package of base, and so are the hardware profiles of this repository
# (cleanlinux-profiles, made by tools/profiles-tarball.sh): until it is installed, profiles/ is
# copied; afterwards the system has the profiles of the package (burn clone gives them to the
# installed system), and a change in profiles/ needs a new release of it
install_profiles() {
	if [[ -d $ROOTFS/var/lib/burn/installed/cleanlinux-profiles ]]; then
		diff -rq "$TOP/profiles" "$ROOTFS/usr/share/burn/profiles" >/dev/null ||
			warn "profiles/ differs from the package cleanlinux-profiles of the rootfs: the system keeps the package (release a new cleanlinux-profiles)"
		return 0
	fi
	rm -rf "$ROOTFS/usr/share/burn/profiles" && mkdir -p "$ROOTFS/usr/share/burn"
	cp -r "$TOP/profiles" "$ROOTFS/usr/share/burn/"
}

rootfs_test() {
	local out rc s=''
	if [[ $(id -u) == 0 ]] || sudo -n true 2>/dev/null; then
		[[ $(id -u) == 0 ]] || s=sudo
		if [[ $ARCH == "$(uname -m)" ]] || [[ -e /proc/sys/fs/binfmt_misc/qemu-$ARCH ]]; then
			# real /dev and /proc, otherwise redirections to /dev/null leave plain files behind
			mkdir -p "$ROOTFS/dev" "$ROOTFS/proc"
			$s mount --bind /dev "$ROOTFS/dev"
			$s mount -t proc proc "$ROOTFS/proc"
			set +e
			# shellcheck disable=SC2016
			out=$($s chroot "$ROOTFS" /usr/bin/bash -c '. /etc/profile; echo "bash $BASH_VERSION"; ls /; zstd --version; burn --version; burn list | wc -l; burn doctor')
			rc=$?
			set -e
			$s umount "$ROOTFS/proc" "$ROOTFS/dev"
			printf '%s\n' "$out"
			return "$rc"
		fi
	fi
	set +e
	# shellcheck disable=SC2016
	run_target "$ROOTFS/usr/bin/bash" -c 'echo "bash $BASH_VERSION runs"'
	rc=$?
	set -e
	((rc == 77)) && echo "cannot run $ARCH binaries here, skipped" && return 0
	return "$rc"
}

make_tarball() {
	local out
	out=$WORK/cleanlinux-$ARCH-$PROFILE-$(date -u +%Y%m%d).tar.zst
	tar -C "$ROOTFS" --numeric-owner --owner=0 --group=0 -cf - . | zstd -q -T0 -19 >"$out"
	ls -lh "$out"
}

stage_image() {
	info "== stage image"
	[[ -f $STAMPS/80-base ]] || die "run the base stage first"
	rm -f "$STAMPS/90-profiles" "$STAMPS/91-rootfs-test" "$STAMPS/99-tarball"
	step 90-profiles install_profiles
	step 91-rootfs-test rootfs_test
	step 99-tarball make_tarball
}

# ---- disk: a bootable image without root privileges ----
#
# GPT with an EFI system partition (vfat: systemd-boot, the kernel, loader entries) and a btrfs
# root with the subvolumes @ (/), @home and @snapshots (/.snapshots, where burn keeps its
# snapshots), compressed with zstd. The root is a copy of the rootfs plus the kernel of the
# profile and systemd-boot, installed by burn so that the booted system updates them itself.
# mkfs.btrfs --rootdir fills the filesystem from the directory and unshare -r makes the files
# owned by root; mtools copy the ESP. The rootfs's own mkfs tools are used when they run here.

DISK_SIZE=${DISK_SIZE:-4G} ESP_SIZE=${ESP_SIZE:-512}

disk_check() {
	local c missing=()
	for c in sfdisk mcopy dd truncate unshare; do
		command -v "$c" >/dev/null || missing+=("$c")
	done
	((${#missing[@]} == 0)) || die "missing host tools for the disk image: ${missing[*]} (util-linux, mtools)"
	unshare -r true || die "unshare -r failed: the disk image needs unprivileged user namespaces"
}

# disk_tool NAME: the command for a filesystem tool, one word per line: the rootfs's own one when
# its binaries run here (same architecture, or through qemu-user), else the host's
disk_tool() {
	local q
	if [[ -x $ROOTFS/usr/bin/$1 ]]; then
		if [[ $ARCH == "$(uname -m)" ]]; then
			printf '%s\n' "$ROOTFS/usr/lib/${LOADER##*/}" --library-path "$ROOTFS/usr/lib" "$ROOTFS/usr/bin/$1"
			return
		fi
		for q in "qemu-$ARCH" "qemu-$ARCH-static"; do
			if command -v "$q" >/dev/null; then
				printf '%s\n' "$(command -v "$q")" -L "$ROOTFS" "$ROOTFS/usr/bin/$1"
				return
			fi
		done
	fi
	if command -v "$1" >/dev/null; then
		command -v "$1"
	fi
}

# disk_native: what cross builds of the spins run on this machine, built here into $TOOLS. A
# Wayland spin needs wayland-scanner of the version of the wayland recipe (wayland itself demands
# exactly its own version, wlroots a recent one); meson takes the build machine's pkg-config path
# of a cross build from PKG_CONFIG_PATH_FOR_BUILD (bootstrap.sh points it at $TOOLS/lib/pkgconfig).
# It links a static expat of the expat recipe, so the host needs no expat headers.
disk_native() {
	local v src e=$OBJ/native-expat w=$OBJ/native-wayland-scanner
	((${#SPINS[@]})) || return 0
	v=$(sed -n 's/^version=//p' "$RECIPES/wayland/recipe")
	if [[ -x $TOOLS/bin/wayland-scanner && $("$TOOLS/bin/wayland-scanner" --version 2>&1) == *" $v" ]]; then
		info "wayland-scanner $v is there"
		return 0
	fi
	src=$(unpack expat)
	rm -rf "$e" && mkdir -p "$e/build"
	(cd "$e/build" && "$src/configure" --prefix="$e/inst" --disable-shared --enable-static \
		--without-xmlwf --without-examples --without-tests --without-docbook)
	make -C "$e/build" -j"$JOBS"
	make -C "$e/build" install
	src=$(unpack wayland)
	rm -rf "$w"
	meson setup "$w" "$src" --prefix="$TOOLS" --libdir=lib --buildtype=release --wrap-mode=nodownload \
		--pkg-config-path="$e/inst/lib/pkgconfig" -Dlibraries=false -Dscanner=true -Dtests=false \
		-Ddocumentation=false -Ddtd_validation=false
	meson compile -C "$w" -j "$JOBS"
	meson install -C "$w"
	"$TOOLS/bin/wayland-scanner" --version
	rm -rf "$e" "$w"
}

# DISK_PACKAGES: what the image has on top of base: the kernel and the boot loader, the installer,
# and Wi-Fi (iwd, enabled by the installer where there is Wi-Fi)
DISK_PACKAGES=${DISK_PACKAGES:-linux systemd-boot cleanlinux-install iwd}

disk_root() {
	local d=$WORK/disk r=$WORK/disk/top/@ meta name version release parch buildid f n=0
	local -a pkgs
	if [[ -d $d ]]; then chmod -R u+w "$d" && rm -rf "$d"; fi
	mkdir -p "$d/top/@home" "$d/top/@snapshots" "$d/esp"
	install_profiles
	cp -a --reflink=auto "$ROOTFS" "$r"
	if [[ -n ${DISK_PACKAGE_FEATURES:-} ]]; then
		printf '%s\n' "$DISK_PACKAGE_FEATURES" >"$r/etc/burn/package.features"
	fi
	read -ra pkgs <<<"$DISK_PACKAGES"
	burn -r "$r" --host-deps -y install "${pkgs[@]}"
	disk_spins "$r"
	burn -r "$r" doctor
	# wired network at boot (dinitctl enable dhcpcd)
	mkdir -p "$r/etc/dinit.d/boot.d"
	ln -sfn /usr/lib/dinit.d/dhcpcd "$r/etc/dinit.d/boot.d/dhcpcd"
	# the image installs itself: cleanlinux-install runs burn clone, which takes the package
	# files of every installed build from /var/cache/burn/packages
	mkdir -p "$r/var/cache/burn/packages"
	for meta in "$r"/var/lib/burn/installed/*/meta; do
		name=$(sed -n 's/^name=//p' "$meta") version=$(sed -n 's/^version=//p' "$meta")
		release=$(sed -n 's/^release=//p' "$meta") parch=$(sed -n 's/^arch=//p' "$meta")
		buildid=$(sed -n 's/^buildid=//p' "$meta")
		f=$BURN_CACHE/packages/$name-$version-$release-$parch-$buildid.pkg.tar.zst
		[[ -f $f ]] || die "the package file of $name is not in the cache: $f"
		cp --reflink=auto "$f" "$r/var/cache/burn/packages/"
		n=$((n + 1))
	done
	info "package cache of the image: $n packages, $(du -sh "$r/var/cache/burn/packages" | cut -f1)"
}

# disk_spins ROOT: the spins of --spin on top of the base (docs/SPINS.md): burn spin add builds and
# installs their packages and enables their services; a spin from a directory is a link to it,
# which the image replaces with a copy
disk_spins() {
	local r=$1 s src
	for s in "${SPINS[@]}"; do
		burn -r "$r" --host-deps -y spin add "$s"
	done
	for s in "$r"/var/lib/burn/spins/*; do
		if [[ -L $s ]]; then
			src=$(readlink -f "$s")
			rm "$s" && cp -a "$src" "$s"
		fi
	done
}

# the spins of the image, for its name: -labwc, -kde+steam
disk_spin_suffix() {
	local s names=()
	for s in "$WORK/disk/top/@/var/lib/burn/spins"/*; do
		[[ -d $s ]] && names+=("${s##*/}")
	done
	((${#names[@]})) || return 0
	local IFS=+
	printf -- '-%s' "${names[*]}"
}

disk_image() {
	local d=$WORK/disk r=$WORK/disk/top/@ img esp_uuid root_uuid fs_uuid root_type console help
	local -a mkvfat mkbtrfs
	img=$WORK/cleanlinux-$ARCH-$PROFILE$(disk_spin_suffix).img
	esp_uuid=$(</proc/sys/kernel/random/uuid) root_uuid=$(</proc/sys/kernel/random/uuid)
	fs_uuid=$(</proc/sys/kernel/random/uuid)
	case $ARCH in
		x86_64) root_type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 console='console=tty0 console=ttyS0,115200' ;;
		aarch64) root_type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE console='console=tty0 console=ttyAMA0,115200' ;;
	esac
	mapfile -t mkvfat < <(disk_tool mkfs.vfat)
	mapfile -t mkbtrfs < <(disk_tool mkfs.btrfs)
	((${#mkvfat[@]})) || die "mkfs.vfat (dosfstools) is needed for the disk image"
	((${#mkbtrfs[@]})) || die "mkfs.btrfs (btrfs-progs) is needed for the disk image"
	# not a pipe into grep -q: under pipefail mkfs.btrfs may die of SIGPIPE once grep has its match
	help=$("${mkbtrfs[@]}" --help 2>&1) || true
	[[ $help == *--subvol* ]] || die "mkfs.btrfs is too old for --subvol (btrfs-progs 6.12+)"

	# the files of this disk: mounts, the kernel command line, the host name; root logs in
	# without a password on a fresh image (set one with passwd)
	printf '%s\n' '# <device> <mount point> <type> <options> <dump> <pass>' \
		"PARTUUID=$root_uuid / btrfs subvol=@,compress=zstd:1,noatime 0 0" \
		"PARTUUID=$root_uuid /home btrfs subvol=@home,compress=zstd:1,noatime 0 0" \
		"PARTUUID=$root_uuid /.snapshots btrfs subvol=@snapshots,compress=zstd:1,noatime 0 0" \
		"PARTUUID=$esp_uuid /boot vfat umask=0077,noatime 0 2" \
		'tmpfs /tmp tmpfs nosuid,nodev 0 0' >"$r/etc/fstab"
	mkdir -p "$r/home" "$r/.snapshots" "$r/boot" "$r/etc/kernel"
	printf '%s\n' "root=PARTUUID=$root_uuid rootflags=subvol=@ rootwait ro ${DISK_CMDLINE-$console}" >"$r/etc/kernel/cmdline"
	[[ -s $r/etc/hostname ]] || echo cleanlinux >"$r/etc/hostname"
	sed -i 's/^root:[^:]*:/root::/' "$r/etc/shadow"

	# the ESP: systemd-boot, the kernels and their entries, as on an installed system
	run_target "$r/usr/bin/cleanlinux-boot" --root "$r" kernel sync --esp "$d/esp"
	find "$d/esp" -type f | sort
	rm -f "$d/esp.img"
	"${mkvfat[@]}" -C -F 32 -n ESP "$d/esp.img" $((ESP_SIZE * 1024))
	MTOOLS_SKIP_CHECK=1 mcopy -s -m -Q -i "$d/esp.img" "$d/esp"/* ::/

	# GPT: the ESP from 1 MiB, the root up to 1 MiB before the end (the backup table)
	local bytes esp_start=2048 esp_sectors=$((ESP_SIZE * 2048)) root_start root_sectors
	rm -f "$img" && truncate -s "$DISK_SIZE" "$img"
	bytes=$(stat -c %s "$img")
	root_start=$((esp_start + esp_sectors))
	root_sectors=$((bytes / 512 - root_start - 2048))
	((root_sectors > 2097152)) || die "DISK_SIZE=$DISK_SIZE is too small"
	printf '%s\n' 'label: gpt' \
		"start=$esp_start, size=$esp_sectors, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=$esp_uuid, name=\"EFI system partition\"" \
		"start=$root_start, size=$root_sectors, type=$root_type, uuid=$root_uuid, name=cleanlinux" |
		sfdisk -q "$img"
	sfdisk -d "$img"

	# btrfs from the directory tree, files owned by root
	rm -f "$d/root.img" && truncate -s $((root_sectors * 512)) "$d/root.img"
	unshare -r "${mkbtrfs[@]}" -f -L cleanlinux -U "$fs_uuid" --rootdir "$d/top" \
		--subvol rw:@ --subvol rw:@home --subvol rw:@snapshots --compress zstd:3 "$d/root.img"

	dd if="$d/esp.img" of="$img" bs=1M seek=$((esp_start * 512)) oflag=seek_bytes conv=notrunc,sparse status=none
	dd if="$d/root.img" of="$img" bs=1M seek=$((root_start * 512)) oflag=seek_bytes conv=notrunc,sparse status=none
	chmod -R u+w "$d" && rm -rf "$d"
	ls -lhs "$img"
}

stage_disk() {
	info "== stage disk"
	[[ -f $STAMPS/80-base ]] || die "run the base stage first"
	rm -f "$STAMPS/94-disk-native" "$STAMPS/95-disk-check" "$STAMPS/96-disk-root" "$STAMPS/97-disk-image"
	step 94-disk-native disk_native
	step 95-disk-check disk_check
	step 96-disk-root disk_root
	step 97-disk-image disk_image
}
