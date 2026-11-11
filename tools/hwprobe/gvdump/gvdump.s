/* gvdump.s - the graphics VRAM to a file, so a picture is compared as data, not as a photo.
 *
 *   GVDUMP FILE        writes the four planes of the CPU access page (0xA6 as found), 32000
 *                      bytes each (640 x 400 / 8), in the order 0xA8000 (B), 0xB0000 (R),
 *                      0xB8000 (G), 0xE0000 (I): 128000 bytes. Reads only.
 *
 * Used after GDCFIG (todo item 126): the GDC draws into GVRAM, so the same binary's dump on
 * the core and on the machine compares byte for byte (gvdump_decode.py --compare, or --png to
 * look at it). A plane the current mode does not map (0xE0000 in the digital 8-colour mode,
 * todo item 31) reads FF and is dumped as read.
 *
 * BUILD: make -C tools/hwprobe gvdump/gvdump.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    push    cs
    pop     ds
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    add     cx, si
1:  cmp     si, cx                  /* skip blanks */
    jae     bad
    lodsb
    cmp     al, ' '
    je      1b
    dec     si
    mov     di, offset fname
2:  cmp     si, cx
    jae     3f
    lodsb
    cmp     al, ' '
    je      3f
    cmp     al, 13
    je      3f
    mov     [di], al
    inc     di
    cmp     di, offset fname + 60
    jb      2b
3:  mov     byte ptr [di], 0
    mov     ah, 0x3C
    xor     cx, cx
    mov     dx, offset fname
    int     0x21
    jc      bad
    mov     bx, ax
    mov     si, offset planes
4:  mov     ax, [si]
    test    ax, ax
    jz      5f
    push    ds
    mov     ds, ax
    xor     dx, dx
    mov     cx, 32000
    mov     ah, 0x40
    int     0x21
    pop     ds
    jc      bad
    add     si, 2
    jmp     4b
5:  mov     ah, 0x3E
    int     0x21
    mov     dx, offset s_ok
    mov     ah, 0x09
    int     0x21
    mov     ax, 0x4C00
    int     0x21
bad:
    mov     dx, offset s_bad
    mov     ah, 0x09
    int     0x21
    mov     ax, 0x4C01
    int     0x21

planes:     .word 0xA800, 0xB000, 0xB800, 0xE000, 0
s_ok:       .ascii "GVDUMP done\r\n$"
s_bad:      .ascii "GVDUMP failed (usage: GVDUMP FILE)\r\n$"
fname:      .space 64
