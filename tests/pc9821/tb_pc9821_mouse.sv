`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The PC-98 BUS MOUSE (pc9821_mouse behind pc9821_iobus's 0x7FD9-0x7FDF/0xBFDB decode) against NP2kai io/mouseif.c: the power-up read-back composes to 0xEF (buttons 0xE0 with the latch_x = -1 reset nibble, mouseif_reset:325-326), a 0x7FDF MODE WRITE resets the Port C latch to 0 (mouseif_o7fdf's setportc(0), :197-216 - unambiguous in NP2kai and identical in qemu-pc98's hw/input/pc98-mouse.c), PS/2 packets accumulate into the X/Y delta counters with Y NEGATED (PS/2 up-positive vs the PC-98 down-positive counter, sdl/mousemng.c:229-234) and portc bits 7/6/5 select latch-vs-live, axis and nibble (i7fd9:239-271), the Port C low nibble is 0x08 | three strap bits DERIVED from the live software-DIP store rather than a constant (mouseif.c:296-303 computes bit 2 from dipsw[2] bit 7 and bits 1:0 from ~dipsw[0] bits 5:4; over the measured power-up image 0x841E = 0x7C / 0x8E1E = 0x49 all three are 0, so the power-up 0x7FDD read is 0xF8 - the old hardcoded 0x03 strap answered 0xFB, a nibble no power-up bank yields), the buttons read as active-low L/M/R at bits 7/6/5 (mousemng.h + MAME's bit map; middle PRESSED is the one MAME-only behaviour and is NOTE'd, not silently claimed), the latch edge clamps to [-128,127] and arms the four-read overflow guard (setportc:142-163, i7fd9:253-266: +496 reads nibble F clamped for four reads and then nibble 0 wrapped - software ASSUMES the overflow), and IRQ13 pulses every (SYS_CLOCK_HZ/120) << timing clk with the 0xBFDB timing field (mouseint:131-140 + mouseif_obfdb:309-312; the 120 Hz base qemu and MAME agree on), silenced by INT# and re-armed by its falling edge (setportc:164-173). The R4 packet/latch coincidence merge is swept across the latch write with the same-cycle hit counted and asserted. FAIL-FIRST: the file connects no NEW port (pc9821_iobus by .*, ps2_mouse/mouse_irq joining the existing nets), so the same file builds against the pre-change pc9821_iobus.sv and every section fails there (0xE0 not 0xEF, no Port C reset, the strap nibble 0x0B where the store's bytes give 0x08, frozen deltas/buttons, no guard, mouse_irq never pulses). With Port C's upper half an input and the lower half an output, the 0x7FDD read is the latch masked to 0x1F (bit 4, INT#, survives).
//
// TB_PC9821_MOUSE: the PC-98 BUS MOUSE (pc9821_mouse behind pc9821_iobus's
// port decode) against NP2kai io/mouseif.c - the PRIMARY reference - driven
// deltas and buttons through the hps_io PS/2 packet port and read back through
// the uPD8255 port interface (0x7FD9-0x7FDF) and the IRQ13 output:
//
//  1. POWER-UP READ-BACK (mouseif_reset:317-330): 0x7FD9 composes to 0xEF -
//     buttons 0xE0 (L/M/R released, active low) OR the latch_x/latch_y = -1
//     reset value's high nibble 0xF through portc 0xF0's latch/swap/hi-nibble
//     mux (i7fd9:239-271) - 0x7FDB = 0x40 (i7fdb:279-287), 0x7FDD = 0xF8
//     (i7fdd:289-307 with NP2kai's 0x08 and the three strap bits its formula
//     computes from the software-DIP bank, all clear at power-up), 0x7FDF =
//     0xFF.
//     [source: NP2kai io/mouseif.c]
//
//  2. THE MODE-WRITE PORT-C RESET (mouseif_o7fdf:197-216): a 0x7FDF mode write RESETS THE PORT C LATCH TO 0 (the mode
//     branch ends in setportc(portc) with local portc = 0 - the uPD8255
//     mode-set clears the output latches, which qemu-pc98 hw/input/pc98-mouse.c
//     implements identically, `pc98_mouse_set_portc(s, 0)`), so writing 0xB5 to
//     0x7FDD and then mode 0x93 reads 0x0B, not 0xBB. FAIL-FIRST: the pre-fix
//     RTL kept the latch and reads 0xBB (NP2kai is unambiguous here, and qemu
//     agrees).
//     [source: NP2kai io/mouseif.c:197-216 + qemu-pc98 hw/input/pc98-mouse.c]
//
//  3. X/Y DELTAS, THE NIBBLE MUX AND THE THREE BUTTONS (i7fd9:228-275):
//     a PS/2 packet's X accumulates into x and its Y - NEGATED, because PS/2 Y
//     is positive = up and the PC-98 counter is positive = down (NP2kai feeds
//     SDL's down-positive yrel into mouseif.y, sdl/mousemng.c:229-234) - into
//     y; portc bits 7/6/5 then select latch-vs-live, X-vs-Y and low-vs-high
//     nibble. Buttons are {L_n, M_n, R_n, 0} active low (mousemng.h:2-5) at
//     bits 7/6/5 - L/R from NP2kai, MIDDLE at bit 6 from MAME
//     (pc9801.cpp:1545-1552); with middle released the byte is bit-identical
//     to NP2kai's `b | 0x40` ("for shizuku", :235), which is middle-always-
//     released. MIDDLE PRESSED is asserted here as bit 6 CLEAR and is NOT
//     sourced from NP2kai (its host has no middle button): it is the one
//     MAME-only behaviour, printed as such on the CHECK line.
//     [source: NP2kai io/mouseif.c + sdl/mousemng.c; middle bit: MAME only]
//
//  4. THE LATCH EDGE (setportc:142-163): a portc bit-7 rising edge snapshots
//     clamp(x, -128, 127) per axis into the latch, clears the counters and
//     arms the four-read guard. 303 latches as 127 (nibble 7) and -285 as -128
//     (nibble 8) - the clamp, not the raw wrap - and the counters read zero
//     after.
//     [source: NP2kai io/mouseif.c:142-163]
//
//  5. THE LIMITCOUNTER READ GUARD (mouseif.c:253-266): for the first four
//     0x7FD9 reads after a latch edge the selected value is clamped to
//     [-128, 127] - a live +496 reads nibble F (clamped 127) - and once the
//     guard expires the WRAPPED value passes: the same +496 reads nibble 0
//     (0x1F0), because software in the wild ASSUMES the overflow (the comment
//     at :150-152). FAIL-FIRST: the pre-fix RTL has no guard and no counters.
//     [source: NP2kai io/mouseif.c:150-152, 253-266]
//
//  6. THE PERIODIC IRQ13 (mouseint:131-140, setportc:164-173): while portc
//     bit 4 (INT#) is CLEAR the device pulses irq every
//     (SYS_CLOCK_HZ / 120) << timing clk_sys - NP2kai's
//     (realclock / 120) << timing CPU clocks at real speed (mouseif_changeclock
//     :344-348), the 120 Hz base qemu (PC98_MOUSE_RATE_HZ, pc98-mouse.c:83-85)
//     and MAME ("(120 >> x) Hz", pc9801.cpp:1663-1668 + the 120 Hz timer at
//     :1947) agree on; timing is 0xBFDB's dat & 3 (mouseif_obfdb:309-312).
//     The bench runs the iobus at SYS_CLOCK_HZ = 12000, so the base period is
//     100 clk and timing 3 gives 800. Masking (INT# set) silences the line and
//     the event dies at its next expiry (mouseint's `if (!(portc & 0x10))`);
//     re-enabling re-arms a full period (setportc:164-173 + mouseif_sync's
//     rev.79 revival :55-61).
//     [source: NP2kai io/mouseif.c; 120 Hz base corroborated by qemu + MAME]
//
//  7. THE PACKET/LATCH COINCIDENCE (R4 of docs/single-cycle-event-discipline):
//     a host packet arriving in the latch edge's own cycle starts the NEW
//     accumulation - it is neither latched nor lost - so latch + live always
//     sums to exactly the one packet, swept across the write. NP2kai cannot
//     express the coincidence (its events are serialized); the rule follows
//     its nearest shape (mouseif_sync leaving the newest delta in rx, :20-25).
//     The sweep is BOUNDED to have actually hit the collision cycle by the
//     collide counter below (asserted at least once), detected through signals
//     that exist on the pre-fix tree too.
//
// FAIL-FIRST: this file connects no NEW port (it instantiates pc9821_iobus by
// `. *` and the ps2_mouse/mouse_irq names join the existing nets), so the same
// file builds against the pre-change pc9821_iobus.sv (git checkout of that one
// file) and fails there: the power-up answer is 0xE0 not 0xEF, the mode write
// does not reset Port C (0xBB not 0x0B), the deltas never move any nibble, the
// buttons never leave 0xE0, the latch and guard have no clamping counters, and
// mouse_irq never pulses at all.

module tb_pc9821_mouse;
  // The iobus is parameterised down so the mouse event period is 100 clk at
  // timing 0 (12000 / 120) and 800 at timing 3 - real-size periods would make
  // the IRQ section run 416k clk per interval.
  localparam [31:0] CLK_HZ = 32'd12_000;
  localparam integer BASE_PERIOD = CLK_HZ / 120;          // 100
  localparam integer T3_PERIOD   = BASE_PERIOD * 8;       // 800

  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  wire beep_mute;
  wire [1:0] beep_vol;      // fix-audio-volume added this iobus output (beeper 2-bit volume)

  reg clk = 0;
  always #5 clk = ~clk;

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
  reg [7:0]  device_io_dout = 8'hC3;
  reg        device_rd_wait = 1'b0;
  reg        egc_gate = 1'b0;
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
  wire        dbg_last_io_stb;
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
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  reg device_rd_hold = 1'b0;
  reg device_wr_wait = 1'b0;

  // ---- the bus mouse's own seam (the ports pc9821_iobus gained for it) ----
  // hps_io's parsed PS/2 packet and the IRQ13 pulse line.
  reg  [24:0] ps2_mouse = 25'd0;
  wire        mouse_irq;
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

  // ==== DUT ====
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
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1), .SYS_CLOCK_HZ(CLK_HZ)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  integer errors = 0, cases = 0;
  integer collision_hits = 0;

  // ---- port I/O drivers (the pc9821_iobus lane handshake) ----
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

  task automatic rd_is(input [15:0] portnum, input [7:0] want, input [8*80-1:0] what);
    reg [7:0] got;
    begin
      cases = cases + 1;
      rd1(portnum, got);
      if (got !== want) begin
        $display("MISMATCH %0s: port %04x read %02x, expected %02x", what, portnum, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = %02x", what, got);
    end
  endtask

  // One host mouse packet through hps_io's field layout (sys/hps_io.sv:397-399):
  // [24] toggles once per packet, [23:16] Y (PS/2: positive = up), [15:8] X
  // (positive = right), [2:0] {middle, right, left}, 1 = pressed. Byte 0 carries the
  // 9-bit deltas' sign bits (bit 5 Y, bit 4 X) as Main_MiSTer user_io_mouse builds them;
  // every delta here is within +-127, so the sign is the byte's own bit 7.
  task automatic packet(input [7:0] dxb, input [7:0] dyb, input [2:0] btn);
    begin
      @(negedge clk);
      ps2_mouse = {~ps2_mouse[24], dyb, dxb, 2'b00, dyb[7], dxb[7], 1'b1, btn};
    end
  endtask

  task automatic fail(input [8*80-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ---- IRQ13 observation ----
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  task automatic wait_irq(output integer at_cyc);
    integer guard;
    begin
      guard = 0;
      // A call made in the detection negedge of the PREVIOUS pulse must not
      // re-consume that same pulse: step past it first (every period is >= 2
      // clk, so the pulse is gone one negedge later).
      if (mouse_irq) @(negedge clk);
      while (!mouse_irq && guard < 20_000) begin
        @(negedge clk);
        guard = guard + 1;
      end
      at_cyc = cyc;
    end
  endtask

  // ---- the packet/latch coincidence detector (section 7) ----
  // Mirrors pc9821_mouse's packet-edge register so the collision is observable
  // through signals that exist on the PRE-FIX tree (dut.state / dut.hit are
  // pc9821_iobus's own): a packet edge sampled in the same cycle as the 0x7FDD
  // write strobe IS the two events reaching the counters at once.
  reg ps2_tog_b = 0;
  always @(posedge clk) ps2_tog_b <= ps2_mouse[24];
  wire pkt_seen = ps2_mouse[24] != ps2_tog_b;
  wire collide = pkt_seen && (dut.state == pc9821_ports_pkg::S_BYTE) && cpu_write && dut.hit[pc9821_ports_pkg::HX_7FDD];
  always @(posedge clk) if (collide) collision_hits = collision_hits + 1;

  integer k, a, b, p1, p2, p3, p4, p5;
  integer quiet;
  reg [7:0] v;

  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ==== 1. power-up read-back (mouseif_reset:317-330) ====================
    // 0x7FD9 = buttons 0xE0 | latch -1's high nibble 0xF = 0xEF.
    rd_is(16'h7FD9, 8'hEF, "power-up 7FD9 = buttons|nibble of latch -1");
    rd_is(16'h7FDB, 8'h40, "power-up 7FDB = 0x40 (B is an input)");
    rd_is(16'h7FDD, 8'hF8, "power-up 7FDD = masked latch | 0x08 | the power-up strap 0x00");
    rd_is(16'h7FDF, 8'hFF, "0x7FDF control word reads open bus");

    // ==== 2. the mode write resets the Port C latch (mouseif_o7fdf) ========
    wr(16'h7FDD, 8'hB5);   // bit7 stays set (no latch edge), INT# stays masked
    rd_is(16'h7FDD, 8'hB8, "7FDD round-trips the 0xB5 latch high nibble");
    wr(16'h7FDF, 8'h93);   // mode write: setportc(0) clobbers the latch
    rd_is(16'h7FDD, 8'h08, "the mode write RESETS the Port C latch");
    // With Port C's UPPER half an input (mode bit 3) and the lower half an output the read is the
    // latch masked to 0x1F - bit 4 (INT#) survives (mouseif_i7fdd, mouseif.c:296-303 as the
    // header of pc9821_mouse.sv reads it): mode 0x98, latch 0xB5 -> 0x15.
    wr(16'h7FDF, 8'h98);
    wr(16'h7FDD, 8'hB5);
    rd_is(16'h7FDD, 8'h15, "C-upper input: the Port C read is the latch masked to 0x1F");
    wr(16'h7FDF, 8'h93);   // back to the power-up mode (clears the latch again)
    wr(16'h7FDF, 8'h09);   // BSR: set bit 4 (INT# masked), a quiet bench

    // ==== 3. deltas, the nibble mux, and the three buttons =================
    wr(16'h7FDD, 8'h10);   // live counters, X axis, low nibble, INT# masked
    packet(8'h37, 8'h25, 3'b011);   // x += 0x37, y -= 0x25; L+R pressed
    rd_is(16'h7FD9, 8'h47, "live X low nibble + button nibble");
    wr(16'h7FDD, 8'h30);   // X high nibble
    rd_is(16'h7FD9, 8'h43, "live X high nibble");
    wr(16'h7FDD, 8'h50);   // Y low nibble (the PS/2 Y sign flip: +0x25 -> -0x25)
    rd_is(16'h7FD9, 8'h4B, "live Y low nibble (PS/2 +Y -> PC-98 -Y)");
    wr(16'h7FDD, 8'h70);   // Y high nibble
    rd_is(16'h7FD9, 8'h4D, "live Y high nibble");
    wr(16'h7FDD, 8'h10);   // back to live X low (still 0x37)
    packet(8'h00, 8'h00, 3'b000);   // all three released
    rd_is(16'h7FD9, 8'hE7, "buttons all released read 1110 (L/M/R active low)");
    packet(8'h00, 8'h00, 3'b100);   // middle pressed
    cases = cases + 1;
    rd1(16'h7FD9, v);
    $display("NOTE     middle pressed reads %02x (bit 6 clear = MAME-sourced ONLY)", v);
    if ((v & 8'hF0) !== 8'hA0) begin
      $display("MISMATCH middle button: 7FD9 upper nibble %02x, expected A0", v[7:4]);
      errors = errors + 1;
    end
    // L and R ALONE: the L+R pair below reads the same with the two lines swapped, so
    // each is pressed by itself (NP2kai sdl/mousemng.h:1 `uPD8255A_LEFTBIT = 0x80,
    // uPD8255A_RIGHTBIT = 0x20`; hps_io [0] = left, [1] = right).
    packet(8'h00, 8'h00, 3'b001);   // left only
    rd_is(16'h7FD9, 8'h67, "left alone clears bit 7 only (LEFTBIT 0x80)");
    packet(8'h00, 8'h00, 3'b010);   // right only
    rd_is(16'h7FD9, 8'hC7, "right alone clears bit 5 only (RIGHTBIT 0x20)");
    packet(8'h00, 8'h00, 3'b011);   // L+R pressed again
    rd_is(16'h7FD9, 8'h47, "buttons L+R pressed read 0100");

    // ==== 4. the latch edge: clamp, clear, read-back =======================
    // x = 0x37 + 248 = 303, y = -0x25 - 248 = -285 at the edge.
    packet(8'h7C, 8'h7C, 3'b011);
    packet(8'h7C, 8'h7C, 3'b011);
    wr(16'h7FDD, 8'h90);   // bit 7 rises: latch = clamp(303)=127 / clamp(-285)=-128
    rd_is(16'h7FD9, 8'h4F, "latched X = 127 (clamped): low nibble");
    wr(16'h7FDD, 8'hB0);
    rd_is(16'h7FD9, 8'h47, "latched X = 127 (clamped): high nibble");
    wr(16'h7FDD, 8'hD0);
    rd_is(16'h7FD9, 8'h40, "latched Y = -128 (clamped): low nibble");
    wr(16'h7FDD, 8'hF0);
    rd_is(16'h7FD9, 8'h48, "latched Y = -128 (clamped): high nibble");
    wr(16'h7FDD, 8'h10);
    rd_is(16'h7FD9, 8'h40, "the live counters cleared at the latch edge");

    // ==== 5. the limitcounter read guard (mouseif.c:253-266) ===============
    wr(16'h7FDD, 8'h90);   // latch edge on zero: arms the four-read guard
    wr(16'h7FDD, 8'h10);   // back to the live X low nibble
    packet(8'h7C, 8'h00, 3'b011);
    packet(8'h7C, 8'h00, 3'b011);
    packet(8'h7C, 8'h00, 3'b011);
    packet(8'h7C, 8'h00, 3'b011);   // x = 496 = 0x1F0
    rd_is(16'h7FD9, 8'h4F, "guard read 1: clamped 127, nibble F");
    rd_is(16'h7FD9, 8'h4F, "guard read 2: clamped 127, nibble F");
    rd_is(16'h7FD9, 8'h4F, "guard read 3: clamped 127, nibble F");
    rd_is(16'h7FD9, 8'h4F, "guard read 4: clamped 127, nibble F");
    rd_is(16'h7FD9, 8'h40, "guard expired: the WRAPPED 0x1F0 passes, nibble 0");

    // ==== 6. the periodic IRQ13 (mouseint:131-140) =========================
    wr(16'hBFDB, 8'h03);   // timing = 3 -> period = 100 << 3 = 800 (mouseif:309-312)
    wr(16'h7FDF, 8'h09);   // BSR set bit 4: INT# masked (already)
    wr(16'h7FDF, 8'h08);   // BSR clear bit 4: the enable edge arms the event
    wait_irq(p1);
    wait_irq(p2);
    wait_irq(p3);
    cases = cases + 1;
    if ((p2 - p1) != T3_PERIOD || (p3 - p2) != T3_PERIOD) begin
      $display("MISMATCH irq period timing=3: %0d / %0d, expected %0d", p2 - p1, p3 - p2, T3_PERIOD);
      errors = errors + 1;
    end else $display("ok       irq period at timing 3 = %0d clk", p3 - p2);
    wr(16'hBFDB, 8'h00);   // timing = 0 mid-interval: the reload at the next
    wait_irq(p4);          // fire picks up the NEW period (mouseint:136-137)
    wait_irq(p5);
    cases = cases + 1;
    if ((p4 - p3) != T3_PERIOD || (p5 - p4) != BASE_PERIOD) begin
      $display("MISMATCH irq period timing 3->0: %0d / %0d, expected %0d / %0d",
               p4 - p3, p5 - p4, T3_PERIOD, BASE_PERIOD);
      errors = errors + 1;
    end else $display("ok       irq period at timing 0 = %0d clk", p5 - p4);
    wr(16'h7FDF, 8'h09);   // INT# masked: the line goes quiet
    quiet = 0;
    repeat (4 * BASE_PERIOD) begin
      @(negedge clk);
      if (mouse_irq) quiet = quiet + 1;
    end
    cases = cases + 1;
    if (quiet != 0) begin
      $display("MISMATCH irq masked: %0d pulses while INT# is set", quiet);
      errors = errors + 1;
    end else $display("ok       no irq while INT# is masked");
    wr(16'h7FDF, 8'h08);   // re-enable: re-arms a full period (setportc:164-173)
    wait_irq(p1);
    wait_irq(p2);
    cases = cases + 1;
    if ((p2 - p1) != BASE_PERIOD) begin
      $display("MISMATCH irq period after re-enable: %0d, expected %0d", p2 - p1, BASE_PERIOD);
      errors = errors + 1;
    end else $display("ok       irq resumed at timing 0 = %0d clk", p2 - p1);
    wr(16'h7FDF, 8'h09);   // quiet again

    // ==== 7. the packet/latch coincidence (R4 merge) =======================
    // Exactly one +1 packet races the latch edge; latch + live must sum to 1
    // whatever cycle the packet lands on - including the edge's own.
    for (k = 0; k < 9; k = k + 1) begin
      wr(16'h7FDD, 8'h90);   // a latch edge on zero: counters cleared
      wr(16'h7FDD, 8'h10);   // live mux armed for the collision write
      fork
        begin
          wr(16'h7FDD, 8'h90);   // THE latch edge racing the packet
        end
        begin
          repeat (k) @(negedge clk);
          packet(8'h01, 8'h00, 3'b011);
        end
      join
      rd1(16'h7FD9, v);      // portc is still 0x90: the latched X low nibble
      a = v & 8'h0F;
      wr(16'h7FDD, 8'h10);
      rd1(16'h7FD9, v);      // the live X low nibble
      b = v & 8'h0F;
      cases = cases + 1;
      if ((a + b) != 1 || a > 1 || b > 1) begin
        $display("MISMATCH coincidence k=%0d: latch %0d + live %0d != one packet", k, a, b);
        errors = errors + 1;
      end else $display("ok       coincidence k=%0d: latch %0d + live %0d = 1", k, a, b);
    end
    cases = cases + 1;
    if (collision_hits < 1) begin
      $display("MISMATCH coincidence sweep never hit the same cycle (%0d hits)", collision_hits);
      errors = errors + 1;
    end else $display("ok       the sweep hit the edge/packet same cycle %0d time(s)", collision_hits);

    // ==== 8. the Port C DIP strap nibble (mouseif.c:296-303) ==============
    // The low nibble is 0x08 | three bits COMPUTED from the software-DIP store, not a
    // constant: over the measured power-up image (0x841E = 0x7C, 0x8E1E = 0x49) all
    // three are 0, and the guest's own writes to 0x841E/0x8E1E move them - the same
    // live bytes those ports answer - with the ACTIVE bank selecting which bytes.
    wr(16'h7FDD, 8'h00);   // latch 0: the low nibble is then the whole strap byte
    rd_is(16'h7FDD, 8'h08, "power-up strap = 0x08 (the 0x7C/0x49 image gives 0x00)");
    wr(16'h8F1F, 8'h80);   // SDIP access enable, bank A (pc9821_iobus's 0x8F1F control)
    wr(16'h841E, 8'h0C);   // dipsw[0] bits 5:4 = 00 -> the strap's bits 1:0 = 3
    rd_is(16'h7FDD, 8'h0B, "a 0x841E write moves Port C bits 1:0 live");
    wr(16'h841E, 8'h3C);   // bits 5:4 = 11 -> the strap's bits 1:0 = 0 again
    rd_is(16'h7FDD, 8'h08, "...and back: the strap is ~dipsw[0] bits 5:4");
    wr(16'h8E1E, 8'h10);   // dipsw[2] bit 7 at 0x8E1E bit 4 -> the strap's bit 2
    rd_is(16'h7FDD, 8'h0C, "a 0x8E1E write moves Port C bit 2 live");
    wr(16'h8F1F, 8'hC0);   // bank B: its own 0x841E/0x8E1E bytes (0x8F/0x80)
    rd_is(16'h7FDD, 8'h0B, "the strap follows the bank select (bank B gives 0x0B)");
    wr(16'h8F1F, 8'h80);   // bank A again: the bytes bank A was left holding
    rd_is(16'h7FDD, 8'h0C, "back to bank A's stored bytes");

    // ==== VERDICT ====
    $display("NOTE tb_pc9821_mouse: %0d cases, %0d mismatched, sim %0t", cases, errors, $time);
    if (errors == 0) begin
      $display("TB_PC9821_MOUSE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_MOUSE: FAIL (%0d of %0d cases)", errors, cases);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_MOUSE: TIMEOUT");
  end

endmodule
