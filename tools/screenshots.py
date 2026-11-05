#!/usr/bin/env python3
"""Screenshots of the installer's screens (cleanlinux-setup) on the console of the live image, in QEMU.

usage: tools/screenshots.py IMAGE OUTDIR [--arch x86_64|aarch64] [--lang ru|en] [--install]
                            [--desktop] [--size 800x600]

The live image (bootstrap.sh live) boots as the USB stick of a UEFI machine with a screen and an empty
disk, with no serial console: the installer opens on tty1, as on a PC. The tool presses the keys
a person would, through QMP, and saves every screen as it settles: OUTDIR/01-language.png and on
(QMP screendump, the console as it is drawn, font and all). --install goes on: erases the empty
virtual disk, saves the progress and the last screen. docs/INSTALL.md and the README show them.

--desktop: the image of a spin boots its desktop by default (labwc: the installer in a window over
it); the tool waits for it, saves it once it settles (OUTDIR/01-desktop.png) and the menu that Super
opens (02-menu.png). The first minute of the screen goes to OUTDIR/boot/ either way: the boot menu
is among it. The screen is the firmware's framebuffer (simpledrm in the guest): x86_64 has a VGA
of --size, aarch64 a ramfb of the firmware's size (1024x768 or so) and a USB keyboard.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests"))
from boot import find_firmware, nic_args, qemu_machine  # noqa: E402

USER, USER_PW = "anna", "anna-pw-2"
# the title bar of the screens: bold white on blue (the console's blue: 0x0000aa)
BLUE = (0, 0, 170)


class Machine:
    def __init__(self, arch, image, code, vars_copy, disk, sock, memory, log, res):
        cmd, _ = qemu_machine(arch)
        cmd += ["-m", str(memory), "-smp", "2", "-display", "none"]
        if arch == "x86_64":
            # the screen size of the EDID: the firmware and the console take it (1280x800 otherwise)
            cmd += ["-vga", "none", "-device", f"VGA,xres={res[0]},yres={res[1]}"]
        else:
            # the virt machine has no VGA (and qemu-kvm of RHEL no virtio-gpu): the firmware's ramfb
            cmd += ["-device", "ramfb"]
        cmd += [
            "-serial", f"file:{log}", "-monitor", "none",
            "-qmp", f"unix:{sock},server=on,wait=off",
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
            "-drive", f"if=pflash,format=raw,unit=1,file={vars_copy}",
            "-device", "virtio-rng-pci",
        ]
        cmd += nic_args(cmd[0])
        cmd += [
            "-device", "qemu-xhci,id=xhci", "-drive", f"file={image},format=raw,if=none,id=stick,snapshot=on",
            "-device", "usb-storage,bus=xhci.0,drive=stick,removable=on",
            "-drive", f"file={disk},format=raw,if=virtio",
        ]
        if arch != "x86_64":
            cmd += ["-device", "usb-kbd,bus=xhci.0"]  # no PS/2 controller on virt
        print("qemu: " + " ".join(cmd), flush=True)
        self.proc = subprocess.Popen(cmd)
        for _ in range(100):
            try:
                self.qmp = socket.socket(socket.AF_UNIX)
                self.qmp.connect(sock)
                break
            except OSError:
                time.sleep(0.1)
        else:
            sys.exit("no QMP socket")
        self.rx = self.qmp.makefile("r")
        self.rx.readline()  # the greeting
        self.cmd("qmp_capabilities")
        self.tmp = sock + ".png"

    def cmd(self, name, **args):
        self.qmp.sendall((json.dumps({"execute": name, "arguments": args}) + "\n").encode())
        while True:
            msg = json.loads(self.rx.readline())
            if "return" in msg:
                return msg["return"]
            if "error" in msg:
                raise RuntimeError(f"{name}: {msg['error']}")

    def keys(self, *combos):
        """combos like "down", "ret", "ctrl-u", "shift-a"; one key press each"""
        for combo in combos:
            keys = [{"type": "qcode", "data": k} for k in combo.split("-")] if combo != "minus" else \
                [{"type": "qcode", "data": "minus"}]
            self.cmd("send-key", keys=keys)
            time.sleep(0.4 if combo == "esc" else 0.15)

    def type(self, text):
        names = {"-": "minus", " ": "spc", ".": "dot", "_": "shift-minus", "@": "shift-2"}
        for c in text:
            if c in names:
                self.keys(names[c])
            elif c.isupper():
                self.keys("shift-" + c.lower())
            else:
                self.keys(c)

    def frame(self):
        self.cmd("screendump", filename=self.tmp, format="png")
        with Image.open(self.tmp) as im:
            return im.convert("RGB")

    def settle(self, before=None, timeout=120, quiet=3.0):
        """the screen once it differs from BEFORE and stays the same for QUIET seconds (the
        blinking cursor of a text field aside)"""
        deadline = time.monotonic() + timeout
        last, since = None, time.monotonic()
        while time.monotonic() < deadline:
            im = self.frame()
            if before is not None and same(im, before):
                last, since = None, time.monotonic()
            elif last is None or not same(im, last):
                last, since = im, time.monotonic()
            elif time.monotonic() - since >= quiet:
                return im
            time.sleep(0.5)
        return last or self.frame()

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()


def same(a, b):
    """the same picture, but for a cell or two: the cursor (8x16 pixels) blinks"""
    box = ImageChops.difference(a, b).getbbox()
    return box is None or (box[2] - box[0]) * (box[3] - box[1]) <= 2 * 8 * 16


def colourful(im):
    """a desktop rather than a console or a boot menu: a wallpaper has far more than 16 colours"""
    # every 4th pixel as it is (resampling would blend the glyphs of a console into many colours)
    colours = im.resize((max(1, im.width // 4), max(1, im.height // 4)), Image.NEAREST).getcolors(maxcolors=4096)
    return colours is None or len(colours) > 256


def tui_open(im):
    """the title bar of the installer at the top of the screen"""
    w = im.width
    row = [im.getpixel((x, 4)) for x in range(0, w, 4)]
    return sum(p == BLUE for p in row) > len(row) // 2


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("outdir")
    ap.add_argument("--arch", default="x86_64", choices=("x86_64", "aarch64"))
    ap.add_argument("--desktop", action="store_true", help="the desktop of a spin and its menu, not the console")
    ap.add_argument("--lang", default="ru", choices=("ru", "en"))
    ap.add_argument("--install", action="store_true", help="also install onto the empty disk")
    ap.add_argument("--memory", type=int, default=2048)
    ap.add_argument("--size", default="800x600", help="the screen (WIDTHxHEIGHT): 800x600 fills it with the installer")
    ap.add_argument("--boot-timeout", type=int, default=1800)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    code, vars_ = find_firmware(args.arch)
    tmp = tempfile.mkdtemp(prefix="cleanlinux-shots.")
    vars_copy, disk, sock = (os.path.join(tmp, n) for n in ("vars.fd", "disk.img", "qmp.sock"))
    shutil.copyfile(vars_, vars_copy)
    subprocess.run(["truncate", "-s", "8G", disk], check=True)
    m = Machine(args.arch, os.path.abspath(args.image), code, vars_copy, disk, sock, args.memory,
                os.path.join(args.outdir, "serial.log"), tuple(int(v) for v in args.size.split("x")))
    n = 0

    def shot(name, im):
        nonlocal n
        n += 1
        path = os.path.join(args.outdir, f"{n:02d}-{name}.png")
        im.save(path, optimize=True)
        print(f"{path}: {im.width}x{im.height}", flush=True)
        return im

    def step(name, *keys, text=None, timeout=120):
        before = m.frame()
        m.keys(*keys)
        if text:
            m.type(text)
        return shot(name, m.settle(before, timeout))

    try:
        t0 = time.monotonic()
        # the first minute, every new picture into OUTDIR/boot/ (the menu of systemd-boot is one)
        os.makedirs(os.path.join(args.outdir, "boot"), exist_ok=True)
        prev, b = None, 0
        while time.monotonic() - t0 < args.boot_timeout:
            if m.proc.poll() is not None:
                sys.exit("QEMU is gone")
            im = m.frame()
            if colourful(im) if args.desktop else tui_open(im):
                break
            early = time.monotonic() - t0 < 60
            if early and im.tobytes() != (prev.tobytes() if prev else None):
                b += 1
                im.save(os.path.join(args.outdir, "boot", f"{b:02d}.png"), optimize=True)
                prev = im
            time.sleep(1 if early else 5)
        else:
            shot("timeout", m.frame())
            sys.exit("the desktop did not open" if args.desktop else "the installer did not open")
        print(f"{'desktop' if args.desktop else 'installer'} open after {time.monotonic() - t0:.0f}s", flush=True)
        if args.desktop:
            # the panel and the installer's window come in a few seconds (TCG: more)
            shot("desktop", m.settle(None, 600, 15))
            # labwc opens its menu when Super is let go; Escape closes it again
            step("menu", "meta_l")
            m.keys("esc")
            return 0
        shot("language", m.settle(None, 30, 5))
        ru = args.lang == "ru"
        step("keyboard", *(["down", "ret"] if ru else ["ret"]))
        m.keys("ret")
        time.sleep(2)
        step("timezone", text="eur")
        m.keys("ret")
        time.sleep(2)
        step("city", text="mosc")
        step("disk", "ret")
        step("user", "ret")
        m.keys("tab")
        m.type(USER)
        m.keys("tab")
        m.type(USER_PW)
        m.keys("tab")
        step("user-filled", text=USER_PW)
        step("system", "ret")
        im = step("summary", "ret")
        if not tui_open(im):
            sys.exit("lost the installer")
        step("confirm", "ret")
        if not args.install:
            return 0
        m.keys("right", "ret")
        # TCG copies the packages in about a minute, a PC in seconds: a few pictures to choose from
        for _ in range(4):
            time.sleep(12)
            shot("progress", m.frame())
        # the last screen: nothing changes on it for two minutes
        last, since, deadline = m.frame(), time.monotonic(), time.monotonic() + 7200
        k = 0
        while time.monotonic() < deadline:
            time.sleep(15)
            im = m.frame()
            if not same(im, last):
                last, since = im, time.monotonic()
                k += 1
                if k % 20 == 0:
                    im.save(os.path.join(args.outdir, "progress-latest.png"))
            elif time.monotonic() - since > 120:
                shot("done", im)
                return 0
        shot("timeout", m.frame())
        return 1
    finally:
        m.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
