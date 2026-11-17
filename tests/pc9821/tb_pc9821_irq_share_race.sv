`timescale 1ns/1ps

// tb_pc9821_irq_share_race - the INT5 junction's one-cycle bubble never turns a pending
// IRQ12 request into a spurious vector.

// ==== WHAT THIS PROVES ====
// TB_PC9821_IRQ_SHARE_RACE: a request on the PC-9801-86 board's shared INT5 line (IRQ12, the slave 8259's IR4) that is latched and not yet acknowledged SURVIVES the one-cycle bubble pc9821_irq_share drops the line for when the other source raises an event under it: with the OPNA side holding the line and IRQ12 pending, an 86-PCM event raised at every offset from 0 to 23 cycles before the CPU's second INTA is answered with vector 0x14, never the slave's spurious 0x17 or the master's spurious 0x0F, and every later interrupt is 0x14 too - as NP2kai delivers it (each event is a pic_setirq that only sets the IRR bit, io/pic.c:262 `pi[1].irr |= bit;` for a slave line, so a second event while a request is pending changes nothing), while a lasting fall of the line still withdraws the request (the slave's WD_UNMASKED bit 4, docs/probes/XE10T-XE10-AUDIT.TXT CASC_DEV), and the filter's boundary is exact: a one-cycle low withdraws nothing and a two-cycle low withdraws (the two-cycle threshold is this RTL's filter contract, not a measured number). FAIL-FIRST: before the slave's WD_FILTER the bubble's falling edge withdrew the latched IR4 for a cycle, and the master's IR7 after it, so an INTA in those cycles took INT 17h or INT 0Fh.
//
// ==== DUT ====
// pc9821_irq_share driven from the bench (irq_a = the OPNA side, irq_b = the 86-PCM side) into
// the real pc9821_interrupts pair, wired as pc9821_system.sv wires them (the shared line on
// slave_irq bit 4). The CPU is the bench: INTA strobes through the pair's inta bridge.
//
// ==== CHECKS ====
// 1. For each offset d = 0..23: the OPNA side raises the line, IRQ12 is requested, the CPU runs
//    its first INTA, the 86-PCM side raises an event (the bubble), and d cycles later the CPU
//    runs the second INTA: the vector is 0x14. After the EOIs, any further interrupt within
//    400 cycles answers 0x14. 2. A real withdraw still works: with IRQ12 pending and masked
//    nowhere, the line falling for good leaves no interrupt (INT drops and the master's IR7
//    clears). 3. The filter's boundary: a one-cycle low of the line withdraws nothing, a
//    two-cycle low withdraws the pending request (the master's IR7 drops before the line's
//    next rising edge requests again, answered 0x14).
//
// ==== VERDICT ====
// PASS when every check holds; each failure is named; $fatal on any.

module tb_pc9821_irq_share_race;

  localparam integer CLK_HZ = 50_000_000;

  reg clk = 0;
  always #10 clk = ~clk;

  reg reset = 1;
  reg ua = 0, ub = 0;
  wire int5;

  pc9821_irq_share share (.clk(clk), .reset(reset), .irq_a(ua), .irq_b(ub), .irq(int5));

  reg  [15:0] pic_addr = 16'h0000;
  reg         pic_wr = 0, pic_rd = 0;
  reg  [7:0]  pic_din = 8'h00;
  reg         pic_master_cs = 0, pic_slave_cs = 0;
  reg         pic_rst_n = 0;
  wire [7:0]  pic_slave_irq = {3'b000, int5, 4'b0000};
  wire        cpu_intr;
  reg         cpu_inta = 0;
  wire [31:0] inta_din;
  wire        inta_ready;
  wire [7:0]  pic_dout, dbg_imr, dbg_irr, dbg_isr;
  wire        pit_out0, pit_out1, pit_out2;

  // ==== DUT ====
  pc9821_interrupts #(.SYS_CLOCK_HZ(CLK_HZ)) pic (
    .clk(clk), .reset_n(pic_rst_n),
    .io_wr(pic_wr), .io_rd(pic_rd), .io_addr(pic_addr), .io_din(pic_din),
    .master_cs(pic_master_cs), .slave_cs(pic_slave_cs), .pit_cs(1'b0),
    .io_dout(pic_dout),
    .keyboard_irq(1'b0), .vsync_irq(1'b0),
    .master_aux_irq(4'b0000),
    .slave_irq(pic_slave_irq),
    .cpu_intr(cpu_intr), .cpu_inta(cpu_inta),
    .cpu_inta_din(inta_din), .cpu_inta_ready(inta_ready),
    .pit_out0(pit_out0), .pit_out1(pit_out1), .pit_out2(pit_out2),
    .dbg_imr(dbg_imr), .dbg_irr(dbg_irr), .dbg_isr(dbg_isr)
  );

  integer errors = 0;

  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic pic_write(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      pic_addr = portnum;
      pic_master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      pic_slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pic_din = data;
      pic_wr = 1;
      @(negedge clk);
      pic_wr = 0;
      pic_master_cs = 0; pic_slave_cs = 0;
    end
  endtask

  // One INTA strobe, held until the bridge answers it (the CPU's bus cycle).
  task automatic inta_cycle(output [7:0] vec);
    begin
      @(negedge clk);
      cpu_inta = 1;
      while (!inta_ready) @(negedge clk);
      vec = inta_din[7:0];
      @(negedge clk);
      cpu_inta = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic wait_intr(input integer limit, output integer got);
    integer n;
    begin
      n = 0;
      while (!cpu_intr && n < limit) begin @(negedge clk); n = n + 1; end
      got = cpu_intr ? 1 : 0;
    end
  endtask

  // The PIC pair as the BIOS sets it: master ICW 11/08/80/1D, slave 11/10/07/01; only the
  // cascade (master IR7) and the slave's IR4 open.
  task automatic init_pics;
    begin
      pic_rst_n = 0;
      repeat (4) @(negedge clk);
      pic_rst_n = 1;
      repeat (4) @(negedge clk);
      pic_write(16'h0000, 8'h11); pic_write(16'h0002, 8'h08);
      pic_write(16'h0002, 8'h80); pic_write(16'h0002, 8'h1D);
      pic_write(16'h0002, 8'h7F);
      pic_write(16'h0008, 8'h11); pic_write(16'h000A, 8'h10);
      pic_write(16'h000A, 8'h07); pic_write(16'h000A, 8'h01);
      pic_write(16'h000A, 8'hEF);
      repeat (8) @(negedge clk);
    end
  endtask

  task automatic eois;
    begin
      pic_write(16'h0008, 8'h64);           // slave: specific EOI, IR4
      pic_write(16'h0000, 8'h67);           // master: specific EOI, IR7
    end
  endtask

  integer d, got, extra, dropped;
  reg [7:0] v;

  // ==== STIMULUS ====
  initial begin
    repeat (10) @(negedge clk);
    reset = 0;
    repeat (10) @(negedge clk);

    // ---- 1. the bubble under a pending request, at every offset before the second INTA ----
    for (d = 0; d < 24; d = d + 1) begin
      ua = 0; ub = 0;
      init_pics();
      if (cpu_intr) fail("INT was up before either source raised the line");
      ua = 1;                               // the OPNA side raises the line: IRQ12 latched
      wait_intr(50, got);
      if (!got) fail("precondition: the OPNA side's edge was not requested");
      inta_cycle(v);                        // INTA 1 (the bridge answers 0)
      @(negedge clk);
      ub = 1;                               // the 86-PCM side's event under the held line
      repeat (d) @(negedge clk);
      inta_cycle(v);                        // INTA 2: the vector
      if (v !== 8'h14) begin
        $display("FAIL: offset %0d: the pending IRQ12 answered vector %02x, want 14 @ %0t", d, v, $time);
        errors = errors + 1;
      end
      eois();
      // Any later interrupt (the event may have become its own request when the ack came
      // before the bubble) must also be IRQ12's.
      extra = 0;
      wait_intr(400, got);
      while (got && extra < 3) begin
        inta_cycle(v); inta_cycle(v);
        if (v !== 8'h14) begin
          $display("FAIL: offset %0d: a later interrupt answered vector %02x, want 14 @ %0t", d, v, $time);
          errors = errors + 1;
        end
        eois();
        extra = extra + 1;
        wait_intr(400, got);
      end
      if (got) fail("the shared line kept requesting after both sources were served");
    end

    // ---- 2. a real fall still withdraws the pending request ----
    ua = 0; ub = 0;
    init_pics();
    ua = 1;
    wait_intr(50, got);
    if (!got) fail("precondition: the edge for the withdraw case was not requested");
    ua = 0;                                 // the source lowers its line for good
    repeat (20) @(negedge clk);
    if (cpu_intr) fail("WITHDRAW: INT stayed up after the IRQ12 line fell for good");
    if (dbg_irr[7] !== 1'b0) fail("WITHDRAW: the master IRR bit 7 stayed set after the line fell");

    // ---- 3. the filter's boundary: one low cycle is a bubble, two are a fall ----
    // A low of exactly ONE cycle (the bubble's shape, here made by the source itself) must not
    // withdraw: the request stays latched in the slave (its IR4) and so on the master's IR7 in
    // every cycle after. A low of exactly TWO cycles is a fall and withdraws the pending
    // request, which shows as the master's IR7 dropping for at least one cycle before the
    // line's new rising edge latches a new request. The two-cycle threshold is this RTL's
    // filter contract (the shortest low that is not the one-cycle bubble), not a measured
    // number: the machine's withdraw evidence is a lasting fall (CASC_DEV, section 2).
    for (d = 1; d <= 2; d = d + 1) begin
      ua = 0; ub = 0;
      init_pics();
      ua = 1;
      wait_intr(50, got);
      if (!got) fail("precondition: the edge for the boundary case was not requested");
      repeat (4) @(negedge clk);
      ua = 0;
      repeat (d) @(negedge clk);
      ua = 1;
      dropped = 0;
      repeat (12) begin
        @(negedge clk);
        if (dbg_irr[7] !== 1'b1) dropped = 1;
      end
      if (d == 1 && dropped)
        fail("BOUNDARY: a one-cycle low withdrew the pending IRQ12 (the bubble must not)");
      if (d == 2 && !dropped)
        fail("BOUNDARY: a two-cycle low of the line did not withdraw the pending IRQ12");
      if (!cpu_intr) fail("BOUNDARY: no request was pending after the line came back high");
      inta_cycle(v); inta_cycle(v);
      if (v !== 8'h14) begin
        $display("FAIL: boundary %0d-cycle low: the request answered vector %02x, want 14", d, v);
        errors = errors + 1;
      end
      eois();
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IRQ_SHARE_RACE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IRQ_SHARE_RACE: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IRQ_SHARE_RACE: TIMEOUT");
  end

endmodule
