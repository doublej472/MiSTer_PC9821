`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDD_WRITE_HPS: a floppy WRITE DATA programmed the way the BIOS programs it - the real uPD71071 (pc9821_dmac) reading the buffer from memory channel 2 memory-to-port, the real pc9821_fdc, pc9821_fdd_media, pc9821_block_share and pc9821_block_io - reaches the image through the REAL framework module sys/hps_io.sv driven over its HPS_BUS by a model of the ARM's own command sequence (the 'h1d/'h1c image mount of slot 2 with a bitmask, the 'h16 status poll, a 'h17 block read and a 'h18 block write reading sd_buff_din at hps_io's own sd_buff_addr post-increment): the 1024-byte sector written to drive 1 lands in slot 2's image byte for byte, every other byte of the image is unchanged, the controller answers NP2kai's success7, and a READ DATA of the same sector brings the written bytes back into memory over the same channel.
//
// WHY THIS EXISTS. The first write-path fit hung a DOS COPY to the floppy on the MiSTer with not
// one byte reaching the image, while tb_pc9821_fdd_write - which models both the DMA engine and the
// host channel - passed. The cause was the memory side of the DMA's memory-to-port direction
// (pc9821_memory_subsystem answered no DMA read; tb_pc9821_dma_accept_steal now pins that), and the
// coordinator's question was whether the HPS side is right too. So here every module between the
// guest's port writes and the ARM's SPI words is the real one; the only models are the memory
// array behind the DMA's bus-master port (an accept, then the word LATENCY cycles later, the
// subsystem's shape) and the ARM itself, whose sequence is written from sys/hps_io.sv's own
// command decoder (the 'h16 status word {1, blk_cnt, BLKSZ, sdn, wr, rd}; 'h17 data words on
// sd_buff_wr with the address post-incremented by b_wr[2]; 'h18 returning sd_buff_din[sdn_ack] at
// the CURRENT sd_buff_addr and then incrementing it; sd_ack set by the command word's disk field and
// cleared when io_enable drops).
//
// Expected values: the controller's result is NP2kai's FDC_WriteData/success7 (io/fdc.c:427-485,
// :120-158: R == EOT -> R = 1, C + 1); a raw sector's file offset is fdd_write_xdf's
// ((treg << 1) + hd) * sectors + R - 1) << (7 + N) (diskimage/fd/fdd_xdf.c:405-410).

// ==== DUT ====
`default_nettype none

module tb_pc9821_fdd_write_hps;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam integer IMG_BYTES = 1261568;          // NP2kai's 154-half-track 8x1024 raw row
  reg [7:0] img [0:IMG_BYTES-1];
  function automatic [7:0] pimg(input integer off);
    pimg = (off * 7 + 3) & 8'hFF;
  endfunction
  function automatic [7:0] pbuf(input integer j);
    pbuf = (j * 29 + 101) & 8'hFF;
  endfunction

  // ==== the guest's memory behind the DMA's bus-master port ====
  // An immediate accept, then the word LATENCY cycles later (pc9821_memory_subsystem's contract:
  // a read owes one response beat, a write none).
  localparam integer LATENCY = 5;
  reg  [7:0]  gmem [0:65535];
  wire [31:0] mem_addr, mem_din;
  wire        mem_we, mem_req;
  wire [3:0]  mem_be;
  reg  [31:0] mem_dout = 32'hA5A5A5A5;
  reg         mem_resp_valid = 0;
  reg  [3:0]  mpend = 0;
  reg  [31:0] mprod;
  wire        macc = mem_req && (mpend == 0);
  wire        mem_ready = macc;
  integer     dma_reads = 0;
  always @(posedge clk) begin
    mem_resp_valid <= 1'b0;
    if (macc) begin
      if (!mem_we) begin
        mprod <= {4{gmem[mem_addr[15:0]]}};
        mpend <= LATENCY[3:0];
        dma_reads <= dma_reads + 1;
      end else begin
        gmem[mem_addr[15:0]] <= mem_din[7:0];
      end
    end else if (mpend != 0) begin
      mpend <= mpend - 4'd1;
      if (mpend == 4'd1) begin
        mem_resp_valid <= 1'b1;
        mem_dout <= mprod;
      end
    end
  end

  // ==== the real uPD71071 ====
  reg        dsel = 0, dwrite = 0;
  reg  [4:0] didx = 0;
  reg  [7:0] ddin = 0;
  wire [3:0] dack;
  wire       dev_we, dev_stb, dev_tc;
  wire [1:0] dev_ch;
  wire [7:0] dev_dout;
  wire [7:0] fdc_dma_out;
  wire       fdc_drq;

  pc9821_dmac u_dma (
    .clk(clk), .reset(reset),
    .sel(dsel), .write(dwrite), .idx(didx), .din(ddin), .dout(), .dout_comb(),
    .dev_drq({1'b0, fdc_drq, 2'b00}), .dev_dack(dack), .dev_we(dev_we), .dev_stb(dev_stb),
    .dev_tc(dev_tc), .dev_ch(dev_ch), .dev_dout(dev_dout), .dev_din(fdc_dma_out),
    .mem_addr(mem_addr), .mem_we(mem_we), .mem_be(mem_be), .mem_din(mem_din),
    .mem_dout(mem_dout), .mem_req(mem_req),
    .mem_ready(mem_ready), .mem_resp_valid(mem_resp_valid), .mem_tc()
  );

  // ==== the real controller and medium ====
  reg        cs = 0, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;
  reg        frame_tick = 0;

  wire [1:0]  fdd_present, fdd_wp, fdd_chg;
  wire        fdd_req, fdd_req_hdr, fdd_adv, fdd_req_wr, fdd_abort;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx, fdd_din;
  wire [7:0] fdd_tc;   // the physical track (pc9821_fdc's media_tc)
  wire       fdd_hd;
  wire       fdd_mf;
  wire       fdd_2hd;
  wire       fdd_rpm;
  wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
  wire [7:0]  fdd_dout, fdd_hr, fdd_hn, fdd_hs;

  pc9821_fdc fdc (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq), .res_done(),
      .media_present({2'b00, fdd_present}), .writeprotect({2'b00, fdd_wp}),
      .media_chg({2'b00, fdd_chg}), .frame_tick(frame_tick),
      .media_req(fdd_req), .media_req_hdr(fdd_req_hdr), .media_unit(fdd_unit),
      .media_c(fdd_c), .media_h(fdd_h), .media_tc(fdd_tc), .media_hd(fdd_hd), .media_mf(fdd_mf), .media_2hd(fdd_2hd), .media_rpm(fdd_rpm), .media_r(fdd_r), .media_n(fdd_n),
      .media_idx(fdd_idx), .media_wr(fdd_req_wr), .media_din(fdd_din), .media_abort(fdd_abort),
      .media_ready(fdd_ready), .media_rdy(fdd_rdy), .media_hdrv(fdd_hdrv),
      .media_err(fdd_err), .media_dout(fdd_dout),
      .media_hr(fdd_hr), .media_hn(fdd_hn), .media_hs(fdd_hs),
      .media_adv(fdd_adv),
      // the strap's channel (2), exactly as pc9821_iobus qualifies it
      .dma_drq(fdc_drq), .dma_dack(dack[2]), .dma_stb(dev_stb && (dev_ch == 2'd2)),
      .dma_tc(dev_tc && (dev_ch == 2'd2)), .dma_dout(fdc_dma_out),
      .dma_we(dev_we), .dma_din(dev_dout),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  // ==== the real framework module ====
  localparam CONF_STR = "Z;;";
  wire [45:0] HPS_BUS;
  wire [35:0] EXT_BUS;
  reg         io_strobe = 0, io_enable = 0;
  reg  [15:0] io_din = 0;
  assign HPS_BUS[31:16] = io_din;
  assign HPS_BUS[33] = io_strobe;
  assign HPS_BUS[34] = io_enable;
  assign HPS_BUS[35] = 1'b0;           // fp_enable
  assign HPS_BUS[45:38] = 8'd0;
  assign EXT_BUS[32] = 1'b0;
  assign EXT_BUS[15:0] = 16'd0;
  wire [15:0] io_dout = HPS_BUS[15:0];

  wire [2:0]  img_mounted;
  wire        img_readonly;
  wire [63:0] img_size;
  wire [31:0] sd_lba [3];
  wire [5:0]  sd_blk_cnt [3];
  wire [2:0]  sd_rd, sd_wr, sd_ack;
  wire [12:0] sd_buff_addr;
  wire [15:0] sd_buff_dout;
  wire [15:0] sd_buff_din [3];
  wire        sd_buff_wr;

  hps_io #(.CONF_STR(CONF_STR), .VDNUM(3), .WIDE(1)) hps (
      .clk_sys(clk), .HPS_BUS(HPS_BUS), .EXT_BUS(EXT_BUS),
      .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
      .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
      .sd_buff_wr(sd_buff_wr)
  );

  wire        blk_rd, blk_wr, blk_busy, blk_done, blk_error, blk_slot;
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr, blk_rd_addr;
  wire [15:0] blk_fill_data, blk_rd_data;

  pc9821_fdd_media media (
      .clk(clk), .reset(reset),
      .img_mounted(img_mounted[1]), .img_size(img_size), .img_readonly(img_readonly),
      .img1_mounted(img_mounted[2]), .img1_size(img_size),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_slot(blk_slot),
      .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .blk_req_wr(blk_wr), .blk_rd_addr(blk_rd_addr), .blk_rd_data(blk_rd_data),
      .present(fdd_present), .writeprotect(fdd_wp), .chg(fdd_chg),
      .req(fdd_req), .req_hdr(fdd_req_hdr), .req_wr(fdd_req_wr), .unit(fdd_unit),
      .req_c(fdd_c), .req_h(fdd_h), .req_tc(fdd_tc), .req_hd(fdd_hd), .req_mf(fdd_mf), .req_2hd(fdd_2hd), .req_rpm(fdd_rpm), .req_r(fdd_r), .req_n(fdd_n), .req_idx(fdd_idx),
      .ready(fdd_ready), .rdy(fdd_rdy), .hdrv(fdd_hdrv), .err(fdd_err),
      .dout(fdd_dout), .adv(fdd_adv), .din(fdd_din), .abort(fdd_abort),
      .hdr_r(fdd_hr), .hdr_n(fdd_hn), .hdr_sects(fdd_hs)
  );

  pc9821_block_share share (
      .clk(clk), .rst_n(!reset),
      .a_img_mounted(img_mounted[0]), .a_img_readonly(img_readonly), .a_img_size(img_size),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(sd_lba[0]), .a_sd_blk_cnt(sd_blk_cnt[0]), .a_sd_rd(sd_rd[0]), .a_sd_wr(sd_wr[0]),
      .a_sd_ack(sd_ack[0]), .a_sd_buff_din(sd_buff_din[0]),
      .b_img_mounted(img_mounted[1]), .b_img_readonly(img_readonly), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_write(blk_wr), .b_req_lba(blk_lba), .b_req_slot(blk_slot),
      .b_req_done(blk_done), .b_req_error(blk_error), .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_buf_rd_addr(blk_rd_addr), .b_buf_rd_data(blk_rd_data),
      .b_sd_lba(sd_lba[1]), .b_sd_blk_cnt(sd_blk_cnt[1]), .b_sd_rd(sd_rd[1]), .b_sd_wr(sd_wr[1]),
      .b_sd_ack(sd_ack[1]), .b_sd_buff_din(sd_buff_din[1]),
      .c_img_mounted(img_mounted[2]), .c_img_readonly(img_readonly), .c_img_size(img_size),
      .c_sd_lba(sd_lba[2]), .c_sd_blk_cnt(sd_blk_cnt[2]), .c_sd_rd(sd_rd[2]), .c_sd_wr(sd_wr[2]),
      .c_sd_ack(sd_ack[2]), .c_sd_buff_din(sd_buff_din[2]),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles()
  );

  // ==== the ARM: Main_MiSTer's side of hps_io's command protocol ====
  // One SPI word = one io_strobe pulse with io_enable held; the gap between strobes is the
  // ARM's (many clk_sys - the strobe is sys_top's synchronised toggle). The reply to a word is
  // io_dout as hps_io registered it at that strobe.
  localparam integer GAP = 6;
  reg arm_busy = 0;
  integer arm_writes = 0, arm_reads = 0;
  task automatic spi_begin;
    begin @(negedge clk); io_enable = 1; repeat (2) @(negedge clk); end
  endtask
  task automatic spi_end;
    begin @(negedge clk); io_enable = 0; repeat (GAP) @(negedge clk); end
  endtask
  task automatic spi_word(input [15:0] w, output [15:0] reply);
    begin
      @(negedge clk); io_din = w; io_strobe = 1;
      @(negedge clk); io_strobe = 0;
      repeat (GAP) @(negedge clk);
      reply = io_dout;
    end
  endtask

  // the image mount: size first ('h1d), then the selection with the slot BITMASK ('h1c)
  task automatic arm_mount(input integer slot, input [63:0] size, input ro);
    reg [15:0] r;
    begin
      arm_busy = 1;
      spi_begin; spi_word(16'h001D, r);
      spi_word(size[15:0], r); spi_word(size[31:16], r); spi_word(size[47:32], r); spi_word(size[63:48], r);
      spi_end;
      spi_begin; spi_word(16'h001C, r); spi_word({8'd0, ro, 7'd0} | (16'd1 << slot), r); spi_end;
      arm_busy = 0;
    end
  endtask

  // one service pass: the status poll, then the transfer it names (slot 2 only is served)
  task automatic arm_service;
    reg [15:0] st, lo, hi, r;
    integer disk, blks, w, base;
    begin
      arm_busy = 1;
      spi_begin; spi_word(16'h0016, st); spi_word(16'h0000, r); spi_word(16'h0000, lo);
      spi_word(16'h0000, hi); spi_end;
      disk = st[5:2];
      blks = st[14:9] + 1;
      if (st[15] && (st[1:0] != 2'b00)) begin
        if (disk != 2) $fatal(1, "TB_PC9821_FDD_WRITE_HPS: a request for slot %0d (only slot 2 is mounted)", disk);
        base = {hi, lo} * 512;
        if (st[0]) begin
          spi_begin; spi_word(16'h0017 | (disk << 8), r);
          for (w = 0; w < blks * 256; w = w + 1)
            spi_word({img[base + 2*w + 1], img[base + 2*w]}, r);
          spi_end;
          arm_reads = arm_reads + 1;
        end else begin
          spi_begin; spi_word(16'h0018 | (disk << 8), r);
          for (w = 0; w < blks * 256; w = w + 1) begin
            spi_word(16'h0000, r);
            img[base + 2*w]     = r[7:0];
            img[base + 2*w + 1] = r[15:8];
          end
          spi_end;
          arm_writes = arm_writes + 1;
        end
      end
      arm_busy = 0;
    end
  endtask

  reg arm_run = 0;
  always begin
    @(negedge clk);
    if (arm_run && !arm_busy) arm_service;
  end

  // the guest's frame (the ready-change insert delay counts frames)
  always begin
    repeat (2000) @(negedge clk);
    frame_tick = 1; @(negedge clk); frame_tick = 0;
  end

  // ==== port helpers ====
  task automatic wr8(input [2:0] a, input [7:0] d);
    begin @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
          @(posedge clk); @(negedge clk); cs = 0; wr = 0; end
  endtask
  reg [7:0] rd_val;
  task automatic rd8(input [2:0] a);
    begin @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1; #1 rd_val = dout;
          @(posedge clk); @(negedge clk); cs = 0; rd = 0; end
  endtask
  task automatic dma_wr(input [4:0] i, input [7:0] d);
    begin @(negedge clk); dsel = 1; dwrite = 1; didx = i; ddin = d;
          @(negedge clk); dsel = 0; dwrite = 0; end
  endtask
  // channel 2, the way the BIOS programs it: mask, clear the flip-flop, mode, address, count
  // (n - 1), bank, unmask (ports 0x15 / 0x19 / 0x17 / 0x09 / 0x0B / 0x23 / 0x15).
  task automatic dma_prog(input [7:0] mode, input [15:0] a, input [15:0] n);
    reg [15:0] nm1;
    begin
      dma_wr(5'd10, 8'h06);              // 0x15: set ch2's mask
      dma_wr(5'd12, 8'h00);              // 0x19: clear the byte flip-flop
      dma_wr(5'd11, mode);               // 0x17: mode
      dma_wr(5'd4, a[7:0]); dma_wr(5'd4, a[15:8]);              // 0x09: ch2 address
      nm1 = n - 16'd1; dma_wr(5'd5, nm1[7:0]); dma_wr(5'd5, nm1[15:8]);   // 0x0B: ch2 count
      dma_wr(5'd17, 8'h00);              // 0x23: ch2 bank
      dma_wr(5'd10, 8'h02);              // 0x15: clear ch2's mask
    end
  endtask

  reg [7:0] rs [0:7];
  integer rlen, i, j, n, fails = 0;
  task automatic get_result;
    begin
      rlen = 0;
      rd8(3'd0);
      while (((rd_val & 8'h40) != 0) && (rlen < 8)) begin
        rd8(3'd1); rs[rlen] = rd_val; rlen = rlen + 1; rd8(3'd0);
      end
    end
  endtask
  task automatic wait_irq(input integer maxc, input [8*40-1:0] what);
    begin
      n = 0;
      while (!irq && n < maxc) begin @(negedge clk); n = n + 1; end
      if (!irq) $fatal(1, "TB_PC9821_FDD_WRITE_HPS: %0s: no interrupt - the command hung (DMA reads %0d, ARM reads %0d, ARM writes %0d, fdc x_st %0d, media st %0d, dma state %0d)",
                       what, dma_reads, arm_reads, arm_writes, fdc.x_st, media.st, u_dma.state);
    end
  endtask
  // THE HEAD IS WHERE THE LAST SEEK LEFT IT. NP2kai reads a sector on the physical track
  // (treg << 1) + hd and only matches the command's C against the header (fdd_d88.c
  // searchsector_d88; READ/WRITE DATA replace treg with C only while it differs from the last
  // SEEK's, io/fdc.c fdc_lasttreg), so - as the BIOS does - a data command for another
  // cylinder is preceded by a SEEK there. The bench seeks only when the drive's track register
  // is not already on the command's C, so every case keeps its own command stream otherwise.
  task automatic seek_to(input [1:0] u, input [7:0] c);
    begin
      if (fdd_present[u[0]] && (u[1] == 1'b0) && (fdc.treg[u] != c)) begin
        wr8(3'd1, 8'h0F); wr8(3'd1, {6'd0, u}); wr8(3'd1, c);
        wait_irq(2000000, "seek before a data command");
        wr8(3'd1, 8'h08);   // SENSE INTERRUPT STATUS: drain the seek's completion
        get_result;
      end
    end
  endtask

  task automatic data_cmd(input [7:0] op, input [7:0] ushd, input [7:0] c, input [7:0] h,
                          input [7:0] r, input [7:0] nn, input [7:0] eot);
    begin
      seek_to(ushd[1:0], c);
      wr8(3'd1, op); wr8(3'd1, ushd); wr8(3'd1, c); wr8(3'd1, h); wr8(3'd1, r);
      wr8(3'd1, nn); wr8(3'd1, eot); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_FDD_WRITE_HPS: watchdog timeout (no verdict reached)");
  end

  integer t0;
  initial begin
    for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = pimg(i);
    for (i = 0; i < 65536; i = i + 1) gmem[i] = 8'h00;
    for (j = 0; j < 1024; j = j + 1) gmem[16'h4000 + j] = pbuf(j);

    reset = 1; repeat (8) @(negedge clk); reset = 0; repeat (8) @(negedge clk);
    arm_run = 1;

    // the hot insert: slot 2 (FDD1, drive 1), writable, through hps_io's own mount commands
    arm_mount(2, IMG_BYTES, 1'b0);
    n = 0;
    while (fdd_present != 2'b10 && n < 2000000) begin @(negedge clk); n = n + 1; end
    if (fdd_present != 2'b10) $fatal(1, "TB_PC9821_FDD_WRITE_HPS: slot 2's image never parsed");
    // the ready change: NR first, then the 20-frame insert delay's AI; drain both
    repeat (50000) @(negedge clk);
    for (i = 0; i < 4; i = i + 1) begin wr8(3'd1, 8'h08); get_result; end
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h01); get_result;
    if ((rs[0] & 8'h60) != 8'h20) begin
      $display("  FAIL: ST3 of drive 1 = %02x, want RDY and no WP", rs[0]); fails = fails + 1;
    end

    // ---- WRITE DATA: drive 1, C=3 H=1 R=2 N=3 EOT=2, 1024 bytes from 0x4000 over channel 2
    dma_prog(8'h4A, 16'h4000, 16'd1024);     // single mode, read transfer (memory -> port), ch2
    data_cmd(8'h45, 8'h05, 8'h03, 8'h01, 8'h02, 8'h03, 8'h02);
    wait_irq(4000000, "WRITE DATA");
    get_result;
    if ((rlen != 7) || (rs[0] != 8'h05) || (rs[1] != 8'h00) || (rs[3] != 8'h04) ||
        (rs[4] != 8'h01) || (rs[5] != 8'h01) || (rs[6] != 8'h03)) begin
      $display("  FAIL: WRITE DATA result %0d bytes %02x %02x %02x %02x %02x %02x %02x, want 05 00 00 04 01 01 03",
               rlen, rs[0], rs[1], rs[2], rs[3], rs[4], rs[5], rs[6]);
      fails = fails + 1;
    end
    repeat (20000) @(negedge clk);
    if (arm_writes != 2) begin
      $display("  FAIL: the ARM served %0d block writes, want 2 (one per 512-byte block of the sector)", arm_writes);
      fails = fails + 1;
    end
    t0 = ((3 * 2 + 1) * 8 + 2 - 1) * 1024;
    n = 0;
    for (i = 0; i < IMG_BYTES; i = i + 1)
      if (img[i] !== (((i >= t0) && (i < t0 + 1024)) ? pbuf(i - t0) : pimg(i))) begin
        if (n < 4) $display("  FAIL: image byte %0d is %02x", i, img[i]);
        n = n + 1;
      end
    if (n != 0) fails = fails + 1;

    // ---- READ DATA of the same sector into 0x8000 over the same channel ----
    dma_prog(8'h46, 16'h8000, 16'd1024);     // single mode, write transfer (port -> memory), ch2
    data_cmd(8'h46, 8'h05, 8'h03, 8'h01, 8'h02, 8'h03, 8'h02);
    wait_irq(4000000, "READ DATA");
    get_result;
    if (rs[0] != 8'h05) begin
      $display("  FAIL: READ DATA ST0 %02x", rs[0]); fails = fails + 1;
    end
    n = 0;
    for (j = 0; j < 1024; j = j + 1) if (gmem[16'h8000 + j] !== pbuf(j)) n = n + 1;
    if (n != 0) begin
      $display("  FAIL: %0d of the 1024 bytes read back differ from the bytes written", n);
      fails = fails + 1;
    end

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_WRITE_HPS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_WRITE_HPS: FAIL (%0d errors)", fails);
  end

endmodule

`default_nettype wire
