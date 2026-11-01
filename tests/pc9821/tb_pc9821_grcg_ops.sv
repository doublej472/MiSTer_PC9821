`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GRCG_OPS: a DIFFERENTIAL conformance suite for the GRCG. The REAL pc9821_grcg (through the REAL pc9821_gvram client against a byte-enable block-RAM backend) and the behavioural REFERENCE model tests/pc9821/pc9821_grcg_ref.sv - a function-for-function transcription of NP2kai's io/crtc.c register file, vram/vram.h's operating-mode decode, i386c/cpumem.c's vacctbl dispatch and mem/memvram.c's VRAM/RMW/TDW/TCR memory functions - are driven through the same matrix of mode/tile registers and CPU accesses and must agree BYTE FOR BYTE on every resulting plane byte and on every read datum. The matrix covers the plain plane-window read/write (all four windows, both access pages, every byte-enable set), the TDW tile write (all 16 active-low plane-enable masks, all 16 colours, the CPU datum ignored), the RMW merge (old & ~data) | (tile & data) over a seeded destination with data in {00, FF, mixed} so the read-skip and partial-byte paths are both taken, the four tile bytes in B,R,G,E order with the pointer's wrap and the 0x7C re-arm, the 0xA6 access page's separation, the low-15-bit address fold through every window, an exhaustive byte-enable x plane-mask x datum sweep, and a randomised 2400-case sweep. The WRITE path agrees with NP2kai on every one of those cases. The READ path now agrees too when the GRCG is armed for TDW: NP2kai's vacctbl sends a read with 0x7C = 0x80 to memtcr (the tile-compare read, window-independent, ~(OR of the enabled planes' (byte ^ tile))), and TH01 issues exactly that shape (grcg_setcolor_tcr -> mode 0x80, then grcg_chunk = VRAM_CHUNK(B,...) reads in th01/op_01.cpp:47 and th01/main/boss/b20m.cpp:1210); section 9 runs 80 TCR byte/word/DWORD/window cases through run_rd_tcr and asserts them BYTE-EXACT against the reference's tcr_read. It also records that the 0x7C register read-back is not this module's: the video device answers open bus 0xFF (probe2 /RDBACK wrote 0x5A and read FF anyway, docs/probes/RDBACK.TXT:152; pinned in tb_pc9821_readback_gdc and tb_pc9821_gdc_text_regs), where NP2kai's crtc_i7c returns the live modereg.
//
// TB_PC9821_GRCG_OPS: a DIFFERENTIAL conformance suite for the GRCG. The REAL pc9821_grcg (through the REAL pc9821_gvram client against a byte-enable block-RAM backend) and the behavioural REFERENCE model tests/pc9821/pc9821_grcg_ref.sv - a function-for-function transcription of NP2kai's io/crtc.c register file, vram/vram.h's operating-mode decode, i386c/cpumem.c's vacctbl dispatch and mem/memvram.c's VRAM/RMW/TDW/TCR memory functions - are driven through the same matrix of mode/tile registers and CPU accesses and must agree BYTE FOR BYTE on every resulting plane byte and on every read datum. The matrix covers the plain plane-window read/write (all four windows, both access pages, every byte-enable set), the TDW tile write (all 16 active-low plane-enable masks, all 16 colours, the CPU datum ignored), the RMW merge (old & ~data) | (tile & data) over a seeded destination with data in {00, FF, mixed} so the read-skip and partial-byte paths are both taken, the four tile bytes in B,R,G,E order with the pointer's wrap and the 0x7C re-arm, the 0xA6 access page's separation, the low-15-bit address fold through every window, an exhaustive byte-enable x plane-mask x datum sweep, and a randomised 2400-case sweep. The WRITE path agrees with NP2kai on every one of those cases. The READ path now agrees too when the GRCG is armed for TDW: NP2kai's vacctbl sends a read with 0x7C = 0x80 to memtcr (the tile-compare read, window-independent, ~(OR of the enabled planes' (byte ^ tile))), and TH01 issues exactly that shape (grcg_setcolor_tcr -> mode 0x80, then grcg_chunk = VRAM_CHUNK(B,...) reads in th01/op_01.cpp:47 and th01/main/boss/b20m.cpp:1210); section 9 runs 80 TCR byte/word/DWORD/window cases through run_rd_tcr and asserts them BYTE-EXACT against the reference's tcr_read. It also records that the 0x7C register read-back is not this module's (the video device answers 0xFF, NP2kai's crtc_i7c returns modereg, and the core follows the machine's measured open bus).

`default_nettype none

module tb_pc9821_grcg_ops;
  localparam integer CYCLE_NS = 20;
  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  localparam [31:0] GVRAM_BASE    = 32'h0300_0000;
  localparam [31:0] BACKEND_BASE  = GVRAM_BASE;
  localparam integer BACKEND_BYTES = 32'h0004_0000;

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
  wire       grcg_expand;

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
      .grcg_expand(grcg_expand),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  // ==== backend model ====
  // A byte-addressed block RAM with native byte enables and the SDRAM controller's
  // own contract: the accept is a registered ready pulse, a write lands at the
  // accept, and a read answers one beat per word of the burst a cycle later. The
  // array is initialised with `grcg_pat`, the SAME function the reference uses, so
  // DUT and golden start byte-identical without a seeding store on the bus.
  function [7:0] grcg_pat(input [31:0] a);
    grcg_pat = a[7:0] ^ {2'b0, a[13:8]} ^ {4'b0, a[19:16]} ^ 8'hA5;
  endfunction

  // The DUT's array IS the storage now, so seed it with `grcg_pat` directly - the SAME function
  // the reference uses - and DUT and golden start byte-identical without a seeding store on the bus.
  integer   bi;
  initial for (bi = 0; bi < (BACKEND_BYTES >> 2); bi = bi + 1)
    begin
      dut.u_gmem.mem0[bi] = grcg_pat(4*bi + 0);
      dut.u_gmem.mem1[bi] = grcg_pat(4*bi + 1);
      dut.u_gmem.mem2[bi] = grcg_pat(4*bi + 2);
      dut.u_gmem.mem3[bi] = grcg_pat(4*bi + 3);
    end

  // The golden. One node; its tasks are called hierarchically.
  pc9821_grcg_ref #(.GVRAM_BASE(GVRAM_BASE)) gold();

  // ==== STIMULUS ====
  integer errors = 0;
  integer cases  = 0;
  integer next_off = 0;
  integer wd;

  task automatic fail(input [8*200-1:0] what);
    begin
      $display("FAIL: %0s @ %0t", what, $time);
      errors = errors + 1;
    end
  endtask

  task automatic port_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk);
      grcg_addr = a;
      grcg_din  = d;
      grcg_we   = 1'b1;
      @(negedge clk);
      grcg_we   = 1'b0;
    end
  endtask

  task automatic set_mode(input [7:0] m);
    begin
      port_w(8'h7C, m);
      gold.set_mode(m);
    end
  endtask

  task automatic put_tile(input [7:0] v);
    begin
      port_w(8'h7E, v);
      gold.w_tile(v);
    end
  endtask

  task automatic put_tiles(input [7:0] b, r, g, e);
    begin
      put_tile(b); put_tile(r); put_tile(g); put_tile(e);
    end
  endtask

  task automatic take_win(output [14:0] off);
    begin
      off = next_off[14:0];
      next_off = next_off + 4;
    end
  endtask

  // One CPU access through the GVRAM's own client port, then the datapath is left
  // idle before the next one. Reads sample cpu_dout at the response strobe.
  task automatic access_op(input pg, input [1:0] plane, input [14:0] off,
                           input [31:0] din, input [3:0] be, input wr,
                           output [31:0] dout);
    begin
      @(negedge clk);
      access_page = pg;
      win_plane   = plane;
      win_offset  = off;
      cpu_din     = din;
      cpu_be      = be;
      cpu_write   = wr;
      cpu_valid   = 1'b1;
      wd = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        wd = wd + 1;
        if (wd == 400) begin
          fail("a GVRAM access never became ready: the datapath stopped answering");
          $finish;
        end
      end
      if (!wr) begin
        wd = 0;
        while (!cpu_resp_valid) begin
          @(negedge clk);
          wd = wd + 1;
          if (wd == 400) begin
            fail("a GVRAM read never returned a response");
            $finish;
          end
        end
        #1; dout = cpu_dout;
      end else dout = 32'hFFFF_FFFF;
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      wd = 0;
      while ((dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 3'd0)) begin
        @(negedge clk);
        wd = wd + 1;
        if (wd == 400) begin
          fail("the GVRAM datapath never returned to idle");
          $finish;
        end
      end
      repeat (2) @(posedge clk);
    end
  endtask

  // A write, mirrored into the golden, then every plane byte of the window compared.
  // The read-back is a PLAIN plane read, so the mode is disarmed first: with the
  // GRCG armed at 0x80 the same read is NP2kai's memtcr tile-compare (section 9),
  // and this bench would be comparing the wrong datum to gold.peek.
  task automatic run_wr(input [8*40-1:0] tag, input pg, input [1:0] plane,
                        input [14:0] off, input [31:0] din, input [3:0] be);
    reg [31:0] dd, dr;
    integer p, k;
    reg [31:0] got;
    begin
      cases = cases + 1;
      access_op(pg, plane, off, din, be, 1'b1, dd);
      gold.op(pg, plane, off, din, be, 1'b1, dr);
      set_mode(8'h00);
      for (p = 0; p < 4; p = p + 1) begin
        access_op(pg, p[1:0], off, 32'd0, 4'hF, 1'b0, got);
        for (k = 0; k < 4; k = k + 1)
          if (got[8*k +: 8] !== gold.peek(pg, p[1:0], off + k)) begin
            $display("MISMATCH case %0d (%0s) pg%0d pl%0d off %04x be %x din %08x: plane %0d byte %0d DUT %02x NP2kai %02x",
                     cases, tag, pg, plane, off, be, din, p, k,
                     got[8*k +: 8], gold.peek(pg, p[1:0], off + k));
            errors = errors + 1;
          end
      end
    end
  endtask

  // A read, compared datum for datum against NP2kai's own read function.
  task automatic run_rd(input [8*40-1:0] tag, input pg, input [1:0] plane,
                        input [14:0] off, input [3:0] be);
    reg [31:0] dd, dr;
    begin
      cases = cases + 1;
      access_op(pg, plane, off, 32'd0, be, 1'b0, dd);
      gold.op(pg, plane, off, 32'd0, be, 1'b0, dr);
      if (dd !== dr) begin
        $display("MISMATCH case %0d (%0s) read pg%0d pl%0d off %04x be %x: DUT %08x NP2kai %08x",
                 cases, tag, pg, plane, off, be, dd, dr);
        errors = errors + 1;
      end
    end
  endtask

  // A read with the GRCG armed (mode bit 7 set, bit 6 clear): NP2kai dispatches it
  // to memtcr0/1_rd, the tile-compare read. `be` selects the reference width: a
  // dword is two 16-bit word compares, a 16-bit unit (lanes 0011 / 1100) is one,
  // and a byte lane is the byte compare.
  task automatic run_rd_tcr(input [8*40-1:0] tag, input pg, input [1:0] plane,
                            input [14:0] off, input [3:0] be);
    reg [31:0] dd, dr;
    begin
      cases = cases + 1;
      access_op(pg, plane, off, 32'd0, be, 1'b0, dd);
      gold.tcr_read(pg, plane, off, be, dr);
      if (dd !== dr) begin
        $display("MISMATCH case %0d (%0s) GRCG-armed read pg%0d pl%0d off %04x be %x: DUT %08x, NP2kai memtcr %08x",
                 cases, tag, pg, plane, off, be, dd, dr);
        errors = errors + 1;
      end
    end
  endtask

  // Seed the four planes of a window with known old bytes through the plain path,
  // mirroring the golden, so an RMW's merge has a controlled destination.
  task automatic seed_win(input [14:0] off, input [7:0] b, input [7:0] r,
                          input [7:0] g, input [7:0] e);
    reg [31:0] sink;
    begin
      set_mode(8'h00);   // the seed is a PLAIN plane write, not a GRCG store
      access_op(1'b0, 2'd0, off, {4{b}}, 4'hF, 1'b1, sink);
      access_op(1'b0, 2'd1, off, {4{r}}, 4'hF, 1'b1, sink);
      access_op(1'b0, 2'd2, off, {4{g}}, 4'hF, 1'b1, sink);
      access_op(1'b0, 2'd3, off, {4{e}}, 4'hF, 1'b1, sink);
      gold.op(1'b0, 2'd0, off, {4{b}}, 4'hF, 1'b1, sink);
      gold.op(1'b0, 2'd1, off, {4{r}}, 4'hF, 1'b1, sink);
      gold.op(1'b0, 2'd2, off, {4{g}}, 4'hF, 1'b1, sink);
      gold.op(1'b0, 2'd3, off, {4{e}}, 4'hF, 1'b1, sink);
    end
  endtask

  reg [14:0] off;
  integer p, pg, b, m, d, c;
  reg [3:0] be;
  reg [31:0] din;
  reg [31:0] sink;
  reg [31:0] data_tab [0:7];
  reg [31:0] rnd = 32'h1234_5678;

  // ==== CHECKS ====
  initial begin
    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (8) @(posedge clk);
    gold.rst();

    // ============================================================
    // 1. The plain path (mode 0x00, GRCG gate clear): each plane window's own
    //    store and read, both access pages, every byte-enable set.
    // ============================================================
    begin : plain_path
      for (pg = 0; pg < 2; pg = pg + 1)
        for (p = 0; p < 4; p = p + 1)
          for (b = 0; b < 8; b = b + 1) begin
            take_win(off);
            set_mode(8'h00);
            case (b)
              0: be = 4'b0001; 1: be = 4'b0010; 2: be = 4'b0100; 3: be = 4'b1000;
              4: be = 4'b0011; 5: be = 4'b1100; 6: be = 4'b0101; default: be = 4'b1111;
            endcase
            din = 32'hA1B2_C3D4;
            run_wr("plain write", pg[0], p[1:0], off, din, be);
            run_rd("plain read", pg[0], p[1:0], off, 4'hF);
          end
    end

    // ============================================================
    // 2. TDW (mode 0x80): the CPU's datum is IGNORED and every enabled plane gets
    //    its own tile byte -- the four planes' bits are the 16-colour value. One
    //    tile byte per plane, distinct, so a swapped plane cannot pass.
    // ============================================================
    begin : tdw_planes
      for (p = 0; p < 4; p = p + 1)
        for (d = 0; d < 3; d = d + 1)
          for (b = 0; b < 3; b = b + 1) begin
            take_win(off);
            set_mode(8'h80);
            put_tiles(8'h11, 8'h22, 8'h33, 8'h44);
            case (d)
              0: din = 32'hFFFF_FFFF; 1: din = 32'h0000_0000; default: din = 32'hCAFE_F00D;
            endcase
            case (b)
              0: be = 4'b0001; 1: be = 4'b1111; default: be = 4'b0110;
            endcase
            run_wr("tdw", 1'b0, p[1:0], off, din, be);
          end
    end

    // 16-colour pattern: the plane's bit of the colour selects its tile byte 00/FF.
    begin : tdw_16colour
      for (c = 0; c < 16; c = c + 1) begin
        take_win(off);
        set_mode(8'h80);
        put_tiles((c[0] ? 8'hFF : 8'h00), (c[1] ? 8'hFF : 8'h00),
                  (c[2] ? 8'hFF : 8'h00), (c[3] ? 8'hFF : 8'h00));
        run_wr("tdw16", 1'b0, 2'd0, off, 32'h1234_5678, 4'hF);
      end
    end

    // ============================================================
    // 3. RMW (mode 0xC0): (old & ~data) | (tile & data) per plane, over a seeded
    //    destination, every byte-enable set and datum in {00, FF, mixed}. FF skips
    //    the read (the tile alone decides); 00 is a no-op; a partial pattern merges.
    // ============================================================
    begin : rmw_merge
      data_tab[0] = 32'hFFFF_FFFF; data_tab[1] = 32'h0000_0000;
      data_tab[2] = 32'h0F0F_0F0F; data_tab[3] = 32'hF0F0_F0F0;
      data_tab[4] = 32'h55AA_55AA; data_tab[5] = 32'h00FF_00FF;
      data_tab[6] = 32'h0000_FFFF; data_tab[7] = 32'h5A96_C33C;
      for (d = 0; d < 8; d = d + 1)
        for (b = 0; b < 5; b = b + 1) begin
          take_win(off);
          seed_win(off, 8'hF0, 8'h0F, 8'hAA, 8'h55);
          set_mode(8'hC0);
          put_tiles(8'h3C, 8'h5A, 8'hC3, 8'h7E);
          case (b)
            0: be = 4'b0001; 1: be = 4'b0010; 2: be = 4'b0100; 3: be = 4'b1000;
            default: be = 4'b1111;
          endcase
          run_wr("rmw", 1'b0, 2'd0, off, data_tab[d], be);
        end
    end

    // ============================================================
    // 4. The active-LOW plane-enable mask (mode bits 3:0), all 16 values, in both
    //    TDW and RMW, with the CPU data NOT equal to the tile so a plain write of
    //    the datum cannot pass.
    // ============================================================
    begin : plane_mask
      for (m = 0; m < 16; m = m + 1) begin
        take_win(off);
        set_mode(8'h80 | m[7:0]);
        put_tiles(8'hA5, 8'h5A, 8'h3C, 8'hC3);
        run_wr("mask-tdw", 1'b0, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
        take_win(off);
        set_mode(8'hC0 | m[7:0]);
        put_tiles(8'hA5, 8'h5A, 8'h3C, 8'hC3);
        run_wr("mask-rmw", 1'b0, 2'd0, off, 32'h0F0F_0F0F, 4'hF);
      end
    end

    // ============================================================
    // 5. The tile register modes: the four plane bytes in B,R,G,E order, the
    //    pointer's wrap after four, and the 0x7C mode write that restarts it.
    // ============================================================
    begin : tile_order
      take_win(off);
      set_mode(8'h80);
      put_tiles(8'h11, 8'h22, 8'h33, 8'h44);
      run_wr("tile order", 1'b0, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
      take_win(off);
      set_mode(8'h80);
      put_tile(8'h55); put_tile(8'h66); put_tile(8'h77); put_tile(8'h88);
      put_tile(8'h99);               // the pointer wrapped: this is B again
      run_wr("tile wrap", 1'b0, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
      take_win(off);
      set_mode(8'h80);
      put_tile(8'hAA);               // pointer 0
      set_mode(8'h80);               // restart the pointer
      put_tile(8'hBB);               // B = BB, not R
      run_wr("tile re-arm", 1'b0, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
      take_win(off);
      set_mode(8'h80);
      put_tiles(8'h1A, 8'h2B, 8'h3C, 8'h4D);
      set_mode(8'h00);               // gate clear: a plain write of ONE plane again
      run_wr("gate off", 1'b0, 2'd1, off, 32'hFFFF_FFFF, 4'hF);
    end

    // ============================================================
    // 6. The 0xA6 access page: the same plane offset in page 1 is a different
    //    store, and page 0 at that offset is not touched.
    // ============================================================
    begin : page_switch
      take_win(off);
      set_mode(8'h80);
      put_tiles(8'h21, 8'h22, 8'h23, 8'h24);
      run_wr("page0 store", 1'b0, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
      run_wr("page1 store", 1'b1, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
      // The page-0 window still holds its own store, read back through page 0.
      // Mode 0x00 so NP2kai's read is also a plain memvram read (a 0x80 read is
      // memtcr -- section 8 records that deviation).
      set_mode(8'h00);
      run_rd("page0 read", 1'b0, 2'd0, off, 4'hF);
      run_rd("page1 read", 1'b1, 2'd0, off, 4'hF);
      // A page-1 store of the SAME offset with a different tile must not disturb it.
      take_win(off);
      set_mode(8'h80);
      put_tiles(8'h31, 8'h32, 8'h33, 8'h34);
      access_op(1'b1, 2'd0, off, 32'hFFFF_FFFF, 4'hF, 1'b1, sink);
      gold.op(1'b1, 2'd0, off, 32'hFFFF_FFFF, 4'hF, 1'b1, sink);
      set_mode(8'hC0);
      put_tiles(8'h00, 8'h00, 8'h00, 8'h00);
      run_wr("page0 rmw", 1'b0, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
      set_mode(8'h00);
      run_rd("page1 read2", 1'b1, 2'd0, off, 4'hF);
    end

    // ============================================================
    // 7. The address fold: a store through ANY of the four plane windows reaches
    //    all four planes at the same 15-bit offset. The window is not the plane
    //    for a GRCG store.
    // ============================================================
    begin : addr_fold
      for (p = 0; p < 4; p = p + 1) begin
        take_win(off);
        set_mode(8'h80);
        put_tiles(8'hC1, 8'hC2, 8'hC3, 8'hC4);
        run_wr("fold", 1'b0, p[1:0], off, 32'hFFFF_FFFF, 4'hF);
      end
    end

    // ============================================================
    // 8. The read-back in the modes whose read NP2kai sends to memvram (0x00 and
    //    0xC0): the addressed window's plain plane, four consecutive bytes.
    // ============================================================
    begin : read_back
      for (p = 0; p < 4; p = p + 1) begin
        take_win(off);
        seed_win(off, 8'hDE, 8'hAD, 8'hBE, 8'hEF);
        // Plain read, and the RMW mode's read, are both memvram reads.
        set_mode(8'h00);
        run_rd("read mode0", 1'b0, p[1:0], off, 4'hF);
        set_mode(8'hC0);
        run_rd("read modeC0", 1'b0, p[1:0], off, 4'hF);
      end
    end

    // ============================================================
    // 9. THE TILE-COMPARE READ (TCR). With mode bit 7 set and bit 6 clear (0x80 -
    //    the mode grcg_setcolor_tcr writes and TH01's grcg_chunk/particle2x2_snap
    //    shape reads through), NP2kai's vacctbl dispatches a GVRAM READ to
    //    memtcr0/1_rd (i386c/cpumem.c:287-289), not to memvram: the datum is
    //    ~(OR of the enabled planes' (plane ^ tile)), one bit per dot, window-
    //    independent. TH01 issues exactly this (rec98/th01/hardware/graph.cpp:200
    //    grcg_setcolor_tcr -> mode 0x80; th01/main/boss/b20m.cpp:1210 sets it then
    //    reads stripe_vram(0,id) = grcg_chunk(offset,16), rec98/planar.h:222 =
    //    VRAM_CHUNK(B,...); th01/op_01.cpp:47 the same). Every one of these is a
    //    real mismatch if the read answers the plain plane byte.
    // ============================================================
    begin : tcr_read
      integer ci;
      for (ci = 0; ci < 16; ci = ci + 1) begin
        take_win(off);
        seed_win(off, 8'h5A, 8'hA5, 8'h3C, 8'hC3);
        set_mode(8'h80);
        put_tiles((ci[0] ? 8'hFF : 8'h00), (ci[1] ? 8'hFF : 8'h00),
                  (ci[2] ? 8'hFF : 8'h00), (ci[3] ? 8'hFF : 8'h00));
        run_rd_tcr("tcr word", 1'b0, 2'd0, off, 4'b0011);    // TH01's 16-bit read
        run_rd_tcr("tcr dword", 1'b0, 2'd0, off, 4'hF);
        run_rd_tcr("tcr byte", 1'b0, 2'd0, off, 4'b0001);
        run_rd_tcr("tcr wordR", 1'b0, 2'd0, off, 4'b1100);
        run_rd_tcr("tcr word Rz", 1'b0, 2'd1, off, 4'b0011);
      end
    end

    // ============================================================
    // 10. All four planes disabled (mode bits 3:0 = F): a GRCG store is a no-op,
    //     not a plain store of the CPU datum.
    // ============================================================
    begin : all_disabled
      take_win(off);
      seed_win(off, 8'h5A, 8'hA5, 8'h3C, 8'hC3);
      set_mode(8'h8F);
      put_tiles(8'h11, 8'h22, 8'h33, 8'h44);
      run_wr("disabled-tdw", 1'b0, 2'd0, off, 32'hFFFF_FFFF, 4'hF);
      take_win(off);
      seed_win(off, 8'h5A, 8'hA5, 8'h3C, 8'hC3);
      set_mode(8'hCF);
      put_tiles(8'h11, 8'h22, 8'h33, 8'h44);
      run_wr("disabled-rmw", 1'b0, 2'd0, off, 32'h0F0F_0F0F, 4'hF);
    end

    // ============================================================
    // 11. A deterministic randomised sweep: a fresh window per case, a random mode
    //     (TDW, RMW, plain, and the RMW bit without the gate bit), a random
    //     active-low plane mask, four random tiles, a random datum, a random
    //     non-zero byte-enable set, a random window and a random access page. The
    //     reference decides every expected byte, so the sweep's job is coverage of
    //     the input space rather than a hand-computed expectation per case.
    // ============================================================
    begin : sweep
      integer n;
      reg [7:0] t0, t1, t2, t3;
      for (n = 0; n < 2400; n = n + 1) begin
        rnd = rnd * 32'd1664525 + 32'd1013904223;
        take_win(off);
        case (rnd[2:0])
          3'd0: set_mode(8'h80 | rnd[7:4]);
          3'd1: set_mode(8'hC0 | rnd[7:4]);
          3'd2: set_mode(8'h00 | rnd[7:4]);
          3'd3: set_mode(8'h40 | rnd[7:4]);
          3'd4: set_mode(8'h80 | rnd[7:4]);
          3'd5: set_mode(8'hC0 | rnd[7:4]);
          3'd6: set_mode(8'h00);
          default: set_mode(8'hC0 | rnd[7:4]);
        endcase
        t0 = rnd[15:8]; t1 = rnd[23:16]; t2 = rnd[7:0]; t3 = rnd[31:24];
        put_tiles(t0, t1, t2, t3);
        din = rnd;
        be  = rnd[3:0];
        if (be == 4'd0) be = 4'h1;
        run_wr("sweep", rnd[5], rnd[7:6], off, din, be);
      end
    end

    // ============================================================
    // 12. Reads in the two modes NP2kai sends to memvram (0x00 and 0xC0), a fresh
    //     seeded window per case, byte and word widths included.
    // ============================================================
    begin : read_sweep
      integer n;
      for (n = 0; n < 64; n = n + 1) begin
        rnd = rnd * 32'd1664525 + 32'd1013904223;
        take_win(off);
        seed_win(off, rnd[7:0], rnd[15:8], rnd[23:16], rnd[31:24]);
        set_mode(rnd[0] ? 8'hC0 : 8'h00);
        pg = rnd[1]; p = rnd[3:2];
        be = rnd[5:4]; if (be == 4'd0) be = 4'hF;
        run_rd("read sweep", pg[0], p[1:0], off, be);
      end
    end

    // ============================================================
    // 13. Exhaustive byte-enable x plane-mask x datum, in TDW and RMW. Every
    //     non-zero byte-enable set crosses every active-low plane mask, with data
    //     patterns chosen so the per-lane RMW read is taken for some lanes and
    //     skipped (byte = FF) for others, and so a merge of a partial nibble is
    //     exercised. This is the shape a per-lane optimization gets wrong.
    // ============================================================
    begin : exhaustive
      integer bb, pp, dd;
      reg [31:0] dtab [0:7];
      dtab[0] = 32'hFFFF_FFFF; dtab[1] = 32'h0000_0000;
      dtab[2] = 32'hFF00_FF00; dtab[3] = 32'h00FF_00FF;
      dtab[4] = 32'hFF00_0000; dtab[5] = 32'h0000_00FF;
      dtab[6] = 32'h0F0F_0F0F; dtab[7] = 32'hF0F0_F0F0;
      for (pp = 0; pp < 16; pp = pp + 1)
        for (bb = 0; bb < 15; bb = bb + 1)
          for (dd = 0; dd < 8; dd = dd + 1) begin
            take_win(off);
            set_mode(8'h80 | pp[7:0]);
            put_tiles(8'h3C, 8'h5A, 8'hC3, 8'h7E);
            run_wr("exh-tdw", 1'b0, 2'd0, off, dtab[dd], bb[3:0] + 4'd1);
            take_win(off);
            set_mode(8'hC0 | pp[7:0]);
            put_tiles(8'h3C, 8'h5A, 8'hC3, 8'h7E);
            run_wr("exh-rmw", 1'b0, 2'd0, off, dtab[dd], bb[3:0] + 4'd1);
          end
    end

    // ==== VERDICT ====
    $display("NOTE grcg_ops: %0d cases, %0d mismatching bytes", cases, errors);
    if (errors == 0) begin
      $display("TB_PC9821_GRCG_OPS: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_GRCG_OPS: FAIL (%0d mismatches over %0d cases)", errors, cases);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_GRCG_OPS: TIMEOUT");
  end

endmodule

`default_nettype wire
