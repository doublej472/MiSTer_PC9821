// tb_pc9821_kbd_reset_race - the keyboard reset vs a same-cycle deliver/enqueue.
//
// ==== WHAT THIS PROVES ====
// The 8251 bit-3 keyboard reset is a priority fold over the receive side's same-cycle updates (the Single-Cycle Event Discipline): a key enqueued one cycle before the reset write delivers INTO the reset write's cycle, and the reset must still win - fifo indices zeroed, no RXRDY/IRQ resurrection with the pre-reset byte, rx_latch untouched - and the next key must still be the next key, while a key held across the reset keeps its dedup state (NP2kai keeps keystat.ref), so a duplicate make stays silent and its break still delivers.
//
// The 8251 bit-3 keyboard reset (the ITF's 0x3A -> 0x32 pair) is a PRIORITY
// FOLD over the receive side's same-cycle updates. A key
// enqueued one cycle before the reset write delivers INTO the reset write's
// cycle - `deliver_key` fires exactly one cycle after any enqueue while !RXRDY -
// and before the fix the deliver/enqueue NBAs (later in the same always block
// than the reset's clears) resurrected RXRDY/IRQ/rx_latch with the pre-reset
// byte and left the queue indices at head+1 / tail+1 instead of zeroed. The
// first post-reset read then returned stale pre-reset data.
//
// The fold follows the Single-Cycle Event Discipline (race-idiom-report.md
// section 4): every affected register has ONE next-state per cycle,
// `reset_event ? clear : normal_update`, so the outcome is a boolean and not
// the NBA order. The coincident event is discarded WITH the rest of what the
// receive side is holding - exactly what NP2kai's keyboard_resetsignal() clears
// (keybrd.status, keybrd.ctrls, keybrd.buffers).

`timescale 1ns / 1ps

module tb_pc9821_kbd_reset_race;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

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

  task read_byte(input [7:0] expected);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        $display("FAIL: no receive IRQ: byte %02x never arrived @ %0t", expected, $time);
        errors = errors + 1;
      end else begin
        @(negedge clk);
        a0 = 0;
        cs = 1;
        rd = 1;
        #1 value = dout;
        if (value !== expected) begin
          $display("FAIL: keyboard byte got %02x want %02x", value, expected);
          errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        cs = 0;
        rd = 0;
        #1;
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;

    // The firmware's own init, then arm bit 3 (0x3A) so the NEXT command write's
    // bit-3 1-to-0 transition is the keyboard reset.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    write_port(1'b1, 8'h3A);

    // ==== THE COLLISIONS ====
    // T6 moved the event DECISION one clk_sys deeper (the dedup table's read is clocked), so
    // the reset is placed against the decision now, and the pre-T6 shape is kept as well.
    // Both are collisions the reset must own:
    //   (A) the reset in the clk the pre-reset event DECIDES (enqueues);
    //   (B) the reset in the clk the pre-reset byte would DELIVER - the bench's original
    //       shape, one clk later than (A).
    // send_key's event decides on the 2nd posedge after its toggle and delivers on the 3rd;
    // write_port strobes the posedge after its first negedge, so calling it straight after
    // send_key strobes the 2nd (case A) and starting it one negedge later strobes the 3rd
    // (case B).

    // ---- (A) the DECISION's clk. ----
    send_key(1'b1, 1'b0, 8'h5A);           // make Enter -> decides on the next posedge
    write_port(1'b1, 8'h32);               // ...and the reset strobes THAT clk

    // The reset owns the cycle: nothing of the pre-reset event survives - not the queued
    // byte, not the FIFO indices, not the delivered byte, not the key-state word.
    repeat (2) @(negedge clk);
    if (dut.fifo_cnt !== 5'd0)    fail("fifo_cnt not zeroed by the keyboard reset (A)");
    if (dut.fifo_head !== 4'd0)   fail("fifo_head not zeroed by the keyboard reset (A)");
    if (dut.fifo_tail !== 4'd0)   fail("fifo_tail not zeroed by the keyboard reset (A)");
    if (dut.status_reg[1])        fail("RXRDY resurrected by a same-cycle enqueue: the pre-reset byte came back (A)");
    if (irq)                      fail("IRQ resurrected by a same-cycle enqueue (A)");
    if (dut.rx_latch !== 8'hFF) begin
      $display("FAIL: rx_latch = %02x, the pre-reset byte: the reset must discard it (A)", dut.rx_latch);
      errors = errors + 1;
    end

    // And the reset did not wedge the queue: the next key is the next key.
    write_port(1'b1, 8'h05);               // re-enable RX/TX (the reset does not touch them)
    send_key(1'b1, 1'b0, 8'h1C);           // A -> 0x1D
    read_byte(8'h1D);

    // ---- (B) the DELIVER's clk, the bench's original shape. ----
    write_port(1'b1, 8'h3A);               // re-arm bit 3
    send_key(1'b1, 1'b0, 8'h1D);           // make W -> 0x11
    @(posedge clk);                        // the depth contract: the event decides here ...
    @(posedge clk); #1;                    // ... and the byte is QUEUED here
    if (dut.fifo_cnt !== 5'd1) begin
      $display("FAIL: the pre-reset byte did not enqueue (%0d): the (B) collision would be vacuous",
               dut.fifo_cnt);
      errors = errors + 1;
    end
    write_port(1'b1, 8'h32);               // ...then the reset strobes THE DELIVER's clk

    // The reset owns the cycle: nothing of the pre-reset receive state survives.
    repeat (2) @(negedge clk);
    if (dut.fifo_cnt !== 5'd0)    fail("fifo_cnt not zeroed by the keyboard reset (B)");
    if (dut.fifo_head !== 4'd0)   fail("fifo_head not zeroed by the keyboard reset (B)");
    if (dut.fifo_tail !== 4'd0)   fail("fifo_tail not zeroed by the keyboard reset (B)");
    if (dut.status_reg[1])        fail("RXRDY resurrected by a same-cycle deliver: the pre-reset byte came back (B)");
    if (irq)                      fail("IRQ resurrected by a same-cycle deliver (B)");
    // rx_latch is NOT cleared by the keyboard reset (it holds the last byte HANDED to the
    // guest; the reset discards what is QUEUED - the original bench recorded it as
    // untouched). It must therefore still hold case (A)'s 0x1D: if the coincident deliver
    // had run, the byte in flight (make W = 0x11) would be there instead.
    if (dut.rx_latch !== 8'h1D) begin
      $display("FAIL: rx_latch = %02x, want 1D (case A's byte): the pre-reset byte 0x11 delivered (B)",
               dut.rx_latch);
      errors = errors + 1;
    end

    // ...and the key whose make was in flight is still held, as NP2kai keeps its
    // keystat.ref across keyboard_resetsignal: a duplicate make is silent (M2) and
    // the physical BREAK still reaches the guest (the old epoch bump cleared the
    // dedup here, so the break was swallowed and the key stuck down).
    write_port(1'b1, 8'h05);               // re-enable RX/TX
    send_key(1'b1, 1'b0, 8'h1D);           // keep W held, make it again
    repeat (4) @(posedge clk); #1;
    if (irq) fail("a duplicate make after the bit-3 reset was delivered: the dedup state did not survive");
    send_key(1'b0, 1'b0, 8'h1D);           // the held key's break must DELIVER
    read_byte(8'h91);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_RESET_RACE: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_RESET_RACE: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_KBD_RESET_RACE: TIMEOUT");
  end

endmodule
