ENTRY(_boot32)

PHDRS
{
    text   PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data   PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x00100000;

    .text : ALIGN(4096)
    {
        KEEP(*(.multiboot))
        *(.text.boot)
        *(.text .text.*)
    } :text

    . = ALIGN(4096);
    .rodata : ALIGN(4096)
    {
        *(.rodata.boot)
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4096);
    .data : ALIGN(4096)
    {
        *(.data.boot)
        *(.data .data.*)
    } :data

    .bss (NOLOAD) : ALIGN(4096)
    {
        *(.bss.boot)
        *(.bss .bss.*)
        *(COMMON)
    } :data

    . = ALIGN(4096);
    _kernel_end = .;
    ASSERT(_kernel_end <= 0x00400000, "Kernel image exceeds 4 MiB Linux base region")

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
