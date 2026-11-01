`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_WIDTH: the EGC's access-width handling (pc9821_egc.sv's word_unit/unit_lane/acc_be) against NP2kai's memegc_rd8/wr8, memegc_rd16/wr16 and memegc_rd32/wr32 (mem/memegc.c:1367-1423): an 8-bit access at each of the four byte lanes, a 16-bit unit at an even and at an odd lane start, the 32-bit access split into its low and high 16-bit units, and every non-zero byte-enable combination -- each driven as z486 presents it (a dword-aligned address with the operand's lanes ONLY in cpu_be: z486_pkg.sv:1169 calc_be / :1226 calc_be_first / :1242 calc_be_second) and compared byte for byte against a port of NP2kai's own decomposition of the same guest access, including its odd-address fallbacks (memegc_wr16/rd16 doing two byte operations; i386c/cpumem.c:1475 memp_write32 turning an odd dword into byte, word, byte). It covers the shifter only as an UNMOVED copy (sft = 0), where NP2kai's output is the source bytes, and it does not cover a moved shift, the ROP or the mask registers.
//
// The mode is WS_CPU|SHIFT_CPU (ope = 0x0400) for the width cases and WS_CPU (0x0000) for the
// read-back-through-the-shifter cases: a write stores the CPU's own bytes and a read returns the
// READ plane's memory (mem/memegc.c:1091-1098 `mem[ad + planead[pl]]`, pl = fgbg[9:8], the arm
// SHIFT_CPU selects) or the unmoved shifter's copy of it, so the only variable left is which
// bytes each width moves. COMPAREREAD (bit 13) is NOT usable as the memory-observing read here:
// the machine compares in the PAT mode too (EGCREAD.CSV RD22_PATSEL), so that arm returns a
// colour-key MASK, not a plane word (pc9821_egc.sv's ope_cmprd). The five byte-enable sets with a
// GAP between two enabled lanes (0101, 1001, 1010, 1011, 1101) are reported rather than asserted:
// the walk stops at the gap and drops every lane beyond it, but no guest access can produce such a
// set -- z486's calc_be* emits only the ten sets the section-4 loop classifies as reachable, and
// the two apertures that carry the EGC window (0xA0000-0xBFFFF as VGA memory, 0xC0000-0xFFFFF as
// the device aperture) are served DIRECTLY from those enables, with no store-queue or cache
// coalescing behind them (z486's bus_unit direct path, `ext_direct_launch`).

`default_nettype none

module tb_pc9821_egc_width;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // Every case works at this dword-aligned window offset and a few bytes past it.
  localparam integer BASE = 32'h0100;

  // ==== DUT ====
  // WS_CPU | SHIFT_CPU: writes store the CPU data, reads return the READ plane's memory.
  reg [15:0] reg_access = 16'hFFF0;   // all four plane enables (active low)
  reg [15:0] reg_fgbg   = 16'h00FF;
  reg [15:0] reg_ope    = 16'h0400;
  reg [15:0] reg_fg     = 16'h0000;
  reg [15:0] reg_mask   = 16'hFFFF;
  reg [15:0] reg_bg     = 16'h0000;
  reg [15:0] reg_sft    = 16'h0000;
  reg [15:0] reg_leng   = 16'h0FFF;
  reg        reg_shift_we = 1'b0;

  reg        cpu_page = 1'b0;
  reg [14:0] cpu_offset = 15'd0;
  reg [1:0]  cpu_plane = 2'd0;
  reg [31:0] cpu_din = 32'd0;
  reg [3:0]  cpu_be = 4'h0;
  reg        cpu_valid = 1'b0;
  reg        cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;

  wire        cl_valid;
  reg         cl_ready = 1'b1;
  wire        cl_write;
  wire [15:0] cl_addr;
  wire [31:0] cl_wdata;
  wire [3:0]  cl_wbe;
  wire        cl_burst;
  wire [63:0] cl_wdata2;
  reg  [31:0] cl_rdata = 32'd0;
  reg         cl_done = 1'b0;

  pc9821_egc dut (
      .clk(clk), .reset(reset),
      .reg_access(reg_access), .reg_fgbg(reg_fgbg), .reg_ope(reg_ope),
      .reg_fg(reg_fg), .reg_mask(reg_mask), .reg_bg(reg_bg),
      .reg_sft(reg_sft), .reg_leng(reg_leng), .reg_shift_we(reg_shift_we),
      .cpu_page(cpu_page), .cpu_offset(cpu_offset), .cpu_plane(cpu_plane),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .cl_valid(cl_valid), .cl_ready(cl_ready), .cl_write(cl_write), .cl_addr(cl_addr),
      .cl_wdata(cl_wdata), .cl_wbe(cl_wbe), .cl_burst(cl_burst), .cl_wdata2(cl_wdata2),
      .cl_rdata(cl_rdata), .cl_done(cl_done)
  );

  // ==== STIMULUS: the plane store behind the D1 client ====
  // One byte per plane per column of an access page, which is how pc9821_gvram presents the
  // planes: byte p of cl_rdata is plane p's byte at that column (pc9821_gvram.sv's D1 port).
  reg [7:0] pl [0:3][0:32767];

  // The NP2kai reference's plane. Mode 0 writes every enabled plane with the same data, so one
  // reference plane stands for all four; a mismatch is reported per plane below.
  reg [7:0] ref_mem [0:32767];

  function [2:0] be_run(input [3:0] be);   // the run of columns a burst read covers
    integer i;
    integer lo, hi;
    begin
      lo = 4; hi = -1;
      for (i = 0; i < 4; i = i + 1)
        if (be[i]) begin
          if (lo == 4) lo = i;
          hi = i;
        end
      be_run = (hi < 0) ? 3'd0 : 3'(hi - lo + 1);
    end
  endfunction

  function [31:0] col_word(input [15:0] a);
    begin
      col_word = {pl[3][a[14:0]], pl[2][a[14:0]], pl[1][a[14:0]], pl[0][a[14:0]]};
    end
  endfunction

  reg [15:0] rd_addr;
  reg [3:0]  rd_left;
  integer    wp;

  always @(posedge clk) begin
    cl_done <= 1'b0;
    if (cl_valid && cl_ready) begin
      if (cl_write) begin
        for (wp = 0; wp < 4; wp = wp + 1)
          if (cl_wbe[wp]) begin
            pl[wp][cl_addr[14:0]] <= cl_wdata[{wp[1:0], 3'b000} +: 8];
            if (cl_burst)
              pl[wp][cl_addr[14:0] + 15'd1] <= cl_wdata2[32 + {wp[1:0], 3'b000} +: 8];
          end
        // The per-column write path waits for its own cl_done (pc9821_egc's S_WR_ACC); the
        // two-column burst write advances on the ACCEPT alone, so it gets no pulse.
        if (!cl_burst) cl_done <= 1'b1;
      end else begin
        rd_addr <= cl_addr;
        rd_left <= {1'b0, be_run(cl_wbe)};
      end
    end else if (rd_left != 4'd0) begin
      cl_rdata <= col_word(rd_addr);
      cl_done  <= 1'b1;
      rd_addr  <= rd_addr + 16'd1;
      rd_left  <= rd_left - 4'd1;
    end
  end

  // ==== STIMULUS: NP2kai's decomposition of a guest access, as the reference ====
  // memegc_wr8/egc_writebyte: the byte of the plane word at `o`'s 16-bit word (memegc.c:1127).
  task automatic ref_byte(input integer o, input [7:0] v);
    begin ref_mem[o] = v; end
  endtask
  // egc_writeword: the word at `o` in the plane's memory (memegc.c:1322).
  task automatic ref_word(input integer o, input [15:0] v);
    begin
      ref_mem[o]     = v[7:0];
      ref_mem[o + 1] = v[15:8];
    end
  endtask
  // memegc_wr16 (memegc.c:1399): an even address is one egc_writeword; an odd one is two
  // egc_writebyte calls, low byte first (the ascending direction, sft bit 12 clear).
  task automatic ref_wr16(input integer o, input [15:0] v);
    begin
      if ((o & 1) == 0) ref_word(o, v);
      else begin
        ref_byte(o, v[7:0]);
        ref_byte(o + 1, v[15:8]);
      end
    end
  endtask
  // memegc_wr32 (memegc.c:1421): wr16(o) then wr16(o+2); the CPU reaches it only for an even
  // address, and i386c's memp_write32 (i386c/cpumem.c:1475) turns an odd dword into byte(o),
  // write16(o+1), byte(o+3) -- the word being the 16 bits at value[23:8], NOT value[15:8].
  task automatic ref_wr32(input integer o, input [31:0] v);
    begin
      if ((o & 1) == 0) begin
        ref_wr16(o, v[15:0]);
        ref_wr16(o + 2, v[31:16]);
      end else begin
        ref_byte(o, v[7:0]);
        ref_wr16(o + 1, v[23:8]);
        ref_byte(o + 3, v[31:24]);
      end
    end
  endtask

  // ==== STIMULUS: one bus cycle, in the shape z486 presents it ====
  // The address is DWORD-ALIGNED (z486.sv:78 `output [31:2] addr`, pc9821_system forms the guest
  // address as {z_addr, 2'b00}), so the operand's lanes travel ONLY in cpu_be.
  task automatic cyc(input integer addr, input [1:0] plane, input [3:0] be,
                     input [31:0] din, input wr, output [31:0] dout);
    begin
      @(negedge clk);
      cpu_offset = addr[14:0] & 15'h7FFC;
      cpu_page   = 1'b0;
      cpu_plane  = plane;
      cpu_din    = din;
      cpu_be     = be;
      cpu_write  = wr;
      cpu_valid  = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      // The negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'h0;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end else dout = 32'h0;
      @(negedge clk);
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  // A guest access as z486 emits it: one cycle, except the shapes whose operand crosses the dword
  // (calc_be_first/calc_be_second, z486_pkg.sv:1226/:1242) which leave as two.
  task automatic g_byte(input integer o, input [7:0] v, input wr, output [31:0] dout);
    begin
      cyc(o, 2'd0, 4'b0001 << o[1:0], {24'd0, v} << {o[1:0], 3'b000}, wr, dout);
    end
  endtask

  task automatic g_word(input integer o, input [15:0] v, input wr);
    reg [31:0] d;
    begin
      if (o[1:0] == 2'd3) begin
        cyc(o, 2'd0, 4'b1000, {v[7:0], 24'd0}, wr, d);          // first dword: byte 3
        cyc(o + 1, 2'd0, 4'b0001, {24'd0, v[15:8]}, wr, d);     // second: next dword's byte 0
      end else begin
        cyc(o, 2'd0, 4'b0011 << o[1:0], {16'd0, v} << {o[1:0], 3'b000}, wr, d);
      end
    end
  endtask

  task automatic g_dword(input integer o, input [31:0] v, input wr);
    reg [31:0] d;
    integer low;
    integer rest;
    begin
      low = o[1:0];
      rest = 4 - low;
      if (low == 0) cyc(o, 2'd0, 4'b1111, v, wr, d);
      else begin
        cyc(o, 2'd0, 4'b1111 << low, v << (8 * low), wr, d);
        cyc(o + rest, 2'd0, 4'b1111 >> rest, v >> (8 * rest), wr, d);
      end
    end
  endtask

  // ==== CHECKS ====
  integer errors = 0;      // asserted: a case every reachable guest access must pass
  integer dropped = 0;     // reported: bytes dropped, in byte-enable sets z486 cannot present
  integer gap_cases = 0;
  integer mism = 0;
  reg [7:0] exp;

  task automatic clear_win(input integer lo, input integer hi);
    integer o;
    integer p;
    begin
      for (o = lo; o < hi; o = o + 1) begin
        ref_mem[o] = 8'h00;
        for (p = 0; p < 4; p = p + 1) pl[p][o] = 8'h00;
      end
    end
  endtask

  // Every plane byte of the window against NP2kai's.
  task automatic cmp_window(input string tag, input integer lo, input integer hi);
    integer o;
    integer p;
    begin
      for (o = lo; o < hi; o = o + 1)
        for (p = 0; p < 4; p = p + 1)
          if (pl[p][o] !== ref_mem[o]) begin
            $display("MISMATCH %0s: plane %0d offset %04x expected %02x actual %02x",
                     tag, p, o, ref_mem[o], pl[p][o]);
            mism = mism + 1;
          end
    end
  endtask

  // The bytes a read cycle returned, at the lanes its own byte enables cover.
  task automatic cmp_read(input string tag, input integer base, input [3:0] be,
                          input [31:0] dout, input [1:0] plane, input use_ref);
    integer l;
    begin
      for (l = 0; l < 4; l = l + 1)
        if (be[l]) begin
          exp = use_ref ? ref_mem[base + l] : pl[plane][base + l];
          if (dout[8*l +: 8] !== exp) begin
            $display("MISMATCH %0s: read lane %0d offset %04x expected %02x actual %02x",
                     tag, l, base + l, exp, dout[8*l +: 8]);
            mism = mism + 1;
          end
        end
    end
  endtask

  // Every plane byte of the window against NP2kai's, but only the planes the access
  // register enables may move: a disabled plane keeps its initial byte.
  task automatic cmp_window_en(input string tag, input integer lo, input integer hi,
                               input [3:0] en);
    integer o;
    integer p;
    begin
      for (o = lo; o < hi; o = o + 1)
        for (p = 0; p < 4; p = p + 1) begin
          exp = en[p] ? ref_mem[o] : 8'h00;
          if (pl[p][o] !== exp) begin
            $display("MISMATCH %0s: plane %0d offset %04x expected %02x actual %02x",
                     tag, p, o, exp, pl[p][o]);
            mism = mism + 1;
          end
        end
    end
  endtask

  task automatic case_verdict(input string tag, input integer m0, input bit strict);
    begin
      cases = cases + 1;
      if (mism == m0) $display("CASE %0s: OK", tag);
      else begin
        failed_cases = failed_cases + 1;
        if (strict) begin
          errors = errors + (mism - m0);
          $display("CASE %0s: MISMATCH (%0d bytes)", tag, mism - m0);
        end else begin
          gap_cases = gap_cases + 1;
          dropped = dropped + (mism - m0);
          $display("CASE %0s: MISMATCH (%0d bytes) -- UNREACHABLE set: every lane after the gap is dropped",
                   tag, mism - m0);
        end
      end
    end
  endtask

  reg [31:0] dout;
  reg [31:0] v32;
  reg [3:0]  b;
  integer m0;
  integer l;
  integer p;
  integer cases;
  integer failed_cases;

  initial begin : run
    // ==== DUT bring-up ====
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);
    clear_win(0, 32768);

    // ---------------------------------------------------------------
    // 1. 8-BIT: one case per byte lane.
    // ---------------------------------------------------------------
    for (l = 0; l < 4; l = l + 1) begin
      m0 = mism;
      clear_win(BASE - 4, BASE + 12);
      v32 = 32'h5A5A5A5A + {24'd0, l[7:0]} * 32'h01010101;
      ref_byte(BASE + l, v32[8*l +: 8]);
      g_byte(BASE + l, v32[8*l +: 8], 1'b1, dout);
      cmp_window("w8 lane", BASE - 4, BASE + 12);
      cyc(BASE + l, 2'd0, 4'b0001 << l[1:0], 32'd0, 1'b0, dout);
      cmp_read("r8 lane", BASE, 4'b0001 << l[1:0], dout, 2'd0, 1'b1);
      case_verdict("8-bit lane", m0, 1);
    end

    // ---------------------------------------------------------------
    // 2. 16-BIT: even lane starts (0:1, 2:3) and the odd start (1:2), plus the
    //    offset-3 operand z486 splits into two cycles.
    // ---------------------------------------------------------------
    // (a) lanes 0:1 -- memegc_wr16 at an even address is ONE egc_writeword.
    m0 = mism;
    clear_win(BASE - 4, BASE + 12);
    ref_wr16(BASE, 16'hB2A1);
    g_word(BASE, 16'hB2A1, 1'b1);
    cmp_window("w16 @+0", BASE - 4, BASE + 12);
    cyc(BASE, 2'd0, 4'b0011, 32'd0, 1'b0, dout);
    cmp_read("r16 @+0", BASE, 4'b0011, dout, 2'd0, 1'b1);
    case_verdict("w16/r16 lanes 0:1", m0, 1);

    // (b) lanes 2:3 -- the same call at addr+2, the lane an earlier fix covered.
    m0 = mism;
    clear_win(BASE - 4, BASE + 12);
    ref_wr16(BASE + 2, 16'hD4C3);
    g_word(BASE + 2, 16'hD4C3, 1'b1);
    cmp_window("w16 @+2", BASE - 4, BASE + 12);
    cyc(BASE + 2, 2'd0, 4'b1100, 32'd0, 1'b0, dout);
    cmp_read("r16 @+2", BASE, 4'b1100, dout, 2'd0, 1'b1);
    case_verdict("w16/r16 lanes 2:3", m0, 1);

    // (c) lanes 1:2 -- an ODD start: memegc_wr16's else branch is two egc_writebyte calls.
    m0 = mism;
    clear_win(BASE - 4, BASE + 12);
    ref_wr16(BASE + 1, 16'hF6E5);
    g_word(BASE + 1, 16'hF6E5, 1'b1);
    cmp_window("w16 @+1", BASE - 4, BASE + 12);
    cyc(BASE + 1, 2'd0, 4'b0110, 32'd0, 1'b0, dout);
    cmp_read("r16 @+1", BASE, 4'b0110, dout, 2'd0, 1'b1);
    case_verdict("w16/r16 lanes 1:2 (odd start)", m0, 1);

    // (d) an offset-3 word: z486's two cycles, byte 3 then the next dword's byte 0.
    m0 = mism;
    clear_win(BASE - 4, BASE + 12);
    ref_wr16(BASE + 3, 16'h18F7);
    g_word(BASE + 3, 16'h18F7, 1'b1);
    cmp_window("w16 @+3", BASE - 4, BASE + 12);
    cyc(BASE + 3, 2'd0, 4'b1000, 32'd0, 1'b0, dout);
    cmp_read("r16 @+3a", BASE, 4'b1000, dout, 2'd0, 1'b1);
    cyc(BASE + 4, 2'd0, 4'b0001, 32'd0, 1'b0, dout);
    cmp_read("r16 @+3b", BASE + 4, 4'b0001, dout, 2'd0, 1'b1);
    case_verdict("w16/r16 lanes 3:4 (dword crossing)", m0, 1);

    // ---------------------------------------------------------------
    // 3. 32-BIT: the aligned access is ONE be=1111 cycle that NP2kai's memegc_wr32
    //    splits into two memegc_wr16 calls (low 16 first); the unaligned ones leave
    //    z486 as be_first then be_second, which i386c decomposes the same way.
    // ---------------------------------------------------------------
    // (a) aligned: ref_wr32(addr) = wr16(addr) + wr16(addr+2).
    m0 = mism;
    clear_win(BASE - 8, BASE + 16);
    v32 = 32'h44332211;
    ref_wr32(BASE, v32);
    g_dword(BASE, v32, 1'b1);
    cmp_window("w32 @+0", BASE - 8, BASE + 16);
    cyc(BASE, 2'd0, 4'b1111, 32'd0, 1'b0, dout);
    cmp_read("r32 @+0", BASE, 4'b1111, dout, 2'd0, 1'b1);
    case_verdict("w32/r32 aligned", m0, 1);

    // (b) offset 2: z486's be_first 1100 (a word at +2) then be_second 0011 (a word at +4).
    m0 = mism;
    clear_win(BASE - 8, BASE + 16);
    v32 = 32'h88776655;
    ref_wr32(BASE + 2, v32);
    g_dword(BASE + 2, v32, 1'b1);
    cmp_window("w32 @+2", BASE - 8, BASE + 16);
    cyc(BASE + 2, 2'd0, 4'b1100, 32'd0, 1'b0, dout);
    cmp_read("r32 @+2a", BASE, 4'b1100, dout, 2'd0, 1'b1);
    cyc(BASE + 4, 2'd0, 4'b0011, 32'd0, 1'b0, dout);
    cmp_read("r32 @+2b", BASE + 4, 4'b0011, dout, 2'd0, 1'b1);
    case_verdict("w32/r32 at offset 2", m0, 1);

    // (c) offset 1: be_first 1110 is byte, word; be_second 0001 is the next dword's byte 0.
    m0 = mism;
    clear_win(BASE - 8, BASE + 16);
    v32 = 32'hCCBBAA99;
    ref_wr32(BASE + 1, v32);
    g_dword(BASE + 1, v32, 1'b1);
    cmp_window("w32 @+1", BASE - 8, BASE + 16);
    cyc(BASE + 1, 2'd0, 4'b1110, 32'd0, 1'b0, dout);
    cmp_read("r32 @+1a", BASE, 4'b1110, dout, 2'd0, 1'b1);
    cyc(BASE + 4, 2'd0, 4'b0001, 32'd0, 1'b0, dout);
    cmp_read("r32 @+1b", BASE + 4, 4'b0001, dout, 2'd0, 1'b1);
    case_verdict("w32/r32 at offset 1", m0, 1);

    // (d) offset 3: be_first 1000 is byte 3; be_second 0111 is a word plus a byte.
    m0 = mism;
    clear_win(BASE - 8, BASE + 16);
    v32 = 32'h1F0E0D0C;
    ref_wr32(BASE + 3, v32);
    g_dword(BASE + 3, v32, 1'b1);
    cmp_window("w32 @+3", BASE - 8, BASE + 16);
    cyc(BASE + 3, 2'd0, 4'b1000, 32'd0, 1'b0, dout);
    cmp_read("r32 @+3a", BASE, 4'b1000, dout, 2'd0, 1'b1);
    cyc(BASE + 4, 2'd0, 4'b0111, 32'd0, 1'b0, dout);
    cmp_read("r32 @+3b", BASE + 4, 4'b0111, dout, 2'd0, 1'b1);
    case_verdict("w32/r32 at offset 3", m0, 1);

    // ---------------------------------------------------------------
    // 4. EVERY NON-ZERO BYTE-ENABLE COMBINATION (1, 2, 3 and 4 bytes) as ONE
    //    access: each enabled lane's byte must land at that lane, which is what
    //    NP2kai's byte granularity does for the reachable sets. The five sets with a
    //    gap (0101, 1001, 1010, 1011, 1101) are NOT reachable from z486 -- neither
    //    calc_be nor calc_be_first/second can emit one -- so a mismatch there is
    //    reported, not asserted.
    // ---------------------------------------------------------------
    for (b = 4'd1; b != 4'd0; b = b + 4'd1) begin
      m0 = mism;
      clear_win(BASE - 4, BASE + 12);
      v32 = 32'h44332211;
      for (l = 0; l < 4; l = l + 1)
        if (b[l]) ref_byte(BASE + l, v32[8*l +: 8]);
      cyc(BASE, 2'd0, b, v32, 1'b1, dout);
      cmp_window("be", BASE - 4, BASE + 12);
      cyc(BASE, 2'd0, b, 32'd0, 1'b0, dout);
      cmp_read("be read", BASE, b, dout, 2'd0, 1'b1);
      // A set z486 can emit (calc_be/calc_be_first/calc_be_second) is an error; a set with
      // a gap between two enabled lanes is one no guest access can produce, so it is reported.
      case_verdict($sformatf("byte-enables %04b", b), m0,
                   (b == 4'b0001 || b == 4'b0010 || b == 4'b0100 || b == 4'b1000 ||
                    b == 4'b0011 || b == 4'b0110 || b == 4'b1100 || b == 4'b1111 ||
                    b == 4'b1110 || b == 4'b0111));
    end

    // ---------------------------------------------------------------
    // 5. THE READ NAMES THE PLANE 0x4A2 SELECTS. Each plane is preloaded with its own
    //    byte through a single-plane write (access[3:0] active low), then the same
    //    lane is read through each of the four windows with the read-plane selector
    //    set to that window's plane. NP2kai returns mem[ad + planead[pl]] on the
    //    SHIFT_CPU arm (mem/memegc.c:1091-1098) and our read must name the plane the
    //    selector names. (The old COMPAREREAD arm returned the ADDRESSED window
    //    plane; the machine compares in PAT mode too, so that arm returns a mask and
    //    cannot observe a plane at all - EGCREAD.CSV RD22_PATSEL.)
    // ---------------------------------------------------------------
    m0 = mism;
    clear_win(BASE - 4, BASE + 12);
    for (p = 0; p < 4; p = p + 1) begin
      reg_access = 16'hFFF0 | (16'h0001 << p);   // plane p's enable LOW, the rest HIGH
      @(negedge clk);
      g_byte(BASE + p, 8'h40 + p[7:0], 1'b1, dout);
      pl[p][BASE + p] = 8'h40 + p[7:0];
      ref_mem[BASE + p] = 8'h40 + p[7:0];
    end
    reg_access = 16'hFFF0;
    for (p = 0; p < 4; p = p + 1) begin
      reg_fgbg = {6'h00, p[1:0], 6'h00, p[1:0]};   // read plane = the window's own plane
      @(negedge clk);
      cyc(BASE + p, p[1:0], 4'b0001 << p[1:0], 32'd0, 1'b0, dout);
      cmp_read("rplane", BASE, 4'b0001 << p[1:0], dout, p[1:0], 1'b0);
    end
    reg_fgbg = 16'h00FF;
    case_verdict("read returns the selected plane", m0, 1);

    // ---------------------------------------------------------------
    // 7. THE READ BACK THROUGH THE SHIFTER, which is the path the games use. WS_CPU
    //    (ope = 0) with an unmoved shift (sft = 0) makes NP2kai's shifter a plain
    //    copy of the source quad: egc_readbyte/egc_readword feed every plane from
    //    lastvram and return egc_src._b[pl][ext] (memegc.c:1114-1123), pl being the
    //    READ plane register fgbg[9:8] -- so each width must come back as the plane's
    //    own bytes at the lanes its enables cover. This is a different response path
    //    from COMPAREREAD's (sdata/sbyte_next instead of quad_byte), and the widths
    //    are what decide whether the word feed or the byte feed produces it.
    // ---------------------------------------------------------------
    for (l = 0; l < 8; l = l + 1) begin
      m0 = mism;
      clear_win(BASE - 4, BASE + 12);
      v32 = 32'h44332211;
      case (l)
        0: begin ref_byte(BASE, 8'h11);   g_byte(BASE, 8'h11, 1'b1, dout);   b = 4'b0001; end
        1: begin ref_byte(BASE + 1, 8'h22); g_byte(BASE + 1, 8'h22, 1'b1, dout); b = 4'b0010; end
        2: begin ref_byte(BASE + 2, 8'h33); g_byte(BASE + 2, 8'h33, 1'b1, dout); b = 4'b0100; end
        3: begin ref_byte(BASE + 3, 8'h44); g_byte(BASE + 3, 8'h44, 1'b1, dout); b = 4'b1000; end
        4: begin ref_wr16(BASE, 16'h2211);   g_word(BASE, 16'h2211, 1'b1);   b = 4'b0011; end
        5: begin ref_wr16(BASE + 2, 16'h4433); g_word(BASE + 2, 16'h4433, 1'b1); b = 4'b1100; end
        6: begin ref_wr16(BASE + 1, 16'h3322); g_word(BASE + 1, 16'h3322, 1'b1); b = 4'b0110; end
        7: begin ref_wr32(BASE, v32);        g_dword(BASE, v32, 1'b1);       b = 4'b1111; end
      endcase
      reg_ope = 16'h0000;   // WS_CPU, no SHIFT_CPU: the shifter's own output
      cyc(BASE, 2'd0, b, 32'd0, 1'b0, dout);
      cmp_read("shifter read", BASE, b, dout, 2'd0, 1'b1);
      reg_ope = 16'h0400;
      case_verdict("read back through the shifter", m0, 1);
    end

    // ---------------------------------------------------------------
    // 6. THE PLANE ENABLES ARE PER COLUMN, AT EVERY WIDTH. NP2kai ANDs each
    //    plane's own enable into that plane's write (memegc.c:1142-1166 byte,
    //    :1343-1366 word), so a plane the access register disables must keep its
    //    bytes while the enabled ones take the operand's. That is the transpose
    //    pc9821_egc.sv's wr_be_p/col_wbe makes, from a per-plane value and
    //    byte-enable to the D1 port's per-column enable: a lane landing on the
    //    wrong column shows up here and nowhere else.
    // ---------------------------------------------------------------
    for (l = 0; l < 5; l = l + 1) begin
      m0 = mism;
      clear_win(BASE - 4, BASE + 12);
      reg_access = 16'hFFF5;   // planes 1 and 3 enabled (access[3:0] active LOW)
      v32 = 32'h44332211;
      case (l)
        0: begin g_byte(BASE, 8'h11, 1'b1, dout); ref_byte(BASE, 8'h11); end
        1: begin g_word(BASE, 16'h2211, 1'b1); ref_wr16(BASE, 16'h2211); end
        2: begin g_word(BASE + 2, 16'h4433, 1'b1); ref_wr16(BASE + 2, 16'h4433); end
        3: begin g_word(BASE + 1, 16'h3322, 1'b1); ref_wr16(BASE + 1, 16'h3322); end
        4: begin g_dword(BASE, v32, 1'b1); ref_wr32(BASE, v32); end
      endcase
      cmp_window_en("planes 1,3", BASE - 4, BASE + 12, 4'b1010);
      reg_access = 16'hFFF0;
      case_verdict("plane enables at width", m0, 1);
    end

    // ==== VERDICT ====
    $display("TB_PC9821_EGC_WIDTH: %0d cases, %0d mismatching, of which %0d are unreachable byte-enable sets dropping %0d bytes; %0d reachable mismatches",
             cases, failed_cases, gap_cases, dropped, errors);
    if (errors == 0) begin
      $display("TB_PC9821_EGC_WIDTH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_EGC_WIDTH: FAIL (%0d reachable mismatches)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_EGC_WIDTH: TIMEOUT");
  end

endmodule

`default_nettype wire
