#!/usr/bin/env bash
# bootstrap/layer.py: the layer of two trees, checked through overlayfs (an unprivileged mount in a
# user namespace): lowerdir=LAYER:LOWER must show UPPER, and the layer holds only what changed.
set -euo pipefail
HERE=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
t=$(mktemp -d)
trap 'chmod -R u+w "$t"; rm -rf "$t"' EXIT
lo=$t/lower up=$t/upper out=$t/layer

mkdir -p "$lo"/{etc,usr/bin,usr/lib/old,var/lib/burn/installed/base,gone/deep,swap}
echo base >"$lo/etc/os-release"
echo same >"$lo/usr/bin/same"
echo aaaa >"$lo/usr/bin/edited"
echo mode >"$lo/usr/bin/mode"
echo old >"$lo/usr/lib/old/lib.so"
echo x >"$lo/gone/deep/file"
echo y >"$lo/removed"
echo file >"$lo/swap/was-file"
mkdir "$lo/swap/was-dir" && echo z >"$lo/swap/was-dir/f"
ln -s same "$lo/usr/bin/link"
mkdir -m 0750 "$lo/private"
touch -d @1000000000 "$lo/usr/bin/edited"
cp -a "$lo" "$up"

echo bbbb >"$up/usr/bin/edited" && touch -d @1000000000 "$up/usr/bin/edited" # same size, same time
chmod 0755 "$up/usr/bin/mode"
echo new >"$up/usr/bin/new"
ln "$up/usr/bin/new" "$up/usr/bin/new-hardlink"
mkdir -p "$up/usr/share/spin/icons" && echo icon >"$up/usr/share/spin/icons/a.svg"
mkdir -p "$up/var/lib/burn/installed/labwc" && echo name=labwc >"$up/var/lib/burn/installed/labwc/meta"
rm -r "$up/gone" "$up/removed" "$up/usr/lib/old"
rm "$up/swap/was-file" && mkdir "$up/swap/was-file" && echo now-dir >"$up/swap/was-file/f"
rm -r "$up/swap/was-dir" && echo now-file >"$up/swap/was-dir"
ln -sfn new "$up/usr/bin/link"
chmod 0700 "$up/private"
: >"$up/empty"

python3 "$HERE/../bootstrap/layer.py" "$lo" "$up" "$out"

# only the changes are in the layer
for p in etc/os-release usr/bin/same var/lib/burn/installed/base; do
	[[ ! -e $out/$p ]] || { echo "FAIL: unchanged $p is in the layer" >&2; exit 1; }
done
for p in gone removed usr/lib/old; do
	[[ $(stat -c %F:%t:%T "$out/$p") == "character special file:0:0" ]] || { echo "FAIL: $p is no whiteout" >&2; exit 1; }
done
[[ $(stat -c %i "$out/usr/bin/new") == $(stat -c %i "$out/usr/bin/new-hardlink") ]] || { echo "FAIL: hard link lost" >&2; exit 1; }

# the overlay shows UPPER
# shellcheck disable=SC2016 # sh expands them
unshare -rm sh -c 'mkdir -p "$1/m" && mount -t overlay overlay -o "lowerdir=$2:$3" "$1/m" &&
	python3 - "$1/m" "$4" <<"PY"
import os, stat, sys
def tree(root):
    r = {}
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(d, n); st = os.lstat(p); rel = os.path.relpath(p, root)
            v = (stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode))
            if stat.S_ISLNK(st.st_mode): v += (os.readlink(p),)
            elif stat.S_ISREG(st.st_mode): v += (open(p, "rb").read(),)
            r[rel] = v
    return r
m, u = tree(sys.argv[1]), tree(sys.argv[2])
bad = sorted(k for k in set(m) | set(u) if m.get(k) != u.get(k))
for k in bad: print("differs:", k, m.get(k), u.get(k))
sys.exit(1 if bad else 0)
PY' sh "$t" "$out" "$lo" "$up" || { echo "FAIL: the overlay does not show the upper tree" >&2; exit 1; }
echo "layer.py: ok"
