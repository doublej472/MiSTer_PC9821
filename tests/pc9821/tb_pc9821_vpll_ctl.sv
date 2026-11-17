`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The video PLL controller (pc9821_vpll_ctl) puts the fractional video PLL into the dot clock the guest's raster runs on, only ever at a legal fractional setting, holds the video side off until the PLL has relocked, and never waits forever: at power-up, with the PLL generated in the 24 kHz configuration, it makes NO write and releases `busy` only after lock has been continuously high for SETTLE clocks; on every configuration change it writes the N counter (address 3, bypass), the M counter (address 4) and the 32-bit fraction K (address 7), then a start (address 2), each held until waitrequest drops, exactly once per change and never while nothing changes, and never a C counter (the framework's pll_cfg_hdmi writes any C counter write to physical counter 5, sys/pll_cfg/pll_cfg_hdmi.v); decoding those words as Altera's Cyclone V PLL reconfiguration map defines them (counter = high + low, bypass = 1; output = 50 MHz x (M + K/2^32) / (N x C0), C0 the generated 24) the video clock is 2 x 400/19 MHz within 0.05 ppm with 0x09A8 bit 0 clear (the 24 kHz dot clock) and 2 x the Xe10's measured 31 kHz dot clock within 3 ppm while 0x09A8 bit 0 is set (docs/probes/CRT31K.TXT: 25 168 031 Hz, calibrated), and every fraction K/2^32 it programs is inside 0.05..0.95, the range Quartus 17.0's PLL generator accepts for a fractional-N PLL ("fractional multiplication factor outside of the legal range (0.05 to 0.95)"); `vclk_31` names the requested configuration from the first write; `busy` rises with the first write and falls only after lock has been continuously high for SETTLE clocks after the start; a lock loss while idle raises `busy` again until the PLL has relocked and settled, with no write; and when the PLL does not relock within TIMEOUT clocks of a start, or the reconfiguration core holds waitrequest on a write for TIMEOUT clocks, the controller drops its write, pulses `pll_rst` (the PLL's areset and the core's mgmt_reset) for RST_CLKS clocks, waits for lock, and writes the whole wanted configuration again, with `busy` high from the fault until the rewritten configuration has settled. FAIL-FIRST: the controller before this change has no `pll_rst` port, so the bench cannot build against it; it also wrote K 0 for 24 kHz (outside the legal range) at every power-up, which the power-up and legal-range checks reject.
//
// THE REGISTER MAP is Altera's Cyclone V PLL reconfiguration interface (altera_pll_reconfig, the
// framework's sys/pll_cfg_hdmi, as Main_MiSTer drives it for the HDMI PLL in video.cpp setPLL):
// 0x02 start, 0x03 N, 0x04 M, 0x05 C, 0x07 M's fraction K; a counter word {odd[17], bypass[16],
// high[15:8], low[7:0]}. The model's registers start at the generated 24 kHz configuration
// (rtl/vpll/vpll_0002.v as tools/profile_gen.py reads it back: M 10+10, K 904200192, C0 12+12);
// C0 is never written, so the model keeps it. The expected frequencies are the dot clocks' (400/19 MHz: the
// 24 kHz rate pc9821_dot_ce documents; 25 168 031 Hz: the capture, tools/hwprobe/crt31k/crt31k_decode.py)
// times two - never read out of the controller.
//
// WHAT IT IS BLIND TO: the real reconfiguration core and PLL (modelled: waitrequest for a few clocks
// per write, lock dropping for LOCK_GAP clocks after a start or a reset; the faults are forced);
// whether the hardware PLL relocks at each setting, or recovers after an areset, is a hardware fact
// the card's load loop measures.

module tb_pc9821_vpll_ctl;
  localparam integer SETTLE   = 64;
  localparam integer LOCK_GAP = 200;
  localparam integer TIMEOUT  = 3000;
  localparam integer RST_CLKS = 16;
  localparam real    CAP_31K_HZ = 25_168_031.0;   // docs/probes/CRT31K.TXT, calibrated (crt31k_decode.py)
  localparam real    DOT24_HZ   = 400.0e6 / 19.0; // the 24 kHz dot clock pc9821_dot_ce documents
  reg clk = 0;
  always #10 clk = ~clk;   // the 50 MHz reference

  reg  want_31k = 1'b0;
  reg  pll_locked = 1'b0;
  reg  no_relock = 1'b0;     // fault: the PLL does not relock after the next start
  reg  stuck_wait = 1'b0;    // fault: the core holds waitrequest on every write
  wire waitreq;
  wire mgmt_write;
  wire [5:0]  mgmt_address;
  wire [31:0] mgmt_writedata;
  wire pll_rst, vclk_31, busy;

  // ==== DUT ====
  pc9821_vpll_ctl #(.SETTLE(SETTLE), .STABLE(0), .TIMEOUT(TIMEOUT), .RST_CLKS(RST_CLKS)) dut (
    .clk(clk), .want_31k(want_31k), .pll_locked(pll_locked),
    .mgmt_waitrequest(waitreq),
    .mgmt_write(mgmt_write), .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
    .pll_rst(pll_rst), .vclk_31(vclk_31), .busy(busy)
  );

  // ---- the reconfiguration core and PLL model ----
  // Avalon-MM: a write is accepted on the clock edge where write is high and waitrequest low; the
  // model holds waitrequest for three clocks of every write, and a start drops lock for LOCK_GAP.
  // A reset (pll_rst) drops lock while it is held and for LOCK_GAP after. The model keeps the PLL's
  // registers, so the frequency it would make is decoded from the words.
  integer n_writes = 0, wcnt = 0, gap = 0, n_rst = 0, bad_frac = 0, c_writes = 0;
  reg [5:0]  log_addr [0:255];
  reg [31:0] log_data [0:255];
  reg [31:0] r_n = 32'h0001_0000, r_m = 32'h0000_0A0A, r_k = 32'h35E5_0000, r_c = 32'h0000_0C0C;
  integer cycle = 0, lock_rise_at = 0;
  reg rst_q = 1'b0;
  real frac;
  assign waitreq = mgmt_write && (stuck_wait || wcnt < 3);
  always @(posedge clk) begin
    cycle <= cycle + 1;
    rst_q <= pll_rst;
    if (pll_rst && !rst_q) n_rst <= n_rst + 1;
    if (mgmt_write && !stuck_wait) begin
      if (wcnt < 3) wcnt <= wcnt + 1;
      else begin
        log_addr[n_writes] <= mgmt_address;
        log_data[n_writes] <= mgmt_writedata;
        n_writes <= n_writes + 1;
        wcnt <= 0;
        case (mgmt_address)
          6'd3: r_n <= mgmt_writedata;
          6'd4: r_m <= mgmt_writedata;
          6'd5: begin r_c <= mgmt_writedata; c_writes <= c_writes + 1; end
          6'd7: begin
            r_k <= mgmt_writedata;
            frac = real'(mgmt_writedata) / 4294967296.0;
            if (frac < 0.05 || frac > 0.95) bad_frac <= bad_frac + 1;
          end
          6'd2: begin pll_locked <= 1'b0; gap <= no_relock ? 0 : LOCK_GAP; end
          default: ;
        endcase
      end
    end
    if (pll_rst) begin pll_locked <= 1'b0; gap <= LOCK_GAP; end
    else if (gap > 0) begin
      gap <= gap - 1;
      if (gap == 1) begin pll_locked <= 1'b1; lock_rise_at <= cycle + 1; end
    end
  end

  // A counter word's division: bypass = 1, else high + low (odd duty is the high/low split itself).
  function automatic integer cdiv(input [31:0] w);
    cdiv = w[16] ? 1 : (w[15:8] + w[7:0]);
  endfunction
  // The output the registers make, in Hz.
  function automatic real fout();
    fout = 50.0e6 * (real'(cdiv(r_m)) + real'(r_k) / 4294967296.0) / (real'(cdiv(r_n)) * real'(cdiv(r_c)));
  endfunction

  // ==== CHECKS ====
  integer fails = 0;
  task automatic expect_true(input bit c, input string what);
    if (!c) begin $display("FAIL: %s", what); fails++; end
  endtask

  task automatic wait_idle;
    integer t;
    t = 0;
    while (busy && t < 100000) begin @(posedge clk); t++; end
    expect_true(!busy, "busy falls after the relock");
  endtask

  // One configuration change: exactly N, M, K, start, in that order, from w0.
  task automatic expect_sequence(input integer w0, input string what);
    expect_true(n_writes == w0 + 4, $sformatf("%s: %0d writes, want 4 (N, M, K, start)", what, n_writes - w0));
    expect_true(log_addr[w0] == 6'd3 && log_addr[w0+1] == 6'd4 && log_addr[w0+2] == 6'd7 &&
                log_addr[w0+3] == 6'd2,
                $sformatf("%s: addresses %0d %0d %0d %0d, want 3 4 7 2", what, log_addr[w0],
                          log_addr[w0+1], log_addr[w0+2], log_addr[w0+3]));
    expect_true(log_data[w0][16] == 1'b1, $sformatf("%s: N 0x%0h is not bypassed (the PFD must be the 50 MHz reference)", what, log_data[w0]));
  endtask

  // The decoded output against the 24 kHz clock, 2 x 400/19 MHz, within 0.05 ppm.
  task automatic expect_24k(input string what);
    real f, ppm;
    f = fout();
    ppm = (f - 2.0 * DOT24_HZ) / (2.0 * DOT24_HZ) * 1.0e6;
    expect_true(ppm < 0.05 && ppm > -0.05,
                $sformatf("%s: the PLL makes %.6f Hz, %.4f ppm from 2 x 400/19 MHz (want within 0.05)", what, f, ppm));
  endtask

  task automatic expect_31k(input string what);
    real f31, ppm;
    f31 = fout() / 2.0;
    ppm = (f31 - CAP_31K_HZ) / CAP_31K_HZ * 1.0e6;
    $display("  %s: the PLL makes %.3f Hz = 2 x %.3f Hz, %.3f ppm from the capture's %.0f Hz", what, fout(), f31, ppm, CAP_31K_HZ);
    expect_true(ppm < 3.0 && ppm > -3.0, $sformatf("%s: dot clock %.3f Hz is %.2f ppm from the capture's 25 168 031 Hz (want within 3)", what, f31, ppm));
  endtask

  integer w0, r0, busy_low_at, t;
  initial begin
    // ---- power-up: the PLL locks at its generated (24 kHz) configuration; nothing is written ----
    expect_true(busy, "busy at power-up");
    expect_true(!vclk_31, "power-up: vclk_31 names the generated 24 kHz configuration");
    expect_true(!pll_rst, "power-up: no reset");
    repeat (20) @(posedge clk);
    pll_locked = 1'b1; lock_rise_at = cycle;
    wait_idle();
    busy_low_at = cycle;
    expect_true(n_writes == 0, $sformatf("power-up: %0d writes, want none (the PLL is generated at 24 kHz)", n_writes));
    expect_24k("power-up (24 kHz, as generated)");
    expect_true(busy_low_at - lock_rise_at >= SETTLE, $sformatf("busy fell %0d clocks after the lock, want >= %0d", busy_low_at - lock_rise_at, SETTLE));

    // ---- nothing changes: no write ----
    w0 = n_writes;
    repeat (2000) @(posedge clk);
    expect_true(n_writes == w0 && !busy, "idle: no write, not busy");

    // ---- 0x09A8 bit 0 set: the 31 kHz dot clock ----
    @(posedge clk); want_31k = 1'b1;
    repeat (5) @(posedge clk);
    expect_true(busy && vclk_31, "busy and vclk_31 rise with the 31 kHz request");
    wait_idle();
    expect_sequence(w0, "31 kHz");
    expect_31k("31 kHz");

    // ---- 0x09A8 bit 0 cleared: back to the 24 kHz clock ----
    w0 = n_writes;
    @(posedge clk); want_31k = 1'b0;
    repeat (5) @(posedge clk);
    expect_true(busy && !vclk_31, "busy rises and vclk_31 falls with the 24 kHz request");
    wait_idle();
    expect_sequence(w0, "24 kHz");
    expect_24k("24 kHz again");

    // ---- lock lost while idle: busy until relocked and settled, no write ----
    w0 = n_writes;
    @(posedge clk); pll_locked = 1'b0;
    repeat (10) @(posedge clk);
    expect_true(busy, "busy while the PLL is unlocked");
    repeat (50) @(posedge clk);
    pll_locked = 1'b1;
    repeat (SETTLE / 2) @(posedge clk);
    expect_true(busy, "still busy inside the settle window");
    wait_idle();
    expect_true(n_writes == w0 && n_rst == 0, "a lock loss that recovers writes nothing and resets nothing");

    // ---- the PLL does not relock after a start: reset, relock, reprogram ----
    w0 = n_writes; r0 = n_rst;
    no_relock = 1'b1;
    @(posedge clk); want_31k = 1'b1;
    t = 0;
    while (n_writes < w0 + 4 && t < 1000) begin @(posedge clk); t++; end
    no_relock = 1'b0;
    repeat (TIMEOUT / 2) @(posedge clk);
    expect_true(busy && n_rst == r0, "no relock: busy, and no reset before TIMEOUT");
    t = 0;
    while (n_rst == r0 && t < 2 * TIMEOUT) begin @(posedge clk); t++; end
    expect_true(n_rst == r0 + 1, "no relock: the PLL is reset after TIMEOUT");
    expect_true(t > TIMEOUT / 2 - SETTLE - 100, $sformatf("no relock: the reset came %0d clocks after the half-way check, want about TIMEOUT/2", t));
    t = 0;
    while (pll_rst && t < 1000) begin @(posedge clk); t++; end
    expect_true(t >= RST_CLKS - 1 && t <= RST_CLKS + 2, $sformatf("the reset pulse is %0d clocks, want RST_CLKS (%0d)", t, RST_CLKS));
    expect_true(busy, "busy while the PLL comes out of reset");
    wait_idle();
    expect_sequence(w0 + 4, "no relock: the rewrite after the reset");
    expect_31k("31 kHz after the recovery");
    expect_true(vclk_31 && n_rst == r0 + 1, "no relock: one reset, the 31 kHz configuration");

    // ---- the core never takes a write: reset, then reprogram ----
    w0 = n_writes; r0 = n_rst;
    stuck_wait = 1'b1;
    @(posedge clk); want_31k = 1'b0;
    t = 0;
    while (n_rst == r0 && t < 3 * TIMEOUT) begin @(posedge clk); t++; end
    expect_true(n_rst == r0 + 1 && n_writes == w0, "stuck waitrequest: no write taken, the PLL is reset");
    expect_true(!mgmt_write, "stuck waitrequest: the write is dropped with the reset");
    stuck_wait = 1'b0;
    wait_idle();
    expect_sequence(w0, "stuck waitrequest: the rewrite after the reset");
    expect_24k("24 kHz after the recovery");
    expect_true(!vclk_31 && n_rst == r0 + 1, "stuck waitrequest: one reset, the 24 kHz configuration");

    // ---- every fraction written was legal, and no C counter was written ----
    expect_true(bad_frac == 0, $sformatf("%0d K write(s) outside the legal fraction 0.05..0.95", bad_frac));
    expect_true(c_writes == 0, $sformatf("%0d C counter write(s), want none", c_writes));

    // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_VPLL_CTL: %0d check(s) failed", fails);
    $display("TB_PC9821_VPLL_CTL: PASS");
    $finish;
  end
endmodule
