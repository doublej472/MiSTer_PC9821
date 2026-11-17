// tb_pc9821_reset_tree - every block of pc9821_system is reset from its own registered copy.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_RESET_TREE: every block of the real pc9821_system (built with CDROM_EN, MPU_EN, SDRAM_PHASE_DYN and PERF_LOG_EN on, so every reset consumer exists; the CPU is tests/pc9821/z486_stub.sv) is reset from its own registered copy of the platform reset. In every clock from power-up - through reset pulses of 1 to 40 clocks with no firmware pack and with one loaded, and across a second pack download that drops and raises cpu_run - every copy of both reset trees (pc9821_system's and pc9821_memory_subsystem's) equals the reset input of the clock before, so all copies agree, and they power up in reset; and the reset port of each block (the CPU reset gate, the I/O bus, the calendar, the rhythm loader, the OPNA, the game port, the -86 PCM, the INT5 share, the interrupt block, the keyboard, both IDE devices, the HDI detector, the disk LED, the block share, the floppy media, the EGC memory gate, the CRTC's two resets, the GDC, the CG, the dot clock, the SDRAM phase instrument, the MPU, the telemetry blocks, and inside the memory subsystem the loader, the window responder, the open bus, the PEGC, the GVRAM share, arbiter and scan, the PEGC scan, the GRCG, the EGC and the store buffer) carries that copy with its own term applied after it (`|| !cpu_run`, `&& !pack_load_hold`, `|| soft_reboot`, `|| !mpu_present_r`) - never the raw reset input; the two raster restarts (the CRTC's position counter and the dot clock, pc9821_raster_reseed) are not reset levels at all but one-clock restarts: the copy's first clock (the input high while the copy is still low) and its last clock (the copy high while the input is already low) - the one place the raw input is read, to find those clocks - the clock after the last for the counter, and cpu_run's rise. FAIL-FIRST: before the tree there is no copy to hold, and with any block put back on the raw reset, a tree fed from another copy, or a copy left unregistered, this bench fails (tests/pc9821/mutations.json).
//
// The expected value is the contract the tree is built to (src/pc9821/core/pc9821_reset_tree.sv:
// "q[k] in cycle t+1 is `reset` in cycle t, for every k, from power-up on"): the bench keeps its own
// one-clock-late copy of the reset it drives and compares every port with it, so no RTL value is
// the reference. The terms ORed after a copy (cpu_run, soft_reboot, pack_load_hold, mpu_present_r)
// are read from the DUT, since they are not what this bench is about; cpu_run is driven through
// both its edges by real pack downloads, so a block whose `|| !cpu_run` hid a raw reset while
// the pack was absent is still exposed while it is present.
//
// The reset input is driven with arbitrary pulses, shorter than the platform synchroniser's
// three-clock minimum too: the contract is per clock, whatever the waveform.

`timescale 1ns / 1ps

module tb_pc9821_reset_tree;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;

  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;

  integer errors = 0;
  task automatic fail(input string message);
    begin
      if (errors < 20) $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== THE RESET THIS BENCH DRIVES (pc9821_system's `reset` port) ====
  reg reset = 1'b1;   // powers up in reset, as z486_mister.sv's reset_sync_r does
  wire pack_load_hold;

  // ==== THE BACKEND (the loader writes the pack through it) ====
  wire [31:0] mem0_addr, mem0_din, mem0_din_hi;
  wire [3:0]  mem0_be;
  wire [7:0]  mem0_burstcount;
  wire        mem0_valid, mem0_write, mem0_gath;
  wire [440:0] mem0_gath_extra;
  wire [31:0] mem0_dout;
  wire        mem0_resp_valid, mem0_ready;
  wire        model_busy;
  wire [127:0] unused_line;
  wire        unused_line_valid;
  wire [31:0] model_accepts, model_beats;
  // The top level's controller reset as z486_mister.sv wires it: its own tree copy, then the hold.
  wire [0:0] rst_top;
  pc9821_reset_tree #(.N(1)) u_top_tree (.clk(clk_sys), .reset(reset), .q(rst_top));
  wire backend_reset = rst_top[0] && !pack_load_hold;

  sdram_backend_model #(
      .ACCEPT_TO_RESP(5), .WRITE_BUSY(3), .LINE_RESP(0), .WORDS_LOG2(16)
  ) backend (
      .clk(clk_sys), .reset(backend_reset),
      .valid(mem0_valid), .ready(mem0_ready),
      .write(mem0_write), .addr(mem0_addr), .din(mem0_din), .din_hi(mem0_din_hi),
      .gath(mem0_gath), .gath_extra(mem0_gath_extra),
      .be(mem0_be), .burstcount(mem0_burstcount),
      .dout(mem0_dout), .resp_valid(mem0_resp_valid),
      .line_dout(unused_line), .line_resp_valid(unused_line_valid),
      .busy(model_busy), .accepts(model_accepts), .beats(model_beats)
  );

  reg         ioctl_download = 1'b0;
  reg  [15:0] ioctl_index = 16'd0;
  reg         ioctl_wr = 1'b0;
  reg  [26:0] ioctl_addr = 27'd0;
  reg  [15:0] ioctl_dout = 16'd0;
  wire        ioctl_wait;

  // ==== DUT ====
  pc9821_system #(
      .SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .CDROM_EN(1'b1), .CDROM_AUDIO_EN(1'b0), .MPU_EN(1'b1), .SDRAM_PHASE_DYN(1'b1),
      .PERF_LOG_EN(1'b1)
  ) dut (
      .clk_sys(clk_sys),
      .reset(reset), .hps_apply_reset(1'b0),
      .rtc(rtc),
      .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0),
      .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(backend_reset || model_busy),
      .ext_mem0_addr(mem0_addr), .ext_mem0_din(mem0_din), .ext_mem0_din_hi(mem0_din_hi),
      .ext_mem0_gath(mem0_gath), .ext_mem0_gath_extra(mem0_gath_extra),
      .ext_mem0_be(mem0_be), .ext_mem0_burstcount(mem0_burstcount),
      .ext_mem0_valid(mem0_valid), .ext_mem0_write(mem0_write),
      .ext_mem0_dout(mem0_dout), .ext_mem0_resp_valid(mem0_resp_valid),
      .ext_mem0_ready(mem0_ready),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
      .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
      .pack_load_hold(pack_load_hold),
      .img_mounted(1'b0), .img_readonly(1'b0), .img_size(64'd0),
      .img_ack(1'b0), .img_buff_addr(13'd0), .img_buff_din(16'd0),
      .img_buff_wr(1'b0),
      .cd_mounted(1'b0), .cd_size(64'd0), .cd_ack(1'b0), .cdda_req(1'b0), .cdda_req4(1'b0),
      .cdda_played(1'b0), .cdda_flush(),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_byte(), .dbg_uart_we(), .dbg_uart_accept(1'b1),
      .mpu_present(1'b1),
      .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0),
      .trace_trig(),
      // 1 MiB guest and module ceiling: pack_base = 1 MiB, inside the model's window.
      .ram_size(3'd0), .ram_size_max(3'd0),
      .bios_set(4'd0)
  );

  // ==== CHECKS ====
  // pr: the reset this bench drove one clock ago - the value every copy must hold now. rd: the
  // raster's delayed cpu_run (pc9821_raster_reseed's run_d); rel_d: the copy's last clock, one late.
  reg pr = 1'b1;
  reg rd = 1'b0;
  reg rel_d = 1'b0;
  integer cycles = 0, moved_run = 0, moved_norun = 0;
  wire cpu_run = dut.cpu_run;
  wire run_rst = pr || !cpu_run;   // the `copy || !cpu_run` most blocks carry
  // inside pc9821_memory_subsystem `cpu_run` is the loader's own (pc9821_system's is it with its rise
  // held to the raster's frame end, pc9821_raster_reseed)
  wire run_rst_ld = pr || !dut.cpu_run_ld;
  // the CRTC's own cpu_run: it rises with cpu_run and falls at the raster's next frame end
  // (pc9821_raster_reseed's cpu_run_crtc); crd is it one clock late, so its fall is a restart
  wire run_rst_crtc = pr || !dut.cpu_run_crtc;
  reg  crd = 1'b0;

  task automatic want(input bit got, input bit exp, input string name);
    if (got !== exp) begin
      if (errors < 20)
        $display("FAIL: %s reset is %b, its copy says %b (reset %b, one clock ago %b) @ %0t",
                 name, got, exp, reset, pr, $time);
      errors = errors + 1;
    end
  endtask

  // Sampled on the rising edge, before this edge's updates: the copies hold what they loaded on
  // the edge before, and so does pr.
  always @(posedge clk_sys) begin
    cycles = cycles + 1;
    // every copy of both trees, and that they agree
    if ((&dut.u_reset_tree.q) !== pr || (|dut.u_reset_tree.q) !== pr)
      fail($sformatf("pc9821_system's reset tree reads %b, not every copy = %b", dut.u_reset_tree.q, pr));
    if ((&dut.memory.u_reset_tree.q) !== pr || (|dut.memory.u_reset_tree.q) !== pr)
      fail($sformatf("the memory subsystem's reset tree reads %b, not every copy = %b",
                     dut.memory.u_reset_tree.q, pr));
    // pc9821_system's blocks
    want(dut.cpu_reset_gate.reset, pr, "cpu_reset_gate");
    want(dut.iobus.reset, run_rst, "iobus");
    want(dut.calendar.rst_n, !run_rst, "calendar (rst_n)");
    want(dut.rhythm_loader.reset, pr, "rhythm_loader");
    want(dut.sound.reset, run_rst, "opna");
    want(dut.gameport.reset, run_rst, "gameport");
    want(dut.pcm86.reset, run_rst, "pcm86");
    want(dut.int5_share.reset, run_rst, "int5_share");
    want(dut.interrupts.reset_n, !run_rst, "interrupts (reset_n)");
    want(dut.keyboard.rst_n, !run_rst, "keyboard (rst_n)");
    want(dut.ata.rst_n, !(run_rst || dut.soft_reboot), "ata (rst_n)");
    want(dut.g_cdrom.atapi.rst_n, !(run_rst || dut.soft_reboot), "atapi (rst_n)");
    want(dut.hdd_image.rst_n, !pr, "hdd_image (rst_n)");
    want(dut.disk_led.reset, pr, "disk_led");
    want(dut.block_share.rst_n, !pr, "block_share (rst_n)");
    want(dut.fdd_media.reset, run_rst, "fdd_media");
    want(dut.u_egc_mem_gate.reset, run_rst, "egc_mem_gate");
    want(dut.u_crtc.rst_n_sys, !run_rst_crtc, "crtc (rst_n_sys)");
    if (cpu_run && !dut.cpu_run_crtc) begin
      $display("FAIL: the CRTC's cpu_run is low while cpu_run is high @ %0t", $time);
      errors = errors + 1;
    end
    // the raster's restarts (pc9821_raster_reseed): the copy's first clock (the input high, the copy
    // still low), its last clock (the copy high, the input already low), the clock after that, and
    // cpu_run's rise - never the reset level itself
    want(dut.u_crtc.rst_n_vid, !((reset && !pr) || (crd && !dut.cpu_run_crtc) || (pr && !reset) || rel_d || (cpu_run && !rd)), "crtc (rst_n_vid)");
    want(dut.u_gdc2.rst_n_sys, !run_rst, "gdc2 (rst_n_sys)");
    want(dut.u_cg.rst_n_sys, !run_rst, "cg (rst_n_sys)");
    want(dut.dot_ce.reset, (reset && !pr) || (crd && !dut.cpu_run_crtc) || (pr && !reset), "dot_ce");
    want(dut.g_sdph.u_sdph.reset, pr, "sdram_phase_ctl");
    want(dut.g_mpu.u_mpu.reset, pr || !dut.g_mpu.mpu_present_r, "mpu");
    want(dut.g_telemetry.u_wdg_trigger.reset, pr, "wdg_trigger");
    want(dut.g_telemetry.u_perf_msg.reset, pr, "perf_msg");
    want(dut.g_telemetry.u_gfx_msg.reset, pr, "gfx_msg");
    want(dut.g_telemetry.u_dbg_record.reset, pr, "dbg_record");
    // pc9821_memory_subsystem's blocks
    want(dut.memory.loader.reset, pr && !dut.memory.pack_load_hold_r, "rom_loader");
    want(dut.memory.u_window.reset, run_rst_ld, "window_responder");
    want(dut.memory.open_bus.reset, run_rst_ld, "open_bus");
    want(dut.memory.u_pegc.reset, run_rst_ld, "pegc");
    want(dut.memory.u_gvr_share.reset, run_rst_ld, "gvram_share");
    want(dut.memory.u_gvram_arb.reset, run_rst_ld, "gvram_arb");
    want(dut.memory.u_pegc_scan.reset, run_rst_ld, "pegc_scan");
    want(dut.memory.u_gvram_scan.reset, run_rst_ld, "gvram_scan");
    want(dut.memory.u_grcg.reset, run_rst_ld, "grcg");
    want(dut.memory.u_egc.reset, run_rst_ld, "egc");
    want(dut.memory.u_storebuf.reset, run_rst_ld, "pegc_storebuf");
    // the top level's controller copy, modelled as z486_mister.sv wires it
    want(backend_reset, pr && !pack_load_hold, "SDRAM backend (modelled top)");
    // coverage: a raw reset differs from its copy, with and without the pack
    if (reset !== pr) begin
      if (cpu_run) moved_run = moved_run + 1;
      else         moved_norun = moved_norun + 1;
    end
    rd <= cpu_run;
    crd <= dut.cpu_run_crtc;
    rel_d <= pr && !reset;
    pr <= reset;
  end

  // ==== STIMULUS ====
  localparam integer WORDS = 64;
  task automatic download(input integer pass);
    integer i;
    begin
      @(negedge clk_sys);
      ioctl_index = 16'd0;
      repeat (4) @(negedge clk_sys);
      ioctl_download = 1'b1;
      repeat (12) @(negedge clk_sys);
      for (i = 0; i < WORDS; i = i + 1) begin
        while (ioctl_wait) @(negedge clk_sys);
        ioctl_addr = 27'(i * 2);
        ioctl_dout = 16'hA500 ^ 16'(i * 37) ^ 16'(pass << 12);
        ioctl_wr   = 1'b1;
        @(negedge clk_sys);
        ioctl_wr   = 1'b0;
        repeat (3) @(negedge clk_sys);
      end
      while (ioctl_wait) @(negedge clk_sys);
      repeat (4) @(negedge clk_sys);
      ioctl_download = 1'b0;
    end
  endtask

  // Reset pulses of pseudo-random width 1..40 and gap 1..60 (a fixed LFSR, so every run is the same).
  reg [15:0] lfsr = 16'hACE1;
  task automatic pulses(input integer n);
    integer k, w, g;
    begin
      for (k = 0; k < n; k = k + 1) begin
        lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        w = 1 + (lfsr % 40);
        lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        g = 1 + (lfsr % 60);
        @(negedge clk_sys) reset = 1'b1;
        repeat (w) @(negedge clk_sys);
        reset = 1'b0;
        repeat (g) @(negedge clk_sys);
      end
    end
  endtask

  initial begin
    // ---- power-up: every copy starts in reset, before the first edge ----
    #1;
    if ((&dut.u_reset_tree.q) !== 1'b1 || (&dut.memory.u_reset_tree.q) !== 1'b1 || rst_top[0] !== 1'b1)
      fail("a reset copy does not power up in reset");
    repeat (20) @(negedge clk_sys);
    reset = 1'b0;
    repeat (20) @(negedge clk_sys);

    // ---- A. no pack: cpu_run low ----
    pulses(30);
    if (cpu_run !== 1'b0) fail("cpu_run is up before any pack");

    // ---- B. a pack loads (reset low): cpu_run rises ----
    download(1);
    // cpu_run rises on the raster's next frame end after the load (pc9821_raster_reseed): bounded
    // by one frame of the power-on raster (373 120 dots) at this SYS_FREQ's dot rate
    begin : wait_run_b
      integer n = 0;
      while (cpu_run !== 1'b1 && n < 2_000_000) begin @(negedge clk_sys); n = n + 1; end
    end
    repeat (40) @(negedge clk_sys);
    if (cpu_run !== 1'b1) fail("the pack did not load (cpu_run low)");

    // ---- C. the pack present: every block's copy is visible through its port ----
    pulses(60);

    // ---- D. a second download: cpu_run falls and rises with reset low ----
    download(2);
    // cpu_run rises on the raster's next frame end after the load (pc9821_raster_reseed): bounded
    // by one frame of the power-on raster (373 120 dots) at this SYS_FREQ's dot rate
    begin : wait_run_d
      integer n = 0;
      while (cpu_run !== 1'b1 && n < 2_000_000) begin @(negedge clk_sys); n = n + 1; end
    end
    repeat (40) @(negedge clk_sys);
    if (cpu_run !== 1'b1) fail("the second pack did not load (cpu_run low)");
    pulses(20);
    repeat (20) @(negedge clk_sys);

    // ==== VERDICT ====
    $display("  %0d clocks checked; the raw reset differed from its copy in %0d with the pack, %0d without",
             cycles, moved_run, moved_norun);
    if (moved_run < 100 || moved_norun < 50) fail("the stimulus did not move the reset enough to see a raw consumer");
    if (errors == 0) begin
      $display("TB_PC9821_RESET_TREE: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_RESET_TREE: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000_000;
    $fatal(1, "TB_PC9821_RESET_TREE: TIMEOUT");
  end

endmodule
