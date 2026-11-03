# shellcheck shell=bash
# Rust/Cargo. Crates are fetched in prepare (Cargo.lock is required), the build itself is offline.
# Recipe knobs: cargo_args=() (e.g. --features x), do_install() for extra files

rust_target() {
	case $CARCH in
		x86_64) printf 'x86_64-unknown-linux-gnu\n' ;;
		aarch64) printf 'aarch64-unknown-linux-gnu\n' ;;
		*) die "$name: no Rust target for $CARCH" ;;
	esac
}

# -march=znver2 / -mcpu=cortex-a73.cortex-a53 / native -> rustc target-cpu
rust_cpu() {
	local c=$CPU_CFLAGS
	case $c in
		*=native*) printf 'native\n' ;;
		-march=x86-64* | -mcpu=* | -march=*) c=${c%% *} c=${c#*=} c=${c%%.*} c=${c%%+*}
			[[ $c == armv* ]] && c=generic
			printf '%s\n' "$c" ;;
		*) printf 'generic\n' ;;
	esac
}

cargo_env() {
	local t
	t=$(rust_target)
	export CARGO_HOME=$CACHE_DIR/cargo CARGO_TARGET_DIR=$BUILD CARGO_BUILD_TARGET=$t
	RUSTFLAGS="-C opt-level=3 -C target-cpu=$(rust_cpu) -C link-arg=-Wl,-z,relro,-z,now ${RUSTFLAGS:-}"
	export RUSTFLAGS
	if ((CROSS)); then
		local v=${t^^}
		v=${v//-/_}
		export "CARGO_TARGET_${v}_LINKER=$CC"
		export "CARGO_TARGET_${v}_RUSTFLAGS=-C link-arg=--sysroot=$SYSROOT"
	fi
	if ((LTO_ON)); then export CARGO_PROFILE_RELEASE_LTO=thin; fi
}

bt_prepare() {
	cargo_env
	cd "$SRC"
	[[ -f Cargo.lock ]] || die "$name: Cargo.lock missing (reproducible builds need it)"
	cargo fetch --locked --target "$CARGO_BUILD_TARGET"
}

bt_build() {
	cargo_env
	cd "$SRC"
	cargo build --release --frozen "${cargo_args[@]}"
}

bt_check() {
	cargo_env
	cd "$SRC"
	cargo test --release --frozen "${cargo_args[@]}"
}

bt_install() {
	cargo_env
	cd "$SRC"
	cargo install --frozen --offline --no-track --path . --root "$DESTDIR/usr" "${cargo_args[@]}"
}
