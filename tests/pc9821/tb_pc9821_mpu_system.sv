`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MPU_SYSTEM: The MPU-PC98II reaches the guest through pc9821_system when the build carries it AND the OSD's UART mode is MIDI (mpu_present): with MPU_EN 1 (the base preset) and the card present an I/O read of its status port 0xE0D2 walks the real pc9821_iobus and device select to the card and answers 0x80 (response queue empty, not busy), its data port 0xE0D0 answers the reset latch 0xFE, a command written to 0xE0D2 queues an ACK that clears status bit 7 (0x00) and raises the card's IRQ6 into the master PIC, the data read returns that ACK 0xFE, and status returns to 0x80; with MPU_EN 0, and with MPU_EN 1 in any other UART mode, both ports read open bus 0xFF in the same bus time, a command raises no IRQ6 and is not ACKed; and a mode flip mid-session (H.CLK running, then UART mode entered) drops the card at once and brings it back in its power-on state: status 0x80, no H.CLK byte 12 ms later, and a command ACKed in intelligent mode.
//
// The expected values are the reference's: NP2kai cbus/mpu98ii.c, with the card at its default
// option 0x82 (pccore.c `np2cfg.mpuopt = 0x82; /* E0D0, INT2 */`):
//   * the base port, `mpu98.port = 0xc0d0 | ((pConfig->mpuopt & 0xf0) << 6)` = 0xE0D0, and the
//     card attaches exactly `port` (data, mpu98ii_i0/o0) and `port |= 2` (status/command,
//     mpu98ii_i2/o2) in mpu98ii_bind;
//   * the status read, mpu98ii_i2: `ret = mpu98.status;` (0 after the reset's ZeroMemory, the
//     write counter idle so MIDIOUT_BUSY 0x40 is clear) and `ret |= MIDIIN_AVAIL;` (0x80) when
//     `(mpu98.r.cnt == 0) && (mpu98.intreq == 0)`: idle 0x80, 0x00 with a byte queued;
//   * the data read of an empty queue returns `mpu98.data`, which the reset sets to
//     `mpu98.data = MPUMSG_ACK;` (0xFE);
//   * every intelligent-mode command, mpu98ii_o2: `setrecvdata(MPUMSG_ACK);` then
//     `mpu98ii_int();` on the card's IRQ, `mpuirqnum[pConfig->mpuopt & 3]` = IRQ6 for 0x82.
//     The command used here, 0x94 (clock-to-host off), sends nothing to the MIDI line, so the
//     BUSY bit cannot be set by it.
// With the card absent no handler is attached and the port is open bus, 0xFF.
//
// PRESENT ONLY IN MIDI MODE (the owner's rule, not a hardware fact): a real card is present or
// not; this core shows it to software only while the OSD routes the UART to MIDI, so a guest that
// would pick MIDI over FM when it finds an MPU keeps FM by default. Absent must be
// indistinguishable from MPU_EN 0: the same 0xFF, the same access time, no IRQ. A mode flip
// is a card removed and re-inserted, so it comes back in NP2kai's mpu98ii_reset state
// (`ZeroMemory(&mpu98, sizeof(mpu98));`, `mpu98.data = MPUMSG_ACK;`): queue empty, H.CLK off
// (0x94/0x95 are mpu98ii.c's clock-to-host off/on), intelligent mode (`mpu98.mode` 0; 0x3F
// enters UART mode, where mpu98ii_o2 ACKs only 0xFF).
//
// FAIL-FIRST: pc9821_system's pc9821_iobus instance did not pass MPU_EN, so the iobus's device
// select decoded 0xE0D0/0xE0D2 with its default MPU_EN 0 even in a build that instantiated the
// card: the MPU_EN 1 half read 0xFF at both ports and no command ever reached the card. Then the
// card answered in every UART mode (no mpu_present input), which the absent and flip halves fail.
//
// The CPU is tests/pc9821/z486_stub.sv; the bench FORCES its side of the I/O handshake (z_valid,
// z_io, z_addr, z_be, z_write, z_dout; z_inta held low) and cpu_run (no pack is loaded), the
// pattern tb_pc9821_ide_layout uses, so every access walks the system's own iobus, device
// select, device bus and read mux. The IRQ is observed at the master PIC's aux input, the
// pc9821_interrupts port pc9821_system drives with `{mpu_irq, 3'b000}`.

`default_nettype none

module tb_pc9821_mpu_system;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  integer errors = 0;
  integer t_absent = 0;

  // ==== DUT ====
  reg [31:2] cpu_addr = 30'd0;
  reg [3:0]  cpu_be = 4'd0;
  reg        cpu_write = 1'b0;
  reg [31:0] cpu_din = 32'd0;
  reg        valid_off = 1'b0, valid_on = 1'b0;
  reg        present_on = 1'b1;      // the MPU_EN 1 build's OSD UART mode: 1 = MIDI

  // the build WITHOUT the card (build_profile.py --no-mpu)
  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .MPU_EN(1'b0)) dut_off (
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
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_setup(1'b0), .bios_set(4'd0),
      .mpu_present(1'b1));   // MIDI mode: without the card built there is still nothing there

  // the build WITH the card (the base preset: build_profile.py's mpu_en)
  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .MPU_EN(1'b1)) dut_on (
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
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_setup(1'b0), .bios_set(4'd0),
      .mpu_present(present_on));

  // ==== THE CPU SIDE ====
  initial begin
    force dut_off.cpu_run = 1'b1;   force dut_on.cpu_run = 1'b1;
    force dut_off.z_inta = 1'b0;    force dut_on.z_inta = 1'b0;
    force dut_off.z_io = 1'b1;      force dut_on.z_io = 1'b1;
    force dut_off.z_valid = valid_off; force dut_on.z_valid = valid_on;
    force dut_off.z_addr = cpu_addr;   force dut_on.z_addr = cpu_addr;
    force dut_off.z_be = cpu_be;       force dut_on.z_be = cpu_be;
    force dut_off.z_write = cpu_write; force dut_on.z_write = cpu_write;
    force dut_off.z_dout = cpu_din;    force dut_on.z_dout = cpu_din;
  end

  // The card's IRQ6 as the master PIC sees it (master_aux_irq bit 3 = IR6).
  wire irq6_off = dut_off.interrupts.master_aux_irq[3];
  wire irq6_on  = dut_on.interrupts.master_aux_irq[3];

  task automatic fail(input string message);
    begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  // One byte access on one build (on = 0: without the card, 1: with it). last_wait is the
  // access's bus time in clk_sys, from the request to the ready.
  integer last_wait = 0;
  task automatic io_byte(input bit on, input [15:0] port, input bit wr, input [7:0] wdata,
                         output [7:0] rdata);
    integer waited;
    reg [31:0] got;
    begin
      @(negedge clk_sys);
      cpu_addr = {16'd0, port[15:2]};
      cpu_be = 4'b0001 << port[1:0];
      cpu_write = wr;
      cpu_din = 32'd0;
      cpu_din[{port[1:0], 3'b000} +: 8] = wdata;
      if (on) valid_on = 1'b1; else valid_off = 1'b1;
      waited = 0;
      while (!(on ? dut_on.io_cpu_ready : dut_off.io_cpu_ready)) begin
        @(negedge clk_sys);
        waited = waited + 1;
        if (waited > 5000) $fatal(1, "TB_PC9821_MPU_SYSTEM: FAIL - an I/O access to %04x never completed", port);
      end
      last_wait = waited;
      got = on ? dut_on.io_cpu_dout : dut_off.io_cpu_dout;
      rdata = got[{port[1:0], 3'b000} +: 8];
      @(negedge clk_sys);
      valid_on = 1'b0; valid_off = 1'b0; cpu_be = 4'd0; cpu_write = 1'b0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  task automatic wr(input bit on, input [15:0] port, input [7:0] data);
    reg [7:0] ignored;
    io_byte(on, port, 1'b1, data, ignored);
  endtask

  task automatic expect8(input bit on, input [15:0] port, input [7:0] want, input string what);
    reg [7:0] got;
    begin
      io_byte(on, port, 1'b0, 8'h00, got);
      $display("  [%s] in %04x -> %02x (want %02x) %s", on ? "MPU_EN 1" : "MPU_EN 0", port, got, want, what);
      if (got !== want)
        fail($sformatf("[%s] %s: port %04x read %02x, want %02x", on ? "MPU_EN 1" : "MPU_EN 0",
                       what, port, got, want));
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk_sys);
    reset = 0;
    repeat (200) @(negedge clk_sys);

    // (a) the build without the card: both ports are open bus, a command reaches nothing
    expect8(0, 16'hE0D2, 8'hFF, "(a) no card: status port is open bus");
    expect8(0, 16'hE0D0, 8'hFF, "(a) no card: data port is open bus");
    wr(0, 16'hE0D2, 8'h94);
    if (irq6_off !== 1'b0) fail("(a) no card: IRQ6 rose after a write to 0xE0D2");
    expect8(0, 16'hE0D2, 8'hFF, "(a) no card: status port after a command write");

    // (b) the build with the card, idle after reset
    if (irq6_on !== 1'b0) fail("(b) the card's IRQ6 is up with nothing queued");
    expect8(1, 16'hE0D2, 8'h80, "(b) idle status: response queue empty, not busy");
    expect8(1, 16'hE0D0, 8'hFE, "(b) data port of an empty queue: the reset latch MPUMSG_ACK");

    // (c) a command is ACKed: status bit 7 clears, IRQ6 rises, the data port returns 0xFE
    wr(1, 16'hE0D2, 8'h94);
    if (irq6_on !== 1'b1) fail("(c) IRQ6 did not rise with the command's ACK queued");
    expect8(1, 16'hE0D2, 8'h00, "(c) status with the ACK queued");
    expect8(1, 16'hE0D0, 8'hFE, "(c) the queued ACK");
    if (irq6_on !== 1'b0) fail("(c) IRQ6 stayed up after the queue drained");
    expect8(1, 16'hE0D2, 8'h80, "(c) status after the queue drained");

    // (d) any other UART mode: the card is absent, exactly as with MPU_EN 0
    @(negedge clk_sys); present_on = 1'b0; repeat (4) @(negedge clk_sys);
    expect8(1, 16'hE0D2, 8'hFF, "(d) not MIDI: status port is open bus");
    t_absent = last_wait;
    expect8(0, 16'hE0D2, 8'hFF, "(d) reference: the MPU_EN 0 read of the same port");
    if (last_wait != t_absent)
      fail($sformatf("(d) the absent card's read took %0d clk_sys, the MPU_EN 0 open-bus read %0d",
                     t_absent, last_wait));
    expect8(1, 16'hE0D0, 8'hFF, "(d) not MIDI: data port is open bus");
    wr(1, 16'hE0D2, 8'h94);
    if (irq6_on !== 1'b0) fail("(d) not MIDI: IRQ6 rose after a command write");
    expect8(1, 16'hE0D2, 8'hFF, "(d) not MIDI: status after a command write");
    expect8(1, 16'hE0D0, 8'hFF, "(d) not MIDI: no ACK on the data port");
    @(negedge clk_sys); present_on = 1'b1; repeat (4) @(negedge clk_sys);
    expect8(1, 16'hE0D2, 8'h80, "(d) back in MIDI: no ACK left over from the absent write");

    // (e) a mode flip mid-session: H.CLK running with its byte queued, then gone, then back
    wr(1, 16'hE0D2, 8'h95);                    // clock-to-host on: ACK, then 0xFD at once
    expect8(1, 16'hE0D0, 8'hFE, "(e) 0x95's ACK");
    if (irq6_on !== 1'b1) fail("(e) IRQ6 not up with the H.CLK byte queued");
    @(negedge clk_sys); present_on = 1'b0; repeat (4) @(negedge clk_sys);
    if (irq6_on !== 1'b0) fail("(e) IRQ6 stayed up after the card disappeared");
    expect8(1, 16'hE0D2, 8'hFF, "(e) gone: status port is open bus");
    @(negedge clk_sys); present_on = 1'b1; repeat (4) @(negedge clk_sys);
    if (irq6_on !== 1'b0) fail("(e) IRQ6 up when the card came back (its queue was not emptied)");
    expect8(1, 16'hE0D2, 8'h80, "(e) back: the power-on status, queue empty");
    repeat (600_000) @(negedge clk_sys);        // 12 ms: two of the 5 ms stepclocks
    expect8(1, 16'hE0D2, 8'h80, "(e) back: no H.CLK byte (clock-to-host off at power-on)");
    if (irq6_on !== 1'b0) fail("(e) IRQ6 rose: the H.CLK survived the card's removal");
    // and UART mode (0x3F) entered, then the card removed and re-inserted: intelligent mode again
    wr(1, 16'hE0D2, 8'h3F);
    expect8(1, 16'hE0D0, 8'hFE, "(e) 0x3F's ACK");
    @(negedge clk_sys); present_on = 1'b0; repeat (4) @(negedge clk_sys);
    @(negedge clk_sys); present_on = 1'b1; repeat (4) @(negedge clk_sys);
    wr(1, 16'hE0D2, 8'h94);
    expect8(1, 16'hE0D2, 8'h00, "(e) back: a command is ACKed (intelligent mode, not UART mode)");
    expect8(1, 16'hE0D0, 8'hFE, "(e) back: that ACK");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_MPU_SYSTEM: FAIL - %0d check(s) failed", errors);
    $display("TB_PC9821_MPU_SYSTEM: PASS");
    $finish;
  end

  initial begin
    #100_000_000;
    $fatal(1, "TB_PC9821_MPU_SYSTEM: TIMEOUT");
  end
endmodule
