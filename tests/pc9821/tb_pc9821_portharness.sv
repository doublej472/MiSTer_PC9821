`timescale 1ns/1ps

// A script-driven harness for measuring ONE subsystem's port behaviour, fast.
//
// The other half of measuring quickly. Booting the authentic firmware to reach
// a device question costs a boot even with +STOP_AT_PC; a device question about
// what a port *does* needs no firmware at all. This harness instantiates the
// real I/O bus (every device hangs off it) and executes a script of port
// accesses, printing one machine-readable line per access.
//
// Build it the way the other benches are built (see run_portharness.sh), then:
//   ./obj/Vtb_pc9821_portharness +SCRIPT=<path>
//
// Seconds per question, and a new subsystem question is a text file rather than
// a testbench edit. The script grammar:
//
//   w <port> <byte>          write a byte
//   r <port>                 read a byte
//   e <port> <byte>          read and expect exactly this byte
//   m <port> <mask> <byte>   read and expect (value & mask) == byte
//   W <port> <word>          write 16 bits (byte lanes 0 and 1)
//   R <port>                 read 16 bits (byte lanes 0 and 1)
//   scan <first> <last>      read every port in a byte range (a sweep)
//   i <n>                    idle n clocks
//   reset                    pulse reset
//   note <text>              a section marker in the output
//
// Any expectation that fails makes the harness exit non-zero, so a script is
// also a test: it can be run in the suite, and an unknown op is reported rather
// than silently skipped.
//
// On timing: this bench drives the ports directly, so "how many clocks does the
// access take" is measurable here, and the *cycle* is printed on every line
// (MEASURE=<cycle> markers included), which is what makes a delta meaningful.

// ==== WHAT THIS PROVES ====
// TB_PC9821_PORTHARNESS:
// A script of port operations runs against the real I/O bus and prints one machine-readable line per access with its cycle; a failed expectation exits non-zero and an unknown op is reported rather than ignored.


module tb_pc9821_portharness;
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
  reg [7:0] device_io_dout = 8'hC3;
  // Most devices present their data in the strobe cycle; the GDC is the one
  // that asks for an extra read cycle. Driving this from the port number is
  // what makes a harness measurement match the machine.
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
  // The CPU's shutdown request, held low here: this harness drives ports only.
  reg        triple_fault_reset = 1'b0;
  // EGC: the gate pc9821_gdc_text exports, and the register file the I/O bus
  // latches from 0x04A0-0x04AE. A script drives the gate with a 0x6A/0x7C pair
  // through the real bus when it wants the write path live; the engine itself is
  // not built here (this harness has no memory path).
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  // Held ON: this harness has no video module to derive the gate from, and its
  // purpose is to measure what the port does, not to re-test the gate (that is
  // tb_pc9821_iobus.sv's job).
  reg         egc_gate = 1'b1;

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
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

  integer errors = 0;
  integer checks = 0;
  integer accesses = 0;
  integer clk_count = 0;

  always @(posedge clk) clk_count = clk_count + 1;

  // device_rd_wait models the DEVICE side of the read handshake: only the GDC's arrays
  // are in block RAM, so only its reads are answered a cycle after the strobe
  // (pc9821_system.sv:1173, `device_rd_wait = gdc_cs || opna_rd_wait`). Copied from the core's decode; +RD_WAIT_NONE disables it.
  reg rd_wait_gdc = 1'b1;
  function automatic bit is_gdc_port(input [15:0] p);
    begin
      case (p)
        16'h0060, 16'h0062, 16'h0064, 16'h0068, 16'h006A, 16'h006E,
        16'h0078, 16'h007A, 16'h007C, 16'h007E,
        16'h00A0, 16'h00A1, 16'h00A2, 16'h00A3, 16'h00A4, 16'h00A5,
        16'h00A6, 16'h00A8, 16'h00A9, 16'h00AA, 16'h00AC, 16'h00AE:
          is_gdc_port = 1'b1;
        default: is_gdc_port = 1'b0;
      endcase
    end
  endfunction
  always @(*) device_rd_wait = rd_wait_gdc && is_gdc_port(cpu_addr[15:0]);

  // ---- port primitives ------------------------------------------------------
  // ==== STIMULUS ====
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

  // 16-bit access: two byte lanes, low lane first, which is what an x86 `out
  // dx, ax` produces on this bus.
  task automatic rd16(input [15:0] portnum, output [15:0] data);
    reg [7:0] lo, hi;
    begin
      rd8(portnum, lo);
      rd8(portnum + 1, hi);
      data = {hi, lo};
    end
  endtask

  task automatic wr16(input [15:0] portnum, input [15:0] data);
    begin
      wr8(portnum, data[7:0]);
      wr8(portnum + 1, data[15:8]);
    end
  endtask

  // Every access prints one CSV line, so a run is diffable and can be compared
  // between the core and real hardware. `want` is only meaningful for
  // expectations; ok is 1 for a plain read/write (nothing was asserted).
  task automatic emit(input [8*4-1:0] kind, input [15:0] portnum,
                      input [15:0] got, input [15:0] want, input ok);
    begin
      $display("PORT %s,%04x,%04x,%04x,%0d,%0d",
               kind, portnum, got, want, ok, clk_count);
    end
  endtask

  task automatic expect8(input [15:0] portnum, input [7:0] want, input [7:0] mask);
    reg [7:0] got;
    begin
      rd8(portnum, got);
      checks = checks + 1;
      if ((got & mask) !== (want & mask)) begin
        $display("FAIL port %04x got %02x want %02x (mask %02x) cyc=%0d",
                 portnum, got, want, mask, clk_count);
        errors = errors + 1;
        emit("m", portnum, got, want, 1'b0);
      end else begin
        emit("m", portnum, got, want, 1'b1);
      end
    end
  endtask

  // ---- script ---------------------------------------------------------------
  integer fd, n;
  reg [8*256-1:0] line;
  reg [8*16-1:0]  op;
  reg [31:0] a, b, c;
  reg [7:0]  got8;
  reg [15:0] got16;

  // True if the line contains a '#', which the grammar reserves for comments.
  function automatic bit line_has_hash(input [8*256-1:0] l);
    integer i;
    begin
      line_has_hash = 1'b0;
      for (i = 0; i < 256; i = i + 1)
        if (l[i*8 +: 8] == 8'h23) line_has_hash = 1'b1;
    end
  endfunction

  task automatic bad_line;
    begin
      $display("MEASURE bad-op line=\"%0s\" (see the grammar in tb_pc9821_portharness.sv)", line);
      errors = errors + 1;
    end
  endtask

  task automatic pulse_reset;
    begin
      reset = 1;
      repeat (8) @(negedge clk);
      reset = 0;
      repeat (8) @(negedge clk);
      $display("MEASURE=reset cyc=%0d", clk_count);
    end
  endtask
  // ==== CHECKS ====

  initial begin
    string script_path;
    int unsigned stub;
    if (!$value$plusargs("SCRIPT=%s", script_path)) begin
      $display("MEASURE ERROR: pass +SCRIPT=<path>");
      $fatal(1);
    end

    // Ports the core does not own fall through to this bench's stub device.
    // +STUB=<hex> sets what it answers, so an unimplemented port can be made to
    // look like open bus (0xff) instead of the bench's own value: otherwise a
    // sweep reports the harness's constant as if the core had returned it.
    if ($value$plusargs("STUB=%h", stub)) device_io_dout = stub[7:0];
    if ($test$plusargs("RD_WAIT_NONE")) begin
      rd_wait_gdc = 1'b0;
      $display("MEASURE=rd_wait policy=none (every read answers in the strobe cycle)");
    end else begin
      $display("MEASURE=rd_wait policy=gdc (the GDC port set takes the extra read cycle)");
    end

    reset = 1;
    repeat (16) @(negedge clk);
    reset = 0;
    repeat (16) @(negedge clk);
    $display("MEASURE=start cyc=%0d", clk_count);

    fd = $fopen(script_path, "r");
    if (fd == 0) begin
      $display("MEASURE ERROR: cannot open %0s", script_path);
      $fatal(1);
    end

    while (!$feof(fd)) begin
      n = $fgets(line, fd);
      if (n == 0) break;
      n = $sscanf(line, "%s", op);
      if (n != 1) continue;              // blank
      if (op == "w") begin
        n = $sscanf(line, "%s %h %h", op, a, b);
        if (n != 3) begin bad_line; continue; end
        wr8(a[15:0], b[7:0]);
        accesses = accesses + 1;
        emit("w", a[15:0], {8'd0, b[7:0]}, 16'd0, 1'b1);
      end else if (op == "W") begin
        n = $sscanf(line, "%s %h %h", op, a, b);
        if (n != 3) begin bad_line; continue; end
        wr16(a[15:0], b[15:0]);
        accesses = accesses + 1;
        emit("W", a[15:0], b[15:0], 16'd0, 1'b1);
      end else if (op == "r") begin
        n = $sscanf(line, "%s %h", op, a);
        if (n != 2) begin bad_line; continue; end
        rd8(a[15:0], got8);
        accesses = accesses + 1;
        emit("r", a[15:0], {8'd0, got8}, 16'd0, 1'b1);
      end else if (op == "R") begin
        n = $sscanf(line, "%s %h", op, a);
        if (n != 2) begin bad_line; continue; end
        rd16(a[15:0], got16);
        accesses = accesses + 1;
        emit("R", a[15:0], got16, 16'd0, 1'b1);
      end else if (op == "e") begin
        n = $sscanf(line, "%s %h %h", op, a, b);
        if (n != 3) begin bad_line; continue; end
        expect8(a[15:0], b[7:0], 8'hFF);
      end else if (op == "m") begin
        n = $sscanf(line, "%s %h %h %h", op, a, b, c);
        if (n != 4) begin bad_line; continue; end
        expect8(a[15:0], b[7:0], c[7:0]);
      end else if (op == "scan") begin
        n = $sscanf(line, "%s %h %h", op, a, b);
        if (n != 3) begin bad_line; continue; end
        for (c = a; c <= b; c = c + 1) begin
          rd8(c[15:0], got8);
          accesses = accesses + 1;
          emit("r", c[15:0], {8'd0, got8}, 16'd0, 1'b1);
        end
        $display("MEASURE=scan %04x..%04x done cyc=%0d", a[15:0], b[15:0], clk_count);
      end else if (op == "i") begin
        n = $sscanf(line, "%s %h", op, a);
        if (n != 2) begin bad_line; continue; end
        $display("MEASURE=idle cyc=%0d", clk_count);
        repeat (a) @(negedge clk);
      end else if (op == "reset") begin
        pulse_reset;
      end else if (op == "note") begin
        $display("MEASURE=\"%0s\" cyc=%0d", line, clk_count);
      end else if (line_has_hash(line)) begin
        // '#': a comment. Deliberately tested on the RAW LINE rather than on the
        // token's first byte: which end of a vector $sscanf("%s") justifies a
        // token into is not worth depending on, and an assumption about it made
        // this branch unreachable while the ops themselves still worked. No valid
        // op contains '#', so this cannot misread one.
      end else begin
        bad_line;
      end
    end
    $fclose(fd);

    $display("MEASURE=end cyc=%0d accesses=%0d checks=%0d errors=%0d",
             clk_count, accesses, checks, errors);
  // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_PORTHARNESS: FAIL (%0d errors of %0d checks)",
                            errors, checks);
    $display("TB_PC9821_PORTHARNESS: PASS");
    $finish;
  end

  // In-bench watchdog. The runner bounds wall time too and greps the
  // PASS marker, but a bench that blocks on a DUT signal with no bound
  // would hang forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PORTHARNESS: TIMEOUT");
  end

endmodule
