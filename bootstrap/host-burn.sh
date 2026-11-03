#!/usr/bin/env bash
# bootstrap/host-burn.sh RECIPES DIR: prints the path of a burn for this host, built once in
# DIR/burn-<version> from the release the burn recipe pins: the same tarball and sha256 as the
# burn package of the image. Needs a C compiler, make and the libzstd headers. The tarball is
# kept in $BURN_CACHE/sources, where burn itself looks for it.
set -euo pipefail
recipes=$1 dir=$2
[[ -f $recipes/burn/recipe ]] || {
	echo "host-burn: no burn recipe in $recipes" >&2
	exit 1
}
read -r version url sum < <(
	# shellcheck disable=SC1091,SC2154
	. "$recipes/burn/recipe" && printf '%s %s %s\n' "$version" "${source[0]}" "${sha256[0]}"
)
out=$dir/burn-$version
if [[ ! -x $out/burn ]]; then
	cache=${BURN_CACHE:-$dir}/sources
	file=$cache/${url##*/}
	mkdir -p "$cache"
	if [[ ! -f $file ]]; then
		if command -v curl >/dev/null; then
			curl -fsSL --retry 3 -o "$file.part" "$url"
		else
			wget -q -O "$file.part" "$url"
		fi
		mv "$file.part" "$file"
	fi
	if ! echo "$sum  $file" | sha256sum -c --quiet - >/dev/null 2>&1; then
		rm -f "$file"
		echo "host-burn: wrong sha256 of $url" >&2
		exit 1
	fi
	if ! printf '#include <zstd.h>\n' | "${HOST_CC:-cc}" -E - >/dev/null 2>&1; then
		echo "host-burn: burn needs a C compiler and the libzstd headers (libzstd-dev, libzstd-devel)" >&2
		exit 1
	fi
	rm -rf "$out.tmp" && mkdir -p "$out.tmp"
	tar -xzf "$file" -C "$out.tmp" --strip-components=1
	make -s -C "$out.tmp" CC="${HOST_CC:-cc}" CFLAGS="-O2 -pipe" >&2
	rm -rf "$out" && mv "$out.tmp" "$out"
fi
printf '%s\n' "$out/burn"
