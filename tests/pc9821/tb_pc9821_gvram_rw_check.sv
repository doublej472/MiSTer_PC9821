`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_RW_CHECK: the GVRAM array's CROSS-PORT read-during-write is deterministic. Port A is the CPU store, port B the scanout fetch, and they share no arbiter, so a port-B read of the exact word a port-A write commits in the SAME clk_sys is REACHABLE; the array keeps `ramstyle = "M10K, no_rw_check"` (dropping it doubles every lane at synthesis), so the module terminates that same-cycle mixed-port read with a cross-port write-forward. The bench instantiates pc9821_gvram_mem directly and drives the worst pattern - the SAME address on both ports, a write on A and a read on B in the one clk_sys - asserting the fetched word is always the whole committed word (the store's byte on every lane the store ENABLES, the array's byte elsewhere), over all 15 partial byte-enable patterns, a full-word store, a no-op store and a non-colliding read. It fails if the forward is removed and on any byte-tear across the four independent lane blocks.
//
// WHY THIS EXISTS. The M10K array carried `no_rw_check`, which makes a cross-port read-during-write
// the M10K's DONT_CARE mode rather than the read-before-write its comment claimed; the CPU store
// and the scanout fetch are independent, so the collision is reachable. The fix forwards
// the byte this edge commits on the store's enabled lanes.
// for the port-ownership analysis and the synthesis cost.

`default_nettype none

module tb_pc9821_gvram_rw_check;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  reg  [15:0] a_addr = 16'd0;
  reg  [31:0] a_din  = 32'd0;
  reg  [3:0]  a_be   = 4'hF;
  reg         a_we   = 1'b0, a_en = 1'b0;
  wire [31:0] a_dout;
  reg  [15:0] b_addr = 16'd0;
  reg         b_en   = 1'b0;
  wire [31:0] b_dout;

  pc9821_gvram_mem dut (
      .clk(clk),
      .a_addr(a_addr), .a_din(a_din), .a_be(a_be),
      .a_we(a_we), .a_en(a_en), .a_dout(a_dout),
      .b_addr(b_addr), .b_en(b_en), .b_dout(b_dout)
  );

  // ==== STIMULUS ====
  integer errors = 0;
  integer checks = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  task automatic check(input ok, input [8*160-1:0] what);
    begin
      checks = checks + 1;
      if (!ok) fail(what);
    end
  endtask

  // A preloaded word names its lane and its address, so a fetched byte says where it came from:
  // lane k's byte is (k+1) * 0x10 + addr[7:0].
  function [7:0] lane_byte(input [1:0] k, input [15:0] x);
    begin lane_byte = (8'h10 * (k + 8'd1)) + x[7:0]; end
  endfunction

  function [31:0] old_word(input [15:0] x);
    begin
      old_word = {lane_byte(2'd3, x), lane_byte(2'd2, x),
                  lane_byte(2'd1, x), lane_byte(2'd0, x)};
    end
  endfunction

  // The committed word after a store of `din` with byte enables `be`: the store's byte on every lane
  // it enables, the preloaded byte on every lane it does not (an unwritten lane is not written).
  function [31:0] committed(input [15:0] x, input [31:0] din, input [3:0] be);
    reg [31:0] o;
    begin
      o = old_word(x);
      if (be[0]) o[ 7: 0] = din[ 7: 0];
      if (be[1]) o[15: 8] = din[15: 8];
      if (be[2]) o[23:16] = din[23:16];
      if (be[3]) o[31:24] = din[31:24];
      committed = o;
    end
  endfunction

  task automatic poke(input [15:0] x);
    begin
      dut.mem0[x] = old_word(x)[ 7: 0];
      dut.mem1[x] = old_word(x)[15: 8];
      dut.mem2[x] = old_word(x)[23:16];
      dut.mem3[x] = old_word(x)[31:24];
    end
  endtask

  // The worst cross-port pattern: port A writes `x` with `din`/`be` while port B reads `x`, in the
  // SAME clk_sys. `b_dout` latches on the edge and is sampled one delta later.
  task automatic collide(input [15:0] x, input [31:0] din, input [3:0] be);
    begin
      @(negedge clk);
      a_addr = x; a_din = din; a_be = be; a_we = 1'b1; a_en = 1'b1;
      b_addr = x; b_en = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      a_en = 1'b0; a_we = 1'b0; b_en = 1'b0;
      @(posedge clk);
    end
  endtask

  // Port A's registered read-back of `x` (a read with a_we low): data is valid one clk later.
  task automatic read_a(input [15:0] x, output [31:0] d);
    begin
      @(negedge clk);
      a_addr = x; a_be = 4'hF; a_we = 1'b0; a_en = 1'b1;
      @(posedge clk);
      #1;
      d = a_dout;
      @(negedge clk);
      a_en = 1'b0;
      @(posedge clk);
    end
  endtask

  // ==== CHECKS ====
  integer k;
  integer i;
  reg [15:0] x;
  reg [31:0] din, exp, got;
  reg [3:0]  be;
  integer    n_checks_rdw, n_checks_plain;

  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (2) @(posedge clk);

    n_checks_rdw = 0;
    n_checks_plain = 0;

    // (1) No-write ports stay stale: port B sees the preload, port A reads it back.
    x = 16'h0100; poke(x);
    @(negedge clk); b_addr = x; b_en = 1'b1;
    @(posedge clk); #1; got = b_dout;
    @(negedge clk); b_en = 1'b0; @(posedge clk);
    check(got === old_word(x), "(1) port B with no write is not the preloaded word");
    read_a(x, got);
    check(got === old_word(x), "(1) port A read-back with no write is not the preloaded word");

    // (2) A same-cycle collision on a PARTIAL store: every enabled lane takes the store's byte,
    //     every other lane keeps the preloaded byte, and the write still commits.
    x = 16'h0042; poke(x);
    for (i = 1; i <= 15; i = i + 1) begin
      be = i[3:0];
      poke(x);
      din = 32'hF0A1_B2C3 ^ {be, be, be, be};
      exp = committed(x, din, be);
      collide(x, din, be);
      if (b_dout !== exp) begin
        $display("FAIL (2) x=%04x be=%b fetched %08x want committed %08x (preload %08x)",
                 x, be, b_dout, exp, old_word(x));
        errors = errors + 1;
      end else n_checks_rdw = n_checks_rdw + 1;
      // It must never be a tear: a mix of lanes the store enabled and lanes it did not.
      if ((b_dout !== old_word(x)) && (b_dout !== committed(x, din, be)))
        fail("(2) the fetched word is neither the pre-write nor the committed word (byte tear)");
      // The store committed: a later port-A read returns the same committed word.
      read_a(x, got);
      if (got !== committed(x, din, be)) begin
        $display("FAIL (2) read-back %08x want committed %08x", got, committed(x, din, be));
        errors = errors + 1;
      end
    end
    $display("NOTE gvram_rw_check: (2) partial-store collision sweep: %0d byte-enable patterns", n_checks_rdw);

    // (3) A same-cycle collision on a FULL-WORD store: the fetched word is the whole new word,
    //     never a mix across the four independent lane blocks.
    x = 16'h1F37; poke(x);
    din = 32'hDEAD_BEEF;
    collide(x, 32'hDEAD_BEEF, 4'hF);
    check(b_dout === 32'hDEAD_BEEF, "(3) a full-word store racing the fetch is not the whole new word");
    read_a(x, got);
    check(got === 32'hDEAD_BEEF, "(3) the full-word store did not commit");

    // (4) A no-op write (no byte enabled) racing the fetch: nothing is written, so the read is the
    //     pre-write word and the array keeps it.
    x = 16'h0088; poke(x);
    collide(x, 32'hFFFF_FFFF, 4'h0);
    check(b_dout === old_word(x), "(4) a no-op write changed the fetched word");
    read_a(x, got);
    check(got === old_word(x), "(4) a no-op write changed the array");

    // (5) A matching write while port B reads a DIFFERENT word is not forwarded; the other word is
    //     read whole, and the written one commits.
    x = 16'h0200; poke(x); poke(x + 16'd1);
    @(negedge clk);
    a_addr = x;         a_din = 32'h1122_3344; a_be = 4'hF; a_we = 1'b1; a_en = 1'b1;
    b_addr = x + 16'd1; b_en = 1'b1;
    @(posedge clk); #1; got = b_dout;
    @(negedge clk); a_en = 1'b0; a_we = 1'b0; b_en = 1'b0; @(posedge clk);
    check(got === old_word(x + 16'd1), "(5) a read of another word took the store's data");
    read_a(x, got);
    check(got === 32'h1122_3344, "(5) the store to another word did not commit");
    n_checks_plain = 2;

    // ==== VERDICT ====
    $display("NOTE gvram_rw_check: %0d collision check(s), %0d plain check(s), %0d error(s)",
             n_checks_rdw, n_checks_plain, errors);
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_RW_CHECK: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_GVRAM_RW_CHECK: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_GVRAM_RW_CHECK: TIMEOUT");
  end

endmodule

`default_nettype wire
