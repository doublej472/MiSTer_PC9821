`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_CONFORMANCE: a DIFFERENTIAL conformance suite for the EGC. The REAL pc9821_egc (through the REAL pc9821_gvram client and the REAL src/memory/sdram.v controller against the chip model) and the behavioural REFERENCE model tests/pc9821/pc9821_egc_ref.sv - a function-for-function transcription of NP2kai's mem/memegc.c and io/egc.c - are driven through the same matrix of registers and CPU accesses and must agree BYTE FOR BYTE on the resulting GVRAM and on every read datum. Each case gets its own 16-byte window on both pages. The matrix covers the three write modes (WS_CPU 0x0000, WS_ROP 0x0800/0x0B00/0x0CF0, WS_PATREG 0x1000/0x1400), all 256 ROP codes, the read modes (COMPAREREAD 0x2000, SHIFT_CPU 0x0400, RL_MEMREAD 0x0100), the colour-quad selects, the plane-enable register, the mask register, byte/word/dword and odd-word accesses over every byte-enable set, the shift register (both directions, moved and byte-aligned sub-byte shifts, srcbit >= 8), and the two shapes already bit by the optimizations: a 32-bit put with shift 0 over a WCB-dirty destination (the m_mode fallback) and a posted write followed by a same-word read. It does NOT measure timing or column counts; those are tb_pc9821_egc.sv's sections 12-15.
//
// Two regressions sit outside that matrix: section 0 is the NO-ARM-AFTER-
// RESET store (F1) - the very first EGC op after reset, with the registers at their
// power-up image and no 0x4AC/0x4AE write, must store bit-exactly (NP2kai's egc_reset
// arms remain = 16); section 9 is the MISALIGNED 16-BIT SPLIT (F2) - memegc_wr16/rd16 at
// an odd address runs its two byte operations HIGH-byte-first when sft bit 12 is set, so
// the be = 0110 walk must follow that direction order in both feeding modes.
//
// Two more cases sit outside
// the matrix for the same reason: section 10 drives the 3-BYTE UNALIGNED BEATS
// in a feeding mode, where merging the even lane pair into one word
// unit diverges from memegc_wr32's four byte operations; section 11 pins the
// STACK-GATED FEED's ring write, which the CPU-visible surface cannot
// reach (see the section header), so the check reads the ring itself against gold.ebuf.

`default_nettype none

module tb_pc9821_egc_conformance;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;

  // ==== DUT ====
  reg  [31:0] gvram_base = GVRAM_BASE;
  reg         access_page = 1'b0;
  reg  [1:0]  win_plane = 2'd0;
  reg [14:0]  win_offset = 15'd0;
  reg [31:0]  cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'hF;
  reg         cpu_line_read = 1'b0;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h3100,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'd0;
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

  // The real controller, at the built configuration, against the chip model (as
  // tb_pc9821_egc_post_walk.sv drives it).

  

  

  // The golden. One node per bench invocation; its tasks are called hierarchically.
  pc9821_egc_ref gold();

  integer errors = 0;
  integer cases  = 0;
  integer pin_cases = 0;   // synthetic-be self-consistency pins (excluded from the conformance count)

  task automatic fail(input [8*200-1:0] what);
    begin
      $display("FAIL: %0s @ %0t", what, $time);
      errors = errors + 1;
    end
  endtask

  // ---- one CPU access through the gvram, gate on (the EGC) or off (the plain path) ----
  task automatic access_op(input pg, input [1:0] plane, input [14:0] off,
                           input [31:0] din, input [3:0] be, input wr, input egc,
                           output [31:0] dout);
    begin
      @(negedge clk);
      access_page = pg;
      egc_gate    = egc;
      win_plane   = plane;
      win_offset  = off;
      cpu_din     = din;
      cpu_be      = be;
      cpu_write   = wr;
      cpu_valid   = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Release at the ready edge (z486's own shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`):
      // the pipelined produce registers the read response one cycle after the ready -
      // the read values are unchanged and still the machine's own (docs/probes/egc-conformance/xe10/
      // EGCREAD.CSV), and the +1 stays under the machine's measured read cost (GFX2-rerun.TXT
      // EGC3100SP) - so a request held into the response cycle is taken twice by the S_IDLE accept.
      // `egc_gate` is NOT released with the request: it is the machine's EGC arming level (0x6A
      // num 2 AND 0x7C bit 7, the register pair NP2kai's io/egc.c drives), not a per-access signal,
      // and the response is routed to the owner the latch holds through it.
      // The negedge below is the old release's own wait, kept so the op retires one cycle after its
      // data and the +1 stays visible in the cadence.
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end else dout = 32'h0000_0000;
      @(negedge clk);
      egc_gate = 1'b0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic flush_wcb;
    begin
      @(negedge clk);
      scan_line_tick = 1'b1;
      @(negedge clk);
      scan_line_tick = 1'b0;
      @(posedge clk);
      while (1'b0) @(posedge clk);
      @(posedge clk);
    end
  endtask

  // ---- the register file, mirrored into DUT latches and into the reference, in the
  //      io/egc.c order: fgbg before the gated mask, sft then leng with the re-arm pulse ----
  task automatic cfg(input [15:0] c_access, c_fgbg, c_ope, c_fg, c_mask, c_bg,
                     input [15:0] c_sft, c_leng);
    begin
      @(negedge clk);
      egc_fgbg = c_fgbg;
      egc_ope  = c_ope;
      egc_fg   = c_fg;
      if ((c_fgbg & 16'h6000) == 16'h0000) egc_mask = c_mask;
      egc_bg   = c_bg;
      egc_access = c_access;
      egc_sft  = c_sft;
      egc_leng = c_leng;
      egc_shift_we = 1'b1;
      @(negedge clk);
      egc_shift_we = 1'b0;
      gold.set_access(c_access);
      gold.set_fgbg(c_fgbg);
      gold.set_ope(c_ope);
      gold.set_fg(c_fg);
      gold.set_mask(c_mask);
      gold.set_bg(c_bg);
      gold.set_sft(c_sft);
      gold.set_leng(c_leng);
      repeat (2) @(posedge clk);
    end
  endtask

  // ---- the per-case window: window `idx` is 16 bytes at 0x1000 + 16*idx on BOTH pages ----
  function [14:0] win_base(input integer idx);
    win_base = 15'h1000 + 15'((idx & 16'h03FF) * 16);
  endfunction

  function [7:0] seedval(input integer pg, input integer plane, input [14:0] off);
    seedval = 8'((pg * 8'h5B) + (plane * 8'h71) + (off * 8'h1D) + ((off >> 3) * 8'h29) + 8'hA5);
  endfunction

  // Seed window idx on both pages, all four planes, and in both memories.
  task automatic seed_win(input integer idx);
    integer pg, p, k;
    reg [31:0] d, sink;
    begin
      for (pg = 0; pg < 2; pg = pg + 1)
        for (p = 0; p < 4; p = p + 1)
          for (k = 0; k < 4; k = k + 1) begin
            d = {seedval(pg, p, win_base(idx) + 4*k + 3), seedval(pg, p, win_base(idx) + 4*k + 2),
                 seedval(pg, p, win_base(idx) + 4*k + 1), seedval(pg, p, win_base(idx) + 4*k + 0)};
            access_op(pg, p[1:0], win_base(idx) + 4*k, d, 4'hF, 1'b1, 1'b0, sink);
            for (integer b = 0; b < 4; b = b + 1)
              gold.seed(pg, p, win_base(idx) + 4*k + b, d[8*b +: 8]);
          end
    end
  endtask

  // Compare window idx, all four planes, byte for byte.
  task automatic cmp_win(input integer idx, input [8*60-1:0] tag);
    integer p, k, b;
    reg [31:0] d;
    begin
      for (p = 0; p < 4; p = p + 1)
        for (k = 0; k < 4; k = k + 1) begin
          access_op(1'b0, p[1:0], win_base(idx) + 4*k, 32'd0, 4'hF, 1'b0, 1'b0, d);
          for (b = 0; b < 4; b = b + 1)
            if (d[8*b +: 8] !== gold.peek(0, p, win_base(idx) + 4*k + b)) begin
              $display("FAIL case %0d (%0s) p%0d off %04x: got %02x want %02x",
                       idx, tag, p, win_base(idx) + 4*k + b, d[8*b +: 8],
                       gold.peek(0, p, win_base(idx) + 4*k + b));
              errors = errors + 1;
            end
        end
    end
  endtask

  // ---- one occurring x86 SHAPE, driven as its logical access into the gold and as the
  //      z486 beat split into the DUT. The gold takes memegc's own
  //      dispatch VERBATIM (pc9821_egc_ref op8/op16/op32 = memegc.c:1379-1424) at the
  //      access's byte address; the DUT sees the beats calc_be/calc_be_first/
  //      calc_be_second issue for it (src/z486/z486_pkg.sv:1169/:1226/:1242), lane L of
  //      the dword carrying din[8*L +: 8] (shift_write_data's mapping). No beat-level
  //      rule is consulted on the gold side at all, so the comparison is DUT-vs-NP2kai,
  //      not DUT-vs-a-rule-derived-from-the-DUT.
  task automatic shape_op(input integer idx, input [8*40-1:0] tag,
                          input integer kind,   // 0 = byte, 1 = word, 2 = dword
                          input integer aa,     // the access's addr[1:0], at win_base+4+aa
                          input [31:0] v);
    reg [31:0] sink, b0, b1, d32;
    reg [15:0] d16;
    reg [7:0]  d8;
    reg [3:0]  e0, e1;
    integer nb;
    begin
      cases = cases + 1;
      b0 = 32'd0; b1 = 32'd0; e0 = 4'd0; e1 = 4'd0; nb = 1;
      case (kind)
        0: begin e0 = 4'b0001 << aa; b0 = v << (8*aa); end
        1: case (aa)
             0: begin e0 = 4'b0011; b0 = v; end
             1: begin e0 = 4'b0110; b0 = v << 8; end
             2: begin e0 = 4'b1100; b0 = v << 16; end
             default: begin nb = 2; e0 = 4'b1000; b0 = (v & 32'hFF) << 24;
                             e1 = 4'b0001; b1 = (v >> 8) & 32'hFF; end
           endcase
        default: case (aa)
             0: begin e0 = 4'b1111; b0 = v; end
             1: begin nb = 2; e0 = 4'b1110; b0 = (v & 32'h00FF_FFFF) << 8;
                         e1 = 4'b0001; b1 = (v >> 24) & 32'hFF; end
             2: begin nb = 2; e0 = 4'b1100; b0 = (v & 32'hFFFF) << 16;
                         e1 = 4'b0011; b1 = (v >> 16) & 32'hFFFF; end
             default: begin nb = 2; e0 = 4'b1000; b0 = (v & 32'hFF) << 24;
                         e1 = 4'b0111; b1 = (v >> 8) & 32'h00FF_FFFF; end
           endcase
      endcase
      if (kind == 0)        gold.op8 (1'b0, 2'd0, win_base(idx) + 4 + aa, v[7:0],  1'b1, d8);
      else if (kind == 1)   gold.op16(1'b0, 2'd0, win_base(idx) + 4 + aa, v[15:0], 1'b1, d16);
      else                  gold.op32(1'b0, 2'd0, win_base(idx) + 4 + aa, v,       1'b1, d32);
      access_op(1'b0, 2'd0, win_base(idx) + 4, b0, e0, 1'b1, 1'b1, sink);
      if (nb == 2) access_op(1'b0, 2'd0, win_base(idx) + 8, b1, e1, 1'b1, 1'b1, sink);
    end
  endtask

  // ---- one EGC op, driven into both, with the read datum compared ----
  task automatic egc_op(input integer idx, input [8*40-1:0] tag,
                        input pg, input [1:0] plane, input [14:0] off,
                        input [31:0] din, input [3:0] be, input wr);
    reg [31:0] dd, dr;
    begin
      cases = cases + 1;
      access_op(pg, plane, off, din, be, wr, 1'b1, dd);
      gold.op(pg, plane, off, din, be, wr, dr);
      if (!wr && (dd !== dr)) begin
        $display("FAIL case %0d (%0s): read %08x want %08x (pg%0d pl%0d off %04x be %x din %08x)",
                 idx, tag, dd, dr, pg, plane, off, be, din);
        errors = errors + 1;
      end
    end
  endtask

  integer i, rop, m;
  reg [31:0] dd;
  reg [15:0] cfgs [0:7];
  integer cidx;

  // ==== CHECKS ====
  // Sections 1-8 drive the matrix; each egc_op compares its read datum and cmp_win compares the
  // case's whole 16-byte window on all four planes, so a mismatch is counted once per wrong byte.
  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    gold.rst();

    // ============================================================
    // 0. THE NO-ARM-AFTER-RESET STORE. The FIRST EGC op after
    //    reset, with the register file at its power-up image (as egc_reset leaves it,
    //    io/egc.c:69-80) and NO 0x4AC/0x4AE write: NP2kai's egc_reset ends in egcshift()
    //    at leng 0x000F, so remain is 16 and the first store is masked 0xFFFF/0xFFFF.
    //    This runs before any other EGC op because the corruption is exactly one unit
    //    per reset (a producing read would burn the bad unit first).
    // ============================================================
    begin : no_arm_store
      egc_access = 16'hFFF0; egc_fgbg = 16'h00FF; egc_ope = 16'h0000;
      egc_fg = 16'h0000; egc_mask = 16'hFFFF; egc_bg = 16'h0000;
      egc_sft = 16'h0000; egc_leng = 16'h000F;
      seed_win(3968);
      egc_op(3968, "no-arm store", 1'b0, 2'd0, win_base(3968) + 4,
             32'hA5C3_9E6B, 4'hF, 1'b1);
      cmp_win(3968, "no-arm store");
      $display("NOTE egc_conf: section 0 no-arm-after-reset store - 1 case");
    end

    // ============================================================
    // 1. WS_CPU (ope 0x0000): the CPU datum, all widths, every byte-enable set,
    //    every plane-enable register, the mask register.
    //    A 16-bit unit in this mode feeds the shifter (memegc.c egc_opew default
    //    `EGCOPE_SHIFTW2`); a byte unit does not (egc_opeb default).
    //
    //    PROVENANCE: the be-set walk is re-derived from NP2kai's
    //    dispatch (mem/memegc.c:1379-1424) + the z486 beat split (z486_pkg.sv:1169
    //    calc_be / :1226 calc_be_first / :1242 calc_be_second), NOT from the DUT-side
    //    rule it used to mirror -- see pc9821_egc_ref's op() header for
    //    the per-set derivation. The sweep is split:
    //      * CONFORMANCE (counted): the 10 byte-enable sets an x86 access generates.
    //      * SELF-CONSISTENCY PIN (NOT counted): the 5 synthetic hole sets (0101, 1001,
    //        1010, 1011, 1101) -- calc_be* never emits them and memegc has no
    //        counterpart; they pin the lane walk against itself only.
    //    The occurring shapes are then re-driven as their LOGICAL accesses (shape_op:
    //    gold = memegc dispatch verbatim, DUT = the beat pair z486 splits them into),
    //    including the unaligned-dword halves 1110+0001 and 1000+0111 as WHOLE
    //    accesses -- the shapes the old rule was circular on.
    // ============================================================
    begin : ws_cpu
      integer b, a, kind, aa;
      cidx = 0;
      for (b = 1; b < 16; b = b + 1) begin
        for (a = 0; a < 4; a = a + 1) begin
          seed_win(cidx);
          cfg(16'hFFF0 - (1 << a), 16'h00FF, 16'h0000, 16'h0000,
              (a == 0) ? 16'hFFFF : 16'h5555 * a[0] + 16'h0F0F * (1 - a[0]), 16'h0000,
              16'h0000, 16'h000F);
          if ((b == 5) || (b == 9) || (b == 10) || (b == 11) || (b == 13)) begin
            // A synthetic hole set: a pin of the lane walk against itself, not a
            // conformance case (no x86 shape generates this byte-enable set).
            egc_op(cidx, "ws_cpu be PIN synthetic", 1'b0, 2'd0, win_base(cidx) + 4,
                   32'hA1B2_C3D4, b[3:0], 1'b1);
            pin_cases = pin_cases + 1;
          end else begin
            egc_op(cidx, "ws_cpu be", 1'b0, 2'd0, win_base(cidx) + 4, 32'hA1B2_C3D4, b[3:0], 1'b1);
          end
          cmp_win(cidx, "ws_cpu be");
          cidx = cidx + 1;
        end
      end
      // The occurring x86 shapes as their LOGICAL accesses (gold = memegc dispatch
      // verbatim, DUT = the z486 beat split): byte at each lane, aligned/misaligned
      // words and crossing words at aa=3 (1000+0001), aligned dwords and the crossing
      // dword at aa=2 (1100+0011), and the unaligned dwords at aa=1 (1110+0001) and
      // aa=3 (1000+0111). One window per shape per plane-enable/mask config.
      for (a = 0; a < 4; a = a + 1) begin
        for (kind = 0; kind <= 2; kind = kind + 1) begin
          for (aa = 0; aa < 4; aa = aa + 1) begin
            // A byte at aa=3 needs no pair; the sweep above already covered the lone
            // single-beat sets -- these cases are about the DISPATCH split, so all run.
            seed_win(cidx);
            cfg(16'hFFF0 - (1 << a), 16'h00FF, 16'h0000, 16'h0000,
                (a == 0) ? 16'hFFFF : 16'h5555 * a[0] + 16'h0F0F * (1 - a[0]), 16'h0000,
                16'h0000, 16'h000F);
            shape_op(cidx, "ws_cpu shape", kind, aa, 32'hA1B2_C3D4);
            cmp_win(cidx, "ws_cpu shape");
            cidx = cidx + 1;
          end
        end
      end
      // The mask register (0x4A8), full and partial, at a dword write.
      for (m = 0; m < 8; m = m + 1) begin
        seed_win(cidx);
        case (m)
          0: cfgs[0] = 16'hFFFF; 1: cfgs[0] = 16'h0000; 2: cfgs[0] = 16'h5555;
          3: cfgs[0] = 16'hAAAA; 4: cfgs[0] = 16'h0F0F; 5: cfgs[0] = 16'hF0F0;
          6: cfgs[0] = 16'h00FF; default: cfgs[0] = 16'hFF00;
        endcase
        cfg(16'hFFF0, 16'h00FF, 16'h0000, 16'h0000, cfgs[0], 16'h0000, 16'h0000, 16'h000F);
        egc_op(cidx, "ws_cpu mask", 1'b0, 2'd0, win_base(cidx) + 4, 32'h96A5_3C4B, 4'hF, 1'b1);
        cmp_win(cidx, "ws_cpu mask");
        cidx = cidx + 1;
      end
      $display("NOTE egc_conf: section 1 WS_CPU - %0d cases (%0d synthetic-be pins excluded from the conformance count)", cidx, pin_cases);
    end

    // ============================================================
    // 2. WS_ROP (ope 0x0C00 | rop): all 256 ROP codes, SHIFT_CPU feeding the
    //    shifter from the CPU word, the colour quad as the pattern term and the
    //    seeded destination as the dst term, so pat, src and dst are independent.
    // ============================================================
    begin : ws_rop
      integer base;
      base = 0;
      for (rop = 0; rop < 256; rop = rop + 1) begin
        seed_win(rop);
        cfg(16'hFFF0, 16'h40FF, 16'h0C00 | rop[15:0], 16'h0005, 16'hFFFF, 16'h0000,
            16'h0000, 16'h000F);
        egc_op(rop, "rop w", 1'b0, 2'd0, win_base(rop) + 4, 32'h5A96_C33C, 4'hF, 1'b1);
        cmp_win(rop, "rop w");
      end
      base = 256;
      // The same 256 codes as a 16-bit unit on lanes 2:3, which is where the games put them.
      for (rop = 0; rop < 256; rop = rop + 1) begin
        seed_win(base + rop);
        cfg(16'hFFF0, 16'h40FF, 16'h0C00 | rop[15:0], 16'h000A, 16'hFFFF, 16'h0000,
            16'h0000, 16'h000F);
        egc_op(base + rop, "rop hw", 1'b0, 2'd0, win_base(base + rop) + 4, 32'h0000_C33C,
               4'b1100, 1'b1);
        cmp_win(base + rop, "rop hw");
      end
      $display("NOTE egc_conf: section 2 WS_ROP - 512 cases");
    end

    // ============================================================
    // 3. WS_PATREG (ope 0x1000/0x1400/0x2000/0x3100): the colour quads and the
    //    pattern register, all widths, both colour selects and the fgbg = 0 case.
    // ============================================================
    begin : ws_patreg
      integer b;
      for (b = 0; b < 12; b = b + 1) begin
        seed_win(1024 + b);
        cfg(16'hFFF0,
            (b[1:0] == 0) ? 16'h40FF : (b[1:0] == 1) ? 16'h20FF :
            (b[1:0] == 2) ? 16'h60FF : 16'h00FF,
            (b[2]) ? 16'h1400 : 16'h1000,
            (b[3]) ? 16'h000A : 16'h0005, 16'hFFFF, 16'h0009, 16'h0000, 16'h000F);
        case (b)
          0, 1, 2, 3:  egc_op(1024 + b, "patreg w", 1'b0, 2'd0, win_base(1024 + b) + 4,
                              32'hFFFF_FFFF, 4'hF, 1'b1);
          4, 5, 6, 7:  egc_op(1024 + b, "patreg hw", 1'b0, 2'd0, win_base(1024 + b) + 4,
                              32'h0000_FFFF, 4'b0011, 1'b1);
          default:     egc_op(1024 + b, "patreg b", 1'b0, 2'd0, win_base(1024 + b) + 4,
                              32'h0000_00FF, b[3] ? 4'b0100 : 4'b0001, 1'b1);
        endcase
        cmp_win(1024 + b, "patreg");
      end
      $display("NOTE egc_conf: section 3 WS_PATREG - 12 cases");
    end

    // ============================================================
    // 4. The 0x3100 page copy: read the source page (which latches the pattern
    //    register from the source, COMPAREREAD returns the window plane), then
    //    write the destination page. Word and dword, several masks.
    // ============================================================
    begin : copy_3100
      integer b, k, w;
      reg [31:0] r;
      for (b = 0; b < 8; b = b + 1) begin
        seed_win(2048 + b);
        cfg(16'hFFF0, 16'h00FF, 16'h3100, 16'h0000,
            (b[0]) ? 16'hFFFF : ((b[1]) ? 16'h00FF : 16'hF0F0), 16'h0000,
            16'h0000, 16'h000F);
        // Read the source on page 1 at the window's third dword, in the width under test.
        if (b[2]) begin
          egc_op(2048 + b, "3100 rd", 1'b1, 2'd0, win_base(2048 + b) + 4, 32'd0, 4'hF, 1'b0);
        end else begin
          egc_op(2048 + b, "3100 rd", 1'b1, 2'd0, win_base(2048 + b) + 4, 32'd0, 4'b0011, 1'b0);
        end
        // Store at the same offset on page 0, the same width.
        if (b[2]) egc_op(2048 + b, "3100 wr", 1'b0, 2'd0, win_base(2048 + b) + 4,
                         32'h1122_3344, 4'hF, 1'b1);
        else      egc_op(2048 + b, "3100 wr", 1'b0, 2'd0, win_base(2048 + b) + 4,
                         32'h0000_3344, 4'b0011, 1'b1);
        cmp_win(2048 + b, "3100");
      end
      $display("NOTE egc_conf: section 4 0x3100 copy - 8 cases");
    end

    // ============================================================
    // 5. THE READ MODES. COMPAREREAD returns the addressed window plane
    //    (memegc.c egc_readword `return(LOADINTELWORD(mem + addr))`); SHIFT_CPU
    //    returns the read plane's memory (`mem[ad + planead[pl]]`, pl = fgbg[9:8]);
    //    the plain read returns the shifter's read plane. All four read planes are
    //    checked against the same window.
    // ============================================================
    begin : read_modes
      integer rp, mode, wi;
      wi = 3072;
      for (rp = 0; rp < 4; rp = rp + 1) begin
        for (mode = 0; mode < 4; mode = mode + 1) begin
          seed_win(wi);
          cfg(16'hFFF0, {6'd0, rp[1:0], 16'h00FF}, (mode == 1) ? 16'h2000 :
              (mode == 2) ? 16'h0400 : (mode == 3) ? 16'h2400 : 16'h0000,
              16'h0000, 16'hFFFF, 16'h0000, 16'h0000, 16'h000F);
          egc_op(wi, "read mode", 1'b0, 2'd0, win_base(wi) + 4, 32'd0, 4'hF, 1'b0);
          egc_op(wi, "read mode b", 1'b0, 2'd0, win_base(wi) + 4, 32'd0, 4'b0010, 1'b0);
          wi = wi + 1;
        end
        $display("NOTE egc_conf: read plane %0d done", rp);
      end
      $display("NOTE egc_conf: section 5 read modes - %0d cases", wi - 3072);
    end

    // ============================================================
    // 6. THE SHIFTER. A read with SHIFT_CPU clear feeds the source quad and returns
    //    the shifted output (egc_readword), and a 0x0CF0 ROP F0 write feeds the CPU
    //    word through the same shifter (EGCOPE_SHIFTW, gated by SHIFT_CPU). Each
    //    config is a stream of 8 word reads (2 per dword) on the source page, then a
    //    fresh arm and a stream of 4 dword writes on the destination; every read datum
    //    and the whole destination window are compared. sft 0 and the byte-bit addresses
    //    8 (srcbit/dstbit) and the moved cases, in both directions, with leng 8/16/64.
    // ============================================================
    begin : shift
      integer s, k;
      reg [15:0] ss [0:13];
      reg [15:0] sl [0:13];
      ss[ 0]=16'h0000; sl[ 0]=16'h000F;
      ss[ 1]=16'h0000; sl[ 1]=16'h0007;
      ss[ 2]=16'h0000; sl[ 2]=16'h003F;
      ss[ 3]=16'h0002; sl[ 3]=16'h000F;
      ss[ 4]=16'h0002; sl[ 4]=16'h003F;
      ss[ 5]=16'h0002; sl[ 5]=16'h0007;
      ss[ 6]=16'h000A; sl[ 6]=16'h001F;
      ss[ 7]=16'h1000; sl[ 7]=16'h000F;
      ss[ 8]=16'h1000; sl[ 8]=16'h003F;
      ss[ 9]=16'h1002; sl[ 9]=16'h000F;
      ss[10]=16'h1002; sl[10]=16'h003F;
      ss[11]=16'h1002; sl[11]=16'h0007;
      ss[12]=16'h100A; sl[12]=16'h001F;
      ss[13]=16'h100A; sl[13]=16'h003F;
      for (s = 0; s < 14; s = s + 1) begin
        seed_win(1024 + s);
        cfg(16'hFFF0, 16'h00FF, 16'h0000, 16'h0000, 16'hFFFF, 16'h0000, ss[s], sl[s]);
        for (k = 0; k < 4; k = k + 1) begin
          egc_op(1024 + s, "shift rd lo", 1'b1, 2'd0, win_base(1024 + s) + 4*k,
                 32'd0, 4'b0011, 1'b0);
          egc_op(1024 + s, "shift rd hi", 1'b1, 2'd0, win_base(1024 + s) + 4*k,
                 32'd0, 4'b1100, 1'b0);
        end
        cfg(16'hFFF0, 16'h00FF, 16'h0CF0, 16'h0000, 16'hFFFF, 16'h0000, ss[s], sl[s]);
        for (k = 0; k < 4; k = k + 1)
          egc_op(1024 + s, "shift wr", 1'b0, 2'd0, win_base(1024 + s) + 4*k,
                 32'h9E3B_71C4, 4'hF, 1'b1);
        cmp_win(1024 + s, "shift");
      end
      $display("NOTE egc_conf: section 6 the shifter - 14 cases");
    end

    // ============================================================
    // 7. THE ROP WRITE MODES 0x0800 and 0x0B00, with SHIFT_CPU CLEAR: the shifter is
    //    armed by a source READ and never fed again, so the ROP's source is the
    //    shifter's STALE output -- the shape that exposed the byte-PATREG feed. 0x0B00
    //    is the same path (its bits 8:9 match neither egc.c's 0x0100 nor 0x0200). The
    //    ROP table's classes are all 16 codes.
    // ============================================================
    begin : rop_stale
      integer r, c;
      reg [15:0] rp16 [0:15];
      rp16[ 0]=16'h00; rp16[ 1]=16'h0F; rp16[ 2]=16'hF0; rp16[ 3]=16'hFF;
      rp16[ 4]=16'hC0; rp16[ 5]=16'hFC; rp16[ 6]=16'h33; rp16[ 7]=16'h3C;
      rp16[ 8]=16'hC3; rp16[ 9]=16'hF3; rp16[10]=16'h05; rp16[11]=16'h0A;
      rp16[12]=16'h55; rp16[13]=16'hF5; rp16[14]=16'h5A; rp16[15]=16'hAA;
      for (r = 0; r < 256; r = r + 1) begin
        seed_win(512 + r);
        cfg(16'hFFF0, 16'h00FF, 16'h0000, 16'h0005, 16'hFFFF, 16'h0000,
            16'h0000, 16'h000F);
        egc_op(512 + r, "rop src rd", 1'b1, 2'd0, win_base(512 + r) + 4, 32'd0, 4'hF, 1'b0);
        cfg(16'hFFF0, 16'h40FF, 16'h0B00 | r[15:0], 16'h0005, 16'hFFFF, 16'h0000,
            16'h0000, 16'h000F);
        egc_op(512 + r, "rop 0b00", 1'b0, 2'd0, win_base(512 + r) + 4, 32'h5A96_C33C,
               4'hF, 1'b1);
        cmp_win(512 + r, "rop 0b00");
      end
      for (c = 0; c < 16; c = c + 1) begin
        seed_win(768 + c);
        cfg(16'hFFF0, 16'h00FF, 16'h0000, 16'h0005, 16'hFFFF, 16'h0000,
            16'h0000, 16'h000F);
        egc_op(768 + c, "rop src rd", 1'b1, 2'd0, win_base(768 + c), 32'd0, 4'hF, 1'b0);
        cfg(16'hFFF0, 16'h40FF, 16'h0800 | rp16[c], 16'h0005, 16'hFFFF, 16'h0000,
            16'h0000, 16'h000F);
        egc_op(768 + c, "rop 0800", 1'b0, 2'd0, win_base(768 + c), 32'h5A96_C33C,
               4'hF, 1'b1);
        cmp_win(768 + c, "rop 0800");
      end
      $display("NOTE egc_conf: section 7 ROP 0x0800/0x0B00 (stale src) - 272 cases");
    end

    // ============================================================
    // 8. ALL FOUR WINDOW PLANES, the plane-enable register, and the posted-write then
    //    same-word read. The 0x3100 read latches the pattern register from the addressed
    //    (window) plane, the write stores it, and the third access READS THE JUST-WRITTEN
    //    WORD back through the EGC (COMPAREREAD returns the addressed plane): the posted
    //    write's data must be visible to that read.
    // ============================================================
    begin : planes
      integer wp, b2;
      for (wp = 0; wp < 4; wp = wp + 1) begin
        for (b2 = 0; b2 < 4; b2 = b2 + 1) begin
          seed_win(1280 + wp*4 + b2);
          cfg(16'hFFF0, 16'h00FF, 16'h3100, 16'h0000,
              (b2[0]) ? 16'hFFFF : ((b2[1]) ? 16'h00FF : 16'hF0F0), 16'h0000,
              16'h0000, 16'h000F);
          egc_op(1280 + wp*4 + b2, "3100 wp rd", 1'b1, wp[1:0],
                 win_base(1280 + wp*4 + b2) + 4, 32'd0, 4'hF, 1'b0);
          egc_op(1280 + wp*4 + b2, "3100 wp wr", 1'b0, wp[1:0],
                 win_base(1280 + wp*4 + b2) + 4, 32'h1122_3344, 4'hF, 1'b1);
          egc_op(1280 + wp*4 + b2, "same-word rd", 1'b0, wp[1:0],
                 win_base(1280 + wp*4 + b2) + 4, 32'd0, 4'hF, 1'b0);
          cmp_win(1280 + wp*4 + b2, "wp");
        end
      end
      $display("NOTE egc_conf: section 8 window planes + same-word read - 16 cases");
    end

    // ============================================================
    // 9. THE MISALIGNED 16-BIT SPLIT. NP2kai's memegc_wr16/rd16 at
    //    an ODD address is two byte operations, and with sft bit 12 (descending) set
    //    they run HIGH-byte-first (memegc.c:1379-1413): the two source bytes enter the
    //    ring in REVERSE order. be = 0110 is exactly that misaligned word on this bus
    //    (z486's calc_be), so both feeding modes - the SHIFT_CPU-clear READ feed and
    //    the 0x0CF0 SHIFT_CPU write feed - are run at sft 0x0002/0x000A (ascending) and
    //    0x1002/0x100A (descending). The gold's op() splits the pair per memegc_wr16/
    //    rd16's direction order, not in lane order, so a lane-order walk shows up here.
    // ============================================================
    begin : odd_split
      integer s, k;
      reg [15:0] ss [0:3];
      reg [15:0] sl [0:3];
      ss[0]=16'h0002; sl[0]=16'h000F;
      ss[1]=16'h000A; sl[1]=16'h003F;
      ss[2]=16'h1002; sl[2]=16'h000F;
      ss[3]=16'h100A; sl[3]=16'h003F;
      for (s = 0; s < 4; s = s + 1) begin
        // The read feed: four misaligned word reads on the source page feeding the
        // shifter, then a dword store draining the stream to the destination. `off` is
        // the DWORD base (section 1's convention); be = 0110 is the misaligned word at
        // base+1, lanes 1:2.
        seed_win(2560 + s);
        cfg(16'hFFF0, 16'h00FF, 16'h0000, 16'h0000, 16'hFFFF, 16'h0000, ss[s], sl[s]);
        for (k = 0; k < 4; k = k + 1)
          egc_op(2560 + s, "odd rd feed", 1'b1, 2'd0, win_base(2560 + s) + 4 * k,
                 32'd0, 4'b0110, 1'b0);
        egc_op(2560 + s, "odd blit wr", 1'b0, 2'd0, win_base(2560 + s) + 4,
               32'h9E3B_71C4, 4'hF, 1'b1);
        cmp_win(2560 + s, "odd read feed");
        // The write feed: four misaligned word stores in the 0x0CF0 form.
        seed_win(2568 + s);
        cfg(16'hFFF0, 16'h00FF, 16'h0CF0, 16'h0000, 16'hFFFF, 16'h0000, ss[s], sl[s]);
        for (k = 0; k < 4; k = k + 1)
          egc_op(2568 + s, "odd wr feed", 1'b0, 2'd0, win_base(2568 + s) + 4 * k,
                 32'hC33C_5A69, 4'b0110, 1'b1);
        cmp_win(2568 + s, "odd write feed");
        // Single-byte feeds: a descending byte unit's produce must read the ring at the
        // FIRST step's position (egcsftb_dnl_sub moves outptr first, memegc.c:331-369),
        // the same path without the odd split. Four single-byte ops over ONE dword's
        // four lanes (section 1's convention: off is the dword base, the lane is be).
        seed_win(2576 + s);
        cfg(16'hFFF0, 16'h00FF, 16'h0000, 16'h0000, 16'hFFFF, 16'h0000, ss[s], sl[s]);
        egc_op(2576 + s, "byte rd feed", 1'b1, 2'd0, win_base(2576 + s),
               32'd0, 4'b0001, 1'b0);
        egc_op(2576 + s, "byte rd feed", 1'b1, 2'd0, win_base(2576 + s),
               32'd0, 4'b0010, 1'b0);
        egc_op(2576 + s, "byte rd feed", 1'b1, 2'd0, win_base(2576 + s),
               32'd0, 4'b0100, 1'b0);
        egc_op(2576 + s, "byte rd feed", 1'b1, 2'd0, win_base(2576 + s),
               32'd0, 4'b1000, 1'b0);
        egc_op(2576 + s, "byte blit wr", 1'b0, 2'd0, win_base(2576 + s) + 4,
               32'h9E3B_71C4, 4'hF, 1'b1);
        cmp_win(2576 + s, "byte read feed");
      end
      $display("NOTE egc_conf: section 9 misaligned word split + byte produce - 12 cases");
    end

    // ============================================================
    // 10. THE 3-BYTE UNALIGNED BEATS IN A FEEDING MODE. The z486
    //     splits a dword at addr 1 / addr 3 into the beat pairs 1110+0001 / 1000+0111
    //     (z486_pkg.sv:1226 calc_be_first / :1242 calc_be_second); NP2kai decomposes
    //     the SAME logical access into FOUR byte operations - memegc_wr32 is two
    //     memegc_wr16s (memegc.c:1421-1424), both at odd addresses, each two byte ops
    //     (memegc.c:1397-1413). Merging the even lane pair of a 3-byte beat into ONE
    //     word unit diverges wherever the bit length re-arms between the two lanes: at
    //     ope 0x1400 (WS_PATREG|SHIFT_CPU), fgbg 0x0000, sft 0x0000, leng 0x000F
    //     NP2kai's second byte op ends with remain = 0 and egcshift() re-arms
    //     (memegc.c:372-381), so bytes 3-4 produce under a fresh srcmask 0xFFFF and all
    //     four bytes are written; the merged word produce runs egcsftw's skip-high rule
    //     (produce_hi false when pr_remain_1 == 0, mirroring memegc.c:397-401) and
    //     leaves the high lane unwritten. The gold takes the logical op32 dispatch
    //     verbatim and the DUT the beat pair (shape_op's split), so every case here is
    //     DUT vs memegc_wr32. Expected FAIL on the merged walk. ope 0x0B00 (the WS_ROP
    //     stale-src form) is driven beside 0x1400.
    // ============================================================
    begin : beat3_feeding
      integer a, c;
      reg [15:0] oos [0:1];
      oos[0] = 16'h1400;   // WS_PATREG | SHIFT_CPU: the byte path feeds from the CPU
      oos[1] = 16'h0B00;   // WS_ROP | 0x0300: the stale-src ROP form (feeds only with bit 10)
      for (c = 0; c < 2; c = c + 1)
        for (a = 0; a < 2; a = a + 1) begin
          seed_win(3840 + c*2 + a);
          cfg(16'hFFF0, 16'h00FF, oos[c], 16'h0000, 16'hFFFF, 16'h0000,
              16'h0000, 16'h000F);
          shape_op(3840 + c*2 + a, "f1 beat3", 2, (a == 0) ? 1 : 3, 32'h9E3B_71C4);
          cmp_win(3840 + c*2 + a, "f1 beat3");
        end
      $display("NOTE egc_conf: section 10 3-byte beats in feeding modes - 4 cases");
    end

    // ============================================================
    // 11. THE STACK-GATED FEED'S RING WRITE. NP2kai's EGCOPE_SHIFTB/
    //     SHIFTW write the feed data at egc.inptr BEFORE shiftinput_* runs
    //     (memegc.c:639-706); only the pointer/stack/srcbit updates sit behind
    //     `if (egc.stack <= 16)` (memegc.c:590-637). The pre-fix RTL dropped the ring
    //     write itself on a gated feed (feed_commit && feed_gate), so the frozen inptr
    //     slot keeps whatever was there instead of the feed's data (last writer wins).
    //     The gate IS reachable: at sft 0x0090 (dstbit 9, srcbit 0) NP2kai's byte
    //     produce gate `stack < (UINT)(8 - dstbit)` wraps to a huge unsigned and every
    //     produce stays gated (memegc.c:385-390), so each byte feed adds its 8 bits and
    //     the FOURTH feed sees stack 24 > 16 and is gated.
    //     The dropped write is NOT CPU-observable: a produce can only read the frozen
    //     slot once the write trail has re-opened and overwritten it (the stack counts
    //     the unread bytes, so the trail re-opens before the read trail catches up),
    //     which is why this check reads the ring ITSELF - row 3 (the frozen inptr) must
    //     hold the last gated feed's byte exactly as gold.ebuf does.
    // ============================================================
    begin : gated_feed
      integer k, p;
      reg [31:0] dw;
      reg [7:0]  want;
      // (a) a DETERMINISTIC stale: four byte feeds at sft 0x0000 (the gate stays open;
      //     leng 0x03FF so no re-arm moves the pointers) fill ring rows 0-3 with
      //     0x30..0x33 in both models.
      seed_win(3904);
      cfg(16'hFFF0, 16'h00FF, 16'h1400, 16'h0000, 16'hFFFF, 16'h0000,
          16'h0000, 16'h03FF);
      for (k = 0; k < 4; k = k + 1)
        egc_op(3904, "f2 stale fill", 1'b0, 2'd0, win_base(3904) + 4,
               (32'h0000_0030 + k[31:0]) << (8*k), 4'b0001 << k, 1'b1);
      // (b) the gated feeds: rows 0-2 take 0xE0..0xE2 from the un-gated feeds, and the
      //     gated feeds leave 0xE6 - the LAST writer - at row 3 in NP2kai (memegc.c
      //     :639-645 writes before the :590-608 gate). The pre-fix RTL leaves the
      //     0x33 stale from (a).
      cfg(16'hFFF0, 16'h00FF, 16'h1400, 16'h0000, 16'hFFFF, 16'h0000,
          16'h0090, 16'h000F);
      for (k = 0; k < 7; k = k + 1)
        egc_op(3904, "f2 gated feed", 1'b0, 2'd0, win_base(3904) + 4,
               32'h0000_00E0 + k[31:0], 4'b0001, 1'b1);
      cmp_win(3904, "f2 gated feed");
      want = 8'hE6;
      for (p = 0; p < 4; p = p + 1) begin
        if (gold.ebuf[3 + 4*p] !== want) begin
          $display("FAIL f2 ring p%0d: gold row 3 = %02x want %02x (the gold dropped the gated feed)",
                   p, gold.ebuf[3 + 4*p], want);
          errors = errors + 1;
        end
        dw = dut.u_egc.u_ebuf_o.ram[1];
        if (dw[8*p +: 8] !== want) begin
          $display("FAIL f2 ring p%0d: DUT row 3 = %02x want %02x (a stack-gated feed must still write the frozen inptr, memegc.c:639-645)",
                   p, dw[8*p +: 8], want);
          errors = errors + 1;
        end
      end
      $display("NOTE egc_conf: section 11 stack-gated feed ring write - 11 cases");
    end

    // ==== VERDICT ====
    $display("NOTE egc_conf: %0d differential cases (%0d conformance + %0d synthetic-be self-consistency pin), %0d errors",
             cases, cases - pin_cases, pin_cases, errors);
    if (errors == 0) begin
      $display("TB_PC9821_EGC_CONFORMANCE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_EGC_CONFORMANCE: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_EGC_CONFORMANCE: FAIL");
    end
  end

  // In-bench watchdog.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_EGC_CONFORMANCE: TIMEOUT");
  end

endmodule

`default_nettype wire
