`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The crt31k probe's own measurement, run against the core: with clk_sys at 80 MHz, the real pc9821_iobus (its ARTIC counter at 0x5C-0x5F and its device bus), pc9821_dot_ce and pc9821_crtc wired as pc9821_system wires them, a CPU that executes tools/hwprobe/crt31k/crt31k.s's measure_runs access for access through the iobus CPU port - wait_vsync_rise polling the master GDC status (port 0x60) bit 5 with its ARTIC timeout reads, artic_read's 0x5F / word 0x5C / 0x5F reads and its wrap rule, the 24-bit delta - reads ARTIC ticks per 60 frames in the 24 kHz mode (as found and after the probe's restore sequence) and per 70 frames in the 31 kHz mode within 100 ppm of the Xe10's docs/probes/CRT31K.TXT rows (326 700 / 326 699 and 306 930; the two machines' ARTIC and dot oscillators are separate crystals), and the 24 kHz-to-31 kHz frame-period ratio, which cancels the ARTIC, within 10 ppm of the capture's. A 24 kHz frame ~610 ppm long (the dot enable 200 parts in 327 680 slow) fails both checks.
//
// WHY. tb_pc9821_crt31k times the VSYNC status bit against simulated time; this bench closes the
// gap between that and what the probe reports on a card: the guest's ARTIC reads and the polled
// status bit, through the iobus CPU port, with the probe's instruction-level access sequence (each
// `in` is one iobus CPU access; the CPU's own instruction time between accesses is GAP clocks).
// It reads 326 673 / 306 907 / 326 674, which is what the core reads on hardware (the 2026-10-17
// card screenshots: 326 672-326 675 and 306 905-306 908; the "326 872-326 875, ~600 ppm long"
// that report transcribed was the screenshot font's 6 read as an 8).
//
// EXPECTED VALUES ARE THE CAPTURE'S (AGENTS.md "Evidence"): docs/probes/CRT31K.TXT `RUN frames=60
// ticks=326700/326700/326698` (24K as found), `RUN frames=70 ticks=306930` x3 (31K), `RUN frames=60
// ticks=326699` (24K restored). The absolute band is 100 ppm: the Xe10's ARTIC and its dot clocks
// are separate crystals, and the Xe10 reads ~77 ppm more ticks a frame than the model (400/19 MHz
// against an exact 307 200 Hz) in the 24 kHz mode - a crystal-tolerance offset no bench can pin
// tighter. The 31 kHz model clock is the capture calibrated by its own 24 kHz rows
// (pc9821_vclk_pkg), so it carries the same offset. The RATIO of the two modes' tick counts per
// frame cancels the ARTIC and is held to 10 ppm (the capture's ~3 ppm a row, plus the 31 kHz
// clock's -0.94 ppm model step).
//
// WHAT IT IS BLIND TO: the rest of pc9821_system (the CPU's own instruction timing, the memory
// system, the other devices), the synthesized netlist and the card itself.

module tb_pc9821_artic_frame;
  localparam integer SYS_HZ = 80_000_000;
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
      .clk_sys(clk), .rst_n_sys(!reset), .rst_n_vid(!reset), .pixel_ce(pixel_ce), .crt31k(crt31k),
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

  // A bound: the run is ~3.3 s of simulated time.
  initial begin
    #(64'd5_000_000_000);
    $fatal(1, "TB_PC9821_ARTIC_FRAME: watchdog (5 s simulated)");
  end

  // ==== CHECKS ====
  // ==== THE CPU: one iobus CPU-port access per `in`/`out` of the probe ====
  // The CPU's own time between two accesses (instruction fetch/execute on the real z486 path):
  // the probe's polling granularity. Any value leaves the measurement unbiased (each window
  // starts and ends with the same detect-then-read latency); 12 clocks is a z486 `in`+`test`+`jz`.
  localparam integer GAP = 12;
  task automatic acc(input [15:0] portnum, input [3:0] be, input wr, input [31:0] wdata,
                     output [31:0] rdata);
    begin
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = be;
      cpu_din = wdata;
      cpu_write = wr;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1;
      rdata = cpu_dout;
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
      repeat (GAP) @(negedge clk);
    end
  endtask
  task automatic outb(input [15:0] portnum, input [7:0] data);
    reg [31:0] unused;
    acc(portnum, 4'b0001 << portnum[1:0], 1'b1, {24'd0, data} << (portnum[1:0] * 8), unused);
  endtask
  task automatic inb(input [15:0] portnum, output [7:0] data);
    reg [31:0] r;
    begin
      acc(portnum, 4'b0001 << portnum[1:0], 1'b0, 32'd0, r);
      data = r[{portnum[1:0], 3'b000} +: 8];
    end
  endtask
  task automatic inw(input [15:0] portnum, output [15:0] data);   // portnum[0] = 0
    reg [31:0] r;
    begin
      acc(portnum, 4'b0011 << portnum[1:0], 1'b0, 32'd0, r);
      data = r[{portnum[1:0], 3'b000} +: 16];
    end
  endtask

  // crt31k.s artic_read: H1 = in 0x5F, L = in ax,0x5C, H2 = in 0x5F; a moved high byte takes
  // H2 when L < 0x8000 (L was read after the wrap), else H1.
  task automatic artic_read(output [31:0] v);
    reg [7:0] h1, h2;
    reg [15:0] l;
    begin
      inb(16'h005F, h1);
      inw(16'h005C, l);
      inb(16'h005F, h2);
      if (h1 != h2 && l >= 16'h8000) v = {8'd0, h1, l};
      else                            v = {8'd0, h2, l};
    end
  endtask

  // crt31k.s wait_vsync_rise: status bit 5 must read 0, then 1; every failed poll also reads the
  // ARTIC for the 0.2 s timeout (EDGE_TIMEOUT = 61440 ticks).
  task automatic wait_vsync_rise(output reg timeout);
    reg [31:0] t_start, now;
    reg [7:0]  st;
    begin
      timeout = 1'b0;
      artic_read(t_start);
      forever begin
        inb(16'h0060, st);
        if (!st[5]) break;
        artic_read(now);
        if (((now - t_start) & 32'h00FF_FFFF) >= 32'd61440) begin timeout = 1'b1; break; end
      end
      if (!timeout) forever begin
        inb(16'h0060, st);
        if (st[5]) break;
        artic_read(now);
        if (((now - t_start) & 32'h00FF_FFFF) >= 32'd61440) begin timeout = 1'b1; break; end
      end
    end
  endtask

  // crt31k.s measure_runs, one run: sync to an edge, read the ARTIC, NFR more edges, read it again.
  task automatic measure_run(input integer nfr, output integer ticks);
    reg [31:0] t0, t1;
    reg to;
    integer i;
    begin
      ticks = -1;
      wait_vsync_rise(to);
      if (!to) begin
        artic_read(t0);
        for (i = 0; i < nfr && !to; i = i + 1) wait_vsync_rise(to);
        if (!to) begin
          artic_read(t1);
          ticks = int'((t1 - t0) & 32'h00FF_FFFF);
        end
      end
    end
  endtask

  // crt31k.s gdc_master_program: each command to 0x62, its parameters to 0x60 (the probe waits on
  // status bit 1, FIFO full, before each; the core's FIFO never fills at this pace).
  task automatic master_program(input [63:0] sync);
    integer i;
    begin
      outb(16'h0062, 8'h00);                                  // RESET
      outb(16'h0062, 8'h6F);                                  // VSYNC master
      outb(16'h0062, 8'h0F);                                  // SYNC (display enabled)
      for (i = 7; i >= 0; i = i - 1) outb(16'h0060, sync[i*8 +: 8]);
      outb(16'h0062, 8'h47); outb(16'h0060, 8'h50);           // PITCH 80
      outb(16'h0062, 8'h46); outb(16'h0060, 8'h00);           // ZOOM 0
      outb(16'h0062, 8'h70); outb(16'h0060, 8'h00); outb(16'h0060, 8'h00);
      outb(16'h0060, 8'hF0); outb(16'h0060, 8'h3F);           // SCROLL
    end
  endtask

  // ---- the capture (docs/probes/CRT31K.TXT) ----
  localparam real CAP_24K   = (326700.0 + 326700.0 + 326698.0) / 3.0;   // 60 frames, as found
  localparam real CAP_31K   = 306930.0;                                  // 70 frames
  localparam real CAP_24K_R = 326699.0;                                  // 60 frames, restored

  task automatic check_abs(input integer got, input real want, input string what);
    real d;
    begin
      d = (real'(got) - want) / want * 1.0e6;
      if (got < 0) begin
        $display("FAIL: %0s: TIMEOUT (no VSYNC edge)", what);
        errors = errors + 1;
      end else if (d > 100.0 || d < -100.0) begin
        $display("FAIL: %0s: %0d ticks, the capture's %.1f (%.1f ppm, want within 100)", what, got, want, d);
        errors = errors + 1;
      end else
        $display("  ok   %0s: %0d ticks (capture %.1f, %.1f ppm)", what, got, want, d);
    end
  endtask
  task automatic check_ratio(input integer t24, input integer t31, input string what);
    real got, want, d;
    begin
      got  = (real'(t24) / 60.0) / (real'(t31) / 70.0);
      want = (CAP_24K / 60.0) / (CAP_31K / 70.0);
      d = (got - want) / want * 1.0e6;
      if (d > 10.0 || d < -10.0) begin
        $display("FAIL: %0s: 24K/31K frame ratio %.7f, the capture's %.7f (%.1f ppm, want within 10)", what, got, want, d);
        errors = errors + 1;
      end else
        $display("  ok   %0s: 24K/31K frame ratio %.7f (capture %.7f, %.1f ppm)", what, got, want, d);
    end
  endtask

  integer t24, t31, t24r, i;
  reg [7:0] b;
  reg       to;
  // crt31k.s `settle` waits 0.5 s after a SYNC change; the new block lands at the next frame
  // boundary, so two VSYNC edges put the run past it at a fraction of the simulated time.
  task automatic settle;
    begin
      wait_vsync_rise(to);
      wait_vsync_rise(to);
    end
  endtask
  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- MODE 24K (as found): the power-up block, the BIOS 24 kHz table ----
    inb(16'h09A8, b);
    if (b !== 8'h00) begin $display("FAIL: 0x09A8 as found reads %02x, want 00", b); errors++; end
    measure_run(60, t24);
    $display("RUN frames=60 ticks=%0d   (24K as found)", t24);
    check_abs(t24, CAP_24K, "24K as found");

    // ---- MODE 31K: 0x09A8 |= 1, then the BIOS 31 kHz master table ----
    inb(16'h09A8, b);
    outb(16'h09A8, b | 8'h01);
    outb(16'h005F, 8'h00);                                     // iowait
    master_program(64'h10_4E_47_0C_07_0D_90_89);
    settle();
    measure_run(70, t31);
    $display("RUN frames=70 ticks=%0d   (31K)", t31);
    check_abs(t31, CAP_31K, "31K");
    check_ratio(t24, t31, "as found vs 31K");

    // ---- MODE 24K (restored): 0x09A8 = 00, the BIOS 24 kHz table ----
    outb(16'h09A8, 8'h00);
    outb(16'h005F, 8'h00);
    master_program(64'h10_4E_07_25_07_07_90_65);
    settle();
    measure_run(60, t24r);
    $display("RUN frames=60 ticks=%0d   (24K restored)", t24r);
    check_abs(t24r, CAP_24K_R, "24K restored");
    check_ratio(t24r, t31, "restored vs 31K");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_ARTIC_FRAME: %0d check(s) failed", errors);
    $display("TB_PC9821_ARTIC_FRAME: PASS");
    $finish;
  end
endmodule
