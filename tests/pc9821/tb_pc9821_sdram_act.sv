`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The SDRAM address pins carry the request the arbiter GRANTED, not whatever the request mux says while the row is being activated: with all four ports changing their addresses on the accept edge itself, every BankActivate still puts the accepted request's bank and row on SDRAM_BA/SDRAM_A for the geometry in force, that row/bank then holds on the pins from the ACT until the first READ or WRITE of the same transaction, and the ACT lands exactly one cycle after the ready pulse, so the +1 clk_sdram cycle the registered ACT stage costs is accounted for instead of drifting.

// ---- the bench's own account of where each expectation comes from ----
// The controller issues its ACT from the values it latched at the accept, one cycle after the
// accept (src/memory/sdram.v's ACT state). Nothing about the
// pin-level data path said so before: every other SDRAM bench drives one request at a time and
// only ever looks at the accepted data, so a controller that re-decoded the LIVE request mux
// when it issued the ACT -- the shape that puts the arbiter back on the pin-critical path --
// would pass all of them as long as no other port changed its address in that window. That is
// what this bench makes happen.
//
//  1. THE ACT'S ROW AND BANK ARE THE ACCEPTED REQUEST'S. sdram.v decodes
//     `req_large_buf ? addr_buf[23:11] : addr_buf[22:10]` for the row and
//     `req_large_buf ? addr_buf[25:24] : addr_buf[24:23]` for the bank, from the latched
//     address. On the pins that is SDRAM_A[12:0] and SDRAM_BA -- a row is A[12:0] and nothing
//     else is, because the ACT carries no column and no auto-precharge bit.
//     [source: sdram.v's ACT state and its port comments]
//
//  2. IT IS THE ACCEPTED ADDRESS, NOT THE MUX'S. Every expectation here is checked with the
//     other three requesters presenting DIFFERENT addresses, and the accepted port's own
//     address changed, on the very edge the accept is delivered. A controller that drove the
//     pin registers from the live mux would put one of those on SDRAM_BA/SDRAM_A, and the
//     check below names which value it saw.
//
//  3. THE ROW/BANK HOLD FROM THE ACT UNTIL THE FIRST ACCESS. The chip latches the row at the
//     ACT, so the field the controller puts on A may not move until the READ/WRITE that
//     consumes it. This is the property the register exists for: a mux that re-decides every
//     cycle moves under the command.
//
//  4. THE ACT IS EXACTLY ONE CYCLE AFTER THE ready PULSE. The registered stage costs one
//     clk_sdram cycle per accepted request, and the controller's own timing table counts it
//     (REFRESH_DELAY, so the refresh interval stays inside tREFI). This pins the +1 at the
//     pins rather than leaving it to a comment, so a later edit that adds a second stage, or
//     that drops the latch and issues the ACT from the mux in the accept cycle, fails here.
//
// Nothing below is taken from a capture: the expected row/bank is decoded from the address the
// bench itself presented, and the one-cycle gap is the stage this bench exists to measure.

module tb_pc9821_sdram_act;
  // 100 MHz: the controller's own clock (clk_sdram), which is where the ACT stage lives. FREQ is
  // a parameter, so the timing table follows it; the period is matched so a waveform reads
  // honestly and so TB_CYCLE is a clk_sdram cycle.
  localparam integer FREQ = 100_000_000;
  localparam integer CYCLE_NS = 10;                 // 1/100MHz
  localparam integer T_RCD = 2;                     // ns_to_cycles(18) at 100 MHz
  localparam integer CAS   = 3;                     // CL3 at 100 MHz and up (sdram.v CAS_I, the 2026-10-13 hardware cutover)

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg resetn = 0;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  // All four requesters are driven: the check depends on the arbiter having a different
  // address to hand the mux while the ACT is being issued.
  reg         valid0 = 0, valid1 = 0, valid2 = 0, valid3 = 0;
  reg         wr0 = 0, wr1 = 0, wr2 = 0, wr3 = 0;
  reg  [26:0] addr0 = 0, addr1 = 0, addr2 = 0, addr3 = 0;
  reg  [31:0] din0 = 0, din1 = 0, din2 = 0, din3 = 0;
  wire [31:0] dout0, dout1, dout2, dout3;
  wire        ready0, ready1, ready2, ready3;
  wire        resp_valid0, resp_valid1, resp_valid2, resp_valid3;
  wire        burst_done0, burst_done1, burst_done2, burst_done3;
  reg  [3:0]  be0 = 4'hF, be1 = 4'hF, be2 = 4'hF, be3 = 4'hF;
  reg  [3:0]  burst_cnt0 = 4'd1, burst_cnt1 = 4'd1, burst_cnt2 = 4'd1, burst_cnt3 = 4'd1;
  reg  [1:0]  sdram_size = 2'd2;                    // 2 = 64MB (the DE10 default shape)
  wire        busy;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA;
  wire [1:0]  SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  // ADQM = 0 (the default): the partial-byte write below takes the read-modify-write path,
  // which issues a SECOND
  // BankActivate (RMW_ACT) that must carry the same latched row.
  sdram #(
      .FREQ(FREQ),
      .FAST_GRADE(1'b1)
  ) dut (
      .clk(clk), .resetn(resetn), .nce(1'b0), .refresh_allowed(1'b1),
      .busy(busy), .sdram_size(sdram_size),
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0), .din0(din0),
.din0_hi(32'd0),
      .dout0(dout0), .resp_valid0(resp_valid0), .be0(be0), .burst_cnt0(burst_cnt0),
      .burst_done0(burst_done0),
      .valid1(valid1), .ready1(ready1), .wr1(wr1), .addr1(addr1), .din1(din1),
      .dout1(dout1), .resp_valid1(resp_valid1), .be1(be1), .burst_cnt1(burst_cnt1),
      .burst_done1(burst_done1),
      .valid2(valid2), .ready2(ready2), .wr2(wr2), .addr2(addr2), .din2(din2),
      .dout2(dout2), .resp_valid2(resp_valid2), .be2(be2), .burst_cnt2(burst_cnt2),
      .burst_done2(burst_done2),
      .valid3(valid3), .ready3(ready3), .wr3(wr3), .addr3(addr3), .din3(din3),
      .dout3(dout3), .resp_valid3(resp_valid3), .be3(be3), .burst_cnt3(burst_cnt3),
      .burst_done3(burst_done3),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  sdram_chip_model #(.CAS(CAS), .FREQ_HZ(FREQ), .GRADE(6)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_act: %0s (cycle %0d)", what, cyc);
    end
  endtask

  localparam [2:0] CMD_ACT = 3'b011;
  localparam [2:0] CMD_WR  = 3'b100;
  localparam [2:0] CMD_RD  = 3'b101;
  wire [2:0] cmd = nCS ? 3'b111 : {nRAS, nCAS, nWE};

  // The request the STIMULUS is presenting, written BEFORE it raises valid and left alone until
  // that transaction has been activated. The monitor cannot sample the port payload at the
  // accept edge instead: the stimulus changes the payload on exactly that edge, so a monitor
  // register written there would race it and could record the decoy.
  reg [26:0] exp_addr = 27'd0;
  reg [1:0]  exp_size = 2'd0;

  reg        txn_open = 1'b0;          // a ready has been seen; its first ACT is still owed
  reg        ever_accepted = 1'b0;     // an ACT before any accept is a stray, not a transaction
  integer    txn_ready_cyc = -1000;

  reg        row_held = 1'b0;          // an ACT is outstanding with no access after it
  reg [14:0] row_bank_q = 15'd0;

  // 1/2/3/4, sampled on the pins. This block reads only pins and registers this block itself
  // writes, so it shares no state with the stimulus except exp_addr/exp_size, which the stimulus
  // writes only between transactions.
  always @(posedge clk) begin
    reg [1:0]  exp_bank;
    reg [12:0] exp_row;
    reg [14:0] pin_row_bank;
    exp_bank = exp_size[1] ? exp_addr[25:24] : exp_addr[24:23];
    exp_row  = exp_size[1] ? exp_addr[23:11] : exp_addr[22:10];
    pin_row_bank = {SDRAM_BA, SDRAM_A};

    if (ready0 || ready1) begin
      ever_accepted <= 1'b1;
      txn_open      <= 1'b1;
      txn_ready_cyc <= cyc;
    end

    if (cmd == CMD_ACT) begin
      if (!ever_accepted)
        fail("a BankActivate was issued before any request was accepted");
      if (pin_row_bank !== {exp_bank, exp_row}) begin
        fail("the ACT's bank/row is not the accepted request's");
        $display("     pins BA=%0d A=%04x, accepted addr=%07x decoded to BA=%0d A=%04x at size %0d",
                 SDRAM_BA, SDRAM_A, exp_addr, exp_bank, exp_row, exp_size);
      end
      // 4. the registered ACT stage: exactly one cycle after the ready, never the same cycle.
      if (txn_open) begin
        if ((cyc - txn_ready_cyc) != 1) begin
          fail("the first ACT of a transaction is not exactly one cycle after its ready pulse");
          $display("     ready at cycle %0d, ACT at cycle %0d", txn_ready_cyc, cyc);
        end
        txn_open <= 1'b0;
      end
      // 3. the row/bank the chip latched may not move until the access that consumes it.
      row_held   <= 1'b1;
      row_bank_q <= pin_row_bank;
    end else if (cmd == CMD_RD || cmd == CMD_WR) begin
      row_held <= 1'b0;
    end else if (row_held && (pin_row_bank !== row_bank_q)) begin
      fail("the ACT's row/bank moved before the first READ/WRITE of that transaction");
      $display("     BA/A %04x -> %04x", row_bank_q, pin_row_bank);
    end
  end

  // That the transaction still reaches the right cells. The pin check above proves WHICH
  // address was activated; this proves the data followed it. It presents its own request, so it
  // sets exp_addr as every other request in this bench does.
  task automatic check_read(input [26:0] a, input [31:0] want, input [1023:0] what);
    integer guard;
    begin
      exp_addr = a;
      exp_size = sdram_size;
      addr0 = a; burst_cnt0 = 4'd1; wr0 = 0; be0 = 4'hF; valid0 = 1;
      guard = 0;
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      valid0 = 0;
      guard = 0;
      while (!resp_valid0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (!resp_valid0) begin
        fail(what);
      end else if (dout0 !== want) begin
        fail(what);
        $display("     read %08x, wrote %08x", dout0, want);
      end
      while (busy) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  // ==== STIMULUS ====
  integer i, guard;

  // One accepted transaction with the accept window made ADVERSARIAL: the accept is delivered in
  // this cycle, and in this cycle every port's address changes -- the other three start asking
  // for addresses that differ in the bank AND the row, so the arbiter's pick (port 1, the one
  // after the accepted port 0) is a different place entirely. Only addr0 is presented before the
  // accept, so only addr0 can be the accepted address.
  //   a     : the address port 0 presents (and exp_addr, the one the ACT must carry)
  //   wr    : 0 = 1-dword read, 1 = write of `data`
  //   be    : byte enables for the write
  task automatic adversarial(input [26:0] a, input wr, input [31:0] data, input [3:0] be);
    begin
      exp_addr  = a;
      exp_size  = sdram_size;
      addr0     = a; din0 = data; be0 = be; wr0 = wr; burst_cnt0 = 4'd1; valid0 = 1;
      guard = 0;
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (guard >= 400) fail("a request was never accepted");
      // The accept is delivered in this cycle. Move the world under it.
      valid0 = 0;
      addr0  = a ^ 27'h0000_1000;                  // ignored: this port is no longer asking
      addr1  = a ^ 27'h0100_0000; valid1 = 1; wr1 = 0; be1 = 4'hF; burst_cnt1 = 4'd1;
      addr2  = a ^ 27'h0000_2000; valid2 = 1; wr2 = 0; be2 = 4'hF; burst_cnt2 = 4'd1;
      addr3  = a ^ 27'h0200_0000; valid3 = 1; wr3 = 0; be3 = 4'hF; burst_cnt3 = 4'd1;
      // Hold them through the ACT cycle and past it; the controller cannot accept another
      // request until this transaction returns to IDLE, so no decoy is ever accepted.
      repeat (3) @(posedge clk);
      valid1 = 0; valid2 = 0; valid3 = 0;
      while (busy) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  initial begin
    // WATCHDOG. A regression that wedges a wait must fail, not hang the tier.
    #2_000_000;
    $fatal(1, "TB_PC9821_SDRAM_ACT: watchdog expired");
  end

  initial begin
    repeat (6) @(posedge clk);
    resetn = 1;
    guard = 0;
    while (busy && guard < 60000) begin @(posedge clk); guard = guard + 1; end
    if (busy) $fatal(1, "TB_PC9821_SDRAM_ACT: the controller never left init");

    // Each geometry in turn: the bank and row fields move with it, so the same pin-level check
    // is a different decode at each size.
    for (i = 0; i < 3; i = i + 1) begin : geometries
      sdram_size = i[1:0] + 2'd1;                  // 1 = 32MB, 2 = 64MB, 3 = 128MB
      repeat (8) @(posedge clk);

      // ---- the ACT address, with the mux changing under it ----
      adversarial(27'h0000_1000, 1'b0, 32'd0, 4'hF);
      adversarial(27'h0000_3F00, 1'b0, 32'd0, 4'hF);
      adversarial(27'h0000_8000, 1'b0, 32'd0, 4'hF);
      adversarial(27'h0002_0000, 1'b0, 32'd0, 4'hF);
      // A write takes the same ACT path, and its T_RCD/T_DAL exit has to stay intact.
      adversarial(27'h0004_0000, 1'b1, 32'h5AA5_0000 + i, 4'hF);
      // A partial write takes the RMW path, whose SECOND BankActivate must carry the same row.
      adversarial(27'h0005_0000, 1'b1, 32'h0000_00AA, 4'h1);

      // ---- and the accepted address still reaches the right cells ----
      check_read(27'h0004_0000, 32'h5AA5_0000 + i, "the data of a written dword did not read back");
      check_read(27'h0005_0000, 32'h0000_00AA, "a partial write did not land where it was addressed");

      // ---- requester 1 takes the same path ----
      exp_addr = 27'h0006_0000;
      exp_size = sdram_size;
      addr1 = 27'h0006_0000; din1 = 32'h1234_0000 + i; be1 = 4'hF; wr1 = 1; burst_cnt1 = 4'd1;
      valid1 = 1;
      guard = 0;
      while (!ready1 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (guard >= 400) fail("a write on requester 1 was never accepted");
      valid1 = 0;
      addr1 = 27'h08FF_0000; valid1 = 1; burst_cnt1 = 4'd1; wr1 = 0;
      repeat (3) @(posedge clk);
      valid1 = 0;
      while (busy) @(posedge clk);
      repeat (4) @(posedge clk);
      check_read(27'h0006_0000, 32'h1234_0000 + i, "requester 1's write did not land where it was addressed");
    end

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_SDRAM_ACT: FAIL (%0d errors)", errors);
    $display("TB_PC9821_SDRAM_ACT: PASS");
    $finish;
  end
endmodule
