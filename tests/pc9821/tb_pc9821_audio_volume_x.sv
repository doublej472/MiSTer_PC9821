// tb_pc9821_audio_volume_x - the mixer's channel sequencer must never X-lock.
//
// ==== WHAT THIS PROVES ====
// The 10-channel master mix's channel sequencer never X-locks: `ch`, `gain`, `sample`, `samples_out` and `valid` are seeded, so in 4-state simulation the self-fed counter resolves instead of poisoning the whole audio path with X forever (the same self-fed shape as crtc's stat_dr, hidden by Verilator's 2-state zero-init; run under iverilog for the fail-first X-lock), valid pulses exactly once per NUM_CH clks, and NUM_CH unity-gain constant channels assemble into samples_out with channel 0 at bits [15:0] in channel order.
//
// The 10-channel volume attenuator's channel counter `ch` is a self-fed
// register (ch <= (ch == CH_LAST) ? 0 : ch + 1) on CLK_AUDIO with no reset and
// no power-up value. In 4-state simulation `ch` = X makes the comparison, the
// ternary and the increment all X, so the register NEVER resolves and the
// 10-channel master mix (`samples_out`) and its `valid` strobe are X-poisoned
// forever. This is the same self-fed shape as
// pc9821_crtc's `stat_dr`; Verilator's 2-state zero-init hides it, which is
// what this bench's $isunknown checks are for - run it under a 4-state
// simulator (iverilog) to see the fail-first X-lock.
//
// With `ch` seeded the sequencer must: run one channel per clk, mark `valid`
// once per NUM_CH clks, and assemble NUM_CH back-to-back unity-gain products
// into `samples_out` channel 0 at bits [15:0] .. channel 9 at bits [159:144].
//
// ==== THE 4-STATE RUN ====
// tools/bench.py --all runs Verilator, which is 2-STATE and zero-initialised: it reads an
// unseeded `ch` as 0, so the X-lock above is NOT part of what the gate proves. The claim's
// backing run is `python3 tools/check_4state_xlock.py audio_volume_x` - iverilog, a real
// 4-state simulator, run by hand outside the build path (tools/check_wiring.py's
// no-iverilog-in-the-build-path rule stands). Its `--selftest` ablates each seed this
// bench's checks reach and REQUIRES the run to FAIL: `ch`'s `= 4'd0`, and the
// out_q/valid initial block (the captured fields read X until first captured). Both are caught.

`timescale 1ns / 1ps

module tb_pc9821_audio_volume_x;

  localparam integer NUM_CH = 10;
  localparam integer SAMPLE_WIDTH = 16;

  reg clk = 0;
  always #5 clk = ~clk;

  reg  [NUM_CH*5-1:0]          volumes_in;
  reg  [NUM_CH*SAMPLE_WIDTH-1:0] samples_in;
  wire [NUM_CH*SAMPLE_WIDTH-1:0] samples_out;
  wire                          valid;

  // ==== DUT ====
  pc9821_audio_volume #(
      .NUM_CH(NUM_CH), .SAMPLE_WIDTH(SAMPLE_WIDTH)
  ) dut (
      .clk(clk),
      .volumes_in(volumes_in),
      .samples_in(samples_in),
      .samples_out(samples_out),
      .valid(valid)
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
  integer valids;
  integer gap;
  integer last_valid;

  initial begin
    // Distinct constant per channel, volume 31 = unity (0dB, the 0x10000 path).
    for (i = 0; i < NUM_CH; i = i + 1) begin
      volumes_in[i*5 +: 5] = 5'd31;
      samples_in[i*SAMPLE_WIDTH +: SAMPLE_WIDTH] = 16'h0100 * (i + 1);
    end

    // ==== 4-STATE X-CHECK ====
    // Nothing about this module may be unknown at any time - it has no inputs
    // that can be unknown here, so ANY X is the self-fed lock.
    for (i = 0; i < 4 * NUM_CH; i = i + 1) begin
      @(negedge clk);
      if ($isunknown(samples_out) || $isunknown(valid) || $isunknown(dut.ch) ||
          $isunknown(dut.gain) || $isunknown(dut.sample)) begin
        fail("X in the mixer state (ch/gain/sample/samples_out/valid): the sequencer never resolves");
        i = 4 * NUM_CH;   // one report is enough
      end
    end

    // ==== valid cadence: one pulse per NUM_CH clks ====
    valids = 0;
    last_valid = -1;
    for (i = 0; i < 4 * NUM_CH; i = i + 1) begin
      @(negedge clk);
      if (valid) begin
        if (last_valid >= 0) begin
          gap = i - last_valid;
          if (gap != NUM_CH) begin
            $display("FAIL: valid pulses %0d clks apart, want %0d", gap, NUM_CH);
            errors = errors + 1;
          end
        end
        last_valid = i;
        valids = valids + 1;
      end
    end
    if (valids < 3) begin
      $display("FAIL: valid pulsed %0d times in %0d clks, want >= 3", valids, 4 * NUM_CH);
      errors = errors + 1;
    end
    // The FRAME the consumer latches on valid: channel 0 at bits [15:0] and channel k at
    // [16k +: 16], every channel its own unity-gain product. The next-epochs check below
    // proves the capture order, so a valid that pulses one channel late (a frame
    // rotated by one slot) is caught by this one.
    begin : frame_at_valid
      integer k;
      @(negedge clk);
      while (!valid) @(negedge clk);
      for (k = 0; k < NUM_CH; k = k + 1)
        if (samples_out[k*SAMPLE_WIDTH +: SAMPLE_WIDTH] !== 16'h0100 * (k + 1)) begin
          $display("FAIL: at valid, channel %0d's slot holds %04x, want %04x", k,
                   samples_out[k*SAMPLE_WIDTH +: SAMPLE_WIDTH], 16'h0100 * (k + 1));
          errors = errors + 1;
        end
    end

    // ==== the assembled mix on the next epochs ====
    // samples_out is meaningful on `valid` (each field is captured once per epoch and held), so
    // the rotation check is the FRAME at each of the next three valids, in channel order: a
    // channel captured an epoch late or into the wrong field shows as a wrong constant here.
    begin : next_epochs
      integer k, e;
      for (e = 0; e < 3; e = e + 1) begin
        @(negedge clk);
        while (valid) @(negedge clk);
        while (!valid) @(negedge clk);
        for (k = 0; k < NUM_CH; k = k + 1)
          if (samples_out[k*SAMPLE_WIDTH +: SAMPLE_WIDTH] !== 16'h0100 * (k + 1)) begin
            $display("FAIL: epoch %0d at valid, channel %0d's slot holds %04x, want %04x", e, k,
                     samples_out[k*SAMPLE_WIDTH +: SAMPLE_WIDTH], 16'h0100 * (k + 1));
            errors = errors + 1;
          end
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_VOLUME_X: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_AUDIO_VOLUME_X: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_AUDIO_VOLUME_X: TIMEOUT");
  end

endmodule
