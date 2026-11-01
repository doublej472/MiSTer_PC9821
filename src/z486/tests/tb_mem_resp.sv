`timescale 1ns/1ns

// ==== WHAT THIS PROVES ====
// The external bus contract memory.sv actually implements: a responder may
// accept a read and return data in the SAME cycle, one cycle later, or many
// cycles later, and the CPU-side request must complete and deliver the right
// data in all three cases - for a cacheable line fill (D-cache and I-cache) and
// for a direct uncached/IO dword read.
//
// WHY IT EXISTS. A cacheable miss issues one request for a whole line
// (burstcount 4, line_read 1) and counts the returning beats against a
// registered pending counter that is loaded on the accept edge. A responder
// that presents its first beat in the accept cycle itself therefore loses that
// beat: the cache sees only burstcount-1 beats, never reaches the last beat, and
// its FSM stays in the fill state forever. From the CPU that is the
// "instruction retired, every unit idle" wedge - the paging unit's
// fast_path_pending latch never clears because dcache_req_complete never comes,
// with no bus request in flight to point at. The PC-9821 core hit exactly this
// and carries a "accept and respond in SEPARATE cycles" workaround in its
// memory dispatcher.
//
// This bench is the failing-then-passing pin: the same-cycle beat, the
// same-cycle line, and the same-cycle direct dword must all complete. MODE_NEXT
// is the responder the tree has always had, and it is measured first so a
// failure of the harness itself is distinguishable from a failure of the
// contract.
//
// FILL_MODE selects which fill datapath the DUT builds; the responder modes
// are filtered to match, so each mode exercises its built path end to end.

module tb_mem_resp
  import z486_cache_map_pkg::*;
#(
  parameter z486_fill_mode_t FILL_MODE = Z486_FILL_BOTH
);

  reg clk = 0;
  always #5 clk = ~clk;

  reg reset_n = 0;

  // Paging-unit demand request
  reg  [31:0] req_addr = 32'h0;
  reg  [31:0] req_wdata = 32'h0;
  reg   [3:0] req_be = 4'hF;
  reg         req_write = 1'b0;
  reg         req_vga = 1'b0;
  reg         req_valid = 1'b0;
  wire        req_accepted;
  wire        req_complete;
  wire        read_complete;
  wire [31:0] rdata;

  // Instruction-side request
  reg  [31:0] icache_addr = 32'h0;
  reg         icache_valid = 1'b0;
  wire        icache_accepted;
  wire        icache_complete;
  wire [127:0] icache_line;

  // External bus
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

  // Responder modes
  localparam integer MODE_NEXT = 0;   // ready now, the beats follow one cycle later
  localparam integer MODE_SAME = 1;   // first beat presented with ready
  localparam integer MODE_LINE = 2;   // the whole line presented with ready
  integer mode = MODE_NEXT;

  memory #(
    .DCACHE_SET_BITS(3),
    .ICACHE_SET_BITS(3)
  ) dut (
    .clk(clk),
    .reset_n(reset_n),
    .a20_enable(1'b1),
    .cache_enable(1'b1),
    .x87_off(1'b0),
    .win0_unmapped(1'b0),
    .ram_cache_top(32'hffff_ffff),
    .cache_flush(1'b0),
    .cache_flush_insn(1'b0),
    .cache_flush_busy(),
    .cache_flush_done(),
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
    .dcache_req_is_vga_mem(req_vga),
    .dcache_req_is_pcd(1'b0),
    .dcache_req_is_locked(1'b0),
    .dcache_stores_drained_out(),
    .dcache_wr_ready(),
    .cache_cd(1'b0),
    .cache_nw(1'b0),
    .bus_locked(1'b0),
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
    .icache_req_phys_addr_raw(icache_addr),
    .icache_req_is_pcd(1'b0), .icache_req_spec_ok(),
    .icache_req_accepted(icache_accepted),
    .icache_req_complete(icache_complete),
    .icache_rdata(icache_line),

    .snoop_addr(32'h0),
    .snoop_valid(1'b0),

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

  // The responder's data pattern: every word is a function of its own byte
  // address, so a beat installed in the wrong line slot or a line assembled in
  // the wrong order is caught rather than coincidentally matching.
  function automatic [31:0] word_at(input [31:0] byte_addr);
    word_at = 32'hC0DE_0000 | {16'h0, byte_addr[15:0]};
  endfunction

  function automatic [127:0] line_at(input [31:0] byte_addr);
    line_at = {word_at({byte_addr[31:4], 4'hc}), word_at({byte_addr[31:4], 4'h8}),
               word_at({byte_addr[31:4], 4'h4}), word_at({byte_addr[31:4], 4'h0})};
  endfunction

  // Ready is always high: this is a zero-wait device. That is what makes the
  // same-cycle cases reachable at all.
  wire accept_now = valid && ready && !write;

  // Accepted bus reads. A repeated read of a cached line must not move this,
  // so a fill installed into the wrong slot is caught (re-read or wrong data).
  integer bus_read_count = 0;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) bus_read_count <= 0;
    else if (accept_now) bus_read_count <= bus_read_count + 1;

  reg        beat_active = 1'b0;
  reg [31:0] beat_addr = 32'h0;
  reg  [7:0] beat_left = 8'd0;

  always @(*) begin
    ready = 1'b1;
    resp_valid = 1'b0;
    line_resp_valid = 1'b0;
    din = word_at(32'h0);
    line_din = line_at(32'h0);
    if (beat_active) begin
      resp_valid = 1'b1;
      din = word_at(beat_addr);
    end else if (accept_now) begin
      if (mode == MODE_LINE && line_read && burstcount == 8'd4) begin
        line_resp_valid = 1'b1;
        line_din = line_at({addr, 2'b00});
      end else if (mode == MODE_SAME) begin
        resp_valid = 1'b1;
        din = word_at({addr, 2'b00});
      end
    end
  end

  // Beat streaming. MODE_SAME has already presented beat 0 on the accept cycle,
  // so it owes burstcount-1; MODE_NEXT owes all of them, starting one cycle
  // after the accept (a single-beat request included).
  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      beat_active <= 1'b0;
      beat_addr <= 32'h0;
      beat_left <= 8'd0;
    end else if (beat_active) begin
      beat_addr <= beat_addr + 32'd4;
      if (beat_left <= 8'd1) beat_active <= 1'b0;
      else beat_left <= beat_left - 8'd1;
    end else if (accept_now && !(mode == MODE_LINE && line_read && burstcount == 8'd4)) begin
      if (mode == MODE_SAME) begin
        if (burstcount > 8'd1) begin
          beat_active <= 1'b1;
          beat_addr <= {addr, 2'b00} + 32'd4;
          beat_left <= burstcount - 8'd1;
        end
      end else begin
        beat_active <= 1'b1;
        beat_addr <= {addr, 2'b00};
        beat_left <= burstcount;
      end
    end
  end

  // Completion monitors: read_complete is a one-cycle pulse, so it is captured
  // on the edge rather than polled.
  reg          dseen = 1'b0;
  reg  [31:0]  ddata = 32'h0;
  reg          iseen = 1'b0;
  reg  [127:0] idata = 128'h0;
  // Acceptance is a combinational pulse in the cycle the request is presented,
  // so it is captured on the edge like the completion pulses.
  reg          dacc = 1'b0;
  reg          iacc = 1'b0;

  always @(posedge clk) begin
    // `icache_req_accepted` is the cache's ready, not a qualified accept, so the
    // request itself qualifies it here.
    if (req_accepted && req_valid) dacc <= 1'b1;
    if (icache_accepted && icache_valid) iacc <= 1'b1;
    if (read_complete) begin
      dseen <= 1'b1;
      ddata <= rdata;
    end
    if (icache_complete) begin
      iseen <= 1'b1;
      idata <= icache_line;
    end
  end

  integer errors = 0;
  integer hit_bus_before = 0;

  // A repeated read must hit; do_reset=0 keeps the line installed.
  task automatic check_hit(input [8*40-1:0] what);
    begin
      if (bus_read_count != hit_bus_before) begin
        $display("FAIL %0s: fill did not install (bus reads moved by %0d)",
                 what, bus_read_count - hit_bus_before);
        errors = errors + 1;
      end else begin
        $display("  ok  %0s", what);
      end
    end
  endtask


  task automatic reset_dut;
    begin
      reset_n = 1'b0;
      req_valid = 1'b0;
      icache_valid = 1'b0;
      repeat (4) @(posedge clk);
      reset_n = 1'b1;
      repeat (24) @(posedge clk);
    end
  endtask

  task automatic check(input [31:0] got, input [31:0] want, input [8*40-1:0] what);
    begin
      if (got !== want) begin
        $display("FAIL %0s: got %08x want %08x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("  ok  %0s: %08x", what, got);
      end
    end
  endtask

  task automatic check_line(input [127:0] got, input [127:0] want, input [8*40-1:0] what);
    begin
      if (got !== want) begin
        $display("FAIL %0s: got %032x want %032x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("  ok  %0s", what);
      end
    end
  endtask

  // A cacheable dword read that misses: the fabric must fill the line and hand
  // the requested word back, whatever the responder's beat timing.
  task automatic dcache_read(input integer m, input [31:0] a, input [8*40-1:0] what,
                             input bit do_reset = 1'b1);
    integer n;
    begin
      mode = m;
      if (do_reset) reset_dut();
      dseen = 1'b0;
      dacc = 1'b0;
      @(negedge clk);
      req_addr = a;
      req_write = 1'b0;
      req_be = 4'hF;
      req_vga = 1'b0;
      req_valid = 1'b1;
      n = 0;
      while (n < 200 && !dacc) begin
        @(negedge clk);
        n = n + 1;
      end
      req_valid = 1'b0;
      if (!dacc) begin
        $display("FAIL %0s: request not accepted", what);
        errors = errors + 1;
      end
      n = 0;
      while (n < 200 && !dseen) begin
        @(negedge clk);
        n = n + 1;
      end
      if (!dseen) begin
        $display("FAIL %0s: no completion", what);
        errors = errors + 1;
      end else begin
        check(ddata, word_at(a), what);
      end
    end
  endtask

  // A direct (uncached) dword read: one beat, and the fabric must accept it with
  // or after `ready`.
  task automatic direct_read(input integer m, input [31:0] a, input [8*40-1:0] what);
    integer n;
    begin
      mode = m;
      reset_dut();
      dseen = 1'b0;
      dacc = 1'b0;
      @(negedge clk);
      req_addr = a;
      req_write = 1'b0;
      req_be = 4'hF;
      req_vga = 1'b1;              // VGA window: the direct path
      req_valid = 1'b1;
      n = 0;
      while (n < 200 && !dacc) begin
        @(negedge clk);
        n = n + 1;
      end
      req_valid = 1'b0;
      if (!dacc) begin
        $display("FAIL %0s: request not accepted", what);
        errors = errors + 1;
      end
      n = 0;
      while (n < 200 && !dseen) begin
        @(negedge clk);
        n = n + 1;
      end
      if (!dseen) begin
        $display("FAIL %0s: no completion", what);
        errors = errors + 1;
      end else begin
        check(ddata, word_at(a), what);
      end
    end
  endtask

  // An instruction fetch: the fabric must fill the line and hand the whole line
  // back, whatever the responder's beat timing.
  task automatic icache_read(input integer m, input [31:0] a, input [8*40-1:0] what,
                             input bit do_reset = 1'b1);
    integer n;
    begin
      mode = m;
      if (do_reset) reset_dut();
      iseen = 1'b0;
      iacc = 1'b0;
      @(negedge clk);
      icache_addr = a;
      icache_valid = 1'b1;
      n = 0;
      while (n < 200 && !iacc) begin
        @(negedge clk);
        n = n + 1;
      end
      icache_valid = 1'b0;
      if (!iacc) begin
        $display("FAIL %0s: request not accepted", what);
        errors = errors + 1;
      end
      n = 0;
      while (n < 200 && !iseen) begin
        @(negedge clk);
        n = n + 1;
      end
      if (!iseen) begin
        $display("FAIL %0s: no completion", what);
        errors = errors + 1;
      end else begin
        check_line(idata, line_at(a), what);
      end
    end
  endtask

  initial begin
    if (FILL_MODE == Z486_FILL_BOTH)
      $display("== fill mode: BOTH ==");
    else if (FILL_MODE == Z486_FILL_BEAT)
      $display("== fill mode: BEAT ==");
    else
      $display("== fill mode: LINE ==");

    // 1/2. THE PER-DWORD BURST FILL: MODE_NEXT (the responder the tree always
    // had) and MODE_SAME (the first beat presented with `ready`). Skipped when
    // the beat fill was not built.
    if (FILL_MODE != Z486_FILL_LINE) begin
      $display("== responder: ready now, beats one cycle later ==");
      dcache_read(MODE_NEXT, 32'h0000_5000, "dcache line fill, beats after ready");
      hit_bus_before = bus_read_count;
      dcache_read(MODE_NEXT, 32'h0000_5000, "dcache beat fill installed", 1'b0);
      check_hit("dcache beat fill installed");
      icache_read(MODE_NEXT, 32'h0000_6000, "icache line fill, beats after ready");
      hit_bus_before = bus_read_count;
      icache_read(MODE_NEXT, 32'h0000_6000, "icache beat fill installed", 1'b0);
      check_hit("icache beat fill installed");
      direct_read(MODE_NEXT, 32'h000A_8000, "direct read, beat after ready");

      $display("== responder: first beat in the accept cycle ==");
      dcache_read(MODE_SAME, 32'h0000_7000, "dcache line fill, first beat with ready");
      hit_bus_before = bus_read_count;
      dcache_read(MODE_SAME, 32'h0000_7000, "dcache same-cycle fill installed", 1'b0);
      check_hit("dcache same-cycle fill installed");
      dcache_read(MODE_SAME, 32'h0000_7004, "dcache line fill, mid-line target");
      icache_read(MODE_SAME, 32'h0000_8000, "icache line fill, first beat with ready");
      hit_bus_before = bus_read_count;
      icache_read(MODE_SAME, 32'h0000_8000, "icache same-cycle fill installed", 1'b0);
      check_hit("icache same-cycle fill installed");
      direct_read(MODE_SAME, 32'h000A_C000, "direct read, beat with ready");
    end

    // 3. THE SINGLE-CYCLE WHOLE-LINE FILL. Skipped when the wide fill was not
    // built. A direct read still covers the bypass path in LINE mode.
    if (FILL_MODE != Z486_FILL_BEAT) begin
      $display("== responder: whole line in the accept cycle ==");
      icache_read(MODE_LINE, 32'h0000_9000, "icache line, whole line with ready");
      hit_bus_before = bus_read_count;
      icache_read(MODE_LINE, 32'h0000_9000, "icache whole-line fill installed", 1'b0);
      check_hit("icache whole-line fill installed");
      dcache_read(MODE_LINE, 32'h0000_A000, "dcache line, whole line with ready");
      hit_bus_before = bus_read_count;
      dcache_read(MODE_LINE, 32'h0000_A000, "dcache whole-line fill installed", 1'b0);
      check_hit("dcache whole-line fill installed");
      direct_read(MODE_LINE, 32'h000A_E000, "direct read, line mode");
    end

    if (errors == 0) begin
      $display("TB_MEM_RESP: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_MEM_RESP: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_MEM_RESP: TIMEOUT");
  end

endmodule
