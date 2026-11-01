// tb_pc9821_ata_retire_race - the read-ahead `block_done` completion landing in
// the SAME clk_sys cycle as the guest's last-word read must be consumed exactly
// once.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The read-ahead block_done completion landing in the SAME clk the guest reads the last word of the current sector is consumed by exactly ONE handler: the last-word handler owns the collision and the prefetch-latch arm stands down, so the old source-order outcome (two consumers, the latch surviving only because its NBA lost) becomes a folded decision. The completion's error record is written once per retire: after the collision prefetch_error equals block_error even when the completion errored (pre-fix abort_command's later clear erased the record), and the clean collision swaps exactly one sector (no phantom prefetch_valid, no double buffer flip).
//
// The prefetch-latch handler and the last-word handler BOTH used to fire on
// `X_PIO_READ && prefetch_busy && block_done` in the last word's read cycle:
// two consumers of one one-shot completion, with the outcome correct only
// because the last-word handler is the later NBA (a source-order invariant,
// race-idiom R2). The latch's `prefetch_error <= block_error` record was NOT
// overridden by the last-word success path - in the ERROR collision
// abort_command's later clear erased it, so `prefetch_error` stopped equalling
// the error of the completion just retired. After the fix the last-word handler
// is the collision's single owner (the latch stands down), and the error record
// is written once per retired completion: `prefetch_error == block_error`.
//
// S1 is the FAIL-FIRST case (the error collision asserts the record);
// S2/S3 pin the swap and the plain latch against regression. The same file
// builds against the pre-fix pc9821_ata and fails at S1.
//
// SIGNAL OWNERSHIP (as in tb_pc9821_ata_srst_race): the adapter's negedge block
// only LATCHES requests; the tasks own block_done/io_* and clear ad_busy exactly
// one negedge BEFORE the completion's posedge.

module tb_pc9821_ata_retire_race;

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
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

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
  reg     ad_busy = 0;
  integer ad_reqs = 0;

  always @(negedge clk) begin
    if (!ad_busy && (block_read || block_write)) begin
      ad_busy = 1;
      ad_reqs = ad_reqs + 1;
    end
  end

  task fire_done(input with_error);
    begin
      @(negedge clk);
      block_done  = 1;
      block_error = with_error;
      ad_busy     = 0;
      @(negedge clk);
      block_done  = 0;
      block_error = 0;
    end
  endtask

  // THE COLLISION: the guest's HIGH-BYTE read of the last word (0x641 at
  // pio_byte 510) and the in-flight read-ahead's block_done pulse, both stable
  // across the same clk posedge.
  task last_word_read_with_done(input with_error, output [7:0] data);
    begin
      @(negedge clk);
      io_addr     = 16'h0641;
      io_rd       = 1;
      block_done  = 1;
      block_error = with_error;
      ad_busy     = 0;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd       = 0;
      block_done  = 0;
      block_error = 0;
    end
  endtask

  task read_sectors_lba(input [7:0] count, input [7:0] lba_low);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h0646, lba_low);
      write_byte(16'h0648, 8'h00);
      write_byte(16'h064A, 8'h00);
      write_byte(16'h064C, 8'hE0);
      write_byte(16'h064E, 8'h20);
    end
  endtask

  // Drain one presented sector: 256 word reads (0x640 lo, 0x641 hi advances).
  task drain_sector;
    integer w;
    begin
      for (w = 0; w < 256; w = w + 1) begin
        read_byte(16'h0640, value);
        read_byte(16'h0641, value);
      end
    end
  endtask

  // Drain 255 words so the NEXT 0x641 read is the sector's last word.
  task drain_to_last_word;
    integer w;
    begin
      for (w = 0; w < 255; w = w + 1) begin
        read_byte(16'h0640, value);
        read_byte(16'h0641, value);
      end
      read_byte(16'h0640, value);
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
      write_byte(16'h0432, 8'h00);
      if (dut.status_reg !== 8'h50) fail("reset_drive: not READY at scenario start");
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (dut.current_cylinders !== 16'd7) @(negedge clk);
    repeat (4) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // ---------------------------------------------------------------
    // S1 (FAIL FIRST). The read-ahead for sector 2 completes WITH ERROR in the
    // exact clk the guest consumes sector 1's last word. The last-word handler
    // owns the completion (one consumer) and retires it: the command aborts
    // with the error, and `prefetch_error` must record the retired completion's
    // error (`prefetch_error == block_error`). Pre-fix the prefetch-latch arm's
    // record NBA is erased by abort_command's later clear: 0 != 1, and the two
    // handler arms double-consumed the one pulse (the latch only lost because
    // its NBA was overridden - source order, R2).
    // ---------------------------------------------------------------
    read_sectors_lba(8'h03, 8'h10);
    fire_done(1'b0);                       // fetch #1 lands: X_PIO_READ + prefetch #2
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd3)    fail("S1 setup: first fetch did not present in X_PIO_READ");
    if (dut.prefetch_busy !== 1'b1) fail("S1 setup: no read-ahead was left in flight");
    drain_to_last_word;
    last_word_read_with_done(1'b1, value); // THE COLLISION: completion with error
    @(negedge clk);
    if (dut.prefetch_error !== 1'b1)
      fail("S1: prefetch_error did not record the retired completion's error (== block_error)");
    if (dut.prefetch_error !== 1'b1)        // == block_error, spelled out
      fail("S1: prefetch_error != block_error after the collision");
    if (dut.prefetch_valid !== 1'b0)
      fail("S1: sector swap AND prefetch_valid set - the completion was consumed twice");
    if (dut.prefetch_busy !== 1'b0)
      fail("S1: the retired completion left a phantom read-ahead in flight");
    if (dut.xfer_state !== 3'd0)
      fail("S1: an errored read-ahead must abort the command to X_IDLE");

    // ---------------------------------------------------------------
    // S2. The same collision with a CLEAN completion: exactly one of
    // {prefetch_valid set, sector swap} may occur - the swap - and the record
    // equals block_error (0). The next read must see the NEW sector (the
    // buffer flipped once, not twice).
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h03, 8'h30);
    fire_done(1'b0);
    repeat (3) @(negedge clk);
    drain_to_last_word;
    last_word_read_with_done(1'b0, value);
    @(negedge clk);
    if (dut.prefetch_valid !== 1'b0)
      fail("S2: the latch handler also fired (prefetch_valid set) - two consumers");
    if (dut.prefetch_error !== 1'b0)
      fail("S2: prefetch_error != block_error after the clean collision");
    if (dut.sectors_left !== 9'd2)
      fail("S2: the sector swap did not advance exactly once");
    if (dut.xfer_state !== 3'd3)
      fail("S2: sector 2 was not presented after the collision");
    if (dut.status_reg[3] !== 1'b1)
      fail("S2: DRQ clear after the collision's swap");

    // ---------------------------------------------------------------
    // S3. The plain read-ahead latch (no collision): the completion is recorded
    // once and the drain's last word swaps in the recorded sector.
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h02, 8'h50);
    fire_done(1'b0);                       // fetch #1 presents, prefetch #2 issued
    repeat (3) @(negedge clk);
    fire_done(1'b1);                       // prefetch #2 completes WITH ERROR mid-sector
    @(negedge clk);
    if (dut.prefetch_valid !== 1'b1)
      fail("S3: the read-ahead completion was not latched");
    if (dut.prefetch_error !== 1'b1)
      fail("S3: the latch record != block_error");
    drain_to_last_word;
    read_byte(16'h0641, value);            // the last word consumes the record: abort
    @(negedge clk);
    if (dut.xfer_state !== 3'd0)
      fail("S3: an errored latched read-ahead must abort at the boundary");

    // ==== VERDICT ====
    // A failing run must exit non-zero: $fatal rather than a bare FAIL line and a
    // $finish, which returns from the process with status 0.
    if (errors == 0) begin
      $display("TB_PC9821_ATA_RETIRE_RACE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_RETIRE_RACE: FAIL (%0d errors)", errors);
  end

endmodule
