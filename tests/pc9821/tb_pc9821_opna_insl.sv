`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_INSL: OPNA register 0x0E (the joystick connector's six switch lines, read through 0x188/0x18A) answers the pad only while register 0x0F bit 6 (INSL, the input select) is clear, as NP2kai (sound/fmboard.c fmboard_getjoy, the stick read only when `!(opna->s.reg[15] & 0x40)`) and MAME (bus/pc98_cbus/pc9801_86.cpp, the pad only when `(m_joy_sel & 0xc0) == 0x80`) agree: with a pad holding up, right and button 1, 0x0E reads 0xFF at power-up (0x0F = 0xFF, the Xe10's `r0e=FF r0f=FF`), 0xE6 after 0x0F = 0x80, and 0xFF again after 0x0F = 0xC0 and after 0x0F = 0x40; register 0x0F reads back what was written.
//
// WHERE THE EXPECTED VALUES COME FROM: NP2kai sound/fmboard.c fmboard_getjoy (the primary
// software reference): `ret = 0xff; if (!(opna->s.reg[15] & 0x40)) { ... ret &= joymng_getstat(); }`
// then `ret &= 0x3f; ret |= opna->s.intr;` (the two upper bits are this board's 1s, the
// machine's idle byte, see pc9821_opna.sv). MAME's -86 reads the pad only with 0x0F bits 7:6
// = 10, so the bench asserts only the values on which the two agree: 0x80 (pad), 0xC0, 0x40
// and 0xFF (released). 0x00 (bit 7 clear, bit 6 clear) is where they differ and is not
// asserted. The power-up 0x0F of 0xFF and the 0x0E byte of 0xFF with it are the Xe10's
// (docs/probes/XE10T-XE10-OPNA2.TXT `X OPNA2 IDC b=0188 ext=0 ... r0e=FF r0f=FF`). No capture
// holds a pad, so no row of the machine decides INSL directly.
//
// ==== DUT ====
// pc9821_opna, the joystick lines driven as pc9821_gameport drives them (active low:
// up, down, left, right, button 1, button 2 = bits 0..5).

module tb_pc9821_opna_insl;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  localparam real    CLK_NS       = 1_000_000_000.0 / SYS_CLOCK_HZ;

  reg clk = 0;
  always #(CLK_NS/2.0) clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait, io_rd_hold, io_wr_wait;
  wire       irq;
  wire signed [19:0] snd_l, snd_r;
  // up (bit 0), right (bit 3) and button 1 (bit 4) held, the rest released: 0x0E = 0xE6
  reg  [5:0] joystick = 6'b10_0110;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .io_rd_hold(io_rd_hold), .io_wr_wait(io_wr_wait),
    .extend(1'b0), .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  integer errors = 0;
  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  task automatic p_out(input [15:0] port, input [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
      while (io_wr_wait) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask
  task automatic p_in(input [15:0] port, output [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_rd = 1;
      @(negedge clk); io_rd = 0;
      while (io_rd_hold) @(negedge clk);
      #1 data = io_dout;
      repeat (2) @(negedge clk);
    end
  endtask
  task automatic rd_reg(input [7:0] r, output [7:0] v);
    begin
      p_out(16'h0188, r);
      p_in(16'h018A, v);
    end
  endtask

  // ==== CHECKS ====
  // One 0x0F value: write it, read 0x0E and 0x0F back.
  task automatic insl_row(input [7:0] r0f, input [7:0] want_0e);
    reg [7:0] v;
    begin
      p_out(16'h0188, 8'h0F);
      p_out(16'h018A, r0f);
      rd_reg(8'h0E, v);
      $display("  0x0F=%02x: 0x0E reads %02x", r0f, v);
      if (v !== want_0e) fail($sformatf("0x0F=%02x: 0x0E reads %02x, NP2kai/MAME want %02x", r0f, v, want_0e));
      rd_reg(8'h0F, v);
      if (v !== r0f) fail($sformatf("0x0F=%02x: 0x0F reads back %02x", r0f, v));
    end
  endtask

  reg [7:0] v;
  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (400) @(negedge clk);

    rd_reg(8'h0E, v);
    $display("  power-up: 0x0E reads %02x", v);
    if (v !== 8'hFF) fail("power-up (0x0F = FF, INSL set): 0x0E is not FF");
    rd_reg(8'h0F, v);
    if (v !== 8'hFF) fail("power-up: 0x0F is not the Xe10's FF");

    insl_row(8'h80, {2'b11, 6'b10_0110});   // INSL clear: the pad
    insl_row(8'hC0, 8'hFF);                 // INSL set: released
    insl_row(8'h80, {2'b11, 6'b10_0110});
    insl_row(8'h40, 8'hFF);
    insl_row(8'hFF, 8'hFF);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_INSL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_INSL: FAIL (%0d errors)", errors);
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_OPNA_INSL: TIMEOUT");
  end

endmodule
