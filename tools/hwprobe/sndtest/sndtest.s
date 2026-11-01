/* sndtest.s - a controlled OPNA (YM2608) audio-calibration stimulus for the
 * real PC-9801-86 board: known register states in, measured dB out.
 *
 * WHY. The drum-balance/SSG-join work could only BOUND the
 * board-join gap at 0.7-2.6 dB, because a game recording forces
 * instrument-class inference (onset pairing, estimator conflicts, possible
 * limiting, an unknown LPF). The plan is a RE-MEASURE with a RAW
 * un-normalized line-out recording; this program is that measurement's
 * stimulus. Every segment is a KNOWN register state held for a KNOWN time and
 * PRINTED to stdout as it is written, so the recording settles the FM / SSG /
 * rhythm balance and the board's low-pass response directly.
 *
 * WHAT IT DECIDES (one row per class):
 *   FM TL sweep (0/8/16/24/32/48)  the FM path's transfer curve - the level at
 *       a known attenuation, which anchors every later ratio.
 *   SSG volume sweep (15/12/8/4)   the SSG join trim's direct measurement: the
 *       SSG-vs-FM ratio at known registers IS the board's join constant.
 *   rhythm, one instrument at a time at 0 dB and -6.02 dB, then the full kit,
 *       then a deliberately hot triple (BD+SD+TOM) - the die's six-drum bus is
 *       a 16-bit two's-complement WRAP (fmopna_impl.c:5370), so the hot triple
 *       is the wrap check.
 *   frequency sweeps on FM and SSG at 100/250/500/1k/2k/4k/8k/10k Hz - the
 *       board LPF heard on the machine, measured instead of assumed.
 *   a quiet/loud pair with IDENTICAL content, repeated last - limiter/AGC
 *       detection (a level-dependent path changes the second pair's ratio).
 * The 0.5 s silent gaps are the item-45 baseline (noise floor / DC).
 *
 * PORTS (pc9821_opna.sv's header; NP2kai cbus/board86.c and qemu fmopn.c agree):
 *   0x188  write the base-bank register-select latch
 *          read  the chip status (BUSY xxxxx FLAGB FLAGA)
 *   0x18A  write the selected base-bank register's data
 *   0x18C/0x18E the EXTENDED bank - NOT USED by this program, so 0xA460 bit 0
 *          is never written either: every register below is in the base bank,
 *          which the -86 decodes without the extension gate.
 *
 * REGISTER SEMANTICS (every write is cited; nothing here is guessed):
 *   FM operator TL       reg 0x40 + slot offset, 7 bits, attenuation =
 *                        TL * 0.7526 dB. The die's op_tl enters the envelope as
 *                        `eg_tl << 3` (fmopna_impl.c:1637) and the final level
 *                        is `logsin + (eg_out << 2)` (:1995) against a
 *                        256-unit-per-octave attenuation table, so one TL step
 *                        is 32 index units = 32/256 octave = 0.7526 dB. fmgen's
 *                        cltable reproduces it (a harness measured 8 steps =
 *                        -6.021 dB, i.e. 0.7526 dB/step).
 *   FM ALG/FB            reg 0xB0 bits 2:0 / 5:3 (ymfm ymfm_opn.h:210-211).
 *                        ALG=7 = four carriers; only slot 1 is left audible
 *                        (the other three get TL=0x7F), so a tonal segment is a
 *                        PURE SINE at the printed frequency - the cleanest
 *                        available LPF and transfer-curve probe.
 *   FM F-NUM             reg 0xA0 (F-NUM bits 7:0) + 0xA4 (BLOCK in bits 5:3,
 *                        F-NUM bits 10:8 in bits 2:0; the F-NUM is 11 bits,
 *                        0..2047). THE CHIP DOUBLES THE F-NUM FIRST: ymfm
 *                        `opn_registers_base::compute_phase_step` takes
 *                        `fnum = bitfield(block_freq, 0, 11) << 1` and then
 *                        `phase_step = (fnum << block) >> 2`
 *                        (ymfm_opn.cpp:354-387), and the die agrees
 *                        (`lfo_fnum = ((fnum[3] << 1) + lfo_pm) & 0xfff` with
 *                        `pg_freq = (lfo_fnum << pg_block) >> 2`,
 *                        fmopna_impl.c:1270 / :1358). So the phase step per
 *                        operator sample is `(fnum << block)/2 * MULTI`, with
 *                        MULTI from the OPN table (MULTI=0 -> x0.5, 1 -> x1,
 *                        2 -> x2, ...):
 *                            f = fnum * 2^block * MULTI * (fm_clk/144) / 2^21
 *                        The FM sample rate is master/144: ymfm's `sample_rate`
 *                        = clock/8 at max fidelity with the FM resampler at
 *                        18:1 (ymfm_opn.cpp:1335-1400, ymfm_opn.h:519-524);
 *                        jt12 clocks the phase generator at cen/6 with one
 *                        operator scan per 24 enables (pc9821_opna.sv:166);
 *                        NP2kai's own OPN core has the same shape
 *                        (`keynote = fn << (ratebit+blk+FREQ_BITS-21)`,
 *                        opngenc.c:571; `freq_inc = ((fc+detune)*multiple)>>1`,
 *                        :398; FREQ_BITS 21 at opngencfg.h:20-29; FM clock
 *                        OPNA_CLOCK/72 at opngenc.c:78). MEASURED against
 *                        NP2kai's fmgen in a host harness, reading the phase
 *                        generator's own increment: fnum 1040 / block 5 /
 *                        MULTI 1 = 880.7 Hz, fnum 520 / block 5 / MULTI 1 =
 *                        440.4 Hz. An earlier revision omitted the doubling and
 *                        printed every FM frequency ONE OCTAVE LOW.
 *   FM key on/off        reg 0x28: bits 7:4 the slot mask, bits 3:0 the channel
 *                        (channel 0 = the manual's channel 1).
 *   FM timers            reg 0x27 <- 0x00 stops BOTH timers and clears both
 *                        flags, so no OPNA IRQ can be raised by this program.
 *   FM LFO               reg 0x22 <- 0x00 (LFO off, so no AM/PM).
 *   SSG tone A period    reg 0x00 (low 8) + 0x01 (high 4). f = 124800/TP Hz:
 *                        the SSG clock is master/table[0][1] = master/4
 *                        (fmgen_opna.cpp:114-133) and the square is
 *                        clock/(16*TP) - NP2kai's own key display uses
 *                        TP = nBaseClock/(32*f) with nBaseClock = 3993600, the
 *                        Xe10's OPNA/2 clock (generic/keydisp.c:863-878).
 *                        Verified against fmgen in the same harness (TP 284 ->
 *                        439.4 Hz, TP 100 -> 100.0 Hz).
 *   SSG mixer            reg 0x07: bits 0-2 tone enable (0 = ON), bits 3-5
 *                        noise enable (1 = off), bits 6/7 the port A/B
 *                        DIRECTION. The direction bits are kept at the chip's
 *                        reset seed 0xBF (port B out, port A in - the AY
 *                        joystick wiring NP2kai's fmboard.c:56 reads), so the
 *                        -86's SSG I/O ports are not disturbed.
 *   SSG channel A volume reg 0x08 bits 3:0, 15 = loudest; bit 4 = 0 selects the
 *                        FIXED level (bit 4 = 1 would select the envelope).
 *                        The die's 32-entry table (fmopna_impl.c:2430-2436,
 *                        indexed `(level << 1) | 1` for fixed levels, :2422)
 *                        gives 15:-0.00, 12:-8.07, 8:-19.52, 4:-31.18 dB.
 *   rhythm control       reg 0x10: bit 7 = 0 keys the drums in bits 5:0 ON,
 *                        bit 7 = 1 keys them OFF (the die's `rss_keydm`
 *                        polarity, fmopna_impl.c:2786-2803; NP2kai
 *                        sound/rhythmc.c:120-142 agrees). Bit 0 = BD, 1 = SD,
 *                        2 = TOP cymbal, 3 = HH, 4 = TOM, 5 = RIM.
 *   rhythm total level   reg 0x11 bits 5:0, 0x3F = loudest, 0 = silent (NP2kai
 *                        `(~value) & 0x3f`; ymfm `total_level() ^ 0x3f`).
 *   rhythm instrument    regs 0x18-0x1D (BD/SD/TOP/HH/TOM/RIM): bit 7 = pan
 *     level + pan        left, bit 6 = pan right (the die reads
 *                        `(params >> 6) & 3` into the two accumulators,
 *                        fmopna_impl.c:3060 and :5364-5373; ymfm's
 *                        ch_pan_left = bit 7 / ch_pan_right = bit 6), bits 4:0
 *                        = the instrument level. The probe writes 0xC0 | IL
 *                        (both sides). GAIN LAW (die == ymfm == ours): vol = 94 - IL - TL,
 *                        mul = 15 - (vol & 7), shift = vol >> 3,
 *                        gain = mul / 2^(1 + shift); the first sounding
 *                        register pair is IL + TL = 32. TL is 0x3F here, so
 *                        IL 0x1F is 0 dB and IL 0x17 is exactly -6.02 dB.
 *   rhythm ROM addresses The YM2608 rhythm has NO start/end address registers:
 *                        its windows are fixed in silicon (BD 0x0000-0x01BF,
 *                        SD 0x01C0-0x043F, TOP 0x0440-0x1B7F, HH 0x1B80-0x1CFF,
 *                        TOM 0x1D00-0x1F7F, RIM 0x1F80-0x1FFF) - ymfm
 *                        ymfm_opn.cpp:1005-1010, the die's end-of-sample compare
 *                        fmopna_impl.c:3022-3030, our jt08_adpcm_cnt.v:149.
 *                        ymfm reaches them through the ADPCM-A register indices
 *                        0x10-0x1F, which the YM2608's own port map does not
 *                        expose (its write_data sends host 0x10-0x1F to
 *                        `m_address & 0x0f`, so 0x20-0x28 and 0x2A-0xFF are FM),
 *                        and NP2kai plays the rhythm from WAV files entirely
 *                        (sound/rhythmc.c:16-23). So keying register 0x10 is the
 *                        whole rhythm program: no address register is written
 *                        or needed.
 *
 * TIMING. Nothing is paced by a CPU loop: the segment clock is the ARTIC
 * free-running counter at 005C/005F, 307200 Hz (QEMU pc98-sys.c TIMESTAMP_HZ
 * and NP2kai io/artic.c agree; machine-confirmed by the VSYNC/raster counts of
 * the probe2 captures; our pc9821_iobus.sv:1491-1492
 * models it). Every wait is a bounded poll of that counter, so the run is
 * identical on the core and needs no clk_sys assumption. The BIOS tick at
 * 0040:006C is read at both ends of every segment and printed as a cross-check;
 * it paces nothing, so a machine where that word means something else still
 * runs the identical sequence.
 *
 * SAFETY.
 *   - Sound only. No disk access at all (INT 21h AH=02/09/4C only), no DMA, no
 *     write outside 0x188/0x18A and the 8259 slave IMR.
 *   - 0x188/0x18A are the base-bank pair every PC-98 sound driver writes all
 *     day (master.lib, the -86 BIOS). The extended bank (0x18C/0x18E) and
 *     0xA460 bit 0 are never touched, so the board's extension state cannot
 *     move. (Consequence: if another program had left 0xA460 bit 0 cleared, this
 *     program's own writes are unaffected - the base bank does not need it.)
 *   - The 8259 slave IMR's IRQ12 bit (bit 4, the OPNA timer line) is masked for
 *     the whole run and replayed in RESTORE, proved by re-reading it. The OPNA
 *     timers are stopped and both flags cleared (0x27 <- 0x00) in every FM
 *     program and again in RESTORE, so no OPNA interrupt is pending either way.
 *   - The OPNA clock-prescaler registers 0x2D/0x2E/0x2F are NOT written: the
 *     power-on default (FM clock = master/6, SSG = master/4) is ASSUMED and is
 *     printed in the manifest. Both the YM2608's reset state and our jt12's
 *     reset seed are that default (jt12_mmr.v:241, div_setting = 2'b10).
 *   - Per-source levels are at/below a typical game's. The run does NOT ramp:
 *     the FIRST sound is the SSG's maximum (MARK, vol 15 = 0 dB) and the
 *     loudest state is the quiet/loud pair at the END (every source at
 *     maximum, the only place all three run together hot). Set the monitor /
 *     amplifier (or headphone) level BEFORE starting - this is a calibration
 *     signal, not music - and the machine's analog stage is decades old.
 *   - Instruments are keyed off after every hit, and all three sources are
 *     silenced with explicit writes before every 0.5 s gap, so the gaps are
 *     real silence and the run ends silent.
 *   - The RESTORE footer is the complete write ledger.
 *
 * OUTPUT (stdout; redirect it: SNDTEST > SNDTEST.TXT). BEGIN:<name>/END:<name>
 * brackets every section so a hang attributes to the section after the last
 * complete one and the capture before it stays valid:
 *   SETUP     the card's as-found answer on the two readable selects (READ-ONLY)
 *   SEGMENTS  the manifest AND the run: per segment a `SEG nn ...` header with
 *             the class, the exact register values, the computed frequency and
 *             the register-level gain in dB, then every write as it happens
 *             (`W ss dd` = 0x188 <- ss then 0x18A <- dd), the drum hit offsets
 *             (`T art=...`), and `ENDSEG art=... bio=...` with the measured
 *             ARTIC and BIOS-tick deltas. The write log IS the replay program.
 *             An `ENDSEG` delta covers the WHOLE segment - its hold PLUS the
 *             0.5 s written silence that closes it (except the marker, whose
 *             tail is its own 1 s wait) - so a 1.500 s hold reads about
 *             614,400 ticks, not 460,800.
 *   RESTORE   the write ledger and what was put back
 *
 * Only the SEGMENTS section makes sound. `SNDTEST DONE` is the last line.
 *
 * BUILD: tools/hwprobe/Makefile, one .COM linked at 0x100:
 *     make -C tools/hwprobe sndtest/sndtest.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

/* ------------------------------------------------------------------
 * ARTIC ticks (307200 Hz). Every hold below is one of these constants,
 * and every one of them is printed as a measured delta.
 * ------------------------------------------------------------------ */
    .equ T_100MS,  30720
    .equ T_150MS,  46080
    .equ T_500MS,  153600
    .equ T_600MS,  184320
    .equ T_800MS,  245760
    .equ T_900MS,  276480
    .equ T_1S,     307200
    .equ T_1200MS, 368640
    .equ T_1500MS, 460800
    .equ T_1MS,    307              /* drum key-off -> key-on settle */
    .equ WAIT_OUTER, 128            /* stuck-counter bound: 128 * 65536 polls */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es

    mov     dx, offset msg_banner
    call    puts

    call    sec_setup
    call    sec_marker
    call    sec_fm_tl
    call    sec_ssg_vol
    call    sec_drums
    call    sec_kit
    call    sec_hot
    call    sec_sweep_fm
    call    sec_sweep_ssg
    call    sec_ql
    call    sec_restore

    mov     dx, offset msg_done
    call    puts
    mov     ax, 0x4C00
    int     0x21
    hlt

/* ==================================================================
 * section: SETUP - the card as found. READ-ONLY except the select latch.
 * ================================================================== */
sec_setup:
    mov     dx, offset msg_begin_setup
    call    puts
    mov     dx, offset msg_setup_p1
    call    puts
    cli
    xor     al, al                  /* the documented neutral select */
    call    sel
    mov     dx, 0x000A              /* 8259 slave IMR: mask IRQ12 (bit 4) */
    in      al, dx
    mov     [imr_save], al
    or      al, 0x10
    out     dx, al
    mov     al, 0xFF                /* the -86 chip-ID register */
    call    sel
    mov     dx, 0x018A
    in      al, dx
    mov     [id_ff], al
    mov     al, 0x07                /* SSG register 7: NP2kai's reset seed */
    call    sel
    mov     dx, 0x018A
    in      al, dx
    mov     [id_07], al
    sti

    mov     dx, offset msg_setup_id
    call    puts
    mov     al, [id_ff]
    call    puthex8
    call    putnl
    mov     dx, offset msg_setup_ssg7
    call    puts
    mov     al, [id_07]
    call    puthex8
    call    putnl
    mov     dx, offset msg_setup_note
    call    puts
    mov     dx, offset msg_end_setup
    call    puts
    ret

/* ==================================================================
 * section: SEGMENTS - the manifest, and the run.
 * ================================================================== */
sec_marker:
    mov     dx, offset msg_begin_segments
    call    puts

/* SEG 00: the start marker - a distinct DOUBLE BEEP at 2971.4 Hz (TP 42), a
 * frequency no other segment uses, so the recording aligns by it. */
    mov     dx, offset hd_00
    call    puts
    call    seg_arm
    mov     word ptr [sg_tp], 42
    call    ssg_prog
    call    ssg_on
    mov     edi, T_100MS
    call    wait_ticks
    call    ssg_off
    mov     edi, T_150MS
    call    wait_ticks
    call    ssg_on
    mov     edi, T_100MS
    call    wait_ticks
    call    ssg_off
    call    all_off
    mov     edi, T_1S
    call    wait_ticks
    call    seg_end
    ret

/* ------------------------------------------------------------------
 * FM TL sweep: one channel, ALG=7, FB=0, MULTI=1, slot 1 only audible, at
 * 440.104 Hz (block 5, F-NUM 0x208 = 520 - see the F-NUM law above: the chip
 * doubles the F-NUM first, so 0x208 at block 5 is 440.1 Hz, matching the SSG
 * reference rows at 439.437 Hz to 4 cents); TL = 0/8/16/24/32/48 =
 * 0..-36.12 dB.
 * ------------------------------------------------------------------ */
sec_fm_tl:
    mov     byte ptr [fm_blk], 5
    mov     word ptr [fm_fnum], 520   /* F-NUM 0x208 -> 440.104 Hz at MULTI 1 */
    mov     byte ptr [fm_multi], 1
    mov     byte ptr [vf_i], 0
fm_tl_loop:
    mov     al, [vf_i]
    mov     bx, offset fm_tl_hdr
    call    hdr_ptr
    mov     dx, si
    call    puts
    mov     al, [vf_i]
    mov     bx, offset fm_tl_list
    call    idxb
    mov     [fm_tl], al
    call    seg_arm
    call    fm_prog
    call    fm_on
    mov     edi, T_1500MS
    call    wait_ticks
    call    fm_off
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    inc     byte ptr [vf_i]
    cmp     byte ptr [vf_i], 6
    jb      fm_tl_loop
    ret

/* ------------------------------------------------------------------
 * SSG volume sweep: channel A square at 439.4 Hz (TP 284), volume
 * 15/12/8/4 = 0/-8.07/-19.52/-31.18 dB (the die's level table).
 * ------------------------------------------------------------------ */
sec_ssg_vol:
    mov     word ptr [sg_tp], 284
    mov     byte ptr [vf_i], 0
ssg_v_loop:
    mov     al, [vf_i]
    mov     bx, offset ssg_vol_hdr
    call    hdr_ptr
    mov     dx, si
    call    puts
    mov     al, [vf_i]
    mov     bx, offset ssg_vol_list
    call    idxb
    mov     [sg_vol], al
    call    seg_arm
    call    ssg_prog
    call    ssg_on
    mov     edi, T_1500MS
    call    wait_ticks
    call    ssg_off
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    inc     byte ptr [vf_i]
    cmp     byte ptr [vf_i], 4
    jb      ssg_v_loop
    ret

/* ------------------------------------------------------------------
 * rhythm: each instrument alone at IL 0x1F (0 dB) and 0x17 (-6.02 dB),
 * TL 0x3F, two hits each 0.800 s apart. 12 segments, in instrument order
 * BD, SD, TOP, HH, TOM, RIM so each instrument's two levels are adjacent.
 * ------------------------------------------------------------------ */
sec_drums:
    mov     byte ptr [vf_i], 0      /* instrument index 0..5 */
    mov     byte ptr [vf_l], 0      /* level index 0..1 */
dr_inst_loop:
    mov     byte ptr [vf_l], 0
dr_lvl_loop:
    /* header pointer: (instrument * 2 + level) into dr_hdr */
    mov     al, [vf_i]
    add     al, al
    add     al, [vf_l]
    mov     bx, offset dr_hdr
    call    hdr_ptr
    mov     dx, si
    call    puts
    /* parameters */
    mov     al, [vf_i]
    mov     bx, offset dr_inst_list
    call    idxb
    mov     [dr_mask], al
    mov     al, [vf_l]
    mov     bx, offset dr_il_list
    call    idxb
    mov     [dr_il], al
    call    seg_arm
    call    drum_prog
    mov     byte ptr [vf_h], 2
dr_hit_loop:
    call    drum_hit
    mov     edi, T_800MS
    call    wait_ticks
    call    drum_off
    dec     byte ptr [vf_h]
    jnz     dr_hit_loop
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    inc     byte ptr [vf_l]
    cmp     byte ptr [vf_l], 2
    jb      dr_lvl_loop
    inc     byte ptr [vf_i]
    cmp     byte ptr [vf_i], 6
    jb      dr_inst_loop
    ret

/* SEG 17: the full kit (all six drums, one key-on) at 0 dB, two hits. */
sec_kit:
    mov     dx, offset hd_23
    call    puts
    mov     byte ptr [dr_mask], 0x3F
    mov     byte ptr [dr_il], 0x1F
    call    seg_arm
    call    drum_prog
    mov     byte ptr [vf_h], 2
kit_hit_loop:
    call    drum_hit
    mov     edi, T_900MS
    call    wait_ticks
    call    drum_off
    dec     byte ptr [vf_h]
    jnz     kit_hit_loop
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    ret

/* SEG 18: the hot triple (BD + SD + TOM) at 0 dB - the drum-bus wrap check.
 * The die sums the six drums into a 16-bit two's-complement accumulator
 * (fmopna_impl.c:5370), so three simultaneous near-peak drums are the case
 * where the machine may wrap and our core is not claimed to match (TODO 87). */
sec_hot:
    mov     dx, offset hd_24
    call    puts
    mov     byte ptr [dr_mask], 0x13
    mov     byte ptr [dr_il], 0x1F
    call    seg_arm
    call    drum_prog
    mov     byte ptr [vf_h], 3
hot_hit_loop:
    call    drum_hit
    mov     edi, T_800MS
    call    wait_ticks
    call    drum_off
    dec     byte ptr [vf_h]
    jnz     hot_hit_loop
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    ret

/* ------------------------------------------------------------------
 * FM frequency sweep: one carrier sine (ALG=7, slot 1 only) at TL 0, so the
 * printed frequency is the only thing that changes. MULTI rises where the
 * F-NUM range runs out (a block-7 F-NUM is 2047 at most).
 * ------------------------------------------------------------------ */
sec_sweep_fm:
    mov     byte ptr [fm_tl], 0x00
    mov     byte ptr [vf_i], 0
fs_loop:
    mov     al, [vf_i]
    mov     bx, offset fs_hdr
    call    hdr_ptr
    mov     dx, si
    call    puts
    mov     al, [vf_i]
    mov     bx, offset fs_blk
    call    idxb
    mov     [fm_blk], al
    mov     al, [vf_i]
    mov     bx, offset fs_mul
    call    idxb
    mov     [fm_multi], al
    mov     al, [vf_i]
    mov     bx, offset fs_fn
    call    idxw
    mov     [fm_fnum], ax
    call    seg_arm
    call    fm_prog
    call    fm_on
    mov     edi, T_1200MS
    call    wait_ticks
    call    fm_off
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    inc     byte ptr [vf_i]
    cmp     byte ptr [vf_i], 8
    jb      fs_loop
    ret

/* ------------------------------------------------------------------
 * SSG frequency sweep: channel A square at volume 15, TP chosen for the
 * closest reachable frequency (the 12-bit period quantizes the top points).
 * ------------------------------------------------------------------ */
sec_sweep_ssg:
    mov     byte ptr [sg_vol], 15
    mov     byte ptr [vf_i], 0
ss_loop:
    mov     al, [vf_i]
    mov     bx, offset ss_hdr
    call    hdr_ptr
    mov     dx, si
    call    puts
    mov     al, [vf_i]
    mov     bx, offset ss_tp
    call    idxw
    mov     [sg_tp], ax
    call    seg_arm
    call    ssg_prog
    call    ssg_on
    mov     edi, T_1200MS
    call    wait_ticks
    call    ssg_off
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    inc     byte ptr [vf_i]
    cmp     byte ptr [vf_i], 8
    jb      ss_loop
    ret

/* ------------------------------------------------------------------
 * The quiet/loud pair, with IDENTICAL content, repeated: FM 440 Hz sine +
 * SSG 440 Hz square + the full kit. QUIET = FM TL 0x20 (-24.08 dB), SSG vol 8
 * (-19.52 dB), drums IL 0x07 (-18.06 dB); LOUD = all at full. A limiter or AGC
 * anywhere in the machine's analog/capture chain changes the second pair's
 * loud:quiet ratio, or the loud segment's crest, relative to the first.
 * ------------------------------------------------------------------ */
    .equ QL_FM_QUIET, 0x20
    .equ QL_FM_LOUD,  0x00
    .equ QL_SSG_QUIET, 8
    .equ QL_SSG_LOUD,  15
    .equ QL_DR_QUIET,  0x07
    .equ QL_DR_LOUD,   0x1F
sec_ql:
    /* QUIET-1 */
    mov     dx, offset hd_41
    call    puts
    mov     byte ptr [fm_tl], QL_FM_QUIET
    mov     byte ptr [sg_vol], QL_SSG_QUIET
    mov     byte ptr [dr_il], QL_DR_QUIET
    call    ql_seg
    /* LOUD-1 */
    mov     dx, offset hd_42
    call    puts
    mov     byte ptr [fm_tl], QL_FM_LOUD
    mov     byte ptr [sg_vol], QL_SSG_LOUD
    mov     byte ptr [dr_il], QL_DR_LOUD
    call    ql_seg
    /* QUIET-2 */
    mov     dx, offset hd_43
    call    puts
    mov     byte ptr [fm_tl], QL_FM_QUIET
    mov     byte ptr [sg_vol], QL_SSG_QUIET
    mov     byte ptr [dr_il], QL_DR_QUIET
    call    ql_seg
    /* LOUD-2 */
    mov     dx, offset hd_44
    call    puts
    mov     byte ptr [fm_tl], QL_FM_LOUD
    mov     byte ptr [sg_vol], QL_SSG_LOUD
    mov     byte ptr [dr_il], QL_DR_LOUD
    call    ql_seg
    ret

/* ql_seg: one quiet/loud segment - all three sources set up and keyed, two
 * kit hits, 1.5 s total. */
ql_seg:
    mov     byte ptr [fm_blk], 5
    mov     word ptr [fm_fnum], 520   /* the same 440.104 Hz FM reference */
    mov     byte ptr [fm_multi], 1
    mov     word ptr [sg_tp], 284
    mov     byte ptr [dr_mask], 0x3F
    call    seg_arm
    call    fm_prog
    call    ssg_prog
    call    drum_prog
    call    fm_on
    call    ssg_on
    call    drum_hit
    mov     edi, T_900MS
    call    wait_ticks
    call    drum_off
    call    drum_hit
    mov     edi, T_600MS
    call    wait_ticks
    call    drum_off
    call    all_off
    mov     edi, T_500MS
    call    wait_ticks
    call    seg_end
    ret

/* ==================================================================
 * section: RESTORE - the complete write ledger
 * ================================================================== */
sec_restore:
    mov     dx, offset msg_begin_restore
    call    puts
    mov     dx, offset msg_restore_p1
    call    puts

    /* Leave the chip silent: FM off, SSG off/volume 0, drums keyed off, timers
     * stopped and both flags clear. Every one of these writes is in the log, so
     * it runs with interrupts ENABLED (no DOS call ever sits in a cli window on
     * this probe); only the IMR replay needs the window, and no interrupt can
     * reach the OPNA line while its bit is still masked. */
    call    all_off
    cli
    mov     dx, 0x000A
    mov     al, [imr_save]
    out     dx, al
    in      al, dx
    mov     [imr_now], al
    sti

    mov     dx, offset msg_restore_imr
    call    puts
    mov     al, [imr_save]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [imr_now]
    call    puthex8
    call    putnl
    mov     dx, offset msg_restore_cannot
    call    puts
    mov     dx, offset msg_end_restore
    call    puts
    ret

/* ==================================================================
 * the OPNA host-port helpers
 * ================================================================== */
/* opna_ready: wait for the board's write queue to drain - the guest's own
 * WAITREADY, `poll 0x188 bit 7`. The chip's BUSY is 192 master clocks = 24.05 us
 *, which covers one operator scan, so a poll after every
 * write is what lets the FM register file absorb back-to-back writes. Bounded:
 * a chip that never clears it costs the bound, not a hang. */
opna_ready:
    push    ax
    push    cx
    push    dx
    mov     cx, 0x2000
ordl:
    mov     dx, 0x0188
    in      al, dx
    test    al, 0x80
    jz      ordd
    loop    ordl
ordd:
    pop     dx
    pop     cx
    pop     ax
    ret

/* sel: AL = the base-bank register select (0x188 <- AL). */
sel:
    mov     [cur_sel], al
    push    ax
    push    dx
    mov     dx, 0x0188
    out     dx, al
    call    opna_ready
    call    io_delay
    pop     dx
    pop     ax
    ret

/* dat: AL = the selected register's data (0x18A <- AL), and the write is
 * LOGGED here - one line per register write, in order, so the transcript is
 * the replay program. */
dat:
    mov     [cur_dat], al
    push    ax
    push    dx
    mov     dx, 0x018A
    out     dx, al
    call    opna_ready
    call    io_delay
    pop     dx
    pop     ax
    /* "  W ss dd" + CRLF */
    push    ax
    mov     dx, offset msg_w
    call    puts
    mov     al, [cur_sel]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [cur_dat]
    call    puthex8
    call    putnl
    pop     ax
    ret

/* io_delay: reads of the I/O-wait port so a chipset latch settles before the
 * next access (the same helper probe2.s uses). Reading it is harmless. */
io_delay:
    push    ax
    push    cx
    push    dx
    mov     dx, 0x005F
    mov     cx, 8
idl:
    in      al, dx
    loop    idl
    pop     dx
    pop     cx
    pop     ax
    ret

/* ==================================================================
 * time: ARTIC (307200 Hz) and the BIOS tick cross-check
 * ================================================================== */
/* artic_read: EAX = the free-running counter at 005C (bits 15:0) / 005F
 * (bits 23:16). 005D and 005E both mirror cnt[15:8]. The low word wraps every
 * 213 ms and the 24-bit value every 54.6 s, so it is read again after the high
 * byte and a low-word wrap bumps the high byte. Read-only. */
artic_read:
    /* EAX = the 24-bit ARTIC count; EBX/ECX/DX preserved whole. High byte, low word, high
     * byte again: if the high byte moved, the low word was read at the wrap and its own value
     * says which side (a small low word belongs to the new high byte). The previous
     * low/high/low read double-counted a wrap landing between its first two reads (a +65536
     * jump), and saved only BX/CX while writing EBX/ECX (crt31k found both on the core). */
    push    ebx
    push    ecx
    push    dx
    mov     dx, 0x005F
    in      al, dx
    movzx   ebx, al                     /* H1 */
    mov     dx, 0x005C
    in      ax, dx
    movzx   ecx, ax                     /* L */
    mov     dx, 0x005F
    in      al, dx
    movzx   eax, al                     /* H2 */
    cmp     eax, ebx
    je      ar_same
    cmp     ecx, 0x8000
    jb      ar_same                     /* L read after the wrap: H2 */
    mov     eax, ebx                    /* L read before the wrap: H1 */
ar_same:
    shl     eax, 16
    or      eax, ecx
    pop     dx
    pop     ecx
    pop     ebx
    ret

/* bios_tick: AX = the BIOS timer-tick word at 0040:006C. A CROSS-CHECK only -
 * nothing is paced by it. */
bios_tick:
    push    es
    push    bx
    mov     bx, 0x0040
    mov     es, bx
    mov     ax, es:[0x006C]
    pop     bx
    pop     es
    ret

/* wait_rel: wait until the ARTIC counter has advanced EDI ticks past [art_ref].
 * Bounded (WAIT_OUTER * 65536 polls) so a machine whose counter does not move
 * costs time, not a hang - the segment then simply runs short and its ENDSEG
 * line shows the short delta. */
/* wait_ticks: EDI = how many ARTIC ticks to wait FROM NOW. The reference is
 * re-marked at every call, so a sequence of waits ACCUMULATES - which is what
 * spaces the two/three drum hits and the quiet/loud pair's two kit hits, and
 * what gives the marker its real double beep. (An earlier revision compared
 * every wait against the SEGMENT start, so every wait after the first saw its
 * target already exceeded and returned at once: the second drum hit landed
 * ~1 ms after the first and the marker's second beep had zero length.) */
wait_ticks:
    call    artic_read
    mov     [gap_ref], eax
    mov     si, offset gap_ref
    call    wait_rel
    ret

/* wait_rel: wait until the 24-bit stamp at DS:SI has been passed by EDI ticks.
 * Called with SI = offset gap_ref (from now, via wait_ticks) or offset art_ref
 * (the segment start, for a whole-segment bracket). Bounded
 * (WAIT_OUTER * 65536 polls) so a machine whose counter does not move costs
 * time, not a hang - the segment then runs short and its ENDSEG line shows it. */
wait_rel:
    push    eax
    push    cx
    push    dx
    mov     word ptr [aw_outer], WAIT_OUTER
wr_outer:
    mov     cx, 0
wr_inner:
    call    artic_read
    sub     eax, [si]
    and     eax, 0x00FFFFFF
    cmp     eax, edi
    jae     wr_done
    loop    wr_inner
    dec     word ptr [aw_outer]
    jnz     wr_outer
wr_done:
    pop     dx
    pop     cx
    pop     eax
    ret

/* seg_arm: start a segment's clock. */
seg_arm:
    call    artic_read
    mov     [art_ref], eax
    call    bios_tick
    mov     [bio_ref], ax
    ret

/* seg_end: print the measured deltas for the segment just played. */
seg_end:
    call    artic_read
    sub     eax, [art_ref]
    and     eax, 0x00FFFFFF
    mov     [d_art], eax
    call    bios_tick
    sub     ax, [bio_ref]
    mov     [d_bio], ax
    mov     dx, offset msg_endseg
    call    puts
    mov     eax, [d_art]
    call    puthex24
    mov     dx, offset msg_endseg_bio
    call    puts
    mov     ax, [d_bio]
    call    puthex16
    call    putnl
    ret

/* put_t_art: the event offset of a drum hit, in ARTIC ticks from the segment
 * start. */
put_t_art:
    call    artic_read
    sub     eax, [art_ref]
    and     eax, 0x00FFFFFF
    push    eax
    mov     dx, offset msg_t_art
    call    puts
    pop     eax
    call    puthex24
    call    putnl
    ret

/* ==================================================================
 * the register programs
 * ================================================================== */
/* fm_put: AL = FM register, BL = value. */
fm_put:
    push    ax
    push    bx
    call    sel
    mov     al, bl
    call    dat
    pop     bx
    pop     ax
    ret

/* fm_quad: AL = base register, BL = value; writes base, base+4, base+8,
 * base+12 (the four operators of channel 1: registers 0x30/0x34/0x38/0x3C,
 * 0x40/0x44/0x48/0x4C, ...). */
fm_quad:
    push    ax
    push    bx
    call    fm_put
    pop     bx
    pop     ax
    push    ax
    push    bx
    add     al, 4
    call    fm_put
    pop     bx
    pop     ax
    push    ax
    push    bx
    add     al, 8
    call    fm_put
    pop     bx
    pop     ax
    push    ax
    push    bx
    add     al, 12
    call    fm_put
    pop     bx
    pop     ax
    ret

/* fm_prog: the complete FM channel-1 state from [fm_tl] (the audible slot's
 * TL), [fm_fnum], [fm_blk] and [fm_multi]. Fixed: DT1=0, AR=31, DR=0, SR=0,
 * SL=0, RR=15, SSG-EG off, FB=0, ALG=7, pan L+R, LFO off, timers off. */
fm_prog:
    mov     al, 0x22
    call    sel
    xor     al, al                  /* LFO off */
    call    dat
    mov     al, 0x27
    call    sel
    xor     al, al                  /* both timers stopped, both flags cleared */
    call    dat
    mov     al, 0x28
    call    sel
    xor     al, al                  /* key off the channel before programming */
    call    dat
    mov     al, 0x30
    mov     bl, [fm_multi]          /* DT1 = 0, MULTI = [fm_multi] */
    call    fm_quad
    mov     al, 0x40
    mov     bl, [fm_tl]             /* slot 1 audible */
    call    fm_put
    mov     al, 0x44
    mov     bl, 0x7F                /* slots 2-4 silent */
    call    fm_put
    mov     al, 0x48
    mov     bl, 0x7F
    call    fm_put
    mov     al, 0x4C
    mov     bl, 0x7F
    call    fm_put
    mov     al, 0x50
    mov     bl, 0x1F                /* AR = 31, KSR = 0 */
    call    fm_quad
    mov     al, 0x60
    xor     bl, bl                  /* DR = 0, AM = 0 */
    call    fm_quad
    mov     al, 0x70
    xor     bl, bl                  /* SR = 0 */
    call    fm_quad
    mov     al, 0x80
    mov     bl, 0x0F                /* SL = 0, RR = 15 (a fast release) */
    call    fm_quad
    mov     al, 0x90
    xor     bl, bl                  /* SSG-EG off */
    call    fm_quad
    mov     al, 0xB0
    call    sel
    mov     al, 0x07                /* FB = 0, ALG = 7 */
    call    dat
    mov     al, 0xB4
    call    sel
    mov     al, 0xC0                /* both outputs, AMS = PMS = 0 */
    call    dat
    /* F-NUM: low, then high (block + the two high bits), then low again, so
     * the pair is correct whichever write an implementation latches on. */
    mov     al, 0xA0
    call    sel
    mov     al, [fm_fnum]
    call    dat
    mov     al, 0xA4
    call    sel
    mov     al, [fm_blk]
    shl     al, 3
    mov     bl, [fm_fnum + 1]
    and     bl, 0x07
    or      al, bl
    call    dat
    mov     al, 0xA0
    call    sel
    mov     al, [fm_fnum]
    call    dat
    ret

/* fm_on / fm_off: 0x28 = the slot mask | channel. 0xF0 = all four slots of
 * channel 1 (the manual's channel 1 = the chip's channel 0). */
fm_on:
    mov     al, 0x28
    call    sel
    mov     al, 0xF0
    call    dat
    ret
fm_off:
    mov     al, 0x28
    call    sel
    xor     al, al
    call    dat
    ret

/* ssg_prog: channel A tone from [sg_tp] (12-bit period) and [sg_vol] (0-15,
 * bit 4 clear = the fixed level). B/C are disabled in the mixer and their
 * periods and volumes are written 0, so the whole SSG state is deterministic.
 * Register 7's port-direction bits keep the chip's reset seed (0xBF). */
ssg_prog:
    mov     al, 0x07
    call    sel
    mov     al, 0xBF                /* all tones and noise off; dirs = reset */
    call    dat
    mov     al, 0x00
    call    sel
    mov     al, [sg_tp]
    call    dat
    mov     al, 0x01
    call    sel
    mov     al, [sg_tp + 1]
    and     al, 0x0F
    call    dat
    mov     al, 0x02
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x03
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x04
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x05
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x06
    call    sel
    mov     al, 0x1F                /* slowest noise period (noise is off) */
    call    dat
    mov     al, 0x08
    call    sel
    mov     al, [sg_vol]
    and     al, 0x0F                /* bit 4 = 0: the fixed level, not the EG */
    call    dat
    mov     al, 0x09
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x0A
    call    sel
    xor     al, al
    call    dat
    ret

/* ssg_on: mixer - tone A on, B/C and all noise off, port directions kept. */
ssg_on:
    mov     al, 0x07
    call    sel
    mov     al, 0xBE                /* 10 111 110: A on, B/C off, noise off */
    call    dat
    ret

/* ssg_off: mixer back to all-off (the reset seed). */
ssg_off:
    mov     al, 0x07
    call    sel
    mov     al, 0xBF
    call    dat
    ret

/* drum_prog: the rhythm total level and the six instrument levels from
 * [dr_il] (TL is 0x3F = loudest), pan L+R (0xC0), then a key-off of all six. */
drum_prog:
    mov     al, 0x11
    call    sel
    mov     al, 0x3F                /* total level: no attenuation */
    call    dat
    mov     al, [dr_il]
    or      al, 0xC0                /* both outputs, then the level */
    mov     [dr_lvl], al
    mov     al, 0x18
    call    sel
    mov     al, [dr_lvl]
    call    dat
    mov     al, 0x19
    call    sel
    mov     al, [dr_lvl]
    call    dat
    mov     al, 0x1A
    call    sel
    mov     al, [dr_lvl]
    call    dat
    mov     al, 0x1B
    call    sel
    mov     al, [dr_lvl]
    call    dat
    mov     al, 0x1C
    call    sel
    mov     al, [dr_lvl]
    call    dat
    mov     al, 0x1D
    call    sel
    mov     al, [dr_lvl]
    call    dat
    mov     al, 0x10
    call    sel
    mov     al, 0xBF                /* key off all six drums */
    call    dat
    ret

/* drum_hit: key [dr_mask]'s drums off, settle, then key them on. The die's
 * per-drum key mask is consumed one bit per channel scan: the six-slot scan is
 * ~0.33 ms at the ADPCM-A channel clock (six slots at ~18.4 kHz), so the 1 ms
 * settle between the two writes already covers a FULL six-drum mask with 3x
 * margin - do not "fix" it to 2 ms. */
drum_hit:
    call    drum_off
    mov     edi, T_1MS
    call    wait_ticks
    call    put_t_art
    mov     al, 0x10
    call    sel
    mov     al, [dr_mask]
    call    dat
    ret

/* drum_off: key [dr_mask]'s drums off (bit 7 = the off polarity). */
drum_off:
    mov     al, 0x10
    call    sel
    mov     al, [dr_mask]
    or      al, 0x80
    call    dat
    ret

/* all_off: every source explicitly silent - FM keyed off, SSG mixer off and
 * its three volumes zero, all six drums keyed off, both timers stopped with
 * both flags clear. The gaps between segments are this state. */
all_off:
    call    fm_off
    call    ssg_off
    mov     al, 0x08
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x09
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x0A
    call    sel
    xor     al, al
    call    dat
    mov     al, 0x10
    call    sel
    mov     al, 0xFF                /* key off all six drums */
    call    dat
    mov     al, 0x27
    call    sel
    xor     al, al
    call    dat
    ret

/* ==================================================================
 * table indexing + output helpers
 * ================================================================== */
/* hdr_ptr: AL = index, BX = a word table; DS:SI = the table's entry. */
hdr_ptr:
    push    ax
    push    bx
    mov     ah, 0
    shl     ax, 1
    add     bx, ax
    mov     si, [bx]
    pop     bx
    pop     ax
    ret

/* idxb: AL = index, BX = a byte table; AL = the entry. */
idxb:
    push    bx
    mov     ah, 0
    add     bx, ax
    mov     al, [bx]
    pop     bx
    ret

/* idxw: AL = index, BX = a word table; AX = the entry. */
idxw:
    push    bx
    mov     ah, 0
    shl     ax, 1
    add     bx, ax
    mov     ax, [bx]
    pop     bx
    ret

putc:                               /* DL = character */
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

puts:                               /* DX = '$'-terminated string */
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

puthex8:                            /* AL */
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

puthex16:                           /* AX */
    push    ax
    xchg    al, ah
    call    puthex8
    xchg    al, ah
    call    puthex8
    pop     ax
    ret

puthex24:                           /* EAX (bits 23:0) */
    push    eax
    shr     eax, 16
    call    puthex8
    pop     eax
    push    eax
    shr     eax, 8
    call    puthex8
    pop     eax
    call    puthex8
    ret

puthexdig:                          /* AL = 0..15 -> one ASCII hex digit */
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

/* ==================================================================
 * data
 * ================================================================== */
cur_sel:    .byte 0
cur_dat:    .byte 0
art_ref:    .long 0
gap_ref:    .long 0
bio_ref:    .word 0
d_art:      .long 0
d_bio:      .word 0
aw_outer:   .word 0
id_ff:      .byte 0
id_07:      .byte 0
imr_save:   .byte 0
imr_now:    .byte 0
vf_i:       .byte 0
vf_l:       .byte 0
vf_h:       .byte 0
fm_tl:      .byte 0
fm_blk:     .byte 0
fm_multi:   .byte 0
fm_fnum:    .word 0
sg_tp:      .word 0
sg_vol:     .byte 0
dr_il:      .byte 0
dr_lvl:     .byte 0
dr_mask:    .byte 0

/* --- parameter tables, one entry per segment, in run order --- */
fm_tl_list:       .byte 0x00, 0x08, 0x10, 0x18, 0x20, 0x30
fm_tl_hdr:        .word hd_01, hd_02, hd_03, hd_04, hd_05, hd_06
ssg_vol_list:     .byte 15, 12, 8, 4
ssg_vol_hdr:      .word hd_07, hd_08, hd_09, hd_10
/* BD, SD, TOP, HH, TOM, RIM (register 0x18..0x1D order, bit 0..5) */
dr_inst_list:     .byte 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
dr_il_list:       .byte 0x1F, 0x17
dr_hdr:           .word hd_11, hd_12, hd_13, hd_14, hd_15, hd_16
                  .word hd_17, hd_18, hd_19, hd_20, hd_21, hd_22
/* 100/250/500/1k/2k/4k/8k/10k Hz under the corrected law. The F-NUMs are half
 * the pre-fix values (the law doubled); MULTI is 1 up to 2 kHz and 2 for
 * 4/8/10 kHz (a block-7 F-NUM caps at 2047 = ~6.9 kHz at MULTI 1). */
fs_blk:           .byte 3, 4, 5, 6, 7, 7, 7, 7
fs_fn:            .word 0x1D9, 0x24F, 0x24F, 0x24F, 0x24F, 0x24F, 0x49E, 0x5C5
fs_mul:           .byte 1, 1, 1, 1, 1, 2, 2, 2
fs_hdr:           .word hd_25, hd_26, hd_27, hd_28, hd_29, hd_30, hd_31, hd_32
ss_tp:            .word 1248, 499, 250, 125, 62, 31, 16, 12
ss_hdr:           .word hd_33, hd_34, hd_35, hd_36, hd_37, hd_38, hd_39, hd_40

/* --- manifest header lines, one per segment (index is hex) --- */
hd_00:  .ascii "SEG 00 class=MARK label=double-beep-2971Hz freq=2971.429Hz tp=0x02A vol=15 beep=100ms gap=150ms tail=1.000s\r\n$"
hd_01:  .ascii "SEG 01 class=FM   label=440Hz-TL00 freq=440.104Hz blk=5 fnum=0x208 mul=1 tl=0x00 atten=+0.000dB hold=1.500s\r\n$"
hd_02:  .ascii "SEG 02 class=FM   label=440Hz-TL08 freq=440.104Hz blk=5 fnum=0x208 mul=1 tl=0x08 atten=-6.021dB hold=1.500s\r\n$"
hd_03:  .ascii "SEG 03 class=FM   label=440Hz-TL16 freq=440.104Hz blk=5 fnum=0x208 mul=1 tl=0x10 atten=-12.041dB hold=1.500s\r\n$"
hd_04:  .ascii "SEG 04 class=FM   label=440Hz-TL24 freq=440.104Hz blk=5 fnum=0x208 mul=1 tl=0x18 atten=-18.062dB hold=1.500s\r\n$"
hd_05:  .ascii "SEG 05 class=FM   label=440Hz-TL32 freq=440.104Hz blk=5 fnum=0x208 mul=1 tl=0x20 atten=-24.082dB hold=1.500s\r\n$"
hd_06:  .ascii "SEG 06 class=FM   label=440Hz-TL48 freq=440.104Hz blk=5 fnum=0x208 mul=1 tl=0x30 atten=-36.124dB hold=1.500s\r\n$"
hd_07:  .ascii "SEG 07 class=SSG  label=440Hz-vol15 freq=439.437Hz tp=0x11C vol=15 lvl=+0.00dB hold=1.500s\r\n$"
hd_08:  .ascii "SEG 08 class=SSG  label=440Hz-vol12 freq=439.437Hz tp=0x11C vol=12 lvl=-8.07dB hold=1.500s\r\n$"
hd_09:  .ascii "SEG 09 class=SSG  label=440Hz-vol08 freq=439.437Hz tp=0x11C vol=8 lvl=-19.52dB hold=1.500s\r\n$"
hd_10:  .ascii "SEG 0A class=SSG  label=440Hz-vol04 freq=439.437Hz tp=0x11C vol=4 lvl=-31.18dB hold=1.500s\r\n$"
hd_11:  .ascii "SEG 0B class=DRUM label=BD il=0x1F tl=0x3F gain=+0.00dB hits=2 spacing=0.800s\r\n$"
hd_12:  .ascii "SEG 0C class=DRUM label=BD il=0x17 tl=0x3F gain=-6.02dB hits=2 spacing=0.800s\r\n$"
hd_13:  .ascii "SEG 0D class=DRUM label=SD il=0x1F tl=0x3F gain=+0.00dB hits=2 spacing=0.800s\r\n$"
hd_14:  .ascii "SEG 0E class=DRUM label=SD il=0x17 tl=0x3F gain=-6.02dB hits=2 spacing=0.800s\r\n$"
hd_15:  .ascii "SEG 0F class=DRUM label=TOP il=0x1F tl=0x3F gain=+0.00dB hits=2 spacing=0.800s\r\n$"
hd_16:  .ascii "SEG 10 class=DRUM label=TOP il=0x17 tl=0x3F gain=-6.02dB hits=2 spacing=0.800s\r\n$"
hd_17:  .ascii "SEG 11 class=DRUM label=HH il=0x1F tl=0x3F gain=+0.00dB hits=2 spacing=0.800s\r\n$"
hd_18:  .ascii "SEG 12 class=DRUM label=HH il=0x17 tl=0x3F gain=-6.02dB hits=2 spacing=0.800s\r\n$"
hd_19:  .ascii "SEG 13 class=DRUM label=TOM il=0x1F tl=0x3F gain=+0.00dB hits=2 spacing=0.800s\r\n$"
hd_20:  .ascii "SEG 14 class=DRUM label=TOM il=0x17 tl=0x3F gain=-6.02dB hits=2 spacing=0.800s\r\n$"
hd_21:  .ascii "SEG 15 class=DRUM label=RIM il=0x1F tl=0x3F gain=+0.00dB hits=2 spacing=0.800s\r\n$"
hd_22:  .ascii "SEG 16 class=DRUM label=RIM il=0x17 tl=0x3F gain=-6.02dB hits=2 spacing=0.800s\r\n$"
hd_23:  .ascii "SEG 17 class=DRUM label=full-kit-3F il=0x1F tl=0x3F gain=+0.00dB hits=2 spacing=0.900s\r\n$"
hd_24:  .ascii "SEG 18 class=DRUM label=hot-triple-BD+SD+TOM-13 il=0x1F tl=0x3F gain=+0.00dB hits=3 spacing=0.800s\r\n$"
hd_25:  .ascii "SEG 19 class=FSWP label=100Hz  freq=100.082Hz blk=3 fnum=0x1D9 mul=1 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_26:  .ascii "SEG 1A class=FSWP label=250Hz  freq=250.098Hz blk=4 fnum=0x24F mul=1 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_27:  .ascii "SEG 1B class=FSWP label=500Hz  freq=500.195Hz blk=5 fnum=0x24F mul=1 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_28:  .ascii "SEG 1C class=FSWP label=1000Hz freq=1000.391Hz blk=6 fnum=0x24F mul=1 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_29:  .ascii "SEG 1D class=FSWP label=2000Hz freq=2000.781Hz blk=7 fnum=0x24F mul=1 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_30:  .ascii "SEG 1E class=FSWP label=4000Hz freq=4001.562Hz blk=7 fnum=0x24F mul=2 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_31:  .ascii "SEG 1F class=FSWP label=8000Hz freq=8003.125Hz blk=7 fnum=0x49E mul=2 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_32:  .ascii "SEG 20 class=FSWP label=10000Hz freq=10000.521Hz blk=7 fnum=0x5C5 mul=2 tl=0x00 atten=+0.000dB hold=1.200s\r\n$"
hd_33:  .ascii "SEG 21 class=SSWP label=100Hz  freq=100.000Hz tp=0x4E0 vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_34:  .ascii "SEG 22 class=SSWP label=250Hz  freq=250.100Hz tp=0x1F3 vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_35:  .ascii "SEG 23 class=SSWP label=500Hz  freq=499.200Hz tp=0x0FA vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_36:  .ascii "SEG 24 class=SSWP label=1000Hz freq=998.400Hz tp=0x07D vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_37:  .ascii "SEG 25 class=SSWP label=2000Hz freq=2012.903Hz tp=0x03E vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_38:  .ascii "SEG 26 class=SSWP label=4000Hz freq=4025.806Hz tp=0x01F vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_39:  .ascii "SEG 27 class=SSWP label=8000Hz freq=7800.000Hz tp=0x010 vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_40:  .ascii "SEG 28 class=SSWP label=10000Hz freq=10400.000Hz tp=0x00C vol=15 lvl=+0.00dB hold=1.200s\r\n$"
hd_41:  .ascii "SEG 29 class=QL   label=QUIET-1 fm_tl=0x20 fm_att=-24.08dB ssg_vol=8 ssg=-19.52dB drum_il=0x07 drum=-18.06dB hits=2 spacing=0.900s hold=1.500s\r\n$"
hd_42:  .ascii "SEG 2A class=QL   label=LOUD-1  fm_tl=0x00 fm_att=-0.00dB ssg_vol=15 ssg=-0.00dB drum_il=0x1F drum=+0.00dB hits=2 spacing=0.900s hold=1.500s\r\n$"
hd_43:  .ascii "SEG 2B class=QL   label=QUIET-2 fm_tl=0x20 fm_att=-24.08dB ssg_vol=8 ssg=-19.52dB drum_il=0x07 drum=-18.06dB hits=2 spacing=0.900s hold=1.500s\r\n$"
hd_44:  .ascii "SEG 2C class=QL   label=LOUD-2  fm_tl=0x00 fm_att=-0.00dB ssg_vol=15 ssg=-0.00dB drum_il=0x1F drum=+0.00dB hits=2 spacing=0.900s hold=1.500s\r\n$"

/* --- messages --- */
msg_banner:
    .ascii "SNDTEST: controlled OPNA (YM2608) audio-calibration stimulus, PC-9801-86.\r\n"
    .ascii "Run it from a FRESHLY BOOTED DOS prompt with the line-out recorder already\r\n"
    .ascii "rolling: the first sounds are the double-beep start marker (SEG 00).\r\n"
    .ascii "Redirect it: SNDTEST > SNDTEST.TXT. Total run ~1.5-2 minutes, 45 segments.\r\n"
    .ascii "ASSUMPTIONS (the printed frequencies depend on them):\r\n"
    .ascii "  1. The OPNA clock prescalers 0x2D/0x2E/0x2F are NOT written: the power-on\r\n"
    .ascii "     default is assumed (FM clock = master/6, SSG clock = master/4).\r\n"
    .ascii "  2. Master clock 7.9872 MHz (the -86 board's crystal).\r\n"
    .ascii "  3. FM tone f = fnum * 2^block * MULTI * (master/144) / 2^21 -\r\n"
    .ascii "     the chip doubles the F-NUM first (ymfm_opn.cpp:354-387, die\r\n"
    .ascii "     fmopna_impl.c:1270/:1358), and MULTI is the OPN table\r\n"
    .ascii "     (0->x0.5, 1->x1, 2->x2, ...);\r\n"
    .ascii "     SSG tone f = 124800 / TP (master/4, /16); ARTIC pacing = 307200 Hz.\r\n"
    .ascii "MANIFEST FORMAT: 'SEG nn class=... ' = the segment's registers, computed\r\n"
    .ascii "frequency and register-level gain in dB. '  W ss dd' = one register write\r\n"
    .ascii "(0x188 <- ss, then 0x18A <- dd), in order. '  T art=XXXXXX' = a drum hit's\r\n"
    .ascii "offset in ARTIC ticks from the segment start. '  ENDSEG art=XXXXXX bio=XXXX'\r\n"
    .ascii "= the segment's measured ARTIC and BIOS-tick deltas (the delta covers\r\n"
    .ascii "the hold PLUS the 0.5 s of written silence that closes it: a 1.500 s hold\r\n"
    .ascii "reads ~614400 ticks, not 460800).\r\n"
    .ascii "SAFETY: no disk, no DMA, 0x188/0x18A only (plus the 8259 slave IMR, replayed).\r\n$"
msg_done:
    .ascii "SNDTEST DONE\r\n$"

msg_begin_setup:
    .ascii "BEGIN:SETUP\r\n$"
msg_setup_p1:
    .ascii "SNDTEST: the card as found, READ-ONLY (only the select latch is written, which is how any of these is read). The -86 answers 01 at the chip-ID register. SSG register 7 is printed because it is the mixer/direction byte this probe writes: NP2kai seeds BF (all tones and noise disconnected, port B an output, port A an input - opna.c:137), NP2kai's OWN fmgen PSG seeds FF (both ports outputs - fmgen_psg.cpp:36), and our jt49 resets to BF too (jt49.v:245, a LOCAL PATCH following NP2kai). The die's SSG register-file reset values are NOT settled (they are NP2kai's, not die-verified), so read this byte as evidence about THIS machine rather than as a chip fact. IRQ12 (slave IMR bit 4) is masked for the whole run here and replayed in RESTORE.\r\n$"
msg_setup_id:
    .ascii "  0x18A with 0x188=FF (chip ID; a -86 answers 01): $"
msg_setup_ssg7:
    .ascii "  0x18A with 0x188=07 (SSG register 7; the reset seed is BF): $"
msg_setup_note:
    .ascii "  a 01/00 here says the card did not answer and every segment below is silent. This is NOT the as-found audio state: the reset seed BF means nothing had enabled the SSG yet.\r\n$"
msg_end_setup:
    .ascii "END:SETUP\r\n$"

msg_begin_segments:
    .ascii "BEGIN:SEGMENTS\r\n$"
msg_w:
    .ascii "  W $"
msg_t_art:
    .ascii "  T art=$"
msg_endseg:
    .ascii "  ENDSEG art=$"
msg_endseg_bio:
    .ascii " bio=$"

msg_begin_restore:
    .ascii "BEGIN:RESTORE\r\n$"
msg_restore_p1:
    .ascii "SNDTEST: the COMPLETE write ledger. Written: 0x188 (the base-bank register select) and 0x18A (its data) only, to SSG 0x00-0x0A, rhythm 0x10/0x11/0x18-0x1D, and FM 0x22/0x27/0x28/0x30-0x9C/0xA0/0xA4/0xB0/0xB4. Left silent: FM keyed off, the SSG mixer off with all three volumes 0, all six drums keyed off, both OPNA timers stopped with both flags cleared (0x27 <- 00).\r\n$"
msg_restore_imr:
    .ascii "  8259 slave IMR (bit 4 = IRQ12, masked for the run) was -> now: $"
msg_restore_cannot:
    .ascii "  NOT touched: 0xA460 (so the -86 extension gate is exactly as found), 0x18C/0x18E (the extended bank is never selected), the 8259 master, the PIT, any DMA page/address register, and the disk (INT 21h AH=02/09/4C only). The OPNA clock prescalers 0x2D/0x2E/0x2F are NOT written, so the chip stays on its power-on default (FM master/6, SSG master/4) - the printed frequencies assume exactly that. The base-bank register-select latch has no readable form (a 0x188 read is the chip status), so the select the run ends on (0x27, timers off) cannot be replayed to the as-found byte; nothing reads it, so nothing observes it. End state of the two SSG bytes that are NOT the boot default on every machine: SSG register 7 is left at 0xBF (all tones and noise disconnected = silent; port B an output, port A an INPUT). That equals NP2kai's and our jt49's reset seed, but if this machine's own reset byte is 0xFF (both ports outputs, as fmgen seeds) the run leaves port A re-configured as an input - its I/O direction is the one piece of state this probe cannot read back, so it is named here rather than claimed restored (the -86 joystick path reads port B's DATA register, fmboard.c:56, whose direction this probe leaves alone). SSG register 6 (noise period) is also left at 0x1F rather than its reset 0x00. Neither is audible with the mixer disconnected.\r\n$"
msg_end_restore:
    .ascii "END:RESTORE\r\n$"
