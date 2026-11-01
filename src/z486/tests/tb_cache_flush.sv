`timescale 1ns/1ns

// ==== WHAT THIS PROVES ====
// The native whole-L1 flush controller's two request paths and its done
// handshake, at the memory.sv boundary:
//
//   1. The platform `cache_flush` keeps its held-level contract: a level held
//      across a walk starts exactly one walk and does not re-arm until it is
//      released.
//   2. The instruction request is a SEPARATE input (`cache_flush_insn`).  A
//      request that arrives after the platform's `done` while the platform
//      level is still held must still start its own walk and pulse its own
//      `done`.  This is the P1 wedge: with the two requests ORed into one
//      input, the held platform level keeps the combined input high, the
//      controller never re-arms, and the instruction that is waiting on `done`
//      stalls forever.
//   3. An instruction request seen while a walk is already running is queued,
//      not dropped - including a one-cycle pulse.
//
// WHY IT EXISTS.  The platform may legally hold `cache_flush` as a level until
// after `cache_flush_done`; INVD/WBINVD may become active in the cycle after
// `done`, while that level is still high.  memory.sv now arbitrates the two
// sources internally instead of ORing them at the z486 boundary.

module tb_cache_flush;

  reg clk = 0;
  always #5 clk = ~clk;

  reg reset_n = 0;

  // Paging-unit demand request (unused here; tied idle)
  reg  [31:0] req_addr = 32'h0;
  reg  [31:0] req_wdata = 32'h0;
  reg   [3:0] req_be = 4'hF;
  reg         req_write = 1'b0;
  reg         req_valid = 1'b0;
  wire        req_accepted;
  wire        req_complete;
  wire        read_complete;
  wire [31:0] rdata;

  // Instruction-side request (unused here; tied idle)
  reg  [31:0] icache_addr = 32'h0;
  reg         icache_valid = 1'b0;
  wire        icache_accepted;
  wire        icache_complete;
  wire [127:0] icache_line;

  // Native whole-L1 flush
  reg         cache_flush = 1'b0;
  reg         cache_flush_insn = 1'b0;
  wire        cache_flush_busy;
  wire        cache_flush_done;

  // External bus (a zero-wait responder)
  wire  [31:2] addr;
  wire   [3:0] be;
  wire   [7:0] burstcount;
  wire         line_read;
  wire  [31:0] dout;
  wire         valid;
  wire         write;
  wire         io;
  wire         inta;

  reg  [31:0]  din = 32'h0;
  reg          ready = 1'b1;
  reg          resp_valid = 1'b0;
  reg  [127:0] line_din = 128'h0;
  reg          line_resp_valid = 1'b0;

  memory #(
    .DCACHE_SET_BITS(3),
    .ICACHE_SET_BITS(3)
  ) dut (
    .clk(clk),
    .reset_n(reset_n),
    .a20_enable(1'b1),
    .win0_unmapped(1'b0),
    .ram_cache_top(32'hffff_ffff),
    .device_mmio_enable(1'b0),
    .device_mmio_base(32'h0),

    .dcache_req_valid(req_valid),
    .dcache_req_phys_addr_raw(req_addr),
    .dcache_req_preread_offset(12'h000),
    .dcache_req_preread_priority(1'b0),
    .dcache_req_write(req_write),
    .dcache_req_be(req_be),
    .dcache_req_wdata(req_wdata),
    .dcache_direct_wdata(req_wdata),
    .dcache_req_is_io(1'b0),
    .dcache_req_is_inta(1'b0),
    .dcache_req_is_x87(1'b0),
    .dcache_req_is_vga_mem(1'b0),
    .dcache_req_is_pcd(1'b0), .dcache_req_is_locked(1'b0), .dcache_stores_drained_out(), .cache_cd(1'b0), .cache_nw(1'b0), .bus_locked(1'b0),
    .dcache_req_accepted(req_accepted),
    .dcache_req_complete(req_complete),
    .dcache_read_complete(read_complete),
    .dcache_rdata(rdata),

    .fast_store_valid(1'b0),
    .fast_store_phys_addr_raw(32'h0),
    .fast_store_be(4'h0),
    .fast_store_wdata(32'h0),
    .fast_store_accepted(),

    .dcache_vipt_probe_valid(1'b0),
    .dcache_vipt_probe_offset(12'h000),
    .dcache_vipt_probe_ready(),
    .dcache_vipt_probe_accepted(),
    .dcache_vipt_probe_direct_accepted(),
    .dcache_vipt_resolve_valid(1'b0),
    .dcache_vipt_resolve_phys_addr_raw(32'h0), .dcache_vipt_resolve_tlb_phys_raw(32'h0), .dcache_vipt_resolve_alt_phys_raw(32'h0), .dcache_vipt_resolve_use_tlb(1'b0),
    .dcache_vipt_resolve_hit(),
    .dcache_vipt_resolve_data(),

    .x87_req_selected(),
    .x87_req_accepted(1'b0),
    .x87_req_complete(1'b0),
    .x87_read_complete(1'b0),
    .x87_rdata(32'h0),

    .icache_req_valid(icache_valid),
    .icache_req_phys_addr_raw(icache_addr), .icache_req_is_pcd(1'b0), .icache_req_spec_ok(),
    .icache_req_accepted(icache_accepted),
    .icache_req_complete(icache_complete),
    .icache_rdata(icache_line),

    .snoop_addr(32'h0),
    .snoop_valid(1'b0),

    .cache_flush(cache_flush),
    .cache_flush_insn(cache_flush_insn),
    .cache_flush_busy(cache_flush_busy),
    .cache_flush_done(cache_flush_done),

    .addr(addr),
    .be(be),
    .burstcount(burstcount),
    .line_read(line_read),
    .din(din),
    .line_din(line_din),
    .dout(dout),
    .valid(valid),
    .ready(ready),
    .write(write),
    .io(io),
    .resp_valid(resp_valid),
    .line_resp_valid(line_resp_valid),
    .inta(inta)
  );

  // Walk/done monitors.  busy rises once per walk; done is a one-cycle pulse.
  integer walks = 0;
  integer dones = 0;
  reg     busy_r = 1'b0;
  always @(posedge clk) begin
    if (reset_n) begin
      busy_r <= cache_flush_busy;
      if (cache_flush_busy && !busy_r)
        walks <= walks + 1;
      if (cache_flush_done)
        dones <= dones + 1;
    end else begin
      busy_r <= 1'b0;
    end
  end

  integer errors = 0;

  task automatic check(input condition, input [8*64-1:0] what);
    begin
      if (condition) begin
        $display("  ok  %0s", what);
      end else begin
        $display("FAIL %0s (walks=%0d dones=%0d busy=%b done=%b)",
                 what, walks, dones, cache_flush_busy, cache_flush_done);
        errors = errors + 1;
      end
    end
  endtask

  task automatic reset_dut;
    begin
      reset_n = 1'b0;
      cache_flush = 1'b0;
      cache_flush_insn = 1'b0;
      repeat (4) @(posedge clk);
      reset_n = 1'b1;
      repeat (24) @(posedge clk);
      walks = 0;
      dones = 0;
    end
  endtask

  // Wait until `target` dones have been seen, or fail on timeout.
  task automatic wait_dones(input integer target, input [8*64-1:0] what);
    integer n;
    begin
      n = 0;
      while (dones < target && n < 400) begin
        @(negedge clk);
        n = n + 1;
      end
      if (dones < target) begin
        $display("FAIL %0s: timed out waiting for done %0d (dones=%0d)",
                 what, target, dones);
        errors = errors + 1;
      end
    end
  endtask

  task automatic settle(input integer n);
    begin
      repeat (n) @(negedge clk);
    end
  endtask

  initial begin
    // 1. A one-cycle platform pulse starts one walk and one done.
    $display("== platform one-cycle pulse ==");
    reset_dut();
    @(negedge clk); cache_flush = 1'b1;
    @(negedge clk); cache_flush = 1'b0;
    wait_dones(1, "platform pulse");
    settle(4);
    check(walks == 1 && dones == 1, "platform pulse -> one walk, one done");

    // 2. A held platform level starts exactly one walk and does not re-arm
    //    while it is held; releasing it re-arms the next request.
    $display("== platform held level re-arms only on release ==");
    reset_dut();
    @(negedge clk); cache_flush = 1'b1;
    wait_dones(1, "held platform level");
    settle(16);
    check(walks == 1, "held platform level did not start a second walk");
    @(negedge clk); cache_flush = 1'b0;
    settle(4);
    @(negedge clk); cache_flush = 1'b1;
    wait_dones(2, "platform level after release");
    @(negedge clk); cache_flush = 1'b0;
    settle(4);
    check(walks == 2 && dones == 2, "released level re-arms the next walk");

    // 3. THE P1 REGRESSION.  The platform holds its level past its own done; an
    //    instruction request arrives in that window (as INVD/WBINVD does the
    //    cycle after done).  It must start its own walk and pulse its own done.
    $display("== instruction request under a held platform level ==");
    reset_dut();
    @(negedge clk); cache_flush = 1'b1;
    wait_dones(1, "platform walk before instruction request");
    // Platform level is still held.  Play the instruction's request now.
    @(negedge clk); cache_flush_insn = 1'b1;
    wait_dones(2, "instruction walk under held platform level");
    check(walks == 2, "instruction request started a second walk");
    // The CPU releases its request once it sees done; the platform its own.
    @(negedge clk); cache_flush_insn = 1'b0;
    @(negedge clk); cache_flush = 1'b0;
    settle(8);
    check(walks == 2 && dones == 2, "no extra walk after both requests released");

    // 4. An instruction request that arrives while a walk is running is queued,
    //    even as a one-cycle pulse, and starts a following walk.
    $display("== instruction pulse during a walk is queued ==");
    reset_dut();
    @(negedge clk); cache_flush = 1'b1;
    @(negedge clk); cache_flush = 1'b0;          // platform pulse: walk 1
    // Wait until the walk is actually running, then pulse the instruction.
    while (!cache_flush_busy) @(negedge clk);
    @(negedge clk); cache_flush_insn = 1'b1;
    @(negedge clk); cache_flush_insn = 1'b0;     // one-cycle pulse
    wait_dones(2, "queued instruction pulse");
    settle(8);
    check(walks == 2 && dones == 2, "pulse during busy was queued, not dropped");

    // 5. A held instruction level is one request: a second walk needs a release.
    $display("== held instruction level is one request ==");
    reset_dut();
    @(negedge clk); cache_flush_insn = 1'b1;
    wait_dones(1, "held instruction request");
    settle(16);
    check(walks == 1, "held instruction level did not start a second walk");
    @(negedge clk); cache_flush_insn = 1'b0;
    settle(4);
    @(negedge clk); cache_flush_insn = 1'b1;
    wait_dones(2, "instruction level after release");
    @(negedge clk); cache_flush_insn = 1'b0;
    settle(4);
    check(walks == 2 && dones == 2, "released instruction level re-arms");

    // 6. A flush requested while a D-cache fill is stalled in flight.  The fill
    //    may be blocked behind an unrelated bus transaction for an unbounded
    //    time (and the platform may be waiting on the flush to release it), so
    //    the flush must complete without waiting for the cache to fall idle;
    //    the fill it swept must not install afterwards.
    $display("== flush while a D-cache fill is stalled ==");
    reset_dut();
    req_addr = 32'h0000_0400;      // a miss: the cache requests the line
    req_write = 1'b0;
    req_be = 4'hF;
    req_valid = 1'b1;
    settle(1);
    req_valid = 1'b0;
    settle(8);                     // the responder never supplies the data
    @(negedge clk); cache_flush = 1'b1;
    wait_dones(1, "flush with a stalled D-cache fill");
    @(negedge clk); cache_flush = 1'b0;
    settle(4);
    check(walks == 1 && dones == 1, "stalled D-cache fill did not block the flush");

    // 7. A platform pulse that arrives while a walk is already running is
    //    queued, not dropped: a platform that pulses rather than holds must not
    //    lose a request just because a walk was in flight.
    $display("== platform pulse during a walk is queued ==");
    reset_dut();
    @(negedge clk); cache_flush = 1'b1;
    @(negedge clk); cache_flush = 1'b0;          // platform pulse: walk 1
    while (!cache_flush_busy) @(negedge clk);
    @(negedge clk); cache_flush = 1'b1;
    @(negedge clk); cache_flush = 1'b0;          // one-cycle pulse mid-walk
    wait_dones(2, "queued platform pulse");
    settle(8);
    check(walks == 2 && dones == 2, "platform pulse during a walk was queued, not dropped");

    if (errors == 0) begin
      $display("TB_CACHE_FLUSH: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_CACHE_FLUSH: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_CACHE_FLUSH: TIMEOUT");
  end

endmodule
