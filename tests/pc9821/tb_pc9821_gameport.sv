`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GAMEPORT:
// The game port at 0x1480-0x1487 answers through the real I/O bus as the card's register does: a write triggers all four axis one-shots, each clears after the delay its position asks for (measured in clk cycles against the IBM timed formula, and counted in reads for the count-on-read forms), the button lines are active low with stick 2's pair moving to stick 1 in 4-button mode, a disabled stick reads as absent (0xFF), and the same connector's six switch lines, which the sound board's OPNA register 0x0E answers, follow the D-pad.
//
// ---- the bench's own account of where each expectation comes from ----
// PROTOCOL. NP2kai cbus/board118.c:333-458 (the -118's SUPPORT_GAMEPORT block): any write
// restarts the axis one-shots, a read samples them, and the card attaches the same two
// handlers to all eight addresses (board118.c:816-822). The byte's layout and the
// position-to-delay arithmetic are the IBM game port's, as ao486's rtl/soc/joystick.v
// implements them -- the same reference z486_mister.sv took its joystick_* mapping from. Each
// timing expectation below is written as the FORMULA's own number (22 ticks at the near end,
// 22 + 502 at centre, 22 + 1000 at the far end, with 1000/255 expanded as 4 - 1/16 - 1/64 -
// 1/256), never as a number read out of the RTL, and a tick is 1.1 us = 55 clk at 50 MHz.
// SWITCH LINES. NP2kai sound/fmboard.c:54-90 fmboard_getjoy, the function every one of its
// OPNA boards returns from register 0x0E: six bits, active low, up/down/left/right and two
// buttons (it masks its result to 0x3F). The machine's /JOY capture holds that register idle
// at 0xFF with nothing pressed (docs/probes/JOY.TXT), which is the all-released switch byte.
//
// The bus is REAL here (pc9821_iobus's decode and pc9821_device_select's claim, wired as
// pc9821_system wires them), so the port claims and the byte are measured end to end. The
// DISCHARGE time is measured through the port's own strobes instead, because a bus access
// costs this core's 186-cycle I/O-wait class and would quantize a 1210-cycle discharge into
// whole accesses; the OR into the strobe is this harness's, and the core has only the bus.

module tb_pc9821_gameport;
  reg clk = 0;
  always #10 clk = ~clk;        // 50 MHz: the rate the module's own parameters assume
  reg reset = 1;

  // ==== DUT ====
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  // pc9821_iobus's ports, named because it is instantiated with (.*).
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
  reg        cal_cdat = 0;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg, egc_sft, egc_leng;
  wire        egc_shift_we;
  wire [3:0] top_bank;
  wire sound_extend, ide_rom_enable, bios_ram_gate, sys16m_en, a20_enable, cpu_reset_req;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
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
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
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

  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(0), .GAMEPORT_118(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // pc9821_system's device glue: the card's select (P5 made the ONE pc9821_device_select
  // instance live inside pc9821_iobus, so `.*` above binds gameport_cs to it), the game port
  // behind it, and the game port's byte as the only thing on that bus (0xFF otherwise).
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;

  // The port's own strobes, off the OR above. They are registered on the NEGEDGE rather than
  // assigned by the sequence: Verilator evaluates a combinational chain out of a same-delta
  // procedural assignment late, so a strobe set by the stimulus process in the delta of the
  // edge it must be seen at can be sampled stale. A negedge-clocked register is level at
  // every posedge by construction, and one strobe means exactly one posedge.
  reg gp_wr_req = 1'b0, gp_rd_req = 1'b0;
  reg gp_wr_q = 1'b0, gp_rd_q = 1'b0;
  always @(negedge clk) begin
    gp_wr_q <= gp_wr_req;
    gp_rd_q <= gp_rd_req;
  end
  wire gp_wr = (device_io_wr && gameport_cs) | gp_wr_q;
  wire gp_rd = (device_io_rd && gameport_cs) | gp_rd_q;
  wire [7:0] gameport_io_dout;
  wire [5:0] switch_lines;

  // The OSD controls and the framework's gamepad bits: joystick_0/1[13:0] and
  // joystick_l_analog_0/1, which z486_mister.sv maps onto these ports.
  reg  [1:0] dis = 2'b00, mode = 2'd0, timed = 2'd0;
  reg [13:0] dig_1 = 14'd0, dig_2 = 14'd0;
  reg [15:0] ana_1 = 16'd0, ana_2 = 16'd0;

  assign device_io_dout = gameport_cs ? gameport_io_dout : 8'hFF;
  assign device_rd_wait = 1'b0;   // both devices here answer in the strobe cycle

  pc9821_gameport #(.SYS_CLOCK_HZ(50_000_000)) gameport (
    .clk(clk), .reset(reset),
    .io_wr(gp_wr), .io_rd(gp_rd), .io_dout(gameport_io_dout),
    .dis(dis), .mode(mode), .timed(timed),
    .dig_1(dig_1), .dig_2(dig_2), .ana_1(ana_1), .ana_2(ana_2),
    .switch_lines(switch_lines)
  );

  integer errors = 0;
  integer reads_at_start = 0;
  integer cycles = 0;
  integer want_cycles = 0;
  integer n = 0;
  integer k;
  reg [7:0] b0;

  // ==== STIMULUS ====
  task automatic fail(input [8*128-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic rd8(input [15:0] portnum, output [7:0] data);
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

  task automatic wr8(input [15:0] portnum, input [7:0] data);
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
      cpu_be = 0;
      cpu_write = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // The port's own strobes, off the OR above (see the header).
  //
  // The four-clk settle before the strobe models the OSD, not the DUT: the module keeps
  // ONE discharge chain time-shared over the four axes, so a position must be stable for
  // four clk for all four load values to be current. A real joystick position is stable for
  // frames, but this bench sets dig_*/ana_* for its own convenience - sometimes in the same
  // instant it triggers - which the hardware never does. The settle is not part of the
  // measurement: the load is still the trigger edge, the clear is still `discharge` ticks
  // after it, and the count-on-read count is still exact, so this bench still pins the
  // serialization value- and timing-exact.
  task automatic gp_trigger;
    begin
      repeat (4) @(posedge clk);
      gp_wr_req = 1'b1;
      @(negedge clk);          // the strobe rises with this negedge
      @(posedge clk);          // the trigger edge: the four counters load
      gp_wr_req = 1'b0;
    end
  endtask

  task automatic gp_read(output [7:0] data);
    begin
      @(negedge clk);
      data = gameport_io_dout;   // the byte this read answers, before it steps the count down
      gp_rd_req = 1'b1;
      @(negedge clk);            // the strobe starts
      gp_rd_req = 1'b0;
      @(posedge clk);            // its one clk: the count steps down once
      @(negedge clk);            // the strobe ends
    end
  endtask

  // Wait until every one of the four one-shots has run out, so a section that expects idle
  // axes is not carrying an earlier trigger's discharge.
  task automatic axes_idle;
    begin
      cycles = 0;
      while (((gameport_io_dout & 8'h0F) != 8'd0) && cycles < 200_000) begin
        cycles = cycles + 1;
        @(posedge clk);
      end
    end
  endtask

  // Trigger, then count clk cycles until every bit in `mask` has cleared. `still` names bits
  // that must NOT have cleared yet, which is what tells the four one-shots apart.
  task automatic measure_clear(input [7:0] mask, input [7:0] still, input [8*70-1:0] what);
    begin
      gp_trigger;
      #1;                      // the loaded counters are visible a delta after the edge
      cycles = 0;
      while (((gameport_io_dout & mask) != 8'd0) && cycles < 200_000) begin
        cycles = cycles + 1;
        @(posedge clk);
        #1;                    // a decrement is visible a delta after its own edge
      end
      if ((gameport_io_dout & mask) != 8'd0) begin
        fail({what, ": the axis never cleared"});
      end else if ((gameport_io_dout & still) != still) begin
        fail({what, ": another axis cleared first"});
      end else if (cycles != want_cycles) begin
        $display("FAIL: %0s: cleared after %0d clk cycles, the formula asks %0d",
                 what, cycles, want_cycles);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_byte(input [7:0] want, input [8*70-1:0] what);
    begin
      #1;   // a combinational output settles on a delay, not on a blocking assign
      if (gameport_io_dout !== want) begin
        $display("FAIL: %0s: byte %02x, this bench asks %02x", what, gameport_io_dout, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_sw(input [5:0] want, input [8*70-1:0] what);
    begin
      #1;   // as check_byte: the switch byte is combinational off the same inputs
      if (switch_lines !== want) begin
        $display("FAIL: %0s: switch lines %06b, this bench asks %06b",
                 what, switch_lines, want);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- 1. the port decode, all eight addresses, through the real bus ----
    // The card's own claim: any of 0x1480-0x1487 (NP2kai board118.c:816-822). A neighbour is
    // NOT the card, and an untriggered one-shot reads its axes 0 with its buttons released.
    reads_at_start = unmapped_reads;
    for (k = 16'h1470; k <= 16'h1490; k = k + 1) begin
      rd8(k[15:0], b0);
      if (b0 !== 8'hFF && (k < 16'h1480 || k > 16'h1487))
        fail("a port outside 0x1480-0x1487 answered the game port");
      if (k == 16'h1480 && b0 !== 8'hF0) begin
        $display("FAIL: an untriggered game port read %02x, this bench asks F0", b0);
        errors = errors + 1;
      end
    end
    if (unmapped_reads != reads_at_start + 16'd25) begin
      $display("FAIL: 33 ports over 0x1470-0x1490 must leave 25 unmapped, %0d did not",
               unmapped_reads - reads_at_start);
      errors = errors + 1;
    end
    reads_at_start = unmapped_reads;

    // A WRITE is the trigger, and a read after it must show all four axes running down.
    wr8(16'h1480, 8'h00);
    rd8(16'h1487, b0);
    if (b0[3:0] !== 4'hF)
      fail("the last of the eight addresses did not show the triggered axes");
    if (unmapped_reads != reads_at_start)
      fail("a write to the game port was counted as unmapped traffic");

    // ---- 2. the button lines, active low ------------------------------------
    dis = 2'b00; mode = 2'd0; timed = 2'd0; dig_1 = 14'd0; dig_2 = 14'd0;
    axes_idle;
    dig_1[4] = 1'b1;
    check_byte(8'hE0, "stick 1 button 1 held");
    dig_1[4] = 1'b0; dig_1[5] = 1'b1;
    check_byte(8'hD0, "stick 1 button 2 held");
    dig_1 = 14'd0; dig_2[4] = 1'b1;
    check_byte(8'hB0, "stick 2 button 1 held, 2-button mode");
    dig_2[4] = 1'b0; dig_2[5] = 1'b1;
    check_byte(8'h70, "stick 2 button 2 held, 2-button mode");
    // 4 buttons: stick 1's third and fourth move into those two bits, and stick 2's
    // buttons stop appearing there.
    mode = 2'd1; dig_2 = 14'd0; dig_1[6] = 1'b1;
    check_byte(8'hB0, "stick 1's third button in 4-button mode");
    dig_1[6] = 1'b0; dig_1[7] = 1'b1;
    check_byte(8'h70, "stick 1's fourth button in 4-button mode");
    dig_1 = 14'd0; dig_2[4] = 1'b1;
    check_byte(8'hF0, "stick 2's buttons in 4-button mode");
    // None: the port answers open bus, stick or no stick.
    mode = 2'd3;
    check_byte(8'hFF, "Joystick Type = None");

    // ---- 3. a disabled stick reads as ABSENT --------------------------------
    // Every line of both sticks held, so the four bits each stick owns are 0 unless its
    // disable forces them high: stick 2's axis and button bits, then stick 1's.
    mode = 2'd0; dig_1 = 14'h3FFF; dig_2 = 14'h3FFF;
    check_byte(8'h00, "both sticks live, every line held");
    dis = 2'b10;
    check_byte(8'hCC, "stick 2 disabled with every line held");
    dis = 2'b01;
    check_byte(8'h33, "stick 1 disabled with every line held");
    dis = 2'b11;
    check_byte(8'hFF, "both sticks disabled");
    dis = 2'b00; dig_1 = 14'd0; dig_2 = 14'd0;

    // ---- 4. the IBM timed form, in clk cycles ------------------------------
    // The discharge for a position is 22 + (1000/255)*position ticks of 55 clk, with
    // 1000/255 expanded as 4 - 1/16 - 1/64 - 1/256: 22 at the near end, 524 at centre,
    // 1022 at the far end. The second axis of each trigger must still be running, which is
    // what says the four one-shots are independent.
    timed = 2'd0; mode = 2'd0; dis = 2'b00; ana_1 = 16'd0; ana_2 = 16'd0;
    dig_1 = 14'b0000_0000_0000_0010;    // left: X at its near end, Y centred
    want_cycles = 22 * 55;
    measure_clear(8'h01, 8'h02, "X at the near end (position 0)");
    want_cycles = 524 * 55;
    measure_clear(8'h02, 8'h00, "Y centred, same stick");
    dig_1 = 14'b0000_0000_0000_0001;    // right: X at its far end
    want_cycles = 524 * 55;
    measure_clear(8'h02, 8'h01, "Y centred while X is at its far end");
    want_cycles = 1022 * 55;
    measure_clear(8'h01, 8'h00, "X at the far end (position 255)");
    dig_1 = 14'd0;                      // centred
    want_cycles = 524 * 55;
    measure_clear(8'h01, 8'h00, "X centred (position 128)");

    // The analog stick, two deflections: +64 maps to position 192 (22 + 753 = 775 ticks) and
    // -64 to position 64 (22 + 251 = 273), so a plausible wrong scale fails here.
    ana_1 = {8'h00, 8'h40};             // x = +64
    repeat (4) @(posedge clk);          // let the source latch settle
    want_cycles = 775 * 55;
    measure_clear(8'h01, 8'h00, "X from the analog stick at +64");
    ana_1 = {8'h00, 8'hC0};             // x = -64
    repeat (4) @(posedge clk);
    want_cycles = 273 * 55;
    measure_clear(8'h01, 8'h00, "X from the analog stick at -64");
    // A D-pad direction while the analog stick is deflected keeps the analog source, which is
    // ao486's latch: the player's last deliberate control wins.
    dig_1 = 14'b0000_0000_0000_0001;    // right, which alone would be position 255
    repeat (4) @(posedge clk);
    want_cycles = 273 * 55;
    measure_clear(8'h01, 8'h00, "the deflected analog stick still wins over the D-pad");
    // And the D-pad is the source again once the stick is centred.
    dig_1 = 14'd0; ana_1 = 16'd0;
    repeat (4) @(posedge clk);
    dig_1 = 14'b0000_0000_0000_0001;    // right
    repeat (4) @(posedge clk);
    want_cycles = 1022 * 55;
    measure_clear(8'h01, 8'h00, "the D-pad again once the analog stick is centred");

    // ---- 5. the count-on-read forms ----------------------------------------
    // The bit is 1 for the count's worth of READS and clears on the next one, which is how a
    // game that counts reads measures. Centre is position 128.
    timed = 2'd2;                       // Count 0+256: the count IS the position
    dig_1 = 14'd0; ana_1 = 16'd0;
    gp_trigger;
    n = 0; gp_read(b0);
    while (((b0 & 8'h01) != 8'd0) && n < 2000) begin
      n = n + 1;
      gp_read(b0);
    end
    if (b0[0] != 1'b0 || n != 128) begin
      $display("FAIL: Timed=0+256 centred: %0d reads saw the bit, this bench asks 128", n);
      errors = errors + 1;
    end
    timed = 2'd1;                       // Count 8+141: 8 + pos/2 + pos/16 - 2*(pos/128)
    gp_trigger;
    n = 0; gp_read(b0);
    while (((b0 & 8'h01) != 8'd0) && n < 2000) begin
      n = n + 1;
      gp_read(b0);
    end
    if (b0[0] != 1'b0 || n != 78) begin
      $display("FAIL: Timed=8+141 centred: %0d reads saw the bit, this bench asks 78", n);
      errors = errors + 1;
    end
    timed = 2'd3;                       // Count 6+256: 6 + pos
    gp_trigger;
    n = 0; gp_read(b0);
    while (((b0 & 8'h01) != 8'd0) && n < 2000) begin
      n = n + 1;
      gp_read(b0);
    end
    if (b0[0] != 1'b0 || n != 134) begin
      $display("FAIL: Timed=6+256 centred: %0d reads saw the bit, this bench asks 134", n);
      errors = errors + 1;
    end
    // Count 0+256 is the position itself, so the near end has nothing to count: the FIRST
    // read after the trigger already sees the bit clear.
    timed = 2'd2;
    dig_1 = 14'b0000_0000_0000_0010;    // left, position 0
    gp_trigger;
    gp_read(b0);
    if (b0[0] != 1'b0)
      fail("Count 0+256 at the near end still reported a running axis");

    // ---- 6. the sound board's switch lines ---------------------------------
    // Six level lines off the same connector, which the OPNA's register 0x0E returns
    // (NP2kai fmboard_getjoy). Bit 0 is up, 1 down, 2 left, 3 right, 4 and 5 the two
    // buttons. The un-driven state is "nothing pressed", the machine's 0xFF /JOY byte.
    timed = 2'd0; mode = 2'd0; dis = 2'b00; dig_1 = 14'd0; dig_2 = 14'd0; ana_1 = 16'd0;
    check_sw(6'b111111, "nothing pressed");
    dig_1[3] = 1'b1;  check_sw(6'b111110, "up");
    dig_1 = 14'd0; dig_1[2] = 1'b1;  check_sw(6'b111101, "down");
    dig_1 = 14'd0; dig_1[1] = 1'b1;  check_sw(6'b111011, "left");
    dig_1 = 14'd0; dig_1[0] = 1'b1;  check_sw(6'b110111, "right");
    dig_1 = 14'd0; dig_1[4] = 1'b1;  check_sw(6'b101111, "button 1");
    dig_1 = 14'd0; dig_1[5] = 1'b1;  check_sw(6'b011111, "button 2");
    dig_1 = 14'h3FFF;                check_sw(6'b000000, "every line held");
    // An analog stick closes no switch, so a deflected one leaves all six released.
    dig_1 = 14'd0; ana_1 = {8'h7F, 8'h7F};
    repeat (4) @(posedge clk);
    check_sw(6'b111111, "the analog stick deflected, which closes no switch");
    // Stick 2's lines are not this connector's, and a disabled stick reads released.
    ana_1 = 16'd0; dig_2 = 14'h3FFF;
    repeat (4) @(posedge clk);
    check_sw(6'b111111, "stick 2 held, which is not this connector");
    dig_2 = 14'd0; dig_1 = 14'h3FFF; dis = 2'b01;
    check_sw(6'b111111, "stick 1 held but disabled");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GAMEPORT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GAMEPORT: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: the discharge measurements together are about 250k clk cycles.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_GAMEPORT: TIMEOUT");
  end

endmodule
