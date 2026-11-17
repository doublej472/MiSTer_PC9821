`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Every flush trigger collapses to one whole-L1 cache_flush request, and the write waits for done.
//
// Every flush trigger through the real pc9821_iobus write path collapses to exactly ONE whole-L1 cache_flush request to the core - a one-cycle cache_flush_req pulse, released before the next launch - and the write completes only after the core answers cache_flush_done: the 0x043F=0xA0 guest flush, a 0x043D bank change, a 0x043F E-nibble bank select under 0x043D = 0x00 (docs/probes/SHADOWW.TXT st04/st05), a shadow-enable change (0x043F=0x80, which leaves ems_state alone), an ems_state change (the 0x043F 0x2x writes), a 0x043B sys16m remap, a 0x0461 window-0 change, a 0x053D gate change and a 0x063C select that changes the 0xD8000 window's bank each pulse exactly once, while a redundant no-change write pulses nothing - nor does a 0x043F = 0xE8 under 0x043D = 0x12, where the machine keeps the BIOS top (SHADOWW.TXT st06); the iobus serialises its lanes in S_FLUSH, so the model's walk is never busy at a new request here and the busy-overlap guard is only the iobus's own assertion; a flush-triggering lane followed by exactly one more lane (an `out dx,ax` at 0x043D or at 0x063C) still presents that lane, with its byte, once the flush is done.
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
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  wire ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
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
  reg device_rd_hold = 1'b0;
  reg device_wr_wait = 1'b0;
    // The GDC FF2 query state (a pc9821_iobus input);
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
  // A request launched while the model's walk is busy. The iobus serialises its lanes in
  // S_FLUSH (each write waits for done), so with no guest INVD walk in this model the count
  // stays 0 by construction: it is a tripwire, not a tested case.
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
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

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

  // A multi-lane write (an `out dx,ax` the CPU presents as ONE dword-aligned access with
  // two byte enables). Same handshake as write_byte.
  task automatic write_lanes(input [15:0] dword_port, input [3:0] be, input [31:0] data);
    begin
      p0 = flush_pulses;
      d0 = done_pulses;
      @(negedge clk);
      cpu_addr = {16'd0, dword_port[15:2], 2'b00};
      cpu_be = be;
      cpu_din = data;
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

  // Every byte-lane write the FSM presents, recorded from the last-I/O latch (which loads
  // at S_BYTE for every walked lane): the lanes after a flush-triggering lane must still be
  // walked once the flush is done.
  reg  [15:0] seen_port [0:7];
  reg  [7:0]  seen_data [0:7];
  integer     seen_n = 0;
  always @(posedge clk) begin
    if (dbg_last_io_stb && dbg_last_io_wr) begin
      if (seen_n < 8) begin
        seen_port[seen_n] = dbg_last_io_addr;
        seen_data[seen_n] = dbg_last_io_data;
      end
      seen_n = seen_n + 1;
    end
  end

  task automatic check_walk2(input [8*80-1:0] tag, input [15:0] port_a, input [7:0] data_a,
                             input [15:0] port_b, input [7:0] data_b);
    begin
      if (seen_n != 2) begin
        $display("FAIL %0s: %0d lane write(s) presented, want 2", tag, seen_n);
        errors = errors + 1;
      end else if (seen_port[0] != port_a || seen_data[0] != data_a ||
                   seen_port[1] != port_b || seen_data[1] != data_b) begin
        $display("FAIL %0s: lanes %04h=%02h %04h=%02h, want %04h=%02h %04h=%02h", tag,
                 seen_port[0], seen_data[0], seen_port[1], seen_data[1],
                 port_a, data_a, port_b, data_b);
        errors = errors + 1;
      end
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

    // ==== A shadow-enable change (0x043F=0x80): ONE pulse. The write leaves ems_state
    // alone (pc9821_iobus next_ems_state moves it only on a 0x2x nibble, qemu
    // pc98-mem.c mem_bankctl_write), so the shadow term alone fires ====
    write_byte(16'h043F, 8'h80);
    check_one_flush("0x043F=0x80 shadow change");
    write_byte(16'h043F, 8'h80);
    check_no_flush("0x043F=0x80 redundant write");

    // ==== A 0x043B sys16m remap (bit 2 inverted: clear enables the hole) ====
    // The hole is ON out of reset (0x043B reads 0xFB: the Xe10's measured byte, bit 2 clear),
    // so the remap is the write that sets bit 2.
    write_byte(16'h043B, 8'h04);                 // hole on -> off
    check_one_flush("0x043B sys16m remap");
    write_byte(16'h043B, 8'h04);
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

    // ==== A flush-triggering lane followed by exactly ONE more lane ====
    // `out dx,ax` at 0x043D is one access at dword 0x043C with be=0110: lane 1 (0x043D) flips
    // the bank (BIOS top -> ITF, a flush), lane 2 (0x043E) must still be presented after the
    // flush's done. The flush leaves exactly one pending lane, the shape S_FLUSH's exit must
    // walk rather than drop.
    seen_n = 0;
    write_lanes(16'h043C, 4'b0110, 32'h00_5A_00_00);
    check_one_flush("out dx,ax at 0x043D (bank flip in lane 1)");
    check_walk2("out dx,ax at 0x043D", 16'h043D, 8'h00, 16'h043E, 8'h5A);
    // The same shape from lane 0: `out dx,ax` at 0x063C (be=0011), lane 0 changes the 0xD8000
    // select (0 -> 1), lane 1 (0x063D) must still be presented.
    seen_n = 0;
    write_lanes(16'h063C, 4'b0011, 32'h00_00_A5_FD);
    check_one_flush("out dx,ax at 0x063C (select change in lane 0)");
    check_walk2("out dx,ax at 0x063C", 16'h063C, 8'hFD, 16'h063D, 8'hA5);

    // ==== The 0x043F E-nibble bank select (the main BIOS's bank-1 copy) ====
    // The lane-1 write above left 0x043D = 0x00 (the ITF state). Under it a 0x043F = 0xE2
    // moves the window to bank 1 (docs/probes/SHADOWW.TXT st04/st05; the BIOS's own copy,
    // BANK6@0x5302-0x532A, writes 0x043D = 0x00 before its 0x043F = 0xE2), so the cached
    // lines of the old bank must go; reselecting it moves nothing. Under 0x043D = 0x12 (the
    // BIOS top latched) the machine keeps the BIOS top for 0x043F = 0xE8 (SHADOWW.TXT st06),
    // so that write remaps nothing and must not flush.
    write_byte(16'h043F, 8'hE2);
    check_one_flush("0x043F=0xE2 bank select under 0x043D=0x00");
    write_byte(16'h043F, 8'hE2);
    check_no_flush("0x043F=0xE2 redundant bank select");
    write_byte(16'h043D, 8'h12);
    check_one_flush("0x043D=0x12 back to the BIOS top");
    write_byte(16'h043F, 8'hE8);
    check_no_flush("0x043F=0xE8 under 0x043D=0x12 (BIOS top kept)");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CACHE_FLUSH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CACHE_FLUSH: FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire
