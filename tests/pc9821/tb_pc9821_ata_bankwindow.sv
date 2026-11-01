// tb_pc9821_ata_bankwindow - the 0x0432 bank window covers the task file's SIDE
// EFFECTS and the data port, not only the values they answer with.
//
// The machine's window is measured in the write direction (the machine's probe results,
// "ATA and the task file": on the probed Xe10, whose disk is a CF card in the CD connector,
// 0x0432 = 0x00 floats the whole block and 0x0432 = 0x01 answers; the core's layout is fixed
// with the hard disk on bank 0, so here 0x00 answers and 0x01 floats) and asserted for the read values and the task-file writes by
// tb_pc9821_ata_blockmap. This bench covers what was left running at ANY bank:
//
//   A. a status poll (0x064E) at a floating bank must not swallow a pending interrupt.
//      NP2kai drops the whole access when getidedrv() is NULL and never calls
//      pic_resetirq in that arm (cbus/ideio.c:1421-1442), so only the bank the
//      interface answers at is an acknowledge.
//   B. an ERROR read (0x0642) at a floating bank must not clear the drive's ERR
//      snapshot (NP2kai ideio_i642 clears IDESTAT_ERR only inside its drv != NULL
//      arm, cbus/ideio.c:1324-1338).
//   C. a 16-bit data write (0x0640/0x0641) at a floating bank must not enter the
//      sector buffer and must not move the word pointer, in either direction: a
//      stray write spliced two bytes of another value into the sector the adapter is
//      about to write to the image, and a stray read during a read phase advances the
//      byte serializer by a word (NP2kai ideio_w16 requires both drv and IDEDIR_OUT,
//      cbus/ideio.c:1503-1515).
//
// The reachability warrant is the machine's own ROM: its ISR re-selects the bank
// around its 0x0642/0x064E reads (BANK3 file offset 0x1A17-0x1A24) and the data phase
// runs inside that bracket, so an access at the wrong bank is a live case, not a
// theoretical one.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_BANKWINDOW:
// The 0x0432 bank window covers the ATA task file's SIDE EFFECTS and its data port, not just the bytes they answer with: a 0x064E status poll at a floating bank leaves a pending interrupt set (only the interface bank acknowledges, NP2kai ideio_i64e's getidedrv() NULL arm), a 0x0642 ERROR read at a floating bank does not clear the drive's latched STATUS.ERR (NP2kai ideio_i642), and a 16-bit data-port write at a floating bank neither enters the sector buffer nor moves the word pointer in either direction (NP2kai ideio_w16) - the sector then round-trips through the modelled block adapter byte-exact, so no stray word consumed a slot.

module tb_pc9821_ata_bankwindow;

  localparam [31:0] LBA_W = 32'h0090;
  localparam [31:0] LBA_R = 32'h00A0;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd100000;
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

  integer errors = 0;
  integer n, w;
  reg [7:0] value;
  reg [15:0] word_value;

  task fail(input [8*152-1:0] message);
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

  // Sector byte N is LBA[7:0] XOR N[7:0]; word i is {LBA ^ (2i+1), LBA ^ (2i)}. The same
  // synthetic map tb_pc9821_ata and tb_pc9821_ata_readahead use, so a word that entered
  // the buffer from anywhere else is visible as a mismatch.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  // ==== the block adapter ====
  // One request / one completion pulse; a short fetch latency so the transfer is not the
  // bench's bottleneck, and a write drain that checks the sector against the same map.
  reg        ad_active = 0;
  reg [31:0] ad_lba = 0;
  integer    ad_wait = 0;
  integer    ad_index = 0;
  integer    ad_writes = 0;
  integer    write_errors = 0;
  reg        drain_active = 0;

  always @(negedge clk) begin
    block_done   = 0;
    block_buf_we = 0;
    if (!ad_active) begin
      if (block_read) begin
        ad_active = 1;
        ad_lba    = block_lba;
        ad_wait   = 4;
        ad_index  = 0;
      end
    end else if (ad_wait != 0) begin
      ad_wait = ad_wait - 1;
    end else begin
      block_buf_we   = 1;
      block_buf_addr = ad_index[7:0];
      block_buf_data = sector_word_for(ad_lba, ad_index[7:0]);
      if (ad_index == 255) begin
        ad_active  = 0;
        block_done = 1;
      end else ad_index = ad_index + 1;
    end

    if (!drain_active && block_write) begin
      drain_active  = 1;
      block_rd_addr = 8'd0;
      ad_writes     = ad_writes + 1;
    end else if (drain_active) begin
      if (block_rd_data !== sector_word_for(block_lba, block_rd_addr))
        write_errors = write_errors + 1;
      if (block_rd_addr == 8'd255) begin
        drain_active = 0;
        block_done   = 1;
      end else block_rd_addr = block_rd_addr + 8'd1;
    end
  end

  task wait_drq;
    begin
      n = 0;
      while (!dut.status_reg[3] && n < 20000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!dut.status_reg[3]) fail("ATA DRQ timeout");
    end
  endtask

  // The interface bank, byte for byte as tb_pc9821_ata_blockmap pins it (bank 0, the hard
  // disk's; the machine reads 0x064E = 0x50 at its live bank, the machine's probe results).
  task select_interface_bank;
    begin
      write_byte(16'h0432, 8'h00);
    end
  endtask

  // A bank with no interface behind it: the machine floats the whole task file at
  // 0x0E there (probes/JOY.TXT, probes/WIN.TXT, probes/R10.TXT, at the machine's empty bank);
  // here bank 1, empty without the CD.
  task select_floating_bank;
    begin
      write_byte(16'h0432, 8'h01);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (dut.current_cylinders !== 16'd735) @(negedge clk);
    select_interface_bank;
    read_byte(16'h064E, value);           // clear any pending interrupt

    // ---- A. a poll at a floating bank must not swallow a pending interrupt ----
    write_byte(16'h064E, 8'h40);          // READ VERIFY: completes at once and raises
    if (!irq) fail("A: READ VERIFY did not raise the interrupt");
    select_floating_bank;
    read_byte(16'h064E, value);
    if (value !== 8'h0E) fail("A: the floating bank does not answer the measured 0x0E float");
    if (!irq) fail("A: a 0x064E poll at a floating bank swallowed the pending interrupt");
    select_interface_bank;
    read_byte(16'h064E, value);
    if (value !== 8'h50) fail("A: the interface bank did not answer READY|DSC");
    if (irq) fail("A: the 0x064E read at the interface bank did not acknowledge");

    // ---- B. an ERROR read at a floating bank must not clear STATUS.ERR ----
    // An unimplemented command is the cheapest latch of the drive's ERR snapshot.
    write_byte(16'h064E, 8'h9A);
    if (dut.error_reg !== 8'h04 || dut.status_reg[0] !== 1'b1)
      fail("B: the rejected command did not latch ABRT with STATUS.ERR");
    select_floating_bank;
    read_byte(16'h0642, value);
    if (value !== 8'h0E) fail("B: the floating bank does not answer the 0x0E float at 0x0642");
    if (dut.error_reg !== 8'h04 || dut.status_reg[0] !== 1'b1)
      fail("B: a 0x0642 read at a floating bank cleared the drive's ERR snapshot");
    select_interface_bank;
    read_byte(16'h0642, value);
    if (value !== 8'h04) fail("B: the interface bank does not answer the latched ABRT");
    // And at the interface bank the read does not clear it either: the machine keeps ERR
    // across an ERROR read (docs/probes/IDE.TXT:343,349), where NP2kai ideio_i642 clears it.
    if (dut.status_reg[0] !== 1'b1)
      fail("B: the 0x0642 read at the interface bank cleared STATUS.ERR (machine keeps it)");

    // ---- C. a 16-bit write at a floating bank must not enter the sector buffer ----
    write_byte(16'h0644, 8'd1);
    write_byte(16'h0646, LBA_W[7:0]);
    write_byte(16'h0648, LBA_W[15:8]);
    write_byte(16'h064A, LBA_W[23:16]);
    write_byte(16'h064C, 8'hE0);          // LBA mode, drive 0
    write_byte(16'h064E, 8'h30);          // WRITE SECTORS
    // X_PIO_WRITE is xfer_state 3'd4 (pc9821_ata's localparam list).
    if (!dut.status_reg[3] || dut.xfer_state !== 3'd4)
      fail("C: WRITE SECTORS did not arm the data phase");
    select_floating_bank;
    write_byte(16'h0640, 8'hAB);          // the stray word's low byte
    write_byte(16'h0641, 8'hCD);          // ...and its high byte
    if (dut.pio_byte !== 9'd0)
      fail("C: a 16-bit write at a floating bank moved the word pointer");
    select_interface_bank;
    for (w = 0; w < 256; w = w + 1)
      write_word(sector_word_for(LBA_W, w[7:0]));
    n = 0;
    while (ad_writes == 0 && n < 20000) begin
      @(posedge clk);
      n = n + 1;
    end
    if (ad_writes != 1) fail("C: WRITE SECTORS never committed its sector");
    while (dut.xfer_state !== 3'd0 && n < 40000) begin
      @(posedge clk);
      n = n + 1;
    end
    if (dut.xfer_state !== 3'd0) fail("C: WRITE SECTORS did not complete");
    if (write_errors != 0)
      fail("C: the drained sector is not the guest's - a stray word entered the buffer");

    // ---- C2. a stray 16-bit READ at a floating bank must not step the pointer ----
    select_interface_bank;
    read_byte(16'h064E, value);           // acknowledge the write transfer's interrupt
    write_byte(16'h0644, 8'd1);
    write_byte(16'h0646, LBA_R[7:0]);
    write_byte(16'h0648, LBA_R[15:8]);
    write_byte(16'h064A, LBA_R[23:16]);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h20);          // READ SECTORS
    wait_drq;
    select_floating_bank;
    read_byte(16'h0640, value);           // the stray 16-bit in's first lane...
    read_byte(16'h0641, value);           // ...and its second
    if (dut.pio_byte !== 9'd0)
      fail("C2: a 16-bit read at a floating bank stepped the word pointer");
    select_interface_bank;
    wait_drq;
    for (w = 0; w < 256; w = w + 1) begin
      read_word(word_value);
      if (word_value !== sector_word_for(LBA_R, w[7:0]))
        fail("C2: the sector is misaligned after the stray read");
    end
    read_byte(16'h064E, value);           // the transfer's own ack
    if (dut.status_reg !== 8'h50) fail("C2: READ SECTORS did not complete READY|DSC");
    if (irq) fail("C2: the final ack left the interrupt pending");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_BANKWINDOW: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_BANKWINDOW: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_ATA_BANKWINDOW: TIMEOUT");
  end

endmodule
