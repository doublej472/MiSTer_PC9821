// tb_pc9821_kbd_repeat — typematic auto-repeat of a held key.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// A held key typematically auto-repeats: one break then one make after the delay, then a break+make pair every interval, until the key breaks; a released key stops and a KBEX_NONREP key never repeats (VF1, the modifiers SHIFT/CTRL/GRPH, the CAPS lock, F1-F10 and RWIN; APP has no key in this core - the keystat.tbl table leaves LWIN repeatable, and this bench pins that it repeats where RWIN does not). The delay (make to first repeat) and the interval (repeat to repeat) are measured against the parameters to within 12 clk, and a second instance elaborated at its DEFAULT parameters with a 2 kHz SYS_CLOCK_HZ measures the NP2kai defaults 500 ms and 50 ms (sdl/ini.c keyrepeat_delay / keyrepeat_interval) as 1000 and 100 clk to within 6.
//
// ---- where the expectation comes from ----
// [source 1: NP2kai keystat.c] keyrepeat_proc() re-sends `keyboard_send(keycode | 0x80)`
// then `keyboard_send(keycode)` -- a break followed by a make -- for the key on top of the
// repeat buffer, once the delay has elapsed and then once per interval.
// NP2kai's defaults are keyrepeat_delay = 500 ms and keyrepeat_interval = 50 ms
// (sdl/ini.c:951-952), which are this module's REPEAT_DELAY / REPEAT_INTERVAL parameters.
// [source 2: NP2kai keystat.tbl] kbexflag[] marks KBEX_NONREP; a key carrying it is sent
// straight through with no repeat bookkeeping (keystat.c:647).
//
// The delay and interval are parameters here so the bench runs in a few microseconds
// instead of seconds; the RATIO is not the subject, the sequence is.

`default_nettype none

module tb_pc9821_kbd_repeat;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // ==== DUT ====
  // 100 cycles to the first repeat, then 200 between repeats: long enough that a single
  // break+make pair is read before the next pair is pushed.
  pc9821_kbd #(
      // The presentation pace is shrunk so the repeat pair's break and make stay
      // inside read_byte's budget (the real tick is SYS_CLOCK_HZ / 1280).
      .XFER_TICK_CYCLES(26'd8),
      .REPEAT_DELAY(26'd100),
      .REPEAT_INTERVAL(26'd200)
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
      .ps2_key(ps2_key)
  );

  // A second instance at its DEFAULT REPEAT_DELAY / REPEAT_INTERVAL, elaborated at a 2 kHz
  // SYS_CLOCK_HZ so 500 ms is 1000 clk and 50 ms is 100 clk: a wrong default expression in the
  // module header shows here (the first instance overrides both).
  localparam integer D_HZ = 2000;
  reg        cs2 = 0;
  reg [10:0] ps2_key2 = 0;
  wire [7:0] dout2;
  wire       irq2;
  pc9821_kbd #(.SYS_CLOCK_HZ(D_HZ)) dut_def (
      .clk(clk), .rst_n(rst_n), .cs(cs2), .a0(a0), .wr(wr), .rd(rd), .din(din),
      .dout(dout2), .irq(irq2), .ps2_key(ps2_key2)
  );

  integer cyc;
  always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;

  integer errors = 0;
  integer timeout_count;
  integer t_make, t_rep1, t_rep2, i, j;
  integer t_def[0:2];
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
        $display("FAIL: no receive IRQ: got nothing, wanted %02x", expected);
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

  // Wait (up to `limit` clk) for the receive IRQ and return the clk it rose on.
  task wait_irq(input integer limit, output integer t);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < limit) begin
        @(posedge clk); #1;
        timeout_count = timeout_count + 1;
      end
      t = cyc;
    end
  endtask

  // A measured gap must equal the parameter to within one presentation tick (8 clk) plus the
  // event pipeline's few clk; the expected value is the parameter, never the measurement.
  task check_gap(input integer got, input integer want, input integer slack,
                 input [8*60-1:0] what);
    begin
      $display("%0s: %0d clk (want %0d)", what, got, want);
      if (got < want || got > want + slack) begin
        $display("FAIL: %0s took %0d clk, want %0d..%0d", what, got, want, want + slack);
        errors = errors + 1;
      end
    end
  endtask

  // A key that must NOT repeat: hold it far past delay + two intervals and demand silence.
  task expect_quiet(input integer cycles, input [8*60-1:0] who);
    begin
      repeat (cycles) @(posedge clk);
      if (irq || (dut.fifo_cnt != 5'd0)) begin
        $display("FAIL: %0s emitted a repeat (irq=%b fifo=%0d)", who, irq, dut.fifo_cnt);
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
    // The Windows keys (0x77/0x78) are sent only after the extended key setting 0x95 0x03
    // (undoc98vol2 io_kb.txt command 95h; NP2kai keystat.c skips keycodes >= 0x75 while
    // kbdtype < 3); tb_pc9821_kbd_winkeys pins the gate, this bench needs the keys live.
    write_port(1'b0, 8'h95);  read_byte(8'hfa);
    write_port(1'b0, 8'h03);  read_byte(8'hfa);

    // ---- 1. A held key repeats break+make after the delay, then once per interval. ----
    //        The delay is timed from the make's arrival to the first repeat's, the interval
    //        between the two repeats' breaks.
    send_key(1'b1, 1'b0, 8'h1D);
    wait_irq(40, t_make);         read_byte(8'h11);   // W make, delivered once
    wait_irq(400, t_rep1);        read_byte(8'h91);   // ...the first repeat: break ...
    read_byte(8'h11);                                 // ...then make. That pair IS the repeat.
    check_gap(t_rep1 - t_make, 100, 12, "make to first repeat (REPEAT_DELAY 100)");
    wait_irq(400, t_rep2);        read_byte(8'h91);   // ...and it keeps coming ...
    read_byte(8'h11);
    check_gap(t_rep2 - t_rep1, 200, 12, "repeat to repeat (REPEAT_INTERVAL 200)");

    // ---- 2. The key's own break stops it. ----
    send_key(1'b0, 1'b0, 8'h1D);  read_byte(8'h91);   // W break
    expect_quiet(600, "a released key");              // far past delay + interval

    // ---- 3. A non-repeatable key never repeats: LShift (NEC SHIFT 0x70). ----
    send_key(1'b1, 1'b0, 8'h12);  read_byte(8'h70);   // LShift make
    expect_quiet(700, "LShift (KBEX_NONREP)");
    send_key(1'b0, 1'b0, 8'h12);  read_byte(8'hF0);

    // ---- 4. A key released inside the delay emits no repeat at all. ----
    send_key(1'b1, 1'b0, 8'h16);  read_byte(8'h01);   // '1' make
    send_key(1'b0, 1'b0, 8'h16);  read_byte(8'h81);   // released well before REPEAT_DELAY
    expect_quiet(600, "a key released inside the delay");

    // ---- 5. The Win cluster: LWIN REPEATS, RWIN does not (keystat.tbl). ----
    // NP2kai's KBEX_NONREP set is 0x62-0x6B, 0x70-0x74, 0x78, 0x79 and 0x7D: the
    // 0x70 row ends at CTRL (0x74), so 0x77 (left Win) carries no flag, and the
    // 0x78 row is RWIN/APP. The old 0x77..0x79 range here made LWIN silent.
    send_key(1'b1, 1'b1, 8'h1F);  read_byte(8'h77);   // left Win make (extended 0x1F)
    repeat (130) @(posedge clk);                      // > REPEAT_DELAY (100)
    read_byte(8'hF7);                                 // the repeat: break ...
    read_byte(8'h77);                                 // ...then make
    send_key(1'b0, 1'b1, 8'h1F);  read_byte(8'hF7);   // its own break stops it
    expect_quiet(600, "a released left Win");
    send_key(1'b1, 1'b1, 8'h27);  read_byte(8'h78);   // right Win make (0x78 row)
    expect_quiet(700, "right Win (KBEX_NONREP)");
    send_key(1'b0, 1'b1, 8'h27);  read_byte(8'hF8);   // right Win break

    // ---- 6. Both ends of the F1-F10 row and CTRL: keystat.tbl kbexflag rows 60h/68h
    //         (`0x80` under f.1..f10, 0x62-0x6B) and 70h (SFT..CTRL, 0x70-0x74). Only
    //         LShift and RWIN were held above, so a table that dropped F10 or CTRL
    //         from the non-repeat set passed. ----
    send_key(1'b1, 1'b0, 8'h05);  read_byte(8'h62);   // F1 make
    expect_quiet(700, "F1 (KBEX_NONREP)");
    send_key(1'b0, 1'b0, 8'h05);  read_byte(8'hE2);
    send_key(1'b1, 1'b0, 8'h09);  read_byte(8'h6B);   // F10 make
    expect_quiet(700, "F10 (KBEX_NONREP)");
    send_key(1'b0, 1'b0, 8'h09);  read_byte(8'hEB);
    send_key(1'b1, 1'b0, 8'h14);  read_byte(8'h74);   // left Ctrl make (NEC CTRL)
    expect_quiet(700, "CTRL (KBEX_NONREP)");
    send_key(1'b0, 1'b0, 8'h14);  read_byte(8'hF4);

    // ---- 7. The rest of the KBEX_NONREP rows that have a key here: VF1 (0x52, F11 - the
    //         VF row 50h, keystat.tbl), GRPH (0x73, right Ctrl) and CAPS (0x71, a lock: one
    //         alternating byte per press, never a repeat). APP (0x79) has no source in this
    //         core (Menu is KANA), so it is not driven. ----
    send_key(1'b1, 1'b0, 8'h78);  read_byte(8'h52);   // F11 -> VF1 make
    expect_quiet(700, "VF1 (KBEX_NONREP)");
    send_key(1'b0, 1'b0, 8'h78);  read_byte(8'hD2);
    send_key(1'b1, 1'b1, 8'h14);  read_byte(8'h73);   // right Ctrl -> GRPH make
    expect_quiet(700, "GRPH (KBEX_NONREP)");
    send_key(1'b0, 1'b1, 8'h14);  read_byte(8'hF3);
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'h71);   // CAPS pressed: lock on
    expect_quiet(700, "CAPS held (KBEX_NONREP)");
    send_key(1'b0, 1'b0, 8'h58);
    expect_quiet(100, "CAPS released");
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'hF1);   // CAPS pressed again: lock off
    send_key(1'b0, 1'b0, 8'h58);

    // ---- 8. The DEFAULT parameters: 500 ms delay, 50 ms interval (NP2kai sdl/ini.c:951-952,
    //         keyrepeat_delay 500 and keyrepeat_interval 50), at D_HZ = 2 kHz: 1000 and 100 clk.
    @(negedge clk); a0 = 1; din = 8'h5E; cs2 = 1; wr = 1; @(posedge clk); @(negedge clk); cs2 = 0; wr = 0;
    @(negedge clk); a0 = 1; din = 8'h05; cs2 = 1; wr = 1; @(posedge clk); @(negedge clk); cs2 = 0; wr = 0;
    @(negedge clk); ps2_key2 = {1'b1, 1'b1, 1'b0, 8'h1D}; // W make
    for (i = 0; i < 3; i = i + 1) begin
      timeout_count = 0;
      while (!irq2 && timeout_count < 2000) begin @(posedge clk); #1; timeout_count = timeout_count + 1; end
      t_def[i] = cyc;
      if (!irq2) begin
        $display("FAIL: default-parameter instance: byte %0d never arrived", i);
        errors = errors + 1;
      end
      // read off this byte (and, for a repeat, its make behind it)
      for (j = 0; j < ((i == 0) ? 1 : 2); j = j + 1) begin
        timeout_count = 0;
        while (!irq2 && timeout_count < 40) begin @(posedge clk); #1; timeout_count = timeout_count + 1; end
        @(negedge clk); a0 = 0; cs2 = 1; rd = 1;
        #1 value = dout2;
        if (value !== ((i > 0 && j == 0) ? 8'h91 : 8'h11)) begin
          $display("FAIL: default-parameter instance: byte got %02x", value);
          errors = errors + 1;
        end
        @(posedge clk); @(negedge clk); cs2 = 0; rd = 0; #1;
      end
    end
    check_gap(t_def[1] - t_def[0], D_HZ / 2,  6, "default delay (500 ms at 2 kHz)");
    check_gap(t_def[2] - t_def[1], D_HZ / 20, 6, "default interval (50 ms at 2 kHz)");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_REPEAT: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_REPEAT: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000;
    $fatal(1, "TB_PC9821_KBD_REPEAT: TIMEOUT");
  end

endmodule

`default_nettype wire
