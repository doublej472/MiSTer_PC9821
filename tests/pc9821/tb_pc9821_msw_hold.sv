`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MSW_HOLD: port 0x31 bit 4 is the memory-switch init switch, and the Boot order
// field puts it at HOLD so the switch value it seeds survives POST.
//
// THE MANIFEST'S CLAIM, word for word (one line, so the checker's whitespace-normalised match sees it):
// The OSD Boot order field reaches the guest only if the ITF's memory-switch init leaves the seeded 0xA3FF2 cell alone: with port 0x31 bit 4 SET (the measured Xe10's 0xF3, MAME pc9801.cpp SW2:5 "Memory Switch Init" = initialise) the ITF rewrites the cells at every POST (BANK4@0x5B9A-0x5BD7, MSW5 = 0x01), so a non-default Boot order drives the switch to HOLD: after the next machine reset port 0x31 reads 0xE3 (NP2kai's default DIP-2 byte, pccore.c:135, bit 4 clear) at 2.5 MHz and 0x63 at 5 MHz, while Auto keeps the measured 0xF3; a mid-run change and the warm CPU-reset class move nothing, and the ITF's 0x851E merge stays odd in every state because the merge masks bit 4. Fail-first: on the tree before this change port 0x31 reads 0xF3 with the hold asked for, and the bench fails at step (d). Port 0x31 also follows the store as the Xe10 does (docs/probes/XE10CFG-XE10-CFGWR.TXT): bit 4 follows a bank-A 0x871E write's bit 5 (1E reads E3, 3E reads F3), and a bank-A 0x851E write stores only its bit 4 while its other bits become port 0x31's (12 reads back 12 on both ports, then 02 reads 02 with 0x31 still 12; the ITF's E3 merge reads 02 / F3), until the next machine reset puts the switches back (F3).
//
// THE EVIDENCE.
//   - The switch: MAME src/mame/nec/pc9801.cpp DSW2 `PORT_DIPNAME( 0x10, 0x00, "Memory Switch
//     Init" ) PORT_DIPLOCATION("SW2:5")`, 0x00 = No ("Hold MEMSW contents"), 0x10 = Yes
//     ("Initialize MEMSW with the system default"); port 0x31 is that DIP bank (MAME
//     `m_ppi_sys->in_pa_callback().set_ioport("DSW2")`, NP2kai io/sysport.c sysp_i31
//     `return(pccore.dipsw[1]);`). NP2kai's default DIP 2 byte is 0xE3 (pccore.c:135
//     `{0x3e, 0xe3, 0x7b}`), bit 4 clear = hold. The measured Xe10 reads 0xF3, bit 4 set
//     (docs/probes/MEMSW.TXT `0031=F3`).
//   - What the firmware does with it: BANK4@0x5B9A `in al,0x31 / test al,0x10 / jz 0x5BE0`, then
//     with the switch writes enabled (`out 0x68,0x0D`) MSW1 = 0x48, MSW2 = 0x05, MSW3 = 0x04,
//     MSW4 = 0x00, MSW5 = 0x01 (`mov byte [es:bx+0x12],0x01` at BANK4@0x5BCD, bx = 0x3FE0),
//     MSW6 &= 0xC0, MSW7 = 0x00 - exactly the measured cells (MEMSW.TXT: 48 05 0C 00 01 00 00
//     81, MSW3's bit 3 being the FPU marker BANK4@0x1D0F-0x1D21 ORs in under the same bit).
//     The core's own boot shows the consequence: with Boot order at 640K the reset seed writes
//     0x21 into 0xA3FF2 and the guest at FDBD7 (BANK4@0x5BD7) writes 0x01 over it
//     (tb_pc9821_userdisk +MSW_CELL_TRACE), so the BIOS boot loop (BANK7@0x7F7B, which
//     takes the nibble as its boot device) never saw the selection.
//   - Parity: the ITF's verify merges `(port31 & 0xEF) | (0x851E & 0x10)` (BANK4@0x46D2
//     `and ax,0x10EF`), so bit 4 of port 0x31 is outside the merged data and the hold cannot
//     make the merge even. Steps (f) check it at both straps.
module tb_pc9821_msw_hold;
  reg clk = 0;
  always #5 clk = ~clk;

  // The bus inputs a read of 0xF0 needs, and nothing more. Every one is named because
  // the DUT instantiation below lists every port.
  reg  reset = 0;
  reg  triple_fault_reset = 0;
  reg  [31:0] cpu_addr = 0;
  reg  [31:0] cpu_din = 0;
  reg  [3:0] cpu_be = 0;
  reg  cpu_valid = 0;
  reg  cpu_write = 0;
  reg  [7:0] debug_status = 0;
  reg  cal_cdat = 0;
  reg  [6:0] cfg_ram_mib = 0;
  reg  cfg_seed_en = 0;
  reg  [7:0] device_io_dout = 0;
  reg  device_rd_wait = 0;
  reg  device_rd_hold = 0;
  reg  egc_gate = 0;
  // The OSD field itself, driven mid-run in step (b). It starts on set 0 (Xe10).
  reg  [3:0] bios_set = 4'd0;
  // The OSD GDC Clock field, driven mid-run in step (d): 0 = 2.5 MHz (entry 0, the
  // measured machine's port-0x31 strap), 1 = 5 MHz. Same latch contract as bios_set.
  reg  gdc_clock_5m = 1'b0;
  // The memory-switch hold request (pc9821_system drives it from the Boot order field).
  reg  msw_hold = 1'b0;

  wire [31:0] cpu_dout;
  wire cpu_ready, cpu_resp_valid;
  wire device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire [7:0] device_io_din;
  wire [3:0] top_bank;
  wire [1:0] ems_state;
  wire sound_extend, beep_mute, fdc_irq;
  wire [7:0] win0_sel;
  wire sys16m_en, ide_rom_enable, top_shadow_en, bios_ram_gate;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0] post_code;
  wire post_write;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg, egc_sft, egc_leng;
  wire egc_shift_we;
  wire [3:0] dbg_gate;
  wire [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire dbg_last_io_rd, dbg_last_io_wr;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [2:0] state = dut.state;

  // ==== DUT ====
  // The 0x9A0 query state input (pc9821_iobus): driven at 0 here - only
  // tb_pc9821_readback_sysports exercises the query protocol.
  reg [10:0] gdc_ff2_state = 11'd0;
  // IDE unit 0 (bank 0's master) holds a drive: the hard disk's image is mounted (step f).
  reg ide_unit0 = 1'b0;
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(ide_unit0), .ide_unit2_present(1'b1),
      .clk(clk),
      .bios_set(bios_set),
      .gdc_clock_5m(gdc_clock_5m), .msw_hold(msw_hold),
      .text_lines_20(1'b0),
      .reset(reset),
      .triple_fault_reset(triple_fault_reset),
      .cpu_addr(cpu_addr),
      .cpu_din(cpu_din),
      .cpu_be(cpu_be),
      .cpu_valid(cpu_valid),
      .cpu_write(cpu_write),
      .cpu_dout(cpu_dout),
      .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .debug_status(debug_status),
      .cal_cdat(cal_cdat),
      .cfg_ram_mib(cfg_ram_mib),
      .cfg_seed_en(cfg_seed_en),
      .device_io_wr(device_io_wr),
      .device_io_rd(device_io_rd),
      .device_io_addr(device_io_addr),
      .device_io_din(device_io_din),
      .device_io_dout(device_io_dout),
      .device_rd_wait(device_rd_wait),
      .device_rd_hold(device_rd_hold),
      .top_bank(top_bank),
      .ems_state(ems_state),
      .sound_extend(sound_extend),
      .beep_mute(beep_mute),
      .fdc_irq(fdc_irq),
      .win0_sel(win0_sel),
      .sys16m_en(sys16m_en),
      .ide_rom_enable(ide_rom_enable),
      .top_shadow_en(top_shadow_en),
      .bios_ram_gate(bios_ram_gate),
      .a20_enable(a20_enable),
      .cpu_reset_req(cpu_reset_req),
      .unmapped_writes(unmapped_writes),
      .unmapped_reads(unmapped_reads),
      .last_unmapped_port(last_unmapped_port),
      .post_code(post_code),
      .post_write(post_write),
      .egc_gate(egc_gate),
      .egc_access(egc_access),
      .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope),
      .egc_fg(egc_fg),
      .egc_mask(egc_mask),
      .egc_bg(egc_bg),
      .egc_sft(egc_sft),
      .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .dbg_gate(dbg_gate),
      .dbg_itf_stage(dbg_itf_stage),
      .dbg_artic_hi(dbg_artic_hi),
      .dbg_last_io_addr(dbg_last_io_addr),
      .dbg_last_io_data(dbg_last_io_data),
      .dbg_last_io_rd(dbg_last_io_rd),
      .dbg_last_io_wr(dbg_last_io_wr),
      .cache_flush_req(cache_flush_req), .cache_flush_busy(cache_flush_busy), .cache_flush_done(cache_flush_done)
  );

  // ==== CHECKS ====
  integer errors = 0;
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
      while (state != 0) @(negedge clk);
    end
  endtask

  // The machine reset / reload strobe: pc9821_iobus's reset, which pc9821_system drives
  // with `reset || !cpu_run` - the platform reset OR the pack-reload window. This is the
  // ONLY event that re-samples the OSD BIOS-set field.
  task automatic machine_reset;
    begin
      @(negedge clk);
      reset = 1'b1;
      repeat (3) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // The warm CPU-RESET class (out 0xF0, 0x534, a z486 shutdown) - the same machine,
  // rebooted into its own ITF again. It must NOT apply a pending OSD change.
  task automatic warm_cpu_reset;
    begin
      @(negedge clk);
      triple_fault_reset = 1'b1;
      repeat (2) @(posedge clk);
      @(negedge clk);
      triple_fault_reset = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Let the mid-run OSD field change settle, without any reset event.
  task automatic osd_flip(input [3:0] set);
    begin
      @(negedge clk);
      bios_set = set;
      repeat (5) @(posedge clk);
    end
  endtask

  task automatic check_f0(input [7:0] want);
    begin
      probe_port = 16'h00F0;
      read_port;
      if (got !== want) begin
        $display("FAIL 0xF0=%02x, want %02x", got, want);
        errors = errors + 1;
      end
    end
  endtask

  // Port 0x31, the GDC clock's strap byte ("DIP switch 2"). Bit 7 CLEAR is 5 MHz; the
  // measured Xe10 answers 0xF3, i.e. bit 7 SET and 2.5 MHz.
  task automatic check_31(input [7:0] want);
    begin
      probe_port = 16'h0031;
      read_port;
      if (got !== want) begin
        $display("FAIL 0x31=%02x, want %02x", got, want);
        errors = errors + 1;
      end
    end
  endtask

  // The GDC-clock field's own mid-run flip (step (d)).
  task automatic gdc_flip(input bit mhz5);
    begin
      @(negedge clk);
      gdc_clock_5m = mhz5;
      repeat (5) @(posedge clk);
    end
  endtask

  // A byte write on the device bus, for the SDIP control port.
  task automatic write_port(input [15:0] port, input [7:0] data);
    reg [1:0] lane;
    integer waited;
    begin
      lane = port[1:0];
      @(negedge clk);
      cpu_addr  = {16'd0, port[15:2], 2'b00};
      cpu_din   = {4{data}};
      cpu_be    = 4'b0001 << lane;
      cpu_write = 1'b1;
      cpu_valid = 1'b1;
      waited = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        waited = waited + 1;
        if (waited > 1000) begin
          $display("FAIL port %04x write never became ready", port);
          errors = errors + 1;
          cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'b0;
          return;
        end
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'b0;
      while (state != 0) @(negedge clk);
    end
  endtask

  task automatic hold_flip(input bit h);
    begin
      @(negedge clk);
      msw_hold = h;
      repeat (5) @(posedge clk);
    end
  endtask

  // The ITF's 0x851E merge (BANK4@0x46CC-0x46DA): odd parity required.
  task automatic merge_odd(input [255:0] what);
    reg [7:0] p31, s1, merged;
    begin
      write_port(16'h8F1F, 8'h80);       // bank A, as BANK4@0x46BA selects it
      probe_port = 16'h851E; read_port; s1 = got;
      probe_port = 16'h0031; read_port; p31 = got;
      merged = (p31 & 8'hEF) | (s1 & 8'h10);
      if (^merged !== 1'b1) begin
        $display("FAIL %0s: merge (%02x & EF) | (%02x & 10) = %02x is EVEN", what, p31, s1, merged);
        errors = errors + 1;
      end else
        $display("  %0s: merge %02x odd", what, merged);
    end
  endtask

  initial begin
    // (a) Auto (the hold not asked for): the measured 0xF3.
    machine_reset;
    check_31(8'hF3);
    $display("  (a) reset with the hold off: 0x31 -> %02x (the measured 0xF3)", got);
    // (b) a mid-run change moves nothing.
    hold_flip(1'b1);
    check_31(8'hF3);
    $display("  (b) mid-run hold request: 0x31 -> %02x (must STILL be 0xF3)", got);
    // (c) nor does the warm CPU-reset class.
    warm_cpu_reset;
    check_31(8'hF3);
    $display("  (c) warm CPU reset: 0x31 -> %02x", got);
    // (c2) nor the guest's 0x534 reboot, although it re-seeds the store and port 0x31 from the
    //      latches (the switches, not the OSD field, are what it restores).
    write_port(16'h0534, 8'h01);
    repeat (40) @(posedge clk);          // the store's 24-cycle reseed walk
    check_31(8'hF3);
    $display("  (c2) 0x534 reboot: 0x31 -> %02x (must STILL be 0xF3)", got);
    // (d) the next machine reset applies it: 0xE3 (NP2kai's default DIP 2, bit 4 = hold).
    machine_reset;
    check_31(8'hE3);
    $display("  (d) machine reset with the hold: 0x31 -> %02x (want 0xE3)", got);
    // (f) the ITF's merge stays odd with the hold, at 2.5 MHz.
    repeat (40) @(posedge clk);
    merge_odd("(f) hold, 2.5 MHz");
    // (e) with 5 MHz as well: bit 7 and bit 4 both clear.
    gdc_flip(1'b1);
    machine_reset;
    check_31(8'h63);
    $display("  (e) hold + 5 MHz: 0x31 -> %02x (want 0x63)", got);
    repeat (40) @(posedge clk);
    merge_odd("(f) hold, 5 MHz");
    // (g) back to Auto: the measured byte again, and its merge.
    hold_flip(1'b0);
    gdc_flip(1'b0);
    machine_reset;
    check_31(8'hF3);
    $display("  (g) reset with the hold off again: 0x31 -> %02x (want 0xF3)", got);
    repeat (40) @(posedge clk);
    merge_odd("(g) init, 2.5 MHz");

    // (h) port 0x31 bit 4 FOLLOWS a 0x871E write's bit 5 (P1): the Xe10 reads E3 after
    //     0x871E = 1E and F3 again after 3E (docs/probes/XE10CFG-XE10-CFGWR.TXT `RT 871E was=3E
    //     wrote=1E got=1E p31=E3 back=3E p31=F3`), as NP2kai io/dipsw.c's 0x0700 arm sets
    //     dipsw[1] bit 4 - but with no parity gate (1E is even and still lands).
    write_port(16'h8F1F, 8'h80);
    write_port(16'h871E, 8'h1E);
    check_31(8'hE3);
    $display("  (h) 0x871E = 1E: 0x31 -> %02x (want E3)", got);
    write_port(16'h871E, 8'h3E);
    check_31(8'hF3);
    $display("  (h) 0x871E = 3E: 0x31 -> %02x (want F3)", got);
    // (i) a bank-A 0x851E write stores ONLY bit 4 and puts its other bits on port 0x31: the
    //     Xe10 reads 0x851E 12 / 0x31 12 after writing 12, then 02 / 12 after writing 02 back
    //     (CFGWR.TXT `RT 851E was=02 wrote=12 got=12 p31=12 back=02 p31=12`; CFG0B.TXT 0031=12).
    write_port(16'h851E, 8'h12);
    probe_port = 16'h851E; read_port;
    if (got !== 8'h12) begin $display("FAIL (i) 0x851E after 12 reads %02x, want 12", got); errors = errors + 1; end
    check_31(8'h12);
    write_port(16'h851E, 8'h02);
    probe_port = 16'h851E; read_port;
    if (got !== 8'h02) begin $display("FAIL (i) 0x851E after 02 reads %02x, want 02", got); errors = errors + 1; end
    check_31(8'h12);
    $display("  (i) 0x851E 12 then 02: 0x31 -> %02x (want 12)", got);
    // (j) the ITF's boot merge writes (0x851E & 10) | (0x31 & EF) = E3 (BANK4@0x46CC-0x46D9),
    //     after which the Xe10 reads 0x851E = 02 and 0x31 = F3 (XE10CFG-XE10-CFG0.TXT): bits
    //     7:5/3:0 of the write do not reach the store.
    write_port(16'h851E, 8'hE3);
    probe_port = 16'h851E; read_port;
    if (got !== 8'h02) begin $display("FAIL (j) 0x851E after the E3 merge reads %02x, want 02", got); errors = errors + 1; end
    check_31(8'hF3);
    $display("  (j) the E3 merge: 0x31 -> %02x (want F3), 0x851E 02", got);
    // (k) a 0x851E write that moved port 0x31 is undone by the next machine reset (the Xe10's
    //     0x534 reboot reads F3 again: XE10CFG-XE10-CFGRB.TXT).
    write_port(16'h851E, 8'h12);
    check_31(8'h12);
    machine_reset;
    check_31(8'hF3);
    $display("  (k) after a reset: 0x31 -> %02x (want F3)", got);

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_MSW_HOLD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_MSW_HOLD: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_MSW_HOLD: TIMEOUT");
  end

endmodule
