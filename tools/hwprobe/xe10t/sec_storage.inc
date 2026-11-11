/* sec_storage.inc - /IDE (in /ALL), /FDC and /CD (opt-in): storage latencies.
 *
 * Nothing here writes a disk. The only ATA commands are IDENTIFY DEVICE 0xEC (the /IDE
 * device scan) and READ SECTORS 0x20 (C0/H0/S1..S8, one device's own boot area); the
 * only ATAPI commands are IDENTIFY PACKET DEVICE, TEST UNIT READY, REQUEST SENSE,
 * READ(10), READ SUB-CHANNEL, PLAY AUDIO MSF, STOP PLAY/SCAN and PAUSE; the only FDC
 * commands are SENSE DRIVE STATUS, SENSE INTERRUPT STATUS, RECALIBRATE, SEEK, READ ID and
 * READ DATA. IRQ9 (IDE) and IR11 (FDC) are masked around the commands and
 * the slave IMR is restored from the as-found byte. Every wait has an ARTIC deadline and a
 * TIMEOUT line (R7). Windows longer than one PIT period (the FDC and CD rows) are reported
 * in ARTIC ticks only (`_art`); the IDE rows carry both columns.
 *
 * /IDE (tools/hwprobe/idelat's rows): the first ATA device found (bank 1 then bank 0 of
 * 0x0432, master, answering IDENTIFY DEVICE; bank 1 first because the option ROM selects
 * it, idelat.s), 16 single-
 * sector READs of S1 (command -> first DRQ, the 256-word `in ax,dx` block, final status;
 * trial 0 is the cold one) and one 8-sector READ (per-sector DRQ wait and transfer).
 *
 * /FDC (dmaroute's fix-lane FDC discipline): DA from DA= (0x90-0x93) or 0x90 then 0x91.
 * Motor on only as the BIOS does it (0x0480 bit 4 set: 0x0485 <- 0, 0x94 <- 0x08), 500 ms
 * ARTIC spin-up, SENSE DRIVE STATUS before and after, the BIOS's MSR settle (ten 0x5F writes)
 * after every data-port access, RECALIBRATE, then SEEK 0->40->0 x3, READ ID x20 back to back
 * (completion spacing: the sector pitch and rotation), READ DATA x20 of C0/H0/R1 by DMA
 * channel 2 (completion to completion: one rotation) and one READ DATA R1..R8 (the per-byte
 * rate). Afterwards the motor is handed back as the BIOS does after its own read (0x0485 <-
 * [0x05CB], 0x94 <- 0x09, 0x0C), the held IR11 request is taken by an EOI-only handler and
 * the vector restored. 0x00BE/0x04BE are never written.
 *
 * /CD: the first ATAPI device on bank 1 master/slave, then bank 0 slave (IDENTIFY PACKET
 * DEVICE answers). TEST UNIT READY, READ(10) of LBA 16 cold then x4 warm, READ TOC, PLAY
 * AUDIO MSF for 3 s from the first audio track (00:02:00 when none) -> READ SUB-CHANNEL
 * polled until audio status 0x11 (time to playing),
 * then STOP PLAY/SCAN (PAUSE as fallback). A CHECK CONDITION prints REQUEST SENSE's key/ASC.
 */
tc_ide:     .asciz "0x432(bank,saved,restored) 0x0A(IMR bit1,restored) 0x644-0x64E(task file, IDENTIFY DEVICE 0xEC and READ SECTORS 0x20 only)"
tc_fdc:     .asciz "0x0A(IMR bit3,restored) IVT[13](EOI stub,restored) 0x92(SDS/SIS/RECAL/SEEK/READID/READDATA) 0x94=08,09,0C(only if 0480.4) BDA0485 DMA-ch2(0x09,0x0B,0x15,0x17,0x19,0x23; count 0x0B read) RAM-buffer"
tc_cd:      .asciz "0x432(bank,saved,restored) 0x0A(IMR bit1,restored) 0x640-0x64E(ATAPI packets: A1,00,03,28,43,42,47,4E,4B)"

/* ======================================================================== common */
/* sm_mark: DI = 6-byte record <- {ARTIC dword, PIT word} now (PIT read first). */
sm_mark:
    push    eax
    call    pit_read
    mov     word ptr [di+4], ax
    call    artic_read
    mov     dword ptr [di], eax
    pop     eax
    ret

/* sm_diff: SI = start record, DI = end record -> EAX = ARTIC ticks, EDX = PIT counts. */
sm_diff:
    push    ebx
    movzx   eax, word ptr [si+4]
    movzx   edx, word ptr [di+4]
    call    pit_sub
    mov     ebx, eax
    mov     eax, dword ptr [di]
    sub     eax, dword ptr [si]
    and     eax, 0x00FFFFFF
    mov     edx, ebx
    pop     ebx
    ret

io_settle:                              /* ten writes to the 0x5F wait port */
    push    ax
    push    cx
    mov     cx, 10
1:  out     0x5F, al
    loop    1b
    pop     cx
    pop     ax
    ret

/* out_kx2: SI = key -> " key=HH" (AL) */
out_kx2:
    call    out_sp
    call    out_s
    push    ax
    mov     al, '='
    call    out_c
    pop     ax
    jmp     out_x2

/* ======================================================================== ATA helpers */
/* ata_wait: wait until (status & BL) == BH; EAX = deadline (ticks). AL = last status,
 * CF = timeout. Polls 0x64E, a deadline check every 32 polls. */
ata_wait:
    push    cx
    push    dx
    call    dl_start
    mov     dx, 0x064E
1:  mov     cx, 32
2:  in      al, dx
    mov     ah, al
    and     ah, bl
    cmp     ah, bh
    je      3f
    loop    2b
    call    dl_check
    jnc     1b
    stc
    jmp     4f
3:  clc
4:  pop     dx
    pop     cx
    ret

/* ata_wait_drq: wait for BSY clear and (DRQ or ERR). EAX = deadline. AL = status, CF = to. */
ata_wait_drq:
    push    cx
    push    dx
    call    dl_start
    mov     dx, 0x064E
1:  mov     cx, 32
2:  in      al, dx
    test    al, 0x80
    jnz     3f
    test    al, 0x09
    jnz     4f
3:  loop    2b
    call    dl_check
    jnc     1b
    stc
    jmp     5f
4:  clc
5:  pop     dx
    pop     cx
    ret

/* ata_drain: a bounded BSY wait, then consume pending DRQ blocks (at most 32 x 256 words),
 * so a failed trial leaves nothing pending. */
ata_drain:
    pushad
    mov     bx, 0x0080
    mov     eax, T_1S
    call    ata_wait
    mov     si, 32
1:  mov     dx, 0x064E
    in      al, dx
    test    al, 0x80
    jnz     2f
    test    al, 0x08
    jz      2f
    mov     dx, 0x0640
    mov     cx, 256
3:  in      ax, dx
    loop    3b
    dec     si
    jnz     1b
2:  mov     bx, 0x0080
    mov     eax, T_1S
    call    ata_wait
    popad
    ret

/* irq9_mask / irq9_restore: slave IMR bit 1 around a command (as-found byte in [st_imr]). */
irq9_mask:
    push    ax
    mov     al, byte ptr [st_imr]
    or      al, 0x02
    out     0x0A, al
    pop     ax
    ret
irq9_restore:
    push    ax
    mov     al, byte ptr [st_imr]
    out     0x0A, al
    pop     ax
    ret

/* ata_select: AL = device byte (0xA0/0xB0) -> 0x64C, settle; AL = status after. */
ata_select:
    push    dx
    mov     dx, 0x064C
    out     dx, al
    call    io_settle
    call    io_settle
    mov     dx, 0x064E
    in      al, dx
    pop     dx
    ret

/* st_mark: SI = tag, AX = port. A flushed ROW line written with the as-found bank selected:
 * the DOS write goes through the BIOS disk driver, which must find the bank DOS left. The
 * caller reselects its own bank (and device) afterwards. Between marks the section holds
 * the output buffer (fl_hold), so no DOS write happens while another bank is selected. */
st_mark:
    push    ax
    cmp     byte ptr [st_bankw], 0
    je      1f
    mov     al, byte ptr [st_bank]
    call    bank_set
1:  pop     ax
    mov     byte ptr [fl_hold], 0
    call    row_mark
    mov     byte ptr [fl_hold], 1
    ret

/* bank_set: AL = bank -> 0x432 */
bank_set:
    push    dx
    mov     dx, 0x0432
    out     dx, al
    call    io_settle
    pop     dx
    ret

/* ======================================================================== /IDE */
sec_ide:
    mov     si, offset nm_ide
    mov     eax, WD_20S
    mov     bx, offset ide_exit
    call    sec_begin
    mov     byte ptr [st_bankw], 0
    in      al, 0x0A
    mov     byte ptr [st_imr], al
    mov     dx, 0x0432
    in      al, dx
    mov     byte ptr [st_bank], al
    mov     si, offset k_STATE
    call    info_start
    PS      "bank432="
    call    out_x2
    PS      " imr_s="
    mov     al, byte ptr [st_imr]
    call    out_x2
    call    out_nl
    /* find an ATA device: bank 1 then bank 0, master. The ATAPI signature in the cylinder
     * registers is only guaranteed after a reset or an aborted command (the core's CD on
     * bank 1 master read st=50 sig=0200 here, 2026-11-01, and took every READ SECTORS as
     * an abort), so a candidate must also answer IDENTIFY DEVICE as an ATA device: a
     * PACKET device aborts it (NP2kai ideio.c: 0xEC on a CD-ROM is drvreset + cmdabort).
     * The signature is read before IDENTIFY, which rewrites it. */
    mov     byte ptr [st_bankw], 1
    mov     byte ptr [id_try], 1
id_scan:
    mov     si, offset tg_scan0
    cmp     byte ptr [id_try], 0
    je      12f
    mov     si, offset tg_scan1
12: mov     ax, 0x0432
    call    st_mark
    mov     al, byte ptr [id_try]
    call    bank_set
    mov     al, 0xA0
    call    ata_select
    mov     byte ptr [id_st], al
    mov     dx, 0x0648
    in      al, dx
    mov     ah, al
    mov     dx, 0x064A
    in      al, dx
    mov     word ptr [id_sig], ax
    mov     byte ptr [id_ata], 0
    mov     al, byte ptr [id_st]
    cmp     al, 0xFF
    je      1f
    test    al, 0x40                    /* DRDY: a device is ready */
    jz      1f
    cmp     word ptr [id_sig], 0x14EB   /* the ATAPI signature: not a disk */
    je      1f
    call    ide_identify
1:  mov     si, offset k_X
    call    row_start
    PS      "PROBE bank="
    mov     al, byte ptr [id_try]
    call    out_x2
    mov     si, offset kk_st
    mov     al, byte ptr [id_st]
    call    out_kx2
    PS      " sig="
    mov     ax, word ptr [id_sig]
    call    out_x4
    PS      " ata="
    movzx   eax, byte ptr [id_ata]
    call    out_d
    call    out_nl
    cmp     byte ptr [id_ata], 0
    je      id_next
    jmp     id_found
id_next:
    cmp     byte ptr [id_try], 0
    je      id_none
    mov     byte ptr [id_try], 0
    jmp     id_scan
id_none:
    mov     si, offset rs_nodrive
    call    skip_line
    jmp     ide_exit
id_found:
    mov     si, offset k_I
    call    info_start
    PS      "using bank="
    mov     al, byte ptr [id_try]
    call    out_x2
    PS      " dev=A0 cmd=20 chs=0/0/1"
    call    out_nl
    mov     si, offset tg_iread
    mov     ax, 0x0640
    call    st_mark                     /* the reads: the data port only with DRQ */
    mov     al, byte ptr [id_try]
    call    bank_set
    /* (a) 16 single-sector reads */
    call    tr_reset
    mov     word ptr [tr_names], offset ide_names
    mov     word ptr [id_i], 0
1:  mov     word ptr [id_count], 1
    call    ide_read
    mov     si, offset k_X
    call    row_start
    PS      "R1 i="
    movzx   eax, word ptr [id_i]
    call    out_d
    call    ide_xfields
    cmp     byte ptr [id_fail], 0
    jne     2f
    xor     bx, bx
    mov     eax, dword ptr [id_dart]
    call    tr_put
    inc     bx
    mov     eax, dword ptr [id_dpit]
    call    tr_put
    inc     bx
    mov     eax, dword ptr [id_xart]
    call    tr_put
    inc     bx
    mov     eax, dword ptr [id_xpit]
    call    tr_put
    call    tr_next
2:  inc     word ptr [id_i]
    cmp     word ptr [id_i], 16
    jb      1b
    mov     si, offset tg_r1
    mov     cx, 4
    call    tr_print
    /* (b) one 8-sector read: per-sector rows (k = 0 includes the command) */
    call    tr_reset
    mov     word ptr [id_count], 8
    call    ide_read
    mov     si, offset k_X
    call    row_start
    PS      "R8 total"
    call    ide_xfields
    xor     cx, cx
3:  cmp     cx, word ptr [id_got]
    jae     5f
    mov     si, offset k_X
    call    row_start
    PS      "R8 k="
    movzx   eax, cx
    call    out_d
    mov     bx, cx
    shl     bx, 4
    mov     eax, dword ptr [id_sect + bx]
    mov     si, offset kk_drqart
    call    out_kd
    mov     eax, dword ptr [id_sect + bx + 4]
    mov     si, offset kk_drqpit
    call    out_kd
    mov     eax, dword ptr [id_sect + bx + 8]
    mov     si, offset kk_xart
    call    out_kd
    mov     eax, dword ptr [id_sect + bx + 12]
    mov     si, offset kk_xpit
    call    out_kd
    call    out_nl
    test    cx, cx
    jz      4f
    push    bx
    mov     eax, dword ptr [id_sect + bx]
    push    eax
    mov     eax, dword ptr [id_sect + bx + 4]
    push    eax
    mov     eax, dword ptr [id_sect + bx + 8]
    push    eax
    mov     eax, dword ptr [id_sect + bx + 12]
    mov     bx, 3
    call    tr_put
    pop     eax
    mov     bx, 2
    call    tr_put
    pop     eax
    mov     bx, 1
    call    tr_put
    pop     eax
    xor     bx, bx
    call    tr_put
    call    tr_next
    pop     bx
4:  inc     cx
    jmp     3b
5:  mov     si, offset tg_r8
    mov     cx, 4
    call    tr_print
ide_exit:
    call    sec_disarm
    call    ide_restore
    call    sec_end
    ret

/* ide_identify: IDENTIFY DEVICE (0xEC, read-only) on the selected device; [id_ata] = 1 when
 * it returns a block whose word 0 bit 15 is clear (an ATA device), 0 on an abort (a PACKET
 * device), a timeout or bit 15 set. IRQ9 masked around it, the interrupt cleared by a status
 * read. */
ide_identify:
    cli
    call    irq9_mask
    mov     bx, 0x0080
    mov     eax, T_500MS
    call    ata_wait
    jc      1f
    mov     dx, 0x064E
    mov     al, 0xEC
    out     dx, al
    mov     eax, T_1S
    call    ata_wait_drq
    jc      1f
    test    al, 0x01                    /* ERR: aborted */
    jnz     2f
    mov     dx, 0x0640
    mov     cx, 256
    xor     di, di
3:  in      ax, dx
    mov     word ptr [SECBUF + di], ax
    add     di, 2
    loop    3b
    test    byte ptr [SECBUF + 1], 0x80 /* word 0 bit 15: 0 = ATA */
    jnz     2f
    mov     byte ptr [id_ata], 1
    jmp     2f
1:  call    ata_drain
2:  mov     dx, 0x064E
    in      al, dx
    call    irq9_restore
    sti
    ret

/* ide_restore: IMR and bank back (both read-back registers). */
ide_restore:
    cli
    call    irq9_restore
    sti
    cmp     byte ptr [st_bankw], 0
    je      1f
    mov     byte ptr [st_bankw], 0
    mov     al, byte ptr [st_bank]
    call    bank_set
    mov     byte ptr [fl_hold], 0       /* the as-found bank again: DOS may write */
    mov     dx, 0x0432
    mov     si, offset n_bank
    call    rs_port8
1:  mov     dx, 0x0A
    mov     al, byte ptr [st_imr]
    mov     si, offset n_imrs
    jmp     rs_port8

/* ide_xfields: " st=.. fst=.. got=.. ck=.. drq_art= drq_pit= xfer_art= xfer_pit= [FAIL=..]" + NL */
ide_xfields:
    mov     si, offset kk_st
    mov     al, byte ptr [id_st]
    call    out_kx2
    mov     si, offset kk_fst
    mov     al, byte ptr [id_fst]
    call    out_kx2
    movzx   eax, word ptr [id_got]
    mov     si, offset kk_got
    call    out_kd
    PS      " ck="
    mov     ax, word ptr [id_ck]
    call    out_x4
    mov     eax, dword ptr [id_dart]
    mov     si, offset kk_drqart
    call    out_kd
    mov     eax, dword ptr [id_dpit]
    mov     si, offset kk_drqpit
    call    out_kd
    mov     eax, dword ptr [id_xart]
    mov     si, offset kk_xart
    call    out_kd
    mov     eax, dword ptr [id_xpit]
    mov     si, offset kk_xpit
    call    out_kd
    cmp     byte ptr [id_fail], 0
    je      1f
    PS      " FAIL="
    mov     si, word ptr [id_why]
    call    out_s
1:  jmp     out_nl

/* ide_read: READ SECTORS of [id_count] sectors from C0/H0/S1 on the selected device.
 * Sector 0's DRQ window starts before the command write; sector k's at the end of k-1's
 * transfer. [id_dart]/[id_dpit] = sector 0's DRQ wait, [id_xart]/[id_xpit] = its transfer
 * (whole command for count > 1: the sum), per-sector values in id_sect (16 bytes each). */
ide_read:
    pushad
    mov     byte ptr [id_fail], 0
    mov     word ptr [id_got], 0
    mov     word ptr [id_ck], 0
    mov     dword ptr [id_dart], 0
    mov     dword ptr [id_dpit], 0
    mov     dword ptr [id_xart], 0
    mov     dword ptr [id_xpit], 0
    mov     byte ptr [id_fst], 0xFF
    call    irq9_mask
    cli
    mov     bx, 0x0080                  /* BSY clear before the setup */
    mov     eax, T_1S
    call    ata_wait
    mov     byte ptr [id_st], al
    jnc     1f
    mov     word ptr [id_why], offset why_busy
    jmp     ir_fail
1:  mov     dx, 0x064C
    mov     al, 0xA0
    out     dx, al
    call    io_settle
    mov     dx, 0x0644
    mov     ax, word ptr [id_count]
    out     dx, al
    mov     dx, 0x0646
    mov     al, 1
    out     dx, al
    mov     dx, 0x0648
    xor     al, al
    out     dx, al
    mov     dx, 0x064A
    out     dx, al
    call    io_settle
    mov     di, offset id_t0
    call    sm_mark
    mov     dx, 0x064E
    mov     al, 0x20                    /* READ SECTORS: the only ATA command issued */
    out     dx, al
    xor     bp, bp                      /* sector index */
ir_sect:
    mov     eax, T_1S
    call    ata_wait_drq
    mov     byte ptr [id_st], al
    jnc     2f
    mov     word ptr [id_why], offset why_drq
    jmp     ir_fail
2:  mov     di, offset id_t1
    call    sm_mark
    test    al, 0x01
    jz      3f
    mov     word ptr [id_why], offset why_err
    jmp     ir_fail
3:  mov     si, offset id_t0
    call    sm_diff
    mov     bx, bp
    shl     bx, 4
    mov     dword ptr [id_sect + bx], eax
    mov     dword ptr [id_sect + bx + 4], edx
    test    bp, bp
    jnz     4f
    mov     dword ptr [id_dart], eax
    mov     dword ptr [id_dpit], edx
4:  mov     dx, 0x0640
    mov     cx, 256
    xor     si, si
5:  in      ax, dx
    add     si, ax
    loop    5b
    add     word ptr [id_ck], si
    mov     di, offset id_t0            /* the transfer end opens the next window */
    call    sm_mark
    mov     si, offset id_t1
    call    sm_diff
    mov     bx, bp
    shl     bx, 4
    mov     dword ptr [id_sect + bx + 8], eax
    mov     dword ptr [id_sect + bx + 12], edx
    add     dword ptr [id_xart], eax
    add     dword ptr [id_xpit], edx
    inc     bp
    mov     word ptr [id_got], bp
    cmp     bp, word ptr [id_count]
    jb      ir_sect
    mov     bx, 0x0088                  /* completion: BSY and DRQ clear */
    mov     eax, T_1S
    call    ata_wait
    jnc     ir_done
    mov     word ptr [id_why], offset why_end
ir_fail:
    mov     byte ptr [id_fail], 1
    call    ata_drain
ir_done:
    mov     dx, 0x064E                  /* the final status read acknowledges INTRQ */
    in      al, dx
    mov     byte ptr [id_fst], al
    sti
    call    irq9_restore
    popad
    ret

/* ======================================================================== FDC helpers */
/* fdc_out: AL -> data port once RQM=1 DIO=0 (0.5 s deadline), then the MSR settle. CF = to. */
fdc_out:
    push    eax
    push    cx
    mov     byte ptr [fo_b], al
    mov     eax, T_500MS
    call    dl_start
1:  mov     cx, 32
2:  in      al, 0x90
    and     al, 0xC0
    cmp     al, 0x80
    je      3f
    loop    2b
    call    dl_check
    jnc     1b
    stc
    jmp     4f
3:  mov     al, byte ptr [fo_b]
    out     0x92, al
    call    io_settle
    clc
4:  pop     cx
    pop     eax
    ret

/* fdc_result: read the result phase into fd_res (8 bytes kept, 0xFF-filled first); CX =
 * bytes read. EAX = deadline for the result phase to begin. CF = timeout. */
fdc_result:
    push    di
    push    ax
    mov     di, offset fd_res
    mov     cx, 8
1:  mov     byte ptr [di], 0xFF
    inc     di
    loop    1b
    pop     ax
    call    dl_start
    mov     di, offset fd_res
    xor     cx, cx
2:  call    io_settle
3:  in      al, 0x90
    test    al, 0x80
    jnz     4f
    call    dl_check
    jnc     3b
    stc
    jmp     7f
4:  test    al, 0x40
    jnz     5f
    test    al, 0x10                    /* RQM, CB, no DIO: still executing */
    jz      6f
    call    dl_check
    jnc     3b
    stc
    jmp     7f
5:  in      al, 0x92
    cmp     cx, 8
    jae     55f
    mov     byte ptr [di], al
    inc     di
55: inc     cx
    cmp     cx, 16
    jb      2b
6:  clc
7:  pop     di
    ret

/* fdc_sds: SENSE DRIVE STATUS -> AL = ST3 (0xFF on failure), CF. */
fdc_sds:
    mov     al, 0x04
    call    fdc_out
    jc      1f
    mov     al, byte ptr [fd_us]
    call    fdc_out
    jc      1f
    push    cx
    mov     eax, T_500MS
    call    fdc_result
    pop     cx
    mov     al, byte ptr [fd_res]
    ret
1:  mov     al, 0xFF
    ret

/* fdc_sis: SENSE INTERRUPT STATUS -> AL = ST0 (0x80: nothing pending), AH = PCN, CF. */
fdc_sis:
    mov     al, 0x08
    call    fdc_out
    jc      1f
    push    cx
    mov     eax, T_500MS
    call    fdc_result
    pop     cx
    mov     al, byte ptr [fd_res]
    mov     ah, byte ptr [fd_res+1]
    ret
1:  mov     ax, 0xFFFF
    ret

/* fdc_seekend: poll SENSE INTERRUPT until this unit's SE (3 s); AL = ST0, AH = PCN, CF = to.
 * Other drives' statuses (ready changes) are drained on the way. */
fdc_seekend:
    push    bx
    push    eax
    mov     eax, 3 * T_1S
    call    dl_start
    pop     eax
1:  push    dword ptr [dl_t0]
    push    dword ptr [dl_len]
    call    fdc_sis
    pop     dword ptr [dl_len]
    pop     dword ptr [dl_t0]
    jc      3f
    cmp     al, 0x80
    je      2f
    mov     bl, al
    and     bl, 0x23
    mov     bh, byte ptr [fd_us]
    or      bh, 0x20
    cmp     bl, bh
    jne     2f
    clc
    jmp     4f
2:  call    io_settle
    call    dl_check
    jnc     1b
3:  stc
4:  pop     bx
    ret

/* fdc_drain_sis: every pending interrupt status, at most 8. */
fdc_drain_sis:
    push    ax
    push    cx
    mov     cx, 8
1:  call    fdc_sis
    jc      2f
    cmp     al, 0x80
    je      2f
    cmp     al, 0xFF
    je      2f
    loop    1b
2:  pop     cx
    pop     ax
    ret

/* fdc_idle: wait for RQM=1, DIO=0, CB=0 (2 s). CF = to. */
fdc_idle:
    push    cx
    mov     eax, 2 * T_1S
    call    dl_start
1:  mov     cx, 32
2:  in      al, 0x90
    and     al, 0xD0
    cmp     al, 0x80
    je      3f
    loop    2b
    call    dl_check
    jnc     1b
    stc
    jmp     4f
3:  clc
4:  pop     cx
    ret

/* fdc_cmd: send CX bytes from SI. CF = to. */
fdc_cmd:
    push    si
    push    cx
1:  lodsb
    call    fdc_out
    jc      2f
    loop    1b
    clc
2:  pop     cx
    pop     si
    ret

/* dma_ch2: program channel 2, I/O -> memory, single, [fd_phys], CX = bytes. (dmaroute's) */
dma_ch2:
    push    eax
    push    cx
    dec     cx
    in      al, 0x11                    /* clears the TC bits a BIOS transfer left */
    mov     al, 0x06                    /* mask channel 2 */
    out     0x15, al
    out     0x5F, al
    out     0x19, al                    /* clear the byte flip-flop */
    out     0x5F, al
    mov     al, 0x46                    /* single, increment, no autoinit, write memory, ch 2 */
    out     0x17, al
    out     0x5F, al
    mov     eax, dword ptr [fd_phys]
    out     0x09, al
    out     0x5F, al
    mov     al, ah
    out     0x09, al
    out     0x5F, al
    mov     al, cl
    out     0x0B, al
    out     0x5F, al
    mov     al, ch
    out     0x0B, al
    out     0x5F, al
    mov     eax, dword ptr [fd_phys]
    shr     eax, 16
    out     0x23, al                    /* ch 2 bank, address bits 23:16 */
    out     0x5F, al
    mov     al, 0x02                    /* unmask channel 2 */
    out     0x15, al
    out     0x5F, al
    pop     cx
    pop     eax
    ret

dma_ch2_off:
    push    ax
    mov     al, 0x06
    out     0x15, al
    out     0x5F, al
    pop     ax
    ret

/* fd_motor_on / fd_motor_back: dmaroute's BIOS-exact motor handling (BANK7@0x756D and
 * @0x7365); nothing is written when 0x0480 bit 4 is clear (the motors always run). */
fd_motor_on:
    push    ax
    push    es
    xor     ax, ax
    mov     es, ax
    test    byte ptr es:[0x480], 0x10
    jz      1f
    cli
    mov     byte ptr es:[0x485], 0
    mov     al, 0x08
    out     0x94, al
    out     0x5F, al
    sti
    mov     byte ptr [fd_mwr], 1
1:  pop     es
    pop     ax
    ret
fd_motor_back:
    push    ax
    push    es
    xor     ax, ax
    mov     es, ax
    test    byte ptr es:[0x480], 0x10
    jz      1f
    mov     al, byte ptr es:[0x5CB]
    mov     byte ptr es:[0x485], al
    mov     al, 0x09
    out     0x94, al
    out     0x5F, al
    mov     al, 0x0C
    out     0x94, al
    out     0x5F, al
    mov     byte ptr [fd_mwr], 2
1:  pop     es
    pop     ax
    ret

/* fd_irq_drain: (cli, IR11 masked) the EOI-only handler on vector 0x13, the as-found IMR
 * back, ~interrupts in for a moment so a held IR11 request is taken, then the vector back. */
fd_irq_drain:
    push    ax
    push    cx
    push    es
    xor     ax, ax
    mov     es, ax
    mov     word ptr [fd_irqn], 0
    cli
    mov     word ptr es:[0x4C], offset fd_eoi
    mov     word ptr es:[0x4E], cs
    mov     al, byte ptr [st_imr]
    out     0x0A, al
    sti
    mov     eax, T_10MS
    call    dl_start
1:  call    dl_check
    jnc     1b
    cli
    mov     eax, dword ptr [fd_vsave]
    mov     dword ptr es:[0x4C], eax
    sti
    pop     es
    pop     cx
    pop     ax
    ret
fd_eoi:
    push    ax
    inc     word ptr cs:[fd_irqn]
    mov     al, 0x20
    out     0x08, al
    out     0x00, al
    pop     ax
    iret

/* fd_x: print an X row's ST bytes: " st0=.. st1=.. st2=.. c= h= r= n=" from fd_res. */
fd_xres:
    push    si
    push    bx
    xor     bx, bx
1:  mov     si, word ptr [fd_resk + bx]
    test    si, si
    jz      2f
    push    bx
    shr     bx, 1
    mov     al, byte ptr [fd_res + bx]
    pop     bx
    call    out_kx2
    add     bx, 2
    jmp     1b
2:  pop     bx
    pop     si
    ret

/* fd_readid: READ ID (MF) head 0 -> result in fd_res, CF on timeout (2 s). */
fd_readid:
    mov     byte ptr [fd_cmdb], 0x4A
    mov     al, byte ptr [fd_us]
    mov     byte ptr [fd_cmdb+1], al
    mov     si, offset fd_cmdb
    mov     cx, 2
    call    fdc_cmd
    jc      1f
    mov     eax, 2 * T_1S
    call    fdc_result
1:  ret

/* fd_readdata: READ DATA (MF) C0 H0 R1, N = [fd_n], EOT = AL. DMA already armed. CF = to. */
fd_readdata:
    mov     byte ptr [fd_cmdb+6], al
    mov     byte ptr [fd_cmdb], 0x46
    mov     al, byte ptr [fd_us]
    mov     byte ptr [fd_cmdb+1], al
    mov     byte ptr [fd_cmdb+2], 0
    mov     byte ptr [fd_cmdb+3], 0
    mov     byte ptr [fd_cmdb+4], 1
    mov     al, byte ptr [fd_n]
    mov     byte ptr [fd_cmdb+5], al
    mov     byte ptr [fd_cmdb+7], 0x1B
    mov     byte ptr [fd_cmdb+8], 0xFF
    mov     si, offset fd_cmdb
    mov     cx, 9
    call    fdc_cmd
    jc      1f
    call    fd_dmawait
    mov     eax, 2 * T_1S
    call    fdc_result
1:  ret

/* fd_dmawait: until channel 2's current count reads 0 or 0xFFFF (the transfer is done;
 * an 8237 reads 0xFFFF after TC, NP2kai's DMAC stops at 0), 2 s. The result phase is read
 * only after this: NP2kai shows RQM|DIO during a DMA data phase (a real uPD765 in DMA mode
 * holds RQM low), so reading 0x92 earlier would take data bytes as result bytes. NP2kai
 * never sets the 0x11 TC bits, so the count is the portable witness. A command that ends
 * with an error before the transfer runs out the 2 s and then reads its result. */
fd_dmawait:
    push    eax
    push    dx
    mov     eax, 2 * T_1S
    call    dl_start
1:  out     0x19, al                    /* clear the byte flip-flop */
    in      al, 0x0B
    mov     dl, al
    in      al, 0x0B
    mov     dh, al
    test    dx, dx
    jz      2f
    cmp     dx, 0xFFFF
    je      2f
    call    dl_check
    jnc     1b
2:  pop     dx
    pop     eax
    ret

/* fd_seek: SEEK to AL (head 0); EAX ticks of command -> SE in [fd_dt], AL = ST0, AH = PCN. */
fd_seek:
    mov     byte ptr [fd_cmdb+2], al
    mov     byte ptr [fd_cmdb], 0x0F
    mov     al, byte ptr [fd_us]
    mov     byte ptr [fd_cmdb+1], al
    mov     di, offset fd_t0
    call    sm_mark
    mov     si, offset fd_cmdb
    mov     cx, 3
    call    fdc_cmd
    jc      1f
    call    fdc_seekend
    pushf
    push    ax
    mov     di, offset fd_t1
    call    sm_mark
    mov     si, offset fd_t0
    call    sm_diff
    mov     dword ptr [fd_dt], eax
    pop     ax
    popf
1:  ret

/* ======================================================================== /FDC */
sec_fdc:
    mov     si, offset nm_fdc
    mov     eax, WD_60S
    mov     bx, offset fdc_exit
    call    sec_begin
    mov     byte ptr [fd_mwr], 0
    mov     byte ptr [fd_hooked], 0
    in      al, 0x0A
    mov     byte ptr [st_imr], al
    push    es
    xor     ax, ax
    mov     es, ax
    mov     eax, dword ptr es:[0x4C]
    mov     dword ptr [fd_vsave], eax
    mov     al, byte ptr es:[0x480]
    mov     byte ptr [fd_b480], al
    mov     al, byte ptr es:[0x485]
    mov     byte ptr [fd_b485], al
    pop     es
    mov     si, offset k_STATE
    call    info_start
    PS      "imr_s="
    mov     al, byte ptr [st_imr]
    call    out_x2
    PS      " bda0480="
    mov     al, byte ptr [fd_b480]
    call    out_x2
    PS      " bda0485="
    mov     al, byte ptr [fd_b485]
    call    out_x2
    in      al, 0x90
    PS      " msr="
    call    out_x2
    call    out_nl
    cmp     word ptr [buf_seg], 0
    jne     1f
    mov     si, offset rs_nobuf
    call    skip_line
    jmp     fdc_exit
1:  /* the DMA buffer: the first 64 KiB-aligned address inside the RAM buffer */
    movzx   eax, word ptr [buf_seg]
    shl     eax, 4
    add     eax, 0xFFFF
    and     eax, 0xFFFF0000
    mov     dword ptr [fd_phys], eax
    /* the candidate units */
    mov     al, byte ptr [da_arg]
    mov     ah, al
    and     ah, 0xFC
    cmp     ah, 0x90
    jne     2f
    mov     byte ptr [fd_cand], al
    mov     byte ptr [fd_cand+1], 0
    jmp     3f
2:  mov     byte ptr [fd_cand], 0x90
    mov     byte ptr [fd_cand+1], 0x91
3:  mov     byte ptr [fd_cand+2], 0
    mov     al, byte ptr [st_imr]
    or      al, 0x08                    /* IR11 masked for the whole section */
    out     0x0A, al
    mov     byte ptr [fd_hooked], 1
    mov     word ptr [fd_ci], 0
fd_try:
    mov     bx, word ptr [fd_ci]
    mov     al, byte ptr [fd_cand + bx]
    test    al, al
    jz      fd_nodisk
    mov     byte ptr [fd_da], al
    /* "DRIVE" + the DA as two hex digits */
    push    ax
    shr     al, 4
    call    fd_hexc
    mov     byte ptr [fd_mtag+5], al
    pop     ax
    push    ax
    call    fd_hexc
    mov     byte ptr [fd_mtag+6], al
    pop     ax
    mov     si, offset fd_mtag
    push    ax
    mov     ax, 0x0092
    call    row_mark                    /* SDS, motor, RECALIBRATE on this unit */
    pop     ax
    and     al, 0x03
    mov     byte ptr [fd_us], al
    mov     word ptr [fd_why], 0
    mov     byte ptr [fd_st3a], 0xFF
    mov     byte ptr [fd_st3b], 0xFF
    mov     word ptr [fd_rst0], 0xFFFF
    mov     byte ptr [fd_n], 0xFF
    call    fdc_idle
    jnc     4f
    mov     word ptr [fd_why], offset why_idle
    jmp     7f
4:  call    fdc_drain_sis
    call    fdc_sds
    mov     byte ptr [fd_st3a], al
    call    fd_motor_on
    mov     eax, T_500MS                /* the spin-up, by the ARTIC */
    call    dl_start
5:  call    dl_check
    jnc     5b
    call    fdc_sds
    mov     byte ptr [fd_st3b], al
    test    al, 0x20                    /* ST3 RDY */
    jnz     6f
    mov     word ptr [fd_why], offset why_nrdy
6:  /* RECALIBRATE (its ST0 is the diagnostic even when not ready) */
    mov     byte ptr [fd_cmdb], 0x07
    mov     al, byte ptr [fd_us]
    mov     byte ptr [fd_cmdb+1], al
    mov     si, offset fd_cmdb
    mov     cx, 2
    call    fdc_cmd
    jc      61f
    call    fdc_seekend
    jnc     62f
61: mov     ax, 0xFFFF
    cmp     word ptr [fd_why], 0
    jne     62f
    mov     word ptr [fd_why], offset why_recal
62: mov     word ptr [fd_rst0], ax
    test    al, 0xD8
    jz      63f
    cmp     word ptr [fd_why], 0
    jne     63f
    mov     word ptr [fd_why], offset why_recal
63: mov     byte ptr [fd_n], 0xFF
    cmp     word ptr [fd_why], 0
    jne     7f
    call    fd_readid
    jnc     64f
    mov     word ptr [fd_why], offset why_rid
    jmp     7f
64: test    byte ptr [fd_res], 0xC0
    jz      65f
    mov     word ptr [fd_why], offset why_rid
    jmp     7f
65: mov     al, byte ptr [fd_res+6]
    mov     byte ptr [fd_n], al
7:  /* X FDC DRIVE da=.. st3=.. motor=.. st3=.. recal_st0=.. pcn=.. n=.. OK|FAIL=.. */
    mov     si, offset k_X
    call    row_start
    PS      "DRIVE da="
    mov     al, byte ptr [fd_da]
    call    out_x2
    mov     si, offset kk_st3a
    mov     al, byte ptr [fd_st3a]
    call    out_kx2
    PS      " motor="
    mov     al, byte ptr [fd_mwr]
    call    out_x2
    mov     si, offset kk_st3b
    mov     al, byte ptr [fd_st3b]
    call    out_kx2
    mov     si, offset kk_rst0
    mov     al, byte ptr [fd_rst0]
    call    out_kx2
    mov     si, offset kk_pcn
    mov     al, byte ptr [fd_rst0+1]
    call    out_kx2
    mov     si, offset kk_n
    mov     al, byte ptr [fd_n]
    call    out_kx2
    cmp     word ptr [fd_why], 0
    jne     8f
    PS      " OK"
    call    out_nl
    jmp     fd_go
8:  PS      " FAIL="
    mov     si, word ptr [fd_why]
    call    out_s
    call    out_nl
fd_tryfail:
    call    fdc_drain_sis
    inc     word ptr [fd_ci]
    jmp     fd_try
fd_nodisk:
    mov     si, offset rs_nodisk
    call    skip_line
    jmp     fdc_exit

fd_go:
    mov     si, offset k_I
    call    info_start
    PS      "using da="
    mov     al, byte ptr [fd_da]
    call    out_x2
    PS      " n="
    mov     al, byte ptr [fd_n]
    call    out_x2
    PS      " dma_phys="
    mov     eax, dword ptr [fd_phys]
    call    out_x8
    call    out_nl
    /* ---- SEEK 0 -> 40 -> 0, three times ---- */
    mov     si, offset tg_fdseek
    mov     ax, 0x0092
    call    row_mark
    call    tr_reset
    mov     word ptr [tr_names], offset fd_names_seek
    mov     word ptr [fd_i], 0
fs_loop:
    cli
    mov     al, 40
    call    fd_seek
    sti
    jc      fs_to
    mov     eax, dword ptr [fd_dt]
    mov     dword ptr [fd_dt2], eax
    cli
    mov     al, 0
    call    fd_seek
    sti
    jc      fs_to
    mov     byte ptr [fd_sst0], al
    mov     si, offset k_X
    call    row_start
    PS      "SEEK i="
    movzx   eax, word ptr [fd_i]
    call    out_d
    mov     eax, dword ptr [fd_dt2]
    mov     si, offset kk_outart
    call    out_kd
    mov     eax, dword ptr [fd_dt]
    mov     si, offset kk_inart
    call    out_kd
    mov     si, offset kk_st0
    mov     al, byte ptr [fd_sst0]
    call    out_kx2
    call    out_nl
    xor     bx, bx
    mov     eax, dword ptr [fd_dt2]
    call    tr_put
    inc     bx
    mov     eax, dword ptr [fd_dt]
    call    tr_put
    call    tr_next
    inc     word ptr [fd_i]
    cmp     word ptr [fd_i], 3
    jb      fs_loop
    jmp     fs_done
fs_to:
    mov     si, offset to_seek
    call    timeout_line
    call    fdc_drain_sis
fs_done:
    mov     si, offset tg_seek
    mov     cx, 2
    call    tr_print
    /* ---- READ ID x20 back to back: completion spacing ---- */
    mov     si, offset tg_fdrid
    mov     ax, 0x0092
    call    row_mark
    call    tr_reset
    mov     word ptr [tr_names], offset fd_names_rid
    mov     word ptr [fd_i], 0
    cli
    call    fd_readid                   /* the reference completion */
    pushf
    mov     di, offset fd_t0
    call    sm_mark
    popf
    sti
    jc      fr_to
fr_loop:
    cli
    call    fd_readid
    pushf
    mov     di, offset fd_t1
    call    sm_mark
    popf
    sti
    jc      fr_to
    mov     si, offset fd_t0
    call    sm_diff
    mov     dword ptr [fd_dt], eax
    mov     si, offset fd_t1            /* this completion opens the next */
    mov     di, offset fd_t0
    mov     cx, 6
    push    es
    push    ds
    pop     es
    rep     movsb
    pop     es
    mov     si, offset k_X
    call    row_start
    PS      "READID i="
    movzx   eax, word ptr [fd_i]
    call    out_d
    mov     eax, dword ptr [fd_dt]
    mov     si, offset kk_art
    call    out_kd
    call    fd_xres
    call    out_nl
    test    byte ptr [fd_res], 0xC0
    jnz     fr_done
    xor     bx, bx
    mov     eax, dword ptr [fd_dt]
    call    tr_put
    call    tr_next
    inc     word ptr [fd_i]
    cmp     word ptr [fd_i], 20
    jb      fr_loop
    jmp     fr_done
fr_to:
    mov     si, offset to_rid
    call    timeout_line
fr_done:
    mov     si, offset tg_rid
    mov     cx, 1
    call    tr_print
    /* ---- READ DATA C0/H0/R1 x20 by DMA: completion to completion ---- */
    mov     si, offset tg_fdrd
    mov     ax, 0x0092
    call    row_mark
    call    tr_reset
    mov     word ptr [tr_names], offset fd_names_rd
    mov     cl, byte ptr [fd_n]
    and     cl, 7
    mov     ax, 128
    shl     ax, cl
    mov     word ptr [fd_secb], ax
    mov     word ptr [fd_i], 0
    mov     byte ptr [fd_dmaon], 1
    cli
    mov     cx, word ptr [fd_secb]
    call    dma_ch2
    mov     al, 1
    call    fd_readdata
    pushf
    call    dma_ch2_off
    mov     di, offset fd_t0
    call    sm_mark
    popf
    sti
    jc      fd_rdto
fd_rdloop:
    cli
    mov     cx, word ptr [fd_secb]
    call    dma_ch2
    mov     al, 1
    call    fd_readdata
    pushf
    call    dma_ch2_off
    mov     di, offset fd_t1
    call    sm_mark
    popf
    sti
    jc      fd_rdto
    mov     si, offset fd_t0
    call    sm_diff
    mov     dword ptr [fd_dt], eax
    mov     si, offset fd_t1
    mov     di, offset fd_t0
    mov     cx, 6
    push    es
    push    ds
    pop     es
    rep     movsb
    pop     es
    mov     si, offset k_X
    call    row_start
    PS      "READ1 i="
    movzx   eax, word ptr [fd_i]
    call    out_d
    mov     eax, dword ptr [fd_dt]
    mov     si, offset kk_art
    call    out_kd
    call    fd_xres
    call    out_nl
    test    byte ptr [fd_res], 0xC0
    jnz     fd_rddone
    xor     bx, bx
    mov     eax, dword ptr [fd_dt]
    call    tr_put
    call    tr_next
    inc     word ptr [fd_i]
    cmp     word ptr [fd_i], 20
    jb      fd_rdloop
    jmp     fd_rddone
fd_rdto:
    mov     si, offset to_rd
    call    timeout_line
    call    fdc_drain_sis
fd_rddone:
    mov     si, offset tg_rd1
    mov     cx, 1
    call    tr_print
    /* ---- one READ DATA R1..R8: command -> result, the per-byte rate ---- */
    mov     si, offset tg_fdrd8
    mov     ax, 0x0092
    call    row_mark
    cli
    mov     ax, word ptr [fd_secb]
    shl     ax, 3                       /* 8 sectors (8 KiB at N=3) */
    mov     cx, ax
    call    dma_ch2
    mov     di, offset fd_t0
    call    sm_mark
    mov     al, 8
    call    fd_readdata
    pushf
    call    dma_ch2_off
    mov     di, offset fd_t1
    call    sm_mark
    popf
    sti
    jnc     9f
    mov     si, offset to_rd8
    call    timeout_line
    call    fdc_drain_sis
9:  mov     si, offset fd_t0
    call    sm_diff
    push    eax
    mov     si, offset k_X
    call    row_start
    PS      "READ8 sectors=8 bytes="
    movzx   eax, word ptr [fd_secb]
    shl     eax, 3
    call    out_d
    pop     eax
    mov     si, offset kk_art
    call    out_kd
    call    fd_xres
    call    out_nl
fdc_exit:
    call    sec_disarm
    cmp     byte ptr [fd_dmaon], 0
    je      1f
    mov     byte ptr [fd_dmaon], 0
    call    dma_ch2_off
    mov     si, offset n_dma2
    mov     eax, 0x06
    call    rs_default
1:  cmp     byte ptr [fd_hooked], 0
    je      2f
    mov     byte ptr [fd_hooked], 0
    call    fdc_drain_sis
    call    fd_irq_drain                /* IMR back, the held IR11 taken, vector back */
    cli
    call    fd_motor_back
    sti
    mov     si, offset k_I
    call    info_start
    PS      "irq11_taken="
    movzx   eax, word ptr [fd_irqn]
    call    out_d
    call    out_nl
2:  /* the motor: 0x94 is write-only (reads 0x44), handed back as the BIOS does */
    push    es
    xor     ax, ax
    mov     es, ax
    movzx   eax, byte ptr es:[0x485]
    pop     es
    mov     si, offset n_motor
    cmp     byte ptr [fd_mwr], 0
    jne     3f
    mov     si, offset n_motor0         /* 0x0480 bit 4 clear: 0x94 never written */
3:  call    rs_default
    push    es
    xor     ax, ax
    mov     es, ax
    mov     edx, dword ptr es:[0x4C]
    pop     es
    mov     eax, dword ptr [fd_vsave]
    mov     si, offset n_vec13
    mov     cx, 0x0008
    mov     bl, 3
    call    rs_line
    mov     dx, 0x0A
    mov     al, byte ptr [st_imr]
    mov     si, offset n_imrs
    call    rs_port8
    call    sec_end
    ret

/* ======================================================================== ATAPI helpers */
/* atapi_cmd: SI = 12-byte CDB, [cd_bc] = byte-count limit. Data (if any) goes to SECBUF
 * (2 KiB kept). Times: [cd_tdrq] = command -> first data DRQ (0 when none), [cd_tend] =
 * command -> completion (ARTIC ticks). [cd_st] = final status, [cd_err] = error register.
 * [cd_dl] = completion deadline. CF = timeout (the device is drained). */
atapi_cmd:
    pushad
    mov     dword ptr [cd_tdrq], 0
    mov     dword ptr [cd_tend], 0
    mov     word ptr [cd_nbytes], 0
    mov     byte ptr [cd_err], 0
    mov     word ptr [cd_cdb], si
    call    irq9_mask
    mov     bx, 0x0088
    mov     eax, T_1S
    call    ata_wait
    jc      ac_fail
    mov     al, byte ptr [cd_dev]
    mov     dx, 0x064C
    out     dx, al
    call    io_settle
    mov     dx, 0x0642
    xor     al, al
    out     dx, al                      /* features: PIO */
    mov     ax, word ptr [cd_bc]
    mov     dx, 0x0648
    out     dx, al
    mov     al, ah
    mov     dx, 0x064A
    out     dx, al
    call    io_settle
    mov     di, offset cd_t0
    call    sm_mark
    mov     dx, 0x064E
    mov     al, 0xA0                    /* PACKET */
    out     dx, al
    mov     word ptr [cd_phases], 0
    mov     eax, T_1S                   /* BSY clear, DRQ: the CDB phase */
    call    ata_wait_drq
    jc      ac_fail
    test    al, 0x01
    jnz     ac_done
    mov     si, word ptr [cd_cdb]
    mov     dx, 0x0640
    mov     cx, 6
1:  lodsw
    out     dx, ax
    loop    1b
    xor     di, di                      /* SECBUF fill */
ac_phase:
    mov     eax, dword ptr [cd_dl]
    mov     bx, 0x0080
    call    ata_wait                    /* BSY clear */
    jc      ac_fail
    test    al, 0x08
    jz      ac_done
    cmp     dword ptr [cd_tdrq], 0
    jne     2f
    push    di
    mov     di, offset cd_t1
    call    sm_mark
    mov     si, offset cd_t0
    call    sm_diff
    pop     di
    or      eax, 1                      /* never 0 once a DRQ came */
    mov     dword ptr [cd_tdrq], eax
2:  mov     dx, 0x064A
    in      al, dx
    mov     ah, al
    mov     dx, 0x0648
    in      al, dx
    inc     word ptr [cd_phases]
    cmp     word ptr [cd_phases], 64
    ja      ac_fail
    mov     cx, ax
    inc     cx
    shr     cx, 1
    jz      ac_fail
    add     word ptr [cd_nbytes], ax
    mov     dx, 0x0640
3:  in      ax, dx
    cmp     di, 2048
    jae     4f
    mov     word ptr [SECBUF + di], ax
    add     di, 2
4:  loop    3b
    jmp     ac_phase
ac_fail:
    mov     byte ptr [cd_to], 1
    call    ata_drain
ac_done:
    mov     di, offset cd_t1
    call    sm_mark
    mov     si, offset cd_t0
    call    sm_diff
    mov     dword ptr [cd_tend], eax
    mov     dx, 0x0642
    in      al, dx
    mov     byte ptr [cd_err], al
    mov     dx, 0x064E
    in      al, dx
    mov     byte ptr [cd_st], al
    call    irq9_restore
    popad
    cmp     byte ptr [cd_to], 0
    je      5f
    mov     byte ptr [cd_to], 0
    stc
    ret
5:  clc
    ret

/* cd_row: SI = name -> "X CD <name> art_drq=.. art_end=.. st=.. err=.. bytes=.." [sense] NL.
 * On ERR, REQUEST SENSE is issued and key/asc/ascq printed. */
cd_row:
    push    si
    mov     si, offset k_X
    call    row_start
    pop     si
    call    out_s
    mov     eax, dword ptr [cd_tdrq]
    mov     si, offset kk_drqart
    call    out_kd
    mov     eax, dword ptr [cd_tend]
    mov     si, offset kk_endart
    call    out_kd
    mov     si, offset kk_st
    mov     al, byte ptr [cd_st]
    call    out_kx2
    mov     si, offset kk_err
    mov     al, byte ptr [cd_err]
    call    out_kx2
    movzx   eax, word ptr [cd_nbytes]
    mov     si, offset kk_bytes
    call    out_kd
    test    byte ptr [cd_st], 0x01
    jz      1f
    call    cd_sense
1:  jmp     out_nl

cd_sense:
    push    dword ptr [cd_tend]
    push    dword ptr [cd_tdrq]
    push    dword ptr [cd_dl]
    push    word ptr [cd_bc]
    push    word ptr [cd_nbytes]
    push    word ptr [cd_st]            /* cd_st and cd_err */
    mov     dword ptr [SECBUF], 0
    mov     dword ptr [SECBUF+12], 0
    mov     word ptr [cd_bc], 18
    mov     dword ptr [cd_dl], T_1S
    mov     si, offset cdb_sense
    call    atapi_cmd
    PS      " sense="
    mov     al, byte ptr [SECBUF+2]
    and     al, 0x0F
    call    out_x2
    PS      "/"
    mov     al, byte ptr [SECBUF+12]
    call    out_x2
    PS      "/"
    mov     al, byte ptr [SECBUF+13]
    call    out_x2
    pop     word ptr [cd_st]
    pop     word ptr [cd_nbytes]
    pop     word ptr [cd_bc]
    pop     dword ptr [cd_dl]
    pop     dword ptr [cd_tdrq]
    pop     dword ptr [cd_tend]
    ret

/* ======================================================================== /CD */
sec_cd:
    mov     si, offset nm_cd
    mov     eax, WD_60S
    mov     bx, offset cd_exit
    call    sec_begin
    mov     byte ptr [st_bankw], 0
    mov     byte ptr [cd_to], 0
    in      al, 0x0A
    mov     byte ptr [st_imr], al
    mov     dx, 0x0432
    in      al, dx
    mov     byte ptr [st_bank], al
    mov     si, offset k_STATE
    call    info_start
    PS      "bank432="
    call    out_x2
    PS      " imr_s="
    mov     al, byte ptr [st_imr]
    call    out_x2
    call    out_nl
    mov     byte ptr [st_bankw], 1
    mov     word ptr [cd_ci], 0
cd_scan:
    mov     bx, word ptr [cd_ci]
    shl     bx, 1
    mov     ax, word ptr [cd_cands + bx]
    test    ax, ax
    jz      cd_none
    mov     si, word ptr [cd_mtags + bx]
    push    ax
    mov     ax, 0x0432
    call    st_mark
    pop     ax
    mov     byte ptr [cd_dev], al
    mov     al, ah
    mov     byte ptr [cd_bank], al
    call    bank_set
    mov     al, byte ptr [cd_dev]
    call    ata_select
    mov     byte ptr [cd_st], al
    mov     byte ptr [cd_ok], 0
    cmp     al, 0xFF
    je      2f
    /* IDENTIFY PACKET DEVICE: an ATA disk aborts it, an absent unit times out */
    cli
    call    irq9_mask
    mov     bx, 0x0080
    mov     eax, T_500MS
    call    ata_wait
    jc      1f
    mov     dx, 0x064E
    mov     al, 0xA1
    out     dx, al
    mov     eax, T_1S
    call    ata_wait_drq
    jc      1f
    mov     byte ptr [cd_st], al
    test    al, 0x01
    jnz     15f
    mov     dx, 0x0640
    mov     cx, 256
    xor     di, di
11: in      ax, dx
    mov     word ptr [SECBUF + di], ax
    add     di, 2
    loop    11b
    mov     ax, word ptr [SECBUF]
    and     ax, 0xC000
    cmp     ax, 0x8000                  /* word 0 bits 15:14 = 10: ATAPI */
    jne     15f
    mov     byte ptr [cd_ok], 1
    jmp     15f
1:  call    ata_drain
15: mov     dx, 0x064E
    in      al, dx
    call    irq9_restore
    sti
2:  mov     si, offset k_X
    call    row_start
    PS      "PROBE bank="
    mov     al, byte ptr [cd_bank]
    call    out_x2
    mov     si, offset kk_dev
    mov     al, byte ptr [cd_dev]
    call    out_kx2
    mov     si, offset kk_st
    mov     al, byte ptr [cd_st]
    call    out_kx2
    PS      " atapi="
    movzx   eax, byte ptr [cd_ok]
    call    out_d
    cmp     byte ptr [cd_ok], 0
    je      3f
    PS      " model="
    mov     si, SECBUF + 54             /* words 27-46: the model, byte-swapped */
    mov     cx, 20
21: mov     ax, word ptr [si]
    xchg    al, ah
    call    cd_pch
    mov     al, ah
    call    cd_pch
    add     si, 2
    loop    21b
    call    out_nl
    jmp     cd_go
3:  call    out_nl
    inc     word ptr [cd_ci]
    jmp     cd_scan
cd_none:
    mov     si, offset rs_nocd
    call    skip_line
    jmp     cd_exit

cd_go:
    mov     si, offset tg_cdpkt
    mov     ax, 0x0640
    call    st_mark                     /* the packet commands */
    mov     al, byte ptr [cd_bank]
    call    bank_set
    mov     al, byte ptr [cd_dev]
    call    ata_select
    /* TEST UNIT READY x4 (the first may report the disc change) */
    mov     word ptr [cd_bc], 0
    mov     dword ptr [cd_dl], 2 * T_1S
    mov     cx, 4
1:  push    cx
    mov     si, offset cdb_tur
    call    atapi_cmd
    jnc     2f
    mov     si, offset to_cd
    call    timeout_line
2:  mov     si, offset cn_tur
    call    cd_row
    pop     cx
    loop    1b
    /* READ(10) LBA 16, cold then warm x4 */
    call    tr_reset
    mov     word ptr [tr_names], offset cd_names_rd
    mov     word ptr [cd_bc], 2048
    mov     dword ptr [cd_dl], 10 * T_1S
    mov     word ptr [cd_i], 0
3:  mov     si, offset cdb_read
    call    atapi_cmd
    jnc     4f
    mov     si, offset to_cd
    call    timeout_line
4:  mov     si, offset cn_readc
    cmp     word ptr [cd_i], 0
    je      5f
    mov     si, offset cn_readw
5:  call    cd_row
    cmp     word ptr [cd_i], 0
    je      6f
    test    byte ptr [cd_st], 0x01
    jnz     6f
    xor     bx, bx
    mov     eax, dword ptr [cd_tdrq]
    call    tr_put
    inc     bx
    mov     eax, dword ptr [cd_tend]
    call    tr_put
    call    tr_next
6:  inc     word ptr [cd_i]
    cmp     word ptr [cd_i], 5
    jb      3b
    mov     si, offset tg_cdread
    mov     cx, 2
    call    tr_print
    /* READ TOC (MSF): PLAY starts at the first audio track (control bit 2 clear), else
     * at 00:02:00; it plays 3 s (the end MSF = start + 3 s). */
    mov     word ptr [cd_bc], 804
    mov     dword ptr [cd_dl], 2 * T_1S
    mov     si, offset cdb_toc
    call    atapi_cmd
    mov     si, offset cn_toc
    call    cd_row
    mov     word ptr [cdb_play+3], 0x0002   /* M=0 S=2 */
    mov     byte ptr [cdb_play+5], 0
    mov     byte ptr [cd_trk], 0
    test    byte ptr [cd_st], 0x01
    jnz     12f
    mov     si, SECBUF + 4
    mov     cx, 99
10: cmp     si, SECBUF + 2040
    jae     12f
    mov     al, byte ptr [si+2]
    cmp     al, 0xAA                    /* the lead-out: no audio track */
    je      12f
    test    byte ptr [si+1], 0x04
    jnz     11f
    mov     byte ptr [cd_trk], al
    mov     al, byte ptr [si+5]
    mov     byte ptr [cdb_play+3], al
    mov     al, byte ptr [si+6]
    mov     byte ptr [cdb_play+4], al
    mov     al, byte ptr [si+7]
    mov     byte ptr [cdb_play+5], al
    jmp     12f
11: add     si, 8
    loop    10b
12: /* end = start + 3 s (seconds carry into minutes) */
    mov     al, byte ptr [cdb_play+3]
    mov     byte ptr [cdb_play+6], al
    mov     al, byte ptr [cdb_play+4]
    add     al, 3
    cmp     al, 60
    jb      13f
    sub     al, 60
    inc     byte ptr [cdb_play+6]
13: mov     byte ptr [cdb_play+7], al
    mov     al, byte ptr [cdb_play+5]
    mov     byte ptr [cdb_play+8], al
    mov     si, offset k_I
    call    info_start
    PS      "play_track="
    movzx   eax, byte ptr [cd_trk]
    call    out_d
    PS      " msf="
    movzx   eax, byte ptr [cdb_play+3]
    call    out_d
    mov     al, ':'
    call    out_c
    movzx   eax, byte ptr [cdb_play+4]
    call    out_d
    mov     al, ':'
    call    out_c
    movzx   eax, byte ptr [cdb_play+5]
    call    out_d
    call    out_nl
    /* PLAY AUDIO MSF, then READ SUB-CHANNEL until 0x11 (5 s) */
    mov     word ptr [cd_bc], 0
    mov     dword ptr [cd_dl], 5 * T_1S
    mov     si, offset cdb_play
    call    atapi_cmd
    mov     di, offset cd_tp
    mov     si, offset cd_t0
    mov     cx, 6
    push    es
    push    ds
    pop     es
    rep     movsb
    pop     es
    mov     si, offset cn_play
    call    cd_row
    test    byte ptr [cd_st], 0x01
    jnz     cd_stop
    mov     byte ptr [cd_aud], 0xFF
    mov     word ptr [cd_polls], 0
    mov     eax, 5 * T_1S
    call    dl_start
    push    dword ptr [dl_t0]
    pop     dword ptr [cd_pdl]
7:  mov     word ptr [cd_bc], 16
    mov     dword ptr [cd_dl], T_1S
    mov     si, offset cdb_subq
    push    dword ptr [cd_pdl]
    call    atapi_cmd
    pop     dword ptr [cd_pdl]
    inc     word ptr [cd_polls]
    mov     al, byte ptr [SECBUF+1]
    mov     byte ptr [cd_aud], al
    test    byte ptr [cd_st], 0x01
    jnz     8f
    cmp     al, 0x11
    je      8f
    mov     eax, T_10MS                 /* poll every ~10 ms */
    call    dl_start
71: call    dl_check
    jnc     71b
    mov     eax, dword ptr [cd_pdl]
    call    artic_since
    cmp     eax, 5 * T_1S
    jb      7b
    mov     eax, dword ptr [cd_pdl]
    mov     dword ptr [dl_t0], eax
    mov     dword ptr [dl_len], 5 * T_1S
    mov     si, offset to_play
    call    timeout_line
8:  mov     di, offset cd_t1
    call    sm_mark
    mov     si, offset cd_tp
    call    sm_diff
    push    eax
    mov     si, offset k_X
    call    row_start
    PS      "PLAYING"
    pop     eax
    mov     si, offset kk_art
    call    out_kd
    mov     si, offset kk_aud
    mov     al, byte ptr [cd_aud]
    call    out_kx2
    movzx   eax, word ptr [cd_polls]
    mov     si, offset kk_polls
    call    out_kd
    call    out_nl
cd_stop:
    mov     word ptr [cd_bc], 0
    mov     dword ptr [cd_dl], 2 * T_1S
    mov     si, offset cdb_stop
    call    atapi_cmd
    mov     si, offset cn_stop
    call    cd_row
    test    byte ptr [cd_st], 0x01
    jz      cd_exit
    mov     si, offset cdb_pause
    call    atapi_cmd
    mov     si, offset cn_pause
    call    cd_row
cd_exit:
    call    sec_disarm
    call    ide_restore
    call    sec_end
    ret

cd_pch:                                 /* AL printable or '_' */
    cmp     al, 0x21
    jb      1f
    cmp     al, 0x7E
    jbe     2f
1:  mov     al, '_'
2:  jmp     out_c

/* ======================================================================== data */
    .p2align 1
cdb_tur:    .byte 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
cdb_sense:  .byte 0x03, 0, 0, 0, 18, 0, 0, 0, 0, 0, 0, 0
cdb_read:   .byte 0x28, 0, 0, 0, 0, 16, 0, 0, 1, 0, 0, 0
cdb_toc:    .byte 0x43, 0x02, 0, 0, 0, 0, 0, 0x03, 0x24, 0, 0, 0
cdb_subq:   .byte 0x42, 0x02, 0x40, 0x01, 0, 0, 0, 0, 16, 0, 0, 0
cdb_stop:   .byte 0x4E, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
cdb_pause:  .byte 0x4B, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
cd_cands:   .word 0x01A0, 0x01B0, 0x00B0, 0     /* bank << 8 | device */
fd_hexc:                                /* AL low nibble -> ASCII hex */
    and     al, 15
    add     al, '0'
    cmp     al, '9'
    jbe     1f
    add     al, 7
1:  ret
tg_fdseek:  .asciz "SEEK"
tg_fdrid:   .asciz "READ_ID"
tg_fdrd:    .asciz "READ_DATA"
tg_fdrd8:   .asciz "READ_DATA8"
cd_mtags:   .word tg_cd1a0, tg_cd1b0, tg_cd0b0
tg_cd1a0:   .asciz "SCAN_B1_A0"
tg_cd1b0:   .asciz "SCAN_B1_B0"
tg_cd0b0:   .asciz "SCAN_B0_B0"
tg_cdpkt:   .asciz "PACKETS"
tg_scan1:   .asciz "SCAN_B1"
tg_scan0:   .asciz "SCAN_B0"
tg_iread:   .asciz "READ_SECTORS"
ide_names:  .word kn_drqart, kn_drqpit, kn_xart, kn_xpit
fd_names_seek: .word kn_out, kn_in
fd_names_rid: .word kn_spacing
fd_names_rd: .word kn_c2c
cd_names_rd: .word kn_drqart, kn_endart
fd_resk:    .word kk_st0, kk_st1, kk_st2, kk_c, kk_h, kk_r, kk_n, 0
kn_drqart:  .asciz "drq_art"
kn_drqpit:  .asciz "drq_pit"
kn_xart:    .asciz "xfer_art"
kn_xpit:    .asciz "xfer_pit"
kn_out:     .asciz "out40_art"
kn_in:      .asciz "in0_art"
kn_spacing: .asciz "c2c_art"
kn_c2c:     .asciz "c2c_art"
kn_endart:  .asciz "end_art"
kk_st:      .asciz "st"
kk_fst:     .asciz "fst"
kk_got:     .asciz "got"
kk_dev:     .asciz "dev"
kk_err:     .asciz "err"
kk_bytes:   .asciz "bytes"
kk_aud:     .asciz "audio"
kk_polls:   .asciz "polls"
kk_art:     .asciz "art"
kk_drqart:  .asciz "drq_art"
kk_drqpit:  .asciz "drq_pit"
kk_xart:    .asciz "xfer_art"
kk_xpit:    .asciz "xfer_pit"
kk_endart:  .asciz "end_art"
kk_outart:  .asciz "out40_art"
kk_inart:   .asciz "in0_art"
kk_st3a:    .asciz "st3"
kk_st3b:    .asciz "st3_spun"
kk_rst0:    .asciz "recal_st0"
kk_pcn:     .asciz "pcn"
kk_st0:     .asciz "st0"
kk_st1:     .asciz "st1"
kk_st2:     .asciz "st2"
kk_c:       .asciz "c"
kk_h:       .asciz "h"
kk_r:       .asciz "r"
kk_n:       .asciz "n"
tg_r1:      .asciz "R1"
tg_r8:      .asciz "R8NEXT"
tg_seek:    .asciz "SEEK40"
tg_rid:     .asciz "READID"
tg_rd1:     .asciz "READ1"
tg_cdread:  .asciz "READ10WARM"
cn_tur:     .asciz "TUR"
cn_readc:   .asciz "READ10COLD"
cn_readw:   .asciz "READ10WARM"
cn_toc:     .asciz "READTOC"
cn_play:    .asciz "PLAYMSF"
cn_stop:    .asciz "STOP4E"
cn_pause:   .asciz "PAUSE4B"
why_busy:   .asciz "BUSY"
why_drq:    .asciz "DRQTMO"
why_err:    .asciz "ERR"
why_end:    .asciz "ENDTMO"
why_idle:   .asciz "IDLE"
why_nrdy:   .asciz "NOTREADY"
why_recal:  .asciz "RECAL"
why_rid:    .asciz "READID"
rs_nodrive: .asciz "nodrive"
rs_nodisk:  .asciz "nodisk"
rs_nocd:    .asciz "noatapi"
to_seek:    .asciz "seek"
to_rid:     .asciz "readid"
to_rd:      .asciz "readdata"
to_rd8:     .asciz "readdata8"
to_cd:      .asciz "atapi"
to_play:    .asciz "audio_status_11"
n_bank:     .asciz "P432_BANK"
n_dma2:     .asciz "DMA2_MASK"
n_motor:    .asciz "P94_MOTOR_HANDBACK_BDA0485"
n_motor0:   .asciz "P94_UNTOUCHED_BDA0485"
n_vec13:    .asciz "VEC13"

    VARS
    .p2align 1
cdb_play:   .byte 0x47, 0, 0, 0, 2, 0, 0, 5, 0, 0, 0, 0
    .p2align 2
id_dart:    .long 0
id_dpit:    .long 0
id_xart:    .long 0
id_xpit:    .long 0
id_sect:    .space 8 * 16
fd_phys:    .long 0
fd_vsave:   .long 0
fd_dt:      .long 0
fd_dt2:     .long 0
cd_tdrq:    .long 0
cd_tend:    .long 0
cd_dl:      .long 0
cd_pdl:     .long 0
id_t0:      .space 6
id_t1:      .space 6
fd_t0:      .space 6
fd_t1:      .space 6
cd_t0:      .space 6
cd_t1:      .space 6
cd_tp:      .space 6
id_i:       .word 0
id_count:   .word 0
id_got:     .word 0
id_ck:      .word 0
id_why:     .word 0
id_sig:     .word 0
fd_i:       .word 0
fd_ci:      .word 0
fd_why:     .word 0
fd_rst0:    .word 0
fd_secb:    .word 0
fd_irqn:    .word 0
cd_i:       .word 0
cd_ci:      .word 0
cd_bc:      .word 0
cd_cdb:     .word 0
cd_nbytes:  .word 0
cd_polls:   .word 0
cd_phases:  .word 0
fd_cmdb:    .space 10
fd_res:     .space 8
fd_cand:    .space 4
st_imr:     .byte 0
st_bank:    .byte 0
st_bankw:   .byte 0
id_try:     .byte 0
id_st:      .byte 0
id_fst:     .byte 0
id_fail:    .byte 0
id_ata:     .byte 0
fd_us:      .byte 0
fd_da:      .byte 0
fd_n:       .byte 0
fd_st3a:    .byte 0
fd_st3b:    .byte 0
fd_mwr:     .byte 0
fd_hooked:  .byte 0
fd_dmaon:   .byte 0
fd_b480:    .byte 0
fd_b485:    .byte 0
fd_sst0:    .byte 0
fo_b:       .byte 0
cd_dev:     .byte 0
cd_bank:    .byte 0
cd_st:      .byte 0                     /* cd_st, cd_err adjacent: saved as one word */
cd_err:     .byte 0
cd_ok:      .byte 0
cd_to:      .byte 0
cd_aud:     .byte 0
cd_trk:     .byte 0
    ENDVARS

    VARS
fd_mtag:    .asciz "DRIVExx"
    ENDVARS
