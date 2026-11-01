// tb_pc9821_kbd_led — the host keyboard LEDs, from the PC-98 lock state.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The PC-98 lock state reaches the MiSTer HOST keyboard's LEDs in hps_io's {scrolllock, numlock, capslock} order, on a CAPS lock toggle and on the host's 0x9D+0x7x set command, and agrees with the 0x9D+0x60 query. This is the bridge that did not exist: z486_mister.sv tied ps2_kbd_led_status to 0, so the keyboard's Caps Lock lamp never lit even though the lock itself toggled correctly.
//
// ---- where the expectation comes from ----
// [source 1: MiSTer hps_io] MkDocs_MiSTer/docs/developer/hps_io.md: the three bits are
// `{scrl_lock, num_lock, caps_lock}`, and the core must first set the matching bit in
// ps2_kbd_led_use to take a lamp over from the HPS.
// [source 2: NP2kai keystat.c] reloadled() republishes getledstat() whenever the lock refs
// move -- on a CAPS/KANA lock-key make/break, and on the host's 0x9D+0x7x set command.
// [source 3: this core's own 0x9D+0x60 answer] which returns 0x70|lock and is pinned by
// tb_pc9821_kbd.sv, so the LED output and the command answer are the same state.

`default_nettype none

module tb_pc9821_kbd_led;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  wire [2:0] led_status;
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
      .ps2_key(ps2_key),
      .bios_setup(1'b0),
      .led_status(led_status)
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
        fail("no receive IRQ: the byte never arrived");
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

  // The LED answer is the subject here, so name the three lamps rather than the index.
  localparam [2:0] LED_OFF  = 3'b000;
  localparam [2:0] LED_CAPS = 3'b001;
  localparam [2:0] LED_NUM  = 3'b010;
  localparam [2:0] LED_KANA = 3'b100;

  task expect_led(input [2:0] want, input [8*60-1:0] who);
    begin
      #1;
      if (led_status !== want) begin
        $display("FAIL: %0s: led_status = %b, want %b", who, led_status, want);
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
    expect_led(LED_OFF, "power-up");

    // The firmware's own init: mode byte, then TxEN+RxE+RTS.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ---- 1. A CAPS lock toggle moves the lamp, and its release moves nothing. ----
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'h71);   // CAPS on -> make
    expect_led(LED_CAPS, "CAPS on");
    send_key(1'b0, 1'b0, 8'h58);                      // release: the lock stays on
    repeat (4) @(posedge clk);
    expect_led(LED_CAPS, "CAPS release");
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'hF1);   // CAPS off -> break
    expect_led(LED_OFF, "CAPS off");
    send_key(1'b0, 1'b0, 8'h58);
    repeat (4) @(posedge clk);
    expect_led(LED_OFF, "CAPS off release");

    // ---- 2. The host's 0x9D+0x7x set command moves the same lamps, as NP2kai does. ----
    // KANA -> scrolllock; the PC-98 KANA lock has no host lamp of its own.
    write_port(1'b0, 8'h9D);  read_byte(8'hFA);
    write_port(1'b0, 8'h78);  read_byte(8'hFA);       // KANA set
    expect_led(LED_KANA, "0x9D+0x78 KANA set");
    write_port(1'b0, 8'h9D);  read_byte(8'hFA);
    write_port(1'b0, 8'h71);  read_byte(8'hFA);       // NUM set
    expect_led(LED_NUM, "0x9D+0x71 NUM set");
    write_port(1'b0, 8'h9D);  read_byte(8'hFA);
    write_port(1'b0, 8'h7C);  read_byte(8'hFA);       // CAPS | KANA
    expect_led(LED_CAPS | LED_KANA, "0x9D+0x7C CAPS|KANA set");
    write_port(1'b0, 8'h9D);  read_byte(8'hFA);
    write_port(1'b0, 8'h70);  read_byte(8'hFA);       // all off
    expect_led(LED_OFF, "0x9D+0x70 all off");

    // ---- 3. The LED output and the 0x9D+0x60 query agree. ----
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'h71);   // CAPS on
    expect_led(LED_CAPS, "CAPS on again");
    write_port(1'b0, 8'h9D);  read_byte(8'hFA);
    write_port(1'b0, 8'h60);  read_byte(8'hFA);
    read_byte(8'h74);                                 // 0x70 | CAPS
    send_key(1'b0, 1'b0, 8'h58);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_LED: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_LED: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_KBD_LED: TIMEOUT");
  end

endmodule

`default_nettype wire
