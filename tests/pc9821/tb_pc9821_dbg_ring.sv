`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DBG_RING: The debug-UART byte ring (pc9821_dbg_ring) carries every pushed byte to the UART handshake exactly once and in order through many wraps, at a 32-byte, a 2 KiB and an 8 KiB depth, with the UART stalled until the ring is as full as its room flag allows and then drained at random pace: a pointer or drain index narrower than the ring (the pn-stall instrument's 8 KiB ring with an 11-bit drain index) reads the wrong half after the first wrap and fails on a byte POSITION; room goes low exactly when fewer than MAX_REC bytes are free, so a producer that starts records only on room never overruns the ring.
//
// WHY THIS EXISTS. The first pn-stall instrument kept an 8 KiB ring with an 11-bit drain index:
// nothing was wrong at the producer, the first wrap made every later record garbage, and it took
// a hardware session to see it. The expected stream here is computed from the PUSH SEQUENCE (a
// counter-derived byte), never from the ring's own pointers.

`default_nettype none

module tb_pc9821_dbg_ring;
  // ==== DUT ====
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg  [2:0] push = 3'b000;
  reg  [7:0] din [0:2];
  wire [2:0] room;
  wire [7:0] lb [0:2];
  wire [2:0] lw;
  reg  [2:0] acc_en = 3'b000;
  wire [2:0] acc = lw & acc_en;
  pc9821_dbg_ring #(.AW(5),  .MAX_REC(8))  r5  (.clk(clk), .push(push[0]), .din(din[0]), .room(room[0]), .log_byte(lb[0]), .log_we(lw[0]), .log_accept(acc[0]));
  pc9821_dbg_ring #(.AW(11), .MAX_REC(40)) r11 (.clk(clk), .push(push[1]), .din(din[1]), .room(room[1]), .log_byte(lb[1]), .log_we(lw[1]), .log_accept(acc[1]));
  pc9821_dbg_ring #(.AW(13), .MAX_REC(40)) r13 (.clk(clk), .push(push[2]), .din(din[2]), .room(room[2]), .log_byte(lb[2]), .log_we(lw[2]), .log_accept(acc[2]));

  // ==== STIMULUS ====
  localparam integer DEPTH0 = 32, DEPTH1 = 2048, DEPTH2 = 8192;
  integer errors = 0;
  integer pushed [0:2];
  integer got    [0:2];
  integer maxrec [0:2];
  integer depth  [0:2];
  initial begin
    pushed[0] = 0; pushed[1] = 0; pushed[2] = 0;
    got[0] = 0; got[1] = 0; got[2] = 0;
    maxrec[0] = 8; maxrec[1] = 40; maxrec[2] = 40;
    depth[0] = DEPTH0; depth[1] = DEPTH1; depth[2] = DEPTH2;
  end
  // The byte expected at position n: a function of n alone.
  function automatic [7:0] pat(input integer n);
    pat = n[7:0] ^ n[15:8] ^ (n[23:16] + 8'h5A);
  endfunction

  // A private generator: $urandom(seed) returns the same value for the same seed variable.
  reg [31:0] lfsr = 32'h5EED1234;
  function automatic [31:0] rnd();
    begin
      lfsr = lfsr ^ (lfsr << 13); lfsr = lfsr ^ (lfsr >> 17); lfsr = lfsr ^ (lfsr << 5);
      rnd = lfsr;
    end
  endfunction

  // The checker: every accepted byte must be the next in the pattern.
  integer k;
  always @(posedge clk) begin
    for (k = 0; k < 3; k = k + 1) begin
      if (acc[k]) begin
        if (lb[k] !== pat(got[k])) begin
          if (errors < 20) $display("FAIL: ring %0d byte %0d is %02x, expected %02x", k, got[k], lb[k], pat(got[k]));
          errors = errors + 1;
        end
        got[k] = got[k] + 1;
      end
    end
  end

  // One producer step: push a record of `len` bytes if (and only if) room was high, one byte per
  // cycle, the way the instruments do.
  // While the UART is stalled (stall_check), room is checked EXACTLY at every record start:
  // high iff at least MAX_REC bytes are free (pushed - taken <= depth - MAX_REC), the module's
  // own contract. Every byte of the previous record has landed by this negedge.
  reg stall_check = 1'b0;
  integer room_exact_checks = 0;
  task automatic push_record(input integer ring, input integer len);
    integer i;
    begin
      @(negedge clk);
      if (stall_check) begin
        room_exact_checks = room_exact_checks + 1;
        if (room[ring] !== ((pushed[ring] - got[ring]) <= depth[ring] - maxrec[ring])) begin
          $display("FAIL: ring %0d: room=%b with %0d of %0d bytes used (MAX_REC %0d)", ring, room[ring],
                   pushed[ring] - got[ring], depth[ring], maxrec[ring]);
          errors = errors + 1;
        end
      end
      if (room[ring]) begin
        for (i = 0; i < len; i = i + 1) begin
          push[ring] = 1'b1; din[ring] = pat(pushed[ring]); pushed[ring] = pushed[ring] + 1;
          @(negedge clk);
        end
        push[ring] = 1'b0;
      end
    end
  endtask

  // used (pushed - taken) may never exceed the depth: that is an overrun, and room must prevent it
  integer used_now;
  always @(posedge clk) begin
    for (k = 0; k < 3; k = k + 1) begin
      used_now = pushed[k] - got[k];
      // +1: this model counts a byte as pushed at the negedge it is presented and as taken only
      // at the UART accept, so it reads one byte high for a cycle when a full ring is pushed and
      // drained at once; the exact room check in the stalled phase is the tight contract.
      if (used_now > depth[k] + 1) begin
        if (errors < 20) $display("FAIL: ring %0d holds %0d bytes of %0d", k, used_now, depth[k]);
        errors = errors + 1;
      end
    end
  end

  // ==== CHECKS ====
  integer rr, i, n;
  initial begin
    // 1. stalled: fill each ring through room alone, then check room dropped at the right fill
    repeat (4) @(negedge clk);
    stall_check = 1'b1;
    for (rr = 0; rr < 3; rr = rr + 1) begin
      i = 0;
      while (room[rr] && i < 20000) begin push_record(rr, 4); i = i + 1; end
      push_record(rr, 4);   // one more start with room low: checked exact, pushes nothing
      // room low means fewer than MAX_REC bytes were free when it was sampled; one more record
      // of MAX_REC could not have fit, and the pushes so far did not overrun (checked above)
      if (depth[rr] - (pushed[rr] - got[rr]) >= maxrec[rr] + 4 + 1)
        begin $display("FAIL: ring %0d: room low with %0d bytes free", rr, depth[rr] - (pushed[rr] - got[rr])); errors = errors + 1; end
      if (depth[rr] - (pushed[rr] - got[rr]) < 0)
        begin $display("FAIL: ring %0d: overran", rr); errors = errors + 1; end
    end
    stall_check = 1'b0;
    if (room_exact_checks < 100) begin
      $display("FAIL: only %0d exact room checks ran in the stalled phase", room_exact_checks); errors = errors + 1;
    end
    // 2. drain everything
    acc_en = 3'b111;
    repeat (20000) @(negedge clk);
    for (rr = 0; rr < 3; rr = rr + 1)
      if (got[rr] != pushed[rr]) begin
        $display("FAIL: ring %0d drained %0d of %0d bytes", rr, got[rr], pushed[rr]); errors = errors + 1;
      end
    // 3. several wraps with random producer and consumer pace; the 8 KiB ring needs more than
    //    2^11 and 2^13 bytes through it to expose a narrow index
    for (n = 0; n < 60000; n = n + 1) begin
      acc_en = {rnd() % 4 != 0, rnd() % 3 != 0, rnd() % 2 != 0};
      for (rr = 0; rr < 3; rr = rr + 1)
        if (rnd() % 4 == 0) push_record(rr, 1 + rnd() % maxrec[rr]);
      @(negedge clk);
    end
    acc_en = 3'b111;
    repeat (40000) @(negedge clk);
    for (rr = 0; rr < 3; rr = rr + 1) begin
      if (got[rr] != pushed[rr]) begin
        $display("FAIL: ring %0d after the random run: %0d of %0d bytes out", rr, got[rr], pushed[rr]); errors = errors + 1;
      end
      if (pushed[rr] < 4 * depth[rr]) begin
        $display("FAIL: ring %0d saw only %0d bytes: not enough to wrap four times (%0d)", rr, pushed[rr], 4 * depth[rr]); errors = errors + 1;
      end
    end
    $display("ring bytes through: 32B %0d, 2K %0d, 8K %0d", pushed[0], pushed[1], pushed[2]);

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_DBG_RING: %0d check(s) failed", errors);
    $display("TB_PC9821_DBG_RING: PASS");
    $finish;
  end

  initial begin
    #60_000_000;
    $fatal(1, "the ring bench did not finish in 60 ms of simulated time");
  end
endmodule
