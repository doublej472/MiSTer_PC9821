// tb_pc9821_hps_slot_integrity - the hard disk's data survives another hps_io slot's traffic.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_HPS_SLOT_INTEGRITY: Every sector the hard disk's block path (pc9821_block_share -> pc9821_block_io) delivers is the image's own sector while the CD-ROM (pc9821_atapi, hps_io slot 4) streams CD-DA through the SAME word bus, however the disk's request lands against the CD's transfer, and the CD-DA samples are the audio sectors' own samples with none of the disk's words in them: the host model is hps_io-shaped (ONE slot served at a time, ONE shared sd_buff_wr/addr/dout bus, a per-slot sd_ack that is high only for the slot being served), the disk requests are issued 2..700 clk after the CD's transfer is acknowledged so they wait in the engine while the CD's words go by, and every expected byte is the host model's own image (a function of sector and byte index), never the RTL's.
//
// WHY THIS BENCH EXISTS. pc9821_block_io once counted any sd_buff_wr word while its own request
// merely WAITED for the host, so a CD-DA transfer on slot 4 landed in the hard disk's sector
// buffer (the Policenauts intro stall: disk data corruption found through a game symptom, after a
// day of tracing). No bench had two slots on one bus.
// FAIL-FIRST: on a tree without the per-slot sd_ack gate in pc9821_block_io's stream_word the
// disk-only pass is green and the CD-playing pass fails with corrupt sectors (or a sector that
// completes early / never completes); with the gate it passes.

// ==== DUT ====
module tb_pc9821_hps_slot_integrity;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer errors = 0;

  // ---- the disk side: pc9821_block_share, slot A only (the floppy ports are unused) ----
  reg         a_img_mounted = 0;
  reg  [63:0] a_img_size = 0;
  reg         a_req_read = 0;
  reg  [31:0] a_req_lba = 0;
  wire        a_req_done, a_req_error, a_busy;
  wire        a_buf_we;
  wire [ 7:0] a_buf_addr;
  wire [15:0] a_buf_data;
  wire [ 7:0] a_buf_rd_addr;
  wire [31:0] a_sd_lba;
  wire [ 5:0] a_sd_blk_cnt;
  wire        a_sd_rd, a_sd_wr;
  reg         a_sd_ack = 0;
  wire [15:0] a_sd_din_unused;
  wire        a_mounted, a_readonly;
  wire [31:0] a_capacity;
  wire [31:0] dbg_hps_cycles;

  // the ONE word bus every slot shares (sys/hps_io.sv: not a per-slot array)
  reg         sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;

  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_block_share share (
      .clk(clk), .rst_n(rst_n),
      .a_img_mounted(a_img_mounted), .a_img_readonly(1'b1), .a_img_size(a_img_size),
      .a_mounted(a_mounted), .a_readonly(a_readonly), .a_capacity(a_capacity),
      .a_req_read(a_req_read), .a_req_write(1'b0), .a_req_lba(a_req_lba),
      .a_req_window(1'b1),
      .a_req_done(a_req_done), .a_req_error(a_req_error), .a_busy(a_busy),
      .a_buf_we(a_buf_we), .a_buf_addr(a_buf_addr), .a_buf_data(a_buf_data),
      .a_buf_rd_addr(a_buf_rd_addr), .a_buf_rd_data(16'd0),
      .a_sd_lba(a_sd_lba), .a_sd_blk_cnt(a_sd_blk_cnt), .a_sd_rd(a_sd_rd), .a_sd_wr(a_sd_wr),
      .a_sd_ack(a_sd_ack), .a_sd_buff_din(a_sd_din_unused),

      .b_img_mounted(1'b0), .b_img_readonly(1'b1), .b_img_size(64'd0),
      .b_req_read(1'b0), .b_req_write(1'b0), .b_req_lba(16'd0), .b_req_slot(1'b0),
      .b_req_done(), .b_req_error(), .b_busy(),
      .b_buf_we(), .b_buf_addr(), .b_buf_data(),
      .b_buf_rd_addr(), .b_buf_rd_data(16'd0),
      .b_sd_lba(), .b_sd_blk_cnt(), .b_sd_rd(), .b_sd_wr(),
      .b_sd_ack(1'b0), .b_sd_buff_din(),

      .c_img_mounted(1'b0), .c_img_readonly(1'b1), .c_img_size(64'd0),
      .c_sd_lba(), .c_sd_blk_cnt(), .c_sd_rd(), .c_sd_wr(),
      .c_sd_ack(1'b0), .c_sd_buff_din(),

      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- the CD side: pc9821_atapi on hps_io slot 4 ----
  reg         io_rd = 0, io_wr = 0;
  reg  [15:0] io_addr = 0;
  reg  [ 7:0] io_din = 0;
  wire [ 7:0] cd_dout;
  wire        cd_own, cd_irq;
  reg         cd_img_mounted = 0;
  reg  [63:0] cd_img_size = 0;
  wire [31:0] cd_sd_lba;
  wire [ 5:0] cd_sd_blk_cnt;
  wire        cd_sd_rd;
  reg         cd_sd_ack = 0;
  reg         cdda_req = 1;
  wire        cdda_wr;
  wire [31:0] cdda_data;

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
      .sd_lba(cd_sd_lba), .sd_blk_cnt(cd_sd_blk_cnt), .sd_rd(cd_sd_rd), .sd_ack(cd_sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .cdda_req(cdda_req), .cdda_req4(cdda_req), .cdda_played(pm_played), .cdda_flush(cdda_flush),
      .cdda_wr(cdda_wr), .cdda_data(cdda_data),
      .log_byte(), .log_we(), .log_accept(1'b1)
  );

  // ==== STIMULUS ====
  // ---- the images: every expected byte is a function of (sector, index), nothing else ----
  localparam integer DISK_SECS = 128;
  localparam integer PCD_SECS = 70;   // track 1 data 0..9, track 2 audio 10..19, track 3 20..69
  localparam integer PLAY_FIRST = 10;
  localparam integer PLAY_SECS = 50;

  function automatic [7:0] hbyte(input integer s, input integer i);
    hbyte = 8'(s * 37 + i * 11 + (i >> 8) * 5 + 8'h5C);
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

  // ---- hps_io's side, shaped like hps_io: ONE slot at a time, one shared word bus ----
  integer host_lat = 40;   // clk from the request to the ack: the window a competing request
                           // arrives in (thousands are measured on the real ARM)
  integer n_disk_xfers = 0, n_cd_xfers = 0;
  reg last_was_cd = 0;
  always @(negedge clk) begin : host
    reg        slot_cd;
    reg [31:0] lba;
    integer    words;
    if (!a_sd_ack && !cd_sd_ack && (a_sd_rd || cd_sd_rd)) begin
      // round-robin: the slot that was NOT served last wins a tie (hps_io starts its scan after
      // the last one)
      slot_cd = cd_sd_rd && (!a_sd_rd || !last_was_cd);
      lba     = slot_cd ? cd_sd_lba : a_sd_lba;
      words   = (slot_cd ? (cd_sd_blk_cnt + 1) : (a_sd_blk_cnt + 1)) * 256;
      repeat (host_lat) @(negedge clk);
      if (slot_cd) begin cd_sd_ack = 1; n_cd_xfers = n_cd_xfers + 1; end
      else         begin a_sd_ack = 1;  n_disk_xfers = n_disk_xfers + 1; end
      repeat (3) @(negedge clk);
      for (int w = 0; w < words; w++) begin
        sd_buff_addr = 13'(w);
        if (slot_cd) begin
          longint o;
          o = longint'(lba) * 512 + w * 2;
          sd_buff_dout = {(o + 1 < img.size()) ? img[o + 1] : 8'h00,
                          (o < img.size()) ? img[o] : 8'h00};
        end else begin
          integer sec, bi;
          sec = lba + (w / 256); bi = (w % 256) * 2;
          sd_buff_dout = {hbyte(sec, bi + 1), hbyte(sec, bi)};
        end
        sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0; @(negedge clk);
      end
      repeat (2) @(negedge clk);
      cd_sd_ack = 0; a_sd_ack = 0;
      last_was_cd = slot_cd;
    end
  end

  // ---- the CD-DA port ----
  integer cdda_n = 0;
  reg [31:0] cdda_log [0:PLAY_SECS * 588 + 1023];
  always @(posedge clk) if (cdda_wr) begin
    if (cdda_n < PLAY_SECS * 588 + 1024) cdda_log[cdda_n] <= cdda_data;
    cdda_n <= cdda_n + 1;
  end

  // ---- the disk requester: one READ per call, the delivered words collected and checked ----
  reg [15:0] dbuf [0:255];
  integer    dwords = 0;
  integer    disk_reqs = 0, disk_bad = 0;
  // The drive consumes the sector when req_done pulses, so the buffer is judged AS IT STANDS AT
  // THAT EDGE: words that land later cannot repair a sector the drive already took.
  reg [15:0] snap [0:255];
  integer    dwords_done = 0;
  bit        done_seen = 0;
  always @(posedge clk) begin
    if (a_buf_we) begin
      dbuf[a_buf_addr] <= a_buf_data;
      dwords <= dwords + 1;
    end
    if (a_req_done && !done_seen) begin
      done_seen <= 1;
      dwords_done <= dwords + (a_buf_we ? 1 : 0);
      for (int q = 0; q < 256; q++) snap[q] <= (a_buf_we && q == int'(a_buf_addr)) ? a_buf_data : dbuf[q];
    end
  end
  task automatic disk_read(input integer lba, input string what);
    integer n, bad, first;
    begin
      dwords = 0; done_seen = 0;
      for (int k = 0; k < 256; k++) dbuf[k] = 16'hxxxx;
      @(negedge clk); a_req_lba = lba; a_req_read = 1;
      @(negedge clk); a_req_read = 0;
      n = 0;
      while (!a_req_done && n < 300000) begin @(negedge clk); n++; end
      repeat (4) @(negedge clk);
      disk_reqs = disk_reqs + 1;
      if (!a_req_done && n >= 300000) begin
        errors++; disk_bad++;
        $display("FAIL: %s: disk LBA %0d never completed", what, lba);
      end else if (a_req_error) begin
        errors++; disk_bad++;
        $display("FAIL: %s: disk LBA %0d completed with an error", what, lba);
      end else begin
        bad = 0; first = -1;
        for (int k = 0; k < 256; k++)
          if (snap[k] !== {hbyte(lba, 2 * k + 1), hbyte(lba, 2 * k)}) begin
            if (first < 0) first = k;
            bad++;
          end
        if (bad != 0 || dwords_done != 256) begin
          errors++; disk_bad++;
          $display("FAIL: %s: disk LBA %0d: at completion %0d of 256 words wrong (first at word %0d), %0d words had reached the drive's buffer (want exactly 256)",
                   what, lba, bad, first, dwords_done);
        end
      end
      // let a completed request's burst tail drain before the next one
      repeat (4) @(negedge clk);
    end
  endtask

  // ---- port access to the CD (the iobus's one-cycle strobes) ----
  task automatic wr(input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_din = d; io_wr = 1;
      @(negedge clk); io_wr = 0;
    end
  endtask
  task automatic rd(input [15:0] a, output [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_rd = 1; #1 d = cd_dout;
      @(negedge clk); io_rd = 0;
    end
  endtask
  task automatic wait_notbusy;
    reg [7:0] s; integer n;
    begin
      n = 0;
      do begin rd(16'h074C, s); n = n + 1; end while (s[7] && n < 20000);
      if (s[7]) $fatal(1, "TB_PC9821_HPS_SLOT_INTEGRITY: FAIL - BSY never cleared");
    end
  endtask
  // a PACKET command with no data phase read (the commands used here return a few bytes at most)
  task automatic packet(input byte c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
    reg [7:0] s, lo, hi; integer cnt, phases;
    begin
      byte cdb [0:11];
      cdb = '{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, 8'h00, 8'h00};
      wr(16'h064E, 8'hA0);
      for (int k = 0; k < 6; k++) begin wr(16'h0640, cdb[2 * k]); wr(16'h0641, cdb[2 * k + 1]); end
      phases = 0;
      forever begin
        wait_notbusy;
        rd(16'h074C, s);
        if (!s[3]) break;
        rd(16'h0648, lo); rd(16'h064A, hi);
        cnt = {hi, lo};
        for (int k = 0; k < (cnt + 1) / 2; k++) begin rd(16'h0640, lo); rd(16'h0641, hi); end
        phases++;
        if (phases > 64) $fatal(1, "TB_PC9821_HPS_SLOT_INTEGRITY: FAIL - runaway data phases");
      end
      rd(16'h064E, s);
    end
  endtask

  // ==== CHECKS ====
  integer play_start;
  integer n0;
  integer offs [0:4];
  integer k, nxt;
  integer cd_x0;
  integer n;
  integer lba_pick;
  initial begin
    offs[0] = 2; offs[1] = 20; offs[2] = 80; offs[3] = 300; offs[4] = 700;
    repeat (8) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);

    // ---- mount both media ----
    a_img_size = 64'(DISK_SECS) * 512;
    @(negedge clk); a_img_mounted = 1; repeat (3) @(negedge clk); a_img_mounted = 0;
    make_pcd;
    cd_img_size = img.size();
    @(negedge clk); cd_img_mounted = 1; repeat (3) @(negedge clk); cd_img_mounted = 0;
    repeat (20000) @(negedge clk);   // the CD's header fetch
    repeat (200) @(negedge clk);

    // ==== P0: the disk alone (the control: green with or without the fix) ====
    disk_read(3, "P0");
    disk_read(77, "P0");
    disk_read(5, "P0");
    disk_read(90, "P0");
    for (k = 30; k < 38; k++) disk_read(k, "P0 run");
    if (errors != 0) $fatal(1, "TB_PC9821_HPS_SLOT_INTEGRITY: FAIL - the disk-alone control failed (%0d errors)", errors);

    // ==== P1: the disk against a playing CD ====
    wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0);
    packet(8'h5A, 0, 8'h0F, 0, 0, 0, 0, 0, 8'd24, 0);   // MODE SENSE 0x0F: NEC mode (BCD MSF)
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0);            // TEST UNIT READY (the post-mount CHECK)
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    n0 = cdda_n;
    play_start = PLAY_FIRST + 150;
    begin
      integer f1; f1 = PLAY_FIRST + PLAY_SECS + 150;
      packet(8'h47, 0, 0, bcd8(play_start / 4500), bcd8((play_start / 75) % 60), bcd8(play_start % 75),
             bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0);
    end
    // each disk request lands a different number of clk after a CD transfer is acknowledged, so
    // it WAITS in the engine (sd_rd up, its own ack low) while that transfer's words go by
    nxt = 0;
    for (k = 0; k < 24 && errors < 6; k++) begin
      cd_x0 = n_cd_xfers;
      n = 0;
      while (!cd_sd_ack && n < 400000) begin @(negedge clk); n++; end
      if (!cd_sd_ack) begin
        // the player ran dry: no CD transfer left to land on
        $display("note: the CD fetched no more after %0d disk reads", k);
        k = 1000;
      end else begin
        repeat (offs[nxt]) @(negedge clk);
        nxt = (nxt + 1) % 5;
        lba_pick = (k * 29 + 7) % DISK_SECS;
        disk_read(lba_pick, "P1 (CD playing)");
        // let the player's next fetch come round
        repeat (50) @(negedge clk);
      end
    end
    if (k < 1000 && k < 24 && errors == 0) $display("note: loop ended early at %0d", k);

    // ==== P2: the CD-DA samples are the audio sectors' own, with none of the disk's words ====
    begin
      integer waited; waited = 0;
      while (cdda_n - n0 < PLAY_SECS * 588 && waited < 3000000) begin @(negedge clk); waited++; end
      repeat (20000) @(negedge clk);
      if (cdda_n - n0 != PLAY_SECS * 588) begin
        errors++;
        $display("FAIL: P2 %0d stereo samples streamed, want %0d (%0d sectors)", cdda_n - n0,
                 PLAY_SECS * 588, PLAY_SECS);
      end else
        for (int s = 0; s < PLAY_SECS * 588; s++) begin
          integer l, o;
          l = PLAY_FIRST + s / 588; o = (s % 588) * 4;
          if (cdda_log[n0 + s] !== {abyte(l, o + 3), abyte(l, o + 2), abyte(l, o + 1), abyte(l, o)}) begin
            errors++;
            $display("FAIL: P2 CD-DA sample %0d (sector %0d) = %08x, want %08x", s, l,
                     cdda_log[n0 + s],
                     {abyte(l, o + 3), abyte(l, o + 2), abyte(l, o + 1), abyte(l, o)});
            break;
          end
        end
    end
    $display("host transfers: disk %0d, cd %0d; disk reads %0d, bad %0d", n_disk_xfers, n_cd_xfers,
             disk_reqs, disk_bad);
    if (n_cd_xfers < 4) begin
      errors++;
      $display("FAIL: only %0d CD transfers - the bench never interleaved the two slots", n_cd_xfers);
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_HPS_SLOT_INTEGRITY: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_HPS_SLOT_INTEGRITY: FAIL (%0d errors)", errors);
  end

  initial begin
    #900_000_000;
    $fatal(1, "TB_PC9821_HPS_SLOT_INTEGRITY: TIMEOUT");
  end

endmodule
