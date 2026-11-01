`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Drives the real pc9821_pic with every 8259 register the machine can reach - ICW1-4, OCW1/OCW2/OCW3 - and checks each result against NP2kai io/pic.c, one named case per register semantics. OCW3 special mask mode (ESMM/SMM) and OCW2 priority rotation (R/SL/EOI) are implemented and asserted, so those cases pass. ICW1 keeping the in-service register is asserted against NP2kai's own contract (io/pic.c:326-337 leaves the isr clear disabled inside #if 0; FAIL-FIRST against the old clear). The four cases where NP2kai's model itself diverges from the datasheet (its RIS latches without RR, its ICW3 count ignores SNGL, its ICW4 ignores AEOI, its reset presets the IMR) print a WAIVED line instead of asserting NP2kai: three of them assert the RTL against QEMU hw/intc/i8259.c instead (RIS gated on RR, SNGL ending the sequence after ICW2, AEOI setting no ISR bit), and the reset IMR (RTL 0xFF; QEMU and MAME 0x00) is not asserted because the ITF programs the IMR before enabling interrupts. The vector takes ICW2 bits 7:3 only (pic.c `(icw[1] & 0xf8) | num`), asserted both tracked and at the acknowledge edge. AEOI is implemented in full against that datasheet/QEMU/ao486 answer: no ISR bit is set in AEOI mode and an OCW2 with R=1, SL=0, EOI=0 arms rotate-on-auto-EOI, so each acknowledge advances the priority pointer and the second of two pending levels is serviced (asserted). The in-service block is asserted to follow that rotation base too: with pry=3 an IRQ4 already in service blocks IRQ0 and permits IRQ3.

`default_nettype none

module tb_pc9821_pic_ref;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // Master ports: command 0x00, data 0x02. The block is driven directly so a
  // failure names the controller rather than the backbone around it.
  reg        cs = 0, wr = 0, rd = 0, a0 = 0;
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

  integer errors = 0, cases = 0, waivers = 0;

  // ==== STIMULUS ====

  // Each case names the RTL result and the NP2kai result; a difference is one
  // MISMATCH line, so the report can cite the case, not a line number.
  task automatic check(input [8*40-1:0] name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%02x np2kai=0x%02x", name, got[7:0], want[7:0]);
        errors = errors + 1;
      end
      else $display("ok       %0s = 0x%02x", name, got[7:0]);
    end
  endtask

  // A case where NP2kai's own model diverges from the datasheet/QEMU and this RTL
  // deliberately follows the hardware: PRINT the RTL/NP2kai bytes and count a waiver,
  // do not assert either. The report owns the divergence.
  task automatic waive(input [8*40-1:0] name, input [15:0] rtl, input [15:0] np2);
    begin
      cases = cases + 1;
      waivers = waivers + 1;
      $display("WAIVED   %0s: rtl=0x%02x np2kai=0x%02x (RTL follows the datasheet/QEMU)",
               name, rtl[7:0], np2[7:0]);
    end
  endtask

  // A waiver that still ASSERTS the RTL: NP2kai is waived, but the answer the RTL claims
  // to follow (QEMU hw/intc/i8259.c, the datasheet's behaviour) is checked, so a waived
  // case cannot hide a regression of the very behaviour the waiver credits.
  task automatic waive_qemu(input [8*40-1:0] name, input [15:0] rtl, input [15:0] np2,
                            input [15:0] qemu);
    begin
      waive(name, rtl, np2);
      if (rtl[7:0] !== qemu[7:0]) begin
        $display("MISMATCH %0s: rtl=0x%02x qemu=0x%02x (the answer the waiver credits)",
                 name, rtl[7:0], qemu[7:0]);
        errors = errors + 1;
      end
    end
  endtask

  task automatic reset_pic;
    begin
      rst_n = 0; ir_in = 0; inta = 0;
      repeat (3) @(negedge clk);
      rst_n = 1;
      repeat (2) @(negedge clk);
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

  task automatic read_cmd(output [7:0] v);
    begin
      @(negedge clk); cs = 1; rd = 1; wr = 0; a0 = 0;
      @(negedge clk); cs = 0; rd = 0; v = dout;
    end
  endtask

  task automatic read_dat(output [7:0] v);
    begin
      @(negedge clk); cs = 1; rd = 1; wr = 0; a0 = 1;
      @(negedge clk); cs = 0; rd = 0; v = dout;
    end
  endtask

  // One acknowledge: the single-cycle pulse the bridge produces on the 2nd INTA.
  task automatic ack;
    begin
      @(negedge clk); inta = 1;
      @(negedge clk); inta = 0;
      repeat (6) @(negedge clk);
    end
  endtask

  // The ITF's own init (BANK4@0x4BA5): ICW1=0x11, ICW2=0x08, ICW3=0x80, ICW4=0x1D.
  task automatic init_itf(input [7:0] mask);
    begin
      write_cmd(8'h11); write_dat(8'h08); write_dat(8'h80);
      write_dat(8'h1D); write_dat(mask);
    end
  endtask

  reg [7:0] rv;

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // ---- 1. ICW1..ICW4 + OCW1: the IMR reads back ----
    reset_pic();
    init_itf(8'h7D);
    read_dat(rv);
    check("icw_imr_roundtrip", rv, 8'h7D);

    // ---- 2. an unmasked request publishes ICW2 | IRQ (pic_irq: icw[1]&0xf8 | num) ----
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h02;                      // IRQ1, keyboard
    repeat (6) @(negedge clk);
    check("vec_base_plus_irq", int_vec, 8'h09);
    ack();

    // ---- 3. OCW3 RR=1 RIS=0 selects the IRR; RR=1 RIS=1 the ISR ----
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h10;                      // IRQ4
    repeat (6) @(negedge clk);
    write_cmd(8'h0A);
    read_cmd(rv);
    check("ocw3_rr_reads_irr", rv, 8'h10);
    ack();
    write_cmd(8'h0B);
    read_cmd(rv);
    check("ocw3_rr_ris_reads_isr", rv, 8'h10);

    // ---- 4. the OCW2 EOIs ----
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h04;                      // IRQ2
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'h0B); read_cmd(rv);
    check("eoi_precondition_isr", rv, 8'h04);
    write_cmd(8'h20);                   // non-specific EOI
    write_cmd(8'h0B); read_cmd(rv);
    check("ocw2_non_specific_eoi", rv, 8'h00);

    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h04;
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'h62);                   // specific EOI, level 2 (SL=1, EOI=1)
    write_cmd(8'h0B); read_cmd(rv);
    check("ocw2_specific_eoi", rv, 8'h00);

    // ---- 5. OCW3 special mask mode is not implemented ----
    // pic.c:163 `if (!(p->pi[0].ocw3 & PIC_OCW3_SMM)) mir |= isr;` - with SMM on
    // the in-service register no longer blocks, so a LOWER-priority request is
    // forwarded once the in-service line is masked (pic.c:159-166). RTL: no SMM
    // bit and isr_block always applies, so the request is dropped.
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h04;                      // IRQ2 in service
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'h68);                   // OCW3 ESMM=1, SMM=1
    write_dat(8'h04);                   // mask IRQ2 while it is in service
    ir_in = 8'h14;                      // IRQ4 (lower priority) rises
    repeat (8) @(negedge clk);
    check("smm_lower_priority_forwarded", {15'b0, int_out}, 16'h0001);
    check("smm_lower_priority_vector", int_vec, 8'h0C);

    // ---- 6. ESMM=0 preserves the SMM already set (pic.c:319-322) ----
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h04;
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'h68);                   // SMM on
    write_dat(8'h04);
    write_cmd(8'h08);                   // ESMM=0, SMM=0: SMM must persist
    ir_in = 8'h14;
    repeat (8) @(negedge clk);
    check("smm_esmm_preserved", {15'b0, int_out}, 16'h0001);

    // ---- 7. OCW2 rotate: Set Priority (0xC0|level) ----
    // pic.c:303-305 `if (dat & PIC_OCW2_R) picp->pry = (level + 1) & 7;`. The scan in
    // pic_irq starts at pry (pic.c:156), so with pry=3 IRQ3 outranks IRQ0. RTL ignores
    // OCW2 D7, so it always answers the lowest-numbered line.
    reset_pic();
    init_itf(8'h00);
    write_cmd(8'hC2);                   // R=1, SL=1, level 2 -> pry = 3, no EOI
    ir_in = 8'h09;                      // IRQ0 and IRQ3 both pending
    repeat (6) @(negedge clk);
    check("ocw2_rotate_set_priority", int_vec, 8'h0B);

    // ---- 8. OCW2 rotate-on-non-specific-EOI (0xA0) ----
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h04;
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'hA0);                   // R=1, SL=0, EOI=1 -> clear IRQ2, pry = 3
    ir_in = 8'h09;
    repeat (6) @(negedge clk);
    check("ocw2_rotate_on_eoi", int_vec, 8'h0B);

    // ---- 9. OCW2 rotate-on-specific-EOI (0xE0|level) ----
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h04;
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'hE2);                   // R=1, SL=1, EOI=1, level 2 -> pry = 3
    ir_in = 8'h09;
    repeat (6) @(negedge clk);
    check("ocw2_specific_eoi_rotate", int_vec, 8'h0B);

    // ---- 9b. the in-service block follows the OCW2 rotation base ----
    // The priority order is pry, pry+1, ... wrapping, so with pry=3 a request in
    // service at IRQ4 blocks IRQ0 (lower) and does NOT block IRQ3 (higher). The
    // RTL's cumulative isr_block mask takes natural IRQ order, where IRQ0 always
    // outranks IRQ4: it forwards IRQ0, so the first check fails before the mask is
    // computed relative to pry. QEMU hw/intc/i8259.c:80-105 compares against the
    // priority computed from isr relative to s->priority_add; NP2kai io/pic.c:156-166
    // scans the request latch from pry as well.
    reset_pic();
    init_itf(8'h00);
    write_cmd(8'hC2);                   // OCW2 R=1, SL=1, level 2 -> pry = 3, no EOI
    ir_in = 8'h10;                      // IRQ4: the highest priority at pry = 3
    repeat (6) @(negedge clk);
    check("rot_precondition_vec", int_vec, 8'h0C);
    ack();                              // IRQ4 goes in service
    write_cmd(8'h0B); read_cmd(rv);
    check("rot_precondition_isr", rv, 8'h10);
    ir_in = 8'h11;                      // IRQ4 held, IRQ0 rises: LOWER than IRQ4
    repeat (8) @(negedge clk);
    check("rot_isr_blocks_lower", {15'b0, int_out}, 16'h0000);
    ir_in = 8'h19;                      // IRQ4 held, IRQ3 rises: HIGHER than IRQ4
    repeat (8) @(negedge clk);
    check("rot_isr_permits_higher", {15'b0, int_out}, 16'h0001);
    check("rot_isr_permits_higher_vec", int_vec, 8'h0B);

    // ---- 10. NP2kai reset presets the IMR (def_master imr=0x7d, pic.c:45) ----
    // The 8259's IMR is undefined at reset; NP2kai starts at the ITF's own value. The
    // RTL's all-masked 0xFF is a safety choice that NO reference makes: QEMU's
    // pic_reset_common sets `s->imr = 0` (hw/intc/i8259_common.c:40) and MAME's
    // device_reset `m_imr = 0` (pic8259.cpp:437). Not asserted: the ITF writes the IMR
    // before it enables interrupts, so the reset value is not guest-observable.
    reset_pic();
    read_dat(rv);
    waive("reset_imr", rv, 8'h7D);

    // ---- 11. ICW1 does NOT clear the ISR (NP2kai io/pic.c:326-337 `#if 0`) ----
    // NP2kai's pic_o00 clears imr/irr/ocw3/pry on ICW1 but deliberately leaves
    // `picp->isr = 0` disabled inside `#if 0` (io/pic.c:331-334): a guest that
    // re-inits while an interrupt is in service keeps the in-service bit. QEMU
    // clears it (pic_reset_common) but the 8259A datasheet's ICW1 reset list
    // does not name the ISR, and NP2kai is the primary software reference.
    // FAIL-FIRST: the old RTL answered 0x00 here (this
    // case was a WAIVE); the contract is the stale 0x04.
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h04;
    repeat (6) @(negedge clk);
    ack();                              // IRQ2 in service, no EOI
    write_cmd(8'h11);                   // re-init mid-service
    write_cmd(8'h0B); read_cmd(rv);     // OCW3 RR=1 RIS=1: read the ISR
    check("icw1_keeps_isr", rv, 8'h04);

    // ---- 12. NP2kai latches RIS without RR (pic.c:315-318), pic_i00 checks only RIS (pic.c:378) ----
    reset_pic();
    init_itf(8'h00);
    ir_in = 8'h02;
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'h09);                   // RR=0, RIS=1
    read_cmd(rv);
    waive("ocw3_ris_without_rr", rv, 8'h02);
    // The waiver above prints NP2kai's answer; the RTL's own (datasheet) answer is
    // ASSERTED here, or a RIS applied without RR would pass as "waived". QEMU
    // hw/intc/i8259.c:249-250 (`if (val & 0x02) s->read_reg_select = val & 1;`) and
    // MAME pic8259.cpp:266-267 (`if (BIT(data, 1)) m_ocw3 = ...`) both gate RIS on RR,
    // so the read register stays the IRR, which the acknowledge has cleared.
    check("ocw3_ris_without_rr_keeps_irr", rv, 8'h00);
    // The other side of the same gate, where all three references agree (NP2kai's
    // pic.c:315-318 ORs the OLD RIS back in): with the ISR selected, an OCW3 with RR=0
    // and RIS=0 leaves the ISR selected.
    write_cmd(8'h0B);                   // RR=1, RIS=1: select the ISR
    write_cmd(8'h08);                   // RR=0, RIS=0: no read-register change
    read_cmd(rv);
    check("ocw3_rr0_keeps_isr_selected", rv, 8'h02);

    // ---- 12b. the vector takes ICW2's T7-T3 only (pic.c:206 `(icw[1] & 0xf8) | num`) ----
    // Every other case programs the ITF's aligned 0x08, where the AND is invisible.
    reset_pic();
    write_cmd(8'h11); write_dat(8'h0D); write_dat(8'h80);
    write_dat(8'h1D); write_dat(8'h00);
    ir_in = 8'h02;                      // IRQ1
    repeat (6) @(negedge clk);
    check("vec_icw2_low_bits_ignored", int_vec, 8'h09);
    // The acknowledge edge LATCHES its own copy of the vector (the one the bridge reads
    // back), held only while INT is held low after the INTA; sample it there.
    @(negedge clk); inta = 1;
    @(negedge clk); inta = 0;
    check("vec_icw2_low_bits_ignored_at_ack", int_vec, 8'h09);
    repeat (6) @(negedge clk);

    // ---- 13. NP2kai stores ICW4 but never reads AEOI (pic.c:336/363) ----
    // Which reference governs AEOI: this RTL follows the DATASHEET (and qemu/ao486, which
    // model it); NP2kai has no AEOI at all, so it sets the ISR even with AEOI=1 and reads
    // back 0x02 where the RTL reads 0x00. The divergence is only in that one register read;
    // the RTL's AEOI behaviour is asserted by case 13b instead.
    reset_pic();
    write_cmd(8'h11); write_dat(8'h08); write_dat(8'h80);
    write_dat(8'h0B);                   // ICW4: AEOI=1
    write_dat(8'h00);                   // IMR
    ir_in = 8'h02;
    repeat (6) @(negedge clk);
    ack();
    write_cmd(8'h0B); read_cmd(rv);
    // QEMU i8259.c:159 `if (s->auto_eoi)` acknowledges without setting the ISR bit.
    waive_qemu("icw4_aeoi", rv, 8'h02, 8'h00);

    // ---- 13b. AEOI's rotate-on-auto-EOI, from ao486 rtl/soc/pic/pic.v ----
    // NP2kai does not implement AEOI, so the datasheet/QEMU/ao486 answer governs: OCW2 with
    // R=1, SL=0, EOI=0 arms `rotate_on_aeoi`, and each not-spurious acknowledge advances the
    // priority pointer one step. Program AEOI + rotate, ack IRQ0 (the ack rotates the pointer
    // to IRQ1), then raise IRQ0 again and IRQ1: with the rotation IRQ1 is serviced, without it
    // IRQ0 is. Fails before the rotate-on-AEOI arm exists and passes after.
    reset_pic();
    write_cmd(8'h11); write_dat(8'h08); write_dat(8'h80);
    write_dat(8'h0B);                   // ICW4: AEOI=1
    write_dat(8'h00);                   // IMR
    write_cmd(8'h80);                   // OCW2 R=1, SL=0, EOI=0 -> arm rotate_on_aeoi
    ir_in = 8'h01;                      // IRQ0, the highest priority at pry=0
    repeat (6) @(negedge clk);
    check("aeoi_first_service", int_vec, 8'h08);
    ack();
    ir_in = 8'h00;                      // withdraw IRQ0 so it needs a fresh edge...
    repeat (4) @(negedge clk);
    ir_in = 8'h03;                      // ...then IRQ0 and IRQ1 both pending
    repeat (8) @(negedge clk);
    check("aeoi_rotate_second_service", int_vec, 8'h09);

    // ---- 13c. AEOI rotation advances from the ACKED IRQ, not the old base ----
    // The bug: the rotate-on-AEOI arm incremented `pry`, so a lone IRQ3
    // acked at pry=0 moved the pointer to IRQ1's base instead of making IRQ3 lowest and IRQ4
    // highest (QEMU pic_intack: `priority_add = (irq + 1) & 7`). Case 13b cannot see it because
    // acking IRQ0 at pry=0 makes `pry+1` and `highest+1` the same. Fail-first: with the pointer
    // wrongly at IRQ1 the later IRQ0/IRQ1/IRQ4 set services IRQ1 (vec 0x09); with the pointer at
    // IRQ4 it services IRQ4 (vec 0x0C).
    reset_pic();
    write_cmd(8'h11); write_dat(8'h08); write_dat(8'h80);
    write_dat(8'h0B);                   // ICW4: AEOI=1
    write_dat(8'h00);                   // IMR
    write_cmd(8'h80);                   // OCW2 R=1, SL=0, EOI=0 -> arm rotate_on_aeoi
    ir_in = 8'h08;                      // IRQ3 ONLY, at pry=0: the base is not the acked line
    repeat (6) @(negedge clk);
    check("aeoi_lone_irq3_service", int_vec, 8'h0B);
    ack();                              // ack IRQ3 -> the pointer must advance from IRQ3
    ir_in = 8'h00;                      // withdraw IRQ3 so it needs a fresh edge
    repeat (4) @(negedge clk);
    ir_in = 8'h11;                      // IRQ0 and IRQ4: IRQ4 must outrank IRQ0 (pry=4)
    repeat (8) @(negedge clk);
    check("aeoi_rotate_irq4_over_irq0", int_vec, 8'h0C);
    ir_in = 8'h00;                      // withdraw, then raise IRQ0, IRQ1 and IRQ4
    repeat (4) @(negedge clk);
    ir_in = 8'h13;                      // pre-fix (pry=1) IRQ1 wins; post-fix (pry=4) IRQ4 wins
    repeat (8) @(negedge clk);
    check("aeoi_rotate_from_acked_irq", int_vec, 8'h0C);

    // ---- 14. NP2kai's ICW3 count ignores SNGL (pic.c:365) ----
    // ICW1=0x12 (SNGL=1, IC4=0) needs only ICW2; NP2kai expects 3 data writes, so
    // the byte the guest writes as the IMR lands in icw[2] and the IMR stays 0.
    reset_pic();
    write_cmd(8'h12); write_dat(8'h08); write_dat(8'h7F);
    read_dat(rv);
    // QEMU i8259.c:303 `s->init_state = s->single_mode ? (s->init4 ? 3 : 0) : 2;` ends
    // the sequence after ICW2, so the third write is the IMR.
    waive_qemu("icw1_sngl_sequence", rv, 8'h00, 8'h7F);

    // ==== VERDICT ====
    $display("NOTE pic_ref: %0d cases, %0d mismatched, %0d waived", cases, errors, waivers);
    if (errors == 0) begin
      $display("TB_PC9821_PIC_REF: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIC_REF: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PIC_REF: TIMEOUT");
  end

endmodule

`default_nettype wire
