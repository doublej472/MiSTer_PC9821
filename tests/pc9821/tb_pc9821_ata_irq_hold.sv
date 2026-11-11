// tb_pc9821_ata_irq_hold - the IRQ level is held until the guest's 0x064E ack;
// no data-phase or command-issue path may lower it.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The IRQ line is level-until-ack exactly as NP2kai's ideio.c holds it: setintr raises and only ideio_i64e's pic_resetirq on a 0x064E status read lowers, so a deferred ISR's 0x0433 source-identification read must still see bank 0's pending bit (0x01, the Xe10's 0x0433, docs/probes/KIT1-XE10-IDE1.TXT IRQ433 row) after a sector's last word parks the FSM in the read-ahead wait arm - dropping the level there loses the interrupt source and deadlocks READ MULTIPLE at the next block boundary. Pinned for the READ MULTIPLE (M=2) wait arm, the WRITE SECTORS per-sector commit, and command issue (NP2kai's command dispatch never lowers it): the level must never fall between a raise and its 0x064E ack.
//
// NP2kai is level-until-ack: setintr raises the line (ideio.c:216-221) and the ONLY
// lowering is ideio_i64e's pic_resetirq on a 0x064E status read (ideio.c:1421-1432).
// The disk ISR's first step is source identification at 0x0433 ("Bits 0 and 1 of port
// 0433h identify primary and secondary channel IRQs", roms/pc98bios/ide.S:18,292), so
// a level dropped anywhere between the raise and the ack makes a deferred ISR find no
// live source and never ack - and for READ MULTIPLE (M > 1) the
// next raise is the next block boundary the guest can never reach: a deadlock of the
// transfer. This bench defers the ISR past the block's sector words (the exact window
// the read-ahead wait arm used to drop the line in) and asserts (a) the irq LINE never
// falls before the 0x064E read and (b) the 0x0433 source-identification read answers
// bank 0's pending bit (0x01) the whole time and 0x00 once the ack lands - the machine's
// 0x0433 IS the interrupt sample (docs/probes/KIT1-XE10-IDE1.TXT:18, the IRQ433 row
// `00 10 01 12 01 50 50 00`: 00 before the command, 01 twice while it pends, 00 after the
// status read) - then that the ack, and only the ack, lowers it. The write path's per-sector commit
  // The machine settled the old NP2kai-vs-qemu question: the 2-state probe (0x0433 idle with
  // a drive present, and during an IRQ) is the IRQ433 row of KIT1-XE10-IDE1.TXT, and it reads
  // the IRQ-bit form (qemu-pc98 pc98_ide_aux_read, irq_levels & 0x03), not NP2kai's
  // ideio_i433 connect flag (0x02).
// and the command-issue path have the same shape and are pinned the same way: NP2kai's
// command dispatch never calls pic_resetirq either, so issuing a command must not
// retract a level the guest has not acked.
//
// The fetch is deliberately slower than the PIO drain (a modelled HPS round trip), so
// the guest ALWAYS finishes a sector's words with the next fetch still in flight -
// the wait arm this defect lives in.

module tb_pc9821_ata_irq_hold;

  localparam [31:0] LBA_BASE = 32'h0070;
  localparam [31:0] LBA_W    = 32'h0090;
  // The HPS fetch the level must survive: slower than one sector's whole drain
  // (256 words at 2 cycles each here), so every sector's last word lands in the
  // read-ahead wait arm.
  localparam HPS_LAT = 3000;

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

  task read_pio_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      data = {hi, lo};
    end
  endtask

  task write_pio_word(input [15:0] data);
    begin
      write_byte(16'h0640, data[7:0]);
      write_byte(16'h0641, data[15:8]);
    end
  endtask

  // Sector byte N is LBA[7:0] XOR N[7:0]; word i is {LBA ^ (2i+1), LBA ^ (2i)}.
  // The same synthetic map tb_pc9821_ata and tb_pc9821_ata_readahead use.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  // ==== the block adapter, HPS-shaped ====
  // One request / one completion pulse, a HPS_LAT-cycle fetch, then 256 words streamed
  // one per cycle (the shape tb_pc9821_ata_readahead models). The write direction
  // drains the sector buffer back through block_rd_data and checks the same map.
  reg        ad_active = 0;
  reg [31:0] ad_lba = 0;
  integer    ad_wait = 0;
  integer    ad_index = 0;
  integer    ad_reqs = 0;
  reg        drain_active = 0;
  integer    ad_writes = 0;
  integer    write_errors = 0;

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

  // THE LEVEL WATCH: from a raise until the guest's 0x064E ack the line must never
  // fall. Any drop in that window is the F2 defect, whenever it lands.
  reg ack_watch = 0;
  reg irq_prev = 0;
  reg fell_before_ack = 0;
  always @(posedge clk) begin
    irq_prev <= irq;
    if (ack_watch && irq_prev && !irq) fell_before_ack = 1;
  end

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

  task wait_complete;
    begin
      n = 0;
      while (dut.status_reg[7] && n < 200000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (dut.status_reg[7]) fail("ATA BSY timeout");
    end
  endtask

  // One presented sector, drained with NO 0x064E/0x0433 access (the deferred-ISR
  // window): this is where the old read-ahead wait arm dropped the level.
  task drain_sector(input [31:0] lba);
    begin
      for (w = 0; w < 256; w = w + 1) begin
        read_pio_word(word_value);
        if (word_value !== sector_word_for(lba, w[7:0]))
          fail("READ MULTIPLE sector data");
      end
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (dut.current_cylinders !== 16'd735) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // The negative control: with the drive present and nothing pending 0x0433 reads 00
    // (KIT1-XE10-IDE1.TXT:18 pre433 = 00), so the 01 below is the interrupt, not the drive.
    read_byte(16'h0433, value);
    if (value !== 8'h00)
        fail("negative control: 0x0433 must read 0x00 with nothing pending");

    // ---------------------------------------------------------------
    // A. READ MULTIPLE, M=2, four sectors (two blocks): the ISR is deferred past
    //    TWO sectors' last words while the next fetch is always still in flight.
    //    The block's first raise must be a live level the whole time.
    // ---------------------------------------------------------------
    write_byte(16'h0644, 8'd2);         // SET MULTIPLE MODE: block of 2
    write_byte(16'h064E, 8'hC6);
    read_byte(16'h064E, value);         // ack the 0xC6 completion: start from level 0
    if (irq) fail("A setup: the 0x064E ack did not lower the SET MULTIPLE interrupt");

    write_byte(16'h0644, 8'd4);         // four sectors = two blocks
    write_byte(16'h0646, LBA_BASE[7:0]);
    write_byte(16'h0648, LBA_BASE[15:8]);
    write_byte(16'h064A, LBA_BASE[23:16]);
    write_byte(16'h064C, 8'hE0);        // LBA mode, drive 0
    write_byte(16'h064E, 8'hC4);        // READ MULTIPLE

    // Sector 0: the block boundary raises the level (NP2kai readsec, mulcnt == 0).
    wait_drq;
    if (!irq) fail("A: the block's first sector raised no interrupt");
    ack_watch = 1;                      // the ISR is deferred from here...

    // ...past sector 0's last word, which parks the FSM in the read-ahead wait
    // arm (the next fetch is still in flight). THE DEFECT WINDOW.
    drain_sector(LBA_BASE);
    if (!irq) fail("A: irq fell at a sector's last word before any 0x064E ack");
    read_byte(16'h0433, value);
    if (value !== 8'h01)
      fail("A: 0x0433 lost the pending bit in the deferral window");

    // Sector 1 is mid-block: no NEW raise, and the pending level must survive it
    // and its own wait arm untouched.
    wait_drq;
    if (!irq) fail("A: the pending level did not survive into the mid-block sector");
    drain_sector(LBA_BASE + 32'd1);
    if (!irq) fail("A: irq fell at the mid-block sector's last word before any 0x064E ack");
    read_byte(16'h0433, value);
    if (value !== 8'h01) fail("A: 0x0433 lost the pending bit across the mid-block sector");

    // The deferred ISR finally services: the 0x064E status read is the ack, and
    // per NP2kai it is the ONLY thing that lowers the line.
    read_byte(16'h064E, value);
    ack_watch = 0;
    if (irq) fail("A: the 0x064E status read did not acknowledge the interrupt");
    read_byte(16'h0433, value);
    if (value !== 8'h00) fail("A: 0x0433 still reads the pending bit after the ack");

    // The stream continues to the second block's boundary - the raise a deadlocked
    // guest can never reach - and the cadence stays one raise per block.
    wait_drq;
    if (!irq) fail("A: the second block boundary raised no interrupt");
    read_byte(16'h064E, value);         // ack it
    if (irq) fail("A: the 0x064E ack did not lower the second block's interrupt");
    drain_sector(LBA_BASE + 32'd2);

    wait_drq;
    if (irq) fail("A: a mid-block sector raised an interrupt (READ MULTIPLE is one per block)");
    drain_sector(LBA_BASE + 32'd3);
    if (fell_before_ack) fail("A: irq fell between a raise and its 0x064E ack");
    if (dut.status_reg !== 8'h50 || dut.xfer_state !== 3'd0)
      fail("A: READ MULTIPLE did not complete READY in X_IDLE");
    if (ad_reqs != 4) fail("A: expected one fetch per sector");

    // ---------------------------------------------------------------
    // B. The write path's per-sector commit. An interrupt-driven WRITE SECTORS
    //    stream raises per committed sector; a deferred ISR must still see the
    //    level after the NEXT sector's last word lands.
    // ---------------------------------------------------------------
    fell_before_ack = 0;
    write_byte(16'h0644, 8'd2);         // two sectors, plain WRITE SECTORS
    write_byte(16'h0646, LBA_W[7:0]);
    write_byte(16'h0648, LBA_W[15:8]);
    write_byte(16'h064A, LBA_W[23:16]);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h30);
    if (irq) fail("B: WRITE SECTORS raised an interrupt at command issue");
    for (w = 0; w < 256; w = w + 1)
      write_pio_word(sector_word_for(LBA_W, w[7:0]));
    wait_drq;                           // sector 0 committed: the raise lands here
    if (!irq) fail("B: a committed sector raised no interrupt");
    ack_watch = 1;                      // the ISR is deferred again
    for (w = 0; w < 256; w = w + 1)
      write_pio_word(sector_word_for(LBA_W + 32'd1, w[7:0]));
    // The second sector's commit must not retract the unacked level.
    if (!irq) fail("B: irq fell at the write commit before any 0x064E ack");
    read_byte(16'h0433, value);
    if (value !== 8'h01) fail("B: 0x0433 lost the pending bit after the write commit");
    read_byte(16'h064E, value);         // the deferred ISR's ack
    ack_watch = 0;
    if (irq) fail("B: the 0x064E status read did not acknowledge the write interrupt");
    wait_complete;
    if (dut.status_reg !== 8'h50) fail("B: WRITE SECTORS did not complete READY|DSC");
    if (ad_writes != 2) fail("B: the adapter did not drain both write sectors");
    if (write_errors != 0) fail("B: write drain pattern mismatch");
    read_byte(16'h064E, value);         // ack the final sector's raise
    if (irq) fail("B: the 0x064E ack did not lower the final write interrupt");

    // ---------------------------------------------------------------
    // C. Command issue. NP2kai's ideio_o64e never calls pic_resetirq: a pending
    //    unacked level survives the next command write (the ack at ideio_i64e is
    //    the only lowering), so a deferred ISR still finds its interrupt after the
    //    stream moved on.
    // ---------------------------------------------------------------
    write_byte(16'h064E, 8'h40);        // READ VERIFY: an immediate completion + raise
    if (!irq) fail("C: READ VERIFY raised no interrupt");
    write_byte(16'h0644, 8'd1);
    write_byte(16'h0646, 8'h70);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h20);        // READ SECTORS, issued with the level pending
    if (!irq) fail("C: the command write retracted an unacked interrupt level");
    read_byte(16'h0433, value);
    if (value !== 8'h01) fail("C: 0x0433 lost the pending bit across a command issue");
    read_byte(16'h064E, value);         // ack
    if (irq) fail("C: the 0x064E status read did not acknowledge");
    wait_drq;
    drain_sector(32'h70);
    read_byte(16'h064E, value);         // ack the transfer's own raise
    if (dut.status_reg !== 8'h50) fail("C: the trailing READ SECTORS did not complete");
    if (irq) fail("C: the trailing ack left the level pending");

    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ATA_IRQ_HOLD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_IRQ_HOLD: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_ATA_IRQ_HOLD: TIMEOUT");
  end

endmodule
