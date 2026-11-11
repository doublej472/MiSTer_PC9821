// tb_pc9821_kbd_pipeline - the keyboard event pipeline's DEPTH as a pinned contract, and
// the event STREAM across it.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_KBD_PIPELINE:
// The keyboard's event pipeline depth is a PINNED CONTRACT, not a comment: a ps2_key toggle edge posts its FIFO byte on the THIRD clk_sys after the toggle (clk 1 = the translation ROM's registered read, clk 2 = the dedup table's clocked read, clk 3 = the event decision's enqueue), the deliver follows one clk later, and NOTHING is enqueued or delivered on the first two clk_sys. The event STREAM is unchanged across that pipeline: a burst of makes and breaks - including a duplicate make of a key pressed on the previous clk, a locking key, and a back-to-back make/break pair for one key - reaches the guest as exactly the same ordered byte sequence, so the T6 registers-to-MLAB trade moved the decision's cycle and nothing else.
//
// ---- the bench's own account of where this expectation comes from ----
// [source 1: the T6 trade and its approval]
// `key_down[0:127]` (the M2 mechanical-lock dedup array) was 208 ALMs / 268 ALUTs / 127
// registers of pc9821_kbd standalone - 46 % of the module, measured with
// tools/res_exp_map.py. Moving it into
// a block memory is a registers->memory trade with ONE structural consequence: a block
// RAM's read is registered, so the "is this key already down" comparison - and every signal
// derived from it - moves one clk_sys later. That latency is accepted
// (and wider: up to ~1 ms of added host->core input latency is acceptable for area,
// docs/trade-candidates.md), on the grounds that the keyboard is not on any hot path and
// the host's USB HID poll dominates the path by milliseconds.
//
// [source 2: why the depth is a contract and not a comment]
// Two existing benches were depth-sensitive and are RE-PINNED by the same change (one
// settle cycle -> two, with the approval cited in their comments):
//   * tb_pc9821_kbd.sv    - the FIFO-capacity and overrun checks after 17 send_key calls;
//   * tb_pc9821_kbd_reset.sv - the "3 queued bytes" count after 4 send_key calls;
// and tb_pc9821_kbd_reset_race.sv - the bit-3 reset vs a coincident event - moved with the
// event path, because the reset now has to meet the DECISION rather than the enqueue.
// A re-pinned value with no bench of its own is how a depth becomes folklore, so this bench
// states the number and fails on the pre-T6 RTL (that is its fail-first evidence: clk 2
// shows fifo_cnt == 1 there).
//
// [source 3: what "the same stream" means, and where it is checked]
// NP2kai io/serial.c is the reference for the byte shape: keyboard_callback delivers one
// byte per queued key event, make byte on press and |0x80 on release, and keystat.c's
// mechanical-lock path emits ONE alternating byte per physical press. The stream asserted
// below is that shape, in order, across the pipeline; the duplicate make is the M2 dedup
// (which must NOT emit a second byte) and the back-to-back make/break pair is the case the
// table's read-during-write bypass exists for: both events for one key land in ADJACENT
// clk_sys, so the second one's read would otherwise see the pre-write word and drop the
// break.

`default_nettype none

module tb_pc9821_kbd_pipeline;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // ==== DUT ====
  // Shrink the byte-presentation tick so back-to-back keys stay inside read_byte's
  // budget (the real tick is SYS_CLOCK_HZ / 1280; tb_pc9821_kbd_pace pins the rate).
  pc9821_kbd #(.XFER_TICK_CYCLES(26'd8)) dut (
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

  // One hps_io key event: a fresh ps2_key[10] toggle, two clk_sys wide, so consecutive
  // send_key calls put their stage-1 clk_sys ADJACENT - which is exactly the back-to-back
  // case the dedup table's bypass exists for.
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

  // The stream is asserted with NO byte in between: nothing else may arrive.
  task expect_silent(input [8*60-1:0] who);
    begin
      repeat (8) @(posedge clk);
      if (irq || (dut.fifo_cnt !== 5'd0)) begin
        $display("FAIL: %0s queued a byte (irq=%b fifo=%0d)", who, irq, dut.fifo_cnt);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;

    // The firmware's own init: mode byte, then TxEN+RxE+RTS.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ---- 1. THE DEPTH CONTRACT. Fail-first: on the pre-T6 RTL the byte lands one clk
    //         earlier and the clk-2 check below fires. ----
    // The ps2_key toggle edge is set here; the four posedges after it are the four clk_sys
    // this bench pins. `fifo_cnt` and `irq` are read after each one.
    @(negedge clk);
    toggle  = ~toggle;
    ps2_key = {toggle, 1'b1, 1'b0, 8'h1C};   // A make -> NEC 0x1D
    @(posedge clk); #1;                       // clk 1: rom_q / ps2_key_q load (stage 1a)
    if (dut.fifo_cnt !== 5'd0 || irq) begin
      fail("depth clk 1: the event already reached the FIFO (want stage 1 only)");
    end
    @(posedge clk); #1;                       // clk 2: the dedup table's read (stage 1b)
    if (dut.fifo_cnt !== 5'd0 || irq) begin
      fail("depth clk 2: the event already reached the FIFO (want the table's read, not the decision)");
    end
    @(posedge clk); #1;                       // clk 3: THE DECISION, the enqueue
    if (dut.fifo_cnt !== 5'd1) begin
      $display("FAIL: depth clk 3: the enqueue is not there (fifo_cnt=%0d)", dut.fifo_cnt);
      errors = errors + 1;
    end
    if (irq) fail("depth clk 3: the deliver is on the enqueue's own clk (want one clk later)");
    @(posedge clk); #1;                       // clk 4: the deliver
    if (dut.rx_latch !== 8'h1D || !irq) begin
      $display("FAIL: depth clk 4: rx_latch=%02x irq=%b, want 1D/1 (the deliver)", dut.rx_latch, irq);
      errors = errors + 1;
    end
    read_byte(8'h1D);
    send_key(1'b0, 1'b0, 8'h1C);   // ... and the break, so the table starts the stream empty
    read_byte(8'h9D);
    $display("KBD_PIPE: the event lands on clk 3 and delivers on clk 4 (pre-T6: clk 2 / clk 3)");

    // ---- 2. THE STREAM ACROSS THE PIPELINE. Makes, a duplicate make, then the breaks, all
    //         queued with no read in between so the ORDER is what is asserted. ----
    send_key(1'b1, 1'b0, 8'h1D);   // W  -> 0x11
    send_key(1'b1, 1'b0, 8'h1C);   // A  -> 0x1D
    send_key(1'b1, 1'b0, 8'h1D);   // W AGAIN on the next clk: a duplicate make -> NO byte
    send_key(1'b1, 1'b0, 8'h24);   // E  -> 0x12
    send_key(1'b1, 1'b0, 8'h76);   // Esc -> 0x00
    send_key(1'b1, 1'b0, 8'h16);   // 1  -> 0x01
    send_key(1'b1, 1'b0, 8'h1E);   // 2  -> 0x02
    send_key(1'b0, 1'b0, 8'h1D);   // W break  -> 0x91
    send_key(1'b0, 1'b0, 8'h1C);   // A break  -> 0x9D
    send_key(1'b0, 1'b0, 8'h24);   // E break  -> 0x92
    send_key(1'b0, 1'b0, 8'h76);   // Esc break -> 0x80
    send_key(1'b0, 1'b0, 8'h16);   // 1 break  -> 0x81
    send_key(1'b0, 1'b0, 8'h1E);   // 2 break  -> 0x82
    @(posedge clk); @(posedge clk); #1;   // the depth contract: the last event lands here
    if (dut.fifo_cnt !== 5'd11) begin
      $display("FAIL: stream: %0d bytes queued, want 11 (12 events - the delivered first - the dropped duplicate)",
               dut.fifo_cnt);
      errors = errors + 1;
    end
    read_byte(8'h11);              // ...and the stream itself, in order
    read_byte(8'h1D);
    read_byte(8'h12);
    read_byte(8'h00);
    read_byte(8'h01);
    read_byte(8'h02);
    read_byte(8'h91);
    read_byte(8'h9D);
    read_byte(8'h92);
    read_byte(8'h80);
    read_byte(8'h81);
    read_byte(8'h82);
    $display("KBD_PIPE: the make/break stream is byte-for-byte the pre-T6 stream, in order");

    // ---- 3. The locking key: ONE toggle per PHYSICAL press, with the duplicate make on
    //         the very next clk (the bypass case again) and both releases silent. ----
    send_key(1'b1, 1'b0, 8'h58);   // CAPS on -> make 0x71
    read_byte(8'h71);
    send_key(1'b1, 1'b0, 8'h58);   // duplicate make, next clk
    send_key(1'b0, 1'b0, 8'h58);   // release: silent
    send_key(1'b0, 1'b0, 8'h58);   // duplicate release: silent
    expect_silent("a duplicate CAPS make / release pair");
    send_key(1'b1, 1'b0, 8'h58);   // CAPS off -> break 0xF1, the second and LAST toggle
    read_byte(8'hF1);
    send_key(1'b0, 1'b0, 8'h58);
    expect_silent("a CAPS release after the toggle");

    // ---- 4. The 8251 bit-3 keyboard reset KEEPS the dedup state (NP2kai
    //         keyboard_resetsignal keeps keystat.ref): a key that was DOWN
    //         before it is not re-announced by a duplicate make, and its own
    //         break still matches. ----
    send_key(1'b1, 1'b0, 8'h12);   // LShift make -> 0x70
    read_byte(8'h70);
    write_port(1'b1, 8'h3A);       // bit 3 set ...
    write_port(1'b1, 8'h32);       // ... then cleared: the ITF's keyboard reset
    write_port(1'b1, 8'h05);       // re-enable RX/TX (the reset does not touch them)
    send_key(1'b1, 1'b0, 8'h12);   // the SAME key, NO break in between
    expect_silent("a duplicate make after the bit-3 reset");
    send_key(1'b0, 1'b0, 8'h12);   // its break still reaches the guest
    read_byte(8'hF0);
    $display("KBD_PIPE: the bit-3 reset keeps the dedup state (duplicate make silent, held break delivered)");

    // ---- 5. The sweep is running in the background over the same table. It must not have
    //         disturbed any of the above: a NEW press after that break still delivers, and
    //         a duplicate of it while held is still silent. ----
    send_key(1'b1, 1'b0, 8'h12);   // a real new press
    read_byte(8'h70);
    send_key(1'b1, 1'b0, 8'h12);   // duplicate, no break
    expect_silent("a duplicate LShift make with the sweep running");
    send_key(1'b0, 1'b0, 8'h12);   // its break
    read_byte(8'hF0);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_PIPELINE: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_PIPELINE: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_KBD_PIPELINE: TIMEOUT");
  end

endmodule

`default_nettype wire
