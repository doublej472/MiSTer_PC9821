`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDC_VFO: the floppy interface's VFO timer (0x94 bit 0 TTRG, bit 2 TMSK; undoc98 io_fdd.txt) raises the controller's interrupt line once, 90.6 ms after a write with TTRG set, as the real Xe10 does for the BIOS's hand-back 0x94 <- 09, 0C (docs/probes/XE10T-XE10-FDC2A.TXT and -FDC2C.TXT VFO rows: one rise at 28018 and 27649 ARTIC ticks, 91.2 and 90.0 ms, with SENSE INTERRUPT STATUS answering 80 - the controller has no status of its own), never before 89 ms nor after 91.5 ms; the line then STAYS high (irr_end=18, and the machine's later READ DATA completions raise no new edge) until a write with TMSK clear (the RST_M reset's 0x98, after which its drive-poll interrupt rises again), and a re-trigger (the BIOS IRQ11 handler's 0D, 0C, BANK7@0x7AC4-0x7ACA, whose motor-off countdown the captures' 0x0485 bytes show running) drops it and raises it again one period later; a trigger with TMSK clear raises nothing while TMSK stays clear, but its expiry is held: kit 2's FDVFO row (docs/probes/KIT2-XE10-FD0.TXT:4) - 0x94 <- 09, 08, 200 ms, then 0C - raises the line within 3 ARTIC ticks of the 0C, and SENSE INTERRUPT STATUS answers 80 and leaves it high, until a trigger drops it. FAIL-FIRST: the controller had no VFO timer, and the core's capture of the same row reads `t_irq_art=- rises=0` (docs/probes/core/XE10T-FDC2-CORE-A.TXT).
//
// THE EXPECTED VALUES:
//   undoc98 io_fdd.txt (I/O 0094h/00CCh write): bit 2 TMSK "1 = timer interrupt enabled, 0 =
//     masked ... the VFO's timer interrupt, triggered by TTRG (bit 0)"; bit 0 TTRG "writing
//     this bit as 1 raises an interrupt 100 ms later; TMSK (bit 2) can mask it".
//   THE MACHINE: XE10T-XE10-FDC2A.TXT `VFO da=90 irr_pre=10 t_irq_art=28018 rises=1 irr_end=18
//     irq_unmask=1 msr_end=80 sis=80` (and -FDC2C.TXT `t_irq_art=27649`), timed from the 0x0C
//     write that follows the 0x09 by one 0x5F wait; one ARTIC tick is 3.255 us. The model's
//     period is their mean, 90.6 ms.
//   THE BIOS (the Xe10's own, BANK7@0x7AAB-0x7AD1): its IRQ11 handler, finding no controller
//     status, decrements the motor-off count 0x0485 and, while it is not zero, writes 0x94 <- 0D
//     then 0C; at zero it writes 0x00. Each period is therefore a fresh request.
// The DUT runs at its default SYS_CLOCK_HZ = 50 MHz: 1 ms is 50000 cycles.
//
// ==== DUT ====
module tb_pc9821_fdc_vfo;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg cs = 0, wr = 0, rd = 0;
  reg [2:0] addr = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg  [3:0] present = 4'b0001;

  pc9821_fdc dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(),
      .fd_640k(1'b0), .fd_auto(1'b0),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present(present), .writeprotect(4'b0000),
      .media_chg(4'b0000), .frame_tick(1'b0),
      .media_req(), .media_req_hdr(), .media_unit(),
      .media_c(), .media_h(), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(),
      .media_r(), .media_n(), .media_idx(),
      .media_wr(), .media_din(), .media_abort(),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(8'h00), .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(), .dma_drq(), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout(), .dma_we(1'b0), .dma_din(8'h00), .res_done(),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  integer fails = 0;
  integer i, t;

  localparam integer MS       = 50000;          // cycles per ms at 50 MHz
  localparam integer EARLIEST = 89 * MS;        // below the machine's 90.0 ms, one tick of slack
  localparam integer LATEST   = 91 * MS + MS/2; // above its 91.2 ms

  initial begin
    #3_000_000_000;
    $fatal(1, "TB_PC9821_FDC_VFO: watchdog timeout (no verdict reached)");
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

  // Cycles from now until the line rises, up to `lim` (t = lim + 1 when it never does).
  task automatic time_irq(input integer lim);
    begin
      t = 0;
      while (!irq && (t <= lim)) begin @(negedge clk); t = t + 1; end
    end
  endtask

  // The line rises inside the machine's window after the trigger that was just written.
  task automatic in_window(input [8*80-1:0] what);
    begin
      time_irq(LATEST);
      if (t > LATEST) begin
        $display("  FAIL: %0s: no interrupt within %0d cycles", what, LATEST);
        fails = fails + 1;
      end else if (t < EARLIEST) begin
        $display("  FAIL: %0s: interrupt after %0d cycles, before the machine's 90 ms", what, t);
        fails = fails + 1;
      end else
        $display("  %0s: interrupt %0d cycles (%0d us) after the trigger", what, t, t / 50);
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

  // The line stays high for `k` cycles.
  task automatic held(input integer k, input [8*80-1:0] what);
    begin
      for (i = 0; i < k; i = i + 1) begin
        @(negedge clk);
        if (!irq) begin
          $display("  FAIL: %0s: the line fell %0d cycles in", what, i); fails = fails + 1;
          i = k;
        end
      end
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    repeat (4) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);

    // V1: the BIOS's hand-back, 0x94 <- 09 then 0C (the VFO row's own writes).
    wr8(3'd2, 8'h09);
    repeat (2) @(negedge clk);
    wr8(3'd2, 8'h0C);
    in_window("V1 0x94 <- 09, 0C: the VFO interrupt (VFO t_irq_art=28018/27649)");

    // V2: the controller has no status of its own (VFO msr_end=80 sis=80), and the line holds.
    rd8(3'd0);
    check8(rd_val, 8'h80, "V2 MSR idle while the VFO holds the line (VFO msr_end=80)");
    wr8(3'd1, 8'h08);
    rd8(3'd1);
    check8(rd_val, 8'h80, "V2 SENSE INTERRUPT STATUS = 80 (VFO sis=80)");
    held(300 * MS, "V2 the VFO line holds (VFO irr_end=18, rises=1)");

    // V3: a write with TMSK clear drops it - the RST_M reset's 0x98 - and the reset's own
    // drive-poll interrupt then rises as a new request (RST_M irr_pre=10 ... rises=1).
    wr8(3'd2, 8'h98);
    check_irq(1'b0, "V3 0x94 <- 98 (TMSK clear) drops the VFO line (RST_M irr_pre=10)");
    repeat (10) @(negedge clk);
    wr8(3'd2, 8'h18);
    time_irq(3 * MS);
    if (t > 3 * MS) begin
      $display("  FAIL: V3 the reset's interrupt did not rise after the VFO line fell"); fails = fails + 1;
    end
    wr8(3'd1, 8'h08); rd8(3'd1);
    check8(rd_val, 8'hC0, "V3 the reset's AI|0 (RST_M sis=C000)");
    rd8(3'd1);
    wr8(3'd1, 8'h08); rd8(3'd1);
    check8(rd_val, 8'h80, "V3 then nothing");
    check_irq(1'b0, "V3 the line is low after the drain");

    // V4: the BIOS handler's re-trigger (0D then 0C, BANK7@0x7AC4-0x7ACA) while the line is up
    // drops it and raises it again one period later.
    wr8(3'd2, 8'h09); wr8(3'd2, 8'h0C);
    in_window("V4 the first period");
    wr8(3'd2, 8'h0D);
    check_irq(1'b0, "V4 the re-trigger (0D) drops the line");
    wr8(3'd2, 8'h0C);
    in_window("V4 the next period after the BIOS's 0D, 0C");
    wr8(3'd2, 8'h00);                                   // the BIOS's count-zero write
    check_irq(1'b0, "V4 0x94 <- 00 (the count reached zero) drops the line");

    // V5: a trigger with TMSK clear raises nothing while TMSK stays clear, but its expiry is
    // HELD: kit 2's FDVFO row (docs/probes/KIT2-XE10-FD0.TXT:4, `irr09-08 ... irr200ms/irr0C
    // ... 90 98 ... irrdrain 98 rise=00000003 sis=80`): 0x94 <- 09, 08, 200 ms with IR11 clear,
    // then 0x94 <- 0C (TMSK set, no trigger) raises the line within 3 ARTIC ticks (9.8 us), and a
    // SENSE INTERRUPT STATUS answering 80 leaves it high.
    wr8(3'd2, 8'h09); wr8(3'd2, 8'h08);
    quiet(200 * MS, "V5 a trigger with TMSK clear (09, 08) raises nothing for 200 ms (irr200ms=90)");
    wr8(3'd2, 8'h0C);
    time_irq(490);                                      // 3 ARTIC ticks = 9.8 us = 490 cycles
    if (t > 490) begin
      $display("  FAIL: V5 0x94 <- 0C did not show the held expiry within 3 ARTIC ticks (rise=00000003)");
      fails = fails + 1;
    end
    wr8(3'd1, 8'h08); rd8(3'd1);
    check8(rd_val, 8'h80, "V5 SENSE INTERRUPT STATUS = 80 (FDVFO sis=80)");
    check_irq(1'b1, "V5 the line stays high after the drain (irrdrain=98)");
    wr8(3'd2, 8'h0D);
    check_irq(1'b0, "V5 a trigger drops the held output");

  // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_FDC_VFO: FAIL (%0d)", fails);
    $display("TB_PC9821_FDC_VFO: PASS");
    $finish;
  end
endmodule
