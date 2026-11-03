# shellcheck shell=bash
# Stages and steps of the bootstrap. Every step runs in a subshell with errexit, logs to
# $LOGS/<step>.log and leaves a stamp, so an interrupted bootstrap resumes where it stopped.

info() { printf '\033[1;36m::\033[0m %s\n' "$*" >&2; }
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
		d=$(broom unpack "$1" "$SRCDIR/$1") || die "unpacking $1 failed, see $SRCDIR/$1/unpack.log"
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
	glibc_ver=$(broom query glibc version)
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
	mkdir -p "$ROOTFS/etc/broom"
	printf 'PROFILE=%s\n' "$PROFILE" >"$ROOTFS/etc/broom/broom.conf"
	# glibc and the kernel headers again, this time as tracked packages built with the profile flags
	broom -r "$ROOTFS" --host-deps -y install filesystem linux-headers glibc
	broom -r "$ROOTFS" --host-deps -y install base
	broom -r "$ROOTFS" doctor
}

stage_base() {
	info "== stage base"
	[[ -f $STAMPS/70-toolchain-test ]] || die "run the toolchain stage first"
	step 80-base base_install
}

install_broom() {
	local dst=$ROOTFS/usr/lib/broom
	rm -rf "$dst" && mkdir -p "$dst" "$ROOTFS/usr/share/broom" "$ROOTFS/etc/broom/hooks/pre-update.d"
	cp -r "$TOP/broom/broom" "$TOP/broom/lib" "$TOP/broom/buildtypes" "$dst/"
	cp -r "$TOP/profiles" "$ROOTFS/usr/share/broom/"
	cp "$TOP/broom/broom.conf" "$ROOTFS/usr/share/broom/broom.conf.example"
	cp "$TOP/broom/hooks/pre-update.d/"* "$ROOTFS/etc/broom/hooks/pre-update.d/"
	ln -sfn ../lib/broom/broom "$ROOTFS/usr/bin/broom"
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
			out=$($s chroot "$ROOTFS" /usr/bin/bash -c '. /etc/profile; echo "bash $BASH_VERSION"; ls /; zstd --version; broom --version; broom list | wc -l; broom doctor')
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
	rm -f "$STAMPS/90-broom" "$STAMPS/91-rootfs-test" "$STAMPS/99-tarball"
	step 90-broom install_broom
	step 91-rootfs-test rootfs_test
	step 99-tarball make_tarball
}
