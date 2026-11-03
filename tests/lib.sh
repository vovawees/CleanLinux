# shellcheck shell=bash
# Shared helpers for the test scripts.
set -euo pipefail
TESTS=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
# burn: $BURN, or the release the burn recipe pins, built for this host
if [[ -z ${BURN:-} ]]; then
	BURN=$("$TESTS/../bootstrap/host-burn.sh" "${BURN_RECIPES:-$TESTS/../../CleanLinux-Recipes/packages}" \
		"$TESTS/../build/host")
fi
export BURN_PROFILE_DIR=${BURN_PROFILE_DIR:-$TESTS/../profiles}
T=$(mktemp -d "${TMPDIR:-/tmp}/burn-test.XXXXXX")
ROOTFS=$T/root
export BURN_CACHE=${BURN_CACHE:-$T/cache}
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
