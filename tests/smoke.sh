#!/usr/bin/env bash
# Smoke test with real recipes: build and install compression libraries into a scratch root
# on the host toolchain, use them, query the database, remove them again.
# Usage: tests/smoke.sh [RECIPES_DIR]  (default: ../CleanLinux-Recipes/packages)
# shellcheck source=tests/lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
RECIPES=$(readlink -f "${1:-${BURN_RECIPES:-$TESTS/../../CleanLinux-Recipes/packages}}")
[[ -d $RECIPES ]] || fail "recipes not found: $RECIPES"
printf 'ASSUME_INSTALLED=(glibc)\nLOCALES=""\n' >"$T/burn.conf"
b() { "$BURN" -r "$ROOTFS" -R "$RECIPES" -c "$T/burn.conf" --host-deps --yes "$@"; }
export LD_LIBRARY_PATH=$ROOTFS/usr/lib

step "lint every recipe"
b lint

step "install zstd (pulls zlib-ng, xz, lz4) and pkgconf"
b install zstd pkgconf
b list

step "the installed tools work and use the root's libraries"
"$ROOTFS/usr/bin/zstd" --version
"$ROOTFS/usr/bin/xz" --version | head -n1
"$ROOTFS/usr/bin/lz4" --version
"$ROOTFS/usr/bin/pkg-config" --version
[[ $(echo clean | "$ROOTFS/usr/bin/zstd" -q | "$ROOTFS/usr/bin/zstd" -dq) == clean ]] || fail "zstd round trip"
[[ $(echo clean | "$ROOTFS/usr/bin/zstd" -q --format=xz | "$ROOTFS/usr/bin/xz" -dc) == clean ]] || fail "zstd xz support"
[[ $(echo clean | "$ROOTFS/usr/bin/zstd" -q --format=lz4 | "$ROOTFS/usr/bin/lz4" -dc) == clean ]] || fail "zstd lz4 support"
expect 'liblz4\.so' readelf -d "$ROOTFS/usr/bin/zstd"
expect "$ROOTFS/usr/lib/libz\.so\.1" ldd "$ROOTFS/usr/bin/zstd"

step "queries"
expect '^/usr/bin/lz4$' b files lz4
expect 'owned by zstd' b owner /usr/bin/zstd
expect 'owned by xz' b owner /bin/xz
expect '^installed +1\.5\.7' b info zstd
expect 'Nothing to do' b plan
b doctor

step "reproducible: lz4 rebuilt in another work directory has the same bytes"
pkg=$(b build lz4 2>/dev/null)
sum=$(sha256sum <"$pkg")
[[ $(BURN_WORK=$T/work2 b --rebuild build lz4 2>/dev/null) == "$pkg" ]] || fail "the lz4 rebuild got another BUILDID"
[[ $(sha256sum <"$pkg") == "$sum" ]] || fail "lz4 is not reproducible"

step "a feature change makes the plan rebuild zstd"
expect 'zstd.*rebuild' b -f -lz4 plan

step "dependency protection and removal"
if b remove lz4 2>/dev/null; then fail "removing lz4 must fail while zstd needs it"; fi
b remove zstd lz4
[[ ! -e $ROOTFS/usr/bin/zstd && ! -e $ROOTFS/usr/lib/liblz4.so.1 ]] || fail "files left after remove"
b history

echo
echo "smoke test passed"
