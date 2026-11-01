`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_TRACE:
// The instruction trace records one ring entry per EIP transition carrying the cycles spent at that PC, commits the PC it is stuck on with a saturated dwell so the stall itself is in the ring, wraps without losing the newest transitions, and dumps it oldest-first as ASCII hex framed by a header, a labelled stall-context line, and a footer; and it arms its stall detector only after real transitions, so a reset is not mistaken for a wedge. The context line carries the address of the transaction the CPU was waiting on when the detector fired, with its write bit and the valid/ready/response flags beside it, and the font port's own request valid - the one thing a ring of past PCs cannot say, and the field a raw capture needs labelled because nothing else tells an operator what a bare hex run means.
//
// The DUT is driven with a synthetic instruction stream - a list of (CS, EIP) pairs held for a
// known number of cycles - so every expected entry is computed from the stimulus alone and not
// from the RTL. The readout is then decoded positionally: the header is 9 bytes, every record is
// exactly 20 bytes and the footer is 13, so a shifted, dropped or reordered byte fails on an
// offset rather than on a value.
//
// THE STALLED PC IS THE POINT. A record is normally written when the CPU LEAVES a PC, so the PC
// it is stuck on would never be written at all; the last scenario holds one PC and requires the
// ring to contain it with dwell 0xFFFF, which is the single record the whole module exists for.

`default_nettype none

module tb_pc9821_trace;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg         reset = 1'b1;
  reg  [15:0] cs = 16'hF800;
  reg  [31:0] eip = 32'h0000_0100;
  reg         out_ready = 1'b1;
  // The outstanding request the context line reports. Held constant, because the module LATCHES it
  // at the stall and a moving stimulus would not test the latch.
  reg  [31:0] ctx_addr = 32'h000A_8000;
  reg         ctx_write = 1'b1;
  reg         ctx_valid = 1'b1;
  reg         ctx_ready = 1'b0;
  reg         ctx_resp_valid = 1'b0;
  // The font port, the other requester into the same SDRAM controller. Driven to 1 in one scenario
  // so the field is proved to carry its own value and not just mirror the flags beside it.
  reg         ctx_fmem_valid = 1'b0;
  // The freeze request (pc9821_system trace_trig: a drawing burst's end or a page flip). Scenario 5.
  reg         trig = 1'b0;

  wire [7:0]  out_byte;
  wire        out_we;

  // ==== DUT ====

  // 8 records, so the wrap happens inside a short scenario; 24 cycles to a stall, so the last
  // scenario can hold one PC long enough without padding the run.
  pc9821_trace #(
      .AW(3),
      .STALL_CYCLES(24),
      .ARM_RECORDS(3)
  ) dut (
      .clk(clk), .reset(reset), .cs(cs), .eip(eip),
      .ctx_addr(ctx_addr), .ctx_write(ctx_write),
      .ctx_valid(ctx_valid), .ctx_ready(ctx_ready),
      .ctx_resp_valid(ctx_resp_valid),
      .ctx_fmem_valid(ctx_fmem_valid),
      .trig(trig),
      .out_ready(out_ready), .out_byte(out_byte), .out_we(out_we)
  );

  // ==== CHECKS ====

  reg [7:0] cap [0:1023];
  integer   capn = 0;
  integer   errors = 0;

  always @(posedge clk) begin
    if (out_we) begin
      cap[capn] = out_byte;
      capn = capn + 1;
    end
  end

  localparam integer LINE = 20;
  localparam integer HDRL = 9;
  localparam integer FTRL = 13;
  // "CTX A=AAAAAAAA W=v V=v R=v S=v F=v" plus CR and LF. The context line sits between the header
  // and the first record, so every record offset below is measured from HDRL + CTXL.
  localparam integer CTXL = 36;

  function [3:0] unhex(input [7:0] c);
    if (c >= "0" && c <= "9")      unhex = c - "0";
    else if (c >= "A" && c <= "F") unhex = c - "A" + 4'd10;
    else                           unhex = 4'hF;   // an impossible nibble, so a bad byte is caught
  endfunction

  function [15:0] f16(input integer b);
    f16 = {unhex(cap[b]), unhex(cap[b+1]), unhex(cap[b+2]), unhex(cap[b+3])};
  endfunction

  function [31:0] f32(input integer b);
    f32 = {unhex(cap[b]), unhex(cap[b+1]), unhex(cap[b+2]), unhex(cap[b+3]),
           unhex(cap[b+4]), unhex(cap[b+5]), unhex(cap[b+6]), unhex(cap[b+7])};
  endfunction

  // The record at line i, as the three fields it carries.
  task automatic get_rec(input integer i, output [15:0] r_cs, output [31:0] r_eip,
                         output [15:0] r_dw);
    integer b;
    begin
      b = HDRL + CTXL + i * LINE;
      r_cs  = f16(b);
      r_eip = f32(b + 5);
      r_dw  = f16(b + 14);
    end
  endtask

  // The context line's labelled fields, read positionally like the records: the address is eight
  // hex characters at offset 6, and the four flags are one nibble each after their label.
  function [31:0] ctx_addr_of(input integer b); ctx_addr_of = f32(b + 6); endfunction
  function [3:0]  ctx_wr_of  (input integer b); ctx_wr_of   = unhex(cap[b + 17]); endfunction
  function [3:0]  ctx_v_of   (input integer b); ctx_v_of    = unhex(cap[b + 21]); endfunction
  function [3:0]  ctx_r_of   (input integer b); ctx_r_of    = unhex(cap[b + 25]); endfunction
  function [3:0]  ctx_s_of   (input integer b); ctx_s_of    = unhex(cap[b + 29]); endfunction
  function [3:0]  ctx_f_of   (input integer b); ctx_f_of    = unhex(cap[b + 33]); endfunction

  task automatic expect_line(input integer i, input [15:0] e_cs, input [31:0] e_eip,
                             input [15:0] e_dw);
    reg [15:0] g_cs, g_dw;
    reg [31:0] g_eip;
    begin
      get_rec(i, g_cs, g_eip, g_dw);
      if (g_cs !== e_cs || g_eip !== e_eip || g_dw !== e_dw) begin
        errors = errors + 1;
        $display("  FAIL  entry %0d: got %04X:%08X dwell %04X, expected %04X:%08X dwell %04X",
                 i, g_cs, g_eip, g_dw, e_cs, e_eip, e_dw);
      end
    end
  endtask

  task automatic check(input bit cond, input [255:0] what);
    if (!cond) begin
      errors = errors + 1;
      $display("  FAIL  %0s", what);
    end
  endtask

  // Hold the current PC for `cycles` clock edges and let the recording counters run.
  task automatic hold(input integer cycles);
    integer k;
    begin
      for (k = 0; k < cycles; k = k + 1) @(posedge clk);
    end
  endtask

  task automatic set_pc(input [15:0] n_cs, input [31:0] n_eip);
    begin
      cs = n_cs; eip = n_eip;
    end
  endtask

  task automatic do_reset();
    begin
      reset = 1'b1; capn = 0;
      repeat (3) @(posedge clk);
      reset = 1'b0;
    end
  endtask

  integer i;
  integer n_rec;
  reg [15:0] rec_cs0, rec_dw0;
  reg [31:0] rec_eip0;

  // ==== VERDICT ====
  initial begin

    // ---- Scenario 1: one entry per transition, dwell = the cycles held minus the arrival cycle,
    //      and the stalled PC committed with a saturated dwell.
    do_reset();
    set_pc(16'hF800, 32'h0000_0100); hold(5);
    set_pc(16'hF800, 32'h0000_0105); hold(5);
    set_pc(16'hF800, 32'h0000_0110); hold(5);
    set_pc(16'hF800, 32'h0000_012B); hold(40);   // long enough to stall
    hold(400);                                   // let the dump finish

    check(cap[0] === 8'h0D && cap[1] === 8'h0A, "header starts with CR LF");
    check(cap[2] === "T" && cap[3] === "R" && cap[4] === "A" && cap[5] === "C" && cap[6] === "E",
          "header spells TRACE");
    check(cap[7] === 8'h0D && cap[8] === 8'h0A, "header ends with CR LF");

    // ==== THE CONTEXT LINE, and it is why this instrument exists: the ring says where the CPU had
    // been, and this says what it was waiting for, which is what a wedge cannot otherwise tell you.
    check(cap[HDRL + 0] === "C" && cap[HDRL + 1] === "T" && cap[HDRL + 2] === "X",
          "the context line starts with CTX");
    check(cap[HDRL + 4] === "A" && cap[HDRL + 5] === "=", "the address field is labelled A=");
    check(cap[HDRL + 15] === "W" && cap[HDRL + 19] === "V" &&
          cap[HDRL + 23] === "R" && cap[HDRL + 27] === "S" && cap[HDRL + 31] === "F",
          "every flag is labelled W= V= R= S= F=, so a raw capture is readable");
    check(ctx_addr_of(HDRL) === 32'h000A_8000,
          "the context carries the address the CPU was waiting on");
    check(ctx_wr_of(HDRL) === 4'h1 && ctx_v_of(HDRL) === 4'h1 &&
          ctx_r_of(HDRL) === 4'h0 && ctx_s_of(HDRL) === 4'h0 && ctx_f_of(HDRL) === 4'h0,
          "and the flags as driven: a write, valid, never ready, no response, no font in flight");
    check(cap[HDRL + 34] === 8'h0D && cap[HDRL + 35] === 8'h0A,
          "the context line ends with CR LF");

    n_rec = (capn - HDRL - CTXL - FTRL) / LINE;
    check(n_rec == 4, "four entries: three transitions plus the stalled PC");

    expect_line(0, 16'hF800, 32'h0000_0100, 16'd4);
    expect_line(1, 16'hF800, 32'h0000_0105, 16'd4);
    expect_line(2, 16'hF800, 32'h0000_0110, 16'd4);
    // dwell 0xFFFF is the signature of a PC that was never left.
    expect_line(3, 16'hF800, 32'h0000_012B, 16'hFFFF);

    check(cap[HDRL + CTXL + 4*LINE + 0] === 8'h0D && cap[HDRL + CTXL + 4*LINE + 1] === 8'h0A,
          "footer starts with CR LF");
    check(cap[HDRL + CTXL + 4*LINE + 2] === "T" && cap[HDRL + CTXL + 4*LINE + 12] === 8'h0A,
          "footer spells TRACE END and ends with LF");

    $display("  scenario 1: one entry per transition, dwell carried, stalled PC committed");

    // ---- Scenario 2: the ring wraps and keeps the NEWEST transitions.
    do_reset();
    for (i = 0; i < 12; i = i + 1) begin
      set_pc(16'hF800, 32'h0000_0200 + i * 4);
      hold(3);
    end
    // Hold the last PC to stall. 12 distinct PCs give 11 leaving-commits plus the stall commit of
    // the PC it stopped on = 12 records for 8 slots, so the ring must hold PC 4..11, oldest first.
    hold(40);
    hold(400);

    check(capn == HDRL + CTXL + 8*LINE + FTRL, "a full ring dumps every slot");
    if (errors != 0) begin : show_dump
      reg [15:0] d_cs, d_dw;
      reg [31:0] d_eip;
      integer    d_i;
      for (d_i = 0; d_i < 8; d_i = d_i + 1) begin
        get_rec(d_i, d_cs, d_eip, d_dw);
        $display("  ring[%0d] = %04X:%08X dwell %04X", d_i, d_cs, d_eip, d_dw);
      end
    end
    expect_line(0, 16'hF800, 32'h0000_0200 + 4*4, 16'd2);
    expect_line(7, 16'hF800, 32'h0000_0200 + 11*4, 16'hFFFF);

    $display("  scenario 2: the ring wrapped and the newest transitions survived");

    // ---- Scenario 3: a reset PC alone must NOT look like a wedge. ARM_RECORDS is 3, so holding
    //      one PC from reset with no transitions before it must produce no dump at all.
    do_reset();
    set_pc(16'hF800, 32'h0000_0300);
    hold(120);

    check(capn == 0, "no dump before the detector has seen ARM_RECORDS transitions");

    $display("  scenario 3: the detector does not arm on a reset PC");

    // ---- Scenario 4: the FONT field carries its own value. Scenario 1 drove it low and read F=0,
    //      which a flag hard-wired to zero would also satisfy; this drives it HIGH and requires
    //      F=1, so the field is proved to be a wire and not a constant that happens to agree.
    ctx_fmem_valid = 1'b1;
    do_reset();
    set_pc(16'hF800, 32'h0000_0100); hold(5);
    set_pc(16'hF800, 32'h0000_0105); hold(5);
    set_pc(16'hF800, 32'h0000_0110); hold(5);
    set_pc(16'hF800, 32'h0000_012B); hold(40);   // long enough to stall
    hold(400);                                   // let the dump finish

    check(capn > HDRL + CTXL + FTRL, "scenario 4 produced a dump to inspect");
    check(ctx_f_of(HDRL) === 4'h1,
          "the font flag reports what it is driven with, not a constant");
    check(ctx_addr_of(HDRL) === 32'h000A_8000,
          "and the address is still the one the port was driving");
    ctx_fmem_valid = 1'b0;

    $display("  scenario 4: the font field is a real wire and not a constant");

    // ---- Scenario 5: the TRIGGER freezes a ring that never stalls. The OOM screen the trigger
    //      exists for keeps EIP moving (a timer ISR), so the stall can never fire there. A trig
    //      before the detector has armed is ignored; one after it dumps at once (well inside the
    //      24-cycle stall window), holding every transition up to and including the PC the CPU is
    //      on, whose dwell is its real count - NOT the stall's saturated 0xFFFF.
    do_reset();
    set_pc(16'hF800, 32'h0000_0400); hold(5);
    trig = 1'b1; @(posedge clk); trig = 1'b0;    // not armed yet: ignored
    hold(2);
    check(capn == 0, "a trigger before the detector arms is ignored");
    set_pc(16'hF800, 32'h0000_0404); hold(5);
    set_pc(16'hF800, 32'h0000_0408); hold(5);
    set_pc(16'hF800, 32'h0000_040C); hold(5);
    trig = 1'b1; @(posedge clk); trig = 1'b0;
    hold(3);
    check(capn > 0, "an armed trigger dumps at once, not after a stall window");
    hold(400);
    check(capn == HDRL + CTXL + 4*LINE + FTRL, "the triggered dump holds the four transitions");
    begin : trig_last
      reg [15:0] t_cs, t_dw;
      reg [31:0] t_eip;
      get_rec(3, t_cs, t_eip, t_dw);
      check(t_cs === 16'hF800 && t_eip === 32'h0000_040C, "the triggered dump ends on the live PC");
      check(t_dw !== 16'hFFFF, "a triggered commit carries its real dwell, not the stall mark");
    end
    get_rec(0, rec_cs0, rec_eip0, rec_dw0);
    check(rec_eip0 === 32'h0000_0400, "the triggered dump starts at the oldest transition");

    $display("  scenario 5: the trigger freezes a moving ring");

    if (errors != 0) begin
      $display("TB_PC9821_TRACE: FAIL (%0d error(s))", errors);
      // $fatal with a CODE AND A MESSAGE: a bare $fatal(1) does not match the structure check,
      // and the message is what makes a failing log say which bench failed.
      $fatal(1, "TB_PC9821_TRACE: FAIL (%0d error(s))", errors);
    end

    $display("TB_PC9821_TRACE: PASS");
    $finish;
  end

endmodule

`default_nettype wire
