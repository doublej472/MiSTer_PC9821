/* ideprobe.s - a real-machine PC-9821 IDE/ATA probe.
 *
 * WHY. The core's ATA model (src/pc9821/storage/pc9821_ata.sv) is being diffed
 * against the Xe10's authentic IDE. The active bug is that the authentic BIOS's
 * IDE option ROM (BANK3.BIN) issues a task-file command and the core does not
 * answer it as the machine does, so the BIOS falls back to ROM-BASIC. This
 * program measures the machine's own side of every contract that matters, so the
 * core's model and its bench can be checked against silicon rather than against
 * NP2kai or QEMU.
 *
 * It is deliberately the same shape as probe.s: an 8086 real-mode DOS .COM, CS =
 * DS = SS, that prints labelled text records one per line. Redirect it:
 *
 *     A> IDEPROBE > IDE.TXT
 *
 * and send IDE.TXT back. A section that hangs leaves BEGIN:<name> with no
 * END:<name>, so the capture before it is still known to be valid.
 *
 * WHAT IT CAPTURES
 *
 *   PORTMAP  the as-found interface and task-file registers, the legacy 005C/005D
 *            bytes (which are the ARTIC counter, not IDE), and the 0432 bank
 *            select behaviour: the value that makes the task file answer and
 *            whether bit 7 gates it. This is the single most important capture
 *            for the core, whose pc9821_ata.sv gates the block on 0432 bit 7.
 *   REG      the task-file register read-back with the live bank selected.
 *   TIME     the I/O wait-state class table: N back-to-back accesses per IDE
 *            task-file port, each bracketed by an interleaved control row, timed
 *            with the ARTIC counter (005C/005F) and the PIT counter-latch read,
 *            exactly as probe2.s /TIME does. The 005F row is the documented
 *            600 ns / 30 clk reference, so the IDE class's ratio to it gives the
 *            clk_sys value the core's class table should carry (it currently
 *            carries 42 for the IDE data port; the old value was 30).
 *   IDENTIFY ATA IDENTIFY DEVICE 0xEC: the full 256-word response, one word per
 *            line, plus the geometry words 1/3/6, word 49 (LBA/CHS), word 47
 *            (multiple), words 0/53/54-56/60-61/64/82/93 and the CHS capacity.
 *   RECAL    RECALIBRATE 0x10: the status byte sequence with the decoded
 *            BSY/DRDY/DSC/DRQ/ERR bits, so the real drive's transitions are
 *            visible, then the register read-back.
 *   IRQ      the IDE interrupt: the PIC mask as found, the IRR/ISR as found and
 *            during an IDENTIFY, the slave IRQ bit (bit 1 = IRQ9 = vector 0x11),
 *            the vector 0x11 owner, and the stub count. This settles which IRQ
 *            the drive asserts and whether IRQ9 is masked at the prompt.
 *   DRVSEL   the 0x64C drive/head write read-back: re-write the as-found byte
 *            and read ERROR(0642)/STATUS(064E) back, settling whether a
 *            0x64C write clears a pending ERR bit at idle.
 *   RESTORE  the 0432 bank byte put back and re-read, so the machine is left as
 *            it was found.
 *
 * PORTS (verified against NP2kai cbus/ideio.c ideio_bind and a disassembly of the
 * machine's IDE ROM driver):
 *
 *   0430 read   connection register (the machine reads 0x41; bit 6 = slave)
 *   0432 read/write  channel/device bank; NP2kai latches dat & 0x71 only when
 *                    dat bit 7 is CLEAR, and getidedev uses bank[1] & 0x7f.
 *                    Value 1 = the built-in IDE (bit 7 clear). A write with bit
 *                    7 set is a NO-OP in NP2kai, NOT a map gate.
 *   0433 read   IRQ source/acknowledge (NP2kai returns 0x02 when bank 1 is live)
 *   0435 read   0x00
 *   0640/0641   16-bit PIO data port (low byte / high byte)
 *   0642 features (write) / error (read; a read clears ERR)
 *   0644 sector count
 *   0646 sector number
 *   0648 cylinder low
 *   064A cylinder high
 *   064C drive/head (bit 4 = unit, bit 6 = LBA, bits 3:0 = head)
 *   064E command (write) / status (read; a read acknowledges the IRQ)
 *   074C alternate status (read; does NOT acknowledge the IRQ)
 *   074E drive address (NP2kai: 0xC0 | (~head & 0xf) << 2 | (unit ? 1 : 2))
 *   1E8E read/write  the DA000 work-RAM gate (bit 0)
 *   005C..005F  the ARTIC free-running counter (005D and 005E mirror cnt[15:8],
 *               005F is cnt[23:16]) - NOT an IDE port; probed to document that.
 *
 * There is no legacy 05C/05D IDE path in NP2kai or in the docs: the 9821's IDE
 * is the 0640-064E block above. The legacy bytes are read here only so the
 * capture proves they are the ARTIC counter, not a hidden task file.
 *
 * SAFETY
 *   - Commands run with interrupts disabled; a timer or keyboard interrupt must
 *     not drive the task file with the resident driver while a command is in
 *     flight. Nothing calls DOS inside a cli window, so results are buffered.
 *   - The slave 8259's IRQ9 line is masked around every command section except
 *     the IRQ section, so a command the probe issues cannot be delivered to a
 *     resident driver's ISR when interrupts are re-enabled. The caller's own
 *     vector 0x11 and both IMRs are saved and restored.
 *   - 0430 is read, never written (its semantics are not established well enough
 *     to justify writing it). 0432 is written because the machine's own option
 *     ROM issues nine writes to it, so switching banks is normal use; the
 *     as-found byte is put back in RESTORE.
 *   - The data port 0640/0641 is read only when the status register says no data
 *     is pending (DRQ and BSY clear), because a read there drains a word.
 *
 * Built by build_ideprobe.sh: GNU as --32, linked at 0x100, .text only.
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ TM_N,        1024          /* timed accesses per class */
    .equ RECAL_MAX,   64            /* status transitions buffered */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es

    mov     dx, offset msg_banner
    call    puts

    call    sec_portmap
    call    sec_reg
    call    sec_drvsel
    call    sec_time
    call    sec_identify
    call    sec_recal
    call    sec_diag
    call    sec_irq
    call    sec_restore

    mov     dx, offset msg_done
    call    puts
    mov     ax, 0x4C00
    int     0x21
    hlt

/* ==================================================================
 * section: PORTMAP - the as-found registers, the legacy bytes, the bank
 * ================================================================== */
sec_portmap:
    mov     dx, offset msg_begin_portmap
    call    puts

    /* The interface registers, then the whole task file exactly as DOS left it.
     * The task file is read BEFORE any 0432 write so its values are first touch. */
    mov     dx, offset msg_pm_if
    call    puts
    mov     si, offset tab_if
    call    dump_tab

    mov     dx, offset msg_pm_tf
    call    puts
    mov     si, offset tab_taskfile_all
    call    dump_tab

    /* The legacy 005C/005D bytes. NP2kai and the docs put the 9821 IDE at
     * 0640-064E; these are the ARTIC counter, read here to document that. */
    mov     dx, offset msg_pm_legacy
    call    puts
    mov     si, offset tab_legacy
    call    dump_tab

    call    pm_bank

    mov     dx, offset msg_end_portmap
    call    puts
    ret

/* pm_bank: what does 0432 have to be for the task file to answer, and does bit
 * 7 gate it? NP2kai says a write with bit 7 set is a no-op and that bank 1 (bit
 * 7 clear, value 1) selects the built-in IDE. The core's pc9821_ata.sv gates the
 * whole block on 0432 bit 7, so the st01 line is the diff. */
pm_bank:
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_save], al
    push    ax
    mov     dx, offset msg_bank_found
    call    puts
    pop     ax
    call    puthex8
    call    putnl

    cli
    mov     dx, 0x0432
    mov     al, 0x01            /* bank 1, bit 7 CLEAR */
    out     dx, al
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_rb01], al
    mov     dx, 0x064E
    in      al, dx
    mov     [bank_st01], al

    mov     dx, 0x0432
    mov     al, 0x80            /* bit 7 SET: NP2kai ignores the write */
    out     dx, al
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_rb80], al
    mov     dx, 0x064E
    in      al, dx
    mov     [bank_st80], al

    mov     dx, 0x0432
    mov     al, 0x81
    out     dx, al
    mov     dx, 0x064E
    in      al, dx
    mov     [bank_st81], al

    mov     dx, 0x0432
    mov     al, [bank_save]
    out     dx, al
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_after], al
    sti

    mov     dx, offset msg_bank_01
    call    puts
    mov     al, [bank_rb01]
    call    puthex8
    mov     dx, offset msg_bank_st
    call    puts
    mov     al, [bank_st01]
    call    puthex8
    call    putnl

    mov     dx, offset msg_bank_80
    call    puts
    mov     al, [bank_rb80]
    call    puthex8
    mov     dx, offset msg_bank_st
    call    puts
    mov     al, [bank_st80]
    call    puthex8
    call    putnl

    mov     dx, offset msg_bank_81
    call    puts
    mov     al, [bank_st81]
    call    puthex8
    call    putnl

    mov     dx, offset msg_bank_after
    call    puts
    mov     al, [bank_after]
    call    puthex8
    call    putnl
    ret

/* ==================================================================
 * section: REG - the task-file read-back with the live bank selected
 * ================================================================== */
sec_reg:
    mov     dx, offset msg_begin_reg
    call    puts
    cli
    mov     dx, 0x0432
    mov     al, 0x01            /* the value the machine's ROM uses (bit 7 clear) */
    out     dx, al
    call    ata_settle
    sti
    mov     dx, offset msg_reg_hdr
    call    puts
    mov     si, offset tab_taskfile_all
    call    dump_tab
    mov     dx, offset msg_end_reg
    call    puts
    ret

/* ==================================================================
 * section: DRVSEL - the 0x64C drive/head write read-back
 * ================================================================== */
sec_drvsel:
    mov     dx, offset msg_begin_drvsel
    call    puts
    cli
    mov     dx, 0x064C
    in      al, dx
    mov     [drvsel_save], al
    mov     dx, 0x0642
    in      al, dx
    mov     [drvsel_err0], al
    mov     dx, 0x064E
    in      al, dx
    mov     [drvsel_st0], al

    /* The write under test: re-issue the as-found drive/head byte. */
    mov     dx, 0x064C
    mov     al, [drvsel_save]
    out     dx, al
    call    ata_settle

    mov     dx, 0x0642
    in      al, dx
    mov     [drvsel_err1], al
    mov     dx, 0x064E
    in      al, dx
    mov     [drvsel_st1], al

    mov     dx, 0x064C
    mov     al, [drvsel_save]
    out     dx, al
    call    ata_settle
    sti

    mov     dx, offset msg_drvsel_hdr
    call    puts

    mov     dx, offset msg_drvsel_64c
    call    puts
    mov     al, [drvsel_save]
    call    puthex8
    call    putnl

    mov     dx, offset msg_drvsel_err
    call    puts
    mov     al, [drvsel_err0]
    call    puthex8
    mov     dx, offset msg_drvsel_arrow
    call    puts
    mov     al, [drvsel_err1]
    call    puthex8
    call    putnl

    mov     dx, offset msg_drvsel_st
    call    puts
    mov     al, [drvsel_st0]
    call    puthex8
    mov     dx, offset msg_drvsel_arrow
    call    puts
    mov     al, [drvsel_st1]
    call    puthex8
    call    putnl

    mov     dx, offset msg_drvsel_restore
    call    puts
    mov     al, [drvsel_save]
    call    puthex8
    call    putnl

    mov     dx, offset msg_end_drvsel
    call    puts
    ret

/* ==================================================================
 * section: TIME - the I/O wait-state class table
 * ================================================================== */
sec_time:
    mov     dx, offset msg_begin_time
    call    puts
    cli
    mov     dx, 0x0432
    mov     al, 0x01
    out     dx, al
    call    tm_div_probe
    sti
    mov     dx, offset msg_time_hdr
    call    puts
    mov     dx, offset msg_time_div
    call    puts
    mov     ax, [tm_div]
    call    puthex16
    call    putnl
    mov     dx, offset msg_time_cols
    call    puts
    call    tm_class_loop
    mov     dx, offset msg_end_time
    call    puts
    ret

/* tm_class_loop: walk tm_tab. Each entry is {port word, kind byte, pad, label
 * word}. A base entry (kind 0) does the same loop with the bus access replaced by
 * a register move, and becomes the reference for the classes beside it, so the
 * base is INTERLEAVED and a class's excess over its neighbour cancels the run's
 * own scale. */
tm_class_loop:
    push    si
    mov     si, offset tm_tab
    mov     dword ptr [tm_base_pd], 0
tcl_next:
    mov     ax, [si]
    cmp     ax, 0xFFFF
    je      tcl_done
    call    tm_run
    cmp     byte ptr [si+2], 0
    jne     tcl_print
    mov     eax, [tm_pd]
    mov     [tm_base_pd], eax
tcl_print:
    call    tm_print_row
    add     si, 6
    jmp     tcl_next
tcl_done:
    pop     si
    ret

/* tm_run: DS:SI -> entry. Runs TM_N back-to-back accesses of the class inside one
 * cli window and stores the ARTIC delta in [tm_ad] and the PIT oscillator counts
 * in [tm_pd]. kind 0 = base (register move), 1 = in al,dx, 2 = out dx,al. */
tm_run:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    mov     ax, [si]
    mov     [tm_port], ax
    mov     bl, [si+2]
    mov     [tm_kind], bl
    mov     dx, [tm_port]
    xor     di, di
    cli
    call    artic_read
    mov     [tm_a0], eax
    call    pit_read
    mov     [tm_p0], ax
    mov     cx, TM_N
tmL_loop:
    mov     al, [tm_kind]
    test    al, al
    jz      tmL_base
    cmp     al, 2
    je      tmL_out
    in      al, dx
    jmp     tmL_next
tmL_out:
    out     dx, al
    jmp     tmL_next
tmL_base:
    mov     al, bl
tmL_next:
    dec     cx
    jnz     tmL_loop
    call    pit_read
    mov     [tm_p1], ax
    call    artic_read
    mov     [tm_a1], eax
    sti
    mov     eax, [tm_a1]
    sub     eax, [tm_a0]
    mov     [tm_ad], eax
    /* PIT: mode 3 decrements the count by two per oscillator clock, so the
     * signed 16-bit distance ps-pe is twice the clocks moved inside one period,
     * and a negative raw difference means the counter reloaded - one divisor
     * more. A 1 ms window can contain at most one reload. [tm_div] is measured by
     * tm_div_probe. */
    movzx   eax, word ptr [tm_p0]
    movzx   ecx, word ptr [tm_p1]
    sub     eax, ecx
    jns     tmL_half
    movzx   ecx, word ptr [tm_div]
    add     eax, ecx
tmL_half:
    shr     eax, 1
    mov     [tm_pd], eax
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* tm_print_row: DS:SI -> entry. One fixed line, so the decoder needs no guess:
 *   TIME <label> port=PPPP mode=R pit=HHHH base=HHHH artic=HHHHHHHH
 * base is the interleaved control's PIT delta; x5F is pit/base against the 005F
 * row in the decoder. */
tm_print_row:
    push    ax
    push    dx
    push    si
    mov     dx, [si+4]
    call    puts
    mov     dx, offset msg_tm_port
    call    puts
    mov     ax, [si]
    call    puthex16
    mov     dx, offset msg_tm_mode
    call    puts
    mov     dl, 'R'
    cmp     byte ptr [si+2], 0
    jne     tpr_notbase
    mov     dl, 'B'
    jmp     tpr_mode_done
tpr_notbase:
    cmp     byte ptr [si+2], 2
    jne     tpr_mode_done
    mov     dl, 'W'
tpr_mode_done:
    call    putc
    mov     dx, offset msg_tm_pit
    call    puts
    mov     ax, [tm_pd]
    call    puthex16
    mov     dx, offset msg_tm_base
    call    puts
    mov     ax, word ptr [tm_base_pd]
    call    puthex16
    mov     dx, offset msg_tm_artic
    call    puts
    mov     eax, [tm_ad]
    call    puthex32
    call    putnl
    pop     si
    pop     dx
    pop     ax
    ret

/* tm_div_probe: the PIT's own divisor, by watching the counter over a window
 * bounded by the ARTIC counter (6144 ticks = 20 ms at the documented 307200 Hz),
 * longer than one 100 Hz period, so the largest value the counter shows is the
 * divisor (mode 3 sweeps divisor..0 in steps of 2). */
tm_div_probe:
    push    ax
    push    cx
    push    dx
    mov     word ptr [tm_dimax], 0
    call    artic_read
    mov     [tm_a0], eax
    mov     word ptr [tm_guard], 0x1000
tdp_loop:
    call    pit_read
    cmp     ax, [tm_dimax]
    jbe     tdp_next
    mov     [tm_dimax], ax
tdp_next:
    call    artic_read
    sub     eax, [tm_a0]
    cmp     eax, 6144
    jae     tdp_done
    dec     word ptr [tm_guard]
    jnz     tdp_loop
tdp_done:
    mov     ax, [tm_dimax]
    mov     [tm_div], ax
    pop     dx
    pop     cx
    pop     ax
    ret

/* ==================================================================
 * section: IDENTIFY - ATA command 0xEC, all 256 words, and the geometry
 * ================================================================== */
sec_identify:
    mov     dx, offset msg_begin_ident
    call    puts
    cli
    call    irq9_mask
    mov     dx, 0x064C
    mov     al, 0xA0            /* master, CHS, head 0 */
    out     dx, al
    call    ata_settle
    mov     dx, 0x064E
    in      al, dx
    mov     [ident_st0], al
    mov     dx, 0x064E
    mov     al, 0xEC            /* ATA IDENTIFY DEVICE */
    out     dx, al
    call    ata_settle
    call    ata_wait_drq
    mov     byte ptr [ident_cf], 0
    jnc     ident_have
    mov     byte ptr [ident_cf], 1
ident_have:
    jc      ident_noread
    mov     dx, 0x0640
    mov     di, offset id_buf
    mov     cx, 256
    cld
ident_rd:
    in      ax, dx
    stosw
    loop    ident_rd
ident_noread:
    mov     dx, 0x064E
    in      al, dx
    mov     [ident_st1], al
    call    irq9_unmask
    sti

    mov     dx, offset msg_ident_st
    call    puts
    mov     al, [ident_st0]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [ident_st1]
    call    puthex8
    mov     dx, offset msg_ident_wait
    call    puts
    mov     al, [ident_cf]
    call    puthex8
    call    putnl

    mov     dx, offset msg_reg_hdr
    call    puts
    mov     si, offset tab_taskfile_all
    call    dump_tab

    cmp     byte ptr [ident_cf], 0
    jne     ident_no_key
    call    ident_print_keys
ident_no_key:
    mov     dx, offset msg_end_ident
    call    puts
    ret

/* ident_print_keys: the labelled key words, then all 256 words one per line. Only
 * called when the read succeeded, so the buffer holds the drive's response. */
ident_print_keys:
    mov     dx, offset msg_geom
    call    puts
    mov     dx, offset lbl_w0
    mov     bx, offset id_buf+0
    call    pr_keyword
    mov     dx, offset lbl_w1
    mov     bx, offset id_buf+2
    call    pr_keyword
    mov     dx, offset lbl_w3
    mov     bx, offset id_buf+6
    call    pr_keyword
    mov     dx, offset lbl_w6
    mov     bx, offset id_buf+12
    call    pr_keyword
    mov     dx, offset lbl_w49
    mov     bx, offset id_buf+98
    call    pr_keyword
    mov     dx, offset lbl_w47
    mov     bx, offset id_buf+94
    call    pr_keyword
    mov     dx, offset lbl_w53
    mov     bx, offset id_buf+106
    call    pr_keyword
    mov     dx, offset lbl_w54
    mov     bx, offset id_buf+108
    call    pr_keyword
    mov     dx, offset lbl_w55
    mov     bx, offset id_buf+110
    call    pr_keyword
    mov     dx, offset lbl_w56
    mov     bx, offset id_buf+112
    call    pr_keyword
    mov     dx, offset lbl_w60
    mov     bx, offset id_buf+120
    call    pr_keyword
    mov     dx, offset lbl_w61
    mov     bx, offset id_buf+122
    call    pr_keyword
    mov     dx, offset lbl_w64
    mov     bx, offset id_buf+128
    call    pr_keyword
    mov     dx, offset lbl_w82
    mov     bx, offset id_buf+164
    call    pr_keyword
    mov     dx, offset lbl_w93
    mov     bx, offset id_buf+186
    call    pr_keyword
    call    putnl

    mov     dx, offset msg_idw_hdr
    call    puts
    mov     si, offset id_buf
    xor     bx, bx
ident_w:
    mov     dx, offset msg_idw
    call    puts
    mov     ax, bx
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [si]
    call    puthex16
    call    putnl
    add     si, 2
    inc     bx
    cmp     bx, 256
    jb      ident_w
    ret

/* ==================================================================
 * section: RECAL - RECALIBRATE 0x10 and the status byte sequence
 * ================================================================== */
sec_recal:
    mov     dx, offset msg_begin_recal
    call    puts
    cli
    call    irq9_mask
    mov     dx, 0x064C
    mov     al, 0xA0
    out     dx, al
    call    ata_settle
    mov     dx, 0x064E
    in      al, dx
    mov     [recal_st0], al
    mov     dx, 0x064E
    mov     al, 0x10            /* ATA RECALIBRATE */
    out     dx, al
    call    ata_settle

    /* Poll the status register, recording every CHANGE with the poll count, until
     * BSY clears. The sequence is buffered because this runs with interrupts
     * disabled and DOS may not be called in that window. */
    mov     word ptr [recal_cnt], 0
    mov     word ptr [recal_nseq], 0
    xor     si, si
    mov     byte ptr [recal_prev], 0xFF
    mov     bp, 0x20
recal_outer:
    mov     cx, 0
recal_inner:
    mov     dx, 0x064E
    in      al, dx
    inc     word ptr [recal_cnt]
    cmp     al, [recal_prev]
    je      recal_same
    mov     [recal_prev], al
    cmp     si, RECAL_MAX
    jae     recal_same
    mov     [recal_st+si], al
    mov     bx, si
    shl     bx, 1
    mov     ax, [recal_cnt]
    mov     [recal_n+bx], ax
    inc     si
recal_same:
    test    byte ptr [recal_prev], 0x80
    jz      recal_ready
    loop    recal_inner
    dec     bp
    jnz     recal_outer
recal_ready:
    mov     [recal_nseq], si
    mov     dx, 0x064E
    in      al, dx
    mov     [recal_st1], al
    call    irq9_unmask
    sti

    mov     dx, offset msg_recal_st
    call    puts
    mov     al, [recal_st0]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [recal_st1]
    call    puthex8
    mov     dx, offset msg_recal_total
    call    puts
    mov     ax, [recal_cnt]
    call    putdec16
    call    putnl

    mov     dx, offset msg_recal_seq_hdr
    call    puts
    xor     si, si
    mov     cx, [recal_nseq]
    test    cx, cx
    jz      recal_seq_done
recal_seq_loop:
    push    cx
    mov     dx, offset msg_recal_seq
    call    puts
    mov     bx, si
    shl     bx, 1
    mov     ax, [recal_n+bx]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     al, [recal_st+si]
    push    ax
    call    puthex8
    pop     ax
    call    pr_status_bits
    call    putnl
    inc     si
    pop     cx
    loop    recal_seq_loop
recal_seq_done:
    mov     dx, offset msg_reg_hdr
    call    puts
    mov     si, offset tab_taskfile_all
    call    dump_tab
    mov     dx, offset msg_end_recal
    call    puts
    ret

/* ==================================================================
 * section: DIAG - EXECUTE DEVICE DIAGNOSTIC 0x90 and DEVICE RESET 0x08:
 * the ERROR register read-back (0x01 vs 0x81)
 * ================================================================== */
sec_diag:
    mov     dx, offset msg_begin_diag
    call    puts
    cli
    call    irq9_mask
    mov     dx, 0x0432
    mov     al, 0x01
    out     dx, al
    call    ata_settle
    mov     dx, 0x064C
    mov     al, 0xA0
    out     dx, al
    call    ata_settle
    mov     dx, 0x064E
    in      al, dx
    mov     [diag_st0], al

    mov     dx, 0x064E
    mov     al, 0x90            /* EXECUTE DEVICE DIAGNOSTIC */
    out     dx, al
    mov     cx, 0xFFFF
diag_wait90:
    mov     dx, 0x064E
    in      al, dx
    test    al, 0x80
    jz      diag90_ready
    loop    diag_wait90
diag90_ready:
    mov     [diag_st90], al
    mov     dx, 0x0642
    in      al, dx              /* ERROR register (a read clears ERR) */
    mov     [diag_err90], al
    mov     dx, 0x0641
    in      al, dx
    mov     [diag_odd641], al
    mov     dx, 0x0643
    in      al, dx
    mov     [diag_odd643], al

    mov     dx, 0x064E
    mov     al, 0x08            /* DEVICE RESET */
    out     dx, al
    mov     cx, 0xFFFF
diag_wait08:
    mov     dx, 0x064E
    in      al, dx
    test    al, 0x80
    jz      diag08_ready
    loop    diag_wait08
diag08_ready:
    mov     [diag_st08], al
    mov     dx, 0x0642
    in      al, dx              /* ERROR register */
    mov     [diag_err08], al
    call    irq9_unmask
    sti

    mov     dx, offset msg_diag_hdr
    call    puts
    mov     al, [diag_st0]
    call    puthex8
    mov     dx, offset msg_diag_st90
    call    puts
    mov     al, [diag_st90]
    call    puthex8
    mov     dx, offset msg_diag_err90
    call    puts
    mov     al, [diag_err90]
    call    puthex8
    mov     dx, offset msg_diag_odd
    call    puts
    mov     al, [diag_odd641]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [diag_odd643]
    call    puthex8
    call    putnl
    mov     dx, offset msg_diag_st08
    call    puts
    mov     al, [diag_st08]
    call    puthex8
    mov     dx, offset msg_diag_err08
    call    puts
    mov     al, [diag_err08]
    call    puthex8
    call    putnl
    mov     dx, offset msg_end_diag
    call    puts
    ret

/* ==================================================================
 * section: IRQ - which PIC IRQ the IDE asserts, and the mask
 * ================================================================== */
sec_irq:
    mov     dx, offset msg_begin_irq
    call    puts
    cli
    /* The as-found vector 0x11 (IRQ9's vector) and the PIC state. Read through
     * segment 0: in a .COM, DS = CS = PSP, so a bare [0x0044] reads the PSP, not
     * the IVT. */
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x0044]
    mov     [vec_off], ax
    mov     ax, es:[0x0046]
    mov     [vec_seg], ax
    pop     es
    mov     dx, 0x0002
    in      al, dx
    mov     [imr_m_found], al
    mov     dx, 0x000A
    in      al, dx
    mov     [imr_s_found], al
    call    pic_read_state

    /* Install our own stub so we can count the IRQ and read the in-service
     * level, then unmask the cascade (master bit 7) and IRQ9 (slave bit 1). */
    push    es
    xor     ax, ax
    mov     es, ax
    mov     word ptr es:[0x0044], offset irq_stub
    push    cs
    pop     ax
    mov     es:[0x0046], ax
    pop     es

    mov     dx, 0x000A
    in      al, dx
    mov     [imr_s_save], al
    and     al, 0xFD
    out     dx, al
    mov     dx, 0x0002
    in      al, dx
    mov     [imr_m_save], al
    and     al, 0x7F
    out     dx, al

    mov     word ptr [irq_count], 0
    mov     byte ptr [irq_status], 0
    mov     dx, 0x064C
    mov     al, 0xA0
    out     dx, al
    mov     dx, 0x064E
    in      al, dx
    mov     [irq_pre], al
    call    ata_settle
    mov     dx, 0x064E
    mov     al, 0xEC
    out     dx, al

    /* Spin on the slave IRR (still IF=0, so nothing is delivered yet) until the
     * request latches, then sti so the stub runs. This captures the LEVEL. The
     * bound is ~2M IRR polls, so a drive that never interrupts costs about a
     * second, not a spin. */
    mov     bp, 0x20
irq_spin_outer:
    mov     cx, 0
irq_spin_inner:
    mov     al, 0x0A
    out     0x08, al
    in      al, 0x08
    mov     [irq_slave_irr], al
    test    al, 0x02
    jnz     irq_spin_have
    loop    irq_spin_inner
    dec     bp
    jnz     irq_spin_outer
irq_spin_have:
    sti
    mov     word ptr [irq_guard], 0xFFFF
irq_wait:
    cmp     word ptr [irq_count], 0
    jne     irq_got
    dec     word ptr [irq_guard]
    jnz     irq_wait
irq_got:
    cli
    mov     dx, 0x064E
    in      al, dx
    mov     [irq_final], al
    test    al, 0x08
    jz      irq_nodrain
    mov     dx, 0x0640
    mov     cx, 256
    mov     di, offset irq_drain
irq_drain_loop:
    in      ax, dx
    stosw
    loop    irq_drain_loop
irq_nodrain:
    mov     dx, 0x0002
    mov     al, [imr_m_save]
    out     dx, al
    mov     dx, 0x000A
    mov     al, [imr_s_save]
    out     dx, al
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, [vec_off]
    mov     es:[0x0044], ax
    mov     ax, [vec_seg]
    mov     es:[0x0046], ax
    pop     es
    sti

    /* Print the whole capture. */
    mov     dx, offset msg_irq_vec
    call    puts
    mov     ax, [vec_seg]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, [vec_off]
    call    puthex16
    call    putnl

    mov     dx, offset msg_irq_found
    call    puts
    mov     al, [imr_m_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [imr_s_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [irr_m_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [isr_m_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [irr_s_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [isr_s_found]
    call    puthex8
    call    putnl

    mov     dx, offset msg_irq_during
    call    puts
    mov     al, [irq_slave_irr]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [irq_slave_isr]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [irq_master_irr]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [irq_master_isr]
    call    puthex8
    call    putnl

    mov     dx, offset msg_irq_stat
    call    puts
    mov     al, [irq_status]
    call    puthex8
    mov     dx, offset msg_irq_stat2
    call    puts
    mov     ax, [irq_count]
    call    putdec16
    mov     dx, offset msg_irq_stat3
    call    puts
    mov     al, [irq_pre]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [irq_final]
    call    puthex8
    call    putnl

    mov     dx, offset msg_end_irq
    call    puts
    ret

/* irq_stub: the IDE ISR. Captures the in-service PIC state, reads the status
 * register (which acknowledges the drive's IRQ), counts, then EOIs the slave and
 * the master only if no other slave request is still in service - the same
 * sequence the machine's own option ROM uses (BANK3+0x1A28-0x1A4C). */
irq_stub:
    push    ax
    push    dx
    push    ds
    push    cs
    pop     ds
    mov     al, 0x0A
    out     0x08, al
    in      al, 0x08
    mov     [irq_slave_irr2], al
    mov     al, 0x0B
    out     0x08, al
    in      al, 0x08
    mov     [irq_slave_isr], al
    mov     al, 0x0A
    out     0x00, al
    in      al, 0x00
    mov     [irq_master_irr], al
    mov     al, 0x0B
    out     0x00, al
    in      al, 0x00
    mov     [irq_master_isr], al
    mov     dx, 0x064E
    in      al, dx
    mov     [irq_status], al
    inc     word ptr [irq_count]
    mov     al, 0x20
    out     0x08, al
    mov     al, 0x0B
    out     0x08, al
    in      al, 0x08
    test    al, al
    jnz     irq_stub_done
    mov     al, 0x20
    out     0x00, al
irq_stub_done:
    pop     ds
    pop     dx
    pop     ax
    iret

/* pic_read_state: the master/slave IRR and ISR words into the *_found bytes. */
pic_read_state:
    mov     al, 0x0A
    out     0x00, al
    in      al, 0x00
    mov     [irr_m_found], al
    mov     al, 0x0B
    out     0x00, al
    in      al, 0x00
    mov     [isr_m_found], al
    mov     al, 0x0A
    out     0x08, al
    in      al, 0x08
    mov     [irr_s_found], al
    mov     al, 0x0B
    out     0x08, al
    in      al, 0x08
    mov     [isr_s_found], al
    ret

/* ==================================================================
 * section: RESTORE - put the 0432 bank byte back
 * ================================================================== */
sec_restore:
    mov     dx, offset msg_begin_restore
    call    puts
    cli
    mov     dx, 0x0432
    mov     al, [bank_save]
    out     dx, al
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_after], al
    sti
    mov     dx, offset msg_restore_432
    call    puts
    mov     al, [bank_save]
    call    puthex8
    mov     dx, offset msg_restore_arrow
    call    puts
    mov     al, [bank_after]
    call    puthex8
    call    putnl
    mov     dx, offset msg_end_restore
    call    puts
    ret

/* ==================================================================
 * ATA and PIC helpers
 * ================================================================== */
/* irq9_mask / irq9_unmask: mask or restore the slave 8259's IRQ9 line (bit 1)
 * around a command section, so a command the probe issues is not delivered to a
 * resident driver's ISR. The as-found byte is saved on the first mask. */
irq9_mask:
    push    ax
    push    dx
    mov     dx, 0x000A
    in      al, dx
    mov     [imr_s_save], al
    or      al, 0x02
    out     dx, al
    pop     dx
    pop     ax
    ret

irq9_unmask:
    push    ax
    push    dx
    mov     dx, 0x000A
    mov     al, [imr_s_save]
    out     dx, al
    pop     dx
    pop     ax
    ret

/* ata_settle: a short settle after a register write (a few I/O reads). */
ata_settle:
    push    ax
    push    cx
    push    dx
    mov     cx, 20
asl_loop:
    mov     dx, 0x0060
    in      al, dx
    loop    asl_loop
    pop     dx
    pop     cx
    pop     ax
    ret

/* ata_wait_drq: wait for DRQ or ERR with a bounded poll (CF set on error or
 * timeout). Runs inside a cli window. */
ata_wait_drq:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, 0x10
aw_outer:
    mov     cx, 0
aw_inner:
    mov     dx, 0x064E
    in      al, dx
    test    al, 0x08            /* DRQ */
    jnz     aw_ok
    test    al, 0x01            /* ERR */
    jnz     aw_fail
    loop    aw_inner
    dec     bx
    jnz     aw_outer
aw_fail:
    stc
    jmp     aw_done
aw_ok:
    clc
aw_done:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* artic_read: EAX = the free-running counter at 005C (bits 15:0) / 005F
 * (bits 23:16). 005D and 005E both mirror cnt[15:8]; 005F is cnt[23:16]. The low
 * word wraps every 213 ms at the documented 307200 Hz, so it is read again after
 * the high byte and a wrap bumps the high byte. Read-only. */
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

/* pit_latch: the PIT counter-latch command, 0077 <- 00. Stateless. */
pit_latch:
    push    dx
    push    ax
    mov     dx, 0x0077
    mov     al, 0x00
    out     dx, al
    pop     ax
    pop     dx
    ret

/* pit_read: AX = channel 0's latched count, in the byte order pit_cal measured.
 * cli covers the latch, the two reads and the one-time calibration. */
pit_read:
    push    dx
    push    cx
    pushf
    cli
    cmp     byte ptr [pit_cal_ok], 0
    jne     pr_go
    call    pit_cal
pr_go:
    call    pit_word
    popf
    pop     cx
    pop     dx
    ret

/* pit_word: one latched pair -> AX, in the byte order pit_cal decided. */
pit_word:
    call    pit_bytes
    mov     al, [pit_b1]
    mov     ah, [pit_b2]
    cmp     byte ptr [pit_swap], 0
    je      pw_done
    xchg    al, ah
pw_done:
    ret

/* pit_bytes: latch channel 0, then the two bytes 0071 returns into pit_b1 and
 * pit_b2. */
pit_bytes:
    push    dx
    call    pit_latch
    mov     dx, 0x0071
    in      al, dx
    mov     [pit_b1], al
    in      al, dx
    mov     [pit_b2], al
    pop     dx
    ret

/* pit_cal: set pit_swap by watching which of the two bytes 0071 returns moves.
 * Mode 3 decrements the count every oscillator clock, so over 32 paired reads the
 * LSB falls on almost every sample and the MSB on almost none; the byte that
 * falls more often is the LSB. The latch command does not restore the read
 * pointer on this machine, so the order is measured, not assumed. */
pit_cal:
    push    ax
    push    cx
    push    dx
    mov     word ptr [pit_d1], 0
    mov     word ptr [pit_d2], 0
    call    pit_bytes
    mov     al, [pit_b1]
    mov     [pit_pb1], al
    mov     al, [pit_b2]
    mov     [pit_pb2], al
    mov     cx, 32
pc_loop:
    call    pit_bytes
    mov     al, [pit_b1]
    cmp     al, [pit_pb1]
    jae     pc_n1
    inc     word ptr [pit_d1]
pc_n1:
    mov     [pit_pb1], al
    mov     al, [pit_b2]
    cmp     al, [pit_pb2]
    jae     pc_n2
    inc     word ptr [pit_d2]
pc_n2:
    mov     [pit_pb2], al
    loop    pc_loop
    mov     byte ptr [pit_swap], 0
    mov     ax, [pit_d2]
    cmp     ax, [pit_d1]
    jbe     pc_done
    mov     byte ptr [pit_swap], 1
pc_done:
    mov     byte ptr [pit_cal_ok], 1
    pop     dx
    pop     cx
    pop     ax
    ret

/* ==================================================================
 * Output and table helpers
 * ================================================================== */
putc:                           /* DL = character */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

puts:                           /* DX = '$'-terminated string */
    push    ax
    push    dx
    mov     ah, 0x09
    int     0x21
    pop     dx
    pop     ax
    ret

putnl:
    push    dx
    mov     dl, 0x0D
    call    putc
    mov     dl, 0x0A
    call    putc
    pop     dx
    ret

puthex8:                        /* AL */
    push    ax
    push    cx
    mov     cl, al
    shr     al, 4
    call    puthexdig
    mov     al, cl
    and     al, 0x0F
    call    puthexdig
    pop     cx
    pop     ax
    ret

puthexdig:                      /* AL = 0..15 -> one ASCII hex digit */
    push    ax
    push    dx
    and     al, 0x0F
    cmp     al, 10
    jb      phd_lo
    add     al, 'A' - 10
    jmp     phd_out
phd_lo:
    add     al, '0'
phd_out:
    mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret

puthex16:                       /* AX */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

puthex32:                       /* EAX */
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
    call    puthex16
    ret

putdec16:                       /* AX, unsigned decimal */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, 10
    xor     cx, cx
pd_loop:
    xor     dx, dx
    div     bx
    push    dx
    inc     cx
    test    ax, ax
    jnz     pd_loop
pd_out:
    pop     dx
    add     dl, '0'
    call    putc
    loop    pd_out
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

putbit:                         /* AL bit 0 -> '0'/'1' */
    push    ax
    push    dx
    and     al, 1
    add     al, '0'
    mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret

/* pr_status_bits: AL = ATA status -> " BSY=n DRDY=n DSC=n DRQ=n ERR=n". */
pr_status_bits:
    push    ax
    push    bx
    mov     bl, al
    mov     dx, offset msg_bit_bsy
    call    puts
    mov     al, bl
    shr     al, 7
    call    putbit
    mov     dx, offset msg_bit_drdy
    call    puts
    mov     al, bl
    shr     al, 6
    call    putbit
    mov     dx, offset msg_bit_dsc
    call    puts
    mov     al, bl
    shr     al, 4
    call    putbit
    mov     dx, offset msg_bit_drq
    call    puts
    mov     al, bl
    shr     al, 3
    call    putbit
    mov     dx, offset msg_bit_err
    call    puts
    mov     al, bl
    call    putbit
    pop     bx
    pop     ax
    ret

/* pr_keyword: DX = label ptr, BX = word address -> "label=XXXX ". */
pr_keyword:
    push    ax
    push    bx
    push    dx
    call    puts
    mov     dl, '='
    call    putc
    mov     ax, [bx]
    call    puthex16
    mov     dl, ' '
    call    putc
    pop     dx
    pop     bx
    pop     ax
    ret

/* rd_byte: DX = port -> AL, CF set when the read was deliberately skipped. The
 * ATA data ports 0640/0641 and 0740/0741 consume state when read, so they are
 * read only when the owning status register says nothing is pending. */
rd_byte:
    cmp     dx, 0x0640
    je      rb0
    cmp     dx, 0x0641
    je      rb0
    cmp     dx, 0x0740
    je      rb1
    cmp     dx, 0x0741
    je      rb1
    in      al, dx
    clc
    ret
rb0:
    push    dx
    mov     dx, 0x064E
    in      al, dx
    pop     dx
    test    al, 0x88            /* BSY or DRQ pending */
    jnz     rb_skip
    in      al, dx
    clc
    ret
rb1:
    push    dx
    mov     dx, 0x074E
    in      al, dx
    pop     dx
    test    al, 0x88
    jnz     rb_skip
    in      al, dx
    clc
    ret
rb_skip:
    stc
    ret

/* pr_port: DX = port, AL = value -> "PPPP=VV". */
pr_port:
    push    ax
    push    dx
    mov     ax, dx
    call    puthex16
    mov     dl, '='
    call    putc
    pop     dx
    pop     ax
    call    puthex8
    ret

/* dump_tab: DS:SI = table of words, 0xFFFF terminated. Prints each port and its
 * value, eight per line. A skipped read prints "PPPP=--". */
dump_tab:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    xor     bx, bx
dt_loop:
    mov     dx, [si]
    cmp     dx, 0xFFFF
    je      dt_done
    add     si, 2
    call    rd_byte
    jc      dt_skip
    call    pr_port
    jmp     dt_after
dt_skip:
    push    dx
    mov     ax, dx
    call    puthex16
    mov     dl, '='
    call    putc
    mov     dl, '-'
    call    putc
    mov     dl, '-'
    call    putc
    pop     dx
dt_after:
    mov     dl, ' '
    call    putc
    inc     bx
    test    bx, 7
    jnz     dt_loop
    call    putnl
    jmp     dt_loop
dt_done:
    call    putnl
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ==================================================================
 * Data
 * ================================================================== */
tab_if:
    .word 0x0430, 0x0432, 0x0433, 0x0435, 0x1E8E
    .word 0xFFFF

tab_taskfile_all:
    .word 0x0640, 0x0641, 0x0642, 0x0644, 0x0646, 0x0648, 0x064A, 0x064C
    .word 0x064E, 0x0740, 0x0741, 0x0742, 0x0744, 0x0746, 0x0748, 0x074A
    .word 0x074C, 0x074E
    .word 0xFFFF

tab_legacy:
    .word 0x005C, 0x005D, 0x005E, 0x005F
    .word 0xFFFF

/* tm_tab: {port word, kind byte, pad, label word}. kind 0 = base, 1 = in, 2 =
 * out. The base is interleaved between every pair of classes AND after the last,
 * so each class's control sits beside it. */
tm_tab:
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x005F
    .byte 2, 0
    .word lbl_tm_wait
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0640
    .byte 1, 0
    .word lbl_tm_ided0
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0641
    .byte 1, 0
    .word lbl_tm_ided1
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x064E
    .byte 1, 0
    .word lbl_tm_stat
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0642
    .byte 1, 0
    .word lbl_tm_err
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0644
    .byte 1, 0
    .word lbl_tm_cnt
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0646
    .byte 1, 0
    .word lbl_tm_sec
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0648
    .byte 1, 0
    .word lbl_tm_cyl
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x064A
    .byte 1, 0
    .word lbl_tm_cyh
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x064C
    .byte 1, 0
    .word lbl_tm_dh
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x074C
    .byte 1, 0
    .word lbl_tm_alt
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x074E
    .byte 1, 0
    .word lbl_tm_da
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0430
    .byte 1, 0
    .word lbl_tm_430
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x0432
    .byte 1, 0
    .word lbl_tm_432
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0x1E8E
    .byte 1, 0
    .word lbl_tm_1e8e
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
    .word 0xFFFF

/* The labels are '$'-terminated like every other printed string, NOT .asciz. The
 * only string printer is puts (DOS AH=09), which runs on to the next '$'; a
 * NUL-terminated label makes puts print through the rest of this table and into
 * the banner, which garbles every TIME and IDENTIFY row. */
lbl_tm_base:    .ascii "BASE    $"
lbl_tm_wait:    .ascii "WAIT5F  $"
lbl_tm_ided0:   .ascii "IDEDAT0 $"
lbl_tm_ided1:   .ascii "IDEDAT1 $"
lbl_tm_stat:    .ascii "ATASTAT $"
lbl_tm_err:     .ascii "ATAERR  $"
lbl_tm_cnt:     .ascii "ATACNT  $"
lbl_tm_sec:     .ascii "ATASEC  $"
lbl_tm_cyl:     .ascii "ATACYL  $"
lbl_tm_cyh:     .ascii "ATACYH  $"
lbl_tm_dh:      .ascii "ATADH   $"
lbl_tm_alt:     .ascii "ATAALT  $"
lbl_tm_da:      .ascii "ATA74E  $"
lbl_tm_430:     .ascii "ATA430  $"
lbl_tm_432:     .ascii "ATA432  $"
lbl_tm_1e8e:    .ascii "ATA1E8E $"

lbl_w0:         .ascii "w0$"
lbl_w1:         .ascii "w1$"
lbl_w3:         .ascii "w3$"
lbl_w6:         .ascii "w6$"
lbl_w47:        .ascii "w47$"
lbl_w49:        .ascii "w49$"
lbl_w53:        .ascii "w53$"
lbl_w54:        .ascii "w54$"
lbl_w55:        .ascii "w55$"
lbl_w56:        .ascii "w56$"
lbl_w60:        .ascii "w60$"
lbl_w61:        .ascii "w61$"
lbl_w64:        .ascii "w64$"
lbl_w82:        .ascii "w82$"
lbl_w93:        .ascii "w93$"

msg_banner:
    .ascii "IDEPROBE - PC-9821 real-machine IDE/ATA probe (tools/hwprobe/ideprobe.s)\r\n"
    .ascii "Ports: 0430/0432/0433/0435 interface, 0640-064E task file, 074C/074E alt;\r\n"
    .ascii "005C-005F are the ARTIC counter, not IDE. Sections are BEGIN:/END: bracketed.\r\n$"
msg_done:       .ascii "IDEPROBE DONE\r\n$"

msg_begin_portmap: .ascii "BEGIN:PORTMAP\r\n$"
msg_pm_if:      .ascii "  interface registers as found (0430 0432 0433 0435 1E8E):\r\n$"
msg_pm_tf:      .ascii "  task file as found BEFORE any 0432 write (0640-064E, 0740-074E):\r\n$"
msg_pm_legacy:  .ascii "  legacy 005C-005F (the ARTIC counter, not IDE):\r\n$"
msg_bank_found: .ascii "  BANK 0432 as found = $"
msg_bank_01:    .ascii "  BANK 0432<-01 rb=$"
msg_bank_80:    .ascii "  BANK 0432<-80 rb=$"
msg_bank_81:    .ascii "  BANK 0432<-81 status=$"
msg_bank_st:    .ascii " st=$"
msg_bank_after: .ascii "  BANK 0432 restored rb=$"
msg_end_portmap: .ascii "END:PORTMAP\r\n$"

msg_begin_reg:  .ascii "BEGIN:REG\r\n$"
msg_reg_hdr:    .ascii "  task file with 0432=01 (live bank):\r\n$"
msg_end_reg:    .ascii "END:REG\r\n$"

msg_begin_drvsel: .ascii "BEGIN:DRVSEL\r\n$"
msg_drvsel_hdr:
    .ascii "  0x64C drive/head write read-back (io-audit F3): re-write the as-found\r\n"
    .ascii "  byte, then read ERROR/STATUS back, to see whether the write clears a\r\n"
    .ascii "  pending ERR bit at idle.\r\n$"
msg_drvsel_64c:  .ascii "  064C as-found = $"
msg_drvsel_err:  .ascii "  0642 ERROR as-found -> after = $"
msg_drvsel_st:   .ascii "  064E STATUS as-found -> after = $"
msg_drvsel_arrow: .ascii " -> $"
msg_drvsel_restore: .ascii "  064C restored = $"
msg_end_drvsel:  .ascii "END:DRVSEL\r\n$"

msg_begin_time: .ascii "BEGIN:TIME\r\n$"
msg_time_hdr:
    .ascii "  I/O access time, TM_N=1024 back-to-back accesses per class in a cli window.\r\n"
    .ascii "  pit is the mode-3 oscillator counts (byte order measured); artic is the 005C/005F\r\n"
    .ascii "  counter delta for diagnosis. base is the interleaved control measured BESIDE the\r\n"
    .ascii "  class, so (pit-base)/(WAIT5F pit-base) is the class's ratio to the machine's own\r\n"
    .ascii "  0x5F 600 ns wait = 30 clk_sys. That ratio x30 is the value the core's class table\r\n"
    .ascii "  for this port should carry (the IDE data port is currently 42, the old value 30).\r\n$"
msg_time_div:   .ascii "  PIT channel-0 measured divisor = $"
msg_time_cols:  .ascii "  class    port mode pit  base artic\r\n$"
msg_end_time:   .ascii "END:TIME\r\n$"
msg_tm_port:    .ascii " port=$"
msg_tm_mode:    .ascii " mode=$"
msg_tm_pit:     .ascii " pit=$"
msg_tm_base:    .ascii " base=$"
msg_tm_artic:   .ascii " artic=$"

msg_begin_ident: .ascii "BEGIN:IDENTIFY\r\n$"
msg_ident_st:   .ascii "  IDENTIFY status before/after = $"
msg_ident_wait: .ascii " wait_ok= $"
msg_geom:       .ascii "  IDKEY $"
msg_idw_hdr:    .ascii "  IDW <word index> <word value>, one per line:\r\n$"
msg_idw:        .ascii "  IDW $"
msg_end_ident:  .ascii "END:IDENTIFY\r\n$"

msg_begin_recal: .ascii "BEGIN:RECAL\r\n$"
msg_recal_st:   .ascii "  RECALIBRATE 0x10 status before/after = $"
msg_recal_total: .ascii " polls = $"
msg_recal_seq_hdr:
    .ascii "  status transitions (poll count, raw byte, decoded bits):\r\n$"
msg_recal_seq:  .ascii "    RECAL poll $"
msg_end_recal:  .ascii "END:RECAL\r\n$"

msg_begin_diag: .ascii "BEGIN:DIAG\r\n$"
msg_diag_hdr:   .ascii "  DIAG status before = $"
msg_diag_st90:  .ascii " ; after 0x90 status = $"
msg_diag_err90: .ascii " ; after 0x90 ERROR(0642) = $"
msg_diag_odd:   .ascii " ; odd partners 0641/0643 = $"
msg_diag_st08:  .ascii "  after 0x08 status = $"
msg_diag_err08: .ascii " ; after 0x08 ERROR(0642) = $"
msg_end_diag:   .ascii "END:DIAG\r\n$"

msg_begin_irq:  .ascii "BEGIN:IRQ\r\n$"
msg_irq_vec:    .ascii "  vector 0x11 (IRQ9) as found = $"
msg_irq_found:  .ascii "  PIC as found m_imr s_imr m_irr m_isr s_irr s_isr = $"
msg_irq_during: .ascii "  during IDENTIFY s_irr s_isr m_irr m_isr = $"
msg_irq_stat:   .ascii "  ISR status = $"
msg_irq_stat2:  .ascii " count = $"
msg_irq_stat3:  .ascii " pre/final status = $"
msg_end_irq:
    .ascii "END:IRQ\r\n"
    .ascii "  note: slave bit1 is IRQ9 (master cascade bit7); IRQ9 vector is 0x11.\r\n"
    .ascii "  count>0 with s_isr bit1 set = the drive asserts IRQ9 and it reached the CPU.\r\n$"

msg_begin_restore: .ascii "BEGIN:RESTORE\r\n$"
msg_restore_432: .ascii "  0432 was $"
msg_restore_arrow: .ascii " -> now $"
msg_end_restore: .ascii "END:RESTORE\r\n$"

msg_bit_bsy:    .ascii " BSY=$"
msg_bit_drdy:   .ascii " DRDY=$"
msg_bit_dsc:    .ascii " DSC=$"
msg_bit_drq:    .ascii " DRQ=$"
msg_bit_err:    .ascii " ERR=$"

/* ==================================================================
 * Variables
 * ================================================================== */
bank_save:      .byte 0
bank_rb01:      .byte 0
bank_rb80:      .byte 0
bank_st01:      .byte 0
bank_st80:      .byte 0
bank_st81:      .byte 0
bank_after:     .byte 0

drvsel_save:    .byte 0
drvsel_err0:    .byte 0
drvsel_err1:    .byte 0
drvsel_st0:     .byte 0
drvsel_st1:     .byte 0

imr_s_save:     .byte 0
imr_m_save:     .byte 0
imr_m_found:    .byte 0
imr_s_found:    .byte 0
irr_m_found:    .byte 0
isr_m_found:    .byte 0
irr_s_found:    .byte 0
isr_s_found:    .byte 0

irq_slave_irr:  .byte 0
irq_slave_irr2: .byte 0
irq_slave_isr:  .byte 0
irq_master_irr: .byte 0
irq_master_isr: .byte 0
irq_status:     .byte 0
irq_pre:        .byte 0
irq_final:      .byte 0
vec_off:        .word 0
vec_seg:        .word 0
irq_count:      .word 0
irq_guard:      .word 0

ident_st0:      .byte 0
ident_st1:      .byte 0
ident_cf:       .byte 0

recal_st0:      .byte 0
recal_st1:      .byte 0
recal_prev:     .byte 0
recal_nseq:     .word 0
recal_cnt:      .word 0
recal_st:       .space RECAL_MAX
recal_n:        .space RECAL_MAX * 2

diag_st0:       .byte 0
diag_st90:      .byte 0
diag_err90:     .byte 0
diag_odd641:    .byte 0
diag_odd643:    .byte 0
diag_st08:      .byte 0
diag_err08:     .byte 0

tm_port:        .word 0
tm_kind:        .byte 0
tm_a0:          .long 0
tm_a1:          .long 0
tm_ad:          .long 0
tm_p0:          .word 0
tm_p1:          .word 0
tm_pd:          .long 0
tm_base_pd:     .long 0
tm_div:         .word 0
tm_dimax:       .word 0
tm_guard:       .word 0

pit_cal_ok:     .byte 0
pit_swap:       .byte 0
pit_b1:         .byte 0
pit_b2:         .byte 0
pit_pb1:        .byte 0
pit_pb2:        .byte 0
pit_d1:         .word 0
pit_d2:         .word 0

id_buf:         .space 512
irq_drain:      .space 512
