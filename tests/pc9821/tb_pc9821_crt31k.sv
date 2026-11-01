`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Port 0x09A8 bit 0 switches the raster to the PC-9821's separate 31 kHz dot clock, and the guest sees the Xe10's own rates both ways: with clk_sys at 80 MHz, the real pc9821_iobus (0x09A8's latch, written and read through its CPU port), pc9821_dot_ce and pc9821_crtc wired as pc9821_system wires them, and the master GDC programmed with the exact sequence tools/hwprobe/crt31k sends (HSB.EXE IGDC:31's: RESET, VSYNC master, SYNC 10 4E 47 0C 07 0D 90 89, PITCH, ZOOM, SCROLL), the VSYNC status bit (the probe's own method) rises at 70.0669 Hz and the hsync at 31.460 kHz - the capture's frame and line rates, docs/probes/CRT31K.TXT `RUN frames=70 ticks=306930` with the ARTIC calibrated by the same file's 24 kHz rows, within 3 ppm - with 0x09A8 reading back 01; writing 0x09A8 = 00 and the BIOS 24 kHz SYNC table brings back the capture's 24 kHz rows (56.42 Hz, 24.82 kHz, the `24K (restored)` row within 3 ppm) and 0x09A8 reads 00; and the monitor range follows the bit: an 784-dot line (x = 98 characters) runs unclamped while 0x09A8 bit 0 is set and is clamped to 800 dots while it is clear (NP2kai io/gdc.c gdcclk[2] minx 92 against gdcclk[1] minx 100) and the BIOS 640 x 480 block (NP2kai bios/bios18.c gdcmastersync[3]) runs VGA's 800 x 525 at the same clock (59.92 Hz). FAIL-FIRST: before the 31 kHz dot clock 0x09A8 is a read-back latch only, so the 31 kHz block runs at the 21.05 MHz dot clock (58.61 Hz, 26.32 kHz) and the 784-dot line is clamped to 800 in both states.
//
// THE EXPECTED VALUES ARE THE CAPTURE'S (AGENTS.md "Evidence"), recomputed here from its raw rows the
// way tools/hwprobe/crt31k/crt31k_decode.py does: frame Hz = 307200 x frames / ticks, dot Hz = frame Hz
// x 449 x 800 (31 kHz) or x 440 x 848 (24 kHz), and the ARTIC calibrated by the 24 kHz `as found` rows
// against the 21 052 600 Hz nominal. The 3 ppm band is the capture's own resolution (one ARTIC tick in
// ~307 000); the model's 31 kHz clock is -0.94 ppm from it (pc9821_vclk_pkg).
//
// WHAT IT IS BLIND TO: the analog output and the video PLL (tb_pc9821_crt31k_video), the slave GDC
// (the probe does not touch it), and pc9821_system's own wiring of these three modules (the bench wires
// them as it does: iobus crt31k -> dot_ce c31 and crtc crt31k; tools/check_port_lists.py and the boot
// tier cover the instance).

module tb_pc9821_crt31k;
  localparam integer SYS_HZ = 80_000_000;
  // ---- the capture (docs/probes/CRT31K.TXT) ----
  localparam real ARTIC_HZ = 307200.0;
  localparam real NOMINAL_24K_DOT = 21_052_600.0;   // the decoder's calibration (NP2kai io/gdc.c `21052600 / 8`)
  // `RUN frames=60 ticks=326700/326700/326698` (24K as found, 848 x 440)
  localparam real CAP_24K_TICKS_MEAN = (326700.0 + 326700.0 + 326698.0) / 3.0;
  // `RUN frames=70 ticks=306930` x3 (31K, 800 x 449)
  localparam real CAP_31K_TICKS = 306930.0;
  // `RUN frames=60 ticks=326699` (24K restored)
  localparam real CAP_24KR_TICKS = 326699.0;

  // ---- clk_sys at exactly 80 MHz (a 12.5 ns period is whole ps, so the rate has no drift) ----
  reg clk = 1'b0;
  always #6.25 clk = ~clk;

  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)


  reg reset = 1;
  reg triple_fault_reset = 0;
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0]  cpu_be = 0;
  reg        cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  reg [7:0]  debug_status = 8'hA5;
  reg        cal_cdat = 0;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire [7:0] device_io_dout;      // the crtc's port (the master GDC), below
  reg        device_rd_wait = 1'b0;
  reg        egc_gate = 1'b0;
  // The 0x9A0 query state pc9821_crtc exports in the real design; driven by
  // hand here so the PROTOCOL (index latch + table + the clock-bit OR) is
  // pinned against NP2kai's gdc_i9a0 table bit for bit.
  reg [10:0] gdc_ff2_state = 11'd0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  wire  [3:0] top_bank;
  wire        sound_extend;
  wire  [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
  wire        ide_rom_enable, bios_ram_gate, a20_enable, cpu_reset_req;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire  [7:0] post_code;
  wire        post_write;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg, egc_sft, egc_leng;
  wire        egc_shift_we;
  wire  [3:0] dbg_gate;
  wire  [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;

  wire [1:0] ems_state;
  wire top_shadow_en;
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  reg device_rd_hold = 1'b0;
  reg device_wr_wait = 1'b0;
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
  // ==== DUT ====
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here
  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode), and the
  // wildcard instantiation needs a signal for each. This bench drives no device select of its
  // own - the GDC below is decoded locally - so they are named here and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;

  pc9821_iobus #(.SYS_CLOCK_HZ(SYS_HZ)) dut (
      .ide_unit0_present(1'b0),.*);


  // ---- the master GDC: pc9821_crtc on the device bus, decoded as pc9821_system's gdc_cs does for
  // its even ports 0x60-0x6E (the only ones this bench drives) ----
  wire       gdc_sel = (device_io_addr[15:8] == 8'h00) && (device_io_addr[7:4] == 4'h6) && !device_io_addr[0];
  wire [7:0] crtc_dout;
  assign device_io_dout = crtc_dout;
  wire       pixel_ce;
  wire       hs_out, vs_out, de_out, stat_vsync;
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_dot_ce #(.SYS_FREQ(SYS_HZ)) dot_ce (.clk(clk), .reset(reset), .c31(crt31k), .ce(pixel_ce));
  pc9821_crtc crtc (
      .clk_sys(clk), .rst_n_sys(!reset), .rst_n_vid(!reset), .pixel_ce(pixel_ce),
      .crt31k(crt31k), .gfx_win_on(1'b0),
      .io_wr(device_io_wr && gdc_sel), .io_rd(device_io_rd && gdc_sel),
      .io_addr(device_io_addr[7:0]), .io_din(device_io_din), .io_dout(crtc_dout),
      .tram_cpu_addr(14'd0), .tram_cpu_din(8'h00), .tram_cpu_we(1'b0),
      .wk_tr_read(1'b0), .wk_tr_addr(14'd0),
      .ank_word(16'h0000), .jc_rd_q(32'd0), .cg_ram_vid_q(8'h00),
      .vsync_irq_arm(1'b0), .o_stat_vsync(stat_vsync),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  integer errors = 0;

  // A bound: the run ends at ~0.5 s of simulated time.
  initial begin
    #(2_000_000_000);
    $fatal(1, "TB_PC9821_CRT31K: watchdog (2 s simulated)");
  end

  // ==== CHECKS ====
  task automatic wr(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, data} << (lane * 8);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic rd1(input [15:0] portnum, output [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1;
      data = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // The probe's gdc_master_program: each command to 0x62, its parameters to 0x60.
  task automatic gdc_cmd(input [7:0] cmd);
    wr(16'h0062, cmd);
  endtask
  task automatic gdc_par(input [7:0] p);
    wr(16'h0060, p);
  endtask
  task automatic master_program(input [63:0] sync);   // sync = the eight SYNC bytes, first in [63:56]
    integer i;
    begin
      gdc_cmd(8'h00);                                 // RESET
      gdc_cmd(8'h6F);                                 // VSYNC master
      gdc_cmd(8'h0F);                                 // SYNC (display enabled)
      for (i = 7; i >= 0; i = i - 1) gdc_par(sync[i*8 +: 8]);
      gdc_cmd(8'h47); gdc_par(8'h50);                 // PITCH 80
      gdc_cmd(8'h46); gdc_par(8'h00);                 // ZOOM 0
      gdc_cmd(8'h70); gdc_par(8'h00); gdc_par(8'h00); gdc_par(8'hF0); gdc_par(8'h3F);   // SCROLL
    end
  endtask

  // Time NFR frames by the VSYNC status bit's rising edges (the probe's wait_vsync_rise), after
  // SKIP edges for the new block to land at a frame boundary; and the hsync period over the same
  // window (negative polarity: a falling edge starts the pulse).
  real    t_first, t_last, h_first, h_last;
  integer n_hs;
  reg     sv_d = 1'b0, hs_d = 1'b1;
  reg     counting = 1'b0;
  always @(posedge clk) begin
    sv_d <= stat_vsync;
    hs_d <= hs_out;
    if (counting && hs_d && !hs_out) begin
      if (n_hs == 0) h_first = $realtime;
      h_last = $realtime;
      n_hs = n_hs + 1;
    end
  end
  task automatic vsync_rise;
    begin
      @(posedge clk);
      while (!(stat_vsync && !sv_d)) @(posedge clk);
    end
  endtask
  task automatic measure(input integer skip, input integer nfr, output real frame_hz, output real line_hz);
    integer i;
    begin
      for (i = 0; i < skip; i = i + 1) vsync_rise();
      t_first = $realtime;
      n_hs = 0;
      counting = 1'b1;
      for (i = 0; i < nfr; i = i + 1) vsync_rise();
      counting = 1'b0;
      t_last = $realtime;
      frame_hz = real'(nfr) * 1.0e9 / (t_last - t_first);
      line_hz  = real'(n_hs - 1) * 1.0e9 / (h_last - h_first);
    end
  endtask

  task automatic within_ppm(input real got, input real want, input real ppm, input string what);
    real d;
    begin
      d = (got - want) / want * 1.0e6;
      if (d > ppm || d < -ppm) begin
        $display("FAIL: %0s: %.4f, the capture's %.4f (%.2f ppm, want within %.0f)", what, got, want, d, ppm);
        errors = errors + 1;
      end else
        $display("  ok   %0s: %.4f (capture %.4f, %.2f ppm)", what, got, want, d);
    end
  endtask

  task automatic expect_line_dots(input real line_hz, input real dot_hz, input integer dots, input string what);
    real got;
    begin
      got = dot_hz / line_hz;
      if (got < real'(dots) - 0.05 || got > real'(dots) + 0.05) begin
        $display("FAIL: %0s: the line is %.3f dots, want %0d", what, got, dots);
        errors = errors + 1;
      end else
        $display("  ok   %0s: %.3f dots a line", what, got);
    end
  endtask

  real cal, f24_cap, f31_cap, f24r_cap, d31_cap, d24_cap;
  real fr, ln;
  reg [7:0] b;
  initial begin
    // The capture's numbers, as crt31k_decode.py derives them.
    cal      = NOMINAL_24K_DOT / (ARTIC_HZ * 60.0 / CAP_24K_TICKS_MEAN * 440.0 * 848.0);
    f24_cap  = ARTIC_HZ * 60.0 / CAP_24K_TICKS_MEAN * cal;
    f31_cap  = ARTIC_HZ * 70.0 / CAP_31K_TICKS * cal;
    f24r_cap = ARTIC_HZ * 60.0 / CAP_24KR_TICKS * cal;
    d31_cap  = f31_cap * 449.0 * 800.0;
    d24_cap  = f24_cap * 440.0 * 848.0;
    $display("  capture (calibrated, ARTIC x %.7f): 24K %.4f Hz, 31K %.4f Hz = %.0f Hz dot, 24K restored %.4f Hz",
             cal, f24_cap, f31_cap, d31_cap, f24r_cap);

    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- as found: 24 kHz, the power-up block (the BIOS 24 kHz table) ----
    rd1(16'h09A8, b);
    if (b !== 8'h00) begin $display("FAIL: 0x09A8 as found reads %02x, want 00 (CRT31K.TXT `09A8 found=00`)", b); errors++; end
    measure(2, 4, fr, ln);
    within_ppm(fr, f24_cap, 3.0, "24K as found: frame Hz");
    within_ppm(ln, f24_cap * 440.0, 3.0, "24K as found: line Hz");

    // ---- 0x09A8 |= 1, then the 31 kHz master table (the probe's order) ----
    rd1(16'h09A8, b);
    wr(16'h09A8, b | 8'h01);
    rd1(16'h09A8, b);
    if (b !== 8'h01) begin $display("FAIL: 0x09A8 after the set reads %02x, want 01 (CRT31K.TXT `09A8 after_set31=01`)", b); errors++; end
    master_program(64'h10_4E_47_0C_07_0D_90_89);
    measure(2, 6, fr, ln);
    within_ppm(fr, f31_cap, 3.0, "31K: frame Hz");
    within_ppm(ln, f31_cap * 449.0, 3.0, "31K: line Hz");
    expect_line_dots(ln, d31_cap, 800, "31K: line at the capture's dot clock");

    // ---- the 31 kHz monitor range: x = 98 characters (784 dots), inside gdcclk[2]'s 92..108 ----
    master_program(64'h10_4E_47_04_07_0D_90_89);      // hfp2 = 1: 80 + 7 + 1 + 7 + 3 = 98
    measure(2, 3, fr, ln);
    expect_line_dots(ln, d31_cap, 784, "31K, x = 98: unclamped (NP2kai gdcclk[2] minx 92)");

    // ---- the BIOS 640 x 480 block (NP2kai bios/bios18.c gdcmastersync[3] `31-480:20`, which INT 18h
    // AH=30h programs with 0x09A8 bit 0 set): 800 x 525, VGA 640 x 480's geometry, at the 31 kHz clock ----
    master_program(64'h10_4E_4B_0C_03_06_E0_95);
    measure(2, 3, fr, ln);
    expect_line_dots(ln, d31_cap, 800, "31K 640 x 480: line");
    within_ppm(fr, d31_cap / 800.0 / 525.0, 3.0, "31K 640 x 480: frame Hz (800 x 525 at the capture's dot clock)");

    // ---- back: 0x09A8 = as found, then the 24 kHz table ----
    wr(16'h09A8, 8'h00);
    master_program(64'h10_4E_07_25_07_07_90_65);
    measure(2, 4, fr, ln);
    within_ppm(fr, f24r_cap, 3.0, "24K restored: frame Hz");
    within_ppm(ln, f24r_cap * 440.0, 3.0, "24K restored: line Hz");
    rd1(16'h09A8, b);
    if (b !== 8'h00) begin $display("FAIL: 0x09A8 restored reads %02x, want 00 (CRT31K.TXT `RESTORE 09A8 was=00 now=00`)", b); errors++; end

    // ---- the 24 kHz range clamps the same 784-dot block to 800 (gdcclk[1] minx 100) ----
    master_program(64'h10_4E_47_04_07_0D_90_89);
    measure(2, 3, fr, ln);
    expect_line_dots(ln, d24_cap, 800, "24K, x = 98: clamped to minx 100 (NP2kai gdcclk[1])");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_CRT31K: %0d check(s) failed", errors);
    $display("TB_PC9821_CRT31K: PASS");
    $finish;
  end
endmodule
