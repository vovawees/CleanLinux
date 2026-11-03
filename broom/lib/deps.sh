# shellcheck shell=bash
# Dependency resolution (depth-first, dependencies before dependents).

declare -A DEP_STATE=()
DEP_ORDER=()

recipe_deps() {
	(
		recipe_load "$1"
		features_resolve
		deps_active "${depends[@]}"
		# build tools come from the host when cross-compiling or bootstrapping
		if ((CROSS == 0 && HOST_DEPS == 0)); then deps_active "${makedepends[@]}"; fi
	) | sed '/^$/d'
}

dep_satisfied() { db_has "$1" || in_list "$1" "${ASSUME_INSTALLED[@]}"; }

deps_visit() {
	local p=$1 d deps
	case ${DEP_STATE[$p]:-} in
		done) return 0 ;;
		active) die "dependency cycle involving '$p'" ;;
	esac
	DEP_STATE[$p]=active
	recipe_path "$p" >/dev/null || die "no recipe provides '$p'"
	deps=$(recipe_deps "$p")
	for d in $deps; do
		dep_satisfied "$d" && continue
		deps_visit "$d"
	done
	DEP_STATE[$p]='done'
	DEP_ORDER+=("$p")
}

deps_resolve() {
	DEP_STATE=() DEP_ORDER=()
	local p
	for p; do deps_visit "$p"; done
}

# Order an arbitrary set of (installed) packages so that dependencies inside the set come first.
deps_order_set() {
	local -A in_set=()
	local p
	for p; do in_set[$p]=1; done
	DEP_STATE=() DEP_ORDER=()
	_set_visit() {
		local q=$1 d
		[[ -n ${DEP_STATE[$q]:-} ]] && return 0
		DEP_STATE[$q]=active
		for d in $(recipe_deps "$q"); do
			if [[ -n ${in_set[$d]:-} ]]; then _set_visit "$d"; fi
		done
		DEP_STATE[$q]='done'
		DEP_ORDER+=("$q")
	}
	for p; do _set_visit "$p"; done
}