`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CPU_RESET_GATE: The CPU reset release waits for the SDRAM controller to leave its initialization sequence as well as for the platform hold, so an OSD reset - which keeps rom_ready and therefore cpu_run - holds the CPU for the whole re-run JEDEC initialization instead of releasing it 15 cycles later, and the release is synchronous: cpu_reset_n is still low on the clock the last condition clears and rises exactly two clocks after it, which is the difference between a machine that boots every time and one that boots sometimes.
//
// WHY THIS EXISTS. The release used to be one combinational expression in pc9821_system.sv
// (!reset && cpu_run && !hps_apply_reset && cpu_reset_count == 0) with two defects.
//
// It released the CPU without asking whether the SDRAM could answer it. A platform reset re-runs
// the controller's JEDEC initialisation (src/memory/sdram.v:1903-1905 `state_n = INIT;` with busy_buf_n
// high) and it then spends ~200 us calibrating. A core reload hides that because the pack
// download holds cpu_run low for seconds; an OSD reset does not, because pc9821_rom_loader keeps
// rom_ready deliberately so the pack is not re-downloaded - so the CPU came out of reset 15
// cycles in and fetched the reset vector from an uninitialised SDRAM. That is the intermittent
// "ROM SUM ERROR" on a MiSTer, and why only a full reload was reliable.
//
// And it deasserted ASYNCHRONOUSLY. z486 consumes reset_n as an asynchronous reset
// (always_ff @(posedge clk or negedge reset_n) in decoder, paging_unit, paging_tlb, paging_walker,
// prefetch and z486.sv itself), so the combinational release rose in the very cycle the hold
// reached zero - inside those flops' recovery window - letting different flops leave reset on
// different cycles and leaving the CPU internally inconsistent for one or more cycles.
//
// CHECK 1 AND CHECK 2 ARE THE REGRESSIONS. Check 1 fails against the old expression, which
// released the CPU after HOLD_CYCLES whatever the SDRAM was doing. Check 2 fails against it too,
// because a combinational release is high on the release cycle itself. The hold is a parameter
// so this bench is four cycles rather than sixteen.

module tb_pc9821_cpu_reset_gate;

  // ==== DUT ====
  localparam [3:0] HOLD = 4'd4;

  reg  clk = 1'b0;
  reg  reset = 1'b1;
  reg  cpu_run = 1'b0;
  reg  hps_apply_reset = 1'b0;
  reg  cpu_reset_req = 1'b0;
  reg  mem_busy = 1'b1;
  wire cpu_reset_n;

  pc9821_cpu_reset_gate #(
      .HOLD_CYCLES(HOLD)
  ) dut (
      .clk(clk), .reset(reset),
      .cpu_run(cpu_run), .hps_apply_reset(hps_apply_reset),
      .cpu_reset_req(cpu_reset_req), .mem_busy(mem_busy),
      .cpu_reset_n(cpu_reset_n)
  );

  integer errors = 0;
  integer i;

  always #5 clk = ~clk;   // 10 ns period; every count below is in cycles

  task automatic check_int(input [511:0] what, input integer got, input integer want);
    begin
      if (got !== want) begin
        $display("  FAIL %s: got %0d, want %0d", what, got, want);
        errors = errors + 1;
      end else begin
        $display("  ok   %s = %0d", what, got);
      end
    end
  endtask

  // The state a power-on leaves: held in reset, the pack not present yet, the SDRAM calibrating.
  task automatic power_on();
    begin
      reset = 1'b1; cpu_run = 1'b0; hps_apply_reset = 1'b0; cpu_reset_req = 1'b0;
      mem_busy = 1'b1;
      repeat (3) @(posedge clk);
      reset = 1'b0;
      @(posedge clk);
    end
  endtask

  // ==== CHECKS ====
  integer released;
  integer latency;

  initial begin
    power_on();

    // CHECK 1 - THE SDRAM TERM, and the reason this bench exists. The pack is present and the
    // CPU would otherwise be released after HOLD cycles, but the SDRAM is still initialising.
    // The CPU must stay in reset for the whole of it. The old expression released it here, so
    // this is the check that fails against the defect.
    $display("check 1: the CPU is held for the whole of a re-run SDRAM initialization");
    cpu_run = 1'b1;
    mem_busy = 1'b1;
    released = 0;
    repeat (20) begin
      @(posedge clk);
      if (cpu_reset_n !== 1'b0) released = released + 1;
    end
    check_int("cycles released while the SDRAM was busy", released, 0);
    check_int("sdram_ready while the SDRAM reports busy", dut.sdram_ready, 0);

    // CHECK 2 - THE RELEASE IS SYNCHRONOUS. Drop busy and follow the release condition: the CPU
    // must STILL be in reset on the clock the last term clears, and come out exactly two clocks
    // later. A combinational release - the old shape - is already high on the first of these.
    $display("check 2: the release is synchronous, two clocks after the last term clears");
    mem_busy = 1'b0;
    // The SDRAM term EXTENDS the hold and never shortens it: the full platform hold (the
    // same HOLD the warm class re-arms in check 3) still runs AFTER the controller leaves
    // init, so the end of init is not itself the release. Counted from the busy drop on
    // the DUT's ports, because the release_ok wait below is white-box and would follow a
    // gate that released the moment init ended.
    latency = 0;
    while (!dut.release_ok && latency < 100) begin
      @(posedge clk);
      latency = latency + 1;
    end
    if (latency < HOLD) begin
      $display("FAIL: the release condition came %0d clocks after SDRAM init ended, inside the %0d-clock platform hold",
               latency, HOLD);
      errors = errors + 1;
    end
    check_int("cpu_reset_n on the release cycle", cpu_reset_n, 0);
    @(posedge clk);
    check_int("cpu_reset_n one clock after release", cpu_reset_n, 0);
    @(posedge clk);
    check_int("cpu_reset_n two clocks after release", cpu_reset_n, 1);

    // CHECK 3 - THE WARM CPU-RESET CLASS still re-arms the hold, which is the behaviour
    // pc9821_system always had for out 0xF0 / 0x534 / a z486 shutdown: the CPU must go back into
    // reset for the hold and come out again, with no platform reset involved. The latency is the
    // hold plus the synchroniser's two clocks, which is the number this bench can hold to.
    $display("check 3: the warm CPU-reset class re-arms the hold and the CPU comes back");
    cpu_reset_req = 1'b1;
    @(posedge clk);
    cpu_reset_req = 1'b0;
    check_int("cpu_reset_n on the request cycle", cpu_reset_n, 0);
    latency = 0;
    while (cpu_reset_n !== 1'b1 && latency < 100) begin
      @(posedge clk);
      latency = latency + 1;
    end
    check_int("cycles from the request to the release (hold + 2)", latency, HOLD + 2);

    // CHECK 4 - NO PACK, NO RELEASE. cpu_run is pc9821_memory_subsystem's "the pack is present
    // and the loader is not mid-download". With it low the CPU must stay reset whatever the
    // SDRAM says, or a machine with no firmware would run.
    $display("check 4: no pack means no release, whatever the SDRAM reports");
    cpu_run = 1'b0;
    mem_busy = 1'b0;
    released = 0;
    repeat (20) begin
      @(posedge clk);
      if (cpu_reset_n !== 1'b0) released = released + 1;
    end
    check_int("cycles released with cpu_run low", released, 0);

    // CHECK 5 - THE PLATFORM RESET RE-ARMS EVERYTHING. This is the OSD-reset path end to end:
    // the reset pulses, the SDRAM starts initialising again, and the CPU must not come out until
    // that finishes - which is exactly the case that used to fetch from an uninitialised SDRAM.
    $display("check 5: a platform reset re-arms the SDRAM wait");
    cpu_run = 1'b1;
    reset = 1'b1;
    mem_busy = 1'b1;          // the controller's JEDEC sequence begins with the reset
    repeat (2) @(posedge clk);
    reset = 1'b0;
    released = 0;
    repeat (20) begin
      @(posedge clk);
      if (cpu_reset_n !== 1'b0) released = released + 1;
    end
    check_int("cycles released after a platform reset while the SDRAM initialises", released, 0);
    mem_busy = 1'b0;
    while (!dut.release_ok) @(posedge clk);
    repeat (2) @(posedge clk);
    check_int("the CPU comes out once the SDRAM is ready", cpu_reset_n, 1);

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_CPU_RESET_GATE: %0d check(s) failed", errors);
    $display("TB_PC9821_CPU_RESET_GATE: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner. $fatal, not
  // $finish: $finish exits ZERO, which would report a timeout as a pass.
  initial begin
    #1_000_000;
    $fatal(1, "the CPU reset gate bench did not finish in 1 ms of simulated time");
  end

endmodule
