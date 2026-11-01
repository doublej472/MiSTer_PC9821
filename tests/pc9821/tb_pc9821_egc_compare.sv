`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_COMPARE: the EGC's COMPARE / colour-key path replayed against REAL PC-9821 (V166) hardware - the PC98_EGC_CONFORMANCE suite v1.3 capture in docs/probes/egc-conformance/ - through the REAL pc9821_egc inside the REAL pc9821_gvram client: 230 word/byte compare vectors, 4 selected-PLOAD_R rows and 21 colour-key WRITE rows (CK00_*_DST / CK01_*_DST, each one the software's own read-mask -> 0x04A8 -> masked-write sequence), each stimulus RECONSTRUCTED from the hardware's own answers by tools/gen_egc_compare_vectors.py and every expectation taken from the Xe10's own aB column, with the reconstructed ramps cross-checked against the suite's own read-back of the plane it compares (CK00_*_SRC) and the shared pattern solved against the FG colour.
//
// The line above is the manifest claim VERBATIM (tools/check_tests.py holds the two
// together). The oracle is the real Xe10, which is the TOP of this repo's evidence
// hierarchy; this core's pre-fix run of the same binaries (mister/) is the baseline that
// says which rows are the gap. The suite is a binary-only distribution - no sources, no
// register listings - so the generator RECONSTRUCTS each covered family's stimulus from the
// expected masks (which fix the stored pattern, the FG colour and the plane-enable mask
// under the compare model), and the reconstruction is checked against independent columns of
// the same capture: the ramp families must reproduce CK00_*_SRC and the plain-read value the
// pre-fix core returns in the MiSTer column, the shared-quad family must solve for one FG
// colour and reproduce all 45 of its rows, and the byte families must give the same solution
// at all four apertures. The generated file is tests/pc9821/egc_xe10_vectors.svh.
//
// THE STIMULUS IS PAT-SOURCE, AND THAT IS MEASURED. Every compare row of the capture is a
// compare with 0x04A2's bits 14-13 at 00: bit 13 is what produces a mask at all (the suite's
// own `04A4-bit13-compare` rows), and this core's pre-fix column for the ramp/mask families
// reads back the addressed PLANE word (5555) rather than the mask, i.e. the core took a
// non-comparing arm - which, with bit 13 set, is the PAT source. So the vectors below drive
// fgbg[14:13] = 00, and the reference colour is still the retained FG whatever those bits say
// (RD21/RD22). That is also RD22_PATSEL's case: `compare-reference-is-retained-FG-not-current-P`
// PASSes on the Xe10 with the retained-FG mask, where a raw return would have to read 4CB3 -
// the value this core produced while it gated the compare on the colour source.
//
// Section 1 (word compare) replays the single-key ramps (B08_CMP_x, RD10_RAMP_x,
// CK00_x_MASK), the shared 16-pixel pattern keyed by all sixteen colours (RD11_MIX_x) and the
// plane-enable "disabled planes are don't care" sweep (RD20_AM_x), plus the
// read-plane-selector- and aperture-independence rows (RD13_RPL_x, RD14_AP_x), the
// compare+PLOAD_R mask (RD17_M_x), the retained-FG row (RD21_BG), the CK01 mask rows (whose
// stored quad and FG colour - A, all four planes compared - are solved from the capture) and
// the two rows whose stimulus the CSV leaves free (RD12_ALL/NONE; the generator names them).
// Section 2 (byte compare) replays RD15_A{a}_{L,H}_K{k}: 128 rows over all four apertures,
// both byte lanes and all sixteen keys - the rows the hardware itself reports as identical
// across apertures. Section 3 (PLOAD_R) replays RD02_PAT_S0..S3: a normal read with
// RL_MEMREAD loads the SELECTED PAT plane only, the other three keeping their retained value.
// Section 4 is the colour-key WRITE: for each of CK00's sixteen keys and CK01's five source
// quads, seed the region, compare-read it (the hardware's own *_MASK column), write that
// byte-exact value into the mask register - the software's `compare-mask-used-as-color-key` -
// then store the data quad the capture solves for with an ordinary masked write and read the
// region back, which must be the hardware's *_DST column.
//
// FAIL-FIRST: on the pre-fix pc9821_egc every section-1 and section-2 vector returns the
// stored plane word instead of the compare mask (the pre-fix resp_word is NP2kai's
// `mem[addr]`, and resp_byte likewise), and section 3's PAT quad takes all four newly read
// planes rather than the selected one. Section 4 fails before the fix for the same reason: the
// mask the software stores into 0x04A8 is the WRONG value (the raw plane), so the write lands
// on the wrong pixels - which is exactly what the capture's own MiSTer column shows (CK00_0's
// pre-fix DST is 0550,3663,5A0F,BE41 = the masked-write result of that raw-plane mask).
//
// The vectors are compared by VALUE only; this bench makes no claim about EGC timing (that is
// tb_pc9821_egc.sv's sections 12-15).

`default_nettype none

module tb_pc9821_egc_compare;
  localparam integer CYCLE_NS = 20;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  // the real EGC inside the real GVRAM client
  reg         access_page = 1'b0;
  reg  [1:0]  win_plane = 2'd0;
  reg [14:0]  win_offset = 15'd0;
  reg [31:0]  cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'hF;
  reg         cpu_line_read = 1'b0;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h0000,
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

  // The generated hardware vectors (see the WHAT THIS PROVES banner).
  /* verilator lint_off UNUSEDPARAM */   // EGCW_* are tb_pc9821_egc_regs' rows, emitted here so
  // the whole hardware capture is regenerated from one source of truth.
  `include "egc_xe10_vectors.svh"
  /* verilator lint_on UNUSEDPARAM */

  integer errors = 0;
  integer cases  = 0;
  integer byte_cases = 0;
  integer ck_cases = 0;

  function [8*16-1:0] id_str(input [127:0] v);
    integer q;
    begin
      for (q = 0; q < 16; q = q + 1)
        id_str[8*q +: 8] = ((v[8*q +: 8] == 8'h00) || (v[8*q +: 8] == 8'h20)) ? 8'h20
                                                                            : v[8*q +: 8];
    end
  endfunction

  // ==== STIMULUS ====
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
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      // `egc_gate` is the machine's EGC arming level (0x6A num 2 AND 0x7C bit 7), not a per-access
      // signal: it is held through the response and released after it.
      // The negedge below is the old release's own wait, kept so the +1 stays in the cadence.
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

  // ---- the register file (the LIVE iobus latches the engine copies at each accept) ----
  // The re-arm pulse is the one io/egc.c's 0x4AC/0x4AE handlers give egcshift().
  task automatic cfg(input [15:0] c_access, c_fgbg, c_ope, c_fg, c_mask, c_bg,
                     input [15:0] c_sft, c_leng);
    begin
      @(negedge clk);
      egc_access = c_access;
      egc_fgbg   = c_fgbg;
      egc_ope    = c_ope;
      egc_fg     = c_fg;
      egc_mask   = c_mask;
      egc_bg     = c_bg;
      egc_sft    = c_sft;
      egc_leng   = c_leng;
      egc_shift_we = 1'b1;
      @(negedge clk);
      egc_shift_we = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic cfg_plain;
    begin
      cfg(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'hFFFF, 16'd0, 16'd0, 16'h000F);
    end
  endtask

  // ---- seed one plane's word at a dword-aligned offset (gate off: the plain window store) ----
  task automatic seed_word(input [14:0] off, input [15:0] b, r, g, e);
    reg [31:0] sink;
    begin
      access_op(1'b0, 2'd0, off, {16'h0000, b}, 4'hF, 1'b1, 1'b0, sink);
      access_op(1'b0, 2'd1, off, {16'h0000, r}, 4'hF, 1'b1, 1'b0, sink);
      access_op(1'b0, 2'd2, off, {16'h0000, g}, 4'hF, 1'b1, 1'b0, sink);
      access_op(1'b0, 2'd3, off, {16'h0000, e}, 4'hF, 1'b1, 1'b0, sink);
      // A plane-window STORE is ACCEPTED and decoupled (pc9821_gvram_arb C_IDLE), so its walk
      // still finishes BEHIND the CPU: the high byte of the word lands on the walk's SECOND lane.
      // Give the walk its cycles before anything reads back, or a read sees the array mid-walk.
      repeat (16) @(posedge clk);
    end
  endtask

  // ---- read one raw plane word back with the gate off ----
  task automatic raw_word(input [1:0] plane, input [14:0] off, output [15:0] d);
    reg [31:0] got;
    begin
      access_op(1'b0, plane, off, 32'd0, 4'b0011, 1'b0, 1'b0, got);
      d = got[15:0];
    end
  endtask

  integer vi;
  integer v_off, v_lane, v_byte, v_access, v_fg, v_exp, v_plane, v_sel;
  reg [15:0] v_db, v_dr, v_dg, v_de;
  reg [31:0] got32;
  reg [15:0] got_w;
  reg [7:0]  got_b;
  reg [127:0] v_id;

  initial begin
    reset = 1;
    repeat (8) @(posedge clk);
    reset = 0;
    repeat (20) @(posedge clk);

    // ==== CHECKS ====
    // Sections 1-2: the compare read, word and byte, over the whole generated vector set ====
    // The vectors live at their own dword-aligned offsets (0x100 word/byte, 0x200 the PLOAD_R
    // source), so one seed per vector is enough.
    for (vi = 0; vi < EGCX_NV; vi = vi + 1) begin
      v_id     = EGCX_V[vi][235:108];
      v_de     = EGCX_V[vi][59:44];
      v_dg     = EGCX_V[vi][75:60];
      v_dr     = EGCX_V[vi][91:76];
      v_db     = EGCX_V[vi][107:92];
      v_exp    = EGCX_V[vi][43:28];
      v_fg     = EGCX_V[vi][27:24];
      v_access = EGCX_V[vi][23:20];
      v_plane  = EGCX_V[vi][19:18];
      v_byte   = EGCX_V[vi][17];
      v_lane   = EGCX_V[vi][16:15];
      v_off    = EGCX_V[vi][14:0];
      seed_word(v_off[14:0], v_db, v_dr, v_dg, v_de);
      // fgbg's bits 9:8 are the read-plane selector (the row's aperture) and bits 14:13 are the
      // colour-register SOURCE. Every compare row of the capture is driven with the source set to
      // PAT (00): bit 13 is what makes a mask at all (`04A4-bit13-compare`), and this core's
      // pre-fix column for these very rows reads the addressed PLANE word back, i.e. the core's
      // non-comparing arm - which with bit 13 set is the PAT source. The reference colour is the
      // retained FG whatever those bits say (RD21/RD22), and bit 13 is the whole gate (RD22_PATSEL).
      cfg(v_access, {6'h00, v_plane[1:0], 6'h00, v_plane[1:0]}, 16'h2000,
          v_fg[3:0], 16'hFFFF, 16'd0, 16'd0, 16'h000F);
      if (v_byte) begin
        access_op(1'b0, v_plane[1:0], v_off[14:0], 32'd0, (4'h1 << v_lane),
                  1'b0, 1'b1, got32);
        got_b = got32[v_lane*8 +: 8];
        if (got_b !== v_exp[7:0]) begin
          $display("FAIL egc_cmp: v%0d id %0s: byte lane %0d mask = %02x, hardware says %02x",
                   vi, id_str(v_id), v_lane, got_b, v_exp[7:0]);
          errors = errors + 1;
        end
        byte_cases = byte_cases + 1;
      end else begin
        access_op(1'b0, v_plane[1:0], v_off[14:0], 32'd0, 4'b0011, 1'b0, 1'b1, got32);
        got_w = got32[15:0];
        if (got_w !== v_exp[15:0]) begin
          $display("FAIL egc_cmp: v%0d id %0s: compare mask = %04x, hardware says %04x",
                   vi, id_str(v_id), got_w, v_exp[15:0]);
          errors = errors + 1;
        end
      end
      cases = cases + 1;
    end
    $display("NOTE egc_cmp: sections 1-2 compare read - %0d hardware vectors (%0d word, %0d byte)",
             cases, cases - byte_cases, byte_cases);

    // ==== Section 3: a normal PLOAD_R read loads the SELECTED PAT plane only ====
    // The retained quad is loaded the way the suite loads a PAT quad: four selected reads. Then
    // ONE read at the second address takes only its selected plane.
    for (vi = 0; vi < 4; vi = vi + 1) begin
      seed_word(15'h0100, EGCX_PAT_RETAINED[0], EGCX_PAT_RETAINED[1],
                EGCX_PAT_RETAINED[2], EGCX_PAT_RETAINED[3]);
      for (v_lane = 0; v_lane < 4; v_lane = v_lane + 1) begin
        cfg(16'hFFF0, {6'h00, v_lane[1:0], 6'h00, v_lane[1:0]}, 16'h0100,
            16'd0, 16'hFFFF, 16'd0, 16'd0, 16'h000F);
        access_op(1'b0, v_lane[1:0], 15'h0100, 32'd0, 4'b0011, 1'b0, 1'b1, got32);
      end
      seed_word(15'h0200, EGCX_PAT_NEW[0], EGCX_PAT_NEW[1], EGCX_PAT_NEW[2], EGCX_PAT_NEW[3]);
      cfg(16'hFFF0, {6'h00, vi[1:0], 6'h00, vi[1:0]}, 16'h0100,
          16'd0, 16'hFFFF, 16'd0, 16'd0, 16'h000F);
      access_op(1'b0, vi[1:0], 15'h0200, 32'd0, 4'b0011, 1'b0, 1'b1, got32);
      // Display the PAT quad: a WS_PATREG store, then a raw read of the four planes.
      cfg(16'hFFF0, 16'h0000, 16'h1000, 16'd0, 16'hFFFF, 16'd0, 16'd0, 16'h000F);
      access_op(1'b0, 2'd0, 15'h0300, 32'h0000_0000, 4'hF, 1'b1, 1'b1, got32);
      for (v_lane = 0; v_lane < 4; v_lane = v_lane + 1) begin
        raw_word(v_lane[1:0], 15'h0300, got_w);
        if (got_w !== EGCX_PAT_EXP[4*vi + v_lane]) begin
          $display("FAIL egc_cmp: RD02_PAT_S%0d plane %0d = %04x, hardware says %04x",
                   vi, v_lane, got_w, EGCX_PAT_EXP[4*vi + v_lane]);
          errors = errors + 1;
        end
      end
      cases = cases + 1;
    end
    $display("NOTE egc_cmp: section 3 selected-PAT PLOAD_R - 4 hardware rows");

    // ==== Section 4: the colour-key WRITE, replayed through its real sequence ====
    // Compare-read the region (the hardware's own MASK column is the expectation), write THAT
    // byte-exact value into 0x04A8 - which is what "compare-mask-used-as-color-key" names - then
    // store the data quad the capture solves for with an ordinary masked write, and read the
    // region back: the hardware's DST column. There is no hardware write overlay behind this; a
    // bit-13 overlay would also have rewritten TH01's 0x3100 copy, which shares the bit, and the
    // pre-fix core's own DST column is the same masked write with ITS (wrong) read value.
    for (vi = 0; vi < EGCK_NV; vi = vi + 1) begin
      v_id     = EGCK_V[vi][286:159];
      v_fg     = EGCK_V[vi][290:287];
      v_db     = EGCK_V[vi][110:95];    // src plane 0
      v_dr     = EGCK_V[vi][126:111];   // src plane 1
      v_dg     = EGCK_V[vi][142:127];   // src plane 2
      v_de     = EGCK_V[vi][158:143];   // src plane 3
      v_exp    = EGCK_V[vi][30:15];     // the hardware's MASK column
      v_off    = EGCK_V[vi][14:0];
      seed_word(v_off[14:0], v_db, v_dr, v_dg, v_de);
      cfg(16'hFFF0, {6'h00, 2'd0, 6'h00, 2'd0}, 16'h2000,
          v_fg[3:0], 16'hFFFF, 16'd0, 16'd0, 16'h000F);
      access_op(1'b0, 2'd0, v_off[14:0], 32'd0, 4'b0011, 1'b0, 1'b1, got32);
      got_w = got32[15:0];
      if (got_w !== v_exp[15:0]) begin
        $display("FAIL egc_cmp: v%0d id %0s: colour-key mask = %04x, hardware says %04x",
                 vi, id_str(v_id), got_w, v_exp[15:0]);
        errors = errors + 1;
      end
      // The software's own next step: the mask BECOMES the colour key (0x04A8). The four plane
      // patterns are then stored one plane at a time, each access enabling ONLY its own plane in
      // 0x04A0 - the EGC writes every ENABLED plane with the same CPU datum, so one access per
      // plane is the only way to give them different data, and it is what the capture's own
      // W12_AMx rows (PLOAD_W under one plane enable at a time) show the suite doing.
      for (v_lane = 0; v_lane < 4; v_lane = v_lane + 1) begin
        cfg(16'hFFF0 | {12'h000, 4'hF & ~(4'h1 << v_lane[1:0])},
            {6'h00, 2'd0, 6'h00, 2'd0}, 16'h0000,
            v_fg[3:0], got_w, 16'd0, 16'd0, 16'h000F);
        access_op(1'b0, v_lane[1:0], v_off[14:0], {16'h0000, EGCK_DATA[v_lane]},
                  4'b0011, 1'b1, 1'b1, got32);
      end
      for (v_lane = 0; v_lane < 4; v_lane = v_lane + 1) begin
        raw_word(v_lane[1:0], v_off[14:0], got_w);
        case (v_lane)
          0: v_exp = EGCK_V[vi][46:31];
          1: v_exp = EGCK_V[vi][62:47];
          2: v_exp = EGCK_V[vi][78:63];
          default: v_exp = EGCK_V[vi][94:79];
        endcase
        if (got_w !== v_exp[15:0]) begin
          $display("FAIL egc_cmp: v%0d id %0s: colour-key DST plane %0d = %04x, hardware says %04x",
                   vi, id_str(v_id), v_lane, got_w, v_exp[15:0]);
          errors = errors + 1;
        end
      end
      cases = cases + 1;
      ck_cases = ck_cases + 1;
    end
    $display("NOTE egc_cmp: section 4 colour-key write - %0d hardware rows (mask, 0x04A8, data, DST)",
             ck_cases);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_EGC_COMPARE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_EGC_COMPARE: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_EGC_COMPARE: FAIL");
    end
  end

  // In-bench watchdog.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_EGC_COMPARE: TIMEOUT");
  end

endmodule
