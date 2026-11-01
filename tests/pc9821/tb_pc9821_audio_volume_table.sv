// tb_pc9821_audio_volume_table — the 32-entry gain table, read from its ROM, is bit-exact.
//
// ==== WHAT THIS PROVES ====
// The 32-entry volume gain table, read from its 32x17 M10K ROM (the true-zero table moved from a LUT-selected packed vector into a synchronous ROM), produces the exact documented 17-bit gain for every one of the 32 volume codes 0..31 - code 0 = 17'h00000 (true mute), code 31 = 17'h10000 (unity), the -60 dB..-2 dB ladder bit-identical to the packed vector it replaced - and the guarded wire drives the DSP multiply: at unity a 0x4000 sample passes through unchanged and at code 0 it contributes exactly zero.
//
// The table is read through the real pc9821_audio_volume with every channel driven
// to the SAME code, so volumes_in's active 5-bit slice IS the volume code: each code
// is presented and the guarded `gain` wire is checked against the documented 17-bit
// value (the ROM init must reproduce the packed-vector table bit-for-bit, including
// the two endpoints the LUT form handled specially - code 0's true mute and code 31's
// 0x10000 unity - so a LUT->ROM rewrite that mis-indexes, swaps nibbles or drops the
// unity special case fails here by name). Two output-path checks pin that the wire
// actually drives the DSP multiply: unity passes a 0x4000 sample through unchanged and
// mute contributes exactly zero (the same endpoints tb_pc9821_audio_mix pins through
// the full mixer).
//
// ==== THE 4-STATE RUN ====
// tools/bench.py --all runs Verilator (2-state); the X-lock fail-first for the
// sequencer's self-fed seeds is tb_pc9821_audio_volume_x's 4-state run
// (tools/check_4state_xlock.py). This bench is about the table's VALUES, which
// are the same in both engines.
`timescale 1ns / 1ps

module tb_pc9821_audio_volume_table;

  localparam integer NUM_CH = 2;        // smallest valid channel count (the shift register needs NUM_CH >= 2)
  localparam integer SAMPLE_WIDTH = 16;

  reg clk = 0;
  always #5 clk = ~clk;

  reg  [NUM_CH*5-1:0]            volumes_in;
  reg  [NUM_CH*SAMPLE_WIDTH-1:0] samples_in;
  wire [NUM_CH*SAMPLE_WIDTH-1:0] samples_out;
  wire                           valid;

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

  // ==== CHECKS ====
  integer errors = 0;

  task fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The documented gain table, indexed by volume code (0..31), in 17 bits. These are
  // the historical values the module's packed vector carried: code 0 is true mute,
  // code 31 is unity, and 1..30 are -60 dB..-2 dB in 2 dB steps (2^(-dB/20) in Q16,
  // rounded). Kept as literals here so a LUT->ROM rewrite that changes a value is caught.
  function [16:0] expected_gain(input [4:0] code);
    case (code)
      5'd0:  expected_gain = 17'h00000;  // mute (code 0 = exact zero)
      5'd1:  expected_gain = 17'h00042;  // -60 dB
      5'd2:  expected_gain = 17'h00053;  // -58 dB
      5'd3:  expected_gain = 17'h00068;  // -56 dB
      5'd4:  expected_gain = 17'h00083;  // -54 dB
      5'd5:  expected_gain = 17'h000A5;  // -52 dB
      5'd6:  expected_gain = 17'h000CF;  // -50 dB
      5'd7:  expected_gain = 17'h00105;  // -48 dB
      5'd8:  expected_gain = 17'h00148;  // -46 dB
      5'd9:  expected_gain = 17'h0019E;  // -44 dB
      5'd10: expected_gain = 17'h00209;  // -42 dB
      5'd11: expected_gain = 17'h0028F;  // -40 dB
      5'd12: expected_gain = 17'h00339;  // -38 dB
      5'd13: expected_gain = 17'h0040F;  // -36 dB
      5'd14: expected_gain = 17'h0051C;  // -34 dB
      5'd15: expected_gain = 17'h0066E;  // -32 dB
      5'd16: expected_gain = 17'h00818;  // -30 dB
      5'd17: expected_gain = 17'h00A31;  // -28 dB
      5'd18: expected_gain = 17'h00CD5;  // -26 dB
      5'd19: expected_gain = 17'h01027;  // -24 dB
      5'd20: expected_gain = 17'h01456;  // -22 dB
      5'd21: expected_gain = 17'h0199A;  // -20 dB
      5'd22: expected_gain = 17'h0203A;  // -18 dB
      5'd23: expected_gain = 17'h02893;  // -16 dB
      5'd24: expected_gain = 17'h03314;  // -14 dB
      5'd25: expected_gain = 17'h0404E;  // -12 dB
      5'd26: expected_gain = 17'h050F4;  // -10 dB
      5'd27: expected_gain = 17'h065EA;  //  -8 dB
      5'd28: expected_gain = 17'h0804E;  //  -6 dB
      5'd29: expected_gain = 17'h0A186;  //  -4 dB
      5'd30: expected_gain = 17'h0CB59;  //  -2 dB
      5'd31: expected_gain = 17'h10000;  //   0 dB (unity)
      default: expected_gain = 17'h00000;   // unreachable (code is always 0..31)
    endcase
  endfunction

  integer i;

  // Present code on every channel, then check the guarded gain wire once the ROM read
  // has landed. volumes_in is written on a negedge (stable before the posedge that
  // latches the ROM address), the posedge registers the read, and the following negedge
  // checks `gain` (which equals `gain_q` once gain_valid is asserted).
  task automatic chk_code(input [4:0] code);
    reg [16:0] want;
    integer c;
    begin
      @(negedge clk);
      for (c = 0; c < NUM_CH; c = c + 1)
        volumes_in[c*5 +: 5] = code;
      @(posedge clk);
      @(negedge clk);
      want = expected_gain(code);
      if (dut.gain !== want) begin
        $display("FAIL: gain for code %0d = %05x, expected %05x", code, dut.gain, want);
        errors = errors + 1;
      end
    end
  endtask

  // Output-path check: every channel gets the same code and sample, so after the shift
  // register fills, every 16-bit slot carries the same product. The oldest slot is
  // samples_out[SAMPLE_WIDTH-1:0].
  task automatic chk_out(input [4:0] code, input [15:0] want);
    integer c;
    begin
      @(negedge clk);
      for (c = 0; c < NUM_CH; c = c + 1) begin
        volumes_in[c*5 +: 5] = code;
        samples_in[c*SAMPLE_WIDTH +: SAMPLE_WIDTH] = 16'h4000;
      end
      repeat (2 * NUM_CH + 2) @(posedge clk);
      @(negedge clk);
      if (samples_out[SAMPLE_WIDTH-1:0] !== want) begin
        $display("FAIL: samples_out for code %0d = %04x, expected %04x",
                 code, samples_out[SAMPLE_WIDTH-1:0], want);
        errors = errors + 1;
      end
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    integer c;
    volumes_in = '0;
    for (c = 0; c < NUM_CH; c = c + 1)
      samples_in[c*SAMPLE_WIDTH +: SAMPLE_WIDTH] = 16'h4000;   // unity passes it through

    // Settle the guarded read (gain_valid asserts on the first edge) before the loop.
    repeat (3) @(posedge clk);

    // Every one of the 32 entries, bit-exact.
    for (i = 0; i < 32; i = i + 1) begin
      chk_code(i[4:0]);
    end

    // The guarded wire really drives the DSP multiply: unity passes the sample, mute zeroes it.
    chk_out(5'd31, 16'h4000);
    chk_out(5'd0,  16'h0000);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_VOLUME_TABLE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_VOLUME_TABLE: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_AUDIO_VOLUME_TABLE: TIMEOUT");
  end

endmodule
