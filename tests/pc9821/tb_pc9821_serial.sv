`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The PC-9821 serial port is NOT modelled: at NP2kai io/serial.c's RS-232C register addresses -- the uPD8251A data port 0x30, its status/control port 0x32, and the FIFO extension's 0x130/0x132/0x134/0x136/0x138/0x13A -- this core answers open bus 0xFF (0x30 and the FIFO ports are neither device ports nor system ports, so the I/O bus never strobes a device and the open bus reaches the CPU) or an unrelated fixed system strap (0x32 reads 0x45, 0x134 reads 0x0F), where NP2kai's 8251 answers its own reset register state (0x30 = 0xFF data register, 0x32 = 0x85 status) and the FIFO registers their reset values (0x132 = 0x83, 0x134 = 0xF0, 0x136 = 0x41, 0x138 = 0x00, 0x13A = 0x00). Every NP2kai case is recorded by value and printed as a WAIVED line: the RTL facts the core does answer are asserted, the absent serial registers are documented, and the bench stands as the conformance target for whenever the port is implemented. It is a GAP, not a correctness bug -- pc9821_system.sv:1182 already says "no serial port is modelled" and leaves the PIT channel-2 baud clock unconnected.

module tb_pc9821_serial;
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
  // tools/check_wiring.py enforces that.
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
  // A sentinel, so a port that reached the device fabric would be visible: the
  // serial addresses must read 0xFF, not this byte (see open_ports for the idiom).
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
  integer     egc_shift_pulses = 0;

  // ==== DUT ====
  wire [1:0] ems_state;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire fdc_irq;
  wire fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

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

  integer errors = 0, cases = 0, waivers = 0;
  reg [7:0]  got;
  reg        dev_seen;   // device_io_rd asserted at any point during the read
  reg [15:0] probe_port;
  reg [7:0]  probe_data;

  // The reference for every NP2kai value below is NP2kai io/serial.c (RS-232C):
  // reset rs232c_reset() :800 sets result=0x05, data=0xFF, cmd=0x27, mul=160;
  // 0x30 rs232c_i30 :714, 0x32 rs232c_i32 :745, 0x130 rs232c_i30 FIFO arm :722,
  // 0x132 rs232c_i132 :772, 0x134 rs232c_i134 :797, 0x136 rs232c_i136 :830,
  // 0x138 rs232c_i138 :874, 0x13A rs232c_i13a :925.
  function automatic [7:0] np2kai_reset(input [15:0] port);
    case (port)
      16'h0030: np2kai_reset = 8'hFF;   // data register, rs232c.data
      16'h0032: np2kai_reset = 8'h85;   // result 0x05 | 0x80 (rs232c_stat()==0)
      16'h0130: np2kai_reset = 8'hFF;   // FIFO data register
      16'h0132: np2kai_reset = 8'h83;   // ((result>>2)&1)|((result<<1)&6) | 0x80
      16'h0134: np2kai_reset = 8'hF0;   // ~CD|~CI|~DR|~CS, lastret=0
      16'h0136: np2kai_reset = 8'h41;   // port136 ^= 0x40; |0x1 (no irqflag)
      16'h0138: np2kai_reset = 8'h00;   // rs232cfifo.port138
      16'h013A: np2kai_reset = 8'h00;   // rs232cfifo.vfast
      default:  np2kai_reset = 8'hFF;
    endcase
  endfunction

  task automatic check(input [8*40-1:0] name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%04x want=0x%04x", name, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = 0x%04x", name, got);
    end
  endtask

  // An NP2kai serial register this core does not implement. PRINT the bytes and count
  // a waiver; the core answers neither the register nor its side effects, so there is
  // nothing to assert. This is the port's whole contract recorded as a divergence.
  task automatic waive(input [8*40-1:0] name, input [15:0] got, input [15:0] np2);
    begin
      cases = cases + 1;
      waivers = waivers + 1;
      $display("WAIVED   %0s: rtl=0x%04x np2kai=0x%04x (absent serial register)", name, got, np2);
    end
  endtask

  // One byte read of probe_port, CPU-side, the idiom open_ports uses: the base
  // address with the low two bits zero and the lane in cpu_be. dev_seen latches
  // device_io_rd so "the I/O bus never strobed the device fabric" is observable.
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
      dev_seen  = 1'b0;
      waited = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        dev_seen = dev_seen | device_io_rd;
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

  task automatic write_port;
    reg [1:0] lane;
    integer waited;
    begin
      lane = probe_port[1:0];
      @(negedge clk);
      cpu_addr  = {16'd0, probe_port[15:2], 2'b00};
      cpu_be    = 4'b0001 << lane;
      cpu_din   = {24'd0, probe_data} << (lane * 8);
      cpu_write = 1'b1;
      cpu_valid = 1'b1;
      waited = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        waited = waited + 1;
        if (waited > 1000) begin
          $display("FAIL write %04x never became ready", probe_port);
          errors = errors + 1;
          cpu_valid = 1'b0;
          cpu_write = 1'b0;
          cpu_be    = 4'b0;
          return;
        end
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // ---- 1. the RTL facts the core DOES answer (asserted) ----
    // 0x30 is neither a device port (pc9821_device_select's dev_bus_cs) nor a system
    // port (|hit[108:0]), so the open bus reaches the CPU and the device fabric is never
    // strobed. If a future implementation adds it to either list, the value and dev_seen
    // change here.
    probe_port = 16'h0030; read_port;
    check("port30_reads_open_bus", got, 8'hFF);
    check("port30_no_device_strobe", {15'b0, dev_seen}, 16'd0);

    // 0x32 is claimed as an unrelated fixed system strap, measured 0x45 at the DOS
    // prompt (pc9821_iobus.sv read arm). NP2kai's 0x32 is the 8251 status register.
    probe_port = 16'h0032; read_port;
    check("port32_strap", got, 8'h45);

    // 0x134 is likewise a fixed system strap (measured 0x0F). NP2kai's 0x134 is the
    // serial FIFO's modem-status register.
    probe_port = 16'h0134; read_port;
    check("port134_strap", got, 8'h0F);

    // The FIFO extension's remaining ports are undecoded: open bus, no device strobe.
    probe_port = 16'h0130; read_port;
    check("fifo_130_open_bus", got, 8'hFF);
    check("fifo_130_no_device", {15'b0, dev_seen}, 16'd0);
    probe_port = 16'h0132; read_port;
    check("fifo_132_open_bus", got, 8'hFF);
    check("fifo_132_no_device", {15'b0, dev_seen}, 16'd0);
    probe_port = 16'h0136; read_port;
    check("fifo_136_open_bus", got, 8'hFF);
    check("fifo_136_no_device", {15'b0, dev_seen}, 16'd0);
    probe_port = 16'h0138; read_port;
    check("fifo_138_open_bus", got, 8'hFF);
    check("fifo_138_no_device", {15'b0, dev_seen}, 16'd0);
    probe_port = 16'h013A; read_port;
    check("fifo_13a_open_bus", got, 8'hFF);
    check("fifo_13a_no_device", {15'b0, dev_seen}, 16'd0);

    // ---- 2. the NP2kai RS-232C contract (recorded, waived) ----
    // The reset register file and both raw data ports. 0x30 happens to read the same
    // byte as NP2kai's reset data register (0xFF) but is open bus here, not a register
    // with a receive-pop side effect.
    probe_port = 16'h0030; read_port;
    waive("np2kai30_data_reset", got, np2kai_reset(16'h0030));
    probe_port = 16'h0130; read_port;
    waive("np2kai130_fifo_data", got, np2kai_reset(16'h0130));

    // Status/control ports and the FIFO registers.
    probe_port = 16'h0032; read_port;
    waive("np2kai32_status_reset", got, np2kai_reset(16'h0032));
    probe_port = 16'h0132; read_port;
    waive("np2kai132_fifo_status", got, np2kai_reset(16'h0132));
    probe_port = 16'h0134; read_port;
    waive("np2kai134_modem_status", got, np2kai_reset(16'h0134));
    probe_port = 16'h0136; read_port;
    waive("np2kai136_fifo_irq", got, np2kai_reset(16'h0136));
    probe_port = 16'h0138; read_port;
    waive("np2kai138_fifo_ctrl", got, np2kai_reset(16'h0138));
    probe_port = 16'h013A; read_port;
    waive("np2kai13a_vfast", got, np2kai_reset(16'h013A));

    // The FIFO control and V-FAST registers are read/write in NP2kai; here the
    // writes are dropped and the reads stay open bus.
    probe_port = 16'h0138; probe_data = 8'h01; write_port;
    probe_port = 16'h0138; read_port;
    waive("np2kai138_write_readback", got, 8'h01);
    probe_port = 16'h013A; probe_data = 8'h81; write_port;
    probe_port = 16'h013A; read_port;
    waive("np2kai13a_write_readback", got, 8'h81);

    // The 8251 mode/command sequence (rs232c_o32 :640 walks pos 0->1->2). Here 0x32
    // is a read-only strap, so the bytes written are lost and the status never moves.
    probe_port = 16'h0032; read_port;
    check("port32_strap_stable", got, 8'h45);
    probe_port = 16'h0032; probe_data = 8'h00; write_port;   // reset
    probe_port = 16'h0032; probe_data = 8'h4E; write_port;   // mode word
    probe_port = 16'h0032; probe_data = 8'h27; write_port;   // command word
    probe_port = 16'h0032; read_port;
    check("port32_strap_after_writes", got, 8'h45);
    waive("np2kai32_mode_cmd", got, np2kai_reset(16'h0032));

  // ==== VERDICT ====
    $display("NOTE serial: %0d cases, %0d mismatched, %0d waived (absent serial port)",
             cases, errors, waivers);
    if (errors == 0) begin
      $display("TB_PC9821_SERIAL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SERIAL: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_SERIAL: TIMEOUT");
  end

endmodule
