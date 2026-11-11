`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDD_MEDIA_FDI: pc9821_fdd_media mounts an Anex86 FDI floppy image directly with NP2kai's fdd_set_fdi acceptance (diskimage/fd/fdd_xdf.c): a header of eight little-endian 32-bit fields (dummy, fddtype, headersize, fddsize, sectorsize, sectors, surfaces, cylinders) whose sectorsize is a power of two, sectors 1..255, surfaces 2, cylinders 1..127, fddtype's high nibble a 2HD, 2DD or 1.44 MB type and whose file size is exactly headersize + sectorsize * sectors * 2 * cylinders mounts with the header's own geometry, and every sector is served from headersize + fdd_read_xdf's raw offset ((C*2+H) * sectors + R-1) << (7+N): a 2HD 77-cylinder 8x1024 FDI and the library's 81-cylinder 9x1024 geometry (cylinder 80 included) read byte-exact at their first, middle and last sectors behind a 4096-byte header, a 512-byte header moves the body to block 1 and a 66,048-byte one to block 129; READ ID answers R = ordinal + 1, the header's N and its sector count on several tracks; a cylinder, R or READ ID ordinal past the header's geometry and an N that is not its N are refused; a 2DD FDI answers only in 2DD mode and a 1.44 MB FDI only at rpm 1; a file one block longer or shorter than the header says, surfaces 1, sectors 0, a sectorsize of 768, cylinders 128 and an unknown fddtype do not mount, nor (the core's own restriction, left to tools/fdconv.py) a 2D FDI that NP2kai mounts but can never read or a header that is not a whole number of 512-byte blocks; and a headerless raw image of the 1,261,568-byte size row - plain, or with an FDI header whose size equation the file does not satisfy - still mounts as that row and reads from offset 0, while a raw size of no row is still refused.
//
// pc9821_fdd_media mounts an Anex86 FDI floppy image directly. Every expected value is the
// FORMAT's, by construction, as NP2kai's reader defines it (diskimage/fd/fdd_xdf.c):
//   * the header is FDIHDR (:76-86), eight little-endian 32-bit fields - dummy, fddtype,
//     headersize, fddsize, sectorsize, sectors, surfaces, cylinders - at bytes 0, 4, ... 28;
//   * fdd_set_fdi accepts a power-of-two sectorsize with `(size & 0x7f80)` set, sectors
//     1..255, surfaces == 2, cylinders 1..127 (:212-216), a file size of exactly
//     `headersize + (size * sectors * surfaces * cylinders)` (:217), and an `fddtype & 0xf0`
//     of 0x10/0x70/0xf0 (2DD), 0x30/0xb0 (2HD, rpm 1), 0x50/0xd0 (2D) or 0x90 (2HD) (:228-251);
//     the geometry is tracks = cylinders * 2, the sector count and N = log2(size) - 7;
//   * fdd_read_xdf reads a sector at ((((C*2+H) * sectors) + R-1) << (7+N)) + headersize
//     (:352-356), refuses an N that is not the geometry's (:341-343), and its
//     fdd_seeksector_common refuses a track at or past tracks >> 1, an R outside 1..sectors and
//     a media mode / rpm that is not the disk's (diskimage/fddfile.c); fdd_readid_common
//     answers R = ++crcn and N = the geometry's N.
// The image bytes are a function of their FILE offset (pat below), so a sector served from the
// wrong offset - the header not skipped, a wrong block, a wrong track stride - shows.
// The core's own restriction (the FDI section of pc9821_fdd_media): a headersize that is not a
// whole number of 512-byte blocks is not mounted (tools/fdconv.py converts such an image); the
// 2D types, which NP2kai mounts but can never read (CTRL_FDMEDIA is only 2HD or 2DD, io/fdc.c),
// are not mounted either.
//
// The host side is tb_pc9821_fdd_media_d88's model of the MiSTer block reader.

// The library's FDI geometry, 4096 + 81 x 2 x 9 x 1024 = 1,497,088 bytes, is the largest image.
`define IMGMAX 1500000

module tb_pc9821_fdd_media_fdi;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg [7:0] img [0:`IMGMAX-1];

  // A byte of the file at offset `off`: distinct across the header, sectors and blocks.
  function automatic [7:0] pat(input integer off);
    pat = (off[7:0] + off[15:8] * 8'd3 + off[23:16] * 8'd7 + 8'h5A) & 8'hFF;
  endfunction

  task automatic put32(input integer at, input [31:0] v);
    begin
      img[at + 0] = v[7:0];   img[at + 1] = v[15:8];
      img[at + 2] = v[23:16]; img[at + 3] = v[31:24];
    end
  endtask

  // An FDI per FDIHDR: the whole file is the offset pattern, then the 32 header bytes.
  integer fdi_bytes;
  task automatic build_fdi(input [31:0] fddtype, input [31:0] hsize, input [31:0] secsize,
                           input [31:0] spt, input [31:0] surf, input [31:0] cyl);
    integer j;
    begin
      fdi_bytes = hsize + secsize * spt * surf * cyl;
      for (j = 0; j < `IMGMAX; j = j + 1) img[j] = pat(j);
      put32(0,  32'd0);                         // dummy
      put32(4,  fddtype);
      put32(8,  hsize);
      put32(12, secsize * spt * surf * cyl);    // fddsize (NP2kai does not test it)
      put32(16, secsize);
      put32(20, spt);
      put32(24, surf);
      put32(28, cyl);
    end
  endtask

  // ==== the HPS block reader (tb_pc9821_fdd_media_d88's model) ====
  reg        sd_ack = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] sd_lba;
  wire        sd_rd, sd_wr;
  wire [5:0]  sd_blk_cnt;
  wire [15:0] sd_buff_din;

  reg [12:0] widx, wtotal;
  reg [31:0] hlba;
  reg        hbusy, hlast;

  function automatic [15:0] img_word(input [31:0] lba, input [7:0] w);
    integer base;
    begin
      base = lba * 512 + w * 2;
      if (base + 1 < `IMGMAX) img_word = {img[base + 1], img[base]};
      else                    img_word = 16'h0000;
    end
  endfunction

  always @(posedge clk) begin
    if (reset) begin
      sd_ack <= 1'b0; sd_buff_wr <= 1'b0; hbusy <= 1'b0; hlast <= 1'b0; widx <= 13'd0;
    end else if (!hbusy) begin
      sd_buff_wr <= 1'b0;
      if (sd_rd) begin
        hbusy  <= 1'b1;
        sd_ack <= 1'b1;
        widx   <= 13'd0;
        hlba   <= sd_lba;
        wtotal <= ({7'd0, sd_blk_cnt} + 13'd1) * 13'd256 - 13'd1;
      end
    end else begin
      sd_buff_wr   <= 1'b1;
      sd_buff_addr <= widx;
      sd_buff_dout <= img_word(hlba + {19'd0, widx[12:8]}, widx[7:0]);
      if (hlast) begin
        hbusy      <= 1'b0;
        sd_ack     <= 1'b0;
        sd_buff_wr <= 1'b0;
        hlast      <= 1'b0;
      end else if (widx == wtotal) begin
        hlast <= 1'b1;
      end else begin
        widx <= widx + 13'd1;
      end
    end
  end

  // ==== DUT ====
  // pc9821_fdd_media + the shared block adapter, drive 0 only.
  reg        img_mounted = 0;
  reg        img_readonly = 1;
  reg [63:0] img_size = 0;
  wire [1:0] present;
  wire [1:0] writeprotect;
  reg        req = 0, req_hdr = 0, adv = 0;
  reg [1:0]  unit = 0;
  reg [7:0]  req_c = 0, req_h = 0, req_r = 0, req_n = 0, req_idx = 0;
  wire       ready, rdy, hdrv, err;
  wire [7:0] dout, hdr_r, hdr_n, hdr_sects;

  wire        blk_rd, blk_busy, blk_done, blk_error;
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr;
  wire [15:0] blk_fill_data;
  wire [31:0] dbg_hps_cycles;

  reg b_2hd = 1'b1;   // the controller's 0x00BE bit 1 (CTRL_FDMEDIA 2HD)
  reg b_rpm = 1'b0;   // the unit's 0x04BE rpm bit (1.44 MB mode)
  pc9821_fdd_media dut (
      .clk(clk), .reset(reset),
      .img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
      .img1_mounted(1'b0), .img1_size(64'd0),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_slot(), .blk_done(blk_done),
      .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .blk_req_wr(), .blk_rd_addr(8'd0), .blk_rd_data(),
      .present(present), .writeprotect(writeprotect), .chg(),
      .req(req), .req_hdr(req_hdr), .req_wr(1'b0), .abort(1'b0), .unit(unit),
      .req_c(req_c), .req_h(req_h), .req_tc(req_c), .req_hd(req_h[0]), .req_mf(1'b1),
      .req_2hd(b_2hd), .req_rpm(b_rpm), .req_r(req_r), .req_n(req_n), .req_idx(req_idx),
      .ready(ready), .rdy(rdy), .hdrv(hdrv), .err(err), .dout(dout), .adv(adv), .din(8'h00),
      .hdr_r(hdr_r), .hdr_n(hdr_n), .hdr_sects(hdr_sects)
  );

  pc9821_block_share share (
      .clk(clk), .rst_n(!reset),
      .a_img_mounted(1'b0), .a_img_readonly(1'b1), .a_img_size(64'd0),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(), .a_sd_blk_cnt(), .a_sd_rd(), .a_sd_wr(), .a_sd_ack(1'b0),
      .a_sd_buff_din(),
      .b_img_mounted(img_mounted), .b_img_readonly(img_readonly), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_lba(blk_lba),
      .b_req_done(blk_done), .b_req_error(blk_error), .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_sd_lba(sd_lba), .b_sd_blk_cnt(sd_blk_cnt), .b_sd_rd(sd_rd), .b_sd_wr(sd_wr),
      .b_sd_ack(sd_ack), .b_sd_buff_din(sd_buff_din),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // ==== CHECKS ====
  integer fails = 0;
  integer i, n;
  reg [7:0] got [0:4095];
  integer   nget;

  initial begin
    #900_000_000;
    $fatal(1, "TB_PC9821_FDD_MEDIA_FDI: watchdog timeout (no verdict reached)");
  end

  task automatic expect8(input [7:0] g, input [7:0] w, input [8*48-1:0] what);
    begin
      if (g !== w) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, g, w);
        fails = fails + 1;
      end
    end
  endtask

  task automatic expecti(input integer g, input integer w, input [8*48-1:0] what);
    begin
      if (g !== w) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, g, w);
        fails = fails + 1;
      end
    end
  endtask

  task automatic mount(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); img_mounted = 1;
      @(posedge clk);
      @(negedge clk); img_mounted = 0;
      repeat (8000) @(negedge clk);
    end
  endtask

  task automatic do_req(input integer hdr, input [7:0] c, hh, r, nn, idx);
    begin
      n = 0;
      while (!ready && n < 100000) begin @(negedge clk); n = n + 1; end
      @(negedge clk);
      req = 1; req_hdr = hdr[0]; unit = 2'd0;
      req_c = c; req_h = hh; req_r = r; req_n = nn; req_idx = idx;
      @(posedge clk);
      @(negedge clk); req = 0;
      nget = 0;
      n = 0;
      while (!rdy && !hdrv && !err && n < 200000) begin @(negedge clk); n = n + 1; end
      if (!rdy && !hdrv && !err) begin
        $display("  FAIL: request never answered (hdr=%0d C=%02x H=%02x R=%02x N=%02x idx=%0d)",
                 hdr[0], c, hh, r, nn, idx);
        fails = fails + 1;
      end
    end
  endtask

  task automatic drain_bytes(input integer maxb);
    begin
      n = 0;
      while ((nget < maxb) && !err && !ready && n < 400000) begin
        n = n + 1;
        if (rdy) begin
          got[nget] = dout;
          nget = nget + 1;
          adv = 1'b1;
          @(posedge clk);
          @(negedge clk); adv = 1'b0;
        end
        @(negedge clk);
      end
    end
  endtask

  // READ DATA of (C,H,R,N) on a geometry of `spt` sectors behind a `hsize`-byte header: the
  // sector is the file's bytes at hsize + ((((C*2+H) * spt) + R-1) << (7+N)) (fdd_xdf.c
  // :352-356), all 128 << N of them.
  task automatic read_check(input integer hsize, input integer spt, input [7:0] c, hh, r, nn,
                            input [8*48-1:0] what);
    integer base, len, bad;
    begin
      len  = 128 << nn;
      base = hsize + ((((c * 2 + hh) * spt) + r - 1) << (7 + nn));
      do_req(0, c, hh, r, nn, 8'h00);
      expect8(err, 1'b0, what);
      drain_bytes(4096);
      expecti(nget, len, what);
      bad = 0;
      for (i = 0; i < len; i = i + 1)
        if (got[i] !== img[base + i]) begin
          if (bad < 4)
            $display("  FAIL: %0s: byte %0d is %02x, the file holds %02x at %0d",
                     what, i, got[i], img[base + i], base + i);
          bad = bad + 1;
        end
      if (bad != 0) fails = fails + 1;
    end
  endtask

  // READ ID ordinal `idx` on track (C,H): fdd_readid_common's R = ++crcn, N = the geometry's N;
  // hdr_sects is the header's sector count.
  task automatic readid_check(input [7:0] c, hh, idx, input [7:0] wn, input [7:0] ws,
                              input [8*48-1:0] what);
    begin
      do_req(1, c, hh, 8'h00, wn, idx);
      expect8(hdrv, 1'b1, what);
      expect8(hdr_r, idx + 8'd1, what);
      expect8(hdr_n, wn, what);
      expect8(hdr_sects, ws, what);
    end
  endtask

  initial begin
    reset = 1;
    repeat (6) @(negedge clk);
    reset = 0;
    repeat (2) @(negedge clk);

    // ---------------- F1: a 2HD FDI, 77 cylinders x 2 x 8 x 1024, 4096-byte header ---------
    // fddtype 0x90 = 2HD at rpm 0 (fdd_xdf.c :245). File = 4096 + 1,261,568 = 1,265,664 bytes,
    // which is no size row (the pre-change medium answered present = 0).
    build_fdi(32'h90, 32'd4096, 32'd1024, 32'd8, 32'd2, 32'd77);
    mount(fdi_bytes);
    expect8(present[0], 1'b1, "F1 a 77x8x1024 FDI mounts");
    read_check(4096, 8, 8'd0,  8'd0, 8'd1, 8'd3, "F1 C0 H0 R1 is the first body sector");
    read_check(4096, 8, 8'd0,  8'd1, 8'd8, 8'd3, "F1 C0 H1 R8");
    read_check(4096, 8, 8'd40, 8'd0, 8'd5, 8'd3, "F1 C40 H0 R5");
    read_check(4096, 8, 8'd76, 8'd1, 8'd8, 8'd3, "F1 C76 H1 R8 is the file's last sector");
    readid_check(8'd0,  8'd0, 8'd0, 8'd3, 8'd8, "F1 READ ID C0 H0 ordinal 0");
    readid_check(8'd40, 8'd1, 8'd7, 8'd3, 8'd8, "F1 READ ID C40 H1 ordinal 7");
    readid_check(8'd76, 8'd1, 8'd3, 8'd3, 8'd8, "F1 READ ID C76 H1 ordinal 3");
    do_req(0, 8'd77, 8'd0, 8'd1, 8'd3, 8'd0);
    expect8(err, 1'b1, "F1 cylinder 77 is past the header's 77 cylinders");
    do_req(0, 8'd0, 8'd0, 8'd9, 8'd3, 8'd0);
    expect8(err, 1'b1, "F1 R9 is past the header's 8 sectors");
    do_req(0, 8'd0, 8'd0, 8'd1, 8'd2, 8'd0);
    expect8(err, 1'b1, "F1 N2 is not the header's N3");
    do_req(1, 8'd0, 8'd0, 8'd0, 8'd3, 8'd8);
    expect8(err, 1'b1, "F1 READ ID ordinal 8 is past the track's 8");
    b_2hd = 1'b0;
    do_req(0, 8'd0, 8'd0, 8'd1, 8'd3, 8'd0);
    expect8(err, 1'b1, "F1 a 2HD FDI read in 2DD mode misses");
    b_2hd = 1'b1;

    // ---------------- F2: the library's geometry, 81 cylinders x 2 x 9 x 1024 --------------
    // 4096 + 1,492,992 = 1,497,088 bytes. Cylinder 80 is inside the header's geometry
    // (tracks = 162, fdd_seeksector_common's treg < tracks >> 1 = 81).
    build_fdi(32'h90, 32'd4096, 32'd1024, 32'd9, 32'd2, 32'd81);
    mount(fdi_bytes);
    expect8(present[0], 1'b1, "F2 an 81x9x1024 FDI mounts");
    read_check(4096, 9, 8'd0,  8'd0, 8'd1, 8'd3, "F2 C0 H0 R1");
    read_check(4096, 9, 8'd0,  8'd0, 8'd9, 8'd3, "F2 C0 H0 R9");
    read_check(4096, 9, 8'd39, 8'd1, 8'd4, 8'd3, "F2 C39 H1 R4");
    read_check(4096, 9, 8'd79, 8'd1, 8'd9, 8'd3, "F2 C79 H1 R9");
    read_check(4096, 9, 8'd80, 8'd0, 8'd1, 8'd3, "F2 C80 H0 R1 (cylinder 80)");
    read_check(4096, 9, 8'd80, 8'd1, 8'd9, 8'd3, "F2 C80 H1 R9 is the file's last sector");
    readid_check(8'd0,  8'd1, 8'd8, 8'd3, 8'd9, "F2 READ ID C0 H1 ordinal 8");
    readid_check(8'd80, 8'd1, 8'd8, 8'd3, 8'd9, "F2 READ ID C80 H1 ordinal 8");
    do_req(0, 8'd81, 8'd0, 8'd1, 8'd3, 8'd0);
    expect8(err, 1'b1, "F2 cylinder 81 is past the header's 81 cylinders");
    do_req(1, 8'd81, 8'd0, 8'd0, 8'd3, 8'd0);
    expect8(err, 1'b1, "F2 READ ID on cylinder 81 misses");
    do_req(0, 8'd0, 8'd0, 8'd10, 8'd3, 8'd0);
    expect8(err, 1'b1, "F2 R10 is past the header's 9 sectors");

    // ---------------- F3: a 2DD FDI (0x10) and a 1.44 MB FDI (0x30), 512-byte sectors -------
    // 0x10 is DISKTYPE_2DD at rpm 0, 0x30 is 2HD at rpm 1 (fdd_xdf.c :229-238); each answers
    // only in its own mode (fdd_seeksector_common's CTRL_FDMEDIA / rpm test).
    build_fdi(32'h10, 32'd4096, 32'd512, 32'd8, 32'd2, 32'd80);
    mount(fdi_bytes);
    expect8(present[0], 1'b1, "F3 an 80x8x512 2DD FDI mounts");
    do_req(0, 8'd0, 8'd0, 8'd1, 8'd2, 8'd0);
    expect8(err, 1'b1, "F3 a 2DD FDI read in 2HD mode misses");
    b_2hd = 1'b0;
    read_check(4096, 8, 8'd0,  8'd0, 8'd1, 8'd2, "F3 2DD C0 H0 R1");
    read_check(4096, 8, 8'd79, 8'd1, 8'd8, 8'd2, "F3 2DD C79 H1 R8 (last)");
    readid_check(8'd10, 8'd0, 8'd2, 8'd2, 8'd8, "F3 2DD READ ID C10 H0 ordinal 2");
    b_2hd = 1'b1;
    build_fdi(32'h30, 32'd4096, 32'd512, 32'd18, 32'd2, 32'd80);
    mount(fdi_bytes);
    expect8(present[0], 1'b1, "F3 an 80x18x512 1.44 MB FDI mounts");
    do_req(0, 8'd0, 8'd0, 8'd1, 8'd2, 8'd0);
    expect8(err, 1'b1, "F3 a 1.44 MB FDI read at rpm 0 misses");
    b_rpm = 1'b1;
    read_check(4096, 18, 8'd0,  8'd0, 8'd18, 8'd2, "F3 1.44 C0 H0 R18");
    read_check(4096, 18, 8'd79, 8'd1, 8'd18, 8'd2, "F3 1.44 C79 H1 R18 (last)");
    b_rpm = 1'b0;

    // ---------------- F4: a header of another whole-block size ---------------------------
    // headersize 512: the body begins at block 1 (NP2kai adds any headersize, :356).
    build_fdi(32'h90, 32'd512, 32'd1024, 32'd8, 32'd2, 32'd77);
    mount(fdi_bytes);
    expect8(present[0], 1'b1, "F4 a 512-byte-header FDI mounts");
    read_check(512, 8, 8'd0,  8'd0, 8'd1, 8'd3, "F4 C0 H0 R1 at 512");
    read_check(512, 8, 8'd76, 8'd1, 8'd8, 8'd3, "F4 C76 H1 R8 at 512");
    // headersize 65,536 + 512 (blocks 129): a header above 64 KiB moves the body past
    // headersize's bits 16 and up, which the 4096- and 512-byte headers never set.
    build_fdi(32'h90, 32'd66048, 32'd1024, 32'd8, 32'd2, 32'd77);
    mount(fdi_bytes);
    expect8(present[0], 1'b1, "F4 a 66,048-byte-header FDI mounts");
    read_check(66048, 8, 8'd0,  8'd0, 8'd1, 8'd3, "F4 C0 H0 R1 at 66048");
    read_check(66048, 8, 8'd76, 8'd1, 8'd8, 8'd3, "F4 C76 H1 R8 at 66048");

    // ---------------- F5: refusals ---------------------------------------------------------
    // The size equation is exact (:217): one block more or less is not an FDI.
    build_fdi(32'h90, 32'd4096, 32'd1024, 32'd8, 32'd2, 32'd77);
    mount(fdi_bytes + 512);
    expect8(present[0], 1'b0, "F5 a file one block longer than the header says");
    mount(fdi_bytes - 512);
    expect8(present[0], 1'b0, "F5 a file one block shorter than the header says");
    // surfaces must be 2 (:213), whatever the size: a header saying 1 on a file of the
    // two-surface size (a test of surfaces itself, not of the size equation).
    build_fdi(32'h90, 32'd4096, 32'd1024, 32'd8, 32'd1, 32'd77);
    mount(fdi_bytes + 1024 * 8 * 77);
    expect8(present[0], 1'b0, "F5 surfaces 1 is refused");
    // fddtype & 0xf0 outside the switch (:250 default) and the 2D types (core restriction).
    build_fdi(32'h20, 32'd4096, 32'd1024, 32'd8, 32'd2, 32'd77);
    mount(fdi_bytes);
    expect8(present[0], 1'b0, "F5 fddtype 0x20 is refused");
    build_fdi(32'h50, 32'd4096, 32'd256, 32'd16, 32'd2, 32'd40);
    mount(fdi_bytes);
    expect8(present[0], 1'b0, "F5 a 2D FDI (0x50) is not mounted");
    // sectors 0 (:212) and a sectorsize that is not a power of two (:212).
    build_fdi(32'h90, 32'd4096, 32'd1024, 32'd0, 32'd2, 32'd77);
    mount(fdi_bytes);
    expect8(present[0], 1'b0, "F5 sectors 0 is refused");
    build_fdi(32'h90, 32'd4096, 32'd768, 32'd8, 32'd2, 32'd77);
    mount(fdi_bytes);
    expect8(present[0], 1'b0, "F5 sectorsize 768 is refused");
    // cylinders 128 (:214), with the 4096 + 1,048,576-byte file it implies (no size row).
    build_fdi(32'h90, 32'd4096, 32'd256, 32'd16, 32'd2, 32'd128);
    mount(fdi_bytes);
    expect8(present[0], 1'b0, "F5 cylinders 128 is refused");
    // A header that is not a whole number of blocks (core restriction, left to fdconv).
    build_fdi(32'h90, 32'd4000, 32'd1024, 32'd8, 32'd2, 32'd77);
    mount(fdi_bytes);
    expect8(present[0], 1'b0, "F5 a 4000-byte header is not mounted");

    // ---------------- F6: a headerless raw image is unchanged ------------------------------
    // A 1,261,568-byte body is the {0,154,8,3,2HD,0} row (fdd_xdf.c :30), and its sector C0 H0
    // R1 is file offset 0 - even when its first 32 bytes are an FDI header (77x8x1024, 4096)
    // whose size equation the file does not satisfy (1,261,568 != 1,265,664).
    build_fdi(32'h90, 32'd4096, 32'd1024, 32'd8, 32'd2, 32'd77);
    mount(64'd1261568);
    expect8(present[0], 1'b1, "F6 the 1,261,568-byte raw row still mounts");
    read_check(0, 8, 8'd0,  8'd0, 8'd1, 8'd3, "F6 raw C0 H0 R1 from offset 0");
    read_check(0, 8, 8'd76, 8'd1, 8'd8, 8'd3, "F6 raw C76 H1 R8 (last)");
    for (i = 0; i < 32; i = i + 1) img[i] = pat(i);   // and a plain body, no header at all
    mount(64'd1261568);
    expect8(present[0], 1'b1, "F6 a plain raw body mounts");
    read_check(0, 8, 8'd40, 8'd0, 8'd3, 8'd3, "F6 plain raw C40 H0 R3");
    // ... and a raw image of no row is still refused.
    mount(64'd1265664);
    expect8(present[0], 1'b0, "F6 a raw size of no row (no FDI header) is refused");

    // ---------------- F7: back to an FDI after the raw mounts ------------------------------
    // The header offset is per mount: an FDI after a raw image reads past its header again.
    build_fdi(32'h90, 32'd4096, 32'd1024, 32'd9, 32'd2, 32'd81);
    mount(fdi_bytes);
    expect8(present[0], 1'b1, "F7 the 81-cylinder FDI mounts again");
    read_check(4096, 9, 8'd80, 8'd1, 8'd9, 8'd3, "F7 C80 H1 R9");

  // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_MEDIA_FDI: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_MEDIA_FDI: FAIL (%0d errors)", fails);
  end

endmodule
