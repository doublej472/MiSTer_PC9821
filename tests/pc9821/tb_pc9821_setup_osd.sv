`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SETUP_OSD: the OSD's SETUP items reach port 0x31 and the software-DIP store, and
// every reset re-seeds them.
//
// THE MANIFEST'S CLAIM, word for word (one line, so the checker's whitespace-normalised match sees it):
// The OSD owns the SETUP configuration and every reset re-seeds it: port 0x31 bit 3 is the Text lines field (0xF3 at 25 lines, the measured byte; 0xFB at 20, the bit the BIOS's POST CRT-mode call reads at BANK7@0x595D and NP2kai bios_screeninit adds as 20 lines), and the software-DIP store's reset walk writes the OSD's Memory switch into bank A - 0x871E = 0x3E at initialise (the measured byte, docs/probes/PORTS.TXT:258) and 0x9E at keep (bit 5 the switch, NP2kai io/dipsw.c's 0x871E bit 5 = port 0x31 bit 4; parity bit 7 set so the byte stays odd for the ITF's jpo verify at BANK4@0x46E2), with port 0x31 bit 4 clear (0xE3) and the ITF's 0x851E merge odd in every state; setup_cfg carries the same two bytes to the CG record and mirror; a field changed while the reset is still held (a core load's config arriving after the assertion) re-runs the walk with the new value; a program's own write to the store survives the warm CPU reset that resumes it (out 0xF0, a triple fault) and is re-seeded to the OSD value by the guest's 0x534 reboot (SETUP's exit, BANK4@0x2574), with the CPU held in its reset class for the whole walk; and a program's 0x31 write (the ITF's own out 0x31, BANK4@0x46AB) does not move the GDC clock strap, which answers the OSD until the next reset; bank-A 0x881E is the measured 0x7C at every reset (bit 5 set: SETUP's Sound item not used, the owner's Xe10 as found, docs/probes/XE10CFG-XE10-CFG0.TXT), and a program's 0xDC (the byte the item 'used' leaves, docs/probes/XE10CFG-XE10-CFGSND.TXT) reads back until the 0x534 reboot re-seeds 0x7C. Fail-first by mutation (tests/pc9821/mutations.json): without the reboot re-seed the program's 0x871E survives the reboot, without the in-reset restart the store keeps the default written at the assertion, and with bit 3 constant or the seed byte constant the 20-line and keep steps fail.
//
// THE EVIDENCE (docs/bios-setup.md holds the item table; these are the rows this bench pins).
//   - Text lines: SETUP DIP switch 2 bit 3 (0 = 25 lines, the factory value). The BIOS reads
//     port 0x31 at POST and calls its own CRT mode set with it: BANK7@0x5952-0x5968 `mov ah,0x4
//     / in al,0x31 / test al,0x4 / jz / or ah,0x2 / test al,0x8 / jz / or ah,0x1 / mov al,ah /
//     mov ah,0xa / int 0x18` - INT 18h AH=0Ah bit 0 = 20 lines; NP2kai bios/bios.c
//     bios_screeninit is the same formula. The measured byte is 0xF3 (docs/probes/MEMSW.TXT
//     `0031=F3`), bit 3 clear.
//   - Memory switch: SETUP DIP switch
//     2 bit 4, written to 0x871E bit 5 (BANK3@0x1581/@0x15F7), which NP2kai io/dipsw.c turns into
//     port 0x31 bit 4 (`set = (value & 0x20) >> 1;`). The byte keeps odd parity in bit 7: the
//     ITF verifies 0x87 with `in al,dx / test al,0xff / out dx,al / jpo`
//     (BANK4@0x46E2-0x46E9) and NP2kai's reader sets bit 7 on an even byte.
//   - The reboot: SETUP exits through `out 0x37,0x0F / out 0x37,0x0B` and the 0x534 toggle
//     (BANK4@0x256C-0x2574); the BIOS reset entry with both SHUT bits set toggles 0x534 too
//     (BANK7@0xFD81F). On the machine the store is battery-backed and keeps SETUP's writes; on
//     this core the OSD owns the configuration, so the reboot re-seeds it.
//   - Port 0x31 writes are ignored by the core (pc9821_iobus's HX_0031 write arm): the ITF
//     writes the inverted record row 2 there and reads the strap back later in the same routine.
//   - Sound: SETUP's item for the built-in PCM codec (not the -86 board) is 0x881E bit 5,
//     1 = not used, with the parity bit 7 kept odd (docs/bios-setup.md, the Sound row). The
//     owner's Xe10 as found has it not used and reads 0x7C; set to "used" the same machine
//     reads 0xDC (docs/probes/XE10CFG-XE10-CFG0.TXT / -CFGSND.TXT, `SDIPA0 7C 02 76 3E 7C`
//     against `... 3E DC`). The core models the -86 board and no codec, which is that
//     machine as found.
module tb_pc9821_setup_osd;
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
  wire sdip_seed_pulse;
  wire [23:0] setup_cfg;

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
      .text_lines_20(text_lines_20),
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

  // The GDC-clock field's own mid-run flip (step (f)).
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
  task automatic merge_odd(input [8*96-1:0] what);
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


  // The guest's reboot: the 0x534 soft reset, as BANK7@0xFD81F does it (read, flip bit 0,
  // write back). One soft_reboot pulse follows, and the store's walk with it.
  task automatic reboot_534;
    begin
      probe_port = 16'h0534;
      read_port;
      write_port(16'h0534, got ^ 8'h01);
      repeat (60) @(posedge clk);
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

  // The ITF's direct odd-parity verify of a bank-A byte (BANK4@0x46E2-0x46E9 `jpo`).
  task automatic check_odd(input [15:0] port, input [8*96-1:0] what);
    begin
      probe_port = port;
      read_port;
      if (^got !== 1'b1) begin
        $display("FAIL %0s: %04x=%02x is EVEN", what, port, got);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_cfg(input [15:0] want, input [8*96-1:0] what);
    begin
      if (setup_cfg[15:0] !== want) begin
        $display("FAIL %0s: setup_cfg=%04x, want %04x", what, setup_cfg[15:0], want);
        errors = errors + 1;
      end
    end
  endtask

  integer held;

  initial begin
    // (a) The defaults: the measured machine.
    machine_reset;
    repeat (40) @(posedge clk);
    write_port(16'h8F1F, 8'h80);                      // bank A, as the ITF selects it
    check_port(16'h0031, 8'hF3, "(a) defaults, port 0x31");
    // Floppy mode at its default, Auto (1M): the Xe10's 0x861E byte in that mode
    // (docs/probes/XE10CFG-XE10-CFGF3.TXT, `SDIPA0 7C 02 F7 3E 7C`).
    check_port(16'h861E, 8'hF7, "(a) defaults, 0x861E (Floppy mode Auto (1M))");
    check_port(16'h871E, 8'h3E, "(a) defaults, 0x871E");
    check_port(16'h881E, 8'h7C, "(a) defaults, 0x881E: Sound not used (as found)");
    check_cfg(16'h3EF3, "(a) defaults");
    merge_odd("(a) defaults");

    // (b) Text lines 20: bit 3 of port 0x31, applied at the next machine reset only.
    @(negedge clk); text_lines_20 = 1'b1;
    repeat (5) @(posedge clk);
    check_port(16'h0031, 8'hF3, "(b) mid-run Text lines change, port 0x31 unchanged");
    machine_reset;
    repeat (40) @(posedge clk);
    check_port(16'h0031, 8'hFB, "(b) Text lines 20, port 0x31");
    merge_odd("(b) Text lines 20");
    check_cfg(16'h3EFB, "(b) Text lines 20");
    @(negedge clk); text_lines_20 = 1'b0;

    // (c) Memory switch keep: port 0x31 bit 4 and the bank-A 0x871E seed byte.
    @(negedge clk); msw_hold = 1'b1;
    machine_reset;
    repeat (40) @(posedge clk);
    write_port(16'h8F1F, 8'h80);
    check_port(16'h871E, 8'h9E, "(c) Memory switch keep, 0x871E");
    check_odd(16'h871E, "(c) 0x871E verify");
    check_port(16'h861E, 8'hF7, "(c) 0x861E stays the Floppy mode byte");
    check_port(16'h0031, 8'hE3, "(c) Memory switch keep, port 0x31");
    merge_odd("(c) keep");
    check_cfg(16'h9EE3, "(c) keep");
    @(negedge clk); msw_hold = 1'b0;

    // (d) A field changed while the reset is still held: the walk started at the assertion
    //     wrote the old value, so it must run again with the new one before the release.
    @(negedge clk); reset = 1'b1;
    repeat (60) @(posedge clk);                       // the assertion's walk is long over
    @(negedge clk); msw_hold = 1'b1;
    repeat (60) @(posedge clk);
    @(negedge clk); reset = 1'b0;
    repeat (4) @(posedge clk);
    write_port(16'h8F1F, 8'h80);
    check_port(16'h871E, 8'h9E, "(d) Memory switch set inside the reset window, 0x871E");
    @(negedge clk); msw_hold = 1'b0;
    machine_reset;
    repeat (40) @(posedge clk);

    // (e) A program's write lasts until the next reset: write 0x871E as SETUP's "keep" would.
    write_port(16'h8F1F, 8'h80);
    write_port(16'h871E, 8'h9E);
    check_port(16'h871E, 8'h9E, "(e) program write, 0x871E read back");
    warm_cpu_reset;
    repeat (60) @(posedge clk);
    check_port(16'h871E, 8'h9E, "(e) after a warm CPU reset (resume), the program's 0x871E stays");
    // The guest's reboot re-seeds the store to the OSD value, with the CPU held throughout.
    probe_port = 16'h0534;
    read_port;
    write_port(16'h0534, got ^ 8'h01);
    held = 0;
    repeat (30) begin
      @(posedge clk);
      if (cpu_reset_req) held = held + 1;
    end
    if (held < 24) begin
      $display("FAIL (e) the CPU was held for %0d of the walk's 24 cycles", held);
      errors = errors + 1;
    end
    repeat (30) @(posedge clk);
    check_port(16'h871E, 8'h3E, "(e) after the 0x534 reboot, 0x871E is the OSD value again");

    // (f) The GDC clock: a program's write to port 0x31 (the ITF's own `out 0x31`) does not
    //     move the strap, and the strap answers the OSD's 5 MHz after the next reset.
    write_port(16'h0031, 8'h73);
    check_port(16'h0031, 8'hF3, "(f) a program's 0x31 write, port 0x31 is the OSD strap");
    gdc_flip(1'b1);
    reboot_534;
    check_port(16'h0031, 8'hF3, "(f) a reboot keeps the reset-latched strap");
    machine_reset;
    repeat (40) @(posedge clk);
    check_port(16'h0031, 8'h73, "(f) GDC 5 MHz after the machine reset");
    merge_odd("(f) 5 MHz");
    gdc_flip(1'b0);
    machine_reset;
    repeat (40) @(posedge clk);
    check_port(16'h0031, 8'hF3, "(f) back to 2.5 MHz");

    // (g) Sound: a program storing SETUP's "used" byte 0xDC at 0x881E reads it back, a warm
    //     CPU reset keeps it, and the 0x534 reboot re-seeds the as-found 0x7C.
    write_port(16'h8F1F, 8'h80);
    check_port(16'h881E, 8'h7C, "(g) 0x881E before the program's write");
    write_port(16'h881E, 8'hDC);
    check_port(16'h881E, 8'hDC, "(g) a program's Sound used byte reads back");
    warm_cpu_reset;
    repeat (60) @(posedge clk);
    check_port(16'h881E, 8'hDC, "(g) after a warm CPU reset (resume), 0x881E stays");
    reboot_534;
    write_port(16'h8F1F, 8'h80);
    check_port(16'h881E, 8'h7C, "(g) after the 0x534 reboot, 0x881E is the as-found byte");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SETUP_OSD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SETUP_OSD: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_SETUP_OSD: TIMEOUT");
  end

endmodule
