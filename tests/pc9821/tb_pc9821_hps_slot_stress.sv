// tb_pc9821_hps_slot_stress - every hps_io slot's own bytes reach its own consumer, whatever the other slots do.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_HPS_SLOT_STRESS: With hard-disk reads and writes, both floppies' reads and writes, CD data reads and CD-DA streaming issued concurrently at random times against ONE hps_io-shaped host (one slot served at a time, one shared sd_buff_wr/addr/dout bus, a per-slot sd_ack high only for the slot being served), every sector the disk and floppy engine delivers is the host image's own sector, every byte it writes back is the byte its drive buffer presented, every CD data sector and every CD-DA sample is the CD image's own, and a second copy of the whole cluster fed through pc9821_hps_slot_demux (the shared bus's single owner) is cycle-for-cycle identical on every output to the copy wired straight to the shared bus; every expected byte comes from the host model's image functions, never the RTL's.

// WHY THIS BENCH EXISTS. pc9821_block_io once counted the CD's CD-DA words into a hard-disk sector
// because it consumed the shared sd_buff_wr without its slot's sd_ack (the Policenauts intro stall). tb_pc9821_hps_slot_integrity covers disk reads against CD-DA;
// this bench widens it to every slot and direction in random interleaving, and adds the
// equivalence of the demux wiring to the direct wiring.
// FAIL-FIRST: with the pre-fix block_io (stream_word without sd_ack, git 07c04959) the DIRECT
// cluster delivers corrupt sectors and the bench fails, while the demux cluster stays clean (the
// demux protects even the defective engine); with the fix both clusters pass.

// ---- file-level helpers shared by the clusters and the host model ----
// the bytes of the write-back a drive buffer presents (a function of the write's nonce and index)
function automatic [15:0] wfun(input [31:0] nonce, input [7:0] w);
  wfun = 16'(nonce * 32'h9E37 + {24'd0, w} * 32'h1F3 + 32'h5A5A) ^ {nonce[7:0], w};
endfunction

// ==== DUT ====
// One copy of everything that consumes the shared bus: the disk/floppy engine, the CD, and (when
// DEMUX) the demux between hps_io's bus and them.
module hps_stress_cluster #(parameter DEMUX = 1) (
    input  wire        clk,
    input  wire        rst_n,
    // requesters
    input  wire        a_img_mounted, input wire [63:0] a_img_size,
    input  wire        a_req_read, input wire a_req_write, input wire [31:0] a_req_lba,
    input  wire        b_img_mounted, input wire [63:0] b_img_size,
    input  wire        c_img_mounted, input wire [63:0] c_img_size,
    input  wire        b_req_read, input wire b_req_write, input wire [15:0] b_req_lba,
    input  wire        b_req_slot,
    input  wire [31:0] nonce_a, input wire [31:0] nonce_b,
    input  wire        cap_clr_a, input wire cap_clr_b,
    // the host
    input  wire        a_ack, input wire b_ack, input wire c_ack, input wire cd_ack,
    input  wire        sd_buff_wr, input wire [12:0] sd_buff_addr, input wire [15:0] sd_buff_dout,
    // CD port + media
    input  wire        io_rd, input wire io_wr, input wire [15:0] io_addr, input wire [7:0] io_din,
    input  wire        cd_img_mounted, input wire [63:0] cd_img_size,
    // observations
    output wire        a_req_done, output wire a_req_error,
    output wire        b_req_done, output wire b_req_error,
    output wire [31:0] a_sd_lba, output wire [5:0] a_sd_blk_cnt, output wire a_sd_rd, output wire a_sd_wr,
    output wire [31:0] b_sd_lba, output wire [5:0] b_sd_blk_cnt, output wire b_sd_rd, output wire b_sd_wr,
    output wire [31:0] c_sd_lba, output wire [5:0] c_sd_blk_cnt, output wire c_sd_rd, output wire c_sd_wr,
    output wire [15:0] sd_buff_din,
    output wire [ 7:0] cd_dout,
    output wire [31:0] cd_sd_lba, output wire [5:0] cd_sd_blk_cnt, output wire cd_sd_rd,
    output wire        cdda_wr, output wire [31:0] cdda_data,
    output wire [4095:0] a_snap, output wire [31:0] a_dwords_done,
    output wire [4095:0] b_snap, output wire [31:0] b_dwords_done,
    output wire [255:0] obs
);
  wire        a_buf_we, b_buf_we;
  wire [ 7:0] a_buf_addr, b_buf_addr, a_buf_rd_addr, b_buf_rd_addr;
  wire [15:0] a_buf_data, b_buf_data;
  wire        a_busy, b_busy;
  wire        a_mounted, a_readonly;
  wire [31:0] a_capacity, dbg_cycles;
  wire [15:0] a_din, b_din, c_din;
  wire        d_wr, k_wr;
  wire [12:0] d_addr, k_addr;
  wire [15:0] d_dout, k_dout;
  wire        cd_own, cd_irq;

  generate if (DEMUX) begin : g_demux
    pc9821_hps_slot_demux dmx (
        .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
        .disk_ack(a_ack | b_ack | c_ack), .cd_ack(cd_ack),
        .disk_buff_wr(d_wr), .disk_buff_addr(d_addr), .disk_buff_dout(d_dout),
        .cd_buff_wr(k_wr), .cd_buff_addr(k_addr), .cd_buff_dout(k_dout));
  end else begin : g_direct
    assign d_wr = sd_buff_wr; assign d_addr = sd_buff_addr; assign d_dout = sd_buff_dout;
    assign k_wr = sd_buff_wr; assign k_addr = sd_buff_addr; assign k_dout = sd_buff_dout;
  end endgenerate

  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_block_share share (
      .clk(clk), .rst_n(rst_n),
      .a_img_mounted(a_img_mounted), .a_img_readonly(1'b0), .a_img_size(a_img_size),
      .a_mounted(a_mounted), .a_readonly(a_readonly), .a_capacity(a_capacity),
      .a_req_read(a_req_read), .a_req_write(a_req_write), .a_req_lba(a_req_lba),
      .a_req_window(1'b1),
      .a_req_done(a_req_done), .a_req_error(a_req_error), .a_busy(a_busy),
      .a_buf_we(a_buf_we), .a_buf_addr(a_buf_addr), .a_buf_data(a_buf_data),
      .a_buf_rd_addr(a_buf_rd_addr), .a_buf_rd_data(wfun(nonce_a, a_buf_rd_addr)),
      .a_sd_lba(a_sd_lba), .a_sd_blk_cnt(a_sd_blk_cnt), .a_sd_rd(a_sd_rd), .a_sd_wr(a_sd_wr),
      .a_sd_ack(a_ack), .a_sd_buff_din(a_din),

      .b_img_mounted(b_img_mounted), .b_img_readonly(1'b0), .b_img_size(b_img_size),
      .b_req_read(b_req_read), .b_req_write(b_req_write), .b_req_lba(b_req_lba),
      .b_req_slot(b_req_slot),
      .b_req_done(b_req_done), .b_req_error(b_req_error), .b_busy(b_busy),
      .b_buf_we(b_buf_we), .b_buf_addr(b_buf_addr), .b_buf_data(b_buf_data),
      .b_buf_rd_addr(b_buf_rd_addr), .b_buf_rd_data(wfun(nonce_b, b_buf_rd_addr)),
      .b_sd_lba(b_sd_lba), .b_sd_blk_cnt(b_sd_blk_cnt), .b_sd_rd(b_sd_rd), .b_sd_wr(b_sd_wr),
      .b_sd_ack(b_ack), .b_sd_buff_din(b_din),

      .c_img_mounted(c_img_mounted), .c_img_readonly(1'b0), .c_img_size(c_img_size),
      .c_sd_lba(c_sd_lba), .c_sd_blk_cnt(c_sd_blk_cnt), .c_sd_rd(c_sd_rd), .c_sd_wr(c_sd_wr),
      .c_sd_ack(c_ack), .c_sd_buff_din(c_din),

      .sd_buff_wr(d_wr), .sd_buff_addr(d_addr), .sd_buff_dout(d_dout),
      .dbg_hps_cycles(dbg_cycles)
  );
  /* verilator lint_on PINCONNECTEMPTY */
  // hps_io samples the din of the slot it is serving; the engine drives the same value on all
  assign sd_buff_din = a_ack ? a_din : b_ack ? b_din : c_din;

  // The CD-DA ring as the drive's read-ahead sees it: always room (four sectors' worth too), and
  // each sector played the moment its last sample is written (CDDA_PLAYED one cycle after every
  // 588th CDDA_WR since the last flush), so a play completes at its fetched end.
  wire       cdda_flush;
  reg  [9:0] pm_n = 0;
  reg        pm_played = 0;
  always @(posedge clk) begin
    pm_played <= 1'b0;
    if (cdda_flush) pm_n <= 10'd0;
    else if (cdda_wr) begin
      if (pm_n == 10'd587) begin pm_n <= 10'd0; pm_played <= 1'b1; end
      else pm_n <= pm_n + 10'd1;
    end
  end
  pc9821_atapi #(.AUDIO_EN(1'b1)) cd (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(cd_dout),
      .io_own(cd_own), .irq(cd_irq),
      .img_mounted(cd_img_mounted), .img_size(cd_img_size),
      .sd_lba(cd_sd_lba), .sd_blk_cnt(cd_sd_blk_cnt), .sd_rd(cd_sd_rd), .sd_ack(cd_ack),
      .sd_buff_wr(k_wr), .sd_buff_addr(k_addr), .sd_buff_dout(k_dout),
      .cdda_req(1'b1), .cdda_req4(1'b1), .cdda_played(pm_played), .cdda_flush(cdda_flush),
      .cdda_wr(cdda_wr), .cdda_data(cdda_data),
      .log_byte(), .log_we(), .log_accept(1'b1)
  );

  // ---- what the drive/floppy buffer holds at the edge its request completes ----
  reg [15:0] a_dbuf [0:255], a_sn [0:255], b_dbuf [0:255], b_sn [0:255];
  reg [31:0] a_dw = 0, b_dw = 0, a_dd = 0, b_dd = 0;
  reg        a_seen = 0, b_seen = 0;
  assign a_dwords_done = a_dd;
  assign b_dwords_done = b_dd;
  genvar gi;
  generate for (gi = 0; gi < 256; gi++) begin : g_snap
    assign a_snap[gi * 16 +: 16] = a_sn[gi];
    assign b_snap[gi * 16 +: 16] = b_sn[gi];
  end endgenerate
  always @(posedge clk) begin
    if (cap_clr_a) begin
      a_dw <= 0; a_seen <= 0;
      for (int q = 0; q < 256; q++) a_dbuf[q] <= 16'hxxxx;
    end else begin
      if (a_buf_we) begin a_dbuf[a_buf_addr] <= a_buf_data; a_dw <= a_dw + 1; end
      if (a_req_done && !a_seen) begin
        a_seen <= 1;
        a_dd <= a_dw + (a_buf_we ? 1 : 0);
        for (int q = 0; q < 256; q++)
          a_sn[q] <= (a_buf_we && q == int'(a_buf_addr)) ? a_buf_data : a_dbuf[q];
      end
    end
    if (cap_clr_b) begin
      b_dw <= 0; b_seen <= 0;
      for (int q = 0; q < 256; q++) b_dbuf[q] <= 16'hxxxx;
    end else begin
      if (b_buf_we) begin b_dbuf[b_buf_addr] <= b_buf_data; b_dw <= b_dw + 1; end
      if (b_req_done && !b_seen) begin
        b_seen <= 1;
        b_dd <= b_dw + (b_buf_we ? 1 : 0);
        for (int q = 0; q < 256; q++)
          b_sn[q] <= (b_buf_we && q == int'(b_buf_addr)) ? b_buf_data : b_dbuf[q];
      end
    end
  end

  // every output the rest of the machine could see, for the cycle-exact equivalence compare
  assign obs = {a_req_done, a_req_error, b_req_done, b_req_error, a_buf_we, b_buf_we, a_sd_rd, a_sd_wr,
                b_sd_rd, b_sd_wr, c_sd_rd, c_sd_wr, cd_sd_rd, cdda_wr, cd_own, cd_irq,
                a_buf_addr, b_buf_addr, a_buf_rd_addr, b_buf_rd_addr, cd_dout, a_sd_blk_cnt[3:0],
                b_sd_blk_cnt[3:0], cd_sd_blk_cnt[3:0], a_buf_data, b_buf_data, sd_buff_din,
                a_sd_lba[15:0], b_sd_lba[15:0], c_sd_lba[15:0], cd_sd_lba[15:0], cdda_data};
endmodule

module tb_pc9821_hps_slot_stress;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer errors = 0;

  localparam integer DISK_SECS = 128;
  localparam integer FLP_SECS = 64;
  localparam integer PCD_SECS = 70;
  localparam integer N_HDD = 60, N_FLP = 40, N_CD = 14;

  // ---- inputs shared by both clusters ----
  reg         a_img_mounted = 0, b_img_mounted = 0, c_img_mounted = 0, cd_img_mounted = 0;
  reg  [63:0] a_img_size = 0, b_img_size = 0, c_img_size = 0, cd_img_size = 0;
  reg         a_req_read = 0, a_req_write = 0, b_req_read = 0, b_req_write = 0, b_req_slot = 0;
  reg  [31:0] a_req_lba = 0;
  reg  [15:0] b_req_lba = 0;
  reg  [31:0] nonce_a = 0, nonce_b = 0;
  reg         cap_clr_a = 0, cap_clr_b = 0;
  reg         a_ack = 0, b_ack = 0, c_ack = 0, cd_ack = 0;
  reg         sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  reg         io_rd = 0, io_wr = 0;
  reg  [15:0] io_addr = 0;
  reg  [ 7:0] io_din = 0;

  // ---- the two clusters: [0] straight on the shared bus (the current wiring), [1] through the demux ----
  wire        a_done[2], a_err[2], b_done[2], b_err[2];
  wire [31:0] a_lba[2], b_lba[2], c_lba[2], cd_lba[2];
  wire [5:0]  a_blk[2], b_blk[2], c_blk[2], cd_blk[2];
  wire        a_rd[2], a_wr[2], b_rd[2], b_wr[2], c_rd[2], c_wr[2], cd_rd[2];
  wire [15:0] din[2];
  wire [7:0]  cdo[2];
  wire        cdw[2];
  wire [31:0] cdd[2];
  wire [4095:0] asn[2], bsn[2];
  wire [31:0] adw[2], bdw[2];
  wire [255:0] ob[2];

  generate for (genvar g = 0; g < 2; g++) begin : g_cl
    hps_stress_cluster #(.DEMUX(g)) cl (
        .clk(clk), .rst_n(rst_n),
        .a_img_mounted(a_img_mounted), .a_img_size(a_img_size),
        .a_req_read(a_req_read), .a_req_write(a_req_write), .a_req_lba(a_req_lba),
        .b_img_mounted(b_img_mounted), .b_img_size(b_img_size),
        .c_img_mounted(c_img_mounted), .c_img_size(c_img_size),
        .b_req_read(b_req_read), .b_req_write(b_req_write), .b_req_lba(b_req_lba),
        .b_req_slot(b_req_slot), .nonce_a(nonce_a), .nonce_b(nonce_b),
        .cap_clr_a(cap_clr_a), .cap_clr_b(cap_clr_b),
        .a_ack(a_ack), .b_ack(b_ack), .c_ack(c_ack), .cd_ack(cd_ack),
        .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
        .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
        .cd_img_mounted(cd_img_mounted), .cd_img_size(cd_img_size),
        .a_req_done(a_done[g]), .a_req_error(a_err[g]),
        .b_req_done(b_done[g]), .b_req_error(b_err[g]),
        .a_sd_lba(a_lba[g]), .a_sd_blk_cnt(a_blk[g]), .a_sd_rd(a_rd[g]), .a_sd_wr(a_wr[g]),
        .b_sd_lba(b_lba[g]), .b_sd_blk_cnt(b_blk[g]), .b_sd_rd(b_rd[g]), .b_sd_wr(b_wr[g]),
        .c_sd_lba(c_lba[g]), .c_sd_blk_cnt(c_blk[g]), .c_sd_rd(c_rd[g]), .c_sd_wr(c_wr[g]),
        .sd_buff_din(din[g]), .cd_dout(cdo[g]),
        .cd_sd_lba(cd_lba[g]), .cd_sd_blk_cnt(cd_blk[g]), .cd_sd_rd(cd_rd[g]),
        .cdda_wr(cdw[g]), .cdda_data(cdd[g]),
        .a_snap(asn[g]), .a_dwords_done(adw[g]), .b_snap(bsn[g]), .b_dwords_done(bdw[g]),
        .obs(ob[g]));
  end endgenerate

  // ==== STIMULUS ====
  // ---- the host's images: every expected byte is a function of (slot, sector, index) plus the
  // writes the host itself accepted; nothing is read from the RTL ----
  function automatic [7:0] hbyte(input integer sl, input integer s, input integer i);
    hbyte = 8'(s * 37 + i * 11 + (i >> 8) * 5 + 8'h5C + sl * 71);
  endfunction
  reg [15:0] ovr [longint];   // {slot, sector, word} -> a word the host has been written
  function automatic [15:0] host_word(input integer sl, input integer s, input integer w);
    longint k;
    k = (longint'(sl) << 40) | (longint'(s) << 8) | longint'(w);
    host_word = ovr.exists(k) ? ovr[k] : {hbyte(sl, s, 2 * w + 1), hbyte(sl, s, 2 * w)};
  endfunction
  function automatic [7:0] dbyte(input integer l, input integer i);
    dbyte = 8'((i ^ (i >> 8) * 29) + l * 13 + 1);
  endfunction
  function automatic [7:0] abyte(input integer l, input integer i);
    abyte = 8'(l * 91 + i * 7 + 3 + (i >> 8));
  endfunction
  function automatic [7:0] bcd8(input integer v);
    bcd8 = 8'(((v / 10) << 4) | (v % 10));
  endfunction

  byte img [];
  task automatic pcd_entry(input integer e, input [7:0] ctrl, input integer lba);
    integer f;
    begin
      img[16 + 4 * e] = ctrl;
      img[16 + 4 * e + 1] = 8'(lba); img[16 + 4 * e + 2] = 8'(lba >> 8);
      img[16 + 4 * e + 3] = 8'(lba >> 16);
      img[512 + 4 * e] = 8'(lba >> 24); img[512 + 4 * e + 1] = 8'(lba >> 16);
      img[512 + 4 * e + 2] = 8'(lba >> 8); img[512 + 4 * e + 3] = 8'(lba);
      f = lba + 150;
      img[1024 + 4 * e] = 0; img[1024 + 4 * e + 1] = 8'(f / 4500);
      img[1024 + 4 * e + 2] = 8'((f / 75) % 60); img[1024 + 4 * e + 3] = 8'(f % 75);
      img[1536 + 4 * e] = 0; img[1536 + 4 * e + 1] = bcd8(f / 4500);
      img[1536 + 4 * e + 2] = bcd8((f / 75) % 60); img[1536 + 4 * e + 3] = bcd8(f % 75);
    end
  endtask
  task automatic make_pcd;
    integer base;
    begin
      img = new[(PCD_SECS + 1) * 2352];
      foreach (img[k]) img[k] = 0;
      img[0] = "P"; img[1] = "C"; img[2] = "9"; img[3] = "8";
      img[4] = "C"; img[5] = "D"; img[6] = "0"; img[7] = "1";
      img[8] = 3; img[9] = 1;
      img[12] = 8'(PCD_SECS);
      pcd_entry(0, 8'h14, 0); pcd_entry(1, 8'h10, 10); pcd_entry(2, 8'h10, 20);
      pcd_entry(3, 8'h10, PCD_SECS);
      for (int l = 0; l < PCD_SECS; l++) begin
        base = (l + 1) * 2352;
        if (l < 10) begin
          img[base] = 0; for (int i = 1; i < 11; i++) img[base + i] = 8'hFF; img[base + 11] = 0;
          img[base + 15] = 1;
          for (int i = 0; i < 2048; i++) img[base + 16 + i] = dbyte(l, i);
        end else
          for (int i = 0; i < 2352; i++) img[base + i] = abyte(l, i);
      end
    end
  endtask

  // ---- a small deterministic RNG (xorshift32) so the interleaving is reproducible ----
  reg [31:0] rng = 32'h2468ACE1;
  function automatic integer rnd(input integer n);
    begin
      rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
      rnd = int'(rng % 32'(n));
    end
  endfunction

  // ---- hps_io's side: ONE slot at a time, a per-slot ack, one shared word bus ----
  integer n_xfer [0:4];                   // transfers served per slot (0 hdd,1 fdd0,2 fdd1,4 cd)
  integer n_wr_words [0:4];               // words the host read back per slot's writes
  integer wr_bad = 0;
  integer last_slot = 4;
  integer wr_lba_seen [0:4];
  initial for (int i = 0; i < 5; i++) begin n_xfer[i] = 0; n_wr_words[i] = 0; wr_lba_seen[i] = -1; end
  always @(negedge clk) begin : host
    integer sl, pick, lat, words;
    reg     is_wr;
    reg [31:0] lba;
    if (!a_ack && !b_ack && !c_ack && !cd_ack &&
        (a_rd[1] || a_wr[1] || b_rd[1] || b_wr[1] || c_rd[1] || c_wr[1] || cd_rd[1])) begin
      pick = -1;
      for (int o = 1; o <= 5 && pick < 0; o++) begin
        int s;
        s = (last_slot + o) % 5;
        case (s)
          0: if (a_rd[1] || a_wr[1]) pick = 0;
          1: if (b_rd[1] || b_wr[1]) pick = 1;
          2: if (c_rd[1] || c_wr[1]) pick = 2;
          4: if (cd_rd[1]) pick = 4;
          default: ;
        endcase
      end
      sl = pick;
      is_wr = (sl == 0) ? a_wr[1] : (sl == 1) ? b_wr[1] : (sl == 2) ? c_wr[1] : 1'b0;
      lba   = (sl == 0) ? a_lba[1] : (sl == 1) ? b_lba[1] : (sl == 2) ? c_lba[1] : cd_lba[1];
      words = 256 * (1 + ((sl == 0) ? a_blk[1] : (sl == 1) ? b_blk[1] : (sl == 2) ? c_blk[1] : cd_blk[1]));
      lat   = 5 + rnd(60);
      repeat (lat) @(negedge clk);
      case (sl) 0: a_ack = 1; 1: b_ack = 1; 2: c_ack = 1; default: cd_ack = 1; endcase
      n_xfer[sl] = n_xfer[sl] + 1;
      repeat (2 + rnd(3)) @(negedge clk);
      for (int w = 0; w < words; w++) begin
        sd_buff_addr = 13'(w);
        if (is_wr) begin
          // the host reads the drive's buffer: hps_io samples sd_buff_din at its address
          @(negedge clk);
          begin
            reg [31:0] nn;
            nn = (sl == 0) ? nonce_a : nonce_b;
            if (din[1][15:0] !== wfun(nn, 8'(w)) || din[0][15:0] !== wfun(nn, 8'(w))) begin
              wr_bad++; errors++;
              if (wr_bad < 6)
                $display("FAIL: write slot %0d lba %0d word %0d: host read %04x/%04x, buffer presented %04x",
                         sl, lba, w, din[0], din[1], wfun(nn, 8'(w)));
            end
            ovr[(longint'(sl) << 40) | (longint'(lba) << 8) | longint'(w)] = wfun(nn, 8'(w));
            n_wr_words[sl] = n_wr_words[sl] + 1;
          end
        end else begin
          if (sl == 4) begin
            longint o;
            o = longint'(lba) * 512 + w * 2;
            sd_buff_dout = {(o + 1 < img.size()) ? img[o + 1] : 8'h00,
                            (o < img.size()) ? img[o] : 8'h00};
          end else
            sd_buff_dout = host_word(sl, int'(lba) + (w / 256), w % 256);
          sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0;
          if (rnd(4) != 0) @(negedge clk);
        end
      end
      repeat (2) @(negedge clk);
      a_ack = 0; b_ack = 0; c_ack = 0; cd_ack = 0;
      last_slot = sl;
    end
  end

  // ---- cycle-exact equivalence of the two clusters ----
  integer eq_bad = 0, eq_cycles = 0;
  always @(negedge clk) if (rst_n) begin
    eq_cycles++;
    if (ob[0] !== ob[1] || a_lba[0] !== a_lba[1] || a_wr[0] !== a_wr[1]) begin
      eq_bad++; errors++;
      if (eq_bad < 6) $display("FAIL: clusters diverge at cycle %0d: obs direct %h vs demux %h",
                               eq_cycles, ob[0], ob[1]);
    end
  end

  // ---- CD-DA samples, per cluster ----
  integer cdda_n [2];
  reg [31:0] cdda_log [2][0:(30 * 588)];
  integer cdda_base [2];   // the sample count when the current play began
  initial begin cdda_n[0] = 0; cdda_n[1] = 0; cdda_base[0] = 0; cdda_base[1] = 0; end
  always @(posedge clk) begin
    for (int c = 0; c < 2; c++) if (cdw[c]) begin
      if (cdda_n[c] - cdda_base[c] < 30 * 588) cdda_log[c][cdda_n[c] - cdda_base[c]] <= cdd[c];
      cdda_n[c] <= cdda_n[c] + 1;
    end
  end

  // ---- checks of one delivered sector against the host image ----
  task automatic judge(input integer which, input integer sl, input integer lba,
                       input [4095:0] snap, input [31:0] dd, input string what);
    integer bad, first;
    begin
      bad = 0; first = -1;
      for (int k = 0; k < 256; k++)
        if (snap[k * 16 +: 16] !== host_word(sl, lba, k)) begin
          if (first < 0) first = k;
          bad++;
        end
      if (bad != 0 || dd != 256) begin
        errors++;
        $display("FAIL: %s %s slot %0d lba %0d: %0d words wrong (first %0d), %0d words reached the buffer (want 256)",
                 which == 0 ? "direct" : "demux", what, sl, lba, bad, first, dd);
      end
    end
  endtask

  // ---- the hard-disk thread ----
  integer hdd_done_threads = 0;
  integer hdd_reads = 0, hdd_writes = 0, last_hdd = 0;
  task automatic hdd_op(input bit wr, input integer lba);
    integer n, nw0;
    begin
      @(negedge clk); cap_clr_a = 1; @(negedge clk); cap_clr_a = 0;
      nw0 = n_wr_words[0];
      if (wr) nonce_a = 32'(rnd(1 << 20)) + 1;
      @(negedge clk); a_req_lba = lba; a_req_read = !wr; a_req_write = wr;
      @(negedge clk); a_req_read = 0; a_req_write = 0;
      n = 0;
      while (!(a_done[0] && a_done[1]) && n < 300000) begin @(negedge clk); n++; end
      repeat (4) @(negedge clk);
      if (n >= 300000) begin errors++; $display("FAIL: hdd %s lba %0d never completed", wr ? "write" : "read", lba); end
      else if (a_err[0] || a_err[1]) begin errors++; $display("FAIL: hdd %s lba %0d error", wr ? "write" : "read", lba); end
      else if (wr) begin
        if (n_wr_words[0] - nw0 != 256) begin
          errors++; $display("FAIL: hdd write lba %0d: host took %0d words, want 256", lba, n_wr_words[0] - nw0);
        end
      end else begin
        judge(0, 0, lba, asn[0], adw[0], "hdd read");
        judge(1, 0, lba, asn[1], adw[1], "hdd read");
      end
      repeat (4) @(negedge clk);
    end
  endtask
  initial begin : hdd_thread
    integer lba, wr;
    wait (rst_n);
    repeat (30000) @(negedge clk);   // after the mounts and the CD header
    for (int i = 0; i < N_HDD; i++) begin
      repeat (rnd(200)) @(negedge clk);
      wr = (rnd(10) < 3);
      lba = (rnd(2) == 0) ? (last_hdd + 1) % DISK_SECS : rnd(DISK_SECS);
      last_hdd = lba;
      hdd_op(wr != 0, lba);
      if (wr != 0) hdd_writes++; else hdd_reads++;
    end
    hdd_done_threads = 1;
  end

  // ---- the floppy thread (both drives, through the B port) ----
  integer flp_done = 0, flp_reads = 0, flp_writes = 0;
  initial begin : flp_thread
    integer sl, lba, wr, n, nw0;
    wait (rst_n);
    repeat (30000) @(negedge clk);
    for (int i = 0; i < N_FLP; i++) begin
      repeat (rnd(300)) @(negedge clk);
      sl = rnd(2); lba = rnd(FLP_SECS); wr = (rnd(10) < 3);
      @(negedge clk); cap_clr_b = 1; @(negedge clk); cap_clr_b = 0;
      nw0 = n_wr_words[1 + sl];
      if (wr != 0) nonce_b = 32'(rnd(1 << 20)) + 7;
      @(negedge clk); b_req_slot = sl[0]; b_req_lba = 16'(lba); b_req_read = 1; b_req_write = (wr != 0);
      @(negedge clk); b_req_read = 0; b_req_write = 0;
      n = 0;
      while (!(b_done[0] && b_done[1]) && n < 300000) begin @(negedge clk); n++; end
      repeat (4) @(negedge clk);
      if (n >= 300000) begin errors++; $display("FAIL: floppy %0d lba %0d never completed", sl, lba); end
      else if (b_err[0] || b_err[1]) begin errors++; $display("FAIL: floppy %0d lba %0d error", sl, lba); end
      else if (wr != 0) begin
        flp_writes++;
        if (n_wr_words[1 + sl] - nw0 != 256) begin
          errors++; $display("FAIL: floppy %0d write lba %0d: host took %0d words", sl, lba, n_wr_words[1 + sl] - nw0);
        end
      end else begin
        flp_reads++;
        judge(0, 1 + sl, lba, bsn[0], bdw[0], "floppy read");
        judge(1, 1 + sl, lba, bsn[1], bdw[1], "floppy read");
      end
      repeat (4) @(negedge clk);
    end
    flp_done = 1;
  end

  // ---- the CD port (the iobus's one-cycle strobes) ----
  task automatic wr(input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_din = d; io_wr = 1;
      @(negedge clk); io_wr = 0;
    end
  endtask
  task automatic rd(input [15:0] a, output [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_rd = 1; #1 d = cdo[1];
      if (cdo[0] !== cdo[1]) begin errors++; $display("FAIL: CD port %04x read differs between clusters", a); end
      @(negedge clk); io_rd = 0;
    end
  endtask
  task automatic wait_notbusy;
    reg [7:0] s; integer n;
    begin
      n = 0;
      do begin rd(16'h074C, s); n = n + 1; end while (s[7] && n < 20000);
      if (s[7]) $fatal(1, "TB_PC9821_HPS_SLOT_STRESS: FAIL - BSY never cleared");
    end
  endtask
  byte rxq [$];
  task automatic packet(input byte c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
    reg [7:0] s, lo, hi; integer cnt, phases;
    begin
      byte cdb [0:11];
      cdb = '{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, 8'h00, 8'h00};
      rxq.delete();
      wr(16'h064E, 8'hA0);
      for (int k = 0; k < 6; k++) begin wr(16'h0640, cdb[2 * k]); wr(16'h0641, cdb[2 * k + 1]); end
      phases = 0;
      forever begin
        wait_notbusy;
        rd(16'h074C, s);
        if (!s[3]) break;
        rd(16'h0648, lo); rd(16'h064A, hi);
        cnt = {hi, lo};
        for (int k = 0; k < (cnt + 1) / 2; k++) begin
          rd(16'h0640, lo); rd(16'h0641, hi); rxq.push_back(lo); rxq.push_back(hi);
        end
        phases++;
        if (phases > 64) $fatal(1, "TB_PC9821_HPS_SLOT_STRESS: FAIL - runaway data phases");
      end
      rd(16'h064E, s);
    end
  endtask

  integer cd_plays = 0, cd_reads = 0, cd_done = 0;
  initial begin : cd_thread
    integer s0, ns, n0, waited, l, f0, f1;
    wait (rst_n);
    wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0);
    packet(8'h5A, 0, 8'h0F, 0, 0, 0, 0, 0, 8'd24, 0);   // MODE SENSE 0x0F: NEC mode (BCD MSF)
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    for (int i = 0; i < N_CD; i++) begin
      repeat (rnd(500)) @(negedge clk);
      if (rnd(3) != 0) begin
        // CD-DA: a random run inside the audio tracks (sectors 10..69), streamed to the end
        s0 = 10 + rnd(40); ns = 3 + rnd(18);
        cdda_base[0] = cdda_n[0]; cdda_base[1] = cdda_n[1];
        n0 = cdda_n[1];
        f0 = s0 + 150; f1 = s0 + ns + 150;
        packet(8'h47, 0, 0, bcd8(f0 / 4500), bcd8((f0 / 75) % 60), bcd8(f0 % 75),
               bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0);
        waited = 0;
        while (cdda_n[1] - n0 < ns * 588 && waited < 3000000) begin @(negedge clk); waited++; end
        repeat (3000) @(negedge clk);
        for (int c = 0; c < 2; c++) begin
          if (cdda_n[c] - cdda_base[c] != ns * 588) begin
            errors++;
            $display("FAIL: CD-DA play %0d (sectors %0d..%0d) %s cluster streamed %0d samples, want %0d",
                     i, s0, s0 + ns - 1, c == 0 ? "direct" : "demux", cdda_n[c] - cdda_base[c], ns * 588);
          end else
            for (int s = 0; s < ns * 588; s++) begin
              integer o;
              l = s0 + s / 588; o = (s % 588) * 4;
              if (cdda_log[c][s] !== {abyte(l, o + 3), abyte(l, o + 2), abyte(l, o + 1), abyte(l, o)}) begin
                errors++;
                $display("FAIL: CD-DA play %0d %s sample %0d (sector %0d) = %08x", i, c == 0 ? "direct" : "demux",
                         s, l, cdda_log[c][s]);
                break;
              end
            end
        end
        cd_plays++;
      end else begin
        // CD data: READ(10) of one or two data-track sectors, 2048 bytes each
        l = rnd(8); ns = 1 + rnd(2);
        packet(8'h28, 0, 0, 0, 0, 8'(l), 0, 0, 8'(ns), 0);
        if (rxq.size() != ns * 2048) begin
          errors++; $display("FAIL: CD READ(10) lba %0d x%0d returned %0d bytes", l, ns, rxq.size());
        end else
          for (int b = 0; b < ns * 2048; b++)
            if (rxq[b] !== dbyte(l + b / 2048, b % 2048)) begin
              errors++;
              $display("FAIL: CD READ(10) lba %0d byte %0d = %02x, want %02x", l, b, rxq[b], dbyte(l + b / 2048, b % 2048));
              break;
            end
        cd_reads++;
      end
    end
    cd_done = 1;
  end

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    // mount every medium (the pulses are single-cycle, as hps_io's are)
    a_img_size = 64'(DISK_SECS) * 512;
    b_img_size = 64'(FLP_SECS) * 512;
    c_img_size = 64'(FLP_SECS) * 512;
    @(negedge clk); a_img_mounted = 1; b_img_mounted = 1; c_img_mounted = 1;
    repeat (3) @(negedge clk); a_img_mounted = 0; b_img_mounted = 0; c_img_mounted = 0;
    make_pcd;
    cd_img_size = img.size();
    @(negedge clk); cd_img_mounted = 1; repeat (3) @(negedge clk); cd_img_mounted = 0;

    wait (hdd_done_threads && flp_done && cd_done);
    repeat (2000) @(negedge clk);

    $display("host transfers: hdd %0d, fdd0 %0d, fdd1 %0d, cd %0d; hdd r/w %0d/%0d, floppy r/w %0d/%0d, cd play/read %0d/%0d; %0d equivalence cycles",
             n_xfer[0], n_xfer[1], n_xfer[2], n_xfer[4], hdd_reads, hdd_writes, flp_reads, flp_writes,
             cd_plays, cd_reads, eq_cycles);
    if (hdd_writes < 5 || flp_writes < 3 || cd_plays < 3 || cd_reads < 2 || n_xfer[0] < 20 ||
        n_xfer[1] < 3 || n_xfer[2] < 3 || n_xfer[4] < 20) begin
      errors++;
      $display("FAIL: the interleaving was too thin to mean anything");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_HPS_SLOT_STRESS: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_HPS_SLOT_STRESS: FAIL (%0d errors)", errors);
  end

  initial begin
    #3_000_000_000;
    $fatal(1, "TB_PC9821_HPS_SLOT_STRESS: TIMEOUT");
  end

endmodule
