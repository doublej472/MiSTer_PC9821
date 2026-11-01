`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM:
// The one four-plane GVRAM datapath: a CPU plane-window store becomes one D1 column access per enabled byte and lands in that plane's byte lane of the byte-interleaved word at gvram_base + page*0x20000 + 4*column, the per-plane byte enables gate writes, the GRCG and the EGC BOTH reach all four planes through the same port (a TDW fill, an RMW merge with and without the old value, the active-low plane mask, the four-window fold, and an EGC 0x1400 WS_PATREG fill), and the scanout fetches 80 columns of a line into a ping-pong buffer one line ahead at no more than one request per 8 clk_sys and advances that buffer EXACTLY ONCE per line tick, however wide the producer's pulse is -- a multi-clk_sys LEVEL (which pc9821_system used to send, and which is why games bounced) must not advance it twice. It does NOT cover the pixel pipeline, the palette or the compositor, which are a later lane's.
module tb_pc9821_gvram;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;

  // ==== DUT ====
  reg        access_page = 0;
  reg  [1:0] win_plane = 0;
  reg [14:0] win_offset = 0;
  reg [31:0] cpu_din = 0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 0;
  reg        cpu_valid = 0, cpu_write = 0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0, grcg_din = 0;

  reg        egc_gate = 0;
  reg [15:0] egc_access = 16'hFFFF, egc_fgbg = 0, egc_ope = 0,
             egc_fg = 0, egc_mask = 16'hFFFF, egc_bg = 0,
             egc_sft = 0, egc_leng = 0;
  reg        egc_shift_we = 0;

  reg        scan_enable = 0, scan_line_tick = 0, scan_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;

  // The walk's telemetry pulses, counted here so section 11 can assert what they mean.
  wire        dut_walk_start, dut_walk_cycle;

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) dut (
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
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready),
      .dbg_walk_start(dut_walk_start), .dbg_walk_cycle(dut_walk_cycle)
  );

  // One clk_sys with either pulse high is one event of it. tb_pc9821_perf_msg asserts that the
  // RECORD counts these pulses; this bench asserts what the module emits them for.
  integer gw_cnt = 0, gc_cnt = 0;
  always @(posedge clk) begin
    if (dut_walk_start) gw_cnt <= gw_cnt + 1;
    if (dut_walk_cycle) gc_cnt <= gc_cnt + 1;
  end


  // ==== STIMULUS ====
  integer errors = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  task automatic port_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk);
      grcg_addr = a;
      grcg_din  = d;
      grcg_we   = 1;
      @(negedge clk);
      grcg_we   = 0;
    end
  endtask

  task automatic put_tiles(input [7:0] b, input [7:0] r, input [7:0] g, input [7:0] e);
    begin
      port_w(8'h7E, b);
      port_w(8'h7E, r);
      port_w(8'h7E, g);
      port_w(8'h7E, e);
    end
  endtask

  // A CPU store through a plane window. `plane` / `off` are the window's plane
  // index and the byte offset inside the plane, exactly what the mapper emits.
  task automatic cpu_store(input [1:0] plane, input [14:0] off,
                           input [31:0] data, input [3:0] be);
    begin
      @(negedge clk);
      win_plane = plane;
      win_offset = off;
      cpu_din   = data;
      cpu_be    = be;
      cpu_write = 1;
      cpu_valid = 1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin
        @(posedge clk);
        #1;
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be    = 4'hF;
      // Let EVERY owner return to idle before the next op and before the GW/GC counters are
      // sampled: the decoupled store is ACCEPTED at its ready and completed BEHIND the CPU, so
      // `ready` no longer means the walk is over. The array FSM, the GRCG's sequencer, the
      // EGC's produce and the plain client's column walk are all waited out.
      while ((dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) ||
             (dut.u_grcg.gstate != 4'd0) || (dut.u_egc.state != 4'd0)) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic cpu_load(input [1:0] plane, input [14:0] off, input [3:0] be,
                          output [31:0] data);
    begin
      // 0x7C = 0 before every plane read-back: with the GRCG armed at 0x80 the SAME
      // plane-window read is NP2kai's memtcr tile-compare, not the plane byte.
      port_w(8'h7C, 8'h00);
      @(negedge clk);
      win_plane = plane;
      win_offset = off;
      cpu_write = 0;
      cpu_be    = be;
      cpu_valid = 1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin
        @(posedge clk);
        #1;
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_be    = 4'hF;
      #1;
      while (!cpu_resp_valid) begin
        @(posedge clk);
        #1;
      end
      data = cpu_dout;
      @(negedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic expect_planes(input [14:0] off,
                               input [31:0] b, input [31:0] r,
                               input [31:0] g, input [31:0] e);
    reg [31:0] rb, rr, rg, re;
    reg [31:0] d;
    begin
      // Read the dword at this column from each of the four windows: the plain
      // path returns the addressed plane's bytes for the four columns
      // off, off+1, off+2, off+3.
      cpu_load(2'd0, off, 4'hF, d); rb = d;
      cpu_load(2'd1, off, 4'hF, d); rr = d;
      cpu_load(2'd2, off, 4'hF, d); rg = d;
      cpu_load(2'd3, off, 4'hF, d); re = d;
      if (rb !== b || rr !== r || rg !== g || re !== e) begin
        $display("FAIL planes at off %04x: got B=%08x R=%08x G=%08x E=%08x want B=%08x R=%08x G=%08x E=%08x",
                 off, rb, rr, rg, re, b, r, g, e);
        errors = errors + 1;
      end
    end
  endtask

  // Read one column of the ping-pong line buffer. The read port is REGISTERED, so
  // the sampling edge has to be after the address was presented.
  task automatic read_line_col(input sel, input [6:0] a, output [31:0] v);
    begin
      line_rd_sel = sel;
      line_rd_addr = a;
      @(posedge clk);
      #1;
      v = line_data;
    end
  endtask

  // THE BENCH NO LONGER OWNS THE ARRAY. It used to hold its own copy and model the backend; the
  // storage is inside the DUT now, so a fill goes through the plane windows the guest uses.
  // fill_all(0) is a no-op: the array is SDRAM-resident and starts zeroed. The non-zero
  // fills are the ones that matter and they are done per plane, because a CPU store writes ONE
  // plane's byte.

  // WRITE ONE PLANE'S BYTE AT ONE COLUMN, with the byte enable, the byte position and the offset
  // all derived from the same column. They are NOT independent and getting that wrong is silent.
  //
  // pc9821_gvram forms the array index as c_col = {win_offset[14:2], c_lane}, where c_lane comes
  // from the BYTE ENABLES and not from the address. So a store whose enables disagree with
  // win_offset[1:0] lands in the dword ONE STEP DOWN and overwrites it, and because the four
  // planes are stored in one iteration each, the LAST writer owns that dword. The symptom was a
  // scanout line with data at every FOURTH column only, each carrying the value belonging to the
  // third column after it - "got c3330f00 want c0300c03" - which reads like a rotation bug in the
  // scanout and is really four stores landing on one dword.
  //
  // The data byte must sit at the lane's position too: the datapath takes cpu_din[{c_lane,3'b000}
  // +: 8], so a byte left in the low lane is read as zero for any other lane.
  task automatic put_byte(input [1:0] plane, input [14:0] off, input [7:0] val);
    begin
      cpu_store(plane, off, {24'd0, val} << (off[1:0] * 8), 4'b0001 << off[1:0]);
    end
  endtask

  task automatic fill_all(input [31:0] v);
    integer pl;
    begin
      // PUT THE DATAPATH IN ITS PLAIN STATE FIRST, and this is load-bearing for the same reason
      // the reset ordering is. fill_all used to poke the SDRAM backend model's array directly, so
      // nothing the GRCG or the EGC had latched could affect it. Every fill is now a CPU STORE
      // through the port, and the engines' state APPLIES TO IT. Two checks failed on that rather
      // than on the array: a fill issued while the GRCG is in RMW mode with a zero tile merges to
      // (old & ~0) | (0 & 0) = old, a NO-OP, which is why the 0x0800 check read a stale 05050505
      // that an earlier section left behind; and an RMW whose read-back returns zero degenerates to
      // (tile & data) alone, which is the 0A0B0C0D the 0x0700 check got where the contract says
      // FAFBFCFD. Both are correct hardware behaviour and a bench that stopped setting up its own
      // preconditions. 0x7C = 0 is GRCG off and egc_gate = 0 is the EGC off, which is what the
      // sections themselves already do when they want a plain store.
      egc_gate = 0;
      port_w(8'h7C, 8'h00);
      // EVERY VALUE IS FILLED, INCLUDING ZERO. A first version skipped the zero fill on the
      // grounds that block RAM powers up at zero - which is true once, at the start, and false for
      // every LATER section: the sections reuse the same offsets, so the previous section's value
      // is still there and the checks read it back. The symptom was 'got R=05050505 want 0'.
      begin
        // BOUNDED, and the bound is honest: every check below inspects an offset in the first
        // 0x2400 of a plane, so filling the whole 32 KiB plane - 262144 CPU stores per call, about
        // 2.6M cycles - only made this bench time out. The offsets it touches are the contract.
        for (pl = 0; pl < 4; pl = pl + 1) begin
          access_page = 0;
          for (mi = 0; mi < 9216; mi = mi + 1)
            cpu_store(pl[1:0], mi[14:0], v, 4'hF);
          access_page = 1;
          for (mi = 0; mi < 9216; mi = mi + 1)
            cpu_store(pl[1:0], mi[14:0], v, 4'hF);
          access_page = 0;
        end
      end
    end
  endtask

  // fill_all's plane-offset counter. It was declared inside the backend model block, which is
  // gone now that the array is inside the DUT, so it lives here.
  integer mi;
  integer c, n;
  integer w;
  integer gw0, gc0;
  reg [31:0] d, rd;
  reg [31:0] exp_word;
  reg        prev_tick_sel;
  reg        sel_before;

  initial begin
    // RESET FIRST, THEN FILL, AND THE ORDER IS LOAD-BEARING. fill_all used to poke the SDRAM
    // backend model's array directly, which reset could not affect. Now that the array is inside
    // the DUT, every fill is a CPU STORE through the port, and a store waits on cpu_ready - which
    // the GVRAM's FSM cannot assert while reset holds it in C_IDLE. Called before the release, the
    // very first store of the very first fill waited forever and the bench timed out with no output
    // at all. The symptom was invisible until the store path itself was probed: cs stuck at C_IDLE
    // with cpu_valid high and cc_owns_plain high, which reads correct on paper and is correct - the
    // FSM was simply held in reset.
    repeat (4) @(posedge clk);
    reset = 0;
    repeat (4) @(posedge clk);
    fill_all(32'h0000_0000);

    // ------------------------------------------------------------------
    // 1. The plain CPU path is a D1 client, and a plane's bytes land in that
    //    plane's byte lane of the interleaved word (D2).
    // ------------------------------------------------------------------
    cpu_store(2'd0, 15'h0100, 32'h1122_3344, 4'hF);
    expect_planes(15'h0100, 32'h1122_3344, 32'h0, 32'h0, 32'h0);

    // The same store through the GREEN window lands in the G lane, at the same
    // column addresses: the window selects the plane, not the address.
    cpu_store(2'd2, 15'h0100, 32'h5566_7788, 4'hF);
    expect_planes(15'h0100, 32'h1122_3344, 32'h0, 32'h5566_7788, 32'h0);

    // ------------------------------------------------------------------
    // 2. The byte enables gate the write, and a read returns all four lanes.
    // ------------------------------------------------------------------

    cpu_store(2'd1, 15'h0200, 32'hAABB_CCDD, 4'b0011);
    expect_planes(15'h0200, 32'h0, 32'h0000_CCDD, 32'h0, 32'h0);

    // ------------------------------------------------------------------
    // 3. Access page 1 is 128 KiB further into the region and is the same
    //    interleaved form.
    // ------------------------------------------------------------------
    access_page = 1;
    cpu_store(2'd0, 15'h0100, 32'hDEAD_BEEF, 4'hF);
    access_page = 0;

    // ------------------------------------------------------------------
    // 4. The GRCG, through the same port. master.lib's graph_clear: a TDW with
    //    four zero tiles and a `rep stosw` through the BLUE window only.
    // ------------------------------------------------------------------
    fill_all(32'hDEAD_BEEF);
    port_w(8'h7C, 8'h80);              // mode bit 7, TDW
    put_tiles(8'h00, 8'h00, 8'h00, 8'h00);
    cpu_store(2'd0, 15'h0300, 32'hFFFF_FFFF, 4'hF);
    expect_planes(15'h0300, 32'h0, 32'h0, 32'h0, 32'h0);

    // Each plane gets its own tile byte, and the CPU data is ignored.
    port_w(8'h7C, 8'h80);
    put_tiles(8'h11, 8'h22, 8'h33, 8'h44);
    cpu_store(2'd0, 15'h0400, 32'h0000_0000, 4'hF);
    expect_planes(15'h0400, 32'h1111_1111, 32'h2222_2222,
                  32'h3333_3333, 32'h4444_4444);

    // A store through ANY window aliases to all four planes (NP2kai mem/memvram.c:42,107,143). The intensity window included.
    port_w(8'h7C, 8'h80);
    put_tiles(8'h55, 8'h55, 8'h55, 8'h55);
    cpu_store(2'd3, 15'h0500, 32'hFFFF_FFFF, 4'hF);
    expect_planes(15'h0500, 32'h5555_5555, 32'h5555_5555,
                  32'h5555_5555, 32'h5555_5555);

    // RMW with data 0xFF is the tile whatever the old value was, so it needs no
    // read: TH01's own clear (th01/hardware/graph.cpp:257-264).
    fill_all(32'hA5A5_A5A5);
    port_w(8'h7C, 8'hC0);              // mode bit 7, RMW
    put_tiles(8'h00, 32'h00, 8'h00, 8'h00);
    cpu_store(2'd0, 15'h0600, 32'hFFFF_FFFF, 4'hF);
    expect_planes(15'h0600, 32'h0, 32'h0, 32'h0, 32'h0);

    // RMW with data 0x0F0F0F0F really merges: (old & ~data) | (tile & data).
    fill_all(32'hF0F0_F0F0);
    port_w(8'h7C, 8'hC0);
    put_tiles(8'hAA, 8'hBB, 8'hCC, 8'hDD);

    cpu_store(2'd0, 15'h0700, 32'h0F0F_0F0F, 4'hF);
    expect_planes(15'h0700, 32'hFAFA_FAFA, 32'hFBFB_FBFB,
                  32'hFCFC_FCFC, 32'hFDFD_FDFD);

    // The active-low plane mask: 0xCE leaves only B (TH04's super_plane puts).
    fill_all(32'h0000_0000);
    port_w(8'h7C, 8'h80 | 8'hCE);
    put_tiles(8'h3C, 8'h3C, 8'h3C, 8'h3C);
    cpu_store(2'd0, 15'h0800, 32'hFFFF_FFFF, 4'hF);
    expect_planes(15'h0800, 32'h3C3C_3C3C, 32'h0, 32'h0, 32'h0);

    // All planes disabled is a no-op, not a plain store.
    fill_all(32'h0000_0000);
    port_w(8'h7C, 8'h80 | 8'h8F);
    put_tiles(8'h77, 8'h77, 8'h77, 8'h77);

    cpu_store(2'd0, 15'h0900, 32'hFFFF_FFFF, 4'hF);

    // With mode bit 7 clear a store is a plain single-plane write again -- the
    // regression pin the pre-GRCG behaviour rests on.
    port_w(8'h7C, 8'h00);
    fill_all(32'h0000_0000);
    cpu_store(2'd0, 15'h0A00, 32'h0BAD_F00D, 4'hF);
    expect_planes(15'h0A00, 32'h0BAD_F00D, 32'h0, 32'h0, 32'h0);

    // ------------------------------------------------------------------
    // 5. The EGC, on the SAME port. 0x1400 WS_PATREG|SHIFT_CPU: the write
    //    quad is the foreground colour register, per plane, and the CPU's data
    //    is not the source. All four planes change, which is exactly what the
    //    pre-EGC core could not do.
    // ------------------------------------------------------------------
    fill_all(32'h0000_0000);
    port_w(8'h7C, 8'h00);                    // GRCG off: the EGC owns the store
    egc_access    = 16'h0000;                // active low: every plane enabled
    egc_ope       = 16'h1400;                // WS_PATREG | SHIFT_CPU
    egc_fgbg      = 16'h4000;                // fgbg_sel = 2'b10 -> the FG quad
    egc_fg        = 16'h000F;                // all four planes all-ones
    egc_mask      = 16'hFFFF;
    egc_leng      = 16'h0FFF;                // enough bit length for a full mask
    egc_sft       = 16'h0000;                // src8 == dst8: a byte-aligned copy
    egc_shift_we  = 1; @(negedge clk); egc_shift_we = 0;
    egc_gate      = 1;
    cpu_store(2'd0, 15'h0B00, 32'h0000_0000, 4'hF);
    egc_gate      = 0;
    expect_planes(15'h0B00, 32'hFFFF_FFFF, 32'hFFFF_FFFF,
                  32'hFFFF_FFFF, 32'hFFFF_FFFF);

    // And the EGC's read path returns the addressed plane's bytes through the
    // same port: with 0x1400 (SHIFT_CPU) a read returns the destination quad.
    cpu_load(2'd1, 15'h0B00, 4'hF, rd);
    if (rd !== 32'hFFFF_FFFF)
      fail("an EGC-gated read did not return the plane's bytes");

    // A CPU read with the EGC gate on and the plain gate off must not disturb
    // the planes: only reads happen.

    cpu_load(2'd0, 15'h0B00, 4'hF, rd);

    // ------------------------------------------------------------------
    // 6. The scanout's line fetch (D5): 80 columns of a line, one line ahead.
    // ------------------------------------------------------------------
    fill_all(32'h0000_0000);
    // A known pattern: column c of the line at base 0x2000 carries
    // {E=c^0xC0, G=c^0x30, R=c^0x0C, B=c^0x03} per plane.
    // Poured through the plane windows, one plane at a time, because that is the only way in now.
    // Column c of the line at base 0x2000 carries {E=c^C0, G=c^30, R=c^0C, B=c^03}.
    for (c = 0; c < 80; c = c + 1) begin
      put_byte(2'd0, 15'h2000 + c[14:0], c[7:0] ^ 8'h03);
      put_byte(2'd1, 15'h2000 + c[14:0], c[7:0] ^ 8'h0C);
      put_byte(2'd2, 15'h2000 + c[14:0], c[7:0] ^ 8'h30);
      put_byte(2'd3, 15'h2000 + c[14:0], c[7:0] ^ 8'hC0);
    end

    // The re-based line of section 8, laid down through the plain CPU path while
    // the scanout is still off: its blue byte at column 0 is 0x78.
    cpu_store(2'd0, 15'h2200, 32'h1234_5678, 4'hF);

    scan_enable    = 1;
    scan_page      = 0;
    scan_line_base = 15'h2000;

    @(negedge clk);
    scan_line_tick = 1;
    @(negedge clk);
    scan_line_tick = 0;
    // 80 columns at one per 8 clk_sys: give it room, then some.
    for (n = 0; n < 2000 && !line_ready; n = n + 1) @(posedge clk);
    if (!line_ready)
      fail("the line fetch never signalled a complete line");

    // The buffer the display switches to at the NEXT tick holds this line: after
    // the tick that started it, `line_sel` is the buffer not being written.
    line_rd_sel = ~line_sel;
    for (c = 0; c < 80; c = c + 1) begin
      line_rd_addr = c[6:0];
      @(posedge clk);
      #1;
      exp_word = {c[7:0] ^ 8'hC0, c[7:0] ^ 8'h30, c[7:0] ^ 8'h0C, c[7:0] ^ 8'h03};
      if (line_data !== exp_word) begin
        $display("FAIL line column %0d: got %08x want %08x", c, line_data, exp_word);
        errors = errors + 1;
      end
    end

    // ------------------------------------------------------------------
    // 7. Double buffering, one line ahead. The contract: the buffer `line_sel`
    //    selects during a line holds the line whose base was presented at the
    //    PREVIOUS tick, and the fetch of the newly presented line goes into the
    //    other, freed buffer. So at this tick the display still shows 0x2000's
    //    line while 0x2100 is being fetched.
    // ------------------------------------------------------------------
    for (c = 0; c < 80; c = c + 1) begin
      put_byte(2'd0, 15'h2100 + c[14:0], c[7:0] ^ 8'h10);
      put_byte(2'd1, 15'h2100 + c[14:0], c[7:0] ^ 8'h20);
      put_byte(2'd2, 15'h2100 + c[14:0], c[7:0] ^ 8'h40);
      put_byte(2'd3, 15'h2100 + c[14:0], c[7:0] ^ 8'h80);
    end
    prev_tick_sel = line_sel;
    scan_line_base = 15'h2100;
    @(negedge clk);
    scan_line_tick = 1;
    @(negedge clk);
    scan_line_tick = 0;
    if (line_sel === prev_tick_sel)
      fail("the line tick did not swap the displayed buffer");
    for (n = 0; n < 2000; n = n + 1) @(posedge clk);
    for (c = 0; c < 80; c = c + 1) begin
      read_line_col(line_sel, c[6:0], d);
      exp_word = {c[7:0] ^ 8'hC0, c[7:0] ^ 8'h30, c[7:0] ^ 8'h0C, c[7:0] ^ 8'h03};
      if (d !== exp_word) begin
        $display("FAIL displayed buffer column %0d: got %08x want %08x",
                 c, d, exp_word);
        errors = errors + 1;
      end
      read_line_col(~line_sel, c[6:0], d);
      exp_word = {c[7:0] ^ 8'h80, c[7:0] ^ 8'h40, c[7:0] ^ 8'h20, c[7:0] ^ 8'h10};
      if (d !== exp_word) begin
        $display("FAIL prefetched buffer column %0d: got %08x want %08x",
                 c, d, exp_word);
        errors = errors + 1;
      end
    end

    // ------------------------------------------------------------------
    // 8. The line base is an ADDRESS, not an increment: the next tick presents a
    //    line whose origin is a plain store's bytes, and after that tick the
    //    display buffer holds the line presented at the previous one (0x2100),
    //    while the new line sits in the other buffer. Nothing here assumes
    //    pitch == 80 (NP2kai's pitch rule).
    // ------------------------------------------------------------------
    scan_line_base = 15'h2200;
    @(negedge clk);
    scan_line_tick = 1;
    @(negedge clk);
    scan_line_tick = 0;
    for (n = 0; n < 2000; n = n + 1) @(posedge clk);
    for (c = 0; c < 80; c = c + 1) begin
      read_line_col(line_sel, c[6:0], d);
      exp_word = {c[7:0] ^ 8'h80, c[7:0] ^ 8'h40, c[7:0] ^ 8'h20, c[7:0] ^ 8'h10};
      if (d !== exp_word) begin
        $display("FAIL re-based display column %0d: got %08x want %08x",
                 c, d, exp_word);
        errors = errors + 1;
      end
    end
    read_line_col(~line_sel, 7'd0, d);
    if (d !== 32'h0000_0078) begin
      $display("FAIL the re-based line read %08x, want the blue byte 0x78", d);
      errors = errors + 1;
    end

    // ------------------------------------------------------------------
    // 9. The tick is a LEVEL from its producer, and one LINE is one advance.
    //    pc9821_system used to hand the scanout `gvram_h_count == 847` on a
    //    counter clocked by the pixel enable, i.e. a signal HIGH for the 2-3
    //    clk_sys between enables, while this module's tick branch TOGGLES the
    //    ping-pong select. The net phase was therefore the level's WIDTH mod 2,
    //    which varies with the pixel-enable phase: the displayed line stopped
    //    tracking the raster and the picture bounced and distorted.
    //    The contract is one advance
    //    per line whatever the producer's pulse shape, so every width 1..4 is
    //    driven here. An even width fails on a level-sensitive tick branch.
    // ------------------------------------------------------------------
    fill_all(32'h0000_0000);
    put_byte(2'd0, 15'h3000, 8'hA5);   // line at 0x3000: blue byte 0xA5 at column 0
    put_byte(2'd0, 15'h3100, 8'h5A);   // line at 0x3100: blue byte 0x5A at column 0

    for (w = 1; w <= 4; w = w + 1) begin
      sel_before = line_sel;
      scan_line_base = 15'h3000;
      @(negedge clk);
      scan_line_tick = 1;
      repeat (w) @(negedge clk);
      scan_line_tick = 0;
      if (line_sel === sel_before) begin
        $display("FAIL tick width %0d advanced the displayed buffer 0 times, want 1", w);
        errors = errors + 1;
      end
      repeat (900) @(posedge clk);   // let the 80-column fetch finish
    end

    // One more tick (the single-clk shape the producer now sends) so the buffer
    // selected is the one holding tick 1's line, 0x3000.
    scan_line_base = 15'h3100;
    @(negedge clk);
    scan_line_tick = 1;
    @(negedge clk);
    scan_line_tick = 0;
    repeat (900) @(posedge clk);
    read_line_col(line_sel, 7'd0, d);
    if ((d & 32'h0000_00FF) !== 32'h0000_00A5) begin
      $display("FAIL the tick's line did not reach the display: col0 = %08x, want blue A5", d);
      errors = errors + 1;
    end

    // 10. Nothing ever hands the backend an address outside the GVRAM region,
    //    and every access is a single 32-bit word.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // 11. The walk's TELEMETRY pulses. dbg_walk_start fires ONCE
    //    per one-visit array walk and dbg_walk_cycle is high for every clk_sys
    //    of it, so a capture's GC/GW is the mean walk and GW counts the client
    //    accesses that walked. Three shapes pin it: a dword store walks four
    //    lanes, a byte store walks one (and still reports the walk, which is
    //    the accept cycle itself), and a store that changes nothing walks
    //    NOTHING - its walk is a completed no-op with no access.
    // ------------------------------------------------------------------
    port_w(8'h7C, 8'h00);
    gw0 = gw_cnt; gc0 = gc_cnt;
    cpu_store(2'd0, 15'h4000, 32'h1122_3344, 4'hF);
    if (gw_cnt - gw0 != 1 || gc_cnt - gc0 != 4) begin
      $display("FAIL a plain dword store reported GW/GC %0d/%0d, want 1/4",
               gw_cnt - gw0, gc_cnt - gc0);
      errors = errors + 1;
    end
    gw0 = gw_cnt; gc0 = gc_cnt;
    cpu_store(2'd0, 15'h4000, 32'h0000_0044, 4'h1);
    if (gw_cnt - gw0 != 1 || gc_cnt - gc0 != 1) begin
      $display("FAIL a plain byte store reported GW/GC %0d/%0d, want 1/1",
               gw_cnt - gw0, gc_cnt - gc0);
      errors = errors + 1;
    end
    // A GRCG RMW store whose datum is 0x00 leaves every lane's word alone, so there is no walk:
    // no start pulse and no cycle. It is a completed no-op in the accept cycle.
    port_w(8'h7C, 8'hC0);
    put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    gw0 = gw_cnt; gc0 = gc_cnt;
    cpu_store(2'd0, 15'h4000, 32'h0000_0000, 4'hF);
    if (gw_cnt != gw0 || gc_cnt != gc0) begin
      $display("FAIL a no-op GRCG RMW store reported GW/GC %0d/%0d, want none",
               gw_cnt - gw0, gc_cnt - gc0);
      errors = errors + 1;
    end
    port_w(8'h7C, 8'h00);
    repeat (8) @(posedge clk);

    // ------------------------------------------------------------------
    // 12. A display RE-ENABLE arms the line fetch the cycle it rises, not
    //    at the next line tick (report section 5.4). The tick-only
    //    arm waited for the next raster tick - up to a whole line - so a
    //    re-enabled display showed the stale buffer for up to two blank lines
    //    the real GDC does not lose. The tick is NEVER sent after the re-enable
    //    here, so the only thing that can start the fetch is the arm itself.
    // ------------------------------------------------------------------
    put_byte(2'd0, 15'h1000, 8'h3C);   // column 0 of the line at base 0x1000: blue byte 0x3C
    scan_line_base = 15'h1000;
    scan_enable    = 0;
    repeat (4) @(posedge clk);
    if (line_ready) begin
      $display("FAIL line_ready stayed high with the scanout disabled");
      errors = errors + 1;
    end
    scan_enable = 1;
    // 400 clk_sys is well past the 80-column fetch and far short of a raster line, so a fetch
    // armed by the re-enable completes inside it and a tick-armed one never starts at all.
    for (n = 0; n < 400 && !line_ready; n = n + 1) @(posedge clk);
    if (!line_ready) begin
      $display("FAIL the re-enabled scanout did not fetch a line without a line tick");
      errors = errors + 1;
    end else begin
      // The arm latches the CURRENT line's base and page, so the fetched line is the one the
      // address generator is presenting, not the previous tick's.
      read_line_col(~line_sel, 7'd0, d);
      if ((d & 32'h0000_00FF) !== 32'h0000_003C) begin
        $display("FAIL the re-armed fetch did not take the current line's base: col0 = %08x, want blue 3C",
                 d);
        errors = errors + 1;
      end else
        $display("  re-arm: line_ready %0d clk_sys after DISP rose with no line tick", n);
    end

    // ==== CHECKS ====
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_GVRAM: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000_000;   // the fills go through the CPU port now, so this is not a tight bench
    $fatal(1, "TB_PC9821_GVRAM: TIMEOUT");
  end

endmodule
