#!/usr/bin/env python3
"""Install CleanLinux from its live ISO with the installer's screens, in QEMU, then boot the new disk.

usage: tests/iso.py ISO [--arch x86_64|aarch64] [--cdrom] [--encrypt] [--size 8G] [--memory MIB]
                    [--timeout SECONDS] [--keep DIR] [-q]

1. The ISO (bootstrap.sh iso) boots as a USB stick (--cdrom: as a CD) of a UEFI machine that has
   an empty disk. SMBIOS passes the serial console to the kernel (io.systemd.boot.kernel-cmdline-
   extra, which systemd-boot adds to its entries), so root logs in by itself on the serial line
   and the installer with screens (cleanlinux-setup) opens there. A small terminal emulator keeps
   its screen, and the test goes through it as a person would: Russian, the keyboard layout, the
   time zone found by searching (Europe/Moscow), the disk (the stick itself cannot be chosen), no
   encryption (--encrypt: LUKS2 with a passphrase), the computer's name, a user, a password of
   its own for root, the summary, "Erase and install". It waits for the installation, leaves to
   the console, checks the live system (overlay root, the medium, services, the package cache)
   and powers off.
2. Only the new disk boots, with the same UEFI variables. The test logs in as the user, then as
   root, and checks the choices (host name, time zone, keymap and font, groups, passwords, LUKS),
   the btrfs layout, the boot entry, the services, and that the new system has the packages of
   the live system and none of its live settings (autologin, the installer at login).

The ISO is not modified. Logs: ISO.live.log and ISO.installed.log (the serial consoles).
"""
import argparse
import codecs
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from boot import PANIC, find_firmware, nic_args, service_failures  # noqa: E402
from install import Run  # noqa: E402

ROOT_PW, USER, USER_PW, HOST, LUKS_PW = "root-pw-1", "anna", "anna-pw-2", "installed", "luks-pw-3x"
SERIAL = {"x86_64": "console=tty0 console=ttyS0,115200", "aarch64": "console=tty0 console=ttyAMA0,115200"}
ENTER, TAB, ESC, DOWN, RIGHT, HOME, CTRL_U = "\r", "\t", "\x1b", "\x1b[B", "\x1b[C", "\x1b[H", "\x15"

LIVE_CHECKS = r"""F=FAIL D=DONE; c() { "$@" >/dev/null 2>&1 || echo "CHECK-$F: $*"; };
cat /proc/cmdline; findmnt -rno TARGET,SOURCE,FSTYPE; c sh -c 'findmnt -no FSTYPE / | grep -qx overlay';
c sh -c 'findmnt -no FSTYPE /run/cleanlinux/live/medium | grep -qx iso9660';
c sh -c 'findmnt -no FSTYPE /run/cleanlinux/live/rootfs | grep -qx squashfs';
c grep -qx cleanlinux-live /proc/sys/kernel/hostname; c test -s /etc/machine-id; c test -s /tmp/cleanlinux-install.log;
c grep -q '^FIRMWARE=' /etc/burn/burn.conf; c sh -c 'ls /usr/lib/firmware | grep -q .';
for s in early-udevd early-fstab early-tmpfiles early-clock system login dhcpcd; do c dinitctl is-started $s; done;
dinitctl list; c burn doctor; burn list | wc -l | sed 's/^/LIVE-PKGS=/';
ls /var/cache/burn/packages | wc -l | sed 's/^/LIVE-CACHE=/'; df -h / /run/cleanlinux/live/rw; free -m;
echo "CHECKS-$D"
"""

INSTALLED_CHECKS = r"""F=FAIL D=DONE; c() { "$@" >/dev/null 2>&1 || echo "CHECK-$F: $*"; };
cat /proc/cmdline; findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS; cat /etc/fstab /etc/vconsole.conf;
c sh -c 'findmnt -no FSTYPE / | grep -qx btrfs'; c sh -c 'findmnt -no OPTIONS / | grep -q "subvol=/@"';
c sh -c 'findmnt -no FSTYPE /home | grep -qx btrfs'; c sh -c 'findmnt -no FSTYPE /boot | grep -qx vfat';
c sh -c 'ls /boot/loader/entries/*.conf'; c grep -qx HOST /proc/sys/kernel/hostname;
c sh -c 'readlink /etc/localtime | grep -q "zoneinfo/Europe/Moscow$"'; c sh -c 'date +%Z | grep -qx MSK';
c grep -qx 'KEYMAP=ruwin_alt_sh-UTF-8' /etc/vconsole.conf; c grep -q '^FONT=.' /etc/vconsole.conf;
c sh -c 'id -nG USER | grep -qw wheel'; c test -d /home/USER; c grep -q '^root:[$]y[$]' /etc/shadow;
c grep -q '^FIRMWARE=' /etc/burn/burn.conf; c sh -c 'ls /usr/lib/firmware | grep -q .';
c sh -c '! grep -rqs autologin /etc/dinit.d'; c sh -c '! grep -qs cleanlinux-setup /root/.bash_profile';
c sh -c '! grep -qs root=live /etc/kernel/cmdline'; LUKSCHECKS
for s in early-udevd early-root-rw early-fstab early-seed early-tmpfiles early-clock early-vconsole system login dhcpcd; do
c dinitctl is-started $s; done; c burn doctor; burn list | wc -l | sed 's/^/INSTALLED-PKGS=/'; c nano --version;
if [ -d /var/lib/burn/installed/base-devel ]; then echo BASE-DEVEL=yes; c make --version; c perl -e 1; c python3 -c 1;
c sh -c 'printf "int main(void) { return 0; }\n" | gcc -O2 -x c -o /tmp/t - && /tmp/t'; c cmake --version; c meson --version;
else echo BASE-DEVEL=no; fi; echo "CHECKS-$D"
"""
LUKS_CHECKS = r"""c cryptsetup isLuks --type luks2 /dev/vda2; c sh -c 'grep -q "^initrd " /boot/loader/entries/*.conf';
c sh -c 'findmnt -no SOURCE / | grep -q "^/dev/mapper/luks-"';"""


def installed_checks(encrypt):
    text = INSTALLED_CHECKS.replace("HOST", HOST).replace("USER", USER)
    text = text.replace("LUKSCHECKS", LUKS_CHECKS if encrypt else "")
    return " ".join(text.split("\n")).strip()


class Screen:
    """What a terminal shows of the TUI: cursor positioning, erasing and text (SGR ignored)."""

    def __init__(self, rows=24, cols=80):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.y = self.x = 0
        self.pending = ""

    def feed(self, s):
        s, self.pending = self.pending + s, ""
        i = 0
        while i < len(s):
            c = s[i]
            if c == "\x1b":
                m = re.match(r"\x1b\[([0-9;?]*)([@-~])", s[i:])
                if not m:
                    if len(s) - i < 16 and re.fullmatch(r"\x1b(\[[0-9;?]*)?", s[i:]):
                        self.pending = s[i:]
                        return
                    i += 2
                    continue
                self.csi(m.group(1), m.group(2))
                i += m.end()
                continue
            if c == "\r":
                self.x = 0
            elif c == "\n":
                self.y = min(self.y + 1, self.rows - 1)
            elif c == "\b":
                self.x = max(self.x - 1, 0)
            elif c >= " ":
                if self.x >= self.cols:
                    self.x = 0
                    self.y = min(self.y + 1, self.rows - 1)
                self.grid[self.y][self.x] = c
                self.x += 1
            i += 1

    def csi(self, params, final):
        if params.startswith("?"):
            return
        p = [int(v) if v else 0 for v in params.split(";")] if params else []
        if final == "H":
            self.y = min(max((p[0] if p else 1) - 1, 0), self.rows - 1)
            self.x = min(max((p[1] if len(p) > 1 else 1) - 1, 0), self.cols - 1)
        elif final == "J" and (p[:1] == [2] or p[:1] == [3]):
            self.grid = [[" "] * self.cols for _ in range(self.rows)]
        elif final == "K":
            for x in range(self.x, self.cols):
                self.grid[self.y][x] = " "

    def text(self):
        return "\n".join("".join(r).rstrip() for r in self.grid)


class Live:
    """The serial console of the live system: a log, a buffer for prompts, a screen for the TUI."""

    def __init__(self, cmd, log_path, echo):
        print(f"qemu: {' '.join(cmd)}", flush=True)
        self.log = open(log_path, "w", encoding="utf-8")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.echo, self.buf, self.pos, self.panic = echo, "", 0, None
        self.screen = Screen()
        self.lock = threading.Condition()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
        while True:
            data = self.proc.stdout.read1(4096)
            if not data:
                break
            text = dec.decode(data)
            self.log.write(text)
            self.log.flush()
            if self.echo:
                sys.stdout.write(text)
                sys.stdout.flush()
            with self.lock:
                self.buf += text
                self.screen.feed(text)
                self.lock.notify_all()
        with self.lock:
            self.lock.notify_all()

    def wait_for(self, *texts, timeout=60, any_of=False):
        """until every TEXT (any_of: one of them) is on the screen; the screen, or None (timeout,
        QEMU gone, panic)"""
        deadline = time.monotonic() + timeout
        with self.lock:
            while True:
                scr = self.screen.text()
                if (any if any_of else all)(t in scr for t in texts):
                    return scr
                p = PANIC.search(self.buf)
                if p:
                    self.panic = p.group(0).strip()
                    return None
                left = deadline - time.monotonic()
                if left <= 0 or self.proc.poll() is not None:
                    return None
                self.lock.wait(min(left, 1.0))

    def expect(self, pattern, timeout):
        """PATTERN in the console text after the last match: the text up to it, or None"""
        rx = re.compile(pattern)
        deadline = time.monotonic() + timeout
        with self.lock:
            while True:
                m = rx.search(self.buf, self.pos)
                if m:
                    text = self.buf[self.pos:m.end()]
                    self.pos = m.end()
                    return text
                left = deadline - time.monotonic()
                if left <= 0 or self.proc.poll() is not None:
                    return None
                self.lock.wait(min(left, 1.0))

    def keys(self, *keys):
        for k in keys:
            self.proc.stdin.write(k.encode())
            self.proc.stdin.flush()
            # Esc alone: the TUI waits a little for the rest of a key sequence
            time.sleep(0.3 if k == ESC else 0.08)

    def type(self, text):
        for c in text:
            self.keys(c)

    def send(self, line):
        self.keys(line + "\r")

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        self.log.close()


class Failed(Exception):
    pass


def qemu(arch, code, vars_copy, iso, target, cdrom, memory, extra_cmdline):
    kvm = os.access("/dev/kvm", os.R_OK | os.W_OK) and arch == os.uname().machine
    cmd = ["qemu-system-x86_64", "-machine", "q35"] if arch == "x86_64" else ["qemu-system-aarch64", "-machine", "virt"]
    cmd += ["-accel", "kvm", "-cpu", "host"] if kvm else ["-accel", "tcg", "-cpu", "max"]
    cmd += [
        "-m", str(memory), "-smp", "2", "-display", "none", "-monitor", "none", "-serial", "stdio", "-no-reboot",
        "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,unit=1,file={vars_copy}",
        "-device", "virtio-rng-pci",
    ]
    cmd += nic_args(cmd[0])
    if extra_cmdline:
        # SMBIOS type 11 (OEM strings): systemd-boot adds it to the command line of its entries
        value = "io.systemd.boot.kernel-cmdline-extra=" + extra_cmdline
        cmd += ["-smbios", "type=11,value=" + value.replace(",", ",,")]
    if iso and cdrom:
        cmd += ["-drive", f"file={iso},format=raw,if=none,id=cd,media=cdrom,readonly=on"]
        cmd += ["-device", "virtio-scsi-pci,id=scsi", "-device", "scsi-cd,drive=cd,bus=scsi.0"]
    elif iso:
        # the stick: USB mass storage behind an xHCI controller, as on a PC
        cmd += ["-device", "qemu-xhci,id=xhci", "-drive", f"file={iso},format=raw,if=none,id=stick,snapshot=on"]
        cmd += ["-device", "usb-storage,bus=xhci.0,drive=stick,removable=on"]
    cmd += ["-drive", f"file={target},format=raw,if=virtio"]
    return cmd, kvm


def need(screen, what):
    if screen is None:
        raise Failed(what)
    return screen


def go_through_screens(live, encrypt, cdrom, timeout):
    """the screens of cleanlinux-setup, in Russian; returns the summary screen"""
    s = need(live.wait_for("Language . Язык", "English", timeout=timeout), "the installer did not open on the serial console")
    print(f"\n--- the installer is open:\n{s}", flush=True)
    live.keys(DOWN, ENTER)
    need(live.wait_for("Добро пожаловать", "Далее"), "no welcome screen in Russian")
    live.keys(ENTER)
    need(live.wait_for("Раскладка клавиатуры", "> Русская"), "no keyboard layout screen with Russian chosen")
    live.keys(ENTER)
    need(live.wait_for("Часовой пояс", "Европа"), "no time zone screen")
    live.type("eur")
    need(live.wait_for("Поиск: eur"), "the search for a region does not show")
    live.keys(ENTER)
    need(live.wait_for("Часовой пояс: Европа", "Moscow"), "no cities of Europe")
    live.type("mosc")
    need(live.wait_for("Поиск: mosc"), "the search for a city does not show")
    live.keys(ENTER)
    s = need(live.wait_for("Диск", "/dev/vda"), "no disk screen with the empty disk (/dev/vda)")
    print(f"\n--- disks:\n{s}", flush=True)
    if not cdrom:
        # the stick is listed first and cannot be chosen: the line under the list says why
        need(live.wait_for("/dev/sda"), "the stick is not on the disk screen")
        live.keys(HOME)
        need(live.wait_for("> /dev/sda", "носитель установки"), "the stick is not the installation medium:\n"
             + live.screen.text())
        # the empty disk (the list is in a box: "| > /dev/vda ...")
        for _ in range(4):
            live.keys(DOWN)
            if live.wait_for("> /dev/vda", timeout=5):
                break
        else:
            raise Failed("cannot select /dev/vda:\n" + live.screen.text())
    need(live.wait_for("> /dev/vda", "пустой"), "/dev/vda is not chosen, or not shown as empty")
    live.keys(ENTER)
    need(live.wait_for("Шифрование", "Зашифровать диск"), "no encryption screen")
    if encrypt:
        live.keys(DOWN, ENTER)
        need(live.wait_for("Пароль шифрования", "Повтор"), "no passphrase fields")
        live.type(LUKS_PW)
        live.keys(TAB)
        live.type(LUKS_PW)
        live.keys(ENTER)
    else:
        live.keys(ENTER)
    need(live.wait_for("Компьютер и пользователь"), "no user screen")
    live.keys(CTRL_U)
    live.type(HOST)
    live.keys(TAB)
    live.type(USER)
    live.keys(TAB)
    live.type(USER_PW)
    live.keys(TAB)
    live.type(USER_PW)
    live.keys(ENTER)
    need(live.wait_for("Администратор (root)", f"Тот же пароль, что у {USER}"), "no root password screen")
    live.keys(DOWN, ENTER)
    need(live.wait_for("Пароль root"), "no root password fields")
    live.type(ROOT_PW)
    live.keys(TAB)
    live.type(ROOT_PW)
    live.keys(ENTER)
    s = need(live.wait_for("Всё готово к установке", "Оборудование", any_of=True), "no summary")
    if "Всё готово к установке" not in s:
        print(f"\n--- hardware profile:\n{s}", flush=True)
        live.keys(DOWN, ENTER)  # keep the profile of the live system
        s = need(live.wait_for("Всё готово к установке"), "no summary after the hardware screen")
    print(f"\n--- summary:\n{s}", flush=True)
    for want in ("/dev/vda", "Europe/Moscow", HOST, USER, "LUKS2" if encrypt else "нет"):
        if want not in s:
            raise Failed(f"the summary lacks {want!r}:\n{s}")
    live.keys(ENTER)
    need(live.wait_for("Стереть диск?", "Стереть и установить"), "no confirmation")
    live.keys(RIGHT, ENTER)
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iso")
    ap.add_argument("--arch", default=os.uname().machine, choices=sorted(SERIAL))
    ap.add_argument("--cdrom", action="store_true", help="the ISO as a CD, not as a USB stick")
    ap.add_argument("--encrypt", action="store_true", help="the root of the new disk in LUKS2")
    ap.add_argument("--size", default="8G", help="size of the empty disk")
    ap.add_argument("--memory", type=int, default=2048, help="MiB")
    ap.add_argument("--timeout", type=int, default=0, help="seconds until the installer opens (default: 300 KVM, 1800 TCG)")
    ap.add_argument("--keep", help="keep the installed disk in this directory")
    ap.add_argument("-q", "--quiet", action="store_true", help="do not echo the consoles")
    args = ap.parse_args()

    code, vars_ = find_firmware(args.arch)
    tmp = tempfile.mkdtemp(prefix="cleanlinux-iso.")
    vars_copy, target = os.path.join(tmp, "vars.fd"), os.path.join(tmp, "target.img")
    shutil.copyfile(vars_, vars_copy)
    subprocess.run(["truncate", "-s", args.size, target], check=True)
    iso = os.path.abspath(args.iso)
    failures, t0 = [], time.monotonic()
    try:
        # 1. the live system, its installer
        cmd, kvm = qemu(args.arch, code, vars_copy, iso, target, args.cdrom, args.memory, SERIAL[args.arch])
        timeout = args.timeout or (300 if kvm else 1800)
        live = Live(cmd, iso + ".live.log", not args.quiet)
        try:
            go_through_screens(live, args.encrypt, args.cdrom, timeout)
            # the progress shows one step at a time (and a fast machine may be done already)
            need(live.wait_for("Разметка диска", "Копирование пакетов", "CleanLinux установлен", "Установка не удалась",
                               timeout=120, any_of=True), "the installation does not start")
            print(f"\n--- installing after {time.monotonic() - t0:.0f}s", flush=True)
            deadline = time.monotonic() + 5400
            while True:
                s = live.wait_for("CleanLinux установлен", timeout=60)
                if s:
                    break
                scr = live.screen.text()
                if "Установка не удалась" in scr:
                    raise Failed("the installation failed:\n" + scr)
                if live.panic or live.proc.poll() is not None or time.monotonic() > deadline:
                    raise Failed(live.panic or "the installation did not finish:\n" + scr)
            print(f"\n--- installed after {time.monotonic() - t0:.0f}s:\n{s}", flush=True)
            live.keys(RIGHT, RIGHT, ENTER)  # Restart, Power off, [Exit to the console]
            live.pos = len(live.buf)
            live.send("")
            live.send("echo SHELL-$((40+2))")
            if live.expect(r"SHELL-42", 60) is None:
                raise Failed("no shell after leaving the installer")
            live.send(" ".join(LIVE_CHECKS.split("\n")).strip())
            out = live.expect(r"CHECKS-DONE", 600)
            if out is None:
                raise Failed("the checks of the live system did not finish")
            failures += ["live system: " + line.strip() for line in out.splitlines() if "CHECK-FAIL" in line]
            m = re.search(r"LIVE-PKGS=(\d+)", out)
            live_pkgs = m.group(1) if m else None
            live.send("poweroff")
            try:
                live.proc.wait(300)
            except subprocess.TimeoutExpired:
                failures.append("live system: no power off within 300s")
            failures += ["live system: " + f for f in service_failures(live.buf)]
        except Failed as e:
            failures.append(f"live system: {e}")
            return report(failures, t0)
        finally:
            live.close()

        # 2. the new disk alone
        cmd, kvm = qemu(args.arch, code, vars_copy, None, target, False, args.memory, None)
        run = Run(cmd, iso + ".installed.log", args.quiet)
        try:
            err = run.unlock(LUKS_PW, timeout) if args.encrypt else None
            if err:
                failures.append("installed system: " + err)
                return report(failures, t0)
            err = run.login(USER, USER_PW, timeout)
            if err:
                failures.append("installed system: " + err)
                return report(failures, t0)
            run.con.send("exit")
            err = run.login("root", ROOT_PW, 120)
            if err:
                failures.append("installed system: " + err)
                return report(failures, t0)
            run.con.send(installed_checks(args.encrypt))
            out = run.con.expect(r"CHECKS-DONE", 600)
            if out is None:
                failures.append("the checks of the installed system did not finish")
                return report(failures, t0)
            failures += ["installed system: " + line.strip() for line in out.splitlines() if "CHECK-FAIL" in line]
            m = re.search(r"INSTALLED-PKGS=(\d+)", out)
            if not m or m.group(1) != live_pkgs:
                failures.append(f"packages: {m.group(1) if m else '?'} installed, {live_pkgs} on the live system")
            # base-devel (ISO_BASE_DEVEL=1): the installed system builds; its checks are above
            m = re.search(r"BASE-DEVEL=(yes|no)", out)
            print(f"\n--- the installed system {'builds (base-devel)' if m and m.group(1) == 'yes' else 'has no base-devel'}", flush=True)
            err = run.poweroff()
            if err:
                failures.append("installed system: " + err)
            failures += ["installed system: " + f for f in service_failures(run.con.buf)]
        finally:
            run.close()
        if args.keep:
            os.makedirs(args.keep, exist_ok=True)
            shutil.move(target, os.path.join(args.keep, "installed.img"))
        return report(failures, t0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def report(failures, t0):
    print(f"\n--- {time.monotonic() - t0:.0f}s")
    for f in failures:
        print(f"FAIL: {f}")
    print("iso test: " + ("FAILED" if failures else "ok"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
