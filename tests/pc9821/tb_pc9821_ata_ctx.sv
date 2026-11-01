`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The ATA's transfer context reaches the stall record's new ALB and ASE fields end to end: ALB is current_lba, the LBA the in-flight or last READ SECTORS started at, and it names the sector a transfer stopped on; ASE packs the task file's {sector_count, error_reg} high half first, so it reads 0101 at reset (the error register's 0x01 diagnostic value), 0400 while a 4-sector read of LBA 0x00123456 runs, and 0404 when the block engine fails that read - error_reg 0x04 ABRT (abort_command, NP2kai cmdabort's 0x41 class) with abort reason 1 (block engine error) in the ATA word above - which is the pair a capture needs to tell 'the guest never issued a command' from 'our own block engine failed'.
//
// WHY IT EXISTS. The stall record already carried the ATA's state byte and its
// command word (A and ATA: aborts, last command, commands, abort reason), but NOT the
// question a failed transfer actually asks: WHICH sector, and WHAT the error register
// says. A capture of a wedged card could show "one abort, reason 2" and
// nothing about where. These two fields close that, pinned here from the task file to
// the record bytes.
//
// The record indices are read BY INDEX - ALB_DIG0 is held to the formatter's ROM by
// tools/check_telemetry_contract.py, the coordinate class tb_pc9821_io_trace guards.

module tb_pc9821_ata_ctx;

// ==== DUT ====
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd2_000_000;
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

  // The two taps this bench exists for.
  wire [31:0] ata_dbg_lba;
  wire [15:0] ata_dbg_sec;

  pc9821_ata dut (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .block_read(block_read), .block_write(block_write), .block_lba(block_lba),
      .block_done(block_done), .block_error(block_error),
      .block_buf_we(block_buf_we), .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr), .block_rd_data(block_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd),
      .dbg_lba(ata_dbg_lba), .dbg_sec(ata_dbg_sec)
  );

  // The watchdog formatter fed the ATA taps; everything else is zero (other benches'
  // subjects). Snapshot exactly as pc9821_dbg_record's report accept.
  reg        msg_snap = 0;
  reg [15:0] msg_idx = 0;
  wire [7:0] msg_ch;

  pc9821_watchdog_msg msg (
      .clk(clk), .snap(msg_snap), .idx(msg_idx),
      .cpu_cs(16'h0), .cpu_eip(32'h0), .io_debug_status(8'h0),
      .triple_fault_reset(1'b0), .hdd_mounted(1'b0), .hdd_capacity(32'h0),
      .gdc_disp(1'b0), .vid_frame_cnt(8'h0), .hdd_req_cnt(8'h0), .hdd_err_cnt(8'h0),
      .hdd_busy(1'b0), .hdd_hps_cycles(32'h0),
      .vid_lit_seen(1'b0), .vid_lit_cnt(8'h0),
      .ata_dbg_state(dbg_state), .ata_dbg_cmd(dbg_cmd),
      .ata_dbg_lba(ata_dbg_lba), .ata_dbg_sec(ata_dbg_sec),
      .io_dbg_gate(4'h0), .mounted_at_run(1'b0),
      .gdc_dbg_sad(16'h0), .gdc_dbg_pitch(8'h0), .gdc_dbg_col40(1'b0), .gdc_dbg_disp(1'b0),
      .kbd_dbg_events(8'h0), .kbd_dbg_delivered(8'h0), .kbd_dbg_rd_data(8'h0),
      .kbd_dbg_wr_ctrl(8'h0), .kbd_dbg_rts(1'b0), .kbd_dbg_rx_en(1'b0), .kbd_irq(1'b0),
      .kbd_dbg_last_del(8'h0), .kbd_dbg_ctrl0(8'h0), .kbd_dbg_ctrl1(8'h0),
      .irq_dbg_imr(8'h0), .irq_dbg_irr(8'h0), .irq_dbg_isr(8'h0), .inta_din(8'h0),
      .cpu_irq_state(8'h0), .inta_count(8'h0),
      .artic_hi(16'h0), .io_itf_stage(8'h0),
      .last_io_addr(16'h0), .last_io_data(8'h0), .last_io_rd(1'b0), .last_io_wr(1'b0),
      .fdc_dbg_state(8'h0), .fdc_dbg_cmd(8'h0),
      .fdc_dbg_result(32'h0), .fdc_dbg_chrn(32'h0),
      .ch(msg_ch)
  );

  // The record indices of the two fields' FIRST digit in the 351-byte record.
  localparam [15:0] ALB_DIG0 = 16'd327;
  localparam [15:0] ASE_DIG0 = 16'd340;

  // The bound: a stuck DUT cannot outlast this.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_ATA_CTX: TIMEOUT (no verdict reached)");
  end

// ==== STIMULUS ====
  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task snap;
    begin
      @(negedge clk); msg_snap = 1;
      @(posedge clk); #1; msg_snap = 0;
    end
  endtask

  task expect_field(input [15:0] dig0, input integer n, input [31:0] exp,
                    input [8*40-1:0] what);
    integer k;
    reg [7:0] c;
    reg [31:0] got;
    begin
      got = 0;
      for (k = 0; k < n; k = k + 1) begin
        msg_idx = dig0 + k[15:0];
        #1;
        c = msg_ch;
        got = (got << 4) | ((c >= 8'h30 && c <= 8'h39) ? (c - 8'h30)
                            : (c >= 8'h41 && c <= 8'h46) ? (c - 8'h37) : 4'hF);
      end
      if (got !== exp)
        $fatal(1, "TB_PC9821_ATA_CTX: %0s: record bytes %0d..%0d read %08x, want %08x",
               what, dig0, dig0 + n - 1, got, exp);
    end
  endtask

  task expect_lit(input [15:0] i, input [7:0] exp, input [8*40-1:0] what);
    begin
      msg_idx = i; #1;
      if (msg_ch !== exp)
        $fatal(1, "TB_PC9821_ATA_CTX: %0s: record byte %0d is %02x, want %02x",
               what, i, msg_ch, exp);
    end
  endtask

// ==== CHECKS ====
  initial begin
    rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // CHK-0: the labels are where the contract puts them.
    expect_lit(16'd322, " ",  "ALB label");
    expect_lit(16'd323, "A",  "ALB label");
    expect_lit(16'd324, "L",  "ALB label");
    expect_lit(16'd325, "B",  "ALB label");
    expect_lit(16'd326, "=",  "ALB label");
    expect_lit(16'd335, " ",  "ASE label");
    expect_lit(16'd336, "A",  "ASE label");
    expect_lit(16'd337, "S",  "ASE label");
    expect_lit(16'd338, "E",  "ASE label");
    expect_lit(16'd339, "=",  "ASE label");

    // CHK-1: RESET. current_lba is 0 (no transfer ever), sector_count resets to 1 and
    // the error register to its 0x01 diagnostic value - so ASE reads 0101 and a zero
    // ALB is "nothing has run", not "a transfer at LBA 0".
    snap;
    expect_field(ALB_DIG0, 8, 32'h00000000, "reset: current_lba");
    expect_field(ASE_DIG0, 4, 32'h0101, "reset: {sector_count, error_reg}");

    // CHK-2: A RUNNING 4-SECTOR READ OF LBA 0x00123456. The bank select makes the
    // device present (bit 0 is the connection test), the task file carries the LBA in
    // its four registers (drive_head[6] selects LBA mode), and READ SECTORS 0x20
    // latches current_lba and asks the block engine. The record must name the sector:
    // ALB=00123456 with ASE=0400 (four sectors owed, no error).
    write_byte(16'h0432, 8'h00);          // select the built-in IDE bank
    write_byte(16'h0644, 8'h04);          // sector_count = 4
    write_byte(16'h0646, 8'h56);          // sector_number (LBA 7:0)
    write_byte(16'h0648, 8'h34);          // cylinder_low  (LBA 15:8)
    write_byte(16'h064A, 8'h12);          // cylinder_high (LBA 23:16)
    write_byte(16'h064C, 8'h40);          // drive_head: LBA mode, LBA 27:24 = 0
    write_byte(16'h064E, 8'h20);          // READ SECTORS
    repeat (3) @(negedge clk);
    snap;
    expect_field(ALB_DIG0, 8, 32'h00123456, "read running: current_lba");
    expect_field(ASE_DIG0, 4, 32'h0400, "read running: {sector_count, error_reg}");

    // CHK-3: THE BLOCK ENGINE FAILS THE READ. block_done with block_error is the
    // adapter's failure answer (X_WAIT_BLOCK -> abort_command reason 1): the error
    // register takes 0x04 ABRT and the abort reason lands in the ATA word (already
    // pinned by tb_pc9821_ata_dbg). ALB keeps naming the sector that failed and ASE
    // reads 0404 - the pair that says "our own block engine failed HERE".
    @(negedge clk); block_done = 1; block_error = 1;
    @(negedge clk); block_done = 0; block_error = 0;
    repeat (2) @(negedge clk);
    snap;
    expect_field(ALB_DIG0, 8, 32'h00123456, "block error: the LBA that failed");
    expect_field(ASE_DIG0, 4, 32'h0404, "block error: {sector_count, error_reg=ABRT}");

    // ==== VERDICT ====
    $display("TB_PC9821_ATA_CTX: PASS");
    $finish;
  end

endmodule

`default_nettype wire
