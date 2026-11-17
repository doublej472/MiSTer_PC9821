`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// A device's write back-pressure (device_wr_wait) holds every lane of a multi-lane write.
//
// A device's write wait holds EVERY byte lane a multi-lane I/O write presents, not only the first: with the OPNA queue one word from full, an `out dx,eax` at 0x0188 lands 0x0188 and then waits at lane 2 (0x018A, the data port) until the queue frees a word, and an `out dx,ax` at 0x0189 (first lane 0x0189, no device wait) waits at its 0x018A lane the same way, as does a single `out dx,al` at 0x018A (the first lane) against the full queue; each waited lane is strobed exactly once, after the release, with its own byte and in its place in the walk, no write reaches a full queue, and with the queue free a dword write still walks its four lanes on four consecutive clocks.
//
// pc9821_iobus's contract for device_wr_wait (the OPNA write queue's and the 86-PCM FIFO's
// back-pressure, pc9821_system `device_wr_wait = (opna_cs && opna_wr_wait) || pcm86_wr_wait`)
// is that a write the device cannot accept is presented exactly once and never dropped
// (S_IOWAIT's comment). pc9821_opna keeps a `!wrq_cnt[WRQ_BITS]` guard on wrq_push as the last
// resort, so a write presented to a full queue is LOST. The device here is a model of that
// queue with one free word: a strobe while it is full is counted as a drop, as pc9821_opna
// would drop it. The OPNA's own queue benches (tb_pc9821_opna_wrq) drive the module directly
// and never reach the iobus's lane walk.
// FAIL-FIRST: with the wait checked only in S_IOWAIT (the access's first lane), lane 2 of
// both accesses reaches the full queue and is dropped.

`default_nettype none

module tb_pc9821_iobus_wr_wait;
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
    // The GDC FF2 query state (a pc9821_iobus input);
    // tied quiet here - this bench is not about the FF2 read-back.
    wire [10:0] gdc_ff2_state = 11'd0;

  // ==== The device: an OPNA-like write queue, MODELLED ====
  // `free` words left; a write to an OPNA port takes one. While none is free the queue
  // drains one word after DRAIN cycles. device_wr_wait is the system's own term for the
  // OPNA side: the CURRENT lane's registered opna_cs and the queue being full.
  localparam integer DRAIN = 20;
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  reg  cache_flush_busy = 1'b0;   // no flush trigger is written here
  reg  cache_flush_done = 1'b0;
  integer free = 4;
  integer drain_left = 0;
  integer drops = 0;
  integer accepted = 0;
  reg  [15:0] acc_port [0:7];
  reg  [7:0]  acc_data [0:7];
  time        acc_time [0:7];
  time        release_time = 0;
  wire device_wr_wait;
  integer     lanes = 0;
  time        lane_time [0:7];
  reg  [15:0] lane_port [0:7];

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

  // ==== The device model's logic (after the DUT: it reads the DUT's opna_cs) ====
  assign device_wr_wait = opna_cs && (free == 0);
  always @(posedge clk) begin
    // The drain runs whatever the bus does: a write presented to the full queue is dropped
    // (pc9821_opna's wrq_push !full guard), and the queue still frees its word on time.
    if (free == 0) begin
      if (drain_left == 0) begin
        free = 1;
        release_time = $time;
      end else drain_left = drain_left - 1;
    end
    if (device_io_wr && opna_cs) begin
      // A strobe on the drain's own edge was presented while the queue was still full.
      if (free == 0 || release_time == $time) begin
        drops = drops + 1;
      end else begin
        if (accepted < 8) begin
          acc_port[accepted] = device_io_addr;
          acc_data[accepted] = device_io_din;
          acc_time[accepted] = $time;
        end
        accepted = accepted + 1;
        free = free - 1;
        if (free == 0) drain_left = DRAIN;
      end
    end
  end

  // Every walked write lane, any port, with its time (the back-to-back check): the
  // last-I/O latch loads once per lane at S_BYTE.
  always @(posedge clk) begin
    if (dbg_last_io_stb && dbg_last_io_wr) begin
      if (lanes < 8) begin
        lane_time[lanes] = $time;
        lane_port[lanes] = dbg_last_io_addr;
      end
      lanes = lanes + 1;
    end
  end

  // ==== CHECKS ====
  integer errors = 0;

  task automatic write_lanes(input [15:0] dword_port, input [3:0] be, input [31:0] data);
    begin
      @(negedge clk);
      cpu_addr = {16'd0, dword_port[15:2], 2'b00};
      cpu_be = be;
      cpu_din = data;
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic expect_acc(input [8*64-1:0] tag, input integer i, input [15:0] port,
                            input [7:0] data);
    begin
      if (acc_port[i] != port || acc_data[i] != data) begin
        $display("FAIL %0s: write %0d landed %04h=%02h, want %04h=%02h", tag, i,
                 acc_port[i], acc_data[i], port, data);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_IOBUS_WR_WAIT: TIMEOUT");
  end

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // ==== 1. `out dx,eax` at 0x0188, one word free ====
    // Lane 0 (0x0188, the address latch) takes the last word; lane 2 (0x018A, the data)
    // must wait for the drain, then land once with its byte.
    free = 1; accepted = 0; drops = 0; lanes = 0;
    write_lanes(16'h0188, 4'b1111, 32'h44_33_22_11);
    // The held lane keeps its place in the walk: 0x0188, 0x0189, 0x018A, 0x018B in order.
    if (lanes != 4 || lane_port[0] != 16'h0188 || lane_port[1] != 16'h0189 ||
        lane_port[2] != 16'h018A || lane_port[3] != 16'h018B) begin
      $display("FAIL out dx,eax at 0x0188: %0d lane(s) walked %04h %04h %04h %04h, want 0188 0189 018A 018B",
               lanes, lane_port[0], lane_port[1], lane_port[2], lane_port[3]);
      errors = errors + 1;
    end
    if (drops != 0) begin
      $display("FAIL out dx,eax at 0x0188: %0d write(s) presented to the full queue", drops);
      errors = errors + 1;
    end
    if (accepted != 2) begin
      $display("FAIL out dx,eax at 0x0188: %0d OPNA write(s) accepted, want 2", accepted);
      errors = errors + 1;
    end else begin
      expect_acc("out dx,eax at 0x0188", 0, 16'h0188, 8'h11);
      expect_acc("out dx,eax at 0x0188", 1, 16'h018A, 8'h33);
      if (acc_time[1] <= release_time || release_time <= acc_time[0]) begin
        $display("FAIL out dx,eax at 0x0188: the 0x018A write at %0t did not wait for the release at %0t",
                 acc_time[1], release_time);
        errors = errors + 1;
      end
    end

    // ==== 2. `out dx,ax` at 0x0189, the queue already full ====
    // The first lane (0x0189) is no OPNA port, so S_IOWAIT has no wait to see; lane 2
    // (0x018A) must still wait for the drain.
    free = 0; drain_left = DRAIN; accepted = 0; drops = 0;
    write_lanes(16'h0188, 4'b0110, 32'h00_5A_A5_00);
    if (drops != 0) begin
      $display("FAIL out dx,ax at 0x0189: %0d write(s) presented to the full queue", drops);
      errors = errors + 1;
    end
    if (accepted != 1) begin
      $display("FAIL out dx,ax at 0x0189: %0d OPNA write(s) accepted, want 1", accepted);
      errors = errors + 1;
    end else expect_acc("out dx,ax at 0x0189", 0, 16'h018A, 8'h5A);

    // ==== 3. `out dx,al` at 0x018A, the queue full: a FIRST lane waits as well ====
    // The wait is honoured at the lane's S_BYTE for every lane, the first included.
    free = 0; drain_left = DRAIN; accepted = 0; drops = 0;
    write_lanes(16'h0188, 4'b0100, 32'h00_77_00_00);
    if (drops != 0 || accepted != 1) begin
      $display("FAIL out dx,al at 0x018A: %0d accepted, %0d presented to the full queue, want 1 and 0",
               accepted, drops);
      errors = errors + 1;
    end else expect_acc("out dx,al at 0x018A", 0, 16'h018A, 8'h77);

    // ==== 4. The queue free: no wait, the lanes walk back to back ====
    free = 4; accepted = 0; drops = 0; lanes = 0;
    write_lanes(16'h0188, 4'b1111, 32'hD4_C3_B2_A1);
    if (accepted != 2 || drops != 0) begin
      $display("FAIL out dx,eax at 0x0188 (queue free): %0d accepted, %0d dropped, want 2 and 0",
               accepted, drops);
      errors = errors + 1;
    end
    if (lanes != 4) begin
      $display("FAIL out dx,eax at 0x0188 (queue free): %0d lane(s) walked, want 4", lanes);
      errors = errors + 1;
    end else begin : walk
      integer k;
      for (k = 1; k < 4; k = k + 1)
        if (lane_time[k] - lane_time[k-1] != 10) begin
          $display("FAIL out dx,eax at 0x0188 (queue free): lane %0d is %0t after lane %0d, want one clock",
                   k, lane_time[k] - lane_time[k-1], k - 1);
          errors = errors + 1;
        end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IOBUS_WR_WAIT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IOBUS_WR_WAIT: FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire
