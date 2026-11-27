/* Multiboot1 + 64-bit Long Mode + 48-vector ISR trampoline for Xu OS. */

.set MB_MAGIC,    0x1BADB002
.set MB_FLAGS,    0x00000003
.set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

.section .multiboot, "a"
.align 4
multiboot_header:
    .long MB_MAGIC
    .long MB_FLAGS
    .long MB_CHECKSUM

.section .text.boot, "ax"
.code32
.globl _boot32
_boot32:
    cli

    /* Save Multiboot1 magic (EAX) and info pointer (EBX) before clearing tables. */
    mov %eax, saved_mb_magic
    mov %ebx, saved_mb_info

    /* Zero boot PML4, PDPT, PD (3 * 4096 bytes = 3072 dwords). */
    mov $boot_pml4, %edi
    xor %eax, %eax
    mov $3072, %ecx
    rep stosl

    /* PML4[0] -> boot_pdpt | Present | Writable */
    mov $boot_pdpt, %eax
    or  $0x03, %eax
    mov %eax, boot_pml4

    /* PDPT[0] -> boot_pd | Present | Writable */
    mov $boot_pd, %eax
    or  $0x03, %eax
    mov %eax, boot_pdpt

    /* Identity-map first 1 GiB using 512 x 2 MiB huge pages (Present | Writable | Huge). */
    mov $0, %ecx
    mov $0x83, %eax
.Lmap_pd:
    mov %eax, boot_pd(,%ecx,8)
    movl $0, boot_pd+4(,%ecx,8)
    add $0x200000, %eax
    inc %ecx
    cmp $512, %ecx
    jl .Lmap_pd

    /* Load CR3 with boot PML4. */
    mov $boot_pml4, %eax
    mov %eax, %cr3

    /* Enable PAE (CR4.PAE = 1 << 5). */
    mov %cr4, %eax
    or  $(1 << 5), %eax
    mov %eax, %cr4

    /* Enable Long Mode in IA32_EFER (MSR 0xC0000080, bit 8 = LME). */
    mov $0xC0000080, %ecx
    rdmsr
    or  $(1 << 8), %eax
    wrmsr

    /* Enable Paging + Protection (CR0.PG | CR0.PE). */
    mov %cr0, %eax
    or  $0x80000001, %eax
    mov %eax, %cr0

    /* Load 64-bit GDT and far jump to 64-bit code segment (0x08). */
    lgdt gdt64_ptr
    ljmp $0x08, $_boot64

.code64
_boot64:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    lea _boot_stack_top(%rip), %rsp

    /* Enable SSE/SSE2 (required by Xu switch_context xmm8..xmm15 movsd). */
    mov %cr0, %rax
    and $~(1 << 2), %rax           /* clear CR0.EM */
    or  $(1 << 1), %rax            /* set CR0.MP */
    mov %rax, %cr0

    mov %cr4, %rax
    or  $((1 << 9) | (1 << 10)), %rax /* CR4.OSFXSR | CR4.OSXMMEXCPT */
    mov %rax, %cr4

    /* Extract mem_upper_kb from Multiboot1 info if valid. */
    mov $130048, %rcx              /* fallback: 127 MiB upper (128 MiB total) */
    movq $0, os_boot_auto_ui(%rip)
    mov saved_mb_magic(%rip), %eax
    cmp $0x2BADB002, %eax
    jne .Lmb_done
    mov saved_mb_info(%rip), %edi
    test %rdi, %rdi
    jz .Lmb_done
    mov (%rdi), %edx               /* mb_info->flags */
    test $1, %edx
    jz .Lmb_chk_ui
    mov 8(%rdi), %ecx              /* mb_info->mem_upper (in KiB) */
.Lmb_chk_ui:
    test $4, %edx
    jz .Lmb_done
    mov 16(%rdi), %esi
    test %rsi, %rsi
    jz .Lmb_done
    mov $0x20, %al                 /* previous char (' ' = token start boundary) */
.Lcmd_scan:
    mov (%rsi), %ah
    test %ah, %ah
    jz .Lmb_done
    cmp $0x20, %al
    jne .Lcmd_next
    cmp $0x75, %ah                 /* 'u' */
    jne .Lcmd_next
    cmpb $0x69, 1(%rsi)            /* 'i' */
    jne .Lcmd_next
    movb 2(%rsi), %dl
    test %dl, %dl
    jz .Lcmd_found_ui
    cmp $0x20, %dl
    jne .Lcmd_next
.Lcmd_found_ui:
    movq $1, os_boot_auto_ui(%rip)
    jmp .Lmb_done
.Lcmd_next:
    mov %ah, %al
    inc %rsi
    jmp .Lcmd_scan
.Lmb_done:

    /* Populate BootInfo directly in linked .bss.boot symbol os_boot_info. */
    lea os_boot_info(%rip), %rdi
    movabs $0x58554F53, %rax       /* "XUOS" magic */
    mov %rax, 0(%rdi)
    mov saved_mb_magic(%rip), %eax
    mov %rax, 8(%rdi)              /* mb_magic */
    mov %rcx, 16(%rdi)             /* mem_upper_kb */
    lea isr_stub_table(%rip), %rax
    mov %rax, 24(%rdi)             /* isr_table_addr */
    lea xu_trap_handler(%rip), %rax
    mov %rax, 32(%rdi)             /* trap_handler_slot */
    lea __xu_start(%rip), %rax
    mov %rax, 40(%rdi)             /* xu_kernel_entry */
    lea _kernel_end(%rip), %rdx
    mov %rdx, 48(%rdi)             /* xu_kernel_end */
    lea boot_pml4(%rip), %rdx
    mov %rdx, 56(%rdi)             /* boot_pml4 */

    /* Jump into Xu freestanding kernel entry (__xu_start -> _xu_main). */
    and $-16, %rsp
    call __xu_start

.Lhang:
    cli
    hlt
    jmp .Lhang

/* ===== 48-vector Interrupt & Exception Trampoline ===== */
.macro ISR_NOERR vec
.align 8
isr_stub_\vec:
    pushq $0
    pushq $\vec
    jmp isr_common
.endm

.macro ISR_ERR vec
.align 8
isr_stub_\vec:
    pushq $\vec
    jmp isr_common
.endm

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

/* Hardware IRQs 0..15 mapped to IDT vectors 32..47 */
ISR_NOERR 32
ISR_NOERR 33
ISR_NOERR 34
ISR_NOERR 35
ISR_NOERR 36
ISR_NOERR 37
ISR_NOERR 38
ISR_NOERR 39
ISR_NOERR 40
ISR_NOERR 41
ISR_NOERR 42
ISR_NOERR 43
ISR_NOERR 44
ISR_NOERR 45
ISR_NOERR 46
ISR_NOERR 47

/* Matches #core/task.TrapFrame (176 bytes): r15..rax, vec, error_code, rip, cs, rflags, rsp, ss */
isr_common:
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    mov %rsp, %rdi
    mov %rsp, %rbx
    and $-16, %rsp
    cld

    call xu_trap_handler
    test %rax, %rax
    cmovz %rbx, %rax
    mov %rax, %rsp

.Lrestore_regs:
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
    addq $16, %rsp
    iretq

/* u64 enter_ring3(u64 entry_rip, u64 user_rsp, u64 cpu_local, u64 user_pml4) */
.globl enter_ring3
enter_ring3:
    movq %rsp, 16(%rdx)
    movq %rbp, 24(%rdx)
    movq %rbx, 32(%rdx)
    movq %r12, 40(%rdx)
    movq %r13, 48(%rdx)
    movq %r14, 56(%rdx)
    movq %r15, 64(%rdx)

    cli
    movq %cr3, %rax
    movq %rax, 96(%rdx)
    movq %rcx, %cr3

    movw $0x1B, %ax
    movw %ax, %ds
    movw %ax, %es

    pushq $0x1B         /* SS  (User Data, RPL=3) */
    pushq %rsi          /* RSP (User stack top) */
    pushq $0x202        /* RFLAGS (IF=1, reserved bit 1) */
    pushq $0x23         /* CS  (User Code64, RPL=3) */
    pushq %rdi          /* RIP (User entry) */

    xorq %rax, %rax
    xorq %rbx, %rbx
    xorq %rcx, %rcx
    xorq %rbp, %rbp
    xorq %r8, %r8
    xorq %r9, %r9
    xorq %r10, %r10
    xorq %r11, %r11
    xorq %r12, %r12
    xorq %r13, %r13
    xorq %r14, %r14
    xorq %r15, %r15
    movq 128(%rdx), %rdi    /* CpuLocal.init_rdi */
    movq 136(%rdx), %rsi    /* CpuLocal.init_rsi */
    movq 144(%rdx), %rdx    /* CpuLocal.init_rdx (load last!) */
    iretq

/* MSR_IA32_LSTAR target (IF=0, DF=0 via FMASK=0x600; rcx=user_rip, r11=user_rflags) */
.globl syscall_entry_asm
syscall_entry_asm:
    swapgs
    movq %rsp, %gs:8
    movq %gs:0, %rsp

    /* Push 10 qwords (80 bytes) -> keeps 16-byte stack alignment for call */
    pushq %gs:8         /* user RSP */
    pushq %rcx          /* user RIP */
    pushq %r11          /* user RFLAGS */
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushq %rax          /* saved syscall nr */

    /* SysV C ABI: xu_syscall_dispatch(nr=rdi, a0=rsi, a1=rdx, a2=rcx, a3=r8, a4=r9) */
    movq %r8,  %r9
    movq %r10, %r8
    movq %rdx, %rcx
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq %rax, %rdi
    call xu_syscall_dispatch

    movq (%rsp), %rcx
    cmpq $60, %rcx          /* Linux SYS_EXIT */
    je .Lsys_exit
    cmpq $231, %rcx         /* Linux SYS_EXIT_GROUP */
    je .Lsys_exit
    cmpq $0x2000001, %rcx   /* macOS Darwin SYS_EXIT */
    je .Lsys_exit

    cmpq $0x2000000, %rcx
    jb .Lsys_ret_linux
    /* macOS Darwin BSD syscall: CF=0 on success, CF=1 & rax=errno on -4095..-1 */
    andq $-2, 56(%rsp)
    cmpq $-4095, %rax
    jb .Ldarwin_ok
    negq %rax
    orq $1, 56(%rsp)
.Ldarwin_ok:
    xorq %rdx, %rdx
.Lsys_ret_linux:

    addq $8, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    popq %r11
    popq %rcx
    popq %rsp
    swapgs
    sysretq

.Lsys_exit:
    movq %gs:96, %rdx
    movq %rdx, %cr3
    movq %gs:24, %rbp
    movq %gs:32, %rbx
    movq %gs:40, %r12
    movq %gs:48, %r13
    movq %gs:56, %r14
    movq %gs:64, %r15
    movq %gs:16, %rsp
    movw $0x10, %cx
    movw %cx, %ds
    movw %cx, %es
    swapgs
    sti
    ret

/* Ring 0 return target from isr_common after catching a Ring 3 fault (rdi=cpu_local, rax=exit_code) */
.globl user_fault_return_asm
user_fault_return_asm:
    movq 96(%rdi), %rdx
    movq %rdx, %cr3
    movw $0x10, %cx
    movw %cx, %ds
    movw %cx, %es
    movq 24(%rdi), %rbp
    movq 32(%rdi), %rbx
    movq 40(%rdi), %r12
    movq 48(%rdi), %r13
    movq 56(%rdi), %r14
    movq 64(%rdi), %r15
    movq 16(%rdi), %rsp
    sti
    ret

.globl vmmouse_cmd_asm
/* void vmmouse_cmd_asm(u32 cmd, u32 arg, u32 *out_eax, u32 *out_ebx, u32 *out_ecx, u32 *out_edx) */
vmmouse_cmd_asm:
    pushq %rbx
    pushq %r12
    pushq %r13
    movq %rdx, %r10
    movq %rcx, %r11
    movq %r8,  %r12
    movq %r9,  %r13
    movl $0x564D5868, %eax
    movl %esi, %ebx
    movl %edi, %ecx
    movl $0x5658, %edx
    inl  %dx, %eax
    movl %eax, (%r10)
    movl %ebx, (%r11)
    movl %ecx, (%r12)
    movl %edx, (%r13)
    popq %r13
    popq %r12
    popq %rbx
    ret

/* ===== Relocatable 16->32->64-bit AP Startup Trampoline (copied to 0x8000) ===== */
.code16
.globl ap_trampoline_start
.globl ap_trampoline_end
.align 16
ap_trampoline_start:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    lgdt (0x8000 + (ap_gdt_ptr - ap_trampoline_start))
    movl %cr0, %eax
    orl  $1, %eax
    movl %eax, %cr0
    ljmpl $0x18, $(0x8000 + (ap_pm32 - ap_trampoline_start))

.code32
ap_pm32:
    movw $0x20, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs

    movl 0x8F00, %eax
    movl %eax, %cr3

    movl %cr4, %eax
    orl  $(1 << 5), %eax
    movl %eax, %cr4

    movl $0xC0000080, %ecx
    rdmsr
    orl  $0x900, %eax              /* LME | NXE */
    wrmsr

    movl %cr0, %eax
    orl  $0x80000001, %eax         /* PG | PE */
    movl %eax, %cr0
    ljmpl $0x08, $(0x8000 + (ap_lm64 - ap_trampoline_start))

.code64
ap_lm64:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs

    movq %cr0, %rax
    andq $~(1 << 2), %rax
    orq  $(1 << 1), %rax
    movq %rax, %cr0

    movq %cr4, %rax
    orq  $((1 << 9) | (1 << 10)), %rax
    movq %rax, %cr4

    movq 0x8F18, %rax
    lidt (%rax)

    movq 0x8F08, %rsp
    andq $-16, %rsp
    movq 0x8F10, %rax
    call *%rax
1:
    cli
    hlt
    jmp 1b

.align 8
ap_gdt:
    .quad 0x0000000000000000       /* 0x00: null */
    .quad 0x00AF9A000000FFFF       /* 0x08: 64-bit Kernel Code (matches BSP GDT/IDT) */
    .quad 0x00AF92000000FFFF       /* 0x10: 64-bit Kernel Data (matches BSP GDT) */
    .quad 0x00CF9A000000FFFF       /* 0x18: 32-bit Temp Code */
    .quad 0x00CF92000000FFFF       /* 0x20: 32-bit Temp Data */
ap_gdt_end:
ap_gdt_ptr:
    .word ap_gdt_end - ap_gdt - 1
    .long (0x8000 + (ap_gdt - ap_trampoline_start))
ap_trampoline_end:
.code64

.section .rodata.boot, "a"
.align 16
.globl user_demo_code_start
.globl user_demo_code_end
user_demo_code_start:
    movq $0x1234, %rbx
    movq $0x5678, %r12
    pushq $0x13572468

    /* Syscall 1: SYS_GETINFO (rax=2) */
    movq $2, %rax
    syscall
    cmpq $0x3300, %rax
    jb .Luser_fail
    cmpq $0x1234, %rbx
    jne .Luser_fail
    cmpq $0x5678, %r12
    jne .Luser_fail

    /* Syscall 2 (negative test): SYS_WRITE kernel address 0x100000 -> -1 */
    movq $1, %rax
    movq $1, %rdi
    movq $0x100000, %rsi
    movq $8, %rdx
    syscall
    cmpq $-1, %rax
    jne .Luser_fail

    /* Syscall 3: SYS_WRITE user message on COM1 */
    movq $1, %rax
    movq $1, %rdi
    leaq .Luser_msg(%rip), %rsi
    movq $(.Luser_msg_end - .Luser_msg), %rdx
    syscall
    cmpq $(.Luser_msg_end - .Luser_msg), %rax
    jne .Luser_fail
    cmpq $0x1234, %rbx
    jne .Luser_fail
    cmpq $0x5678, %r12
    jne .Luser_fail

    popq %rcx
    cmpq $0x13572468, %rcx
    jne .Luser_fail

    /* Syscall 4: SYS_EXIT(42) */
    movq $60, %rax
    movq $42, %rdi
    syscall

.Luser_fail:
    movq $60, %rax
    movq $99, %rdi
    syscall

.Luser_msg:
    .ascii "[RING3] Hello from CPL=3 via syscall/sysret!\n"
.Luser_msg_end:
user_demo_code_end:
.align 16
gdt64:
    .quad 0x0000000000000000       /* 0x00: Null descriptor */
    .quad 0x00AF9A000000FFFF       /* 0x08: 64-bit Kernel Code */
    .quad 0x00AF92000000FFFF       /* 0x10: 64-bit Kernel Data */
gdt64_end:

gdt64_ptr:
    .word gdt64_end - gdt64 - 1
    .quad gdt64

.align 8
.globl isr_stub_table
isr_stub_table:
    .quad isr_stub_0,  isr_stub_1,  isr_stub_2,  isr_stub_3
    .quad isr_stub_4,  isr_stub_5,  isr_stub_6,  isr_stub_7
    .quad isr_stub_8,  isr_stub_9,  isr_stub_10, isr_stub_11
    .quad isr_stub_12, isr_stub_13, isr_stub_14, isr_stub_15
    .quad isr_stub_16, isr_stub_17, isr_stub_18, isr_stub_19
    .quad isr_stub_20, isr_stub_21, isr_stub_22, isr_stub_23
    .quad isr_stub_24, isr_stub_25, isr_stub_26, isr_stub_27
    .quad isr_stub_28, isr_stub_29, isr_stub_30, isr_stub_31
    .quad isr_stub_32, isr_stub_33, isr_stub_34, isr_stub_35
    .quad isr_stub_36, isr_stub_37, isr_stub_38, isr_stub_39
    .quad isr_stub_40, isr_stub_41, isr_stub_42, isr_stub_43
    .quad isr_stub_44, isr_stub_45, isr_stub_46, isr_stub_47

.section .data.boot, "aw"
.align 8
saved_mb_magic:
    .long 0
saved_mb_info:
    .long 0

.section .bss.boot, "aw", @nobits
.align 8
.globl os_boot_info
os_boot_info:
    .skip 64
.globl os_boot_auto_ui
os_boot_auto_ui:
    .skip 8
.align 4096
boot_pml4:
    .skip 4096
boot_pdpt:
    .skip 4096
boot_pd:
    .skip 4096
.align 16
_boot_stack_bottom:
    .skip 65536
_boot_stack_top:

.section .note.GNU-stack, "", @progbits
