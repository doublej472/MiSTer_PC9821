// tb_pc9821_kbd_resp_race - a command response must not be lost to its own delivery.
//
// ==== WHAT THIS PROVES ====
// A command response loaded in the exact clk the old response's last byte delivers must not be lost (defer-not-lose): the in-flight byte still reaches the guest, the new FA A0 83 of the 0x96 ID command is installed intact (resp_count 3, 0x83 at the shift top) instead of being clobbered by the deliver's bookkeeping, and the guest sees the whole ack sequence byte by byte.
//
// A guest command write that loads a new response in the exact clk the old
// response's last byte delivers must keep the NEW response.
// Before the fix the deliver arm (later in the same always block) shifted
// `resp_shift` and decremented `resp_count` from the OLD response, so the fresh
// FA A0 83 of the 0x96 keyboard-ID command was clobbered to a zero-length
// response and the 0x9C/0x9D/0x96 protocol's FA ack never appeared.
//
// The fold is DEFER-NOT-LOSE: the in-flight byte still reaches the guest (the
// collision delivers the OLD byte - deliver-first, which is the order the
// expected resp_shift[23:16] == 8'h83 pins), and the deliver's bookkeeping
// defers to the load so the command response is installed intact. A response
// arriving mid-response replaces the unread remainder exactly as NP2kai does it:
// keystat_ctrlsend -> keyboard_ctrl() clears keybrd.ctrls on the leading FA/FC
// before queueing the new bytes (NP2kai io/serial.c keyboard_ctrl).

`timescale 1ns / 1ps

module tb_pc9821_kbd_resp_race;

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
      .ps2_key(ps2_key),
      .bios_setup(1'b0)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;

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

    // The firmware's own init.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ==== THE COLLISION ====
    // A junk command (0xEE -> the default one-byte FC response, no pending
    // parameter) puts resp_count at 1; the load's NBA makes deliver_resp fire in
    // the NEXT clk. The strobe is HELD across two consecutive posedges with only
    // din changing, so the 0x96 write lands in exactly the clk deliver_resp
    // fires with resp_count == 1. (The iobus floor keeps real accesses far
    // apart; nothing inside this module asserts that pacing.)
    @(negedge clk);
    a0 = 0; din = 8'hEE; cs = 1; wr = 1;   // strobe posedge A: load {FC}, count 1
    @(negedge clk);
    din = 8'h96;                           // strobe posedge A+1: deliver collides with the load
    @(negedge clk);
    cs = 0; wr = 0;

    // The delivered byte is the OLD response's (deliver-first order), and the
    // NEW response is installed INTACT: 3 bytes, 0x83 at the shift top.
    repeat (2) @(negedge clk);
    if (dut.rx_latch !== 8'hFC) begin
      $display("FAIL: rx_latch = %02x want FC (the in-flight byte must still reach the guest)", dut.rx_latch);
      errors = errors + 1;
    end
    if (dut.resp_count !== 2'd3) begin
      $display("FAIL: resp_count = %0d want 3: the same-cycle command response was lost", dut.resp_count);
      errors = errors + 1;
    end
    if (dut.resp_shift[23:16] !== 8'h83) begin
      $display("FAIL: resp_shift top = %02x want 83: the new response was clobbered by the deliver", dut.resp_shift[23:16]);
      errors = errors + 1;
    end

    // And the guest actually SEES the ack sequence: the old FC, then FA A0 83.
    read_byte(8'hFC);                      // the collided delivery (already in rx_latch)
    read_byte(8'hFA);                      // the 0x96 response, byte 1
    read_byte(8'hA0);                      // byte 2
    read_byte(8'h83);                      // byte 3 (NP2kai keystat_ctrlsend: FA A0 83)

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_RESP_RACE: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_RESP_RACE: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_KBD_RESP_RACE: TIMEOUT");
  end

endmodule
