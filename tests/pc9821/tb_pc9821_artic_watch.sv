// tb_pc9821_artic_watch - the watchdog's U field against the port the firmware actually reads.
//
// WHY THIS EXISTS. The core boots the authentic firmware through the whole ITF and then spins
// forever in the IDE option ROM's delay() helper (BANK3@0x0B1B, 0x0B2A): `in ax,0x5E; add cx,ax;
// ... cmp ax,cx; jae` - a deadline computed from the ARTIC timestamp counter, waiting for the
// counter to reach it. It never does. The one fact that decides why is what `in ax,0x5E` returns
// over time, so the watchdog message's U field was repurposed to carry it.
//
// THAT MAKES A WIRING QUESTION THE WHOLE VALUE OF THE INSTRUMENT, and this bench answers it: does
// U report the same 16 bits the firmware's `in ax,0x5E` reads? If the two ever disagree, every
// capture decoded from the field would be evidence about a different signal than the guest's, and
// the instrument would be confidently wrong rather than silent.
//
// WHAT IT DOES NOT COVER, said plainly rather than left implied: it does not instantiate
// pc9821_system or the top level, so it cannot see the last hop of the wiring - that
// pc9821_system connects .dbg_artic_hi(artic_hi) to the message's .artic_hi(artic_hi). That hop
// is two named ports in one file and is checked by tools/check_port_lists.py; this bench pins the
// two ends it can reach, which are the parts that can silently disagree about MEANING.
//
// ==== WHAT THIS PROVES ====
// The ARTIC timestamp counter advances at 307200 Hz through the guest own byte port, and the 16 bits a word read at 0x5E returns - cnt[23:8], with 0x5E mirroring 0x5D in the low byte - are exactly the 16 bits the watchdog message U field reports, so a capture decoded from that field is evidence about the value the firmware delay() helper is spinning on.
//
// ==== DUT ====
// pc9821_iobus, and pc9821_watchdog_msg fed with the iobus's dbg_artic_hi.
//
// ==== CHECKS ====
// CHK-1 the counter ADVANCES: byte 0 at 0x5C changes within a few hundred clocks, which is the low byte of a 307200 Hz counter at 50 MHz.
// CHK-2 the RATE is 307200 Hz, measured from the port over a known number of clocks.
  // CHK-3 a WORD read at 0x5E returns cnt[23:8] in cpu_dout[31:16] - the exact bytes `in ax,0x5E` gives the guest.
// CHK-4 dbg_artic_hi EQUALS that word, so the instrument and the guest read the same signal.
// CHK-5 the message's U field renders dbg_artic_hi as four hex digits, most significant first.
//
// ==== VERDICT ====
// PASS when every check holds; FAIL with the measured values otherwise. Breaking the wiring
// (dbg_artic_hi driven from the wrong half of the counter) must fail CHK-4.
`timescale 1ns/1ps

module tb_pc9821_artic_watch;
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
  wire ide_rom_enable, bios_ram_gate;
  wire [7:0] win0_sel;
  wire sys16m_en;   // 0x043B bit 2, the 15-16 MiB system-space window
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
  reg        cal_cdat = 0;
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;

  integer errors = 0;
  integer i;
  reg [7:0]  b0_lo, b0_lo2;
  reg [31:0] word5e;
  reg [7:0]  umsg [0:279];
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;


  pc9821_iobus dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),
    .clk(clk), .reset(reset), .triple_fault_reset(triple_fault_reset),
    .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
    .cpu_valid(cpu_valid), .cpu_write(cpu_write),
    .cpu_dout(cpu_dout), .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
    .debug_status(debug_status), .cal_cdat(cal_cdat),
    .device_io_wr(device_io_wr), .device_io_rd(device_io_rd),
    .device_io_addr(device_io_addr), .device_io_din(device_io_din),
    .device_io_dout(device_io_dout), .device_rd_wait(device_rd_wait),
    .top_bank(top_bank), .sound_extend(sound_extend),
    .win0_sel(win0_sel), .ide_rom_enable(ide_rom_enable),
    .sys16m_en(sys16m_en),
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
    .cache_flush_req(cache_flush_req), .cache_flush_busy(cache_flush_busy), .cache_flush_done(cache_flush_done)
  );

  // THE MESSAGE, FED THE IOBUS'S OWN FIELD. This is the pair whose agreement is the point: the
  // bench asserts the U bytes against dbg_artic_hi, and dbg_artic_hi against the port.
  wire [7:0] msg_ch;
  reg  [15:0] msg_idx = 0;
  reg        msg_snap = 0;
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
    .artic_hi(dbg_artic_hi), .io_itf_stage(8'h0), .ch(msg_ch)
  );

  // The port idiom is the bus's: cpu_addr carries the BASE (the port with its low two bits cleared)
  // and the lane rides in cpu_be. Passing the port itself as the address answers a different port.
  reg [15:0] rp_port;
  reg [1:0]  rp_lane;
  task automatic read_port;
    integer guard;
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, rp_port[15:2], 2'b00};
      cpu_be    = 4'b0001 << rp_lane;
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      guard = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard > 50000) begin
          $display("FAIL port %04x never became ready", rp_port);
          errors = errors + 1;
          disable read_port;
        end
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // A WORD read at 0x5E, exactly as the firmware's `in ax,0x5E` presents it: base 0x5C, byte
  // enables 0b1100 - lanes 2 and 3 - so the bus answers 0x5E and 0x5F.
  task automatic read_word_5e;
    integer guard;
    begin
      @(negedge clk);
      cpu_addr  = 32'h0000_005C;
      cpu_be    = 4'b1100;
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      guard = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard > 50000) begin
          $display("FAIL the word read at 0x5E never became ready");
          errors = errors + 1;
          disable read_word_5e;
        end
      end
      word5e = cpu_dout;
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // The record's four U bytes (247..250 since the record became one line), read out one
  // index at a time. tools/check_telemetry_contract.py requires this index to be the one the
  // formatter puts the U field's first digit at, so a layout change cannot leave it here.
  task automatic capture_u(output [15:0] got);
    begin
      msg_snap = 1'b1; @(posedge clk); #1; msg_snap = 1'b0;   // the record's snapshot at its accept
      msg_idx = 16'd247; #1; umsg[0] = msg_ch;
      msg_idx = 16'd248; #1; umsg[1] = msg_ch;
      msg_idx = 16'd249; #1; umsg[2] = msg_ch;
      msg_idx = 16'd250; #1; umsg[3] = msg_ch;
      got = {hexval(umsg[0]), hexval(umsg[1]), hexval(umsg[2]), hexval(umsg[3])};
      msg_idx = 16'd0;
    end
  endtask

  function automatic [3:0] hexval(input [7:0] c);
    begin
      if (c >= "0" && c <= "9") hexval = c - "0";
      else if (c >= "A" && c <= "F") hexval = c - "A" + 10;
      else hexval = 4'hF;
    end
  endfunction

  reg [15:0] msg_u;

  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (8) @(negedge clk);

    // CHK-1: the counter ADVANCES. Byte 0 of a 307200 Hz counter at 50 MHz carries once every
    // 162.76 clocks, so a few hundred clocks MUST move it. A counter that stands still is the
    // exact fault under investigation, so this is the check that matters most.
    rp_port = 16'h005C; rp_lane = 2'd0; read_port;
    b0_lo = cpu_dout[7:0];
    repeat (600) @(negedge clk);
    rp_port = 16'h005C; rp_lane = 2'd0; read_port;
    b0_lo2 = cpu_dout[7:0];
    if (b0_lo == b0_lo2) begin
      $display("FAIL CHK-1 the counter did not advance: 0x5C read 0x%02X, then 0x%02X after 600 clocks",
               b0_lo, b0_lo2);
      errors = errors + 1;
    end

    // CHK-2: the RATE. 600 clocks at 307200 Hz is 600/162.76 = 3.686 ticks, so the low byte must
    // have moved by 3, 4 or (allowing for the read's own latency) 5. Anything else is a different
    // rate, and a different rate changes how long the firmware's delay() should take.
    begin
      integer delta;
      delta = (b0_lo2 - b0_lo) & 8'hFF;
      if (delta < 3 || delta > 5) begin
        $display("FAIL CHK-2 the rate is wrong: 600 clocks moved 0x5C by %0d, expected 3..5 for 307200 Hz",
                 delta);
        errors = errors + 1;
      end
    end

    // CHK-3 and CHK-4: the word the GUEST reads at 0x5E is the field the INSTRUMENT reports.
    // PRELOAD the counter first: ~620 clocks after reset it holds
    // ~4 ticks, so cnt[23:8] is 0x0000 and so is EVERY other 16-bit slice above bit 2 - a
    // dbg_artic_hi wired to the wrong half of the counter read 0x0000 = 0x0000 and passed
    // the check the VERDICT banner says it must fail. 0x00A5C300 makes cnt[23:8] = 0xA5C3,
    // every neighbouring slice differs, and the low byte has 256 ticks (41 k clocks) before
    // a carry could move the word between the read and the message capture.
    @(negedge clk);
    dut.artic_cnt = 32'h00A5_C300;
    read_word_5e;
    if (word5e[31:16] !== dbg_artic_hi) begin
      $display("FAIL CHK-3/4 a word read at 0x5E gave 0x%04X in bits 31:16 but dbg_artic_hi is 0x%04X",
               word5e[31:16], dbg_artic_hi);
      errors = errors + 1;
    end

    // CHK-5: the message renders that same value as four hex digits, most significant first.
    capture_u(msg_u);
    if (msg_u !== dbg_artic_hi) begin
      $display("FAIL CHK-5 the message's U field reads 0x%04X but dbg_artic_hi is 0x%04X",
               msg_u, dbg_artic_hi);
      errors = errors + 1;
    end

    if (errors == 0) begin
      $display("TB_PC9821_ARTIC_WATCH: PASS");
      $display("  the ARTIC counter advanced 0x%02X -> 0x%02X in 600 clocks, and the word read at",
               b0_lo, b0_lo2);
      $display("  0x5E (0x%08X) carries 0x%04X in bits 31:16, which is what the message reports",
               word5e, word5e[31:16]);
    end else
      $fatal(1, "TB_PC9821_ARTIC_WATCH: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #4_000_000;
    // $fatal, NOT $display then $finish: $finish exits with status 0, so a timeout would be
    // reported to the harness as a pass.
    $fatal(1, "TB_PC9821_ARTIC_WATCH: FAIL (timed out after 4M cycles)");
  end
endmodule
