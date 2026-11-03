# shellcheck shell=bash
# Shared helpers for the test scripts.
set -euo pipefail
TESTS=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
BROOM=$TESTS/../broom/broom
T=$(mktemp -d "${TMPDIR:-/tmp}/broom-test.XXXXXX")
ROOTFS=$T/root
export BROOM_CACHE=${BROOM_CACHE:-$T/cache}
export NO_COLOR=1
cleanup() {
	local rc=$?
	if ((rc)) && [[ ${KEEP:-0} != 1 ]]; then echo "FAILED (exit $rc); rerun with KEEP=1 to keep $T" >&2; fi
	if [[ ${KEEP:-0} == 1 ]]; then echo "kept $T" >&2; else rm -rf "$T"; fi
}
trap cleanup EXIT
step() { printf '\n### %s\n' "$*"; }
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
# expect PATTERN CMD...: run CMD (must succeed), its stdout+stderr must match PATTERN (ERE)
expect() {
	local pat=$1 out
	shift
	out=$("$@" 2>&1) || fail "command failed: $*"$'\n'"$out"
	grep -Eq -- "$pat" <<<"$out" || fail "'$*' did not print /$pat/:"$'\n'"$out"
}
