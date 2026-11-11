`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_THROTTLE:
// The OSD CPU Speed throttle slows the CPU and only the CPU, through the real CPU, bridge, memory and I/O path: at 8 MHz and at 1 MHz a 4096-iteration DEC/JNZ takes the clock ratio times its full-speed time (within 3%), a 12288-dword REP STOSD takes at least one throttled CPU edge per dword (the throttle acts inside the REP, which an instruction-boundary throttle cannot), every timed interval is its CPU-edge count at the selected rate, and the guest's architectural results - a data-dependent checksum over the region re-read after a whole-L1 flush, and the region itself - are identical at every setting, with a CPU reset, an I/O read, burst line fills, the 0x043F flush and an INTA all crossing the gated-clock bridge on the way; and at every setting an IRQ0 the 8259 raises a few platform cycles after it acknowledges IRQ2 (its INT low for less than one throttled CPU clock) is still taken once the IRQ2 handler's IRET sets IF (a 486 samples INTR as a level, so INTR need not be seen low between two requests).

// The guest is tests/pc9821/throttle_guest.s (its POST codes are listed there). Each run is a
// platform reset with a new cpu_speed_sel; RAM survives it, as on an OSD reset. The expected
// ratios come from the platform clock and cpu_throttle's own rate table (the RTL's rate_khz(),
// which tools/check_osd_contract.py ties to the OSD labels), not from a measurement of this
// RTL; the architectural results are compared against the full-speed run of the same guest.

module tb_pc9821_throttle;
  localparam integer SYS_HZ  = 50_000_000;
  localparam integer SYS_KHZ = SYS_HZ / 1000;
  localparam integer N_DWORDS = 12288;
  localparam integer N_LOOP   = 4096;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  integer tb_cycles = 0;
  always @(posedge clk_sys) tb_cycles = tb_cycles + 1;

  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait;
  wire [31:0] ext_mem0_addr, ext_mem0_din, ext_mem0_dout;
  wire [3:0] ext_mem0_be;
  wire [7:0] ext_mem0_burstcount;
  wire ext_mem0_valid, ext_mem0_write, ext_mem0_ready, ext_mem0_resp_valid;
  wire [7:0] debug_post_code;
  wire debug_post_write, debug_bios_loaded;
  wire [15:0] cpu_cs;
  wire [31:0] cpu_eip, cpu_cs_base;
  wire [7:0] video_r, video_g, video_b;
  wire video_ce, video_blank_n, video_hsync, video_vsync;
  reg [2:0] ram_size = 3'd5, ram_size_max = 3'd5;
  reg [3:0] cpu_speed_sel = 4'd0;
  reg [15:0] pack_words [0:17'h187ff];

  // ==== DUT ====
  pc9821_system #(
      .SYS_FREQ(SYS_HZ), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .CDROM_EN(1'b1), .CDROM_AUDIO_EN(1'b1)
  ) dut (
      .clk_sys(clk_sys), .reset(reset), .hps_apply_reset(1'b0), .rtc(rtc),
      .ext_mem_busy(1'b0),
      .ext_mem0_addr(ext_mem0_addr), .ext_mem0_din(ext_mem0_din),
      .ext_mem0_dout(ext_mem0_dout), .ext_mem0_resp_valid(ext_mem0_resp_valid),
      .ext_mem0_be(ext_mem0_be), .ext_mem0_burstcount(ext_mem0_burstcount),
      .ext_mem0_ready(ext_mem0_ready),
      .ext_mem0_valid(ext_mem0_valid), .ext_mem0_write(ext_mem0_write),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
      .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
      .ps2_key(11'd0), .ram_size(ram_size), .bios_set(4'd0), .ram_size_max(ram_size_max),
      .cpu_speed_sel(cpu_speed_sel),
      .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .debug_post_code(debug_post_code), .debug_post_write(debug_post_write),
      .debug_bios_loaded(debug_bios_loaded), .cpu_cs(cpu_cs),
      .cpu_eip(cpu_eip), .cpu_cs_base(cpu_cs_base),
      .video_ce(video_ce), .video_blank_n(video_blank_n),
      .video_hsync(video_hsync), .video_vsync(video_vsync),
      .video_r(video_r), .video_g(video_g), .video_b(video_b)
  );
  // The real-timing backend the boot tier uses (6 cycles accept-to-data, 3-cycle write busy).
  sdram_backend_model #(
      .ACCEPT_TO_RESP(4), .WRITE_BUSY(3), .LINE_RESP(0), .WORDS_LOG2(24)
  ) u_mem (
      .clk(clk_sys), .reset(reset),
      .valid(ext_mem0_valid), .ready(ext_mem0_ready), .write(ext_mem0_write),
      .addr(ext_mem0_addr), .din(ext_mem0_din), .din_hi(32'd0), .be(ext_mem0_be),
      .burstcount(ext_mem0_burstcount),
      .dout(ext_mem0_dout), .resp_valid(ext_mem0_resp_valid),
      .busy(), .accepts(), .beats()
  );

  // ==== STIMULUS ====
  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk_sys);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk_sys);
      ioctl_wr = 0;
    end
  endtask

  // Per-run measurements, keyed on the guest's POST codes.
  integer t_c0, t_c1, t_c2, e_c0, e_c1, e_c2;
  integer ce_count = 0;
  reg seen_c8, seen_c4, seen_c5, seen_cf;
  always @(posedge clk_sys) if (dut.cpu_ce) ce_count = ce_count + 1;
  always @(posedge clk_sys) if (debug_post_write) begin
    case (debug_post_code)
      8'hC8: seen_c8 = 1'b1;
      8'hC0: begin t_c0 = tb_cycles; e_c0 = ce_count; end
      8'hC1: begin t_c1 = tb_cycles; e_c1 = ce_count; end
      8'hC2: begin t_c2 = tb_cycles; e_c2 = ce_count; end
      8'hC4: seen_c4 = 1'b1;
      8'hC5: seen_c5 = 1'b1;
      8'hCF: seen_cf = 1'b1;
      8'hEF: $fatal(1, "speed %0d: the VSYNC interrupt never reached the CPU (no INTA through the bridge)", cpu_speed_sel);
      default: ;
    endcase
  end

  // ==== THE RE-REQUEST LEG ====
  // The guest's POST C6 arms it: IR0 (the PIT's out0 into the master's IR0) is held low,
  // and RR_GAP platform cycles after the master acknowledges IRQ2 it is raised (a rising
  // edge, so the edge-triggered master latches IRQ0). The master's INT drops at that
  // acknowledge and returns for IRQ0, which outranks the in-service IRQ2, RR_GAP cycles
  // later - shorter than one CPU clock period at 8 MHz and 1 MHz (6.25 and 50 platform
  // cycles at 50 MHz). The CPU must then acknowledge IRQ0 once the IRQ2 handler's IRET sets
  // IF; if it has not within RR_LIMIT platform cycles the run is the wedge: INTR high with
  // IF set and no INTA ever started.
  localparam integer RR_GAP   = 3;
  localparam integer RR_LIMIT = 4_000_000;
  integer rr_state = 0;   // 0 idle, 1 armed, 2 gap, 3 raised (waiting for IRQ0 in service), 4 done
  integer rr_count = 0;
  always @(posedge clk_sys) begin
    if (reset) begin
      if (rr_state != 0) release dut.interrupts.pit_out0;
      rr_state = 0;
    end else begin
      case (rr_state)
        0: if (debug_post_write && debug_post_code == 8'hC6) begin
             force dut.interrupts.pit_out0 = 1'b0;
             rr_state = 1;
           end
        1: if (dut.interrupts.pic_ack && dut.interrupts.master_irq == 3'd2) begin
             rr_count = 0;
             rr_state = 2;
           end
        2: begin
             rr_count = rr_count + 1;
             if (rr_count == RR_GAP) begin
               force dut.interrupts.pit_out0 = 1'b1;
               rr_count = 0;
               rr_state = 3;
             end
           end
        3: begin
             rr_count = rr_count + 1;
             if (dut.interrupts.master.isr[0]) begin
               force dut.interrupts.pit_out0 = 1'b0;
               rr_state = 4;
             end else if (rr_count >= RR_LIMIT)
               $fatal(1, "speed %0d: IRQ0, raised %0d platform cycles after the IRQ2 acknowledge, was never acknowledged in %0d cycles: INTR=%0d IF=%0d, master IRR=%02x ISR=%02x IMR=%02x, CS:EIP=%04x:%08x (the CPU never starts an INTA while INTR is held with IF set)",
                      cpu_speed_sel, RR_GAP, RR_LIMIT, dut.z_intr, dut.cpu_dbg_eflags[9],
                      dut.interrupts.dbg_irr, dut.interrupts.dbg_isr, dut.interrupts.dbg_imr, cpu_cs, cpu_eip);
           end
        default: ;
      endcase
    end
  end

  function automatic integer rate_khz(input [3:0] sel);
    // The RTL's own table, read back out of the instance (cpu_throttle.rate_khz).
    rate_khz = dut.u_cpu_throttle.rate_khz(sel);
  endfunction

  // The architectural results of a run.
  reg [31:0] checksum [0:2];
  reg [31:0] region_hash [0:2];
  integer rep_t [0:2], loop_t [0:2], rep_e [0:2], loop_e [0:2];
  reg [3:0] sel_of [0:2];
  integer run_i, k;
  reg [31:0] h;

  task automatic do_run(input integer idx, input [3:0] sel);
    integer budget, budget_max;
    begin
      sel_of[idx] = sel;
      cpu_speed_sel = sel;
      seen_c8 = 0; seen_c4 = 0; seen_c5 = 0; seen_cf = 0;
      t_c0 = -1; t_c1 = -1; t_c2 = -1;
      reset = 1;
      repeat (8) @(posedge clk_sys);
      @(negedge clk_sys);
      reset = 0;
      budget = 0;
      budget_max = 60_000_000;
      if ($value$plusargs("BUDGET=%d", budget_max)) ;
      while (!seen_cf && budget < budget_max) begin
        @(posedge clk_sys);
        budget = budget + 1;
      end
      if (!seen_cf)
        $fatal(1, "speed %0d: the guest did not finish in 60M cycles (CS:EIP=%04x:%08x)", sel, cpu_cs, cpu_eip);
      if (!seen_c8) $fatal(1, "speed %0d: the guest skipped its CPU-reset leg", sel);
      if (!seen_c4) $fatal(1, "speed %0d: no interrupt was taken", sel);
      if (!seen_c5 || rr_state != 4) $fatal(1, "speed %0d: the re-request leg did not complete (IRQ0 after the IRQ2 acknowledge)", sel);
      if (t_c0 < 0 || t_c1 < 0 || t_c2 < 0) $fatal(1, "speed %0d: a timing marker is missing", sel);
      repeat (2000) @(posedge clk_sys);   // the last stores drain to the backend
      rep_t[idx]  = t_c1 - t_c0;  rep_e[idx]  = e_c1 - e_c0;
      loop_t[idx] = t_c2 - t_c1;  loop_e[idx] = e_c2 - e_c1;
      checksum[idx] = u_mem.mem[32'h0610 >> 2];
      h = 32'h811c9dc5;
      for (k = 32'h10000 >> 2; k < (32'h10000 + N_DWORDS * 4) >> 2; k = k + 1)
        h = (h ^ u_mem.mem[k]) * 32'h01000193;
      region_hash[idx] = h;
      $display("RUN speed=%0d (%0d kHz): REP STOSD x%0d %0d clk / %0d CPU edges, DEC/JNZ x%0d %0d clk / %0d CPU edges, checksum %08x region %08x",
               sel, rate_khz(sel), N_DWORDS, rep_t[idx], rep_e[idx], N_LOOP, loop_t[idx], loop_e[idx],
               checksum[idx], region_hash[idx]);
    end
  endtask

  // Debug aids, none of them a verdict: +BUSTRACE prints the bridge's events at speed
  // +BUSTRACE_SEL (default 11), +ONLY_SLOW runs the 1 MHz leg alone, +BUDGET=<n> shortens the
  // per-run cycle bound.
  reg bustrace = 1'b0;
  integer bustrace_sel = 11, bustrace_n = 0;
  always @(posedge clk_sys)
    if (bustrace && !reset && cpu_speed_sel == bustrace_sel[3:0] && bustrace_n < 200000 &&
        ((dut.cpu_ce && (dut.zc_valid || dut.zc_resp_valid)) || dut.z_ready || dut.z_resp_valid)) begin
      bustrace_n = bustrace_n + 1;
      $display("BT %0d ce=%0d cv=%0d pv=%0d io=%0d wr=%0d a=%08x bc=%0d | pr=%0d prv=%0d cr=%0d crv=%0d din=%08x cdin=%08x acc=%0d cnt=%0d eip=%04x:%08x",
               tb_cycles, dut.cpu_ce, dut.zc_valid, dut.z_valid, dut.z_io, dut.z_write, {dut.z_addr, 2'b00},
               dut.z_burstcount, dut.z_ready, dut.z_resp_valid, dut.zc_ready, dut.zc_resp_valid,
               dut.z_din, dut.zc_din, dut.u_cpu_bridge.acc_pend, dut.u_cpu_bridge.count, cpu_cs, cpu_eip);
    end

  // ==== CHECKS ====
  integer errors = 0;
  real ratio, want, edge_t;
  initial begin
    if ($test$plusargs("BUSTRACE")) bustrace = 1'b1;
    if ($value$plusargs("BUSTRACE_SEL=%d", bustrace_sel)) ;
    $readmemh("throttle_pack.mem", pack_words);
    repeat (10) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;
    ioctl_download = 1;
    for (run_i = 0; run_i < 16'h4000; run_i = run_i + 1)
      send_word(run_i * 2, pack_words[run_i]);
    for (run_i = 0; run_i < 2048; run_i = run_i + 1)
      send_word(27'h0030000 + run_i * 2, pack_words[17'h18000 + run_i]);
    ioctl_download = 0;
    begin : wait_for_pack
      integer pack_poll = 0;
      while (!debug_bios_loaded && pack_poll < 2_000_000) begin
        @(posedge clk_sys);
        pack_poll = pack_poll + 1;
      end
      if (!debug_bios_loaded) $fatal(1, "the pack was never loaded (2M cycles)");
    end

    if ($test$plusargs("ONLY_SLOW")) begin
      do_run(2, 4'd11);
      $fatal(1, "+ONLY_SLOW is a debug run, not a verdict");
    end
    do_run(0, 4'd0);    // Full
    do_run(1, 4'd5);    // 8 MHz
    do_run(2, 4'd11);   // 1 MHz

    if (rep_e[0] != rep_t[0] || loop_e[0] != loop_t[0]) begin
      $display("FAIL: at Full the CPU missed an edge (cpu_ce was not constant 1)");
      errors = errors + 1;
    end
    for (run_i = 1; run_i < 3; run_i = run_i + 1) begin
      want = real'(SYS_KHZ) / real'(rate_khz(sel_of[run_i]));
      ratio = real'(loop_t[run_i]) / real'(loop_t[0]);
      $display("speed %0d: DEC/JNZ ratio %0.3f (requested %0.3f), REP STOSD ratio %0.3f, REP needs >= %0d clk at one edge per dword",
               sel_of[run_i], ratio, want, real'(rep_t[run_i]) / real'(rep_t[0]),
               $rtoi(N_DWORDS * want));
      if (ratio < want * 0.97 || ratio > want * 1.03) begin
        $display("FAIL: speed %0d: the cached DEC/JNZ ran %0.3fx its full-speed time, want %0.3fx", sel_of[run_i], ratio, want);
        errors = errors + 1;
      end
      if (real'(rep_t[run_i]) < real'(N_DWORDS) * want) begin
        $display("FAIL: speed %0d: the REP STOSD took %0d clk, under one throttled CPU edge per dword (%0d): the REP ran unthrottled",
                 sel_of[run_i], rep_t[run_i], $rtoi(N_DWORDS * want));
        errors = errors + 1;
      end
      // Each interval is its CPU-edge count at the selected rate (the rate generator's
      // Bresenham spread, measured from the edges the CPU actually got).
      edge_t = real'(rep_e[run_i]) * want;
      if (edge_t < real'(rep_t[run_i]) * 0.99 || edge_t > real'(rep_t[run_i]) * 1.01) begin
        $display("FAIL: speed %0d: %0d CPU edges in %0d clk is not the requested rate", sel_of[run_i], rep_e[run_i], rep_t[run_i]);
        errors = errors + 1;
      end
      if (checksum[run_i] !== checksum[0] || region_hash[run_i] !== region_hash[0]) begin
        $display("FAIL: speed %0d: the architectural results differ from full speed (checksum %08x vs %08x, region %08x vs %08x)",
                 sel_of[run_i], checksum[run_i], checksum[0], region_hash[run_i], region_hash[0]);
        errors = errors + 1;
      end
    end
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_THROTTLE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_THROTTLE: FAIL (%0d errors)", errors);
    end
  end
endmodule
