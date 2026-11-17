`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PORTS_SWEEP: every port the real PC-9821Xe10's own port sweep captured (docs/probes/PORTS.TXT BEGIN:PORTS, 218 ports: 0x0000-0x005B, 0x00F0-0x00FF, 0x0120-0x014B, 0x0180-0x018B, 0x01F0-0x01FF, 0x0431-0x043F, 0x053C-0x053F, 0x063D-0x0640, 0x0740-0x074B, 0x0F40-0x0F46 and the SDIP bytes 0x841E-0x931E and 0x8F1F) is read through the real pc9821_iobus straight out of reset, with no write first: the 194 ports the fabric answers itself read the machine's byte exactly, open-bus FF and fixed straps alike, 0x0033 reads it under a mask of its live calendar-data bit 0, the 18 device-bus ports (the 8259 pair, the calendar, the keyboard 8251, the OPNA, the IDE task file and its 0x074x mirror) are routed to the device bus rather than answered by the fabric (their bytes belong to those devices' benches), and the five rows whose captured byte is not a power-up value - 0x0025 (DOS's own uPD71071 programming), 0x00F2 (A20 opened by DOS), 0x0439 (the ITF's cold-start write), 0x053D (the firmware's writable-BIOS-copy bit) and 0x861E (the user's Floppy-mode SDIP setting, where the OSD default is 0xF7) - are named and printed, not asserted.
//
// WHY THIS BENCH EXISTS. tb_pc9821_open_ports asserts open bus at two sites, and
// tb_pc9821_system_integration asserts the R10.TXT rows the core decodes; neither walks
// the machine's whole sweep, so a wrong default or a stray decode arm at any other
// captured port went unnoticed. This bench takes EVERY row of the capture: the table below
// is PORTS.TXT's BEGIN:PORTS section transcribed row for row (port, byte; a port the probe
// read twice read the same byte both times), and each row carries its class:
//   A  the fabric answers it; assert the machine's byte exactly.
//   M  the same, under a mask: 0x0033 bit 0 is the calendar's serial data line (CDAT),
//      live at capture time and an input here (tb_pc9821_system_integration drives it).
//   D  a device-bus port (pc9821_device_select names a device for it): assert it is
//      ROUTED to the device bus (device_io_rd seen, the fabric's stub byte 0xC3 returned),
//      so the fabric neither answers it itself nor drops it; the byte is the device's.
//   S  the captured byte is the DOS prompt's STATE, not a power-up value, so it is
//      printed beside the core's power-up byte and not asserted; each has its reason
//      in state_reason() below and a bench that covers it with the state applied.
// The capture is a DOS-prompt snapshot (the probe runs from DOS), so A is a claim that
// the byte is the same at power-up and at the prompt: true for open bus, write-only
// ports and straps, which is what these rows are. The ports the capture did not take
// (0x0060-0x00EF, 0x0020) are outside this bench.

module tb_pc9821_ports_sweep;
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
  wire sys16m_en;
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
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire [1:0] ems_state;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  // ==== DUT ====
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
  wire        dma_mem_load_we;   // pc9821_iobus dma_mem_load_we (the loading byte is a store); unread here
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
  // This bench's own decode below is driven independently, so these are named for the
  // wildcard instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);


  // ==== STIMULUS ====
  reg [15:0] probe_port = 16'h0000;
  reg  [7:0] got = 8'h00;
  reg        saw_device_rd = 1'b0;
  integer    dev_rds = 0;          // device-bus read strobes seen, one writer
  integer    dev_rds_before = 0;
  always @(posedge clk) if (device_io_rd) dev_rds <= dev_rds + 1;

  integer errors = 0;
  task automatic fail(input [8*100-1:0] message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  // One CPU byte read of probe_port, exactly as tb_pc9821_system_integration reads one.
  task automatic read_port;
    reg [1:0] lane;
    integer waited;
    begin
      lane = probe_port[1:0];
      @(negedge clk);
      dev_rds_before = dev_rds;
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
      @(negedge clk);   // dev_rds is registered
      saw_device_rd = (dev_rds != dev_rds_before);
    end
  endtask

  // docs/probes/PORTS.TXT BEGIN:PORTS, row for row: {port, the machine's byte, class}.
  localparam integer NROW = 218;
  typedef struct packed { logic [15:0] port; logic [7:0] machine; logic [7:0] cls; } row_t;
  localparam row_t ROWS [0:NROW-1] = '{
    {16'h0000, 8'h00, "D"}, {16'h0001, 8'h00, "A"}, {16'h0002, 8'h7D, "D"}, {16'h0003, 8'h00, "A"},
    {16'h0004, 8'hFF, "A"}, {16'h0005, 8'h00, "A"}, {16'h0006, 8'hFF, "A"}, {16'h0007, 8'h00, "A"},
    {16'h0008, 8'h00, "D"}, {16'h0009, 8'h00, "A"}, {16'h000A, 8'h75, "D"}, {16'h000B, 8'h00, "A"},
    {16'h000C, 8'hFF, "A"}, {16'h000D, 8'h00, "A"}, {16'h000E, 8'hFF, "A"}, {16'h000F, 8'h00, "A"},
    {16'h0010, 8'hFF, "A"}, {16'h0011, 8'h00, "A"}, {16'h0012, 8'hFF, "A"}, {16'h0013, 8'hFF, "A"},
    {16'h0014, 8'hFF, "A"}, {16'h0015, 8'hFF, "A"}, {16'h0016, 8'hFF, "A"}, {16'h0017, 8'hFF, "A"},
    {16'h0018, 8'hFF, "A"}, {16'h0019, 8'hFF, "A"}, {16'h001A, 8'hFF, "A"}, {16'h001B, 8'h00, "A"},
    {16'h001C, 8'hFF, "A"}, {16'h001D, 8'hFF, "A"}, {16'h001E, 8'hFF, "A"}, {16'h001F, 8'hFF, "A"},
    {16'h0021, 8'h00, "A"}, {16'h0022, 8'hEF, "D"}, {16'h0023, 8'h00, "A"}, {16'h0024, 8'hFF, "A"},
    {16'h0025, 8'h0E, "S"}, {16'h0026, 8'hFF, "A"}, {16'h0027, 8'h00, "A"}, {16'h0028, 8'hFF, "A"},
    {16'h0029, 8'h00, "A"}, {16'h002A, 8'hFF, "A"}, {16'h002B, 8'hFF, "A"}, {16'h002C, 8'hFF, "A"},
    {16'h002D, 8'hFF, "A"}, {16'h002E, 8'hFF, "A"}, {16'h002F, 8'hFF, "A"}, {16'h0030, 8'hFF, "A"},
    {16'h0031, 8'hF3, "A"}, {16'h0032, 8'h45, "A"}, {16'h0033, 8'hF9, "M"}, {16'h0034, 8'hFF, "A"},
    {16'h0035, 8'hB8, "A"}, {16'h0036, 8'hFF, "A"}, {16'h0037, 8'hFF, "A"}, {16'h0038, 8'hFF, "A"},
    {16'h0039, 8'hFF, "A"}, {16'h003A, 8'hFF, "A"}, {16'h003B, 8'hFF, "A"}, {16'h003C, 8'hFF, "A"},
    {16'h003D, 8'hFF, "A"}, {16'h003E, 8'hFF, "A"}, {16'h003F, 8'hFF, "A"}, {16'h0040, 8'h00, "A"},
    {16'h0041, 8'h9C, "D"}, {16'h0042, 8'h94, "A"}, {16'h0043, 8'h85, "D"}, {16'h0044, 8'h81, "A"},
    {16'h0045, 8'hFF, "A"}, {16'h0046, 8'hFF, "A"}, {16'h0047, 8'hFF, "A"}, {16'h0048, 8'hFF, "A"},
    {16'h0049, 8'hFF, "A"}, {16'h004A, 8'hFF, "A"}, {16'h004B, 8'hFF, "A"}, {16'h004C, 8'hFF, "A"},
    {16'h004D, 8'hFF, "A"}, {16'h004E, 8'hFF, "A"}, {16'h004F, 8'hFF, "A"}, {16'h0050, 8'hFF, "A"},
    {16'h0051, 8'hFF, "A"}, {16'h0052, 8'hFF, "A"}, {16'h0053, 8'hFF, "A"}, {16'h0054, 8'hFF, "A"},
    {16'h0055, 8'hFF, "A"}, {16'h0056, 8'hFF, "A"}, {16'h0057, 8'hFF, "A"}, {16'h0058, 8'hFF, "A"},
    {16'h0059, 8'hFF, "A"}, {16'h005A, 8'hFF, "A"}, {16'h005B, 8'hFF, "A"}, {16'h00F0, 8'hA9, "A"},
    {16'h00F1, 8'hFF, "A"}, {16'h00F2, 8'hFE, "S"}, {16'h00F3, 8'hFF, "A"}, {16'h00F4, 8'hFC, "A"},
    {16'h00F5, 8'hFF, "A"}, {16'h00F6, 8'h5E, "A"}, {16'h00F7, 8'hFF, "A"}, {16'h00F8, 8'hFF, "A"},
    {16'h00F9, 8'hFF, "A"}, {16'h00FA, 8'hFF, "A"}, {16'h00FB, 8'hFF, "A"}, {16'h00FC, 8'hFF, "A"},
    {16'h00FD, 8'hFF, "A"}, {16'h00FE, 8'hFF, "A"}, {16'h00FF, 8'hFF, "A"}, {16'h0120, 8'hFF, "A"},
    {16'h0121, 8'hFF, "A"}, {16'h0122, 8'hFF, "A"}, {16'h0123, 8'hFF, "A"}, {16'h0124, 8'hFF, "A"},
    {16'h0125, 8'hFF, "A"}, {16'h0126, 8'hFF, "A"}, {16'h0127, 8'hFF, "A"}, {16'h012A, 8'hFF, "A"},
    {16'h012B, 8'hFF, "A"}, {16'h0130, 8'hFF, "A"}, {16'h0131, 8'hFF, "A"}, {16'h0132, 8'hFF, "A"},
    {16'h0133, 8'hFF, "A"}, {16'h0134, 8'h0F, "A"}, {16'h0135, 8'hFF, "A"}, {16'h0140, 8'hFF, "A"},
    {16'h0141, 8'hFF, "A"}, {16'h0142, 8'hFF, "A"}, {16'h0143, 8'hFF, "A"}, {16'h0144, 8'hFF, "A"},
    {16'h0145, 8'hFF, "A"}, {16'h0146, 8'hFF, "A"}, {16'h0147, 8'hFF, "A"}, {16'h0148, 8'hFF, "A"},
    {16'h0149, 8'h00, "A"}, {16'h014A, 8'hFF, "A"}, {16'h014B, 8'hFF, "A"}, {16'h0180, 8'hFF, "A"},
    {16'h0181, 8'hFF, "A"}, {16'h0182, 8'hFF, "A"}, {16'h0183, 8'hFF, "A"}, {16'h0188, 8'h03, "D"},
    {16'h0189, 8'hFF, "A"}, {16'h018A, 8'h00, "D"}, {16'h018B, 8'hFF, "A"}, {16'h01F0, 8'hFF, "A"},
    {16'h01F1, 8'hFF, "A"}, {16'h01F2, 8'hFF, "A"}, {16'h01F3, 8'hFF, "A"}, {16'h01F4, 8'hFF, "A"},
    {16'h01F5, 8'hFF, "A"}, {16'h01F6, 8'hFF, "A"}, {16'h01F7, 8'hFF, "A"}, {16'h01F8, 8'hFF, "A"},
    {16'h01F9, 8'hFF, "A"}, {16'h01FA, 8'hFF, "A"}, {16'h01FB, 8'hFF, "A"}, {16'h01FC, 8'hFF, "A"},
    {16'h01FD, 8'hFF, "A"}, {16'h01FE, 8'hFF, "A"}, {16'h01FF, 8'hFF, "A"}, {16'h0431, 8'hFF, "A"},
    {16'h0432, 8'h00, "D"}, {16'h0434, 8'hBE, "A"}, {16'h0435, 8'h00, "D"}, {16'h0436, 8'h04, "A"},
    {16'h0437, 8'hFF, "A"}, {16'h0438, 8'hFF, "A"}, {16'h0439, 8'hB4, "S"}, {16'h043A, 8'hFF, "A"},
    {16'h043B, 8'hFB, "A"}, {16'h043C, 8'hFF, "A"}, {16'h043D, 8'hFF, "A"}, {16'h043E, 8'hFF, "A"},
    {16'h043F, 8'hC4, "A"}, {16'h053C, 8'hFF, "A"}, {16'h053D, 8'h1F, "S"}, {16'h053E, 8'hFC, "A"},
    {16'h053F, 8'hFF, "A"}, {16'h063D, 8'hEC, "A"}, {16'h063E, 8'hFE, "A"}, {16'h063F, 8'h6C, "A"},
    {16'h0640, 8'h0E, "D"}, {16'h0740, 8'h0F, "D"}, {16'h0741, 8'hFF, "A"}, {16'h0742, 8'h0F, "D"},
    {16'h0743, 8'hFF, "A"}, {16'h0744, 8'h0F, "D"}, {16'h0745, 8'hFF, "A"}, {16'h0746, 8'h0F, "D"},
    {16'h0747, 8'hFF, "A"}, {16'h0748, 8'h0F, "D"}, {16'h0749, 8'hFF, "A"}, {16'h074A, 8'h0F, "D"},
    {16'h074B, 8'hFF, "A"}, {16'h0F40, 8'hFF, "A"}, {16'h0F41, 8'hFF, "A"}, {16'h0F42, 8'hFF, "A"},
    {16'h0F43, 8'hFF, "A"}, {16'h0F44, 8'hFF, "A"}, {16'h0F45, 8'hFF, "A"}, {16'h0F46, 8'hFF, "A"},
    {16'h841E, 8'h7C, "A"}, {16'h841F, 8'hFF, "A"}, {16'h851E, 8'h02, "A"}, {16'h861E, 8'h76, "S"},
    {16'h871E, 8'h3E, "A"}, {16'h881E, 8'h7C, "A"}, {16'h891E, 8'h7F, "A"}, {16'h8A1E, 8'hFF, "A"},
    {16'h8B1E, 8'hBF, "A"}, {16'h8C1E, 8'h7F, "A"}, {16'h8D1E, 8'h7F, "A"}, {16'h8E1E, 8'h49, "A"},
    {16'h8F1E, 8'h98, "A"}, {16'h901E, 8'hFF, "A"}, {16'h911E, 8'hFF, "A"}, {16'h921E, 8'hFF, "A"},
    {16'h931E, 8'hFF, "A"}, {16'h8F1F, 8'hFF, "A"}
  };

  // Why an S row's captured byte is not a power-up value, and where it is covered.
  function automatic [8*120-1:0] state_reason(input [15:0] port);
    case (port)
      16'h0025: state_reason = "DOS's own uPD71071 channel programming (R10.TXT's 0E); the chip resets 00 (tb_pc9821_system_integration)";
      16'h00F2: state_reason = "A20 opened by DOS; the core resets it masked (tb_pc9821_system_integration writes 0xF2 first)";
      16'h0439: state_reason = "the ITF's cold-branch write 0xB4 (BANK4@0x40EC); 00 out of reset (tb_pc9821_system_integration)";
      16'h053D: state_reason = "the firmware's writable-BIOS-copy bit; the core resets it clear (tb_pc9821_system_integration)";
      16'h861E: state_reason = "the user's Floppy-mode SDIP byte; the OSD default Auto (1M) is 0xF7 (tb_pc9821_floppy_mode)";
      default:  state_reason = "(no reason recorded)";
    endcase
  endfunction

  // ==== CHECKS ====
  integer i;
  integer n_a = 0, n_m = 0, n_d = 0, n_s = 0;
  reg [15:0] port;
  reg  [7:0] machine;
  reg  [7:0] cls;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    for (i = 0; i < NROW; i = i + 1) begin
      port    = ROWS[i].port;
      machine = ROWS[i].machine;
      cls     = ROWS[i].cls;
      probe_port = port;
      read_port;
      case (cls)
        "A": begin
          n_a = n_a + 1;
          if (saw_device_rd)
            $display("MISMATCH port %04x: the machine's byte %02x is answered by the fabric, but the read went to the device bus", port, machine);
          if (got !== machine || saw_device_rd) begin
            $display("MISMATCH port %04x: core reads %02x at power-up, the machine reads %02x (PORTS.TXT)", port, got, machine);
            errors = errors + 1;
          end
        end
        "M": begin
          n_m = n_m + 1;
          if (((got ^ machine) & 8'hFE) != 8'h00 || saw_device_rd) begin
            $display("MISMATCH port %04x: core reads %02x, the machine reads %02x outside the live calendar-data bit 0 (PORTS.TXT)", port, got, machine);
            errors = errors + 1;
          end
        end
        "D": begin
          n_d = n_d + 1;
          if (!saw_device_rd || got !== device_io_dout) begin
            $display("MISMATCH port %04x: a device-bus port was answered by the fabric (%02x, device read %0d), not routed to its device", port, got, saw_device_rd);
            errors = errors + 1;
          end
        end
        "S": begin
          n_s = n_s + 1;
          $display("STATE    port %04x: core %02x at power-up, machine %02x at the DOS prompt - %0s", port, got, machine, state_reason(port));
        end
        default: fail("a table row carries an unknown class");
      endcase
    end

    $display("PORTS-SWEEP rows=%0d asserted=%0d masked=%0d device=%0d state=%0d", NROW, n_a, n_m, n_d, n_s);
    if (n_a != 194 || n_m != 1 || n_d != 18 || n_s != 5)
      fail("the table's class counts are not the claim's 194 / 1 / 18 / 5");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PORTS_SWEEP: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PORTS_SWEEP: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PORTS_SWEEP: TIMEOUT");
  end

endmodule
