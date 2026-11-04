#!/usr/bin/env python3
"""dt-kconfig: which kernel options a device tree needs, checked against a .config.

Usage: tools/dt-kconfig.py --kernel SRC --config .config [--dtc DTC] [--root KINDS] [--ref]
                           [--ignore COMPATIBLE]... DTS...

For every enabled node of each DTS (a path under arch/<arch>/boot/dts or a file) it finds the drivers
that match the node's compatibles in the kernel source (of_device_id tables and *_OF_DECLARE),
the Kconfig options that build them (the Makefiles: obj-$(CONFIG_X) += x.o, x-y/x-objs, the
directory's own option) and reports:
  missing  nodes that no enabled driver serves (each option they could use, with its value)
  storage  the controllers the root may live on (--root, default mmc,ufs,ata; pci for NVMe, usb
           for USB drives) and everything they need to probe: clocks, resets, power domains,
           supplies, pins, PHYs, GPIOs, IOMMUs, interconnects, with their parent buses. Without an
           initramfs the root is mounted before any module loads: each of them must be built in.
--ref only checks the storage chain: a reference board of the SoC when the device's own tree is not
in mainline. The exit status is 1 when a storage node is not built in, or (without --ref) when a node
has no driver; --missing-ok keeps the status 0 for the missing nodes (the report stays).
--ignore COMPATIBLE: nodes of that compatible need no driver here (a block another one serves, a
driver the architecture cannot build: the BCM2835 system timer on arm64, which runs on the
architected timer).
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

# ---- the device tree (dtc -O dts output: labels and &references are kept) ----


class Node:
    def __init__(self, name, parent):
        self.name, self.parent, self.props, self.children, self.labels = name, parent, {}, [], []

    @property
    def path(self):
        if self.parent is None:
            return "/"
        p = self.parent.path
        return (p if p != "/" else "") + "/" + self.name

    def strings(self, prop):
        return re.findall(r'"((?:[^"\\]|\\.)*)"', self.props.get(prop, ""))

    def enabled(self):
        st = self.strings("status")
        return not st or st[0] in ("okay", "ok")


TOKEN = re.compile(r'\s*(?:(/\*.*?\*/)|(//[^\n]*)|("(?:[^"\\]|\\.)*")|(<[^>]*>)|(\[[^\]]*\])|([{};=,])|([^\s{};=,"<\[]+))', re.S)


def parse_dts(text):
    root, stack, labels = None, [], {}
    pending, i, n = [], 0, len(text)
    tokens = []
    while i < n:
        m = TOKEN.match(text, i)
        if not m:
            if text[i:].strip() == "":
                break
            raise SystemExit("dt-kconfig: cannot parse the device tree near: " + text[i:i + 60])
        i = m.end()
        if m.group(1) or m.group(2):
            continue
        tokens.append(m.group(0).strip())
    j = 0
    while j < len(tokens):
        t = tokens[j]
        if t == "/dts-v1/" or t.startswith("/memreserve/"):
            while tokens[j] != ";":
                j += 1
            j += 1
            continue
        if t == "}":
            stack.pop()
            j += 2 if j + 1 < len(tokens) and tokens[j + 1] == ";" else 1
            continue
        # labels: "name:" tokens before a node or property
        words = []
        while tokens[j] not in ("{", ";", "="):
            words.append(tokens[j])
            j += 1
        lbls = [w[:-1] for w in words if w.endswith(":")]
        names = [w for w in words if not w.endswith(":")]
        name = names[-1] if names else ""
        if tokens[j] == "{":
            node = Node(name if stack else "/", stack[-1] if stack else None)
            node.labels = lbls
            if stack:
                stack[-1].children.append(node)
            else:
                root = node
            for lb in lbls:
                labels[lb] = node
            stack.append(node)
            j += 1
        elif tokens[j] == ";":
            stack[-1].props[name] = ""
            j += 1
        else:  # =
            j += 1
            vals = []
            while tokens[j] != ";":
                vals.append(tokens[j])
                j += 1
            stack[-1].props[name] = " ".join(vals)
            j += 1
    return root, labels


def compile_dts(src, dts, dtc):
    arch_dts = None
    if not os.path.isfile(dts):
        for a in ("arm64", "arm", "riscv"):
            cand = os.path.join(src, "arch", a, "boot", "dts", dts)
            if os.path.isfile(cand):
                dts, arch_dts = cand, os.path.join(src, "arch", a, "boot", "dts")
                break
        else:
            raise SystemExit("dt-kconfig: no such device tree: " + dts)
    inc = ["-I", os.path.dirname(os.path.abspath(dts)), "-I", os.path.join(src, "include"),
           "-I", os.path.join(src, "scripts", "dtc", "include-prefixes")]
    if arch_dts:
        inc += ["-I", arch_dts]
    pre = subprocess.run(["cpp", "-nostdinc", *inc, "-undef", "-D__DTS__", "-x", "assembler-with-cpp", dts],
                         capture_output=True, text=True)
    if pre.returncode:
        raise SystemExit("dt-kconfig: cpp failed for %s:\n%s" % (dts, pre.stderr))
    out = subprocess.run([dtc, "-q", "-I", "dts", "-O", "dts", "-o", "-", "-"], input=pre.stdout,
                         capture_output=True, text=True)
    if out.returncode:
        raise SystemExit("dt-kconfig: dtc failed for %s:\n%s" % (dts, out.stderr))
    return out.stdout


# ---- the drivers: compatible -> source files -> Kconfig options ----

COMPAT = re.compile(r'\.compatible\s*=\s*"([^"]+)"|_DECLARE\s*\(\s*\w+\s*,\s*"([^"]+)"')


def read_makefile(path):
    try:
        with open(path, errors="replace") as f:
            text = f.read().replace("\\\n", " ")
    except OSError:
        return []
    rules = []
    for line in text.splitlines():
        line = line.split("#", 1)[0]
        m = re.match(r'\s*([\w.-]+?)-(y|objs|\$\((CONFIG_\w+)\))\s*[:+]?=\s*(.*)', line)
        if m:
            rules.append((m.group(1), m.group(3), m.group(4).split()))
    return rules


class Drivers:
    def __init__(self, src):
        self.src, self.makefiles, self.by_compat = src, {}, {}
        files = []
        for top in ("drivers", "sound"):
            for d, _, names in os.walk(os.path.join(src, top)):
                files += [os.path.join(d, n) for n in names if n.endswith(".c")]
        for f in files:
            with open(f, errors="replace") as fh:
                text = fh.read()
            if "compatible" not in text and "_DECLARE" not in text:
                continue
            for m in COMPAT.finditer(text):
                self.by_compat.setdefault(m.group(1) or m.group(2), set()).add(f)

    def rules(self, d):
        if d not in self.makefiles:
            r = read_makefile(os.path.join(d, "Makefile"))
            if not r:
                r = read_makefile(os.path.join(d, "Kbuild"))
            self.makefiles[d] = r
        return self.makefiles[d]

    def dir_options(self, d):
        """the options that make kbuild descend into the directory d"""
        parent = os.path.dirname(d)
        if len(parent) <= len(self.src):
            return []
        base = os.path.basename(d) + "/"
        for target, cond, objs in self.rules(parent):
            if target == "obj" and base in objs:
                return ([cond] if cond else []) + self.dir_options(parent)
        return self.dir_options(parent)

    def options(self, f):
        """lists of options that build the source file f (one list per way it is built)"""
        d, obj = os.path.dirname(f), os.path.basename(f)[:-2] + ".o"
        ways = []

        def walk(o, conds, depth):
            if depth > 4:
                return
            for target, cond, objs in self.rules(d):
                if o not in objs:
                    continue
                c = conds + ([cond] if cond else [])
                if target == "obj":
                    ways.append(c)
                elif target not in ("ccflags", "subdir", "asflags", "ldflags", "always", "extra", "hostprogs", "targets", "lib"):
                    walk(target + ".o", c, depth + 1)

        walk(obj, [], 0)
        up = self.dir_options(d)
        return [w + up for w in ways]


def value(config, opt):
    return config.get(opt, "n")


def state(config, ways):
    """the best way to have the driver: 'y', 'm' or 'n'"""
    best = "n"
    for w in ways:
        vals = [value(config, o) for o in w]
        if all(v == "y" for v in vals):
            return "y"
        if all(v in ("y", "m") for v in vals):
            best = "m"
    return best


def read_config(path):
    cfg = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'(CONFIG_\w+)=(.*)', line)
            if m:
                cfg[m.group(1)] = m.group(2)
    return cfg


# ---- the checks ----

ROOT_KINDS = {"mmc": ("drivers/mmc/host/",), "ufs": ("drivers/ufs/",), "ata": ("drivers/ata/",),
              "pci": ("drivers/pci/controller/",), "usb": ("drivers/usb/dwc3/", "drivers/usb/dwc2/", "drivers/usb/host/")}
REF_PROPS = re.compile(r'^(clocks|assigned-clocks|assigned-clock-parents|resets|power-domains|.*-supply|pinctrl-\d+|phys|.*-gpios?|iommus|interconnects|mmc-pwrseq|operating-points-v2|nvmem-cells)$')


def node_drivers(drv, node):
    files = set()
    for c in node.strings("compatible"):
        files |= drv.by_compat.get(c, set())
    return files


def node_ways(drv, node):
    ways = []
    for f in sorted(node_drivers(drv, node)):
        ways += drv.options(f)
    return ways


def refs(node, labels):
    out = []
    for prop, val in node.props.items():
        # the input clocks of a clock controller (PHY pipe clocks...) do not hold back its probe:
        # they are optional parents, and form cycles that fw_devlink relaxes
        if prop == "clocks" and "#clock-cells" in node.props:
            continue
        if REF_PROPS.match(prop):
            for lb in re.findall(r'&([\w-]+)', val):
                if lb in labels:
                    out.append(labels[lb])
    return out


def check(drv, config, dts_text, name, ref_only, storage_dirs, ignore=()):
    root, labels = parse_dts(dts_text)
    nodes = []

    def walk(n):
        if not n.enabled():
            return
        nodes.append(n)
        for c in n.children:
            walk(c)

    walk(root)
    rel = lambda f: os.path.relpath(f, drv.src)
    storage = [n for n in nodes if n.strings("compatible") and any(rel(f).startswith(storage_dirs) for f in node_drivers(drv, n))]
    # the probe chain of the storage controllers: references and parent buses, transitively
    chain, todo = {}, list(storage)
    while todo:
        n = todo.pop()
        if n.path in chain or n is root:
            continue
        chain[n.path] = n
        todo += refs(n, labels)
        p = n.parent
        while p is not None and p is not root:
            if p.strings("compatible"):
                todo.append(p)
                break
            p = p.parent
        # a pin configuration's owner is its pin controller
        if not n.strings("compatible") and n.parent is not None:
            q = n.parent
            while q is not None and not q.strings("compatible"):
                q = q.parent
            if q is not None and q is not root:
                todo.append(q)
    bad_storage, missing = [], []
    for n in sorted(chain.values(), key=lambda x: x.path):
        if not n.strings("compatible"):
            continue
        ways = node_ways(drv, n)
        if not ways:
            continue  # data nodes (fixed clocks and regulators come with the core)
        s = state(config, ways)
        if s != "y":
            bad_storage.append((n, s, ways))
    if not ref_only:
        for n in nodes:
            if not n.strings("compatible") or n is root or set(n.strings("compatible")) & set(ignore):
                continue
            ways = node_ways(drv, n)
            if ways and state(config, ways) == "n":
                missing.append((n, ways))
    print("== %s: %d enabled nodes, %d on the storage chain" % (name, len(nodes), len(chain)))
    for n, s, ways in bad_storage:
        print("  storage chain, not built in (%s): %s %s -> %s" % (s, n.path, n.strings("compatible")[0], fmt(config, ways)))
    for n, ways in missing:
        print("  no driver: %s %s -> %s" % (n.path, n.strings("compatible")[0], fmt(config, ways)))
    return bad_storage, missing


def fmt(config, ways):
    seen, out = set(), []
    for w in ways:
        k = " ".join("%s=%s" % (o, value(config, o)) for o in w)
        if k not in seen:
            seen.add(k)
            out.append(k)
    return " | ".join(out[:3])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--dtc", default="dtc")
    ap.add_argument("--root", default="mmc,ufs,ata")
    ap.add_argument("--ref", action="store_true")
    ap.add_argument("--missing-ok", action="store_true")
    ap.add_argument("--ignore", action="append", default=[], metavar="COMPATIBLE")
    ap.add_argument("dts", nargs="+")
    a = ap.parse_args()
    src = os.path.abspath(a.kernel)
    config = read_config(a.config)
    kinds = [k for k in a.root.split(",") if k]
    unknown = [k for k in kinds if k not in ROOT_KINDS]
    if unknown:
        raise SystemExit("dt-kconfig: unknown --root kind %s (%s)" % (unknown[0], ",".join(ROOT_KINDS)))
    storage_dirs = tuple(d for k in kinds for d in ROOT_KINDS[k])
    drv = Drivers(src)
    rc = 0
    for dts in a.dts:
        bad, missing = check(drv, config, compile_dts(src, dts, a.dtc), dts, a.ref, storage_dirs, a.ignore)
        if bad or (missing and not a.missing_ok):
            rc = 1
    sys.exit(rc)


if __name__ == "__main__":
    main()
