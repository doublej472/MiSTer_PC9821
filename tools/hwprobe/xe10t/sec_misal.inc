/* sec_misal.inc - /MISAL (opt-in, XE10V.COM only): the GVRAM store cost by alignment, with
 * the graphics display stopped and started.
 *
 * WHY. The core's Xe10 store table (pc9821_gvram_arb.sv, the timing_xe10 path) charges a
 * byte-misaligned word one store period when it stays inside a dword and two when it crosses
 * a dword boundary; no capture measures either. The only misaligned row the machine has is
 * /GVRAM W16ODD (plain stores at DI = 1, 3, 5, ...: docs/probes/XE10T-XE10.TXT, 625 ARTIC
 * ticks per 8192 against W16's 362), which mixes the two cases and has the GRCG off. Rusty's
 * C-Lab logo wipe blits `rep movsw` rows of 20 words to odd addresses with the GRCG in RMW mode
 * and the graphics display on (docs/probes/RWIPE-XE10.TXT); its rows run 8.6 % slower on the
 * core than on the machine. The table also marks the TDW word, every dword class and the plain
 * stores with the graphics display on as unmeasured (todo item 151): every /GVRAM and /GRCG row
 * so far ran at the DOS prompt, with the graphics display stopped.
 *
 * THE ROWS. Three store modes, each with the same shapes (tags <MODE>_<SHAPE>):
 *   mode RMW: 0x7C <- C0 (read-modify-write), tile FF,00,FF,00 (as /GRCG);
 *   mode TDW: 0x7C <- 80 (tile data write), the same tile;
 *   mode PLN: 0x7C <- 00 (GRCG off: a plain plane-B store).
 * Shapes, all on plane B (0xA8000) inside the first 4 KiB (displayed lines 0-51):
 *   W0 W1 W2 W3  `mov word es:[di], ax` at DI = 0, 1, 2, 3 with DI += 4 (swept 0..32 nops):
 *                every store of a row has the same offset in its dword, so W1 is a misaligned
 *                word inside a dword and W3 a word across a dword boundary (W2 an aligned word
 *                in the upper half, the control for W0);
 *   WA           the same store at DI = 1 with DI += 2 (swept): offsets 1, 3, 1, 3, ... as
 *                /GVRAM W16ODD, the link to the existing capture;
 *   B0           `mov byte es:[di], al`, DI += 1 (swept): the byte control;
 *   D0           `mov dword es:[di], eax`, DI += 4 (swept): the aligned dword;
 *   SW0 SW1 SW3  `rep stosw` of 1024 words from DI = 0, 1, 3 (a word string from an odd DI
 *                alternates offsets 1 and 3);
 *   MW0 MW1 MW3  `rep movsw` of 1024 words from the RAM buffer (SI = 0) to DI = 0, 1, 3;
 *   BL0 BL1      (RMW and PLN only) Rusty's row shape: 50 rows of `mov cx, 20; rep movsw`
 *                from the RAM buffer, DI += 80 per row, from DI = 0 and 1.
 * n = 1024 words or bytes, 512 dwords, 50 rows per window: a window lasts at most about
 * 0.7 ms, so it fits inside the vertical blank (below).
 *
 * THREE PHASES, the same rows each time (the tag ends in the phase):
 *   _O  graphics display stopped (INT 18h AH=41h): the prompt state of every earlier row;
 *   _A  INT 18h AH=42h CH=C0 (640x400, display bank 0) and AH=40h (graphics display on); each
 *       timed window starts MS_ADELAY ARTIC ticks (2 ms) after the falling edge of VSYNC
 *       (master GDC status 0x60 bit 5), inside the active lines;
 *   _V  the same display, each window started at the rising edge of VSYNC: inside the
 *       vertical blank.
 * Why those two places: the BIOS's 24 kHz 400-line SYNC block has 400 active lines, a 7-line
 * front porch, 8 lines of VSYNC and a 25-line back porch (440 lines; xe10t_decode.py
 * RASTER_LINES cites it), so the blank lasts 33 lines (about 1.33 ms) from the VSYNC rise and
 * the active lines start 25 lines (about 1.0 ms) after its fall and last about 16.1 ms. The
 * machine's RMW rate differs between the two: in docs/probes/RWIPE-XE10.TXT the wipe steps
 * whose 4000-word fill lies in the blank take 314 ARTIC ticks, the others 368, and 314 is the
 * prompt-time rate of /GRCG RMWSTOSW in XE10T-XE10.TXT (pc9821_gvram_arb.sv's table cites
 * both). The sync is ms_sync, called by time_call (lib.inc,
 * XE10V only) before each window's ARTIC edge while [win_ph] is set; the control and the body
 * windows (and if1) are each synced. Its polls are bounded by MS_SPIN reads; an expired poll
 * counts in sync_to= (the I line at the end), and that window then starts unsynced.
 * Before the _O rows and again after the display is on, a `P MISAL RASTER_<O|G>` row times
 * 8 frames (art=, rising edge to rising edge) and the VSYNC pulse (hi= summed over them), so
 * the decoder can check each window against the measured raster.
 *
 * STATE: the as-found BDA 0x054C (bit 7: the BIOS's graphics-display-on flag) and 0x054D
 * (bit 2: the 400-line mode; NP2kai bios/bios18.c bios0x18_40/41/42 keep both) and port 0x31
 * (the DIP-switch read the RWIPE rows also print: bit 7 is the GDC clock switch).
 *
 * RESTORE: GRCG off and the tile 0 (as /GRCG), EGC off and access page 0 (gfx_restore_common);
 * the display: AH=41h, then AH=42h CH=C0 if 0x054D bit 2 was set, else CH=80 (200 lines,
 * scroll 0), then AH=40h if 0x054C bit 7 was set; RESTORE lines for those two BDA bits
 * against their as-found values. GVRAM plane B is scribbled (not saved), as /GVRAM.
 */
    .equ MS_ADELAY, 614                 /* 2.0 ms after the VSYNC fall: inside the active lines */
    .equ MS_SPIN,   0x00400000          /* reads of 0x60 per ms_sync (> 0.3 s at 80 ns a read) */

TPL m_set0, "mov ax, 0xA800; mov es, ax; xor di, di; mov eax, 0x55AA55AA"
TPL m_set1, "mov ax, 0xA800; mov es, ax; mov di, 1; mov eax, 0x55AA55AA"
TPL m_set2, "mov ax, 0xA800; mov es, ax; mov di, 2; mov eax, 0x55AA55AA"
TPL m_set3, "mov ax, 0xA800; mov es, ax; mov di, 3; mov eax, 0x55AA55AA"
TPL m_ssw0, "mov ax, 0xA800; mov es, ax; mov eax, 0x55AA55AA; xor di, di; mov cx, 1024"
TPL m_ssw1, "mov ax, 0xA800; mov es, ax; mov eax, 0x55AA55AA; mov di, 1; mov cx, 1024"
TPL m_ssw3, "mov ax, 0xA800; mov es, ax; mov eax, 0x55AA55AA; mov di, 3; mov cx, 1024"
TPL m_smw0, "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; xor si, si; xor di, di; mov cx, 1024"
TPL m_smw1, "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; xor si, si; mov di, 1; mov cx, 1024"
TPL m_smw3, "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; xor si, si; mov di, 3; mov cx, 1024"
TPL m_sbl0, "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; xor si, si; xor di, di"
TPL m_sbl1, "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; xor si, si; mov di, 1"
/* Rusty's row: 20 words, then the next row 80 bytes on (the movsw moved DI by 40) */
TPL m_blit,  "mov cx, 20; rep movsw"
TPL m_bladv, "add di, 40; xor si, si"

/* MSTAB p: the shapes every mode has, tags "<p>_<shape>" */
    .macro MSTAB p
    CASE "\p\()_W0",  "w",   1024, 128, 8, m_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "\p\()_W1",  "w",   1024, 128, 8, m_set1, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "\p\()_W2",  "w",   1024, 128, 8, m_set2, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "\p\()_W3",  "w",   1024, 128, 8, m_set3, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "\p\()_WA",  "w",   1024, 128, 8, m_set1, g_w16, g_adv2, g_nil, CF_SWEEP
    CASE "\p\()_B0",  "b",   1024, 128, 8, m_set0, g_w8,  g_adv1, g_nil, CF_SWEEP
    CASE "\p\()_D0",  "d",   512,  64,  8, m_set0, g_w32, g_adv4, g_nil, CF_SWEEP
    CASE "\p\()_SW0", "w",   1024, 1,   1, m_ssw0, g_stosw, g_nil, g_nil
    CASE "\p\()_SW1", "w",   1024, 1,   1, m_ssw1, g_stosw, g_nil, g_nil
    CASE "\p\()_SW3", "w",   1024, 1,   1, m_ssw3, g_stosw, g_nil, g_nil
    CASE "\p\()_MW0", "w",   1024, 1,   1, m_smw0, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "\p\()_MW1", "w",   1024, 1,   1, m_smw1, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "\p\()_MW3", "w",   1024, 1,   1, m_smw3, g_movsw, g_nil, g_post_ds, CF_BUF
    .endm
    .macro MSBL p
    CASE "\p\()_BL0", "row", 50,   10,  5, m_sbl0, m_blit, m_bladv, g_post_ds, CF_BUF
    CASE "\p\()_BL1", "row", 50,   10,  5, m_sbl1, m_blit, m_bladv, g_post_ds, CF_BUF
    .endm

tab_ms_rmw:
    MSTAB RMW
    MSBL  RMW
    ENDTAB
tab_ms_tdw:
    MSTAB TDW
    ENDTAB
tab_ms_pln:
    MSTAB PLN
    MSBL  PLN
    ENDTAB
tl_misal:   .word tab_ms_rmw, tab_ms_tdw, tab_ms_pln, 0
tc_misal:   .asciz "GVRAM-B 0x0000-0x0FFF(scribbled) 0x7C=C0/80/00 0x7E(tile x4) 0x6A=07,04,06 0xA6=00 INT18h AH=41/42(CH=C0)/40 then 41/42/40 as found"
nm_misal:   .asciz "MISAL"
kw_misal:   .asciz "MISAL"
n_b54c:     .asciz "BDA054C_BIT7"
n_b54d:     .asciz "BDA054D_BIT2"
tg_ras_o:   .asciz "RASTER_O"
tg_ras_g:   .asciz "RASTER_G"
sfx_ph_o:   .asciz "_O"
sfx_ph_a:   .asciz "_A"
sfx_ph_v:   .asciz "_V"

/* ms_sync: called by time_call (XE10V) before the window's ARTIC edge while [win_ph] != 0.
 * [win_ph] 1: the next VSYNC fall, then MS_ADELAY ticks; 2: the next VSYNC rise. Preserves
 * every register; an expired poll counts in [ms_to]. */
ms_sync:
    push    eax
    push    ecx
    mov     ecx, MS_SPIN
1:  in      al, 0x60                    /* VSYNC low first, so the rise is an edge */
    test    al, 0x20
    jz      2f
    dec     ecx
    jnz     1b
    jmp     8f
2:  in      al, 0x60
    test    al, 0x20
    jnz     3f
    dec     ecx
    jnz     2b
    jmp     8f
3:  cmp     byte ptr [win_ph], 2
    je      9f
4:  in      al, 0x60                    /* phase A: the fall, then the delay */
    test    al, 0x20
    jz      5f
    dec     ecx
    jnz     4b
    jmp     8f
5:  call    artic_read
    mov     dword ptr [ms_t0], eax
6:  mov     eax, dword ptr [ms_t0]
    call    artic_since
    cmp     eax, MS_ADELAY
    jae     9f
    dec     ecx
    jnz     6b
8:  inc     word ptr [ms_to]
9:  pop     ecx
    pop     eax
    ret

/* ms_raster: SI = tag. Under cli: 8 frames from a VSYNC rise, the total and the summed
 * VSYNC-high time -> `P MISAL <tag> frames=8 art= hi= to=`. */
ms_raster:
    pushad
    push    si
    cli
    xor     esi, esi                    /* summed high ticks */
    xor     edi, edi                    /* expired polls */
    mov     ecx, MS_SPIN
1:  in      al, 0x60
    test    al, 0x20
    jz      2f
    dec     ecx
    jnz     1b
    inc     edi
2:  in      al, 0x60
    test    al, 0x20
    jnz     3f
    dec     ecx
    jnz     2b
    inc     edi
3:  call    artic_read
    mov     dword ptr [ms_t0], eax
    mov     ebp, eax                    /* this frame's rise */
    mov     bx, 8
4:  mov     ecx, MS_SPIN
5:  in      al, 0x60                    /* the fall */
    test    al, 0x20
    jz      6f
    dec     ecx
    jnz     5b
    inc     edi
6:  call    artic_read
    sub     eax, ebp
    and     eax, 0x00FFFFFF
    add     esi, eax
    mov     ecx, MS_SPIN
7:  in      al, 0x60                    /* the next rise */
    test    al, 0x20
    jnz     8f
    dec     ecx
    jnz     7b
    inc     edi
8:  call    artic_read
    mov     ebp, eax
    dec     bx
    jnz     4b
    sti
    mov     dword ptr [ms_hi], esi
    mov     dword ptr [ms_rto], edi
    mov     eax, ebp
    sub     eax, dword ptr [ms_t0]
    and     eax, 0x00FFFFFF
    mov     dword ptr [ms_t0], eax
    mov     si, offset k_P
    call    row_start
    pop     si
    call    out_s
    PS      " frames=8 art="
    mov     eax, dword ptr [ms_t0]
    call    out_d
    PS      " hi="
    mov     eax, dword ptr [ms_hi]
    call    out_d
    PS      " to="
    mov     eax, dword ptr [ms_rto]
    call    out_d
    call    out_nl
    popad
    ret

/* ms_bda: AL = 0:054C, AH = 0:054D */
ms_bda:
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, word ptr es:[0x054C]
    pop     es
    ret

ms_state_bda:
    push    ax
    PS      " bda054C="
    call    ms_bda
    call    out_x2
    PS      " bda054D="
    call    ms_bda
    mov     al, ah
    call    out_x2
    pop     ax
    ret

ms_rearm:                               /* the watchdog budget is per mode and phase */
    push    eax
    call    artic_read
    mov     dword ptr [wd_t0], eax
    pop     eax
    ret

/* ms_modes: the three mode tables in the phase [tag_sfx] names. */
ms_modes:
    call    ms_rearm
    mov     si, offset k_STATE
    call    info_start
    PS      "grcg=C0 tile=FF,00,FF,00 phase="
    mov     si, word ptr [tag_sfx]
    call    out_s
    call    out_nl
    mov     al, 0xC0
    call    grcg_set
    mov     si, offset tab_ms_rmw
    call    run_list
    call    ms_rearm
    mov     si, offset k_STATE
    call    info_start
    PS      "grcg=80 tile=FF,00,FF,00 phase="
    mov     si, word ptr [tag_sfx]
    call    out_s
    call    out_nl
    mov     al, 0x80
    call    grcg_set
    mov     si, offset tab_ms_tdw
    call    run_list
    call    ms_rearm
    mov     si, offset k_STATE
    call    info_start
    PS      "grcg=00 phase="
    mov     si, word ptr [tag_sfx]
    call    out_s
    call    out_nl
    mov     al, 0
    out     0x7C, al
    mov     si, offset tab_ms_pln
    call    run_list
    ret

sec_misal:
    mov     si, offset nm_misal
    mov     eax, WD_60S
    mov     bx, offset ms_exit
    call    sec_begin
    mov     byte ptr [win_ph], 0
    mov     word ptr [ms_to], 0
    mov     word ptr [tag_sfx], 0
    call    gfx_off
    call    gfx_state
    call    ms_bda
    mov     word ptr [ms_bda0], ax
    mov     byte ptr [ms_disp], 1        /* the display is the probe's from here */
    mov     si, offset k_STATE
    call    info_start
    PS      "as_found"
    call    ms_state_bda
    PS      " p31="
    in      al, 0x31
    call    out_x2
    PS      " adelay="
    mov     eax, MS_ADELAY
    call    out_d
    call    out_nl
    /* phase O: the graphics display stopped */
    mov     ah, 0x41
    int     0x18
    mov     si, offset tg_ras_o
    call    ms_raster
    mov     word ptr [tag_sfx], offset sfx_ph_o
    call    ms_modes
    mov     word ptr [tag_sfx], 0
    /* the graphics display on: 640x400, bank 0 */
    mov     al, 0
    out     0x7C, al
    mov     ah, 0x42
    mov     ch, 0xC0
    int     0x18
    mov     ah, 0x40
    int     0x18
    mov     si, offset k_STATE
    call    info_start
    PS      "gfx=on ah42=C0"
    call    ms_state_bda
    call    out_nl
    mov     si, offset tg_ras_g
    call    ms_raster
    mov     byte ptr [win_ph], 1
    mov     word ptr [tag_sfx], offset sfx_ph_a
    call    ms_modes
    mov     byte ptr [win_ph], 2
    mov     word ptr [tag_sfx], offset sfx_ph_v
    call    ms_modes
ms_exit:
    call    sec_disarm
    mov     byte ptr [win_ph], 0
    mov     word ptr [tag_sfx], 0
    mov     al, 0
    call    grcg_set                    /* GRCG off, tile FF,00,FF,00 */
    mov     al, 0
    mov     cx, 4
1:  out     0x7E, al                    /* tile back to 0 (the documented default) */
    loop    1b
    mov     si, offset n_7e
    xor     eax, eax
    call    rs_default
    cmp     byte ptr [ms_disp], 0
    je      3f
    mov     byte ptr [ms_disp], 0
    mov     ah, 0x41
    int     0x18
    mov     ch, 0x80                    /* 200 lines, scroll 0 */
    test    byte ptr [ms_bda0 + 1], 0x04
    jz      2f
    mov     ch, 0xC0
2:  mov     ah, 0x42
    int     0x18
    test    byte ptr [ms_bda0], 0x80
    jz      21f
    mov     ah, 0x40
    int     0x18
21: call    ms_bda
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
3:  mov     si, offset k_I
    call    info_start
    PS      "sync_to="
    movzx   eax, word ptr [ms_to]
    call    out_d
    call    out_nl
    call    gfx_restore_common
    call    sec_end
    ret

    VARS
    .p2align 2
ms_t0:      .long 0
ms_hi:      .long 0
ms_rto:     .long 0
ms_bda0:    .word 0
ms_to:      .word 0
win_ph:     .byte 0
ms_disp:    .byte 0
    ENDVARS
