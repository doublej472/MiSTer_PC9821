/* rboot.s - the software reboot Windows 95's WIN.COM performs, byte for byte.
 *
 * WHAT IT IS FOR. Leaving Windows 95's MS-DOS mode (`exit` at the real-mode prompt) or
 * choosing Shut Down > Restart ends in WIN.COM's reboot stub (WIN.COM 4.00.950 at file
 * offset 0x27, IO.SYS 4.00.950 carries the same stub at 0x3BD7). This program runs exactly
 * that stub, so a reboot the core or the machine fails can be reproduced from a plain DOS
 * prompt without Windows:
 *
 *   cli
 *   out 0x37,0x92   8255 mode word (port A in, port B in, port C out)
 *   out 0x37,0x07   port C bit 3 set   (buzzer off)
 *   out 0x37,0x0B   port C bit 5 set   (SHUT1)
 *   out 0x37,0x0F   port C bit 7 set   (SHUT0)
 *   out 0x37,0x08   port C bit 4 clear (memory-check enable off)
 *   out 0x50,al     NMI off
 *   out 0xA2,0x05   graphics GDC: BLANK (display off)
 *   out 0x62,0x05   text GDC: BLANK (display off)
 *   mov ecx,0x40000 / loop $    a short settle delay
 *   out 0xF0,0x00   CPU reset
 *   jmp $
 *
 * With SHUT0 = SHUT1 = 1 the main BIOS's reset entry (BIOS.ROM FD80:0000, BANK7@0xFD804-
 * 0xFD83D) treats the reset as a reboot: it toggles port 0x534 bit 0 and then maps the ITF
 * (out 0x43D,0) and jumps to FFFF:0000, so the machine re-runs its POST and boots again.
 * A correct core does the same: the screen comes back with the memory count and the disk
 * boots. A black screen that stays black is the failure.
 *
 * Run it from a plain DOS prompt (`RBOOT`); it prints one line, waits for a key (Esc quits)
 * and reboots. `RBOOT /Y` (any other argument) skips the key, for AUTOEXEC.BAT.
 *
 * THE RESET-SET VARIANT (todo item 170): what the reboot leaves behind, in two invocations
 * with a file between them, because nothing in memory is known to survive the reboot:
 *
 *   RBOOT /S   reads the set below as found and writes it to RBOOT.TXT (`RB BEFORE ...`);
 *              then, under cli, moves the three latches whose read-back follows a write -
 *              0x063C (the 0xD8000 bank select; docs/probes/D8BANK-XE10.TXT reads FC -> FE
 *              after a write of 2) to bank 2, 0x1E8E (the IDE work-RAM gate;
 *              docs/probes/SHADOWW.TXT reads FE, FF after 0x81) to 0x81 - and stores the
 *              marker 0xA5 at physical 0xF8E90 with the writable-copy gate 0x053D bit 1 set
 *              (bit 4, the 0xD8000 ROM gate, keeps its as-found value: probe2 /SHADOW's rule),
 *              reads everything back (`RB SET ...`), puts every byte back, reads again
 *              (`RB RESTORED ...`, which must equal BEFORE), sti, appends both lines to the
 *              file and closes it; then cli, the same moves again, and the WIN.COM stub. No
 *              DOS call is made while a latch is moved.
 *   RBOOT /R   run after that reboot has come back to DOS: reads the same set
 *              (`RB AFTER ...`) and appends it to RBOOT.TXT (creating it when it is missing,
 *              with `RB NOSAVE`).
 *
 * The set: ports 0x053D, 0x043F, 0x0461, 0x0463 (straps or encoded reads, so they are read,
 * not moved: probe2's restore report says why), 0x063C, 0x1E8E, the IDE bank select 0x0432,
 * the ERROR register 0x0642 and the alternate status 0x074C (no status read, which would ack a
 * pending IDE interrupt), 0x0534, and the bytes at physical 0xF8E8F-0xF8E91. AFTER is what the
 * re-POST and the DOS boot leave; BEFORE, taken on a machine that was powered on into DOS, is
 * the cold-boot answer to compare it with. A value AFTER that equals SET where BEFORE differs
 * is a latch the reboot and the POST both left alone.
 */
    .code16
    .intel_syntax noprefix

/* The set's size. Defined BEFORE any use: GAS reads a not-yet-defined symbol in an
 * Intel-syntax immediate as a memory operand (`mov cx, NSET` would load CX from address 13). */
NPORT = 10
NSET = NPORT + 3

    .section .text
    .global _start

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    /* the argument: none = prompt, /S, /R, anything else = /Y */
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    add     cx, si
a_skip:
    cmp     si, cx
    jae     no_arg
    lodsb
    cmp     al, ' '
    je      a_skip
    cmp     al, '/'
    jne     do_banner_y
    cmp     si, cx
    jae     do_banner_y
    lodsb
    and     al, 0xDF
    cmp     al, 'S'
    je      mode_save
    cmp     al, 'R'
    je      mode_read
do_banner_y:
    mov     dx, offset msg_banner
    mov     ah, 0x09
    int     0x21
    jmp     do_reboot
no_arg:
    mov     dx, offset msg_banner
    mov     ah, 0x09
    int     0x21
    mov     ah, 0x08                    /* wait for a key (no echo) */
    int     0x21
    cmp     al, 0x1B
    jne     do_reboot
    mov     ax, 0x4C00
    int     0x21

/* ---- /S ------------------------------------------------------------------------------- */
mode_save:
    call    read_set
    mov     dx, offset tag_before
    call    fmt_set                     /* -> line */
    mov     ah, 0x3C                    /* create RBOOT.TXT */
    xor     cx, cx
    mov     dx, offset fname
    int     0x21
    jc      file_err
    mov     [fh], ax
    mov     dx, offset hdr_line
    call    emit_z
    mov     dx, offset line
    call    emit_z

    pushf
    cli
    call    move_latches
    call    read_set
    call    copy_set_to_set2
    call    restore_latches
    call    read_set
    popf

    call    copy_set2_back_swap         /* set <-> set2: print SET first */
    mov     dx, offset tag_set
    call    fmt_set
    mov     dx, offset line
    call    emit_z
    call    copy_set2_back_swap
    mov     dx, offset tag_restored
    call    fmt_set
    mov     dx, offset line
    call    emit_z
    mov     dx, offset boot_line
    call    emit_z
    mov     bx, [fh]
    mov     ah, 0x3E
    int     0x21
    mov     ah, 0x0D                    /* disk reset: flush DOS's buffers before the reboot */
    int     0x21
    /* the moves again, and the reboot */
    cli
    call    move_latches
    jmp     do_reboot_cli

/* ---- /R ------------------------------------------------------------------------------- */
mode_read:
    call    read_set
    mov     dx, offset tag_after
    call    fmt_set
    mov     ax, 0x3D01                  /* open RBOOT.TXT for writing */
    mov     dx, offset fname
    int     0x21
    jc      r_create
    mov     [fh], ax
    mov     bx, ax
    mov     ax, 0x4202                  /* seek to the end */
    xor     cx, cx
    xor     dx, dx
    int     0x21
    jmp     r_write
r_create:
    mov     ah, 0x3C
    xor     cx, cx
    mov     dx, offset fname
    int     0x21
    jc      file_err
    mov     [fh], ax
    mov     dx, offset nosave_line
    call    emit_z
r_write:
    mov     dx, offset line
    call    emit_z
    mov     bx, [fh]
    mov     ah, 0x3E
    int     0x21
    mov     ax, 0x4C00
    int     0x21

file_err:
    mov     dx, offset msg_ferr
    mov     ah, 0x09
    int     0x21
    mov     ax, 0x4C01
    int     0x21

/* ---- the reboot (WIN.COM's stub) ----------------------------------------------------- */
do_reboot:
    cli
do_reboot_cli:
    mov     al, 0x92
    out     0x37, al
    mov     al, 0x07
    out     0x37, al
    mov     al, 0x0B
    out     0x37, al
    mov     al, 0x0F
    out     0x37, al
    mov     al, 0x08
    out     0x37, al
    out     0x50, al
    mov     al, 0x05
    out     0xA2, al
    out     0x62, al
    mov     ecx, 0x40000
settle:
    loop    settle                      /* address-size 16: CX, as WIN.COM's own loop */
    mov     al, 0x00
    out     0xF0, al
halt:
    jmp     halt

/* ---- the set -------------------------------------------------------------------------- */
/* read_set: every port in porttab -> set[0..NPORT-1], then F8E8F/F8E90/F8E91 -> set[NPORT..].
 * No DOS call, so it runs under cli. */
read_set:
    push    si
    push    di
    push    es
    mov     si, offset porttab
    mov     di, offset set
1:  mov     dx, [si]
    cmp     dx, 0xFFFF
    je      2f
    in      al, dx
    mov     [di], al
    inc     di
    add     si, 2
    jmp     1b
2:  mov     ax, 0xF8E8
    mov     es, ax
    mov     al, es:[0x0F]
    mov     [di], al
    mov     al, es:[0x10]
    mov     [di+1], al
    mov     al, es:[0x11]
    mov     [di+2], al
    pop     es
    pop     di
    pop     si
    ret

/* move_latches: as found (set[] holds BEFORE when called the first time; the as-found
 * copies are kept in was_*) -> the moved state. */
move_latches:
    push    es
    mov     dx, 0x063C
    in      al, dx
    mov     [was_63c], al
    and     al, 0xFC
    or      al, 0x02
    out     dx, al
    mov     dx, 0x1E8E
    in      al, dx
    mov     [was_1e8e], al
    mov     al, 0x81
    out     dx, al
    mov     dx, 0x053D
    in      al, dx
    mov     [was_53d], al
    or      al, 0x02                    /* the writable-copy gate; bit 4 as found */
    out     dx, al
    mov     ax, 0xF8E8
    mov     es, ax
    mov     al, es:[0x10]
    mov     [was_e90], al
    mov     byte ptr es:[0x10], 0xA5
    pop     es
    ret

/* restore_latches: the marker byte back (gate still set), then 0x053D, 0x1E8E, 0x063C. */
restore_latches:
    push    es
    mov     ax, 0xF8E8
    mov     es, ax
    mov     al, [was_e90]
    mov     es:[0x10], al
    pop     es
    mov     dx, 0x053D
    mov     al, [was_53d]
    out     dx, al
    mov     dx, 0x1E8E
    mov     al, [was_1e8e]
    out     dx, al
    mov     dx, 0x063C
    mov     al, [was_63c]
    out     dx, al
    ret

copy_set_to_set2:
    push    si
    push    di
    push    cx
    mov     si, offset set
    mov     di, offset set2
    mov     cx, NSET
    rep     movsb
    pop     cx
    pop     di
    pop     si
    ret
copy_set2_back_swap:                    /* swap set[] and set2[] */
    push    si
    push    cx
    xor     si, si
1:  mov     al, [set + si]
    xchg    al, [set2 + si]
    mov     [set + si], al
    inc     si
    cmp     si, NSET
    jb      1b
    pop     cx
    pop     si
    ret

/* fmt_set: DX = tag (zero-terminated) -> line = "RB <tag> 053D=.. ... F8E8F=.. .. ..\r\n" */
fmt_set:
    mov     di, offset line
    mov     si, offset s_rb
    call    cpy_z
    mov     si, dx
    call    cpy_z
    mov     si, offset porttab
    mov     bx, offset set
1:  mov     ax, [si]
    cmp     ax, 0xFFFF
    je      2f
    mov     byte ptr [di], ' '
    inc     di
    call    hex16_to
    mov     byte ptr [di], '='
    inc     di
    mov     al, [bx]
    call    hex8_to
    inc     bx
    add     si, 2
    jmp     1b
2:  mov     si, offset s_f8e8f
    call    cpy_z
    mov     al, [bx]
    call    hex8_to
    mov     byte ptr [di], ' '
    inc     di
    mov     al, [bx+1]
    call    hex8_to
    mov     byte ptr [di], ' '
    inc     di
    mov     al, [bx+2]
    call    hex8_to
    mov     byte ptr [di], 13
    mov     byte ptr [di+1], 10
    mov     byte ptr [di+2], 0
    ret

cpy_z:                                  /* SI (zero-terminated) -> DI, DI advanced */
    lodsb
    test    al, al
    jz      1f
    mov     [di], al
    inc     di
    jmp     cpy_z
1:  ret
hex16_to:                               /* AX -> 4 digits at DI */
    push    ax
    mov     al, ah
    call    hex8_to
    pop     ax
    call    hex8_to
    ret
hex8_to:                                /* AL -> 2 digits at DI */
    push    ax
    shr     al, 4
    call    hexd_to
    pop     ax
    push    ax
    call    hexd_to
    pop     ax
    ret
hexd_to:
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     1f
    add     al, 7
1:  mov     [di], al
    inc     di
    ret

/* emit_z: DX = zero-terminated text -> stdout (handle 1) and the file [fh] */
emit_z:
    push    bx
    push    cx
    mov     si, dx
    xor     cx, cx
1:  cmp     byte ptr [si], 0
    je      2f
    inc     si
    inc     cx
    jmp     1b
2:  push    dx
    push    cx
    mov     bx, 1
    mov     ah, 0x40
    int     0x21
    pop     cx
    pop     dx
    mov     bx, [fh]
    mov     ah, 0x40
    int     0x21
    pop     cx
    pop     bx
    ret

msg_banner:
    .ascii  "RBOOT: WIN.COM reboot (SHUT0=SHUT1=1, GDC blank, out 0xF0). Any key = reboot, Esc = quit\r\n$"
msg_ferr:
    .ascii  "RBOOT: cannot write RBOOT.TXT\r\n$"
fname:      .asciz "RBOOT.TXT"
hdr_line:   .asciz "RBOOT reset-set variant (tools/hwprobe/rboot; todo item 170)\r\n"
boot_line:  .asciz "RB REBOOTING (run RBOOT /R at the next DOS prompt)\r\n"
nosave_line: .asciz "RB NOSAVE (no RBOOT.TXT from an RBOOT /S was found)\r\n"
s_rb:       .asciz "RB "
tag_before: .asciz "BEFORE  "
tag_set:    .asciz "SET     "
tag_restored: .asciz "RESTORED"
tag_after:  .asciz "AFTER   "
s_f8e8f:    .asciz " F8E8F="

porttab:
    .word 0x053D, 0x043F, 0x0461, 0x0463, 0x063C, 0x1E8E, 0x0432, 0x0642, 0x074C, 0x0534
    .word 0xFFFF

fh:         .word 0
was_63c:    .byte 0
was_1e8e:   .byte 0
was_53d:    .byte 0
was_e90:    .byte 0
set:        .space NSET
set2:       .space NSET
line:       .space 160
