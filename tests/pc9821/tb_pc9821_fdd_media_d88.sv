`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// pc9821_fdd_media reads a D88 and a raw sector image through the HPS block protocol and serves them over the byte seam pc9821_fdc drives: the D88 header is parsed where d88head.h puts its fields (fd_type at 0x1B, fd_size at 0x1C, trackp[164] at 0x20 as little-endian 32-bit offsets), a sector's file offset is found by walking the track's [16-byte _D88SEC][data] run and testing (c,h,r,n) as NP2kai's searchsector_d88 does, so a header that matches C/H/R with a different N is not the sector, a sector whose stored size is shorter than 128<<N still delivers the full 128<<N bytes with a ZERO tail, READ ID answers the requested ordinal with the track's own sector count, a raw image maps CHRN straight onto its geometry row's file offset and refuses an N that is not the row's N, and a missing sector, a missing track, an ordinal past the track's headers and an unknown image size are each reported as not available. The host side is a model of the MiSTer block reader: sd_ack held for the transfer, one 16-bit word per clk_sys at sd_buff_addr with (sd_blk_cnt+1) sectors per handshake. A RE-MOUNT MOVES THE MEDIUM, which is what lets the platform stop resetting the machine on a floppy change: mounting a second image of the same geometry answers the SECOND image's sector bytes (so neither a cached block nor a parsed track table may survive the swap), an eject - a mount of a sub-sector image - clears present and answers no byte out of the ejected medium, and remounting the first image serves it byte-exact again. THE RAW SIZE GUESSER IS NP2kai's fdd_xdf.c supportxdf rows (headersize 0) AND THE GEOMETRY IS PER DRIVE: the 512-byte rows (2DD 9x512 and 8x512, 2HD 15x512/18x512/21x512), the 256-byte 26x256 row and the 9x1024 row mount and each answers READ ID with ITS OWN N and sector count (fdd_readid_common, diskimage/fddfile.c:319-345) while refusing a request whose N is not the row's (fdd_read_xdf's 0xC0, fdd_xdf.c:341-343); the double-claimed 655,360-byte body answers the DD6 row's 8x512 geometry, fdd_set_xdf's first size match in table order (:41 before the same-sized DDB row :47, whose .ddb extension tiebreak :129-133 does not exist at this seam), and a D88 whose fd_type major is 2D or 2DD (0 or 1) mounts beside the 2HD classes and answers its geometry from the walked per-track headers (fdd_d88.c:92-118 takes majors 0/1/2). Each medium answers only in its own media mode (the controller's 0x00BE bit 1 and the unit's 0x04BE rpm bit): a 2DD class read in 2HD mode, a 2HD class in 2DD mode or a minor-0 2HD at 360 rpm misses (NP2kai fdd_d88.c d88trk_read, fddfile.c fdd_seeksector_common).
//
// pc9821_fdd_media reads a D88 and a raw sector image through the HPS block protocol and
// serves them over the byte seam pc9821_fdc drives, with every layout taken from NP2kai's
// own readers: the D88 header at fdd/d88head.h (fd_type at 0x1B, fd_size at 0x1C..0x1F,
// trackp[164] at 0x20 as little-endian 32-bit offsets), the per-track run of [16-byte
// _D88SEC][sector data] walked exactly as searchsector_d88 does (diskimage/fd/fdd_d88.c
// :220-258), the sector's stored size at the header's bytes 14-15 with the read returning
// min(128<<N, size) file bytes and ZEROES for the rest (:427-443), the (C<<1)|H track
// index (:369-373), and the raw geometry rows of diskimage/fd/fdd_xdf.c's supportxdf
// table (:20-74) with the ((((C*2+H) * sects) + R-1) << (7+N)) offset of fdd_read_xdf
// (:352-355) and its N-mismatch failure (:341-343).
//
// The host side is a model of the MiSTer block reader: hold sd_ack for the transfer, one
// 16-bit word per clk_sys at sd_buff_addr (slot = addr[10:8], word = addr[7:0]), (sd_blk_cnt+1)
// sectors per handshake exactly as hps_io presents it.
// ==== DUT ====
// ==== DUT ====

// Big enough for the WIDEST row of the raw guesser: fdd_xdf.c:35's DMF {0, 160, 21, 2,
// DISKTYPE_2HD, rpm 1} is 160 x 21 x 512 = 1,720,320 bytes, and the host model's image
// array must address every block a mounted image can name.
`define IMGMAX 1720320

module tb_pc9821_fdd_media_d88;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== the image: a synthetic D88 laid out byte by byte ====
  // 0x2B0 header, then track 0 with three sectors (R=1 1024 B, R=2 1024 B, R=3 256 B) and
  // track 1 with two (R=1, R=2, both 1024 B). fd_size is the exact end of track 1.
  localparam integer T0_OFF = 688;                 // 0x2B0
  localparam integer T1_OFF = T0_OFF + 16 + 1024 + 16 + 1024 + 16 + 256;   // 3040
  localparam integer IMG_BYTES = T1_OFF + 16 + 1024 + 16 + 1024;           // 5120

  reg [7:0] img [0:`IMGMAX-1];
  // Which pattern put_sec_data writes and check_sector expects: 0 = the first image, 1 = the
  // remounted one (D9/D10).
  reg       alt_image = 0;

  function automatic [7:0] secpat(input [7:0] r, input integer j);
    secpat = (j * 7 + r * 13) & 8'hFF;
  endfunction

  // The SECOND image's pattern (D9/D10): a remount must move the bytes the guest reads, so
  // the two media hold the same geometry and different data.
  function automatic [7:0] secpat2(input [7:0] r, input integer j);
    secpat2 = (j * 11 + r * 29 + 1) & 8'hFF;
  endfunction

  task automatic put_d88_header;
    integer t, j;
    begin
      for (j = 0; j < 688; j = j + 1) img[j] = 8'h00;
      img[8'h1A] = hdr_protect;               // protect: bit 4 (0x10) = write-protected
      // fd_type = 0x20. DISKTYPE_2HD is major 2 (NP2kai diskimage/fd/fddfile.h:42-44),
      // and MAME maps 0x20 to DSHD (d88_dsk.cpp:455-459); the one real D88 in this tree
      // carries this byte at 0x1B (../refs/X68000_MiSTer/releases/BLANK_disk_X68000.D88).
      // The old fixture wrote 0x30, "fd_type: DISKTYPE_2HD (major 3)" - a misconception
      // that made this bench pass against a container test carrying the same error;
      // the format's own byte is the
      // fixture's source, never what a model happens to expect.
      img[8'h1B] = 8'h20;
      img[8'h1C] = IMG_BYTES[7:0];            // fd_size, little-endian 32-bit
      img[8'h1D] = IMG_BYTES[15:8];
      img[8'h1E] = IMG_BYTES[23:16];
      img[8'h1F] = IMG_BYTES[31:24];
      for (t = 0; t < 164; t = t + 1) begin
        img[8'h20 + 4*t + 0] = 8'h00;
        img[8'h20 + 4*t + 1] = 8'h00;
        img[8'h20 + 4*t + 2] = 8'h00;
        img[8'h20 + 4*t + 3] = 8'h00;
      end
      img[8'h20 + 0] = T0_OFF[7:0];           // track 0 -> 0x2B0
      img[8'h20 + 1] = T0_OFF[15:8];
      img[8'h20 + 4] = T1_OFF[7:0];           // track 1 -> 0xBE0
      img[8'h20 + 5] = T1_OFF[15:8];
    end
  endtask

  task automatic put_sec_header(input integer off, input [7:0] c, h, r, nn,
                                input integer nsec, input integer size);
    begin
      img[off+0] = c; img[off+1] = h; img[off+2] = r; img[off+3] = nn;
      img[off+4] = nsec[7:0]; img[off+5] = nsec[15:8];
      img[off+6] = 8'h00;                     // mfm_flg: 0x00 = MFM, the mode these reads use (0x40 = FM, NP2kai searchsector_d88)
      img[off+7] = 8'h00; img[off+8] = 8'h00; img[off+9] = 8'h00;
      img[off+10] = 8'h00; img[off+11] = 8'h00; img[off+12] = 8'h00;
      img[off+13] = 8'h00;                    // rpm_flg
      img[off+14] = size[7:0]; img[off+15] = size[15:8];
    end
  endtask

  task automatic put_sec_data(input integer off, input [7:0] r, input integer size);
    integer j;
    reg [7:0] v;
    begin
      for (j = 0; j < size; j = j + 1) begin
        v = alt_image ? secpat2(r, j) : secpat(r, j);
        img[off + j] = v;
      end
    end
  endtask

  task automatic build_d88;
    begin
      put_d88_header;
      put_sec_header(T0_OFF + 0,    8'h00, 8'h00, 8'h01, 8'h03, 3, 1024);
      put_sec_data  (T0_OFF + 16,   8'h01, 1024);
      put_sec_header(T0_OFF + 1040, 8'h00, 8'h00, 8'h02, 8'h03, 3, 1024);
      put_sec_data  (T0_OFF + 1056, 8'h02, 1024);
      put_sec_header(T0_OFF + 2080, 8'h00, 8'h00, 8'h03, 8'h03, 3, 256);
      put_sec_data  (T0_OFF + 2096, 8'h03, 256);
      put_sec_header(T1_OFF + 0,    8'h00, 8'h01, 8'h01, 8'h03, 2, 1024);
      put_sec_data  (T1_OFF + 16,   8'h01, 1024);
      put_sec_header(T1_OFF + 1040, 8'h00, 8'h01, 8'h02, 8'h03, 2, 1024);
      put_sec_data  (T1_OFF + 1056, 8'h02, 1024);
    end
  endtask

  // ==== the HPS block reader ====
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
      img_word = {img[base + 1], img[base]};
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
      // The word is presented for the whole cycle. The LAST word needs its own cycle with
      // the handshake still up -- dropping sd_ack in the same edge would cancel the
      // presentation before the adapter ever saw the word.
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

  // ==== the DUT ====
  // The real pair: pc9821_fdd_media + the SHARED block adapter (T9). The floppy's image goes to
  // the share module's slot B; slot A - the hard disk's - is unmounted and asks for nothing, so
  // this run covers the floppy's whole path through the shared engine, hand-over included
  // (loading the engine with this image and flushing its read-ahead window before the first
  // fetch). Contention between the two slots is tb_pc9821_block_share's subject.
  reg        img_mounted = 0;
  // THE MOUNT'S READ-ONLY FLAG. It defaults to 1 here so every pre-existing arm keeps the
  // "this medium cannot be written" medium it was written against; the protect arms below set
  // it (and the header's own bit) explicitly. It is the MiSTer stand-in for the first term of
  // NP2kai's protect condition, diskimage/fd/fdd_d88.c:306.
  reg        img_readonly = 1;
  reg [63:0] img_size = 0;
  reg [7:0]  hdr_protect = 8'h00;    // the D88 header's byte 0x1A; bit 4 = write-protected
  wire       present;
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

  // The controller's media mode (0x00BE bit 1): 2HD except for the 2DD raw rows (D13, D14), which
  // NP2kai's fdd_seeksector_common serves only when CTRL_FDMEDIA is their own DISKTYPE_2DD.
  reg b_2hd = 1'b1;
  reg b_rpm = 1'b0;   // the unit's 0x04BE rpm bit: 1 for the 1.44 MB raw rows (D17)
  pc9821_fdd_media dut (
      .clk(clk), .reset(reset),
      .img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .present(present), .writeprotect(writeprotect),
      .req(req), .req_hdr(req_hdr), .unit(unit),
      .req_c(req_c), .req_h(req_h), .req_tc(req_c), .req_hd(req_h[0]), .req_mf(1'b1), .req_2hd(b_2hd), .req_rpm(b_rpm), .req_r(req_r), .req_n(req_n), .req_idx(req_idx),
      .ready(ready), .rdy(rdy), .hdrv(hdrv), .err(err), .dout(dout), .adv(adv),
      .hdr_r(hdr_r), .hdr_n(hdr_n), .hdr_sects(hdr_sects)
  );

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
      // the floppy's slot
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
    #400_000_000;
    $fatal(1, "TB_PC9821_FDD_MEDIA_D88: watchdog timeout (no verdict reached)");
  end

  task automatic expect8(input [7:0] g, input [7:0] w, input [8*40-1:0] what);
    begin
      if (g !== w) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, g, w);
        fails = fails + 1;
      end
    end
  endtask

  task automatic expecti(input integer g, input integer w, input [8*40-1:0] what);
    begin
      if (g !== w) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, g, w);
        fails = fails + 1;
      end
    end
  endtask

  // Mount `size` and give the header read time to complete; `present` is then checked by
  // the caller, because an unsupported image is a legitimate outcome (D8).
  task automatic mount(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); img_mounted = 1;
      @(posedge clk);
      @(negedge clk); img_mounted = 0;
      repeat (4000) @(negedge clk);
    end
  endtask

  // One request; then wait for the answer level.
  task automatic do_req(input integer hdr, input [1:0] u, input [7:0] c, hh, r, nn, idx);
    begin
      n = 0;
      while (!ready && n < 100000) begin @(negedge clk); n = n + 1; end
      @(negedge clk);
      req = 1; req_hdr = hdr[0]; unit = u;
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

  // Drain until the module is idle again. NOT `while (rdy)`: a block fetch in flight drops
  // rdy for hundreds of cycles mid-sector, which is the transfer PAUSING, not finishing.
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

  // A RAW body carries no headers: its sector data is the pattern at the row's own file
  // offset ((((C*2+H) * sects) + R-1) << (7+N)), fdd_xdf.c:352-355.
  task automatic put_raw_data(input integer off, input [7:0] r, input integer len);
    integer j;
    begin
      for (j = 0; j < len; j = j + 1) img[off + j] = secpat(r, j);
    end
  endtask

  // A raw sector delivers exactly 128<<N bytes of file data (no zero tail: the row's N IS
  // the sector size), so the check spans exactly the drained length.
  task automatic check_raw(input [7:0] r, input integer len);
    begin
      for (i = 0; i < len; i = i + 1) begin
        if (got[i] !== secpat(r, i)) begin
          $display("  FAIL: raw sector R=%0d byte %0d is %02x, the image holds %02x",
                   r, i, got[i], secpat(r, i));
          fails = fails + 1;
        end
      end
    end
  endtask

  task automatic check_sector(input [7:0] r, input integer size);
    reg [7:0] want;
    begin
      for (i = 0; i < 1024; i = i + 1) begin
        want = alt_image ? secpat2(r, i) : secpat(r, i);
        if (i < size) begin
          if (got[i] !== want) begin
            $display("  FAIL: sector R=%0d byte %0d is %02x, the image holds %02x",
                     r, i, got[i], want);
            fails = fails + 1;
          end
        end else if (got[i] !== 8'h00) begin
          $display("  FAIL: sector R=%0d byte %0d is %02x, the zero fill demands 00",
                   r, i, got[i]);
          fails = fails + 1;
        end
      end
    end
  endtask

  initial begin
    reset = 1;
    repeat (6) @(negedge clk);
    reset = 0;
    repeat (2) @(negedge clk);

    // ---------------- D1: a D88 is detected and its track table is parsed -------------
    build_d88;
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D1 present");
    // THE MEDIUM'S PROTECT STATE (Stage A), from the MOUNT's flag in this arm: the fixture's
    // header byte 0x1A is 0 and img_readonly is 1, which is NP2kai's second and first terms
    // respectively (diskimage/fd/fdd_d88.c:306).
    expect8(writeprotect[0], 1'b1, "D1 a read-only mount is write-protected");

    // ---------------- D1b: the D88 header's OWN protect bit, byte 0x1A bit 4 ---------
    // FAIL-FIRST: the model used to hardcode writeprotect = 1, so a flag-cleared read-write
    // mount still reported a protected medium. The arms below are NP2kai's composite condition
    // one term at a time: the header bit alone, neither, and a byte that is set but is not the
    // protect bit.
    reset = 1; repeat (4) @(negedge clk); reset = 0; repeat (2) @(negedge clk);
    hdr_protect = 8'h10;                     // the D88 header's protect bit, and only it
    img_readonly = 1'b0;                     // ... with the mount read-WRITE
    build_d88;
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D1b present");
    expect8(writeprotect[0], 1'b1, "D1b the header's protect bit 4 alone protects the medium");
    expect8(writeprotect[1], 1'b0, "D1b the other drive has no medium, so it is not protected");

    reset = 1; repeat (4) @(negedge clk); reset = 0; repeat (2) @(negedge clk);
    hdr_protect = 8'h00;
    img_readonly = 1'b0;
    build_d88;
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D1c present");
    expect8(writeprotect[0], 1'b0, "D1c neither source set: the medium reports WRITABLE");

    reset = 1; repeat (4) @(negedge clk); reset = 0; repeat (2) @(negedge clk);
    hdr_protect = 8'h80;                     // bit 7 is NOT the flag: the D88 uses bit 4 only
    mount(IMG_BYTES);
    expect8(writeprotect[0], 1'b0, "D1d a byte with another bit set is not protected");

    // Restore the fixture's own configuration for every arm that follows.
    hdr_protect = 8'h00;
    img_readonly = 1'b1;
    reset = 1; repeat (4) @(negedge clk); reset = 0; repeat (2) @(negedge clk);
    build_d88;
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D1e present (fixture restored)");
    expect8(writeprotect[0], 1'b1, "D1e protected again");

    // ---------------- D2: sector data, C=0 H=0 R=1 --------------------------------
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D2 no error");
    expect8(rdy, 1'b1, "D2 the byte is available");
    drain_bytes(4096);
    expecti(nget, 1024, "D2 a 1024-byte sector");
    check_sector(8'h01, 1024);
    expect8(ready, 1'b1, "D2 the module is idle again");

    // ---------------- D3: a sector on the OTHER SIDE of cylinder 0 -------------------
    // track index (C<<1)|H, so this is trackp[1] (fdd_d88.c:369-373).
    do_req(0, 2'd0, 8'h00, 8'h01, 8'h02, 8'h03, 8'h00);
    expect8(err, 1'b0, "D3 no error");
    drain_bytes(4096);
    expecti(nget, 1024, "D3 a 1024-byte sector");
    check_sector(8'h02, 1024);

    // ---------------- D4: a SHORT stored sector is zero-filled ----------------------
    // The header's size field is 256 while the read asks for 128<<3, and fdd_read_d88
    // returns min(size, 128<<N) file bytes with the rest ZERO (:427-443).
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h03, 8'h03, 8'h00);
    expect8(err, 1'b0, "D4 no error");
    drain_bytes(4096);
    expecti(nget, 1024, "D4 the full 128<<N is still delivered");
    check_sector(8'h03, 256);

    // ---------------- D5: a missing sector and a missing track are err ---------------
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h05, 8'h03, 8'h00);
    expect8(err, 1'b1, "D5 a sector not on the track is 'not found'");
    do_req(0, 2'd0, 8'h05, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b1, "D5 a track with no trackp entry is 'not found'");
    // ---------------- D5b: C/H/R on the track but a different N is not the sector --------
    // searchsector_d88 tests all four - `((D88SEC)p)->n == fdc.N` (fdd_d88.c:243) - so a
    // request for R=1 with N=2 on a track whose R=1 header carries N=3 finds nothing. (A
    // matcher that dropped the N term passed every other case here.)
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h02, 8'h00);
    expect8(err, 1'b1, "D5b a sector whose N differs is 'not found'");

    // ---------------- D6: READ ID's header walk -------------------------------------
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h00);
    expect8(hdrv, 1'b1, "D6 a header answer");
    expect8(hdr_r, 8'h01, "D6 header 0's R");
    expect8(hdr_n, 8'h03, "D6 header 0's N");
    expect8(hdr_sects, 8'd3, "D6 the track's sector count");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h02);
    expect8(hdr_r, 8'h03, "D6 header 2's R");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h07);
    expect8(err, 1'b1, "D6 an ordinal past the track's headers is 'not found'");

    // ---------------- D7: a RAW image maps CHRN straight onto a file offset ----------
    // 154 half-tracks x 8 sectors x 1024 B is NP2kai's fdd_xdf row {0,154,8,3,2HD,0}.
    for (i = 0; i < `IMGMAX; i = i + 1) img[i] = 8'h00;
    for (i = 0; i < 1024; i = i + 1) img[0 + i] = secpat(8'h01, i);              // C0 H0 R1
    for (i = 0; i < 1024; i = i + 1) img[7*1024 + i] = secpat(8'h02, i);         // C0 H0 R8
    for (i = 0; i < 1024; i = i + 1) img[16*1024 + i] = secpat(8'h03, i);        // C1 H0 R1
    mount(64'd1261568);
    expect8(present, 1'b1, "D7 raw 1261568 B is a supported 2HD geometry");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D7 no error");
    drain_bytes(4096);
    expecti(nget, 1024, "D7 a 1024-byte sector");
    check_sector(8'h01, 1024);
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h08, 8'h03, 8'h00);
    expect8(err, 1'b0, "D7 sector 8 no error");
    drain_bytes(4096);
    check_sector(8'h02, 1024);
    do_req(0, 2'd0, 8'h01, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D7 cylinder 1 no error");
    drain_bytes(4096);
    check_sector(8'h03, 1024);
    // The N mismatch is NP2kai's fdd_read_xdf failure (fdd_xdf.c:339-342).
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h02, 8'h00);
    expect8(err, 1'b1, "D7 a raw read with N != the geometry's N fails");
    // A raw READ ID is answered from the geometry (fdd_readid_common,
    // diskimage/fddfile.c:319-345: R = ++crcn, N = the geometry's N).
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h00);
    expect8(hdrv, 1'b1, "D7 a raw READ ID answer");
    expect8(hdr_r, 8'h01, "D7 raw header R");
    expect8(hdr_n, 8'h03, "D7 raw header N");

    // ---------------- D8: an unsupported size is simply not present ------------------
    mount(64'd12345);
    expect8(present, 1'b0, "D8 an unknown size is not a supported image");

    // ---------------- D8b: the latched-size ENCODING keeps the high half's zero test ----
    // The mount tuple is stored as {the high half is non-zero, the low word}, so a size ABOVE
    // 4 GiB whose low word IS a supported row must still be refused. 0x2_0000_0000 has bit 32
    // CLEAR and bits [63:32] set, so a truncation to `img_size[32:0]` (instead of the OR of the
    // high half) would answer present here - this arm is the encoding's contract, and the
    // 64-bit form this replaced refused it too.
    mount(64'h2_0000_0000 + 64'd1310720);
    expect8(present, 1'b0, "D8b a size above 4 GiB is not a supported image");

    // ---------------- D9: a MOUNT MOVES THE MEDIUM (no reset needed) -----------------
    // The rule is that changing a floppy must not reset the machine, so the guest
    // must see the new disk from the media side alone: the mount re-reads the header from
    // block 0 and every later request comes out of the new image. A cache or a parsed
    // header that survived the swap would answer the OLD bytes here.
    alt_image = 1'b1;
    build_d88;                             // same geometry, secpat2's data
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D9 the second image is present");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D9 no error after the remount");
    drain_bytes(4096);
    expecti(nget, 1024, "D9 a 1024-byte sector after the remount");
    check_sector(8'h01, 1024);
    do_req(0, 2'd0, 8'h00, 8'h01, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D9 trackp[1] is the NEW image's track table");
    drain_bytes(4096);
    check_sector(8'h01, 1024);
    // READ ID walks the new image's headers too (the sector count comes from the header).
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h01);
    expect8(hdrv, 1'b1, "D9 a header answer after the remount");
    expect8(hdr_r, 8'h02, "D9 the new image's header 1 R");

    // ---------------- D10: an EJECT clears the media, and the old medium is gone ------
    // hps_io signals an unmount as a mount of a sub-sector image (pc9821_block_io's own eject
    // test), and pc9821_fdd_media's ST_PARSE then finds no format. The requirement is that
    // `present` drops - the FDC's media_present follows it - and that no later request is
    // answered out of the ejected medium: the stale buffer must not be served as a disk.
    mount(64'd0);
    expect8(present, 1'b0, "D10 an eject clears present");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b1, "D10 a read after the eject is not available");
    expect8(rdy, 1'b0, "D10 and it serves no byte out of the ejected medium");

    // Remount the FIRST image: the medium comes back byte for byte.
    alt_image = 1'b0;
    build_d88;
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D10 the first image mounts again");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D10 no error after the eject/remount round trip");
    drain_bytes(4096);
    expecti(nget, 1024, "D10 a 1024-byte sector after the eject/remount");
    check_sector(8'h01, 1024);

    // ---------------- D11: the 0x30 fd_type TOLERANCE still mounts ----------------
    // Major 3 is NOT the format's 2HD code (MAME maps 0x30 to SSDD; NP2kai's D88 reader
    // rejects it), but it is accepted as a FLAGGED TOLERANCE for the PC-98 tooling that
    // writes it (see pc9821_fdd_media's container-test comment, and P1-b's decision note in
    // the report). This arm PINS the tolerance so it cannot disappear silently; the
    // reference-correct bytes are D1..D10's 0x20. Only the fd_type byte changes - the rest
    // of the mounted image is D10's, byte for byte.
    img[8'h1B] = 8'h30;
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D11 the 0x30 fd_type tolerance still mounts");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D11 no error under the tolerated major 3");
    drain_bytes(4096);
    expecti(nget, 1024, "D11 a 1024-byte sector under the tolerance");
    check_sector(8'h01, 1024);

    // ---------------- D12: a TRUNCATED D88 serves no byte past its extent -------------
    // P2-e. The sector header's stored `size` (1024) claims more than the DECLARED EXTENT
    // holds - fd_size = 768 = the 0x2B0 header + one 16-byte _D88SEC + 64 data bytes - while
    // the MOUNTED file is the larger 2048 and its bytes past the extent are non-zero. The
    // read must serve the 64 real bytes and ZERO the remainder (the same zero tail a short
    // header already gets, fdd_read_d88 :427-443), and it must NOT walk its block pointer
    // past the extent onto the file's bytes there.
    // PRE-CHANGE: file_left was min(128<<N, size) with no extent bound, so consume() walked
    // past img_left to file offsets 768..1727 - inside the 2048-byte mount, so every block
    // fetch was VALID and the emitted tail was the file's own 0x5A, not zero (and on a
    // smaller mount a rejected fetch would have marked the STALE buffer resident).
    for (i = 0; i < `IMGMAX; i = i + 1) img[i] = 8'h00;
    img[8'h1B] = 8'h20;                              // fd_type = DISKTYPE_2HD
    img[8'h1C] = 8'h00; img[8'h1D] = 8'h03;          // fd_size = 768
    img[8'h1E] = 8'h00; img[8'h1F] = 8'h00;
    img[8'h20 + 0] = 8'hB0; img[8'h20 + 1] = 8'h02;  // trackp[0] -> 0x2B0
    put_sec_header(T0_OFF + 0, 8'h00, 8'h00, 8'h01, 8'h03, 1, 1024);  // size > extent
    for (i = 0; i < 64;  i = i + 1) img[T0_OFF + 16 + i] = 8'hAA;     // the 64 real bytes
    for (i = 768; i < 2048; i = i + 1) img[i] = 8'h5A;               // past the extent
    mount(64'd2048);
    expect8(present, 1'b1, "D12 the truncated D88 still parses (extent inside the file)");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D12 no error");
    drain_bytes(4096);
    expecti(nget, 1024, "D12 the full 128<<N is still delivered");
    for (i = 0; i < 1024; i = i + 1) begin
      if (i < 64) begin
        if (got[i] !== 8'hAA) begin
          $display("  FAIL: D12 byte %0d is %02x, the image holds AA", i, got[i]);
          fails = fails + 1;
        end
      end else if (got[i] !== 8'h00) begin
        $display("  FAIL: D12 byte %0d is %02x; past the declared extent it must be 00",
                 i, got[i]);
        fails = fails + 1;
      end
    end

    // ---------------- D13: a 2DD 512-byte-sector raw body (Phase 2) ---------------------
    b_2hd = 1'b0;   // the controller in 2DD mode, as a 2DD medium needs (fdd_seeksector_common)
    // 160 half-tracks x 9 sectors x 512 B is NP2kai's fdd_xdf row {0, 160, 9, 2,
    // DISKTYPE_2DD, 0} (fdd_xdf.c:42, BKDSK(DD9) MS-DOS 720K(2DD)) - a size Phase 1
    // rejected outright (present = 0). EVERY expected value below is the REFERENCE's,
    // never this tree's RTL: READ ID answers R = ++crcn and N = the row's N with the row's
    // sector count as the ordinal's bound (fdd_readid_common, diskimage/fddfile.c:319-345),
    // a request whose N is not the row's fails with fdd_read_xdf's 0xC0
    // (diskimage/fd/fdd_xdf.c:341-343) and R past 1..sectors with
    // fdd_seeksector_common's 0xC0 (diskimage/fddfile.c:294-310).
    for (i = 0; i < `IMGMAX; i = i + 1) img[i] = 8'h00;
    put_raw_data(0,     8'h01, 512);   // C0 H0 R1
    put_raw_data(4096,  8'h02, 512);   // C0 H0 R9  (((0*2+0)*9 + 8) * 512)
    put_raw_data(9216,  8'h03, 512);   // C1 H0 R1  (((1*2+0)*9 + 0) * 512)
    mount(64'd737280);
    expect8(present, 1'b1, "D13 raw 737280 B mounts as 2DD 9x512");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00);
    expect8(hdrv, 1'b1, "D13 a raw READ ID answer");
    expect8(hdr_r, 8'h01, "D13 raw header R = ++crcn");
    expect8(hdr_n, 8'h02, "D13 raw header N = the row's N");
    expect8(hdr_sects, 8'd9, "D13 the row's sector count");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h02, 8'h08);
    expect8(hdr_r, 8'h09, "D13 raw header ordinal 8's R");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h02, 8'h09);
    expect8(err, 1'b1, "D13 an ordinal past the row's sectors is not found");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h02, 8'h00);
    expect8(err, 1'b0, "D13 no error");
    drain_bytes(4096);
    expecti(nget, 512, "D13 a 512-byte sector");
    check_raw(8'h01, 512);
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h09, 8'h02, 8'h00);
    expect8(err, 1'b0, "D13 R=9 no error");
    drain_bytes(4096);
    check_raw(8'h02, 512);
    do_req(0, 2'd0, 8'h01, 8'h00, 8'h01, 8'h02, 8'h00);
    expect8(err, 1'b0, "D13 cylinder 1 no error");
    drain_bytes(4096);
    check_raw(8'h03, 512);
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b1, "D13 N != the row's N fails (fdd_read_xdf 0xC0)");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h0A, 8'h02, 8'h00);
    expect8(err, 1'b1, "D13 R past 1..sectors fails (fdd_seeksector_common)");

    // ---------------- D14: 655,360 B takes the DD6 row's 8x512 geometry ----------------
    // The size is DOUBLE-CLAIMED in fdd_xdf.c: BKDSK(DD6) {0, 160, 8, 2, DISKTYPE_2DD}
    // (:41) and BKDSK(DDB) {0, 160, 16, 1, DISKTYPE_2DD} (:47) are both 655,360 bytes.
    // fdd_set_xdf scans the table IN ORDER and takes the first size match (:120-134), with
    // a .ddb-EXTENSION tiebreak that skips the 8-sector row (:129-133); the extension does
    // not exist at this seam, so the table-order first match stands and the DDB-shaped
    // request (256-byte sectors) is refused. This arm pins that choice.
    for (i = 0; i < `IMGMAX; i = i + 1) img[i] = 8'h00;
    put_raw_data(3584, 8'h04, 512);   // C0 H0 R8  (((0*2+0)*8 + 7) * 512)
    mount(64'd655360);
    expect8(present, 1'b1, "D14 raw 655360 B mounts");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00);
    expect8(hdrv, 1'b1, "D14 a raw READ ID answer");
    expect8(hdr_n, 8'h02, "D14 the DD6 row's N");
    expect8(hdr_sects, 8'd8, "D14 the DD6 sector count (8x512, not DDB's 16x256)");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h08, 8'h02, 8'h00);
    expect8(err, 1'b0, "D14 R=8 no error");
    drain_bytes(4096);
    expecti(nget, 512, "D14 a 512-byte sector");
    check_raw(8'h04, 512);
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h01, 8'h00);
    expect8(err, 1'b1, "D14 a DDB-shaped N=1 request is refused (the row is DD6)");

    // ---------------- D15: the 256-byte row (the 2D family) ----------------------------
    b_2hd = 1'b1;   // H01 is a 2HD row
    // 154 half-tracks x 26 sectors x 256 B is fdd_xdf.c:38-39's {0, 154, 26, 1,
    // DISKTYPE_2HD, 0} (BKDSK(H01) 2HD:256byte*26sec), N = 1.
    for (i = 0; i < `IMGMAX; i = i + 1) img[i] = 8'h00;
    put_raw_data(6400,  8'h05, 256);   // C0 H0 R26 (((0*2+0)*26 + 25) * 256)
    put_raw_data(13312, 8'h06, 256);   // C1 H0 R1  (((1*2+0)*26 +  0) * 256)
    mount(64'd1025024);
    expect8(present, 1'b1, "D15 raw 1025024 B mounts as 26x256");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00);
    expect8(hdrv, 1'b1, "D15 a raw READ ID answer");
    expect8(hdr_r, 8'h01, "D15 raw header R");
    expect8(hdr_n, 8'h01, "D15 raw header N = 1 (256-byte sectors)");
    expect8(hdr_sects, 8'd26, "D15 the row's sector count");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h1A, 8'h01, 8'h00);
    expect8(err, 1'b0, "D15 R=26 no error");
    drain_bytes(4096);
    expecti(nget, 256, "D15 a 256-byte sector");
    check_raw(8'h05, 256);
    do_req(0, 2'd0, 8'h01, 8'h00, 8'h01, 8'h01, 8'h00);
    expect8(err, 1'b0, "D15 cylinder 1 no error");
    drain_bytes(4096);
    check_raw(8'h06, 256);
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h02, 8'h00);
    expect8(err, 1'b1, "D15 N=2 against a 256-byte row fails (fdd_read_xdf 0xC0)");

    // ---------------- D16: the 2HD 512-byte row (1.21M) --------------------------------
    // {0, 160, 15, 2, DISKTYPE_2HD, 0} (fdd_xdf.c:26-27, BKDSK(HD5) MS-DOS 1.21M(2HC)).
    for (i = 0; i < `IMGMAX; i = i + 1) img[i] = 8'h00;
    put_raw_data(7168,  8'h07, 512);   // C0 H0 R15 (((0*2+0)*15 + 14) * 512)
    put_raw_data(15360, 8'h08, 512);   // C1 H0 R1  (((1*2+0)*15 +  0) * 512)
    mount(64'd1228800);
    expect8(present, 1'b1, "D16 raw 1228800 B mounts as 15x512");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00);
    expect8(hdrv, 1'b1, "D16 a raw READ ID answer");
    expect8(hdr_n, 8'h02, "D16 raw header N");
    expect8(hdr_sects, 8'd15, "D16 the row's sector count");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h0F, 8'h02, 8'h00);
    expect8(err, 1'b0, "D16 R=15 no error");
    drain_bytes(4096);
    expecti(nget, 512, "D16 a 512-byte sector");
    check_raw(8'h07, 512);
    do_req(0, 2'd0, 8'h01, 8'h00, 8'h01, 8'h02, 8'h00);
    expect8(err, 1'b0, "D16 cylinder 1 no error");
    drain_bytes(4096);
    check_raw(8'h08, 512);

    // ---------------- D17: the rest of the guesser's headersize-0 rows ------------------
    // 1.44M {0, 160, 18, 2, DISKTYPE_2HD, rpm 1} (fdd_xdf.c:33-34), MS 2HD-DMF
    // {0, 160, 21, 2, DISKTYPE_2HD, rpm 1} (:35) and MS-DOS 2HD(9sec) {0, 154, 9, 3,
    // DISKTYPE_2HD, 0} (:40). Each mounts and answers READ ID with its own N and sector
    // count; each is served only at its row's rpm (fdd_xdf.c's 6th column, tested by
    // fdd_seeksector_common / fdd_readid_common `fdc.rpm[fdc.us] != fdd->inf.xdf.rpm`).
    b_rpm = 1'b1;
    mount(64'd1474560);
    expect8(present, 1'b1, "D17 raw 1474560 B mounts as 18x512");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00);
    expect8(hdrv, 1'b1, "D17 a raw READ ID answer");
    expect8(hdr_n, 8'h02, "D17 18x512 header N");
    expect8(hdr_sects, 8'd18, "D17 18x512 sector count");
    mount(64'd1720320);
    expect8(present, 1'b1, "D17 raw 1720320 B mounts as the DMF 21x512 row");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00);
    expect8(hdrv, 1'b1, "D17 a raw READ ID answer");
    expect8(hdr_n, 8'h02, "D17 21x512 header N");
    expect8(hdr_sects, 8'd21, "D17 21x512 sector count");
    b_rpm = 1'b0;
    mount(64'd1419264);
    expect8(present, 1'b1, "D17 raw 1419264 B mounts as 9x1024");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h00);
    expect8(hdrv, 1'b1, "D17 a raw READ ID answer");
    expect8(hdr_n, 8'h03, "D17 9x1024 header N");
    expect8(hdr_sects, 8'd9, "D17 9x1024 sector count");

    // ---------------- D18: the D88 2D and 2DD fd_types mount (Phase 2) -----------------
    // NP2kai's D88 reader takes fdtype_major 0/1/2 - DISKTYPE_2D/2DD/2HD
    // (diskimage/fddfile.h:42-44); its switch answers "not found" for every other major
    // (fdd_d88.c:92-118) - and answers each track's geometry from the walked _D88SEC
    // headers. PRE-CHANGE: the container test took major 2 (and the flagged 3 tolerance)
    // only, so a 2D/2DD D88 answered present = 0. Only the fd_type byte changes here; the
    // image is D1's, byte for byte (alt_image is 0). The controller is in 2DD mode for them
    // (0x00BE bit 1 clear), the only mode a 2D/2DD class answers in (D19).
    b_2hd = 1'b0;
    build_d88;
    img[8'h1B] = 8'h00;                              // fd_type = DISKTYPE_2D (major 0)
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D18 a 2D fd_type (major 0) mounts");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h00);
    expect8(hdrv, 1'b1, "D18 a header answer under major 0");
    expect8(hdr_n, 8'h03, "D18 the walked header's N");
    expect8(hdr_sects, 8'd3, "D18 the walked track's sector count");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D18 no error under major 0");
    drain_bytes(4096);
    expecti(nget, 1024, "D18 a 1024-byte sector under major 0");
    check_sector(8'h01, 1024);
    img[8'h1B] = 8'h10;                              // fd_type = DISKTYPE_2DD (major 1)
    mount(IMG_BYTES);
    expect8(present, 1'b1, "D18 a 2DD fd_type (major 1) mounts");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h01);
    expect8(hdrv, 1'b1, "D18 a header answer under major 1");
    expect8(hdr_r, 8'h02, "D18 the walked header's R");
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h03, 8'h03, 8'h00);
    expect8(err, 1'b0, "D18 no error under major 1");
    drain_bytes(4096);
    expecti(nget, 1024, "D18 the full 128<<N under major 1");
    check_sector(8'h03, 256);

    // ---------------- D19: a medium answers only in its own media mode ----------------
    // NP2kai d88trk_read (diskimage/fd/fdd_d88.c): the 2DD arm `if ((rpm) || (type !=
    // DISKTYPE_2DD)) goto dtrd_err1;`, the 2HD arm `if (CTRL_FDMEDIA != DISKTYPE_2HD) goto
    // dtrd_err1;` and, minor 0, `if ((fdd->inf.d88.fdtype_minor == 0) && (rpm)) goto
    // dtrd_err1;`; the raw reader's fdd_seeksector_common `(CTRL_FDMEDIA !=
    // fdd->inf.xdf.disktype) || (fdc.rpm[fdc.us] != fdd->inf.xdf.rpm)` -> failure; and
    // fdd_readid_common the same for READ ID. A failure is "no sector" (err). So a 2DD disk read
    // with the controller in 2HD mode misses - the BIOS boot's cue to try the other mode.
    // PRE-CHANGE: the medium ignored the mode and answered in both.
    b_2hd = 1'b1;                                    // the 2DD D88 (major 1) above, in 2HD mode
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h03, 8'h03, 8'h00);
    expect8(err, 1'b1, "D19 a 2DD D88 read in 2HD mode misses");
    do_req(1, 2'd0, 8'h00, 8'h00, 8'h00, 8'h03, 8'h00);
    expect8(err, 1'b1, "D19 a 2DD D88 READ ID in 2HD mode misses");
    img[8'h1B] = 8'h20;                              // the same image as a 2HD D88
    mount(IMG_BYTES);
    b_2hd = 1'b0;
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b1, "D19 a 2HD D88 read in 2DD mode misses");
    b_2hd = 1'b1;
    b_rpm = 1'b1;
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b1, "D19 a minor-0 2HD D88 read at 360 rpm (1.44 MB mode) misses");
    b_rpm = 1'b0;
    do_req(0, 2'd0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expect8(err, 1'b0, "D19 the 2HD D88 in its own mode reads");
    drain_bytes(4096);

  // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_MEDIA_D88: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_MEDIA_D88: FAIL (%0d errors)", fails);
  end

endmodule
