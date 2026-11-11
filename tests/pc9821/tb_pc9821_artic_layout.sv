// tb_pc9821_artic_layout - the ARTIC timestamp counter's byte layout.
//
// The four ports 0x5C..0x5F are ONE counter. The question this bench answers is
// how its bytes are arranged, and the answer decides whether a guest reading the
// upper half at 0x5E gets the counter or gets the byte it already read at 0x5D.

module tb_pc9821_artic_layout;
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
  reg        cal_cdat = 0;
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;

// ==== WHAT THIS PROVES ====
// The ARTIC timestamp ports 0x5C..0x5F are ONE 24-bit counter at 307200 Hz in which 0x5E MIRRORS 0x5D - both return cnt[15:8], as NP2kai artic_bind attaches 0x5D and 0x5E to the same handler - and 0x5F is cnt[23:16], so the value reconstructed from 0x5C/0x5D/0x5F advances by the elapsed ticks while 0x5E equals 0x5D or is one ahead, and the real-machine captures prove the mirror: six of fourteen read 0x5E EQUAL to 0x5D and seven read +1, an agreement adjacent independent bytes cannot produce.
//
// ---- the bench's own account of where each expectation comes from ----
// The port map is NP2kai's, verbatim: io/artic.c attaches 0x5D AND 0x5E to the same
// cnt[15:8] handler (artic_i5d) and 0x5F to cnt[23:16] (artic_i5f), so `in ax,0x5E` is
// cnt[23:8]. The real machine agrees: of the fourteen 0x5C..0x5F snapshots in the Xe10
// captures, six read 0x5E EQUAL to 0x5D and seven read 0x5D + 1 - an agreement two
// independent adjacent bytes would show one time in 256, not six times in fourteen. The
// old four-independent-byte layout was this tree reading that carry as evidence AGAINST a
// mirror, which is backwards: a mirror returns 0x5D or 0x5D + (ticks between the reads).
  integer errors = 0;
  integer elapsed = 0;

// ==== DUT ====
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
    .cache_flush_req(cache_flush_req), .cache_flush_busy(cache_flush_busy), .cache_flush_done(cache_flush_done)
  );

  // [source: the port idiom is tb_pc9821_io_wait.sv's, which the bus actually
  // takes - cpu_addr carries the BASE (bits 15:2 with the low two zeroed) and the
  // LANE rides in cpu_be. Passing the port as the address answers a different
  // port.]
  task automatic read_byte;
    reg [1:0] lane;
    begin
      lane = probe_port[1:0];
      @(negedge clk);
      cpu_addr  = {16'd0, probe_port[15:2], 2'b00};
      cpu_be    = 4'b0001 << lane;
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      elapsed   = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        elapsed = elapsed + 1;
        if (elapsed > 50000) begin
          $display("FAIL port %04x never became ready", probe_port);
          errors = errors + 1;
          rd_byte = 8'h00;
          disable read_byte;
        end
      end
      // The byte lands in the LANE's position of cpu_dout, which is where a real
      // CPU reads it from: an access to 0x5D puts its data in bits 15:8. Reading
      // [7:0] for every port is what made the first version of this bench report
      // 0x5D..0x5F as open bus while 0x5C passed.
      rd_lane = lane;
      rd_byte = cpu_dout[{rd_lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

// ==== CHECKS ====
  reg [7:0] b5c, b5d, b5e, b5f;
  // read_byte's port and result. Module-level, not task arguments: this is the
  // idiom tb_pc9821_io_wait.sv uses for measure_port, and Verilator rejected both
  // an output argument and an ANSI input header here.
  reg [15:0] probe_port;
  reg [7:0]  rd_byte;
  reg [1:0]  rd_lane;
  reg [31:0] v1, v2, delta, expect_ticks;
  integer wait_cycles, i;
  // 50 MHz / 307200 Hz = 162.7604 clk_sys cycles per ARTIC tick.
  localparam real CYCLES_PER_TICK = 162.76041666666666;

  task automatic read_counter(output [31:0] v);
    reg [7:0] a, b, d;
    begin
      probe_port = 16'h005C; read_byte; a = rd_byte;
      probe_port = 16'h005D; read_byte; b = rd_byte;
      probe_port = 16'h005F; read_byte; d = rd_byte;
      v = {d, b, a};   // 24-bit cnt[23:0]; 0x5E is the 0x5D mirror, checked in check 2
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // 1. 0x5C..0x5F must be DECODED, not open bus. A counter that reads 0xFF is
    //    not a counter, and every later check would compare two stub constants.
    probe_port = 16'h005C; read_byte; b5c = rd_byte;
    probe_port = 16'h005D; read_byte; b5d = rd_byte;
    probe_port = 16'h005E; read_byte; b5e = rd_byte;
    probe_port = 16'h005F; read_byte; b5f = rd_byte;
    if (b5c == 8'hFF || b5d == 8'hFF || b5e == 8'hFF || b5f == 8'hFF) begin
      $display("FAIL 0x5C..0x5F read 0xFF: the ARTIC counter is not decoded (%02x %02x %02x %02x)",
               b5c, b5d, b5e, b5f);
      errors = errors + 1;
    end

    // PRELOAD the counter so its three bytes DIFFER and check 3's window crosses a carry
    // into cnt[23:16] (after check 1, whose 0xFF test is for an
    // undecoded port and would read a live 0xFF byte as one). From reset the counter reaches only ~550
    // ticks in this bench, so cnt[23:16] - and the byte a wrong 0x5E or 0x5F decode would
    // return instead - is 0x00 everywhere it is read: a 0x5E wired to cnt[23:16], or a
    // 0x5F wired to cnt[31:24], read 0x00 = 0x5D's own 0x00 and passed checks 2 and 3.
    // 0x00C3FF00 gives 0x5C/0x5D/0x5F = 00/FF/C3 (0x5E must read FF, not C3), and
    // ~550 ticks later 0x5D has wrapped and 0x5F reads C4. Reaching the same state by
    // counting would take 2^16 ticks (10.7 M clk_sys) and still leave 0x5D near 0x5F.
    @(negedge clk);
    dut.artic_cnt = 32'h00C3_FF00;

    // 2. THE MIRROR. Read 0x5D then 0x5E back-to-back four times: 0x5E must equal 0x5D
    //    or be a few ahead (ticks land between the two reads). Two independent adjacent
    //    bytes would differ by an arbitrary amount 255 times out of 256.
    for (i = 0; i < 4; i = i + 1) begin
      probe_port = 16'h005D; read_byte; b5d = rd_byte;
      probe_port = 16'h005E; read_byte; b5e = rd_byte;
      if (((b5e - b5d) & 8'hFF) > 3) begin
        $display("FAIL 0x5E read 0x%02X while 0x5D read 0x%02X: 0x5E does not mirror 0x5D", b5e, b5d);
        errors = errors + 1;
      end
    end

    // 3. THE 24-BIT ADVANCE. Reconstruct cnt[23:0] = {0x5F, 0x5D, 0x5C} (0x5E is the
    //    0x5D mirror and carries no information), run long enough for a carry, and
    //    require the advance to be the elapsed ticks.
    read_counter(v1);
    wait_cycles = 90000;
    for (i = 0; i < wait_cycles; i = i + 1) @(posedge clk);
    read_counter(v2);

    expect_ticks = (wait_cycles + 400) / CYCLES_PER_TICK;  // +400 covers the read latency
    delta = v2 - v1;
    $display("  artic: v1=%08x v2=%08x delta=%0d expected=%0d (+-2)",
             v1, v2, delta, expect_ticks);
    if (delta > expect_ticks + 2 || delta + 2 < expect_ticks) begin
      $display("FAIL the reconstructed 24-bit counter advanced %0d over ~%0d ticks",
               delta, expect_ticks);
      $display("     0x5C/0x5D/0x5F are not three adjacent bytes of one counter.");
      errors = errors + 1;
    end
    // (The mirror check above is the assertion this bench once deleted because it reported
    //  0 of 256 when ~99.6% is expected. That failure was the RTL's, not the check's: 0x5E
    //  was an independent byte cnt[23:16], so the pair agreed one time in 256. With the
    //  correct mirror the check passes every time, so it is restored as the strongest
    //  statement of the layout.)

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ARTIC_LAYOUT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ARTIC_LAYOUT: FAIL (%0d errors)", errors);
  end

endmodule
