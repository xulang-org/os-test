# Xu OS Test Kernel (`os-test`)

A freestanding x86_64 Long Mode microkernel written in **Xu (`--profile=freestanding --target=x64-none`)**, featuring 15 verified subsystems, Dual-ABI Ring 3 execution (unmodified Linux x86_64 ELF64 + macOS x86_64 Mach-O 64-bit), a `1280×800` `#ui/widgets` Ring 3 graphical desktop, and QEMU `vmmouse` pointer integration.

## Features & Architecture

- **Boot & Trap Trampoline (`arch/x86_64/boot.S`, `linker.ld`)**:
  - Multiboot1 header -> 32-bit protected mode -> 64-bit Long Mode (`CR3`, `PAE`, `EFER.LME`, `GDT64`, SSE2), plus Bochs VBE (`1280×800×32` linear framebuffer) and QEMU `vmmouse` VMware backdoor helpers.
  - Directly linked via `x86_64-elf-ld` with Xu's freestanding relocatable ELF64 object (`xu build --emit-obj ... -o build/kernel_xu.o`) across `W^X` `PT_LOAD` segments (`R E`, `R  `, `RW `).
  - 48-vector exception/IRQ trampoline matching `#core/task.TrapFrame` (176 bytes), dispatching to `@export("xu_trap_handler")` and switching `RSP` on preemption before `iretq`.

- **Kernel Subsystems (`--profile=freestanding --target=x64-none`)**:
  - `main.xu`: Kernel entry, boot command-line dispatch (`-append ui` launches the graphical desktop directly), and `@panic_handler` freestanding panic hook.
  - `serial.xu`: COM1 (`0x3F8`) 16550 UART driver with IRQ4 RX ring buffer and `IrqSpinlock` protection.
  - `idt.xu`: 48-vector IDT (`#core/arch.IdtEntry`), 8259A PIC remap (`32..47`), 8254 PIT 100 Hz timer, kernel & user `#PF` demand paging dispatch, Ring 3 exception containment, and PS/2 keyboard (`IRQ1`) + mouse (`IRQ12`) IRQ handlers.
  - `pmm.xu`: 4 KiB physical frame bitmap allocator (`0x00800000..128 MiB`) with `#core/sync.IrqSpinlock` RAII guards.
  - `vmm.xu`: 4-level x86_64 paging (`IA32_EFER.NXE` `W^X`/NX enforcement, per-process isolated `user_pml4` create/destroy, `CR3` switch, 2 MiB identity pages + 4 KiB dynamic page tables, `invlpg`, demand `#PF` mapping).
  - `heap.xu`: First-fit kernel heap (`kmalloc`/`kfree`) with 16-byte aligned payloads and bidirectional block coalescing.
  - `sched.xu`: Preemptive round-robin scheduler (50 ms quantum, sleep/wake queue, dynamic task spawn/exit) + cooperative `#core/task.switch_context`.
  - `user.xu`, `userprog/*.xu`: 64-bit GDT/TSS, `SYSCALL`/`SYSRET` MSRs (`swapgs`), `#core/elf` ELF64 loader + Mach-O 64-bit loader with strict `W^X` + `NX` + per-process `CR3` isolation, Dual-ABI syscall translation (Linux x86_64 ELF64 + macOS x86_64 Mach-O), coalescing Ring 3 `mmap` arena with demand paging, VFD virtual files (`/dev/fb0`, `/dev/vmmouse`, `/etc/font.ttf`, `/proc/xufs`, `/proc/app_out`, `/proc/cmd`), and nested Ring 3 child execution (`user_exec_subapp`).
  - `blk.xu`, `fs.xu`: Real `#core/virtio.VirtioPciBlkDriver` + persistent `XuFS` filesystem on VirtIO-Blk (`build/disk.img`).
  - `fb.xu`, `font.xu`, `input.xu`, `gui.xu`: `1280×800×32` diff-only double-buffered framebuffer with cursor overlay, QEMU `vmmouse` 1:1 absolute pointer, lossless PS/2 draining, and interactive `1280×800` kernel shell desktop.
  - `shell.xu`: Interactive UART shell (`help`, `info`, `mem`, `ps`, `uptime`, `vmtest`, `heaptest`, `usertest`, `blktest`, `ls`, `cat`, `fstest`, `elftest`, `pftest`, `spawn`, `gui`, `ui`, `selftest`, `poweroff`).

- **Ring 3 `#ui/widgets` Graphical Desktop (`userprog/desktop/`)**:
  - Compiled as both unmodified Linux ELF64 (`/bin/desktop_linux`) and macOS Mach-O (`/bin/desktop_macos`) targets from the exact same `#ui/widgets` source (`main.xu`, `xdf_sw.xu`).
  - Uses `widgets.hostless_screen(1280.0, 800.0)` and `xdf_sw.xu` (a 4×AA XDF1 software rasterizer with TrueType Lato `/etc/font.ttf` glyph atlas caching) to render System Overview, XuFS Explorer (with nested Ring 3 `/bin/linux_app` & `/bin/macos_app` execution + `/proc/app_out` output capture), and interactive Widget Showcase controls.

## Prerequisites

- Xu toolchain (`XU` defaults to `../xu-dev/bin/xu` when present, otherwise `xu` from `PATH`)
- `x86_64-elf-as`, `x86_64-elf-ld`, `x86_64-elf-objcopy`
- `qemu-system-x86_64`
- `python3`

## Build, Run & Verify

```bash
# Type-check kernel + Ring 3 #ui/widgets desktop
make check

# Build kernel (build/os.elf) + VirtIO disk image (build/disk.img)
make

# Run automated 15-check kernel + Dual-ABI Linux/macOS + #ui/widgets smoke suite
make verify

# Launch interactive 1280x800 QEMU Cocoa GUI (boots straight into Ring 3 desktop)
make gui

# Launch headless UART shell in QEMU
make qemu
```

## Assets & License

- `assets/font.ttf`: **Lato Regular** by Łukasz Dziedzic, licensed under the **SIL Open Font License 1.1** (see `assets/FONT_LICENSE.txt`).
