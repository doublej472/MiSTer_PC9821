`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// pc9821_video_cleaner is output-identical to the framework's video_cleaner as z486_mister.sv wires it (HBlank/VBlank/interlace/f1 tied 0): VGA_R/G/B, VGA_HS, VGA_VS and DE_out match on every clock for sync waveforms of either polarity whose active pulse is shorter than the saturation bound (CLOCK_RATE_HZ/16 clocks), with arbitrarily long inactive phases, stuck syncs and ce_pix gaps, and a planted waveform whose two phases both exceed the bound does separate them.
//
// ---- the oracle is the framework's own module ----
// sys/video_cleaner.sv is instantiated beside the copy on one stimulus. The bench runs the copy at
// CLOCK_RATE_HZ = 65536, i.e. a saturation bound of 4096 clocks, so phases far beyond the bound fit
// in a short run: the logic is the same parameterised module the core builds at 50..120 MHz, where
// the bound is 62.5 ms. The legal classes are the ones the GDC can produce - a short active pulse,
// an inactive phase of any length - in both polarities, plus syncs held still for a long time
// (pos/neg are sampled only at edges, so a stuck sync must not move either module), with random
// RGB/DE and a ce_pix that drops out. The PLANTED class (+PLANT_BOTH_LONG) makes both phases
// longer than the bound - the one case the header of pc9821_video_cleaner.sv says separates them -
// and the bench must then report mismatches (it fails, which is the point of the plant; the
// mutation plan, tests/pc9821/mutations.json, runs it).

module tb_pc9821_video_cleaner_equiv;
  reg clk = 0;
  always #5 clk = ~clk;

  localparam integer RATE = 65536;              // SAT_CYCLES = RATE/16 = 4096
  localparam integer SAT  = RATE / 16;

  reg        ce_pix = 0;
  reg  [7:0] r = 0, g = 0, b = 0;
  reg        hsync = 0, vsync = 0, de = 0;

  // ==== DUT ====
  wire [7:0] ur, ug, ub, cr, cg, cb;
  wire       uhs, uvs, ude, chs, cvs, cde;

  /* verilator lint_off PINCONNECTEMPTY */
  video_cleaner upstream (
    .clk_vid(clk), .ce_pix(ce_pix), .R(r), .G(g), .B(b), .HSync(hsync), .VSync(vsync),
    .HBlank(1'b0), .VBlank(1'b0), .DE_in(de), .interlace(1'b0), .f1(1'b0),
    .VGA_R(ur), .VGA_G(ug), .VGA_B(ub), .VGA_VS(uvs), .VGA_HS(uhs), .VGA_DE(),
    .HBlank_out(), .VBlank_out(), .DE_out(ude));
  /* verilator lint_on PINCONNECTEMPTY */
  pc9821_video_cleaner #(.CLOCK_RATE_HZ(RATE)) copy (
    .clk_vid(clk), .ce_pix(ce_pix), .R(r), .G(g), .B(b), .HSync(hsync), .VSync(vsync),
    .DE_in(de), .VGA_R(cr), .VGA_G(cg), .VGA_B(cb), .VGA_VS(cvs), .VGA_HS(chs), .DE_out(cde));

  // ==== STIMULUS ====
  int unsigned seed = 32'hC1EA_0001;
  function automatic int unsigned rnd();
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    return seed;
  endfunction

  // Each sync is its own process: an active pulse, then an inactive phase, in a polarity.
  bit plant;
  int mism = 0, checked = 0, hs_edges = 0, vs_edges = 0;
  // One polarity per sync for the whole run, as the core's are (z486_mister.sv feeds the GDC's
  // fixed-polarity HSYNC/VSYNC); the two syncs take the two polarities so both are covered.
  bit hs_pol = 0, vs_pol = 1;

  task automatic phase_len(output int act, output int inact);
    case (rnd() % 8)
      0, 1, 2: begin act = 1 + rnd() % 64;   inact = 50 + rnd() % 900; end      // line-scale
      3, 4:    begin act = 1 + rnd() % (SAT - 1); inact = SAT + rnd() % (4 * SAT); end // long inactive
      5:       begin act = SAT - 2 + rnd() % 2; inact = 1 + rnd() % (6 * SAT); end   // the bound's edge
      6:       begin act = 1 + rnd() % 200; inact = 1 + rnd() % 200; end           // ~square
      default: begin act = 1 + rnd() % 16;  inact = 8 * SAT + rnd() % (2 * SAT); end // stuck a long time
    endcase
    if (plant) begin act = SAT + 16 + rnd() % SAT; inact = SAT + 16 + rnd() % SAT; end
  endtask

  initial begin : hs_proc
    int a, i;
    forever begin
      phase_len(a, i);
      hsync = hs_pol;  repeat (a) @(posedge clk);
      hsync = ~hs_pol; repeat (i) @(posedge clk);
      hs_edges++;
    end
  end
  initial begin : vs_proc
    int a, i;
    forever begin
      phase_len(a, i);
      vsync = vs_pol;  repeat (a) @(posedge clk);
      vsync = ~vs_pol; repeat (i) @(posedge clk);
      vs_edges++;
    end
  end
  always @(posedge clk) begin
    ce_pix <= (rnd() % 5) != 0;
    r <= 8'(rnd()); g <= 8'(rnd()); b <= 8'(rnd()); de <= rnd() % 2;
  end

  // ==== CHECKS ====
  int cycles = 0;
  always @(negedge clk) begin
    cycles++;
    if (cycles > 8) begin
      checked++;
      if ({ur, ug, ub, uhs, uvs, ude} !== {cr, cg, cb, chs, cvs, cde}) begin
        mism++;
        if (mism <= 5)
          $display("MISMATCH cycle %0d: upstream rgb %h%h%h hs %b vs %b de %b / copy rgb %h%h%h hs %b vs %b de %b",
                   cycles, ur, ug, ub, uhs, uvs, ude, cr, cg, cb, chs, cvs, cde);
      end
    end
  end

  // ==== VERDICT ====
  initial begin
    plant = $test$plusargs("PLANT_BOTH_LONG");
    repeat (3_000_000) @(posedge clk);
    $display("video_cleaner_equiv: %0d clocks compared, %0d HSYNC and %0d VSYNC periods, %0d mismatches%s",
             checked, hs_edges, vs_edges, mism, plant ? " (PLANTED: both phases past the bound)" : "");
    if (mism == 0 && hs_edges > 100 && vs_edges > 100) begin
      $display("TB_PC9821_VIDEO_CLEANER_EQUIV: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_VIDEO_CLEANER_EQUIV: FAIL (%0d mismatches)", mism);
  end
endmodule
