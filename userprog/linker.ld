ENTRY(_start)

PHDRS
{
    text   PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data   PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x0000008000000000;

    .text : ALIGN(4096)
    {
        *(.text .text.*)
    } :text

    . = ALIGN(4096);
    .rodata : ALIGN(4096)
    {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4096);
    .data : ALIGN(4096)
    {
        *(.data .data.*)
    } :data

    .bss (NOLOAD) : ALIGN(4096)
    {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
