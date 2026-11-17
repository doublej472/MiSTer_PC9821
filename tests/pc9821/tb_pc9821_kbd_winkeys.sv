// tb_pc9821_kbd_winkeys - the Windows keys reach the guest only after the 0x95 0x03 command.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_KBD_WINKEYS: the left and right Windows keys (set-2 E0 1F / E0 27, PC-98 0x77 / 0x78) send nothing to the guest until the guest enables the extended keys with command 0x95 and parameter 0x03 (both bytes answered FA); after it, a tap of each gives its make and break (0x77/0xF7, 0x78/0xF8); the setting survives the 8251 bit-3 keyboard reset (0x3A then 0x32) and a later 0x95 0x00 turns the keys off again; the parameters 0x01 and 0x02 leave them off and 0x04 turns them on (NP2kai's `kbdtype < 3` test), and a Windows key held down across 0x95 0x00 still sends its break on release, while an ordinary key (A, 0x1D/0x9D) is delivered in every state, so a model that delivers the Windows keys from power-up, ignores the 0x95 parameter, tests it against the wrong threshold, gates the break or forgets the setting at the keyboard reset fails here.

// ---- where the expectation comes from ----
//   undoc98vol2 io_kb.txt, command 95h: the extended key setting [PC-9801-98/119],
//     the parameter 00h = normal, 03h = Windows keys and the application key enabled.
//   NP2kai keystat.c (built with SUPPORT_PC9801_119 for the IA-32 core): keystat_initialize
//     sets `keyctrl.kbdtype = 1`, keystat_ctrlsend case 0x95 stores the parameter
//     (`keyctrl.kbdtype = dat;`), and keystat_down / keystat_up skip every keycode >= 0x75
//     while `keyctrl.kbdtype < 3`. keystat_ctrlreset (the 8251 keyboard reset's
//     keyboard_resetsignal) does not touch kbdtype.
//   No capture of the Xe10's keyboard after 0x95 exists; NP2kai and the undoc98 text agree.
// FAIL-FIRST: on the tree before the fix the power-up Windows-key taps deliver 0x77/0xF7 and
// 0x78/0xF8 at once (section 1), and 0x95 0x00 leaves them live (section 4).

`default_nettype none

module tb_pc9821_kbd_winkeys;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // ==== DUT ====
  // The byte-presentation tick is shrunk so back-to-back bytes stay inside read_byte's budget
  // (the real tick is SYS_CLOCK_HZ / 1280; tb_pc9821_kbd_pace pins it). The Windows keys are
  // typematic in NP2kai's table (0x77) or not (0x78); the taps here are far shorter than the
  // repeat delay either way.
  pc9821_kbd #(.XFER_TICK_CYCLES(26'd8)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .a0(a0), .wr(wr), .rd(rd), .din(din), .dout(dout),
      .irq(irq), .ps2_key(ps2_key)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;

  task fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
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

  task send_key(input pressed, input extended, input [7:0] code);
    begin
      @(negedge clk);
      toggle  = ~toggle;
      ps2_key = {toggle, pressed, extended, code};
      @(posedge clk);
      @(negedge clk);
      repeat (12) @(posedge clk);
    end
  endtask

  task read_byte(input [7:0] expected, input string what);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        fail($sformatf("%s: no byte arrived, want %02x", what, expected));
      end else begin
        @(negedge clk);
        a0 = 0; cs = 1; rd = 1;
        #1 value = dout;
        if (value !== expected) fail($sformatf("%s: got %02x want %02x", what, value, expected));
        @(posedge clk);
        @(negedge clk);
        cs = 0; rd = 0;
        #1;
      end
    end
  endtask

  // Nothing may reach the guest for a long window (the presentation tick is 8 clks); every
  // byte that does arrive is read off and reported, so the stream stays in step.
  integer drained;
  task expect_silence(input string what);
    begin
      drained = 0;
      timeout_count = 0;
      while (timeout_count < 200 && drained < 8) begin
        if (irq) begin
          @(negedge clk);
          a0 = 0; cs = 1; rd = 1;
          #1 value = dout;
          @(posedge clk);
          @(negedge clk);
          cs = 0; rd = 0;
          fail($sformatf("%s: the guest got %02x, want nothing", what, value));
          drained = drained + 1;
          timeout_count = 0;
        end else begin
          @(posedge clk);
          timeout_count = timeout_count + 1;
        end
      end
    end
  endtask

  task win_taps_silent(input string what);
    begin
      send_key(1'b1, 1'b1, 8'h1F); send_key(1'b0, 1'b1, 8'h1F);
      expect_silence({what, ", left Windows"});
      send_key(1'b1, 1'b1, 8'h27); send_key(1'b0, 1'b1, 8'h27);
      expect_silence({what, ", right Windows"});
    end
  endtask

  task win_taps_live(input string what);
    begin
      send_key(1'b1, 1'b1, 8'h1F); read_byte(8'h77, {what, ", left Windows make"});
      send_key(1'b0, 1'b1, 8'h1F); read_byte(8'hF7, {what, ", left Windows break"});
      send_key(1'b1, 1'b1, 8'h27); read_byte(8'h78, {what, ", right Windows make"});
      send_key(1'b0, 1'b1, 8'h27); read_byte(8'hF8, {what, ", right Windows break"});
    end
  endtask

  task a_tap(input string what);
    begin
      send_key(1'b1, 1'b0, 8'h1C); read_byte(8'h1D, {what, ", A make"});
      send_key(1'b0, 1'b0, 8'h1C); read_byte(8'h9D, {what, ", A break"});
    end
  endtask

  task cmd_95(input [7:0] param);
    begin
      write_port(1'b0, 8'h95); read_byte(8'hFA, "0x95 ACK");
      write_port(1'b0, param); read_byte(8'hFA, "0x95 parameter ACK");
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    write_port(1'b1, 8'h5E);            // the firmware's mode byte
    write_port(1'b1, 8'h05);            // TxEN + RxE
    repeat (4) @(posedge clk);

    // 1. power-up: the extended keys are off (NP2kai kbdtype 1)
    win_taps_silent("power-up");
    a_tap("power-up");

    // 2. 0x95 0x03 turns them on
    cmd_95(8'h03);
    win_taps_live("after 0x95 0x03");
    a_tap("after 0x95 0x03");

    // 3. the 8251 keyboard reset keeps the setting (keystat_ctrlreset leaves kbdtype)
    write_port(1'b1, 8'h3A);
    write_port(1'b1, 8'h32);            // bit 3 1 -> 0: the keyboard reset
    write_port(1'b1, 8'h05);            // TxEN again
    repeat (4) @(posedge clk);
    win_taps_live("after the keyboard reset");

    // 4. 0x95 0x00 turns them off again
    cmd_95(8'h00);
    win_taps_silent("after 0x95 0x00");
    a_tap("after 0x95 0x00");

    // 5. the threshold: NP2kai keystat.c skips keycodes >= 0x75 while `keyctrl.kbdtype < 3`,
    //    so 0x01 and 0x02 leave the Windows keys off and 0x04 (above 3) turns them on
    cmd_95(8'h01);
    win_taps_silent("after 0x95 0x01");
    cmd_95(8'h02);
    win_taps_silent("after 0x95 0x02");
    cmd_95(8'h04);
    win_taps_live("after 0x95 0x04");

    // 6. a Windows key held down across 0x95 0x00 still breaks when released: the guest saw
    //    its make, and a make with no break leaves the key down in the guest for good (the
    //    stream rule tb_pc9821_kbd_overrun_break holds the queue to; NP2kai keystat_up skips
    //    this break and leaves the key down in its own table - a divergence, kept on purpose)
    send_key(1'b1, 1'b1, 8'h1F); read_byte(8'h77, "held across 0x95 0x00, left Windows make");
    cmd_95(8'h00);
    send_key(1'b0, 1'b1, 8'h1F); read_byte(8'hF7, "held across 0x95 0x00, left Windows break");
    win_taps_silent("after the held key's release");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_WINKEYS: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_WINKEYS: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_KBD_WINKEYS: TIMEOUT");
  end

endmodule

`default_nettype wire
