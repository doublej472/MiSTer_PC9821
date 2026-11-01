// tb_pc9821_atapi_equiv - the ATAPI CD-ROM against its own pre-restructuring self, command by command.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATAPI_EQUIV:
// The CD-ROM drive src/pc9821/storage/pc9821_atapi.sv answers every packet command with exactly the values the drive of 284a2442 answered (tests/pc9821/pc9821_atapi_ref.sv, a byte-for-byte copy of it under another name, a golden model in the way pc9821_egc_ref.sv is): the same pseudo-random stream of ATA-level and packet commands is run through both drives, each behind its own hps_io slot model serving the same ISO, PCD or no medium, and after EVERY command the two traces must be equal - the packet-phase status, the interrupt-reason and byte-count registers of every data phase, every data byte, the completion STATUS, ERROR, sector count and cylinder registers. The stream covers TEST UNIT READY, REQUEST SENSE, INQUIRY, READ CAPACITY, READ(10) in and out of range, MODE SENSE(10) of every page code, 0x3F and an unknown one in both the default and the changeable form at allocation lengths from 0 to 255 (page 0x0F switching the drive to BCD MSF), READ TOC in formats 0 and 1 in LBA and MSF with every start track, READ SUB-CHANNEL, GET CONFIGURATION, START/STOP, SEEK, PLAY AUDIO(10) and MSF, PAUSE/RESUME, MODE SELECT, unknown opcodes, DEVICE RESET, EXECUTE DEVICE DIAGNOSTIC, IDENTIFY PACKET DEVICE and SRST, with the player held still (CDDA_REQ low) so its position is a function of the commands alone, plus plays of a few sectors run to completion with CDDA_REQ high whose streamed {R, L} samples must also be equal; the medium changes between the ISO, the PCD and an eject.
//
// It is an equivalence bench, not a conformance one: the expected value of every check is the previous drive's answer, which tb_pc9821_atapi pins against NP2kai. Its job is to let the drive be restructured for area with every guest-visible value held identical; a restructuring that changes one value of any command class above fails here.

// ==== DUT ====
module eq_side #(parameter REF = 0) (
    input wire clk,
    input wire rst_n
);
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] cd_dout;
  wire cd_own, cd_irq;
  reg         img_mounted = 0;
  reg  [63:0] img_size = 0;
  wire [31:0] sd_lba;
  wire [5:0]  sd_blk_cnt;
  wire        sd_rd;
  reg         sd_ack = 0, sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  reg         cdda_req = 0;
  wire        cdda_wr;
  wire [31:0] cdda_data;
  wire [7:0]  log_byte;
  wire        log_we;
  byte img [];

  // The new drive's read-ahead ports. CDDA_REQ4 low keeps it fetching one sector per request,
  // as the previous drive did, so the fetched stream compares; its played position follows a
  // ring that plays each sector the moment its last sample is written (CDDA_PLAYED one cycle
  // after every 588th CDDA_WR since the last flush), so a play completes when the previous
  // drive's did, a few cycles later, and every command sees the same position.
  wire       cdda_flush;
  reg  [9:0] pm_n = 0;
  reg        pm_played = 0;
  always @(posedge clk) begin
    pm_played <= 1'b0;
    if (!REF && cdda_flush) pm_n <= 10'd0;
    else if (cdda_wr) begin
      if (pm_n == 10'd587) begin pm_n <= 10'd0; pm_played <= 1'b1; end
      else pm_n <= pm_n + 10'd1;
    end
  end
  generate if (REF) begin : g_noflush assign cdda_flush = 1'b0; end endgenerate
  /* verilator lint_off PINCONNECTEMPTY */
  generate
    if (REF) begin : g_ref
      pc9821_atapi_ref #(.AUDIO_EN(1'b1), .LOG_EN(1'b0)) cd (
          .clk(clk), .rst_n(rst_n),
          .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(cd_dout),
          .io_own(cd_own), .irq(cd_irq),
          .img_mounted(img_mounted), .img_size(img_size),
          .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_ack(sd_ack),
          .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
          .cdda_req(cdda_req), .cdda_wr(cdda_wr), .cdda_data(cdda_data),
          .log_byte(log_byte), .log_we(log_we), .log_accept(1'b1)
      );
    end else begin : g_new
      pc9821_atapi #(.AUDIO_EN(1'b1), .LOG_EN(1'b0)) cd (
          .clk(clk), .rst_n(rst_n),
          .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(cd_dout),
          .io_own(cd_own), .irq(cd_irq),
          .img_mounted(img_mounted), .img_size(img_size),
          .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_ack(sd_ack),
          .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
          .cdda_req(cdda_req), .cdda_req4(1'b0), .cdda_played(pm_played), .cdda_flush(cdda_flush),
          .cdda_wr(cdda_wr), .cdda_data(cdda_data),
          .log_byte(log_byte), .log_we(log_we), .log_accept(1'b1)
      );
    end
  endgenerate
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- hps_io's side of slot 4 ----
  integer host_delay = 5;
  always @(negedge clk) begin : host
    reg [31:0] lba; integer words;
    if (sd_rd && !sd_ack) begin
      lba = sd_lba; words = (sd_blk_cnt + 1) * 256;
      repeat (host_delay) @(negedge clk);
      sd_ack = 1;
      repeat (3) @(negedge clk);
      for (int w = 0; w < words; w++) begin
        longint o; o = longint'(lba) * 512 + w * 2;
        sd_buff_addr = 13'(w);
        sd_buff_dout = {(o + 1 < img.size()) ? img[o + 1] : 8'h00, (o < img.size()) ? img[o] : 8'h00};
        sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0; @(negedge clk);
      end
      repeat (2) @(negedge clk);
      sd_ack = 0;
    end
  end

  // ---- the CD-DA stream, folded ----
  integer cdda_n = 0;
  reg [31:0] cdda_sum = 0, cdda_xor = 0;
  always @(posedge clk) if (cdda_wr) begin
    cdda_n   <= cdda_n + 1;
    cdda_sum <= cdda_sum + cdda_data;
    cdda_xor <= cdda_xor ^ {cdda_data[15:0], cdda_data[31:16]} ^ cdda_n;
  end

  // ---- the trace: every value the guest observed since the last clear ----
  byte unsigned trace [$];
  task automatic put(input [7:0] v);
    begin trace.push_back(v); end
  endtask
  task automatic put32(input [31:0] v);
    begin put(v[7:0]); put(v[15:8]); put(v[23:16]); put(v[31:24]); end
  endtask

  // ---- port access (one strobe cycle, the iobus's shape) ----
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
  task automatic rdw(output [15:0] w);
    reg [7:0] lo, hi;
    begin rd(16'h0640, lo); rd(16'h0641, hi); w = {hi, lo}; end
  endtask
  task automatic wait_notbusy;
    reg [7:0] s; integer n;
    begin
      n = 0;
      do begin rd(16'h074C, s); n = n + 1; end while (s[7] && n < 20000);
      put(s[7] ? 8'hEE : 8'h00);   // a drive that never clears BSY is itself a difference
    end
  endtask

  task automatic mount(input bit have, input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);
    end
  endtask

  task automatic regs_after;
    reg [7:0] v;
    begin
      rd(16'h064E, v); put(v);
      rd(16'h0642, v); put(v);
      rd(16'h0644, v); put(v);
      rd(16'h0646, v); put(v);
      rd(16'h0648, v); put(v);
      rd(16'h064A, v); put(v);
      rd(16'h064C, v); put(v);
    end
  endtask

  task automatic sel_cd;
    begin wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0); end
  endtask

  // A packet command, polled; every observed value goes to the trace.
  task automatic packet(input byte c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
    reg [7:0] s, ir, bl, bh; reg [15:0] w; integer cnt, phases;
    begin
      byte cdb [0:11];
      cdb = '{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, 8'h00, 8'h00};
      wr(16'h064E, 8'hA0);
      rd(16'h074C, s); put(s);
      rd(16'h0644, ir); put(ir);
      for (int k = 0; k < 6; k++) begin
        wr(16'h0640, cdb[2 * k]); wr(16'h0641, cdb[2 * k + 1]);
      end
      phases = 0;
      forever begin
        wait_notbusy;
        rd(16'h074C, s); put(s);
        if (!s[3]) break;
        rd(16'h0644, ir); rd(16'h0648, bl); rd(16'h064A, bh);
        put(ir); put(bl); put(bh);
        cnt = {bh, bl};
        for (int k = 0; k < (cnt + 1) / 2; k++) begin
          rdw(w);
          put(w[7:0]); put(w[15:8]);
        end
        phases++;
        if (phases > 64) begin put(8'hEF); break; end
      end
      regs_after;
    end
  endtask

  // An ATA-level command written to the CD, with its status registers (and a data phase, if any).
  task automatic ata(input [7:0] cmd, input integer words);
    reg [7:0] s; reg [15:0] w;
    begin
      wr(16'h064E, cmd);
      wait_notbusy;
      rd(16'h074C, s); put(s);
      if (s[3]) for (int k = 0; k < words; k++) begin rdw(w); put(w[7:0]); put(w[15:8]); end
      regs_after;
    end
  endtask

  task automatic srst;
    begin
      wr(16'h074C, 8'h06); repeat (20) @(negedge clk); wr(16'h074C, 8'h00);
      wait_notbusy;
      regs_after;
    end
  endtask

  // The streamed samples so far, as a trace entry.
  task automatic put_stream;
    begin put32(cdda_n); put32(cdda_sum); put32(cdda_xor); end
  endtask

endmodule

module tb_pc9821_atapi_equiv;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  eq_side #(.REF(1)) a (.clk(clk), .rst_n(rst_n));
  eq_side #(.REF(0)) b (.clk(clk), .rst_n(rst_n));

  // ==== STIMULUS ====
  integer errors = 0;
  integer ops = 0;
  reg [31:0] rs = 32'h2545F491;
  function automatic [31:0] rnd(input integer dummy);
    begin
      rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5);
      rnd = rs;
    end
  endfunction
  function automatic integer pick(input integer n);
    begin pick = rnd(0) % n; end
  endfunction

  // the images (as tb_pc9821_atapi builds them)
  // Big enough that the MSF arithmetic crosses minute boundaries (4500 frames, + the 150 offset), but
  // only the first FILLED sectors carry data: the commands that read or stream sectors stay inside them.
  // (the host model answers zeros past the end of `img`, so the DECLARED size can be far larger)
  integer iso_secs = 4400;
  integer pcd_secs = 6000;
  integer cap = 0;      // the sector count of the medium now mounted
  localparam integer FILLED   = 48;
  localparam integer TRK3     = 4400;
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
  task automatic make_iso;
    begin
      img = new[FILLED * 2048];
      foreach (img[k]) img[k] = 0;
      for (int l = 0; l < FILLED; l++)
        for (int i = 0; i < 2048; i++) img[l * 2048 + i] = dbyte(l, i);
    end
  endtask
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
      img = new[(FILLED + 1) * 2352];
      foreach (img[k]) img[k] = 0;
      img[0] = "P"; img[1] = "C"; img[2] = "9"; img[3] = "8";
      img[4] = "C"; img[5] = "D"; img[6] = "0"; img[7] = "1";
      img[8] = 3; img[9] = 1;
      img[12] = 8'(pcd_secs); img[13] = 8'(pcd_secs >> 8); img[14] = 8'(pcd_secs >> 16); img[15] = 8'(pcd_secs >> 24);
      pcd_entry(0, 8'h14, 0); pcd_entry(1, 8'h10, 10); pcd_entry(2, 8'h10, TRK3);
      pcd_entry(3, 8'h10, pcd_secs);
      for (int l = 0; l < FILLED; l++) begin
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

  // ==== CHECKS ====
  // ---- one operation on both drives, then the comparison ----
  task automatic compare(input string what);
    integer n;
    begin
      ops = ops + 1;
      if (a.trace.size() != b.trace.size()) begin
        errors++;
        $display("FAIL: op %0d %s: the traces have %0d and %0d entries", ops, what, a.trace.size(), b.trace.size());
      end else begin
        n = 0;
        foreach (a.trace[k]) if (a.trace[k] !== b.trace[k] && n == 0) begin
          errors++; n++;
          $display("FAIL: op %0d %s: trace entry %0d is %02x (old) vs %02x (new)", ops, what, k, a.trace[k], b.trace[k]);
        end
      end
      a.trace.delete(); b.trace.delete();
      if (errors > 20) $fatal(1, "TB_PC9821_ATAPI_EQUIV: FAIL (%0d errors, stopping)", errors);
    end
  endtask

  task automatic pk(input byte c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, input string what);
    begin
      fork
        a.packet(c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
        b.packet(c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
      join
      compare(what);
    end
  endtask

  task automatic at(input [7:0] cmd, input integer words, input string what);
    begin
      fork a.ata(cmd, words); b.ata(cmd, words); join
      compare(what);
    end
  endtask

  task automatic srst_both;
    begin fork a.srst(); b.srst(); join compare("SRST"); end
  endtask

  task automatic mount_both(input integer kind);   // 0 = eject, 1 = ISO, 2 = PCD
    longint sz;
    begin
      if (kind == 1) make_iso; else if (kind == 2) make_pcd; else img = new[0];
      a.img = img; b.img = img;
      // the declared size: an ISO is its sector count; a PCD is a header sector plus its sectors
      sz = (kind == 1) ? longint'(iso_secs) * 2048 : (kind == 2) ? longint'(pcd_secs + 1) * 2352 : 0;
      cap = (kind == 1) ? iso_secs : (kind == 2) ? pcd_secs : 0;
      fork
        a.mount(kind != 0, sz);
        b.mount(kind != 0, sz);
      join
    end
  endtask

  // The short plays run to completion with the player's CDDA_REQ high; the stream must be equal.
  task automatic play_to_end(input integer start, input integer len, input bit msf, input bit bcd);
    integer f0, f1;
    begin
      a.cdda_req = 1; b.cdda_req = 1;
      if (msf) begin
        f0 = start + 150; f1 = start + len + 150;
        if (bcd)
          pk(8'h47, 0, 0, bcd8(f0 / 4500), bcd8((f0 / 75) % 60), bcd8(f0 % 75),
             bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0, "PLAY MSF (BCD) to the end");
        else
          pk(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "PLAY MSF to the end");
      end else
        pk(8'h45, 0, 8'(start >> 24), 8'(start >> 16), 8'(start >> 8), 8'(start), 0, 8'(len >> 8), 8'(len), 0,
           "PLAY(10) to the end");
      repeat (150000) @(negedge clk);
      a.cdda_req = 0; b.cdda_req = 0;
      repeat (3000) @(negedge clk);
      a.put_stream(); b.put_stream();
      compare("the streamed samples");
    end
  endtask

  // A random LBA: mostly low, some around the minute boundaries (abs MSF = lba + 150), some anywhere.
  function automatic integer rlba(input integer dummy);
    integer m;
    begin
      m = pick(8);
      if (m < 4)      rlba = pick(40);
      else if (m < 6) rlba = 4340 + pick(24);
      else if (m == 6) rlba = TRK3 - 6 + pick(12);
      else            rlba = pick(cap + 20);
    end
  endfunction

  // One random command.
  task automatic random_op;
    integer k, p, al, t;
    reg [7:0] pc;
    begin
      k = pick(26);
      al = 0;
      case (pick(14))
        0: al = 0;   1: al = 1;   2: al = 2;  3: al = 4;   4: al = 5;   5: al = 8;  6: al = 12;
        7: al = 18;  8: al = 24;  9: al = 28; 10: al = 36; 11: al = 60;  12: al = 64; default: al = 255;
      endcase
      case (k)
        0: pk(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "TEST UNIT READY");
        1: pk(8'h03, 0, 0, 0, 8'(al), 0, 0, 0, 0, 0, "REQUEST SENSE");
        2: pk(8'h12, 0, 0, 0, 8'(al), 0, 0, 0, 0, 0, "INQUIRY");
        3: pk(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, "READ CAPACITY");
        4: begin
             case (pick(8))
               0: t = 0; 1: t = 1; 2: t = 9; 3: t = 19; 4: t = 20; 5: t = 29; 6: t = 30; default: t = 5;
             endcase
             pk(8'h28, 0, 0, 0, 0, 8'(t), 0, 0, 8'(pick(3)), 0, "READ(10)");
           end
        5, 6, 7: begin
             case (pick(8))
               0: pc = 8'h01; 1: pc = 8'h0D; 2: pc = 8'h0E; 3: pc = 8'h2A; 4: pc = 8'h0F; 5: pc = 8'h3F;
               6: pc = 8'h10; default: pc = 8'h3F;
             endcase
             pk(8'h5A, 0, pc | (pick(2) << 6), 0, 0, 0, 0, 8'(al >> 8), 8'(al), 0, "MODE SENSE(10)");
           end
        8, 9: pk(8'h42, 8'(pick(2) << 1), 8'(pick(4) == 0 ? 8'h00 : 8'h40), 8'(pick(4) == 0 ? pick(3) : 1),
                 0, 0, 0, 0, 8'(pick(3) == 0 ? al : 16), 0, "READ SUB-CHANNEL");
        10, 11: begin
             case (pick(6)) 0: t = 0; 1: t = 1; 2: t = 2; 3: t = 3; 4: t = 8'hAA; default: t = 4; endcase
             pk(8'h43, 8'(pick(2) << 1), 0, 0, 0, 0, 8'(t), 8'(al >> 8), 8'(al), 8'(pick(3) << 6), "READ TOC");
           end
        12: pk(8'h46, 0, 0, 0, 0, 0, 0, 8'(pick(2) ? 0 : al), 8'(pick(2) ? 0 : al), 0, "GET CONFIGURATION");
        13: pk(8'h1B, 0, 0, 0, 8'(pick(8) == 0 ? 8'h02 : pick(3)), 0, 0, 0, 0, 0, "START/STOP");
        14: begin
             t = rlba(0);
             pk(8'h2B, 0, 0, 8'(t >> 16), 8'(t >> 8), 8'(t), 0, 0, 0, 0, "SEEK");
           end
        15: begin
             t = rlba(0);
             pk(8'h45, 0, 0, 8'(t >> 16), 8'(t >> 8), 8'(t), 0, 8'(pick(2)), 8'(pick(8)), 0, "PLAY(10)");
           end
        16, 17: begin
             integer f0, f1;
             f0 = 150 + rlba(0) - (pick(4) == 0 ? 160 : 0); f1 = f0 + pick(10) - 2 + (pick(6) == 0 ? 4500 : 0);
             if (pick(2) && 1)
               pk(8'h47, 0, 0, bcd8(f0 / 4500), bcd8((f0 / 75) % 60), bcd8(f0 % 75),
                  bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0, "PLAY MSF (BCD)");
             else
               pk(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
                  8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "PLAY MSF");
           end
        18: pk(8'h4B, 0, 0, 0, 0, 0, 0, 0, 8'(pick(2)), 0, "PAUSE/RESUME");
        19: pk(8'h55, 8'(pick(4) == 0 ? 1 : 0), 0, 0, 0, 0, 0, 0, 0, 0, "MODE SELECT");
        20: begin
             case (pick(6)) 0: t = 8'hBE; 1: t = 8'h4E; 2: t = 8'hA8; 3: t = 8'h1E; 4: t = 8'h35; default: t = 8'h5B; endcase
             pk(8'(t), 0, 0, 0, 0, 0, 0, 0, 0, 0, "other opcode");
           end
        21: at(8'h08, 0, "DEVICE RESET");
        22: at(8'h90, 0, "EXECUTE DEVICE DIAGNOSTIC");
        23: at(8'hA1, 256, "IDENTIFY PACKET DEVICE");
        24: srst_both;
        default: begin
             // a sub-channel poll at a settled position, the way a game polls
             pk(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "SUB-CHANNEL poll");
           end
      endcase
    end
  endtask

  integer e, i, t;
  initial begin
    a.cdda_req = 0; b.cdda_req = 0;
    repeat (8) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    fork a.sel_cd(); b.sel_cd(); join

    // the power-on state, with no medium
    for (i = 0; i < 40; i++) random_op;

    for (e = 0; e < 10; e++) begin
      // the media: PCD, ISO, PCD, eject, PCD ...
      case (e % 8)
        0: begin pcd_secs = 6000;   mount_both(2); end
        1: begin iso_secs = 4400;   mount_both(1); end
        2: begin pcd_secs = 900000; mount_both(2); end
        3: mount_both(0);
        4: begin iso_secs = 1000000; mount_both(1); end
        5: begin pcd_secs = 6000;   mount_both(2); end
        6: begin iso_secs = 300000; mount_both(1); end
        default: begin pcd_secs = 1048575; mount_both(2); end
      endcase
      // NEC mode on for half the epochs (MODE SENSE page 0x0F, length 24 - as NECCD.SYS asks)
      if (e % 2 == 0) pk(8'h5A, 0, 8'h0F, 0, 0, 0, 0, 0, 8'd24, 0, "MODE SENSE 0F (NEC mode)");
      for (i = 0; i < 120; i++) random_op;
      // MODE SENSE swept: every page code, both value sets, allocation lengths across every boundary
      // of the reply (the header, each page, the run of all four, and past the end)
      if (e < 2) for (int pg = 0; pg < 10; pg++) for (int ch = 0; ch < 2; ch++) for (int al2 = 0; al2 < 26; al2++) begin
        integer als;
        case (al2) 0: als = 0; 1: als = 1; 2: als = 2; 3: als = 3; 4: als = 4; 5: als = 5; 6: als = 7; 7: als = 8;
                   8: als = 9; 9: als = 12; 10: als = 16; 11: als = 17; 12: als = 20; 13: als = 24; 14: als = 25;
                   15: als = 28; 16: als = 29; 17: als = 30; 18: als = 31; 19: als = 32; 20: als = 59; 21: als = 60;
                   22: als = 61; 23: als = 64; 24: als = 255; default: als = 8; endcase
        case (pg) 0: t = 8'h01; 1: t = 8'h0D; 2: t = 8'h0E; 3: t = 8'h2A; 4: t = 8'h0F; 5: t = 8'h3F;
                  6: t = 8'h00; 7: t = 8'h02; 8: t = 8'h10; default: t = 8'h3E; endcase
        pk(8'h5A, 0, 8'(t | (ch << 6)), 0, 0, 0, 0, 8'(als >> 8), 8'(als), 0, "MODE SENSE sweep");
      end
      // the minute boundaries of the MSF conversion, one frame either side (abs = pos + 150), and the
      // decades of the BCD formatter (90..99, the 7-bit minute's 100, 127 and its wrap at 128)
      if (e % 8 != 3) for (i = 0; i < 22; i++) begin
        integer bp;
        case (i) 0: bp = 4349; 1: bp = 4350; 2: bp = 4351; 3: bp = 4424; 4: bp = 4425; 5: bp = 4426;
                 6: bp = 4399; 7: bp = 4400; 8: bp = 4401; 9: bp = 5999; 10: bp = 8999; 11: bp = 8850;
                 12: bp = 90 * 4500 - 150; 13: bp = 99 * 4500 - 150; 14: bp = 100 * 4500 - 151;
                 15: bp = 127 * 4500 - 150; 16: bp = 128 * 4500 - 151; 17: bp = 128 * 4500 - 150;
                 18: bp = 89 * 4500 + 59 * 75 + 74 - 150; 19: bp = 99 * 4500 + 59 * 75 + 74 - 150;
                 20: bp = 95 * 4500 + 90 * 0 + 30 * 75 + 74 - 150; default: bp = 60 * 4500 - 150; endcase
        if (bp < cap) begin
          pk(8'h2B, 0, 0, 8'(bp >> 16), 8'(bp >> 8), 8'(bp), 0, 0, 0, 0, "SEEK (boundary)");
          pk(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "SUB-CHANNEL (boundary)");
          pk(8'h42, 8'h00, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "SUB-CHANNEL (boundary, LBA)");
        end
      end
      if (e % 8 != 3) for (i = 0; i < 8; i++) begin
        integer rl, rn;
        rl = cap - 1 + (i / 3) * 1 - (i == 6 ? 1 : 0);   // cap-1, cap, cap+1 .. and cap-2
        rn = 1 + (i % 3);
        pk(8'h28, 0, 8'(rl >> 24), 8'(rl >> 16), 8'(rl >> 8), 8'(rl), 0, 8'(rn >> 8), 8'(rn), 0, "READ(10) at the end");
      end
      if (e % 8 == 0 || e % 8 == 2 || e % 8 == 5 || e % 8 == 7) begin
        // plays to completion, with the stream compared
        play_to_end(12, 3, 1, e % 2 == 0);
        play_to_end(10, 2, 0, 0);
        play_to_end(11, 4, 1, e % 2 == 0);
        pk(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "SUB-CHANNEL after the plays");
      end
    end

    // ==== VERDICT ====
    $display("  %0d operations compared", ops);
    if (errors == 0) begin
      $display("TB_PC9821_ATAPI_EQUIV: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATAPI_EQUIV: FAIL (%0d errors)", errors);
  end

  initial begin
    #4_000_000_000;
    $fatal(1, "TB_PC9821_ATAPI_EQUIV: TIMEOUT");
  end
endmodule
