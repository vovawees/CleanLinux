# shellcheck shell=bash
# GNU autotools: ./configure && make && make install
# Recipe knobs: configure_args=(), configure_extra(), out_of_tree=1, make_args=(), make_install_args=()

bt_dir() { if ((out_of_tree)); then printf '%s\n' "$BUILD"; else printf '%s\n' "$SRC"; fi; }

bt_configure() {
	local -a args=() extra=()
	if [[ ! -x $SRC/configure ]]; then
		[[ -f $SRC/configure.ac || -f $SRC/configure.in ]] || die "$name: no configure script"
		(cd "$SRC" && autoreconf -fi)
	fi
	cd "$(bt_dir)"
	args=(--prefix=/usr --sysconfdir=/etc --localstatedir=/var
		--bindir=/usr/bin --sbindir=/usr/bin --libdir=/usr/lib --libexecdir=/usr/lib
		--mandir=/usr/share/man --infodir=/usr/share/info
		--build="$CBUILD" --host="$CHOST" --disable-dependency-tracking)
	[[ -n $LOCALES ]] || args+=(--disable-nls)
	mapfile -t extra < <(run_fn configure_extra)
	"$SRC/configure" "${args[@]}" "${configure_args[@]}" "${extra[@]}"
}

bt_build() {
	cd "$(bt_dir)"
	make "${make_args[@]}"
}

bt_check() {
	cd "$(bt_dir)"
	make "${make_args[@]}" check
}

bt_install() {
	cd "$(bt_dir)"
	make DESTDIR="$DESTDIR" "${make_args[@]}" "${make_install_args[@]}" install
}
