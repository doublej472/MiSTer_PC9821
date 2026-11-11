`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The IDE interface's own registers read back as the Xe10 reads them (docs/probes/KIT1-XE10-IDE1.TXT, XE10CFG /IDE): 0x0432 written 00, 01, 02, 03, 2A and 80 reads back 00, 01, 00, 01, 22 and 00 - bit 0 and bit 5 read back, bit 3 never, bit 1 only beside bit 5, and a bit-7 write is a no-op that leaves the bank as it was (KIT1-XE10-IDEPROBE.TXT `0432<-80 rb=01`) - while the bank select itself still follows bit 0 of the written byte; 0x0433 reads 00 after every one of those bank writes, and is the interrupt-pending port: a CHECK POWER MODE completion on bank 0 reads 01 (twice, and an alternate-status read does not clear it) until the 0x064E status read acknowledges it, then 00, where NP2kai's ideio_i433 connect flag answered 02 in every row; bit 1 is bank 1's interrupt (qemu-pc98 irq_levels), set by a completion on a second disk on bank 1 whichever bank is selected, and a completion under nIEN sets neither bit; and 0x074E reads 0F with the slave selected (`IDES dh=A3 da=0F`) and 00 with the master (`IDEB w=00 ... da=00`). Kit 2's sweep (docs/probes/KIT2-XE10-IDE2.TXT, XE10CFG /IDE2): 0x0432 written 04, 06, 07, 10, 20, 22, 23 and 40 reads back 00, 00, 01, 10, 20, 22, 23 and FF; with bit 2 set (04, 06, 07) every task-file register 0x0642-0x064E, 0x074C and 0x074E reads that read-back byte and 0x0433 reads 00, and with 10, 20, 22 and 40 the task file is bank 0's (status and alternate status 50, 0x074E 00).
//
// ---- the bench's own account of where each expectation comes from ----
//
//  docs/probes/KIT1-XE10-IDE1.TXT (the machine, XE10CFG /IDE; each row writes 0x0432, reads it
//  back with 0x064E, 0x074C, 0x074E and 0x0433, then puts the as-found 00 back):
//      IDEB w=00 r432=00 st=50 ast=50 da=00 433=00
//      IDEB w=01 r432=01 ...                433=00
//      IDEB w=02 r432=00 ...                433=00
//      IDEB w=03 r432=01 ...                433=00
//      IDEB w=2A r432=22 ...                433=00
//      IDEB w=80 r432=00 ...                433=00
//      IDES dh=A3 da=0F st=00 ast=00 back=A3      (0x064C <- B0, the slave, on bank 0)
//      IDEI ran=1 pre433/preirr/433/irr/433b/ast/st/433ack/irrack/count/err
//           00 10 01 12 01 50 50 00 10 FF 00       (CHECK POWER MODE on bank 0)
//  docs/probes/KIT1-XE10-IDEPROBE.TXT: `BANK 0432<-01 rb=01`, then `BANK 0432<-80 rb=01`.
//  The machine's bank 1 never had an interrupt pending in the capture, so bit 1's meaning is
//  the next reference's: qemu-pc98 hw/ide/pc98-ide.c `ret = s->irq_levels & 0x03;` (one
//  level per channel, raised only while nIEN is clear, hw/ide/core.c ide_bus_set_irq).
//  docs/probes/KIT2-XE10-IDE2.TXT (kit 2, XE10CFG /IDE2; 0x0432, 0x0642-0x064E, 0x074C, 0x074E
//  and 0x0433 read back to back after each write):
//      IDE2B w=04 432/err/cnt/sec/cyl/cyh/dh/st/ast/da/433 00 00 00 00 00 00 00 00 00 00 00
//      IDE2B w=06 ...                                      00 00 00 00 00 00 00 00 00 00 00
//      IDE2B w=07 ...                                      01 01 01 01 01 01 01 01 01 01 00
//      IDE2B w=10 ...                                      10 00 00 04 05 00 A1 50 50 00 00
//      IDE2B w=20 / 22 / 23: 432 = 20 / 22 / 23, the same bank-0 task file (23's not pinned)
//      IDE2B w=40 ...                                      FF 00 00 04 05 00 A1 50 50 00 00
//  (the bank-0 rows' sector/cylinder/drive-head bytes are that machine's state, not pinned).
//  The status rows of banks 02/03 (st=00 / 04) are not pinned: that task-file state is not
//  modelled (todo item 27).
//
// FAIL-FIRST: on the pre-fix tree 0x0432 reads back 02/03/2A, 0x0433 reads the connect
// flag 02 at bank 0 whether or not an interrupt is pending, and 0x074E reads 00 with the
// slave selected. Kit 2's rows: before its fix 0x0432 <- 40 read back 40 and the bit-2 task
// file read the bank's registers (status 50 at 04/06, the empty bank's 0E at 07).

module tb_pc9821_readback_ata;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd1000;
  reg mounted1 = 0, readonly1 = 0;
  reg [31:0] capacity1 = 32'd2000;
  wire block_read, block_write, block_unit;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq, xfer;
  wire [7:0] dbg_state;
  wire [31:0] dbg_cmd;
  wire [31:0] dbg_lba;
  wire [15:0] dbg_sec;

  // ==== DUT ====
  pc9821_ata dut (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .mounted1(mounted1), .readonly1(readonly1), .capacity1(capacity1),
      .block_read(block_read), .block_write(block_write), .block_lba(block_lba),
      .block_unit(block_unit),
      .block_done(block_done), .block_error(block_error),
      .block_buf_we(block_buf_we), .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr), .block_rd_data(block_rd_data),
      .irq(irq), .xfer(xfer), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd),
      .dbg_lba(dbg_lba), .dbg_sec(dbg_sec));

  integer errors = 0, cases = 0;

  // ==== CHECKS ====
  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
      repeat (2) @(posedge clk);
    end
  endtask

  task read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
      repeat (2) @(posedge clk);
    end
  endtask

  task expect_port(input [15:0] addr, input [7:0] expected,
                   input [8*72-1:0] what);
    reg [7:0] got;
    begin
      cases = cases + 1;
      read_byte(addr, got);
      if (got !== expected) begin
        $display("MISMATCH %0s: port %04x expected %02x got %02x", what, addr, expected, got);
        errors = errors + 1;
      end
      else $display("ok       %0s = %02x", what, got);
    end
  endtask

  // The capture's bank row: write, read 0x0432 and 0x0433 back, put the as-found 00 back.
  task bank_row(input [7:0] w, input [7:0] want432);
    begin
      write_byte(16'h0432, w);
      expect_port(16'h0432, want432, "0x0432 read-back of the written bank byte");
      expect_port(16'h0433, 8'h00, "0x0433 after the bank write, nothing pending");
      write_byte(16'h0432, 8'h00);
    end
  endtask

  // Kit 2's IDE2B row in a bit-2 state: 0x0432, err, cnt, sec, cyl, cyh, dh, st, ast, da all
  // read `want`, 0x0433 reads 00 (KIT2-XE10-IDE2.TXT:4-8).
  task b2_row(input [7:0] w, input [7:0] want);
    reg [15:0] a;
    begin
      write_byte(16'h0432, w);
      expect_port(16'h0432, want, "IDE2B bit-2 row: 0x0432");
      for (a = 16'h0642; a <= 16'h064E; a = a + 16'd2)
        expect_port(a, want, "IDE2B bit-2 row: the task file reads the 0x0432 byte");
      expect_port(16'h074C, want, "IDE2B bit-2 row: ast");
      expect_port(16'h074E, want, "IDE2B bit-2 row: da");
      expect_port(16'h0433, 8'h00, "IDE2B bit-2 row: 433");
      write_byte(16'h0432, 8'h00);
    end
  endtask

  // Kit 2's IDE2B row in a bank-0 state: st=50 ast=50 da=00 433=00 (KIT2-XE10-IDE2.TXT:10-18).
  task b0_row(input [7:0] w, input [7:0] want432);
    begin
      write_byte(16'h0432, w);
      expect_port(16'h0432, want432, "IDE2B bank-0 row: 0x0432");
      expect_port(16'h064E, 8'h50, "IDE2B bank-0 row: st");
      expect_port(16'h074C, 8'h50, "IDE2B bank-0 row: ast");
      expect_port(16'h074E, 8'h00, "IDE2B bank-0 row: da");
      expect_port(16'h0433, 8'h00, "IDE2B bank-0 row: 433");
      write_byte(16'h0432, 8'h00);
    end
  endtask

  // A no-data command; waits for BSY to clear.
  task run_cmd(input [7:0] cmd);
    reg [7:0] st;
    integer n;
    begin
      write_byte(16'h064E, cmd);
      n = 0;
      do begin read_byte(16'h074C, st); n = n + 1; end while (st[7] && n < 1000);
      repeat (20) @(posedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    // ---- 0x0432: the bank sweep (KIT1-XE10-IDE1.TXT rows IDEB) ----
    bank_row(8'h00, 8'h00);
    bank_row(8'h01, 8'h01);
    bank_row(8'h02, 8'h00);
    bank_row(8'h03, 8'h01);
    bank_row(8'h2A, 8'h22);
    bank_row(8'h80, 8'h00);
    // The bit-7 no-op keeps the bank as it was (KIT1-XE10-IDEPROBE.TXT `0432<-80 rb=01`).
    write_byte(16'h0432, 8'h01);
    write_byte(16'h0432, 8'h80);
    expect_port(16'h0432, 8'h01, "0x0432 <- 80 after 01 reads 01: the write is a no-op");
    // The read-back mask leaves the bank select alone: 0x2A is bank 0, the disk answers
    // (IDEB w=2A st=50), and 0x03 is bank 1, which floats here (no disk on bank 1).
    write_byte(16'h0432, 8'h2A);
    expect_port(16'h064E, 8'h50, "bank 0x2A is bank 0: the disk's status");
    write_byte(16'h0432, 8'h09);
    expect_port(16'h0432, 8'h01, "0x0432 <- 09 (bit 3, DWORD PIO) reads back 01");
    expect_port(16'h064E, 8'h0E, "bank 0x09 is bank 1: the empty bank's float");
    write_byte(16'h0432, 8'h00);

    // ---- kit 2's sweep (KIT2-XE10-IDE2.TXT:4-18, rows IDE2B) ----
    // Bit 2: 0x0432 and then the whole task file read the read-back byte, 0x0433 00.
    b2_row(8'h04, 8'h00);
    b2_row(8'h06, 8'h00);
    b2_row(8'h07, 8'h01);
    // Bits 4, 5 and 6: the task file is bank 0's (st=50 ast=50 da=00 433=00); 40 reads FF.
    b0_row(8'h10, 8'h10);
    b0_row(8'h20, 8'h20);
    b0_row(8'h22, 8'h22);
    // 23 has bit 0 set and read the same bank-0 registers on the machine (sec 04, cyl 05, dh A1,
    // st 50): whether bit 1 + bit 5 select bank 0 or that machine's bank 1 answered alike is not
    // settled, so only its read-back is pinned here.
    write_byte(16'h0432, 8'h23);
    expect_port(16'h0432, 8'h23, "IDE2B w=23: 0x0432");
    write_byte(16'h0432, 8'h00);
    b0_row(8'h40, 8'hFF);

    // ---- 0x074E with the master and with the slave selected (IDEB w=00 da=00; IDES) ----
    write_byte(16'h064C, 8'hA3);
    expect_port(16'h074E, 8'h00, "0x074E with the master selected (da=00)");
    write_byte(16'h064C, 8'hB0);
    expect_port(16'h074E, 8'h0F, "0x074E with the slave selected (IDES da=0F)");
    expect_port(16'h064E, 8'h00, "the absent slave's status (IDES st=00)");
    expect_port(16'h074C, 8'h00, "the absent slave's alternate status (IDES ast=00)");
    write_byte(16'h064C, 8'hA3);
    expect_port(16'h064C, 8'hA3, "0x064C put back reads A3 (IDES back=A3)");

    // ---- 0x0433 with an interrupt pending (IDEI) ----
    expect_port(16'h0433, 8'h00, "IDEI pre433 = 00");
    run_cmd(8'hE5);   // CHECK POWER MODE
    if (irq !== 1'b1) begin
      $display("MISMATCH CHECK POWER MODE did not raise the interrupt: the rows below are vacuous");
      errors = errors + 1;
    end
    expect_port(16'h0433, 8'h01, "IDEI 433 = 01 with bank 0's interrupt pending");
    expect_port(16'h0433, 8'h01, "IDEI 433b = 01: the read does not clear it");
    expect_port(16'h074C, 8'h50, "IDEI ast = 50");
    expect_port(16'h0433, 8'h01, "0x0433 still 01 after the alternate-status read");
    expect_port(16'h064E, 8'h50, "IDEI st = 50 (the acknowledge)");
    expect_port(16'h0433, 8'h00, "IDEI 433ack = 00 after the status read");
    expect_port(16'h0644, 8'hFF, "IDEI count = FF (the power mode: active)");
    expect_port(16'h0642, 8'h00, "IDEI err = 00");

    // ---- nIEN: a completion under nIEN raises no interrupt and sets no bit (qemu-pc98) ----
    write_byte(16'h074C, 8'h02);
    run_cmd(8'hE5);
    expect_port(16'h0433, 8'h00, "a completion under nIEN sets no 0x0433 bit");
    expect_port(16'h064E, 8'h50, "status read under nIEN");
    write_byte(16'h074C, 8'h00);

    // ---- bit 1: bank 1's interrupt (qemu-pc98 irq_levels), with a second disk there ----
    mounted1 = 1;
    repeat (200) @(posedge clk);
    write_byte(16'h0432, 8'h01);
    repeat (40) @(posedge clk);
    expect_port(16'h0432, 8'h01, "bank 1 selected");
    write_byte(16'h064C, 8'hA0);
    run_cmd(8'hE5);
    expect_port(16'h0433, 8'h02, "bank 1's interrupt pending reads bit 1");
    write_byte(16'h0432, 8'h00);   // bank 0 selected: the bank-1 level is not the selection's
    repeat (40) @(posedge clk);
    expect_port(16'h0433, 8'h02, "bank 1's interrupt is still bit 1 with bank 0 selected");
    run_cmd(8'hE5);
    expect_port(16'h0433, 8'h03, "both banks' interrupts pending read 03");
    expect_port(16'h064E, 8'h50, "bank 0's status read (its acknowledge)");
    expect_port(16'h0433, 8'h02, "bank 0's acknowledge leaves bank 1's bit");
    write_byte(16'h0432, 8'h01);
    repeat (40) @(posedge clk);
    expect_port(16'h064E, 8'h50, "bank 1's status read (its acknowledge)");
    expect_port(16'h0433, 8'h00, "both acknowledged: 0x0433 reads 00");
    write_byte(16'h0432, 8'h00);

    // The neighbour is untouched.
    expect_port(16'h0435, 8'h00, "0x0435 stays 0x00");

    // ==== VERDICT ====
    $display("NOTE readback_ata: %0d cases, %0d mismatched, sim %0t", cases, errors, $time);
    if (errors == 0) begin
      $display("TB_PC9821_READBACK_ATA: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_READBACK_ATA: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_READBACK_ATA: TIMEOUT");
  end

endmodule
