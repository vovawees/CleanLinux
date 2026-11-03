# shellcheck shell=bash
# Meson + Ninja. Auto features are disabled by default (MESON_AUTO_FEATURES): a package only
# gets what its recipe enables, so builds are deterministic and minimal.
# Recipe knobs: meson_args=(), meson_extra(), meson_subdir=

# meson_list "a b c" -> ['a', 'b', 'c']
meson_list() {
	local w out=''
	for w in $1; do out+="'$w', "; done
	printf '[%s]' "${out%, }"
}

# Both "pkg-config" (meson >= 1.3) and the older "pkgconfig" key are written; meson accepts the
# pair as long as the values match.
meson_cross_file() {
	local f=$WORK/cross.ini fam=$CARCH
	case $CARCH in arm*) fam=arm ;; esac
	cat >"$f" <<CROSS
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
nm = '$NM'
strip = '$STRIP'
objcopy = '$OBJCOPY'
pkg-config = '${PKG_CONFIG:-pkg-config}'
pkgconfig = '${PKG_CONFIG:-pkg-config}'

[built-in options]
c_args = $(meson_list "$CFLAGS")
cpp_args = $(meson_list "$CXXFLAGS")
c_link_args = $(meson_list "$LDFLAGS")
cpp_link_args = $(meson_list "$LDFLAGS")

[properties]
sys_root = '$SYSROOT'
pkg_config_libdir = '$PKG_CONFIG_LIBDIR'

[host_machine]
system = 'linux'
cpu_family = '$fam'
cpu = '$CARCH'
endian = 'little'
CROSS
	printf '%s\n' "$f"
}

bt_configure() {
	local -a args=() extra=() env=()
	args=(--prefix=/usr --sysconfdir=/etc --localstatedir=/var --libdir=lib --libexecdir=lib
		--bindir=bin --sbindir=bin --buildtype=plain --wrap-mode=nodownload
		--auto-features="$MESON_AUTO_FEATURES" -Db_pie=true -Db_staticpic=true)
	mapfile -t extra < <(run_fn meson_extra)
	if ((CROSS)); then
		args+=(--cross-file "$(meson_cross_file)")
		env=(-u CFLAGS -u CXXFLAGS -u LDFLAGS)
	fi
	env "${env[@]}" meson setup "${args[@]}" "${meson_args[@]}" "${extra[@]}" "$BUILD" "$SRC${meson_subdir:+/$meson_subdir}"
}

bt_build() { meson compile -C "$BUILD" -j "$JOBS"; }
bt_check() { meson test -C "$BUILD" --print-errorlogs; }
bt_install() { meson install -C "$BUILD" --no-rebuild --destdir "$DESTDIR"; }
