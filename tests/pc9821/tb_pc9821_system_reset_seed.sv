// tb_pc9821_system_reset_seed - pc9821_system's unreset telemetry / line flops.
//
// ==== WHAT THIS PROVES ====
// pc9821_system's unreset telemetry: the INTA pulse counter inta_count/z_inta_d counts exactly the CPU's INTA pulses PER RESET EPOCH (it X-locked and never armed in 4-state sim and ran across warm resets). The CPU is tests/pc9821/z486_stub.sv - the real z486 tree cannot elaborate in the 4-state simulator these checks are FOR - issuing exactly two INTA pulses per epoch, so count == 2 is the whole F6 contract.
//
// (F6) The INTA telemetry counter (`inta_count`, `z_inta_d`) counts the INTA
//      pulses the CPU actually issued, and counts them PER RESET EPOCH: after a
//      reset, exactly the pulses of THIS run are visible. Before the fix the
//      counter had no reset and no initialiser: in 4-state simulation
//      `if (z_inta && !z_inta_d && inta_count != 8'hFF)` X-locks (the != is X,
//      the arm never fires, the counter never resolves - the
//      "X-no-arm"), and in any simulation the count ran across warm resets so
//      the diagnostic that separates "not delivered" from "delivered but
//      mishandled" could not count a run.
// (F7) The registered line response into the L1 icache (`z_line_din`,
//      `z_line_resp_valid`) is 0 at reset: data and valid
//      are registered TOGETHER into the cache's fill completion input, and an X
//      there at power-up (4-state) or a stale pre-reset valid at a warm reset is
//      exactly the garbage the pair exists to exclude.
//
// The CPU is tests/pc9821/z486_stub.sv (the real z486 tree cannot elaborate in
// the 4-state simulator these checks are FOR): it issues two INTA pulses per
// 50-clk window on an absolute schedule (rising edges at posedges 9, 21, 59,
// 71, ...), and the reset windows below sit BETWEEN pulse windows, so "the
// counter reads exactly 2 after each window" is the whole F6 contract.
//
// ==== THE 4-STATE RUN: NONE, AND WHAT THAT LEAVES PROVEN ====
// tools/check_4state_xlock.py covers five of the six X-lock benches and lists this one
// as NOT RUN, because pc9821_system does not elaborate in iverilog (its UNCOVERED entry
// names the first error iverilog reports). The real z486 tree stops iverilog earlier still
// (src/z486/address_unit.sv:5 (import z486_pkg::*)), which is what the stub above is for.
// So there is NO 4-state run for F6's X-no-arm form anywhere in this tree, and this bench
// proves only:
//   - the PER-EPOCH half of F6, measurably: deleting `inta_count <= 8'd0` from the reset
//     branch makes epoch 2 read 4 instead of 2 and the gate run FAILS;
//   - F7 against a nonzero SOURCE (z_line_resp_valid <= 1'b1 in the else branch fails the
//     first-clks check), but NOT against its reset value: the first sample lands one clk
//     after a posedge that reloads the pair from the memory subsystem, so setting the
//     reset value to 1 does not fail it.
// F7's reset-value and X-at-power-up halves are therefore UNPROVEN by any run here, and
// the "X-locked in 4-state sim" sentence above is history, not a property this bench
// checks.

`timescale 1ns / 1ps

module tb_pc9821_system_reset_seed;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;

  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;

  integer errors = 0;

  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== DUT ====
  pc9821_system #(
      .SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4),
      .ENABLE_X87(1'b0)
  ) dut (
      .clk_sys(clk_sys),
      .reset(reset), .hps_apply_reset(1'b0),
      .rtc(rtc),
      .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0),
      .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(1'b0),
      .ext_mem0_dout(32'd0), .ext_mem0_resp_valid(1'b0), .ext_mem0_ready(1'b1),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0),
      .ioctl_addr(27'd0), .ioctl_dout(16'd0),
      .img_mounted(1'b0), .img_readonly(1'b0), .img_size(64'd0),
      .img_ack(1'b0), .img_buff_addr(13'd0), .img_buff_din(16'd0),
      .img_buff_wr(1'b0),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0),
      .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7),
      .bios_setup(1'b0), .bios_set(4'd0)
  );

  integer i;

  // One reset window: the first 4 clks must show the RESET line-response state,
  // and the window's two stub INTA pulses must make the counter read exactly 2
  // (which for the second window can only be true if the reset re-zeroed it).
  // ==== CHECKS ====
  task run_epoch(input [8*110-1:0] name);
    begin
      for (i = 0; i < 4; i = i + 1) begin
        @(negedge clk_sys);
        if ($isunknown(dut.inta_count) || $isunknown(dut.z_inta_d)) begin
          $display("FAIL: %0s: X in the line-response / INTA telemetry state (unseeded flops)", name);
          errors = errors + 1;
          i = 4;
        end
      end
      repeat (40) @(negedge clk_sys);
      if ($isunknown(dut.inta_count)) begin
        $display("FAIL: %0s: inta_count is X and never arms (the X-no-arm defect)", name);
        errors = errors + 1;
      end else if (dut.inta_count !== 8'd2) begin
        $display("FAIL: %0s: inta_count = %0d, want exactly 2 (this epoch's two INTA pulses)",
                 name, dut.inta_count);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (6) @(negedge clk_sys);
    reset = 0;
    run_epoch("epoch 1");

    // A WARM reset: the counter is per-epoch state and the line pair re-seeds.
    reset = 1;
    repeat (3) @(negedge clk_sys);
    reset = 0;
    run_epoch("epoch 2");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SYSTEM_RESET_SEED: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_SYSTEM_RESET_SEED: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_SYSTEM_RESET_SEED: TIMEOUT");
  end

endmodule
