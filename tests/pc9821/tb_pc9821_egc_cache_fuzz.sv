`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_CACHE_FUZZ: a seeded, reproducible fuzz (seed 0xC0DEC0DE, 200 sequences of 16-64 steps, xorshift32) of the GVRAM's three CPU clients - the posted EGC write, the GRCG and the plain plane path - and the GVRAM's per-word fallback walk, over the block-RAM GVRAM array (the 8-slot write-combining buffer this bench was written for is gone). It drives randomized sequences of non-overlapping EGC, GRCG and plain reads and writes (each step waits for every client to go idle, so the ORDER is randomized, not the overlap) over random page-0/page-1 addresses with random byte enables, widths and posted-write-then-read-own-word shapes, checks every plain and GRCG read against a byte-exact golden image as it returns, holds every EGC store to NP2kai's WS_CPU datum (the CPU byte or word on every plane, memegc.c egc_opeb/egc_opew default) through both the EGC and the plain reader, requires the stream to enter the fallback walk (u_arb.m_mode), and after EVERY sequence compares the WHOLE 256 KiB GVRAM array against that golden, so a lost or misplaced write cannot hide.
//
// WHY THIS EXISTS. An earlier review probed the GVRAM's write-combining buffer with 17 hand-named
// cases and found zero mismatches; this bench was the adversarial half of that result, a seeded
// random stream that mixes the clients and the widths. The buffer has since been removed (the
// GVRAM is block RAM, each store its own access) and the buffer-era shapes (dirty eviction, stale
// over-fetch, buffer seed) went with it. NOTE THE SCOPE: op() waits for every client to go idle
// before the next step, so the accesses never overlap in time - the fuzz randomizes the ORDER,
// widths, lanes and clients of non-overlapping accesses. Reproducibility is the contract - the seed
// is printed, the RNG is xorshift32, and a mismatch dumps every op of the failing sequence with the
// expected-vs-actual bytes.
//
// THE ORACLE. Plain and GRCG writes have a deterministic byte effect and drive the golden exactly.
// The EGC stores are WS_CPU stores with every plane enabled and a full mask, whose datum NP2kai
// fixes (memegc.c egc_opeb/egc_opew `default`: the CPU byte or word on every plane), so they drive
// the golden exactly too, and both the EGC reader and the plain reader are held to it.

`default_nettype none

module tb_pc9821_egc_cache_fuzz;
  localparam [31:0] GVRAM_BASE = 32'h0300_0000;
  localparam integer ACCEPT_LAT = 2;
  localparam integer WRITE_LAT  = 2;
  localparam [31:0] SEED        = 32'hC0DE_C0DE;
  localparam integer NSEQ       = 200;   // randomized sequences
  localparam integer MIN_STEPS  = 16;
  localparam integer MAX_STEPS  = 64;

  reg clk = 0;
  always #10 clk = ~clk;
  reg reset = 1;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  reg        access_page = 1'b0;
  reg  [1:0] win_plane = 2'd0;
  reg [14:0] win_offset = 15'd0;
  reg [31:0] cpu_din = 32'd0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 1'b0;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'h0000, egc_fgbg = 16'h0000, egc_ope = 16'h0000,
             egc_fg = 16'h0000, egc_mask = 16'hFFFF, egc_bg = 16'h0000,
             egc_sft = 16'h0000, egc_leng = 16'h0000;
  reg        egc_shift_we = 1'b0;

  reg        scan_enable = 1'b0, scan_line_tick = 1'b0, scan_page = 1'b0;
  reg [14:0] scan_line_base = 15'd0;
  reg  [6:0] line_rd_addr = 7'd0;
  reg        line_rd_sel = 1'b0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;


  pc9821_gvram_dut dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  

  // ---- the golden image: the plane byte at (page, plane, plane offset) ----
  reg [7:0] gold [0:262143];
  function integer gi(input integer pg, input integer pl, input integer off);
    gi = ((pg * 32768) + off) * 4 + pl;
  endfunction

  integer errors = 0;
  integer checks = 0;
  // Entries into the GVRAM's per-word fallback walk (u_arb.m_mode rising): the claim names the walk,
  // so a stream that never reaches it fails rather than passing vacuously.
  integer walk_entries = 0;
  reg     m_mode_q = 1'b0;
  always @(posedge clk) begin
    if (!reset && dut.u_arb.m_mode && !m_mode_q) walk_entries = walk_entries + 1;
    m_mode_q <= dut.u_arb.m_mode;
  end

  // ---- the reproducible PRNG: xorshift32, seeded once; every step is a function of it ----
  reg [31:0] rng;
  function [31:0] rnd;
    begin
      rng = rng ^ (rng << 13);
      rng = rng ^ (rng >> 17);
      rng = rng ^ (rng << 5);
      rnd = rng;
    end
  endfunction

  // ---- the failing sequence's log, so a mismatch is reproducible from the seed ----
  integer cur_seq = 0, cur_step = 0, cur_op = 0;
  integer log_n = 0, log_op [0:127], log_pg [0:127], log_pl [0:127], log_off [0:127];
  reg [31:0] log_dat [0:127];

  task automatic rec(input integer o, input integer pg, input integer pl,
                     input integer off, input [31:0] dat);
    begin
      if (log_n < 128) begin
        log_op[log_n] = o; log_pg[log_n] = pg; log_pl[log_n] = pl;
        log_off[log_n] = off; log_dat[log_n] = dat;
      end
      log_n = log_n + 1;
    end
  endtask

  task automatic dump_seq;
    integer q;
    begin
      $display("NOTE egc_cache_fuzz: FAILED sequence %0d (%0d step(s)), seed 0x%08x:",
               cur_seq, log_n, SEED);
      for (q = 0; q < log_n; q = q + 1)
        $display("NOTE egc_cache_fuzz:   step %0d op %0d pg %0d pl %0d off %04x dat %08x",
                 q, log_op[q], log_pg[q], log_pl[q], log_off[q], log_dat[q]);
    end
  endtask

  task automatic fail_text(input [8*200-1:0] what);
    begin
      $display("FAIL [seq %0d step %0d op %0d] %0s", cur_seq, cur_step, cur_op, what);
      errors = errors + 1;
    end
  endtask

  task automatic chk_byte(input integer pg, input integer pl, input integer off,
                          input [7:0] got, input [8*70-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== gold[gi(pg, pl, off)]) begin
        $display("FAIL [seq %0d step %0d op %0d] %0s: pg%0d pl%0d off %04x got %02x want %02x",
                 cur_seq, cur_step, cur_op, tag, pg, pl, off, got, gold[gi(pg, pl, off)]);
        errors = errors + 1;
      end
    end
  endtask

  // ==== STIMULUS ====
  // One CPU access. `egc` routes it to the EGC (a SHIFT_CPU load when it is a load, a WS_CPU
  // store when it is a store); otherwise the plain path owns it. The handshake is the real one.
  // The load's mode is SHIFT_CPU (0x0400) rather than COMPAREREAD (0x2000): NP2kai returns
  // `mem[ad + planead[pl]]` for it (mem/memegc.c:1091-1098), the same plane datum this bench
  // checks against the plain reader -- whereas the machine compares in the PAT mode too, so
  // COMPAREREAD returns a colour-key MASK and cannot observe a plane at all (EGCREAD.CSV
  // RD22_PATSEL; pc9821_egc.sv's ope_cmprd). The read-plane selector follows the window so the
  // datum is the plane the access addressed.
  task automatic op(input pg, input [1:0] plane, input [14:0] off, input [31:0] din,
                    input [3:0] be, input wr, input egc, output [31:0] dout);
    begin
      @(negedge clk);
      access_page = pg;
      egc_gate    = egc;
      egc_ope     = wr ? 16'h0000 : 16'h0400;   // WS_CPU store / SHIFT_CPU load
      egc_fgbg    = {6'h00, plane[1:0], 6'h00, plane[1:0]};
      win_plane   = plane;
      win_offset  = off;
      cpu_din     = din;
      cpu_be      = be;
      cpu_write   = wr;
      cpu_valid   = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      // `egc_gate` is the machine's EGC arming level (0x6A num 2 AND 0x7C bit 7), not a per-access
      // signal: it is held through the response and released after it.
      // The negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      dout = 32'd0;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end
      @(negedge clk);
      egc_gate = 1'b0;
      // THE DEVICE IS DONE when it will take the NEXT access: every owner back in its idle state
      // AND the GVRAM's own acceptance period spent. pc9821_gvram_arb's GVRAM_PERIODS prices a
      // GVRAM access at the machine's own per-operation TIME, so a step that returned while the
      // period was still running would leave that operation's array work to land in the NEXT
      // step's window - which is exactly what the sequence-end image check saw (the
      // accept-and-decouple is unaffected: the store's ready still pulses at its accept).
      while ((dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) || (dut.u_arb.gstate != 3'd0) ||
             dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 4'd0) ||
             (dut.u_arb.hold_left != 16'd0)) @(negedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  // One plain-path byte store/load at a column (the shape every plane window uses).
  task automatic put_byte(input integer pg, input [1:0] pl, input [14:0] off,
                          input [7:0] val);
    reg [31:0] d;
    begin
      op(pg, pl, off, {4{val}}, 4'b0001 << off[1:0], 1'b1, 1'b0, d);
      gold[gi(pg, pl, off)] = val;
    end
  endtask

  task automatic get_byte(input integer pg, input [1:0] pl, input [14:0] off,
                          input [8*70-1:0] tag);
    reg [31:0] d;
    begin
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b0, d);
      chk_byte(pg, pl, off, d[{off[1:0], 3'b000} +: 8], tag);
    end
  endtask

  // A partial plain store with an arbitrary byte-enable: lane k writes plane pl at base+k. This
  // is the partial-store shape.
  task automatic plain_write_be(input integer pg, input [1:0] pl, input [14:0] base,
                                input [31:0] dat, input [3:0] be);
    reg [31:0] sink;
    integer k;
    begin
      op(pg, pl, base, dat, be, 1'b1, 1'b0, sink);
      for (k = 0; k < 4; k = k + 1)
        if (be[k]) gold[gi(pg, pl, base + k)] = dat[8*k +: 8];
    end
  endtask

  task automatic plain_read_be(input integer pg, input [1:0] pl, input [14:0] base,
                               input [3:0] be, input [8*70-1:0] tag);
    reg [31:0] d;
    integer k;
    begin
      op(pg, pl, base, 32'd0, be, 1'b0, 1'b0, d);
      for (k = 0; k < 4; k = k + 1)
        if (be[k]) chk_byte(pg, pl, base + k, d[8*k +: 8], tag);
    end
  endtask

  task automatic dword_write(input integer pg, input [1:0] pl, input [14:0] base,
                             input [31:0] dat);
    begin
      plain_write_be(pg, pl, base, dat, 4'hF);
    end
  endtask

  task automatic dword_read(input integer pg, input [1:0] pl, input [14:0] base,
                            input [8*70-1:0] tag);
    begin
      plain_read_be(pg, pl, base, 4'hF, tag);
    end
  endtask

  // A line load: 16 consecutive plane offsets of ONE plane, gathered from the route's four
  // word beats in order (beat N = line word N).
  task automatic line_read(input integer pg, input [1:0] pl, input [14:0] base,
                           input [8*70-1:0] tag);
    integer k;
    reg [127:0] d;
    begin
      @(negedge clk);
      access_page  = pg[0];
      win_plane    = pl;
      win_offset   = base;
      cpu_be       = 4'hF;
      cpu_write    = 1'b0;
      cpu_line_read = 1'b1;
      cpu_valid    = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 1'b0; cpu_line_read = 1'b0;
      #1;
      // The four word beats stream through the walk (P3): gather them in order, beat N into
      // line word N exactly as the L1 does.
      d = 128'd0;
      for (k = 0; k < 4; k = k + 1) begin
        while (!cpu_line_word_valid) begin @(posedge clk); #1; end
        d[{k[1:0], 5'b00000} +: 32] = cpu_line_word;
        @(posedge clk); #1;
      end
      repeat (2) @(posedge clk);
      for (k = 0; k < 16; k = k + 1)
        chk_byte(pg, pl, base + k, d[{k[3:0], 3'b000} +: 8], tag);
    end
  endtask

  // An EGC store's DATUM is NP2kai's: the stores here run WS_CPU (ope 0x0000, so ope&0x1800 is
  // neither 0x0800 nor 0x1000) with every plane enabled (0x4A0 = 0x0000) and mask 0xFFFF, and
  // memegc.c's egc_opeb / egc_opew `default` case then writes the CPU byte / word itself to every
  // plane (pc9821_egc_ref.sv egc_opeb/egc_opew `default:` dqw[p] = value; the word's mask2 ANDs a
  // srcmask the re-arm just reset to 0xFFFF). So the golden is set to that datum FIRST and both
  // readers are held to it: the EGC reader (behind the posted store) and then the plain reader.
  // A dropped, misplaced or wrong-datum EGC store fails here, not only a reader disagreement.
  task automatic egc_store_chk(input integer pg, input [1:0] pl, input [14:0] off,
                               input [7:0] want, input [8*70-1:0] tag);
    reg [31:0] d;
    begin
      gold[gi(pg, pl, off)] = want;
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b1, d);
      chk_byte(pg, pl, off, d[{off[1:0], 3'b000} +: 8], tag);
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b0, d);
      chk_byte(pg, pl, off, d[{off[1:0], 3'b000} +: 8], tag);
    end
  endtask

  task automatic egc_put_raw(input integer pg, input [14:0] off, input [7:0] val);
    reg [31:0] d;
    begin
      op(pg, 2'd0, off, {4{val}}, 4'b0001 << off[1:0], 1'b1, 1'b1, d);
    end
  endtask

  task automatic egc_put(input integer pg, input [14:0] off, input [7:0] val);
    integer pp;
    begin
      egc_put_raw(pg, off, val);
      for (pp = 0; pp < 4; pp = pp + 1)
        egc_store_chk(pg, pp[1:0], off, val, "EGC byte store: the CPU byte on every plane");
    end
  endtask

  task automatic egc_get(input integer pg, input [1:0] pl, input [14:0] off,
                         input [8*70-1:0] tag);
    reg [31:0] d;
    begin
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b1, d);
      chk_byte(pg, pl, off, d[{off[1:0], 3'b000} +: 8], tag);
    end
  endtask

  task automatic egc_get_dword(input integer pg, input [1:0] pl, input [14:0] off,
                               input [8*70-1:0] tag);
    integer k;
    reg [31:0] d;
    begin
      op(pg, pl, off, 32'd0, 4'hF, 1'b0, 1'b1, d);
      for (k = 0; k < 4; k = k + 1)
        chk_byte(pg, pl, off + k, d[8*k +: 8], tag);
    end
  endtask

  task automatic egc_get_word(input integer pg, input [1:0] pl, input [14:0] off,
                              input [8*70-1:0] tag);
    reg [31:0] d;
    begin
      if (off[1:0] == 2'd0) begin
        op(pg, pl, off, 32'd0, 4'b0011, 1'b0, 1'b1, d);
        chk_byte(pg, pl, off + 0, d[7:0], tag);
        chk_byte(pg, pl, off + 1, d[15:8], tag);
      end else begin
        op(pg, pl, off, 32'd0, 4'b1100, 1'b0, 1'b1, d);
        chk_byte(pg, pl, off + 0, d[23:16], tag);
        chk_byte(pg, pl, off + 1, d[31:24], tag);
      end
    end
  endtask

  task automatic egc_arm;
    begin
      @(negedge clk);
      egc_sft = 16'h0000;
      egc_leng = 16'h0010;
      egc_shift_we = 1'b1;
      @(negedge clk);
      egc_shift_we = 1'b0;
      @(negedge clk);
    end
  endtask

  // An EGC word store (be 0011 at a dword base): the CPU word lands on every plane.
  task automatic egc_put_word(input integer pg, input [14:0] off, input [15:0] data);
    reg [31:0] d;
    integer pp;
    begin
      egc_arm;
      op(pg, 2'd0, off, {16'd0, data}, 4'b0011, 1'b1, 1'b1, d);
      for (pp = 0; pp < 4; pp = pp + 1) begin
        egc_store_chk(pg, pp[1:0], off + 1, data[15:8], "EGC word store: high byte on every plane");
        egc_store_chk(pg, pp[1:0], off + 0, data[7:0],  "EGC word store: low byte on every plane");
      end
    end
  endtask

  // A GRCG store with a PARTIAL plane mask (active-high enable): only the enabled planes take the
  // tile, the partial-byte / full-word-hit store shape.
  task automatic grcg_put_mask(input integer pg, input [14:0] off, input [7:0] tile,
                               input [3:0] pmask);
    reg [31:0] d;
    integer k;
    begin
      @(negedge clk);
      grcg_we = 1'b1; grcg_addr = 8'h7C; grcg_din = 8'h80 | (~pmask);
      @(negedge clk); grcg_we = 1'b0;
      grcg_we = 1'b1; grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_we = 1'b0;
      op(pg, 2'd0, off, 32'hFFFF_FFFF, 4'hF, 1'b1, 1'b0, d);
      for (k = 0; k < 4; k = k + 1)
        if (pmask[k]) begin
          gold[gi(pg, k, off + 0)] = tile;
          gold[gi(pg, k, off + 1)] = tile;
          gold[gi(pg, k, off + 2)] = tile;
          gold[gi(pg, k, off + 3)] = tile;
        end
      @(negedge clk); grcg_we = 1'b1; grcg_addr = 8'h7C; grcg_din = 8'h00;
      @(negedge clk); grcg_we = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // A GRCG TDW store: mode bit 7 set, all four planes enabled -> ONE full-word store per CPU lane.
  task automatic grcg_put(input integer pg, input [15:0] addr_off, input [7:0] tile);
    reg [31:0] sink;
    integer k;
    begin
      @(negedge clk);
      grcg_we   = 1'b1;
      grcg_addr = 8'h7C; grcg_din = 8'h80;
      @(negedge clk); grcg_we = 1'b0;
      grcg_we = 1'b1;
      grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk);
      grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk);
      grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk);
      grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_we = 1'b0;
      op(pg, 2'd0, addr_off, 32'hFFFF_FFFF, 4'hF, 1'b1, 1'b0, sink);
      for (k = 0; k < 4; k = k + 1) begin
        gold[gi(pg, 0, addr_off + k)] = tile;
        gold[gi(pg, 1, addr_off + k)] = tile;
        gold[gi(pg, 2, addr_off + k)] = tile;
        gold[gi(pg, 3, addr_off + k)] = tile;
      end
      @(negedge clk); grcg_we = 1'b1; grcg_addr = 8'h7C; grcg_din = 8'h00;
      @(negedge clk); grcg_we = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // A GRCG RMW store: the GRCG READS the column first - through the GVRAM's own read path - and
  // writes back (old & ~data) | (tile & data). A stale read
  // corrupts the merge, so the golden is computed byte by byte from the current golden.
  task automatic grcg_rmw(input integer pg, input [14:0] off, input [7:0] tile,
                          input [3:0] pmask, input [7:0] din);
    reg [31:0] d;
    integer k, p;
    reg [14:0] w;
    begin
      @(negedge clk);
      grcg_we = 1'b1; grcg_addr = 8'h7C; grcg_din = 8'hC0 | (~pmask);
      @(negedge clk); grcg_we = 1'b0;
      grcg_we = 1'b1; grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_we = 1'b0;
      op(pg, 2'd0, off, {4{din}}, 4'hF, 1'b1, 1'b0, d);
      for (k = 0; k < 4; k = k + 1) begin
        w = (off & 15'h7FFC) | k[14:0];
        for (p = 0; p < 4; p = p + 1)
          if (pmask[p])
            gold[gi(pg, p, w)] = (gold[gi(pg, p, w)] & ~din) | (tile & din);
      end
      @(negedge clk); grcg_we = 1'b1; grcg_addr = 8'h7C; grcg_din = 8'h00;
      @(negedge clk); grcg_we = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // A raster line tick between sequences (the write-combining buffer it once flushed is gone).
  task automatic line_tick;
    begin
      @(negedge clk); scan_line_tick = 1'b1; @(negedge clk); scan_line_tick = 1'b0;
      repeat (5) @(posedge clk);
    end
  endtask

  // The whole GVRAM array against the golden model.
  // The GVRAM array is four byte-lane M10K arrays (a synthesis decision), so a word's
  // byte `pl` is lane `pl` of the word at `w`.
  function [7:0] gvmem_byte(input [15:0] w, input [1:0] pl);
    case (pl)
      2'd0: gvmem_byte = dut.u_gmem.mem0[w];
      2'd1: gvmem_byte = dut.u_gmem.mem1[w];
      2'd2: gvmem_byte = dut.u_gmem.mem2[w];
      default: gvmem_byte = dut.u_gmem.mem3[w];
    endcase
  endfunction

  task automatic sdram_chk(input [8*70-1:0] tag);
    integer w, pl;
    begin
      for (w = 0; w < 65536; w = w + 1)
        for (pl = 0; pl < 4; pl = pl + 1) begin
          checks = checks + 1;
          if (gvmem_byte(w[15:0], pl[1:0]) !== gold[(w * 4) + pl]) begin
            $display("FAIL [seq %0d step %0d op %0d] %0s: GVRAM word %04x plane %0d = %02x want %02x",
                     cur_seq, cur_step, cur_op, tag, w, pl,
                     gvmem_byte(w[15:0], pl[1:0]), gold[(w * 4) + pl]);
            errors = errors + 1;
          end
        end
    end
  endtask

  // ==== CHECKS ====
  integer i, k, s, nsteps;
  integer total_steps = 0;
  integer seq_errors0;
  integer win_base_i;
  reg [14:0] win_base, win_mask;

  // One randomized step. Every parameter is drawn ONCE into a named variable and the op uses that
  // variable, so the logged step (op, pg, pl, off, dat) reproduces it exactly from the seed.
  task automatic do_step(input integer sx);
    integer o, pg, pl, offi;
    reg [31:0] dat;
    reg [7:0]  val;
    reg [3:0]  be;
    begin
      cur_step = sx;
      o    = rnd() % 17;
      cur_op = o;
      pg   = rnd() & 1;
      pl   = rnd() & 3;
      offi = (win_base + (rnd() & win_mask)) & 32'h7FFF;
      dat  = rnd();
      val  = dat[7:0];
      rec(o, pg, pl, offi, dat);
      case (o)
        0: put_byte(pg, pl[1:0], offi[14:0], val);
        1:  get_byte(pg, pl[1:0], offi[14:0], "plain byte read");
        2: begin be = dat[4] ? 4'b0011 : 4'b1100;
                 plain_write_be(pg, pl[1:0], offi[14:0] & 15'h7FFC, dat, be); end
        3: begin be = dat[4] ? 4'b0011 : 4'b1100;
                 plain_read_be(pg, pl[1:0], offi[14:0] & 15'h7FFC, be, "plain word read"); end
        4:  dword_write(pg, pl[1:0], offi[14:0] & 15'h7FFC, dat);
        5:  dword_read(pg, pl[1:0], offi[14:0] & 15'h7FFC, "plain dword read");
        6: begin be = (dat[7:4] == 4'h0) ? 4'hF : dat[7:4];
                 plain_write_be(pg, pl[1:0], offi[14:0] & 15'h7FFC, dat, be); end
        7:  line_read(pg, pl[1:0], offi[14:0] & 15'h7FF0, "plain line read");
        8: grcg_put(pg, offi[14:0] & 15'h7FFC, val);
        9: grcg_put_mask(pg, offi[14:0] & 15'h7FFC, val, dat[11:8]);
        10: grcg_rmw(pg, offi[14:0] & 15'h7FFC, val, dat[11:8], dat[15:8]);
        11: egc_get(pg, pl[1:0], offi[14:0], "EGC byte read");
        12: egc_get_dword(pg, pl[1:0], offi[14:0] & 15'h7FFC, "EGC dword read");
        13: egc_get_word(pg, pl[1:0], offi[14:0] & 15'h7FFE, "EGC word read");
        14: egc_put(pg, offi[14:0], val);
        15: egc_put_word(pg, offi[14:0] & 15'h7FFC, dat[15:0]);
        // posted write then read its own word: the EGC store is posted on the accept, so a read of
        // the same word lands behind it and must return the new value on the EGC, plain and line.
        16: begin egc_put_raw(pg, offi[14:0], val);
                  for (k = 0; k < 4; k = k + 1)
                    egc_store_chk(pg, k[1:0], offi[14:0], val, "posted: the CPU byte on every plane");
                  get_byte(pg, pl[1:0], offi[14:0], "posted: plain read own word");
                  egc_get(pg, pl[1:0], offi[14:0], "posted: EGC read own word");
                  line_read(pg, pl[1:0], offi[14:0] & 15'h7FF0, "posted: line read own word"); end
        default: put_byte(pg, pl[1:0], offi[14:0], val);
      endcase
    end
  endtask

  initial begin
    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (8) @(posedge clk);

    for (i = 0; i < 262144; i = i + 1) gold[i] = 8'h00;

    rng = SEED;
    $display("NOTE egc_cache_fuzz: seed 0x%08x, %0d randomized sequence(s), %0d..%0d step(s) each",
             SEED, NSEQ, MIN_STEPS, MIN_STEPS + MAX_STEPS);

    for (cur_seq = 0; cur_seq < NSEQ; cur_seq = cur_seq + 1) begin
      win_base_i = rnd() & 32'h7800;
      win_base   = win_base_i[14:0];
      case (rnd() & 3)
        0:       win_mask = 15'h003F;
        1:       win_mask = 15'h00FF;
        2:       win_mask = 15'h03FF;
        default: win_mask = 15'h00FF;
      endcase
      log_n        = 0;
      seq_errors0  = errors;
      nsteps       = MIN_STEPS + (rnd() % (MAX_STEPS + 1));
      total_steps  = total_steps + nsteps;
      for (s = 0; s < nsteps; s = s + 1)
        do_step(s);
      line_tick;
      sdram_chk("sequence end");
      if (errors > seq_errors0) dump_seq;
    end

    line_tick;

    // ==== VERDICT ====
    $display("NOTE egc_cache_fuzz: %0d sequence(s), %0d step(s), seed 0x%08x, %0d coherence check(s), %0d mismatch(es), %0d fallback-walk entries",
             NSEQ, total_steps, SEED, checks, errors, walk_entries);
    if (walk_entries == 0) begin
      $display("FAIL: the stream never entered the GVRAM's fallback walk (u_arb.m_mode)");
      errors = errors + 1;
    end
    if (errors == 0) begin
      $display("TB_PC9821_EGC_CACHE_FUZZ: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_EGC_CACHE_FUZZ: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_EGC_CACHE_FUZZ: FAIL");
    end
  end

  // ==== VERDICT BOUND ====
  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_EGC_CACHE_FUZZ: FAIL (timed out)");
  end

endmodule

`default_nettype wire
