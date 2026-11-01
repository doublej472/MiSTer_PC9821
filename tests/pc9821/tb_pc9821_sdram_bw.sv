`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_BW: the four-stream SDRAM demand fits inside the machine's own deadline through the REAL sdram_sync_bridge at the deployed settings (the controller on clk_sys, FREQ = clk_sys = 90 MHz by default, the shipping build, ADQM=1, FAST_GRADE=0, GATHER_K=4) against sdram_chip_model with its AUTO REFRESH gap held to tREFI under this load - the PEGC packed scanout's 160-dword line completes inside the SHORTER of the machine's two raster lines - the 31 kHz line (800 dots at the Xe10's 25.168 MHz 31 kHz dot clock, pc9821_vclk_pkg / docs/probes/CRT31K.TXT: 31.79 us = 2860 clk_sys at 90 MHz, the 640x480 256-colour mode's line), not only the 24 kHz 40.28 us one (3625) and the CPU is served under a saturating cache-line stream, its MB/s REPORTED against the old 40 MB/s requirement (tb_pc9821_sdram_tdm's, a 50/100 split-clock number the same-clock build does not meet, the accepted T36 trade), while the single-port engine ceiling (15-dword read and single-word write MB/s) and the all-four-saturating adversarial aggregate are REPORTED, not asserted, so the instrument decides whether the serial transaction engine limits the current demand.
// (The claim above is the manifest's, word for word, per the house convention.)
//
// TB_PC9821_SDRAM_BW is the SDRAM bandwidth/headroom INSTRUMENT the floor analysis
// asked for: it drives the
// REAL sdram_sync_bridge at the DEPLOYED settings (the controller on clk_sys at SYS_MHZ, 90 by
// default, ADQM=1, FAST_GRADE=0, GATHER_K=4 - z486_mister.sv's split_sdram_backend
// instance) against sdram_chip_model, and reports each of the four streams' headroom at the real
// demand. Its FAIL conditions: the PEGC packed scanout's line completes inside the SHORTER raster
// line - the 31 kHz one (800 dots / 25 168 007 Hz = 31.79 us, the 640x480 256-colour mode's;
// the 24 kHz line is 56.42 Hz * 440 VTOTAL = 40.28 us), the CPU is served at all, and the PCM gets its rate.
// THE CPU's 40 MB/s (tb_pc9821_sdram_tdm's requirement, set for the 50/100 split-clock build) IS
// REPORTED, NOT ASSERTED, since 2026-10-09: the same-clock build measures 25.9 MB/s under this
// mix at 80/80 (and the 80/100 split-clock build already measured 38.3), the loss
// accepted with trade T36 (docs/trade-candidates.md). The mix runs the packed scanout back to back, unpaced by
// the raster - an adversarial ceiling, not a game. Everything else - the adversarial
// all-ports-max aggregate, and the single-port engine ceiling in MB/s - is REPORTED, not asserted. It exists to decide whether the controller's
// serial one-transaction-at-a-time engine actually limits the current demand, before any
// scheduler rewrite on the design's worst-timing clock.
//
// WHAT IT DOES NOT PROVE: it is not a device-timing model (sdram_chip_model is a data model) and
// it is not the boot golden; it is a load/headroom measurement through the real bridge.
//
// THE SHAPES (the real streams, not fabricated ones):
//   port 0 CPU:    a saturating stream of 4-dword cache-line reads and single-dword writes
//                  (the z486 L1 line fill and store drain shapes).
//   port 1 font:   one 8-dword glyph burst every FONT_GAP clk_sys (~40 dwords/line).
//   port 2 PCM:    one dword per 44.1 kHz frame (1134 clk_sys), read/write alternating.
//   port 3 scanout: the PEGC PACKED line fetch - 160 dwords per line as sixteen 10-dword bursts,
//                  back to back (the worst case for its own line), in pc9821_pegc_scan's shape.

module tb_pc9821_sdram_bw;
  localparam integer CAS       = 2;
  localparam integer GK        = 4;
  // clk_sys is a PARAMETER (the deadlines below scale with it), and the controller runs on it:
  // the default is the shipped build's 90 MHz (build_profile.py base); -GSYS_MHZ=100 is mediumoc.
  parameter  integer SYS_MHZ   = 90;                 // clk_sys = the controller's clock
  localparam integer CTRL_MHZ  = SYS_MHZ;
  localparam integer CHIP_TRP  = (20 * CTRL_MHZ + 999) / 1000;   // sdram.v ns_to_cycles(20)
  localparam integer CHIP_TWR  = (15 * CTRL_MHZ + 999) / 1000;   // sdram.v ns_to_cycles(15)

  // The raster line budget, in clk_sys cycles. The 24 kHz line: 56.42 Hz * 440 VTOTAL -> 40.28 us =
  // 2014 clk_sys at 50 MHz, scaled to SYS_MHZ (3625 at 90). The 31 kHz line is SHORTER and is the
  // deadline: 800 dots (the BIOS 31 kHz and 640x480 blocks, NP2kai bios/bios18.c gdcmastersync[2..5])
  // at the 31 kHz dot clock 50 MHz x 78347/4096 / 38 = 25 168 007 Hz (pc9821_vclk_pkg, the capture
  // docs/probes/CRT31K.TXT) = 31.787 us = floor(800 * 38 * 4096 * SYS_MHZ / (50 * 78347)) clk_sys
  // (2860 at 90). The packed line is 640 bytes in both the 400- and 480-line modes.
  localparam integer LINE24_BUDGET_SYS = 2014 * SYS_MHZ / 50;
  localparam integer LINE_BUDGET_SYS = int'((64'd800 * 38 * 4096 * SYS_MHZ) / (64'd50 * 78347));
  localparam integer LINE_DWORDS     = 160;          // packed 640x400 8bpp line
  localparam integer SCAN_BURST      = 10;           // pc9821_pegc_scan's BURST_LEN
  localparam integer SCAN_BURSTS     = LINE_DWORDS / SCAN_BURST;   // 16
  localparam integer FONT_GAP        = 250 * SYS_MHZ / 50;         // clk_sys; ~40 dwords/line at burst 8
  localparam integer FONT_BURST      = 8;
  localparam integer PCM_GAP         = SYS_MHZ * 1_000_000 / 44_100;         // 50 MHz / 44.1 kHz
  localparam integer CPU_MIN_MBPS    = 40;
  localparam integer WARMUP_LINES    = 20;
  localparam integer MEAS_LINES      = 200;
  localparam integer CEIL_CYCLES     = 200_000;      // engine-ceiling window (clk_sys)
  localparam integer ADV_CYCLES      = 200_000;      // adversarial window (clk_sys)

  // ==== CLOCKS ====
  reg clk_sys = 0;
  always #(500.0 / SYS_MHZ) clk_sys = ~clk_sys;      // requesters, controller and device model
  wire clk = clk_sys;
  reg resetn = 0;

  // ==== DUT ====
  reg         cpu_valid = 0, cpu_wr = 0;
  reg  [26:0] cpu_addr = 27'd0;
  reg  [31:0] cpu_din  = 32'd0;
  reg   [3:0] cpu_be   = 4'hF;
  reg   [3:0] cpu_burst = 4'd4;
  wire        cpu_ready;
  wire [31:0] cpu_dout;
  wire        cpu_resp_valid;

  reg         font_valid = 0, font_wr = 0;
  reg  [26:0] font_addr = 27'd0;
  reg  [31:0] font_din  = 32'd0;
  reg   [3:0] font_be   = 4'hF;
  reg   [3:0] font_burst = 4'(FONT_BURST);
  wire        font_ready;
  wire [31:0] font_dout;
  wire        font_resp_valid;

  reg         pcm_valid = 0, pcm_wr = 0;
  reg  [26:0] pcm_addr = 27'd0;
  reg  [31:0] pcm_din  = 32'd0;
  reg   [3:0] pcm_be   = 4'hF;
  reg   [3:0] pcm_burst = 4'd1;
  wire        pcm_ready;
  wire [31:0] pcm_dout;
  wire        pcm_resp_valid;

  reg         scan_valid = 0, scan_wr = 0;
  reg  [26:0] scan_addr = 27'd0;
  reg  [31:0] scan_din  = 32'd0;
  reg   [3:0] scan_be   = 4'hF;
  reg   [3:0] scan_burst = 4'(SCAN_BURST);
  wire        scan_ready;
  wire [31:0] scan_dout;
  wire        scan_resp_valid;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;
  wire        busy;

  sdram_sync_bridge #(
      .FREQ(CTRL_MHZ * 1_000_000), .ADQM(1'b1), .FAST_GRADE(1'b0), .GATHER_K(GK)
  ) backend (
      .clk(clk_sys), .resetn(resetn),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(cpu_valid),  .ready0(cpu_ready),  .wr0(cpu_wr),
      .addr0(cpu_addr), .din0(cpu_din), .din0_hi(32'd0), .gath0(1'b0), .gath0_extra(441'd0),
      .dout0(cpu_dout), .resp_valid0(cpu_resp_valid), .be0(cpu_be), .burst_cnt0(cpu_burst),
      .valid1(font_valid), .ready1(font_ready), .wr1(font_wr),
      .addr1(font_addr), .din1(font_din),
      .dout1(font_dout), .resp_valid1(font_resp_valid), .be1(font_be), .burst_cnt1(font_burst),
      .valid2(pcm_valid), .ready2(pcm_ready), .wr2(pcm_wr),
      .addr2(pcm_addr), .din2(pcm_din),
      .dout2(pcm_dout), .resp_valid2(pcm_resp_valid), .be2(pcm_be), .burst_cnt2(pcm_burst),
      .valid3(scan_valid), .ready3(scan_ready), .wr3(scan_wr),
      .addr3(scan_addr), .din3(scan_din),
      .dout3(scan_dout), .resp_valid3(scan_resp_valid), .be3(scan_be), .burst_cnt3(scan_burst),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS), .SDRAM_CKE(CKE)
  );

  // The AUTO REFRESH gap is held to tREFI = 64 ms / 8192 rows (the AS4C32M16SB datasheet's 8192
  // refreshes per 64 ms) on the pins, under this bench's saturating four-stream load.
  sdram_chip_model #(.CAS(CAS), .T_RP(CHIP_TRP), .T_WR(CHIP_TWR), .FREQ_HZ(SYS_MHZ * 1_000_000), .GRADE(7),
                     .REFRESH_INTERVAL(SYS_MHZ * 1_000_000 / 128_000)) chip (
      .clk(clk_sys), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_bw: %0s", what);
    end
  endtask

  // ==== STIMULUS ====
  // The four requester FSMs below drive the client-side ports (clk_sys) of the real bridge:
  // port 0 the CPU (saturating 4-dword reads / single-dword writes, or the ceiling/adversarial
  // shapes), port 1 the font glyph burst, port 2 the PCM sample, port 3 the PEGC packed line.
  // ==== MODE / WINDOW CONTROL ====
  // mode: 0 = settle/idle, 1 = demand mix, 2 = engine ceiling (port 0 read), 3 = ceiling write,
  //       4 = adversarial (all four saturate).
  integer mode = 0;
  integer cyc_sys = 0;
  always @(posedge clk_sys) cyc_sys <= cyc_sys + 1;

  // Placed-fail check: `+tight` shrinks the line budget so the gate's own FAIL path is exercised.
  integer budget_sys = LINE_BUDGET_SYS;
  initial if ($test$plusargs("tight")) budget_sys = 100;

  // The mode each port's in-flight request was presented under (see the hold guard below).
  integer cpu_mode_q = 0, font_mode_q = 0, pcm_mode_q = 0, scan_mode_q = 0;
  always @(posedge clk_sys) begin
    if (!cpu_valid  || cpu_ready)  cpu_mode_q  <= mode;
    if (!font_valid || font_ready) font_mode_q <= mode;
    if (!pcm_valid  || pcm_ready)  pcm_mode_q  <= mode;
    if (!scan_valid || scan_ready) scan_mode_q <= mode;
  end

  // ==== PORT 0: CPU ====
  integer cpu_accepts = 0, cpu_dwords = 0;
  reg [1:0] cpu_phase = 2'd0;
  integer supply_accepts = 0, supply_dwords = 0;      // ceiling/adversarial window counters
  always @(posedge clk_sys) begin
    if (!resetn) begin
      cpu_valid <= 1'b0; cpu_wr <= 1'b0; cpu_burst <= 4'd4; cpu_phase <= 2'd0;
    end else if (cpu_valid && !cpu_ready && (mode != cpu_mode_q)) begin
      // A window change never abandons a presented request: it is held, payload and all,
      // until its ready (the backend contract - the same-clock bridge asserts it).
    end else if (mode == 1) begin
      cpu_valid <= 1'b1;                              // saturating
      cpu_burst <= 4'd4;
      if (cpu_ready) begin
        cpu_accepts <= cpu_accepts + 1;
        cpu_dwords  <= cpu_dwords + (cpu_wr ? 1 : 4);
        cpu_addr    <= cpu_addr + 27'd64;
        cpu_phase   <= cpu_phase + 2'd1;
        cpu_wr      <= (cpu_phase == 2'd2);           // the NEXT request is the write (moved on its own accept edge, never mid-flight)
      end
    end else if (mode == 2) begin
      cpu_valid <= 1'b1; cpu_wr <= 1'b0; cpu_burst <= 4'd15;   // engine ceiling: max read burst
      if (cpu_ready) begin
        supply_accepts <= supply_accepts + 1;
        supply_dwords  <= supply_dwords + 15;
        cpu_addr       <= cpu_addr + 27'd60;
      end
    end else if (mode == 3) begin
      cpu_valid <= 1'b1; cpu_wr <= 1'b1; cpu_burst <= 4'd1;    // engine ceiling: single-word write
      if (cpu_ready) begin
        supply_accepts <= supply_accepts + 1;
        supply_dwords  <= supply_dwords + 1;
        cpu_addr       <= cpu_addr + 27'd4;
      end
    end else if (mode == 4) begin
      cpu_valid <= 1'b1; cpu_wr <= 1'b0; cpu_burst <= 4'd15;   // adversarial
      if (cpu_ready) begin
        supply_accepts <= supply_accepts + 1;
        supply_dwords  <= supply_dwords + 15;
        cpu_addr       <= cpu_addr + 27'd60;
      end
    end else begin
      cpu_valid <= 1'b0;
    end
  end

  // ==== PORT 1: font ====
  integer font_accepts = 0;
  integer font_gap = 0;
  integer adv_font_accepts = 0;
  always @(posedge clk_sys) begin
    if (!resetn) begin
      font_valid <= 1'b0; font_gap <= 0;
    end else if (font_valid && !font_ready && (mode != font_mode_q)) begin
      // A window change never abandons a presented request: it is held, payload and all,
      // until its ready (the backend contract - the same-clock bridge asserts it).
    end else if (mode == 1) begin
      if (font_ready) begin
        font_valid <= 1'b0; font_accepts <= font_accepts + 1;
      end
      if (font_gap == 0 && !font_valid) begin
        font_valid <= 1'b1; font_addr <= font_addr + 27'd32; font_gap <= FONT_GAP;
      end else if (font_gap != 0) begin
        font_gap <= font_gap - 1;
      end
    end else if (mode == 4) begin
      font_valid <= 1'b1; font_burst <= 4'd15;
      if (font_ready) begin
        adv_font_accepts <= adv_font_accepts + 1;
        font_addr <= font_addr + 27'd60;
      end
    end else begin
      font_valid <= 1'b0;
    end
  end

  // ==== PORT 2: PCM ====
  integer pcm_accepts = 0;
  integer pcm_gap = 0;
  integer adv_pcm_accepts = 0;
  always @(posedge clk_sys) begin
    if (!resetn) begin
      pcm_valid <= 1'b0; pcm_gap <= 0;
    end else if (pcm_valid && !pcm_ready && (mode != pcm_mode_q)) begin
      // A window change never abandons a presented request: it is held, payload and all,
      // until its ready (the backend contract - the same-clock bridge asserts it).
    end else if (mode == 1) begin
      if (pcm_ready) begin
        pcm_valid <= 1'b0; pcm_accepts <= pcm_accepts + 1;
      end
      if (pcm_gap == 0 && !pcm_valid) begin
        pcm_valid <= 1'b1; pcm_wr <= ~pcm_wr; pcm_addr <= pcm_addr + 27'd4; pcm_gap <= PCM_GAP;
      end else if (pcm_gap != 0) begin
        pcm_gap <= pcm_gap - 1;
      end
    end else if (mode == 4) begin
      pcm_valid <= 1'b1; pcm_burst <= 4'd15;
      if (pcm_ready) begin
        adv_pcm_accepts <= adv_pcm_accepts + 1;
        pcm_addr <= pcm_addr + 27'd60;
      end
    end else begin
      pcm_valid <= 1'b0;
    end
  end

  // ==== PORT 3: PEGC packed scanout, 160 dwords/line as sixteen 10-dword bursts ====
  reg [4:0]  scan_bidx  = 5'd0;      // 0..15
  reg [3:0]  scan_beats = 4'd0;      // beats left in the current burst
  integer    scan_line_start = 0;
  integer    worst_line = 0;
  integer    lines_done = 0;
  integer    scan_accepts = 0;
  integer    adv_scan_accepts = 0;
  always @(posedge clk_sys) begin
    if (!resetn) begin
      scan_valid <= 1'b0; scan_bidx <= 5'd0; scan_beats <= 4'd0;
    end else if (scan_valid && !scan_ready && (mode != scan_mode_q)) begin
      // A window change never abandons a presented request: it is held, payload and all,
      // until its ready (the backend contract - the same-clock bridge asserts it).
    end else if (mode == 1) begin
      // Issue a burst whenever none is in flight; on the last burst's last beat, close the line.
      if (scan_ready) begin
        scan_valid <= 1'b0;
        scan_beats <= 4'(SCAN_BURST);
        scan_accepts <= scan_accepts + 1;
      end
      if (scan_resp_valid && (scan_beats != 4'd0)) begin
        if (scan_beats == 4'd1) begin
          if (scan_bidx == 5'(SCAN_BURSTS-1)) begin
            if (lines_done >= WARMUP_LINES) begin
              if ((cyc_sys - scan_line_start) > worst_line)
                worst_line <= cyc_sys - scan_line_start;
            end
            lines_done <= lines_done + 1;
            scan_bidx  <= 5'd0;
            scan_line_start <= cyc_sys;
          end else begin
            scan_bidx <= scan_bidx + 5'd1;
          end
          scan_beats <= 4'd0;
        end else begin
          scan_beats <= scan_beats - 4'd1;
        end
      end
      if (!scan_valid && (scan_beats == 4'd0)) begin
        scan_valid <= 1'b1;
        scan_addr  <= 27'h0010_0000 + {16'd0, scan_bidx, 4'd0, 2'b00};  // 64 bytes per burst
        scan_burst <= 4'(SCAN_BURST);
      end
    end else if (mode == 4) begin
      scan_valid <= 1'b1; scan_burst <= 4'd15;
      if (scan_ready) begin
        adv_scan_accepts <= adv_scan_accepts + 1;
        scan_addr <= scan_addr + 27'd60;
      end
    end else begin
      scan_valid <= 1'b0;
    end
  end

  // ==== MEASUREMENT ====
  real    cpu_mbps, ceil_rd_mbps, ceil_wr_mbps, adv_total_mbps;
  integer cyc0, cyc1, dwords0, dwords1, accepts0;
  integer dcyc, dpcm0;
  integer guard;
  integer adv_dwords;
  integer adv_scan_valid_cyc = 0;   // cycles port 3 held valid during the adversarial window
  always @(posedge clk_sys) if (mode == 4 && scan_valid) adv_scan_valid_cyc <= adv_scan_valid_cyc + 1;

  initial begin
    repeat (8) @(posedge clk);
    resetn = 1;

    // Wait out the controller's own init.
    guard = 0;
    while (busy && guard < 2000000) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (busy) fail("the controller never left init");

    // ---- PHASE 1: the real demand mix ----
    mode = 1;
    scan_line_start = cyc_sys;
    guard = 0;
    while ((lines_done < WARMUP_LINES) && (guard < 20_000_000)) begin
      @(posedge clk_sys);
      guard = guard + 1;
    end
    if (lines_done < WARMUP_LINES) fail("the scanout did not complete its warm-up lines");

    cyc0 = cyc_sys; dwords0 = cpu_dwords; accepts0 = scan_accepts;
    dpcm0 = pcm_accepts;
    guard = 0;
    while ((lines_done < WARMUP_LINES + MEAS_LINES) && (guard < 200_000_000)) begin
      @(posedge clk_sys);
      guard = guard + 1;
    end
    if (lines_done < WARMUP_LINES + MEAS_LINES)
      fail("the scanout did not complete the measurement lines");
    cyc1 = cyc_sys; dwords1 = cpu_dwords;
    dcyc  = cyc1 - cyc0;

    if (cyc1 > cyc0)
      cpu_mbps = (dwords1 - dwords0) * 4.0 * SYS_MHZ / (cyc1 - cyc0);
    else
      cpu_mbps = 0.0;

    $display("NOTE sdram_bw demand: %0d lines; worst packed line %0d clk_sys (budget %0d); CPU %0.1f MB/s; scanout accepts %0d",
             MEAS_LINES, worst_line, budget_sys, cpu_mbps, scan_accepts - accepts0);

    // ---- PHASE 2: engine ceiling, port 0 alone, max read burst ----
    mode = 0; repeat (200) @(posedge clk_sys);
    supply_accepts = 0; supply_dwords = 0;
    cyc0 = cyc_sys; dwords0 = supply_dwords;
    mode = 2;
    repeat (CEIL_CYCLES) @(posedge clk_sys);
    cyc1 = cyc_sys; dwords1 = supply_dwords;
    mode = 0;
    ceil_rd_mbps = (cyc1 > cyc0) ? (dwords1 - dwords0) * 4.0 * SYS_MHZ / (cyc1 - cyc0) : 0.0;
    $display("NOTE sdram_bw ceiling: 15-dword reads %0.1f MB/s over %0d clk_sys (%0d dwords)",
             ceil_rd_mbps, cyc1 - cyc0, dwords1 - dwords0);

    // ---- PHASE 3: engine ceiling, port 0 alone, single-word writes ----
    repeat (200) @(posedge clk_sys);
    supply_accepts = 0; supply_dwords = 0;
    cyc0 = cyc_sys; dwords0 = supply_dwords;
    mode = 3;
    repeat (CEIL_CYCLES) @(posedge clk_sys);
    cyc1 = cyc_sys; dwords1 = supply_dwords;
    mode = 0;
    ceil_wr_mbps = (cyc1 > cyc0) ? (dwords1 - dwords0) * 4.0 * SYS_MHZ / (cyc1 - cyc0) : 0.0;
    $display("NOTE sdram_bw ceiling: 1-word writes %0.1f MB/s over %0d clk_sys (%0d dwords)",
             ceil_wr_mbps, cyc1 - cyc0, dwords1 - dwords0);

    // ---- PHASE 4: adversarial, all four saturate 15-dword reads ----
    repeat (200) @(posedge clk_sys);
    supply_accepts = 0; supply_dwords = 0;
    adv_font_accepts = 0; adv_pcm_accepts = 0; adv_scan_accepts = 0;
    adv_scan_valid_cyc = 0;
    cyc0 = cyc_sys; dwords0 = supply_dwords;
    mode = 4;
    repeat (ADV_CYCLES) @(posedge clk_sys);
    cyc1 = cyc_sys; dwords1 = supply_dwords;
    mode = 0;
    adv_dwords = dwords1 - dwords0;
    adv_total_mbps = (cyc1 > cyc0) ? (adv_dwords * 4.0 * SYS_MHZ) / (cyc1 - cyc0) : 0.0;
    $display("NOTE sdram_bw adversarial: port0 %0d, font %0d, pcm %0d, scan %0d accepts (scan held valid %0d clk_sys); aggregate port0-only %0.1f MB/s",
             supply_accepts, adv_font_accepts, adv_pcm_accepts, adv_scan_accepts, adv_scan_valid_cyc, adv_total_mbps);
    // The packed line's cost if all four ports saturated: 16 bursts at the measured accept spacing.
    if (adv_scan_accepts > 0)
      $display("NOTE sdram_bw adversarial packed line: %0d clk_sys for %0d bursts (31 kHz budget %0d, 24 kHz %0d; reported, not asserted)",
               (ADV_CYCLES * SCAN_BURSTS) / adv_scan_accepts, SCAN_BURSTS, LINE_BUDGET_SYS, LINE24_BUDGET_SYS);

    // ==== VERDICT ====
    // machine-derived deadlines at the CURRENT demand only
    if (worst_line == 0)
      fail("no scanout line completed: the demand measurement is vacuous");
    if (worst_line > budget_sys)
      fail("the packed scanout line EXCEEDED the raster line budget -- the demand does not fit");
    // The 40 MB/s is REPORTED (header: trade T36); being served at all is asserted.
    if (cpu_mbps <= 0.0)
      fail("the CPU was not served at all under the demand mix");
    $display("NOTE sdram_bw CPU under the demand mix: %0.1f MB/s against the old %0d MB/s split-clock requirement (%s; reported, not asserted - trade T36)",
             cpu_mbps, CPU_MIN_MBPS, (cpu_mbps < CPU_MIN_MBPS) ? "BELOW" : "at or above");
    if (pcm_accepts - dpcm0 + 2 < (dcyc / PCM_GAP))
      fail("the PCM stream did not receive its requested rate");

    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_BW: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_SDRAM_BW: FAIL (%0d problems)", errors);
      $fatal(1, "the SDRAM demand/headroom measurement did not hold");
    end
  end

  // A hang is a named failure, not a timeout.
  initial begin
    repeat (200_000_000) @(posedge clk);
    $fatal(1, "TB_PC9821_SDRAM_BW: FAIL (the bench did not finish -- a request never completed)");
  end
endmodule
