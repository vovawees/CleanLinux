#!/usr/bin/env bash
# Clean Linux ISO build wrapper around mkarchiso.
#
# Usage: scripts/build.sh [path/to/profile]
# Output: out/*.iso, intermediate files: work/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ARG="${1:-$REPO_ROOT/profiles/cleanlinux}"
PROFILE="$(readlink -f "$PROFILE_ARG")"
WORK_DIR="$REPO_ROOT/work"
OUT_DIR="$REPO_ROOT/out"

if ! command -v mkarchiso >/dev/null 2>&1; then
    echo "ERROR: mkarchiso not found. Install it with: sudo pacman -S archiso" >&2
    exit 1
fi

if [[ ! -f "$PROFILE/profiledef.sh" ]]; then
    echo "ERROR: '$PROFILE' is not an archiso profile (profiledef.sh missing)." >&2
    exit 1
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"

# Reproducible builds: anchor timestamps to the last commit.
export SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --pretty=%ct)"
echo "==> Building profile: $PROFILE"
echo "==> SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

exec mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE"
