// tb_pc9821_kbd_overrun_break - a full receive queue never loses a key's break.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_KBD_OVERRUN_BREAK: with the guest not reading 0x41, a full key queue never strands a key down: a key held until typematic repeat has filled the queue and then released, ten taps of distinct keys queued behind an unread byte, and ten keys held at once and then released all drain to a stream in which the first eight taps and the first seven held keys (each set at most 16 bytes, the queue's depth) arrive whole and every key the guest saw made is also broken (its last byte a break, makes and breaks equal per key), with OE still raised for a tap or held key's make the full queue refused and the drain ending on an empty queue, so a model that drops the newest byte even when it is a break - leaving the guest's last byte for the key a make - fails here.

// ---- where the expectation comes from ----
//   undoc98vol2 io_kb.txt, port 0043h status bit 4 (OE): it does not occur as long as the
//     keyboard handshake is kept - the keyboard holds what it has to send until RDY#, so the
//     real interface loses no byte the keyboard produced and a real keyboard never leaves a
//     released key with a make as its last code. Which of the keyboard's OWN bytes a real
//     keyboard drops when its internal buffer fills is not captured; this bench asserts only
//     the consistency of the stream the guest drains, not which makes were refused.
//   NP2kai io/serial.c keyboard_send: a byte that does not fit sets status 0x10 (OE).
//   The stream's grammar (a make 0x00-0x7F, its break with bit 7 set, typematic as a break then
//     a make) is NP2kai keystat.c's (keystat_down / keystat_up / keyrepeat_proc).
// FAIL-FIRST: on the tree before the fix the break of the typematic key and of the last tapped
// key arrive with the queue full and are dropped, so the drained stream ends on their makes
// (sections 1 and 2), and with ten keys held the breaks of the last held keys are dropped.

`default_nettype none

module tb_pc9821_kbd_overrun_break;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // ==== DUT ====
  // The transfer tick and the typematic window are shrunk (the real ones are SYS_CLOCK_HZ/1280,
  // 500 ms and 50 ms) so a queue full of repeats builds in a few thousand clocks.
  pc9821_kbd #(.XFER_TICK_CYCLES(26'd8), .REPEAT_DELAY(26'd100), .REPEAT_INTERVAL(26'd40)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .a0(a0), .wr(wr), .rd(rd), .din(din), .dout(dout),
      .irq(irq), .ps2_key(ps2_key)
  );

  integer errors = 0;
  integer timeout_count, i, n;
  reg [7:0] value;
  reg toggle = 0;
  integer makes [0:127];
  integer breaks[0:127];
  reg     last_break[0:127];
  reg     seen[0:127];
  reg     oe_seen;

  task fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The first keys of a section must arrive whole: their makes and breaks together are at most
  // 16 bytes, the receive queue's depth, so a queue that refused one of them lost a byte it had
  // room for (undoc98vol2 io_kb.txt 0043h bit 4: no byte is lost while the handshake is kept).
  task require_whole(input string what, input [6:0] code);
    begin
      if (makes[code] != 1 || breaks[code] != 1)
        fail($sformatf("%s: key %02x not delivered whole although the queue had room (%0d makes, %0d breaks)",
                       what, code, makes[code], breaks[code]));
    end
  endtask

  // ==== STIMULUS ====
  task write_port(input control_port, input [7:0] data);
    begin
      @(negedge clk);
      a0 = control_port; din = data; cs = 1; wr = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0; wr = 0;
    end
  endtask

  task send_key(input pressed, input [7:0] code);
    begin
      @(negedge clk);
      toggle  = ~toggle;
      ps2_key = {toggle, pressed, 1'b0, code};
      @(posedge clk);
      @(negedge clk);
      repeat (6) @(posedge clk);
    end
  endtask

  task status_read(output [7:0] v);
    begin
      @(negedge clk);
      a0 = 1; cs = 1; rd = 1;
      #1 v = dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0; rd = 0;
    end
  endtask

  // ==== CHECKS ====
  // Drain everything the guest can read, tallying the stream per key.
  task drain_and_check(input string what, input want_oe);
    begin
      for (i = 0; i < 128; i = i + 1) begin
        makes[i] = 0; breaks[i] = 0; last_break[i] = 1'b1; seen[i] = 1'b0;
      end
      status_read(value);
      oe_seen = value[4];
      n = 0;
      timeout_count = 0;
      while (timeout_count < 200) begin
        if (irq) begin
          @(negedge clk);
          a0 = 0; cs = 1; rd = 1;
          #1 value = dout;
          @(posedge clk);
          @(negedge clk);
          cs = 0; rd = 0;
          n = n + 1;
          seen[value[6:0]] = 1'b1;
          if (value[7]) begin breaks[value[6:0]] = breaks[value[6:0]] + 1; last_break[value[6:0]] = 1'b1; end
          else begin makes[value[6:0]] = makes[value[6:0]] + 1; last_break[value[6:0]] = 1'b0; end
          timeout_count = 0;
        end else begin
          @(posedge clk);
          timeout_count = timeout_count + 1;
        end
      end
      $display("%s: drained %0d bytes, OE=%0d, queue %0d", what, n, oe_seen, dut.fifo_cnt);
      // A refused key event raises OE; a typematic byte waits for room instead (it is
      // pushed only when it fits), so section 1 refuses nothing.
      if (want_oe && !oe_seen) fail({what, ": the full queue refused a byte but OE is clear"});
      if (dut.fifo_cnt != 0) fail({what, ": the queue did not drain"});
      for (i = 0; i < 128; i = i + 1) begin
        if (seen[i] && (!last_break[i] || makes[i] != breaks[i]))
          fail($sformatf("%s: key %02x left down in the guest (%0d makes, %0d breaks, last %0s)",
                         what, i, makes[i], breaks[i], last_break[i] ? "break" : "make"));
      end
      write_port(1'b1, 8'h15);          // ER: clear OE for the next section (TxEN, RxE kept)
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    repeat (4) @(posedge clk);

    // 1. W held, unread, until typematic has filled the queue; then released
    send_key(1'b1, 8'h1D);              // W make: delivered, left unread
    repeat (2000) @(posedge clk);       // ~47 repeat periods: far more than 16 bytes
    if (dut.fifo_cnt < 5'd14) fail("section 1: typematic did not fill the queue");
    send_key(1'b0, 8'h1D);              // W released with the queue full
    drain_and_check("typematic fill", 1'b0);

    // 2. ten taps behind an unread byte: the last tap's break meets a full queue
    send_key(1'b1, 8'h76); send_key(1'b0, 8'h76);          // Esc
    send_key(1'b1, 8'h16); send_key(1'b0, 8'h16);          // 1
    send_key(1'b1, 8'h1E); send_key(1'b0, 8'h1E);          // 2
    send_key(1'b1, 8'h26); send_key(1'b0, 8'h26);          // 3
    send_key(1'b1, 8'h25); send_key(1'b0, 8'h25);          // 4
    send_key(1'b1, 8'h2E); send_key(1'b0, 8'h2E);          // 5
    send_key(1'b1, 8'h36); send_key(1'b0, 8'h36);          // 6
    send_key(1'b1, 8'h3D); send_key(1'b0, 8'h3D);          // 7
    send_key(1'b1, 8'h3E); send_key(1'b0, 8'h3E);          // 8
    send_key(1'b1, 8'h46); send_key(1'b0, 8'h46);          // 9
    drain_and_check("taps", 1'b1);
    // the first eight taps (Esc, 1-7: 16 bytes) fit beside each other and must all arrive
    for (i = 0; i < 8; i = i + 1) require_whole("taps", i[6:0]);

    // 3. ten non-repeating keys held at once (F1-F10), then all released
    send_key(1'b1, 8'h05); send_key(1'b1, 8'h06); send_key(1'b1, 8'h04); send_key(1'b1, 8'h0C);
    send_key(1'b1, 8'h03); send_key(1'b1, 8'h0B); send_key(1'b1, 8'h83); send_key(1'b1, 8'h0A);
    send_key(1'b1, 8'h01); send_key(1'b1, 8'h09);
    send_key(1'b0, 8'h05); send_key(1'b0, 8'h06); send_key(1'b0, 8'h04); send_key(1'b0, 8'h0C);
    send_key(1'b0, 8'h03); send_key(1'b0, 8'h0B); send_key(1'b0, 8'h83); send_key(1'b0, 8'h0A);
    send_key(1'b0, 8'h01); send_key(1'b0, 8'h09);
    drain_and_check("ten held", 1'b1);
    // the first seven held keys (F1-F7, PC-98 0x62-0x68: 14 bytes) fit and must all arrive
    for (i = 0; i < 7; i = i + 1) require_whole("ten held", 7'h62 + i[6:0]);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_OVERRUN_BREAK: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_OVERRUN_BREAK: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_KBD_OVERRUN_BREAK: TIMEOUT");
  end

endmodule

`default_nettype wire
