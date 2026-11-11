`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FLOPPY_MODE: the OSD's Floppy mode field is SETUP's floppy disk mode - it seeds
// software-DIP 0x861E, port 0x00BE bits 3:2 read it back, and the firmware's own POST sequence
// then programs the interface as the Xe10 does.
//
// THE MANIFEST'S CLAIM, word for word (one line, so the checker's whitespace-normalised match sees it):
// The OSD's Floppy mode field seeds bank-A 0x861E with the byte the Xe10 holds after SETUP stored each floppy disk mode - F7 at auto (1M) (the default, list position 0), 76 at 1M, 75 at auto (640K), F4 at 640K (docs/probes/XE10CFG-XE10-CFG0/CFGF3/CFGF1/CFGF0.TXT SDIPA0 byte 2) - and carries it to the CG record and mirror in setup_cfg[23:16]; port 0x00BE bit 3 reads 0x861E bit 1 and bit 2 reads NOT 0x861E bit 0, so after the ITF's `out 0xBE,(0xBE&1)|4|(0x861E&2)` (BANK4@0x1B55-0x1B65) and the BIOS's `in al,0xbe / test al,8` interface choice (BANK7@0x5982-0x59AB) the port reads the machine's FF / FB / F0 / F4 (docs/probes/FDMODE-XE10-FDM0/FDMF3/FDMF1/FDMF0.TXT, FF the 1M reading after its SENSE) and 0x00BF reads FF in every mode; the two 640K modes leave the strap at 0, so the controller answers at 0xC8 (MSR 0x80) while 0x90 reads FF and its DMA channel is 3, and the 1M modes the other way round with channel 2; the field applies at the next machine reset, and a program's 0x861E write (SETUP storing a mode) is re-seeded to the OSD's byte by the guest's 0x534 reboot. Fail-first by mutation (tests/pc9821/mutations.json): with the seed byte constant, bit 3 constant (the earlier `out 0xBE,03` from the BIOS), bit 2 constant clear (the retired FDD mode field's Auto default), or 0x00BF aliased to 0x00BE, the steps fail.
//
// THE EVIDENCE.
//   - The four captures were taken on the owner's Xe10 with SETUP's floppy disk mode at each
//     value (docs/bios-setup.md, DIP switch 3 bits 1:0: 0 640K, 1 auto (640K), 2 1M, 3 auto
//     (1M)): 0x861E = 76 / F7 / 75 / F4, 0x00BE = FD-then-FF / FB / F0 / F4, 0x00BF = FF, and
//     with the 640K modes 0x00C8 = 80 (the 640 KB interface's MSR) where the 1M modes read FF.
//   - The ITF (BANK4@0x1B55): `mov dx,0x861e / in al,dx / and al,2 / mov bl,al / in al,0xbe /
//     and al,1 / or al,4 / or al,bl / out 0xbe,al`.
//   - The BIOS (BANK7@0x5982): `in al,0xbe / test al,8 / mov al,0 / jz / mov al,3`, then the
//     memory switch 5 nibble (0 here, Boot order Auto, `jz` keeps al), then `out 0xbe,al`.
//   - MAME pc9801.cpp fdc_mode_r `(m_dsw3->read() & 3) << 2`: bits 3:2 are switches.
//   - NP2kai io/fdc.c:1265 attaches the channel-group reader at 0x00BE only.
module tb_pc9821_floppy_mode;
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
  // The OSD Machine field, held at set 0 (Xe10) throughout.
  reg  [3:0] bios_set = 4'd0;
  // The OSD GDC Clock field, driven in step (f): 0 = 2.5 MHz (entry 0, the
  // measured machine's port-0x31 strap), 1 = 5 MHz. Same latch contract as bios_set.
  reg  gdc_clock_5m = 1'b0;
  // The memory-switch hold request (pc9821_system drives it from the Memory switch field's
  // Keep and the Boot order field), and the Text lines field.
  reg  msw_hold = 1'b0;
  reg  text_lines_20 = 1'b0;
  // The Floppy mode field's LIST POSITION (0 = Auto (1M), the default; 1 = 1M; 2 = Auto (640K);
  // 3 = 640K), the one input this bench drives. Position 0 is what a card with no saved config
  // passes, so step (a)'s first check is the OSD default.
  reg  [1:0] floppy_mode = 2'd0;
  wire sdip_seed_pulse;
  wire [23:0] setup_cfg;

  wire [31:0] cpu_dout;
  wire cpu_ready, cpu_resp_valid;
  wire device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire [7:0] device_io_din;
  wire [3:0] top_bank;
  wire [1:0] ems_state;
  wire sound_extend, beep_mute, fdc_irq, fdc_irq10;
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
      .text_lines_20(text_lines_20), .floppy_mode(floppy_mode),
      .sdip_seed_pulse(sdip_seed_pulse), .setup_cfg(setup_cfg),
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
      .fdc_irq(fdc_irq), .fdc_irq10(fdc_irq10),
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

  task automatic check_port(input [15:0] port, input [7:0] want, input [8*96-1:0] what);
    begin
      probe_port = port;
      read_port;
      if (got !== want) begin
        $display("FAIL %0s: %04x=%02x, want %02x", what, port, got, want);
        errors = errors + 1;
      end else
        $display("  %0s: %04x=%02x", what, port, got);
    end
  endtask

  task automatic reboot_534;
    begin
      probe_port = 16'h0534;
      read_port;
      write_port(16'h0534, got ^ 8'h01);
      repeat (60) @(posedge clk);
    end
  endtask

  task automatic set_mode(input [1:0] pos);
    begin
      @(negedge clk);
      floppy_mode   = pos;
      machine_reset;
      repeat (60) @(posedge clk);
    end
  endtask

  // The two firmware sequences verbatim, as port I/O (see THE EVIDENCE).
  task automatic post_floppy_setup;
    reg [7:0] s86, be, al;
    begin
      write_port(16'h8F1F, 8'h80);                  // bank A, as the ITF selects it
      probe_port = 16'h861E; read_port; s86 = got;  // ITF BANK4@0x1B55
      probe_port = 16'h00BE; read_port; be = got;
      write_port(16'h00BE, (be & 8'h01) | 8'h04 | (s86 & 8'h02));
      probe_port = 16'h00BE; read_port; be = got;   // BIOS BANK7@0x5982
      al = (be & 8'h08) ? 8'h03 : 8'h00;            // MSW5 nibble 0: `jz` keeps al
      write_port(16'h00BE, al);
    end
  endtask

  task automatic check_mode(input [1:0] pos, input [7:0] want_861e,
                            input [7:0] want_be, input is_640k, input [8*40-1:0] what);
    begin
      set_mode(pos);
      write_port(16'h8F1F, 8'h80);
      check_port(16'h861E, want_861e, what);
      if (setup_cfg[23:16] !== want_861e) begin
        $display("FAIL %0s: setup_cfg[23:16]=%02x, want %02x", what, setup_cfg[23:16], want_861e);
        errors = errors + 1;
      end
      post_floppy_setup;
      check_port(16'h00BE, want_be, what);
      check_port(16'h00BF, 8'hFF, what);
      check_port(16'h0090, is_640k ? 8'hFF : 8'h80, what);
      check_port(16'h00C8, is_640k ? 8'h80 : 8'hFF, what);
      if (dut.fdc_dma_ch !== (is_640k ? 2'd3 : 2'd2)) begin
        $display("FAIL %0s: the FDC DMA channel is %0d, want %0d", what, dut.fdc_dma_ch,
                 is_640k ? 3 : 2);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // (a) The four captures, the default first (position 0 = auto (1M), docs/policies.md's
    //     defaults rule; the factory 1M is position 1).
    check_mode(2'd0, 8'hF7, 8'hFB, 1'b0, "(a) auto (1M), the default");
    check_mode(2'd1, 8'h76, 8'hFF, 1'b0, "(a) 1M");
    check_mode(2'd2, 8'h75, 8'hF0, 1'b1, "(a) auto (640K)");
    check_mode(2'd3, 8'hF4, 8'hF4, 1'b1, "(a) 640K");

    // (b) The field applies at the next machine reset only.
    set_mode(2'd1);
    @(negedge clk); floppy_mode = 2'd3;
    repeat (20) @(posedge clk);
    write_port(16'h8F1F, 8'h80);
    check_port(16'h861E, 8'h76, "(b) mid-run change, 0x861E unchanged");
    machine_reset;
    repeat (60) @(posedge clk);
    write_port(16'h8F1F, 8'h80);
    check_port(16'h861E, 8'hF4, "(b) after the reset, 640K");

    // (c) A program's 0x861E write (SETUP storing 640K under 1M) lasts until the 0x534 reboot,
    //     which re-seeds the OSD's byte.
    set_mode(2'd1);
    write_port(16'h8F1F, 8'h80);
    write_port(16'h861E, 8'hF4);
    check_port(16'h861E, 8'hF4, "(c) a program's 0x861E write reads back");
    reboot_534;
    write_port(16'h8F1F, 8'h80);
    check_port(16'h861E, 8'h76, "(c) after the 0x534 reboot, the OSD's 1M");
    check_port(16'h00BE, 8'hFF, "(c) after the 0x534 reboot, 0x00BE");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_FLOPPY_MODE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FLOPPY_MODE: FAIL (%0d errors)", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_FLOPPY_MODE: TIMEOUT");
  end

endmodule
