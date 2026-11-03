# shellcheck shell=bash
# Output, errors and small helpers.
#
# NOTE: never call build/install functions from a condition (if/||/&&):
# bash then silently disables `set -e` inside them.

if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
	C_B=$'\e[1m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_C=$'\e[36m' C_0=$'\e[0m'
else
	C_B='' C_G='' C_Y='' C_R='' C_C='' C_0=''
fi

msg() { printf '%s==>%s %s%s%s\n' "$C_G" "$C_0" "$C_B" "$*" "$C_0" >&2; }
msg2() { printf '  %s->%s %s\n' "$C_C" "$C_0" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die() {
	printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2
	exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# in_list NEEDLE ITEM...
in_list() {
	local n=$1 x
	shift
	for x; do [[ $x == "$n" ]] && return 0; done
	return 1
}

# vercmp A B -> -1, 0 or 1
vercmp() {
	if [[ $1 == "$2" ]]; then
		echo 0
	elif [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$1" ]]; then
		echo -1
	else
		echo 1
	fi
}

confirm() {
	[[ ${ASSUME_YES:-0} == 1 ]] && return 0
	[[ -t 0 ]] || die "confirmation needed but stdin is not a terminal (use --yes)"
	local a
	read -r -p "$1 [y/N] " a
	[[ $a == [yY]* ]]
}

is_elf() { [[ $(LC_ALL=C head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]; }

# run_fn NAME: call shell function NAME only if the recipe defines it
run_fn() {
	if declare -F "$1" >/dev/null; then "$1"; fi
	return 0
}