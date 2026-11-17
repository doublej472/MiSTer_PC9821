`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SHADOWW_STATES: the 0xF8000-0xFFFFF window answers every row of the Xe10's SHADOWW state table (docs/probes/SHADOWW.TXT st01-st08, each row written in the probe's own order 0x053D, then 0x043D, then 0x043F: tools/hwprobe/probe2/probe2.s sh_st_loop) through the REAL pc9821_iobus and pc9821_memory_map: with 0x043D = 0x02 latched the window shows the BIOS-top bank whatever 0x043F then selects (st06: 0x043F = 0xE8 still reads A1 and the stored 04, not the ITF image), the writable shadow is shown only in that 0x043D = 0x02 state (st05: 0x043D = 0x00 then 0x043F = 0xEE shows bank 7's ROM byte 00 at 0xF8E90, not the stored 04) and only with the 0x053D bit-1 gate set (st07: gate clear reads the ROM byte 00), and 0x043F's bank select still works under 0x043D = 0x00 (st04/st05/st08). FAIL-FIRST: with one top_bank register written by both ports and the shadow read on bank 7 or 9 without the gate, st05 and st07 read the shadow and st06 showed the ITF image.
//
// THE ROWS (docs/probes/SHADOWW.TXT, the "st" lines; F8000:0000 identifies the bank shown,
// F8E90 is the drive byte the ITF stores into the shadow during POST):
//   st01 043D=02 043F=(firmware) gate on : A1, F8E90 = 04  (BIOS top + shadow)
//   st02 043D=00 043F=(firmware) gate on : EB, F8E90 = 57  (the ITF, bank 4)
//   st03 043D=02 043F=EE         gate on : A1, 04
//   st04 043D=00 043F=E8         gate on : EB, 57
//   st05 043D=00 043F=EE         gate on : A1, 00          (bank 7 ROM, no shadow)
//   st06 043D=02 043F=E8         gate on : A1, 04          (043D=02 outranks the 043F select)
//   st07 043D=02 043F=EE         gate off: A1, 00          (gate clear: ROM)
//   st08 043D=00 043F=E8         gate off: EB, 57
// The byte values map onto the pack's routes: A1/00 are BANK7.BIN[0] and BANK7.BIN[0x0E90] (the
// pack's BIOS-top slot at +0x20000, which 0x043F bank 7 also selects), EB/57 are BANK4.BIN[0]
// and BANK4.BIN[0x0E90] (the ITF slot at +0x00000), and 04 is the stored byte, which only the
// shadow holds. So each row is asserted as the backend address the map hands out: the bank's
// pack slot, or the shadow wherever the shadow is shown. The shadow is the whole 32 KiB window
// (the loader tees the BIOS-top slot into it, pc9821_memory_subsystem), so in the rows that show
// it 0xF8000 is the shadow's copy of BANK7.BIN[0] (A1) and 0xF8E90 the stored 04.
//
// THE FIRMWARE STATE BEFORE THE TABLE. st01/st02 leave 0x043F at the firmware's value. The
// main BIOS's last ROM-bank selection is BANK6@0x5302-0x532A: `out 0x43D,0x00 / out 0x43F,0xE2`,
// a copy out of bank 1, then `out 0x43F,0xE8 / out 0x43D,0x02` - so it is replayed here, after
// the ITF's shadow enable (`out 0x43F,0x80`, BANK4@0x1CD) and with the shadow already written
// (fw_shadow_dirty, owned by pc9821_memory_subsystem, held set as it is after POST). Then the
// probe's own step (1): gate on, 0x043D = 0x00. The probe's A5 marker store (the Q1 question)
// is not replayed: this bench pins the read routing, not the store rule.
//
// NOT CAPTURED, and so not asserted: 0x043F = 0xEx written while 0x043D = 0x02 is latched and
// then 0x043D = 0x00 (does the window show bank x or the ITF?), 0x043D = 0x00 re-written after a
// 0x043F bank select, and 0x043F values other than 0xE8/0xEE under 0x043D = 0x02.

module tb_pc9821_shadoww_states;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg  [31:0] io_cpu_addr = 0, io_cpu_din = 0;
  reg  [3:0]  io_cpu_be = 0;
  reg         io_cpu_valid = 0, io_cpu_write = 0;
  wire [31:0] io_cpu_dout;
  wire        io_cpu_ready, io_cpu_resp_valid;
  wire        cache_flush_req;

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
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;

  // The seam under test: pc9821_iobus's window latches into pc9821_memory_map, exactly as
  // pc9821_system wires them.
  wire [3:0] top_bank;
  wire       bios_ram_gate;
  wire       top_shadow_en;
  wire [1:0] ems_state;

  // pack_base = 32 MiB; the shadow base is pc9821_memory_subsystem's pack_base + PACK_BYTES +
  // 0x58000 (PACK_BYTES = 1 MiB).
  localparam [31:0] PACK_BASE   = 32'h0200_0000;
  localparam [31:0] SHADOW_BASE = 32'h0215_8000;
  localparam [31:0] EMS_PAGE_BASE = 32'h0214_8000;
  localparam [31:0] ITF_SLOT    = PACK_BASE + 32'h0000_0000;   // BANK4.BIN: EB at 0, 57 at 0x0E90
  localparam [31:0] TOP_SLOT    = PACK_BASE + 32'h0002_0000;   // BANK7.BIN: A1 at 0, 00 at 0x0E90

  // ==== DUT ====
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;
  wire [7:0] fdd_din;
  wire       fdd_abort;
  wire [3:0] fdd_chg = 4'd0;
  wire       fdd_frame_tick = 1'b0;

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
      // A zero-latency flush handshake: 0x043D/0x043F/0x053D are flush triggers, and this bench
      // pins the window state, not the flush (tb_pc9821_cache_flush owns that contract).
      .cache_flush_req(cache_flush_req),
      .cache_flush_done(cache_flush_req),
      .top_bank(top_bank), .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
      .ems_state(ems_state)
  );

  reg  mode2_16color = 1'b0;
  wire e_plane_nc;

  pc9821_memory_map map (
      .mode2_16color(mode2_16color),
      .e_plane_nc(e_plane_nc),
      .top_bank(top_bank), .ide_rom_enable(1'b0), .d8_bank(2'b00), .ide_ram_gate(1'b0),
      .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en), .fw_shadow_dirty(1'b1),
      .fw_shadow_base(SHADOW_BASE),
      .ems_state(ems_state), .ems_page_base(EMS_PAGE_BASE),
      .win0_sel(8'h08), .win0_sel_moved(1'b0), .pack_base(PACK_BASE),
      .guest_ram_bytes(32'h0200_0000),
      .peg_window(1'b0), .peg_base(32'h0),
      .pegc_256(1'b0), .pegc_plane(1'b0),
      .pegc_bank_a(4'h0), .pegc_bank_b(4'h0),
      .cpu_addr(mem_cpu_addr), .cpu_addr_raw(mem_cpu_addr), .xl_low20(1'b0), .xl_peg(1'b0),
      .cpu_din(mem_cpu_din), .cpu_be(mem_cpu_be),
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

  // One read through the map: the backend address it hands out.
  task automatic route(input [31:0] addr, output [31:0] got);
    begin
      @(negedge clk);
      mem_cpu_addr = addr;
      mem_cpu_valid = 1;
      mem_cpu_write = 0;
      #1;
      if (!mem_valid) begin
        $display("FAIL read %08x did not reach the backend", addr);
        errors = errors + 1;
      end
      got = mem_addr;
      @(negedge clk);
      mem_cpu_valid = 0;
    end
  endtask

  // One SHADOWW row in the probe's order: the 0x053D gate, then 0x043D, then 0x043F
  // (0xFF = leave that latch, as the probe's table encodes it), then the two reads.
  task automatic st_row(input [8*4-1:0] id, input [7:0] v43d, input [7:0] v43f,
                        input gate, input [31:0] want_f8000, input [31:0] want_e90,
                        input [8*40-1:0] what);
    reg [31:0] got;
    integer    errors_at_row;
    begin
      errors_at_row = errors;
      write_port(16'h053D, gate ? 8'h1F : 8'h1D);   // SHADOWW.TXT:146 gate-on/gate-off = 1F 1D
      if (v43d != 8'hFF) write_port(16'h043D, v43d);
      if (v43f != 8'hFF) write_port(16'h043F, v43f);
      route(32'h000F_8000, got);
      if (got !== want_f8000) begin
        $display("FAIL %0s (%0s): F8000:0000 -> %08x, want %08x (top_bank=%0d)",
                 id, what, got, want_f8000, top_bank);
        errors = errors + 1;
      end
      route(32'h000F_8E90, got);
      if (got !== want_e90) begin
        $display("FAIL %0s (%0s): F8E90 -> %08x, want %08x (top_bank=%0d gate=%b en=%b)",
                 id, what, got, want_e90, top_bank, bios_ram_gate, top_shadow_en);
        errors = errors + 1;
      end else if (errors == errors_at_row)
        $display("  %0s ok: F8000 -> %08x, F8E90 -> %08x (%0s)", id, want_f8000, want_e90, what);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // POST as far as these latches go: the ITF's shadow enable (BANK4@0x1CD `out 0x43F,0x80`),
    // its gate (BANK4@0x25B `out 0x53D,0x02`), then the main BIOS's bank-1 copy sequence
    // (BANK6@0x5302-0x532A), which leaves 0x043F = 0xE8 and 0x043D = 0x02.
    write_port(16'h043F, 8'h80);
    write_port(16'h053D, 8'h02);
    write_port(16'h043D, 8'h00);
    write_port(16'h043F, 8'hE2);
    write_port(16'h043F, 8'hE8);
    write_port(16'h043D, 8'h02);
    // The probe's step (1): gate on, the ITF state selected through 0x043D.
    write_port(16'h053D, 8'h1F);
    write_port(16'h043D, 8'h00);

    st_row("st01", 8'h02, 8'hFF, 1'b1, SHADOW_BASE, SHADOW_BASE + 32'h0E90, "BIOS top + shadow");
    st_row("st02", 8'h00, 8'hFF, 1'b1, ITF_SLOT, ITF_SLOT + 32'h0E90,    "the ITF");
    st_row("st03", 8'h02, 8'hEE, 1'b1, SHADOW_BASE, SHADOW_BASE + 32'h0E90, "BIOS top + shadow");
    st_row("st04", 8'h00, 8'hE8, 1'b1, ITF_SLOT, ITF_SLOT + 32'h0E90,    "bank 4, the ITF");
    st_row("st05", 8'h00, 8'hEE, 1'b1, TOP_SLOT, TOP_SLOT + 32'h0E90,    "bank 7 ROM, no shadow");
    st_row("st06", 8'h02, 8'hE8, 1'b1, SHADOW_BASE, SHADOW_BASE + 32'h0E90, "043D=02 outranks 043F");
    st_row("st07", 8'h02, 8'hEE, 1'b0, TOP_SLOT, TOP_SLOT + 32'h0E90,    "gate clear: ROM");
    st_row("st08", 8'h00, 8'hE8, 1'b0, ITF_SLOT, ITF_SLOT + 32'h0E90,    "gate clear: the ITF");

    repeat (4) @(posedge clk);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SHADOWW_STATES: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SHADOWW_STATES: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_SHADOWW_STATES: TIMEOUT");
  end

endmodule
