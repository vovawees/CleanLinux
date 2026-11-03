# shellcheck shell=bash
# Plain Makefiles (no configure step). CC/CFLAGS/... come from the environment.
# Recipe knobs: make_args=(), make_install_args=()

bt_build() {
	cd "$SRC"
	make PREFIX=/usr "${make_args[@]}"
}

bt_check() {
	cd "$SRC"
	make PREFIX=/usr "${make_args[@]}" check
}

bt_install() {
	cd "$SRC"
	make PREFIX=/usr DESTDIR="$DESTDIR" "${make_args[@]}" "${make_install_args[@]}" install
}
