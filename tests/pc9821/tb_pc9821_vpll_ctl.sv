`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The video PLL controller (pc9821_vpll_ctl) puts the fractional video PLL into the dot clock the guest's raster runs on and holds the video side off until the PLL has relocked: on every configuration change it writes the N counter (address 3, bypass), the M counter (address 4) and the 32-bit fraction K (address 7), then a start (address 2), each held until waitrequest drops, exactly once per change and never while nothing changes; decoding those words as Altera's Cyclone V PLL reconfiguration map defines them (counter = high + low, bypass = 1; output = 50 MHz x (M + K/2^32) / (N x C0), C0 the generated 19) the video clock is exactly 2 x 400/19 MHz with 0x09A8 bit 0 clear (the 24 kHz dot clock, and the configuration the controller settles on at power-up) and 2 x the Xe10's measured 31 kHz dot clock within 3 ppm while 0x09A8 bit 0 is set (docs/probes/CRT31K.TXT: 25 168 031 Hz, calibrated); `vclk_31` names the requested configuration from the first write; `busy` rises with the first write and falls only after lock has been continuously high for SETTLE clocks after the start; and a lock loss while idle raises `busy` again until the PLL has relocked and settled, with no write. FAIL-FIRST: the pre-31 kHz controller has no 0x09A8 input and writes no fraction, so the bench cannot build against it.
//
// THE REGISTER MAP is Altera's Cyclone V PLL reconfiguration interface (altera_pll_reconfig, the
// framework's sys/pll_cfg_hdmi, as Main_MiSTer drives it for the HDMI PLL): 0x02 start, 0x03 N,
// 0x04 M, 0x05 C, 0x07 M's fraction K; a counter word {odd[17], bypass[16], high[15:8], low[7:0]}.
// C0 is not written (19 in every setting, as generated), so the model keeps it. The expected
// frequencies are the dot clocks' (400/19 MHz: the 24 kHz rate pc9821_dot_ce documents; 25 168 031 Hz:
// the capture, tools/hwprobe/crt31k/crt31k_decode.py) times two - never read out of the controller.
//
// WHAT IT IS BLIND TO: the real reconfiguration core and PLL (modelled: waitrequest for a few clocks
// per write, lock dropping for LOCK_GAP clocks after a start); that the hardware PLL relocks at each
// setting is a hardware fact (the fractional PLL is generated at the 31 kHz setting with the same
// charge pump and bandwidth the integer one had, and the PFD stays the 50 MHz reference).

module tb_pc9821_vpll_ctl;
  localparam integer SETTLE   = 64;
  localparam integer LOCK_GAP = 200;
  localparam real    CAP_31K_HZ = 25_168_031.0;   // docs/probes/CRT31K.TXT, calibrated (crt31k_decode.py)
  reg clk = 0;
  always #10 clk = ~clk;   // the 50 MHz reference

  reg  want_31k = 1'b0;
  reg  pll_locked = 1'b0;
  wire waitreq;
  wire mgmt_write;
  wire [5:0]  mgmt_address;
  wire [31:0] mgmt_writedata;
  wire vclk_31, busy;

  // ==== DUT ====
  pc9821_vpll_ctl #(.SETTLE(SETTLE)) dut (
    .clk(clk), .want_31k(want_31k), .pll_locked(pll_locked),
    .mgmt_waitrequest(waitreq),
    .mgmt_write(mgmt_write), .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
    .vclk_31(vclk_31), .busy(busy)
  );

  // ---- the reconfiguration core and PLL model ----
  // Avalon-MM: a write is accepted on the clock edge where write is high and waitrequest low; the
  // model holds waitrequest for three clocks of every write, and a start drops lock for LOCK_GAP.
  // The model keeps the PLL's registers, so the frequency it would make is decoded from the words.
  integer n_writes = 0, wcnt = 0, gap = 0;
  reg [5:0]  log_addr [0:63];
  reg [31:0] log_data [0:63];
  reg [31:0] r_n = 32'h0001_0000, r_m = 32'h0002_0A09, r_k = 32'h20B0_0000, r_c = 32'h0002_0A09;
  integer cycle = 0, lock_rise_at = 0;
  assign waitreq = mgmt_write && (wcnt < 3);
  always @(posedge clk) begin
    cycle <= cycle + 1;
    if (mgmt_write) begin
      if (wcnt < 3) wcnt <= wcnt + 1;
      else begin
        log_addr[n_writes] <= mgmt_address;
        log_data[n_writes] <= mgmt_writedata;
        n_writes <= n_writes + 1;
        wcnt <= 0;
        case (mgmt_address)
          6'd3: r_n <= mgmt_writedata;
          6'd4: r_m <= mgmt_writedata;
          6'd5: r_c <= mgmt_writedata;
          6'd7: r_k <= mgmt_writedata;
          6'd2: begin pll_locked <= 1'b0; gap <= LOCK_GAP; end
          default: ;
        endcase
      end
    end
    if (gap > 0) begin
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

  // The decoded output against an exact rational (the 24 kHz clock): within 1 Hz of 1e-6 ppm.
  task automatic expect_exact(input real want, input string what);
    real f;
    f = fout();
    expect_true((f - want) < 1.0e-3 && (want - f) < 1.0e-3,
                $sformatf("%s: the PLL makes %.6f Hz, want %.6f Hz exactly", what, f, want));
  endtask

  integer w0, busy_low_at;
  real    f31, ppm;
  initial begin
    // ---- power-up: the PLL locks at its generated (31 kHz) configuration; the controller moves it
    // to the guest's 24 kHz mode ----
    expect_true(busy, "busy at power-up");
    expect_true(vclk_31, "power-up: vclk_31 names the generated 31 kHz configuration");
    repeat (20) @(posedge clk);
    pll_locked = 1'b1;
    wait_idle();
    busy_low_at = cycle;
    expect_sequence(0, "power-up");
    expect_exact(2.0 * 400.0e6 / 19.0, "power-up (24 kHz, 2 x 400/19 MHz)");
    expect_true(!vclk_31, "after power-up: vclk_31 0 (the 24 kHz configuration)");
    expect_true(busy_low_at - lock_rise_at >= SETTLE, $sformatf("busy fell %0d clocks after the relock, want >= %0d", busy_low_at - lock_rise_at, SETTLE));

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
    f31 = fout() / 2.0;
    ppm = (f31 - CAP_31K_HZ) / CAP_31K_HZ * 1.0e6;
    $display("  31 kHz: the PLL makes %.3f Hz = 2 x %.3f Hz, %.3f ppm from the capture's %.0f Hz", fout(), f31, ppm, CAP_31K_HZ);
    expect_true(ppm < 3.0 && ppm > -3.0, $sformatf("31 kHz: dot clock %.3f Hz is %.2f ppm from the capture's 25 168 031 Hz (want within 3)", f31, ppm));

    // ---- 0x09A8 bit 0 cleared: back to the 24 kHz clock ----
    w0 = n_writes;
    @(posedge clk); want_31k = 1'b0;
    repeat (5) @(posedge clk);
    expect_true(busy && !vclk_31, "busy rises and vclk_31 falls with the 24 kHz request");
    wait_idle();
    expect_sequence(w0, "24 kHz");
    expect_exact(2.0 * 400.0e6 / 19.0, "24 kHz again");

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
    expect_true(n_writes == w0, "a lock loss writes nothing");

    // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_VPLL_CTL: %0d check(s) failed", fails);
    $display("TB_PC9821_VPLL_CTL: PASS");
    $finish;
  end
endmodule
