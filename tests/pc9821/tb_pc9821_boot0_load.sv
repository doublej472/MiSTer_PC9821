// tb_pc9821_boot0_load - the firmware pack sent as a boot ROM at core start, under the OSD Reset level.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_BOOT0_LOAD: the firmware pack sent as games/PC9821/boot0.rom at core start lands with Main_MiSTer's own sequence (release 20261010, commit 738cb7a): status[0] set before the transfer (user_io.cpp:1613) and held across the whole ioctl download (index 0, user_io.cpp:1684), released only after it (user_io.cpp:1774). Through the real pc9821_system (its pc9821_memory_subsystem, pc9821_rom_loader and pc9821_cpu_reset_gate; the CPU is tests/pc9821/z486_stub.sv) with the top level's reset synchroniser and the SDRAM backend's reset as z486_mister.sv wires them, and a backend that is busy for its initialisation after every reset, every word of the pack reaches SDRAM, the pack is accepted (rom_ready high, load_error low) before status[0] falls, the CPU stays in reset until status[0] falls and leaves it after, and the backend is reset exactly once (at status[0]'s rise, before the download) so its initialisation is not re-run when status[0] falls. Regressions: a later OSD Reset (a status[0] pulse with no download) resets the backend once, keeps the pack (rom_ready stays high, no re-load needed) and releases the CPU after the controller's initialisation; an OSD load of a second pack (status[0] low, menu.cpp:2752) takes the CPU into reset, rewrites the pack without resetting the backend and releases the CPU at its end. FAIL-FIRST: on the tree before the change (bench built with -DPRE_BOOT0_LOAD, the backend on the plain platform reset) the loader is held in the platform reset for the whole boot-ROM download, no word lands and rom_ready never rises.
//
// THE SEQUENCE IS MAIN_MISTER'S, not this core's. In user_io.cpp at 738cb7a:
//   * :1613 `user_io_status_set("[0]", 1);` after the config load ("send a reset"; :1516 does the
//     same for every 8-bit core), BEFORE the boot ROMs;
//   * :1684 `user_io_file_tx(mainpath, i << 6);` for boot0.rom..boot3.rom, so boot0.rom is index 0,
//     the index of this core's `F0,BIN,Load BIOS ROM;` entry;
//   * :1774 `if (!is_minimig() && !is_st()) user_io_status_set("[0]", 0);` ("release reset") only
//     after them.
// user_io_file_tx is the same transfer the OSD's file load uses (menu.cpp:2752
// `user_io_file_tx(selPath, idx, opensave, 0, 0, load_addr);`): user_io_set_index(index), then
// user_io_set_download(1, 0), the data in FIO_FILE_TX_DAT chunks, then user_io_set_download(0).
// hps_io turns those into ioctl_index (sys/hps_io.sv:694 `ioctl_index <= io_din[15:0];`),
// ioctl_download raised when the FIO_FILE_TX command ends (sys/hps_io.sv:667
// `{ioctl_upload, ioctl_download} <= req_io;`), one ioctl_wr per 16-bit word a clock after its
// io_strobe (sys/hps_io.sv:662 `ioctl_wr <= wr;`), the address stepping by 2 (sys/hps_io.sv:716),
// and ioctl_download cleared by the closing FIO_FILE_TX (sys/hps_io.sv:707
// `ioctl_download <= 0;`). The host holds the next word while ioctl_wait is high
// (sys/hps_io.sv:206 `assign HPS_BUS[37]   = ioctl_wait;`). So the only difference between a
// boot ROM and an OSD load is the status[0] level around it, which is what this bench varies.
//
// THE TOP LEVEL IS MODELLED, because z486_mister.sv is in no bench's file list: its
// `reset_req = buttons[1] | status[0] | disk_change_reset` (status[0] alone here), the reset_sync_r
// synchroniser (set by the request, released by a three-stage shift), and the backend's
// `.reset(reset_sync_r[2] && !pack_load_hold)`. tools/check_wiring.py pins those texts in the top.
// The backend is tests/pc9821/sdram_backend_model.sv behind an initialisation window: after every
// reset it is busy and accepts nothing for INIT_CYCLES, as src/memory/sdram.v is busy through its
// JEDEC initialisation (the contract pc9821_cpu_reset_gate's sdram_ready term reads).

`timescale 1ns / 1ps

module tb_pc9821_boot0_load;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;

  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;

  integer errors = 0;

  task fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== THE TOP LEVEL'S RESET (z486_mister.sv) ====
  reg        status0 = 1'b0;
  wire       reset_req = status0;
  reg  [2:0] reset_sync_r = 3'b111;
  always @(posedge clk_sys) begin
    if (reset_req) reset_sync_r <= 3'b111;
    else           reset_sync_r <= {reset_sync_r[1:0], 1'b0};
  end
  wire reset = reset_sync_r[2];
  wire pack_load_hold;
`ifdef PRE_BOOT0_LOAD
  wire backend_reset = reset;
`else
  wire backend_reset = reset && !pack_load_hold;
`endif

  // ==== THE HPS DOWNLOAD STREAM ====
  reg         ioctl_download = 1'b0;
  reg  [15:0] ioctl_index = 16'd0;
  reg         ioctl_wr = 1'b0;
  reg  [26:0] ioctl_addr = 27'd0;
  reg  [15:0] ioctl_dout = 16'd0;
  wire        ioctl_wait;

  // ==== THE BACKEND: the model behind an initialisation window ====
  localparam integer INIT_CYCLES = 300;
  integer init_left = INIT_CYCLES;
  integer backend_resets = 0;      // rising edges of the backend's reset
  reg     backend_reset_d = 1'b1;
  always @(posedge clk_sys) begin
    backend_reset_d <= backend_reset;
    if (backend_reset && !backend_reset_d) backend_resets <= backend_resets + 1;
    if (backend_reset) init_left <= INIT_CYCLES;
    else if (init_left != 0) init_left <= init_left - 1;
  end
  wire initialising = backend_reset || (init_left != 0);

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

  sdram_backend_model #(
      .ACCEPT_TO_RESP(5), .WRITE_BUSY(3), .LINE_RESP(0), .WORDS_LOG2(16)
  ) backend (
      .clk(clk_sys), .reset(backend_reset),
      .valid(mem0_valid && !initialising), .ready(mem0_ready),
      .write(mem0_write), .addr(mem0_addr), .din(mem0_din), .din_hi(mem0_din_hi),
      .gath(mem0_gath), .gath_extra(mem0_gath_extra),
      .be(mem0_be), .burstcount(mem0_burstcount),
      .dout(mem0_dout), .resp_valid(mem0_resp_valid),
      .line_dout(unused_line), .line_resp_valid(unused_line_valid),
      .busy(model_busy), .accepts(model_accepts), .beats(model_beats)
  );

  // ==== DUT ====
  pc9821_system #(
      .SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4),
      .ENABLE_X87(1'b0)
  ) dut (
      .clk_sys(clk_sys),
      .reset(reset), .hps_apply_reset(status0),
      .rtc(rtc),
      .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0),
      .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(initialising || model_busy),
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
`ifndef PRE_BOOT0_LOAD
      .pack_load_hold(pack_load_hold),
`endif
      .img_mounted(1'b0), .img_readonly(1'b0), .img_size(64'd0),
      .img_ack(1'b0), .img_buff_addr(13'd0), .img_buff_din(16'd0),
      .img_buff_wr(1'b0),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0),
      .trace_trig(),
      // 1 MiB guest and module ceiling: pack_base = 1 MiB, inside the model's 256 KiB window as 0.
      .ram_size(3'd0), .ram_size_max(3'd0),
      .bios_set(4'd0)
  );
`ifdef PRE_BOOT0_LOAD
  assign pack_load_hold = 1'b0;
`endif

  // ==== STIMULUS ====
  // The pack words this bench sends: offsets 0 .. 2*WORDS-2, below the BIOS-top bank the loader
  // tees into the shadow, so each word has exactly one home in the model.
  localparam integer WORDS = 256;
  localparam [31:0] PACK_BASE = 32'h0010_0000;

  function automatic [15:0] word_of(input integer pass, input integer i);
    word_of = 16'hA500 ^ (i[15:0] * 16'd37) ^ (pass[15:0] << 12);
  endfunction

  // One download as hps_io presents it: index, the download level, a gap before the first data
  // command, then one ioctl_wr per word, each only once ioctl_wait is low, and the level cleared.
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
        ioctl_addr = i * 2;
        ioctl_dout = word_of(pass, i);
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

  // ==== CHECKS ====
  task automatic check_pack(input [8*40-1:0] name, input integer pass);
    integer i, bad;
    reg [31:0] w;
    reg [15:0] got;
    begin
      bad = 0;
      for (i = 0; i < WORDS; i = i + 1) begin
        w = backend.peek(PACK_BASE + i * 2);
        got = (i % 2) ? w[31:16] : w[15:0];
        if (got !== word_of(pass, i)) begin
          if (bad < 4)
            $display("FAIL: %0s: pack word %0d reads %04h in SDRAM, sent %04h", name, i, got,
                     word_of(pass, i));
          bad = bad + 1;
        end
      end
      if (bad != 0) begin
        $display("FAIL: %0s: %0d of %0d pack words did not land", name, bad, WORDS);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_accepted(input [8*40-1:0] name);
    begin
      if (dut.rom_ready !== 1'b1 || dut.load_error !== 1'b0)
        begin
          $display("FAIL: %0s: pack not accepted (rom_ready=%b load_error=%b)", name, dut.rom_ready,
                   dut.load_error);
          errors = errors + 1;
        end
    end
  endtask

  // The CPU must leave reset within `limit` clocks, and not before `status0` is low.
  task automatic expect_cpu_start(input [8*40-1:0] name, input integer limit);
    integer n;
    begin
      n = 0;
      while (dut.cpu_reset_n !== 1'b1 && n < limit) begin
        @(negedge clk_sys);
        n = n + 1;
      end
      if (dut.cpu_reset_n !== 1'b1) begin
        $display("FAIL: %0s: the CPU did not leave reset within %0d clocks", name, limit);
        errors = errors + 1;
      end else $display("  %0s: CPU out of reset %0d clocks after the release", name, n);
    end
  endtask

  // The CPU is never out of reset while the OSD Reset level is up or a pack is downloading. The
  // levels are sampled a few clocks late: the loader sees a download on its next clock (its
  // download edge), and the gate's release synchroniser is cleared asynchronously from there.
  reg [3:0] status0_q = 4'd0, download_q = 4'd0;
  always @(posedge clk_sys) begin
    status0_q  <= {status0_q[2:0], status0};
    download_q <= {download_q[2:0], ioctl_download};
  end
  always @(negedge clk_sys)
    if ((status0_q[1] && status0) || (download_q[3] && ioctl_download))
      if (dut.cpu_reset_n === 1'b1) fail("the CPU is out of reset under status[0] or a download");

  integer resets_before, accepts_before;

  initial begin
    // ---- power-up: the core starts; the HPS identifies it with status[0] low ----
    repeat (20) @(negedge clk_sys);

    // ---- A. the boot ROM: status[0] up (user_io.cpp:1613), boot0.rom (:1684), released (:1774) ----
    status0 = 1'b1;
    repeat (40) @(negedge clk_sys);
    resets_before = backend_resets;
    download(1);
    repeat (200) @(negedge clk_sys);     // send_rtc and the rest before the release
    expect_accepted("boot ROM, before release");
    check_pack("boot ROM", 1);
    if (dut.cpu_reset_n !== 1'b0) fail("boot ROM: the CPU left reset before status[0] fell");
    status0 = 1'b0;
    expect_cpu_start("boot ROM", 200);
    expect_accepted("boot ROM, after release");
    if (backend_resets != resets_before)
      fail("boot ROM: the SDRAM backend was reset again after the download began");

    // ---- B. a later OSD Reset: a status[0] pulse, no download ----
    repeat (100) @(negedge clk_sys);
    resets_before = backend_resets;
    status0 = 1'b1;
    repeat (30) @(negedge clk_sys);
    status0 = 1'b0;
    // The controller re-initialises (INIT_CYCLES) and the CPU waits for it, as before the change.
    expect_cpu_start("OSD reset", INIT_CYCLES + 200);
    if (backend_resets != resets_before + 1)
      fail("OSD reset: the SDRAM backend was not reset exactly once");
    expect_accepted("OSD reset (the pack is kept)");
    check_pack("OSD reset (the pack is kept)", 1);

    // ---- C. an OSD load of a second pack (status[0] low throughout) ----
    repeat (100) @(negedge clk_sys);
    resets_before = backend_resets;
    accepts_before = model_accepts;
    download(2);
    expect_cpu_start("OSD load", 200);
    expect_accepted("OSD load");
    check_pack("OSD load", 2);
    if (backend_resets != resets_before) fail("OSD load: the SDRAM backend was reset");
    if (model_accepts - accepts_before < WORDS) fail("OSD load: fewer backend writes than words");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_BOOT0_LOAD: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_BOOT0_LOAD: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_BOOT0_LOAD: TIMEOUT");
  end

endmodule
