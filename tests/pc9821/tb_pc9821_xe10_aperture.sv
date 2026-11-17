`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_XE10_APERTURE: with OSD I/O timing = Xe10, through pc9821_memory_subsystem, the open 0xF00000 PEGC aperture costs what the packed bank costs, as on the real Xe10 (XE10Y /CELLS /APER, docs/probes/XE10Y-XE10-RUN3-APER2.TXT: 0xF00000 is the packed bank 0, its loads LATENCY-shaped and its stores RATE-shaped at the packed bank's cost): at 24 kHz with the 256-colour display on, on a graphics line, an aperture read's response comes exactly as late as a packed-bank (0xA8000) read's, the PK_RD_24PA hold (761.4 ns, XE10X-XE10-RDLAT1.TXT:216) later than the same read in Fast, and aperture stores are spaced the packed store's period (PK_WR_24PA 182.8 ns, :223) as packed-bank stores are; the subsystem's display-mode column is 24P there (xe10_mode 3: a text RAM read on a graphics line costs TX_RD_1W_24PA's 759.0 ns, XE10Y-XE10-CELLS.TXT:31, against the 24 kHz column's 692.2 with the display off, and 31 kHz with it on stays the 48 column's 705.7); and in Fast the aperture and the packed bank answer as on the tree before the change, cycle for cycle.

// ---- where the expectation comes from ----
//   The machine: docs/probes/XE10Y-XE10-RUN3-APER2.TXT `X APER` (a word stored at 0xA8000 reads
//   at 0xF00000 and back) and its timed rows, the aperture load 731.2 ns net and the store 144.6
//   ns per word at 24 kHz with 256 colours (:40 `R CELLS PAR_2PA`, :32 `R CELLS PAW_2PA`), the
//   same costs as the packed bank (the same kit's CELLS PKR_2PA 759.0 / PKW_2PA 147.8). So the
//   aperture takes the packed bank's classes, whose values are the class table's
//   (tools/xe10_classes.csv, each row cited and re-derived by tools/check_xe10_table.py):
//     PK_RD_24PA 761.4 ns (RDLAT1 :216, the 24 column XE10X measured with the display on)
//     PK_WR_24PA 182.8 ns (RDLAT1 :223; the store's two states are todo item 199)
//     TX_RD_1W_24PA 759.0 (CELLS :31), TX_RD_1W_24A 692.2 (RDLAT1 :174), TX_RD_1W_48A 705.7 (:535)
//   converted to the nearest clk_sys at this bench's 100 MHz. THE CORE'S OWN SHARE: the pace
//   holds a packed read its class time less the core's 18-clk_sys unpaced read, and arms it one
//   cycle after it arrives (pc9821_pegc_xe10_pace), so an Xe10 read answers C - 18 cycles after
//   its Fast twin; the text responder holds C less 8 + 2 (pc9821_window_responder), so two text
//   reads differ by exactly the difference of their classes' cycles.
//   THE FAST PINS were measured on the tree before the change.
// FAIL-FIRST: before the change the aperture was unpaced in Xe10 (its read answered as in Fast,
// docs/probes/core/XE10Y-CORE-xt-3409ab24-s3-XE10-RUN3-APER2.TXT: PAR 228 ns, PAW 77) and the
// 24 kHz 256-colour state read the 24 kHz column (the text read 0 cycles apart).

`default_nettype none

module tb_pc9821_xe10_aperture;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg        bios_ram_gate = 0;
  reg [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  // 0x043B bit 2, the 15-16 MiB system-space window. ON is the machine's reset
  // value and the value qemu's pc98_mem_reset leaves (`s->sys16m = 1`).
  reg        sys16m_en = 1'b1;
  // ems_state: the 0x043F 0x2x EMS window state. This bench does not exercise EMS, so it is
  // tied to the identity/VRAM state; the port exists because pc9821_memory_subsystem consumes it.
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  reg  [1:0] ems_state = 2'd0;
  reg [31:0] pack_base = 32'h0200_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg        gvram_access_page = 0;

  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0;
  reg [7:0]  grcg_din = 0;
  wire       grcg_expand;   // the GRCG's CG-mode bit 7, fed back from the subsystem
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here


  // EGC off: this bench is about address translation, not the plane engines.
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

  wire [10:0] font_addr;
  wire [15:0] font_data;
  wire        font_we;

  reg        scan_enable = 0;

  reg        gvram_timing_xe10 = 0, gvram_gfx_scan_on = 0, gvram_crt31k = 0;   // OSD I/O timing Fast
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
  wire [7:0]  tram_dout;
  reg  [7:0]  tram [0:16383];
  assign tram_dout = tram[tram_addr];

  wire [4:0] cg_win_byte_sel;
  wire       cg_win_rd;
  reg  [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire       cg_win_we;

  reg [18:0] font_req_addr = 0;
  reg        font_req = 0;
  wire       font_word_valid;
  wire [31:0] font_word_data;

  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write;
  wire [3:0]  fmem_be;
  wire [7:0]  fmem_burstcount;
  reg         fmem_ready = 1, fmem_resp_valid = 0;
  reg  [31:0] fmem_dout = 32'd0;

  wire [31:0] mem_addr, mem_din;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  reg  [31:0] mem_dout = 32'd0;
  reg  [127:0] mem_line_dout = 128'd0;

  // The immediate backend stub: accept straight away, answer the next cycle.
  reg         mem_ready = 1, mem_resp_valid = 0, mem_line_resp_valid = 0;
  // The GVRAM scanout's SDRAM requester. The wildcard instantiation needs every port
  // named; nothing here drives the scanout, so it accepts and never answers.
  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1, mem3_resp_valid = 0;
  always @(posedge clk) begin
    if (reset) mem_resp_valid <= 1'b0;
    else       mem_resp_valid <= mem_valid && !mem_write;
  end

  // The GVRAM write client's two-word payload; this bench's backend ignores it.

  wire [31:0] mem_din_hi;

  // The graphics telemetry bus; this bench does not read it, but (.*) needs the name.
  wire [127:0] dbg_gfx_stats;
  wire dbg_walk_start, dbg_walk_cycle;   // the GVRAM's walk pulses, same reason
  wire dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;   // the EGC/GRCG operation pulses, same reason
  // The GRCG's and the EGC's per-cycle ownership pulses; this bench does not count
  // them, but (.*) needs every port named.
  wire dbg_gr_owned, dbg_eg_owned;
  // The page-coincidence probe's two page levels; this bench does not read them,
  // but (.*) needs every port named.
  wire dbg_access_page, dbg_scan_page_q;
  wire cg_win_byte_hold = 1'b0;
  // Tied off: the 200-line interleave's odd-line fetch-skip input (400-line traffic
  // here; tb_pc9821_interleave_200 drives it).
  wire gfx_odd_line = 1'b0;
  // ---- pc9821_memory_subsystem's DMA bus-master port, tied off (see the iobus block) ----
/* verilator lint_off UNUSEDSIGNAL */
  wire        dma_addr_unused = 1'b0;
  wire [31:0] dma_addr = 32'd0;
  wire [31:0] dma_snoop_addr;   // the DMA byte's post-map name, for the external snoop (unused here)
  wire [31:0] dma_addr_nx = 32'd0;   // the DMAC's address load (idle here)
  wire        dma_load    = 1'b0;
  wire        dma_load_write = 1'b0;   // the loading byte's direction (pc9821_dmac mem_load_we)
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

  // The PEGC view select (pc9821_crtc's mode2_256col): the 256-colour display, which also picks
  // the Xe10 table's display-mode column (pc9821_memory_subsystem's xe10_mode).
  reg        pegc_256 = 1'b0;
  // PEGC packed scanout's fourth-requester port,
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

  // The G3 gather session's qualifier/entries and the SDRAM geometry
  // (pc9821_memory_subsystem's ports; (.*) binds them by name).
  wire        mem_gath;
  wire [440:0] mem_gath_extra;
  wire  [1:0] sdram_size = 2'd2;
  // The plain-window client's ownership pulse (pc9821_memory_subsystem's dbg_pw_owned,
  // added 2026-10-03 so the page-coincidence counter covers plain stores too). `.*` needs a
  // matching net here; this bench does not read it.
  wire dbg_pw_owned;

  // 0x063C bank select into the 0xD8000 window: 0 = the IDE option ROM, the reset bank.

  reg  [1:0] d8_bank = 2'b00;
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;

  // ==== DUT ====
  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);

  integer errors = 0;

  // Set an address and the window state, then let the combinational decode
  // settle. `#1` is enough: every route select in the subsystem is a function of
  // cpu_addr and sys16m_en alone. A probe PRESENTS a request it never completes
  // (the checks read the decode after this returns), so each probe first drains
  // whatever the previous one left in a registered responder's FSM - two
  // responders mid-flight would trip the subsystem's one-request check.
  task automatic drain;
    begin
      cpu_valid = 1'b0; cpu_write = 1'b0;
      repeat (8) @(negedge clk);
    end
  endtask

  task automatic drive_addr(input [31:0] a, input en);
    begin
      drain;
      sys16m_en = en;
      cpu_addr  = a;
      cpu_write = 1'b0;
      cpu_line_read = 1'b0;
      cpu_be    = 4'hF;
      cpu_valid = 1'b1;
      #1;
    end
  endtask

  // The subsystem owns the backend until a pack word lands and rom_ready rises, so
  // cpu_run must be brought up the same way the subsystem's own bench does.
  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1;
      @(negedge clk); ioctl_wr = 0;
    end
  endtask

  // One CPU store: the PEGC register file's [0xE0102] write is the machine's own
  // aperture-enable flow (the ITF's phase-2 block does exactly this inside its
  // 0x6A 0x21 bracket).
  task automatic cpu_store(input [31:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      drain;
      @(negedge clk);
      cpu_addr = a; cpu_din = d; cpu_be = be; cpu_write = 1; cpu_line_read = 0;
      cpu_burstcount = 8'd1; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 40) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_XE10_APERTURE: no accept for write %08x", a);
      @(negedge clk); cpu_valid = 0; cpu_write = 0;
    end
  endtask


`define XE10_CYC(hz, x10) (((64'(hz) * 64'(x10)) + 64'd5_000_000_000) / 64'd10_000_000_000)
  localparam integer HZ = 100_000_000;
  localparam integer PK_CPU = 18;
  // THE FAST PINS (clk_sys from the presenting edge to the response; store accept spacing),
  // measured on the tree before the change.
  localparam integer F_APER_RD = 1, F_PK_RD = 1, F_APER_WS = 1, F_PK_WS = 1;

  integer checks = 0;
  task automatic check_eq(input [8*64-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("  FAIL %0s: %0d, want %0d", what, got, want);
        errors = errors + 1;
      end else $display("  ok   %0s = %0d", what, got);
    end
  endtask

  // One read: presented at a falling edge, counted in rising edges to the response strobe.
  task automatic rd_time(input [31:0] a, output integer t);
    reg acc;
    begin
      drain;
      @(negedge clk);
      cpu_addr = a; cpu_be = 4'b0011; cpu_write = 1'b0; cpu_line_read = 1'b0;
      cpu_burstcount = 8'd1; cpu_valid = 1'b1;
      t = 0; acc = 1'b0;
      while (1) begin
        @(posedge clk);
        t = t + 1;
        if (cpu_valid && cpu_ready) acc = 1'b1;
        #1;
        if (acc) cpu_valid = 1'b0;
        if (cpu_resp_valid || t > 4000) break;
      end
      if (t > 4000) $fatal(1, "TB_PC9821_XE10_APERTURE: no response for read %08x", a);
    end
  endtask

  // Eight back-to-back stores; the spacing of the last two accepts.
  task automatic wr_spacing(input [31:0] a, output integer sp);
    integer n, t, last, prev;
    begin
      drain;
      repeat (40) @(negedge clk);
      @(negedge clk);
      cpu_addr = a; cpu_din = 32'h1234_5678; cpu_be = 4'b0011; cpu_write = 1'b1;
      cpu_line_read = 1'b0; cpu_burstcount = 8'd1; cpu_valid = 1'b1;
      n = 0; t = 0; last = 0; prev = 0;
      while (n < 8 && t < 8000) begin
        @(posedge clk);
        t = t + 1;
        if (cpu_ready) begin
          prev = last; last = t; n = n + 1;
          #1 cpu_addr = cpu_addr + 32'd4;
        end
      end
      @(negedge clk); cpu_valid = 1'b0; cpu_write = 1'b0;
      sp = last - prev;
    end
  endtask

  integer ap_rd, pk_rd, ap_ws, pk_ws, fa_rd, fp_rd, fa_ws, fp_ws;
  integer tx_24p, tx_24, tx_48;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (4) @(posedge clk);
    if (!cpu_run) $fatal(1, "TB_PC9821_XE10_APERTURE: cpu_run never asserted");
    // 24 kHz with the 256-colour display on, packed mode, [0xE0102] = 1 (the aperture open),
    // the 15-16 MiB window on: the state the machine's APER2 rows ran in.
    sys16m_en = 1'b1;
    pegc_256 = 1'b1;
    cpu_store(32'h000E_0100, 32'h0001_0000, 4'b0100);
    gvram_crt31k = 1'b0;
    gvram_gfx_scan_on = 1'b1;

    // ==== CHECKS ====
    // Fast first: the pins
    gvram_timing_xe10 = 1'b0;
    rd_time(32'h00F0_0000, fa_rd);  rd_time(32'h000A_8000, fp_rd);
    wr_spacing(32'h00F0_1000, fa_ws); wr_spacing(32'h000A_9000, fp_ws);
    $display("  Fast: aperture read %0d, packed read %0d, aperture store spacing %0d, packed %0d",
             fa_rd, fp_rd, fa_ws, fp_ws);
    check_eq("Fast aperture read", fa_rd, F_APER_RD);
    check_eq("Fast packed-bank read", fp_rd, F_PK_RD);
    check_eq("Fast aperture store spacing", fa_ws, F_APER_WS);
    check_eq("Fast packed-bank store spacing", fp_ws, F_PK_WS);

    // Xe10, 24P, on a graphics line
    gvram_timing_xe10 = 1'b1;
    repeat (8) @(negedge clk);
    rd_time(32'h00F0_0000, ap_rd);  rd_time(32'h000A_8000, pk_rd);
    wr_spacing(32'h00F0_1000, ap_ws); wr_spacing(32'h000A_9000, pk_ws);
    check_eq("Xe10 aperture read = the packed-bank read", ap_rd, pk_rd);
    check_eq("Xe10 aperture read - Fast (PK_RD_24PA 761.4 ns hold)", ap_rd - fa_rd,
             int'(`XE10_CYC(HZ, 7614)) - PK_CPU);
    check_eq("Xe10 aperture store spacing (PK_WR_24PA 182.8 ns)", ap_ws, int'(`XE10_CYC(HZ, 1828)));
    check_eq("Xe10 packed-bank store spacing (PK_WR_24PA 182.8 ns)", pk_ws, int'(`XE10_CYC(HZ, 1828)));

    // The display-mode column: the text read on a graphics line, 24P against 24 and 48
    rd_time(32'h000A_0000, tx_24p);
    pegc_256 = 1'b0; repeat (8) @(negedge clk);
    rd_time(32'h000A_0000, tx_24);
    gvram_crt31k = 1'b1; pegc_256 = 1'b1; repeat (8) @(negedge clk);
    rd_time(32'h000A_0000, tx_48);
    gvram_crt31k = 1'b0;
    check_eq("text read 24P - 24 (759.0 vs 692.2 ns)", tx_24p - tx_24,
             int'(`XE10_CYC(HZ, 7590)) - int'(`XE10_CYC(HZ, 6922)));
    check_eq("text read 48 - 24 (705.7 vs 692.2 ns)", tx_48 - tx_24,
             int'(`XE10_CYC(HZ, 7057)) - int'(`XE10_CYC(HZ, 6922)));

    cpu_valid = 1'b0;
    $display("  %0d checks", checks);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_XE10_APERTURE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_XE10_APERTURE: FAIL (%0d errors)", errors);
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_XE10_APERTURE: FAIL (timed out)");
  end
endmodule

`default_nettype wire
