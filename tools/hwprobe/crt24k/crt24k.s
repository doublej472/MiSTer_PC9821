/* crt24k.s - the PC-9821's 24 kHz guest frame, timed against TWO references.
 *
 *   CRT24K > CRT24K.TXT          (or RUN24K.BAT)
 *
 * WHY. `crt31k` times the guest's frame with the ARTIC counter (0x5C/0x5F,
 * 307200 Hz). In the 24 kHz mode the Xe10 capture (docs/probes/CRT31K.TXT) reads
 * 326 698-326 700 ARTIC ticks per 60 frames and the core 326 672-326 675 (its model
 * is 326 674.0: 848 x 440 dots at 400/19 MHz). Every number in that comparison
 * comes from one counter, so the ~77 ppm between the two machines cannot say
 * whether the frame or the ARTIC crystal differs. (A 2026-10-17 card report of
 * 326 872-326 875, a "~600 ppm long" frame, was the screenshot font's 6 read as an
 * 8; the screenshots themselves read 326 672-326 675.) This probe times the SAME
 * frames against a second, independent device counter in the same run:
 *
 *   ARTIC   0x5C low word / 0x5F high byte, the free-running 307 200 Hz tick.
 *   PIT     channel 0, latched through 0x77 <- 00 and read at 0x71 (two bytes).
 *           The BIOS programs it to 100 Hz; the 8253/71054 input is 2.4576 MHz
 *           with the documented 0x6000 divisor, or 1.9968 MHz with 0x4E00 when
 *           the BIOS work-area 0x0501 bit-7 strap selects the other oscillator.
 *           The READ element has more than one convention in the field:
 *             - the Xe10 counts ONCE per oscillator clock (8 raw counts per
 *               ARTIC tick), range 0..0x6000;
 *             - a standard 8253 mode-3 element counts 2*count, range
 *               0..0xC000 (the core's pc9821_pit models this);
 *             - this core's profile-0 image reads a FREE-RUNNING 16-bit
 *               counter (top 0xFFF7, wraps through 0), range 0..0x10000.
 *           The probe MEASURES which: the largest coherent latched word over
 *           30 ms names the modulus, and a 1 ms element/ARTIC ratio (~8 vs ~16,
 *           or 6.5 vs 13 on the 1.9968 MHz strap) names the x1/x2 element.
 *           The device rate is used, not the ARTIC, so the cross-check stays
 *           independent.
 *
 * METHOD. Each run waits for a rising VSYNC (master GDC status bit 5) by polling
 * 0x60 tightly, then latches the PIT once and reads the ARTIC once; it repeats
 * for 60 edges and samples both counters at the last edge. Both samples are
 * taken in the same instruction sequence at the two ends, so the fixed sampling
 * offset cancels and only the poll's ~1 us quantisation remains (~50 ppm on a
 * 17.7 ms frame, ~1 ppm over the 60-frame window, while the ARTIC row keeps
 * its ~3 ppm resolution). The timeout is crt31k's ARTIC deadline (61440 ticks =
 * 0.2 s), checked every 256 polls: a fixed 60000-poll guard was shorter than
 * one 24 kHz frame's low phase on the core's fast I/O and timed out every run.
 *
 * A 16-bit PIT word cannot span 1.77 periods, so the number of whole wraps is
 * resolved from the ARTIC estimate: total = (p0 - p1) + wraps*mod, with
 * wraps = round((artic * rate / 307200 - (p0 - p1)) / mod). The ARTIC chooses
 * only the integer wrap count; a wrong pick is a ~1 % PIT-vs-ARTIC jump and the
 * decoder flags it. The printed `pit` is the resolved count in source clocks at
 * `hz`, with `pit_raw` and `pit_expected` beside it for the check.
 *
 * WHAT IT WRITES. The PIT latch command 0x77 <- 00 copies the counter, changes no
 * state, and the 0x71 reads are consumed in pairs (the read pointer returns to
 * where it started). No other port is written; 0x09A8 is only read. A run under
 * `cli` lasts ~1.06 s, so the BIOS timer interrupt is late by that much on each of
 * the three runs - the usual cost of `crt31k`'s measurement, and the PIT itself
 * keeps counting. REBOOT is not needed (nothing is reprogrammed).
 *
 * SAFETY. No disk access except DOS stdout; no memory writes outside this
 * program. A VSYNC that does not arrive within 0.2 s ends that run with
 * `TIMEOUT` and the next run starts; output is always one line per run.
 *
 * BUILD: make -C tools/hwprobe crt24k/crt24k.com
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

    .equ NFRAMES, 60
    .equ RUNS, 3
    .equ EDGE_TIMEOUT, 61440            /* ARTIC ticks (0.2 s), as crt31k */
    .equ EDGE_CHECK, 0x100              /* polls between ARTIC deadline checks */

_start:
    mov     si, offset msg_begin
    call    puts

    mov     dx, 0x09A8
    in      al, dx
    mov     [p9a8], al
    mov     si, offset msg_mode
    call    puts
    mov     al, [p9a8]
    call    puthex8
    call    crlf

    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     al, [0x0501]
    pop     ds
    mov     [strap], al
    call    pit_div_probe
    call    pit_ratio_probe
    call    pit_snap_div
    call    report_div

    mov     byte ptr [run_no], 0
mr_runs:
    inc     byte ptr [run_no]
    call    measure_run
    cmp     byte ptr [run_no], RUNS
    jb      mr_runs

    mov     si, offset msg_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* measure_run: one cli window, NFRAMES rising VSYNC edges, ARTIC + PIT. */
measure_run:
    cli
    mov     dword ptr [pit_total], 0
    mov     dword ptr [pit_raw], 0
    mov     dword ptr [pit_expected], 0
    mov     byte ptr [pit_ok], 0
    call    wait_edge                 /* start edge */
    jc      mrun_timeout
    call    pit_sample_once
    jc      mrun_nopit0
    mov     [pit0], ax
    mov     byte ptr [pit_ok], 1
    jmp     mrun_a0
mrun_nopit0:
    mov     byte ptr [pit_ok], 0
mrun_a0:
    call    artic_read
    mov     [a0], eax
    mov     cx, NFRAMES
mrun_edges:
    call    wait_edge
    jc      mrun_timeout
    loop    mrun_edges
    call    pit_sample_once
    jc      mrun_nopit1
    mov     [pit1], ax
    jmp     mrun_a1
mrun_nopit1:
    mov     byte ptr [pit_ok], 0
mrun_a1:
    call    artic_read
    mov     [a1], eax
    sti

    mov     eax, [a1]
    sub     eax, [a0]
    and     eax, 0x00FFFFFF
    mov     [artic_delta], eax

    cmp     byte ptr [pit_ok], 0
    je      mrun_report

    /* diff = pit0 - pit1 (signed): the decrease inside the last period. The
     * total is diff + wraps*mod, NOT (pit1-pit0 mod mod) + k*mod - that form
     * cannot represent a total whose start phase is on the other side of the
     * wrap, and on the core's 65536 modulus it read 6120 ppm low. */
    movzx   eax, word ptr [pit0]
    movzx   ebx, word ptr [pit1]
    sub     eax, ebx
    mov     [pit_diff], eax

    /* raw for the capture: (pit1 - pit0) mod mod, the partial period */
    movzx   eax, word ptr [pit1]
    movzx   ebx, word ptr [pit0]
    sub     eax, ebx
    jns     mrun_raw_pos
    mov     ecx, [pit_mod]
    add     eax, ecx
mrun_raw_pos:
    mov     [pit_raw_e], eax

    /* expected = artic_delta * pit_eff_hz / 307200 (element counts) */
    mov     eax, [artic_delta]
    mov     ecx, [pit_eff_hz]
    mul     ecx
    mov     ecx, 307200
    div     ecx
    mov     [pit_expected_e], eax

    /* wraps = round((expected - diff) / mod); total_element = diff + wraps*mod */
    mov     ecx, [pit_expected_e]
    sub     ecx, [pit_diff]
    mov     ebx, [pit_mod]
    mov     edx, ebx
    shr     edx, 1
    add     ecx, edx
    mov     eax, ecx
    xor     edx, edx
    div     ebx
    mov     ecx, eax
    mov     eax, [pit_mod]
    imul    eax, ecx
    add     eax, [pit_diff]

    /* The printed pit/raw/expected are SOURCE clocks at pit_hz: on the core's
     * mode-3 counting element (2*count) the element counts are twice the source
     * clocks, so halve them there. */
    cmp     byte ptr [pit_x2], 0
    je      mrun_el_x1
    shr     eax, 1
mrun_el_x1:
    mov     [pit_total], eax

    mov     eax, [pit_raw_e]
    cmp     byte ptr [pit_x2], 0
    je      mrun_raw_x1
    shr     eax, 1
mrun_raw_x1:
    mov     [pit_raw], eax

    mov     eax, [pit_expected_e]
    cmp     byte ptr [pit_x2], 0
    je      mrun_exp_x1
    shr     eax, 1
mrun_exp_x1:
    mov     [pit_expected], eax

mrun_report:
    call    report_run
    ret

mrun_timeout:
    sti
    mov     si, offset msg_run
    call    puts
    movzx   eax, byte ptr [run_no]
    call    putdec32
    mov     si, offset msg_timeout
    call    puts
    ret

/* wait_edge: wait for a falling then a rising VSYNC, polling master-GDC status
 * (0x60 bit 5) as tightly as the I/O port allows. The timeout is the ARTIC
 * deadline crt31k uses (61440 ticks = 0.2 s), not a fixed poll count: the
 * core's I/O is fast enough that 60000 polls did not span one 24 kHz frame's
 * low phase. The ARTIC is read once per EDGE_CHECK polls, so the edge-detection
 * jitter stays at the poll interval. CF=1 on a stuck line. */
wait_edge:
    push    ebx
    call    artic_read
    mov     ebx, eax
    mov     dx, EDGE_CHECK
we_fall:
    in      al, 0x60
    test    al, 0x20
    jz      we_rise_start
    dec     dx
    jnz     we_fall
    call    we_check
    jc      we_timeout
    mov     dx, EDGE_CHECK
    jmp     we_fall
we_rise_start:
    mov     dx, EDGE_CHECK
we_rise:
    in      al, 0x60
    test    al, 0x20
    jnz     we_ok
    dec     dx
    jnz     we_rise
    call    we_check
    jc      we_timeout
    mov     dx, EDGE_CHECK
    jmp     we_rise
we_ok:
    pop     ebx
    clc
    ret
we_timeout:
    pop     ebx
    stc
    ret

/* we_check: CF=1 if more than EDGE_TIMEOUT ARTIC ticks have passed since EBX. */
we_check:
    push    eax
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, EDGE_TIMEOUT
    cmc
    pop     eax
    ret

/* pit_sample_once: AX = one coherent latched count; CF=1 if three tries tear. */
pit_sample_once:
    mov     byte ptr [ps_try], 0
pso_retry:
    call    pit_read_pair
    jnc     pso_ok
    inc     byte ptr [ps_try]
    cmp     byte ptr [ps_try], 3
    jb      pso_retry
    stc
    ret
pso_ok:
    clc
    ret

/* pit_read_pair: two words -> AX; CF=1 when they disagree by more than 64
 * counts (a torn latch word). BX/CX clobbered, others preserved. */
pit_read_pair:
    call    pit_read
    mov     bx, ax
    call    pit_read
    mov     cx, bx
    sub     cx, ax
    jns     prp_abs
    neg     cx
prp_abs:
    cmp     cx, 64
    ja      prp_bad
    clc
    ret
prp_bad:
    stc
    ret

/* report_div: the measured and snapped PIT divisor, its rate, the 0x0501 strap. */
report_div:
    mov     si, offset msg_div
    call    puts
    mov     ax, [div_max]
    call    puthex16
    mov     si, offset msg_mod
    call    puts
    mov     eax, [pit_mod]
    call    putdec32
    mov     si, offset msg_hz
    call    puts
    mov     eax, [pit_hz]
    call    putdec32
    mov     si, offset msg_ratio
    call    puts
    mov     eax, [ratio_milli]
    call    putdec32
    mov     si, offset msg_x2
    call    puts
    movzx   eax, byte ptr [pit_x2]
    call    putdec32
    mov     si, offset msg_strap
    call    puts
    mov     al, [strap]
    call    puthex8
    call    crlf
    ret

/* report_run: one line, both references, rates and frame periods. */
report_run:
    mov     si, offset msg_run
    call    puts
    movzx   eax, byte ptr [run_no]
    call    putdec32

    mov     si, offset msg_frames
    call    puts
    mov     ax, NFRAMES
    call    putdec32

    mov     si, offset msg_artic
    call    puts
    mov     eax, [artic_delta]
    call    putdec32

    mov     si, offset msg_pit
    call    puts
    mov     eax, [pit_total]
    call    putdec32

    mov     si, offset msg_pitok
    call    puts
    movzx   eax, byte ptr [pit_ok]
    call    putdec32

    mov     si, offset msg_pitdiv
    call    puts
    mov     eax, [pit_mod]
    call    putdec32

    mov     si, offset msg_pitraw
    call    puts
    mov     eax, [pit_raw]
    call    putdec32

    mov     si, offset msg_pitexp
    call    puts
    mov     eax, [pit_expected]
    call    putdec32

    /* ARTIC fps = 307200 * frames * 10000 / ticks */
    mov     si, offset msg_afps
    call    puts
    mov     eax, 307200
    mov     ecx, NFRAMES
    imul    eax, ecx
    mov     ecx, 10000
    mul     ecx
    mov     ecx, [artic_delta]
    div     ecx
    call    putfixed4

    /* PIT fps = pit_hz * frames * 10000 / pit_total (when the sample was good) */
    mov     si, offset msg_pfps
    call    puts
    cmp     byte ptr [pit_ok], 0
    je      rr_pfps_zero
    mov     eax, [pit_hz]
    mov     ecx, NFRAMES
    imul    eax, ecx
    mov     ecx, 10000
    mul     ecx
    mov     ecx, [pit_total]
    div     ecx
    call    putfixed4
    jmp     rr_ans
rr_pfps_zero:
    xor     eax, eax
    call    putfixed4

rr_ans:
    /* ARTIC frame ns*10 = (ticks*1e9/307200)*10/frames */
    mov     si, offset msg_ans
    call    puts
    mov     eax, [artic_delta]
    mov     ebx, 307200
    mov     ecx, NFRAMES
    call    calc_ns10
    call    putfixed1

    /* PIT frame ns*10 */
    mov     si, offset msg_pns
    call    puts
    cmp     byte ptr [pit_ok], 0
    je      rr_pns_zero
    mov     eax, [pit_total]
    mov     ebx, [pit_hz]
    mov     ecx, NFRAMES
    call    calc_ns10
    call    putfixed1
    jmp     rr_done
rr_pns_zero:
    xor     eax, eax
    call    putfixed1
rr_done:
    call    crlf
    ret

/* calc_ns10: EAX = count, EBX = rate_hz, ECX = frames -> EAX = ns*10. */
calc_ns10:
    push    edx
    push    ebx
    push    ecx
    mov     ecx, 1000000000
    mul     ecx
    mov     ecx, ebx
    div     ecx
    mov     ecx, 10
    mul     ecx
    pop     ecx
    div     ecx
    pop     ebx
    pop     edx
    ret

/* ------------------------------------------------------------------ */
/* the PIT: latch + two-byte read, byte order measured                  */
/* ------------------------------------------------------------------ */
pit_latch:
    push    ax
    push    dx
    mov     dx, 0x0077
    xor     al, al
    out     dx, al
    pop     dx
    pop     ax
    ret

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

/* pit_cal: the byte that falls more often is the LSB (the counter counts down);
 * the latch does not restore the read pointer on this machine, so the order can
 * differ between runs and is measured, not assumed. */
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

pit_word:
    /* The byte order is MEASURED by pit_cal and used verbatim. Do NOT reject a
     * word above pit_div: this core's mode-3 counting element is 2*count and
     * ranges to 2*divisor (0xC000 at 0x6000), while the Xe10's element counts
     * once per clock and ranges to the divisor. The >divisor heuristic made
     * every legitimate core word above 0x6000 byte-swap (the core capture read
     * 0xFFEB and a bogus 106 ppm PIT-vs-ARTIC). */
    call    pit_bytes
    mov     al, [pit_b1]
    mov     ah, [pit_b2]
    cmp     byte ptr [pit_swap], 0
    je      pw_done
    mov     al, [pit_b2]
    mov     ah, [pit_b1]
pw_done:
    ret

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

/* pit_div_probe: the largest coherent latched word over 30 ms of ARTIC ticks
 * (9216). Mode 3 reloads at the divisor, so the maximum is the divisor or a step
 * below; report_div snaps it to the two documented values. */
pit_div_probe:
    push    eax
    push    ebx
    push    dx
    mov     word ptr [div_max], 0
    call    artic_read
    mov     [div_a0], eax
    mov     word ptr [div_guard], 0x4000
pdp_loop:
    call    pit_read_pair
    jc      pdp_next
    cmp     ax, [div_max]
    jbe     pdp_next
    mov     [div_max], ax
pdp_next:
    call    artic_read
    sub     eax, [div_a0]
    and     eax, 0x00FFFFFF
    cmp     eax, 9216
    jae     pdp_done
    dec     word ptr [div_guard]
    jnz     pdp_loop
pdp_done:
    pop     dx
    pop     ebx
    pop     eax
    ret

/* pit_ratio_probe: element counts per ARTIC tick over up to eight 1 ms windows.
 * This detects the two read-element conventions without assuming either:
 *   Xe10   mode 3 counts once per oscillator clock -> ~8.0 (or 6.5 on the
 *          1.9968 MHz strap);
 *   this core's pc9821_pit models the standard 8253 half-period element,
 *          2*count -> ~16.0 (or 13.0).
 * A window whose word increased wrapped and is rejected. The result only sets
 * the read convention; the frame rate still uses the device rate (pit_hz), not
 * the ARTIC, so the cross-check stays independent. */
pit_ratio_probe:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     dword ptr [ratio_sum], 0
    mov     word ptr [ratio_n], 0
    mov     byte ptr [rd_try], 8
prp_window:
    call    artic_read
    mov     [ra0], eax
    call    pit_sample_once
    jc      prp_next
    mov     [rp0], ax
prp_wait:
    call    artic_read
    sub     eax, [ra0]
    and     eax, 0x00FFFFFF
    cmp     eax, 307                  /* 1 ms at 307200 Hz */
    jb      prp_wait
    call    pit_sample_once
    jc      prp_next
    mov     [rp1], ax
    call    artic_read
    mov     [ra1], eax
    mov     ax, [rp1]
    cmp     ax, [rp0]
    ja      prp_next                  /* the element wrapped in this window */
    movzx   eax, word ptr [rp0]
    movzx   ebx, word ptr [rp1]
    sub     eax, ebx
    mov     ecx, [ra1]
    sub     ecx, [ra0]
    and     ecx, 0x00FFFFFF
    jz      prp_next
    mov     ebx, 1000
    mul     ebx
    div     ecx
    add     [ratio_sum], eax
    inc     word ptr [ratio_n]
prp_next:
    dec     byte ptr [rd_try]
    jnz     prp_window
    cmp     word ptr [ratio_n], 0
    je      prp_zero
    mov     eax, [ratio_sum]
    xor     edx, edx
    movzx   ecx, word ptr [ratio_n]
    div     ecx
    mov     [ratio_milli], eax
    jmp     prp_done
prp_zero:
    mov     dword ptr [ratio_milli], 0
prp_done:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* pit_snap_div: the PIT's counting modulus, its element rate and the x1/x2
 * convention, all measured.
 *
 * The read element's TOP (div_max over 30 ms) names the modulus:
 *   0x10000  a free-running 16-bit counter (this core's profile-0 image reads
 *            0xFFEF at the top and wraps through 0, not at 0x6000);
 *   0xC000 / 0x9C00  the standard 8253 mode-3 element 2*count at the 0x6000 /
 *            0x4E00 divisor;
 *   0x6000 / 0x4E00  the Xe10's once-per-clock element at the same divisors.
 * The short-window ratio (element counts per ARTIC tick) separates x1 (~8, or
 * 6.5 on the 1.9968 MHz strap) from x2 (~16 / 13); it does NOT set the frame
 * rate, which stays on the device rate. */
pit_snap_div:
    mov     byte ptr [pit_x2], 0
    movzx   eax, word ptr [div_max]
    cmp     ax, 0xF000
    jb      psd_not_free
    mov     eax, 0x10000
    jmp     psd_mod_done
psd_not_free:
    cmp     ax, 0xB800
    jae     psd_mod_c000
    cmp     ax, 0x9000
    jae     psd_mod_9c00
    cmp     ax, 0x5800
    jae     psd_mod_6000
    cmp     ax, 0x4800
    jb      psd_mod_6000
    cmp     ax, 0x5400
    ja      psd_mod_6000
    mov     eax, 0x4E00
    jmp     psd_mod_done
psd_mod_c000:
    mov     eax, 0xC000
    jmp     psd_mod_done
psd_mod_9c00:
    mov     eax, 0x9C00
    jmp     psd_mod_done
psd_mod_6000:
    mov     eax, 0x6000
psd_mod_done:
    mov     [pit_mod], eax
    /* x1/x2 from the short-window ratio; if every window wrapped, a 0xC000 /
     * 0x9C00 modulus can only be the 2x element. */
    cmp     dword ptr [ratio_milli], 10000
    ja      psd_x2
    cmp     word ptr [ratio_n], 0
    jne     psd_x1
    cmp     eax, 0xC000
    je      psd_x2
    cmp     eax, 0x9C00
    je      psd_x2
    jmp     psd_x1
psd_x2:
    mov     byte ptr [pit_x2], 1
psd_x1:
    /* base rate from the BIOS work-area 0x0501 bit-7 strap */
    mov     dword ptr [pit_hz], 2457600
    mov     al, [strap]
    test    al, 0x80
    jz      psd_rate_done
    mov     dword ptr [pit_hz], 1996800
psd_rate_done:
    mov     eax, [pit_hz]
    mov     [pit_eff_hz], eax
    cmp     byte ptr [pit_x2], 0
    je      psd_done
    shl     dword ptr [pit_eff_hz], 1
psd_done:
    ret

/* ------------------------------------------------------------------ */
/* the ARTIC counter                                                    */
/* ------------------------------------------------------------------ */
artic_read:                             /* EAX = 24-bit count, 005C/005F */
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005f
    in      al, dx
    movzx   ebx, al
    mov     dx, 0x005c
    in      ax, dx
    movzx   ecx, ax
    mov     dx, 0x005f
    in      al, dx
    movzx   eax, al
    cmp     eax, ebx
    je      ar_same
    cmp     ecx, 0x8000
    jb      ar_use_h2
    mov     eax, ebx
ar_use_h2:
ar_same:
    shl     eax, 16
    or      eax, ecx
    pop     ecx
    pop     ebx
    pop     dx
    ret

/* ------------------------------------------------------------------ */
/* output                                                              */
/* ------------------------------------------------------------------ */
putc:                                   /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
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
    push    dx
    push    si
ps_loop:
    mov     al, [si]
    test    al, al
    jz      ps_done
    mov     dl, al
    call    putc
    inc     si
    jmp     ps_loop
ps_done:
    pop     si
    pop     dx
    pop     ax
    ret

puthex8:                                /* AL */
    push    ax
    push    dx
    push    ax
    shr     al, 4
    call    ph_nib
    pop     ax
    and     al, 0x0F
    call    ph_nib
    pop     dx
    pop     ax
    ret
ph_nib:
    add     al, '0'
    cmp     al, '9'
    jbe     ph_out
    add     al, 'A' - '9' - 1
ph_out:
    mov     dl, al
    call    putc
    ret

puthex16:                               /* AX, four digits */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

putdec32:                               /* EAX unsigned */
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 10
    xor     ecx, ecx
pd_div:
    xor     edx, edx
    div     ebx
    push    dx
    inc     ecx
    test    eax, eax
    jnz     pd_div
pd_out:
    pop     dx
    add     dl, '0'
    call    putc
    dec     ecx
    jnz     pd_out
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* putfixed4: EAX = value * 10000 -> `N.FFFF` */
putfixed4:
    push    edx
    push    ebx
    mov     ebx, 10000
    xor     edx, edx
    div     ebx
    push    edx                     /* fraction */
    call    putdec32
    mov     dl, '.'
    call    putc
    pop     eax
    call    putdec4
    pop     ebx
    pop     edx
    ret

putfixed1:                              /* EAX = value * 10 -> `N.F` */
    push    edx
    push    ebx
    mov     ebx, 10
    xor     edx, edx
    div     ebx
    push    edx
    call    putdec32
    mov     dl, '.'
    call    putc
    pop     eax
    add     al, '0'
    mov     dl, al
    call    putc
    pop     ebx
    pop     edx
    ret

/* putdec4: EAX = 0..9999, always four digits. */
putdec4:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 1000
    mov     cx, 4
pd4_loop:
    xor     edx, edx
    div     ebx
    push    edx                     /* remainder */
    add     al, '0'
    mov     dl, al
    call    putc
    pop     eax
    push    eax
    mov     eax, ebx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    mov     ebx, eax
    pop     eax
    loop    pd4_loop
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* ------------------------------------------------------------------ */
    .balign 4
a0:          .long 0
a1:          .long 0
div_a0:      .long 0
artic_delta: .long 0
pit_total:   .long 0
pit_hz:      .long 2457600
pit_eff_hz:  .long 2457600
pit_raw:     .long 0
pit_expected:.long 0
pit_raw_e:   .long 0
pit_expected_e:.long 0
pit_diff:    .long 0
pit_div:     .word 0x6000
pit_mod:     .long 0
pit_x2:      .byte 0
strap:       .byte 0
ratio_sum:   .long 0
ratio_milli: .long 0
ratio_n:     .word 0
ra0:         .long 0
ra1:         .long 0
rp0:         .word 0
rp1:         .word 0
rd_try:      .byte 0
div_max:     .word 0
div_guard:   .word 0
pit0:        .word 0
pit1:        .word 0
pit_b1:      .byte 0
pit_b2:      .byte 0
pit_pb1:     .byte 0
pit_pb2:     .byte 0
pit_d1:      .word 0
pit_d2:      .word 0
pit_swap:    .byte 0
pit_cal_ok:  .byte 0
pit_ok:      .byte 0
ps_try:      .byte 0
p9a8:        .byte 0
run_no:      .byte 0

msg_begin:   .asciz "BEGIN:CRT24K artic_hz=307200\r\n"
msg_mode:    .asciz "MODE 24K 09A8="
msg_div:     .asciz "PIT measured_top="
msg_mod:     .asciz " mod="
msg_hz:      .asciz " hz="
msg_strap:   .asciz " strap0501="
msg_ratio:   .asciz " ratio_milli="
msg_x2:      .asciz " x2="
msg_run:     .asciz "RUN="
msg_frames:  .asciz " frames="
msg_artic:   .asciz " artic="
msg_pit:     .asciz " pit="
msg_pitok:   .asciz " pit_ok="
msg_pitdiv:  .asciz " pit_mod="
msg_pitraw:  .asciz " pit_raw="
msg_pitexp:  .asciz " pit_expected="
msg_afps:    .asciz " artic_fps="
msg_pfps:    .asciz " pit_fps="
msg_ans:     .asciz " artic_frame_ns="
msg_pns:     .asciz " pit_frame_ns="
msg_timeout: .asciz " TIMEOUT (no VSYNC)\r\n"
msg_end:     .asciz "END:CRT24K\r\n"
msg_crlf:    .asciz "\r\n"
