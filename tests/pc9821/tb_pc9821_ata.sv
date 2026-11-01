// tb_pc9821_ata - focused PC-98 ATA task-file, PIO read and PIO write checks.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA:
// The ATA task file as the machine has it: the measured 0x0430 connection report (0x41), the DRDY|DSC reset status, IDENTIFY raising DRQ and IRQ, a status read acknowledging that IRQ, the IDENTIFY words, PIO reads and writes through the block adapter, both data phases as the ROM's own 0x0432 save/restore bracket leaves them, and rejected commands honouring nIEN. Its single-sector write is preceded by one STRAY read of the high data port mid-transfer, which the read serializer must ignore because DRQ is set on the write path too: gating that read on DRQ alone advances the byte index by a word and hands the sector over two words early, which the drain of the modelled block adapter sees.


module tb_pc9821_ata;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1;
  reg readonly = 0;
  reg [31:0] capacity = 32'd1000;
  wire block_read;
  wire block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq;

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
      .irq(irq)
  );

  integer errors = 0;
  integer n;
  reg [7:0] value;
  reg [15:0] word_value;

  task fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_byte(input [15:0] addr, input [7:0] data);
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

  task read_byte(input [15:0] addr, output [7:0] data);
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

  task read_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      data = {hi, lo};
    end
  endtask

  task write_word(input [15:0] data);
    begin
      write_byte(16'h0640, data[7:0]);
      write_byte(16'h0641, data[15:8]);
    end
  endtask

  task wait_idle;
    begin
      n = 0;
      while (dut.xfer_state !== 3'd0 && n < 8000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (dut.xfer_state !== 3'd0) fail("ATA transfer did not complete");
    end
  endtask

  // block_write is a one-cycle pulse, and the model that counts it is resumed by the
  // same negedge as the stimulus, so an immediate comparison races that event. Wait
  // for the count with a bound instead.
  task wait_write_count(input integer want, input [8*56-1:0] what);
    begin
      n = 0;
      while (seen_write_count < want && n < 4000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (seen_write_count < want) fail(what);
    end
  endtask

  task wait_drq;
    begin
      n = 0;
      while (!dut.status_reg[3] && n < 2000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!dut.status_reg[3]) fail("ATA DRQ timeout");
    end
  endtask

  // Synthetic block device: sector byte N is LBA[7:0] XOR N[7:0], so word
  // index i is {LBA ^ (2i+1), LBA ^ (2i)}. Used both to fill the buffer for
  // reads and to check what the guest wrote for writes.
  // ==== STIMULUS ====
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  reg block_active = 0;
  reg [7:0] block_index = 0;
  reg [31:0] seen_lba[0:3];
  integer seen_count = 0;

  // Write side: when the drive asks for a block write, drain the sector buffer
  // through the read port it muxes for this direction, one word per cycle, and
  // compare against the pattern the guest was told to write.
  reg        drain_active = 0;
  integer    write_errors = 0;
  reg [31:0] seen_write_lba[0:3];
  integer    seen_write_count = 0;

  always @(negedge clk) begin
    block_buf_we = 0;
    block_done   = 0;
    block_error  = 0;
    if (!block_active && block_read) begin
      block_active = 1;
      block_index = 0;
      seen_lba[seen_count] = block_lba;
      seen_count = seen_count + 1;
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
      drain_active = 1;
      block_rd_addr = 0;
      seen_write_lba[seen_write_count] = block_lba;
      seen_write_count = seen_write_count + 1;
    end else if (drain_active) begin
      // block_rd_data is combinational from the address presented last cycle.
      if (block_rd_data !== sector_word_for(block_lba, block_rd_addr))
        write_errors = write_errors + 1;
      if (block_rd_addr == 8'd255) begin
        drain_active = 0;
        block_done   = 1;
      end else block_rd_addr = block_rd_addr + 8'd1;
    end
  end
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // Wait for the capacity-derived cylinder count to settle before any
    // IDENTIFY data is read.
    while (dut.current_cylinders !== 16'd7) @(negedge clk);

    // 0x0430 reports the measured value, 0x41, twice reproducibly on the real
    // machine with its internal IDE. Bit 6 is a STRAP bit, not "the selected
    // channel has a slave": the 0x01 this core used to answer was invented so
    // that our own free IDE ROM would not map a phantom slave, and that
    // firmware is gone. A measurement outranks it.
    read_byte(16'h0430, value);
    if (value !== 8'h41) fail("0x0430 connection report (measured 0x41)");
    // The task file is a window on the interface at the selected bank: it
    // answers at the hard disk's bank (0x00: bank 0's master, the core's fixed layout)
    // and floats at a bank with nothing behind it (0x01 without the CD; the probed
    // machine shows an empty bank's whole block at 0x0E in probes/JOY.TXT and
    // probes/WIN.TXT). The bank
    // values, the float, and the command-after-bank-select case are asserted by
    // tests/pc9821/tb_pc9821_ata_blockmap.sv through ports only.
    write_byte(16'h0432, 8'h00);
    read_byte(16'h064E, value);
    if (value !== 8'h50) fail("reset status is not DRDY|DSC");

    // IDENTIFY: verify the geometry/capacity words while consuming all data.
    write_byte(16'h064E, 8'hEC);
    if (!irq || dut.status_reg !== 8'h58) fail("IDENTIFY did not raise DRQ/IRQ");
    read_byte(16'h064E, value);  // acknowledge IRQ without clearing DRQ
    if (irq || value !== 8'h58) fail("status read did not acknowledge IDENTIFY IRQ");
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      case (n)
        0: if (word_value !== 16'h044A) fail("IDENTIFY word 0");
        1: if (word_value !== 16'd0) fail("IDENTIFY default cylinders");
        3: if (word_value !== 16'd16) fail("IDENTIFY default heads");
        6: if (word_value !== 16'd63) fail("IDENTIFY default sectors/track");
        // NP2kai's setidentify advertises multiple-block mode (word 47 = 0x8080);
        // this model withdraws it. It buffers one sector at a time and the Xe10
        // ROM's READ MULTIPLE does not check DRQ, so a streamed block would splice
        // 0x00 into the file. 0 sends the ROM to single-sector READ SECTORS. The
        // multiple commands are still implemented and pinned by ata_multiple.
        47: if (word_value !== 16'h0000) fail("IDENTIFY multiple count");
        49: if (word_value !== 16'h0200) fail("IDENTIFY LBA capability");
        60: if (word_value !== 16'd1000) fail("IDENTIFY LBA capacity low");
        61: if (word_value !== 16'd0) fail("IDENTIFY LBA capacity high");
        default: ;
      endcase
    end
    if (dut.status_reg !== 8'h50 || dut.xfer_state !== 0) fail("IDENTIFY did not finish");

    // One LBA28 sector at LBA 5.
    seen_count = 0;
    write_byte(16'h0644, 8'h01);
    write_byte(16'h0646, 8'h05);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h20);
    if (dut.status_reg !== 8'h80) fail("READ did not enter BSY");
    wait_drq();
    if (seen_count != 1 || seen_lba[0] !== 32'd5) fail("LBA28 block request");
    read_word(word_value);
    if (word_value !== 16'h0405) fail("sector first PIO word");
    for (n = 1; n < 256; n = n + 1) begin
      read_word(word_value);
      if (word_value !== sector_word_for(32'd5, n[7:0]))
        fail("LBA 5 sector word mismatch");
    end
    if (dut.status_reg !== 8'h50) fail("single-sector read did not finish");

    // CHS C=2, H=3, S=4 -> ((2*8+3)*17)+(4-1) = LBA 326.
    write_byte(16'h0644, 8'h01);
    write_byte(16'h0646, 8'h04);
    write_byte(16'h0648, 8'h02);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hA3);
    write_byte(16'h064E, 8'h20);
    wait_drq();
    if (seen_lba[1] !== 32'd326) fail("CHS block translation");
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      if (word_value !== sector_word_for(32'd326, n[7:0]))
        fail("CHS-translated sector word mismatch");
    end

    // Two-sector LBA read issues a second request only after sector 0 drains.
    write_byte(16'h0644, 8'h02);
    write_byte(16'h0646, 8'h0A);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h20);
    wait_drq();
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      if (word_value !== sector_word_for(32'd10, n[7:0]))
        fail("multi-sector read, first sector word mismatch");
    end
    wait_drq();
    if (seen_lba[2] !== 32'd10 || seen_lba[3] !== 32'd11) fail("multi-sector LBA sequence");
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      if (word_value !== sector_word_for(32'd11, n[7:0]))
        fail("multi-sector read, second sector word mismatch");
    end
    if (dut.status_reg !== 8'h50 || dut.sector_count !== 8'h00)
      fail("multi-sector read did not finish");

    // Single-sector write at LBA 0x20: the drive accepts the command, takes 256
    // words, hands the buffer to the block adapter, and the adapter must observe
    // exactly the bytes the guest wrote. One word in the middle is preceded by a
    // STRAY READ of the high data port: a confused driver can do that, and the read
    // serializer is gated on the transfer state (X_PIO_READ/X_PIO_IDENT) exactly as
    // the write mirror at :466 is gated on X_PIO_WRITE. Gating it on DRQ alone is not
    // enough, because the WRITE phase sets DRQ too (the WRITE SECTORS arm sets
    // READY|DRQ) -- and the ungated arm runs the READ path's `pio_byte += 2`, which
    // skips a word of the sector and hands the block over two words early.
    write_byte(16'h0644, 8'h01);
    write_byte(16'h0646, 8'h20);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h30);
    wait_drq();
    for (n = 0; n < 256; n = n + 1) begin
      if (n == 100) begin
        read_byte(16'h0641, value);
        if (!dut.status_reg[3] || dut.xfer_state !== 3'd4)
          fail("a stray 0x641 read during a PIO write disturbed the write phase");
      end
      write_word(sector_word_for(32'h20, n[7:0]));
    end
    wait_idle();
    if (write_errors != 0)
      fail("single-sector write pattern mismatch (a stray 0x641 read during the PIO write was not ignored)");
    if (seen_write_count != 1 || seen_write_lba[0] !== 32'd32)
      fail("single-sector write LBA");
    if (dut.status_reg !== 8'h50 || dut.sector_count !== 8'h00)
      fail("single-sector write did not finish");

    // Two-sector write: the second block is requested only after the first has
    // been handed over, for the next LBA.
    write_byte(16'h0644, 8'h02);
    write_byte(16'h0646, 8'h40);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h30);
    wait_drq();
    for (n = 0; n < 256; n = n + 1) write_word(sector_word_for(32'h40, n[7:0]));
    wait_write_count(2, "second write block not requested");
    wait_drq();
    for (n = 0; n < 256; n = n + 1) write_word(sector_word_for(32'h41, n[7:0]));
    wait_idle();
    wait_write_count(3, "write block count");
    // Slot 0 was the single-sector write above, so the two-sector write is in
    // slots 1 and 2.
    if (seen_write_lba[1] !== 32'd64 || seen_write_lba[2] !== 32'd65)
      fail("multi-sector write LBA sequence");
    if (write_errors != 0) fail("multi-sector write pattern mismatch");

    // A read-only image rejects writes cleanly, before any host transaction.
    readonly = 1;
    write_byte(16'h064E, 8'h30);
    if (dut.status_reg !== 8'h41 || dut.error_reg !== 8'h04)
      fail("write to a read-only image was not rejected");
    readonly = 0;

    // WRITE MULTIPLE (0xC5) without a preceding SET MULTIPLE MODE completes: the
    // power-up multiple count is NP2kai's IDEIO_MULTIPLE_MAX (128), so a write-only
    // guest that skips 0xC6 is still served rather than ABRTed. One sector here; the
    // block interrupt cadence is tb_pc9821_ata_multiple's.
    write_byte(16'h0644, 8'd1);
    write_byte(16'h0646, 8'h60);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'hC5);
    if (dut.status_reg !== 8'h58 || dut.error_reg !== 8'h00)
      fail("WRITE MULTIPLE did not arm the write path");
    for (n = 0; n < 256; n = n + 1) write_word(sector_word_for(32'h60, n[7:0]));
    wait_write_count(4, "WRITE MULTIPLE did not request its block");
    wait_idle();
    if (dut.status_reg !== 8'h50) fail("WRITE MULTIPLE did not finish READY|DSC");
    if (seen_write_lba[3] !== 32'd96) fail("WRITE MULTIPLE LBA");
    if (write_errors != 0) fail("WRITE MULTIPLE pattern mismatch");

    // Power, idle and diagnostic commands must complete successfully. The PC-98
    // IDE BIOS polls the status register for exactly READY|DSC (0x50) after IDLE
    // IMMEDIATE, so an abort here (0x51 with ERR set) leaves it spinning until it
    // times out and the drive class and geometry never get set.
    write_byte(16'h064E, 8'hE1);          // IDLE IMMEDIATE
    if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h00)
      fail("IDLE IMMEDIATE did not complete successfully");
    write_byte(16'h064E, 8'hE5);          // CHECK POWER MODE
    if (dut.status_reg !== 8'h50 || dut.sector_count !== 8'hFF)
      fail("CHECK POWER MODE did not report the drive active");
    write_byte(16'h064E, 8'h90);          // EXECUTE DEVICE DIAGNOSTIC
    if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h01)
      fail("EXECUTE DEVICE DIAGNOSTIC did not leave the pass signature");
    write_byte(16'h064E, 8'h08);          // DEVICE RESET
    // The machine, not NP2kai: its own DIAG section polls 0x064E for !BSY and then
    // reads 0x0642 -- "after 0x08 status = 51 ; after 0x08 ERROR(0642) = 04"
    // (docs/probes/IDE.TXT:343, tools/hwprobe/ideprobe/ideprobe.s:826 (`/* DEVICE RESET */`)). The ATA
    // definition says the same thing: a DEVICE RESET is an ABORT, so STATUS takes ERR
    // and ERROR takes ABRT. The old 0x50/0x01 pair was another drive's AMNF presence
    // signature, so a guest classifying the reset by STATUS.ERR (the ATA contract)
    // read a failed reset as success.
    if (dut.status_reg !== 8'h51 || dut.error_reg !== 8'h04)
      fail("DEVICE RESET did not leave the machine's 0x51/0x04 abort signature");

    // INITIALIZE DEVICE PARAMETERS: the fixed PC-98 geometry is accepted, any
    // other geometry aborts rather than being quietly ignored.
    write_byte(16'h0644, 8'd17);
    // The head nibble is the highest head number, so the platform's 8 heads are
    // encoded as 7 (NP2kai: surfaces = hd + 1; QEMU: heads = (select & 0xF) + 1).
    write_byte(16'h064C, 8'hA7);
    write_byte(16'h064E, 8'h91);
    if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h00)
      fail("INITIALIZE DEVICE PARAMETERS with the PC-98 geometry");
    write_byte(16'h0644, 8'd16);
    write_byte(16'h064E, 8'h91);
    // A real drive adopts what the host asks for, and the PC-98 BIOS relies on
    // that to narrow the power-on 16-head/63-sector geometry; QEMU's
    // cmd_init_drive_params and NP2kai's ideio.c both adopt. The previous
    // behaviour aborted instead, which made our own free IDE ROM fall back to a
    // 4-head geometry and compute wrong LBAs, so this asserts adoption now.
    if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h00)
      fail("INITIALIZE DEVICE PARAMETERS did not adopt a foreign geometry");
    // Put the platform geometry back so the checks below see the default.
    write_byte(16'h0644, 8'd17);
    write_byte(16'h064E, 8'h91);
    if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h00)
      fail("INITIALIZE DEVICE PARAMETERS did not restore the PC-98 geometry");

    // Write commands above the section above leave the task file dirty; restore
    // it before the CHS read checks below.
    write_byte(16'h0644, 8'h01);
    write_byte(16'h064C, 8'hA0);
    write_byte(16'h0646, 8'h00);
    write_byte(16'h064C, 8'hA0);
    write_byte(16'h064E, 8'h20);
    if (dut.status_reg !== 8'h41 || dut.error_reg !== 8'h04)
      fail("invalid CHS request was not rejected");

    // The single emulated drive answers at bank 0 (the fixed layout; the measured
    // live-bank 0x064E = 0x50) and the task file floats at every bank with channel
    // bit 0 set (the measured empty-bank float: the whole block reads 0x0E). The
    // unit is 0x064C bit 4, not a bank value, and a real single-drive channel
    // answers for the addressed unit: 0xFF here is bit 7 = BSY, which is exactly
    // the answer the disk BIOS probe loops on for its whole timeout, so the old
    // "absent slave floats 0xFF" expectation encoded the P0 bug as the contract; the absent
    // unit now reads the ATA-3 0x00 instead (below).
    write_byte(16'h0432, 8'h00);   // the bank the interface is on
    read_byte(16'h064E, value);
    // 0x0432 selects the IDE bank and must NOT rewrite the drive status: the
    // abort above left DRDY|ERR (0x41, DSC clear) and it stays 0x41 here. The old
    // expectation of 0x50 depended on that rewrite, which erased the
    // {ERROR,STATUS} snapshot the authentic ISR classifies from.
    if (value !== 8'h41) fail("0x0432 write clobbered the drive status");
    write_byte(16'h0432, 8'h03);   // a bank with no interface
    read_byte(16'h064E, value);
    if (value !== 8'h0E) fail("bank 0x03 did not float at the measured 0x0E");
    write_byte(16'h064C, 8'hB0);   // discarded: the task file is not connected
    write_byte(16'h0432, 8'h00);
    read_byte(16'h064E, value);
    if (value !== 8'h41) fail("a floating-bank write changed the drive state");
    // Unit selection is 0x064C bit 4, at the connected bank. Device 1 is ABSENT, and an absent
    // device 1 reads STATUS 0x00 (ATA-3 r6 s.9.5.1) - the answer
    // the Linux/98 IDE driver, which boots on the real Xe10, needs to give the unit up
    // (pc98_ide.c pc98ide_identify). The old 0x50 here registered a
    // phantom slave that aliased the master. 0x00 is neither the BSY float the disk BIOS once
    // looped on nor a ready drive.
    write_byte(16'h064C, 8'hB0);
    read_byte(16'h064E, value);
    if (value !== 8'h00) fail("an absent unit 1 did not read STATUS 0x00 (ATA-3 s.9.5.1)");
    // Re-selecting device 0 shows the master's status as it was left: the abort's 0x41.
    // A device/head write does not rewrite STATUS on the machine (docs/probes/IDE.TXT:349,
    // 'pre/final status = 51 58' after `out 0x064C,0xA0` following an abort).
    write_byte(16'h064C, 8'hA0);
    read_byte(16'h064E, value);
    if (value !== 8'h41) fail("primary master's status was rewritten by the device select");

    // An abort must honour nIEN (0x74C bit 1): a guest doing polled I/O must
    // not be interrupted by a rejected command. No existing case covered this,
    // which is why the leak survived.
    write_byte(16'h074C, 8'h02);         // nIEN set
    write_byte(16'h064E, 8'h9A);         // an unimplemented command: aborts
    if (irq) fail("abort raised IRQ with nIEN set");
    write_byte(16'h074C, 8'h00);         // restore
    read_byte(16'h064E, value);

    // Changing the mounted image capacity recomputes the cylinder count.
    capacity = 32'd272;
    while (dut.current_cylinders !== 16'd2) @(negedge clk);
    write_byte(16'h064E, 8'hEC);
    if (!irq || dut.status_reg !== 8'h58) fail("IDENTIFY after capacity change");
    read_byte(16'h064E, value);
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      if (n == 54 && word_value !== 16'd2) fail("IDENTIFY current cylinders after capacity change");
    end

    // The ROM's data phases run INSIDE its own save/restore bracket, so the bank
    // the bracket leaves behind is the bank every word of that phase is read
    // through. This reproduces the ISR sequence exactly (BANK3 file offset
    // 0x1A0C): park with 0x80, read the register back and keep that value
    // (es:0x2075), install the drive's own bank byte (es:0x2077), read ERROR and
    // STATUS, acknowledge 0x0433, restore the saved value -- and only then run
    // the data phase, which is what the handler does once its poll sees the ISR's
    // flag (BANK3@0x9917 for READ, @0x952C for IDENTIFY).
    //
    // The 0x80 write is a no-op on both references and in the machine's ROM, and
    // it has to be: under a latching model the value the bracket saves is 0x80 and
    // the restore re-writes 0x80, so the interface is disconnected for the whole
    // phase and every word reads 0x0E/0xFF instead of the sector. That is the P0
    // these two checks are the negative control for; the port-level form of the
    // same bracket is asserted by tests/pc9821/tb_pc9821_ata_blockmap.sv.
    write_byte(16'h0432, 8'h00);
    write_byte(16'h0432, 8'h80);          // the park write
    read_byte(16'h0432, value);           // es:0x2075 <- the read-back
    if (value !== 8'h00) fail("the 0x80 park write was latched");
    write_byte(16'h0432, 8'h00);          // es:0x2077, the drive's bank byte
    write_byte(16'h0644, 8'h01);
    write_byte(16'h0646, 8'h05);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h20);          // READ, the command the IPL runs
    write_byte(16'h0433, 8'h01);          // the ISR's acknowledge
    write_byte(16'h0432, value);          // the restore of es:0x2075
    wait_drq();
    read_byte(16'h064E, value);
    if (value !== 8'h58) fail("status through the bracket is not DRQ|DRDY|DSC");
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      if (word_value !== sector_word_for(32'd5, n[7:0]))
        fail("sector word read through the ROM's bracket");
    end
    if (dut.status_reg !== 8'h50) fail("the bracketed READ did not finish");

    // ... and the same for the IDENTIFY the drive probe runs first: its 256 words
    // are read from the data register after the bracket has been restored, so a
    // latching model hands the probe 256 copies of 0xFFFF (0x0640 and 0x0641
    // both float at 0xFF) in place of the drive's signature and geometry.
    // The probe's accept test is the *completion status*, not the data
    // (BANK3@0x8A4B classifies from the [es:0x200C] pair), so a floating data phase
    // does not make the probe declare the drive absent -- it makes the geometry it
    // derives from words 1/3/6 (BANK3@0x8A6B) nonsense and leaves the failure to
    // the READ below.
    write_byte(16'h0432, 8'h80);          // park
    read_byte(16'h0432, value);           // the saved value (0x00)
    write_byte(16'h0432, 8'h00);
    write_byte(16'h064E, 8'hEC);          // IDENTIFY
    write_byte(16'h0433, 8'h01);          // acknowledge
    write_byte(16'h0432, value);          // restore
    if (!irq || dut.status_reg !== 8'h58)
      fail("IDENTIFY through the bracket did not raise DRQ/IRQ");
    read_byte(16'h064E, value);           // acknowledge without clearing DRQ
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      if (n == 0 && word_value !== 16'h044A)
        fail("IDENTIFY word 0 read through the ROM's bracket");
    end
    if (dut.status_reg !== 8'h50) fail("the bracketed IDENTIFY did not finish");
  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ATA: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_ATA: TIMEOUT");
  end

endmodule
