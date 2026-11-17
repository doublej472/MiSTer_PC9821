`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MOUSE_SYSTEM: the bus mouse's periodic interrupt reaches the slave 8259 as IRQ13 through pc9821_system's own wiring: with the mouse's INT# cleared by the guest's 0x7FDF bit-reset write (0x08) the slave PIC's IR5 input rises once per mouse interval, (SYS_CLOCK_HZ/120) at 0xBFDB timing 0 (NP2kai io/mouseif.c mouseint and mouseif_obfdb; the 120 Hz base qemu and MAME agree on), while no other slave input moves with it; and with INT# set again (0x7FDF 0x09) the line stays quiet for two intervals - so a pc9821_system that drops the mouse's line or moves it to another slave input fails here, not only in tools/check_wiring.py.
//
// The expected values are the reference's: NP2kai io/mouseif.c (mouseint: the event re-arms at
// the 120 Hz base shifted by the 0xBFDB timing field; setportc: INT#, Port C bit 4, silences it
// and its falling edge arms it) and the PC-98 bus mouse's IRQ13 (NP2kai's MOUSE IRQ 13 = the
// slave's IR5). tb_pc9821_mouse pins the device's own interval and masking against
// pc9821_iobus; this bench pins only the ROUTE through the real pc9821_system to the PIC input.
//
// ==== DUT ====
// pc9821_system (MPU_EN 1, the base preset; the MPU absent), with the CPU side forced onto its
// I/O request port the way tb_pc9821_mpu_system drives it.

`default_nettype none

module tb_pc9821_mouse_system;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  integer errors = 0;

  // ==== DUT ====
  reg [31:2] cpu_addr = 30'd0;
  reg [3:0]  cpu_be = 4'd0;
  reg        cpu_write = 1'b0;
  reg [31:0] cpu_din = 32'd0;
  reg        valid_on = 1'b0;

  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .MPU_EN(1'b1)) dut (
      .clk_sys(clk_sys), .reset(reset), .hps_apply_reset(1'b0), .rtc(rtc), .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(1'b0),
      .ext_mem0_dout(32'd0), .ext_mem0_resp_valid(1'b0), .ext_mem0_ready(1'b1),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(16'd0),
      .img_mounted(1'b0), .img_readonly(1'b0), .img_size(64'd0), .img_ack(1'b0), .img_buff_addr(13'd0),
      .img_buff_din(16'd0), .img_buff_wr(1'b0),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_byte(), .dbg_uart_we(), .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_set(4'd0),
      .mpu_present(1'b0));

  // ==== THE CPU SIDE ====
  initial begin
    force dut.memory.loader.cpu_run = 1'b1;
    force dut.z_inta = 1'b0;
    force dut.z_io = 1'b1;
    force dut.z_valid = valid_on;
    force dut.z_addr = cpu_addr;
    force dut.z_be = cpu_be;
    force dut.z_write = cpu_write;
    force dut.z_dout = cpu_din;
  end

  // The slave 8259's request inputs as pc9821_system drives them (bit 5 = IR5 = IRQ13).
  wire [7:0] slave_in = dut.interrupts.slave_irq;
  localparam integer PERIOD = 50_000_000 / 120;   // 416666 clk at 0xBFDB timing 0

  task automatic fail(input string message);
    begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic wr(input [15:0] port, input [7:0] wdata);
    integer waited;
    begin
      @(negedge clk_sys);
      cpu_addr = {16'd0, port[15:2]};
      cpu_be = 4'b0001 << port[1:0];
      cpu_write = 1'b1;
      cpu_din = 32'd0;
      cpu_din[{port[1:0], 3'b000} +: 8] = wdata;
      valid_on = 1'b1;
      waited = 0;
      while (!dut.io_cpu_ready) begin
        @(negedge clk_sys);
        waited = waited + 1;
        if (waited > 5000) $fatal(1, "TB_PC9821_MOUSE_SYSTEM: FAIL - an I/O write to %04x never completed", port);
      end
      @(negedge clk_sys);
      valid_on = 1'b0; cpu_be = 4'd0; cpu_write = 1'b0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // Watch the slave inputs for `cycles` clk: the number of IR5 rises, the clk of the first two,
  // and whether any OTHER slave input was high on a clk IR5 rose.
  integer rises, t_first, t_second, others;
  task automatic watch(input integer cycles);
    integer n;
    reg prev5;
    begin
      rises = 0; t_first = -1; t_second = -1; others = 0;
      prev5 = slave_in[5];
      for (n = 0; n < cycles; n = n + 1) begin
        @(posedge clk_sys); #1;
        if (slave_in[5] && !prev5) begin
          if (rises == 0) t_first = n;
          else if (rises == 1) t_second = n;
          rises = rises + 1;
          if ((slave_in & 8'hDF) !== 8'h00) others = others + 1;
        end
        prev5 = slave_in[5];
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk_sys);
    reset = 0;
    repeat (200) @(negedge clk_sys);

    // INT# is set out of reset (0x7FDD reads 0xF8: bit 4 set): the line is quiet.
    watch(PERIOD + PERIOD / 4);
    if (rises != 0) fail($sformatf("IR5 rose %0d times with the mouse's INT# set out of reset", rises));

    // Timing 0, then INT# cleared by the 8255 bit-reset form: the interval starts.
    wr(16'hBFDB, 8'h00);
    wr(16'h7FDF, 8'h08);
    watch(2 * PERIOD + PERIOD / 2);
    $display("  INT# clear: %0d IR5 rises, first at %0d, interval %0d clk (want %0d), %0d with another slave input up",
             rises, t_first, t_second - t_first, PERIOD, others);
    if (rises < 2)
      fail($sformatf("the mouse interrupt reached the slave's IR5 %0d times in 2.5 intervals (want 2)", rises));
    else if ((t_second - t_first) < PERIOD - PERIOD / 100 || (t_second - t_first) > PERIOD + PERIOD / 100)
      fail($sformatf("IR5's interval is %0d clk, want %0d +/- 1%%", t_second - t_first, PERIOD));
    if (others != 0)
      fail("another slave input rose with the mouse's IR5: the line is not the mouse's alone");

    // INT# set again: quiet.
    wr(16'h7FDF, 8'h09);
    watch(2 * PERIOD);
    if (rises != 0) fail($sformatf("IR5 rose %0d times after INT# was set again", rises));

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_MOUSE_SYSTEM: FAIL - %0d check(s) failed", errors);
    $display("TB_PC9821_MOUSE_SYSTEM: PASS");
    $finish;
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_MOUSE_SYSTEM: TIMEOUT");
  end
endmodule

`default_nettype wire
