`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_E_PLANE_MODE: the intensity (E) plane at 0xE0000-0xE7FFF is a 16-colour-mode window, switched by the guest with its own OUT 0x6A through pc9821_system: in the digital (8-colour) mode the machine resets to, a dword stored at 0xE0004 reads back 0xFFFFFFFF and is not kept, exactly as the real Xe10 answers (docs/probes/DMAROUTE-XE10.TXT case P4 view V1, `ORIG=FFFFFFFF PRE=FFFFFFFF POST=FFFFFFFF` under `9A0_04/07/08/0A=00 00 00 00`; docs/probes/VRAM2.TXT `E000wrote= 00 FF 55 AA` / `got= FF FF FF FF`; NP2kai i386c/cpumem.c installs memnc over the slot while VOPBIT_ANALOG is clear); after OUT 0x6A,0x01 (FF2 num 0, the 16-colour select) the same store round-trips through the plane; OUT 0x6A,0x00 hides the plane again (0xFF, the store dropped) and OUT 0x6A,0x01 shows it with the byte the analog-mode store left, untouched by the digital-mode store. FAIL-FIRST: the core mapped the E plane in every mode, so the digital-mode store read back.
//
// The CPU is tests/pc9821/z486_stub.sv; the bench FORCES its side of the bus (z_valid, z_io,
// z_addr, z_be, z_write, z_dout, z_burstcount, z_line_read; z_inta held low) and the loader's
// cpu_run (no pack is loaded), the pattern tb_pc9821_mpu_system uses, so the OUT 0x6A walks the
// system's own iobus, device select and pc9821_crtc, and the memory access walks the system's
// own subsystem, map and responders. Nothing between the port write and the map is forced.

`default_nettype none

module tb_pc9821_e_plane_mode;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  integer errors = 0;

  // ==== DUT ====
  reg [31:2] cpu_addr = 30'd0;
  reg [3:0]  cpu_be = 4'd0;
  reg        cpu_write = 1'b0;
  reg        cpu_io = 1'b0;
  reg [31:0] cpu_din = 32'd0;
  reg        cpu_valid = 1'b0;

  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .MPU_EN(1'b0)) dut (
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
    // cpu_run is forced at its DRIVER, the loader's register, not on pc9821_system's net: that
    // net reaches pc9821_memory_subsystem through an output port, and IEEE 1800-2017 23.3.3.7
    // makes both sides one net, but Verilator keeps them apart unless it inlines the module,
    // so a force on the outer net left the subsystem's own copy at 0 (its open bus, windows
    // and PEGC held in reset) under 5.054, which inlines after scoping. A force on the
    // variable reaches every reader through the port assigns under any inlining.
    force dut.memory.loader.cpu_run = 1'b1;
    force dut.z_inta = 1'b0;
    force dut.z_io = cpu_io;
    force dut.z_valid = cpu_valid;
    force dut.z_addr = cpu_addr;
    force dut.z_be = cpu_be;
    force dut.z_write = cpu_write;
    force dut.z_dout = cpu_din;
    force dut.z_burstcount = 8'd1;
    force dut.z_line_read = 1'b0;
  end

  task automatic fail(input string message);
    begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  // OUT port,data: one byte through the system's iobus.
  task automatic out8(input [15:0] port, input [7:0] data);
    integer waited;
    begin
      @(negedge clk_sys);
      cpu_io = 1'b1;
      cpu_addr = {16'd0, port[15:2]};
      cpu_be = 4'b0001 << port[1:0];
      cpu_write = 1'b1;
      cpu_din = 32'd0;
      cpu_din[{port[1:0], 3'b000} +: 8] = data;
      cpu_valid = 1'b1;
      waited = 0;
      while (!dut.io_cpu_ready) begin
        @(negedge clk_sys);
        waited = waited + 1;
        if (waited > 5000) $fatal(1, "TB_PC9821_E_PLANE_MODE: FAIL - OUT %04x never completed", port);
      end
      @(negedge clk_sys);
      cpu_valid = 1'b0; cpu_be = 4'd0; cpu_write = 1'b0; cpu_io = 1'b0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // One dword memory access; a read returns its data.
  task automatic mem32(input [31:0] addr, input bit wr, input [31:0] wdata, output [31:0] rdata);
    integer waited;
    bit got_resp;
    begin
      @(negedge clk_sys);
      cpu_io = 1'b0;
      cpu_addr = addr[31:2];
      cpu_be = 4'hF;
      cpu_write = wr;
      cpu_din = wdata;
      cpu_valid = 1'b1;
      got_resp = 1'b0;
      rdata = 32'hDEAD_BEEF;
      waited = 0;
      while (!dut.mem_cpu_ready) begin
        if (dut.mem_cpu_resp_valid) begin got_resp = 1'b1; rdata = dut.mem_cpu_dout; end
        @(negedge clk_sys);
        waited = waited + 1;
        if (waited > 5000) $fatal(1, "TB_PC9821_E_PLANE_MODE: FAIL - an access to %08x was never accepted", addr);
      end
      if (dut.mem_cpu_resp_valid) begin got_resp = 1'b1; rdata = dut.mem_cpu_dout; end
      @(negedge clk_sys);
      cpu_valid = 1'b0; cpu_be = 4'd0; cpu_write = 1'b0;
      if (!wr) begin
        waited = 0;
        while (!got_resp) begin
          if (dut.mem_cpu_resp_valid) begin got_resp = 1'b1; rdata = dut.mem_cpu_dout; end
          else begin
            @(negedge clk_sys);
            waited = waited + 1;
            if (waited > 5000) $fatal(1, "TB_PC9821_E_PLANE_MODE: FAIL - a read of %08x was never answered", addr);
          end
        end
      end
      repeat (8) @(negedge clk_sys);
    end
  endtask

  task automatic expect32(input [31:0] addr, input [31:0] want, input string what);
    reg [31:0] got;
    begin
      mem32(addr, 1'b0, 32'd0, got);
      $display("  read %08x -> %08x (want %08x) %s", addr, got, want, what);
      if (got !== want) fail($sformatf("%s: %08x read %08x, want %08x", what, addr, got, want));
    end
  endtask

  task automatic store32(input [31:0] addr, input [31:0] data);
    reg [31:0] ignored;
    mem32(addr, 1'b1, data, ignored);
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk_sys);
    reset = 0;
    repeat (200) @(negedge clk_sys);

    // (a) the digital mode the machine resets to: the slot is open bus (P4 view V1)
    store32(32'h000E_0004, 32'h0000_09EB);
    expect32(32'h000E_0004, 32'hFFFF_FFFF, "(a) digital mode: 0xE0004 reads FF and keeps no store (P4 V1)");
    store32(32'h000E_0000, 32'hAA55_FF00);
    expect32(32'h000E_0000, 32'hFFFF_FFFF, "(a) digital mode: 0xE0000 `wrote 00 FF 55 AA got FF FF FF FF` (VRAM2)");

    // (b) OUT 0x6A,0x01: the 16-colour select shows the E plane, which keeps a store
    out8(16'h006A, 8'h01);
    store32(32'h000E_0004, 32'h1234_5678);
    expect32(32'h000E_0004, 32'h1234_5678, "(b) 16-colour mode: the E plane round-trips the store");

    // (c) OUT 0x6A,0x00: hidden again, and a store there is dropped
    out8(16'h006A, 8'h00);
    expect32(32'h000E_0004, 32'hFFFF_FFFF, "(c) back in digital mode: open bus");
    store32(32'h000E_0004, 32'hCAFE_F00D);

    // (d) OUT 0x6A,0x01: the plane again, with the analog-mode byte and not the dropped one
    out8(16'h006A, 8'h01);
    expect32(32'h000E_0004, 32'h1234_5678, "(d) 16-colour mode again: the plane kept its byte, the digital store dropped");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_E_PLANE_MODE: FAIL - %0d check(s) failed", errors);
    $display("TB_PC9821_E_PLANE_MODE: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_E_PLANE_MODE: TIMEOUT");
  end
endmodule
