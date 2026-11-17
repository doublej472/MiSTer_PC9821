`timescale 1ns / 1ps

// tb_pc9821_raster_run_fall - a second pack download (cpu_run falling) lets the frame in progress
// finish on the guest's geometry.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_RASTER_RUN_FALL: with the raster wired as pc9821_system wires it (pc9821_raster_reseed, the real pc9821_dot_ce at 90 MHz and pc9821_crtc, the CRTC's configuration held by `reset || !cpu_run_crtc`), a guest raster other than the power-on one - a 550-line frame (the block {10 4e 47 25 07 14 e0 a1}) and an 896-dot line (defsyncm15, x = 112) - followed by cpu_run falling mid-frame (a second pack download), at a line below the power-on block's 440 and at one above it, completes the frame in progress with the guest's geometry (its frame end lands on the guest's last dot, 549/847 or 399/895, one guest frame after the previous frame end to within 5 clocks) and the next frame uses the power-on geometry (its frame end on 439/847, one power-on frame of 1 595 088 clocks later to within 10), the counter never leaving the guest raster; so dropping the geometry where cpu_run falls - which cuts the frame below line 440 and runs the counter on to 1023 above it - fails here, and so does a re-seed at the fall itself.
//
// Expected values: the owner's decision for cpu_run's fall (no re-seed mid-frame; the new geometry
// takes effect at the next frame end); the geometries are NP2kai's gdc_updateclock() figures for the
// blocks (tb_pc9821_gdc_sync_raster cases 2 and 3: 848 x 550 and 896 x 400; defsyncm24 848 x 440,
// NP2kai io/gdc.c:42), with a dot every 4.275 clocks (400/19 MHz from 90 MHz): frames of 1 993 860,
// 1 532 160 and 1 595 088 clocks.
// FAIL-FIRST: with the CRTC's reset on cpu_run itself and no re-seed at its fall (the tree before
// this change, tests/pc9821/mutations.json), the fall at line 100 of the 550-line frame ends it at
// line 439 and the fall at line 500 runs vline to 1023.

module tb_pc9821_raster_run_fall;

  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;

  // ==== THE RESET PATH (z486_mister.sv + pc9821_system.sv, as tb_pc9821_raster_hold) ====
  reg  req = 1'b0;
  reg  platform = 1'b1;
  wire wrap, go, waiting;
  reg [2:0] sync_r = 3'b111;
  pc9821_reset_align #(.TIMEOUT(4_000_000)) align (.clk(clk_sys), .req(req), .wrap(wrap), .active(sync_r[1]), .go(go), .waiting(waiting));
  always @(posedge clk_sys or posedge platform)
    if (platform) sync_r <= 3'b111;
    else          sync_r <= go ? 3'b111 : {sync_r[1:0], 1'b0};
  wire reset = sync_r[2];
  reg  rst_q = 1'b1;
  always @(posedge clk_sys) rst_q <= reset;

  reg  cpu_run_ld = 1'b0;
  wire cpu_run, cpu_run_crtc, reseed_cnt, reseed_dot;
  pc9821_raster_reseed reseed (
    .clk(clk_sys), .reset(reset), .rst_q(rst_q), .cpu_run_ld(cpu_run_ld), .frame_end(wrap),
    .cpu_run(cpu_run), .cpu_run_crtc(cpu_run_crtc), .reseed_cnt(reseed_cnt), .reseed_dot(reseed_dot)
  );
  wire pixel_ce;
  pc9821_dot_ce #(.SYS_FREQ(90_000_000)) dot_ce (.clk(clk_sys), .reset(reseed_dot), .c31(1'b0), .ce(pixel_ce));

  // ==== DUT ====
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 8'h60, io_din = 0;
  wire [7:0] io_dout;
  wire hs_out, vs_out, de_out;
  pc9821_crtc crtc (
    .clk_sys(clk_sys), .rst_n_sys(!(rst_q || !cpu_run_crtc)), .rst_n_vid(!reseed_cnt), .pixel_ce(pixel_ce),
    .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
    .o_frame_end(wrap), .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  // ==== CHECKS ====
  integer errors = 0;
  reg cpu_run_ld_seen = 1'b0;   // the counter bound is checked once the guest runs
  integer lim_h = 848, lim_v = 550;
  always @(posedge clk_sys) if (!platform && cpu_run_ld_seen) begin
    if (integer'(crtc.hdot) >= lim_h || integer'(crtc.vline) >= lim_v) begin
      if (errors < 8)
        $display("FAIL: the counter left the %0d x %0d raster: hdot %0d vline %0d @ %0t",
                 lim_h, lim_v, crtc.hdot, crtc.vline, $time);
      errors = errors + 1;
    end
  end
  // every frame end's first clock: where the counter stands and how long since the last one
  reg wrap_q = 1'b0;
  longint unsigned cyc = 0, fe_at = 0, fe_len = 0;
  integer fe_v = 0, fe_h = 0, fe_n = 0;
  always @(posedge clk_sys) begin
    cyc <= cyc + 1;
    wrap_q <= wrap;
    if (wrap && !wrap_q) begin
      fe_len = cyc - fe_at;
      fe_at = cyc;
      fe_v = integer'(crtc.vline);
      fe_h = integer'(crtc.hdot);
      fe_n = fe_n + 1;
    end
  end

  // ==== STIMULUS ====
  localparam integer FRAME_CLK = 1_595_088;
  reg [7:0] sb [0:7];
  integer k, c, n0;
  integer want_v, want_h, fall_line;
  longint unsigned want_len;

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1'b1;
      @(negedge clk_sys);
      io_wr = 1'b0;
    end
  endtask

  task automatic write_sync;
    begin
      write_io(8'h62, 8'h0F);
      for (k = 0; k < 8; k = k + 1) write_io(8'h60, sb[k]);
    end
  endtask

  task automatic near(input longint unsigned got, input longint unsigned want, input integer tol, input string what);
    begin
      if (got + tol < want || got > want + tol) begin
        $display("FAIL: %s: %0d clocks, want %0d +- %0d", what, got, want, tol);
        errors = errors + 1;
      end
    end
  endtask

  // one case: program the block, let it run, drop cpu_run on `fall_line`, check the two frame ends
  task automatic run_case(input string name);
    begin
      write_sync;
      repeat (3 * FRAME_CLK) @(posedge clk_sys);
      // the fall: on fall_line of the guest frame
      @(posedge clk_sys);
      while (!(integer'(crtc.vline) == fall_line && integer'(crtc.hdot) == 300)) @(posedge clk_sys);
      n0 = fe_n;
      cpu_run_ld = 1'b0;
      // the frame in progress ends on the guest's last dot
      while (fe_n == n0) @(posedge clk_sys);
      if (fe_v != want_v || fe_h != want_h) begin
        $display("FAIL: %s: the frame cpu_run fell in ended on %0d/%0d, want the guest's %0d/%0d", name, fe_v, fe_h, want_v, want_h);
        errors = errors + 1;
      end
      near(fe_len, want_len, 5, {name, ": the frame cpu_run fell in"});
      // the next one is the power-on frame
      while (fe_n == n0 + 1) @(posedge clk_sys);
      if (fe_v != 439 || fe_h != 847) begin
        $display("FAIL: %s: the frame after the fall ended on %0d/%0d, want the power-on 439/847", name, fe_v, fe_h);
        errors = errors + 1;
      end
      near(fe_len, 1_595_088, 10, {name, ": the frame after the fall"});
      lim_h = 848; lim_v = 440;
      // the second pack lands; cpu_run rises at a frame end
      repeat (FRAME_CLK / 3) @(posedge clk_sys);
      cpu_run_ld = 1'b1;
      repeat (2 * FRAME_CLK) @(posedge clk_sys);
    end
  endtask

  initial begin
    req = 1'b1;
    repeat (20) @(posedge clk_sys);
    platform = 1'b0;
    repeat (FRAME_CLK + 12345) @(posedge clk_sys);
    cpu_run_ld = 1'b1;
    repeat (FRAME_CLK + 777) @(posedge clk_sys);
    req = 1'b0;
    repeat (2 * FRAME_CLK) @(posedge clk_sys);
    cpu_run_ld_seen = 1'b1;
    for (c = 0; c < 3; c = c + 1) begin
      if (c < 2) begin   // 550 lines (tb_pc9821_gdc_sync_raster case 3)
        sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h47; sb[3] = 8'h25;
        sb[4] = 8'h07; sb[5] = 8'h14; sb[6] = 8'he0; sb[7] = 8'hA1;
        want_v = 549; want_h = 847; want_len = 1_993_860;
        fall_line = (c == 0) ? 100 : 500;
      end else begin     // defsyncm15, x = 112 (case 2)
        sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
        sb[4] = 8'h0d; sb[5] = 8'h0f; sb[6] = 8'hc8; sb[7] = 8'h94;
        want_v = 399; want_h = 895; want_len = 1_532_160;
        fall_line = 200;
      end
      lim_h = (c < 2) ? 848 : 896; lim_v = (c < 2) ? 550 : 440;
      run_case($sformatf("case %0d (fall on line %0d)", c, fall_line));
    end
    $display("errors=%0d frame_ends=%0d", errors, fe_n);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_RASTER_RUN_FALL: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_RASTER_RUN_FALL: FAIL");
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_RASTER_RUN_FALL: TIMEOUT");
  end

endmodule
