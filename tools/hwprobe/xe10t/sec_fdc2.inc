/* sec_fdc2.inc - /FDC2 (opt-in): the floppy controller's answers the core's model infers
 * (todo items 59 and 180, and the answers the core now follows). Raw register values,
 * ARTIC-timed.
 *
 * NOTHING WRITES A DISK. The only commands are SENSE DRIVE STATUS, SENSE INTERRUPT STATUS,
 * SPECIFY (03 C1 46, Windows 95 HSFLOP.PDR's bytes, only after this section reset the
 * controller), RECALIBRATE, READ ID and READ DATA. The only BIOS call is INT 1Bh AH=04h
 * (SENSE) on DA/UA 0x90 and 0x91, made first, with the BIOS's own IRQ11 handler, to tell
 * which drive holds a diskette.
 *
 * 1 MB MODE (the default, 0x00BE bit 0 = 1; the FDC at 0x90/0x92/0x94, IRQ11, DMA ch 2):
 *   STATE      the BDA floppy bytes (0x055C: item 59), the ports of both windows read once
 *   SENSE u    INT 1Bh AH=04h on DA 0x90 / 0x91 (AH, CF): class D (CF=0) or E (CF=1)
 *   UNIT u     ST3 before the motor, the motor on as the BIOS does it (0x0480 bit 4), 500 ms,
 *              ST3 again, RECALIBRATE -> ST0/PCN (item 59: an empty powered drive)
 *   on the disk unit d (DA= names it, else the first class-D unit):
 *   GEOM       READ IDs until R repeats: N and the sectors per track (spt = EOT below)
 *   TC_R3      READ DATA C0 H0 R3, EOT=spt, a 1-sector DMA count (TC before EOT)
 *   TC_MT0     MT READ DATA R1, an spt-sector count (TC at side 0's EOT)
 *   TC_MT1     MT READ DATA R1, a 2*spt count (TC at side 1's EOT)
 *   EOT_NT     READ DATA R1, an spt+1 count (EOT reached with no TC)
 *   EOT_MT     MT READ DATA R1, a 2*spt+1 count (side 1's EOT with no TC)
 *   IRQHOLD    READ DATA R1 (TC), the result read, NO SENSE INTERRUPT STATUS: the slave IRR
 *              bit 3 after the result and 10 ms later, then IRQ11 counted for 10 ms unmasked
 *              (1 = something holds the request, 0 = it is withdrawn)
 *   VFO        0x94 <- 0x09, 0x0C alone (the BIOS's hand-back): IRR bit 3 for 400 ms, then
 *              counted unmasked, then SENSE INTERRUPT STATUS (the 100 ms VFO timer)
 *   DMA_REF / DMA_MSR / DMA_92   three spt-sector reads of C0 H0 by DMA: a reference, one
 *              with MSR sampled throughout (every distinct value, its count and first time),
 *              one that also reads 0x92 four times inside the transfer; each buffer is
 *              compared with the reference
 *   on the first class-E unit e (not d):
 *   NRID / NRRD READ ID / READ DATA (1-sector DMA armed) on the empty drive: MSR over time,
 *              how it ends (I = IRQ11, D = a result phase, T = 2 s with neither), the result
 *              bytes and the SENSE INTERRUPT STATUS answers; a T row is followed by an
 *              NRREC row: the controller reset that frees it (0x98, ten 0x5F, 0x18)
 *   NRID_U2    READ ID on unit 2, which the machine does not equip
 *   RST_M      0x94 <- 0x98, ten 0x5F writes, 0x18 (HSFLOP.PDR's reset, motor bit set): the
 *              IR11 request timed from the 0x18 write, MSR over time, SENSE INTERRUPT STATUS
 *              until 0x80, a second request within 500 ms
 *   RST_NM     the same with 0x90 / 0x10 (motor bit clear)
 * 640K MODE (/M640: SETUP floppy disk mode 640K, 0x00BE bit 0 = 0; the FDC at 0xC8/0xCA/0xCC):
 *   M640 u m   per unit, motor on (0xCC <- 08, as BANK7@0x74E7) and off (0xCC <- 00, as
 *              BANK7@0x7EF6): SENSE DRIVE STATUS, then 0xCC read straight after the ST3 byte
 *              and every change of it for 20 ms (180: bit 4, the drive's RDY)
 *   RST640     0xCC <- 0x98, ten 0x5F, 0x18 with IRQ10 masked: the IR10 request timed (the
 *              640 KB window)
 *   then 0x05D7 <- 0x96, 0xCC <- 0x09, 0x0C (the BIOS's own hand-back, BANK7@0x77B3).
 *
 * Every row is behind its own ROW line (committed before it runs). Every wait has an ARTIC
 * deadline. Times are ARTIC ticks (3.255 us) from the named write. Restored: the slave IMR,
 * IVT 13h (an EOI-counting stub while the section runs), DMA channel 2 masked, the slave PIC's
 * read register (OCW3 0Bh, ISR, as IRQWD leaves it), the motor handed back as the BIOS does.
 * The controller's SPECIFY values are the BIOS's own until a reset row runs; after one the
 * section sends HSFLOP.PDR's SPECIFY and RECALIBRATEs units 0 and 1: reboot after /FDC2.
 */
tc_fdc2:    .asciz "INT1Bh AH=04(DA90,91) 0x0A(IMR bits 2,3,restored) IVT[13](EOI stub,restored) 0x08(OCW3 0A,left 0B) 0x92(SDS/SIS/SPECIFY C1 46/RECAL/READID/READDATA, unit 2 READ ID) 0x94=08,09,0C,98,18,90,10 BDA0485 DMA-ch2(0x09,0x0B,0x15,0x17,0x19,0x23) RAM-buffer; /M640: 0xCA(SDS/SIS/SPECIFY) 0xCC=08,00,98,18,09,0C BDA05D7"

/* ======================================================================== helpers */
/* f2_irr: AL = the slave PIC's IRR (bit 3 = IR11, bit 2 = IR10). */
f2_irr:
    mov     al, 0x0A
    out     0x08, al
    in      al, 0x08
    ret

/* f2_now: EAX = ARTIC ticks since [f2_t0]. */
f2_now:
    mov     eax, dword ptr [f2_t0]
    jmp     artic_since

/* f2_dmacnt: AX = DMA channel 2's current count (0xFFFF after the terminal count). */
f2_dmacnt:
    push    dx
    out     0x19, al
    in      al, 0x0B
    mov     dl, al
    in      al, 0x0B
    mov     ah, al
    mov     al, dl
    pop     dx
    ret

/* f2_hreset / f2_hadd: the distinct-value histogram (8 values): AL = value; its count and
 * the f2_now time of its first sample. */
f2_hreset:
    mov     byte ptr [f2_hn], 0
    ret
f2_hadd:
    pushad
    mov     dl, al
    movzx   ecx, byte ptr [f2_hn]
    xor     ebx, ebx
1:  cmp     ebx, ecx
    jae     2f
    cmp     byte ptr [f2_hv + ebx], dl
    je      3f
    inc     ebx
    jmp     1b
2:  cmp     ecx, 8
    jae     4f
    mov     byte ptr [f2_hv + ebx], dl
    mov     word ptr [f2_hc + ebx*2], 0
    call    f2_now
    mov     dword ptr [f2_ht + ebx*4], eax
    inc     byte ptr [f2_hn]
3:  cmp     word ptr [f2_hc + ebx*2], 0xFFFF
    je      4f
    inc     word ptr [f2_hc + ebx*2]
4:  popad
    ret
/* f2_hprint: "vv:count:t,..." ("-" when empty) */
f2_hprint:
    pushad
    movzx   ecx, byte ptr [f2_hn]
    xor     ebx, ebx
    test    ecx, ecx
    jnz     1f
    mov     al, '-'
    call    out_c
    jmp     3f
1:  mov     al, byte ptr [f2_hv + ebx]
    call    out_x2
    mov     al, ':'
    call    out_c
    movzx   eax, word ptr [f2_hc + ebx*2]
    call    out_d
    mov     al, ':'
    call    out_c
    mov     eax, dword ptr [f2_ht + ebx*4]
    call    out_d
    inc     ebx
    cmp     ebx, ecx
    jae     3f
    mov     al, ','
    call    out_c
    jmp     1b
3:  popad
    ret

/* f2_pt: EAX = a time or 0xFFFFFFFF -> decimal or "-" */
f2_pt:
    cmp     eax, 0xFFFFFFFF
    jne     out_d
    push    ax
    mov     al, '-'
    call    out_c
    pop     ax
    ret

/* ---- port-parametric FDC access ([f2_pb] = 0x90 or 0xC8; data = +2, control = +4) ---- */
/* f2_out: AL -> data port once RQM=1 DIO=0 (0.5 s), then the BIOS's MSR settle. CF = to. */
f2_out:
    push    eax
    push    dx
    mov     byte ptr [fo_b], al
    mov     eax, T_500MS
    call    dl_start
1:  mov     dx, word ptr [f2_pb]
    in      al, dx
    and     al, 0xC0
    cmp     al, 0x80
    je      2f
    call    dl_check
    jnc     1b
    stc
    jmp     3f
2:  add     dx, 2
    mov     al, byte ptr [fo_b]
    out     dx, al
    call    io_settle
    clc
3:  pop     dx
    pop     eax
    ret

/* f2_rdres: the result phase into fd_res (0xFF-filled, 8 kept), CX = bytes; EAX = the
 * deadline for it to begin. The 0x90 twin of fdc_result. CF = to. */
f2_rdres:
    push    di
    push    dx
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
3:  mov     dx, word ptr [f2_pb]
    in      al, dx
    test    al, 0x80
    jnz     4f
    call    dl_check
    jnc     3b
    stc
    jmp     7f
4:  test    al, 0x40
    jnz     5f
    test    al, 0x10
    jz      6f
    call    dl_check
    jnc     3b
    stc
    jmp     7f
5:  add     dx, 2
    in      al, dx
    cmp     cx, 8
    jae     55f
    mov     byte ptr [di], al
    inc     di
55: inc     cx
    cmp     cx, 16
    jb      2b
6:  clc
7:  pop     dx
    pop     di
    ret

/* f2_sisp: SENSE INTERRUPT STATUS -> AL = ST0 (0x80 none, 0xFF failed), AH = PCN. */
f2_sisp:
    push    cx
    mov     al, 0x08
    call    f2_out
    jc      1f
    mov     eax, T_500MS
    call    f2_rdres
    mov     al, byte ptr [fd_res]
    mov     ah, byte ptr [fd_res+1]
    pop     cx
    ret
1:  mov     ax, 0xFFFF
    pop     cx
    ret

/* f2_drain: DI = list (count byte, then 8 ST0/PCN pairs): SENSE INTERRUPT STATUS until
 * 0x80 (kept as the last entry) or a failure, at most 8. */
f2_drain:
    push    ax
    push    bx
    mov     byte ptr [di], 0
    xor     bx, bx
1:  call    f2_sisp
    mov     word ptr [di + 1 + bx], ax
    inc     byte ptr [di]
    add     bx, 2
    cmp     al, 0x80
    je      2f
    cmp     al, 0xFF
    je      2f
    cmp     bx, 16
    jb      1b
2:  pop     bx
    pop     ax
    ret
/* f2_plist: DI = list -> "C000,C100,80" ("-" when empty) */
f2_plist:
    pusha
    movzx   cx, byte ptr [di]
    xor     bx, bx
    test    cx, cx
    jnz     1f
    mov     al, '-'
    call    out_c
    jmp     3f
1:  mov     ax, word ptr [di + 1 + bx]
    push    ax
    call    out_x2
    pop     ax
    cmp     al, 0x80
    je      2f
    cmp     al, 0xFF
    je      2f
    mov     al, ah
    call    out_x2
2:  add     bx, 2
    dec     cx
    jz      3f
    mov     al, ','
    call    out_c
    jmp     1b
3:  popa
    ret

/* f2_spec: SPECIFY with HSFLOP.PDR's bytes (C1 46: ND = 0, DMA mode). */
f2_spec:
    push    ax
    mov     al, 0x03
    call    f2_out
    mov     al, 0xC1
    call    f2_out
    mov     al, 0x46
    call    f2_out
    pop     ax
    ret

/* f2_wait: EAX ticks by the ARTIC (the watchdog runs). */
f2_wait:
    call    dl_start
1:  call    dl_check
    jnc     1b
    ret

/* f2_count: IR11 unmasked for 10 ms with the counting EOI stub on vector 0x13 -> AX.
 * The request a masked IR11 holds is taken at the unmask. */
f2_count:
    mov     word ptr [fd_irqn], 0
    cli
    mov     al, byte ptr [f2_imr]
    and     al, 0xF7
    out     0x0A, al
    sti
    mov     eax, T_10MS
    call    f2_wait
    cli
    mov     al, byte ptr [f2_imr]
    out     0x0A, al
    sti
    mov     ax, word ptr [fd_irqn]
    ret

/* f2_buf: AX = the real-mode segment of the 64 KiB DMA page ([fd_phys] >> 4). */
f2_buf:
    mov     eax, dword ptr [fd_phys]
    shr     eax, 4
    ret

/* f2_fill: BX = offset, CX = bytes, AL = byte. */
f2_fill:
    push    es
    push    di
    push    ax
    call    f2_buf
    mov     es, ax
    pop     ax
    mov     di, bx
    rep     stosb
    pop     di
    pop     es
    ret

/* f2_cmp: SI, DI = offsets, CX = bytes -> EAX = differing bytes, BX = first (0xFFFF none). */
f2_cmp:
    push    ds
    push    cx
    push    dx
    push    si
    push    di
    call    f2_buf
    mov     ds, ax
    xor     edx, edx
    mov     bx, 0xFFFF
1:  mov     al, byte ptr [si]
    cmp     al, byte ptr [di]
    je      2f
    inc     edx
    cmp     bx, 0xFFFF
    jne     2f
    mov     bx, cx
2:  inc     si
    inc     di
    loop    1b
    mov     eax, edx
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     ds
    cmp     bx, 0xFFFF
    je      3f
    neg     bx                          /* bx held the bytes left at the first diff */
    add     bx, cx
3:  ret

/* f2_x: start `X FDC2 <SI tag> da=<unit|0x90>` */
f2_x:
    push    si
    mov     si, offset k_X
    call    row_start
    pop     si
    call    out_s
    PS      " da="
    mov     al, byte ptr [fd_us]
    or      al, 0x90
    jmp     out_x2

/* f2_pres: " nres=<n> st0=.. st1=.. st2=.. c= h= r= n=" */
f2_pres:
    PS      " nres="
    movzx   eax, word ptr [f2_nres]
    call    out_d
    mov     eax, dword ptr [f2_rsv]
    mov     dword ptr [fd_res], eax
    mov     eax, dword ptr [f2_rsv+4]
    mov     dword ptr [fd_res+4], eax
    jmp     fd_xres

/* ======================================================================== the 1 MB rows */
/* f2_low0: the IR11 request counts as risen at its first high sample when it was low before the
 * command ([f2_irr0] bit 3 clear: a completion can rise before the first sample); a request
 * already high before the command must be seen low first. */
f2_low0:
    mov     byte ptr [f2_low], 0
    test    byte ptr [f2_irr0], 0x08
    jnz     1f
    mov     byte ptr [f2_low], 1
1:  ret

/* f2_dwait: after a data command's last byte ([f2_t0]): until IR11 rises after being seen
 * low (end I) or EAX ticks pass (end T). MSR into the histogram when [f2_hon]; 0x92 read at
 * four points of the transfer when [f2_r92]. [f2_tirq], [f2_ttc] (first terminal count). */
f2_dwait:
    call    dl_start
    mov     dword ptr [f2_tirq], 0xFFFFFFFF
    mov     dword ptr [f2_ttc], 0xFFFFFFFF
    call    f2_low0
    mov     byte ptr [f2_rdn], 0
dw_lp:
    cmp     byte ptr [f2_hon], 0
    je      1f
    in      al, 0x90
    call    f2_hadd
1:  call    f2_dmacnt
    cmp     ax, 0xFFFF
    je      dw_tc
    test    ax, ax
    je      dw_tc
    cmp     byte ptr [f2_r92], 0
    je      dw_nx
    movzx   ebx, byte ptr [f2_rdn]
    cmp     bl, 4
    jae     dw_nx
    mov     dx, word ptr [f2_cnt0]
    sub     dx, ax                      /* bytes moved so far */
    mov     cx, bx
    shl     cx, 11
    add     cx, 512                     /* mid-sector 0, 2, 4, 6 at N=3 */
    cmp     dx, cx
    jb      dw_nx
    mov     word ptr [f2_rdc + ebx*2], ax
    in      al, 0x92
    mov     byte ptr [f2_rdv + ebx], al
    inc     byte ptr [f2_rdn]
    jmp     dw_nx
dw_tc:
    cmp     dword ptr [f2_ttc], 0xFFFFFFFF
    jne     dw_nx
    call    f2_now
    mov     dword ptr [f2_ttc], eax
dw_nx:
    call    f2_irr
    test    al, 0x08
    jnz     dw_hi
    mov     byte ptr [f2_low], 1
    jmp     dw_dl
dw_hi:
    cmp     byte ptr [f2_low], 0
    je      dw_dl
    call    f2_now
    mov     dword ptr [f2_tirq], eax
    mov     byte ptr [f2_end], 'I'
    ret
dw_dl:
    call    dl_check
    jnc     dw_lp
    mov     byte ptr [f2_end], 'T'
    ret

/* f2_read: READ DATA (MF) of C0 H0 on [fd_us], R = AL, MT = AH, EOT = [f2_spt], N = [fd_n];
 * DMA channel 2 armed for CX sectors at buffer offset BX. Fills fd_res/[f2_nres], [f2_irr0]
 * (before), [f2_tirq], [f2_ttc], [f2_end], [f2_dcnt] (the count after). */
f2_read:
    push    ax
    call    f2_irr
    mov     byte ptr [f2_irr0], al
    mov     ax, word ptr [fd_secb]
    mul     cx
    mov     cx, ax
    dec     ax
    mov     word ptr [f2_cnt0], ax
    mov     eax, dword ptr [fd_phys]
    push    eax
    movzx   ebx, bx
    add     dword ptr [fd_phys], ebx
    mov     byte ptr [fd_dmaon], 1
    call    dma_ch2
    pop     eax
    mov     dword ptr [fd_phys], eax
    pop     ax
    mov     byte ptr [fd_cmdb+4], al
    mov     al, 0x46
    test    ah, ah
    jz      1f
    mov     al, 0xC6
1:  mov     byte ptr [fd_cmdb], al
    mov     al, byte ptr [fd_us]
    mov     byte ptr [fd_cmdb+1], al
    mov     byte ptr [fd_cmdb+2], 0
    mov     byte ptr [fd_cmdb+3], 0
    mov     al, byte ptr [fd_n]
    mov     byte ptr [fd_cmdb+5], al
    mov     al, byte ptr [f2_spt]
    mov     byte ptr [fd_cmdb+6], al
    mov     byte ptr [fd_cmdb+7], 0x1B
    mov     byte ptr [fd_cmdb+8], 0xFF
    mov     si, offset fd_cmdb
    mov     cx, 9
    call    fdc_cmd
    call    artic_read
    mov     dword ptr [f2_t0], eax
    mov     eax, 3 * T_1S
    call    f2_dwait
    mov     eax, T_500MS
    call    fdc_result
    mov     word ptr [f2_nres], cx
    call    f2_rsave
    call    dma_ch2_off
    call    f2_dmacnt
    mov     word ptr [f2_dcnt], ax
    ret

/* f2_rsave / f2_pres's reload: the result bytes kept across the SENSE INTERRUPT STATUS that
 * reuse fd_res. */
f2_rsave:
    push    eax
    mov     eax, dword ptr [fd_res]
    mov     dword ptr [f2_rsv], eax
    mov     eax, dword ptr [fd_res+4]
    mov     dword ptr [f2_rsv+4], eax
    pop     eax
    ret

/* f2_prd: the common tail of a READ DATA row */
f2_prd:
    PS      " end="
    mov     al, byte ptr [f2_end]
    call    out_c
    PS      " irr_pre="
    mov     al, byte ptr [f2_irr0]
    call    out_x2
    PS      " t_irq_art="
    mov     eax, dword ptr [f2_tirq]
    call    f2_pt
    PS      " t_tc_art="
    mov     eax, dword ptr [f2_ttc]
    call    f2_pt
    PS      " dmacnt="
    mov     ax, word ptr [f2_dcnt]
    call    out_x4
    jmp     f2_pres

/* the TC/EOT table: tag, R, MT, sectors = spt * k + d (k, d) */
f2_tct:
    .word   tg2_tcr3
    .byte   3, 0, 0, 1
    .word   tg2_tcmt0
    .byte   1, 1, 1, 0
    .word   tg2_tcmt1
    .byte   1, 1, 2, 0
    .word   tg2_eotnt
    .byte   1, 0, 1, 1
    .word   tg2_eotmt
    .byte   1, 1, 2, 1
    .word   0

/* f2_rst: the controller reset through the control port ([f2_pb]+4): AL = the asserting
 * write, AH = the releasing write, ten 0x5F writes between (HSFLOP.PDR's). From the release
 * ([f2_t0]) for 500 ms: MSR into the histogram, the IRR bit [f2_im] watched; its first rise
 * drains SENSE INTERRUPT STATUS into f2_sis, its second into f2_sis2. */
f2_rst:
    mov     word ptr [f2_wa], ax
    mov     di, offset f2_sis2
    call    f2_drain                    /* whatever was pending before (not reported) */
    call    f2_irr
    mov     byte ptr [f2_irr0], al
    call    f2_hreset
    mov     byte ptr [f2_sis], 0
    mov     byte ptr [f2_sis2], 0
    mov     byte ptr [f2_rises], 0
    mov     byte ptr [f2_prev], 0
    mov     dword ptr [f2_tirq], 0xFFFFFFFF
    mov     dword ptr [f2_t2], 0xFFFFFFFF
    mov     byte ptr [f2_didrst], 1
    mov     dx, word ptr [f2_pb]
    add     dx, 4
    cli
    mov     al, byte ptr [f2_wa]
    out     dx, al
    call    io_settle
    mov     al, byte ptr [f2_wa+1]
    out     dx, al
    call    artic_read
    mov     dword ptr [f2_t0], eax
    sti
    mov     eax, T_500MS
    call    dl_start
rs_lp:
    mov     dx, word ptr [f2_pb]
    in      al, dx
    call    f2_hadd
    call    f2_irr
    and     al, byte ptr [f2_im]
    mov     ah, byte ptr [f2_prev]
    mov     byte ptr [f2_prev], al
    test    al, al
    jz      rs_nx
    test    ah, ah
    jnz     rs_nx
    inc     byte ptr [f2_rises]
    call    f2_now
    mov     di, offset f2_sis
    cmp     byte ptr [f2_rises], 1
    jne     1f
    mov     dword ptr [f2_tirq], eax
    jmp     2f
1:  mov     di, offset f2_sis2
    cmp     byte ptr [f2_rises], 2
    jne     3f
    mov     dword ptr [f2_t2], eax
2:  push    dword ptr [dl_t0]
    push    dword ptr [dl_len]
    call    f2_drain
    pop     dword ptr [dl_len]
    pop     dword ptr [dl_t0]
3:  call    f2_irr
    and     al, byte ptr [f2_im]
    mov     byte ptr [f2_prev], al
rs_nx:
    call    dl_check
    jnc     rs_lp
    call    f2_irr
    mov     byte ptr [f2_irra], al
    call    f2_spec
    ret

/* f2_prst: print a reset row: SI = tag */
f2_prst:
    call    f2_x
    PS      " w="
    mov     al, byte ptr [f2_wa]
    call    out_x2
    mov     al, '/'
    call    out_c
    mov     al, byte ptr [f2_wa+1]
    call    out_x2
    PS      " irr_pre="
    mov     al, byte ptr [f2_irr0]
    call    out_x2
    PS      " t_irq_art="
    mov     eax, dword ptr [f2_tirq]
    call    f2_pt
    PS      " rises="
    movzx   eax, byte ptr [f2_rises]
    call    out_d
    PS      " t_irq2_art="
    mov     eax, dword ptr [f2_t2]
    call    f2_pt
    PS      " sis="
    mov     di, offset f2_sis
    call    f2_plist
    PS      " sis2="
    mov     di, offset f2_sis2
    call    f2_plist
    PS      " irr_end="
    mov     al, byte ptr [f2_irra]
    call    out_x2
    PS      " msr="
    call    f2_hprint
    jmp     out_nl

/* f2_nr: a data command on the (empty) unit [fd_us]: AL = 0 READ ID, 1 READ DATA (a
 * 1-sector DMA count armed at offset 0xC000). Ends at IR11 (I), a result phase (D) or 2 s (T);
 * SI = tag. A T row is followed by the NRREC reset that frees the controller. */
f2_nr:
    mov     byte ptr [f2_kind], al
    mov     word ptr [f2_tag], si
    mov     ax, 0x0092
    call    row_mark
    mov     di, offset f2_sis
    call    f2_drain
    call    f2_irr
    mov     byte ptr [f2_irr0], al
    call    f2_hreset
    mov     byte ptr [f2_sis], 0
    mov     word ptr [f2_nres], 0
    mov     word ptr [f2_dcnt], 0xFFFF
    mov     di, offset fd_res
    mov     cx, 8
    mov     al, 0xFF
    push    es
    push    ds
    pop     es
    rep     stosb
    pop     es
    call    f2_rsave
    mov     byte ptr [fd_cmdb], 0x4A
    mov     al, byte ptr [fd_us]
    mov     byte ptr [fd_cmdb+1], al
    mov     cx, 2
    cmp     byte ptr [f2_kind], 0
    je      1f
    mov     eax, dword ptr [fd_phys]
    push    eax
    add     dword ptr [fd_phys], 0xC000
    mov     byte ptr [fd_dmaon], 1
    mov     cx, 1024
    call    dma_ch2
    pop     eax
    mov     dword ptr [fd_phys], eax
    mov     word ptr [f2_cnt0], 1023
    mov     byte ptr [fd_cmdb], 0x46
    mov     byte ptr [fd_cmdb+2], 0
    mov     byte ptr [fd_cmdb+3], 0
    mov     byte ptr [fd_cmdb+4], 1
    mov     byte ptr [fd_cmdb+5], 3
    mov     byte ptr [fd_cmdb+6], 8
    mov     byte ptr [fd_cmdb+7], 0x1B
    mov     byte ptr [fd_cmdb+8], 0xFF
    mov     cx, 9
1:  mov     si, offset fd_cmdb
    call    fdc_cmd
    call    artic_read
    mov     dword ptr [f2_t0], eax
    in      al, 0x90
    mov     byte ptr [f2_msr0], al
    call    f2_low0
    mov     dword ptr [f2_tirq], 0xFFFFFFFF
    mov     eax, 2 * T_1S
    call    dl_start
nr_lp:
    in      al, 0x90
    call    f2_hadd
    and     al, 0xC0
    cmp     al, 0xC0
    jne     1f
    mov     byte ptr [f2_end], 'D'
    jmp     nr_end
1:  call    f2_irr
    test    al, 0x08
    jnz     2f
    mov     byte ptr [f2_low], 1
    jmp     3f
2:  cmp     byte ptr [f2_low], 0
    je      3f
    mov     byte ptr [f2_end], 'I'
    jmp     nr_end
3:  call    dl_check
    jnc     nr_lp
    mov     byte ptr [f2_end], 'T'
nr_end:
    call    f2_now
    mov     dword ptr [f2_tirq], eax
    in      al, 0x90
    mov     byte ptr [f2_msre], al
    cmp     byte ptr [f2_end], 'T'
    je      nr_out
    and     al, 0xC0
    cmp     al, 0xC0
    jne     4f
    mov     eax, T_500MS
    call    fdc_result
    mov     word ptr [f2_nres], cx
4:  call    f2_rsave
    call    f2_irr
    mov     byte ptr [f2_irra], al
    mov     di, offset f2_sis
    call    f2_drain
nr_out:
    cmp     byte ptr [f2_kind], 0
    je      5f
    call    dma_ch2_off
    call    f2_dmacnt
    mov     word ptr [f2_dcnt], ax
5:  mov     si, word ptr [f2_tag]
    call    f2_x
    PS      " end="
    mov     al, byte ptr [f2_end]
    call    out_c
    PS      " t_end_art="
    mov     eax, dword ptr [f2_tirq]
    call    out_d
    PS      " irr_pre="
    mov     al, byte ptr [f2_irr0]
    call    out_x2
    PS      " msr0="
    mov     al, byte ptr [f2_msr0]
    call    out_x2
    PS      " msr_end="
    mov     al, byte ptr [f2_msre]
    call    out_x2
    PS      " msr="
    call    f2_hprint
    PS      " sis="
    mov     di, offset f2_sis
    call    f2_plist
    PS      " dmacnt="
    mov     ax, word ptr [f2_dcnt]
    call    out_x4
    call    f2_pres
    call    out_nl
    cmp     byte ptr [f2_end], 'T'
    jne     6f
    mov     si, offset tg2_nrrec
    mov     ax, 0x0094
    call    row_mark
    mov     ax, 0x1898
    call    f2_rst
    mov     si, offset tg2_nrrec
    call    f2_prst
6:  ret

/* ======================================================================== /FDC2 */
sec_fdc2:
    mov     si, offset nm_fdc2
    mov     eax, WD_60S
    mov     bx, offset fdc2_exit
    call    sec_begin
    mov     byte ptr [fd_mwr], 0
    mov     byte ptr [fd_hooked], 0
    mov     byte ptr [fd_dmaon], 0
    mov     byte ptr [f2_didrst], 0
    mov     byte ptr [f2_m640w], 0
    mov     word ptr [f2_pb], 0x90
    mov     byte ptr [f2_im], 0x08
    in      al, 0x0A
    mov     byte ptr [st_imr], al
    mov     byte ptr [f2_imr], al
    push    es
    xor     ax, ax
    mov     es, ax
    mov     eax, dword ptr es:[0x4C]
    mov     dword ptr [fd_vsave], eax
    pop     es
    /* STATE: the BDA floppy bytes and both windows' ports, read once */
    mov     si, offset k_STATE
    call    info_start
    PS      "imr_m="
    in      al, 0x02
    call    out_x2
    PS      " imr_s="
    mov     al, byte ptr [st_imr]
    call    out_x2
    PS      " irr_s="
    call    f2_irr
    call    out_x2
    mov     si, offset f2_bda
1:  lodsw
    test    ax, ax
    jz      2f
    push    si
    mov     bx, ax
    PS      " bda"
    mov     ax, bx
    call    out_x4
    mov     al, '='
    call    out_c
    push    es
    xor     ax, ax
    mov     es, ax
    mov     al, byte ptr es:[bx]
    pop     es
    call    out_x2
    pop     si
    jmp     1b
2:  mov     si, offset f2_ports
3:  lodsw
    test    ax, ax
    jz      4f
    push    si
    mov     dx, ax
    PS      " p"
    mov     ax, dx
    call    out_x4
    mov     al, '='
    call    out_c
    in      al, dx
    call    out_x2
    pop     si
    jmp     3b
4:  call    out_nl
    cmp     word ptr [buf_seg], 0
    jne     5f
    mov     si, offset rs_nobuf
    call    skip_line
    jmp     fdc2_exit
5:  movzx   eax, word ptr [buf_seg]
    shl     eax, 4
    add     eax, 0xFFFF
    and     eax, 0xFFFF0000
    mov     dword ptr [fd_phys], eax
    in      al, 0xBE
    test    al, 0x01
    jnz     f2_1m
    cmp     byte ptr [m_m640], 0
    jne     f2_640
    mov     si, offset rs_640
    call    skip_line
    jmp     fdc2_exit
f2_1m:
    cmp     byte ptr [m_m640], 0
    je      6f
    mov     si, offset rs_not640
    call    skip_line
    jmp     fdc2_exit
6:  /* ---- SENSE: the BIOS's INT 1Bh AH=04h on DA 0x90 / 0x91, its own IRQ11 handler ---- */
    xor     bx, bx
f2_sl:
    mov     al, bl
    or      al, 0x90
    mov     byte ptr [fd_us], bl
    mov     si, offset tg2_sense
    push    bx
    mov     ax, 0xFFFF
    call    row_mark
    pop     bx
    push    bx
    push    es
    push    bp
    mov     al, bl
    or      al, 0x90
    mov     ah, 0x04
    int     0x1B
    pop     bp
    pop     es
    pop     bx
    mov     byte ptr [f2_sah + bx], ah
    mov     al, 'D'
    jnc     7f
    mov     al, 'E'
7:  mov     byte ptr [f2_cls + bx], al
    mov     si, offset tg2_sense
    call    f2_x
    PS      " ah="
    mov     al, byte ptr [f2_sah + bx]
    call    out_x2
    PS      " cls="
    mov     al, byte ptr [f2_cls + bx]
    call    out_c
    call    out_nl
    inc     bx
    cmp     bx, 2
    jb      f2_sl
    /* ---- IR11 masked and the counting stub on vector 0x13 for the rest of the section ---- */
    cli
    mov     al, byte ptr [st_imr]
    or      al, 0x08
    mov     byte ptr [f2_imr], al
    out     0x0A, al
    push    es
    xor     ax, ax
    mov     es, ax
    mov     word ptr es:[0x4C], offset fd_eoi
    mov     word ptr es:[0x4E], cs
    pop     es
    mov     byte ptr [fd_hooked], 1
    sti
    /* ---- UNIT u: ST3, the motor, ST3 spun, RECALIBRATE ---- */
    mov     si, offset tg2_unit
    mov     ax, 0x0092
    call    row_mark
    call    fdc_idle
    call    fdc_drain_sis
    xor     bx, bx
8:  mov     byte ptr [fd_us], bl
    call    fdc_sds
    mov     byte ptr [f2_st3a + bx], al
    inc     bx
    cmp     bx, 2
    jb      8b
    call    fd_motor_on
    mov     eax, T_500MS
    call    f2_wait
    xor     bx, bx
f2_ul:
    mov     byte ptr [fd_us], bl
    call    fdc_sds
    mov     byte ptr [f2_st3b], al
    mov     byte ptr [fd_cmdb], 0x07
    mov     byte ptr [fd_cmdb+1], bl
    mov     si, offset fd_cmdb
    mov     cx, 2
    push    bx
    call    fdc_cmd
    mov     ax, 0xFFFF
    jc      9f
    call    fdc_seekend
    jnc     9f
    mov     ax, 0xFFFF
9:  pop     bx
    mov     word ptr [f2_rst0], ax
    mov     si, offset tg2_unit
    call    f2_x
    PS      " cls="
    mov     al, byte ptr [f2_cls + bx]
    call    out_c
    PS      " st3="
    mov     al, byte ptr [f2_st3a + bx]
    call    out_x2
    PS      " st3_spun="
    mov     al, byte ptr [f2_st3b]
    call    out_x2
    PS      " recal_st0="
    mov     al, byte ptr [f2_rst0]
    call    out_x2
    PS      " pcn="
    mov     al, byte ptr [f2_rst0+1]
    call    out_x2
    call    out_nl
    call    fdc_drain_sis
    inc     bx
    cmp     bx, 2
    jb      f2_ul
    /* ---- the disk unit and the empty unit ---- */
    mov     byte ptr [f2_du], 0xFF
    mov     byte ptr [f2_eu], 0xFF
    mov     al, byte ptr [da_arg]
    mov     ah, al
    and     ah, 0xFE
    cmp     ah, 0x90
    jne     10f
    and     al, 1
    mov     byte ptr [f2_du], al
    jmp     11f
10: xor     bx, bx
101: cmp    byte ptr [f2_cls + bx], 'D'
    jne     102f
    mov     byte ptr [f2_du], bl
    jmp     11f
102: inc    bx
    cmp     bx, 2
    jb      101b
11: xor     bx, bx
111: cmp    bl, byte ptr [f2_du]
    je      112f
    cmp     byte ptr [f2_cls + bx], 'E'
    jne     112f
    mov     byte ptr [f2_eu], bl
    jmp     12f
112: inc    bx
    cmp     bx, 2
    jb      111b
12: mov     si, offset k_I
    call    info_start
    PS      "disk_unit="
    mov     al, byte ptr [f2_du]
    call    out_x2
    PS      " empty_unit="
    mov     al, byte ptr [f2_eu]
    call    out_x2
    PS      " dma_phys="
    mov     eax, dword ptr [fd_phys]
    call    out_x8
    call    out_nl
    cmp     byte ptr [f2_du], 0xFF
    jne     f2_disk
    mov     si, offset rs_nodisk
    call    skip_line
    jmp     f2_empty

f2_disk:
    mov     al, byte ptr [f2_du]
    mov     byte ptr [fd_us], al
    /* ---- GEOM: READ IDs until R repeats ---- */
    mov     si, offset tg2_geom
    mov     ax, 0x0092
    call    row_mark
    mov     byte ptr [f2_spt], 0
    mov     byte ptr [fd_n], 0xFF
    mov     word ptr [f2_ids], 0
13: call    fd_readid
    jc      14f
    test    byte ptr [fd_res], 0xC0
    jnz     14f
    inc     word ptr [f2_ids]
    mov     al, byte ptr [fd_res+5]
    cmp     word ptr [f2_ids], 1
    jne     131f
    mov     byte ptr [f2_r0], al
    mov     ah, byte ptr [fd_res+6]
    mov     byte ptr [fd_n], ah
    jmp     132f
131: cmp    al, byte ptr [f2_r0]
    je      14f
132: cmp    al, byte ptr [f2_spt]
    jbe     133f
    mov     byte ptr [f2_spt], al
133: cmp    word ptr [f2_ids], 40
    jb      13b
14: mov     si, offset tg2_geom
    call    f2_x
    PS      " ids="
    movzx   eax, word ptr [f2_ids]
    call    out_d
    PS      " n="
    mov     al, byte ptr [fd_n]
    call    out_x2
    PS      " spt="
    mov     al, byte ptr [f2_spt]
    call    out_x2
    call    out_nl
    call    fdc_drain_sis
    cmp     byte ptr [f2_spt], 2
    jb      15f
    cmp     byte ptr [f2_spt], 26
    ja      15f
    cmp     byte ptr [fd_n], 3
    jbe     16f
15: mov     si, offset rs_nogeom
    call    skip_line
    jmp     f2_empty
16: mov     cl, byte ptr [fd_n]
    mov     ax, 128
    shl     ax, cl
    mov     word ptr [fd_secb], ax
    /* ---- 162: the terminal-count and EOT rows ---- */
    mov     word ptr [f2_ti], offset f2_tct
f2_tl:
    mov     bx, word ptr [f2_ti]
    mov     si, word ptr [bx]
    test    si, si
    jz      f2_tdone
    mov     ax, 0x0092
    call    row_mark
    mov     bx, word ptr [f2_ti]
    mov     al, byte ptr [f2_spt]
    mul     byte ptr [bx+4]
    add     al, byte ptr [bx+5]
    adc     ah, 0
    mov     cx, ax
    mov     word ptr [f2_ns], ax
    mov     al, byte ptr [bx+2]
    mov     ah, byte ptr [bx+3]
    xor     bx, bx
    call    f2_read
    mov     bx, word ptr [f2_ti]
    mov     si, word ptr [bx]
    call    f2_x
    PS      " r0="
    mov     bx, word ptr [f2_ti]
    mov     al, byte ptr [bx+2]
    call    out_x2
    PS      " mt="
    mov     al, byte ptr [bx+3]
    call    out_x2
    PS      " eot="
    mov     al, byte ptr [f2_spt]
    call    out_x2
    PS      " sectors="
    movzx   eax, word ptr [f2_ns]
    call    out_d
    call    f2_prd
    call    out_nl
    mov     di, offset f2_sis
    call    f2_drain
    add     word ptr [f2_ti], 6
    jmp     f2_tl
f2_tdone:
    /* ---- IRQHOLD ---- */
    mov     si, offset tg2_hold
    mov     ax, 0x0092
    call    row_mark
    mov     di, offset f2_sis
    call    f2_drain
    mov     ax, 0x0001
    mov     cx, 1
    xor     bx, bx
    call    f2_read
    call    f2_irr
    mov     byte ptr [f2_irra], al
    mov     eax, T_10MS
    call    f2_wait
    call    f2_irr
    mov     byte ptr [f2_irrb], al
    call    f2_count
    mov     word ptr [f2_cnt], ax
    in      al, 0x90
    mov     byte ptr [f2_msre], al
    mov     di, offset f2_sis
    call    f2_drain
    mov     si, offset tg2_hold
    call    f2_x
    PS      " irr_res="
    mov     al, byte ptr [f2_irra]
    call    out_x2
    PS      " irr_10ms="
    mov     al, byte ptr [f2_irrb]
    call    out_x2
    PS      " irq_unmask="
    movzx   eax, word ptr [f2_cnt]
    call    out_d
    PS      " msr_end="
    mov     al, byte ptr [f2_msre]
    call    out_x2
    PS      " sis="
    mov     di, offset f2_sis
    call    f2_plist
    call    f2_prd
    call    out_nl
    /* ---- VFO (0x94 <- 09, 0C), only where the BIOS writes it (0x0480 bit 4) ---- */
    push    es
    xor     ax, ax
    mov     es, ax
    mov     al, byte ptr es:[0x480]
    pop     es
    test    al, 0x10
    jnz     17f
    mov     si, offset rs_novfo
    call    skip_line
    jmp     f2_dma
17: mov     si, offset tg2_vfo
    mov     ax, 0x0094
    call    row_mark
    call    f2_irr
    mov     byte ptr [f2_irr0], al
    mov     byte ptr [f2_rises], 0
    mov     byte ptr [f2_prev], 0
    mov     dword ptr [f2_tirq], 0xFFFFFFFF
    cli
    mov     al, 0x09
    out     0x94, al
    out     0x5F, al
    mov     al, 0x0C
    out     0x94, al
    call    artic_read
    mov     dword ptr [f2_t0], eax
    sti
    mov     eax, 400 * T_1MS
    call    dl_start
18: call    f2_irr
    and     al, 0x08
    mov     ah, byte ptr [f2_prev]
    mov     byte ptr [f2_prev], al
    test    al, al
    jz      19f
    test    ah, ah
    jnz     19f
    inc     byte ptr [f2_rises]
    cmp     byte ptr [f2_rises], 1
    jne     19f
    call    f2_now
    mov     dword ptr [f2_tirq], eax
19: call    dl_check
    jnc     18b
    call    f2_irr
    mov     byte ptr [f2_irra], al
    call    f2_count
    mov     word ptr [f2_cnt], ax
    in      al, 0x90
    mov     byte ptr [f2_msre], al
    mov     di, offset f2_sis
    call    f2_drain
    mov     si, offset tg2_vfo
    call    f2_x
    PS      " irr_pre="
    mov     al, byte ptr [f2_irr0]
    call    out_x2
    PS      " t_irq_art="
    mov     eax, dword ptr [f2_tirq]
    call    f2_pt
    PS      " rises="
    movzx   eax, byte ptr [f2_rises]
    call    out_d
    PS      " irr_end="
    mov     al, byte ptr [f2_irra]
    call    out_x2
    PS      " irq_unmask="
    movzx   eax, word ptr [f2_cnt]
    call    out_d
    PS      " msr_end="
    mov     al, byte ptr [f2_msre]
    call    out_x2
    PS      " sis="
    mov     di, offset f2_sis
    call    f2_plist
    call    out_nl
    mov     byte ptr [fd_mwr], 2       /* 0x94 left as the BIOS leaves it */
f2_dma:
    /* ---- 177: DMA_REF, DMA_MSR, DMA_92 ---- */
    movzx   cx, byte ptr [f2_spt]
    mov     ax, word ptr [fd_secb]
    mul     cx
    mov     word ptr [f2_len], ax
    mov     word ptr [f2_ti], 0
f2_dl:
    mov     bx, word ptr [f2_ti]
    mov     si, word ptr [f2_dtag + bx]
    mov     ax, 0x0092
    call    row_mark
    mov     bx, word ptr [f2_ti]
    mov     al, byte ptr [f2_dhon + bx]
    mov     byte ptr [f2_hon], al
    mov     al, byte ptr [f2_dr92 + bx]
    mov     byte ptr [f2_r92], al
    mov     bx, word ptr [f2_doff + bx]
    mov     cx, word ptr [f2_len]
    mov     al, 0xA5
    call    f2_fill
    call    f2_hreset
    mov     ax, 0x0001
    movzx   cx, byte ptr [f2_spt]
    call    f2_read
    mov     byte ptr [f2_hon], 0
    mov     byte ptr [f2_r92], 0
    mov     bx, word ptr [f2_ti]
    mov     si, word ptr [f2_dtag + bx]
    call    f2_x
    call    f2_prd
    PS      " msr="
    call    f2_hprint
    cmp     word ptr [f2_ti], 0
    je      22f
    mov     bx, word ptr [f2_ti]
    mov     di, word ptr [f2_doff + bx]
    xor     si, si
    mov     cx, word ptr [f2_len]
    call    f2_cmp
    mov     dword ptr [f2_dif], eax
    mov     word ptr [f2_fst], bx
    PS      " diff="
    mov     eax, dword ptr [f2_dif]
    call    out_d
    PS      " first="
    mov     ax, word ptr [f2_fst]
    call    out_x4
    cmp     word ptr [f2_ti], 4
    jne     22f
    PS      " rd92="
    movzx   cx, byte ptr [f2_rdn]
    xor     ebx, ebx
    test    cx, cx
    jnz     20f
    mov     al, '-'
    call    out_c
    jmp     22f
20: mov     al, byte ptr [f2_rdv + ebx]
    call    out_x2
    mov     al, '@'
    call    out_c
    mov     ax, word ptr [f2_rdc + ebx*2]
    call    out_x4
    inc     ebx
    dec     cx
    jz      22f
    mov     al, ','
    call    out_c
    jmp     20b
22: call    out_nl
    mov     di, offset f2_sis
    call    f2_drain
    add     word ptr [f2_ti], 2
    cmp     word ptr [f2_ti], 6
    jb      f2_dl

f2_empty:
    /* ---- 176: the empty unit, then unit 2 ---- */
    mov     al, byte ptr [f2_eu]
    cmp     al, 0xFF
    jne     23f
    mov     si, offset rs_noempty
    call    skip_line
    jmp     24f
23: mov     byte ptr [fd_us], al
    mov     si, offset tg2_nrid
    mov     al, 0
    call    f2_nr
    mov     si, offset tg2_nrrd
    mov     al, 1
    call    f2_nr
24: mov     byte ptr [fd_us], 2
    mov     si, offset tg2_nru2
    mov     al, 0
    call    f2_nr
    /* ---- 165: the controller reset, motor bit set and clear ---- */
    mov     byte ptr [fd_us], 0
    mov     si, offset tg2_rstm
    mov     ax, 0x0094
    call    row_mark
    mov     ax, 0x1898
    call    f2_rst
    mov     si, offset tg2_rstm
    call    f2_prst
    mov     si, offset tg2_rstnm
    mov     ax, 0x0094
    call    row_mark
    mov     ax, 0x1090
    call    f2_rst
    mov     si, offset tg2_rstnm
    call    f2_prst

fdc2_exit:
    call    sec_disarm
    cmp     byte ptr [fd_dmaon], 0
    je      1f
    mov     byte ptr [fd_dmaon], 0
    call    dma_ch2_off
    mov     si, offset n_dma2
    mov     eax, 0x06
    call    rs_default
1:  cmp     byte ptr [f2_m640w], 0
    je      2f
    /* the 640K hand-back, the BIOS's own (BANK7@0x77B3-0x77BE) */
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     byte ptr es:[0x5D7], 0x96
    mov     al, 0x09
    out     0xCC, al
    out     0x5F, al
    mov     al, 0x0C
    out     0xCC, al
    sti
    pop     es
    mov     si, offset n_cchand
    mov     eax, 0x0C
    call    rs_default
2:  cmp     byte ptr [fd_hooked], 0
    je      4f
    cmp     byte ptr [f2_didrst], 0
    je      3f
    /* after a reset: HSFLOP's SPECIFY and the heads back to track 0 (motor on, spun up) */
    mov     word ptr [f2_pb], 0x90
    call    fd_motor_on
    mov     eax, T_500MS
    call    f2_wait
    call    f2_spec
    xor     bx, bx
21: mov     byte ptr [fd_us], bl
    mov     byte ptr [fd_cmdb], 0x07
    mov     byte ptr [fd_cmdb+1], bl
    mov     si, offset fd_cmdb
    mov     cx, 2
    push    bx
    call    fdc_cmd
    jc      22f
    call    fdc_seekend
22: pop     bx
    inc     bx
    cmp     bx, 2
    jb      21b
    mov     si, offset n_spec
    mov     eax, 0xC146
    call    rs_default
3:  mov     byte ptr [fd_hooked], 0
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
    push    es
    xor     ax, ax
    mov     es, ax
    movzx   eax, byte ptr es:[0x485]
    pop     es
    mov     si, offset n_motor
    cmp     byte ptr [fd_mwr], 0
    jne     31f
    mov     si, offset n_motor0
31: call    rs_default
4:  mov     al, 0x0B                    /* the slave PIC's read register: ISR (IRQWD's) */
    out     0x08, al
    mov     si, offset n_ocw3
    mov     eax, 0x0B
    call    rs_default
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

/* ======================================================================== /M640 (180) */
/* f2_sds640: SENSE DRIVE STATUS of [fd_us] through 0xC8/0xCA -> AL = ST3 (FF failed); then
 * 0xCC read at once and on every change for 20 ms into f2_ccv/f2_cct (6 kept). */
f2_sds640:
    mov     byte ptr [f2_ccn], 0
    mov     al, 0x04
    call    f2_out
    jc      2f
    mov     al, byte ptr [fd_us]
    call    f2_out
    jc      2f
    mov     eax, T_500MS
    call    dl_start
1:  in      al, 0xC8
    and     al, 0xC0
    cmp     al, 0xC0
    je      3f
    call    dl_check
    jnc     1b
2:  mov     al, 0xFF
    mov     byte ptr [f2_st3b], al
    ret
3:  in      al, 0xCA
    mov     byte ptr [f2_st3b], al
    call    artic_read
    mov     dword ptr [f2_t0], eax
    in      al, 0xCC
    mov     byte ptr [f2_ccv], al
    call    f2_now
    mov     dword ptr [f2_cct], eax
    mov     byte ptr [f2_ccn], 1
    mov     eax, 20 * T_1MS
    call    dl_start
4:  in      al, 0xCC
    movzx   ebx, byte ptr [f2_ccn]
    cmp     al, byte ptr [f2_ccv + ebx - 1]
    je      5f
    cmp     bl, 6
    jae     5f
    mov     byte ptr [f2_ccv + ebx], al
    call    f2_now
    mov     dword ptr [f2_cct + ebx*4], eax
    inc     byte ptr [f2_ccn]
5:  call    dl_check
    jnc     4b
    call    io_settle
    in      al, 0xC8
    mov     byte ptr [f2_msre], al
    mov     al, byte ptr [f2_st3b]
    ret

f2_640:
    mov     word ptr [f2_pb], 0xC8
    mov     byte ptr [f2_im], 0x04
    mov     byte ptr [f2_m640w], 1
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     byte ptr es:[0x5D7], 0
    mov     al, 0x08                    /* motor on, as BANK7@0x74E7 */
    out     0xCC, al
    sti
    pop     es
    mov     byte ptr [f2_mot], 1
f2_ml:
    mov     eax, T_500MS
    call    f2_wait
    xor     bx, bx
f2_mu:
    mov     byte ptr [fd_us], bl
    push    bx
    mov     si, offset tg2_m640
    mov     ax, 0x00CA
    call    row_mark
    mov     di, offset f2_sis
    call    f2_drain
    call    f2_sds640
    mov     si, offset tg2_m640
    call    f2_x
    PS      " motor="
    mov     al, byte ptr [f2_mot]
    call    out_x2
    PS      " st3="
    mov     al, byte ptr [f2_st3b]
    call    out_x2
    PS      " msr_end="
    mov     al, byte ptr [f2_msre]
    call    out_x2
    PS      " cc="
    movzx   cx, byte ptr [f2_ccn]
    xor     ebx, ebx
    test    cx, cx
    jnz     1f
    mov     al, '-'
    call    out_c
    jmp     2f
1:  mov     al, byte ptr [f2_ccv + ebx]
    call    out_x2
    mov     al, ':'
    call    out_c
    mov     eax, dword ptr [f2_cct + ebx*4]
    call    out_d
    inc     ebx
    dec     cx
    jz      2f
    mov     al, ','
    call    out_c
    jmp     1b
2:  call    out_nl
    pop     bx
    inc     bx
    cmp     bx, 2
    jb      f2_mu
    cmp     byte ptr [f2_mot], 0
    je      f2_m2
    mov     byte ptr [f2_mot], 0
    xor     al, al                      /* motor off, as BANK7@0x7EF6 (0xCC only) */
    out     0xCC, al
    jmp     f2_ml
f2_m2:
    /* RST640: the reset through 0xCC with IR10 (and IR11) masked */
    mov     al, byte ptr [st_imr]
    or      al, 0x0C
    mov     byte ptr [f2_imr], al
    out     0x0A, al
    mov     byte ptr [fd_us], 0
    mov     si, offset tg2_rst640
    mov     ax, 0x00CC
    call    row_mark
    mov     ax, 0x1898
    call    f2_rst
    mov     si, offset tg2_rst640
    call    f2_prst
    mov     di, offset f2_sis
    call    f2_drain
    cli
    mov     al, byte ptr [st_imr]
    out     0x0A, al
    sti
    mov     byte ptr [f2_didrst], 0     /* the 1 MB tail does not apply here */
    jmp     fdc2_exit

f2_bda:     .word 0x480, 0x485, 0x494, 0x500, 0x55C, 0x55D, 0x55E, 0x55F, 0x5CA, 0x5CB, 0x5D7, 0
f2_ports:   .word 0x90, 0x92, 0x94, 0xBE, 0xBF, 0x4BE, 0xC8, 0xCA, 0xCC, 0
f2_dtag:    .word tg2_dref, tg2_dmsr, tg2_d92
f2_doff:    .word 0x0000, 0x4000, 0x8000
f2_dhon:    .byte 0, 0, 1, 0, 1, 0
f2_dr92:    .byte 0, 0, 0, 0, 1, 0
tg2_sense:  .asciz "SENSE"
tg2_unit:   .asciz "UNIT"
tg2_geom:   .asciz "GEOM"
tg2_tcr3:   .asciz "TC_R3"
tg2_tcmt0:  .asciz "TC_MT0"
tg2_tcmt1:  .asciz "TC_MT1"
tg2_eotnt:  .asciz "EOT_NT"
tg2_eotmt:  .asciz "EOT_MT"
tg2_hold:   .asciz "IRQHOLD"
tg2_vfo:    .asciz "VFO"
tg2_dref:   .asciz "DMA_REF"
tg2_dmsr:   .asciz "DMA_MSR"
tg2_d92:    .asciz "DMA_92"
tg2_nrid:   .asciz "NRID"
tg2_nrrd:   .asciz "NRRD"
tg2_nru2:   .asciz "NRID_U2"
tg2_nrrec:  .asciz "NRREC"
tg2_rstm:   .asciz "RST_M"
tg2_rstnm:  .asciz "RST_NM"
tg2_m640:   .asciz "M640"
tg2_rst640: .asciz "RST640"
rs_640:     .asciz "640k_mode_use_/M640"
rs_not640:  .asciz "not_640k_mode"
rs_nogeom:  .asciz "nogeom"
rs_novfo:   .asciz "bda0480_bit4_clear"
rs_noempty: .asciz "noempty"
n_cchand:   .asciz "PCC_HANDBACK_BDA05D7"
n_spec:     .asciz "SPECIFY_03_C1_46"
n_ocw3:     .asciz "PIC2_OCW3_ISR"

    VARS
    .p2align 2
f2_t0:      .long 0
f2_tirq:    .long 0
f2_ttc:     .long 0
f2_t2:      .long 0
f2_dif:     .long 0
f2_rsv:     .space 8
f2_ht:      .space 32
f2_cct:     .space 24
f2_hc:      .space 16
f2_rdc:     .space 8
f2_pb:      .word 0x90
f2_wa:      .word 0
f2_cnt0:    .word 0
f2_dcnt:    .word 0
f2_nres:    .word 0
f2_ids:     .word 0
f2_ti:      .word 0
f2_ns:      .word 0
f2_cnt:     .word 0
f2_len:     .word 0
f2_tag:     .word 0
f2_rst0:    .word 0
f2_fst:     .word 0
f2_hv:      .space 8
f2_rdv:     .space 4
f2_ccv:     .space 6
f2_sis:     .space 18
f2_sis2:    .space 18
f2_sah:     .space 2
f2_cls:     .space 2
f2_st3a:    .space 2
f2_hn:      .byte 0
f2_ccn:     .byte 0
f2_im:      .byte 8
f2_imr:     .byte 0
f2_irr0:    .byte 0
f2_irra:    .byte 0
f2_irrb:    .byte 0
f2_end:     .byte 0
f2_low:     .byte 0
f2_prev:    .byte 0
f2_rises:   .byte 0
f2_rdn:     .byte 0
f2_hon:     .byte 0
f2_r92:     .byte 0
f2_kind:    .byte 0
f2_msr0:    .byte 0
f2_msre:    .byte 0
f2_st3b:    .byte 0
f2_du:      .byte 0
f2_eu:      .byte 0
f2_spt:     .byte 0
f2_r0:      .byte 0
f2_didrst:  .byte 0
f2_m640w:   .byte 0
f2_mot:     .byte 0
m_m640:     .byte 0
    ENDVARS
