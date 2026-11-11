`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIC_CMD:
// The 8259A's COMMAND and REQUEST-LATCH semantics, which the init-sequence bench does not reach: an ICW1 clears the mask and the latched requests but deliberately keeps the in-service register (NP2kai io/pic.c:326-337 leaves the isr clear disabled inside #if 0; FAIL-FIRST against the old clear); OCW3 selects whether a command-port read returns the IRR or the ISR and only when RR is set; a masked request is latched but not forwarded; a non-specific EOI clears the highest-priority in-service level and only that one; a specific EOI clears exactly the level it names; an unacknowledged request answers the ICW2|7 spurious vector; and after an acknowledge a still-held line does not re-request while a fresh rising edge does, which is the edge-triggered behaviour the authentic ITF selects.

// ==== where the expectation comes from ====
//
//  1. ICW1 clears imr and irr, and deliberately NOT the isr.
//     NP2kai io/pic.c:326-337  pic_o00's ICW1 arm clears imr/irr/ocw3/pry and
//           leaves `picp->isr = 0` disabled inside `#if 0` (io/pic.c:331-334):
//           a guest that re-inits while an interrupt is in service keeps the
//           in-service bit.
//     QEMU  hw/intc/i8259.c  pic_reset_common also clears the isr - QEMU
//           disagrees here, but NP2kai is the primary software reference and
//           the 8259A datasheet's ICW1 reset list does not name the ISR.
//     A guest that reads a stale mask and writes it back is how a boot ends up
//     with a mask nobody intended, so the IMR clear stays.
//
//  2. OCW3 read select: RR (D1) enables the read-register command and RIS (D0)
//     then picks the ISR (1) or the IRR (0).
//     QEMU  hw/intc/i8259.c:250  "s->read_reg_select = val & 1;" -- reached only
//           inside the `val & 2` arm, so RIS with RR clear changes nothing.
//     NP2kai io/pic.c  pic_o00: it folds the stored RIS into the reply only when
//           the stored RR bit is set.
//
//  3. A masked request is latched but not forwarded. This is the 8259A's
//     edge-triggered IRR semantics (the request flip-flop is set on the rising
//     edge and cleared only by INTA/ICW1; QEMU's i8259 and NP2kai both model
//     it). The in-repo machine evidence for the latch PERSISTING is
//     docs/probes/VSYNC.TXT's in-service hold (`VC hold ... post_eoi=1`: three
//     VSYNC edges arrived while IRQ2 was in service and one was delivered at the
//     EOI). NOTE: an earlier revision of this comment cited docs/probes/VRAM.TXT
//     for `IRR = 0x03 with IMR = 0xFF`, but VRAM.TXT (and VRAM2.TXT) contain no
//     PIC read at all - their port snapshot starts at 0x20. The only direct PIC
//     reads in-repo are docs/probes/PROBE.TXT:16 and T.TXT:16, both `7d 00 00`,
//     which are consistent with a TIMER-specific clear (BOOT14)
//     and do not by themselves prove the general latch.
//
//  4. Non-specific EOI clears the HIGHEST-PRIORITY in-service level, and only one.
//     QEMU hw/intc/i8259.c:97 get_priority() is the rule; IRQ0 is the highest
//     priority and IRQ7 the lowest on a fixed-priority 8259A.
//
//  5. Specific EOI clears exactly the level named in OCW2 D2:D0.
//
//  6. A spurious (nothing pending) acknowledge answers ICW2 | 7.
//     QEMU hw/intc/i8259.c:197-199 -- the spurious-IRQ arm:
//         "/* spurious IRQ on host controller */ irq = 7; intno = s->irq_base + irq;"
//     and irq_base is the ICW2 value masked to 0xf8, so the answer is ICW2 | 7.
//
//  7. EDGE-triggered request latch. The authentic ITF programs ICW1 = 0x11
//     (bios/xe10/BANK4.BIN @ 0x4BA5), whose D3 is LTIM: 0 selects edge. So a line
//     held high across an acknowledge must NOT re-request, while a fresh rising
//     edge must. This is the behaviour the machine asks for, not a choice of ours.

`default_nettype none

module tb_pc9821_pic_cmd;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // The master's own ports: command 0x00, data 0x02. The block is driven
  // directly rather than through pc9821_interrupts so that a failure here names
  // this controller and not the backbone around it.
  reg        cs = 0, wr = 0, rd = 0;
  reg        a0 = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  reg  [7:0] ir_in = 0;
  wire       int_out;
  wire [7:0] int_vec;
  wire [2:0] int_irq;
  reg        inta = 0;
  wire [7:0] dbg_imr, dbg_irr, dbg_isr;

  // ==== DUT ====
  pc9821_pic #(.BASE_VEC(8'h08), .CASCADE_IRQ(7)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .wr(wr), .rd(rd), .a0(a0),
      .din(din), .dout(dout), .ir_in(ir_in), .int_out(int_out),
      .int_vec(int_vec), .int_irq(int_irq), .inta(inta),
      .dbg_imr(dbg_imr), .dbg_irr(dbg_irr), .dbg_isr(dbg_isr)
  );

  integer errors = 0;

  // ==== CHECKS ====

  task automatic check(input bit ok, input [1023:0] what);
    begin
      if (!ok) begin
        errors = errors + 1;
        $display("FAIL pic_cmd: %0s", what);
      end
    end
  endtask

  task automatic write_cmd(input [7:0] v);
    begin
      @(negedge clk); cs = 1; wr = 1; rd = 0; a0 = 0; din = v;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  task automatic write_dat(input [7:0] v);
    begin
      @(negedge clk); cs = 1; wr = 1; rd = 0; a0 = 1; din = v;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  // A command-port read returns whichever register OCW3 selected.
  task automatic read_cmd(output [7:0] v);
    begin
      @(negedge clk); cs = 1; rd = 1; wr = 0; a0 = 0;
      @(negedge clk); cs = 0; rd = 0;
      v = dout;
    end
  endtask

  // One acknowledge: a single-cycle pulse, which is what the bridge produces.
  task automatic ack;
    begin
      @(negedge clk); inta = 1;
      @(negedge clk); inta = 0;
    end
  endtask

  // The ITF's own init: ICW1=0x11, ICW2=0x08, ICW3=0x80, ICW4=0x1D, then the IMR.
  task automatic init_itf(input [7:0] mask);
    begin
      write_cmd(8'h11);
      write_dat(8'h08);
      write_dat(8'h80);
      write_dat(8'h1D);
      write_dat(mask);
    end
  endtask

  reg [7:0] rv;
  integer   i;

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // ---- 1. ICW1 clears the mask and the latched requests, NOT the ISR ------
    init_itf(8'h00);                       // everything unmasked
    ir_in = 8'h02;                         // IRQ1 (keyboard) rising edge
    repeat (4) @(negedge clk);
    ack();                                 // now in service, latch cleared
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h02, "IRQ1 was not put in service by the acknowledge");
    check(dbg_imr == 8'h00, "the IMR is not what ICW2..IMR left it as");

    ir_in = 8'h00;
    repeat (4) @(negedge clk);
    write_cmd(8'h11);                      // re-init: imr/irr clear, the isr STAYS
    repeat (2) @(negedge clk);
    // FAIL-FIRST: NP2kai's ICW1 leaves `picp->isr = 0` inside `#if 0`
    // (io/pic.c:331-334), so the in-service bit survives a re-init; the old
    // RTL cleared it and answered 0x00 here.
    check(dbg_isr == 8'h02,
          "ICW1 cleared the in-service register: NP2kai keeps it (io/pic.c:331-334)");
    check(dbg_imr == 8'h00, "ICW1 cleared the IMR to something other than 0");
    check(int_out == 1'b0,  "ICW1 left INT asserted");
    write_cmd(8'h20);                      // EOI the surviving in-service IRQ1
    repeat (2) @(negedge clk);
    check(dbg_isr == 8'h00,
          "a non-specific EOI did not clear the ICW1-surviving ISR bit");

    // ---- 2. OCW3 selects IRR vs ISR, and only when RR is set ---------------
    init_itf(8'h00);
    ir_in = 8'h10;                         // IRQ4 rising edge
    repeat (4) @(negedge clk);
    write_cmd(8'h0A);                      // RR=1, RIS=0 -> read the IRR
    read_cmd(rv);
    check(rv == 8'h10, "OCW3 RR=1 RIS=0 did not select the IRR");

    ack();
    repeat (4) @(negedge clk);
    write_cmd(8'h0B);                      // RR=1, RIS=1 -> read the ISR
    read_cmd(rv);
    check(rv == 8'h10, "OCW3 RR=1 RIS=1 did not select the ISR");

    // RIS alone must change nothing: the earlier RR=1 RIS=1 selection stands.
    write_cmd(8'h08);                      // RR=0, RIS=1
    read_cmd(rv);
    check(rv == 8'h10, "OCW3 RIS without RR changed the selected register");

    // ---- 3. a masked request is latched but not forwarded ------------------
    ir_in = 8'h00;
    repeat (4) @(negedge clk);
    write_cmd(8'h20);                      // non-specific EOI: back to idle
    repeat (4) @(negedge clk);
    init_itf(8'hFF);                       // mask everything
    ir_in = 8'h04;                         // IRQ2 rising edge, masked
    repeat (6) @(negedge clk);
    check(dbg_irr == 8'h04, "a masked request was not latched into the IRR");
    check(int_out == 1'b0,  "a masked request asserted INT");

    // ---- 4. non-specific EOI clears the highest-priority level, one only ---
    ir_in = 8'h00;
    write_cmd(8'h11);
    repeat (2) @(negedge clk);
    init_itf(8'h00);
    ir_in = 8'h04;                         // IRQ2
    repeat (4) @(negedge clk);
    ack();
    repeat (4) @(negedge clk);
    ir_in = 8'h00;
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h04, "IRQ2 did not enter service");

    ir_in = 8'h01;                         // IRQ0, higher priority
    repeat (4) @(negedge clk);
    ack();
    repeat (4) @(negedge clk);
    ir_in = 8'h00;
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h05, "IRQ0 and IRQ2 are not both in service");

    write_cmd(8'h20);                      // non-specific EOI
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h04,
          "a non-specific EOI did not clear exactly the highest-priority level");

    // ---- 5. specific EOI clears exactly the level it names -----------------
    write_cmd(8'h62);                      // SL=1, EOI=1, level 2 (IRQ2): 0x62 = 0110_0010
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h00, "specific EOI level 2 did not clear IRQ2");

    // A specific EOI of a level that is NOT in service must clear nothing.
    ir_in = 8'h04;
    repeat (4) @(negedge clk);
    ack();
    repeat (4) @(negedge clk);
    ir_in = 8'h00;
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h04, "IRQ2 did not re-enter service on a fresh edge");
    write_cmd(8'h67);                      // specific EOI level 7, not in service
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h04, "specific EOI cleared a level that was not in service");
    write_cmd(8'h62);
    repeat (4) @(negedge clk);

    // ---- 6. spurious acknowledge answers ICW2 | 7 --------------------------
    ir_in = 8'h00;
    write_cmd(8'h11);
    repeat (2) @(negedge clk);
    init_itf(8'h00);
    repeat (4) @(negedge clk);
    check(int_out == 1'b0, "INT is asserted with nothing pending");
    check(int_vec == (8'h08 | 8'h07),
          "the spurious vector is not ICW2 | 7");
    ack();                                 // a spurious ack must not set an ISR bit
    repeat (4) @(negedge clk);
    check(dbg_isr == 8'h00, "a spurious acknowledge set an in-service bit");

    // ---- 7. edge-triggered: a held level does not re-request ---------------
    ir_in = 8'h08;                         // IRQ3 rises and STAYS high
    repeat (4) @(negedge clk);
    check(int_out == 1'b1, "IRQ3 did not assert INT");
    ack();
    repeat (8) @(negedge clk);
    check(dbg_isr == 8'h08, "IRQ3 did not enter service");
    write_cmd(8'h20);                      // EOI, but the line is still high
    repeat (8) @(negedge clk);
    check(int_out == 1'b0,
          "a still-held line re-requested after its acknowledge: this is level-triggered behaviour, and the ITF selects edge (ICW1 0x11 at BANK4@0x4BA5)");

    // A fresh rising edge on the SAME line must request again.
    ir_in = 8'h00;
    repeat (4) @(negedge clk);
    ir_in = 8'h08;
    repeat (4) @(negedge clk);
    check(int_out == 1'b1, "a fresh rising edge did not re-request");

    // ---- every line's vector, so the ICW2 base is pinned both ways ---------
    ir_in = 8'h00;
    write_cmd(8'h11);
    repeat (2) @(negedge clk);
    init_itf(8'h00);
    for (i = 0; i < 7; i = i + 1) begin
      ir_in = 8'h01 << i;
      repeat (4) @(negedge clk);
      check(int_vec == (8'h08 | i[7:0]),
            "a single pending line did not publish ICW2 | IRQ");
      ir_in = 8'h00;
      repeat (4) @(negedge clk);
      ack();
      repeat (2) @(negedge clk);
      write_cmd(8'h20);
      repeat (4) @(negedge clk);
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PIC_CMD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIC_CMD: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time (BENCH_TIMEOUT) and
  // greps the PASS marker, but a bench that blocks on a DUT signal with no bound
  // would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PIC_CMD: FAIL (watchdog)");
  end

endmodule

`default_nettype wire
