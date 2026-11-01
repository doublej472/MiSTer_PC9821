`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Every flush trigger collapses to one whole-L1 cache_flush request, and the write waits for done.
//
// Every flush trigger through the real pc9821_iobus write path collapses to exactly ONE whole-L1 cache_flush request to the core - a one-cycle cache_flush_req pulse, released before the next launch - and the write completes only after the core answers cache_flush_done: the 0x043F=0xA0 guest flush, a bank or shadow change, an ems_state change (the 0x043F 0x2x writes AND the silent ems_state <= 0 in the other 0x043F writes), a 0x043B sys16m remap, a 0x0461 window-0 change, a 0x053D gate change and a 0x063C select that changes the 0xD8000 window's bank each pulse exactly once, while a redundant no-change write pulses nothing and no request is ever issued while the core's walk is busy.
//
// This is the PLATFORM half of the cache-flush migration (fork
// src/z486/docs/platform-integration.md, "Native cache-flush port"): the old
// pc9821_cache_flush line-sweep sequencer and its per-kind slot/alias decode are
// gone, every trigger owes the same one pulse, and the old "ignore a launch while
// busy" contract survives as the request/done handshake. The core side of the
// handshake (the walk itself, 136 cycles over both L1s) is the fork's own
// wbinvd_flush_rm program and l1 benches; the coherency end of it is
// tb_pc9821_cpu_vram_coherency's flush section. The old tb_pc9821_cache_flush
// pinned the deleted sequencer's sweep ranges and tb_pc9821_flush_encoding_sets
// pinned the deleted per-kind encoding-set sweeps; both subjects are RETIRED as
// the accepted trade (a bank flip now clears the whole L1 - slightly fewer
// retained lines, one constant latency), so this bench pins what replaced them.
// FAIL-FIRST: before the migration the iobus has no cache_flush_req port at all
// (it swept through snoop_addr/snoop_valid), so this bench cannot even build.

`default_nettype none

module tb_pc9821_cache_flush;
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
  reg [3:0]  bios_set = 4'd0;
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  wire ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
  wire top_shadow_en;
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  wire a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0] post_code;
  wire post_write;
  wire [3:0] dbg_gate;
  wire [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
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
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire [1:0] ems_state;
  reg device_rd_hold = 1'b0;
  reg device_wr_wait = 1'b0;
    // The GDC FF2 query state (a pc9821_iobus input since readbacks.md P6);
    // tied quiet here - this bench is not about the FF2 read-back.
    wire [10:0] gdc_ff2_state = 11'd0;

  // ==== The core side of the native flush, MODELLED ====
  // The real core walks both L1s in 136 cycles (src/z486/docs/platform-integration.md);
  // the model walks for 7, because what this bench measures is the CONTRACT - one
  // request per trigger, one done per request, the write held until done - not the
  // walk length (the walk itself is the fork's wbinvd_flush_rm and l1 bench
  // territory). The model keeps the core's own rule that a request observed while
  // busy is IGNORED (and counts it, so the check is not vacuous).
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  reg  cache_flush_busy = 1'b0;
  reg  cache_flush_done = 1'b0;
  reg  [3:0] model_left = 4'd0;
  integer flush_pulses = 0;
  integer done_pulses = 0;
  integer req_while_busy = 0;
  time    last_req_time = 0;
  time    last_done_time = 0;
  always @(posedge clk) begin
    cache_flush_done <= 1'b0;
    if (cache_flush_req) begin
      flush_pulses = flush_pulses + 1;
      last_req_time = $time;
      if (cache_flush_busy) begin
        req_while_busy = req_while_busy + 1;   // the core would IGNORE this launch
      end else begin
        cache_flush_busy <= 1'b1;
        model_left <= 4'd7;
      end
    end else if (cache_flush_busy) begin
      if (model_left == 4'd0) begin
        cache_flush_busy <= 1'b0;
        cache_flush_done <= 1'b1;
        done_pulses = done_pulses + 1;
        last_done_time = $time;
      end else model_left <= model_left - 4'd1;
    end
  end

  // ==== DUT ====
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

  // ==== CHECKS ====
  integer p0 = 0, d0 = 0;
  time    ready_time = 0;

  task automatic write_byte(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      p0 = flush_pulses;
      d0 = done_pulses;
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, data} << (lane * 8);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      ready_time = $time;
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask

  // The write owed one flush: exactly one request, exactly one done, the done
  // BEFORE the write completed (that is the wait), and never a request while busy.
  task automatic check_one_flush(input [8*80-1:0] tag);
    begin
      if (flush_pulses != p0 + 1 || done_pulses != d0 + 1) begin
        $display("FAIL %0s: %0d request(s), %0d done(s), want 1 and 1",
                 tag, flush_pulses - p0, done_pulses - d0);
        errors = errors + 1;
      end
      if (last_done_time >= ready_time) begin
        $display("FAIL %0s: the write completed at %0t before done at %0t",
                 tag, ready_time, last_done_time);
        errors = errors + 1;
      end
      if (req_while_busy != 0) begin
        $display("FAIL %0s: %0d request(s) issued while the core was busy (a redundant walk)",
                 tag, req_while_busy);
        errors = errors + 1;
      end
    end
  endtask

  // The write owed NOTHING: no request, no done.
  task automatic check_no_flush(input [8*80-1:0] tag);
    begin
      if (flush_pulses != p0 || done_pulses != d0) begin
        $display("FAIL %0s: %0d request(s), %0d done(s), want none",
                 tag, flush_pulses - p0, done_pulses - d0);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_CACHE_FLUSH: TIMEOUT");
  end

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // ==== The 0x043F=0xA0 guest "486 cache flush" ====
    write_byte(16'h043F, 8'hA0);
    check_one_flush("0x043F=0xA0 guest flush");
    // It fires every time - it is a flush REQUEST, not a state change.
    write_byte(16'h043F, 8'hA0);
    check_one_flush("0x043F=0xA0 repeat");

    // ==== A bank change pulses once; a redundant re-select pulses nothing ====
    write_byte(16'h043D, 8'h12);                 // ITF bank -> BIOS top
    check_one_flush("0x043D bank flip");
    write_byte(16'h043D, 8'h12);
    check_no_flush("0x043D redundant bank write");

    // ==== A 0x053D gate change (bit 4, then bit 1) ====
    write_byte(16'h053D, 8'h00);                 // close the IDE window (reset: open)
    check_one_flush("0x053D gate bit-4 flip");
    write_byte(16'h053D, 8'h02);                 // bios_ram_gate flips
    check_one_flush("0x053D gate bit-1 flip");
    write_byte(16'h053D, 8'h02);
    check_no_flush("0x053D redundant gate write");

    // ==== An ems_state change (the 0x043F 0x2x writes) ====
    write_byte(16'h043F, 8'h22);                 // identity -> the EMS RAM page
    check_one_flush("0x043F=0x22 ems change");
    write_byte(16'h043F, 8'h22);
    check_no_flush("0x043F=0x22 redundant ems write");

    // ==== The silent ems_state <= 0 reset inside another 0x043F write, combined
    // with the shadow enable's own change: ONE pulse for the whole write ====
    write_byte(16'h043F, 8'h80);
    check_one_flush("0x043F=0x80 shadow+ems change");
    write_byte(16'h043F, 8'h80);
    check_no_flush("0x043F=0x80 redundant write");

    // ==== A 0x043B sys16m remap (bit 2 inverted: clear enables the hole) ====
    write_byte(16'h043B, 8'h00);                 // hole off -> on
    check_one_flush("0x043B sys16m remap");
    write_byte(16'h043B, 8'h00);
    check_no_flush("0x043B redundant remap write");

    // ==== A 0x0461 window-0 overlay change ====
    write_byte(16'h0461, 8'h0A);                 // 0x08 -> 0x0A
    check_one_flush("0x0461 window-0 change");
    write_byte(16'h0461, 8'h0A);
    check_no_flush("0x0461 redundant window-0 write");

    // ==== A 0x063C select that changes what the 0xD8000 window shows ====
    // What each select shows is the machine's (docs/probes/D8BANK-XE10.TXT): 0 and 2 the
    // IDE option ROM, 1 BANK0 0x0000-0x3FFF, 3 BANK0 0x4000-0x7FFF. The Xe10 BIOS's INT 1Fh
    // AH=CEh thunk (BIOS.ROM F560:00E5-00F7: `mov dx,0x63c` ... `retf`) writes 0x063C and far-returns straight into
    // D800:0018 with no cache flush of its own, and the machine runs BANK0's code there, so
    // the old window's lines must not survive the write. Without this pulse the L1 kept
    // IDE-ROM lines of D800:0000-013F and Windows 95's EMM386 /T ran the IDE ROM's INT 1Bh
    // entry on BANK0's stack frame (hardware --dbg-trig capture).
    write_byte(16'h063C, 8'hFD);                 // reset 0xFC: select 0 -> 1
    check_one_flush("0x063C select 0 -> 1 (IDE ROM -> BANK0 low)");
    write_byte(16'h063C, 8'hFD);
    check_no_flush("0x063C redundant select write");
    write_byte(16'h063C, 8'hFF);                 // 1 -> 3
    check_one_flush("0x063C select 1 -> 3 (BANK0 low -> high)");
    write_byte(16'h063C, 8'hFE);                 // 3 -> 2
    check_one_flush("0x063C select 3 -> 2 (BANK0 high -> IDE ROM)");
    write_byte(16'h063C, 8'hFC);                 // 2 -> 0: both show the IDE ROM
    check_no_flush("0x063C select 2 -> 0 (same window)");
    write_byte(16'h063C, 8'h7C);                 // only the read-back bits 7:2 move
    check_no_flush("0x063C read-back-only bits");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CACHE_FLUSH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CACHE_FLUSH: FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire
