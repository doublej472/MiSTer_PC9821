`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_HDD_PROBE_ERR: a mount probe that the block engine answers with an ERROR at the earliest the engine contract allows - req_done with req_error one, two or three clk_sys after the request pulse (pc9821_block_io answers a rejected request in the cycle after it, its `req_reject` arm), with no word streamed - takes pc9821_hdd_image's not-an-HDI verdict on the PROBED drive's own size even when the size mux switched drives in the cycle before the probe started (two drives mounted on consecutive cycles, the second probed straight after the first's last completion; and a mount of drive 0 while drive 1 is idle): a drive whose file is a whole number of sectors of at least 1024 bytes gets its tail probe at LBA size/512 - 1 and, when that also fails, is mounted raw with capacity size/512, and a drive too small for a footer is mounted raw with capacity size/512 and no tail probe, so neither drive ever takes the other drive's size; at the rule's boundaries a 512-byte file gets no tail probe and a 1024-byte one gets it at LBA 1, while 1500 and 8448 bytes (not whole sectors) get none and mount raw with floor(size/512); the staged verdict terms' static premise (pc9821_static_stage, DEPTH 1 per stage) holds at every one of those completions.
//
// EXPECTED VALUES. The verdict's rules are the module's documented mount rules, from the image
// formats, never read out of the RTL under test: a fixed VHD's footer is the file's last sector
// (Microsoft Virtual Hard Disk Image Format Specification: "the footer is the last 512 bytes"), so
// the tail is probed only in a file that is a whole number of sectors with a sector before the
// footer; an image that is neither HDI nor VHD is the raw image, pc9821_block_io's floor(size/512)
// sectors. The engine's earliest answer is its registered completion (pc9821_block_io.sv
// `if (req_reject) begin req_done <= 1'b1; req_error <= 1'b1;`), one clk_sys after the request.
//
// ==== DUT ====
// pc9821_hdd_image alone, its A port answered by a model engine that completes every probe with an
// error LAT cycles after the request pulse and streams nothing.

module tb_pc9821_hdd_probe_err;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer fails = 0;

  reg         img_mounted = 0, img_mounted1 = 0, img_readonly = 0;
  reg  [63:0] img_size = 64'd0;
  wire        mounted, readonly, mounted1, readonly1;
  wire [31:0] capacity, capacity1;
  wire        req_done, req_error, busy, buf_we;
  wire [7:0]  buf_addr;
  wire [15:0] buf_data;
  wire        a_req_read, a_req_write, a_req_window, a_req_unit;
  wire [31:0] a_req_lba;
  reg         a_req_done = 0, a_req_error = 0;

  pc9821_hdd_image dut (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted), .img_mounted1(img_mounted1), .img_readonly(img_readonly),
      .img_size(img_size),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .mounted1(mounted1), .readonly1(readonly1), .capacity1(capacity1),
      .req_read(1'b0), .req_write(1'b0), .req_lba(32'd0), .req_unit(1'b0),
      .req_done(req_done), .req_error(req_error), .busy(busy),
      .buf_we(buf_we), .buf_addr(buf_addr), .buf_data(buf_data),
      .a_req_read(a_req_read), .a_req_write(a_req_write), .a_req_lba(a_req_lba),
      .a_req_window(a_req_window), .a_req_unit(a_req_unit),
      .a_req_done(a_req_done), .a_req_error(a_req_error),
      .a_buf_we(1'b0), .a_buf_addr(8'd0), .a_buf_data(16'd0));

  // The model engine: every request completes with an error LAT cycles after its pulse.
  integer lat = 1;
  integer pend_at = -1;
  integer cyc = 0;
  integer nreq = 0;
  reg     dup_req = 1'b0;
  reg [31:0] req_lba_log [0:255];
  reg        req_unit_log [0:255];
  always @(posedge clk) begin
    cyc <= cyc + 1;
    a_req_done  <= 1'b0;
    a_req_error <= 1'b0;
    if (a_req_read || a_req_write) begin
      if (pend_at >= 0) begin
        $display("  FAIL: a second request while one is outstanding");
        dup_req = 1'b1;
      end
      if (nreq < 256) begin req_lba_log[nreq] = a_req_lba; req_unit_log[nreq] = a_req_unit; end
      nreq = nreq + 1;
      pend_at = cyc + lat;
    end
    if (pend_at >= 0 && cyc + 1 == pend_at) begin
      a_req_done  <= 1'b1;
      a_req_error <= 1'b1;
      pend_at = -1;
    end
  end

  // ==== CHECKS ====
  task automatic expect_eq(input [31:0] got, input [31:0] want, input [8*72-1:0] what);
    if (got !== want) begin
      $display("  FAIL [lat %0d] %0s: got %0d, want %0d", lat, what, got, want);
      fails = fails + 1;
    end
  endtask

  // The verdict for a size, from the format rules (see EXPECTED VALUES).
  function automatic tail_probed(input [63:0] sz);
    tail_probed = (sz >= 64'd1024) && (sz[8:0] == 9'd0);
  endfunction

  integer wd;
  initial begin
    for (wd = 0; wd < 200000; wd = wd + 1) @(posedge clk);
    $fatal(1, "TB_PC9821_HDD_PROBE_ERR: watchdog timeout (no verdict reached)");
  end

  task automatic pulse_mount(input m0, input m1, input [63:0] sz);
    begin
      @(negedge clk);
      img_mounted = m0; img_mounted1 = m1; img_size = sz;
      @(negedge clk);
      img_mounted = 0; img_mounted1 = 0;
    end
  endtask

  task automatic settle;
    integer i;
    begin
      for (i = 0; i < 64; i = i + 1) @(negedge clk);
      if (busy) begin
        $display("  FAIL [lat %0d]: the probes never finished", lat);
        fails = fails + 1;
      end
    end
  endtask

  // The requests a drive of size sz gets, in order, from req_lba_log[first..]: the front probe at
  // LBA 0, then the tail probe at size/512 - 1 when the file can hold a footer.
  task automatic expect_probes(input integer first, input unit, input [63:0] sz, output integer next);
    begin
      expect_eq(req_unit_log[first], unit, "front probe's drive");
      expect_eq(req_lba_log[first], 32'd0, "front probe's LBA");
      next = first + 1;
      if (tail_probed(sz)) begin
        expect_eq(req_unit_log[next], unit, "tail probe's drive");
        expect_eq(req_lba_log[next], 32'(sz / 512) - 32'd1, "tail probe's LBA");
        next = next + 1;
      end
    end
  endtask

  // Two sizes whose verdicts differ: drive A's file holds a footer, drive B's does not.
  localparam [63:0] SZ_TAIL  = 64'd8192;   // 16 sectors: front, then tail at LBA 15, raw 16
  localparam [63:0] SZ_SMALL = 64'd600;    // 1 sector, no room for a footer: raw 1, no tail

  // ==== STIMULUS ====
  integer n, b;
  reg [63:0] bsz;
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    for (lat = 1; lat <= 3; lat = lat + 1) begin
      // (1) Both drives mounted, drive 0 small and drive 1 tail-sized: drive 0 is
      // probed first; drive 1's probe starts the cycle after drive 0's last completion, the cycle
      // the size mux switches from drive 0 to drive 1. Then the sizes swapped (drive 0 first again,
      // now tail-sized, so drive 1's front probe follows drive 0's TAIL probe).
      b = nreq;
      // the same size reaches both slots: the mount event carries one img_size, so mount each
      // drive in its own cycle back to back (still both pending before either probe ends)
      @(negedge clk);
      img_mounted = 1; img_size = SZ_SMALL;
      @(negedge clk);
      img_mounted = 0; img_mounted1 = 1; img_size = SZ_TAIL;
      @(negedge clk);
      img_mounted1 = 0;
      settle;
      expect_probes(b, 1'b0, SZ_SMALL, n);
      expect_probes(n, 1'b1, SZ_TAIL, n);
      expect_eq(nreq, n, "requests issued (case 1)");
      expect_eq(mounted, 1, "drive 0 mounted (case 1)");
      expect_eq(capacity, 32'(SZ_SMALL / 512), "drive 0 capacity (case 1)");
      expect_eq(mounted1, 1, "drive 1 mounted (case 1)");
      expect_eq(capacity1, 32'(SZ_TAIL / 512), "drive 1 capacity (case 1)");

      b = nreq;
      @(negedge clk);
      img_mounted = 1; img_size = SZ_TAIL;
      @(negedge clk);
      img_mounted = 0; img_mounted1 = 1; img_size = SZ_SMALL;
      @(negedge clk);
      img_mounted1 = 0;
      settle;
      expect_probes(b, 1'b0, SZ_TAIL, n);
      expect_probes(n, 1'b1, SZ_SMALL, n);
      expect_eq(nreq, n, "requests issued (case 2)");
      expect_eq(capacity, 32'(SZ_TAIL / 512), "drive 0 capacity (case 2)");
      expect_eq(capacity1, 32'(SZ_SMALL / 512), "drive 1 capacity (case 2)");

      // (3) Drive 0 alone remounted while drive 1 sits idle: before the mount the size tests read
      // drive 1 (no probe pending for drive 0); the mount edge switches them to drive 0 and the
      // probe starts in the next cycle.
      b = nreq;
      pulse_mount(1'b1, 1'b0, SZ_SMALL);
      settle;
      expect_probes(b, 1'b0, SZ_SMALL, n);
      expect_eq(nreq, n, "requests issued (case 3)");
      expect_eq(capacity, 32'(SZ_SMALL / 512), "drive 0 capacity (case 3)");
      expect_eq(capacity1, 32'(SZ_SMALL / 512), "drive 1 untouched (case 3)");
      b = nreq;
      pulse_mount(1'b0, 1'b1, SZ_TAIL);
      settle;
      b = nreq;
      pulse_mount(1'b1, 1'b0, SZ_TAIL);
      settle;
      expect_probes(b, 1'b0, SZ_TAIL, n);
      expect_eq(nreq, n, "requests issued (case 3, tail-sized)");
      expect_eq(capacity, 32'(SZ_TAIL / 512), "drive 0 capacity (case 3, tail-sized)");
      // and back, so the next latency starts from small drives
      pulse_mount(1'b1, 1'b0, SZ_SMALL);
      settle;
      pulse_mount(1'b0, 1'b1, SZ_SMALL);
      settle;
    end

    // (4) The tail-probe boundary, drive 0 alone at the last latency: 512 bytes (one sector,
    // no sector before a footer: no tail), 1024 (the smallest file with one: tail at LBA 1),
    // 1500 and 8448 (not a whole number of sectors, so the last 512 bytes are not a sector:
    // no tail, raw floor(size/512)). Each mount is followed by the same drive's next size, so
    // every verdict is the probed size's own.
    for (n = 0; n < 4; n = n + 1) begin
      bsz = (n == 0) ? 64'd512 : (n == 1) ? 64'd1024 : (n == 2) ? 64'd1500 : 64'd8448;
      b = nreq;
      pulse_mount(1'b1, 1'b0, bsz);
      settle;
      expect_eq(req_lba_log[b], 32'd0, "boundary: the front probe's LBA");
      if (n == 1) begin
        expect_eq(nreq, b + 2, "boundary: a 1024-byte file gets a front and a tail probe");
        expect_eq(req_lba_log[b + 1], 32'd1, "boundary: the 1024-byte file's tail probe is LBA 1");
      end
      else
        expect_eq(nreq, b + 1, "boundary: a file with no whole sector before a footer gets no tail probe");
      expect_eq(mounted, 1, "boundary: drive 0 mounted");
      expect_eq(capacity, 32'(bsz / 512), "boundary: drive 0 raw capacity floor(size/512)");
    end

    // ==== VERDICT ====
    if (dup_req) fails = fails + 1;
    if (fails == 0) begin
      $display("TB_PC9821_HDD_PROBE_ERR: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_HDD_PROBE_ERR: FAIL (%0d errors)", fails);
  end

endmodule
