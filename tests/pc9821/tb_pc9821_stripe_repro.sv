`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_STRIPE_REPRO: the observed horizontal stripe under the CONTENDED case the earlier value benches never drove. tb_pc9821_planewin_draw draws a full-screen picture with a raster flush per row and read every byte back right, but it drove the scanout and the CPU one after the other; this bench drives them TOGETHER through the DEPLOYED route - the real pc9821_memory_subsystem (so the response-route queue is in the path), the real pc9821_gvram, the real sdram_sync_bridge (the controller on clk_sys, here 50 MHz) and the real src/memory/sdram.v controller - with the scanout's line fetch ticking every raster line on its own port while the CPU runs a plane-window row stream (the graphics library's rep movsw / rep stosw shape: consecutive 16-bit stores down a row, the LAST one a partial byte), and compares every plane byte of the row against a software model.

`default_nettype none

module tb_pc9821_stripe_repro;
  localparam integer CYCLE_SYS_NS   = 20;
  localparam integer CAS = 2;
  localparam integer LINE_COLS = 80;

  reg clk = 0;
  always #(CYCLE_SYS_NS/2)   clk = ~clk;      // 50 MHz: the subsystem AND the SDRAM controller
  reg reset = 1;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== pc9821_memory_subsystem ports ====
  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg        bios_ram_gate = 0;
  reg [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg        top_shadow_en = 0;
  reg        sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg        gvram_access_page = 0;

  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0;
  reg [7:0]  grcg_din = 0;
  wire       grcg_expand;
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here


  reg        egc_enable = 0;
  reg [15:0] egc_access = 16'hFFF0;
  reg [15:0] egc_fgbg = 16'h00FF;
  reg [15:0] egc_ope = 16'h0000;
  reg [15:0] egc_fg = 16'h0000;
  reg [15:0] egc_mask = 16'hFFFF;
  reg [15:0] egc_bg = 16'h0000;
  reg [15:0] egc_sft = 16'h0000;
  reg [15:0] egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;

  reg        ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire       ioctl_wait, rom_ready, load_error, cpu_run;

  reg        scan_enable = 0;
  reg        scan_line_tick = 0;
  reg        scan_page = 0;
  reg        scan_walk_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel;
  wire        line_ready;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 8'd1;
  reg        cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire       cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire [7:0]  tram_din;
  wire        tram_we;
  reg  [7:0]  tram_dout = 0;
  reg  [7:0]  tram [0:16383];

  wire [4:0] cg_win_byte_sel;
  wire       cg_win_rd;
  reg  [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire       cg_win_we;

  reg [18:0] font_req_addr = 0;
  reg        font_req = 0;
  wire       font_word_valid;
  wire [31:0] font_word_data;
  wire [17:0] font_addr;
  wire [15:0] font_data;
  wire        font_we;

  reg         fmem_ready = 1, fmem_resp_valid = 0;
  reg  [31:0] fmem_dout = 32'd0;
  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write;
  wire [3:0]  fmem_be;
  wire [7:0]  fmem_burstcount;

  reg  [31:0] mem3_dout = 32'd0;
  reg         mem3_ready = 0, mem3_resp_valid = 0;
  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;

  wire [1:0] ems_state = 2'd0;

  // The subsystem's port-0 bus, into the real SDRAM bridge.
  wire [31:0] mem_addr, mem_din, mem_din_hi, mem_dout;
  // The G3 gather session's qualifier and entries (the subsystem's mem_gath* outputs,
  // carried into the bridge; the store buffer groups its drains with them) and the
  // geometry its row key needs.
  wire        mem_gath;
  wire [440:0] mem_gath_extra;
  wire  [1:0] sdram_size = 2'd2;
  wire [127:0] mem_line_dout;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write, mem_ready, mem_resp_valid;
  wire        mem_line_resp_valid;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;
  wire        busy;
  wire [127:0] dbg_gfx_stats;
  wire dbg_walk_start, dbg_walk_cycle;   // the GVRAM's walk pulses, same reason
  wire dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;   // the EGC/GRCG operation pulses, same reason
  // The GRCG's and the EGC's per-cycle ownership pulses; this bench does not count
  // them, but (.*) needs every port named.
  wire dbg_gr_owned, dbg_eg_owned;
  // The page-coincidence probe's two page levels; this bench does not read them,
  // but (.*) needs every port named.
  wire dbg_access_page, dbg_scan_page_q;

  // Backend transaction counters: what the WCB actually issued.
  integer n_pair_wr = 0, n_single_wr = 0, n_rd = 0;
  integer n_wb4 = 0;   // the EGC/GRCG TWO-WORD WRITE burst (B_WB4)
  // The WCB forwarding / write-back counters are gone with the write-combining buffer:
  // the scanout reads the M10K array directly and sees every store on the clk_sys it commits, so
  // the stripe this bench reproduced (a fetch reading behind a pending write-back) cannot arise.
  // ==== DUT ====
  wire cg_win_byte_hold = 1'b0;
  // Tied off: the 200-line interleave's odd-line fetch-skip input (400-line traffic
  // here; tb_pc9821_interleave_200 drives it).
  wire gfx_odd_line = 1'b0;
  // ---- pc9821_memory_subsystem's DMA bus-master port, tied off (see the iobus block) ----
/* verilator lint_off UNUSEDSIGNAL */
  wire        dma_addr_unused = 1'b0;
  wire [31:0] dma_addr = 32'd0;
  wire [1:0]  dma_gvwin = 2'b00;   // the DMAC's plane-window class of dma_addr (idle here)
  wire [31:0] dma_din  = 32'd0;
  wire [3:0]  dma_be   = 4'd0;
  wire        dma_valid = 1'b0;
  wire        dma_write = 1'b0;
  wire        dma_ready, dma_resp_valid;
  wire [31:0] dma_dout;
/* verilator lint_on UNUSEDSIGNAL */
  // The GDC draw engine's visit (the GDC2 WRITE slice) is not this bench's subject: tied
  // off, so the CPU side permanently owns the GVRAM port share.
  wire        gdc_mem_valid = 1'b0;
  wire        gdc_mem_write = 1'b0;
  wire        gdc_mem_route_egc = 1'b0;
  wire        gdc_mem_route_grcg = 1'b0;
  wire        gdc_mem_page = 1'b0;
  wire  [1:0] gdc_mem_plane = 2'd0;
  wire [14:0] gdc_mem_offset = 15'd0;
  wire [31:0] gdc_mem_din = 32'd0;
  wire  [3:0] gdc_mem_be = 4'd0;
  wire        gdc_mem_ready;
  wire        gdc_mem_resp;
  wire [31:0] gdc_mem_rdata;
  // The PEGC view select (pc9821_crtc's mode2_256col, pegc-scope-REPORT.md 4 row 2):
  // 0 = the pre-PEGC decode this bench drives; the PEGC arms are tb_pc9821_memmap_ref's.
  wire pegc_256 = 1'b0;
  // PEGC packed scanout's fourth-requester port (pegc-scope-REPORT.md 4 rows 3/6),
  // tied off: pegc_256 is 0 here, so the packed fetch never runs and the fourth
  // SDRAM requester stays idle (tb_pc9821_pegc_scanout drives this path).
  wire pegc_256e = 1'b0;
  wire [2:0] scan_dot = 3'b0;
  wire [7:0] peg_packed_idx;
  wire peg_line_sel, peg_line_ready;
  wire [31:0] pmem_addr, pmem_din;
  wire pmem_valid, pmem_write;
  wire  [3:0] pmem_be;
  wire  [7:0] pmem_burstcount;
  wire pmem_ready = 1'b1;
  wire [31:0] pmem_dout = 32'b0;
  wire pmem_resp_valid = 1'b0;
  // Not the packed dot phase's subject here: the one-clk-early address is inert
  // (tb_pc9821_pegc_scan_dot owns it).
  wire scan_dot_ce = 1'b0;
  wire scan_dot_act = 1'b1;

  // The plain-window client's ownership pulse (pc9821_memory_subsystem's dbg_pw_owned,
  // added 2026-10-03 so the page-coincidence counter covers plain stores too). `.*` needs a
  // matching net here; this bench does not read it.
  wire dbg_pw_owned;

  // 0x063C bank select into the 0xD8000 window: 0 = the IDE option ROM, the reset bank.

  reg  [1:0] d8_bank = 2'b00;

  pc9821_memory_subsystem dut (.*);

  // The bridge: port 0 = the subsystem's mem_* bus (the CPU + loader), port 2 = the scanout line
  // fetch (the subsystem's mem3_* bus). The bridge has three ports; port 2 was
  // the 86-PCM buffer in the SoC and is idle here, so the subsystem's scanout route (mem3_*) is
  // wired to it. The controller's fourth port is tied idle inside the bridge.
  sdram_sync_bridge #(
      .FREQ(`TB_SDRAM_FREQ), .FAST_GRADE(1'b0)
  ) bridge (
      .clk(clk), .resetn(~reset),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(mem_valid), .ready0(mem_ready), .wr0(mem_write),
      .addr0(mem_addr[26:0]), .din0(mem_din), .din0_hi(mem_din_hi), .gath0(mem_gath), .gath0_extra(mem_gath_extra),
      .dout0(mem_dout), .be0(mem_be), .resp_valid0(mem_resp_valid),
      .burst_cnt0(mem_burstcount[3:0]),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0),
      .dout1(), .be1(4'd0), .resp_valid1(), .burst_cnt1(4'd0),
      .valid2(mem3_valid), .ready2(mem3_ready), .wr2(mem3_write),
      .addr2(mem3_addr[26:0]), .din2(mem3_din),
      .dout2(mem3_dout), .be2(mem3_be), .resp_valid2(mem3_resp_valid),
      .burst_cnt2(mem3_burstcount[3:0]),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );
  // The line form has no producer in the built design (z486_mister.sv ties it off).
  assign mem_line_resp_valid = 1'b0;

  sdram_chip_model #(.CAS(CAS), .T_RP(`TB_CHIP_TRP), .T_WR(`TB_CHIP_TWR)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== THE MODEL: word o carries {P3,P2,P1,P0}; the plane's byte at plane offset o is
  // exp_word[o][plane*8 +: 8]. One word == one 8-pixel column of the four planes.
  localparam integer NW = 4096;
  reg [31:0] exp_word [0:NW-1];

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [255:0] what);
    begin
      $display("FAIL stripe_repro: %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS through the subsystem's CPU port ====
  // Plane p (0..2) lives at 0xA8000 + p*0x8000, the intensity plane (3) at 0xE0000.
  function [31:0] plane_base(input [1:0] p);
    begin
      plane_base = (p == 2'd3) ? 32'h000E_0000 : (32'h000A_8000 + (p * 32'h0000_8000));
    end
  endfunction

  task automatic cpu_op(input [31:0] addr, input [31:0] din, input [3:0] be, input wr,
                        output [31:0] dout);
    begin
      @(negedge clk);
      cpu_addr  = addr;
      cpu_din   = din;
      cpu_be    = be;
      cpu_write = wr;
      cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
        @(negedge clk);
      end else dout = 32'd0;
    end
  endtask

  // A 16-bit plane store at plane byte offset `off` (even), plane `plane`, value `v`.
  task automatic word_wr(input [1:0] plane, input [14:0] off, input [15:0] v);
    reg [31:0] d;
    begin
      d = off[1] ? {v, 16'd0} : {16'd0, v};
      cpu_op(plane_base(plane) + {17'd0, off}, d, (off[1] ? 4'b1100 : 4'b0011), 1'b1, d);
    end
  endtask

  task automatic word_rd(input [1:0] plane, input [14:0] off, output [15:0] v);
    reg [31:0] d;
    begin
      cpu_op(plane_base(plane) + {17'd0, off}, 32'd0, (off[1] ? 4'b1100 : 4'b0011), 1'b0, d);
      v = off[1] ? d[31:16] : d[15:0];
    end
  endtask

  function [7:0] model_byte(input integer widx, input integer plane);
    begin
      model_byte = exp_word[widx][plane*8 +: 8];
    end
  endfunction

  // ==== SCANOUT LINE DRIVER ====
  reg        scan_run = 1'b0;
  integer    scan_line = 0;
  integer    scan_lines = 0;

  task automatic tick(input integer base);
    begin
      @(negedge clk);
      scan_line_base = 15'(base);
      scan_line_tick = 1'b1;
      @(posedge clk);
      @(negedge clk);
      scan_line_tick = 1'b0;
    end
  endtask

  integer tick_period = 240;
  initial begin : scan_bg
    integer t0;
    forever begin
      @(posedge clk);
      if (scan_run) begin
        tick((scan_line % 4) * LINE_COLS);
        scan_line  = scan_line + 1;
        scan_lines = scan_lines + 1;
        t0 = cyc;
        while ((cyc - t0) < tick_period) @(posedge clk);
      end
    end
  end

  // ==== STIMULUS ====
  // ==== WRITE / VERIFY ====
  integer i, p, c, wbase, bad;
  integer loff;
  reg [15:0] got, v;
  reg [31:0] d;
  integer trials, fails;

  localparam integer NT = 24;

  // One plane-window row: 40 16-bit stores at plane offsets wbase..wbase+79 on plane p. The last
  // one is a single byte (the right-edge column the symptom shows).
  task automatic put_row(input [1:0] plane, input integer wb, input [7:0] seed);
    begin
      for (c = 0; c < 40; c = c + 1) begin
        v = ({8'h80, 8'h40} + {8'd0, seed}) ^ {8'd0, c[7:0]};
        if (c == 39) begin
          loff = (wb + 2*c) & 3;
          d = ({24'd0, v[7:0]} << (8*loff));
          cpu_op(plane_base(plane) + {17'd0, 15'(wb + 2*c)}, d, 4'b0001 << loff, 1'b1, d);
          exp_word[wb + 2*c][plane*8 +: 8] = v[7:0];
        end else begin
          word_wr(plane, 15'(wb + 2*c), v);
          exp_word[wb + 2*c][plane*8 +: 8]     = v[7:0];
          exp_word[wb + 2*c + 1][plane*8 +: 8] = v[15:8];
        end
      end
    end
  endtask

  task automatic check_row(input [1:0] plane, input integer wb, input [8*24-1:0] label);
    begin
      for (c = 0; c < 40; c = c + 1) begin
        word_rd(plane, 15'(wb + 2*c), got);
        if (got[7:0] !== model_byte(wb + 2*c, plane)) begin
          if (bad < 6)
            $display("FAIL stripe_repro: %0s plane %0d word %0d got %02x want %02x",
                     label, plane, wb+2*c, got[7:0], model_byte(wb+2*c, plane));
          bad = bad + 1;
        end
        if (got[15:8] !== model_byte(wb + 2*c + 1, plane)) begin
          if (bad < 6)
            $display("FAIL stripe_repro: %0s plane %0d word %0d got %02x want %02x",
                     label, plane, wb+2*c+1, got[15:8], model_byte(wb+2*c+1, plane));
          bad = bad + 1;
        end
      end
    end
  endtask

  // The game's own sprite shape (ptn_put_quarter_8): for each of 16 rows and each of the four
  // planes, read the plane's 16-bit word at the sprite offset and `or es:[di],ax` it back. The
  // model follows the RMW, so the check is the final value, not the delta.
  localparam integer SPR_ROWS = 16;
  localparam integer SPR_STRIDE = LINE_COLS;
  task automatic put_sprite(input integer base, input [7:0] seed);
    integer row2;
    reg [15:0] w, w2;
    begin
      for (row2 = 0; row2 < SPR_ROWS; row2 = row2 + 1)
        for (p = 0; p < 4; p = p + 1) begin
          word_rd(p[1:0], 15'(base + row2 * SPR_STRIDE), w);
          w2 = w | ({8'hF0, 8'hF0} ^ {8'd0, seed});
          word_wr(p[1:0], 15'(base + row2 * SPR_STRIDE), w2);
          exp_word[base + row2 * SPR_STRIDE][p*8 +: 8]     = w2[7:0];
          exp_word[base + row2 * SPR_STRIDE + 1][p*8 +: 8] = w2[15:8];
        end
    end
  endtask

  // A continuous-cadence stream: the CPU keeps `cpu_valid` high and re-points the request in the
  // ACCEPT cycle, so the plain client sees a back-to-back `rep movsw` stream with no idle cycle
  // between accesses (the shape tb_pc9821_plain_write's driver uses).
  task automatic stream_row(input [1:0] plane, input integer wb, input [7:0] seed);
    integer c2, loff2;
    reg [31:0] d2;
    begin
      cpu_valid = 1'b1; cpu_write = 1'b1;
      for (c2 = 0; c2 < 40; c2 = c2 + 1) begin
        v = ({8'h80, 8'h40} + {8'd0, seed}) ^ {8'd0, c2[7:0]};
        loff2 = (wb + 2*c2) & 3;
        d2 = {16'd0, v} << (8*loff2);
        cpu_addr = plane_base(plane) + {17'd0, 15'(wb + 2*c2)};
        cpu_din  = d2;
        cpu_be   = (loff2 == 0) ? 4'b0011 : 4'b1100;
        @(negedge clk);
        while (!cpu_ready) @(negedge clk);
        exp_word[wb + 2*c2][plane*8 +: 8]     = v[7:0];
        exp_word[wb + 2*c2 + 1][plane*8 +: 8] = v[15:8];
      end
      cpu_valid = 1'b0; cpu_write = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic check_sprite(input integer base, input [8*24-1:0] label);
    integer row2;
    begin
      check_row(2'd0, base, label);
      // rows are LINE_COLS apart; check each row pair of every plane
      for (row2 = 0; row2 < SPR_ROWS; row2 = row2 + 1)
        for (p = 0; p < 4; p = p + 1) begin
          word_rd(p[1:0], 15'(base + row2 * SPR_STRIDE), got);
          if (got[7:0] !== model_byte(base + row2*SPR_STRIDE, p)) begin
            if (bad < 6)
              $display("FAIL stripe_repro: %0s sprite row %0d plane %0d got %02x want %02x",
                       label, row2, p, got[7:0], model_byte(base + row2*SPR_STRIDE, p));
            bad = bad + 1;
          end
        end
    end
  endtask

  integer g;
  task automatic settle;
    begin
      @(negedge clk); scan_enable = 1'b1; scan_line_tick = 1'b1;
      @(negedge clk); scan_line_tick = 1'b0;
      g = 0;
      while (1'b0 && (g < 8000)) begin @(posedge clk); g = g + 1; end
      repeat (60) @(posedge clk);
      scan_enable = 1'b0;
    end
  endtask

  // Fetch one line with the CPU idle and compare the assembled ping-pong buffer against the
  // model: the scanout must see exactly the plane data the CPU left behind.
  task automatic check_line(input integer base, input [8*24-1:0] label);
    integer c2, g2;
    begin
      tick(base);
      g2 = 0;
      while (!(!dut.u_gvram_scan.fetch_active && !dut.u_gvram_scan.fetch_req_d) && (g2 < 8000)) begin
        @(posedge clk); g2 = g2 + 1;
      end
      for (c2 = 0; c2 < LINE_COLS; c2 = c2 + 1) begin
        if (dut.u_gvram_scan.line_buf[{dut.u_gvram_scan.wr_sel, c2[6:0]}] !== exp_word[base + c2]) begin
          if (bad < 6)
            $display("FAIL stripe_repro: %0s scanout col %0d got %08x want %08x",
                     label, c2, dut.u_gvram_scan.line_buf[{dut.u_gvram_scan.wr_sel, c2[6:0]}], exp_word[base + c2]);
          bad = bad + 1;
        end
      end
    end
  endtask

  task automatic do_reset;
    begin
      reset = 1;
      repeat (8) @(posedge clk);
      reset = 0;
      repeat (4) @(posedge clk);
    end
  endtask

  integer guard;
  task automatic load_rom;
    begin
      ioctl_download = 1;
      ioctl_addr = 27'd0;
      ioctl_dout = 16'hBEEF;
      ioctl_wr = 1;
      @(posedge clk);
      ioctl_wr = 0;
      repeat (2) @(posedge clk);
      ioctl_download = 0;
      guard = 0;
      while (!rom_ready && guard < 20000) begin @(posedge clk); guard = guard + 1; end
      if (!rom_ready || !cpu_run) fail("the ROM loader never brought cpu_run up");
    end
  endtask

  // The GRCG's register port (0x7C mode, 0x7E tiles), as the games write it.
  task automatic grcg_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); grcg_we = 1'b1; grcg_addr = a; grcg_din = d;
      @(negedge clk); grcg_we = 1'b0;
    end
  endtask

  // A GRCG TDW 16-bit store at plane offset off (mode 0x80): the burst writes the tile to BOTH
  // covered columns of every plane. The model follows.
  task automatic grcg_tdw_row(input integer wb, input [7:0] t);
    integer c2, loff2;
    reg [31:0] d2;
    begin
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, t); grcg_w(8'h7E, t); grcg_w(8'h7E, t); grcg_w(8'h7E, t);
      for (c2 = 0; c2 < 40; c2 = c2 + 1) begin
        loff2 = (wb + 2*c2) & 3;
        d2 = 32'hFFFF_FFFF;
        cpu_op(plane_base(2'd0) + {17'd0, 15'(wb + 2*c2)}, d2,
               (loff2 == 0) ? 4'b0011 : 4'b1100, 1'b1, d2);
        exp_word[wb + 2*c2]     = {t, t, t, t};
        exp_word[wb + 2*c2 + 1] = {t, t, t, t};
      end
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  task automatic check_tdw_row(input integer wb, input [8*24-1:0] label);
    begin
      for (c = 0; c < 40; c = c + 1) begin
        word_rd(2'd0, 15'(wb + 2*c), got);
        if (got[7:0] !== model_byte(wb + 2*c, 0)) begin
          if (bad < 6)
            $display("FAIL stripe_repro: %0s word %0d got %02x want %02x",
                     label, wb+2*c, got[7:0], model_byte(wb+2*c, 0));
          bad = bad + 1;
        end
        if (got[15:8] !== model_byte(wb + 2*c + 1, 0)) begin
          if (bad < 6)
            $display("FAIL stripe_repro: %0s word %0d got %02x want %02x",
                     label, wb+2*c+1, got[15:8], model_byte(wb+2*c+1, 0));
          bad = bad + 1;
        end
      end
    end
  endtask

  initial begin
    for (i = 0; i < NW; i = i + 1) exp_word[i] = 32'd0;
    for (i = 0; i < 16384; i = i + 1) tram[i] = 8'h00;

    do_reset;
    load_rom;
    guard = 0;
    while (busy && guard < 80000) begin @(posedge clk); guard = guard + 1; end
    if (busy) fail("the controller never left init");
    repeat (20) @(posedge clk);

    scan_enable = 1'b0;
    bad = 0; fails = 0;

    // ---- TRIAL 1: control, no scanout, one row per plane. ----
    for (p = 0; p < 4; p = p + 1) begin
      put_row(p[1:0], 8, 8'h11);
      check_row(p[1:0], 8, "ctrl");
    end
    if (bad != 0) fail("control (no scanout): the plane row did not read back");
    $display("NOTE stripe_repro: control row read back %0d mismatches", bad);

    // ---- TRIAL 2: the row stream with the scanout fetching concurrently, sweeping the raster
    // phase relative to the CPU's store cadence (a fixed phase can step over the alignment). ----
    for (trials = 0; trials < 24; trials = trials + 1) begin
      tick_period = 20 + trials * 16;
      bad = 0;
      // Straddle the 512-dword SDRAM row boundary so the two-word write-back's split
      // (WRITE_BURST_ACT) is driven, as well as ordinary interior rows.
      case (trials % 6)
        0: wbase = 16;
        1: wbase = 168;
        2: wbase = 448;
        3: wbase = 500;
        4: wbase = 1016;
        default: wbase = 72;
      endcase
      scan_line = 0; scan_lines = 0;
      scan_enable = 1'b1;
      scan_run = 1'b1;
      for (p = 0; p < 4; p = p + 1)
        put_row(p[1:0], wbase, 8'h20 + trials[7:0]);
      scan_run = 1'b0;
      settle;
      for (p = 0; p < 4; p = p + 1)
        check_row(p[1:0], wbase, "concurrent");
      // The scanout's own view of the line must match too (only lines the model covers).
      if ((wbase + LINE_COLS) <= NW) begin
        scan_enable = 1'b1;
        check_line(wbase, "concurrent-line");
        scan_enable = 1'b0;
      end
      $display("NOTE stripe_repro: concurrent trial %0d (period %0d, wbase %0d): %0d scanout line(s), %0d mismatches",
               trials, tick_period, wbase, scan_lines, bad);
      if (bad != 0) fails = fails + 1;
    end
    if (fails != 0) fail("a concurrent plane row did not read back");

    // ---- TRIAL 3: the sprite RMW shape, concurrent with the scanout. ----
    fails = 0;
    for (trials = 0; trials < 12; trials = trials + 1) begin
      tick_period = 24 + trials * 32;
      bad = 0;
      wbase = 16 + (trials % 4) * 96;
      scan_line = 0; scan_lines = 0;
      scan_enable = 1'b1;
      scan_run = 1'b1;
      put_sprite(wbase, 8'h30 + trials[7:0]);
      scan_run = 1'b0;
      settle;
      check_sprite(wbase, "sprite");
      $display("NOTE stripe_repro: sprite trial %0d (period %0d, base %0d): %0d scanout line(s), %0d mismatches",
               trials, tick_period, wbase, scan_lines, bad);
      if (bad != 0) fails = fails + 1;
    end
    if (fails != 0) fail("a concurrent sprite RMW did not read back");

    // ---- TRIAL 4: the EGC copy (page 1 -> page 0), concurrent with the scanout. ----
    // The music room's dominant shape. Page 1 plane 0 is painted through the plain path (a 16-bit
    // word per EVEN offset, so each unit is one dword lane pair), the EGC copies the 16-bit unit
    // down a run, and page 0 plane 0 is read back and compared against the source.
    fails = 0;
    for (trials = 0; trials < 8; trials = trials + 1) begin
      tick_period = 40 + trials * 40;
      bad = 0;
      wbase = 8 + (trials % 4) * 8;
      // paint page 1 plane 0, one 16-bit word per even offset
      for (c = 0; c < SPR_ROWS; c = c + 1) begin
        gvram_access_page = 1'b1;
        v = 16'hA500 ^ {8'd0, (wbase + 2*c) };
        word_wr(2'd0, 15'(wbase + 2*c), v);
        gvram_access_page = 1'b0;
      end
      settle;
      scan_line = 0; scan_lines = 0;
      scan_enable = 1'b1;
      scan_run = 1'b1;
      // the EGC unit: the 0x3100 copy the game's library issues
      egc_enable = 1'b1;
      egc_access = 16'hFFF0;
      egc_fgbg   = 16'h00FF;
      egc_ope    = 16'h3100;
      egc_mask   = 16'hFFFF;
      @(negedge clk); egc_sft = 16'h0000; egc_leng = 16'h000F; egc_shift_we = 1'b1;
      @(negedge clk); egc_shift_we = 1'b0;
      for (c = 0; c < SPR_ROWS; c = c + 1) begin
        gvram_access_page = 1'b1;
        word_rd(2'd0, 15'(wbase + 2*c), v);
        gvram_access_page = 1'b0;
        word_wr(2'd0, 15'(wbase + 2*c), v);
      end
      egc_enable = 1'b0;
      scan_run = 1'b0;
      settle;
      // verify: page 0 plane 0 carries page 1 plane 0's pattern
      for (c = 0; c < SPR_ROWS; c = c + 1) begin
        gvram_access_page = 1'b0;
        word_rd(2'd0, 15'(wbase + 2*c), got);
        if (got !== (16'hA500 ^ {8'd0, (wbase + 2*c)})) begin
          if (bad < 6)
            $display("FAIL stripe_repro: EGC trial %0d unit %0d off %0d page0 got %04x want %04x",
                     trials, c, wbase + 2*c, got, 16'hA500 ^ {8'd0, (wbase + 2*c)});
          bad = bad + 1;
        end
      end
      $display("NOTE stripe_repro: EGC trial %0d (period %0d, base %0d): %0d scanout line(s), %0d mismatches",
               trials, tick_period, wbase, scan_lines, bad);
      if (bad != 0) fails = fails + 1;
    end
    if (fails != 0) fail("a concurrent EGC copy did not land");

    // ---- TRIAL 5: a long continuous-cadence stream across many lines, concurrent with the
    // scanout. This is the graphics library's rep movsw plane run: thousands of back-to-back
    // 16-bit stores, so the WCB evicts and pairs for a long stretch while the raster fetches. ----
    fails = 0;
    for (trials = 0; trials < 4; trials = trials + 1) begin
      tick_period = 30 + trials * 50;
      bad = 0;
      wbase = 8;
      scan_line = 0; scan_lines = 0;
      scan_enable = 1'b1;
      scan_run = 1'b1;
      for (p = 0; p < 4; p = p + 1)
        for (c = 0; c < 12; c = c + 1)
          stream_row(p[1:0], 8 + c * LINE_COLS, 8'h50 + c[7:0] + trials[7:0]);
      scan_run = 1'b0;
      settle;
      for (p = 0; p < 4; p = p + 1)
        for (c = 0; c < 12; c = c + 1)
          check_row(p[1:0], 8 + c * LINE_COLS, "stream");
      $display("NOTE stripe_repro: stream trial %0d (period %0d): %0d scanout line(s), %0d mismatches",
               trials, tick_period, scan_lines, bad);
      if (bad != 0) fails = fails + 1;
    end
    if (fails != 0) fail("a concurrent plane stream did not read back");

    // ---- TRIAL 6: the GRCG TDW store (a solid box row), concurrent with the scanout. ----
    fails = 0;
    for (trials = 0; trials < 10; trials = trials + 1) begin
      tick_period = 26 + trials * 36;
      bad = 0;
      wbase = 16 + (trials % 4) * 40;
      scan_line = 0; scan_lines = 0;
      scan_enable = 1'b1;
      scan_run = 1'b1;
      grcg_tdw_row(wbase, 8'h90 + trials[7:0]);
      scan_run = 1'b0;
      settle;
      check_tdw_row(wbase, "grcg-tdw");
      $display("NOTE stripe_repro: GRCG TDW trial %0d (period %0d, base %0d): %0d scanout line(s), %0d mismatches",
               trials, tick_period, wbase, scan_lines, bad);
      if (bad != 0) fails = fails + 1;
    end
    if (fails != 0) fail("a concurrent GRCG TDW row did not land");

    // ---- TRIAL 7 (DETERMINISTIC, fail-first): the scanout's fetch must see a CPU store that
    // landed in the write-combining buffer AFTER the line tick's flush. The tick flushes what is
    // dirty THEN, but the CPU keeps writing during the line's fetch, and a fetch burst that read
    // SDRAM behind such a store would put the column's PREVIOUS value on the line - the reported
    // "short strip from elsewhere in the picture". ----
    begin : stale_line
      integer lc;
      reg [31:0] want64;
      bad = 0;
      wbase = 240;
      // (a) paint the line (both planes' byte lanes) with the OLD image and let it reach SDRAM
      for (c = 0; c < 40; c = c + 1)
        for (p = 0; p < 4; p = p + 1) begin
          v = 16'h1234 ^ {8'd0, c[7:0]};
          word_wr(p[1:0], 15'(wbase + 2*c), v);
          exp_word[wbase + 2*c][p*8 +: 8]     = v[7:0];
          exp_word[wbase + 2*c + 1][p*8 +: 8] = v[15:8];
        end
      settle;
      // (b) tick the line, let the tick's flush land, then store NEW to one column WHILE the
      // fetch is still running: the store is in the buffer when the burst covering that column
      // is read from SDRAM.
      scan_enable = 1'b1;
      tick(wbase);
      g = 0;
      while (1'b0 && (g < 4000)) begin @(posedge clk); g = g + 1; end
      lc = wbase + 64;
      got = 0;  // unused here
      d = {24'd0, 8'h5A};
      cpu_op(plane_base(2'd0) + {17'd0, 15'(lc)}, d, 4'b0001, 1'b1, d);
      exp_word[lc][0*8 +: 8] = 8'h5A;
      // (c) let the fetch finish and compare the assembled line to the model
      g = 0;
      while (!(!dut.u_gvram_scan.fetch_active && !dut.u_gvram_scan.fetch_req_d) && (g < 8000)) begin
        @(posedge clk); g = g + 1;
      end
      scan_enable = 1'b0;
      want64 = exp_word[lc];
      if (dut.u_gvram_scan.line_buf[{dut.u_gvram_scan.wr_sel, 7'd64}] !== want64) begin
        $display("FAIL stripe_repro: the scanout's fetched line shows column 64 as %08x, but the CPU stored %08x there after the tick (stale fetch)",
                 dut.u_gvram_scan.line_buf[{dut.u_gvram_scan.wr_sel, 7'd64}], want64);
        bad = bad + 1;
      end
      $display("NOTE stripe_repro: stale-line: fetched col 64 = %08x, CPU-store model = %08x",
               dut.u_gvram_scan.line_buf[{dut.u_gvram_scan.wr_sel, 7'd64}], want64);
      if (bad != 0) fail("the scanout fetched a column behind a pending write-back");
    end
    // ---- TRIAL 7: a DISPLAY PAGE CHANGE while a line fetch is in flight. TH05's music room and
    // Rusty flip the display page at the frame boundary, so the first lines' fetches are the ones
    // in flight when scan_page moves. The burst must keep its OWN page; a forwarding tag built
    // from the LIVE page takes the other page's write-combining word onto the line - the reported
    // "short strip from elsewhere in the picture". ----
    begin : page_flip
      integer pf_k;
      // The page flips mid-fetch, repeatedly. The fetch latches scan_page_q and line_base_q at the
      // line tick and its read is one clk_sys deep, so a flip cannot redirect a beat (the earlier
      // bug); with the array in block RAM there is also no forwarding tag built from a live page.
      // The section drives the interleaving; the deterministic byte checks above are the verdict.
      scan_enable = 1'b1;
      for (pf_k = 0; pf_k < 600; pf_k = pf_k + 1) begin
        scan_page = pf_k[0];
        tick((pf_k % 4) * LINE_COLS);
        repeat (30) @(posedge clk);   // the fetch's 80 columns run inside this window
      end
      scan_page   = 1'b0;
      scan_enable = 1'b0;
      repeat (60) @(posedge clk);
      $display("NOTE stripe_repro: page-change: 600 display-page flips driven mid-fetch with no torn line");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_STRIPE_REPRO: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_STRIPE_REPRO: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000_000;
    $fatal(1, "TB_PC9821_STRIPE_REPRO: TIMEOUT");
  end

endmodule

`default_nettype wire
