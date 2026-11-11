// tb_pc9821_ata_drq_takeover - a command written while a PIO data phase is pending (DRQ set,
// BSY clear) is executed, not ignored: the pending data phase is abandoned.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_DRQ_TAKEOVER: a command written to 0x064E while a PIO data phase is pending with BSY clear (DRQ set, words left to transfer) is EXECUTED the way NP2kai's ideio_o64e dispatches every command byte (cbus/ideio.c `drv->cmd = dat;` then `switch (dat)`): RECALIBRATE in the middle of a READ SECTORS sector ends with status 0x50 and the drive takes the next IDENTIFY; a second IDENTIFY in the middle of an IDENTIFY page restarts the page at word 0 (0x044A); a READ SECTORS in the middle of a WRITE SECTORS sector abandons the half-filled sector (no block write reaches the image) and reads the new LBA; a READ SECTORS issued while the old READ's read-ahead is still at the block adapter reads BSY, sends NO request until that read-ahead completes, then fetches exactly the new LBA and presents it with status 0x58; an SRST during that wait cancels the deferred command (no request, READY after the reset); and NOP (NP2kai `case 0x00: break`, no state change) leaves the data phase standing. A command written while BSY is set is still ignored (tb_pc9821_ata_cmd_race S2).
//
// ---- where the expectation comes from ----
//   NP2kai cbus/ideio.c ideio_o64e: no BSY/DRQ test before the dispatch; `case 0x10..0x1f`
//     sets `drv->status = IDESTAT_DRDY | IDESTAT_DSC` (0x50, DRQ clear); setidentify and
//     readsec/writeinit restart the buffer (`drv->bufpos = 0`); `case 0x00:` is an empty break.
// FAIL-FIRST: before the fix every command written in X_PIO_READ / X_PIO_IDENT / X_PIO_WRITE was
// dropped by the 0x064E guard (`xfer_state != X_IDLE`), so P1 read 0x58 after the RECALIBRATE,
// P2 kept reading the old page position, P3/P4 never issued the new read.

module tb_pc9821_ata_drq_takeover;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg        io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg  [7:0] io_din = 0;
  wire [ 7:0] io_dout;
  wire        block_read, block_write;
  wire [31:0] block_lba;
  reg         block_done = 0, block_error = 0;
  reg         block_buf_we = 0;
  reg  [ 7:0] block_buf_addr = 0;
  reg  [15:0] block_buf_data = 0;
  reg  [ 7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire        irq;
  wire [ 7:0] dbg_state;
  wire [31:0] dbg_cmd;

  integer errors = 0;
  integer n;
  reg [7:0] value;

  // ==== DUT ====
  pc9821_ata dut (
      .clk(clk),
      .rst_n(rst_n),
      .io_rd(io_rd),
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout),
      .mounted(1'b1),
      .readonly(1'b0),
      .capacity(32'd1000),
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

  // ==== CHECKS ====
  task fail(input [8*160-1:0] message);
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

  // ==== the block adapter, under the bench's full control ====
  // One request at a time, as pc9821_block_io serves them: a request presented while
  // the adapter is still busy is a protocol violation (the real adapter drops it).
  reg     ad_busy = 0;
  integer ad_reqs = 0, ad_writes = 0, ad_overrun = 0;
  reg [31:0] ad_lba = 0;

  always @(negedge clk) begin
    if (block_read || block_write) begin
      if (ad_busy) ad_overrun = ad_overrun + 1;
      else begin
        ad_busy = 1;
        ad_reqs = ad_reqs + 1;
        ad_lba  = block_lba;
        if (block_write) ad_writes = ad_writes + 1;
      end
    end
  end

  task fire_done;
    begin
      @(negedge clk);
      block_done = 1;
      ad_busy    = 0;
      @(negedge clk);
      block_done = 0;
    end
  endtask

  task taskfile(input [7:0] count, input [7:0] lba_low);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h0646, lba_low);
      write_byte(16'h0648, 8'h00);
      write_byte(16'h064A, 8'h00);
      write_byte(16'h064C, 8'hE0);
    end
  endtask

  task reset_drive;
    begin
      @(negedge clk);
      rst_n = 0;
      repeat (4) @(negedge clk);
      rst_n = 1;
      repeat (4) @(negedge clk);
      ad_busy = 0;
      ad_reqs = 0;
      ad_writes = 0;
      write_byte(16'h0432, 8'h00);
      if (dut.status_reg !== 8'h50) fail("reset_drive: not READY at scenario start");
    end
  endtask

  task read_words(input integer words);
    integer w;
    begin
      for (w = 0; w < words; w = w + 1) begin
        read_byte(16'h0640, value);
        read_byte(16'h0641, value);
      end
    end
  endtask

  task write_words(input integer words);
    integer w;
    begin
      for (w = 0; w < words; w = w + 1) begin
        write_byte(16'h0640, w[7:0]);
        write_byte(16'h0641, 8'h00);
      end
    end
  endtask

  integer reqs_before;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (dut.current_cylinders !== 16'd7) @(negedge clk);
    repeat (4) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // P1: READ SECTORS (1 sector) presented, 4 words read, then RECALIBRATE.
    taskfile(8'h01, 8'h10);
    write_byte(16'h064E, 8'h20);
    repeat (3) @(negedge clk);
    fire_done;
    repeat (3) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h58) fail("P1 setup: the sector is not presented (0x58)");
    read_words(4);
    write_byte(16'h064E, 8'h10);
    repeat (2) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h50) begin $display("P1: status 0x%02x", value); fail("P1: RECALIBRATE in a DRQ phase did not end with status 0x50"); end
    write_byte(16'h064E, 8'hEC);
    repeat (2) @(negedge clk);
    read_byte(16'h0640, value);
    if (value !== 8'h4A) fail("P1: the IDENTIFY after the RECALIBRATE was not accepted");
    else $display("ok  P1 pio_read + RECALIBRATE");

    // P2: IDENTIFY page, 3 words read, IDENTIFY again -> the page restarts at word 0.
    reset_drive;
    write_byte(16'h064E, 8'hEC);
    repeat (2) @(negedge clk);
    read_words(3);
    write_byte(16'h064E, 8'hEC);
    repeat (2) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h58) fail("P2: the second IDENTIFY does not present its page (0x58)");
    read_byte(16'h0640, value);
    if (value !== 8'h4A) begin $display("P2: word lo 0x%02x", value); fail("P2: the second IDENTIFY did not restart at word 0"); end
    else $display("ok  P2 identify + IDENTIFY");

    // P3: WRITE SECTORS (2) with 10 words written, then READ SECTORS at LBA 0x50.
    reset_drive;
    taskfile(8'h02, 8'h40);
    write_byte(16'h064E, 8'h30);
    repeat (2) @(negedge clk);
    write_words(10);
    taskfile(8'h01, 8'h50);
    write_byte(16'h064E, 8'h20);
    repeat (3) @(negedge clk);
    if (ad_reqs != 1 || ad_writes != 0 || ad_lba !== 32'h50)
      begin $display("P3: reqs %0d writes %0d lba 0x%0h", ad_reqs, ad_writes, ad_lba); fail("P3: READ SECTORS in a write DRQ phase did not fetch the new LBA alone"); end
    fire_done;
    repeat (3) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h58 || dut.xfer_state !== 3'd3) fail("P3: the new read's sector is not presented");
    else $display("ok  P3 pio_write + READ SECTORS");

    // P4: READ SECTORS (3): sector 1 presented with its read-ahead still at the adapter,
    // then READ SECTORS (1) at LBA 0x60.
    reset_drive;
    taskfile(8'h03, 8'h30);
    write_byte(16'h064E, 8'h20);
    repeat (3) @(negedge clk);
    fire_done;
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd3 || !ad_busy) fail("P4 setup: expected X_PIO_READ with the read-ahead in flight");
    reqs_before = ad_reqs;
    taskfile(8'h01, 8'h60);
    write_byte(16'h064E, 8'h20);
    repeat (3) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h80) begin $display("P4: status 0x%02x", value); fail("P4: the deferred command does not read BSY"); end
    if (ad_reqs != reqs_before) fail("P4: a request went out while the read-ahead was still owed");
    fire_done;                            // the abandoned read-ahead lands
    repeat (3) @(negedge clk);
    if (ad_reqs != reqs_before + 1 || ad_lba !== 32'h60)
      begin $display("P4: reqs %0d lba 0x%0h", ad_reqs - reqs_before, ad_lba); fail("P4: the deferred READ SECTORS did not fetch LBA 0x60 after the drain"); end
    fire_done;
    repeat (3) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h58) fail("P4: the deferred read's sector is not presented");
    read_words(256);
    read_byte(16'h064E, value);
    if (value !== 8'h50) fail("P4: the one-sector read did not end READY");
    else $display("ok  P4 pio_read with read-ahead + READ SECTORS");

    // P5: as P4, but an SRST lands while the deferred command waits: it is cancelled.
    reset_drive;
    taskfile(8'h03, 8'h30);
    write_byte(16'h064E, 8'h20);
    repeat (3) @(negedge clk);
    fire_done;
    repeat (3) @(negedge clk);
    reqs_before = ad_reqs;
    taskfile(8'h01, 8'h60);
    write_byte(16'h064E, 8'h20);
    repeat (2) @(negedge clk);
    write_byte(16'h074C, 8'h04);
    write_byte(16'h074C, 8'h00);
    fire_done;
    repeat (4) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h50 || ad_reqs != reqs_before)
      begin $display("P5: status 0x%02x reqs %0d", value, ad_reqs - reqs_before); fail("P5: SRST did not cancel the deferred command"); end
    else $display("ok  P5 SRST cancels the deferred command");

    // P6: NOP in a DRQ phase leaves the data phase standing.
    reset_drive;
    write_byte(16'h064E, 8'hEC);
    repeat (2) @(negedge clk);
    write_byte(16'h064E, 8'h00);
    repeat (2) @(negedge clk);
    read_byte(16'h064E, value);
    read_byte(16'h0640, value);
    if (value !== 8'h4A) fail("P6: NOP disturbed the IDENTIFY page");
    else $display("ok  P6 NOP leaves the data phase");

    if (ad_overrun != 0) fail("a request was presented while the adapter was busy");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_DRQ_TAKEOVER: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_DRQ_TAKEOVER: FAIL (%0d errors)", errors);
  end

endmodule
