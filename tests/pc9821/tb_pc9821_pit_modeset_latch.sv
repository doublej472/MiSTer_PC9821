// tb_pc9821_pit_modeset_latch - a mode-set control word drops a pending count latch and a
// pending read-back status.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_MODESET_LATCH: a mode-set control word discards whatever a channel still holds for the reader: after a counter latch whose low byte alone was read, after a counter latch never read, and after a read-back status latch never read, reprogramming channel 2 (control 0xB0 or 0xB4) and loading a new count 0x0300 makes the next LSB+MSB read pair return the NEW live count (a pair within 0x02C0..0x0300, about 12 PIT clocks after the load), never the stale latched 0x1234 or the stale status byte, so a model whose mode-set leaves the count latch, its second byte or the status latch pending fails here; and the clear is per channel: a count latch pending on channel 0 survives a mode-set of channel 2 and still reads the held value (0x1220..0x1234, about 100 PIT clocks above the live count), so a broadened clear fails too.

// ---- where the expectation comes from ----
//   NP2kai io/pit.c:246-249, pit_setflag on a control word with the RL bits set:
//     `pitch->flag &= ~(PIT_FLAG_R | PIT_FLAG_W | PIT_FLAG_L |` / `PIT_FLAG_S | PIT_FLAG_C);`
//     - C (a count latch pending), L (its second byte outstanding) and S (a status latch
//     pending) are all cleared, so the next read takes the live counter.
//   8254 datasheet (Intel 231164), "Counter Latch Command": the latched count is held "until
//     it is read by the CPU (or until the counter is reprogrammed)".
//   No Xe10 capture covers a latch left pending across a mode-set; NP2kai is the strongest
//   source available (QEMU hw/timer/i8254.c leaves count_latched set on a control word, a
//   lower-ranked reference, recorded as a divergence in pc9821_pit.sv).
//   The new count 0x0300 is read about 220 clk_sys (about 11 PIT clocks at 2.4576 MHz) after
//   its load, so the live pair is 0x02C0..0x0300 whatever the tick phase; the stale values are
//   the count latched near 0x122F (a stale low byte 0x2F mixed with a live high byte reads
//   0x022F) and the status byte 0x30/0x70/0xB0/0xF0 (RW=3, mode 0, OUT and NULL COUNT either
//   way).
// FAIL-FIRST: on the tree before the fix every case returns a stale byte (the latched 0x34/0x12
// or the status byte) on the first read after the reprogramming.

module tb_pc9821_pit_modeset_latch;

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
  reg [7:0] lo, hi, junk;

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

  // ch2 in mode 0, LSB+MSB, counting from 0x1234
  task start_old;
    begin
      write_pit(2'd3, 8'hB0);
      write_pit(2'd2, 8'h34);
      write_pit(2'd2, 8'h12);
      repeat (100) @(posedge clk);
    end
  endtask

  // the reprogramming under test, then the read pair
  task reprogram_and_check(input [7:0] ctrl, input string name);
    begin
      write_pit(2'd3, ctrl);
      write_pit(2'd2, 8'h00);
      write_pit(2'd2, 8'h03);           // count 0x0300
      repeat (200) @(posedge clk);
      read_pit(2'd2, lo);
      read_pit(2'd2, hi);
      $display("%s: pair after the mode-set = %02x%02x", name, hi, lo);
      if ({hi, lo} < 16'h02C0 || {hi, lo} > 16'h0300) begin
        $display("MISMATCH %s: read %02x%02x, want the live new count 0x02C0..0x0300", name, hi, lo);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // 1. a counter latch with its low byte read (the high byte, L, still owed)
    start_old;
    write_pit(2'd3, 8'h80);             // counter latch, ch2
    read_pit(2'd2, junk);               // the latched LSB
    reprogram_and_check(8'hB0, "latch half read, mode 0");

    // 2. a counter latch never read (C pending)
    start_old;
    write_pit(2'd3, 8'h80);
    reprogram_and_check(8'hB0, "latch unread, mode 0");

    // 3. a read-back STATUS latch never read (S pending): 0xE8 = read-back, count not
    //    latched (bit 5), status latched (bit 4 clear), counter 2 (bit 3)
    start_old;
    write_pit(2'd3, 8'hE8);
    reprogram_and_check(8'hB4, "status unread, mode 2");

    // 4. the read-back latching count AND status (0xC8), neither read
    start_old;
    write_pit(2'd3, 8'hC8);
    reprogram_and_check(8'hB0, "count+status unread, mode 0");

    // 5. the NEGATIVE control: a mode-set clears only ITS channel. ch0 holds a count latch
    //    (the common "latch ch0, then program ch2" order); reprogramming ch2 must leave it, so
    //    the ch0 pair still reads the value latched ~2000 clk_sys (about 100 PIT clocks)
    //    before the live count moved on. NP2kai pit_setflag acts on the addressed channel's
    //    own pitch->flag only (io/pit.c:246-249); the 8254 holds a latch "until it is read
    //    by the CPU (or until the counter is reprogrammed)", and ch0 is not reprogrammed.
    write_pit(2'd3, 8'h30);             // ch0, LSB+MSB, mode 0
    write_pit(2'd0, 8'h34);
    write_pit(2'd0, 8'h12);             // count 0x1234
    repeat (100) @(posedge clk);
    write_pit(2'd3, 8'h00);             // counter latch, ch0 (near 0x122F)
    repeat (2000) @(posedge clk);       // the live ch0 count falls about 100 below the latch
    write_pit(2'd3, 8'hB0);             // mode-set ch2
    write_pit(2'd2, 8'h00);
    write_pit(2'd2, 8'h03);
    read_pit(2'd0, lo);
    read_pit(2'd0, hi);
    $display("ch0 latch across a ch2 mode-set: pair = %02x%02x", hi, lo);
    if ({hi, lo} < 16'h1220 || {hi, lo} > 16'h1234) begin
      $display("MISMATCH ch0 latch across a ch2 mode-set: read %02x%02x, want the held latch 0x1220..0x1234 (a mode-set of ch2 dropped ch0's latch)", hi, lo);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PIT_MODESET_LATCH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_MODESET_LATCH: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PIT_MODESET_LATCH: TIMEOUT");
  end

endmodule

`default_nettype wire
