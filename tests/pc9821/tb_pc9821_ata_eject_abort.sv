// tb_pc9821_ata_eject_abort - the real drive, the real shared adapter, and a medium that
// moves under an in-flight command: the command must ALWAYS terminate, and a disk that went
// away must never answer a read with data.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_EJECT_ABORT:
// A guest READ SECTORS always terminates in one of the two outcomes ATA semantics allow - the block (DRQ rises) or an abort (STATUS.ERR, NP2kai/qemu's 0x41) - whatever cycle the slot's img_mounted pulse lands on, INCLUDING the cycles the shared adapter's hand-over owns. The real pc9821_ata, pc9821_block_share and pc9821_block_io are driven with a host model for one READ SECTORS while an eject (img_mounted with img_size < 512) is swept across every offset around the hand-over at pulse widths 1 (offsets 0..8) and 3 (offsets 0..6), plus the no-eject control: every one must end with the drive not BSY and ERR set (a visible abort), and *no* offset may leave DRQ risen - a read of the ejected slot must fail, not be served. A second sweep grows a mounted image (64 -> 1000 blocks) one cycle at a time across the same window and then reads an LBA that exists only in the grown image: it must be SERVED at every offset, which pins that the adapter's own mounted/capacity latch never keeps the pre-mount value after the pulse that delivered the new one.
//
// FAIL-FIRST, both halves, on the tree this shipped with:
//  * the eject pulse covering the share's ARB_REQ cycle left the drive BSY forever - no DRQ,
//    no IRQ, no completion ever (the request was neither served nor aborted);
//  * the eject pulse ENDING on ARB_META let the drive answer that read with DRQ and an IRQ,
//    a "successful" read of an unmounted slot;
//  * the growing mount ENDING on ARB_META left the engine on the old capacity, so the read
//    of an LBA inside the new image aborted with ERR.
//
// The sweep form is deliberate: the failing alignments are one cycle wide, so a single
// scenario cannot see them and only a sweep over the hand-over can. The harness this
// is derived from (one offset per process run) was the same experiment unswept.

`timescale 1ns / 1ps

module tb_pc9821_ata_eject_abort;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  integer fails = 0;

  // ==== DUT ====
  // ---- the drive under test and the slot's image ----
  reg        io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [ 7:0] io_din = 0;
  wire [ 7:0] io_dout;
  wire        blk_read, blk_write;
  wire [31:0] blk_lba;
  wire        blk_done, blk_error;
  wire        blk_we;
  wire [ 7:0] blk_addr;
  wire [15:0] blk_data;
  wire [ 7:0] blk_rd_addr;
  wire [15:0] blk_rd_data;
  wire        irq;
  wire [ 7:0] dbg_state;
  wire [31:0] dbg_cmd;

  reg        img_mounted = 0;
  reg [63:0] img_size = 0;
  wire       a_mounted, a_readonly;
  wire [31:0] a_capacity;
  wire        a_busy;
  wire        a_sd_rd, a_sd_wr, b_sd_rd, b_sd_wr;
  wire [31:0] a_sd_lba, b_sd_lba;
  wire [5:0]  a_blk_cnt, b_blk_cnt;
  wire [15:0] a_sd_din, b_sd_din;
  wire [31:0] dbg_hps;

  // ---- the host: the MiSTer block reader for whichever slot is requesting ----
  reg        sd_ack = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  reg [12:0] widx, wtotal;
  reg [31:0] hlba;
  reg        hbusy, hlast;
  integer    host_requests = 0;

  always @(posedge clk) begin
    if (!rst_n) begin
      sd_ack <= 0; sd_buff_wr <= 0; hbusy <= 0; hlast <= 0; widx <= 0; host_requests <= 0;
    end else if (!hbusy) begin
      sd_buff_wr <= 0;
      if (a_sd_rd || b_sd_rd) begin
        hbusy <= 1; sd_ack <= 1; widx <= 0; host_requests <= host_requests + 1;
        hlba <= a_sd_rd ? a_sd_lba : b_sd_lba;
        wtotal <= ({7'd0, (a_sd_rd ? a_blk_cnt : b_blk_cnt)} + 13'd1) * 13'd256 - 13'd1;
      end
    end else begin
      sd_buff_wr <= 1; sd_buff_addr <= widx;
      sd_buff_dout <= {hlba[7:0] ^ 8'hA5, widx[7:0]};
      if (hlast) begin hbusy <= 0; sd_ack <= 0; sd_buff_wr <= 0; hlast <= 0; end
      else if (widx == wtotal) hlast <= 1;
      else widx <= widx + 1;
    end
  end

  pc9821_ata ata (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .mounted(a_mounted), .readonly(a_readonly), .capacity(a_capacity),
      .block_read(blk_read), .block_write(blk_write), .block_lba(blk_lba),
      .block_done(blk_done), .block_error(blk_error),
      .block_buf_we(blk_we), .block_buf_addr(blk_addr), .block_buf_data(blk_data),
      .block_rd_addr(blk_rd_addr), .block_rd_data(blk_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd)
  );

  pc9821_block_share share (
      // Slot D (the second hard disk): unmounted; every disk request is for slot A.




      .clk(clk), .rst_n(rst_n),
      .a_img_mounted(img_mounted), .a_img_readonly(1'b0), .a_img_size(img_size),
      .a_mounted(a_mounted), .a_readonly(a_readonly), .a_capacity(a_capacity),
      .a_req_read(blk_read), .a_req_write(blk_write), .a_req_lba(blk_lba),
      .a_req_window(1'b1),
      .a_req_done(blk_done), .a_req_error(blk_error), .a_busy(a_busy),
      .a_buf_we(blk_we), .a_buf_addr(blk_addr), .a_buf_data(blk_data),
      .a_buf_rd_addr(blk_rd_addr), .a_buf_rd_data(blk_rd_data),
      .a_sd_lba(a_sd_lba), .a_sd_blk_cnt(a_blk_cnt), .a_sd_rd(a_sd_rd), .a_sd_wr(a_sd_wr),
      .a_sd_ack(sd_ack), .a_sd_buff_din(a_sd_din),
      // slot B: no medium, no requests
      .b_img_mounted(1'b0), .b_img_readonly(1'b0), .b_img_size(64'd0),
      .b_req_read(1'b0), .b_req_lba(16'd0), .b_req_done(), .b_req_error(), .b_busy(),
      .b_buf_we(), .b_buf_addr(), .b_buf_data(),
      .b_sd_lba(b_sd_lba), .b_sd_blk_cnt(b_blk_cnt), .b_sd_rd(b_sd_rd), .b_sd_wr(b_sd_wr),
      .b_sd_ack(1'b0), .b_sd_buff_din(b_sd_din),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps)
  );

  // ==== CHECKS ====
  // ---- what the guest would see. STATUS comes from the drive's own register through a
  //      hierarchical reference, as the tree's other ATA benches do, and NOT from a port read:
  //      after an eject the drive's port answers 8'hFF (pc9821_ata.sv:555 "end else if (!device_present"),
  //      so the verdict has to survive the very event under test. ----
  integer drq_cycles, bsy_cycles, err_cycles, irq_edges;
  reg     irq_q = 0;
  reg     en_window = 0;
  wire [7:0] status_r = ata.status_reg;
  always @(posedge clk) begin
    irq_q <= irq;
    if (irq & ~irq_q) irq_edges <= irq_edges + 1;
    if (en_window) begin
      if (status_r[3]) drq_cycles <= drq_cycles + 1;
      if (status_r[7]) bsy_cycles <= bsy_cycles + 1;
      if (status_r[0]) err_cycles <= err_cycles + 1;
    end
  end

  task automatic write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic read_byte(input [15:0] addr);
    begin
      @(negedge clk);
      io_addr = addr; io_rd = 1;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task automatic mount_image(input [63:0] bytes);
    begin
      img_size = bytes;
      @(negedge clk); img_mounted = 1;
      @(negedge clk); img_mounted = 0;
    end
  endtask

  // bank 0x0432/0 (the disk's), then one READ SECTORS of the sector at `lba` (LBA mode, unit 0)
  task automatic issue_read_sectors(input [27:0] lba);
    begin
      write_byte(16'h0432, 8'h00);
      repeat (2) @(negedge clk);
      write_byte(16'h0644, 8'h01);              // sector count = 1
      write_byte(16'h0646, lba[7:0]);           // sector number
      write_byte(16'h0648, lba[15:8]);          // cylinder low
      write_byte(16'h064A, lba[23:16]);         // cylinder high
      write_byte(16'h064C, 8'hE0);              // drive_head[6] = LBA mode
      write_byte(16'h064E, 8'h20);              // READ SECTORS
    end
  endtask

  // Read the sector out of the drive's buffer, which is what returns it to X_IDLE: a command
  // written while a transfer is still in flight is a takeover and is discarded
  // (pc9821_ata.sv:420 "command_takeover"), so a second command cannot follow an undrained one.
  task automatic drain_sector;
    begin
      while (status_r[3] && !status_r[7]) begin
        read_byte(16'h0640);
        read_byte(16'h0641);
      end
      repeat (4) @(negedge clk);
    end
  endtask

  integer i;
  integer off, width, lba4_lg, lba100_lg, saw_drq, bsy_end, err_end, irq_seen;

  task automatic scenario_reset;
    begin
      rst_n = 0;
      repeat (4) @(negedge clk);
      @(negedge clk) rst_n = 1;
      drq_cycles = 0; bsy_cycles = 0; err_cycles = 0; irq_edges = 0;
      host_requests = 0;
      @(negedge clk);
    end
  endtask

  // ONE eject-alignment scenario: reset, mount 1000 blocks, issue a read, present an eject
  // pulse of `width` cycles starting `off` cycles after the command write, then watch the
  // drive for 25000 cycles. `width` 0 means NO pulse (the control).
  task automatic eject_scenario(input integer off, input integer width, output integer o_drq,
                                output integer o_bsy, output integer o_err, output integer o_irq);
    begin
      scenario_reset;
      mount_image(64'd1000 * 64'd512);
      repeat (8) @(negedge clk);
      issue_read_sectors(28'd5);
      if (width > 0) begin
        img_size = 64'd0;
        for (i = 0; i < off; i = i + 1) @(negedge clk);
        img_mounted = 1;
        for (i = 1; i < width; i = i + 1) @(negedge clk);
        @(negedge clk); img_mounted = 0;
      end
      en_window = 1;
      repeat (25000) @(negedge clk);
      en_window = 0;
      o_drq = (drq_cycles > 0);
      o_bsy = status_r[7];
      o_err = status_r[0];
      o_irq = (irq_edges > 0);
    end
  endtask

  // ONE grow-alignment scenario: reset, mount 64 blocks; issue a read (the request whose
  // hand-over the pulse is aimed at); re-mount the SAME slot at 1000 blocks with a one-cycle
  // pulse `off` cycles after that command write; drain it; then read LBA 100, which exists
  // only in the grown image. It must be SERVED.
  task automatic grow_scenario(input integer off, output integer o_served, output integer o_err,
                               output integer o_irq);
    begin
      scenario_reset;
      mount_image(64'd64 * 64'd512);
      repeat (8) @(negedge clk);
      issue_read_sectors(28'd4);
      for (i = 0; i < off; i = i + 1) @(negedge clk);
      mount_image(64'd1000 * 64'd512);          // the grow: one cycle of img_mounted
      // wait for the positioning command to terminate, then drain it back to X_IDLE
      en_window = 1;
      for (i = 0; i < 30000; i = i + 1) begin
        @(negedge clk);
        if (!status_r[7] && (drq_cycles > 0 || err_cycles > 0)) i = 30000;
      end
      en_window = 0;
      drain_sector;
      repeat (10) @(negedge clk);
      // the fresh request: inside the NEW image, past the OLD one
      drq_cycles = 0; err_cycles = 0; irq_edges = 0;
      issue_read_sectors(28'd100);
      en_window = 1;
      repeat (25000) @(negedge clk);
      en_window = 0;
      o_served = (drq_cycles > 0);
      o_err    = (err_cycles > 0);
      o_irq    = (irq_edges > 0);
    end
  endtask

  initial begin
    #1_000_000_000;
    $fatal(1, "TB_PC9821_ATA_EJECT_ABORT: watchdog timeout (no verdict reached)");
  end

  initial begin
    repeat (4) @(negedge clk);

    // ==== PHASE 1: an eject across every offset around the hand-over ====
    // Every alignment must ABORT the command (ERR, BSY clear) - never wedge, and never serve
    // a read of the slot that was ejected. The pulse is presented well inside the host fetch's
    // own window (a 256-word transfer takes thousands of cycles, and the offsets here are single
    // cycles after the command write), so no alignment can legitimately have delivered the block
    // before the eject lands: a DRQ at any of them is the "served an ejected slot" defect.
    for (width = 1; width <= 3; width = width + 2) begin
      for (off = 0; off <= ((width == 1) ? 8 : 6); off = off + 1) begin
        eject_scenario(off, width, saw_drq, bsy_end, err_end, irq_seen);
        if (saw_drq) begin
          $display("  FAIL: eject width=%0d off=%0d: the command COMPLETED with DRQ -- a read of the ejected slot was SERVED (host requests=%0d)",
                   width, off, host_requests);
          fails = fails + 1;
        end else if (bsy_end) begin
          $display("  FAIL: eject width=%0d off=%0d: *** WEDGED: the drive is still BSY, no DRQ, no ERR -- the request was neither served nor aborted ***",
                   width, off);
          fails = fails + 1;
        end else if (!err_end) begin
          $display("  FAIL: eject width=%0d off=%0d: neither DRQ nor ERR nor BSY (status=%02x, IRQ=%0b) -- no terminal state",
                   width, off, status_r, irq_seen);
          fails = fails + 1;
        end
      end
    end

    // ==== PHASE 2: the control - no eject, the command must complete ====
    eject_scenario(0, 0, saw_drq, bsy_end, err_end, irq_seen);
    if (!saw_drq) begin
      $display("  FAIL: control (no eject): the command never reached DRQ (BSY=%0b ERR=%0b host requests=%0d)",
               bsy_end, err_end, host_requests);
      fails = fails + 1;
    end
    drain_sector;

    // ==== PHASE 3: a grow across the same window ====
    // The fresh LBA is inside the NEW image and past the OLD one, so a reject at any offset
    // means the engine is still holding the pre-mount capacity.
    for (off = 0; off <= 8; off = off + 1) begin
      grow_scenario(off, saw_drq, err_end, lba100_lg);
      if (!saw_drq) begin
        $display("  FAIL: grow off=%0d: the read of LBA 100 (inside the grown image) did not complete (ERR=%0b IRQ=%0b host requests=%0d) -- the engine kept the OLD capacity",
                 off, err_end, lba100_lg, host_requests);
        fails = fails + 1;
      end
    end

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_ATA_EJECT_ABORT: PASS");
      $finish;
    end else begin
      // $fatal(1, ...) and not a $display: Verilator's $finish returns from the process rather
      // than aborting it, so a failing run that only prints would exit ZERO (check_tests'
      // CAN PASS SILENTLY rule).
      $fatal(1, "TB_PC9821_ATA_EJECT_ABORT: FAIL (%0d errors)", fails);
    end
  end

endmodule
