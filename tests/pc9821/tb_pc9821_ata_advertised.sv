// tb_pc9821_ata_advertised - the mechanical "advertised => executable" cross-check.
//
// Reads the model's own IDENTIFY page and, for every capability bit it sets that
// maps to a command, drives that command through the task-file ports and requires
// it to COMPLETE (no ABRT); a capability bit that is clear owes no command. It also
// asserts that no DMA capability is advertised at all (word 49 bit 8, words 62/63/88,
// word 53 bit 2), because the model implements no 0xC8-0xCF path: a future change
// that sets one of those bits fails here until the command exists.
//
// This is the generic guard the multiple-mode defect needed: the model advertised
// ATA multiple mode (word 47 = 0x8080) while aborting SET MULTIPLE (0xC6) and READ
// MULTIPLE (0xC4), and nothing compared the two halves of the page.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_ADVERTISED:
// The mechanical advertised=>executable cross-check the multiple-mode defect needed: every capability bit the ATA model's IDENTIFY page sets is executed or is not set - LBA support (word 49 bit 9) runs an LBA-mode READ SECTORS, the PIO-mode words (word 53 bit 1 / word 64) run SET FEATURES, and word 82's NOP / DEVICE RESET / WRITE CACHE bits run 0x00 / 0x08 / 0xE7. It pins that multiple mode is NOT advertised (word 47 = 0, because the model buffers one sector and the Xe10 ROM's READ MULTIPLE does not check DRQ) and that no DMA capability is advertised anywhere (word 49 bit 8, words 62/63/88 and word 53 bit 2 clear) because no 0xC8-0xCF command exists.

module tb_pc9821_ata_advertised;

  localparam [31:0] LBA_BASE = 32'h0400;

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
  reg [15:0] idw[0:255];

  task fail(input [8*144-1:0] message);
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
    reg [7:0] l, h;
    begin
      read_byte(16'h0640, l);
      read_byte(16'h0641, h);
      data = {h, l};
    end
  endtask

  task write_word(input [15:0] data);
    begin
      write_byte(16'h0640, data[7:0]);
      write_byte(16'h0641, data[15:8]);
    end
  endtask

  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

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

  task wait_idle;
    begin
      n = 0;
      while (dut.xfer_state !== 3'd0 && n < 20000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (dut.xfer_state !== 3'd0) fail("ATA transfer did not complete");
    end
  endtask

  // Did the command just issued abort? The model's own abort counter, sampled before the
  // command under test, answers that unambiguously. ERROR is NOT usable as this proxy any
  // more: DEVICE RESET (0x08) legitimately leaves ABRT (0x04) as its post-diagnostic
  // signature on the machine -- status 0x51, ERROR 0x04 (docs/probes/IDE.TXT:343) -- which
  // is a completion, not a rejection.
  reg [7:0] aborts_before;

  task note_aborts;
    begin
      aborts_before = dbg_cmd[31:24];
    end
  endtask

  function aborted;
    aborted = dbg_cmd[31:24] != aborts_before;
  endfunction

  // ==== block adapter ====
  // Reads fill a sector, writes drain one; a short latency so the transfer is not
  // the bench's bottleneck.
  reg        ad_active = 0;
  reg [31:0] ad_lba = 0;
  integer    ad_wait = 0;
  integer    ad_index = 0;
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
    end else if (drain_active) begin
      if (block_rd_addr == 8'd255) begin
        drain_active = 0;
        block_done   = 1;
      end else block_rd_addr = block_rd_addr + 8'd1;
    end
  end

  // Put the task file in the state every read/write command needs: LBA mode,
  // count 1, and the LBA. A drive/head register write with bit 6 set selects LBA.
  task arm_lba_read(input [31:0] lba);
    begin
      write_byte(16'h0644, 8'd1);
      write_byte(16'h0646, lba[7:0]);
      write_byte(16'h0648, lba[15:8]);
      write_byte(16'h064A, lba[23:16]);
      write_byte(16'h064C, 8'hE0);
    end
  endtask

  // Consume one sector's DRQ and acknowledge the interrupt it raised.
  task drain_read_sector(input [31:0] lba);
    begin
      wait_drq;
      for (w = 0; w < 256; w = w + 1) begin
        read_word(word_value);
        if (word_value !== sector_word_for(lba, w[7:0]))
          fail("advertised read data mismatch");
      end
      read_byte(16'h064E, value);
    end
  endtask

  task feed_write_sector(input [31:0] lba);
    begin
      wait_drq;
      for (w = 0; w < 256; w = w + 1)
        write_word(sector_word_for(lba, w[7:0]));
      read_byte(16'h064E, value);
    end
  endtask

  // Clear ERROR with a command both references complete without error, so the
  // next command's ABRT bit is its own.
  task clear_error;
    begin
      write_byte(16'h064E, 8'hE1);   // IDLE IMMEDIATE: error = 0
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (200) @(posedge clk);      // let the capacity-derived cylinder count settle
    write_byte(16'h0432, 8'h00);      // the bank the built-in interface is on
    read_byte(16'h064E, value);       // clear any pending interrupt

    // ---- 1. Read the model's whole IDENTIFY page ----
    write_byte(16'h064E, 8'hEC);
    if (!dut.status_reg[3]) fail("IDENTIFY did not raise DRQ");
    for (n = 0; n < 256; n = n + 1) read_word(idw[n]);
    if (dut.status_reg !== 8'h50) fail("IDENTIFY did not finish");
    $display("  ADVERTISED word 47=0x%04x 49=0x%04x 53=0x%04x 59=0x%04x 63=0x%04x 64=0x%04x 80=0x%04x 82=0x%04x",
             idw[47], idw[49], idw[53], idw[59], idw[63], idw[64], idw[80], idw[82]);

    // ---- 2. Multiple mode: word 47 bit 15 ----
    // The bit says the low byte is a valid maximum. This model withdraws it (0),
    // because it buffers one sector at a time and the Xe10 ROM's READ MULTIPLE
    // consumes a whole block after one interrupt WITHOUT checking DRQ: a streamed
    // block that outruns the HPS fetch would splice 0x00 into the file stream.
    // The commands themselves are still implemented and are exercised by
    // tb_pc9821_ata_multiple. If someone sets the bit again, this arm now REQUIRES
    // SET MULTIPLE / READ MULTIPLE / WRITE MULTIPLE to complete, so the
    // advertisement can never come back without the commands.
    if (idw[47][15]) begin
      integer m;
      m = idw[47][7:0];
      if (!(m == 2 || m == 4 || m == 8 || m == 16 || m == 32 || m == 64 || m == 128)) begin
        fail("word 47 advertises a maximum that is not a legal multiple count");
      end else begin
        clear_error;
        write_byte(16'h0644, m[7:0]);
        note_aborts;
        write_byte(16'h064E, 8'hC6);           // SET MULTIPLE
        if (aborted()) fail("word 47 advertises multiple mode but SET MULTIPLE aborted");
        $display("  ok word 47 multiple mode: SET MULTIPLE %0d completed", m);

        read_byte(16'h064E, value);
        arm_lba_read(LBA_BASE);
        note_aborts;
        write_byte(16'h064E, 8'hC4);           // READ MULTIPLE
        if (aborted()) fail("word 47 advertises multiple mode but READ MULTIPLE aborted");
        drain_read_sector(LBA_BASE);
        while (dut.status_reg[7]) @(negedge clk);
        $display("  ok word 47 multiple mode: READ MULTIPLE completed");
      end

      read_byte(16'h064E, value);
      arm_lba_read(LBA_BASE + 32'd1);
      note_aborts;
      write_byte(16'h064E, 8'hC5);             // WRITE MULTIPLE
      if (aborted()) fail("word 47 advertises multiple mode but WRITE MULTIPLE aborted");
      feed_write_sector(LBA_BASE + 32'd1);
      while (dut.status_reg[7]) @(negedge clk);
      $display("  ok word 47 multiple mode: WRITE MULTIPLE completed");
    end else begin
      // Withdrawn: word 59's valid bit must agree, or a driver reads a current
      // multiple setting that no word-47 claim backs.
      if (idw[59][8]) fail("word 59 says the multiple setting is valid but word 47 advertises no multiple mode");
      $display("  ok word 47/59 do not advertise multiple mode (the model cannot stream a block)");
    end

    // ---- 3. word 49: LBA support (bit 9) and DMA (bit 8) ----
    if (idw[49][9]) begin
      read_byte(16'h064E, value);
      arm_lba_read(LBA_BASE + 32'd2);
      note_aborts;
      write_byte(16'h064E, 8'h20);             // READ SECTORS, LBA mode
      if (aborted()) fail("word 49 advertises LBA but an LBA READ SECTORS aborted");
      drain_read_sector(LBA_BASE + 32'd2);
      while (dut.status_reg[7]) @(negedge clk);
      $display("  ok word 49 LBA: LBA-mode READ SECTORS completed");
    end else begin
      $display("  - word 49 does not advertise LBA; no LBA command owed");
    end
    if (idw[49][8]) begin
      // No 0xC8-0xCF command exists in this model, so this bit may not be set.
      // The guard fires here first, before anything tries to run a DMA command.
      fail("word 49 advertises DMA but the model implements no READ/WRITE DMA command");
    end

    // ---- 4. word 53 / 64: PIO modes ----
    // Word 53 bit 1 says words 64-70 are valid; the PIO-mode word must then be
    // populated, and the command that negotiates PIO timing must complete.
    if (idw[53][1]) begin
      if (idw[64] == 16'h0000) fail("word 53 bit 1 advertises words 64-70 valid but word 64 is zero");
      clear_error;
      note_aborts;
      write_byte(16'h064E, 8'hEF);             // SET FEATURES (transfer mode)
      if (aborted()) fail("word 53 bit 1 advertises PIO modes but SET FEATURES aborted");
      $display("  ok word 53/64 PIO modes: word 64=0x%04x, SET FEATURES completed", idw[64]);
    end else begin
      $display("  - word 53 does not advertise words 64-70; no PIO-mode command owed");
    end
    if (idw[53][2]) begin
      fail("word 53 advertises words 88-89 (Ultra DMA) but the model implements no UDMA command");
    end

    // ---- 5. word 80 is the ATA MAJOR-VERSION field, not a capability ----
    // Bits 1..14 name ATA-1..ATA-14 (Linux ATA_ID_MAJOR_VER, NP2kai "support ATA-1
    // to 5"). It maps to no command, so it is reported rather than exercised; bit 1
    // can be misread as a DMA advertisement, and this bench instead pins
    // the DMA words directly (section 6).
    $display("  - word 80=0x%04x is the ATA major-version field (bit 1 = ATA-1), not a capability", idw[80]);

    // ---- 6. The DMA capability words must be clear (PIO-only model) ----
    if (idw[62] != 16'h0000) fail("word 62 advertises singleword DMA modes but the model is PIO-only");
    if (idw[63] != 16'h0000) fail("word 63 advertises multiword DMA modes but the model is PIO-only");
    if (idw[88] != 16'h0000) fail("word 88 advertises Ultra DMA modes but the model is PIO-only");
    if (idw[49][8] != 1'b0) fail("word 49 bit 8 (DMA) is set but the model is PIO-only");
    if (idw[53][2] != 1'b0) fail("word 53 bit 2 (words 88-89 valid) is set but the model is PIO-only");
    $display("  ok no DMA capability advertised (words 49/62/63/88 and word 53 bit 2 clear)");

    // ---- 7. word 82's command-set bits ----
    if (idw[82][14]) begin
      clear_error;
      note_aborts;
      write_byte(16'h064E, 8'h00);             // NOP
      if (aborted()) fail("word 82 advertises NOP but NOP aborted");
      $display("  ok word 82 NOP: 0x00 completed");
    end
    if (idw[82][9]) begin
      clear_error;
      note_aborts;
      write_byte(16'h064E, 8'h08);             // DEVICE RESET
      if (aborted()) fail("word 82 advertises DEVICE RESET but 0x08 aborted");
      $display("  ok word 82 DEVICE RESET: 0x08 completed");
    end
    if (idw[82][5]) begin
      clear_error;
      note_aborts;
      write_byte(16'h064E, 8'hE7);             // FLUSH CACHE
      if (aborted()) fail("word 82 advertises WRITE CACHE but FLUSH CACHE aborted");
      $display("  ok word 82 WRITE CACHE: FLUSH CACHE completed");
    end

    // ---- verdict ----
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_ADVERTISED: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_ATA_ADVERTISED: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #5000000;
    $fatal(1, "TB_PC9821_ATA_ADVERTISED: FAIL (timeout)");
  end

endmodule
