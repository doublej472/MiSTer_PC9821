`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDC_READY_CHANGE: a floppy media change raises NP2kai's ready-change interrupt (fdd/diskdrv.c): every mount event of an equipped drive - an eject, an insert, an eject of an empty drive - leaves ST0 = AI|NR|drv (0xC8|u) for SENSE INTERRUPT STATUS and raises the interrupt at once, ungated; an insert keeps the drive NOT READY (ST3 RDY clear, a READ DATA answering the IC0|NR class in its own seven-byte result with the interrupt, SENSE INTERRUPT STATUS then empty, the real Xe10's not-ready shape) for DISK_DELAY = 20 guest frames and then, only when the 0xBE register's bit 2 is clear or the DOR's motor bit 0x08 is set, leaves ST0 = AI|drv (0xC0|u) and raises the interrupt again, with the drive READY, while a ready held back by that gate is announced (AI|drv) when the DOR's motor bit later rises with 0xBE bit 2 set (NP2kai io/fdc.c fdc_o94); a medium that parses after the delay is announced when it parses; and a mount event while the controller is held in reset raises nothing (fdc_reset zeroes fdc.stat). FAIL-FIRST: the base controller had no ready-change interrupt at all (no media_chg/frame_tick seam).
//
// THE EXPECTED VALUES ARE NP2kai's (commit 5939e0c6):
//   eject/insert:  diskdrv_setfddex, fdd/diskdrv.c:256-284 -
//                  `fdc.stat[drv] = FDCRLT_AI | FDCRLT_NR | drv; fdc.us = drv; fdc_interrupt();`
//                  then `diskdrv_delay[drv] = DISK_DELAY;` (DISK_DELAY = 20, :15) for an insert;
//   the delay:     diskdrv_callback, :290-306, called once per emulated frame (pccore.c:2016);
//   ready:         diskdrv_readyfddex, :225-249 - fdd_set, then
//                  `if ((!(fdc.chgreg & 4)) || (fdc.ctrlreg & 0x08)) { fdc.stat[drv] = FDCRLT_AI | drv; ... fdc_interrupt(); }`
//   READY between: fdd_diskready is `fname[0] != 0` (diskimage/fddfile.c:639-645), and fdd_eject
//                  has cleared it, so FDC_SenseDeviceStatus's RDY (io/fdc.c:367) is clear;
//   SENSE INT:     FDC_SenceintStatus, io/fdc.c:657-701 - {stat, treg}, or the single IC1 0x80;
//   the codes:     FDCRLT_NR = 0x08, FDCRLT_AI = 0xC0 (io/fdc.h).
// NP2kai prefers stat[fdc.us] over the lowest pending drive in SENSE INTERRUPT STATUS; every
// case here has ONE drive pending, so the two orders agree (the divergence is in the report).
//
// The medium is modelled at the seam: `present` is what pc9821_fdd_media's parse reports and
// `chg` is its per-drive change tag (one toggle per mount event).
//
// ==== DUT ====
module tb_pc9821_fdc_ready_change;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg cs = 0, wr = 0, rd = 0;
  reg [2:0] addr = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg  [1:0] present = 2'b00;
  reg  [1:0] chg = 2'b00;
  reg        tick = 1'b0;

  pc9821_fdc dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present({2'b00, present}), .writeprotect(4'b0000),
      .media_chg({2'b00, chg}), .frame_tick(tick),
      .media_req(), .media_req_hdr(), .media_unit(),
      .media_c(), .media_h(), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(), .media_n(), .media_idx(),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(8'h00), .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(), .dma_drq(), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout(), .res_done(),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  integer fails = 0;
  integer i, n;

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_FDC_READY_CHANGE: watchdog timeout (no verdict reached)");
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

  // The result phase, bounded: up to 8 bytes while MSR says DIO.
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

  // SENSE INTERRUPT STATUS against NP2kai's answer: {st0, PCN} or the one-byte IC1 0x80.
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
      if (st0 != 8'h80) check8(rs[1], 8'h00, {what, ": SENSE INT PCN (treg)"});
    end
  endtask

  // SENSE DRIVE STATUS: an equipped drive at treg 0 is TS|T0|us = 0x18|us, plus RDY 0x20.
  task automatic st3_is(input [1:0] u, input [7:0] want, input [8*64-1:0] what);
    begin
      wr8(3'd1, 8'h04); wr8(3'd1, {6'd0, u});
      get_result;
      check8(rs[0], want, {what, ": ST3"});
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

  // ==== STIMULUS ====
  initial begin
    // R0: a mount event while the controller is held (the power-on mount): nothing pending.
    repeat (4) @(negedge clk);
    chg[0] = ~chg[0]; present[0] = 1'b1;
    repeat (4) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);
    check_irq(1'b0, "R0 no interrupt for a mount made during reset");
    sense_is(8'h80, "R0 nothing pending after a reset-time mount");
    st3_is(2'd0, 8'h38, "R0 drive 0 READY at once (no insert delay across reset)");

    // R1: EJECT drive 0 at runtime: AI|NR|0 and the interrupt at once.
    @(negedge clk); chg[0] = ~chg[0]; present[0] = 1'b0;
    repeat (3) @(negedge clk);
    check_irq(1'b1, "R1 eject raises the interrupt");
    sense_is(8'hC8, "R1 eject: AI|NR|drv (diskdrv.c:264)");
    check_irq(1'b0, "R1 interrupt drops once the status is drained");
    sense_is(8'h80, "R1 nothing else pending");
    st3_is(2'd0, 8'h18, "R1 drive 0 not ready");

    // R2: INSERT into drive 1 (the parse is quick): AI|NR|1 at once, not ready for 20 frames,
    // then AI|1 (chgreg = 3 after reset, so bit 2 is clear and the gate is open).
    @(negedge clk); chg[1] = ~chg[1];
    repeat (20) @(negedge clk); present[1] = 1'b1;
    check_irq(1'b1, "R2 insert raises the interrupt");
    sense_is(8'hC9, "R2 insert: AI|NR|drv first (diskdrv.c:264)");
    st3_is(2'd1, 8'h19, "R2 drive 1 NOT ready during the insert delay");
    frames(19);
    check_irq(1'b0, "R2 no ready interrupt before the 20th frame");
    st3_is(2'd1, 8'h19, "R2 drive 1 still not ready after 19 frames");
    frames(1);
    repeat (3) @(negedge clk);
    check_irq(1'b1, "R2 the ready interrupt at the 20th frame");
    sense_is(8'hC1, "R2 ready: AI|drv (diskdrv.c:240)");
    check_irq(1'b0, "R2 interrupt drops once drained");
    st3_is(2'd1, 8'h39, "R2 drive 1 READY after the delay");

    // R3: the gate CLOSED - 0xBE bit 2 set and the DOR motor bit clear: the insert's AI|NR still
    // comes (no gate on that leg), the drive becomes ready after the delay, and NO ready AI.
    wr8(3'd4, 8'h07);                                   // chgreg = 7 (bits 0/1 kept: 2HD)
    @(negedge clk); chg[1] = ~chg[1]; present[1] = 1'b0;
    repeat (5) @(negedge clk); present[1] = 1'b1;
    sense_is(8'hC9, "R3 gated insert still reports AI|NR|drv");
    frames(20);
    repeat (3) @(negedge clk);
    check_irq(1'b0, "R3 no ready interrupt with chgreg bit 2 set and the motor off");
    sense_is(8'h80, "R3 nothing pending");
    st3_is(2'd1, 8'h39, "R3 drive 1 READY all the same (fdd_set runs ungated)");

    // R3b: the gated ready is DEFERRED, not lost: NP2kai fdc_o94 announces every ready drive
    // when the motor bit then rises with 0xBE bit 2 set - `if (fdc.chgreg & 4) { if ((fdc.ctrlreg
    // ^ dat) & 0x08) { if (dat & 0x08) { for (i...) if (fdd_diskready(i)) { fdc.int_stat[i] =
    // FDCRLT_AI | i; fdc.int_timer[i] = FDC_INT_DELAY; ...` (io/fdc.c).
    wr8(3'd2, 8'h08);
    repeat (3) @(negedge clk);
    check_irq(1'b1, "R3b the motor bit's rise announces the drive that became ready while gated");
    sense_is(8'hC1, "R3b motor on: AI|drv for the ready drive 1");
    wr8(3'd2, 8'h00);

    // R4: the gate OPENED by the motor bit (DOR 0x08: bit 4/bit 7 unchanged, no controller reset).
    wr8(3'd2, 8'h08);
    @(negedge clk); chg[0] = ~chg[0];
    repeat (5) @(negedge clk); present[0] = 1'b1;
    sense_is(8'hC8, "R4 insert drive 0: AI|NR|drv");
    frames(20);
    repeat (3) @(negedge clk);
    check_irq(1'b1, "R4 ready interrupt with the motor bit set");
    sense_is(8'hC0, "R4 ready: AI|drv");
    wr8(3'd4, 8'h03);                                   // back to the reset strap
    wr8(3'd2, 8'h00);

    // R5: EJECT AN EMPTY DRIVE: NP2kai's setfddex is unconditional for an equipped drive.
    @(negedge clk); chg[1] = ~chg[1]; present[1] = 1'b0;
    repeat (3) @(negedge clk);
    sense_is(8'hC9, "R5 drive 1 eject: AI|NR|drv");
    @(negedge clk); chg[1] = ~chg[1];                   // eject again: the drive is already empty
    repeat (3) @(negedge clk);
    check_irq(1'b1, "R5 eject of an empty drive still interrupts");
    sense_is(8'hC9, "R5 eject of an empty drive: AI|NR|drv");
    frames(25);
    repeat (3) @(negedge clk);
    check_irq(1'b0, "R5 an eject never raises the ready interrupt");
    sense_is(8'h80, "R5 nothing pending after the eject's delay");

    // R6: a medium that parses AFTER the delay is announced when it parses.
    @(negedge clk); chg[1] = ~chg[1];
    sense_is(8'hC9, "R6 insert: AI|NR|drv");
    frames(30);
    repeat (3) @(negedge clk);
    check_irq(1'b0, "R6 no ready interrupt while the medium has not parsed");
    st3_is(2'd1, 8'h19, "R6 not ready before the parse");
    present[1] = 1'b1;
    repeat (3) @(negedge clk);
    check_irq(1'b1, "R6 ready interrupt on the late parse");
    sense_is(8'hC1, "R6 late parse: AI|drv");

    // R7: a READ DATA during the insert delay answers the not-ready class (FDC_DriveCheck,
    // io/fdc.c:175-186: IC0|NR|hd<<2|us) in its own seven-byte result with the interrupt, and
    // SENSE INTERRUPT STATUS then has nothing: the shape of NP2kai's fdcsend_error7 and of the
    // real Xe10's not-ready READ DATA (docs/probes/XE10T-XE10-FDC2C.TXT:59, `NRRD da=90 ...
    // msr0=10 msr_end=D0 ... sis=80 dmacnt=03FF nres=7 st0=48`).
    @(negedge clk); chg[0] = ~chg[0];
    sense_is(8'hC8, "R7 insert drive 0: AI|NR|drv");
    wr8(3'd1, 8'h46);
    wr8(3'd1, 8'h00); wr8(3'd1, 8'h00); wr8(3'd1, 8'h00); wr8(3'd1, 8'h01);
    wr8(3'd1, 8'h03); wr8(3'd1, 8'h01); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
    n = 0;
    while (!irq && n < 20000) begin @(negedge clk); n = n + 1; end
    check_irq(1'b1, "R7 READ during the delay interrupts");
    get_result;
    if (rlen !== 7) begin
      $display("  FAIL: R7 READ during the delay: result length %0d, expected 7 (NRRD nres=7)", rlen);
      fails = fails + 1;
    end
    check8(rs[0], 8'h48, "R7 READ during the delay: ST0 IC0|NR|us (NRRD st0=48)");
    check8(rs[1], 8'h00, "R7 READ during the delay: ST1 (NRRD st1=00)");
    check_irq(1'b0, "R7 the line falls with the result");
    sense_is(8'h80, "R7 nothing left for SENSE INTERRUPT STATUS (NRRD sis=80)");
    frames(20);
    repeat (3) @(negedge clk);
    sense_is(8'hC0, "R7 ready after the delay");

  // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_FDC_READY_CHANGE: FAIL (%0d)", fails);
    $display("TB_PC9821_FDC_READY_CHANGE: PASS");
    $finish;
  end
endmodule
