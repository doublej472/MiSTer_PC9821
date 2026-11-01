`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDC_MF: the FDC carries the command's MF bit (MFM vs FM) to the medium and the medium honours it as NP2kai does - a raw image is MFM only, so an FM READ DATA or FM READ ID on it answers IC0 with ST1 ND while the MFM form reads (diskimage/fddfile.c fdd_seeksector_common, fdd_readid_common), and a D88 READ DATA whose header matches in the other recording mode (mfm_flg 0x40 = FM, 0x00 = MFM) finds no sector (fdd_d88.c searchsector_d88), and a D88 READ ID of a header in the other mode answers ND too (an FM READ ID cannot read MFM address marks; NP2kai fdd_readid_d88 does not test MF, a recorded divergence) - so the BIOS's FM boot probe of an MFM disk fails and its MFM retry loads the whole boot sector, instead of a phantom FM read moving half of it.
//
// WHY THIS EXISTS. The controller dropped the opcode's MF bit, so the BIOS's first boot read
// (opcode 0x06, FM, N=3) of a 1024-byte MFM boot sector was served as if it were MFM; the
// transfer ended part-way and the BIOS ran a half-loaded boot program, which scanned a zeroed
// file table and jumped into empty memory (a black screen).
//
// EXPECTED VALUES (NP2kai): get_mtmfsk `fdc.mf = fdc.cmd & 0x40`; fdd_seeksector_common
// `if ((fdc.mf != 0xff) && (fdc.mf != 0x40))` -> failure (read and write of a raw image);
// fdd_readid_common `if ((!fdc.mf) || ...)` -> failure; searchsector_d88 with check `if
// ((fdc.mf != 0xff) && !((fdc.mf ^ mfm_flg) & 0x40)) break;` -> no sector; readsector and
// FDC_ReadID answer a failure with ST0 = IC0|hd<<2|us and ST1 = ND.
//
// FAIL-FIRST: with MF ignored M2, M3, R1 and R3 transfer bytes instead of answering ND, and
// with the D88 READ ID left unchecked (NP2kai's form) D2 answers a header.

`define IMGMAX 65536

module tb_pc9821_fdc_mf;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== the image: a D88 whose IDs do not name their own tracks ====
  //   index 0 (cyl 0 side 0): ID (0,0,1,3)          the boot track, IDs honest
  //   index 1 (cyl 0 side 1): ID (0,0,1,3)          side 1 written with H=0 IDs
  //   index 2 (cyl 1 side 0): ID (0,1,1,3)          cylinder 1 holding cylinder 0 side 1's IDs
  //   index 4 (cyl 2 side 0): ID (1,0,1,3)          cylinder 2 holding cylinder 1's IDs
  //   index 6 (cyl 3 side 0): ID (3,0,1,3)          honest again
  localparam integer A_T0 = 688;
  localparam integer A_T1 = A_T0 + 16 + 1024;
  localparam integer A_T2 = A_T1 + 16 + 1024;
  localparam integer A_T4 = A_T2 + 16 + 1024;
  localparam integer A_T6 = A_T4 + 16 + 1024;
  localparam integer A_BYTES = A_T6 + 16 + 1024;
  localparam integer B_BYTES = 0;

  reg [7:0] imgA [0:`IMGMAX-1];
  reg [7:0] imgB [0:`IMGMAX-1];
  reg [7:0] imgC [0:`IMGMAX-1];

  // A sector's bytes are a function of its PHYSICAL track index, so a read from the wrong
  // track is a byte mismatch.
  function automatic [7:0] pt(input integer trk, input integer j);
    pt = (j * 7 + trk * 37 + 5) & 8'hFF;
  endfunction

  task automatic put_track(input integer trk, input integer off, input [7:0] c, input [7:0] h,
                           input [7:0] mfm_flg);
    integer j;
    begin
      imgA[8'h20 + 4*trk + 0] = off[7:0];  imgA[8'h20 + 4*trk + 1] = off[15:8];
      imgA[8'h20 + 4*trk + 2] = 8'h00;     imgA[8'h20 + 4*trk + 3] = 8'h00;
      for (j = 0; j < 16; j = j + 1) imgA[off + j] = 8'h00;
      imgA[off+0] = c; imgA[off+1] = h; imgA[off+2] = 8'h01; imgA[off+3] = 8'h03;
      imgA[off+4] = 8'h01; imgA[off+5] = 8'h00;            // one sector on the track
      imgA[off+6] = mfm_flg;                               // 0x40 = FM, 0x00 = MFM
      imgA[off+14] = 8'h00; imgA[off+15] = 8'h04;          // 1024 bytes stored
      for (j = 0; j < 1024; j = j + 1) imgA[off + 16 + j] = pt(trk, j);
    end
  endtask

  task automatic build_image;
    integer j;
    begin
      for (j = 0; j < `IMGMAX; j = j + 1) begin imgA[j] = 8'h00; imgB[j] = 8'h00; imgC[j] = 8'h00; end
      imgA[8'h1B] = 8'h20;                                  // 2HD (DISKTYPE_2HD major 2)
      imgA[8'h1C] = A_BYTES[7:0];   imgA[8'h1D] = A_BYTES[15:8];
      imgA[8'h1E] = A_BYTES[23:16]; imgA[8'h1F] = A_BYTES[31:24];
      put_track(0, A_T0, 8'h00, 8'h00, 8'h40);   // FM, as a 2HD boot track
      put_track(1, A_T1, 8'h00, 8'h00, 8'h00);
      put_track(2, A_T2, 8'h00, 8'h01, 8'h00);
      put_track(4, A_T4, 8'h01, 8'h00, 8'h00);
      put_track(6, A_T6, 8'h03, 8'h00, 8'h00);
    end
  endtask

  // praw is referenced by the shared host model's helpers; no RAW image is mounted here.
  // The RAW image (drive 1): its bytes are a function of the file offset.
  localparam integer C_BYTES = 1261568;
  function automatic [7:0] praw(input integer off);
    praw = (off * 3 + 7) & 8'hFF;
  endfunction
  // ==== DUT ====
  // The real controller, the real medium, the real shared adapter.
  reg        cs = 0, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;

  wire [1:0]  fdd_present;         // one bit per DRIVE, from the media module
  wire [1:0]  fdd_wp;     // [u] the media module's write-protect state, one bit per drive
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx;
  wire [7:0] fdd_tc;   // the physical track (pc9821_fdc's media_tc)
  wire       fdd_hd;
  wire       fdd_mf;
  wire       fdd_2hd;
  wire       fdd_rpm;
  wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
  wire [7:0]  fdd_dout, fdd_hr, fdd_hn, fdd_hs;

  wire        blk_rd, blk_busy, blk_done, blk_error, blk_slot;
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr;
  wire [15:0] blk_fill_data;
  wire [31:0] dbg_hps_cycles;

  wire        dma_drq;
  reg         dma_dack = 0, dma_stb = 0, dma_tc = 0;
  wire [7:0]  dma_dout;

  pc9821_fdc fdc (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      // The controller's per-unit presence vector: drive 0 is bit 0, drive 1 is bit 1,
      // which is what gives an unmounted drive 1 its own no-media answer (U1/U5).
      .media_present({2'b00, fdd_present}), .writeprotect({2'b00, fdd_wp}),
      // No media-change tag: this bench's mounts are not ready changes (pc9821_fdc's media_chg).
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(fdd_req), .media_req_hdr(fdd_req_hdr), .media_unit(fdd_unit),
      .media_c(fdd_c), .media_h(fdd_h), .media_tc(fdd_tc), .media_hd(fdd_hd), .media_mf(fdd_mf), .media_2hd(fdd_2hd), .media_rpm(fdd_rpm), .media_r(fdd_r), .media_n(fdd_n),
      .media_idx(fdd_idx),
      .media_ready(fdd_ready), .media_rdy(fdd_rdy), .media_hdrv(fdd_hdrv),
      .media_err(fdd_err), .media_dout(fdd_dout),
      .media_hr(fdd_hr), .media_hn(fdd_hn), .media_hs(fdd_hs),
      .media_adv(fdd_adv),
      .dma_drq(dma_drq), .dma_dack(dma_dack), .dma_stb(dma_stb), .dma_tc(dma_tc),
      .dma_dout(dma_dout)
  );

  // The two drives' image slots, wired as pc9821_system wires them: `img_size` is ONE
  // hps_io register feeding BOTH slots (sys/hps_io.sv:130 (output reg [63:0] img_size,     // size of image in bytes. v)), which is why this bench has one
  // size register and two mount pulses - and why the mount tasks set it before each pulse.
  reg        mnt0 = 0, mnt1 = 0;
  reg [63:0] img_size = 0;

  pc9821_fdd_media media (
      .clk(clk), .reset(reset),
      .img_mounted(mnt0), .img_size(img_size), .img_readonly(1'b1),
      .img1_mounted(mnt1), .img1_size(img_size),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_slot(blk_slot),
      .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .present(fdd_present), .writeprotect(fdd_wp),
      .req(fdd_req), .req_hdr(fdd_req_hdr), .unit(fdd_unit),
      .req_c(fdd_c), .req_h(fdd_h), .req_tc(fdd_tc), .req_hd(fdd_hd), .req_mf(fdd_mf), .req_2hd(fdd_2hd), .req_rpm(fdd_rpm), .req_r(fdd_r), .req_n(fdd_n), .req_idx(fdd_idx),
      .ready(fdd_ready), .rdy(fdd_rdy), .hdrv(fdd_hdrv), .err(fdd_err),
      .dout(fdd_dout), .adv(fdd_adv),
      .hdr_r(fdd_hr), .hdr_n(fdd_hn), .hdr_sects(fdd_hs)
  );

  // ==== the HPS host model: both slots, one transfer at a time ====
  reg        sd_ack_b = 0, sd_ack_c = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] sd_lba_b, sd_lba_c;
  wire [ 5:0] sd_blk_cnt_b, sd_blk_cnt_c;
  wire        sd_rd_b, sd_wr_b, sd_rd_c, sd_wr_c;
  wire [15:0] sd_buff_din_b, sd_buff_din_c;

  pc9821_block_share share (
      // Slot D (the second hard disk): unmounted; every disk request is for slot A.




      .clk(clk), .rst_n(!reset),
      // the hard disk's slot: unmounted, no requests
      .a_img_mounted(1'b0), .a_img_readonly(1'b1), .a_img_size(64'd0),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(), .a_sd_blk_cnt(), .a_sd_rd(), .a_sd_wr(), .a_sd_ack(1'b0),
      .a_sd_buff_din(),
      // the floppy's ONE device port: drive 0 is slot B and drive 1 is slot C, told apart
      // by the drive tag the medium holds with its request (`blk_slot` -> b_req_slot)
      .b_img_mounted(mnt0), .b_img_readonly(1'b1), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_lba(blk_lba), .b_req_slot(blk_slot),
      .b_req_done(blk_done), .b_req_error(blk_error), .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_sd_lba(sd_lba_b), .b_sd_blk_cnt(sd_blk_cnt_b),
      .b_sd_rd(sd_rd_b), .b_sd_wr(sd_wr_b),
      .b_sd_ack(sd_ack_b), .b_sd_buff_din(sd_buff_din_b),
      .c_img_mounted(mnt1), .c_img_readonly(1'b1), .c_img_size(img_size),
      .c_sd_lba(sd_lba_c), .c_sd_blk_cnt(sd_blk_cnt_c),
      .c_sd_rd(sd_rd_c), .c_sd_wr(sd_wr_c),
      .c_sd_ack(sd_ack_c), .c_sd_buff_din(sd_buff_din_c),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // Which image a slot C handshake is answered from: 0 = imgB (the D88), 1 = imgC (the RAW
  // remount). Set by the mount sequence, exactly as the OSD's mount would pick a file.
  reg c_is_raw = 0;

  reg [12:0] widx, wtotal;
  reg [31:0] hlba;
  reg        hbusy, hlast;
  reg  [1:0] hwhich;

  task automatic word_for(input [1:0] which, input [31:0] lba, input [7:0] w,
                          output [15:0] v);
    integer base;
    begin
      base = lba * 512 + w * 2;
      if (which == 2'd0)      v = {imgA[base + 1], imgA[base]};
      else if (which == 2'd1) v = {imgB[base + 1], imgB[base]};
      else                    v = {praw(base + 1), praw(base)};
    end
  endtask

  always @(posedge clk) begin
    if (reset) begin
      sd_ack_b <= 1'b0; sd_ack_c <= 1'b0; sd_buff_wr <= 1'b0;
      hbusy <= 1'b0; hlast <= 1'b0; widx <= 13'd0; hwhich <= 2'd0;
    end else if (!hbusy) begin
      sd_buff_wr <= 1'b0;
      if (sd_rd_b) begin
        hbusy    <= 1'b1;
        sd_ack_b <= 1'b1;
        widx     <= 13'd0;
        hlba     <= sd_lba_b;
        hwhich   <= 2'd0;
        wtotal   <= ({7'd0, sd_blk_cnt_b} + 13'd1) * 13'd256 - 13'd1;
      end else if (sd_rd_c) begin
        hbusy    <= 1'b1;
        sd_ack_c <= 1'b1;
        widx     <= 13'd0;
        hlba     <= sd_lba_c;
        hwhich   <= c_is_raw ? 2'd2 : 2'd1;
        wtotal   <= ({7'd0, sd_blk_cnt_c} + 13'd1) * 13'd256 - 13'd1;
      end
    end else begin
      sd_buff_wr   <= 1'b1;
      sd_buff_addr <= widx;
      word_for(hwhich, hlba + {19'd0, widx[12:8]}, widx[7:0], sd_buff_dout);
      if (hlast) begin
        hbusy      <= 1'b0;
        sd_ack_b   <= 1'b0;
        sd_ack_c   <= 1'b0;
        sd_buff_wr <= 1'b0;
        hlast      <= 1'b0;
      end else if (widx == wtotal) begin
        hlast <= 1'b1;
      end else begin
        widx <= widx + 13'd1;
      end
    end
  end

  // ==== the DMA model: one strobe per DRQ, TC coincident with the final one ====
  reg [15:0] dm_left;
  reg        dm_run;
  integer    dm_n;
  reg  [7:0] dm_bytes [0:8191];

  reg armed;
  always @(posedge clk) begin
    dma_dack <= 1'b0;
    dma_stb  <= 1'b0;
    dma_tc   <= 1'b0;
    if (reset) begin
      dm_left <= 16'd0; dm_run <= 1'b0; dm_n = 0; armed <= 1'b0;
    end else if (armed) begin
      if (dm_n < 8192) dm_bytes[dm_n] = dma_dout;
      dm_n     = dm_n + 1;
      dm_left <= dm_left - 16'd1;
      if (dm_left == 16'd1) dm_run <= 1'b0;
      armed <= 1'b0;
    end else if (dm_run && dma_drq && (dm_left != 16'd0)) begin
      dma_dack <= 1'b1;
      dma_stb  <= 1'b1;
      dma_tc   <= (dm_left == 16'd1);
      armed    <= 1'b1;
    end
  end


  // ==== CHECKS ====
  integer fails = 0;
  integer i, n;
  initial begin
    #20_000_000_000;
    $fatal(1, "TB_PC9821_FDC_MF: watchdog timeout (no verdict reached)");
  end

  task automatic expect8(input [7:0] got, input [7:0] want, input [8*96-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  task automatic expecti(input integer got, input integer want, input [8*96-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, got, want);
        fails = fails + 1;
      end
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

  reg [7:0] g_rs [0:6];
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

  // A missing sector ends at the controller's second index pulse, up to two revolutions of the
  // slowest spindle (300 rpm) after the command: 2/5 s of the instance's SYS_CLOCK_HZ (the
  // module default, 50 MHz), plus slack (pc9821_fdc X_NDW; tb_pc9821_fdc_nd_search pins it).
  localparam integer ND_WAIT = 2 * (50_000_000 / 5) + 100_000;
  task automatic wait_irq(input integer maxc);
    begin
      n = 0;
      while (!irq && n < maxc) begin @(negedge clk); n = n + 1; end
      if (!irq) begin
        $display("  FAIL: interrupt never came");
        fails = fails + 1;
      end
    end
  endtask


  // READ DATA: opcode, then us|hd<<2, C, H, R, N, EOT, GPL, DTL (io/fdc.c:201-215).
  task automatic read_cmd(input [7:0] op, input [7:0] ushd,
                          input [7:0] c, input [7:0] h, input [7:0] r,
                          input [7:0] nn, input [7:0] eot);
    begin
      wr8(3'd1, op);
      wr8(3'd1, ushd); wr8(3'd1, c); wr8(3'd1, h); wr8(3'd1, r);
      wr8(3'd1, nn); wr8(3'd1, eot); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
    end
  endtask

  task automatic arm_dma(input integer bytes);
    begin
      dm_left = bytes[15:0]; dm_n = 0; dm_run = 1;
    end
  endtask

  // One drive's READ DATA of one 1024-byte sector (EOT = R, so the walk ends after it),
  // with the seven-byte result and the DMA count around it.
  task automatic read_one(input [1:0] us, input hd, input [7:0] c, input [7:0] h,
                          input [7:0] r, input [8*48-1:0] what);
    begin
      arm_dma(1024);
      read_cmd(8'h46, {5'd0, hd, us}, c, h, r, 8'h03, r);
      wait_irq(ND_WAIT);
      get_result;
      expecti(g_rlen, 7, {what, ": result length"});
      expect8(g_rs[0], {5'd0, hd, us}, {what, ": ST0 = hd<<2|us"});
      expect8(g_rs[1], 8'h00, {what, ": ST1"});
      expect8(g_rs[2], 8'h00, {what, ": ST2"});
      expect8(g_rs[3], c, {what, ": C"});
      expect8(g_rs[4], h, {what, ": H"});
      expect8(g_rs[5], 8'h01, {what, ": R forced to 1 by the terminal count"});
      expect8(g_rs[6], 8'h03, {what, ": N"});
      expecti(dm_n, 1024, {what, ": (N+1) bytes moved"});
    end
  endtask

  // A mount pulse on slot 1 (drive 0) or slot 2 (drive 1); `size` is the ONE hps_io
  // img_size both slots read, set immediately before the pulse as the framework does.
  task automatic mount0(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); mnt0 = 1;
      @(posedge clk);
      @(negedge clk); mnt0 = 0;
      repeat (4000) @(negedge clk);
    end
  endtask

  task automatic mount1(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); mnt1 = 1;
      @(posedge clk);
      @(negedge clk); mnt1 = 0;
      repeat (4000) @(negedge clk);
    end
  endtask


  // ==== STIMULUS ====
  task automatic check_track(input integer trk, input [8*48-1:0] what);
    integer k, bad;
    begin
      bad = 0;
      for (k = 0; k < 1024; k = k + 1)
        if (dm_bytes[k] !== pt(trk, k)) bad = bad + 1;
      if (bad != 0) begin
        $display("  FAIL: %0s: %0d of 1024 bytes are not physical track %0d's", what, bad, trk);
        fails = fails + 1;
      end
    end
  endtask
  // one sector, opcode op (0x06 FM / 0x46 MFM), expecting success or ND
  task automatic rd1(input [7:0] op, input [1:0] us, input hd, input [7:0] c, input [7:0] h,
                    input ok, input [8*48-1:0] what);
    begin
      arm_dma(1024);
      read_cmd(op, {5'd0, hd, us}, c, h, 8'h01, 8'h03, 8'h01);
      wait_irq(ND_WAIT);
      get_result;
      expecti(g_rlen, 7, {what, ": result length"});
      if (ok) begin
        expect8(g_rs[0], {5'd0, hd, us}, {what, ": ST0 normal"});
        expecti(dm_n, 1024, {what, ": a whole sector moved"});
      end else begin
        expect8(g_rs[0], 8'h40 | {5'd0, hd, us}, {what, ": ST0 = IC0|hd<<2|us"});
        expect8(g_rs[1], 8'h04, {what, ": ST1 = ND"});
        expecti(dm_n, 0, {what, ": no byte moved"});
      end
    end
  endtask
  task automatic readid(input [7:0] op, input [1:0] us, input ok, input [8*48-1:0] what);
    begin
      wr8(3'd1, op); wr8(3'd1, {6'd0, us});
      wait_irq(ND_WAIT);
      get_result;
      if (ok) begin
        expect8(g_rs[0], {6'd0, us}, {what, ": ST0 normal"});
        expect8(g_rs[5], 8'h01, {what, ": R = 1"});
        expect8(g_rs[6], 8'h03, {what, ": N = 3"});
      end else begin
        expect8(g_rs[0], 8'h40 | {6'd0, us}, {what, ": ST0 = IC0|us"});
        expect8(g_rs[1], 8'h04, {what, ": ST1 = ND"});
      end
    end
  endtask

  integer k2;
  initial begin
    build_image;
    reset = 1; repeat (6) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);
    mount0(A_BYTES);
    c_is_raw = 1;
    mount1(C_BYTES);
    expecti(fdd_present, 2'b11, "both drives present");

    // ---- D88 (drive 0): track 0 is FM, track 1 (side 1) is MFM ----
    rd1(8'h06, 2'd0, 1'b0, 8'h00, 8'h00, 1'b1, "M1 FM read of the FM sector");
    check_track(0, "M1 FM read of the FM sector");
    rd1(8'h46, 2'd0, 1'b0, 8'h00, 8'h00, 1'b0, "M2 MFM read of the FM sector");
    rd1(8'h06, 2'd0, 1'b1, 8'h00, 8'h00, 1'b0, "M3 FM read of an MFM sector");
    rd1(8'h46, 2'd0, 1'b1, 8'h00, 8'h00, 1'b1, "M4 MFM read of an MFM sector");
    check_track(1, "M4 MFM read of an MFM sector");

    // ---- D88 READ ID honours MF: FM on the FM track, MFM on the MFM track (side 1) ----
    readid(8'h0A, 2'd0, 1'b1, "D1 FM READ ID of the FM track");
    wr8(3'd1, 8'h0A); wr8(3'd1, 8'h04);          // FM READ ID, hd 1 (MFM track)
    wait_irq(ND_WAIT);
    get_result;
    expect8(g_rs[0], 8'h44, "D2 FM READ ID of an MFM track: ST0 = IC0|hd<<2");
    expect8(g_rs[1], 8'h04, "D2 FM READ ID of an MFM track: ST1 = ND");
    wr8(3'd1, 8'h4A); wr8(3'd1, 8'h04);          // MFM READ ID, hd 1
    wait_irq(ND_WAIT);
    get_result;
    expect8(g_rs[0], 8'h04, "D3 MFM READ ID of an MFM track: ST0 normal");
    expect8(g_rs[6], 8'h03, "D3 MFM READ ID of an MFM track: N = 3");

    // ---- raw (drive 1): MFM only ----
    rd1(8'h06, 2'd1, 1'b0, 8'h00, 8'h00, 1'b0, "R1 FM read of a raw image");
    rd1(8'h46, 2'd1, 1'b0, 8'h00, 8'h00, 1'b1, "R2 MFM read of a raw image");
    for (k2 = 0; k2 < 1024; k2 = k2 + 1)
      if (dm_bytes[k2] !== praw(k2)) begin
        if (fails < 40) $display("  FAIL: R2 raw byte %0d is %02x, the image holds %02x", k2, dm_bytes[k2], praw(k2));
        fails = fails + 1;
      end
    readid(8'h0A, 2'd1, 1'b0, "R3 FM READ ID of a raw image");
    readid(8'h4A, 2'd1, 1'b1, "R4 MFM READ ID of a raw image");

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDC_MF: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDC_MF: FAIL (%0d errors)", fails);
  end

endmodule
