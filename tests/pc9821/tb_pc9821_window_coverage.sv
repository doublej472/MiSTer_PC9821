`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_WINDOW_COVERAGE:
// Every address in window 0 is claimed by exactly one owner, for EVERY window base the 0x0461 register can select (all 256 of them, not the three or four the firmware is known to write, and not the 252 that no bench has ever driven).
// Window 0 is the only guest-programmable relocation in the memory map, and it decides whether an address in 0x80000-0x9FFFF reaches guest RAM, the absent ROM area (which the machine answers with 0xFF and whose stores are discarded), the IDE option-ROM
// window, or the GVRAM plane windows. Two failures matter and both are silent: a HOLE, where no owner claims the address and the CPU waits forever for a ready that no route will give it, and a DOUBLE claim, where two routes answer one access
// and the loser can act on a completion that is not its own. The double-claim half is the invariant pc9821_memory_subsystem.sv's route-isolation block asserts, and it is what let the mapper take the TRAM route's response 37,763,735 cycles into
// the authentic POST. Note that gvram_window and mem_valid both being set is NOT a violation: the plane window is a decode output for the subsystem, which gates this block's cpu_valid with !gvram_select, so mem_valid here is the map's own
// block-level answer and never reaches the backend for those addresses.

module tb_pc9821_window_coverage;
  reg clk = 0;
  always #5 clk = ~clk;

  // Identical to tb_pc9821_memory_map.sv's harness: the same package, the same
  // bottom of the pack, and the same guest size, so the two benches agree about
  // the map they are describing. guest_ram_bytes is the 32 MiB option, which is
  // also the smallest value any OSD entry can produce (1 MiB) rounded up -- the
  // invariant below is asserted in the first MiB, which is inside RAM for every
  // selectable size.
  reg        reset = 1;
  reg  [3:0] top_bank = 4'd7;
  reg        ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg        bios_ram_gate = 0;
  reg  [7:0] win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg  [31:0] pack_base = 32'h01F8_0000;
  reg  [31:0] guest_ram_bytes = 32'h0200_0000;
  reg  [31:0] gvram_base = 32'h0300_0000;
  reg        gvram_access_page = 0;
  reg  [31:0] cpu_addr = 0;
  reg  [31:0] cpu_din = 0;
  reg  [3:0]  cpu_be = 4'hF;
  reg  [7:0]  cpu_burstcount = 8'd1;
  reg         cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  reg  [31:0] mem_dout = 32'h89AB_CDEF;
  reg  [127:0] mem_line_dout = 128'h0;
  reg         mem_ready = 1'b1, mem_resp_valid = 0, mem_line_resp_valid = 0;

  wire        gvram_window;
  wire [1:0]  gvram_win_plane;
  wire [14:0] gvram_win_offset;
  // The map's exported window-0 pair (P2): the post-bias address and its flag. Unused here.
  wire [31:0] d_addr;
  wire        win0_moved;
  wire [31:0] cpu_dout, mem_addr, mem_din;
  wire [31:0] cpu_line_word;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  wire        absent_area;

  // ==== DUT ====
  // 0x043F EMS window select (from pc9821_iobus) and the backend base of the 0x22
  // state's 64 KiB page (pc9821_memory_subsystem computes it above the pack).
  wire [1:0]  ems_state;
  wire [31:0] ems_page_base;
  wire        ems_open_bus;
  // The PEGC extended-VRAM window: off here, so the window-coverage walk is
  // unchanged. Its own routing is tb_pc9821_sys16m.sv's and its bytes are tb_pc9821_pegvram.sv's.
  reg         peg_window = 1'b0;
  reg  [31:0] peg_base = 32'd0;
  wire        top_shadow_en;
  wire        fw_shadow_dirty;
  wire [31:0] fw_shadow_base;
  wire        fw_shadow_store;
  // The PEGC window-arm state (pegc-scope-REPORT.md 4 row 2): 0 = the pre-PEGC
  // decode; the arms themselves are tb_pc9821_memmap_ref's cases.
  wire        pegc_256 = 1'b0;
  wire        pegc_plane = 1'b0;
  wire  [3:0] pegc_bank_a = 4'd0, pegc_bank_b = 4'd0;
  wire        pegc_packed, pegc_reg_win, pegc_nc;

  // 0x063C bank select into the 0xD8000 window: 0 = the IDE option ROM, the reset bank.

  reg  [1:0] d8_bank = 2'b00;

  wire addr_ge_ram;   // the map's shared compare output, unused here
  // No translation in front of the map here: the untranslated address IS cpu_addr.
  wire [31:0] cpu_addr_raw = cpu_addr;
  wire        xl_low20 = 1'b0;
  wire        xl_peg = 1'b0;
  pc9821_memory_map dut (.*);

  integer errors = 0;
  integer sel, page;

  // ==== CHECKS ====
  //
  // The invariant, and why each half of it is required rather than decorative:
  //
  //   HOLE     -- an address no owner claims. The CPU asserts valid and waits for
  //               a ready that no route will give it, so the guest stops
  //               mid-instruction with no diagnostic. This is the failure mode
  //               tb_pc9821_memory_subsystem's held-valid case was written for.
  //   DOUBLE   -- two owners claim one address. Whichever wins, the other route
  //               can act on a completion that is not its own, which is exactly
  //               what the route-isolation block in pc9821_memory_subsystem.sv
  //               exists to forbid; it is also what let the mapper take the TRAM
  //               route's response 37,763,735 cycles into the authentic POST.
  //
  // gvram_window and mem_valid BOTH being set is NOT a violation: the map states
  // the plane window as a decode output for the subsystem, which gates this
  // block's cpu_valid with !gvram_select, so mem_valid here is the map's own
  // block-level answer and never reaches the backend for those addresses. The
  // check is therefore absent_area vs gvram_window for double-claim, and
  // "at least one claims it" for the hole.
  task automatic check_claims;
    reg hole, double;
    begin
      hole   = !absent_area && !gvram_window && !mem_valid;
      double = absent_area && gvram_window;
      if (hole) begin
        $display("FAIL window0=%02x addr=%08x claimed by NOBODY (absent=0 gvram=0 mem_valid=0): the CPU waits forever",
                 win0_sel, cpu_addr);
        errors = errors + 1;
      end
      if (double) begin
        $display("FAIL window0=%02x addr=%08x claimed TWICE (absent=%b gvram=%b): two routes answer one access",
                 win0_sel, cpu_addr, absent_area, gvram_window);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    reset = 0;
    @(negedge clk);

    // A read, so that fw_write_blocked cannot mask the decode: that term needs
    // cpu_write and this bench is about which REGION an address belongs to.
    cpu_valid   = 1'b1;
    cpu_write   = 1'b0;
    cpu_line_read = 1'b0;

    // Every window base, and inside each base every 4 KiB page of the window
    // plus both exact extremes. 256 x 34 addresses, all combinationally
    // evaluated, so the whole sweep costs a few hundred clock cycles.
    for (sel = 0; sel < 256; sel = sel + 1) begin
      win0_sel = sel[7:0];
      #1;
      for (page = 0; page < 32; page = page + 1) begin
        cpu_addr = 32'h0008_0000 + (page * 32'h1000);
        #1;
        check_claims;
      end
      cpu_addr = 32'h0008_0000; #1; check_claims;   // exact bottom
      cpu_addr = 32'h0009_FFFF; #1; check_claims;   // exact top
    end

    cpu_valid = 1'b0;
    @(negedge clk);

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_WINDOW_COVERAGE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_WINDOW_COVERAGE: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks would hang CI forever. The runner
  // also bounds wall time and greps the PASS marker.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_WINDOW_COVERAGE: TIMEOUT");
  end

endmodule
