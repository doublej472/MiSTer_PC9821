`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The burst of 0x09A8 bit 0 toggles the ITF makes at every POST leaves the video PLL alone and a held change is still followed, at pc9821_vpll_ctl's shipped STABLE of 75 000 clocks of the 50 MHz reference (1.5 ms): settled in the 24 kHz configuration, the burst as the card measured it at Full speed (256 edges in 210 us, ending at 0) and the slowest one it measured (256 edges in 17.3 ms whose longest run at 1 is 1242 us, CPU Speed 0.5 MHz with Xe10 I/O timing) make no reconfiguration write, never raise busy (so pc9821_video_out never flushes its FIFO for them) and never move vclk_31 (the framework's new_vmode); a burst whose runs at 1 are each STABLE - 64 clocks long is swallowed too; a value held STABLE + 64 clocks is followed - written (N, M, K, start) STABLE clocks after the change, give or take the synchroniser, busy rising with that write - and so is the change back, each switch complete (busy low again) within STABLE + its writes + the relock + SETTLE. FAIL-FIRST: the controller before the stability window reconfigures on a burst's first edge, so busy rises and the writes happen; one whose window does not restart at each edge follows a burst whose runs add up past STABLE.
//
// THE REASON: on the machine 0x09A8 bit 0 selects one of two dot-clock oscillators (docs/probes/
// CRT31K.TXT), so a toggle has nothing to relock; the core's video clock is one PLL that must be
// re-programmed and relocked, and a relock flushes the picture. The register map and the PLL model
// are tb_pc9821_vpll_ctl's. The burst shapes are the card's (pc9821_vpll_ctl's STABLE comment).

module tb_pc9821_vpll_burst;
  localparam integer SETTLE   = 64;
  localparam integer LOCK_GAP = 200;
  localparam integer STABLE   = 75_000;    // the shipped default, restated: 1.5 ms of 50 MHz
  reg clk = 0;
  always #10 clk = ~clk;

  reg  want_31k = 1'b0;
  reg  pll_locked = 1'b0;
  wire waitreq, mgmt_write, vclk_31, busy;
  wire [5:0]  mgmt_address;
  wire [31:0] mgmt_writedata;

  // ==== DUT ====
  pc9821_vpll_ctl #(.SETTLE(SETTLE)) dut (
    .clk(clk), .want_31k(want_31k), .pll_locked(pll_locked),
    .mgmt_waitrequest(waitreq),
    .mgmt_write(mgmt_write), .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
    .pll_rst(), .vclk_31(vclk_31), .busy(busy)
  );

  // the reconfiguration core and PLL (tb_pc9821_vpll_ctl's model)
  integer n_writes = 0, wcnt = 0, gap = 0, n_starts = 0;
  assign waitreq = mgmt_write && (wcnt < 3);
  always @(posedge clk) begin
    if (mgmt_write) begin
      if (wcnt < 3) wcnt <= wcnt + 1;
      else begin
        n_writes <= n_writes + 1;
        wcnt <= 0;
        if (mgmt_address == 6'd2) begin pll_locked <= 1'b0; gap <= LOCK_GAP; n_starts <= n_starts + 1; end
      end
    end
    if (gap > 0) begin
      gap <= gap - 1;
      if (gap == 1) pll_locked <= 1'b1;
    end
  end

  // ==== CHECKS ====
  integer errors = 0, busy_rises = 0, v31_moves = 0, cyc = 0;
  reg busy_q = 1'b1, v31_q = 1'b1;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    busy_q <= busy;
    v31_q  <= vclk_31;
    if (busy && !busy_q) busy_rises <= busy_rises + 1;
    if (vclk_31 != v31_q) v31_moves <= v31_moves + 1;
  end
  task automatic expect_true(input bit c, input string what);
    if (!c) begin errors = errors + 1; $display("FAIL: %s", what); end
  endtask

  integer i, w0, b0, m0, t_change, t_write;
  initial begin
    // power-up: lock comes at the generated 24 kHz configuration and the controller settles
    #1000 pll_locked = 1'b1;
    wait (!busy);
    repeat (1000) @(posedge clk);
    w0 = n_writes; b0 = busy_rises; m0 = v31_moves;
    // ---- the burst at Full speed: 256 edges in 210 us, ending at 0 ----
    for (i = 0; i < 256; i = i + 1) begin
      want_31k = ~want_31k;
      repeat (41) @(posedge clk);
    end
    if (want_31k) begin want_31k = 1'b0; repeat (100) @(posedge clk); end
    repeat (2 * STABLE) @(posedge clk);
    // ---- the slowest burst measured: 255 short runs (bits) then the 1242 us last run at 1 ----
    for (i = 0; i < 255; i = i + 1) begin
      want_31k = ~want_31k;
      repeat (3000) @(posedge clk);          // 60 us: a bit's runs at 0.5 MHz
    end
    if (!want_31k) want_31k = 1'b1;
    repeat (62_100) @(posedge clk);          // 1242 us at 1: the run before the final write
    want_31k = 1'b0;
    repeat (2 * STABLE) @(posedge clk);
    // ---- runs at 1 of STABLE - 64 clocks, separated by 1 us at 0 ----
    for (i = 0; i < 8; i = i + 1) begin
      want_31k = 1'b1; repeat (STABLE - 64) @(posedge clk);
      want_31k = 1'b0; repeat (50) @(posedge clk);
    end
    repeat (2 * STABLE) @(posedge clk);
    expect_true(n_writes == w0, $sformatf("the bursts made %0d reconfiguration writes, want 0", n_writes - w0));
    expect_true(busy_rises == b0, $sformatf("busy rose %0d times in the bursts, want 0", busy_rises - b0));
    expect_true(v31_moves == m0, $sformatf("vclk_31 moved %0d times in the bursts, want 0", v31_moves - m0));
    expect_true(!busy && !vclk_31, "after the bursts: settled at 24 kHz");
    // ---- a hold just over the window: STABLE + 64 clocks, then back - followed ----
    @(posedge clk); want_31k = 1'b1; t_change = cyc;
    repeat (STABLE + 64) @(posedge clk);
    want_31k = 1'b0;
    expect_true(n_writes > w0, "a value held STABLE + 64 clocks was not followed");
    wait (!busy && !mgmt_write);
    repeat (2 * STABLE + 20_000) @(posedge clk);
    expect_true(!busy && !vclk_31, "after the short hold and its return: back at 24 kHz");
    w0 = n_writes;
    // ---- a change that holds: followed after STABLE clocks ----
    @(posedge clk); want_31k = 1'b1; t_change = cyc;
    wait (mgmt_write); t_write = cyc;
    expect_true(t_write - t_change >= STABLE, $sformatf("the held change was written %0d clocks after it, want >= %0d", t_write - t_change, STABLE));
    expect_true(t_write - t_change <= STABLE + 8, $sformatf("the held change was written %0d clocks after it, want <= %0d", t_write - t_change, STABLE + 8));
    expect_true(busy && vclk_31, "busy and vclk_31 move with the first write");
    wait (!busy);
    expect_true(cyc - t_change <= STABLE + 64 + LOCK_GAP + SETTLE + 64,
                $sformatf("the switch completed %0d clocks after the change, want <= STABLE + writes + relock + SETTLE", cyc - t_change));
    expect_true(n_starts == 3, $sformatf("%0d starts by the 31 kHz switch, want 3 (the short hold and its return, the switch; none at power-up)", n_starts));
    // ---- and back ----
    @(posedge clk); want_31k = 1'b0; t_change = cyc;
    wait (mgmt_write); t_write = cyc;
    expect_true(t_write - t_change >= STABLE, "the change back waits STABLE clocks too");
    wait (!busy);
    expect_true(!vclk_31 && n_starts == 4, "settled back at 24 kHz after one more start");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_VPLL_BURST: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_VPLL_BURST: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_VPLL_BURST: TIMEOUT");
  end
endmodule
