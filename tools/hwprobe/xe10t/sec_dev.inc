/* sec_dev.inc - /IRQ /OPNA /PCM86 /BIOS.
 *
 * /IRQ (W: PIT ch0, INT 08h, IMR bit 0): PIT ch0 is loaded in mode 0 (one-shot, count
 * IRQ_COUNT); at terminal count OUT rises, IRQ0 is requested, and a stub ISR latches ch0
 * as its first act. In mode 0 the counter keeps counting down through 0 -> FFFF, so the
 * counts from the terminal count to the latch are (0x10000 - latched) & 0xFFFF: the IRQ
 * entry latency (PIC + INTA + the CPU's interrupt entry + the latch's own bus time).
 * The same stub entered by `int 08h` (no PIC, no INTA) gives the CPU-only part, and a
 * request already pending in the IRR delivered at the unmask (`out 02h`) gives the
 * gate-lift-to-handler time (the EOI-to-next-IRQ analogue: a held request released). Refused
 * when IRQ0 is unmasked as found (a resident timer user). Restored: the vector and the
 * IMR (read-back), PIT ch0 reloaded in mode 0 with the modulus CAL measured (default).
 *
 * /OPNA (W: silent registers): the YM2608's BUSY flag (status bit 7 at 0x188) after an
 * address write and after a data write to an FM register (0x30 DT/MUL, 0x40 TL <- 7F, 0xA0
 * F-number low, 0xB0 FB/ALG), an SSG register (0x08 volume A <- 0), the rhythm total level
 * (0x11) and ADPCM-B control (0x18C/0x18E reg 0 <- 0). Each trial: PIT latch, the write,
 * the status polled until BUSY clears (counted, bounded by 65535 polls), PIT latch: the
 * busy time is bounded by polls x the 0x188 read cost the /IO row gives. Refused when
 * INT 60h is hooked by a resident driver (a RAM vector that is neither DOS's shared dummy -
 * the vector unused INT F5h also holds - nor an IRET). Every register written is listed
 * as a default.
 *
 * /PCM86 (W: 0xA468, 0xA46C): the FIFO data write cost with playback stopped, the status
 * and control reads, and the FIFO-full point (bytes written until 0xA466 bit 7, ARTIC
 * deadline). The FIFO is reset before and after; 0xA468 is restored from its read-back.
 *
 * /BIOS: INT 18h AH=01 (key sense, non-blocking), AH=02 (shift state), AH=0Ch (text display
 * on: idempotent at a DOS prompt), INT 1Bh AH=04 (SENSE) on DA/UA 0x80, and INT 21h AH=30h,
 * each with IF=1 (the BIOS may need its interrupts). AH=40h/41h/42h (W6's mode sets) are
 * not timed: the graphics mode's as-found state cannot be read back to restore it (R13).
 */
    .equ IRQ_COUNT, 0x0400              /* 1024 PIT counts, about 0.42 ms */
    .equ IRQ_TRIALS, 48

TPL d_nil,      ""
TPL d_k01,      "push ebp; mov ah, 0x01; int 0x18; pop ebp"
TPL d_k02,      "push ebp; mov ah, 0x02; int 0x18; pop ebp"
TPL d_t0c,      "push ebp; mov ah, 0x0C; int 0x18; pop ebp"
TPL d_sns,      "push ebp; mov ax, 0x0480; int 0x1B; pop ebp"
TPL d_dos30,    "push ebp; mov ah, 0x30; int 0x21; pop ebp"
TPL d_set_pcm,  "mov dx, 0xA46C; xor al, al"
TPL d_set_a466, "mov dx, 0xA466"
TPL d_set_a468, "mov dx, 0xA468"
TPL d_out,      "out dx, al"
TPL d_in,       "in al, dx"

tab_bios:
    CASE "INT18_01", "call", 256, 256, 1, d_nil, d_k01,  d_nil, d_nil, CF_NOCLI
    CASE "INT18_02", "call", 256, 256, 1, d_nil, d_k02,  d_nil, d_nil, CF_NOCLI
    CASE "INT18_0C", "call", 64,  64,  1, d_nil, d_t0c,  d_nil, d_nil, CF_NOCLI
    CASE "INT1B_04", "call", 16,  16,  1, d_nil, d_sns,  d_nil, d_nil, CF_NOCLI
    CASE "INT21_30", "call", 256, 256, 1, d_nil, d_dos30, d_nil, d_nil, CF_NOCLI
    ENDTAB
tl_bios:    .word tab_bios, 0
tc_bios:    .asciz "INT 18h AH=01/02/0C, INT 1Bh AH=04 DA=80 (read-only), INT 21h AH=30h"

tab_pcm86:
    CASE "FIFOW",   "io",   1024, 128, 8, d_set_pcm,  d_out, d_nil, d_nil
    CASE "STATR",   "io",   1024, 128, 8, d_set_a466, d_in,  d_nil, d_nil
    CASE "CTLR",    "io",   1024, 128, 8, d_set_a468, d_in,  d_nil, d_nil
    ENDTAB
tl_pcm86:   .word tab_pcm86, 0
tc_pcm86:   .asciz "A468(FIFO reset/stop, restored from read-back) A46C(FIFO data, reset after)"
tc_irq:     .asciz "PIT ch0 (mode 0, reloaded mode 0 with CAL's modulus) IVT[08] IMR bit 0"
tc_opna:    .asciz "OPNA 30=00 40=7F A0=00 B0=00 08=00 11=00, ext reg 00=00 (silent values)"

n_vec08:    .asciz "VEC08"
n_imrm2:    .asciz "IMR_M"
n_imrs2:    .asciz "IMR_S"
n_pitch0:   .asciz "PIT_CH0_MODE0"
n_a468:     .asciz "PA468"
n_opnaregs: .asciz "OPNA_REGS"
rs_irq0use: .asciz "irq0_in_use"
rs_absent:  .asciz "absent"
rs_tsr:     .asciz "tsr_int60"
rs_playing: .asciz "pcm_playing"
to_irq:     .asciz "irq0"
to_unmask:  .asciz "irq0_after_unmask"
to_wrap:    .asciz "pit0_past_terminal_count"
to_opna:    .asciz "opna_busy"
to_fill:    .asciz "pcm_fifo_full"
f_lat:      .asciz "lat_pit"
f_sw:       .asciz "swint_pit"
f_busy:     .asciz "busy_pit"
f_polls:    .asciz "polls"
tn_irq:     .word f_lat
tn_sw:      .word f_sw
tn_um:      .word f_um
f_um:       .asciz "unmask_pit"
tg_um:      .asciz "UNMASK_ENTRY"
tn_opna:    .word f_busy, f_polls
tg_irq:     .asciz "IRQ0_ENTRY"
tg_irqmark: .asciz "IRQ0_ENTRY+INT08_SOFT+UNMASK_ENTRY"
tg_fill:    .asciz "FIFOFILL"
tg_pcmpre:  .asciz "PRECHECK"
tg_sw:      .asciz "INT08_SOFT"

/* ---------------------------------------------------------------- IRQ */
/* the stub ISR: latch ch0 first, then EOI and flag */
irq_isr:
    push    ax
    mov     al, 0
    out     0x77, al
    in      al, 0x71
    mov     byte ptr cs:[ir_b1], al
    in      al, 0x71
    mov     byte ptr cs:[ir_b2], al
    mov     al, 0x20
    out     0x00, al
    mov     byte ptr cs:[ir_flag], 1
    pop     ax
    iret

/* ir_latched: AX = the ISR's latched count in the measured byte order */
ir_latched:
    mov     al, byte ptr [ir_b1]
    mov     ah, byte ptr [ir_b2]
    cmp     byte ptr [pit_swap], 0
    je      1f
    xchg    al, ah
1:  ret

/* pit_peek: AX = channel 0 read WITHOUT the latch command. NP2kai clears IRR bit 0 on
 * every write to 0x77 for channel 0, the latch command included (io/pit.c pit_o77), so a
 * latched read would withdraw the pending request this row measures; a real counter's
 * latch leaves OUT alone. Two unlatched pairs are read until two agree to within 64
 * counts (a pair can tear across a carry between its two bytes). Interrupt state kept. */
pit_peek:
    push    bx
    push    cx
    push    dx
    pushf
    cli
    mov     cx, 8
1:  in      al, 0x71
    mov     dl, al
    in      al, 0x71
    mov     dh, al
    in      al, 0x71
    mov     bl, al
    in      al, 0x71
    mov     bh, al
    cmp     byte ptr [pit_swap], 0
    je      2f
    xchg    dl, dh
    xchg    bl, bh
2:  mov     ax, dx
    sub     ax, bx
    cmp     ax, 64
    jbe     3f
    loop    1b
3:  mov     ax, bx
    popf
    pop     dx
    pop     cx
    pop     bx
    ret

/* pit0_mode0: AX = count; ch0 <- mode 0, LSB then MSB (interrupts off) */
pit0_mode0:
    push    ax
    mov     al, 0x30
    out     0x77, al
    pop     ax
    out     0x71, al
    xchg    al, ah
    out     0x71, al
    xchg    al, ah
    ret

sec_irq:
    mov     si, offset nm_irq
    mov     eax, WD_20S
    mov     bx, offset irq_exit
    call    sec_begin
    mov     byte ptr [ir_hooked], 0
    test    byte ptr [imr_m_save], 1
    jnz     1f
    mov     si, offset rs_irq0use
    call    skip_line
    jmp     irq_end
1:  mov     si, offset tg_irqmark
    mov     ax, 0x0071
    call    row_mark                    /* flushed before INT 08h is hooked: no DOS call after */
    mov     si, offset k_STATE
    call    info_start
    PS      "pit0=mode0 count=1024 imr_m="
    in      al, 0x02
    call    out_x2
    call    out_nl
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     eax, dword ptr es:[0x08*4]
    mov     dword ptr [ir_vsave], eax
    mov     word ptr es:[0x08*4], offset irq_isr
    mov     word ptr es:[0x08*4+2], cs
    sti
    pop     es
    mov     byte ptr [ir_hooked], 1
    /* drain: a request latched in the IRR while IRQ0 was masked would fire at the first
     * unmask; take it (and one real terminal count) before the timed trials */
    cli
    mov     ax, IRQ_COUNT
    call    pit0_mode0
    in      al, 0x02
    and     al, 0xFE
    out     0x02, al
    mov     eax, T_10MS
    call    dl_start
    sti
11: call    dl_check
    jnc     11b
    cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    sti
    /* hardware IRQ0 trials */
    call    tr_reset
    mov     cx, IRQ_TRIALS
2:  push    cx
    cli
    mov     byte ptr [ir_flag], 0
    mov     ax, IRQ_COUNT
    call    pit0_mode0
    in      al, 0x02
    and     al, 0xFE
    out     0x02, al                    /* unmask IRQ0 */
    mov     eax, T_100MS
    call    dl_start
    sti
3:  mov     cx, 4096                    /* a tight spin, the deadline every 4096 */
4:  cmp     byte ptr [ir_flag], 0
    jne     5f
    loop    4b
    call    dl_check
    jnc     3b
    cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    sti
    pop     cx
    mov     si, offset to_irq
    call    timeout_line
    jmp     6f
5:  cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al                    /* mask IRQ0 again */
    sti
    call    ir_latched
    neg     ax                          /* (0x10000 - latched) & 0xFFFF */
    movzx   eax, ax
    xor     bx, bx
    call    tr_put
    call    tr_next
    pop     cx
    loop    2b
6:  mov     word ptr [tr_names], offset tn_irq
    mov     si, offset tg_irq
    mov     cx, 1
    call    tr_print
    /* the same stub by INT 08h: no PIC, no INTA (ch0 keeps counting in mode 0) */
    call    tr_reset
    mov     cx, IRQ_TRIALS
7:  push    cx
    cli
    call    pit_read
    mov     dx, ax
    int     0x08
    sti
    call    ir_latched
    sub     dx, ax                      /* ch0 runs mod 65536 here (mode 0) */
    movzx   eax, dx
    xor     bx, bx
    call    tr_put
    call    tr_next
    pop     cx
    loop    7b
    mov     word ptr [tr_names], offset tn_sw
    mov     si, offset tg_sw
    mov     cx, 1
    call    tr_print
    /* a request already pending in the IRR (terminal count reached while masked),
     * delivered when the mask lifts: PIT latch, out 0x02 (unmask), ISR latch */
    call    tr_reset
    mov     cx, IRQ_TRIALS
13: push    cx
    cli
    mov     byte ptr [ir_flag], 0
    mov     ax, 16
    call    pit0_mode0                  /* terminal count after 16 counts */
    mov     eax, T_10MS
    call    dl_start
14: call    dl_check                    /* wait until it has wrapped below 0 */
    jc      19f
    call    pit_peek
    cmp     ax, 0x8000
    jb      14b
    in      al, 0x02
    and     al, 0xFE
    mov     bl, al
    mov     eax, T_10MS
    call    dl_start
    sti
    call    pit_peek
    mov     dx, ax                      /* p0 (unlatched: no 0x77 write, see pit_peek) */
    mov     al, bl
    out     0x02, al                    /* unmask: the pending IRQ0 is delivered */
15: cmp     byte ptr [ir_flag], 0
    jne     17f
    call    dl_check
    jnc     15b
16: mov     si, offset to_unmask
    jmp     20f
19: mov     si, offset to_wrap
20: cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    sti
    pop     cx
    call    timeout_line
    jmp     18f
17: cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    sti
    call    ir_latched
    sub     dx, ax
    movzx   eax, dx
    xor     bx, bx
    call    tr_put
    call    tr_next
    pop     cx
    loop    13b
18: mov     word ptr [tr_names], offset tn_um
    mov     si, offset tg_um
    mov     cx, 1
    call    tr_print
irq_exit:
    call    sec_disarm
    cmp     byte ptr [ir_hooked], 0
    je      irq_end
    cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    mov     eax, dword ptr [pit_mod]
    call    pit0_mode0                  /* 65536 -> count 0 */
    push    es
    xor     ax, ax
    mov     es, ax
    mov     eax, dword ptr [ir_vsave]
    mov     dword ptr es:[0x08*4], eax
    mov     edx, dword ptr es:[0x08*4]
    pop     es
    mov     al, byte ptr [imr_m_save]
    out     0x02, al
    sti
    mov     si, offset n_vec08
    mov     eax, dword ptr [ir_vsave]
    mov     cx, 0x0208
    mov     bl, 3
    call    rs_line
    mov     dx, 0x02
    mov     al, byte ptr [imr_m_save]
    mov     si, offset n_imrm2
    call    rs_port8
    mov     si, offset n_pitch0
    mov     eax, dword ptr [pit_mod]
    call    rs_default
irq_end:
    call    sec_end
    ret

/* ---------------------------------------------------------------- OPNA */
/* opna_wait: wait until BUSY clears; CF = 1 on the deadline (10 ms) */
opna_wait:
    push    eax
    push    dx
    mov     eax, T_10MS
    call    dl_start
    mov     dx, 0x188
1:  in      al, dx
    test    al, 0x80
    jz      2f
    call    dl_check
    jnc     1b
    pop     dx
    pop     eax
    stc
    ret
2:  pop     dx
    pop     eax
    clc
    ret

/* opna_trial: BX = address port (0x188/0x18C), AL = register, AH = data,
 * [op_mode] 0 = time the address write, 1 = time the data write.
 * Puts busy_pit and polls into the trial buffer. Interrupts off. */
opna_trial:
    pushad
    cli
    call    opna_wait
    jc      9f
    cmp     byte ptr [op_mode], 0
    je      1f
    mov     dx, bx
    out     dx, al                      /* select (untimed) */
    call    opna_wait
    jc      9f
    call    pit_read
    mov     si, ax                      /* p0 */
    mov     al, ah
    add     dx, 2
    out     dx, al                      /* the data write */
    jmp     2f
1:  push    ax
    call    pit_read
    mov     si, ax
    pop     ax
    mov     dx, bx
    out     dx, al                      /* the address write */
2:  xor     cx, cx                      /* polls */
    mov     dx, 0x188
3:  in      al, dx
    inc     cx
    test    al, 0x80
    jz      4f
    cmp     cx, 0xFFFF
    jb      3b
    inc     word ptr [poll_to]
4:  call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    xor     bx, bx
    call    tr_put
    movzx   eax, cx
    mov     bx, 1
    call    tr_put
    call    tr_next
9:  sti
    popad
    ret

/* opna_kind: SI = tag, BX = port, AL = reg, AH = data, DL = mode. 32 trials -> a T row. */
opna_kind:
    push    ax
    mov     ax, bx
    call    row_mark                    /* the tag and the address port, flushed */
    pop     ax
    push    si
    call    tr_reset
    mov     byte ptr [op_mode], dl
    mov     cx, 32
1:  call    wd_check
    call    opna_trial
    loop    1b
    pop     si
    mov     word ptr [tr_names], offset tn_opna
    push    cx
    mov     cx, 2
    call    tr_print
    pop     cx
    ret

tg_oaddr:   .asciz "BUSY_ADDR"
tg_ofm30:   .asciz "BUSY_FM30"
tg_ofm40:   .asciz "BUSY_FM40"
tg_ofma0:   .asciz "BUSY_FMA0"
tg_ofmb0:   .asciz "BUSY_FMB0"
tg_ossg:    .asciz "BUSY_SSG08"
tg_orhy:    .asciz "BUSY_RHY11"
tg_oadb:    .asciz "BUSY_ADPCMB00"

sec_opna:
    mov     si, offset nm_opna
    mov     eax, WD_20S
    mov     bx, offset opna_exit
    call    sec_begin
    mov     byte ptr [op_ran], 0
    mov     dx, 0x188
    in      al, dx
    cmp     al, 0xFF
    jne     1f
    mov     si, offset rs_absent
    call    skip_line
    jmp     opna_end
1:  call    opna_drvchk
    jnc     2f
    mov     si, offset rs_tsr
    call    skip_line
    mov     si, offset k_I
    call    info_start
    PS      "vec60="
    mov     eax, dword ptr [op_v60]
    call    out_x8
    call    out_nl
    jmp     opna_end
2:
    mov     si, offset k_STATE
    call    info_start
    PS      "opna_status="
    mov     dx, 0x188
    in      al, dx
    call    out_x2
    PS      " imr_s="
    in      al, 0x0A
    call    out_x2
    PS      " vec60="
    mov     eax, dword ptr [op_v60]
    call    out_x8
    call    out_nl
    mov     byte ptr [op_ran], 1
    mov     word ptr [poll_to], 0
    mov     si, offset tg_oaddr
    mov     bx, 0x188
    mov     ax, 0x0030
    mov     dl, 0
    call    opna_kind
    mov     si, offset tg_ofm30
    mov     ax, 0x0030
    mov     dl, 1
    call    opna_kind
    mov     si, offset tg_ofm40
    mov     ax, 0x7F40
    call    opna_kind
    mov     si, offset tg_ofma0
    mov     ax, 0x00A0
    call    opna_kind
    mov     si, offset tg_ofmb0
    mov     ax, 0x00B0
    call    opna_kind
    mov     si, offset tg_ossg
    mov     ax, 0x0008
    call    opna_kind
    mov     si, offset tg_orhy
    mov     ax, 0x0011
    call    opna_kind
    mov     si, offset tg_oadb
    mov     bx, 0x18C
    mov     ax, 0x0000
    call    opna_kind
    cmp     word ptr [poll_to], 0
    je      opna_exit
    mov     si, offset to_opna
    call    timeout_line
opna_exit:
    call    sec_disarm
    cmp     byte ptr [op_ran], 0
    je      opna_end
    /* the documented silent values, written again */
    cli
    mov     bx, 0x188
    mov     ax, 0x0030
    call    opna_put
    mov     ax, 0x7F40
    call    opna_put
    mov     ax, 0x00A0
    call    opna_put
    mov     ax, 0x00B0
    call    opna_put
    mov     ax, 0x0008
    call    opna_put
    mov     ax, 0x0011
    call    opna_put
    mov     bx, 0x18C
    mov     ax, 0x0000
    call    opna_put
    sti
    mov     si, offset n_opnaregs
    xor     eax, eax
    call    rs_default
opna_end:
    call    sec_end
    ret

/* opna_drvchk: CF = 1 when INT 60h is hooked by a resident driver (a RAM vector that is
 * neither DOS's shared dummy - the vector unused INT F5h also holds - nor an IRET; a ROM
 * vector at or above C000 is no driver). [op_v60] = the vector. Used by /OPNA and /OPNA2. */
opna_drvchk:
    push    ax
    push    bx
    push    es
    xor     ax, ax
    mov     es, ax
    mov     bx, word ptr es:[0x60*4]
    mov     ax, word ptr es:[0x60*4+2]
    mov     word ptr [op_v60], bx
    mov     word ptr [op_v60+2], ax
    test    ax, ax
    jz      2f
    cmp     ax, 0xC000
    jae     2f
    cmp     bx, word ptr es:[0xF5*4]
    jne     1f
    cmp     ax, word ptr es:[0xF5*4+2]
    je      2f
1:  mov     es, ax
    cmp     byte ptr es:[bx], 0xCF
    je      2f
    pop     es
    pop     bx
    pop     ax
    stc
    ret
2:  pop     es
    pop     bx
    pop     ax
    clc
    ret

opna_put:                               /* BX = port, AL = reg, AH = data */
    push    dx
    call    opna_wait
    mov     dx, bx
    out     dx, al
    call    opna_wait
    xchg    al, ah
    add     dx, 2
    out     dx, al
    xchg    al, ah
    pop     dx
    ret

/* ---------------------------------------------------------------- PCM86 */
sec_pcm86:
    mov     si, offset nm_pcm86
    mov     eax, WD_10S
    mov     bx, offset pcm_exit
    call    sec_begin
    mov     byte ptr [pc_ran], 0
    mov     dx, 0xA460
    in      al, dx
    cmp     al, 0xFF
    jne     1f
    mov     si, offset rs_absent
    call    skip_line
    jmp     pcm_end
1:  mov     si, offset tg_pcmpre
    mov     ax, 0xA468
    call    row_mark                    /* the first read of 0xA468 on a machine */
    mov     dx, 0xA468
    in      al, dx
    mov     byte ptr [pc_save], al
    test    al, 0x80
    jz      2f
    mov     si, offset rs_playing
    call    skip_line
    jmp     pcm_end
2:  mov     byte ptr [pc_ran], 1
    mov     si, offset k_STATE
    call    info_start
    PS      "a468="
    mov     al, byte ptr [pc_save]
    call    out_x2
    PS      " a466="
    mov     dx, 0xA466
    in      al, dx
    call    out_x2
    call    out_nl
    call    pcm_reset
    mov     byte ptr [rm_on], 1         /* a flushed ROW line before each case */
    mov     si, offset tab_pcm86
    call    run_list
    mov     byte ptr [rm_on], 0
    /* the FIFO-full point */
    mov     si, offset tg_fill
    mov     ax, 0xA46C
    call    row_mark
    call    pcm_reset
    cli
    mov     eax, T_1S
    call    dl_start
    xor     ecx, ecx
3:  mov     dx, 0xA466
    in      al, dx
    test    al, 0x80
    jnz     4f
    mov     dx, 0xA46C
    xor     al, al
    out     dx, al
    inc     ecx
    cmp     ecx, 40000
    jae     4f
    test    cx, 255
    jnz     3b
    call    dl_check
    jnc     3b
    sti
    mov     si, offset to_fill
    call    timeout_line
    cli
4:  sti
    call    dl_elapsed
    push    eax
    mov     si, offset k_X
    call    row_start
    PS      "FIFOFILL i=0 bytes="
    mov     eax, ecx
    call    out_d
    PS      " art="
    pop     eax
    call    out_d
    PS      " a466="
    mov     dx, 0xA466
    in      al, dx
    call    out_x2
    call    out_nl
pcm_exit:
    call    sec_disarm
    cmp     byte ptr [pc_ran], 0
    je      pcm_end
    call    pcm_reset
    mov     dx, 0xA468
    mov     al, byte ptr [pc_save]
    and     al, 0xEF
    out     dx, al
    in      al, dx
    and     al, 0xEF
    movzx   edx, al
    movzx   eax, byte ptr [pc_save]
    and     al, 0xEF
    mov     si, offset n_a468
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
pcm_end:
    call    sec_end
    ret

/* pcm_reset: stop, FIFO reset pulse (bit 3), IRQ off; the rate bits kept */
pcm_reset:
    push    ax
    push    dx
    mov     dx, 0xA468
    mov     al, byte ptr [pc_save]
    and     al, 0x47
    or      al, 0x08
    out     dx, al
    and     al, 0x47
    out     dx, al
    pop     dx
    pop     ax
    ret

/* ---------------------------------------------------------------- BIOS */
sec_bios:
    mov     si, offset nm_bios
    mov     eax, WD_20S
    mov     bx, offset bios_exit
    call    sec_begin
    mov     si, offset k_STATE
    call    info_start
    PS      "if=1 (BIOS rows run with interrupts on)"
    call    out_nl
    mov     byte ptr [rm_on], 1         /* a flushed ROW line before each call */
    mov     si, offset tab_bios
    call    run_list
bios_exit:
    call    sec_disarm
    call    sec_end
    ret

    VARS
    .p2align 2
ir_vsave:   .long 0
op_v60:     .long 0
ir_b1:      .byte 0
ir_b2:      .byte 0
ir_flag:    .byte 0
ir_hooked:  .byte 0
op_mode:    .byte 0
op_ran:     .byte 0
pc_save:    .byte 0
pc_ran:     .byte 0
    ENDVARS
