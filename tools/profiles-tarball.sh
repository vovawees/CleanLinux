#!/bin/bash
# profiles-tarball.sh VERSION: the source of the package cleanlinux-profiles (CleanLinux-Recipes),
# profiles/ and LICENSE of the committed HEAD, as cleanlinux-profiles-VERSION.tar.gz. It goes to
# the GitHub release profiles-VERSION; then the recipe gets the version and the sha256 printed here.
set -euo pipefail
[[ $# == 1 && $1 =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "usage: $0 VERSION (e.g. $(date -u +%Y.%-m.%-d))" >&2; exit 2; }
cd "$(dirname "$0")/.."
[[ -z $(git status --porcelain -- profiles LICENSE) ]] || { echo "profiles/ has uncommitted changes" >&2; exit 1; }
out=cleanlinux-profiles-$1.tar.gz
git archive --format=tar --prefix="cleanlinux-profiles-$1/" HEAD profiles LICENSE | gzip -n -9 >"$out"
sha256sum "$out"
