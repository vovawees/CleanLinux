# shellcheck shell=bash
# Build pipeline: fetch -> unpack -> patch -> prepare/configure/build/check/install -> finalize -> package.

pkg_cache_file() {
	printf '%s/packages/%s-%s-%s-%s-%s.pkg.tar.zst\n' "$CACHE_DIR" "$name" "$version" "$release" "$CARCH" "$BUILDID"
}

# phase LABEL CMD...: run CMD in a subshell with errexit, log output, fail loudly.
phase() {
	local label=$1 rc
	shift
	msg2 "$label"
	set +e
	if [[ ${VERBOSE:-0} == 1 ]]; then
		(
			set -e
			"$@"
		) 2>&1 | tee -a "$LOG" >&2
		rc=${PIPESTATUS[0]}
	else
		(
			set -e
			"$@"
		) >>"$LOG" 2>&1
		rc=$?
	fi
	set -e
	if ((rc != 0)); then
		tail -n 40 "$LOG" >&2
		die "$name: $label failed (exit $rc, full log: $LOG)"
	fi
}

run_phase() {
	if declare -F "do_$1" >/dev/null; then
		cd "$SRC"
		"do_$1"
	else
		"bt_$1"
	fi
}

run_in_src() {
	cd "$SRC"
	"$@"
}

# build_pkg NAME -> prints the package file (stdout); everything else goes to stderr/log.
build_pkg() {
	(
		recipe_env "$1"
		local out p
		out=$(pkg_cache_file)
		if [[ -f $out && $REBUILD == 0 ]]; then
			msg "$name $version-$release: using cached build ${BUILDID}"
			printf '%s\n' "$out"
			exit 0
		fi
		[[ -f $BURN_HOME/buildtypes/$build_type.sh ]] || die "$name: unknown build_type '$build_type'"
		# shellcheck source=/dev/null
		. "$BURN_HOME/buildtypes/$build_type.sh"
		local how=native
		((CROSS)) && how=cross
		msg "Building $name $version-$release ($CHOST, $how, $build_type)"
		[[ -n $WORK_DIR && -n $name ]] || die "internal: empty work dir"
		WORK=$WORK_DIR/$name BUILD=$WORK_DIR/$name/build DESTDIR=$WORK_DIR/$name/dest
		LOG=$CACHE_DIR/logs/$name-$version-$release.log
		rm -rf "$WORK"
		mkdir -p "$WORK" "$BUILD" "$DESTDIR" "${LOG%/*}"
		# reproducible packages: the same recipe, flags and toolchain give the same bytes.
		# Timestamps come from the recipe, build paths never end up in the binaries.
		SOURCE_DATE_EPOCH=$(recipe_epoch)
		META_CFLAGS=$CFLAGS
		CFLAGS+=" -ffile-prefix-map=$WORK=/usr/src/$name" CXXFLAGS+=" -ffile-prefix-map=$WORK=/usr/src/$name"
		export SOURCE_DATE_EPOCH CFLAGS CXXFLAGS
		{
			echo "# burn $BURN_VERSION: $name $version-$release, $(date -u)"
			echo "# CHOST=$CHOST CC=$CC SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
			echo "# CFLAGS=$CFLAGS"
			echo "# LDFLAGS=$LDFLAGS"
			echo "# features: $(features_string)"
		} >"$LOG"
		if [[ $build_type == meta ]]; then
			SRC=$WORK FILES=$WORK
		else
			fetch_sources
			msg2 "unpack"
			unpack_sources
			apply_patches
		fi
		export MAKEFLAGS="-j$JOBS"
		for p in prepare configure build check install; do
			[[ $p == check && $CHECK != 1 ]] && continue
			if declare -F "do_$p" >/dev/null || declare -F "bt_$p" >/dev/null; then
				phase "$p" run_phase "$p"
			fi
		done
		if declare -F post_install >/dev/null; then phase post_install run_in_src post_install; fi
		msg2 "finalize"
		pkg_finalize
		pkg_write_meta
		mkdir -p "${out%/*}"
		(cd "$DESTDIR" && LC_ALL=C tar --sort=name --numeric-owner --owner=0 --group=0 \
			--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cf - .) | $PKG_COMPRESS >"$out.part"
		mv -f "$out.part" "$out"
		msg2 "package ${out##*/} ($(du -h "$out" | cut -f1), $(grep -vc '/$' "$DESTDIR/.BURN/files") files)"
		[[ ${KEEP_WORK:-0} == 1 ]] || rm -rf "$WORK"
		printf '%s\n' "$out"
	)
}

# Keep the tree "clean": merged /usr, no libtool archives, no docs/locales nobody asked for, stripped ELF.
pkg_finalize() {
	local d=$DESTDIR a
	merge_usr "$d"
	find "$d" -name '*.la' -type f -delete
	if ! has_option staticlibs; then
		while IFS= read -r -d '' a; do
			if [[ -e ${a%.a}.so ]]; then rm -f "$a"; fi
		done < <(find "$d" -name '*.a' -type f -print0)
	fi
	if ! has_option '!prune'; then
		((KEEP_DOCS)) || rm -rf "$d/usr/share/doc" "$d/usr/share/gtk-doc"
		((KEEP_INFO)) || rm -rf "$d/usr/share/info"
		((KEEP_MAN)) || rm -rf "$d/usr/share/man"
		prune_langs "$d/usr/share/locale"
		prune_langs "$d/usr/share/man" keep-sections
	fi
	if ((STRIP_BINARIES)) && ! has_option '!strip'; then strip_tree "$d"; fi
	if ((LTO_ON)) && ! has_option staticlibs; then
		while IFS= read -r -d '' a; do
			if LC_ALL=C "$READELF" -S "$a" 2>/dev/null | grep '\.gnu\.lto_' >/dev/null; then
				warn "$name: ${a#"$d"} holds LTO-only objects; add options=(staticlibs) or options=(!lto)"
			fi
		done < <(find "$d" -name '*.a' -type f -print0)
	fi
	if ! has_option emptydirs; then find "$d" -mindepth 1 -type d -empty -delete; fi
	return 0
}

merge_usr() {
	local d=$1 pair from to
	for pair in bin:usr/bin sbin:usr/bin usr/sbin:usr/bin lib:usr/lib lib64:usr/lib usr/lib64:usr/lib; do
		from=$d/${pair%%:*} to=$d/${pair#*:}
		[[ -d $from && ! -L $from ]] || continue
		mkdir -p "$to"
		cp -a "$from"/. "$to"/
		rm -rf "$from"
	done
}

# prune_langs DIR [keep-sections]: keep only $LOCALES translations
prune_langs() {
	local dir=$1 e l k keep
	[[ -d $dir && -n $LOCALES && $LOCALES != all ]] || return 0
	for e in "$dir"/*/; do
		e=${e%/} l=${e##*/}
		[[ ${2:-} == keep-sections && $l == man* ]] && continue
		keep=0
		for k in $LOCALES; do
			case $l in "$k" | "$k"_* | "$k"@* | "$k".*) keep=1 ;; esac
		done
		((keep)) || rm -rf "$e"
	done
	return 0
}

strip_tree() {
	local f
	while IFS= read -r -d '' f; do
		case $f in *.ko | *.ko.* | *.o | */usr/lib/debug/*) continue ;; esac
		is_elf "$f" || continue
		case $f in
			*.so | *.so.*) "$STRIP" --strip-unneeded "$f" 2>/dev/null || true ;;
			*) "$STRIP" --strip-all "$f" 2>/dev/null || true ;;
		esac
	done < <(find "$1" -type f ! -name '*.a' -print0)
}

pkg_write_meta() {
	local m=$DESTDIR/.BURN
	mkdir -p "$m"
	{
		printf 'name=%s\nversion=%s\nrelease=%s\narch=%s\nchost=%s\n' "$name" "$version" "$release" "$CARCH" "$CHOST"
		printf 'buildid=%s\nrid=%s\nprofile=%s\n' "$BUILDID" "$(recipe_rid)" "$PROFILE"
		printf 'summary=%s\nlicense=%s\ndepends=%s\n' "$summary" "${license[*]}" "$(deps_active "${depends[@]}" | paste -sd' ' -)"
		printf 'features=%s\nbackup=%s\n' "$(features_string)" "${backup[*]}"
		printf 'cflags=%s\nldflags=%s\nbuilddate=%s\n' "${META_CFLAGS:-$CFLAGS}" "$LDFLAGS" \
			"$(date -u -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y-%m-%dT%H:%M:%SZ)"
	} >"$m/meta"
	(cd "$DESTDIR" && find . -mindepth 1 \( -path ./.BURN -prune \) -o \( -type d -printf '%P/\n' \) -o -printf '%P\n') |
		LC_ALL=C sort >"$m/files"
	elf_scan "$m"
}

# Record sonames provided/needed: the basis for ABI-aware rolling updates.
elf_scan() {
	local m=$1 f dyn
	: >"$m/provides-so"
	: >"$m/needs.tmp"
	while IFS= read -r -d '' f; do
		is_elf "$f" || continue
		dyn=$(LC_ALL=C "$READELF" -d "$f" 2>/dev/null) || continue
		sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p' <<<"$dyn" >>"$m/provides-so"
		sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' <<<"$dyn" >>"$m/needs.tmp"
	done < <(find "$DESTDIR" -path "$DESTDIR/.BURN" -prune -o -type f -print0)
	LC_ALL=C sort -u -o "$m/provides-so" "$m/provides-so"
	LC_ALL=C sort -u "$m/needs.tmp" | { grep -vxF -f "$m/provides-so" || true; } >"$m/needs-so"
	rm -f "$m/needs.tmp"
}