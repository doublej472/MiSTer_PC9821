// tb_pc9821_pit_latch_pair - a counter-latch command freezes BOTH bytes of the count.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_LATCH_PAIR: a counter-latch command on an LSB+MSB channel freezes the WHOLE 16-bit count, not just the byte read first: with the channel counting down through 0x0102 and the latch issued there, the low byte read ~600 clk_sys later still comes from the latched value (0x00..0x05, not the live ~0xDD) and the high byte read another ~600 clk_sys later is the latched 0x01 although the live counter's high byte has fallen to 0x00 by then, so a second byte served from the running counter (a high byte that disagrees with the low byte it pairs with) fails here.

// ---- where the expectation comes from ----
//   8254 datasheet (Intel 231164), "Counter Latch Command": the count is latched into the
//     output latch "until it is read by the CPU (or until the counter is reprogrammed)"; a
//     two-byte count is read as the latched low byte then the latched high byte.
//   NP2kai io/pit.c latchcmd(): stores the count once and the following
//     reads of the pair serve that stored word (RL=3: low byte, then high byte).
//   The programmed count (0x0105) and the delay are chosen so the live high byte (0x01 at
//   the latch) is 0x00 by the time the second byte is read; the expected bytes are therefore
//   fixed by the latch semantics alone, independent of the counter's exact tick phase.
// FAIL-FIRST: a model that serves the second byte of a latched pair from the live counter
// returns 0x00 for the high byte here (mutant: drop read_latch_2nd from the read mux).

module tb_pc9821_pit_latch_pair;

  reg clk = 0;
  always #10 clk = ~clk;   // 50 MHz
  reg rst_n = 0;
  reg cs = 0, wr = 0, rd = 0;
  reg  [1:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire out0, out1, out2;

  // ==== DUT ====
  pc9821_pit #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .out0(out0), .out1(out1), .out2(out2)
  );

  integer errors = 0;
  reg [7:0] lo, hi;

  // ==== STIMULUS ====
  task write_pit(input [1:0] port, input [7:0] value);
    begin
      @(negedge clk);
      addr = port; din = value; cs = 1; wr = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0; wr = 0;
    end
  endtask

  task read_pit(input [1:0] port, output [7:0] value);
    begin
      @(negedge clk);
      addr = port; cs = 1; rd = 1;
      #1 value = dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0; rd = 0;
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    write_pit(2'd3, 8'hB0);           // ch2, LSB+MSB, mode 0
    write_pit(2'd2, 8'h05);
    write_pit(2'd2, 8'h01);           // count 0x0105
    repeat (70) @(posedge clk);       // ~3 PIT clocks: the count is about 0x0102
    write_pit(2'd3, 8'h80);           // counter latch, ch2
    repeat (600) @(posedge clk);      // ~29 PIT clocks: the live count is about 0x00E5
    read_pit(2'd2, lo);
    repeat (600) @(posedge clk);
    read_pit(2'd2, hi);
    $display("latched pair: lo=%02x hi=%02x", lo, hi);
    if (lo > 8'h05) begin
      $display("MISMATCH latched low byte %02x is not the count at the latch (<= 0x05)", lo);
      errors = errors + 1;
    end
    if (hi !== 8'h01) begin
      $display("MISMATCH latched high byte %02x, want 01 (served from the live counter?)", hi);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PIT_LATCH_PAIR: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_LATCH_PAIR: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PIT_LATCH_PAIR: TIMEOUT");
  end

endmodule

`default_nettype wire
