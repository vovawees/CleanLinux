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
	# the build tools of the cross builds come from the host (burn --host-deps: the makedepends of
	# the layers devel and core, such as gperf for eudev and systemd-boot, bc and flex for the kernel)
	for c in gcc g++ make bison flex gawk m4 bc gperf python3 perl tar xz zstd patch sed grep find git ninja cmake pkg-config; do
		command -v "$c" >/dev/null || missing+=("$c")
	done
	if ! command -v curl >/dev/null && ! command -v wget >/dev/null; then missing+=(curl); fi
	((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]}"
	# headers of the host programs: burn (libzstd), the kernel's objtool (libelf) and sign-file (OpenSSL)
	local h
	for h in zstd.h gelf.h openssl/evp.h; do
		printf '#include <%s>\n' "$h" | gcc -E -x c - >/dev/null 2>&1 || missing+=("$h")
	done
	((${#missing[@]} == 0)) || die "missing host headers: ${missing[*]} (libzstd, libelf/elfutils and OpenSSL development packages)"
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

# host_meson: the meson of the meson recipe for every meson build of the bootstrap, run from its
# release tarball (pure Python) by the python3 of PATH. Hosts ship older ones (Amazon Linux 2023:
# 0.63, which looks at Python through distutils, gone since Python 3.12) and the recipes want a
# recent one (Mesa, wlroots); bootstrap.sh calls this before every stage
host_meson() {
	local v src
	command -v python3 >/dev/null || die "missing host tools: python3"
	v=$(burn query meson version)
	if [[ -x $TOOLS/bin/meson && $("$TOOLS/bin/meson" --version 2>/dev/null) == "$v" ]]; then
		return 0
	fi
	src=$(unpack meson)
	rm -rf "$TOOLS/lib/meson" && mkdir -p "$TOOLS/lib" "$TOOLS/bin"
	cp -a "$src" "$TOOLS/lib/meson"
	printf '#!/bin/sh\nexec python3 "%s/meson.py" "$@"\n' "$TOOLS/lib/meson" >"$TOOLS/bin/meson"
	chmod +x "$TOOLS/bin/meson"
	"$TOOLS/bin/meson" --version >/dev/null || die "meson $v of the recipe does not run with $(python3 --version 2>&1)"
	info "meson $v (recipe) in $TOOLS/bin"
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
	step 75-toolchain-clean toolchain_clean
}

# the build trees and sources of the toolchain (11 GB for arm64) are not needed once it works: the
# stamps keep the steps done, and a step that is run again unpacks and builds anew
toolchain_clean() {
	rm -rf "${OBJ:?}"/{binutils,gcc1,glibc,gcc2,test} "${SRCDIR:?}"/{binutils,gcc,glibc,linux-headers}
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

# can_run_target: the machine runs binaries of the target (the same architecture, or qemu-user
# registered with binfmt_misc)
can_run_target() {
	[[ $ARCH == "$(uname -m)" ]] || [[ -e /proc/sys/fs/binfmt_misc/qemu-$ARCH ]]
}

# in_root ROOT COMMAND...: run a command of ROOT inside it, as its root, with a clean environment;
# sources are downloaded by the root's own curl (the host's resolv.conf). in_rootfs: the rootfs
in_root() {
	local r=$1
	shift
	can_run_target || die "the native builds run $ARCH binaries: same architecture or qemu-user with binfmt_misc"
	mkdir -p "$r/var/cache/burn" "$r/var/lib/burn/bootstrap-recipes" "$BURN_CACHE"
	[[ -e $r/etc/resolv.conf ]] || : >"$r/etc/resolv.conf.bootstrap"
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
	' sh "$r" "$BURN_CACHE" "$RECIPES" "$JOBS" "$@"
}

in_rootfs() { in_root "$ROOTFS" "$@"; }

# root_cleanup ROOT: what in_root left in ROOT (the host's resolv.conf, the recipes' mount point)
root_cleanup() {
	local r=$1
	if [[ -e $r/etc/resolv.conf.bootstrap ]]; then
		rm -f "$r/etc/resolv.conf.bootstrap"
		[[ ! -L $r/etc/resolv.conf ]] || rm -f "$r/etc/resolv.conf"
	fi
	rmdir "$r/var/lib/burn/bootstrap-recipes" 2>/dev/null || true
}

native_cleanup() { root_cleanup "$ROOTFS"; }

native_build() {
	local -a pkgs
	read -ra pkgs <<<"$NATIVE_PACKAGES"
	install_profiles
	trap native_cleanup EXIT
	in_rootfs /usr/bin/burn -R /var/lib/burn/bootstrap-recipes -j "$JOBS" -y install "${pkgs[@]}"
	# a rerun brings what the rootfs built up to the recipes (install only adds)
	in_rootfs /usr/bin/burn -R /var/lib/burn/bootstrap-recipes -j "$JOBS" -y --no-sync update
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
	local c m missing=()
	for c in sfdisk mcopy dd truncate unshare; do
		command -v "$c" >/dev/null || missing+=("$c")
	done
	((${#missing[@]} == 0)) || die "missing host tools for the disk image: ${missing[*]} (util-linux, mtools)"
	# systemd-boot is built here for the image: its meson generates code with jinja2 and elf2efi
	# makes PE files of the ELF loaders with pyelftools, both from the python3 of PATH
	for m in jinja2 elftools; do
		python3 -c "import $m" 2>/dev/null || missing+=("$m")
	done
	((${#missing[@]} == 0)) || die "python3 lacks the modules of the systemd-boot build: ${missing[*]} (python3-jinja2 and python3-pyelftools, or pip install jinja2 pyelftools)"
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
# Wi-Fi (iwd, enabled by the installer where there is Wi-Fi) and an editor for the console (nano)
DISK_PACKAGES=${DISK_PACKAGES:-linux systemd-boot cleanlinux-install iwd nano}

disk_root() {
	local d=$WORK/disk r=$WORK/disk/top/@
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
	package_cache "$r"
}

# package_cache ROOT: the image installs itself: cleanlinux-install runs burn clone, which takes
# the package files of every installed build from ROOT/var/cache/burn/packages
package_cache() {
	local r=$1 meta name version release parch buildid f n=0
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

# root_install ROOT PKG...: burn install into ROOT. When this machine runs the target's binaries and
# ROOT has base-devel, ROOT builds the packages itself (native, as spin_add does: no cross builds of
# Mesa and the tools it runs while it builds, glslangValidator); otherwise burn cross-compiles them
root_install() {
	local r=$1
	shift
	if can_run_target && [[ -d $r/var/lib/burn/installed/base-devel ]]; then
		info "$*: built inside the root (native)"
		in_root "$r" /usr/bin/burn -R /var/lib/burn/bootstrap-recipes -j "$JOBS" -y install "$@"
		root_cleanup "$r"
	else
		burn -r "$r" --host-deps -y install "$@"
	fi
}

# spin_add ROOT SPIN: burn spin add. When this machine runs the target's binaries and ROOT has
# base-devel, ROOT builds the spin itself with its own compiler, as a device does (no cross builds
# of GTK and the tools it runs while it builds); otherwise burn cross-compiles it from here. A
# spin from a directory is built from a copy inside ROOT, which then replaces burn's link to it.
spin_add() {
	local r=$1 s=$2 l src=/var/lib/burn/bootstrap-spin
	if can_run_target && [[ -d $r/var/lib/burn/installed/base-devel ]]; then
		info "spin $s: built inside the root (native)"
		if [[ -d $s ]]; then
			rm -rf "${r:?}$src" && cp -a "$s" "$r$src"
			in_root "$r" /usr/bin/burn -R /var/lib/burn/bootstrap-recipes -j "$JOBS" -y spin add "$src"
			for l in "$r"/var/lib/burn/spins/*; do
				if [[ -L $l && $(readlink "$l") == "$src" ]]; then rm "$l" && mv "$r$src" "$l"; fi
			done
			rm -rf "${r:?}$src"
		else
			in_root "$r" /usr/bin/burn -R /var/lib/burn/bootstrap-recipes -j "$JOBS" -y spin add "$s"
		fi
		root_cleanup "$r"
	else
		burn -r "$r" --host-deps -y spin add "$s"
	fi
}

# disk_spins ROOT: the spins of --spin on top of the base (docs/SPINS.md): burn spin add builds and
# installs their packages and enables their services; a spin from a directory is a link to it,
# which the image replaces with a copy
disk_spins() {
	local r=$1 s src
	for s in "${SPINS[@]}"; do
		spin_add "$r" "$s"
	done
	for s in "$r"/var/lib/burn/spins/*; do
		if [[ -L $s ]]; then
			src=$(readlink -f "$s")
			rm "$s" && cp -a "$src" "$s"
		fi
	done
}

# spin_suffix ROOT: the spins of the image, for its name: -labwc, -kde+steam
spin_suffix() {
	local s names=()
	for s in "$1/var/lib/burn/spins"/*; do
		[[ -d $s ]] && names+=("${s##*/}")
	done
	((${#names[@]})) || return 0
	local IFS=+
	printf -- '-%s' "${names[*]}"
}

disk_image() {
	local d=$WORK/disk r=$WORK/disk/top/@ img esp_uuid root_uuid fs_uuid root_type console help
	local -a mkvfat mkbtrfs
	img=$WORK/cleanlinux-$ARCH-$PROFILE$(spin_suffix "$r").img
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

# ---- live: the live system of a USB stick, which installs itself ----
#
# A disk image for UEFI PCs, boards and handhelds (Secure Boot off), written as it is onto a USB
# stick or an SD card (dd, Rufus in DD mode, balenaEtcher) or given to a virtual machine as a disk:
# GPT with an EFI system partition (systemd-boot, the kernel, an initramfs with the init of
# cleanlinux-boot) and a root partition (btrfs compressed with zstd, or ext4) labelled
# CL_LIVE_<date>, which holds the system as a plain tree and the layers over it:
#
#   @/             the system the installer copies: base, base-devel, the kernel, firmware
#   nonfree/       the proprietary drivers (LIVE_NONFREE), on by default (cleanlinux.live.nonfree=0)
#   spins/NAME/    what a spin adds (--spin: a desktop), the one cleanlinux.live.spin=NAME names
#   live/          what makes it live: root logs in by itself, the installer opens on the console
#
# The init of the initramfs finds the partition by its label and mounts an overlay of live/ over
# spins/NAME/ over nonfree/ over @/ with a tmpfs on top (root=live:LABEL=...; cleanlinux.live.toram
# copies it into memory first). cleanlinux-install copies @/ and the chosen layers onto the disk:
# no network, no package cache, no burn clone. nonfree/ and spins/NAME/ are made against @/ each
# (bootstrap/layer.py: the files a burn install adds or changes, whiteouts for what it removes), so
# a spin works with or without the proprietary drivers. No root privileges are needed.
# docs/INSTALL.md is the user's side of it, tests/live.py installs from it in QEMU.
#
#   LIVE_PACKAGES    on top of DISK_PACKAGES: firmware and the Wi-Fi regulatory database
#   LIVE_FIRMWARE    the firmware of a generic profile (below; "all": the whole of linux-firmware,
#                    2 GB more); a device profile keeps its own FIRMWARE
#   LIVE_NONFREE     the proprietary packages of nonfree/ (x86_64: NVIDIA, the Steam Deck's DSP)
#   LIVE_FS          btrfs (compressed with LIVE_COMPRESS, zstd:15) or ext4 (no compression)
#   LIVE_LABEL       the label the init looks for (CL_LIVE_<date>, up to 16 of A-Z, 0-9 and _)
#   LIVE_BASE_DEVEL  1: the system carries base-devel (the native stage runs first when the rootfs
#                    has not got it), so the systems it installs build their updates and spins
#                    themselves; 0: no native stage for it, the system has what the rootfs has

LIVE_PACKAGES=${LIVE_PACKAGES:-linux-firmware wireless-regdb}
LIVE_BASE_DEVEL=${LIVE_BASE_DEVEL:-1}
LIVE_FS=${LIVE_FS:-btrfs}
LIVE_COMPRESS=${LIVE_COMPRESS:-zstd:15}
# FIRMWARE of the linux-firmware recipe (prefixes under /usr/lib/firmware), kept in
# /etc/burn/burn.conf of the live system and of the systems it installs (unless they get a device
# profile with a list of its own). PCs: the GPUs (AMD, Intel, the GSP firmware nouveau needs for
# NVIDIA Turing and newer), AMD microcode, the Wi-Fi, Bluetooth and Ethernet chips of PCs and
# laptops (Intel, Realtek, MediaTek, Qualcomm Atheros, Broadcom, Marvell), the speaker amplifiers
# of laptops and handhelds (Cirrus CS35L41/CS35L56). ARM: Adreno GPUs and the DSPs of Snapdragon
# handhelds and laptops, Mali (panthor), the Wi-Fi and Bluetooth of boards and handhelds
LIVE_FIRMWARE_PCS=(amdgpu/ radeon/ i915/ xe/ nvidia/ amd-ucode/ intel/iwlwifi/ iwlwifi- intel/ibt- rtw88/ rtw89/
	rtlwifi/ rtl_bt/ rtl_nic/ mediatek/BT_RAM_CODE_MT79 mediatek/WIFI_ mediatek/mt7925/ mediatek/mt7927/ mediatek/mt76
	mediatek/mt7915_ mediatek/mt7916_ ath9k_htc/ ar3k/ ath10k/QCA6174/ ath10k/QCA9377/ ath10k/QCA988X/
	ath11k/WCN6855/ ath11k/QCA2066/ ath11k/QCA6390/ ath12k/WCN7850/ qca/ brcm/ tigon/ mrvl/pcie mrvl/sd
	cirrus/cs35l41 cirrus/cs35l56)
LIVE_FIRMWARE_ARM=(qcom/a3 qcom/a5 qcom/a6 qcom/a7 qcom/gmu_ qcom/venus- qcom/vpu qcom/sm8150/ qcom/sm8250/
	qcom/sm8350/ qcom/sm8450/ qcom/sm8550/ qcom/sm8650/ qcom/qrb4210/ qcom/qcm2290/ qcom/sdm845/ qcom/sc8280xp/
	qcom/x1e80100/ ath10k/WCN3990/ ath11k/ ath12k/ qca/ brcm/ cypress/ rtw88/ rtw89/ rtlwifi/ rtl_bt/ rtl_nic/
	mediatek/mt76 mediatek/WIFI_ mediatek/BT_RAM_CODE_ arm/mali/ rockchip/ meson/ amlogic/ ti-connectivity/)

# live_defaults: LIVE_FIRMWARE and LIVE_NONFREE of the architecture, unless they are set
live_defaults() {
	case $ARCH in
		x86_64)
			LIVE_FIRMWARE=${LIVE_FIRMWARE-${LIVE_FIRMWARE_PCS[*]}}
			LIVE_NONFREE=${LIVE_NONFREE-nvidia steamdeck-dsp}
			;;
		*)
			LIVE_FIRMWARE=${LIVE_FIRMWARE-${LIVE_FIRMWARE_ARM[*]}}
			LIVE_NONFREE=${LIVE_NONFREE-}
			;;
	esac
}

# live_mkfs: mkfs of LIVE_FS for the root partition, one word per line as disk_tool gives it
live_mkfs() {
	case $LIVE_FS in
		btrfs) disk_tool mkfs.btrfs ;;
		ext4) disk_tool mkfs.ext4 ;;
	esac
}

live_check() {
	local help t
	local -a mk
	[[ $LIVE_FS == btrfs || $LIVE_FS == ext4 ]] || die "LIVE_FS=$LIVE_FS: btrfs or ext4"
	[[ -z ${LIVE_LABEL:-} || $LIVE_LABEL =~ ^[A-Z0-9_]{1,16}$ ]] || die "LIVE_LABEL=$LIVE_LABEL: up to 16 of A-Z, 0-9 and _"
	command -v python3 >/dev/null || die "python3 is needed (bootstrap/layer.py makes the layers of the medium)"
	mapfile -t mk < <(live_mkfs)
	((${#mk[@]})) || die "mkfs.$LIVE_FS is needed for the live image (btrfs-progs or e2fsprogs)"
	if [[ $LIVE_FS == btrfs ]]; then
		# not a pipe into grep -q: under pipefail mkfs.btrfs may die of SIGPIPE once grep has its match
		help=$("${mk[@]}" --help 2>&1) || true
		[[ $help == *--compress* && $help == *--shrink* ]] ||
			die "mkfs.btrfs lacks --rootdir --compress --shrink (btrfs-progs 6.13+, or the rootfs's own)"
	else
		for t in e2fsck resize2fs dumpe2fs; do
			[[ -n $(disk_tool "$t") ]] || die "$t (e2fsprogs) is needed for an ext4 live image"
		done
	fi
	# the boot partition is made as the disk image's is (mtools, the systemd-boot build)
	disk_check
}

# live_firmware ROOT: FIRMWARE of LIVE_FIRMWARE into burn.conf, unless the profile lists its own
live_firmware() {
	local r=$1 own
	[[ -n $LIVE_FIRMWARE && $LIVE_FIRMWARE != all ]] || return 0
	own=$(burn -r "$r" profile show | awk '$1 == "firmware" { print $2 }')
	if [[ -n $own && $own != - ]]; then
		info "the profile $PROFILE lists its firmware: LIVE_FIRMWARE is not used"
		return 0
	fi
	printf '%s\n' '' \
		'# the firmware of the CleanLinux live image (linux-firmware): GPUs, Wi-Fi, Bluetooth, sound;' \
		'# without this line linux-firmware is built whole (2 GB), or as the device profile lists it' \
		"FIRMWARE=\"$LIVE_FIRMWARE\"" >>"$r/etc/burn/burn.conf"
}

# live_spin_names ROOT: the spins of ROOT (burn spin add), those of a directory made copies
live_spin_names() {
	local s src
	for s in "$1/var/lib/burn/spins"/*; do
		if [[ -L $s ]]; then
			src=$(readlink -f "$s")
			rm "$s" && cp -a "$src" "$s"
		fi
		[[ -d $s ]] && printf '%s\n' "${s##*/}"
	done
}

live_root() {
	local d=$WORK/live t=$WORK/live/top r=$WORK/live/top/@ w=$WORK/live/work s name
	local -a pkgs names
	if [[ -d $d ]]; then chmod -R u+w "$d" && rm -rf "$d"; fi
	mkdir -p "$t"
	install_profiles
	cp -a --reflink=auto "$ROOTFS" "$r"
	if [[ -n ${DISK_PACKAGE_FEATURES:-} ]]; then
		printf '%s\n' "$DISK_PACKAGE_FEATURES" >"$r/etc/burn/package.features"
	fi
	live_firmware "$r"
	read -ra pkgs <<<"$DISK_PACKAGES $LIVE_PACKAGES"
	burn -r "$r" --host-deps -y install "${pkgs[@]}"
	burn -r "$r" doctor
	# wired network at boot (dinitctl enable dhcpcd), here and on the systems it installs
	mkdir -p "$r/etc/dinit.d/boot.d"
	ln -sfn /usr/lib/dinit.d/dhcpcd "$r/etc/dinit.d/boot.d/dhcpcd"
	rm -rf "$r/var/cache/burn"/*

	# the proprietary drivers: what installing them adds to @ (NVIDIA brings Mesa, Wayland and X11
	# libraries: built inside the root, as the spins are)
	if [[ -n $LIVE_NONFREE ]]; then
		cp -a --reflink=auto "$r" "$w"
		printf '%s\n' '' '# the proprietary drivers of the live image (its layer nonfree/)' 'ALLOW_NONFREE=1' \
			>>"$w/etc/burn/burn.conf"
		read -ra pkgs <<<"$LIVE_NONFREE"
		root_install "$w" "${pkgs[@]}"
		burn -r "$w" doctor
		rm -rf "$w/var/cache/burn"/*
		python3 "$HERE/layer.py" "$r" "$w" "$t/nonfree"
		chmod -R u+w "$w" && rm -rf "$w"
	fi

	# the spins: what each adds to @, a layer of its own
	for s in "${SPINS[@]}"; do
		cp -a --reflink=auto "$r" "$w"
		spin_add "$w" "$s"
		mapfile -t names < <(live_spin_names "$w")
		((${#names[@]} == 1)) || die "the spin $s: ${#names[@]} spins in the root after burn spin add"
		name=${names[0]}
		[[ ! -e $t/spins/$name ]] || die "the spin $name twice"
		burn -r "$w" doctor
		rm -rf "$w/var/cache/burn"/*
		mkdir -p "$t/spins"
		python3 "$HERE/layer.py" "$r" "$w" "$t/spins/$name"
		chmod -R u+w "$w" && rm -rf "$w"
	done

	live_layer "$r" "$t/live"
	du -sh "$t"/* "$t"/spins/* "$r/usr/lib/firmware" "$r/usr/lib/modules"
}

# live_layer ROOT LAYER: what makes ROOT a live system, a layer of its own: root logged in on the
# consoles (agetty --autologin; root keeps no password, there is none to type), the installer at
# that login (cleanlinux-setup --auto: on the main console, once), Wi-Fi (iwd) next to wired
# networking, the hints of /etc/motd. The installed system has none of it: cleanlinux-install
# copies @/ and the layers it chose, then sets up the users, the disk and the boot.
live_layer() {
	local r=$1 l=$2 agetty=/usr/bin/agetty dir
	[[ -x $r$agetty ]] || die "$agetty is not in the root"
	# the directories with the modes of the root, which an overlay takes from the top layer
	for dir in etc etc/dinit.d etc/dinit.d/boot.d root; do
		mkdir -p "$l/$dir"
		if [[ -d $r/$dir ]]; then chmod --reference="$r/$dir" "$l/$dir"; fi
	done
	chmod 0700 "$l/root"
	echo cleanlinux-live >"$l/etc/hostname"
	printf '%s\n' '# the live system: / is an overlay of the layers of the medium with a tmpfs (cleanlinux-boot)' \
		'tmpfs /tmp tmpfs nosuid,nodev 0 0' >"$l/etc/fstab"
	if [[ -e $r/usr/lib/dinit.d/iwd ]]; then
		ln -sfn /usr/lib/dinit.d/iwd "$l/etc/dinit.d/boot.d/iwd"
	fi
	cat >"$l/etc/dinit.d/getty" <<-EOF
		# CleanLinux live: root logs in by itself on the virtual terminals (getty@tty1, getty@tty2...)
		type = process
		command = $agetty --noclear --autologin root \$1 linux
		restart = true
		smooth-recovery = true
		termsignal = HUP
		depends-on: system
	EOF
	cat >"$l/etc/dinit.d/serial-getty" <<-EOF
		# CleanLinux live: root logs in by itself on the serial consoles (serial-getty@ttyS0...)
		type = process
		command = $agetty -L --autologin root 115200,57600,38400,9600 \$1 vt220
		restart = true
		smooth-recovery = true
		termsignal = HUP
		depends-on: system
	EOF
	cat >"$l/root/.bash_profile" <<-'EOF'
		# CleanLinux live: the installer opens on the main console when root logs in there, once
		# (closed, it opens again with: cleanlinux-setup)
		[[ -f ~/.bashrc ]] && . ~/.bashrc
		cleanlinux-setup --auto
	EOF
	cat >"$l/etc/motd" <<-'EOF'

		CleanLinux live system

		  cleanlinux-setup     install CleanLinux on this computer, screen by screen
		  cleanlinux-install   the same from the command line (--help)
		  iwctl                Wi-Fi: iwctl station wlan0 scan, iwctl station wlan0 connect NAME
		  loadkeys ru          a keyboard layout for the console (setfont cyr-sun16: Cyrillic)
		  poweroff, reboot

		Everything changed here stays in memory and is gone after a reboot.

	EOF
}

# live_entry ENTRY N TITLE OPTIONS: the boot entry of kernel sync with another title, place and
# more kernel options
live_entry() {
	awk -v n="$2" -v title="$3" -v extra="$4" '
		/^title / { print "title " title; next }
		/^sort-key / { print "sort-key cleanlinux-live-" n; next }
		/^options / { print $0 (extra == "" ? "" : " " extra); next }
		{ print }' "$1"
}

# live_esp ROOT LABEL ESP: systemd-boot, the kernel and an initramfs with the init that finds the
# medium by its label and mounts its layers (root=live:), as kernel sync makes them for ROOT with
# the live settings; ROOT is left as it was (it is the system the installer copies)
live_esp() {
	local r=$1 label=$2 esp=$3 x saved=$WORK/live/saved
	local -a made=()
	rm -rf "$saved" "$esp" && mkdir -p "$saved" "$esp"
	if [[ -e $r/etc/kernel/cmdline ]]; then mv "$r/etc/kernel/cmdline" "$saved/cmdline"; fi
	if [[ -e $r/var/lib/cleanlinux ]]; then mv "$r/var/lib/cleanlinux" "$saved/var-lib-cleanlinux"; fi
	for x in etc/kernel etc/cleanlinux etc/cleanlinux/initramfs.d; do
		if [[ ! -d $r/$x ]]; then mkdir "$r/$x" && made=("$x" "${made[@]}"); fi
	done
	printf '%s\n' '# the live system (bootstrap.sh live): the init that finds the medium and mounts its layers' \
		'enable=yes' >"$r/etc/cleanlinux/initramfs.d/10-live.conf"
	printf '%s\n' "root=live:LABEL=$label" >"$r/etc/kernel/cmdline"
	run_target "$r/usr/bin/cleanlinux-boot" --root "$r" kernel sync --esp "$esp"
	rm -rf "$r/etc/cleanlinux/initramfs.d/10-live.conf" "$r/etc/kernel/cmdline" "$r/var/lib/cleanlinux"
	for x in "${made[@]}"; do rmdir "$r/$x"; done
	if [[ -e $saved/cmdline ]]; then mv "$saved/cmdline" "$r/etc/kernel/cmdline"; fi
	if [[ -e $saved/var-lib-cleanlinux ]]; then mv "$saved/var-lib-cleanlinux" "$r/var/lib/cleanlinux"; fi
	rmdir "$saved"
}

# live_fs TOP LABEL IMAGE: the root partition from the tree TOP, as small as it gets, every file
# owned by root (in a user namespace, which reads every file whatever its mode)
live_fs() {
	local top=$1 label=$2 img=$3 mb n bs count
	local -a mk fsck resize dump
	mapfile -t mk < <(live_mkfs)
	mb=$(du -sm --apparent-size "$top" | cut -f1)
	rm -f "$img"
	case $LIVE_FS in
		btrfs)
			# plain directories, no subvolumes; single metadata (the medium is read, not written)
			truncate -s $((mb + mb / 2 + 512))M "$img"
			unshare -r "${mk[@]}" -f -q -L "$label" -m single -d single --rootdir "$top" \
				--compress "$LIVE_COMPRESS" --shrink "$img"
			;;
		ext4)
			mapfile -t fsck < <(disk_tool e2fsck)
			mapfile -t resize < <(disk_tool resize2fs)
			mapfile -t dump < <(disk_tool dumpe2fs)
			n=$(find "$top" | wc -l)
			truncate -s $((mb + mb / 4 + 256))M "$img"
			# no journal and no reserved blocks: nothing writes to it
			unshare -r "${mk[@]}" -q -F -L "$label" -O ^has_journal -m 0 -N $((n + n / 10 + 4096)) -d "$top" "$img"
			"${fsck[@]}" -fy "$img" >/dev/null
			"${resize[@]}" -M "$img"
			bs=$("${dump[@]}" -h "$img" 2>/dev/null | awk -F: '$1 == "Block size" { print $2 + 0 }')
			count=$("${dump[@]}" -h "$img" 2>/dev/null | awk -F: '$1 == "Block count" { print $2 + 0 }')
			truncate -s $((bs * count)) "$img"
			;;
	esac
}

live_image() {
	local d=$WORK/live t=$WORK/live/top r=$WORK/live/top/@ date label img entry e serial efi screen kib s spin=''
	local default=1-live.conf suffix='' sums
	local -a mkvfat names=()
	date=$(date -u +%Y%m%d)
	label=${LIVE_LABEL:-CL_LIVE_$date}
	for s in "$t"/spins/*/; do
		s=${s%/} && names+=("${s##*/}")
	done
	if ((${#names[@]})); then suffix=-$(IFS=+ && echo "${names[*]}"); fi
	img=$WORK/cleanlinux-$ARCH-${PROFILE##*/}$suffix-$date.img
	# screen: the options of the entries for a screen. arm64 firmware names a serial console of its
	# own (ACPI SPCR, the device tree's stdout-path), which the kernel makes the main console unless
	# console= says otherwise: the installer and the desktop of the live system would go to the serial
	# line, not to the screen (QEMU virt, servers, boards and handhelds with a debug UART)
	case $ARCH in
		x86_64) serial='console=tty0 console=ttyS0,115200' efi=BOOTX64.EFI screen='' ;;
		aarch64) serial='console=tty0 console=ttyAMA0,115200' efi=BOOTAA64.EFI screen='console=tty0 ' ;;
	esac
	mapfile -t mkvfat < <(disk_tool mkfs.vfat)
	((${#mkvfat[@]})) || die "mkfs.vfat (dosfstools) is needed for the live image"

	# the boot partition: the menu, the first spin by default (a desktop), then the console
	live_esp "$r" "$label" "$d/esp"
	e=$d/esp/loader/entries
	entry=$(find "$e" -name 'cleanlinux-*.conf' | sort -V | tail -n 1)
	[[ -n $entry ]] || die "kernel sync wrote no boot entry"
	[[ -f $d/esp/EFI/BOOT/$efi ]] || die "kernel sync put no EFI/BOOT/$efi into the boot partition"
	grep -q '^initrd ' "$entry" || die "the boot entry has no initramfs: $entry"
	for s in "${names[@]}"; do
		live_entry "$entry" "0-$s" "CleanLinux live ($s)" "${screen}quiet cleanlinux.live.spin=$s" >"$e/0-$s.conf"
		if [[ -z $spin ]]; then spin="cleanlinux.live.spin=$s" default=0-$s.conf; fi
	done
	live_entry "$entry" 1 "CleanLinux live${spin:+ (console)}" "${screen}quiet" >"$e/1-live.conf"
	live_entry "$entry" 2 "CleanLinux live (copy to RAM)" "${screen}quiet cleanlinux.live.toram${spin:+ $spin}" \
		>"$e/2-toram.conf"
	live_entry "$entry" 3 "CleanLinux live (safe graphics)" "${screen}nomodeset${spin:+ $spin}" >"$e/3-safe-graphics.conf"
	if [[ -d $t/nonfree ]]; then
		live_entry "$entry" 4 "CleanLinux live (no proprietary drivers)" \
			"${screen}quiet cleanlinux.live.nonfree=0${spin:+ $spin}" >"$e/4-free-drivers.conf"
	fi
	live_entry "$entry" 5 "CleanLinux live (serial console)" "$serial" >"$e/5-serial.conf"
	rm "$entry"
	printf '%s\n' '# the boot menu of the CleanLinux live image (systemd-boot; e edits an entry)' "default $default" \
		'timeout 5' 'editor yes' 'console-mode keep' >"$d/esp/loader/loader.conf"
	head -n 50 "$e"/*.conf
	kib=$(du -sk --apparent-size "$d/esp" | cut -f1)
	rm -f "$d/esp.img"
	"${mkvfat[@]}" -C -n CL_EFI "$d/esp.img" $((kib + kib / 8 + 4096))
	MTOOLS_SKIP_CHECK=1 mcopy -s -m -Q -i "$d/esp.img" "$d/esp"/* ::/
	cat >"$t/README.txt" <<-EOF
		CleanLinux live $date ($ARCH, profile $PROFILE): https://github.com/vovawees/CleanLinux

		@/ is the system, nonfree/ the proprietary drivers, spins/NAME/ what a spin adds, live/ what
		makes it live: the boot loader's menu picks the layers, the installer copies them to a disk.
	EOF

	# the root partition, then GPT: the boot partition from 1 MiB, the root after it, 1 MiB for
	# the backup table at the end
	live_fs "$t" "$label" "$d/root.img"
	local esp_start=2048 esp_mib root_mib esp_sectors root_start root_sectors
	esp_mib=$((($(stat -c %s "$d/esp.img") + 1048575) / 1048576))
	root_mib=$((($(stat -c %s "$d/root.img") + 1048575) / 1048576))
	esp_sectors=$((esp_mib * 2048)) root_sectors=$((root_mib * 2048))
	root_start=$((esp_start + esp_sectors))
	rm -f "$img" "$img.sha256"
	truncate -s $(((root_start + root_sectors + 2048) * 512)) "$img"
	printf '%s\n' 'label: gpt' \
		"start=$esp_start, size=$esp_sectors, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"EFI system partition\"" \
		"start=$root_start, size=$root_sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"CleanLinux live\"" |
		sfdisk -q "$img"
	sfdisk -d "$img"
	dd if="$d/esp.img" of="$img" bs=1M seek=$((esp_start * 512)) oflag=seek_bytes conv=notrunc,sparse status=none
	dd if="$d/root.img" of="$img" bs=1M seek=$((root_start * 512)) oflag=seek_bytes conv=notrunc,sparse status=none
	(cd "${img%/*}" && sha256sum "${img##*/}" >"${img##*/}.sha256")
	sums=$(du -sh "$t"/* | tr '\t' ' ' | tr '\n' ',')
	info "the medium: ${sums%,}; the root partition $root_mib MiB ($LIVE_FS)"
	chmod -R u+w "$d" && rm -rf "$d"
	ls -lhs "$img"
	cat "$img.sha256"
}

stage_live() {
	info "== stage live"
	[[ -f $STAMPS/80-base ]] || die "run the base stage first"
	live_defaults
	# burn builds from source on the device: a system with no compiler could neither update nor
	# take a spin. perl and python of base-devel do not cross-compile: the native stage builds them
	if [[ $LIVE_BASE_DEVEL == 1 && ! -d $ROOTFS/var/lib/burn/installed/base-devel ]]; then
		info "the live system carries base-devel (LIVE_BASE_DEVEL=1): the native stage first"
		stage_native
	fi
	rm -f "$STAMPS/94-disk-native" "$STAMPS/95-live-check" "$STAMPS/96-live-root" "$STAMPS/97-live-image"
	step 94-disk-native disk_native
	step 95-live-check live_check
	step 96-live-root live_root
	step 97-live-image live_image
}
