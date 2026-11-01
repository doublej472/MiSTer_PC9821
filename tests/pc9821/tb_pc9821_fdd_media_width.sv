// tb_pc9821_fdd_media_width — the floppy medium's size arithmetic at the top of its range and over it.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDD_MEDIA_WIDTH:
// The floppy medium decides what it serves from sizes, and every size test gives the same answer at the TOP of its range as at the bottom, against the bench's own arithmetic and a synthetic image whose bytes are a function of their file offset: a D88 whose declared extent is exactly D88_MAX_EXTENT (2,000,000) mounts and reads a sector that ends 472 bytes before it back byte-exact, while an extent one byte over, 2^21, 2^21+688, 2^24+2,000,000, 2^31 and 0xFFFFFFFF each refuse to mount (no format matches); an extent beyond the file (5,000 against a 4,999-byte file) is refused and the same extent against a 5,000-byte and a 3,000,000-byte file is served; a track pointer at or past the extent, one byte short of it, 2^21+688, 2^24+688 and 0xFFFFFFFF each answer sector-not-found, and a first-track pointer at or past the extent or of 2^21 and up refuses the mount; and a raw body mounts exactly when its size is one of NP2kai's size rows - the 1,228,800 (15x512), 1,720,320 (21x512, the widest), 1,025,024 (26x256) and 1,261,568 (8x1024) rows - and not at the row size less one, plus one, plus 2^21 or plus 2^32, each served row returning its last sector (the farthest file offset of the row) byte-exact.

`define PAT(a) (((a) * 7 + ((a) >> 9) * 3 + 1) & 8'hFF)

module tb_pc9821_fdd_media_width;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== the image: bytes as a function of the file offset ====
  reg [7:0]  hdr [0:687];     // the D88 header being tested
  reg        raw_mode = 0;    // a raw body: every byte past the (zero) head is the pattern
  // The unit's 0x04BE rpm bit: a raw 18- or 21-sector row is a 1.44 MB medium, served only at
  // rpm 1 (NP2kai fdd_xdf.c rows HD4/DMF carry rpm 1; fdd_seeksector_common `fdc.rpm[fdc.us] !=
  // fdd->inf.xdf.rpm` -> failure).
  reg        b_rpm = 0;
  integer    sec_off = 0;     // the one D88 sector header's file offset
  reg [7:0]  sechdr [0:15];
  wire [31:0] alias_off = (sec_off[31:0] & 32'h001FFFFF) < 32'd688 ? 32'h7FFFFFFF : (sec_off[31:0] & 32'h001FFFFF);

  function automatic [7:0] byte_at(input [31:0] a);
    begin
      if (raw_mode) byte_at = (a < 32'd688) ? 8'h00 : `PAT(a);
      else if (a < 32'd688) byte_at = hdr[a];
      else if (a >= sec_off[31:0] && a < sec_off[31:0] + 32'd16) byte_at = sechdr[a - sec_off[31:0]];
      else if (a >= sec_off[31:0] + 32'd16 && a < sec_off[31:0] + 32'd528) byte_at = `PAT(a);
      // The same sector again where a pointer wrapped at 2^21 would land: a pointer of 2^21+688
      // read as its low 21 bits would FIND a sector (and serve the wrong bytes) instead of
      // answering not-found, so the fixture makes that aliasing observable.
      else if (a >= alias_off && a < alias_off + 32'd16) byte_at = sechdr[a - alias_off];
      else if (a >= alias_off + 32'd16 && a < alias_off + 32'd528) byte_at = ~`PAT(a);
      else byte_at = 8'h00;
    end
  endfunction

  function automatic [15:0] img_word(input [31:0] lba, input [7:0] w);
    reg [31:0] base;
    begin
      base = lba * 32'd512 + {23'd0, w, 1'b0};
      img_word = {byte_at(base + 32'd1), byte_at(base)};
    end
  endfunction

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
  reg        img_mounted = 0;
  reg [63:0] img_size = 0;
  wire [1:0] present;
  wire [1:0] writeprotect;
  reg        req = 0, req_hdr = 0, adv = 0;
  reg [7:0]  req_c = 0, req_h = 0, req_r = 0, req_n = 0, req_idx = 0;
  wire       ready, rdy, hdrv, err;
  wire [7:0] dout, hdr_r, hdr_n, hdr_sects;
  wire        blk_rd, blk_busy, blk_done, blk_error;
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr;
  wire [15:0] blk_fill_data;
  wire [31:0] dbg_hps_cycles;

  pc9821_fdd_media dut (
      .clk(clk), .reset(reset),
      .img_mounted(img_mounted), .img_size(img_size), .img_readonly(1'b1),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .present(present), .writeprotect(writeprotect),
      .req(req), .req_hdr(req_hdr), .unit(2'd0),
      .req_c(req_c), .req_h(req_h), .req_tc(req_c), .req_hd(req_h[0]), .req_mf(1'b1), .req_2hd(1'b1), .req_rpm(b_rpm), .req_r(req_r), .req_n(req_n), .req_idx(req_idx),
      .ready(ready), .rdy(rdy), .hdrv(hdrv), .err(err), .dout(dout), .adv(adv),
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
      .b_img_mounted(img_mounted), .b_img_readonly(1'b1), .b_img_size(img_size),
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
  integer checks = 0;
  integer n, nget, i;
  reg [7:0] got [0:1023];

  initial begin
    #900_000_000;
    $fatal(1, "TB_PC9821_FDD_MEDIA_WIDTH: watchdog timeout (no verdict reached)");
  end

  task automatic mount(input [63:0] size);
    begin
      reset = 1; repeat (4) @(negedge clk); reset = 0; repeat (2) @(negedge clk);
      img_size = size;
      @(negedge clk); img_mounted = 1;
      @(posedge clk);
      @(negedge clk); img_mounted = 0;
      repeat (4000) @(negedge clk);
    end
  endtask

  task automatic do_req(input [7:0] c, hh, r, nn);
    begin
      n = 0;
      while (!ready && n < 100000) begin @(negedge clk); n = n + 1; end
      @(negedge clk);
      req = 1; req_hdr = 0;
      req_c = c; req_h = hh; req_r = r; req_n = nn; req_idx = 0;
      @(posedge clk);
      @(negedge clk); req = 0;
      nget = 0;
      n = 0;
      while (!rdy && !err && n < 400000) begin @(negedge clk); n = n + 1; end
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

  task automatic expect_present(input [255:0] what, input want);
    begin
      checks = checks + 1;
      if (present[0] !== want) begin
        $display("  FAIL: %0s: present=%0d, want %0d", what, present[0], want);
        fails = fails + 1;
      end
    end
  endtask

  // ---- a D88 with extent `fdsz`, first-track pointer `p0`, the track-2 pointer `p2` ----
  task automatic build_d88(input [31:0] fdsz, input [31:0] p0, input [31:0] p2);
    integer j;
    begin
      raw_mode = 0;
      b_rpm = 0;
      for (j = 0; j < 688; j = j + 1) hdr[j] = 8'h00;
      hdr[8'h1B] = 8'h20;
      hdr[8'h1C] = fdsz[7:0]; hdr[8'h1D] = fdsz[15:8]; hdr[8'h1E] = fdsz[23:16]; hdr[8'h1F] = fdsz[31:24];
      hdr[8'h20] = p0[7:0];   hdr[8'h21] = p0[15:8];   hdr[8'h22] = p0[23:16];   hdr[8'h23] = p0[31:24];
      hdr[8'h28] = p2[7:0];   hdr[8'h29] = p2[15:8];   hdr[8'h2A] = p2[23:16];   hdr[8'h2B] = p2[31:24];
      // the sector C=1 H=0 R=1 N=2 (512 bytes) of track 2, wherever p2 puts it
      sec_off = p2;
      sechdr[0] = 8'd1; sechdr[1] = 8'd0; sechdr[2] = 8'd1; sechdr[3] = 8'd2;
      sechdr[4] = 8'd1; sechdr[5] = 8'd0; sechdr[6] = 8'h00;   // mfm_flg 0x00 = MFM, the mode req_mf names (0x40 = FM, NP2kai searchsector_d88)
      for (j = 7; j < 14; j = j + 1) sechdr[j] = 8'h00;
      sechdr[14] = 8'h00; sechdr[15] = 8'h02;
    end
  endtask

  // The sector of track 2 reads back byte-exact (want_ok) or is answered not-found.
  task automatic read_trk2(input [255:0] what, input want_ok);
    begin
      do_req(8'd1, 8'd0, 8'd1, 8'd2);
      checks = checks + 1;
      if (want_ok) begin
        if (err) begin $display("  FAIL: %0s: sector refused", what); fails = fails + 1; end
        else begin
          drain_bytes(512);
          for (i = 0; i < 512; i = i + 1)
            if (got[i] !== `PAT(sec_off + 16 + i)) begin
              $display("  FAIL: %0s: byte %0d is %02x, the image holds %02x", what, i, got[i], `PAT(sec_off + 16 + i));
              fails = fails + 1;
              i = 512;
            end
        end
      end else if (!err) begin
        $display("  FAIL: %0s: a sector past the extent was served", what);
        fails = fails + 1;
        drain_bytes(512);
      end
    end
  endtask

  task automatic d88_case(input [255:0] what, input [31:0] fdsz, input [63:0] fsize,
                          input [31:0] p0, input [31:0] p2, input want_present, input want_read);
    begin
      build_d88(fdsz, p0, p2);
      mount(fsize);
      expect_present(what, want_present);
      if (want_present) read_trk2(what, want_read);
    end
  endtask

  // ---- a raw body: the row's size mounts; its last sector reads back from the farthest offset ----
  task automatic raw_case(input [255:0] what, input [31:0] size, input integer tracks,
                          input integer sects, input integer nn);
    integer tr, off, len;
    begin
      raw_mode = 1;
      b_rpm = (sects == 18) || (sects == 21);
      mount({32'd0, size});
      expect_present(what, 1'b1);
      tr = tracks - 1;
      do_req(tr[8:1], {7'd0, tr[0]}, sects[7:0], nn[7:0]);
      len = 128 << nn;
      off = ((tr * sects) + sects - 1) << (7 + nn);
      checks = checks + 1;
      if (err) begin $display("  FAIL: %0s: last sector refused", what); fails = fails + 1; end
      else begin
        drain_bytes(len);
        for (i = 0; i < len; i = i + 1)
          if (got[i] !== `PAT(off + i)) begin
            $display("  FAIL: %0s: last-sector byte %0d is %02x, the image holds %02x", what, i, got[i], `PAT(off + i));
            fails = fails + 1;
            i = len;
          end
      end
    end
  endtask

  task automatic raw_absent(input [255:0] what, input [63:0] size);
    begin
      raw_mode = 1;
      mount(size);
      expect_present(what, 1'b0);
    end
  endtask

  initial begin
    reset = 1;
    repeat (6) @(negedge clk);
    reset = 0;
    repeat (2) @(negedge clk);

    // ---- the D88 extent: D88_MAX_EXTENT is in, everything over it is out ----
    d88_case("extent 2,000,000",      32'd2000000, 64'd2000000, 32'd688, 32'd1999000, 1, 1);
    d88_case("extent 2,000,000 big file", 32'd2000000, 64'd3000000, 32'd688, 32'd1999000, 1, 1);
    d88_case("extent 2,000,001",      32'd2000001, 64'd2000001, 32'd688, 32'd1999000, 0, 0);
    d88_case("extent 2^21",           32'h00200000, 64'h00200000, 32'd688, 32'd1999000, 0, 0);
    d88_case("extent 2^21+688",       32'h00200000 + 32'd688, 64'd3000000, 32'd688, 32'd1999000, 0, 0);
    d88_case("extent 2^24+2,000,000", 32'h01000000 + 32'd2000000, 64'd30000000, 32'd688, 32'd1999000, 0, 0);
    d88_case("extent 2^31",           32'h80000000, 64'd3000000, 32'd688, 32'd1999000, 0, 0);
    d88_case("extent 0xFFFFFFFF",     32'hFFFFFFFF, 64'd3000000, 32'd688, 32'd1999000, 0, 0);
    d88_case("extent 687",            32'd687, 64'd5000, 32'd688, 32'd688, 0, 0);
    // the extent against the file
    d88_case("extent 5,000, file 4,999", 32'd5000, 64'd4999, 32'd688, 32'd688, 0, 0);
    d88_case("extent 5,000, file 5,000", 32'd5000, 64'd5000, 32'd688, 32'd688, 1, 1);
    d88_case("extent 5,000, file 3,000,000", 32'd5000, 64'd3000000, 32'd688, 32'd688, 1, 1);

    // ---- the track pointers ----
    d88_case("pointer = extent",      32'd2000000, 64'd2000000, 32'd688, 32'd2000000, 1, 0);
    d88_case("pointer = extent-1",    32'd2000000, 64'd2000000, 32'd688, 32'd1999999, 1, 0);
    d88_case("pointer 2^21+688",      32'd2000000, 64'd2000000, 32'd688, 32'h00200000 + 32'd688, 1, 0);
    d88_case("pointer 2^24+688",      32'd2000000, 64'd2000000, 32'd688, 32'h01000000 + 32'd688, 1, 0);
    d88_case("pointer 0xFFFFFFFF",    32'd2000000, 64'd2000000, 32'd688, 32'hFFFFFFFF, 1, 0);
    d88_case("pointer 0",             32'd2000000, 64'd2000000, 32'd688, 32'd0, 1, 0);
    d88_case("first pointer = extent", 32'd2000000, 64'd2000000, 32'd2000000, 32'd1999000, 0, 0);
    d88_case("first pointer 2^21",    32'd2000000, 64'd2000000, 32'h00200000, 32'd1999000, 0, 0);
    d88_case("first pointer 2^24",    32'd2000000, 64'd2000000, 32'h01000000, 32'd1999000, 0, 0);
    d88_case("first pointer 0",       32'd2000000, 64'd2000000, 32'd0, 32'd1999000, 0, 0);

    // ---- raw rows: the size is the whole test, and the widest row's far end must be reachable ----
    raw_case("raw 15x512 (1,228,800)",  32'd1228800, 160, 15, 2);
    raw_case("raw 21x512 (1,720,320)",  32'd1720320, 160, 21, 2);
    raw_case("raw 26x256 (1,025,024)",  32'd1025024, 154, 26, 1);
    raw_case("raw 8x1024 (1,261,568)",  32'd1261568, 154,  8, 3);
    raw_absent("raw 1,720,319",         64'd1720319);
    raw_absent("raw 1,720,321",         64'd1720321);
    raw_absent("raw 1,720,320 + 2^21",  64'd1720320 + 64'h200000);
    raw_absent("raw 1,720,320 + 2^32",  64'd1720320 + 64'h100000000);
    raw_absent("raw 1,228,800 + 2^32",  64'd1228800 + 64'h100000000);

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("  %0d checks", checks);
      $display("TB_PC9821_FDD_MEDIA_WIDTH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_MEDIA_WIDTH: FAIL (%0d errors)", fails);
  end

endmodule
