`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_REGS:
// The EGC's register file and its GRCG back-compat gate, checked against NP2kai: the eight registers 0x04A0-0x04AE (access, fgbg, ope, fg, mask, bg, sft, leng) are write-only with 0xFF read-back, hold egc_reset()'s power-up values, drop every write while the EGC enable is clear, hold the mask register while 0x04A2's bits 13-14 are set, and re-arm the shifter on 0x04AC/0x04AE; then the GRCG-compat dispatch, where with the EGC gate clear the 0x7C/0x7E tile registers still own a plane-window store and with it set the EGC engine owns it instead, and where NP2kai's real gate (the EGC mode AND the GRCG CG-mode bit 7) keeps a store whose GRCG bit 7 is clear on the plain back-compat path - ASSERTED through the bench's own model of that AND (egc_disp_gate = egc_gate && grcg_cg, the same post-AND gate pc9821_system's gdc_egc_mem_gate forms). Section C is FAIL-FIRST: a configuration write (0x4A6 fg) issued while an EGC op is still in flight must NOT change that op - the op uses the register image it was ACCEPTED with, exactly as NP2kai's atomic op does - and must still take effect on the NEXT op (latched at the accept, not dropped); it fails on the pre-change pc9821_egc, where the produce read the registers live and the in-flight op took the new fg.

module tb_pc9821_egc_regs;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;


  // ==== DUT ====
  // DUT 1: pc9821_iobus owns the EGC register latches.
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
  // The declaration block matches pc9821_iobus's port list so `(.*)` binds every
  // port; the unused ones are parked exactly as tb_pc9821_iobus parks them.
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0] cpu_be = 0;
  reg cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire cpu_ready, cpu_resp_valid;
  reg [7:0] debug_status = 8'hA5;
  wire device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire [7:0] device_io_din;
  reg [7:0] device_io_dout = 8'hC3;
  reg device_rd_wait = 1'b0;
  wire [3:0] top_bank;
  wire sound_extend;
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  wire ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
  wire top_shadow_en;
  wire fdc_irq;
  wire fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  wire a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0] post_code;
  wire post_write;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0] dbg_gate;
  wire [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire [7:0] dbg_last_io_data;
  wire dbg_last_io_rd, dbg_last_io_wr;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  reg cal_cdat = 0;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg triple_fault_reset = 1'b0;
  wire [1:0] ems_state;
  // The EGC gate pc9821_gdc_text exports (the mode latch). In the live core the MEMORY
  // dispatch needs the GRCG's CG-mode bit 7 as well (NP2kai VOPBIT_EGC && VOPBIT_GRCG),
  // which pc9821_system ANDs in from the GRCG's expand gate; `grcg_cg` tracks that bit
  // so this bench drives pc9821_gvram with the same post-AND gate the core forms. The
  // register file keeps the mode latch alone, so iobus still takes `egc_gate`.
  reg egc_gate = 1'b0;
  reg grcg_cg  = 1'b0;
  wire egc_disp_gate = egc_gate && grcg_cg;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire egc_shift_we;
  integer egc_shift_pulses = 0;

  reg device_rd_hold = 1'b0;
  reg device_wr_wait = 1'b0;   // write back-pressure: unused here (no device buffer is stressed), 0 = never stall
  // The 0x9A0 query state input (pc9821_iobus): driven at 0 here - only
  // tb_pc9821_readback_sysports exercises the query protocol.
  reg [10:0] gdc_ff2_state = 11'd0;
  // The bus mouse's IRQ13 line and hps_io's parsed mouse packet - the ports
  // pc9821_iobus carries for pc9821_mouse; not exercised by this bench.
  wire        mouse_irq;
  reg  [24:0] ps2_mouse = 25'd0;
  // ---- pc9821_iobus's Phase-1 port groups, tied off: this bench drives NO floppy ----
  // The wildcard instantiation connects every port by name, so the floppy media seam and
  // the uPD71071's bus-master port need a signal here even though nothing in this bench
  // uses them (tools/check_wiring.py requires exactly that). With `fdd_present` clear the
  // FDC never takes its media path, so the data path this seam feeds is unreachable.
/* verilator lint_off UNUSEDSIGNAL */
  wire [3:0]  fdd_present = 4'd0;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx, fdd_dout, fdd_hr, fdd_hn, fdd_hs;
  wire [7:0]  fdd_tc;   // pc9821_iobus's physical-track pair (pc9821_fdc media_tc/media_hd)
  wire        fdd_hd;
  wire        fdd_mf;
  wire        fdd_2hd;   // pc9821_iobus's media-mode pair (pc9821_fdc media_2hd/media_rpm)
  wire        fdd_rpm;
  wire        fdd_ready = 1'b1, fdd_rdy = 1'b0, fdd_hdrv = 1'b0, fdd_err = 1'b0;
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire [1:0]  dma_mem_gvwin;   // the DMAC's plane-window class (unused here)
  wire [3:0]  dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  wire        dma_mem_ready = 1'b0;
  wire [31:0] dma_mem_dout = 32'd0;
  wire        dma_mem_resp_valid = 1'b0;
/* verilator lint_on UNUSEDSIGNAL */
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here

  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) io (
      .ide_unit0_present(1'b0),.*);

  // DUT 2: pc9821_gvram owns the GRCG and the EGC datapath.
  // The GRCG's 0x7C/0x7E writes arrive on this device port exactly as
  // pc9821_system routes them (system.sv:597,654).
  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0, grcg_din = 0;
  reg        gv_access_page = 0;
  reg [1:0]  win_plane = 0;
  reg [14:0] win_offset = 0;
  reg [31:0] gv_din = 0;
  reg [3:0]  gv_be = 4'hF;
  reg        gv_valid = 0, gv_write = 0;
  wire [31:0] gv_dout;
  wire [127:0] gv_line_dout;
  wire gv_ready, gv_resp_valid, gv_line_resp_valid;

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) gv (
      .clk(clk), .reset(reset),
      .access_page(gv_access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(gv_din), .cpu_be(gv_be), .cpu_line_read(1'b0),
      .cpu_valid(gv_valid), .cpu_write(gv_write),
      .cpu_dout(gv_dout), .cpu_line_word(gv_line_dout),
      .cpu_ready(gv_ready), .cpu_resp_valid(gv_resp_valid),
      .cpu_line_word_valid(gv_line_resp_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_disp_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask), .egc_bg(egc_bg),
      .egc_sft(egc_sft), .egc_leng(egc_leng), .egc_shift_we(egc_shift_we),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0),
      .scan_line_base(15'd0), .line_rd_addr(7'd0), .line_rd_sel(1'b0),
      .line_data(), .line_sel(), .line_ready());

  // ==== STIMULUS ====
  // The hardware vectors generated from the Xe10 capture (docs/probes/egc-conformance).
  // Only the colour-gate rows are used here; tb_pc9821_egc_compare replays the rest.
  `include "egc_xe10_vectors.svh"

  integer errors = 0;

  task automatic fail(input [8*96-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  task automatic io_read(input [15:0] portnum, output [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0; cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1; data = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0; cpu_be = 0;
      while (io.state != 0) @(negedge clk);
    end
  endtask

  task automatic io_write_byte(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, data} << (lane * 8);
      cpu_write = 1; cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0; cpu_write = 0; cpu_be = 0;
      while (io.state != 0) @(negedge clk);
    end
  endtask

  // A 16-bit `out dx,ax`, the form every authentic EGC sequence uses.
  task automatic io_write_word(input [15:0] portnum, input [15:0] data);
    begin
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0011 << portnum[1:0];
      cpu_din = {16'd0, data} << (portnum[1:0] * 8);
      cpu_write = 1; cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0; cpu_write = 0; cpu_be = 0;
      while (io.state != 0) @(negedge clk);
    end
  endtask

  task automatic grcg_port(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); grcg_addr = a; grcg_din = d; grcg_we = 1;
      if (a == 8'h7C) grcg_cg = d[7];   // the CG-mode bit the EGC's dispatch needs
      @(negedge clk); grcg_we = 0;
    end
  endtask

  task automatic grcg_tiles(input [7:0] b, input [7:0] r, input [7:0] g, input [7:0] e);
    begin
      grcg_port(8'h7E, b); grcg_port(8'h7E, r);
      grcg_port(8'h7E, g); grcg_port(8'h7E, e);
    end
  endtask

  task automatic gv_store(input [1:0] plane, input [14:0] off,
                          input [31:0] din, input [3:0] be);
    begin
      @(negedge clk);
      win_plane = plane; win_offset = off; gv_din = din; gv_be = be;
      gv_write = 1; gv_valid = 1;
      while (!gv_ready) @(negedge clk);
      @(negedge clk);
      gv_valid = 0; gv_write = 0; gv_be = 4'hF;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic gv_load(input [1:0] plane, input [14:0] off, output [31:0] d);
    begin
      // 0x7C = 0 before every plane read-back: with the GRCG armed at 0x80 the SAME
      // plane-window read is NP2kai's memtcr tile-compare, not the plane byte.
      grcg_port(8'h7C, 8'h00);
      @(negedge clk);
      win_plane = plane; win_offset = off; gv_be = 4'hF;
      gv_write = 0; gv_valid = 1;
      while (!gv_ready) @(negedge clk);
      while (!gv_resp_valid) @(negedge clk);
      #1; d = gv_dout;
      @(negedge clk); gv_valid = 0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic gv_byte(input [1:0] p, input [14:0] c, output [7:0] v);
    reg [31:0] d;
    begin
      gv_load(p, {c[14:2], 2'b00}, d);
      v = d[{c[1:0], 3'b000} +: 8];
    end
  endtask

  task automatic expect_dword(input [1:0] plane, input [14:0] off,
                              input [31:0] want, input [8*48-1:0] what);
    reg [31:0] got;
    begin
      gv_load(plane, {off[14:2], 2'b00}, got);
      if (got !== want) begin
        $display("FAIL %0s: plane %0d off %04x got %08x want %08x",
                 what, plane, off[14:0], got, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_reset_regs(input [8*40-1:0] when);
    begin
      if (egc_access !== 16'hFFF0) begin
        $display("FAIL %0s: access reset %04x, want FFF0", when, egc_access);
        errors = errors + 1;
      end
      if (egc_fgbg !== 16'h00FF) begin
        $display("FAIL %0s: fgbg reset %04x, want 00FF", when, egc_fgbg);
        errors = errors + 1;
      end
      if (egc_ope !== 16'h0000) begin
        $display("FAIL %0s: ope reset %04x, want 0000", when, egc_ope);
        errors = errors + 1;
      end
      if (egc_fg !== 16'h0000) begin
        $display("FAIL %0s: fg reset %04x, want 0000", when, egc_fg);
        errors = errors + 1;
      end
      if (egc_mask !== 16'hFFFF) begin
        $display("FAIL %0s: mask reset %04x, want FFFF", when, egc_mask);
        errors = errors + 1;
      end
      if (egc_bg !== 16'h0000) begin
        $display("FAIL %0s: bg reset %04x, want 0000", when, egc_bg);
        errors = errors + 1;
      end
      if (egc_sft !== 16'h0000) begin
        $display("FAIL %0s: sft reset %04x, want 0000", when, egc_sft);
        errors = errors + 1;
      end
      if (egc_leng !== 16'h000F) begin
        $display("FAIL %0s: leng reset %04x, want 000F", when, egc_leng);
        errors = errors + 1;
      end
    end
  endtask

  always @(posedge clk) if (egc_shift_we) egc_shift_pulses = egc_shift_pulses + 1;

  // ==== CHECKS ====
  reg [7:0] value;

  initial begin
    repeat (4) @(posedge clk);
    reset = 0;
    repeat (4) @(posedge clk);

    // ---------------------------------------------------------------
    // A. The register file, against NP2kai io/egc.c.
    // ---------------------------------------------------------------

    // A0. Reset: NP2kai egc_reset() (mem/memegc.c:69-80) leaves access=FGBG's
    //     own latches at 0xFFF0/0x00FF, mask=0xFFFF, leng=0x000F and the rest 0.
    expect_reset_regs("power-up");

    // A1. Read-back: NP2kai attaches out handlers only (io/egc.c:101-107), so
    //     every one of the sixteen ports is open bus 0xFF.
    for (integer p = 0; p < 16; p = p + 1) begin
      io_read(16'h04A0 + p, value);
      if (value !== 8'hFF) begin
        $display("FAIL read-back 0x%04x = %02x, want FF", 16'h04A0 + p, value);
        errors = errors + 1;
      end
    end

    // A2. The write gate: NP2kai checks `vramop.operate & (1<<VOPBIT_EGC)` at
    //     the head of egc_o4a0 (io/egc.c:24) and egc_w16 (:142), so with the
    //     gate clear every write is dropped and the reset image survives.
    egc_gate = 1'b0;
    @(negedge clk);
    io_write_word(16'h04A0, 16'h1234);
    io_write_word(16'h04A2, 16'h5678);
    io_write_word(16'h04A4, 16'h9ABC);
    io_write_word(16'h04A6, 16'hDEF0);
    io_write_word(16'h04A8, 16'hABCD);
    io_write_word(16'h04AA, 16'h0F0F);
    io_write_word(16'h04AC, 16'h1357);
    io_write_word(16'h04AE, 16'h2468);
    expect_reset_regs("gate clear");

    // A3. With the gate set the 16-bit form latches both halves, low byte at
    //     the even port (NP2kai cases 0x00..0x0f). The two COLOUR registers are named as the
    //     hardware gate requires (0x4A6 under 0x4A2 = FG, 0x4AA under 0x4A2 = BG; see D), because
    //     while 0x4A2's bits 13-14 are clear an 0x4A6/0x4AA write is dropped.
    egc_gate = 1'b1;
    @(negedge clk);
    io_write_word(16'h04A0, 16'h1234);
    io_write_word(16'h04A2, 16'h00FF);
    io_write_word(16'h04A4, 16'h9ABC);
    io_write_word(16'h04A8, 16'hABCD);
    if (egc_fgbg !== 16'h00FF) begin
      $display("FAIL fgbg latched %04x, want 00FF", egc_fgbg); errors = errors + 1;
    end
    io_write_word(16'h04A2, 16'h40FF);   // FG selected: 0x4A6 is writable
    io_write_word(16'h04A6, 16'hDEF0);
    io_write_word(16'h04A2, 16'h20FF);   // BG selected: 0x4AA is writable
    io_write_word(16'h04AA, 16'h0F0F);
    io_write_word(16'h04A2, 16'h00FF);
    io_write_word(16'h04AC, 16'h1357);
    io_write_word(16'h04AE, 16'h2468);
    if (egc_access !== 16'h1234) begin
      $display("FAIL access latched %04x, want 1234", egc_access); errors = errors + 1;
    end
    if (egc_fgbg !== 16'h00FF) begin
      $display("FAIL fgbg latched %04x, want 00FF", egc_fgbg); errors = errors + 1;
    end
    if (egc_ope !== 16'h9ABC) begin
      $display("FAIL ope latched %04x, want 9ABC", egc_ope); errors = errors + 1;
    end
    if (egc_fg !== 16'hDEF0) begin
      $display("FAIL fg latched %04x, want DEF0", egc_fg); errors = errors + 1;
    end
    if (egc_mask !== 16'hABCD) begin
      $display("FAIL mask latched %04x, want ABCD", egc_mask); errors = errors + 1;
    end
    if (egc_bg !== 16'h0F0F) begin
      $display("FAIL bg latched %04x, want 0F0F", egc_bg); errors = errors + 1;
    end
    if (egc_sft !== 16'h1357) begin
      $display("FAIL sft latched %04x, want 1357", egc_sft); errors = errors + 1;
    end
    if (egc_leng !== 16'h2468) begin
      $display("FAIL leng latched %04x, want 2468", egc_leng); errors = errors + 1;
    end

    // A4. Byte form: the even port is the low byte, the odd port the high
    //     (NP2kai cases 0x00/0x01). A word is not required to hit both.
    io_write_byte(16'h04A0, 8'h5A);
    io_write_byte(16'h04A1, 8'hA5);
    if (egc_access !== 16'hA55A) begin
      $display("FAIL byte access latched %04x, want A55A", egc_access); errors = errors + 1;
    end

    // A5. The mask register is gated AGAIN by 0x4A2's foreground/background
    //     colour field: while bits 13 or 14 are set it is not writable
    //     (NP2kai case 0x08/0x09, `!(egc.fgbg & 0x6000)`).
    io_write_word(16'h04A2, 16'h0000);
    io_write_word(16'h04A8, 16'h1111);
    if (egc_mask !== 16'h1111) begin
      $display("FAIL mask latched %04x with fgbg field clear, want 1111", egc_mask);
      errors = errors + 1;
    end
    io_write_word(16'h04A2, 16'h2000);   // bit 13 set: colour quad selected
    io_write_word(16'h04A8, 16'h2222);
    if (egc_mask !== 16'h1111) begin
      $display("FAIL mask latched %04x with fgbg bit 13 set, want 1111", egc_mask);
      errors = errors + 1;
    end
    io_write_word(16'h04A2, 16'h4000);   // bit 14 set
    io_write_word(16'h04A8, 16'h3333);
    if (egc_mask !== 16'h1111) begin
      $display("FAIL mask latched %04x with fgbg bit 14 set, want 1111", egc_mask);
      errors = errors + 1;
    end
    io_write_word(16'h04A2, 16'h0000);
    io_write_word(16'h04A8, 16'h4444);
    if (egc_mask !== 16'h4444) begin
      $display("FAIL mask latched %04x after fgbg cleared, want 4444", egc_mask);
      errors = errors + 1;
    end
    if (egc_fgbg !== 16'h0000) begin
      $display("FAIL fgbg latched %04x, want 0000", egc_fgbg); errors = errors + 1;
    end

    // A6. The shifter re-arm: NP2kai's cases 0x0c..0x0f each run egcshift()
    //     (io/egc.c:91-113), so a word write hits two byte lanes and pulses
    //     twice. Nothing else in the file has a side effect.
    egc_shift_pulses = 0;
    io_write_word(16'h04AC, 16'h0300);
    io_write_word(16'h04AE, 16'h027F);
    if (egc_sft !== 16'h0300 || egc_leng !== 16'h027F) begin
      $display("FAIL sft/leng latched %04x/%04x, want 0300/027F", egc_sft, egc_leng);
      errors = errors + 1;
    end
    if (egc_shift_pulses != 4) begin
      $display("FAIL shifter re-arm pulsed %0d, want 4 (two word writes)", egc_shift_pulses);
      errors = errors + 1;
    end

    // A7. A gate-clear write drops without disturbing what is latched.
    egc_gate = 1'b0;
    @(negedge clk);
    io_write_word(16'h04A0, 16'h0000);   // access was last written by A4 -> 0xA55A
    if (egc_access !== 16'hA55A) begin
      $display("FAIL access moved while the gate was clear: %04x", egc_access);
      errors = errors + 1;
    end

    // ---------------------------------------------------------------
    // B. The GRCG back-compat dispatch.
    //    The gate is wired as the live core wires it (system.sv:336,1074:
    //    gdc_egc_gate = gfx_egc_gate = mode2_egc).
    // ---------------------------------------------------------------

    // B1. Plain store: GRCG mode bit 7 clear, one plane takes the CPU data.
    grcg_port(8'h7C, 8'h00);
    gv_store(2'd0, 15'h0100, 32'h1122_3344, 4'hF);
    expect_dword(2'd0, 15'h0100, 32'h1122_3344, "plain store B");
    expect_dword(2'd1, 15'h0100, 32'h0000_0000, "plain store B leaves R");
    expect_dword(2'd2, 15'h0100, 32'h0000_0000, "plain store B leaves G");
    expect_dword(2'd3, 15'h0100, 32'h0000_0000, "plain store B leaves E");

    // B2. GRCG TDW: bit 7 set, the tile registers own all four planes and the
    //     CPU data is ignored (NP2kai mem/memvram.c memtdw0_wr8 = TDWWR8).
    grcg_tiles(8'h11, 8'h22, 8'h33, 8'h44);
    grcg_port(8'h7C, 8'h80);
    gv_store(2'd0, 15'h0200, 32'hCAFE_F00D, 4'hF);
    expect_dword(2'd0, 15'h0200, 32'h1111_1111, "GRCG TDW tile B");
    expect_dword(2'd1, 15'h0200, 32'h2222_2222, "GRCG TDW tile R");
    expect_dword(2'd2, 15'h0200, 32'h3333_3333, "GRCG TDW tile G");
    expect_dword(2'd3, 15'h0200, 32'h4444_4444, "GRCG TDW tile E");

    // B3. The GRCG needs bit 7: with it clear the store is plain even though
    //     the tile registers hold values (NP2kai's operate GRCG bits are
    //     0x7C bits 7:6, so 0x7C <- 0x40 engages nothing).
    grcg_port(8'h7C, 8'h00);
    gv_store(2'd0, 15'h0300, 32'h5566_7788, 4'hF);
    expect_dword(2'd0, 15'h0300, 32'h5566_7788, "bit7-clear store is plain");
    expect_dword(2'd1, 15'h0300, 32'h0000_0000, "bit7-clear store leaves R");

    grcg_port(8'h7C, 8'h40);   // bit 6 alone
    gv_store(2'd0, 15'h0500, 32'h99AA_BBCC, 4'hF);
    expect_dword(2'd0, 15'h0500, 32'h99AA_BBCC, "bit6-only store is plain");
    expect_dword(2'd1, 15'h0500, 32'h0000_0000, "bit6-only store leaves R");

    // B4. EGC owns: gate set AND GRCG bit 7 set. Program the BIOS's own
    //     0x1400 colour fill (BANK7.BIN@0x35A1) through the iobus so the
    //     register file drives the engine, and check the EGC's signature
    //     (fg quad colour 9 = planes 0 and 3) rather than the GRCG tiles.
    egc_gate = 1'b1;
    @(negedge clk);
    io_write_word(16'h04A0, 16'hFFF0);   // all four planes enabled
    io_write_word(16'h04A2, 16'h00FF);   // mask register writable...
    io_write_word(16'h04A8, 16'hFFFF);   // ...so the fill's mask is all-ones
    io_write_word(16'h04A2, 16'h40FF);   // foreground-colour quad (mask now held)
    io_write_word(16'h04A4, 16'h1400);   // WS_PATREG | SHIFT_CPU
    io_write_word(16'h04A6, 16'h0009);   // colour 9: planes 0 and 3
    io_write_word(16'h04AC, 16'h0000);
    io_write_word(16'h04AE, 16'h027F);
    grcg_tiles(8'h11, 8'h22, 8'h33, 8'h44);
    grcg_port(8'h7C, 8'h80);
    gv_store(2'd0, 15'h0600, 32'h0000_0000, 4'hF);
    egc_gate = 1'b0;
    @(negedge clk);
    expect_dword(2'd0, 15'h0600, 32'hFFFF_FFFF, "EGC fill plane B");
    expect_dword(2'd1, 15'h0600, 32'h0000_0000, "EGC fill plane R");
    expect_dword(2'd2, 15'h0600, 32'h0000_0000, "EGC fill plane G");
    expect_dword(2'd3, 15'h0600, 32'hFFFF_FFFF, "EGC fill plane E");

    // B5. NP2kai's real gate is the EGC mode AND the GRCG's CG-mode bit 7:
    //     VOPBIT_EGC alone selects vacctbl index 2 for func=0x02, which is
    //     memvram0, i.e. a PLAIN store (NP2kai i386c/cpumem.c:287-295,
    //     mem/memvram.c memvram0_wr8 = VRAMWR8). So with the EGC mode set but
    //     0x7C bit 7 clear the machine stays on the back-compat path: the core
    //     now ANDs the GRCG bit into the gate (pc9821_system's
    //     gdc_egc_mem_gate), and this bench drives gvram with that same post-AND
    //     gate, so the store must be plain.
    egc_gate = 1'b1;
    grcg_port(8'h7C, 8'h00);
    @(negedge clk);
    gv_store(2'd0, 15'h0700, 32'hAABB_CCDD, 4'hF);
    egc_gate = 1'b0;
    @(negedge clk);
    begin
      reg [31:0] b_plane, e_plane;
      gv_load(2'd0, 15'h0700, b_plane);
      gv_load(2'd3, 15'h0700, e_plane);
      if (b_plane !== 32'hAABB_CCDD || e_plane !== 32'h0000_0000)
        fail("EGC mode set / GRCG bit 7 clear: NP2kai stays PLAIN (plane B = AABBCCDD, plane E = 0)");
    end

    // ---------------------------------------------------------------
    // C. A configuration write during an in-flight op does NOT change that op.
    //    The core releases the CPU at the accept (a WRITE's cpu_ready pulses in S_FEED), so the
    //    guest can execute `out 0x4A0..0x4AE` while the produce is still running. NP2kai's EGC
    //    op is one atomic memory access (memegc_wr* completes inside the CPU's access handler),
    //    so the op must use the register image it was ACCEPTED with and a later write belongs to
    //    the NEXT op. Pre-fix the produce read the registers LIVE, so the mid-op write changed
    //    the op in flight; the eight registers are now latched at the S_IDLE accept. The control
    //    arm runs a second store AFTER the first and asserts the mid-op write DID take effect
    //    there, so the fix latches/defer - it does not drop the write.
    // ---------------------------------------------------------------
    begin : check_mid_op_register
      reg [7:0] b0, b1;
      // Clear the two destination dwords on all four planes (plain path: gate clear).
      egc_gate = 1'b0;
      grcg_port(8'h7C, 8'h00);
      for (integer pl = 0; pl < 4; pl = pl + 1) begin
        gv_store(pl[1:0], 15'h0900, 32'h0000_0000, 4'hF);
        gv_store(pl[1:0], 15'h0A00, 32'h0000_0000, 4'hF);
      end
      // Program a pattern-quad fill: all planes enabled, fgbg selects the fg colour quad, a
      // partial mask forces a destination fetch (a longer op), ope = WS_PATREG.
      egc_gate = 1'b1;
      @(negedge clk);
      io_write_word(16'h04A0, 16'hFFF0);   // all four planes enabled
      io_write_word(16'h04A2, 16'h00FF);   // mask register writable (fgbg field clear)
      io_write_word(16'h04A8, 16'h0F0F);   // partial mask -> a destination fetch
      io_write_word(16'h04A2, 16'h4000);   // fgbg = fg colour quad (mask now held)
      io_write_word(16'h04A6, 16'h0001);   // fg = colour 1 -> plane 0 only (ACCEPT-time value)
      io_write_word(16'h04A4, 16'h1000);   // WS_PATREG
      grcg_port(8'h7C, 8'h80);             // the EGC owns the store (gate AND GRCG bit 7)
      // Store, then change fg while the produce is in flight.
      gv_store(2'd0, 15'h0900, 32'hFFFF_FFFF, 4'hF);
      io_write_word(16'h04A6, 16'h0002);   // fg = colour 2 -> plane 1, written MID-OP
      while (gv.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(posedge clk);
      repeat (4) @(posedge clk);
      egc_gate = 1'b0;
      @(negedge clk);
      gv_byte(2'd0, 15'h0900, b0);
      gv_byte(2'd1, 15'h0900, b1);
      if (b0 !== 8'h0F || b1 !== 8'h00) begin
        $display("FAIL mid-op 0x4A6 write changed the op in flight: plane0/plane1 at 0x0900 = %02x/%02x, want 0F/00", b0, b1);
        errors = errors + 1;
      end else
        $display("  mid-op register change: the op used the ACCEPT-time image (plane0=%02x, plane1=%02x)", b0, b1);
      // The write is not lost: the NEXT store (accepted after it) uses fg = colour 2.
      egc_gate = 1'b1;
      grcg_port(8'h7C, 8'h80);
      gv_store(2'd0, 15'h0A00, 32'hFFFF_FFFF, 4'hF);
      while (gv.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(posedge clk);
      repeat (4) @(posedge clk);
      egc_gate = 1'b0;
      grcg_port(8'h7C, 8'h00);
      @(negedge clk);
      gv_byte(2'd0, 15'h0A00, b0);
      gv_byte(2'd1, 15'h0A00, b1);
      if (b1 !== 8'h0F || b0 !== 8'h00) begin
        $display("FAIL the mid-op 0x4A6 write was LOST: the next op's plane0/plane1 = %02x/%02x, want 00/0F", b0, b1);
        errors = errors + 1;
      end else
        $display("  mid-op register change: the write reached the NEXT op (plane0=%02x, plane1=%02x)", b0, b1);
    end

    // ==== D. THE COLOUR-REGISTER WRITE GATE (EGCWRITE.CSV W00_FG_x / W01_BG_x) ====
    // The suite's W00/W01 rows: 0x4A6 (FG) and 0x4AA (BG) take a write only while 0x4A2's
    // bits 13-14 name FG or BG; written with the pattern coming from PAT (00) they are
    // DROPPED and the retained colour survives. The measurement is the row's own: select the
    // colour, store the pattern quad (WS_PATREG, 0x1000) into a clean destination, and read the
    // four planes back - the expected quad is the Xe10's own aB..aI column. The value the
    // dropped write carries is the PRE-FIX core's own answer in the same capture (the
    // complement of the retained colour), so this is FAIL-FIRST rather than a vacuous pass.
    begin : colour_gate
      integer gi, gp;
      reg [31:0] gd;
      reg [7:0]  gb;
      for (gi = 0; gi < EGCW_NV; gi = gi + 1) begin
        egc_gate = 1'b1;
        @(negedge clk);
        // 0x4A8 first: it is writable only while 0x4A2's colour field is clear, and the write
        // mask rides the store.
        io_write_word(16'h04A2, 16'h0000);
        io_write_word(16'h04A8, 16'hFFFF);
        io_write_word(16'h04A0, 16'hFFF0);
        io_write_word(16'h04A4, 16'h1000);
        // Re-arm the shifter: a WS_PATREG store's write mask is mask2 & srcmask, and the sections
        // before this one left a moved shift behind whose srcmask would mask the store out.
        io_write_word(16'h04AC, 16'h0000);
        io_write_word(16'h04AE, 16'h000F);
        // Name the colour for the store, then take the pattern source away to PAT: in that
        // window both colour writes must be DROPPED and the retained colour must survive.
        io_write_word(16'h04A2, {EGCW_SEL[gi], 8'h00});
        io_write_word(16'h04A6, {12'h000, EGCW_COL[gi]});
        io_write_word(16'h04AA, {12'h000, EGCW_COL[gi]});
        io_write_word(16'h04A2, 16'h0000);
        io_write_word(16'h04A6, {12'h000, EGCW_IGNORED[gi]});
        io_write_word(16'h04AA, {12'h000, EGCW_IGNORED[gi]});
        // Select the colour again and store its quad: the written data quad IS the pattern.
        io_write_word(16'h04A2, {EGCW_SEL[gi], 8'h00});
        for (gp = 0; gp < 4; gp = gp + 1)
          gv_store(gp[1:0], 15'h0700, 32'h0000_0000, 4'hF);
        grcg_port(8'h7C, 8'h80);
        gv_store(2'd0, 15'h0700, 32'h0000_0000, 4'hF);
        repeat (16) @(posedge clk);
        grcg_port(8'h7C, 8'h00);
        for (gp = 0; gp < 4; gp = gp + 1) begin
          gv_load(gp[1:0], 15'h0700, gd);
          if (gd[15:0] !== EGCW_EXP[4*gi + gp]) begin
            $display("FAIL colour gate %0s plane %0d = %04x, want %04x (the ignored write took)",
                     EGCW_ID[gi], gp, gd[15:0], EGCW_EXP[4*gi + gp]);
            errors = errors + 1;
          end
        end
        egc_gate = 1'b0;
        grcg_port(8'h7C, 8'h00);
        @(negedge clk);
      end
      $display("NOTE egc_regs: section D colour-register write gate - %0d hardware rows", EGCW_NV);
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_EGC_REGS: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_EGC_REGS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog.
  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_EGC_REGS: TIMEOUT");
  end

endmodule
