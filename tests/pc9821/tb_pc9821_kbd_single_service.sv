// tb_pc9821_kbd_single_service - one byte, ONE request: the re-poke must not double-serve.
//
// ==== WHAT THIS PROVES ====
// One delivered byte produces exactly ONE interrupt request and the request dies with its 0x41 read: the re-poke's one-clk dip may not arm the edge-latched PIC in a normal service's dispatch-to-read window (the BIOS IRQ1 handler at BIOS.ROM 0x16640 reads 0x41 without checking RXRDY - so any request that survives the read re-processes the stale byte as a second keypress) and a read landing on the dip's recovery cycle cancels that edge atomically - while a genuinely unread byte still re-fires (tb_pc9821_kbd_repoke pins that side).
//
// The regression this pins (reported as "some keys now double-type
// occasionally"): the re-poke dips the request line once per transfer tick while
// the byte waits unread. The dip is a falling edge plus a RISING edge, and the
// rising edge re-arms the PIC's edge latch. If it lands after the acknowledge of
// the byte's own service and before the handler's 0x41 read, the latch is set
// again; the read clears RXRDY (and the line) but cannot withdraw that latch, so
// after EOI IRQ1 fires a second time and the handler - which reads 0x41
// UNCONDITIONALLY (the firmware's `in al,0x43; test al,0x38` gates only the
// error flags, then `in al,0x41`) - re-reads the stale rx_latch and queues the
// same MAKE again. Stale breaks are harmless (the handler queues makes only),
// which is why only some keys double-type.
//
// Two holes, both pinned here:
//   (1) the dip's recovery may land anywhere in the free-running tick, including
//       the [dispatch, read] window of a normal service - the fix restarts the
//       tick divider on every request rise, so the first re-stroke of a fresh
//       byte is one FULL transfer tick after the request and a normal read has
//       long cleared RXRDY before it;
//   (2) a read landing on the recovery cycle let the recovery edge fire DURING
//       the read (status_reg[1] is still set while the read strobe is up) - the
//       fix forces the line low in the read cycle itself (st_read), cancelling
//       the in-flight dip atomically with the status clear.
//
// FAIL-FIRST: on the pre-fix tree both sections see a SECOND rising edge and a
// pending latch after the byte was read (2 edges where 1 is required).

`timescale 1ns / 1ps

module tb_pc9821_kbd_single_service;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // The transfer tick the DUT derives from the device rate (NP2kai
  // keyboard_changeclock: 2,457,600 / 1920 = 1280 byte-times/s at clk 50 MHz).
  localparam integer TICK_CYCLES = 50_000_000 / 1280;

  // ==== DUT ====
  pc9821_kbd dut (
      .clk(clk),
      .rst_n(rst_n),
      .cs(cs),
      .a0(a0),
      .wr(wr),
      .rd(rd),
      .din(din),
      .dout(dout),
      .irq(irq),
      .ps2_key(ps2_key)
  );

  // The consumer's request latch - pc9821_pic.sv's edge latch in shape (set on a
  // rising edge, held until the acknowledge; a still-held level does NOT re-set).
  reg pic_prev  = 1'b0;
  reg pic_latch = 1'b0;
  reg pic_ack   = 1'b0;
  integer edges = 0;
  always @(posedge clk) begin
    pic_prev  <= irq;
    pic_latch <= (pic_latch & ~pic_ack) | (irq & ~pic_prev);
    if (irq && !pic_prev) edges = edges + 1;
  end

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;

  // ==== CHECKS ====
  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_port(input control_port, input [7:0] data);
    begin
      @(negedge clk);
      a0  = control_port;
      din = data;
      cs  = 1;
      wr  = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      wr = 0;
    end
  endtask

  task send_key(input pressed, input extended, input [7:0] code);
    begin
      @(negedge clk);
      toggle  = ~toggle;
      ps2_key = {toggle, pressed, extended, code};
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  // The CPU takes IRQ1: the acknowledge consumes the latch and the handler runs.
  task pic_dispatch;
    begin
      @(negedge clk);
      pic_ack = 1'b1;
      @(posedge clk);
      @(negedge clk);
      pic_ack = 1'b0;
    end
  endtask

  task wait_request;
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) fail("no receive IRQ: the delivered byte never requested");
      #1;   // let the edge counter's update land before anyone reads it
    end
  endtask

  task read_byte(input [7:0] expected);
    begin
      wait_request();
      @(negedge clk);
      a0 = 0;
      cs = 1;
      rd = 1;
      #1 value = dout;
      if (value !== expected) begin
        $display("FAIL: keyboard byte got %02x want %02x @ %0t", value, expected, $time);
        errors = errors + 1;
      end
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      rd = 0;
      #1;
    end
  endtask

  // The service is over: exactly `want` rising edges and nothing left pending.
  // Every scenario dispatches (the acknowledge consumes the one legitimate
  // request), so after the read the latch must be EMPTY - a latch still set is
  // the double-type itself: after EOI IRQ1 re-fires and the handler (which reads
  // 0x41 without checking RXRDY) re-processes the stale byte.
  task expect_exactly_one(input integer want, input [8*64-1:0] who);
    begin
      repeat (2 * TICK_CYCLES + 100) @(posedge clk);
      #1;
      if (edges != want) begin
        $display("FAIL: %0s: %0d request edges, want %0d (a re-fire re-processes the stale byte)", who, edges, want);
        errors = errors + 1;
      end
      if (pic_latch) fail("the PIC still holds a pending request after the byte was read");
      if (irq)       fail("the IRQ line is asserted after the byte was read");
    end
  endtask

  // ==== STIMULUS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    // The firmware's own init: mode byte, then TxEN+RxE+RTS.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ---- 1. The [dispatch, read] window of a normal service is dip-free. ----
    // Phase-align the (pre-fix free-running) tick divider so the dip's recovery
    // lands ~100 clk after the send - inside the window between the acknowledge
    // and the handler's read. The fix restarts the divider on the request rise,
    // so post-fix the alignment is moot: the first re-stroke is one full tick
    // away, past the read that consumes the byte.
    edges = 0;
    while (dut.xfer_div !== (TICK_CYCLES - 100)) @(posedge clk);
    send_key(1'b1, 1'b0, 8'h1C);           // A make -> NEC 0x1D
    wait_request();                        // edges == 1: the delivery's request
    if (edges != 1) fail("the delivery did not make exactly one request");
    pic_dispatch();                        // the CPU takes IRQ1 - the handler runs now
    repeat (200) @(posedge clk);           // ...and reads 0x41 a couple hundred clk later
    read_byte(8'h1D);
    expect_exactly_one(1, "service window");

    // ---- 2. A read landing on the dip's recovery cycle cancels it atomically. ----
    edges = 0;
    send_key(1'b1, 1'b0, 8'h1D);           // W make -> NEC 0x11
    wait_request();
    if (edges != 1) fail("the second delivery did not make exactly one request");
    pic_dispatch();                        // the CPU takes IRQ1 - the handler runs now
    // Find the re-stroke's low phase with the byte still unread; the NEXT cycle
    // is the recovery edge's cycle, and the handler's read lands exactly there.
    timeout_count = 0;
    while (!(dut.status_reg[1] && !irq) && timeout_count < 2 * TICK_CYCLES) begin
      @(posedge clk);
      #1;
      timeout_count = timeout_count + 1;
    end
    if (!(dut.status_reg[1] && !irq)) fail("no re-stroke low phase observed: scenario 2 is vacuous");
    // The recovery edge is the cycle AFTER the low phase, and the read's status
    // clear only lands the cycle after its strobe is sampled - so the handler's
    // read must be ON the recovery cycle for the pre-fix recovery edge to arm the
    // PIC inside the very read that consumes the byte.
    @(posedge clk);
    @(negedge clk);
    a0 = 0;
    cs = 1;
    rd = 1;                                // the read strobe covers the recovery cycle
    #1 value = dout;
    if (value !== 8'h11) begin
      $display("FAIL: keyboard byte got %02x want 11 @ %0t", value, $time);
      errors = errors + 1;
    end
    @(posedge clk);
    @(negedge clk);
    cs = 0;
    rd = 0;
    expect_exactly_one(1, "read-on-recovery");

    // ---- 3. The contract is not over-suppressed: the next byte still gets exactly one. ----
    edges = 0;
    send_key(1'b0, 1'b0, 8'h1C);           // A break -> NEC 0x9D
    wait_request();
    pic_dispatch();
    read_byte(8'h9D);
    expect_exactly_one(1, "second byte");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_SINGLE_SERVICE: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_SINGLE_SERVICE: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_KBD_SINGLE_SERVICE: TIMEOUT");
  end

endmodule
