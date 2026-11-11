/* sec_opna4.inc - /OPNA4 (opt-in, XE10U.COM only): a timer start written right after a burst
 * of BUSY-polled FM data writes (todo item 155).
 *
 * WHY. The core latches the timer registers (0x24-0x26, 0x27 bits 3-0) at the guest's write
 * while FM data writes drain through its write queue (pc9821_opna.sv `host_tmr`, the owner's
 * decision (b) of item 155); the YM2608 itself takes a register write only after the BUSY of
 * the write before it (about 25 us after a data write, docs/probes/XE10T-XE10-OPNA2.TXT BUSY
 * rows). /OPNA2's TMRA_3FF/TMRB_FF rows time a 1-count start from an idle chip; no capture
 * times a start written straight after a burst, which is how a PMD-style driver writes it
 * (every write BUSY-polled before the select and before the data, as /OPNA2's o2_put does).
 *
 * THE ROWS (0x188, the -86 board; IRQ12 masked in the slave IMR for the section, IF=0 in a
 * trial). For timer A (NA 0x3FF, 1 count; tag BA_<n>) and timer B (NB 0xFF, 1 count; BB_<n>),
 * bursts of n = 0 (the control: the /OPNA2 shape), 8, 32, 64 and 128 data writes, 8 trials
 * each. A trial: 0x27 <- 30 (stopped, flags reset), the load(s), PIT t0, n BUSY-polled writes
 * cycling over the silent registers TL 0x40-0x4E <- 7F and DT/MUL 0x30-0x3C <- 00 (no key-on,
 * no level raised), PIT t1, then the start: BUSY poll, select 0x27, BUSY poll, PIT t2, data
 * 15 (A: load+enable+reset) / 2A (B), the status read until the flag bit rises (bound 65535
 * reads), PIT t3. Printed per trial: `X OPNA4 <tag> i= reads= pit=(t2..t3) bpit=(t0..t1)`,
 * then `T OPNA4 <tag> trials= start_pit=min/med/max reads=min/med/max burst_pit=min/med/max`.
 * The decoder holds start_pit against the machine's /OPNA2 TMRA_3FF (70..101 PIT counts) and
 * TMRB_FF (101..751) bounds.
 *
 * Then the rows the opna-xe10 lane asked for (items 187 and 18 (c), .build lane report):
 *   RMAP_C / RMAP_O: the base-bank data-port read (0x18A after a select of 0x188, nothing
 *     written) of EVERY register 0x00-0xFF, with 0xA460 bit 0 (the extension) clear, then
 *     set: 16 rows `X OPNA4 RMAP_<C|O> r<h>0=<16 bytes>`. KIT1-XE10-YM29.TXT has 0x00-0x2F
 *     and 0xFF with the extension closed only.
 *   RD29_O: with the extension open, 0x29 read before and after each write of 1F 03 02 01 00
 *     1F (YM29's RD29 row; leaves 0x29 at 1F, its reset value: reboot after).
 *   S3A_A0..S3A_C1: opnapro's STATUS3 (KIT1-XE10-OPNA.TXT) with TIMER A running instead of
 *     timer B: 0x110 <- 00, NA 0 (0x24/0x25 <- 00), 0x27 <- 15, the flag waited for (100 ms
 *     bound, `seen`), then 0x188/0x18C read at once and 100 ms later after 0x110 <- 00 (A),
 *     1F (B) and 00 again (C), IF=0 throughout.
 *
 * RESTORE: as /OPNA2 on 0x188 (o2_rs_all, o2_rs_188: timers stopped, flags reset, loads and
 * scratch registers 0, key-off, TL 0x40 <- 7F), the slave IMR from its read-back, OCW3 left
 * at ISR; the extension-bank list (ADPCM-B reset, 0x110 <- 80 then 1C, ymfm's reset mask)
 * written with the extension open; 0xA460 from its read-back. 0x29 is left at 1F.
 */
tc_opna4:   .asciz "OPNA 0x188/0x18A: 24 25 26 27 29, TL 40-4E <- 7F, DT/MUL 30-3C <- 00 (no key-on), selects 00-FF (read only); 0x18C/0x18E 00 01 10; 0xA460 bit 0; IMR_S bit 4"
tg_o4_rmc:  .asciz "RMAP_C"
tg_o4_rmo:  .asciz "RMAP_O"
tg_o4_rd29: .asciz "RD29_O"
tg_o4_s3a:  .asciz "S3A"
o4_v29:     .byte 0x1F, 0x03, 0x02, 0x01, 0x00, 0x1F, 0xFF
o4_s3tags:  .ascii "A0A1B0B1C0C1"
nm_opna4:   .asciz "OPNA4"
kw_opna4:   .asciz "OPNA4"
f_bpit:     .asciz "burst_pit"
k_bpit:     .asciz "bpit"
o4_tag:     .asciz "BA_000"
o4_n:       .word 0, 8, 32, 64, 128, 0xFFFF
/* the burst registers: (data << 8) | register, 16 entries */
o4_regs:    .word 0x7F40, 0x7F44, 0x7F48, 0x7F4C, 0x7F41, 0x7F45, 0x7F49, 0x7F4D
            .word 0x7F42, 0x7F46, 0x7F4A, 0x7F4E, 0x0030, 0x0034, 0x0038, 0x003C

/* o4_mktag: AL = 'A'/'B', DX = n -> o4_tag = "B<AL>_<nnn>" */
o4_mktag:
    push    ax
    push    dx
    mov     byte ptr [o4_tag + 1], al
    mov     ax, dx
    mov     dl, 100
    div     dl                          /* AL = hundreds, AH = rest */
    add     al, '0'
    mov     byte ptr [o4_tag + 3], al
    mov     al, ah
    xor     ah, ah
    mov     dl, 10
    div     dl
    add     al, '0'
    add     ah, '0'
    mov     byte ptr [o4_tag + 4], al
    mov     byte ptr [o4_tag + 5], ah
    pop     dx
    pop     ax
    ret

/* o4_row: [o4_kind] 0 = A, 1 = B, [o4_cnt] = burst writes. 8 trials. */
o4_row:
    pushad
    mov     word ptr [o2_n], 8
    mov     ax, 0xFFFF
    mov     si, offset o4_tag
    call    row_mark
    xor     di, di
1:  call    wd_check
    cli
    mov     ax, 0x3027
    call    o2_put
    cmp     byte ptr [o4_kind], 0
    jne     2f
    mov     ax, 0xFF24                  /* NA = 0x3FF: 0x24 <- FF, 0x25 <- 03 */
    call    o2_put
    mov     ax, 0x0325
    call    o2_put
    mov     byte ptr [o2_msk], 0x01
    mov     byte ptr [o2_ctl], 0x15
    jmp     3f
2:  mov     ax, 0xFF26                  /* NB = 0xFF */
    call    o2_put
    mov     byte ptr [o2_msk], 0x02
    mov     byte ptr [o2_ctl], 0x2A
3:  call    pit_read
    mov     word ptr [o4_t0], ax
    mov     cx, word ptr [o4_cnt]
    xor     bx, bx
    jcxz    5f
4:  mov     ax, word ptr [o4_regs + bx]
    call    o2_put
    add     bx, 2
    and     bx, 31
    loop    4b
5:  call    pit_read
    movzx   edx, ax
    movzx   eax, word ptr [o4_t0]
    call    pit_sub
    mov     bx, O2_AUX
    call    o2_store
    /* the start */
    call    o2_wait
    mov     dx, word ptr [o2_base]
    mov     al, 0x27
    out     dx, al
    call    o2_wait
    call    pit_read
    mov     si, ax
    add     dx, 2
    mov     al, byte ptr [o2_ctl]
    out     dx, al
    sub     dx, 2
    xor     cx, cx
6:  in      al, dx
    inc     cx
    test    al, byte ptr [o2_msk]
    jnz     7f
    cmp     cx, 0xFFFF
    jb      6b
    inc     word ptr [o2_to]
7:  call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    mov     bx, O2_PIT
    call    o2_store
    movzx   eax, cx
    mov     bx, O2_POLL
    call    o2_store
    mov     ax, 0x3027
    call    o2_put
    sti
    mov     si, offset o4_tag
    call    o2_x
    movzx   eax, di
    mov     si, offset k_i
    call    out_kd
    mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O2_POLL + bx]
    mov     si, offset k_reads
    call    out_kd
    mov     eax, dword ptr [O2_PIT + bx]
    mov     si, offset k_pit
    call    out_kd
    mov     eax, dword ptr [O2_AUX + bx]
    mov     si, offset k_bpit
    call    out_kd
    call    out_nl
    inc     di
    cmp     di, word ptr [o2_n]
    jb      1b
    mov     si, offset k_T
    call    row_start
    mov     si, offset o4_tag
    call    o2_tag
    movzx   eax, word ptr [o2_n]
    mov     si, offset k_trials
    call    out_kd
    mov     cx, word ptr [o2_n]
    mov     bx, O2_PIT
    mov     si, offset f_spit
    call    o2_mmm
    mov     bx, O2_POLL
    mov     si, offset f_reads
    call    o2_mmm
    mov     bx, O2_AUX
    mov     si, offset f_bpit
    call    o2_mmm
    call    out_nl
    popad
    ret

/* o4_rmap: SI = tag. 16 rows of 16 register reads through the base data port. */
o4_rmap:
    pushad
    mov     word ptr [o4_tg], si
    mov     ax, word ptr [o2_base]
    call    row_mark
    xor     bx, bx
1:  call    wd_check
    cli
    xor     di, di
2:  mov     al, bl
    call    o2_get
    mov     byte ptr [o2_v + di], al
    inc     bl
    inc     di
    cmp     di, 16
    jb      2b
    sti
    mov     si, word ptr [o4_tg]
    call    o2_x
    PS      " r"
    mov     al, bl
    sub     al, 16
    call    out_x2
    mov     al, '='
    call    out_c
    xor     di, di
3:  mov     al, byte ptr [o2_v + di]
    call    out_x2
    inc     di
    cmp     di, 16
    jb      3b
    call    out_nl
    test    bl, bl
    jnz     1b
    popad
    ret

/* o4_rd29: the 0x29 write/read pairs (extension open) */
o4_rd29:
    pushad
    mov     si, offset tg_o4_rd29
    mov     ax, word ptr [o2_base]
    call    row_mark
    mov     bx, offset o4_v29
1:  mov     cl, byte ptr [bx]
    cmp     cl, 0xFF
    je      2f
    cli
    mov     al, 0x29
    call    o2_get
    mov     ch, al
    mov     al, 0x29
    mov     ah, cl
    call    o2_put
    mov     al, 0x29
    call    o2_get
    sti
    mov     dl, al
    mov     si, offset tg_o4_rd29
    call    o2_x
    PS      " v29="
    mov     al, cl
    call    out_x2
    PS      " pre="
    mov     al, ch
    call    out_x2
    PS      " post="
    mov     al, dl
    call    out_x2
    call    out_nl
    inc     bx
    jmp     1b
2:  popad
    ret

/* o4_s3rd: the two status reads -> o2_v[DI], o2_v[DI+1]; DI += 2 */
o4_s3rd:
    push    dx
    mov     dx, word ptr [o2_base]
    in      al, dx
    mov     byte ptr [o2_v + di], al
    add     dx, 4
    in      al, dx
    mov     byte ptr [o2_v + di + 1], al
    add     di, 2
    pop     dx
    ret
o4_100ms:
    push    eax
    mov     eax, T_100MS
    call    dl_start
1:  call    dl_check
    jnc     1b
    pop     eax
    ret

/* o4_s3a: STATUS3 with timer A (extension open) */
o4_s3a:
    pushad
    mov     si, offset tg_o4_s3a
    mov     ax, word ptr [o2_base]
    call    row_mark
    cli
    mov     ax, 0x0010
    call    o2_putx
    mov     ax, 0x0024
    call    o2_put
    mov     ax, 0x0025
    call    o2_put
    mov     ax, 0x1527
    call    o2_put
    mov     byte ptr [o4_seen], 0
    mov     eax, T_100MS
    call    dl_start
    mov     dx, word ptr [o2_base]
1:  in      al, dx
    test    al, 0x01
    jnz     2f
    call    dl_check
    jnc     1b
    jmp     3f
2:  mov     byte ptr [o4_seen], 1
3:  xor     di, di
    call    o4_s3rd                     /* A0 */
    call    o4_100ms
    call    o4_s3rd                     /* A1 */
    mov     ax, 0x1F10
    call    o2_putx
    call    o4_s3rd                     /* B0 */
    call    o4_100ms
    call    o4_s3rd                     /* B1 */
    mov     ax, 0x0010
    call    o2_putx
    call    o4_s3rd                     /* C0 */
    call    o4_100ms
    call    o4_s3rd                     /* C1 */
    mov     ax, 0x3027
    call    o2_put
    sti
    xor     di, di
    xor     bx, bx
4:  mov     si, offset k_X
    call    row_start
    PS      "S3A_"
    mov     al, byte ptr [o4_s3tags + bx]
    call    out_c
    mov     al, byte ptr [o4_s3tags + bx + 1]
    call    out_c
    PS      " seen="
    movzx   eax, byte ptr [o4_seen]
    call    out_d
    PS      " st188="
    mov     al, byte ptr [o2_v + di]
    call    out_x2
    PS      " st18C="
    mov     al, byte ptr [o2_v + di + 1]
    call    out_x2
    call    out_nl
    add     di, 2
    add     bx, 2
    cmp     bx, 12
    jb      4b
    popad
    ret

sec_opna4:
    mov     si, offset nm_opna4
    mov     eax, WD_20S
    mov     bx, offset o4_exit
    call    sec_begin
    mov     byte ptr [o2_ran], 0
    mov     word ptr [tag_sfx], 0
    mov     word ptr [o2_base], 0x188
    call    opna_drvchk
    jnc     1f
    mov     si, offset rs_tsr
    call    skip_line
    jmp     o4_end
1:  in      al, 0x0A
    mov     byte ptr [o2_imrs], al
    mov     byte ptr [o4_extw], 0
    mov     dx, 0xA460
    in      al, dx
    mov     byte ptr [o2_a460], al
    mov     si, offset k_STATE
    call    info_start
    PS      "imr_s="
    mov     al, byte ptr [o2_imrs]
    call    out_x2
    PS      " a460="
    mov     al, byte ptr [o2_a460]
    call    out_x2
    PS      " st188="
    mov     dx, 0x188
    in      al, dx
    mov     byte ptr [o2_sts], al
    call    out_x2
    call    out_nl
    cmp     byte ptr [o2_sts], 0xFF
    jne     2f
    mov     si, offset rs_absent
    call    skip_line
    jmp     o4_end
2:  mov     byte ptr [o2_ran], 1
    mov     word ptr [o2_to], 0
    cli
    mov     al, byte ptr [o2_imrs]
    or      al, 0x10                    /* IRQ12 (slave IR4) masked for the section */
    out     0x0A, al
    sti
    mov     byte ptr [o4_kind], 0
3:  mov     si, offset o4_n
4:  lodsw
    cmp     ax, 0xFFFF
    je      5f
    mov     word ptr [o4_cnt], ax
    mov     dx, ax
    mov     al, 'A'
    add     al, byte ptr [o4_kind]
    call    o4_mktag
    push    si
    call    o4_row
    pop     si
    jmp     4b
5:  inc     byte ptr [o4_kind]
    cmp     byte ptr [o4_kind], 2
    jb      3b
    /* the opna-xe10 lane's rows: the read map closed and open, RD29 and STATUS3 with timer A */
    mov     byte ptr [o4_extw], 1
    mov     al, byte ptr [o2_a460]
    and     al, 0xFE
    call    o2_a460w
    mov     si, offset tg_o4_rmc
    call    o4_rmap
    mov     al, byte ptr [o2_a460]
    or      al, 1
    call    o2_a460w
    mov     si, offset tg_o4_rmo
    call    o4_rmap
    call    o4_rd29
    call    o4_s3a
    cmp     word ptr [o2_to], 0
    je      o4_exit
    mov     si, offset to_o2
    call    timeout_line
o4_exit:
    call    sec_disarm
    cmp     byte ptr [o2_ran], 0
    je      o4_end
    cli
    mov     word ptr [o2_base], 0x188
    mov     si, offset o2_rs_all
    call    o2_putlist
    mov     si, offset o2_rs_188
    call    o2_putlist
    cmp     byte ptr [o4_extw], 0
    je      1f
    mov     al, byte ptr [o2_a460]
    or      al, 1
    call    o2_a460w
    mov     si, offset o2_rs_ext
    call    o2_putlistx
    mov     al, byte ptr [o2_a460]
    call    o2_a460w
1:  mov     al, 0x0B                    /* the slave PIC's read register: ISR */
    out     0x08, al
    mov     al, byte ptr [o2_imrs]
    out     0x0A, al
    sti
    cmp     byte ptr [o4_extw], 0
    je      2f
    mov     dx, 0xA460
    mov     al, byte ptr [o2_a460]
    mov     si, offset n_a460
    call    rs_port8
2:  mov     al, byte ptr [o2_imrs]
    mov     dx, 0x0A
    mov     si, offset n_imrs2
    call    rs_port8
    mov     si, offset n_opna2r
    xor     eax, eax
    call    rs_default
o4_end:
    call    sec_end
    ret

    VARS
o4_t0:      .word 0
o4_cnt:     .word 0
o4_kind:    .byte 0
o4_seen:    .byte 0
o4_extw:    .byte 0
o4_tg:      .word 0
    ENDVARS
