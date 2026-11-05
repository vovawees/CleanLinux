#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""layer.py LOWER UPPER OUT: the overlay layer that turns the tree LOWER into the tree UPPER.

OUT gets what UPPER has that LOWER has not, or has otherwise: files, symbolic links, directories
and their modes and times, hard links kept, the directories on the way to them; what UPPER lacks
becomes a whiteout (a character device 0:0, which overlayfs reads as "deleted"). An overlay with
lowerdir=OUT:LOWER shows UPPER. Files of the same size are compared by content (package files
carry clamped times, so a time says little). Owners are not compared: the trees of the bootstrap
belong to one user and the image makes them root's. Extended attributes are copied when they can
be. bootstrap.sh live makes the layers of the live medium with it (nonfree/, spins/NAME/).
"""
import fcntl
import os
import stat
import sys

FICLONE = 0x40049409
CHUNK = 1 << 20


class Layer:
    def __init__(self, lower, upper, out):
        self.lower, self.upper, self.out = lower, upper, out
        self.made = {}  # directories made in OUT: relative path -> stat of UPPER
        self.links = {}  # (st_dev, st_ino) of UPPER -> path in OUT, for hard links
        self.files = self.symlinks = self.whiteouts = self.hardlinks = self.bytes = 0
        self.xattr_warned = set()

    # ---- what is the same

    @staticmethod
    def same_content(a, b):
        with open(a, "rb") as fa, open(b, "rb") as fb:
            while True:
                x = fa.read(CHUNK)
                if x != fb.read(CHUNK):
                    return False
                if not x:
                    return True

    def same(self, lo, up, sl, su):
        if stat.S_IFMT(sl.st_mode) != stat.S_IFMT(su.st_mode) or sl.st_mode != su.st_mode:
            return False
        if stat.S_ISLNK(su.st_mode):
            return os.readlink(lo) == os.readlink(up)
        if stat.S_ISREG(su.st_mode):
            return sl.st_size == su.st_size and self.same_content(lo, up)
        if stat.S_ISCHR(su.st_mode) or stat.S_ISBLK(su.st_mode):
            return sl.st_rdev == su.st_rdev
        return True  # fifos, sockets

    # ---- OUT

    def parents(self, rel):
        """the directories of OUT on the way to REL, with the metadata of UPPER"""
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in self.made:
                self.mkdir(d, os.lstat(os.path.join(self.upper, d)))

    def mkdir(self, rel, st):
        p = os.path.join(self.out, rel)
        try:
            os.mkdir(p, 0o700)
        except FileExistsError:
            pass
        self.made[rel] = st

    def xattrs(self, src, dst):
        try:
            names = os.listxattr(src, follow_symlinks=False)
        except OSError:
            return
        for n in names:
            try:
                os.setxattr(dst, n, os.getxattr(src, n, follow_symlinks=False), follow_symlinks=False)
            except OSError as e:
                if n not in self.xattr_warned:
                    self.xattr_warned.add(n)
                    print(f"layer.py: {n} not copied ({e.strerror}): {src}", file=sys.stderr)

    def copy_file(self, src, dst, st):
        with open(src, "rb") as fs:
            fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                try:
                    fcntl.ioctl(fd, FICLONE, fs.fileno())
                except OSError:
                    while True:
                        b = fs.read(CHUNK)
                        if not b:
                            break
                        mv = memoryview(b)
                        while mv:
                            mv = mv[os.write(fd, mv):]
            finally:
                os.close(fd)
        self.xattrs(src, dst)
        os.chmod(dst, stat.S_IMODE(st.st_mode))
        os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))
        self.files += 1
        self.bytes += st.st_size

    def copy(self, rel, st):
        """the entry REL of UPPER into OUT, a directory with all it holds"""
        src, dst = os.path.join(self.upper, rel), os.path.join(self.out, rel)
        m = st.st_mode
        if stat.S_ISDIR(m):
            self.mkdir(rel, st)
            self.xattrs(src, dst)
            with os.scandir(src) as it:
                names = sorted(e.name for e in it)
            for n in names:
                r = f"{rel}/{n}" if rel else n
                self.copy(r, os.lstat(os.path.join(self.upper, r)))
        elif stat.S_ISREG(m):
            key = (st.st_dev, st.st_ino)
            if st.st_nlink > 1 and key in self.links:
                os.link(self.links[key], dst)
                self.hardlinks += 1
                return
            self.copy_file(src, dst, st)
            if st.st_nlink > 1:
                self.links[key] = dst
        elif stat.S_ISLNK(m):
            os.symlink(os.readlink(src), dst)
            os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
            self.symlinks += 1
        elif stat.S_ISFIFO(m):
            os.mkfifo(dst, stat.S_IMODE(m))
            os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))
        elif stat.S_ISCHR(m) or stat.S_ISBLK(m):
            try:
                os.mknod(dst, m, st.st_rdev)
            except PermissionError:
                print(f"layer.py: the device {rel} is left out (no right to make it)", file=sys.stderr)
        else:
            print(f"layer.py: {rel} is left out (a socket)", file=sys.stderr)

    def whiteout(self, rel):
        self.parents(rel)
        os.mknod(os.path.join(self.out, rel), stat.S_IFCHR, os.makedev(0, 0))
        self.whiteouts += 1

    # ---- the walk

    def walk(self, rel):
        lo_dir = os.path.join(self.lower, rel) if rel else self.lower
        up_dir = os.path.join(self.upper, rel) if rel else self.upper
        with os.scandir(up_dir) as it:
            up = sorted(e.name for e in it)
        with os.scandir(lo_dir) as it:
            lo = {e.name for e in it}
        for n in up:
            r = f"{rel}/{n}" if rel else n
            u, l = os.path.join(self.upper, r), os.path.join(self.lower, r)
            su = os.lstat(u)
            try:
                sl = os.lstat(l) if n in lo else None
            except FileNotFoundError:
                sl = None
            if sl is not None and stat.S_ISDIR(su.st_mode) and stat.S_ISDIR(sl.st_mode):
                if su.st_mode != sl.st_mode:
                    self.parents(r)
                    self.mkdir(r, su)
                self.walk(r)
            elif sl is None or not self.same(l, u, sl, su):
                self.parents(r)
                self.copy(r, su)
        for n in sorted(lo.difference(up)):
            self.whiteout(f"{rel}/{n}" if rel else n)

    def run(self):
        os.makedirs(self.out, exist_ok=True)
        if os.listdir(self.out):
            sys.exit(f"layer.py: {self.out} is not empty")
        self.made[""] = os.lstat(self.upper)
        self.walk("")
        # the directories last, deepest first: their modes and times as in UPPER
        for rel in sorted(self.made, key=lambda r: r.count("/") + bool(r), reverse=True):
            st = self.made[rel]
            p = os.path.join(self.out, rel) if rel else self.out
            os.chmod(p, stat.S_IMODE(st.st_mode))
            os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
        print(f"layer {self.out}: {self.files} files ({self.bytes / 1048576:.1f} MiB), {self.symlinks} symbolic"
              f" links, {self.hardlinks} hard links, {len(self.made) - 1} directories, {self.whiteouts} whiteouts")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.split("\n\n")[0] if __doc__ else "usage: layer.py LOWER UPPER OUT")
    lower, upper, out = (os.path.abspath(a) for a in sys.argv[1:])
    for d in (lower, upper):
        if not os.path.isdir(d):
            sys.exit(f"layer.py: {d} is not a directory")
    Layer(lower, upper, out).run()


if __name__ == "__main__":
    main()
