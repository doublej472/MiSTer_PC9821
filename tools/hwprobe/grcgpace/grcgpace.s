/* grcgpace.s - the real PC-9821's walk-bound GRCG store shapes, timed.
 *
 *   GRCGPACE > GRCGPACE.TXT          (or RUNPACE.BAT)
 *
 * WHY. Trade T68 latches `pc9821_gvram_arb`'s port-A
 * presentation at the accept. At the core's 80 MHz it costs +0 on every
 * period-bound shape and +12.5 ns on the two WALK-bound ones:
 *
 *   32-bit GRCG RMW store   112.5 -> 125.0 ns   (machine row: none; the 16-bit
 *                                                RMW row is 103.9 ns, so two of
 *                                                them would be 207.8 ns)
 *   GRCG TDW 32-bit burst   137.5 -> 150.0 ns   (machine gross 16-bit TDW row
 *                                                183.3 ns, docs/probes/GFX2.TXT)
 *
 * Both machine rows that exist are 16-BIT (`rep stosw`); the 32-bit shapes have
 * no capture. This probe measures them on the machine, with the 16-bit shapes
 * and the plain 32-bit store beside them as controls:
 *
 *   PLAIN_W_LOOP      plain 16-bit plane-0 store loop, GRCG off
 *   GRCG_RMW_W_LOOP   the same loop with 0x7C <- 0xC0 (GRCG read-modify-write)
 *   PLAIN_D_LOOP      plain 32-bit store loop, GRCG off
 *   GRCG_RMW_D_LOOP   the same loop with the GRCG armed 0xC0
 *   CTRL_D_LOOP       PLAIN_D_LOOP's exact shell, store replaced by `or eax,0`
 *   PLAIN_W_REP       `rep stosw` to plane 0, GRCG off (the GFX2 shape)
 *   TDW_W_REP         `rep stosw` with 0x7C <- 0x80 (GRCG TDW)
 *   PLAIN_D_REP       `rep stosd` to plane 0, GRCG off
 *   TDW_D_REP         `rep stosd` with 0x7C <- 0x80
 *
 * Every shape performs 65 536 stores, each timed under `cli` with the ARTIC
 * counter (0x5C/0x5F, 307 200 Hz), three runs. The line prints the ARTIC delta,
 * total ns, ns per store and ns per 16-bit word equivalent (a 32-bit store counts
 * as two). The decoder (`grcgpace_decode.py`) means the three runs, subtracts the
 * loop shell from the loop shapes, and prints the table beside the core's numbers.
 *
 * The GRCG is armed through 0x7C and its four tile bytes 0x7E are zero (the tile
 * colour is not the subject; the transfer width is). `rep stosd`/`stosw` reset DI
 * to 0 after every 32 KiB so a burst never crosses out of the plane-0 window
 * 0xA8000-0xAFFFF into plane 1.
 *
 * SAFETY / RESTORE. No disk access except DOS stdout; no memory writes outside
 * the plane-0 GVRAM window (0xA8000-0xAFFFF). The screen may change if the
 * display is showing GVRAM; redirect stdout. At the end the GRCG is off (0x7C
 * <- 0), the EGC bit is restored if it was found set (it is normally clear at a
 * fresh DOS prompt), and the run prints `RESTORE`. 0xA6 is never touched.
 *
 * BUILD: make -C tools/hwprobe grcgpace/grcgpace.com
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

    .equ STORES, 65536
    .equ BURSTS, 8
    .equ INNER_D, 8192                 /* 32 KiB per burst */
    .equ INNER_W, 8192                 /* 16 KiB per burst */

_start:
    pushf
    cld                             /* rep stos* requires DF=0; restored at exit */
    mov     si, offset msg_begin
    call    puts

    /* EGC guard: at a fresh prompt the bit is clear; record and clear it if not,
     * because GRCG CG mode (0x7C bit 7) would otherwise hand the stores to it. */
    mov     al, 0x07
    call    query9a0
    mov     [egc_found], al
    mov     al, 0x08
    call    query9a0
    mov     [wren_found], al
    mov     si, offset msg_egc
    call    puts
    mov     al, [egc_found]
    call    puthex8
    mov     si, offset msg_wren
    call    puts
    mov     al, [wren_found]
    call    puthex8
    call    crlf
    cmp     byte ptr [egc_found], 0
    je      egc_done
    call    egc_off

egc_done:
    call    shape_plain_w_loop
    call    shape_grcg_rmw_w_loop
    call    shape_plain_d_loop
    call    shape_grcg_rmw_d_loop
    call    shape_ctrl_d_loop
    call    shape_plain_w_rep
    call    shape_tdw_w_rep
    call    shape_plain_d_rep
    call    shape_tdw_d_rep

    call    cleanup
    mov     si, offset msg_end
    call    puts
    popf
    mov     ax, 0x4C00
    int     0x21

/* ------------------------------------------------------------------ */
/* the shapes                                                          */
/* ------------------------------------------------------------------ */
shape_plain_w_loop:
    call    grcg_off
    mov     si, offset lbl_plain_w_loop
    xor     al, al
    mov     bx, offset body_w_loop
    mov     ecx, STORES
    mov     dx, 16
    jmp     do_shape

shape_grcg_rmw_w_loop:
    mov     si, offset lbl_grcg_rmw_w_loop
    mov     al, 0xC0
    mov     bx, offset body_w_loop
    mov     ecx, STORES
    mov     dx, 16
    jmp     do_shape

shape_plain_d_loop:
    call    grcg_off
    mov     si, offset lbl_plain_d_loop
    xor     al, al
    mov     bx, offset body_d_loop
    mov     ecx, STORES
    mov     dx, 32
    jmp     do_shape

shape_grcg_rmw_d_loop:
    mov     si, offset lbl_grcg_rmw_d_loop
    mov     al, 0xC0
    mov     bx, offset body_d_loop
    mov     ecx, STORES
    mov     dx, 32
    jmp     do_shape

shape_ctrl_d_loop:
    call    grcg_off
    mov     si, offset lbl_ctrl_d_loop
    xor     al, al
    mov     bx, offset body_ctrl_d_loop
    mov     ecx, STORES
    mov     dx, 32
    jmp     do_shape

shape_plain_w_rep:
    call    grcg_off
    mov     si, offset lbl_plain_w_rep
    xor     al, al
    mov     bx, offset body_rep_w
    mov     ecx, STORES
    mov     dx, 16
    jmp     do_shape

shape_tdw_w_rep:
    mov     si, offset lbl_tdw_w_rep
    mov     al, 0x80
    mov     bx, offset body_rep_w
    mov     ecx, STORES
    mov     dx, 16
    jmp     do_shape

shape_plain_d_rep:
    call    grcg_off
    mov     si, offset lbl_plain_d_rep
    xor     al, al
    mov     bx, offset body_rep_d
    mov     ecx, STORES
    mov     dx, 32
    jmp     do_shape

shape_tdw_d_rep:
    mov     si, offset lbl_tdw_d_rep
    mov     al, 0x80
    mov     bx, offset body_rep_d
    mov     ecx, STORES
    mov     dx, 32
    jmp     do_shape

/* do_shape: SI tag, AL GRCG mode (0 = off), BX body, ECX stores, DX width. */
do_shape:
    mov     [g_tag], si
    mov     [g_body], bx
    mov     [g_stores], ecx
    mov     [g_width], dx
    mov     [g_mode], al
    test    al, al
    jz      ds_off
    call    grcg_arm
    jmp     ds_run
ds_off:
    call    grcg_off
ds_run:
    mov     byte ptr [g_run], 0
ds_loop:
    inc     byte ptr [g_run]
    cli
    call    artic_read
    mov     [t0], eax
    call    word ptr [g_body]
    call    artic_read
    mov     [t1], eax
    sti
    call    report
    cmp     byte ptr [g_run], 3
    jb      ds_loop
    ret

/* ------------------------------------------------------------------ */
/* the timed bodies (all: plane 0, 8 bursts, 8192 inner stores)        */
/* ------------------------------------------------------------------ */
body_w_loop:
    push    ax
    push    bx
    push    cx
    push    di
    push    es
    mov     ax, 0xA800
    mov     es, ax
    mov     ax, 0x1234
    mov     bx, BURSTS
bwl_outer:
    xor     di, di
    mov     cx, INNER_W
bwl_inner:
    mov     es:[di], ax
    add     di, 2
    dec     cx
    jnz     bwl_inner
    dec     bx
    jnz     bwl_outer
    pop     es
    pop     di
    pop     cx
    pop     bx
    pop     ax
    ret

body_d_loop:
    push    eax
    push    bx
    push    cx
    push    di
    push    es
    mov     ax, 0xA800
    mov     es, ax
    mov     eax, 0x12345678
    mov     bx, BURSTS
bdl_outer:
    xor     di, di
    mov     cx, INNER_D
bdl_inner:
    mov     es:[di], eax
    add     di, 4
    dec     cx
    jnz     bdl_inner
    dec     bx
    jnz     bdl_outer
    pop     es
    pop     di
    pop     cx
    pop     bx
    pop     eax
    ret

body_ctrl_d_loop:
    push    eax
    push    bx
    push    cx
    push    di
    push    es
    mov     ax, 0xA800
    mov     es, ax
    mov     eax, 0x12345678
    mov     bx, BURSTS
bcd_outer:
    xor     di, di
    mov     cx, INNER_D
bcd_inner:
    or      eax, 0
    add     di, 4
    dec     cx
    jnz     bcd_inner
    dec     bx
    jnz     bcd_outer
    pop     es
    pop     di
    pop     cx
    pop     bx
    pop     eax
    ret

body_rep_w:
    push    ax
    push    bx
    push    cx
    push    di
    push    es
    mov     ax, 0xA800
    mov     es, ax
    mov     ax, 0x1234
    mov     bx, BURSTS
brw_outer:
    xor     di, di
    mov     cx, INNER_W
    rep     stosw
    dec     bx
    jnz     brw_outer
    pop     es
    pop     di
    pop     cx
    pop     bx
    pop     ax
    ret

body_rep_d:
    push    eax
    push    bx
    push    cx
    push    di
    push    es
    mov     ax, 0xA800
    mov     es, ax
    mov     eax, 0x12345678
    mov     bx, BURSTS
brd_outer:
    xor     di, di
    mov     cx, INNER_D
    rep     stosd
    dec     bx
    jnz     brd_outer
    pop     es
    pop     di
    pop     cx
    pop     bx
    pop     eax
    ret

/* ------------------------------------------------------------------ */
/* report: one line per shape per run                                   */
/* ------------------------------------------------------------------ */
report:
    mov     eax, [t1]
    sub     eax, [t0]
    and     eax, 0x00FFFFFF
    mov     [g_ticks], eax

    mov     si, offset msg_shape
    call    puts
    mov     si, [g_tag]
    call    puts
    mov     si, offset msg_mode
    call    puts
    mov     al, [g_mode]
    call    puthex8
    mov     si, offset msg_width
    call    puts
    movzx   eax, word ptr [g_width]
    call    putdec32
    mov     si, offset msg_stores
    call    puts
    mov     eax, [g_stores]
    call    putdec32
    mov     si, offset msg_run
    call    puts
    movzx   eax, byte ptr [g_run]
    call    putdec32
    mov     si, offset msg_artic
    call    puts
    mov     eax, [g_ticks]
    call    putdec32

    /* total ns = ticks * 1e9 / 307200 */
    mov     eax, [g_ticks]
    mov     ecx, 1000000000
    mul     ecx
    mov     ecx, 307200
    div     ecx
    mov     [g_ns], eax
    mov     si, offset msg_nstotal
    call    puts
    mov     eax, [g_ns]
    call    putdec32

    /* ps per store = ns * 1000 / stores */
    mov     eax, [g_ns]
    mov     ecx, 1000
    mul     ecx
    mov     ecx, [g_stores]
    div     ecx
    mov     [g_ps], eax
    mov     si, offset msg_nsper
    call    puts
    mov     eax, [g_ps]
    call    putfixed3

    /* ns per 16-bit word equivalent: a 32-bit store counts as two words */
    mov     eax, [g_ps]
    cmp     word ptr [g_width], 32
    jne     rp_psword
    shr     eax, 1
rp_psword:
    mov     si, offset msg_nsword
    call    puts
    call    putfixed3

    call    crlf
    ret

/* ------------------------------------------------------------------ */
/* GRCG / EGC control                                                   */
/* ------------------------------------------------------------------ */
grcg_arm:                               /* AL = mode; tile bytes 0x7E = 0 */
    push    ax
    push    dx
    mov     dx, 0x007C
    out     dx, al
    mov     dx, 0x007E
    xor     al, al
    out     dx, al
    out     dx, al
    out     dx, al
    out     dx, al
    pop     dx
    pop     ax
    ret

grcg_off:
    push    ax
    push    dx
    mov     dx, 0x007C
    xor     al, al
    out     dx, al
    pop     dx
    pop     ax
    ret

egc_off:                                /* FF2 num 2 off, wren bracketed */
    push    ax
    push    dx
    mov     dx, 0x006A
    mov     al, 0x07
    out     dx, al
    mov     al, 0x04
    out     dx, al
    mov     al, 0x06
    out     dx, al
    pop     dx
    pop     ax
    ret

cleanup:
    call    grcg_off
    cmp     byte ptr [egc_found], 0
    je      cu_wren
    /* restore the EGC bit that was found set (num 3 must be on to write it) */
    mov     dx, 0x006A
    mov     al, 0x07
    out     dx, al
    mov     al, 0x05
    out     dx, al
cu_wren:
    mov     dx, 0x006A
    cmp     byte ptr [wren_found], 0
    je      cu_wren_off
    mov     al, 0x07
    out     dx, al
    jmp     cu_done
cu_wren_off:
    mov     al, 0x06
    out     dx, al
cu_done:
    mov     si, offset msg_restore
    call    puts
    mov     al, [egc_found]
    call    puthex8
    call    crlf
    ret

/* query9a0: AL = index, returns AL = query byte. */
query9a0:
    push    dx
    mov     dx, 0x09A0
    out     dx, al
    out     0x5F, al
    in      al, dx
    pop     dx
    ret

/* ------------------------------------------------------------------ */
/* the ARTIC counter                                                    */
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
putc:
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

puts:
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

puthex8:
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
    push    dx
    inc     ecx
    test    eax, eax
    jnz     pd_div
pd_out:
    pop     dx
    add     dl, '0'
    call    putc
    dec     ecx
    jnz     pd_out
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* putfixed3: EAX = value * 1000 -> `N.FFF` */
putfixed3:
    push    edx
    push    ebx
    mov     ebx, 1000
    xor     edx, edx
    div     ebx
    push    edx
    call    putdec32
    mov     dl, '.'
    call    putc
    pop     eax
    call    putdec3
    pop     ebx
    pop     edx
    ret

putdec3:                                /* EAX = 0..999, always three digits */
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 100
    mov     cx, 3
pd3_loop:
    xor     edx, edx
    div     ebx
    push    edx
    add     al, '0'
    mov     dl, al
    call    putc
    pop     eax
    push    eax
    mov     eax, ebx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    mov     ebx, eax
    pop     eax
    loop    pd3_loop
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* ------------------------------------------------------------------ */
    .balign 4
t0:        .long 0
t1:        .long 0
g_ticks:   .long 0
g_ns:      .long 0
g_ps:      .long 0
g_stores:  .long 0
g_tag:     .word 0
g_body:    .word 0
g_width:   .word 0
g_mode:    .byte 0
g_run:     .byte 0
egc_found: .byte 0
wren_found: .byte 0

lbl_plain_w_loop:    .asciz "PLAIN_W_LOOP"
lbl_grcg_rmw_w_loop: .asciz "GRCG_RMW_W_LOOP"
lbl_plain_d_loop:    .asciz "PLAIN_D_LOOP"
lbl_grcg_rmw_d_loop: .asciz "GRCG_RMW_D_LOOP"
lbl_ctrl_d_loop:     .asciz "CTRL_D_LOOP"
lbl_plain_w_rep:     .asciz "PLAIN_W_REP"
lbl_tdw_w_rep:       .asciz "TDW_W_REP"
lbl_plain_d_rep:     .asciz "PLAIN_D_REP"
lbl_tdw_d_rep:       .asciz "TDW_D_REP"

msg_begin:   .asciz "BEGIN:GRCGPACE artic_hz=307200 stores=65536 runs=3\r\n"
msg_egc:     .asciz "EGC found="
msg_wren:    .asciz " wren="
msg_shape:   .asciz "SHAPE="
msg_mode:    .asciz " MODE="
msg_width:   .asciz " WIDTH="
msg_stores:  .asciz " STORES="
msg_run:     .asciz " RUN="
msg_artic:   .asciz " ARTIC="
msg_nstotal: .asciz " NS_TOTAL="
msg_nsper:   .asciz " NS_PER="
msg_nsword:  .asciz " NS_PER_WORD="
msg_restore: .asciz "RESTORE 7C=00 EGC_found="
msg_end:     .asciz "END:GRCGPACE\r\n"
msg_crlf:    .asciz "\r\n"
