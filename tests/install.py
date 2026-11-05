#!/usr/bin/env python3
"""Install CleanLinux from its disk image onto an empty disk in QEMU, then boot the new disk.

usage: tests/install.py IMAGE [--arch x86_64|aarch64] [--size 8G] [--timeout SECONDS] [--keep DIR]

1. The image (bootstrap.sh disk) boots with a second, empty disk. As root, cleanlinux-install
   erases the second disk and installs the running system on it (burn clone: a disk image has no
   live layers; passwords from files, a user, a host name, the serial console on the kernel
   command line), then the VM powers off.
2. Only the new disk boots, with the same UEFI variables (the installer's boot entry). The test
   logs in as the new user, then as root, checks mounts, services and packages, and powers off.
   A service that fails to start or to stop on either system fails the test.

The image is not modified (QEMU snapshot mode). Logs: IMAGE.install.log and IMAGE.installed.log.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from boot import Console, find_firmware, nic_args, qemu_machine, service_failures  # noqa: E402

ROOT_PW, USER, USER_PW, HOST = "root-pw-1", "anna", "anna-pw-2", "installed"
CONSOLE = {"x86_64": "console=tty0 console=ttyS0,115200", "aarch64": "console=tty0 console=ttyAMA0,115200"}

INSTALL = (
    f"printf '%s\\n' {ROOT_PW} >/tmp/rpw; printf '%s\\n' {USER_PW} >/tmp/upw; "
    "cleanlinux-install -y --root-password-file /tmp/rpw --user {user} --user-password-file /tmp/upw "
    "--hostname {host} --cmdline '{console}' /dev/vdb; echo INSTALL-RC=$?; burn list | wc -l | sed 's/^/LIVE-PKGS=/'"
)

# on the installed system, as root (the markers are built by the shell: the echo of the typed
# line never matches them)
CHECKS = r"""F=FAIL D=DONE; c() { "$@" >/dev/null 2>&1 || echo "CHECK-$F: $*"; };
cat /proc/cmdline; findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS; cat /etc/fstab;
c sh -c 'findmnt -no FSTYPE / | grep -qx btrfs'; c sh -c 'findmnt -no OPTIONS / | grep -q "subvol=/@"';
c sh -c 'findmnt -no OPTIONS / | grep -qw rw'; c sh -c 'findmnt -no SOURCE / | grep -q "^ROOTSRC"';
c sh -c 'findmnt -no FSTYPE /home | grep -qx btrfs'; c sh -c 'findmnt -no FSTYPE /.snapshots | grep -qx btrfs';
c sh -c 'findmnt -no FSTYPE /boot | grep -qx vfat'; c test -f /boot/EFI/BOOT/BOOTX64.EFI -o -f /boot/EFI/BOOT/BOOTAA64.EFI;
c sh -c 'ls /boot/loader/entries/*.conf'; c grep -q 'root=PARTUUID=' /etc/kernel/cmdline;
c grep -qx HOST /proc/sys/kernel/hostname; c grep -qx HOST /etc/hostname; c test -s /etc/machine-id;
c sh -c 'id -nG USER | grep -qw wheel'; c sh -c 'id -nG USER | grep -qw audio'; c test -d /home/USER; c sh -c 'stat -c %U /home/USER | grep -qx USER';
c grep -q '^root:[$]y[$]' /etc/shadow; c test -L /etc/dinit.d/boot.d/dhcpcd;
for s in early-udevd early-root-rw early-fstab early-seed early-tmpfiles early-clock system login dhcpcd; do
c dinitctl is-started $s; done;
c burn --version; c burn doctor; burn list | wc -l | sed 's/^/INSTALLED-PKGS=/';
ls /sys/firmware/efi/efivars | grep -c '^Boot[0-9A-F]' | sed 's/^/EFI-BOOT-ENTRIES=/';
echo "CHECKS-$D"
"""


def checks():
    text = CHECKS.replace("HOST", HOST).replace("USER", USER).replace("ROOTSRC", "/dev/vda2")
    return " ".join(text.split("\n")).strip()


def qemu(arch, code, vars_copy, drives, memory):
    cmd, kvm = qemu_machine(arch)
    cmd += [
        "-m", str(memory), "-smp", "2", "-display", "none", "-monitor", "none", "-serial", "stdio", "-no-reboot",
        "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,unit=1,file={vars_copy}",
        "-device", "virtio-rng-pci",
    ]
    cmd += nic_args(cmd[0])
    for path, snapshot in drives:
        cmd += ["-drive", f"file={path},format=raw,if=virtio" + (",snapshot=on" if snapshot else "")]
    return cmd, kvm


class Run:
    def __init__(self, cmd, log_path, quiet):
        print(f"qemu: {' '.join(cmd)}", flush=True)
        self.log = open(log_path, "w", encoding="utf-8")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.con = Console(self.proc, self.log, not quiet)

    def login(self, user, password, timeout):
        if self.con.expect(r"login: ", timeout) is None:
            return self.con.panic or f"no login prompt within {timeout}s"
        self.con.send(user)
        if password is None:
            # no password (the live image): a shell prompt, or PAM asks anyway
            if self.con.expect(r"(Password: ?$)|([#$] ?$)", 60) is None:
                return f"no shell after logging in as {user}"
            self.con.send("")
        else:
            if self.con.expect(r"Password: ?", 60) is None:
                return f"no password prompt for {user}"
            self.con.send(password)
            # the prompt first: what is typed while login checks the password may be flushed
            if self.con.expect(r"[#$] ?$", 90) is None:
                return f"no shell after logging in as {user}"
        self.con.send("echo LOGIN-$((40+2))-$(id -un)")
        if self.con.expect(rf"LOGIN-42-{user}", 90) is None:
            return f"{user} could not log in"
        return None

    def poweroff(self, timeout=300):
        self.con.send("poweroff")
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            return f"no power off within {timeout}s"
        return None if self.proc.returncode == 0 else f"qemu exited with {self.proc.returncode}"

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        self.log.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--arch", default=os.uname().machine, choices=sorted(CONSOLE))
    ap.add_argument("--size", default="8G", help="size of the empty disk")
    ap.add_argument("--timeout", type=int, default=0, help="seconds until login: (default: 180 KVM, 1200 TCG)")
    ap.add_argument("--memory", type=int, default=2048, help="MiB")
    ap.add_argument("--keep", help="keep the installed disk in this directory")
    ap.add_argument("-q", "--quiet", action="store_true", help="do not echo the consoles")
    args = ap.parse_args()

    code, vars_ = find_firmware(args.arch)
    tmp = tempfile.mkdtemp(prefix="cleanlinux-install.")
    vars_copy, target = os.path.join(tmp, "vars.fd"), os.path.join(tmp, "target.img")
    shutil.copyfile(vars_, vars_copy)
    subprocess.run(["truncate", "-s", args.size, target], check=True)
    image = os.path.abspath(args.image)
    failures, t0 = [], time.monotonic()
    try:
        # 1. install from the image onto the empty disk
        cmd, kvm = qemu(args.arch, code, vars_copy, [(image, True), (target, False)], args.memory)
        timeout = args.timeout or (180 if kvm else 1200)
        run = Run(cmd, image + ".install.log", args.quiet)
        try:
            err = run.login("root", None, timeout)
            if err:
                failures.append("live system: " + err)
                return report(failures, t0)
            run.con.send(INSTALL.format(user=USER, host=HOST, console=CONSOLE[args.arch]))
            out = run.con.expect(r"LIVE-PKGS=\d+", 3600)
            if out is None:
                failures.append("the installer did not finish")
                return report(failures, t0)
            rc = re.search(r"INSTALL-RC=(\d+)", out)
            live_pkgs = re.search(r"LIVE-PKGS=(\d+)", out).group(1)
            if not rc or rc.group(1) != "0":
                failures.append(f"cleanlinux-install failed (exit {rc.group(1) if rc else '?'})")
                return report(failures, t0)
            print(f"\n--- installed after {time.monotonic() - t0:.0f}s", flush=True)
            err = run.poweroff()
            if err:
                failures.append("live system: " + err)
                return report(failures, t0)
            failures += ["live system: " + f for f in service_failures(run.con.buf)]
        finally:
            run.close()

        # 2. boot the new disk alone
        cmd, kvm = qemu(args.arch, code, vars_copy, [(target, False)], args.memory)
        run = Run(cmd, image + ".installed.log", args.quiet)
        try:
            err = run.login(USER, USER_PW, timeout)
            if err:
                failures.append("installed system: " + err)
                return report(failures, t0)
            run.con.send("exit")
            err = run.login("root", ROOT_PW, 120)
            if err:
                failures.append("installed system: " + err)
                return report(failures, t0)
            run.con.send(checks())
            out = run.con.expect(r"CHECKS-DONE", 600)
            if out is None:
                failures.append("the checks did not finish")
                return report(failures, t0)
            failures += [line.strip() for line in out.splitlines() if "CHECK-FAIL" in line]
            m = re.search(r"INSTALLED-PKGS=(\d+)", out)
            if not m or m.group(1) != live_pkgs:
                failures.append(f"packages: {m.group(1) if m else '?'} installed, {live_pkgs} on the live system")
            m = re.search(r"EFI-BOOT-ENTRIES=(\d+)", out)
            print(f"\n--- EFI boot entries: {m.group(1) if m else '?'}", flush=True)
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
    print("install test: " + ("FAILED" if failures else "ok"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
