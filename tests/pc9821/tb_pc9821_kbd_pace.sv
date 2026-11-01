// tb_pc9821_kbd_pace - the keyboard's byte PRESENTATION is paced at the keyboard's
// own transfer rate, so a guest that peeks 0x41 between chained reads gets the STALE
// data register exactly as it does on a real PC-9821.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_KBD_PACE: the keyboard presents one byte per transfer tick (NP2kai io/serial.c keyboard_changeclock: pccore.realclock / 1920 = 2,457,600 / 1920 = 1280 byte-times/s), not one clk after the previous byte is read. The first byte after idle is still immediate; after a delivery the next FIFO byte is presented only after XFER_TICK_CYCLES, so a guest interrupt hook that reads port 0x41 itself BEFORE chaining (a disk image's HSB.EXE INT 09h hook at 0x2CE5/0x2C3D, which tracks the 0x70-0x74 modifiers) and then lets the chained BIOS handler read 0x41 again sees the SAME stale latch both times, instead of the peek consuming the next queued make or break and leaving a modifier stuck. A host burst is delivered with consecutive presentations a full tick apart and no byte is lost or reordered;  slow/ordinary typing (an idle longer than a tick) still presents its first byte immediately. The 8251 bit-3 keyboard reset clears the divider (the first byte after it is immediate again) while keeping the held-key dedup epoch, so a held key is never forgotten and its break still arrives.
//
// ==== WHERE THE EXPECTED TIMING COMES FROM ====
// NP2kai io/serial.c keyboard_callback delivers a byte and pokes the PIC once per
// keyboard transfer tick; keyboard_changeclock sets keybrd.xferclock =
// pccore.realclock / 1920, and pccore.realclock is the 2,457,600 Hz base clock at
// multiple 1 (pccore.h PCBASECLOCK25), i.e. 1,280 byte-times/s (one byte per 0.78 ms).
// The real Xe10 cannot present the next byte sooner than that, which is why HSB's peek
// sees the stale data register rather than the next key.
//
// The bench scales the tick down (TICK = 64 clk = 0.64 us at its 10 ns clock) so the
// cases run in microseconds while keeping the ORDER OF MAGNITUDE of the real ratio
// (0.78 ms per byte against ~50 ms typing): a "normal typing" gap here is >30 ticks.
//
// ==== FAIL-FIRST ====
// On the pre-fix pc9821_kbd the next FIFO byte is delivered one clk after the 0x41
// read that clears RXRDY, so case (a) measures consecutive presentations one or two
// clk apart (not a tick) and case (b)/(e) find the chained read returning the NEXT
// key instead of the stale latch (HSB's modifier make/break stolen).

`timescale 1ns / 1ps

module tb_pc9821_kbd_pace;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // The scaled transfer tick. The DUT's real tick is SYS_CLOCK_HZ / 1280; this bench
  // overrides it so the interval is observable without simulating milliseconds.
  localparam integer TICK = 64;

  // ==== DUT ====
  pc9821_kbd #(
      .XFER_TICK_CYCLES(26'(TICK))
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

  integer errors = 0;
  integer timeout_count;
  integer i;
  integer gap;
  integer last_rx_time;
  reg [7:0] value;
  reg [7:0] peek;
  reg [7:0] chained;
  reg [7:0] collected [0:7];
  reg toggle = 0;

  // The delivery edge, independent of when the guest first notices it: RXRDY's rising
  // edge IS the presentation (status_reg[1] is set by the delivery fold). A four-event
  // burst can present its first byte while the later events are still being sent, so a
  // poll after the sends would understate the first interval by a few clocks.
  reg st_prev = 1'b0;
  integer rx_rise_time = 0;
  always @(posedge clk) begin
    #1;
    if (dut.status_reg[1] && !st_prev) rx_rise_time = $time;
    st_prev = dut.status_reg[1];
  end

  // ==== CHECKS ====

  task fail(input [8*160-1:0] message);
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

  // A raw 0x41 read: returns the data register and clears RXRDY (NP2kai
  // keyboard_i41: `status &= ~2`), exactly what a guest poll or the BIOS handler does.
  task read_raw(output [7:0] v);
    begin
      @(negedge clk);
      a0 = 0;
      cs = 1;
      rd = 1;
      #1 v = dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      rd = 0;
      #1;
    end
  endtask

  // Wait for RXRDY (the delivered-byte presentation) and return the `$time` at which
  // it is first observed, in ns.
  task wait_rx(input integer budget, output integer at);
    begin
      timeout_count = 0;
      while (!dut.status_reg[1] && timeout_count < budget) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      at = $time;
      if (!dut.status_reg[1]) fail("no keyboard byte presented within the budget");
      #1;
    end
  endtask

  task read_byte(input [7:0] expected);
    integer at;
    begin
      wait_rx(2 * TICK + 80, at);
      read_raw(value);
      if (value !== expected) begin
        $display("FAIL: keyboard byte got %02x want %02x @ %0t", value, expected, $time);
        errors = errors + 1;
      end
    end
  endtask

  // ==== STIMULUS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    // The firmware's own 8251 init: mode byte, then TxEN + RxE + RTS.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ---- (a) A host burst is presented one full tick apart. ----
    // Four host events within ~1 us (make A, break A, make W, break W). The guest reads
    // each presented byte; the NEXT presentation must not come before a transfer tick.
    send_key(1'b1, 1'b0, 8'h1C);   // A make  -> NEC 1D
    send_key(1'b0, 1'b0, 8'h1C);   // A break -> NEC 9D
    send_key(1'b1, 1'b0, 8'h1D);   // W make  -> NEC 11
    send_key(1'b0, 1'b0, 8'h1D);   // W break -> NEC 91
    // ...and read them in order, measuring when each becomes presentable.
    begin : burst
      reg [7:0] want [0:3];
      integer at;
      want[0] = 8'h1D; want[1] = 8'h9D; want[2] = 8'h11; want[3] = 8'h91;
      wait_rx(2 * TICK + 80, at);
      last_rx_time = rx_rise_time;
      read_raw(value);
      if (value !== want[0]) fail("burst byte 0 is not the first make (1D)");
      for (i = 1; i < 4; i = i + 1) begin
        wait_rx(3 * TICK + 80, at);
        gap = (rx_rise_time - last_rx_time) / 10;   // clk_sys cycles at the bench's 10 ns clock
        if (gap < TICK) begin
          $display("FAIL: burst byte %0d presented %0d clk after the previous one, not a transfer tick (%0d clk) @ %0t",
                   i, gap, TICK, $time);
          errors = errors + 1;
        end
        if (gap > TICK + 4) begin
          $display("FAIL: burst byte %0d presented %0d clk after the previous one, later than the tick (%0d clk) @ %0t",
                   i, gap, TICK, $time);
          errors = errors + 1;
        end
        last_rx_time = rx_rise_time;
        read_raw(value);
        if (value !== want[i]) begin
          $display("FAIL: burst byte %0d got %02x want %02x (lost or reordered) @ %0t",
                   i, value, want[i], $time);
          errors = errors + 1;
        end
      end
    end

    // Let the pacing timer drain so the next scenario starts from idle.
    repeat (TICK + 8) @(posedge clk);

    // ---- (b) HSB's peek + chained read both return the STALE latch. ----
    // Two host events back to back (make A then break A) leave one byte presentable and
    // one queued. The guest's interrupt hook peeks 0x41, then the chained handler reads
    // 0x41 again a few clk later; both must see the SAME byte. A third read inside the
    // same tick still must not reach the queued byte; after the tick it arrives.
    send_key(1'b1, 1'b0, 8'h1C);   // A make  -> 1D
    send_key(1'b0, 1'b0, 8'h1C);   // A break -> 9D (queued)
    begin : peek_case
      integer at;
      wait_rx(2 * TICK + 80, at);
      read_raw(peek);
      if (peek !== 8'h1D) fail("case (b): the first byte is not the make 1D");
      repeat (4) @(posedge clk);
      read_raw(chained);
      if (chained !== peek) begin
        $display("FAIL: the chained 0x41 read returned %02x, not the stale latch %02x (the peek consumed the next key) @ %0t",
                 chained, peek, $time);
        errors = errors + 1;
      end
      repeat (4) @(posedge clk);
      read_raw(chained);
      if (chained !== peek) begin
        $display("FAIL: an early 0x41 read returned %02x before the tick, not the stale latch %02x @ %0t",
                 chained, peek, $time);
        errors = errors + 1;
      end
      // The queued break arrives only after the tick, not "one clk after the read".
      read_byte(8'h9D);
    end

    // ---- (c) Ordinary typing (an idle longer than a tick) is unaffected. ----
    repeat (2000) @(posedge clk);   // ~31 ticks: the pacing timer is long expired
    begin : normal_typing
      integer at;
      send_key(1'b1, 1'b0, 8'h1C);  // A make -> 1D after a normal-typing gap
      // The first byte after idle is IMMEDIATE: the tick divider starts from zero, so
      // the presentation is the event pipeline's own few clocks, never a tick later.
      wait_rx(20, at);
      if (!dut.status_reg[1]) fail("case (c): an idle-time byte was delayed past its bound");
      read_raw(value);
      if (value !== 8'h1D) fail("case (c): the idle byte is not the make 1D");
      // ...and the same holds for the break of an ordinary keystroke.
      repeat (2000) @(posedge clk);
      send_key(1'b0, 1'b0, 8'h1C);  // A break -> 9D
      wait_rx(20, at);
      if (!dut.status_reg[1]) fail("case (c): a normal-typing byte was delayed past its bound");
      read_raw(value);
      if (value !== 8'h9D) fail("case (c): the normal-typing byte is not the break 9D");
    end

    // ---- (d) A slow guest that reads after each tick gets every byte in order. ----
    repeat (TICK + 8) @(posedge clk);
    send_key(1'b1, 1'b0, 8'h15);   // Q make  -> 10
    send_key(1'b0, 1'b0, 8'h15);   // Q break -> 90
    send_key(1'b1, 1'b0, 8'h24);   // E make  -> 12
    send_key(1'b0, 1'b0, 8'h24);   // E break -> 92
    read_byte(8'h10);
    read_byte(8'h90);
    read_byte(8'h12);
    read_byte(8'h92);

    // ---- (e) A realistic Shift+key overlap never loses a break under HSB's pattern. ----
    // Shift make, A make, A break, Shift break back to back (the overlap a modifier+key
    // press produces within one millisecond), while the guest runs a real image's INT
    // 09h pattern: peek 0x41, then chain into the BIOS handler that reads 0x41 again in
    // the same tick. Every byte must reach the guest exactly once, in order - including
    // the Shift break; under the pre-fix model the chained read steals the next byte and
    // the peek stream loses a make or a break, which is the stuck modifier.
    repeat (TICK + 8) @(posedge clk);
    send_key(1'b1, 1'b0, 8'h12);   // LShift make  -> 70
    send_key(1'b1, 1'b0, 8'h1C);   // A make       -> 1D
    send_key(1'b0, 1'b0, 8'h1C);   // A break      -> 9D
    send_key(1'b0, 1'b0, 8'h12);   // LShift break -> F0
    begin : modifier_overlap
      reg [7:0] want [0:3];
      integer at;
      integer got;
      want[0] = 8'h70; want[1] = 8'h1D; want[2] = 8'h9D; want[3] = 8'hF0;
      got = 0;
      for (i = 0; i < 4; i = i + 1) begin
        timeout_count = 0;
        while (!dut.status_reg[1] && timeout_count < 3 * TICK + 80) begin
          @(posedge clk);
          timeout_count = timeout_count + 1;
        end
        if (!dut.status_reg[1]) begin
          $display("FAIL: case (e): only %0d of 4 modifier bytes reached the guest (missing %02x) @ %0t",
                   got, want[i], $time);
          errors = errors + 1;
          i = 4;
        end else begin
          #1;
          read_raw(peek);
          collected[got] = peek;
          got = got + 1;
          repeat (4) @(posedge clk);
          read_raw(chained);
          if (chained !== peek) begin
            $display("FAIL: case (e): chained read got %02x, not the stale %02x (a modifier byte was stolen) @ %0t",
                     chained, peek, $time);
            errors = errors + 1;
          end
          if (peek !== want[i]) begin
            $display("FAIL: case (e): byte %0d is %02x want %02x (order/modifier state corrupted) @ %0t",
                     i, peek, want[i], $time);
            errors = errors + 1;
          end
        end
      end
      if (!(collected[0] === 8'h70 && collected[1] === 8'h1D &&
            collected[2] === 8'h9D && collected[3] === 8'hF0))
        fail("case (e): the delivered stream is not Shift make, A make, A break, Shift break");
    end

    // ---- (f) The 8251 bit-3 keyboard reset clears the pace divider and keeps
    // the dedup epoch. The target design withdraws IRQ1 on the
    // keyboard line's falling edge; the 8251 model makes the bit-3
    // reset a KEYBOARD-record reset (NP2kai keyboard_resetsignal keeps
    // keystat.ref) rather than a physical-key reset. Both must hold in the
    // union: the reset re-arms the presentation (the first byte after it is
    // immediate, exactly as after a module reset), while the held-key dedup
    // survives so the held key's break still reaches the guest.
    repeat (TICK + 8) @(posedge clk);
    send_key(1'b1, 1'b0, 8'h1C);   // A make -> armed pace
    read_byte(8'h1D);
    if (dut.pace_div == 26'd0) fail("case (f): the pace divider is not armed after a delivery");
    begin : bit3_reset_join
      reg [6:0] epoch_before;
      integer at;
      epoch_before = dut.key_epoch;
      write_port(1'b1, 8'h3A);     // bit 3 set
      write_port(1'b1, 8'h32);     // bit 3 clear -> keyboard reset
      #1;
      if (dut.pace_div !== 26'd0)
        fail("case (f): the 8251 bit-3 reset did not clear the presentation pace");
      if (dut.key_epoch !== epoch_before)
        fail("case (f): the 8251 bit-3 reset bumped the dedup epoch (a held key's break would be swallowed)");
      write_port(1'b1, 8'h05);     // TxEN + RxEN
      send_key(1'b0, 1'b0, 8'h1C); // the held A's break -> 9D
      wait_rx(20, at);             // immediate: the reset cleared the tick, not a tick away
      if (!dut.status_reg[1])
        fail("case (f): the byte after a bit-3 reset was not presented immediately");
      read_raw(value);
      if (value !== 8'h9D)
        fail("case (f): the held key's break did not survive the bit-3 reset");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_PACE: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_PACE: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;   // 2 ms of simulated time: a few hundred scaled ticks
    $fatal(1, "TB_PC9821_KBD_PACE: TIMEOUT");
  end

endmodule
