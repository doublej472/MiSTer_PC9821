`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The SDRAM controller honours its own stated timing and its consumers' handshake: a request is accepted with a one-cycle ready pulse, a read's data arrives several cycles later and never in the accept cycle, the response count equals the burst count, a partial-byte write preserves the other bytes through the read-modify-write path the DQM-less MiSTer module requires, and the 32/64/128 MB geometry decode moves the bank bits as documented. THE TWO-WORD WRITE BELONGS TO PORT 0: a burst_cnt == 2 write on requester 1 stores exactly one dword and leaves the word at addr+4 untouched, because only port 0 has an upper payload word (din0_hi).
//
// ---- the bench's own account of where each expectation comes from ----
// This is the one module in the tree with no bench at all before this one, and a week
// was lost to a bug that lived exactly here: the route-isolation fix held an ownership
// record for ONE cycle while this controller answers SEVERAL cycles later, so every
// response was dropped and the CPU waited forever on its first fetch. Every bench
// passed. So the expectations below are taken from the controller's own documented
// contract and from the chip's documented behaviour, NOT from what the RTL happens to
// do today -- a bench that asserts the current behaviour is worthless, and worse than
// worthless when it is trusted.
//
//  1. READY IS A ONE-CYCLE PULSE, AND NO TWO REQUESTERS ARE ACCEPTED TOGETHER. The
//     port list says so: "ready0 -- 1-cycle pulse: request accepted". The header adds
//     that the controller accepts only in IDLE and does not return there until a
//     transaction finishes.
//     [source: src/memory/sdram.v's port comments and its IDLE state]
//
//  2. A READ'S DATA ARRIVES SEVERAL CYCLES AFTER THE ACCEPT, NEVER IN IT. The header's
//     timing diagram pins the sequence: req in cycle 0, ack in cycle 1, and the first
//     ready (data) at cycle 5 with burst_cnt=2 -- "read latency is T_RCD + CAS +
//     2*burst_cnt - 1 cycles from ACT to last data". The RTL's own capture condition
//     is `cycle >= T_RCD + CAS + 2`. This is the property the lost week turned on, and
//     it is asserted as a FLOOR (>= T_RCD + CAS after the accept) rather than an exact
//     cycle, so the bench does not become a restatement of the implementation.
//     [source: sdram.v's header timing diagram and its READ state]
//
//  3. THE RESPONSE COUNT EQUALS THE BURST COUNT, AND burst_done COMES LAST. One
//     resp_valid per 32-bit read word, then burst_done for the whole burst.
//     [source: sdram.v's port comments]
//
//  4. A PARTIAL-BYTE WRITE PRESERVES THE OTHER BYTES. With ADQM=0 (the default) the
//     controller does not mask a write at the chip, so it must read the original word and merge
//     locally. That is the RMW_READ state, and it is invisible to any consumer unless
//     it is wrong. A full-word write followed by a one-byte write and a read-back is
//     the end-to-end test of it.
//     [source: sdram.v's RMW_READ comment "Boards without DQM must read the original
//      dword and merge bytes locally"]
//
//  5. THE GEOMETRY DECODE MOVES THE BANK BITS. The RTL selects the bank from
//     addr[25:24] for a 128 MB module and addr[24:23] otherwise, and asserts a second
//     chip select from addr[26] for 128 MB. Those are the two sizes a MiSTer module can
//     be, and getting one wrong aliases memory silently.
//     [source: sdram.v's BankActivate assignment and its sdram_size comments]
//
// Nothing here asserts a magnitude taken from a capture: the capture this tree once
// pinned I/O times to is documented as carrying a possible scale error, and the
// controller's timing comes from its own declared parameters (FREQ, T_RCD, CAS).

module tb_pc9821_sdram;
  // 50 MHz, the clock this core runs at (z486_mister.sv: CLOCK_RATE_HZ = 50_000_000).
  // FREQ is a PARAMETER, so the controller's timing table follows it rather than the
  // testbench's period; the period is matched anyway so a waveform reads honestly.
  localparam integer FREQ = 50_000_000;
  localparam integer CYCLE_NS = 20;                 // 1/50MHz
  localparam integer T_RCD = 1;                     // ns_to_cycles(18) at 50 MHz = 1
  localparam integer CAS   = 2;                     // CAS_I = 2 below 100 MHz
  // ns_to_cycles(60) at 50 MHz = 3. This was 4, taken from the FREQ<=75MHz shortcut T_RC
  // used to have; the shortcut under-counted tRC/tWR above 66.7MHz and is gone
  // from sdram.v, so the derived ceiling is what the controller emits and what this monitor
  // must assert against.
  localparam integer T_RC  = 3;
  // tREFI = 64ms / 8192 rows = 390.625 cycles at 50MHz. The controller must issue a REFRESH at
  // least this often on average; the rotation/arbiter must never push one past it. This is the
  // check the refresh path never had -- the fix under test (a counter margin for the two-cycle
  // gate plus one in-flight transaction) is what makes the interval <= TREFI_CYCLES.
  localparam integer TREFI_CYCLES = (FREQ/1000) * 64 / 8192;   // 390
  // The chip model's own AutoRefresh interval check (the dropped-refresh regression net). tREFI is 390
  // cycles here; the drop defect (a pending refresh lost at the free-running counter's wrap)
  // leaves a ~865-cycle gap, while a refresh DELIBERATELY blocked across the wrap (check G2)
  // legitimately lands up to ~540 cycles after its predecessor. 700 separates the two.
  localparam integer REFRESH_GAP_MAX = 700;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg resetn = 0;

  // ==== DUT ====
  reg         valid0 = 0, valid1 = 0;
  reg         wr0 = 0, wr1 = 0;
  reg  [26:0] addr0 = 0, addr1 = 0;
  reg  [31:0] din0 = 0, din1 = 0;
  wire [31:0] dout0, dout1;
  wire        ready0, ready1, resp_valid0, resp_valid1, burst_done0, burst_done1;
  reg  [3:0]  be0 = 4'hF, be1 = 4'hF;
  reg  [3:0]  burst_cnt0 = 4'd1, burst_cnt1 = 4'd1;
  reg  [1:0]  sdram_size = 2'd2;                    // 2 = 64MB (the DE10 default shape)
  reg         refresh_allowed = 1'b1;               // dropped by check G2
  wire        busy;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA;
  wire [1:0]  SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS;
  wire        CKE;

  // ADQM = 0 (the default): the controller does a read-modify-write for a partial byte
  // write instead of masking it at the chip.
  sdram #(
      .FREQ(FREQ),
      .FAST_GRADE(1'b1)
  ) dut (
      .clk(clk), .resetn(resetn), .nce(1'b0), .refresh_allowed(refresh_allowed),
      .busy(busy), .sdram_size(sdram_size),
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0), .din0(din0),
      .din0_hi(32'd0),
      .dout0(dout0), .resp_valid0(resp_valid0), .be0(be0), .burst_cnt0(burst_cnt0),
      .burst_done0(burst_done0),
      .valid1(valid1), .ready1(ready1), .wr1(wr1), .addr1(addr1), .din1(din1),
      .dout1(dout1), .resp_valid1(resp_valid1), .be1(be1), .burst_cnt1(burst_cnt1),
      .burst_done1(burst_done1),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0), .dout2(),
      .resp_valid2(), .be2(4'd0), .burst_cnt2(4'd0), .burst_done2(),
      .valid3(1'b0), .ready3(), .wr3(1'b0), .addr3(27'd0), .din3(32'd0), .dout3(),
      .resp_valid3(), .be3(4'd0), .burst_cnt3(4'd0), .burst_done3(),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  // The model checks tRP and the AutoRefresh interval for real:
  // an ACT into a bank still precharging $fatals, and an AutoRefresh gap over REFRESH_INTERVAL
  // $fatals. T_RP/T_WR are the controller's derived values for this config (50 MHz, FAST_GRADE
  // = 1: ns_to_cycles(18) = 1 and ns_to_cycles(12) = 1), sourced from the JEDEC minima.
  sdram_chip_model #(.CAS(CAS), .T_RP(1), .T_WR(1), .REFRESH_INTERVAL(REFRESH_GAP_MAX),
                   .FREQ_HZ(FREQ), .GRADE(6)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====

  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram: %0s (cycle %0d)", what, cyc);
    end
  endtask

  // A free-running cycle counter, so a failure names a cycle.
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // EVERY check in this clocked block reads only signals sampled in the same cycle, or
  // a register this block itself writes. That is deliberate: the first draft kept
  // counters that an initial-block task reset while this block wrote them with
  // non-blocking assignments, and the resulting races produced three failures that were
  // the bench's, not the RTL's. A bench whose own bookkeeping lies is worse than none.
  reg ready0_q = 1'b0, ready1_q = 1'b0;
  integer last_act = -1000;
  // tRC is tracked separately from last_act, because the T_RCD check below must keep
  // referring to an ACTIVATE while tRC applies to ACT and REFRESH alike. last_row_cmd
  // is the more recent of the two.
  integer last_row_cmd = -1000;
  reg [31:0] refresh_cmds = 32'd0;
  // Refresh INTERVAL: the 64ms/8192-row requirement, asserted rather than assumed. The counter
  // target must sit below tREFI by the whole gate + in-flight-transaction delay, so a controller
  // that is 1-2 cycles slow (the pre-fix bug) fails here.
  integer last_refresh = -1000;
  integer trefi_worst = 0;
  reg     trefi_check_en = 1'b0;

  always @(posedge clk) begin
    ready0_q <= ready0;
    ready1_q <= ready1;

    // 1. ready is a ONE-CYCLE pulse -- never high two cycles running.
    //    [source: sdram.v's port comment "ready0  // 1-cycle pulse: request accepted"]
    if (ready0 && ready0_q)
      fail("ready0 was high two cycles running -- it is documented as a 1-cycle pulse");
    if (ready1 && ready1_q)
      fail("ready1 was high two cycles running -- it is documented as a 1-cycle pulse");

    // 1b. Two requesters must never be accepted in the same cycle: the controller
    //     accepts only in IDLE, so one accept per transaction.
    if (ready0 && ready1)
      fail("ready0 and ready1 asserted together -- two accepts in one cycle");

    // 2. THE PROPERTY THE LOST WEEK TURNED ON. A read's response is never in the accept
    //    cycle. This is the whole reason the ownership record must outlive the accept:
    //    a consumer that records the owner for ONE cycle drops a response that arrives
    //    several cycles later, and the CPU waits forever. Asserted here as a same-cycle
    //    impossibility plus the documented latency FLOOR in the tasks below.
    if (resp_valid0 && ready0)
      fail("resp_valid0 arrived in the SAME cycle as the accept -- a one-cycle ownership record would drop this response");
    if (resp_valid1 && ready1)
      fail("resp_valid1 arrived in the SAME cycle as the accept");

    // 5. The controller's obligations TO THE CHIP, sampled on the pins. Checkable
    //    without trusting any data model, because it is a property of the command
    //    stream alone.
    //    [source: sdram.v's header -- T_RCD from ACT to a read/write, T_RC between ACTs]
    if ({nRAS, nCAS, nWE} == 3'b011) begin                  // BankActivate
      if ((cyc - last_act) < T_RC)
        fail("two BankActivate commands closer than T_RC");
      last_act <= cyc;
      last_row_cmd <= cyc;
    end else if ({nRAS, nCAS, nWE} == 3'b101 || {nRAS, nCAS, nWE} == 3'b100) begin
      if (last_act >= 0 && (cyc - last_act) < T_RCD)
        fail("a READ or WRITE was issued sooner than T_RCD after the ACTIVATE");
    end else if ({nRAS, nCAS, nWE} == 3'b001) begin          // AutoRefresh
      // tRC separates two REFRESH commands exactly as it separates two ACTs: it is the
      // minimum interval between any two ACT or REF commands, and a refresh inside
      // another refresh's tRC window is undefined behaviour rather than a tolerance.
      // A 128MB module is two chips and needs one refresh each, so this is the command
      // pair that can arrive too close together.
      // [source: sdram.v's header timing table, T_RC; and its CONFIG sequence, which
      //  spaces its own two AutoRefreshes by T_RC at cycle == T_RP + T_RC]
      if ((cyc - last_row_cmd) < T_RC)
        fail("two ACT/REFRESH commands closer than T_RC");
      last_row_cmd <= cyc;
      // And the refresh must not be pushed past tREFI. The gap covers the whole path from the
      // counter expiring, through the two-cycle gate, through whatever burst was in flight.
      if (trefi_check_en && (last_refresh >= 0)) begin
        if ((cyc - last_refresh) > trefi_worst) trefi_worst <= cyc - last_refresh;
        if ((cyc - last_refresh) > TREFI_CYCLES)
          fail("the refresh interval EXCEEDED tREFI -- a pending refresh was delayed past 64ms/8192");
      end
      last_refresh <= cyc;
      refresh_cmds <= refresh_cmds + 32'd1;
    end
  end

  // One whole read on a port, watched cycle by cycle INSIDE this task so no state is
  // shared with the clocked block. Returns the response count, the first response's
  // latency from the accept, and whether burst_done arrived.
  task automatic watched_read(input [1:0] port, input [26:0] a, input [3:0] n,
                              output integer responses, output integer first_latency,
                              output integer done_latency, output bit done);
    integer t0;
    begin
      responses = 0; first_latency = -1; done_latency = -1; done = 1'b0;
      if (port == 0) begin
        addr0 = a; burst_cnt0 = n; wr0 = 0; valid0 = 1;
        while (!ready0) @(posedge clk);
        t0 = cyc; valid0 = 0;
        while (!done && (cyc - t0) < 200) begin
          @(posedge clk);
          if (resp_valid0) begin
            responses = responses + 1;
            if (first_latency < 0) first_latency = cyc - t0;
          end
          if (burst_done0) begin done = 1'b1; done_latency = cyc - t0; end
        end
      end else begin
        addr1 = a; burst_cnt1 = n; wr1 = 0; valid1 = 1;
        while (!ready1) @(posedge clk);
        t0 = cyc; valid1 = 0;
        while (!done && (cyc - t0) < 200) begin
          @(posedge clk);
          if (resp_valid1) begin
            responses = responses + 1;
            if (first_latency < 0) first_latency = cyc - t0;
          end
          if (burst_done1) begin done = 1'b1; done_latency = cyc - t0; end
        end
      end
    end
  endtask

  // Drive a write and let it finish: the two chip-side halves and the auto-precharge.
  // Like watched_read, but captures EACH response's word in arrival order. The count and
  // burst_done are already checked; this is for pinning the CONTENT and its ORDER, which a
  // controller returning the same word four times, or the columns in reverse, would satisfy.
  task automatic watched_read4(input [26:0] a, output integer responses,
                               output [31:0] w0, output [31:0] w1,
                               output [31:0] w2, output [31:0] w3, output bit done);
    integer t0;
    begin
      responses = 0; done = 1'b0;
      w0 = 32'hDEAD_0000; w1 = 32'hDEAD_0001; w2 = 32'hDEAD_0002; w3 = 32'hDEAD_0003;
      addr0 = a; burst_cnt0 = 4'd4; wr0 = 0; valid0 = 1;
      while (!ready0) @(posedge clk);
      t0 = cyc; valid0 = 0;
      while (!done && (cyc - t0) < 200) begin
        @(posedge clk);
        if (resp_valid0) begin
          case (responses)
            0: w0 = dout0;
            1: w1 = dout0;
            2: w2 = dout0;
            3: w3 = dout0;
            default: ;
          endcase
          responses = responses + 1;
        end
        if (burst_done0) done = 1'b1;
      end
    end
  endtask

  task automatic do_write(input [1:0] port, input [26:0] a, input [31:0] d, input [3:0] be);
    integer wait_cycles;
    begin
      wait_cycles = 0;
      if (port == 0) begin
        addr0 = a; din0 = d; be0 = be; wr0 = 1; valid0 = 1;
        while (!ready0 && wait_cycles < 200) begin @(posedge clk); wait_cycles = wait_cycles + 1; end
        @(posedge clk);
        valid0 = 0;
      end else begin
        addr1 = a; din1 = d; be1 = be; wr1 = 1; valid1 = 1;
        while (!ready1 && wait_cycles < 200) begin @(posedge clk); wait_cycles = wait_cycles + 1; end
        @(posedge clk);
        valid1 = 0;
      end
      repeat (16) @(posedge clk);
    end
  endtask

  // Read one word and return it, watching inside the task.
  task automatic read_one_word(input [26:0] a, output [31:0] data, output integer latency);
    integer t0, guard;
    begin
      data = 32'hDEAD_BEEF; latency = -1; guard = 0;
      addr0 = a; burst_cnt0 = 4'd1; wr0 = 0; valid0 = 1;
      @(posedge clk);
      while (!ready0 && guard < 200) begin @(posedge clk); guard = guard + 1; end
      t0 = cyc; valid0 = 0;
      guard = 0;
      while (!resp_valid0 && guard < 200) begin @(posedge clk); guard = guard + 1; end
      if (resp_valid0) begin
        data = dout0;
        latency = cyc - t0;
      end
      while (!burst_done0 && guard < 240) begin @(posedge clk); guard = guard + 1; end
      repeat (10) @(posedge clk);
    end
  endtask

  // Write a DISTINCT word at `base` and at `base | bit`, read both back, and require both
  // to survive. A geometry decode that aliases silently drops one of them, which reaches
  // the guest as corrupted data - and in a firmware pack that is corrupted code.
  task automatic alias_check(input [1:0] size, input integer bitno, input [26:0] base);
    reg [26:0] a_lo, a_hi;
    reg [31:0] w_lo, w_hi, g_lo, g_hi;
    integer lat;
    begin
      sdram_size = size;
      a_lo = base;
      a_hi = base | (27'd1 << bitno);
      w_lo = 32'h5A5A_0000 | (size * 32'd4) | bitno[7:0];
      w_hi = 32'hA5A5_0000 | (size * 32'd4) | bitno[7:0];
      do_write(0, a_lo, w_lo, 4'hF);
      do_write(0, a_hi, w_hi, 4'hF);
      read_one_word(a_lo, g_lo, lat);
      read_one_word(a_hi, g_hi, lat);
      if (g_lo !== w_lo || g_hi !== w_hi) begin
        $display("     size=%0d bit=%0d: low read %h want %h; high read %h want %h",
                 size, bitno, g_lo, w_lo, g_hi, w_hi);
        fail("the geometry decode ALIASED: two addresses differing in ONE address bit did not hold two different words");
      end else
        $display("NOTE sdram: size %0d addr bit %0d: both words survived, no aliasing", size, bitno);
    end
  endtask

  initial begin
    integer    responses, first_latency, done_latency, lat;
    bit        done;
    reg [31:0] data, w0, w1, w2, w3;
    reg [1:0]  bank_at_64, bank_at_128;

    repeat (6) @(posedge clk);
    resetn = 1;

    // ---- The controller's mode register, REPORTED rather than asserted ----
    // sdram.v programs its mode register inside the ~200us init, and CAS latency and burst
    // type come from there -- so this is worth looking at. It is NOT an assertion, and the
    // reason is a measurement rather than a preference: the check was written as
    // 'chk(chip.mrs_seen)' and then REVERTED in sdram.v -- the MRS slot forced to another
    // command -- and it STILL PASSED. So mrs_seen is set by something other than that one
    // command, and an assertion that cannot be made to fail is not a check. Rather than ship
    // one that looks like coverage and is not, the value is printed and whoever can settle
    // it can promote it. The wait below is on `busy` alone for the same reason: depending on
    // mrs_seen would hang the bench if it ever stopped being set.
    begin : init_wait
      integer guard = 0;
      while (busy && guard < 200000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (busy) fail("the controller never left init");
      else $display("NOTE sdram: init ended %0d cycles after reset; mode register seen = %0d (REPORTED, not asserted)",
                    guard, chip.mrs_seen);
      // The refresh-interval check starts now: the CONFIG sequence's own refreshes are spaced by
      // fixed setup intervals, not by tREFI, so they must not be measured against it.
      trefi_check_en = 1'b1;
      last_refresh   = cyc;
    end
    repeat (20) @(posedge clk);

    // ---- Check A: the documented latency, on a single-word read ----
    // The header says "read latency is T_RCD + CAS + 2*burst_cnt - 1 cycles from ACT to
    // last data" and its diagram puts the accept in cycle 1 and the first data at cycle
    // 5 for burst_cnt=2. This asserts the FLOOR on the host side -- the response cannot
    // legally arrive sooner -- and reports the measured gap, so the bench states the
    // relationship rather than restating one implementation's exact cycle.
    watched_read(0, 27'h000100, 4'd1, responses, first_latency, done_latency, done);
    if (!done) fail("a single-word read never asserted burst_done");
    if (responses != 1) begin
      fail("a 1-word read did not produce exactly one response");
      $display("     saw %0d responses", responses);
    end
    if (first_latency >= 0) begin
      $display("NOTE sdram: a 1-word read was answered %0d cycles after the accept (T_RCD+CAS=%0d, documented ACT-to-last-data latency %0d)",
               first_latency, T_RCD + CAS, T_RCD + CAS + 2*1 - 1);
      if (first_latency < (T_RCD + CAS))
        fail("a response arrived before T_RCD + CAS after the accept");
    end else begin
      fail("no response to a single-word read");
    end
    repeat (20) @(posedge clk);

    // ---- Check B: the response count equals burst_cnt, and burst_done comes last ----
    watched_read(0, 27'h000200, 4'd4, responses, first_latency, done_latency, done);
    if (!done) fail("a 4-word read never asserted burst_done");
    else begin
      if (responses != 4) begin
        fail("the response count did not equal burst_cnt");
        $display("     saw %0d responses for burst_cnt=4", responses);
      end
      if (done_latency < first_latency)
        fail("burst_done arrived before the first response");
      $display("NOTE sdram: a 4-word burst produced %0d responses, the first %0d cycles after the accept and burst_done at %0d",
               responses, first_latency, done_latency);
    end
    repeat (20) @(posedge clk);

    // ---- Check C: a written word reads back ----
    do_write(0, 27'h001000, 32'hA5A5_5A5A, 4'hF);
    read_one_word(27'h001000, data, lat);
    if (lat < 0) fail("no response reading back a written word");
    else if (data !== 32'hA5A5_5A5A) begin
      fail("a written word did not read back");
      $display("     wrote A5A55A5A, read %08x", data);
    end else begin
      $display("NOTE sdram: a 32-bit word written at 0x1000 read back identical (%0d cycles)", lat);
    end
    repeat (20) @(posedge clk);

    // ---- Check D: the DQM-less partial write preserves the other bytes ----
    // With ADQM=0 a partial write is not masked at the chip, so the controller must read
    // the original word and merge locally. Straight
    // through sdram.v's RMW_READ path, and invisible to a consumer unless it is wrong.
    do_write(0, 27'h002000, 32'h1122_3344, 4'hF);
    do_write(0, 27'h002000, 32'h0000_00AA, 4'h1);
    read_one_word(27'h002000, data, lat);
    if (lat < 0) fail("no response reading back after a partial write");
    else if (data !== 32'h1122_33AA) begin
      fail("a partial byte write did not preserve the other bytes");
      $display("     wrote 11223344 then 0xAA with be=1, read %08x (expected 112233AA)", data);
    end else begin
      $display("NOTE sdram: a one-byte write through the read-modify-write path preserved the other three bytes");
    end
    repeat (20) @(posedge clk);

    // ---- Check D2: a burst's words arrive in COLUMN ORDER, with the written content ----
    // Check B asserts the COUNT and that burst_done comes last. Neither says which word is
    // which: a controller that returned the same column four times, or walked the columns
    // backwards, would satisfy every other check in this bench. Four distinct dwords are
    // written at four consecutive columns and read back as one 4-word burst.
    do_write(0, 27'h002400, 32'h1111_0000, 4'hF);
    do_write(0, 27'h002404, 32'h2222_0001, 4'hF);
    do_write(0, 27'h002408, 32'h3333_0002, 4'hF);
    do_write(0, 27'h00240C, 32'h4444_0003, 4'hF);
    watched_read4(27'h002400, responses, w0, w1, w2, w3, done);
    if (!done) fail("a 4-word burst over four written columns never completed");
    else if (w0 !== 32'h1111_0000) begin
      fail("burst word 0 is not the dword written at column 0");
      $display("     got %08x want 11110000 (word 3 was %08x)", w0, w3);
    end else if (w1 !== 32'h2222_0001) begin
      fail("burst word 1 is not the dword written at column 1");
      $display("     got %08x want 22220001", w1);
    end else if (w2 !== 32'h3333_0002) begin
      fail("burst word 2 is not the dword written at column 2");
      $display("     got %08x want 33330002", w2);
    end else if (w3 !== 32'h4444_0003) begin
      fail("burst word 3 is not the dword written at column 3");
      $display("     got %08x want 44440003", w3);
    end else begin
      $display("NOTE sdram: a 4-word burst returned the four written dwords in column order");
    end
    repeat (20) @(posedge clk);

    // ---- Check E: the second requester is live ----
    // The controller serves three requesters with requester 0 first. Only two reach the
    // DE10 backend; the loader owns the second, and nothing has ever exercised it.
    do_write(1, 27'h003000, 32'hCAFE_BABE, 4'hF);
    watched_read(1, 27'h003000, 4'd1, responses, first_latency, done_latency, done);
    if (!done || responses != 1) begin
      fail("a read on requester 1 did not complete");
      $display("     done=%0d responses=%0d", done, responses);
    end else begin
      $display("NOTE sdram: requester 1 completed a 1-word read %0d cycles after its accept", first_latency);
    end
    repeat (20) @(posedge clk);

    // ---- Check E2: the two-word write belongs to PORT 0 ----
    // The controller's opt-in pair (burst_cnt == 2) takes its second payload word from PORT 0's
    // `din0_hi`, and no other requester has such an input: the port comments and the header both
    // say "port 0's two-word pair". Every other count - and every other port - means ONE word per
    // request and the count is ignored, which is the contract every other caller relies on. Before
    // sdram.v's `ef_wr_burst` carried its port term, a burst_cnt == 2 write on requester 1 took the
    // pair path too, latched PORT 0's `din0_hi` (tied to 32'd0 in this bench and in the machine)
    // as its second word, and wrote four zero bytes at addr+4 that the caller never named. No live
    // caller presents 2 (z486's store drain is 8'd1), so this bench is the stimulus that reaches
    // it; the neighbour word is the assertion, because a pair writes it and a single word does not.
    burst_cnt1 = 4'd1;
    do_write(1, 27'h003104, 32'hB0B0_1111, 4'hF);   // the word at the pair's second dword
    addr1 = 27'h003100; din1 = 32'hC0C0_3333; be1 = 4'hF; wr1 = 1; burst_cnt1 = 4'd2; valid1 = 1;
    begin : pair_write
      integer guard = 0;
      while (!ready1 && guard < 200) begin @(posedge clk); guard = guard + 1; end
      if (guard >= 200) fail("a burst_cnt == 2 write on requester 1 was never accepted");
    end
    @(posedge clk);
    valid1 = 0; burst_cnt1 = 4'd1;
    repeat (20) @(posedge clk);
    read_one_word(27'h003100, data, lat);
    if (data !== 32'hC0C0_3333) begin
      fail("the burst_cnt == 2 write on requester 1 did not store its own word");
      $display("     read %08x want C0C03333", data);
    end else begin
      read_one_word(27'h003104, data, lat);
      if (data !== 32'hB0B0_1111) begin
        fail("a burst_cnt == 2 write on requester 1 wrote a SECOND dword: only port 0 has an upper payload word, so the word at addr+4 must be untouched");
        $display("     read %08x at addr+4, want B0B01111", data);
      end else begin
        $display("NOTE sdram: a burst_cnt == 2 write on requester 1 wrote exactly one dword (the port-0 pair's second word is not written by another port)");
      end
    end
    repeat (20) @(posedge clk);

    // ---- Check F: the geometry decode, reported ----
    // sdram.v selects the bank from addr[25:24] for a 128MB module and addr[24:23]
    // otherwise. The two sizes must not silently address the same place; the bench
    // reports what the pins do for one address at each size rather than asserting a
    // cycle-exact sample, because when the ACT lands is the scheduler's business.
    begin
      integer guard;
      sdram_size = 2'd2;
      valid0 = 1; wr0 = 0; addr0 = 27'h0200_0000; burst_cnt0 = 4'd1;
      guard = 0;
      while (!ready0 && guard < 200) begin @(posedge clk); guard = guard + 1; end
      bank_at_64 = SDRAM_BA; valid0 = 0;
      repeat (40) @(posedge clk);
      sdram_size = 2'd3;
      valid0 = 1; wr0 = 0; addr0 = 27'h0200_0000; burst_cnt0 = 4'd1;
      guard = 0;
      while (!ready0 && guard < 200) begin @(posedge clk); guard = guard + 1; end
      bank_at_128 = SDRAM_BA; valid0 = 0;
      repeat (40) @(posedge clk);
      $display("NOTE sdram: bank pins %0d at 64MB and %0d at 128MB for the same address (reported, not asserted: the sample cycle is the scheduler's)",
               bank_at_64, bank_at_128);
    end

  
    // ---- Check H: the geometry decode does not alias ----
    // Check F above REPORTS the bank pins and asserts nothing, so the geometry decode has
    // been unasserted since this bench was written. Aliasing is the failure mode a wrong
    // split actually produces, and it is SILENT - a card tolerates it until it does not -
    // so it is asserted here as DATA rather than sampled as pins: write a distinct word to
    // a pair of addresses differing in ONE bit and require both to survive.
    //
    // The bit per geometry is one that geometry's OWN decode consumes, so the sizes are
    // told apart rather than agreeing by accident:
    //   32MB : bank addr[24:23], row addr[22:10], column addr[9:2]
    //   64MB : bank addr[25:24], row addr[23:11], column addr[10:2]
    //   128MB: bank addr[25:24], row addr[23:11], column addr[10:2] (+ chip addr[26])
    // Bit 10 is the sharp one: it is the column MSB at 64MB and a ROW bit at 32MB, and the
    // 32MB column expression {1'b0, req_addr[9:2]} discards it - so if the two branches
    // were ever crossed, this is the bit that would alias.
    // [source: sdram.v:1418-1421, `col0 = req_large_buf ? addr_buf[10:2] : {1'b0, addr_buf[9:2]};`]
    //
    // NOT tested, and why: addr[26], the 128MB chip select. The chip model decides what to
    // do from nCS alone (`wire cmd = nCS ? CMD_NOP : ...`), so it treats the second chip as
    // a permanent NOP and cannot hold a value there - to the fixture the two chips are one
    // cell. That is a limitation of the model, not of the controller, and it is also why
    // the model's own key had to be widened before bank bits could be told apart at all.
    alias_check(2'd1, 9,  27'h0000_2000);   // 32MB: column MSB
    alias_check(2'd1, 10, 27'h0000_2000);   // 32MB: bit 10 is a ROW bit here
    alias_check(2'd1, 23, 27'h0000_2000);   // 32MB: a bank bit
    alias_check(2'd2, 10, 27'h0000_2000);   // 64MB: column MSB - the bit 32MB drops
    alias_check(2'd2, 11, 27'h0000_2000);   // 64MB: row LSB
    alias_check(2'd2, 24, 27'h0000_2000);   // 64MB: a bank bit
    alias_check(2'd3, 10, 27'h0000_2000);   // 128MB: column MSB within chip 0
    alias_check(2'd3, 25, 27'h0000_2000);   // 128MB: a bank bit within chip 0
    // The ROW-aliasing pair, at rows 0x000 and 0x800 exactly (bit 11 of the 13-bit row), and
    // its bit-12 sibling (rows 0x000/0x1000). The chip model's memory key used to drop row bit
    // 12, so the model itself aliased that pair and a controller with a 12-bit row wrap could
    // read back 'correctly' through the fixture's own blind spot (bench-circularity audit entry
    // 5). With the key widened to the full (bank, row, column) triple, both pairs must hold two
    // different words.
    alias_check(2'd2, 22, 27'h0000_0000);   // 64MB: row bit 11 - rows 0x000 and 0x800
    alias_check(2'd2, 23, 27'h0000_0000);   // 64MB: row bit 12 - rows 0x000 and 0x1000
    sdram_size = 2'd2;
    repeat (20) @(posedge clk);

    // ---- Check G: the REFRESH path, which no test had ever seen ----
    // Every check above completes well inside the ~390-cycle refresh interval at 50MHz, so
    // before this section no bench in this tree had ever put a REFRESH command on the
    // pins. That is a whole state machine -- REFRESH, need_refresh, refresh_cnt, and the
    // 128MB second-chip refresh -- that was in no test at all.
    //
    // This section is deliberately a TRIGGER rather than an assertion of its own. The tRC
    // rule the monitor enforces (two ACT/REFRESH commands never closer than T_RC) can only
    // fire if a refresh actually happens, and a check that cannot fire is not a check; so
    // the failure mode this guards against is the section going vacuous, which is why it
    // FAILS when no refresh appears rather than passing quietly.
    begin
      integer seen;
      seen = refresh_cmds;
      sdram_size = 2'd3;                     // 128MB: two chips, so two REFRESH commands
      repeat (1200) @(posedge clk);          // ~3 refresh intervals at 50MHz
      if (refresh_cmds == seen)
        fail("no REFRESH command in 1200 idle cycles at 128MB -- the refresh path is uncovered and the tRC check above is vacuous");
      else
        $display("NOTE sdram: %0d REFRESH commands in 1200 idle cycles at 128MB, every pair spaced by at least T_RC=%0d",
                 refresh_cmds - seen, T_RC);

      seen = refresh_cmds;
      sdram_size = 2'd2;                     // 64MB: one chip, one REFRESH per interval
      repeat (1200) @(posedge clk);
      if (refresh_cmds == seen)
        fail("no REFRESH command in 1200 idle cycles at 64MB");
      else
        $display("NOTE sdram: %0d REFRESH commands in 1200 idle cycles at 64MB; worst interval seen %0d cycles (tREFI = %0d)",
                 refresh_cmds - seen, trefi_worst, TREFI_CYCLES);
    end

    // ---- Check G2: a BLOCKED refresh is DEFERRED, not DROPPED ----
    // need_refresh used to clear whenever the free-running refresh counter wrapped through 0
    // (W = clog2(REFRESH_CYCLES+1) = 9 bits here: the request sets at 350 and the wrap-clear
    // landed 162 cycles later at 512), so a service blocked by !refresh_allowed across that
    // window was SILENTLY LOST and the next attempt waited out another whole wrap -- a ~865
    // cycle gap against tREFI's 390, and ~10.9us of row retention against 7.8125us. The fix
    // makes the request sticky until an AutoRefresh actually issues. This anchors on a real
    // refresh, blocks refresh_allowed across the set-to-wrap window, releases, and requires
    // the next AutoRefresh within 60 cycles of the release: a DEFERRAL is bounded by the block
    // itself, a DROP is bounded only by the next counter wrap.
    // The tREFI monitor is disabled across this window ON PURPOSE: pushing one refresh past
    // tREFI is this check's stimulus, not its failure mode.
    begin
      integer anchor, release_cyc, waitc;
      trefi_check_en = 1'b0;
      anchor = refresh_cmds;
      waitc = 0;
      while ((refresh_cmds == anchor) && (waitc < 4000)) begin
        @(posedge clk); waitc = waitc + 1;
      end
      if (refresh_cmds == anchor) begin
        fail("no REFRESH to anchor the blocked-refresh check on");
        trefi_check_en = 1'b1;
      end else begin
        // The refresh's service resets refresh_cnt at about -1; need_refresh then sets at
        // +350 and the pre-fix wrap-clear landed at +511. Block [340, 540] spans both.
        repeat (340) @(posedge clk);
        refresh_allowed = 1'b0;
        repeat (200) @(posedge clk);
        refresh_allowed = 1'b1;
        release_cyc = cyc;
        anchor = refresh_cmds;
        waitc = 0;
        while ((refresh_cmds == anchor) && (waitc < 4000)) begin
          @(posedge clk); waitc = waitc + 1;
        end
        if (refresh_cmds == anchor) begin
          fail("NO refresh after a blocked window -- the pending refresh was dropped");
          trefi_check_en = 1'b1;
        end else if ((cyc - release_cyc) > 60) begin
          fail("the blocked refresh was DROPPED, not deferred -- it waited out the counter wrap instead of firing at the release");
          $display("     release-to-refresh %0d cycles (a deferral is bounded by the ~200-cycle block; a drop is +350 past the wrap)",
                   cyc - release_cyc);
          trefi_check_en = 1'b1;
          last_refresh = cyc;
        end else begin
          $display("NOTE sdram: a refresh blocked across the counter wrap fired %0d cycles after the release -- deferred, not dropped",
                   cyc - release_cyc);
          trefi_check_en = 1'b1;
          last_refresh = cyc;
        end
      end
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_SDRAM: FAIL (%0d problems)", errors);
      $fatal(1, "sdram controller contract not met");
    end
  end

  // A watchdog so a hang is a named failure rather than a timeout.
  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "TB_PC9821_SDRAM: FAIL (the bench did not finish -- a request never completed)");
  end
endmodule
