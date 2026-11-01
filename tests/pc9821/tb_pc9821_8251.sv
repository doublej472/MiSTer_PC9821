// tb_pc9821_8251 — conformance audit of every uPD8251A behaviour the PC-98
// keyboard interface exposes, against NP2kai io/serial.c + keystat.c, qemu-pc98
// hw/input/pc98-kbd.c and the NEC uPD8251A datasheet.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_8251:
// The keyboard's uPD8251A is pinned against NP2kai io/serial.c + keystat.c, qemu-pc98 hw/input/pc98-kbd.c and the NEC uPD8251A datasheet, every check carrying its reference: status bits DSR/TXEMPTY/TXRDY forced (0x85) and SYNDET 0, RXRDY set by a delivery and cleared by the 0x41 read (including a read while RXRDY=0, which returns the last latch as both software references do), RxEN/RTS not gating reception, delivery winning a same-clk read without losing the new byte, TxEN gating the 0x41 command path, unknown commands answered 0xFC, 0x95/0x9C/0x9D/0x96/0x9F/0x99 answered as the references do, an unrecognized 0x9D LED parameter answered with NO second byte (NP2kai and QEMU both ignore it), 0x9C 0x70 inhibiting typematic repeat, the bit-3 keyboard reset flushing the receive side while KEEPING the held-key state so the held key's break still reaches the guest, and the FIFO's 16-entry overrun semantics. The known, recorded divergences (the 8251's mode-after-IR phase, the die's overwrite-old overrun, 0x99's QEMU-vs-NP2kai answer, the 0x96 ID byte QEMU reports as 0x85, and TxRDY/TXEMPTY forced) are printed as WAIVED lines with both values instead of being asserted.

module tb_pc9821_8251;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;
  reg        bios_setup = 0;

  // ==== DUT ====
  // Shrink the typematic delay/interval so the 0x9C 0x70 section is observable
  // in a few microseconds. The RATIO is irrelevant to the semantics under test;
  // the production defaults (NP2kai's 500 ms / 50 ms) are tb_pc9821_kbd_repeat's.
  // The presentation tick is shrunk for the same reason (tb_pc9821_kbd_pace's
  // TICK does the same): this bench pins the 8251's VALUE/status semantics, and
  // the production 80 MHz / 1280 = 62,500-cycle tick would make it simulate
  // milliseconds per byte. The pacing itself is tb_pc9821_kbd_pace's claim.
  localparam integer TICK = 4;
  pc9821_kbd #(
      .REPEAT_DELAY(26'd400),
      .REPEAT_INTERVAL(26'd100),
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
      .bios_setup(bios_setup)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;
  integer i;

  // ==== CHECKS ====
  task fail(input [8*120-1:0] message);
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

  task do_reset;
    begin
      @(negedge clk);
      ps2_key = 0;
      rst_n   = 0;
      repeat (4) @(posedge clk);
      @(negedge clk);
      rst_n = 1;
      #1;
    end
  endtask

  // One-cycle 0x43 status read.
  task status_read(output [7:0] got);
    begin
      @(negedge clk);
      a0 = 1;
      cs = 1;
      rd = 1;
      #1 got = dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      rd = 0;
      #1;
    end
  endtask

  // One-cycle 0x41 data read. Does NOT wait for RXRDY, so it can be issued in
  // the cycle after a read (the concurrent-read case).
  task data_read(output [7:0] got);
    begin
      @(negedge clk);
      a0 = 0;
      cs = 1;
      rd = 1;
      #1 got = dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      rd = 0;
      #1;
    end
  endtask

  task wait_irq;
    begin
      timeout_count = 0;
      while (!irq && timeout_count < TICK + 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) fail("keyboard receive IRQ timeout");
    end
  endtask

  task read_byte(input [7:0] expected);
    begin
      wait_irq();
      data_read(value);
      if (value !== expected) begin
        $display("FAIL: keyboard byte got %02x want %02x", value, expected);
        errors = errors + 1;
      end
      if (irq) fail("data read did not clear IRQ");
    end
  endtask

  task expect_no_byte(input [8*72-1:0] who);
    begin
      repeat (8) @(posedge clk);
      #1;
      if (irq) begin
        $display("FAIL: %0s: an unexpected byte was delivered", who);
        errors = errors + 1;
      end
    end
  endtask

  task expect_status85(input [8*72-1:0] who);
    begin
      status_read(value);
      if ((value & 8'hC5) !== 8'h85) begin
        $display("FAIL: %0s: status %02x, DSR/TXEMPTY/TXRDY must be 111 (NP2kai i43 |0x85; PROBE.TXT 0043=85)",
                 who, value);
        errors = errors + 1;
      end
      if (value & 8'h40) begin
        $display("FAIL: %0s: SYNDET/BD bit 6 set in async mode (status %02x)", who, value);
        errors = errors + 1;
      end
    end
  endtask

  task config_tx_rx;
    begin
      write_port(1'b1, 8'h5E);   // mode: async, 8 data, no parity, 1 stop, x16
      write_port(1'b1, 8'h05);   // TxEN + RxEN
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;

    // =====================================================================
    // 1. RESET STATE (NP2kai keyboard_reset: data 0xFF, mode 0x5E; QEMU
    //    pc98_kbd_reset: status TXRDY|TXEMPTY|DSR, rx_latch 0xFF; machine
    //    capture docs/probes/PROBE.TXT `0041=9c 0043=85`).
    // =====================================================================
    data_read(value);
    if (value !== 8'hFF) fail("reset data latch is not FF (NP2kai keyboard_reset data=0xff)");
    expect_status85("reset status");
    if (dut.rx_enabled || dut.tx_enabled || !dut.rts)
      fail("reset command state is not RxEN=0/TxEN=0/RTS=1 (NP2kai keyboard_reset cmd=0)");

    // A data read while RXRDY is 0 returns the last latch and clears nothing:
    // NP2kai keyboard_i41 returns keybrd.data after `status &= ~2`; QEMU
    // pc98_kbd_data_read returns rx_latch; the datasheet's only rule is that a
    // fetch resets RxRDY.
    @(negedge clk);
    if (dut.status_reg[1]) fail("RXRDY set with no delivery");
    data_read(value);
    if (value !== 8'hFF) fail("read with RXRDY=0 did not return the last latch (NP2kai i41 returns keybrd.data)");
    expect_status85("read with RXRDY=0");

    config_tx_rx();

    // =====================================================================
    // 2. RxEN=0 / RTS=1 DO NOT GATE RECEPTION.
    //    NP2kai keyboard_callback gates only on `!(status & 2)`; the PC-98
    //    BIOS asserts RTS in every command byte (0x16 on each IRQ, BIOS.ROM
    //    @0x16670) and the machine still types, while QEMU's RTS/RxEN gate is
    //    the divergence recorded in the WAIVED line below.
    // =====================================================================
    write_port(1'b1, 8'h21);   // TxEN + RTS asserted, RxEN clear
    send_key(1'b1, 1'b0, 8'h15);   // Q
    read_byte(8'h10);
    write_port(1'b1, 8'h05);
    send_key(1'b0, 1'b0, 8'h15);
    read_byte(8'h90);              // Q break
    $display("WAIVED: QEMU pc98-kbd.c gates the receive pump on rx_enabled and !rts; NP2kai io/serial.c does not, and RTS is a modem output rather than a receiver enable on the die, so the model follows NP2kai there. RxEN is different: the die's command bit 2 does disable the receiver, and no capture tests a key with RxEN=0 (the BIOS and the ITF leave it set in normal operation), so the model's NP2kai-style no-gate is a recorded divergence for a guest that deliberately receives with the receiver off.");

    // =====================================================================
    // 3. A DATA READ CONCURRENT WITH A DELIVERY.
    //    status_reg[1] gates delivery in both references (NP2kai
    //    keyboard_callback `if (!(keybrd.status & 2))`), so a byte that becomes
    //    deliverable in the same clk as a 0x41 read must be delivered, not
    //    lost, and the read must return the PREVIOUS latch (the read strobe
    //    samples the register before the edge loads it).
    // =====================================================================
    send_key(1'b1, 1'b0, 8'h1C);   // A make -> delivered to rx_latch
    wait_irq();
    send_key(1'b1, 1'b0, 8'h1D);   // W make -> queues behind the unread A
    // Let A's presentation tick expire first, so the delivery decision under test
    // is the read itself and not the pace (the pacing is tb_pc9821_kbd_pace's
    // claim); W still cannot deliver while A is unread.
    repeat (TICK + 2) @(posedge clk); #1;
    if (dut.fifo_cnt !== 5'd1) fail("the concurrent-read setup did not queue exactly one byte");
    // Hold the data-read strobe across THREE cycles: the read of A, the cycle
    // in which the delivery decision fires, and the cycle the delivered byte is
    // available. dout is sampled before each edge.
    @(negedge clk);
    a0 = 0; cs = 1; rd = 1;
    #1;
    if (dout !== 8'h1D) fail("concurrent-read: the first read is not A (0x1D)");
    @(posedge clk);              // edge 1: RXRDY clears
    #1;
    if (dut.status_reg[1]) fail("concurrent-read: RXRDY did not clear on the read");
    if (dout !== 8'h1D) fail("concurrent-read: the read in the delivery clk did not return the previous latch");
    @(posedge clk);              // edge 2: the delivery loads W and sets RXRDY
    #1;
    if (!dut.status_reg[1]) fail("concurrent-read: the same-clk delivery was lost (RXRDY clear)");
    if (dout !== 8'h11) fail("concurrent-read: the delivered W byte (0x11) was not loaded");
    @(posedge clk);              // edge 3: the read consumes W
    @(negedge clk);
    cs = 0; rd = 0;
    #1;
    if (irq) fail("concurrent-read: IRQ survived the read that consumed W");
    send_key(1'b0, 1'b0, 8'h1D);
    read_byte(8'h91);
    send_key(1'b0, 1'b0, 8'h1C);
    read_byte(8'h9D);

    // =====================================================================
    // 4. THE TX/COMMAND PATH (0x41 write with TxEN).
    //    NP2kai keyboard_o41: TxEN (`cmd & 1`) set -> keystat_ctrlsend(dat),
    //    clear -> keybrd.mode = dat (no response). Every unknown opcode and
    //    unrecognized two-byte sequence that a reference rejects is 0xFC;
    //    keystat.c's 0x9C/0x9D ACK both bytes. QEMU's 0x96 ID byte is 0x85,
    //    NP2kai's (and this model's) is 0x83.
    // =====================================================================
    // TxEN=0: a 0x41 write is a mode byte in NP2kai, produces no reply.
    write_port(1'b1, 8'h04);       // TxEN=0 (RxEN=1)
    write_port(1'b0, 8'h9F);       // must be swallowed
    expect_no_byte("0x41 write with TxEN=0 answered");
    config_tx_rx();

    // Unknown opcode -> 0xFC (NP2kai keystat_ctrlsend default; QEMU default).
    write_port(1'b0, 8'h55);
    read_byte(8'hFC);
    expect_status85("after an unknown command");

    // 0x96 keyboard ID: NP2kai FA A0 83 (keystat_ctrlsend case 0x96).
    write_port(1'b0, 8'h96);
    read_byte(8'hFA);
    read_byte(8'hA0);
    read_byte(8'h83);
    $display("WAIVED: QEMU pc98-kbd.c answers 0x96 with FA A0 85; NP2kai keystat.c answers FA A0 83 and the model follows NP2kai (the primary software reference).");

    // 0x9F identity: NP2kai/QEMU/the ITF's BANK4@0x1992 probe: FA A0 80.
    write_port(1'b0, 8'h9F);
    read_byte(8'hFA);
    read_byte(8'hA0);
    read_byte(8'h80);

    // 0x99: the model answers QEMU's FA FB (a PC-9801-119 "not ready" report);
    // NP2kai has no 0x99 case and would answer FC. WAIVED, then asserted as the
    // model's recorded value so a change is visible.
    write_port(1'b0, 8'h99);
    read_byte(8'hFA);
    read_byte(8'hFB);
    $display("WAIVED: 0x99 is FA FB here (QEMU pc98-kbd.c); NP2kai keystat.c has no 0x99 case and answers FC. No capture arbitrates.");

    // 0x9C two-byte command: ACK at the opcode and at the parameter (NP2kai
    // keystat_ctrlsend case 0x9c queues FA on both; the Xe10's PC-9801-119
    // keyboard logs `s9C r00FA s70 r00FA`).
    write_port(1'b0, 8'h9C);
    read_byte(8'hFA);
    write_port(1'b0, 8'h21);
    read_byte(8'hFA);

    // 0x9D 0x60 LED query: NP2kai FA then 0x70|getledstat (KANA bit 3, CAPS
    // bit 2; LOCK_NUM bit 0 as the PC-98 LED command defines it).
    write_port(1'b0, 8'h9D);
    read_byte(8'hFA);
    write_port(1'b0, 8'h60);
    read_byte(8'hFA);
    read_byte(8'h70);

    // 0x9D 0x7x LED set: FA at the opcode and FA at the parameter, then the
    // query reports the new state (NP2kai stores bits 3/2/0).
    write_port(1'b0, 8'h9D);
    read_byte(8'hFA);
    write_port(1'b0, 8'h74);       // CAPS
    read_byte(8'hFA);
    write_port(1'b0, 8'h9D);
    read_byte(8'hFA);
    write_port(1'b0, 8'h60);
    read_byte(8'hFA);
    read_byte(8'h74);
    write_port(1'b0, 8'h9D);
    read_byte(8'hFA);
    write_port(1'b0, 8'h70);
    read_byte(8'hFA);

    // 0x9D with an UNRECOGNIZED parameter: NP2kai keystat_ctrlsend case 0x9d
    // does nothing (no ACK, no NACK); QEMU pc98-kbd.c sends no rejection byte.
    // The opcode's FA is the ONLY reply. FAIL-FIRST: the old model loaded 0xFC
    // here, which the next read would hand the guest as a command error/key.
    write_port(1'b0, 8'h9D);
    read_byte(8'hFA);
    write_port(1'b0, 8'h00);       // not 0x60, not 0x7x
    expect_no_byte("0x9D 0x00: an unrecognized LED parameter was answered");
    // ...and the receive side is still usable and not desynchronized.
    send_key(1'b1, 1'b0, 8'h16);   // 1
    read_byte(8'h01);
    send_key(1'b0, 1'b0, 8'h16);
    read_byte(8'h81);

    // 0x95 0x03 (enable Windows/Menu keys): two ACKs (NP2kai case 0x95).
    write_port(1'b0, 8'h95);
    read_byte(8'hFA);
    write_port(1'b0, 8'h03);
    read_byte(8'hFA);

    // =====================================================================
    // 5. STATUS BITS. DSR(7)/TXEMPTY(2)/TXRDY(0) are forced 1 by NP2kai
    //    keyboard_i43 (`return keybrd.status | 0x85`) and the machine capture
    //    PROBE.TXT reads 0x85; SYNDET(6) is 0 in async mode with no break.
    //    TxRDY/TXEMPTY never drop (the die drops TXEMPTY on a data write and
    //    raises TxRDY when the transmitter is ready), which is the WAIVED
    //    divergence below.
    // =====================================================================
    write_port(1'b0, 8'h9F);       // queue a response
    read_byte(8'hFA);
    read_byte(8'hA0);
    read_byte(8'h80);
    expect_status85("status after a command burst");
    $display("WAIVED: the die clears TXEMPTY when 0x41 is written and drives TXRDY from the transmitter (datasheet note 2, TxRDY status = DB Buffer Empty - CTS*TxE); NP2kai i43 and the machine's 0043=85 capture force both high, and the model follows them (a guest that polls TXEMPTY, e.g. the ITF's 0x4F98 helper, always proceeds).");

    // =====================================================================
    // 6. THE INTERNAL RESET (command bit 6).
    //    The die returns to AWAIT_MODE (datasheet: "a reset operation ... will
    //    cause the 8251A to interpret the next control write ... as a mode
    //    instruction") and QEMU pc98-kbd.c does the same (cfg_phase =
    //    CFG_AWAIT_MODE). NP2kai keyboard_o43 stores the byte as the command and
    //    ignores bit 6. The model clears the enables like a reset but keeps
    //    every 0x43 write a command, i.e. it is lenient in NP2kai's direction.
    //    Assert the enables clear (all references agree IR disables them) and
    //    record the phase divergence.
    // =====================================================================
    config_tx_rx();
    if (!dut.rx_enabled || !dut.tx_enabled) fail("setup did not enable RX/TX before IR");
    write_port(1'b1, 8'h40);       // IR
    if (dut.rx_enabled || dut.tx_enabled || !dut.rts)
      fail("IR (command bit 6) did not clear RxEN/TxEN and set RTS (datasheet, QEMU CFG_AWAIT_MODE)");
    expect_status85("status after IR");
    $display("WAIVED: after IR the die and QEMU pc98-kbd.c require the next 0x43 write to be a MODE word; NP2kai and this model keep treating every 0x43 write as a command. Every async mode word has bit 6 set, so the model's IR branch swallows the mode and the following command works - the standard `IR, 0x5E, 0x05` sequence is equivalent, and changing the phase would risk every guest (owner review).");
    config_tx_rx();

    // =====================================================================
    // 7. THE BIT-3 KEYBOARD RESET (the ITF's 0x3A -> 0x32 pair,
    //    BANK4@0x04BEA/0x04BF6; NP2kai keyboard_o43 -> keyboard_resetsignal).
    //    It discards the receive record (status, IRQ, both queues) but NOT the
    //    physical key state: NP2kai keeps keystat.ref and keystat_resendstat
    //    re-announces held keys; only the repeat buffer is dropped.
    // =====================================================================
    config_tx_rx();
    send_key(1'b1, 1'b0, 8'h1C);   // A down, read
    read_byte(8'h1D);
    send_key(1'b1, 1'b0, 8'h1D);   // W down, unread: the reset must flush it
    wait_irq();                    // presented after A's pace tick (tb_pc9821_kbd_pace)
    write_port(1'b1, 8'h3A);       // bit 3 set
    if (!dut.status_reg[1]) fail("a bit-3 write without the 1->0 transition cleared RXRDY");
    write_port(1'b1, 8'h32);       // bit 3 clear -> KEYBOARD RESET
    if (dut.status_reg[1]) fail("bit-3 reset left RXRDY set (NP2kai keyboard_resetsignal status=0)");
    if (irq) fail("bit-3 reset left the receive IRQ asserted");
    if (dut.fifo_cnt !== 5'd0) fail("bit-3 reset did not discard the queued W byte (NP2kai buffers=0)");
    config_tx_rx();
    // THE HELD A's BREAK MUST STILL ARRIVE. FAIL-FIRST: the old model bumped
    // the dedup epoch on this reset, so key_down_now was false, normal_break
    // did not fire, and the guest - which was told A was down and whose state
    // the 8251 reset does not touch - never saw the release: the key stuck.
    send_key(1'b0, 1'b0, 8'h1C);
    read_byte(8'h9D);
    $display("WAIVED: NP2kai keyboard_resetsignal -> keystat_resendstat RE-ANNOUNCES every held key after the reset; this model keeps the held state (so the break matches) but does not re-send, because the 8251 reset does not clear the guest's own key table and a resend walk would re-announce a key pressed during it. The one cost is a make still queued in the receive buffer at the reset.");
    // A re-delivered make (USB resync) is still the same physical press: the
    // M2 dedup must suppress it even after the reset.
    send_key(1'b1, 1'b0, 8'h1C);
    read_byte(8'h1D);
    send_key(1'b1, 1'b0, 8'h1C);
    expect_no_byte("a duplicate make after the bit-3 reset");
    send_key(1'b0, 1'b0, 8'h1C);
    read_byte(8'h9D);
    // The reset still abandons a half-written command (NP2kai keystat_ctrlreset
    // reqparam=0): 0x9D opcode, reset, then 0x9F must be a command, not 0x9D's
    // parameter.
    write_port(1'b0, 8'h9D);
    read_byte(8'hFA);
    write_port(1'b1, 8'h3A);
    write_port(1'b1, 8'h32);
    config_tx_rx();
    write_port(1'b0, 8'h9F);
    read_byte(8'hFA);
    read_byte(8'hA0);
    read_byte(8'h80);

    // =====================================================================
    // 8. 0x9C 0x70 INHIBITS TYPEMATIC REPEAT.
    //    Protocol: tmk_keyboard wiki PC-9801-Keyboard, "Inhibiting key
    //    repeating 0x9C 0x70"; the Xe10's PC-9801-119 ACKs both bytes. NP2kai
    //    stores it as keyctrl.keyrep and keystat_down refuses a repeat when it
    //    is 0x70 (its keyrepeat_proc ignores the value - the gap this pins).
    //    Any other parameter re-enables repeating.
    // =====================================================================
    config_tx_rx();
    write_port(1'b0, 8'h9C);
    read_byte(8'hFA);
    write_port(1'b0, 8'h70);
    read_byte(8'hFA);
    send_key(1'b1, 1'b0, 8'h1C);   // A held
    read_byte(8'h1D);
    repeat (1200) @(posedge clk);  // 3x REPEAT_DELAY
    #1;
    if (irq) fail("0x9C 0x70 did not inhibit typematic repeat (a break+make pair appeared)");
    write_port(1'b0, 8'h9C);
    read_byte(8'hFA);
    write_port(1'b0, 8'h21);       // any other parameter re-enables
    read_byte(8'hFA);
    repeat (430) @(posedge clk);   // > REPEAT_DELAY, < DELAY+INTERVAL
    read_byte(8'h9D);              // the repeat pair: break ...
    read_byte(8'h1D);              // ... then make
    $display("INFO: 0x9C repeat pair seen at %0t (rep_pend=%0d fifo=%0d)", $time, dut.rep_pend, dut.fifo_cnt);
    // Break the key IMMEDIATELY: the next pair is one REPEAT_INTERVAL away.
    send_key(1'b0, 1'b0, 8'h1C);
    read_byte(8'h9D);
    // ...and after the break the engine is quiet again.
    repeat (600) @(posedge clk);
    if (irq) begin
      $display("INFO: quiet check irq=1 rx_latch=%02x fifo=%0d rep_key=%02x rep_pend=%0d timer=%0d",
               dut.rx_latch, dut.fifo_cnt, dut.rep_key, dut.rep_pend, dut.rep_timer);
      fail("typematic kept repeating after the key's break");
    end

    // =====================================================================
    // 9. OVERRUN / OE (the FIFO model).
    //    NP2kai keyboard_send: a full buffer drops the NEW byte and sets
    //    status 0x10; QEMU kbd_enqueue does the same at 256 entries; the die's
    //    1-byte RBR instead overwrites the OLD character and sets OE (datasheet:
    //    "the previously received character is overwritten and lost"). The
    //    model follows the two software references (16 entries), and the die's
    //    direction is the WAIVED divergence.
    // =====================================================================
    do_reset;
    config_tx_rx();
    send_key(1'b1, 1'b0, 8'h76);   // Esc: delivered, RXRDY stays set
    // 16 more distinct keys, none of them typematic-sensitive within this burst.
    send_key(1'b1, 1'b0, 8'h75);   // Up
    send_key(1'b1, 1'b0, 8'h16);   // 1
    send_key(1'b1, 1'b0, 8'h1E);   // 2
    send_key(1'b1, 1'b0, 8'h26);   // 3
    send_key(1'b1, 1'b0, 8'h25);   // 4
    send_key(1'b1, 1'b0, 8'h2E);   // 5
    send_key(1'b1, 1'b0, 8'h36);   // 6
    send_key(1'b1, 1'b0, 8'h3D);   // 7
    send_key(1'b1, 1'b0, 8'h3E);   // 8
    send_key(1'b1, 1'b0, 8'h46);   // 9
    send_key(1'b1, 1'b0, 8'h45);   // 0
    send_key(1'b1, 1'b0, 8'h05);   // F1 (non-repeatable)
    send_key(1'b1, 1'b0, 8'h06);   // F2
    send_key(1'b1, 1'b0, 8'h04);   // F3
    send_key(1'b1, 1'b0, 8'h0C);   // F4
    send_key(1'b1, 1'b0, 8'h03);   // F5
    repeat (4) @(posedge clk); #1;
    if (dut.fifo_cnt !== 5'd16) fail("FIFO did not reach capacity 16 (NP2kai KB_BUF is 128; this is the model's depth)");
    send_key(1'b1, 1'b0, 8'h0B);   // the 17th key: overflow
    repeat (4) @(posedge clk); #1;
    status_read(value);
    if (!(value & 8'h10)) fail("a byte arriving with the receive side full did not set OE (NP2kai keyboard_send status|=0x10)");
    if (dut.fifo_cnt !== 5'd16) fail("the full FIFO changed depth on an overrun");
    // The error clear (bit 4) clears OE without touching RXRDY (NP2kai o43).
    write_port(1'b1, 8'h11);       // ER, TxEN
    status_read(value);
    if (value & 8'h10) fail("command bit 4 (ER) did not clear OE (NP2kai keyboard_o43)");
    if (!(value & 8'h02)) fail("ER cleared RXRDY: the unread byte is still there");
    $display("WAIVED: the die's 1-byte receiver OVERWRITES the previously received character on overrun (uPD8251A datasheet, OE); NP2kai (KB_BUF=128) and QEMU (256) drop the NEW byte, and this model follows them. Only a guest 17 bytes behind ever sees this, so changing the direction is a maintainer decision (it would preserve releases over old makes).");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_8251: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_8251: FAIL (%0d errors)", errors);
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_8251: TIMEOUT");
  end

endmodule
