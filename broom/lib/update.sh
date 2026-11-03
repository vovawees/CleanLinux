# shellcheck shell=bash
# Rolling+++: sync, plan, update (build everything first, then apply), ABI follow-up, doctor.

cmd_sync() {
	have git || die "git is required for sync"
	mkdir -p "$REPO_DIR"
	local url dir
	for url in "${RECIPE_REPOS[@]}"; do
		dir=$REPO_DIR/$(basename "$url" .git)
		if [[ -d $dir/.git ]]; then
			msg "Syncing ${dir##*/} ($CHANNEL)"
			git -C "$dir" fetch -q origin "$CHANNEL"
			git -C "$dir" checkout -q "$CHANNEL"
			git -C "$dir" merge -q --ff-only "origin/$CHANNEL"
		else
			msg "Cloning $url ($CHANNEL)"
			git clone -q --filter=blob:none --branch "$CHANNEL" "$url" "$dir"
		fi
		msg2 "$(git -C "$dir" log -1 --format='%h %cs %s')"
	done
}

# PLAN entries: name|installed|available|reason|risk   (available "-" = will not be touched)
plan_compute() {
	PLAN=()
	local n old new line rid reason risk
	for n in $(db_list); do
		old=$(db_get "$n" version)-$(db_get "$n" release)
		if ! recipe_path "$n" >/dev/null; then
			PLAN+=("$n|$old|-|no recipe any more (kept, orphan)|")
			continue
		fi
		line=$(recipe_state "$n")
		if [[ -z $line ]]; then
			PLAN+=("$n|$old|-|recipe failed to load (skipped)|")
			continue
		fi
		new=${line% *} rid=${line#* }
		if [[ $new != "$old" ]]; then
			reason=upgrade
			[[ $(vercmp "${old%-*}" "${new%-*}") == 1 ]] && reason=downgrade
		elif [[ $rid != "$(db_get "$n" rid)" ]]; then
			reason='rebuild: recipe or features changed'
		else
			continue
		fi
		if is_held "$n"; then
			PLAN+=("$n|$old|-|held, recipe has $new ($reason)|")
			continue
		fi
		risk=''
		[[ $reason == upgrade && ${old%%.*} != "${new%%.*}" ]] && risk+='major '
		in_list "$n" "${CORE_PKGS[@]}" && risk+='core '
		PLAN+=("$n|$old|$new|$reason|${risk% }")
	done
}

plan_print() {
	if ((${#PLAN[@]} == 0)); then
		msg "Nothing to do: installed packages match the recipes"
		return 0
	fi
	msg "Update plan (${#PLAN[@]}):"
	local e n o v r k
	for e in "${PLAN[@]}"; do
		IFS='|' read -r n o v r k <<<"$e"
		printf '  %-22s %-14s -> %-14s %s%s\n' "$n" "$o" "$v" "$r" "${k:+  [$k]}" >&2
	done
	plan_changelog
}

plan_changelog() {
	local dir last e
	local -a paths=()
	for e in "${PLAN[@]}"; do paths+=("packages/${e%%|*}"); done
	for dir in "$REPO_DIR"/*/; do
		dir=${dir%/}
		[[ -d $dir/.git && -f $STATE_DIR/${dir##*/}.commit ]] || continue
		last=$(<"$STATE_DIR/${dir##*/}.commit")
		msg2 "recipe changes in ${dir##*/} since the last update:"
		{ git -C "$dir" log --oneline --no-decorate "$last..HEAD" -- "${paths[@]}" 2>/dev/null || true; } | head -n 30 | sed 's/^/      /' >&2
	done
	return 0
}

cmd_plan() {
	plan_compute
	plan_print
}

cmd_update() {
	((NO_SYNC)) || cmd_sync
	plan_compute
	plan_print
	local e n v f
	local -a todo=() files=()
	for e in "${PLAN[@]}"; do
		IFS='|' read -r n _ v _ _ <<<"$e"
		[[ $v == - ]] || todo+=("$n")
	done
	((${#todo[@]})) || return 0
	confirm "Build ${#todo[@]} package(s) and apply them?" || die "aborted, nothing changed"
	deps_order_set "${todo[@]}"
	# 1) build everything: the running system is untouched until every build succeeded
	for n in "${DEP_ORDER[@]}"; do
		f=$(build_pkg "$n")
		files+=("$f")
	done
	# 2) rollback point (e.g. btrfs snapshot hook)
	run_hooks pre-update
	# 3) apply
	: >"$WORK_DIR/.lost-sonames"
	for f in "${files[@]}"; do pkg_install_file "$f"; done
	# 4) rebuild what linked against sonames that disappeared
	abi_followup
	run_hooks post-update
	state_record
	cmd_doctor || true
}

abi_followup() {
	local so p f
	local -a lost=() rebuild=()
	[[ -s $WORK_DIR/.lost-sonames ]] || return 0
	mapfile -t lost < <(LC_ALL=C sort -u "$WORK_DIR/.lost-sonames")
	for p in $(db_list); do
		for so in "${lost[@]}"; do
			if grep -qxF -- "$so" "$DB_DIR/$p/needs-so"; then
				rebuild+=("$p")
				break
			fi
		done
	done
	: >"$WORK_DIR/.lost-sonames"
	((${#rebuild[@]})) || return 0
	msg "ABI change (${lost[*]}): rebuilding ${rebuild[*]}"
	deps_order_set "${rebuild[@]}"
	local saved=$REBUILD
	REBUILD=1 TXN_OP=rebuild
	for p in "${DEP_ORDER[@]}"; do
		f=$(build_pkg "$p")
		pkg_install_file "$f"
	done
	REBUILD=$saved TXN_OP=''
	preserved_cleanup
}

# Delete preserved libraries that nothing needs any more.
preserved_cleanup() {
	local p f needed
	needed=$(cat "$DB_DIR"/*/needs-so 2>/dev/null | LC_ALL=C sort -u)
	for p in $(db_list); do
		[[ -s $DB_DIR/$p/preserved ]] || continue
		while IFS= read -r f; do
			if grep -qxF -- "${f##*/}" <<<"$needed"; then
				printf '%s\n' "$f"
			else
				rm -f "$R/$f"
				msg2 "removed preserved /$f"
			fi
		done <"$DB_DIR/$p/preserved" >"$DB_DIR/$p/preserved.new"
		mv -f "$DB_DIR/$p/preserved.new" "$DB_DIR/$p/preserved"
	done
	return 0
}

run_hooks() {
	local h
	for h in "$R/etc/broom/hooks/$1.d"/*; do
		[[ -x $h ]] || continue
		msg2 "hook $1: ${h##*/}"
		if ! ROOT=$ROOT "$h"; then
			[[ $1 == pre-* ]] && die "hook $h failed; nothing was changed"
			warn "hook $h failed"
		fi
	done
	return 0
}

state_record() {
	local dir
	mkdir -p "$STATE_DIR"
	for dir in "$REPO_DIR"/*/; do
		dir=${dir%/}
		if [[ -d $dir/.git ]]; then git -C "$dir" rev-parse HEAD >"$STATE_DIR/${dir##*/}.commit"; fi
	done
	date -u +%Y-%m-%dT%H:%M:%SZ >"$STATE_DIR/last-update"
}

lib_exists() {
	local d
	for d in "$R/usr/lib" "$R/usr/lib/$CARCH-linux-gnu"; do [[ -e $d/$1 ]] && return 0; done
	if ((HOST_DEPS)); then
		for d in /usr/lib /usr/lib64 /lib /lib64 "/usr/lib/$(uname -m)-linux-gnu" "/lib/$(uname -m)-linux-gnu"; do
			[[ -e $d/$1 ]] && return 0
		done
	fi
	return 1
}

cmd_doctor() {
	local p so prov problems=0
	prov=$(cat "$DB_DIR"/*/provides-so 2>/dev/null | LC_ALL=C sort -u)
	for p in $(db_list); do
		[[ -s $DB_DIR/$p/needs-so ]] || continue
		while IFS= read -r so; do
			grep -qxF -- "$so" <<<"$prov" && continue
			lib_exists "$so" && continue
			warn "$p needs $so, but no installed package provides it"
			problems=$((problems + 1))
		done <"$DB_DIR/$p/needs-so"
	done
	for p in $(db_list); do
		[[ -s $DB_DIR/$p/preserved ]] || continue
		warn "$p: preserved old libraries: $(paste -sd' ' "$DB_DIR/$p/preserved")"
		problems=$((problems + 1))
	done
	if ((problems)); then
		warn "doctor: $problems problem(s)"
		return 1
	fi
	msg "doctor: no problems found ($(db_list | wc -l) packages)"
}