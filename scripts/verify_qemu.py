#!/usr/bin/env python3
"""End-to-end QEMU verification script for Xu x86_64 Long Mode microkernel."""

import os
import re
import select
import subprocess
import sys
import time


class QemuSession:
    def __init__(self, kernel_path: str, disk_path: str, timeout: float = 15.0):
        self.timeout = timeout
        self.proc = subprocess.Popen(
            [
                "qemu-system-x86_64",
                "-m",
                "128M",
                "-cpu",
                "qemu64",
                "-smp",
                "2",
                "-kernel",
                kernel_path,
                "-drive",
                f"file={disk_path},if=none,format=raw,id=hd0",
                "-device",
                "virtio-blk-pci,drive=hd0,disable-modern=on",
                "-serial",
                "stdio",
                "-display",
                "none",
                "-no-reboot",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        self.buf = ""
        self.full_log = ""

    def read_until(self, marker: str, timeout: float | None = None) -> str:
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        fd = self.proc.stdout.fileno()
        while True:
            idx = self.buf.find(marker)
            if idx != -1:
                end = idx + len(marker)
                chunk = self.buf[:end]
                self.buf = self.buf[end:]
                return chunk

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"Timed out waiting for {marker!r}.\n--- Captured output ---\n{self.full_log}"
                )

            rlist, _, _ = select.select([fd], [], [], min(0.1, remaining))
            if rlist:
                data = os.read(fd, 4096)
                if not data:
                    raise EOFError(
                        f"QEMU exited early while waiting for {marker!r}.\n--- Captured output ---\n{self.full_log}"
                    )
                text = data.decode("utf-8", errors="replace").replace("\r\n", "\n")
                self.buf += text
                self.full_log += text

    def send_cmd(self, cmd: str) -> str:
        assert self.proc.stdin is not None
        self.proc.stdin.write((cmd + "\n").encode("ascii"))
        self.proc.stdin.flush()
        return self.read_until("xu-os> ")

    def send_poweroff(self) -> int:
        assert self.proc.stdin is not None
        self.proc.stdin.write(b"poweroff\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + self.timeout
        fd = self.proc.stdout.fileno()
        while time.monotonic() < deadline:
            rlist, _, _ = select.select([fd], [], [], 0.1)
            if rlist:
                data = os.read(fd, 4096)
                if data:
                    self.full_log += data.decode("utf-8", errors="replace").replace("\r\n", "\n")
            rc = self.proc.poll()
            if rc is not None:
                return rc
        self.proc.kill()
        raise TimeoutError(f"QEMU did not exit after poweroff.\n--- Captured output ---\n{self.full_log}")

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


def must_contain(text: str, needle: str, ctx: str):
    if needle not in text:
        raise AssertionError(f"[{ctx}] Expected {needle!r} in output:\n{text}")


def main() -> int:
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    build_dir = os.path.join(root_dir, "build")
    kernel = os.path.join(build_dir, "os.elf")
    hello_elf = os.path.join(build_dir, "hello.elf")
    fault_elf = os.path.join(build_dir, "fault.elf")
    linux_app = os.path.join(build_dir, "linux_app")
    macos_app = os.path.join(build_dir, "macos_app")
    desktop_linux = os.path.join(build_dir, "desktop_linux")
    desktop_macos = os.path.join(build_dir, "desktop_macos")
    font_ttf = os.path.join(root_dir, "assets", "font.ttf")
    disk = os.path.join(build_dir, "disk.img")
    mkdisk = os.path.join(root_dir, "scripts", "mkdisk.py")
    for p in (kernel, hello_elf, fault_elf, linux_app, macos_app, desktop_linux, desktop_macos, font_ttf):
        if not os.path.exists(p):
            print(f"Required build artifact not found: {p}", file=sys.stderr)
            return 1

    subprocess.check_call(
        [
            sys.executable,
            mkdisk,
            disk,
            f"/bin/hello.elf={hello_elf}",
            f"/bin/fault.elf={fault_elf}",
            f"/bin/linux_app={linux_app}",
            f"/bin/macos_app={macos_app}",
            f"/bin/desktop_linux={desktop_linux}",
            f"/bin/desktop_macos={desktop_macos}",
            f"/etc/font.ttf={font_ttf}",
        ]
    )

    sess = QemuSession(kernel, disk, timeout=45.0)
    try:
        boot_out = sess.read_until("xu-os> ")
        must_contain(boot_out, "Xu OS Test Kernel (x86_64 Long Mode, Freestanding)", "boot")
        must_contain(boot_out, "[BOOT] IDT (48 vectors), PIC 8259A, PIT 100 Hz initialized.", "boot")
        must_contain(boot_out, "[BOOT] PMM bitmap frame allocator initialized", "boot")
        must_contain(boot_out, "[BOOT] VMM 4-level paging active, CR3=0x", "boot")
        must_contain(boot_out, "[BOOT] GDT/TSS (64-bit) & SYSCALL/SYSRET MSRs configured.", "boot")
        must_contain(boot_out, "[BOOT] Framebuffer 1280x800x32 (Bochs VBE) & PS/2 input ready.", "boot")
        must_contain(boot_out, "[BOOT] VirtIO-Blk PCI driver ready (32768 sectors).", "boot")
        must_contain(boot_out, "[BOOT] XuFS mounted on VirtIO-Blk (8 files).", "boot")
        must_contain(boot_out, "[BOOT] Cooperative #core/task.switch_context test PASSED.", "boot")
        must_contain(boot_out, "[BOOT] Enabling interrupts and starting preemptive scheduler...", "boot")

        out_help = sess.send_cmd("help")
        must_contain(out_help, "Available commands:", "help")
        must_contain(out_help, "Show CPU, BootInfo, CR3, and IRQ stats", "help")
        must_contain(out_help, "elftest", "help")
        must_contain(out_help, "pftest", "help")
        must_contain(out_help, "linuxtest", "help")
        must_contain(out_help, "mactest", "help")
        must_contain(out_help, "uitest", "help")

        out_self = sess.send_cmd("selftest")
        must_contain(out_self, "[PASS] 18/18", "selftest")
        must_contain(out_self, "[SELFTEST] ALL 18 CHECKS PASSED", "selftest")

        out_info = sess.send_cmd("info")
        must_contain(out_info, "CPU Vendor     :", "info")
        must_contain(out_info, "NXE=1", "info")
        must_contain(out_info, "CR3            : 0x", "info")
        must_contain(out_info, "PIT Ticks      :", "info")

        out_mem = sess.send_cmd("mem")
        must_contain(out_mem, "[PMM]", "mem")
        must_contain(out_mem, "[VMM]", "mem")
        must_contain(out_mem, "[HEAP]", "mem")

        out_ps1 = sess.send_cmd("ps")
        must_contain(out_ps1, "shell", "ps1")
        must_contain(out_ps1, "idle", "ps1")
        must_contain(out_ps1, "worker_a", "ps1")
        must_contain(out_ps1, "worker_b", "ps1")

        out_vm = sess.send_cmd("vmtest")
        must_contain(out_vm, "[VMM] PASS", "vmtest")

        out_heap = sess.send_cmd("heaptest")
        must_contain(out_heap, "[HEAP] PASS", "heaptest")

        out_user = sess.send_cmd("usertest")
        must_contain(out_user, "[RING3] Hello from CPL=3 via syscall/sysret!", "usertest")
        must_contain(out_user, "[USER] Ring3 exit=42 syscalls=4 rejected_kptr=1", "usertest")
        must_contain(out_user, "[USER] PASS", "usertest")

        out_blk = sess.send_cmd("blktest")
        must_contain(out_blk, "[BLK] VirtIO-PCI DMA RW OK sectors=32768 (16384 KiB)", "blktest")
        must_contain(out_blk, "[BLK] PASS", "blktest")

        out_ls = sess.send_cmd("ls")
        must_contain(out_ls, "/etc/motd", "ls")
        must_contain(out_ls, "/bin/hello.elf", "ls")
        must_contain(out_ls, "/bin/fault.elf", "ls")
        must_contain(out_ls, "/bin/linux_app", "ls")
        must_contain(out_ls, "/bin/macos_app", "ls")
        must_contain(out_ls, "/bin/desktop_linux", "ls")
        must_contain(out_ls, "/bin/desktop_macos", "ls")
        must_contain(out_ls, "/tmp/persist.txt", "ls")

        out_cat = sess.send_cmd("cat")
        must_contain(out_cat, "Welcome to Xu OS (XuFS on VirtIO-Blk)!", "cat")

        out_fs = sess.send_cmd("fstest")
        must_contain(out_fs, "[FS] PASS", "fstest")

        out_elf = sess.send_cmd("elftest")
        must_contain(out_elf, "[RING3-XU] Hello from pure-Xu ELF! data=4661 motd_bytes=39", "elftest")
        must_contain(out_elf, "[ELF] Pure-Xu Ring3 ELF64 W^X+NX OK exit=42", "elftest")
        must_contain(out_elf, "[ELF] PASS", "elftest")

        out_pf = sess.send_cmd("pftest")
        must_contain(out_pf, "[RING3-FAULT] Triggering intentional #PF on kernel addr...", "pftest")
        must_contain(out_pf, "[USER EXCEPTION] Contained Ring3 fault vec=14", "pftest")
        must_contain(out_pf, "[PF] Demand paging + Ring3 #PF containment OK", "pftest")
        must_contain(out_pf, "[PF] PASS", "pftest")

        out_lnx = sess.send_cmd("linuxtest")
        must_contain(out_lnx, "[GUEST-LINUX]", "linuxtest")
        must_contain(out_lnx, "[LINUX-APP] Unmodified Linux x86_64 ELF64 OK", "linuxtest")
        must_contain(out_lnx, "[LINUX] PASS", "linuxtest")

        out_mac = sess.send_cmd("mactest")
        must_contain(out_mac, "[GUEST-MACOS]", "mactest")
        must_contain(out_mac, "[MACOS-APP] Unmodified macOS x86_64 Mach-O OK", "mactest")
        must_contain(out_mac, "[MACOS] PASS", "mactest")

        out_ui = sess.send_cmd("uitest")
        must_contain(out_ui, "[UI-DESKTOP] ABI=linux", "uitest")
        must_contain(out_ui, "[UI-DESKTOP] ABI=macos", "uitest")
        must_contain(out_ui, "[UI-WIDGETS] Ring3 #ui/widgets Desktop (Linux ELF64 + macOS Mach-O) OK", "uitest")
        must_contain(out_ui, "[UI] PASS", "uitest")

        out_sub = sess.send_cmd("subtest")
        must_contain(out_sub, "[SUBSTRATE] extern_static+@weak+@naked+@interrupt+asm_ops+atomics+lapic_ver=", "subtest")
        must_contain(out_sub, "[SUBSTRATE] PASS", "subtest")

        out_smp = sess.send_cmd("smptest")
        must_contain(out_smp, "[SMP] ACPI MADT cpus=", "smptest")
        must_contain(out_smp, "lock=40000", "smptest")
        must_contain(out_smp, "ipi_cpu=1", "smptest")
        must_contain(out_smp, "lapic_timer=", "smptest")
        must_contain(out_smp, "[SMP] PASS", "smptest")

        out_lspci = sess.send_cmd("lspci")
        must_contain(out_lspci, "[PCI] Bus 0 devices", "lspci")
        must_contain(out_lspci, "vendor=0x1af4 device=0x1001", "lspci")

        out_pci = sess.send_cmd("pcitest")
        must_contain(out_pci, "virtio_blk=0x1af4:0x1001", "pcitest")
        must_contain(out_pci, "[PCI] PASS", "pcitest")

        out_spawn = sess.send_cmd("spawn")
        must_contain(out_spawn, "[SCHED] Spawned dyn_worker tid=", "spawn")

        time.sleep(0.25)
        out_ps2 = sess.send_cmd("ps")
        must_contain(out_ps2, "dyn_worker", "ps2")
        m_dyn = re.search(r"dyn_worker=(\d+)", out_ps2)
        if not m_dyn or int(m_dyn.group(1)) <= 0:
            raise AssertionError(f"[ps2] Expected dyn_worker > 0, got:\n{out_ps2}")

        out_up1 = sess.send_cmd("uptime")
        m1 = re.search(r"PIT Ticks\s*:\s*(\d+)", out_info)
        m2 = re.search(r"Ticks=(\d+)", out_up1)
        if not m1 or not m2 or int(m2.group(1)) <= int(m1.group(1)):
            raise AssertionError(f"[uptime] Expected ticks to advance: {m1} -> {m2}")

        rc = sess.send_poweroff()
        if rc != 0:
            raise AssertionError(f"[poweroff] Expected QEMU exit code 0, got {rc}")

        with open(disk, "rb") as f:
            disk_after = f.read()
        if disk_after[512:536] != b"XU-OS-VIRTIO-BLK-DMA-OK!":
            raise AssertionError(f"[disk] Expected VirtIO-Blk DMA write persisted at sector 1, got {disk_after[512:540]!r}")

        persisted = subprocess.check_output([sys.executable, mkdisk, "--read", disk, "/tmp/persist.txt"])
        if persisted != b"XUFS-PERSIST-OK":
            raise AssertionError(f"[xufs] Expected /tmp/persist.txt == b'XUFS-PERSIST-OK', got {persisted!r}")

        print(sess.full_log)
        print("VERIFICATION PASSED: All 18 kernel subsystems (incl. Dual-Core SMP, #core/pci, LAPIC Timer/IPI, Pure-Xu Ring 3 ELF64, and @interrupt) verified in QEMU!")
        return 0
    finally:
        sess.close()


if __name__ == "__main__":
    sys.exit(main())
