`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPEN_BUS: the open-bus responder's phases: no combinational response, acceptance separate from the data response, all-ones data, and a line read answered as FOUR all-ones word beats on cpu_resp_valid (the L1's only fill form; there is no 128-bit line port since P3).


module tb_pc9821_open_bus;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg cpu_valid = 0, cpu_write = 0, cpu_line_read = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  // ==== DUT ====
  pc9821_open_bus dut (.*);
  integer errors = 0;
  integer n;
  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    cpu_valid = 1;

    @(negedge clk); // request captured, not accepted combinationally
    if (cpu_ready || cpu_resp_valid) begin
      $display("FAIL early open-bus response");
      errors = errors + 1;
    end
    @(negedge clk); // acceptance
    if (!cpu_ready || cpu_resp_valid) begin
      $display("FAIL acceptance phase");
      errors = errors + 1;
    end
    @(negedge clk); // separate read response
    if (cpu_ready || !cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL DWORD response phase");
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);

    cpu_valid = 1;
    cpu_line_read = 1;
    repeat (3) @(negedge clk);
    // The response cycle itself carries no beat (it did carry the old line strobe); the four
    // beats start the cycle after, exactly where the old converter put beat 0.
    if (cpu_resp_valid) begin
      $display("FAIL a line read answered in the response phase");
      errors = errors + 1;
    end
    for (n = 0; n < 4; n = n + 1) begin
      @(negedge clk);
      if (!cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF) begin
        $display("FAIL line beat %0d: resp=%b dout=%08x", n, cpu_resp_valid, cpu_dout);
        errors = errors + 1;
      end
    end
    @(negedge clk);
    if (cpu_resp_valid) begin
      $display("FAIL a fifth line beat");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_line_read = 0;
    repeat (2) @(negedge clk);

    cpu_valid = 1;
    cpu_write = 1;
    repeat (2) @(negedge clk);
    if (!cpu_ready || cpu_resp_valid || cpu_line_word_valid) begin
      $display("FAIL dropped-write acceptance");
      errors = errors + 1;
    end
    @(negedge clk);
    if (cpu_resp_valid || cpu_line_word_valid) begin
      $display("FAIL dropped write generated response");
      errors = errors + 1;
    end
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_OPEN_BUS: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_OPEN_BUS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_OPEN_BUS: TIMEOUT");
  end

endmodule
