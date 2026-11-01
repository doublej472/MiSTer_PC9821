`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_MASK_PATTERN:
// The EGC's mask register and its fgbg colour-quad / pattern selection, driven directly at the pc9821_egc D1 port, against NP2kai's egc_writebyte / egc_writeword: the mask register's byte-lane placement on the addressed lane (full, partial and zero masks merged into the destination byte-by-byte), the fgbg&0x6000 fgc/bgc quads expanded per plane from the fg/bg low nibble, the fgbg-selected pattern register as a colour source, and the srcmask NP2kai's EGCOPE_SHIFTW2 / EGCOPE_SHIFTB apply in each of the four fgbg selections and every ope mode.
//
// Sections A-C and F1/F2 pass; D2, E1-E3 and F3 are DEVIATIONS from NP2kai.
// This bench therefore
// FAILs on the current RTL by design.
//
// NOTE the scope: the D1 backend is this bench's own behavioural client (one byte per
// plane per column, exactly pc9821_gvram.sv's contract), not the real SDRAM path.
// The shifter is only ever driven at sft = 0, so every case is a byte-aligned
// transform and NP2kai's egcsftb/egcsftw sub-byte functions are out of scope.

`default_nettype none

module tb_pc9821_egc_mask_pattern;
  `timescale 1ns/1ps
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ---- DUT register file (latched by pc9821_iobus in the machine) ----
  reg [15:0] reg_access = 16'hFFF0;
  reg [15:0] reg_fgbg   = 16'h00FF;
  reg [15:0] reg_ope    = 16'h0000;
  reg [15:0] reg_fg     = 16'h0000;
  reg [15:0] reg_mask   = 16'hFFFF;
  reg [15:0] reg_bg     = 16'h0000;
  reg [15:0] reg_sft    = 16'h0000;
  reg [15:0] reg_leng   = 16'h000F;
  reg        reg_shift_we = 1'b0;

  // ---- CPU access ----
  reg         cpu_page = 1'b0;
  reg [14:0]  cpu_offset = 15'd0;
  reg [1:0]   cpu_plane = 2'd0;
  reg [31:0]  cpu_din = 32'd0;
  reg [3:0]   cpu_be = 4'hF;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;

  // ---- D1 client ----
  wire        cl_valid, cl_write, cl_burst;
  wire [15:0] cl_addr;
  wire [31:0] cl_wdata;
  wire [3:0]  cl_wbe;
  wire [63:0] cl_wdata2;
  reg  [31:0] cl_rdata;
  reg         cl_done;
  reg         cl_ready;

  // ==== DUT ====
  pc9821_egc dut (
      .clk(clk), .reset(reset),
      .reg_access(reg_access), .reg_fgbg(reg_fgbg), .reg_ope(reg_ope),
      .reg_fg(reg_fg), .reg_mask(reg_mask), .reg_bg(reg_bg),
      .reg_sft(reg_sft), .reg_leng(reg_leng), .reg_shift_we(reg_shift_we),
      .cpu_page(cpu_page), .cpu_offset(cpu_offset), .cpu_plane(cpu_plane),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_valid(cpu_valid),
      .cpu_write(cpu_write), .cpu_dout(cpu_dout), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .cl_valid(cl_valid), .cl_ready(cl_ready), .cl_write(cl_write),
      .cl_addr(cl_addr), .cl_wdata(cl_wdata), .cl_wbe(cl_wbe),
      .cl_burst(cl_burst), .cl_wdata2(cl_wdata2),
      .cl_rdata(cl_rdata), .cl_done(cl_done)
  );

  // ==== BEHAVIOURAL GVRAM BACKEND (the D1 client) ====
  // One plane byte per lane per access, addressed by cl_addr = {page, plane byte offset}
  // (pc9821_gvram.sv's D1 contract). Flat array: index plane*32768 + offset.
  localparam integer PLANE_LEN = 32768;
  reg [7:0] pmem [0:4*PLANE_LEN-1];

  reg [14:0] rd_off;
  reg [1:0]  rd_last;
  reg        rd_busy;
  reg [31:0] rd_word;
  reg        cl_done_r;
  reg        wr_pending;   // a single-column write completes with cl_done; a burst does not

  assign cl_ready = !rd_busy;
  assign cl_done  = cl_done_r;
  assign cl_rdata = rd_word;

  function [1:0] last_col(input [3:0] be);
    integer i;
    begin
      last_col = 2'd0;
      for (i = 0; i < 4; i = i + 1) if (be[i]) last_col = i[1:0];
    end
  endfunction

  always @(posedge clk) begin
    cl_done_r <= 1'b0;
    if (reset) begin
      rd_busy <= 1'b0; rd_off <= 15'd0; rd_last <= 2'd0; rd_word <= 32'd0;
      wr_pending <= 1'b0;
    end else begin
      if (cl_valid && cl_ready) begin
        if (cl_write) begin
          for (integer q = 0; q < 4; q = q + 1) begin
            if (cl_wbe[q])
              pmem[q*PLANE_LEN + cl_addr[14:0]] <= cl_wdata[{q, 3'b000} +: 8];
            // A burst carries word 0 on cl_wdata and word 1 on cl_wdata2's HIGH half
            // (wb_data2 = {higher column, cl_wdata}); both are full-word writes.
            if (cl_burst && cl_wbe[q])
              pmem[q*PLANE_LEN + cl_addr[14:0] + 1] <= cl_wdata2[32 + {q, 3'b000} +: 8];
          end
          // S_WR_ACC waits for cl_done; S_WR_B_ACC advances on the accept alone.
          wr_pending <= !cl_burst;
        end else begin
          rd_off  <= cl_addr[14:0];
          rd_last <= last_col(cl_wbe);
          rd_busy <= 1'b1;
        end
      end else if (rd_busy) begin
        rd_word  <= {pmem[3*PLANE_LEN + rd_off], pmem[2*PLANE_LEN + rd_off],
                     pmem[1*PLANE_LEN + rd_off], pmem[0*PLANE_LEN + rd_off]};
        cl_done_r <= 1'b1;
        if (rd_off[1:0] == rd_last) rd_busy <= 1'b0;
        else rd_off <= rd_off + 1'b1;
      end
      if (wr_pending) begin
        cl_done_r <= 1'b1;
        wr_pending <= 1'b0;
      end
    end
  end

  // ==== CHECK BOOKKEEPING ====
  integer mismatches = 0;
  integer cases = 0;

  task automatic chk(input [8*48-1:0] name, input integer p, input integer off, input [7:0] exp);
    begin
      cases = cases + 1;
      if (pmem[p*PLANE_LEN + off] !== exp) begin
        $display("MISMATCH %0s: plane %0d off 0x%03x = 0x%02x, NP2kai = 0x%02x",
                 name, p, off, pmem[p*PLANE_LEN + off], exp);
        mismatches = mismatches + 1;
      end else begin
        $display("ok       %0s: plane %0d off 0x%03x = 0x%02x", name, p, off, exp);
      end
    end
  endtask

  task automatic preload(input integer off, input [7:0] v);
    integer p, q;
    begin
      for (p = 0; p < 4; p = p + 1)
        for (q = 0; q < 4; q = q + 1) pmem[p*PLANE_LEN + off + q] = v;
    end
  endtask

  task automatic poke(input integer p, input integer off, input [7:0] v);
    begin
      pmem[p*PLANE_LEN + off] = v;
    end
  endtask

  // ==== STIMULUS ====
  // A clean module state plus the arm the guest's 0x4AC/0x4AE write would give (NP2kai
  // egcshift + `srcmask = 0xFFFF`).
  task automatic begin_case(input [15:0] access, input [15:0] fgbg, input [15:0] ope,
                            input [15:0] fg, input [15:0] bg, input [15:0] mask,
                            input [15:0] sft, input [15:0] leng);
    begin
      reset = 1'b1; reg_shift_we = 1'b0;
      reg_access = access; reg_fgbg = fgbg; reg_ope = ope;
      reg_fg = fg; reg_bg = bg; reg_mask = mask;
      reg_sft = 16'd0; reg_leng = 16'h000F;
      repeat (3) @(posedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
      @(negedge clk);
      reg_sft = sft; reg_leng = leng; reg_shift_we = 1'b1;
      @(negedge clk);
      reg_shift_we = 1'b0;
    end
  endtask

  task automatic set_ope_fgbg(input [15:0] ope, input [15:0] fgbg);
    begin
      @(negedge clk);
      reg_ope = ope; reg_fgbg = fgbg;
    end
  endtask

  task automatic cpu_do(input [14:0] off, input [1:0] plane, input [31:0] din,
                        input [3:0] be, input wr, output [31:0] dout);
    begin
      @(negedge clk);
      cpu_offset = off; cpu_plane = plane; cpu_din = din; cpu_be = be;
      cpu_write = wr; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      // The negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'h0;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end
      @(negedge clk);
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic byte_write(input [14:0] off, input [1:0] lane, input [7:0] data);
    reg [31:0] dummy;
    begin
      cpu_do(off, 2'd0, {24'd0, data} << {lane, 3'b000}, 4'b0001 << lane, 1'b1, dummy);
    end
  endtask

  task automatic word_write(input [31:0] din, input [3:0] be, input [14:0] off);
    reg [31:0] dummy;
    begin
      cpu_do(off, 2'd0, din, be, 1'b1, dummy);
    end
  endtask

  task automatic word_read(input [14:0] off, input [1:0] plane, input [3:0] be);
    reg [31:0] dummy;
    begin
      cpu_do(off, plane, 32'd0, be, 1'b0, dummy);
    end
  endtask

  // ==== CHECKS ====
  integer p;
  initial begin : run
    for (integer k = 0; k < 4*PLANE_LEN; k = k + 1) pmem[k] = 8'h00;

    // ============================================================
    // A. The MASK register: full, partial, none and the odd lane.
    //    NP2kai egc_writebyte (mem/memegc.c): the DEFAULT ope (ope&0x1800==0)
    //    makes the data quad the CPU byte replicated and sets `mask2 = egc.mask` (NOT ANDed
    //    with srcmask), then each enabled plane does
    //      mem = (mem & ~mask2._b[addr&1]) | (data & mask2._b[addr&1]).
    //    So the mask is a bitwise merge and its byte is the one ADDRESSED (addr&1).
    // ============================================================
    // A1: lane 0 (ext 0), mask 0xFFFF
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd0, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("A1 mask-FFFF lane0", p, 15'h0000, 8'hA5);

    // A2: lane 0, mask 0x00FF (low byte full)
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'h00FF, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd0, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("A2 mask-00FF lane0", p, 15'h0000, 8'hA5);

    // A3: lane 0, mask 0x0000 (nothing written)
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'h0000, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd0, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("A3 mask-0000 lane0", p, 15'h0000, 8'h11);

    // A4: ODD lane 1 (ext 1), mask 0xFF00 (high byte full)
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'hFF00, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd1, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("A4 mask-FF00 lane1", p, 15'h0001, 8'hA5);

    // A5: ODD lane 1, mask 0x00FF -- the byte at ext=1 is zero, so nothing is written.
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'h00FF, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd1, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("A5 mask-00FF lane1", p, 15'h0001, 8'h11);

    // A6: lane 0, nibble mask 0x000F -> (0xA5 & 0x0F) | (0x11 & 0xF0) = 0x15
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'h000F, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd0, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("A6 mask-000F lane0", p, 15'h0000, 8'h15);

    // A7: ODD lane 3 (ext 1), nibble mask 0x0F00 -> high mask byte 0x0F -> 0x15
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'h0F00, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd3, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("A7 mask-0F00 lane3", p, 15'h0003, 8'h15);

    // A8: the active-low plane mask: access bit 1 set disables plane 1 only.
    begin_case(16'hFFF2, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    preload(15'h0000, 8'h11);
    byte_write(15'h0000, 2'd0, 8'hA5);
    chk("A8 plane0 enabled",  0, 15'h0000, 8'hA5);
    chk("A8 plane1 disabled", 1, 15'h0000, 8'h11);
    chk("A8 plane2 enabled",  2, 15'h0000, 8'hA5);
    chk("A8 plane3 enabled",  3, 15'h0000, 8'hA5);

    // ============================================================
    // B. The fgbg COLOUR QUADS, word path (ope&0x1800==0x1000, WS_PATREG). NP2kai
    //    egc_opew (mem/memegc.c) case 0x1000 returns egc.bgc for fgbg&0x6000
    //    == 0x2000, egc.fgc for == 0x4000; each quad is maskword[colour&15] expanded per
    //    plane (io/egc.c), i.e. plane p = 0xFFFF iff bit p of the colour nibble is
    //    set. mask2 = egc.mask & egc.srcmask.
    // ============================================================
    // B1: bgc = 0x0005 -> planes 0,2 full; 1,3 empty.
    begin_case(16'hFFF0, 16'h2000, 16'h1000, 16'd0, 16'h0005, 16'hFFFF, 16'd0, 16'h000F);
    word_write(32'h0000_0000, 4'b0011, 15'h0100);
    chk("B1 bgc=5 plane0", 0, 15'h0101, 8'hFF);
    chk("B1 bgc=5 plane1", 1, 15'h0101, 8'h00);
    chk("B1 bgc=5 plane2", 2, 15'h0101, 8'hFF);
    chk("B1 bgc=5 plane3", 3, 15'h0101, 8'h00);

    // B2: fgc = 0x000A -> planes 1,3 full; 0,2 empty.
    begin_case(16'hFFF0, 16'h4000, 16'h1000, 16'h000A, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    word_write(32'h0000_0000, 4'b0011, 15'h0100);
    chk("B2 fgc=A plane0", 0, 15'h0101, 8'h00);
    chk("B2 fgc=A plane1", 1, 15'h0101, 8'hFF);
    chk("B2 fgc=A plane2", 2, 15'h0101, 8'h00);
    chk("B2 fgc=A plane3", 3, 15'h0101, 8'hFF);

    // B3: fgc = 0x000F -> all planes full.
    begin_case(16'hFFF0, 16'h4000, 16'h1000, 16'h000F, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    word_write(32'h0000_0000, 4'b0011, 15'h0100);
    for (p = 0; p < 4; p = p + 1) chk("B3 fgc=F plane all", p, 15'h0101, 8'hFF);

    // B4: fgc = 0x0009 (planes 0,3) with mask 0xFF00 over a 0x1111 destination.
    //     plane0/3: (0xFFFF & 0xFF00)|(0x1111 & 0x00FF) = 0xFF11
    //     plane1/2: (0x0000 & 0xFF00)|(0x1111 & 0x00FF) = 0x0011
    begin_case(16'hFFF0, 16'h4000, 16'h1000, 16'h0009, 16'd0, 16'hFF00, 16'd0, 16'h000F);
    preload(15'h0100, 8'h11);
    word_write(32'h0000_0000, 4'b0011, 15'h0100);
    chk("B4 fgc=9 maskFF00 p0 low",  0, 15'h0100, 8'h11);
    chk("B4 fgc=9 maskFF00 p0 high", 0, 15'h0101, 8'hFF);
    chk("B4 fgc=9 maskFF00 p1 high", 1, 15'h0101, 8'h00);
    chk("B4 fgc=9 maskFF00 p2 high", 2, 15'h0101, 8'h00);
    chk("B4 fgc=9 maskFF00 p3 high", 3, 15'h0101, 8'hFF);

    // B5: fgc = 0x0001 -> plane 0 only.
    begin_case(16'hFFF0, 16'h4000, 16'h1000, 16'h0001, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    word_write(32'h0000_0000, 4'b0011, 15'h0100);
    chk("B5 fgc=1 plane0", 0, 15'h0101, 8'hFF);
    chk("B5 fgc=1 plane1", 1, 15'h0101, 8'h00);

    // B6: fgc = 0x0008 -> plane 3 only.
    begin_case(16'hFFF0, 16'h4000, 16'h1000, 16'h0008, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    word_write(32'h0000_0000, 4'b0011, 15'h0100);
    chk("B6 fgc=8 plane2", 2, 15'h0101, 8'h00);
    chk("B6 fgc=8 plane3", 3, 15'h0101, 8'hFF);

    // ============================================================
    // C. The fgbg colour quads, BYTE path (egc_opeb, mem/memegc.c). case 0x1000
    //    returns egc.bgc/egc.fgc with mask2 = egc.mask (no srcmask AND).
    // ============================================================
    // C1: fgc = 0x0009, lane 0, full mask.
    begin_case(16'hFFF0, 16'h4000, 16'h1000, 16'h0009, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    byte_write(15'h0200, 2'd0, 8'hA5);
    chk("C1 fgc=9 byte p0", 0, 15'h0200, 8'hFF);
    chk("C1 fgc=9 byte p1", 1, 15'h0200, 8'h00);
    chk("C1 fgc=9 byte p2", 2, 15'h0200, 8'h00);
    chk("C1 fgc=9 byte p3", 3, 15'h0200, 8'hFF);

    // C2: bgc = 0x0006 (planes 1,2), ODD lane 1, mask 0xFF00.
    begin_case(16'hFFF0, 16'h2000, 16'h1000, 16'd0, 16'h0006, 16'hFF00, 16'd0, 16'h000F);
    byte_write(15'h0200, 2'd1, 8'hA5);
    chk("C2 bgc=6 lane1 p0", 0, 15'h0201, 8'h00);
    chk("C2 bgc=6 lane1 p1", 1, 15'h0201, 8'hFF);
    chk("C2 bgc=6 lane1 p2", 2, 15'h0201, 8'hFF);
    chk("C2 bgc=6 lane1 p3", 3, 15'h0201, 8'h00);

    // C3: bgc = 0x0006, lane 0, nibble mask 0x000F over 0x11.
    begin_case(16'hFFF0, 16'h2000, 16'h1000, 16'd0, 16'h0006, 16'h000F, 16'd0, 16'h000F);
    preload(15'h0200, 8'h11);
    byte_write(15'h0200, 2'd0, 8'hA5);
    chk("C3 bgc=6 mask000F p0", 0, 15'h0200, 8'h10);
    chk("C3 bgc=6 mask000F p1", 1, 15'h0200, 8'h1F);
    chk("C3 bgc=6 mask000F p2", 2, 15'h0200, 8'h1F);
    chk("C3 bgc=6 mask000F p3", 3, 15'h0200, 8'h10);

    // ============================================================
    // D. The fgbg DEFAULT byte selection. NP2kai's egc_opeb case 0x1000 default runs
    //    EGCOPE_SHIFTB -- which feeds ONLY when ope[10] (SHIFT_CPU) is set -- THEN
    //    mask2 &= srcmask, and returns egc_src: the LAST produce's output, not one the
    //    current CPU byte just made.
    // ============================================================
    // D1: ope=0x1400 (SHIFT_CPU set), fgbg 0x00FF. EGCOPE_SHIFTB feeds 0x5A and egc_src
    //     becomes it (sft=0), so the byte written is 0x5A.
    begin_case(16'hFFF0, 16'h00FF, 16'h1400, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    preload(15'h0300, 8'h11);
    byte_write(15'h0300, 2'd0, 8'h5A);
    for (p = 0; p < 4; p = p + 1) chk("D1 pat SHIFT byte", p, 15'h0300, 8'h5A);

    // D2: drop SHIFT_CPU to ope=0x1000 and write a DIFFERENT byte. EGCOPE_SHIFTB now feeds
    //     nothing, so egc_src is still 0x5A and that is what NP2kai stores; the RTL produces
    //     from the current CPU byte and stores 0xA5.
    set_ope_fgbg(16'h1000, 16'h00FF);
    preload(15'h0304, 8'h11);
    byte_write(15'h0304, 2'd0, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("D2 patnoSHIFT byte", p, 15'h0304, 8'h5A);

    // ============================================================
    // E. fgbg&0x6000 == 0x6000 on the BYTE path. NP2kai falls into the same `default` as
    //    0x0000: EGCOPE_SHIFTB + mask2 &= srcmask + egc_src. To make srcmask partial, a
    //    preceding WORD write is armed with leng=0, so NP2kai's EGCOPE_SHIFTW2 leaves
    //    srcmask = 0x0080 (egcsftw_upn0's remain-1 byte mask; mem/memegc.c).
    // ============================================================
    // E1: fgbg 0x6000; expected mask2 = 0xFFFF & 0x0080 = 0x0080, data = egc_src = 0x00
    //     (the leng=0 word write fed 0x0000), so the byte is (old 0xFF & 0x7F) = 0x7F.
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'd0);
    word_write(32'h0000_0000, 4'b0011, 15'h0400);      // sets srcmask = 0x0080
    preload(15'h0404, 8'hFF);
    set_ope_fgbg(16'h1000, 16'h6000);
    byte_write(15'h0404, 2'd0, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("E1 fgbg6000 byte", p, 15'h0404, 8'h7F);

    // E2: same setup with fgbg 0x00FF (selection 0). Mask2 = 0x0080 but the data is still
    //     egc_src = 0x00.
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'd0);
    word_write(32'h0000_0000, 4'b0011, 15'h0400);
    preload(15'h0404, 8'hFF);
    set_ope_fgbg(16'h1000, 16'h00FF);
    byte_write(15'h0404, 2'd0, 8'hA5);
    for (p = 0; p < 4; p = p + 1) chk("E2 fgbg0000 byte", p, 15'h0404, 8'h7F);

    // E3: fgbg 0x6000 with the SAME data egc_src holds (0x00), isolating the mask from the
    //     data: NP2kai's mask2 0x0080 leaves bit 7 = old 0xFF -> 0x7F, the RTL's mask 0xFF
    //     clears the whole byte -> 0x00.
    begin_case(16'hFFF0, 16'h00FF, 16'h0000, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'd0);
    word_write(32'h0000_0000, 4'b0011, 15'h0400);
    preload(15'h0408, 8'hFF);
    set_ope_fgbg(16'h1000, 16'h6000);
    byte_write(15'h0408, 2'd0, 8'h00);
    for (p = 0; p < 4; p = p + 1) chk("E3 fgbg6000 mask", p, 15'h0408, 8'h7F);

    // ============================================================
    // F. The PATTERN REGISTER as a colour source. A read with RL_MEMREAD ((ope&0x0300)==0x0100)
    //    latches egc.patreg from the fetched quad, and egc_opew case 0x1000 returns egc.patreg
    //    when fgbg&0x6000 is neither 0x2000 nor 0x4000. NP2kai latches ALL FOUR planes from a
    //    single read; the MACHINE latches the SELECTED one only - "Normal PLOAD_R loads the
    //    selected PAT plane only.  Four-plane PAT setup uses four selected reads" (the
    //    PC98_EGC_CONFORMANCE v1.3 README) and its RD02_PAT_S0..S3 rows, where the three planes
    //    the read did not select keep their retained value (docs/probes/egc-conformance,
    //    tb_pc9821_egc_compare section 3). So the four-plane setup below is four SELECTED reads
    //    at the one address - one per 0x4A2 read-plane selector - exactly as the suite does it.
    // ============================================================
    begin_case(16'hFFF0, 16'h00FF, 16'h3100, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    poke(0, 15'h0500, 8'h22); poke(0, 15'h0501, 8'h11);
    poke(1, 15'h0500, 8'h44); poke(1, 15'h0501, 8'h33);
    poke(2, 15'h0500, 8'h66); poke(2, 15'h0501, 8'h55);
    poke(3, 15'h0500, 8'h88); poke(3, 15'h0501, 8'h77);
    for (p = 0; p < 4; p = p + 1) begin
      set_ope_fgbg(16'h3100, {6'h00, p[1:0], 6'h00, p[1:0]});
      word_read(15'h0500, 2'd0, 4'b0011);
    end
    set_ope_fgbg(16'h3100, 16'h00FF);
    // F1: fgbg selection 0 -> the pattern register quad.
    set_ope_fgbg(16'h1000, 16'h00FF);
    word_write(32'h0000_0000, 4'b0011, 15'h0600);
    chk("F1 patreg p0 lo", 0, 15'h0600, 8'h22);
    chk("F1 patreg p0 hi", 0, 15'h0601, 8'h11);
    chk("F1 patreg p1 lo", 1, 15'h0600, 8'h44);
    chk("F1 patreg p1 hi", 1, 15'h0601, 8'h33);
    chk("F1 patreg p2 lo", 2, 15'h0600, 8'h66);
    chk("F1 patreg p2 hi", 2, 15'h0601, 8'h55);
    chk("F1 patreg p3 lo", 3, 15'h0600, 8'h88);
    chk("F1 patreg p3 hi", 3, 15'h0601, 8'h77);
    // F2: fgbg 0x6000 on the WORD path is also `default` -> the pattern register.
    set_ope_fgbg(16'h1000, 16'h6000);
    word_write(32'h0000_0000, 4'b0011, 15'h0620);
    chk("F2 patreg6000 p0 lo", 0, 15'h0620, 8'h22);
    chk("F2 patreg6000 p0 hi", 0, 15'h0621, 8'h11);
    chk("F2 patreg6000 p3 hi", 3, 15'h0621, 8'h77);

    // F3: the RL_MEMWRITE load (ope[9:8]==2'b10). NP2kai egc_writeword latches patreg from
    //     the DESTINATION before egc_opew runs, so the same write stores that just-loaded
    //     pattern. A later 0x1000 write must reproduce the pre-write destination words.
    begin_case(16'hFFF0, 16'h00FF, 16'h1200, 16'd0, 16'd0, 16'hFFFF, 16'd0, 16'h000F);
    poke(0, 15'h0700, 8'h0A); poke(0, 15'h0701, 8'h0B);
    poke(1, 15'h0700, 8'h0C); poke(1, 15'h0701, 8'h0D);
    poke(2, 15'h0700, 8'h0E); poke(2, 15'h0701, 8'h0F);
    poke(3, 15'h0700, 8'h1A); poke(3, 15'h0701, 8'h1B);
    word_write(32'h0000_0000, 4'b0011, 15'h0700);      // latches patreg from 0x0700
    // NP2kai latches patreg BEFORE egc_opew, so this write stores the just-latched old
    // destination words back (mask full); the destination is unchanged.
    chk("F3 memwrite dst p0 lo", 0, 15'h0700, 8'h0A);
    chk("F3 memwrite dst p0 hi", 0, 15'h0701, 8'h0B);
    chk("F3 memwrite dst p1 hi", 1, 15'h0701, 8'h0D);
    chk("F3 memwrite dst p3 lo", 3, 15'h0700, 8'h1A);
    chk("F3 memwrite dst p3 hi", 3, 15'h0701, 8'h1B);
    set_ope_fgbg(16'h1000, 16'h00FF);
    word_write(32'h0000_0000, 4'b0011, 15'h0720);
    chk("F3 memwrite p0 lo", 0, 15'h0720, 8'h0A);
    chk("F3 memwrite p0 hi", 0, 15'h0721, 8'h0B);
    chk("F3 memwrite p1 lo", 1, 15'h0720, 8'h0C);
    chk("F3 memwrite p2 hi", 2, 15'h0721, 8'h0F);
    chk("F3 memwrite p3 lo", 3, 15'h0720, 8'h1A);
    chk("F3 memwrite p3 hi", 3, 15'h0721, 8'h1B);

    // ==== VERDICT ====
    if (mismatches == 0) begin
      $display("TB_PC9821_EGC_MASK_PATTERN: PASS");
      $display("  %0d checks, 0 mismatches", cases);
      $finish;
    end else begin
      $display("TB_PC9821_EGC_MASK_PATTERN: FAIL (%0d/%0d checks mismatch NP2kai)", mismatches, cases);
      $fatal(1, "EGC mask/pattern deviations from NP2kai");
    end
  end

  initial begin : watchdog
    #2_000_000;
    $fatal(1, "TB_PC9821_EGC_MASK_PATTERN: watchdog fired");
  end

endmodule

`default_nettype wire
