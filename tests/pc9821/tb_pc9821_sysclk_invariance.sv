`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Every guest-visible TIMEBASE and device-pacing TIME this core owns measures the same WALL-CLOCK rate at two clk_sys frequencies (the base profile's 50 MHz and mediumoc's 100 MHz): each device is instantiated twice in ONE simulation, on its own clock, and read at the same simulated nanosecond, so an equal count is an equal real time rather than an equal cycle count - a model counting clk_sys instead of a real time reads 2x at 100 MHz. THE VIDEO ENABLE IS THE PRODUCTION ONE, not a copy: the real pc9821_system runs at both clocks (its CPU is tests/pc9821/z486_stub.sv) and its exported video_ce - the production PIXEL_CE_INC = round(PIXEL_HZ * 2^24 / SYS_FREQ) accumulator - drives the standalone CRTC probes and is itself counted, so a divider that counted clk_sys fails here. Covered, each with the time it is derived from named in the bench: PIT channel 0 at BOTH programs a guest uses - the BIOS's 100 Hz (divisor 0x6000 at 2.4576 MHz) and the sound drivers' 9990.24 Hz (divisor 0x00F6, the Rusty intro's INT 08h music/PCM tick) - plus channel 1 (the beeper tone, the ITF's own 2000 Hz program: control 0x76, divisor 0x04CD) and channel 2 (the RS-232C baud clock), all three on the 8253's own 2.4576 MHz input clock; the uPD4993A's four guest-writable tick rates (1/64, 1/32, 1/16 s and off) and its 1 Hz divider; the keyboard's typematic delay and interval (NP2kai's 500 ms / 50 ms); the calendar's CDAT serial read, whose bit clock is the GUEST's (both clocks are driven with one wall-clock command schedule and the recovered 48-bit payload is compared); the bus mouse's IRQ13 at its default 120 Hz and at its guest-programmed 60 Hz and 30 Hz forms; the game port's 1.1 us tick and the axis one-shot it times (the right end stop's 1022 ticks); the ARTIC 307200 Hz counter the ITF's delay() spins on (qemu pc98-sys.c:64 TIMESTAMP_HZ); the two I/O-wait floors that are real times and therefore must be paid at both clocks (0x005F = a posted write's 1744 ns bus time, the machine's write period (XE10T-XE10.TXT /IO W8_005F), paid by the access behind it, an 8253 port >= one 2.4576 MHz tick); the GVRAM arbiter's captured per-access holds (478 ns read, 142 ns write, 104 ns GRCG store - the capture's times, converted per profile and asserted back as times); the FDC's 20 us recalibrate delay; the OPNA's 7.9872 MHz chip enable, the SSG's cen/16 sample enable and its guest-programmed Timer A/B IRQ period (144 and 2304 chip enables per count); PCM86's sample strobe at a guest-selected rate of NP2kai's pcm86rate8 table; and the Xe10 I/O class table (the OSD's I/O timing field at Xe10, pc9821_iobus io_timing_xe10), whose per-class times all come from docs/probes/XE10T-XE10.TXT /IO and whose WHOLE I/O instruction - the bus time plus the core CPU's own 8 clk_sys (docs/probes/core/KIT2-CORE-SPEED.TXT) - must be the same REAL TIME at 50 and 100 MHz and within one clk_sys of the capture: the default class (792 ns read / 823 ns write), the EGC named ports 0x006A/0x00A6 (350 read / 318 write), the text GDC 0x0060/0x0062 (414), the graphics GDC 0x00A0/0x00A2 (639), the GRCG tile write 0x007E (318), the 8253 write 0x0077 (823, the default write), the 0x005F read (792) and posted write (1744, the XE10T capture's write period) and the EGC register file 0x04A1 odd / 0x04A0 even (792 / 5990). The iobus's per-access class floor (IO_MIN_HOLD = 4 clk_sys, a deliberate stall reduction against the measured 840 ns machine class) is PRINTED at both clocks and asserted by nothing, because locking in either number would decide a stall-budget question this bench does not own. FAIL-FIRST history: the 0x60 status byte's data-ready bit 0 was a bare `stat_dr <= ~stat_dr` on every clk_sys, so its edge count read 2x at 100 MHz before the fix. The data-ready bit's RATE IS NOT A MACHINE FACT and is not claimed: the machine's 2^21-sample 0x60 histogram (docs/probes/GDC.TXT) measures only its ~50 % duty and no reference gives its period, so the bench asserts the DERIVATION (one toggle per two 21.0526 MHz dots) and the two clocks' agreement. The MPU-PC98II's MIDI-out serialiser is measured here too: its start bit is the same 32 us at both clocks, which is MIDI's own 31250 baud. The 31 kHz mode (0x09A8 bit 0 set) is covered at both clocks too: the production dot enable with its 31 kHz select high drives a CRTC programmed with the BIOS 31 kHz master SYNC block, and its frame and line periods must be the Xe10's measured 70.0669 Hz / 31.460 kHz (docs/probes/CRT31K.TXT, calibrated) within 3 ppm at 50 and 100 MHz alike.
//
// Every guest-visible TIMEBASE this core owns measures the SAME WALL-CLOCK RATE at two
// different clk_sys frequencies (50 MHz, the base profile, and 100 MHz, mediumoc). Each
// pair of DUTs below runs in the SAME simulation, on its own clock, and is sampled at the
// SAME simulated nanosecond, so an equal reading is an equal wall-clock rate, not an
// equal cycle count. A model that counted clk_sys instead of a real time would read
// 2x at the 100 MHz instance.
//
//   device / rate                 reference (file:line)
//   ----------------------------  -------------------------------------------------
//   PIT ch0  100 Hz               the BIOS's own divisor 0x6000 at 2.4576 MHz
//                                 (docs/probes/TIME.TXT, "the BIOS's own divisor here
//                                 is 0x6000 = 24576, so it expects a 2.4576 MHz
//                                 counter"; pc9821_pit.sv header)
//   PIT ch0  9990.24 Hz           the sound drivers' own divisor 0x00F6 (the strap
//                                 arm that makes both clock series ~10 kHz), the
//                                 Rusty intro's INT 08h music/PCM tick
//                                 (tb_pc9821_pit_driver_rate)
//   PIT ch1  2000 Hz              the 8253's channel 1, the beeper's tone, at the
//                                 divisor the authentic ITF's own beep routine
//                                 loads: control 0x76, divisor 0x04CD = 1229
//                                 (pc9821_system.sv's beeper section, BANK4@0x4B2B;
//                                 2.4576 MHz / 1229 = 1999.7 Hz)
//   PIT ch2  6400 Hz              the 8253's channel 2, the RS-232C baud clock, at
//                                 the bench's divisor 0x0180 on the same 2.4576 MHz
//                                 input clock (a channel the core does not consume,
//                                 so only its own rate is asserted)
//   calendar 1/32 s tick          uPD4993A power-up tick rate (pc9821_calendar.sv reset
//                                 value tick_rate = 1; NP2kai io/upd4990.c)
//   calendar 1/64, 1/16 s ticks   the same register's guest-writable rates 0 and 3
//                                 (pc9821_calendar.sv:150 (tick_rate == 2'd3); tick_rate 2 = off)
//   1 Hz calendar second          uPD4993A calendar (pc9821_calendar.sv:148 (SYS_CLOCK_HZ))
//   calendar CDAT serial read     uPD4993A serial protocol, BANK7@0x5DA2 (NP2kai
//                                 io/upd4990.c:24-49,81-90): the bit clock is the
//                                 GUEST's, so the bench drives one wall-clock
//                                 schedule at both clocks and compares the payload
//   mouse IRQ13 120 Hz            NP2kai io/mouseif.c:346 (realclock / 120), MAME
//                                 pc9801.cpp:1663-1668 agrees
//   mouse timing 1, 2 (60/30 Hz)  the same rate scaled by the guest's 0xBFDB field
//                                 (mouseif.c:309-312,344-348: (realclock/120)<<timing)
//   gameport axis tick 1.1 us     the IBM game-port formula t = 24.2 us + 0.011 us * R
//                                 in 1.1 us ticks (pc9821_gameport.sv:105-130)
//   gameport axis one-shot        the same formula's OUTPUT: the right end stop's
//                                 R = 1000 asks 1022 ticks, so the pulse the guest
//                                 times is 1022 * 1.1 us of wall clock
//   ARTIC 307200 Hz               qemu-pc98 hw/misc/pc98-sys.c:64 TIMESTAMP_HZ; the
//                                 counter the ITF's delay() spins on (iobus 0x5C..0x5F)
//   0x005F posted write 1744 ns      the firmware's own I/O-wait port: the next access waits (iobus IO_POST_5F)
//   8253 port >= one PIT tick     the ITF timer self-test floor (iobus IO_PIT_HOLD)
//   GVRAM holds 478/142/104 ns    the Xe10's own capture (pc9821_gvram_arb.sv:406 (GVRAM_RD_HOLD) and :295-336:
//                                 GFX2.TXT GRCG_RMW-CTRLGC = 103.9 ns store,
//                                 GFXB.TXT GVRAM0 WRITE = 142.0 ns, and the
//                                 PW4RW/PLANE_COPY pair's read half = 478.4 ns)
//   FDC recalibrate 20 us         pc9821_fdc.sv:87 (RECAL_CYCLES) = SYS_CLOCK_HZ/50_000
//   OPNA chip enable 7.9872 MHz   the YM2608's own clock (pc9821_opna.sv:97 (CEN_STEP)
//                                 CEN_STEP; NP2kai's OPNA_CLOCK doubled)
//   OPNA SSG sample 499.2 kHz     cen/16, the SSG's own update rate
//                                 (pc9821_opna.sv:1009 (ssg_div); jt49's /16 divider)
//   OPNA Timer A/B                the chip clock divided by the guest's value:
//                                 144*(1024-NA) and 2304*(256-NB) chip enables
//                                 (jt12_timers.v header, the YM3438 datasheet
//                                 formula; NP2kai sound/opntimer.c:30,53 gives the
//                                 same period in its own quantisation)
//   PCM86 sample rate             NP2kai sound/pcm86c.c:35 pcm86rate8[] - 44100 Hz
//                                 down to 4134.375 Hz, each 8x the entry
//                                 (pc9821_pcm86.sv:154 (`STEP0`); 2^29 * rate step)
//   kbd typematic 500 ms / 50 ms  NP2kai sound/keystat.c's repeat defaults
//                                 (pc9821_kbd.sv:17 (SYS_CLOCK_HZ / 2))
//   raster line 848 dots          the SYNC block's own geometry: 848 dots at the
//                                 PIXEL_HZ dot rate (pc9821_crtc.sv's geometry section,
//                                 NP2kai io/gdc.c:370-444; docs/probes/GDC.TXT)
//   raster frame 440 lines        the same block
//   active width 640 dots         the same block (cr = 80 characters)
//   0x60 bit 0 (data-ready)       NOT a machine rate: the derivation only. The
//                                 machine's 2^21-sample histogram at 0x60 measures this
//                                 bit's DUTY alone (~50 %, docs/probes/GDC.TXT) and no
//                                 reference gives its period, so the bench pins that it
//                                 is the PIXEL_HZ-derived dot rate (one toggle per two
//                                 dots, profile-invariant) and NOT a clk_sys count.
//
// The VIDEO side is covered the same way, and the ENABLE ITSELF is the production one: the real pc9821_system runs at both clocks
// (its CPU is tests/pc9821/z486_stub.sv, the same port shell tb_pc9821_system_reset_seed
// uses) and its exported video_ce - pc9821_system.sv:1119 (the dot rate as a fraction) - PIXEL_CE_INC,
// round(PIXEL_HZ * 2^24 / SYS_FREQ) - is what drives the standalone crtc_probe pair AND
// what the bench counts. This bench once computed its OWN copy of that
// divider ("it tests the CRTC given a dot enable, not the dot enable"), so a change to the
// RTL formula passed here; now a raw clk_sys count in the production expression makes the
// 100 MHz raster, its stat_dr edges and its line/frame periods read 2x and the bench FAILS.
// The raster, the active width, the 0x60 data-ready bit and the production enable's own
// edge rate must all read the SAME wall-clock numbers at 50 and 100 MHz. FAIL-FIRST on the
// data-ready bit: it was a bare clk_sys toggle, so its edge count is 2x at 100 MHz over the
// same window.
//
// THE DERIVATION IS WHAT EACH CHECK COMPARES, and the bench says what each interval is. An
// equal count at two clocks is only an equal TIME because both halves are read at the same
// simulated nanosecond over the same window, and every check below names the interval it
// converts with (a device rate, a guest-programmed register, or a capture's ns). Where the
// machine gives no number - the 0x60 data-ready bit's period - the bench asserts the
// derivation and says so.
//
// A device whose rate comes from a CONSTANT rather than from a running counter (the GVRAM
// arbiter's holds, the FDC's recalibrate delay) is checked by reading the production
// module's own constant out of the hierarchy at both clocks and asserting the TIME it
// encodes is the same at both - which is the property those constants exist to have. A hold
// that is deliberately a CYCLE count rather than a time is called out where it is read, and
// none of these is one.
//
// WHAT IS DELIBERATELY NOT ASSERTED. The iobus's per-access class floor (IO_MIN_HOLD = 4
// clk_sys) is a fixed CLOCK count where the machine's measured classes are real times
// (the machine probe: default 840 ns, EGC 400 ns, text GDC 460 ns, graphics GDC 680 ns at
// its 0x5F anchor), and the FSM-floor change dropped the classes to that floor ON PURPOSE to cut the
// CPU's I/O-bus wait. So one default-class access is 80 ns at 50 MHz and 40 ns at
// 100 MHz. The min profile's floor is PRINTED and asserted by nothing: locking in either
// number would decide a stall-budget question that is still open. The two floors
// that change kept - 0x5F and the 8253 - ARE asserted, because they are the firmware's and
// must hold. The Xe10 TABLE (the OSD's I/O timing field at Xe10, pc9821_iobus io_timing_xe10)
// is the opposite case and IS asserted: its classes are the machine's measured TIMES
// (docs/probes/XE10T-XE10.TXT /IO), so both clocks must pay the SAME real time for the whole
// I/O instruction - the bus time measured here plus the core CPU's own XE10_CPU_CYC around it
// - within one clk_sys of the capture, which is exactly what Fast's fixed clk count cannot do.
//
// ---- the DUT ----
// The real pc9821_pit, pc9821_calendar, pc9821_gameport, pc9821_mouse, pc9821_kbd,
// pc9821_iobus and pc9821_crtc, instantiated twice each (once per clock), plus the real
// pc9821_system twice (the production pixel_ce / video_ce, and the GVRAM arbiter's
// captured holds read out of `memory.u_gvram_arb`), the real pc9821_opna twice (its chip
// enable, the SSG's sample enable and the guest-programmed timers) and the real
// pc9821_pcm86 twice (its sample strobe and NP2kai's rate table). The FDC's recalibrate
// constant is read out of the pc9821_iobus instance's own `fdc` - the production one.
// Only pc9821_iobus, pc9821_opna and pc9821_pcm86 need a bus driver, which are the probe
// modules below.
//
// pc9821_system carries the cpu stub's port shell: tests/pc9821/z486_stub.sv replaces
// src/z486 in this bench's manifest, the same substitution tb_pc9821_system_reset_seed
// makes, because the real z486 tree is not what these rates come from.
//
// ---- the verdict ----
// PASS when every device's reading matches its reference rate at BOTH clocks and the two
// clocks agree with each other, with the failing check named.

module tb_pc9821_sysclk_invariance;

  // ==== DUT ====

  // ------------------------------------------------------------------
  // Two clocks, one simulation, one sample instant.
  // ------------------------------------------------------------------
  localparam integer CLK50_HZ  = 50_000_000;
  localparam integer CLK100_HZ = 100_000_000;
  // 99.5 ms: far enough from every checked period boundary that the two clocks' sampling
  // phases cannot straddle an event (the PIT's 10th edge is at 95 ms, the calendar's 3rd
  // tick at 93.75 ms, the mouse's 12th at 100 ms, the gameport's 90000th at 99.0 ms).
  localparam integer RESET_NS  = 1000;
  localparam integer WINDOW_NS = 99_500_000;

  reg clk50  = 1'b0;
  reg clk100 = 1'b0;
  always #10 clk50  = ~clk50;    // 20 ns period
  always #5  clk100 = ~clk100;   // 10 ns period

  reg reset  = 1'b1;
  reg sample = 1'b0;
  initial begin
    #RESET_NS reset = 1'b0;
    #WINDOW_NS sample = 1'b1;
  end

  integer errors = 0;

  // ==== CHECKS ====
  task automatic fail(input string message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  task automatic note(input string message);
    begin
      $display("  %0s", message);
    end
  endtask

  // One PCM86 step-table entry: the eight entries are the reference's own pcm86rate8 table,
  // and the production step constant is (2^29 * 8 * rate) / SYS_CLOCK_HZ, so the step/HZ
  // FRACTION must be the same at both clocks. That is what makes every entry a real rate
  // rather than a clk_sys count, and it is checked on the production constants themselves.
  task automatic pcm_step(input string name, input integer rate_milli_hz,
                          input [31:0] s50, input [31:0] s100);
    longint implied_50, implied_100;      // the implied rate in milli-Hz (64-bit: the product needs it)
    longint expected;
    begin
      expected    = longint'(rate_milli_hz);
      implied_50  = (longint'(s50)  * longint'(CLK50_HZ)  * 1000) / 64'd4_294_967_296;
      implied_100 = (longint'(s100) * longint'(CLK100_HZ) * 1000) / 64'd4_294_967_296;
      if ((implied_50 - implied_100 > 200) || (implied_100 - implied_50 > 200))
        fail($sformatf("PCM86's %0s step is not a real rate: it implies %0d mHz at 50 MHz and %0d mHz at 100 MHz",
             name, implied_50, implied_100));
      if ((implied_50 - expected > 2_000) || (expected - implied_50 > 2_000))
        fail($sformatf("PCM86's %0s step implies %0d mHz, not the reference's %0d mHz", name, implied_50, expected));
      note($sformatf("PCM86 %0s step implies %0d mHz at both clocks (reference %0d mHz)", name, implied_50, expected));
    end
  endtask

  // One Xe10 class row: the same REAL TIME at both clocks and within one clk_sys of the
  // capture, with the min profile's own value for the same access printed beside it (that
  // value is asserted by nothing - see the header).
  task automatic fclass(input string name, input integer ns50, input integer ns100,
                       input integer capture, input [15:0] min50, input [15:0] min100);
    begin
      if ((ns50 - ns100 > TOL50) || (ns100 - ns50 > TOL50))
        fail($sformatf("the Xe10 %0s class is not a real time: %0d ns at 50 MHz, %0d ns at 100 MHz", name, ns50, ns100));
      if ((ns50 < capture) || (ns50 > capture + TOL50) ||
          (ns100 < capture) || (ns100 > capture + TOL100))
        fail($sformatf("the Xe10 %0s class is %0d / %0d ns, not the capture's %0d ns (+<=1 clk)", name, ns50, ns100, capture));
      note($sformatf("Xe10 %0s: %0d / %0d ns (capture %0d; Fast %0d / %0d clk, NOT asserted)",
           name, ns50, ns100, capture, min50, min100));
    end
  endtask

  // ==== the probed devices, one pair each ====
  wire [15:0] pit_edges_50, pit_edges_100;
  wire [15:0] pitdrv_edges_50, pitdrv_edges_100;
  wire [15:0] pit1_edges_50, pit1_edges_100;
  wire [15:0] pit2_edges_50, pit2_edges_100;
  wire [15:0] cal_ticks_50, cal_ticks_100;
  wire [15:0] cal64_ticks_50, cal64_ticks_100;
  wire [15:0] cal16_ticks_50, cal16_ticks_100;
  wire [31:0] cal_hz_50, cal_hz_100, cal_tick_50, cal_tick_100;
  wire [31:0] cal64_tick_50, cal64_tick_100, cal16_tick_50, cal16_tick_100;
  wire [47:0] cal_ser_50, cal_ser_100;      // the 48 CDAT clocks' payload word
  wire [15:0] cal_ser_n_50, cal_ser_n_100;  // clocks the probe actually walked
  wire [15:0] mouse_irq_50, mouse_irq_100;
  wire [15:0] mouse60_irq_50, mouse60_irq_100;
  wire [15:0] mouse30_irq_50, mouse30_irq_100;
  wire [31:0] mouse_per_50, mouse_per_100, mouse60_per_50, mouse60_per_100;
  wire [31:0] mouse30_per_50, mouse30_per_100;
  wire [31:0] gp_tick_50, gp_tick_100;
  wire [31:0] gp_width_50, gp_width_100;    // the axis one-shot's width in ns
  wire [31:0] kbd_rep_del_50, kbd_rep_del_100, kbd_rep_int_50, kbd_rep_int_100;
  wire [23:0] artic_first_50, artic_last_50, artic_first_100, artic_last_100;
  wire [15:0] cyc_5f_50, cyc_5f_100, cyc_71_50, cyc_71_100;
  wire [15:0] cyc_def_50, cyc_def_100, cyc_def_r_50, cyc_def_r_100, cyc_grcg_w_50, cyc_grcg_w_100;
  wire        done_50, done_100;
  // The Xe10 pair (io_timing_xe10 1): the same classes, plus the read direction
  // and the GRCG tile write, measured at both clocks so each class's REAL TIME can be
  // compared with the machine's capture.
  wire [15:0] fcyc_5f_50, fcyc_5f_100, fcyc_71_50, fcyc_71_100;
  wire [15:0] fcyc_def_50, fcyc_def_100, fcyc_def_r_50, fcyc_def_r_100, fcyc_grcg_w_50, fcyc_grcg_w_100;
  wire [15:0] fcyc_egc_r_50, fcyc_egc_r_100, fcyc_egc_w_50, fcyc_egc_w_100;
  wire [15:0] fcyc_gdc1_50, fcyc_gdc1_100, fcyc_gdc2_50, fcyc_gdc2_100;
  wire [15:0] fcyc_pit_w_50, fcyc_pit_w_100, fcyc_5f_r_50, fcyc_5f_r_100;
  wire [15:0] fcyc_egcf_e_50, fcyc_egcf_e_100, fcyc_egcf_o_50, fcyc_egcf_o_100;
  wire        fdone_50, fdone_100;
  // The same seven Xe10 rows in FAST, PRINTED and never asserted (see the
  // header: the min profile's floor is an open stall-budget question). They are here so
  // a reader can see what the same accesses cost at the floor.
  wire [15:0] mcyc_egc_r_50, mcyc_egc_r_100, mcyc_egc_w_50, mcyc_egc_w_100;
  wire [15:0] mcyc_gdc1_50, mcyc_gdc1_100, mcyc_gdc2_50, mcyc_gdc2_100;
  wire [15:0] mcyc_pit_w_50, mcyc_pit_w_100, mcyc_5f_r_50, mcyc_5f_r_100;
  wire [15:0] mcyc_egcf_e_50, mcyc_egcf_e_100, mcyc_egcf_o_50, mcyc_egcf_o_100;
  // The FDC's recalibrate delay, read out of the iobus's own pc9821_fdc instance (the
  // production one) at both clocks: 20 us of wall clock, or a clk_sys count.
  wire [15:0] fdc_recal_50, fdc_recal_100, ffdc_recal_50, ffdc_recal_100;
  wire [31:0] dr_50, dr_100, line_ns_50, line_ns_100, frame_ns_50, frame_ns_100;
  wire [15:0] lin_50, lin_100, frm_50, frm_100, de_line_50, de_line_100, hs_w_50, hs_w_100;
  // The PRODUCTION video path: pc9821_system's own video_ce / video_hsync / video_vsync.
  wire        ce_50, ce_100, hs_sys_50, hs_sys_100, vs_sys_50, vs_sys_100;
  wire [31:0] ce_edges_50, ce_edges_100, sys_hs_50, sys_hs_100, sys_vs_50, sys_vs_100;
  wire [15:0] gv_rd_hold_50, gv_rd_hold_100, gv_wr_hold_50, gv_wr_hold_100;
  wire [15:0] gv_gr_hold_50, gv_gr_hold_100;
  // The OPNA and the 86-PCM, each twice.
  wire [31:0] opna_cen_50, opna_cen_100, opna_ssg_50, opna_ssg_100;
  wire [31:0] opna_ta_clk_50, opna_ta_clk_100, opna_tb_clk_50, opna_tb_clk_100;
  wire [31:0] pcm_tick_50, pcm_tick_100, pcm_tick7_50, pcm_tick7_100;

  pit_probe #(.HZ(CLK50_HZ))  pit50  (.clk(clk50),  .reset(reset), .sample(sample), .edges(pit_edges_50));
  pit_probe #(.HZ(CLK100_HZ)) pit100 (.clk(clk100), .reset(reset), .sample(sample), .edges(pit_edges_100));
  // The same PIT programmed as the SOUND DRIVERS program it (the intro's music/PCM
  // tick): control 0x36, divisor 0x00F6 (9990.24 Hz at 2.4576 MHz). This is a
  // different PROGRAM of the same device - the rate must not move with clk_sys
  // either, and the band check below keeps the reference rate in the assertion.
  pit_probe #(.HZ(CLK50_HZ),  .CTRL(8'h36), .DIVISOR(16'h00F6))
      pitdrv50  (.clk(clk50),  .reset(reset), .sample(sample), .edges(pitdrv_edges_50));
  pit_probe #(.HZ(CLK100_HZ), .CTRL(8'h36), .DIVISOR(16'h00F6))
      pitdrv100 (.clk(clk100), .reset(reset), .sample(sample), .edges(pitdrv_edges_100));
  // Channel 1, the BEEPER'S TONE: the ITF's own beep routine (BANK4@0x4B2B) writes control
  // 0x76 (channel 1, LSB+MSB, mode 3) and divisor 0x04CD = 1229, i.e. 2.4576 MHz / 1229 =
  // 1999.7 Hz (pc9821_system.sv's speaker_out section). Channel 2 is the RS-232C baud
  // clock, programmed here at divisor 0x0180 = 384 -> 6400 Hz. Both are the same 8253 on
  // the same 2.4576 MHz input clock as channel 0, and both are real times.
  pit_probe #(.HZ(CLK50_HZ),  .CH(1), .CTRL(8'h76), .DIVISOR(16'h04CD))
      pit1_50  (.clk(clk50),  .reset(reset), .sample(sample), .edges(pit1_edges_50));
  pit_probe #(.HZ(CLK100_HZ), .CH(1), .CTRL(8'h76), .DIVISOR(16'h04CD))
      pit1_100 (.clk(clk100), .reset(reset), .sample(sample), .edges(pit1_edges_100));
  pit_probe #(.HZ(CLK50_HZ),  .CH(2), .CTRL(8'hB6), .DIVISOR(16'h0180))
      pit2_50  (.clk(clk50),  .reset(reset), .sample(sample), .edges(pit2_edges_50));
  pit_probe #(.HZ(CLK100_HZ), .CH(2), .CTRL(8'hB6), .DIVISOR(16'h0180))
      pit2_100 (.clk(clk100), .reset(reset), .sample(sample), .edges(pit2_edges_100));

  cal_probe #(.HZ(CLK50_HZ))  cal50  (.clk(clk50),  .reset(reset), .sample(sample),
                                       .ticks(cal_ticks_50), .hz_max(cal_hz_50), .tick_period(cal_tick_50));
  cal_probe #(.HZ(CLK100_HZ)) cal100 (.clk(clk100), .reset(reset), .sample(sample),
                                       .ticks(cal_ticks_100), .hz_max(cal_hz_100), .tick_period(cal_tick_100));
  // The icky register's OTHER two rates: tick_rate 0 = 1/64 s, tick_rate 3 = 1/16 s
  // (pc9821_calendar.sv:150 (tick_rate == 2'd3); 2 = off). Same device, same guest-writable register.
  cal_probe #(.HZ(CLK50_HZ),  .TICK_RATE(2'd0)) cal64_50  (.clk(clk50),  .reset(reset), .sample(sample),
                                       .ticks(cal64_ticks_50), .hz_max(), .tick_period(cal64_tick_50));
  cal_probe #(.HZ(CLK100_HZ), .TICK_RATE(2'd0)) cal64_100 (.clk(clk100), .reset(reset), .sample(sample),
                                       .ticks(cal64_ticks_100), .hz_max(), .tick_period(cal64_tick_100));
  cal_probe #(.HZ(CLK50_HZ),  .TICK_RATE(2'd3)) cal16_50  (.clk(clk50),  .reset(reset), .sample(sample),
                                       .ticks(cal16_ticks_50), .hz_max(), .tick_period(cal16_tick_50));
  cal_probe #(.HZ(CLK100_HZ), .TICK_RATE(2'd3)) cal16_100 (.clk(clk100), .reset(reset), .sample(sample),
                                       .ticks(cal16_ticks_100), .hz_max(), .tick_period(cal16_tick_100));
  // The CDAT serial read, driven with ONE wall-clock schedule at both clocks.
  cal_serial_probe #(.HZ(CLK50_HZ))  calser50  (.clk(clk50),  .reset(reset), .word(cal_ser_50),
                                                .clocks(cal_ser_n_50));
  cal_serial_probe #(.HZ(CLK100_HZ)) calser100 (.clk(clk100), .reset(reset), .word(cal_ser_100),
                                                .clocks(cal_ser_n_100));

  mouse_probe #(.HZ(CLK50_HZ))  mouse50  (.clk(clk50),  .reset(reset), .sample(sample),
                                          .irqs(mouse_irq_50), .period(mouse_per_50));
  mouse_probe #(.HZ(CLK100_HZ)) mouse100 (.clk(clk100), .reset(reset), .sample(sample),
                                          .irqs(mouse_irq_100), .period(mouse_per_100));
  // The guest's OWN 0xBFDB timing field: period = (SYS_CLOCK_HZ/120) << timing, so timing 1
  // is 60 Hz and timing 2 is 30 Hz (NP2kai io/mouseif.c:344-348).
  mouse_probe #(.HZ(CLK50_HZ),  .TIMING(2'd1)) mouse60_50  (.clk(clk50),  .reset(reset), .sample(sample),
                                          .irqs(mouse60_irq_50), .period(mouse60_per_50));
  mouse_probe #(.HZ(CLK100_HZ), .TIMING(2'd1)) mouse60_100 (.clk(clk100), .reset(reset), .sample(sample),
                                          .irqs(mouse60_irq_100), .period(mouse60_per_100));
  mouse_probe #(.HZ(CLK50_HZ),  .TIMING(2'd2)) mouse30_50  (.clk(clk50),  .reset(reset), .sample(sample),
                                          .irqs(mouse30_irq_50), .period(mouse30_per_50));
  mouse_probe #(.HZ(CLK100_HZ), .TIMING(2'd2)) mouse30_100 (.clk(clk100), .reset(reset), .sample(sample),
                                          .irqs(mouse30_irq_100), .period(mouse30_per_100));

  gameport_probe #(.HZ(CLK50_HZ))  gp50  (.clk(clk50),  .reset(reset), .sample(sample),
                                          .ticks(gp_tick_50), .axis_ns(gp_width_50));
  gameport_probe #(.HZ(CLK100_HZ)) gp100 (.clk(clk100), .reset(reset), .sample(sample),
                                          .ticks(gp_tick_100), .axis_ns(gp_width_100));

  kbd_probe #(.HZ(CLK50_HZ))  kbd50  (.clk(clk50),  .reset(reset), .sample(sample),
                                      .rep_delay(kbd_rep_del_50), .rep_interval(kbd_rep_int_50));
  kbd_probe #(.HZ(CLK100_HZ)) kbd100 (.clk(clk100), .reset(reset), .sample(sample),
                                      .rep_delay(kbd_rep_del_100), .rep_interval(kbd_rep_int_100));

  iobus_probe #(.HZ(CLK50_HZ))  iobus50  (.clk(clk50),  .reset(reset), .sample(sample),
                                          .artic_first(artic_first_50), .artic_last(artic_last_50),
                                          .cyc_5f(cyc_5f_50), .cyc_71(cyc_71_50),
                                          .cyc_default(cyc_def_50), .cyc_def_r(cyc_def_r_50),
                                          .cyc_grcg_w(cyc_grcg_w_50), .done(done_50),
                                          .fdc_recal(fdc_recal_50),
                                          .egc_r(mcyc_egc_r_50), .egc_w(mcyc_egc_w_50),
                                          .gdc1(mcyc_gdc1_50), .gdc2(mcyc_gdc2_50),
                                          .pit_w(mcyc_pit_w_50), .f_5f_r(mcyc_5f_r_50),
                                          .egcf_e(mcyc_egcf_e_50), .egcf_o(mcyc_egcf_o_50));
  iobus_probe #(.HZ(CLK100_HZ)) iobus100 (.clk(clk100), .reset(reset), .sample(sample),
                                          .artic_first(artic_first_100), .artic_last(artic_last_100),
                                          .cyc_5f(cyc_5f_100), .cyc_71(cyc_71_100),
                                          .cyc_default(cyc_def_100), .cyc_def_r(cyc_def_r_100),
                                          .cyc_grcg_w(cyc_grcg_w_100), .done(done_100),
                                          .fdc_recal(fdc_recal_100),
                                          .egc_r(mcyc_egc_r_100), .egc_w(mcyc_egc_w_100),
                                          .gdc1(mcyc_gdc1_100), .gdc2(mcyc_gdc2_100),
                                          .pit_w(mcyc_pit_w_100), .f_5f_r(mcyc_5f_r_100),
                                          .egcf_e(mcyc_egcf_e_100), .egcf_o(mcyc_egcf_o_100));
  // The Xe10 table, the SAME pc9821_iobus at the same two clocks: its classes are the
  // machine's measured TIMES, so they must be paid as the same real time at both (the PIT's
  // own rate is the proof a real time is achievable here - see the I/O-wait block below).
  iobus_probe #(.HZ(CLK50_HZ),  .XE10(1'b1)) faith50  (.clk(clk50),  .reset(reset), .sample(sample),
                                          .artic_first(fartic_first_50), .artic_last(fartic_last_50),
                                          .cyc_5f(fcyc_5f_50), .cyc_71(fcyc_71_50),
                                          .cyc_default(fcyc_def_50), .cyc_def_r(fcyc_def_r_50),
                                          .cyc_grcg_w(fcyc_grcg_w_50), .done(fdone_50),
                                          .fdc_recal(ffdc_recal_50),
                                          .egc_r(fcyc_egc_r_50), .egc_w(fcyc_egc_w_50),
                                          .gdc1(fcyc_gdc1_50), .gdc2(fcyc_gdc2_50),
                                          .pit_w(fcyc_pit_w_50), .f_5f_r(fcyc_5f_r_50),
                                          .egcf_e(fcyc_egcf_e_50), .egcf_o(fcyc_egcf_o_50));
  iobus_probe #(.HZ(CLK100_HZ), .XE10(1'b1)) faith100 (.clk(clk100), .reset(reset), .sample(sample),
                                          .artic_first(fartic_first_100), .artic_last(fartic_last_100),
                                          .cyc_5f(fcyc_5f_100), .cyc_71(fcyc_71_100),
                                          .cyc_default(fcyc_def_100), .cyc_def_r(fcyc_def_r_100),
                                          .cyc_grcg_w(fcyc_grcg_w_100), .done(fdone_100),
                                          .fdc_recal(ffdc_recal_100),
                                          .egc_r(fcyc_egc_r_100), .egc_w(fcyc_egc_w_100),
                                          .gdc1(fcyc_gdc1_100), .gdc2(fcyc_gdc2_100),
                                          .pit_w(fcyc_pit_w_100), .f_5f_r(fcyc_5f_r_100),
                                          .egcf_e(fcyc_egcf_e_100), .egcf_o(fcyc_egcf_o_100));

  // The OPNA and the 86-PCM: the chip's own clock enable and the sample strobe each
  // free-runs from the module's parameters, and the probe programs Timer A and Timer B
  // through the same host port pc9821_iobus drives.
  opna_probe #(.HZ(CLK50_HZ))  opna50  (.clk(clk50),  .reset(reset), .sample(sample),
                                        .cen_edges(opna_cen_50), .ssg_edges(opna_ssg_50),
                                        .ta_clk(opna_ta_clk_50), .tb_clk(opna_tb_clk_50));
  opna_probe #(.HZ(CLK100_HZ)) opna100 (.clk(clk100), .reset(reset), .sample(sample),
                                        .cen_edges(opna_cen_100), .ssg_edges(opna_ssg_100),
                                        .ta_clk(opna_ta_clk_100), .tb_clk(opna_tb_clk_100));
  pcm86_probe #(.HZ(CLK50_HZ),  .RATE(3'd0)) pcm_50  (.clk(clk50),  .reset(reset), .sample(sample),
                                        .ticks(pcm_tick_50));
  pcm86_probe #(.HZ(CLK100_HZ), .RATE(3'd0)) pcm_100 (.clk(clk100), .reset(reset), .sample(sample),
                                        .ticks(pcm_tick_100));
  pcm86_probe #(.HZ(CLK50_HZ),  .RATE(3'd7)) pcm7_50  (.clk(clk50),  .reset(reset), .sample(sample),
                                        .ticks(pcm_tick7_50));
  pcm86_probe #(.HZ(CLK100_HZ), .RATE(3'd7)) pcm7_100 (.clk(clk100), .reset(reset), .sample(sample),
                                        .ticks(pcm_tick7_100));

  // The PRODUCTION video path: pc9821_system at both clocks (CPU = the z486 stub). Its
  // video_ce is the enable the shipped design gives the framework as CE_PIXEL, and it is
  // what DRIVES the two crtc_probe instances below - so the CRTC checks are checks of the
  // production divider, not of a copy of it.
  sys_probe #(.HZ(CLK50_HZ))  sys50  (.clk(clk50),  .reset(reset),
                                      .video_ce(ce_50), .ce_edges(ce_edges_50),
                                      .hs_pulses(sys_hs_50), .vs_pulses(sys_vs_50),
                                      .video_hsync(hs_sys_50), .video_vsync(vs_sys_50),
                                      .gv_rd_hold(gv_rd_hold_50), .gv_wr_hold(gv_wr_hold_50),
                                      .gv_gr_hold(gv_gr_hold_50));
  sys_probe #(.HZ(CLK100_HZ)) sys100 (.clk(clk100), .reset(reset),
                                      .video_ce(ce_100), .ce_edges(ce_edges_100),
                                      .hs_pulses(sys_hs_100), .vs_pulses(sys_vs_100),
                                      .video_hsync(hs_sys_100), .video_vsync(vs_sys_100),
                                      .gv_rd_hold(gv_rd_hold_100), .gv_wr_hold(gv_wr_hold_100),
                                      .gv_gr_hold(gv_gr_hold_100));

  // The MPU-PC98II's MIDI-out serialiser (pc9821_mpu), driven through its own two
  // ports at each clock: one complete channel message, and the start bit's width measured in
  // NANOseconds. MIDI's line rate is 31250 baud, so the bit is 32 us - a divider counting
  // clk_sys reads 16 us at 100 MHz.
  wire [31:0] mpu_bit_ns_50, mpu_bit_ns_100;
  mpu_rate_probe #(.HZ(CLK50_HZ))  mpu50  (.clk(clk50),  .reset(reset), .bit_ns(mpu_bit_ns_50));
  mpu_rate_probe #(.HZ(CLK100_HZ)) mpu100 (.clk(clk100), .reset(reset), .bit_ns(mpu_bit_ns_100));

  crtc_probe crtc50  (.clk(clk50),  .reset(reset), .sample(sample), .pixel_ce(ce_50),
                      .dr_edges(dr_50), .lines(lin_50), .frames(frm_50),
                      .de_line(de_line_50), .line_ns(line_ns_50),
                      .frame_ns(frame_ns_50), .hs_width_ns(hs_w_50));
  crtc_probe crtc100 (.clk(clk100), .reset(reset), .sample(sample), .pixel_ce(ce_100),
                      .dr_edges(dr_100), .lines(lin_100), .frames(frm_100),
                      .de_line(de_line_100), .line_ns(line_ns_100),
                      .frame_ns(frame_ns_100), .hs_width_ns(hs_w_100));

  // THE 31 kHz MODE (0x09A8 bit 0 set): the production dot enable (pc9821_dot_ce) with c31 high at
  // both clocks, driving a crtc31_probe that programs the BIOS 31 kHz master SYNC block (NP2kai
  // bios/bios18.c gdcmastersync[2], the block docs/probes/CRT31K.TXT measured) into a pc9821_crtc
  // with crt31k high. The 0x09A8 latch -> c31 wiring itself is tb_pc9821_crt31k's subject.
  wire        ce31_50, ce31_100;
  wire [31:0] f31_ns_50, f31_ns_100, l31_ns_50, l31_ns_100;
  wire [15:0] l31_n_50, l31_n_100;
  pc9821_dot_ce #(.SYS_FREQ(CLK50_HZ))  dot31_50  (.clk(clk50),  .reset(reset), .c31(1'b1), .ce(ce31_50));
  pc9821_dot_ce #(.SYS_FREQ(CLK100_HZ)) dot31_100 (.clk(clk100), .reset(reset), .c31(1'b1), .ce(ce31_100));
  crtc31_probe crtc31_50  (.clk(clk50),  .reset(reset), .sample(sample), .pixel_ce(ce31_50),
                           .frame_ns(f31_ns_50), .line_ns(l31_ns_50), .lines(l31_n_50));
  crtc31_probe crtc31_100 (.clk(clk100), .reset(reset), .sample(sample), .pixel_ce(ce31_100),
                           .frame_ns(f31_ns_100), .line_ns(l31_ns_100), .lines(l31_n_100));

  // ==== checks ====
  integer ns_5f_50, ns_5f_100, ns_71_50, ns_71_100, ns_def_50, ns_def_100;
  // The Xe10 classes' real times at both clocks, and the capture's own values
  // (docs/probes/XE10T-XE10.TXT /IO `net_ns`, decoded by xe10t_decode.py). Expected values are NEVER
  // derived from our RTL - the RTL is what these measure.
  integer fns_def_r_50, fns_def_r_100, fns_def_w_50, fns_def_w_100;
  integer fns_grcg_w_50, fns_grcg_w_100, fns_5f_w_50, fns_5f_w_100;
  localparam integer CAP_DEF_R   = 792;   // default-class reads (R8_0002 791.5, the 37 default rows 788.4-791.5)
  localparam integer CAP_DEF_W   = 823;   // default-class writes (W8_0000/W8_0008 823.3, W8_0188 820.2)
  localparam integer CAP_GRCG_W  = 318;   // W8_007E 317.9 (nop=0)
  // The core CPU's own share of an I/O instruction, which the Xe10 table takes off the bus and
  // these checks add back, so each is a WHOLE-INSTRUCTION time against the machine's. A
  // measurement of this core (docs/probes/core/KIT2-CORE-SPEED.TXT at 90 MHz: `in al,dx` 12
  // clk_sys in Fast around a 4-clk access), a CYCLE count at every clock because the z486 runs
  // at clk_sys - which is why bus + share is the real time at both clocks and the bus alone is not.
  localparam integer XE10_CPU_CYC = 8;
  localparam integer CAP_5F_W    = 1744;  // 0x005F write period, posted (XE10T-XE10.TXT /IO W8_005F, PIT 1744.0-1744.4)
  integer artic_d_50, artic_d_100;
  integer opna_ta_ns_50, opna_ta_ns_100, opna_tb_ns_50, opna_tb_ns_100;
  integer kbd_rep_del_ns_50, kbd_rep_del_ns_100, kbd_rep_int_ns_50, kbd_rep_int_ns_100;
  // The newly covered constants' real times at both clocks.
  integer gv_rd_ns_50, gv_rd_ns_100, gv_wr_ns_50, gv_wr_ns_100, gv_gr_ns_50, gv_gr_ns_100;
  integer fdc_recal_ns_50, fdc_recal_ns_100;
  integer fns_egc_r_50, fns_egc_r_100, fns_egc_w_50, fns_egc_w_100;
  integer fns_gdc1_50, fns_gdc1_100, fns_gdc2_50, fns_gdc2_100;
  integer fns_pit_w_50, fns_pit_w_100, fns_5f_r_50, fns_5f_r_100;
  integer fns_egcf_e_50, fns_egcf_e_100, fns_egcf_o_50, fns_egcf_o_100;
  // A class's delivered time may exceed the capture's by one clk_sys (the ceil quantisation)
  // and may never fall short of it. At 100 MHz that is half the 50 MHz allowance.
  localparam integer TOL50  = 20;
  localparam integer TOL100 = 10;
  localparam integer PIT_EXPECTED    = 9;          // rising edges at 10..90 ms (OUT idles HIGH after a mode-3 load)
  // 99.5 ms x 2457600/246 = 994.03 ticks. The probe arms a few cycles after reset,
  // so the first counted rise is the mode-3 half-period in, and the count can be
  // 994 or 995; the band is +/-3 and the CLOCK-INVARIANCE check is exact.
  localparam integer PITDRV_EXPECTED = 994;
  localparam integer CAL_EXPECTED    = 3;          // 1/32 s over 99.5 ms
  localparam integer MOUSE_EXPECTED  = 11;         // 120 Hz over 99.5 ms
  localparam integer GP_EXPECTED     = 90454;      // 99.5 ms / 1.1 us; needs 17 bits, hence the 32-bit counter
  localparam integer ARTIC_EXPECTED  = 30566;      // 99.5 ms * 307200 Hz
  // The video side's reference numbers, derived from the machine's own dot rate and the
  // SYNC block's geometry (848 x 440, 640 active): PIXEL_HZ = 21.0526 MHz at every profile.
  // DR_EXPECTED is the 0x60 data-ready bit's DERIVATION (one toggle per two dots), not a
  // measured machine rate.
  localparam integer PIXEL_HZ        = 21_052_600;
  localparam integer LINE_NS         = 40_280;     // 848 dots / 21.0526 MHz
  localparam integer FRAME_NS        = 17_723_227; // 848 * 440 dots / 21.0526 MHz
  localparam integer HS_WIDTH_NS     = 3_040;      // the block's hs field 7: (7 + 1) chars = 64 dots (MAME upd7220.cpp:1243 `m_hs = (m_pr[3] & 0x1f) + 1`)
  localparam integer DE_LINE         = 640;        // the block's cr field: 80 chars = 640 dots
  localparam integer LINES_EXPECTED  = 2470;       // 99.5 ms / 40.280 us
  // The 31 kHz mode's capture (docs/probes/CRT31K.TXT `RUN frames=70 ticks=306930`, calibrated):
  localparam integer F31_NS          = 14_272_074; // 1 / 70.06690 Hz
  localparam integer L31_NS          = 317_864;    // 1 / 31 460.04 Hz, in 0.1 ns
  localparam integer FRAMES_EXPECTED = 5;          // 99.5 ms / 17.723 ms
  localparam integer DR_EXPECTED     = 1_047_366;  // 99.5 ms * 21.0526 MHz / 2 (see above)
  // The production enable's own rate over the same window (one enable per dot).
  localparam integer CE_EXPECTED     = 2_094_734;  // 99.5 ms * 21.0526 MHz
  // PIT channels 1 and 2: their own divisor / 2.4576 MHz over the window.
  localparam integer PIT1_EXPECTED   = 199;        // 2.4576 MHz / 1229 = 1999.7 Hz
  localparam integer PIT2_EXPECTED   = 637;        // 2.4576 MHz / 384 = 6400 Hz
  // The calendar's other two registered rates. The 1/64 s tick is 15.625 ms, so 99.5 ms
  // holds 6; the 1/16 s tick is 62.5 ms, so it holds ONE - and at one event the count is a
  // weak instrument, which is why the strong assertion for that rate is the DIVIDER the
  // module armed (SYS_CLOCK_HZ/16-1 clk, i.e. exactly 1/16 s at both clocks).
  localparam integer CAL64_EXPECTED  = 6;          // 99.5 ms / 15.625 ms
  localparam integer CAL16_EXPECTED  = 1;          // 99.5 ms / 62.5 ms
  // The keyboard's typematic windows (NP2kai's repeat defaults, as wall clock).
  localparam integer KBD_REP_DEL_NS  = 500_000_000;
  localparam integer KBD_REP_INT_NS  = 50_000_000;
  // The bus mouse at the guest's own timing field.
  localparam integer MOUSE60_EXPECTED = 5;         // 60 Hz over 99.5 ms
  localparam integer MOUSE30_EXPECTED = 2;         // 30 Hz over 99.5 ms
  // The game port's axis one-shot at the right end stop: 22 + 1000 ticks of 1.1 us.
  localparam integer GP_AXIS_NS      = 1_124_200;
  localparam integer GP_TOL_NS       = 2_200;      // two 1.1 us ticks
  // The GVRAM arbiter's captured holds (docs/probes/GFX2.TXT / GFXB.TXT); the constant is a
  // clk count, so one clk_sys of rounding is the band.
  localparam integer CAP_GV_RD       = 478;
  localparam integer CAP_GV_WR       = 142;
  localparam integer CAP_GV_GR       = 104;
  // The OPNA: the chip's clock, the SSG's cen/16, and the two timers' one-period times.
  localparam integer OPNA_CEN_EXPECTED = 794_726;  // 99.5 ms * 7.9872 MHz
  localparam integer OPNA_SSG_EXPECTED = 49_670;   // ... / 16
  localparam integer OPNA_TA_PERIOD_NS = 1_153_846; // 64 steps x 144 master clocks at 7.9872 MHz
  localparam integer OPNA_TB_PERIOD_NS = 4_615_385; // 16 steps x 2304 master clocks at 7.9872 MHz
  // The 86-PCM's two sampled entries of NP2kai's pcm86rate8 table.
  localparam integer PCM0_EXPECTED   = 4_388;      // 99.5 ms * 44100 Hz
  localparam integer PCM7_EXPECTED   = 411;        // 99.5 ms * 4134.375 Hz
  // The Xe10 table's remaining captured rows (docs/probes/XE10T-XE10.TXT /IO net_ns).
  localparam integer CAP_EGC_R       = 350;        // R8_006A 349.7
  localparam integer CAP_EGC_W       = 318;        // W8_00A6 317.9
  localparam integer CAP_GDC1        = 414;        // R8_0060/R8_0062 413.3
  localparam integer CAP_GDC2        = 639;        // R8_00A0/R8_00A2 639.0
  localparam integer CAP_PIT_W       = 823;        // the default write (no XE10T 8253 write row; IO.TXT priced 0x77's at its default write)
  localparam integer CAP_5F_R        = 792;        // R8_005F 788.4, the default read class
  localparam integer CAP_EGCF_E      = 5_990;      // R8_04A0/R8_04A2 5989.1, EVEN address
  localparam integer CAP_EGCF_O      = 792;        // R8_04A1 791.5, ODD address
  // The 48-bit CDAT payload the bench's rtc_bcd loads, packed the way pc9821_calendar emits
  // it (seconds byte first, then min, hour, day, month|weekday, year - LSB first on the wire):
  // the loaded 0x05_26_09_12_12_34_56 is weekday 5, year 26, month 9 (decimal 9), day 0x12,
  // hour 0x12, min 0x34, sec 0x56.
  localparam [47:0] CAL_SER_PAYLOAD = 48'h26_95_12_12_34_56;

  initial begin
    wait (sample);
    wait (done_50 && done_100 && fdone_50 && fdone_100);   // the probes' final ARTIC reads are three I/O accesses long
    @(posedge clk100);
    #100;

    // ---- PIT channel 0: 100 Hz at both clocks ----
    if (pit_edges_50 !== pit_edges_100)
      fail($sformatf("PIT ch0 tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", pit_edges_50, pit_edges_100));
    if (pit_edges_50 !== 16'(PIT_EXPECTED))
      fail($sformatf("PIT ch0 tick count %0d over 99.5 ms is not the reference 100 Hz (%0d)", pit_edges_50, PIT_EXPECTED));
    note($sformatf("PIT ch0: %0d ticks / 99.5 ms at both clocks (2.4576 MHz / 0x6000 = 100 Hz)", pit_edges_50));

    // ---- PIT channel 0 as the SOUND DRIVERS program it: 9990.24 Hz ----
    // Same device, same input clock, the guests' other program (control 0x36,
    // divisor 0x00F6). Its RATE is the device's, so it is a wall-clock rate at
    // both clocks too - which is what makes the intro's music/PCM tick immune to
    // the build profile.
    if (pitdrv_edges_50 !== pitdrv_edges_100)
      fail($sformatf("PIT ch0 (driver program 0x00F6) tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz",
           pitdrv_edges_50, pitdrv_edges_100));
    if ((pitdrv_edges_50 > 16'(PITDRV_EXPECTED + 3)) || (pitdrv_edges_50 < 16'(PITDRV_EXPECTED - 3)))
      fail($sformatf("PIT ch0 (driver program 0x00F6) tick count %0d over 99.5 ms is not the reference 9990.24 Hz (%0d)",
           pitdrv_edges_50, PITDRV_EXPECTED));
    note($sformatf("PIT ch0 (sound-driver program): %0d ticks / 99.5 ms at both clocks (2.4576 MHz / 0x00F6 = 9990.24 Hz)",
         pitdrv_edges_50));

    // ---- calendar: the 1/32 s tick and the 1 s divider are both derived ----
    if (cal_ticks_50 !== cal_ticks_100)
      fail($sformatf("calendar tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", cal_ticks_50, cal_ticks_100));
    if (cal_ticks_50 !== 16'(CAL_EXPECTED))
      fail($sformatf("calendar tick count %0d over 99.5 ms is not the reference 1/32 s (%0d)", cal_ticks_50, CAL_EXPECTED));
    if (cal_tick_50 !== (CLK50_HZ / 32 - 1))
      fail($sformatf("calendar tick period at 50 MHz is %0d, not SYS_CLOCK_HZ/32-1", cal_tick_50));
    if (cal_tick_100 !== (CLK100_HZ / 32 - 1))
      fail($sformatf("calendar tick period at 100 MHz is %0d, not SYS_CLOCK_HZ/32-1 (the tick is a fixed 50 MHz count)", cal_tick_100));
    if (cal_hz_50 !== (CLK50_HZ - 1) || cal_hz_100 !== (CLK100_HZ - 1))
      fail($sformatf("calendar 1 Hz divider is not SYS_CLOCK_HZ-1 (%0d at 50 MHz, %0d at 100 MHz)", cal_hz_50, cal_hz_100));
    note($sformatf("calendar: %0d ticks / 99.5 ms at both clocks; 1 Hz divider %0d / %0d", cal_ticks_50, cal_hz_50, cal_hz_100));

    // ---- bus mouse IRQ13: 120 Hz at both clocks ----
    if (mouse_irq_50 !== mouse_irq_100)
      fail($sformatf("mouse IRQ13 count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", mouse_irq_50, mouse_irq_100));
    if (mouse_irq_50 !== 16'(MOUSE_EXPECTED))
      fail($sformatf("mouse IRQ13 count %0d over 99.5 ms is not the reference 120 Hz (%0d)", mouse_irq_50, MOUSE_EXPECTED));
    note($sformatf("mouse IRQ13: %0d pulses / 99.5 ms at both clocks (120 Hz)", mouse_irq_50));

    // ---- gameport 1.1 us axis tick: the same wall-clock period at both clocks ----
    if (gp_tick_50 !== gp_tick_100)
      fail($sformatf("gameport 1.1 us tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", gp_tick_50, gp_tick_100));
    if ((gp_tick_50 > GP_EXPECTED + 4) || (gp_tick_50 < GP_EXPECTED - 4))
      fail($sformatf("gameport tick count %0d over 99.5 ms is not the reference 1.1 us period (%0d)", gp_tick_50, GP_EXPECTED));
    note($sformatf("gameport: %0d axis ticks / 99.5 ms at both clocks (1.1 us)", gp_tick_50));

    // ---- ARTIC 307200 Hz: the firmware delay() timebase ----
    artic_d_50  = artic_last_50  - artic_first_50;
    artic_d_100 = artic_last_100 - artic_first_100;
    if ((artic_d_50 > artic_d_100 + 2) || (artic_d_100 > artic_d_50 + 2))
      fail($sformatf("ARTIC count is clock-dependent: %0d ticks at 50 MHz, %0d at 100 MHz over 99.5 ms", artic_d_50, artic_d_100));
    if ((artic_d_50 > ARTIC_EXPECTED + 4) || (artic_d_50 < ARTIC_EXPECTED - 4))
      fail($sformatf("ARTIC count %0d over 99.5 ms is not the reference 307200 Hz (%0d)", artic_d_50, ARTIC_EXPECTED));
    note($sformatf("ARTIC: %0d / %0d ticks over 99.5 ms (307200 Hz reference %0d); raw %06h->%06h and %06h->%06h",
         artic_d_50, artic_d_100, ARTIC_EXPECTED,
         artic_first_50, artic_last_50, artic_first_100, artic_last_100));

    // ---- the two firmware I/O-wait floors are real TIMES, so both clocks pay them ----
    // A 0x005F write is POSTED (every profile): the CPU goes on and the next I/O access waits
    // until the write's 1744 ns are up (docs/probes/XE10T-XE10.TXT /IO W8_005F, the period
    // flat over 0-340 ns of work between writes). cyc_5f times the write AND the access right
    // behind it, from the write's presentation to the second ready: the write's bus time plus
    // six fixed FSM cycles (the presenting cycle, the write's S_IDLE/S_IOWAIT before its
    // S_BYTE starts the post, and the second access's S_REPLY and ready), which come off.
    // A post that counted clk_sys fails at one of the two clocks; that the CPU is released
    // early is tb_pc9821_io_5f's.
    ns_5f_50   = (cyc_5f_50  - 16'd6) * 1000 / (CLK50_HZ  / 1_000_000);
    ns_5f_100  = (cyc_5f_100 - 16'd6) * 1000 / (CLK100_HZ / 1_000_000);
    ns_71_50   = cyc_71_50   * 1000 / (CLK50_HZ  / 1_000_000);
    ns_71_100  = cyc_71_100  * 1000 / (CLK100_HZ / 1_000_000);
    ns_def_50  = cyc_def_50  * 1000 / (CLK50_HZ  / 1_000_000);
    ns_def_100 = cyc_def_100 * 1000 / (CLK100_HZ / 1_000_000);
    if ((ns_5f_50 < CAP_5F_W) || (ns_5f_50 > CAP_5F_W + 1000 / (CLK50_HZ / 1_000_000)) ||
        (ns_5f_100 < CAP_5F_W) || (ns_5f_100 > CAP_5F_W + 1000 / (CLK100_HZ / 1_000_000)))
      fail($sformatf("the min profile's posted 0x005F WRITE is not the machine's %0d ns at both clocks: %0d ns / %0d ns", CAP_5F_W, ns_5f_50, ns_5f_100));
    if ((ns_71_50 < 407) || (ns_71_100 < 407))
      fail($sformatf("an 8253 port access does not outlast one 2.4576 MHz PIT tick (406.9 ns): %0d ns / %0d ns", ns_71_50, ns_71_100));
    note($sformatf("I/O waits: 0x5F %0d / %0d ns, 8253 %0d / %0d ns", ns_5f_50, ns_5f_100, ns_71_50, ns_71_100));

    // ---- the Xe10 class table is a set of REAL TIMES, so both clocks must pay the same ----
    // The OSD's I/O timing field at Xe10 prices every class at the machine's measured access
    // time from docs/probes/XE10T-XE10.TXT, converted from SYS_CLOCK_HZ, less the CPU's own
    // XE10_CPU_CYC (added back here) - so the same
    // access is the same wall-clock time at 50 and at 100 MHz, where the min profile's 4-clk
    // floor is 80 ns here and 40 ns there. These are the FAIL-FIRST cases the class table's own
    // derivation is for; the capture's values are NEVER taken from our RTL.
    // (The probe's window is two cycles wider than io_access_cycles' own value, the same
    // offset the 0x5F print above carries: `timed_write`/`timed_read` count from the negedge
    // the request is PRESENTED on, and the class value is that window minus two.)
    fns_def_r_50   = (fcyc_def_r_50   - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_def_r_100  = (fcyc_def_r_100  - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_def_w_50   = (fcyc_def_50     - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_def_w_100  = (fcyc_def_100    - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_grcg_w_50  = (fcyc_grcg_w_50  - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_grcg_w_100 = (fcyc_grcg_w_100 - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    // (the posted 0x5F write's window, like the min one above, spans two accesses: -6 clk)
    fns_5f_w_50    = (fcyc_5f_50      - 16'd6) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_5f_w_100   = (fcyc_5f_100     - 16'd6) * 1000 / (CLK100_HZ / 1_000_000);
    if ((fns_def_r_50 - fns_def_r_100 > TOL50) || (fns_def_r_100 - fns_def_r_50 > TOL50))
      fail($sformatf("the Xe10 default-class READ is not a real time: %0d ns at 50 MHz, %0d ns at 100 MHz", fns_def_r_50, fns_def_r_100));
    if ((fns_def_r_50 < CAP_DEF_R) || (fns_def_r_50 > CAP_DEF_R + TOL50) ||
        (fns_def_r_100 < CAP_DEF_R) || (fns_def_r_100 > CAP_DEF_R + TOL100))
      fail($sformatf("the Xe10 default-class READ is %0d / %0d ns, not the capture's %0d ns (+<=1 clk)", fns_def_r_50, fns_def_r_100, CAP_DEF_R));
    if ((fns_def_w_50 - fns_def_w_100 > TOL50) || (fns_def_w_100 - fns_def_w_50 > TOL50))
      fail($sformatf("the Xe10 default-class WRITE is not a real time: %0d ns at 50 MHz, %0d ns at 100 MHz", fns_def_w_50, fns_def_w_100));
    if ((fns_def_w_50 < CAP_DEF_W) || (fns_def_w_50 > CAP_DEF_W + TOL50) ||
        (fns_def_w_100 < CAP_DEF_W) || (fns_def_w_100 > CAP_DEF_W + TOL100))
      fail($sformatf("the Xe10 default-class WRITE is %0d / %0d ns, not the capture's %0d ns (+<=1 clk)", fns_def_w_50, fns_def_w_100, CAP_DEF_W));
    if ((fns_grcg_w_50 - fns_grcg_w_100 > TOL50) || (fns_grcg_w_100 - fns_grcg_w_50 > TOL50))
      fail($sformatf("the Xe10 0x007E GRCG write is not a real time: %0d ns at 50 MHz, %0d ns at 100 MHz", fns_grcg_w_50, fns_grcg_w_100));
    if ((fns_grcg_w_50 < CAP_GRCG_W) || (fns_grcg_w_50 > CAP_GRCG_W + TOL50) ||
        (fns_grcg_w_100 < CAP_GRCG_W) || (fns_grcg_w_100 > CAP_GRCG_W + TOL100))
      fail($sformatf("the Xe10 0x007E GRCG write is %0d / %0d ns, not the capture's %0d ns (+<=1 clk)", fns_grcg_w_50, fns_grcg_w_100, CAP_GRCG_W));
    if ((fns_5f_w_50 - fns_5f_w_100 > TOL50) || (fns_5f_w_100 - fns_5f_w_50 > TOL50))
      fail($sformatf("the Xe10 0x005F WRITE is not a real time: %0d ns at 50 MHz, %0d ns at 100 MHz", fns_5f_w_50, fns_5f_w_100));
    if ((fns_5f_w_50 < CAP_5F_W) || (fns_5f_w_50 > CAP_5F_W + TOL50) ||
        (fns_5f_w_100 < CAP_5F_W) || (fns_5f_w_100 > CAP_5F_W + TOL100))
      fail($sformatf("the Xe10 posted 0x005F WRITE is %0d / %0d ns, not the capture's %0d ns (+<=1 clk)", fns_5f_w_50, fns_5f_w_100, CAP_5F_W));
    if (fns_def_w_50 <= fns_def_r_50)
      fail($sformatf("the capture prices the default class per direction (read %0d / write %0d ns); the Xe10 table lost the split: %0d / %0d ns", CAP_DEF_R, CAP_DEF_W, fns_def_r_50, fns_def_w_50));
    note($sformatf("Xe10 I/O classes: default R %0d / %0d ns (capture %0d), default W %0d / %0d ns (capture %0d), 0x7E W %0d / %0d ns (capture %0d), 0x5F W %0d / %0d ns (capture %0d)",
         fns_def_r_50, fns_def_r_100, CAP_DEF_R, fns_def_w_50, fns_def_w_100, CAP_DEF_W,
         fns_grcg_w_50, fns_grcg_w_100, CAP_GRCG_W, fns_5f_w_50, fns_5f_w_100, CAP_5F_W));

    // ---- the VIDEO side: the 0x60 data-ready bit and the dot-counted raster ----
    // FAIL-FIRST: stat_dr was `stat_dr <= ~stat_dr` on every clk_sys, so this first check reads
    // 2x at 100 MHz before the fix. THE RATE ITSELF IS NOT A MACHINE FACT (see the header): the
    // histogram measures only the duty, so what is asserted is the DERIVATION (one toggle per
    // two PIXEL_HZ dots) plus the two clocks' agreement - never the hardware's period.
    if ((dr_50 > dr_100 + 32'd2) || (dr_100 > dr_50 + 32'd2))
      fail($sformatf("0x60 status bit 0 (stat_dr) is not clock-invariant: %0d edges at 50 MHz, %0d at 100 MHz over 99.5 ms", dr_50, dr_100));
    if ((dr_50 > DR_EXPECTED + 4) || (dr_50 < DR_EXPECTED - 4))
      fail($sformatf("0x60 status bit 0 (stat_dr) reads %0d edges / 99.5 ms, not the dot-derived %0d (one toggle per two dots at 21.0526 MHz)", dr_50, DR_EXPECTED));
    note($sformatf("crtc stat_dr: %0d / %0d edges over 99.5 ms (dot-derived %0d; the machine's own rate is UNMEASURED - only its ~50 %% duty is captured)", dr_50, dr_100, DR_EXPECTED));

    // The raster is the guest's SYNC block counted in DOTS, so it must be the same wall-clock
    // period at both clocks: pre-fix this passed and must keep passing (it is the regression
    // guard for the clock the stat_dr fix now shares).
    if (lin_50 !== lin_100)
      fail($sformatf("CRTC line count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz over 99.5 ms", lin_50, lin_100));
    if ((lin_50 > LINES_EXPECTED + 1) || (lin_50 < LINES_EXPECTED - 1))
      fail($sformatf("CRTC line count %0d over 99.5 ms is not the SYNC block's %0d (848 dots / 21.0526 MHz)", lin_50, LINES_EXPECTED));
    if (frm_50 !== frm_100)
      fail($sformatf("CRTC frame count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz over 99.5 ms", frm_50, frm_100));
    if (frm_50 !== FRAMES_EXPECTED)
      fail($sformatf("CRTC frame count %0d over 99.5 ms is not the SYNC block's %0d (848 x 440 dots)", frm_50, FRAMES_EXPECTED));
    if (de_line_50 !== DE_LINE || de_line_100 !== DE_LINE)
      fail($sformatf("the CRTC's active width is %0d / %0d dots, not the block's %0d (cr = 80 characters)", de_line_50, de_line_100, DE_LINE));
    if ((line_ns_50 > LINE_NS + 100) || (line_ns_50 < LINE_NS - 100))
      fail($sformatf("the CRTC's line period is %0d ns, not the block's %0d (848 dots / 21.0526 MHz)", line_ns_50, LINE_NS));
    if (line_ns_50 > line_ns_100 + 30)
      fail($sformatf("the CRTC's line period is not clock-invariant: %0d ns at 50 MHz, %0d ns at 100 MHz", line_ns_50, line_ns_100));
    if ((frame_ns_50 > FRAME_NS + 50_000) || (frame_ns_50 < FRAME_NS - 50_000))
      fail($sformatf("the CRTC's frame period is %0d ns, not the block's %0d (848 x 440 dots / 21.0526 MHz)", frame_ns_50, FRAME_NS));
    if (frame_ns_50 > frame_ns_100 + 1_000)
      fail($sformatf("the CRTC's frame period is not clock-invariant: %0d ns at 50 MHz, %0d ns at 100 MHz", frame_ns_50, frame_ns_100));
    if ((hs_w_50 > HS_WIDTH_NS + 100) || (hs_w_50 < HS_WIDTH_NS - 100))
      fail($sformatf("the CRTC's hsync pulse is %0d ns wide, not the block's %0d (hs = 7 => 64 dots)", hs_w_50, HS_WIDTH_NS));
    note($sformatf("crtc raster: %0d lines / %0d frames over 99.5 ms, active %0d dots/line, line %0d / %0d ns, frame %0d / %0d ns, hsync %0d / %0d ns",
         lin_50, frm_50, de_line_50, line_ns_50, line_ns_100, frame_ns_50, frame_ns_100, hs_w_50, hs_w_100));

    // ---- the 31 kHz raster at both clocks (0x09A8 bit 0 set) ----
    // The capture's rates (docs/probes/CRT31K.TXT, the ARTIC calibrated by its 24 kHz rows as
    // tools/hwprobe/crt31k/crt31k_decode.py does): a 70.0669 Hz frame = 14 272 074 ns and a
    // 31 460.04 Hz line = 31 786.4 ns. Each probe averages three whole frames, so the clk_sys sampling
    // (20 / 10 ns) is under 0.5 ppm of the frame; the band is the capture's own ~3 ppm.
    if ((f31_ns_50 > F31_NS + 43) || (f31_ns_50 < F31_NS - 43) || (f31_ns_100 > F31_NS + 43) || (f31_ns_100 < F31_NS - 43))
      fail($sformatf("the 31 kHz frame is %0d / %0d ns at 50 / 100 MHz, not the capture's %0d ns (70.0669 Hz, within 3 ppm)", f31_ns_50, f31_ns_100, F31_NS));
    if ((l31_ns_50 > L31_NS + 1) || (l31_ns_50 < L31_NS - 1) || (l31_ns_100 > L31_NS + 1) || (l31_ns_100 < L31_NS - 1))
      fail($sformatf("the 31 kHz line is %0d / %0d (x 0.1 ns) at 50 / 100 MHz, not the capture's %0d (31.460 kHz)", l31_ns_50, l31_ns_100, L31_NS));
    if ((f31_ns_50 > f31_ns_100 + 20) || (f31_ns_100 > f31_ns_50 + 20) || (l31_n_50 != l31_n_100))
      fail($sformatf("the 31 kHz raster is clock-dependent: frame %0d / %0d ns, %0d / %0d lines", f31_ns_50, f31_ns_100, l31_n_50, l31_n_100));
    note($sformatf("31 kHz raster: frame %0d / %0d ns (capture %0d), line %0d / %0d x 0.1 ns (capture %0d), %0d / %0d lines in three frames",
         f31_ns_50, f31_ns_100, F31_NS, l31_ns_50, l31_ns_100, L31_NS, l31_n_50, l31_n_100));
    // DISPLAY ONLY - the deliberately waived divergence, not an assertion.
    note($sformatf("I/O class floor (NOT asserted): one default-class access is %0d ns at 50 MHz and %0d ns at 100 MHz; the machine's measured default class is 840 ns",
         ns_def_50, ns_def_100));

    // ---- PIT channel 1 (the beeper's tone) and channel 2 (the RS-232C clock) ----
    // Same 8253, same 2.4576 MHz input clock, different CHANNEL: the period is
    // divisor / 2.4576 MHz, a real time, and the count over the shared window must be the
    // same at both clocks and match that rate (the BIOS's own beep program for ch1:
    // control 0x76, divisor 0x04CD = 1229 -> 1999.7 Hz).
    if (pit1_edges_50 !== pit1_edges_100)
      fail($sformatf("PIT ch1 tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", pit1_edges_50, pit1_edges_100));
    if ((pit1_edges_50 > 16'(PIT1_EXPECTED + 3)) || (pit1_edges_50 < 16'(PIT1_EXPECTED - 3)))
      fail($sformatf("PIT ch1 (the beeper's 0x04CD program) tick count %0d over 99.5 ms is not the reference 1999.7 Hz (%0d)", pit1_edges_50, PIT1_EXPECTED));
    note($sformatf("PIT ch1 (beeper tone): %0d ticks / 99.5 ms at both clocks (2.4576 MHz / 0x04CD = 1999.7 Hz)", pit1_edges_50));
    if (pit2_edges_50 !== pit2_edges_100)
      fail($sformatf("PIT ch2 tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", pit2_edges_50, pit2_edges_100));
    if ((pit2_edges_50 > 16'(PIT2_EXPECTED + 3)) || (pit2_edges_50 < 16'(PIT2_EXPECTED - 3)))
      fail($sformatf("PIT ch2 (RS-232C clock, divisor 0x0180) tick count %0d over 99.5 ms is not 2.4576 MHz / 0x0180 = 6400 Hz (%0d)", pit2_edges_50, PIT2_EXPECTED));
    note($sformatf("PIT ch2 (RS-232C clock): %0d ticks / 99.5 ms at both clocks (2.4576 MHz / 0x0180 = 6400 Hz)", pit2_edges_50));

    // ---- calendar: the OTHER two guest-writable tick rates (1/64 s and 1/16 s) ----
    // tick_rate is the guest's field at 0x128 (pc9821_calendar.sv:150 (tick_rate == 2'd3)): 0 = 1/64 s,
    // 1 = 1/32 s, 2 = off, 3 = 1/16 s. Each is a period, so the IRQ count is
    // window / period at BOTH clocks; the register's own clk count (tick_period) doubles
    // with SYS_CLOCK_HZ, which is what makes the TIME invariant.
    if (cal64_ticks_50 !== cal64_ticks_100)
      fail($sformatf("calendar 1/64 s tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", cal64_ticks_50, cal64_ticks_100));
    if ((cal64_ticks_50 > 16'(CAL64_EXPECTED + 1)) || (cal64_ticks_50 < 16'(CAL64_EXPECTED - 1)))
      fail($sformatf("calendar 1/64 s tick count %0d over 99.5 ms is not the register's 1/64 s (%0d)", cal64_ticks_50, CAL64_EXPECTED));
    if (cal64_tick_50 !== (CLK50_HZ / 64 - 1) || cal64_tick_100 !== (CLK100_HZ / 64 - 1))
      fail($sformatf("calendar 1/64 s divider is not SYS_CLOCK_HZ/64-1 (%0d at 50 MHz, %0d at 100 MHz)", cal64_tick_50, cal64_tick_100));
    if (cal16_ticks_50 !== cal16_ticks_100)
      fail($sformatf("calendar 1/16 s tick count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", cal16_ticks_50, cal16_ticks_100));
    if ((cal16_ticks_50 > 16'(CAL16_EXPECTED + 1)) || (cal16_ticks_50 < 16'(CAL16_EXPECTED - 1)))
      fail($sformatf("calendar 1/16 s tick count %0d over 99.5 ms is not the register's 1/16 s (%0d)", cal16_ticks_50, CAL16_EXPECTED));
    if (cal16_tick_50 !== (CLK50_HZ / 16 - 1) || cal16_tick_100 !== (CLK100_HZ / 16 - 1))
      fail($sformatf("calendar 1/16 s divider is not SYS_CLOCK_HZ/16-1 (%0d at 50 MHz, %0d at 100 MHz)", cal16_tick_50, cal16_tick_100));
    note($sformatf("calendar rates: 1/64 s %0d / %0d ticks (divider %0d / %0d), 1/16 s %0d / %0d ticks (divider %0d / %0d)",
         cal64_ticks_50, cal64_ticks_100, cal64_tick_50, cal64_tick_100,
         cal16_ticks_50, cal16_ticks_100, cal16_tick_50, cal16_tick_100));

    // ---- keyboard typematic: NP2kai's 500 ms delay / 50 ms interval ----
    // The window a key's auto-repeat ARMS, converted to wall clock at each clock
    // (value clk x 1e9 / HZ ns, done in two steps so the 32-bit product cannot overflow).
    // A model deriving it from clk_sys without dividing reads 500 ms at 50 MHz and 1 s at
    // 100 MHz here.
    kbd_rep_del_ns_50  = (kbd_rep_del_50  / (CLK50_HZ  / 1_000_000)) * 1000;
    kbd_rep_del_ns_100 = (kbd_rep_del_100 / (CLK100_HZ / 1_000_000)) * 1000;
    kbd_rep_int_ns_50  = (kbd_rep_int_50  / (CLK50_HZ  / 1_000_000)) * 1000;
    kbd_rep_int_ns_100 = (kbd_rep_int_100 / (CLK100_HZ / 1_000_000)) * 1000;
    if ((kbd_rep_del_ns_50 > KBD_REP_DEL_NS + TOL50) || (kbd_rep_del_ns_50 < KBD_REP_DEL_NS - TOL50) ||
        (kbd_rep_del_ns_100 > KBD_REP_DEL_NS + TOL100) || (kbd_rep_del_ns_100 < KBD_REP_DEL_NS - TOL100))
      fail($sformatf("kbd typematic delay is %0d / %0d ns, not NP2kai's 500 ms (%0d ns)", kbd_rep_del_ns_50, kbd_rep_del_ns_100, KBD_REP_DEL_NS));
    if ((kbd_rep_int_ns_50 > KBD_REP_INT_NS + TOL50) || (kbd_rep_int_ns_50 < KBD_REP_INT_NS - TOL50) ||
        (kbd_rep_int_ns_100 > KBD_REP_INT_NS + TOL100) || (kbd_rep_int_ns_100 < KBD_REP_INT_NS - TOL100))
      fail($sformatf("kbd typematic interval is %0d / %0d ns, not NP2kai's 50 ms (%0d ns)", kbd_rep_int_ns_50, kbd_rep_int_ns_100, KBD_REP_INT_NS));
    if ((kbd_rep_del_ns_50 > kbd_rep_del_ns_100 + TOL50) || (kbd_rep_del_ns_100 > kbd_rep_del_ns_50 + TOL50) ||
        (kbd_rep_int_ns_50 > kbd_rep_int_ns_100 + TOL50) || (kbd_rep_int_ns_100 > kbd_rep_int_ns_50 + TOL50))
      fail($sformatf("kbd typematic windows are not clock-invariant: %0d / %0d ns (delay), %0d / %0d ns (interval)",
           kbd_rep_del_ns_50, kbd_rep_del_ns_100, kbd_rep_int_ns_50, kbd_rep_int_ns_100));
    note($sformatf("kbd typematic: delay %0d / %0d ns, interval %0d / %0d ns (NP2kai 500 ms / 50 ms)",
         kbd_rep_del_ns_50, kbd_rep_del_ns_100, kbd_rep_int_ns_50, kbd_rep_int_ns_100));

    // ---- the calendar's CDAT serial read: the bit clock is the GUEST's ----
    // Both instances are driven by ONE wall-clock command schedule (#-delays, so the two
    // clocks see the same ns), and the 48 bits recovered from cdat must be identical - the
    // payload is the date those registers hold and the read's pacing is the guest's CLK, so
    // no clk_sys count can appear in it. A core-side divider in this path would desynchronise
    // one side and the two payloads would differ.
    if (cal_ser_n_50 !== 16'd48 || cal_ser_n_100 !== 16'd48)
      fail($sformatf("the calendar serial read clocked %0d / %0d bits, not 48", cal_ser_n_50, cal_ser_n_100));
    if (cal_ser_50 !== CAL_SER_PAYLOAD)
      fail($sformatf("calendar CDAT payload is %012h, not the loaded date %012h", cal_ser_50, CAL_SER_PAYLOAD));
    if (cal_ser_100 !== CAL_SER_PAYLOAD)
      fail($sformatf("calendar CDAT payload at 100 MHz is %012h, not the loaded date %012h (the serial path is not the guest's clock)", cal_ser_100, CAL_SER_PAYLOAD));
    // The walk is not a clk count: the two instances are driven by the SAME wall-clock
    // schedule (#-delays), so after the same 48 clocks their shift registers must also
    // agree bit for bit - an internal divider or timeout in the serial path would leave one
    // of them at a different bit.
    if (calser50.dut.sreg !== calser100.dut.sreg)
      fail($sformatf("the calendar's CDAT shift register disagrees across the two clocks after the same guest schedule: %013h vs %013h",
           calser50.dut.sreg, calser100.dut.sreg));
    note($sformatf("calendar CDAT serial read: %012h at both clocks from one wall-clock schedule (48 bits, guest-clocked; shift register %013h on both)", cal_ser_50, calser50.dut.sreg));

    // ---- the bus mouse at its guest-programmed timings 1 and 2 ----
    if (mouse_irq_50 !== mouse_irq_100)
      fail($sformatf("mouse IRQ13 (timing 0) count is clock-dependent: %0d / %0d", mouse_irq_50, mouse_irq_100));
    if (mouse_per_50 !== 32'(CLK50_HZ / 120) || mouse_per_100 !== 32'(CLK100_HZ / 120))
      fail($sformatf("mouse timing-0 period is %0d / %0d clk, not SYS_CLOCK_HZ/120", mouse_per_50, mouse_per_100));
    if (mouse60_irq_50 !== mouse60_irq_100)
      fail($sformatf("mouse IRQ13 (timing 1, 60 Hz) count is clock-dependent: %0d / %0d", mouse60_irq_50, mouse60_irq_100));
    if ((mouse60_per_50 !== 32'(2 * (CLK50_HZ / 120))) || (mouse60_per_100 !== 32'(2 * (CLK100_HZ / 120))))
      fail($sformatf("mouse timing-1 period is %0d / %0d clk, not (SYS_CLOCK_HZ/120)<<1", mouse60_per_50, mouse60_per_100));
    if ((mouse60_irq_50 > 16'(MOUSE60_EXPECTED + 1)) || (mouse60_irq_50 < 16'(MOUSE60_EXPECTED - 1)))
      fail($sformatf("mouse timing-1 count %0d over 99.5 ms is not the reference 60 Hz (%0d)", mouse60_irq_50, MOUSE60_EXPECTED));
    if (mouse30_irq_50 !== mouse30_irq_100)
      fail($sformatf("mouse IRQ13 (timing 2, 30 Hz) count is clock-dependent: %0d / %0d", mouse30_irq_50, mouse30_irq_100));
    if ((mouse30_per_50 !== 32'(4 * (CLK50_HZ / 120))) || (mouse30_per_100 !== 32'(4 * (CLK100_HZ / 120))))
      fail($sformatf("mouse timing-2 period is %0d / %0d clk, not (SYS_CLOCK_HZ/120)<<2", mouse30_per_50, mouse30_per_100));
    if ((mouse30_irq_50 > 16'(MOUSE30_EXPECTED + 1)) || (mouse30_irq_50 < 16'(MOUSE30_EXPECTED - 1)))
      fail($sformatf("mouse timing-2 count %0d over 99.5 ms is not the reference 30 Hz (%0d)", mouse30_irq_50, MOUSE30_EXPECTED));
    note($sformatf("mouse IRQ13: timing 0 %0d, timing 1 %0d, timing 2 %0d pulses / 99.5 ms at both clocks (120/60/30 Hz)",
         mouse_irq_50, mouse60_irq_50, mouse30_irq_50));

    // ---- the game port's axis one-shot: 1022 of its own 1.1 us ticks ----
    // The trigger loads the IBM formula's t = 24.2 us + 0.011 us * R for the right end stop
    // (R = 1000 -> 1022 ticks of 1.1 us), and the pulse the guest times is that many ticks of
    // wall clock, so the width in ns must be the same at both clocks. One clk_sys of
    // resolution plus one tick of the discharge chain are the band.
    if ((gp_width_50 > GP_AXIS_NS + GP_TOL_NS) || (gp_width_50 < GP_AXIS_NS - GP_TOL_NS))
      fail($sformatf("gameport axis pulse is %0d ns, not the formula's 1022 x 1.1 us = %0d ns", gp_width_50, GP_AXIS_NS));
    if ((gp_width_50 > gp_width_100 + GP_TOL_NS) || (gp_width_100 > gp_width_50 + GP_TOL_NS))
      fail($sformatf("gameport axis pulse is not clock-invariant: %0d ns at 50 MHz, %0d ns at 100 MHz", gp_width_50, gp_width_100));
    note($sformatf("gameport axis one-shot: %0d / %0d ns for the right end stop (the formula's %0d ns = 1022 ticks x 1.1 us)",
         gp_width_50, gp_width_100, GP_AXIS_NS));

    // ---- the GVRAM arbiter's holds: the capture's TIMES, never a cycle count ----
    // pc9821_gvram_arb.sv:406 (GVRAM_RD_HOLD) converts the Xe10 capture's 478 ns read / 142 ns write /
    // 104 ns GRCG store from SYS_CLOCK_HZ, so the CONSTANT is a clk count and the TIME it
    // encodes must be the same at both clocks (each rounds to whole cycles, hence one
    // clk_sys of tolerance on the capture's own value). These set the CPU's effective
    // GVRAM latency, so a clk_sys count here would speed the machine's drawing up with the
    // profile - the property gvram-latency-fix exists to have.
    gv_rd_ns_50  = gv_rd_hold_50  * 1000 / (CLK50_HZ  / 1_000_000);
    gv_rd_ns_100 = gv_rd_hold_100 * 1000 / (CLK100_HZ / 1_000_000);
    gv_wr_ns_50  = gv_wr_hold_50  * 1000 / (CLK50_HZ  / 1_000_000);
    gv_wr_ns_100 = gv_wr_hold_100 * 1000 / (CLK100_HZ / 1_000_000);
    gv_gr_ns_50  = gv_gr_hold_50  * 1000 / (CLK50_HZ  / 1_000_000);
    gv_gr_ns_100 = gv_gr_hold_100 * 1000 / (CLK100_HZ / 1_000_000);
    if ((gv_rd_ns_50 > CAP_GV_RD + TOL50) || (gv_rd_ns_50 < CAP_GV_RD - TOL50) ||
        (gv_rd_ns_100 > CAP_GV_RD + TOL100) || (gv_rd_ns_100 < CAP_GV_RD - TOL100))
      fail($sformatf("the GVRAM read hold is %0d / %0d ns, not the capture's %0d ns", gv_rd_ns_50, gv_rd_ns_100, CAP_GV_RD));
    if ((gv_wr_ns_50 > CAP_GV_WR + TOL50) || (gv_wr_ns_50 < CAP_GV_WR - TOL50) ||
        (gv_wr_ns_100 > CAP_GV_WR + TOL100) || (gv_wr_ns_100 < CAP_GV_WR - TOL100))
      fail($sformatf("the GVRAM write hold is %0d / %0d ns, not the capture's %0d ns", gv_wr_ns_50, gv_wr_ns_100, CAP_GV_WR));
    if ((gv_gr_ns_50 > CAP_GV_GR + TOL50) || (gv_gr_ns_50 < CAP_GV_GR - TOL50) ||
        (gv_gr_ns_100 > CAP_GV_GR + TOL100) || (gv_gr_ns_100 < CAP_GV_GR - TOL100))
      fail($sformatf("the GVRAM GRCG store hold is %0d / %0d ns, not the capture's %0d ns", gv_gr_ns_50, gv_gr_ns_100, CAP_GV_GR));
    if ((gv_rd_hold_50 * 2) !== gv_rd_hold_100)
      fail($sformatf("the GVRAM read hold is a fixed CYCLE count, not the capture's time: %0d clk at 50 MHz vs %0d at 100 MHz", gv_rd_hold_50, gv_rd_hold_100));
    note($sformatf("GVRAM holds: read %0d / %0d ns (%0d / %0d clk), write %0d / %0d ns, GRCG %0d / %0d ns (capture 478 / 142 / 104 ns)",
         gv_rd_ns_50, gv_rd_ns_100, gv_rd_hold_50, gv_rd_hold_100, gv_wr_ns_50, gv_wr_ns_100, gv_gr_ns_50, gv_gr_ns_100));

    // ---- the FDC's recalibrate delay: 20 us of wall clock ----
    fdc_recal_ns_50  = fdc_recal_50  * 1000 / (CLK50_HZ  / 1_000_000);
    fdc_recal_ns_100 = fdc_recal_100 * 1000 / (CLK100_HZ / 1_000_000);
    if ((fdc_recal_ns_50 > 20_200) || (fdc_recal_ns_50 < 19_800) ||
        (fdc_recal_ns_100 > 20_100) || (fdc_recal_ns_100 < 19_900))
      fail($sformatf("the FDC's RECAL_CYCLES is %0d / %0d ns, not the 20 us the constant is named for", fdc_recal_ns_50, fdc_recal_ns_100));
    if ((fdc_recal_50 * 2) !== fdc_recal_100)
      fail($sformatf("the FDC's RECAL_CYCLES is not SYS_CLOCK_HZ-derived: %0d clk at 50 MHz vs %0d at 100 MHz", fdc_recal_50, fdc_recal_100));
    // The FDC's TRANSFER pacing is the media engine's request/ready walk (pc9821_fdd_media
    // has no SYS_CLOCK_HZ at all), so there is no data-rate clk count to test here: the
    // 2DD/2HD rate is the drive's, and the walk is paced by the guest's own accesses.
    note($sformatf("FDC recalibrate: %0d / %0d ns (%0d / %0d clk) - and pc9821_fdd_media holds no SYS_CLOCK_HZ, so the data rate is the drive's, not a clk_sys count",
         fdc_recal_ns_50, fdc_recal_ns_100, fdc_recal_50, fdc_recal_100));

    // ---- the OPNA: its own clock enable, its SSG rate and its guest-programmed timers ----
    // cen is the chip's 7.9872 MHz (pc9821_opna.sv:97 (CEN_STEP)); the SSG is cen/16 = 499.2 kHz.
    // Timer A and Timer B are programmed through the same host port pc9821_iobus drives
    // (0x188 select / 0x18A data), and their period is the chip clock times the guest's
    // value: 144*(1024-NA) and 2304*(256-NB) chip enables (jt12_timers.v's header formula;
    // NP2kai sound/opntimer.c:30,53 is the same period in its own quantisation). A model
    // counting clk_sys would put 2x the enables in the same window at 100 MHz.
    if (opna_cen_50 !== opna_cen_100)
      fail($sformatf("the OPNA's chip enable count is clock-dependent: %0d at 50 MHz, %0d at 100 MHz", opna_cen_50, opna_cen_100));
    if ((opna_cen_50 > 32'(OPNA_CEN_EXPECTED + 2000)) || (opna_cen_50 < 32'(OPNA_CEN_EXPECTED - 2000)))
      fail($sformatf("the OPNA's chip enable is %0d over 99.5 ms, not 7.9872 MHz (%0d)", opna_cen_50, OPNA_CEN_EXPECTED));
    if (opna_ssg_50 !== opna_ssg_100)
      fail($sformatf("the OPNA's SSG sample enable count is clock-dependent: %0d / %0d", opna_ssg_50, opna_ssg_100));
    if ((opna_ssg_50 > 32'(OPNA_SSG_EXPECTED + 200)) || (opna_ssg_50 < 32'(OPNA_SSG_EXPECTED - 200)))
      fail($sformatf("the OPNA's SSG sample enable is %0d over 99.5 ms, not cen/16 = 499.2 kHz (%0d)", opna_ssg_50, OPNA_SSG_EXPECTED));
    if (opna_ta_clk_50 === 32'd0 || opna_ta_clk_100 === 32'd0)
      fail($sformatf("OPNA Timer A's interrupt never rose (0 clk counted at 50/100 MHz)"));
    opna_ta_ns_50  = opna_ta_clk_50  * 1000 / (CLK50_HZ  / 1_000_000);
    opna_ta_ns_100 = opna_ta_clk_100 * 1000 / (CLK100_HZ / 1_000_000);
    if ((opna_ta_ns_50 > OPNA_TA_PERIOD_NS * 102 / 100) || (opna_ta_ns_50 < OPNA_TA_PERIOD_NS * 98 / 100) ||
        (opna_ta_ns_100 > OPNA_TA_PERIOD_NS * 102 / 100) || (opna_ta_ns_100 < OPNA_TA_PERIOD_NS * 98 / 100))
      fail($sformatf("OPNA Timer A (value 960) fired one period in %0d / %0d ns, not the chip's 64 x 144 master clocks / 7.9872 MHz = %0d ns (%0d / %0d clk)",
           opna_ta_ns_50, opna_ta_ns_100, OPNA_TA_PERIOD_NS, opna_ta_clk_50, opna_ta_clk_100));
    if (opna_tb_clk_50 === 32'd0 || opna_tb_clk_100 === 32'd0)
      fail($sformatf("OPNA Timer B's interrupt never rose (0 clk counted at 50/100 MHz)"));
    opna_tb_ns_50  = opna_tb_clk_50  * 1000 / (CLK50_HZ  / 1_000_000);
    opna_tb_ns_100 = opna_tb_clk_100 * 1000 / (CLK100_HZ / 1_000_000);
    if ((opna_tb_ns_50 > OPNA_TB_PERIOD_NS * 102 / 100) || (opna_tb_ns_50 < OPNA_TB_PERIOD_NS * 98 / 100) ||
        (opna_tb_ns_100 > OPNA_TB_PERIOD_NS * 102 / 100) || (opna_tb_ns_100 < OPNA_TB_PERIOD_NS * 98 / 100))
      fail($sformatf("OPNA Timer B (value 240) fired one period in %0d / %0d ns, not the chip's 16 x 2304 master clocks / 7.9872 MHz = %0d ns (%0d / %0d clk)",
           opna_tb_ns_50, opna_tb_ns_100, OPNA_TB_PERIOD_NS, opna_tb_clk_50, opna_tb_clk_100));
    note($sformatf("OPNA: cen %0d / %0d enables (7.9872 MHz), ssg %0d / %0d (cen/16 = 499.2 kHz), Timer A one period in %0d / %0d ns (%0d / %0d clk), Timer B in %0d / %0d ns (%0d / %0d clk)",
         opna_cen_50, opna_cen_100, opna_ssg_50, opna_ssg_100,
         opna_ta_ns_50, opna_ta_ns_100, opna_ta_clk_50, opna_ta_clk_100,
         opna_tb_ns_50, opna_tb_ns_100, opna_tb_clk_50, opna_tb_clk_100));

    // ---- PCM86: the sample strobe at a guest-selected rate ----
    // NP2kai's pcm86rate8 table (sound/pcm86c.c:35) is eight rates; rate 0 is 44100 Hz and
    // rate 7 is 4134.375 Hz. The strobe is the accumulator's carry, so the count over the
    // shared window must be that many samples at BOTH clocks.
    if (pcm_tick_50 !== pcm_tick_100)
      fail($sformatf("PCM86 sample strobe (rate 0) count is clock-dependent: %0d / %0d", pcm_tick_50, pcm_tick_100));
    if ((pcm_tick_50 > 32'(PCM0_EXPECTED + 4)) || (pcm_tick_50 < 32'(PCM0_EXPECTED - 4)))
      fail($sformatf("PCM86 rate 0 produced %0d samples over 99.5 ms, not 44100 Hz (%0d)", pcm_tick_50, PCM0_EXPECTED));
    if (pcm_tick7_50 !== pcm_tick7_100)
      fail($sformatf("PCM86 sample strobe (rate 7) count is clock-dependent: %0d / %0d", pcm_tick7_50, pcm_tick7_100));
    if ((pcm_tick7_50 > 32'(PCM7_EXPECTED + 4)) || (pcm_tick7_50 < 32'(PCM7_EXPECTED - 4)))
      fail($sformatf("PCM86 rate 7 produced %0d samples over 99.5 ms, not 4134.375 Hz (%0d)", pcm_tick7_50, PCM7_EXPECTED));
    note($sformatf("PCM86: rate 0 %0d / %0d samples (44100 Hz), rate 7 %0d / %0d samples (4134.375 Hz)",
         pcm_tick_50, pcm_tick_100, pcm_tick7_50, pcm_tick7_100));
    // ...and the other six entries, from the reference's own pcm86rate8 table (NP2kai
    // sound/pcm86c.c:35): the step the module derives must imply the same REAL rate at both
    // clocks, which a clk_sys count cannot do (it would imply 2x at 100 MHz).
    pcm_step("z0  44100 Hz   ", 44_100_000, pcm_50.dut.STEP0, pcm_100.dut.STEP0);
    pcm_step("z1  33075 Hz   ", 33_075_000, pcm_50.dut.STEP1, pcm_100.dut.STEP1);
    pcm_step("z2  22050 Hz   ", 22_050_000, pcm_50.dut.STEP2, pcm_100.dut.STEP2);
    pcm_step("z3  16537.5 Hz ", 16_537_500, pcm_50.dut.STEP3, pcm_100.dut.STEP3);
    pcm_step("z4  11025 Hz   ", 11_025_000, pcm_50.dut.STEP4, pcm_100.dut.STEP4);
    pcm_step("z5  8268.75 Hz ",  8_268_750, pcm_50.dut.STEP5, pcm_100.dut.STEP5);
    pcm_step("z6  5501.25 Hz ",  5_501_250, pcm_50.dut.STEP6, pcm_100.dut.STEP6);
    pcm_step("z7  4134.375 Hz",  4_134_375, pcm_50.dut.STEP7, pcm_100.dut.STEP7);

    // ---- the PRODUCTION pixel enable ----
    // pc9821_system's own video_ce, counted at both clocks and converted with the window: a
    // divider that counted clk_sys reads 2x at 100 MHz here, and a divider with a different
    // PIXEL_HZ reads a different rate at BOTH. This is the check the bench did not have - it
    // drove the CRTC with its OWN copy of PIXEL_CE_INC, so a change to the RTL formula was
    // invisible. The CRTC checks above now ride this same enable.
    if ((ce_edges_50 > ce_edges_100 + 32'd4) || (ce_edges_100 > ce_edges_50 + 32'd4))
      fail($sformatf("the PRODUCTION video_ce (pc9821_system's pixel_ce) is not clock-invariant: %0d edges at 50 MHz, %0d at 100 MHz over 99.5 ms", ce_edges_50, ce_edges_100));
    if ((ce_edges_50 > 32'(CE_EXPECTED + 200)) || (ce_edges_50 < 32'(CE_EXPECTED - 200)))
      fail($sformatf("the PRODUCTION video_ce produced %0d dot enables over 99.5 ms, not the 21.0526 MHz dot rate (%0d)", ce_edges_50, CE_EXPECTED));
    // The shipped CRTC is held in reset until cpu_run (pc9821_system.sv:1935 (rst_n_sys =)
    // !(reset || !cpu_run), and cpu_run = rom_ready), and this bench loads no pack, so the
    // production RASTER runs no lines here - the raster numbers above are the standalone
    // crtc_probe's, driven by the same production enable. The two clocks' agreement is
    // still asserted; the count is printed with its reason.
    if (sys_hs_50 !== sys_hs_100 || sys_vs_50 !== sys_vs_100)
      fail($sformatf("pc9821_system's own raster counters are clock-dependent: %0d / %0d lines, %0d / %0d frames",
           sys_hs_50, sys_hs_100, sys_vs_50, sys_vs_100));
    note($sformatf("PRODUCTION video: video_ce %0d / %0d dot enables over 99.5 ms (21.0526 MHz; the enable is ungated by cpu_run, which is what makes it the production divider's rate), pc9821_system's own raster %0d / %0d lines (held in reset without a loaded pack - the raster checks above are the standalone CRTC driven by this same enable)",
         ce_edges_50, ce_edges_100, sys_hs_50, sys_hs_100));

    // ---- the Xe10 class table's remaining captured rows ----
    // Each of these is a docs/probes/XE10T-XE10.TXT /IO row: the machine's own measured time
    // for that class, converted per profile (the CPU's share added back). Asserted the same way as the rows above - the same
    // real time at both clocks, and within one clk_sys of the capture. The min profile's
    // value for the same access is PRINTED beside it and asserted by nothing (Fast's).
    fns_egc_r_50   = (fcyc_egc_r_50   - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_egc_r_100  = (fcyc_egc_r_100  - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_egc_w_50   = (fcyc_egc_w_50   - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_egc_w_100  = (fcyc_egc_w_100  - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_gdc1_50    = (fcyc_gdc1_50    - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_gdc1_100   = (fcyc_gdc1_100   - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_gdc2_50    = (fcyc_gdc2_50    - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_gdc2_100   = (fcyc_gdc2_100   - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_pit_w_50   = (fcyc_pit_w_50   - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_pit_w_100  = (fcyc_pit_w_100  - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_5f_r_50    = (fcyc_5f_r_50    - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_5f_r_100   = (fcyc_5f_r_100   - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_egcf_e_50  = (fcyc_egcf_e_50  - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_egcf_e_100 = (fcyc_egcf_e_100 - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fns_egcf_o_50  = (fcyc_egcf_o_50  - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK50_HZ  / 1_000_000);
    fns_egcf_o_100 = (fcyc_egcf_o_100 - 16'd2 + XE10_CPU_CYC) * 1000 / (CLK100_HZ / 1_000_000);
    fclass("EGC 0x6A/0xA6 read",  fns_egc_r_50,  fns_egc_r_100,  CAP_EGC_R,   mcyc_egc_r_50,  mcyc_egc_r_100);
    fclass("EGC 0x6A/0xA6 write", fns_egc_w_50,  fns_egc_w_100,  CAP_EGC_W,   mcyc_egc_w_50,  mcyc_egc_w_100);
    fclass("text GDC 0x60/0x62",  fns_gdc1_50,   fns_gdc1_100,   CAP_GDC1,    mcyc_gdc1_50,   mcyc_gdc1_100);
    fclass("graphics GDC 0xA0/A2",fns_gdc2_50,   fns_gdc2_100,   CAP_GDC2,    mcyc_gdc2_50,   mcyc_gdc2_100);
    fclass("8253 write 0x0077",   fns_pit_w_50,  fns_pit_w_100,  CAP_PIT_W,   mcyc_pit_w_50,  mcyc_pit_w_100);
    fclass("0x005F read",        fns_5f_r_50,   fns_5f_r_100,   CAP_5F_R,    mcyc_5f_r_50,   mcyc_5f_r_100);
    fclass("EGC file 0x4A0 even", fns_egcf_e_50, fns_egcf_e_100, CAP_EGCF_E,  mcyc_egcf_e_50, mcyc_egcf_e_100);
    fclass("EGC file 0x4A1 odd",  fns_egcf_o_50, fns_egcf_o_100, CAP_EGCF_O,  mcyc_egcf_o_50, mcyc_egcf_o_100);

    // ---- the MPU-PC98II's MIDI line rate ----
    // The card's transmitter is the core's whole MIDI-out path, and its bit time is MIDI's own
    // line rate: 1/31250 s = 32 us at BOTH clocks. A divider counting clk_sys would read 16 us
    // at 100 MHz, which is exactly the failure class this bench exists for.
    if (mpu_bit_ns_50 == 32'd0 || mpu_bit_ns_100 == 32'd0)
      fail("the MPU-PC98II rate probes did not complete");
    else begin
      if (mpu_bit_ns_50 !== 32'd32_000)
        fail($sformatf("the MPU-PC98II MIDI bit time at 50 MHz is %0d ns, not 32000", mpu_bit_ns_50));
      if (mpu_bit_ns_100 !== 32'd32_000)
        fail($sformatf("the MPU-PC98II MIDI bit time at 100 MHz is %0d ns, not 32000", mpu_bit_ns_100));
      note($sformatf("MPU-PC98II MIDI out: start bit %0d ns at 50 MHz, %0d ns at 100 MHz (31250 baud)",
           mpu_bit_ns_50, mpu_bit_ns_100));
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SYSCLK_INVARIANCE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SYSCLK_INVARIANCE: FAIL (%0d errors)", errors);
  end

  initial begin
    #(RESET_NS + WINDOW_NS + 20_000_000);
    $fatal(1, "TB_PC9821_SYSCLK_INVARIANCE: timeout");
  end

endmodule

// ------------------------------------------------------------------
// pc9821_pit: program the selected CHANNEL the way its user does (channel 0's BIOS
// program is control 0x36 = channel 0, LSB then MSB, mode 3, divisor 0x6000; channel 1's
// is the ITF beep's 0x76/0x04CD; channel 2's is the RS-232C clock) and count that
// channel's OUT rising edges. All three channels share the 8253's 2.4576 MHz input
// clock, so every period the probe measures is divisor / 2.4576 MHz of wall clock.
// ------------------------------------------------------------------
module pit_probe #(parameter integer HZ = 50_000_000,
                   parameter integer CH = 0,
                   parameter [7:0] CTRL = 8'h36,
                   parameter [15:0] DIVISOR = 16'h6000) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [15:0] edges
);
  reg       cs = 1'b0, wr = 1'b0, rd = 1'b0;
  reg [1:0] addr = 2'd0;
  reg [7:0] din = 8'h00;
  wire [7:0] dout;
  wire out0, out1, out2;
  wire [2:0] outs = {out2, out1, out0};
  wire out_sel = outs[CH];
  reg out_sel_d = 1'b0;
  reg armed  = 1'b0;

  pc9821_pit #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .rst_n(!reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .out0(out0), .out1(out1), .out2(out2));

  initial begin
    edges = 16'd0;
    wait (!reset);
    @(negedge clk);
    cs = 1'b1;
    addr = 2'd3; din = CTRL; wr = 1'b1;    // 0x77: the channel, LSB+MSB, mode 3
    @(negedge clk);
    addr = 2'(CH); din = DIVISOR[7:0];     // 0x71/0x73/0x75: the divisor, LSB first
    @(negedge clk);
    din = DIVISOR[15:8];                   // ...then MSB
    @(negedge clk);
    wr = 1'b0; cs = 1'b0;
    armed = 1'b1;
  end

  always @(posedge clk) begin
    out_sel_d <= out_sel;
    if (armed && out_sel && !out_sel_d) edges <= edges + 16'd1;
    if (sample) armed <= 1'b0;
  end
endmodule

// ------------------------------------------------------------------
// pc9821_calendar: one guest-writable tick RATE (0 = 1/64 s, 1 = 1/32 s, 2 = off,
// 3 = 1/16 s; pc9821_calendar.sv:150 (tick_rate == 2'd3)) written through the 0x128 register the guest
// uses, plus the 1 Hz divider. The tick IRQ is counted and cleared with the 0x128 read
// the guest's own handler uses, so the count is of INTERRUPTS, not of a level that would
// stay high forever, and the divider the module ARMED is read back as a clk count - it is
// the clk count that must scale with SYS_CLOCK_HZ for the TIME not to.
// ------------------------------------------------------------------
module cal_probe #(parameter integer HZ = 50_000_000,
                   parameter [1:0] TICK_RATE = 2'd1) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [15:0] ticks,
    output reg [31:0] hz_max,
    output reg [31:0] tick_period
);
  reg  [55:0] rtc_bcd  = 56'h05_26_09_12_12_34_56;
  reg         rtc_load = 1'b0;
  reg         cmd_we = 1'b0, mode_we = 1'b0, tick_we = 1'b0, tick_rd = 1'b0;
  reg  [7:0]  cmd_din = 8'h00, mode_din = 8'h00, tick_din = 8'h00;
  wire [7:0]  mode_dout, tick_dout;
  wire        cdat, irq;
  reg         irq_d = 1'b0;
  reg  [2:0]  clear_pend = 3'd0;

  pc9821_calendar #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .rst_n(!reset),
      .rtc_bcd(rtc_bcd), .rtc_load(rtc_load),
      .cmd_we(cmd_we), .cmd_din(cmd_din),
      .mode_we(mode_we), .mode_din(mode_din), .mode_dout(mode_dout),
      .tick_we(tick_we), .tick_din(tick_din), .tick_dout(tick_dout),
      .tick_rd(tick_rd), .cdat(cdat), .irq(irq));

  initial begin
    ticks = 16'd0; hz_max = 32'd0; tick_period = 32'd0;
    wait (!reset);
    @(negedge clk);
    hz_max      = 32'(dut.HZ_DIV_MAX);
    // The guest's own act on 0x128: select the tick rate, the interrupt enabled (bit 7: the
    // Xe10 delivers nothing with it clear, docs/probes/XE10T-XE10-AUDIT.TXT CAL cfg=00/01).
    tick_din = {1'b1, 5'b00000, TICK_RATE};
    tick_we  = 1'b1;
    @(negedge clk);
    tick_we  = 1'b0;
    repeat (4) @(negedge clk);
    tick_period = 32'(dut.tick_period);   // the divider the module ARMED, in clk
  end

  always @(posedge clk) begin
    irq_d <= irq;
    if (irq && !irq_d && !sample && (TICK_RATE != 2'd2)) begin
      ticks <= ticks + 16'd1;
      clear_pend <= 3'd2;      // the guest's own handler reads 0x128 to clear the tick
    end else if (clear_pend != 3'd0) begin
      clear_pend <= clear_pend - 3'd1;
    end
    tick_rd <= (clear_pend != 3'd0);
  end
endmodule

// ------------------------------------------------------------------
// pc9821_calendar's CDAT serial read, driven the way the firmware drives it: the serial
// command channel (field 7, four opcode bits on DATA, one CLK each, then STB), then the
// 48 CLK edges a TIMEREAD needs. Every command is spaced by the SAME WALL-CLOCK delay
// (#-delays, not clks), so the two clock instances see the same guest schedule and the
// payload they recover must be identical: the bit clock is the GUEST's, and a core-side
// divider in this path would desynchronise one of them.
// ------------------------------------------------------------------
module cal_serial_probe #(parameter integer HZ = 50_000_000,
                          parameter integer STEP_NS = 2000) (
    input wire clk,
    input wire reset,
    output reg [47:0] word,
    output reg [15:0] clocks
);
  reg  [55:0] rtc_bcd  = 56'h05_26_09_12_12_34_56;
  reg         rtc_load = 1'b0;
  reg         cmd_we = 1'b0, mode_we = 1'b0, tick_we = 1'b0, tick_rd = 1'b0;
  reg  [7:0]  cmd_din = 8'h00, mode_din = 8'h00, tick_din = 8'h00;
  wire [7:0]  mode_dout, tick_dout;
  wire        cdat, irq;
  integer k;
  reg [1:0]   opbits;

  pc9821_calendar #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .rst_n(!reset),
      .rtc_bcd(rtc_bcd), .rtc_load(rtc_load),
      .cmd_we(cmd_we), .cmd_din(cmd_din),
      .mode_we(mode_we), .mode_din(mode_din), .mode_dout(mode_dout),
      .tick_we(tick_we), .tick_din(tick_din), .tick_dout(tick_dout),
      .tick_rd(tick_rd), .cdat(cdat), .irq(irq));

  // One 0x20 write, spaced from the last by a WALL-CLOCK delay (200 ns wide, so both
  // clocks sample it at a posedge with room to spare: 4 clks at 50 MHz, 2 at 100 MHz).
  task automatic cmd(input [7:0] din);
    begin
      #STEP_NS;
      cmd_din = din;
      cmd_we  = 1'b1;
      #200;
      cmd_we  = 1'b0;
      cmd_din = 8'h00;
    end
  endtask

  // One serial command: four (DATA bit, CLK) pairs LSB first, then the STB edge with the
  // field still at 7 so `command` resolves to the opcode just clocked in.
  task automatic serial_cmd(input [3:0] opcode);
    begin
      for (k = 0; k < 4; k = k + 1) begin
        cmd(opcode[k] ? 8'h27 : 8'h07);    // DATA write: field 7, the opcode bit at bit 5
        cmd(8'h10);                        // CLK rising: shift it into the command register
      end
      cmd(8'h0F);                          // STB rising with the field at 7: latch the opcode
      cmd(8'h00);                          // STB released (the next command needs the edge)
    end
  endtask

  initial begin
    word = 48'd0; clocks = 16'd0;
    wait (!reset);
    @(negedge clk);
    rtc_load = 1'b1;             // load the framework RTC, as the core does once the CPU runs
    @(negedge clk);
    rtc_load = 1'b0;
    #STEP_NS;
    serial_cmd(4'd3);            // TIMEREAD: latch the counters into the output register
    serial_cmd(4'd1);            // SHIFT: arm the walk-out
    for (k = 0; k < 48; k = k + 1) begin
      #STEP_NS;
      word[k] = cdat;            // the bit the shift register is presenting
      cmd(8'h10);                // one CLK: shift to the next bit
      cmd(8'h00);                // CLK back low, so the NEXT high is an edge
      clocks = clocks + 16'd1;
    end
  end
endmodule

// ------------------------------------------------------------------
// pc9821_mouse: the periodic IRQ13. Port C bit 4 is INT# (active low) and resets to F0h,
// so the bench clears bit 4 with the 8255's BSR form (0x7FDF, din = 0x08) to arm it.
// TIMING is the guest's own field at 0xBFDB (mouseif.c:309-312), which scales the period
// by 2^timing: the bench writes it and reads back the clk count the module ARMED, so the
// TIME (not the clk count) can be compared at the two clocks.
// ------------------------------------------------------------------
module mouse_probe #(parameter integer HZ = 50_000_000,
                     parameter [1:0] TIMING = 2'd0) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [15:0] irqs,
    output reg [31:0] period
);
  reg        cs = 1'b0, wr = 1'b0, rd = 1'b0;
  reg [2:0]  addr = 3'd0;
  reg [7:0]  din = 8'h00;
  wire [7:0] dout;
  wire       irq;
  reg        irq_d = 1'b0;

  pc9821_mouse #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .ps2_mouse(25'd0), .irq(irq));

  initial begin
    irqs = 16'd0; period = 32'd0;
    wait (!reset);
    @(negedge clk);
    cs = 1'b1; addr = 3'd3; din = 8'h08; wr = 1'b1;   // BSR: clear port C bit 4 (INT# on)
    @(negedge clk);
    addr = 3'd4; din = {6'd0, TIMING};  // 0xBFDB: the guest's interrupt-timing field
    @(negedge clk);
    wr = 1'b0; cs = 1'b0;
    repeat (2) @(negedge clk);
    period = 32'(dut.period);           // the wired period the module ARMED, in clk
  end

  always @(posedge clk) begin
    irq_d <= irq;
    if (irq && !irq_d && !sample) irqs <= irqs + 16'd1;
  end
endmodule

// ------------------------------------------------------------------
// pc9821_gameport: count the module's own 1.1 us axis tick, and measure the AXIS
// ONE-SHOT it feeds. A write to the port triggers the four one-shots from the latched
// discharge values, and the axis bit in the read byte stays 1 while its counter runs down
// - one decrement per tick (timed 0). The probe drives the right end stop (dig_1[0] = 1 ->
// pos 255 -> the IBM formula's R = 1000 -> 22 + 1000 ticks of 1.1 us) and measures the
// pulse in WALL CLOCK, which is what a game times.
// ------------------------------------------------------------------
module gameport_probe #(parameter integer HZ = 50_000_000) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [31:0] ticks,
    output reg [31:0] axis_ns
);
  reg         io_wr = 1'b0, io_rd = 1'b0;
  wire [7:0]  dout;
  wire [5:0]  sw;
  reg [31:0]  t0 = 32'd0, t1 = 32'd0;

  pc9821_gameport #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset),
      .io_wr(io_wr), .io_rd(io_rd), .io_dout(dout),
      .dis(2'b00), .mode(2'b00), .timed(2'b00),
      .dig_1(14'b0001), .dig_2(14'd0), .ana_1(16'd0), .ana_2(16'd0),
      .switch_lines(sw));

  always @(posedge clk) begin
    if (!sample && dut.tick) ticks <= ticks + 32'd1;
  end

  initial begin
    axis_ns = 32'd0;
    wait (!reset);
    repeat (8) @(negedge clk);      // let the free-running discharge phase latch the positions
    io_wr = 1'b1;
    @(negedge clk);
    io_wr = 1'b0;                   // one write: all four one-shots reload
    while (!dout[0]) @(negedge clk);
    t0 = 32'($time);
    while (dout[0]) @(negedge clk);
    t1 = 32'($time);
    axis_ns = t1 - t0;
  end
endmodule

// ------------------------------------------------------------------
// pc9821_kbd: the typematic pair. The delay and interval are read out of the module's own
// parameters - they are the windows a held key arms (NP2kai's 500 ms / 50 ms), and the
// bench converts them to wall clock itself so the RATE is what is asserted.
// ------------------------------------------------------------------
module kbd_probe #(parameter integer HZ = 50_000_000) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [31:0] rep_delay,
    output reg [31:0] rep_interval
);
  wire [7:0]  dout;
  wire [2:0]  led;
  wire [7:0]  d_ev, d_del, d_rd, d_wr, d_last, d_c0, d_c1;
  wire        d_rts, d_rx;
  wire        irq;

  pc9821_kbd #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .rst_n(!reset), .cs(1'b0), .a0(1'b0), .wr(1'b0), .rd(1'b0),
      .din(8'h00), .dout(dout), .irq(irq), .ps2_key(11'd0),
      .led_status(led), .dbg_events(d_ev), .dbg_delivered(d_del), .dbg_rd_data(d_rd),
      .dbg_wr_ctrl(d_wr), .dbg_rts(d_rts), .dbg_rx_en(d_rx), .dbg_last_del(d_last),
      .dbg_ctrl0(d_c0), .dbg_ctrl1(d_c1));

  initial begin
    rep_delay = 32'd0; rep_interval = 32'd0;
    wait (!reset);
    repeat (4) @(negedge clk);
    rep_delay    = 32'(dut.REPEAT_DELAY);
    rep_interval = 32'(dut.REPEAT_INTERVAL);
  end
endmodule

// ------------------------------------------------------------------
// pc9821_iobus: the ARTIC timestamp counter (the firmware's delay() timebase) and the
// three I/O-access classes the bench cares about. Self-driving: it reads the ARTIC at
// reset release, times three accesses, then re-reads the ARTIC at the shared `sample`.
// ------------------------------------------------------------------
module iobus_probe #(parameter [31:0] HZ = 32'd50_000_000,
                     parameter        XE10 = 1'b0) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [23:0] artic_first,
    output reg [23:0] artic_last,
    output reg [15:0] cyc_5f,
    output reg [15:0] cyc_71,
    output reg [15:0] cyc_default,
    output reg [15:0] cyc_def_r,    // the SAME default class, READ side
    output reg [15:0] cyc_grcg_w,   // the GRCG tile register 0x007E, the Rusty wipe's port
    // The remaining captured class rows (docs/probes/XE10T-XE10.TXT /IO). Both tables' probes
    // take them: the Xe10 table's values are asserted, Fast's are only printed.
    output reg [15:0] egc_r,        // 0x006A read   (350 ns Xe10)
    output reg [15:0] egc_w,        // 0x00A6 write  (318 ns Xe10)
    output reg [15:0] gdc1,         // 0x0060 read   (414 ns Xe10, both directions)
    output reg [15:0] gdc2,         // 0x00A0 read   (639 ns Xe10, both directions)
    output reg [15:0] pit_w,        // 0x0077 write  (823 ns Xe10)
    output reg [15:0] f_5f_r,       // 0x005F read   (792 ns Xe10)
    output reg [15:0] egcf_e,       // 0x04A0 read   (5990 ns Xe10, even address)
    output reg [15:0] egcf_o,       // 0x04A1 read   (792 ns Xe10, odd address)
    output reg [15:0] fdc_recal,    // pc9821_fdc's RECAL_CYCLES, read out of the production instance
    output reg        done        // the final ARTIC read has landed
);
  // The iobus's whole port list, named so `.*` binds it (the same shape
  // tb_pc9821_mouse.sv uses).
  reg  [3:0]  bios_set = 4'd0;
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  wire        beep_mute;
  wire [1:0]  beep_vol;
  reg         triple_fault_reset = 1'b0;
  reg  [31:0] cpu_addr = 32'd0, cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'd0;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  reg  [7:0]  debug_status = 8'hA5;
  reg         cal_cdat = 1'b0;
  wire [6:0]  cfg_ram_mib = 7'd0;
  wire        cfg_seed_en = 1'b0;
  reg  [7:0]  device_io_dout = 8'h00;
  reg         device_rd_wait = 1'b0;
  reg         device_rd_hold = 1'b0;
  reg         device_wr_wait = 1'b0;
  reg         egc_gate = 1'b0;
  reg  [10:0] gdc_ff2_state = 11'd0;
  reg  [24:0] ps2_mouse = 25'd0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  wire  [3:0] top_bank;
  wire        sound_extend;
  wire  [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire        sys16m_en;
  wire        ide_rom_enable, bios_ram_gate, a20_enable, cpu_reset_req;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire  [7:0] post_code;
  wire        post_write;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg, egc_sft, egc_leng;
  wire        egc_shift_we;
  wire  [3:0] dbg_gate;
  wire  [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  wire        dbg_last_io_stb;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire  [1:0] ems_state;
  wire        top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  wire        mouse_irq;
  // ---- pc9821_iobus's Phase-1 port groups, tied off: this bench drives NO floppy ----
  // The wildcard instantiation connects every port by name, so the floppy media seam and
  // the uPD71071's bus-master port need a signal here even though nothing in this bench
  // uses them (tools/check_wiring.py requires exactly that). With `fdd_present` clear the
  // FDC never takes its media path, so the data path this seam feeds is unreachable.
/* verilator lint_off UNUSEDSIGNAL */
  wire [3:0]  fdd_present = 4'd0;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx, fdd_dout, fdd_hr, fdd_hn, fdd_hs;
  wire [7:0]  fdd_tc;   // pc9821_iobus's physical-track pair (pc9821_fdc media_tc/media_hd)
  wire        fdd_hd;
  wire        fdd_mf;
  wire        fdd_2hd;   // pc9821_iobus's media-mode pair (pc9821_fdc media_2hd/media_rpm)
  wire        fdd_rpm;
  wire        fdd_ready = 1'b1, fdd_rdy = 1'b0, fdd_hdrv = 1'b0, fdd_err = 1'b0;
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and its load cycle (unused here)
  wire        dma_mem_load;
  wire [3:0]  dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  wire        dma_mem_ready = 1'b0;
  wire [31:0] dma_mem_dout = 32'd0;
  wire        dma_mem_resp_valid = 1'b0;
/* verilator lint_on UNUSEDSIGNAL */
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;


  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here


  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): this probe's XE10 parameter.
  wire io_timing_xe10 = XE10;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1), .SYS_CLOCK_HZ(HZ)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  task automatic rd_byte(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, portnum[15:2], 2'b00};
      cpu_be    = 4'b0001 << portnum[1:0];
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      #1 data = cpu_dout[{portnum[1:0], 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'd0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic read_artic(output [23:0] value);
    reg [7:0] lo, mid, hi;
    begin
      rd_byte(16'h005C, lo);    // cnt[7:0]
      rd_byte(16'h005D, mid);   // cnt[15:8]
      rd_byte(16'h005F, hi);    // cnt[23:16]
      value = {hi, mid, lo};
    end
  endtask

  // The access cost a guest sees: clk cycles from presenting the access to cpu_ready.
  task automatic timed_write(input [15:0] portnum, output [15:0] cycles);
    integer n;
    begin
      n = 0;
      @(negedge clk);
      cpu_addr  = {16'd0, portnum[15:2], 2'b00};
      cpu_be    = 4'b0001 << portnum[1:0];
      cpu_din   = 32'h0000_0000;
      cpu_write = 1'b1;
      cpu_valid = 1'b1;
      while (!cpu_ready) begin @(negedge clk); n = n + 1; end
      cycles = n[15:0] + 16'd1;
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'd0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // A posted 0x005F write and the access right behind it (an unmapped default-class write),
  // timed together from the 0x5F write's presentation to the second ready: the write's bus
  // time is only visible on the access that has to wait for it.
  task automatic timed_post(output [15:0] cycles);
    integer n;
    begin
      n = 0;
      @(negedge clk);
      cpu_addr  = {16'd0, 14'h0017, 2'b00};   // 0x5C dword, lane 3 = 0x5F
      cpu_be    = 4'b1000;
      cpu_din   = 32'h0000_0000;
      cpu_write = 1'b1;
      cpu_valid = 1'b1;
      while (!cpu_ready) begin @(negedge clk); n = n + 1; end
      @(negedge clk); n = n + 1;
      cpu_valid = 1'b0;
      cpu_be    = 4'd0;
      @(negedge clk); n = n + 1;
      cpu_addr  = {16'd0, 14'h03B8, 2'b00};   // 0x0EE0, lane 0: unmapped, the default class
      cpu_be    = 4'b0001;
      cpu_valid = 1'b1;
      while (!cpu_ready) begin @(negedge clk); n = n + 1; end
      cycles = n[15:0] + 16'd1;
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'd0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // The same window as timed_write, for the read direction: the class table prices the two
  // directions differently in the Xe10 table, so a read must be timed too.
  task automatic timed_read(input [15:0] portnum, output [15:0] cycles);
    integer n;
    begin
      n = 0;
      @(negedge clk);
      cpu_addr  = {16'd0, portnum[15:2], 2'b00};
      cpu_be    = 4'b0001 << portnum[1:0];
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      while (!cpu_ready) begin @(negedge clk); n = n + 1; end
      cycles = n[15:0] + 16'd1;
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'd0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  initial begin
    artic_first = 24'd0; artic_last = 24'd0;
    cyc_5f = 16'd0; cyc_71 = 16'd0; cyc_default = 16'd0;
    cyc_def_r = 16'd0; cyc_grcg_w = 16'd0; done = 1'b0;
    egc_r = 16'd0; egc_w = 16'd0; gdc1 = 16'd0; gdc2 = 16'd0;
    pit_w = 16'd0; f_5f_r = 16'd0; egcf_e = 16'd0; egcf_o = 16'd0;
    fdc_recal = 16'd0;
    wait (!reset);
    read_artic(artic_first);
    timed_post(cyc_5f);                 // the firmware's own I/O-wait port: posted, 1744 ns
    timed_write(16'h0071, cyc_71);      // an 8253 port: >= one 2.4576 MHz PIT tick
    timed_write(16'h0EE0, cyc_default); // unmapped: the class floor
    timed_read(16'h0EE0, cyc_def_r);    // the same class, read side (the Xe10 split)
    timed_write(16'h007E, cyc_grcg_w);  // the GRCG tile register (the Rusty wipe's port)
    // The remaining captured rows (docs/probes/XE10T-XE10.TXT /IO). All seven are real guest accesses:
    // the EGC's named mode/page pair, the two GDCs' status ports, the 8253's control port,
    // the ARTIC window's high byte, and the EGC register file's odd and even addresses (the
    // even one is the 6 us class that only the Xe10 table prices).
    timed_read(16'h006A, egc_r);
    timed_write(16'h00A6, egc_w);
    timed_read(16'h0060, gdc1);
    timed_read(16'h00A0, gdc2);
    timed_write(16'h0077, pit_w);
    timed_read(16'h005F, f_5f_r);
    timed_read(16'h04A0, egcf_e);
    timed_read(16'h04A1, egcf_o);
    // The FDC's recalibrate constant, out of this iobus's own pc9821_fdc instance: a TIME
    // (20 us) the module converts from SYS_CLOCK_HZ, so both clocks must encode the same
    // wall-clock delay. The FDC is inside the production pc9821_iobus.
    fdc_recal = 16'(dut.fdc.RECAL_CYCLES);
    wait (sample);
    read_artic(artic_last);
    done = 1'b1;
  end
endmodule

// ------------------------------------------------------------------
// pc9821_system: the PRODUCTION video path at both clocks. The CPU is z486_stub (the
// real z486 tree is not where this bench's rates come from, and the stub is what
// tb_pc9821_system_reset_seed elaborates), everything else is the shipped design. The
// bench takes the module's own video_ce as the dot enable for the standalone CRTC probes,
// counts its edges, counts its raster's own hsync/vsync pulses, and reads the GVRAM
// arbiter's captured hold constants out of `memory.u_gvram_arb` - all of them the
// production instances, at the two clocks the two `SYS_FREQ` values give.
// ------------------------------------------------------------------
module sys_probe #(parameter integer HZ = 50_000_000) (
    input wire clk,
    input wire reset,
    output wire video_ce,
    output reg [31:0] ce_edges,
    output reg [31:0] hs_pulses,
    output reg [31:0] vs_pulses,
    output wire video_hsync,
    output wire video_vsync,
    output reg [15:0] gv_rd_hold,
    output reg [15:0] gv_wr_hold,
    output reg [15:0] gv_gr_hold
);
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  reg  ce_d = 1'b0, hs_d = 1'b1, vs_d = 1'b1;

  pc9821_system #(.SYS_FREQ(HZ), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0)) dut (
      .clk_sys(clk), .reset(reset), .hps_apply_reset(1'b0), .rtc(rtc),
      .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(1'b0),
      .ext_mem0_dout(32'd0), .ext_mem0_resp_valid(1'b0), .ext_mem0_ready(1'b1),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(16'd0),
      .img_mounted(1'b0), .img_readonly(1'b0), .img_size(64'd0), .img_ack(1'b0),
      .img_buff_addr(13'd0), .img_buff_din(16'd0), .img_buff_wr(1'b0),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0),
      .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_set(4'd0),
      .video_ce(video_ce), .video_blank_n(), .video_hsync(video_hsync), .video_vsync(video_vsync),
      .video_r(), .video_g(), .video_b(),
      .sample_86_l(), .sample_86_r(), .speaker_out(),
      .vol_master_l(), .vol_master_r(), .vol_voice_l(), .vol_voice_r(),
      .vol_cd_l(), .vol_cd_r(), .vol_midi_l(), .vol_midi_r(),
      .vol_line_l(), .vol_line_r(), .vol_spk(), .beep_vol(), .vol_en(),
      .debug_boot_stage(), .debug_sd_error(), .debug_bios_loaded(),
      .debug_first_instruction(), .debug_post_code(), .debug_post_write(),
      .cpu_pe(), .cpu_vm(), .cpu_cs(), .cpu_eip(), .cpu_cs_base(),
      .mpu_uart_tx(), .dbg_uart_byte(), .dbg_uart_we());

  initial begin
    ce_edges = 32'd0; hs_pulses = 32'd0; vs_pulses = 32'd0;
    gv_rd_hold = 16'd0; gv_wr_hold = 16'd0; gv_gr_hold = 16'd0;
    wait (!reset);
    repeat (4) @(negedge clk);
    // The arbiter's captured per-access TIMES, converted per profile (pc9821_gvram_arb.sv:406 (GVRAM_RD_HOLD)):
    // 478 ns read, 142 ns write, 104 ns GRCG store. They are a clk count in the module and a
    // TIME here, which is exactly the property this bench checks.
    gv_rd_hold = 16'(dut.memory.u_gvram_arb.GVRAM_RD_HOLD);
    gv_wr_hold = 16'(dut.memory.u_gvram_arb.GVRAM_WR_HOLD);
    gv_gr_hold = 16'(dut.memory.u_gvram_arb.GVRAM_GR_HOLD);
  end

  always @(posedge clk) begin
    ce_d <= video_ce;
    hs_d <= video_hsync;
    vs_d <= video_vsync;
    if (!reset) begin
      if (video_ce && !ce_d) ce_edges <= ce_edges + 32'd1;
      if (hs_d && !video_hsync) hs_pulses <= hs_pulses + 32'd1;   // negative polarity: falling starts the pulse
      if (vs_d && !video_vsync) vs_pulses <= vs_pulses + 32'd1;
    end
  end
endmodule

// ------------------------------------------------------------------
// pc9821_opna: the chip's own 7.9872 MHz enable, the SSG's cen/16 sample enable, and the
// two guest-programmed timers, driven through the same host port pc9821_iobus drives
// (0x188 = the register-select latch, 0x18A = the data). Each timer is measured the way
// tb_pc9821_opna_timers measures one: stop both and clear both flags (0x27 = 0x30), load
// the value, start with the IRQ enable (0x27 = 0x05 for A, 0x0A for B), and count clk
// cycles to the first interrupt - which is ONE full period of the chip clock times the
// guest's value: 144*(1024-NA) and 2304*(256-NB) master clocks (jt12_timers.v's header
// formula; NP2kai sound/opntimer.c:30,53 is the same period in its own quantisation).
// The count is a clk count and the PERIOD is the ns it converts to, which is what must
// not move with clk_sys.
// ------------------------------------------------------------------
module opna_probe #(parameter integer HZ = 50_000_000,
                    parameter [9:0] TA_VALUE = 10'd1000,
                    parameter [7:0] TB_VALUE = 8'd254) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [31:0] cen_edges,
    output reg [31:0] ssg_edges,
    output reg [31:0] ta_clk,
    output reg [31:0] tb_clk
);
  reg  [15:0] io_addr = 16'h0188;
  reg         io_wr = 1'b0, io_rd = 1'b0;
  reg  [7:0]  io_din = 8'h00;
  wire [7:0]  io_dout;
  wire        io_rd_wait, io_wr_wait;
  wire signed [19:0] snd_l, snd_r;
  wire        irq;
  reg  ce_d = 1'b0, ssg_ce_d = 1'b0;
  integer n;

  pc9821_opna #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset),
      .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
      .io_dout(io_dout), .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
      .extend(1'b1), .joystick(6'b111111),
      .snd_l(snd_l), .snd_r(snd_r), .irq(irq),
      .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0));

  // One driver register write: the index to 0x188, then the data to 0x18A, each waiting
  // out the module's own back-pressure (the same handshake pc9821_iobus performs).
  task automatic wreg(input [7:0] sel, input [7:0] data);
    begin
      @(negedge clk);
      while (io_wr_wait) @(negedge clk);
      io_addr = 16'h0188; io_din = sel;  io_wr = 1'b1;
      @(negedge clk);
      io_wr = 1'b0;
      repeat (2) @(negedge clk);
      while (io_wr_wait) @(negedge clk);
      io_addr = 16'h018A; io_din = data; io_wr = 1'b1;
      @(negedge clk);
      io_wr = 1'b0;
      repeat (2) @(negedge clk);
    end
  endtask

  // Stop both timers and clear both flags, so each measurement times a full count from a
  // clean flag state (0x27 = 0x30 is the two flag resets with both start bits clear).
  task automatic stop_and_clear;
    begin
      wreg(8'h27, 8'h30);
      repeat (60) @(posedge clk);
    end
  endtask

  // clk cycles from the start write to the first interrupt; 0 means it never rose.
  task automatic start_to_irq(input [7:0] ctrl);
    begin
      wreg(8'h27, ctrl);
      n = 0;
      while (!irq && n < 4_000_000) begin @(posedge clk); n = n + 1; end
    end
  endtask

  always @(posedge clk) begin
    ce_d <= dut.cen;
    ssg_ce_d <= dut.ssg_cen;
    if (!sample) begin
      if (dut.cen && !ce_d) cen_edges <= cen_edges + 32'd1;
      if (dut.ssg_cen && !ssg_ce_d) ssg_edges <= ssg_edges + 32'd1;
    end
  end

  initial begin
    cen_edges = 32'd0; ssg_edges = 32'd0; ta_clk = 32'd0; tb_clk = 32'd0;
    wait (!reset);
    repeat (2000) @(posedge clk);      // the reset stretch is 16 cen; settle past it
    // Timer A: value 960 (0x24 takes value[9:2], 0x25 value[1:0]) -> 64 steps.
    stop_and_clear;
    wreg(8'h24, 8'hF0);
    wreg(8'h25, 8'h00);
    start_to_irq(8'h05);               // bit0 start A, bit2 enable A
    ta_clk = 32'(n);
    // Timer B: value 240 -> 16 steps.
    stop_and_clear;
    wreg(8'h26, 8'hF0);
    start_to_irq(8'h0A);               // bit1 start B, bit3 enable B
    tb_clk = 32'(n);
  end
endmodule

// ------------------------------------------------------------------
// pc9821_pcm86: the sample strobe at a guest-selected rate. The rate is the module's own
// phase accumulator carry, and the rate register is 0xA468 bits 2:0 - the field the guest
// writes (NP2kai sound/pcm86c.c:35 pcm86rate8[] is the table behind it, and pc9821_pcm86.sv
// derives each step as 2^29 * (8 x rate) / SYS_CLOCK_HZ). The accumulator free-runs, so the
// count over the window is the delivered sample rate with no guest data needed.
// ------------------------------------------------------------------
module pcm86_probe #(parameter integer HZ = 50_000_000,
                     parameter [2:0] RATE = 3'd0) (
    input wire clk,
    input wire reset,
    input wire sample,
    output reg [31:0] ticks
);
  reg  [15:0] io_addr = 16'h0A468;
  reg         io_wr = 1'b0, io_rd = 1'b0;
  reg  [7:0]  io_din = 8'h00;
  wire [7:0]  io_dout;
  wire        io_rd_wait, io_wr_wait;
  wire signed [15:0] snd_l, snd_r;
  wire        irq;
  wire [15:0] dbg_count;
  reg  tick_d = 1'b0;

  pc9821_pcm86 #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset),
      .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
      .io_dout(io_dout), .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
      .snd_l(snd_l), .snd_r(snd_r), .irq(irq), .dbg_count(dbg_count),
      .buf_base(32'd0), .sdram_valid(), .sdram_ready(1'b0), .sdram_write(),
      .sdram_addr(), .sdram_din(), .sdram_dout(32'd0), .sdram_resp_valid(1'b0),
      .sdram_be(), .sdram_burstcount());

  initial begin
    ticks = 32'd0;
    wait (!reset);
    @(negedge clk);
    io_addr = 16'h0A468; io_din = {5'b00000, RATE}; io_wr = 1'b1;   // the guest's rate field
    @(negedge clk);
    io_wr = 1'b0;
  end

  always @(posedge clk) begin
    tick_d <= dut.sample_tick;
    if (dut.sample_tick && !tick_d && !sample) ticks <= ticks + 32'd1;
  end
endmodule

// ------------------------------------------------------------------
// pc9821_crtc: the video side's timebases at both clocks. The raster is the guest's SYNC block
// counted in DOTS, and the 0x60 status byte's data-ready bit 0 is the one GUEST-VISIBLE bit the
// F6 fix moved off clk_sys, so both are read in wall-clock terms: counts over the shared window,
// plus the first line's and frame's period and the first hsync pulse's width in ns.
//
// pixel_ce IS AN INPUT, and the bench wires it to pc9821_system's own video_ce: the
// production PIXEL_HZ-derived 24-bit fixed-point enable (pc9821_system.sv:1119 (the dot rate as a fraction),
// round(PIXEL_HZ * 2^24 / SYS_FREQ)), which averages 21.0526 MHz at every build profile.
// This probe used to compute its OWN copy of that divider from
// its own PIXEL_HZ parameter, so it tested the CRTC GIVEN a dot enable and a change to the
// RTL's formula was invisible; with the production enable wired in, a raw clk_sys count
// makes everything below read 2x at 100 MHz. A bit gated by this enable reads the same
// wall-clock rate at 50 and 100 MHz; a bit gated by clk_sys reads 2x over the same window.
// ------------------------------------------------------------------
module crtc_probe (
    input wire clk,
    input wire reset,
    input wire sample,
    input wire pixel_ce,            // the PRODUCTION dot enable, from pc9821_system's video_ce
    output reg [31:0] dr_edges,     // 0x60 status bit 0 (data-ready) rising edges
    output reg [15:0] lines,        // hsync pulses
    output reg [15:0] frames,       // vsync pulses
    output reg [15:0] de_line,      // active dots of the first FULL line
    output reg [31:0] line_ns,      // the first line period, ns
    output reg [31:0] frame_ns,     // the first frame period, ns
    output reg [15:0] hs_width_ns   // the first hsync pulse's width, ns
);
  reg  [7:0] io_addr = 8'h60;
  wire [7:0] io_dout;
  wire       hs_out, vs_out, de_out;

  pc9821_crtc dut (
      .clk_sys(clk), .rst_n_sys(!reset), .rst_n_vid(!reset), .pixel_ce(pixel_ce),
      .gfx_win_on(1'b0),
      .io_wr(1'b0), .io_rd(1'b0), .io_addr(io_addr), .io_din(8'h00), .io_dout(io_dout),
      .tram_cpu_addr(14'd0), .tram_cpu_din(8'h00), .tram_cpu_we(1'b0),
      .wk_tr_read(1'b0), .wk_tr_addr(14'd0),
      .ank_word(16'h0000), .jc_rd_q(32'd0), .cg_ram_vid_q(8'h00),
      .vsync_irq_arm(1'b0),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  reg        dr_d = 1'b0, hs_d = 1'b1, vs_d = 1'b1;   // both sync outputs idle HIGH
  reg        hs_seen = 1'b0, hs_width_done = 1'b0, vs_seen = 1'b0;
  reg [31:0] t_hs = 32'd0, t_vs = 32'd0;
  reg [15:0] de_acc = 16'd0;

  initial begin
    dr_edges = 32'd0; lines = 16'd0; frames = 16'd0; de_line = 16'd0;
    line_ns = 32'd0; frame_ns = 32'd0; hs_width_ns = 16'd0;
  end

  always @(posedge clk) begin
    dr_d <= io_dout[0];
    hs_d <= hs_out;
    vs_d <= vs_out;
  end

  // The first line's and frame's wall-clock periods and the first hsync pulse's width, in ns.
  // hs_out/vs_out are NEGATIVE polarity, so a pulse STARTS on a falling edge. `!reset` matters:
  // before the first clock edge the geometry registers hold their power-up zeros, which make
  // VSYNC_W the 1-line minimum and put in_vsync TRUE at vline 0, so vs_out starts LOW and the
  // first real pulse would otherwise be read as the SECOND edge (a 16.4 ms "frame").
  always @(posedge clk) begin
    if (!reset && hs_d && !hs_out) begin
      if (!hs_seen) begin
        t_hs    <= $time;
        hs_seen <= 1'b1;
      end else if (line_ns == 32'd0) begin
        line_ns <= $time - t_hs;
        t_hs    <= $time;
      end
    end
    if (!reset && !hs_d && hs_out && hs_seen && !hs_width_done) begin
      hs_width_ns   <= 16'($time - t_hs);
      hs_width_done <= 1'b1;
    end
    if (!reset && vs_d && !vs_out) begin
      if (!vs_seen) begin
        t_vs    <= $time;
        vs_seen <= 1'b1;
      end else if (frame_ns == 32'd0) frame_ns <= $time - t_vs;
    end
  end

  always @(posedge clk) begin
    if (!reset && !sample) begin
      // de_acc counts DOTS: de_out is high for HACTIVE dots, each of which is one clk with
      // pixel_ce (at 50 MHz that is 640 dots in 1520 clk_sys), so the count must be gated by the
      // same enable the raster is.
      if (io_dout[0] && !dr_d) dr_edges <= dr_edges + 32'd1;
      if (pixel_ce && de_out) de_acc <= de_acc + 16'd1;
      if (hs_d && !hs_out) begin
        lines <= lines + 16'd1;
        if (lines == 16'd1) de_line <= de_acc;   // the first FULL line's active dots
        de_acc <= 16'd0;
      end
      if (vs_d && !vs_out) frames <= frames + 16'd1;
    end
  end
endmodule

// The MPU-PC98II's line-rate probe: drives ONE channel message into its own
// pc9821_mpu through the card's two device ports and measures the start bit's width in
// NANOseconds. The start bit is chosen first on purpose - both message bytes have bit 0 SET, so
// the first low run after the falling edge is the start bit and not the start plus four zero data
// bits, which is what a byte like 0x90 would measure. The bit time IS 1/31250 s.
module mpu_rate_probe #(parameter integer HZ = 50_000_000) (
    input  wire        clk,
    input  wire        reset,
    output reg  [31:0] bit_ns
);
  reg         cs = 1'b0;
  reg  [15:0] addr = 16'hE0D0;
  reg         wr = 1'b0;
  reg         rd = 1'b0;
  reg  [7:0]  din = 8'h00;
  wire [7:0]  dout;
  wire        uart_tx;
  wire        irq;
  integer     c;
  localparam integer NS_PER_CYCLE = 1_000 / (HZ / 1_000_000);

  pc9821_mpu #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .uart_tx(uart_tx), .irq(irq));

  task automatic bus_wr(input [15:0] a, input [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; din = b; wr = 1'b1; rd = 1'b0;
      @(negedge clk);
      wr = 1'b0; cs = 1'b0;
    end
  endtask

  initial begin
    bit_ns = 32'd0;
    wait (!reset);
    repeat (10) @(posedge clk);
    bus_wr(16'hE0D2, 8'hD0);        // want to send data
    bus_wr(16'hE0D0, 8'h91);        // status, bit 0 set
    bus_wr(16'hE0D0, 8'h7F);        // data, bit 0 set
    bus_wr(16'hE0D0, 8'h7F);
    while (uart_tx !== 1'b1) @(posedge clk);
    while (uart_tx !== 1'b0) @(posedge clk);
    c = 0;
    while (uart_tx === 1'b0) begin
      @(posedge clk);
      c = c + 1;
    end
    bit_ns = c * NS_PER_CYCLE;
  end
endmodule

// ------------------------------------------------------------------
// pc9821_crtc in the 31 kHz mode: crt31k high, and the BIOS 31 kHz master SYNC block programmed
// through the master GDC's ports as the BIOS and HSB.EXE do (SYNC 0x0F to 0x62, its eight bytes
// 10 4E 47 0C 07 0D 90 89 to 0x60; NP2kai bios/bios18.c gdcmastersync[2]). The block lands at the
// first frame boundary; the probe skips two frames and then averages three, reporting the frame and
// line periods in wall-clock time (the line in 0.1 ns) and the lines counted in those four frames.
// pixel_ce is the production enable (pc9821_dot_ce with c31 high).
// ------------------------------------------------------------------
module crtc31_probe (
    input wire clk,
    input wire reset,
    input wire sample,
    input wire pixel_ce,
    output reg [31:0] frame_ns,
    output reg [31:0] line_ns,      // x 0.1 ns
    output reg [15:0] lines
);
  reg  [7:0] io_addr = 8'h60, io_din = 8'h00;
  reg        io_wr = 1'b0;
  wire [7:0] io_dout;
  wire       hs_out, vs_out, de_out;
  pc9821_crtc dut (
      .clk_sys(clk), .rst_n_sys(!reset), .rst_n_vid(!reset), .pixel_ce(pixel_ce),
      .crt31k(1'b1), .gfx_win_on(1'b0),
      .io_wr(io_wr), .io_rd(1'b0), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .tram_cpu_addr(14'd0), .tram_cpu_din(8'h00), .tram_cpu_we(1'b0),
      .wk_tr_read(1'b0), .wk_tr_addr(14'd0),
      .ank_word(16'h0000), .jc_rd_q(32'd0), .cg_ram_vid_q(8'h00),
      .vsync_irq_arm(1'b0),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );
  task automatic put(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_din = d; io_wr = 1'b1;
      @(negedge clk); io_wr = 1'b0;
      repeat (4) @(negedge clk);
    end
  endtask
  reg     vs_d = 1'b1, hs_d = 1'b1;
  integer n_vs = 0, n_hs = 0;
  real    t_v0 = 0.0, t_v1 = 0.0, t_h0 = 0.0, t_h1 = 0.0;
  always @(posedge clk) begin
    vs_d <= vs_out;
    hs_d <= hs_out;
    if (!reset && !sample && vs_d && !vs_out) begin
      n_vs = n_vs + 1;
      if (n_vs == 3) t_v0 = $realtime;
      if (n_vs == 6) t_v1 = $realtime;
    end
    if (!reset && !sample && hs_d && !hs_out && n_vs >= 3 && n_vs < 6) begin
      if (n_hs == 0) t_h0 = $realtime;
      t_h1 = $realtime;
      n_hs = n_hs + 1;
    end
  end
  initial begin
    frame_ns = 32'd0; line_ns = 32'd0; lines = 16'd0;
    wait (!reset);
    repeat (8) @(negedge clk);
    put(8'h62, 8'h0F);
    put(8'h60, 8'h10); put(8'h60, 8'h4E); put(8'h60, 8'h47); put(8'h60, 8'h0C);
    put(8'h60, 8'h07); put(8'h60, 8'h0D); put(8'h60, 8'h90); put(8'h60, 8'h89);
    io_addr = 8'h60;
    wait (sample);
    if (n_vs >= 6) begin
      frame_ns = 32'((t_v1 - t_v0) / 3.0);
      line_ns  = 32'((t_h1 - t_h0) * 10.0 / real'(n_hs - 1));
      lines    = 16'(n_hs);
    end
  end
endmodule

