# shellcheck shell=bash
# Downloading, verifying, extracting and patching sources.

url_expand() {
	case $1 in
		gnu://*) printf '%s\n' "$GNU_MIRROR/${1#gnu://}" ;;
		kernel://*) printf '%s\n' "$KERNEL_MIRROR/${1#kernel://}" ;;
		*) printf '%s\n' "$1" ;;
	esac
}

# source_info SPEC -> SRC_NAME SRC_URL SRC_LOCAL   (SPEC: [name::]url | local-file)
source_info() {
	local s=$1
	SRC_LOCAL=0 SRC_NAME=''
	if [[ $s == *::* ]]; then
		SRC_NAME=${s%%::*}
		s=${s#*::}
	fi
	if [[ $s == *://* ]]; then
		SRC_URL=$(url_expand "$s")
		[[ -n $SRC_NAME ]] || SRC_NAME=${SRC_URL##*/}
	else
		SRC_URL=$s SRC_LOCAL=1
		[[ -n $SRC_NAME ]] || SRC_NAME=${s##*/}
	fi
}

source_path() {
	source_info "$1"
	if ((SRC_LOCAL)); then
		printf '%s\n' "$RECIPE_DIR/$SRC_URL"
	else
		printf '%s\n' "$CACHE_DIR/sources/$SRC_NAME"
	fi
}

download() {
	local tmp=$2.part
	if have curl; then
		curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -sS -o "$tmp" "$1" || return 1
	elif have wget; then
		wget -q -O "$tmp" "$1" || return 1
	else
		die "curl or wget is required to download sources"
	fi
	mv -f "$tmp" "$2"
}

# sum_ok FILE SUM: SUM is the sha256 of FILE (or SKIP)
sum_ok() { [[ $2 == SKIP || $(sha256sum "$1" | cut -d' ' -f1) == "$2" ]]; }

# fetch_one SPEC FILE SUM PKG: FILE (in the source cache) is downloaded and matches SUM
fetch_one() {
	local spec=$1 file=$2 sum=$3 pkg=$4
	source_info "$spec"
	if [[ ! -f $file ]]; then
		msg2 "download $SRC_NAME"
		if ! download "$SRC_URL" "$file"; then
			[[ $spec == *gnu://* ]] || die "$pkg: download failed: $SRC_URL"
			download "https://ftp.gnu.org/gnu/${spec#*gnu://}" "$file" || die "$pkg: download failed: $SRC_URL"
		fi
	fi
	[[ -n $sum ]] || die "$pkg: missing sha256 for $SRC_NAME"
	if ! sum_ok "$file" "$sum"; then
		mv -f "$file" "$file.bad"
		die "$pkg: sha256 mismatch for $SRC_NAME (moved aside as .bad)"
	fi
}

# fetch_sources [verify=1]
fetch_sources() {
	local verify=${1:-1} i spec file sum
	mkdir -p "$CACHE_DIR/sources"
	for i in "${!source[@]}"; do
		spec=${source[$i]}
		file=$(source_path "$spec")
		source_info "$spec"
		sum=${sha256[$i]:-}
		((verify)) || sum=SKIP
		if ((SRC_LOCAL)); then
			[[ -f $file ]] || die "$name: local source '$SRC_URL' is missing"
			[[ -n $sum ]] || die "$name: missing sha256 for $SRC_NAME"
			sum_ok "$file" "$sum" || die "$name: sha256 mismatch for $SRC_NAME"
		else
			fetch_one "$spec" "$file" "$sum" "$name"
		fi
	done
}

# remote_sources PKG...: "file<TAB>spec<TAB>sha256<TAB>pkg" for every remote source
remote_sources() {
	local p i
	for p; do
		(
			recipe_load "$p"
			features_resolve
			for i in "${!source[@]}"; do
				source_info "${source[$i]}"
				((SRC_LOCAL)) || printf '%s\t%s\t%s\t%s\n' "$CACHE_DIR/sources/$SRC_NAME" "${source[$i]}" "${sha256[$i]:-}" "$name"
			done
		)
	done
}

# prefetch PKG...: download (FETCH_JOBS at a time) and verify every source of PKG... before
# anything is built, so a long update never stops halfway on a dead link or a bad checksum.
prefetch() {
	local e file spec sum pkg running=0 failed=0
	local -a list=()
	local -A seen=()
	mapfile -t list < <(remote_sources "$@")
	mkdir -p "$CACHE_DIR/sources"
	for e in "${list[@]}"; do
		IFS=$'\t' read -r file spec sum pkg <<<"$e"
		[[ -z ${seen[$file]:-} ]] || continue
		seen[$file]=1
		if ((running >= FETCH_JOBS)); then
			wait -n || failed=$((failed + 1))
			running=$((running - 1))
		fi
		fetch_one "$spec" "$file" "$sum" "$pkg" &
		running=$((running + 1))
	done
	while ((running > 0)); do
		wait -n || failed=$((failed + 1))
		running=$((running - 1))
	done
	((failed == 0)) || die "$failed source(s) could not be fetched or verified: nothing was built"
	msg2 "sources: ${#seen[@]} downloaded and verified"
}

is_archive() {
	case $1 in *.tar | *.tar.gz | *.tgz | *.tar.xz | *.txz | *.tar.bz2 | *.tbz2 | *.tar.zst | *.tar.lz | *.zip) return 0 ;; esac
	return 1
}

# Extract archives into $WORK/src, copy other files into $WORK/files; sets SRC and FILES.
unpack_sources() {
	local spec file first='' before
	rm -rf "$WORK/src" "$WORK/files"
	mkdir -p "$WORK/src" "$WORK/files"
	FILES=$WORK/files
	for spec in "${source[@]}"; do
		file=$(source_path "$spec")
		source_info "$spec"
		if is_archive "$SRC_NAME" && ! in_list "$SRC_NAME" "${noextract[@]}"; then
			before=$(LC_ALL=C ls -A "$WORK/src")
			case $SRC_NAME in
				*.zip) unzip -q "$file" -d "$WORK/src" ;;
				*) tar -xf "$file" -C "$WORK/src" --no-same-owner ;;
			esac
			if [[ -z $first ]]; then
				first=$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(LC_ALL=C ls -A "$WORK/src") | head -n1)
			fi
		else
			cp -f "$file" "$FILES/$SRC_NAME"
		fi
	done
	if [[ -n $srcdir ]]; then
		SRC=$WORK/src/$srcdir
	elif [[ -n $first && -d $WORK/src/$first ]]; then
		SRC=$WORK/src/$first
	else
		SRC=$WORK/src
	fi
	[[ -d $SRC ]] || die "$name: source directory $SRC does not exist (check srcdir=)"
}

apply_patches() {
	local p f
	for p in "${patches[@]}"; do
		if [[ -f $RECIPE_DIR/$p ]]; then
			f=$RECIPE_DIR/$p
		elif [[ -f $RECIPE_DIR/patches/$p ]]; then
			f=$RECIPE_DIR/patches/$p
		elif [[ -f $FILES/$p ]]; then
			f=$FILES/$p
		else
			die "$name: patch '$p' not found"
		fi
		msg2 "patch $p"
		patch -d "$SRC" -Np"$patch_strip" -i "$f" >>"$LOG" 2>&1 || die "$name: patch $p failed (log: $LOG)"
	done
}