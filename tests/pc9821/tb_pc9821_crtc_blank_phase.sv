// tb_pc9821_crtc_blank_phase - GDC status bit 6 rises at the VSYNC fall, as on the Xe10.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CRTC_BLANK_PHASE: GDC status bit 6 (the per-line blank) sits where the Xe10 puts it against bit 5 (VSYNC): polled the way XE10Y /K3M polls port 0x60 (2048 reads from the VSYNC rise, decoded into runs of the two bits as xe10t_decode.py's hbl_decode does), the first poll with bit 5 clear after the VSYNC pulse already reads bit 6 set (the blank rises 0.000 of a line after the VSYNC fall), bit 6 is high 0.21-0.27 of a line, and it rises once per line, never 0.76 of a line after the fall as the blank over the dots after the active window did.

// ---- where the expectation comes from ----
//   The machine, XE10Y /K3M HBL (tools/hwprobe/xe10t/sec_kit3.inc k3_hbl: wait for bit 5 low,
//   then its rise, then 2048 `in al, dx` into a buffer, printed as `<state><polls>` runs with
//   state = bit 6 * 2 + bit 5):
//     docs/probes/XE10Y-XE10-K3M.TXT:38 `319,157,317,157,218,056` - the last VSYNC run (1) is
//       followed at once by a blank-only run (2): bit 6 rises in the poll bit 5 falls in; the
//       blank runs are 17-18 polls of a 74-75 poll line (0.23-0.24);
//     docs/probes/XE10Y-XE10-K3M.TXT:39 `313,138,212,037` - the graphics GDC (0xA0, the same
//       o_stat_blank) the same, 12-13 of 50 (0.24-0.26);
//     docs/probes/XE10Y-XE10-K3M2.TXT:38-39 and docs/probes/XE10Y-XE10-RUN3-KATA.TXT:38-39 repeat
//       both (xe10t_decode: blank high 0.24, 0.000 of a line after the VSYNC fall).
//   The duty window 0.21-0.27 spans the captures' 0.23-0.26 with a poll of quantisation.
// FAIL-FIRST: before the fix bit 6 was ~h_active (the 208 dots after the active 640), so the
// first blank rise came 0.76 of a line after the VSYNC fall
// (docs/probes/core/XE10Y-CORE-xt-3409ab24-s3-XE10-K3M.TXT:38 `318,054,217`).

`default_nettype none

module tb_pc9821_crtc_blank_phase;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg rst_n_sys = 0;

  reg        io_wr = 0;
  reg  [7:0] io_addr = 8'h60;   // the master GDC's status port
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;

  // ==== DUT ====
  pc9821_crtc dut (
      .crt31k(1'b0),      // 0x09A8 bit 0 clear: the 24 kHz range the captures ran in
      .gfx_win_on(1'b0),
      .clk_sys(clk_sys),
      .rst_n_sys(rst_n_sys),
      .rst_n_vid(rst_n_sys),
      .pixel_ce(1'b1),    // one dot per clk_sys: 848 clk_sys per default line
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout)
  );

  // One poll every POLL clk_sys: 77 polls per line, the machine's 74 (0x60) in grain.
  localparam integer POLL = 11;
  localparam integer NPOLL = 2048;

  integer errors = 0, checks = 0;
  reg [1:0] smp [0:NPOLL-1];   // {bit 6, bit 5}
  integer i, j, guard;
  integer vfall, nrises, first_rise, after_fall, last_rise, sum_per, nper;
  integer hrun, sum_hrun, nhrun;
  real period, high_frac;

  task expect_range(input [8*48-1:0] name, input integer got, input integer lo,
                    input integer hi);
    begin
      checks = checks + 1;
      if (got < lo || got > hi) begin
        $display("MISMATCH %0s: got %0d, want %0d..%0d", name, got, lo, hi);
        errors = errors + 1;
      end else $display("ok       %0s = %0d", name, got);
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    repeat (4) @(negedge clk_sys);
    rst_n_sys = 1;
    repeat (848 * 440 + 100) @(negedge clk_sys);   // one whole frame first
    // k3_hbl: bit 5 low, then its rise
    guard = 0;
    while (io_dout[5] && guard < 848 * 440) begin @(negedge clk_sys); guard = guard + 1; end
    while (!io_dout[5] && guard < 2 * 848 * 440) begin @(negedge clk_sys); guard = guard + 1; end
    for (i = 0; i < NPOLL; i = i + 1) begin
      smp[i] = {io_dout[6], io_dout[5]};
      repeat (POLL) @(negedge clk_sys);
    end

    // ==== CHECKS ==== (hbl_decode: rises of bit 6, the first bit-5 fall, the full blank runs)
    vfall = -1; nrises = 0; first_rise = -1; after_fall = -1; last_rise = -1;
    sum_per = 0; nper = 0; hrun = 0; sum_hrun = 0; nhrun = 0;
    for (i = 1; i < NPOLL; i = i + 1) begin
      if (smp[i - 1][0] && !smp[i][0] && vfall < 0) vfall = i;
      if (smp[i][1] && !smp[i - 1][1]) begin
        nrises = nrises + 1;
        if (last_rise >= 0) begin sum_per = sum_per + (i - last_rise); nper = nper + 1; end
        last_rise = i;
        if (vfall >= 0 && after_fall < 0) after_fall = i;
        hrun = 1;
      end else if (smp[i][1] && hrun > 0) hrun = hrun + 1;
      if (!smp[i][1] && smp[i - 1][1] && hrun > 0) begin
        sum_hrun = sum_hrun + hrun; nhrun = nhrun + 1; hrun = 0;
      end
    end
    period = (nper > 0) ? (sum_per * 1.0) / nper : 0.0;
    high_frac = (nhrun > 0 && period > 0.0) ? ((sum_hrun * 1.0) / nhrun) / period : 0.0;
    $display("polls %0d: VSYNC fall at poll %0d, first blank rise after it %0d, %0d rises, line %0f polls, blank high %0f of a line",
             NPOLL, vfall, after_fall, nrises, period, high_frac);
    expect_range("a VSYNC fall inside the polls", (vfall > 0) ? 1 : 0, 1, 1);
    // phase 0.000 after the VSYNC fall: the blank rises in the poll VSYNC falls in
    expect_range("blank rise - VSYNC fall (polls)", after_fall - vfall, 0, 0);
    // one rise per line: 2048 polls of a 77-poll line
    expect_range("bit-6 rises", nrises, 25, 27);
    expect_range("blank high x1000 of a line", $rtoi(high_frac * 1000.0), 210, 270);

    $display("  %0d checks", checks);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CRTC_BLANK_PHASE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CRTC_BLANK_PHASE: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_CRTC_BLANK_PHASE: TIMEOUT");
  end

endmodule

`default_nettype wire
