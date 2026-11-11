`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The CG window's unused low page answers the machine's measured dummy byte 0x8F in the writable user-CG class rather than zero, pinned by the capture that also fixes the class (its odd page holds the zeroed store and its even writes are dropped, so 0x8F cannot be memory) and without disturbing the odd page's write round-trip; and the two GDC status bytes are shown not to be the same byte, since a 2M-sample histogram has 0xA0's bit 0 never moving where 0x60's toggles.
//
// ---- the bench's own account of where each expectation comes from ----
// BOTH EXPECTATIONS ARE MACHINE PROPERTIES, from the Xe10 captures, not from the RTL.
//
// THE 0x8F DUMMY. docs/probes/VRAM.TXT records, in the writable class:
//     A4000..A400F (CG window, across the TRAM boundary):
//         8F 00 8F 00 8F 00 8F 00 8F 00 8F 00 8F 00 8F 00
//     A400wrote= 00 FF 55 AA   got= 8F FF 8F AA
// Three facts fix its meaning, and the second is what rules out the obvious reading:
//   * the ODD page is the gaiji store itself and reads 0x00 for all eight rows, so the store is
//     zeroed on the machine;
//   * therefore the even page's 0x8F is NOT the store -- a store reading 0x00 cannot answer 0x8F;
//   * and in the read-after-write the even writes were DROPPED (wrote 00 and 55, read 8F) while the
//     odd ones survived (wrote FF and AA, read FF and AA), so the even page is read-only.
// 0x8F is constant across all eight rows and identical in two independent captures (VRAM.TXT and
// VRAM2.TXT), where glyph data would vary per row and uninitialised SRAM would not repeat.
//
// THE CLASS IS PINNED BY THE SAME CAPTURE, which is why this bench loads the code it does. The same
// snapshot reads 0xA1=2F and 0xA3=57, i.e. cg_code = 0x2F57. Its low seven bits are 0x57, which is the
// gaiji (writable user-CG) class, and the writes being accepted at all requires cg_gaiji_writable --
// so the machine was demonstrably IN that class when it answered 0x8F. The bench reproduces it by
// loading 0x2F57 through the same two ports the firmware uses.
// NP2kai would have said 0x00 here: cgrom.c:18 leaves the unused low page on `low = 0x7fff0`, past the
// end of its 0x46800 font image. The machine is a higher evidence class, and the machine says 0x8F.
//
// THE STATUS BIT. the machine's probe results "GDC status" is a 2M-sample per-bit histogram at
// 0x60 and 0xA0, which exists precisely because one sample cannot tell a live signal from a strap:
//     bit | 0x60 | 0xA0
//      0  |  50% |  0%      <- toggles at the text GDC, NEVER moves at the graphics GDC
//      5  | 2.8% | 2.8%     <- blanking, both
//      6  |  37% |  37%     <- blanking, both
// The core answered ONE packed byte for both ports, so 0xA0's bit 0 toggled 50% where the machine
// never sets it. Three assertions cover it, and the third is what stops the bench passing vacuously:
// bit 0 of 0xA0 is always clear, every OTHER bit of the two bytes always agrees, and bit 0 of 0x60 is
// observed to take BOTH values in the window -- so the bytes are genuinely different rather than
// merely sampled at an idle moment.
//
// WHAT IT IS BLIND TO, stated rather than implied: it does not cover the other three classes that
// leave the low page unused (cg_ank, cg_ver078, cg_wide), which no capture has measured - they now
// answer the SAME class-independent dummy 0x8F (NP2kai has one dummy page shared by every class,
// io/cgrom.c:18,43-48), and tb_pc9821_cg_read_path asserts that per class. It does not check the ROM glyph classes
// (tb_pc9821_cg_read_path owns those) or the raster (tb_pc9821_gdc_raster owns that).
//
// AND IT CANNOT TELL A CONSTANT FROM A PAGE. It asserts 0x8F for the gaiji low page because that is
// what the machine answered in the only state anyone has looked at, and every capture so far was taken
// with the SAME code register loaded. If a /VRAM re-run after changing 0xA1/0xA3 moves the even byte,
// the low page is a page rather than a constant and this assertion needs to become code-dependent
// along with the RTL it pins. Stated here so that the day that capture arrives, this file is one of
// the two places that must change rather than a surprise.

module tb_pc9821_gdc_cg_dummy;

  reg clk = 0;
  always #10 clk = ~clk;              // 50 MHz, as pc9821_system runs this module

  reg rst_n = 0;

  // ---- port interface, driven by the bench ----
  reg  [7:0] io_addr = 8'h00;
  reg  [7:0] io_din  = 8'h00;
  reg        io_wr   = 1'b0;
  reg        io_rd   = 1'b0;
  wire [7:0] io_dout;

  // ---- the memory-mapped CG window, driven by the bench ----
  reg  [4:0] cg_win_byte_sel = 5'd0;   // [4] = odd/high page, [3:0] = row
  reg        cg_win_rd       = 1'b0;
  reg        cg_win_we       = 1'b0;
  reg  [7:0] cg_win_din      = 8'h00;
  wire [7:0] cg_win_dout;

  // ---- outputs the bench does not drive; declared so the named list is complete ----
  wire [7:0]  tram_cpu_dout;
  wire [18:0] font_req_addr;   wire font_req;
  wire        vsync_active, vsync_irq, disp_on, gfx_access_page, gfx_disp;
  wire [15:0] gfx_line_addr;   wire gfx_egc_gate;
  wire [15:0] dbg_sad;         wire [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp, text_opaque, text_cell;
  wire [9:0]  pix_dot;         wire pix_h_active, pix_v_active, gfx_mode16;
  wire [31:0] gfx_dig;
  // The analogue palette table's CPU write port (pc9821_gfx_palette's RAM).
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        hs_out, vs_out, de_out;

  // ==== DUT ====
  pc9821_gdc_text_dut dut (
      .clk_sys(clk), .rst_n_sys(rst_n),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .pixel_ce(1'b1),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .tram_cpu_addr(14'd0), .tram_cpu_din(8'h00), .tram_cpu_we(1'b0),
      .tram_cpu_dout(tram_cpu_dout),
      .font_ld_addr(11'd0), .font_ld_data(16'd0), .font_ld_we(1'b0),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(1'b0), .font_word_data(32'hFFFF_FFFF),
      .cg_record_restore(1'b0),
      .cfg_seed_reload(1'b0),
      .vsync_active(vsync_active), .vsync_irq_arm(1'b0),
      .vsync_irq(vsync_irq), .disp_on(disp_on), .gfx_access_page(gfx_access_page),
      .gfx_disp(gfx_disp), .gfx_line_addr(gfx_line_addr), .gfx_egc_gate(gfx_egc_gate),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch), .dbg_col40(dbg_col40), .dbg_disp(dbg_disp),
      .text_opaque(text_opaque), .text_cell(text_cell),
      .pix_h_active(pix_h_active), .pix_v_active(pix_v_active), .gfx_mode16(gfx_mode16),
      .gfx_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx),
      .pal_wr_chan(pal_wr_chan), .pal_wr_data(pal_wr_data),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  // ==== CHECKS ====
  integer errors = 0;
  integer i;

  // The machine's measured class and dummy, from docs/probes/VRAM.TXT.
  localparam [7:0] MACHINE_A1        = 8'h2F;   // snapshot: 0xA1 = 0x2F
  localparam [7:0] MACHINE_A3        = 8'h57;   // snapshot: 0xA3 = 0x57 -> cg_code 0x2F57, gaiji
  localparam [7:0] MACHINE_LOW_DUMMY = 8'h8F;   // the even page, all eight rows

  reg [7:0] b60, bA0;
  reg bit0_60_seen_high = 1'b0;
  reg bit0_60_seen_low  = 1'b0;

  task fail(input [1023:0] msg);
    begin
      errors = errors + 1;
      $display("FAIL: %0s @ %0t", msg, $time);
    end
  endtask

  task write_port(input [7:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1'b1;
      @(negedge clk);
      io_wr = 1'b0;
    end
  endtask

  // A window read the way the responder drives it: the byte select is HELD for the whole access and
  // the answer is taken from the port's REGISTERED read on the following cycle, which is what the
  // RTL's own comment describes ("the window holds its byte select for the whole access (it advances
  // only in S_READ_CAPTURE) ... win_rd_d keeps the mux pointed at the window for the wait cycle,
  // after which the answer is already in the register"). Sampling the cycle the select is applied
  // reads the register one access too early -- which is how this bench first failed, on the store
  // path only, because the unused low page is a constant and does not need the register at all.
  task read_window(input page, input [3:0] row, output [7:0] val);
    begin
      @(negedge clk);
      cg_win_byte_sel = {page, row};
      cg_win_rd = 1'b1;
      @(negedge clk);        // the registered read captures the address here
      #1;
      val = cg_win_dout;     // ... and the answer is present by the end of this cycle
      @(negedge clk);
      cg_win_rd = 1'b0;
    end
  endtask

  reg [7:0] rdval;

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // ---------------------------------------------------------------
    // 1. Load the machine's own CG code and confirm the packing
    // ---------------------------------------------------------------
    write_port(8'hA1, MACHINE_A1);
    write_port(8'hA3, MACHINE_A3);
    repeat (2) @(negedge clk);

    if (dut.u_cg.cg_code !== 16'h2F57)
      fail("the CG code registers did not pack as A1 high / A3 low to the machine's 0x2F57");

    // ---------------------------------------------------------------
    // 2. THE FIX: the unused low page answers the machine's dummy, not zero.
    //    Before the RTL change every one of these read 0x00.
    // ---------------------------------------------------------------
    for (i = 0; i < 8; i = i + 1) begin
      read_window(1'b0, i[3:0], rdval);   // even: the low page
      if (rdval !== MACHINE_LOW_DUMMY) begin
        $display("       row %0d read 0x%02X", i, rdval);
        fail("the CG window's unused low page did not answer the machine's 0x8F");
      end
    end

    // ---------------------------------------------------------------
    // 3. The odd page is still the store and a write there still round-trips
    // ---------------------------------------------------------------
    @(negedge clk);
    cg_win_byte_sel = {1'b1, 4'd3};       // odd, row 3
    cg_win_din = 8'hA5;
    cg_win_we  = 1'b1;
    @(negedge clk);
    cg_win_we  = 1'b0;
    read_window(1'b1, 4'd3, rdval);
    if (rdval !== 8'hA5) begin
      $display("       read back 0x%02X, expected 0xA5", rdval);
      fail("a write to the odd page did not read back: the change broke the store path");
    end

    // ---------------------------------------------------------------
    // 4. The even page is still read-only (the machine dropped those writes)
    // ---------------------------------------------------------------
    @(negedge clk);
    cg_win_byte_sel = {1'b0, 4'd3};       // even, same row
    cg_win_din = 8'h5A;
    cg_win_we  = 1'b1;
    @(negedge clk);
    cg_win_we  = 1'b0;
    read_window(1'b0, 4'd3, rdval);
    if (rdval !== MACHINE_LOW_DUMMY) begin
      $display("       read back 0x%02X, expected the dummy 0x8F", rdval);
      fail("a write to the even page was accepted: the machine drops it and so must we");
    end

    // ---------------------------------------------------------------
    // 5. THE TWO STATUS BYTES ARE NOT THE SAME BYTE.
    //    Observed over a whole frame, because bit 0 of 0x60 is a live line and one sample cannot
    //    tell a live signal from a strap.
    // ---------------------------------------------------------------
    io_rd = 1'b1;
    for (i = 0; i < 1000; i = i + 1) begin
      @(negedge clk);
      io_addr = 8'h60; #1;
      bit0_60_seen_high = bit0_60_seen_high |  io_dout[0];
      bit0_60_seen_low  = bit0_60_seen_low  | ~io_dout[0];
      io_addr = 8'hA0; #1;
      if (io_dout[0] !== 1'b0)
        fail("0xA0 bit 0 was set: the machine's histogram shows it never moves there");
    end
    io_rd = 1'b0;

    // Non-vacuity: the check above only means something if 0x60's bit 0 in fact moves.
    if (!(bit0_60_seen_high && bit0_60_seen_low))
      fail("0x60 bit 0 never changed, so the 0xA0 comparison proved nothing about a live line");

    // ---------------------------------------------------------------
    // 6. Every other bit of the two bytes still agrees
    // ---------------------------------------------------------------
    io_rd = 1'b1;
    for (i = 0; i < 32; i = i + 1) begin
      @(negedge clk);
      io_addr = 8'h60; #1; b60 = io_dout;
      io_addr = 8'hA0; #1; bA0 = io_dout;
      if ((b60 & 8'hFE) !== (bA0 & 8'hFE))
        fail("0x60 and 0xA0 disagree on a bit other than bit 0");
    end
    io_rd = 1'b0;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GDC_CG_DUMMY: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GDC_CG_DUMMY: FAIL (%0d errors)", errors);
  end

  initial begin
    #4000000;
    $fatal(1, "TB_PC9821_GDC_CG_DUMMY: TIMEOUT");
  end

endmodule
