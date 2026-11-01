`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The floppy medium's accept-time raw offset (FD-a: the raw image's ((C*2+H)*sects + R-1) << (7+N) formed from the request's live fields and the accepting drive's geometry and latched on the accept edge, instead of formed from the request latches inside ST_SEEK) is cycle-for-cycle identical to the pre-change module (pc9821_fdd_media_ref.sv, the module as of ad9ed84c): over random raw images of every NP2kai size row and a D88 image on both drives, random READ DATA / READ ID / WRITE / FORMAT requests with in-range and out-of-range C/H/R/N, requests for an empty drive, remounts and ejects landing mid-request, aborts, read-only mounts, failed and slow block fetches and core resets, every output (the block request, LBA, slot and write flag, the write-back read data, present/writeprotect/chg, ready/rdy/hdrv/err, dout and the READ ID answer) matches on every clk cycle.

// The reference is the pre-change TEXT, not a model of the hardware: this bench proves the
// restructure did not change behaviour. The medium's behaviour itself is pinned by
// tb_pc9821_fdd_media_d88 / _width / _change (NP2kai's fdd_xdf.c rows and d88 layout); the
// offset arithmetic alone is proven equal for every input by tools/equiv/fdd_raw_off.sv.

`define PAT(s, a) (((a) * 13 + ((a) >> 9) * 5 + (s) * 101 + 7) & 8'hFF)

// ==== DUT ====
// pc9821_fdd_media vs pc9821_fdd_media_ref, every input shared; the block backend below
// answers the DUT's requests (the reference's are compared equal every cycle).
module tb_pc9821_fdd_media_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg        reset = 1;
  reg        img_mounted = 0, img1_mounted = 0, img_readonly = 0;
  reg [63:0] img_size = 0, img1_size = 0;
  reg        blk_done = 0, blk_err = 0, blk_busy = 0, blk_fill_we = 0;
  reg  [7:0] blk_fill_addr = 0, blk_rd_addr = 0;
  reg [15:0] blk_fill_data = 0;
  reg        req = 0, req_hdr = 0, req_wr = 0, abort = 0, adv = 0;
  reg  [1:0] unit = 0;
  reg  [7:0] req_c = 0, req_h = 0, req_r = 0, req_n = 0, req_idx = 0, din = 0;

  `define FDD_OUTS(p) \
    wire p``_blk_req_rd, p``_blk_slot, p``_blk_req_wr, p``_ready, p``_rdy, p``_hdrv, p``_err; \
    wire [15:0] p``_blk_req_lba, p``_blk_rd_data; wire [1:0] p``_present, p``_writeprotect, p``_chg; \
    wire [7:0] p``_dout, p``_hdr_r, p``_hdr_n, p``_hdr_sects;
  `FDD_OUTS(d)
  `FDD_OUTS(r)
  `define FDD_PORTS(p) \
      .clk(clk), .reset(reset), .img_mounted(img_mounted), .img_size(img_size), \
      .img1_mounted(img1_mounted), .img1_size(img1_size), .img_readonly(img_readonly), \
      .blk_req_rd(p``_blk_req_rd), .blk_req_lba(p``_blk_req_lba), .blk_slot(p``_blk_slot), \
      .blk_done(blk_done), .blk_err(blk_err), .blk_busy(blk_busy), .blk_fill_we(blk_fill_we), \
      .blk_fill_addr(blk_fill_addr), .blk_fill_data(blk_fill_data), .blk_req_wr(p``_blk_req_wr), \
      .blk_rd_addr(blk_rd_addr), .blk_rd_data(p``_blk_rd_data), .present(p``_present), \
      .writeprotect(p``_writeprotect), .chg(p``_chg), .req(req), .req_hdr(req_hdr), \
      .req_wr(req_wr), .abort(abort), .unit(unit), .req_c(req_c), .req_h(req_h), .req_tc(req_c), .req_hd(req_h[0]), .req_mf(1'b1), .req_2hd(1'b1), .req_rpm(1'b0), .req_r(req_r), \
      .req_n(req_n), .req_idx(req_idx), .ready(p``_ready), .rdy(p``_rdy), .hdrv(p``_hdrv), \
      .err(p``_err), .dout(p``_dout), .adv(adv), .din(din), .hdr_r(p``_hdr_r), \
      .hdr_n(p``_hdr_n), .hdr_sects(p``_hdr_sects)
  pc9821_fdd_media     dut  (`FDD_PORTS(d));
  pc9821_fdd_media_ref ref0 (`FDD_PORTS(r));

  wire [92:0] d_all = {d_blk_req_rd, d_blk_slot, d_blk_req_wr, d_ready, d_rdy, d_hdrv, d_err,
                       d_blk_req_lba, d_blk_rd_data, d_present, d_writeprotect, d_chg,
                       d_dout, d_hdr_r, d_hdr_n, d_hdr_sects};
  wire [92:0] r_all = {r_blk_req_rd, r_blk_slot, r_blk_req_wr, r_ready, r_rdy, r_hdrv, r_err,
                       r_blk_req_lba, r_blk_rd_data, r_present, r_writeprotect, r_chg,
                       r_dout, r_hdr_r, r_hdr_n, r_hdr_sects};

  // ==== the two images: raw bodies (a pattern of the offset) or one synthetic D88 ====
  // D88: 2HD, 160 tracks of 8 sectors of 1024 bytes; track t at 688 + t*8320, each sector a
  // 16-byte _D88SEC header {C, H, R, N, nsec(2), mfm, del, stat, rsv(5), size(2)} + data.
  localparam [31:0] D88_TRK = 32'd8320, D88_SIZE = 32'd688 + 32'd160 * 32'd8320;
  reg        is_d88 [0:1];
  reg [31:0] isz    [0:1];
  reg        prot   [0:1];
  function automatic [7:0] byte_at(input integer s, input [31:0] a);
    reg [31:0] off, t, k, sn;
    begin
      if (!is_d88[s]) byte_at = `PAT(s, a);
      else if (a < 32'd688) begin
        if (a == 32'h1A) byte_at = prot[s] ? 8'h10 : 8'h00;
        else if (a == 32'h1B) byte_at = 8'h20;
        else if (a >= 32'h1C && a < 32'h20) byte_at = D88_SIZE >> (8 * (a - 32'h1C));
        else if (a >= 32'h20 && a < 32'h20 + 32'd164 * 4) begin
          t = (a - 32'h20) >> 2;
          byte_at = (t < 160) ? ((32'd688 + t * D88_TRK) >> (8 * ((a - 32'h20) & 3))) : 8'h00;
        end else byte_at = 8'h00;
      end else if (a < D88_SIZE) begin
        off = a - 32'd688; t = off / D88_TRK; sn = (off % D88_TRK) / 32'd1040; k = off % 32'd1040;
        case (k)
          0: byte_at = t >> 1;  1: byte_at = t & 1;  2: byte_at = sn + 1;  3: byte_at = 8'd3;
          4: byte_at = 8'd8;   15: byte_at = 8'h04;
          default: byte_at = (k < 16) ? 8'h00 : `PAT(s, a);
        endcase
      end else byte_at = 8'h00;
    end
  endfunction

  // ==== the block backend (pc9821_block_share's B side, abstracted) ====
  integer seed = 4242;
  integer fills = 0, wbs = 0, fails = 0;
  reg [15:0] b_lba; reg b_slot, b_wr;
  integer b_i, b_lat;
  initial begin : backend
    forever begin
      @(negedge clk);
      if (reset) begin blk_busy = 0; blk_done = 0; blk_fill_we = 0; end
      else if (d_blk_req_rd) begin
        b_lba = d_blk_req_lba; b_slot = d_blk_slot; b_wr = d_blk_req_wr;
        blk_busy = 1;
        @(negedge clk);
        for (b_lat = {$random(seed)} % 40; b_lat > 0; b_lat = b_lat - 1) @(negedge clk);
        for (b_i = 0; b_i < 256 && !reset; b_i = b_i + 1) begin
          if (b_wr) begin blk_rd_addr = b_i; end
          else begin
            blk_fill_we = 1; blk_fill_addr = b_i;
            blk_fill_data = {byte_at(b_slot, {b_lba, 9'd0} + 2 * b_i + 1),
                             byte_at(b_slot, {b_lba, 9'd0} + 2 * b_i)};
          end
          @(negedge clk);
        end
        blk_fill_we = 0;
        blk_done = 1; blk_busy = 0;
        blk_err = (({$random(seed)} % 60) == 0) || ({b_lba, 9'd0} >= isz[b_slot]);
        if (blk_err) fails = fails + 1; else if (b_wr) wbs = wbs + 1; else fills = fills + 1;
        @(negedge clk);
        blk_done = 0; blk_err = 0;
      end
    end
  end

  // ==== CHECKS ====
  integer errors = 0, cycles = 0;
  integer reqs = 0, rawreqs_ok = 0, d88reqs_ok = 0, mounts = 0, aborts = 0, resets = 0;
  integer bytes = 0, hdrvs = 0, errs = 0;
  always @(posedge clk) begin
    cycles = cycles + 1;
    if (d_all !== r_all) begin
      errors = errors + 1;
      if (errors <= 10)
        $display("MISMATCH cycle %0d: dut^ref %h (ready %b/%b err %b/%b rdy %b/%b dout %02h/%02h lba %04h/%04h)",
                 cycles, d_all ^ r_all, d_ready, r_ready, d_err, r_err, d_rdy, r_rdy, d_dout, r_dout,
                 d_blk_req_lba, r_blk_req_lba);
    end
  end

  // The raw rows pc9821_fdd_media's ST_PARSE loads (NP2kai fdd_xdf.c supportxdf: tracks,
  // sectors, N), the synthetic D88, and sizes no format takes.
  reg [7:0] g_t [0:1]; reg [7:0] g_s [0:1]; reg [7:0] g_n [0:1];
  task automatic pick(input integer s, input integer k);
    begin
      is_d88[s] = 0;
      case (k)
        0:  begin g_t[s] = 160; g_s[s] = 15; g_n[s] = 2; end
        1:  begin g_t[s] = 154; g_s[s] = 8;  g_n[s] = 3; end
        2:  begin g_t[s] = 160; g_s[s] = 18; g_n[s] = 2; end
        3:  begin g_t[s] = 160; g_s[s] = 21; g_n[s] = 2; end
        4:  begin g_t[s] = 154; g_s[s] = 26; g_n[s] = 1; end
        5:  begin g_t[s] = 154; g_s[s] = 9;  g_n[s] = 3; end
        6:  begin g_t[s] = 160; g_s[s] = 8;  g_n[s] = 2; end
        7:  begin g_t[s] = 160; g_s[s] = 9;  g_n[s] = 2; end
        8:  begin g_t[s] = 156; g_s[s] = 8;  g_n[s] = 3; end
        9:  begin g_t[s] = 158; g_s[s] = 8;  g_n[s] = 3; end
        10: begin g_t[s] = 160; g_s[s] = 8;  g_n[s] = 3; end
        11, 12, 13: begin is_d88[s] = 1; g_t[s] = 160; g_s[s] = 8; g_n[s] = 3; end
        default: begin g_t[s] = 160; g_s[s] = 8; g_n[s] = 3; end
      endcase
      if (is_d88[s]) isz[s] = D88_SIZE;
      else if (k <= 10) isz[s] = g_t[s] * g_s[s] * (32'd128 << g_n[s]);
      else isz[s] = 32'd1000 + k;   // no format
    end
  endtask

  task automatic mount(input integer s);
    begin
      pick(s, {$random(seed)} % 15);
      prot[s] = $random(seed);
      @(negedge clk);
      img_readonly = (({$random(seed)} % 6) == 0);
      if (s == 0) begin img_size = isz[0]; img_mounted = 1; end
      else begin img1_size = isz[1]; img1_mounted = 1; end
      @(negedge clk);
      img_mounted = 0; img1_mounted = 0;
      mounts = mounts + 1;
    end
  endtask

  task automatic one_request;
    integer n, s;
    begin
      n = 0;
      while (!d_ready && n < 200000) begin @(negedge clk); n = n + 1; end
      s = {$random(seed)} % 2;
      unit = s;
      req_wr = (({$random(seed)} % 3) == 0);
      req_hdr = (({$random(seed)} % 5) == 0);
      if (({$random(seed)} % 8) == 0) begin   // anything
        req_c = $random(seed); req_h = $random(seed); req_r = $random(seed); req_n = $random(seed);
      end else begin                               // mostly in range for the mounted geometry
        req_c = {$random(seed)} % (g_t[s] / 2 + 1); req_h = {$random(seed)} % 2;
        req_r = 1 + {$random(seed)} % (g_s[s] + 1); req_n = g_n[s];
      end
      req_idx = {$random(seed)} % (g_s[s] + 2);
      req = 1;
      @(negedge clk); req = 0;
      reqs = reqs + 1;
      n = 0;
      while (!d_ready && n < 60000) begin
        if (d_rdy && ($random(seed) & 1)) begin
          adv = 1; din = $random(seed); bytes = bytes + 1;
          @(negedge clk); adv = 0;
        end else @(negedge clk);
        if ((({$random(seed)} % 20000) == 0)) begin abort = 1; @(negedge clk); abort = 0; aborts = aborts + 1; end
        if ((({$random(seed)} % 40000) == 0)) mount({$random(seed)} % 2);   // a remount mid-request
        n = n + 1;
      end
      if (d_hdrv) hdrvs = hdrvs + 1;
      if (d_err) errs = errs + 1;
      else if (!d_hdrv && bytes > 0) begin
        if (is_d88[s]) d88reqs_ok = d88reqs_ok + 1; else rawreqs_ok = rawreqs_ok + 1;
      end
    end
  endtask

  // ==== VERDICT ====
  integer i;
  initial begin
    pick(0, 14); pick(1, 14); prot[0] = 0; prot[1] = 0;
    repeat (6) @(negedge clk);
    reset = 0;
    for (i = 0; i < 1500; i = i + 1) begin
      if (i % 60 == 0) begin mount(0); mount(1); repeat (3000) @(negedge clk); end
      if (i % 97 == 50) begin
        @(negedge clk); reset = 1; repeat (1 + {$random(seed)} % 5) @(negedge clk); reset = 0;
        resets = resets + 1;
      end
      one_request;
    end
    if (reqs < 1500 || rawreqs_ok < 150 || d88reqs_ok < 30 || hdrvs < 50 || errs < 100 ||
        fills < 1000 || wbs < 50 || mounts < 40 || resets < 10)
      $fatal(1, "TB_PC9821_FDD_MEDIA_EQUIV: coverage short: reqs %0d raw-ok %0d d88-ok %0d hdrv %0d err %0d fills %0d wbs %0d mounts %0d resets %0d aborts %0d",
             reqs, rawreqs_ok, d88reqs_ok, hdrvs, errs, fills, wbs, mounts, resets, aborts);
    if (errors != 0) $fatal(1, "TB_PC9821_FDD_MEDIA_EQUIV: %0d mismatching cycles of %0d", errors, cycles);
    $display("TB_PC9821_FDD_MEDIA_EQUIV: PASS");
    $display("NOTE fdd_media_equiv: %0d cycles, %0d requests (%0d raw / %0d D88 served, %0d READ ID, %0d err), %0d bytes, %0d fills, %0d write-backs, %0d failed fetches, %0d mounts, %0d aborts, %0d resets, identical",
             cycles, reqs, rawreqs_ok, d88reqs_ok, hdrvs, errs, bytes, fills, wbs, fails, mounts, aborts, resets);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_FDD_MEDIA_EQUIV: timeout");
  end
endmodule
