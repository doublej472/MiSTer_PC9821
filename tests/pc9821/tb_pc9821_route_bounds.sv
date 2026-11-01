`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ROUTE_BOUNDS: text RAM and the character-generator window answer correctly at the EDGES of their regions -- the last DWORD, the last cache line and the last byte of the 16 KiB text RAM, and the last DWORD of the 4 KiB CG window -- because the existing benches drive only interior offsets (0x0123, 0x0121, 0x0037, 0x07, 0x27, 0x47, 0x11) and a base that let a transfer run off the end would pass every one of them.
//
// WHY THE EXISTING BENCHES DO NOT COVER THIS, stated rather than assumed. tb_pc9821_tram_bridge
// drives offsets 0x0123, 0x0121 and 0x0037; tb_pc9821_cg_window drives 0x07, 0x27, 0x47 and 0x11.
// Every one of those is well inside its region, so a base that aligned four bytes wrong, or that let
// a 16-byte line or a 32-byte window view run past the end, would pass all of them. Both benches are
// otherwise strong -- the tram bench carries a same-cycle ready/response guard -- which is exactly
// why this is a gap to close rather than a bench to replace.
//
// WHAT THIS BENCH ADDS AND WHAT IT DOES NOT, measured rather than assumed. Planting an UNALIGNED
// base_off in the CG window was observed to FAIL tb_pc9821_cg_window, so the alignment property is
// already covered and the alignment tests below are deliberate duplication kept for locality, not a
// new claim. What is NOT covered anywhere is the EDGE of each region: no existing offset is near
// 0x3FFF or near the top of the CG view, so a transfer that ran off the end would pass them all.
//
// WHERE EACH EXPECTATION COMES FROM. Text RAM is 0xA0000-0xA3FFF, 16 KiB, so 0x3FFF is the last byte
// and the 14-bit port cannot name more; a read that aligns down and then walks forward must stop
// there rather than wrap. A DWORD read at 0x3FFF therefore starts at 0x3FFC, and a cache line at
// 0x3FF0. Both land in the ATTRIBUTE half, whose odd bytes read back as the machine's 0xFF:
// the Xe10 read-back row (`A2000` | `00 FF 55 AA` | `00 FF 55 FF`) is that
// row, so the ramp below shows in their even lanes; the even lane
// values are what pin the aligned base. The byte-enable bit order is fixed by the existing tram
// bench's be=4'b1011 case, where be[0] carries data[7:0] and be[3] carries data[31:24].
//
// The CG window is 0xA4000-0xA4FFF and, per NP2kai memtram.c:23-29, its position is {page =
// address[0], row = address[4:1]} -- so the view repeats every 32 bytes and the page is the LOW bit,
// not the row. That permutation is asserted here through the module's own byte_sel port, which is
// the position it hands the GDC's class table. THE MACHINE CORROBORATES IT: docs/probes/VRAM.TXT
// reads A4000..A400F as 8F 00 8F 00 ... -- the even offsets carry one constant and the odd offsets
// another, which is only possible if bit 0 selects a different PAGE rather than a neighbouring byte.
//
// ---------------------------------------------------------------------------
// WHAT IS DELIBERATELY NOT ASSERTED, so the next reader does not think it was forgotten:
//   * A line WRITE cannot occur. z486 bus_unit.sv:301 (`assign line_read  = ext_valid_r && !ext_write_r`) makes line_read exclusive with write (line_read
//     requires !ext_write_r; write requires ext_write_r), so the bridges' shared write path can never
//     see a 16-byte request. It is NOT defended in the RTL -- the write path indexes its data with
//     byte_index[1:0], which wraps every four bytes -- so if the CPU's contract ever changed, bytes
//     4..15 would be written with bytes 0..3's data. Reported, not asserted: a bench cannot prove
//     anything about a state it cannot reach.
//   * The memory-switch cells at 0xA3FE2+i*4 and their write protect live in pc9821_gdc_text, not in
//     either bridge, so they are a report finding rather than this bench's subject.

module tb_pc9821_route_bounds;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ---- TRAM bridge ----
  reg  [13:0] tb_addr = 0;
  reg  [31:0] tb_din = 0;
  reg  [3:0]  tb_be = 0;
  reg         tb_valid = 0, tb_write = 0, tb_line = 0;
  wire [31:0]  tb_dout;
  wire [31:0]  tb_line_dout;   // the current word beat (P3)
  reg  [127:0] tb_line_cap;    // the four beats of the last line read, as the L1 gathers them
  wire         tb_ready, tb_resp, tb_line_resp;
  wire [13:0] tram_addr;
  wire [7:0]  tram_din;
  wire        tram_we;
  reg  [7:0]  tram_dout;
  reg  [7:0]  ram [0:16383];

  // ---- CG window ----
  reg  [11:0] cg_addr = 0;
  reg  [31:0] cg_din = 0;
  reg  [3:0]  cg_be = 0;
  reg         cg_valid = 0, cg_write = 0, cg_line = 0;
  wire [31:0]  cg_dout;
  wire [31:0]  cg_line_dout;   // the current word beat (P3)
  reg  [127:0] cg_line_cap;
  wire         cg_ready, cg_resp, cg_line_resp;
  wire [4:0]  cg_byte_sel;
  wire        cg_byte_rd;
  wire [7:0]  cg_byte_dout;
  wire [7:0]  cg_byte_din;
  wire        cg_byte_we;

  // ---- The merged responder's two route arms ----
  wire [4:0]  tram_byte_sel;
  wire        tram_byte_rd, tram_byte_we;
  wire [7:0]  tram_byte_din;
  wire [13:0] cgw_tram_addr;
  wire [7:0]  cgw_tram_din;
  wire        cgw_tram_we;

  // ==== DUT ====
  // The TRAM bridge and the CG byte window are the same eight-state byte walk, served by ONE
  // engine now (pc9821_window_responder): the memory subsystem instantiates it once with
  // route_cg = the map's one-hot CG select. This bench drives the two ARMS separately -- one
  // instance pinned to route_cg = 0 and one to route_cg = 1 -- because it is asserting each
  // region's EDGE behaviour, not the subsystem's routing; the shared-instance routing is
  // covered by tb_pc9821_cg_window and tb_pc9821_memory_subsystem.

  // The DMA ports are idle: this bench is about the CPU routes' edges.
  wire       tram_dma_ready, tram_dma_resp, cgw_dma_ready, cgw_dma_resp;
  wire [7:0] tram_dma_dout, cgw_dma_dout;
  pc9821_window_responder tram (
      .clk(clk), .reset(reset), .route_cg(1'b0),
      .cpu_addr(tb_addr), .cpu_din(tb_din), .cpu_be(tb_be),
      .cpu_line_read(tb_line), .cpu_valid(tb_valid), .cpu_write(tb_write),
      .cpu_dout(tb_dout), .cpu_line_word(tb_line_dout),
      .cpu_ready(tb_ready), .cpu_resp_valid(tb_resp), .cpu_line_word_valid(tb_line_resp),
      .dma_valid(1'b0), .dma_write(1'b0), .dma_addr(14'd0), .dma_din(8'h00),
      .dma_ready(tram_dma_ready), .dma_resp_valid(tram_dma_resp), .dma_dout(tram_dma_dout),
      .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we), .tram_dout(tram_dout),
      .byte_sel(tram_byte_sel), .byte_rd(tram_byte_rd),
      .byte_dout(8'h00), .byte_hold(1'b0),
      .byte_din(tram_byte_din), .byte_we(tram_byte_we));

  pc9821_window_responder cgw (
      .clk(clk), .reset(reset), .route_cg(1'b1),
      .cpu_addr({2'b0, cg_addr}), .cpu_din(cg_din), .cpu_be(cg_be),
      .cpu_line_read(cg_line), .cpu_valid(cg_valid), .cpu_write(cg_write),
      .cpu_dout(cg_dout), .cpu_line_word(cg_line_dout),
      .cpu_ready(cg_ready), .cpu_resp_valid(cg_resp), .cpu_line_word_valid(cg_line_resp),
      .dma_valid(1'b0), .dma_write(1'b0), .dma_addr(14'd0), .dma_din(8'h00),
      .dma_ready(cgw_dma_ready), .dma_resp_valid(cgw_dma_resp), .dma_dout(cgw_dma_dout),
      .tram_addr(cgw_tram_addr), .tram_din(cgw_tram_din), .tram_we(cgw_tram_we),
      .tram_dout(8'h00),
      .byte_sel(cg_byte_sel), .byte_rd(cg_byte_rd),
      .byte_dout(cg_byte_dout), .byte_hold(1'b0),
      .byte_din(cg_byte_din), .byte_we(cg_byte_we));

  integer i, errors = 0;

  // A same-cycle accept and response wedges z486. Checked on EVERY edge for both bridges rather
  // than sampled, because the failure mode is a one-cycle pulse.
  always @(posedge clk) begin
    if (tb_ready && (tb_resp || tb_line_resp)) $fatal(1, "tram: ready and response in the same cycle");
    if (cg_ready && (cg_resp || cg_line_resp)) $fatal(1, "cg: ready and response in the same cycle");
  end

  // The TRAM itself: one-cycle, write-first, matching pc9821_dpram's ports as read from the source
  // (q_a <= ram[address_a] when not writing; q_a <= data_a when writing). The bridge's read sequence
  // presents the address one cycle before it samples, which this model needs to line up with.
  always @(posedge clk) begin
    if (tram_we) begin
      ram[tram_addr] <= tram_din;
      tram_dout <= tram_din;
    end else
      tram_dout <= ram[tram_addr];
  end

  // The GDC byte port. The class table is pc9821_gdc_text's; all this bench needs is a byte that
  // depends on the POSITION the window presents, so the pages can be told apart.
  reg [7:0] cg_store [0:31];
  reg [7:0] cg_byte_q = 8'h00;
  always @(posedge clk) begin
    if (cg_byte_we) cg_store[cg_byte_sel] <= cg_byte_din;
    else if (cg_byte_rd) cg_byte_q <= cg_store[cg_byte_sel];
  end
  assign cg_byte_dout = cg_byte_q;

  // ==== STIMULUS ====
  task automatic tram_req(input [13:0] a, input wr, input line, input [3:0] be, input [31:0] d);
    integer n;
    begin
      @(negedge clk);
      tb_addr = a; tb_din = d; tb_be = be; tb_write = wr; tb_line = line; tb_valid = 1;
      while (!tb_ready) @(negedge clk);
      // A line read is accepted at the walk's start (P3) and its four word beats stream through
      // it; gather them in order, beat N into line word N as the L1 does.
      if (!wr && line) begin
        n = 0; tb_line_cap = 128'd0;
        while (n < 4) begin
          @(negedge clk);
          if (tb_line_resp) begin tb_line_cap[{n[1:0], 5'b00000} +: 32] = tb_line_dout; n = n + 1; end
        end
      end
      else if (!wr) while (!tb_resp) @(negedge clk);
      #1;
    end
  endtask
  task automatic tram_end;
    begin
      @(negedge clk); tb_valid = 0; tb_write = 0; tb_line = 0; tb_be = 0;
      while (tram.state != 0) @(negedge clk);
    end
  endtask
  task automatic cg_req(input [11:0] a, input wr, input line, input [3:0] be, input [31:0] d);
    integer n;
    begin
      @(negedge clk);
      cg_addr = a; cg_din = d; cg_be = be; cg_write = wr; cg_line = line; cg_valid = 1;
      while (!cg_ready) @(negedge clk);
      if (!wr && line) begin
        n = 0; cg_line_cap = 128'd0;
        while (n < 4) begin
          @(negedge clk);
          if (cg_line_resp) begin cg_line_cap[{n[1:0], 5'b00000} +: 32] = cg_line_dout; n = n + 1; end
        end
      end
      else if (!wr) while (!cg_resp) @(negedge clk);
      #1;
    end
  endtask
  task automatic cg_end;
    begin
      @(negedge clk); cg_valid = 0; cg_write = 0; cg_line = 0; cg_be = 0;
      while (cgw.state != 0) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    // A ramp, so a base that aligned wrongly shows up in the DATA and not merely in the address.
    for (i = 0; i < 16384; i = i + 1) ram[i] = i[7:0];
    for (i = 0; i < 32; i = i + 1) cg_store[i] = 8'hA0 + i[7:0];
    tram_dout = 8'h00;
    repeat (3) @(posedge clk);
    @(negedge clk); reset = 0;

    // ---- 1. THE LAST DWORD of text RAM. 0x3FFF aligns down to 0x3FFC, so the four bytes are the
    // ramp's FC, FD, FE, FF and the little-endian dword would be 0xFFFEFDFC. A base that used the
    // raw address would start at 0x3FFF and wrap, or return the last byte four times.
    // 0x3FFC-0x3FFF is the ATTRIBUTE half, whose ODD bytes read back as the machine's 0xFF:
    // the Xe10 read-back row (`A2000` | `00 FF 55 AA` | `00 FF 55 FF`), the probe's own
    // row: it wrote `00 FF 55 AA` at A2000 and read `00 FF 55 FF` back, so the dword is
    // {FF, FE, FF, FC} = 0xFFFEFFFC. The EVEN lanes (FC, FE) are
    // still the ramp and are what pins the aligned base - a base that used the raw address would
    // move them.
    tram_req(14'h3FFF, 1'b0, 1'b0, 4'hF, 32'd0);
    if (!tb_resp || tb_line_resp || tb_dout !== 32'hFF_FE_FF_FC) begin
      $display("FAIL tram last dword: got %08x want fffefffc", tb_dout);
      errors = errors + 1;
    end
    tram_end();

    // ---- 2. THE LAST CACHE LINE. 0x3FFF aligns down to 0x3FF0 and returns exactly 16 bytes
    // ending at 0x3FFF, with no wrap back to 0x3F00. The attribute half's odd lanes read 0xFF
    // (case 1), so the ramp shows in the even lanes only.
    tram_req(14'h3FFF, 1'b0, 1'b1, 4'hF, 32'd0);
    if (tb_line_cap !== 128'hFF_FE_FF_FC_FF_FA_FF_F8_FF_F6_FF_F4_FF_F2_FF_F0) begin
      $display("FAIL tram last line: got %032x", tb_line_cap);
      errors = errors + 1;
    end
    tram_end();

    // ---- 3. A SINGLE-LANE WRITE AT THE LAST BYTE. 0x3FFF aligns to 0x3FFC, so the lane index
    // is 3 and the address walked to is base+3 -- proved in the CODE half at 0x1FFF, where an
    // odd store lands: be[3] selects lane 3, which is data[31:24], so 0xDE is the byte that must
    // land -- not 0xEF -- and 0x1FFC must be untouched. The same lane-3 write at 0x3FFF must be
    // a NO-OP: 0x3FFF is an ODD ATTRIBUTE byte and the attribute half is even-only (NP2kai
    // mem/memtram.c:82-99, the machine A2000 probe row), so the byte
    // keeps its 0xFF and 0x3FFC stays 0xFC. FAIL-FIRST on the old store-it-anyway bridge.
    tram_req(14'h1FFF, 1'b1, 1'b0, 4'b1000, 32'hDE_AD_BE_EF);
    if (ram[14'h1FFF] !== 8'hDE || ram[14'h1FFC] !== 8'hFC) begin
      $display("FAIL tram lane-3 write at the end: 1FFF=%02x (want de) 1FFC=%02x (want fc)",
               ram[14'h1FFF], ram[14'h1FFC]);
      errors = errors + 1;
    end
    tram_end();
    tram_req(14'h3FFF, 1'b1, 1'b0, 4'b1000, 32'hDE_AD_BE_EF);
    if (ram[14'h3FFF] !== 8'hFF || ram[14'h3FFC] !== 8'hFC) begin
      $display("FAIL tram odd attr write at the end: 3FFF=%02x (want ff) 3FFC=%02x (want fc)",
               ram[14'h3FFF], ram[14'h3FFC]);
      errors = errors + 1;
    end
    tram_end();

    // ---- 4. THE WHOLE PAGE/ROW PERMUTATION IN ONE READ. A dword read starts at the aligned base
    // and walks four byte offsets; at base 0x000 those are 0x000, 0x001, 0x002, 0x003, which the
    // permutation maps to positions 0x00, 0x10, 0x01, 0x11. So lanes 0 and 2 are the two rows of
    // PAGE 0 and lanes 1 and 3 the same two rows of PAGE 1. With the ramp cg_store[i] = 0xA0+i the
    // four bytes are A0, B0, A1, B1, and a module that used the raw low bits or swapped page with
    // row lands all four somewhere else.
    cg_req(12'h000, 1'b0, 1'b0, 4'hF, 32'd0);
    if (!cg_resp || cg_line_resp || cg_dout !== 32'hB1_A1_B0_A0) begin
      $display("FAIL cg dword read at 0x000 wants B1A1B0A0 (page/row permutation), got %08x", cg_dout);
      errors = errors + 1;
    end
    cg_end();

    // ---- 5. THE 32-BYTE REPEAT AT THE TOP OF THE REGION, asserted through a READ rather than by
    // poking win_addr. This distinction matters and cost this bench its first run: byte_sel is a
    // function of the REGISTERED base_off, latched when the request is accepted, so writing win_addr
    // combinationally does not move the position -- which is correct behaviour, since the position
    // must not change under a transfer in flight. So every position test below is a data test.
    //
    // A dword read at 0xFE0 walks offsets 0xFE0..0xFE3. The permutation maps those to positions
    // 0x00, 0x10, 0x01, 0x11 -- the same four positions a dword at 0x000 reaches, because 0xFE0 is
    // 127 whole 32-byte periods. The value must therefore be IDENTICAL to test 4's, and that
    // identity IS the repeat: no arithmetic on the base, just the same bytes.
    cg_req(12'hFE0, 1'b0, 1'b0, 4'hF, 32'd0);
    if (!cg_resp || cg_line_resp || cg_dout !== 32'hB1_A1_B0_A0) begin
      $display("FAIL cg dword read at 0xFE0 wants B1A1B0A0 (32-byte repeat of 0x000), got %08x", cg_dout);
      errors = errors + 1;
    end
    cg_end();

    // The LAST DWORD of the window, 0xFFC..0xFFF, reaches positions 0x0E, 0x1E, 0x0F and 0x1F --
    // row 7 of both pages, then row 15 of both pages. Nothing runs off the end and nothing wraps to
    // the bottom of the view: the values are the ramp at 0x0E, 0x1E, 0x0F, 0x1F = AE, BE, AF, BF.
    cg_req(12'hFFC, 1'b0, 1'b0, 4'hF, 32'd0);
    if (!cg_resp || cg_line_resp || cg_dout !== 32'hBF_AF_BE_AE) begin
      $display("FAIL cg dword read at 0xFFC wants BFAFBEAE (last of the view), got %08x", cg_dout);
      errors = errors + 1;
    end
    cg_end();

    // ---- 6. THE PAGE BIT IS OFFSET BIT 0, and test 4 has already proven it: lanes 2 and 3 of that
    // read are offsets 0x002 and 0x003, which differ ONLY in the low bit and must therefore name the
    // same row of two DIFFERENT pages -- positions 0x01 and 0x11, values A1 and B1, not the two
    // adjacent rows A1 and A2 a raw-low-bits decode would give. That identity is what makes the
    // machine's A4000 and A4001 read differently (docs/probes/VRAM.TXT: 8F 00 8F 00 ...). Rather than
    // restate it, this bench asserts the one thing test 4 cannot: that the two lanes really are a
    // page apart, by comparing them against the page-0 and page-1 ramp bytes directly.
    if (cg_store[5'h01] === cg_store[5'h11]) begin
      $display("FAIL the bench's own page-0 and page-1 ramp bytes are equal, so test 4 cannot " +
               "distinguish the pages it claims to distinguish");
      errors = errors + 1;
    end

    // ---- 7. AN UNALIGNED READ STARTS AT THE ALIGNED BASE. Tests 4 to 6 all use addresses that are
    // already four-byte aligned, so they cannot see this -- and planting exactly that bug (base_off
    // taking the raw win_addr) was observed to PASS every one of them. A dword at 0x002 must
    // therefore still read the four bytes of 0x000, and the values prove it: the raw-base answer
    // would be A1 B1 A2 B2 (0xB2A2B1A1), the aligned answer is A0 B0 A1 B1.
    cg_req(12'h002, 1'b0, 1'b0, 4'hF, 32'd0);
    if (!cg_resp || cg_line_resp || cg_dout !== 32'hB1_A1_B0_A0) begin
      $display("FAIL cg unaligned dword at 0x002 wants B1A1B0A0 (aligned to 0x000), got %08x", cg_dout);
      errors = errors + 1;
    end
    cg_end();

    // ---- 8. AND AN UNALIGNED LINE READ, which is the same claim for the 16-byte transfer. A line
    // at 0x00A aligns to 0x000 and walks the view's sixteen positions in ADDRESS order, which the
    // permutation scatters across both pages: bytes A0 B0 A1 B1 A2 B2 ... A7 B7, i.e. 0xA0 is the
    // row-0 page-0 byte, 0xB0 the row-0 page-1 byte, and so on up to row 7. A raw-base line would
    // start at offset 0x00A and return rows 5,6,7 of both pages then wrap.
    cg_req(12'h00A, 1'b0, 1'b1, 4'hF, 32'd0);
    if (cg_line_cap !== 128'hB7_A7_B6_A6_B5_A5_B4_A4_B3_A3_B2_A2_B1_A1_B0_A0) begin
      $display("FAIL cg unaligned line at 0x00A wants the view from 0x000, got %032x", cg_line_cap);
      errors = errors + 1;
    end
    cg_end();

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ROUTE_BOUNDS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ROUTE_BOUNDS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog, matching the other benches.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_ROUTE_BOUNDS: TIMEOUT");
  end

endmodule
