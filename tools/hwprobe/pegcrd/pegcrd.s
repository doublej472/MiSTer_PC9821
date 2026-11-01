/* pegcrd.s - the PEGC 256-colour palette READ-BACK, measured on a real PC-9821.
 *
 *   PEGCRD > PEGCRD.TXT          (or RUNPEGC.BAT)
 *
 * WHY. In PEGC 256-colour mode (`0x6A` dat `0x21`, NP2kai's GDCANALOG_256) the guest
 * programs a 256-entry palette through 0xA8 (index), 0xAA (green), 0xAC (red) and
 * 0xAE (blue). What a READ of those three ports returns is unmeasured on the machine:
 *
 *   NP2kai io/gdc.c gdc_iaa/iac/iae returns the FULL byte last written to
 *     anareg[16*3 + palnum*4 + c], at the unmasked 8-bit index.
 *   MAME src/mame/nec/pc9801.cpp's pc9821_a0_r has a `256 color mode [xx] R` arm
 *     that returns 0 for these ports.
 *   This core follows NP2kai (pc9821_crtc.sv's pal256_{g,r,b} mirror, 3 M10K).
 *
 * The divergence is recorded in pc9821_crtc.sv's mirror comment; the machine has not
 * been measured on this row (docs/probes/PEGCRD-XE10.TXT). The Xe10 answers the full
 * byte in 256-colour mode (the mirror stays) and only the low nibble in 16-colour mode.
 *
 * METHOD. Write a six-entry pattern (00, 01, 02, 0B, 5A, A5 - the last two separate an
 * 8-bit index from a 4-bit-masked one), then read 0xAA/0xAC/0xAE back. Both analogue
 * paths are exercised, each in its own mode and with its own restore:
 *
 *   16-colour analogue (`0x6A` dat 0x01): the 16-entry table, index masked to 4 bits.
 *     The reference for the 256-colour result: the 16-colour mirror is the known path.
 *   256-colour PEGC (`0x6A` dat 0x07 = FF2 num 3 / register write enable, then dat
 *     0x21 = FF2 num 0x10 / GDCANALOG_256): the 256-entry table, unmasked 8-bit index.
 *
 * WHAT IT WRITES, AND HOW IT IS RESTORED. The probe runs from a freshly booted plain
 * DOS prompt, where 0x6A reads 0x00 (digital 8-colour text). It saves that byte and the
 * 0x9A0 query bits, writes the two analogue modes, and at the end:
 *   - restores the 16-entry analogue palette from the values read back before the
 *     test (the same six-entry read path), or from the NEC power-on table (itf.rom
 *     0x042F, the same {R,G,B} table pc9821_gfx_palette seeds) when every as-found
 *     channel read 0, and prints which source it used;
 *   - zeroes the six 256-colour entries it wrote (NP2kai's palette powers up zeroed);
 *   - clears 256 mode, clears FF2 num 3, then restores the saved FF2 bits one at a time;
 *   - writes 0xA8 <- 0 (the boot palette index; the hidden analogue index cannot be read
 *     back in digital mode, so this is the documented boot value, not a saved one).
 * Every port it touches is also printed before/after, so a capture proves the restore.
 *
 * SAFETY. No disk access except DOS stdout; no memory writes outside this program. It
 * changes display modes, so the screen may change colour or go blank for a second -
 * always redirect stdout to a file. A missing END:PEGCRD means the last BEGIN section
 * did not finish.
 *
 * BUILD: make -C tools/hwprobe pegcrd/pegcrd.com
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

    .equ PATTERN_N, 6

_start:
    mov     si, offset msg_begin
    call    puts

    /* The as-found FF2 byte and the query bits the restore needs. */
    mov     dx, 0x006A
    in      al, dx
    mov     [mode_found], al
    cmp     al, 0x10                /* mode2 is four bits; clamp an open-bus read */
    jb      mf_ok
    xor     al, al
    mov     [mode_found], al
mf_ok:
    mov     al, 0x04
    call    query9a0
    mov     [q16], al
    mov     al, 0x07
    call    query9a0
    mov     [qegc], al
    mov     al, 0x08
    call    query9a0
    mov     [qwren], al
    mov     al, 0x0A
    call    query9a0
    mov     [q256], al
    call    mode_state

    /* ---------------- 16-colour analogue path ---------------- */
    mov     dx, 0x006A
    mov     al, 0x01                /* FF2 num 0 on: 16-colour analogue */
    out     dx, al
    call    iowait
    call    mode_state
    call    save_pal16

    mov     si, offset pattern
    mov     cx, PATTERN_N
p16_loop:
    push    cx
    push    si
    call    write_entry
    call    read_entry
    pop     si
    push    si
    mov     di, offset pre16
    call    print_entry
    pop     si
    add     si, 4
    pop     cx
    loop    p16_loop

    cmp     byte ptr [save16_ok], 0
    je      p16_nec
    call    restore_saved16
    mov     si, offset msg_rest16_save
    call    puts
    jmp     p16_restored
p16_nec:
    call    restore_pal16
    mov     si, offset msg_rest16_nec
    call    puts
p16_restored:
    call    reset_a8                 /* the boot analogue index, set while analogue */
    /* Back to the as-found 16/8-colour bit (the 0x9A0 query is the witness). */
    mov     dx, 0x006A
    mov     al, [q16]
    and     al, 0x01
    out     dx, al
    call    iowait
    call    mode_state

    /* ---------------- 256-colour PEGC path ---------------- */
    mov     dx, 0x006A
    mov     al, 0x07                /* FF2 num 3 on: register write enable */
    out     dx, al
    call    iowait
    mov     dx, 0x006A
    mov     al, 0x21                /* FF2 num 0x10 on: GDCANALOG_256 */
    out     dx, al
    call    iowait
    call    mode_state

    mov     si, offset pattern
    mov     cx, PATTERN_N
p256_loop:
    push    cx
    push    si
    call    write_entry
    call    read_entry
    pop     si
    push    si
    mov     di, offset pre256
    call    print_entry
    pop     si
    add     si, 4
    pop     cx
    loop    p256_loop

    call    restore_pal256
    call    reset_a8                 /* the boot analogue index, set while analogue */
    /* 256 off, then FF2 num 3 off; then the saved FF2 bits. */
    mov     dx, 0x006A
    mov     al, 0x20                /* FF2 num 0x10 off */
    out     dx, al
    call    iowait
    mov     dx, 0x006A
    mov     al, 0x06                /* FF2 num 3 off */
    out     dx, al
    call    iowait
    call    restore_mode_bits
    call    iowait

    mov     si, offset msg_restore_a8
    call    puts

    call    mode_state
    mov     si, offset msg_restore
    call    puts
    mov     al, [mode_found]
    call    puthex8
    mov     si, offset msg_now
    call    puts
    mov     dx, 0x006A
    in      al, dx
    call    puthex8
    call    crlf

    mov     si, offset msg_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* ------------------------------------------------------------------ */
/* write_entry: DS:SI -> {index, R, G, B}; writes 0xA8 then 0xAC/AA/AE. */
write_entry:
    push    ax
    push    dx
    push    si
    mov     al, [si]
    mov     dx, 0x00A8
    out     dx, al
    mov     al, [si+1]              /* red   -> 0xAC */
    mov     dx, 0x00AC
    out     dx, al
    mov     al, [si+2]              /* green -> 0xAA */
    mov     dx, 0x00AA
    out     dx, al
    mov     al, [si+3]              /* blue  -> 0xAE */
    mov     dx, 0x00AE
    out     dx, al
    call    iowait
    pop     si
    pop     dx
    pop     ax
    ret

/* read_entry: with 0xA8 already set, read 0xAC/0xAA/0xAE into rd_r/rd_g/rd_b. */
read_entry:
    push    ax
    push    dx
    mov     dx, 0x00AC
    in      al, dx
    mov     [rd_r], al
    mov     dx, 0x00AA
    in      al, dx
    mov     [rd_g], al
    mov     dx, 0x00AE
    in      al, dx
    mov     [rd_b], al
    pop     dx
    pop     ax
    ret

/* print_entry: DS:SI -> pattern entry, DI -> prefix string. */
print_entry:
    push    ax
    push    bx
    push    dx
    push    si
    push    di
    mov     bx, si                  /* BX keeps the pattern entry: puts preserves BX */
    mov     si, di
    call    puts
    mov     si, offset msg_entry
    call    puts
    mov     al, [bx]
    call    puthex8
    mov     si, offset msg_wrote
    call    puts
    mov     al, [bx+1]
    call    puthex8
    mov     si, offset msg_g
    call    puts
    mov     al, [bx+2]
    call    puthex8
    mov     si, offset msg_b
    call    puts
    mov     al, [bx+3]
    call    puthex8
    mov     si, offset msg_read
    call    puts
    mov     al, [rd_r]
    call    puthex8
    mov     si, offset msg_g
    call    puts
    mov     al, [rd_g]
    call    puthex8
    mov     si, offset msg_b
    call    puts
    mov     al, [rd_b]
    call    puthex8
    call    crlf
    pop     di
    pop     si
    pop     dx
    pop     bx
    pop     ax
    ret

/* save_pal16: read the as-found 16-colour palette into save16 (R,G,B bytes at
 * the masked index). save16_ok is set only if some byte is non-zero, so a
 * write-only/zero-returning pathway falls back to the NEC table at restore. */
save_pal16:
    push    ax
    push    cx
    push    dx
    push    si
    mov     byte ptr [save16_ok], 0
    mov     byte ptr [save16_ff], 0
    mov     si, offset save16
    xor     cx, cx
sp16_loop:
    mov     al, cl
    mov     dx, 0x00A8
    out     dx, al
    call    iowait
    mov     dx, 0x00AC
    in      al, dx
    mov     [si], al
    call    sp16_note
    mov     dx, 0x00AA
    in      al, dx
    mov     [si+1], al
    call    sp16_note
    mov     dx, 0x00AE
    in      al, dx
    mov     [si+2], al
    call    sp16_note
    add     si, 3
    inc     cx
    cmp     cx, 16
    jb      sp16_loop
    cmp     byte ptr [save16_ff], 0
    je      sp16_done
    mov     byte ptr [save16_ok], 0   /* an open-bus read is not a saved palette */
sp16_done:
    pop     si
    pop     dx
    pop     cx
    pop     ax
    ret

/* sp16_note: AL was just read; note a non-zero value and an open-bus 0xFF. */
sp16_note:
    cmp     al, 0xFF
    jne     sp16_not_ff
    mov     byte ptr [save16_ff], 1
    ret
sp16_not_ff:
    or      [save16_ok], al
    ret

/* restore_saved16: write save16 back, index by index. */
restore_saved16:
    push    ax
    push    cx
    push    dx
    push    si
    mov     si, offset save16
    xor     cx, cx
rs16_loop:
    mov     al, cl
    mov     dx, 0x00A8
    out     dx, al
    mov     al, [si]                /* red   -> 0xAC */
    mov     dx, 0x00AC
    out     dx, al
    mov     al, [si+1]              /* green -> 0xAA */
    mov     dx, 0x00AA
    out     dx, al
    mov     al, [si+2]              /* blue  -> 0xAE */
    mov     dx, 0x00AE
    out     dx, al
    add     si, 3
    inc     cx
    cmp     cx, 16
    jb      rs16_loop
    call    iowait
    pop     si
    pop     dx
    pop     cx
    pop     ax
    ret

/* restore_pal16: the NEC power-on 16-colour analogue table (itf.rom 0x042F). */
restore_pal16:
    push    ax
    push    cx
    push    dx
    push    si
    mov     si, offset pal16
    xor     cx, cx
rp16_loop:
    mov     al, cl
    mov     dx, 0x00A8
    out     dx, al
    mov     al, [si]                /* red nibble */
    mov     dx, 0x00AC
    out     dx, al
    mov     al, [si+1]              /* green */
    mov     dx, 0x00AA
    out     dx, al
    mov     al, [si+2]              /* blue */
    mov     dx, 0x00AE
    out     dx, al
    add     si, 3
    inc     cx
    cmp     cx, 16
    jb      rp16_loop
    call    iowait
    pop     si
    pop     dx
    pop     cx
    pop     ax
    ret

/* restore_pal256: zero the six entries the pattern wrote (NP2kai powers up zeroed). */
restore_pal256:
    push    ax
    push    cx
    push    dx
    push    si
    mov     si, offset pattern
    mov     cx, PATTERN_N
rp256_loop:
    mov     al, [si]
    mov     dx, 0x00A8
    out     dx, al
    xor     al, al
    mov     dx, 0x00AA
    out     dx, al                  /* green 0 */
    mov     dx, 0x00AC
    out     dx, al                  /* red 0 */
    mov     dx, 0x00AE
    out     dx, al                  /* blue 0 */
    add     si, 4
    loop    rp256_loop
    call    iowait
    pop     si
    pop     dx
    pop     cx
    pop     ax
    ret

/* restore_mode_bits: restore the four FF2 bits saved in mode_found/qegc/qwren. */
restore_mode_bits:
    push    ax
    push    dx
    /* num 0: 16-colour select (the query bit is the witness, not the 0x6A read) */
    mov     dx, 0x006A
    mov     al, [q16]
    and     al, 0x01
    out     dx, al                  /* dat 0x00 or 0x01 */
    /* num 1: the FF2 bit-1 latch */
    mov     al, [mode_found]
    and     al, 0x02
    shr     al, 1
    or      al, 0x02                /* dat 0x02 or 0x03 */
    out     dx, al
    /* num 2 (EGC): needs FF2 num 3 set while it is written */
    cmp     byte ptr [qegc], 0
    je      rmb_egc_done
    mov     al, 0x07
    out     dx, al
    mov     al, 0x05
    out     dx, al
rmb_egc_done:
    /* num 0x10 (GDCANALOG_256), if the machine was found in it */
    cmp     byte ptr [q256], 0
    je      rmb_wren
    mov     al, 0x07
    out     dx, al
    mov     al, 0x21
    out     dx, al
rmb_wren:
    /* num 3: the register write enable, to its saved value */
    cmp     byte ptr [qwren], 0
    je      rmb_wren_off
    mov     al, 0x07
    out     dx, al
    jmp     rmb_done
rmb_wren_off:
    mov     al, 0x06
    out     dx, al
rmb_done:
    pop     dx
    pop     ax
    ret

/* mode_state: print 0x6A and the four query bits that describe the mode. */
mode_state:
    push    ax
    push    dx
    mov     si, offset msg_mode
    call    puts
    mov     dx, 0x006A
    in      al, dx
    call    puthex8
    mov     si, offset msg_q04
    call    puts
    mov     al, 0x04
    call    query9a0
    call    puthex8
    mov     si, offset msg_q07
    call    puts
    mov     al, 0x07
    call    query9a0
    call    puthex8
    mov     si, offset msg_q08
    call    puts
    mov     al, 0x08
    call    query9a0
    call    puthex8
    mov     si, offset msg_q0a
    call    puts
    mov     al, 0x0A
    call    query9a0
    call    puthex8
    call    crlf
    pop     dx
    pop     ax
    ret

reset_a8:                               /* 0xA8 <- 0 while an analogue mode is on */
    push    ax
    push    dx
    mov     dx, 0x00A8
    xor     al, al
    out     dx, al
    call    iowait
    pop     dx
    pop     ax
    ret

/* query9a0: AL = index, returns AL = the 0x9A0 query byte. */
query9a0:
    push    dx
    mov     dx, 0x09A0
    out     dx, al
    call    iowait
    in      al, dx
    pop     dx
    ret

iowait:
    out     0x5F, al                /* the PC-98 I/O wait port; preserves AL */
    ret

/* ------------------------------------------------------------------ */
/* output                                                              */
/* ------------------------------------------------------------------ */
putc:                                   /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret

crlf:
    push    si
    mov     si, offset msg_crlf
    call    puts
    pop     si
    ret

puts:                                   /* DS:SI, NUL terminated */
    push    ax
    push    dx
    push    si
ps_loop:
    mov     al, [si]
    test    al, al
    jz      ps_done
    mov     dl, al
    call    putc
    inc     si
    jmp     ps_loop
ps_done:
    pop     si
    pop     dx
    pop     ax
    ret

puthex8:                                /* AL */
    push    ax
    push    dx
    push    ax
    shr     al, 4
    call    ph_nib
    pop     ax
    and     al, 0x0F
    call    ph_nib
    pop     dx
    pop     ax
    ret
ph_nib:
    add     al, '0'
    cmp     al, '9'
    jbe     ph_out
    add     al, 'A' - '9' - 1
ph_out:
    mov     dl, al
    call    putc
    ret

/* ------------------------------------------------------------------ */
    .balign 4
mode_found: .byte 0
q16:        .byte 0
qegc:       .byte 0
qwren:      .byte 0
q256:       .byte 0
save16_ok:  .byte 0
save16_ff:  .byte 0
save16:     .space 48
rd_r:       .byte 0
rd_g:       .byte 0
rd_b:       .byte 0

/* {index, R, G, B}. 5A/A5 separate an unmasked 8-bit index from a 4-bit one. */
pattern:
    .byte 0x00, 0x00, 0x00, 0x00
    .byte 0x01, 0x12, 0x34, 0x56
    .byte 0x02, 0xFF, 0x00, 0x7F
    .byte 0x0B, 0x5A, 0xA5, 0x3C
    .byte 0x5A, 0x11, 0x22, 0x33
    .byte 0xA5, 0x44, 0x55, 0x66

/* NEC power-on 16-colour analogue table, {R,G,B} nibbles, itf.rom 0x042F. */
pal16:
    .byte 0,0,0,     0,0,7,     7,0,0,     7,0,7
    .byte 0,7,0,     0,7,7,     7,7,0,     7,7,7
    .byte 4,4,4,     0,0,15,    15,0,0,    15,0,15
    .byte 0,15,0,    0,15,15,   15,15,0,   15,15,15

msg_begin:   .asciz "BEGIN:PEGCRD\r\n"
msg_mode:    .asciz "MODE 6A="
msg_q04:     .asciz " 9A0_04="
msg_q07:     .asciz " 9A0_07="
msg_q08:     .asciz " 9A0_08="
msg_q0a:     .asciz " 9A0_0A="
pre16:       .asciz "16  "
pre256:      .asciz "256 "
msg_entry:   .asciz "ENTRY="
msg_wrote:   .asciz " WROTE_R="
msg_g:       .asciz " G="
msg_b:       .asciz " B="
msg_read:    .asciz " READ_R="
msg_rest16_save: .asciz "RESTORE16 source=saved\r\n"
msg_rest16_nec:  .asciz "RESTORE16 source=NEC-power-on\r\n"
msg_restore_a8: .asciz "RESTORE A8=00 (analogue index, both modes)\r\n"
msg_restore: .asciz "RESTORE 6A was="
msg_now:     .asciz " now="
msg_end:     .asciz "END:PEGCRD\r\n"
msg_crlf:    .asciz "\r\n"
