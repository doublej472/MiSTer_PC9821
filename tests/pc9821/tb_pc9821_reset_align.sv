`timescale 1ns / 1ps

// tb_pc9821_reset_align — a machine reset of an unchanged mode is not a mode change to the framework.
//
// ==== WHAT THIS PROVES ====
// With the machine reset's REQUEST path wired as the top wires it (reset_req through pc9821_reset_align into the three-stage synchroniser and a reset-copy stage), driving a held-counter stand-in for the raster (the CRTC counter and a fractional 90 MHz : 21.05 MHz dot enable held by that reset - the pre-reseed wiring, NOT pc9821_system's, which runs the counter through the reset and re-seeds it with pc9821_raster_reseed: tb_pc9821_raster_hold and tb_pc9821_raster_reset_geom cover the shipped path) and the CRTC on its defsyncm24 raster, 48 reset requests - one-cycle pulses like the OSD Reset and held requests like the keyboard combo - landing anywhere in the frame are each taken within one frame, on the frame's last dot, and leave every frame the framework's resolution detector closes (sys/hps_io.sv video_calc: the first DE line's width and the DE lines outside VSYNC, a frame closed at the end of VSYNC) at 640 x 400, so its 15-frame report never fires, and every frame a one-cycle request closes as long as a frame without one to within a dot plus the hold (sys/pll_hdmi_adj.vhd steers the low-latency HDMI PLL from each frame's length); a request taken anywhere else in the frame (today's immediate reset) cuts a frame and fails here.
//
// Expected values: the defsyncm24 block {10 4e 07 25 07 07 90 65} (NP2kai io/gdc.c:42) is 640
// active dots in an 848-dot line and 400 active lines in a 440-line frame with an 8-line VSYNC
// pulse rising on line 407 (tb_pc9821_crtc_norom_raster); the detector's frame rule is
// sys/hps_io.sv:972-998 (`if(~vs & ~old_de & de) vcnt <= vcnt + 1;`, `if(calch & de) hcnt <= hcnt + 1;`,
// `if(old_de & ~de) calch <= 0;`, the compare at `if(old_vs & ~vs)`).

module tb_pc9821_reset_align;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;

  // ==== THE RESET PATH (z486_mister.sv's, with the platform reset already released) ====
  reg  req = 1'b0;
  wire wrap, go;
  reg [2:0] sync_r = 3'b111;   // the top's reset synchroniser
  pc9821_reset_align #(.TIMEOUT(2_000_000)) align (.clk(clk_sys), .req(req), .wrap(wrap), .active(sync_r[1]), .go(go), .waiting());
  always @(posedge clk_sys) sync_r <= go ? 3'b111 : {sync_r[1:0], 1'b0};
  reg rst = 1'b1;                        // the block's copy (pc9821_reset_tree: one register)
  always @(posedge clk_sys) rst <= sync_r[2];
  // The dot enable as pc9821_dot_ce makes it: an accumulator held at 0 by the machine reset (no dots
  // while it is held), 400/19 MHz from 90 MHz otherwise (19 x 90 : 400 = 1710 : 400, a dot every
  // 4.275 clocks).
  reg  [11:0] acc = 12'd0;
  wire [11:0] sum = acc + 12'd400;
  wire pixel_ce = !rst && (sum >= 12'd1710);
  always @(posedge clk_sys) acc <= rst ? 12'd0 : (pixel_ce ? sum - 12'd1710 : sum);

  // ==== DUT ====
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 8'h60, io_din = 0;
  wire [7:0] io_dout;
  wire hs_out, vs_out, de_out;
  pc9821_crtc crtc (
      .clk_sys(clk_sys), .rst_n_sys(!rst), .rst_n_vid(!rst), .pixel_ce(pixel_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .o_frame_end(wrap), .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  // ==== CHECKS ====
  // THE FRAMEWORK'S DETECTOR (video_calc's ce_pix block, syncs made active high) ====
  wire vs = !vs_out;
  reg  old_vs = 0, old_de = 0, calch = 0;
  integer hcnt = 0, vcnt = 0, frames = 0, bad = 0, p_h = -1, p_v = -1, resto = 0, nres = 0;
  // the frame's length in clk_sys, and whether a one-cycle request was taken inside it
  longint unsigned f_start = 0, f_len = 0, f_nom = 0, cyc = 0;
  integer long_bad = 0;
  reg pulse_in_frame = 1'b0, held_in_frame = 1'b0;
  always @(posedge clk_sys) cyc <= cyc + 1;
  always @(posedge clk_sys) if (pixel_ce) begin
    old_vs <= vs;
    old_de <= de_out;
    if (!vs && !old_de && de_out) vcnt = vcnt + 1;
    if (calch && de_out) hcnt = hcnt + 1;
    if (old_de && !de_out) calch <= 1'b0;
    if (old_vs && !vs) begin
      frames = frames + 1;
      if (frames > 2 && (hcnt != 640 || vcnt != 400)) begin
        bad = bad + 1;
        $display("FRAME %0d differs: %0d x %0d", frames, hcnt, vcnt);
      end
      f_len = cyc - f_start;
      f_start = cyc;
      if (frames == 3) f_nom = f_len;
      // a frame without a reset varies by the dot enable's phase (under a dot); one with the
      // OSD-style pulse may be longer by the hold (4 clocks) and shorter by the last dot it cut
      if (frames > 3 && !held_in_frame &&
          (f_len + 10 < f_nom || f_len > f_nom + 10)) begin
        long_bad = long_bad + 1;
        $display("FRAME %0d length %0d, a frame is %0d (pulse=%0d)", frames, f_len, f_nom, pulse_in_frame);
      end
      pulse_in_frame = 1'b0;
      held_in_frame = 1'b0;
      if (hcnt != 0 && vcnt != 0) begin
        if (resto != 0) resto = resto + 1;
        if (hcnt != p_h || vcnt != p_v) resto = 1;
        if (resto == 15) begin nres = nres + 1; resto = 0; end
        p_h = hcnt; p_v = vcnt;
      end
      hcnt = 0; vcnt = 0;
      calch <= 1'b1;
    end
  end

  // WHERE EACH RESET LANDS
  reg rst_q = 1'b1;
  integer taken = 0, off_wrap = 0;
  always @(posedge clk_sys) begin
    rst_q <= rst;
    if (rst && !rst_q) begin
      taken = taken + 1;
      if (cur_held) held_in_frame = 1'b1; else pulse_in_frame = 1'b1;
      if (!wrap_at_go) begin
        off_wrap = off_wrap + 1;
        $display("RESET %0d asserted off the frame's last dot", taken);
      end
    end
  end
  // the raster position the synchroniser saw when it was set (go's first cycle)
  reg go_q = 1'b0, wrap_at_go = 1'b0;
  always @(posedge clk_sys) begin
    go_q <= go;
    if (go && !go_q) wrap_at_go <= wrap;
  end

  // ==== STIMULUS ====
  localparam integer FRAME_CLK = 848 * 440 * 4275 / 1000;
  integer i, k, wait_clk, waited, errors = 0;
  integer seed = 32'h5eed_0001;
  reg cur_held = 1'b0;
  initial begin
    repeat (3 * FRAME_CLK) @(posedge clk_sys);
    for (i = 0; i < 48; i = i + 1) begin
      wait_clk = 1000 + ($urandom(seed) % FRAME_CLK);
      seed = seed + 1;
      repeat (wait_clk) @(posedge clk_sys);
      k = taken;
      cur_held = (i % 3 == 2);
      req <= 1'b1;
      if (i % 3 == 2) repeat (20_000 + (i * 997) % 30_000) @(posedge clk_sys);   // a held request
      else @(posedge clk_sys);                                                    // the OSD pulse
      req <= 1'b0;
      waited = 0;
      while (taken == k && waited < 2 * FRAME_CLK) begin @(posedge clk_sys); waited = waited + 1; end
      if (taken == k) begin
        errors = errors + 1;
        $display("REQUEST %0d was never taken", i);
      end
      repeat (2 * FRAME_CLK) @(posedge clk_sys);
    end
    repeat (20 * FRAME_CLK) @(posedge clk_sys);
    $display("requests=48 taken=%0d off_wrap=%0d frames=%0d differing=%0d mislength=%0d reports=%0d",
             taken, off_wrap, frames, bad, long_bad, nres);
    if (taken != 48) errors = errors + 1;
    if (off_wrap != 0) errors = errors + 1;
    if (bad != 0) errors = errors + 1;
    if (long_bad != 0) errors = errors + 1;
    if (nres != 1) errors = errors + 1;   // the one report of the first stable mode
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_RESET_ALIGN: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_RESET_ALIGN: FAIL (%0d errors)", errors);
  end

endmodule
