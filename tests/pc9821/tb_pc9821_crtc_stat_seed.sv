// tb_pc9821_crtc_stat_seed - the GDC status byte's resample flops at reset.
//
// ==== WHAT THIS PROVES ====
// The GDC status byte's resample family comes up at its reset state: the first two port-0x60 status reads after a reset return the reset raster's BLANK (bit 6) / NO-VSYNC (bit 5) values with bit 2 set and bit 0 a RESOLVED free-running toggle - stat_dr <= ~stat_dr is the same self-fed X-lock shape as audio_volume's channel counter and was X forever in 4-state sim - and the steady-state byte never goes X (run under iverilog for the fail-first X-lock).
//
// The vsync/blank/data-ready resample flops (`vs_sync_ff`, `de_ff`, `stat_dr`)
// come up at their RESET state - 00/00 - so the first two GDC status reads
// (port 0x60) after a reset return the reset raster's BLANK / NO-VSYNC values
// with bit 0 a resolved free-running toggle, instead of X (the rest of the
// stat_dr family). `stat_dr <= ~stat_dr` is the same self-fed
// X-lock shape as pc9821_audio_volume's channel counter: unseeded it is X
// forever in 4-state simulation and bit 0 of every status read is garbage. The
// ITF polls this port early, which is why the first reads must be defined.
//
// Status byte (pc9821_crtc.sv's read mux, port_code 5'd0):
//   {1'b0, ~de_ff[1], vs_sync_ff[1], 2'b00, 1'b1, 1'b0, stat_dr}
// so bit 6 = blank, bit 5 = vsync, bit 2 = 1 (constant), bit 0 = the toggle.
//
// ==== THE 4-STATE RUN ====
// tools/bench.py --all runs Verilator, which is 2-STATE and zero-initialised, so the
// self-fed-toggle half of the claim above is NOT part of what the gate proves. The backing
// run is `python3 tools/check_4state_xlock.py crtc_stat_seed` (iverilog, 4-state, by
// hand, outside the build path); its `--selftest` drops stat_dr's `= 1'b0` and REQUIRES the
// run to FAIL ("stat_dr (status bit 0) is X: the self-fed toggle never resolves in
// 4-state"). The resample flops' half needs no 4-state and is already in the gate:
// resetting vs_sync_ff/de_ff to 2'b11 instead of 2'b00 fails the bit-6/bit-5 checks.

`timescale 1ns / 1ps

module tb_pc9821_crtc_stat_seed;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg rst_n_sys = 0;

  reg        io_wr = 0;
  reg  [7:0] io_addr = 8'h60;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;

  // ==== DUT ====
  // The scanout side is idle; only the CPU-side port read matters here.
  pc9821_crtc dut (
      .crt31k(1'b0),   // 0x09A8 bit 0 clear: the 24 kHz monitor range
      .gfx_win_on(1'b0),   // no slave window here
      .clk_sys(clk_sys),
      .rst_n_sys(rst_n_sys),
      .rst_n_vid(rst_n_sys),
      .pixel_ce(1'b1),
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout)
  );

  integer errors = 0;
  reg [7:0] first_byte, second_byte;

  // ==== CHECKS ====
  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  integer i;

  initial begin
    repeat (4) @(negedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1;             // release
    #1;

    // ==== THE FIRST TWO READS AFTER RESET ====
    // The flops hold their reset state 00/00 through the first read and track
    // the raster two clks later, so the first two reads are BLANK (bit 6 = 1,
    // ~de_ff[1] with de_ff = 0) / NO-VSYNC (bit 5 = 0) with bit 2 set and bit 0
    // RESOLVED (the free-running toggle's seed).
    first_byte = io_dout;
    @(negedge clk_sys);
    second_byte = io_dout;
    if ($isunknown(first_byte) || $isunknown(second_byte)) begin
      $display("FAIL: the first status reads after reset are X: %02x %02x", first_byte, second_byte);
      errors = errors + 1;
    end
    if (first_byte[6] !== 1'b1 || first_byte[5] !== 1'b0 || first_byte[2] !== 1'b1) begin
      $display("FAIL: first status read %02x want bit6 blank / bit5 no-vsync / bit2 set", first_byte);
      errors = errors + 1;
    end
    if (second_byte[6] !== 1'b1 || second_byte[5] !== 1'b0 || second_byte[2] !== 1'b1) begin
      $display("FAIL: second status read %02x want bit6 blank / bit5 no-vsync / bit2 set", second_byte);
      errors = errors + 1;
    end

    // ==== bit 0 is the FREE-RUNNING toggle: resolved and actually toggling ====
    begin : toggle_watch
      reg prev;
      reg saw_toggle;
      prev = io_dout[0];
      saw_toggle = 0;
      for (i = 0; i < 4; i = i + 1) begin
        @(negedge clk_sys);
        if ($isunknown(io_dout[0])) begin
          fail("stat_dr (status bit 0) is X: the self-fed toggle never resolves in 4-state");
          i = 4;
        end
        if (io_dout[0] !== prev) saw_toggle = 1;
        prev = io_dout[0];
      end
      if (!saw_toggle) fail("status bit 0 did not toggle over 4 clks: the free-running toggle is stuck");
    end

    // ==== the steady-state byte has no X either ====
    for (i = 0; i < 8; i = i + 1) begin
      @(negedge clk_sys);
      if ($isunknown(io_dout)) begin
        fail("status byte went X while running");
        i = 8;
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CRTC_STAT_SEED: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_CRTC_STAT_SEED: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_CRTC_STAT_SEED: TIMEOUT");
  end

endmodule
