// tb_pc9821_pic - focused 8259 interrupt controller checks.
//
// Verifies the pc9821_pic module in isolation: reset masking, the ICW1/ICW2
// programming sequence, edge-triggered request latching (including the
// no-re-latch-after-INTA and falling-edge-does-not-withdraw rules), INT
// assertion with vector = base + IRQ, INTA IRR->ISR transfer, non-specific
// EOI, masking, and the critical no-spurious-INTA guarantee (an INTA with
// nothing pending must not re-assert INT).
//
// INT timing uses fixed posedge waits: the DUT latches a rising edge one
// posedge later and asserts INT one posedge after that (2 cycles edge-to-INT),
// and deasserts INT one posedge after INTA. Fixed waits are used (rather than
// wait()/task polling) because iverilog's wait() and task-based NBA sampling
// miss the DUT's posedge-updated int_out in isolation.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The 8259: reset masking, ICW1/ICW2, edge-triggered latching including no re-latch after INTA and a falling edge not withdrawing a request, INT with vector = base + IRQ, the IRR to ISR transfer on INTA, non-specific EOI, masking, no spurious INTA, and the same-cycle edge-set vs ack-clear collision (a new IR edge landing on the acknowledge edge of the same level must SURVIVE set-wins, race-idiom S2; FAIL-FIRST against the old clear-wins fold).
//
// The 8259: reset masking, ICW1/ICW2, edge-triggered latching including no re-latch after INTA and a falling edge not withdrawing a request, INT with vector = base + IRQ, the IRR to ISR transfer on INTA, non-specific EOI, masking, no spurious INTA, and the same-cycle edge-set vs ack-clear collision (a new IR edge landing on the acknowledge edge of the same level must SURVIVE - set wins - or the request is lost forever; review interrupts.md F5 / race-idiom S2, FAIL-FIRST against the old clear-wins fold).


module tb_pc9821_pic;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, wr = 0, rd = 0, a0 = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  reg [7:0] ir_in = 0;
  wire int_out;
  wire [7:0] int_vec;
  reg inta = 0;

  // ==== DUT ====
  pc9821_pic #(.BASE_VEC(8'h08)) dut (
      .clk(clk),
      .rst_n(rst_n),
      .cs(cs),
      .wr(wr),
      .rd(rd),
      .a0(a0),
      .din(din),
      .dout(dout),
      .ir_in(ir_in),
      .int_out(int_out),
      .int_vec(int_vec),
      .inta(inta)
  );

  integer errors = 0;
  // ==== STIMULUS ====

  task fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_cmd(input [7:0] d);
    begin
      @(negedge clk); cs = 1; wr = 1; a0 = 0; din = d;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask
  task write_data(input [7:0] d);
    begin
      @(negedge clk); cs = 1; wr = 1; a0 = 1; din = d;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask
  task read_cmd(output [7:0] d);
    begin
      @(negedge clk); cs = 1; rd = 1; a0 = 0;
      @(negedge clk); d = dout; cs = 0; rd = 0;
    end
  endtask
  task read_data(output [7:0] d);
    begin
      @(negedge clk); cs = 1; rd = 1; a0 = 1;
      @(negedge clk); d = dout; cs = 0; rd = 0;
    end
  endtask

  // One-cycle INTA pulse (ao486 interrupt_done).
  task inta_pulse;
    begin
      @(negedge clk); inta = 1;
      @(negedge clk); inta = 0;
    end
  endtask

  // One clean rising edge on the given IRQ (level held high afterwards).
  task ir_rise(input [7:0] which);
    begin
      @(negedge clk); ir_in = 0;
      @(negedge clk); ir_in = which;
    end
  endtask

  task ir_fall;
    begin
      @(negedge clk); ir_in = 0;
    end
  endtask

  // INT asserts 2 posedges after a rising edge; settle with a margin.
  task wait_int_high;
    begin
      repeat (5) @(posedge clk);
    end
  endtask
  // INT deasserts 1 posedge after INTA; settle with a margin.
  task wait_int_low;
    begin
      repeat (3) @(posedge clk);
    end
  endtask

  reg [7:0] value;
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    // Reset: all IRQs masked, no INT.
    read_data(value);
    if (value !== 8'hFF) fail("reset IMR is not all-masked");
    if (int_out) fail("INT asserted at reset");

    // Program: ICW1 (SNGL=1, IC4=0), ICW2 = 0x08. The model's ICW state
    // machine still consumes the ICW3 slot (one data-port write) before the
    // data port becomes IMR, so a dummy write flushes it.
    write_cmd(8'h1A);
    write_data(8'h08);  // ICW2

    // Unmask IRQ2 (keyboard).
    write_data(8'hF9);  // unmask IRQ1 and IRQ2

    // A rising edge on IRQ2 latches and asserts INT with vector 0x0A.
    ir_rise(8'h04);
    wait_int_high;
    if (!int_out) fail("INT did not assert on latched IRQ2");
    if (int_vec !== 8'h0A) fail("INT vector is not base+2");

    // INTA: transfers IRR->ISR and deasserts INT.
    inta_pulse;
    wait_int_low;
    read_cmd(value);  // read_irr defaults to 1, so this reads IRR
    if (value !== 8'h00) fail("IRR not cleared after INTA");
    // The claim names the ISR and nothing else reads it; OCW3 0x0B selects it.
    write_cmd(8'h0B);
    read_cmd(value);
    if (value !== 8'h04) fail("ISR did not show IRQ2 in service after INTA");

    // A still-held level must NOT re-latch after INTA (no new edge).
    repeat (4) @(posedge clk);
    if (int_out) fail("held IR level re-latched after INTA");
    write_cmd(8'h20);  // EOI for the serviced IRQ2
    // EOI must clear the ISR: watching INT alone passes even if it clears nothing.
    write_cmd(8'h0B);
    read_cmd(value);
    if (value !== 8'h00) fail("non-specific EOI did not clear the ISR");

    // A falling edge does not withdraw an unacknowledged request: raise
    // IRQ1, let it latch, drop the level before INTA - INT stays high.
    ir_rise(8'h02);
    wait_int_high;
    if (!int_out) fail("INT did not assert on latched IRQ1");
    ir_fall;
    repeat (3) @(posedge clk);
    if (!int_out) fail("falling edge withdrew an unacknowledged request");
    inta_pulse;
    wait_int_low;

    // Non-specific EOI clears the highest-priority serviced bit; with nothing
    // latched, INT stays low.
    write_cmd(8'h20);
    repeat (3) @(posedge clk);
    if (int_out) fail("INT asserted after EOI with nothing pending");

    // Masking: mask IRQ2, raise it, INT must not assert.
    write_data(8'hFD);  // mask IRQ2
    ir_rise(8'h04);
    repeat (6) @(posedge clk);
    if (int_out) fail("masked IRQ2 asserted INT");

    // Unmask and confirm it now asserts.
    write_data(8'h00);  // IMR=0 unmask all
    wait_int_high;
    if (!int_out) fail("unmasked IRQ2 did not assert INT");
    inta_pulse;
    wait_int_low;

    // The critical guarantee: an INTA with nothing pending must not
    // re-assert INT (no spurious interrupt).
    write_cmd(8'h20);  // EOI
    repeat (3) @(posedge clk);
    inta_pulse;
    repeat (5) @(posedge clk);
    if (int_out) fail("spurious INT after INTA with nothing pending");

    // ------------------------------------------------------------------
    // Regression: the real ICW sequences must leave the data port writable.
    //
    // ICW1 with SNGL=0 and IC4=0 (0x10/0x12) asks for ICW2 + ICW3 and no ICW4.
    // The state machine used to park with icw_active still set, so every later
    // write to the data port was swallowed as a stray ICW4: the IMR became
    // permanently unwritable, INT could never follow, and the guest's mask
    // read-modify-write silently did nothing. That is exactly how the
    // authentic BIOS wedges -- spinning on the VSYNC flag with IMR frozen at
    // the 0x7F its ITF left behind. The older bench missed it because it
    // initialised with SNGL=1 and unmasked with 0x00, which passes whether or
    // not the write is discarded.
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    // 0x10 is the wedging combination: bit 1 = 0 means ICW3 is expected, bit 0
    // = 0 means ICW4 is not. So the machine consumes ICW2 and ICW3 and must then
    // leave the sequence -- 0x11 (IC4=1) exits after ICW4, and 0x12 (SNGL=1)
    // exits after ICW2, which is why only this exact form exposes the bug.
    write_cmd(8'h10);        // ICW1: SNGL=0 (ICW3), IC4=0 (no ICW4)
    write_data(8'h08);       // ICW2
    write_data(8'h80);       // ICW3
    write_data(8'h7F);       // must land in the IMR
    read_data(value);
    if (value !== 8'h7F) fail("ICW1=0x10 left the data port unwritable");
    ir_rise(8'h04);          // IRQ2 pending
    repeat (3) @(posedge clk);
    if (int_out) fail("masked IRQ2 asserted INT after ICW1=0x10");
    write_data(8'hFB);       // unmask IRQ2: the write the BIOS makes
    repeat (3) @(posedge clk);
    if (!int_out) fail("unmasking IRQ2 did not assert INT after ICW1=0x10");
    inta_pulse;
    repeat (5) @(posedge clk);
    write_cmd(8'h20);        // EOI

    // SNGL=1 (ICW1 bit 1) means there is no ICW3, so the word after ICW2 is the
    // IMR (or ICW4 if IC4 is set). The sequence machine used to consume it, which
    // left the guest with no interrupts at all and, in the IC4 case, loaded AEOI
    // from the mask byte.
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    write_cmd(8'h12);        // ICW1: SNGL=1, IC4=0 -> sequence ends at ICW2
    write_data(8'h08);       // ICW2
    write_data(8'h7F);       // must be the IMR
    read_data(value);
    if (value !== 8'h7F) fail("ICW1=0x12 ate the IMR write");

    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    write_cmd(8'h13);        // ICW1: SNGL=1, IC4=1 -> ICW2 then ICW4
    write_data(8'h08);       // ICW2
    write_data(8'h0D);       // ICW4 (not AEOI: bit 1 clear)
    write_data(8'h7F);       // IMR
    read_data(value);
    if (value !== 8'h7F) fail("ICW1=0x13 did not reach the IMR");

    // The four-word form (IC4=1) must leave the same usable data port.
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    write_cmd(8'h11);        // ICW1: SNGL=0, IC4=1
    write_data(8'h08);       // ICW2
    write_data(8'h80);       // ICW3
    write_data(8'h1D);       // ICW4
    write_data(8'h7F);       // IMR
    read_data(value);
    if (value !== 8'h7F) fail("ICW1=0x11 sequence left a wrong IMR");

    // ------------------------------------------------------------------
    // The same-cycle collision (race-idiom S2): an old
    // pulse set ir_latch[2], the line fell again, and a NEW pulse rises in the exact
    // clk edge where inta acknowledges bit 2. The old fold `(latch | set) & ~clr` let
    // the clear eat the set for the same bit - the new request vanished with no way
    // for an edge source to re-assert it. Set must win: `(latch & ~clr) | set`.
    // FAIL-FIRST: the old fold answers IRR 0x00 here, want 0x04.
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    write_cmd(8'h1A);        // ICW1: SNGL=1, IC4=0
    write_data(8'h08);       // ICW2
    write_data(8'hFB);       // IMR: IRQ2 unmasked only
    ir_rise(8'h04);          // the OLD request: latched, then the level falls
    wait_int_high;
    ir_fall;
    repeat (3) @(posedge clk);
    if (!int_out) fail("collision setup: the first IRQ2 edge did not latch");
    // THE COLLISION, one edge: the new rise and the acknowledge of the old latch.
    @(negedge clk); inta = 1; ir_in = 8'h04;
    @(negedge clk); inta = 0;             // ir_in stays high: the new request is held
    repeat (2) @(posedge clk);
    read_cmd(value);                      // read_irr is 1 after ICW1: this is IRR
    if (value !== 8'h04)
      fail("same-cycle edge-set was eaten by the ack clear (IRR != 0x04)");
  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_PIC: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIC: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PIC: timeout");
  end

endmodule
