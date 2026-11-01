/* gfxbenc2.s - a per-subsystem real-machine graphics benchmark for the PC-9821.
 *
 * WHY THIS EXISTS. The MiSTer core's graphics benches (tests/pc9821/tb_pc9821_gfx_scene.sv
 * and tb_pc9821_sprite_scene.sv, driven by tools/bench.py) report a per-sprite cost for
 * each draw shape - the plain plane-window draw (A, 1,952 clk_sys/sprite), the EGC 0x3100
 * blit (B, 343), the busy scene (D, 3,319). Those are the CORE's numbers. This program is
 * the machine's answer to the same question: it issues each shape on a real Xe10 and times
 * it with the ARTIC counter, so the two can be diffed directly instead of through a model.
 *
 * WHAT IT MEASURES, one TIMED section each (a `cli` window around the whole body, the ARTIC
 * counter 005C/005F at 307200 Hz bracketing it):
 *
 *   1. PLANE-WINDOW DRAW  - the CPU writing one word per column to the GVRAM plane windows
 *                           0xA8000/0xB0000/0xB8000/0xE0000, for 1, 2, 3 and 4 planes, as a
 *                           one-word-then-advance loop (NOT `rep stosw`), plus a 4-plane
 *                           read-modify-write that mirrors gfx_scene phase A's scene_draw.
 *   2. EGC BLIT           - the EGC 0x3100 put (page 1 -> page 0), the same put same-page
 *                           (isolates the 0xA6 page-switch cost), a shifted copy (0x28F0,
 *                           sft=2), a solid colour fill (0x1400) and an ROP F0 write feed
 *                           (0x0CF0) - the Touhou shapes gfx_scene phase B models.
 *   3. GRCG               - a tile clear (TDW, 0x7C=0x80), the RMW erase gfx_scene phase D's
 *                           scene_erase arms (0x7C=0xC0), and a plain two-plane copy.
 *   4. GDC TEXT           - a text-plane fill (TRAM code + attribute words at 0xA0000/
 *                           0xA2000), a CG font read through port 0xA9, and a combined
 *                           per-line render that does both.
 *
 * OUTPUT. One labelled line per case:
 *
 *   GFX2 <TAG> UNITS=<n> ARTIC=<ticks> CLK50=<total> PER=<per-unit>
 *
 * UNITS is the case's own count (sprites for sections 1-3, lines/glyphs for section 4).
 * ARTIC is the raw 24-bit counter delta. CLK50 = ARTIC * 50000000 / 307200, i.e. the delta
 * in clk_sys at the core's 50 MHz, using the DOCUMENTED ARTIC rate 307200 Hz (the same
 * anchor the ioprobe/egcport timing probes measure; one measured it 0 per-mille
 * off). PER = CLK50 * 1000 / UNITS, in MILLI-clk_sys per unit, so 1,952 clk_sys/sprite reads
 * as PER=1952000. A `; <TAG> = ...` comment precedes each case and names the shape.
 *
 * RUN IT REDIRECTED:
 *
 *   GFXBENC2 > GFX2.TXT
 *
 * The text-TRAM section scribbles the visible console (0xA0000 is the text plane), so stdout
 * must go to a file. The GVRAM is scribbled by design (this is a graphics benchmark); the
 * EGC and GRCG are left OFF and the 0xA6 access page is restored to 0 at the end. READ-ONLY
 * with respect to the disk.
 *
 * BUILD: ./build_gfxbenc2.sh  (as/ld/objcopy, a .COM linked at 0x100, like build_gfxbench.sh)
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

/* Iterations per case: enough that the ARTIC delta is thousands of ticks, small enough
   that every cli-timed window stays short (the text and EGC cases are port-bound, so their
   counts are lower) and the whole run is a few seconds on a 486. */
    .equ PW_SPRITES,   2000
    .equ EGC_SPRITES,  1000
    .equ GRCG_SPRITES, 2000
    .equ TRAM_LINES,   1000
    .equ FONT_GLYPHS,  500
    .equ TXT_LINES,    100

_start:
    mov     si, offset msg_banner_tab
    call    putlns

    /* A prior partial run could leave the EGC/GRCG armed; section 1 must be the plain path. */
    call    egc_off

    /* ---- 1. PLANE-WINDOW DRAW (gfx_scene A) ---- */
    mov     si, offset msg_sec1
    call    puts
    call    case_pw1
    call    case_pw2
    call    case_pw3
    call    case_pw4
    call    case_ctrlpw
    call    case_pw4rw

    /* ---- 2. EGC BLIT (gfx_scene B) ---- */
    mov     si, offset msg_sec2
    call    puts
    call    case_egc3100
    call    case_egc3100sp
    call    case_egc28f0
    call    case_egc1400
    call    case_egc0cf0

    /* ---- 3. GRCG (graphics clear / scroll) ---- */
    mov     si, offset msg_sec3
    call    puts
    call    case_ctrlgc
    call    case_grcg_tdw
    call    case_grcg_rmw
    call    case_ctrlcp
    call    case_plane_copy

    /* ---- 4. GDC TEXT ---- */
    mov     si, offset msg_sec4
    call    puts
    call    case_tram
    call    case_font
    call    case_textline

    call    cleanup
    mov     si, offset msg_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* ==================================================================== */
/* SECTION 1 - the plane-window draw                                    */
/* ==================================================================== */

/* body_pw: [g_count] sprites. Per sprite: 16 rows; per row: [nplanes] plane windows,
   each getting one word. [pw_rw]=1 reads each word first and ORs 0xF0F0, the read-modify-
   write gfx_scene's scene_draw issues; [pw_rw]=0 is the bare store. */
body_pw:
    mov     bx, [g_count]
bpw_sprite:
    mov     ax, bx                      /* spread the writes across the bank: base */
    shl     ax, 1
    and     ax, 0x3FFE
    mov     di, ax
    mov     dx, 16
bpw_row:
    mov     si, offset plane_tab
    mov     cx, [nplanes]
bpw_plane:
    mov     es, [si]
    cmp     byte ptr [pw_rw], 0
    je      bpw_store
    mov     ax, es:[di]
    or      ax, 0xF0F0
    jmp     bpw_put
bpw_store:
    mov     ax, 0xF0F0
bpw_put:
    mov     es:[di], ax
    add     si, 2
    loop    bpw_plane
    add     di, 80                      /* one GDC line of one plane = 80 bytes */
    dec     dx
    jnz     bpw_row
    dec     bx
    jnz     bpw_sprite
    ret

case_pw1:
    mov     si, offset c_pw1
    call    puts
    mov     word ptr [g_count], PW_SPRITES
    mov     word ptr [nplanes], 1
    mov     byte ptr [pw_rw], 0
    mov     dword ptr [rc_units], PW_SPRITES
    mov     word ptr [rc_body], offset body_pw
    mov     si, offset lbl_pw1
    call    run_case
    ret

case_pw2:
    mov     si, offset c_pw2
    call    puts
    mov     word ptr [g_count], PW_SPRITES
    mov     word ptr [nplanes], 2
    mov     byte ptr [pw_rw], 0
    mov     dword ptr [rc_units], PW_SPRITES
    mov     word ptr [rc_body], offset body_pw
    mov     si, offset lbl_pw2
    call    run_case
    ret

case_pw3:
    mov     si, offset c_pw3
    call    puts
    mov     word ptr [g_count], PW_SPRITES
    mov     word ptr [nplanes], 3
    mov     byte ptr [pw_rw], 0
    mov     dword ptr [rc_units], PW_SPRITES
    mov     word ptr [rc_body], offset body_pw
    mov     si, offset lbl_pw3
    call    run_case
    ret

case_pw4:
    mov     si, offset c_pw4
    call    puts
    mov     word ptr [g_count], PW_SPRITES
    mov     word ptr [nplanes], 4
    mov     byte ptr [pw_rw], 0
    mov     dword ptr [rc_units], PW_SPRITES
    mov     word ptr [rc_body], offset body_pw
    mov     si, offset lbl_pw4
    call    run_case
    ret

case_pw4rw:
    mov     si, offset c_pw4rw
    call    puts
    mov     word ptr [g_count], PW_SPRITES
    mov     word ptr [nplanes], 4
    mov     byte ptr [pw_rw], 1
    mov     dword ptr [rc_units], PW_SPRITES
    mov     word ptr [rc_body], offset body_pw
    mov     si, offset lbl_pw4rw
    call    run_case
    ret

/* case_ctrlpw: the loop-shell CONTROL for the PW family (the ladder discipline of
 * ioprobe.s: the same loop with each GVRAM access replaced by a register op).
 * It mirrors PW4RW exactly (4-plane walk, read+write arm) so PW4RW's GVRAM cost
 * is its row minus this one; PW1-PW4 net approximately (same shell per plane).
 * Place it immediately before its exact pair. */
case_ctrlpw:
    mov     si, offset c_ctrlpw
    call    puts
    mov     word ptr [g_count], PW_SPRITES
    mov     word ptr [nplanes], 4
    mov     byte ptr [pw_rw], 1
    mov     dword ptr [rc_units], PW_SPRITES
    mov     word ptr [rc_body], offset body_ctrlpw
    mov     si, offset lbl_ctrlpw
    call    run_case
    ret

/* body_ctrlpw: body_pw's exact shell with the two GVRAM accesses replaced:
 * `mov ax, es:[di]` -> `mov ax, di` and `mov es:[di], ax` -> `or ax, 0` (a pure
 * ALU op - no register is free in the loop for a `mov`).  Everything else - the
 * per-sprite DI setup, the plane_tab walk, the segment loads, the row loop -
 * is byte-identical, so the subtraction leaves the GVRAM-window access cost. */
body_ctrlpw:
    mov     bx, [g_count]
bcw_sprite:
    mov     ax, bx
    shl     ax, 1
    and     ax, 0x3FFE
    mov     di, ax
    mov     dx, 16
bcw_row:
    mov     si, offset plane_tab
    mov     cx, [nplanes]
bcw_plane:
    mov     es, [si]
    cmp     byte ptr [pw_rw], 0
    je      bcw_store
    mov     ax, di
    or      ax, 0xF0F0
    jmp     bcw_put
bcw_store:
    mov     ax, 0xF0F0
bcw_put:
    or      ax, 0
    add     si, 2
    loop    bcw_plane
    add     di, 80
    dec     dx
    jnz     bcw_row
    dec     bx
    jnz     bcw_sprite
    ret

/* ==================================================================== */
/* SECTION 2 - the EGC blit                                             */
/* ==================================================================== */

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

case_egc3100:
    mov     si, offset c_egc3100
    call    puts
    call    egc_on
    mov     word ptr [egc_v_access], 0xFFF0
    mov     word ptr [egc_v_fgbg], 0x00FF
    mov     word ptr [egc_v_ope],  0x3100
    mov     word ptr [egc_v_fg],   0x0000
    mov     word ptr [egc_v_mask], 0xFFFF
    mov     word ptr [egc_v_sft],  0x0000
    mov     word ptr [egc_v_leng], 0x000F
    call    egc_prog
    mov     word ptr [g_count], EGC_SPRITES
    mov     byte ptr [egc_rw], 1
    mov     byte ptr [egc_page], 1
    mov     dword ptr [rc_units], EGC_SPRITES
    mov     word ptr [rc_body], offset body_egc
    mov     si, offset lbl_egc3100
    call    run_case
    ret

case_egc3100sp:
    mov     si, offset c_egc3100sp
    call    puts
    /* EGC is already enabled and 0x4A4 still holds 0x3100 from the case above. */
    mov     word ptr [egc_v_ope], 0x3100
    call    egc_prog
    mov     word ptr [g_count], EGC_SPRITES
    mov     byte ptr [egc_rw], 1
    mov     byte ptr [egc_page], 0
    mov     dword ptr [rc_units], EGC_SPRITES
    mov     word ptr [rc_body], offset body_egc
    mov     si, offset lbl_egc3100sp
    call    run_case
    ret

case_egc28f0:
    mov     si, offset c_egc28f0
    call    puts
    mov     word ptr [egc_v_fgbg], 0x00FF
    mov     word ptr [egc_v_ope],  0x28F0
    mov     word ptr [egc_v_sft],  0x0002
    mov     word ptr [egc_v_leng], 0x000F
    call    egc_prog
    mov     word ptr [g_count], EGC_SPRITES
    mov     byte ptr [egc_rw], 1
    mov     byte ptr [egc_page], 1
    mov     dword ptr [rc_units], EGC_SPRITES
    mov     word ptr [rc_body], offset body_egc
    mov     si, offset lbl_egc28f0
    call    run_case
    ret

case_egc1400:
    mov     si, offset c_egc1400
    call    puts
    mov     word ptr [egc_v_fgbg], 0x40FF
    mov     word ptr [egc_v_ope],  0x1400
    mov     word ptr [egc_v_fg],   0x0009
    mov     word ptr [egc_v_sft],  0x0000
    mov     word ptr [egc_v_leng], 0x000F
    call    egc_prog
    mov     word ptr [g_count], EGC_SPRITES
    mov     byte ptr [egc_rw], 0
    mov     byte ptr [egc_page], 0
    mov     dword ptr [rc_units], EGC_SPRITES
    mov     word ptr [rc_body], offset body_egc
    mov     si, offset lbl_egc1400
    call    run_case
    ret

case_egc0cf0:
    mov     si, offset c_egc0cf0
    call    puts
    mov     word ptr [egc_v_fgbg], 0x00FF
    mov     word ptr [egc_v_ope],  0x0CF0
    mov     word ptr [egc_v_sft],  0x0000
    mov     word ptr [egc_v_leng], 0x000F
    call    egc_prog
    mov     word ptr [g_count], EGC_SPRITES
    mov     byte ptr [egc_rw], 0
    mov     byte ptr [egc_page], 0
    mov     dword ptr [rc_units], EGC_SPRITES
    mov     word ptr [rc_body], offset body_egc
    mov     si, offset lbl_egc0cf0
    call    run_case
    ret

/* ==================================================================== */
/* SECTION 3 - the GRCG                                                 */
/* ==================================================================== */

/* grcg_arm: AL = mode (0x80 TDW, 0xC0 RMW). A 0x7C write resets the tile pointer, so the
   four zero tile bytes that follow land B,R,G,E. */
grcg_arm:
    mov     dx, 0x007C
    out     dx, al
    mov     dx, 0x007E
    xor     al, al
    out     dx, al
    out     dx, al
    out     dx, al
    out     dx, al
    ret

/* grcg_off: mode 0, the GRCG stops owning stores. */
grcg_off:
    mov     dx, 0x007C
    xor     al, al
    out     dx, al
    ret

/* body_grcg: [g_count] sprites; per sprite 16 rows; per row one store through the plane-0
   window. With the GRCG armed that one store expands to all four planes. [grcg_copy]=1 is
   the GRCG-inactive shape: read plane 0, store to plane 1. */
body_grcg:
    mov     bx, [g_count]
bg_sprite:
    mov     ax, bx
    shl     ax, 1
    and     ax, 0x3FFE
    mov     di, ax
    mov     dx, 16
bg_row:
    mov     es, [plane_seg0]
    cmp     byte ptr [grcg_copy], 0
    je      bg_fill
    mov     ax, es:[di]
    mov     es, [plane_seg1]
    mov     es:[di], ax
    jmp     bg_next
bg_fill:
    mov     ax, 0xF0F0
    mov     es:[di], ax
bg_next:
    add     di, 80
    dec     dx
    jnz     bg_row
    dec     bx
    jnz     bg_sprite
    ret

case_grcg_tdw:
    mov     si, offset c_grcg_tdw
    call    puts
    call    egc_off                       /* the EGC would otherwise own these stores */
    mov     al, 0x80
    call    grcg_arm
    mov     word ptr [g_count], GRCG_SPRITES
    mov     byte ptr [grcg_copy], 0
    mov     dword ptr [rc_units], GRCG_SPRITES
    mov     word ptr [rc_body], offset body_grcg
    mov     si, offset lbl_grcg_tdw
    call    run_case
    ret

case_grcg_rmw:
    mov     si, offset c_grcg_rmw
    call    puts
    mov     al, 0xC0
    call    grcg_arm
    mov     word ptr [g_count], GRCG_SPRITES
    mov     byte ptr [grcg_copy], 0
    mov     dword ptr [rc_units], GRCG_SPRITES
    mov     word ptr [rc_body], offset body_grcg
    mov     si, offset lbl_grcg_rmw
    call    run_case
    ret

/* case_ctrlgc: the loop-shell CONTROL for the GRCG fill rows (GRCG_TDW and
 * GRCG_RMW share body_grcg's fill arm).  body_ctrlgc is that arm's exact shell
 * (including the grcg_copy test) with the GVRAM store replaced by `or ax, 0`;
 * GRCG_RMW's read-merge-write cost per word is (its row - this row) / 16
 * stores per sprite. */
case_ctrlgc:
    mov     si, offset c_ctrlgc
    call    puts
    call    grcg_off
    mov     word ptr [g_count], GRCG_SPRITES
    mov     byte ptr [grcg_copy], 0
    mov     dword ptr [rc_units], GRCG_SPRITES
    mov     word ptr [rc_body], offset body_ctrlgc
    mov     si, offset lbl_ctrlgc
    call    run_case
    ret

/* body_ctrlgc: body_grcg's fill arm (grcg_copy=0 path, which is the path the
 * timed rows take) with the store replaced; the copy arm is kept DEAD code so
 * the executed instruction sequence is identical. */
body_ctrlgc:
    mov     bx, [g_count]
bcg_sprite:
    mov     ax, bx
    shl     ax, 1
    and     ax, 0x3FFE
    mov     di, ax
    mov     dx, 16
bcg_row:
    mov     es, [plane_seg0]
    cmp     byte ptr [grcg_copy], 0
    je      bcg_fill
    mov     ax, di                  /* dead copy arm, kept for shape */
    mov     es, [plane_seg1]
    or      ax, 0
    jmp     bcg_next
bcg_fill:
    mov     ax, 0xF0F0
    or      ax, 0
bcg_next:
    add     di, 80
    dec     dx
    jnz     bcg_row
    dec     bx
    jnz     bcg_sprite
    ret

case_plane_copy:
    mov     si, offset c_plane_copy
    call    puts
    call    grcg_off
    mov     word ptr [g_count], GRCG_SPRITES
    mov     byte ptr [grcg_copy], 1
    mov     dword ptr [rc_units], GRCG_SPRITES
    mov     word ptr [rc_body], offset body_grcg
    mov     si, offset lbl_plane_copy
    call    run_case
    ret

/* case_ctrlcp: the loop-shell CONTROL for PLANE_COPY - body_grcg's copy arm
 * (grcg_copy=1 path) with both GVRAM accesses replaced (`mov ax, es:[di]` ->
 * `mov ax, di`; the second store -> `or ax, 0`). */
case_ctrlcp:
    mov     si, offset c_ctrlcp
    call    puts
    call    grcg_off
    mov     word ptr [g_count], GRCG_SPRITES
    mov     byte ptr [grcg_copy], 1
    mov     dword ptr [rc_units], GRCG_SPRITES
    mov     word ptr [rc_body], offset body_ctrlcp
    mov     si, offset lbl_ctrlcp
    call    run_case
    ret

/* body_ctrlcp: body_grcg's copy arm with the read and the write replaced; the
 * branch structure is kept identical (the je is not taken, as in the real row). */
body_ctrlcp:
    mov     bx, [g_count]
bcc_sprite:
    mov     ax, bx
    shl     ax, 1
    and     ax, 0x3FFE
    mov     di, ax
    mov     dx, 16
bcc_row:
    mov     es, [plane_seg0]
    cmp     byte ptr [grcg_copy], 0
    je      bcc_fill
    mov     ax, di
    mov     es, [plane_seg1]
    or      ax, 0
    jmp     bcc_next
bcc_fill:
    mov     ax, 0xF0F0                /* dead fill arm, kept for shape */
    or      ax, 0
bcc_next:
    add     di, 80
    dec     dx
    jnz     bcc_row
    dec     bx
    jnz     bcc_sprite
    ret

/* ==================================================================== */
/* SECTION 4 - the GDC text subsystem                                   */
/* ==================================================================== */

/* body_tram: [g_count] text lines. Per line: 80 cells, each a 16-bit code word written to
   the character plane 0xA0000 and a 16-bit attribute word written to 0xA2000. */
body_tram:
    mov     bx, [g_count]
bt_line:
    mov     ax, bx
    and     ax, 15
    mov     cl, 160                     /* 80 cells x 2 bytes */
    mul     cl
    mov     di, ax
    mov     es, [tram_code_seg]
    mov     cx, 80
    mov     ax, 0x1234
bt_code:
    mov     es:[di], ax
    add     di, 2
    loop    bt_code
    mov     ax, bx
    and     ax, 15
    mov     cl, 160
    mul     cl
    mov     di, ax
    mov     es, [tram_attr_seg]
    mov     cx, 80
    mov     ax, 0x0001
bt_attr:
    mov     es:[di], ax
    add     di, 2
    loop    bt_attr
    dec     bx
    jnz     bt_line
    ret

/* body_font: [g_count] glyphs. Per glyph: set the CG code through 0xA1/0xA3, then read the
   16 raster rows through 0xA5/0xA9 (the CG font read path). */
body_font:
    mov     bx, [g_count]
bf_glyph:
    mov     dx, 0x00A1
    xor     al, al
    out     dx, al
    mov     dx, 0x00A3
    mov     al, 0x41                    /* 'A' */
    out     dx, al
    mov     dx, 0x00A5
    xor     cx, cx
bf_row:
    mov     al, cl
    out     dx, al
    mov     dx, 0x00A9
    in      al, dx
    mov     dx, 0x00A5
    inc     cx
    cmp     cx, 16
    jb      bf_row
    dec     bx
    jnz     bf_glyph
    ret

/* body_textline: [g_count] lines, the whole text subsystem per line: 80 code writes, 80
   attribute writes, and 80 glyph font reads (16 rows each). */
body_textline:
    mov     bx, [g_count]
bl_line:
    mov     es, [tram_code_seg]
    xor     di, di
    mov     cx, 80
    mov     ax, 0x1234
bl_code:
    mov     es:[di], ax
    add     di, 2
    loop    bl_code
    mov     es, [tram_attr_seg]
    xor     di, di
    mov     cx, 80
    mov     ax, 0x0001
bl_attr:
    mov     es:[di], ax
    add     di, 2
    loop    bl_attr
    mov     bp, 80
bl_glyph:
    mov     dx, 0x00A1
    xor     al, al
    out     dx, al
    mov     dx, 0x00A3
    mov     al, 0x41
    out     dx, al
    mov     dx, 0x00A5
    xor     cx, cx
bl_frow:
    mov     al, cl
    out     dx, al
    mov     dx, 0x00A9
    in      al, dx
    mov     dx, 0x00A5
    inc     cx
    cmp     cx, 16
    jb      bl_frow
    dec     bp
    jnz     bl_glyph
    dec     bx
    jnz     bl_line
    ret

case_tram:
    mov     si, offset c_tram
    call    puts
    mov     word ptr [g_count], TRAM_LINES
    mov     dword ptr [rc_units], TRAM_LINES
    mov     word ptr [rc_body], offset body_tram
    mov     si, offset lbl_tram
    call    run_case
    ret

case_font:
    mov     si, offset c_font
    call    puts
    mov     word ptr [g_count], FONT_GLYPHS
    mov     dword ptr [rc_units], FONT_GLYPHS
    mov     word ptr [rc_body], offset body_font
    mov     si, offset lbl_font
    call    run_case
    ret

case_textline:
    mov     si, offset c_textline
    call    puts
    mov     word ptr [g_count], TXT_LINES
    mov     dword ptr [rc_units], TXT_LINES
    mov     word ptr [rc_body], offset body_textline
    mov     si, offset lbl_textline
    call    run_case
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
    .balign 4
t0:         .long 0
t1:         .long 0
g_delta:    .long 0
g_clk:      .long 0
rc_units:   .long 0
rc_body:    .word 0
g_count:    .word 0
nplanes:    .word 0
pw_rw:      .byte 0
egc_rw:     .byte 0
egc_page:   .byte 0
egc_pg:     .byte 0
grcg_copy:  .byte 0

egc_v_access: .word 0xFFF0
egc_v_fgbg:   .word 0x00FF
egc_v_ope:    .word 0x3100
egc_v_fg:     .word 0x0000
egc_v_mask:   .word 0xFFFF
egc_v_sft:    .word 0x0000
egc_v_leng:   .word 0x000F

plane_seg0:   .word 0xA800
plane_seg1:   .word 0xB000
tram_code_seg: .word 0xA000
tram_attr_seg: .word 0xA200
/* The four GVRAM plane windows, in plane order 0..3. */
plane_tab:    .word 0xA800, 0xB000, 0xB800, 0xE000

/* One puts per message: a NUL ends a line. The banner is a pointer table of lines, printed
   by putlns; a run of .asciz directives would print only the first line. */
msg_banner_tab:
    .word   msg_b0, msg_b1, msg_b2, msg_b3, msg_b4, msg_b5, msg_b6, msg_b7, 0
msg_b0: .asciz "BEGIN:GFXBENC2\r\n"
msg_b1: .asciz "GFXBENC2: per-subsystem real-machine graphics benchmark (Xe10). Each case is a\r\n"
msg_b2: .asciz "  cli-timed body around the ARTIC counter. ANCHOR: ARTIC 005C/005F = 307200 Hz (the\r\n"
msg_b3: .asciz "  documented free-running tick; egcport.s measures it 0 per-mille off). CLK50 = ARTIC\r\n"
msg_b4: .asciz "  ticks * 50000000 / 307200 = ticks * 162.7604, i.e. clk_sys at the core's 50 MHz.\r\n"
msg_b5: .asciz "  PER = CLK50 * 1000 / UNITS = MILLI-clk_sys per unit (1952 clk_sys/sprite = 1952000).\r\n"
msg_b6: .asciz "  The text-TRAM section scribbles the visible console: redirect stdout to a file.\r\n"
msg_b7: .asciz "  The GVRAM is scribbled by design; the EGC/GRCG end off and 0xA6 ends at 0. Disk: untouched.\r\n"
msg_sec1:
    .asciz "; ---- 1. PLANE-WINDOW DRAW (gfx_scene A: the plain 0xA8000+ window path) ----\r\n"
msg_sec2:
    .asciz "; ---- 2. EGC BLIT (gfx_scene B: the Touhou EGC shapes) ----\r\n"
msg_sec3:
    .asciz "; ---- 3. GRCG (graphics clear / scroll) ----\r\n"
msg_sec4:
    .asciz "; ---- 4. GDC TEXT (TRAM fill + the CG font read) ----\r\n"

c_pw1:      .asciz "; PW1 = 1-plane window write, 16 word writes/sprite\r\n"
c_pw2:      .asciz "; PW2 = 2-plane window write, 32 word writes/sprite\r\n"
c_pw3:      .asciz "; PW3 = 3-plane window write, 48 word writes/sprite\r\n"
c_pw4:      .asciz "; PW4 = 4-plane window write, 64 word writes/sprite\r\n"
c_pw4rw:    .asciz "; PW4RW = 4-plane read-modify-write (scene_draw), 128 accesses/sprite\r\n"
c_ctrlpw:   .asciz "; CTRLPW = PW4RW's loop shell with each GVRAM access replaced (control row)\r\n"
c_egc3100:  .asciz "; EGC3100 = EGC 0x3100 put, page1->page0, 16 units/sprite (gfx_scene B)\r\n"
c_egc3100sp:.asciz "; EGC3100SP = EGC 0x3100 put, same page (no 0xA6 switch), 16 units/sprite\r\n"
c_egc28f0:  .asciz "; EGC28F0 = EGC 0x28F0 shifted copy sft=2, page1->page0, 16 units/sprite\r\n"
c_egc1400:  .asciz "; EGC1400 = EGC 0x1400 solid colour fill, 16 units/sprite\r\n"
c_egc0cf0:  .asciz "; EGC0CF0 = EGC 0x0CF0 ROP F0 write feed, 16 units/sprite\r\n"
c_grcg_tdw: .asciz "; GRCG_TDW = GRCG TDW tile clear (0x7C=0x80), 16 plane-expanded stores/sprite\r\n"
c_grcg_rmw: .asciz "; GRCG_RMW = GRCG RMW erase (0x7C=0xC0, scene_erase), 16 stores/sprite\r\n"
c_plane_copy:.asciz "; PLANE_COPY = plain plane-0 -> plane-1 copy, 16 read+write pairs/sprite\r\n"
c_ctrlgc:   .asciz "; CTRLGC = GRCG_TDW/GRCG_RMW's loop shell, store replaced (control row)\r\n"
c_ctrlcp:   .asciz "; CTRLCP = PLANE_COPY's loop shell, both accesses replaced (control row)\r\n"
c_tram:     .asciz "; TRAM_FILL = text-plane fill, 80 code + 80 attribute words per line\r\n"
c_font:     .asciz "; CG_FONT = CG font read: 0xA1/0xA3 code then 16 rows of 0xA5/0xA9 per glyph\r\n"
c_textline: .asciz "; TXT_LINE = whole text subsystem per line: 160 TRAM writes + 80x16 font reads\r\n"

lbl_pw1:      .asciz "PW1"
lbl_pw2:      .asciz "PW2"
lbl_pw3:      .asciz "PW3"
lbl_pw4:      .asciz "PW4"
lbl_pw4rw:    .asciz "PW4RW"
lbl_ctrlpw:   .asciz "CTRLPW"
lbl_egc3100:  .asciz "EGC3100"
lbl_egc3100sp:.asciz "EGC3100SP"
lbl_egc28f0:  .asciz "EGC28F0"
lbl_egc1400:  .asciz "EGC1400"
lbl_egc0cf0:  .asciz "EGC0CF0"
lbl_grcg_tdw: .asciz "GRCG_TDW"
lbl_grcg_rmw: .asciz "GRCG_RMW"
lbl_plane_copy:.asciz "PLANE_COPY"
lbl_ctrlgc:   .asciz "CTRLGC"
lbl_ctrlcp:   .asciz "CTRLCP"
lbl_tram:     .asciz "TRAM_FILL"
lbl_font:     .asciz "CG_FONT"
lbl_textline: .asciz "TXT_LINE"

msg_tag:    .asciz "GFX2 "
msg_units:  .asciz " UNITS="
msg_artic:  .asciz " ARTIC="
msg_clk:    .asciz " CLK50="
msg_per:    .asciz " PER="
msg_nl:     .asciz "\r\n"
msg_end:
    .asciz "END:GFXBENC2\r\n"
