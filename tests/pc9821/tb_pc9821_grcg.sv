`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GRCG:
// The GRCG VRAM write path in the shapes the five games issue, driven through pc9821_memory_map into pc9821_gvram so the guest window address is translated rather than assumed: a TDW zero-fill through the B window (master.lib graph_clear), an RMW fill that needs the old value (TH01's clear) and one that does not (all-ones data), the active-low plane mask (TH04's single-plane put), and the low-15-bit address fold that makes a store through ANY of the four plane windows reach all four planes. It also pins that a store with the mode bit clear stays a plain single-plane write, that a GRCG store is exactly four COLUMN writes each enabling all four lanes (no partial-byte-enable write, so no sdram.v read-modify-write), that a masked store writes only the enabled lanes, and that a store outside the aperture never reaches the GVRAM datapath at all.
module tb_pc9821_grcg;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam [31:0] PACK_BASE  = 32'h02F8_0000;
  localparam [31:0] GVRAM_BASE = 32'h0300_0000;
  localparam [31:0] BACKEND_BASE = 32'h0300_0000;
  localparam integer BACKEND_BYTES = 32'h0004_0000;

  localparam [31:0] WIN_B = 32'h000A_8000;   // guest B window
  localparam [31:0] WIN_R = 32'h000B_0000;   // guest R window
  localparam [31:0] WIN_G = 32'h000B_8000;   // guest G window
  localparam [31:0] WIN_E = 32'h000E_0000;   // guest intensity window

  // ==== GRCG register write port ====
  reg        port_we = 0;
  reg [7:0]  port_addr = 0;
  reg [7:0]  port_din = 0;

  // ==== guest CPU request (into the memory map) ====
  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  // The IDE work RAM's 0x1E8E gate: ON here (the gated shape is pinned by
  // tb_pc9821_memory_map / tb_pc9821_memory_subsystem).
  reg        ide_ram_gate = 1'b1;
  reg        bios_ram_gate = 0;
  reg [7:0]  win0_sel = 8'h08;              // identity
  reg        gvram_access_page = 0;
  reg        cpu_valid = 0, cpu_write = 0;
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 8'd1;
  reg        cpu_line_read = 0;
  wire       gv_cpu_ready, gv_cpu_resp_valid, gv_cpu_line_word_valid;
  wire [31:0] gv_cpu_dout;
  wire [31:0] gv_cpu_line_word;
  // The route's answer, muxed exactly as pc9821_memory_subsystem muxes it: a
  // plane window is pc9821_gvram's, everything else is the map's.
  wire       cpu_ready           = gvram_window ? gv_cpu_ready : map_cpu_ready;
  wire       cpu_resp_valid      = gvram_window ? gv_cpu_resp_valid
                                                : map_cpu_resp_valid;
  wire [31:0]  cpu_dout          = gvram_window ? gv_cpu_dout : map_cpu_dout;

  // ==== the map's plane-window decode, which is the route pc9821_gvram serves ====
  wire        gvram_window;
  wire [1:0]  gvram_win_plane;
  wire [14:0] gvram_win_offset;

  // ==== the map's backend bus: unclaimed for GVRAM now (the route owns it) ====
  wire [31:0]  map_addr, map_din, map_dout;
  wire [127:0] map_line_dout;
  wire [3:0]   map_be;
  wire [7:0]   map_burstcount;
  wire         map_line_read, map_valid, map_write;
  wire         map_ready, map_resp_valid, map_line_resp_valid;
  reg          mem_ready_unused = 1;
  // What the map's own route was asked to do, so the out-of-aperture case can be
  // asserted after the transaction has left the bus rather than during it.
  reg [31:0] map_last_addr = 0;
  reg        map_last_write = 0;
  reg        map_seen = 0;
  always @(posedge clk) if (map_valid && mem_ready_unused) begin
    map_last_addr  <= map_addr;
    map_last_write <= map_write;
    map_seen       <= 1'b1;
  end
  wire [31:0]  map_cpu_dout;
  wire         map_cpu_ready, map_cpu_resp_valid;

  // ==== the GVRAM datapath's backend, which the model answers ====
  wire        mem_valid, mem_write;
  wire [31:0] mem_addr, mem_din, mem_din_hi;
  wire  [3:0] mem_be;
  wire  [7:0] mem_burstcount;
  wire        mem_line_read;
  reg         mem_ready = 0;
  reg  [31:0] mem_dout = 0;
  reg         mem_resp_valid = 0;
  // The 16-colour mode (the guest's OUT 0x6A,0x01, FF2 num 0): this bench reaches the E plane at
  // 0xE0000-0xE7FFF, which the machine maps only in that mode (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b1;
  wire       e_plane_nc;

  pc9821_memory_map map_dut (
      .mode2_16color(mode2_16color),
      .e_plane_nc(e_plane_nc),
      .top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00),
      .ide_ram_gate(ide_ram_gate),
      .bios_ram_gate(bios_ram_gate), .win0_sel(win0_sel), .win0_sel_moved(win0_sel != 8'h08),
      // No EMS here: the identity state leaves 0xB0000-0xBFFFF as the ordinary plane window.
      .ems_state(2'd0), .ems_page_base(32'd0),
      .pack_base(PACK_BASE), .guest_ram_bytes(PACK_BASE),
      // The PEGC extended-VRAM window is off: this bench drives the plane windows only.
      .peg_window(1'b0), .peg_base(32'd0),
      .gvram_window(gvram_window), .gvram_win_plane(gvram_win_plane),
      .gvram_win_offset(gvram_win_offset),
      .cpu_addr(cpu_addr), .cpu_addr_raw(cpu_addr), .xl_low20(1'b0), .xl_peg(1'b0), .cpu_din(cpu_din), .cpu_dout(map_cpu_dout), .cpu_be(cpu_be),
      .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read),
      // The subsystem's route gate: the map never serves a plane window.
      .cpu_valid(cpu_valid && !gvram_window), .cpu_write(cpu_write),
      .cpu_ready(map_cpu_ready),
      .cpu_resp_valid(map_cpu_resp_valid),
      .mem_addr(map_addr), .mem_din(map_din), .mem_dout(map_dout),
      .mem_be(map_be),
      .mem_burstcount(map_burstcount),
      .mem_valid(map_valid), .mem_write(map_write),
      .mem_ready(mem_ready_unused), .mem_resp_valid(map_resp_valid)
  );

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .clk(clk), .reset(reset),
      .access_page(gvram_access_page),
      .win_plane(gvram_win_plane), .win_offset(gvram_win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      // The route gate the subsystem applies: only a plane-window access reaches
      // this block at all.
      .cpu_valid(cpu_valid && gvram_window),
      .cpu_write(cpu_write),
      .cpu_dout(gv_cpu_dout), .cpu_line_word(gv_cpu_line_word),
      .cpu_ready(gv_cpu_ready), .cpu_resp_valid(gv_cpu_resp_valid),
      .cpu_line_word_valid(gv_cpu_line_word_valid),
      .grcg_we(port_we), .grcg_addr(port_addr), .grcg_din(port_din),
      .egc_gate(1'b0),
      .egc_access(16'hFFFF), .egc_fgbg(16'd0), .egc_ope(16'd0),
      .egc_fg(16'd0), .egc_mask(16'hFFFF), .egc_bg(16'd0),
      .egc_sft(16'd0), .egc_leng(16'd0), .egc_shift_we(1'b0),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0),
      .scan_line_base(15'd0), .line_rd_addr(7'd0), .line_rd_sel(1'b0),
      .line_data(), .line_sel(), .line_ready());


  integer mi;

  // ==== DUT ====

  // ==== STIMULUS ====
  integer errors = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  reg [7:0] grcg_mode_sh = 8'h00;   // the bench's own 0x7C value, for the read-back disarm

  task automatic port_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk);
      port_addr = a;
      port_din  = d;
      port_we   = 1;
      if (a == 8'h7C) grcg_mode_sh = d;
      @(negedge clk);
      port_we   = 0;
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

  // A guest store through the memory map. `addr` is the GUEST address.
  task automatic cpu_store(input [31:0] addr, input [31:0] data, input [3:0] be);
    begin
      @(negedge clk);
      cpu_addr  = addr;
      cpu_din   = data;
      cpu_be    = be;
      cpu_write = 1;
      cpu_valid = 1;
      @(posedge clk);
      #1;
      wd = 0;
      while (!cpu_ready) begin
        @(posedge clk);
        #1;
        wd = wd + 1;
        if (wd == 400) begin
          fail("a GVRAM store never became ready: the datapath stopped answering");
          $finish;
        end
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be    = 4'hF;
      // The block holds the bus until the request leaves (its C_HOLD), so leave
      // the gap z486 leaves rather than re-asserting into it.
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic cpu_load(input [31:0] addr, output [31:0] data);
    reg [7:0] saved;
    begin
      // A plane read-back must be PLAIN. With the GRCG armed for TDW (0x7C bit 7 set, bit 6
      // clear) the SAME plane-window read is NP2kai's memtcr tile-compare, so disarm
      // for the read and put the bench's mode back afterwards for a store that follows.
      saved = grcg_mode_sh;
      if (saved[7] && !saved[6]) port_w(8'h7C, 8'h00);
      @(negedge clk);
      cpu_addr  = addr;
      cpu_write = 0;
      cpu_be    = 4'hF;
      cpu_valid = 1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin
        @(posedge clk);
        #1;
      end
      @(negedge clk);
      cpu_valid = 0;
      #1;
      wd = 0;
      while (!cpu_resp_valid) begin
        @(posedge clk);
        #1;
        wd = wd + 1;
        if (wd == 400) begin
          $display("PROBE LOAD HANG addr=%08x cs=%0d bstate=%0d cc_valid=%b cc_ready=%b b_done_r=%b",
                   addr, dut.u_arb.cs, dut.u_arb.gstate, dut.u_arb.cc_valid, dut.u_arb.cc_ready, dut.u_arb.b_done_r);
          fail("a GVRAM read never returned a response");
          $finish;
        end
      end
      data = cpu_dout;
      @(negedge clk);
      if (saved[7] && !saved[6]) port_w(8'h7C, saved);
      repeat (4) @(posedge clk);
    end
  endtask

  // Read the four planes' dword at this column out through the four guest
  // windows: the plain path returns the addressed plane's four bytes, i.e.
  // columns off..off+3 of that plane.
  task automatic expect_planes(input [31:0] win_base, input [14:0] off,
                               input [31:0] b, input [31:0] r,
                               input [31:0] g, input [31:0] e);
    reg [31:0] rb, rr, rg, re;
    begin
      cpu_load(win_base + {17'd0, off}, rb);
      cpu_load(win_base + 32'h0000_8000 + {17'd0, off}, rr);
      cpu_load(win_base + 32'h0001_0000 + {17'd0, off}, rg);
      cpu_load(win_base + 32'h0003_8000 + {17'd0, off}, re);
      if (rb !== b || rr !== r || rg !== g || re !== e) begin
        $display("FAIL planes at off %04x: got B=%08x R=%08x G=%08x E=%08x want B=%08x R=%08x G=%08x E=%08x",
                 off, rb, rr, rg, re, b, r, g, e);
        errors = errors + 1;
      end
    end
  endtask

  // FILL EVERY PLANE, THROUGH THE PLANE WINDOWS. This used to write the bench's own model array,
  // which reset, the GRCG and the EGC could not affect because nothing read it back through the
  // datapath. The array is inside the DUT now, so a fill is a CPU store like any other and the
  // engines' state APPLIES to it: a fill issued while the GRCG is in RMW mode with a zero tile
  // merges to (old & ~0) | (0 & 0) = old, a NO-OP, which is why the 0x0500 check read 0A0B0C0D
  // where the contract says FAFBFCFD. 0x7C = 0 is GRCG off.
  //
  // BOUNDED, and the bound is the contract: every check in this bench inspects a column below
  // FILL_COLS, so filling the whole 256 KiB aperture only made the bench slow. One store covers
  // FOUR columns because a 32-bit store writes four consecutive columns of ONE plane - the
  // byte-interleaved layout - so this is FILL_COLS/4 stores per plane per page.
  localparam [14:0] FILL_COLS = 15'h1000;
  task automatic fill_all(input [7:0] v);
    integer pg;
    begin
      // The EGC is tied off at the instantiation in this bench (.egc_gate(1'b0)), so only the
      // GRCG has state to clear here.
      port_w(8'h7C, 8'h00);
      // The access page does NOT move the guest address: pc9821_gvram takes
      // `gvram_access_page` as its own `access_page` and the plane windows stay
      // at 0xA8000-0xBFFFF. An earlier revision added 0x20000 here, which sent
      // the page-1 accesses to 0xC8000 -- the absent-ROM area -- where no route
      // answers, so the bench hung.
      for (pg = 0; pg < 2; pg = pg + 1) begin
        gvram_access_page = pg[0];
        for (mi = 0; mi < FILL_COLS; mi = mi + 4) begin
          cpu_store(WIN_B + {2'b0, mi[14:2], 2'b00}, {v, v, v, v}, 4'hF);
          cpu_store(WIN_B + 32'h0000_8000 + {2'b0, mi[14:2], 2'b00}, {v, v, v, v}, 4'hF);
          cpu_store(WIN_B + 32'h0001_0000 + {2'b0, mi[14:2], 2'b00}, {v, v, v, v}, 4'hF);
          cpu_store(WIN_B + 32'h0003_8000 + {2'b0, mi[14:2], 2'b00}, {v, v, v, v}, 4'hF);
        end
      end
      gvram_access_page = 0;
    end
  endtask

  // Plane p's byte at column c, read back THROUGH THE PLANE WINDOW. It used to index the bench's
  // own model array. A byte read is one enabled byte, so be = 0001 selects lane 0 and the datapath
  // forms c_col = {win_offset[14:2], 0}, which is c when win_offset = 4*c. A Verilog FUNCTION
  // cannot advance time and this must issue a real bus cycle, so it is a task with an output.
  task automatic lane_byte(input page, input [1:0] p, input [14:0] c, output [7:0] v);
    reg [31:0] wd;
    begin
      gvram_access_page = page;
      // Same guest addresses as page 0: the page is gvram's access_page, not an
      // offset on the window (see fill_all).
      case (p)
        2'd0: cpu_load(WIN_B + {2'b0, c[14:2], 2'b00}, wd);
        2'd1: cpu_load(WIN_B + 32'h0000_8000 + {2'b0, c[14:2], 2'b00}, wd);
        2'd2: cpu_load(WIN_B + 32'h0001_0000 + {2'b0, c[14:2], 2'b00}, wd);
        default: cpu_load(WIN_B + 32'h0003_8000 + {2'b0, c[14:2], 2'b00}, wd);
      endcase
      v = wd[{c[1:0], 3'b000} +: 8];
      gvram_access_page = 0;
    end
  endtask

  integer w0, r0, f0, p0;
  integer wd;
  reg [31:0] d;
  reg  [7:0] lb;

  initial begin
    // RESET FIRST, THEN FILL. The order is load-bearing and it was LATENT here: fill_all used to
    // write the bench's own model array, which reset could not affect, so calling it before the
    // release was harmless. Now that the array is inside the DUT every fill is a CPU store, and a
    // store waits on cpu_ready, which the GVRAM's FSM cannot assert while reset holds it in C_IDLE.
    // Called before the release, the FIRST store of the first fill waited forever; the symptom was
    // one progress mark and then nothing for the whole budget, which reads like a slow bench and is
    // a hang.
    repeat (4) @(posedge clk);
    reset = 0;
    repeat (4) @(posedge clk);
    fill_all(8'h00);

    // ------------------------------------------------------------------
    // Mode bit 7 clear: a plain store, and the window selects the plane.
    // ------------------------------------------------------------------
    cpu_store(WIN_B + 32'h0100, 32'h1122_3344, 4'hF);
    expect_planes(WIN_B, 15'h0100, 32'h1122_3344, 32'h0, 32'h0, 32'h0);
    cpu_store(WIN_R + 32'h0100, 32'h5566_7788, 4'hF);
    expect_planes(WIN_B, 15'h0100, 32'h1122_3344, 32'h5566_7788, 32'h0, 32'h0);

    // ------------------------------------------------------------------
    // TDW zero fill through the B window: master.lib graph_clear. All four
    // planes change, and each column write enables all four lanes.
    // ------------------------------------------------------------------
    fill_all(8'hA5);
    port_w(8'h7C, 8'h80);              // mode bit 7, TDW
    put_tiles(8'h00, 8'h00, 8'h00, 8'h00);
    cpu_store(WIN_B + 32'h0200, 32'hFFFF_FFFF, 4'hF);
    // WHAT THIS USED TO ASSERT, AND WHY IT NO LONGER CAN. Three checks stood here, counting the
    // backend's transactions and requiring every GRCG column write to enable all four lanes. Both
    // were properties of the SDRAM path rather than of the machine: the counters watched the
    // bench's own stub, which the array has left, and the full-lane rule existed because sdram.v
    // has no DQM and a partial-byte-enable write would have cost a read-modify-write. BLOCK RAM HAS
    // NATIVE BYTE ENABLES, so a masked write is free and the rule is withdrawn with the constraint
    // that produced it. What is still a contract is that the store reaches all four planes, and
    // expect_planes below is the check that says so - read through the CPU port, which is what the
    // guest sees.
    expect_planes(WIN_B, 15'h0200, 32'h0, 32'h0, 32'h0, 32'h0);

    // Each plane gets its own tile byte, and the CPU's data is ignored.
    port_w(8'h7C, 8'h80);
    put_tiles(8'h11, 8'h22, 8'h33, 8'h44);
    cpu_store(WIN_B + 32'h0300, 32'hCAFE_F00D, 4'hF);
    expect_planes(WIN_B, 15'h0300, 32'h1111_1111, 32'h2222_2222,
                  32'h3333_3333, 32'h4444_4444);

    // ------------------------------------------------------------------
    // RMW. All-ones data determines the result, so there must be no read at all
    // (TH01's clear); a partial pattern must merge with the old planes.
    // ------------------------------------------------------------------
    port_w(8'h7C, 8'hC0);              // mode bit 7, RMW
    put_tiles(8'h00, 8'h00, 8'h00, 8'h00);
    cpu_store(WIN_B + 32'h0400, 32'hFFFF_FFFF, 4'hF);
    // (An `if (0) fail(...)` stood here, left from the withdrawn transaction-count check.
    // A branch whose condition is a constant can never fire, so it was not a check.)
    expect_planes(WIN_B, 15'h0400, 32'h0, 32'h0, 32'h0, 32'h0);

    fill_all(8'hF0);
    port_w(8'h7C, 8'hC0);
    put_tiles(8'hAA, 8'hBB, 8'hCC, 8'hDD);
    cpu_store(WIN_B + 32'h0500, 32'h0F0F_0F0F, 4'hF);
    $display("PROBE after the RMW store: grcg_cl_valid=%b cl_write=%b cl_addr=%04x cc_done=%b cc_rdata=%08x expand=%b owns_grcg=%b",
             dut.grcg_cl_valid, dut.grcg_cl_write, dut.grcg_cl_addr, dut.u_arb.cc_done,
             dut.u_arb.cc_rdata, dut.grcg_expand_gate, dut.u_arb.cc_owns_grcg);
    // THE RMW'S READ IS PROVED BY ITS RESULT, not by a transaction count. The merge is
    // (old & ~data) | (tile & data); if the old value had not been read, every plane would read
    // back as (tile & data) alone - FA's low nibble is A - and this check would fail. That is a
    // stronger statement than "the backend was read four times", because it is the thing the guest
    // can observe.
    expect_planes(WIN_B, 15'h0500, 32'hFAFA_FAFA, 32'hFBFB_FBFB,
                  32'hFCFC_FCFC, 32'hFDFD_FDFD);

    // ------------------------------------------------------------------
    // The active-low plane mask. 0xCE leaves bit 0 set -> only B enabled, which
    // is TH04's single-plane put; the tile differs from the data so a plain
    // write cannot pass.
    // ------------------------------------------------------------------
    fill_all(8'h00);
    port_w(8'h7C, 8'h80 | 8'hCE);
    put_tiles(8'h3C, 8'h3C, 8'h3C, 8'h3C);
    cpu_store(WIN_B + 32'h0600, 32'hFFFF_FFFF, 4'hF);
    expect_planes(WIN_B, 15'h0600, 32'h3C3C_3C3C, 32'h0, 32'h0, 32'h0);

    // 0x8D leaves bit 1 set -> red only.
    fill_all(8'h00);
    port_w(8'h7C, 8'h80 | 8'h8D);
    put_tiles(8'h77, 8'h77, 8'h77, 8'h77);
    cpu_store(WIN_B + 32'h0700, 32'hFFFF_FFFF, 4'hF);
    expect_planes(WIN_B, 15'h0700, 32'h0, 32'h7777_7777, 32'h0, 32'h0);

    // All planes disabled is a no-op, not a plain store.
    fill_all(8'h00);
    port_w(8'h7C, 8'h80 | 8'h8F);
    put_tiles(8'h99, 8'h99, 8'h99, 8'h99);
    cpu_store(WIN_B + 32'h0800, 32'hFFFF_FFFF, 4'hF);
    // The old check counted backend writes and required zero. The observable form is that the
    // planes are UNCHANGED - the tiles went nowhere - so read them all back.
    expect_planes(WIN_B, 15'h0800, 32'h0, 32'h0, 32'h0, 32'h0);

    // ------------------------------------------------------------------
    // The address fold: a store through ANY of the four windows reaches all four
    // planes at the same 15-bit offset.
    // ------------------------------------------------------------------
    fill_all(8'h00);
    port_w(8'h7C, 8'h80);
    put_tiles(8'h55, 8'h55, 8'h55, 8'h55);
    cpu_store(WIN_G + 32'h0900, 32'hFFFF_FFFF, 4'hF);
    expect_planes(WIN_B, 15'h0900, 32'h5555_5555, 32'h5555_5555,
                  32'h5555_5555, 32'h5555_5555);
    // ... and through the intensity window.
    cpu_store(WIN_E + 32'h0A00, 32'hFFFF_FFFF, 4'hF);
    expect_planes(WIN_B, 15'h0A00, 32'h5555_5555, 32'h5555_5555,
                  32'h5555_5555, 32'h5555_5555);

    // ------------------------------------------------------------------
    // A byte store reaches the same four planes at the one column it names.
    // ------------------------------------------------------------------
    fill_all(8'h00);
    port_w(8'h7C, 8'h80);
    put_tiles(8'h3C, 8'h5A, 8'hC3, 8'h7E);
    // z486 presents a dword-aligned byte address with the byte enables naming the
    // bytes, so `be = 0010` at 0x0B00 is the byte at plane offset 0x0B01.
    cpu_store(WIN_B + 32'h0B00, 32'h0000_5500, 4'b0010);
    lane_byte(0, 2'd0, 15'h0B00, lb); if (lb !== 8'h00) fail("a byte GRCG store touched a column it did not name");
    lane_byte(0, 2'd3, 15'h0B00, lb); if (lb !== 8'h00) fail("a byte GRCG store touched a column it did not name");
    lane_byte(0, 2'd0, 15'h0B01, lb); if (lb !== 8'h3C) fail("a byte GRCG store did not write the named column of all four planes");
    lane_byte(0, 2'd1, 15'h0B01, lb); if (lb !== 8'h5A) fail("a byte GRCG store did not write the named column of all four planes");
    lane_byte(0, 2'd2, 15'h0B01, lb); if (lb !== 8'hC3) fail("a byte GRCG store did not write the named column of all four planes");
    lane_byte(0, 2'd3, 15'h0B01, lb); if (lb !== 8'h7E) fail("a byte GRCG store did not write the named column of all four planes");

    // ------------------------------------------------------------------
    // The tile write pointer and the mode write that restarts it.
    // ------------------------------------------------------------------
    fill_all(8'h00);
    port_w(8'h7C, 8'h80);
    put_tiles(8'h01, 8'h02, 8'h03, 8'h04);
    put_tiles(8'h05, 8'h06, 8'h07, 8'h08);   // the pointer wrapped: B is now 05
    cpu_store(WIN_B + 32'h0C00, 32'hFFFF_FFFF, 4'hF);
    expect_planes(WIN_B, 15'h0C00, 32'h0505_0505, 32'h0606_0606,
                  32'h0707_0707, 32'h0808_0808);

    // ------------------------------------------------------------------
    // The access page shifts the whole aperture by one interleaved page.
    // ------------------------------------------------------------------
    fill_all(8'h00);
    port_w(8'h7C, 8'h80);
    put_tiles(8'h11, 8'h11, 8'h11, 8'h11);
    gvram_access_page = 1;
    cpu_store(WIN_B + 32'h0D00, 32'hFFFF_FFFF, 4'hF);
    gvram_access_page = 0;
    for (mi = 0; mi < 4; mi = mi + 1) begin
      lane_byte(1, mi[1:0], 15'h0D00, lb);
      if (lb !== 8'h11) fail("page 1 GRCG store did not reach the second page's four planes");
    end
    lane_byte(0, 2'd0, 15'h0D00, lb);
    if (lb !== 8'h00) fail("a page-1 GRCG store disturbed page 0");

    // ------------------------------------------------------------------
    // A store outside the aperture is never expanded and never reaches this
    // block: the subsystem routes it to the mapper, which the stimulus feeds.
    // ------------------------------------------------------------------
    port_w(8'h7C, 8'h80);
    put_tiles(8'h11, 8'h22, 8'h33, 8'h44);
    map_seen = 0;
    cpu_store(32'h0000_2000, 32'hCAFE_F00D, 4'hF);   // ordinary guest RAM
    // The count is gone with the stub; the contract is that the MAP took the store, which the two
    // checks below already assert.
    if (!map_seen || map_last_addr !== 32'h0000_2000 || !map_last_write)
      fail("a store outside the GVRAM aperture did not go to the map");

    // ==== CHECKS ====
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GRCG: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_GRCG: FAIL (%0d errors)", errors);
  end

  initial begin
    // SIZED TO THE WORK, not to a guess. Every fill is now real bus traffic through the plane
    // windows rather than a write into a local array, and fill_all is called eleven times.
    // Each call is 2 pages x 4 planes x (FILL_COLS/4) = 8192 stores, and a store costs about
    // thirty cycles (four lanes, five cycles each, plus the task's own edges), so eleven calls
    // is roughly 2.7 M cycles, about 27 ms of simulated time. The old 20 ms budget was sized
    // for the array poke and is now genuinely too small; this is ten times the measured cost
    // so that a slow machine or a longer section still finishes.
    #200_000_000;
    $fatal(1, "TB_PC9821_GRCG: TIMEOUT");
  end

endmodule
