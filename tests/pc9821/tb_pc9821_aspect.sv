`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ASPECT: the OSD "Aspect ratio" field reaches video_freak as the NEC monitor's shape: with pc9821_aspect fed the picture video_freak receives, "Original" (option 0) gives ARX:ARY 16:10 for a 640x400 picture (the 24 kHz 848 x 440 raster and the 31 kHz 800 x 449 one), for a 200-line picture and for the analog doubler's 640x800 copy of the 400-line one, and 4:3 for a 640x480 picture (NEC display sheets: PC-KD854 d077 640x400 表示面積 240*150; PC-KD1522 d059 400 lines 260*163, 480 lines 260*195; PC-KD871 d087 200/400 lines 240*150 - square dots in every mode), including a 480-line frame whose last line ends on the very pixel enable VS rises on; the shape moves only within two clocks of a VS rising edge, and one frame cut short (a relock flush) does not flip it; options 1-3 stay 3:0, 1:0 and 2:0 in both modes; and through the framework's own video_freak (1920x1080 HDMI) Scale 0 passes 16:10 / 4:3 through, while V-Integer and Narrower HV-Integer give 1280x800 for 400 lines and 1280x960 for 480 lines, the exact 2x of square dots. FAIL-FIRST: with option 0 fixed at 4:3 (the previous wiring) the 400-line checks fail, and Narrower HV-Integer gives 640x800 instead of 1280x800.
//
// THE EXPECTED VALUES are the NEC sheets' areas (16:10 = 240/150 = 1.6, 4:3 = 260/195) and the
// arithmetic of square dots (640x400 doubled is 1280x800), never read out of the DUT. The option
// 1-3 values are the framework's encodings z486_mister.sv documents (3:0 full screen, ARX 1/2 with
// ARY 0 the ARC1/ARC2 slots sys_top substitutes).
//
// WHAT IT IS BLIND TO: sys_top's ARC1/ARC2 substitution and the ascal scaler itself (the bench stops
// at video_freak's VIDEO_ARX/ARY), and how the real cleaner/gamma chain delays the syncs (the
// raster here is already in the active-high form video_freak takes).

module tb_pc9821_aspect;
  reg clk = 1'b0;
  always #10 clk = ~clk;
  reg ce = 1'b0;
  always @(posedge clk) ce <= ~ce;

  // ---- the raster: switched at a frame boundary, syncs active high (the cleaner's form) ----
  reg [11:0] HT = 12'd848, HA = 12'd640, VT = 12'd440, VA = 12'd400, VFP = 12'd7, VSW = 12'd8;
  reg [11:0] nHT = 12'd848, nVT = 12'd440, nVA = 12'd400, nVFP = 12'd7, nVSW = 12'd8;
  reg        coinc = 1'b0, ncoinc = 1'b0;   // VS rises on the last active line's DE fall
  reg        cut = 1'b0, ncut = 1'b0;       // this frame shows only its first 100 lines (a flush)
  reg        dbl = 1'b0;
  reg [11:0] hx = '0, vy = '0;
  always @(posedge clk) if (ce) begin
    if (hx == HT - 1) begin
      hx <= '0;
      if (vy == VT - 1) begin
        vy <= '0;
        HT <= nHT; VT <= nVT; VA <= nVA; VFP <= nVFP; VSW <= nVSW; coinc <= ncoinc; cut <= ncut;
      end else vy <= vy + 1'd1;
    end else hx <= hx + 1'd1;
  end
  wire de = (hx < HA) && (vy < VA) && !(cut && vy >= 12'd100);
  wire vs = coinc ? (((vy == VA - 1) && (hx >= HA)) || ((vy >= VA) && (vy < VA + VSW)))
                  : ((vy >= VA + VFP) && (vy < VA + VFP + VSW));

  // ==== DUT ====
  // pc9821_aspect, and the framework's video_freak as z486_mister.sv wires it.
  reg  [2:0]  ar = 3'd0;
  reg  [2:0]  scale = 3'd0;
  wire [11:0] arx, ary;
  pc9821_aspect dut (.clk(clk), .ce(ce), .vs(vs), .de(de), .dbl(dbl), .ar(ar), .arx(arx), .ary(ary));
  wire [12:0] varx, vary;
  /* verilator lint_off PINCONNECTEMPTY */
  video_freak vf (
    .CLK_VIDEO(clk), .CE_PIXEL(ce), .VGA_VS(vs), .HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080),
    .VGA_DE(), .VIDEO_ARX(varx), .VIDEO_ARY(vary), .VGA_DE_IN(de), .ARX(arx), .ARY(ary),
    .CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE(scale)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  initial begin
    #(2.0e9);
    $fatal(1, "TB_PC9821_ASPECT: watchdog (2 s simulated)");
  end

  // ==== CHECKS ====
  integer errors = 0;
  task automatic check(input bit ok, input string what);
    if (!ok) begin $display("FAIL: %0s", what); errors++; end
    else $display("  ok   %0s", what);
  endtask

  // ---- the frame-boundary monitor: with ar steady, ARX/ARY move only within 2 clocks of VS rising ----
  reg        vs_q = 1'b0;
  integer    since_vs = 1000, since_ar = 1000;
  reg [11:0] arx_q = 12'd0, ary_q = 12'd0;
  reg [2:0]  ar_q = 3'd0;
  integer    midframe = 0;
  integer    age = 0;          // the first clocks compare against the monitor's own power-up value
  always @(posedge clk) begin
    if (ce) vs_q <= vs;
    since_vs <= (ce && vs && !vs_q) ? 0 : since_vs + 1;
    since_ar <= (ar != ar_q) ? 0 : since_ar + 1;
    ar_q  <= ar;
    arx_q <= arx;
    ary_q <= ary;
    age   <= age + 1;
    if ((arx != arx_q || ary != ary_q) && age > 2 && since_ar > 3 && since_vs > 2) begin
      midframe++;
      $display("FAIL: ARX:ARY moved to %0d:%0d %0d clocks after VS rose", arx, ary, since_vs);
    end
  end

  // ---- around the cut frame, the 480-line shape must hold on every clock ----
  reg     watch43 = 1'b0;
  integer flips43 = 0;
  always @(posedge clk) if (watch43 && !(arx == 12'd4 && ary == 12'd3)) flips43++;

  task automatic frames(input integer n);
    integer i;
    for (i = 0; i < n; i++) begin
      @(posedge clk iff (ce && vs && !vs_q));
    end
    @(posedge clk);
  endtask
  task automatic mode(input [11:0] ht, input [11:0] vt, input [11:0] va, input [11:0] vfp,
                      input [11:0] vsw, input bit c, input bit d);
    nHT = ht; nVT = vt; nVA = va; nVFP = vfp; nVSW = vsw; ncoinc = c; dbl = d;
    frames(4);
  endtask
  task automatic options(input string m, input [11:0] x0, input [11:0] y0);
    integer k;
    ar = 3'd0;
    repeat (4) @(posedge clk);
    check(arx == x0 && ary == y0, $sformatf("%0s: Original gives %0d:%0d (want %0d:%0d)", m, arx, ary, x0, y0));
    for (k = 1; k <= 3; k++) begin
      ar = 3'(k);
      repeat (4) @(posedge clk);
      check(arx == ((k == 1) ? 12'd3 : 12'(k - 1)) && ary == 12'd0,
            $sformatf("%0s: option %0d gives %0d:%0d (want %0d:0)", m, k, arx, ary, (k == 1) ? 3 : k - 1));
    end
    ar = 3'd0;
    repeat (4) @(posedge clk);
  endtask
  task automatic freak(input string m, input [2:0] s, input [12:0] wx, input [12:0] wy);
    scale = s;
    frames(2);
    check(varx == wx && vary == wy,
          $sformatf("%0s: video_freak Scale %0d gives %0d:%0d%0s (want %0d:%0d%0s)", m, s,
                    varx[11:0], vary[11:0], varx[12] ? " (integer)" : "",
                    wx[11:0], wy[11:0], wx[12] ? " (integer)" : ""));
    scale = 3'd0;
  endtask

  initial begin
    // ---- 640x400 at 24 kHz (848 x 440; NP2kai bios/bios18.c gdcmastersync[1]) ----
    frames(4);
    options("640x400 24 kHz", 12'd16, 12'd10);
    freak("640x400 24 kHz", 3'd0, 13'd16, 13'd10);
    freak("640x400 24 kHz", 3'd1, {1'b1, 12'd1280}, {1'b1, 12'd800});
    freak("640x400 24 kHz", 3'd2, {1'b1, 12'd1280}, {1'b1, 12'd800});

    // ---- 640x480 at 31 kHz (800 x 525) ----
    mode(12'd800, 12'd525, 12'd480, 12'd10, 12'd2, 1'b0, 1'b0);
    options("640x480", 12'd4, 12'd3);
    freak("640x480", 3'd0, 13'd4, 13'd3);
    freak("640x480", 3'd1, {1'b1, 12'd1280}, {1'b1, 12'd960});
    freak("640x480", 3'd2, {1'b1, 12'd1280}, {1'b1, 12'd960});

    // ---- one frame cut short in the 480-line mode: the shape holds ----
    watch43 = 1'b1;
    ncut = 1'b1;
    frames(1);
    ncut = 1'b0;
    frames(3);
    watch43 = 1'b0;
    check(flips43 == 0, $sformatf("640x480 around a cut frame: left 4:3 on %0d clock(s)", flips43));

    // ---- 640x480 whose last line ends on the pixel enable VS rises on ----
    mode(12'd800, 12'd525, 12'd480, 12'd0, 12'd2, 1'b1, 1'b0);
    check(arx == 12'd4 && ary == 12'd3, $sformatf("640x480, coincident VS: %0d:%0d (want 4:3)", arx, ary));

    // ---- 640x400 at 31 kHz (800 x 449; gdcmastersync[2]) ----
    mode(12'd800, 12'd449, 12'd400, 12'd13, 12'd2, 1'b0, 1'b0);
    options("640x400 31 kHz", 12'd16, 12'd10);

    // ---- 640x200 ----
    mode(12'd848, 12'd220, 12'd200, 12'd4, 12'd4, 1'b0, 1'b0);
    options("640x200", 12'd16, 12'd10);

    // ---- the analog doubler's 640x800 copy of the 400-line picture ----
    mode(12'd848, 12'd880, 12'd800, 12'd14, 12'd6, 1'b0, 1'b1);
    options("640x400 doubled (640x800)", 12'd16, 12'd10);

    // ---- and back to 480 lines ----
    mode(12'd800, 12'd525, 12'd480, 12'd10, 12'd2, 1'b0, 1'b0);
    check(arx == 12'd4 && ary == 12'd3, $sformatf("640x480 again: %0d:%0d (want 4:3)", arx, ary));

    check(midframe == 0, $sformatf("ARX:ARY moved away from a frame boundary %0d time(s)", midframe));

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_ASPECT: %0d check(s) failed", errors);
    $display("TB_PC9821_ASPECT: PASS");
    $finish;
  end
endmodule
