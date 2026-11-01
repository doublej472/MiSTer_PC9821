// tb_pc9821_ata_readahead — sector read-ahead: throughput with an overlapped HPS fetch.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_READAHEAD:
// Sector read-ahead across a modelled HPS round trip: with a block adapter that takes a realistic fetch latency before its 256-word stream, a multi-sector READ SECTORS overlaps sector N+1's fetch with sector N's PIO drain, so the per-sector cost is the longer of the two terms rather than their sum -- 4856 cycles (5.3 MB/s) with the measured 4600-cycle fetch against the current class table's 1536-cycle drain, where the serialized FSM paid 6392 (4.0 MB/s) -- while raising exactly one IRQ per sector and presenting each sector's data with DRQ.


module tb_pc9821_ata_readahead;

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

  // The word rate is the CURRENT class table's, not the superseded 30: pc9821_iobus charges
  // 0x0640/0x0641 IO_MIN_HOLD = 4, and a 16-bit data word is ONE access that
  // walks two lanes, so it is 6 clk_sys (tb_pc9821_ata_iowait measures 6 delivered / 5
  // stalled through the real bus). The bench drives io_rd directly, so it inserts that
  // cost itself: each of the two byte reads is 2 cycles (read_byte) and PIO_GAP completes
  // the word. 28 here was the superseded class 30 and made every figure 5x pessimistic.
  localparam PIO_GAP     = 2;
  localparam DRAIN_SECTOR = 256 * (4 + PIO_GAP);   // 1,536 cycles = 30.7 us = 16.7 MB/s
  // The HPS fetch the read-ahead must hide: sd_rd -> sd_ack -> req_done, up to
  // ~4,600 cycles/sector, then the 256-word stream.
  localparam HPS_LAT   = 4600;
  localparam HPS_FETCH = HPS_LAT + 256;            // 4,856 cycles
  localparam SECTORS   = 16;
  localparam LBA_BASE  = 32'h1000;
  // The two regimes at the current class: the drain is 1,536 and the fetch 4,856, so the
  // FETCH is the binding term and the overlap window (one sector's drain) can no longer
  // hide it. Serialized (the old FSM) the sector costs DRAIN + FETCH = 6,392; overlapped it
  // costs FETCH. The bound sits between the two, so a lost overlap fails.
  localparam SERIAL_BOUND = SECTORS * (HPS_FETCH + 512);

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
  integer n, s, w;
  reg [7:0] value;
  reg [15:0] word_value;
  reg [7:0] status;
  integer irq_count = 0;
  reg irq_prev = 0;
  integer cycles = 0;
  integer t_start = 0, t_end = 0;
  always @(posedge clk) cycles = cycles + 1;

  task fail(input [8*128-1:0] message);
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

  // One PIO word: low byte at 0x640, high byte at 0x641, then the I/O class's
  // remaining wait, so a sector costs the current class table's 1,536 cycles.
  task read_pio_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      data = {hi, lo};
      repeat (PIO_GAP) @(posedge clk);
    end
  endtask

  task wait_drq;
    begin
      n = 0;
      while (!dut.status_reg[3] && n < 200000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!dut.status_reg[3]) fail("ATA DRQ timeout");
    end
  endtask

  // Sector byte N is LBA[7:0] XOR N[7:0]; word i is {LBA ^ (2i+1), LBA ^ (2i)}.
  // The same synthetic map tb_pc9821_ata uses, so a wrong read-ahead LBA (or a
  // stale buffer) is a data mismatch, not a silent pass.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  // ==== STIMULUS ====
  // The block adapter, with an HPS-shaped latency: it latches a request only
  // while idle (pc9821_block_io's B_IDLE), waits HPS_LAT cycles as the ARM does
  // the SD read, then streams the 256 words one per cycle and pulses completion.
  reg        ad_active = 0;
  reg [31:0] ad_lba = 0;
  integer    ad_wait = 0;
  integer    ad_index = 0;
  integer    ad_reqs = 0;
  integer    overlap_cycles = 0;

  always @(negedge clk) begin
    block_done   = 0;
    block_buf_we = 0;
    if (!ad_active) begin
      if (block_read) begin
        ad_active = 1;
        ad_lba    = block_lba;
        ad_wait   = HPS_LAT;
        ad_index  = 0;
        ad_reqs   = ad_reqs + 1;
      end
    end else if (ad_wait != 0) begin
      ad_wait = ad_wait - 1;
    end else begin
      block_buf_we   = 1;
      block_buf_addr = ad_index[7:0];
      block_buf_data = sector_word_for(ad_lba, ad_index[7:0]);
      if (ad_index == 255) begin
        ad_active = 0;
        block_done = 1;
      end else ad_index = ad_index + 1;
    end
  end

  // Count the cycles a fetch is IN FLIGHT while the guest has a sector to drain: this is the
  // overlap the read-ahead exists to create. At the current class the fetch (4,856) is longer
  // than the drain (1,536), so the guest finishes the sector before the stream starts -- the
  // overlapped term is the fetch's LATENCY, and the counter must accept a still-waiting
  // adapter (ad_wait != 0) as overlapping, or it would read zero in exactly the regime the
  // read-ahead now has to work in.
  always @(posedge clk)
    if (ad_active && dut.status_reg[3]) overlap_cycles = overlap_cycles + 1;

  always @(posedge clk) begin
    irq_prev <= irq;
    if (irq && !irq_prev) irq_count = irq_count + 1;
  end

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // Wait for the capacity-derived cylinder count, then select the interface's bank.
    while (dut.current_cylinders !== 16'd735) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // A SECTORS-sector LBA28 READ SECTORS, exactly the task-file order the ROM
    // uses: count, LBA, drive/head, then the command.
    write_byte(16'h0644, SECTORS[7:0]);
    write_byte(16'h0646, LBA_BASE[7:0]);
    write_byte(16'h0648, LBA_BASE[15:8]);
    write_byte(16'h064A, LBA_BASE[23:16]);
    write_byte(16'h064C, 8'hE0);
    t_start = cycles;
    write_byte(16'h064E, 8'h20);

    if (dut.status_reg !== 8'h80) fail("READ did not enter BSY");

    for (s = 0; s < SECTORS; s = s + 1) begin
      wait_drq();
      // The sector's IRQ is pending. A status read acknowledges it, exactly as
      // the ROM's ISR does (pc9821_ata clears the IRQ on a 0x064E read). With
      // read-ahead the IRQ must still be one per sector, not one per fetch.
      read_byte(16'h064E, status);
      if (!status[3]) fail("status read at the sector boundary dropped DRQ");
      for (w = 0; w < 256; w = w + 1) begin
        read_pio_word(word_value);
        if (word_value !== sector_word_for(LBA_BASE + s, w[7:0]))
          fail("sector data mismatch under read-ahead");
      end
    end
    t_end = cycles;

    if (dut.status_reg !== 8'h50) fail("multi-sector READ did not finish READY|DSC");
    if (dut.xfer_state !== 3'd0) fail("multi-sector READ did not return to X_IDLE");
    if (ad_reqs != SECTORS)
      fail("one block request per sector expected (a lost or extra fetch)");
    if (irq_count != SECTORS)
      fail("exactly one IRQ per sector expected (per fetch is the defect)");
    // One sector's drain is 1,536 cycles and the fetch is issued when the sector is
    // presented, so a working read-ahead overlaps most of that window. Zero (or a few
    // cycles) means the request goes out after the drain instead of during it.
    if (overlap_cycles < 1024)
      fail("the HPS fetch barely overlapped the PIO drain (the read-ahead did nothing)");

    // The measurement. Serialized, the run would be SECTORS*(DRAIN+FETCH); the
    // read-ahead leaves only the first fetch on the critical path. The MB/s figure
    // is the machine's: 512 bytes/sector at 50 MHz (20 ns/cycle).
    begin
      integer elapsed, mbps_x100;
      elapsed  = t_end - t_start;
      mbps_x100 = (SECTORS * 512 * 50 * 100) / elapsed;
      $display("READAHEAD sectors=%0d cycles=%0d per_sector=%0.1f MB/s=%0.2f",
               SECTORS, elapsed, elapsed * 1.0 / SECTORS, mbps_x100 / 100.0);
      $display("READAHEAD overlap=%0d serialized_bound=%0d HPS_FETCH=%0d",
               overlap_cycles, SERIAL_BOUND, HPS_FETCH);
      // At the current class the fetch (4,856) is the longer term, so the per-sector cost
      // must be the fetch plus a little of the FSM: 512 cycles of slack sits under the
      // serialized 6,392 and over the measured value, so a lost overlap fails.
      if (elapsed > SERIAL_BOUND)
        fail("throughput is in the serialized regime: the read-ahead did not hide the HPS fetch");
      if (mbps_x100 < 500)
        fail("throughput below 5.0 MB/s: the drain and the HPS fetch are both on the critical path");
    end

    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ATA_READAHEAD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_READAHEAD: FAIL (%0d errors)", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_ATA_READAHEAD: TIMEOUT");
  end

endmodule
