// ==== WHAT THIS PROVES ====
// TB_PC9821_BIOS_MODEL: the four-bit Machine field reaches the port-0xF0 machine-ID
// strap LUT and NOTHING ELSE. The pack file IS the firmware set (the MGL chooses it), and
// the two ITFs read port 0xF0's bit 5 differently: the
// PC-9821Xe10 ITF tests bits 5 and 6 together (BANK4@0xF8207), the PC-9821Xe ITF tests
// bit 5 alone (BANK4@0xF81DF) and with bit 5 SET skips the 0xD8000 option-ROM shadow copy
// its own boot needs. So the core answers the MEASURED Xe10 strap 0xA9 for set 0, 0x89
// (the same byte with bit 5 clear) for set 1, and the measured Xe10 strap 0xA9 again for
// the reserved sets 2..15 (pc9821_iobus's machine_id_strap).
//
// THE TWO ENDS, MEASURED. probes/PORTS.TXT:198 is a real PC-9821Xe10 reading
// 0xF0 = 0xA9, and that is the config-less default. The Xe value is not a machine capture
// (no Xe probe exists); it is fixed by what the Xe ITF's own branch requires -- with 0xA9
// the authentic Xe set's IDE option ROM never runs (ATA cmds=0) and the guest runs away,
// with 0x89 it takes the Xe10's shadow path and the ROM runs.
//
// WHY TWO INSTANCES. The field is a RUNTIME input (it comes from an OSD field, so it is
// not a constant and cannot be a parameter). One build is swept across all sixteen set
// indices; the second is held on the Xe set, so both machines' answers are on the same
// bus at once. Both DUTs are driven from the same bus inputs and the read harness muxes
// their outputs, so the reads are the same bus idiom against two builds of the block.
// Each swept entry is APPLIED through a machine reset pulse: the set is reset-qualified
// (pc9821_iobus's bios_set_eff latches the field on the reset/reload strobe only), so
// this bench pins WHICH byte each set answers and tb_pc9821_bios_select pins WHEN the
// set may change (mid-run flips move nothing until the next reset).
//
// WHY THE SET FIELD IS NOT status[5]. It was, once: status[5] and status[6]
// already drive the DDR framebuffer's BGR/RGB and 1555/565 format (z486_mister.sv
// fb_fmt[4:3]), so selecting the Xe set silently flipped BGR->RGB in every framebuffer
// video mode. The field moved to O[31:28]. That collision is a TOP-LEVEL SOURCE-TEXT fact
// - which status bits feed fb_fmt - that a Verilator bench cannot observe, so its guard
// lives in tools/check_osd_contract.py; this bench pins the strap LUT the wiring feeds.
//
// WHAT IT ALSO PINS: the switch is NARROW. 0xF1 (open bus 0xFF) and 0xF2 (the A20 read,
// 0xFF in the masked power-on state - it tracks the latch per NP2kai cpuio_if2, and
// that dependence is tb_pc9821_iobus's case) are read beside 0xF0 and
// must be identical for every set, so a change that moved another port's answer with the
// set would fail here.
//
// THE MANIFEST'S CLAIM, word for word (one line, so the checker's whitespace-normalised match sees it):
// The Machine field reaches port 0xF0's four-bit machine-ID strap LUT and nowhere else: set 0 (the config-less default) reads the MEASURED PC-9821Xe10 strap 0xA9, set 1 (PC-9821Xe) reads 0x89 (the same byte with bit 5 clear, the branch the Xe ITF needs to shadow the option ROM), and the reserved sets 2..15 read the measured Xe10 0xA9, while the neighbouring 0xF1 and 0xF2 straps stay put for every set (0xF1 open bus 0xFF; 0xF2 is the A20 read and answers 0xFF, its masked power-on state, tracking the latch per NP2kai cpuio_if2 as tb_pc9821_iobus pins). The set field is O[31:28], NOT the status[5]/status[6] pair the DDR framebuffer's fb_fmt assignment read until that descriptor was deleted - the reason the field moved; the OSD contract gate's field-disjointness check lives in tools/check_osd_contract.py. Without a non-Xe10 answer the authentic Xe set never runs its IDE option ROM (ATA cmds=0) and the guest runs away.

`timescale 1ns/1ps

module tb_pc9821_bios_model;
  reg clk = 0;
  always #5 clk = ~clk;

  // The bus inputs both DUTs share, and the configuration/device ties a read of 0xF0 needs
  // no part of. Every one is named because the DUT instantiation below lists every port.
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
  // The set index each DUT is instantiated with: DUT A is swept across all sixteen, DUT B
  // is held on the Xe set. The Xe10 (the config-less default) is set 0.
  reg  [3:0] set_x10 = 4'd0;
  reg  [3:0] set_xe  = 4'd1;

  // The outputs of BOTH instances, kept apart so each DUT drives its own nets.
  wire [31:0] cpu_dout_x10;
  wire [31:0] cpu_dout_xe;
  wire cpu_ready_x10;
  wire cpu_ready_xe;
  wire cpu_resp_valid_x10;
  wire cpu_resp_valid_xe;
  wire device_io_wr_x10;
  wire device_io_wr_xe;
  wire device_io_rd_x10;
  wire device_io_rd_xe;
  wire [15:0] device_io_addr_x10;
  wire [15:0] device_io_addr_xe;
  wire [7:0] device_io_din_x10;
  wire [7:0] device_io_din_xe;
  wire [3:0] top_bank_x10;
  wire [3:0] top_bank_xe;
  wire [1:0] ems_state_x10;
  wire [1:0] ems_state_xe;
  wire sound_extend_x10;
  wire sound_extend_xe;
  wire beep_mute_x10;
  wire beep_mute_xe;
  wire fdc_irq_x10;
  wire fdc_irq_xe;
  wire [7:0] win0_sel_x10;
  wire [7:0] win0_sel_xe;
  wire sys16m_en_x10;
  wire sys16m_en_xe;
  wire ide_rom_enable_x10;
  wire ide_rom_enable_xe;
  wire top_shadow_en_x10;
  wire top_shadow_en_xe;
  wire bios_ram_gate_x10;
  wire bios_ram_gate_xe;
  wire a20_enable_x10;
  wire a20_enable_xe;
  wire cpu_reset_req_x10;
  wire cpu_reset_req_xe;
  wire [15:0] unmapped_writes_x10;
  wire [15:0] unmapped_writes_xe;
  wire [15:0] unmapped_reads_x10;
  wire [15:0] unmapped_reads_xe;
  wire [15:0] last_unmapped_port_x10;
  wire [15:0] last_unmapped_port_xe;
  wire [7:0] post_code_x10;
  wire [7:0] post_code_xe;
  wire post_write_x10;
  wire post_write_xe;
  wire [15:0] egc_access_x10;
  wire [15:0] egc_access_xe;
  wire [15:0] egc_fgbg_x10;
  wire [15:0] egc_fgbg_xe;
  wire [15:0] egc_ope_x10;
  wire [15:0] egc_ope_xe;
  wire [15:0] egc_fg_x10;
  wire [15:0] egc_fg_xe;
  wire [15:0] egc_mask_x10;
  wire [15:0] egc_mask_xe;
  wire [15:0] egc_bg_x10;
  wire [15:0] egc_bg_xe;
  wire [15:0] egc_sft_x10;
  wire [15:0] egc_sft_xe;
  wire [15:0] egc_leng_x10;
  wire [15:0] egc_leng_xe;
  wire egc_shift_we_x10;
  wire egc_shift_we_xe;
  wire [3:0] dbg_gate_x10;
  wire [3:0] dbg_gate_xe;
  wire [7:0] dbg_itf_stage_x10;
  wire [7:0] dbg_itf_stage_xe;
  wire [15:0] dbg_artic_hi_x10;
  wire [15:0] dbg_artic_hi_xe;
  wire [15:0] dbg_last_io_addr_x10;
  wire [15:0] dbg_last_io_addr_xe;
  wire [7:0] dbg_last_io_data_x10;
  wire [7:0] dbg_last_io_data_xe;
  wire dbg_last_io_rd_x10;
  wire dbg_last_io_rd_xe;
  wire dbg_last_io_wr_x10;
  wire dbg_last_io_wr_xe;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY per DUT:
  // this bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req_x10, cache_flush_req_xe;
  wire cache_flush_busy_x10 = 1'b0;
  wire cache_flush_busy_xe  = 1'b0;
  wire cache_flush_done_x10 = cache_flush_req_x10;
  wire cache_flush_done_xe  = cache_flush_req_xe;

  // Which DUT the harness is talking to: 0 = the swept DUT A, 1 = the Xe-held DUT B.
  reg  sel_xe = 1'b0;
  wire [31:0] cpu_dout       = sel_xe ? cpu_dout_xe       : cpu_dout_x10;
  wire        cpu_ready      = sel_xe ? cpu_ready_xe      : cpu_ready_x10;
  wire        cpu_resp_valid = sel_xe ? cpu_resp_valid_xe : cpu_resp_valid_x10;
  wire [2:0]  state          = sel_xe ? xe_dut.state      : x10_dut.state;

  // ==== DUT ====
  // The 0x9A0 query state input (pc9821_iobus): driven at 0 here - only
  // tb_pc9821_readback_sysports exercises the query protocol.
  reg [10:0] gdc_ff2_state = 11'd0;
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) x10_dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),
      .clk(clk),
      .bios_set(set_x10),
      .reset(reset),
      .triple_fault_reset(triple_fault_reset),
      .cpu_addr(cpu_addr),
      .cpu_din(cpu_din),
      .cpu_be(cpu_be),
      .cpu_valid(cpu_valid),
      .cpu_write(cpu_write),
      .cpu_dout(cpu_dout_x10),
      .cpu_ready(cpu_ready_x10),
      .cpu_resp_valid(cpu_resp_valid_x10),
      .debug_status(debug_status),
      .cal_cdat(cal_cdat),
      .cfg_ram_mib(cfg_ram_mib),
      .cfg_seed_en(cfg_seed_en),
      .device_io_wr(device_io_wr_x10),
      .device_io_rd(device_io_rd_x10),
      .device_io_addr(device_io_addr_x10),
      .device_io_din(device_io_din_x10),
      .device_io_dout(device_io_dout),
      .device_rd_wait(device_rd_wait),
      .device_rd_hold(device_rd_hold),
      .top_bank(top_bank_x10),
      .ems_state(ems_state_x10),
      .sound_extend(sound_extend_x10),
      .beep_mute(beep_mute_x10),
      .fdc_irq(fdc_irq_x10),
      .win0_sel(win0_sel_x10),
      .sys16m_en(sys16m_en_x10),
      .ide_rom_enable(ide_rom_enable_x10),
      .top_shadow_en(top_shadow_en_x10),
      .bios_ram_gate(bios_ram_gate_x10),
      .a20_enable(a20_enable_x10),
      .cpu_reset_req(cpu_reset_req_x10),
      .unmapped_writes(unmapped_writes_x10),
      .unmapped_reads(unmapped_reads_x10),
      .last_unmapped_port(last_unmapped_port_x10),
      .post_code(post_code_x10),
      .post_write(post_write_x10),
      .egc_gate(egc_gate),
      .egc_access(egc_access_x10),
      .egc_fgbg(egc_fgbg_x10),
      .egc_ope(egc_ope_x10),
      .egc_fg(egc_fg_x10),
      .egc_mask(egc_mask_x10),
      .egc_bg(egc_bg_x10),
      .egc_sft(egc_sft_x10),
      .egc_leng(egc_leng_x10),
      .egc_shift_we(egc_shift_we_x10),
      .dbg_gate(dbg_gate_x10),
      .dbg_itf_stage(dbg_itf_stage_x10),
      .dbg_artic_hi(dbg_artic_hi_x10),
      .dbg_last_io_addr(dbg_last_io_addr_x10),
      .dbg_last_io_data(dbg_last_io_data_x10),
      .dbg_last_io_rd(dbg_last_io_rd_x10),
      .dbg_last_io_wr(dbg_last_io_wr_x10),
      .cache_flush_req(cache_flush_req_x10),
      .cache_flush_busy(cache_flush_busy_x10),
      .cache_flush_done(cache_flush_done_x10)
  );

  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) xe_dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),
      .clk(clk),
      .bios_set(set_xe),
      .reset(reset),
      .triple_fault_reset(triple_fault_reset),
      .cpu_addr(cpu_addr),
      .cpu_din(cpu_din),
      .cpu_be(cpu_be),
      .cpu_valid(cpu_valid),
      .cpu_write(cpu_write),
      .cpu_dout(cpu_dout_xe),
      .cpu_ready(cpu_ready_xe),
      .cpu_resp_valid(cpu_resp_valid_xe),
      .debug_status(debug_status),
      .cal_cdat(cal_cdat),
      .cfg_ram_mib(cfg_ram_mib),
      .cfg_seed_en(cfg_seed_en),
      .device_io_wr(device_io_wr_xe),
      .device_io_rd(device_io_rd_xe),
      .device_io_addr(device_io_addr_xe),
      .device_io_din(device_io_din_xe),
      .device_io_dout(device_io_dout),
      .device_rd_wait(device_rd_wait),
      .device_rd_hold(device_rd_hold),
      .top_bank(top_bank_xe),
      .ems_state(ems_state_xe),
      .sound_extend(sound_extend_xe),
      .beep_mute(beep_mute_xe),
      .fdc_irq(fdc_irq_xe),
      .win0_sel(win0_sel_xe),
      .sys16m_en(sys16m_en_xe),
      .ide_rom_enable(ide_rom_enable_xe),
      .top_shadow_en(top_shadow_en_xe),
      .bios_ram_gate(bios_ram_gate_xe),
      .a20_enable(a20_enable_xe),
      .cpu_reset_req(cpu_reset_req_xe),
      .unmapped_writes(unmapped_writes_xe),
      .unmapped_reads(unmapped_reads_xe),
      .last_unmapped_port(last_unmapped_port_xe),
      .post_code(post_code_xe),
      .post_write(post_write_xe),
      .egc_gate(egc_gate),
      .egc_access(egc_access_xe),
      .egc_fgbg(egc_fgbg_xe),
      .egc_ope(egc_ope_xe),
      .egc_fg(egc_fg_xe),
      .egc_mask(egc_mask_xe),
      .egc_bg(egc_bg_xe),
      .egc_sft(egc_sft_xe),
      .egc_leng(egc_leng_xe),
      .egc_shift_we(egc_shift_we_xe),
      .dbg_gate(dbg_gate_xe),
      .dbg_itf_stage(dbg_itf_stage_xe),
      .dbg_artic_hi(dbg_artic_hi_xe),
      .dbg_last_io_addr(dbg_last_io_addr_xe),
      .dbg_last_io_data(dbg_last_io_data_xe),
      .dbg_last_io_rd(dbg_last_io_rd_xe),
      .dbg_last_io_wr(dbg_last_io_wr_xe),
      .cache_flush_req(cache_flush_req_xe),
      .cache_flush_busy(cache_flush_busy_xe),
      .cache_flush_done(cache_flush_done_xe)
  );

  // ==== CHECKS ====
  integer errors = 0;
  integer set_idx;
  reg [15:0] probe_port = 16'h0000;
  reg [7:0]  got = 8'h00;
  reg [7:0]  want = 8'h00;

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

  // THE SET IS APPLIED THROUGH A MACHINE RESET: pc9821_iobus's bios_set_eff latches the
  // OSD field on the reset/reload strobe only, so every entry needs a reset pulse before
  // its read. The stability half of that contract is tb_pc9821_bios_select's.
  task automatic machine_reset;
    begin
      @(negedge clk);
      reset = 1'b1;
      repeat (2) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    // The first reset latches both DUTs' held sets: DUT A on set 0, DUT B on set 1.
    machine_reset;

    // 1. THE STRAP LUT: sweep the four-bit set field across all sixteen entries, each
    //    applied by a machine reset. Set 0 (the
    //    config-less default) must read the MEASURED Xe10 strap, set 1 the Xe byte, and the
    //    reserved sets 2..15 the measured Xe10 strap again.
    sel_xe = 1'b0;
    for (set_idx = 0; set_idx < 16; set_idx = set_idx + 1) begin
      set_x10 = set_idx[3:0];
      want = (set_idx == 1) ? 8'h89 : 8'hA9;
      machine_reset;
      probe_port = 16'h00F0; read_port;
      if (got !== want) begin
        $display("FAIL set %0d reads 0xF0=%02x, want %02x", set_idx, got, want);
        errors = errors + 1;
      end
    end
    set_x10 = 4'd0;
    machine_reset;
    $display("  Machine field 0..15 -> 0xF0: 0xA9 except set 1 = 0x89 (the strap LUT)");

    // 2. the two builds, latched: set 0 (the Xe10, restored above) and set 1 (the Xe).
    probe_port = 16'h00F0; read_port;
    $display("  Xe10 0xF0 -> %02x (the measured PC-9821Xe10 strap)", got);
    if (got !== 8'hA9) begin
      $display("FAIL Xe10 model reads 0xF0=%02x, want the measured 0xA9", got);
      errors = errors + 1;
    end

    sel_xe = 1'b1;
    probe_port = 16'h00F0; read_port;
    $display("  Xe   0xF0 -> %02x (bit 5 clear, the Xe ITF's option-ROM shadow branch)", got);
    if (got !== 8'h89) begin
      $display("FAIL Xe model reads 0xF0=%02x, want 0x89 (bit 5 clear)", got);
      errors = errors + 1;
    end

    // 3. the switch is narrow: the neighbouring straps do not move with the set.
    probe_port = 16'h00F1; read_port;
    if (got !== 8'hFF) begin
      $display("FAIL Xe model 0xF1=%02x, want the open bus 0xFF", got);
      errors = errors + 1;
    end
    probe_port = 16'h00F2; read_port;
    if (got !== 8'hFF) begin
      $display("FAIL Xe model 0xF2=%02x, want the A20 read's masked-state 0xFF", got);
      errors = errors + 1;
    end
    sel_xe = 1'b0;
    probe_port = 16'h00F1; read_port;
    if (got !== 8'hFF) begin
      $display("FAIL Xe10 model 0xF1=%02x, want 0xFF", got);
      errors = errors + 1;
    end
    $display("  0xF1/0xF2 unchanged by the set field");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_BIOS_MODEL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_BIOS_MODEL: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_BIOS_MODEL: TIMEOUT");
  end

endmodule
