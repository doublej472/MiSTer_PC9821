`timescale 1ns / 1ps

// tb_pc9821_ide_layout - the IDE layout is FIXED in both builds.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_IDE_LAYOUT: The built-in IDE layout is fixed in pc9821_system whatever the build and the media: in the build WITHOUT the CD (CDROM_EN 0) and in the build WITH it (CDROM_EN 1), the one hard disk (hps_io slot 0) answers as bank 0's master - 0x0432 = 0x00, 0x064C = 0xA0: STATUS 0x50, ERROR 0x01, cylinder 0x00/0x00 (an ATA, not a packet, signature) and 0x0433 = 0x02 - and the CD-ROM, when built, as bank 1's master - STATUS 0x00, 0x0642 = 0x01 and the 0x14/0xEB ATAPI signature the Xe10 IDE ROM's presence test reads - with bank 1 an empty connector without it (the measured empty-bank float: 0x064E = 0x064C = 0x0E, 0x074E = 0x0F); port 0xF0 reports exactly that, bit 5 = the hard disk (clear once it is mounted) and bit 6 = the CD drive (clear only in the CD build), so the Xe10 strap reads 0xE9 then 0xC9 without the CD and 0xA9 then 0x89 with it, the stock CD-equipped Xe10's 0x89; and in the CD build a disc mount and an eject move none of it.
//
// The reference for the layout is the stock CD-equipped PC-9821Xe10 (its hard disk on the first
// IDE connector, bank 0; its CD-ROM on the second, bank 1) and NP2kai's default (the hard disk at
// IDE unit 0, the CD-ROM at unit 2). The probed Xe10 answers at bank 1 (docs/probes/IDE.TXT)
// only because its CF card sits in the CD connector; the core follows the stock layout.
// The individual values:
//   * port 0xF0 bits 5/6 are the two connectors' drive-present lines, active low (the Xe10 ITF's
//     IDE drive bitmap, BANK4@0x19DF-0x19F2, and its 0x457 byte, BANK4@0x1B6C-0x1B8F); the
//     measured Xe10 byte 0xA9 (docs/probes/PORTS.TXT) has bit 5 set (bank 0 empty) and bit 6
//     clear (the CF card on bank 1). So: no hard disk and no CD -> 0xA9 | 0x40 = 0xE9; the disk
//     alone -> 0xC9; the CD alone -> 0xA9; both -> 0x89.
//   * an ATA hard disk's idle STATUS at its live bank is 0x50 (docs/probes/ATA.TXT: 0x064E = 0x50),
//     its ERROR after the power-on diagnostic 0x01 (the Xe10 IDE ROM accepts the unit only so),
//     its cylinder registers 0x00/0x00 (ATA-3: the packet signature 0x14/0xEB is a CD's), and
//     0x0433 = 0x02 at a bank with a device on it (NP2kai cbus/ideio.c ideio_i433).
//   * an ATAPI master at power-on: STATUS 0x00, ERROR 0x01, 0x0648/0x064A = 0x14/0xEB - the Xe10
//     IDE ROM's pre-reset presence test (BANK3@0x0D39), NP2kai's signature.
//   * an empty bank floats 0x0E across 0x0642-0x064E and 0x0F at 0x074C/0x074E (the probed Xe10
//     at its empty bank 0: probes/R10.TXT, JOY.TXT, WIN.TXT).
//
// FAIL-FIRST: before the layout was fixed the build without the CD put the disk on bank 1, so
// bank 0 floated 0x0E there and port 0xF0 read 0xA9 with the disk mounted - the CD-off half fails.
//
// The CPU is tests/pc9821/z486_stub.sv; the bench FORCES its side of the I/O handshake (z_valid,
// z_io, z_addr, z_be, z_write, z_dout; z_inta held low) and cpu_run (no pack is loaded), so every
// access walks the REAL pc9821_iobus, device bus, pc9821_ata / pc9821_atapi and read mux of the
// pc9821_system it builds - the layout under test is the system's own wiring, not a copy of it.

`default_nettype none

module tb_pc9821_ide_layout;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  integer errors = 0;

  // ==== DUT ====
  // the shared stimulus; each instance gets its own valid
  reg [31:2] cpu_addr = 30'd0;
  reg [3:0]  cpu_be = 4'd0;
  reg        cpu_write = 1'b0;
  reg [31:0] cpu_din = 32'd0;
  reg        valid_hd = 1'b0, valid_cd = 1'b0;
  reg        hdd_mount_hd = 1'b0, hdd_mount_cd = 1'b0;
  reg        cd_mount = 1'b0;
  reg [63:0] cd_size = 64'd0;
  localparam [63:0] HDD_BYTES = 64'd4_194_304;   // an 8192-sector disk image
  // Slot 0 (the hard disk): the mount detector reads the image's first and last sectors, so
  // each instance needs hps_io's acknowledge and word stream. The words are zero, which is
  // neither an HDI header nor a VHD footer, so the image mounts as raw - the layout this
  // bench is about is unchanged.
  wire        img_lba_hd_u, img_rd_hd, img_wr_hd, img_lba_cd_u, img_rd_cd, img_wr_cd;
  wire [31:0] img_lba_hd, img_lba_cd;
  wire [5:0]  img_blk_hd, img_blk_cd;
  reg         img_ack_hd = 1'b0, img_ack_cd = 1'b0;
  reg  [12:0] hd_buff_addr = 13'd0;
  reg         hd_buff_wr = 1'b0;

  // the build WITHOUT the CD-ROM (build_profile.py --no-cdrom)
  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .CDROM_EN(1'b0), .CDROM_AUDIO_EN(1'b0)) dut_hd (
      .clk_sys(clk_sys), .reset(reset), .hps_apply_reset(1'b0), .rtc(rtc), .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(1'b0),
      .ext_mem0_dout(32'd0), .ext_mem0_resp_valid(1'b0), .ext_mem0_ready(1'b1),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(16'd0),
      .img_mounted(hdd_mount_hd), .img_readonly(1'b0), .img_size(HDD_BYTES),
      .img_lba(img_lba_hd), .img_blk_cnt(img_blk_hd), .img_rd(img_rd_hd), .img_wr(img_wr_hd),
      .img_ack(img_ack_hd),
      .img_buff_addr(hd_buff_addr), .img_buff_din(16'd0), .img_buff_wr(hd_buff_wr),
      .cd_mounted(1'b0), .cd_size(64'd0), .cd_ack(1'b0), .cdda_req(1'b0), .cdda_req4(1'b0), .cdda_played(1'b0), .cdda_flush(),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_byte(), .dbg_uart_we(), .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_setup(1'b0), .bios_set(4'd0));

  // the build WITH the CD-ROM and its CD-DA player (every preset since 2026-10-10)
  wire        cd_rd;
  wire [31:0] cd_lba;
  wire [5:0]  cd_blk_cnt;
  reg         cd_ack = 1'b0, cd_buff_wr = 1'b0;
  reg  [12:0] cd_buff_addr = 13'd0;
  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .CDROM_EN(1'b1), .CDROM_AUDIO_EN(1'b1)) dut_cd (
      .clk_sys(clk_sys), .reset(reset), .hps_apply_reset(1'b0), .rtc(rtc), .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(1'b0),
      .ext_mem0_dout(32'd0), .ext_mem0_resp_valid(1'b0), .ext_mem0_ready(1'b1),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(16'd0),
      .img_mounted(hdd_mount_cd), .img_readonly(1'b0), .img_size(HDD_BYTES),
      .img_lba(img_lba_cd), .img_blk_cnt(img_blk_cd), .img_rd(img_rd_cd), .img_wr(img_wr_cd),
      .img_ack(img_ack_cd),
      .img_buff_addr(cd_buff_addr), .img_buff_din(16'd0), .img_buff_wr(cd_buff_wr),
      .cd_mounted(cd_mount), .cd_size(cd_size), .cd_ack(cd_ack), .cdda_req(1'b0), .cdda_req4(1'b0), .cdda_played(1'b0), .cdda_flush(),
      .cd_rd(cd_rd), .cd_lba(cd_lba), .cd_blk_cnt(cd_blk_cnt),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_byte(), .dbg_uart_we(), .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_setup(1'b0), .bios_set(4'd0));

  // hps_io's side of slot 0: serve each mount probe (first, then last sector) with 256 zero
  // words, one slot at a time. The no-CD instance has only the disk.
  always @(negedge clk_sys) begin : hd_host
    integer words, w;
    if (img_rd_hd && !img_ack_hd) begin
      words = (img_blk_hd + 1) * 256;
      repeat (6) @(negedge clk_sys);
      img_ack_hd = 1;
      repeat (3) @(negedge clk_sys);
      for (w = 0; w < words; w = w + 1) begin
        hd_buff_addr = 13'(w);
        hd_buff_wr = 1; @(negedge clk_sys); hd_buff_wr = 0; @(negedge clk_sys);
      end
      repeat (2) @(negedge clk_sys);
      img_ack_hd = 0;
    end
  end

  // hps_io's side of slot 4 and of the same instance's slot 0: the CD's header fetch at a
  // mount (zero words: an ISO whose first sectors are blank) and the disk's mount probes. The
  // two never overlap in this bench; the CD wins if they ever do.
  always @(negedge clk_sys) begin : cd_host
    integer words, w;
    if (cd_rd && !cd_ack) begin
      words = (cd_blk_cnt + 1) * 256;
      repeat (6) @(negedge clk_sys);
      cd_ack = 1;
      repeat (3) @(negedge clk_sys);
      for (w = 0; w < words; w = w + 1) begin
        cd_buff_addr = 13'(w);
        cd_buff_wr = 1; @(negedge clk_sys); cd_buff_wr = 0; @(negedge clk_sys);
      end
      repeat (2) @(negedge clk_sys);
      cd_ack = 0;
    end else if (img_rd_cd && !img_ack_cd) begin
      words = (img_blk_cd + 1) * 256;
      repeat (6) @(negedge clk_sys);
      img_ack_cd = 1;
      repeat (3) @(negedge clk_sys);
      for (w = 0; w < words; w = w + 1) begin
        cd_buff_addr = 13'(w);
        cd_buff_wr = 1; @(negedge clk_sys); cd_buff_wr = 0; @(negedge clk_sys);
      end
      repeat (2) @(negedge clk_sys);
      img_ack_cd = 0;
    end
  end

  // ==== THE CPU SIDE ====
  initial begin
    force dut_hd.cpu_run = 1'b1;  force dut_cd.cpu_run = 1'b1;
    force dut_hd.z_inta = 1'b0;   force dut_cd.z_inta = 1'b0;
    force dut_hd.z_io = 1'b1;     force dut_cd.z_io = 1'b1;
    force dut_hd.z_valid = valid_hd;  force dut_cd.z_valid = valid_cd;
    force dut_hd.z_addr = cpu_addr;   force dut_cd.z_addr = cpu_addr;
    force dut_hd.z_be = cpu_be;       force dut_cd.z_be = cpu_be;
    force dut_hd.z_write = cpu_write; force dut_cd.z_write = cpu_write;
    force dut_hd.z_dout = cpu_din;    force dut_cd.z_dout = cpu_din;
  end

  task automatic fail(input string message);
    begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  // One byte access on one build (cd = 0: the build without the CD, 1: with it).
  task automatic io_byte(input bit cd, input [15:0] port, input bit wr, input [7:0] wdata,
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
      if (cd) valid_cd = 1'b1; else valid_hd = 1'b1;
      waited = 0;
      while (!(cd ? dut_cd.io_cpu_ready : dut_hd.io_cpu_ready)) begin
        @(negedge clk_sys);
        waited = waited + 1;
        if (waited > 5000) $fatal(1, "TB_PC9821_IDE_LAYOUT: FAIL - an I/O access to %04x never completed", port);
      end
      got = cd ? dut_cd.io_cpu_dout : dut_hd.io_cpu_dout;
      rdata = got[{port[1:0], 3'b000} +: 8];
      @(negedge clk_sys);
      valid_hd = 1'b0; valid_cd = 1'b0; cpu_be = 4'd0; cpu_write = 1'b0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  task automatic wr(input bit cd, input [15:0] port, input [7:0] data);
    reg [7:0] ignored;
    io_byte(cd, port, 1'b1, data, ignored);
  endtask

  task automatic expect8(input bit cd, input [15:0] port, input [7:0] want, input string what);
    reg [7:0] got;
    begin
      io_byte(cd, port, 1'b0, 8'h00, got);
      if (got !== want)
        fail($sformatf("[%s] %s: port %04x read %02x, want %02x", cd ? "CD build" : "no-CD build",
                       what, port, got, want));
    end
  endtask

  // bank 0's master is the hard disk (when mounted)
  task automatic expect_hdd_on_bank0(input bit cd, input string when);
    begin
      wr(cd, 16'h0432, 8'h00); wr(cd, 16'h064C, 8'hA0);
      expect8(cd, 16'h064E, 8'h50, {when, ": bank 0's master STATUS (the hard disk, idle)"});
      expect8(cd, 16'h0642, 8'h01, {when, ": bank 0's master ERROR (post-diagnostic)"});
      expect8(cd, 16'h0648, 8'h00, {when, ": bank 0's master cylinder low (ATA, not ATAPI)"});
      expect8(cd, 16'h064A, 8'h00, {when, ": bank 0's master cylinder high (ATA, not ATAPI)"});
      expect8(cd, 16'h0433, 8'h02, {when, ": 0x0433 at bank 0 (a device on the bank)"});
    end
  endtask

  // bank 1's master is the CD-ROM (CD build) or nothing (no-CD build)
  task automatic expect_bank1(input bit cd, input string when);
    begin
      wr(cd, 16'h0432, 8'h01); wr(cd, 16'h064C, 8'hA0);
      if (cd) begin
        expect8(cd, 16'h064E, 8'h00, {when, ": bank 1's master STATUS (the ATAPI CD-ROM)"});
        expect8(cd, 16'h0642, 8'h01, {when, ": bank 1's master ERROR"});
        expect8(cd, 16'h0648, 8'h14, {when, ": bank 1's master signature low (ATAPI)"});
        expect8(cd, 16'h064A, 8'hEB, {when, ": bank 1's master signature high (ATAPI)"});
      end else begin
        expect8(cd, 16'h064E, 8'h0E, {when, ": bank 1 is an empty connector (STATUS floats)"});
        expect8(cd, 16'h064C, 8'h0E, {when, ": bank 1 is an empty connector (0x064C floats)"});
        expect8(cd, 16'h074E, 8'h0F, {when, ": bank 1 is an empty connector (0x074E floats)"});
      end
      wr(cd, 16'h0432, 8'h00);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk_sys);
    reset = 0;
    repeat (200) @(negedge clk_sys);

    // (a) nothing mounted: bit 5 set in both builds; bit 6 set only where bank 1 is empty
    expect8(0, 16'h00F0, 8'hE9, "(a) port 0xF0 with no hard disk and no CD drive");
    expect8(1, 16'h00F0, 8'hA9, "(a) port 0xF0 with no hard disk, the CD drive built");
    expect_bank1(0, "(a)");
    expect_bank1(1, "(a)");

    // (b) the hard disk mounted (hps_io slot 0's mount event)
    @(negedge clk_sys); hdd_mount_hd = 1; hdd_mount_cd = 1;
    @(negedge clk_sys); hdd_mount_hd = 0; hdd_mount_cd = 0;
    repeat (2000) @(negedge clk_sys);
    expect8(0, 16'h00F0, 8'hC9, "(b) port 0xF0 with the hard disk, no CD drive");
    expect8(1, 16'h00F0, 8'h89, "(b) port 0xF0 with the hard disk and the CD drive (the stock Xe10)");
    expect_hdd_on_bank0(0, "(b)");
    expect_hdd_on_bank0(1, "(b)");
    expect_bank1(0, "(b)");
    expect_bank1(1, "(b)");
    if (errors != 0) $fatal(1, "TB_PC9821_IDE_LAYOUT: FAIL - the fixed layout does not hold (%0d errors)", errors);

    // (c) the CD build: a disc mount, then an eject (the size-0 event), move nothing
    @(negedge clk_sys); cd_size = 64'd2048 * 64'd300; cd_mount = 1;
    @(negedge clk_sys); cd_mount = 0;
    repeat (20000) @(negedge clk_sys);
    expect8(1, 16'h00F0, 8'h89, "(c) port 0xF0 after a disc mount");
    expect_hdd_on_bank0(1, "(c) disc mounted");
    wr(1, 16'h0432, 8'h01); wr(1, 16'h064C, 8'hA0);
    expect8(1, 16'h0648, 8'h14, "(c) disc mounted: bank 1's master signature low (ATAPI)");
    expect8(1, 16'h064A, 8'hEB, "(c) disc mounted: bank 1's master signature high (ATAPI)");
    wr(1, 16'h0432, 8'h00);
    @(negedge clk_sys); cd_size = 64'd0; cd_mount = 1;
    @(negedge clk_sys); cd_mount = 0;
    repeat (2000) @(negedge clk_sys);
    expect8(1, 16'h00F0, 8'h89, "(c) port 0xF0 after an eject");
    expect_hdd_on_bank0(1, "(c) ejected");
    wr(1, 16'h0432, 8'h01); wr(1, 16'h064C, 8'hA0);
    expect8(1, 16'h0648, 8'h14, "(c) ejected: bank 1's master signature low (ATAPI)");
    expect8(1, 16'h064A, 8'hEB, "(c) ejected: bank 1's master signature high (ATAPI)");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_IDE_LAYOUT: FAIL - %0d check(s) failed", errors);
    $display("TB_PC9821_IDE_LAYOUT: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IDE_LAYOUT: TIMEOUT");
  end
endmodule
