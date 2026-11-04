#!/usr/bin/env bash
# The kernel configuration of the profiles: configure the kernel of each profile with the
# do_configure of the recipe linux itself (defconfig or KERNEL_CONFIG, cleanlinux.config, the arch
# fragment, VIDEO_CARDS, the profile's KERNEL_FRAGMENT) and check that every option the fragments
# ask for is in the final .config. An option that does not exist, depends on something that is off
# or loses to a later fragment shows up here, not on the device.
# A device with a list of its device trees (profiles/devices/NAME/boards) gets them checked too,
# by tools/dt-kconfig.py: a driver for every enabled node, the root's storage chain built in.
# Usage: tests/kernel-config.sh [--recipes DIR] [--keep DIR] KERNEL_SOURCE_DIR|linux-X.tar.xz [PROFILE...]
#   (default: every profile but native, which is this machine); --keep DIR keeps PROFILE.config
# shellcheck source=tests/lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
RECIPES=${BURN_RECIPES:-$TESTS/../../CleanLinux-Recipes/packages} KEEP_DIR=''
while (($#)); do
	case $1 in
		--recipes) RECIPES=$2 && shift 2 ;;
		--keep) KEEP_DIR=$2 && shift 2 ;;
		*) break ;;
	esac
done
(($#)) || fail "usage: tests/kernel-config.sh [--recipes DIR] [--keep DIR] KERNEL_SOURCE_DIR|linux-X.tar.xz [PROFILE...]"
RECIPES=$(readlink -f "$RECIPES")
[[ -f $RECIPES/linux/recipe ]] || fail "no recipe linux in $RECIPES"
SRC=$1 && shift
if [[ -f $SRC ]]; then
	step "unpack $SRC"
	mkdir -p "$T/src" && tar -xf "$SRC" -C "$T/src"
	SRC=$(find "$T/src" -mindepth 1 -maxdepth 1 -type d | head -1)
else
	# a copy of hard links: kconfig only writes new files (.config, include/, scripts/ objects)
	[[ -f $SRC/Kconfig ]] || fail "not a kernel source tree: $SRC"
	cp -al "$(readlink -f "$SRC")" "$T/linux" && SRC=$T/linux
fi
if (($# == 0)); then
	for f in "$BURN_PROFILE_DIR"/*.profile "$BURN_PROFILE_DIR"/devices/*.profile; do
		p=${f##*/} && p=${p%.profile}
		[[ $p == native ]] || set -- "$@" "$p"
	done
fi
[[ -z $KEEP_DIR ]] || mkdir -p "$KEEP_DIR"

# show PROFILE KEY: one value of 'burn profile show'
show() { "$BURN" -p "$1" profile show | sed -n "s/^$2 *//p"; }

# configure PROFILE: the recipe's do_configure in the source tree, for that profile
configure() (
	local p=$1 chost
	chost=$(show "$p" chost)
	case $chost in
		x86_64-*) KARCH=x86 ;;
		aarch64-*) KARCH=arm64 ;;
		*) fail "$p: no kernel arch for $chost" ;;
	esac
	VIDEO_CARDS=$(show "$p" video_cards) KERNEL_CONFIG=$(show "$p" kernel_config)
	KERNEL_FRAGMENT=$(show "$p" kernel_fragment) FEATURES=" $(show "$p" features) "
	[[ $VIDEO_CARDS != - ]] || VIDEO_CARDS=''
	[[ $KERNEL_CONFIG != - ]] || KERNEL_CONFIG=''
	[[ $KERNEL_FRAGMENT != - ]] || KERNEL_FRAGMENT=''
	FILES=$RECIPES/linux WORK=$T/work/$p CROSS=0 CHOST=$chost
	mkdir -p "$WORK"
	# the recipe calls these (SC2329)
	# shellcheck disable=SC2329
	die() { fail "$p: $*"; }
	# shellcheck disable=SC2329
	use() { [[ $FEATURES == *" $1 "* ]]; }
	# shellcheck source=/dev/null
	. "$RECIPES/linux/recipe"
	# configuring needs no cross compiler; the host's answers the compiler tests of Kconfig
	# shellcheck disable=SC2329
	_kmake() { make -s ARCH="$KARCH" HOSTCC=gcc "$@"; }
	cd "$SRC"
	do_configure >"$WORK/configure.log" 2>&1 || fail "$p: do_configure failed:"$'\n'"$(tail -20 "$WORK/configure.log")"
	cp .config "$WORK/.config"
)

# check PROFILE: every option of the merged fragments (the last one of a name wins) as asked
check() {
	local p=$1
	awk '
		FNR == NR {
			if (match($0, /^CONFIG_[A-Za-z0-9_]+=/)) want[substr($0, 1, RLENGTH - 1)] = substr($0, RLENGTH + 1)
			else if (match($0, /^# CONFIG_[A-Za-z0-9_]+ is not set/)) want[$2] = "n"
			next
		}
		match($0, /^CONFIG_[A-Za-z0-9_]+=/) { got[substr($0, 1, RLENGTH - 1)] = substr($0, RLENGTH + 1) }
		END {
			bad = 0
			for (k in want) {
				g = (k in got) ? got[k] : "n"
				if (g != want[k]) { printf "  %s: asked %s, got %s\n", k, want[k], g; bad++ }
			}
			exit bad > 0
		}' "$T/work/$p/fragment.config" "$T/work/$p/.config" | sort
}

# boards PROFILE: the device trees of profiles/devices/PROFILE/boards against its .config
#   rockchip/board.dts     a board of the device: every enabled node needs a driver
#   ref qcom/soc-ref.dts   a reference board of the SoC (no tree of the device in mainline):
#                          only the storage chain counts
#   root mmc,pci,usb       where the root may live (tools/dt-kconfig.py --root; mmc,ufs,ata)
#   ignore vendor,block    a compatible that needs no driver of its own (--ignore)
boards() {
	local p=$1 list=$BURN_PROFILE_DIR/devices/$1/boards root=mmc,ufs,ata line
	local -a own=() ref=() ignore=()
	[[ -f $list ]] || return 0
	while read -r line; do
		case $line in
			'' | '#'*) ;;
			root\ *) root=${line#root } ;;
			ignore\ *) ignore+=(--ignore "${line#ignore }") ;;
			ref\ *) ref+=("${line#ref }") ;;
			*) own+=("$line") ;;
		esac
	done <"$list"
	# the kernel's own dtc, built once in the configured tree
	[[ -x $SRC/scripts/dtc/dtc ]] || (cd "$SRC" && make -s ARCH=arm64 HOSTCC=gcc scripts_dtc >/dev/null) ||
		fail "$p: building dtc failed"
	local -a dt=(python3 "$TESTS/../tools/dt-kconfig.py" --kernel "$SRC" --config "$T/work/$p/.config"
		--dtc "$SRC/scripts/dtc/dtc" --root "$root" "${ignore[@]}")
	local rc=0
	if ((${#own[@]})); then "${dt[@]}" "${own[@]}" || rc=1; fi
	if ((${#ref[@]})); then "${dt[@]}" --ref "${ref[@]}" || rc=1; fi
	return "$rc"
}

bad=0
for p in "$@"; do
	step "$p"
	configure "$p"
	if out=$(check "$p"); then
		echo "ok: $(grep -c '^CONFIG_\|^# CONFIG_' "$T/work/$p/fragment.config") options as asked"
	else
		echo "$out" && bad=$((bad + 1))
	fi
	boards "$p" || bad=$((bad + 1))
	[[ -z $KEEP_DIR ]] || cp "$T/work/$p/.config" "$KEEP_DIR/$p.config"
done
((bad == 0)) || fail "$bad profile(s) do not get the kernel options they ask for"
