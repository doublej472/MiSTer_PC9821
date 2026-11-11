`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_BIOS_SELECT: the OSD Machine field applies ONLY at machine reset /
// reload. A reset latches the Xe10 set (entry 0, the config-less default) and port 0xF0
// reads the MEASURED strap 0xA9; a mid-run OSD flip to the Xe set (or to any reserved
// set) must move NOTHING - the strap is still 0xA9 on every later read, and so it stays
// across the warm CPU-reset class (out 0xF0 / 0x534 / a z486 shutdown), because that
// re-enters the same ITF on the same machine; only the NEXT machine reset / reload
// re-samples the field and moves the strap to the Xe byte 0x89, and the reset after that
// restores 0xA9 once the OSD is back on the default.
//
// WHY the strap must be frozen mid-run: the two ITFs read this byte's bit 5 differently -
// the Xe10 masks bits 5 and 6 together (BANK4@0xF8207: and al,0x60; xor al,0x60), the Xe
// tests bit 5 alone (BANK4@0xF81DF: test al,0x20). A strap that moved under the running
// firmware would change the machine's identity mid-boot (or mid-DOS), and a flip that
// landed before the ITF's own read would silently reroute its option-ROM shadow branch.
//
// THE RESET/RELOAD STROBE this bench pulses is pc9821_iobus's reset port, which
// pc9821_system drives with the core's machine-reset/reload strobe `reset || !cpu_run`
// (its iobus instance): the platform reset (OSD Reset, the user button, the RESET pin)
// OR the pack-reload window (cpu_run is low while a ROM pack is (re)loading). The warm
// CPU-reset class deliberately does NOT latch: the machine stays consistent across its
// own resets until the next machine reset / reload.
//
//
// STEP (e) IS THE ITF'S OWN GATE, TRANSCRIBED FROM BANK4.BIN. It reads the twelve bank-A
// bytes and the ten bank-B bytes the way the firmware does (the `test al,0FFh` / `jnp`
// odd-parity branches, the write-back each direct byte gets, the XOR pair, and the
// port-0x31 MERGE that stands in for index 1), at the measured machine's strap and at
// 5 MHz. Index 1 is the one bank-A byte the ITF does NOT check directly, and it is
// checked directly in bank B - so this bench is the one that says which side of the
// device a fix for the 2026-09-26 'SET THE SOFTWARE DIP-SWITCH' loop belongs on.
// FAIL-FIRST: on the old wiring (lane_rdata = machine_id_strap(live OSD field)) step (b)
// reads 0x89 one cycle after the flip and this bench fails there. tb_pc9821_bios_model
// pins the strap LUT's VALUE mapping (which set answers which byte); this bench pins WHEN
// the set is allowed to change.
//
// THE MANIFEST'S CLAIM, word for word (one line, so the checker's whitespace-normalised match sees it):
// The Machine field applies ONLY at machine reset / reload: after a reset latches the Xe10 set, port 0xF0 reads the measured 0xA9, and a mid-run OSD flip to the Xe set (or any reserved set) leaves the strap at 0xA9 on every later read and across the warm CPU-reset class (out 0xF0, 0x534, a z486 shutdown); only the next machine reset / reload re-samples the field and moves the strap to the Xe byte 0x89, and the reset after that restores 0xA9 with the OSD back on the config-less default. The strap must be stable for the whole boot because the two ITFs read its bit 5 differently (the Xe10 masks bits 5 and 6 together at BANK4@0xF8207, the Xe tests bit 5 alone at BANK4@0xF81DF). Fail-first: on the old live-apply wiring the mid-run flip reads 0x89 immediately and this bench fails at step (b). And the OSD GDC Clock field (port 0x31 bit 7 - the machine's own GDC 2.5/5 MHz strap, 0xF3 with bit 7 set at 2.5 MHz, 0x73 at 5 MHz, the BIOS sampling it once at POST at BIOS.ROM@0xFD93C and deriving the games' work-area 0x54D bit 2 from it) follows the identical contract on its own byte: entry 0 answers the measured 0xF3, a mid-run flip and the warm CPU-reset class move it not at all, and only the next machine reset applies 0x73 - each step FAIL-FIRST against a live-apply wiring, which answers 0x73 immediately in step (d2). And the ITF's own software-DIP-switch verify is transcribed whole (BANK4@0xFC6BA-0xFC726: the direct odd-parity pass over bank A's 0x84/0x86-0x88/0x89^0x8A/0x8B-0x8F, the port-0x31 MERGE for 0x851E, and bank B's ten direct bytes) and passes at BOTH straps, because index 1's bit 4 is the DIP-2 register's parity bit and the machine-reset walk SEEDS it from the reset-qualified strap latch over the measured 0x02 byte; FAIL-FIRST, because with bit 4 stored the 5 MHz merge (0x73 & 0xEF) | (0x02 & 0x10) = 0x63 is EVEN, the ITF's repair path cannot own the bit, and its SET THE SOFTWARE DIP-SWITCH printer (BANK4@0xFC8DE-0xFC903) writes 0xF0 = 0x00 - a reboot loop on this core. Step (e3) pins the SHAPE of that fix at both straps: after a machine reset - the store's restore walk, now the ONLY restore, the OSD `Reset DIPs` action this step used to name having been removed - the store holds the MEASURED 0x02 data - the machine's own bank A image, docs/probes/PORTS.TXT:258 - with bit 4 seeded, so 0x851E reads 0x12 with 5 MHz selected and 0x02 at the machine's own 2.5 MHz, a recovery route that does not work on hardware. And port 0xF0 bit 5 is IDE unit 0's drive-present line: the ITF builds its IDE drive bitmap and the 0x457 byte from bits 5/6 (BANK4@0x19DF-0x19F2, BANK4@0x1B6C-0x1B8F), so with a drive on bank 0 (the hard disk, bank 0's master in the core's fixed layout) the measured 0xA9 reads 0x89 and returns to 0xA9 without it (step f).


module tb_pc9821_bios_select;
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
      .gdc_clock_5m(gdc_clock_5m), 
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

  // ==== THE AUTHENTIC ITF'S OWN SOFTWARE-DIP-SWITCH VERIFY ==================================
  // Not a paraphrase: the whole sequence the NEC Initial Test Firmware runs before it will
  // draw anything, read out of BANK4.BIN (file offsets; phys = 0xF8000 + off) with
  // `objdump -D -b binary -m i8086`. Bank A is 0xFC6BA-0xFC70D, bank B 0xFC70F-0xFC726:
  //
  //   FC6BA  mov dx,0x8F1F / mov al,0x80 / out       ; select bank A (enable)
  //   FC6C0  in al,0x841E / test al,0FFh / out / jnp  ; DIRECT odd-parity byte 0
  //   FC6CC  in al,0x851E / mov ah,al
  //   FC6D2  in al,0x31   / and ax,0x10EF / or al,ah / out al,(same dx) / jnp
  //          -> merged = (port31 & 0xEF) | (sdip1 & 0x10), written back, ODD required
  //   FC6DF  mov cx,3 / in-test-out-jnp loop over 0x861E,0x871E,0x881E   ; 3 DIRECT bytes
  //   FC6FA  in al,0x891E / mov ah,al / in al,0x8A1E / xor ah,al / jnp     ; the XOR PAIR
  //   FC707  mov cx,5 / the same read-test-write-back loop over 0x8B1E..0x8F1E
  //   FC70F  mov dx,0x8F1F / mov al,0xC0 / out       ; select bank B
  //   FC715  mov cx,0x0A / loop over 0x841E..0x8D1E  ; 10 DIRECT bytes
  //
  // Two facts this transcription settles, both of which decide where a fix belongs:
  //   * INDEX 1 IS NOT CHECKED DIRECTLY. The direct pass covers 0x84, 0x86-0x88, the
  //     0x89^0x8A XOR pair and 0x8B-0x8F, and 0x851E sits between the first byte and the
  //     loop as the port-0x31 MERGE. So bit 4 of that register is its parity bit (NP2kai's
  //     per-register parity positions, io/dipsw.c: bit 4 for 0x85) and is not guest data -
  //     which is why a value presented on the READ side can be right where a stored one
  //     cannot be.
  //   * BANK B'S 0x851E IS CHECKED DIRECTLY (it is one of the ten), so whatever the bank-A
  //     read presents must NOT reach bank B: bank B index 1 is the seed 0x80, already odd.
  //
  // THE CONSEQUENCE OF A FAILED BYTE is in the firmware too: any `jnp` that does not
  // continue jumps to 0xFC7B2 (the repair/factory-rewrite path, which cannot own bit 4), and
  // the register stays invalid through it, so the ITF reaches its message printer at
  // 0xFC8DE-0xFC903, prints "SET THE SOFTWARE DIP-SWITCH", writes 0xF0 = 0x00 and halts.
  // On this core `out 0xF0,0` raises cpu_reset_req, so that terminal state IS the observed
  // POST -> message -> reset -> POST loop (the ITF's BANK4 disassembly).
  task automatic itf_sdip_verify(input bit mhz5);
    reg [7:0] p31, v, merge;
    integer bad;
    begin
      bad = 0;
      probe_port = 16'h0031;
      read_port;
      p31 = got;                        // FC6D2: in al,0x31
      if (mhz5 !== (p31[7] === 1'b0)) begin
        $display("FAIL step (e): port 0x31 = %02x does not carry the selected GDC clock (5 MHz = %0d)",
                 p31, mhz5);
        bad = bad + 1;
      end

      // ---- bank A: 0x8F1F = 0x80 (FC6BA) --------------------------------------------
      write_port(16'h8F1F, 8'h80);
      // FC6C0-FC6C7: byte 0 is a DIRECT check, with the byte written straight back.
      probe_port = 16'h841E; read_port; v = got; write_port(16'h841E, v);
      if (!(^v)) begin
        $display("FAIL step (e): 0x841E = %02x has EVEN parity, so the ITF's `test al,0FFh / jnp` at BANK4@0xFC6C4 does not continue", v);
        bad = bad + 1;
      end
      // FC6CC-FC6DA: THE MERGE. The merged byte is written back to the same port, so the
      // second read below is what a store-backed bit 4 would fail and a presented one pass.
      probe_port = 16'h851E; read_port; v = got;
      merge = (p31 & 8'hEF) | (v & 8'h10);
      write_port(16'h851E, merge);
      $display("  (e) ITF verify, 5 MHz = %0d: 841E/851E read (0x851E = %02x), merged = (%02x & EF) | bit4 = %02x",
               mhz5, v, p31, merge);
      if (^merge) $display("      -> ODD: the ITF continues");
      else        $display("      -> EVEN: the ITF jumps to its repair");
      if (!(^merge)) begin
        $display("FAIL step (e): with 5 MHz = %0d the merged DIP-2 byte 0x%02x has EVEN parity; the ITF jumps to BANK4@0xFC7B2, bit 4 is not a bit a write can own, and the register stays invalid so it prints SET THE SOFTWARE DIP-SWITCH (BANK4@0xFC8DE-0xFC903) and writes 0xF0 = 0x00 - a reset, i.e. POST -> message -> reset -> POST forever",
                 mhz5, merge);
        bad = bad + 1;
      end
      // ...and the SAME register one pass later: the merge has been stored, so this is the
      // read that tells a presented parity bit from a stored one.
      probe_port = 16'h851E; read_port; v = got;
      merge = (p31 & 8'hEF) | (v & 8'h10);
      if (!(^merge)) begin
        $display("FAIL step (e): after the ITF stored its merge, 0x851E reads %02x so the merged byte is 0x%02x - EVEN again: the store cannot hold its way out of the bad parity",
                 v, merge);
        bad = bad + 1;
      end
      // FC6DF-FC6F3: three DIRECT bytes.
      probe_port = 16'h861E; read_port; v = got; write_port(16'h861E, v);
      if (!(^v)) begin
        $display("FAIL step (e): 0x861E = %02x has EVEN parity (BANK4@0xFC6E6)", v);
        bad = bad + 1;
      end
      probe_port = 16'h871E; read_port; v = got; write_port(16'h871E, v);
      if (!(^v)) begin
        $display("FAIL step (e): 0x871E = %02x has EVEN parity (BANK4@0xFC6E6)", v);
        bad = bad + 1;
      end
      probe_port = 16'h881E; read_port; v = got; write_port(16'h881E, v);
      if (!(^v)) begin
        $display("FAIL step (e): 0x881E = %02x has EVEN parity (BANK4@0xFC6E6)", v);
        bad = bad + 1;
      end
      // FC6FA-FC702: the XOR PAIR - read-only, no write-back.
      probe_port = 16'h891E; read_port; v = got;
      probe_port = 16'h8A1E; read_port; merge = v ^ got;
      if (!(^merge)) begin
        $display("FAIL step (e): 0x891E ^ 0x8A1E = %02x has EVEN parity (BANK4@0xFC700)", merge);
        bad = bad + 1;
      end
      // FC707-FC726: five DIRECT bytes, 0x8B1E..0x8F1E.
      probe_port = 16'h8B1E; read_port; v = got; write_port(16'h8B1E, v);
      if (!(^v)) begin $display("FAIL step (e): 0x8B1E = %02x has EVEN parity (BANK4@0xFC6E6)", v); bad = bad + 1; end
      probe_port = 16'h8C1E; read_port; v = got; write_port(16'h8C1E, v);
      if (!(^v)) begin $display("FAIL step (e): 0x8C1E = %02x has EVEN parity (BANK4@0xFC6E6)", v); bad = bad + 1; end
      probe_port = 16'h8D1E; read_port; v = got; write_port(16'h8D1E, v);
      if (!(^v)) begin $display("FAIL step (e): 0x8D1E = %02x has EVEN parity (BANK4@0xFC6E6)", v); bad = bad + 1; end
      probe_port = 16'h8E1E; read_port; v = got; write_port(16'h8E1E, v);
      if (!(^v)) begin $display("FAIL step (e): 0x8E1E = %02x has EVEN parity (BANK4@0xFC6E6)", v); bad = bad + 1; end
      probe_port = 16'h8F1E; read_port; v = got; write_port(16'h8F1E, v);
      if (!(^v)) begin $display("FAIL step (e): 0x8F1E = %02x has EVEN parity (BANK4@0xFC6E6)", v); bad = bad + 1; end

      // ---- bank B: 0x8F1F = 0xC0, ten DIRECT bytes 0x841E..0x8D1E (FC70F-FC726) -----
      write_port(16'h8F1F, 8'hC0);
      probe_port = 16'h841E; read_port; v = got; write_port(16'h841E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x841E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h851E; read_port; v = got; write_port(16'h851E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x851E = %02x has EVEN parity (BANK4@0xFC71C) - bank B's index 1 is DIRECTLY checked, so the bank-A read must not patch it", v); bad = bad + 1; end
      probe_port = 16'h861E; read_port; v = got; write_port(16'h861E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x861E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h871E; read_port; v = got; write_port(16'h871E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x871E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h881E; read_port; v = got; write_port(16'h881E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x881E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h891E; read_port; v = got; write_port(16'h891E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x891E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h8A1E; read_port; v = got; write_port(16'h8A1E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x8A1E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h8B1E; read_port; v = got; write_port(16'h8B1E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x8B1E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h8C1E; read_port; v = got; write_port(16'h8C1E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x8C1E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end
      probe_port = 16'h8D1E; read_port; v = got; write_port(16'h8D1E, v);
      if (!(^v)) begin $display("FAIL step (e): bank B 0x8D1E = %02x has EVEN parity (BANK4@0xFC71C)", v); bad = bad + 1; end

      write_port(16'h8F1F, 8'h00);       // drop the access enable again (FC72B writes 0x80)
      if (bad != 0) begin
        $display("FAIL step (e): the ITF's own verify fails on %0d byte(s) at 5 MHz = %0d, so its message printer runs and the core reboots",
                 bad, mhz5);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // The first machine reset latches set 0 (the Xe10, the config-less default).
    machine_reset;

    // (a) the Xe10 set answers its MEASURED strap.
    check_f0(8'hA9);
    $display("  (a) Xe10 set latched at reset: 0xF0 -> %02x (want the measured 0xA9)", got);
    if (got !== 8'hA9) begin
      $display("FAIL step (a): the Xe10 set must answer 0xA9");
      errors = errors + 1;
    end

    // (b) MID-RUN OSD FLIPS MOVE NOTHING: neither the Xe set nor the reserved sets may
    //     reach the strap, and neither may the warm CPU-reset class. THIS is the step
    //     the old live-apply wiring fails.
    osd_flip(4'd1);
    check_f0(8'hA9);
    $display("  (b) mid-run flip to the Xe set: 0xF0 -> %02x (must STILL be 0xA9)", got);
    if (got !== 8'hA9) begin
      $display("FAIL step (b): a mid-run OSD change moved the strap to %02x", got);
      errors = errors + 1;
    end
    warm_cpu_reset;
    check_f0(8'hA9);
    $display("  (b) warm CPU reset: 0xF0 stays %02x", got);
    if (got !== 8'hA9) begin
      $display("FAIL step (b): the strap must be stable across the CPU-reset class");
      errors = errors + 1;
    end

    // (b2) THE RESERVED-SET CASE, MADE DISCRIMINATING. The old
    //      check flipped to a reserved set while the strap ALREADY read 0xA9 and
    //      asserted 0xA9 - vacuous, since the strap LUT maps every reserved set to
    //      the Xe10's 0xA9 in BOTH wirings (tb_pc9821_bios_model). Here the strap is
    //      the Xe's 0x89 (applied by the reset below) and a MID-RUN flip to a
    //      RESERVED set must not move it even where the live LUT would answer 0xA9 -
    //      a live-apply wiring fails this by name.
    machine_reset;                  // bios_set is 1: the reset applies the Xe 0x89
    check_f0(8'h89);
    osd_flip(4'd4);                 // a reserved set, mid-run
    check_f0(8'h89);
    $display("  (b2) reserved set mid-run on the Xe strap: 0xF0 stays %02x (a live LUT would answer 0xA9)", got);
    if (got !== 8'h89) begin
      $display("FAIL step (b2): a reserved mid-run set moved the strap to %02x", got);
      errors = errors + 1;
    end
    // ...but the freeze is apply-at-RESET, not "the strap is stuck": a reset on the
    // reserved set applies its own LUT value (the Xe10 0xA9).
    machine_reset;
    check_f0(8'hA9);
    $display("  (b2) reset on the reserved set: 0xF0 -> %02x (its LUT value 0xA9)", got);
    if (got !== 8'hA9) begin
      $display("FAIL step (b2): the reset must apply the reserved set's own LUT value");
      errors = errors + 1;
    end

    // (c) THE NEXT MACHINE RESET / RELOAD APPLIES IT.
    osd_flip(4'd1);                 // the Xe set is pending; the strap is frozen
    check_f0(8'hA9);
    machine_reset;
    check_f0(8'h89);
    $display("  (c) after the next machine reset: 0xF0 -> %02x (want the Xe 0x89)", got);
    if (got !== 8'h89) begin
      $display("FAIL step (c): the reset must apply the pending Xe set (0x89)");
      errors = errors + 1;
    end

    // ...and symmetrically: back to the default mid-run freezes at 0x89 until the reset.
    osd_flip(4'd0);
    check_f0(8'h89);
    $display("  (c) mid-run flip back to Xe10: 0xF0 -> %02x (must STILL be 0x89)", got);
    if (got !== 8'h89) begin
      $display("FAIL step (c): the return flip must also wait for the reset");
      errors = errors + 1;
    end
    machine_reset;
    check_f0(8'hA9);
    $display("  (c) reset back on the default: 0xF0 -> %02x (the Xe10 0xA9 again)", got);
    if (got !== 8'hA9) begin
      $display("FAIL step (c): the reset on set 0 must restore the measured 0xA9");
      errors = errors + 1;
    end

    // (d) THE GDC CLOCK FIELD, the same reset-latch contract on its own strap byte.
    // Port 0x31 bit 7 SET is the 2.5 MHz the measured Xe10 answers (0xF3) and entry 0
    // of the OSD list; bit 7 CLEAR is 0x73 and 5 MHz. The BIOS samples this byte once
    // at POST (BIOS.ROM@0xFD93C -> work area 0x54D bit 5, which the display-mode helper
    // turns into the games' 0x54D bit 2), so the LATCH is what keeps a mid-run OSD
    // change from moving the clock under the running firmware - the step a live-apply
    // wiring fails by name here (it would answer 0x73 immediately in (d2)).
    machine_reset;                  // gdc_clock_5m is 0: entry 0, 2.5 MHz
    check_31(8'hF3);
    $display("  (d) reset on entry 0 (2.5 MHz): 0x31 -> %02x (the measured 0xF3)", got);
    if (got !== 8'hF3) begin
      $display("FAIL step (d): entry 0 must answer the machine's measured 0xF3");
      errors = errors + 1;
    end
    gdc_flip(1'b1);                 // mid-run flip to 5 MHz: must move nothing
    check_31(8'hF3);
    $display("  (d2) mid-run flip to 5 MHz: 0x31 -> %02x (must STILL be 0xF3)", got);
    if (got !== 8'hF3) begin
      $display("FAIL step (d2): a mid-run OSD change moved the GDC-clock strap to %02x", got);
      errors = errors + 1;
    end
    warm_cpu_reset;                 // the CPU-reset class must not apply it either
    check_31(8'hF3);
    $display("  (d2) warm CPU reset: 0x31 stays %02x", got);
    if (got !== 8'hF3) begin
      $display("FAIL step (d2): the strap must be stable across the CPU-reset class");
      errors = errors + 1;
    end
    machine_reset;                  // the next machine reset applies 5 MHz
    check_31(8'h73);
    $display("  (d3) after the next machine reset: 0x31 -> %02x (5 MHz, bit 7 clear)", got);
    if (got !== 8'h73) begin
      $display("FAIL step (d3): the reset must apply the pending 5 MHz selection");
      errors = errors + 1;
    end
    gdc_flip(1'b0);                 // and back: mid-run, then at the reset
    check_31(8'h73);
    $display("  (d3) mid-run flip back to 2.5 MHz: 0x31 -> %02x (must STILL be 0x73)", got);
    if (got !== 8'h73) begin
      $display("FAIL step (d3): the return flip must also wait for the reset");
      errors = errors + 1;
    end
    machine_reset;
    check_31(8'hF3);
    $display("  (d3) reset back on entry 0: 0x31 -> %02x (the measured 0xF3 again)", got);
    if (got !== 8'hF3) begin
      $display("FAIL step (d3): the reset on entry 0 must restore the measured 0xF3");
      errors = errors + 1;
    end
    // (e) THE ITF'S OWN GATE, at the measured machine's own state (2.5 MHz): every byte it
    //     checks must pass, so a cold core draws its configuration screen without repair.
    itf_sdip_verify(1'b0);
    // (e2) THE SAME GATE AT 5 MHz. The store is a BATTERY-BACKED image (seeded once in an
    //      `initial` block, so it cannot see an OSD field at all) and port 0x31 bit 7 -- the
    //      one bit the 5 MHz selection moves -- decides the DIP-2 register's parity bit, so
    //      this is the step that fails while bit 4 is a STORED bit and passes when the READ
    //      presents it. FAIL-FIRST: with sdip_powerup's index 1 still 0x02 the merge below is
    //      0x63 (EVEN) and the bench fails here by name.
    gdc_flip(1'b1);
    machine_reset;
    itf_sdip_verify(1'b1);

    // (e3) A MACHINE RESET MUST LEAVE A STORE THE ITF ACCEPTS, at the strap the
    //      card is set to - the recovery route for a store the ITF rejects
    //      (there is no OSD `Reset DIPs` action; the machine-reset seed's restore walk is
    //      the recovery). It
    //      writes the measured power-up image, and at 5 MHz the image's own parity bit is 0,
    //      so the READ is what has to supply it. The store byte is asserted separately from
    //      the port byte: the measured bank must hold the measured byte (docs/probes/
    //      PORTS.TXT:258 is the machine's bank A, `841E7C 851E02 861E76 ... 8F1E98`, i.e.
    //      0x851E = 0x02), and only the PORT presents the register's parity bit.
    machine_reset;
    repeat (40) @(posedge clk);          // the restore walk writes one byte per cycle
    probe_port = 16'h851E;
    read_port;
    $display("  (e3) after a machine reset at 5 MHz: the store holds 0x%02x and 0x851E reads 0x%02x",
             dut.sdip[5'd1], got);
    // The reset walk SEEDS that bit from the same strap latch (the Xe10 stores a written bit 4
    // and reads it back: docs/probes/XE10CFG-XE10-CFGWR.TXT `RT 851E was=02 wrote=12 got=12`),
    // so the store holds the measured 0x02 data with the parity bit set: 0x12.
    if (dut.sdip[5'd1] !== 8'h12) begin
      $display("FAIL step (e3): the store's index 1 is 0x%02x, want 0x12 (the measured 0x02 data with the seeded parity bit)",
               dut.sdip[5'd1]);
      errors = errors + 1;
    end
    if (got !== 8'h12) begin
      $display("FAIL step (e3): 0x851E reads 0x%02x, want 0x12 = the measured 0x02 data with the register's parity bit (bit 4) SET, which is what makes the ITF's merge odd at 5 MHz",
               got);
      errors = errors + 1;
    end
    itf_sdip_verify(1'b1);

    // (e4) AND AT THE MACHINE'S OWN STRAP the restored store reads back its measured byte
    //      unchanged: 0xF3 with bit 4 clear merges odd, so the derived parity bit is 0 and
    //      the presented byte is the captured one.
    gdc_flip(1'b0);
    machine_reset;
    repeat (40) @(posedge clk);
    probe_port = 16'h851E;
    read_port;
    $display("  (e4) after a machine reset at 2.5 MHz: 0x851E reads 0x%02x (the captured byte)", got);
    if (got !== 8'h02) begin
      $display("FAIL step (e4): 0x851E reads 0x%02x at entry 0, want the measured 0x02 (docs/probes/PORTS.TXT:258): at the machine's own strap the presented byte is the captured one",
               got);
      errors = errors + 1;
    end
    itf_sdip_verify(1'b0);

    // (f) PORT 0xF0 BIT 5 IS IDE UNIT 0's DRIVE-PRESENT LINE (active low). The machine's ITF
    //     builds the IDE drive bitmap from bits 5/6 (BANK4@0x19DF-0x19F2: bit 5 clear -> slot 0,
    //     bit 6 clear -> slot 2) and the 0x457 unit-0/unit-2 byte from the same two bits
    //     (BANK4@0x1B6C-0x1B8F; NP2kai bios.c:322 keys 0x457 to units 0 and 2). The measured
    //     Xe10 0xA9 is bit 5 SET (bank 0 empty) and bit 6 clear (the probed machine's CF card in the CD
    //     connector, bank 1), so with a drive on bank 0 as well the byte is 0xA9 & ~0x20 = 0x89 -
    //     and nothing else moves. 0x89 is the stock CD-equipped Xe10's layout (disk on bank 0, CD
    //     on bank 1), which the core's CD build reproduces; bit 6 in the build without the CD is
    //     tb_pc9821_ide_layout's (this bench ties ide_unit2_present to 1, a bank-1 drive).
    bios_set = 4'd0;
    machine_reset;
    check_f0(8'hA9);
    ide_unit0 = 1'b1;
    repeat (2) @(posedge clk);
    check_f0(8'h89);
    $display("  (f) a drive on IDE unit 0: 0xF0 -> %02x (want 0x89: bit 5 is unit 0's drive-present line)", got);
    if (got !== 8'h89) begin
      $display("FAIL step (f): with a drive on bank 0 the Xe10 strap must clear bit 5 (0x89)");
      errors = errors + 1;
    end
    ide_unit0 = 1'b0;
    repeat (2) @(posedge clk);
    check_f0(8'hA9);

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_BIOS_SELECT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_BIOS_SELECT: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_BIOS_SELECT: TIMEOUT");
  end

endmodule
