#!/usr/bin/env bash
# Rolling+++ test with tiny local recipes (no downloads): soname bump with preserved libraries
# and automatic rebuild of dependents, holds, rollback, checksum --write.
# shellcheck source=tests/lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
RECIPES=$T/recipes
cp -r "$TESTS/fixtures" "$RECIPES"
b() { "$BROOM" -r "$ROOTFS" -R "$RECIPES" --host-deps --yes "$@"; }
export LD_LIBRARY_PATH=$ROOTFS/usr/lib
app() { "$ROOTFS/usr/bin/app"; }
ver() { b list | awk -v p="$1" '$1 == p { print $2 }'; }

step "checksum --write fills in the sha256 sums"
b --write checksum libfoo
b --write checksum app
grep -q 'SKIP' "$RECIPES/libfoo/recipe" "$RECIPES/app/recipe" && fail "SKIP left in recipes"
b lint

step "install app (pulls libfoo 1.0)"
b install app
[[ $(app) == "foo 1" ]] || fail "app output: $(app)"

step "libfoo 2.0 changes its soname: plan, then update"
sed -i 's/^version=1.0/version=2.0/' "$RECIPES/libfoo/recipe"
expect 'libfoo +1\.0-1 +-> 2\.0-1 +upgrade +\[major\]' b plan
b --no-sync update
expect 'libfoo\.so\.2' readelf -d "$ROOTFS/usr/bin/app"
[[ ! -e $ROOTFS/usr/lib/libfoo.so.1 ]] || fail "preserved libfoo.so.1 was not cleaned up"
[[ $(app) == "foo 2" ]] || fail "app output after update: $(app)"
b doctor
expect 'rebuild +app' b history

step "holds: a held package is skipped by update"
b hold app
sed -i 's/^release=1/release=2/' "$RECIPES/app/recipe"
expect 'app.*held' b plan
b --no-sync update
[[ $(ver app) == 1.0-1 ]] || fail "held app was updated"
b unhold app
b --no-sync update
[[ $(ver app) == 1.0-2 ]] || fail "app was not updated after unhold"

step "rollback reinstalls the previous build and holds it"
b rollback app
[[ $(ver app) == 1.0-1 ]] || fail "rollback did not restore 1.0-1"
expect 'app .*\[held\]' b list
[[ $(app) == "foo 2" ]] || fail "app broken after rollback"
b history

echo
echo "rolling test passed"
