// tb_pc9821_kbd_repoke - the unread byte's IRQ request: held level, re-poked.
//
// ==== WHAT THIS PROVES ====
// While a delivered byte waits unread the IRQ line holds (RXRDY's own level - qemu pc98-kbd.c raises it from KST_RXRDY and tb_pc9821_kbd_reset pins the hold) but re-strokes once per keyboard transfer tick (NP2kai io/serial.c keyboard_callback pokes pic_setirq(1) at every xferclock tick; keyboard_changeclock: realclock/1920 -> 1280 byte-times/s), so an acknowledge that is NOT followed by a 0x41 read is re-requested within one tick by the edge-latched PIC and the re-strokes stop the moment the byte is read; and the receive status has ONE next-state, so a same-clk data read + overflow cannot resurrect RXRDY after the guest's read (the old last-wins chain handed the guest its already-read byte again) while the overflow flag still lands.
//
// The consumer is the edge-latched PIC (pc9821_pic.sv: "set on a rising edge of
// IR, held until INTA clears the serviced bit. A still-held level does NOT
// re-set after INTA (no new edge)"). NP2kai's keyboard_callback (io/serial.c)
// pokes pic_setirq(1) at EVERY transfer tick while the receive side is not
// empty - a request EVENT, not a wire level - so after a dispatch whose handler
// does not read the byte, the next tick RE-REQUESTS IRQ1 and the byte cannot
// sit forever with no interrupt (the dispatched-but-never-read wedge; the
// EMM386 trace's 13-delivered/12-reads residue). qemu holds the level and has
// no re-poke (pc98-kbd.c:470/514); NP2kai wins per the evidence hierarchy.
//
// The read side is the fold's proof: with a full receive
// side (byte in flight + 16 queued), a data read landing on the same clk as an
// overflowing event must leave RXRDY CLEAR (the read's clear wins over the
// overflow's stale-value write) with the OVERRUN flag set - before the fold the
// overflow arm resurrected RXRDY from the pre-read value and the guest's next
// 0x41 read returned the ALREADY-read rx_latch as a duplicate key byte.
//
// FAIL-FIRST: on the pre-fix pc9821_kbd (level held, no re-poke, un-folded
// status) section 1 finds no re-fire after the dispatch, and section 4 finds
// RXRDY resurrected at the collision; sections 2/3 pass both ways.

`timescale 1ns / 1ps

module tb_pc9821_kbd_repoke;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // ==== DUT ====
  // The transfer tick is SHRUNK from the device default (SYS_CLOCK_HZ / 1280 =
  // 39,062 clk at this bench's 50 MHz) so the re-poke and the presentation pace are
  // both observable in a few microseconds; the RATE it models and the tick's use as
  // the re-stroke period are unchanged (tb_pc9821_kbd_pace pins the presentation
  // interval; this bench pins the re-poke contract).
  localparam integer XFER = 32;
  pc9821_kbd #(
      .XFER_TICK_CYCLES(26'(XFER))
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .cs(cs),
      .a0(a0),
      .wr(wr),
      .rd(rd),
      .din(din),
      .dout(dout),
      .irq(irq),
      .ps2_key(ps2_key),
      .bios_setup(1'b0)
  );

  // The consumer's request latch, pc9821_pic.sv's edge latch in shape:
  // ir_set = ir_in & ~ir_prev, held until the acknowledge clears it, with the
  // datasheet's set-wins collision (a stroke on the ack edge is a new request).
  reg pic_prev  = 1'b0;
  reg pic_latch = 1'b0;
  reg pic_ack   = 1'b0;
  always @(posedge clk) begin
    pic_prev  <= irq;
    pic_latch <= (pic_latch & ~pic_ack) | (irq & ~pic_prev);
  end

  integer errors = 0;
  integer timeout_count;
  integer i;
  integer low_clks;
  reg [7:0] value;
  reg toggle = 0;
  // 16 distinct MAPPED Set-2 makes for the overflow fill (the table maps every
  // one of them), in enqueue order; the first queued byte is therefore NEC 0x01.
  reg [7:0] fill_set2 [0:15];
  initial begin
    fill_set2[ 0] = 8'h16; fill_set2[ 1] = 8'h1e; fill_set2[ 2] = 8'h26; fill_set2[ 3] = 8'h25;
    fill_set2[ 4] = 8'h2e; fill_set2[ 5] = 8'h36; fill_set2[ 6] = 8'h3d; fill_set2[ 7] = 8'h3e;
    fill_set2[ 8] = 8'h46; fill_set2[ 9] = 8'h45; fill_set2[10] = 8'h4e; fill_set2[11] = 8'h55;
    fill_set2[12] = 8'h66; fill_set2[13] = 8'h0d; fill_set2[14] = 8'h1d; fill_set2[15] = 8'h24;
  end

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

  // The CPU takes IRQ1: the PIC acknowledge moves the request to in-service.
  task pic_dispatch;
    begin
      @(negedge clk);
      pic_ack = 1'b1;
      @(posedge clk);
      @(negedge clk);
      pic_ack = 1'b0;
    end
  endtask

  task read_byte(input [7:0] expected);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 60) begin
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
          $display("FAIL: keyboard byte got %02x want %02x @ %0t", value, expected, $time);
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

  // ==== STIMULUS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    // The firmware's own init: mode byte, then TxEN+RxE+RTS.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ---- 1. A dispatch WITHOUT a read is re-requested at the next tick. ----
    send_key(1'b1, 1'b0, 8'h1C);           // A make -> NEC 0x1D, delivered
    timeout_count = 0;
    while (!dut.status_reg[1] && timeout_count < 20) begin
      @(posedge clk);
      timeout_count = timeout_count + 1;
    end
    if (!dut.status_reg[1]) fail("the delivered byte did not set RXRDY (NP2kai serial.c status |= 2)");
    // The level is RXRDY's own: it may dip exactly one clk per transfer tick
    // (the re-stroke) and nothing more - it is a held level, not a pulse.
    low_clks = 0;
    for (i = 0; i < 20; i = i + 1) begin
      @(posedge clk);
      #1;
      if (!irq) low_clks = low_clks + 1;
    end
    if (low_clks > 2) fail("the IRQ level is not held while the byte waits (only one-clk re-strokes are allowed)");

    pic_dispatch();                        // the CPU took IRQ1 - and did NOT read 0x41
    if (pic_latch) fail("the PIC latch was not consumed by the acknowledge");
    // Within three transfer ticks the re-poke must put the request back: the
    // edge-latched PIC sees a NEW rising edge and IRQ1 fires again - the guest
    // gets another chance at the byte instead of it sitting forever.
    timeout_count = 0;
    while (!pic_latch && timeout_count < 3 * XFER) begin
      @(posedge clk);
      timeout_count = timeout_count + 1;
    end
    if (!pic_latch) fail("no re-fire: an acknowledged-but-unread byte left IRQ1 dead forever (the EMM386 wedge)");

    // ---- 2. The re-strokes stop the moment the byte is read. ----
    read_byte(8'h1D);                      // the guest finally reads
    if (dut.status_reg[1]) fail("RXRDY survived the 0x41 read (NP2kai serial.c status &= ~2)");
    if (irq)                fail("the IRQ line is still asserted after the read");
    pic_dispatch();                        // consume whatever the read left pending
    repeat (3 * XFER + 4) @(posedge clk); // three transfer ticks
    if (pic_latch) fail("a read byte still re-fires IRQ1: the re-strokes did not stop");
    if (irq)       fail("the IRQ line re-asserted after the byte was read");

    // ---- 3. A second delivery re-arms the whole contract (level + re-poke). ----
    send_key(1'b0, 1'b0, 8'h1C);           // A break -> NEC 0x9D
    timeout_count = 0;
    while (!dut.status_reg[1] && timeout_count < 20) begin
      @(posedge clk);
      timeout_count = timeout_count + 1;
    end
    if (!dut.status_reg[1]) fail("the second delivery did not re-arm RXRDY");
    if (!irq)               fail("the second delivery did not re-arm the IRQ level");
    read_byte(8'h9D);

    // ---- 4. The status fold: a same-clk read + overflow cannot resurrect RXRDY. ----
    // Fill the receive side: one byte in flight (unread) and 16 queued behind
    // it, then one more event that can only overflow. The pacing timer is drained
    // first so Q's own delivery is the immediate first-after-idle case.
    repeat (XFER + 4) @(posedge clk);
    send_key(1'b1, 1'b0, 8'h15);           // Q make -> 0x10, delivered
    repeat (4) @(posedge clk);
    if (!dut.status_reg[1]) fail("the in-flight byte for the overflow collision never set RXRDY");
    for (i = 0; i < 16; i = i + 1) begin
      send_key(1'b1, 1'b0, fill_set2[i]);  // 16 distinct makes, all queued
      repeat (2) @(posedge clk);
    end
    #1;   // let the last enqueue's NBA land before counting
    if (dut.fifo_cnt !== 5'd16) begin
      $display("FAIL: expected 16 queued bytes before the overflow, found %0d", dut.fifo_cnt);
      errors = errors + 1;
    end
    // The collision: the overflowing event decides on the posedge after the
    // extra negedge (the T6 pipeline contract tb_pc9821_kbd_pipeline pins), and
    // the guest's 0x41 read strobes that same clk.
    send_key(1'b1, 1'b0, 8'h31);           // N make -> 0x2E: the event that overflows
    @(negedge clk);
    a0 = 0; cs = 1; rd = 1;                // the guest reads 0x41 in the decision clk
    @(posedge clk);
    @(negedge clk);
    cs = 0; rd = 0;
    #1;
    if (dut.status_reg[1]) fail("same-clk read + overflow resurrected RXRDY: the guest would re-read its stale byte");
    if (!dut.status_reg[4]) fail("the overflow flag did not land alongside the read's clear");
    // And the guest's next byte is the NEXT queued key, not the stale duplicate.
    read_byte(8'h01);                      // the first queued make's NEC code

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_REPOKE: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_REPOKE: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_KBD_REPOKE: TIMEOUT");
  end

endmodule
