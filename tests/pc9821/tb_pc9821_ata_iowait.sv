// tb_pc9821_ata_iowait - what one IDE sector read costs the CPU through the REAL I/O bus.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_IOWAIT:
// The CPU-side cost of an IDE PIO sector read, measured through the real pc9821_iobus instead of a bench-inserted gap: one 16-bit data-port word (0x0640) is ONE bus access that walks two lanes and stalls the CPU for 8 clk_sys, because EVERY lane the access FETCHES pays its own class (the rule the capture supports, docs/probes/IO.TXT pricing 0x0640 and 0x0641 as accesses in their own right, rows IDED0/IDED1, and the machine's per-access values being that capture's IDE.TXT rows IDEDAT0/IDEDAT1) and the min-profile class table puts both IDE data lanes at its FSM floor (IO_MIN_HOLD = 4), so a 512-byte sector's data phase is 256 x 9 = 2304 clk_sys (11.1 MB/s at 50 MHz) and 2048 of those cycles are device-wait; the task file charges the same floor, the fabric holds device_rd_wait/device_rd_hold low as pc9821_system's decode does for every ATA port, so the measured cost is the class and nothing else, and the 256 words are byte-exact against a synthetic disk image with the CPU's own view of the port.

// This bench exists because the tree's two throughput benches (ata_datapath,
// ata_readahead) model the data port with a bench-inserted 28-cycle gap, i.e. the
// SUPERSEDED class 30; the table was later re-anchored to the machine's
// measured 8 and then dropped every non-floor class to 4, so both of those
// benches were 5x pessimistic about the tree they test (risk 3).
// A bench that inserts its own gap cannot notice that: this one takes the number
// from pc9821_iobus itself, so a re-slowed class, an added S_DEVWAIT or a per-word
// bubble on the ATA's data port changes the measured figure and fails.
//
// The references for the machine's own per-access figures are the Xe10 captures, and
// they are per BYTE: the ideprobe's timing loop is `in al,dx` (ideprobe.s `tmL_loop`,
// tools/hwprobe/ideprobe/ideprobe.s), and it times a byte read of the data port at
// 170 ns (8.48 clk_sys at 50 MHz) and of the task file at 297 ns (14.9 clk_sys) -
// docs/probes/IDE.TXT rows IDEDAT0/IDEDAT1 and ATASTAT, whose ratio the probe itself
// prints as 584/2065 x 30 clk at the 0x5F = 600 ns anchor (and the measured
// class ladder). One SINGLE-LANE access here is 5 clk_sys = 100 ns, so the model
// is faster than the machine lane for lane. What the machine charges for a 16-BIT word
// is NOT captured - the ioprobe prices one port at a time - so the word's figure is the
// sum of its two lanes' classes and nothing more, which is
// what this bench pins.

module tb_pc9821_ata_iowait;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ---- the I/O bus's CPU port (z486's external request) ----
  reg  [31:0] cpu_addr = 0, cpu_din = 0;
  reg  [3:0]  cpu_be = 0;
  reg         cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  reg  [7:0]  debug_status = 8'hA5;
  reg         cal_cdat = 0;
  wire [6:0]  cfg_ram_mib = 7'd0;
  wire        cfg_seed_en = 1'b0;
  reg         triple_fault_reset = 1'b0;
  reg  [3:0]  bios_set = 4'd0;    // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)

  // ---- the device fabric: the iobus's byte transaction, with the ATA behind it ----
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  wire  [7:0] device_io_dout;
  reg         device_rd_wait = 1'b0;   // pc9821_system: gdc_cs || opna_rd_wait, never the ATA
  reg         device_rd_hold = 1'b0;   // pc9821_system: cg_port_rd && cg_rd_hold, never the ATA

  // ---- iobus outputs this bench does not exercise (named because the DUT is (.*)) ----
  wire [3:0]  top_bank;
  wire        sound_extend;
  wire        ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0]  win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire        sys16m_en;
  wire        a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0]  post_code;
  wire        post_write;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0]  dbg_gate;
  wire [7:0]  dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd, dbg_last_io_wr;
  wire        dbg_last_io_stb;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  wire [1:0]  ems_state;
  reg         egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  wire        top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  // ==== DUT ====
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

  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) bus (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // The ATA's chip select is the shipped decode: P5 made the ONE pc9821_device_select
  // instance live inside pc9821_iobus, so `.*` above binds these to it (the same module and
  // the same decode pc9821_system routes with - this bench no longer instantiates its own).
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs, opna_cs,
       pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs, ata_cs;

  wire [7:0] ata_io_dout;
  reg  [31:0] ata_capacity = 32'd100000;
  wire        mounted = 1'b1, readonly = 1'b0;
  wire        ata_block_read, ata_block_write;
  wire [31:0] ata_block_lba;
  reg         ata_block_done = 0, ata_block_error = 0;
  reg         ata_buf_we = 0;
  reg  [7:0]  ata_buf_addr = 0;
  reg  [15:0] ata_buf_data = 0;
  wire [7:0]  ata_buf_rd_addr;
  wire [15:0] ata_buf_rd_data;
  wire        ata_irq;
  wire [7:0]  ata_dbg_state;
  wire [31:0] ata_dbg_cmd;

  // pc9821_system's device read mux, reduced to the one device this bench builds.
  assign device_io_dout = ata_cs ? ata_io_dout : 8'hC3;

  pc9821_ata ata (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(!reset),
      .io_rd(device_io_rd && ata_cs), .io_wr(device_io_wr && ata_cs),
      .io_addr(device_io_addr), .io_din(device_io_din), .io_dout(ata_io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(ata_capacity),
      .block_read(ata_block_read), .block_write(ata_block_write),
      .block_lba(ata_block_lba),
      .block_done(ata_block_done), .block_error(ata_block_error),
      .block_buf_we(ata_buf_we), .block_buf_addr(ata_buf_addr),
      .block_buf_data(ata_buf_data),
      .block_rd_addr(ata_buf_rd_addr), .block_rd_data(ata_buf_rd_data),
      .irq(ata_irq), .dbg_state(ata_dbg_state), .dbg_cmd(ata_dbg_cmd)
  );

  integer errors = 0;
  integer cycle = 0;
  always @(posedge clk) cycle = cycle + 1;

  // ==== STIMULUS ====
  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The sector map both ATA throughput benches use: byte n of sector L is L[7:0] XOR n,
  // so word i is {L ^ (2i+1), L ^ (2i)}. A wrong LBA, a stale buffer or an off-by-one
  // word index is a data mismatch, not a silent pass.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  // ---- the block adapter, HPS-shaped: latch a request in idle, wait SD_LAT cycles
  // (the ARM reading the image and the framework's per-block handshake), then stream
  // the 256 words one per cycle and pulse completion, exactly as pc9821_block_io does.
  localparam integer SD_LAT = 4600;   // the measured upward bound for one block
  reg        ad_active = 0;
  reg [31:0] ad_lba = 0;
  integer    ad_wait = 0;
  integer    ad_index = 0;
  integer    ad_reqs = 0;

  always @(negedge clk) begin
    ata_block_done = 0;
    ata_buf_we = 0;
    if (!ad_active) begin
      if (ata_block_read) begin
        ad_active = 1;
        ad_lba = ata_block_lba;
        ad_wait = SD_LAT;
        ad_index = 0;
        ad_reqs = ad_reqs + 1;
      end
    end else if (ad_wait != 0) begin
      ad_wait = ad_wait - 1;
    end else begin
      ata_buf_we = 1;
      ata_buf_addr = ad_index[7:0];
      ata_buf_data = sector_word_for(ad_lba, ad_index[7:0]);
      if (ad_index == 255) begin
        ad_active = 0;
        ata_block_done = 1;
      end else ad_index = ad_index + 1;
    end
  end

  integer irq_count = 0;
  reg irq_prev = 0;
  always @(posedge clk) begin
    irq_prev <= ata_irq;
    if (ata_irq && !irq_prev) irq_count = irq_count + 1;
  end

  // ---- one CPU access, the idiom the iobus benches use: cpu_addr carries the port's
  // BASE (bits 15:2, low two clear) and the LANE rides in cpu_be (pc9821_iobus places the
  // byte at read_data[{lane,3'b000}] and takes the write byte from the same lane), so a
  // single-byte access to an ODD lane carries its byte at that lane's position.
  // `waited` is the delivered count: the negedge steps until cpu_ready, which is the class
  // value plus one per lane the access walks (tb_pc9821_io_wait's convention); `stall` is
  // one less, the cycles spent waiting for the response.
  task automatic io_access(input [15:0] port, input [3:0] be, input wr, input [31:0] din,
                           output [31:0] dout, output integer waited, output integer stall);
    begin
      @(negedge clk);
      cpu_addr = {16'd0, port[15:2], 2'b00};
      cpu_be = be;
      cpu_write = wr;
      cpu_din = din;
      cpu_valid = 1'b1;
      waited = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        waited = waited + 1;
        if (waited > 5000) begin
          fail("an I/O access never became ready");
          return;
        end
      end
      stall = waited - 1;
      dout = cpu_dout;
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be = 4'b0;
      while (bus.state != 0) @(negedge clk);
    end
  endtask

  task automatic write_byte(input [15:0] port, input [7:0] data);
    reg [31:0] wdata, ignored;
    integer w, s;
    begin
      wdata = 32'd0;
      wdata[{port[1:0], 3'b000} +: 8] = data;
      io_access(port, 4'b0001 << port[1:0], 1'b1, wdata, ignored, w, s);
    end
  endtask

  task automatic read_byte(input [15:0] port, output [7:0] data);
    reg [31:0] got;
    integer w, s;
    begin
      io_access(port, 4'b0001 << port[1:0], 1'b0, 32'd0, got, w, s);
      data = got[{port[1:0], 3'b000} +: 8];
    end
  endtask

  // One 16-bit data word read: a SINGLE access with both lanes enabled, which is what the
  // ROM's `rep insw` issues. Returns the word and its delivered/stall counts.
  task automatic read_pio_word(output [15:0] data, output integer waited, output integer stall);
    reg [31:0] got;
    begin
      io_access(16'h0640, 4'b0011, 1'b0, 32'd0, got, waited, stall);
      data = got[15:0];
    end
  endtask

  reg [31:0] tf_dout = 32'd0;
  integer word_waited = 0, word_stall = 0;
  integer sector_waited = 0, sector_stall = 0;
  integer tf_waited = 0, tf_stall = 0, tf_max_waited = 0, tf_max_stall = 0;
  integer drq_cycles = 0;
  reg [7:0] status = 0;
  reg [15:0] word_value = 0;
  integer i, bad_words = 0, t_cmd, t_drq, t_end;
  integer elapsed = 0, mbps_x100 = 0;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // ---- 1. the interface's own registers: the bank select and the task file ----
    // 0x0432 bit 0 CLEAR connects the hard disk (pc9821_ata's bank_has_interface: bank 0);
    // at bank 1 the task file floats and every access would be measured on the float path.
    write_byte(16'h0432, 8'h00);
    read_byte(16'h0432, status);
    if (status !== 8'h00) fail("the bank select did not read back");

    // The task file is the same class as the data port: one access, one floor.
    io_access(16'h0644, 4'b0001, 1'b1, 32'd1, tf_dout, tf_waited, tf_stall);
    tf_max_waited = tf_waited;
    tf_max_stall = tf_stall;
    read_byte(16'h064E, status);
    if (status !== 8'h50) fail("the interface did not read READY|DSC at idle");

    // ---- 2. one READ SECTORS, one sector, LBA28 ----
    write_byte(16'h0646, 8'h00);          // LBA 0x001100, sector number low
    write_byte(16'h0648, 8'h11);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);          // drive 1, LBA28
    t_cmd = cycle;
    write_byte(16'h064E, 8'h20);          // READ SECTORS

    // The command is accepted in BSY and the block request goes out exactly once.
    if (ad_reqs != 1) fail("the command did not reach the block adapter exactly once");
    read_byte(16'h074C, status);
    if (status !== 8'h80) fail("the command did not enter BSY");

    // The IRQ wait the ROM pays: poll the alternate status until DRQ. 0x074C does NOT
    // acknowledge the interrupt, so the IRQ edge count stays honest across the poll.
    drq_cycles = 0;
    read_byte(16'h074C, status);
    while (!status[3] && drq_cycles < 20000) begin
      @(negedge clk);
      drq_cycles = drq_cycles + 1;
      read_byte(16'h074C, status);
    end
    t_drq = cycle;
    if (!status[3]) fail("the sector never presented DRQ");

    // ---- 3. the data phase: 256 16-bit word reads, byte-exact ----
    for (i = 0; i < 256; i = i + 1) begin
      read_pio_word(word_value, word_waited, word_stall);
      if (i == 0) begin
        // The first word's counts are the per-word contract; every later word must match.
        // 9 delivered = the FSM's own cycle + the two lanes' classes (IO_MIN_HOLD 4 each,
        // audit-iobus F5's per-lane sum); 8 of those 9 are the CPU's device-wait.
        if (word_waited != 9)
          fail("a 16-bit data-port word delivered in a different number of cycles than 9");
        if (word_stall != 8)
          fail("a 16-bit data-port word stalled the CPU for a different number of cycles than 8");
      end
      if (word_waited != 9 || word_stall != 8)
        fail("a later data-port word's cost differs from the first");
      sector_waited = sector_waited + word_waited;
      sector_stall = sector_stall + word_stall;
      if (word_value !== sector_word_for(32'h001100, i[7:0])) begin
        if (bad_words < 4)
          $display("MISMATCH word=%0d got=%04x want=%04x", i, word_value,
                   sector_word_for(32'h001100, i[7:0]));
        bad_words = bad_words + 1;
      end
    end
    t_end = cycle;

    // ---- 4. the contract after the sector ----
    read_byte(16'h074C, status);
    if (status !== 8'h50) fail("the sector did not complete READY|DSC");
    if (ata.xfer_state !== 3'd0) fail("the READ did not return to X_IDLE");
    if (ad_reqs != 1) fail("a second block request appeared for a one-sector read");
    if (irq_count != 1) fail("exactly one IRQ edge was expected for the sector");
    if (bad_words != 0) fail("the sector's data was not byte-exact");

    // ==== CHECKS ====
    // 5. the CPU-side cost, asserted
    // 9 cycles delivered per word (F5's sum of the two lanes' classes at the FSM floor:
    // 4 + 4 plus the FSM's own cycle), 8 of them device-wait: 2304 and 2048 clk_sys for
    // the 512-byte data phase. The machine's own data-port per-BYTE access is 170 ns
    // (8.48 clk at 50 MHz) per the ideprobe, so the model is faster lane for lane; the
    // machine's 16-bit word cost is uncaptured, so the word is the sum and no more.
    elapsed = t_end - t_cmd;
    mbps_x100 = (512 * 50 * 100) / sector_waited;   // 512 bytes at 50 MHz over the data phase
    $display("PIOCOST word: delivered=%0d stall=%0d | sector: words=%0d delivered=%0d stall=%0d",
             word_waited, word_stall, 256, sector_waited, sector_stall);
    $display("PIOCOST taskfile: delivered=%0d stall=%0d (0x0644 write)", tf_max_waited, tf_max_stall);
    $display("PIOCOST command: DRQ after %0d cycles (%0d SD_LAT), sector end-to-end %0d cycles",
             t_drq - t_cmd, SD_LAT, elapsed);
    $display("PIOCOST data phase: %0d clk_sys = %0.1f us at 50 MHz, %0.2f MB/s",
             sector_waited, sector_waited * 0.02, mbps_x100 / 100.0);
    if (sector_waited != 256 * 9) begin
      $display("FAIL the data phase delivered %0d cycles for 256 words, not 2304",
               sector_waited);
      errors = errors + 1;
    end
    if (sector_stall != 256 * 8) begin
      $display("FAIL the data phase stalled the CPU for %0d cycles, not 2048",
               sector_stall);
      errors = errors + 1;
    end
    // The task file rides the same floor as the data port: a named class arm cannot be
    // re-slowed without failing here.
    if (tf_max_waited != 5 || tf_max_stall != 4) begin
      $display("FAIL a task-file access cost delivered=%0d stall=%0d, not 5/4",
               tf_max_waited, tf_max_stall);
      errors = errors + 1;
    end
    // The fetch is exposed exactly once on a one-sector command: the DRQ poll exits on
    // the completion, so the command-to-DRQ cycle count is SD_LAT plus the FSM's own
    // presentation latency (the poll's own accesses, a handful of cycles).
    if ((t_drq - t_cmd) < SD_LAT) begin
      $display("FAIL the sector presented DRQ in %0d cycles, before its own fetch (%0d)",
               t_drq - t_cmd, SD_LAT);
      errors = errors + 1;
    end
    // ... and not much after it either: the fetch, its 256-word stream and the FSM's own
    // presentation are all the command-to-DRQ latency may contain. A second block request,
    // a per-sector bubble or a serialized round trip would push past this bound.
    if ((t_drq - t_cmd) > SD_LAT + 512) begin
      $display("FAIL the command-to-DRQ latency is %0d cycles, over fetch %0d + 512: a bubble or a second fetch",
               t_drq - t_cmd, SD_LAT);
      errors = errors + 1;
    end
    // `elapsed` is the HARNESS's wall clock for the command, so it carries this bench's own
    // idle cycles between accesses (one negedge plus the bus's return to idle per access,
    // ~5 cycles x ~640 accesses); the CHARGED numbers above are the contract, and this one
    // is printed for orientation only. The machine pays those cycles as the guest's next
    // instruction, which the harness does not model.

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_IOWAIT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_IOWAIT: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_ATA_IOWAIT: TIMEOUT");
  end

endmodule
