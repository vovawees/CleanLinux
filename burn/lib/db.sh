# shellcheck shell=bash
# Installed-package database ($ROOT/var/lib/burn/installed/<name>/{meta,files,provides-so,needs-so}).

db_has() { [[ -f $DB_DIR/$1/meta ]]; }
db_get() { sed -n "s/^$2=//p" "$DB_DIR/$1/meta" | head -n1; }
db_list() {
	local d
	for d in "$DB_DIR"/*/meta; do
		d=${d%/meta}
		printf '%s\n' "${d##*/}"
	done
}

db_conflicts() { # NAME NEWLIST
	local p
	for p in $(db_list); do
		[[ $p == "$1" ]] && continue
		awk -v pkg="$p" 'NR == FNR { if ($0 !~ /\/$/) want[$0] = 1; next } ($0 in want) { print "  /" $0 " (owned by " pkg ")" }' \
			"$2" "$DB_DIR/$p/files"
	done
}

db_rdeps() {
	local p out=()
	for p in $(db_list); do
		[[ $p == "$1" ]] && continue
		# shellcheck disable=SC2046
		if in_list "$1" $(db_get "$p" depends); then out+=("$p"); fi
	done
	printf '%s' "${out[*]}"
}

is_held() { [[ -f $HOLD_FILE ]] && grep -qxF -- "$1" "$HOLD_FILE"; }

# history: date|operation|name|old version|new version|previous package file
history_add() {
	mkdir -p "$STATE_DIR"
	printf '%s|%s|%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" >>"$STATE_DIR/history"
}

pkg_install_file() {
	local file=$1 tmp name ver old='' old_file='' conflicts b
	local -a keep=()
	mkdir -p "$WORK_DIR"
	tmp=$(mktemp -d "$WORK_DIR/.install.XXXXXX")
	zstd -dcq "$file" | tar -xf - -C "$tmp" ./.BURN
	name=$(sed -n 's/^name=//p' "$tmp/.BURN/meta")
	[[ -n $name ]] || die "$file is not a burn package"
	ver=$(sed -n 's/^version=//p' "$tmp/.BURN/meta")-$(sed -n 's/^release=//p' "$tmp/.BURN/meta")
	if db_has "$name"; then
		old=$(db_get "$name" version)-$(db_get "$name" release)
		old_file=$CACHE_DIR/packages/$name-$old-$(db_get "$name" arch)-$(db_get "$name" buildid).pkg.tar.zst
		if [[ $(db_get "$name" buildid) == "$(sed -n 's/^buildid=//p' "$tmp/.BURN/meta")" && $FORCE == 0 && $REBUILD == 0 ]]; then
			msg2 "$name $ver is already installed"
			rm -rf "$tmp"
			return 0
		fi
	fi
	conflicts=$(db_conflicts "$name" "$tmp/.BURN/files")
	if [[ -n $conflicts ]]; then
		printf '%s\n' "$conflicts" | head -n 20 >&2
		((FORCE)) || die "$name: file conflicts with installed packages (use --force to overwrite)"
	fi
	if [[ -z $old ]]; then
		msg "Installing $name $ver"
	elif [[ $old == "$ver" ]]; then
		msg "Rebuilding $name $ver"
	elif [[ $(vercmp "$old" "$ver") == 1 ]]; then
		msg "Downgrading $name $old -> $ver"
	else
		msg "Upgrading $name $old -> $ver"
	fi
	# config protection: never overwrite existing files listed in backup=()
	# shellcheck disable=SC2013 # backup= holds space separated paths
	for b in $(sed -n 's/^backup=//p' "$tmp/.BURN/meta"); do
		if [[ -e $R/$b ]]; then
			mkdir -p "$tmp/keep/${b%/*}"
			cp -a "$R/$b" "$tmp/keep/$b"
			keep+=("$b")
		fi
	done
	mkdir -p "$ROOT"
	zstd -dcq "$file" | tar -xpf - -C "$ROOT" --keep-directory-symlink --no-overwrite-dir --exclude=./.BURN
	for b in "${keep[@]}"; do
		if ! cmp -s "$tmp/keep/$b" "$R/$b"; then
			mv -f "$R/$b" "$R/$b.burnnew"
			cp -a "$tmp/keep/$b" "$R/$b"
			warn "kept your /$b; the new default is /$b.burnnew"
		fi
	done
	if [[ -n $old ]]; then
		remove_obsolete "$name" "$DB_DIR/$name/files" "$tmp/.BURN/files" "$tmp/.BURN/preserved"
		[[ -f $DB_DIR/$name/preserved ]] && cat "$DB_DIR/$name/preserved" >>"$tmp/.BURN/preserved"
		LC_ALL=C comm -23 "$DB_DIR/$name/provides-so" "$tmp/.BURN/provides-so" >>"$WORK_DIR/.lost-sonames"
	fi
	mkdir -p "$DB_DIR"
	rm -rf "${DB_DIR:?}/$name"
	cp -a "$tmp/.BURN" "$DB_DIR/$name"
	rm -rf "$tmp"
	if [[ -n $old ]]; then
		history_add "${TXN_OP:-upgrade}" "$name" "$old" "$ver" "$old_file"
	else
		history_add "${TXN_OP:-install}" "$name" - "$ver" ""
	fi
	run_triggers "$DB_DIR/$name/files"
}

# remove_obsolete NAME OLDLIST NEWLIST PRESERVED_OUT
# Files of the old version that the new one dropped are deleted, except shared libraries
# that other installed packages still link against ("preserved libs", rebuilt later).
remove_obsolete() {
	local f t needed
	local -a obsolete=() keep=()
	mapfile -t obsolete < <(LC_ALL=C comm -23 <(LC_ALL=C sort "$2") <(LC_ALL=C sort "$3"))
	needed=$(cat "$DB_DIR"/*/needs-so 2>/dev/null | LC_ALL=C sort -u)
	for f in "${obsolete[@]}"; do
		[[ -n $f && $f != */ && ${f##*/} == *.so.* ]] || continue
		grep -qxF -- "${f##*/}" <<<"$needed" || continue
		keep+=("$f")
		if [[ -L $R/$f ]]; then
			t=$(readlink "$R/$f")
			if [[ $t == /* ]]; then keep+=("${t#/}"); else keep+=("${f%/*}/$t"); fi
		fi
	done
	for f in "${obsolete[@]}"; do
		[[ -n $f && $f != */ ]] || continue
		if in_list "$f" "${keep[@]}"; then
			warn "preserving /$f: still needed by installed packages"
			printf '%s\n' "$f" >>"$4"
			continue
		fi
		rm -f "$R/$f"
	done
	printf '%s\n' "${obsolete[@]}" | sed -n '/\/$/p' | LC_ALL=C sort -r | while IFS= read -r f; do
		rmdir "$R/$f" 2>/dev/null || true
	done
}

run_triggers() {
	if [[ $(id -u) == 0 ]] && have ldconfig && grep -q '^usr/lib/[^/]*\.so' "$1"; then
		if [[ -z $R ]]; then ldconfig; elif [[ -f $R/etc/ld.so.conf ]]; then ldconfig -r "$R" 2>/dev/null || true; fi
	fi
	if grep -q '^usr/lib/modules/.' "$1"; then modules_trigger; fi
	return 0
}

# Kernel modules changed (a kernel or a module package was installed, upgraded or removed):
# depmod for every installed kernel, and the depmod output of kernels that are gone is removed.
modules_trigger() {
	local dir f
	for dir in "$R"/usr/lib/modules/*/; do
		dir=${dir%/}
		if [[ -f $dir/modules.order ]]; then
			depmod_run "${dir##*/}"
		else
			for f in modules.alias modules.alias.bin modules.builtin.alias.bin modules.builtin.bin modules.dep \
				modules.dep.bin modules.devname modules.softdep modules.symbols modules.symbols.bin modules.weakdep; do
				rm -f "$dir/$f"
			done
			rmdir "$dir" 2>/dev/null || true
		fi
	done
	return 0
}

# depmod KVER with the root's own kmod when it can run here, otherwise the host's (the index
# files are portable); without either, the boot service generates them at the next boot.
depmod_run() {
	local kver=$1 host
	host=$(PATH=$PATH:/usr/sbin:/sbin command -v depmod) || host=''
	if [[ -z $R ]]; then
		if [[ -n $host ]] && "$host" "$kver"; then return 0; fi
	elif [[ -e $R/usr/bin/depmod ]] && root_run depmod -b "$R" "$kver" 2>/dev/null; then
		return 0
	elif [[ -n $host ]] && "$host" -b "$R" "$kver" 2>/dev/null; then
		return 0
	fi
	warn "depmod could not run: modules.dep for kernel $kver is generated at the next boot"
}

pkg_remove() {
	local name=$1 rdeps f
	local -a backups=()
	db_has "$name" || die "$name is not installed"
	if in_list "$name" "${ESSENTIAL[@]}" && ((FORCE == 0)); then die "$name is essential (use --force)"; fi
	rdeps=$(db_rdeps "$name")
	if [[ -n $rdeps ]] && ((FORCE == 0)); then die "$name is required by: $rdeps"; fi
	msg "Removing $name $(db_get "$name" version)-$(db_get "$name" release)"
	read -r -a backups <<<"$(db_get "$name" backup)"
	while IFS= read -r f; do
		[[ -n $f && $f != */ ]] || continue
		if in_list "$f" "${backups[@]}" && [[ -e $R/$f ]]; then
			mv -f "$R/$f" "$R/$f.burnsave"
			warn "saved /$f as /$f.burnsave"
		else
			rm -f "$R/$f"
		fi
	done <"$DB_DIR/$name/files"
	sed -n '/\/$/p' "$DB_DIR/$name/files" | LC_ALL=C sort -r | while IFS= read -r f; do
		rmdir "$R/$f" 2>/dev/null || true
	done
	history_add remove "$name" "$(db_get "$name" version)-$(db_get "$name" release)" - ""
	if grep -q '^usr/lib/modules/.' "$DB_DIR/$name/files"; then
		rm -rf "${DB_DIR:?}/$name"
		modules_trigger
	else
		rm -rf "${DB_DIR:?}/$name"
	fi
}

# Order installed packages so that dependencies come first (uses installed metadata).
db_order_set() {
	local -A in_set=() seen=()
	local p
	DEP_ORDER=()
	for p; do in_set[$p]=1; done
	_db_visit() {
		local q=$1 d
		[[ -n ${seen[$q]:-} ]] && return 0
		seen[$q]=1
		for d in $(db_get "$q" depends); do
			if [[ -n ${in_set[$d]:-} ]]; then _db_visit "$d"; fi
		done
		DEP_ORDER+=("$q")
	}
	for p; do _db_visit "$p"; done
}