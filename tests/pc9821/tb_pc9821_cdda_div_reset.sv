// tb_pc9821_cdda_div_reset - the CDDA ring's CLK_AUDIO divider must resolve.
//
// ==== WHAT THIS PROVES ====
// The CDDA block's CLK_AUDIO domain resolves out of reset: the 44.1 kHz divider accumulator, the clk_44100 toggle, the resample flops and the ring pointers are seeded, so the divider does not X-lock in 4-state simulation (run under iverilog for the fail-first X-lock), AUDIO_CE pulses at the divided rate, AUDIO_L/R are never X, and one word written through CDDA_WR comes out of AUDIO_L/R at the full-volume setting.
//
// The CDDA block's 44.1 kHz divider and ring pointers power up unseeded.
// In 4-state simulation `clk_44100_cnt <= clk_44100_cnt
// + 88200` from X stays X forever, the wrap comparison is X, and AUDIO_CE /
// AUDIO_L / AUDIO_R never resolve: the only path that drains the CDDA ring is
// X-locked and `read_addr`/`write_addr` X makes `buffer_q <= buffer[read_addr]`
// an X read of an unseeded array. Verilator's 2-state zero-init hides it, which
// is what this bench's $isunknown checks are for - run it under a 4-state
// simulator (iverilog) to see the fail-first X-lock.
//
// With the divider, the resample flops and the ring pointers seeded, the bench
// requires: no unknown state, AUDIO_CE pulsing at the divided rate, and one
// CDDA word written through CDDA_WR coming out of AUDIO_L/AUDIO_R at the full
// volume setting (>>> ~0xF = no shift).
//
// ==== THE 4-STATE RUN ====
// tools/bench.py --all runs Verilator, which is 2-STATE and zero-initialised, so the
// divider/ring X-lock above is NOT part of what the gate proves. The backing run is
// `python3 tools/check_4state_xlock.py cdda_div_reset` (iverilog, 4-state, by hand,
// outside the build path). Its `--selftest` ablates each seed this bench's checks reach
// and REQUIRES the run to FAIL: the divider's (clk_44100/clk_44100_cnt), the ring
// pointers' (read_addr/write_addr) and the resample flops' (audio_l/audio_r) are all
// caught. The ring ARRAY's own seed is not individually observable here - with the
// pointers seeded, buffer_q always reloads an address that has been written.

`timescale 1ns / 1ps

module tb_pc9821_cdda_div_reset;

  // 4 CLK_AUDIO ticks per clk_44100 half-period (88200*4), so the bench sees
  // AUDIO_CE within a few dozen ticks instead of a real 24.576 MHz's ~279.
  localparam CLK_AUDIO_RATE = 88200 * 4;

  reg CLK = 0;
  reg CLK_AUDIO = 0;
  always #5  CLK = ~CLK;
  always #10 CLK_AUDIO = ~CLK_AUDIO;

  reg         CDDA_WR = 0;
  reg  [31:0] CDDA_DATA = 0;
  wire        CDDA_REQ;
  wire        AUDIO_CE;
  wire [15:0] AUDIO_L, AUDIO_R;

  // ==== DUT ====
  cdda #(.CLK_AUDIO_RATE(CLK_AUDIO_RATE)) dut (
      .CLK(CLK),
      .CDDA_REQ(CDDA_REQ),
      .CDDA_REQ4(),
      .CDDA_PLAYED(),
      .CDDA_FLUSH(1'b0),
      .CDDA_WR(CDDA_WR),
      .CDDA_DATA(CDDA_DATA),
      .VOLUME_L(4'hF),      // ~0xF = 0: full volume, no shift
      .VOLUME_R(4'hF),
      .CLK_AUDIO(CLK_AUDIO),
      .AUDIO_CE(AUDIO_CE),
      .AUDIO_L(AUDIO_L),
      .AUDIO_R(AUDIO_R)
  );

  integer errors = 0;

  // ==== CHECKS ====
  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  integer i;
  integer pulses;

  initial begin
    // ==== 4-STATE X-CHECK ====
    // After two CLK_AUDIO edges the divider accumulator must be resolved and
    // AUDIO_L/R must never be unknown (they hold 0 until the first sample).
    repeat (2) @(posedge CLK_AUDIO);
    @(negedge CLK);
    if ($isunknown(dut.clk_44100_cnt) || $isunknown(dut.clk_44100)) begin
      fail("X in the 44.1 kHz divider: clk_44100_cnt/clk_44100 never resolve");
    end
    if ($isunknown(AUDIO_CE) || $isunknown(AUDIO_L) || $isunknown(AUDIO_R)) begin
      fail("X in the CLK_AUDIO outputs: AUDIO_CE/AUDIO_L/AUDIO_R never resolve");
    end

    // ==== AUDIO_CE must pulse at the divided rate ====
    pulses = 0;
    for (i = 0; i < 200; i = i + 1) begin
      @(posedge CLK_AUDIO);
      @(negedge CLK);
      if ($isunknown(AUDIO_CE) || $isunknown(AUDIO_L) || $isunknown(AUDIO_R)) begin
        fail("X in the CLK_AUDIO outputs while running");
        i = 200;
      end
      if (AUDIO_CE) pulses = pulses + 1;
    end
    if (pulses == 0) begin
      fail("AUDIO_CE never pulsed: the 44.1 kHz strobe is dead");
    end
    // ...and at the DIVIDED RATE, not merely alive: CD-DA is 44 100 frames/s (Red Book), so
    // 200 CLK_AUDIO ticks at this bench's CLK_AUDIO_RATE carry 200 * 44100 / 352800 = 25
    // AUDIO_CE pulses (+-1 for the window's two ends). Only `pulses == 0` was checked, so a
    // divider stepping for 48 kHz (27 pulses) passed.
    else if (pulses < 24 || pulses > 26) begin
      $display("FAIL: AUDIO_CE pulsed %0d times in 200 CLK_AUDIO ticks, want 25 +-1 (44.1 kHz)", pulses);
      errors = errors + 1;
    end

    // ==== one CDDA word round-trips through the ring ====
    @(negedge CLK);
    CDDA_DATA = 32'h1234_5678;   // [31:16]=audio_r, [15:0]=audio_l
    CDDA_WR = 1;
    @(negedge CLK);
    CDDA_WR = 0;
    pulses = 0;
    for (i = 0; i < 200 && pulses == 0; i = i + 1) begin
      @(negedge CLK);
      if (AUDIO_CE && AUDIO_L === 16'h5678 && AUDIO_R === 16'h1234) pulses = 1;
    end
    if (pulses == 0) begin
      $display("FAIL: written CDDA word 5678/1234 never reached AUDIO_L/R (got %04x/%04x)",
               AUDIO_L, AUDIO_R);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CDDA_DIV_RESET: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_CDDA_DIV_RESET: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_CDDA_DIV_RESET: TIMEOUT");
  end

endmodule
