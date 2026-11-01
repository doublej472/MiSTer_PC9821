/* ioprobe.s - a real-machine PC-9821 I/O wait-state probe for EVERY port class.
 *
 * WHY. The core prices one I/O access in src/pc9821/core/pc9821_iobus.sv's
 * io_access_cycles() with a small class table: the 0x5F wait port 81 clk_sys, the
 * text GDC (0x60/0x62) 23, the graphics GDC (0xA0/0xA2) 34, the EGC block
 * (0x4A0-0x4AF, 0x6A, 0x7C, 0xA6) 20, the IDE PIO data port (0x640/0x641) 42, and
 * EVERY other port 42. That table is now known to be wrong somewhere: the fresh
 * IDE probe (tools/hwprobe/ideprobe/ideprobe.s /TIME) measured the IDE data port at 8.5
 * clk_sys and the task file at ~14.8 against its own 0x5F row, while the class
 * table says 42. The earlier class ladder went through the PIT
 * byte-order bug and the dead-RTC OPNA-Timer-B workaround, so it is only half
 * trusted. This probe re-measures EVERY port class with the self-calibrating
 * method the fixed IDE probe uses, so the table can be corrected.
 *
 * METHOD (identical to ideprobe.s /TIME, which is the fixed self-calibrating form):
 *   - For each port, TM_N=1024 back-to-back accesses in a cli window.
 *   - Immediately before each port row, the SAME loop with the bus access replaced
 *     by a register move: the interleaved BASE control. A class's excess over its
 *     control is pit - base, and the run's own time base cancels in the ratio
 *     (pit-base) / (WAIT5F pit-base).
 *   - The 0x005F write row is the machine's documented 600 ns = 30 clk_sys I/O-wait
 *     port, so the class's clk_sys = 30 * (pit-base) / (WAIT5F pit-base). No
 *     absolute time base is assumed anywhere; the PIT divisor is MEASURED and
 *     printed, not assumed (the IDE probe's run reads 0xCEF3, not 0x6000).
 *   - The count comes from the PIT channel-0 counter through its latch command
 *     (0x0077 <- 0x00, 0x0071 x2), with the byte order MEASURED per run (pit_cal)
 *     and printed as RAW counts (16-bit mod 65536, NO halving: a raster check on the
 *     machine found the machine counts once per oscillator clock, 8 raw counts per
 *     ARTIC tick).  1 count = 1/2.4576 MHz = 406.9 ns and 1 ARTIC tick = 1/307200
 *     Hz = 3255.2 ns, so BOTH columns give absolute nanoseconds with no run-local
 *     scale at all; where they disagree (a torn or wrapped PIT window) the decoder
 *     flags the row and the ARTIC column serves.  The divisor (tm_div_probe) feeds
 *     only the one-reload wrap correction and is coherent-pair filtered - the
 *     absolute latch word tears and is never trusted raw.
 *   - The free-running ARTIC counter (0x005C low word / 0x005F high byte) is read
 *     at both ends of the same window as the independent cross-check.
 *
 * EVERY PORT CLASS the core's class table names, plus one representative of every
 * device the firmware talks to, is in io_tab below: the 0x5F wait / ARTIC bytes,
 * the master+slave PIC, the PIT, the calendar, the keyboard, both GDCs, the EGC
 * named ports and the whole 0x4A0-0x4AE register file, the PC-9801-86 OPNA pair
 * (0x188/0x18A) and its extension bank, 0xA460 and the 86-PCM block, the whole
 * 0x430/0x640-0x64E IDE task file and the 0x740-0x74E second channel, the bus
 * mouse and the printer, the DMA read ports, the PC-9801-118 game port, and the
 * chipset straps (0x43B/0x43D/0x43F/0x461/0x463/0x530/0x531/0x534/0x53D/0x63C-0x63F
 * /0x98D7/0x9892/0x9894) and the firmware-only decoded ports.
 *
 * THE FDC'S TWO PORT WINDOWS (the 2DD-bank round). The one uPD765 is reached at
 * 0x90/0x92/0x94 (the 2HD interface) or at 0xC8/0xCA/0xCC (the 2DD one), and the
 * 0x00BE strap's bit 0 selects which - NP2kai binds the same handler table at both
 * with a gate on that bit, qemu-pc98 and MAME alias the two windows, and no capture
 * in docs/probes/ reads those ports at all (PORTS.TXT skips 0x5B-0xEF). So the run
 * times each window TWICE, once selected and once not, and each read row prints the
 * byte it answered (`val=HH`): the UNSELECTED window's answer (0xFF as open bus, or
 * an alias) and the control-port byte at 0x94 vs 0xCC are the two behaviours the
 * design study could not settle from the references, and equal timing classes on
 * 0x90 and 0xC8 would independently confirm the one register file they agree on.
 * The strap is saved in BEGIN:FDCSTRAP and put back at the end of the run.
 *
 * OUTPUT. One BEGIN:IO<port><mode> / END:IO<port><mode> section per measured access,
 * so a port that hangs the machine is the one whose BEGIN: has no END:. Inside,
 * one labelled row (the exact row shape the decoder parses):
 *
 *     WAIT5F  port=005F mode=W pit=03F2 base=00C3 artic=0001A2B3 bartic=00004567
 *     FDC90   port=0090 mode=R pit=... base=... artic=... bartic=... val=80
 *
 * pit/base are the mode-3 oscillator counts for the port and its interleaved
 * control; artic/bartic are the ARTIC-counter deltas for the same two windows.
 * `val=` is the byte ONE extra read returned after the timed window, and it is
 * printed for READ rows only (reading back a port the probe just wrote is a
 * different access class, and on a write-only port a different question). The
 * field is optional and trailing, so the decoder and every existing capture are
 * unaffected by it.
 * tools/hwprobe/ioprobe/ioprobe_decode.py turns pit/base into clk_sys and ns against the
 * WAIT5F row. Sections are bracketed so the capture before a hang stays valid.
 *
 * SAFETY.
 *   - Reads are the safe direction and are what the firmware's poll loops do; every
 *     port below is timed in the read direction.
 *   - A curated subset is also timed in the WRITE direction: 0x005F (the wait port,
 *     write-only), the EGC named ports and the EGC file, and the -86 sound pair.
 *     Every write is the CONSTANT 0x00: the EGC/GRCG/mode-off state and the -86
 *     register-0/data-0 select, the same bytes egcport.com leaves. 0x0077 <- 0x00
 *     is the PIT latch-channel-0 command, which is safe and repeated anyway. NO
 *     write is made to the PIC, the PIT control beyond the latch, the calendar, the
 *     GDC command registers, or the ATA task file.
 *   - 0x0041 (keyboard data) is read: with nothing typed it returns the idle byte;
 *     it does not call DOS inside the cli window.
 *   - 0x00BE (the FDC interface/media strap) is READ into fdc_strap_sv at start-up
 *     and WRITTEN back at the end of the run; the FDC rows in between read-modify-
 *     write it to select a port window and touch bit 0 only, which is the firmware's
 *     own idiom (BANK7 0x741B). Nothing else writes it, and the capture prints the
 *     saved and the restored value so the restore is verifiable from the log.
 *   - DOS is only called (puts/putc) OUTSIDE the cli windows; the measurements
 *     buffer into variables first. No command is issued to any device.
 *
 * Built by build_ioprobe.sh: GNU as --32, linked at 0x100, .text only.
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ TM_N, 1024                 /* timed accesses per row */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es

    mov     dx, offset msg_banner
    call    puts

    /* SETUP: measure the PIT channel-0 divisor once, before any row. Never assume
     * 0x6000 - the IDE probe's run reads 0xCEF3. The ratio method does not need the
     * value, but the wrap correction in tm_run does, and printing it makes the run
     * self-documenting. */
    mov     dx, offset msg_begin_setup
    call    puts
    cli
    call    tm_div_probe
    sti
    mov     dx, offset msg_time_div
    call    puts
    mov     ax, [tm_div]
    call    puthex16
    mov     dx, offset msg_time_div_n
    call    puts
    mov     ax, [tm_daccept]
    call    puthex16
    mov     dl, '/'
    call    putc
    mov     ax, [tm_dtry]
    call    puthex16
    call    putnl
    mov     dx, offset msg_end_setup
    call    puts

    /* The FDC's interface strap, SAVED before any row touches it: the 0x00BE rows
     * below set bit 0 to select a port window and the run puts this value back at
     * the end (only bit 0 is ever written, so the media strap in bit 1 and every
     * other bit keep whatever the machine booted with). */
    mov     dx, 0x00BE
    in      al, dx
    mov     [fdc_strap_sv], al
    mov     dx, offset msg_begin_strap
    call    puts
    mov     al, [fdc_strap_sv]
    call    puthex8
    call    putnl

    call    io_loop

    /* restore it, and say so in the capture */
    mov     al, [fdc_strap_sv]
    mov     dx, 0x00BE
    out     dx, al
    mov     dx, offset msg_end_strap
    call    puts
    mov     al, [fdc_strap_sv]
    call    puthex8
    call    putnl

    mov     dx, offset msg_done
    call    puts
    mov     ax, 0x4C00
    int     0x21
    hlt

/* ==================================================================
 * the port loop
 * ================================================================== */
/* io_loop: walk io_tab {port word, kind byte, pad, label word}; 0xFFFF ends it. */
io_loop:
    push    si
    mov     si, offset io_tab
iol_next:
    mov     ax, [si]
    cmp     ax, 0xFFFF
    je      iol_done
    call    tm_meas
    add     si, 6
    jmp     iol_next
iol_done:
    pop     si
    ret

/* tm_meas: DS:SI -> entry. Brackets the measurement with BEGIN:/END:, times the
 * interleaved base control and the port, then prints the row. SI is preserved
 * across tm_run, so the entry stays readable. */
tm_meas:
    push    ax
    push    dx
    push    si
    mov     ax, [si]
    mov     [tm_port], ax

    /* the entry's strap byte: 0 = leave 0x00BE alone, 1 = bit 0 set (the 2HD
     * window), 2 = bit 0 clear (the 2DD window). Applied BEFORE the section so a
     * hang would still be attributed to the row it belongs to. */
    mov     al, [si+3]
    test    al, al
    jz      tm_nostrap
    call    strap_set
tm_nostrap:

    mov     dx, offset msg_begin_io
    call    puts
    mov     ax, [tm_port]
    call    puthex16
    mov     al, [si+2]
    call    pr_mode
    call    putnl

    /* the interleaved control: the same loop with a register move for the access */
    mov     byte ptr [tm_kind], 0
    call    tm_run
    mov     eax, [tm_pd]
    mov     [tm_base_pd], eax
    mov     eax, [tm_ad]
    mov     [tm_base_ad], eax

    /* the port access itself */
    mov     al, [si+2]
    mov     [tm_kind], al
    call    tm_run

    /* one fixed row: <label> port=PPPP mode=X pit=HHHH base=HHHH artic=HHHHHHHH bartic=HHHHHHHH */
    mov     dx, [si+4]
    call    puts
    mov     dx, offset msg_r_port
    call    puts
    mov     ax, [tm_port]
    call    puthex16
    mov     dx, offset msg_r_mode
    call    puts
    mov     al, [si+2]
    call    pr_mode
    mov     dx, offset msg_r_pit
    call    puts
    mov     ax, word ptr [tm_pd]
    call    puthex16
    mov     dx, offset msg_r_base
    call    puts
    mov     ax, word ptr [tm_base_pd]
    call    puthex16
    mov     dx, offset msg_r_artic
    call    puts
    mov     eax, [tm_ad]
    call    puthex32
    mov     dx, offset msg_r_bartic
    call    puts
    mov     eax, [tm_base_ad]
    call    puthex32
    /* THE BYTE THE PORT ANSWERED, for read rows: one more read after the timed
     * window. This is what makes the FDC rows below settle their two open
     * questions in the same capture as their timing - the unselected window's
     * answer (0xFF vs an alias) and the control-port byte. A write row prints no
     * val, because reading back the port the probe just wrote is a different
     * access class (and on a write-only port, a different question). */
    cmp     byte ptr [si+2], 1
    jne     tm_noval
    mov     dx, offset msg_r_val
    call    puts
    mov     dx, [tm_port]
    in      al, dx
    call    puthex8
tm_noval:
    call    putnl

    mov     dx, offset msg_end_io
    call    puts
    mov     ax, [tm_port]
    call    puthex16
    mov     al, [si+2]
    call    pr_mode
    call    putnl
    pop     si
    pop     dx
    pop     ax
    ret

/* tm_run: time one window. [tm_kind] = 0 base (a register move), 1 read (in al,dx),
 * 2 write (out dx,al, AL held at 0 so the write is the safe constant). [tm_port]
 * is the port. Leaves the ARTIC delta in [tm_ad] and the PIT oscillator counts in
 * [tm_pd]. The inner loop has the same instruction count for the read and the write
 * arms (eight) and a shorter base arm (five), so the read arm and the write arm
 * carry the same loop overhead and the base cancels it: a WAIT5F write anchor and a
 * read class stay comparable. The kind is hoisted to BL so AL stays free for the
 * constant 0x00 the write arm emits. */
tm_run:
    push    ax
    push    bx
    push    cx
    push    dx
    push    di
    mov     dx, [tm_port]
    mov     bl, [tm_kind]
    xor     al, al
    cli
    call    artic_read
    mov     [tm_a0], eax
    call    pit_read
    mov     [tm_p0], ax
    mov     cx, TM_N
tmr_loop:
    test    bl, bl
    jz      tmr_base
    cmp     bl, 2
    je      tmr_out
    in      al, dx
    jmp     tmr_next
tmr_out:
    out     dx, al
    jmp     tmr_next
tmr_base:
    mov     al, 0
tmr_next:
    dec     cx
    jnz     tmr_loop
    call    pit_read
    mov     [tm_p1], ax
    call    artic_read
    mov     [tm_a1], eax
    sti
    mov     eax, [tm_a1]
    sub     eax, [tm_a0]
    mov     [tm_ad], eax
    /* Raw count distance, 16-bit mod 65536, NO halving: a raster check on the machine
     * found the machine's channel 0 counts once per oscillator clock (8 raw
     * counts per ARTIC tick, three windows, 0.5%), so the old mode-3 /2 was 2x
     * wrong. One negative distance means the counter reloaded inside the
     * window; one divisor (only when tm_div_probe measured one coherently)
     * recovers it. A torn or doubly-wrapped window stays wrong and is caught
     * by the decoder's 8:1 PIT:ARTIC check, which is why both columns print. */
    movzx   eax, word ptr [tm_p0]
    movzx   ecx, word ptr [tm_p1]
    sub     eax, ecx
    jns     tmr_done
    cmp     byte ptr [tm_divok], 0
    je      tmr_done
    movzx   ecx, word ptr [tm_div]
    add     eax, ecx
tmr_done:
    mov     [tm_pd], eax
    pop     di
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* tm_div_probe: the PIT divisor, for the one-reload wrap correction only -
 * the absolute latch word is known to tear (scans have
 * returned 0xFFFA/0xD12E-class words that cannot be a count of the BIOS's
 * 0x6000 divisor), so each candidate is sampled TWICE back to back and only a
 * coherent pair (words within 64 counts) is accepted.  The window is 30 ms of
 * ARTIC ticks (9216), which covers any possible 16-bit period, so the largest
 * accepted word is the divisor or one step below it.  [tm_divok] is set only
 * when at least half the attempts were coherent, so a still-tearing run does
 * not corrupt the wrap correction (its rows are caught by the 8:1 check). */
tm_div_probe:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     word ptr [tm_dimax], 0
    mov     word ptr [tm_dtry], 0
    mov     word ptr [tm_daccept], 0
    mov     byte ptr [tm_divok], 0
    call    artic_read
    mov     [tm_a0], eax
    mov     word ptr [tm_guard], 0x4000
tdp_loop:
    call    pit_read
    mov     bx, ax
    call    pit_read
    mov     cx, ax
    inc     word ptr [tm_dtry]
    mov     ax, bx
    sub     ax, cx
    jns     tdp_d1
    neg     ax
tdp_d1:
    cmp     ax, 64
    ja      tdp_next
    inc     word ptr [tm_daccept]
    cmp     bx, [tm_dimax]
    jbe     tdp_next
    mov     [tm_dimax], bx
tdp_next:
    call    artic_read
    sub     eax, [tm_a0]
    cmp     eax, 9216
    jae     tdp_done
    dec     word ptr [tm_guard]
    jnz     tdp_loop
tdp_done:
    mov     ax, [tm_dtry]
    shr     ax, 1
    cmp     ax, [tm_daccept]
    ja      tdp_out
    cmp     word ptr [tm_dimax], 0
    je      tdp_out
    mov     byte ptr [tm_divok], 1
tdp_out:
    mov     ax, [tm_dimax]
    mov     [tm_div], ax
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ==================================================================
 * the two counters (copied from ideprobe.s, which carries the PIT fix)
 * ================================================================== */
/* artic_read: EAX = the free-running counter at 005C (bits 15:0) / 005F (bits
 * 23:16). 005D and 005E both mirror cnt[15:8]; 005F is cnt[23:16]. The low word
 * wraps every 213 ms, so it is read again after the high byte and a wrap bumps the
 * high byte. Read-only. */
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

/* pit_bytes: latch channel 0, then the two bytes 0071 returns into pit_b1/pit_b2. */
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

/* pit_cal: set pit_swap by watching which of the two bytes 0071 returns moves. Mode
 * 3 decrements the count every oscillator clock, so over 32 paired reads the LSB
 * falls on almost every sample and the MSB on almost none; the byte that falls more
 * often is the LSB. The latch command does not restore the read pointer on this
 * machine, so the order is measured, not assumed. */
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
 * output helpers
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

/* strap_set: AL = 1 -> 0x00BE bit 0 SET (the 2HD window is selected), AL = 2 ->
 * bit 0 CLEAR (the 2DD window at 0xC8-0xCC). Read-modify-write on the LIVE value,
 * which is the firmware's own idiom (BANK7 0x741B: `in al,0xBE / and al,0x1 /
 * or al,0x2 / out 0xBE,al`), so nothing but bit 0 can move. */
strap_set:
    push    ax
    push    dx
    mov     ah, al
    mov     dx, 0x00BE
    in      al, dx
    cmp     ah, 2
    je      sts_clr
    or      al, 0x01
    jmp     sts_wr
sts_clr:
    and     al, 0xFE
sts_wr:
    out     dx, al
    pop     dx
    pop     ax
    ret

pr_mode:                        /* AL = kind -> 'R' or 'W' */
    push    ax
    cmp     al, 2
    jne     prm_r
    mov     dl, 'W'
    jmp     prm_out
prm_r:
    mov     dl, 'R'
prm_out:
    call    putc
    pop     ax
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

/* ==================================================================
 * Data
 * ================================================================== */
/* io_tab: one entry per measured access: {port word, kind byte, pad, label word}.
 * kind 1 = read (in al,dx), 2 = write (out dx,al with the constant 0x00). 0xFFFF
 * ends the table. Ports are grouped by device so the capture reads in order. */
io_tab:
    /* the I/O-wait anchor and the ARTIC counter bytes */
    .word 0x005F
    .byte 2, 0
    .word lbl_wait5f
    .word 0x005F
    .byte 1, 0
    .word lbl_artichi
    .word 0x005C
    .byte 1, 0
    .word lbl_articlo
    /* master + slave 8259 PIC (reads only: a write would move the mask) */
    .word 0x0000
    .byte 1, 0
    .word lbl_picm
    .word 0x0002
    .byte 1, 0
    .word lbl_picmimr
    .word 0x0008
    .byte 1, 0
    .word lbl_pics
    .word 0x000A
    .byte 1, 0
    .word lbl_picsimr
    /* PIT: channel-0 data, channel-1 data, the control port (write 0 = latch ch0) */
    .word 0x0071
    .byte 1, 0
    .word lbl_pitd0
    .word 0x0073
    .byte 1, 0
    .word lbl_pitd1
    .word 0x0077
    .byte 2, 0
    .word lbl_pitctl
    /* calendar command/mode latches */
    .word 0x0020
    .byte 1, 0
    .word lbl_calcmd
    .word 0x0022
    .byte 1, 0
    .word lbl_calmode
    /* keyboard uPD8251A data/status */
    .word 0x0041
    .byte 1, 0
    .word lbl_kbddata
    .word 0x0043
    .byte 1, 0
    .word lbl_kbdstat
    /* text GDC status/data */
    .word 0x0060
    .byte 1, 0
    .word lbl_gdc1sts
    .word 0x0062
    .byte 1, 0
    .word lbl_gdc1dat
    /* graphics GDC status/data */
    .word 0x00A0
    .byte 1, 0
    .word lbl_gdc2sts
    .word 0x00A2
    .byte 1, 0
    .word lbl_gdc2dat
    /* EGC mode / GRCG mode / access-page, read and write (write 0 = off) */
    .word 0x006A
    .byte 1, 0
    .word lbl_egcmode
    .word 0x006A
    .byte 2, 0
    .word lbl_egcmodew
    .word 0x007C
    .byte 1, 0
    .word lbl_grcg
    .word 0x007C
    .byte 2, 0
    .word lbl_grcgw
    .word 0x00A6
    .byte 1, 0
    .word lbl_egcap
    .word 0x00A6
    .byte 2, 0
    .word lbl_egcapw
    /* the EGC register file 0x04A0-0x04AE: the even lanes and one odd lane to show
     * the split, plus one write */
    .word 0x04A0
    .byte 1, 0
    .word lbl_egc40
    .word 0x04A1
    .byte 1, 0
    .word lbl_egc41
    .word 0x04A2
    .byte 1, 0
    .word lbl_egc42
    .word 0x04A3
    .byte 1, 0
    .word lbl_egc43
    .word 0x04A4
    .byte 1, 0
    .word lbl_egc44
    .word 0x04A5
    .byte 1, 0
    .word lbl_egc45
    .word 0x04A6
    .byte 1, 0
    .word lbl_egc46
    .word 0x04A7
    .byte 1, 0
    .word lbl_egc47
    .word 0x04A8
    .byte 1, 0
    .word lbl_egc48
    .word 0x04A9
    .byte 1, 0
    .word lbl_egc49
    .word 0x04AA
    .byte 1, 0
    .word lbl_egc4a
    .word 0x04AB
    .byte 1, 0
    .word lbl_egc4b
    .word 0x04AC
    .byte 1, 0
    .word lbl_egc4c
    .word 0x04AD
    .byte 1, 0
    .word lbl_egc4d
    .word 0x04AE
    .byte 1, 0
    .word lbl_egc4e
    .word 0x04A0
    .byte 2, 0
    .word lbl_egc40w
    /* the PC-9801-86 OPNA register-select/data pair and its extension bank */
    .word 0x0188
    .byte 1, 0
    .word lbl_snd188
    .word 0x018A
    .byte 1, 0
    .word lbl_snd18a
    .word 0x018C
    .byte 1, 0
    .word lbl_snd18c
    .word 0x018E
    .byte 1, 0
    .word lbl_snd18e
    .word 0x0188
    .byte 2, 0
    .word lbl_snd188w
    .word 0x018A
    .byte 2, 0
    .word lbl_snd18aw
    /* the -86's card-level extend/ID register and the 86-PCM block */
    .word 0xA460
    .byte 1, 0
    .word lbl_snda460
    .word 0xA462
    .byte 1, 0
    .word lbl_pcm86
    /* the IDE interface registers and the whole task file (read only) */
    .word 0x0430
    .byte 1, 0
    .word lbl_ide430
    .word 0x0432
    .byte 1, 0
    .word lbl_ide432
    .word 0x0433
    .byte 1, 0
    .word lbl_ide433
    .word 0x0435
    .byte 1, 0
    .word lbl_ide435
    .word 0x0640
    .byte 1, 0
    .word lbl_ided0
    .word 0x0641
    .byte 1, 0
    .word lbl_ided1
    .word 0x0642
    .byte 1, 0
    .word lbl_ideerr
    .word 0x0644
    .byte 1, 0
    .word lbl_idecnt
    .word 0x0646
    .byte 1, 0
    .word lbl_idesec
    .word 0x0648
    .byte 1, 0
    .word lbl_idecyl
    .word 0x064A
    .byte 1, 0
    .word lbl_idecyh
    .word 0x064C
    .byte 1, 0
    .word lbl_idedh
    .word 0x064E
    .byte 1, 0
    .word lbl_idestat
    .word 0x1E8E
    .byte 1, 0
    .word lbl_ide1e8e
    /* the second ATA channel (0x740-0x74E) */
    .word 0x0740
    .byte 1, 0
    .word lbl_ata740
    .word 0x0742
    .byte 1, 0
    .word lbl_ata742
    .word 0x0744
    .byte 1, 0
    .word lbl_ata744
    .word 0x0746
    .byte 1, 0
    .word lbl_ata746
    .word 0x0748
    .byte 1, 0
    .word lbl_ata748
    .word 0x074A
    .byte 1, 0
    .word lbl_ata74a
    .word 0x074C
    .byte 1, 0
    .word lbl_ata74c
    .word 0x074E
    .byte 1, 0
    .word lbl_ata74e
    /* the PC-9801-118 game port (0x1480-0x1487 answer on all eight) */
    .word 0x1480
    .byte 1, 0
    .word lbl_joy1480
    .word 0x1481
    .byte 1, 0
    .word lbl_joy1481
    /* the uPD71071 DMA controller read ports */
    .word 0x0011
    .byte 1, 0
    .word lbl_dma11
    .word 0x001B
    .byte 1, 0
    .word lbl_dma1b
    .word 0x0021
    .byte 1, 0
    .word lbl_dma21
    .word 0x0023
    .byte 1, 0
    .word lbl_dma23
    .word 0x0025
    .byte 1, 0
    .word lbl_dma25
    .word 0x0027
    .byte 1, 0
    .word lbl_dma27
    .word 0x0029
    .byte 1, 0
    .word lbl_dma29
    /* printer data and the FDC/uPD765 registers. THE SAME CONTROLLER IS BEHIND
     * TWO PORT WINDOWS: 0x90/0x92/0x94 is the 2HD interface and 0xC8/0xCA/0xCC the
     * 2DD one, with the 0x00BE strap (bit 0) deciding which answers (NP2kai binds
     * the same fdco90/fdci90 handler table at both, gated by `((port >> 4) ^
     * fdc.chgreg) & 1`, io/fdc.c:975/996/1040/1050/1068; the machine's own
     * firmware branches on the same bit before every FDC access and programs DMA
     * channel 2 or 3 from it). The strap byte in each entry SELECTS the window for
     * that row, and every read row prints the byte it got, so ONE capture settles
     * the two questions the design study could not: what the UNSELECTED window
     * answers (NP2kai returns 0xFF and drops writes; qemu-pc98 and MAME alias) and
     * the control-port byte at 0x94 vs 0xCC (NP2kai's fdc_i94 gives 0x74 at 0xCC
     * and 0x44 at 0x94; qemu's FDSTAT_DMA is set at 0x94 and not at 0xcc). The
     * unselected rows are cheap: an open bus is a faster access than a register.
     * Equal timing classes on 0x90 and 0xC8 would independently confirm the one
     * register file the four references agree on. */
    .word 0x0040
    .byte 1, 0
    .word lbl_prn40
    .word 0x00BE
    .byte 1, 0
    .word lbl_fdcbe
    /* the 2HD window, SELECTED (strap bit 0 set - the value the machine boots with) */
    .word 0x0090
    .byte 1, 1
    .word lbl_fdc90
    .word 0x0092
    .byte 1, 1
    .word lbl_fdc92
    .word 0x0094
    .byte 1, 1
    .word lbl_fdc94
    /* the 2DD window while the 2HD one is selected: UNSELECTED, so this is the gate */
    .word 0x00C8
    .byte 1, 1
    .word lbl_fdc2hc8
    .word 0x00CA
    .byte 1, 1
    .word lbl_fdc2hca
    .word 0x00CC
    .byte 1, 1
    .word lbl_fdc2hcc
    /* the 2DD window, SELECTED: the same controller through the other door */
    .word 0x00C8
    .byte 1, 2
    .word lbl_fdc2dc8
    .word 0x00CA
    .byte 1, 2
    .word lbl_fdc2dca
    .word 0x00CC
    .byte 1, 2
    .word lbl_fdc2dcc
    /* and the 2HD window while the 2DD one is selected: the gate, mirrored */
    .word 0x0090
    .byte 1, 2
    .word lbl_fdc2d90
    .word 0x0092
    .byte 1, 2
    .word lbl_fdc2d92
    .word 0x0094
    .byte 1, 2
    .word lbl_fdc2d94
    /* the chipset straps and the firmware-only decoded ports */
    .word 0x043B
    .byte 1, 0
    .word lbl_sys43b
    .word 0x043D
    .byte 1, 0
    .word lbl_sys43d
    .word 0x043F
    .byte 1, 0
    .word lbl_sys43f
    .word 0x0461
    .byte 1, 0
    .word lbl_sys461
    .word 0x0463
    .byte 1, 0
    .word lbl_sys463
    .word 0x0530
    .byte 1, 0
    .word lbl_msw530
    .word 0x0531
    .byte 1, 0
    .word lbl_msw531
    .word 0x0534
    .byte 1, 0
    .word lbl_sys534
    .word 0x053D
    .byte 1, 0
    .word lbl_sys53d
    .word 0x063C
    .byte 1, 0
    .word lbl_sys63c
    .word 0x063D
    .byte 1, 0
    .word lbl_sys63d
    .word 0x063E
    .byte 1, 0
    .word lbl_sys63e
    .word 0x063F
    .byte 1, 0
    .word lbl_sys63f
    .word 0x0EE0
    .byte 1, 0
    .word lbl_openbus
    .word 0x09A0
    .byte 1, 0
    .word lbl_pegc9a0
    .word 0x98D7
    .byte 1, 0
    .word lbl_sys98d7
    .word 0x9892
    .byte 1, 0
    .word lbl_sys9892
    .word 0x9894
    .byte 1, 0
    .word lbl_sys9894
    .word 0x18F0
    .byte 1, 0
    .word lbl_cfg18f0
    .word 0x18F2
    .byte 1, 0
    .word lbl_cfg18f2
    .word 0x0FAA
    .byte 1, 0
    .word lbl_accfaa
    .word 0x7FD9
    .byte 1, 0
    .word lbl_mouse7fd9
    .word 0xBFDB
    .byte 1, 0
    .word lbl_mousebfdb
    .word 0xFFFF

/* Row labels are '$'-terminated like every other printed string, NOT .asciz: the
 * only string printer is puts (DOS AH=09), which runs on to the next '$'. A
 * NUL-terminated label makes puts print through the rest of this table and into
 * the banner, which garbles every row (the bug ideprobe.s's first capture hit). */
lbl_wait5f:     .ascii "WAIT5F  $"
lbl_artichi:    .ascii "ARTICHI $"
lbl_articlo:    .ascii "ARTICLO $"
lbl_picm:       .ascii "PICM    $"
lbl_picmimr:    .ascii "PICMIMR $"
lbl_pics:       .ascii "PICS    $"
lbl_picsimr:    .ascii "PICSIMR $"
lbl_pitd0:      .ascii "PITD0   $"
lbl_pitd1:      .ascii "PITD1   $"
lbl_pitctl:     .ascii "PITCTL  $"
lbl_calcmd:     .ascii "CALCMD  $"
lbl_calmode:    .ascii "CALMODE $"
lbl_kbddata:    .ascii "KBDDATA $"
lbl_kbdstat:    .ascii "KBDSTAT $"
lbl_gdc1sts:    .ascii "GDC1STS $"
lbl_gdc1dat:    .ascii "GDC1DAT $"
lbl_gdc2sts:    .ascii "GDC2STS $"
lbl_gdc2dat:    .ascii "GDC2DAT $"
lbl_egcmode:    .ascii "EGCMODE $"
lbl_egcmodew:   .ascii "EGCMODEW$"
lbl_grcg:       .ascii "GRCG    $"
lbl_grcgw:      .ascii "GRCGW   $"
lbl_egcap:      .ascii "EGCAP   $"
lbl_egcapw:     .ascii "EGCAPW  $"
lbl_egc40:      .ascii "EGC40   $"
lbl_egc41:      .ascii "EGC41   $"
lbl_egc42:      .ascii "EGC42   $"
lbl_egc43:      .ascii "EGC43   $"
lbl_egc44:      .ascii "EGC44   $"
lbl_egc45:      .ascii "EGC45   $"
lbl_egc46:      .ascii "EGC46   $"
lbl_egc47:      .ascii "EGC47   $"
lbl_egc48:      .ascii "EGC48   $"
lbl_egc49:      .ascii "EGC49   $"
lbl_egc4a:      .ascii "EGC4A   $"
lbl_egc4b:      .ascii "EGC4B   $"
lbl_egc4c:      .ascii "EGC4C   $"
lbl_egc4d:      .ascii "EGC4D   $"
lbl_egc4e:      .ascii "EGC4E   $"
lbl_egc40w:     .ascii "EGC40W  $"
lbl_snd188:     .ascii "SND188  $"
lbl_snd18a:     .ascii "SND18A  $"
lbl_snd18c:     .ascii "SND18C  $"
lbl_snd18e:     .ascii "SND18E  $"
lbl_snd188w:    .ascii "SND188W $"
lbl_snd18aw:    .ascii "SND18AW $"
lbl_snda460:    .ascii "SNDA460 $"
lbl_pcm86:      .ascii "PCM86   $"
lbl_ide430:     .ascii "IDE430  $"
lbl_ide432:     .ascii "IDE432  $"
lbl_ide433:     .ascii "IDE433  $"
lbl_ide435:     .ascii "IDE435  $"
lbl_ided0:      .ascii "IDED0   $"
lbl_ided1:      .ascii "IDED1   $"
lbl_ideerr:     .ascii "IDEERR  $"
lbl_idecnt:     .ascii "IDECNT  $"
lbl_idesec:     .ascii "IDESEC  $"
lbl_idecyl:     .ascii "IDECYL  $"
lbl_idecyh:     .ascii "IDECYH  $"
lbl_idedh:      .ascii "IDEDH   $"
lbl_idestat:    .ascii "IDESTAT $"
lbl_ide1e8e:    .ascii "IDE1E8E $"
lbl_ata740:     .ascii "ATA740  $"
lbl_ata742:     .ascii "ATA742  $"
lbl_ata744:     .ascii "ATA744  $"
lbl_ata746:     .ascii "ATA746  $"
lbl_ata748:     .ascii "ATA748  $"
lbl_ata74a:     .ascii "ATA74A  $"
lbl_ata74c:     .ascii "ATA74C  $"
lbl_ata74e:     .ascii "ATA74E  $"
lbl_joy1480:    .ascii "JOY1480 $"
lbl_joy1481:    .ascii "JOY1481 $"
lbl_dma11:      .ascii "DMA11   $"
lbl_dma1b:      .ascii "DMA1B   $"
lbl_dma21:      .ascii "DMA21   $"
lbl_dma23:      .ascii "DMA23   $"
lbl_dma25:      .ascii "DMA25   $"
lbl_dma27:      .ascii "DMA27   $"
lbl_dma29:      .ascii "DMA29   $"
lbl_prn40:      .ascii "PRN40   $"
lbl_fdc90:      .ascii "FDC90   $"
lbl_fdc92:      .ascii "FDC92   $"
lbl_fdc94:      .ascii "FDC94   $"
lbl_fdcbe:      .ascii "FDCBE   $"
lbl_fdc2hc8:    .ascii "FDC2HC8 $"
lbl_fdc2hca:    .ascii "FDC2HCA $"
lbl_fdc2hcc:    .ascii "FDC2HCC $"
lbl_fdc2dc8:    .ascii "FDC2DC8 $"
lbl_fdc2dca:    .ascii "FDC2DCA $"
lbl_fdc2dcc:    .ascii "FDC2DCC $"
lbl_fdc2d90:    .ascii "FDC2D90 $"
lbl_fdc2d92:    .ascii "FDC2D92 $"
lbl_fdc2d94:    .ascii "FDC2D94 $"
lbl_sys43b:     .ascii "SYS43B  $"
lbl_sys43d:     .ascii "SYS43D  $"
lbl_sys43f:     .ascii "SYS43F  $"
lbl_sys461:     .ascii "SYS461  $"
lbl_sys463:     .ascii "SYS463  $"
lbl_msw530:     .ascii "MSW530  $"
lbl_msw531:     .ascii "MSW531  $"
lbl_sys534:     .ascii "SYS534  $"
lbl_sys53d:     .ascii "SYS53D  $"
lbl_sys63c:     .ascii "SYS63C  $"
lbl_sys63d:     .ascii "SYS63D  $"
lbl_sys63e:     .ascii "SYS63E  $"
lbl_sys63f:     .ascii "SYS63F  $"
lbl_openbus:    .ascii "OPENBUS $"
lbl_pegc9a0:    .ascii "PEGC9A0 $"
lbl_sys98d7:    .ascii "SYS98D7 $"
lbl_sys9892:    .ascii "SYS9892 $"
lbl_sys9894:    .ascii "SYS9894 $"
lbl_cfg18f0:    .ascii "CFG18F0 $"
lbl_cfg18f2:    .ascii "CFG18F2 $"
lbl_accfaa:     .ascii "ACCFAA  $"
lbl_mouse7fd9:  .ascii "MOUSE7FD$"
lbl_mousebfdb:  .ascii "MOUSEBFD$"

msg_banner:
    .ascii "IOPROBE - PC-9821 real-machine I/O wait-state probe (tools/hwprobe/ioprobe.s)\r\n"
    .ascii "Each row: TM_N=1024 back-to-back accesses in a cli window, timed with the PIT\r\n"
    .ascii "channel-0 counter and an interleaved control (pit-/base-), with the ARTIC counter\r\n"
    .ascii "(artic-/bartic-) as the cross-check. pit/base are RAW counts (1 count = 406.9 ns,\r\n"
    .ascii "8 per ARTIC tick, r13/215) and artic/bartic are ticks (1 = 3255.2 ns), so both\r\n"
    .ascii "give absolute ns with no run-local scale. clk_sys = 30 * (pit-base) / (WAIT5F\r\n"
    .ascii "pit-base), where 0x005F is the documented 600 ns / 30 clk_sys I/O-wait port, so\r\n"
    .ascii "the value is the ratio the core's pc9821_iobus.sv io_access_cycles should carry\r\n"
    .ascii "for the port.\r\n"
    .ascii "Reads are the safe direction; the write rows write the constant 0x00 (the EGC/\r\n"
    .ascii "GRCG/mode off state, the -86 register 0, and the PIT latch command at 0x0077).\r\n"
    .ascii "Every READ row ends with val=HH, the byte one extra read returned after the\r\n"
    .ascii "timed window (write rows print no val: reading back what was just written is a\r\n"
    .ascii "different access class). The FDC's two port windows - 0x90/0x92/0x94 for the 2HD\r\n"
    .ascii "interface, 0xC8/0xCA/0xCC for the 2DD one, selected by 0x00BE bit 0 - are each\r\n"
    .ascii "timed while selected (FDC90/FDC2DC8) and while NOT selected (FDC2HC8/FDC2D90),\r\n"
    .ascii "so one capture answers what the unselected window returns and what the control\r\n"
    .ascii "port reads at 0x94 vs 0xCC. The strap is saved in BEGIN:FDCSTRAP and put back\r\n"
    .ascii "(bit 0 only, read-modify-write) after the last row.\r\n"
    .ascii "Sections are bracketed BEGIN/END pairs named IO<port><mode>: a hang leaves\r\n"
    .ascii "a BEGIN with no END, and the capture before it is still valid.\r\n$"
msg_begin_setup: .ascii "BEGIN:SETUP\r\n$"
msg_time_div:   .ascii "  PIT channel-0 measured divisor = $"
msg_time_div_n: .ascii " coherent pairs = $"
msg_end_setup:  .ascii "END:SETUP\r\n$"
msg_begin_strap: .ascii "BEGIN:FDCSTRAP\r\n  strap saved from 0x00BE = $"
msg_end_strap:  .ascii "  strap put back to 0x00BE = $"
msg_done:       .ascii "IOPROBE DONE\r\n$"

msg_begin_io:   .ascii "BEGIN:IO$"
msg_end_io:     .ascii "END:IO$"
msg_r_port:     .ascii " port=$"
msg_r_mode:     .ascii " mode=$"
msg_r_pit:      .ascii " pit=$"
msg_r_base:     .ascii " base=$"
msg_r_artic:    .ascii " artic=$"
msg_r_bartic:   .ascii " bartic=$"
msg_r_val:      .ascii " val=$"

/* ==================================================================
 * Variables
 * ================================================================== */
fdc_strap_sv:   .byte 0          /* 0x00BE as the machine booted it, restored after io_loop */
tm_port:        .word 0
tm_kind:        .byte 0
tm_a0:          .long 0
tm_a1:          .long 0
tm_ad:          .long 0
tm_p0:          .word 0
tm_p1:          .word 0
tm_pd:          .long 0
tm_base_pd:     .long 0
tm_base_ad:     .long 0
tm_div:         .word 0
tm_dimax:       .word 0
tm_guard:       .word 0
tm_dtry:        .word 0
tm_daccept:     .word 0
tm_divok:       .byte 0

pit_cal_ok:     .byte 0
pit_swap:       .byte 0
pit_b1:         .byte 0
pit_b2:         .byte 0
pit_pb1:        .byte 0
pit_pb2:        .byte 0
pit_d1:         .word 0
pit_d2:         .word 0
