`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DBG_SYSTEM: The debug-UART framework is wired into pc9821_system the way the build options say: with every DBG_* parameter at its default the debug arm (dbg_uart_we) never rises - the instruments do not exist - and with the display log, the CPU sampler and the snoop built the mux puts whole records on the arm under a randomly stalling accept: the display log's ALIVE record (0x1F) at power-up, CPU samples (0x20/0x21) at the sampler's period, and a display-port write the bench forces onto the device bus (OUT 0xA4 = 0x01) as a 0x16 record carrying that value, every record intact and in the table's length.
//
// This is the integration the unit benches cannot see: that the instruments are fed the right
// system signals, that the mux's grant reaches each instrument's log_accept, and that the shipped
// all-off configuration really leaves the arm dead. The CPU is tests/pc9821/z486_stub.sv (the real
// z486 tree does not elaborate in the 4-state simulator the other system benches use), so the CPU
// fields of a sample are the stub's constants; what is checked is the framing and the flow.

`default_nettype none

module tb_pc9821_dbg_system;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  integer errors = 0;

  // ==== DUT ====
  wire       off_we, on_we;
  wire [7:0] off_byte, on_byte;
  reg        on_acc_en = 1'b1;
  wire       on_accept = on_we && on_acc_en;
  // all DBG_* at their defaults: the shipped configuration
  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0)) dut_off (
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
      .dbg_uart_byte(off_byte), .dbg_uart_we(off_we), .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_setup(1'b0), .bios_set(4'd0));
  // the display log, the sampler (1 ms window at 50 MHz = 50,000 clocks) and a snoop built
  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .DBG_GDC_EN(1'b1), .DBG_CPU_EN(1'b1), .DBG_SAMPLE_MS(1), .DBG_SNOOP_EN(1'b1),
      .DBG_SNOOP_LO(32'h0001_0000), .DBG_SNOOP_HI(32'h0002_0000)) dut_on (
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
      .dbg_uart_byte(on_byte), .dbg_uart_we(on_we), .dbg_uart_accept(on_accept), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_setup(1'b0), .bios_set(4'd0));

  // ==== CHECKS ====
  reg [31:0] lfsr = 32'h1BADB002;
  function automatic [31:0] rnd();
    begin
      lfsr = lfsr ^ (lfsr << 13); lfsr = lfsr ^ (lfsr >> 17); lfsr = lfsr ^ (lfsr << 5);
      rnd = lfsr;
    end
  endfunction
  function automatic integer tlen(input [7:0] t);
    case (t)
      8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17, 8'h18: tlen = 7;
      8'h19: tlen = 9;  8'h1E, 8'h1F: tlen = 7;
      8'h20, 8'h21: tlen = 34;
      8'h30, 8'h31: tlen = 15;  8'h32: tlen = 8;
      default: tlen = 0;
    endcase
  endfunction

  // the off instance: the arm must never rise
  integer off_rises = 0;
  always @(posedge clk_sys) if (off_we) off_rises = off_rises + 1;

  // capture the on instance
  reg [7:0] cap [0:99999];
  integer ncap = 0;
  always @(posedge clk_sys) if (on_accept && ncap < 100000) begin cap[ncap] = on_byte; ncap = ncap + 1; end

  integer i, l, nalive, nsmp, nout16, bad, dump_fd;
  reg [8*256-1:0] dump_name;
  initial begin
    repeat (6) @(negedge clk_sys);
    reset = 0;
    // a stalling accept, 320,000 clocks (6 sampler periods), with a display-port write forced
    // onto the device bus part-way through
    for (i = 0; i < 320000; i = i + 1) begin
      @(negedge clk_sys);
      on_acc_en = (rnd() % 4 != 0);
      if (i == 120000) begin
        force dut_on.device_io_wr = 1'b1; force dut_on.device_io_addr = 16'h00A4; force dut_on.device_io_din = 8'h01;
      end
      if (i == 120002) begin release dut_on.device_io_wr; release dut_on.device_io_addr; release dut_on.device_io_din; end
    end
    on_acc_en = 1'b1;
    repeat (4000) @(negedge clk_sys);
    // parse
    nalive = 0; nsmp = 0; nout16 = 0; bad = 0; i = 0;
    while (i < ncap) begin
      l = (cap[i] == 8'hA5) ? tlen(cap[i+1]) : 0;
      if (l == 0) begin
        $display("FAIL: byte %0d is not a record start (%02x %02x)", i, cap[i], cap[i+1]); errors = errors + 1; i = ncap;
      end else if (i + l <= ncap) begin
        if (cap[i+1] == 8'h1F && cap[i+6] == 8'h5A) nalive = nalive + 1;
        if (cap[i+1] == 8'h20 || cap[i+1] == 8'h21) begin
          nsmp = nsmp + 1;
          if (cap[i+33] != 8'h5A) begin $display("FAIL: sample at %0d lacks its tail", i); errors = errors + 1; end
        end
        if (cap[i+1] == 8'h16 && cap[i+6] == 8'h01) nout16 = nout16 + 1;
        i = i + l;
      end else i = ncap;
    end
    if (off_rises != 0) begin $display("FAIL: the all-off build's debug arm rose %0d times", off_rises); errors = errors + 1; end
    if (nalive < 1) begin $display("FAIL: no display-log ALIVE record"); errors = errors + 1; end
    if (nsmp < 4) begin $display("FAIL: only %0d CPU samples in 6 sampler periods", nsmp); errors = errors + 1; end
    if (nout16 != 1) begin $display("FAIL: %0d records for the one forced OUT 0xA4 = 0x01 (expected 1)", nout16); errors = errors + 1; end
    $display("dbg_system: %0d bytes, %0d ALIVE, %0d samples, %0d OUT records", ncap, nalive, nsmp, nout16);

    // the capture, for tools/decode_dbglog.py (an end-to-end check of RTL bytes against the tool)
    if ($value$plusargs("DBGLOG_OUT=%s", dump_name)) begin
      dump_fd = $fopen(dump_name, "wb");
      for (i = 0; i < ncap; i = i + 1) $fwrite(dump_fd, "%c", cap[i]);
      $fclose(dump_fd);
    end

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_DBG_SYSTEM: %0d check(s) failed", errors);
    $display("TB_PC9821_DBG_SYSTEM: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_DBG_SYSTEM: TIMEOUT");
  end
endmodule
