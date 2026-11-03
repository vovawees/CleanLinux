# shellcheck shell=bash
# Recipe discovery, loading and features ("USE flags").

RECIPE_VARS=(name version release summary homepage license category source sha256 build_type srcdir
	depends makedepends features patches patch_strip options backup noextract
	configure_args meson_args cmake_args make_args make_install_args cargo_args
	out_of_tree meson_subdir cmake_subdir cflags_append)
RECIPE_FUNCS=(do_prepare do_configure do_build do_check do_install post_install
	configure_extra meson_extra cmake_extra)

recipe_dirs() {
	local d
	for d in "${RECIPE_PATHS[@]}" "$REPO_DIR"/*/packages; do
		[[ -d $d ]] && printf '%s\n' "$d"
	done
	return 0
}

recipe_path() {
	local d
	if [[ $1 == */* ]]; then
		if [[ -f $1/recipe ]]; then readlink -f "$1/recipe"; return 0; fi
		if [[ -f $1 ]]; then readlink -f "$1"; return 0; fi
		return 1
	fi
	while IFS= read -r d; do
		if [[ -f $d/$1/recipe ]]; then
			printf '%s\n' "$d/$1/recipe"
			return 0
		fi
	done < <(recipe_dirs)
	return 1
}

recipe_names() {
	local d r
	while IFS= read -r d; do
		for r in "$d"/*/recipe; do
			r=${r%/recipe}
			printf '%s\n' "${r##*/}"
		done
	done < <(recipe_dirs) | awk '!seen[$0]++'
}

recipe_reset() {
	unset -v "${RECIPE_VARS[@]}"
	unset -f "${RECIPE_FUNCS[@]}"
	name='' version='' release=1 summary='' homepage='' category='' build_type=autotools srcdir=''
	patch_strip=1 out_of_tree=0 meson_subdir='' cmake_subdir='' cflags_append=''
	license=() source=() sha256=() depends=() makedepends=() features=() patches=() options=()
	backup=() noextract=() configure_args=() meson_args=() cmake_args=() make_args=()
	make_install_args=() cargo_args=()
}

recipe_load() {
	local path
	path=$(recipe_path "$1") || die "recipe not found: $1"
	recipe_reset
	RECIPE_FILE=$path RECIPE_DIR=${path%/*}
	# shellcheck source=/dev/null
	. "$path"
	[[ -n $name && -n $version ]] || die "$path: 'name' and 'version' are required"
}

# Load a recipe and prepare the full build environment.
recipe_env() {
	recipe_load "$1"
	features_resolve
	toolchain_env
	flags_for_recipe
	BUILDID=$(recipe_buildid)
}

# recipe_state NAME -> "version-release rid" (subshell; empty output if the recipe is broken)
recipe_state() {
	(
		recipe_load "$1"
		features_resolve
		printf '%s %s\n' "$version-$release" "$(recipe_rid)"
	) 2>/dev/null || true
}

# Identity of the recipe itself (files + features): changes => rebuild.
recipe_rid() {
	{
		cat "$RECIPE_FILE"
		find "$RECIPE_DIR" -type f ! -name recipe -print0 | LC_ALL=C sort -z | xargs -0r cat
		features_string
	} | sha256sum | cut -c1-16
}

# Identity of the exact build: recipe + toolchain + flags + the ABI (sonames) of the installed
# dependencies. It names the cached package, so a soname bump of a dependency never reuses
# a stale build.
recipe_buildid() {
	local d
	{
		recipe_rid
		printf '%s\n' "$CHOST" "$CFLAGS" "$CXXFLAGS" "$LDFLAGS" "$KEEP_DOCS$KEEP_INFO$KEEP_MAN$STRIP_BINARIES $LOCALES"
		for d in $(deps_active "${depends[@]}"); do
			if [[ -f $DB_DIR/$d/provides-so ]]; then printf '%s: %s\n' "$d" "$(paste -sd' ' "$DB_DIR/$d/provides-so")"; fi
		done
	} | sha256sum | cut -c1-12
}

package_features() {
	local f=${ROOT%/}/etc/broom/package.features pkg rest
	[[ -f $f ]] || return 0
	while read -r pkg rest; do
		[[ $pkg == "$1" ]] && printf '%s\n' "$rest"
	done < <(sed 's/#.*//' "$f")
	return 0
}

# features=(+on -off off) in the recipe; overrides: profile, broom.conf, package.features, --features
features_resolve() {
	declare -gA FEAT=()
	local f v tok
	for f in "${features[@]}"; do
		case $f in +*) FEAT[${f#+}]=1 ;; -*) FEAT[${f#-}]=0 ;; *) FEAT[$f]=0 ;; esac
	done
	# shellcheck disable=SC2046,SC2153
	for tok in $PROFILE_FEATURES $FEATURES $(package_features "$name") ${CLI_FEATURES:-}; do
		case $tok in -*) f=${tok#-} v=0 ;; +*) f=${tok#+} v=1 ;; *) f=$tok v=1 ;; esac
		if [[ -v FEAT[$f] ]]; then FEAT[$f]=$v; fi
	done
}

features_string() {
	local f
	for f in "${!FEAT[@]}"; do
		if [[ ${FEAT[$f]} == 1 ]]; then printf '+%s\n' "$f"; else printf -- '-%s\n' "$f"; fi
	done | LC_ALL=C sort -k1.2 | paste -sd' ' -
}

# Helpers for recipes
use() { [[ ${FEAT[$1]:-0} == 1 ]]; }
use_enable() { if use "$1"; then echo "--enable-${2:-$1}"; else echo "--disable-${2:-$1}"; fi; }
use_with() { if use "$1"; then echo "--with-${2:-$1}"; else echo "--without-${2:-$1}"; fi; }
meson_feature() { if use "$1"; then echo "-D${2:-$1}=enabled"; else echo "-D${2:-$1}=disabled"; fi; }
meson_use() { if use "$1"; then echo "-D${2:-$1}=true"; else echo "-D${2:-$1}=false"; fi; }
cmake_use() { if use "$1"; then echo "-D$2=ON"; else echo "-D$2=OFF"; fi; }
has_option() { in_list "$1" "${options[@]}"; }

# deps_active DEP...: "pkg" always, "pkg:feat" only with feat on, "pkg:!feat" only with feat off
deps_active() {
	local d f
	for d; do
		case $d in
			*:!*) f=${d#*:!} && if ! use "$f"; then printf '%s\n' "${d%%:*}"; fi ;;
			*:*) f=${d#*:} && if use "$f"; then printf '%s\n' "${d%%:*}"; fi ;;
			*) printf '%s\n' "$d" ;;
		esac
	done
	return 0
}