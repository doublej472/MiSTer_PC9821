`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_BRIDGE: split_sdram_backend - the module z486_mister.sv instantiates - carries every requester port's whole request into the controller at the deployed settings (90 MHz, ADQM=1, FAST_GRADE=0, a 128 MB two-chip module) against two sdram_chip_model instances (chip 0 on nCS low, chip 1 on nCS high, the -7 grade's AC checks on): a port-1, port-2 and port-3 read of a chip-1 address (bit 26 set) returns the word port 0 wrote THERE and not the different word at the same offset in chip 0, and a port-1 write to chip 1 lands there; a byte-masked store on ports 1, 2 and 3 changes exactly its enabled byte and leaves the dword's other three bytes as port 0 wrote them; and refresh_allowed reaches the controller - while it is low for three tREFI intervals no AUTO REFRESH reaches the pins, and within 100 clocks of its return both chips are refreshed.
//
// WHY. The controller's own benches drive sdram.v directly, and tb_pc9821_sdram_sync drives this
// module only with a 64 MB module, full byte enables off port 0 and refresh_allowed tied high, so
// three wiring defects in this file passed every bench: port 1's address losing bit 26 (the chip
// select of a 128 MB module), port 2's byte enables forced to 4'hF, and refresh_allowed tied to 1.
// Each is a one-token edit of a port connection; each is checked here by its observable effect
// (the word read, the bytes kept, the refresh commands on the pins), not by reading the netlist.
//
// Expected values: the data are what this bench wrote (a memory returns what was stored at the
// address); chip 1 is selected by address bit 26 on a 128 MB module (docs/sdram.md: two chips on
// complementary chip selects); a masked store keeps the masked bytes (the DQM function, AS4C32M16SB
// datasheet); a controller told not to refresh issues no AUTO REFRESH.

`default_nettype none

module tb_pc9821_sdram_bridge;
  localparam integer FREQ = 90_000_000;
  localparam integer TREFI = FREQ / 128_000;        // 64 ms / 8192 rows, in clocks (703)

  reg clk = 1'b0;
  always #(1000.0 / 90 / 2.0) clk = ~clk;

  // ==== DUT ====
  reg  [3:0]       valid = 4'b0;
  reg  [3:0]       wr = 4'b0;
  reg  [3:0][31:0] addr = '0;
  reg  [3:0][31:0] din = '0;
  reg  [3:0][3:0]  be = {4{4'hF}};
  reg  [3:0][7:0]  burst = {4{8'd1}};
  wire [3:0]       ready;
  wire [3:0]       resp;
  wire [3:0][31:0] dout;
  reg              reset = 1'b1;
  reg              refresh_allowed = 1'b1;
  wire             busy;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  split_sdram_backend #(
      .FREQ(FREQ), .ADQM(1'b1), .FAST_GRADE(1'b0), .GATHER_K(4)
  ) backend (
      .clk(clk), .reset(reset), .refresh_allowed(refresh_allowed),
      .sdram_size(2'd3), .busy(busy),
      .mem0_valid(valid[0]), .mem0_ready(ready[0]), .mem0_write(wr[0]), .mem0_addr(addr[0]),
      .mem0_din(din[0]), .mem0_din_hi(32'd0), .mem0_gath(1'b0), .mem0_gath_extra(441'd0),
      .mem0_dout(dout[0]), .mem0_resp_valid(resp[0]), .mem0_be(be[0]), .mem0_burstcount(burst[0]),
      .mem1_valid(valid[1]), .mem1_ready(ready[1]), .mem1_write(wr[1]), .mem1_addr(addr[1]),
      .mem1_din(din[1]), .mem1_dout(dout[1]), .mem1_resp_valid(resp[1]), .mem1_be(be[1]),
      .mem1_burstcount(burst[1]),
      .mem2_valid(valid[2]), .mem2_ready(ready[2]), .mem2_write(wr[2]), .mem2_addr(addr[2]),
      .mem2_din(din[2]), .mem2_dout(dout[2]), .mem2_resp_valid(resp[2]), .mem2_be(be[2]),
      .mem2_burstcount(burst[2]),
      .mem3_valid(valid[3]), .mem3_ready(ready[3]), .mem3_write(wr[3]), .mem3_addr(addr[3]),
      .mem3_din(din[3]), .mem3_dout(dout[3]), .mem3_resp_valid(resp[3]), .mem3_be(be[3]),
      .mem3_burstcount(burst[3]),
      .sdram_dq(DQ), .sdram_a(SDRAM_A), .sdram_ba(SDRAM_BA), .sdram_dqm(SDRAM_DQM),
      .sdram_nwe(nWE), .sdram_nras(nRAS), .sdram_ncas(nCAS), .sdram_ncs(nCS), .sdram_cke(CKE)
  );

  // The 128 MB module: two chips on complementary chip selects, each with its own command decode,
  // refresh account and storage. The refresh-gap monitor is off here (this bench holds refresh
  // off on purpose) and the bench counts the refreshes itself.
  sdram_chip_model #(.CAS(2), .FREQ_HZ(FREQ), .GRADE(7), .CHIP_SEL(0)) chip0 (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );
  sdram_chip_model #(.CAS(2), .FREQ_HZ(FREQ), .GRADE(7), .CHIP_SEL(1)) chip1 (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====
  integer errors = 0;
  integer checks = 0;
  task automatic chk(input [31:0] got, input [31:0] want, input [8*80-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // AUTO REFRESH on the pins ({RAS#, CAS#, WE#} = 0,0,1), per chip select.
  integer aref [0:1];
  initial begin aref[0] = 0; aref[1] = 0; end
  always @(posedge clk)
    if (!nRAS && !nCAS && nWE) aref[nCS] = aref[nCS] + 1;

  task automatic settle(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(negedge clk);
    end
  endtask

  // One request on port p, held until its one-cycle ready (the requester contract).
  task automatic issue(input integer p, input bit w, input [31:0] a, input [31:0] d, input [3:0] b);
    integer g;
    begin
      @(negedge clk);
      wr[p] = w; addr[p] = a; din[p] = d; be[p] = b; burst[p] = 8'd1; valid[p] = 1'b1;
      g = 0;
      while (!ready[p] && g < 4000) begin @(negedge clk); g = g + 1; end
      if (!ready[p]) $fatal(1, "TB_PC9821_SDRAM_BRIDGE: port %0d request at %08x never accepted", p, a);
      @(negedge clk);
      valid[p] = 1'b0; wr[p] = 1'b0;
    end
  endtask

  task automatic write(input integer p, input [31:0] a, input [31:0] d, input [3:0] b);
    begin
      issue(p, 1'b1, a, d, b);
      settle(12);
    end
  endtask

  task automatic read(input integer p, input [31:0] a, output [31:0] w);
    integer g;
    begin
      issue(p, 1'b0, a, 32'd0, 4'hF);
      g = 0;
      while (!resp[p] && g < 4000) begin @(negedge clk); g = g + 1; end
      if (!resp[p]) $fatal(1, "TB_PC9821_SDRAM_BRIDGE: port %0d read at %08x never answered", p, a);
      w = dout[p];
      settle(4);
    end
  endtask

  reg [31:0] w;
  integer p;
  integer a0, a1, g;

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_SDRAM_BRIDGE: FAIL (watchdog)");
  end

  // ==== VERDICT ====
  initial begin
    settle(20);
    reset = 1'b0;
    g = 0;
    while (busy && g < 100_000) begin @(negedge clk); g = g + 1; end
    if (busy) $fatal(1, "TB_PC9821_SDRAM_BRIDGE: the controller never left its power-up init");
    settle(20);

    // ---- every port reaches chip 1 (address bit 26) and not chip 0 ----
    write(0, 32'h0000_0100, 32'hC0C0_0100, 4'hF);         // chip 0
    write(0, 32'h0400_0100, 32'hC1C1_0100, 4'hF);         // chip 1, the same offset
    for (p = 1; p < 4; p = p + 1) begin
      read(p, 32'h0400_0100, w);
      chk(w, 32'hC1C1_0100, "port 1..3 read of a chip-1 address");
      read(p, 32'h0000_0100, w);
      chk(w, 32'hC0C0_0100, "port 1..3 read of the same chip-0 offset");
    end
    write(0, 32'h0000_0200, 32'h0C0C_0200, 4'hF);
    write(1, 32'h0400_0200, 32'h1C1C_0200, 4'hF);         // port 1 writes chip 1
    read(0, 32'h0400_0200, w);
    chk(w, 32'h1C1C_0200, "port 1 write lands in chip 1");
    read(0, 32'h0000_0200, w);
    chk(w, 32'h0C0C_0200, "port 1 write leaves chip 0's word alone");

    // ---- every port's byte enables reach the controller ----
    for (p = 1; p < 4; p = p + 1) begin
      write(0, 32'h0000_0400 + p * 4, 32'h1122_3344, 4'hF);
      write(p, 32'h0000_0400 + p * 4, 32'h0000_AB00, 4'b0010);
      read(0, 32'h0000_0400 + p * 4, w);
      chk(w, 32'h1122_AB44, "port 1..3 byte store keeps the other three bytes");
    end

    // ---- refresh_allowed reaches the controller ----
    // Held low for three tREFI intervals: the controller may finish a refresh already on the pins,
    // but must start none (sdram.v issues AUTO REFRESH only from IDLE with refresh_allowed set).
    @(negedge clk);
    refresh_allowed = 1'b0;
    settle(2);
    a0 = aref[0]; a1 = aref[1];
    settle(3 * TREFI);
    checks = checks + 1;
    if ((aref[0] != a0) || (aref[1] != a1)) begin
      $display("FAIL refresh_allowed low: %0d/%0d AUTO REFRESH command(s) reached chips 0/1 while it was low",
               aref[0] - a0, aref[1] - a1);
      errors = errors + 1;
    end
    refresh_allowed = 1'b1;
    settle(100);
    checks = checks + 1;
    if ((aref[0] == a0) || (aref[1] == a1)) begin
      $display("FAIL refresh_allowed high again: chips 0/1 saw %0d/%0d AUTO REFRESH command(s) within 100 clocks (want >= 1 each, the refresh that came due while it was low)",
               aref[0] - a0, aref[1] - a1);
      errors = errors + 1;
    end
    // The memory survived the episode in the model's terms (no data was lost by the controller).
    read(1, 32'h0400_0100, w);
    chk(w, 32'hC1C1_0100, "chip-1 word after the refresh episode");

    $display("TB_PC9821_SDRAM_BRIDGE: %0d check(s), %0d error(s); AUTO REFRESH chip0 %0d chip1 %0d",
             checks, errors, aref[0], aref[1]);
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_BRIDGE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_SDRAM_BRIDGE: FAIL (%0d errors)", errors);
    end
  end
endmodule

`default_nettype wire
