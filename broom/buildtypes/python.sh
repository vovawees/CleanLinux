# shellcheck shell=bash
# Python packages (PEP 517). Uses build+installer when present, pip otherwise.

bt_build() {
	((CROSS == 0)) || die "$name: cross builds of Python packages are not supported yet"
	cd "$SRC"
	if python3 -c 'import build, installer' 2>/dev/null; then
		python3 -m build --wheel --no-isolation --outdir "$BUILD"
	else
		python3 -m pip wheel --no-deps --no-build-isolation --wheel-dir "$BUILD" .
	fi
}

bt_check() {
	cd "$SRC"
	python3 -m pytest
}

bt_install() {
	local w=("$BUILD"/*.whl)
	((${#w[@]})) || die "$name: no wheel was built"
	if python3 -c 'import installer' 2>/dev/null; then
		python3 -m installer --destdir="$DESTDIR" --prefix=/usr "${w[@]}"
	else
		python3 -m pip install --no-deps --no-index --root="$DESTDIR" --prefix=/usr "${w[@]}"
	fi
}
