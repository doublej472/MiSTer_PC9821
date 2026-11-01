`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_SNOOP_THROTTLE: DMA writes accepted by the backend inside a gated (cpu_ce=0) CPU run still invalidate every line they land in - one FDC byte held for the next enabled edge, then TWO back-to-back bytes of a software-request channel-0 transfer in ONE disabled run, each into a different cached line, with both re-reads coherent. It runs the REAL pc9821_system (real z486, real gated cpu_clk, real bridge, real iobus/FDC/uPD71071) at OSD CPU Speed = 1 MHz, so a disabled run spans the uPD71071's ~8-cycle byte cadence: a one-deep snoop hold would let the second accept replace the first address and leave the first line stale, and the bench also asserts no write was accepted while the bridge held a snoop (the back-pressure).
//
// WHY TWO PHASES. Phase 1 (the F1 counterexample) is a count-0 channel-3 FDC transfer:
// exactly ONE byte, hence one snoop, whose fate is decided by the cycle it lands in; the
// bench forces that cycle disabled. Phase 2 (the G1 counterexample) is a TWO-byte
// software-request port-to-memory transfer on channel 0 (no device, so the engine moves
// both bytes at bus rate, ~8-10 clk_sys each) programmed to walk DOWN from 0x2020: byte 0
// lands in 0x2020 (D$ set 1) and byte 1 in 0x201F (set 0). At 1 MHz the disabled run is
// 49 clk_sys of a 50 MHz build, so both accepts fall inside ONE run. A one-deep hold
// takes the live address for the second accept and abandons the first, so the 0x2020
// line stays stale - the guest reads 0xA5A55678 and the bench fails on POST 0xEB. The
// back-pressure fix withdraws the second byte from the memory subsystem until the CPU's
// next enabled edge has taken the first snoop, so both are invalidated; the bench also
// counts accepts seen while the hold is occupied (must be 0) and the accept addresses
// (must be exactly 0x2020 then 0x201F).
//
// FAIL-FIRST: on 723774e8 (one-deep hold, no back-pressure) phase 2 fails with POST 0xEB
// (and an accept lands while the hold is busy); with the fix both phases pass.
//
// The FDD media is modelled at pc9821_fdd_media's own seam (the same model
// tb_pc9821_dma_flush_coherency drives at the iobus): it is held "not ready" until the
// bench arms the disabled-cycle window, so the accept cannot happen before the phase is
// forced.

`default_nettype none

module tb_pc9821_dma_snoop_throttle;
  localparam integer SYS_HZ  = 50_000_000;

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
  // OSD CPU Speed = 1 MHz (sel 11): a disabled run is 49 clk_sys of this 50 MHz build,
  // which spans two uPD71071 bytes (~8-10 clk_sys apart), so a two-byte software-request
  // transfer really does accept both inside one run. At 8 MHz (6-cycle runs) it could not.
  reg [3:0] cpu_speed_sel = 4'd11;
  reg [15:0] pack_words [0:17'h187ff];

  // ==== DUT ====
  pc9821_system #(
      .SYS_FREQ(SYS_HZ), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .CDROM_EN(1'b0), .CDROM_AUDIO_EN(1'b0)
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
      .bios_setup(1'b0), .cpu_speed_sel(cpu_speed_sel),
      .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .debug_post_code(debug_post_code), .debug_post_write(debug_post_write),
      .debug_bios_loaded(debug_bios_loaded), .cpu_cs(cpu_cs),
      .cpu_eip(cpu_eip), .cpu_cs_base(cpu_cs_base),
      .video_ce(video_ce), .video_blank_n(video_blank_n),
      .video_hsync(video_hsync), .video_vsync(video_vsync),
      .video_r(video_r), .video_g(video_g), .video_b(video_b)
  );

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

  // ==== the FDD media, forced at pc9821_fdd_media's seam ====
  // The coherency bench's model: a byte per fdd_req, byte k = R ^ k, advanced by fdd_adv.
  // `media_ready` holds the byte back until the bench has forced the disabled-cycle
  // window, so the accept is guaranteed to be inside it.
  reg        media_ready = 1'b0;
  reg        m_xfer = 1'b0;
  reg [15:0] m_ptr = 16'd0;
  reg  [7:0] m_last_r = 8'h00;
  integer    m_reqs = 0;

  always @(posedge clk_sys) begin
    if (reset) begin
      m_xfer <= 1'b0; m_ptr <= 16'd0; m_last_r <= 8'h00; m_reqs <= 0;
    end else begin
      if (dut.fdd_req) begin
        m_reqs <= m_reqs + 1;
        if (!dut.fdd_req_hdr) begin
          m_xfer   <= 1'b1;
          m_ptr    <= 16'd0;
          m_last_r <= dut.fdd_r;
        end
      end
      if (m_xfer && dut.fdd_adv) m_ptr <= m_ptr + 16'd1;
    end
  end

  // Forced every evaluation with the current regs, so there is no skew.
  always @* begin
    force dut.fdd_media_present = 2'b01;
    force dut.fdd_ready = ~m_xfer;                    // drive ready (not busy in a transfer)
    force dut.fdd_rdy   = m_xfer & media_ready;       // byte available only once armed
    force dut.fdd_dout  = m_xfer ? (m_last_r ^ m_ptr[7:0]) : 8'h00;
    force dut.fdd_hdrv  = 1'b0;
    force dut.fdd_err   = 1'b0;
    force dut.fdd_hr    = 8'h01;
    force dut.fdd_hn    = 8'h03;
    force dut.fdd_hs    = 8'h02;
  end

  // ==== the disabled-cycle window (phase 1) and the two-accept window (phase 2) ====
  // Phase 1: on the guest's POST 0xB1 (DMAC armed, FDC command out) the bench forces
  // cpu_ce low and releases the media; the one DMA byte's accept can then only happen in
  // a disabled cycle. It releases cpu_ce on the accept edge. `accept_seen`/`accept_addr`
  // are the setup proof; if no accept ever lands, the run fails rather than passing
  // vacuously.
  //
  // Phase 2 (from POST 0xB3) is NOT forced: the 1 MHz throttle itself produces the
  // 49-cycle disabled run both accepts must fall in, which is the real-machine case. The
  // counters record the accepts, their addresses and - the back-pressure invariant - any
  // accept seen while the bridge's one-deep hold was still occupied (snoop_pend).
  reg        phase_hold = 1'b0;
  reg        accept_seen = 1'b0;
  reg [31:0] accept_addr = 32'h0;
  integer    snoop_count = 0;
  integer    accept_disabled = 0;
  reg        phase2 = 1'b0;
  integer    p2_snoops = 0;
  integer    p2_disabled = 0;
  integer    p2_accepts_while_busy = 0;
  reg        p2_saw_2020 = 1'b0;
  reg        p2_saw_201f = 1'b0;
  reg [31:0] p2_last_addr = 32'h0;

  always @(posedge clk_sys) begin
    if (reset) begin
      phase_hold <= 1'b0; accept_seen <= 1'b0; accept_addr <= 32'h0;
      snoop_count <= 0; accept_disabled <= 0; media_ready <= 1'b0;
      phase2 <= 1'b0; p2_snoops <= 0; p2_disabled <= 0;
      p2_accepts_while_busy <= 0; p2_saw_2020 <= 1'b0; p2_saw_201f <= 1'b0;
      p2_last_addr <= 32'h0;
    end else begin
      if (phase_hold) begin
        if (dut.dma_snoop_valid) begin
          accept_seen   <= 1'b1;
          accept_addr   <= dut.dma_mem_addr;
          accept_disabled <= accept_disabled + 1;
          release dut.cpu_ce;
          phase_hold    <= 1'b0;
        end
      end
      if (dut.dma_snoop_valid && !phase2) snoop_count <= snoop_count + 1;
      if (dut.dma_snoop_valid && phase2) begin
        p2_snoops  <= p2_snoops + 1;
        p2_last_addr <= dut.dma_mem_addr;
        if (!dut.cpu_ce) p2_disabled <= p2_disabled + 1;
        if (dut.dma_mem_addr == 32'h0000_2020) p2_saw_2020 <= 1'b1;
        if (dut.dma_mem_addr == 32'h0000_201f) p2_saw_201f <= 1'b1;
      end
      // THE BACK-PRESSURE INVARIANT: a WRITE accepted while the bridge's hold is already
      // occupied is exactly the overrun the fix removes (it would discard the waiting
      // address). Read hierarchically so the same bench compiles against the pre-fix tree.
      if (dut.dma_snoop_valid && dut.u_cpu_bridge.snoop_pend)
        p2_accepts_while_busy <= p2_accepts_while_busy + 1;
    end
  end

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

  // ==== CHECKS ====
  integer errors = 0;
  reg saw_b0 = 0, saw_b1 = 0, saw_b2 = 0, saw_pass = 0, saw_stale = 0, saw_notc = 0;
  reg saw_b3 = 0, saw_b4 = 0, saw_pass2 = 0, saw_stale2 = 0, saw_notc2 = 0;
  reg saw_stale_first = 0, saw_stale_second = 0;
  always @(posedge clk_sys) if (debug_post_write) begin
    case (debug_post_code)
      8'hB0: saw_b0 <= 1'b1;
      8'hB1: begin
        // Arm the disabled-cycle window and let the media deliver its byte.
        saw_b1    <= 1'b1;
        phase_hold <= 1'b1;
        media_ready <= 1'b1;
        force dut.cpu_ce = 1'b0;
      end
      8'hB2: saw_b2 <= 1'b1;
      8'hB3: begin
        // Phase 2 begins: both target lines are cached and the next transfer is armed.
        saw_b3 <= 1'b1;
        phase2 <= 1'b1;
      end
      8'hB4: saw_b4 <= 1'b1;
      8'h5A: saw_pass <= 1'b1;
      8'h5B: saw_pass2 <= 1'b1;
      8'hE7: saw_stale <= 1'b1;
      8'hEB: begin saw_stale2 <= 1'b1; saw_stale_first  <= 1'b1; end
      8'hEC: begin saw_stale2 <= 1'b1; saw_stale_second <= 1'b1; end
      8'hE9: saw_notc <= 1'b1;
      8'hE8: saw_notc2 <= 1'b1;
      default: ;
    endcase
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_DMA_SNOOP_THROTTLE: watchdog timeout (no verdict reached)");
  end

  integer i;
  initial begin
    $readmemh("dma_snoop_pack.mem", pack_words);
    repeat (10) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;
    ioctl_download = 1;
    for (i = 0; i < 16'h4000; i = i + 1)
      send_word(i * 2, pack_words[i]);
    for (i = 0; i < 2048; i = i + 1)
      send_word(27'h0030000 + i * 2, pack_words[17'h18000 + i]);
    ioctl_download = 0;
    begin : wait_for_pack
      integer pack_poll = 0;
      while (!debug_bios_loaded && pack_poll < 2_000_000) begin
        @(posedge clk_sys);
        pack_poll = pack_poll + 1;
      end
      if (!debug_bios_loaded) $fatal(1, "the pack was never loaded (2M cycles)");
    end

    fork
      begin
        wait (saw_pass2 || saw_stale || saw_stale2 || saw_notc || saw_notc2);
        repeat (20) @(posedge clk_sys);
        // The guest cached the line before the DMA.
        if (!saw_b0) $fatal(1, "the guest never emitted POST B0 (line not cached)");
        if (!saw_b1) $fatal(1, "the guest never emitted POST B1 (DMAC/FDC never armed)");
        if (saw_notc) $fatal(1, "the FDC DMA never reached terminal count (no byte transferred)");
        // THE PHASE-1 SETUP PROOF: the accept must have happened in the forced disabled cycle.
        if (!accept_seen || accept_disabled == 0)
          $fatal(1, "the FDC DMA accept never landed while cpu_ce was forced low - this run proves nothing");
        if (accept_addr !== 32'h0000_2000)
          $fatal(1, "the FDC accept address was %08x, want 00002000", accept_addr);
        if (snoop_count != 1)
          $fatal(1, "the one-byte FDC transfer raised %0d snoops, want exactly 1", snoop_count);
        // THE PHASE-1 VERDICT: the CPU's re-read is coherent.
        if (saw_stale)
          $fatal(1, "the CPU read the STALE cached dword after a DMA accept in a disabled cycle (the snoop was not held for the gated CPU clock)");
        if (!saw_pass)
          $fatal(1, "phase 1 reached no pass marker");
        // ---- PHASE 2: TWO accepted writes in one disabled run ----
        if (!saw_b3) $fatal(1, "the guest never emitted POST B3 (phase 2 never ran)");
        if (saw_notc2) $fatal(1, "the two-byte channel-0 transfer never reached terminal count");
        if (!saw_b4)  $fatal(1, "the guest never emitted POST B4 (phase-2 terminal count)");
        if (p2_snoops != 2)
          $fatal(1, "the two-byte transfer raised %0d snoops, want exactly 2", p2_snoops);
        if (!p2_saw_2020 || !p2_saw_201f)
          $fatal(1, "the snoop addresses were not both of {2020,201f} (last %08x)", p2_last_addr);
        if (p2_disabled < 1)
          $fatal(1, "neither phase-2 accept landed in a disabled cycle - the run proves nothing");
        if (saw_stale_first)
          $fatal(1, "the 0x2020 line was STALE after the two-byte DMA transfer (G1: the FIRST accepted write lost its invalidate - the second accept replaced its address in the one-deep hold); memory now 2020=%08x 201c=%08x",
                 u_mem.peek(32'h0000_2020), u_mem.peek(32'h0000_201c));
        if (saw_stale_second)
          $fatal(1, "the 0x201C line was STALE after the two-byte DMA transfer (G1: the SECOND accepted write lost its invalidate); memory now 2020=%08x 201c=%08x",
                 u_mem.peek(32'h0000_2020), u_mem.peek(32'h0000_201c));
        if (p2_accepts_while_busy != 0)
          $fatal(1, "%0d DMA write(s) were ACCEPTED while the bridge still held a snoop - the back-pressure did not hold", p2_accepts_while_busy);
        if (!saw_pass2)
          $fatal(1, "the guest reached neither the pass nor a stale marker in phase 2");
        $display("NOTE dma_snoop_throttle: cpu_speed=%0d phase1_accepts=%0d phase1_snoops=%0d addr=%08x phase2_snoops=%0d phase2_disabled=%0d accepts_while_busy=%0d",
                 cpu_speed_sel, accept_disabled, snoop_count, accept_addr,
                 p2_snoops, p2_disabled, p2_accepts_while_busy);
      // ==== VERDICT ====
        $display("TB_PC9821_DMA_SNOOP_THROTTLE: PASS");
        $finish;
      end
      begin
        repeat (50_000_000) @(posedge clk_sys);
        $fatal(1, "dma_snoop_throttle timeout CS:EIP=%04x:%08x (POST B0=%0d B1=%0d B2=%0d B3=%0d B4=%0d)",
               cpu_cs, cpu_eip, saw_b0, saw_b1, saw_b2, saw_b3, saw_b4);
      end
    join
  end
endmodule

`default_nettype wire
