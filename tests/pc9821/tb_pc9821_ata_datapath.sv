// tb_pc9821_ata_datapath — the IDE sector data path through the REAL block adapter.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_DATAPATH:
// The IDE sector data path end to end through the real block adapter: a full 512-byte PIO sector read and write are byte-exact against a synthetic disk image, the CHS and LBA28 forms translate to the reference's LBA and the read-ahead presents each sector once, the 16-bit data port assembles the sector word little-endian across 0x640/0x641 while the DRQ/data-phase handshake and the task-file advance follow NP2kai, and the measured per-sector cost is reported in clk_sys and MB/s at the CURRENT class table (IO_MIN_HOLD = 4, a 16-bit data word = 6 clk_sys, so the data phase is 1,536 clk_sys = 16.7 MB/s and a fetch-bound sector is 4,937 = 5.2 MB/s).

// The DUT is the shipped pair: pc9821_ata wired to pc9821_block_io exactly as
// pc9821_system wires them, driven on the guest side through the task-file ports
// and on the host side through an hps_io-shaped block model. Every expectation
// names its reference: NP2kai cbus/ideio.c is primary (read first), qemu
// hw/ide is the cross-check, MAME pc9801.cpp maps 0x640-0x64F as a word region.

module tb_pc9821_ata_datapath;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // ---- guest task-file ports ----
  reg        io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0]  io_din = 0;
  wire [7:0] io_dout;
  wire       irq;
  wire [7:0]  dbg_state;
  wire [31:0] dbg_cmd;

  // ---- hps_io host side ----
  reg         img_mounted = 0, img_readonly = 0;
  reg  [63:0] img_size = 0;
  wire        mounted, readonly;
  wire [31:0] capacity;
  wire [31:0] sd_lba;
  wire        sd_rd, sd_wr;
  reg         sd_ack = 0, sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  wire [15:0] sd_buff_din;
  wire        busy;

  // ---- ATA <-> block adapter ----
  wire        ata_block_read, ata_block_write;
  wire [31:0] ata_block_lba;
  wire        ata_block_done, ata_block_error;
  wire        ata_buf_we;
  wire [7:0]  ata_buf_addr;
  wire [15:0] ata_buf_data;
  wire [7:0]  ata_buf_rd_addr;
  wire [15:0] ata_buf_rd_data;

  // ==== DUT ====
  pc9821_ata ata (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .block_read(ata_block_read), .block_write(ata_block_write),
      .block_lba(ata_block_lba),
      .block_done(ata_block_done), .block_error(ata_block_error),
      .block_buf_we(ata_buf_we), .block_buf_addr(ata_buf_addr),
      .block_buf_data(ata_buf_data),
      .block_rd_addr(ata_buf_rd_addr), .block_rd_data(ata_buf_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd)
  );

  pc9821_block_io block_io (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .req_read(ata_block_read), .req_write(ata_block_write), .req_lba(ata_block_lba),
      // The sole owner of its engine: the window is its own, and a mount replaces the image
      // the window's blocks came from (pc9821_block_io's header).
      .req_window(1'b1), .win_flush(img_mounted),
      .req_done(ata_block_done), .req_error(ata_block_error),
      .buf_we(ata_buf_we), .buf_addr(ata_buf_addr), .buf_data(ata_buf_data),
      .buf_rd_addr(ata_buf_rd_addr), .buf_rd_data(ata_buf_rd_data),
      .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
      .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .busy(busy)
  );

  integer errors = 0, cases = 0, waivers = 0;
  reg [7:0] value, lo, hi;
  reg [15:0] word_value;
  integer n, i, s;

  // ==== STIMULUS ====
  // The synthetic disk image: byte n of sector L is a function of both, so a
  // buffer filled with the wrong sector, or shifted by one byte, is a byte
  // mismatch. The host synthesizes it; the guest is compared against it.
  function [7:0] image_byte(input [31:0] lba, input [7:0] n);
    image_byte = (lba[7:0] + n * 32'd7 + 8'h5A) & 8'hFF;
  endfunction

  function [15:0] image_word(input [31:0] lba, input [7:0] idx);
    image_word = {image_byte(lba, {idx[6:0], 1'b1}), image_byte(lba, {idx[6:0], 1'b0})};
  endfunction

  // A reference case: NP2kai's answer is the expectation. A different byte prints
  // the exact case and counts as a mismatch.
  task automatic check(input [8*44-1:0] name, input [31:0] got, input [31:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%08x np2kai=0x%08x", name, got, want);
        errors = errors + 1;
      end else $display("ok       %0s = 0x%08x", name, got);
    end
  endtask

  task automatic fail(input [8*64-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // A documented divergence from the primary reference: the case is printed and counted, but
  // not asserted, because the module boundary cannot carry the distinction it tests (see the
  // byte-read waiver below).
  task automatic waive(input [8*44-1:0] name, input [31:0] got, input [31:0] np2kai);
    begin
      cases   = cases + 1;
      waivers = waivers + 1;
      $display("WAIVED   %0s: rtl=0x%08x np2kai=0x%08x (documented)", name, got, np2kai);
    end
  endtask

  task automatic write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  // The guest's 16-bit data-register access: the machine's I/O bus walks the two
  // byte lanes low (0x640) then high (0x641), which is what a `in ax, 0x640` does.
  task automatic read_word(output [15:0] data);
    reg [7:0] l, h;
    begin
      read_byte(16'h0640, l);
      read_byte(16'h0641, h);
      data = {h, l};
    end
  endtask

  task automatic write_word(input [15:0] data);
    begin
      write_byte(16'h0640, data[7:0]);
      write_byte(16'h0641, data[15:8]);
    end
  endtask

  // The same word access with the CURRENT I/O class: iobus charges 0x0640/0x0641
  // IO_MIN_HOLD = 4 per access (pc9821_iobus.sv), and a 16-bit word is ONE
  // access that walks two lanes, so the word costs 6 clk_sys -- measured through the real
  // bus by tb_pc9821_ata_iowait (6 delivered, 5 of them stalled). 28 here was an earlier
  // superseded class 30 and made every throughput figure 5x pessimistic.
  localparam PIO_GAP = 2;
  task automatic read_word_class(output [15:0] data);
    reg [7:0] l, h;
    begin
      read_byte(16'h0640, l);
      read_byte(16'h0641, h);
      data = {h, l};
      repeat (PIO_GAP) @(posedge clk);
    end
  endtask

  task automatic set_lba28(input [31:0] lba, input [7:0] count);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h0646, lba[7:0]);
      write_byte(16'h0648, lba[15:8]);
      write_byte(16'h064A, lba[23:16]);
      write_byte(16'h064C, 8'hE0 | lba[27:24]);
    end
  endtask

  task automatic set_chs(input [15:0] cy, input [3:0] hd, input [7:0] sn,
                         input [7:0] count);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h0646, sn);
      write_byte(16'h0648, cy[7:0]);
      write_byte(16'h064A, cy[15:8]);
      write_byte(16'h064C, 8'hA0 | hd);
    end
  endtask

  // Poll the ALTERNATE status so the poll does not acknowledge the IRQ: the
  // pending-interrupt cases need that latch intact.
  task automatic wait_drq;
    begin
      n = 0;
      read_byte(16'h074C, value);
      while (!value[3] && n < 200000) begin
        read_byte(16'h074C, value);
        n = n + 1;
      end
      if (!value[3]) fail("DRQ timeout");
    end
  endtask

  task automatic wait_idle;
    begin
      n = 0;
      while (ata.xfer_state !== 3'd0 && n < 200000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (ata.xfer_state !== 3'd0) fail("transfer did not return to X_IDLE");
    end
  endtask

  task automatic settle;
    begin
      wait_idle;
      read_byte(16'h064E, value);   // acknowledge any pending IRQ
    end
  endtask

  // Guest-side drain of one sector; every word is compared byte-exact to the
  // synthetic image. A wrong sector, a one-word shift or a byte swap all count.
  integer data_bad = 0;
  integer cycle = 0;
  always @(posedge clk) cycle = cycle + 1;
  task automatic read_one_sector(input [31:0] lba);
    reg [7:0] l, h; reg [15:0] got;
    begin
      wait_drq;
      for (i = 0; i < 256; i = i + 1) begin
        read_byte(16'h0640, l);
        read_byte(16'h0641, h);
        got = {h, l};
        if (got !== image_word(lba, i[7:0])) begin
          if (data_bad < 4)
            $display("DATA MISMATCH lba=%08x word=%0d got=%04x want=%04x",
                     lba, i, got, image_word(lba, i[7:0]));
          data_bad = data_bad + 1;
        end
      end
    end
  endtask

  // The host side of pc9821_block_io: an hps_io-shaped SD transaction. SD_LAT is
  // the card's own latency before the 256-word burst, exactly the round trip the
  // machine pays; the guest's word class is modelled above.
  integer SD_LAT = 0;
  localparam HS_IDLE = 0, HS_LAT = 1, HS_READ = 2, HS_WRITE = 3;
  integer host_state = HS_IDLE;
  integer host_wait = 0;
  integer host_addr = 0;
  integer host_lba = 0;
  integer host_is_write = 0;
  integer host_reads = 0, host_writes = 0;
  integer write_bad = 0;
  integer last_req_lba = 0;
  integer host_short = 0;
  reg     sd_abort_next = 0;

  always @(negedge clk) begin
    sd_buff_wr = 0;
    case (host_state)
      HS_IDLE: begin
        sd_ack = 0;
        if (sd_rd || sd_wr) begin
          host_lba  = sd_lba;
          last_req_lba = sd_lba;
          host_is_write = sd_wr;
          host_short = sd_abort_next;
          sd_abort_next = 0;
          host_wait = SD_LAT;
          host_addr = 0;
          host_state = HS_LAT;
          if (sd_wr) host_writes = host_writes + 1;
          else       host_reads  = host_reads  + 1;
        end
      end
      HS_LAT: begin
        if (host_wait > 0) host_wait = host_wait - 1;
        else begin
          sd_ack = 1;
          host_addr = 0;
          host_state = host_is_write ? HS_WRITE : HS_READ;
        end
      end
      HS_READ: begin
        sd_buff_wr   = 1;
        sd_buff_addr = host_addr[12:0];
        sd_buff_dout = image_word(host_lba[31:0], host_addr[7:0]);
        if (host_short && host_addr == 2) host_state = HS_IDLE;  // short block -> req_error
        else if (host_addr == 255) host_state = HS_IDLE;
        else host_addr = host_addr + 1;
      end
      HS_WRITE: begin
        // sd_buff_din follows sd_buff_addr combinationally; sample the address
        // presented last cycle before advancing.
        if (host_addr > 0) begin
          if (sd_buff_din !== image_word(host_lba[31:0], (host_addr - 1) & 255))
            write_bad = write_bad + 1;
        end
        sd_buff_addr = host_addr[12:0];
        if (host_addr == 256) host_state = HS_IDLE;
        else host_addr = host_addr + 1;
      end
    endcase
  end

  task automatic mount(input [63:0] bytes, input ro);
    begin
      @(negedge clk);
      img_size = bytes; img_readonly = ro; img_mounted = 1;
      @(posedge clk);
      @(negedge clk);
      img_mounted = 0;
      repeat (4) @(posedge clk);
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    // 200000 sectors of image so every LBA below is in range.
    mount(64'd200000 * 64'd512, 1'b0);
    while (ata.current_cylinders !== 16'd1470) @(negedge clk);
    write_byte(16'h0432, 8'h00);           // the bank the built-in interface is on

    // ---- (a) full 512-byte PIO sector read, byte-exact ----
    // READ SECTORS (NP2kai ideio_o64e case 0x20 -> readsec) presents the sector the
    // task file names; ideio_r16 hands back buf[0..511] two bytes at a time.
    set_lba28(32'h00001234, 8'h01);
    write_byte(16'h064E, 8'h20);
    check("read_command_status_bsy", ata.status_reg, 8'h80);
    read_one_sector(32'h00001234);
    check("read_sector_byte_exact", data_bad, 0);
    check("read_final_status", ata.status_reg, 8'h50);
    check("read_final_drq_clear", ata.status_reg[3], 1'b0);
    check("read_final_sector_count", ata.sector_count, 8'h00);
    check("read_block_lba", last_req_lba, 32'h00001234);
    settle;

    // ---- (a) full 512-byte PIO sector write, byte-exact ----
    // WRITE SECTORS (case 0x30 -> writeinit); ideio_w16 stores the guest's two
    // bytes and hands the buffer to the card at the last word.
    write_bad = 0;
    set_lba28(32'h00002000, 8'h01);
    write_byte(16'h064E, 8'h30);
    check("write_command_status_drq", ata.status_reg, 8'h58);
    wait_drq;
    for (i = 0; i < 256; i = i + 1) write_word(image_word(32'h00002000, i[7:0]));
    wait_idle;
    check("write_sector_byte_exact", write_bad, 0);
    check("write_final_status", ata.status_reg, 8'h50);
    check("write_final_sector_count", ata.sector_count, 8'h00);
    check("write_host_writes", host_writes >= 1 ? 1 : 0, 1);
    settle;

    // ---- (b) CHS translation: NP2kai getcursec = (cy*surfaces + hd)*sectors + sn-1 ----
    // Default geometry is the platform's 8 heads x 17 sectors. The LBA the card is
    // asked for is checked after the request is in flight, since the request rides
    // block_read -> pc9821_block_io -> sd_lba in the cycle after the command.
    set_chs(16'd0, 4'd0, 8'd1, 8'h01);  write_byte(16'h064E, 8'h20);
    read_one_sector(32'd0);
    check("chs_0_0_1_lba", last_req_lba, 32'd0);
    settle;

    set_chs(16'd1, 4'd2, 8'd3, 8'h01);  write_byte(16'h064E, 8'h20);
    read_one_sector(32'd172);
    check("chs_1_2_3_lba", last_req_lba, 32'd172);
    settle;

    set_chs(16'd2, 4'd7, 8'd17, 8'h01); write_byte(16'h064E, 8'h20);
    read_one_sector(32'd407);
    check("chs_2_7_17_lba", last_req_lba, 32'd407);
    settle;

    set_chs(16'd5, 4'd3, 8'd9, 8'h01);  write_byte(16'h064E, 8'h20);
    read_one_sector(32'd739);
    check("chs_5_3_9_lba", last_req_lba, 32'd739);
    settle;

    // ---- (b) LBA28: {0, head[3:0], cy, sn} (NP2kai getcursec LBA branch) ----
    set_lba28(32'h00000005, 8'h01); write_byte(16'h064E, 8'h20);
    read_one_sector(32'd5);
    check("lba28_5_lba", last_req_lba, 32'd5);
    settle;

    set_lba28(32'h00012345, 8'h01); write_byte(16'h064E, 8'h20);
    read_one_sector(32'h00012345);
    check("lba28_12345_lba", last_req_lba, 32'h00012345);
    settle;

    // ---- (b) INITIALIZE DEVICE PARAMETERS adopts the requested geometry ----
    // NP2kai case 0x91 stores surfaces = hd + 1, sectors = sc; the CHS translation
    // must follow the adopted geometry, not the power-on one.
    write_byte(16'h0644, 8'd17);
    write_byte(16'h064C, 8'hA3);          // heads - 1 = 3
    write_byte(16'h064E, 8'h91);
    set_chs(16'd1, 4'd1, 8'd1, 8'h01); write_byte(16'h064E, 8'h20);
    read_one_sector(32'd85);
    check("idp_adopted_chs_lba", last_req_lba, 32'd85);
    settle;
    // restore the platform geometry
    write_byte(16'h0644, 8'd17);
    write_byte(16'h064C, 8'hA7);
    write_byte(16'h064E, 8'h91); settle;

    // ---- (b) 16-bit vs 8-bit PIO ----
    // A word access is low (0x640) then high (0x641) and must assemble the sector
    // word little-endian. NP2kai attaches only the 16-bit handlers (ideio_w16/
    // ideio_r16); a byte read at 0x640/0x641 falls through to definp8 = 0xFF. qemu
    // registers an 8-bit handler that returns ide_data_readw & 0xff, i.e. the LOW
    // byte, and advances a whole word. MAME maps 0x640-0x64F as one word region.
    data_bad = 0;
    set_lba28(32'h00003000, 8'h01); write_byte(16'h064E, 8'h20); wait_drq;
    read_byte(16'h0640, lo);                       // low byte of word 0
    read_byte(16'h0640, hi);                       // 0x640 again: must NOT advance
    check("pio_word0_low_byte", lo, image_byte(32'h3000, 8'd0));
    check("pio_640_does_not_advance", hi, lo);
    read_byte(16'h0641, hi);                       // high byte of word 0, advances
    check("pio_word0_high_byte", hi, image_byte(32'h3000, 8'd1));
    read_byte(16'h0640, lo);                       // now word 1's low byte
    check("pio_641_advances_word", lo, image_byte(32'h3000, 8'd2));
    // Drain the rest of the sector from the bytes just presented (words 1..255).
    for (i = 0; i < 255; i = i + 1) begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      word_value = {hi, lo};
      if (word_value !== image_word(32'h3000, (i + 1) & 255)) data_bad = data_bad + 1;
    end
    check("pio_byte_path_sector_exact", data_bad, 0);
    settle;

    // A BARE byte read of the data register with DRQ set. NP2kai attaches only the 16-bit
    // handlers, so a byte read of 0x640/0x641 falls through to definp8 = 0xFF. WAIVED here:
    // the module boundary carries no word/byte distinction (rs/addr/din/dout only), so the
    // one-address byte read the word path uses is indistinguishable from a lone byte read.
    // The real distinction is the iobus's - a lone 0x640 lane is open bus, a two-lane word is
    // the serialized data port - and the byte-serialized word path is pinned by ata_regs,
    // ata_conform and ata_readahead. Asserting 0xFF here would break all three.
    set_lba28(32'h00003001, 8'h01); write_byte(16'h064E, 8'h20); wait_drq;
    read_byte(16'h0640, lo);
    waive("data_byte_read_640", lo, 8'hFF);        // NP2kai definp8
    read_byte(16'h0641, hi);
    waive("data_byte_read_641", hi, 8'hFF);        // NP2kai definp8
    for (i = 0; i < 255; i = i + 1) begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
    end
    settle;

    // ---- (c) DRQ / data-phase handshake and the pending IRQ ----
    // readsec raises the interrupt when the data is READY (sector start), and only
    // a 0x064E read calls pic_resetirq; the end of the transfer does not lower it.
    set_lba28(32'h00004000, 8'h01);
    read_byte(16'h064E, value);                   // clear anything pending first
    write_byte(16'h064E, 8'h20);
    check("read_irq_at_data_ready_pending", {31'b0, irq}, 32'd0);  // BSY first
    wait_drq;
    check("read_irq_at_data_ready", {31'b0, irq}, 32'd1);
    check("read_drq_status", ata.status_reg, 8'h58);
    for (i = 0; i < 256; i = i + 1) begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
    end
    // NP2kai: the interrupt readsec raised is STILL pending until 0x064E is read.
    check("read_irq_pending_after_last_word", {31'b0, irq}, 32'd1);
    check("read_status_after_last_word", ata.status_reg, 8'h50);
    read_byte(16'h064E, value);                   // acknowledge it
    check("read_status_read_clears_irq", {31'b0, irq}, 32'd0);
    settle;

    // The IDENTIFY data phase has the same shape: NP2kai setidentify + setintr, and
    // ideio_r16's 0xEC completion only clears DRQ.
    read_byte(16'h064E, value);
    write_byte(16'h064C, 8'hA0);
    write_byte(16'h064E, 8'hEC); wait_drq;
    check("identify_irq_at_data_ready", {31'b0, irq}, 32'd1);
    for (i = 0; i < 256; i = i + 1) read_word(word_value);
    check("identify_irq_pending_after_last_word", {31'b0, irq}, 32'd1);
    read_byte(16'h064E, value);
    settle;

    // Write data phase: writeinit sets DRDY|DSC|DRQ with NO interrupt; the card
    // raises one per completed sector (writesec / setintr at the last word).
    read_byte(16'h064E, value);
    set_lba28(32'h00005000, 8'h01);
    write_byte(16'h064E, 8'h30);
    check("write_drq_at_command", ata.status_reg, 8'h58);
    check("write_no_irq_at_command", {31'b0, irq}, 32'd0);
    wait_drq;
    for (i = 0; i < 256; i = i + 1) write_word(image_word(32'h00005000, i[7:0]));
    wait_idle;
    check("write_irq_at_completion", {31'b0, irq}, 32'd1);
    check("write_status_read_clears_irq_after", ata.status_reg, 8'h50);
    settle;

    // A data read DURING a write data phase. Both references answer 0: NP2kai
    // ideio_r16 requires `drv->bufdir == IDEDIR_IN`, qemu ide_data_readw requires
    // ide_is_pio_out. The core answers the sector buffer's current word.
    set_lba28(32'h00005001, 8'h01);
    write_byte(16'h064E, 8'h30); wait_drq;
    write_word(image_word(32'h00005001, 8'd0));
    read_byte(16'h0640, lo);
    read_byte(16'h0641, hi);
    check("data_read_during_write", {hi, lo}, 16'h0000);
    for (i = 1; i < 256; i = i + 1) write_word(image_word(32'h00005001, i[7:0]));
    wait_idle;
    check("data_read_during_write_undisturbed", write_bad, 0);
    settle;

    // ---- (b) read-ahead across a multi-sector READ SECTORS ----
    // 3 sectors: the card sees one request per LBA in order, each sector's data is
    // byte-exact, and exactly one interrupt is raised per sector.
    data_bad = 0; host_reads = 0;
    set_lba28(32'h00006000, 8'h03);
    write_byte(16'h064E, 8'h20);
    for (s = 0; s < 3; s = s + 1) begin
      read_one_sector(32'h00006000 + s);
      read_byte(16'h064E, value);                // one IRQ per sector
    end
    check("multi_read_byte_exact", data_bad, 0);
    check("multi_read_requests", host_reads, 3);
    check("multi_read_final_status", ata.status_reg, 8'h50);
    check("multi_read_sector_count", ata.sector_count, 8'h00);
    settle;

    // ---- (b) the task-file address advances as each sector transfers (incsec) ----
    // NP2kai incsec() (cbus/ideio.c) after the last word of the sector: drv->sn++ in
    // LBA mode, the sn/hd/cy carry in CHS mode.
    set_lba28(32'h00000005, 8'h01);
    write_byte(16'h064E, 8'h20); read_one_sector(32'd5);
    check("read_advances_lba_sector", ata.sector_number, 8'h06);
    settle;

    set_lba28(32'h00000020, 8'h01);
    write_byte(16'h064E, 8'h30); wait_drq;
    for (i = 0; i < 256; i = i + 1) write_word(image_word(32'h20, i[7:0]));
    wait_idle;
    check("write_advances_lba_sector", ata.sector_number, 8'h21);
    settle;

    // CHS carry: a read at sector 17, head 7, cylinder 1 (LBA 271) rolls to 1/0/2.
    set_chs(16'd1, 4'd7, 8'd17, 8'h01);
    write_byte(16'h064E, 8'h20); read_one_sector(32'd271);
    check("chs_advance_sector", ata.sector_number, 8'h01);
    check("chs_advance_head", {4'b0, ata.drive_head[3:0]}, 4'd0);
    check("chs_advance_cylinder", {8'b0, ata.cylinder_low}, 32'd2);
    settle;

    // ---- (a)/(c) a failed block read aborts the command ----
    // NP2kai readsec's read_err -> cmdabort: status DRDY|ERR (0x41), error ABRT.
    // A short block makes the real adapter complete with req_error.
    sd_abort_next = 1;
    set_lba28(32'h00007000, 8'h01);
    write_byte(16'h064E, 8'h20);
    wait_idle;
    check("block_error_abort_status", ata.status_reg, 8'h41);
    check("block_error_abort_error", ata.error_reg, 8'h04);
    settle;

    // ---- (d) THROUGHPUT ----
    // The machine's own budget: a 16-bit word costs the current class table's 6 clk_sys on
    // the data port (1,536 clk_sys per sector), and the HPS round trip costs the measured
    // ~4600 cycles before the burst.
    // The measured figure is the sector cost at 50 MHz, so MB/s is 512*50/cycles.
    begin : throughput
      integer t0, t1, elapsed, per_sector_x100, mbps_x100;
      integer one_cycles, one_mbps_x100;
      data_bad = 0;
      SD_LAT = 4600;

      // One sector: the round trip is fully exposed (no read-ahead).
      set_lba28(32'h00008000, 8'h01);
      t0 = cycle;
      write_byte(16'h064E, 8'h20);
      wait_drq;
      for (i = 0; i < 256; i = i + 1) read_word_class(word_value);
      wait_idle;
      t1 = cycle;
      one_cycles = t1 - t0;
      one_mbps_x100 = (512 * 50 * 100) / one_cycles;
      $display("THROUGHPUT single_sector cycles=%0d MB/s=%0.2f",
               one_cycles, one_mbps_x100 / 100.0);
      settle;

      // 16 sectors: the read-ahead overlaps sector N+1's fetch with sector N's
      // drain, so the per-sector cost is the drain, not drain + round trip.
      set_lba28(32'h00009000, 8'd16);
      t0 = cycle;
      write_byte(16'h064E, 8'h20);
      for (s = 0; s < 16; s = s + 1) begin
        wait_drq;
        read_byte(16'h064E, value);
        for (i = 0; i < 256; i = i + 1) begin
          read_word_class(word_value);
          if (word_value !== image_word(32'h9000 + s, i[7:0])) begin
            if (data_bad < 4)
              $display("RA MISMATCH s=%0d word=%0d got=%04x want=%04x host_lba=%08x",
                       s, i, word_value, image_word(32'h9000 + s, i[7:0]), last_req_lba);
            data_bad = data_bad + 1;
          end
        end
      end
      wait_idle;
      t1 = cycle;
      elapsed = t1 - t0;
      per_sector_x100 = (elapsed * 100) / 16;
      mbps_x100 = (16 * 512 * 50 * 100) / elapsed;
      $display("THROUGHPUT readahead sectors=16 cycles=%0d per_sector=%0.2f MB/s=%0.2f",
               elapsed, per_sector_x100 / 100.0, mbps_x100 / 100.0);
      $display("THROUGHPUT model word_cycles=6 HPS_latency=%0d", SD_LAT);
      check("readahead_byte_exact", data_bad, 0);
      if (mbps_x100 < 250)
        fail("16-sector throughput below 2.5 MB/s: the read-ahead is not hiding the fetch");
      settle;
    end

    // ==== VERDICT ====
    $display("NOTE ata_datapath: %0d cases, %0d mismatched, %0d waived", cases, errors, waivers);
    if (errors == 0) begin
      $display("TB_PC9821_ATA_DATAPATH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_DATAPATH: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_ATA_DATAPATH: TIMEOUT");
  end

endmodule
