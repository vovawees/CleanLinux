# shellcheck shell=bash
# Command line interface: option parsing and the user-facing commands.

broom_usage() {
	cat <<USAGE
broom $BROOM_VERSION - the CleanLinux package manager (source based, rolling+++)

Usage: broom [options] <command> [arguments]

Commands:
  sync                        update the recipe repositories (git)
  search [regex]              find recipes
  info <pkg>                  show a recipe with its resolved features
  query <pkg> <var>           print one recipe variable (for scripts)
  fetch <pkg>...              download and verify sources
  unpack <pkg> [dir]          unpack + patch + prepare sources, print the source dir
  build <pkg>...              build into the package cache (no deps, no install)
  install <pkg|file>...       resolve dependencies, build and install
  remove <pkg>...             remove packages
  list                        list installed packages
  files <pkg>                 list the files of an installed package
  owner <path>                show which package owns a file
  plan                        show what 'update' would do (changes nothing)
  update                      sync, build every update, snapshot, apply, fix ABI breaks
  hold|unhold [pkg]...        pin packages (update skips them); no args: list holds
  history                     show the transaction log
  rollback <pkg>              reinstall the previous build of a package and hold it
  doctor                      check the system (missing and preserved libraries)
  lint [pkg|dir]...           check recipes
  checksum <pkg>              print the sha256 of the sources (--write: into the recipe)
  profile [show|list|detect]  hardware profiles

Options:
  -r, --root DIR              operate on another root (default: /)
  -p, --profile NAME          hardware profile (default: native)
  -R, --recipes DIR           extra recipe directory, searched first (repeatable)
  -c, --config FILE           extra configuration file
  -j, --jobs N                parallel build jobs
  -f, --features "a -b"       enable/disable features for this run
      --target TRIPLE         cross-compile, e.g. aarch64-cleanlinux-linux-gnu
      --host-deps             take build tools from the host (ignore makedepends)
      --check                 run test suites while building
      --nodeps                do not resolve dependencies
      --rebuild               ignore cached builds
      --force                 overwrite conflicting files, allow removing essentials
      --no-sync               'update' without syncing recipes first
      --write                 'checksum': write the sums into the recipe
  -y, --yes                   do not ask for confirmation
  -v, --verbose               show build output
  -h, --help                  show this help
  -V, --version               show the version
USAGE
}

broom_main() {
	config_defaults
	CLI_FEATURES='' VERBOSE=0 ASSUME_YES=0 FORCE=0 REBUILD=0 NODEPS=0 NO_SYNC=0 WRITE=0
	CONFIG_FILE=${BROOM_CONFIG:-}
	local a cmd o_root='' o_profile='' o_jobs='' o_target='' o_host_deps=0 o_check=0 loaded
	local -a o_recipes=() args=()
	while (($#)); do
		a=$1
		if [[ $a == --*=* ]]; then
			shift
			set -- "${a%%=*}" "${a#*=}" "$@"
			continue
		fi
		case $a in
			-r | --root | -p | --profile | -R | --recipes | -c | --config | -j | --jobs | -f | --features | --target)
				(($# >= 2)) || die "option $a needs a value"
				case $a in
					-r | --root) o_root=$2 ;;
					-p | --profile) o_profile=$2 ;;
					-R | --recipes)
						[[ -d $2 ]] || die "recipe directory not found: $2"
						o_recipes+=("$(readlink -f "$2")")
						;;
					-c | --config)
						[[ -f $2 ]] || die "config file not found: $2"
						CONFIG_FILE=$(readlink -f "$2")
						;;
					-j | --jobs)
						[[ $2 =~ ^[1-9][0-9]*$ ]] || die "--jobs needs a positive number"
						o_jobs=$2
						;;
					-f | --features) CLI_FEATURES+=" $2" ;;
					--target) o_target=$2 ;;
				esac
				shift 2
				;;
			--host-deps) o_host_deps=1 && shift ;;
			--check) o_check=1 && shift ;;
			--nodeps) NODEPS=1 && shift ;;
			--rebuild) REBUILD=1 && shift ;;
			--force) FORCE=1 && shift ;;
			--no-sync) NO_SYNC=1 && shift ;;
			--write) WRITE=1 && shift ;;
			-y | --yes) ASSUME_YES=1 && shift ;;
			-v | --verbose) VERBOSE=1 && shift ;;
			-h | --help)
				broom_usage
				return 0
				;;
			-V | --version)
				printf 'broom %s\n' "$BROOM_VERSION"
				return 0
				;;
			--)
				shift
				args+=("$@")
				break
				;;
			-?*) die "unknown option: $a (see: broom --help)" ;;
			*) args+=("$a") && shift ;;
		esac
	done
	if ((${#args[@]} == 0)); then
		broom_usage >&2
		exit 2
	fi
	cmd=${args[0]}
	args=("${args[@]:1}")

	# root -> config -> profile -> config again (user settings beat the profile) -> command line
	[[ -z $o_root ]] || ROOT=$o_root
	ROOT=$(readlink -m "$ROOT")
	local root=$ROOT
	R=${ROOT%/}
	config_load
	[[ -z $o_profile ]] || PROFILE=$o_profile
	if [[ -n $o_target && -z $o_profile && $PROFILE == native && ${o_target%%-*} != "$(uname -m)" ]]; then
		PROFILE=generic-${o_target%%-*}
	fi
	profile_load
	loaded=$PROFILE
	config_load
	ROOT=$root PROFILE=$loaded R=${ROOT%/}
	[[ -z $o_jobs ]] || JOBS=$o_jobs
	[[ -z $o_target ]] || CHOST=$o_target
	((o_host_deps == 0)) || HOST_DEPS=1
	((o_check == 0)) || CHECK=1
	if ((${#o_recipes[@]})); then RECIPE_PATHS=("${o_recipes[@]}" "${RECIPE_PATHS[@]}"); fi
	DB_DIR=$R/var/lib/broom/installed
	STATE_DIR=$R/var/lib/broom/state
	REPO_DIR=${BROOM_REPO_DIR:-$R/var/lib/broom/repos}
	HOLD_FILE=$R/etc/broom/hold
	flags_setup

	case $cmd in
		sync) need_write && cmd_sync ;;
		search) cmd_search "${args[@]}" ;;
		info) cmd_info "${args[@]}" ;;
		query) cmd_query "${args[@]}" ;;
		fetch) cmd_fetch "${args[@]}" ;;
		unpack) cmd_unpack "${args[@]}" ;;
		build) cmd_build "${args[@]}" ;;
		install) cmd_install "${args[@]}" ;;
		remove | uninstall) cmd_remove "${args[@]}" ;;
		list) cmd_list ;;
		files) cmd_files "${args[@]}" ;;
		owner) cmd_owner "${args[@]}" ;;
		plan) cmd_plan ;;
		update | upgrade) need_write && cmd_update ;;
		hold) cmd_hold "${args[@]}" ;;
		unhold) cmd_unhold "${args[@]}" ;;
		history) cmd_history ;;
		rollback) cmd_rollback "${args[@]}" ;;
		doctor) cmd_doctor ;;
		lint) cmd_lint "${args[@]}" ;;
		checksum) cmd_checksum "${args[@]}" ;;
		profile) cmd_profile "${args[@]}" ;;
		help) broom_usage ;;
		*) die "unknown command: $cmd (see: broom --help)" ;;
	esac
}

# Commands that change ROOT: root privileges for / and one broom at a time.
need_write() {
	[[ -z ${BROOM_LOCK_FD:-} ]] || return 0
	if [[ -z $R && $(id -u) != 0 ]]; then die "this command changes the system: run it as root"; fi
	mkdir -p "$R/var/lib/broom"
	if have flock; then
		exec {BROOM_LOCK_FD}>"$R/var/lib/broom/lock"
		flock -n "$BROOM_LOCK_FD" || die "another broom process is working on $ROOT"
	fi
	return 0
}

cmd_search() {
	local re=${1:-.} n line mark
	re=${re,,}
	while IFS= read -r n; do
		line=$(
			recipe_load "$n" 2>/dev/null
			printf '%s %s-%s|%s' "$name" "$version" "$release" "$summary"
		) || continue
		[[ ${line,,} =~ $re ]] || continue
		mark=''
		if db_has "$n"; then mark=' [installed]'; fi
		printf '%-34s %s\n' "${line%%|*}$mark" "${line#*|}"
	done < <(recipe_names | LC_ALL=C sort)
}

cmd_info() {
	(($# == 1)) || die "usage: broom info <pkg>"
	recipe_load "$1"
	features_resolve
	local inst=no s
	if db_has "$name"; then inst="$(db_get "$name" version)-$(db_get "$name" release) [$(db_get "$name" features)]"; fi
	if is_held "$name"; then inst+=' (held)'; fi
	printf '%-12s %s\n' name "$name" version "$version-$release" summary "$summary" homepage "$homepage" \
		license "${license[*]}" category "${category:--}" build_type "$build_type" \
		depends "${depends[*]:--}" makedepends "${makedepends[*]:--}" features "$(features_string)" \
		options "${options[*]:--}" installed "$inst" recipe "$RECIPE_FILE"
	for s in "${source[@]}"; do
		source_info "$s"
		printf '%-12s %s\n' source "$SRC_URL"
	done
}

cmd_query() {
	(($# == 2)) || die "usage: broom query <pkg> <variable>"
	recipe_load "$1"
	features_resolve
	local s
	case $2 in
		rid) recipe_rid ;;
		features) features_string ;;
		dir) printf '%s\n' "$RECIPE_DIR" ;;
		urls)
			for s in "${source[@]}"; do
				source_info "$s"
				printf '%s\n' "$SRC_URL"
			done
			;;
		*)
			in_list "$2" "${RECIPE_VARS[@]}" || die "unknown recipe variable: $2"
			if [[ $(declare -p "$2" 2>/dev/null) == "declare -a"* ]]; then
				local -n _qv=$2
				if ((${#_qv[@]})); then printf '%s\n' "${_qv[@]}"; fi
			else
				printf '%s\n' "${!2:-}"
			fi
			;;
	esac
}

cmd_fetch() {
	(($#)) || die "usage: broom fetch <pkg>..."
	local p
	for p; do
		(
			recipe_load "$p"
			features_resolve
			msg "Fetching $name $version"
			fetch_sources
		)
	done
}

# unpack PKG [DIR]: sources ready for hacking (or for bootstrap/), prints the source directory
cmd_unpack() {
	(($# == 1 || $# == 2)) || die "usage: broom unpack <pkg> [dir]"
	local pkg=$1 dest=${2:-}
	(
		recipe_load "$pkg"
		features_resolve
		WORK=${dest:-$WORK_DIR/$name}
		WORK=$(readlink -m "$WORK")
		# same layout as a real build, so do_prepare may use $BUILD and $DESTDIR
		BUILD=$WORK/build DESTDIR=$WORK/dest LOG=$WORK/unpack.log
		mkdir -p "$WORK" "$BUILD"
		: >"$LOG"
		msg "Unpacking $name $version into $WORK"
		fetch_sources
		unpack_sources
		apply_patches
		if declare -F do_prepare >/dev/null; then phase prepare run_in_src do_prepare; fi
		printf '%s\n' "$SRC"
	)
}

cmd_build() {
	(($#)) || die "usage: broom build <pkg>..."
	local p f
	for p; do
		f=$(build_pkg "$p")
		printf '%s\n' "$f"
	done
}

# installed with the same version, recipe and features?
pkg_uptodate() {
	local st
	db_has "$1" || return 1
	st=$(recipe_state "$1")
	[[ -n $st && $st == "$(db_get "$1" version)-$(db_get "$1" release) $(db_get "$1" rid)" ]]
}

cmd_install() {
	(($#)) || die "usage: broom install <pkg|file.pkg.tar.zst>..."
	need_write
	local a f n
	local -a files=() names=() todo=()
	for a; do
		if [[ $a == *.pkg.tar.zst ]]; then
			[[ -f $a ]] || die "no such package file: $a"
			files+=("$(readlink -f "$a")")
		else
			names+=("$a")
		fi
	done
	mkdir -p "$WORK_DIR"
	: >"$WORK_DIR/.lost-sonames"
	for f in "${files[@]}"; do pkg_install_file "$f"; done
	if ((${#names[@]})); then
		if ((NODEPS)); then DEP_ORDER=("${names[@]}"); else deps_resolve "${names[@]}"; fi
		for n in "${DEP_ORDER[@]}"; do
			if ((FORCE == 0 && REBUILD == 0)) && pkg_uptodate "$n"; then
				msg2 "$n is up to date"
				continue
			fi
			todo+=("$n")
		done
		if ((${#todo[@]})); then
			msg "Packages (${#todo[@]}): ${todo[*]}"
			confirm "Build and install them?" || die "aborted, nothing changed"
			for n in "${todo[@]}"; do
				f=$(build_pkg "$n")
				pkg_install_file "$f"
			done
		fi
	fi
	abi_followup
}

cmd_remove() {
	(($#)) || die "usage: broom remove <pkg>..."
	need_write
	local p i
	for p; do db_has "$p" || die "$p is not installed"; done
	confirm "Remove $*?" || die "aborted, nothing changed"
	db_order_set "$@"
	for ((i = ${#DEP_ORDER[@]} - 1; i >= 0; i--)); do pkg_remove "${DEP_ORDER[$i]}"; done
}

cmd_list() {
	local p held
	for p in $(db_list); do
		held=''
		if is_held "$p"; then held=' [held]'; fi
		if ((VERBOSE)); then
			printf '%-24s %-18s %-16s %s%s\n' "$p" "$(db_get "$p" version)-$(db_get "$p" release)" \
				"$(db_get "$p" profile)" "$(db_get "$p" features)" "$held"
		else
			printf '%-24s %s%s\n' "$p" "$(db_get "$p" version)-$(db_get "$p" release)" "$held"
		fi
	done
}

cmd_files() {
	(($# == 1)) || die "usage: broom files <pkg>"
	db_has "$1" || die "$1 is not installed"
	sed -n '/\/$/!s|^|/|p' "$DB_DIR/$1/files"
}

cmd_owner() {
	(($# == 1)) || die "usage: broom owner <path>"
	local p=$1 q d found=0
	[[ $p == /* ]] || p=$PWD/$p
	p=$(readlink -m "$p")
	if [[ -n $R && $p == "$R"/* ]]; then p=${p#"$R"}; fi
	p=${p#/}
	q=$(sed -E 's#^(bin|sbin|usr/sbin)/#usr/bin/#; s#^(lib|lib64|usr/lib64)/#usr/lib/#' <<<"$p")
	for d in $(db_list); do
		if grep -qxF -e "$p" -e "$q" "$DB_DIR/$d/files"; then
			printf '/%s is owned by %s %s-%s\n' "$q" "$d" "$(db_get "$d" version)" "$(db_get "$d" release)"
			found=1
		fi
	done
	((found)) || die "no package owns /$p"
}

cmd_hold() {
	if (($# == 0)); then
		if [[ -f $HOLD_FILE ]]; then cat "$HOLD_FILE"; fi
		return 0
	fi
	need_write
	mkdir -p "${HOLD_FILE%/*}"
	touch "$HOLD_FILE"
	local p
	for p; do
		grep -qxF -- "$p" "$HOLD_FILE" || printf '%s\n' "$p" >>"$HOLD_FILE"
		msg2 "held $p (update will skip it)"
	done
}

cmd_unhold() {
	(($#)) || die "usage: broom unhold <pkg>..."
	need_write
	[[ -f $HOLD_FILE ]] || return 0
	local p
	for p; do
		{ grep -vxF -- "$p" "$HOLD_FILE" || true; } >"$HOLD_FILE.new"
		mv -f "$HOLD_FILE.new" "$HOLD_FILE"
		msg2 "released $p"
	done
}

cmd_history() {
	[[ -f $STATE_DIR/history ]] || {
		msg "no transactions yet"
		return 0
	}
	awk -F'|' '{ printf "%s  %-9s %-22s %s -> %s\n", $1, $2, $3, $4, $5 }' "$STATE_DIR/history"
}

cmd_rollback() {
	(($# == 1)) || die "usage: broom rollback <pkg>"
	need_write
	local line f
	db_has "$1" || die "$1 is not installed"
	[[ -f $STATE_DIR/history ]] || die "no history yet"
	line=$(awk -F'|' -v p="$1" '$3 == p && $2 == "upgrade" { l = $0 } END { print l }' "$STATE_DIR/history")
	[[ -n $line ]] || die "no previous build of $1 in the history"
	f=${line##*|}
	[[ -f $f ]] || die "the previous build is not in the package cache any more: $f"
	mkdir -p "$WORK_DIR"
	: >"$WORK_DIR/.lost-sonames"
	TXN_OP=rollback
	pkg_install_file "$f"
	TXN_OP=''
	cmd_hold "$1"
	abi_followup
	msg "$1 rolled back and held; 'broom unhold $1' lets updates touch it again"
}

# lint_one RECIPE: prints one line per problem
lint_one() (
	local path p f i s
	local -a e=()
	path=$(recipe_path "$1") || {
		printf '%s: recipe not found\n' "$1"
		exit 0
	}
	if ! bash -n "$path" 2>/dev/null; then
		printf '%s: syntax error\n' "$path"
		exit 0
	fi
	recipe_load "$path"
	[[ $name == "${RECIPE_DIR##*/}" ]] || e+=("name does not match the directory '${RECIPE_DIR##*/}'")
	[[ $name =~ ^[a-z0-9][a-z0-9+._-]*$ ]] || e+=("bad name")
	[[ $version =~ ^[A-Za-z0-9._+~]+$ ]] || e+=("bad version '$version' (letters, digits and ._+~ only)")
	[[ $release =~ ^[1-9][0-9]*$ ]] || e+=("release must be a positive integer")
	[[ -n $summary ]] || e+=("summary is empty")
	((${#license[@]})) || e+=("license is empty")
	[[ $homepage == https://* || $homepage == http://* ]] || e+=("homepage must be a URL")
	[[ -f $BROOM_HOME/buildtypes/$build_type.sh ]] || e+=("unknown build_type '$build_type'")
	if [[ $build_type != meta ]]; then
		((${#source[@]})) || e+=("no sources")
	fi
	((${#source[@]} == ${#sha256[@]})) || e+=("${#source[@]} sources but ${#sha256[@]} sha256 sums")
	for i in "${!source[@]}"; do
		source_info "${source[$i]}"
		s=${sha256[$i]:-}
		if ((SRC_LOCAL)); then
			[[ -f $RECIPE_DIR/$SRC_URL ]] || e+=("local source '$SRC_URL' is missing")
		else
			case ${source[$i]#*::} in
				https://* | gnu://* | kernel://*) ;;
				*) e+=("source must use https:// (or gnu:// kernel://): ${source[$i]}") ;;
			esac
			[[ $s != SKIP ]] || e+=("remote source $SRC_NAME needs a real sha256")
		fi
		[[ $s =~ ^[0-9a-f]{64}$ || $s == SKIP ]] || e+=("bad sha256 for $SRC_NAME")
	done
	local -a srcnames=()
	for s in "${source[@]}"; do
		source_info "$s"
		srcnames+=("$SRC_NAME")
	done
	for p in "${patches[@]}"; do
		[[ -f $RECIPE_DIR/$p || -f $RECIPE_DIR/patches/$p ]] || in_list "$p" "${srcnames[@]}" || e+=("patch '$p' is missing")
	done
	local -a known=()
	for f in "${features[@]}"; do known+=("${f#[+-]}"); done
	for p in "${depends[@]}" "${makedepends[@]}"; do
		recipe_path "${p%%:*}" >/dev/null || e+=("unknown dependency '${p%%:*}'")
		if [[ $p == *:* ]]; then
			f=${p#*:}
			in_list "${f#!}" "${known[@]}" || e+=("dependency '$p' uses undeclared feature '${f#!}'")
		fi
	done
	for f in "${features[@]}"; do
		[[ $f =~ ^[+-]?[a-z0-9][a-z0-9_-]*$ ]] || e+=("bad feature '$f'")
	done
	for f in "${options[@]}"; do
		in_list "$f" '!lto' '!strip' '!hardening' '!prune' staticlibs emptydirs || e+=("unknown option '$f'")
	done
	# the recipe repository holds instructions only: no binaries, no vendored tarballs
	while IFS= read -r -d '' f; do
		if (($(stat -c %s "$f") > 262144)); then
			e+=("file too large for a recipe: ${f#"$RECIPE_DIR"/}")
		elif [[ -s $f ]] && ! grep -Iq . "$f"; then
			e+=("binary file not allowed: ${f#"$RECIPE_DIR"/}")
		fi
	done < <(find "$RECIPE_DIR" -type f -print0)
	for f in "${e[@]}"; do printf '%s: %s\n' "$name" "$f"; done
)

cmd_lint() {
	local -a targets=()
	local t out total=0
	if (($#)); then targets=("$@"); else mapfile -t targets < <(recipe_names | LC_ALL=C sort); fi
	((${#targets[@]})) || die "no recipes to check (use -R DIR)"
	for t in "${targets[@]}"; do
		out=$(lint_one "$t") || out="$t: recipe failed to load"
		if [[ -n $out ]]; then
			printf '%s\n' "$out"
			total=$((total + $(wc -l <<<"$out")))
		fi
	done
	((total == 0)) || die "lint: $total problem(s) in ${#targets[@]} recipe(s)"
	msg "lint: ${#targets[@]} recipe(s) OK"
}

cmd_checksum() {
	(($# == 1)) || die "usage: broom checksum [--write] <pkg>"
	recipe_load "$1"
	features_resolve
	fetch_sources 0
	local s block='sha256=('
	local -a sums=()
	for s in "${source[@]}"; do sums+=("$(sha256sum "$(source_path "$s")" | cut -d' ' -f1)"); done
	if ((${#sums[@]} == 1)); then
		block+="${sums[0]})"
	else
		block+=$'\n'
		for s in "${sums[@]}"; do block+=$'\t'"$s"$'\n'; done
		block+=')'
	fi
	if ((WRITE == 0)); then
		printf '%s\n' "$block"
		return 0
	fi
	grep -q '^sha256=(' "$RECIPE_FILE" || die "$RECIPE_FILE has no 'sha256=(' line to replace"
	BLOCK=$block awk '
		/^sha256=\(/ { print ENVIRON["BLOCK"]; skip = ($0 !~ /\)/); next }
		skip { if ($0 ~ /\)/) skip = 0; next }
		{ print }' "$RECIPE_FILE" >"$RECIPE_FILE.new"
	mv -f "$RECIPE_FILE.new" "$RECIPE_FILE"
	msg "sha256 updated in $RECIPE_FILE"
}

cmd_profile() {
	case ${1:-show} in
		show) profile_show ;;
		list) profile_list ;;
		detect) profile_detect ;;
		*) die "usage: broom profile [show|list|detect]" ;;
	esac
}

profile_show() {
	printf '%-12s %s\n' profile "$PROFILE" file "$PROFILE_FILE" description "${PROFILE_DESC:--}" \
		chost "$CHOST" cross "$CROSS" cpu "$CPU_CFLAGS" video_cards "${VIDEO_CARDS:--}" \
		features "$(printf '%s' "$PROFILE_FEATURES $FEATURES" | xargs)" \
		cflags "$OPT_FLAGS $CPU_CFLAGS $HARDENING_FLAGS${EXTRA_CFLAGS:+ $EXTRA_CFLAGS}" \
		ldflags "$LDFLAGS_BASE${EXTRA_LDFLAGS:+ $EXTRA_LDFLAGS}" lto "$LTO"
}

profile_list() {
	local d f n info
	while IFS= read -r d; do
		for f in "$d"/*.profile "$d"/devices/*.profile; do
			n=${f##*/}
			n=${n%.profile}
			info=$(
				PROFILE=$n
				profile_load
				printf '%s|%s' "$CARCH" "$PROFILE_DESC"
			) || continue
			printf '%-18s %-8s %s\n' "$n" "${info%%|*}" "${info#*|}"
		done
	done < <(profile_dirs)
}

profile_detect() {
	local arch cpu=unknown gpu='' model='' suggestion=native
	arch=$(uname -m)
	if have gcc; then
		if [[ $arch == aarch64 ]]; then
			cpu=$(gcc -mcpu=native -### -E - </dev/null 2>&1 | grep cc1 | grep -o -- "-mcpu=[^ \"']*" | head -n1 || true)
		else
			cpu=$(gcc -march=native -### -E - </dev/null 2>&1 | grep cc1 | grep -o -- "-march=[^ \"']*" | head -n1 || true)
		fi
	fi
	gpu=$(detect_video_cards)
	model=$({ cat /sys/firmware/devicetree/base/model || cat /sys/class/dmi/id/product_name; } 2>/dev/null | tr -d '\0' || true)
	case $model in
		*Jupiter* | *Galileo*) suggestion=steam-deck ;;
		*"ROG Ally"* | *RC71L* | *RC72L*) suggestion=rog-ally ;;
		*X540YA*) suggestion=asus-x540ya ;;
		*"Raspberry Pi 5"*) suggestion=raspberry-pi-5 ;;
		*[Mm]angmi*) suggestion=mangmi-air-x ;;
		*RG353* | *RG503* | *RK3566* | *rk3566*) suggestion=rk3566-handheld ;;
	esac
	printf '%-10s %s\n' arch "$arch" model "${model:-unknown}" cpu "${cpu:-unknown}" gpu "${gpu:-unknown}" profile "$suggestion"
	if [[ $suggestion == native ]]; then
		printf '\nNo device profile matched. A starting point for /etc/broom/profiles/my-device.profile:\n\n'
		printf 'PROFILE_DESC="My device"\nCARCH=%s\nCPU_FLAGS="%s"\nVIDEO_CARDS="%s"\n' "$arch" "${cpu:-native}" "$gpu"
	fi
}
