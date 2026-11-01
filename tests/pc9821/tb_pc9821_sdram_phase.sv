`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_PHASE: the run-time SDRAM_CLK phase instrument (pc9821_sdram_phase_ctl on clk_sys + pc9821_sdram_dps on the PLL's 50 MHz scan clock), driven through its two device-bus ports against a model of the Cyclone V PLL's dynamic-phase-shift ports, moves the SDRAM pin clock by exactly the number of PLL steps the guest asks for and in the direction it asks: a requested offset written to 0x5FF2 (+5, -7) is walked one step at a time and 0x5FF2 then reads back the applied offset the PLL model has counted; command 01/02/03 at 0x5FF0 step later, step earlier and return to nominal; every step obeys the handbook sequence the model enforces (CNTSEL = 1, the SDRAM pin clock's logical output; PHASEEN held at least two scan clocks and until PHASEDONE falls; never re-raised before PHASEDONE is back high; exactly one shift per PHASEEN pulse); 0x5FF0 reads 0xA in its high nibble with busy set while a walk is in flight; when the guest stops writing for WDOG_MS the request returns to 0, the PLL is walked back to its generated phase and the sticky `reverted` bit is set until command 04 clears it, while keepalive writes every 1 ms hold a shifted phase indefinitely; a write in the very cycle the watchdog would expire wins (no revert) and a core reset requests nominal; and a PLL that never answers sets `fault`, stops further stepping and does not wedge the controller. POWER-UP AS QUARTUS BUILDS IT: both fault registers start at 1 (a set-only flag under ALLOW_POWER_UP_DONT_CARE was tied to VCC in every fitted build), and the instrument still reads 0xA0 after the power-up core reset and steps; `fault` reaches clk_sys settled at least two scan clocks before the acknowledge that reports it, is held until a core reset, and a reset in the very cycle of a failing acknowledge still reports it (set wins); after a reset a recovered PLL steps again, one PLL step per request. The expected step counts are the guest's requests, never read out of the controller.
//
// THE PLL MODEL follows the vendor's description of the DPS ports (Intel Cyclone V Device Handbook,
// "Dynamic Phase Shift"; the vendor sequencer sys/pll_cfg/altera_pll_reconfig_core.v
// `dyn_phase_shift` drives the same ports): PHASEDONE falls some scan clocks after a PHASEEN rising
// edge and rises again when the counter has moved one VCO/8 step. The model counts the steps
// (pll_steps, signed) and checks the sequence rules above on every pulse; `stuck` makes it never
// answer, the fault case.
//
// WHAT IT IS BLIND TO: the real PLL's analogue behaviour (that a step is glitch-free on the output
// is the vendor's statement), which physical counter the fitter maps CNTSEL 1 to (altera_pll's
// dont_touch rotation LUTs, rewritten by the fitter), and the guest program (tools/hwprobe/sdshmoo).

module tb_pc9821_sdram_phase;
  localparam integer CLOCK_RATE_HZ = 90_000;   // 90 clk_sys per ms: a short watchdog to simulate
  localparam integer WDOG_MS = 20;
  localparam integer WDOG_CYC = 90 * WDOG_MS;

  reg clk = 0;       // clk_sys
  always #5.5 clk = ~clk;
  reg sclk = 0;      // the 50 MHz scan clock
  always #10 sclk = ~sclk;

  reg        reset = 1'b1;   // the top level holds the core reset until the PLL locks
  reg        wr = 1'b0;
  reg [15:0] addr = 16'h0000;
  reg  [7:0] din = 8'h00;
  wire [7:0] dout;
  wire       cs = (addr == 16'h5FF0) || (addr == 16'h5FF2);
  wire       step_req, step_up, step_ack, fault;
  wire       phase_en, updn;
  wire [4:0] cntsel;
  reg        phase_done = 1'b1;

  // ==== DUT ====
  pc9821_sdram_phase_ctl #(.CLOCK_RATE_HZ(CLOCK_RATE_HZ), .WDOG_MS(WDOG_MS)) ctl (
    .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .din(din), .dout(dout),
    .step_req(step_req), .step_up(step_up), .step_ack_async(step_ack), .fault_async(fault));
  pc9821_sdram_dps #(.TIMEOUT(255)) dps (
    .clk(sclk), .step_req_async(step_req), .step_up_async(step_up),
    .phase_done_async(phase_done), .phase_en(phase_en), .updn(updn), .cntsel(cntsel),
    .step_ack(step_ack), .fault(fault));

  // ---- the PLL's DPS ports --------------------------------------------------------------
  integer fails = 0;
  integer pll_steps = 0;
  integer pulses = 0;
  reg     stuck = 1'b0;
  reg     en_prev = 1'b0;
  integer en_run = 0;
  integer busy_m = 0;      // scan clocks left in the current shift (0 = idle)
  reg     dir_m = 1'b0;
  always @(posedge sclk) begin
    en_prev <= phase_en;
    en_run <= phase_en ? en_run + 1 : 0;
    if (phase_en && !en_prev) begin
      pulses <= pulses + 1;
      if (busy_m != 0) begin
        $display("FAIL: PHASEEN re-raised before PHASEDONE returned high"); fails = fails + 1;
      end
      if (cntsel !== 5'd1) begin
        $display("FAIL: CNTSEL %0d, not 1 (the SDRAM pin clock)", cntsel); fails = fails + 1;
      end
      if (!stuck) begin busy_m <= 12; dir_m <= updn; end
    end else if (busy_m != 0) begin
      busy_m <= busy_m - 1;
      if (busy_m == 10) begin
        phase_done <= 1'b0;
        if (en_run < 2) begin
          $display("FAIL: PHASEEN held %0d scan clocks before PHASEDONE fell (needs >= 2)", en_run);
          fails = fails + 1;
        end
      end
      if (busy_m == 1) begin
        phase_done <= 1'b1;
        pll_steps <= dir_m ? pll_steps + 1 : pll_steps - 1;
        if (phase_en) begin
          $display("FAIL: PHASEEN still high when the shift completed"); fails = fails + 1;
        end
      end
    end
  end

  // ---- the device bus ---------------------------------------------------------------------
  task automatic bus_wr(input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); addr = a; din = d; wr = 1'b1;
      @(negedge clk); wr = 1'b0; addr = 16'h0000;
    end
  endtask
  task automatic bus_rd(input [15:0] a, output [7:0] d);
    begin
      @(negedge clk); addr = a; #1 d = dout;
      @(negedge clk); addr = 16'h0000;
    end
  endtask
  // Wait (without writing) until the status says not busy; give up after `lim` clk_sys.
  task automatic wait_idle(input integer lim);
    reg [7:0] s;
    integer n;
    begin
      n = 0;
      bus_rd(16'h5FF0, s);
      while (s[1] && n < lim) begin
        repeat (8) @(posedge clk);
        n = n + 10;
        bus_rd(16'h5FF0, s);
      end
    end
  endtask
  task automatic expect_offset(input integer want, input [8*40-1:0] what);
    reg [7:0] o;
    begin
      bus_rd(16'h5FF2, o);
      repeat (40) @(posedge sclk);   // let any last model step land
      if ($signed(o) != want || pll_steps != want) begin
        $display("FAIL: %0s: offset reads %0d, PLL moved %0d steps, want %0d", what,
                 $signed(o), pll_steps, want);
        fails = fails + 1;
      end else
        $display("ok: %0s: offset %0d = PLL steps %0d", what, $signed(o), pll_steps);
    end
  endtask
  task automatic expect_status(input [7:0] mask, input [7:0] want, input [8*40-1:0] what);
    reg [7:0] s;
    begin
      bus_rd(16'h5FF0, s);
      if ((s & mask) != want) begin
        $display("FAIL: %0s: status %02h (mask %02h) want %02h", what, s, mask, want);
        fails = fails + 1;
      end else
        $display("ok: %0s: status %02h", what, s);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] s;
  integer k, k2;
  // POWER-UP AS QUARTUS BUILDS IT. The qsf's ALLOW_POWER_UP_DONT_CARE lets Quartus give a register
  // any power-up value it likes when its data input is a constant, whatever its declaration
  // initializer, and Verilator always honours the initializer. Every fitted --dbg-sdram-phase build
  // tied the scan-clock engine's set-only `fault` to VCC ("Stuck at VCC due to stuck port data_in"
  // in z486_mister.map.rpt), so the instrument read a fault at power-up and never stepped. The
  // bench therefore starts that flag at 1, before the first clock edge, and the controller's own
  // sticky copy too (the power-up core reset must clear it); the instrument must not depend on
  // either value.
  initial begin
    #1 dps.fault_q = 1'b1;
    ctl.fault_st = 1'b1;
  end
  // The crossing contract (pc9821_sdram_dps FLT_LEAD): `fault` is settled at least two scan clocks
  // before every step_ack toggle, so the controller's synchroniser cannot see the ack first.
  // Sampled one edge late: `flt_lead` is how many scan edges separate fault's last change from the
  // edge that just toggled step_ack (0 = the same edge).
  reg     ack_prev = 1'b0;
  reg     flt_prev = 1'b0;
  integer flt_lead = 1000;
  always @(posedge sclk) begin
    if (fault !== flt_prev) flt_lead = 0; else flt_lead = flt_lead + 1;
    if (step_ack !== ack_prev && flt_lead < 2) begin
      $display("FAIL: step_ack toggled %0d scan clocks after fault last changed (needs >= 2)",
               flt_lead);
      fails = fails + 1;
    end
    ack_prev <= step_ack;
    flt_prev <= fault;
  end
  initial begin
    repeat (10) @(posedge clk);
    @(negedge clk) reset = 1'b0;
    repeat (10) @(posedge clk);
    // Present, idle, nominal.
    expect_status(8'hFF, 8'hA0, "power-up: present, idle, unarmed");
    expect_offset(0, "power-up");

    // A requested offset is walked to, one step per PLL pulse, and reads back.
    bus_wr(16'h5FF2, 8'd5);
    expect_status(8'h02, 8'h02, "walking: busy");
    wait_idle(1500);
    expect_offset(5, "target +5");
    if (pulses != 5) begin $display("FAIL: %0d PHASEEN pulses for 5 steps", pulses); fails = fails + 1; end

    // Step commands: earlier x3, later x1, nominal.
    for (k = 0; k < 3; k = k + 1) begin bus_wr(16'h5FF0, 8'h02); wait_idle(1500); end
    expect_offset(2, "three steps earlier");
    bus_wr(16'h5FF0, 8'h01); wait_idle(1500);
    expect_offset(3, "one step later");
    bus_wr(16'h5FF0, 8'h03); wait_idle(1500);
    expect_offset(0, "back to nominal (command 03)");
    expect_status(8'h0F, 8'h00, "nominal: not busy, not armed");

    // A negative request; then the guest goes silent: the watchdog walks it back.
    bus_wr(16'h5FF2, 8'hF9);          // -7
    wait_idle(1500);
    expect_offset(-7, "target -7");
    expect_status(8'h05, 8'h01, "armed, not reverted");
    repeat (WDOG_CYC + 2000) @(posedge clk);
    expect_offset(0, "watchdog returned to nominal");
    expect_status(8'h04, 8'h04, "reverted is set");
    bus_wr(16'h5FF0, 8'h04);
    expect_status(8'h04, 8'h00, "command 04 clears reverted");

    // Keepalive writes every ~1 ms hold a shifted phase for many watchdog periods.
    bus_wr(16'h5FF2, 8'd3); wait_idle(1500);
    for (k = 0; k < 5 * WDOG_MS; k = k + 1) begin
      repeat (90) @(posedge clk);
      bus_wr(16'h5FF0, 8'h00);
    end
    expect_offset(3, "held by keepalives");
    expect_status(8'h04, 8'h00, "no revert under keepalives");

    // The colliding pair: a write in the cycle the watchdog would expire. The write wins.
    @(negedge clk);
    while (!(ctl.tick_wrap && ctl.ms == WDOG_MS - 1)) @(negedge clk);
    addr = 16'h5FF0; din = 8'h00; wr = 1'b1;     // presented in the expiry cycle
    @(negedge clk); wr = 1'b0; addr = 16'h0000;
    expect_offset(3, "write in the expiry cycle: no revert");
    expect_status(8'h04, 8'h00, "write at expiry: reverted clear");

    // A core reset requests nominal.
    @(negedge clk); reset = 1'b1; @(negedge clk); reset = 1'b0;
    wait_idle(1500);
    expect_offset(0, "core reset returns to nominal");

    // Saturation at the signed range (checked on the request; no walk is waited for).
    bus_wr(16'h5FF2, 8'h7F); bus_wr(16'h5FF0, 8'h01);
    if (ctl.target != 8'sd127) begin $display("FAIL: +1 past +127 wrapped"); fails = fails + 1; end
    bus_wr(16'h5FF2, 8'h80); bus_wr(16'h5FF0, 8'h02);
    if (ctl.target != -8'sd128) begin $display("FAIL: -1 past -128 wrapped"); fails = fails + 1; end
    bus_wr(16'h5FF0, 8'h03);
    wait_idle(20000);
    expect_offset(0, "after the saturation checks");

    // A PLL that never answers: fault, no further stepping, no wedge.
    stuck = 1'b1;
    bus_wr(16'h5FF2, 8'd2);
    repeat (2000) @(posedge clk);
    expect_status(8'h08, 8'h08, "a dead PLL sets fault");
    k = pulses;
    repeat (2000) @(posedge clk);
    if (pulses != k) begin $display("FAIL: stepping continued after fault"); fails = fails + 1; end
    if (ctl.pending) begin $display("FAIL: the controller is wedged with a step in flight"); fails = fails + 1; end

    // The colliding pair: a core reset in the very cycle a timed-out step is acknowledged. Set wins
    // (R3): the timeout is still reported. One step is requested on the dead PLL; the reset is
    // presented in the acknowledge's cycle.
    @(negedge clk); reset = 1'b1; @(negedge clk); reset = 1'b0;
    expect_status(8'h08, 8'h00, "core reset clears fault");
    @(negedge clk);
    while (!ctl.step_failed) @(negedge clk);
    reset = 1'b1;                                  // presented in the failing ack's cycle
    @(negedge clk); reset = 1'b0;
    expect_status(8'h08, 8'h08, "reset at a failing ack: fault still set");

    // Recovery: the PLL answers again and a core reset clears fault; stepping resumes with exactly
    // one PLL step per request. (Each timed-out step above was counted without a PLL move, the
    // documented "off by one" per timeout, so this checks the PLL's own count across one request.)
    stuck = 1'b0;
    repeat (300) @(posedge sclk);
    @(negedge clk); reset = 1'b1; @(negedge clk); reset = 1'b0;
    wait_idle(5000);
    repeat (40) @(posedge sclk);
    expect_status(8'h0A, 8'h00, "after the reset: idle, no fault");
    k = pulses;
    k2 = pll_steps;
    bus_wr(16'h5FF0, 8'h01);
    wait_idle(5000);
    repeat (40) @(posedge sclk);
    bus_rd(16'h5FF2, s);
    if (pulses != k + 1 || pll_steps != k2 + 1 || $signed(s) != 1) begin
      $display("FAIL: after recovery one request gave %0d pulses, %0d PLL steps, offset %0d (want 1, 1, 1)",
               pulses - k, pll_steps - k2, $signed(s)); fails = fails + 1;
    end else
      $display("ok: after recovery: one request, one PLL step, offset 1");
    expect_status(8'h0A, 8'h00, "recovered: idle, no fault");

    // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_SDRAM_PHASE: %0d check(s) failed", fails);
    $display("TB_PC9821_SDRAM_PHASE: PASS");
    $finish;
  end
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_SDRAM_PHASE: timeout");
  end
endmodule
