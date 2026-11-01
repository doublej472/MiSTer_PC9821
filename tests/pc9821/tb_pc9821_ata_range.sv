// tb_pc9821_ata_range — which data commands the end-of-image check accepts, against ATA's own rule.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_RANGE:
// A data command (READ SECTORS 0x20) is accepted exactly when the image holds every sector it names, which is ATA's own rule and the bench's own 64-bit arithmetic, never a value read out of the RTL: the sector count (0 meaning 256) fits between the start LBA and the capacity (start + count <= capacity, so capacity 0 accepts nothing), in the LBA28 form for starts at 0, capacity-2, capacity-1, capacity, capacity+1 and 2^28-1 and counts 1, 2, 255 and 256 over capacities from 0 to 2^32-1 (the 2^28 and 2^31 classes included, whose starts the LBA28 field cannot name past 2^28-1), and in the CHS form of the default 8-head/17-sector geometry for sectors 0, 1, 17 and 18 and heads 7 and 8 around a capacity boundary, an invalid sector or head being refused whatever the capacity; an accepted command issues its block request at the LBA the task file named and a refused one answers STATUS 0x41 with ERROR 0x04 and issues none.

module tb_pc9821_ata_range;

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
  integer checks = 0;
  reg [7:0] value;

  task fail(input [8*72-1:0] message);
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

  // A minimal block model: every request completes without error the cycle after it is made, so
  // an accepted command runs to its first DRQ and a refused one never produces a request.
  reg        saw_req;
  reg [31:0] req_lba;
  always @(posedge clk) begin
    block_done <= block_read;
    if (block_read) begin
      if (!saw_req) req_lba <= block_lba;   // the first request: a read-ahead follows it
      saw_req <= 1'b1;
    end
  end

  task srst;
    begin
      write_byte(16'h074C, 8'h04);
      write_byte(16'h074C, 8'h00);
      repeat (40) @(posedge clk);
    end
  endtask

  // One READ SECTORS and the verdict. `lba_mode` selects the form; (c,h,s) are the CHS fields.
  task run_cmd(input integer lba_mode, input [27:0] lba, input [15:0] cyl, input [3:0] head,
               input [7:0] sec, input [8:0] count, input accept, input [8*24-1:0] tag);
    reg [7:0] cnt8;
    begin
      cnt8 = count[7:0];
      srst;
      saw_req = 0;
      write_byte(16'h0644, cnt8);
      if (lba_mode) begin
        write_byte(16'h0646, lba[7:0]);
        write_byte(16'h0648, lba[15:8]);
        write_byte(16'h064A, lba[23:16]);
        write_byte(16'h064C, {4'hE, lba[27:24]});
      end else begin
        write_byte(16'h0646, sec);
        write_byte(16'h0648, cyl[7:0]);
        write_byte(16'h064A, cyl[15:8]);
        write_byte(16'h064C, {4'hA, head});
      end
      repeat (4) @(posedge clk);
      write_byte(16'h064E, 8'h20);
      repeat (12) @(posedge clk);
      checks = checks + 1;
      if (accept) begin
        if (!saw_req) begin $display("  %0s: cap=%0d lba=%0d count=%0d: refused, want accepted", tag, capacity, lba, count); fail("a command that fits was refused"); end
        else if (lba_mode && req_lba !== {4'd0, lba}) begin $display("  %0s: cap=%0d lba=%0d: requested %0d", tag, capacity, lba, req_lba); fail("block request is not at the task file's LBA"); end
      end else begin
        read_byte(16'h074C, value);
        if (saw_req) begin $display("  %0s: cap=%0d lba=%0d count=%0d: accepted, want refused", tag, capacity, lba, count); fail("a command past the image was accepted"); end
        else if (value !== 8'h41) begin $display("  %0s: STATUS %02x", tag, value); fail("refusal STATUS is not 0x41"); end
        else begin
          read_byte(16'h0642, value);
          if (value !== 8'h04) fail("refusal ERROR is not 0x04");
        end
      end
    end
  endtask

  // ==== CHECKS ====
  localparam integer NCAP = 12;
  reg [31:0] caps [0:NCAP-1];
  reg [27:0] starts [0:5];
  reg [8:0]  counts [0:3];
  reg [31:0] cap, s64;
  reg [63:0] lo, last;
  integer ci, si, ni;
  reg        exp_ok;
  integer ch, sc, hd;
  reg [63:0] chs_lba;

  initial begin
    caps[0] = 32'd0;           caps[1] = 32'd1;           caps[2] = 32'd2;
    caps[3] = 32'd256;         caps[4] = 32'd257;         caps[5] = 32'd1000;
    caps[6] = 32'd4096;        caps[7] = 32'd16_777_216;  caps[8] = 32'd268_435_455;
    caps[9] = 32'd268_435_456; caps[10] = 32'd2_147_483_648; caps[11] = 32'd4_294_967_295;
    counts[0] = 9'd1; counts[1] = 9'd2; counts[2] = 9'd255; counts[3] = 9'd256;

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    write_byte(16'h0432, 8'h00);   // the bank the interface is on

    // ---- LBA28 ----
    for (ci = 0; ci < NCAP; ci = ci + 1) begin
      cap = caps[ci];
      capacity = cap;
      repeat (4) @(posedge clk);
      starts[0] = 28'd0;
      starts[1] = (cap >= 2) ? 28'(cap - 2) : 28'd0;
      starts[2] = (cap >= 1) ? 28'(cap - 1) : 28'd0;
      starts[3] = 28'(cap);
      starts[4] = 28'(cap + 1);
      starts[5] = 28'hFFFFFFF;
      for (si = 0; si < 6; si = si + 1)
        for (ni = 0; ni < 4; ni = ni + 1) begin
          lo = {36'd0, starts[si]};
          last = lo + counts[ni];
          // ATA: the whole run [lba, lba+count) must lie inside [0, capacity)
          exp_ok = (last <= {32'd0, cap});
          run_cmd(1, starts[si], 16'd0, 4'd0, 8'd1, counts[ni], exp_ok, "lba28");
        end
    end

    // ---- CHS (default geometry 8 heads x 17 sectors) around a capacity boundary ----
    capacity = 32'd1000;     // 7*136 + 3*17 + (s-1): the boundary falls inside cylinder 7
    repeat (4) @(posedge clk);
    for (ch = 5; ch <= 8; ch = ch + 1)
      // heads 0, 7 and 8: 8 is the first head past the 8-head geometry. (This loop once
      // stepped `hd + 7`, which visits 0 and 7 only, so the head-8 refusal the claim names
      // was never driven - a 3-bit head compare survived it.)
      for (hd = 0; hd <= 8; hd = (hd == 0) ? 7 : hd + 1)
        for (sc = 0; sc <= 18; sc = sc + 1) begin
          if (sc == 0 || sc == 1 || sc == 2 || sc == 17 || sc == 18) begin
            chs_lba = (ch * 8 + hd) * 17 + sc - 1;
            exp_ok = (sc >= 1) && (sc <= 17) && (hd <= 7) && (chs_lba + 1 <= 64'd1000);
            run_cmd(0, 28'd0, ch[15:0], hd[3:0], sc[7:0], 9'd1, exp_ok, "chs");
            exp_ok = (sc >= 1) && (sc <= 17) && (hd <= 7) && (chs_lba + 2 <= 64'd1000);
            run_cmd(0, 28'd0, ch[15:0], hd[3:0], sc[7:0], 9'd2, exp_ok, "chs2");
          end
        end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("  %0d commands checked", checks);
      $display("TB_PC9821_ATA_RANGE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_RANGE: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_ATA_RANGE: TIMEOUT");
  end
endmodule
