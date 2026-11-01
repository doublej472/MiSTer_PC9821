`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The controller's speculative pre-ACT really moves the row activate off the accept's serial path: with port 0 running a 4-dword read and port 1 holding a read, a BankActivate carrying PORT 1's row/bank lands on the pins between port 0's first and last response, the reserved request then reads back the exact dword written to its address, the ready for it is still one per transaction and still after port 0's last response (so the response-order contract the TDM bench asserts is untouched), the same port-0 read with port 1 silent puts no ACT inside the data phase, and every ACT/REFRESH is still T_RC apart with every READ T_RCD after its ACT.

// ---- the bench's own account of where each expectation comes from ----
// The controller's IDLE accepted only after a transaction's LAST data word, so the next
// transaction's BankActivate could not begin until the previous one had fully drained and the
// row activate's T_RCD followed the ready. Every bench before this one drove ONE requester at a
// time, so the only request the arbiter could see during a drain was the one that had already
// been served -- and the early ACT is invisible unless a DIFFERENT port is asking while port 0
// drains.
//
//  1. THE EARLY ACT OVERLAPS THE DATA PHASE, AND CARRIES THE RESERVED REQUEST'S ROW. Port 1's
//     request is raised as port 0's is accepted and held for the whole of port 0's 4-dword burst,
//     so the arbiter's pick is port 1 from the moment port 0's CAS commands are out. The ACT that
//     appears while port 0 has answered at least one word and has not yet raised burst_done must
//     decode to port 1's own row/bank -- a controller that activated anything else would read the
//     wrong cells below. [source: sdram.v's READ state, the pnd_valid/pnd_go/pnd_age reservation]
//
//  2. THE ACCEPT CONTRACT IS UNCHANGED. The reservation is HELD, not acknowledged: ready1 is a
//     one-cycle pulse that lands AFTER port 0's last response, exactly as the un-reordered
//     controller's would, so the response-order rule tb_pc9821_sdram_tdm asserts is preserved.
//     [source: sdram.v's IDLE, the pnd_take arm]
//
//  3. THE RESERVATION IS NOT A FIXED-ADDRESS TRICK. With the SAME port-0 read and NO port-1
//     request, no ACT may appear inside the data phase at all: the early ACT is caused by a
//     pending request, not by the read's shape. [phase 2 below]
//
//  4. THE PIN TIMING IS STILL LEGAL. Every ACT/REFRESH is at least T_RC apart and every READ is
//     at least T_RCD after its ACT -- the same chip-side rules tb_pc9821_sdram asserts, checked
//     here because the early ACT moves the ACT/READ pair without moving the accept.
//     [source: sdram.v's header timing table; T_RC = 6 and T_RCD = 2 at 100 MHz]
//
// Nothing here is taken from a capture: the expected row/bank is decoded from the addresses the
// bench itself presents, and the overlap is a relation between two pin events and one response.

module tb_pc9821_sdram_preact;
  // 100 MHz: the clock the TDM schedule runs at, so T_RC and T_RCD are the values that schedule
  // was sized against. FREQ is a parameter and the timing table follows it.
  localparam integer FREQ = 100_000_000;
  localparam integer CYCLE_NS = 10;
  localparam integer T_RCD = 2;                     // ns_to_cycles(18) at 100 MHz
  localparam integer T_RC  = 6;                     // ns_to_cycles(60) at 100 MHz
  localparam integer CAS   = 3;                     // CL3 at 100 MHz and up (sdram.v CAS_I, the 2026-10-13 hardware cutover)

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg resetn = 0;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
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

  // ADQM = 0 (the default), the same shape the other SDRAM benches drive.
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

  // The chip model checks tRP for real: a BankActivate that
  // reaches a bank still inside its auto-precharge is fatal. The values are the controller's
  // own derived ones for this config -- 100 MHz, FAST_GRADE=1: T_RP = ns_to_cycles(18) = 2,
  // T_WR = ns_to_cycles(12) = 2 -- sourced from the JEDEC minima, not fitted to the RTL.
  sdram_chip_model #(.CAS(CAS), .T_RP(2), .T_WR(2), .FREQ_HZ(FREQ), .GRADE(6)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_preact: %0s (cycle %0d)", what, cyc);
    end
  endtask

  localparam [2:0] CMD_ACT = 3'b011;
  localparam [2:0] CMD_WR  = 3'b100;
  localparam [2:0] CMD_RD  = 3'b101;
  // The pins, read the way tb_pc9821_sdram reads them, so the tRC and T_RCD rules below are the
  // same rules that bench states.
  wire [2:0] cmd = nCS ? 3'b111 : {nRAS, nCAS, nWE};

  // The two addresses this bench moves. A is port 0's 4-dword read; B is port 1's 1-dword read.
  // They differ in ROW but share a bank, so the reservation has to honour tRP and tRC -- the less
  // forgiving case, and the one a wrong early ACT would break. That also makes this the directed
  // ACT-after-PRE case for the tRP guard: port 0's last READ-A starts the bank's precharge, and
  // the reserved ACT to B's row lands in the same bank -- pre-fix (rp_need = halves + T_RP) it
  // arrives T_RCD-2 cycles before tRP permits and the chip model $fatals; post-fix the ACT is
  // measured from the read data's completion and is legal.
  localparam [26:0] A_ADDR = 27'h0000_2000;         // 64MB: bank 0, row 4
  localparam [26:0] B_ADDR = 27'h0001_0000;         // 64MB: bank 0, row 32
  wire [1:0]  b_bank = B_ADDR[25:24];
  wire [12:0] b_row  = B_ADDR[23:11];

  integer phase = 0;                // 1 = the overlap case, 2 = the negative control
  reg     a_drain = 1'b0;           // port 0 has answered a word and has not raised burst_done
  reg     done0_seen = 1'b0;
  integer overlap_acts   = 0;       // ACTs carrying B's row, seen while port 0 drains
  integer premature_acts = 0;       // ANY ACT seen while port 0 drains with port 1 not asking
  reg     ready1_after_done0 = 1'b0;
  integer acts_seen  = 0;
  integer cmds_seen  = 0;
  integer last_act_cyc = -1000;
  integer last_row_cyc = -1000;     // the later of the last ACT and the last REFRESH

  always @(posedge clk) begin
    if (resetn) begin
      // a_drain brackets port 0's data phase: set by its first response, cleared by burst_done,
      // which is pulsed WITH its last response.
      if (resp_valid0) a_drain <= 1'b1;
      if (burst_done0) begin
        a_drain    <= 1'b0;
        done0_seen <= 1'b1;
      end
      if (ready1 && !ready1_after_done0) ready1_after_done0 <= done0_seen;

      if (cmd == CMD_ACT) begin
        acts_seen <= acts_seen + 1;
        // 4. the chip's own rules: no two ACT/REFRESH inside T_RC, no READ/WRITE before T_RCD.
        if ((cyc - last_row_cyc) < T_RC)
          fail("two ACT/REFRESH commands closer than T_RC");
        last_row_cyc <= cyc;
        last_act_cyc <= cyc;
        // 1. the early ACT, if it is the reserved request's row and port 0 is draining.
        if (a_drain && ({SDRAM_BA, SDRAM_A} == {b_bank, b_row}))
          overlap_acts <= overlap_acts + 1;
        // 3. and the control: with port 1 silent, nothing may be activated mid-drain.
        if (phase == 2 && a_drain && !valid1) begin
          premature_acts <= premature_acts + 1;
          $display("     ACT BA=%0d A=%04x during port 0's drain with no request pending",
                   SDRAM_BA, SDRAM_A);
        end
      end else if (cmd == CMD_RD || cmd == CMD_WR) begin
        cmds_seen <= cmds_seen + 1;
        if ((cyc - last_act_cyc) < T_RCD)
          fail("a READ or WRITE was issued sooner than T_RCD after the ACTIVATE");
      end
    end
  end

  // ==== STIMULUS ====
  integer guard;

  task automatic write1(input [26:0] a, input [31:0] d);
    begin
      addr0 = a; din0 = d; be0 = 4'hF; wr0 = 1; burst_cnt0 = 4'd1; valid0 = 1;
      guard = 0;
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (guard >= 400) fail("a write was never accepted");
      valid0 = 0;
      while (busy) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  // One 4-dword read on port 0. Port 1's request is raised in the cycle port 0's is accepted and
  // held to its own accept, so the arbiter sees it for the whole of port 0's drain. `driven_b`
  // selects the negative control (phase 2), where port 1 stays silent.
  task automatic read4_on_p0(input driven_b, output integer got, output [31:0] w0,
                             output [31:0] w1, output [31:0] w2, output [31:0] w3);
    integer got1;
    reg [31:0] last1;
    begin
      got = 0; w0 = 32'hDEAD_0000; w1 = 32'hDEAD_0001;
      w2 = 32'hDEAD_0002; w3 = 32'hDEAD_0003;
      addr0 = A_ADDR; wr0 = 0; be0 = 4'hF; burst_cnt0 = 4'd4; valid0 = 1;
      guard = 0;
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (guard >= 400) fail("the port-0 read was never accepted");
      valid0 = 0;
      if (driven_b) begin
        addr1 = B_ADDR; wr1 = 0; be1 = 4'hF; burst_cnt1 = 4'd1; valid1 = 1;
      end
      // Collect port 0's burst, and land on the last response (which is burst_done).
      guard = 0;
      while (!burst_done0 && guard < 400) begin
        @(posedge clk);
        if (resp_valid0) begin
          case (got)
            0: w0 = dout0;
            1: w1 = dout0;
            2: w2 = dout0;
            default: w3 = dout0;
          endcase
          got = got + 1;
        end
        guard = guard + 1;
      end
      if (guard >= 400) fail("the port-0 burst never completed");
      if (driven_b) begin
        // 2. port 1's accept must still be one per transaction, i.e. after port 0's last data.
        guard = 0;
        while (!ready1 && guard < 400) begin @(posedge clk); guard = guard + 1; end
        if (guard >= 400) fail("the held port-1 request was never accepted");
        @(posedge clk);
        if (!ready1_after_done0)
          fail("port 1 was accepted before port 0's last response -- the accept order moved");
        valid1 = 0;
        guard = 0;
        // The reserved request was made with burst_cnt1 = 1, so it must answer exactly ONE word
        // and raise burst_done1 with it. The reserved-take arm reads its burst/be/din from the
        // PRE-ACT reservation's latches (S2-j): a take that read any other port's field (the
        // burst_buf <= burst_cnt0 mutant, which would give this 1-entry read port 0's 4-dword
        // shape) answers more than once and fails here, as well as in the RTL's own equality
        // check (pnd_take_contract, sdram.v).
        got1 = 0; last1 = 32'hxxxx_xxxx;
        guard = 0;
        while (!burst_done1 && guard < 400) begin
          @(posedge clk);
          if (resp_valid1) begin
            got1  = got1 + 1;
            last1 = dout1;
          end
          guard = guard + 1;
        end
        if (guard >= 400)
          fail("the reserved port-1 read never raised burst_done1");
        if (got1 != 1) begin
          fail("the reserved 1-entry read produced != 1 response -- the take read the wrong port's burst");
          $display("     got %0d responses, last %08x", got1, last1);
        end else if (last1 !== 32'hB0B0_1234) begin
          fail("the reserved request read the wrong cells");
          $display("     got %08x want B0B01234", last1);
        end else
          $display("NOTE sdram_preact: the reserved port-1 read returned B0B01234 in exactly one response");
        while (busy) @(posedge clk);
        repeat (4) @(posedge clk);
      end
    end
  endtask

  initial begin
    // WATCHDOG. A regression that wedges a wait must fail, not hang the tier.
    #4_000_000;
    $fatal(1, "TB_PC9821_SDRAM_PREACT: watchdog expired");
  end

  initial begin
    integer got;
    reg [31:0] w0, w1, w2, w3;

    repeat (6) @(posedge clk);
    resetn = 1;
    guard = 0;
    while (busy && guard < 60000) begin @(posedge clk); guard = guard + 1; end
    if (busy) $fatal(1, "TB_PC9821_SDRAM_PREACT: the controller never left init");

    // Seed the cells both reads fetch. Port 0 writes both, so port 1's later read of the same
    // word is what proves the early ACT opened the right row.
    write1(A_ADDR + 27'd0,  32'hA0A0_0000);
    write1(A_ADDR + 27'd4,  32'hA0A0_0001);
    write1(A_ADDR + 27'd8,  32'hA0A0_0002);
    write1(A_ADDR + 27'd12, 32'hA0A0_0003);
    write1(B_ADDR,          32'hB0B0_1234);

    // ---- phase 1: the overlap ----
    phase = 1;
    read4_on_p0(1'b1, got, w0, w1, w2, w3);
    if (overlap_acts == 0)
      fail("no BankActivate carrying port 1's row appeared while port 0 was draining -- the ACT never left the accept");
    else
      $display("NOTE sdram_preact: port 1's BankActivate landed inside port 0's data phase (%0d time(s))",
               overlap_acts);

    if (got != 4) begin
      fail("port 0's 4-dword burst did not produce four responses");
    end else if (w0 !== 32'hA0A0_0000 || w1 !== 32'hA0A0_0001 ||
                 w2 !== 32'hA0A0_0002 || w3 !== 32'hA0A0_0003) begin
      fail("port 0's burst data was corrupted across the early ACT");
      $display("     got %08x %08x %08x %08x", w0, w1, w2, w3);
    end else
      $display("NOTE sdram_preact: port 0's four written dwords came back in order through the overlap");

    // ---- phase 2: the control. Same port-0 read, port 1 silent: no mid-drain ACT may appear ----
    phase = 2;
    read4_on_p0(1'b0, got, w0, w1, w2, w3);
    if (premature_acts != 0)
      fail("an ACT landed inside port 0's data phase with no other request pending");
    else
      $display("NOTE sdram_preact: with port 1 silent, no ACT landed inside the data phase");

    if (acts_seen < 4 || cmds_seen < 8)
      fail("the bench did not put enough commands on the pins to be measuring anything");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_SDRAM_PREACT: FAIL (%0d errors)", errors);
    $display("TB_PC9821_SDRAM_PREACT: PASS");
    $finish;
  end
endmodule
