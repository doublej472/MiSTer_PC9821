`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_GATHER_MAP: the G3 gather-RMW session's slot maps are a pure function of the accepted byte-enable masks, so REGISTERING them at the accept (the Class-2 stage that takes the entry-count -> gk_wmap -> dq_out cone off the clk_sdram critical path) is value-identical: across 1..4-entry sessions with byte, half and full-dword enables, the merged half-WRITE data stream on the pins matches an independent software model of the pre-change behaviour in the same slot order, the auto-precharge rides the last write alone, and a read issued behind the session sees every stored byte (only the internal cycle count may change, never a value).

// ==== DUT ====
// sdram_sync_bridge (the controller on clk_sys, as every build runs it) over the
// real src/memory/sdram.v against sdram_chip_model on port 0, at a 50 MHz clk_sys
// (`TB_SDRAM_FREQ, sdram_sync_bench.svh). The gather request is the port-0 shape: gath0 qualifying a
// write of burst_cnt0 (1..GATHER_K) same-row entries, entry 0 on addr0/din0/be0 and
// entries 1.. on gath0_extra ({addr[26:0], din[31:0], be[3:0]} per entry). The write
// DATA STREAM is pinned directly off the DQ pins on every WRITE command (the slot-map
// register's only observable), not re-derived from the controller.

module tb_pc9821_sdram_gather_map;
  localparam integer CAS = 2;                        // CAS_I = 2 below 100 MHz
  localparam integer GK = 4;                         // the session size under test
  localparam integer GENT_W = 27 + 32 + 4;

  // ==== DUT ====
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;                     // 50 MHz: requesters, controller and pins
  wire clk = clk_sys;                                // the pin monitors' clock: the controller's
  reg reset = 1;
  reg resetn = 0;

  reg         valid0 = 0, wr0 = 0, gath0 = 0;
  reg  [26:0] addr0 = 0;
  reg  [31:0] din0 = 0;
  reg   [3:0] be0 = 4'hF;
  reg   [3:0] burst0 = 4'd1;
  reg [440:0] gath0_extra = 441'd0;
  wire        ready0;
  wire [31:0] dout0;
  wire        resp_valid0;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;
  wire        busy;

  sdram_sync_bridge #(
      .FREQ(`TB_SDRAM_FREQ), .FAST_GRADE(1'b0), .GATHER_K(GK)
  ) backend (
      .clk(clk_sys), .resetn(resetn),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0),
      .din0(din0), .din0_hi(32'd0), .gath0(gath0), .gath0_extra(gath0_extra),
      .dout0(dout0), .resp_valid0(resp_valid0),
      .be0(be0), .burst_cnt0(burst0),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0),
      .dout1(), .resp_valid1(), .be1(4'd0), .burst_cnt1(4'd0),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0),
      .dout2(), .resp_valid2(), .be2(4'd0), .burst_cnt2(4'd0),
      .valid3(1'b0), .ready3(), .wr3(1'b0), .addr3(27'd0), .din3(32'd0),
      .dout3(), .resp_valid3(), .be3(4'd0), .burst_cnt3(4'd0),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  sdram_chip_model #(.CAS(CAS), .T_RP(`TB_CHIP_TRP), .T_WR(`TB_CHIP_TWR),
                   .FREQ_HZ(`TB_SDRAM_FREQ), .GRADE(7)) chip (
      .clk(clk_sys), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // Bound: a stream that never completes is a FAIL, not a stall.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_SDRAM_GATHER_MAP: FAIL watchdog (the run did not finish)");
  end

  // ==== CHECKS ====
  integer errors = 0;

  // The write data stream, captured off the DQ pins on every WRITE command (nCS=0,
  // nRAS=1, nCAS=0, nWE=0), armed around exactly one request's lifetime. DQ is the
  // controller's dq_out (dq_oen=0 for the whole write command cycle), so this is the
  // slot-map register's only observable, in emission order.
  reg        cap_on = 0;
  integer    got_wcnt = 0;
  reg [15:0] got_wdat [0:15];
  reg        got_wap  [0:15];
  always @(posedge clk) begin
    if (cap_on && !nCS && nRAS && !nCAS && !nWE) begin
      got_wdat[got_wcnt] = DQ;
      got_wap[got_wcnt]  = SDRAM_A[10];
      got_wcnt = got_wcnt + 1;
    end
  end

  task automatic capture_start;
    begin
      cap_on = 1'b0;
      @(negedge clk);
      got_wcnt = 0;
      cap_on = 1'b1;
    end
  endtask
  task automatic capture_stop;
    begin
      @(negedge clk);
      cap_on = 1'b0;
    end
  endtask

  // Build one gather request's extra payload: entry j (1..) is {addr, din, be}.
  function automatic [440:0] pack_extras(
      input [26:0] a1, input [31:0] d1, input [3:0] b1,
      input [26:0] a2, input [31:0] d2, input [3:0] b2,
      input [26:0] a3, input [31:0] d3, input [3:0] b3);
    reg [440:0] x;
    begin
      x = 441'd0;
      x[0*GENT_W +: GENT_W] = {a1, d1, b1};
      x[1*GENT_W +: GENT_W] = {a2, d2, b2};
      x[2*GENT_W +: GENT_W] = {a3, d3, b3};
      pack_extras = x;
    end
  endfunction

  // One gather request: hold until the accept, then leave the request line.
  task automatic gath_req(
      input integer n,
      input [26:0] a0, input [31:0] d0, input [3:0] b0,
      input [440:0] extras);
    integer guard;
    begin
      @(negedge clk_sys);
      addr0 = a0; din0 = d0; be0 = b0; burst0 = 4'(n);
      gath0 = 1'b1; gath0_extra = extras; wr0 = 1'b1; valid0 = 1'b1;
      guard = 0;
      @(posedge clk_sys);
      while (!ready0 && guard < 2000) begin @(posedge clk_sys); guard = guard + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_GATHER_MAP: no accept for a gather of %0d", n);
      @(negedge clk_sys);
      valid0 = 1'b0; gath0 = 1'b0; wr0 = 1'b0;
    end
  endtask

  // One ordinary single-dword write (the preload).
  task automatic wr_single(input [26:0] a, input [31:0] d, input [3:0] b);
    integer guard;
    begin
      @(negedge clk_sys);
      addr0 = a; din0 = d; be0 = b; burst0 = 4'd1;
      gath0 = 1'b0; wr0 = 1'b1; valid0 = 1'b1;
      guard = 0;
      @(posedge clk_sys);
      while (!ready0 && guard < 2000) begin @(posedge clk_sys); guard = guard + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_GATHER_MAP: no accept for a write");
      @(negedge clk_sys);
      valid0 = 1'b0; wr0 = 1'b0;
    end
  endtask

  // One dword read, through the same port: the response path.
  task automatic rd32(input [26:0] a, output [31:0] d);
    integer guard;
    begin
      @(negedge clk_sys);
      addr0 = a; be0 = 4'hF; burst0 = 4'd1; gath0 = 1'b0; wr0 = 1'b0; valid0 = 1'b1;
      guard = 0;
      @(posedge clk_sys);
      while (!ready0 && guard < 2000) begin @(posedge clk_sys); guard = guard + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_GATHER_MAP: no accept for a read");
      @(negedge clk_sys);
      valid0 = 1'b0;
      guard = 0;
      while (!resp_valid0 && guard < 2000) begin @(negedge clk_sys); guard = guard + 1; end
      if (!resp_valid0) $fatal(1, "TB_PC9821_SDRAM_GATHER_MAP: no response for a read");
      d = dout0;
      @(negedge clk_sys);
    end
  endtask

  task automatic expect_dword(input [26:0] a, input [31:0] want, input string what);
    reg [31:0] got;
    begin
      rd32(a, got);
      if (got !== want) begin
        errors = errors + 1;
        $display("FAIL sdram_gather_map: %0s at %06x: got %08x want %08x", what, a, got, want);
      end
    end
  endtask

  // Four same-row columns (large geometry: 512 dword columns per 2 KiB row), entry j's
  // address, all {row 2, bank 0}.
  localparam [26:0] A0 = 27'h000_1000;               // col 0
  localparam [26:0] A1 = 27'h000_1024;               // col 9
  localparam [26:0] A2 = 27'h000_1040;               // col 16
  localparam [26:0] A3 = 27'h000_1080;               // col 32

  function automatic [26:0] addr_of(input integer j);
    begin
      case (j)
      0: addr_of = A0;
      1: addr_of = A1;
      2: addr_of = A2;
      default: addr_of = A3;
      endcase
    end
  endfunction

  // ==== CHECKS: the independent software model of the pre-change behaviour ====
  // mem[j] tracks the 32-bit contents of A_j. compute_session derives, from the
  // request alone and the CURRENT mem, the ordered merged half-WRITE stream and the
  // post-session mem -- the OLD combinational slot-map behaviour written out by hand,
  // never read back from the controller.
  reg [31:0] mem [0:3];
  integer    exp_wcnt = 0;
  reg [15:0] exp_wdat [0:15];

  task automatic compute_session(
      input integer n,
      input [31:0] d0, input [31:0] d1, input [31:0] d2, input [31:0] d3,
      input [3:0]  b0, input [3:0]  b1, input [3:0]  b2, input [3:0]  b3);
    integer j, h;
    reg [3:0]  beh, be;
    reg [31:0] oldw, dinw;
    begin
      exp_wcnt = 0;
      for (j = 0; j < n; j = j + 1) begin
        case (j)
        0: begin oldw = mem[0]; dinw = d0; be = b0; end
        1: begin oldw = mem[1]; dinw = d1; be = b1; end
        2: begin oldw = mem[2]; dinw = d2; be = b2; end
        default: begin oldw = mem[3]; dinw = d3; be = b3; end
        endcase
        for (h = 0; h < 2; h = h + 1) begin
          beh = (h == 1) ? be[3:2] : be[1:0];
          if (beh != 2'b00) begin
            if (h == 0)
              exp_wdat[exp_wcnt] = {be[1] ? dinw[15:8] : oldw[15:8],
                                    be[0] ? dinw[7:0]  : oldw[7:0]};
            else
              exp_wdat[exp_wcnt] = {be[3] ? dinw[31:24] : oldw[31:24],
                                    be[2] ? dinw[23:16] : oldw[23:16]};
            exp_wcnt = exp_wcnt + 1;
          end
        end
        if (be[1:0] != 2'b00)
          mem[j][15:0] = {be[1] ? dinw[15:8] : oldw[15:8],
                          be[0] ? dinw[7:0]  : oldw[7:0]};
        if (be[3:2] != 2'b00)
          mem[j][31:16] = {be[3] ? dinw[31:24] : oldw[31:24],
                           be[2] ? dinw[23:16] : oldw[23:16]};
      end
    end
  endtask

  // One full session: derive the expected stream + post-memory from the model, drive
  // the gather, capture the real stream off the pins, compare DATA and ORDER (never
  // the cycle at which a write appears), then read every touched entry back.
  task automatic run_gather(
      input integer n,
      input [31:0] d0, input [3:0] b0,
      input [31:0] d1, input [3:0] b1,
      input [31:0] d2, input [3:0] b2,
      input [31:0] d3, input [3:0] b3,
      input string tag);
    integer k, j;
    begin
      compute_session(n, d0, d1, d2, d3, b0, b1, b2, b3);
      // Let the previous request's own pin writes finish before arming the capture: a ready is
      // the ACCEPT, not the completion, and it is delivered before the accepted write reaches the
      // pins (the removed clock-domain bridge's ack crossing used to hide that).
      repeat (20) @(posedge clk_sys);
      capture_start;
      gath_req(n, addr_of(0), d0, b0,
               pack_extras(addr_of(1), d1, b1, addr_of(2), d2, b2, addr_of(3), d3, b3));
      // Let the session run to its exit (a fixed generous wait, NOT a cycle pin: the
      // internal session length is free to move).
      repeat (60) @(posedge clk_sys);
      capture_stop;

      if (got_wcnt != exp_wcnt) begin
        errors = errors + 1;
        $display("FAIL sdram_gather_map: %0s expected %0d merged writes, captured %0d",
                 tag, exp_wcnt, got_wcnt);
      end
      for (k = 0; k < exp_wcnt; k = k + 1) begin
        if (got_wdat[k] !== exp_wdat[k]) begin
          errors = errors + 1;
          $display("FAIL sdram_gather_map: %0s write slot %0d data: got %04x want %04x",
                   tag, k, got_wdat[k], exp_wdat[k]);
        end
      end
      for (k = 0; k < exp_wcnt; k = k + 1) begin
        if (got_wap[k] !== (k == exp_wcnt - 1)) begin
          errors = errors + 1;
          $display("FAIL sdram_gather_map: %0s write slot %0d auto-precharge: got %b want %b",
                   tag, k, got_wap[k], (k == exp_wcnt - 1));
        end
      end
      for (j = 0; j < n; j = j + 1)
        expect_dword(addr_of(j), mem[j], tag);
    end
  endtask

  initial begin
    @(negedge clk_sys);
    reset = 0; resetn = 1;
    repeat (30000) @(posedge clk_sys);               // past the controller's 200 us JEDEC init

    // Preload a known pattern (the plain-write half of the read/write mix), so every
    // merge below folds over recognisable old lanes and never relies on unwritten RAM.
    wr_single(A0, 32'h1111_2222, 4'hF);
    wr_single(A1, 32'h3333_4444, 4'hF);
    wr_single(A2, 32'h5555_6666, 4'hF);
    wr_single(A3, 32'h7777_8888, 4'hF);
    mem[0] = 32'h1111_2222;
    mem[1] = 32'h3333_4444;
    mem[2] = 32'h5555_6666;
    mem[3] = 32'h7777_8888;

    // ---- 1: four entries, one byte each (be = 1,2,4,8) ----
    // Four read slots and four write slots, low/high half interleaved by entry order.
    run_gather(4,
               32'hAAAA_AA0A, 4'h1,
               32'h0000_BB00, 4'h2,
               32'h00CC_0000, 4'h4,
               32'hDD00_0000, 4'h8,
               "check 1 (4-entry byte session)");

    // ---- 2: mixed full dword + byte + full half (be = F,1,C) ----
    run_gather(3,
               32'hDEAD_BEEF, 4'hF,
               32'h0000_00CC, 4'h1,
               32'hCAFE_0000, 4'hC,
               32'h0000_0000, 4'h0,
               "check 2 (mixed full/byte/half)");

    // ---- 3: the 1-entry session (the column stream's leftover shape) ----
    run_gather(1,
               32'h0000_0077, 4'h1,
               32'h0000_0000, 4'h0,
               32'h0000_0000, 4'h0,
               32'h0000_0000, 4'h0,
               "check 3 (1-entry byte session)");

    // ---- 4: two full halves (be = 3,C): NO reads, two writes ----
    run_gather(2,
               32'h0000_1234, 4'h3,
               32'h5678_0000, 4'hC,
               32'h0000_0000, 4'h0,
               32'h0000_0000, 4'h0,
               "check 4 (two full halves)");

    // ---- 5: a gather then a read behind it (accept order is visibility order) ----
    run_gather(2,
               32'h0000_0011, 4'h1,
               32'h0000_0022, 4'h1,
               32'h0000_0000, 4'h0,
               32'h0000_0000, 4'h0,
               "check 5 (gather then read)");
    // A read of an address the session did NOT touch must still see its own value,
    // proving the session neither clobbered a neighbour nor left the port wedged.
    expect_dword(A2, 32'hCAFE_6666, "check 5 untouched neighbour");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_GATHER_MAP: PASS");
    end else begin
      $fatal(1, "TB_PC9821_SDRAM_GATHER_MAP: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
