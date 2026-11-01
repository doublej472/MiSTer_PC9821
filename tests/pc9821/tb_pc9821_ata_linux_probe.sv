// tb_pc9821_ata_linux_probe - the Linux pc98_ide.c probe against an absent IDE slave.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_LINUX_PROBE: The Linux/98 IDE driver's probe (pc98_ide.c, pc98ide_init + pc98ide_identify), which boots on the real Xe10, replayed port for port against the REAL pc9821_ata -> pc9821_block_share -> pc9821_block_io stack with the one disk image mounted at bank 0 (the core's fixed position, bank 0's master, so pc98ide_init's own `outb(0, PC98IDE_BANK)` reaches it unchanged): the bank select, SRST through 0x74C, then for unit 0 the 0xE0 select, four alternate-status reads, STATUS neither 0x00 nor 0xFF, IDENTIFY with STATUS non-zero, DRQ and words 60/61 = the image's capacity; and for unit 1 the 0xF0 select, which must read STATUS = ALTSTATUS = 0x00 (ATA-3 r6 s.9.5.1, an absent device 1), so the driver gives the unit up - and an IDENTIFY written anyway must leave STATUS 0x00 with no DRQ and no IRQ (a command for the absent device is not executed), EXECUTE DEVICE DIAGNOSTIC written with device 1 selected is still executed by device 0 (IRQ, ERROR 0x01), and re-selecting 0xE0 must show the master's 0x50 and serve a READ SECTORS of the image's own data. FAIL-FIRST: on ffd1ae9d the absent slave answered 0x50 and IDENTIFY returned the master's page, which is the phantom hdb Linux saw on the MiSTer.
//
// Reference: the Linux/98 IDE driver, pc98_ide.c (the driver of a Linux image
// that boots on the real Xe10 - a software observation of the real machine, rank 2):
// pc98ide_init "outb(0, PC98IDE_BANK); outb(ATA_CTL_NIEN | ATA_CTL_SRST, PC98IDE_CONTROL);"
// then pc98ide_identify per unit "outb(ATA_DEV_LBA | (dev->unit << 4), PC98IDE_DEVICE);
// pc98ide_400ns_delay(); if (inb(PC98IDE_STATUS) == 0 || inb(PC98IDE_STATUS) == 0xff) return
// -ENODEV; outb(ATA_CMD_IDENTIFY, PC98IDE_COMMAND); if (inb(PC98IDE_STATUS) == 0) return -ENODEV;".
// The absent-device answer itself is ATA-3 r6 s.9.5.1.
// ==== DUT ====

module tb_pc9821_ata_linux_probe;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer errors = 0;

  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  wire ata_block_read, ata_block_write;
  wire [31:0] ata_block_lba;
  wire ata_block_done, ata_block_error, ata_buf_we;
  wire [7:0] ata_buf_addr;
  wire [15:0] ata_buf_data;
  wire [7:0] ata_rd_addr;
  wire [15:0] ata_rd_data;
  wire irq;

  wire hdd_mounted, hdd_readonly;
  wire [31:0] hdd_capacity;
  wire [31:0] a_lba;
  wire [5:0]  a_blk;
  wire a_rd, a_wr;
  wire [15:0] a_din;
  // The host model below still has a second image's leg; nothing drives it any more.
  wire [31:0] d_lba = 32'd0;
  wire [5:0]  d_blk = 6'd0;
  wire d_rd = 1'b0, d_wr = 1'b0;
  wire [15:0] d_din = 16'd0;

  // Image sizes in sectors. Different, so a capacity answered from the wrong slot is visible.
  localparam [7:0] BANK = 8'h00;   // pc98ide_init's own outb(0, PC98IDE_BANK): the disk is bank 0's master
  localparam [31:0] CAP_A = 32'd20160;   // 20 cylinders of 16*63
  localparam [31:0] CAP_D = 32'd5040;    //  5 cylinders of 16*63

  reg a_mount = 0, d_mount = 0;
  reg [63:0] a_size = {32'd0, CAP_A} * 64'd512;
  reg [63:0] d_size = {32'd0, CAP_D} * 64'd512;

  reg a_ack = 0, d_ack = 0;
  reg sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;

  pc9821_ata ata (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .mounted(hdd_mounted), .readonly(hdd_readonly), .capacity(hdd_capacity),
      .block_read(ata_block_read), .block_write(ata_block_write), .block_lba(ata_block_lba),
      .block_done(ata_block_done), .block_error(ata_block_error),
      .block_buf_we(ata_buf_we), .block_buf_addr(ata_buf_addr), .block_buf_data(ata_buf_data),
      .block_rd_addr(ata_rd_addr), .block_rd_data(ata_rd_data),
      .irq(irq),
      /* verilator lint_off PINCONNECTEMPTY */
      .dbg_state(), .dbg_cmd(), .dbg_lba(), .dbg_sec()
      /* verilator lint_on PINCONNECTEMPTY */
  );

  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_block_share share (
      .clk(clk), .rst_n(rst_n),
      .a_img_mounted(a_mount), .a_img_readonly(1'b0), .a_img_size(a_size),
      .a_mounted(hdd_mounted), .a_readonly(hdd_readonly), .a_capacity(hdd_capacity),
      .a_req_read(ata_block_read), .a_req_write(ata_block_write), .a_req_lba(ata_block_lba),
      .a_req_window(1'b1),
      .a_req_done(ata_block_done), .a_req_error(ata_block_error), .a_busy(),
      .a_buf_we(ata_buf_we), .a_buf_addr(ata_buf_addr), .a_buf_data(ata_buf_data),
      .a_buf_rd_addr(ata_rd_addr), .a_buf_rd_data(ata_rd_data),
      .a_sd_lba(a_lba), .a_sd_blk_cnt(a_blk), .a_sd_rd(a_rd), .a_sd_wr(a_wr),
      .a_sd_ack(a_ack), .a_sd_buff_din(a_din),
      .b_img_mounted(1'b0), .b_img_readonly(1'b1), .b_img_size(64'd0),
      .b_req_read(1'b0), .b_req_lba(16'd0), .b_req_slot(1'b0),
      .b_req_done(), .b_req_error(), .b_busy(),
      .b_buf_we(), .b_buf_addr(), .b_buf_data(),
      .b_sd_lba(), .b_sd_blk_cnt(), .b_sd_rd(), .b_sd_wr(), .b_sd_ack(1'b0), .b_sd_buff_din(),
      .c_img_mounted(1'b0), .c_img_readonly(1'b1), .c_img_size(64'd0),
      .c_sd_lba(), .c_sd_blk_cnt(), .c_sd_rd(), .c_sd_wr(), .c_sd_ack(1'b0), .c_sd_buff_din(),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ==== the two images ====
  // Each image's content is a function of (slot, lba, word), so the bytes a read returns name
  // the image they came from. Writes land in a per-slot overlay the host model keeps.
  function automatic [15:0] img_word(input integer slot, input [31:0] lba, input [7:0] w);
    begin
      img_word = (slot == 0) ? {lba[7:0] ^ w, lba[15:8] ^ 8'h3C}
                             : {lba[7:0] ^ ~w, lba[15:8] ^ 8'hC3};
    end
  endfunction
  reg [15:0] ovl_a [longint];
  reg [15:0] ovl_d [longint];
  function automatic [15:0] host_word(input integer slot, input [31:0] lba, input [7:0] w);
    longint k;
    begin
      k = longint'(lba) * 256 + w;
      if (slot == 0 && ovl_a.exists(k)) host_word = ovl_a[k];
      else if (slot == 1 && ovl_d.exists(k)) host_word = ovl_d[k];
      else host_word = img_word(slot, lba, w);
    end
  endfunction

  integer a_rd_reqs = 0, d_rd_reqs = 0, a_wr_reqs = 0, d_wr_reqs = 0;
  integer hi, hk, hslot;
  reg [31:0] h_lba;
  reg [2:0] h_state = 0;   // 0 idle, 1 read stream, 2 write stream
  always @(negedge clk) begin
    sd_buff_wr = 0;
    case (h_state)
      3'd0: begin
        if (a_rd || d_rd) begin
          hslot = a_rd ? 0 : 1;
          h_lba = a_rd ? a_lba : d_lba;
          hk    = ((a_rd ? a_blk : d_blk) + 1) * 256;
          if (a_rd) a_rd_reqs = a_rd_reqs + 1; else d_rd_reqs = d_rd_reqs + 1;
          repeat (40) @(negedge clk);
          if (hslot == 0) a_ack = 1; else d_ack = 1;
          hi = 0; h_state = 3'd1;
        end else if (a_wr || d_wr) begin
          hslot = a_wr ? 0 : 1;
          h_lba = a_wr ? a_lba : d_lba;
          if (a_wr) a_wr_reqs = a_wr_reqs + 1; else d_wr_reqs = d_wr_reqs + 1;
          repeat (40) @(negedge clk);
          if (hslot == 0) a_ack = 1; else d_ack = 1;
          hi = 0; h_state = 3'd2;
        end
      end
      3'd1: begin
        if (hi < hk) begin
          sd_buff_wr = 1;
          sd_buff_addr = hi[12:0];
          sd_buff_dout = host_word(hslot, h_lba + (hi >> 8), hi[7:0]);
          hi = hi + 1;
        end else begin
          a_ack = 0; d_ack = 0; h_state = 3'd0;
        end
      end
      default: begin
        if (hi < 256) begin
          sd_buff_addr = hi[12:0];
          @(negedge clk);
          if (hslot == 0) ovl_a[longint'(h_lba) * 256 + hi] = a_din;
          else            ovl_d[longint'(h_lba) * 256 + hi] = d_din;
          hi = hi + 1;
        end else begin
          a_ack = 0; d_ack = 0; h_state = 3'd0;
        end
      end
    endcase
  end

  // ==== CHECKS ====
  // The guest: port-level task-file accesses, and the named S1..S6 cases below.
  task automatic fail(input [8*120-1:0] m);
    begin
      $display("  FAIL: %0s @ %0t", m, $time);
      errors = errors + 1;
    end
  endtask

  task automatic tf_read(input [15:0] addr, output [7:0] data);
    begin
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 0;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic tf_write(input [15:0] addr, input [7:0] data);
    begin
      io_addr = addr; io_din = data; io_wr = 1;
      @(negedge clk);
      io_wr = 0;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic wait_not_busy(output [7:0] st);
    integer n;
    begin
      n = 0; st = 8'h80;
      while (st[7] && n < 200000) begin tf_read(16'h074C, st); n = n + 1; end
      if (st[7]) fail("BSY never cleared");
    end
  endtask

  task automatic read_word(output [15:0] w);
    reg [7:0] lo, hi8;
    begin
      tf_read(16'h0640, lo);
      tf_read(16'h0641, hi8);
      w = {hi8, lo};
    end
  endtask

  // The bank the one disk answers at (bank 0, the core's fixed layout).
  task automatic select(input dev, input [3:0] lba_hi);
    begin
      tf_write(16'h0432, BANK);
      tf_write(16'h064C, {4'b1110, lba_hi});        // LBA mode, master
    end
  endtask

  // IDENTIFY the selected drive and return the words this bench checks.
  reg [15:0] id_w [0:255];
  task automatic identify(input [8*24-1:0] who);
    reg [7:0] st;
    reg [15:0] w;
    integer i;
    begin
      tf_write(16'h064E, 8'hEC);
      wait_not_busy(st);
      if (!st[3]) fail({who, ": IDENTIFY raised no DRQ"});
      for (i = 0; i < 256; i = i + 1) begin read_word(w); id_w[i] = w; end
      tf_read(16'h064E, st);
    end
  endtask

  // READ SECTORS (LBA) of `count` sectors from the selected drive, checked word by word
  // against image `slot`.
  task automatic read_check(input integer slot, input [31:0] lba, input [7:0] count,
                            input [8*40-1:0] what);
    reg [7:0] st;
    reg [15:0] w;
    integer s, i, bad;
    begin
      bad = 0;
      tf_write(16'h0644, count);
      tf_write(16'h0646, lba[7:0]);
      tf_write(16'h0648, lba[15:8]);
      tf_write(16'h064A, lba[23:16]);
      tf_write(16'h064E, 8'h20);
      for (s = 0; s < count; s = s + 1) begin
        wait_not_busy(st);
        if (!st[3] || st[0]) begin fail({what, ": no DRQ / ERR on a sector"}); s = count; end
        else begin
          for (i = 0; i < 256; i = i + 1) begin
            read_word(w);
            if (w !== img_word(slot, lba + s, i[7:0]) && !(slot == 1 && ovl_d.exists(longint'(lba + s) * 256 + i))) begin
              if (bad == 0)
                $display("    %0s: lba %0d word %0d = %04x, image %0d holds %04x", what, lba + s, i, w,
                         slot, img_word(slot, lba + s, i[7:0]));
              bad = bad + 1;
            end
          end
        end
      end
      tf_read(16'h064E, st);
      if (bad != 0) fail({what, ": sector data is not the selected image's"});
    end
  endtask

  reg [7:0] st, st2;
  integer i, k, irqs;
  reg [15:0] w;
  reg irq_q = 0;
  always @(posedge clk) begin irq_q <= irq; if (irq && !irq_q) irqs = irqs + 1; end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_ATA_LINUX_PROBE: watchdog timeout (no verdict reached)");
  end

  initial begin
    irqs = 0;
    repeat (4) @(negedge clk);
    a_mount = 1; @(negedge clk); a_mount = 0;
    repeat (2) @(negedge clk);
    d_mount = 1; @(negedge clk); d_mount = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (400) @(negedge clk);

    // pc98ide_init: the bank, then SRST with nIEN held, then nIEN alone.
    tf_write(16'h0432, BANK);
    tf_write(16'h074C, 8'h06);
    repeat (50) @(negedge clk);
    tf_write(16'h074C, 8'h02);
    repeat (400) @(negedge clk);

    // ---- L1: unit 0 (0xE0) is found and identified ----
    wait_not_busy(st);
    tf_write(16'h064C, 8'hE0);
    for (i = 0; i < 4; i = i + 1) tf_read(16'h074C, st);
    tf_read(16'h064E, st);
    if (st == 8'h00 || st == 8'hFF) fail("L1 unit 0 reads 0x00/0xFF after its select: the driver would drop it");
    tf_write(16'h064E, 8'hEC);
    tf_read(16'h064E, st);
    if (st == 8'h00) fail("L1 unit 0 reads 0x00 after IDENTIFY");
    wait_not_busy(st);
    if (!st[3]) fail("L1 unit 0 IDENTIFY raised no DRQ");
    for (i = 0; i < 256; i = i + 1) begin read_word(w); id_w[i] = w; end
    if ({id_w[61], id_w[60]} !== CAP_A) fail("L1 unit 0 words 60/61 are not the image's capacity");

    // ---- L2: unit 1 (0xF0) is ABSENT: STATUS and ALTSTATUS read 0x00 ----
    wait_not_busy(st);
    tf_write(16'h064C, 8'hF0);
    for (i = 0; i < 4; i = i + 1) tf_read(16'h074C, st2);
    tf_read(16'h064E, st);
    if (st !== 8'h00) fail("L2 an absent device 1 did not read STATUS 0x00 (the driver registers a phantom unit)");
    if (st2 !== 8'h00) fail("L2 an absent device 1 did not read ALTSTATUS 0x00");

    // ---- L3: a command for the absent device is not executed ----
    k = irqs;
    tf_write(16'h064E, 8'hEC);
    repeat (400) @(negedge clk);
    tf_read(16'h064E, st);
    if (st !== 8'h00) fail("L3 IDENTIFY to the absent device 1 changed its STATUS from 0x00");
    if (irqs != k) fail("L3 IDENTIFY to the absent device 1 raised an interrupt");
    if (ata.xfer_state != 3'd0) fail("L3 IDENTIFY to the absent device 1 started a data phase");

    // ---- L4: EXECUTE DEVICE DIAGNOSTIC is device 0's for the pair, whoever is selected ----
    k = irqs;
    tf_write(16'h074C, 8'h00);         // interrupts enabled for this case
    tf_write(16'h064E, 8'h90);
    repeat (50) @(negedge clk);
    if (irqs == k) fail("L4 EXECUTE DEVICE DIAGNOSTIC with device 1 selected was not executed");
    tf_read(16'h0642, st);
    if (st !== 8'h01) fail("L4 EXECUTE DEVICE DIAGNOSTIC did not leave ERROR 0x01 (device 0 passed, device 1 absent)");
    tf_write(16'h074C, 8'h02);

    // ---- L5: re-selecting device 0 restores the master, data intact ----
    tf_write(16'h064C, 8'hE0);
    tf_read(16'h064E, st);
    if (st !== 8'h50) fail("L5 re-selecting device 0 does not read the master's 0x50");
    tf_write(16'h0432, BANK);
    read_check(0, 32'd100, 8'd2, "L5 the master LBA 100..101");

    if (errors == 0) begin
      // ==== VERDICT ====
      $display("TB_PC9821_ATA_LINUX_PROBE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_ATA_LINUX_PROBE: FAIL (%0d errors)", errors);
  end

endmodule
