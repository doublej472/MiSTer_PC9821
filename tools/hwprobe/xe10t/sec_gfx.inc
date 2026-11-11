/* sec_gfx.inc - /GVRAM /GRCG /EGC /PEGC /TEXT: graphics and text memory costs.
 *
 * Every memory row names its window and stays inside it (R12): the GVRAM rows use plane B
 * at 0xA8000-0xAFFFF (the span is n x stride: 16 KiB for the word rows, 32 KiB for the
 * string rows, the stride-80 row masks DI to 0x7FFF), the three-plane row planes B/R/G at
 * the same offsets, the PEGC rows bank 0 through the 0xA8000 window, the TRAM rows the
 * off-screen 0x1000-0x1FFF of the code (0xA0000) and attribute (0xA2000) planes, and the
 * CG rows the 0xA4000-0xA4FFF window. GVRAM and PEGC memory are scribbled (not saved); the
 * TRAM is saved to the RAM buffer and copied back, and the copy is verified.
 *
 * Writes are swept (R1): the GVRAM write is posted on the machine (the GFX2 GRCG misread),
 * so the decoder takes the period from the knee of gross(nop) against the control. Reads
 * and string moves are blocking and get net rows. Pairs are cross-checks only (R2).
 *
 * Declared starting state of every section (R17): EGC mode off (0x6A <- 07,04,06), GRCG off
 * (0x7C <- 0), access page 0 (0xA6 <- 0). The display page (0xA4) is never written here.
 */

/* ---------------------------------------------------------------- templates */
TPL g_nil,      ""
TPL g_set_b,    "mov ax, 0xA800; mov es, ax; xor di, di; mov eax, 0x55AA55AA; xor bx, bx"
TPL g_set_b1,   "mov ax, 0xA800; mov es, ax; mov di, 1; mov eax, 0x55AA55AA"
TPL g_set_b0,   "mov ax, 0xA800; mov es, ax; xor di, di; xor eax, eax; xor bx, bx"
TPL g_set_3p,   "mov ax, 0xA800; mov es, ax; mov ax, 0xB000; mov fs, ax; mov ax, 0xB800; mov gs, ax; xor di, di; mov eax, 0x55AA55AA"
TPL g_w16,      "mov word ptr es:[di], ax"
TPL g_w8,       "mov byte ptr es:[di], al"
TPL g_w32,      "mov dword ptr es:[di], eax"
TPL g_w3p,      "mov word ptr es:[di], ax; mov word ptr fs:[di], ax; mov word ptr gs:[di], ax"
TPL g_r16,      "mov bx, word ptr es:[di]"
TPL g_r8,       "mov bl, byte ptr es:[di]"
TPL g_r32,      "mov ebx, dword ptr es:[di]"
TPL g_wr,       "mov word ptr es:[di], ax; mov bx, word ptr es:[di+2]"
TPL g_rw,       "mov bx, word ptr es:[di]; mov word ptr es:[di], ax"
TPL g_adv1,     "inc di"
TPL g_adv2,     "add di, 2"
TPL g_adv4,     "add di, 4"
TPL g_adv80,    "add di, 80; and di, 0x7FFF"
TPL g_post_ds,  "pop ds"
TPL g_set_lw,   "mov ax, 0xA800; push ds; mov ds, ax; xor si, si; mov cx, 16384"
TPL g_set_ld,   "mov ax, 0xA800; push ds; mov ds, ax; xor si, si; mov cx, 8192"
TPL g_lodsw,    "rep lodsw"
TPL g_lodsd,    "rep lodsd"
TPL g_set_sw,   "mov ax, 0xA800; mov es, ax; mov eax, 0x55AA55AA; xor di, di; mov cx, 16384"
TPL g_set_sd,   "mov ax, 0xA800; mov es, ax; mov eax, 0x55AA55AA; xor di, di; mov cx, 8192"
TPL g_set_sb,   "mov ax, 0xA800; mov es, ax; mov eax, 0x55AA55AA; xor di, di; mov cx, 32768"
TPL g_stosw,    "rep stosw"
TPL g_stosd,    "rep stosd"
TPL g_stosb,    "rep stosb"
TPL g_set_r2v,  "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; xor si, si; mov di, 0x4000; mov cx, 8192"
TPL g_set_v2r,  "mov ax, word ptr [buf_seg]; push ds; mov es, ax; mov ax, 0xA800; mov ds, ax; xor si, si; mov di, 0x4000; mov cx, 8192"
TPL g_set_v2v,  "mov ax, 0xA800; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x4000; mov cx, 8192"
TPL g_set_v2x,  "mov ax, 0xA800; push ds; mov ds, ax; mov ax, 0xB000; mov es, ax; xor si, si; mov di, 0x4000; mov cx, 8192"
TPL g_set_r2vd, "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; xor si, si; xor di, di; mov cx, 8192"
TPL g_movsw,    "rep movsw"
TPL g_movsd,    "rep movsd"
/* GRCG tile reload: four 0x7E writes then the store (Rusty's wipe shape) */
TPL g_tile4w,   "mov al, 0xFF; out 0x7E, al; out 0x7E, al; out 0x7E, al; out 0x7E, al; mov word ptr es:[di], bx"
/* EGC: the 0xA6 access page alone, then followed by a read and by a write */
TPL g_a6,       "out 0xA6, al"
TPL g_a6r,      "out 0xA6, al; mov bx, word ptr es:[di]"
TPL g_a6w,      "out 0xA6, al; mov word ptr es:[di], bx"
TPL g_set_4a8,  "mov dx, 0x4A8; mov ax, 0xFFFF"
TPL g_set_4a0,  "mov dx, 0x4A0"
TPL g_outw,     "out dx, ax"
TPL g_inw,      "in ax, dx"
/* TRAM and CG */
TPL t_set_c,    "mov ax, 0xA000; mov es, ax; mov di, 0x1000; mov ax, 0x0020"
TPL t_set_a,    "mov ax, 0xA200; mov es, ax; mov di, 0x1000; mov ax, 0x00E1"
TPL t_set_cg,   "mov ax, 0xA400; mov es, ax; xor di, di"
TPL t_adv_cg,   "inc di; and di, 0x0FFF"
TPL t_set_cgp,  "xor bx, bx; xor al, al"
TPL t_cgrow,    "out 0xA5, al; in al, 0xA9"
TPL t_adv_cgp,  "inc bx; mov al, bl; and al, 0x0F"
TPL t_cgsel,    "mov al, 0x21; out 0xA1, al; mov al, 0x24; out 0xA3, al"

/* ---------------------------------------------------------------- tables */
tab_gvram:
    CASE "W16",     "w",   8192,  1024, 8, g_set_b,  g_w16, g_adv2,  g_nil, CF_SWEEP
    CASE "W8",      "b",   8192,  1024, 8, g_set_b,  g_w8,  g_adv1,  g_nil, CF_SWEEP
    CASE "W32",     "d",   4096,  512,  8, g_set_b,  g_w32, g_adv4,  g_nil, CF_SWEEP
    CASE "W16ODD",  "w",   8192,  1024, 8, g_set_b1, g_w16, g_adv2,  g_nil, CF_SWEEP
    CASE "W16S80",  "w",   8192,  1024, 8, g_set_b,  g_w16, g_adv80, g_nil, CF_SWEEP
    CASE "W16P3",   "3w",  4096,  512,  8, g_set_3p, g_w3p, g_adv2,  g_nil, CF_SWEEP
    CASE "R16",     "w",   8192,  1024, 8, g_set_b,  g_r16, g_adv2,  g_nil
    CASE "R8",      "b",   8192,  1024, 8, g_set_b,  g_r8,  g_adv1,  g_nil
    CASE "R32",     "d",   4096,  512,  8, g_set_b,  g_r32, g_adv4,  g_nil
    CASE "PAIRWR",  "pair", 4096, 512,  8, g_set_b,  g_wr,  g_adv4,  g_nil, CF_SWEEP
    CASE "PAIRRW",  "pair", 8192, 1024, 8, g_set_b,  g_rw,  g_adv2,  g_nil, CF_SWEEP
    CASE "LODSW",   "w",   16384, 1,    1, g_set_lw, g_lodsw, g_nil, g_post_ds
    CASE "LODSD",   "d",   8192,  1,    1, g_set_ld, g_lodsd, g_nil, g_post_ds
    CASE "STOSW",   "w",   16384, 1,    1, g_set_sw, g_stosw, g_nil, g_nil
    CASE "STOSD",   "d",   8192,  1,    1, g_set_sd, g_stosd, g_nil, g_nil
    CASE "STOSB",   "b",   32768, 1,    1, g_set_sb, g_stosb, g_nil, g_nil
    CASE "MOVSWR2V", "w",  8192,  1,    1, g_set_r2v, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "MOVSWV2R", "w",  8192,  1,    1, g_set_v2r, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "MOVSWV2V", "w",  8192,  1,    1, g_set_v2v, g_movsw, g_nil, g_post_ds
    CASE "MOVSWV2X", "w",  8192,  1,    1, g_set_v2x, g_movsw, g_nil, g_post_ds
    ENDTAB
tl_gvram:   .word tab_gvram, 0
tc_gvram:   .asciz "GVRAM-B/R/G(scribbled) 0x6A=07,04,06 0x7C=00 0xA6=00"

tab_grcg_rmw:                           /* 0x7C = 0xC0 (read-modify-write) */
    CASE "RMW16",   "w",   8192,  1024, 8, g_set_b,  g_w16, g_adv2,  g_nil, CF_SWEEP
    CASE "RMW8",    "b",   8192,  1024, 8, g_set_b,  g_w8,  g_adv1,  g_nil, CF_SWEEP
    CASE "RMW32",   "d",   4096,  512,  8, g_set_b,  g_w32, g_adv4,  g_nil, CF_SWEEP
    CASE "RMWSTOSW", "w",  16384, 1,    1, g_set_sw, g_stosw, g_nil, g_nil
    CASE "RMWSTOSD", "d",  8192,  1,    1, g_set_sd, g_stosd, g_nil, g_nil
    CASE "TILE4W",  "grp", 4096,  1024, 4, g_set_b,  g_tile4w, g_adv2, g_nil
    ENDTAB
tab_grcg_tdw:                           /* 0x7C = 0x80 (tile data write; reads = TCR) */
    CASE "TDW16",   "w",   8192,  1024, 8, g_set_b,  g_w16, g_adv2,  g_nil, CF_SWEEP
    CASE "TDW8",    "b",   8192,  1024, 8, g_set_b,  g_w8,  g_adv1,  g_nil, CF_SWEEP
    CASE "TDW32",   "d",   4096,  512,  8, g_set_b,  g_w32, g_adv4,  g_nil, CF_SWEEP
    CASE "TDWSTOSW", "w",  16384, 1,    1, g_set_sw, g_stosw, g_nil, g_nil
    CASE "TDWSTOSD", "d",  8192,  1,    1, g_set_sd, g_stosd, g_nil, g_nil
    CASE "TCR16",   "w",   8192,  1024, 8, g_set_b,  g_r16, g_adv2,  g_nil
    CASE "TCR8",    "b",   8192,  1024, 8, g_set_b,  g_r8,  g_adv1,  g_nil
    ENDTAB
tl_grcg:    .word tab_grcg_rmw, tab_grcg_tdw, 0
tc_grcg:    .asciz "GVRAM-B 0x7C=C0/80 then 00 0x7E(tile x4) 0x6A=07,04,06"

tab_egc_w:                              /* write-only ROP shape (gfxbenc2 EGC1400) */
    CASE "EGCW",    "w",   8192,  1024, 8, g_set_b,  g_w16, g_adv2,  g_nil, CF_SWEEP
    ENDTAB
tab_egc_rw:                             /* copy shape (gfxbenc2 EGC3100SP), 4 planes */
    CASE "EGCR",    "w",   8192,  1024, 8, g_set_b,  g_r16, g_adv2,  g_nil
    CASE "EGCRW",   "pair", 8192, 1024, 8, g_set_b,  g_rw,  g_adv2,  g_nil, CF_SWEEP
    CASE "EGCA6",   "io",  2048,  256,  8, g_set_b0, g_a6,  g_nil,   g_nil
    CASE "EGCA6R",  "grp", 4096,  512,  8, g_set_b0, g_a6r, g_adv2,  g_nil
    CASE "EGCA6W",  "grp", 4096,  512,  8, g_set_b0, g_a6w, g_adv2,  g_nil
    CASE "EGCREGW", "io",  1024,  128,  8, g_set_4a8, g_outw, g_nil, g_nil
    CASE "EGCREGR", "io",  256,   32,   8, g_set_4a0, g_inw, g_nil,  g_nil
    ENDTAB
tl_egc:     .word tab_egc_w, tab_egc_rw, 0
tc_egc:     .asciz "GVRAM-B 0x6A=07,05,06/07,04,06 0x7C=80/00 0x4A0-0x4AE 0xA6=00"

tab_pegc:                               /* 256-colour packed, bank 0 at 0xA8000 */
    CASE "PKW8",    "b",   8192,  1024, 8, g_set_b,  g_w8,  g_adv1,  g_nil, CF_SWEEP
    CASE "PKW16",   "w",   8192,  1024, 8, g_set_b,  g_w16, g_adv2,  g_nil, CF_SWEEP
    CASE "PKW32",   "d",   4096,  512,  8, g_set_b,  g_w32, g_adv4,  g_nil, CF_SWEEP
    CASE "PKR8",    "b",   8192,  1024, 8, g_set_b,  g_r8,  g_adv1,  g_nil
    CASE "PKR16",   "w",   8192,  1024, 8, g_set_b,  g_r16, g_adv2,  g_nil
    CASE "PKSTOSD", "d",   8192,  1,    1, g_set_sd, g_stosd, g_nil, g_nil
    CASE "PKMOVSD", "d",   8192,  1,    1, g_set_r2vd, g_movsd, g_nil, g_post_ds, CF_BUF
    ENDTAB
tl_pegc:    .word tab_pegc, 0
tc_pegc:    .asciz "0x6A=01,07,21,06/07,20,06,(q04) E0004=0000 E0006=0000 E0100=00 PEGC-bank0(scribbled)"

tab_text:
    CASE "TCW16",   "w",   2048,  256,  8, t_set_c,  g_w16, g_adv2,  g_nil, CF_SWEEP | CF_TRAM
    CASE "TCW8",    "b",   4096,  512,  8, t_set_c,  g_w8,  g_adv1,  g_nil, CF_SWEEP | CF_TRAM
    CASE "TCR16",   "w",   2048,  256,  8, t_set_c,  g_r16, g_adv2,  g_nil, CF_TRAM
    CASE "TAW16",   "w",   2048,  256,  8, t_set_a,  g_w16, g_adv2,  g_nil, CF_SWEEP | CF_TRAM
    CASE "TAR16",   "w",   2048,  256,  8, t_set_a,  g_r16, g_adv2,  g_nil, CF_TRAM
    CASE "CGWINR8", "b",   2048,  256,  8, t_set_cg, g_r8,  t_adv_cg, g_nil, CF_TRAM
    CASE "CGROW",   "row", 2048,  256,  8, t_set_cgp, t_cgrow, t_adv_cgp, g_nil, CF_TRAM
    CASE "CGSEL",   "sel", 1024,  128,  8, g_nil,    t_cgsel, g_nil,  g_nil, CF_TRAM
    ENDTAB
tl_text:    .word tab_text, 0
tc_text:    .asciz "TRAM 0xA1000-0xA1FFF,0xA3000-0xA3FFF(saved,restored) 0xA1/0xA3/0xA5(CG select) 0x6A=07,04,06 0x7C=00"

n_egcq:     .asciz "Q9A07_EGC"
n_q04:      .asciz "Q9A04_16C"
n_q0a:      .asciz "Q9A0A_256"
n_7e:       .asciz "P7E_TILE"
n_egcregs:  .asciz "P4A0_ACCESS"
n_pegcbank: .asciz "E0004_BANK"
n_tram:     .asciz "TRAM_0000_3FFF"
n_cgsel:    .asciz "PA1A3_CGCODE"
sfx_p1:     .asciz "P1"
sfx_p2:     .asciz "P2"
sfx_p3:     .asciz "P3"
sfx_p4:     .asciz "P4"
egc_planes: .word 0xFFFE, sfx_p1, 0xFFFC, sfx_p2, 0xFFF8, sfx_p3, 0xFFF0, sfx_p4, 0

/* ---------------------------------------------------------------- helpers */
/* gfx_off: the declared starting state - EGC mode off, GRCG off, access page 0. */
gfx_off:
    push    ax
    mov     al, 0
    out     0x7C, al
    mov     al, 0x07
    out     0x6A, al
    mov     al, 0x04
    out     0x6A, al
    mov     al, 0x06
    out     0x6A, al
    mov     al, 0
    out     0xA6, al
    pop     ax
    ret

gfx_state:
    mov     si, offset k_STATE
    call    info_start
    PS      "egc=off grcg=off a6=0 q07="
    mov     al, 0x07
    call    query9a0
    call    out_x2
    PS      " q04="
    mov     al, 0x04
    call    query9a0
    call    out_x2
    PS      " q0A="
    mov     al, 0x0A
    call    query9a0
    call    out_x2
    jmp     out_nl

/* gfx_restore_common: GRCG off, EGC off, access page 0 and the RESTORE lines for them:
 * the EGC bit against its as-found query (readback), the GRCG/tile/page as defaults. */
gfx_restore_common:
    call    gfx_off
    mov     si, offset n_7c
    xor     eax, eax
    call    rs_default
    mov     si, offset n_a6
    call    rs_default
    mov     al, 0x07
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [q_save+1]
    mov     si, offset n_egcq
    mov     cx, 0x0002
    mov     bl, 3
    jmp     rs_line

/* grcg_set: AL = 0x7C mode; the tile bytes 0xFF,0x00,0xFF,0x00 (planes B,R,G,I). */
grcg_set:
    out     0x7C, al
    mov     al, 0xFF
    out     0x7E, al
    mov     al, 0x00
    out     0x7E, al
    mov     al, 0xFF
    out     0x7E, al
    mov     al, 0x00
    out     0x7E, al
    ret

/* egc_on / egc_off / egc_prog: master.lib's sequences (egcplane.s). */
egc_on:
    mov     al, 0x07
    out     0x6A, al
    mov     al, 0x05
    out     0x6A, al
    mov     al, 0x80
    out     0x7C, al
    mov     al, 0x06
    out     0x6A, al
    ret

/* egc_prog: BX -> 7 words: access, fgbg, ope, fg, mask, sft, leng (0x4A0..0x4AE). The
 * write enable (FF2 num 3) is held for the block; the mask follows the colour field. */
egc_prog:
    push    ax
    push    dx
    push    si
    mov     al, 0x07
    out     0x6A, al
    mov     si, bx
    mov     dx, 0x4A0
    lodsw
    out     dx, ax
    mov     dx, 0x4A2
    lodsw
    out     dx, ax
    mov     dx, 0x4A4
    lodsw
    out     dx, ax
    mov     dx, 0x4A6
    lodsw
    out     dx, ax
    mov     dx, 0x4A8
    lodsw
    out     dx, ax
    mov     dx, 0x4AC
    lodsw
    out     dx, ax
    mov     dx, 0x4AE
    lodsw
    out     dx, ax
    mov     al, 0x06
    out     0x6A, al
    pop     si
    pop     dx
    pop     ax
    ret

egc_v_rw:   .word 0xFFF0, 0x00FF, 0x3100, 0x0009, 0xFFFF, 0x0000, 0x000F

/* ---------------------------------------------------------------- GVRAM */
sec_gvram:
    mov     si, offset nm_gvram
    mov     eax, WD_20S
    mov     bx, offset gvram_exit
    call    sec_begin
    call    gfx_off
    call    gfx_state
    mov     si, offset tab_gvram
    call    run_list
gvram_exit:
    call    sec_disarm
    call    gfx_restore_common
    call    sec_end
    ret

/* ---------------------------------------------------------------- GRCG */
sec_grcg:
    mov     si, offset nm_grcg
    mov     eax, WD_20S
    mov     bx, offset grcg_exit
    call    sec_begin
    call    gfx_off
    call    gfx_state
    mov     si, offset k_STATE
    call    info_start
    PS      "grcg=C0 tile=FF,00,FF,00"
    call    out_nl
    mov     al, 0xC0
    call    grcg_set
    mov     si, offset tab_grcg_rmw
    call    run_list
    mov     si, offset k_STATE
    call    info_start
    PS      "grcg=80 tile=FF,00,FF,00"
    call    out_nl
    mov     al, 0x80
    call    grcg_set
    mov     si, offset tab_grcg_tdw
    call    run_list
grcg_exit:
    call    sec_disarm
    mov     al, 0
    call    grcg_set                    /* GRCG off, tile FF,00,FF,00 */
    mov     al, 0
    mov     cx, 4
1:  out     0x7E, al                    /* tile back to 0 (the documented default) */
    loop    1b
    mov     si, offset n_7e
    xor     eax, eax
    call    rs_default
    call    gfx_restore_common
    call    sec_end
    ret

/* ---------------------------------------------------------------- EGC */
sec_egc:
    mov     si, offset nm_egc
    mov     eax, WD_20S
    mov     bx, offset egc_exit
    call    sec_begin
    call    gfx_off
    call    gfx_state
    call    egc_on
    mov     si, offset egc_planes
1:  mov     ax, word ptr [si]
    test    ax, ax
    jz      2f
    mov     word ptr [egc_v_w], ax
    mov     bx, offset egc_v_w
    call    egc_prog
    mov     ax, word ptr [si+2]
    mov     word ptr [tag_sfx], ax
    push    si
    mov     si, offset k_STATE
    call    info_start
    PS      "egc=on ope=1400 fgbg=40FF access="
    mov     ax, word ptr [egc_v_w]
    call    out_x4
    call    out_nl
    mov     si, offset tab_egc_w
    call    run_list
    pop     si
    add     si, 4
    jmp     1b
2:  mov     word ptr [tag_sfx], 0
    mov     bx, offset egc_v_rw
    call    egc_prog
    mov     si, offset k_STATE
    call    info_start
    PS      "egc=on ope=3100 fgbg=00FF access=FFF0"
    call    out_nl
    mov     si, offset tab_egc_rw
    call    run_list
egc_exit:
    call    sec_disarm
    mov     word ptr [tag_sfx], 0
    mov     word ptr [egc_v_w], 0xFFF0
    mov     bx, offset egc_v_w          /* the access register back to all planes */
    call    egc_prog
    mov     si, offset n_egcregs
    mov     eax, 0xFFF0
    mov     edx, eax
    mov     cx, 0x0104
    mov     bl, 2
    call    rs_line
    call    gfx_restore_common
    call    sec_end
    ret

/* ---------------------------------------------------------------- PEGC */
sec_pegc:
    mov     si, offset nm_pegc
    mov     eax, WD_20S
    mov     bx, offset pegc_exit
    call    sec_begin
    call    gfx_off
    call    gfx_state
    mov     al, 0x04
    call    query9a0
    mov     byte ptr [pg_q04], al
    mov     byte ptr [pg_on], 1
    /* 16-colour analogue, then 256-colour (FF2 num 0x10) under the write enable */
    mov     al, 0x01
    out     0x6A, al
    mov     al, 0x07
    out     0x6A, al
    mov     al, 0x21
    out     0x6A, al
    mov     al, 0x06
    out     0x6A, al
    push    es
    mov     ax, 0xE000
    mov     es, ax
    mov     byte ptr es:[0x0100], 0x00      /* packed-pixel mode */
    mov     word ptr es:[0x0004], 0         /* bank at 0xA8000 */
    mov     word ptr es:[0x0006], 0         /* bank at 0xB0000 */
    pop     es
    mov     si, offset k_STATE
    call    info_start
    PS      "pegc=256 packed bank0=0 q0A="
    mov     al, 0x0A
    call    query9a0
    call    out_x2
    call    out_nl
    mov     si, offset tab_pegc
    call    run_list
pegc_exit:
    call    sec_disarm
    cmp     byte ptr [pg_on], 0
    je      1f
    mov     byte ptr [pg_on], 0
    push    es
    mov     ax, 0xE000
    mov     es, ax
    mov     word ptr es:[0x0004], 0
    mov     word ptr es:[0x0006], 0
    pop     es
    mov     al, 0x07
    out     0x6A, al
    mov     al, 0x20
    out     0x6A, al
    mov     al, 0x06
    out     0x6A, al
    mov     al, byte ptr [pg_q04]
    and     al, 1
    out     0x6A, al                    /* FF2 num 0 back to the as-found colour mode */
1:  mov     si, offset n_pegcbank
    xor     eax, eax
    call    rs_default
    mov     al, 0x0A
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [q_save+3]
    mov     si, offset n_q0a
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    mov     al, 0x04
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [q_save+0]
    mov     si, offset n_q04
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    call    gfx_restore_common
    call    sec_end
    ret

/* ---------------------------------------------------------------- TEXT */
sec_text:
    mov     si, offset nm_text
    mov     eax, WD_20S
    mov     bx, offset text_exit
    call    sec_begin
    mov     byte ptr [tx_saved], 0
    cmp     word ptr [buf_seg], 0
    jne     1f
    mov     si, offset rs_nobuf
    call    skip_line
    jmp     text_end
1:  call    gfx_off
    call    gfx_state
    /* save TRAM 0xA0000-0xA3FFF to buffer:8000 */
    push    ds
    push    es
    mov     es, word ptr [buf_seg]
    mov     ax, 0xA000
    mov     ds, ax
    xor     si, si
    mov     di, 0x8000
    mov     cx, 0x2000
    cld
    rep     movsw
    pop     es
    pop     ds
    mov     byte ptr [tx_saved], 1
    mov     al, 0x21
    out     0xA1, al
    mov     al, 0x24
    out     0xA3, al
    mov     si, offset tab_text
    call    run_list
text_exit:
    call    sec_disarm
    cmp     byte ptr [tx_saved], 0
    je      text_end
    /* copy back and verify */
    push    ds
    push    es
    mov     ax, 0xA000
    mov     es, ax
    mov     ds, word ptr [buf_seg]
    mov     si, 0x8000
    xor     di, di
    mov     cx, 0x2000
    cld
    rep     movsw
    mov     si, 0x8000
    xor     di, di
    mov     cx, 0x2000
    xor     dx, dx                      /* mismatching words */
2:  mov     ax, word ptr [si]
    cmp     ax, word ptr es:[di]
    je      3f
    inc     dx
3:  add     si, 2
    add     di, 2
    loop    2b
    pop     es
    pop     ds
    mov     si, offset n_tram
    movzx   edx, dx
    xor     eax, eax                    /* was: 0 mismatches expected */
    mov     cx, 0x0204
    mov     bl, 3
    call    rs_line
    mov     si, offset n_cgsel
    xor     eax, eax
    call    rs_default
    call    gfx_restore_common
text_end:
    call    sec_end
    ret

    VARS
egc_v_w:    .word 0xFFF0, 0x40FF, 0x1400, 0x0009, 0xFFFF, 0x0000, 0x000F
pg_q04:     .byte 0
pg_on:      .byte 0
tx_saved:   .byte 0
    ENDVARS
