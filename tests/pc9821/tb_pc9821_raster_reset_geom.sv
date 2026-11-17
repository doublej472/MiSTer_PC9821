`timescale 1ns / 1ps

// tb_pc9821_raster_reset_geom - a reset taken on a guest raster larger than the power-on one
// does not run the position counter away.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_RASTER_RESET_GEOM: with the reset path wired as pc9821_system wires it (reset_req through pc9821_reset_align, the three-stage synchroniser, a reset-copy stage, pc9821_raster_reseed, the real pc9821_dot_ce at 90 MHz and pc9821_crtc), a guest raster LARGER than the power-on block - a 550-line frame (the hand-built block {10 4e 47 25 07 14 e0 a1}) and an 896-dot line (defsyncm15 {10 4e 07 25 0d 0f c8 94}, x = 112) - followed by a held machine reset (the keyboard combo, two frames) and by an OSD-style one-clock reset keeps the raster position counter inside the larger of the two rasters on every clock (vline below 550 and hdot below 896), the frame in which the reset is taken on the 550-line raster is no longer than the 550-line frame, and on the guest's first clock out of every reset the counter is at 0,0 and the dot accumulator at 0 (NP2kai pccore_reset's restart), so a counter that is not re-seeded when the reset drops the geometry to the power-on block - and runs on to 1023 before it can wrap - fails here.
//
// Expected values: the geometries are NP2kai's gdc_updateclock() figures for those blocks
// (tb_pc9821_gdc_sync_raster cases 2 and 3: 848 x 550 and 896 x 400; the power-on defsyncm24 is
// 848 x 440, NP2kai io/gdc.c:42); the dot enable is 400/19 MHz from 90 MHz (pc9821_dot_ce), a dot
// every 4.275 clocks, so the 550-line frame is 848 x 550 x 4.275 = 1 993 860 clocks and the
// 896-dot frame 896 x 400 x 4.275 = 1 532 160. The power-on block's own frame is 1 595 088.
// FAIL-FIRST: before the counter is re-seeded on the reset's first clock, the reset taken on the
// 550-line frame lets vline run 550..1023 (about 38 ms with no VSYNC) and the 896-dot one lets
// hdot run 896..1023.

module tb_pc9821_raster_reset_geom;

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
  integer hmax = 0, vmax = 0;
  integer lim_h = 848, lim_v = 440;      // the larger raster of the case in progress
  // the counter stays inside the larger raster on every clock
  always @(posedge clk_sys) if (!platform) begin
    if (integer'(crtc.hdot) > hmax) hmax = integer'(crtc.hdot);
    if (integer'(crtc.vline) > vmax) vmax = integer'(crtc.vline);
    if (integer'(crtc.hdot) >= lim_h || integer'(crtc.vline) >= lim_v) begin
      if (errors < 8)
        $display("FAIL: the counter left the %0d x %0d raster: hdot %0d vline %0d @ %0t",
                 lim_h, lim_v, crtc.hdot, crtc.vline, $time);
      errors = errors + 1;
    end
  end
  // the frame the reset is taken in: VSYNC-to-VSYNC, no longer than the 550-line frame. Checked on
  // the 550-line case only: there the guest's VSYNC (line 500) is later than the power-on one (407),
  // so the frame that crosses the reset is shorter than either; defsyncm15's VSYNC rises on line
  // 215, so its crossing frame is 185 of its lines plus 407 power-on ones (about 2 184 000 clocks)
  // by geometry alone, and that case is judged by the counter bound above.
  reg frame_chk = 1'b0;
  wire vs = !vs_out;
  reg  old_vs = 0;
  longint unsigned cyc = 0, f_start = 0, f_len = 0, f_max = 0;
  integer frames = 0;
  localparam longint unsigned F550 = 1_993_860;
  always @(posedge clk_sys) begin
    cyc <= cyc + 1;
    old_vs <= vs;
    if (!old_vs && vs) begin
      frames = frames + 1;
      f_len = cyc - f_start;
      f_start = cyc;
      if (frames > 2) begin
        if (f_len > f_max) f_max = f_len;
        if (frame_chk && f_len > F550 + 10) begin
          $display("FAIL: a %0d-clock frame, longer than the 550-line frame's %0d @ %0t", f_len, F550, $time);
          errors = errors + 1;
        end
      end
    end
  end
  // the guest's first clock out of each machine reset
  reg rst_q_d = 1'b1;
  integer starts = 0;
  always @(posedge clk_sys) begin
    rst_q_d <= rst_q;
    if (rst_q_d && !rst_q && !platform) begin
      starts = starts + 1;
      if (crtc.hdot != 0 || crtc.vline != 0 || dot_ce.acc != 0) begin
        $display("FAIL: reset release %0d: counter %0d,%0d acc %0d", starts, crtc.hdot, crtc.vline, dot_ce.acc);
        errors = errors + 1;
      end
    end
  end

  // ==== STIMULUS ====
  localparam integer FRAME_CLK = 1_595_088;
  reg [7:0] sb [0:7];
  integer k, c, r;

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

  initial begin
    // the core load: platform reset, Main's reset bit while the pack loads, then the guest
    req = 1'b1;
    repeat (20) @(posedge clk_sys);
    platform = 1'b0;
    repeat (2 * FRAME_CLK + 12345) @(posedge clk_sys);
    cpu_run_ld = 1'b1;
    repeat (FRAME_CLK + 777) @(posedge clk_sys);
    req = 1'b0;
    repeat (2 * FRAME_CLK) @(posedge clk_sys);
    for (c = 0; c < 2; c = c + 1) begin
      if (c == 0) begin   // 550 lines (tb_pc9821_gdc_sync_raster case 3)
        sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h47; sb[3] = 8'h25;
        sb[4] = 8'h07; sb[5] = 8'h14; sb[6] = 8'he0; sb[7] = 8'hA1;
        lim_h = 848; lim_v = 550;
        frame_chk = 1'b1;
      end else begin      // defsyncm15, x = 112 (case 2)
        sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
        sb[4] = 8'h0d; sb[5] = 8'h0f; sb[6] = 8'hc8; sb[7] = 8'h94;
        lim_h = 896; lim_v = 440;
        frame_chk = 1'b0;
      end
      for (r = 0; r < 2; r = r + 1) begin
        // the guest programs its raster; give it three frames to land and run
        write_sync;
        repeat (3 * FRAME_CLK + 4321 * (r + 1)) @(posedge clk_sys);
        if (r == 0) begin                  // a held request (the keyboard combo)
          req = 1'b1;
          repeat (2 * FRAME_CLK + 999) @(posedge clk_sys);
          req = 1'b0;
        end else begin                     // the OSD's one-clock pulse
          req = 1'b1;
          @(posedge clk_sys);
          req = 1'b0;
        end
        repeat (3 * FRAME_CLK) @(posedge clk_sys);
      end
    end
    $display("frames=%0d longest=%0d resets=%0d hmax=%0d vmax=%0d errors=%0d", frames, f_max, starts, hmax, vmax, errors);
    // ==== VERDICT ====
    if (errors == 0 && starts == 1 + 4 && vmax == 549 && hmax == 895) begin
      $display("TB_PC9821_RASTER_RESET_GEOM: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_RASTER_RESET_GEOM: FAIL");
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_RASTER_RESET_GEOM: TIMEOUT");
  end

endmodule
