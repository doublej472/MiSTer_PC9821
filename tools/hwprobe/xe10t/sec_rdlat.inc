/* sec_rdlat.inc - /RDLAT (opt-in, XE10X.COM only): are GVRAM, GRCG-TCR and text-RAM reads a
 * LATENCY (the CPU waits for each read, so work between reads adds to the time) or a RATE (the
 * next read waits out a period, so work between reads hides inside it)? And the raster penalty
 * of the store and read classes in the 31 kHz 640x400 mode and the PEGC 640x480 mode, with a
 * text-RAM pass on the displayed lines.
 *
 * WHY. Every read row so far (XE10W /MISAL2, docs/probes/XE10W-XE10-MIS2RUN1.TXT) is a tight
 * loop with nothing between the reads, and a tight loop reads the same under both models. The
 * core's Xe10 table (pc9821_gvram_arb.sv, pc9821_window_responder.sv) prices a read as an
 * acceptance period; the stores were shown to be rate-shaped by the XE10T W32 nop sweep
 * (docs/probes/XE10T-XE10.TXT:68-72). Every `_A` row so far ran in 640x400 colour at 24 kHz
 * (INT 18h AH=42h CH=C0), and every text-RAM row in the off-screen 0x1000-0x1FFF.
 *
 * THE ROWS (n = 512 per window, DI += 4, every swept row at 0, 2, 4, 8, 16, 32 and 64 nops
 * after each access: rd_ks, which only this binary's run_case reads). Tags <FAMILY>_<MODE><PH>:
 *   GRW  plain GVRAM word load (plane B, GRCG off)        GRD  plain dword load
 *   GW   plain GVRAM word store (the rate-shaped control: its sweep must show a knee)
 *   GLSW `rep lodsw` of 512 words; GMVR `rep movsw` GVRAM -> RAM (one point each, nop 0)
 *   TCRW the GRCG TCR word read (0x7C = 80)               TDW  the TDW word store (0x7C = 80)
 *   RMW  the GRCG RMW word store (0x7C = C0)
 *   XCR/XCW   text code word load/store in the off-screen 0xA1000 (the /MISAL2 rows)
 *   XCRS/XCWS text code word load/store at 0xA0000 (rows 0-12 of the displayed text)
 *   XARS/XAWS text attribute word load/store at 0xA2000 (the same displayed cells)
 *   PKR/PKW   PEGC 256-colour packed bank 0 word load/store through 0xA8000 (/PEGC's setup)
 * The text-RAM rows need the 256 KiB buffer (the whole 0xA0000-0xA1FFF and 0xA2000-0xA3FFF are
 * saved to it first, copied back at the end and compared); without it they are skipped.
 *
 * THE MODES AND PHASES (MODE: 24 = INT 18h AH=42h CH=C0 at 24 kHz, the /MISAL display;
 * 31 = AH=30h AL=0C BH=2x then AH=42h CH=C0, 640x400 on the 31 kHz raster; 48 = AH=30h AL=0C
 * BH=31, the 640x480 mode the Windows 95 PC-9821 256-colour driver sets, with the PEGC's packed
 * 256-colour mode on; PH as /MISAL: O display stopped, A each window 2 ms after the VSYNC fall,
 * V each window from the VSYNC rise). 24 runs O, A, V; 31 and 48 run A and V. 48 runs only the
 * text and PEGC rows (in the 256-colour mode 0xA8000 is the packed bank, not plane B).
 * Raster geometry from the BIOS SYNC tables (NP2kai bios/bios18.c gdcmastersync / gdcslavesync,
 * the decoder's RD_GEOM): 24 kHz 400 + 7 + 8 + 25 = 440 lines, a 33-line blank from the VSYNC
 * rise; 31 kHz 400-line 400 + 13 + 2 + 34 = 449, 36 lines; 640x480 (slave 31-H) 480 + 6 + 2 + 37
 * = 525, 39 lines (about 1.15 ms at 31.5 kHz). 2 ms after the fall is past every back porch.
 * Each mode is entered, read back with AH=31h (the 31 kHz bit and the BH line field must be the
 * ones asked, else `SKIP RDLAT reason=mode<M>` and the mode's rows are left out) and timed with
 * `P RDLAT RASTER_<M>` (8 frames, as /MISAL), so the capture proves where each window ran.
 *
 * STATE: the as-found BDA 0x054C/0x054D, AH=31h's AL/BH (preloaded FF: a BIOS without the call
 * leaves FF and the 31/48 modes are skipped), port 0x09A8 (bit 0: the 31 kHz dot clock) and
 * 0x9A0 query 0x0A (256 colours); one STATE line per mode with AH=30h's AH and the read-back.
 *
 * RESTORE: AH=30h with the as-found AL/BH and AH=0Ch (AH=30h stops the text display) if a mode
 * was set; the PEGC as /MISAL2 (bank registers 0, the 256-colour mode off, RESTORE lines for
 * queries 0A and 04); the GRCG off and the tile 0; the TRAM copied back and compared
 * (kind=self); the graphics display as /MISAL (AH=41h/42h/40h to the as-found BDA bits, with
 * RESTORE lines); readback RESTORE lines for AH=31h's AL and BH and port 0x09A8 bit 0. GVRAM
 * plane B and the packed bank 0 are scribbled (not saved), as /GVRAM and /PEGC.
 */

rd_ks:      .byte 0, 2, 4, 8, 16, 32, 64, 0xFF

TPL x_cs0,  "mov ax, 0xA000; mov es, ax; xor di, di; mov ax, 0x0020"
TPL x_as0,  "mov ax, 0xA200; mov es, ax; xor di, di; mov ax, 0x00E1"

tab_rd_gv:                              /* GRCG off, plane B */
    CASE "GRW",  "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "GRD",  "d", 512, 64, 8, m_set0, g_r32, g_adv4, g_nil, CF_SWEEP
    CASE "GW",   "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "GLSW", "w", 512, 1, 1, v_ls0, g_lodsw, g_nil, g_post_ds
    CASE "GMVR", "w", 512, 1, 1, v_mr0, g_movsw, g_nil, g_post_ds, CF_BUF
    ENDTAB
tab_rd_tcr:                             /* 0x7C = 80: reads are the TCR, stores TDW */
    CASE "TCRW", "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "TDW",  "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_rd_rmw:                             /* 0x7C = C0 */
    CASE "RMW",  "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_rd_tx:
    CASE "XCR",  "w", 512, 64, 8, x_c0,  g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XCW",  "w", 512, 64, 8, x_c0,  g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XCRS", "w", 512, 64, 8, x_cs0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XCWS", "w", 512, 64, 8, x_cs0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XARS", "w", 512, 64, 8, x_as0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XAWS", "w", 512, 64, 8, x_as0, g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_rd_pk:
    CASE "PKR",  "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "PKW",  "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tl_rdlat:   .word tab_rd_gv, tab_rd_tcr, tab_rd_rmw, tab_rd_tx, tab_rd_pk, 0
tc_rdlat:   .asciz "RAM buffer(scribbled) GVRAM-B/PEGC-bank0(scribbled) TRAM 0xA0000-0xA3FFF(saved,restored) 0x7C=80/C0/00 0x7E 0x6A INT18h AH=30/31/0C/41/42/40 then AH=30/0C/41/42/40 as found"
nm_rdlat:   .asciz "RDLAT"
kw_rdlat:   .asciz "RDLAT"
n_tram3:    .asciz "TRAM_0000_1FFF"
n_ah31al:   .asciz "AH31_AL"
n_ah31bh:   .asciz "AH31_BH"
n_9a8:      .asciz "P9A8_BIT0"
rs_nobios:  .asciz "ah31_none"
rs_m31:     .asciz "mode31"
rs_m48:     .asciz "mode48"
tg_r24o:    .asciz "RASTER_24O"
tg_r24:     .asciz "RASTER_24"
tg_r31:     .asciz "RASTER_31"
tg_r48:     .asciz "RASTER_48"
sfx_24o:    .asciz "_24O"
sfx_24a:    .asciz "_24A"
sfx_24v:    .asciz "_24V"
sfx_31a:    .asciz "_31A"
sfx_31v:    .asciz "_31V"
sfx_48a:    .asciz "_48A"
sfx_48v:    .asciz "_48V"
md_24:      .asciz "24"
md_31:      .asciz "31"
md_48:      .asciz "48"

/* rd_tram: AL = 0 save (0xA0000-0xA1FFF and 0xA2000-0xA3FFF -> buffer+0x3000:0000/+0x3200:0000),
 * 1 restore. */
rd_tram:
    pushad
    push    ds
    push    es
    mov     bx, word ptr [buf_seg]
    add     bx, 0x3000
    mov     dx, 0xA000
    mov     bp, 2
1:  cld
    xor     si, si
    xor     di, di
    test    al, al
    jnz     2f
    mov     ds, dx
    mov     es, bx
    jmp     3f
2:  mov     ds, bx
    mov     es, dx
3:  mov     cx, 0x1000
    rep     movsw
    add     dx, 0x0200
    add     bx, 0x0200
    dec     bp
    jnz     1b
    pop     es
    pop     ds
    popad
    ret

/* rd_tcmp: EDX = mismatching words between the TRAM and its saved copy. */
rd_tcmp:
    push    ds
    push    es
    push    si
    push    cx
    push    bx
    push    ax
    xor     edx, edx
    mov     bx, word ptr [buf_seg]
    add     bx, 0x3000
    mov     ax, 0xA000
1:  mov     ds, bx
    mov     es, ax
    xor     si, si
    mov     cx, 0x1000
2:  push    ax
    mov     ax, word ptr [si]
    cmp     ax, word ptr es:[si]
    pop     ax
    je      3f
    inc     edx
3:  add     si, 2
    loop    2b
    add     bx, 0x0200
    add     ax, 0x0200
    cmp     ax, 0xA400
    jb      1b
    pop     ax
    pop     bx
    pop     cx
    pop     si
    pop     es
    pop     ds
    ret

/* rd_q31: INT 18h AH=31h -> [rd_al], [rd_bh] (both preloaded FF). */
rd_q31:
    pushad
    mov     ax, 0x31FF
    mov     bx, 0xFFFF
    int     0x18
    mov     byte ptr [rd_al], al
    mov     byte ptr [rd_bh], bh
    popad
    ret

/* rd_st: the mode's state after " " on a STATE line: AH=31h's AL/BH, 0x09A8, query 0A, the BDA. */
rd_st:
    push    ax
    PS      " al="
    mov     al, byte ptr [rd_al]
    call    out_x2
    PS      " bh="
    mov     al, byte ptr [rd_bh]
    call    out_x2
    PS      " p9a8="
    push    dx
    mov     dx, 0x09A8
    in      al, dx
    pop     dx
    call    out_x2
    PS      " q0A="
    mov     al, 0x0A
    call    query9a0
    call    out_x2
    call    ms_state_bda
    pop     ax
    ret

/* rd_set: AL = rate, BH = screen (INT 18h AH=30h), SI = the mode's name. The text display is
 * started again (AH=0Ch), AH=31h read back and printed; CF = 1 when the read-back's 31 kHz bit
 * (AL bit 2) or line field (BH bits 5:4) is not the one asked. */
rd_set:
    mov     byte ptr [rd_sw], 1
    mov     byte ptr [rd_wal], al
    mov     byte ptr [rd_wbh], bh
    push    si
    mov     ah, 0x30
    int     0x18
    mov     byte ptr [rd_ret], ah
    mov     ah, 0x0C
    int     0x18
    call    rd_q31
    mov     si, offset k_STATE
    call    info_start
    PS      "mode="
    pop     si
    call    out_s
    PS      " ah30="
    mov     al, byte ptr [rd_ret]
    call    out_x2
    call    rd_st
    call    out_nl
    mov     al, byte ptr [rd_al]
    xor     al, byte ptr [rd_wal]
    test    al, 0x04
    jnz     9f
    mov     al, byte ptr [rd_bh]
    xor     al, byte ptr [rd_wbh]
    test    al, 0x30
    jnz     9f
    clc
    ret
9:  stc
    ret

/* rd_run: SI = case table, run after the watchdog is re-armed. */
rd_run:
    call    ms_rearm
    jmp     run_list

/* rd_ph16: the 16-colour display's tables in the phase [tag_sfx] names. */
rd_ph16:
    mov     al, 0
    out     0x7C, al
    mov     si, offset tab_rd_gv
    call    rd_run
    mov     al, 0x80
    call    grcg_set
    mov     si, offset tab_rd_tcr
    call    rd_run
    mov     al, 0xC0
    call    grcg_set
    mov     si, offset tab_rd_rmw
    call    rd_run
    mov     al, 0
    out     0x7C, al
    call    rd_phtx
    call    m2_pegc_on
    mov     si, offset tab_rd_pk
    call    rd_run
    jmp     m2_pegc_off

/* rd_phtx: the TRAM rows, when the TRAM is saved. */
rd_phtx:
    cmp     byte ptr [rd_tsaved], 0
    je      1f
    mov     si, offset tab_rd_tx
    call    rd_run
1:  ret

/* rd_ph48: the 640x480 256-colour display's tables. */
rd_ph48:
    call    rd_phtx
    mov     si, offset tab_rd_pk
    jmp     rd_run

/* rd_av: AX = the _A suffix, BX = the _V suffix, DX = the phase routine: both raster phases. */
rd_av:
    mov     byte ptr [win_ph], 1
    mov     word ptr [tag_sfx], ax
    push    bx
    push    dx
    call    dx
    pop     dx
    pop     bx
    mov     byte ptr [win_ph], 2
    mov     word ptr [tag_sfx], bx
    call    dx
    mov     byte ptr [win_ph], 0
    mov     word ptr [tag_sfx], 0
    ret

sec_rdlat:
    mov     si, offset nm_rdlat
    mov     eax, WD_60S
    mov     bx, offset rd_exit
    call    sec_begin
    mov     byte ptr [win_ph], 0
    mov     word ptr [ms_to], 0
    mov     word ptr [tag_sfx], 0
    mov     byte ptr [rd_tsaved], 0
    mov     byte ptr [rd_sw], 0
    mov     byte ptr [m2_pgon], 0
    mov     word ptr [ks_ptr0], offset rd_ks
    call    gfx_off
    call    gfx_state
    call    ms_bda
    mov     word ptr [ms_bda0], ax
    call    rd_q31
    mov     al, byte ptr [rd_al]
    mov     byte ptr [rd_al0], al
    mov     al, byte ptr [rd_bh]
    mov     byte ptr [rd_bh0], al
    mov     dx, 0x09A8
    in      al, dx
    mov     byte ptr [rd_p9a8], al
    mov     si, offset k_STATE
    call    info_start
    PS      "as_found"
    call    rd_st
    PS      " bufparas="
    movzx   eax, word ptr [buf_paras]
    call    out_x4
    call    out_nl
    cmp     word ptr [buf_paras], 0x4000
    jae     1f
    mov     si, offset rs_m2buf
    call    skip_line
    jmp     2f
1:  mov     al, 0
    call    rd_tram
    mov     byte ptr [rd_tsaved], 1
2:  mov     byte ptr [ms_disp], 1
    /* 24 kHz, the graphics display stopped */
    mov     ah, 0x41
    int     0x18
    mov     si, offset tg_r24o
    call    ms_raster
    mov     word ptr [tag_sfx], offset sfx_24o
    call    rd_ph16
    mov     word ptr [tag_sfx], 0
    /* 24 kHz, 640x400 colour, bank 0, on (the /MISAL display) */
    mov     ah, 0x42
    mov     ch, 0xC0
    int     0x18
    mov     ah, 0x40
    int     0x18
    mov     si, offset k_STATE
    call    info_start
    PS      "mode=24"
    call    rd_st
    call    out_nl
    mov     si, offset tg_r24
    call    ms_raster
    mov     ax, offset sfx_24a
    mov     bx, offset sfx_24v
    mov     dx, offset rd_ph16
    call    rd_av
    /* the 31 kHz modes need AH=30h/31h */
    cmp     word ptr [rd_al], 0xFFFF
    jne     3f
    mov     si, offset rs_nobios
    call    skip_line
    jmp     rd_exit
3:  mov     al, 0x0C
    mov     bh, byte ptr [rd_bh0]
    and     bh, 0x01
    or      bh, 0x20
    mov     si, offset md_31
    call    rd_set
    jnc     4f
    mov     si, offset rs_m31
    call    skip_line
    jmp     5f
4:  mov     ah, 0x42
    mov     ch, 0xC0
    int     0x18
    mov     ah, 0x40
    int     0x18
    mov     si, offset tg_r31
    call    ms_raster
    mov     ax, offset sfx_31a
    mov     bx, offset sfx_31v
    mov     dx, offset rd_ph16
    call    rd_av
5:  mov     al, 0x0C
    mov     bh, 0x31
    mov     si, offset md_48
    call    rd_set
    jnc     6f
    mov     si, offset rs_m48
    call    skip_line
    jmp     rd_exit
6:  call    m2_pegc_on
    mov     al, byte ptr [q_save+0]     /* the colour mode to put back is the as-found one */
    mov     byte ptr [m2_q04], al
    mov     ah, 0x40
    int     0x18
    mov     si, offset k_STATE
    call    info_start
    PS      "mode=48 pegc=256 packed"
    call    rd_st
    call    out_nl
    mov     si, offset tg_r48
    call    ms_raster
    mov     ax, offset sfx_48a
    mov     bx, offset sfx_48v
    mov     dx, offset rd_ph48
    call    rd_av
rd_exit:
    call    sec_disarm
    mov     byte ptr [win_ph], 0
    mov     word ptr [tag_sfx], 0
    mov     word ptr [ks_ptr0], offset sweep_ks
    cmp     byte ptr [rd_sw], 0
    je      1f
    mov     byte ptr [rd_sw], 0
    mov     al, byte ptr [rd_al0]
    mov     bh, byte ptr [rd_bh0]
    mov     ah, 0x30
    int     0x18
    mov     ah, 0x0C
    int     0x18
1:  call    m2_pegc_off
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
    mov     si, offset n_pegcbank
    xor     eax, eax
    call    rs_default
    mov     al, 0
    call    grcg_set
    mov     al, 0
    mov     cx, 4
2:  out     0x7E, al
    loop    2b
    mov     si, offset n_7e
    xor     eax, eax
    call    rs_default
    cmp     byte ptr [rd_tsaved], 0
    je      4f
    mov     byte ptr [rd_tsaved], 0
    mov     al, 1
    call    rd_tram
    call    rd_tcmp
    mov     si, offset n_tram3
    xor     eax, eax
    mov     cx, 0x0204
    mov     bl, 3
    call    rs_line
4:  cmp     byte ptr [ms_disp], 0
    je      6f
    mov     byte ptr [ms_disp], 0
    mov     ah, 0x41
    int     0x18
    mov     ch, 0x80
    test    byte ptr [ms_bda0 + 1], 0x04
    jz      5f
    mov     ch, 0xC0
5:  mov     ah, 0x42
    int     0x18
    test    byte ptr [ms_bda0], 0x80
    jz      51f
    mov     ah, 0x40
    int     0x18
51: call    ms_bda
    and     al, 0x80
    movzx   edx, al
    movzx   eax, byte ptr [ms_bda0]
    and     al, 0x80
    mov     si, offset n_b54c
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    call    ms_bda
    and     ah, 0x04
    movzx   edx, ah
    movzx   eax, byte ptr [ms_bda0 + 1]
    and     al, 0x04
    mov     si, offset n_b54d
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
6:  call    rd_q31
    movzx   eax, byte ptr [rd_al0]
    movzx   edx, byte ptr [rd_al]
    mov     si, offset n_ah31al
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    movzx   eax, byte ptr [rd_bh0]
    movzx   edx, byte ptr [rd_bh]
    mov     si, offset n_ah31bh
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    mov     dx, 0x09A8
    in      al, dx
    and     al, 1
    movzx   edx, al
    movzx   eax, byte ptr [rd_p9a8]
    and     al, 1
    mov     si, offset n_9a8
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    mov     si, offset k_I
    call    info_start
    PS      "sync_to="
    movzx   eax, word ptr [ms_to]
    call    out_d
    call    out_nl
    call    gfx_restore_common
    call    sec_end
    ret

    VARS
ks_ptr0:    .word sweep_ks
rd_al:      .byte 0                     /* rd_al, rd_bh: one word (the AH=31h-unsupported test) */
rd_bh:      .byte 0
rd_al0:     .byte 0
rd_bh0:     .byte 0
rd_wal:     .byte 0
rd_wbh:     .byte 0
rd_ret:     .byte 0
rd_p9a8:    .byte 0
rd_sw:      .byte 0
rd_tsaved:  .byte 0
    ENDVARS
