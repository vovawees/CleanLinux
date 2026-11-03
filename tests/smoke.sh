#!/usr/bin/env bash
# Smoke test with real recipes: build and install compression libraries and kmod into a scratch
# root on the host toolchain, use them, query the database, remove them again.
# Usage: tests/smoke.sh [RECIPES_DIR]  (default: ../CleanLinux-Recipes/packages)
# shellcheck source=tests/lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
RECIPES=$(readlink -f "${1:-${BURN_RECIPES:-$TESTS/../../CleanLinux-Recipes/packages}}")
[[ -d $RECIPES ]] || fail "recipes not found: $RECIPES"
printf 'ASSUME_INSTALLED=(glibc)\nLOCALES=""\n' >"$T/burn.conf"
b() { "$BURN" -r "$ROOTFS" -R "$RECIPES" -c "$T/burn.conf" --host-deps --yes "$@"; }
# the installed programs with the root's libraries; not for burn itself, whose libzstd (and so
# the package bytes) must not change when the root gets another zstd
rt() { LD_LIBRARY_PATH=$ROOTFS/usr/lib "$@"; }

step "lint every recipe"
b lint

step "install zstd (pulls zlib-ng, xz, lz4) and pkgconf"
b install zstd pkgconf
b list

step "the installed tools work and use the root's libraries"
rt "$ROOTFS/usr/bin/zstd" --version
rt "$ROOTFS/usr/bin/xz" --version | head -n1
rt "$ROOTFS/usr/bin/lz4" --version
rt "$ROOTFS/usr/bin/pkg-config" --version
[[ $(echo clean | rt "$ROOTFS/usr/bin/zstd" -q | rt "$ROOTFS/usr/bin/zstd" -dq) == clean ]] || fail "zstd round trip"
[[ $(echo clean | rt "$ROOTFS/usr/bin/zstd" -q --format=xz | rt "$ROOTFS/usr/bin/xz" -dc) == clean ]] || fail "zstd xz support"
[[ $(echo clean | rt "$ROOTFS/usr/bin/zstd" -q --format=lz4 | rt "$ROOTFS/usr/bin/lz4" -dc) == clean ]] || fail "zstd lz4 support"
expect 'liblz4\.so' readelf -d "$ROOTFS/usr/bin/zstd"
expect "$ROOTFS/usr/lib/libz\.so\.1" rt ldd "$ROOTFS/usr/bin/zstd"

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

step "kmod, and the depmod trigger on kernel install, upgrade and removal"
b install kmod
rt "$ROOTFS/usr/bin/kmod" --version
cp -r "$TESTS/fixtures" "$T/fixtures"
k() { b -R "$T/fixtures" "$@"; }
k install fakekernel
[[ -f $ROOTFS/usr/lib/modules/1.0-test/modules.dep ]] || fail "depmod did not run for kernel 1.0-test"
sed -i 's/^version=1.0/version=2.0/' "$T/fixtures/fakekernel/recipe"
k install fakekernel
[[ -f $ROOTFS/usr/lib/modules/2.0-test/modules.dep ]] || fail "depmod did not run for kernel 2.0-test"
[[ ! -e $ROOTFS/usr/lib/modules/1.0-test ]] || fail "the module directory of the old kernel was left behind"
k remove fakekernel kmod
[[ ! -e $ROOTFS/usr/lib/modules/2.0-test ]] || fail "module directory left after removing the kernel"

step "dependency protection and removal"
if b remove lz4 2>/dev/null; then fail "removing lz4 must fail while zstd needs it"; fi
b remove zstd lz4
[[ ! -e $ROOTFS/usr/bin/zstd && ! -e $ROOTFS/usr/lib/liblz4.so.1 ]] || fail "files left after remove"
b history

echo
echo "smoke test passed"
