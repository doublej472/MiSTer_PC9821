`timescale 1ns / 1ps

// tb_pc9821_ide_bank1_hdd - IDE bank 1's master is the OSD's choice: the CD-ROM or a second disk.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_IDE_BANK1_HDD: In the CD build of pc9821_system with hard-disk images in hps_io slot 0 and slot 3, the OSD's IDE bank 1 field decides bank 1's master and applies only at a platform reset: at its default (CD-ROM) bank 1 answers the ATAPI signature 0x14/0xEB, port 0xF0 reads 0x89 and slot 3 is never read; set to HDD2 (after the reset) bank 1 answers the ATA signature (STATUS 0x50, ERROR 0x01, cylinder 0x00/0x00, 0x0433 = 0x00 with nothing pending), the CD drive is absent (no ATAPI signature, its interrupt cut), IDENTIFY at bank 1 reports slot 3's capacity in words 60/61 and at bank 0 slot 0's, READ SECTORS at bank 1 returns slot 3's sectors and at bank 0 slot 0's (each fetched from its own slot only), WRITE SECTORS at bank 1 reaches slot 3 alone, each bank keeps its own task file and nIEN, a completion on bank 1 holds the IDE interrupt and 0x0433 bit 1 while bank 0 is selected until bank 1's STATUS is read (and at the default a pending CD interrupt is 0x0433 bit 1 at either bank selection), a bank-1 read while bank 0's transfer holds DRQ shows bank 1's own registers (no DRQ), and an eject of slot 3 sets port 0xF0 bit 6 and leaves bank 1 the measured empty connector (0x0E/0x0F); and back at the default after a reset the CD is bank 1's master again.
//
// The references:
//   * the layout: the Xe10 IDE ROM registers an ATA device at any master its bitmap holds -
//     IDENTIFY, then `or [0x5ba],1<<slot` (BANK3@0x0A0A/0x0A96 of the Xe10 BIOS dump) -
//     and the ITF builds that bitmap from port 0xF0 bits 5/6, bit 6 = bank 1's master
//     (BANK4@0x19DF-0x19F2: `shr ah,4 / and ah,4 / ... / xor al,5`), active low; the measured
//     Xe10 byte 0xA9 has bit 6 clear with a drive on bank 1 (docs/probes/PORTS.TXT).
//   * two banks are two cables, each with its own device, task file, device control and INTRQ:
//     NP2kai cbus/ideio.c keeps one IDEDEV per bank (getidedev: `ideio.dev + bank`), and every
//     task-file register handler reads the selected bank's drive (getidedrv). Both banks share
//     one interrupt line (setintr: `pic_setirq(IDE_IRQ)`), each gated by its own nIEN.
//   * INTRQ stays asserted until the device's STATUS is read (ATA-3 r6 s.7.15: reading the
//     Status register clears a pending interrupt); a read of the OTHER bank's STATUS is another
//     device's register and acknowledges nothing (NP2kai ideio_i64e resets the IRQ only under
//     `if (drv)` for the selected bank's drive).
//   * ATA idle values: STATUS 0x50 (docs/probes/ATA.TXT 0x064E = 0x50), ERROR 0x01 after the
//     power-on diagnostic, the ATA (not packet) signature 0x00/0x00; the empty-bank float
//     0x0E/0x0F (probes/R10.TXT).
//   * 0x0433 is the per-bank interrupt-pending port: 00 with nothing pending at any bank, bit 0
//     bank 0's interrupt (docs/probes/KIT1-XE10-IDE1.TXT:18, the IRQ433 row), bit 1 bank 1's
//     whichever bank is selected (qemu-pc98 hw/ide/pc98-ide.c:203 `ret = s->irq_levels & 0x03;`).
//   * the ATAPI master's signature STATUS 0x00, cylinder 0x14/0xEB (NP2kai, the Xe10 IDE ROM's
//     presence test at BANK3@0x0D39).
//   * IDENTIFY words 60/61 = the drive's LBA capacity (ATA-3 r6 s.8.12, NP2kai setidentify).
//
// FAIL-FIRST: on the tree before the field the bench does not build (pc9821_system has no
// hdd1_* or ide_bank1_hdd port); with them it fails if bank 1's disk answers from slot 0, if
// the CD stays on the bus, or if one bank's registers leak into the other's (mutate_bench).
//
// The CPU is tests/pc9821/z486_stub.sv; the bench FORCES its side of the I/O handshake and
// cpu_run (no pack is loaded), so every access walks the REAL pc9821_iobus, device bus,
// pc9821_ata / pc9821_atapi, pc9821_hdd_image, pc9821_block_share and read mux.

`default_nettype none

module tb_pc9821_ide_bank1_hdd;
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
  reg        valid = 1'b0;

  // Slot 0 (HDD1) and slot 3 (HDD2): two raw images of different sizes and contents.
  localparam [31:0] SECS0 = 32'd8192, SECS3 = 32'd16384;
  reg         mount0 = 1'b0, mount3 = 1'b0;
  reg  [63:0] size0 = {23'd0, SECS0, 9'd0}, size3 = {23'd0, SECS3, 9'd0};
  wire [31:0] lba0, lba3;
  wire [5:0]  blk0, blk3;
  wire        rd0, wr0, rd3, wr3;
  reg         ack0 = 1'b0, ack3 = 1'b0;
  reg  [12:0] buff_addr = 13'd0;
  reg  [15:0] buff_din = 16'd0;
  reg         buff_wr = 1'b0;
  wire [15:0] dout0, dout3;
  reg         bank1_hdd = 1'b0;   // the OSD field
  wire        cd_rd;
  wire [31:0] cd_lba;
  wire [5:0]  cd_blk_cnt;

  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .CDROM_EN(1'b1), .CDROM_AUDIO_EN(1'b0)) dut (
      .clk_sys(clk_sys), .reset(reset), .hps_apply_reset(1'b0), .rtc(rtc), .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(1'b0),
      .ext_mem0_dout(32'd0), .ext_mem0_resp_valid(1'b0), .ext_mem0_ready(1'b1),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(16'd0),
      .img_mounted(mount0), .img_readonly(1'b0), .img_size(size0),
      .img_lba(lba0), .img_blk_cnt(blk0), .img_rd(rd0), .img_wr(wr0), .img_ack(ack0),
      .img_buff_addr(buff_addr), .img_buff_din(buff_din), .img_buff_dout(dout0), .img_buff_wr(buff_wr),
      .hdd1_mounted(mount3), .hdd1_size(size3), .hdd1_lba(lba3), .hdd1_blk_cnt(blk3),
      .hdd1_rd(rd3), .hdd1_wr(wr3), .hdd1_ack(ack3), .hdd1_buff_din(dout3),
      .ide_bank1_hdd(bank1_hdd),
      .cd_mounted(1'b0), .cd_size(64'd0), .cd_ack(1'b0), .cdda_req(1'b0), .cdda_req4(1'b0), .cdda_played(1'b0), .cdda_flush(),
      .cd_rd(cd_rd), .cd_lba(cd_lba), .cd_blk_cnt(cd_blk_cnt),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_byte(), .dbg_uart_we(), .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_set(4'd0));

  // The two images' words: a sector's word w of image u.
  function automatic [15:0] img_word(input bit u, input [31:0] lba, input [7:0] w);
    img_word = {(u ? 8'hB0 : 8'hA0) ^ lba[7:0], w};
  endfunction

  // ==== hps_io's side of slots 0 and 3: one transfer at a time, reads and writes ====
  integer rd_cnt [0:1];
  integer wr_cnt [0:1];
  reg [31:0] wr_lba [0:1];
  reg [15:0] wr_data [0:1][0:255];
  initial begin
    rd_cnt[0] = 0; rd_cnt[1] = 0; wr_cnt[0] = 0; wr_cnt[1] = 0;
  end
  always @(negedge clk_sys) begin : host
    integer words, w;
    reg u, is_rd;
    reg [31:0] lba;
    if (((rd0 || wr0) && !ack0) || ((rd3 || wr3) && !ack3)) begin
      u = !(rd0 || wr0);
      lba = u ? lba3 : lba0;
      is_rd = u ? rd3 : rd0;   // the request levels drop once the ack is seen
      words = ((u ? blk3 : blk0) + 1) * 256;
      if ($test$plusargs("HOSTLOG"))
        $display("HOST slot %0d %s lba=%0d blocks=%0d t=%0t", u ? 3 : 0, is_rd ? "read" : "write",
                 lba, words / 256, $time);
      repeat (6) @(negedge clk_sys);
      if (u) ack3 = 1; else ack0 = 1;
      repeat (3) @(negedge clk_sys);
      if (is_rd) begin
        rd_cnt[u] = rd_cnt[u] + 1;
        for (w = 0; w < words; w = w + 1) begin
          buff_addr = 13'(w);
          buff_din = img_word(u, lba + 32'(w / 256), 8'(w % 256));
          buff_wr = 1; @(negedge clk_sys); buff_wr = 0; @(negedge clk_sys);
        end
      end else begin
        wr_cnt[u] = wr_cnt[u] + 1;
        wr_lba[u] = lba;
        for (w = 0; w < words; w = w + 1) begin
          buff_addr = 13'(w);
          repeat (3) @(negedge clk_sys);
          if (w < 256) wr_data[u][w] = u ? dout3 : dout0;
        end
      end
      repeat (2) @(negedge clk_sys);
      ack0 = 0; ack3 = 0;
    end
  end

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
    force dut.z_io = 1'b1;
    force dut.z_valid = valid;
    force dut.z_addr = cpu_addr;
    force dut.z_be = cpu_be;
    force dut.z_write = cpu_write;
    force dut.z_dout = cpu_din;
  end

  task automatic fail(input string message);
    begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic io_byte(input [15:0] port, input bit wr, input [7:0] wdata, output [7:0] rdata);
    integer waited;
    reg [31:0] got;
    begin
      @(negedge clk_sys);
      cpu_addr = {16'd0, port[15:2]};
      cpu_be = 4'b0001 << port[1:0];
      cpu_write = wr;
      cpu_din = 32'd0;
      cpu_din[{port[1:0], 3'b000} +: 8] = wdata;
      valid = 1'b1;
      waited = 0;
      while (!dut.io_cpu_ready) begin
        @(negedge clk_sys);
        waited = waited + 1;
        if (waited > 5000) $fatal(1, "TB_PC9821_IDE_BANK1_HDD: FAIL - an I/O access to %04x never completed", port);
      end
      got = dut.io_cpu_dout;
      rdata = got[{port[1:0], 3'b000} +: 8];
      @(negedge clk_sys);
      valid = 1'b0; cpu_be = 4'd0; cpu_write = 1'b0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  task automatic wr(input [15:0] port, input [7:0] data);
    reg [7:0] ignored;
    io_byte(port, 1'b1, data, ignored);
  endtask

  task automatic rd(input [15:0] port, output [7:0] data);
    io_byte(port, 1'b0, 8'h00, data);
  endtask

  task automatic expect8(input [15:0] port, input [7:0] want, input string what);
    reg [7:0] got;
    begin
      rd(port, got);
      if (got !== want) fail($sformatf("%s: port %04x read %02x, want %02x", what, port, got, want));
    end
  endtask

  // Poll STATUS until BSY clears; return it.
  task automatic wait_ready(input string what, output [7:0] st);
    integer n;
    begin
      n = 0;
      rd(16'h064E, st);
      while (st[7] && n < 20000) begin rd(16'h074C, st); n = n + 1; end
      rd(16'h064E, st);
      if (st[7]) fail($sformatf("%s: the drive stayed BSY", what));
    end
  endtask

  // Read one 256-word sector from the data port.
  reg [15:0] sector [0:255];
  task automatic read_sector;
    integer w;
    reg [7:0] lo, hi;
    begin
      for (w = 0; w < 256; w = w + 1) begin
        rd(16'h0640, lo); rd(16'h0641, hi);
        sector[w] = {hi, lo};
      end
    end
  endtask

  task automatic select_bank(input bit b);
    wr(16'h0432, {7'd0, b});
  endtask

  // A READ SECTORS (0x20) in LBA mode at the selected bank; checks the sectors against image u.
  task automatic read_and_check(input bit u, input [27:0] lba, input [7:0] count, input string what);
    integer s, w, bad;
    reg [7:0] st;
    begin
      wr(16'h0644, count);
      wr(16'h0646, lba[7:0]); wr(16'h0648, lba[15:8]); wr(16'h064A, lba[23:16]);
      wr(16'h064C, {4'hE, lba[27:24]});
      wr(16'h064E, 8'h20);
      for (s = 0; s < count; s = s + 1) begin
        wait_ready(what, st);
        if (st !== 8'h58) fail($sformatf("%s: sector %0d STATUS %02x, want 0x58 (DRQ) (abort reason %0d)",
                                         what, s, st, dut.ata.dbg_abort_reason));
        read_sector;
        bad = 0;
        for (w = 0; w < 256; w = w + 1)
          if (sector[w] !== img_word(u, 32'(lba) + 32'(s), 8'(w))) bad = bad + 1;
        if (bad != 0)
          fail($sformatf("%s: sector %0d: %0d words differ from slot %0d's image (word 0 %04x, want %04x)",
                         what, s, bad, u ? 3 : 0, sector[0], img_word(u, 32'(lba) + 32'(s), 8'd0)));
      end
      wait_ready(what, st);
      if (st !== 8'h50) fail($sformatf("%s: final STATUS %02x, want 0x50", what, st));
    end
  endtask

  // IDENTIFY DEVICE at the selected bank: words 60/61.
  task automatic identify_capacity(output [31:0] cap, input string what);
    reg [7:0] st;
    begin
      wr(16'h064C, 8'hA0);
      wr(16'h064E, 8'hEC);
      wait_ready(what, st);
      if (st !== 8'h58) fail($sformatf("%s: IDENTIFY STATUS %02x, want 0x58", what, st));
      read_sector;
      cap = {sector[61], sector[60]};
    end
  endtask

  task automatic expect_cd_on_bank1(input string when);
    begin
      select_bank(1'b1); wr(16'h064C, 8'hA0);
      expect8(16'h064E, 8'h00, {when, ": bank 1's master STATUS (the ATAPI CD-ROM)"});
      expect8(16'h0648, 8'h14, {when, ": bank 1's master signature low (ATAPI)"});
      expect8(16'h064A, 8'hEB, {when, ": bank 1's master signature high (ATAPI)"});
      select_bank(1'b0);
    end
  endtask

  task automatic expect_ata_on_bank(input bit b, input string when);
    begin
      select_bank(b); wr(16'h064C, 8'hA0);
      expect8(16'h064E, 8'h50, {when, ": the master's idle STATUS (an ATA disk)"});
      expect8(16'h0642, 8'h01, {when, ": the master's ERROR (post-diagnostic)"});
      expect8(16'h0648, 8'h00, {when, ": the master's cylinder low (ATA, not ATAPI)"});
      expect8(16'h064A, 8'h00, {when, ": the master's cylinder high (ATA, not ATAPI)"});
      expect8(16'h0433, 8'h00, {when, ": 0x0433 with nothing pending (a device on the bank)"});
      select_bank(1'b0);
    end
  endtask

  task automatic platform_reset;
    begin
      @(negedge clk_sys); reset = 1;
      repeat (8) @(negedge clk_sys);
      reset = 0;
      repeat (200) @(negedge clk_sys);
    end
  endtask

  // ==== CHECKS ====
  integer rd3_before;
  reg [31:0] cap;
  reg [7:0]  st, b;
  integer w, bad;
  initial begin
    repeat (8) @(negedge clk_sys);
    reset = 0;
    repeat (200) @(negedge clk_sys);

    // (a) both images mounted, the field at its default (bank 1 = the CD-ROM)
    @(negedge clk_sys); mount0 = 1; @(negedge clk_sys); mount0 = 0;
    repeat (3000) @(negedge clk_sys);
    @(negedge clk_sys); mount3 = 1; @(negedge clk_sys); mount3 = 0;
    repeat (3000) @(negedge clk_sys);
    rd3_before = rd_cnt[1];
    expect8(16'h00F0, 8'h89, "(a) port 0xF0: disk on bank 0, the CD drive on bank 1");
    expect_ata_on_bank(1'b0, "(a) bank 0");
    expect_cd_on_bank1("(a) default: HDD2 is not on the bus");
    select_bank(1'b0);
    read_and_check(1'b0, 28'd5, 8'd1, "(a) READ at bank 0");
    // A READ SECTORS written at bank 1 is the CD drive's (which aborts it): the second disk
    // neither executes it nor raises the IDE interrupt.
    select_bank(1'b1);
    wr(16'h0644, 8'd1); wr(16'h0646, 8'd7); wr(16'h0648, 8'd0); wr(16'h064A, 8'd0);
    wr(16'h064C, 8'hE0); wr(16'h064E, 8'h20);
    repeat (3000) @(negedge clk_sys);
    if (dut.ata_irq !== 1'b0) fail("(a) the second disk answered a command at bank 1 with the CD selected");
    rd(16'h064E, st);
    // DEVICE RESET puts the CD drive's signature back (NP2kai atapi: 0x08 resets the device).
    wr(16'h064E, 8'h08);
    repeat (3000) @(negedge clk_sys);
    // The CD's pending DEVICE RESET interrupt is 0x0433 bit 1, at either bank selection.
    if (dut.cd_irq !== 1'b1) fail("(a) the CD's DEVICE RESET raised no interrupt: the 0x0433 rows are vacuous");
    expect8(16'h0433, 8'h02, "(a) 0x0433 bit 1: the CD's interrupt pending (bank 1 selected)");
    select_bank(1'b0);
    expect8(16'h0433, 8'h02, "(a) 0x0433 bit 1: the CD's interrupt pending (bank 0 selected)");
    select_bank(1'b1);
    rd(16'h064E, st);
    expect8(16'h0433, 8'h00, "(a) 0x0433 clears with the CD's STATUS read");
    select_bank(1'b0);
    if (rd_cnt[1] != rd3_before) fail("(a) slot 3 was read with the CD on bank 1");

    // (b) the field moved to HDD2 WITHOUT a reset: nothing changes yet
    bank1_hdd = 1'b1;
    repeat (100) @(negedge clk_sys);
    expect_cd_on_bank1("(b) field set, no reset yet");
    if (errors != 0) $fatal(1, "TB_PC9821_IDE_BANK1_HDD: FAIL - the default layout does not hold (%0d errors)", errors);

    // (c) the reset applies it: bank 1 is the second disk, the CD is gone
    platform_reset;
    expect8(16'h00F0, 8'h89, "(c) port 0xF0: a disk on each bank");
    expect_ata_on_bank(1'b0, "(c) bank 0");
    expect_ata_on_bank(1'b1, "(c) bank 1 = HDD2");
    select_bank(1'b1); wr(16'h064C, 8'hA0);
    rd(16'h0648, b);
    if (b == 8'h14) fail("(c) bank 1 still answers the ATAPI signature with HDD2 selected");
    select_bank(1'b0);

    // (d) IDENTIFY: each bank reports its own drive's capacity
    select_bank(1'b1);
    identify_capacity(cap, "(d) IDENTIFY at bank 1");
    if (cap !== SECS3) fail($sformatf("(d) bank 1 IDENTIFY words 60/61 = %0d, want slot 3's %0d", cap, SECS3));
    select_bank(1'b0);
    identify_capacity(cap, "(d) IDENTIFY at bank 0");
    if (cap !== SECS0) fail($sformatf("(d) bank 0 IDENTIFY words 60/61 = %0d, want slot 0's %0d", cap, SECS0));
    select_bank(1'b1);
    identify_capacity(cap, "(d) IDENTIFY at bank 1 again");
    if (cap !== SECS3) fail($sformatf("(d) bank 1 IDENTIFY words 60/61 = %0d, want slot 3's %0d", cap, SECS3));

    // (e) READ SECTORS: bank 1 reads slot 3, bank 0 reads slot 0, alternating (window flush)
    select_bank(1'b1);
    read_and_check(1'b1, 28'd5, 8'd3, "(e) READ at bank 1");
    select_bank(1'b0);
    read_and_check(1'b0, 28'd5, 8'd3, "(e) READ at bank 0");
    select_bank(1'b1);
    read_and_check(1'b1, 28'd6, 8'd2, "(e) READ at bank 1 again");
    // A sequential run long enough for the read-ahead window to fill from slot 3, then bank 0
    // reading LBAs that window holds: they must come from slot 0.
    read_and_check(1'b1, 28'd20, 8'd6, "(e) sequential READ at bank 1");
    select_bank(1'b0);
    read_and_check(1'b0, 28'd24, 8'd4, "(e) READ at bank 0 over bank 1's run");

    // (f) WRITE SECTORS at bank 1 reaches slot 3 only
    begin : f_write
      integer wr0_before;
      wr0_before = wr_cnt[0];
      select_bank(1'b1);
      wr(16'h0644, 8'd1); wr(16'h0646, 8'd9); wr(16'h0648, 8'd0); wr(16'h064A, 8'd0);
      wr(16'h064C, 8'hE0);
      wr(16'h064E, 8'h30);
      wait_ready("(f) WRITE at bank 1", st);
      if (st !== 8'h58) fail($sformatf("(f) WRITE STATUS %02x, want 0x58 (DRQ)", st));
      for (w = 0; w < 256; w = w + 1) begin
        wr(16'h0640, 8'(w)); wr(16'h0641, 8'hC3);
      end
      wait_ready("(f) WRITE completion", st);
      if (st !== 8'h50) fail($sformatf("(f) WRITE final STATUS %02x, want 0x50", st));
      repeat (200) @(negedge clk_sys);
      if (wr_cnt[1] != 1 || wr_lba[1] !== 32'd9)
        fail($sformatf("(f) slot 3 saw %0d writes (last LBA %0d), want one at LBA 9", wr_cnt[1], wr_lba[1]));
      if (wr_cnt[0] != wr0_before) fail("(f) the bank-1 write reached slot 0");
      bad = 0;
      for (w = 0; w < 256; w = w + 1) if (wr_data[1][w] !== {8'hC3, 8'(w)}) bad = bad + 1;
      if (bad != 0) fail($sformatf("(f) %0d words of the sector written to slot 3 differ", bad));
      select_bank(1'b0);
    end

    // (g) each bank keeps its own task file
    select_bank(1'b0); wr(16'h0644, 8'h11); wr(16'h0646, 8'h12);
    select_bank(1'b1); wr(16'h0644, 8'h21); wr(16'h0646, 8'h22);
    select_bank(1'b0);
    expect8(16'h0644, 8'h11, "(g) bank 0's sector count after bank 1's write");
    expect8(16'h0646, 8'h12, "(g) bank 0's sector number after bank 1's write");
    select_bank(1'b1);
    expect8(16'h0644, 8'h21, "(g) bank 1's sector count");
    expect8(16'h0646, 8'h22, "(g) bank 1's sector number");

    // (h) interrupt routing: bank 1's completion holds the line while bank 0 is selected
    select_bank(1'b0); wr(16'h074C, 8'h00); rd(16'h064E, st);
    select_bank(1'b1); wr(16'h074C, 8'h00); rd(16'h064E, st);
    if (dut.ata_irq !== 1'b0) fail("(h) the IDE interrupt is pending before the command");
    wr(16'h064C, 8'hA0);
    wr(16'h064E, 8'hEF);                       // SET FEATURES: a non-data command, one interrupt
    repeat (50) @(negedge clk_sys);
    if (dut.ata_irq !== 1'b1) fail("(h) bank 1's completion raised no interrupt");
    expect8(16'h0433, 8'h02, "(h) 0x0433 bit 1: bank 1's interrupt pending");
    select_bank(1'b0);
    expect8(16'h0433, 8'h02, "(h) 0x0433 bit 1 with bank 0 selected");
    rd(16'h064E, st);                          // bank 0's STATUS: another device's register
    if (dut.ata_irq !== 1'b1) fail("(h) a STATUS read at bank 0 acknowledged bank 1's interrupt");
    expect8(16'h0433, 8'h02, "(h) 0x0433 bit 1 survives bank 0's STATUS read");
    select_bank(1'b1);
    rd(16'h064E, st);
    if (dut.ata_irq !== 1'b0) fail("(h) bank 1's STATUS read did not acknowledge its interrupt");
    expect8(16'h0433, 8'h00, "(h) 0x0433 clears with bank 1's STATUS read");
    // bank 0's nIEN does not mask bank 1's INTRQ
    select_bank(1'b0); wr(16'h074C, 8'h02);
    select_bank(1'b1);
    wr(16'h064E, 8'hEF);
    repeat (50) @(negedge clk_sys);
    if (dut.ata_irq !== 1'b1) fail("(h) bank 0's nIEN masked bank 1's interrupt");
    rd(16'h064E, st);
    // bank 1's own nIEN masks it
    wr(16'h074C, 8'h02);
    wr(16'h064E, 8'hEF);
    repeat (50) @(negedge clk_sys);
    if (dut.ata_irq !== 1'b0) fail("(h) bank 1's nIEN did not mask its interrupt");
    wr(16'h074C, 8'h00); rd(16'h064E, st);
    select_bank(1'b0); wr(16'h074C, 8'h00); rd(16'h064E, st);
    if (dut.cd_irq !== 1'b0) fail("(h) the absent CD drive drives the interrupt");

    // (i) a bank-1 access while bank 0's transfer holds DRQ shows bank 1's own registers
    select_bank(1'b1); wr(16'h0644, 8'h33);
    select_bank(1'b0);
    wr(16'h0644, 8'd2); wr(16'h0646, 8'd40); wr(16'h0648, 8'd0); wr(16'h064A, 8'd0);
    wr(16'h064C, 8'hE0); wr(16'h064E, 8'h20);
    wait_ready("(i) READ at bank 0", st);
    if (st !== 8'h58) fail($sformatf("(i) bank 0 STATUS %02x, want 0x58", st));
    select_bank(1'b1);
    rd(16'h064E, st);
    if (st[3]) fail($sformatf("(i) bank 1 STATUS %02x carries bank 0's DRQ", st));
    expect8(16'h0644, 8'h33, "(i) bank 1's sector count during bank 0's transfer");
    select_bank(1'b0);
    for (w = 0; w < 2; w = w + 1) begin
      wait_ready("(i) bank 0 sector", st);
      read_sector;
      bad = 0;
      for (int k = 0; k < 256; k++) if (sector[k] !== img_word(1'b0, 32'd40 + 32'(w), 8'(k))) bad = bad + 1;
      if (bad != 0) fail($sformatf("(i) bank 0 sector %0d: %0d words differ after the bank-1 access", w, bad));
    end
    wait_ready("(i) bank 0 completion", st);
    select_bank(1'b1);
    expect8(16'h0644, 8'h33, "(i) bank 1's sector count after bank 0's transfer");
    read_and_check(1'b1, 28'd100, 8'd1, "(i) READ at bank 1 after the overlap");
    select_bank(1'b0);

    // (j) eject slot 3: bank 1 is an empty connector, port 0xF0 bit 6 set
    @(negedge clk_sys); size3 = 64'd0; mount3 = 1; @(negedge clk_sys); mount3 = 0;
    repeat (500) @(negedge clk_sys);
    expect8(16'h00F0, 8'hC9, "(j) port 0xF0 with slot 3 ejected (bank 1 empty)");
    select_bank(1'b1);
    expect8(16'h064E, 8'h0E, "(j) bank 1 floats (STATUS)");
    expect8(16'h074E, 8'h0F, "(j) bank 1 floats (0x074E)");
    expect8(16'h0433, 8'h00, "(j) 0x0433 at the empty bank 1");
    select_bank(1'b0);
    // (bank 0's ERROR is its last command's, 0x00, not the power-on 0x01 any more)
    wr(16'h064C, 8'hA0);
    expect8(16'h064E, 8'h50, "(j) bank 0's STATUS after the eject (idle, ready)");
    expect8(16'h0433, 8'h00, "(j) 0x0433 at bank 0 after the eject (nothing pending)");

    // (k) back to the default after a reset: the CD is bank 1's master again
    @(negedge clk_sys); size3 = {23'd0, SECS3, 9'd0}; mount3 = 1; @(negedge clk_sys); mount3 = 0;
    repeat (3000) @(negedge clk_sys);
    bank1_hdd = 1'b0;
    platform_reset;
    expect8(16'h00F0, 8'h89, "(k) port 0xF0 back at the default");
    expect_cd_on_bank1("(k) default again");
    expect_ata_on_bank(1'b0, "(k) bank 0");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_IDE_BANK1_HDD: FAIL - %0d check(s) failed", errors);
    $display("TB_PC9821_IDE_BANK1_HDD: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IDE_BANK1_HDD: TIMEOUT");
  end
endmodule
