# shellcheck shell=bash
# CMake (Ninja when available). CMAKE_BUILD_TYPE=None: only the profile flags are used.
# Recipe knobs: cmake_args=(), cmake_extra(), cmake_subdir=

bt_configure() {
	local -a args=() extra=()
	local gen='Unix Makefiles'
	have ninja && gen=Ninja
	args=(-G "$gen" -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_LIBEXECDIR=lib
		-DCMAKE_INSTALL_BINDIR=bin -DCMAKE_INSTALL_SBINDIR=bin -DCMAKE_INSTALL_SYSCONFDIR=/etc
		-DCMAKE_INSTALL_LOCALSTATEDIR=/var -DCMAKE_BUILD_TYPE=None
		-DCMAKE_AR="$(command -v "$AR")" -DCMAKE_RANLIB="$(command -v "$RANLIB")"
		-DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -Wno-dev)
	if ((CROSS)); then
		args+=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="$CARCH" -DCMAKE_SYSROOT="$SYSROOT"
			-DCMAKE_FIND_ROOT_PATH="$SYSROOT" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
			-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
			-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY)
	elif [[ -n $R ]]; then
		args+=(-DCMAKE_PREFIX_PATH="$R/usr")
	fi
	mapfile -t extra < <(run_fn cmake_extra)
	cmake -S "$SRC${cmake_subdir:+/$cmake_subdir}" -B "$BUILD" "${args[@]}" "${cmake_args[@]}" "${extra[@]}"
}

bt_build() { cmake --build "$BUILD" -j "$JOBS"; }
bt_check() { ctest --test-dir "$BUILD" --output-on-failure -j "$JOBS"; }
bt_install() { DESTDIR="$DESTDIR" cmake --install "$BUILD"; }
