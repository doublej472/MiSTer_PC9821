`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CPU_CLK: the gated CPU clock gives the CPU exactly the edges the platform's cpu_ce names - at a 90 MHz clk_sys, for Full, 33, 25, 16 and 8 MHz, the CPU's clock rises at the end of a clk_sys cycle if and only if the gate's cpu_ce was high in that cycle, the edge count is the selected rate (within one edge) and Full is every clk_sys edge - and this holds with the enable's route into the clock-control block (modelled as the falling-edge register the Cyclone V block is, after a route delay) anywhere from 0 to 10.5 ns, i.e. beyond HALF a clk_sys period: the enable path into the block is a full-period path, so the placement of the throttle's register cannot move the CPU's edges off the bridge's cycles (FAIL-FIRST: the unstaged enable, the throttle's rising-edge register straight into the block, puts the CPU's edges one cycle late at a 6.0 ns route).
//
// ---- where the expected values come from ----
// [contract] src/z486/cpu_throttle.sv's header: "cpu_ce is a REGISTERED enable: cpu_ce high
// during a clk cycle means the CPU gets the clock edge that ENDS this cycle", and
// src/pc9821/core/pc9821_cpu_clk.sv:7-21 (what the platform owes the CPU): the bridge holds
// every handshake against that same cpu_ce, so an edge in any other cycle loses a beat.
// [the block] the Cyclone V clock-control block registers `ena` on the FALLING edge of its
// input clock (pc9821_cpu_clk.sv, `.ena_register_mode("falling edge")`); the model is that
// register ANDed with the clock, as the block's output is.
// [the route] the hardware failure (docs/clock-domains.md, "The enable into the clock-control block"): placements whose
// enable route to the block exceeds half a 90 MHz period (5.56 ns) never boot below Full.
// [the rates] cpu_throttle's rate_khz() table (33000/25000/16000/8000 kHz at positions 1, 2,
// 3, 5), which tools/check_osd_contract.py ties to the OSD labels.

`default_nettype none

module tb_pc9821_cpu_clk;
  localparam integer SYS_KHZ = 90000;
  localparam realtime HALF = 5.5555;          // 90 MHz
  localparam integer NROUTE = 5;
  localparam integer ROUTE_PS [NROUTE] = '{0, 3000, 6000, 9000, 10500};

  reg clk = 0;
  always #(HALF) clk = ~clk;
  reg reset_n = 0;
  reg [3:0] speed_sel = 4'd0;

  // ==== DUT ====
  wire ce_next;
  cpu_throttle #(.CLOCK_RATE_KHZ(SYS_KHZ)) u_thr (
      .clk(clk), .reset_n(reset_n), .speed_sel(speed_sel), .cpu_ce(ce_next));

  wire [NROUTE-1:0] ce, gclk;
  integer gedges [NROUTE];
  genvar g;
  generate for (g = 0; g < NROUTE; g = g + 1) begin : R
    pc9821_cpu_clk #(.SIM_ENA_ROUTE_PS(ROUTE_PS[g])) u_gate (
        .clk(clk), .ce_next(ce_next), .ce(ce[g]), .gclk(gclk[g]));
    initial gedges[g] = 0;
    always @(posedge gclk[g]) gedges[g] = gedges[g] + 1;
  end endgenerate

  // ==== CHECKS ====
  integer errors = 0;
  integer checking = 0;
  integer seen [NROUTE];
  integer ces [NROUTE];
  integer cycles = 0;
  integer i;

  // At each rising clk edge: the cycle that ends here had ce[g] (read before the edge's
  // updates); one sample later the CPU edge count must have moved by exactly that.
  reg [NROUTE-1:0] ce_before;
  always @(posedge clk) begin
    ce_before = ce;
    for (i = 0; i < NROUTE; i = i + 1) seen[i] = gedges[i];
    #(0.5);
    if (checking) begin
      cycles = cycles + 1;
      for (i = 0; i < NROUTE; i = i + 1) begin
        if (gedges[i] - seen[i] != {31'd0, ce_before[i]}) begin
          if (errors < 12)
            $display("MISMATCH route=%0d ps sel=%0d cycle %0d: cpu_ce=%0d but %0d CPU edge(s)",
                     ROUTE_PS[i], speed_sel, cycles, ce_before[i], gedges[i] - seen[i]);
          errors = errors + 1;
        end
        if (ce_before[i]) ces[i] = ces[i] + 1;
      end
    end
  end

  function automatic integer rate(input integer sel);
    case (sel) 1: rate = 33000; 2: rate = 25000; 3: rate = 16000; 5: rate = 8000;
      default: rate = SYS_KHZ; endcase
  endfunction

  task automatic run_speed(input integer sel);
    integer n0 [NROUTE];
    integer exp, k;
    begin
      // a platform reset with the new setting, as an OSD change reaches the CPU
      @(negedge clk); reset_n = 0; speed_sel = sel[3:0];
      repeat (20) @(negedge clk);
      reset_n = 1;
      repeat (8) @(negedge clk);
      for (k = 0; k < NROUTE; k = k + 1) begin ces[k] = 0; n0[k] = gedges[k]; end
      cycles = 0; checking = 1;
      repeat (9000) @(negedge clk);
      checking = 0;
      exp = (cycles * rate(sel)) / SYS_KHZ;
      for (k = 0; k < NROUTE; k = k + 1) begin
        if (gedges[k] - n0[k] < exp - 1 || gedges[k] - n0[k] > exp + 1) begin
          $display("RATE route=%0d ps sel=%0d: %0d CPU edges in %0d cycles, expected %0d +-1",
                   ROUTE_PS[k], sel, gedges[k] - n0[k], cycles, exp);
          errors = errors + 1;
        end
      end
      $display("sel=%0d: %0d cycles, %0d CPU edges (route 0 ps), %0d expected", sel, cycles,
               gedges[0] - n0[0], exp);
    end
  endtask

  // ==== VERDICT ====
  initial begin
    #(2_000_000);
    $fatal(1, "TB_PC9821_CPU_CLK: FAIL (watchdog: the run did not finish)");
  end

  initial begin
    run_speed(0);
    run_speed(1);
    run_speed(2);
    run_speed(3);
    run_speed(5);
    if (errors != 0) $fatal(1, "TB_PC9821_CPU_CLK: FAIL (%0d errors)", errors);
    $display("TB_PC9821_CPU_CLK: PASS");
    $finish;
  end
endmodule

`default_nettype wire
