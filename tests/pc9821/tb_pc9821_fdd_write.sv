`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDD_WRITE: WRITE DATA reaches the floppy image end to end through the real pc9821_fdc, pc9821_fdd_media, pc9821_block_share and pc9821_block_io: a raw-image sector written over DMA lands at its raw offset and reads back through READ DATA, a multi-sector write walks R to EOT and answers NP2kai's FDC_WriteData result (R=1, C+1), a D88 sector that straddles three host blocks or starts on an odd byte rewrites only its own bytes (the read-modify-write keeps every neighbouring header and sector), a D88 sector whose stored size is short stores only its stored bytes, a missing sector takes its bytes and then answers IC0|ND, a protected medium (D88 header bit 4 or a read-only mount) answers IC0|NW with no byte moved and reports ST3 WP, a terminal count inside a sector still completes and answers, a write whose image is swapped before the host takes it is withdrawn (from the engine or from the shared queue) so no byte of it reaches the new image, an ejected drive refuses a write with no host write at all, a PIO write that polls RQM loses no byte while a block is in flight, a raw write whose EOT is past the track takes its bytes and answers IC0|ND, a READ ended by a terminal count inside a sector and a DOR reset in the middle of a read or a write leave the drive serving the next command (a reset write leaves its sector unchanged), a raw FORMAT fills the head's track with D and answers at once with no ID byte taken, and a D88 FORMAT answers IC0|NW with the image untouched.
//
// WHERE THE EXPECTED VALUES COME FROM (never from this RTL):
//   * the controller's answers are NP2kai io/fdc.c's FDC_WriteData (:427-485) and
//     writesector (:394-425), verbatim: FDC_DriveCheck(TRUE) answers a protected medium with
//     ST0 IC0|NW|hd<<2|us and ST1 NW = 0x02 before any byte is taken (:175-193); a sector's
//     128 << N bytes are taken BEFORE fdd_write() looks it up, so a missing sector moves its
//     bytes and then answers ST0 IC0|ND|hd<<2|us, ST1 ND = 0x04 (:400-403); after each sector
//     `if ((fdc.tc) || (fdc.R++ == fdc.eot)) { fdc.R = 1; ... fdc.C++; fdcsend_success7(); }`,
//     and success7 is {hd<<2|us, 0, 0, C, H, R, N} (:120-158). ST3's WP is the medium's own
//     protect flag (FDC_SenseDeviceStatus, :370-372).
//   * WHERE A SECTOR'S BYTES LIVE IN THE FILE is the image format's own layout, the one the read
//     benches already pin: a raw body's sector is at ((((C*2+H) * sects) + R-1) << (7+N)), and a
//     D88 sector's data follows its 16-byte _D88SEC header with `size` bytes stored (the read
//     returns min(128 << N, size) file bytes and zeroes after). A WRITE of a sector stores into
//     exactly the bytes the READ of it returns from the file - the bytes past the stored size
//     have no home in the file. NP2kai's fdd_write_d88/fdd_write_xdf (diskimage/fd/) were not
//     consulted, so that one reading is the format's (an open question).
//   * the D88 header's protect byte is 0x1A, bit 4 (NP2kai fdd_head_d88.h `UINT8 protect;
//     // Write Protect bit:4`, the same field Stage A parses).
//
// THE HOST SIDE is a model of the MiSTer block channel for all three slots: a read handshake
// streams (sd_blk_cnt+1)*256 words in at one per clock, a WRITE handshake reads 256 words out
// of sd_buff_din at sd_buff_addr (sampled two clocks after the address moves - hps_io samples it
// at an SPI strobe many clocks apart, sys/hps_io.sv 'h18), and whichever slot's request is
// presented is served from THAT slot's image, so a block written to the wrong slot or the wrong
// image is a byte mismatch. `host_hold` makes the ARM late: requests stay presented and are not
// acknowledged, which is what opens the swap windows below.
//
// TC is coincident with the final strobe, exactly pc9821_dmac's S_DEV (the same model
// tb_pc9821_fdc_read uses). Every arm whose result depends on the TC/last-byte ordering ends its
// walk at EOT on its last sector, where NP2kai's two orderings give the same answer.
//
// ==== DUT ====
`define IMGMAX 1261568

module tb_pc9821_fdd_write;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== the images ====
  // A (drive 0, slot B): RAW 2HD, NP2kai's 154-half-track 8x1024 row (1,261,568 bytes).
  localparam integer RAW_BYTES = 1261568;
  // N (the image swapped into slot B mid-write): the same geometry, its own pattern.
  // D (drive 1, slot C): a D88 laid out so its sectors straddle host blocks:
  //   track 0 at 0x2B0: R1 N3 size 1024 (data 704..1727 = blocks 1,2,3), R2 N3 STORED 512
  //   (data 1744..2255), R3 N3 size 1024 (data 2272..3295);
  //   track 1 at the ODD offset 3297: R1 N1 256 (data 3313..3568, odd start), R2 N1 256.
  localparam integer D_T0  = 688;
  localparam integer D_T1  = 3297;
  localparam integer D_END = D_T1 + 16 + 256 + 16 + 256;   // 3841, not a multiple of 512
  localparam integer D_SPAN = 4096;                         // the host blocks it occupies

  reg [7:0] imgA [0:`IMGMAX-1];
  reg [7:0] imgN [0:`IMGMAX-1];
  reg [7:0] imgD [0:D_SPAN-1];
  // H (drive 1's last remount): RAW 1.44 MB, NP2kai's HD4 row (160 half-tracks x 18 x 512) -
  // the size of a Policenauts user disk - so the 512-byte, block-aligned sector shape
  // and an MT write across both heads are covered too.
  localparam integer HD4_BYTES = 1474560;
  reg [7:0] imgH [0:HD4_BYTES-1];
  reg [7:0] expH [0:HD4_BYTES-1];
  reg       c_is_hd4 = 0;
  reg [7:0] expA [0:`IMGMAX-1];   // what imgA must hold
  reg [7:0] expD [0:D_SPAN-1];

  function automatic [7:0] praw(input integer off);
    praw = (off * 3 + 7) & 8'hFF;
  endfunction
  function automatic [7:0] pnew(input integer off);
    pnew = (off * 5 + 91) & 8'hFF;
  endfunction
  function automatic [7:0] pd88(input integer off);
    pd88 = (off * 11 + 1) & 8'hFF;
  endfunction
  // the bytes a write sends: distinct per arm (`seed`) and per position
  function automatic [7:0] pw(input integer seed, input integer j);
    pw = (j * 13 + seed * 37 + 5) & 8'hFF;
  endfunction

  integer i, j, n;

  task automatic put_hdr(input integer off, input [7:0] c, h, r, nn,
                         input integer nsec, input integer size);
    begin
      imgD[off+0] = c; imgD[off+1] = h; imgD[off+2] = r; imgD[off+3] = nn;
      imgD[off+4] = nsec[7:0]; imgD[off+5] = nsec[15:8];
      imgD[off+6] = 8'h00; imgD[off+7] = 8'h00; imgD[off+8] = 8'h00;
      for (j = 9; j < 14; j = j + 1) imgD[off+j] = 8'h00;
      imgD[off+14] = size[7:0]; imgD[off+15] = size[15:8];
    end
  endtask

  task automatic build_d88(input [7:0] protect);
    begin
      for (i = 0; i < D_SPAN; i = i + 1) imgD[i] = pd88(i);
      for (i = 0; i < 688; i = i + 1) imgD[i] = 8'h00;
      imgD[8'h1A] = protect;
      imgD[8'h1B] = 8'h20;                                  // 2HD (fddfile.h DISKTYPE_2HD = 2)
      imgD[8'h1C] = D_END[7:0];   imgD[8'h1D] = D_END[15:8];
      imgD[8'h1E] = 8'h00;        imgD[8'h1F] = 8'h00;
      imgD[8'h20] = D_T0[7:0];    imgD[8'h21] = D_T0[15:8];   // trackp[0]
      imgD[8'h24] = D_T1[7:0];    imgD[8'h25] = D_T1[15:8];   // trackp[1]
      put_hdr(688,  8'h00, 8'h00, 8'h01, 8'h03, 3, 1024);
      put_hdr(1728, 8'h00, 8'h00, 8'h02, 8'h03, 3, 512);
      put_hdr(2256, 8'h00, 8'h00, 8'h03, 8'h03, 3, 1024);
      put_hdr(3297, 8'h00, 8'h01, 8'h01, 8'h01, 2, 256);
      put_hdr(3569, 8'h00, 8'h01, 8'h02, 8'h01, 2, 256);
      for (i = 0; i < D_SPAN; i = i + 1) expD[i] = imgD[i];
    end
  endtask

  task automatic build_raw;
    begin
      for (i = 0; i < RAW_BYTES; i = i + 1) begin imgA[i] = praw(i); expA[i] = praw(i); end
    end
  endtask
  task automatic build_new;
    begin
      for (i = 0; i < RAW_BYTES; i = i + 1) imgN[i] = pnew(i);
    end
  endtask

  // ==== DUT: the real controller, the real medium, the real shared adapter ====
  reg        cs = 0, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;

  wire [1:0]  fdd_present, fdd_wp;
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

  wire        blk_rd, blk_wr, blk_busy, blk_done, blk_error, blk_slot;
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr, blk_rd_addr;
  wire [15:0] blk_fill_data, blk_rd_data;
  wire [31:0] dbg_hps_cycles;

  wire        dma_drq;
  reg         dma_dack = 0, dma_stb = 0, dma_tc = 0, dma_we = 0;
  reg  [7:0]  dma_din = 0;
  wire [7:0]  dma_dout;

  pc9821_fdc fdc (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq), .res_done(),
      .media_present({2'b00, fdd_present}), .writeprotect({2'b00, fdd_wp}),
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(fdd_req), .media_req_hdr(fdd_req_hdr), .media_unit(fdd_unit),
      .media_c(fdd_c), .media_h(fdd_h), .media_tc(fdd_tc), .media_hd(fdd_hd), .media_mf(fdd_mf), .media_2hd(fdd_2hd), .media_rpm(fdd_rpm), .media_r(fdd_r), .media_n(fdd_n),
      .media_idx(fdd_idx), .media_wr(fdd_req_wr), .media_din(fdd_din), .media_abort(fdd_abort),
      .media_ready(fdd_ready), .media_rdy(fdd_rdy), .media_hdrv(fdd_hdrv),
      .media_err(fdd_err), .media_dout(fdd_dout),
      .media_hr(fdd_hr), .media_hn(fdd_hn), .media_hs(fdd_hs),
      .media_adv(fdd_adv),
      .dma_drq(dma_drq), .dma_dack(dma_dack), .dma_stb(dma_stb), .dma_tc(dma_tc),
      .dma_dout(dma_dout), .dma_we(dma_we), .dma_din(dma_din),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  // ONE hps_io img_size / img_readonly pair feeds every slot, valid with the mount pulse.
  reg        mnt0 = 0, mnt1 = 0, mntA = 0;
  reg [63:0] img_size = 0;
  reg        img_ro = 0;

  pc9821_fdd_media media (
      .clk(clk), .reset(reset),
      .img_mounted(mnt0), .img_size(img_size), .img_readonly(img_ro),
      .img1_mounted(mnt1), .img1_size(img_size),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_slot(blk_slot),
      .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .blk_req_wr(blk_wr), .blk_rd_addr(blk_rd_addr), .blk_rd_data(blk_rd_data),
      .present(fdd_present), .writeprotect(fdd_wp), .chg(),
      .req(fdd_req), .req_hdr(fdd_req_hdr), .req_wr(fdd_req_wr), .unit(fdd_unit),
      .req_c(fdd_c), .req_h(fdd_h), .req_tc(fdd_tc), .req_hd(fdd_hd), .req_mf(fdd_mf), .req_2hd(fdd_2hd), .req_rpm(fdd_rpm), .req_r(fdd_r), .req_n(fdd_n), .req_idx(fdd_idx),
      .ready(fdd_ready), .rdy(fdd_rdy), .hdrv(fdd_hdrv), .err(fdd_err),
      .dout(fdd_dout), .adv(fdd_adv), .din(fdd_din), .abort(fdd_abort),
      .hdr_r(fdd_hr), .hdr_n(fdd_hn), .hdr_sects(fdd_hs)
  );

  // ==== the host channel ====
  reg        sd_ack_a = 0, sd_ack_b = 0, sd_ack_c = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] sd_lba_a, sd_lba_b, sd_lba_c;
  wire [ 5:0] sd_blk_cnt_a, sd_blk_cnt_b, sd_blk_cnt_c;
  wire        sd_rd_a, sd_wr_a, sd_rd_b, sd_wr_b, sd_rd_c, sd_wr_c;
  wire [15:0] sd_buff_din_a, sd_buff_din_b, sd_buff_din_c;

  // the disk side: one read request, for the queue-fence arm
  reg         a_req_read = 0;
  wire        a_req_done, a_req_error;

  pc9821_block_share share (
      .clk(clk), .rst_n(!reset),
      .a_img_mounted(mntA), .a_img_readonly(1'b0), .a_img_size(img_size),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(a_req_read), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(a_req_done), .a_req_error(a_req_error), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(sd_lba_a), .a_sd_blk_cnt(sd_blk_cnt_a), .a_sd_rd(sd_rd_a), .a_sd_wr(sd_wr_a),
      .a_sd_ack(sd_ack_a), .a_sd_buff_din(sd_buff_din_a),
      .b_img_mounted(mnt0), .b_img_readonly(img_ro), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_write(blk_wr), .b_req_lba(blk_lba), .b_req_slot(blk_slot),
      .b_req_done(blk_done), .b_req_error(blk_error), .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_buf_rd_addr(blk_rd_addr), .b_buf_rd_data(blk_rd_data),
      .b_sd_lba(sd_lba_b), .b_sd_blk_cnt(sd_blk_cnt_b),
      .b_sd_rd(sd_rd_b), .b_sd_wr(sd_wr_b),
      .b_sd_ack(sd_ack_b), .b_sd_buff_din(sd_buff_din_b),
      .c_img_mounted(mnt1), .c_img_readonly(img_ro), .c_img_size(img_size),
      .c_sd_lba(sd_lba_c), .c_sd_blk_cnt(sd_blk_cnt_c),
      .c_sd_rd(sd_rd_c), .c_sd_wr(sd_wr_c),
      .c_sd_ack(sd_ack_c), .c_sd_buff_din(sd_buff_din_c),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // Which image slot B is answered from: 0 = imgA, 1 = imgN (the swap-in).
  reg        b_is_new = 0;
  reg        host_hold = 0;
  // host-side write counters: how many blocks the host wrote into each image
  integer    hw_a = 0, hw_n = 0, hw_d = 0, hw_disk = 0;
  integer    hr_disk = 0;

  reg [12:0] widx, wtotal;
  reg [31:0] hlba;
  reg        hbusy, hlast, hwrite;
  reg  [1:0] hslot;              // 0 = A (disk), 1 = B, 2 = C
  reg  [1:0] hph;                // write: address -> wait -> sample

  task automatic word_for(input [1:0] slot, input [31:0] lba, input [7:0] w,
                          output [15:0] v);
    integer base;
    begin
      base = lba * 512 + w * 2;
      if (slot == 2'd0)      v = {8'hD5, 8'h5D};
      else if (slot == 2'd1) v = b_is_new ? {imgN[base + 1], imgN[base]} : {imgA[base + 1], imgA[base]};
      else if (c_is_hd4)     v = {imgH[base + 1], imgH[base]};
      else                   v = (base + 1 < D_SPAN) ? {imgD[base + 1], imgD[base]} : 16'h0000;
    end
  endtask

  task automatic store_word(input [1:0] slot, input [31:0] lba, input [7:0] w,
                            input [15:0] v);
    integer base;
    begin
      base = lba * 512 + w * 2;
      if (slot == 2'd1) begin
        if (b_is_new) begin imgN[base] = v[7:0]; imgN[base + 1] = v[15:8]; end
        else          begin imgA[base] = v[7:0]; imgA[base + 1] = v[15:8]; end
      end else if (slot == 2'd2) begin
        if (c_is_hd4) begin imgH[base] = v[7:0]; imgH[base + 1] = v[15:8]; end
        else if (base + 1 < D_SPAN) begin imgD[base] = v[7:0]; imgD[base + 1] = v[15:8]; end
      end
    end
  endtask

  wire [15:0] cur_din = (hslot == 2'd1) ? sd_buff_din_b :
                        (hslot == 2'd2) ? sd_buff_din_c : sd_buff_din_a;

  always @(posedge clk) begin
    if (reset) begin
      sd_ack_a <= 1'b0; sd_ack_b <= 1'b0; sd_ack_c <= 1'b0; sd_buff_wr <= 1'b0;
      hbusy <= 1'b0; hlast <= 1'b0; widx <= 13'd0; hwrite <= 1'b0; hslot <= 2'd0; hph <= 2'd0;
    end else if (!hbusy) begin
      sd_buff_wr <= 1'b0;
      if (!host_hold) begin
        if (sd_rd_a || sd_wr_a) begin
          hbusy <= 1'b1; sd_ack_a <= 1'b1; hslot <= 2'd0; hwrite <= sd_wr_a; hlba <= sd_lba_a;
          wtotal <= ({7'd0, sd_blk_cnt_a} + 13'd1) * 13'd256 - 13'd1;
          widx <= 13'd0; hph <= 2'd0; sd_buff_addr <= 13'd0;
          if (sd_rd_a) hr_disk = hr_disk + 1;
        end else if (sd_rd_b || sd_wr_b) begin
          hbusy <= 1'b1; sd_ack_b <= 1'b1; hslot <= 2'd1; hwrite <= sd_wr_b; hlba <= sd_lba_b;
          wtotal <= ({7'd0, sd_blk_cnt_b} + 13'd1) * 13'd256 - 13'd1;
          widx <= 13'd0; hph <= 2'd0; sd_buff_addr <= 13'd0;
          if (sd_wr_b) begin
            if (b_is_new) hw_n = hw_n + 1; else hw_a = hw_a + 1;
          end
        end else if (sd_rd_c || sd_wr_c) begin
          hbusy <= 1'b1; sd_ack_c <= 1'b1; hslot <= 2'd2; hwrite <= sd_wr_c; hlba <= sd_lba_c;
          wtotal <= ({7'd0, sd_blk_cnt_c} + 13'd1) * 13'd256 - 13'd1;
          widx <= 13'd0; hph <= 2'd0; sd_buff_addr <= 13'd0;
          if (sd_wr_c) hw_d = hw_d + 1;
        end
      end
    end else if (hwrite) begin
      // WRITE: present the address, let the registered buffer read settle, sample.
      sd_buff_wr <= 1'b0;
      if (hlast) begin
        hbusy <= 1'b0; sd_ack_a <= 1'b0; sd_ack_b <= 1'b0; sd_ack_c <= 1'b0; hlast <= 1'b0;
      end else if (hph == 2'd0) begin
        sd_buff_addr <= widx; hph <= 2'd1;
      end else if (hph == 2'd1) begin
        hph <= 2'd2;
      end else begin
        store_word(hslot, hlba, widx[7:0], cur_din);
        hph <= 2'd0;
        if (widx == 13'd255) hlast <= 1'b1;
        else widx <= widx + 13'd1;
      end
    end else begin
      sd_buff_wr   <= 1'b1;
      sd_buff_addr <= widx;
      word_for(hslot, hlba + {19'd0, widx[12:8]}, widx[7:0], sd_buff_dout);
      if (hlast) begin
        hbusy <= 1'b0; sd_ack_a <= 1'b0; sd_ack_b <= 1'b0; sd_ack_c <= 1'b0;
        sd_buff_wr <= 1'b0; hlast <= 1'b0;
      end else if (widx == wtotal) begin
        hlast <= 1'b1;
      end else begin
        widx <= widx + 13'd1;
      end
    end
  end

  // ==== the DMA model: one strobe per DRQ, TC coincident with the final one ====
  // dm_out = 1: memory to port (a WRITE's bytes come from dm_src); 0: port to memory.
  reg [15:0] dm_left;
  reg        dm_run, dm_out;
  integer    dm_n;
  reg  [7:0] dm_bytes [0:16383];
  reg  [7:0] dm_src   [0:16383];
  reg        armed;
  always @(posedge clk) begin
    dma_dack <= 1'b0;
    dma_stb  <= 1'b0;
    dma_tc   <= 1'b0;
    dma_we   <= 1'b0;
    if (reset) begin
      dm_left <= 16'd0; dm_run <= 1'b0; dm_n = 0; armed <= 1'b0;
    end else if (armed) begin
      if (dm_n < 16384) dm_bytes[dm_n] = dma_dout;
      dm_n     = dm_n + 1;
      dm_left <= dm_left - 16'd1;
      if (dm_left == 16'd1) dm_run <= 1'b0;
      armed <= 1'b0;
    end else if (dm_run && dma_drq && (dm_left != 16'd0)) begin
      dma_dack <= 1'b1;
      dma_stb  <= 1'b1;
      dma_we   <= dm_out;
      dma_din  <= dm_src[dm_n];
      dma_tc   <= (dm_left == 16'd1);
      armed    <= 1'b1;
    end
  end

  // ==== CHECKS ====
  integer fails = 0;
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_FDD_WRITE: watchdog timeout (no verdict reached)");
  end

  task automatic expect8(input [7:0] got, input [7:0] want, input [8*100-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, got, want);
        fails = fails + 1;
      end
    end
  endtask
  task automatic expecti(input integer got, input integer want, input [8*100-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  // whole-image compares against the expectation (at most 4 mismatches printed)
  task automatic cmp_raw(input [8*60-1:0] what);
    integer bad;
    begin
      bad = 0;
      for (i = 0; i < RAW_BYTES; i = i + 1)
        if (imgA[i] !== expA[i]) begin
          if (bad < 4) $display("  FAIL: %0s: raw image byte %0d is %02x, expected %02x",
                                what, i, imgA[i], expA[i]);
          bad = bad + 1;
        end
      if (bad != 0) fails = fails + 1;
    end
  endtask
  task automatic cmp_d88(input [8*60-1:0] what);
    integer bad;
    begin
      bad = 0;
      for (i = 0; i < D_END; i = i + 1)
        if (imgD[i] !== expD[i]) begin
          if (bad < 4) $display("  FAIL: %0s: D88 byte %0d is %02x, expected %02x",
                                what, i, imgD[i], expD[i]);
          bad = bad + 1;
        end
      if (bad != 0) fails = fails + 1;
    end
  endtask
  task automatic cmp_new(input [8*60-1:0] what);
    integer bad;
    begin
      bad = 0;
      for (i = 0; i < RAW_BYTES; i = i + 1)
        if (imgN[i] !== pnew(i)) begin
          if (bad < 4) $display("  FAIL: %0s: the swapped-in image's byte %0d is %02x, it held %02x",
                                what, i, imgN[i], pnew(i));
          bad = bad + 1;
        end
      if (bad != 0) fails = fails + 1;
    end
  endtask

  // ==== the controller's port helpers (the iobus S_BYTE contract) ====
  task automatic wr8(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(posedge clk);
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask
  reg [7:0] rd_val;
  task automatic rd8(input [2:0] a);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      #1 rd_val = dout;
      @(posedge clk);
      @(negedge clk); cs = 0; rd = 0;
    end
  endtask
  reg [7:0] g_rs [0:7];
  integer   g_rlen;
  task automatic get_result;
    begin
      g_rlen = 0;
      for (i = 0; i < 8; i = i + 1) g_rs[i] = 8'hFF;
      rd8(3'd0);
      while (((rd_val & 8'h40) != 0) && (g_rlen < 8)) begin
        rd8(3'd1);
        g_rs[g_rlen] = rd_val;
        g_rlen = g_rlen + 1;
        rd8(3'd0);
      end
    end
  endtask
  task automatic wait_irq(input integer maxc, input [8*60-1:0] what);
    begin
      n = 0;
      while (!irq && n < maxc) begin @(negedge clk); n = n + 1; end
      if (!irq) begin
        $display("  FAIL: %0s: the interrupt never came (the controller hung)", what);
        fails = fails + 1;
      end
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
        wait_irq(200000, "seek before a data command");
        wr8(3'd1, 8'h08);   // SENSE INTERRUPT STATUS: drain the seek's completion
        get_result;
      end
    end
  endtask

  // a data command: opcode, then us|hd<<2, C, H, R, N, EOT, GPL, DTL (io/fdc.c:201-220)
  task automatic data_cmd(input [7:0] op, input [7:0] ushd, input [7:0] c, input [7:0] h,
                          input [7:0] r, input [7:0] nn, input [7:0] eot);
    begin
      seek_to(ushd[1:0], c);
      wr8(3'd1, op);
      wr8(3'd1, ushd); wr8(3'd1, c); wr8(3'd1, h); wr8(3'd1, r);
      wr8(3'd1, nn); wr8(3'd1, eot); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
    end
  endtask

  task automatic arm_dma_out(input integer bytes, input integer seed);
    begin
      for (i = 0; i < bytes; i = i + 1) dm_src[i] = pw(seed, i);
      dm_left = bytes[15:0]; dm_n = 0; dm_out = 1; dm_run = 1;
    end
  endtask
  task automatic arm_dma_in(input integer bytes);
    begin
      dm_left = bytes[15:0]; dm_n = 0; dm_out = 0; dm_run = 1;
    end
  endtask

  task automatic expect_result(input [7:0] st0, st1, c, h, r, nn, input [8*60-1:0] what);
    begin
      get_result;
      expecti(g_rlen, 7, {what, ": result length"});
      expect8(g_rs[0], st0, {what, ": ST0"});
      expect8(g_rs[1], st1, {what, ": ST1"});
      expect8(g_rs[2], 8'h00, {what, ": ST2"});
      expect8(g_rs[3], c, {what, ": C"});
      expect8(g_rs[4], h, {what, ": H"});
      expect8(g_rs[5], r, {what, ": R"});
      expect8(g_rs[6], nn, {what, ": N"});
    end
  endtask

  task automatic mount0(input [63:0] size, input ro);
    begin
      img_size = size; img_ro = ro;
      @(negedge clk); mnt0 = 1;
      @(posedge clk);
      @(negedge clk); mnt0 = 0;
      repeat (6000) @(negedge clk);
    end
  endtask
  task automatic mount1(input [63:0] size, input ro);
    begin
      img_size = size; img_ro = ro;
      @(negedge clk); mnt1 = 1;
      @(posedge clk);
      @(negedge clk); mnt1 = 0;
      repeat (6000) @(negedge clk);
    end
  endtask

  // a raw sector's file offset: ((C*2+H) * 8 + R-1) << 10 (the 8x1024 row)
  function automatic integer raw_off(input integer c, input integer h, input integer r);
    raw_off = (((c * 2 + h) * 8) + r - 1) * 1024;
  endfunction

  integer t0, hwa0, hwn0;

  // ==== STIMULUS ====
  initial begin
    build_raw;
    build_new;
    build_d88(8'h00);

    reset = 1; repeat (6) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);

    mount0(RAW_BYTES, 1'b0);
    mount1(D_END, 1'b0);
    expecti(fdd_present, 2'b11, "setup: both drives present");
    expecti(fdd_wp, 2'b00, "setup: both media writable");

    // ---------------- W1: one raw sector, written and read back ----------------------
    // WRITE DATA (0x45: MF) unit 0, C=2 H=1 R=5 N=3 EOT=5. FDC_WriteData: the sector's 1024
    // bytes, fdd_write, then R++ == EOT -> R = 1, C++ -> success7 {0|hd<<2, 0, 0, 3, 1, 1, 3}.
    arm_dma_out(1024, 1);
    data_cmd(8'h45, 8'h04, 8'h02, 8'h01, 8'h05, 8'h03, 8'h05);
    wait_irq(400000, "W1");
    expect_result(8'h04, 8'h00, 8'h03, 8'h01, 8'h01, 8'h03, "W1 write raw C2 H1 R5");
    expecti(dm_n, 1024, "W1 the sector's 128 << N bytes were taken");
    t0 = raw_off(2, 1, 5);
    for (j = 0; j < 1024; j = j + 1) expA[t0 + j] = pw(1, j);
    cmp_raw("W1 the raw image after one sector");
    // ... and READ DATA returns it (the image bytes, through the same medium)
    arm_dma_in(1024);
    data_cmd(8'h46, 8'h04, 8'h02, 8'h01, 8'h05, 8'h03, 8'h05);
    wait_irq(400000, "W1 read-back");
    get_result;
    expect8(g_rs[0], 8'h04, "W1 read-back ST0");
    n = 0;
    for (j = 0; j < 1024; j = j + 1) if (dm_bytes[j] !== pw(1, j)) n = n + 1;
    expecti(n, 0, "W1 read-back: every byte is the one written");

    // ---------------- W2: a multi-sector raw write, R walks to EOT -------------------
    // R=6..8 with EOT=8 on C=0 H=0: three sectors, then R++ == EOT -> R = 1, C+1.
    arm_dma_out(3072, 2);
    data_cmd(8'h45, 8'h00, 8'h00, 8'h00, 8'h06, 8'h03, 8'h08);
    wait_irq(1200000, "W2");
    expect_result(8'h00, 8'h00, 8'h01, 8'h00, 8'h01, 8'h03, "W2 write raw R6..R8");
    expecti(dm_n, 3072, "W2 three sectors' bytes taken");
    t0 = raw_off(0, 0, 6);
    for (j = 0; j < 3072; j = j + 1) expA[t0 + j] = pw(2, j);
    cmp_raw("W2 the raw image after three sectors (R5 and R1 of the next track untouched)");

    // ---------------- W3: D88 sectors that straddle host blocks ----------------------
    // T0 R1 (data 704..1727: the tail of block 1, all of block 2, the head of block 3).
    arm_dma_out(1024, 3);
    data_cmd(8'h45, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(800000, "W3a");
    expect_result(8'h01, 8'h00, 8'h01, 8'h00, 8'h01, 8'h03, "W3a write D88 T0 R1");
    for (j = 0; j < 1024; j = j + 1) expD[704 + j] = pw(3, j);
    cmp_d88("W3a only R1's data changed (headers, R2, R3 kept)");
    // T0 R2: N3 (1024 bytes sent) but 512 STORED - the rest has no home in the file.
    arm_dma_out(1024, 4);
    data_cmd(8'h45, 8'h01, 8'h00, 8'h00, 8'h02, 8'h03, 8'h02);
    wait_irq(800000, "W3b");
    expect_result(8'h01, 8'h00, 8'h01, 8'h00, 8'h01, 8'h03, "W3b write D88 T0 R2 (short stored)");
    expecti(dm_n, 1024, "W3b the whole 128 << N taken");
    for (j = 0; j < 512; j = j + 1) expD[1744 + j] = pw(4, j);
    cmp_d88("W3b R2 stores its 512 bytes, R3's header kept");
    // T1 R1: N1 256 bytes at the ODD offset 3313 (the odd-start merge of the first word).
    arm_dma_out(256, 5);
    data_cmd(8'h45, 8'h05, 8'h00, 8'h01, 8'h01, 8'h01, 8'h01);
    wait_irq(800000, "W3c");
    expect_result(8'h05, 8'h00, 8'h01, 8'h01, 8'h01, 8'h01, "W3c write D88 T1 R1 (odd start)");
    for (j = 0; j < 256; j = j + 1) expD[3313 + j] = pw(5, j);
    cmp_d88("W3c the odd-start sector, neighbours kept");
    // read T0 R2 back: 512 written bytes, then zeroes past the stored size
    arm_dma_in(1024);
    data_cmd(8'h46, 8'h01, 8'h00, 8'h00, 8'h02, 8'h03, 8'h02);
    wait_irq(800000, "W3 read-back");
    get_result;
    n = 0;
    for (j = 0; j < 1024; j = j + 1)
      if (dm_bytes[j] !== ((j < 512) ? pw(4, j) : 8'h00)) n = n + 1;
    expecti(n, 0, "W3 read-back of the short sector: written bytes then zeroes");

    // ---------------- W4: a sector that is not there --------------------------------
    // R=9 on an 8-sector track: the bytes go first, then writesector's IC0|ND (:400-403).
    hwa0 = hw_a;
    arm_dma_out(1024, 6);
    data_cmd(8'h45, 8'h00, 8'h00, 8'h00, 8'h09, 8'h03, 8'h09);
    wait_irq(400000, "W4");
    expect_result(8'h40, 8'h04, 8'h00, 8'h00, 8'h09, 8'h03, "W4 missing sector");
    expecti(dm_n, 1024, "W4 the missing sector's bytes were still taken");
    expecti(hw_a - hwa0, 0, "W4 no host write for a missing sector");
    cmp_raw("W4 the raw image is unchanged");

    // ---------------- W5: a terminal count inside a sector ---------------------------
    // 512 bytes for a 1024-byte sector: the command ends with tc's R = 1, C+1 (FDC_WriteData's
    // `(fdc.tc) ||` arm), and its first 512 bytes are in the image. The sector's tail is NOT
    // asserted (NP2kai writes whatever fdc.buf held; see the report), only that the
    // controller and the medium are not left wedged - W6 issues the next command.
    arm_dma_out(512, 7);
    data_cmd(8'h45, 8'h00, 8'h03, 8'h00, 8'h01, 8'h03, 8'h08);
    wait_irq(400000, "W5");
    expect_result(8'h00, 8'h00, 8'h04, 8'h00, 8'h01, 8'h03, "W5 TC mid-sector");
    expecti(dm_n, 512, "W5 the guest's 512 bytes");
    t0 = raw_off(3, 0, 1);
    for (j = 0; j < 512; j = j + 1) expA[t0 + j] = pw(7, j);
    for (j = 512; j < 1024; j = j + 1) expA[t0 + j] = imgA[t0 + j];   // the tail: not asserted
    cmp_raw("W5 the first 512 bytes landed");

    // ---------------- W6: write protect -------------------------------------------
    // (a) the D88 header's protect bit (0x1A bit 4): ST3 WP, and WRITE DATA refused with
    // IC0|NW before any byte moves (FDC_DriveCheck(TRUE)).
    build_d88(8'h10);
    mount1(D_END, 1'b0);
    expecti(fdd_wp, 2'b10, "W6a drive 1's medium is protected by its header");
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h01);
    get_result;
    expect8(g_rs[0] & 8'h40, 8'h40, "W6a ST3 WP for the protected D88");
    hwa0 = hw_d;
    arm_dma_out(1024, 8);
    data_cmd(8'h45, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(200000, "W6a");
    expect_result(8'h41, 8'h02, 8'h00, 8'h00, 8'h01, 8'h03, "W6a NW on the protected D88");
    expecti(dm_n, 0, "W6a no byte moves for a protected medium");
    expecti(hw_d - hwa0, 0, "W6a no host write");
    cmp_d88("W6a the protected image is unchanged");
    // (b) a READ-ONLY MOUNT of a raw image: the same refusal from the mount's flag.
    mount0(RAW_BYTES, 1'b1);
    expecti(fdd_wp, 2'b11, "W6b drive 0 mounted read-only is protected");
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h00);
    get_result;
    expect8(g_rs[0] & 8'h40, 8'h40, "W6b ST3 WP for the read-only mount");
    hwa0 = hw_a;
    arm_dma_out(1024, 9);
    data_cmd(8'h45, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(200000, "W6b");
    expect_result(8'h40, 8'h02, 8'h00, 8'h00, 8'h01, 8'h03, "W6b NW on the read-only mount");
    expecti(dm_n, 0, "W6b no byte moves");
    expecti(hw_a - hwa0, 0, "W6b no host write");
    // (c) the same image mounted writable: ST3 WP clear, and the write goes through.
    mount0(RAW_BYTES, 1'b0);
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h00);
    get_result;
    expect8(g_rs[0] & 8'h40, 8'h00, "W6c ST3 WP clear for the writable mount");
    arm_dma_out(1024, 10);
    data_cmd(8'h45, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(400000, "W6c");
    expect_result(8'h00, 8'h00, 8'h01, 8'h00, 8'h01, 8'h03, "W6c write after the writable remount");
    t0 = raw_off(0, 0, 1);
    for (j = 0; j < 1024; j = j + 1) expA[t0 + j] = pw(10, j);
    cmp_raw("W6c the writable remount's write landed");

    // ---------------- W7: the image is SWAPPED under a write the host has not taken ----
    // (a) the engine's withdraw: the sector's last block write-back is presented (sd_wr) and
    // the ARM is late (host_hold); the OSD then mounts ANOTHER image in the same slot. The
    // write must never be served - hps_io names the slot, so the ARM would write the old
    // disk's block into the new one. The command must still end (no hang).
    hwa0 = hw_a; hwn0 = hw_n;
    arm_dma_out(1024, 11);
    data_cmd(8'h45, 8'h00, 8'h05, 8'h00, 8'h01, 8'h03, 8'h01);
    n = 0;
    while (dm_n < 600 && n < 400000) begin @(negedge clk); n = n + 1; end
    host_hold = 1;
    n = 0;
    while (!sd_wr_b && n < 400000) begin @(negedge clk); n = n + 1; end
    expecti(sd_wr_b, 1, "W7a the last block's write-back is presented to the host");
    b_is_new = 1;
    mount0(RAW_BYTES, 1'b0);
    host_hold = 0;
    wait_irq(400000, "W7a");
    get_result;
    expect8(g_rs[0] & 8'hC0, 8'h40, "W7a the cut-off write ends with an error result (IC0)");
    repeat (20000) @(negedge clk);
    expecti(hw_n - hwn0, 0, "W7a no block reached the swapped-in image");
    cmp_new("W7a the swapped-in image is untouched");
    // The sector's first block was written back BEFORE the swap (at its 512th byte), so it is
    // in the image that was mounted then - one host write, the first 512 bytes.
    expecti(hw_a - hwa0, 1, "W7a the pre-swap block reached the image mounted at the time");
    t0 = raw_off(5, 0, 1);
    for (j = 0; j < 512; j = j + 1) expA[t0 + j] = pw(11, j);
    // the new image is served afterwards
    arm_dma_in(1024);
    data_cmd(8'h46, 8'h00, 8'h00, 8'h00, 8'h02, 8'h03, 8'h02);
    wait_irq(400000, "W7a read of the new image");
    get_result;
    expect8(g_rs[0], 8'h00, "W7a the new image reads");
    expect8(dm_bytes[0], pnew(raw_off(0, 0, 2)), "W7a byte 0 is the NEW image's");
    // (b) the shared queue's fence: the disk holds the engine (its read is presented and the
    // ARM is late), so the floppy's write-back WAITS IN THE QUEUE; the slot is swapped back to
    // the first image; when the ARM resumes, the disk read is served and the floppy write is
    // never handed to the engine.
    hwa0 = hw_a; hwn0 = hw_n;
    img_size = 64'd1048576;
    @(negedge clk); mntA = 1; @(posedge clk); @(negedge clk); mntA = 0;
    arm_dma_out(1024, 12);
    data_cmd(8'h45, 8'h00, 8'h06, 8'h00, 8'h01, 8'h03, 8'h01);
    n = 0;
    while (dm_n < 600 && n < 400000) begin @(negedge clk); n = n + 1; end
    host_hold = 1;
    @(negedge clk); a_req_read = 1; @(negedge clk); a_req_read = 0;
    n = 0;
    while (!(share.b_pend && share.b_pend_write) && n < 400000) begin @(negedge clk); n = n + 1; end
    expecti(share.b_pend && share.b_pend_write, 1, "W7b the floppy write-back is queued behind the disk");
    expecti(sd_rd_a, 1, "W7b the disk's read holds the engine");
    b_is_new = 0;
    mount0(RAW_BYTES, 1'b0);
    host_hold = 0;
    wait_irq(400000, "W7b");
    get_result;
    expect8(g_rs[0] & 8'hC0, 8'h40, "W7b the cut-off write ends with an error result (IC0)");
    repeat (20000) @(negedge clk);
    // The sector's FIRST block was written back before the swap, into the image mounted then
    // (W7a's swapped-in image); the image swapped in now (the first one again) gets nothing.
    expecti(hw_n - hwn0, 1, "W7b only the pre-swap block reached the image it was written to");
    expecti(hw_a - hwa0, 0, "W7b nothing reached the image swapped in under the queued write");
    expecti(hr_disk >= 1, 1, "W7b the disk read was served");
    cmp_raw("W7b the image swapped in under the queued write is unchanged");

    // ---------------- W8: a write to an EJECTED drive ---------------------------------
    // No medium: the controller's no-media class (IC0|NR|hd<<2|us, FDC_DriveCheck's first arm,
    // through this model's deferred completion) and NOTHING reaches the host.
    hwa0 = hw_a; hwn0 = hw_n;
    mount0(64'd16, 1'b0);
    expecti(fdd_present, 2'b10, "W8 drive 0 ejected");
    arm_dma_out(1024, 13);
    data_cmd(8'h45, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(200000, "W8");
    rd8(3'd0);
    expect8(rd_val & 8'hC0, 8'h80, "W8 no result phase for the ejected drive");
    wr8(3'd1, 8'h08);
    get_result;
    expect8(g_rs[0], 8'h48, "W8 ST0 = IC0|NR|unit 0");
    expecti(dm_n, 0, "W8 no byte moves to an ejected drive");
    repeat (20000) @(negedge clk);
    expecti((hw_a - hwa0) + (hw_n - hwn0), 0, "W8 no host write after the eject");
    // ... and a remount is written again
    mount0(RAW_BYTES, 1'b0);
    arm_dma_out(1024, 14);
    data_cmd(8'h45, 8'h00, 8'h07, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(400000, "W8 remount");
    expect_result(8'h00, 8'h00, 8'h08, 8'h00, 8'h01, 8'h03, "W8 write after the remount");
    t0 = raw_off(7, 0, 1);
    for (j = 0; j < 1024; j = j + 1) expA[t0 + j] = pw(14, j);
    cmp_raw("W8 the remount's write landed");

    // ---------------- W9: a 1.44 MB raw image (512-byte sectors), MT across both heads ----
    // HD4 row {0, 160, 18, 2, 2HD} (fdd_xdf.c). An MT (0xC5) write from side 0's R18 runs on
    // into side 1's R1..R18 (FDC_WriteData: at EOT `hd ^= 1; H ^= 1;` and, H now 1, the
    // transfer continues) and ends at side 1's EOT: R = 1, hd and H back to 0, C+1. 19 sectors.
    for (i = 0; i < HD4_BYTES; i = i + 1) begin imgH[i] = praw(i + 17); expH[i] = praw(i + 17); end
    c_is_hd4 = 1;
    mount1(HD4_BYTES, 1'b0);
    expecti(fdd_present, 2'b11, "W9 the 1.44 MB image mounts on drive 1");
    hwa0 = hw_d;
    // The 1.44 MB medium is served at 360 rpm only: select unit 1 and set its rpm bit through
    // 0x04BE (bit 4 = write the rpm, bits 6:5 = the unit, bit 0 = 1; NP2kai fdc_o4be), as the
    // BIOS does before a 1.44 MB access (fdd_seeksector_common's rpm test).
    wr8(3'd3, 8'h31);
    arm_dma_out(19 * 512, 15);
    data_cmd(8'hC5, 8'h01, 8'h0A, 8'h00, 8'h12, 8'h02, 8'h12);
    wait_irq(4000000, "W9");
    expect_result(8'h01, 8'h00, 8'h0B, 8'h00, 8'h01, 8'h02, "W9 MT write side 0 R18 .. side 1 R18");
    expecti(dm_n, 19 * 512, "W9 nineteen 512-byte sectors taken");
    expecti(hw_d - hwa0, 19, "W9 one host block write per 512-byte sector");
    // side 0 R18 at ((10*2+0)*18 + 17) << 9, then side 1 R1..R18 at ((10*2+1)*18 + R-1) << 9:
    // the two are adjacent in the file, so the 19 sectors are one contiguous run.
    t0 = ((10 * 2 + 0) * 18 + 17) * 512;
    for (j = 0; j < 19 * 512; j = j + 1) expH[t0 + j] = pw(15, j);
    n = 0;
    for (i = 0; i < HD4_BYTES; i = i + 1) if (imgH[i] !== expH[i]) n = n + 1;
    expecti(n, 0, "W9 the 1.44 MB image holds exactly the nineteen sectors written");
    // the disk's very last sector (C79 H1 R18), whose block is the image's last
    arm_dma_out(512, 16);
    data_cmd(8'h45, 8'h05, 8'h4F, 8'h01, 8'h12, 8'h02, 8'h12);
    wait_irq(400000, "W9 last sector");
    expect_result(8'h05, 8'h00, 8'h50, 8'h01, 8'h01, 8'h02, "W9 the last sector of the disk");
    t0 = HD4_BYTES - 512;
    for (j = 0; j < 512; j = j + 1) expH[t0 + j] = pw(16, j);
    n = 0;
    for (i = 0; i < HD4_BYTES; i = i + 1) if (imgH[i] !== expH[i]) n = n + 1;
    expecti(n, 0, "W9 the last sector landed in the image's last block");

    // ---------------- W10: READ DATA's EOT end keeps the command's H -------------------
    // The read and the write share the sector-end step now, and NP2kai's success7 sends fdc.H,
    // which only MT flips (FDC_ReadData NEXTDATA, io/fdc.c:556-576): a non-MT read of side 1
    // that ends at EOT answers H = 1, not 0. The DMA count is larger than the sector, so EOT
    // (not the terminal count) ends it.
    arm_dma_in(2048);
    data_cmd(8'h46, 8'h05, 8'h0A, 8'h01, 8'h12, 8'h02, 8'h12);
    wait_irq(400000, "W10");
    expect_result(8'h05, 8'h00, 8'h0B, 8'h01, 8'h01, 8'h02, "W10 non-MT read at side 1's EOT");
    expecti(dm_n, 512, "W10 one sector moved");
    dm_run = 0;

    // ---------------- W11: a PIO (non-DMA) write, polling RQM before every byte -----------
    // NP2kai's data-port write lands in fdc_datawrite's BUFRECV arm exactly as a DMA byte does
    // (fdc_o92 -> fdc_datawrite, io/fdc.c:1059-1076 and :945-956; fdc_o92 takes the byte only while `(status & (RQM|DIO)) == RQM`). The guest polls the MSR for
    // RQM (and DIO clear) before each byte; the medium cannot take a byte while a block is in
    // flight, so RQM must say so or the byte is lost. Drive 1's HD4 image, C=20 H=0 R=1 N=3
    // (1024 bytes - two host blocks, so a write-back and a fetch land mid-sector).
    data_cmd(8'h45, 8'h01, 8'h14, 8'h00, 8'h01, 8'h03, 8'h01);
    for (j = 0; j < 1024; j = j + 1) begin
      n = 0;
      rd8(3'd0);
      while (((rd_val & 8'hC0) != 8'h80) && (n < 200000)) begin rd8(3'd0); n = n + 1; end
      wr8(3'd1, pw(17, j));
    end
    wait_irq(400000, "W11");
    // The 1024-byte sector at N=3 is NOT this image's geometry (HD4 is N=2), so the medium
    // answers it as fdd_read_xdf's N mismatch: the bytes are taken, then IC0|ND.
    expect_result(8'h41, 8'h04, 8'h14, 8'h00, 8'h01, 8'h03, "W11a PIO write, wrong N for the image");
    data_cmd(8'h45, 8'h01, 8'h14, 8'h00, 8'h01, 8'h02, 8'h02);
    for (j = 0; j < 1024; j = j + 1) begin
      n = 0;
      rd8(3'd0);
      while (((rd_val & 8'hC0) != 8'h80) && (n < 200000)) begin rd8(3'd0); n = n + 1; end
      wr8(3'd1, pw(18, j));
    end
    wait_irq(400000, "W11b");
    expect_result(8'h01, 8'h00, 8'h15, 8'h00, 8'h01, 8'h02, "W11b PIO write R1..R2 (N=2)");
    t0 = ((20 * 2 + 0) * 18 + 0) * 512;
    for (j = 0; j < 1024; j = j + 1) expH[t0 + j] = pw(18, j);
    n = 0;
    for (i = 0; i < HD4_BYTES; i = i + 1) if (imgH[i] !== expH[i]) n = n + 1;
    expecti(n, 0, "W11b every PIO byte landed (none dropped while a block was in flight)");

    // ---------------- W12: a raw write whose EOT is past the track -------------------------
    // fdd_write_xdf (diskimage/fd/fdd_xdf.c:399-404): `if (fdc.eot > fdd->inf.xdf.sectors)`
    // -> 0xc0, i.e. writesector's IC0|ND after the sector's bytes (the 8-sector raw row, EOT 9).
    hwa0 = hw_a;
    arm_dma_out(1024, 19);
    data_cmd(8'h45, 8'h00, 8'h0B, 8'h00, 8'h01, 8'h03, 8'h09);
    wait_irq(400000, "W12");
    expect_result(8'h40, 8'h04, 8'h0B, 8'h00, 8'h01, 8'h03, "W12 raw write with EOT 9 > 8 sectors");
    expecti(dm_n, 1024, "W12 the sector's bytes were taken first");
    expecti(hw_a - hwa0, 0, "W12 nothing written");
    cmp_raw("W12 the raw image is unchanged");

    // ---------------- W13: READ DATA whose count ends INSIDE a sector ----------------------
    // NP2kai answers at the terminal count (R = 1, C unchanged - fdc_dataread :1016-1026) and
    // just stops reading. The next command must be served: before the fix the medium stayed
    // mid-sector with bytes owed, `ready` never rose, and the next READ hung in X_REQ.
    arm_dma_in(300);
    data_cmd(8'h46, 8'h00, 8'h0B, 8'h00, 8'h02, 8'h03, 8'h08);
    wait_irq(400000, "W13a");
    expect_result(8'h00, 8'h00, 8'h0B, 8'h00, 8'h01, 8'h03, "W13a READ ended by TC after 300 bytes");
    expecti(dm_n, 300, "W13a 300 bytes moved");
    arm_dma_in(1024);
    data_cmd(8'h46, 8'h00, 8'h0B, 8'h00, 8'h03, 8'h03, 8'h03);
    wait_irq(400000, "W13b the next READ after a mid-sector TC");
    get_result;
    expect8(g_rs[0], 8'h00, "W13b the next READ completes");
    n = 0;
    for (j = 0; j < 1024; j = j + 1) if (dm_bytes[j] !== expA[raw_off(11, 0, 3) + j]) n = n + 1;
    expecti(n, 0, "W13b and returns its own sector");
    // A DOR RESET in the middle of a READ (fdc_o94's 0->1 bit 7 edge -> fdcstatusreset,
    // io/fdc.c:996-1032): the DMA is held off so the controller sits in the data phase.
    data_cmd(8'h46, 8'h00, 8'h0B, 8'h00, 8'h04, 8'h03, 8'h04);
    repeat (20000) @(negedge clk);
    wr8(3'd2, 8'h80);
    wr8(3'd2, 8'h00);
    arm_dma_in(1024);
    data_cmd(8'h46, 8'h00, 8'h0B, 8'h00, 8'h05, 8'h03, 8'h05);
    wait_irq(400000, "W13c the READ after a DOR reset mid-read");
    get_result;
    expect8(g_rs[0], 8'h00, "W13c the READ after a DOR reset completes");
    n = 0;
    for (j = 0; j < 1024; j = j + 1) if (dm_bytes[j] !== expA[raw_off(11, 0, 5) + j]) n = n + 1;
    expecti(n, 0, "W13c and returns its own sector");

    // ---------------- W14: a DOR reset in the middle of a WRITE ---------------------------
    // fdcstatusreset drops the half-received buffer: writesector() never runs, so NP2kai leaves
    // the sector as it was. 300 of 1024 bytes arrive, the DMA stops, the controller is reset;
    // the sector must be unchanged and the next write must work.
    hwa0 = hw_a;
    arm_dma_out(1024, 20);
    data_cmd(8'h45, 8'h00, 8'h0C, 8'h00, 8'h01, 8'h03, 8'h01);
    n = 0;
    while (dm_n < 300 && n < 400000) begin @(negedge clk); n = n + 1; end
    dm_run = 0;
    repeat (2000) @(negedge clk);
    wr8(3'd2, 8'h80);
    wr8(3'd2, 8'h00);
    repeat (20000) @(negedge clk);
    expecti(hw_a - hwa0, 0, "W14 nothing of the cut-off write reached the image");
    cmp_raw("W14 the sector is unchanged after the reset");
    arm_dma_out(1024, 21);
    data_cmd(8'h45, 8'h00, 8'h0C, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(400000, "W14 the write after the reset");
    expect_result(8'h00, 8'h00, 8'h0D, 8'h00, 8'h01, 8'h03, "W14 the write after the reset");
    t0 = raw_off(12, 0, 1);
    for (j = 0; j < 1024; j = j + 1) expA[t0 + j] = pw(21, j);
    cmp_raw("W14 the write after the reset landed");

    // ---------------- W15: FORMAT (WRITE ID) of a raw image ---------------------------------
    // FDC_WriteID (io/fdc.c:723-765) -> fdd_formatinit_xdf (diskimage/fd/fdd_xdf.c:433-517):
    // SC sectors of 128 << N bytes of D at ((treg << 1) + hd) * SC * (128 << N), then - the raw
    // format's fdd_isformating() being FALSE - `fdc.crcn = 1; fdcsend_success7();` with NO ID
    // byte taken. SEEK unit 0 to cylinder 9 first; FORMAT hd 1: N 3, SC 8, GPL 0x74, D 0xE5.
    wr8(3'd1, 8'h0F); wr8(3'd1, 8'h00); wr8(3'd1, 8'h09);
    wait_irq(200000, "W15 SEEK");
    wr8(3'd1, 8'h08); get_result;
    hwa0 = hw_a;
    arm_dma_out(1024, 22);
    wr8(3'd1, 8'h4D); wr8(3'd1, 8'h04); wr8(3'd1, 8'h03); wr8(3'd1, 8'h08);
    wr8(3'd1, 8'h74); wr8(3'd1, 8'hE5);
    wait_irq(1200000, "W15 FORMAT");
    get_result;
    expecti(g_rlen, 7, "W15 FORMAT result length");
    expect8(g_rs[0], 8'h04, "W15 FORMAT ST0 = hd<<2|us (success7)");
    expect8(g_rs[1], 8'h00, "W15 FORMAT ST1");
    expect8(g_rs[2], 8'h00, "W15 FORMAT ST2");
    expect8(g_rs[6], 8'h03, "W15 FORMAT N = the command's N (FDC_WriteID's fdc.N = cmds[1])");
    expecti(dm_n, 0, "W15 the raw FORMAT takes no ID byte");
    dm_run = 0;
    t0 = ((9 * 2 + 1) * 8) * 1024;
    for (j = 0; j < 8 * 1024; j = j + 1) expA[t0 + j] = 8'hE5;
    cmp_raw("W15 the track (C9 H1) is filled with D and nothing else changed");
    // READ ID after the format: crcn = 1, so fdd_readid_common answers R = ++crcn = 2
    // (diskimage/fddfile.c:321-350).
    wr8(3'd1, 8'h4A); wr8(3'd1, 8'h04);
    wait_irq(200000, "W15 READ ID");
    get_result;
    expect8(g_rs[5], 8'h02, "W15 READ ID after FORMAT answers R = 2 (crcn = 1)");

    // ---------------- W16: FORMAT of a D88 is not modelled: IC0|NW, image untouched --------
    // NP2kai rebuilds the D88 track (fdd_formating_d88, diskimage/fd/fdd_d88.c:693-737, growing
    // the file through fileappend) - a known gap here, answered as the unformattable medium.
    build_d88(8'h00);
    c_is_hd4 = 0;
    mount1(D_END, 1'b0);
    // SEEK drive 1 to cylinder 0 first, so the format names a track this D88 HAS (its R1..R3
    // with N 3): a D88 that took the request as a write would then visibly overwrite them.
    wr8(3'd1, 8'h0F); wr8(3'd1, 8'h01); wr8(3'd1, 8'h00);
    wait_irq(200000, "W16 SEEK");
    wr8(3'd1, 8'h08); get_result;
    hwa0 = hw_d;
    wr8(3'd1, 8'h4D); wr8(3'd1, 8'h01); wr8(3'd1, 8'h03); wr8(3'd1, 8'h03);
    wr8(3'd1, 8'h74); wr8(3'd1, 8'hE5);
    wait_irq(400000, "W16 D88 FORMAT");
    get_result;
    expect8(g_rs[0], 8'h41, "W16 D88 FORMAT ST0 = IC0|us");
    expect8(g_rs[1], 8'h02, "W16 D88 FORMAT ST1 = NW");
    expecti(hw_d - hwa0, 0, "W16 nothing written to the D88");
    cmp_d88("W16 the D88 is unchanged");

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_WRITE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_WRITE: FAIL (%0d errors)", fails);
  end

endmodule
