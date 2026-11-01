/* egcplane.s - does the EGC's per-operation time depend on how many planes are enabled?
 *
 * WHY. A plane-serial EGC (one plane per clock) would take ~N times longer for N enabled
 * planes; a plane-parallel EGC takes the same time for 1, 2, 3 or 4. The core needs to know
 * which one the real Xe10 is. This probe times the same EGC shape with the EGC access-plane
 * register (0x04A0) enabling exactly 1, 2, 3 and 4 planes and everything else held fixed.
 *
 * 0x04A0 BIT CONVENTION (the one gfxbenc2 uses): bits 3:0 are plane-DISABLE bits, active
 * LOW enable (a SET bit leaves that plane out of the operation; NP2kai memegc.c plane_en =
 * !access[n], and src/pc9821/core/pc9821_egc.sv plane_en[n] = !acc_access[n]). Bits 15:4 are
 * held at 1, as gfxbenc2's 0xFFF0 does. The enabled planes are the LOW planes 0..N-1:
 *     1 plane  -> 0xFFFE  (plane 0 only)
 *     2 planes -> 0xFFFC  (planes 0,1)
 *     3 planes -> 0xFFF8  (planes 0,1,2)
 *     4 planes -> 0xFFF0  (all; gfxbenc2's value)
 *
 * SHAPES (each at P1..P4), the register values are gfxbenc2's verbatim:
 *   EGC1400  : 0x4A2=0x40FF 0x4A4=0x1400 0x4A6=0x0009 0x4AC=0 0x4AE=0x000F, write only
 *   EGC0CF0  : 0x4A2=0x00FF 0x4A4=0x0CF0 0x4A6=0x0009 0x4AC=0 0x4AE=0x000F, write only
 *   EGC3100SP: 0x4A2=0x00FF 0x4A4=0x3100 0x4A6=0x0009 0x4AC=0 0x4AE=0x000F, read + write, one page
 *   EGC28F0SP: 0x4A2=0x00FF 0x4A4=0x28F0 0x4A6=0x0009 0x4AC=2 0x4AE=0x000F, read + write, one page
 *   (0x4A8 mask = 0xFFFF everywhere; the 0xA6 page switch is avoided, it is an I/O cost.)
 * CONTROLS: CTRLEW (write-only shell) and CTRLER (read+write shell): body_egc with each GVRAM
 * access replaced by a register op, same loop. Net = row - control.
 *
 * OUTPUT: `EGCP <TAG> UNITS=<n> ARTIC=<ticks> CLK50=<total> PER=<per-unit>` as gfxbenc2.
 * TAG = <shape>P<n>, e.g. EGC1400P2. Run redirected (RUNEGCP.BAT). The GVRAM is scribbled
 * by design; the EGC and GRCG end off, 0xA6 ends at 0, the access register ends 0xFFF0.
 * READ-ONLY with respect to the disk.
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

/* 16 units per sprite; 16000 EGC accesses per row. */
    .equ EGC_SPRITES,  1000

/* EGCROW lbl, access, fgbg, ope, fg, sft, rw : program the EGC and time one row. */
    .macro EGCROW lbl, access, fgbg, ope, fg, sft, rw
    mov     word ptr [egc_v_access], \access
    mov     word ptr [egc_v_fgbg], \fgbg
    mov     word ptr [egc_v_ope],  \ope
    mov     word ptr [egc_v_fg],   \fg
    mov     word ptr [egc_v_mask], 0xFFFF
    mov     word ptr [egc_v_sft],  \sft
    mov     word ptr [egc_v_leng], 0x000F
    call    egc_prog
    mov     word ptr [g_count], EGC_SPRITES
    mov     byte ptr [egc_rw], \rw
    mov     byte ptr [egc_page], 0
    mov     dword ptr [rc_units], EGC_SPRITES
    mov     word ptr [rc_body], offset body_egc
    mov     si, offset lbl_\lbl
    call    run_case
    .endm

    .macro EGCSHAPE pfx, fgbg, ope, fg, sft, rw
    EGCROW  \pfx\()P1, 0xFFFE, \fgbg, \ope, \fg, \sft, \rw
    EGCROW  \pfx\()P2, 0xFFFC, \fgbg, \ope, \fg, \sft, \rw
    EGCROW  \pfx\()P3, 0xFFF8, \fgbg, \ope, \fg, \sft, \rw
    EGCROW  \pfx\()P4, 0xFFF0, \fgbg, \ope, \fg, \sft, \rw
    .endm

_start:
    mov     si, offset msg_banner_tab
    call    putlns
    call    egc_off
    call    egc_on

    /* controls first (no GVRAM access; EGC state irrelevant but it is armed already) */
    mov     word ptr [g_count], EGC_SPRITES
    mov     dword ptr [rc_units], EGC_SPRITES
    mov     byte ptr [egc_rw], 0
    mov     word ptr [rc_body], offset body_ctrlegc
    mov     si, offset lbl_ctrlew
    call    run_case
    mov     byte ptr [egc_rw], 1
    mov     si, offset lbl_ctrler
    call    run_case

    mov     si, offset c_ctrl
    call    puts
    mov     si, offset c_1400
    call    puts
    EGCSHAPE EGC1400, 0x40FF, 0x1400, 0x0009, 0x0000, 0
    mov     si, offset c_0cf0
    call    puts
    EGCSHAPE EGC0CF0, 0x00FF, 0x0CF0, 0x0009, 0x0000, 0
    mov     si, offset c_3100
    call    puts
    EGCSHAPE EGC3100SP, 0x00FF, 0x3100, 0x0009, 0x0000, 1
    mov     si, offset c_28f0
    call    puts
    EGCSHAPE EGC28F0SP, 0x00FF, 0x28F0, 0x0009, 0x0002, 1

    call    cleanup
    mov     si, offset msg_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* body_ctrlegc: body_egc's shell (page 0 arm), GVRAM accesses replaced by register ops. */
body_ctrlegc:
    mov     bx, [g_count]
bce_sprite:
    mov     ax, bx
    shl     ax, 1
    and     ax, 0x3FFE
    mov     di, ax
    mov     dx, 16
bce_row:
    mov     ax, 0xFFFF
    cmp     byte ptr [egc_rw], 0
    je      bce_write
    cmp     byte ptr [egc_page], 0
    je      bce_read
bce_read:
    mov     es, [plane_seg0]
    mov     ax, di
bce_write:
    cmp     byte ptr [egc_page], 0
    je      bce_store
bce_store:
    mov     es, [plane_seg0]
    or      ax, 0
    add     di, 80
    dec     dx
    jnz     bce_row
    dec     bx
    jnz     bce_sprite
    ret

/* ---- EGC machinery, verbatim from gfxbenc2.s ---- */
/* egc_on: master.lib EGC_ON - FF2 num 3 (register-write enable) on, FF2 num 2 (the EGC
   extended mode) on, then 0x7C bit 7 (the GRCG CG mode the real gate ANDs). FF2 num 3 off
   again; the 0x4A0 register file is written separately. */
egc_on:
    mov     dx, 0x006A
    mov     al, 0x07
    out     dx, al
    mov     al, 0x05
    out     dx, al
    mov     dx, 0x007C
    mov     al, 0x80
    out     dx, al
    mov     dx, 0x006A
    mov     al, 0x06
    out     dx, al
    ret

/* egc_off: the inverse - GRCG off, FF2 num 2 off. */
egc_off:
    mov     dx, 0x007C
    xor     al, al
    out     dx, al
    mov     dx, 0x006A
    mov     al, 0x07
    out     dx, al
    mov     al, 0x04
    out     dx, al
    mov     al, 0x06
    out     dx, al
    ret

/* egc_prog: write the 0x4A0-0x4AF register file from the egc_v_* variables. The write
   enable is on for the whole block so a machine that also gates the file on it is covered;
   the mask (0x4A8) is written after the colour field (0x4A2) because bits 14:13 of 0x4A2
   non-zero make the mask read-only. */
egc_prog:
    mov     dx, 0x006A
    mov     al, 0x07
    out     dx, al
    mov     dx, 0x04A0
    mov     ax, [egc_v_access]
    out     dx, ax
    mov     dx, 0x04A2
    mov     ax, [egc_v_fgbg]
    out     dx, ax
    mov     dx, 0x04A4
    mov     ax, [egc_v_ope]
    out     dx, ax
    mov     dx, 0x04A6
    mov     ax, [egc_v_fg]
    out     dx, ax
    mov     dx, 0x04A8
    mov     ax, [egc_v_mask]
    out     dx, ax
    mov     dx, 0x04AC
    mov     ax, [egc_v_sft]
    out     dx, ax
    mov     dx, 0x04AE
    mov     ax, [egc_v_leng]
    out     dx, ax
    mov     dx, 0x006A
    mov     al, 0x06
    out     dx, al
    ret

/* egc_page_set: write [egc_pg] to the access-page port 0xA6. Preserves AX. */
egc_page_set:
    push    ax
    push    dx
    mov     dx, 0x00A6
    mov     al, [egc_pg]
    out     dx, al
    pop     dx
    pop     ax
    ret

/* body_egc: [g_count] sprites; per sprite 16 rows; per row one EGC unit. [egc_rw]=1 reads
   the source (which latches the shifter/pattern) then writes; [egc_rw]=0 is a write-only
   fill/ROP feed. [egc_page]=1 selects page 1 for the read and page 0 for the write (the
   page1->page0 copy gfx_scene phase B issues); 0 keeps one page. */
body_egc:
    mov     bx, [g_count]
be_sprite:
    mov     ax, bx
    shl     ax, 1
    and     ax, 0x3FFE
    mov     di, ax
    mov     dx, 16
be_row:
    mov     ax, 0xFFFF                  /* the write-only default datum */
    cmp     byte ptr [egc_rw], 0
    je      be_write
    cmp     byte ptr [egc_page], 0
    je      be_read
    mov     byte ptr [egc_pg], 1
    call    egc_page_set
be_read:
    mov     es, [plane_seg0]
    mov     ax, es:[di]
be_write:
    cmp     byte ptr [egc_page], 0
    je      be_store
    mov     byte ptr [egc_pg], 0
    call    egc_page_set
be_store:
    mov     es, [plane_seg0]
    mov     es:[di], ax
    add     di, 80
    dec     dx
    jnz     be_row
    dec     bx
    jnz     be_sprite
    ret


/* ==================================================================== */
/* the timing harness                                                   */
/* ==================================================================== */

/* run_case: SI = label string. Times body pointed to by [rc_body] once, in a cli window,
   then prints `GFX2 <label> UNITS=.. ARTIC=.. CLK50=.. PER=..`. */
run_case:
    push    si
    cli
    call    artic_read
    mov     dword ptr [t0], eax
    call    word ptr [rc_body]
    call    artic_read
    mov     dword ptr [t1], eax
    sti
    pop     si
    call    report
    ret

/* report: SI = label; t0/t1/rc_units set. Prints one case line. */
report:
    push    si
    mov     si, offset msg_tag
    call    puts
    pop     si
    call    puts

    mov     eax, dword ptr [t1]
    sub     eax, dword ptr [t0]
    mov     dword ptr [g_delta], eax

    mov     si, offset msg_units
    call    puts
    mov     eax, dword ptr [rc_units]
    call    putdec32

    mov     si, offset msg_artic
    call    puts
    mov     eax, dword ptr [g_delta]
    call    putdec32

    /* CLK50 = ARTIC * 50000000 / 307200 */
    mov     eax, dword ptr [g_delta]
    mov     edx, 50000000
    mul     edx
    mov     ecx, 307200
    div     ecx
    mov     dword ptr [g_clk], eax
    mov     si, offset msg_clk
    call    puts
    call    putdec32

    /* PER = CLK50 * 1000 / UNITS, in milli-clk_sys per unit */
    mov     eax, dword ptr [g_clk]
    mov     ecx, 1000
    mul     ecx
    mov     ecx, dword ptr [rc_units]
    div     ecx
    mov     si, offset msg_per
    call    puts
    call    putdec32

    mov     si, offset msg_nl
    call    puts
    ret

/* cleanup: leave the EGC, the GRCG and the 0xA6 access page in their off/idle state. */
cleanup:
    call    egc_off
    mov     dx, 0x00A6
    xor     al, al
    out     dx, al
    ret

/* ------------------------------------------------------------------ */
/* artic_read: EAX = the 24-bit free-running counter (307200 Hz).       */
/* The high byte is at 005F: 005D and 005E mirror cnt[15:8], so a read */
/* of 005E would inflate every delta ~513x.                             */
/* ------------------------------------------------------------------ */
artic_read:
    push    dx
    push    bx
    push    cx
    mov     dx, 0x005c
    in      ax, dx
    movzx   ebx, ax
    mov     dx, 0x005f
    in      al, dx
    movzx   ecx, al
    mov     dx, 0x005c
    in      ax, dx
    cmp     ax, bx
    jae     ar_nowrap
    inc     ecx
ar_nowrap:
    movzx   eax, ax
    shl     ecx, 16
    or      eax, ecx
    pop     cx
    pop     bx
    pop     dx
    ret

/* ------------------------------------------------------------------ */
/* output                                                              */
/* ------------------------------------------------------------------ */
putc:                               /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret

puts:                               /* DS:SI, NUL terminated */
    push    ax
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
    pop     ax
    ret

/* putlns: DS:SI -> a table of near pointers to strings, terminated by a 0 word.
   Prints each line in turn. */
putlns:
    push    bx
    push    si
pln_loop:
    mov     bx, [si]
    test    bx, bx
    jz      pln_done
    push    si
    mov     si, bx
    call    puts
    pop     si
    add     si, 2
    jmp     pln_loop
pln_done:
    pop     si
    pop     bx
    ret

/* putdec32: print EAX as unsigned decimal, no leading zero suppression. */
putdec32:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 10
    xor     ecx, ecx
pd_div:
    xor     edx, edx
    div     ebx
    push    edx
    inc     ecx
    test    eax, eax
    jnz     pd_div
pd_out:
    pop     edx
    add     dl, '0'
    mov     al, dl
    mov     dl, al
    call    putc
    dec     ecx
    jnz     pd_out
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* ------------------------------------------------------------------ */
/* data                                                                */

/* ------------------------------------------------------------------ */
/* data                                                                */
/* ------------------------------------------------------------------ */
    .balign 4
t0:         .long 0
t1:         .long 0
g_delta:    .long 0
g_clk:      .long 0
rc_units:   .long 0
rc_body:    .word 0
g_count:    .word 0
egc_rw:     .byte 0
egc_page:   .byte 0
egc_pg:     .byte 0

egc_v_access: .word 0xFFF0
egc_v_fgbg:   .word 0x00FF
egc_v_ope:    .word 0x3100
egc_v_fg:     .word 0x0000
egc_v_mask:   .word 0xFFFF
egc_v_sft:    .word 0x0000
egc_v_leng:   .word 0x000F

plane_seg0:   .word 0xA800

msg_banner_tab:
    .word   msg_b0, msg_b1, msg_b2, msg_b3, msg_b4, 0
msg_b0: .asciz "BEGIN:EGCPLANE\r\n"
msg_b1: .asciz "EGCPLANE: EGC time vs enabled planes (0x4A0 = FFFE/FFFC/FFF8/FFF0 = 1/2/3/4 planes).\r\n"
msg_b2: .asciz "  cli-timed bodies around ARTIC 005C/005F = 307200 Hz; PER = milli-clk_sys at 50 MHz.\r\n"
msg_b3: .asciz "  Redirect stdout to a file. GVRAM is scribbled; EGC/GRCG end off, 0xA6 = 0.\r\n"
msg_b4: .asciz "  Disk: untouched.\r\n"

c_1400: .asciz "; EGC1400P1..P4 = 0x1400 solid fill, write only, 1..4 planes, 16 units/sprite\r\n"
c_0cf0: .asciz "; EGC0CF0P1..P4 = 0x0CF0 ROP F0 write feed, write only, 1..4 planes\r\n"
c_3100: .asciz "; EGC3100SPP1..P4 = 0x3100 put, same page, read+write, 1..4 planes\r\n"
c_28f0: .asciz "; EGC28F0SPP1..P4 = 0x28F0 shifted copy sft=2, same page, read+write, 1..4 planes\r\n"
c_ctrl: .asciz "; CTRLEW / CTRLER = body_egc loop shell (write-only / read+write), accesses replaced\r\n"

lbl_ctrlew: .asciz "CTRLEW"
lbl_ctrler: .asciz "CTRLER"
lbl_EGC1400P1: .asciz "EGC1400P1"
lbl_EGC1400P2: .asciz "EGC1400P2"
lbl_EGC1400P3: .asciz "EGC1400P3"
lbl_EGC1400P4: .asciz "EGC1400P4"
lbl_EGC0CF0P1: .asciz "EGC0CF0P1"
lbl_EGC0CF0P2: .asciz "EGC0CF0P2"
lbl_EGC0CF0P3: .asciz "EGC0CF0P3"
lbl_EGC0CF0P4: .asciz "EGC0CF0P4"
lbl_EGC3100SPP1: .asciz "EGC3100SPP1"
lbl_EGC3100SPP2: .asciz "EGC3100SPP2"
lbl_EGC3100SPP3: .asciz "EGC3100SPP3"
lbl_EGC3100SPP4: .asciz "EGC3100SPP4"
lbl_EGC28F0SPP1: .asciz "EGC28F0SPP1"
lbl_EGC28F0SPP2: .asciz "EGC28F0SPP2"
lbl_EGC28F0SPP3: .asciz "EGC28F0SPP3"
lbl_EGC28F0SPP4: .asciz "EGC28F0SPP4"

msg_tag:    .asciz "EGCP "
msg_units:  .asciz " UNITS="
msg_artic:  .asciz " ARTIC="
msg_clk:    .asciz " CLK50="
msg_per:    .asciz " PER="
msg_nl:     .asciz "\r\n"
msg_end:
    .asciz "END:EGCPLANE\r\n"
