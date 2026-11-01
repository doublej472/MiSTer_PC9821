// tb_pc9821_pit_oneshot - PIT modes 1, 4 and 5 are one-shots, and the status byte keeps the mode.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_ONESHOT: PIT modes 1, 4 and 5 are ONE-SHOTS that raise exactly one OUT rising edge (one IRQ0) per count write and never oscillate: after the control word OUT is HIGH in modes 1/4/5 (only mode 0 starts low), a mode-4/5 count makes one OUT low strobe of one PIT clock about N clocks after the write and then OUT stays high while the counter wraps, and a mode-1 count (software-triggered here, as NP2kai counts it) takes OUT low and back high once at terminal count; the read-back status byte returns the control word's bits 5:0 as written (mode 6 stays 6, the BCD bit is kept), not a normalised mode. The read-back status byte's RW field (bits 5:4) is the written control word's own for the single-byte formats too (RL=1 reads 0x14 for control 0x14, RL=2 reads 0x28 for control 0x68), not a fixed LSB+MSB (NP2kai pit_setflag).

// ---- where the expectation comes from ----
//   8254 datasheet (Intel 231164), "Mode 4: Software Triggered Strobe": "OUT will be
//     initially high. When the initial count expires, OUT will go low for one CLK pulse and
//     then go high again"; "After writing a Control Word and initial count ... the counter
//     will wrap around ... and continue counting" with no reload. "After the Control Word is
//     written, OUT is high" for modes 1, 4 and 5; only Mode 0 sets OUT low on the control word.
//   NP2kai io/pit.c systimer(): `if ((pitch->ctrl & 0x0c) == 0x04)` re-arms PIT_FLAG_I only
//     for modes 2/3 (and their 6/7 aliases); every other mode clears it
//     (`pitch->flag &= ~PIT_FLAG_I;`) after ONE `pic_setirq(0)` - one IRQ0 per count write.
//   NP2kai io/pit.c pit_setflag(): `pitch->ctrl = (UINT8)((value & 0x3f) | PIT_STAT_CMD);`
//     and latchcmd's status is `pitch->stat = pitch->ctrl`, so read-back status bits 5:0 are
//     the control word's own (mode 6 reads 6, BCD bit 0 reads back). The 8254 datasheet's
//     status format is the same ("D5-D0: counter programmed mode", as written).
//   Divergence: MAME src/devices/machine/pit8253.cpp starts modes 1/5 only on a GATE rising
//     edge, and its PC-98 driver never drives the gates, so there they never fire. NP2kai is
//     the higher-ranked reference and counts them from the count write (one IRQ), which is
//     what this bench asserts.
// FAIL-FIRST: before the fix the mode-set drove OUT low for modes 1/4/5, the count reloaded at
// terminal count and OUT toggled there, so mode 4 was a 2N-period square wave raising an IRQ0
// edge every 2N clocks; and the status byte read 0x34 for control 0x7D.

module tb_pc9821_pit_oneshot;

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

  // One PIT clock is 50e6 / 2.4576e6 = 20.35 clk_sys.
  localparam integer N = 20;

  integer errors = 0;
  integer rises = 0, falls = 0;
  integer t_write = 0, t_fall = -1, t_rise = -1;
  integer cyc = 0;
  reg     out0_q = 1'b0;
  reg     [7:0] st;

  always @(posedge clk) begin
    cyc <= cyc + 1;
    out0_q <= out0;
    if (rst_n && out0 && !out0_q) begin rises <= rises + 1; if (t_rise < 0) t_rise <= cyc; end
    if (rst_n && !out0 && out0_q) begin falls <= falls + 1; if (t_fall < 0) t_fall <= cyc; end
  end

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

  task clear_counts;
    begin
      @(negedge clk);
      rises = 0; falls = 0; t_fall = -1; t_rise = -1;
    end
  endtask

  // ==== CHECKS ====
  task expect_int(input [8*48-1:0] name, input integer got, input integer lo, input integer hi);
    begin
      if (got < lo || got > hi) begin
        $display("MISMATCH %0s: got %0d, want %0d..%0d", name, got, lo, hi);
        errors = errors + 1;
      end else $display("ok       %0s = %0d", name, got);
    end
  endtask

  // Program ch0 with a control word, check OUT, write count N, run ~50 N PIT clocks.
  task one_shot(input [7:0] ctrl, input [8*16-1:0] tag, input is_strobe);
    begin
      write_pit(2'd3, ctrl);
      repeat (4) @(posedge clk);
      expect_int({tag, " OUT after control word"}, out0, 1, 1);
      clear_counts;
      write_pit(2'd0, N[7:0]);
      write_pit(2'd0, 8'h00);
      t_write = cyc;
      repeat (50 * N * 21) @(posedge clk);
      expect_int({tag, " OUT rising edges"}, rises, 1, 1);
      expect_int({tag, " OUT falling edges"}, falls, 1, 1);
      expect_int({tag, " OUT final level"}, out0, 1, 1);
      if (is_strobe) begin
        // One CLK pulse low, about N PIT clocks after the count write.
        expect_int({tag, " strobe width clk_sys"}, t_rise - t_fall, 15, 26);
        expect_int({tag, " strobe start clk_sys"}, t_fall - t_write, (N - 1) * 20, (N + 2) * 21);
      end else begin
        // Mode 1, triggered by the count write: low at the load, high at terminal count.
        expect_int({tag, " low time clk_sys"}, t_rise - t_fall, (N - 1) * 20, (N + 2) * 21);
      end
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    one_shot(8'h38, "mode4", 1'b1);   // ch0, LSB+MSB, mode 4
    one_shot(8'h3A, "mode5", 1'b1);   // ch0, LSB+MSB, mode 5
    one_shot(8'h32, "mode1", 1'b0);   // ch0, LSB+MSB, mode 1

    // Read-back status keeps the written mode and BCD bits (NP2kai pit_setflag).
    write_pit(2'd3, 8'h7D);           // ch1, LSB+MSB, mode 6, BCD
    write_pit(2'd1, 8'h10);
    write_pit(2'd1, 8'h00);
    write_pit(2'd3, 8'hE4);           // read-back: status only, CT1
    read_pit(2'd1, st);
    expect_int("ch1 status bits 5:0 (0x7D written)", st[5:0], 8'h3D, 8'h3D);
    write_pit(2'd3, 8'hB7);           // ch2, LSB+MSB, mode 3, BCD
    write_pit(2'd3, 8'hE8);           // read-back: status only, CT2
    read_pit(2'd2, st);
    expect_int("ch2 status bits 5:0 (0xB7 written)", st[5:0], 8'h37, 8'h37);

    // The status byte's RW field (bits 5:4) is the control word's own for the single-byte
    // formats too (NP2kai pit_setflag: `ctrl = (value & 0x3f) | PIT_STAT_CMD`, status =
    // ctrl), not a fixed LSB+MSB: an LSB-only (RL=1) and an MSB-only (RL=2) channel.
    write_pit(2'd3, 8'h14);           // ch0, LSB only, mode 2
    write_pit(2'd3, 8'hE2);           // read-back: status only, CT0
    read_pit(2'd0, st);
    expect_int("ch0 status bits 5:0 (0x14 written)", st[5:0], 8'h14, 8'h14);
    write_pit(2'd3, 8'h68);           // ch1, MSB only, mode 4
    write_pit(2'd3, 8'hE4);
    read_pit(2'd1, st);
    expect_int("ch1 status bits 5:0 (0x68 written)", st[5:0], 8'h28, 8'h28);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PIT_ONESHOT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_ONESHOT: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PIT_ONESHOT: TIMEOUT");
  end

endmodule

`default_nettype wire
