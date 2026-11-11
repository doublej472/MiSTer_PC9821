/* dmaroute.s - where a uPD71071 DMA byte lands when its address is in a memory window that is
 * not plain RAM, measured on a real PC-9821.
 *
 *   DMAROUTE [DA=xx] [/CPU] > DMAROUTE.TXT          (or RUNDMA.BAT)
 *
 * WHY. NP2kai moves every DMA byte with MEMP_WRITE8/MEMP_READ8 (mem/dmax86.c), i.e. through
 * the CPU's handler table (i386c/cpumem.c memfn0.wr8[address >> 15]), so a DMA byte goes
 * where a CPU byte at the same address goes. lane/dma-route models that for the EMS page,
 * the PEGC banks and register file and the 0x0461 window (the DMA-routing entries of
 * todo/6-memory.md); the CG window (0xA4000-0xA4FFF) is still sent to the SDRAM under it
 * there, an entry of its own in the same file. No machine has
 * been measured. This probe asks the machine, case by case.
 *
 * METHOD. The DMA source is the floppy controller: READ DATA of C0 H0 R1 of the disk in
 * drive DA/UA (default 0x90, the first 1 MB-interface drive) on the 1 MB interface (ports
 * 0x90/0x92, uPD71071 channel 2, IRQ11 - NP2kai io/fdc.c FDC_DMACH2HD, the core's
 * pc9821_fdc). The probe ONLY READS the disk: the sector is first read normally by INT 1Bh
 * (AH=56h) into a buffer, so its bytes are known, and every DMA run is preceded by another
 * INT 1Bh read of the same sector (it positions the head and spins the motor). The DMA run
 * itself is programmed directly: channel 2 (mode 0x46 = single, increment, I/O->memory;
 * address 0x09, count 0x0B, bank 0x23 - NP2kai io/dmac.c dmac_o01/o03/o21), count = LEN-1
 * (the 8237 moves count+1 bytes), and the FDC gets READ DATA 0x46 for C0 H0 R1 with EOT=R.
 * The DMA's terminal count after LEN bytes ends the command early (NP2kai fdc_dataread on
 * TC; a uPD765 stops requesting on TC), so only LEN bytes (32, or 4) are written.
 *
 * Every case is run TWICE with the same mapping: XFER=CPU copies the LEN sector bytes with
 * the CPU (`rep movsb`), XFER=DMA moves them with the DMA. Each run reads a set of VIEWS -
 * the same bytes seen through the window itself, through an alias, and through the storage
 * that would sit under the window with the mapping off - in four phases:
 *   ORIG  the as-found bytes (saved; written back after the run, views in reverse order);
 *   PRE   after writing a per-view prefill (the expected bytes XOR the view's key, so every
 *         byte of every view differs from the sector and from the other views' prefills);
 *   POST  after the transfer.
 * The decoder classifies each POST view as D (the transferred bytes), Pn (still view n's
 * prefill), FF (open bus) or mixed, and compares the DMA run with the CPU run: the DMA is
 * "routed as the CPU" when every view's POST bytes are equal.
 *
 * CASES (one BEGIN:CASE/END:CASE section each; V0 is always the window's own view):
 *   C0  plain conventional RAM (a buffer in this program) - the control.
 *   E1  0xB0200 with 0x043F=0x22 (the 64 KiB EMS page); views: 0x22, 0x20 (planes), 0x24.
 *   E2  the same with 0x043F=0x24 (the unmapped state).
 *   P1  PEGC 256-colour packed, bank A=5 B=6, 0xA8100; views: A8100 (A=5), B0100 with B=5
 *       (the same bank through window B), A8100 in the as-found mode (plane B).
 *   P2  the same, 0xB0100 (bank B=6); views: B0100, A8100 with A=6, B0100 as-found (plane R).
 *   P3  the same, 0xB8100 (not connected in 256-colour mode); views: B8100, B8100 as-found.
 *   P4  the same, 0xE0004 LEN=4: the bank registers E0004-E0007; views: the register file,
 *       E0004 as-found (the E plane).
 *   W1  0x0461=0x0A, 0x88100 (-> 0xA8100); views: 88100 moved, A8100, 88100 unmoved (RAM).
 *   W2  0x0461=0x0A, 0x81000 (-> 0xA1000, text RAM); views likewise.
 *   W3  0x0461=0x10, 0x9F000 (-> 0x11F000); views: 9F000 moved, 9F000 unmoved (RAM).
 *   G1  the CG window 0xA4000 LEN=32 with user character 0x7621 (A1=21 A3=56 A5 bit5=0)
 *       selected: its odd bytes are glyph lines 0-15 (NP2kai mem/memtram.c memtram_wr8);
 *       views: the window's odd bytes A4001+2i, port 0xA9 lines 0-15.
 *
 * WHAT IT CHANGES, AND HOW IT IS RESTORED. Everything inside a run happens with interrupts
 * off (CLI) - the window-0 cases move DOS's own 0x80000-0x9FFFF, so no handler may run -
 * and ends with the mapping back at "normal":
 *   0x043F <- 0x20 (the identity: the planes at 0xB0000; plain DOS has no EMS window);
 *   0x0461 <- its as-found read-back with bit 0 cleared (it reads back value|1), 0x08 if absent;
 *   PEGC: 0x6A 0x20 (256 off), 0x06 (FF2 num 3 off), then the as-found FF2 bits as pegcrd
 *     restores them (the 0x9A0 query bits are the witness); bank registers are written back
 *     from ORIG;
 *   CG: the glyph lines are written back from ORIG; 0xA1/0xA3/0xA5 are write-only and are
 *     left at 00/00/00;
 *   DMA channel 2 is masked again after the transfer (the BIOS reprograms it per call);
 *   0x94 (write-only) and the BIOS work byte 0x0485: handed back as the BIOS leaves them after
 *     its own read (motor_rearm; THE MOTOR, AFTERWARDS, below), after the direct check and
 *     after every DMA run; 0x00BE/0x04BE are only ever written by the BIOS (per DA/UA);
 *   IRQ11 is masked in the slave IMR (0x0A) for the DMA run, and afterwards a probe-owned
 *     handler that only sends the EOIs is installed on vector 0x13 while the as-found IMR
 *     is restored and interrupts are on for a moment, so an FDC interrupt held by the PIC
 *     is consumed by it, not by the BIOS's FDC handler; then the BIOS vector is put back.
 * The memory bytes the views touch are written back from ORIG; the 486 caches are
 * written back and invalidated (WBINVD) between the transfer and the POST reads. The probe
 * never writes the disk. RESTORE prints every register before/after.
 *
 * FINDING THE DISK. The first Xe10 run printed `DISK DA=90 RECAL=60 READID=60`: those are
 * INT 1Bh AH returns, and 0x60 is NOT READY (NP2kai bios/bios1b.c fdd_operate `ret_ah = 0x60`
 * when !fdd_diskready). The Xe10 BIOS reaches it after switching the motor on itself and
 * polling SENSE DRIVE STATUS for RDY 16 times (BANK7@0x756D-0x759B: `out 0x94,0x08`, then
 * BANK7@0x7E67 `ah=4 ... test al,0x20`), so drive 0 never reported ready: no medium there, as
 * the BIOS saw it. The probe now scans, BIOS first and then directly, until one answers:
 *   DA/UA 0x90, 0x91 (2HD 1 MB), 0x30, 0x31 (1.44 MB), 0x10, 0x11 (640 KB 2DD) - all on the
 *   1 MB interface (ports 0x90/0x92/0x94), the BIOS choosing the mode per call (0x00BE and
 *   0x04BE, BANK7@0x73D9-0x745D) - with DA=xx, if given, tried first. The 640 KB interface
 *   (0xC8/0xCA/0xCC, DA/UA 0x7x) is NOT tried: on the measured unit its window is switched out
 *   (docs/probes/FDMODE-XE10.TXT `PORT 00C8=FF`, `SENSE DA=70 AH=40 CF=1`), and switching it
 *   in means rewriting 0x00BE bit 0 under the BIOS, which moves the one controller to the other
 *   window, IRQ10 and DMA channel 3 (src/pc9821/storage/pc9821_fdc.sv header); a 2DD disk is
 *   read through DA/UA 0x1x instead.
 * For each DA it prints one DISK line (INT 1Bh SENSE 04h, RECALIBRATE 07h, READ ID 4Ah, READ
 * 56h) and one DIRECT line, the controller programmed by hand with IR11 masked:
 *   SENSE DRIVE STATUS (ST3: bit 6 WP, 5 RDY, 4 T0, 3 TS) before the motor is switched on;
 *   the motor on as the BIOS does it before an operation (BANK7@0x7574-0x757E: when the work
 *     byte 0x0480 has bit 4 set - the machine's 0480=DB - the BIOS's motor-off countdown
 *     0x0485 is zeroed and 0x94 <- 0x08, the MTON bit 3; MAME pc9801.cpp fdc_2hd_2dd_ctrl_w
 *     drives both drives' motor line from bit 3; with bit 4 clear the BIOS never writes 0x94,
 *     the motors run always (0x00BE bit 2 written 0, MAME fdc_mode_w), and neither does the
 *     probe). There is no drive-select register on this interface: the uPD765's US bits in
 *     each command select the unit (SENSE DRIVE STATUS is the first);
 *   500 ms of spin-up, timed by the ARTIC (307200 Hz, ports 0x5C/0x5F), not by CPU speed;
 *   SENSE DRIVE STATUS again; RECALIBRATE, completed by polling SENSE INTERRUPT STATUS (0x80 =
 *     nothing pending yet; ready-change statuses of other drives are drained) for 3 s; READ ID
 *     (MF) when RDY and the recalibrate were clean, 2 s;
 *   then every pending interrupt status is drained, the held IRQ11 taken by the probe's EOI
 *     handler (irq_drain), and the motor handed back to the BIOS (motor_rearm, below).
 * A failed DIRECT line names its step: IDLE (the FDC was not idle), SDS1/SDS2 (no ST3),
 * NOTREADY (RDY clear after spin-up), RECAL (abnormal ST0), RECALTMO, READID (abnormal ST0),
 * READIDTMO. The first DA whose BIOS read AND direct READ ID both succeed is used; failing
 * that, the first whose BIOS read succeeded (the DMA runs then report their own RC); failing
 * both, NODISK. USING DA=xx says which.
 *
 * THE MOTOR, AFTERWARDS. 0x94 is write-only (it reads 0x44, docs/probes/FDMODE-XE10.TXT), so
 * the as-found value cannot be read back. The probe leaves it as the BIOS leaves it after its
 * own read: 0x0485 <- [0x05CB] (0x96 on the machine) and 0x94 <- 0x09 then 0x0C (BANK7@0x7365-
 * 0x7396, the motor still on, bit 0 pulsed). The BIOS's FDC interrupt handler (vector 0x13,
 * BANK7@0x7AF7) then counts 0x0485 down on the interface's own timer interrupts, writing
 * 0x0D/0x0C per tick, and at zero writes 0x94 <- 0x00 and marks the drives for a spin-up wait
 * (BANK7@0x7AAB-0x7ACA): the motor stops under the BIOS's own timeout, exactly as after any DOS
 * read. The same hand-back runs after each DMA run, because irq_drain may have consumed one
 * of those timer interrupts and with it the BIOS's re-trigger.
 *
 * REQUIREMENTS. Plain DOS (no EMM386: WBINVD and the 0x043F writes need real mode, and an
 * EMS driver owns 0x043F); a disk in drive 0 or 1 whose C0 H0 R1 is readable (any formatted
 * 2HD, 1.44 MB or 2DD disk, e.g. a DOS disk). DA=xx is tried first (hex).
 * /CPU runs only the CPU transfers (no FDC programming: no DIRECT lines, no DMA runs; the
 * scan then takes the first DA whose BIOS read succeeds), to check the views on their own.
 * Always redirect stdout to a file. A BEGIN: with no END: is the section that hung.
 *
 * BUILD: make -C tools/hwprobe dmaroute/dmaroute.com
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

    .equ VMAX,      4           /* views per case */
    .equ VLEN,      32          /* the longest view */
    .equ CASE_SZ,   44          /* 12 header + 4 views x 8 */
    .equ C_NAME,    0
    .equ C_STATE,   2
    .equ C_BA,      3
    .equ C_BB,      4
    .equ C_LEN,     5
    .equ C_NV,      6
    .equ C_SEG,     8
    .equ C_OFF,     10
    .equ C_VIEWS,   12
    .equ V_STATE,   0
    .equ V_BA,      1
    .equ V_BB,      2
    .equ V_KIND,    3
    .equ V_SEG,     4
    .equ V_OFF,     6

    .equ ST_NORMAL, 0
    .equ ST_EMS22,  1
    .equ ST_EMS24,  2
    .equ ST_PEG,    3
    .equ ST_W0A,    4
    .equ ST_W10,    5
    .equ ST_CG,     6

    .equ K_MEM,     0           /* LEN bytes at seg:off */
    .equ K_ODD,     1           /* LEN/2 bytes at seg:off + 2i (the CG window's odd bytes) */
    .equ K_CGP,     2           /* LEN/2 glyph lines through port 0xA9 */

    .equ OP_ORIG,   0
    .equ OP_PREFILL,1
    .equ OP_PRE,    2
    .equ OP_POST,   3
    .equ OP_RESTORE,4

    .equ TMO_HI,    0x0080      /* poll timeout: TMO_HI * 65536 MSR reads */
    .equ ART_500MS, 153600      /* ARTIC ticks (307200 Hz): the spin-up wait */
    .equ ART_2S,    614400      /* READ ID's result phase */
    .equ ART_3S,    921600      /* RECALIBRATE's seek end */

_start:
    cld
    mov     si, offset msg_begin
    call    puts
    call    parse_args

    /* ---------------- the as-found state ---------------- */
    mov     dx, 0x0461
    in      al, dx
    mov     [w0_rb], al
    and     al, 0xFE
    cmp     al, 0xFE
    jne     w0_ok
    mov     al, 0x08                /* no register: the identity */
w0_ok:
    mov     [w0_found], al
    mov     dx, 0x006A
    in      al, dx
    mov     [mode_found], al
    cmp     al, 0x10
    jb      mf_ok
    xor     al, al
    mov     [mode_found], al
mf_ok:
    mov     al, 0x04
    call    query9a0
    mov     [q16], al
    mov     al, 0x07
    call    query9a0
    mov     [qegc], al
    mov     al, 0x08
    call    query9a0
    mov     [qwren], al
    mov     al, 0x0A
    call    query9a0
    mov     [q256], al
    in      al, 0x0A
    mov     [imr_found], al
    in      al, 0x02
    mov     [mimr_found], al
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x4C]
    mov     [vec13_off], ax
    mov     ax, es:[0x4E]
    mov     [vec13_seg], ax
    pop     es

    mov     si, offset msg_found
    call    puts
    mov     al, [w0_rb]
    call    puthex8
    mov     si, offset msg_6a
    call    puts
    mov     al, [mode_found]
    call    puthex8
    mov     si, offset msg_q
    call    puts
    mov     al, [q16]
    call    puthex8
    mov     al, ' '
    call    putch
    mov     al, [qegc]
    call    puthex8
    mov     al, ' '
    call    putch
    mov     al, [qwren]
    call    puthex8
    mov     al, ' '
    call    putch
    mov     al, [q256]
    call    puthex8
    mov     si, offset msg_imr
    call    puts
    mov     al, [mimr_found]
    call    puthex8
    mov     al, ' '
    call    putch
    mov     al, [imr_found]
    call    puthex8
    mov     si, offset msg_vec
    call    puts
    mov     ax, [vec13_seg]
    call    puthex16
    mov     al, ':'
    call    putch
    mov     ax, [vec13_off]
    call    puthex16
    call    crlf

    /* ---------------- buffers that must not cross a 64 KiB DMA page ---------------- */
    mov     ax, offset secarea
    mov     cx, 1024
    call    dma_safe
    mov     [secbuf], ax
    mov     ax, offset secarea2
    mov     cx, 1024
    call    dma_safe
    mov     [secbuf2], ax
    mov     ax, offset ctrlarea
    mov     cx, 32
    call    dma_safe
    mov     [ctrl_off], ax
    /* patch the control case (target and its one view) with this segment */
    mov     bx, offset case_c0
    mov     [bx+C_SEG], cs
    mov     [bx+C_OFF], ax
    mov     [bx+C_VIEWS+V_SEG], cs
    mov     [bx+C_VIEWS+V_OFF], ax

    /* ---------------- the sector ---------------- */
    call    disk_setup
    jnc     disk_ok
    mov     si, offset msg_nodisk
    call    puts
    jmp     finish
disk_ok:
    mov     si, offset msg_sector
    call    puts
    mov     si, [secbuf]
    mov     cx, VLEN
    call    puthexbuf
    call    crlf
    mov     si, offset msg_keys
    call    puts
    mov     si, offset keys
    mov     cx, VMAX
    call    puthexbuf
    call    crlf

    /* ---------------- the cases ---------------- */
    mov     word ptr [cur], offset cases
case_loop:
    mov     bx, [cur]
    cmp     word ptr [bx+C_NAME], 0
    je      cases_done
    mov     si, offset msg_bcase
    call    puts
    mov     si, [bx+C_NAME]
    call    puts
    call    crlf
    call    build_expect
    mov     byte ptr [xkind], 0
    call    run_case
    cmp     byte ptr [cpu_only], 0
    jne     case_next
    cmp     byte ptr [dma_dead], 0
    je      case_dma
    mov     si, offset msg_dmaskip
    call    puts
    jmp     case_next
case_dma:
    mov     byte ptr [xkind], 1
    call    run_case
case_next:
    mov     si, offset msg_ecase
    call    puts
    mov     bx, [cur]
    mov     si, [bx+C_NAME]
    call    puts
    call    crlf
    add     word ptr [cur], CASE_SZ
    jmp     case_loop
cases_done:

finish:
    /* ---------------- the restore report ---------------- */
    cli
    call    to_normal_force
    sti
    mov     si, offset msg_brest
    call    puts
    mov     si, offset msg_r461
    call    puts
    mov     al, [w0_rb]
    call    puthex8
    mov     si, offset msg_now
    call    puts
    mov     dx, 0x0461
    in      al, dx
    call    puthex8
    call    crlf
    mov     si, offset msg_r6a
    call    puts
    mov     al, [mode_found]
    call    puthex8
    mov     al, ' '
    call    putch
    mov     al, [q16]
    call    puthex8
    mov     al, [qegc]
    call    puthex8
    mov     al, [qwren]
    call    puthex8
    mov     al, [q256]
    call    puthex8
    mov     si, offset msg_now
    call    puts
    mov     dx, 0x006A
    in      al, dx
    call    puthex8
    mov     al, ' '
    call    putch
    mov     al, 0x04
    call    query9a0
    call    puthex8
    mov     al, 0x07
    call    query9a0
    call    puthex8
    mov     al, 0x08
    call    query9a0
    call    puthex8
    mov     al, 0x0A
    call    query9a0
    call    puthex8
    call    crlf
    mov     si, offset msg_rimr
    call    puts
    mov     al, [mimr_found]
    call    puthex8
    mov     al, ' '
    call    putch
    mov     al, [imr_found]
    call    puthex8
    mov     si, offset msg_now
    call    puts
    in      al, 0x02
    call    puthex8
    mov     al, ' '
    call    putch
    in      al, 0x0A
    call    puthex8
    call    crlf
    mov     si, offset msg_rvec
    call    puts
    mov     ax, [vec13_seg]
    call    puthex16
    mov     al, ':'
    call    putch
    mov     ax, [vec13_off]
    call    puthex16
    mov     si, offset msg_now
    call    puts
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x4E]
    call    puthex16
    mov     al, ':'
    call    putch
    mov     ax, es:[0x4C]
    call    puthex16
    pop     es
    call    crlf
    /* the floppy interface: the mode registers (the BIOS's) and the motor (handed back) */
    mov     si, offset msg_rfd
    call    puts
    mov     al, [fd_be]
    call    puthex8
    mov     al, '/'
    call    putch
    mov     al, [fd_4be]
    call    puthex8
    mov     si, offset msg_now
    call    puts
    in      al, 0xBE
    call    puthex8
    mov     al, '/'
    call    putch
    mov     dx, 0x04BE
    in      al, dx
    call    puthex8
    mov     si, offset msg_rfd2
    call    puts
    mov     al, [da]
    call    puthex8
    call    crlf
    mov     si, offset msg_r94
    call    puts
    mov     al, [m_wrote]
    call    puthex8
    push    es
    xor     ax, ax
    mov     es, ax
    mov     si, offset msg_f480
    call    puts
    mov     al, es:[0x480]
    call    puthex8
    mov     si, offset msg_r485
    call    puts
    mov     al, es:[0x485]
    call    puthex8
    pop     es
    mov     si, offset msg_r94b
    call    puts
    mov     si, offset msg_rfixed
    call    puts
    mov     si, offset msg_erest
    call    puts
    mov     si, offset msg_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* ------------------------------------------------------------------ */
/* parse_args: "DA=xx" (hex) and "/CPU" anywhere in the command tail.   */
/* ------------------------------------------------------------------ */
parse_args:
    mov     si, 0x81
    xor     cx, cx
    mov     cl, [0x80]
pa_loop:
    test    cx, cx
    jz      pa_done
    mov     al, [si]
    call    upcase
    cmp     al, 'D'
    jne     pa_slash
    cmp     cx, 4
    jb      pa_next
    mov     al, [si+1]
    call    upcase
    cmp     al, 'A'
    jne     pa_next
    /* "DA=xx", and "DA xx" / "DAxx": COMMAND.COM splits batch arguments at '=' as at a
     * space, so RUNDMA DA=91 arrives here as "DA 91" */
    mov     bx, 2
pa_sep:
    lea     dx, [bx+2]
    cmp     dx, cx
    ja      pa_next                 /* fewer than two characters left */
    mov     al, [si+bx]
    cmp     al, '='
    je      pa_sep_n
    cmp     al, ' '
    je      pa_sep_n
    cmp     al, ','
    je      pa_sep_n
    cmp     al, ';'
    jne     pa_hex
pa_sep_n:
    inc     bx
    jmp     pa_sep
pa_hex:
    mov     al, [si+bx]
    call    hexnib
    jc      pa_next
    shl     al, 4
    mov     ah, al
    mov     al, [si+bx+1]
    call    hexnib
    jc      pa_next
    or      al, ah
    mov     [da_user], al
    mov     byte ptr [da_given], 1
    jmp     pa_next
pa_slash:
    cmp     al, '/'
    jne     pa_next
    cmp     cx, 4
    jb      pa_next
    mov     al, [si+1]
    call    upcase
    cmp     al, 'C'
    jne     pa_next
    mov     al, [si+2]
    call    upcase
    cmp     al, 'P'
    jne     pa_next
    mov     al, [si+3]
    call    upcase
    cmp     al, 'U'
    jne     pa_next
    mov     byte ptr [cpu_only], 1
pa_next:
    inc     si
    dec     cx
    jmp     pa_loop
pa_done:
    ret

upcase:
    cmp     al, 'a'
    jb      uc_r
    cmp     al, 'z'
    ja      uc_r
    sub     al, 0x20
uc_r:
    ret

hexnib:                                 /* AL ascii -> AL 0..15, CF on error */
    call    upcase
    cmp     al, '0'
    jb      hn_bad
    cmp     al, '9'
    jbe     hn_dig
    cmp     al, 'A'
    jb      hn_bad
    cmp     al, 'F'
    ja      hn_bad
    sub     al, 'A' - 10
    clc
    ret
hn_dig:
    sub     al, '0'
    clc
    ret
hn_bad:
    stc
    ret

/* dma_safe: AX = offset of a 2*CX area in this segment; returns AX = the start of a CX-byte
 * span inside it that does not cross a 64 KiB physical page (the DMAC's bank boundary). */
dma_safe:
    push    ebx
    push    edx
    movzx   ebx, ax
    xor     edx, edx
    mov     dx, cs
    shl     edx, 4
    add     edx, ebx                /* physical start */
    mov     ebx, edx
    and     ebx, 0xFFFF
    movzx   edx, cx
    add     ebx, edx
    cmp     ebx, 0x10000
    jbe     ds_ok
    add     ax, cx
ds_ok:
    pop     edx
    pop     ebx
    ret

/* ------------------------------------------------------------------ */
/* the floppy: the scan over DA/UA (see FINDING THE DISK in the header)  */
/* ------------------------------------------------------------------ */
disk_setup:
    /* the as-found interface registers (reads only) and the BIOS's motor work bytes */
    in      al, 0xBE
    mov     [fd_be], al
    mov     dx, 0x04BE
    in      al, dx
    mov     [fd_4be], al
    mov     si, offset msg_fdc
    call    puts
    in      al, 0x90
    call    puthex8
    mov     si, offset msg_f94
    call    puts
    in      al, 0x94
    call    puthex8
    mov     si, offset msg_fbe
    call    puts
    mov     al, [fd_be]
    call    puthex8
    mov     si, offset msg_f4be
    call    puts
    mov     al, [fd_4be]
    call    puthex8
    push    es
    xor     ax, ax
    mov     es, ax
    mov     si, offset msg_f480
    call    puts
    mov     al, es:[0x480]
    call    puthex8
    mov     si, offset msg_f485
    call    puts
    mov     al, es:[0x485]
    call    puthex8
    mov     si, offset msg_f5cb
    call    puts
    mov     al, es:[0x5CB]
    call    puthex8
    pop     es
    call    crlf

    mov     byte ptr [fb_da], 0
    cmp     byte ptr [da_given], 0
    je      dsu_list
    mov     al, [da_user]
    call    try_da
    jnc     dsu_found
dsu_list:
    mov     si, offset da_list
dsu_l:
    mov     al, [si]
    test    al, al
    jz      dsu_none
    inc     si
    cmp     byte ptr [da_given], 0
    je      dsu_try
    cmp     al, [da_user]
    je      dsu_l                   /* already tried */
dsu_try:
    push    si
    call    try_da
    pop     si
    jnc     dsu_found
    jmp     dsu_l
dsu_none:
    /* no DA passed both: the first whose BIOS read succeeded, read again (its mode set) */
    mov     al, [fb_da]
    test    al, al
    jz      dsu_fail
    call    try_da_bios
    jc      dsu_fail
dsu_found:
    mov     si, offset msg_using
    call    puts
    mov     al, [da]
    call    puthex8
    mov     si, offset msg_dok
    cmp     byte ptr [d_ok], 0
    jne     dsu_f2
    mov     si, offset msg_dfail
    cmp     byte ptr [cpu_only], 0
    je      dsu_f2
    mov     si, offset msg_dcpu
dsu_f2:
    call    puts
    clc
    ret
dsu_fail:
    stc
    ret

/* try_da: AL = DA/UA. The BIOS steps, then (not under /CPU) the direct check. CF clear when
 * this DA is the one to use (BIOS read ok and direct READ ID ok; under /CPU the BIOS read
 * alone); a BIOS-only success is remembered in fb_da. */
try_da:
    mov     byte ptr [d_ok], 0
    call    try_da_bios
    pushf
    cmp     byte ptr [cpu_only], 0
    jne     td_cpu
    call    direct_check
    popf
    jc      td_no
    cmp     byte ptr [d_ok], 0
    jne     td_yes
    cmp     byte ptr [fb_da], 0
    jne     td_no
    mov     al, [da]
    mov     [fb_da], al
td_no:
    stc
    ret
td_cpu:
    popf
    jc      td_no
td_yes:
    clc
    ret

/* try_da_bios: AL = DA/UA -> [da]; INT 1Bh SENSE, RECALIBRATE, READ ID, READ into secbuf.
 * Prints the DISK line. CF on failure. */
try_da_bios:
    mov     [da], al
    mov     si, offset msg_disk
    call    puts
    mov     al, [da]
    call    puthex8
    /* SENSE (04h): the BIOS's own ready check of this unit */
    mov     ah, 0x04
    mov     al, [da]
    call    int1b
    push    ax
    mov     si, offset msg_bsense
    call    puts
    pop     ax
    mov     al, ah
    call    puthex8
    /* RECALIBRATE */
    mov     ah, 0x07
    mov     al, [da]
    call    int1b
    mov     [bios_recal], ah
    mov     si, offset msg_recal
    call    puts
    mov     al, [bios_recal]
    call    puthex8
    /* READ ID, head 0 */
    mov     ah, 0x4A
    mov     al, [da]
    xor     dh, dh
    call    int1b
    mov     [bios_rid], ah
    mov     [rid_c], cl
    mov     [rid_h], dh
    mov     [rid_r], dl
    mov     [rid_n], ch
    mov     si, offset msg_rid
    call    puts
    mov     al, [bios_rid]
    call    puthex8
    mov     si, offset msg_chrn
    call    puts
    mov     al, [rid_c]
    call    puthex8
    mov     al, [rid_h]
    call    puthex8
    mov     al, [rid_r]
    call    puthex8
    mov     al, [rid_n]
    call    puthex8
    mov     al, [bios_rid]
    and     al, 0xF0
    cmp     al, 0x00
    je      dsk_idok
    call    crlf
    stc
    ret
dsk_idok:
    mov     al, [rid_n]
    cmp     al, 3
    jbe     dsk_nok
    call    crlf
    stc
    ret
dsk_nok:
    mov     cl, al
    mov     ax, 128
    shl     ax, cl
    mov     [seclen], ax
    mov     di, [secbuf]
    call    bios_read
    mov     [bios_rd], ah
    mov     si, offset msg_rd
    call    puts
    mov     al, [bios_rd]
    call    puthex8
    mov     si, offset msg_len
    call    puts
    mov     ax, [seclen]
    call    puthex16
    call    crlf
    mov     al, [bios_rd]
    and     al, 0xF0
    cmp     al, 0
    je      dsk_ok2
    stc
    ret
dsk_ok2:
    clc
    ret

/* bios_read: INT 1Bh AH=56h (READ DATA, MF, seek) of C0 H0 R1 N=rid_n into DS:DI.
 * Returns AH = the BIOS status. */
bios_read:
    push    bx
    push    cx
    push    dx
    push    bp
    push    es
    mov     bp, di
    push    cs
    pop     es
    mov     ah, 0x56
    mov     al, [da]
    mov     bx, [seclen]
    mov     ch, [rid_n]
    mov     cl, 0x00                /* C */
    mov     dh, 0x00                /* H */
    mov     dl, 0x01                /* R */
    call    int1b
    pop     es
    pop     bp
    pop     dx
    pop     cx
    pop     bx
    ret

/* int1b: INT 1Bh with DS/ES/BP/SI/DI preserved; interrupts on, DF clear. */
int1b:
    push    ds
    push    es
    push    si
    push    di
    push    bp
    cld
    sti
    int     0x1B
    pop     bp
    pop     di
    pop     si
    pop     es
    pop     ds
    ret

/* ------------------------------------------------------------------ */
/* direct_check: the controller by hand for unit [da]&3 on the 1 MB interface (header,      */
/* FINDING THE DISK). Interrupts stay on; IR11 is masked throughout, so the BIOS's FDC      */
/* handler cannot run between the probe's commands. Sets d_ok; prints the DIRECT line.      */
/* ------------------------------------------------------------------ */
direct_check:
    push    ax
    push    bx
    push    cx
    push    di
    push    si
    mov     al, [da]
    and     al, 0x03
    mov     [d_us], al
    mov     byte ptr [d_ok], 0
    mov     word ptr [d_step], 0
    mov     byte ptr [d_mwr], 0
    mov     al, 0xFF
    mov     [d_st3a], al
    mov     [d_st3b], al
    mov     [d_st0], al
    mov     [d_pcn], al
    mov     di, offset d_rid
    mov     cx, 8
dc_fill:
    mov     [di], al
    inc     di
    loop    dc_fill

    in      al, 0x0A
    mov     [imr_run], al
    or      al, 0x08                /* IR11 masked for the whole check */
    out     0x0A, al
    call    iowait

    call    fdc_wait_idle
    jnc     dc_idle
    mov     word ptr [d_step], offset st_idle
    jmp     dc_end
dc_idle:
    call    fdc_sds
    jnc     dc_s1
    mov     word ptr [d_step], offset st_sds1
    jmp     dc_end
dc_s1:
    mov     [d_st3a], al
    call    motor_on
    mov     eax, ART_500MS
    call    art_wait
    call    fdc_sds
    jnc     dc_s2
    mov     word ptr [d_step], offset st_sds2
    jmp     dc_end
dc_s2:
    mov     [d_st3b], al
    test    al, 0x20                /* ST3 RDY */
    jnz     dc_recal
    mov     word ptr [d_step], offset st_nrdy
dc_recal:
    /* RECALIBRATE, run even when not ready: its ST0 is the diagnostic */
    mov     al, 0x07
    call    fdc_out
    jc      dc_rtmo
    mov     al, [d_us]
    call    fdc_out
    jc      dc_rtmo
    call    art_mark
dc_rpoll:
    call    fdc_sis                 /* AL = ST0, AH = PCN */
    jc      dc_rtmo
    cmp     al, 0x80
    je      dc_rwait                /* nothing pending yet */
    mov     bl, al
    and     bl, 0x23                /* SE | US */
    mov     bh, [d_us]
    or      bh, 0x20
    cmp     bl, bh
    je      dc_rgot
dc_rwait:                           /* pending yet, or another drive's status: drained */
    mov     cx, 20
dc_rdly:
    call    fdc_settle
    loop    dc_rdly
    call    art_since
    cmp     eax, ART_3S
    jb      dc_rpoll
dc_rtmo:
    mov     word ptr [d_step], offset st_rtmo
    jmp     dc_drain
dc_rgot:
    mov     [d_st0], al
    mov     [d_pcn], ah
    test    al, 0xD8                /* IC (7:6), EC (4), NR (3) */
    jz      dc_rok
    cmp     word ptr [d_step], 0
    jne     dc_drain
    mov     word ptr [d_step], offset st_recal
    jmp     dc_drain
dc_rok:
    cmp     word ptr [d_step], 0
    jne     dc_drain                /* not ready: no READ ID */
    /* READ ID (MF), head 0 */
    mov     al, 0x4A
    call    fdc_out
    jc      dc_itmo
    mov     al, [d_us]
    call    fdc_out
    jc      dc_itmo
    call    art_mark
dc_iw:
    in      al, 0x90
    and     al, 0xC0
    cmp     al, 0xC0
    je      dc_ires
    call    art_since
    cmp     eax, ART_2S
    jb      dc_iw
dc_itmo:
    mov     word ptr [d_step], offset st_itmo
    mov     byte ptr [dma_dead], 1  /* the FDC is in an unknown phase: no DMA runs */
    jmp     dc_end
dc_ires:
    mov     di, offset d_rid
    call    fdc_result
    jc      dc_itmo
    test    byte ptr [d_rid], 0xC0
    jz      dc_iok
    mov     word ptr [d_step], offset st_rid
    jmp     dc_drain
dc_iok:
    mov     byte ptr [d_ok], 1
dc_drain:
    /* every interrupt status still pending (ready changes from the motor-on), up to 8 */
    mov     cx, 8
dc_dl:
    call    fdc_sis
    jc      dc_end
    cmp     al, 0x80
    je      dc_end
    loop    dc_dl
dc_end:
    cli
    call    irq_drain               /* the held IRQ11 to the EOI handler; IMR as found */
    call    motor_rearm
    sti

    /* DIRECT U=u ST3=xx MOTOR=xx ST3=xx RECAL ST0=xx PCN=xx READID=xx*7 OK|FAIL=step */
    mov     si, offset msg_direct
    call    puts
    mov     al, [d_us]
    add     al, '0'
    call    putch
    mov     si, offset msg_dst3
    call    puts
    mov     al, [d_st3a]
    call    puthex8
    mov     si, offset msg_dmotor
    call    puts
    cmp     byte ptr [d_mwr], 0
    jne     dc_pm
    mov     si, offset msg_dash
    call    puts
    jmp     dc_pm2
dc_pm:
    mov     al, 0x08
    call    puthex8
dc_pm2:
    mov     si, offset msg_dst3
    call    puts
    mov     al, [d_st3b]
    call    puthex8
    mov     si, offset msg_drecal
    call    puts
    mov     al, [d_st0]
    call    puthex8
    mov     si, offset msg_dpcn
    call    puts
    mov     al, [d_pcn]
    call    puthex8
    mov     si, offset msg_drid
    call    puts
    mov     si, offset d_rid
    mov     cx, 7
    call    puthexbuf
    mov     si, offset msg_dok
    cmp     byte ptr [d_ok], 0
    jne     dc_p3
    mov     si, offset msg_dfail_at
    call    puts
    mov     si, [d_step]
    test    si, si
    jnz     dc_p3
    mov     si, offset st_unk
dc_p3:
    call    puts
    cmp     byte ptr [d_ok], 0
    jne     dc_ret
    call    crlf
dc_ret:
    pop     si
    pop     di
    pop     cx
    pop     bx
    pop     ax
    ret

/* motor_on: the BIOS's pre-operation motor switch (BANK7@0x756D-0x757E): when 0x0480 bit 4
 * is set, the motor-off countdown 0x0485 is zeroed (the BIOS's xchg) and 0x94 <- 0x08 (MTON).
 * With bit 4 clear the BIOS does not write 0x94 and neither does this. */
motor_on:
    push    ax
    push    es
    xor     ax, ax
    mov     es, ax
    test    byte ptr es:[0x480], 0x10
    jz      mo_r
    cli
    mov     byte ptr es:[0x485], 0
    mov     al, 0x08
    out     0x94, al
    call    iowait
    sti
    mov     byte ptr [d_mwr], 1
    mov     byte ptr [m_wrote], 1
mo_r:
    pop     es
    pop     ax
    ret

/* motor_rearm (interrupts off): the BIOS's post-operation hand-back (BANK7@0x7365-0x7396):
 * 0x0485 <- [0x05CB], 0x94 <- 0x09, 0x0C. The BIOS's FDC handler then counts the motor off. */
motor_rearm:
    push    ax
    push    es
    xor     ax, ax
    mov     es, ax
    test    byte ptr es:[0x480], 0x10
    jz      mr_r
    mov     al, es:[0x5CB]
    mov     es:[0x485], al
    mov     al, 0x09
    out     0x94, al
    call    iowait
    mov     al, 0x0C
    out     0x94, al
    call    iowait
    mov     byte ptr [m_wrote], 1
mr_r:
    pop     es
    pop     ax
    ret

/* fdc_sds: SENSE DRIVE STATUS of unit [d_us], head 0 -> AL = ST3. CF on timeout. */
fdc_sds:
    push    di
    mov     al, 0x04
    call    fdc_out
    jc      fs_r
    mov     al, [d_us]
    call    fdc_out
    jc      fs_r
    mov     byte ptr [f_res], 0xFF
    mov     di, offset f_res
    call    fdc_result
    jc      fs_r
    mov     al, [f_res]
fs_r:
    pop     di
    ret

/* fdc_sis: SENSE INTERRUPT STATUS -> AL = ST0, AH = PCN (0xFF when only 0x80 came back). */
fdc_sis:
    push    di
    mov     al, 0x08
    call    fdc_out
    jc      fsi_r
    mov     byte ptr [f_res], 0xFF
    mov     byte ptr [f_res+1], 0xFF
    mov     di, offset f_res
    call    fdc_result
    jc      fsi_r
    mov     al, [f_res]
    mov     ah, [f_res+1]
fsi_r:
    pop     di
    ret

/* fdc_result: the result phase into DS:DI (at most 8 bytes kept). It reads while the MSR
 * shows RQM|DIO and stops at RQM with DIO and CB clear (the command phase again); the MSR is
 * read only after the BIOS's settle delay (BANK7@0x71CD, ten 0x5F writes, called before its
 * MSR reads, e.g. BANK7@0x7B08). CF on timeout. */
fdc_result:
    push    ax
    push    cx
    push    dx
    push    di
    xor     cx, cx
    mov     word ptr [fr_spin], 0xFFFF
fr_l:
    dec     word ptr [fr_spin]
    jz      fr_t
    call    fdc_settle
    mov     dx, TMO_HI
fr_o:
    push    cx
    xor     cx, cx
fr_i:
    in      al, 0x90
    test    al, 0x80
    jnz     fr_rqm
    loop    fr_i
    pop     cx
    dec     dx
    jnz     fr_o
fr_t:
    stc
    jmp     fr_r
fr_rqm:
    pop     cx
    test    al, 0x40
    jnz     fr_byte
    test    al, 0x10
    jnz     fr_l                    /* RQM, CB, no DIO: not in the result phase yet */
    clc
    jmp     fr_r
fr_byte:
    in      al, 0x92
    cmp     cx, 8
    jae     fr_skip
    mov     [di], al
    inc     di
fr_skip:
    inc     cx
    cmp     cx, 16
    jb      fr_l
    clc
fr_r:
    pop     di
    pop     dx
    pop     cx
    pop     ax
    ret

fdc_settle:
    push    ax
    push    cx
    mov     cx, 10
fst_l:
    out     0x5F, al
    loop    fst_l
    pop     cx
    pop     ax
    ret

/* the ARTIC (307200 Hz, 24 bits): read as tools/hwprobe/crt31k does (high, low word, high). */
art_read:
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005F
    in      al, dx
    movzx   ebx, al
    mov     dx, 0x005C
    in      ax, dx
    movzx   ecx, ax
    mov     dx, 0x005F
    in      al, dx
    movzx   eax, al
    cmp     eax, ebx
    je      art_s
    cmp     ecx, 0x8000
    jb      art_s
    mov     eax, ebx
art_s:
    shl     eax, 16
    or      eax, ecx
    pop     ecx
    pop     ebx
    pop     dx
    ret

art_mark:                               /* t0 <- now */
    push    eax
    call    art_read
    mov     [art_t0], eax
    pop     eax
    ret

art_since:                              /* EAX <- ticks since art_mark */
    call    art_read
    sub     eax, [art_t0]
    and     eax, 0x00FFFFFF
    ret

art_wait:                               /* EAX ticks */
    push    ecx
    mov     ecx, eax
    call    art_mark
aw_l:
    call    art_since
    cmp     eax, ecx
    jb      aw_l
    pop     ecx
    ret

/* ------------------------------------------------------------------ */
/* build_expect: exp[i] and pf[i] (= exp[i] ^ key[i]) for the current case's views. */
/* ------------------------------------------------------------------ */
build_expect:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    bp
    mov     bx, [cur]
    xor     dx, dx                  /* view index */
be_view:
    cmp     dl, [bx+C_NV]
    jae     be_done
    mov     si, dx
    shl     si, 3
    add     si, bx
    add     si, C_VIEWS             /* SI = view */
    mov     al, [si+V_KIND]
    mov     [vkind], al
    call    view_len                /* CX = count, BX preserved */
    mov     di, dx
    shl     di, 5                   /* * VLEN */
    push    bx
    mov     bx, dx
    mov     ah, [keys+bx]
    pop     bx
    push    si
    mov     si, [secbuf]
    xor     bp, bp
be_byte:
    cmp     bp, cx
    jae     be_vdone
    push    bp
    cmp     byte ptr [vkind], K_MEM
    je      be_lin
    shl     bp, 1
    inc     bp                      /* the odd byte 2j+1 */
be_lin:
    mov     al, ds:[si+bp]
    pop     bp
    mov     ds:[exp+di+bp], al
    xor     al, ah
    mov     ds:[pf+di+bp], al
    inc     bp
    jmp     be_byte
be_vdone:
    pop     si
    inc     dx
    jmp     be_view
be_done:
    pop     bp
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* view_len: [vkind] and the case's LEN -> CX. BX = case. */
view_len:
    xor     cx, cx
    mov     cl, [bx+C_LEN]
    cmp     byte ptr [vkind], K_MEM
    je      vl_r
    shr     cx, 1
vl_r:
    ret

/* ------------------------------------------------------------------ */
/* run_case: one transfer ([xkind] 0 = CPU, 1 = DMA) of the case at [cur], with its views. */
/* ------------------------------------------------------------------ */
run_case:
    mov     bx, [cur]
    /* header */
    mov     si, offset msg_run
    call    puts
    mov     si, [bx+C_NAME]
    call    puts
    mov     si, offset msg_xcpu
    cmp     byte ptr [xkind], 0
    je      rc_h1
    mov     si, offset msg_xdma
rc_h1:
    call    puts
    mov     si, offset msg_state
    call    puts
    mov     al, [bx+C_STATE]
    mov     ah, [bx+C_BA]
    mov     dl, [bx+C_BB]
    call    print_state
    mov     si, offset msg_dst
    call    puts
    mov     ax, [bx+C_SEG]
    mov     dx, [bx+C_OFF]
    call    print_phys
    mov     si, offset msg_lenk
    call    puts
    mov     al, [bx+C_LEN]
    call    puthex8
    call    crlf

    mov     byte ptr [dma_rc], 0xFF
    cmp     byte ptr [xkind], 0
    je      rc_nobios
    /* the head and the motor: a normal BIOS read of the same sector, checked */
    mov     di, [secbuf2]
    call    bios_read
    mov     [bios_rd2], ah
    call    same_sector
    mov     [same], al
rc_nobios:
    in      al, 0x0A
    mov     [imr_run], al
    cli
    cmp     byte ptr [xkind], 0
    je      rc_nomask
    or      al, 0x08                /* IR11 (the 1 MB FDC) masked for the run */
    out     0x0A, al
rc_nomask:
    mov     byte ptr [cur_state], ST_NORMAL
    mov     al, OP_ORIG
    call    views_fwd
    mov     al, OP_PREFILL
    call    views_fwd
    mov     al, OP_PRE
    call    views_fwd

    /* the transfer, in the case's own mapping */
    mov     bx, [cur]
    mov     al, [bx+C_STATE]
    mov     ah, [bx+C_BA]
    mov     dl, [bx+C_BB]
    call    set_state
    cmp     byte ptr [xkind], 0
    jne     rc_dma
    push    es
    mov     es, [bx+C_SEG]
    mov     di, [bx+C_OFF]
    mov     si, [secbuf]
    xor     cx, cx
    mov     cl, [bx+C_LEN]
    cld
    rep     movsb
    pop     es
    jmp     rc_xdone
rc_dma:
    call    fdc_dma
rc_xdone:
    wbinvd
    mov     al, OP_POST
    call    views_fwd
    mov     al, OP_RESTORE
    call    views_rev
    call    to_normal

    cmp     byte ptr [xkind], 0
    je      rc_noirq
    call    irq_drain
    call    motor_rearm             /* the BIOS's motor-off countdown, re-armed */
rc_noirq:
    sti

    /* report */
    cmp     byte ptr [xkind], 0
    je      rc_rep_views
    call    print_dma
rc_rep_views:
    mov     bx, [cur]
    xor     dx, dx
rc_rv:
    cmp     dl, [bx+C_NV]
    jae     rc_rv_done
    call    print_view
    inc     dx
    jmp     rc_rv
rc_rv_done:
    ret

/* same_sector: AL = 1 if secbuf2 equals secbuf over seclen. */
same_sector:
    push    cx
    push    si
    push    di
    push    es
    push    cs
    pop     es
    mov     si, [secbuf]
    mov     di, [secbuf2]
    mov     cx, [seclen]
    cld
    repe    cmpsb
    mov     al, 1
    je      ss_r
    xor     al, al
ss_r:
    pop     es
    pop     di
    pop     si
    pop     cx
    ret

/* views_fwd / views_rev: AL = op, over every view of the case at [cur]. */
views_fwd:
    push    dx
    mov     [vop], al
    xor     dx, dx
vf_l:
    mov     bx, [cur]
    cmp     dl, [bx+C_NV]
    jae     vf_d
    call    view_io
    inc     dx
    jmp     vf_l
vf_d:
    pop     dx
    ret

views_rev:
    push    dx
    mov     [vop], al
    mov     bx, [cur]
    xor     dx, dx
    mov     dl, [bx+C_NV]
vr_l:
    test    dx, dx
    jz      vr_d
    dec     dx
    call    view_io
    jmp     vr_l
vr_d:
    pop     dx
    ret

/* view_io: DX = view index, [vop] = op. Sets the view's mapping, then moves its bytes:
 * ORIG/PRE/POST read into orig/pre/post[DX]; PREFILL writes pf[DX]; RESTORE writes orig[DX]. */
view_io:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    bp
    push    es
    mov     bx, [cur]
    mov     si, dx
    shl     si, 3
    add     si, bx
    add     si, C_VIEWS             /* SI = view */
    mov     al, [si+V_KIND]
    mov     [vkind], al
    call    view_len                /* CX */
    mov     bp, dx
    shl     bp, 5                   /* buffer offset */
    push    cx
    push    si
    mov     al, [si+V_STATE]
    mov     ah, [si+V_BA]
    mov     dl, [si+V_BB]
    call    set_state
    pop     si
    pop     cx
    mov     di, [si+V_OFF]
    mov     es, [si+V_SEG]
    /* BX = the buffer for this op */
    mov     al, [vop]
    mov     bx, offset orig
    cmp     al, OP_ORIG
    je      vio_rd
    cmp     al, OP_RESTORE
    je      vio_wr
    mov     bx, offset pf
    cmp     al, OP_PREFILL
    je      vio_wr
    mov     bx, offset pre
    cmp     al, OP_PRE
    je      vio_rd
    mov     bx, offset post
vio_rd:
    add     bx, bp
    xor     bp, bp
vio_rl:
    cmp     bp, cx
    jae     vio_done
    call    vbyte_rd
    mov     ds:[bx], al
    inc     bx
    inc     bp
    jmp     vio_rl
vio_wr:
    add     bx, bp
    xor     bp, bp
vio_wl:
    cmp     bp, cx
    jae     vio_done
    mov     al, ds:[bx]
    call    vbyte_wr
    inc     bx
    inc     bp
    jmp     vio_wl
vio_done:
    pop     es
    pop     bp
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* vbyte_rd / vbyte_wr: byte BP of the view ([vkind], ES:DI = its base). AL = the byte. */
vbyte_rd:
    push    dx
    push    di
    cmp     byte ptr [vkind], K_CGP
    je      vbr_cg
    add     di, bp
    cmp     byte ptr [vkind], K_MEM
    je      vbr_m
    add     di, bp                  /* K_ODD: base + 2j */
vbr_m:
    mov     al, es:[di]
    pop     di
    pop     dx
    ret
vbr_cg:
    mov     ax, bp
    and     al, 0x0F                /* the line; bit 5 clear = the half the window writes */
    out     0xA5, al
    call    iowait
    in      al, 0xA9
    pop     di
    pop     dx
    ret

vbyte_wr:
    push    dx
    push    di
    cmp     byte ptr [vkind], K_CGP
    je      vbw_cg
    add     di, bp
    cmp     byte ptr [vkind], K_MEM
    je      vbw_m
    add     di, bp
vbw_m:
    mov     es:[di], al
    pop     di
    pop     dx
    ret
vbw_cg:
    push    ax
    mov     ax, bp
    and     al, 0x0F
    out     0xA5, al
    call    iowait
    pop     ax
    out     0xA9, al
    call    iowait
    pop     di
    pop     dx
    ret

/* ------------------------------------------------------------------ */
/* the mapping states                                                   */
/* ------------------------------------------------------------------ */
/* set_state: AL = state, AH = bank A, DL = bank B (0xFF = leave the register alone). */
set_state:
    push    ax
    push    dx
    push    es
    cmp     al, [cur_state]
    jne     ss_change
    cmp     al, ST_PEG
    jne     ss_same
    /* PEGC -> PEGC: only the banks */
    call    peg_banks
    jmp     ss_out
ss_same:
    jmp     ss_out
ss_change:
    push    ax
    push    dx
    call    to_normal
    pop     dx
    pop     ax
    mov     [cur_state], al
    cmp     al, ST_EMS22
    jne     ss_e24
    mov     al, 0x22
    jmp     ss_43f
ss_e24:
    cmp     al, ST_EMS24
    jne     ss_peg
    mov     al, 0x24
ss_43f:
    push    dx
    mov     dx, 0x043F
    out     dx, al
    call    iowait
    pop     dx
    jmp     ss_out
ss_peg:
    cmp     al, ST_PEG
    jne     ss_w0a
    push    ax
    mov     al, 0x07                /* FF2 num 3: register write enable */
    out     0x6A, al
    call    iowait
    mov     al, 0x21                /* FF2 num 0x10: 256-colour (GDCANALOG_256) */
    out     0x6A, al
    call    iowait
    mov     ax, 0xE000
    mov     es, ax
    mov     byte ptr es:[0x0100], 0 /* packed-pixel mode */
    pop     ax
    call    peg_banks
    jmp     ss_out
ss_w0a:
    cmp     al, ST_W0A
    jne     ss_w10
    mov     al, 0x0A
    jmp     ss_461
ss_w10:
    cmp     al, ST_W10
    jne     ss_cg
    mov     al, 0x10
ss_461:
    push    dx
    mov     dx, 0x0461
    out     dx, al
    call    iowait
    pop     dx
    jmp     ss_out
ss_cg:
    cmp     al, ST_CG
    jne     ss_out
    mov     al, 0x21                /* the JIS second byte: 0x7621 */
    out     0xA1, al
    call    iowait
    mov     al, 0x56                /* the JIS first byte - 0x20: user characters 0x76xx */
    out     0xA3, al
    call    iowait
    xor     al, al                  /* line 0, bit 5 clear */
    out     0xA5, al
    call    iowait
ss_out:
    pop     es
    pop     dx
    pop     ax
    ret

/* peg_banks: AH = bank A, DL = bank B, written unless 0xFF (256-colour mode is on). */
peg_banks:
    push    es
    push    bx
    mov     bx, 0xE000
    mov     es, bx
    cmp     ah, 0xFF
    je      pb_b
    mov     es:[0x0004], ah
pb_b:
    cmp     dl, 0xFF
    je      pb_r
    mov     es:[0x0006], dl
pb_r:
    pop     bx
    pop     es
    ret

/* to_normal: back to the as-found mapping from whatever [cur_state] is. */
to_normal:
    cmp     byte ptr [cur_state], ST_NORMAL
    jne     to_normal_force
    ret
to_normal_force:
    push    ax
    push    dx
    mov     dx, 0x043F
    mov     al, 0x20
    out     dx, al
    call    iowait
    mov     dx, 0x0461
    mov     al, [w0_found]
    out     dx, al
    call    iowait
    cmp     byte ptr [cur_state], ST_PEG
    jne     tn_cg
    mov     al, 0x20                /* 256 off */
    out     0x6A, al
    call    iowait
    mov     al, 0x06                /* FF2 num 3 off */
    out     0x6A, al
    call    iowait
    call    restore_mode_bits
tn_cg:
    cmp     byte ptr [cur_state], ST_CG
    jne     tn_done
    xor     al, al
    out     0xA1, al
    call    iowait
    out     0xA3, al
    call    iowait
    out     0xA5, al
    call    iowait
tn_done:
    mov     byte ptr [cur_state], ST_NORMAL
    pop     dx
    pop     ax
    ret

/* restore_mode_bits: the as-found FF2 bits (pegcrd.s restore_mode_bits). */
restore_mode_bits:
    push    ax
    push    dx
    mov     dx, 0x006A
    mov     al, [q16]
    and     al, 0x01
    out     dx, al                  /* num 0: 16-colour select */
    call    iowait
    mov     al, [mode_found]
    and     al, 0x02
    shr     al, 1
    or      al, 0x02
    out     dx, al                  /* num 1 */
    call    iowait
    cmp     byte ptr [qegc], 0
    je      rmb_egc_done
    mov     al, 0x07
    out     dx, al
    call    iowait
    mov     al, 0x05
    out     dx, al                  /* num 2 (EGC), under num 3 */
    call    iowait
rmb_egc_done:
    cmp     byte ptr [q256], 0
    je      rmb_wren
    mov     al, 0x07
    out     dx, al
    call    iowait
    mov     al, 0x21
    out     dx, al
    call    iowait
rmb_wren:
    mov     al, 0x06
    cmp     byte ptr [qwren], 0
    je      rmb_w
    mov     al, 0x07
rmb_w:
    out     dx, al                  /* num 3, to its as-found value */
    call    iowait
    pop     dx
    pop     ax
    ret

/* query9a0: AL = index -> AL = the 0x9A0 query byte. */
query9a0:
    push    dx
    mov     dx, 0x09A0
    out     dx, al
    call    iowait
    in      al, dx
    pop     dx
    ret

iowait:
    out     0x5F, al                /* the PC-98 I/O wait port; preserves AL */
    ret

/* ------------------------------------------------------------------ */
/* fdc_dma: the DMA transfer of the case at [cur] (interrupts off, mapping set).   */
/* Leaves dma_rc (0 = ok), res[7], dmast_pre, dmast.                               */
/* ------------------------------------------------------------------ */
fdc_dma:
    push    eax
    push    ebx
    push    cx
    push    dx
    push    si
    mov     bx, [cur]
    movzx   eax, word ptr [bx+C_SEG]
    shl     eax, 4
    movzx   ebx, word ptr [bx+C_OFF]
    add     eax, ebx
    mov     [dma_phys], eax
    mov     bx, [cur]
    xor     cx, cx
    mov     cl, [bx+C_LEN]
    dec     cx                      /* the 8237 moves count + 1 */

    in      al, 0x11                /* clear the TC bits the BIOS read left */
    mov     [dmast_pre], al
    mov     al, 0x06                /* mask channel 2 */
    out     0x15, al
    call    iowait
    out     0x19, al                /* clear the byte flip-flop */
    call    iowait
    mov     al, 0x46                /* single, increment, no autoinit, I/O -> memory, ch 2 */
    out     0x17, al
    call    iowait
    mov     eax, [dma_phys]
    out     0x09, al                /* ch 2 address low */
    call    iowait
    mov     al, ah
    out     0x09, al                /* ch 2 address high */
    call    iowait
    mov     al, cl
    out     0x0B, al                /* ch 2 count low */
    call    iowait
    mov     al, ch
    out     0x0B, al                /* ch 2 count high */
    call    iowait
    mov     eax, [dma_phys]
    shr     eax, 16
    out     0x23, al                /* ch 2 bank (address bits 23:16) */
    call    iowait
    mov     al, 0x02                /* unmask channel 2 */
    out     0x15, al
    call    iowait

    /* the FDC must be idle */
    mov     byte ptr [dma_rc], 1
    call    fdc_wait_idle
    jc      fd_fail
    /* READ DATA: 0x46 (MF), HD/US, C, H, R, N, EOT, GPL, DTL */
    mov     byte ptr [dma_rc], 2
    mov     al, 0x46
    call    fdc_out
    jc      fd_fail
    mov     al, [da]
    and     al, 0x03                /* head 0 */
    call    fdc_out
    jc      fd_fail
    xor     al, al                  /* C */
    call    fdc_out
    jc      fd_fail
    xor     al, al                  /* H */
    call    fdc_out
    jc      fd_fail
    mov     al, 1                   /* R */
    call    fdc_out
    jc      fd_fail
    mov     al, [rid_n]             /* N */
    call    fdc_out
    jc      fd_fail
    mov     al, 1                   /* EOT = R */
    call    fdc_out
    jc      fd_fail
    mov     al, 0x1B                /* GPL */
    call    fdc_out
    jc      fd_fail
    mov     al, 0xFF                /* DTL */
    call    fdc_out
    jc      fd_fail
    /* the result phase */
    mov     byte ptr [dma_rc], 3
    call    fdc_wait_result
    jc      fd_fail
    mov     byte ptr [dma_rc], 4
    mov     si, offset res
    mov     cx, 7
fd_res:
    call    fdc_in
    jc      fd_fail
    mov     [si], al
    inc     si
    loop    fd_res
    mov     byte ptr [dma_rc], 0
    jmp     fd_end
fd_fail:
    mov     byte ptr [dma_dead], 1  /* the FDC is in an unknown phase: no more DMA runs */
fd_end:
    mov     al, 0x06                /* mask channel 2 again */
    out     0x15, al
    call    iowait
    in      al, 0x11
    mov     [dmast], al
    in      al, 0x90
    mov     [msr_after], al
    pop     si
    pop     dx
    pop     cx
    pop     ebx
    pop     eax
    ret

/* fdc_wait_idle: CF on timeout. Idle = RQM set, DIO clear, CB clear. */
fdc_wait_idle:
    push    cx
    push    dx
    mov     dx, TMO_HI
fwi_o:
    xor     cx, cx
fwi_i:
    in      al, 0x90
    and     al, 0xD0
    cmp     al, 0x80
    je      fwi_ok
    loop    fwi_i
    dec     dx
    jnz     fwi_o
    pop     dx
    pop     cx
    stc
    ret
fwi_ok:
    pop     dx
    pop     cx
    clc
    ret

/* fdc_out: AL -> the data register when RQM=1 DIO=0. CF on timeout. */
fdc_out:
    push    cx
    push    dx
    mov     ah, al
    mov     dx, TMO_HI
fo_o:
    xor     cx, cx
fo_i:
    in      al, 0x90
    and     al, 0xC0
    cmp     al, 0x80
    je      fo_go
    loop    fo_i
    dec     dx
    jnz     fo_o
    pop     dx
    pop     cx
    stc
    ret
fo_go:
    mov     al, ah
    out     0x92, al
    call    fdc_settle              /* the BIOS's MSR settle, BANK7@0x71CD */
    pop     dx
    pop     cx
    clc
    ret

/* fdc_wait_result: RQM=1 DIO=1 (the result phase). CF on timeout. */
fdc_wait_result:
    push    cx
    push    dx
    mov     dx, TMO_HI
fwr_o:
    xor     cx, cx
fwr_i:
    in      al, 0x90
    and     al, 0xC0
    cmp     al, 0xC0
    je      fwr_ok
    loop    fwr_i
    dec     dx
    jnz     fwr_o
    pop     dx
    pop     cx
    stc
    ret
fwr_ok:
    pop     dx
    pop     cx
    clc
    ret

/* fdc_in: the data register -> AL when RQM=1 DIO=1. CF on timeout. */
fdc_in:
    push    cx
    push    dx
    mov     dx, TMO_HI
fi_o:
    xor     cx, cx
fi_i:
    in      al, 0x90
    and     al, 0xC0
    cmp     al, 0xC0
    je      fi_go
    loop    fi_i
    dec     dx
    jnz     fi_o
    pop     dx
    pop     cx
    stc
    ret
fi_go:
    in      al, 0x92
    call    fdc_settle
    pop     dx
    pop     cx
    clc
    ret

/* irq_drain: interrupts are off and IR11 is masked. Put the probe's EOI-only handler on
 * vector 0x13, restore the run's as-found slave IMR, let interrupts in for a moment (an FDC
 * request the PIC holds - or NP2kai's delayed one - is taken by the probe's handler), then
 * put the BIOS vector back. */
irq_drain:
    push    ax
    push    cx
    push    dx
    push    es
    mov     word ptr [irq_cnt], 0
    xor     ax, ax
    mov     es, ax
    mov     word ptr es:[0x4C], offset irq_eoi
    mov     es:[0x4E], cs
    mov     al, [imr_run]
    out     0x0A, al
    call    iowait
    sti
    mov     dx, 16
id_o:
    mov     cx, 0x4000
id_i:
    out     0x5F, al
    loop    id_i
    dec     dx
    jnz     id_o
    cli
    xor     ax, ax
    mov     es, ax
    mov     ax, [vec13_off]
    mov     es:[0x4C], ax
    mov     ax, [vec13_seg]
    mov     es:[0x4E], ax
    pop     es
    pop     dx
    pop     cx
    pop     ax
    ret

irq_eoi:
    push    ax
    inc     word ptr cs:[irq_cnt]
    mov     al, 0x20
    out     0x08, al                /* slave EOI */
    out     0x00, al                /* master EOI (the slave cascades on IR7) */
    pop     ax
    iret

/* ------------------------------------------------------------------ */
/* output                                                               */
/* ------------------------------------------------------------------ */
print_dma:
    mov     si, offset msg_dma
    call    puts
    mov     al, [bios_rd2]
    call    puthex8
    mov     si, offset msg_same
    call    puts
    mov     al, [same]
    call    puthex8
    mov     si, offset msg_rc
    call    puts
    mov     al, [dma_rc]
    call    puthex8
    mov     si, offset msg_st
    call    puts
    mov     si, offset res
    mov     cx, 7
    call    puthexbuf
    mov     si, offset msg_d11
    call    puts
    mov     al, [dmast_pre]
    call    puthex8
    mov     al, '/'
    call    putch
    mov     al, [dmast]
    call    puthex8
    mov     si, offset msg_msr
    call    puts
    mov     al, [msr_after]
    call    puthex8
    mov     si, offset msg_irq
    call    puts
    mov     ax, [irq_cnt]
    call    puthex16
    call    crlf
    ret

/* print_view: DX = view index of the case at [cur]. */
print_view:
    push    bx
    push    cx
    push    dx
    push    si
    mov     bx, [cur]
    mov     si, dx
    shl     si, 3
    add     si, bx
    add     si, C_VIEWS
    mov     al, [si+V_KIND]
    mov     [vkind], al
    call    view_len                /* CX */
    mov     [vcnt], cx
    mov     [vidx], dl
    push    si
    mov     al, 'V'
    call    putch
    mov     al, [vidx]
    add     al, '0'
    call    putch
    mov     si, offset msg_vstate
    call    puts
    pop     si
    push    si
    mov     al, [si+V_STATE]
    mov     ah, [si+V_BA]
    mov     dl, [si+V_BB]
    call    print_state
    mov     si, offset msg_vat
    call    puts
    pop     si
    push    si
    mov     ax, [si+V_SEG]
    call    puthex16
    mov     al, ':'
    call    putch
    mov     ax, [si+V_OFF]
    call    puthex16
    mov     si, offset msg_vkind
    call    puts
    pop     si
    mov     al, [si+V_KIND]
    mov     si, offset kname_mem
    cmp     al, K_MEM
    je      pv_k
    mov     si, offset kname_odd
    cmp     al, K_ODD
    je      pv_k
    mov     si, offset kname_cgp
pv_k:
    call    puts
    mov     si, offset msg_vn
    call    puts
    mov     al, [vcnt]
    call    puthex8
    call    crlf
    /* the three byte lines */
    xor     bx, bx
    mov     bl, [vidx]
    shl     bx, 5
    mov     si, offset msg_orig
    mov     di, offset orig
    call    pv_line
    mov     si, offset msg_pre
    mov     di, offset pre
    call    pv_line
    mov     si, offset msg_post
    mov     di, offset post
    call    pv_line
    pop     si
    pop     dx
    pop     cx
    pop     bx
    ret

pv_line:                                /* SI = label, DI = buffer base, BX = view offset */
    push    si
    mov     al, 'V'
    call    putch
    mov     al, [vidx]
    add     al, '0'
    call    putch
    pop     si
    call    puts
    lea     si, [di+bx]
    mov     cx, [vcnt]
    call    puthexbuf
    call    crlf
    ret

/* print_state: AL = state, AH = bank A, DL = bank B. */
print_state:
    push    ax
    push    bx
    push    si
    xor     bx, bx
    mov     bl, al
    shl     bx, 1
    mov     si, [sname+bx]
    call    puts
    cmp     al, ST_PEG
    jne     pst_r
    mov     al, '/'
    call    putch
    mov     al, ah
    call    puthex8
    mov     al, '/'
    call    putch
    mov     al, dl
    call    puthex8
pst_r:
    pop     si
    pop     bx
    pop     ax
    ret

/* print_phys: AX = segment, DX = offset -> 8 hex digits. */
print_phys:
    push    eax
    push    edx
    movzx   eax, ax
    shl     eax, 4
    movzx   edx, dx
    add     eax, edx
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
    call    puthex16
    pop     edx
    pop     eax
    ret

putch:                                  /* AL */
    push    ax
    push    dx
    mov     dl, al
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     ax
    ret

crlf:
    push    si
    mov     si, offset msg_crlf
    call    puts
    pop     si
    ret

puts:                                   /* DS:SI, NUL terminated */
    push    ax
    push    si
ps_loop:
    mov     al, [si]
    test    al, al
    jz      ps_done
    call    putch
    inc     si
    jmp     ps_loop
ps_done:
    pop     si
    pop     ax
    ret

puthexbuf:                              /* DS:SI, CX bytes, no separators */
    push    ax
    push    cx
    push    si
    jcxz    phb_d
phb_l:
    mov     al, [si]
    call    puthex8
    inc     si
    loop    phb_l
phb_d:
    pop     si
    pop     cx
    pop     ax
    ret

puthex16:                               /* AX */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

puthex8:                                /* AL */
    push    ax
    push    ax
    shr     al, 4
    call    ph_nib
    pop     ax
    and     al, 0x0F
    call    ph_nib
    pop     ax
    ret
ph_nib:
    add     al, '0'
    cmp     al, '9'
    jbe     ph_out
    add     al, 'A' - '9' - 1
ph_out:
    call    putch
    ret

/* ------------------------------------------------------------------ */
/* the case table                                                       */
/* ------------------------------------------------------------------ */
/* case: name, state, bankA, bankB, LEN, nviews, pad, seg, off; then 4 views of
 *       state, bankA, bankB, kind, seg, off. */
    .macro CASE name, st, ba, bb, len, nv, seg, off
    .word \name
    .byte \st, \ba, \bb, \len, \nv, 0
    .word \seg, \off
    .endm
    .macro VIEW st, ba, bb, kind, seg, off
    .byte \st, \ba, \bb, \kind
    .word \seg, \off
    .endm
    .macro NOVIEW
    .byte 0, 0, 0, 0
    .word 0, 0
    .endm

    .balign 2
cases:
case_c0:
    CASE    nm_c0, ST_NORMAL, 0xFF, 0xFF, 32, 1, 0, 0       /* patched at start */
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0, 0
    NOVIEW
    NOVIEW
    NOVIEW
    CASE    nm_e1, ST_EMS22, 0xFF, 0xFF, 32, 3, 0xB000, 0x0200
    VIEW    ST_EMS22,  0xFF, 0xFF, K_MEM, 0xB000, 0x0200
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xB000, 0x0200
    VIEW    ST_EMS24,  0xFF, 0xFF, K_MEM, 0xB000, 0x0200
    NOVIEW
    CASE    nm_e2, ST_EMS24, 0xFF, 0xFF, 32, 3, 0xB000, 0x0200
    VIEW    ST_EMS22,  0xFF, 0xFF, K_MEM, 0xB000, 0x0200
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xB000, 0x0200
    VIEW    ST_EMS24,  0xFF, 0xFF, K_MEM, 0xB000, 0x0200
    NOVIEW
    CASE    nm_p1, ST_PEG, 0x05, 0x06, 32, 3, 0xA800, 0x0100
    VIEW    ST_PEG,    0x05, 0x06, K_MEM, 0xA800, 0x0100
    VIEW    ST_PEG,    0x05, 0x05, K_MEM, 0xB000, 0x0100
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xA800, 0x0100
    NOVIEW
    CASE    nm_p2, ST_PEG, 0x05, 0x06, 32, 3, 0xB000, 0x0100
    VIEW    ST_PEG,    0x05, 0x06, K_MEM, 0xB000, 0x0100
    VIEW    ST_PEG,    0x06, 0x06, K_MEM, 0xA800, 0x0100
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xB000, 0x0100
    NOVIEW
    CASE    nm_p3, ST_PEG, 0x05, 0x06, 32, 2, 0xB800, 0x0100
    VIEW    ST_PEG,    0x05, 0x06, K_MEM, 0xB800, 0x0100
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xB800, 0x0100
    NOVIEW
    NOVIEW
    CASE    nm_p4, ST_PEG, 0xFF, 0xFF, 4, 2, 0xE000, 0x0004
    VIEW    ST_PEG,    0xFF, 0xFF, K_MEM, 0xE000, 0x0004
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xE000, 0x0004
    NOVIEW
    NOVIEW
    CASE    nm_w1, ST_W0A, 0xFF, 0xFF, 32, 3, 0x8000, 0x8100
    VIEW    ST_W0A,    0xFF, 0xFF, K_MEM, 0x8000, 0x8100
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xA800, 0x0100
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0x8000, 0x8100
    NOVIEW
    CASE    nm_w2, ST_W0A, 0xFF, 0xFF, 32, 3, 0x8000, 0x1000
    VIEW    ST_W0A,    0xFF, 0xFF, K_MEM, 0x8000, 0x1000
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0xA000, 0x1000
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0x8000, 0x1000
    NOVIEW
    CASE    nm_w3, ST_W10, 0xFF, 0xFF, 32, 2, 0x9000, 0xF000
    VIEW    ST_W10,    0xFF, 0xFF, K_MEM, 0x9000, 0xF000
    VIEW    ST_NORMAL, 0xFF, 0xFF, K_MEM, 0x9000, 0xF000
    NOVIEW
    NOVIEW
    CASE    nm_g1, ST_CG, 0xFF, 0xFF, 32, 2, 0xA400, 0x0000
    VIEW    ST_CG,     0xFF, 0xFF, K_ODD, 0xA400, 0x0001
    VIEW    ST_CG,     0xFF, 0xFF, K_CGP, 0, 0
    NOVIEW
    NOVIEW
    .word   0                       /* end of the table */

nm_c0:  .asciz "C0"
nm_e1:  .asciz "E1"
nm_e2:  .asciz "E2"
nm_p1:  .asciz "P1"
nm_p2:  .asciz "P2"
nm_p3:  .asciz "P3"
nm_p4:  .asciz "P4"
nm_w1:  .asciz "W1"
nm_w2:  .asciz "W2"
nm_w3:  .asciz "W3"
nm_g1:  .asciz "G1"

    .balign 2
sname:  .word sn0, sn1, sn2, sn3, sn4, sn5, sn6
sn0:    .asciz "NORMAL"
sn1:    .asciz "EMS22"
sn2:    .asciz "EMS24"
sn3:    .asciz "PEG"
sn4:    .asciz "W0A"
sn5:    .asciz "W10"
sn6:    .asciz "CG"
kname_mem: .asciz "MEM"
kname_odd: .asciz "ODD"
kname_cgp: .asciz "CGPORT"

/* the prefill keys, one per view */
keys:   .byte 0x5A, 0xA5, 0x3C, 0xC3

msg_begin:  .asciz "BEGIN:DMAROUTE\r\nDMAROUTE - where a uPD71071 DMA byte lands in a memory window (tools/hwprobe/dmaroute)\r\n"
msg_found:  .asciz "FOUND 0461="
msg_6a:     .asciz " 6A="
msg_q:      .asciz " 9A0_04/07/08/0A="
msg_imr:    .asciz " IMR="
msg_vec:    .asciz " VEC13="
msg_disk:   .asciz "DISK DA="
msg_bsense: .asciz " SENSE="
msg_fdc:    .asciz "FDC 0090="
msg_f94:    .asciz " 0094="
msg_fbe:    .asciz " 00BE="
msg_f4be:   .asciz " 04BE="
msg_f480:   .asciz " 0480="
msg_f485:   .asciz " 0485="
msg_f5cb:   .asciz " 05CB="
msg_using:  .asciz "USING DA="
msg_dok:    .asciz " OK\r\n"
msg_dfail:  .asciz " DIRECT-FAILED (the BIOS read works; the DMA runs report their own RC)\r\n"
msg_dcpu:   .asciz " (BIOS read; /CPU: no direct check)\r\n"
msg_direct: .asciz "DIRECT U="
msg_dst3:   .asciz " ST3="
msg_dmotor: .asciz " MOTOR="
msg_dash:   .asciz "--"
msg_drecal: .asciz " RECAL ST0="
msg_dpcn:   .asciz " PCN="
msg_drid:   .asciz " READID="
msg_dfail_at: .asciz " FAIL="
st_idle:    .asciz "IDLE"
st_sds1:    .asciz "SDS1"
st_sds2:    .asciz "SDS2"
st_nrdy:    .asciz "NOTREADY"
st_recal:   .asciz "RECAL"
st_rtmo:    .asciz "RECALTMO"
st_rid:     .asciz "READID"
st_itmo:    .asciz "READIDTMO"
st_unk:     .asciz "?"
msg_rfd:    .asciz "RESTORE 00BE/04BE was="
msg_rfd2:   .asciz " (the BIOS sets both per INT 1Bh DA/UA and keeps its own record; the probe never writes them) USING DA="
msg_r94:    .asciz "RESTORE 0094 written="
msg_r485:   .asciz " 0485 now="
msg_r94b:   .asciz " (0094 is write-only: handed back as the BIOS leaves it, 0485<-05CB, 0094<-09,0C; the BIOS's countdown stops the motor)\r\n"
msg_recal:  .asciz " RECAL="
msg_rid:    .asciz " READID="
msg_chrn:   .asciz " CHRN="
msg_rd:     .asciz " READ="
msg_len:    .asciz " SECLEN="
msg_nodisk: .asciz "NODISK the sector could not be read: no DMA source, nothing tested\r\n"
msg_sector: .asciz "SECTOR "
msg_keys:   .asciz "KEYS "
msg_bcase:  .asciz "BEGIN:CASE "
msg_ecase:  .asciz "END:CASE "
msg_dmaskip: .asciz "DMA SKIPPED an earlier DMA run left the FDC in an unknown phase\r\n"
msg_run:    .asciz "RUN "
msg_xcpu:   .asciz " XFER=CPU"
msg_xdma:   .asciz " XFER=DMA"
msg_state:  .asciz " STATE="
msg_dst:    .asciz " DST="
msg_lenk:   .asciz " LEN="
msg_dma:    .asciz "DMA BIOS="
msg_same:   .asciz " SAME="
msg_rc:     .asciz " RC="
msg_st:     .asciz " RES="
msg_d11:    .asciz " ST11="
msg_msr:    .asciz " MSR="
msg_irq:    .asciz " IRQ11="
msg_vstate: .asciz " STATE="
msg_vat:    .asciz " AT="
msg_vkind:  .asciz " KIND="
msg_vn:     .asciz " N="
msg_orig:   .asciz " ORIG="
msg_pre:    .asciz " PRE="
msg_post:   .asciz " POST="
msg_brest:  .asciz "BEGIN:RESTORE\r\n"
msg_r461:   .asciz "RESTORE 0461 was="
msg_r6a:    .asciz "RESTORE 6A/9A0 was="
msg_rimr:   .asciz "RESTORE IMR was="
msg_rvec:   .asciz "RESTORE VEC13 was="
msg_rfixed: .asciz "RESTORE 043F=20 A1/A3/A5=00 DMA ch2 masked (write-only: set, not read back)\r\n"
msg_now:    .asciz " now="
msg_erest:  .asciz "END:RESTORE\r\n"
msg_end:    .asciz "END:DMAROUTE\r\n"
msg_crlf:   .asciz "\r\n"

/* ------------------------------------------------------------------ */
/* state                                                                */
/* ------------------------------------------------------------------ */
    .balign 4
dma_phys:   .long 0
da:         .byte 0x90
da_user:    .byte 0x90
da_given:   .byte 0
fb_da:      .byte 0
fd_be:      .byte 0
fd_4be:     .byte 0
m_wrote:    .byte 0
d_us:       .byte 0
d_ok:       .byte 0
d_mwr:      .byte 0
d_st3a:     .byte 0
d_st3b:     .byte 0
d_st0:      .byte 0
d_pcn:      .byte 0
d_rid:      .space 8
f_res:      .space 8
/* the scan: 2HD 1 MB, 1.44 MB, 640 KB 2DD - units 0 and 1, all on the 1 MB interface */
da_list:    .byte 0x90, 0x91, 0x30, 0x31, 0x10, 0x11, 0
cpu_only:   .byte 0
dma_dead:   .byte 0
w0_rb:      .byte 0
w0_found:   .byte 0x08
mode_found: .byte 0
q16:        .byte 0
qegc:       .byte 0
qwren:      .byte 0
q256:       .byte 0
imr_found:  .byte 0
mimr_found: .byte 0
imr_run:    .byte 0
cur_state:  .byte 0
xkind:      .byte 0
vop:        .byte 0
vkind:      .byte 0
vidx:       .byte 0
bios_recal: .byte 0
bios_rid:   .byte 0
bios_rd:    .byte 0
bios_rd2:   .byte 0
same:       .byte 0
rid_c:      .byte 0
rid_h:      .byte 0
rid_r:      .byte 0
rid_n:      .byte 0
dma_rc:     .byte 0
dmast_pre:  .byte 0
dmast:      .byte 0
msr_after:  .byte 0
res:        .space 7
    .balign 4
art_t0:     .long 0
irq_cnt:    .word 0
d_step:     .word 0
fr_spin:    .word 0
vec13_off:  .word 0
vec13_seg:  .word 0
cur:        .word 0
vcnt:       .word 0
seclen:     .word 0
secbuf:     .word 0
secbuf2:    .word 0
ctrl_off:   .word 0

    .balign 16
exp:        .space VMAX*VLEN
pf:         .space VMAX*VLEN
orig:       .space VMAX*VLEN
pre:        .space VMAX*VLEN
post:       .space VMAX*VLEN
ctrlarea:   .space 64
secarea:    .space 2048
secarea2:   .space 2048
