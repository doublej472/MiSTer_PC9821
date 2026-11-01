`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The sound path under a dense worst case -- six full-level drums overlapping with six FM channels at maximum, the SSG at maximum and the 86-PCM voice playing at full scale, with the 0xA46C write-FIFO and the OPNA register queue (WRQ) flooded at the I/O floor cadence -- with three detections running throughout: (a) no dropped write or sample: every host write presented through the real pc9821_iobus master is accepted by the buffer and lands (WRQ entries drained to the chip, 0xA46C bytes stored in SDRAM byte-exact) now that both buffers back-pressure through io_wr_wait instead of silently dropping on full (the pre-fix WRQ lost 94/160 at this cadence and the 0xA46C FIFO dropped past 4 deep under SDRAM contention), with the stall itself counted so the no-drop result cannot be vacuous; (b) the die's drum bus: the six-drum sum is recomputed from jt08_adpcm_acc's per-drum slot inputs as the die's 16-bit two's-complement WRAP (YM2608-LLE fmopna_impl.c:5370) and compared with the DUT accumulator every slot; (c) no clipped-vs-expected sample: jt08_adpcm_acc's pcm_out must equal that wrapped round sum, never a clamped one (the pre-fix 16-bit clamp there flat-topped dense overlaps before the FM mix -- audible as drums clipping) and the output chain must equal the single-clamp saturating model of the wide FM+ADPCM junction (the ymfm clamp16 / NP2kai _saturation_s16 point) followed by the AC-coupled (zero-mean) SSG and a WIDE join with NO intermediate saturation (datapaths.md F1: the pre-fix tree flat-topped there even when the FM+SSG+PCM86 sum fit in 16 bits; the single clamp is at the final DAC), the over-16 stimulus kept non-vacuous. Phase 1 pins the 0 dB single-drum output to the same model, so the default path stays bit-identical.
//
// TB_PC9821_AUDIO_CLIP: the sound path under a DENSE worst case - six full-level
// drums overlapping with six FM channels at maximum and the SSG at maximum, the
// 86-PCM voice playing at full scale, the 0xA46C write-FIFO flooded at the I/O
// floor and the OPNA register queue (WRQ) flooded with 128 back-to-back writes -
// with three detections running the whole time:
//
//   (a) DROPPED WRITES/SAMPLES (buffer overrun): every host write presented to
//       the OPNA or the 0xA46C port must be ACCEPTED and must LAND (WRQ entries
//       drained to the chip; FIFO bytes stored in SDRAM, byte-exact). Pre-fix the
//       WRQ silently dropped 94/160 at this cadence (T9a) and the 0xA46C FIFO
//       dropped past 4 deep (S6): both are now back-pressure (pc9821_iobus holds
//       S_IOWAIT while io_wr_wait is up) and this bench counts presented vs
//       accepted vs landed through the REAL iobus master.
//   (b) THE DIE'S 16-BIT WRAP: the six-drum sum is recomputed here from
//       jt08_adpcm_acc's per-drum slot inputs, wrapping at 16 bits exactly as the die
//       does (YM2608-LLE fmopna_impl.c:5370 F1), and
//       compared with the DUT's accumulator and its sign-extended round capture.
//   (c) CLIPPED-VS-EXPECTED: jt08_adpcm_acc's pcm_out must be the die's 16-bit
//       wrapped round sum, never a clamped one - the pre-fix tree flat-topped it at
//       16 bits, which is the audible "drums clipping" -
//       and the FM+ADPCM junction must clamp to the 16-bit rail (ymfm's
//       m_last_fm.clamp16, ymfm_opn.cpp:1411 `m_last_fm.clamp16();`) BEFORE the SSG is added, with
//       the SSG joining after that clamp and mix_dry as the final clamp.
//
// WHERE THE EXPECTED VALUES COME FROM. Every constant the models below compare
// against is sourced from the reference hierarchy (NP2kai = PRIMARY software
// reference; ymfm = the YM2608 die model) and is cited at its use - never from
// this RTL, which is the thing under test and never evidence of what the hardware
// does (the same rule the bench-circular audit applies to the pit/fdc rows):
//   * the FM+ADPCM value and its ONE clamp16 - ymfm ym2608::clock_fm_and_adpcm
//     (ymfm_opn.cpp:1405-1411, `// mix in the ADPCM and clamp`) and NP2kai's single DAC saturation
//     (_saturation_s16, sdl/soundmng.c:787);
//   * the SSG term is the DUT's own sound.ssg_ac (the join psg_snd * 33/16, then
//     AC-coupled to zero mean by the board's C7C1 series cap model): this bench
//     takes it as given and checks only WHERE it joins; its level is pinned
//     against the captures by tb_pc9821_opna_ssg_level / _opna_sndtest_balance;
//   * the single-drum amplitude ceiling - ymfm adpcm_a_channel::output
//     (ymfm_adpcm.cpp:226-239, `int8_t mul = 15 - (vol & 7);` ... `& ~3;`).
//
// PHASE 1 plays ONE drum at full level and pins the model every sample; its peak
// is checked against the reference ADPCM-A amplitude ceiling, not against a
// previous tree's printed value.
//
// WHY THIS BENCH EXISTS. The real YM2608 sums FM "with no intermediate
// clipping", adds ADPCM-A/B to the same int32, and clamps ONCE
// (ymfm ym2608::clock_fm_and_adpcm: m_last_fm.clamp16()), then adds the SSG
// AFTER that clamp; NP2kai sums SINT32 and saturates once at the DAC
// (_saturation_s16). The pre-fix drum bus clamped INSIDE the sum
// (jt08_adpcm_acc), before the FM mix - dense drum overlaps flat-topped there
// even when the true FM+drum sum fit in 16 bits - and the two write buffers
// dropped on full instead of back-pressuring. This bench is the fail-first for
// all three.

module tb_pc9821_audio_clip;
  // System port C bit 3: the beeper's MUTE (pc9821_iobus, ANDed with the PIT's
  // channel 2 in pc9821_system). This bench does not drive the beeper, but it
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
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
  wire [7:0] device_io_dout;
  wire       device_rd_wait;
  wire [3:0] top_bank;
  wire ide_rom_enable, bios_ram_gate, sound_extend;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  reg  [5:0] joystick = 6'b111111;   // the game port's switch lines, released
  // The rhythm ROM's pack-loader write port. This bench fills the ROM with a
  // non-silent ADPCM-A pattern so CHK-12 can require the channel to SOUND; with
  // the port left tied off (as it was) the ROM reads the all-zero code, which
  // the decoder turns into silence by design (src/opna/rhythm_rom/RHYTHM_ROM.v).
  reg         rhythm_we = 1'b0;
  reg  [11:0] rhythm_waddr = 12'd0;
  reg  [15:0] rhythm_wdata = 16'd0;
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
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;

  // The EGC's register file and its gate. This bench drives the sound ports, not
  // the graphics accelerator, so the gate is tied off and the registers are left
  // unread; they are declared because pc9821_iobus carries them (merged
  // with this branch) and the `.*` instantiation below matches ports by name.
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
  // The FDC's level interrupt (slave PIC IRQ11). pc9821_iobus carries the
  // port and the `.*` DUT instantiation matches by name, so it must
  // be declared here; this bench does not exercise the floppy path.
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  reg device_rd_hold = 1'b0;
  wire device_wr_wait;   // THE FIX UNDER TEST: the OPNA/PCM86 write back-pressure, muxed below
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

  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

  // pc9821_system's device glue: the OPNA is selected for its four ports (P5 made the ONE
  // pc9821_device_select instance live inside pc9821_iobus, so `.*` above binds opna_cs/pcm_cs
  // to the real decode instead of reproducing it here), it is the only device the bus waits a
  // cycle for, and its output is the only byte on the device bus (0xFF otherwise, standing in
  // for the devices this bench does not build).
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  wire [7:0] opna_io_dout;
  wire       opna_rd_wait, opna_wr_wait, opna_irq;
  wire signed [19:0] opna_snd_l, opna_snd_r;   // WIDE since A-1 (20-bit FM+ADPCM+SSG sum)

  assign device_io_dout = opna_cs ? opna_io_dout :
                          pcm_cs  ? pcm_io_dout  : 8'hFF;
  assign device_rd_wait = opna_rd_wait;
  // pc9821_system's write-back-pressure mux: a device buffer that cannot accept
  // a byte holds the guest's I/O write in pc9821_iobus's S_IOWAIT (the fix).
  assign device_wr_wait = (opna_cs && opna_wr_wait) || (pcm_cs && pcm86_wr_wait);

  // The clock enable is derived from SYS_CLOCK_HZ; this bench runs at 100 MHz
  // (10 ns period) so the OPNA sees its own 7.9872 MHz.
  pc9821_opna #(.SYS_CLOCK_HZ(100_000_000)) sound (
    .clk(clk), .reset(reset),
    .io_addr(device_io_addr),
    .io_wr(device_io_wr && opna_cs),
    .io_rd(device_io_rd && opna_cs),
    .io_din(device_io_din),
    .io_dout(opna_io_dout),
    .io_rd_wait(opna_rd_wait),
    .io_wr_wait(opna_wr_wait),
    .extend(sound_extend),
    // The connector's six switch lines, which pc9821_gameport owns; this bench drives
    // them directly (the register's own behaviour is what it tests).
    .joystick(joystick),
    .snd_l(opna_snd_l), .snd_r(opna_snd_r),
    .irq(opna_irq),
    // The rhythm ROM, driven from the pack-loader port this bench owns (CHK-12).
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr),
    .rhythm_wdata(rhythm_wdata)
  );

  integer errors = 0;

  // ==== CHECKS ====
  task automatic fail(input [8*170-1:0] message);
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

  // The games' own sequence (rec98 libs/master.lib/soundio.asm:52-56,
  // js_sense.asm:56-69): write the register index to 0x188, the data to 0x18A.
  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      write_byte(16'h0188, reg_index);
      write_byte(16'h018A, data);
    end
  endtask

  // The extended bank's register/data pair (0x18C/0x18E), the port pair the
  // card puts FM channels 4-6 behind: jt12_mmr decodes the chip address's high
  // bit as the channel's high bit (jt12_mmr.v:535, `up_ch <= {part, selected_register[1:0]};`), and the glue reaches it only
  // when 0xA460 bit 0 is set (pc9821_opna.sv op_sel).
  task automatic sound_x(input [7:0] reg_index, input [7:0] data);
    begin
      write_byte(16'h018C, reg_index);
      write_byte(16'h018E, data);
    end
  endtask


  // ==== THE 86-PCM BLOCK (the card's other device) =====================
  wire [7:0] pcm_io_dout;
  wire       pcm_irq, pcm86_wr_wait;
  wire signed [15:0] pcm_snd_l, pcm_snd_r;
  wire [15:0] pcm_dbg_count;
  // The SDRAM third-port stub: a byte store with a controllable ready-hold (the
  // contention the S6 sizing claim missed) and read support for the drain engine.
  wire        sdram_valid, sdram_write, sdram_resp_valid;
  wire [31:0] sdram_addr, sdram_din;
  wire  [3:0] sdram_be;
  wire  [7:0] sdram_burstcount;
  reg  [31:0] sdram_dout = 32'd0;
  localparam [31:0] BUF_BASE = 32'h0040_0000;

  integer stub_hold   = 0;      // cycles to withhold ready
  integer stub_writes = 0;      // bytes STORED (must equal the accepted pushes)
  integer stub_reads  = 0;
  reg [7:0] stub_mem [0:4095];
  reg       stub_ready;
  reg       stub_resp = 0;
  always @* stub_ready = (stub_hold == 0);

  function automatic [7:0] stub_byte(input [31:0] din, input [3:0] be);
    stub_byte = be[0] ? din[7:0] : be[1] ? din[15:8] : be[2] ? din[23:16] : din[31:24];
  endfunction

  wire [11:0] stub_off = sdram_addr[11:0] - BUF_BASE[11:0];
  always @(posedge clk) begin
    stub_resp <= 1'b0;
    if (stub_hold > 0) stub_hold = stub_hold - 1;
    if (sdram_valid && stub_ready) begin
      if (sdram_write) begin
        stub_mem[stub_off] <= stub_byte(sdram_din, sdram_be);
        stub_writes = stub_writes + 1;
      end else begin
        sdram_dout <= { stub_mem[{stub_off[11:2], 2'b11}], stub_mem[{stub_off[11:2], 2'b10}],
                        stub_mem[{stub_off[11:2], 2'b01}], stub_mem[{stub_off[11:2], 2'b00}] };
        stub_resp  <= 1'b1;
        stub_reads = stub_reads + 1;
      end
    end
  end
  assign sdram_resp_valid = stub_resp;

  pc9821_pcm86 #(.SYS_CLOCK_HZ(100_000_000)) pcm86 (
    .clk(clk), .reset(reset),
    .io_addr(device_io_addr),
    .io_wr(device_io_wr && pcm_cs),
    .io_rd(device_io_rd && pcm_cs),
    .io_din(device_io_din),
    .io_dout(pcm_io_dout),
    /* verilator lint_off PINCONNECTEMPTY */   // reads answer in the strobe cycle
    .io_rd_wait(),
    /* verilator lint_on PINCONNECTEMPTY */
    .io_wr_wait(pcm86_wr_wait),
    .snd_l(pcm_snd_l), .snd_r(pcm_snd_r),
    .irq(pcm_irq),
    /* verilator lint_off PINCONNECTEMPTY */   // bench instrument only
    .dbg_count(),
    /* verilator lint_on PINCONNECTEMPTY */
    .buf_base(BUF_BASE),
    .sdram_valid(sdram_valid), .sdram_ready(stub_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  // ==== THE DETECTION TAPS =============================================
  // (b) is a WIDTH/WRAP differential, not a conformance model: it replays
  // jt08_adpcm_acc's own per-slot sum (fed from the DUT's slot taps) with the
  // die's 16-bit wrap and compares it against the DUT's accumulator and its
  // sign-extended round capture every slot. SCOPE: because it
  // takes the decoded drum samples from the DUT, it CANNOT see a wrong ADPCM
  // decode or a wrong drum gain - only an intermediate clamp or an accumulator
  // overflow. (c) is the output-chain check; its expected
  // values are reference-sourced (see the constants below). The monitor compares
  // FIRST (both sides at the same state) and updates second, and captures BEFORE
  // updating because the RTL's `pcm_out <= acc` takes the pre-edge sum.
  wire        dr_cen    = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.cen;
  wire        dr_match  = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.match;
  wire        dr_en_sum = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.en_sum;
  wire [5:0]  dr_cur_ch = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.cur_ch;
  wire [5:0]  dr_en_ch  = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.en_ch;
  wire [2:0]  dr_gain   = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.gain_shift;
  wire signed [15:0] dr_pcm_in = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.pcm_in;
  wire signed [19:0] drumacc = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.acc;
  wire signed [19:0] presum   = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.pcm_out;
  wire signed [19:0] fmsnd    = sound.u_opna.u_jt08.u_jt12.gen_adpcm.u_acc.u_left.snd;

  // Reference-sourced expected values (see "WHERE THE EXPECTED VALUES COME FROM").
  // The SSG joins at psg_snd << 2 (the PC88 board mix) and is then AC-COUPLED by
  // the board's C7C1 series cap model, so the join adds the zero-mean term
  // sound.ssg_ac (its level is pinned by tb_pc9821_opna_ssg_level).
  wire signed [19:0] ssg_term = sound.ssg_ac;
  // The 16-bit rail of the junction clamp16 (ymfm ymfm_opn.cpp:1411 `m_last_fm.clamp16();`). The
  // FM+ADPCM sum is clamped to it here; the SSG is added AFTER (ymfm_opn.cpp:
  // 1323 `m_ssg_resampler.resample(output - numsamples, numsamples);`), which is why the join itself can still ride past 16 bits.
  localparam integer CLAMP16_MAX =  32767;
  localparam integer CLAMP16_MIN = -32768;
  // A full-level drum's ceiling: ymfm adpcm_a_channel::output (ymfm_adpcm.cpp:
  // 226-239) over a 12-bit accumulator (+-2048) at the documented full level
  // (instrument+total level both max -> vol 0 -> mul 15, shift 5), so
  // |value| <= |(2048 << 4) * 15 >> 5| = 15360.
  localparam integer P1_DRUM_MAX = 15360;

  integer model_acc, model_raw, model_expected, model_started;
  integer clip_events, wrap_events, chain_events, bp_stall_events, join_over16, drum_wrapped;
  initial begin
    model_acc = 0; model_raw = 0; model_expected = 0; model_started = 0;
    clip_events = 0; wrap_events = 0; chain_events = 0; bp_stall_events = 0;
    join_over16 = 0; drum_wrapped = 0;
  end

  // The die's six-drum bus WRAPS at 16 bits (fmopna_impl.c:5367-5382,
  // `chip->ac_rss_accm1[0] = accm1 & 0xffff;`). The model keeps the
  // UNBOUNDED running sum plus its 16-bit two's-complement image, which is what the
  // DUT's accumulator and the sign-extended pcm_out must equal.
  function automatic integer wrap16(input integer v);
    integer t;
    begin
      t = v & 16'hFFFF;
      wrap16 = (t >= 32768) ? t - 65536 : t;
    end
  endfunction

  // The (b) per-drum term: the DUT's decoded sample through its RHYTHM shift.
  // `rhythm_gain_shift` is hardwired to 0 (jtopna.v:75), so this is a no-op in the
  // core; (b)'s scope note above stands (it cannot see a wrong decode/gain).
  wire signed [15:0] dr_term = dr_en_sum ? (dr_pcm_in >>> dr_gain) : 16'sd0;

  // Per-phase presentation/acceptance/landing counters (the (a) detection).
  integer io_strobes_opna, io_strobes_pcm, wrq_pushes, wrq_lands, pcm_pushes;
  initial begin
    io_strobes_opna = 0; io_strobes_pcm = 0;
    wrq_pushes = 0; wrq_lands = 0; pcm_pushes = 0;
  end

  integer exp_mix, exp_fm;
  always @(posedge clk) begin
    if (!reset) begin
      // ---- (b)/(c) the drum-sum model ----
      if (model_started) begin
        if (presum !== model_expected) clip_events = clip_events + 1;
        if (drumacc !== model_acc)     wrap_events = wrap_events + 1;
      end
      if (dr_cen && !$isunknown({dr_match, dr_en_sum, dr_cur_ch, dr_en_ch, dr_gain})) begin
        if (dr_en_ch[0] && dr_cur_ch[0]) begin
          model_expected = model_acc;
          model_started  = 1;
        end
        if (dr_match) begin
          model_raw = dr_cur_ch[0] ? dr_term : model_raw + dr_term;
          model_acc = wrap16(model_raw);
          if (model_raw != model_acc) drum_wrapped = drum_wrapped + 1;
        end
      end

      // ---- (c) the output chain, re-sourced to the reference arithmetic ----
      // ymfm ym2608::clock_fm_and_adpcm (ymfm_opn.cpp:1405-1411) sums FM +
      // ADPCM-A(0x3f) + ADPCM-B(1) into ONE int32 and clamps ONCE
      // (`m_last_fm.clamp16()`); the SSG is added AFTER that clamp. `fmsnd` taps
      // that complete FM+ADPCM sum, so the model clamps IT to the 16-bit rail
      // (CLAMP16_MAX/MIN) and then adds the AC-coupled (zero-mean) SSG term
      // (sound.ssg_ac; its level is pinned by tb_pc9821_opna_ssg_level). The
      // junction clamp is the one the known-good
      // 8f8194e2 tip shipped; A-1 (a194031e) removed it, and every over-16
      // sample then diverged from this model (the DUT delivered PSG+raw where
      // the model has PSG+clamped) -> chain_events -> FAIL. That is the same
      // fail-first, now inverted: it catches BOTH an intermediate sat16 on the
      // drum bus AND the A-1 raw junction.
      exp_fm  = ($signed(fmsnd) > CLAMP16_MAX) ? CLAMP16_MAX :
                ($signed(fmsnd) < CLAMP16_MIN) ? CLAMP16_MIN : $signed(fmsnd);
      exp_mix = exp_fm + ssg_term;
      if ((exp_mix > CLAMP16_MAX) || (exp_mix < CLAMP16_MIN)) join_over16 = join_over16 + 1;
      if (!$isunknown({fmsnd, sound.ssg_ac, sound.mix_l, opna_snd_l})) begin
        if ((sound.mix_l !== $signed(exp_mix[19:0])) || (opna_snd_l !== $signed(exp_mix[19:0])))
          chain_events = chain_events + 1;
      end

      // ---- (a) presentation / acceptance / landing ----
      if (device_io_wr && opna_cs) io_strobes_opna = io_strobes_opna + 1;
      if (device_io_wr && pcm_cs)  io_strobes_pcm  = io_strobes_pcm  + 1;
      if (sound.wrq_push)          wrq_pushes      = wrq_pushes      + 1;
      // dr_go, not dr_fire: the S1 fire-retry discipline holds dr_fire across a
      // host access and retries, so a landing is the cycle the chip actually
      // sees the write (dr_fire && host-free) - one per queued entry.
      if (sound.dr_go)             wrq_lands       = wrq_lands       + 1;
      if (pcm86.u_buf.fifo_push)   pcm_pushes      = pcm_pushes      + 1;
      // The back-pressure engaged at least once: the stall is real, not vacuous.
      if (device_wr_wait && (dut.state == pc9821_ports_pkg::S_IOWAIT) && (dut.io_hold == 0))
        bp_stall_events = bp_stall_events + 1;
    end
  end

  // ==== STIMULUS (register sequences, through the real bus) ============
  // Key-on through the BASE bank (jt12_mmr gates up_keyon on !part && !addr[1]);
  // channels 4-6 are the chip's 4,5,6 behind the extended port pair.
  task automatic key_on(input [2:0] chcode);
    begin
      sound_o(8'h28, {4'hF, 1'b0, chcode});
    end
  endtask

  task automatic key_off;
    begin
      sound_o(8'h28, 8'h00); sound_o(8'h28, 8'h01); sound_o(8'h28, 8'h02);
      sound_o(8'h28, 8'h04); sound_o(8'h28, 8'h05); sound_o(8'h28, 8'h06);
    end
  endtask

  // One FM channel loud: TL=0, AR=31, ALG=7 (every operator a carrier), L+R.
  // Each channel gets its OWN fnum so the six drift through every relative phase.
  task automatic fm_channel(input bank, input [1:0] sel, input [7:0] fnumlo);
    begin
      if (bank) sound_x(8'h28, 8'h00); else sound_o(8'h28, 8'h00);
      begin : ops
        integer op;
        for (op = 0; op < 4; op = op + 1) begin
          if (bank) begin
            sound_x(8'h30 + 8'(op*4) + {6'b0, sel}, 8'h01);
            sound_x(8'h40 + 8'(op*4) + {6'b0, sel}, 8'h00);
            sound_x(8'h50 + 8'(op*4) + {6'b0, sel}, 8'h1F);
            sound_x(8'h60 + 8'(op*4) + {6'b0, sel}, 8'h00);
            sound_x(8'h70 + 8'(op*4) + {6'b0, sel}, 8'h00);
            sound_x(8'h80 + 8'(op*4) + {6'b0, sel}, 8'h0F);
            sound_x(8'h90 + 8'(op*4) + {6'b0, sel}, 8'h00);
          end else begin
            sound_o(8'h30 + 8'(op*4) + {6'b0, sel}, 8'h01);
            sound_o(8'h40 + 8'(op*4) + {6'b0, sel}, 8'h00);
            sound_o(8'h50 + 8'(op*4) + {6'b0, sel}, 8'h1F);
            sound_o(8'h60 + 8'(op*4) + {6'b0, sel}, 8'h00);
            sound_o(8'h70 + 8'(op*4) + {6'b0, sel}, 8'h00);
            sound_o(8'h80 + 8'(op*4) + {6'b0, sel}, 8'h0F);
            sound_o(8'h90 + 8'(op*4) + {6'b0, sel}, 8'h00);
          end
        end
      end
      if (bank) begin
        sound_x(8'hB0 + {6'b0, sel}, 8'h07);
        sound_x(8'hB4 + {6'b0, sel}, 8'hC0);
        sound_x(8'hA4 + {6'b0, sel}, 8'h22);
        sound_x(8'hA0 + {6'b0, sel}, fnumlo);
      end else begin
        sound_o(8'hB0 + {6'b0, sel}, 8'h07);
        sound_o(8'hB4 + {6'b0, sel}, 8'hC0);
        sound_o(8'hA4 + {6'b0, sel}, 8'h22);
        sound_o(8'hA0 + {6'b0, sel}, fnumlo);
      end
    end
  endtask

  task automatic ssg_max;
    begin
      sound_o(8'h07, 8'h38);
      sound_o(8'h00, 8'h40); sound_o(8'h01, 8'h01);
      sound_o(8'h02, 8'h55); sound_o(8'h03, 8'h01);
      sound_o(8'h04, 8'h6A); sound_o(8'h05, 8'h01);
      sound_o(8'h08, 8'h0F); sound_o(8'h09, 8'h0F); sound_o(8'h0A, 8'h0F);
    end
  endtask

  task automatic ssg_off;
    begin
      sound_o(8'h08, 8'h00); sound_o(8'h09, 8'h00); sound_o(8'h0A, 8'h00);
    end
  endtask

  // All six rhythm instruments at full level; the LRACL byte rides a six-stage
  // pipeline, so each write needs its own gap to reach every channel.
  task automatic rhythm_full;
    begin
      sound_o(8'h11, 8'h3F);
      sound_o(8'h18, 8'hDF); repeat (2000) @(posedge clk);
      sound_o(8'h19, 8'hDF); repeat (2000) @(posedge clk);
      sound_o(8'h1A, 8'hDF); repeat (2000) @(posedge clk);
      sound_o(8'h1B, 8'hDF); repeat (2000) @(posedge clk);
      sound_o(8'h1C, 8'hDF); repeat (2000) @(posedge clk);
      sound_o(8'h1D, 8'hDF); repeat (2000) @(posedge clk);
    end
  endtask

  // ==== PHASE WINDOWS ==================================================
  reg [7:0] v;
  integer n, lo, peak, clip0, wrap0, chain0, pcm_peak;
  integer wr_base;
  integer p1_peak;

  task automatic window(input integer cycles);
    begin
      peak = 0; pcm_peak = 0;
      for (n = 0; n < cycles; n = n + 1) begin
        @(posedge clk);
        lo = (opna_snd_l < 0) ? -opna_snd_l : opna_snd_l;
        if (lo > peak) peak = lo;
        lo = (pcm_snd_l < 0) ? -pcm_snd_l : pcm_snd_l;
        if (lo > pcm_peak) pcm_peak = lo;
      end
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2000) @(posedge clk);

    // ---- the drum ROM image: one non-silent ADPCM-A nibble everywhere ----
    // Nibble 5 is the decoder's non-silent code (the all-zero code is silence by
    // design); the samples are not in the tree, so the bench supplies its own
    // through the loader port. The vendored decoder caps its output at 12 bits,
    // so this reaches the same amplitude as any real image at the same levels.
    for (n = 0; n < 4096; n = n + 1) begin
      @(negedge clk);
      rhythm_we    = 1'b1;
      rhythm_waddr = n[11:0];
      rhythm_wdata = 16'h5555;
    end
    @(negedge clk);
    rhythm_we = 1'b0;

    // =================================================================
    // PHASE 1: ONE drum at full level, alone - the 0 dB reference pin. The
    // single-drum output is bounded by the ymfm ADPCM-A amplitude:
    // adpcm_a_channel::output (ymfm_adpcm.cpp:226-239) turns the 12-bit
    // accumulator into ((acc<<4)*(15-vol&7)) >> (5+vol>>3) & ~3, so at the
    // documented full level used here (vol 0 -> mul 15, shift 5) one drum cannot
    // exceed |(+/-2048 << 4)*15 >> 5| = 15360. The 0 dB path must stay inside
    // that reference ceiling (a scaled-up gain fails), not match a previous tree's
    // printed peak.
    // =================================================================
    rhythm_full;
    sound_o(8'h10, 8'h01);            // trigger instrument 0 (bass drum)
    repeat (6000) @(posedge clk);
    window(300_000);
    p1_peak = peak;
    $display("  P1 one drum full, alone: peak L=%0d, model clip events=%0d, wrap=%0d",
             p1_peak, clip_events, wrap_events);
    if (p1_peak <= 0)
      fail("the single full-level drum produced nothing: trigger, ROM or path is dead");
    if (p1_peak > P1_DRUM_MAX)
      fail("P1: one full-level drum exceeds the reference ADPCM-A ceiling (15360): the drum gain is scaled up");
    if (clip_events != 0)
      fail("P1: the drum bus is not the die's 16-bit sum even for a single drum");
    if (wrap_events != 0)
      fail("P1: the drum accumulator diverged from the die's 16-bit wrapping model");

    // =================================================================
    // PHASE 2: THE DENSE PATTERN - six FM channels at max (drifting notes),
    // SSG three at max, six drums at full, AND the 86-PCM voice playing at
    // full scale: every voice the card has, at once.
    // =================================================================
    // The 86-PCM voice: full DAC volume, playback on, a buffer of full-scale
    // 16-bit big-endian frames. The block has to OUTLAST the FM/SSG/drum setup
    // plus this phase's 500k-clk window: the reset format is 16-bit STEREO (4
    // bytes a frame, dactrl 0x32) at 44100 Hz, so 4096 bytes is 1024 frames = 23
    // ms, against a setup of ~1.4 ms. 256 bytes (64 frames, 1.45 ms) no longer
    // reaches the window, because a starved card now outputs SILENCE - the
    // reference behaviour (NP2kai sound/pcm86g.c:105-109 etc., qemu
    // opna_pcm_consume) - and the stale held frame this bench used to see was
    // the DAC repeating its last sample, not the PCM leg being alive. 4096 is
    // also far inside the 32 KiB ring, so nothing is dropped and the count
    // never caps.
    write_byte(16'h0A466, 8'hA0);     // vol5 = ~0xA0 & 0xF = 15 (full)
    write_byte(16'h0A468, 8'h80);     // playback enable, rate index 0
    for (n = 0; n < 4096; n = n + 1)
      write_byte(16'h0A46C, n[0] ? 8'hFF : 8'h7F);

    fm_channel(1'b0, 2'd0, 8'h40); fm_channel(1'b0, 2'd1, 8'h55); fm_channel(1'b0, 2'd2, 8'h69);
    fm_channel(1'b1, 2'd0, 8'h7D); fm_channel(1'b1, 2'd1, 8'h90); fm_channel(1'b1, 2'd2, 8'hA5);
    key_on(3'd0); key_on(3'd1); key_on(3'd2);
    key_on(3'd4); key_on(3'd5); key_on(3'd6);
    ssg_max;
    rhythm_full;
    sound_o(8'h10, 8'h3F);            // trigger all six drums
    repeat (6000) @(posedge clk);
    clip0 = clip_events; wrap0 = wrap_events; chain0 = chain_events;
    window(500_000);
    $display("  P2 dense mix (FM6+SSG3+drums6+PCM): peak L=%0d, 86-PCM peak=%0d", peak, pcm_peak);
    $display("     model: clip events=%0d, wrap events=%0d, chain mismatches=%0d",
             clip_events - clip0, wrap_events - wrap0, chain_events - chain0);
    if (pcm_peak == 0)
      fail("P2: the 86-PCM voice at full volume produced nothing: the PCM leg of the dense mix is dead");
    if ((clip_events - clip0) != 0)
      fail("P2: the drum bus is not the die's 16-bit WRAPPED sum under the dense overlap (the audible clip)");
    if ((wrap_events - wrap0) != 0)
      fail("P2: the drum accumulator is not the die's 16-bit wrapping sum under the dense overlap");
    if ((chain_events - chain0) != 0)
      fail("P2: the FM+ADPCM + SSG join does not match the clamp16-then-add-SSG model");
    $display("     drum bus passed the 16-bit range (wrap exercised) %0d slots", drum_wrapped);
    if (drum_wrapped == 0)
      fail("P2: the six-drum sum never left 16 bits: the die's 16-bit WRAP leg would be vacuous");
    if (join_over16 == 0)
      fail("P2: the join never passed 16 bits: the no-clamp check would be vacuous");

    // =================================================================
    // PHASE 3: WRQ FLOOD (the S2 overrun): 128 back-to-back host writes
    // (64 FM register pairs) at the I/O floor cadence - the fastest a guest
    // can go. Pre-fix the 64-deep queue silently dropped the overflow; with
    // the back-pressure every presented write is accepted AND lands.
    // =================================================================
    key_off; ssg_off;
    // Quiesce first: the land counter must count the FLOOD's own entries, not the
    // tail of the previous phases still draining when the counters zero.
    for (n = 0; n < 200000 && sound.wrq_busy; n = n + 1) @(posedge clk);
    if (sound.wrq_busy)
      fail("P3: the queue never drained before the flood");
    io_strobes_opna = 0; wrq_pushes = 0; wrq_lands = 0;
    for (n = 0; n < 64; n = n + 1)
      sound_o(8'h30 + 8'(n[2:0]), 8'(8'h40 + n));   // both bytes are queued writes
    // The guest-visible WAITREADY: 0x188 bit 7 clears only when the queue AND
    // the drain are done - so the lands are countable at quiesce.
    for (n = 0; n < 200000; n = n + 1) begin
      read_raw(16'h0188, v);
      if (!v[7]) n = 200000;
    end
    repeat (4000) @(posedge clk);
    $display("  P3 WRQ flood: presented=%0d accepted=%0d landed=%0d, back-pressure stall cycles=%0d",
             io_strobes_opna, wrq_pushes, wrq_lands, bp_stall_events);
    if (io_strobes_opna != 128)
      fail("P3: the flood did not present all 128 writes");
    if (wrq_pushes != io_strobes_opna)
      fail("P3: the register queue DROPPED writes under the flood: the S2 overrun is back");
    if (wrq_lands != io_strobes_opna)
      fail("P3: accepted writes did not all reach the chip");
    if (bp_stall_events == 0)
      fail("P3: the flood never hit the back-pressure: the no-drop result is vacuous");

    // =================================================================
    // PHASE 4: 0xA46C FLOOD (the S6 overrun): 32 bytes back-to-back with
    // the SDRAM port withheld for 400 clk (the contention the depth-4 sizing
    // claim missed). Pre-fix the FIFO dropped past 4 deep; with the
    // back-pressure every byte is accepted and lands, byte-exact.
    // =================================================================
    io_strobes_pcm = 0; pcm_pushes = 0; stub_writes = 0;
    wr_base = pcm86.wrptr;      // the flood continues the circular buffer where P2 left it
    stub_hold = 400;
    for (n = 0; n < 32; n = n + 1)
      write_byte(16'h0A46C, 8'(8'h10 + n));
    stub_hold = 0;
    for (n = 0; n < 4000 && stub_writes < 32; n = n + 1) @(posedge clk);
    $display("  P4 0xA46C flood: presented=%0d accepted=%0d stored=%0d",
             io_strobes_pcm, pcm_pushes, stub_writes);
    if (io_strobes_pcm != 32)
      fail("P4: the flood did not present all 32 bytes");
    if (pcm_pushes != io_strobes_pcm)
      fail("P4: the 0xA46C write FIFO DROPPED bytes under contention: the S6 overrun is back");
    if (stub_writes != io_strobes_pcm)
      fail("P4: accepted bytes did not all reach SDRAM");
    for (n = 0; n < 32; n = n + 1)
      if (stub_mem[wr_base + n] !== 8'(8'h10 + n))
        fail("P4: a stored byte is not the byte written: the FIFO corrupted the stream");

    // ==== FINAL CROSS-CHECKS ====
    if (wrap_events != 0)
      fail("the drum accumulator diverged from the die's 16-bit wrapping model somewhere in the run");
    if (clip_events != 0)
      fail("the drum bus diverged from the die's 16-bit wrapping model somewhere in the run");
    if (chain_events != 0)
      fail("the FM+ADPCM + SSG join deviated from the clamp16-then-add-SSG model somewhere in the run");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_CLIP: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_CLIP: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_AUDIO_CLIP: TIMEOUT");
  end

endmodule
