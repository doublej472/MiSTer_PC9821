`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// An UNMASKED IRQ0 request that the PIT withdraws before it is acknowledged is not delivered: reprogramming channel 0 to mode 0 (OUT falls) clears master IRR bit 0 whether IRQ0 is masked or not, so a timer handler that re-arms mode 3 and then mode 0 inside its own tick (Might and Magic III's NEC26K/Roland driver over the BIOS INT 1Ch interval timer) does not loop on a phantom IRQ0. Expected from NP2kai's channel-0 write clearing master IRR0 (io/pit.c:378 after a complete count, :470-471 on a mode-set control word) and from the real Xe10's IRR following the OUT pin (docs/probes/IRQWD.TXT; the 8259's IRR sits upstream of the IMR, so the mask does not change it). FAIL-FIRST: the masked-only withdraw left the request latched and delivered it 1 clk after the EOI. The positive control delivers exactly one IRQ0 (vector 0x08) at the new count's terminal count.
//
// ---- where the expectation comes from ----
//   NP2kai io/pit.c pit_o71 (`pic.pi[0].irr &= (~1);` once the count is
//     complete) and pit_o77 (`if (chnum == 0) { ... pic.pi[0].irr &= (~1);`).
//     NP2kai also clears on a counter LATCH command; the Xe10 does not
//     (pit_irq_clear's waiver, docs/probes/IRQWD.TXT), and a latch does not
//     move OUT, so this bench issues no latch.
//   docs/probes/IRQWD.TXT - masked IRR bit 0 follows OUT (2826 falls / 2826
//     rises): the request is the OUT level, not a sticky latch.
//   The sequence is the one the userdisk run of Might and Magic III logs at
//   ~175M cycles: BIOS fd80:05E6 `out 77h,36h / 71h,00h / 71h,60h`, unmask,
//   then the driver's `out 77h,20h / 71h,80h`.

`default_nettype none

module tb_pc9821_pit_irq_reprogram;

  reg clk = 0;
  always #10 clk = ~clk;                 // 50 MHz, the shipped SYS_FREQ
  reg reset_n = 0;

  reg  io_wr = 0, io_rd = 0;
  reg  [15:0] io_addr = 0;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg  master_cs = 0, slave_cs = 0, pit_cs = 0;
  reg  keyboard_irq = 0, vsync_irq = 0;
  reg  [3:0] master_aux_irq = 0;
  reg  [7:0] slave_irq = 0;
  wire cpu_intr;
  reg  cpu_inta = 0;
  wire [31:0] cpu_inta_din;
  wire cpu_inta_ready;
  wire pit_out0, pit_out1, pit_out2;
  wire [7:0] dbg_imr, dbg_irr, dbg_isr;
  wire [7:0] dbg_s_imr, dbg_s_isr;

  // ==== DUT ====
  pc9821_interrupts #(.SYS_CLOCK_HZ(50_000_000)) dut (.*);

  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  task automatic fail(input [8*140-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic set_selects(input [15:0] portnum);
    begin
      master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pit_cs    = ((portnum[15:3] == 13'h000E) || (portnum[15:3] == 13'h07FB)) &&
                  portnum[0];
    end
  endtask

  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; set_selects(portnum); io_din = data; io_wr = 1;
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic read_port(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; set_selects(portnum); io_rd = 1;
      #1 data = io_dout;
      @(negedge clk); io_rd = 0;
    end
  endtask

  task automatic init_master(input [7:0] mask);
    begin
      write_port(16'h0000, 8'h11); write_port(16'h0002, 8'h08);
      write_port(16'h0002, 8'h80); write_port(16'h0002, 8'h1D);
      write_port(16'h0002, mask);
    end
  endtask

  task automatic reset_all;
    begin
      reset_n = 0; io_wr = 0; io_rd = 0; cpu_inta = 0;
      repeat (4) @(negedge clk);
      reset_n = 1;
      repeat (2) @(negedge clk);
    end
  endtask

  // One x86 acknowledge is two INTA assertions, as the bridge's state machine needs.
  task automatic one_inta;
    begin
      @(negedge clk); cpu_inta = 1;
      while (!cpu_inta_ready) @(negedge clk);
      @(negedge clk); cpu_inta = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // Wait for IRQ0 to reach the CPU, acknowledge it, EOI, and return the vector.
  task automatic service_irq(output [7:0] vec, output bit ok);
    integer guard;
    begin
      guard = 0;
      while (!cpu_intr && guard < 20000) begin @(posedge clk); guard = guard + 1; end
      ok = (guard < 20000);
      vec = 8'h00;
      if (ok) begin
        one_inta(); one_inta();
        vec = cpu_inta_din[7:0];
        write_port(16'h0000, 8'h20);       // master non-specific EOI
        repeat (4) @(posedge clk);
      end
    end
  endtask

  bit iok;
  reg [7:0] rv;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;

    reset_all();
    init_master(8'hFF);                    // IRQ0 masked while the request is raised
    // ch0 mode 0, MSB only, a long count: OUT is low and stays low
    write_port(16'h0077, 8'h20);
    write_port(16'h0071, 8'h80);
    repeat (20) @(posedge clk);
    if (dbg_irr[0] !== 1'b0) fail("IRR0 set by a mode-0 load (OUT is low)");

    // the BIOS INT 1Ch AH=03h re-arm: mode 3 raises OUT -> a rising edge -> IRR0
    write_port(16'h0077, 8'h36);
    write_port(16'h0071, 8'h00);
    write_port(16'h0071, 8'h60);
    repeat (4) @(posedge clk);
    if (dbg_irr[0] !== 1'b1) fail("the mode-3 control word's rising OUT did not request IRQ0");
    write_port(16'h0002, 8'hFE);            // unmask IRQ0 (the CPU has IF=0: no acknowledge)

    // the driver's own re-arm: mode 0 again, OUT falls -> the request is withdrawn
    write_port(16'h0077, 8'h20);
    write_port(16'h0071, 8'h01);            // MSB only: count 0x0100 (~5.2k clk_sys)
    repeat (4) @(posedge clk);
    if (dbg_irr[0] !== 1'b0)
      fail("unmasked IRR0 survived the channel-0 reprogram (NP2kai pit.c:470-471 clears it)");
    else $display("ok       irr0_withdrawn_unmasked");
    if (cpu_intr !== 1'b0)
      fail("INTR still asserted for the withdrawn IRQ0");
    else $display("ok       intr_dropped");

    // no IRQ0 before the new count's terminal count (256 PIT ticks ~ 5.2k clk at 50 MHz)
    begin
      integer i, early;
      early = 0;
      for (i = 0; i < 3000; i = i + 1) begin
        @(posedge clk);
        if (cpu_intr) early = early + 1;
      end
      if (early != 0) fail("IRQ0 delivered before the mode-0 terminal count (phantom tick)");
      else $display("ok       no_phantom_tick");
    end

    // positive control: the terminal count delivers exactly one IRQ0, vector 0x08
    service_irq(rv, iok);
    if (!iok) fail("the mode-0 terminal count did not deliver IRQ0");
    else if (rv !== 8'h08) fail("IRQ0 vector not 0x08");
    else $display("ok       terminal_count_delivers vec=%02x", rv);
    begin
      integer i, again;
      again = 0;
      for (i = 0; i < 8000; i = i + 1) begin
        @(posedge clk);
        if (cpu_intr) again = again + 1;
      end
      if (again != 0) fail("mode 0 delivered a second IRQ0 without a reload");
      else $display("ok       one_shot");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PIT_IRQ_REPROGRAM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_IRQ_REPROGRAM: FAIL (%0d errors)", errors);
  end

endmodule

`default_nettype wire
