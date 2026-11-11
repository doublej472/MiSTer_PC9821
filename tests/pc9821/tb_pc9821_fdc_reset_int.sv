`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDC_RESET_INT: a controller reset through the 0x94 DOR, RELEASED (bit 7 falling) by a write with or without the motor bit 0x08 (the real Xe10 interrupts 1.07 ms after both, docs/probes/XE10T-XE10-FDC2A.TXT RST_M and RST_NM), is followed by the uPD765A's drive-poll interrupt at the first poll, within 1.024 ms (8192 clocks of the 8 MHz FDC) of the release and never before 100 us nor later than one more poll - not NP2kai's 6-frame (100 ms) workaround - with ST0 = AI|unit (0xC0|u) pending for each READY drive, drained one per SENSE INTERRUPT STATUS down to the one-byte 0x80, one interrupt per reset; a status pending for a drive that is not ready survives the reset and follows the AI; no interrupt while bit 7 is held set or for a motor-on write with no reset; and a poll that falls inside a command is deferred to the next one; a later control write with bit 7 clear (a repeated 0x18, 0x1C, 0x08) neither cancels nor restarts the poll, which still interrupts at the first poll after the release (MAME upd765.cpp reset_w acts only on a change of the RESET level, NP2kai never cancels int_timer), while a write re-asserting bit 7 stops it until the next release. The stimulus is the Windows 95 floppy driver's own reset (HSFLOP.PDR 4.00.950, NEC build): SENSE DRIVE STATUS reads RDY, DOR 0x98, ten 0x5F waits, DOR 0x18, then it sleeps until the interrupt. FAIL-FIRST: the base controller raised no interrupt after a reset (the Windows 95 Explorer hang), the 6-frame model raised none within the datasheet's window, and NP2kai's motor-bit condition raised none for the 0x90/0x10 reset.
//
// THE EXPECTED VALUES:
//   uPD765A datasheet, drive polling: after a reset every drive is taken as not ready; the
//     controller polls the ready lines every 1.024 ms at 8 MHz while idle in the command phase,
//     and a drive whose ready line differs gets ST0 = AI|unit with INT.
//   MAME upd765.cpp: end_reset (RESET released) `poll_timer->adjust(attotime::from_usec(100), 0,
//     attotime::from_usec(1024));` (so the earliest poll is 100 us after the release), and
//     run_drive_ready_polling `flopi[fid].st0 = ST0_ABRT | fid | (ready ? 0 : ST0_NR);` (ST0_ABRT =
//     0xc0), skipped `if(main_phase != PHASE_CMD || ... || command_pos)`; pc9801.cpp drives RESET
//     from 0x94 bit 7 (`m_fdc_2hd->reset_w(BIT(data, 7));`) of an `UPD765A(... 8'000'000 ...)`.
//   NP2kai io/fdc.c fdc_o94: `// FDCリセット後 1,024ms以内にINTがアクティブになる` ("INT within
//     1.024 ms after an FDC reset"); its `if(dat & 0x08){ // XXX: Workaround for OSASK` 6-frame delay
//     (FDC_INT_DELAY, "Delay 100ms") is a per-frame approximation and is what S1 rejects. Its motor
//     condition (`if(dat & 0x08)`) is what S2 rejects. The surviving status of a drive that is not
//     ready (int_stat = stat) is NP2kai's;
//     RECALIBRATE of an empty drive is SE|NR|u = 0x28|u (FDC_Recalibrate, `fdc.int_stat[fdc.us] |= FDCRLT_NR;`).
// The DUT runs at its default SYS_CLOCK_HZ = 50 MHz, so 1.024 ms is 51200 cycles.
//
// ==== DUT ====
module tb_pc9821_fdc_reset_int;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg cs = 0, wr = 0, rd = 0;
  reg [2:0] addr = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg        tick = 1'b0;
  reg  [3:0] present = 4'b0001;

  pc9821_fdc dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present(present), .writeprotect(4'b0000),
      .media_chg(4'b0000), .frame_tick(tick),
      .media_req(), .media_req_hdr(), .media_unit(),
      .media_c(), .media_h(), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(), .media_n(), .media_idx(),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(8'h00), .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(), .dma_drq(), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout(), .res_done(),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  integer fails = 0;
  integer i, n, t;

  // 1.024 ms at the DUT's 50 MHz (uPD765A: 8192 clocks of 8 MHz), and MAME's earliest poll.
  localparam integer POLL     = 51200;
  localparam integer EARLIEST = 5000;     // 100 us

  // A free-running cycle count, so S7 times the interrupt from the RELEASE and not from the
  // later control write.
  integer cyc = 0, t0;
  always @(posedge clk) cyc <= cyc + 1;

  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_FDC_RESET_INT: watchdog timeout (no verdict reached)");
  end

  // ==== CHECKS ====
  task automatic wr8(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  reg [7:0] rd_val;
  task automatic rd8(input [2:0] a);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      #1 rd_val = dout;
      @(negedge clk); cs = 0; rd = 0;
    end
  endtask

  task automatic check8(input [7:0] got, input [7:0] want, input [8*80-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  task automatic check_irq(input want, input [8*80-1:0] what);
    begin
      if (irq !== want) begin
        $display("  FAIL: %0s: irq=%b, expected %b", what, irq, want);
        fails = fails + 1;
      end
    end
  endtask

  reg [7:0] rs [0:7];
  integer   rlen;
  task automatic get_result;
    begin
      rlen = 0;
      for (i = 0; i < 8; i = i + 1) rs[i] = 8'hFF;
      rd8(3'd0);
      while (((rd_val & 8'h40) != 0) && (rlen < 8)) begin
        rd8(3'd1);
        rs[rlen] = rd_val;
        rlen = rlen + 1;
        rd8(3'd0);
      end
    end
  endtask

  task automatic sense_is(input [7:0] st0, input [8*64-1:0] what);
    begin
      wr8(3'd1, 8'h08);
      get_result;
      if (st0 == 8'h80) begin
        if (rlen !== 1) begin
          $display("  FAIL: %0s: SENSE INT length %0d, expected 1", what, rlen); fails = fails + 1;
        end
      end else if (rlen !== 2) begin
        $display("  FAIL: %0s: SENSE INT length %0d, expected 2", what, rlen); fails = fails + 1;
      end
      check8(rs[0], st0, {what, ": SENSE INT ST0"});
    end
  endtask

  task automatic frames(input integer k);
    begin
      for (n = 0; n < k; n = n + 1) begin
        @(negedge clk); tick = 1; @(negedge clk); tick = 0;
        repeat (3) @(negedge clk);
      end
    end
  endtask

  // Cycles from now until the line rises, up to `lim` (t = lim + 1 when it never does).
  task automatic time_irq(input integer lim);
    begin
      t = 0;
      while (!irq && (t <= lim)) begin @(negedge clk); t = t + 1; end
    end
  endtask

  // The line stays low for `k` cycles.
  task automatic quiet(input integer k, input [8*80-1:0] what);
    begin
      time_irq(k);
      if (t <= k) begin
        $display("  FAIL: %0s: irq rose after %0d cycles", what, t); fails = fails + 1;
      end
    end
  endtask

  // The line rises inside the datasheet's window after the release that just happened.
  task automatic in_window(input [8*80-1:0] what);
    begin
      time_irq(2 * POLL);
      if (t > 2 * POLL) begin
        $display("  FAIL: %0s: no interrupt within %0d cycles of the release", what, 2 * POLL);
        fails = fails + 1;
      end else if (t < EARLIEST) begin
        $display("  FAIL: %0s: interrupt after %0d cycles, before the first poll", what, t);
        fails = fails + 1;
      end else
        $display("  %0s: interrupt %0d cycles after the release", what, t);
    end
  endtask

  // HSFLOP's reset (0x30079F): SENSE DRIVE STATUS, DOR 0x98, ten 0x5F waits, DOR 0x18.
  // The release (0x18) is the last write; the caller times from there.
  task automatic hsflop_reset;
    begin
      wr8(3'd1, 8'h04); wr8(3'd1, 8'h00);
      get_result;
      check8(rs[0], 8'h38, "the driver's SENSE DRIVE STATUS reads RDY|TS|T0 (it then waits)");
      wr8(3'd2, 8'h98);
      repeat (10) @(negedge clk);
      wr8(3'd2, 8'h18);
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    repeat (4) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);

    // The driver's motor-on (0x3005A7): 0xBE |= 4, DOR 0x18. With 0xBE bit 2 set the motor bit's
    // rise announces the ready drive 0 (fdc_o94's other arm); the driver's ISR drains it.
    wr8(3'd2, 8'h10);
    wr8(3'd4, 8'h07);
    wr8(3'd2, 8'h18);
    repeat (3) @(negedge clk);
    sense_is(8'hC0, "S0 motor on announces the ready drive (AI|0)");
    sense_is(8'h80, "S0 nothing else pending");
    check_irq(1'b0, "S0 line low before the reset");

    // S1: the reset with the motor on: the interrupt at the first poll, about 1 ms after the
    // release, with no frame passing (the 6-frame model raises nothing here).
    hsflop_reset;
    in_window("S1 the reset's drive-poll interrupt");
    rd8(3'd0);
    check8(rd_val, 8'h80, "S1 MSR idle (RQM) when the interrupt arrives");
    sense_is(8'hC0, "S1 the ready drive 0 reports AI|0");
    sense_is(8'h80, "S1 then nothing");
    check_irq(1'b0, "S1 the line falls once the statuses drain");
    quiet(3 * POLL, "S1 one interrupt per reset (later polls)");
    frames(8);
    repeat (3) @(negedge clk);
    check_irq(1'b0, "S1 nothing 6 frames after the reset either");
    wr8(3'd1, 8'h03); wr8(3'd1, 8'hC1); wr8(3'd1, 8'h46);    // the driver's SPECIFY
    rd8(3'd0);
    check8(rd_val, 8'h80, "S1 SPECIFY accepted after the reset");

    // S2: a reset WITHOUT the motor bit (0x90 then 0x10) interrupts like one with it. THE
    // MACHINE: docs/probes/XE10T-XE10-FDC2A.TXT:65 (`RST_NM da=90 w=90/10 irr_pre=10
    // t_irq_art=329 rises=1 t_irq2_art=- sis=C000,80`, 1.07 ms, the same as RST_M's 330), drive
    // 2's -FDC2C.TXT row alike (334 ticks, C100). NP2kai's arm needs dat & 0x08; the capture
    // outranks it.
    wr8(3'd2, 8'h10);
    wr8(3'd2, 8'h90);
    wr8(3'd2, 8'h10);
    in_window("S2 a release written without the motor bit interrupts (RST_NM)");
    sense_is(8'hC0, "S2 the ready drive 0 reports AI|0 (RST_NM sis=C000)");
    sense_is(8'h80, "S2 then nothing (RST_NM sis=...,80)");
    check_irq(1'b0, "S2 the line falls once the statuses drain");
    quiet(3 * POLL, "S2 one interrupt per reset (RST_NM t_irq2_art=-)");

    // S3: bit 7 held set is a held reset: no poll runs until it falls. A motor-on with no
    // reset raises nothing (0xBE bit 2 clear: no ready announcement).
    wr8(3'd4, 8'h03);
    wr8(3'd2, 8'h98);
    wr8(3'd2, 8'h98);
    quiet(3 * POLL, "S3 no interrupt while the reset is held");
    wr8(3'd2, 8'h18);
    in_window("S3 the interrupt follows the release");
    sense_is(8'hC0, "S3 AI|0");
    sense_is(8'h80, "S3 then nothing");
    wr8(3'd2, 8'h10); wr8(3'd2, 8'h18);
    quiet(3 * POLL, "S3 a motor-on without a reset raises nothing");

    // S4: a status pending for drive 1 (empty, so not ready) survives the reset and follows
    // drive 0's AI.
    wr8(3'd1, 8'h07); wr8(3'd1, 8'h01);                  // RECALIBRATE drive 1
    time_irq(20000);
    check_irq(1'b1, "S4 RECALIBRATE of the empty drive 1 completes");
    wr8(3'd2, 8'h10);
    hsflop_reset;
    repeat (2 * POLL) @(negedge clk);
    check_irq(1'b1, "S4 interrupt after the reset");
    sense_is(8'hC0, "S4 the ready drive 0's AI first");
    sense_is(8'h29, "S4 drive 1's RECALIBRATE status survives (SE|NR|1)");
    sense_is(8'h80, "S4 then nothing");
    check_irq(1'b0, "S4 line low");

    // S5: a poll that falls inside a command is skipped; the next poll takes the change.
    wr8(3'd2, 8'h10);
    hsflop_reset;
    wr8(3'd1, 8'h03);                                     // SPECIFY, first byte only
    quiet(3 * POLL, "S5 no poll while a command is being written");
    wr8(3'd1, 8'hC1); wr8(3'd1, 8'h46);
    time_irq(POLL + 16);
    if (t > POLL + 16) begin
      $display("  FAIL: S5 no interrupt at the next poll after the command"); fails = fails + 1;
    end
    sense_is(8'hC0, "S5 AI|0");
    sense_is(8'h80, "S5 then nothing");

    // S6: both drives ready: one AI per drive.
    present = 4'b0011;
    wr8(3'd2, 8'h10);
    hsflop_reset;
    in_window("S6 the reset's interrupt with two ready drives");
    sense_is(8'hC0, "S6 AI|0");
    sense_is(8'hC1, "S6 AI|1");
    sense_is(8'h80, "S6 then nothing");
    check_irq(1'b0, "S6 line low");

    // S7: control-port writes AFTER the release do not cancel or restart the poll. Only the
    // chip's RESET pin is wired to the latch (pc9801.cpp `m_fdc_2hd->reset_w(BIT(data, 7));`),
    // and MAME upd765.cpp reset_w returns at once unless the level changes (`if(bool(state) ==
    // !BIT(dor, 2)) return;`), so a write with bit 7 clear after the release leaves the poll
    // timer end_reset started running; NP2kai fdc_o94 never cancels a loaded int_timer either.
    // The interrupt therefore comes at the FIRST poll after the release (within POLL of it),
    // not one interval after the later write, and not never.
    present = 4'b0001;
    wr8(3'd2, 8'h10);
    hsflop_reset;
    t0 = cyc;
    repeat (1000) @(negedge clk);                         // 20 us into the window
    wr8(3'd2, 8'h18);                                     // the same latch value again
    time_irq(2 * POLL);
    t = cyc - t0;
    if (!irq) begin
      $display("  FAIL: S7 a repeated 0x18 after the release cancelled the reset's interrupt");
      fails = fails + 1;
    end else if ((t < EARLIEST) || (t > POLL + 16)) begin
      $display("  FAIL: S7 interrupt %0d cycles after the release, expected the first poll (%0d..%0d)",
               t, EARLIEST, POLL + 16);
      fails = fails + 1;
    end else
      $display("  S7 interrupt %0d cycles after the release, a repeated 0x18 at +1000", t);
    sense_is(8'hC0, "S7 AI|0 after a repeated 0x18");
    sense_is(8'h80, "S7 then nothing");

    // S7b: a TMSK-bit write (0x1C) and then DMAE cleared (0x08) inside the window, the same rule.
    wr8(3'd2, 8'h10);
    hsflop_reset;
    t0 = cyc;
    repeat (1000) @(negedge clk);
    wr8(3'd2, 8'h1C);
    repeat (1000) @(negedge clk);
    wr8(3'd2, 8'h08);
    time_irq(2 * POLL);
    t = cyc - t0;
    if (!irq) begin
      $display("  FAIL: S7b writes 0x1C, 0x08 after the release cancelled the reset's interrupt");
      fails = fails + 1;
    end else if ((t < EARLIEST) || (t > POLL + 16)) begin
      $display("  FAIL: S7b interrupt %0d cycles after the release, expected the first poll (%0d..%0d)",
               t, EARLIEST, POLL + 16);
      fails = fails + 1;
    end
    sense_is(8'hC0, "S7b AI|0 after 0x1C, 0x08");
    sense_is(8'h80, "S7b then nothing");

    // S7c: a write that ASSERTS reset (bit 7) inside the window does stop it (MAME soft_reset
    // with the poll timer off until end_reset); the next release re-arms it.
    wr8(3'd2, 8'h18);
    hsflop_reset;
    repeat (1000) @(negedge clk);
    wr8(3'd2, 8'h98);
    quiet(3 * POLL, "S7c a re-asserted reset inside the window stops the poll");
    wr8(3'd2, 8'h18);
    in_window("S7c the next release re-arms it");
    sense_is(8'hC0, "S7c AI|0");
    sense_is(8'h80, "S7c then nothing");

  // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_FDC_RESET_INT: FAIL (%0d)", fails);
    $display("TB_PC9821_FDC_RESET_INT: PASS");
    $finish;
  end
endmodule
