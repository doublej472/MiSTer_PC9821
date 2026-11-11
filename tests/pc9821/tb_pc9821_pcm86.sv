`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PCM86:
// The PC-9801-86's 86-PCM block through the real I/O bus: 0xA460 answering the board sound ID 0x40 with the extension latch in bit 0 and the ID nibble read-only, 0xA468 and 0xA46A reading back what was written with 0xA46A multiplexed between the IRQ threshold and the DAC control and the reset values 0x00 and 0x32, 0xA466 full/empty/phase status whose full bit only a real 32 KiB buffer can set, the drain stopping while playback is disabled and then consuming one sample frame per sample period at the selected rate, the 16-bit big-endian (mono and the reset format's stereo, left word first) and 8-bit left-justified sample decode as an exact audio level, and the buffer-low interrupt at 0xA468 bit 4 as a LEVEL that is gated by the IRQ enable (bit 5), that re-asserts on a bit-4-clear write while the buffer is still below threshold, and that clears only when the level is no longer true. It does NOT cover DMA, which neither reference models, and it does not assert the analogue output.


// The DUTs are pc9821_iobus plus pc9821_pcm86 wired exactly as pc9821_system
// wires them, so every sequence below runs down the real device path: iobus
// decodes 0xA462-0xA46E as device ports, pc9821_system's chip select routes them
// to the PCM block, and the block answers in the strobe cycle (it never asks for
// the extra read cycle the GDC and the OPNA do). A bench against pc9821_pcm86
// alone would not see the decode, and a bench against the I/O bus alone would
// not see the block.
//
// The 32 KiB fill and the 0x7FFC threshold case are the reason this bench takes
// milliseconds rather than microseconds: they are the only way to prove from
// outside that the buffer really is 0x8000 bytes and that the threshold ceiling
// is the references' 0x7FFC, which is a driver-visible promise.

module tb_pc9821_pcm86;
  // System port C bit 3: the beeper's MUTE (pc9821_iobus, ANDed with the PIT's
  // channel 2 in pc9821_system). This bench does not drive the beeper, but it
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  // instantiates pc9821_iobus with (.*), which needs every port named -
  // tools/check_wiring.py enforces that, and it caught exactly this when the
  // port was added. tb_pc9821_beeper covers the behaviour.
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0] cpu_be = 0;
  reg cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire cpu_ready, cpu_resp_valid;
  reg [7:0] debug_status = 8'hA5;
  wire device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire [7:0] device_io_din;
  reg  [7:0] device_io_dout;
  reg        device_rd_wait;
  wire [3:0] top_bank;
  wire ide_rom_enable, bios_ram_gate, sound_extend;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;   // 0x043B bit 2, the 15-16 MiB system-space window
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
  wire [15:0] dbg_last_io_addr;   // the most recent I/O access (the IO/DR/IV fields)
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  wire        dbg_last_io_stb;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;

  // The EGC's register file and its gate, which pc9821_iobus carries and this
  // bench does not drive (the `.*` instantiation below matches ports by name).
  wire        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg;
  wire [15:0] egc_mask, egc_bg, egc_sft, egc_leng;
  wire        egc_shift_we;
  reg        cal_cdat = 0;
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;

  // ==== DUT ====
  // 0x043F EMS page register / window select (pc9821_iobus outputs).
  wire [1:0] ems_state;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  // The FDC's level interrupt (slave PIC IRQ11). pc9821_iobus carries the
  // port and the `.*` DUT instantiation matches by name, so it must
  // be declared here; this bench does not exercise the floppy path.
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

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
  wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and its load cycle (unused here)
  wire        dma_mem_load;
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

  // P5: the chip select is pc9821_iobus's own decode now (the ONE pc9821_device_select
  // instance lives inside it), so `.*` above binds it instead of a local copy.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // pc9821_system's device glue, reproduced: the 86-PCM block is selected for
  // its seven even ports, is the only device on the bus in this bench, and its
  // output is the only byte the device bus carries (0xFF otherwise, standing in
  // for the devices this bench does not build). It does not raise
  // device_rd_wait: its reads are its register file.
  wire [7:0] pcm_io_dout;
  wire       pcm_irq;
  wire signed [15:0] pcm_snd_l, pcm_snd_r;
  wire [15:0] count;

  always @* begin
    device_io_dout = pcm_cs ? pcm_io_dout : 8'hFF;
    device_rd_wait = 1'b0;
  end

  // The bench runs at 100 MHz (10 ns period), so the sample period at rate
  // index 0 (44100 Hz) is 100e6/44100 = 2267.6 clk.
  // The sample buffer's SDRAM side (src/pcm86/pc9821_pcm86_buf.sv): the third port of the
// memory controller, which the bench stands in for.
wire        sdram_valid, sdram_ready, sdram_write, sdram_resp_valid;
wire [31:0] sdram_addr, sdram_din, sdram_dout;
wire  [3:0] sdram_be;
wire  [7:0] sdram_burstcount;
pcm86_sdram_model u_sdram (
  .clk(clk), .reset(reset),
  .valid(sdram_valid), .ready(sdram_ready), .write(sdram_write),
  .addr(sdram_addr), .din(sdram_din), .dout(sdram_dout),
  .resp_valid(sdram_resp_valid), .be(sdram_be)
);

pc9821_pcm86 #(.SYS_CLOCK_HZ(100_000_000)) pcm86 (
    .clk(clk), .reset(reset),
    .io_addr(device_io_addr),
    .io_wr(device_io_wr && pcm_cs),
    .io_rd(device_io_rd && pcm_cs),
    .io_din(device_io_din),
    .io_dout(pcm_io_dout),
    .io_rd_wait(),
    .snd_l(pcm_snd_l), .snd_r(pcm_snd_r),
    .irq(pcm_irq),
    .dbg_count(count),
    .buf_base(32'd0),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  integer errors = 0;
  integer cyc    = 0;
  always @(posedge clk) cyc = cyc + 1;

  task automatic fail(input [8*90-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  task automatic read_raw(input [15:0] portnum, output [7:0] data);
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

  task automatic write_byte(input [15:0] portnum, input [7:0] data);
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

  task automatic read_byte(input [15:0] portnum, input [7:0] expected,
                           input [8*60-1:0] what);
    reg [7:0] got;
    begin
      read_raw(portnum, got);
      if (got !== expected) begin
        $display("FAIL %0s: read %04x got=%02x expected=%02x",
                 what, portnum, got, expected);
        errors = errors + 1;
      end
    end
  endtask

  // The 0xA466 data port: 32 bytes, as the driver would push a block.
  task automatic fill(input integer nbytes, input [7:0] first);
    integer k;
    begin
      for (k = 0; k < nbytes; k = k + 1)
        write_byte(16'h0A46C, first + k[7:0]);
    end
  endtask

  // The DAC volume law this block implements: hold * vol5 * 4369 / 65536, with
  // 4369 = round(65536/15) so that the qemu reference's sample * volume / 15 is
  // a reciprocal multiply rather than a divider. Volume 15 (the 0xA466 write
  // 0xA0) is unity to within an LSB, and the bench computes its expectation with
  // the same arithmetic so the assertion below is about the DECODE (which byte
  // becomes which sample, and in which order) rather than about the rounding.
  function automatic signed [15:0] dac_scale(input signed [15:0] sample);
    reg signed [31:0] p;
    begin
      p = sample * $signed(32'd65535);       // vol_scale for vol5 = 15: 15*4369
      dac_scale = p[31:16];
    end
  endfunction

  // ==== CHECKS ====
  reg [7:0]  v;
  reg [7:0]  rb;
  integer    n, t0, t1, period;
  integer    k;
  reg        seen;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (50) @(posedge clk);

    // ---- 1. the card's identity and the extension latch ----------------
    // 0x40 is the board ID BOTH references give: NP2kai derives it from its
    // default DIP for the -86 (cbus/pcm86io.c pcm86io_setopt, a dialog labeled
    // 4x) and qemu-pc98 hard-codes PC98_OPNA_SOUND_ID 0x40 (hw/audio/pc98-opna.c).
    // Bit 0 is the extension latch the ITF sets by writing 0x73 at BANK4@0x2A5E.
    read_byte(16'h0A460, 8'h40, "0xA460 sound ID at reset");
    // The ID nibble is a STRAP: a write moves bit 0 alone, so the ITF's own
    // write-back reads 0x41, not 0x73 (both references).
    write_byte(16'h0A460, 8'h73);
    if (sound_extend !== 1'b1)
      fail("0xA460 bit 0 did not set the extension enable");
    read_byte(16'h0A460, 8'h41, "0xA460 after the ITF write-back");

    // ---- 2. the reset values of the control registers ------------------
    read_byte(16'h0A468, 8'h00, "0xA468 reset");
    read_byte(16'h0A46A, 8'h32, "0xA46A reset dactrl");
    read_raw(16'h0A466, v);
    // Empty (bit 6) with an empty buffer, not full (bit 7). Bit 0 is the
    // free-running sample phase, so it is masked.
    if ((v & 8'hFE) !== 8'h40)
      fail("0xA466 reset status is not the empty bit alone");

    // ---- 3. 0xA46A: threshold vs DAC control, and the 0x?F rejection ---
    // 0xA468 bit 5 chooses which register 0xA46A is (pcm86_oa46a). With it set
    // the port writes (val + 1) << 7 and 0xA46A keeps reading the DAC control.
    write_byte(16'h0A468, 8'h20);
    write_byte(16'h0A46A, 8'h07);
    read_byte(16'h0A46A, 8'h32, "0xA46A reads dactrl after a threshold write");
    // With bit 5 clear the port is the DAC control register, and 0x?F is
    // rejected outright (NP2kai's Windows NT 3.5 workaround).
    write_byte(16'h0A468, 8'h00);
    write_byte(16'h0A46A, 8'h6F);
    read_byte(16'h0A46A, 8'h32, "0xA46A rejects the 0x?F value");
    // 0x60 = 8-bit left: one byte per sample frame, so a byte write is one
    // sample and the drain rate below is in bytes per sample period.
    write_byte(16'h0A46A, 8'h60);
    read_byte(16'h0A46A, 8'h60, "0xA46A dactrl read-back");

    // ---- 4. the buffer fills, and does NOT drain while playback is off --
    fill(4, 8'h7F);
    if (count !== 16'd4) begin
      $display("FAIL: count after four writes is %0d, expected 4", count);
      errors = errors + 1;
    end
    read_raw(16'h0A466, v);
    if ((v & 8'hC0) !== 8'h00)
      fail("0xA466 reports full/empty with four bytes buffered");
    for (n = 0; n < 4000; n = n + 1) @(posedge clk);
    if (count !== 16'd4)
      fail("the buffer drained with 0xA468 bit 7 clear");

    // ---- 5. the volume, and the sample decode --------------------------
    // 0xA466 is the volume when (val & 0xE0) == 0xA0: vol5 = (~val) & 0xF, so
    // 0xA0 is FULL volume and the reset value 0 is silence.
    write_byte(16'h0A466, 8'hA0);
    // The first byte written above was 0x7F and the mode is 8-bit LEFT, i.e.
    // left-justified (signed byte << 8) on the LEFT channel and silence on the
    // right. Enable playback and let the drain consume it.
    write_byte(16'h0A468, 8'h80);
    seen = 1'b0;
    for (n = 0; n < 20000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count == 16'd3) begin t0 = cyc; seen = 1'b1; end
    end
    if (!seen) fail("the drain never consumed the first sample");
    else begin
      if (pcm_snd_l !== dac_scale(16'sh7F00)) begin
        $display("FAIL: left channel is %04x, expected %04x",
                 pcm_snd_l, dac_scale(16'sh7F00));
        errors = errors + 1;
      end
      if (pcm_snd_r !== 16'sd0)
        fail("the right channel is not silent in 8-bit-left mode");
    end

    // ---- 6. one sample frame per sample period at the selected rate -----
    // Rate index 0 is 44100 Hz, so at 100 MHz the count falls one byte every
    // 2267.6 clk. Measuring two consecutive transitions pins the divider: a
    // table read as the sample rate (rather than eight times it) would be 8x
    // slow here, and a wrong index would be off by a factor.
    seen = 1'b0;
    for (n = 0; n < 20000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count == 16'd2) begin t1 = cyc; seen = 1'b1; end
    end
    if (!seen) fail("the drain did not consume a second sample");
    else begin
      period = t1 - t0;
      if (period < 2250 || period > 2290) begin
        $display("FAIL: sample period is %0d clk, expected ~2268", period);
        errors = errors + 1;
      end
    end
    // Drain the rest and check the empty bit, which is NP2kai's
    // virbuf <= stepmask widening: fewer bytes than one sample frame.
    seen = 1'b0;
    for (n = 0; n < 40000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count == 16'd0) seen = 1'b1;
    end
    if (!seen) fail("the buffer never emptied");
    read_raw(16'h0A466, v);
    if ((v & 8'hC0) !== 8'h40)
      fail("0xA466 does not report empty with an empty buffer");

    // ---- 7. the stereo and 16-bit decodes ------------------------------
    // The card's byte order is the detail a first implementation gets wrong:
    // 16-bit samples are SIGNED and stored HIGH BYTE FIRST (NP2kai's
    // PCM86GET16, qemu's opna_pcm_pop_16), so the two bytes 0x12 0x34 in
    // 16-bit-left mode are the sample 0x1234 and not 0x3412, and in 8-bit
    // stereo the FIRST byte is the left channel. Both are asserted as audio
    // levels, so a little-endian decode fails here.
    write_byte(16'h0A468, 8'h88);      // buffer reset + playback enable
    write_byte(16'h0A46A, 8'h70);      // 8-bit stereo
    write_byte(16'h0A46C, 8'h40);      // left
    write_byte(16'h0A46C, 8'hC0);      // right
    seen = 1'b0;
    for (n = 0; n < 20000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count == 16'd0) seen = 1'b1;
    end
    if (!seen) fail("the 8-bit stereo pair never drained");
    else begin
      if (pcm_snd_l !== dac_scale(16'sh4000)) begin
        $display("FAIL: 8-bit stereo left is %04x, expected %04x",
                 pcm_snd_l, dac_scale(16'sh4000));
        errors = errors + 1;
      end
      if (pcm_snd_r !== dac_scale(16'shC000)) begin
        $display("FAIL: 8-bit stereo right is %04x, expected %04x",
                 pcm_snd_r, dac_scale(16'shC000));
        errors = errors + 1;
      end
    end
    write_byte(16'h0A468, 8'h88);      // buffer reset + playback enable
    write_byte(16'h0A46A, 8'h20);      // 16-bit left
    if (count !== 16'd0)
      fail("the buffer is not empty before the 16-bit frame");
    write_byte(16'h0A46C, 8'h12);      // the sample's HIGH byte first
    write_byte(16'h0A46C, 8'h34);
    seen = 1'b0;
    for (n = 0; n < 20000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count == 16'd0) seen = 1'b1;
    end
    if (!seen) fail("the 16-bit frame never drained");
    else if (pcm_snd_l !== dac_scale(16'sh1234)) begin
      $display("FAIL: 16-bit left is %04x, expected %04x (byte order)",
               pcm_snd_l, dac_scale(16'sh1234));
      errors = errors + 1;
    end
    // 16-bit STEREO (0xA46A format 3, the card's reset format 0x32): the frame is
    // the LEFT word then the RIGHT word, each high byte first - NP2kai
    // pcm86stereo16 (sound/pcm86g.c:127-133) takes `PCM86GET16(pcm86, dat);
    // ... smp_l = dat;` and then the second PCM86GET16 into smp_r. The reset
    // format was never decoded by this bench, so a frame whose words were
    // swapped between the channels passed.
    write_byte(16'h0A468, 8'h88);      // buffer reset + playback enable
    write_byte(16'h0A46A, 8'h30);      // 16-bit stereo
    if (count !== 16'd0)
      fail("the buffer is not empty before the 16-bit stereo frame");
    write_byte(16'h0A46C, 8'h12);      // left, high byte first
    write_byte(16'h0A46C, 8'h34);
    write_byte(16'h0A46C, 8'hAB);      // right, high byte first
    write_byte(16'h0A46C, 8'hCD);
    seen = 1'b0;
    for (n = 0; n < 20000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count == 16'd0) seen = 1'b1;
    end
    if (!seen) fail("the 16-bit stereo frame never drained");
    else begin
      if (pcm_snd_l !== dac_scale(16'sh1234)) begin
        $display("FAIL: 16-bit stereo left is %04x, expected %04x",
                 pcm_snd_l, dac_scale(16'sh1234));
        errors = errors + 1;
      end
      if (pcm_snd_r !== dac_scale(16'shABCD)) begin
        $display("FAIL: 16-bit stereo right is %04x, expected %04x",
                 pcm_snd_r, dac_scale(16'shABCD));
        errors = errors + 1;
      end
    end
    // Back to the one-byte mode the rest of the bench uses.
    write_byte(16'h0A468, 8'h08);      // buffer reset, playback off
    write_byte(16'h0A46A, 8'h60);      // 8-bit left

    // ---- 8. a full 32 KiB buffer, the 0x7FFC threshold ceiling, and the
    //         buffer-low interrupt -------------------------------------
    // Stop playback and clear the interrupt, then fill the whole logical buffer
    // with playback off: the count must saturate at 0x8000 and the full bit set.
    write_byte(16'h0A468, 8'h08);      // buffer reset (bit 3, 0->1 edge)
    if (count !== 16'd0)
      fail("the 0xA468 bit-3 buffer reset did not empty the count");
    write_byte(16'h0A468, 8'h00);
    fill(16'h8000, 8'h00);
    if (count !== 16'h8000) begin
      $display("FAIL: after 0x8000 writes the count is %04x (the buffer is not 32 KiB)",
               count);
      errors = errors + 1;
    end
    read_raw(16'h0A466, v);
    if ((v & 8'hC0) !== 8'h80)
      fail("0xA466 does not report full with 0x8000 bytes buffered");
    // Writing while full is accepted: the oldest byte is dropped and the count
    // stays at the ceiling rather than wrapping or refusing.
    fill(4, 8'hA5);
    if (count !== 16'h8000)
      fail("a write at full did not leave the count at 0x8000");

    // The threshold ceiling: 0xA46A = 0xFF means 0x7FFC, not (0xFF + 1) << 7.
    // The count is at 0x8000 > 0x7FFC, so arming must NOT raise the interrupt
    // yet -- and it must raise it four sample frames later, when the drain
    // crosses 0x7FFC. A threshold of 0x7FFC is only reachable with a real
    // 0x8000-byte buffer, so this is also the buffer-size assertion.
    write_byte(16'h0A468, 8'h20);      // threshold mode (bit 5)
    write_byte(16'h0A46A, 8'hFF);      // 0xFF -> 0x7FFC
    write_byte(16'h0A468, 8'hA0);      // bit 5 + playback enable, bit 4 clear
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b0)
      fail("the interrupt rose before the threshold was crossed");
    if (pcm_irq !== 1'b0)
      fail("the interrupt line is high before the threshold was crossed");
    // Two sample frames in: the count is 0x7FFE, still above the threshold.
    for (k = 0; k < 2; k = k + 1) begin
      seen = 1'b0;
      for (n = 0; n < 20000 && !seen; n = n + 1) begin
        @(posedge clk);
        if (count == 16'h8000 - 1 - k) seen = 1'b1;
      end
      if (!seen) fail("the drain stopped while draining a full buffer");
    end
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b0)
      fail("the interrupt rose two sample frames after the threshold test began");
    // By six frames the count has crossed 0x7FFC and the interrupt is up.
    seen = 1'b0;
    for (n = 0; n < 40000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count <= 16'h7FFC) seen = 1'b1;
    end
    if (!seen) fail("the buffer never crossed the 0x7FFC threshold");
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b1)
      fail("0xA468 bit 4 does not report the interrupt at the threshold");
    if (pcm_irq !== 1'b1)
      fail("the interrupt line is low with the interrupt pending");
    // B-3: a bit-4-clear write cannot extinguish a still-true level. The buffer
    // is still at/below the 0x7FFC threshold, so the same write that clears the
    // flag must immediately re-assert it (NP2kai pcm86_oa468 clears irqflag
    // first, then the `virbuf <= fifosize` level sets it again, pcm86io.c:114-126).
    write_byte(16'h0A468, 8'hA0);
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b1)
      fail("0xA468 bit 4 did not re-assert on a clear while the buffer is below threshold");
    if (pcm_irq !== 1'b1)
      fail("the interrupt line dropped on a clear while the buffer is still below threshold");

    // B-2: bit 4 is gated by the IRQ enable (bit 5). Clearing the enable masks
    // the latched flag on read even though the flag and the level are still true
    // (NP2kai pcm86gen_intrq returns FALSE when !(fifo & 0x20), pcm86c.c:472).
    // The irq WIRE is that same query, not the raw latched flag: the wire must
    // follow bit 4 low here, because the edge-latched PIC (pc9821_pic.sv:168)
    // gets no re-enable edge from a wire held high through the mask
    // (tb_pc9821_pcm86_irqmask owns the re-edge behaviour).
    write_byte(16'h0A468, 8'h90);   // playback on, bit 4 set (no clear), bit 5 clear
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b0)
      fail("0xA468 bit 4 read 1 with the IRQ enable (bit 5) clear");
    if (pcm_irq !== 1'b0)
      fail("the irq wire stayed high with the IRQ enable (bit 5) clear");

    // The clear sticks only once the level is no longer true: refill the whole
    // buffer above the 0x7FFC threshold (with the enable set) and then clear.
    write_byte(16'h0A468, 8'h28);   // buffer reset + threshold mode (bit 5 set)
    fill(16'h8000, 8'h00);          // count = 0x8000 > 0x7FFC
    write_byte(16'h0A468, 8'h20);   // bit 4 clear while the buffer is above threshold
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b0)
      fail("0xA468 bit 4 did not stay clear when cleared above the threshold");
    if (pcm_irq !== 1'b0)
      fail("the interrupt line stayed high after a clear above the threshold");

    // ---- 9. the programmed threshold fires at its value ----------------
    // A 256-byte threshold: fill above it with the arming bit clear (so nothing
    // can be pending), arm, and check that the interrupt is exactly at the
    // crossing. 0xA46A = 0x01 -> (1 + 1) << 7.
    write_byte(16'h0A468, 8'h28);      // buffer reset + threshold mode
    write_byte(16'h0A46A, 8'h01);
    write_byte(16'h0A468, 8'h08);      // buffer reset again, threshold mode off
    fill(16'h0140, 8'h20);
    if (count !== 16'h0140)
      fail("the second fill did not land in the buffer");
    write_byte(16'h0A468, 8'h20);      // threshold mode
    write_byte(16'h0A468, 8'hA0);      // arm + playback; count 0x140 > 0x100
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b0)
      fail("the interrupt rose above the programmed threshold");
    seen = 1'b0;
    for (n = 0; n < 300000 && !seen; n = n + 1) begin
      @(posedge clk);
      if (count <= 16'h0100) seen = 1'b1;
    end
    if (!seen) fail("the second fill never drained to its threshold");
    read_raw(16'h0A468, rb);
    if (rb[4] !== 1'b1)
      fail("the threshold interrupt did not fire at the programmed value");

    // ---- 10. no PCM port is reported as unmapped -----------------------
    if (last_unmapped_port == 16'h0A460 ||
        last_unmapped_port == 16'h0A462 ||
        last_unmapped_port == 16'h0A464 ||
        last_unmapped_port == 16'h0A466 ||
        last_unmapped_port == 16'h0A468 ||
        last_unmapped_port == 16'h0A46A ||
        last_unmapped_port == 16'h0A46C ||
        last_unmapped_port == 16'h0A46E)
      fail("a decoded PCM port is still the last unmapped port");

    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_PCM86: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: the two fills and the drains they feed are why this is
  // tens of milliseconds rather than microseconds.
  initial begin
    #120_000_000;
    $fatal(1, "TB_PC9821_PCM86: TIMEOUT");
  end

endmodule

// pcm86_sdram_model: the SDRAM third-port handshake and a 32 KiB byte store, for the PCM86
// benches. The buffer moved out of block RAM (src/pcm86/pc9821_pcm86_buf.sv), so each bench
// supplies the SDRAM side. The real controller answers a read after its CAS latency; this
// answers after one wait cycle, which is enough to exercise the request/valid handshake.
module pcm86_sdram_model (
  input  wire        clk, reset,
  input  wire        valid,
  output reg         ready,
  input  wire        write,
  input  wire [31:0] addr,
  input  wire [31:0] din,
  output reg  [31:0] dout,
  output reg         resp_valid,
  input  wire  [3:0] be
);
  reg [7:0]  mem [0:32767];
  reg [1:0]  st;
  reg [31:0] lat_addr;
  reg        lat_wr;
  integer    i;
  wire [14:0] wbase = {lat_addr[14:2], 2'b00};
  always @(posedge clk) begin
    ready      <= 1'b0;
    resp_valid <= 1'b0;
    if (reset) begin
      st <= 2'd0;
      for (i = 0; i < 32768; i = i + 1) mem[i] <= 8'h00;
    end else case (st)
      2'd0: if (valid) begin
              ready    <= 1'b1;
              lat_addr <= addr;
              lat_wr   <= write;
              st       <= 2'd1;
            end
      2'd1: begin
              if (lat_wr) begin
                if (be[0]) mem[wbase]     <= din[7:0];
                if (be[1]) mem[wbase + 1] <= din[15:8];
                if (be[2]) mem[wbase + 2] <= din[23:16];
                if (be[3]) mem[wbase + 3] <= din[31:24];
                st <= 2'd0;
              end else begin
                dout <= {mem[wbase + 3], mem[wbase + 2], mem[wbase + 1], mem[wbase]};
                st   <= 2'd2;
              end
            end
      default: begin
              resp_valid <= 1'b1;
              st         <= 2'd0;
            end
    endcase
  end
endmodule
