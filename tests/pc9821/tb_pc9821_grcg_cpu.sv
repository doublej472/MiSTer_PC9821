`timescale 1ns/1ps
`include "z486_pc98_preset.svh"

// ==== WHAT THIS PROVES ====
// TB_PC9821_GRCG_CPU: the graphics-charger fill END TO END, driven by the REAL z486 executing the REAL guest clear sequence (FSMAIN.EXE @0xB1C: `out 0x7C,0x80`, four `out 0x7E,0`, then `rep stosw` through ES=0xA800 over 0x4000 words) through the REAL pc9821_memory_map plane-window decode into the REAL pc9821_gvram client and its GRCG, so the shape the CPU actually presents on the client port - the operand's byte enables, the DWORD-ALIGNED address, the datum and the store order - is what the GRCG's TDW burst classification keys on. The leaf benches (tb_pc9821_grcg / grcg_ops) drive that port by hand and prove a whole-pair TDW zero-fill expands to all four planes; what they cannot see is whether z486 PRESENTS those whole pairs for `rep stosw`, which is the seam this bench closes. Every window store the CPU issues is recorded as {addr, be, data}; the shapes are asserted to be whole column pairs (0011/1100/1111), the precondition the burst needs; and the guest-visible outcome is asserted through the CPU's own read path: the cleared page reads back zero in ALL FOUR planes while the OTHER access page, filled with a different pattern and not addressed by the clear, keeps it byte for byte - so a one-plane (blue-only) fill, a wrong-page fill or a dead read path cannot pass.
//
// Blind spots stated: the access page is 0 on the guest side, the EGC is gated off (Farland
// Story never arms it: its only FF2 writes are num 0 and num 0x20, never num 2), and the
// source is ONE 16-bit real-mode `rep stosw` - a 32-bit operand or an EGC-routed variant is
// not covered. The guest's datum is 0xA800 (AX, which it also used for the segment), which
// the TDW must IGNORE; the bench prints it and does not assert it.

`default_nettype none

module tb_pc9821_grcg_cpu;

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
  localparam [31:0] PROG_BASE = 32'h000C_0000;        // the DIRECT device aperture
  localparam [15:0] PROG_SEG  = 16'hC000;

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

  // The address the plane-window decode sees. z486's own is {z_addr, 2'b00}
  // (z486.sv's address output is 30 bits, "Physical address [31:2]").
  wire [31:0] bus_addr = bench_valid ? bench_addr : {z_addr, 2'b00};

  // ---------------- the REAL map's plane-window decode ----------------
  wire        gvram_window;
  wire [1:0]  gvram_win_plane;
  wire [14:0] gvram_win_offset;

  // ==== DUT ====
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;
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
  wire        gv_sel_z = z_valid && !z_io && gvram_window;
  wire        gv_sel   = gv_sel_z || bench_valid;
  wire [31:0] gv_din   = bench_valid ? bench_din   : z_dout;
  wire  [3:0] gv_be    = bench_valid ? bench_be    : z_be;
  wire        gv_write = bench_valid ? bench_write : z_write;
  wire        gv_line_read = bench_valid ? 1'b0 : z_line_read;

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
    end else begin
      port_we       <= 1'b0;
      io_resp_valid <= 1'b0;
      if (io_sel && io_ready) begin
        if (z_write) begin
          // presented the cycle after the bus accept, as pc9821_iobus presents
          // its device-bus write.
          port_we   <= 1'b1;
          port_addr <= io_port;
          port_din  <= io_wdata;
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
      mem[PROG_BASE+0]  = 8'hB0;  // mov al,0x80
      mem[PROG_BASE+1]  = 8'h80;
      mem[PROG_BASE+2]  = 8'hE6;  // out 0x7C,al
      mem[PROG_BASE+3]  = 8'h7C;
      mem[PROG_BASE+4]  = 8'h32;  // xor al,al
      mem[PROG_BASE+5]  = 8'hC0;
      mem[PROG_BASE+6]  = 8'hE6;  // out 0x7E,al   (0x7C's write reset the tile pointer)
      mem[PROG_BASE+7]  = 8'h7E;
      mem[PROG_BASE+8]  = 8'hE6;  // out 0x7E,al
      mem[PROG_BASE+9]  = 8'h7E;
      mem[PROG_BASE+10] = 8'hE6;  // out 0x7E,al
      mem[PROG_BASE+11] = 8'h7E;
      mem[PROG_BASE+12] = 8'hE6;  // out 0x7E,al
      mem[PROG_BASE+13] = 8'h7E;
      mem[PROG_BASE+14] = 8'hB8;  // mov ax,0xA800
      mem[PROG_BASE+15] = 8'h00;
      mem[PROG_BASE+16] = 8'hA8;
      mem[PROG_BASE+17] = 8'h8E;  // mov es,ax
      mem[PROG_BASE+18] = 8'hC0;
      mem[PROG_BASE+19] = 8'h33;  // xor di,di
      mem[PROG_BASE+20] = 8'hFF;
      mem[PROG_BASE+21] = 8'hB9;  // mov cx,0x4000
      mem[PROG_BASE+22] = 8'h00;
      mem[PROG_BASE+23] = 8'h40;
      mem[PROG_BASE+24] = 8'hF3;  // rep stosw   (AX = 0xA800, which the TDW must ignore)
      mem[PROG_BASE+25] = 8'hAB;
      mem[PROG_BASE+26] = 8'h32;  // xor al,al
      mem[PROG_BASE+27] = 8'hC0;
      mem[PROG_BASE+28] = 8'hE6;  // out 0x7C,al   (the guest disarms the GRCG here)
      mem[PROG_BASE+29] = 8'h7C;
      mem[PROG_BASE+30] = 8'hF4;  // hlt
    end
  endtask

  // ---------------- bench-side window master ----------------
  integer errors = 0;
  integer wd;

  task automatic fail(input [8*200-1:0] what);
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
  localparam integer FILL_COLS = 16'h0400;
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

  always @(posedge clk) begin
    if (gv_sel_z && z_ready) begin
      if (n_stores < MAX_STORES) begin
        st_addr[n_stores] = {z_addr, 2'b00};
        st_be[n_stores]   = z_be;
        st_data[n_stores] = z_dout;
      end
      n_stores = n_stores + 1;
    end
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
  reg [31:0] b0, r0, g0, e0;
  reg [31:0] b1, r1, g1, e1;
  reg [31:0] b2, r2, g2, e2;
  reg [31:0] p0, q0, s0, t0;      // page 1, column 0 (the control)
  reg [31:0] p1, q1, s1, t1;      // page 1, column 0x0100

  initial begin
    // 1. Hold both resets and load the program.
    reset       = 1'b1;
    reset_n_sys = 1'b0;
    access_page = 1'b0;
    load_program();
    repeat (8) @(posedge clk);

    // 2. Release the GVRAM and pre-fill BOTH pages with different patterns.
    reset = 1'b0;
    repeat (8) @(posedge clk);
    access_page = 1'b0;
    fill_planes(8'hA5);
    access_page = 1'b1;
    fill_planes(8'h5A);
    access_page = 1'b0;

    read_planes(15'h0000, b0, r0, g0, e0);
    if (b0 !== 32'hA5A5A5A5 || r0 !== 32'hA5A5A5A5 ||
        g0 !== 32'hA5A5A5A5 || e0 !== 32'hA5A5A5A5) begin
      $display("FAIL the page-0 pre-fill did not land: B=%08x R=%08x G=%08x E=%08x",
               b0, r0, g0, e0);
      errors = errors + 1;
    end
    access_page = 1'b1;
    read_planes(15'h0000, p0, q0, s0, t0);
    access_page = 1'b0;
    if (p0 !== 32'h5A5A5A5A || q0 !== 32'h5A5A5A5A ||
        s0 !== 32'h5A5A5A5A || t0 !== 32'h5A5A5A5A) begin
      $display("FAIL the page-1 pre-fill did not land: B=%08x R=%08x G=%08x E=%08x",
               p0, q0, s0, t0);
      errors = errors + 1;
    end

    // 3. Reset and release z486, then run the guest clear (page 0).
    core_reset();
    run_to_hlt("grcg_cpu_clear");

    // 4. The shapes the CPU presented on the window port.
    $display("== the CPU issued %0d window store(s) ==", n_stores);
    for (i = 0; i < (n_stores < MAX_STORES ? n_stores : MAX_STORES); i = i + 1) begin
      if (st_be[i] == 4'b0011 || st_be[i] == 4'b1100 || st_be[i] == 4'b1111)
        n_pair = n_pair + 1;
      else
        n_other = n_other + 1;
    end
    $display("   whole column pairs (0011/1100/1111): %0d; other shapes: %0d",
             n_pair, n_other);
    if (n_stores != 0) begin
      $display("   store[0]: %08x be=%b data=%08x", st_addr[0], st_be[0], st_data[0]);
      if (n_stores > 1)
        $display("   store[1]: %08x be=%b data=%08x", st_addr[1], st_be[1], st_data[1]);
    end
    $display("== the CPU's I/O writes (the GRCG arming) ==");
    for (i = 0; i < (n_iow < MAX_IOW ? n_iow : MAX_IOW); i = i + 1)
      $display("   out 0x%02x, 0x%02x", iow_addr[i], iow_data[i]);
    $display("   GRCG mode register now = 0x%02x, expand gate = %b",
             dut.u_grcg.mode, dut.grcg_expand);
    if (n_other != 0)
      fail("a `rep stosw` window store was not a whole column pair, so the GRCG's TDW burst cannot take it");
    if (n_stores == 0)
      fail("the guest clear issued no window store at all - the store never reached the GVRAM route");

    // 5. The guest-visible outcome. Page 0 is cleared in ALL FOUR planes; page 1,
    //    which the clear never addresses, keeps its own pattern byte for byte.
    // ==== CHECKS ====
    access_page = 1'b0;
    read_planes(15'h0000, b0, r0, g0, e0);
    read_planes(15'h0100, b1, r1, g1, e1);
    read_planes(15'h03FC, b2, r2, g2, e2);
    access_page = 1'b1;
    read_planes(15'h0000, p0, q0, s0, t0);
    read_planes(15'h0100, p1, q1, s1, t1);
    access_page = 1'b0;

    $display("== cleared page 0 (want all zero) ==");
    $display("   col 0x0000: B=%08x R=%08x G=%08x E=%08x", b0, r0, g0, e0);
    $display("   col 0x0100: B=%08x R=%08x G=%08x E=%08x", b1, r1, g1, e1);
    $display("   col 0x03FC: B=%08x R=%08x G=%08x E=%08x", b2, r2, g2, e2);
    $display("== control page 1, never addressed (want 0x5A5A5A5A) ==");
    $display("   col 0x0000: B=%08x R=%08x G=%08x E=%08x", p0, q0, s0, t0);
    $display("   col 0x0100: B=%08x R=%08x G=%08x E=%08x", p1, q1, s1, t1);

    if (b0 !== 32'd0 || r0 !== 32'd0 || g0 !== 32'd0 || e0 !== 32'd0)
      fail("the clear did not reach all four planes at page-0 column 0x0000 (a single-plane fill leaves the others)");
    if (b1 !== 32'd0 || r1 !== 32'd0 || g1 !== 32'd0 || e1 !== 32'd0)
      fail("the clear did not reach all four planes at page-0 column 0x0100");
    if (b2 !== 32'd0 || r2 !== 32'd0 || g2 !== 32'd0 || e2 !== 32'd0)
      fail("the clear did not reach all four planes at page-0 column 0x03FC");
    if (p0 !== 32'h5A5A5A5A || q0 !== 32'h5A5A5A5A ||
        s0 !== 32'h5A5A5A5A || t0 !== 32'h5A5A5A5A)
      fail("the clear disturbed page 1, which it never addressed (the access page is not applied)");
    if (p1 !== 32'h5A5A5A5A || q1 !== 32'h5A5A5A5A ||
        s1 !== 32'h5A5A5A5A || t1 !== 32'h5A5A5A5A)
      fail("the clear disturbed page 1 at column 0x0100");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GRCG_CPU: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_GRCG_CPU: FAIL (%0d errors)", errors);
  end

  initial begin
    #80_000_000;   // 80 ms: the two-page pre-fill (~2k stores) plus the clear (16k)
    $fatal(1, "TB_PC9821_GRCG_CPU: TIMEOUT");
  end

endmodule
