// ==== WHAT THIS PROVES ====
// Tests that a port this core does not implement reads 0xFF, which is what the MACHINE answers, at two sites taken from the machine's own capture: an address in neither decode list, and the 0x04A0-0x04AF range the core decodes explicitly as 0xFF with a comment calling it accidentally right. docs/probes/PORTS.TXT records 04A0 through 04AF all reading FF, and the low open-bus ports 0012 through 001A likewise, so the expectation is the machine's rather than the RTL's - which matters here because the explicit 0x04A0 case exists only because the value "was accidentally right", and nothing would notice a cleanup that dropped it or a default that returned 0x00.
//
// ---- the bench's own account of where each expectation comes from ----
//
// The PC-98 answers an address no device drives with open bus, which on this
// machine reads 0xFF. Two independent sources in this tree say so:
//
//   [measured] docs/probes/PORTS.TXT, a real PC-9821Xe10, in the
//     BEGIN:PORTS section: every port from 04A0 to 04AF reads FF, and the low
//     range 0012..001A reads FF as well. Those are captures, not models.
//
//   [from-a-dump] the BIOS's option-ROM scan depends on it: it needs a byte
//     that is not the 0xAA55 signature, and the absent ROM area supplies 0xFF
//     (docs/probes/WIN.TXT, the 0461=0C line).
//
// So the contract is the machine's, and this bench pins it in two places:
//
//   1. a port in NEITHER decode list - 0x1235, chosen because nothing in the
//      firmware touches it and no case in pc9821_iobus.sv mentions it, so it
//      reaches the default arm. A default that returned 0x00 would fail here,
//      and that is the fails-first break this bench was verified with.
//
//   2. the 0x04A0-0x04AF range, which pc9821_iobus.sv decodes explicitly as
//      8'hFF with the comment "0xFF this core already answered was accidentally
//      right; it stays". The machine agrees with the VALUE, so this is not a
//      divergence - but the case exists for an accidental reason, and a future
//      reader removing it as redundant would be removing a statement about the
//      machine. Both the explicit arm and the default answer 0xFF today, so
//      only the VALUE is asserted here and not which arm produced it: an
//      assertion about the route taken would be a statement about the RTL.
//
// What this bench does NOT cover, stated rather than implied: nothing here is
// about timing, and nothing here distinguishes a decoded port from an undecoded
// one. The accounting side (unmapped_reads, last_unmapped_port) is asserted by
// tb_pc9821_iobus.sv's own open-bus case, and the access-time contract is
// tb_pc9821_io_wait.sv's.

`timescale 1ns/1ps

module tb_pc9821_open_ports;
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
  reg [7:0] device_io_dout = 8'hC3;
  reg       device_rd_wait = 1'b0;
  wire [3:0] top_bank;
  wire sound_extend;
  wire ide_rom_enable, bios_ram_gate;
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
  reg        cal_cdat = 0;
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  integer     egc_shift_pulses = 0;

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

  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // ==== CHECKS ====

  integer errors = 0;

  // One byte read of `port`, using the request idiom the bus actually takes:
  // cpu_addr carries the BASE address with the low two bits forced to zero and
  // the LANE rides in cpu_be. Passing the port number as the address instead
  // makes the bus answer a different port - tb_pc9821_io_wait.sv's first version
  // measured nothing that way, which is why the idiom is spelled out here too.
  // The task takes NO arguments, mirroring tb_pc9821_io_wait.sv's measure_port,
  // which is the pattern in this tree that verilator accepts. The port goes in
  // through `probe_port` and the byte comes back in `got`.
  reg [15:0] probe_port = 16'h0000;
  reg [7:0]  got = 8'h00;

  task automatic read_port;
    reg [1:0] lane;
    integer waited;
    begin
      lane = probe_port[1:0];
      @(negedge clk);
      cpu_addr  = {16'd0, probe_port[15:2], 2'b00};
      cpu_be    = 4'b0001 << lane;
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      waited = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        waited = waited + 1;
        if (waited > 1000) begin
          $display("FAIL port %04x never became ready", probe_port);
          errors = errors + 1;
          cpu_valid = 1'b0;
          cpu_be    = 4'b0;
          return;
        end
      end
      #1;
      got = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  integer   i;
  reg [15:0] p;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // 1. an address in NEITHER decode list reaches the default arm, and the
    //    machine's answer for an undriven address is open bus = 0xFF.
    probe_port = 16'h1235; read_port;
    $display("  open port 1235 -> %02x (the machine answers FF)", got);
    if (got !== 8'hFF) begin
      $display("FAIL port 1235 reads %02x, not the machine's open bus 0xFF: an undecoded address must not read as something a device would drive",
               got);
      errors = errors + 1;
    end

    // 2. every port in 0x04A0-0x04AF, all of which the machine reads as FF
    //    (docs/probes/PORTS.TXT, BEGIN:PORTS).
    for (i = 0; i < 16; i = i + 1) begin
      p = 16'h04A0 + i[15:0];
      probe_port = p; read_port;
      if (got !== 8'hFF) begin
        $display("FAIL port %04x reads %02x, not the machine's FF (docs/probes/PORTS.TXT records 04A0..04AF all FF)",
                 p, got);
        errors = errors + 1;
      end
    end
    $display("  open ports 04A0..04AF -> all FF, as the machine's capture has them");

    // 3. and the low range the capture also records as open bus, sampled rather
    //    than exhaustively: 0012..001A are FF on the machine.
    for (i = 0; i < 9; i = i + 1) begin
      p = 16'h0012 + i[15:0];
      probe_port = p; read_port;
      if (got !== 8'hFF) begin
        $display("FAIL port %04x reads %02x, not the machine's FF (docs/probes/PORTS.TXT records 0012..001A as FF)",
                 p, got);
        errors = errors + 1;
      end
    end
    $display("  open ports 0012..001A -> all FF, as the machine's capture has them");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPEN_PORTS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPEN_PORTS: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_OPEN_PORTS: TIMEOUT");
  end

endmodule
