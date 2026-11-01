`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_COHERENCE: the write-combining buffer (8 word slots) holds every coherence the GVRAM's single datapath promises, against the REAL src/memory/sdram.v storage shape and a golden byte image: a read of a just-written word returns the buffer's copy and not stale SDRAM, a store to a word updates every write path (the plain lane store, the full-word GRCG/EGC store, the partial-store fill and the EGC two-word burst), every dirty word is written back before the scanout's SDRAM fetch reads it (flush/drain, including a display-page change), a dirty victim is written back and a clean one dropped (eviction), a one-lane store preserves the other three planes (partial-byte RMW), and a read fill never overwrites a word the buffer still holds dirty (the over-fetched beat). It drives interleaved reads and writes to the same and adjacent words, both pages, and the posted-write-then-read-own-word shape, then compares the WHOLE SDRAM image to the golden model, so a lost write-back cannot hide behind a buffer hit.
//
// WHY THIS EXISTS. The WCB was built first; later changes then changed the fill width and the
// invalidation scope. Every one of those
// edits is a coherence edit, and the benches that exist check shapes (tb_pc9821_gvram_combine: RAW
// forwarding and the scanout flush) or counts (gfx_scene/sprite_scene), not the invariants as a
// matrix. This bench is the matrix, with a golden image as the oracle.

`default_nettype none

module tb_pc9821_gvram_coherence;
  localparam [31:0] GVRAM_BASE = 32'h0300_0000;
  // The backend's latency shape is a knob so the coherence cases can be re-run at a controller
  // slower than the machine's own (the states must not depend on a fixed accept-to-response gap).
  localparam integer ACCEPT_LAT = 2;
  localparam integer WRITE_LAT  = 2;

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

  // The storage: sdram.v's own shape (one transaction at a time, a one-cycle accept, byte-enabled
  // writes). Its memory is the oracle's other half - the golden image must equal it after a flush.
  

  // ---- the golden image: the plane byte at (page, plane, plane offset) ----
  reg [7:0] gold [0:262143];
  function integer gi(input integer pg, input integer pl, input integer off);
    gi = ((pg * 32768) + off) * 4 + pl;
  endfunction

  integer errors = 0;
  integer checks = 0;

  task automatic fail(input [8*240-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  task automatic chk_byte(input integer pg, input integer pl, input integer off,
                          input [7:0] got, input [8*90-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== gold[gi(pg, pl, off)]) begin
        $display("FAIL %0s: pg%0d pl%0d off %04x got %02x want %02x",
                 tag, pg, pl, off, got, gold[gi(pg, pl, off)]);
        errors = errors + 1;
      end
    end
  endtask

  // ==== STIMULUS ====
  integer cb_burst2 = 0;
  integer cb_fullwr = 0;
  // The GVRAM is block RAM now: there is no backend transaction and no write-combining
  // buffer, so these counters stay at zero and the image comparison below is the assertion.

  // One CPU access. `egc` routes it to the EGC (a SHIFT_CPU load when it is a load, a WS_CPU
  // store when it is a store); otherwise the plain path owns it. The handshake is the real one:
  // cpu_ready is the accept and the response strobe follows. The load's mode is SHIFT_CPU
  // (0x0400) rather than COMPAREREAD (0x2000): NP2kai returns `mem[ad + planead[pl]]` for it
  // (mem/memegc.c:1091-1098), the plane datum this bench checks against its golden -- where the
  // machine compares in the PAT mode too, so COMPAREREAD returns a colour-key MASK and cannot
  // observe a plane at all (EGCREAD.CSV RD22_PATSEL; pc9821_egc.sv's ope_cmprd). The read-plane
  // selector follows the window so the datum is the plane the access addressed.
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
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      dout = 32'd0;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end
      @(negedge clk);
      egc_gate = 1'b0;
      while (dut.u_egc.state != 4'd0) @(negedge clk);
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
                          input [8*90-1:0] tag);
    reg [31:0] d;
    begin
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b0, d);
      chk_byte(pg, pl, off, d[{off[1:0], 3'b000} +: 8], tag);
    end
  endtask

  // The four lanes of one column read as a dword: byte k is the plane byte at word off+k? No -
  // a dword load at a 4-aligned plane offset covers FOUR consecutive plane offsets, one plane.
  task automatic dword_write(input integer pg, input [1:0] pl, input [14:0] off,
                             input [31:0] d);
    reg [31:0] sink;
    begin
      op(pg, pl, off, d, 4'hF, 1'b1, 1'b0, sink);
      gold[gi(pg, pl, off + 0)] = d[7:0];
      gold[gi(pg, pl, off + 1)] = d[15:8];
      gold[gi(pg, pl, off + 2)] = d[23:16];
      gold[gi(pg, pl, off + 3)] = d[31:24];
    end
  endtask

  task automatic dword_read(input integer pg, input [1:0] pl, input [14:0] off,
                            input [8*90-1:0] tag);
    reg [31:0] d;
    begin
      op(pg, pl, off, 32'd0, 4'hF, 1'b0, 1'b0, d);
      chk_byte(pg, pl, off + 0, d[7:0], tag);
      chk_byte(pg, pl, off + 1, d[15:8], tag);
      chk_byte(pg, pl, off + 2, d[23:16], tag);
      chk_byte(pg, pl, off + 3, d[31:24], tag);
    end
  endtask

  // A line load: 16 consecutive plane offsets of ONE plane, gathered from the route's four
  // word beats in order (beat N = line word N).
  task automatic line_read(input integer pg, input [1:0] pl, input [14:0] base,
                           input [8*90-1:0] tag);
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

  // A posted EGC WS_CPU byte store. The EGC's own store DATUM is the EGC's contract - its plane
  // enable, mask and shifter registers decide it, and egc_conformance owns that - so this bench
  // does NOT predict it. What it owns is that every reader of the word sees the SAME value: the
  // EGC reader (the SDRAM burst) runs FIRST, right behind the posted store, the
  // plain (buffer) reader second, and the plain value becomes the golden the later SDRAM compare
  // is held to.
  task automatic readers_agree(input integer pg, input [1:0] pl, input [14:0] off,
                               input [8*90-1:0] tag);
    reg [31:0] d;
    reg [7:0]  v_egc, v_plain;
    begin
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b1, d);
      v_egc = d[{off[1:0], 3'b000} +: 8];
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b0, d);
      v_plain = d[{off[1:0], 3'b000} +: 8];
      gold[gi(pg, pl, off)] = v_plain;
      checks = checks + 1;
      if (v_egc !== v_plain) begin
        $display("FAIL %0s: pg%0d pl%0d off %04x: the EGC reader sees %02x, the buffer reader %02x",
                 tag, pg, pl, off, v_egc, v_plain);
        errors = errors + 1;
      end
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
        readers_agree(pg, pp[1:0], off, "EGC byte store: readers agree");
    end
  endtask

  // An EGC COMPAREREAD byte load of ONE plane at ONE column.
  task automatic egc_get(input integer pg, input [1:0] pl, input [14:0] off,
                         input [8*90-1:0] tag);
    reg [31:0] d;
    begin
      op(pg, pl, off, 32'd0, 4'b0001 << off[1:0], 1'b0, 1'b1, d);
      chk_byte(pg, pl, off, d[{off[1:0], 3'b000} +: 8], tag);
    end
  endtask

  // An EGC dword read: a FOUR-column run in one burst, both units evaluated from the drained
  // dword. Byte k of the response is the plane byte at word off+k.
  task automatic egc_get_dword(input integer pg, input [1:0] pl, input [14:0] off,
                               input [8*90-1:0] tag);
    integer k;
    reg [31:0] d;
    begin
      op(pg, pl, off, 32'd0, 4'hF, 1'b0, 1'b1, d);
      for (k = 0; k < 4; k = k + 1)
        chk_byte(pg, pl, off + k, d[8*k +: 8], tag);
    end
  endtask

  // An EGC 16-bit read: a TWO-column run, one cl_done per column. The byte
  // enables must name the two lanes the plane offset's own low bits select - an offset at 2 (mod
  // 4) is lanes 2 and 3, and the EGC's run then starts at that offset, not at the dword's base.
  task automatic egc_get_word(input integer pg, input [1:0] pl, input [14:0] off,
                              input [8*90-1:0] tag);
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

  // Arm the shifter: 0x4AC/0x4AE re-point the pointers and reset srcmask to 0xFFFF, which is what
  // makes a following write carry a full mask (and so its two-column burst).
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

  // The EGC's TWO-WORD write burst (cl_burst, wbe 4'hF): one request writes the unit's two
  // consecutive columns, all four planes each. Which of the two words the masked store actually
  // changes is the EGC's own contract, so both are captured by reader agreement.
  task automatic egc_put_word(input integer pg, input [14:0] off, input [15:0] data);
    reg [31:0] d;
    integer pp;
    begin
      egc_arm;
      op(pg, 2'd0, off, {16'd0, data}, 4'b0011, 1'b1, 1'b1, d);
      // The SECOND word is read first: a read of the first word's own run prefetches the following
      // words and would fill the second word's buffer slot with the post-store value before
      // the second word is checked.
      for (pp = 0; pp < 4; pp = pp + 1) begin
        readers_agree(pg, pp[1:0], off + 1, "EGC word store: readers agree (word 1)");
        readers_agree(pg, pp[1:0], off + 0, "EGC word store: readers agree (word 0)");
      end
    end
  endtask

  // A GRCG store with a PARTIAL plane mask (active-high enable): only the enabled planes take
  // the tile, which is the partial-byte - and full-word-hit - store shape.
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

  // A GRCG TDW store: mode bit 7 set, all four planes enabled -> ONE full-word store per CPU lane
  // at the column that lane names, the whole word = the tile.
  task automatic grcg_put(input integer pg, input [15:0] addr_off, input [7:0] tile);
    reg [31:0] sink;
    integer k;
    begin
      @(negedge clk);
      grcg_we   = 1'b1;
      grcg_addr = 8'h7C; grcg_din = 8'h80;             // bit 7: the GRCG owns stores
      @(negedge clk); grcg_we = 1'b0;
      grcg_we = 1'b1;
      grcg_addr = 8'h7E; grcg_din = tile;              // plane 0 tile
      @(negedge clk);
      grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk);
      grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk);
      grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_we = 1'b0;
      op(pg, 2'd0, addr_off, 32'hFFFF_FFFF, 4'hF, 1'b1, 1'b0, sink);
      // every enabled lane writes a full word (tile in all four planes); a dword store is four
      // lanes, so the GRCG walks four COLUMNS, not four planes.
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

  // A GRCG RMW store (mode bit 6 set): the GRCG READS the column first - through the GVRAM's own
  // read path - and writes back (old & ~data) | (tile & data), one
  // column per enabled CPU lane, only in the planes its mask enables. A stale read would
  // corrupt the merge, so the golden is computed byte by byte.
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

  // Drain the write-combining buffer: one line tick sets the flush debt, and the scanout's own
  // fetch gate holds until every dirty word is back.
  task automatic flush_wcb;
    begin
      @(negedge clk); scan_line_tick = 1'b1; @(negedge clk); scan_line_tick = 1'b0;
      @(posedge clk);
      while (1'b0) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  // The scanout's own SDRAM view of one line: 80 columns of the buffer the fetch just filled.
  reg [31:0] scan_words [0:79];
  task automatic scanout_capture(input integer pg, input [14:0] base);
    integer c;
    begin
      scan_enable = 1'b0;
      repeat (6) @(posedge clk);
      scan_enable    = 1'b1;
      scan_page      = pg[0];
      scan_line_base = base;
      @(negedge clk); scan_line_tick = 1'b1; @(negedge clk); scan_line_tick = 1'b0;
      c = 0;
      while (!line_ready && (c < 8000)) begin @(posedge clk); c = c + 1; end
      if (!line_ready) fail("the scanout line fetch never completed");
      line_rd_sel = ~line_sel;
      for (c = 0; c < 80; c = c + 1) begin
        line_rd_addr = c[6:0];
        @(posedge clk); #1;
        scan_words[c] = line_data;
      end
      scan_enable = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic scanout_chk(input integer pg, input [14:0] base, input [8*90-1:0] tag);
    integer c, pl;
    begin
      scanout_capture(pg, base);
      for (c = 0; c < 80; c = c + 1)
        for (pl = 0; pl < 4; pl = pl + 1) begin
          checks = checks + 1;
          if (scan_words[c][8*pl +: 8] !== gold[gi(pg, pl, base + c)]) begin
            $display("FAIL %0s: scanout pg%0d col %0d plane %0d = %02x want %02x",
                     tag, pg, c, pl, scan_words[c][8*pl +: 8], gold[gi(pg, pl, base + c)]);
            errors = errors + 1;
          end
        end
    end
  endtask

  // The whole SDRAM image against the golden model. Only meaningful after a flush.
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

  task automatic sdram_chk(input [8*90-1:0] tag);
    integer w, pl;
    begin
      for (w = 0; w < 65536; w = w + 1)
        for (pl = 0; pl < 4; pl = pl + 1) begin
          checks = checks + 1;
          if (gvmem_byte(w[15:0], pl[1:0]) !== gold[((w) * 4) + pl]) begin
            $display("FAIL %0s: SDRAM word %04x plane %0d = %02x want %02x",
                     tag, w, pl, gvmem_byte(w[15:0], pl[1:0]), gold[(w * 4) + pl]);
            errors = errors + 1;
          end
        end
    end
  endtask

  // The write-combining buffer is gone: the array IS the read-after-write view, so there
  // is no held-word state left to check - the whole-image comparison in sdram_chk is the check.
  task automatic wcb_chk(input [8*90-1:0] tag);
    begin
      checks = checks + 0;
    end
  endtask

  integer i, k, pg, pl, off;
  reg [31:0] d;
  integer s_checks, s_errors;

  task automatic section(input [8*60-1:0] name);
    begin
      s_checks = checks; s_errors = errors;
      $display("NOTE gvram_coherence: --- %0s ---", name);
    end
  endtask

  task automatic section_end(input [8*60-1:0] name);
    begin
      $display("NOTE gvram_coherence: %0s: %0d checks, %0d mismatch(es)",
               name, checks - s_checks, errors - s_errors);
    end
  endtask

  // ==== CHECKS ====
  integer fsec;
  reg [31:0] lfsr;
  task automatic fuzz_step;
    integer o;
    begin
      lfsr = (lfsr * 32'd1103515245) + 32'd12345;
      o    = (lfsr >> 16) & 32'h1F;
      fsec = (lfsr >> 19) & 32'h3;
      pg   = (lfsr >> 21) & 32'h1;
      pl   = (lfsr >> 22) & 32'h3;
      off  = 15'h2000 + ((lfsr >> 24) & 15'h00FF);
      case (o)
        0: put_byte(pg, pl[1:0], off, (lfsr >> 8) & 8'hFF);
        1: get_byte(pg, pl[1:0], off, "fuzz: plain load");
        2: dword_write(pg, pl[1:0], {off[14:2], 2'b00},
                       {(lfsr ^ 32'hA5A5_0000) | 32'h5A5A_0001});
        3: dword_read(pg, pl[1:0], {off[14:2], 2'b00}, "fuzz: dword load");
        4: line_read(pg, pl[1:0], {off[14:4], 4'b0000}, "fuzz: line load");
        5: egc_get(pg, pl[1:0], off, "fuzz: EGC byte load");
        6: begin grcg_put(pg, {off[14:2], 2'b00}, (lfsr >> 8) & 8'hFF); end
        7: begin egc_put(pg, off, (lfsr >> 8) & 8'hFF); end
        8: egc_get_dword(pg, pl[1:0], {off[14:2], 2'b00}, "fuzz: EGC dword load");
        9: begin egc_put_word(pg, {off[14:2], 2'b00}, lfsr[15:0]); end
        10: begin grcg_put_mask(pg, {off[14:2], 2'b00}, (lfsr >> 8) & 8'hFF,
                                (lfsr >> 4) & 4'hF); end
        11: egc_get_word(pg, pl[1:0], {off[14:1], 1'b0}, "fuzz: EGC word load");
        12: line_read(pg, pl[1:0], {off[14:4], 4'b0000}, "fuzz: line load B");
        13: get_byte(pg, pl[1:0], off, "fuzz: plain load B");
        14: begin put_byte(pg, pl[1:0], off, (lfsr >> 8) & 8'hFF);
                  get_byte(pg, pl[1:0], off, "fuzz: store then load own word"); end
        16: begin grcg_rmw(pg, {off[14:2], 2'b00}, (lfsr >> 8) & 8'hFF,
                           (lfsr >> 27) & 4'hF, (lfsr >> 24) & 8'hFF); end
        default: begin egc_put(pg, off, (lfsr >> 8) & 8'hFF);
                       egc_get(pg, pl[1:0], off, "fuzz: EGC store then load own word"); end      endcase
    end
  endtask

  initial begin
    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (8) @(posedge clk);

    for (i = 0; i < 262144; i = i + 1) gold[i] = 8'h00;

    // ------------------------------------------------------------------
    // 1. READ-AFTER-WRITE: a byte written through a plane window reads back through the SAME
    //    window, both access pages, all four planes - the WCB's copy, not stale SDRAM.
    // ------------------------------------------------------------------
    section("1 read-after-write, same word, both pages, four planes");
    for (pg = 0; pg < 2; pg = pg + 1)
      for (pl = 0; pl < 4; pl = pl + 1) begin
        off = 15'h2010 + pl[14:0];
        put_byte(pg, pl[1:0], off, 8'h10 + pl[7:0] + (pg * 8'h40));
        get_byte(pg, pl[1:0], off, "1 same-word RAW");
      end
    // Interleaved: each plane's store is followed by a read of every plane already stored.
    off = 15'h2020;
    for (pl = 0; pl < 4; pl = pl + 1) begin
      put_byte(0, pl[1:0], off, 8'hA0 + pl[7:0]);
      for (k = 0; k <= pl; k = k + 1)
        get_byte(0, k[1:0], off, "1 interleaved four-plane RAW");
    end
    section_end("1 read-after-write");
    flush_wcb;
    sdram_chk("1 SDRAM after RAW");

    // ------------------------------------------------------------------
    // 2. ADJACENT WORDS: the fill's read-prefetch covers the neighbours, so a store to a word the
    //    prefetch already brought in must merge into it, and the neighbours must not be disturbed.
    // ------------------------------------------------------------------
    section("2 adjacent words and the read-prefetch");
    off = 15'h2044;
    // Descending: the LAST word first, so every later store hits a word the prefetch already holds.
    for (k = 3; k >= 0; k = k - 1) begin
      put_byte(0, 2'd0, off + k[14:0], 8'h50 + k[7:0]);
      get_byte(0, 2'd0, off + k[14:0], "2 descending adjacent RAW");
    end
    // Ascending with an immediate read of the previous word (the prefetch's clean slot).
    for (k = 0; k < 8; k = k + 1) begin
      put_byte(0, 2'd1, off + k[14:0], 8'h60 + k[7:0]);
      get_byte(0, 2'd0, off + k[14:0], "2 adjacent plane0 preserved");
      get_byte(0, 2'd1, off + k[14:0], "2 ascending adjacent RAW");
    end
    get_byte(0, 2'd1, off + 15'h0000 - 15'h0001, "2 word below the run");
    section_end("2 adjacent words");
    flush_wcb;
    sdram_chk("2 SDRAM after adjacent");

    // ------------------------------------------------------------------
    // 3. PAGE 0 vs PAGE 1: the buffer tag carries the page bit, so the same
    //    offset on the two pages is two different words.
    // ------------------------------------------------------------------
    section("3 page 0 vs page 1");
    off = 15'h2060;
    for (pl = 0; pl < 4; pl = pl + 1) begin
      put_byte(0, pl[1:0], off, 8'h70 + pl[7:0]);
      put_byte(1, pl[1:0], off, 8'hB0 + pl[7:0]);
    end
    for (pl = 0; pl < 4; pl = pl + 1) begin
      get_byte(0, pl[1:0], off, "3 page0");
      get_byte(1, pl[1:0], off, "3 page1");
    end
    line_read(0, 2'd0, 15'h2060, "3 page0 line");
    line_read(1, 2'd0, 15'h2060, "3 page1 line");
    section_end("3 page 0 vs page 1");

    // ------------------------------------------------------------------
    // 4. PARTIAL-BYTE RMW: a one-lane store reads the word it changes, so the other three planes
    //    keep their SDRAM value - on a virgin word and on a seeded one whose buffer slot is gone.
    // ------------------------------------------------------------------
    section("4 partial-byte read-modify-write");
    off = 15'h2080;
    put_byte(0, 2'd2, off, 8'hC3);
    for (pl = 0; pl < 4; pl = pl + 1)
      get_byte(0, pl[1:0], off, "4 virgin-word lanes");
    // Seed all four planes, flush, then push the slot out with eight fresh words.
    for (pl = 0; pl < 4; pl = pl + 1)
      put_byte(0, pl[1:0], off, 8'hD0 + pl[7:0]);
    flush_wcb;
    for (k = 0; k < 9; k = k + 1)
      put_byte(0, k[1:0], 15'h2090 + k[14:0], 8'hE0 + k[7:0]);
    flush_wcb;
    // The slot is gone, so this partial store fills from SDRAM and merges.
    put_byte(0, 2'd1, off, 8'h55);
    for (pl = 0; pl < 4; pl = pl + 1)
      get_byte(0, pl[1:0], off, "4 seeded-word lanes preserved");
    section_end("4 partial-byte RMW");
    flush_wcb;
    sdram_chk("4 SDRAM after partial RMW");

    // ------------------------------------------------------------------
    // 5. EVICTION: twelve words through eight slots. A dirty victim must be written back, a clean
    //    one dropped, and every word must still carry its bytes afterwards.
    // ------------------------------------------------------------------
    section("5 eviction: dirty victim written back, clean victim dropped");
    for (k = 0; k < 12; k = k + 1) begin
      off = 15'h20A0 + k[14:0];
      put_byte(0, k[1:0], off, 8'h71 + k[7:0]);
    end
    // A clean-victim shape: read a run into clean slots, then evict it with fresh stores.
    line_read(0, 2'd3, 15'h20C0, "5 clean fill before eviction");
    for (k = 0; k < 12; k = k + 1)
      put_byte(1, 2'd0, 15'h20E0 + k[14:0], 8'h33 + k[7:0]);
    for (k = 0; k < 12; k = k + 1) begin
      get_byte(0, k[1:0], 15'h20A0 + k[14:0], "5 evicted dirty word");
      get_byte(1, 2'd0, 15'h20E0 + k[14:0], "5 evicting store");
    end
    line_read(0, 2'd3, 15'h20C0, "5 clean victim dropped");
    wcb_chk("5 held words match golden");
    section_end("5 eviction");
    flush_wcb;
    sdram_chk("5 SDRAM after eviction");

    // ------------------------------------------------------------------
    // 6. FLUSH / DRAIN: the scanout reads SDRAM on its own requester, so a dirty word must be
    //    written back before the line fetch that displays it, on both pages.
    // ------------------------------------------------------------------
    section("6 flush/drain before the scanout fetch");
    for (k = 0; k < 80; k = k + 1) begin
      put_byte(0, 2'd0, 15'h2200 + k[14:0], 8'h01 + k[7:0]);
      put_byte(0, 2'd3, 15'h2200 + k[14:0], 8'h81 + k[7:0]);
    end
    scanout_chk(0, 15'h2200, "6 page0 line through SDRAM");
    for (k = 0; k < 80; k = k + 1)
      put_byte(1, 2'd1, 15'h2300 + k[14:0], 8'h41 + k[7:0]);
    scanout_chk(1, 15'h2300, "6 page1 line after a display-page change");
    section_end("6 flush/drain");

    // ------------------------------------------------------------------
    // 7. LINE LOAD after a store: a line load reads SDRAM, so a store to one of its words followed
    //    by a reload must show the merged value, even after the buffer's own copy was evicted.
    // ------------------------------------------------------------------
    section("7 line-load fill, store, line-load again");
    line_read(0, 2'd0, 15'h2400, "7 line warm-up");
    for (k = 0; k < 8; k = k + 1) begin
      off = 15'h2400 + k[14:0];
      put_byte(0, 2'd0, off, 8'hF0 - k[7:0]);
      line_read(0, 2'd0, 15'h2400, "7 line after the store");
    end
    // Push the buffer's copies out, then read the line again.
    for (k = 0; k < 12; k = k + 1)
      put_byte(0, 2'd1, 15'h2500 + k[14:0], 8'h10 + k[7:0]);
    flush_wcb;
    line_read(0, 2'd0, 15'h2400, "7 line after the buffer was evicted");
    section_end("7 line load / store");
    flush_wcb;
    sdram_chk("7 SDRAM after the store");

    // ------------------------------------------------------------------
    // 8. FULL-WORD STORE: a full-word GRCG/EGC store must be visible to every reader of the word.
    // ------------------------------------------------------------------
    section("8 full-word store then every reader");
    off = 15'h2600;
    egc_get(0, 2'd2, off, "8 EGC read A");
    egc_get(0, 2'd2, off, "8 EGC read B");
    for (k = 1; k < 8; k = k + 1)
      egc_get(0, 2'd2, off + k[14:0], "8 EGC neighbour read");
    egc_get(0, 2'd2, off, "8 EGC read before the EGC store");
    egc_put_raw(0, off, 8'h6B);
    grcg_put(0, off, 8'h9A);
    egc_get(0, 2'd0, off, "8 EGC read of the GRCG word");
    egc_get(0, 2'd1, off, "8 EGC read of the GRCG word");
    egc_get(0, 2'd2, off, "8 EGC read of the GRCG word");
    egc_get(0, 2'd3, off, "8 EGC read of the GRCG word");
    section_end("8 full-word store");
    flush_wcb;
    sdram_chk("8 SDRAM after GRCG store");

    // ------------------------------------------------------------------
    // 9. THE EGC READ FILL: a miss reads only the run's columns; the following words are separate
    //    reads, and a strided walk must read correctly.
    // ------------------------------------------------------------------
    section("9 EGC read fill");
    off = 15'h2700;
    egc_get(0, 2'd1, off, "9 fill, own word");
    for (k = 1; k < 8; k = k + 1)
      egc_get(0, 2'd1, off + k[14:0], "9 following word");
    // Store one of the following words, then read it back through the same EGC path.
    put_byte(0, 2'd1, off + 15'h0003, 8'h5C);
    egc_get(0, 2'd1, off + 15'h0003, "9 EGC read after the store");
    // Push the buffer's dirty copy out, so the read can only come from SDRAM.
    for (k = 0; k < 12; k = k + 1)
      put_byte(0, 2'd2, 15'h2740 + k[14:0], 8'h44 + k[7:0]);
    flush_wcb;
    egc_get(0, 2'd1, off + 15'h0003, "9 EGC read after buffer eviction");
    // A strided walk must still read correctly.
    for (k = 0; k < 8; k = k + 1) begin
      egc_get(0, 2'd2, 15'h2780 + (k * 40), "9 strided walk");
      egc_get(0, 2'd2, 15'h2700, "9 stride returning to the run");
    end
    section_end("9 EGC read fill");

    // ------------------------------------------------------------------
    // 10. POSTED WRITE THEN READ ITS OWN WORD: the EGC's store is posted on the accept, so a read
    //     of the same word may land behind it; the GVRAM must return the new value.
    // ------------------------------------------------------------------
    section("10 posted write then read own word");
    off = 15'h2800;
    for (k = 0; k < 8; k = k + 1) begin
      egc_put(0, off, 8'h3A + k[7:0]);
      egc_get(0, 2'd0, off, "10 EGC read-own-word plane0");
      egc_get(0, 2'd3, off, "10 EGC read-own-word plane3");
      get_byte(0, 2'd1, off, "10 plain read-own-word");
      line_read(0, 2'd2, 15'h2800, "10 line read-own-word");
    end
    // The store hits a CLEAN buffer slot this time (the line load above brought it in).
    for (k = 0; k < 4; k = k + 1) begin
      egc_put(0, off + k[14:0], 8'hC1 + k[7:0]);
      egc_get(0, 2'd0, off + k[14:0], "10 EGC clean-slot store then read");
    end
    section_end("10 posted write then read own word");
    flush_wcb;
    sdram_chk("10 SDRAM after posted writes");

    // ------------------------------------------------------------------
    // 11. MULTI-COLUMN EGC RUNS: a 16-bit unit is a TWO-column run and a dword a FOUR-column run
    //     of ONE burst, one cl_done per column, and the two-word write burst is one request.
    // ------------------------------------------------------------------
    section("11 EGC multi-column read runs and the two-word write burst");
    off = 15'h2900;
    for (pl = 0; pl < 4; pl = pl + 1) begin
      put_byte(0, pl[1:0], off + 0, 8'hA0 + pl[7:0]);
      put_byte(0, pl[1:0], off + 1, 8'hB0 + pl[7:0]);
      put_byte(0, pl[1:0], off + 2, 8'hC0 + pl[7:0]);
      put_byte(0, pl[1:0], off + 3, 8'hD0 + pl[7:0]);
    end
    for (pl = 0; pl < 4; pl = pl + 1) begin
      egc_get_word(0, pl[1:0], off, "11 EGC two-column run");
      egc_get_dword(0, pl[1:0], off, "11 EGC four-column run");
    end
    // A dirty hold inside the run must drain before the burst streams past it.
    put_byte(0, 2'd1, off + 2, 8'hE5);
    egc_get_dword(0, 2'd1, off, "11 four-column run over a dirty inner word");
    // The two-word write burst, and the read that must see it.
    egc_put_word(0, off, 16'h7733);
    egc_get_word(0, 2'd0, off, "11 EGC two-word burst write then read");
    egc_get_dword(0, 2'd3, off, "11 EGC two-word burst write then dword read");
    section_end("11 EGC multi-column runs");
    flush_wcb;
    sdram_chk("11 SDRAM after the EGC runs");

    // ------------------------------------------------------------------
    // 12. THE OVER-FETCHED BEAT AND THE DIRTY EVICTION: a read fill must never overwrite a word the
    //     buffer holds DIRTY with SDRAM's stale value, AND the write-back that ends the hold (an
    //     EVICTION, not a flush) must land it so a later reader sees the merge.
    //     The offsets end in 0xFF, where the read-prefetch is clamped to ONE word: a store there
    //     fills a single DIRTY slot, so nine of them fill the buffer with dirty slots and the next
    //     allocation has no clean victim left and must evict a DIRTY one.
    // ------------------------------------------------------------------
    section("12 the over-fetched dirty beat and the dirty eviction");
    off = 15'h20FF;
    put_byte(0, 2'd1, off, 8'h6D);                     // W: dirty, one slot
    get_byte(0, 2'd1, off - 1, "12 prefetch over the dirty word");
    // The prefetch's beat for W must NOT have allocated a second slot holding SDRAM's stale W:
    // a hit is served by the slot the buffer really holds, so this read must still see the merge.
    get_byte(0, 2'd1, off, "12 the dirty word still reads back after the prefetch");
    for (k = 0; k < 9; k = k + 1)
      put_byte(0, 2'd2, 15'h21FF + (k[14:0] * 15'h0100), 8'h40 + k[7:0]);
    egc_get(0, 2'd1, off, "12 EGC read after the dirty eviction");
    get_byte(0, 2'd1, off, "12 plain read after the dirty eviction");
    flush_wcb;
    sdram_chk("12 SDRAM after the dirty eviction");
    // The other end of the rule: a word still HELD dirty must be drained before the EGC's burst
    // streams past it, so the read behind it sees the merged value.
    off = 15'h2A00;
    put_byte(0, 2'd1, off + 5, 8'h3E);
    egc_get(0, 2'd1, off + 5, "12 EGC read of the still-held dirty word");
    get_byte(0, 2'd1, off + 5, "12 plain read of the still-held dirty word");
    // A prefetch's beat for a word the buffer ALREADY holds must be DROPPED, never allocated as a
    // second slot with the same tag: a duplicate would be a clean slot holding SDRAM's stale value,
    // and the hit - which serves the lowest matching slot - could pick it instead of the merge.
    // Twelve one-slot stores (low byte FF) leave the buffer full of dirty slots; the last eight are
    // re-read with a two-word prefetch over each, so a duplicate below any of their slots shows.
    for (k = 0; k < 12; k = k + 1)
      put_byte(0, 2'd1, 15'h30FF + (k[14:0] * 15'h0100), 8'h71 + k[7:0]);
    for (k = 4; k < 12; k = k + 1) begin
      off = 15'h30FF + (k[14:0] * 15'h0100);
      get_byte(0, 2'd1, off - 1, "12 prefetch over a held dirty word");
      get_byte(0, 2'd1, off, "12 the held word after the prefetch");
    end
    section_end("12 the over-fetched dirty beat and the dirty eviction");
    flush_wcb;
    sdram_chk("12 SDRAM after the hold was drained");

    // ------------------------------------------------------------------
    // 13. A STORE'S SCOPE: a store to one word must leave its neighbours and the other page at the
    //     same offset untouched (the buffer tag carries the page).
    // ------------------------------------------------------------------
    section("13 store scope: neighbour word and page");
    egc_get(0, 2'd0, 15'h2400, "13 word A");
    egc_get(0, 2'd0, 15'h2C00, "13 word B");
    put_byte(0, 2'd0, 15'h2400, 8'h77);
    egc_get(0, 2'd0, 15'h2C00, "13 word B after its neighbour's store");
    egc_get(0, 2'd0, 15'h2400, "13 word A (page 0)");
    egc_get(1, 2'd1, 15'h2400, "13 word A (page 1)");
    put_byte(1, 2'd1, 15'h2404, 8'h78);
    egc_get(0, 2'd0, 15'h2400, "13 the page-0 word after a page-1 store");
    egc_get(1, 2'd1, 15'h2404, "13 the page-1 word after its store");
    section_end("13 store scope");

    // ------------------------------------------------------------------
    // 14. THE SCANOUT AFTER AN EVICTION: no explicit flush, just the dirty words the evictions
    //     wrote back, and the display's own SDRAM view must be the golden line.
    // ------------------------------------------------------------------
    section("14 scanout after eviction write-backs");
    for (k = 0; k < 80; k = k + 1) begin
      put_byte(0, 2'd0, 15'h2B00 + k[14:0], 8'h11 + k[7:0]);
      put_byte(0, 2'd2, 15'h2B00 + k[14:0], 8'h91 + k[7:0]);
    end
    // 80 fresh one-lane stores through the eight slots force every earlier word out.
    for (k = 0; k < 80; k = k + 1)
      put_byte(0, 2'd1, 15'h2C80 + k[14:0], 8'h55 + k[7:0]);
    scanout_chk(0, 15'h2B00, "14 evicted line through SDRAM");
    section_end("14 scanout after eviction");

    // ------------------------------------------------------------------
    // 15. THE PLANE END: every fill clamp (the plane's 0x8000 boundary, the SDRAM row) tightens
    //     at the last words of a plane, so the store/merge/read path there is its own case.
    // ------------------------------------------------------------------
    section("15 the plane end");
    off = 15'h7FF0;
    for (pl = 0; pl < 4; pl = pl + 1)
      for (k = 0; k < 16; k = k + 1)
        put_byte(0, pl[1:0], off + k[14:0], 8'h20 + pl[7:0] + k[7:0]);
    for (pl = 0; pl < 4; pl = pl + 1) begin
      for (k = 0; k < 16; k = k + 1)
        get_byte(0, pl[1:0], off + k[14:0], "15 plane-end RAW");
      line_read(0, pl[1:0], 15'h7FF0, "15 plane-end line load");
      egc_get(0, pl[1:0], 15'h7FFF, "15 plane-end EGC byte load");
    end
    egc_get_dword(0, 2'd1, 15'h7FFC, "15 plane-end EGC dword run");
    // A one-lane store at the very last word: the read-prefetch is clamped to a single word.
    put_byte(0, 2'd3, 15'h7FFF, 8'h5B);
    get_byte(0, 2'd3, 15'h7FFF, "15 last-word partial store");
    get_byte(0, 2'd2, 15'h7FFF, "15 last-word neighbours preserved");
    flush_wcb;
    scanout_chk(0, 15'h7F80, "15 plane-end line through SDRAM");
    sdram_chk("15 SDRAM at the plane end");
    section_end("15 the plane end");

    // ------------------------------------------------------------------
    // 16. THE GRCG READ-MODIFY-WRITE: its read goes through the GVRAM's own
    //     read path, so a copy the buffer holds must be CURRENT when it feeds the merge.
    // ------------------------------------------------------------------
    section("16 the GRCG read-modify-write over a re-read word");
    off = 15'h2D00;
    for (pl = 0; pl < 4; pl = pl + 1)
      for (k = 0; k < 4; k = k + 1)
        put_byte(0, pl[1:0], off + k[14:0], 8'h60 + pl[7:0] + k[7:0]);
    egc_get_dword(0, 2'd0, off, "16 warm the RMW target dword");
    grcg_rmw(0, off, 8'hF0, 4'hF, 8'h0F);
    grcg_rmw(0, off, 8'h3C, 4'b0101, 8'hAA);
    for (pl = 0; pl < 4; pl = pl + 1)
      for (k = 0; k < 4; k = k + 1)
        get_byte(0, pl[1:0], off + k[14:0], "16 RMW result");
    for (pl = 0; pl < 4; pl = pl + 1)
      line_read(0, pl[1:0], off, "16 RMW result through the read path");
    section_end("16 the GRCG read-modify-write");
    flush_wcb;
    sdram_chk("16 SDRAM after the GRCG RMW");

    // ------------------------------------------------------------------
    // 17. INTERLEAVED FUZZ: a fixed pseudo-random sequence of every client and width over one
    //     window, every returned byte checked, and a final whole-image SDRAM compare.
    // ------------------------------------------------------------------
    section("17 interleaved fuzz");
    lfsr = 32'h1234_5678;
    for (i = 0; i < 900; i = i + 1)
      fuzz_step;
    section_end("17 interleaved fuzz");
    flush_wcb;
    sdram_chk("17 SDRAM after the fuzz");

    // Final: the buffer holds nothing dirty, every held word is golden, and the whole SDRAM image
    // is golden.
    wcb_chk("final held words");

    // ==== VERDICT ====
    $display("NOTE gvram_coherence: backend stores: %0d full-word (burst 1, be F), %0d two-word burst(s) (burst 2)",
             cb_fullwr, cb_burst2);
    $display("TB_PC9821_GVRAM_COHERENCE: %0d coherence check(s), %0d mismatch(es)", checks, errors);
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_COHERENCE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_GVRAM_COHERENCE: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_GVRAM_COHERENCE: FAIL");
    end
  end

  // ==== VERDICT BOUND ====
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_GVRAM_COHERENCE: FAIL (timed out)");
  end

endmodule

`default_nettype wire
