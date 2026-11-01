`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The watchdog message names the most recent I/O access. pc9821_iobus latches the port, the byte and the direction where each access lands - a read in S_BYTE, a device read one cycle later in S_DEVWAIT, a write in S_BYTE - and the message renders that latch as IO/DR/IV, so a guest freeze loop that polls one port can be read straight out of a serial capture rather than inferred.
//
// WHY IT EXISTS. Touhou 5 freezes at startup with interrupts off and the FM silent, and the
// freeze loop polls some I/O port. The message carried CS:EIP and the PIC and keyboard state but
// not that port, so the poll was invisible in the capture. This bench pins the whole hop: a real
// bus access -> the latch -> the message's IO/DR/IV bytes.
//
// ==== DUT ====
// pc9821_iobus, with its dbg_last_io_* outputs wired to pc9821_watchdog_msg's IO/DR/IV inputs.
//
// ==== CHECKS ====
// CHK-1 an I/O READ of a system port sets addr/data/rd and clears wr.
// CHK-2 an I/O WRITE sets addr/data/wr and clears rd, and the write really landed (sound_extend moves).
// CHK-3 a DEVICE read that asks for the extra cycle (S_DEVWAIT) still latches the port and byte.
// CHK-4 the message renders the last WRITE's access as IO/DR/IV on the L line.
// CHK-5 the message renders the last READ's access, with DR=1.
//
// ==== VERDICT ====
// PASS when every check holds; FAIL with the measured values otherwise.

module tb_pc9821_io_trace;
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
  wire [1:0] ems_state;
  wire sound_extend;
  wire ide_rom_enable, bios_ram_gate;
  wire beep_mute, top_shadow_en;
  wire [7:0] win0_sel;
  wire sys16m_en;
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
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0] dbg_gate;
  wire [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire [7:0]  dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  reg        cal_cdat = 0;
  reg        triple_fault_reset = 1'b0;
  // OSD BIOS set: 0 = PC-9821Xe10 (the default strap), 1 = PC-9821Xe.
  reg [3:0]  bios_set = 4'd0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;

  integer errors = 0;
  integer i;
  reg [15:0] msg_idx = 0;
  reg        msg_snap = 0;
  wire [7:0] msg_ch;
  reg [151:0] io_rendered;

  // The 0x9A0 query state input (pc9821_iobus): driven at 0 here - only
  // tb_pc9821_readback_sysports exercises the query protocol.
  reg [10:0] gdc_ff2_state = 11'd0;
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),
    .clk(clk), .reset(reset), .triple_fault_reset(triple_fault_reset),
    .bios_set(bios_set),
    .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
    .cpu_valid(cpu_valid), .cpu_write(cpu_write),
    .cpu_dout(cpu_dout), .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
    .debug_status(debug_status), .cal_cdat(cal_cdat),
    .device_io_wr(device_io_wr), .device_io_rd(device_io_rd),
    .device_io_addr(device_io_addr), .device_io_din(device_io_din),
    .device_io_dout(device_io_dout), .device_rd_wait(device_rd_wait),
    .top_bank(top_bank), .ems_state(ems_state), .sound_extend(sound_extend),
    .win0_sel(win0_sel), .ide_rom_enable(ide_rom_enable),
    .sys16m_en(sys16m_en), .beep_mute(beep_mute), .top_shadow_en(top_shadow_en),
    .bios_ram_gate(bios_ram_gate), .a20_enable(a20_enable),
    .cpu_reset_req(cpu_reset_req),
    .unmapped_writes(unmapped_writes), .unmapped_reads(unmapped_reads),
    .last_unmapped_port(last_unmapped_port),
    .post_code(post_code), .post_write(post_write),
    .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
    .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask), .egc_bg(egc_bg),
    .egc_sft(egc_sft), .egc_leng(egc_leng), .egc_shift_we(egc_shift_we),
    .dbg_gate(dbg_gate), .dbg_itf_stage(dbg_itf_stage),
    .dbg_artic_hi(dbg_artic_hi),
    .dbg_last_io_addr(dbg_last_io_addr), .dbg_last_io_data(dbg_last_io_data),
    .dbg_last_io_rd(dbg_last_io_rd), .dbg_last_io_wr(dbg_last_io_wr),
    .cache_flush_req(cache_flush_req), .cache_flush_busy(cache_flush_busy), .cache_flush_done(cache_flush_done)
  );

  // The message, fed the iobus's own latch: the pair whose agreement is the point.
  pc9821_watchdog_msg u_msg (
    .clk(clk), .snap(msg_snap),
    .idx(msg_idx), .cpu_cs(16'h1234), .cpu_eip(32'h0), .io_debug_status(8'h0),
    .triple_fault_reset(1'b0), .hdd_mounted(1'b0), .hdd_capacity(32'h0),
    .gdc_disp(1'b0), .vid_frame_cnt(8'h0), .hdd_req_cnt(8'h0), .hdd_err_cnt(8'h0),
    .hdd_busy(1'b0), .vid_lit_seen(1'b0), .vid_lit_cnt(8'h0),
    .ata_dbg_state(8'h0), .ata_dbg_cmd(32'h0), .io_dbg_gate(4'h0), .mounted_at_run(1'b0),
    .gdc_dbg_sad(16'h0), .gdc_dbg_pitch(8'h0), .gdc_dbg_col40(1'b0), .gdc_dbg_disp(1'b0),
    .kbd_dbg_events(8'h0), .kbd_dbg_delivered(8'h0), .kbd_dbg_rd_data(8'h0),
    .kbd_dbg_wr_ctrl(8'h0), .kbd_dbg_rts(1'b0), .kbd_dbg_rx_en(1'b0), .kbd_irq(1'b0),
    .kbd_dbg_last_del(8'h0), .kbd_dbg_ctrl0(8'h0), .kbd_dbg_ctrl1(8'h0),
    .irq_dbg_imr(8'h0), .irq_dbg_irr(8'h0), .irq_dbg_isr(8'h0),
    .inta_din(8'h0), .cpu_irq_state(8'h0), .inta_count(8'h0),
    .artic_hi(16'h0), .io_itf_stage(8'h0),
    .last_io_addr(dbg_last_io_addr), .last_io_data(dbg_last_io_data),
    .last_io_rd(dbg_last_io_rd), .last_io_wr(dbg_last_io_wr),
    .ch(msg_ch)
  );

  // The bus idiom: cpu_addr carries the BASE (the port with its low two bits cleared) and the
  // lane rides in cpu_be. Passing the port itself as the address answers a different port.
  // $fatal rather than a `disable <taskname>` guard: Verilator 5.052 drops a task's whole
  // port list when its body names itself in a disable, so a guarded call site then reads
  // "Too many arguments in call to task". A stuck access is a failure anyway, and the
  // watchdog below bounds the run.
  task automatic read_port(input [15:0] rport, input [1:0] rlane);
    integer guard;
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, rport[15:2], 2'b00};
      cpu_be    = 4'b0001 << rlane;
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      guard = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard > 50000) $fatal(1, "port %04x never became ready", rport);
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic write_port(input [15:0] wport, input [7:0] wdata, input [1:0] wlane);
    integer guard;
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, wport[15:2], 2'b00};
      cpu_be    = 4'b0001 << wlane;
      cpu_din   = {24'd0, wdata};
      cpu_write = 1'b1;
      cpu_valid = 1'b1;
      guard = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard > 50000) $fatal(1, "port %04x never became ready", wport);
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      cpu_write = 1'b0;
      cpu_din   = 32'd0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // The record's IO/DR/IV fields, indices 251..269 (since the record became one line), read
  // out one character at a time. tools/check_telemetry_contract.py requires this index to be the
  // one the formatter puts the IO field's leading space at.
  task automatic capture_io;
    integer k;
    begin
      msg_snap = 1'b1; @(posedge clk); #1; msg_snap = 1'b0;   // the record's snapshot at its accept
      io_rendered = 152'd0;
      for (k = 0; k < 19; k = k + 1) begin
        msg_idx = 16'd251 + k[15:0];
        #1;
        io_rendered = {io_rendered[143:0], msg_ch};
      end
      msg_idx = 16'd0;
    end
  endtask

  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (8) @(negedge clk);

    // CHK-1 and CHK-5: a READ of a system port. 0x0EE0 answers debug_status.
    read_port(16'h0EE0, 2'd0);
    if (cpu_dout[7:0] !== 8'hA5) begin
      $display("FAIL the read of 0x0EE0 gave 0x%02X, not debug_status 0xA5", cpu_dout[7:0]);
      errors = errors + 1;
    end
    if (dbg_last_io_addr !== 16'h0EE0 || dbg_last_io_rd !== 1'b1 ||
        dbg_last_io_wr !== 1'b0 || dbg_last_io_data !== 8'hA5) begin
      $display("FAIL CHK-1 after a read of 0x0EE0 the latch is addr=0x%04X rd=%0b wr=%0b data=0x%02X",
               dbg_last_io_addr, dbg_last_io_rd, dbg_last_io_wr, dbg_last_io_data);
      errors = errors + 1;
    end
    capture_io;
    if (io_rendered !== " IO=0EE0 DR=1 IV=A5") begin
      $display("FAIL CHK-5 the message renders the read as '%0s', expected ' IO=0EE0 DR=1 IV=A5'",
               io_rendered);
      errors = errors + 1;
    end

    // CHK-2 and CHK-4: a WRITE that really lands. 0x0A460 bit 0 is sound_extend.
    write_port(16'h0A460, 8'h01, 2'd0);
    if (sound_extend !== 1'b1) begin
      $display("FAIL the write of 0x01 to 0x0A460 did not set sound_extend");
      errors = errors + 1;
    end
    if (dbg_last_io_addr !== 16'h0A460 || dbg_last_io_rd !== 1'b0 ||
        dbg_last_io_wr !== 1'b1 || dbg_last_io_data !== 8'h01) begin
      $display("FAIL CHK-2 after a write to 0x0A460 the latch is addr=0x%04X rd=%0b wr=%0b data=0x%02X",
               dbg_last_io_addr, dbg_last_io_rd, dbg_last_io_wr, dbg_last_io_data);
      errors = errors + 1;
    end
    capture_io;
    if (io_rendered !== " IO=A460 DR=2 IV=01") begin
      $display("FAIL CHK-4 the message renders the write as '%0s', expected ' IO=A460 DR=2 IV=01'",
               io_rendered);
      errors = errors + 1;
    end

    // CHK-3: a DEVICE read that asks for the extra cycle. 0x0060 routes to the device fabric, so
    // with device_rd_wait the data only lands in S_DEVWAIT - the arm that must not be skipped.
    device_io_dout = 8'h5A;
    device_rd_wait = 1'b1;
    read_port(16'h0060, 2'd0);
    device_rd_wait = 1'b0;
    if (cpu_dout[7:0] !== 8'h5A) begin
      $display("FAIL the device read of 0x0060 gave 0x%02X, not device_io_dout 0x5A", cpu_dout[7:0]);
      errors = errors + 1;
    end
    if (dbg_last_io_addr !== 16'h0060 || dbg_last_io_rd !== 1'b1 ||
        dbg_last_io_wr !== 1'b0 || dbg_last_io_data !== 8'h5A) begin
      $display("FAIL CHK-3 after a device read of 0x0060 the latch is addr=0x%04X rd=%0b wr=%0b data=0x%02X",
               dbg_last_io_addr, dbg_last_io_rd, dbg_last_io_wr, dbg_last_io_data);
      errors = errors + 1;
    end

    if (errors == 0) begin
      $display("TB_PC9821_IO_TRACE: PASS");
      $display("  the latch followed a read (0x0EE0=A5), a write (0x0A460=01) and a device read");
      $display("  (0x0060=5A), and the message rendered the last write as IO=A460 DR=2 IV=01");
    end else begin
      $fatal(1, "TB_PC9821_IO_TRACE: FAIL (%0d errors)", errors);
    end
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_IO_TRACE: FAIL (timed out after 4M ns)");
  end
endmodule
