// tb_pc9821_dmac_reset_mask - a hardware reset leaves every DMA channel masked.

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMAC_RESET_MASK: after a hardware reset every DMA channel is MASKED, so a device that raises its request on a channel the guest has programmed (mode, address, count) but not yet unmasked is never granted - no DACK, no memory access for 200 clocks - and the same request is served as soon as the guest clears the masks (register 0x1D), which proves the request path itself was live and only the reset mask held it off.

// ---- where the expectation comes from ----
//   uPD71071 / 8237-family datasheet: the RESET input clears the command, status, request and
//     temporary registers and SETS the mask register (all four channels masked), so no channel
//     serves a request until the CPU unmasks it. The chip's 0x1B master-clear command, which
//     pc9821_dmac implements as a mask-all too (NP2kai io/dmac.c dmac_o1b), is the software
//     twin of the same state.
//   This bench pins only the reset side; the clear-masks (0x1D) side is the control.
// FAIL-FIRST: a reset that leaves the mask register at 0 grants the request at once
// (mutant: `mask <= 4'h0` in the reset block).

module tb_pc9821_dmac_reset_mask;

  reg        clk = 0;
  reg        reset = 1;
  reg        sel = 0, write = 0;
  reg  [4:0] idx = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  reg  [3:0] drq = 0;
  wire [3:0] dack;
  wire       dev_we, dev_stb, dev_tc;
  wire [1:0] dev_ch;
  wire [7:0] dev_dout;
  wire [31:0] mem_addr;
  wire        mem_we;
  wire [3:0]  mem_be;
  wire [31:0] mem_din;
  wire        mem_req;
  reg         mem_resp_valid = 0;
  wire [7:0]  dout_comb_unused;

  // ==== DUT ====
  pc9821_dmac dut (
    .clk(clk), .reset(reset),
    .sel(sel), .write(write), .idx(idx), .din(din), .dout(dout), .dout_comb(dout_comb_unused),
    .dev_drq(drq), .dev_dack(dack), .dev_we(dev_we), .dev_stb(dev_stb),
    .dev_tc(dev_tc), .dev_ch(dev_ch), .dev_dout(dev_dout), .dev_din(8'h5A),
    .mem_addr(mem_addr), .mem_we(mem_we), .mem_be(mem_be), .mem_din(mem_din),
    .mem_dout(32'h11223344), .mem_req(mem_req),
    .mem_ready(mem_req), .mem_resp_valid(mem_resp_valid), .mem_tc()
  );

  always #5 clk = ~clk;

  // A backend that accepts at once and completes a read one clock later.
  always @(posedge clk) mem_resp_valid <= mem_req && !mem_we;

  integer mem_reqs = 0, dack_clks = 0;
  always @(posedge clk) begin
    if (mem_req) mem_reqs <= mem_reqs + 1;
    if (|dack) dack_clks <= dack_clks + 1;
  end

  integer errors = 0;

  // ==== STIMULUS ====
  task automatic reg_wr(input [4:0] i, input [7:0] d);
    begin
      @(negedge clk); sel <= 1; write <= 1; idx <= i; din <= d;
      @(negedge clk); sel <= 0; write <= 0;
    end
  endtask

  // ==== CHECKS ====
  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // Channel 0, memory to device, four bytes at 0: programmed but NOT unmasked.
    reg_wr(5'd11, 8'h08);   // mode (0x17)
    reg_wr(5'd0, 8'h00); reg_wr(5'd0, 8'h00);   // address
    reg_wr(5'd1, 8'h03); reg_wr(5'd1, 8'h00);   // count
    drq[0] = 1;
    repeat (200) @(negedge clk);
    if (dack_clks != 0 || mem_reqs != 0) begin
      $display("MISMATCH a masked-at-reset channel was served: dack_clks=%0d mem_reqs=%0d",
               dack_clks, mem_reqs);
      errors = errors + 1;
    end

    // Control: clearing the masks (0x1D) serves the same request.
    reg_wr(5'd14, 8'h00);
    repeat (200) @(negedge clk);
    drq[0] = 0;
    if (dack_clks == 0 || mem_reqs == 0) begin
      $display("MISMATCH the request was not served after the masks were cleared (control)");
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMAC_RESET_MASK: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_DMAC_RESET_MASK: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_DMAC_RESET_MASK: TIMEOUT");
  end

endmodule

`default_nettype wire
