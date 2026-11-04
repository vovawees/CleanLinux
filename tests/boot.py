#!/usr/bin/env python3
"""Boot a CleanLinux disk image in QEMU (UEFI) and check the booted system.

usage: tests/boot.py IMAGE [--arch x86_64|aarch64] [--timeout SECONDS] [--log FILE]
                           [--memory MIB] [--no-login] [--exec COMMAND]...

The image (bootstrap.sh disk) boots through the UEFI firmware (OVMF/AAVMF) and systemd-boot.
The test waits for "login:" on the serial console, logs in as root (a fresh image has no root
password), checks the services, mounts, devices and burn, runs the --exec commands, then powers
off: QEMU has to exit by itself, and a service that fails to start or to stop fails the test.
The image is not modified (QEMU snapshot mode).
KVM is used when /dev/kvm is usable, TCG otherwise (slow: minutes).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

FIRMWARE = {
    "x86_64": [
        ("/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd"),  # Fedora
        ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),  # Debian, Ubuntu
        ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
        ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.4m.fd"),  # Arch
        ("/usr/share/qemu/ovmf-x86_64-code.bin", "/usr/share/qemu/ovmf-x86_64-vars.bin"),  # openSUSE
    ],
    "aarch64": [
        ("/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd"),  # Debian, Ubuntu
        ("/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw", "/usr/share/edk2/aarch64/vars-template-pflash.raw"),
        ("/usr/share/edk2/aarch64/QEMU_CODE.fd", "/usr/share/edk2/aarch64/QEMU_VARS.fd"),  # Arch
    ],
}

# run on the booted system as root, one line; FAIL lines are collected, DONE ends it. The
# markers are built by the shell, so the echo of the typed line never matches them.
CHECKS = r"""F=FAIL D=DONE; c() { "$@" >/dev/null 2>&1 || echo "CHECK-$F: $*"; };
cat /proc/cmdline; findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS;
c sh -c 'findmnt -no FSTYPE / | grep -qx btrfs'; c sh -c 'findmnt -no OPTIONS / | grep -q "subvol=/@"';
c sh -c 'findmnt -no OPTIONS / | grep -qw rw';
c sh -c 'findmnt -no FSTYPE /home | grep -qx btrfs'; c sh -c 'findmnt -no FSTYPE /.snapshots | grep -qx btrfs';
c sh -c 'findmnt -no FSTYPE /boot | grep -qx vfat'; c test -f /boot/loader/loader.conf;
c sh -c 'ls /dev/disk/by-partuuid | grep -q .'; c test -s /etc/machine-id; c test -s /etc/udev/hwdb.bin;
c grep -qx cleanlinux /proc/sys/kernel/hostname;
for s in early-udevd early-root-rw early-fstab early-seed early-tmpfiles early-clock system login; do
c dinitctl is-started $s; done; dinitctl list;
c burn --version; c burn doctor; burn list | wc -l; uname -a;
echo "CHECKS-$D"
"""


def find_firmware(arch):
    for code, vars_ in FIRMWARE[arch]:
        if os.path.exists(code) and os.path.exists(vars_):
            return code, vars_
    sys.exit(f"no UEFI firmware for {arch} found (install ovmf / edk2-ovmf / qemu-efi-aarch64)")


def nic_args(qemu_bin):
    """user networking (QEMU's DHCP and NAT) when this QEMU has it, else a NIC on an empty hub"""
    try:
        out = subprocess.run([qemu_bin, "-netdev", "help"], capture_output=True, text=True).stdout
    except OSError:
        out = ""
    if re.search(r"^user$", out, re.M):
        return ["-nic", "user,model=virtio-net-pci"]
    return ["-netdev", "hubport,id=net0,hubid=0", "-device", "virtio-net-pci,netdev=net0"]


def qemu_command(arch, image, code, vars_copy, memory):
    kvm = os.access("/dev/kvm", os.R_OK | os.W_OK) and arch == os.uname().machine
    if arch == "x86_64":
        cmd = ["qemu-system-x86_64", "-machine", "q35"]
    else:
        cmd = ["qemu-system-aarch64", "-machine", "virt"]
    cmd += ["-accel", "kvm", "-cpu", "host"] if kvm else ["-accel", "tcg", "-cpu", "max"]
    cmd += [
        "-m", str(memory), "-smp", "2", "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-no-reboot",
        "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,unit=1,file={vars_copy}",
        "-drive", f"file={image},format=raw,if=virtio,snapshot=on",
        "-device", "virtio-rng-pci",
    ]
    cmd += nic_args(cmd[0])
    return cmd, kvm


class Console:
    """The serial console of QEMU: everything it prints goes to the log and a buffer."""

    def __init__(self, proc, log, echo):
        self.proc, self.log, self.echo = proc, log, echo
        self.buf, self.pos = "", 0
        self.lock = threading.Condition()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            data = self.proc.stdout.read1(4096)
            if not data:
                break
            text = data.decode("utf-8", "replace")
            self.log.write(text)
            self.log.flush()
            if self.echo:
                sys.stdout.write(text)
                sys.stdout.flush()
            with self.lock:
                self.buf += text
                self.lock.notify_all()
        with self.lock:
            self.lock.notify_all()

    def expect(self, pattern, timeout):
        """wait for PATTERN after the last match; returns the text up to the end of the match"""
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

    def send(self, line):
        self.proc.stdin.write(line.encode() + b"\r")
        self.proc.stdin.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--arch", default=os.uname().machine, choices=sorted(FIRMWARE))
    ap.add_argument("--timeout", type=int, default=0, help="seconds until login: (default: 120 KVM, 900 TCG)")
    ap.add_argument("--memory", type=int, default=2048, help="MiB")
    ap.add_argument("--log", help="serial console log (default: IMAGE.boot.log)")
    ap.add_argument("--no-login", action="store_true", help="stop at the login prompt")
    ap.add_argument("-q", "--quiet", action="store_true", help="do not echo the console")
    ap.add_argument("--exec", action="append", default=[], metavar="COMMAND",
                    help="a shell command to run as root after the checks (repeatable)")
    args = ap.parse_args()

    code, vars_ = find_firmware(args.arch)
    tmp = tempfile.mkdtemp(prefix="cleanlinux-boot.")
    vars_copy = os.path.join(tmp, "vars.fd")
    shutil.copyfile(vars_, vars_copy)
    cmd, kvm = qemu_command(args.arch, os.path.abspath(args.image), code, vars_copy, args.memory)
    timeout = args.timeout or (120 if kvm else 900)
    log_path = args.log or args.image + ".boot.log"
    print(f"boot: {' '.join(cmd)}", flush=True)
    t0 = time.monotonic()
    failures = []
    with open(log_path, "w", encoding="utf-8") as log:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        con = Console(proc, log, not args.quiet)
        try:
            if con.expect(r"login: ?$|login: ", timeout) is None:
                failures.append(f"no login prompt within {timeout}s")
                return report(failures, log_path, t0)
            print(f"\n--- login prompt after {time.monotonic() - t0:.0f}s", flush=True)
            if args.no_login:
                return report(failures, log_path, t0)
            con.send("root")
            if con.expect(r"(Password: ?$)|(# ?$)", 60) is None:
                failures.append("no shell after logging in as root")
                return report(failures, log_path, t0)
            con.send("")
            con.send("echo SHELL-$((40+2))")
            if con.expect(r"SHELL-42", 60) is None:
                failures.append("the root shell does not answer")
                return report(failures, log_path, t0)
            con.send(" ".join(CHECKS.split("\n")).strip())
            out = con.expect(r"CHECKS-DONE", 300)
            if out is None:
                failures.append("the checks did not finish")
                return report(failures, log_path, t0)
            failures += [line.strip() for line in out.splitlines() if "CHECK-FAIL" in line]
            for n, command in enumerate(args.exec):
                con.send(f"{command}; echo EXEC-$((0+{n}))-$?")
                m = con.expect(rf"EXEC-{n}-\d+", 600)
                if m is None:
                    failures.append(f"--exec did not finish: {command}")
                    return report(failures, log_path, t0)
                rc = m.rsplit("-", 1)[1]
                if rc != "0":
                    failures.append(f"--exec exited with {rc}: {command}")
            con.send("poweroff")
            try:
                proc.wait(180)
            except subprocess.TimeoutExpired:
                failures.append("no power off within 180s")
            else:
                if proc.returncode != 0:
                    failures.append(f"qemu exited with {proc.returncode}")
            failures += service_failures(con.buf)
            return report(failures, log_path, t0)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            shutil.rmtree(tmp, ignore_errors=True)


def service_failures(text):
    """dinit's messages about services that failed to start or to stop"""
    rx = re.compile(r"\[FAILED\][^\r\n]*|dinit: Service [^\r\n]*(?:failed|exited|terminated)[^\r\n]*")
    return sorted(set(m.group(0).strip() for m in rx.finditer(text)))


def report(failures, log_path, t0):
    print(f"\n--- {time.monotonic() - t0:.0f}s, console log: {log_path}")
    for f in failures:
        print(f"FAIL: {f}")
    print("boot test: " + ("FAILED" if failures else "ok"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
