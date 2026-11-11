`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// Every non-0x2x/non-0xEx write to 0x043F leaves the EMS window state alone: after 0x22 enables the 64 KiB page, the BIOS's pre-mov-cr0 cache-flush write 0xA0 - and 0x80/0xC4 - still serve the EMS page at 0xB0000 instead of resetting the window to the VRAM planes, exactly as qemu's mem_bankctl_write acts only on 0x20 (EMS) and 0xE0 (bank) (pc98-mem.c:684-701). FAIL-FIRST: before this fix every other nibble took the else arm, reset ems_state to the identity, and 0xB0000 fell back to VRAM - an EMM386-style driver that enables 0x22 and then toggles paging with the BIOS's 0xA0 flush lost its page. And 0x24 written from the identity keeps the VRAM planes (docs/probes/DMAROUTE-XE10.TXT cases E1/E2: the 0x20 and 0x24 views are one storage) while written from the page it unmaps the window (docs/probes/EMS.TXT `B0000 under 20/22/24: 1111 2222 FFFF`) - FAIL-FIRST, the identity case read unmapped.
//
// The defect: pc9821_iobus's 0x043F
// write arm returned ems_state to the identity for every nibble except 0x2x
// (and 0xEx kept it), so the 486 cache flush 0x043F=0xA0 the firmware emits
// immediately before every `mov cr0` (BANK7@0x5F83, BANK4@0x6020/0x6044)
// silently unmapped an enabled EMS page. qemu's mem_bankctl_write
// (pc98-mem.c:684-701) switches on data & 0xf0 and acts only in the 0x20 and
// 0xE0 cases - 0x80/0xA0/0xC0 fall through with the EMS state untouched - and
// that is the expected value here. The route itself is the one
// tb_pc9821_memory_map pins for the three measured states (EMS.TXT):
// state 1 serves ems_page_base + offset (64 KiB), state 0 leaves the GVRAM R
// plane at 0xB0000 alone.
//
// Both halves of the claim are exercised through the real pair: the writes go
// through pc9821_iobus (whose decode owns ems_state) and the reads through
// pc9821_memory_map (whose route decides "page vs VRAM"), wired together
// exactly as pc9821_system wires them, so a decode regression and a route
// regression both fail this bench.

module tb_pc9821_ems;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The I/O side (pc9821_iobus's CPU port): 0x043F writes ride this.
  reg  [31:0] io_cpu_addr = 0, io_cpu_din = 0;
  reg  [3:0]  io_cpu_be = 0;
  reg         io_cpu_valid = 0, io_cpu_write = 0;
  wire [31:0] io_cpu_dout;
  wire        io_cpu_ready, io_cpu_resp_valid;
  wire        cache_flush_req;

  // The memory side (pc9821_memory_map's requester port): 0xB0000 reads ride this.
  reg  [31:0] mem_cpu_addr = 0;
  reg  [31:0] mem_cpu_din = 0;
  reg  [3:0]  mem_cpu_be = 4'hF;
  reg         mem_cpu_valid = 0, mem_cpu_write = 0;
  wire [31:0] mem_cpu_dout, mem_addr, mem_din;
  wire        mem_valid, mem_write;
  wire        mem_cpu_ready, mem_cpu_resp_valid;
  wire        gvram_window;
  wire [1:0]  gvram_win_plane;
  wire [14:0] gvram_win_offset;
  wire        ems_open_bus, absent_area, fw_shadow_store;
  wire [31:0] cpu_line_word;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;

  // The seam under test: pc9821_iobus's ems_state into pc9821_memory_map,
  // exactly as pc9821_system wires it.
  wire [1:0] ems_state;

  // The map reads only ems_page_base[31:20]: the port is pc9821_memory_subsystem's
  // pack_base + PACK_BYTES + 0x48000 (pack_base = the map's 32 MiB default here), so its low
  // 20 bits ARE the constant 0x48000 and the page arm is a bit splice
  // (tools/check_memmap_addr_equiv.py PREMISES). Drive that same shape.
  localparam [31:0] EMS_PAGE_BASE = 32'h0214_8000;   // 0x0200_0000 + 1 MiB + 0x48000

  // ==== DUT ====
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;

  pc9821_iobus bus (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),
      .clk(clk), .reset(reset),
      .bios_set(4'h0), .gdc_clock_5m(1'b0), .triple_fault_reset(1'b0),
      .cpu_addr(io_cpu_addr), .cpu_din(io_cpu_din), .cpu_be(io_cpu_be),
      .cpu_valid(io_cpu_valid), .cpu_write(io_cpu_write),
      .cpu_dout(io_cpu_dout), .cpu_ready(io_cpu_ready),
      .cpu_resp_valid(io_cpu_resp_valid),
      .debug_status(8'h00), .cal_cdat(1'b0),
      .cfg_ram_mib(7'h0), .cfg_seed_en(1'b0),
      .device_io_dout(8'h00), .device_rd_wait(1'b0), .device_rd_hold(1'b0),
      .device_wr_wait(1'b0),
      .fdd_present(4'h0), .fdd_ready(1'b1), .fdd_rdy(1'b0), .fdd_hdrv(1'b0),
      .fdd_err(1'b0), .fdd_dout(8'h00), .fdd_hr(8'h00), .fdd_hn(8'h00),
      .fdd_hs(8'h00),
      .dma_mem_ready(1'b0), .dma_mem_dout(32'h0), .dma_mem_resp_valid(1'b0),
      .ps2_mouse(25'h0), .egc_gate(1'b0), .gdc_ff2_state(11'h0),
      .cache_flush_busy(1'b0),
      // The core's whole-L1 flush handshake at ZERO latency: this bench counts
      // states, not flushes (tb_pc9821_cache_flush owns the trigger contract),
      // and an unmodelled done would leave a flush-triggering write waiting in
      // the iobus's S_FLUSH forever.
      .cache_flush_req(cache_flush_req),
      .cache_flush_done(cache_flush_req),
      .ems_state(ems_state)
  );
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;
  wire       e_plane_nc;

  pc9821_memory_map map (
      .mode2_16color(mode2_16color),
      .e_plane_nc(e_plane_nc),
      .top_bank(4'd3), .ide_rom_enable(1'b0), .d8_bank(2'b00), .ide_ram_gate(1'b0),
      .bios_ram_gate(1'b0), .top_shadow_en(1'b0), .fw_shadow_dirty(1'b0),
      .fw_shadow_base(32'h0),
      .ems_state(ems_state), .ems_page_base(EMS_PAGE_BASE),
      .win0_sel(8'h08), .win0_sel_moved(1'b0), .pack_base(32'h0200_0000),
      .guest_ram_bytes(32'h0200_0000),
      .peg_window(1'b0), .peg_base(32'h0),
      .pegc_256(1'b0), .pegc_plane(1'b0),
      .pegc_bank_a(4'h0), .pegc_bank_b(4'h0),
      .cpu_addr(mem_cpu_addr), .cpu_addr_raw(mem_cpu_addr), .xl_low20(1'b0), .xl_peg(1'b0), .cpu_din(mem_cpu_din), .cpu_be(mem_cpu_be),
      .cpu_burstcount(8'h0), .cpu_line_read(1'b0),
      .cpu_valid(mem_cpu_valid), .cpu_write(mem_cpu_write),
      .cpu_dout(mem_cpu_dout),
      .cpu_ready(mem_cpu_ready), .cpu_resp_valid(mem_cpu_resp_valid),
      .absent_area(absent_area), .ems_open_bus(ems_open_bus),
      .fw_shadow_store(fw_shadow_store),
      .gvram_window(gvram_window), .gvram_win_plane(gvram_win_plane),
      .gvram_win_offset(gvram_win_offset),
      .mem_addr(mem_addr), .mem_din(mem_din), .mem_be(mem_be),
      .mem_burstcount(mem_burstcount), .mem_valid(mem_valid),
      .mem_write(mem_write),
      .mem_dout(32'h0), .mem_ready(1'b0), .mem_resp_valid(1'b0)
  );

  integer errors = 0;
  // ==== STIMULUS ====

  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The iobus's port-write protocol (the shape tb_pc9821_iobus drives): a
  // dword-aligned address plus a byte-enable lane.
  task automatic write_port(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      io_cpu_addr = {16'd0, portnum[15:2], 2'b00};
      io_cpu_be = 4'b0001 << lane;
      io_cpu_din = {24'd0, data} << (lane * 8);
      io_cpu_write = 1;
      io_cpu_valid = 1;
      begin : wr_wait
        integer n;
        n = 0;
        while (!io_cpu_ready && n < 3000) begin @(negedge clk); n = n + 1; end
        if (!io_cpu_ready)
          $fatal(1, "write %04x wedged waiting cpu_ready (iobus state=%0d)", portnum, bus.state);
      end
      @(negedge clk);
      io_cpu_valid = 0;
      io_cpu_write = 0;
      io_cpu_be = 0;
      begin : st_wait
        integer n;
        n = 0;
        while (bus.state != 0 && n < 3000) begin @(negedge clk); n = n + 1; end
        if (bus.state != 0)
          $fatal(1, "write %04x wedged in the iobus FSM (state=%0d)", portnum, bus.state);
      end
    end
  endtask

  // 0xB0000 as the memory map answers it: the EMS page in state 1 (mem_addr =
  // ems_page_base + offset, the backend route), the GVRAM R plane in state 0
  // (gvram_window, plane 1 - tb_pc9821_memory_map pins the same pair).
  task automatic check_ems_page(input [31:0] off, input [8*120-1:0] what);
    begin
      @(negedge clk);
      mem_cpu_addr = 32'h000B_0000 + off;
      mem_cpu_valid = 1;
      mem_cpu_write = 0;
      #1;
      if (!mem_valid) begin
        $display("FAIL %0s: 0xB0000+%0x did not reach the backend (mem_valid=0)", what, off);
        errors = errors + 1;
      end else if (gvram_window || mem_addr !== EMS_PAGE_BASE + off) begin
        $display("FAIL %0s: 0xB0000+%0x -> mem=%08x gvram=%b, want the EMS page at %08x",
                 what, off, mem_addr, gvram_window, EMS_PAGE_BASE + off);
        errors = errors + 1;
      end
      @(negedge clk);
      mem_cpu_valid = 0;
    end
  endtask

  // The unmapped state: no backend request, no plane, the open-bus responder's flag.
  task automatic check_unmapped(input [8*120-1:0] what);
    begin
      @(negedge clk);
      mem_cpu_addr = 32'h000B_0000;
      mem_cpu_valid = 1;
      mem_cpu_write = 0;
      #1;
      if (mem_valid || gvram_window || !ems_open_bus) begin
        $display("FAIL %0s: 0xB0000 -> mem_valid=%b gvram=%b open=%b, want the unmapped state",
                 what, mem_valid, gvram_window, ems_open_bus);
        errors = errors + 1;
      end
      @(negedge clk);
      mem_cpu_valid = 0;
    end
  endtask

  task automatic check_vram(input [8*120-1:0] what);
    begin
      @(negedge clk);
      mem_cpu_addr = 32'h000B_0000;
      mem_cpu_valid = 1;
      mem_cpu_write = 0;
      #1;
      if (!gvram_window || gvram_win_plane !== 2'd1 || mem_addr !== 32'h000B_0000) begin
        $display("FAIL %0s: 0xB0000 -> mem=%08x gvram=%b plane=%0d, want the VRAM R plane",
                 what, mem_addr, gvram_window, gvram_win_plane);
        errors = errors + 1;
      end
      @(negedge clk);
      mem_cpu_valid = 0;
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // The window's identity first: 0x20 leaves the GVRAM R plane at 0xB0000
    // (the state the BIOS's mode-set stub and the ITF leave it in).
    write_port(16'h043F, 8'h20);
    check_vram("0x20: the identity state");

    // 0x24 FROM THE IDENTITY KEEPS THE PLANES, and from the page it unmaps the window.
    // docs/probes/DMAROUTE-XE10.TXT writes 0x24 right after 0x20 (dmaroute.s set_state ->
    // to_normal): case E1's 0x20 view and 0x24 view are one storage (`V1 PRE=D735...`, V2's
    // prefill) and case E2's store under 0x24 reads back through 0x20 (`E2 CPU V1 NORMAL -> D`).
    // docs/probes/EMS.TXT writes it right after 0x22: `B0000 under 20/22/24: 1111 2222 FFFF`,
    // and the later 0x20 and 0x22 reads still find 1111 and 2222.
    write_port(16'h043F, 8'h24);
    check_vram("0x24 written from the identity keeps the planes (DMAROUTE-XE10 E1/E2)");
    write_port(16'h043F, 8'h24);
    check_vram("0x24 written twice from the identity keeps the planes");
    write_port(16'h043F, 8'h22);
    write_port(16'h043F, 8'h24);
    check_unmapped("0x24 written from the page unmaps the window (EMS.TXT 24 -> FFFF)");
    write_port(16'h043F, 8'h24);
    check_unmapped("0x24 again keeps the window unmapped");
    write_port(16'h043F, 8'h20);
    check_vram("0x20 after the unmapped state: the planes (EMS.TXT 20 -> 1111)");

    // 0x22 enables the 64 KiB page - the ITF's own fill-and-verify window
    // (BANK4@0xF82C7-0xF8317). From here on the page must SURVIVE every
    // non-0x2x/non-0xEx write.
    write_port(16'h043F, 8'h22);
    check_ems_page(32'h0000, "0x22: the 64 KiB page serves");
    check_ems_page(32'hFFFC, "0x22: the page is 64 KiB");

    // 0x80: the top-window shadow enable (its own effect is not the subject).
    write_port(16'h043F, 8'h80);
    check_ems_page(32'h0000, "after 0x043F=0x80 the EMS page must survive");

    // 0xA0: the 486 cache flush the firmware emits before every `mov cr0`.
    write_port(16'h043F, 8'hA0);
    check_ems_page(32'h0000, "after 0x043F=0xA0 (the cache flush) the EMS page must survive");

    // 0xC4: any other nibble, the same rule (qemu falls through every case
    // that is not 0x20/0xE0).
    write_port(16'h043F, 8'hC4);
    check_ems_page(32'h0000, "after 0x043F=0xC4 the EMS page must survive");

    // The 0x2x writes still MOVE the state (the checks above are not vacuous):
    // 0x20 returns the window to the VRAM planes, 0x22 re-enables the page.
    write_port(16'h043F, 8'h20);
    check_vram("0x20: the identity returns");
    write_port(16'h043F, 8'h22);
    check_ems_page(32'h0000, "0x22 re-enables the page after the identity");

    // 0xEx is the ROM bank select and must not move the EMS state either
    // (qemu's 0xE0 case touches top_bank only) - so the page survives a bank
    // flip too.
    write_port(16'h043F, 8'hE4);
    check_ems_page(32'h0000, "after 0x043F=0xE4 (a ROM bank select) the EMS page must survive");

    repeat (4) @(posedge clk);
    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_EMS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_EMS: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_EMS: TIMEOUT");
  end

endmodule
