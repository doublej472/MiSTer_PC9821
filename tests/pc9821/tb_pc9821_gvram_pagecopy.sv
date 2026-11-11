`timescale 1ns/1ps
`include "z486_pc98_preset.svh"

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_PAGECOPY: Farland Story's page-to-page map copy END TO END on the REAL z486 running the guest's own instruction bytes (FSMAIN.EXE @0x5C7) through the REAL pc9821_memory_map window decode into the REAL pc9821_gvram client, so the 0xA6 access-page write reaching the window decode is tested on the operand forms the CPU really presents: both pages and all four planes are pre-filled with a pattern that is a pure function of (byte offset, plane, page), the destination page must then hold the SOURCE page's pattern at the offsets the routine's own arithmetic computes (the first 200 words from dst, then 160 more from dst + 5 rows) and the source page must stay byte-identical to its own pattern - so a wrong page on either leg, a wrong plane window (the routine walks 0xA800/0xB000/0xB800/0xE000 and one failing iteration leaves one plane stale), a dropped store or a byte-enable fault each changes the bytes that must match.
// REAL z486 executing the guest's own instruction bytes (FSMAIN.EXE @0x5C7, verified against
// the binary with the routine's own outer plane loop), through the REAL pc9821_memory_map
// window decode into the REAL pc9821_gvram client, so the seam under test is the one the
// triage report could only name: the 0xA6 access-page write reaching the window decode, the
// reads it steers and the writes it steers back, on the operand forms the CPU really presents.
//
// WHAT THE ROUTINE IS. `out 0xA6, page^1` -> 200 + 160 words read OUT of the plane window into
// a scratch buffer at 0x5CD2 -> `out 0xA6, page` -> 360 words written BACK. Its outer loop
// (0x62B-0x63D: `add ax,0x800` / `cmp ax,0xC000` / `jc`, then `cmp ax,0xE000` / `mov ax,0xE000`
// / `jc`) walks ES over the four plane windows 0xA800, 0xB000, 0xB800, 0xE000 - the classic
// PC-98 layout, and exactly the four windows pc9821_memory_map decodes. SO A FAILURE IN ONE
// ITERATION LEAVES EXACTLY ONE PLANE STALE, and the first plane is B - blue - which is the
// reported symptom ("the blue is missing from the bugged sprites/stuck graphics") read literally.
//
// THE EXPECTED VALUES ARE ARCHITECTURAL, never from this repo's RTL: both pages are pre-filled
// with a pattern that is a pure function of (byte offset, plane, page), so the copy's outcome is
// computable in advance. Byte-for-byte, per plane, the destination region must hold the SOURCE
// page's pattern at the source offsets the routine computes - first 200 words from dst, then 160
// from dst + 5 rows. A wrong page on either leg, a wrong plane window, a dropped store or a
// byte-enable fault each changes the bytes and fails.
//
// THE GRCG IS NEVER ARMED, AND THAT IS THE BENCH'S LARGEST GAP (recorded 2026-10-03). The
// routine runs with `0x7C` at its reset value, so its reads are plain plane reads and its writes
// are plain plane writes. Farland Story, however, drives the GRCG hard - 3.3M GRCG stores against
// 4.6M plain-write cycles in a 47.5 s in-game capture - and a copy issued while `0x7C` is left at
// 0x80 (TDW) or 0xC0 (RMW) behaves DIFFERENTLY ON BOTH LEGS: a read with the TDW arm returns the
// tile-compare value rather than the plane byte (`memtcr`, benched byte-exact in
// tb_pc9821_grcg_ops section 9), and a write merges with the tile instead of storing the datum.
// Whether the game leaves it armed across this copy is UNKNOWN without an access trace - so the
// next bench extends this one with `out 0x7C`/`out 0x7E` before the copy, for both arms. Do not
// read a PASS here as covering the armed case.
//
// BLIND SPOTS, stated: the routine's SECOND stage (0x63F onward, a different shape that copies
// from 0x4970 + arg and beyond) is NOT run - the image stops at the plane loop's exit, where a
// sentinel takes over, because that stage needs more of the game's data area than this bench
// builds. The GRCG is never armed here: Farland never arms it in this routine and the report's
// counter evidence says this game's copies are PLAIN window stores. A 32-bit operand or an
// EGC-routed variant is not covered (Farland never arms the EGC: its only FF2 writes are num 0
// and num 0x20, never num 2).
module tb_pc9821_gvram_pagecopy;

  // 10 ns = 100 MHz, matching pc9821_gvram_dut's SYS_CLOCK_HZ.
  reg clk = 0;
  always #5 clk = ~clk;

  // The GVRAM DUT's active-HIGH reset and z486's active-LOW one. Separate because
  // the GVRAM must be out of reset for the pre-fill, while the CPU is released after.
  reg reset       = 1'b1;
  reg reset_n_sys = 1'b0;

  // ---------------- guest RAM: the program ----------------
  localparam integer MEM_SIZE = 1 << 20;              // 1 MiB
  localparam [31:0]  MEM_MASK = MEM_SIZE - 1;
  reg [7:0] mem [0:MEM_SIZE-1];

  localparam [31:0] PACK_BASE = 32'h02F8_0000;
  // Base 0, not the direct aperture: this harness forces seg_init_ds to 0 at reset, so a guest
  // `mov ds,ax` does not move the data base - the routine's `mov bx,[0x49C]` read 0 and every
  // computed offset collapsed onto the raw argument (found by dumping the recorded store
  // addresses: all four planes at window offset 0x0100 instead of 0x13C0).
  localparam [31:0] PROG_BASE = 32'h0000_0000;
  localparam [15:0] PROG_SEG  = 16'h0000;

  localparam [31:0] WIN_B = 32'h000A_8000;            // the guest B plane window
  localparam [31:0] WIN_R = 32'h000B_0000;
  localparam [31:0] WIN_G = 32'h000B_8000;
  localparam [31:0] WIN_E = 32'h000E_0000;            // the intensity window

  // ---------------- z486's external bus ----------------
  wire [31:2]  z_addr;
  wire  [3:0]  z_be;
  wire  [7:0]  z_burstcount;
  wire [31:0]  z_dout;
  wire         z_valid, z_write, z_io, z_line_read;
  wire         z_inta;
  reg  [31:0]  z_din;
  reg  [127:0] z_line_din;
  reg          z_ready;
  reg          z_resp_valid;
  reg          z_line_resp_valid;

  // ---------------- the bench's own window master ----------------
  // The plane pre-fill and the read-back drive the GVRAM client directly. z486 is
  // in reset or halted for every one of those cycles, so the masters never overlap.
  reg         bench_valid = 1'b0, bench_write = 1'b0;
  reg  [31:0] bench_addr  = 32'd0, bench_din = 32'd0;
  reg  [3:0]  bench_be    = 4'hF;

  // The CPU access page (port 0xA6), which shifts the whole aperture by one
  // interleaved page. The guest clear runs on page 0; page 1 is the control.
  reg         access_page = 1'b0;
  reg         done        = 1'b0;   // set by the program's sentinel write to port 0xFF

  // The address the plane-window decode sees. z486's own is {z_addr, 2'b00}
  // (z486.sv's address output is 30 bits, "Physical address [31:2]").
  wire [31:0] bus_addr = bench_valid ? bench_addr : (h_valid ? h_addr : {z_addr, 2'b00});

  // ---------------- the REAL map's plane-window decode ----------------
  wire        gvram_window;
  wire [1:0]  gvram_win_plane;
  wire [14:0] gvram_win_offset;

  // ==== DUT ====
  // The 16-colour mode (the guest's OUT 0x6A,0x01, FF2 num 0): this bench reaches the E plane at
  // 0xE0000-0xE7FFF, which the machine maps only in that mode (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b1;
  wire       e_plane_nc;
  pc9821_memory_map map_dut (
      .mode2_16color(mode2_16color),
      .e_plane_nc(e_plane_nc),
      .top_bank(4'd8), .ide_rom_enable(1'b0), .d8_bank(2'b00),
      .ide_ram_gate(1'b1),
      .bios_ram_gate(1'b0), .win0_sel(8'h08), .win0_sel_moved(1'b0),
      .ems_state(2'd0), .ems_page_base(32'd0),
      .pack_base(PACK_BASE), .guest_ram_bytes(PACK_BASE),
      .peg_window(1'b0), .peg_base(32'd0),
      .gvram_window(gvram_window), .gvram_win_plane(gvram_win_plane),
      .gvram_win_offset(gvram_win_offset),
      .cpu_addr(bus_addr), .cpu_addr_raw(bus_addr), .xl_low20(1'b0), .xl_peg(1'b0), .cpu_din(32'd0), .cpu_dout(), .cpu_be(4'h0),
      .cpu_burstcount(8'd1), .cpu_line_read(1'b0),
      // The map's own responder is unused here: the bench serves ordinary RAM
      // itself and only wants this block's plane-window decode.
      .cpu_valid(1'b0), .cpu_write(1'b0),
      .cpu_ready(), .cpu_resp_valid(),
      .mem_addr(), .mem_din(), .mem_dout(32'd0), .mem_be(),
      .mem_burstcount(), .mem_valid(), .mem_write(),
      .mem_ready(1'b1), .mem_resp_valid(1'b0)
  );

  // ---------------- the GVRAM client + GRCG ----------------
  // ---- THE REQUEST HOLDER: the bus master's obligation, which this bench was not meeting ----
  // z486 drops z_valid in the ACCEPT cycle of a read (it completes on `ready` and consumes the
  // datum on the response strobe), but the GVRAM cluster's visit "owns the port from its grant
  // until its own completion - a store's ready, a read's RESPONSE STROBE" (pc9821_gvram_share.sv,
  // where that select is a REGISTER). pc9821_memory_subsystem.sv names the same pattern from the
  // other side: "a bench that holds cpu_valid past the accept". Presenting z486's live pins let
  // the request vanish before its own response: the arbiter returned to C_IDLE, never reached
  // C_RESP2, and the CPU waited for a strobe that could never come (stall_mem + mem_servicing
  // high, z_valid 0, gstate 0 - the trip this bench was instrumented to catch). So the request is
  // latched on first sight and held until the completion above, exactly as the fabric does.
  reg        h_valid = 1'b0, h_write = 1'b0, h_line = 1'b0;
  reg [31:0] h_addr  = 32'd0, h_din = 32'd0;
  reg  [3:0] h_be    = 4'hF;
  wire       gv_req_seen = z_valid && !z_io && gvram_window;
  // THE COMPLETION DIFFERS BY DIRECTION, and getting it wrong is why the hold did not help at
  // first: pc9821_gvram_share says the visit owns the port "until its own completion - a STORE's
  // ready, a READ's RESPONSE STROBE". Releasing a read on `ready` dropped the request before
  // C_RESP2 could strobe, which is the very strobe the CPU is waiting for.
  wire       h_done      = h_write ? gv_cpu_ready : gv_cpu_resp_valid;
  always @(posedge clk) begin
    if (reset_n_sys == 1'b0) begin
      h_valid <= 1'b0;
    end else if (h_valid) begin
      if (h_done) h_valid <= 1'b0;
    end else if (gv_req_seen) begin
      h_valid <= 1'b1;
      h_addr  <= {z_addr, 2'b00};
      h_din   <= z_dout;
      h_be    <= z_be;
      h_write <= z_write;
      h_line  <= z_line_read;
    end
  end

  wire        gv_sel_z = h_valid || (z_valid && !z_io && gvram_window && !h_valid);
  wire        gv_sel   = gv_sel_z || bench_valid;
  wire [31:0] gv_din   = bench_valid ? bench_din   : (h_valid ? h_din  : z_dout);
  wire  [3:0] gv_be    = bench_valid ? bench_be    : (h_valid ? h_be   : z_be);
  wire        gv_write = bench_valid ? bench_write : (h_valid ? h_write: z_write);
  wire        gv_line_read = bench_valid ? 1'b0 : (h_valid ? h_line : z_line_read);

  wire [31:0]  gv_cpu_dout;
  wire [31:0] gv_cpu_line_word;
  wire         gv_cpu_ready, gv_cpu_resp_valid, gv_cpu_line_word_valid;

  // The GRCG's register port, driven by the I/O responder below.
  reg  [7:0] port_addr = 8'd0, port_din = 8'd0;
  reg        port_we   = 1'b0;

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(gvram_win_plane), .win_offset(gvram_win_offset),
      .cpu_din(gv_din), .cpu_be(gv_be), .cpu_line_read(gv_line_read),
      .cpu_valid(gv_sel),
      .cpu_write(gv_write),
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

  // ---------------- the I/O responder (the GRCG's 0x7C / 0x7E) ----------------
  // z486 presents an I/O access as a DWORD-ALIGNED address with the operand's byte
  // lane carried only in `be` (pc9821_system forms {z_addr, 2'b00}); pc9821_iobus
  // steps `lane` = be's first set bit and forms the byte port as base_addr + lane
  // (pc9821_iobus.sv:870-872, `lane_addr = base_addr + {30'd0, lane}`). The responder MUST do the same: without it
  // `out 0x7E,al` (base 0x7C, lane 2) decodes as `out 0x7C,al` and every tile write
  // lands on the mode register, so the GRCG is never armed - which is exactly the
  // false failure this bench reported before the lane was modelled.
  reg  [1:0] io_lane;
  always_comb begin
    if      (z_be[0]) io_lane = 2'd0;
    else if (z_be[1]) io_lane = 2'd1;
    else if (z_be[2]) io_lane = 2'd2;
    else              io_lane = 2'd3;
  end
  wire [7:0] io_port  = bus_addr[7:0] + {6'd0, io_lane};
  wire [7:0] io_wdata = z_dout[{io_lane, 3'b000} +: 8];

  reg  [31:0] io_dout       = 32'd0;
  reg         io_resp_valid = 1'b0;
  wire        io_sel   = z_valid && z_io;
  wire        io_ready = io_sel;

  always @(posedge clk) begin
    if (reset_n_sys == 1'b0) begin
      port_we       <= 1'b0;
      io_resp_valid <= 1'b0;
      io_dout       <= 32'd0;
      done          <= 1'b0;
    end else begin
      port_we       <= 1'b0;
      io_resp_valid <= 1'b0;
      if (io_sel && io_ready) begin
        if (z_write) begin
          // presented the cycle after the bus accept, as pc9821_iobus presents its
          // device-bus write - and the access page is written in that SAME cycle, which
          // is where pc9821_crtc puts it (5'd19: access_page <= io_din[0]). Modelling it
          // here rather than as a bench reg is the point of this bench: the page must
          // have arrived by the time the CPU's NEXT access reaches the window decode.
          case (io_port)
            8'h7C: begin port_we <= 1'b1; port_addr <= 8'h7C; port_din <= io_wdata; end
            8'h7E: begin port_we <= 1'b1; port_addr <= 8'h7E; port_din <= io_wdata; end
            8'hA6: access_page <= io_wdata[0];
            8'hFF: done <= 1'b1;                  // the program's sentinel (out 0xFF,al)
            default: ;
          endcase
        end else begin
          io_resp_valid <= 1'b1;
          io_dout       <= 32'hFFFF_FFFF;   // open bus
        end
      end
    end
  end

  // ---------------- the RAM model (ordinary guest memory) ----------------
  // Mirrors tb_pc98_map's external model: single-cycle ready when idle, one beat
  // per cycle for a burst, writes applied by byte enable. The program sits in the
  // DIRECT aperture so its fetches are single-beat too; the burst path is kept so
  // a cacheable access would not hang.
  reg         ram_read_active    = 1'b0;
  reg  [31:0] ram_read_base      = 32'd0;
  reg   [7:0] ram_read_remaining = 8'd0;
  reg   [7:0] ram_read_index     = 8'd0;
  reg         ram_ready          = 1'b0;
  reg  [31:0] ram_dout           = 32'd0;
  reg         ram_resp_valid     = 1'b0;

  wire ram_sel = z_valid && !z_io && !gvram_window;

  always @(posedge clk) begin
    if (reset_n_sys == 1'b0) begin
      ram_ready          <= 1'b0;
      ram_resp_valid     <= 1'b0;
      ram_read_active    <= 1'b0;
      ram_read_remaining <= 8'd0;
      ram_read_index     <= 8'd0;
      ram_dout           <= 32'd0;
    end else begin
      ram_ready      <= !ram_read_active;
      ram_resp_valid <= 1'b0;
      ram_dout       <= 32'd0;

      if (ram_read_active) begin
        ram_resp_valid <= 1'b1;
        ram_dout <= {mem[(ram_read_base + {22'h0, ram_read_index, 2'b00} + 3) & MEM_MASK],
                     mem[(ram_read_base + {22'h0, ram_read_index, 2'b00} + 2) & MEM_MASK],
                     mem[(ram_read_base + {22'h0, ram_read_index, 2'b00} + 1) & MEM_MASK],
                     mem[(ram_read_base + {22'h0, ram_read_index, 2'b00} + 0) & MEM_MASK]};
        ram_read_index     <= ram_read_index + 8'd1;
        ram_read_remaining <= ram_read_remaining - 8'd1;
        if (ram_read_remaining == 8'd1)
          ram_read_active <= 1'b0;
      end

      if (ram_sel && ram_ready && !ram_read_active) begin
        if (!z_write) begin
          reg [31:0] byte_addr;
          reg  [7:0] burst_len;
          byte_addr = {z_addr, 2'b00} & MEM_MASK;
          burst_len = (z_burstcount == 8'd0) ? 8'd1 : z_burstcount;
          ram_resp_valid <= 1'b1;
          ram_dout <= {mem[byte_addr + 3], mem[byte_addr + 2],
                       mem[byte_addr + 1], mem[byte_addr + 0]};
          ram_ready          <= (burst_len <= 8'd1);
          ram_read_active    <= (burst_len > 8'd1);
          ram_read_base      <= byte_addr;
          ram_read_remaining <= (burst_len > 8'd1) ? (burst_len - 8'd1) : 8'd0;
          ram_read_index     <= 8'd1;
        end else begin
          reg [31:0] byte_addr;
          byte_addr = {z_addr, 2'b00} & MEM_MASK;
          if (z_be[0]) mem[byte_addr+0] <= z_dout[7:0];
          if (z_be[1]) mem[byte_addr+1] <= z_dout[15:8];
          if (z_be[2]) mem[byte_addr+2] <= z_dout[23:16];
          if (z_be[3]) mem[byte_addr+3] <= z_dout[31:24];
        end
      end
    end
  end

  // ---------------- z486's ready/data mux ----------------
  always_comb begin
    if (gv_sel_z) begin
      z_ready           = gv_cpu_ready;
      z_din             = gv_cpu_dout;
      z_resp_valid      = gv_cpu_resp_valid;
      // The CPU's line ports are TIED OFF in the system (pc9821_system.sv's
      // line_din(128'd0)/line_resp_valid(1'b0)): a fill is four word beats on
      // z_resp_valid, which z486's L1 gathers. Nothing drives the line arm.
      z_line_resp_valid = 1'b0;
      z_line_din        = 128'd0;
    end else if (z_io) begin
      z_ready           = io_ready;
      z_din             = io_dout;
      z_resp_valid      = io_resp_valid;
      z_line_resp_valid = 1'b0;
      z_line_din        = 128'd0;
    end else begin
      z_ready           = ram_ready;
      z_din             = ram_dout;
      z_resp_valid      = ram_resp_valid;
      z_line_resp_valid = 1'b0;
      z_line_din        = 128'd0;
    end
  end

  // ---------------- the REAL z486 ----------------
  z486 #(
      `Z486_PC98_MAP_PARAMS
  ) cpu (
      .clk(clk),
      .reset_n(reset_n_sys),
      .device_mmio_enable(1'b0),
      .device_mmio_base(32'h0),
      .win0_unmapped(1'b0),
      .ram_cache_top(32'hffff_ffff),
      .addr(z_addr),
      .be(z_be),
      .burstcount(z_burstcount),
      .line_read(z_line_read),
      .din(z_din),
      .line_din(z_line_din),
      .dout(z_dout),
      .valid(z_valid),
      .ready(z_ready),
      .write(z_write),
      .io(z_io),
      .resp_valid(z_resp_valid),
      .line_resp_valid(z_line_resp_valid),
      .intr(1'b0),
      .nmi(1'b0),
      .inta(z_inta),
      .snoop_addr(32'h0),
      .snoop_valid(1'b0),
      .cache_flush(1'b0),
      .cache_flush_busy(),
      .cache_flush_done(),
      .a20_enable(1'b1),
      .fast_off_req(1'b0), .cache_off_req(1'b0), .x87_off_req(1'b0),
      .single_step(1'b0),
      .dbg_CS(),
      .dbg_EIP(),
      .dbg_CS_base(),
      .dbg_pe(),
      .dbg_vm(),
      .dbg_x87_state(),
      .triple_fault_reset()
  );

  // ==== STIMULUS ====
  // ---------------- the guest clear, byte for byte (FSMAIN.EXE @0xB1C) ----------------
  // The 16-bit real-mode sequence is used verbatim, so the operand encoding -
  // which is what decides the byte enables z486 presents - is the guest's own.
  task automatic load_program;
    begin
mem[PROG_BASE+16'h0000] = 8'hB8;
      mem[PROG_BASE+16'h0001] = 8'h00;
      mem[PROG_BASE+16'h0002] = 8'h00;
      mem[PROG_BASE+16'h0003] = 8'h8E;
      mem[PROG_BASE+16'h0004] = 8'hD8;
      mem[PROG_BASE+16'h0005] = 8'h8E;
      mem[PROG_BASE+16'h0006] = 8'hC0;
      mem[PROG_BASE+16'h0007] = 8'h8E;
      mem[PROG_BASE+16'h0008] = 8'hD0;
      mem[PROG_BASE+16'h0009] = 8'hBC;
      mem[PROG_BASE+16'h000A] = 8'h00;
      mem[PROG_BASE+16'h000B] = 8'h7F;
      mem[PROG_BASE+16'h000C] = 8'h68;
      mem[PROG_BASE+16'h000D] = 8'h00;
      mem[PROG_BASE+16'h000E] = 8'h00;
      mem[PROG_BASE+16'h000F] = 8'h68;
      mem[PROG_BASE+16'h0010] = 8'h00;
      mem[PROG_BASE+16'h0011] = 8'h01;
      mem[PROG_BASE+16'h0012] = 8'h68;
      mem[PROG_BASE+16'h0013] = 8'h00;
      mem[PROG_BASE+16'h0014] = 8'h00;
      mem[PROG_BASE+16'h0015] = 8'h68;
      mem[PROG_BASE+16'h0016] = 8'h00;
      mem[PROG_BASE+16'h0017] = 8'h00;
      mem[PROG_BASE+16'h0018] = 8'h68;
      mem[PROG_BASE+16'h0019] = 8'h00;
      mem[PROG_BASE+16'h001A] = 8'h08;
      mem[PROG_BASE+16'h001B] = 8'hC7;
      mem[PROG_BASE+16'h001C] = 8'h06;
      mem[PROG_BASE+16'h001D] = 8'h9C;
      mem[PROG_BASE+16'h001E] = 8'h04;
      mem[PROG_BASE+16'h001F] = 8'h28;
      mem[PROG_BASE+16'h0020] = 8'h00;
      mem[PROG_BASE+16'h0021] = 8'hE9;
      mem[PROG_BASE+16'h0022] = 8'hDC;
      mem[PROG_BASE+16'h0023] = 8'h00;
      mem[PROG_BASE+16'h0024] = 8'h90;
      mem[PROG_BASE+16'h0025] = 8'h90;
      mem[PROG_BASE+16'h0026] = 8'h90;
      mem[PROG_BASE+16'h0027] = 8'h90;
      mem[PROG_BASE+16'h0028] = 8'h90;
      mem[PROG_BASE+16'h0029] = 8'h90;
      mem[PROG_BASE+16'h002A] = 8'h90;
      mem[PROG_BASE+16'h002B] = 8'h90;
      mem[PROG_BASE+16'h002C] = 8'h90;
      mem[PROG_BASE+16'h002D] = 8'h90;
      mem[PROG_BASE+16'h002E] = 8'h90;
      mem[PROG_BASE+16'h002F] = 8'h90;
      mem[PROG_BASE+16'h0030] = 8'h90;
      mem[PROG_BASE+16'h0031] = 8'h90;
      mem[PROG_BASE+16'h0032] = 8'h90;
      mem[PROG_BASE+16'h0033] = 8'h90;
      mem[PROG_BASE+16'h0034] = 8'h90;
      mem[PROG_BASE+16'h0035] = 8'h90;
      mem[PROG_BASE+16'h0036] = 8'h90;
      mem[PROG_BASE+16'h0037] = 8'h90;
      mem[PROG_BASE+16'h0038] = 8'h90;
      mem[PROG_BASE+16'h0039] = 8'h90;
      mem[PROG_BASE+16'h003A] = 8'h90;
      mem[PROG_BASE+16'h003B] = 8'h90;
      mem[PROG_BASE+16'h003C] = 8'h90;
      mem[PROG_BASE+16'h003D] = 8'h90;
      mem[PROG_BASE+16'h003E] = 8'h90;
      mem[PROG_BASE+16'h003F] = 8'h90;
      mem[PROG_BASE+16'h0040] = 8'h90;
      mem[PROG_BASE+16'h0041] = 8'h90;
      mem[PROG_BASE+16'h0042] = 8'h90;
      mem[PROG_BASE+16'h0043] = 8'h90;
      mem[PROG_BASE+16'h0044] = 8'h90;
      mem[PROG_BASE+16'h0045] = 8'h90;
      mem[PROG_BASE+16'h0046] = 8'h90;
      mem[PROG_BASE+16'h0047] = 8'h90;
      mem[PROG_BASE+16'h0048] = 8'h90;
      mem[PROG_BASE+16'h0049] = 8'h90;
      mem[PROG_BASE+16'h004A] = 8'h90;
      mem[PROG_BASE+16'h004B] = 8'h90;
      mem[PROG_BASE+16'h004C] = 8'h90;
      mem[PROG_BASE+16'h004D] = 8'h90;
      mem[PROG_BASE+16'h004E] = 8'h90;
      mem[PROG_BASE+16'h004F] = 8'h90;
      mem[PROG_BASE+16'h0050] = 8'h90;
      mem[PROG_BASE+16'h0051] = 8'h90;
      mem[PROG_BASE+16'h0052] = 8'h90;
      mem[PROG_BASE+16'h0053] = 8'h90;
      mem[PROG_BASE+16'h0054] = 8'h90;
      mem[PROG_BASE+16'h0055] = 8'h90;
      mem[PROG_BASE+16'h0056] = 8'h90;
      mem[PROG_BASE+16'h0057] = 8'h90;
      mem[PROG_BASE+16'h0058] = 8'h90;
      mem[PROG_BASE+16'h0059] = 8'h90;
      mem[PROG_BASE+16'h005A] = 8'h90;
      mem[PROG_BASE+16'h005B] = 8'h90;
      mem[PROG_BASE+16'h005C] = 8'h90;
      mem[PROG_BASE+16'h005D] = 8'h90;
      mem[PROG_BASE+16'h005E] = 8'h90;
      mem[PROG_BASE+16'h005F] = 8'h90;
      mem[PROG_BASE+16'h0060] = 8'h90;
      mem[PROG_BASE+16'h0061] = 8'h90;
      mem[PROG_BASE+16'h0062] = 8'h90;
      mem[PROG_BASE+16'h0063] = 8'h90;
      mem[PROG_BASE+16'h0064] = 8'h90;
      mem[PROG_BASE+16'h0065] = 8'h90;
      mem[PROG_BASE+16'h0066] = 8'h90;
      mem[PROG_BASE+16'h0067] = 8'h90;
      mem[PROG_BASE+16'h0068] = 8'h90;
      mem[PROG_BASE+16'h0069] = 8'h90;
      mem[PROG_BASE+16'h006A] = 8'h90;
      mem[PROG_BASE+16'h006B] = 8'h90;
      mem[PROG_BASE+16'h006C] = 8'h90;
      mem[PROG_BASE+16'h006D] = 8'h90;
      mem[PROG_BASE+16'h006E] = 8'h90;
      mem[PROG_BASE+16'h006F] = 8'h90;
      mem[PROG_BASE+16'h0070] = 8'h90;
      mem[PROG_BASE+16'h0071] = 8'h90;
      mem[PROG_BASE+16'h0072] = 8'h90;
      mem[PROG_BASE+16'h0073] = 8'h90;
      mem[PROG_BASE+16'h0074] = 8'h90;
      mem[PROG_BASE+16'h0075] = 8'h90;
      mem[PROG_BASE+16'h0076] = 8'h90;
      mem[PROG_BASE+16'h0077] = 8'h90;
      mem[PROG_BASE+16'h0078] = 8'h90;
      mem[PROG_BASE+16'h0079] = 8'h90;
      mem[PROG_BASE+16'h007A] = 8'h90;
      mem[PROG_BASE+16'h007B] = 8'h90;
      mem[PROG_BASE+16'h007C] = 8'h90;
      mem[PROG_BASE+16'h007D] = 8'h90;
      mem[PROG_BASE+16'h007E] = 8'h90;
      mem[PROG_BASE+16'h007F] = 8'h90;
      mem[PROG_BASE+16'h0080] = 8'h90;
      mem[PROG_BASE+16'h0081] = 8'h90;
      mem[PROG_BASE+16'h0082] = 8'h90;
      mem[PROG_BASE+16'h0083] = 8'h90;
      mem[PROG_BASE+16'h0084] = 8'h90;
      mem[PROG_BASE+16'h0085] = 8'h90;
      mem[PROG_BASE+16'h0086] = 8'h90;
      mem[PROG_BASE+16'h0087] = 8'h90;
      mem[PROG_BASE+16'h0088] = 8'h90;
      mem[PROG_BASE+16'h0089] = 8'h90;
      mem[PROG_BASE+16'h008A] = 8'h90;
      mem[PROG_BASE+16'h008B] = 8'h90;
      mem[PROG_BASE+16'h008C] = 8'h90;
      mem[PROG_BASE+16'h008D] = 8'h90;
      mem[PROG_BASE+16'h008E] = 8'h90;
      mem[PROG_BASE+16'h008F] = 8'h90;
      mem[PROG_BASE+16'h0090] = 8'h90;
      mem[PROG_BASE+16'h0091] = 8'h90;
      mem[PROG_BASE+16'h0092] = 8'h90;
      mem[PROG_BASE+16'h0093] = 8'h90;
      mem[PROG_BASE+16'h0094] = 8'h90;
      mem[PROG_BASE+16'h0095] = 8'h90;
      mem[PROG_BASE+16'h0096] = 8'h90;
      mem[PROG_BASE+16'h0097] = 8'h90;
      mem[PROG_BASE+16'h0098] = 8'h90;
      mem[PROG_BASE+16'h0099] = 8'h90;
      mem[PROG_BASE+16'h009A] = 8'h90;
      mem[PROG_BASE+16'h009B] = 8'h90;
      mem[PROG_BASE+16'h009C] = 8'h90;
      mem[PROG_BASE+16'h009D] = 8'h90;
      mem[PROG_BASE+16'h009E] = 8'h90;
      mem[PROG_BASE+16'h009F] = 8'h90;
      mem[PROG_BASE+16'h00A0] = 8'h90;
      mem[PROG_BASE+16'h00A1] = 8'h90;
      mem[PROG_BASE+16'h00A2] = 8'h90;
      mem[PROG_BASE+16'h00A3] = 8'h90;
      mem[PROG_BASE+16'h00A4] = 8'h90;
      mem[PROG_BASE+16'h00A5] = 8'h90;
      mem[PROG_BASE+16'h00A6] = 8'h90;
      mem[PROG_BASE+16'h00A7] = 8'h90;
      mem[PROG_BASE+16'h00A8] = 8'h90;
      mem[PROG_BASE+16'h00A9] = 8'h90;
      mem[PROG_BASE+16'h00AA] = 8'h90;
      mem[PROG_BASE+16'h00AB] = 8'h90;
      mem[PROG_BASE+16'h00AC] = 8'h90;
      mem[PROG_BASE+16'h00AD] = 8'h90;
      mem[PROG_BASE+16'h00AE] = 8'h90;
      mem[PROG_BASE+16'h00AF] = 8'h90;
      mem[PROG_BASE+16'h00B0] = 8'h90;
      mem[PROG_BASE+16'h00B1] = 8'h90;
      mem[PROG_BASE+16'h00B2] = 8'h90;
      mem[PROG_BASE+16'h00B3] = 8'h90;
      mem[PROG_BASE+16'h00B4] = 8'h90;
      mem[PROG_BASE+16'h00B5] = 8'h90;
      mem[PROG_BASE+16'h00B6] = 8'h90;
      mem[PROG_BASE+16'h00B7] = 8'h90;
      mem[PROG_BASE+16'h00B8] = 8'h90;
      mem[PROG_BASE+16'h00B9] = 8'h90;
      mem[PROG_BASE+16'h00BA] = 8'h90;
      mem[PROG_BASE+16'h00BB] = 8'h90;
      mem[PROG_BASE+16'h00BC] = 8'h90;
      mem[PROG_BASE+16'h00BD] = 8'h90;
      mem[PROG_BASE+16'h00BE] = 8'h90;
      mem[PROG_BASE+16'h00BF] = 8'h90;
      mem[PROG_BASE+16'h00C0] = 8'h90;
      mem[PROG_BASE+16'h00C1] = 8'h90;
      mem[PROG_BASE+16'h00C2] = 8'h90;
      mem[PROG_BASE+16'h00C3] = 8'h90;
      mem[PROG_BASE+16'h00C4] = 8'h90;
      mem[PROG_BASE+16'h00C5] = 8'h90;
      mem[PROG_BASE+16'h00C6] = 8'h90;
      mem[PROG_BASE+16'h00C7] = 8'h90;
      mem[PROG_BASE+16'h00C8] = 8'h90;
      mem[PROG_BASE+16'h00C9] = 8'h90;
      mem[PROG_BASE+16'h00CA] = 8'h90;
      mem[PROG_BASE+16'h00CB] = 8'h90;
      mem[PROG_BASE+16'h00CC] = 8'h90;
      mem[PROG_BASE+16'h00CD] = 8'h90;
      mem[PROG_BASE+16'h00CE] = 8'h90;
      mem[PROG_BASE+16'h00CF] = 8'h90;
      mem[PROG_BASE+16'h00D0] = 8'h90;
      mem[PROG_BASE+16'h00D1] = 8'h90;
      mem[PROG_BASE+16'h00D2] = 8'h90;
      mem[PROG_BASE+16'h00D3] = 8'h90;
      mem[PROG_BASE+16'h00D4] = 8'h90;
      mem[PROG_BASE+16'h00D5] = 8'h90;
      mem[PROG_BASE+16'h00D6] = 8'h90;
      mem[PROG_BASE+16'h00D7] = 8'h90;
      mem[PROG_BASE+16'h00D8] = 8'h90;
      mem[PROG_BASE+16'h00D9] = 8'h90;
      mem[PROG_BASE+16'h00DA] = 8'h90;
      mem[PROG_BASE+16'h00DB] = 8'h90;
      mem[PROG_BASE+16'h00DC] = 8'h90;
      mem[PROG_BASE+16'h00DD] = 8'h90;
      mem[PROG_BASE+16'h00DE] = 8'h90;
      mem[PROG_BASE+16'h00DF] = 8'h90;
      mem[PROG_BASE+16'h00E0] = 8'h90;
      mem[PROG_BASE+16'h00E1] = 8'h90;
      mem[PROG_BASE+16'h00E2] = 8'h90;
      mem[PROG_BASE+16'h00E3] = 8'h90;
      mem[PROG_BASE+16'h00E4] = 8'h90;
      mem[PROG_BASE+16'h00E5] = 8'h90;
      mem[PROG_BASE+16'h00E6] = 8'h90;
      mem[PROG_BASE+16'h00E7] = 8'h90;
      mem[PROG_BASE+16'h00E8] = 8'h90;
      mem[PROG_BASE+16'h00E9] = 8'h90;
      mem[PROG_BASE+16'h00EA] = 8'h90;
      mem[PROG_BASE+16'h00EB] = 8'h90;
      mem[PROG_BASE+16'h00EC] = 8'h90;
      mem[PROG_BASE+16'h00ED] = 8'h90;
      mem[PROG_BASE+16'h00EE] = 8'h90;
      mem[PROG_BASE+16'h00EF] = 8'h90;
      mem[PROG_BASE+16'h00F0] = 8'h90;
      mem[PROG_BASE+16'h00F1] = 8'h90;
      mem[PROG_BASE+16'h00F2] = 8'h90;
      mem[PROG_BASE+16'h00F3] = 8'h90;
      mem[PROG_BASE+16'h00F4] = 8'h90;
      mem[PROG_BASE+16'h00F5] = 8'h90;
      mem[PROG_BASE+16'h00F6] = 8'h90;
      mem[PROG_BASE+16'h00F7] = 8'h90;
      mem[PROG_BASE+16'h00F8] = 8'h90;
      mem[PROG_BASE+16'h00F9] = 8'h90;
      mem[PROG_BASE+16'h00FA] = 8'h90;
      mem[PROG_BASE+16'h00FB] = 8'h90;
      mem[PROG_BASE+16'h00FC] = 8'h90;
      mem[PROG_BASE+16'h00FD] = 8'h90;
      mem[PROG_BASE+16'h00FE] = 8'h90;
      mem[PROG_BASE+16'h00FF] = 8'h90;
      mem[PROG_BASE+16'h0100] = 8'h55;
      mem[PROG_BASE+16'h0101] = 8'h8B;
      mem[PROG_BASE+16'h0102] = 8'hEC;
      mem[PROG_BASE+16'h0103] = 8'h56;
      mem[PROG_BASE+16'h0104] = 8'h57;
      mem[PROG_BASE+16'h0105] = 8'h1E;
      mem[PROG_BASE+16'h0106] = 8'hFC;
      mem[PROG_BASE+16'h0107] = 8'h8B;
      mem[PROG_BASE+16'h0108] = 8'h1E;
      mem[PROG_BASE+16'h0109] = 8'h9C;
      mem[PROG_BASE+16'h010A] = 8'h04;
      mem[PROG_BASE+16'h010B] = 8'hB8;
      mem[PROG_BASE+16'h010C] = 8'h78;
      mem[PROG_BASE+16'h010D] = 8'h00;
      mem[PROG_BASE+16'h010E] = 8'h2B;
      mem[PROG_BASE+16'h010F] = 8'h46;
      mem[PROG_BASE+16'h0110] = 8'h0A;
      mem[PROG_BASE+16'h0111] = 8'hF7;
      mem[PROG_BASE+16'h0112] = 8'hE3;
      mem[PROG_BASE+16'h0113] = 8'h03;
      mem[PROG_BASE+16'h0114] = 8'h46;
      mem[PROG_BASE+16'h0115] = 8'h08;
      mem[PROG_BASE+16'h0116] = 8'h8B;
      mem[PROG_BASE+16'h0117] = 8'hF8;
      mem[PROG_BASE+16'h0118] = 8'hB8;
      mem[PROG_BASE+16'h0119] = 8'h78;
      mem[PROG_BASE+16'h011A] = 8'h00;
      mem[PROG_BASE+16'h011B] = 8'h2B;
      mem[PROG_BASE+16'h011C] = 8'h46;
      mem[PROG_BASE+16'h011D] = 8'h0A;
      mem[PROG_BASE+16'h011E] = 8'h05;
      mem[PROG_BASE+16'h011F] = 8'h05;
      mem[PROG_BASE+16'h0120] = 8'h00;
      mem[PROG_BASE+16'h0121] = 8'hF7;
      mem[PROG_BASE+16'h0122] = 8'hE3;
      mem[PROG_BASE+16'h0123] = 8'h03;
      mem[PROG_BASE+16'h0124] = 8'h46;
      mem[PROG_BASE+16'h0125] = 8'h08;
      mem[PROG_BASE+16'h0126] = 8'h8B;
      mem[PROG_BASE+16'h0127] = 8'hD0;
      mem[PROG_BASE+16'h0128] = 8'hB8;
      mem[PROG_BASE+16'h0129] = 8'h00;
      mem[PROG_BASE+16'h012A] = 8'hA8;
      mem[PROG_BASE+16'h012B] = 8'h52;
      mem[PROG_BASE+16'h012C] = 8'h57;
      mem[PROG_BASE+16'h012D] = 8'h8C;
      mem[PROG_BASE+16'h012E] = 8'hD9;
      mem[PROG_BASE+16'h012F] = 8'h8E;
      mem[PROG_BASE+16'h0130] = 8'hC1;
      mem[PROG_BASE+16'h0131] = 8'h8E;
      mem[PROG_BASE+16'h0132] = 8'hD8;
      mem[PROG_BASE+16'h0133] = 8'h8B;
      mem[PROG_BASE+16'h0134] = 8'h46;
      mem[PROG_BASE+16'h0135] = 8'h06;
      mem[PROG_BASE+16'h0136] = 8'h35;
      mem[PROG_BASE+16'h0137] = 8'h01;
      mem[PROG_BASE+16'h0138] = 8'h00;
      mem[PROG_BASE+16'h0139] = 8'hE6;
      mem[PROG_BASE+16'h013A] = 8'hA6;
      mem[PROG_BASE+16'h013B] = 8'hBF;
      mem[PROG_BASE+16'h013C] = 8'hD2;
      mem[PROG_BASE+16'h013D] = 8'h5C;
      mem[PROG_BASE+16'h013E] = 8'h8B;
      mem[PROG_BASE+16'h013F] = 8'h76;
      mem[PROG_BASE+16'h0140] = 8'h08;
      mem[PROG_BASE+16'h0141] = 8'hB9;
      mem[PROG_BASE+16'h0142] = 8'hC8;
      mem[PROG_BASE+16'h0143] = 8'h00;
      mem[PROG_BASE+16'h0144] = 8'hF3;
      mem[PROG_BASE+16'h0145] = 8'hA5;
      mem[PROG_BASE+16'h0146] = 8'h8B;
      mem[PROG_BASE+16'h0147] = 8'hF2;
      mem[PROG_BASE+16'h0148] = 8'hB9;
      mem[PROG_BASE+16'h0149] = 8'hA0;
      mem[PROG_BASE+16'h014A] = 8'h00;
      mem[PROG_BASE+16'h014B] = 8'hF3;
      mem[PROG_BASE+16'h014C] = 8'hA5;
      mem[PROG_BASE+16'h014D] = 8'h8C;
      mem[PROG_BASE+16'h014E] = 8'hC0;
      mem[PROG_BASE+16'h014F] = 8'h8C;
      mem[PROG_BASE+16'h0150] = 8'hD9;
      mem[PROG_BASE+16'h0151] = 8'h8E;
      mem[PROG_BASE+16'h0152] = 8'hC1;
      mem[PROG_BASE+16'h0153] = 8'h8E;
      mem[PROG_BASE+16'h0154] = 8'hD8;
      mem[PROG_BASE+16'h0155] = 8'h8B;
      mem[PROG_BASE+16'h0156] = 8'h46;
      mem[PROG_BASE+16'h0157] = 8'h06;
      mem[PROG_BASE+16'h0158] = 8'hE6;
      mem[PROG_BASE+16'h0159] = 8'hA6;
      mem[PROG_BASE+16'h015A] = 8'h5F;
      mem[PROG_BASE+16'h015B] = 8'h57;
      mem[PROG_BASE+16'h015C] = 8'hBE;
      mem[PROG_BASE+16'h015D] = 8'hD2;
      mem[PROG_BASE+16'h015E] = 8'h5C;
      mem[PROG_BASE+16'h015F] = 8'hB9;
      mem[PROG_BASE+16'h0160] = 8'h68;
      mem[PROG_BASE+16'h0161] = 8'h01;
      mem[PROG_BASE+16'h0162] = 8'hF3;
      mem[PROG_BASE+16'h0163] = 8'hA5;
      mem[PROG_BASE+16'h0164] = 8'h5F;
      mem[PROG_BASE+16'h0165] = 8'h5A;
      mem[PROG_BASE+16'h0166] = 8'h8C;
      mem[PROG_BASE+16'h0167] = 8'hC0;
      mem[PROG_BASE+16'h0168] = 8'h05;
      mem[PROG_BASE+16'h0169] = 8'h00;
      mem[PROG_BASE+16'h016A] = 8'h08;
      mem[PROG_BASE+16'h016B] = 8'h3D;
      mem[PROG_BASE+16'h016C] = 8'h00;
      mem[PROG_BASE+16'h016D] = 8'hC0;
      mem[PROG_BASE+16'h016E] = 8'h72;
      mem[PROG_BASE+16'h016F] = 8'hBB;
      mem[PROG_BASE+16'h0170] = 8'h3D;
      mem[PROG_BASE+16'h0171] = 8'h00;
      mem[PROG_BASE+16'h0172] = 8'hE0;
      mem[PROG_BASE+16'h0173] = 8'hB8;
      mem[PROG_BASE+16'h0174] = 8'h00;
      mem[PROG_BASE+16'h0175] = 8'hE0;
      mem[PROG_BASE+16'h0176] = 8'h72;
      mem[PROG_BASE+16'h0177] = 8'hB3;
      mem[PROG_BASE+16'h0178] = 8'h90;
      mem[PROG_BASE+16'h0179] = 8'h90;
      mem[PROG_BASE+16'h017A] = 8'h90;
      mem[PROG_BASE+16'h017B] = 8'h90;
      mem[PROG_BASE+16'h017C] = 8'h90;
      mem[PROG_BASE+16'h017D] = 8'h90;
      mem[PROG_BASE+16'h017E] = 8'h90;
      mem[PROG_BASE+16'h017F] = 8'h90;
      mem[PROG_BASE+16'h0180] = 8'h90;
      mem[PROG_BASE+16'h0181] = 8'h90;
      mem[PROG_BASE+16'h0182] = 8'h90;
      mem[PROG_BASE+16'h0183] = 8'h90;
      mem[PROG_BASE+16'h0184] = 8'h90;
      mem[PROG_BASE+16'h0185] = 8'h90;
      mem[PROG_BASE+16'h0186] = 8'h90;
      mem[PROG_BASE+16'h0187] = 8'h90;
      mem[PROG_BASE+16'h0188] = 8'h90;
      mem[PROG_BASE+16'h0189] = 8'h90;
      mem[PROG_BASE+16'h018A] = 8'h90;
      mem[PROG_BASE+16'h018B] = 8'h90;
      mem[PROG_BASE+16'h018C] = 8'h90;
      mem[PROG_BASE+16'h018D] = 8'h90;
      mem[PROG_BASE+16'h018E] = 8'h90;
      mem[PROG_BASE+16'h018F] = 8'h90;
      mem[PROG_BASE+16'h0190] = 8'h90;
      mem[PROG_BASE+16'h0191] = 8'h90;
      mem[PROG_BASE+16'h0192] = 8'h90;
      mem[PROG_BASE+16'h0193] = 8'h90;
      mem[PROG_BASE+16'h0194] = 8'h90;
      mem[PROG_BASE+16'h0195] = 8'h90;
      mem[PROG_BASE+16'h0196] = 8'h90;
      mem[PROG_BASE+16'h0197] = 8'h90;
      mem[PROG_BASE+16'h0198] = 8'h90;
      mem[PROG_BASE+16'h0199] = 8'h90;
      mem[PROG_BASE+16'h019A] = 8'h90;
      mem[PROG_BASE+16'h019B] = 8'h90;
      mem[PROG_BASE+16'h019C] = 8'h90;
      mem[PROG_BASE+16'h019D] = 8'h90;
      mem[PROG_BASE+16'h019E] = 8'h90;
      mem[PROG_BASE+16'h019F] = 8'h90;
      mem[PROG_BASE+16'h01A0] = 8'h90;
      mem[PROG_BASE+16'h01A1] = 8'h90;
      mem[PROG_BASE+16'h01A2] = 8'h90;
      mem[PROG_BASE+16'h01A3] = 8'h90;
      mem[PROG_BASE+16'h01A4] = 8'h90;
      mem[PROG_BASE+16'h01A5] = 8'h90;
      mem[PROG_BASE+16'h01A6] = 8'h90;
      mem[PROG_BASE+16'h01A7] = 8'h90;
      mem[PROG_BASE+16'h01A8] = 8'h90;
      mem[PROG_BASE+16'h01A9] = 8'h90;
      mem[PROG_BASE+16'h01AA] = 8'h90;
      mem[PROG_BASE+16'h01AB] = 8'h90;
      mem[PROG_BASE+16'h01AC] = 8'h90;
      mem[PROG_BASE+16'h01AD] = 8'h90;
      mem[PROG_BASE+16'h01AE] = 8'h90;
      mem[PROG_BASE+16'h01AF] = 8'h90;
      mem[PROG_BASE+16'h01B0] = 8'h90;
      mem[PROG_BASE+16'h01B1] = 8'h90;
      mem[PROG_BASE+16'h01B2] = 8'h90;
      mem[PROG_BASE+16'h01B3] = 8'h90;
      mem[PROG_BASE+16'h01B4] = 8'h90;
      mem[PROG_BASE+16'h01B5] = 8'h90;
      mem[PROG_BASE+16'h01B6] = 8'h90;
      mem[PROG_BASE+16'h01B7] = 8'h90;
      mem[PROG_BASE+16'h01B8] = 8'h90;
      mem[PROG_BASE+16'h01B9] = 8'h90;
      mem[PROG_BASE+16'h01BA] = 8'h90;
      mem[PROG_BASE+16'h01BB] = 8'h90;
      mem[PROG_BASE+16'h01BC] = 8'h90;
      mem[PROG_BASE+16'h01BD] = 8'h90;
      mem[PROG_BASE+16'h01BE] = 8'h90;
      mem[PROG_BASE+16'h01BF] = 8'h90;
      mem[PROG_BASE+16'h01C0] = 8'h90;
      mem[PROG_BASE+16'h01C1] = 8'h90;
      mem[PROG_BASE+16'h01C2] = 8'h90;
      mem[PROG_BASE+16'h01C3] = 8'h90;
      mem[PROG_BASE+16'h01C4] = 8'h90;
      mem[PROG_BASE+16'h01C5] = 8'h90;
      mem[PROG_BASE+16'h01C6] = 8'h90;
      mem[PROG_BASE+16'h01C7] = 8'h90;
      mem[PROG_BASE+16'h01C8] = 8'h90;
      mem[PROG_BASE+16'h01C9] = 8'h90;
      mem[PROG_BASE+16'h01CA] = 8'h90;
      mem[PROG_BASE+16'h01CB] = 8'h90;
      mem[PROG_BASE+16'h01CC] = 8'h90;
      mem[PROG_BASE+16'h01CD] = 8'h90;
      mem[PROG_BASE+16'h01CE] = 8'h90;
      mem[PROG_BASE+16'h01CF] = 8'h90;
      mem[PROG_BASE+16'h01D0] = 8'h90;
      mem[PROG_BASE+16'h01D1] = 8'h90;
      mem[PROG_BASE+16'h01D2] = 8'h90;
      mem[PROG_BASE+16'h01D3] = 8'h90;
      mem[PROG_BASE+16'h01D4] = 8'h90;
      mem[PROG_BASE+16'h01D5] = 8'h90;
      mem[PROG_BASE+16'h01D6] = 8'h90;
      mem[PROG_BASE+16'h01D7] = 8'h90;
      mem[PROG_BASE+16'h01D8] = 8'h90;
      mem[PROG_BASE+16'h01D9] = 8'h90;
      mem[PROG_BASE+16'h01DA] = 8'h90;
      mem[PROG_BASE+16'h01DB] = 8'h90;
      mem[PROG_BASE+16'h01DC] = 8'h90;
      mem[PROG_BASE+16'h01DD] = 8'h90;
      mem[PROG_BASE+16'h01DE] = 8'h90;
      mem[PROG_BASE+16'h01DF] = 8'h90;
      mem[PROG_BASE+16'h01E0] = 8'h90;
      mem[PROG_BASE+16'h01E1] = 8'h90;
      mem[PROG_BASE+16'h01E2] = 8'h90;
      mem[PROG_BASE+16'h01E3] = 8'h90;
      mem[PROG_BASE+16'h01E4] = 8'h90;
      mem[PROG_BASE+16'h01E5] = 8'h90;
      mem[PROG_BASE+16'h01E6] = 8'h90;
      mem[PROG_BASE+16'h01E7] = 8'h90;
      mem[PROG_BASE+16'h01E8] = 8'h90;
      mem[PROG_BASE+16'h01E9] = 8'h90;
      mem[PROG_BASE+16'h01EA] = 8'h90;
      mem[PROG_BASE+16'h01EB] = 8'h90;
      mem[PROG_BASE+16'h01EC] = 8'h90;
      mem[PROG_BASE+16'h01ED] = 8'h90;
      mem[PROG_BASE+16'h01EE] = 8'h90;
      mem[PROG_BASE+16'h01EF] = 8'h90;
      mem[PROG_BASE+16'h01F0] = 8'h90;
      mem[PROG_BASE+16'h01F1] = 8'h90;
      mem[PROG_BASE+16'h01F2] = 8'h90;
      mem[PROG_BASE+16'h01F3] = 8'h90;
      mem[PROG_BASE+16'h01F4] = 8'h90;
      mem[PROG_BASE+16'h01F5] = 8'h90;
      mem[PROG_BASE+16'h01F6] = 8'h90;
      mem[PROG_BASE+16'h01F7] = 8'h90;
      mem[PROG_BASE+16'h01F8] = 8'h90;
      mem[PROG_BASE+16'h01F9] = 8'h90;
      mem[PROG_BASE+16'h01FA] = 8'h90;
      mem[PROG_BASE+16'h01FB] = 8'h90;
      mem[PROG_BASE+16'h01FC] = 8'h90;
      mem[PROG_BASE+16'h01FD] = 8'h90;
      mem[PROG_BASE+16'h01FE] = 8'h90;
      mem[PROG_BASE+16'h01FF] = 8'h90;
      mem[PROG_BASE+16'h0200] = 8'h90;
      mem[PROG_BASE+16'h0201] = 8'h90;
      mem[PROG_BASE+16'h0202] = 8'h90;
      mem[PROG_BASE+16'h0203] = 8'h90;
      mem[PROG_BASE+16'h0204] = 8'h90;
      mem[PROG_BASE+16'h0205] = 8'h90;
      mem[PROG_BASE+16'h0206] = 8'h90;
      mem[PROG_BASE+16'h0207] = 8'h90;
      mem[PROG_BASE+16'h0208] = 8'h90;
      mem[PROG_BASE+16'h0209] = 8'h90;
      mem[PROG_BASE+16'h020A] = 8'h90;
      mem[PROG_BASE+16'h020B] = 8'h90;
      mem[PROG_BASE+16'h020C] = 8'h90;
      mem[PROG_BASE+16'h020D] = 8'h90;
      mem[PROG_BASE+16'h020E] = 8'h90;
      mem[PROG_BASE+16'h020F] = 8'h90;
      mem[PROG_BASE+16'h0210] = 8'h90;
      mem[PROG_BASE+16'h0211] = 8'h90;
      mem[PROG_BASE+16'h0212] = 8'h90;
      mem[PROG_BASE+16'h0213] = 8'h90;
      mem[PROG_BASE+16'h0214] = 8'h90;
      mem[PROG_BASE+16'h0215] = 8'h90;
      mem[PROG_BASE+16'h0216] = 8'h90;
      mem[PROG_BASE+16'h0217] = 8'h90;
      mem[PROG_BASE+16'h0218] = 8'h90;
      mem[PROG_BASE+16'h0219] = 8'h90;
      mem[PROG_BASE+16'h021A] = 8'h90;
      mem[PROG_BASE+16'h021B] = 8'h90;
      mem[PROG_BASE+16'h021C] = 8'h90;
      mem[PROG_BASE+16'h021D] = 8'h90;
      mem[PROG_BASE+16'h021E] = 8'h90;
      mem[PROG_BASE+16'h021F] = 8'h90;
      mem[PROG_BASE+16'h0220] = 8'h90;
      mem[PROG_BASE+16'h0221] = 8'h90;
      mem[PROG_BASE+16'h0222] = 8'h90;
      mem[PROG_BASE+16'h0223] = 8'h90;
      mem[PROG_BASE+16'h0224] = 8'h90;
      mem[PROG_BASE+16'h0225] = 8'h90;
      mem[PROG_BASE+16'h0226] = 8'h90;
      mem[PROG_BASE+16'h0227] = 8'h90;
      mem[PROG_BASE+16'h0228] = 8'h90;
      mem[PROG_BASE+16'h0229] = 8'h90;
      mem[PROG_BASE+16'h022A] = 8'h90;
      mem[PROG_BASE+16'h022B] = 8'h90;
      mem[PROG_BASE+16'h022C] = 8'h90;
      mem[PROG_BASE+16'h022D] = 8'h90;
      mem[PROG_BASE+16'h022E] = 8'h90;
      mem[PROG_BASE+16'h022F] = 8'h90;
      mem[PROG_BASE+16'h0230] = 8'h90;
      mem[PROG_BASE+16'h0231] = 8'h90;
      mem[PROG_BASE+16'h0232] = 8'h90;
      mem[PROG_BASE+16'h0233] = 8'h90;
      mem[PROG_BASE+16'h0234] = 8'h90;
      mem[PROG_BASE+16'h0235] = 8'h90;
      mem[PROG_BASE+16'h0236] = 8'h90;
      mem[PROG_BASE+16'h0237] = 8'h90;
      mem[PROG_BASE+16'h0238] = 8'h90;
      mem[PROG_BASE+16'h0239] = 8'h90;
      mem[PROG_BASE+16'h023A] = 8'h90;
      mem[PROG_BASE+16'h023B] = 8'h90;
      mem[PROG_BASE+16'h023C] = 8'h90;
      mem[PROG_BASE+16'h023D] = 8'h90;
      mem[PROG_BASE+16'h023E] = 8'h90;
      mem[PROG_BASE+16'h023F] = 8'h90;
      mem[PROG_BASE+16'h0240] = 8'h90;
      mem[PROG_BASE+16'h0241] = 8'h90;
      mem[PROG_BASE+16'h0242] = 8'h90;
      mem[PROG_BASE+16'h0243] = 8'h90;
      mem[PROG_BASE+16'h0244] = 8'h90;
      mem[PROG_BASE+16'h0245] = 8'h90;
      mem[PROG_BASE+16'h0246] = 8'h90;
      mem[PROG_BASE+16'h0247] = 8'h90;
      mem[PROG_BASE+16'h0248] = 8'h90;
      mem[PROG_BASE+16'h0249] = 8'h90;
      mem[PROG_BASE+16'h024A] = 8'h90;
      mem[PROG_BASE+16'h024B] = 8'h90;
      mem[PROG_BASE+16'h024C] = 8'h90;
      mem[PROG_BASE+16'h024D] = 8'h90;
      mem[PROG_BASE+16'h024E] = 8'h90;
      mem[PROG_BASE+16'h024F] = 8'h90;
      mem[PROG_BASE+16'h0250] = 8'h90;
      mem[PROG_BASE+16'h0251] = 8'h90;
      mem[PROG_BASE+16'h0252] = 8'h90;
      mem[PROG_BASE+16'h0253] = 8'h90;
      mem[PROG_BASE+16'h0254] = 8'h90;
      mem[PROG_BASE+16'h0255] = 8'h90;
      mem[PROG_BASE+16'h0256] = 8'h90;
      mem[PROG_BASE+16'h0257] = 8'h90;
      mem[PROG_BASE+16'h0258] = 8'h90;
      mem[PROG_BASE+16'h0259] = 8'h90;
      mem[PROG_BASE+16'h025A] = 8'h90;
      mem[PROG_BASE+16'h025B] = 8'h90;
      mem[PROG_BASE+16'h025C] = 8'h90;
      mem[PROG_BASE+16'h025D] = 8'h90;
      mem[PROG_BASE+16'h025E] = 8'h90;
      mem[PROG_BASE+16'h025F] = 8'h90;
      mem[PROG_BASE+16'h0260] = 8'h90;
      mem[PROG_BASE+16'h0261] = 8'h90;
      mem[PROG_BASE+16'h0262] = 8'h90;
      mem[PROG_BASE+16'h0263] = 8'h90;
      mem[PROG_BASE+16'h0264] = 8'h90;
      mem[PROG_BASE+16'h0265] = 8'h90;
      mem[PROG_BASE+16'h0266] = 8'h90;
      mem[PROG_BASE+16'h0267] = 8'h90;
      mem[PROG_BASE+16'h0268] = 8'h90;
      mem[PROG_BASE+16'h0269] = 8'h90;
      mem[PROG_BASE+16'h026A] = 8'h90;
      mem[PROG_BASE+16'h026B] = 8'h90;
      mem[PROG_BASE+16'h026C] = 8'h90;
      mem[PROG_BASE+16'h026D] = 8'h90;
      mem[PROG_BASE+16'h026E] = 8'h90;
      mem[PROG_BASE+16'h026F] = 8'h90;
      mem[PROG_BASE+16'h0270] = 8'h90;
      mem[PROG_BASE+16'h0271] = 8'h90;
      mem[PROG_BASE+16'h0272] = 8'h90;
      mem[PROG_BASE+16'h0273] = 8'h90;
      mem[PROG_BASE+16'h0274] = 8'h90;
      mem[PROG_BASE+16'h0275] = 8'h90;
      mem[PROG_BASE+16'h0276] = 8'h90;
      mem[PROG_BASE+16'h0277] = 8'h90;
      mem[PROG_BASE+16'h0278] = 8'h90;
      mem[PROG_BASE+16'h0279] = 8'h90;
      mem[PROG_BASE+16'h027A] = 8'h90;
      mem[PROG_BASE+16'h027B] = 8'h90;
      mem[PROG_BASE+16'h027C] = 8'h90;
      mem[PROG_BASE+16'h027D] = 8'h90;
      mem[PROG_BASE+16'h027E] = 8'h90;
      mem[PROG_BASE+16'h027F] = 8'h90;
      mem[PROG_BASE+16'h0280] = 8'h90;
      mem[PROG_BASE+16'h0281] = 8'h90;
      mem[PROG_BASE+16'h0282] = 8'h90;
      mem[PROG_BASE+16'h0283] = 8'h90;
      mem[PROG_BASE+16'h0284] = 8'h90;
      mem[PROG_BASE+16'h0285] = 8'h90;
      mem[PROG_BASE+16'h0286] = 8'h90;
      mem[PROG_BASE+16'h0287] = 8'h90;
      mem[PROG_BASE+16'h0288] = 8'h90;
      mem[PROG_BASE+16'h0289] = 8'h90;
      mem[PROG_BASE+16'h028A] = 8'h90;
      mem[PROG_BASE+16'h028B] = 8'h90;
      mem[PROG_BASE+16'h028C] = 8'h90;
      mem[PROG_BASE+16'h028D] = 8'h90;
      mem[PROG_BASE+16'h028E] = 8'h90;
      mem[PROG_BASE+16'h028F] = 8'h90;
      mem[PROG_BASE+16'h0290] = 8'h90;
      mem[PROG_BASE+16'h0291] = 8'h90;
      mem[PROG_BASE+16'h0292] = 8'h90;
      mem[PROG_BASE+16'h0293] = 8'h90;
      mem[PROG_BASE+16'h0294] = 8'h90;
      mem[PROG_BASE+16'h0295] = 8'h90;
      mem[PROG_BASE+16'h0296] = 8'h90;
      mem[PROG_BASE+16'h0297] = 8'h90;
      mem[PROG_BASE+16'h0298] = 8'h90;
      mem[PROG_BASE+16'h0299] = 8'h90;
      mem[PROG_BASE+16'h029A] = 8'h90;
      mem[PROG_BASE+16'h029B] = 8'h90;
      mem[PROG_BASE+16'h029C] = 8'h90;
      mem[PROG_BASE+16'h029D] = 8'h90;
      mem[PROG_BASE+16'h029E] = 8'h90;
      mem[PROG_BASE+16'h029F] = 8'h90;
      mem[PROG_BASE+16'h02A0] = 8'h90;
      mem[PROG_BASE+16'h02A1] = 8'h90;
      mem[PROG_BASE+16'h02A2] = 8'h90;
      mem[PROG_BASE+16'h02A3] = 8'h90;
      mem[PROG_BASE+16'h02A4] = 8'h90;
      mem[PROG_BASE+16'h02A5] = 8'h90;
      mem[PROG_BASE+16'h02A6] = 8'h90;
      mem[PROG_BASE+16'h02A7] = 8'h90;
      mem[PROG_BASE+16'h02A8] = 8'h90;
      mem[PROG_BASE+16'h02A9] = 8'h90;
      mem[PROG_BASE+16'h02AA] = 8'h90;
      mem[PROG_BASE+16'h02AB] = 8'h90;
      mem[PROG_BASE+16'h02AC] = 8'h90;
      mem[PROG_BASE+16'h02AD] = 8'h90;
      mem[PROG_BASE+16'h02AE] = 8'h90;
      mem[PROG_BASE+16'h02AF] = 8'h90;
      mem[PROG_BASE+16'h02B0] = 8'h90;
      mem[PROG_BASE+16'h02B1] = 8'h90;
      mem[PROG_BASE+16'h02B2] = 8'h90;
      mem[PROG_BASE+16'h02B3] = 8'h90;
      mem[PROG_BASE+16'h02B4] = 8'h90;
      mem[PROG_BASE+16'h02B5] = 8'h90;
      mem[PROG_BASE+16'h02B6] = 8'h90;
      mem[PROG_BASE+16'h02B7] = 8'h90;
      mem[PROG_BASE+16'h02B8] = 8'h90;
      mem[PROG_BASE+16'h02B9] = 8'h90;
      mem[PROG_BASE+16'h02BA] = 8'h90;
      mem[PROG_BASE+16'h02BB] = 8'h90;
      mem[PROG_BASE+16'h02BC] = 8'h90;
      mem[PROG_BASE+16'h02BD] = 8'h90;
      mem[PROG_BASE+16'h02BE] = 8'h90;
      mem[PROG_BASE+16'h02BF] = 8'h90;
      mem[PROG_BASE+16'h02C0] = 8'h90;
      mem[PROG_BASE+16'h02C1] = 8'h90;
      mem[PROG_BASE+16'h02C2] = 8'h90;
      mem[PROG_BASE+16'h02C3] = 8'h90;
      mem[PROG_BASE+16'h02C4] = 8'h90;
      mem[PROG_BASE+16'h02C5] = 8'h90;
      mem[PROG_BASE+16'h02C6] = 8'h90;
      mem[PROG_BASE+16'h02C7] = 8'h90;
      mem[PROG_BASE+16'h02C8] = 8'h90;
      mem[PROG_BASE+16'h02C9] = 8'h90;
      mem[PROG_BASE+16'h02CA] = 8'h90;
      mem[PROG_BASE+16'h02CB] = 8'h90;
      mem[PROG_BASE+16'h02CC] = 8'h90;
      mem[PROG_BASE+16'h02CD] = 8'h90;
      mem[PROG_BASE+16'h02CE] = 8'h90;
      mem[PROG_BASE+16'h02CF] = 8'h90;
      mem[PROG_BASE+16'h02D0] = 8'h90;
      mem[PROG_BASE+16'h02D1] = 8'h90;
      mem[PROG_BASE+16'h02D2] = 8'h90;
      mem[PROG_BASE+16'h02D3] = 8'h90;
      mem[PROG_BASE+16'h02D4] = 8'h90;
      mem[PROG_BASE+16'h02D5] = 8'h90;
      mem[PROG_BASE+16'h02D6] = 8'h90;
      mem[PROG_BASE+16'h02D7] = 8'h90;
      mem[PROG_BASE+16'h02D8] = 8'h90;
      mem[PROG_BASE+16'h02D9] = 8'h90;
      mem[PROG_BASE+16'h02DA] = 8'h90;
      mem[PROG_BASE+16'h02DB] = 8'h90;
      mem[PROG_BASE+16'h02DC] = 8'h90;
      mem[PROG_BASE+16'h02DD] = 8'h90;
      mem[PROG_BASE+16'h02DE] = 8'h90;
      mem[PROG_BASE+16'h02DF] = 8'h90;
      mem[PROG_BASE+16'h02E0] = 8'h90;
      mem[PROG_BASE+16'h02E1] = 8'h90;
      mem[PROG_BASE+16'h02E2] = 8'h90;
      mem[PROG_BASE+16'h02E3] = 8'h90;
      mem[PROG_BASE+16'h02E4] = 8'h90;
      mem[PROG_BASE+16'h02E5] = 8'h90;
      mem[PROG_BASE+16'h02E6] = 8'h90;
      mem[PROG_BASE+16'h02E7] = 8'h90;
      mem[PROG_BASE+16'h02E8] = 8'h90;
      mem[PROG_BASE+16'h02E9] = 8'h90;
      mem[PROG_BASE+16'h02EA] = 8'h90;
      mem[PROG_BASE+16'h02EB] = 8'h90;
      mem[PROG_BASE+16'h02EC] = 8'h90;
      mem[PROG_BASE+16'h02ED] = 8'h90;
      mem[PROG_BASE+16'h02EE] = 8'h90;
      mem[PROG_BASE+16'h02EF] = 8'h90;
      mem[PROG_BASE+16'h02F0] = 8'h90;
      mem[PROG_BASE+16'h02F1] = 8'h90;
      mem[PROG_BASE+16'h02F2] = 8'h90;
      mem[PROG_BASE+16'h02F3] = 8'h90;
      mem[PROG_BASE+16'h02F4] = 8'h90;
      mem[PROG_BASE+16'h02F5] = 8'h90;
      mem[PROG_BASE+16'h02F6] = 8'h90;
      mem[PROG_BASE+16'h02F7] = 8'h90;
      mem[PROG_BASE+16'h02F8] = 8'h90;
      mem[PROG_BASE+16'h02F9] = 8'h90;
      mem[PROG_BASE+16'h02FA] = 8'h90;
      mem[PROG_BASE+16'h02FB] = 8'h90;
      mem[PROG_BASE+16'h02FC] = 8'h90;
      mem[PROG_BASE+16'h02FD] = 8'h90;
      mem[PROG_BASE+16'h02FE] = 8'h90;
      mem[PROG_BASE+16'h02FF] = 8'h90;
      mem[PROG_BASE+16'h0300] = 8'h90;
      mem[PROG_BASE+16'h0301] = 8'h90;
      mem[PROG_BASE+16'h0302] = 8'h90;
      mem[PROG_BASE+16'h0303] = 8'h90;
      mem[PROG_BASE+16'h0304] = 8'h90;
      mem[PROG_BASE+16'h0305] = 8'h90;
      mem[PROG_BASE+16'h0306] = 8'h90;
      mem[PROG_BASE+16'h0307] = 8'h90;
      mem[PROG_BASE+16'h0308] = 8'h90;
      mem[PROG_BASE+16'h0309] = 8'h90;
      mem[PROG_BASE+16'h030A] = 8'h90;
      mem[PROG_BASE+16'h030B] = 8'h90;
      mem[PROG_BASE+16'h030C] = 8'h90;
      mem[PROG_BASE+16'h030D] = 8'h90;
      mem[PROG_BASE+16'h030E] = 8'h90;
      mem[PROG_BASE+16'h030F] = 8'h90;
      mem[PROG_BASE+16'h0310] = 8'h90;
      mem[PROG_BASE+16'h0311] = 8'h90;
      mem[PROG_BASE+16'h0312] = 8'h90;
      mem[PROG_BASE+16'h0313] = 8'h90;
      mem[PROG_BASE+16'h0314] = 8'h90;
      mem[PROG_BASE+16'h0315] = 8'h90;
      mem[PROG_BASE+16'h0316] = 8'h90;
      mem[PROG_BASE+16'h0317] = 8'h90;
      mem[PROG_BASE+16'h0318] = 8'h90;
      mem[PROG_BASE+16'h0319] = 8'h90;
      mem[PROG_BASE+16'h031A] = 8'h90;
      mem[PROG_BASE+16'h031B] = 8'h90;
      mem[PROG_BASE+16'h031C] = 8'h90;
      mem[PROG_BASE+16'h031D] = 8'h90;
      mem[PROG_BASE+16'h031E] = 8'h90;
      mem[PROG_BASE+16'h031F] = 8'h90;
      mem[PROG_BASE+16'h0320] = 8'h90;
      mem[PROG_BASE+16'h0321] = 8'h90;
      mem[PROG_BASE+16'h0322] = 8'h90;
      mem[PROG_BASE+16'h0323] = 8'h90;
      mem[PROG_BASE+16'h0324] = 8'h90;
      mem[PROG_BASE+16'h0325] = 8'h90;
      mem[PROG_BASE+16'h0326] = 8'h90;
      mem[PROG_BASE+16'h0327] = 8'h90;
      mem[PROG_BASE+16'h0328] = 8'h90;
      mem[PROG_BASE+16'h0329] = 8'h90;
      mem[PROG_BASE+16'h032A] = 8'h90;
      mem[PROG_BASE+16'h032B] = 8'h90;
      mem[PROG_BASE+16'h032C] = 8'h90;
      mem[PROG_BASE+16'h032D] = 8'h90;
      mem[PROG_BASE+16'h032E] = 8'h90;
      mem[PROG_BASE+16'h032F] = 8'h90;
      mem[PROG_BASE+16'h0330] = 8'h90;
      mem[PROG_BASE+16'h0331] = 8'h90;
      mem[PROG_BASE+16'h0332] = 8'h90;
      mem[PROG_BASE+16'h0333] = 8'h90;
      mem[PROG_BASE+16'h0334] = 8'h90;
      mem[PROG_BASE+16'h0335] = 8'h90;
      mem[PROG_BASE+16'h0336] = 8'h90;
      mem[PROG_BASE+16'h0337] = 8'h90;
      mem[PROG_BASE+16'h0338] = 8'h90;
      mem[PROG_BASE+16'h0339] = 8'h90;
      mem[PROG_BASE+16'h033A] = 8'h90;
      mem[PROG_BASE+16'h033B] = 8'h90;
      mem[PROG_BASE+16'h033C] = 8'h90;
      mem[PROG_BASE+16'h033D] = 8'h90;
      mem[PROG_BASE+16'h033E] = 8'h90;
      mem[PROG_BASE+16'h033F] = 8'h90;
      mem[PROG_BASE+16'h0340] = 8'h90;
      mem[PROG_BASE+16'h0341] = 8'h90;
      mem[PROG_BASE+16'h0342] = 8'h90;
      mem[PROG_BASE+16'h0343] = 8'h90;
      mem[PROG_BASE+16'h0344] = 8'h90;
      mem[PROG_BASE+16'h0345] = 8'h90;
      mem[PROG_BASE+16'h0346] = 8'h90;
      mem[PROG_BASE+16'h0347] = 8'h90;
      mem[PROG_BASE+16'h0348] = 8'h90;
      mem[PROG_BASE+16'h0349] = 8'h90;
      mem[PROG_BASE+16'h034A] = 8'h90;
      mem[PROG_BASE+16'h034B] = 8'h90;
      mem[PROG_BASE+16'h034C] = 8'h90;
      mem[PROG_BASE+16'h034D] = 8'h90;
      mem[PROG_BASE+16'h034E] = 8'h90;
      mem[PROG_BASE+16'h034F] = 8'h90;
      mem[PROG_BASE+16'h0350] = 8'h90;
      mem[PROG_BASE+16'h0351] = 8'h90;
      mem[PROG_BASE+16'h0352] = 8'h90;
      mem[PROG_BASE+16'h0353] = 8'h90;
      mem[PROG_BASE+16'h0354] = 8'h90;
      mem[PROG_BASE+16'h0355] = 8'h90;
      mem[PROG_BASE+16'h0356] = 8'h90;
      mem[PROG_BASE+16'h0357] = 8'h90;
      mem[PROG_BASE+16'h0358] = 8'h90;
      mem[PROG_BASE+16'h0359] = 8'h90;
      mem[PROG_BASE+16'h035A] = 8'h90;
      mem[PROG_BASE+16'h035B] = 8'h90;
      mem[PROG_BASE+16'h035C] = 8'h90;
      mem[PROG_BASE+16'h035D] = 8'h90;
      mem[PROG_BASE+16'h035E] = 8'h90;
      mem[PROG_BASE+16'h035F] = 8'h90;
      mem[PROG_BASE+16'h0360] = 8'h90;
      mem[PROG_BASE+16'h0361] = 8'h90;
      mem[PROG_BASE+16'h0362] = 8'h90;
      mem[PROG_BASE+16'h0363] = 8'h90;
      mem[PROG_BASE+16'h0364] = 8'h90;
      mem[PROG_BASE+16'h0365] = 8'h90;
      mem[PROG_BASE+16'h0366] = 8'h90;
      mem[PROG_BASE+16'h0367] = 8'h90;
      mem[PROG_BASE+16'h0368] = 8'h90;
      mem[PROG_BASE+16'h0369] = 8'h90;
      mem[PROG_BASE+16'h036A] = 8'h90;
      mem[PROG_BASE+16'h036B] = 8'h90;
      mem[PROG_BASE+16'h036C] = 8'h90;
      mem[PROG_BASE+16'h036D] = 8'h90;
      mem[PROG_BASE+16'h036E] = 8'h90;
      mem[PROG_BASE+16'h036F] = 8'h90;
      mem[PROG_BASE+16'h0370] = 8'h90;
      mem[PROG_BASE+16'h0371] = 8'h90;
      mem[PROG_BASE+16'h0372] = 8'h90;
      mem[PROG_BASE+16'h0373] = 8'h90;
      mem[PROG_BASE+16'h0374] = 8'h90;
      mem[PROG_BASE+16'h0375] = 8'h90;
      mem[PROG_BASE+16'h0376] = 8'h90;
      mem[PROG_BASE+16'h0377] = 8'h90;
      mem[PROG_BASE+16'h0378] = 8'h90;
      mem[PROG_BASE+16'h0379] = 8'h90;
      mem[PROG_BASE+16'h037A] = 8'h90;
      mem[PROG_BASE+16'h037B] = 8'h90;
      mem[PROG_BASE+16'h037C] = 8'h90;
      mem[PROG_BASE+16'h037D] = 8'h90;
      mem[PROG_BASE+16'h037E] = 8'h90;
      mem[PROG_BASE+16'h037F] = 8'h90;
      mem[PROG_BASE+16'h0380] = 8'h90;
      mem[PROG_BASE+16'h0381] = 8'h90;
      mem[PROG_BASE+16'h0382] = 8'h90;
      mem[PROG_BASE+16'h0383] = 8'h90;
      mem[PROG_BASE+16'h0384] = 8'h90;
      mem[PROG_BASE+16'h0385] = 8'h90;
      mem[PROG_BASE+16'h0386] = 8'h90;
      mem[PROG_BASE+16'h0387] = 8'h90;
      mem[PROG_BASE+16'h0388] = 8'h90;
      mem[PROG_BASE+16'h0389] = 8'h90;
      mem[PROG_BASE+16'h038A] = 8'h90;
      mem[PROG_BASE+16'h038B] = 8'h90;
      mem[PROG_BASE+16'h038C] = 8'h90;
      mem[PROG_BASE+16'h038D] = 8'h90;
      mem[PROG_BASE+16'h038E] = 8'h90;
      mem[PROG_BASE+16'h038F] = 8'h90;
      mem[PROG_BASE+16'h0390] = 8'h90;
      mem[PROG_BASE+16'h0391] = 8'h90;
      mem[PROG_BASE+16'h0392] = 8'h90;
      mem[PROG_BASE+16'h0393] = 8'h90;
      mem[PROG_BASE+16'h0394] = 8'h90;
      mem[PROG_BASE+16'h0395] = 8'h90;
      mem[PROG_BASE+16'h0396] = 8'h90;
      mem[PROG_BASE+16'h0397] = 8'h90;
      mem[PROG_BASE+16'h0398] = 8'h90;
      mem[PROG_BASE+16'h0399] = 8'h90;
      mem[PROG_BASE+16'h039A] = 8'h90;
      mem[PROG_BASE+16'h039B] = 8'h90;
      mem[PROG_BASE+16'h039C] = 8'h90;
      mem[PROG_BASE+16'h039D] = 8'h90;
      mem[PROG_BASE+16'h039E] = 8'h90;
      mem[PROG_BASE+16'h039F] = 8'h90;
      mem[PROG_BASE+16'h03A0] = 8'h90;
      mem[PROG_BASE+16'h03A1] = 8'h90;
      mem[PROG_BASE+16'h03A2] = 8'h90;
      mem[PROG_BASE+16'h03A3] = 8'h90;
      mem[PROG_BASE+16'h03A4] = 8'h90;
      mem[PROG_BASE+16'h03A5] = 8'h90;
      mem[PROG_BASE+16'h03A6] = 8'h90;
      mem[PROG_BASE+16'h03A7] = 8'h90;
      mem[PROG_BASE+16'h03A8] = 8'h90;
      mem[PROG_BASE+16'h03A9] = 8'h90;
      mem[PROG_BASE+16'h03AA] = 8'h90;
      mem[PROG_BASE+16'h03AB] = 8'h90;
      mem[PROG_BASE+16'h03AC] = 8'h90;
      mem[PROG_BASE+16'h03AD] = 8'h90;
      mem[PROG_BASE+16'h03AE] = 8'h90;
      mem[PROG_BASE+16'h03AF] = 8'h90;
      mem[PROG_BASE+16'h03B0] = 8'h90;
      mem[PROG_BASE+16'h03B1] = 8'h90;
      mem[PROG_BASE+16'h03B2] = 8'h90;
      mem[PROG_BASE+16'h03B3] = 8'h90;
      mem[PROG_BASE+16'h03B4] = 8'h90;
      mem[PROG_BASE+16'h03B5] = 8'h90;
      mem[PROG_BASE+16'h03B6] = 8'h90;
      mem[PROG_BASE+16'h03B7] = 8'h90;
      mem[PROG_BASE+16'h03B8] = 8'h90;
      mem[PROG_BASE+16'h03B9] = 8'h90;
      mem[PROG_BASE+16'h03BA] = 8'h90;
      mem[PROG_BASE+16'h03BB] = 8'h90;
      mem[PROG_BASE+16'h03BC] = 8'h90;
      mem[PROG_BASE+16'h03BD] = 8'h90;
      mem[PROG_BASE+16'h03BE] = 8'h90;
      mem[PROG_BASE+16'h03BF] = 8'h90;
      mem[PROG_BASE+16'h03C0] = 8'h90;
      mem[PROG_BASE+16'h03C1] = 8'h90;
      mem[PROG_BASE+16'h03C2] = 8'h90;
      mem[PROG_BASE+16'h03C3] = 8'h90;
      mem[PROG_BASE+16'h03C4] = 8'h90;
      mem[PROG_BASE+16'h03C5] = 8'h90;
      mem[PROG_BASE+16'h03C6] = 8'h90;
      mem[PROG_BASE+16'h03C7] = 8'h90;
      mem[PROG_BASE+16'h03C8] = 8'h90;
      mem[PROG_BASE+16'h03C9] = 8'h90;
      mem[PROG_BASE+16'h03CA] = 8'h90;
      mem[PROG_BASE+16'h03CB] = 8'h90;
      mem[PROG_BASE+16'h03CC] = 8'h90;
      mem[PROG_BASE+16'h03CD] = 8'h90;
      mem[PROG_BASE+16'h03CE] = 8'h90;
      mem[PROG_BASE+16'h03CF] = 8'h90;
      mem[PROG_BASE+16'h03D0] = 8'h90;
      mem[PROG_BASE+16'h03D1] = 8'h90;
      mem[PROG_BASE+16'h03D2] = 8'h90;
      mem[PROG_BASE+16'h03D3] = 8'h90;
      mem[PROG_BASE+16'h03D4] = 8'h90;
      mem[PROG_BASE+16'h03D5] = 8'h90;
      mem[PROG_BASE+16'h03D6] = 8'h90;
      mem[PROG_BASE+16'h03D7] = 8'h90;
      mem[PROG_BASE+16'h03D8] = 8'h90;
      mem[PROG_BASE+16'h03D9] = 8'h90;
      mem[PROG_BASE+16'h03DA] = 8'h90;
      mem[PROG_BASE+16'h03DB] = 8'h90;
      mem[PROG_BASE+16'h03DC] = 8'h90;
      mem[PROG_BASE+16'h03DD] = 8'h90;
      mem[PROG_BASE+16'h03DE] = 8'h90;
      mem[PROG_BASE+16'h03DF] = 8'h90;
      mem[PROG_BASE+16'h03E0] = 8'h90;
      mem[PROG_BASE+16'h03E1] = 8'h90;
      mem[PROG_BASE+16'h03E2] = 8'h90;
      mem[PROG_BASE+16'h03E3] = 8'h90;
      mem[PROG_BASE+16'h03E4] = 8'h90;
      mem[PROG_BASE+16'h03E5] = 8'h90;
      mem[PROG_BASE+16'h03E6] = 8'h90;
      mem[PROG_BASE+16'h03E7] = 8'h90;
      mem[PROG_BASE+16'h03E8] = 8'h90;
      mem[PROG_BASE+16'h03E9] = 8'h90;
      mem[PROG_BASE+16'h03EA] = 8'h90;
      mem[PROG_BASE+16'h03EB] = 8'h90;
      mem[PROG_BASE+16'h03EC] = 8'h90;
      mem[PROG_BASE+16'h03ED] = 8'h90;
      mem[PROG_BASE+16'h03EE] = 8'h90;
      mem[PROG_BASE+16'h03EF] = 8'h90;
      mem[PROG_BASE+16'h03F0] = 8'h90;
      mem[PROG_BASE+16'h03F1] = 8'h90;
      mem[PROG_BASE+16'h03F2] = 8'h90;
      mem[PROG_BASE+16'h03F3] = 8'h90;
      mem[PROG_BASE+16'h03F4] = 8'h90;
      mem[PROG_BASE+16'h03F5] = 8'h90;
      mem[PROG_BASE+16'h03F6] = 8'h90;
      mem[PROG_BASE+16'h03F7] = 8'h90;
      mem[PROG_BASE+16'h03F8] = 8'h90;
      mem[PROG_BASE+16'h03F9] = 8'h90;
      mem[PROG_BASE+16'h03FA] = 8'h90;
      mem[PROG_BASE+16'h03FB] = 8'h90;
      mem[PROG_BASE+16'h03FC] = 8'h90;
      mem[PROG_BASE+16'h03FD] = 8'h90;
      mem[PROG_BASE+16'h03FE] = 8'h90;
      mem[PROG_BASE+16'h03FF] = 8'h90;
      mem[PROG_BASE+16'h0400] = 8'h90;
      mem[PROG_BASE+16'h0401] = 8'h90;
      mem[PROG_BASE+16'h0402] = 8'h90;
      mem[PROG_BASE+16'h0403] = 8'h90;
      mem[PROG_BASE+16'h0404] = 8'h90;
      mem[PROG_BASE+16'h0405] = 8'h90;
      mem[PROG_BASE+16'h0406] = 8'h90;
      mem[PROG_BASE+16'h0407] = 8'h90;
      mem[PROG_BASE+16'h0408] = 8'h90;
      mem[PROG_BASE+16'h0409] = 8'h90;
      mem[PROG_BASE+16'h040A] = 8'h90;
      mem[PROG_BASE+16'h040B] = 8'h90;
      mem[PROG_BASE+16'h040C] = 8'h90;
      mem[PROG_BASE+16'h040D] = 8'h90;
      mem[PROG_BASE+16'h040E] = 8'h90;
      mem[PROG_BASE+16'h040F] = 8'h90;
      mem[PROG_BASE+16'h0410] = 8'h90;
      mem[PROG_BASE+16'h0411] = 8'h90;
      mem[PROG_BASE+16'h0412] = 8'h90;
      mem[PROG_BASE+16'h0413] = 8'h90;
      mem[PROG_BASE+16'h0414] = 8'h90;
      mem[PROG_BASE+16'h0415] = 8'h90;
      mem[PROG_BASE+16'h0416] = 8'h90;
      mem[PROG_BASE+16'h0417] = 8'h90;
      mem[PROG_BASE+16'h0418] = 8'h90;
      mem[PROG_BASE+16'h0419] = 8'h90;
      mem[PROG_BASE+16'h041A] = 8'h90;
      mem[PROG_BASE+16'h041B] = 8'h90;
      mem[PROG_BASE+16'h041C] = 8'h90;
      mem[PROG_BASE+16'h041D] = 8'h90;
      mem[PROG_BASE+16'h041E] = 8'h90;
      mem[PROG_BASE+16'h041F] = 8'h90;
      mem[PROG_BASE+16'h0420] = 8'h90;
      mem[PROG_BASE+16'h0421] = 8'h90;
      mem[PROG_BASE+16'h0422] = 8'h90;
      mem[PROG_BASE+16'h0423] = 8'h90;
      mem[PROG_BASE+16'h0424] = 8'h90;
      mem[PROG_BASE+16'h0425] = 8'h90;
      mem[PROG_BASE+16'h0426] = 8'h90;
      mem[PROG_BASE+16'h0427] = 8'h90;
      mem[PROG_BASE+16'h0428] = 8'h90;
      mem[PROG_BASE+16'h0429] = 8'h90;
      mem[PROG_BASE+16'h042A] = 8'h90;
      mem[PROG_BASE+16'h042B] = 8'h90;
      mem[PROG_BASE+16'h042C] = 8'h90;
      mem[PROG_BASE+16'h042D] = 8'h90;
      mem[PROG_BASE+16'h042E] = 8'h90;
      mem[PROG_BASE+16'h042F] = 8'h90;
      mem[PROG_BASE+16'h0430] = 8'h90;
      mem[PROG_BASE+16'h0431] = 8'h90;
      mem[PROG_BASE+16'h0432] = 8'h90;
      mem[PROG_BASE+16'h0433] = 8'h90;
      mem[PROG_BASE+16'h0434] = 8'h90;
      mem[PROG_BASE+16'h0435] = 8'h90;
      mem[PROG_BASE+16'h0436] = 8'h90;
      mem[PROG_BASE+16'h0437] = 8'h90;
      mem[PROG_BASE+16'h0438] = 8'h90;
      mem[PROG_BASE+16'h0439] = 8'h90;
      mem[PROG_BASE+16'h043A] = 8'h90;
      mem[PROG_BASE+16'h043B] = 8'h90;
      mem[PROG_BASE+16'h043C] = 8'h90;
      mem[PROG_BASE+16'h043D] = 8'h90;
      mem[PROG_BASE+16'h043E] = 8'h90;
      mem[PROG_BASE+16'h043F] = 8'h90;
      mem[PROG_BASE+16'h0440] = 8'h90;
      mem[PROG_BASE+16'h0441] = 8'h90;
      mem[PROG_BASE+16'h0442] = 8'h90;
      mem[PROG_BASE+16'h0443] = 8'h90;
      mem[PROG_BASE+16'h0444] = 8'h90;
      mem[PROG_BASE+16'h0445] = 8'h90;
      mem[PROG_BASE+16'h0446] = 8'h90;
      mem[PROG_BASE+16'h0447] = 8'h90;
      mem[PROG_BASE+16'h0448] = 8'h90;
      mem[PROG_BASE+16'h0449] = 8'h90;
      mem[PROG_BASE+16'h044A] = 8'h90;
      mem[PROG_BASE+16'h044B] = 8'h90;
      mem[PROG_BASE+16'h044C] = 8'h90;
      mem[PROG_BASE+16'h044D] = 8'h90;
      mem[PROG_BASE+16'h044E] = 8'h90;
      mem[PROG_BASE+16'h044F] = 8'h90;
      mem[PROG_BASE+16'h0450] = 8'h90;
      mem[PROG_BASE+16'h0451] = 8'h90;
      mem[PROG_BASE+16'h0452] = 8'h90;
      mem[PROG_BASE+16'h0453] = 8'h90;
      mem[PROG_BASE+16'h0454] = 8'h90;
      mem[PROG_BASE+16'h0455] = 8'h90;
      mem[PROG_BASE+16'h0456] = 8'h90;
      mem[PROG_BASE+16'h0457] = 8'h90;
      mem[PROG_BASE+16'h0458] = 8'h90;
      mem[PROG_BASE+16'h0459] = 8'h90;
      mem[PROG_BASE+16'h045A] = 8'h90;
      mem[PROG_BASE+16'h045B] = 8'h90;
      mem[PROG_BASE+16'h045C] = 8'h90;
      mem[PROG_BASE+16'h045D] = 8'h90;
      mem[PROG_BASE+16'h045E] = 8'h90;
      mem[PROG_BASE+16'h045F] = 8'h90;
      mem[PROG_BASE+16'h0460] = 8'h90;
      mem[PROG_BASE+16'h0461] = 8'h90;
      mem[PROG_BASE+16'h0462] = 8'h90;
      mem[PROG_BASE+16'h0463] = 8'h90;
      mem[PROG_BASE+16'h0464] = 8'h90;
      mem[PROG_BASE+16'h0465] = 8'h90;
      mem[PROG_BASE+16'h0466] = 8'h90;
      mem[PROG_BASE+16'h0467] = 8'h90;
      mem[PROG_BASE+16'h0468] = 8'h90;
      mem[PROG_BASE+16'h0469] = 8'h90;
      mem[PROG_BASE+16'h046A] = 8'h90;
      mem[PROG_BASE+16'h046B] = 8'h90;
      mem[PROG_BASE+16'h046C] = 8'h90;
      mem[PROG_BASE+16'h046D] = 8'h90;
      mem[PROG_BASE+16'h046E] = 8'h90;
      mem[PROG_BASE+16'h046F] = 8'h90;
      mem[PROG_BASE+16'h0470] = 8'h90;
      mem[PROG_BASE+16'h0471] = 8'h90;
      mem[PROG_BASE+16'h0472] = 8'h90;
      mem[PROG_BASE+16'h0473] = 8'h90;
      mem[PROG_BASE+16'h0474] = 8'h90;
      mem[PROG_BASE+16'h0475] = 8'h90;
      mem[PROG_BASE+16'h0476] = 8'h90;
      mem[PROG_BASE+16'h0477] = 8'h90;
      mem[PROG_BASE+16'h0478] = 8'h90;
      mem[PROG_BASE+16'h0479] = 8'h90;
      mem[PROG_BASE+16'h047A] = 8'h90;
      mem[PROG_BASE+16'h047B] = 8'h90;
      mem[PROG_BASE+16'h047C] = 8'h90;
      mem[PROG_BASE+16'h047D] = 8'h90;
      mem[PROG_BASE+16'h047E] = 8'h90;
      mem[PROG_BASE+16'h047F] = 8'h90;
      mem[PROG_BASE+16'h0480] = 8'h90;
      mem[PROG_BASE+16'h0481] = 8'h90;
      mem[PROG_BASE+16'h0482] = 8'h90;
      mem[PROG_BASE+16'h0483] = 8'h90;
      mem[PROG_BASE+16'h0484] = 8'h90;
      mem[PROG_BASE+16'h0485] = 8'h90;
      mem[PROG_BASE+16'h0486] = 8'h90;
      mem[PROG_BASE+16'h0487] = 8'h90;
      mem[PROG_BASE+16'h0488] = 8'h90;
      mem[PROG_BASE+16'h0489] = 8'h90;
      mem[PROG_BASE+16'h048A] = 8'h90;
      mem[PROG_BASE+16'h048B] = 8'h90;
      mem[PROG_BASE+16'h048C] = 8'h90;
      mem[PROG_BASE+16'h048D] = 8'h90;
      mem[PROG_BASE+16'h048E] = 8'h90;
      mem[PROG_BASE+16'h048F] = 8'h90;
      mem[PROG_BASE+16'h0490] = 8'h90;
      mem[PROG_BASE+16'h0491] = 8'h90;
      mem[PROG_BASE+16'h0492] = 8'h90;
      mem[PROG_BASE+16'h0493] = 8'h90;
      mem[PROG_BASE+16'h0494] = 8'h90;
      mem[PROG_BASE+16'h0495] = 8'h90;
      mem[PROG_BASE+16'h0496] = 8'h90;
      mem[PROG_BASE+16'h0497] = 8'h90;
      mem[PROG_BASE+16'h0498] = 8'h90;
      mem[PROG_BASE+16'h0499] = 8'h90;
      mem[PROG_BASE+16'h049A] = 8'h90;
      mem[PROG_BASE+16'h049B] = 8'h90;
      mem[PROG_BASE+16'h049C] = 8'h90;
      mem[PROG_BASE+16'h049D] = 8'h90;
      mem[PROG_BASE+16'h049E] = 8'h90;
      mem[PROG_BASE+16'h049F] = 8'h90;
      mem[PROG_BASE+16'h04A0] = 8'h90;
      mem[PROG_BASE+16'h04A1] = 8'h90;
      mem[PROG_BASE+16'h04A2] = 8'h90;
      mem[PROG_BASE+16'h04A3] = 8'h90;
      mem[PROG_BASE+16'h04A4] = 8'h90;
      mem[PROG_BASE+16'h04A5] = 8'h90;
      mem[PROG_BASE+16'h04A6] = 8'h90;
      mem[PROG_BASE+16'h04A7] = 8'h90;
      mem[PROG_BASE+16'h04A8] = 8'h90;
      mem[PROG_BASE+16'h04A9] = 8'h90;
      mem[PROG_BASE+16'h04AA] = 8'h90;
      mem[PROG_BASE+16'h04AB] = 8'h90;
      mem[PROG_BASE+16'h04AC] = 8'h90;
      mem[PROG_BASE+16'h04AD] = 8'h90;
      mem[PROG_BASE+16'h04AE] = 8'h90;
      mem[PROG_BASE+16'h04AF] = 8'h90;
      mem[PROG_BASE+16'h04B0] = 8'h90;
      mem[PROG_BASE+16'h04B1] = 8'h90;
      mem[PROG_BASE+16'h04B2] = 8'h90;
      mem[PROG_BASE+16'h04B3] = 8'h90;
      mem[PROG_BASE+16'h04B4] = 8'h90;
      mem[PROG_BASE+16'h04B5] = 8'h90;
      mem[PROG_BASE+16'h04B6] = 8'h90;
      mem[PROG_BASE+16'h04B7] = 8'h90;
      mem[PROG_BASE+16'h04B8] = 8'h90;
      mem[PROG_BASE+16'h04B9] = 8'h90;
      mem[PROG_BASE+16'h04BA] = 8'h90;
      mem[PROG_BASE+16'h04BB] = 8'h90;
      mem[PROG_BASE+16'h04BC] = 8'h90;
      mem[PROG_BASE+16'h04BD] = 8'h90;
      mem[PROG_BASE+16'h04BE] = 8'h90;
      mem[PROG_BASE+16'h04BF] = 8'h90;
      mem[PROG_BASE+16'h04C0] = 8'h90;
      mem[PROG_BASE+16'h04C1] = 8'h90;
      mem[PROG_BASE+16'h04C2] = 8'h90;
      mem[PROG_BASE+16'h04C3] = 8'h90;
      mem[PROG_BASE+16'h04C4] = 8'h90;
      mem[PROG_BASE+16'h04C5] = 8'h90;
      mem[PROG_BASE+16'h04C6] = 8'h90;
      mem[PROG_BASE+16'h04C7] = 8'h90;
      mem[PROG_BASE+16'h04C8] = 8'h90;
      mem[PROG_BASE+16'h04C9] = 8'h90;
      mem[PROG_BASE+16'h04CA] = 8'h90;
      mem[PROG_BASE+16'h04CB] = 8'h90;
      mem[PROG_BASE+16'h04CC] = 8'h90;
      mem[PROG_BASE+16'h04CD] = 8'h90;
      mem[PROG_BASE+16'h04CE] = 8'h90;
      mem[PROG_BASE+16'h04CF] = 8'h90;
      mem[PROG_BASE+16'h04D0] = 8'h90;
      mem[PROG_BASE+16'h04D1] = 8'h90;
      mem[PROG_BASE+16'h04D2] = 8'h90;
      mem[PROG_BASE+16'h04D3] = 8'h90;
      mem[PROG_BASE+16'h04D4] = 8'h90;
      mem[PROG_BASE+16'h04D5] = 8'h90;
      mem[PROG_BASE+16'h04D6] = 8'h90;
      mem[PROG_BASE+16'h04D7] = 8'h90;
      mem[PROG_BASE+16'h04D8] = 8'h90;
      mem[PROG_BASE+16'h04D9] = 8'h90;
      mem[PROG_BASE+16'h04DA] = 8'h90;
      mem[PROG_BASE+16'h04DB] = 8'h90;
      mem[PROG_BASE+16'h04DC] = 8'h90;
      mem[PROG_BASE+16'h04DD] = 8'h90;
      mem[PROG_BASE+16'h04DE] = 8'h90;
      mem[PROG_BASE+16'h04DF] = 8'h90;
      mem[PROG_BASE+16'h04E0] = 8'h90;
      mem[PROG_BASE+16'h04E1] = 8'h90;
      mem[PROG_BASE+16'h04E2] = 8'h90;
      mem[PROG_BASE+16'h04E3] = 8'h90;
      mem[PROG_BASE+16'h04E4] = 8'h90;
      mem[PROG_BASE+16'h04E5] = 8'h90;
      mem[PROG_BASE+16'h04E6] = 8'h90;
      mem[PROG_BASE+16'h04E7] = 8'h90;
      mem[PROG_BASE+16'h04E8] = 8'h90;
      mem[PROG_BASE+16'h04E9] = 8'h90;
      mem[PROG_BASE+16'h04EA] = 8'h90;
      mem[PROG_BASE+16'h04EB] = 8'h90;
      mem[PROG_BASE+16'h04EC] = 8'h90;
      mem[PROG_BASE+16'h04ED] = 8'h90;
      mem[PROG_BASE+16'h04EE] = 8'h90;
      mem[PROG_BASE+16'h04EF] = 8'h90;
      mem[PROG_BASE+16'h04F0] = 8'h90;
      mem[PROG_BASE+16'h04F1] = 8'h90;
      mem[PROG_BASE+16'h04F2] = 8'h90;
      mem[PROG_BASE+16'h04F3] = 8'h90;
      mem[PROG_BASE+16'h04F4] = 8'h90;
      mem[PROG_BASE+16'h04F5] = 8'h90;
      mem[PROG_BASE+16'h04F6] = 8'h90;
      mem[PROG_BASE+16'h04F7] = 8'h90;
      mem[PROG_BASE+16'h04F8] = 8'h90;
      mem[PROG_BASE+16'h04F9] = 8'h90;
      mem[PROG_BASE+16'h04FA] = 8'h90;
      mem[PROG_BASE+16'h04FB] = 8'h90;
      mem[PROG_BASE+16'h04FC] = 8'h90;
      mem[PROG_BASE+16'h04FD] = 8'h90;
      mem[PROG_BASE+16'h04FE] = 8'h90;
      mem[PROG_BASE+16'h04FF] = 8'h90;
      mem[PROG_BASE+16'h0500] = 8'h90;
      mem[PROG_BASE+16'h0501] = 8'h90;
      mem[PROG_BASE+16'h0502] = 8'h90;
      mem[PROG_BASE+16'h0503] = 8'h90;
      mem[PROG_BASE+16'h0504] = 8'h90;
      mem[PROG_BASE+16'h0505] = 8'h90;
      mem[PROG_BASE+16'h0506] = 8'h90;
      mem[PROG_BASE+16'h0507] = 8'h90;
      mem[PROG_BASE+16'h0508] = 8'h90;
      mem[PROG_BASE+16'h0509] = 8'h90;
      mem[PROG_BASE+16'h050A] = 8'h90;
      mem[PROG_BASE+16'h050B] = 8'h90;
      mem[PROG_BASE+16'h050C] = 8'h90;
      mem[PROG_BASE+16'h050D] = 8'h90;
      mem[PROG_BASE+16'h050E] = 8'h90;
      mem[PROG_BASE+16'h050F] = 8'h90;
      mem[PROG_BASE+16'h0510] = 8'h90;
      mem[PROG_BASE+16'h0511] = 8'h90;
      mem[PROG_BASE+16'h0512] = 8'h90;
      mem[PROG_BASE+16'h0513] = 8'h90;
      mem[PROG_BASE+16'h0514] = 8'h90;
      mem[PROG_BASE+16'h0515] = 8'h90;
      mem[PROG_BASE+16'h0516] = 8'h90;
      mem[PROG_BASE+16'h0517] = 8'h90;
      mem[PROG_BASE+16'h0518] = 8'h90;
      mem[PROG_BASE+16'h0519] = 8'h90;
      mem[PROG_BASE+16'h051A] = 8'h90;
      mem[PROG_BASE+16'h051B] = 8'h90;
      mem[PROG_BASE+16'h051C] = 8'h90;
      mem[PROG_BASE+16'h051D] = 8'h90;
      mem[PROG_BASE+16'h051E] = 8'h90;
      mem[PROG_BASE+16'h051F] = 8'h90;
      mem[PROG_BASE+16'h0520] = 8'h90;
      mem[PROG_BASE+16'h0521] = 8'h90;
      mem[PROG_BASE+16'h0522] = 8'h90;
      mem[PROG_BASE+16'h0523] = 8'h90;
      mem[PROG_BASE+16'h0524] = 8'h90;
      mem[PROG_BASE+16'h0525] = 8'h90;
      mem[PROG_BASE+16'h0526] = 8'h90;
      mem[PROG_BASE+16'h0527] = 8'h90;
      mem[PROG_BASE+16'h0528] = 8'h90;
      mem[PROG_BASE+16'h0529] = 8'h90;
      mem[PROG_BASE+16'h052A] = 8'h90;
      mem[PROG_BASE+16'h052B] = 8'h90;
      mem[PROG_BASE+16'h052C] = 8'h90;
      mem[PROG_BASE+16'h052D] = 8'h90;
      mem[PROG_BASE+16'h052E] = 8'h90;
      mem[PROG_BASE+16'h052F] = 8'h90;
      mem[PROG_BASE+16'h0530] = 8'h90;
      mem[PROG_BASE+16'h0531] = 8'h90;
      mem[PROG_BASE+16'h0532] = 8'h90;
      mem[PROG_BASE+16'h0533] = 8'h90;
      mem[PROG_BASE+16'h0534] = 8'h90;
      mem[PROG_BASE+16'h0535] = 8'h90;
      mem[PROG_BASE+16'h0536] = 8'h90;
      mem[PROG_BASE+16'h0537] = 8'h90;
      mem[PROG_BASE+16'h0538] = 8'h90;
      mem[PROG_BASE+16'h0539] = 8'h90;
      mem[PROG_BASE+16'h053A] = 8'h90;
      mem[PROG_BASE+16'h053B] = 8'h90;
      mem[PROG_BASE+16'h053C] = 8'h90;
      mem[PROG_BASE+16'h053D] = 8'h90;
      mem[PROG_BASE+16'h053E] = 8'h90;
      mem[PROG_BASE+16'h053F] = 8'h90;
      mem[PROG_BASE+16'h0540] = 8'h90;
      mem[PROG_BASE+16'h0541] = 8'h90;
      mem[PROG_BASE+16'h0542] = 8'h90;
      mem[PROG_BASE+16'h0543] = 8'h90;
      mem[PROG_BASE+16'h0544] = 8'h90;
      mem[PROG_BASE+16'h0545] = 8'h90;
      mem[PROG_BASE+16'h0546] = 8'h90;
      mem[PROG_BASE+16'h0547] = 8'h90;
      mem[PROG_BASE+16'h0548] = 8'h90;
      mem[PROG_BASE+16'h0549] = 8'h90;
      mem[PROG_BASE+16'h054A] = 8'h90;
      mem[PROG_BASE+16'h054B] = 8'h90;
      mem[PROG_BASE+16'h054C] = 8'h90;
      mem[PROG_BASE+16'h054D] = 8'h90;
      mem[PROG_BASE+16'h054E] = 8'h90;
      mem[PROG_BASE+16'h054F] = 8'h90;
      mem[PROG_BASE+16'h0550] = 8'h90;
      mem[PROG_BASE+16'h0551] = 8'h90;
      mem[PROG_BASE+16'h0552] = 8'h90;
      mem[PROG_BASE+16'h0553] = 8'h90;
      mem[PROG_BASE+16'h0554] = 8'h90;
      mem[PROG_BASE+16'h0555] = 8'h90;
      mem[PROG_BASE+16'h0556] = 8'h90;
      mem[PROG_BASE+16'h0557] = 8'h90;
      mem[PROG_BASE+16'h0558] = 8'h90;
      mem[PROG_BASE+16'h0559] = 8'h90;
      mem[PROG_BASE+16'h055A] = 8'h90;
      mem[PROG_BASE+16'h055B] = 8'h90;
      mem[PROG_BASE+16'h055C] = 8'h90;
      mem[PROG_BASE+16'h055D] = 8'h90;
      mem[PROG_BASE+16'h055E] = 8'h90;
      mem[PROG_BASE+16'h055F] = 8'h90;
      mem[PROG_BASE+16'h0560] = 8'h90;
      mem[PROG_BASE+16'h0561] = 8'h90;
      mem[PROG_BASE+16'h0562] = 8'h90;
      mem[PROG_BASE+16'h0563] = 8'h90;
      mem[PROG_BASE+16'h0564] = 8'h90;
      mem[PROG_BASE+16'h0565] = 8'h90;
      mem[PROG_BASE+16'h0566] = 8'h90;
      mem[PROG_BASE+16'h0567] = 8'h90;
      mem[PROG_BASE+16'h0568] = 8'h90;
      mem[PROG_BASE+16'h0569] = 8'h90;
      mem[PROG_BASE+16'h056A] = 8'h90;
      mem[PROG_BASE+16'h056B] = 8'h90;
      mem[PROG_BASE+16'h056C] = 8'h90;
      mem[PROG_BASE+16'h056D] = 8'h90;
      mem[PROG_BASE+16'h056E] = 8'h90;
      mem[PROG_BASE+16'h056F] = 8'h90;
      mem[PROG_BASE+16'h0570] = 8'h90;
      mem[PROG_BASE+16'h0571] = 8'h90;
      mem[PROG_BASE+16'h0572] = 8'h90;
      mem[PROG_BASE+16'h0573] = 8'h90;
      mem[PROG_BASE+16'h0574] = 8'h90;
      mem[PROG_BASE+16'h0575] = 8'h90;
      mem[PROG_BASE+16'h0576] = 8'h90;
      mem[PROG_BASE+16'h0577] = 8'h90;
      mem[PROG_BASE+16'h0578] = 8'h90;
      mem[PROG_BASE+16'h0579] = 8'h90;
      mem[PROG_BASE+16'h057A] = 8'h90;
      mem[PROG_BASE+16'h057B] = 8'h90;
      mem[PROG_BASE+16'h057C] = 8'h90;
      mem[PROG_BASE+16'h057D] = 8'h90;
      mem[PROG_BASE+16'h057E] = 8'h90;
      mem[PROG_BASE+16'h057F] = 8'h90;
      mem[PROG_BASE+16'h0580] = 8'h90;
      mem[PROG_BASE+16'h0581] = 8'h90;
      mem[PROG_BASE+16'h0582] = 8'h90;
      mem[PROG_BASE+16'h0583] = 8'h90;
      mem[PROG_BASE+16'h0584] = 8'h90;
      mem[PROG_BASE+16'h0585] = 8'h90;
      mem[PROG_BASE+16'h0586] = 8'h90;
      mem[PROG_BASE+16'h0587] = 8'h90;
      mem[PROG_BASE+16'h0588] = 8'h90;
      mem[PROG_BASE+16'h0589] = 8'h90;
      mem[PROG_BASE+16'h058A] = 8'h90;
      mem[PROG_BASE+16'h058B] = 8'h90;
      mem[PROG_BASE+16'h058C] = 8'h90;
      mem[PROG_BASE+16'h058D] = 8'h90;
      mem[PROG_BASE+16'h058E] = 8'h90;
      mem[PROG_BASE+16'h058F] = 8'h90;
      mem[PROG_BASE+16'h0590] = 8'h90;
      mem[PROG_BASE+16'h0591] = 8'h90;
      mem[PROG_BASE+16'h0592] = 8'h90;
      mem[PROG_BASE+16'h0593] = 8'h90;
      mem[PROG_BASE+16'h0594] = 8'h90;
      mem[PROG_BASE+16'h0595] = 8'h90;
      mem[PROG_BASE+16'h0596] = 8'h90;
      mem[PROG_BASE+16'h0597] = 8'h90;
      mem[PROG_BASE+16'h0598] = 8'h90;
      mem[PROG_BASE+16'h0599] = 8'h90;
      mem[PROG_BASE+16'h059A] = 8'h90;
      mem[PROG_BASE+16'h059B] = 8'h90;
      mem[PROG_BASE+16'h059C] = 8'h90;
      mem[PROG_BASE+16'h059D] = 8'h90;
      mem[PROG_BASE+16'h059E] = 8'h90;
      mem[PROG_BASE+16'h059F] = 8'h90;
      mem[PROG_BASE+16'h05A0] = 8'h90;
      mem[PROG_BASE+16'h05A1] = 8'h90;
      mem[PROG_BASE+16'h05A2] = 8'h90;
      mem[PROG_BASE+16'h05A3] = 8'h90;
      mem[PROG_BASE+16'h05A4] = 8'h90;
      mem[PROG_BASE+16'h05A5] = 8'h90;
      mem[PROG_BASE+16'h05A6] = 8'h90;
      mem[PROG_BASE+16'h05A7] = 8'h90;
      mem[PROG_BASE+16'h05A8] = 8'h90;
      mem[PROG_BASE+16'h05A9] = 8'h90;
      mem[PROG_BASE+16'h05AA] = 8'h90;
      mem[PROG_BASE+16'h05AB] = 8'h90;
      mem[PROG_BASE+16'h05AC] = 8'h90;
      mem[PROG_BASE+16'h05AD] = 8'h90;
      mem[PROG_BASE+16'h05AE] = 8'h90;
      mem[PROG_BASE+16'h05AF] = 8'h90;
      mem[PROG_BASE+16'h05B0] = 8'h90;
      mem[PROG_BASE+16'h05B1] = 8'h90;
      mem[PROG_BASE+16'h05B2] = 8'h90;
      mem[PROG_BASE+16'h05B3] = 8'h90;
      mem[PROG_BASE+16'h05B4] = 8'h90;
      mem[PROG_BASE+16'h05B5] = 8'h90;
      mem[PROG_BASE+16'h05B6] = 8'h90;
      mem[PROG_BASE+16'h05B7] = 8'h90;
      mem[PROG_BASE+16'h05B8] = 8'h90;
      mem[PROG_BASE+16'h05B9] = 8'h90;
      mem[PROG_BASE+16'h05BA] = 8'h90;
      mem[PROG_BASE+16'h05BB] = 8'h90;
      mem[PROG_BASE+16'h05BC] = 8'h90;
      mem[PROG_BASE+16'h05BD] = 8'h90;
      mem[PROG_BASE+16'h05BE] = 8'h90;
      mem[PROG_BASE+16'h05BF] = 8'h90;
      mem[PROG_BASE+16'h05C0] = 8'h90;
      mem[PROG_BASE+16'h05C1] = 8'h90;
      mem[PROG_BASE+16'h05C2] = 8'h90;
      mem[PROG_BASE+16'h05C3] = 8'h90;
      mem[PROG_BASE+16'h05C4] = 8'h90;
      mem[PROG_BASE+16'h05C5] = 8'h90;
      mem[PROG_BASE+16'h05C6] = 8'h90;
      mem[PROG_BASE+16'h05C7] = 8'h90;
      mem[PROG_BASE+16'h05C8] = 8'h90;
      mem[PROG_BASE+16'h05C9] = 8'h90;
      mem[PROG_BASE+16'h05CA] = 8'h90;
      mem[PROG_BASE+16'h05CB] = 8'h90;
      mem[PROG_BASE+16'h05CC] = 8'h90;
      mem[PROG_BASE+16'h05CD] = 8'h90;
      mem[PROG_BASE+16'h05CE] = 8'h90;
      mem[PROG_BASE+16'h05CF] = 8'h90;
      mem[PROG_BASE+16'h05D0] = 8'h90;
      mem[PROG_BASE+16'h05D1] = 8'h90;
      mem[PROG_BASE+16'h05D2] = 8'h90;
      mem[PROG_BASE+16'h05D3] = 8'h90;
      mem[PROG_BASE+16'h05D4] = 8'h90;
      mem[PROG_BASE+16'h05D5] = 8'h90;
      mem[PROG_BASE+16'h05D6] = 8'h90;
      mem[PROG_BASE+16'h05D7] = 8'h90;
      mem[PROG_BASE+16'h05D8] = 8'h90;
      mem[PROG_BASE+16'h05D9] = 8'h90;
      mem[PROG_BASE+16'h05DA] = 8'h90;
      mem[PROG_BASE+16'h05DB] = 8'h90;
      mem[PROG_BASE+16'h05DC] = 8'h90;
      mem[PROG_BASE+16'h05DD] = 8'h90;
      mem[PROG_BASE+16'h05DE] = 8'h90;
      mem[PROG_BASE+16'h05DF] = 8'h90;
      mem[PROG_BASE+16'h05E0] = 8'h90;
      mem[PROG_BASE+16'h05E1] = 8'h90;
      mem[PROG_BASE+16'h05E2] = 8'h90;
      mem[PROG_BASE+16'h05E3] = 8'h90;
      mem[PROG_BASE+16'h05E4] = 8'h90;
      mem[PROG_BASE+16'h05E5] = 8'h90;
      mem[PROG_BASE+16'h05E6] = 8'h90;
      mem[PROG_BASE+16'h05E7] = 8'h90;
      mem[PROG_BASE+16'h05E8] = 8'h90;
      mem[PROG_BASE+16'h05E9] = 8'h90;
      mem[PROG_BASE+16'h05EA] = 8'h90;
      mem[PROG_BASE+16'h05EB] = 8'h90;
      mem[PROG_BASE+16'h05EC] = 8'h90;
      mem[PROG_BASE+16'h05ED] = 8'h90;
      mem[PROG_BASE+16'h05EE] = 8'h90;
      mem[PROG_BASE+16'h05EF] = 8'h90;
      mem[PROG_BASE+16'h05F0] = 8'h90;
      mem[PROG_BASE+16'h05F1] = 8'h90;
      mem[PROG_BASE+16'h05F2] = 8'h90;
      mem[PROG_BASE+16'h05F3] = 8'h90;
      mem[PROG_BASE+16'h05F4] = 8'h90;
      mem[PROG_BASE+16'h05F5] = 8'h90;
      mem[PROG_BASE+16'h05F6] = 8'h90;
      mem[PROG_BASE+16'h05F7] = 8'h90;
      mem[PROG_BASE+16'h05F8] = 8'h90;
      mem[PROG_BASE+16'h05F9] = 8'h90;
      mem[PROG_BASE+16'h05FA] = 8'h90;
      mem[PROG_BASE+16'h05FB] = 8'h90;
      mem[PROG_BASE+16'h05FC] = 8'h90;
      mem[PROG_BASE+16'h05FD] = 8'h90;
      mem[PROG_BASE+16'h05FE] = 8'h90;
      mem[PROG_BASE+16'h05FF] = 8'h90;
      mem[PROG_BASE+16'h0600] = 8'h90;
      mem[PROG_BASE+16'h0601] = 8'h90;
      mem[PROG_BASE+16'h0602] = 8'h90;
      mem[PROG_BASE+16'h0603] = 8'h90;
      mem[PROG_BASE+16'h0604] = 8'h90;
      mem[PROG_BASE+16'h0605] = 8'h90;
      mem[PROG_BASE+16'h0606] = 8'h90;
      mem[PROG_BASE+16'h0607] = 8'h90;
      mem[PROG_BASE+16'h0608] = 8'h90;
      mem[PROG_BASE+16'h0609] = 8'h90;
      mem[PROG_BASE+16'h060A] = 8'h90;
      mem[PROG_BASE+16'h060B] = 8'h90;
      mem[PROG_BASE+16'h060C] = 8'h90;
      mem[PROG_BASE+16'h060D] = 8'h90;
      mem[PROG_BASE+16'h060E] = 8'h90;
      mem[PROG_BASE+16'h060F] = 8'h90;
      mem[PROG_BASE+16'h0610] = 8'h90;
      mem[PROG_BASE+16'h0611] = 8'h90;
      mem[PROG_BASE+16'h0612] = 8'h90;
      mem[PROG_BASE+16'h0613] = 8'h90;
      mem[PROG_BASE+16'h0614] = 8'h90;
      mem[PROG_BASE+16'h0615] = 8'h90;
      mem[PROG_BASE+16'h0616] = 8'h90;
      mem[PROG_BASE+16'h0617] = 8'h90;
      mem[PROG_BASE+16'h0618] = 8'h90;
      mem[PROG_BASE+16'h0619] = 8'h90;
      mem[PROG_BASE+16'h061A] = 8'h90;
      mem[PROG_BASE+16'h061B] = 8'h90;
      mem[PROG_BASE+16'h061C] = 8'h90;
      mem[PROG_BASE+16'h061D] = 8'h90;
      mem[PROG_BASE+16'h061E] = 8'h90;
      mem[PROG_BASE+16'h061F] = 8'h90;
      mem[PROG_BASE+16'h0620] = 8'h90;
      mem[PROG_BASE+16'h0621] = 8'h90;
      mem[PROG_BASE+16'h0622] = 8'h90;
      mem[PROG_BASE+16'h0623] = 8'h90;
      mem[PROG_BASE+16'h0624] = 8'h90;
      mem[PROG_BASE+16'h0625] = 8'h90;
      mem[PROG_BASE+16'h0626] = 8'h90;
      mem[PROG_BASE+16'h0627] = 8'h90;
      mem[PROG_BASE+16'h0628] = 8'h90;
      mem[PROG_BASE+16'h0629] = 8'h90;
      mem[PROG_BASE+16'h062A] = 8'h90;
      mem[PROG_BASE+16'h062B] = 8'h90;
      mem[PROG_BASE+16'h062C] = 8'h90;
      mem[PROG_BASE+16'h062D] = 8'h90;
      mem[PROG_BASE+16'h062E] = 8'h90;
      mem[PROG_BASE+16'h062F] = 8'h90;
      mem[PROG_BASE+16'h0630] = 8'h90;
      mem[PROG_BASE+16'h0631] = 8'h90;
      mem[PROG_BASE+16'h0632] = 8'h90;
      mem[PROG_BASE+16'h0633] = 8'h90;
      mem[PROG_BASE+16'h0634] = 8'h90;
      mem[PROG_BASE+16'h0635] = 8'h90;
      mem[PROG_BASE+16'h0636] = 8'h90;
      mem[PROG_BASE+16'h0637] = 8'h90;
      mem[PROG_BASE+16'h0638] = 8'h90;
      mem[PROG_BASE+16'h0639] = 8'h90;
      mem[PROG_BASE+16'h063A] = 8'h90;
      mem[PROG_BASE+16'h063B] = 8'h90;
      mem[PROG_BASE+16'h063C] = 8'h90;
      mem[PROG_BASE+16'h063D] = 8'h90;
      mem[PROG_BASE+16'h063E] = 8'h90;
      mem[PROG_BASE+16'h063F] = 8'h90;
      mem[PROG_BASE+16'h0640] = 8'h90;
      mem[PROG_BASE+16'h0641] = 8'h90;
      mem[PROG_BASE+16'h0642] = 8'h90;
      mem[PROG_BASE+16'h0643] = 8'h90;
      mem[PROG_BASE+16'h0644] = 8'h90;
      mem[PROG_BASE+16'h0645] = 8'h90;
      mem[PROG_BASE+16'h0646] = 8'h90;
      mem[PROG_BASE+16'h0647] = 8'h90;
      mem[PROG_BASE+16'h0648] = 8'h90;
      mem[PROG_BASE+16'h0649] = 8'h90;
      mem[PROG_BASE+16'h064A] = 8'h90;
      mem[PROG_BASE+16'h064B] = 8'h90;
      mem[PROG_BASE+16'h064C] = 8'h90;
      mem[PROG_BASE+16'h064D] = 8'h90;
      mem[PROG_BASE+16'h064E] = 8'h90;
      mem[PROG_BASE+16'h064F] = 8'h90;
      mem[PROG_BASE+16'h0650] = 8'h90;
      mem[PROG_BASE+16'h0651] = 8'h90;
      mem[PROG_BASE+16'h0652] = 8'h90;
      mem[PROG_BASE+16'h0653] = 8'h90;
      mem[PROG_BASE+16'h0654] = 8'h90;
      mem[PROG_BASE+16'h0655] = 8'h90;
      mem[PROG_BASE+16'h0656] = 8'h90;
      mem[PROG_BASE+16'h0657] = 8'h90;
      mem[PROG_BASE+16'h0658] = 8'h90;
      mem[PROG_BASE+16'h0659] = 8'h90;
      mem[PROG_BASE+16'h065A] = 8'h90;
      mem[PROG_BASE+16'h065B] = 8'h90;
      mem[PROG_BASE+16'h065C] = 8'h90;
      mem[PROG_BASE+16'h065D] = 8'h90;
      mem[PROG_BASE+16'h065E] = 8'h90;
      mem[PROG_BASE+16'h065F] = 8'h90;
      mem[PROG_BASE+16'h0660] = 8'h90;
      mem[PROG_BASE+16'h0661] = 8'h90;
      mem[PROG_BASE+16'h0662] = 8'h90;
      mem[PROG_BASE+16'h0663] = 8'h90;
      mem[PROG_BASE+16'h0664] = 8'h90;
      mem[PROG_BASE+16'h0665] = 8'h90;
      mem[PROG_BASE+16'h0666] = 8'h90;
      mem[PROG_BASE+16'h0667] = 8'h90;
      mem[PROG_BASE+16'h0668] = 8'h90;
      mem[PROG_BASE+16'h0669] = 8'h90;
      mem[PROG_BASE+16'h066A] = 8'h90;
      mem[PROG_BASE+16'h066B] = 8'h90;
      mem[PROG_BASE+16'h066C] = 8'h90;
      mem[PROG_BASE+16'h066D] = 8'h90;
      mem[PROG_BASE+16'h066E] = 8'h90;
      mem[PROG_BASE+16'h066F] = 8'h90;
      mem[PROG_BASE+16'h0670] = 8'h90;
      mem[PROG_BASE+16'h0671] = 8'h90;
      mem[PROG_BASE+16'h0672] = 8'h90;
      mem[PROG_BASE+16'h0673] = 8'h90;
      mem[PROG_BASE+16'h0674] = 8'h90;
      mem[PROG_BASE+16'h0675] = 8'h90;
      mem[PROG_BASE+16'h0676] = 8'h90;
      mem[PROG_BASE+16'h0677] = 8'h90;
      mem[PROG_BASE+16'h0678] = 8'h90;
      mem[PROG_BASE+16'h0679] = 8'h90;
      mem[PROG_BASE+16'h067A] = 8'h90;
      mem[PROG_BASE+16'h067B] = 8'h90;
      mem[PROG_BASE+16'h067C] = 8'h90;
      mem[PROG_BASE+16'h067D] = 8'h90;
      mem[PROG_BASE+16'h067E] = 8'h90;
      mem[PROG_BASE+16'h067F] = 8'h90;
      mem[PROG_BASE+16'h0680] = 8'h90;
      mem[PROG_BASE+16'h0681] = 8'h90;
      mem[PROG_BASE+16'h0682] = 8'h90;
      mem[PROG_BASE+16'h0683] = 8'h90;
      mem[PROG_BASE+16'h0684] = 8'h90;
      mem[PROG_BASE+16'h0685] = 8'h90;
      mem[PROG_BASE+16'h0686] = 8'h90;
      mem[PROG_BASE+16'h0687] = 8'h90;
      mem[PROG_BASE+16'h0688] = 8'h90;
      mem[PROG_BASE+16'h0689] = 8'h90;
      mem[PROG_BASE+16'h068A] = 8'h90;
      mem[PROG_BASE+16'h068B] = 8'h90;
      mem[PROG_BASE+16'h068C] = 8'h90;
      mem[PROG_BASE+16'h068D] = 8'h90;
      mem[PROG_BASE+16'h068E] = 8'h90;
      mem[PROG_BASE+16'h068F] = 8'h90;
      mem[PROG_BASE+16'h0690] = 8'h90;
      mem[PROG_BASE+16'h0691] = 8'h90;
      mem[PROG_BASE+16'h0692] = 8'h90;
      mem[PROG_BASE+16'h0693] = 8'h90;
      mem[PROG_BASE+16'h0694] = 8'h90;
      mem[PROG_BASE+16'h0695] = 8'h90;
      mem[PROG_BASE+16'h0696] = 8'h90;
      mem[PROG_BASE+16'h0697] = 8'h90;
      mem[PROG_BASE+16'h0698] = 8'h90;
      mem[PROG_BASE+16'h0699] = 8'h90;
      mem[PROG_BASE+16'h069A] = 8'h90;
      mem[PROG_BASE+16'h069B] = 8'h90;
      mem[PROG_BASE+16'h069C] = 8'h90;
      mem[PROG_BASE+16'h069D] = 8'h90;
      mem[PROG_BASE+16'h069E] = 8'h90;
      mem[PROG_BASE+16'h069F] = 8'h90;
      mem[PROG_BASE+16'h06A0] = 8'h90;
      mem[PROG_BASE+16'h06A1] = 8'h90;
      mem[PROG_BASE+16'h06A2] = 8'h90;
      mem[PROG_BASE+16'h06A3] = 8'h90;
      mem[PROG_BASE+16'h06A4] = 8'h90;
      mem[PROG_BASE+16'h06A5] = 8'h90;
      mem[PROG_BASE+16'h06A6] = 8'h90;
      mem[PROG_BASE+16'h06A7] = 8'h90;
      mem[PROG_BASE+16'h06A8] = 8'h90;
      mem[PROG_BASE+16'h06A9] = 8'h90;
      mem[PROG_BASE+16'h06AA] = 8'h90;
      mem[PROG_BASE+16'h06AB] = 8'h90;
      mem[PROG_BASE+16'h06AC] = 8'h90;
      mem[PROG_BASE+16'h06AD] = 8'h90;
      mem[PROG_BASE+16'h06AE] = 8'h90;
      mem[PROG_BASE+16'h06AF] = 8'h90;
      mem[PROG_BASE+16'h06B0] = 8'h90;
      mem[PROG_BASE+16'h06B1] = 8'h90;
      mem[PROG_BASE+16'h06B2] = 8'h90;
      mem[PROG_BASE+16'h06B3] = 8'h90;
      mem[PROG_BASE+16'h06B4] = 8'h90;
      mem[PROG_BASE+16'h06B5] = 8'h90;
      mem[PROG_BASE+16'h06B6] = 8'h90;
      mem[PROG_BASE+16'h06B7] = 8'h90;
      mem[PROG_BASE+16'h06B8] = 8'h90;
      mem[PROG_BASE+16'h06B9] = 8'h90;
      mem[PROG_BASE+16'h06BA] = 8'h90;
      mem[PROG_BASE+16'h06BB] = 8'h90;
      mem[PROG_BASE+16'h06BC] = 8'h90;
      mem[PROG_BASE+16'h06BD] = 8'h90;
      mem[PROG_BASE+16'h06BE] = 8'h90;
      mem[PROG_BASE+16'h06BF] = 8'h90;
      mem[PROG_BASE+16'h06C0] = 8'h90;
      mem[PROG_BASE+16'h06C1] = 8'h90;
      mem[PROG_BASE+16'h06C2] = 8'h90;
      mem[PROG_BASE+16'h06C3] = 8'h90;
      mem[PROG_BASE+16'h06C4] = 8'h90;
      mem[PROG_BASE+16'h06C5] = 8'h90;
      mem[PROG_BASE+16'h06C6] = 8'h90;
      mem[PROG_BASE+16'h06C7] = 8'h90;
      mem[PROG_BASE+16'h06C8] = 8'h90;
      mem[PROG_BASE+16'h06C9] = 8'h90;
      mem[PROG_BASE+16'h06CA] = 8'h90;
      mem[PROG_BASE+16'h06CB] = 8'h90;
      mem[PROG_BASE+16'h06CC] = 8'h90;
      mem[PROG_BASE+16'h06CD] = 8'h90;
      mem[PROG_BASE+16'h06CE] = 8'h90;
      mem[PROG_BASE+16'h06CF] = 8'h90;
      mem[PROG_BASE+16'h06D0] = 8'h90;
      mem[PROG_BASE+16'h06D1] = 8'h90;
      mem[PROG_BASE+16'h06D2] = 8'h90;
      mem[PROG_BASE+16'h06D3] = 8'h90;
      mem[PROG_BASE+16'h06D4] = 8'h90;
      mem[PROG_BASE+16'h06D5] = 8'h90;
      mem[PROG_BASE+16'h06D6] = 8'h90;
      mem[PROG_BASE+16'h06D7] = 8'h90;
      mem[PROG_BASE+16'h06D8] = 8'h90;
      mem[PROG_BASE+16'h06D9] = 8'h90;
      mem[PROG_BASE+16'h06DA] = 8'h90;
      mem[PROG_BASE+16'h06DB] = 8'h90;
      mem[PROG_BASE+16'h06DC] = 8'h90;
      mem[PROG_BASE+16'h06DD] = 8'h90;
      mem[PROG_BASE+16'h06DE] = 8'h90;
      mem[PROG_BASE+16'h06DF] = 8'h90;
      mem[PROG_BASE+16'h06E0] = 8'h90;
      mem[PROG_BASE+16'h06E1] = 8'h90;
      mem[PROG_BASE+16'h06E2] = 8'h90;
      mem[PROG_BASE+16'h06E3] = 8'h90;
      mem[PROG_BASE+16'h06E4] = 8'h90;
      mem[PROG_BASE+16'h06E5] = 8'h90;
      mem[PROG_BASE+16'h06E6] = 8'h90;
      mem[PROG_BASE+16'h06E7] = 8'h90;
      mem[PROG_BASE+16'h06E8] = 8'h90;
      mem[PROG_BASE+16'h06E9] = 8'h90;
      mem[PROG_BASE+16'h06EA] = 8'h90;
      mem[PROG_BASE+16'h06EB] = 8'h90;
      mem[PROG_BASE+16'h06EC] = 8'h90;
      mem[PROG_BASE+16'h06ED] = 8'h90;
      mem[PROG_BASE+16'h06EE] = 8'h90;
      mem[PROG_BASE+16'h06EF] = 8'h90;
      mem[PROG_BASE+16'h06F0] = 8'h90;
      mem[PROG_BASE+16'h06F1] = 8'h90;
      mem[PROG_BASE+16'h06F2] = 8'h90;
      mem[PROG_BASE+16'h06F3] = 8'h90;
      mem[PROG_BASE+16'h06F4] = 8'h90;
      mem[PROG_BASE+16'h06F5] = 8'h90;
      mem[PROG_BASE+16'h06F6] = 8'h90;
      mem[PROG_BASE+16'h06F7] = 8'h90;
      mem[PROG_BASE+16'h06F8] = 8'h90;
      mem[PROG_BASE+16'h06F9] = 8'h90;
      mem[PROG_BASE+16'h06FA] = 8'h90;
      mem[PROG_BASE+16'h06FB] = 8'h90;
      mem[PROG_BASE+16'h06FC] = 8'h90;
      mem[PROG_BASE+16'h06FD] = 8'h90;
      mem[PROG_BASE+16'h06FE] = 8'h90;
      mem[PROG_BASE+16'h06FF] = 8'h90;
      mem[PROG_BASE+16'h0700] = 8'h90;
      mem[PROG_BASE+16'h0701] = 8'h90;
      mem[PROG_BASE+16'h0702] = 8'h90;
      mem[PROG_BASE+16'h0703] = 8'h90;
      mem[PROG_BASE+16'h0704] = 8'h90;
      mem[PROG_BASE+16'h0705] = 8'h90;
      mem[PROG_BASE+16'h0706] = 8'h90;
      mem[PROG_BASE+16'h0707] = 8'h90;
      mem[PROG_BASE+16'h0708] = 8'h90;
      mem[PROG_BASE+16'h0709] = 8'h90;
      mem[PROG_BASE+16'h070A] = 8'h90;
      mem[PROG_BASE+16'h070B] = 8'h90;
      mem[PROG_BASE+16'h070C] = 8'h90;
      mem[PROG_BASE+16'h070D] = 8'h90;
      mem[PROG_BASE+16'h070E] = 8'h90;
      mem[PROG_BASE+16'h070F] = 8'h90;
      mem[PROG_BASE+16'h0710] = 8'h90;
      mem[PROG_BASE+16'h0711] = 8'h90;
      mem[PROG_BASE+16'h0712] = 8'h90;
      mem[PROG_BASE+16'h0713] = 8'h90;
      mem[PROG_BASE+16'h0714] = 8'h90;
      mem[PROG_BASE+16'h0715] = 8'h90;
      mem[PROG_BASE+16'h0716] = 8'h90;
      mem[PROG_BASE+16'h0717] = 8'h90;
      mem[PROG_BASE+16'h0718] = 8'h90;
      mem[PROG_BASE+16'h0719] = 8'h90;
      mem[PROG_BASE+16'h071A] = 8'h90;
      mem[PROG_BASE+16'h071B] = 8'h90;
      mem[PROG_BASE+16'h071C] = 8'h90;
      mem[PROG_BASE+16'h071D] = 8'h90;
      mem[PROG_BASE+16'h071E] = 8'h90;
      mem[PROG_BASE+16'h071F] = 8'h90;
      mem[PROG_BASE+16'h0720] = 8'h90;
      mem[PROG_BASE+16'h0721] = 8'h90;
      mem[PROG_BASE+16'h0722] = 8'h90;
      mem[PROG_BASE+16'h0723] = 8'h90;
      mem[PROG_BASE+16'h0724] = 8'h90;
      mem[PROG_BASE+16'h0725] = 8'h90;
      mem[PROG_BASE+16'h0726] = 8'h90;
      mem[PROG_BASE+16'h0727] = 8'h90;
      mem[PROG_BASE+16'h0728] = 8'h90;
      mem[PROG_BASE+16'h0729] = 8'h90;
      mem[PROG_BASE+16'h072A] = 8'h90;
      mem[PROG_BASE+16'h072B] = 8'h90;
      mem[PROG_BASE+16'h072C] = 8'h90;
      mem[PROG_BASE+16'h072D] = 8'h90;
      mem[PROG_BASE+16'h072E] = 8'h90;
      mem[PROG_BASE+16'h072F] = 8'h90;
      mem[PROG_BASE+16'h0730] = 8'h90;
      mem[PROG_BASE+16'h0731] = 8'h90;
      mem[PROG_BASE+16'h0732] = 8'h90;
      mem[PROG_BASE+16'h0733] = 8'h90;
      mem[PROG_BASE+16'h0734] = 8'h90;
      mem[PROG_BASE+16'h0735] = 8'h90;
      mem[PROG_BASE+16'h0736] = 8'h90;
      mem[PROG_BASE+16'h0737] = 8'h90;
      mem[PROG_BASE+16'h0738] = 8'h90;
      mem[PROG_BASE+16'h0739] = 8'h90;
      mem[PROG_BASE+16'h073A] = 8'h90;
      mem[PROG_BASE+16'h073B] = 8'h90;
      mem[PROG_BASE+16'h073C] = 8'h90;
      mem[PROG_BASE+16'h073D] = 8'h90;
      mem[PROG_BASE+16'h073E] = 8'h90;
      mem[PROG_BASE+16'h073F] = 8'h90;
      mem[PROG_BASE+16'h0740] = 8'h90;
      mem[PROG_BASE+16'h0741] = 8'h90;
      mem[PROG_BASE+16'h0742] = 8'h90;
      mem[PROG_BASE+16'h0743] = 8'h90;
      mem[PROG_BASE+16'h0744] = 8'h90;
      mem[PROG_BASE+16'h0745] = 8'h90;
      mem[PROG_BASE+16'h0746] = 8'h90;
      mem[PROG_BASE+16'h0747] = 8'h90;
      mem[PROG_BASE+16'h0748] = 8'h90;
      mem[PROG_BASE+16'h0749] = 8'h90;
      mem[PROG_BASE+16'h074A] = 8'h90;
      mem[PROG_BASE+16'h074B] = 8'h90;
      mem[PROG_BASE+16'h074C] = 8'h90;
      mem[PROG_BASE+16'h074D] = 8'h90;
      mem[PROG_BASE+16'h074E] = 8'h90;
      mem[PROG_BASE+16'h074F] = 8'h90;
      mem[PROG_BASE+16'h0750] = 8'h90;
      mem[PROG_BASE+16'h0751] = 8'h90;
      mem[PROG_BASE+16'h0752] = 8'h90;
      mem[PROG_BASE+16'h0753] = 8'h90;
      mem[PROG_BASE+16'h0754] = 8'h90;
      mem[PROG_BASE+16'h0755] = 8'h90;
      mem[PROG_BASE+16'h0756] = 8'h90;
      mem[PROG_BASE+16'h0757] = 8'h90;
      mem[PROG_BASE+16'h0758] = 8'h90;
      mem[PROG_BASE+16'h0759] = 8'h90;
      mem[PROG_BASE+16'h075A] = 8'h90;
      mem[PROG_BASE+16'h075B] = 8'h90;
      mem[PROG_BASE+16'h075C] = 8'h90;
      mem[PROG_BASE+16'h075D] = 8'h90;
      mem[PROG_BASE+16'h075E] = 8'h90;
      mem[PROG_BASE+16'h075F] = 8'h90;
      mem[PROG_BASE+16'h0760] = 8'h90;
      mem[PROG_BASE+16'h0761] = 8'h90;
      mem[PROG_BASE+16'h0762] = 8'h90;
      mem[PROG_BASE+16'h0763] = 8'h90;
      mem[PROG_BASE+16'h0764] = 8'h90;
      mem[PROG_BASE+16'h0765] = 8'h90;
      mem[PROG_BASE+16'h0766] = 8'h90;
      mem[PROG_BASE+16'h0767] = 8'h90;
      mem[PROG_BASE+16'h0768] = 8'h90;
      mem[PROG_BASE+16'h0769] = 8'h90;
      mem[PROG_BASE+16'h076A] = 8'h90;
      mem[PROG_BASE+16'h076B] = 8'h90;
      mem[PROG_BASE+16'h076C] = 8'h90;
      mem[PROG_BASE+16'h076D] = 8'h90;
      mem[PROG_BASE+16'h076E] = 8'h90;
      mem[PROG_BASE+16'h076F] = 8'h90;
      mem[PROG_BASE+16'h0770] = 8'h90;
      mem[PROG_BASE+16'h0771] = 8'h90;
      mem[PROG_BASE+16'h0772] = 8'h90;
      mem[PROG_BASE+16'h0773] = 8'h90;
      mem[PROG_BASE+16'h0774] = 8'h90;
      mem[PROG_BASE+16'h0775] = 8'h90;
      mem[PROG_BASE+16'h0776] = 8'h90;
      mem[PROG_BASE+16'h0777] = 8'h90;
      mem[PROG_BASE+16'h0778] = 8'h90;
      mem[PROG_BASE+16'h0779] = 8'h90;
      mem[PROG_BASE+16'h077A] = 8'h90;
      mem[PROG_BASE+16'h077B] = 8'h90;
      mem[PROG_BASE+16'h077C] = 8'h90;
      mem[PROG_BASE+16'h077D] = 8'h90;
      mem[PROG_BASE+16'h077E] = 8'h90;
      mem[PROG_BASE+16'h077F] = 8'h90;
      mem[PROG_BASE+16'h0780] = 8'h90;
      mem[PROG_BASE+16'h0781] = 8'h90;
      mem[PROG_BASE+16'h0782] = 8'h90;
      mem[PROG_BASE+16'h0783] = 8'h90;
      mem[PROG_BASE+16'h0784] = 8'h90;
      mem[PROG_BASE+16'h0785] = 8'h90;
      mem[PROG_BASE+16'h0786] = 8'h90;
      mem[PROG_BASE+16'h0787] = 8'h90;
      mem[PROG_BASE+16'h0788] = 8'h90;
      mem[PROG_BASE+16'h0789] = 8'h90;
      mem[PROG_BASE+16'h078A] = 8'h90;
      mem[PROG_BASE+16'h078B] = 8'h90;
      mem[PROG_BASE+16'h078C] = 8'h90;
      mem[PROG_BASE+16'h078D] = 8'h90;
      mem[PROG_BASE+16'h078E] = 8'h90;
      mem[PROG_BASE+16'h078F] = 8'h90;
      mem[PROG_BASE+16'h0790] = 8'h90;
      mem[PROG_BASE+16'h0791] = 8'h90;
      mem[PROG_BASE+16'h0792] = 8'h90;
      mem[PROG_BASE+16'h0793] = 8'h90;
      mem[PROG_BASE+16'h0794] = 8'h90;
      mem[PROG_BASE+16'h0795] = 8'h90;
      mem[PROG_BASE+16'h0796] = 8'h90;
      mem[PROG_BASE+16'h0797] = 8'h90;
      mem[PROG_BASE+16'h0798] = 8'h90;
      mem[PROG_BASE+16'h0799] = 8'h90;
      mem[PROG_BASE+16'h079A] = 8'h90;
      mem[PROG_BASE+16'h079B] = 8'h90;
      mem[PROG_BASE+16'h079C] = 8'h90;
      mem[PROG_BASE+16'h079D] = 8'h90;
      mem[PROG_BASE+16'h079E] = 8'h90;
      mem[PROG_BASE+16'h079F] = 8'h90;
      mem[PROG_BASE+16'h07A0] = 8'h90;
      mem[PROG_BASE+16'h07A1] = 8'h90;
      mem[PROG_BASE+16'h07A2] = 8'h90;
      mem[PROG_BASE+16'h07A3] = 8'h90;
      mem[PROG_BASE+16'h07A4] = 8'h90;
      mem[PROG_BASE+16'h07A5] = 8'h90;
      mem[PROG_BASE+16'h07A6] = 8'h90;
      mem[PROG_BASE+16'h07A7] = 8'h90;
      mem[PROG_BASE+16'h07A8] = 8'h90;
      mem[PROG_BASE+16'h07A9] = 8'h90;
      mem[PROG_BASE+16'h07AA] = 8'h90;
      mem[PROG_BASE+16'h07AB] = 8'h90;
      mem[PROG_BASE+16'h07AC] = 8'h90;
      mem[PROG_BASE+16'h07AD] = 8'h90;
      mem[PROG_BASE+16'h07AE] = 8'h90;
      mem[PROG_BASE+16'h07AF] = 8'h90;
      mem[PROG_BASE+16'h07B0] = 8'h90;
      mem[PROG_BASE+16'h07B1] = 8'h90;
      mem[PROG_BASE+16'h07B2] = 8'h90;
      mem[PROG_BASE+16'h07B3] = 8'h90;
      mem[PROG_BASE+16'h07B4] = 8'h90;
      mem[PROG_BASE+16'h07B5] = 8'h90;
      mem[PROG_BASE+16'h07B6] = 8'h90;
      mem[PROG_BASE+16'h07B7] = 8'h90;
      mem[PROG_BASE+16'h07B8] = 8'h90;
      mem[PROG_BASE+16'h07B9] = 8'h90;
      mem[PROG_BASE+16'h07BA] = 8'h90;
      mem[PROG_BASE+16'h07BB] = 8'h90;
      mem[PROG_BASE+16'h07BC] = 8'h90;
      mem[PROG_BASE+16'h07BD] = 8'h90;
      mem[PROG_BASE+16'h07BE] = 8'h90;
      mem[PROG_BASE+16'h07BF] = 8'h90;
      mem[PROG_BASE+16'h07C0] = 8'h90;
      mem[PROG_BASE+16'h07C1] = 8'h90;
      mem[PROG_BASE+16'h07C2] = 8'h90;
      mem[PROG_BASE+16'h07C3] = 8'h90;
      mem[PROG_BASE+16'h07C4] = 8'h90;
      mem[PROG_BASE+16'h07C5] = 8'h90;
      mem[PROG_BASE+16'h07C6] = 8'h90;
      mem[PROG_BASE+16'h07C7] = 8'h90;
      mem[PROG_BASE+16'h07C8] = 8'h90;
      mem[PROG_BASE+16'h07C9] = 8'h90;
      mem[PROG_BASE+16'h07CA] = 8'h90;
      mem[PROG_BASE+16'h07CB] = 8'h90;
      mem[PROG_BASE+16'h07CC] = 8'h90;
      mem[PROG_BASE+16'h07CD] = 8'h90;
      mem[PROG_BASE+16'h07CE] = 8'h90;
      mem[PROG_BASE+16'h07CF] = 8'h90;
      mem[PROG_BASE+16'h07D0] = 8'h90;
      mem[PROG_BASE+16'h07D1] = 8'h90;
      mem[PROG_BASE+16'h07D2] = 8'h90;
      mem[PROG_BASE+16'h07D3] = 8'h90;
      mem[PROG_BASE+16'h07D4] = 8'h90;
      mem[PROG_BASE+16'h07D5] = 8'h90;
      mem[PROG_BASE+16'h07D6] = 8'h90;
      mem[PROG_BASE+16'h07D7] = 8'h90;
      mem[PROG_BASE+16'h07D8] = 8'h90;
      mem[PROG_BASE+16'h07D9] = 8'h90;
      mem[PROG_BASE+16'h07DA] = 8'h90;
      mem[PROG_BASE+16'h07DB] = 8'h90;
      mem[PROG_BASE+16'h07DC] = 8'h90;
      mem[PROG_BASE+16'h07DD] = 8'h90;
      mem[PROG_BASE+16'h07DE] = 8'h90;
      mem[PROG_BASE+16'h07DF] = 8'h90;
      mem[PROG_BASE+16'h07E0] = 8'h90;
      mem[PROG_BASE+16'h07E1] = 8'h90;
      mem[PROG_BASE+16'h07E2] = 8'h90;
      mem[PROG_BASE+16'h07E3] = 8'h90;
      mem[PROG_BASE+16'h07E4] = 8'h90;
      mem[PROG_BASE+16'h07E5] = 8'h90;
      mem[PROG_BASE+16'h07E6] = 8'h90;
      mem[PROG_BASE+16'h07E7] = 8'h90;
      mem[PROG_BASE+16'h07E8] = 8'h90;
      mem[PROG_BASE+16'h07E9] = 8'h90;
      mem[PROG_BASE+16'h07EA] = 8'h90;
      mem[PROG_BASE+16'h07EB] = 8'h90;
      mem[PROG_BASE+16'h07EC] = 8'h90;
      mem[PROG_BASE+16'h07ED] = 8'h90;
      mem[PROG_BASE+16'h07EE] = 8'h90;
      mem[PROG_BASE+16'h07EF] = 8'h90;
      mem[PROG_BASE+16'h07F0] = 8'h90;
      mem[PROG_BASE+16'h07F1] = 8'h90;
      mem[PROG_BASE+16'h07F2] = 8'h90;
      mem[PROG_BASE+16'h07F3] = 8'h90;
      mem[PROG_BASE+16'h07F4] = 8'h90;
      mem[PROG_BASE+16'h07F5] = 8'h90;
      mem[PROG_BASE+16'h07F6] = 8'h90;
      mem[PROG_BASE+16'h07F7] = 8'h90;
      mem[PROG_BASE+16'h07F8] = 8'h90;
      mem[PROG_BASE+16'h07F9] = 8'h90;
      mem[PROG_BASE+16'h07FA] = 8'h90;
      mem[PROG_BASE+16'h07FB] = 8'h90;
      mem[PROG_BASE+16'h07FC] = 8'h90;
      mem[PROG_BASE+16'h07FD] = 8'h90;
      mem[PROG_BASE+16'h07FE] = 8'h90;
      mem[PROG_BASE+16'h07FF] = 8'h90;
      mem[PROG_BASE+16'h0800] = 8'hB0;
      mem[PROG_BASE+16'h0801] = 8'hFF;
      mem[PROG_BASE+16'h0802] = 8'hE6;
      mem[PROG_BASE+16'h0803] = 8'hFF;
      mem[PROG_BASE+16'h0804] = 8'hF4;
      // THE STRIDE IS PRE-LOADED INTO THE RAM MODEL, not stored by the guest program. The stub's
      // own `mov word [0x49C],0x28` executed but the routine then read 0 from it: z486's caches
      // are enabled, so the CPU's view and this model are not the same storage, and a store that
      // has not drained is invisible here. Pre-loading before reset puts the value where the
      // CPU's line fill reads it, exactly as the program bytes themselves are placed. (Reading
      // mem[] after the run is equally unreliable for the same reason - the scratch and stack
      // both read as zeros here even though the routine used them.)
      mem[PROG_BASE+16'h049C] = 8'h28;   // 40, the machine's GDC pitch in words
      mem[PROG_BASE+16'h049D] = 8'h00;
    end
  endtask

  // ---------------- bench-side window master ----------------
  integer errors = 0;
  integer wd;

  // A STRING port, not the template's [8*200-1:0] bit vector: this bench calls fail() with
  // $sformatf results, and Verilator refuses to cast a std::string into a wide bit vector.
  task automatic fail(input string what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  task automatic bench_store(input [31:0] addr, input [31:0] data, input [3:0] be);
    begin
      @(negedge clk);
      bench_addr  = addr;
      bench_din   = data;
      bench_be    = be;
      bench_write = 1'b1;
      bench_valid = 1'b1;
      @(posedge clk); #1;
      wd = 0;
      while (!gv_cpu_ready) begin
        @(posedge clk); #1;
        wd = wd + 1;
        if (wd == 400) begin
          fail("a bench window store never became ready");
          $finish;
        end
      end
      @(negedge clk);
      bench_valid = 1'b0;
      bench_write = 1'b0;
      bench_be    = 4'hF;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic bench_load(input [31:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      bench_addr  = addr;
      bench_write = 1'b0;
      bench_be    = 4'hF;
      bench_valid = 1'b1;
      @(posedge clk); #1;
      wd = 0;
      while (!gv_cpu_ready) begin
        @(posedge clk); #1;
        wd = wd + 1;
        if (wd == 400) begin
          fail("a bench window read never became ready");
          $finish;
        end
      end
      @(negedge clk);
      bench_valid = 1'b0;
      #1;
      wd = 0;
      while (!gv_cpu_resp_valid) begin
        @(posedge clk); #1;
        wd = wd + 1;
        if (wd == 400) begin
          fail("a bench window read never returned a response");
          $finish;
        end
      end
      data = gv_cpu_dout;
      @(negedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  // Fill columns [0, FILL_COLS) of all four planes with `v`, through the plane
  // windows, with the GRCG DISARMED and the CURRENT access page selected, so each
  // store is a plain single-plane write of the page the guest later reads.
  localparam integer FILL_COLS = 16'h3000;
  task automatic fill_planes(input [7:0] v);
    integer c;
    begin
      for (c = 0; c < FILL_COLS; c = c + 4) begin
        bench_store(WIN_B + {2'b0, c[14:2], 2'b00}, {v,v,v,v}, 4'hF);
        bench_store(WIN_R + {2'b0, c[14:2], 2'b00}, {v,v,v,v}, 4'hF);
        bench_store(WIN_G + {2'b0, c[14:2], 2'b00}, {v,v,v,v}, 4'hF);
        bench_store(WIN_E + {2'b0, c[14:2], 2'b00}, {v,v,v,v}, 4'hF);
      end
    end
  endtask

  // Read the four planes' dword at column `off` on the CURRENT access page.
  task automatic read_planes(input [14:0] off, output [31:0] b, output [31:0] r,
                             output [31:0] g, output [31:0] e);
    begin
      bench_load(WIN_B + {17'd0, off}, b);
      bench_load(WIN_R + {17'd0, off}, r);
      bench_load(WIN_G + {17'd0, off}, g);
      bench_load(WIN_E + {17'd0, off}, e);
    end
  endtask

  // ---------------- z486 reset, from the working z486 harness ----------------
  z486_pkg::seg_desc_t cs_desc;
  z486_pkg::seg_desc_t es_desc;

  task automatic core_reset;
    begin
      reset_n_sys = 1'b0;
      #30;

      // A 16-bit real-mode code segment at 0xC0000: the guest's own encoding, so
      // the operand forms (and therefore the byte enables) are the guest's.
      cs_desc = z486_pkg::seg_desc_real_mode_code(PROG_SEG);
      force cpu.seg_unit.seg_init_cs = cs_desc;
      // ES at the B window base, so the store target is 0xA8000 even before the
      // program's own `mov es,ax` takes effect.
      es_desc = z486_pkg::seg_desc_real_mode(16'hA800);
      force cpu.seg_unit.seg_init_es = es_desc;
      force cpu.seg_unit.seg_init_ds = z486_pkg::seg_desc_real_mode(16'h0000);
      force cpu.seg_unit.seg_init_ss = z486_pkg::seg_desc_real_mode(16'h0000);
      force cpu.seg_unit.seg_init_fs = z486_pkg::seg_desc_real_mode(16'h0000);
      force cpu.seg_unit.seg_init_gs = z486_pkg::seg_desc_real_mode(16'h0000);
      force cpu.CR0 = 32'h0;
      force cpu.CS  = PROG_SEG;
      force cpu.DS  = 16'h0000;
      force cpu.ES  = 16'hA800;
      force cpu.SS  = 16'h0000;
      force cpu.EIP = 32'd0;
      // pf_fetch_addr is the LINEAR prefetch address (prefetch.sv:98, `Next LINEAR cache-line address`), so it is
      // CS.base + EIP, not the bare EIP (the z486 harness can pass EIP directly
      // only because its CS base is 0).
      force cpu.prefetch_inst.pf_fetch_addr = PROG_BASE;

      #50;
      reset_n_sys = 1'b1;
      release cpu.CR0;
      release cpu.CS;
      release cpu.DS;
      release cpu.ES;
      release cpu.SS;
      release cpu.EIP;
      release cpu.prefetch_inst.pf_fetch_addr;
      release cpu.seg_unit.seg_init_cs;
      release cpu.seg_unit.seg_init_ds;
      release cpu.seg_unit.seg_init_es;
      release cpu.seg_unit.seg_init_ss;
      release cpu.seg_unit.seg_init_fs;
      release cpu.seg_unit.seg_init_gs;
    end
  endtask

  task automatic run_to_hlt(input string name);
    integer c;
    begin
      c = 0;
      while (c < 400000 && !cpu.stall_wio) begin
        @(posedge clk);
        c = c + 1;
      end
      if (c >= 400000) begin
        $display("PC98 GRCG CPU FAIL: %0s timeout (halted=%b) cs=%04x eip=%08x",
                 name, cpu.stall_wio, cpu.CS, cpu.EIP);
        $display("   DIAGNOSTIC: %0d window stores, %0d window READS, %0d I/O writes, gstate=%0d",
                 n_stores, n_gvreads, n_iow, dut.u_arb.gstate);
        $display("   DIAGNOSTIC: GRCG mode=0x%02x, access_page=%b, done=%b",
                 dut.u_grcg.mode, access_page, done);
        dump_ring(60);
        $display("   DIAGNOSTIC z486: stall=%b stall_mem=%b stall_wio=%b mem_servicing=%b halted=%b",
                 cpu.stall, cpu.stall_mem, cpu.stall_wio, cpu.mem_servicing, cpu.halted);
        $display("   DIAGNOSTIC z486: uc=%03x uaddr=%03x uc_active=%b uc_exec=%b payload_ready=%b exw=%b",
                 cpu.uc_addr, cpu.uaddr, cpu.uc_active, cpu.uc_exec,
                 cpu.d2_payload_ready, cpu.d2_ea_split_wait);
        $display("   DIAGNOSTIC z486: d1dir=%b valid=%b decq_empty=%b",
                 cpu.d1_issue_direct, cpu.vipt_load_ex_r.valid, cpu.decq_empty);
        $fatal(1);
      end
      $display("PHASE_CYCLES %0s: %0d", name, c);
      // Drain posted stores before sampling.
      c = 0;
      while (c < 4000 && !cpu.memory_inst.dcache_stores_drained) begin
        @(posedge clk);
        c = c + 1;
      end
      repeat (40) @(posedge clk);
    end
  endtask

  // ---------------- store-shape recording ----------------
  // 0x4000 word stores, plus headroom; the CPU never exceeds it.
  localparam integer MAX_STORES = 1 << 16;
  integer    n_stores = 0;
  reg [31:0] st_addr [0:MAX_STORES-1];
  reg  [3:0] st_be   [0:MAX_STORES-1];
  reg [31:0] st_data [0:MAX_STORES-1];

  // ---- the bus ring: what the CPU and the GVRAM actually did in the last cycles ----
  // Added 2026-10-03 to attribute the read stall: EIP history separates "stuck" from "slow",
  // and the per-cycle valid/ready/resp/gstate shows which side stopped speaking.
  localparam integer RING = 512;
  reg [31:0] rb_addr [0:RING-1];
  reg  [9:0] rb_info [0:RING-1];   // {z_valid,z_write,z_ready,z_resp_valid,gv_sel_z,arb.gstate[2:0],stall_wio,io_sel}
  reg [31:0] rb_eip  [0:RING-1];
  reg [15:0] rb_cs   [0:RING-1];
  integer    rb_i = 0;
  always @(posedge clk) begin
    rb_addr[rb_i] = {z_addr, 2'b00};
    rb_info[rb_i] = {z_valid, z_write, z_ready, z_resp_valid, gv_sel_z,
                     dut.u_arb.gstate[2:0], cpu.stall_wio, io_sel};
    rb_eip[rb_i]  = cpu.EIP;
    rb_cs[rb_i]   = cpu.CS;
    rb_i = (rb_i + 1) % RING;
  end
  // ---- trip on the hang so the ring still holds the HANDSHAKE ----
  // 400k cycles of stall means a 512-cycle ring has long since lost the read that started it.
  // `mem_servicing` with no bus request is the signature of a response the CPU believes is
  // still coming, so dump at the FIRST long window of it and not at the timeout.
  integer  hung_cycles = 0;
  always @(posedge clk) begin
    if (cpu.mem_servicing === 1'b1 && z_valid === 1'b0) begin
      hung_cycles = hung_cycles + 1;
      if (hung_cycles == 100) begin
        $display("== TRIP: mem_servicing with NO bus request for 100 cycles ==");
        dump_ring(140);
        $display("   DIAGNOSTIC arb: gstate=%0d m_mode=%b accept_ok=%b cc_valid=%b cc_lane_many=%b w_first_lane=%0d c_many=%b c_write_q=%b cpu_valid_in=%b",
                 dut.u_arb.gstate, dut.u_arb.m_mode, dut.u_arb.accept_ok, dut.u_arb.cc_valid,
                 dut.u_arb.cc_lane_many, dut.u_arb.w_first_lane, dut.u_arb.c_many,
                 dut.u_arb.c_write_q, dut.u_arb.cpu_valid);
        $display("   DIAGNOSTIC z486: stall=%b stall_mem=%b mem_servicing=%b uc=%03x uaddr=%03x",
                 cpu.stall, cpu.stall_mem, cpu.mem_servicing, cpu.uc_addr, cpu.uaddr);
        $fatal(1, "TB_PC9821_GVRAM_PAGECOPY: TRIP (the read handshake never completed)");
      end
    end else begin
      hung_cycles = 0;
    end
  end

  task automatic dump_ring(input integer n);
    integer k, idx;
    begin
      $display("   ---- the last %0d cycles: cs:eip addr vwrsG gstate stall io ----", n);
      for (k = n - 1; k >= 0; k = k - 1) begin
        idx = (rb_i - 1 - k + RING) % RING;
        $display("     %04x:%08x  %08x  v%0b w%0b r%0b s%0b g%0b G%0d st%0b io%0b",
                 rb_cs[idx], rb_eip[idx], rb_addr[idx], rb_info[idx][9], rb_info[idx][8],
                 rb_info[idx][7], rb_info[idx][6], rb_info[idx][5], rb_info[idx][4:2],
                 rb_info[idx][1], rb_info[idx][0]);
      end
    end
  endtask
  integer n_gvreads = 0;
  reg     st_ready_q = 1'b0;
  always @(posedge clk) begin
    // Count the ACCEPT EDGE, not every cycle the request is presented: the holder keeps it
    // presented until its completion, so a per-cycle test double-counts (2880 for 1440 stores).
    if (gv_sel_z && z_ready && !st_ready_q) begin
      if (!gv_write) n_gvreads = n_gvreads + 1;
      if (n_stores < MAX_STORES) begin
        st_addr[n_stores] = bench_valid ? bench_addr : (h_valid ? h_addr : {z_addr, 2'b00});
        st_be[n_stores]   = gv_be;
        st_data[n_stores] = gv_din;
      end
      n_stores = n_stores + 1;
    end
    st_ready_q <= gv_sel_z && z_ready;
  end

  // ---------------- I/O write recording (the GRCG arming) ----------------
  localparam integer MAX_IOW = 32;
  integer   n_iow = 0;
  reg [7:0] iow_addr [0:MAX_IOW-1];
  reg [7:0] iow_data [0:MAX_IOW-1];

  always @(posedge clk) begin
    if (port_we) begin
      if (n_iow < MAX_IOW) begin
        iow_addr[n_iow] = port_addr;
        iow_data[n_iow] = port_din;
      end
      n_iow = n_iow + 1;
    end
  end

  // ---------------- run ----------------
  integer    i;
  integer    n_pair = 0, n_other = 0;
  // ---------------- the pattern, and where the copy must put it ----------------
  // A pure function of (byte offset, plane, page), so the expected destination bytes are
  // computable from the routine's arithmetic alone - never from this repo's RTL. Both pages
  // and all four planes are filled with it, which makes a WRONG-PAGE write, a WRONG-PLANE
  // window, a dropped store and a byte-enable fault each change the bytes that must match.
  function automatic [7:0] pat(input [15:0] off, input [2:0] pl, input pg);
    pat = ((off[7:0] * 8'd7) + (off[15:8] * 8'd13)) ^ (pl * 8'h31)
          ^ (pg ? 8'h5B : 8'h00) ^ 8'hA5;
  endfunction

  function automatic [31:0] want4(input [15:0] off, input [2:0] pl);
    want4 = {pat(off + 16'd3, pl, 1'b1), pat(off + 16'd2, pl, 1'b1),
             pat(off + 16'd1, pl, 1'b1), pat(off + 16'd0, pl, 1'b1)};
  endfunction

  // The routine's own arithmetic, at STRIDE = 40 (the machine's GDC pitch, the value its PITCH
  // routine stores into [0x049C]), ROW = 0 and SRC = 0x100:
  //   dst  = (0x78 - 0)*40 + 0x100 = 4800 + 256 = 5056 = 0x13C0
  //   src1 = (0x78 - 0 + 5)*40 + 0x100 = 5000 + 256 = 5256 = 0x1488
  // The FIRST read leg uses the same offset as the destination, so the first 400 bytes of the
  // destination must equal the SOURCE PAGE's pattern at those same offsets.
  // AND THE FIRST READ LEG STARTS AT THE RAW ARGUMENT: the guest's own code is
  // `mov si,[bp+0x8]` at 0x605 - the source argument ITSELF - while only the second leg
  // (`mov si,dx` at 0x60D) uses a computed offset, and DI (the write) uses the computed one.
  // Reading it as "both legs computed" is what made the first four dword checks fail on all
  // four planes: the destination was right (the stores end at 0x168C = dst + 716) and the
  // expectation was wrong.
  localparam [15:0] DST  = 16'h13C0;   // (0x78 - row)*stride + src  -> the write leg
  localparam [15:0] SRC0 = 16'h0100;   // [bp+8] itself              -> the first read leg
  localparam [15:0] SRC1 = 16'h1488;   // (0x78 - row + 5)*stride+src -> the second read leg

  task automatic fill_page(input pg, input [31:0] win, input [2:0] pl);
    integer c;
    begin
      access_page = pg;
      for (c = 0; c < FILL_COLS; c = c + 4)
        bench_store(win + c, {pat(c[15:0] + 16'd3, pl, pg), pat(c[15:0] + 16'd2, pl, pg),
                              pat(c[15:0] + 16'd1, pl, pg), pat(c[15:0] + 16'd0, pl, pg)}, 4'hF);
    end
  endtask

  integer   e, d;
  integer   n_word = 0, n_mrg = 0, n_odd = 0;
  reg [31:0] got, want;
  reg [2:0]  pl;
  reg [31:0] win;

  initial begin
    reset       = 1'b1;
    reset_n_sys = 1'b0;
    access_page = 1'b0;
    done        = 1'b0;
    load_program();
    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (8) @(posedge clk);

    // Pre-fill BOTH pages, all four planes, with the address-dependent pattern.
    for (pl = 0; pl < 4; pl = pl + 1) begin
      case (pl)
        3'd0: win = WIN_B;
        3'd1: win = WIN_R;
        3'd2: win = WIN_G;
        default: win = WIN_E;
      endcase
      fill_page(1'b0, win, pl);
      fill_page(1'b1, win, pl);
    end
    access_page = 1'b0;
    $display("== pre-filled %0d planes x 2 pages with the pattern ==", 4);

    // Did the stub's stride write land? The routine multiplies by [0x049C], so a zero there
    // collapses every computed offset onto the raw source argument.
    $display("== guest RAM [0x049C] = 0x%04X (want 0x0028 = 40, the stub's stride write)",
             {mem[32'h0000_049D], mem[32'h0000_049C]});
    // Did CPU RAM WRITES land at all? The stub's pushes are writes too, and the routine read its
    // argument back as 0x100, so the stack path works - this separates "RAM writes are broken"
    // from "this particular store is lost".
    $display("   stack words 0x7EF8..0x7EFF: %02X %02X %02X %02X %02X %02X %02X %02X",
             mem[32'h7EF8], mem[32'h7EF9], mem[32'h7EFA], mem[32'h7EFB],
             mem[32'h7EFC], mem[32'h7EFD], mem[32'h7EFE], mem[32'h7EFF]);
    $display("   (the pushes were 00/00, 00/01, 00/00, 00/00, 00/08 as words: row/page/src/row/CS/IP)");
    $display("   scratch 0x5CD2 first 4 bytes: %02X %02X %02X %02X",
             mem[32'h5CD2], mem[32'h5CD3], mem[32'h5CD4], mem[32'h5CD5]);
    // Run the guest's own routine on the REAL CPU.
    core_reset();
    run_to_hlt("gvram_pagecopy");

    $display("== the CPU issued %0d window store(s); I/O writes: ==", n_stores);
    for (e = 0; e < (n_iow < MAX_IOW ? n_iow : MAX_IOW); e = e + 1)
      $display("   out 0x%02x, 0x%02x", iow_addr[e], iow_data[e]);
    for (e = 0; e < (n_stores < MAX_STORES ? n_stores : MAX_STORES); e = e + 1) begin
      if (st_be[e] == 4'hF)                     n_mrg = n_mrg + 1;
      else if (st_be[e] == 4'b0011 || st_be[e] == 4'b1100) n_word = n_word + 1;
      else                                      n_odd  = n_odd + 1;
    end
    $display("   word stores %0d, merged-pair stores %0d, partial shapes %0d",
             n_word, n_mrg, n_odd);
    for (e = 0; e < 6 && e < n_stores; e = e + 1)
      $display("   store[%0d] addr=0x%05X (win off 0x%04X) be=%b", e, st_addr[e],
               st_addr[e] & 32'h7FFF, st_be[e]);
    if (n_stores > 0)
      $display("   store[last] addr=0x%05X (win off 0x%04X)", st_addr[n_stores-1],
               st_addr[n_stores-1] & 32'h7FFF);
    if (n_odd != 0)
      fail("a `rep movsw` window store was neither a whole 16-bit word nor a merged pair");
    if (n_stores == 0)
      fail("the routine issued no window store at all - nothing reached the GVRAM route");
    // 4 plane iterations x 360 words = 1440 words, as 16-bit stores or merged pairs.
    if (n_word + n_mrg != 2880)
      fail($sformatf("the routine issued %0d lane accepts, want 2880 (4 planes x 360 words x 2 lanes)",
                     n_word + n_mrg));

    // ==== CHECKS ====
    // The destination page must hold the SOURCE page's pattern at the routine's own offsets,
    // and the source page must be untouched - a write that landed on the wrong page shows up
    // as page 1 no longer matching its own pattern.
    access_page = 1'b0;
    for (pl = 0; pl < 4; pl = pl + 1) begin
      case (pl)
        3'd0: win = WIN_B;
        3'd1: win = WIN_R;
        3'd2: win = WIN_G;
        default: win = WIN_E;
      endcase
      for (d = 0; d < 100; d = d + 1) begin
        bench_load(win + DST + 4*d, got);
        want = want4(SRC0 + 4*d, pl);       // the first leg's source is the raw argument
        if (got !== want) begin
          fail($sformatf("plane %0d: dst[0x%04X] = %08x, want %08x (first 200 words from SRC0)",
                         pl, DST + 4*d, got, want));
          d = 100;
        end
      end
      for (d = 0; d < 80; d = d + 1) begin
        bench_load(win + DST + 16'd400 + 4*d, got);
        want = want4(SRC1 + 4*d, pl);
        if (got !== want) begin
          fail($sformatf("plane %0d: dst[0x%04X] = %08x, want %08x (the 160-word second leg)",
                         pl, DST + 16'd400 + 4*d, got, want));
          d = 80;
        end
      end
    end
    $display("== destination page 0 verified against the source page's pattern, 4 planes ==");

    access_page = 1'b1;
    for (pl = 0; pl < 4; pl = pl + 1) begin
      case (pl)
        3'd0: win = WIN_B;
        3'd1: win = WIN_R;
        3'd2: win = WIN_G;
        default: win = WIN_E;
      endcase
      for (d = 0; d < 100; d = d + 1) begin
        bench_load(win + DST + 4*d, got);
        want = want4(DST + 4*d, pl);
        if (got !== want) begin
          fail($sformatf("plane %0d: SOURCE page 1 was MODIFIED at 0x%04X (%08x, want %08x) - a write landed on the wrong page",
                         pl, DST + 4*d, got, want));
          d = 100;
        end
      end
    end
    $display("== source page 1 is intact: the write leg used the page the routine set ==");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_PAGECOPY: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_GVRAM_PAGECOPY: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000_000;   // 400 ms: the two-page four-plane pre-fill is ~25k stores
    $fatal(1, "TB_PC9821_GVRAM_PAGECOPY: TIMEOUT");
  end

endmodule
