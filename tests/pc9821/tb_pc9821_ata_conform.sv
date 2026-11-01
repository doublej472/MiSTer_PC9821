`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// A conformance sweep of the PC-9821 ATA interface against NP2kai's cbus/ideio.c: the port register file (0x0430/0x0432/0x0433/0x0435 and the 0x064x/0x074x block), a PIO sector read and write, the status/error semantics (a command abort, an ERROR-register read, READ VERIFY) and the reset paths (software reset, DEVICE RESET, EXECUTE DEVICE DIAGNOSTIC, NOP) are each compared word for word with the reference, while the IDENTIFY words are asserted against the machine's capture with the PIO-only core's documented capability substitutions (docs/probes/IDE.TXT) for the same capacity. The NP2kai divergences Round 3 fixed are asserted; ten documented divergences (the measured 0x0430/0x074E/0x064C, the 0x0644/0x0646 post-reset default, the still-waived 0x90 diagnostic error signature, and the withdrawn multiple-mode words 47/59) print a WAIVED line, while DEVICE RESET is asserted against the MACHINE (status 0x51 / ERROR 0x04, docs/probes/IDE.TXT:343) where NP2kai's 0x01|0x80 disagrees, and so is the ERROR-register read, which keeps STATUS.ERR on the machine (IDE.TXT:343,349) where NP2kai's ideio_i642 clears it.

module tb_pc9821_ata_conform;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd13600;   // 100 cylinders x 8 heads x 17 sectors
  wire block_read, block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq;
  wire [7:0] dbg_state;
  wire [31:0] dbg_cmd;

  // ==== DUT ====
  pc9821_ata dut (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk),
      .rst_n(rst_n),
      .io_rd(io_rd),
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted),
      .readonly(readonly),
      .capacity(capacity),
      .block_read(block_read),
      .block_write(block_write),
      .block_lba(block_lba),
      .block_done(block_done),
      .block_error(block_error),
      .block_buf_we(block_buf_we),
      .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr),
      .block_rd_data(block_rd_data),
      .irq(irq),
      .dbg_state(dbg_state),
      .dbg_cmd(dbg_cmd)
  );

  integer errors = 0, cases = 0, n, waivers = 0, read_errors = 0;
  reg [7:0] value, lo, hi;
  reg [15:0] word_value;

  // ==== STIMULUS ====
  // The oracle is NP2kai cbus/ideio.c (primary); each expectation below names the
  // handler it comes from. qemu hw/ide/pc98-ide.c + hw/ide/core.c is the secondary
  // cross-check and is cited where it differs from NP2kai.
  task automatic check(input [8*40-1:0] name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%04x np2kai=0x%04x", name, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = 0x%04x", name, got);
    end
  endtask

  // The same assertion with the MACHINE as the oracle, for the rows a committed capture
  // settles against the reference (DEVICE RESET's 0x51/0x04).
  task automatic check_machine(input [8*40-1:0] name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%04x machine=0x%04x", name, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = 0x%04x", name, got);
    end
  endtask

  // A case kept as a documented divergence: a measured-probe override (0x0430, 0x074E,
  // power-on 0x064C), a value an EXISTING bench pins (0x0644/0x0646, the 0x90 error
  // signature), or a reference split the core answers with qemu. PRINT the bytes and
  // count a waiver, do not assert either.
  task automatic waive(input [8*40-1:0] name, input [15:0] got, input [15:0] np2);
    begin
      cases = cases + 1;
      waivers = waivers + 1;
      $display("WAIVED   %0s: rtl=0x%04x np2kai=0x%04x (documented)", name, got, np2);
    end
  endtask

  task automatic write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_din  = data;
      io_wr   = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_rd   = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task automatic read_word(output [15:0] data);
    reg [7:0] l, h;
    begin
      read_byte(16'h0640, l);
      read_byte(16'h0641, h);
      data = {h, l};
    end
  endtask

  task automatic write_word(input [15:0] data);
    begin
      write_byte(16'h0640, data[7:0]);
      write_byte(16'h0641, data[15:8]);
    end
  endtask

  // Poll the ALTERNATE status (0x074C) so the read does not acknowledge the IRQ:
  // the pending-interrupt checks need that latch intact.
  task automatic wait_drq_alt;
    begin
      n = 0;
      read_byte(16'h074C, value);
      while (!value[3] && n < 8000) begin
        read_byte(16'h074C, value);
        n = n + 1;
      end
    end
  endtask

  task automatic wait_idle_alt;
    begin
      n = 0;
      read_byte(16'h074C, value);
      while (value[7] && n < 8000) begin
        read_byte(16'h074C, value);
        n = n + 1;
      end
    end
  endtask

  // Software reset, the pair the BIOS uses: SRST set then clear.
  task automatic srst;
    begin
      write_byte(16'h074C, 8'h04);
      write_byte(16'h074C, 8'h00);
    end
  endtask

  // Synthetic block device: sector byte N is LBA[7:0] XOR N[7:0], so word i is
  // {LBA ^ (2i+1), LBA ^ (2i)}. Fills reads and checks writes.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    sector_word_for = {lba[7:0] ^ {index[6:0], 1'b1}, lba[7:0] ^ {index[6:0], 1'b0}};
  endfunction

  reg block_active = 0;
  reg [7:0] block_index = 0;
  reg drain_active = 0;
  integer write_errors = 0;
  // Host block requests whose LBA is at or beyond the mounted image: the end-of-image
  // tests require this to stay 0, where the pre-fix start-only range
  // check let a multi-sector command run past capacity.
  integer oor_reads = 0, oor_writes = 0;

  always @(negedge clk) begin
    block_buf_we = 0;
    block_done   = 0;
    block_error  = 0;
    if (!block_active && block_read) begin
      if (block_lba >= capacity) oor_reads = oor_reads + 1;
      block_active = 1;
      block_index  = 0;
    end else if (block_active) begin
      block_buf_we   = 1;
      block_buf_addr = block_index;
      block_buf_data = sector_word_for(block_lba, block_index);
      if (block_index == 8'd255) begin
        block_active = 0;
        block_done   = 1;
      end else block_index = block_index + 8'd1;
    end

    if (!drain_active && block_write) begin
      if (block_lba >= capacity) oor_writes = oor_writes + 1;
      drain_active  = 1;
      block_rd_addr = 0;
    end else if (drain_active) begin
      if (block_rd_data !== sector_word_for(block_lba, block_rd_addr))
        write_errors = write_errors + 1;
      if (block_rd_addr == 8'd255) begin
        drain_active = 0;
        block_done   = 1;
      end else block_rd_addr = block_rd_addr + 8'd1;
    end
  end

  reg [15:0] idw[0:255];

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (200) @(posedge clk);          // let the capacity-derived cylinder count settle
    write_byte(16'h0432, 8'h00);          // the bank the built-in interface is on

    // ---- 1. a channel with no image is no drive at all ----
    // NP2kai devinit (cbus/ideio.c) leaves drv->device = IDETYPE_NONE when its sxsi is
    // not READY, getidedrv() then returns NULL, and every task-file handler returns
    // 0xff (ideio_i64e, ideio_i646). This core keeps answering its registers.
    mounted = 0;
    repeat (8) @(posedge clk);
    read_byte(16'h064E, value); check("noimage_status", value, 8'hFF);
    read_byte(16'h0646, value); check("noimage_sector_number", value, 8'hFF);
    mounted = 1;
    repeat (8) @(posedge clk);

    // ---- 2. the interface registers ----
    // NP2kai ideio_i430 returns bit 0 set for a connected layout and bit 6 ONLY when
    // the selected channel has a slave (dev->drv[1].device != IDETYPE_NONE); this
    // model has one master, so the reference answers 0x01. qemu agrees (0x01).
    read_byte(16'h0430, value); waive("reg_430_connection_report", value, 8'h01);
    // NP2kai ideio_i430 for 0x0432 returns the stored bank byte & 0x7f; qemu
    // pc98_ide_chsel_read adds 0x40 (slave-capable). This core matches NP2kai here.
    read_byte(16'h0432, value); check("reg_432_bank_readback", value, 8'h00);
    // NP2kai ideio_i435 is a constant 0.
    read_byte(16'h0435, value); check("reg_435", value, 8'h00);

    // Power-on task file. NP2kai devinit sets status = DRDY|DSC and error = AMNF; it does
    // NOT load dr/sc/sn, which are only set by a reset or a task-file write. qemu's
    // ide_reset sets status = READY|SEEK and error = 0 but select = 0xa0.
    read_byte(16'h064E, value); check("reg_64e_reset_status", value, 8'h50);
    read_byte(16'h074C, value); check("reg_74c_alt_status", value, 8'h50);
    read_byte(16'h0644, value); waive("reg_644_reset_count", value, 8'h00);
    read_byte(16'h0646, value); waive("reg_646_reset_sector", value, 8'h00);
    read_byte(16'h0648, value); check("reg_648_reset_cyl_lo", value, 8'h00);
    read_byte(16'h064A, value); check("reg_64a_reset_cyl_hi", value, 8'h00);
    read_byte(16'h064C, value); waive("reg_64c_reset_drivehead", value, 8'h00);

    // ---- 3. the drive-address register at 0x074E ----
    // NP2kai ideio_i74e returns 0xc0 | (~hd & 0xf) << 2 | (drivesel == 0 ? 2 : 1), so a
    // head of 0 reads 0xFE. qemu pc98_ide_drive_addr_read is the same formula. This core
    // answers a constant 0x00.
    read_byte(16'h074E, value); waive("reg_74e_drive_addr_head0", value, 8'hFE);
    write_byte(16'h064C, 8'hA5);          // head number 5
    read_byte(16'h074E, value); waive("reg_74e_drive_addr_head5", value, 8'hEA);
    write_byte(16'h064C, 8'hA0);

    // ---- 4. the data register with DRQ clear ----
    // NP2kai ideio_r16 returns 0 when a drive is present but DRQ is clear; qemu
    // ide_data_readw returns 0 under the same condition. This core answers 0xFF.
    read_byte(16'h0640, lo);
    read_byte(16'h0641, hi);
    check("reg_data_drq_clear", {hi, lo}, 16'h0000);

    // ---- 5. IDENTIFY DEVICE ----
    write_byte(16'h064E, 8'hEC);
    read_byte(16'h074C, value); check("id_cmd_status", value, 8'h58);
    check("id_cmd_irq", irq, 16'd1);
    for (n = 0; n < 256; n = n + 1) read_word(idw[n]);

    // The oracle is the machine's own capture (docs/probes/IDE.TXT) applied to
    // this bench's capacity (13600 sectors, 8 heads x 17 sectors), with the
    // factory-default 16-head/63-sector words 1/3/4/6 computed the same way.
    check("id_word_0_device_type", idw[0], 16'h044A);
    check("id_word_1_cylinders", idw[1], 16'd13);
    check("id_word_3_heads", idw[3], 16'd16);
    // factory default: 63 sectors * 512 bytes
    check("id_word_4_bytes_per_track", idw[4], 16'h7E00);
    check("id_word_5_bytes_per_sector", idw[5], 16'h0200);
    check("id_word_6_sectors_per_track", idw[6], 16'd63);
    check("id_word_22_ecc_bytes", idw[22], 16'd4);
    // tmp[27] = model[0..1] = 'Q','U'
    check("id_word_27_model_string", idw[27], 16'h5155);
    // tmp[47] = 0x8000 | IDEIO_MULTIPLE_MAX (128). The core WITHDRAWS this on
    // purpose: it buffers one sector at a time and the Xe10 ROM's READ
    // MULTIPLE consumes a whole block without checking DRQ, so the multiple
    // advertisement would corrupt a streamed read. The commands stay implemented.
    waive("id_word_47_multiple_count", idw[47], 16'h8080);
    check("id_word_49_lba_capable", idw[49], 16'h0200);
    check("id_word_51_pio_timing", idw[51], 16'h0200);
    check("id_word_53_validity", idw[53], 16'h0003);
    check("id_word_54_current_cylinders", idw[54], 16'd100);
    check("id_word_55_current_heads", idw[55], 16'd8);
    check("id_word_56_current_sectors", idw[56], 16'd17);
    check("id_word_57_capacity_low", idw[57], 16'd13600);
    // tmp[59] = 0x0100 | mulmode. Withdrawn with word 47: the valid
    // bit must not claim a multiple setting the advertisement denies.
    waive("id_word_59_multiple_mode", idw[59], 16'h0180);
    check("id_word_60_lba_capacity_low", idw[60], 16'd13600);
    check("id_word_64_pio_modes", idw[64], 16'h0003);
    check("id_word_80_ata_levels", idw[80], 16'h0000);
    check("id_word_82_features", idw[82], 16'h4200);
    // hardware reset result: passed, no cable ID (the machine's 0x4000)
    check("id_word_93_hw_config", idw[93], 16'h4000);

    // ---- 6. PIO sector read ----
    write_byte(16'h0644, 8'h01);
    write_byte(16'h0646, 8'h05);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    read_byte(16'h064E, value);           // acknowledge the IDENTIFY IRQ first
    write_byte(16'h064E, 8'h20);
    wait_drq_alt;
    check("read_drq_status", value, 8'h58);
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      // The PIO read is claimed word-for-word, so EVERY word is compared
      // against the model, not only word 0. A serializer/index corruption after the first
      // word used to drain all 256 but assert only the first.
      if (word_value !== sector_word_for(32'd5, n[7:0])) begin
        $display("MISMATCH read_data_word_%0d: rtl=0x%04x np2kai=0x%04x",
                 n, word_value, sector_word_for(32'd5, n[7:0]));
        read_errors = read_errors + 1;
      end
    end
    check("read_data_words", read_errors[15:0], 16'd0);
    read_byte(16'h074C, value); check("read_complete_status", value, 8'h50);
    // NP2kai ideio_r16 calls incsec() after the last word, so the task-file sector number
    // register advances past the sector just read. This core leaves it where the guest set.
    read_byte(16'h0646, value); check("read_advances_sector_number", value, 8'h06);
    read_byte(16'h0644, value); check("read_sector_count_after", value, 8'h00);

    // ---- 7. PIO sector write ----
    write_byte(16'h0644, 8'h01);
    write_byte(16'h0646, 8'h20);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h30);
    wait_drq_alt;
    check("write_drq_status", value, 8'h58);
    for (n = 0; n < 256; n = n + 1) write_word(sector_word_for(32'h20, n[7:0]));
    wait_idle_alt;
    check("write_complete_status", value, 8'h50);
    check("write_data_pattern", write_errors, 0);
    read_byte(16'h0646, value); check("write_advances_sector_number", value, 8'h21);
    read_byte(16'h0644, value); check("write_sector_count_after", value, 8'h00);

    // ---- 8. an aborted command's status and error ----
    // NP2kai cmdabort sets status = DRDY|ERR (DSC CLEAR) and error = ABRT, then setintr.
    // qemu ide_abort_command is the same 0x41. 0xDE (MEDIA LOCK) aborts on a hard disk in
    // both references and in this core.
    write_byte(16'h074C, 8'h04);          // park + clear the pending IRQ
    write_byte(16'h074C, 8'h00);
    read_byte(16'h064E, value);
    write_byte(16'h064E, 8'hDE);
    read_byte(16'h074C, value); check("abort_status_no_dsc", value, 8'h41);
    check("abort_irq", irq, 16'd1);
    read_byte(16'h0642, value); check("abort_error_abrt", value, 8'h04);
    // The MACHINE keeps STATUS.ERR across an ERROR read (docs/probes/IDE.TXT:343,349: 0x51
    // after the 0x0642 read and a 0x064C write), where NP2kai ideio_i642 clears it (0x40).
    read_byte(16'h074C, value); check_machine("error_read_keeps_status_err", value, 8'h41);

    // ---- 9. READ VERIFY (0x40) ----
    // NP2kai accepts it: `drv->status &= ~IDESTAT_BSY; setintr(drv);` with no error. qemu
    // routes it to cmd_verify (success, SET_DSC). This core aborts it.
    write_byte(16'h074C, 8'h04);
    write_byte(16'h074C, 8'h00);
    read_byte(16'h064E, value);
    write_byte(16'h064E, 8'hE1);          // IDLE IMMEDIATE: error = 0 in both references
    read_byte(16'h064E, value);
    write_byte(16'h064E, 8'h40);
    read_byte(16'h074C, value); check("read_verify_status", value, 8'h50);
    read_byte(16'h0642, value); check("read_verify_error", value, 8'h00);

    // ---- 10. software reset ----
    // NP2kai ideio_o74c on SRST assert sets status = 0 and error = 0 for both drives; it
    // does not set BSY. This core enters BSY. (qemu's ide_ctrl_write calls ide_bus_reset,
    // which leaves READY|SEEK and error 0.)
    write_byte(16'h074C, 8'h04);
    read_byte(16'h074C, value); check("srst_assert_status", value, 8'h00);
    write_byte(16'h074C, 8'h00);
    read_byte(16'h074C, value); check("srst_deassert_status", value, 8'h50);
    read_byte(16'h0642, value); check("srst_deassert_error", value, 8'h01);
    read_byte(16'h0644, value); check("srst_deassert_count", value, 8'h01);
    read_byte(16'h0646, value); check("srst_deassert_sector", value, 8'h01);
    // NP2kai drvreset() reloads hd = 0 but leaves dr untouched, so 0x064C reads the last
    // high nibble the guest wrote.
    write_byte(16'h064C, 8'hA7);
    srst;
    read_byte(16'h064C, value); check("srst_clears_head_select", value, 8'hA0);

    // ---- 11. power/diagnostic commands ----
    // NP2kai ideio_o64e case 0x00 is an empty `break`: it changes neither status nor error
    // and raises no interrupt. qemu has no WIN_NOP entry and aborts. This core completes it.
    srst;
    read_byte(16'h064E, value);           // clear any pending IRQ
    check("nop_no_pending_irq", irq, 16'd0);
    write_byte(16'h064E, 8'h00);
    check("nop_irq", irq, 16'd0);
    read_byte(16'h0642, value); check("nop_error_unchanged", value, 8'h01);

    // The machine's own DIAG section is the expected value here, not NP2kai: the probe
    // polls 0x064E for !BSY and then reads 0x0642 -- status 0x51, ERROR 0x04
    // (docs/probes/IDE.TXT:343, tools/hwprobe/ideprobe/ideprobe.s:826 (`/* DEVICE RESET */`)). NP2kai's
    // 0x01|0x80 is another drive's AMNF presence signature and its drvreset does not
    // set STATUS.ERR at all, so the reference and the machine disagree on this one
    // command; the machine and the ATA definition (a device reset is an ABORT: STATUS
    // ERR + ERROR ABRT) agree, and they win. 0x90 below keeps its waiver.
    srst;
    read_byte(16'h064E, value);
    write_byte(16'h064E, 8'h08);
    read_byte(16'h074C, value); check_machine("device_reset_status", value, 8'h51);
    read_byte(16'h0642, value); check_machine("device_reset_error", value, 8'h04);

    // NP2kai EXECUTE DEVICE DIAGNOSTIC (0x90) sets the same error signature and RETURNS
    // WITHOUT setintr (the case is handled before the shared epilogue). This core raises
    // an interrupt and reports AMNF alone.
    srst;
    read_byte(16'h064E, value);
    write_byte(16'h064E, 8'h90);
    read_byte(16'h074C, value); check("diagnostic_status", value, 8'h50);
    waive("diagnostic_irq", {15'b0, irq}, 16'd0);
    read_byte(16'h0642, value); waive("diagnostic_error", value, 8'h81);

    // ---- 12. end-of-image range validation ----
    // A data command at capacity-1 with a count that does NOT fit must be REJECTED. The four
    // data commands once validated only the START lba, so the second sector (lba = capacity) ran
    // past the image: the status here was BSY/DRQ and oor_reads/oor_writes became non-zero. The
    // block model counts any host request at or beyond capacity, so these checks fail on the
    // pre-fix tree. capacity-1 = 13599 = 0x351F.
    srst;
    read_byte(16'h064E, value);
    oor_reads = 0;
    write_byte(16'h0644, 8'h02);
    write_byte(16'h0646, 8'h1F);
    write_byte(16'h0648, 8'h35);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h20);
    repeat (600) @(negedge clk);       // let a wrongly-accepted read run to the overrun
    read_byte(16'h074C, value); check("eoi_read_count2_status", value, 8'h41);
    read_byte(16'h0642, value); check("eoi_read_count2_error", value, 8'h04);
    check("eoi_read_count2_no_oor", oor_reads, 0);

    srst;
    read_byte(16'h064E, value);
    oor_reads = 0;
    write_byte(16'h0644, 8'h00);          // count 256
    write_byte(16'h0646, 8'h1F);
    write_byte(16'h0648, 8'h35);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'hC4);          // READ MULTIPLE
    repeat (600) @(negedge clk);
    read_byte(16'h074C, value); check("eoi_read_count256_status", value, 8'h41);
    check("eoi_read_count256_no_oor", oor_reads, 0);

    srst;
    read_byte(16'h064E, value);
    oor_writes = 0;
    write_byte(16'h0644, 8'h02);
    write_byte(16'h0646, 8'h1F);
    write_byte(16'h0648, 8'h35);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h30);          // WRITE SECTORS
    read_byte(16'h074C, value); check("eoi_write_count2_status", value, 8'h41);
    read_byte(16'h0642, value); check("eoi_write_count2_error", value, 8'h04);
    check("eoi_write_count2_no_oor", oor_writes, 0);

    srst;
    read_byte(16'h064E, value);
    oor_writes = 0;
    write_byte(16'h0644, 8'h00);          // count 256
    write_byte(16'h0646, 8'h1F);
    write_byte(16'h0648, 8'h35);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'hC5);          // WRITE MULTIPLE
    read_byte(16'h074C, value); check("eoi_write_count256_status", value, 8'h41);
    check("eoi_write_count256_no_oor", oor_writes, 0);

    // ---- 13. READ NATIVE MAX (0xF8) ----
    // NP2kai ideio.c:1162-1173 loads the capacity-derived address into the task file before
    // interrupting (sn = totals & 0xff, cy = (totals >> 8) & 0xffff, hd low nibble =
    // (totals >> 24) & 0xf), leaving the high drive/head bits. 0xF8 once
    // shared the STANDBY/IDLE arm and returned whatever address the caller had preloaded. A
    // DIFFERENT address is preloaded here so all four fields must be rewritten.
    // capacity = 13600 = 0x3520 -> sn 0x20, cy 0x0035, hd low nibble 0 (high nibble kept).
    srst;
    read_byte(16'h064E, value);
    write_byte(16'h0646, 8'hAA);
    write_byte(16'h0648, 8'hBB);
    write_byte(16'h064A, 8'hCC);
    write_byte(16'h064C, 8'hA5);
    write_byte(16'h064E, 8'hF8);
    read_byte(16'h074C, value); check("native_max_status", value, 8'h50);
    read_byte(16'h0646, value); check("native_max_sector_number", value, 8'h20);
    read_byte(16'h0648, value); check("native_max_cylinder_low", value, 8'h35);
    read_byte(16'h064A, value); check("native_max_cylinder_high", value, 8'h00);
    read_byte(16'h064C, value); check("native_max_drive_head", value, 8'hA0);

    // ==== VERDICT ====
    $display("NOTE ata_conform: %0d cases, %0d mismatched, %0d waived",
             cases, errors, waivers);
    if (errors == 0) begin
      $display("TB_PC9821_ATA_CONFORM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_CONFORM: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_ATA_CONFORM: TIMEOUT");
  end

endmodule
