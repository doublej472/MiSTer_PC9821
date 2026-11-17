`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_HDD_EJECT_REQ: pc9821_hdd_image answers every guest request with exactly one req_done whatever cycle an OSD eject of the requested drive lands on: an eject pulse (img_mounted with img_size < 512) swept from four cycles before to four cycles after a req_read or a req_write for that drive, with eject sizes 0, 1 and 511, the coincident cycle and the request's dispatch cycle included, never leaves the request unanswered or answers it twice - a request taken before the eject is served by the engine or answered with req_error, and one that arrives in the eject's own cycle or after it (a multi-sector command's next sector after the medium went away) is answered with req_error and never handed to the engine, as pc9821_block_io answers a request in its eject cycle or for an unmounted image - and in every alignment a following request for the OTHER drive reaches the engine and is served, so one drive's eject never blocks the other.
//
// EXPECTED VALUES. The contract is pc9821_ata's block handshake, one req_done pulse per request
// (pc9821_hdd_image.sv's port comment "one req_done pulse per request with req_error beside it"),
// which the ATA relies on to leave X_WAIT_BLOCK; and the engine's own eject rule for the same
// alignment (pc9821_block_io.sv:553 "else if (req_read || req_write) complete(1'b1);"). Nothing
// here is read out of the RTL under test.
//
// FAIL-FIRST, on the tree before the fix: an eject in the request's cycle or before it (offsets
// -4..0) latched the request for a drive with no image, so it was never dispatched and never
// answered, and the one-deep queue then refused drive 1's request too (no completion for either);
// an eject in the dispatch cycle (offset 1) answered the queued request with an error AND handed it
// to the engine, two completions for one request.
//
// ==== DUT ====
// pc9821_hdd_image alone, its A port answered by a model engine: a probe (window 0) completes with
// an error so each drive mounts as a raw image, and a guest request (window 1) completes with
// success, each LAT cycles after its request pulse, streaming nothing.

module tb_pc9821_hdd_eject_req;

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
  reg         req_read = 0;
  reg         req_write = 0;
  reg  [31:0] req_lba = 32'd0;
  reg         req_unit = 0;

  pc9821_hdd_image dut (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted), .img_mounted1(img_mounted1), .img_readonly(img_readonly),
      .img_size(img_size),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .mounted1(mounted1), .readonly1(readonly1), .capacity1(capacity1),
      .req_read(req_read), .req_write(req_write), .req_lba(req_lba), .req_unit(req_unit),
      .req_done(req_done), .req_error(req_error), .busy(busy),
      .buf_we(buf_we), .buf_addr(buf_addr), .buf_data(buf_data),
      .a_req_read(a_req_read), .a_req_write(a_req_write), .a_req_lba(a_req_lba),
      .a_req_window(a_req_window), .a_req_unit(a_req_unit),
      .a_req_done(a_req_done), .a_req_error(a_req_error),
      .a_buf_we(1'b0), .a_buf_addr(8'd0), .a_buf_data(16'd0));

  // ==== the model engine ====
  localparam integer LAT = 3;
  integer pend_at = -1;
  reg     pend_err = 1'b0;
  integer cyc = 0;
  integer guest_served = 0;          // guest requests the engine received
  reg     last_guest_unit = 1'b0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    a_req_done  <= 1'b0;
    a_req_error <= 1'b0;
    if (a_req_read || a_req_write) begin
      pend_at  = cyc + LAT;
      pend_err = !a_req_window;
      if (a_req_window) begin
        guest_served = guest_served + 1;
        last_guest_unit = a_req_unit;
      end
    end
    if (pend_at >= 0 && cyc + 1 == pend_at) begin
      a_req_done  <= 1'b1;
      a_req_error <= pend_err;
      pend_at = -1;
    end
  end

  // ==== CHECKS ====
  // The ATA side: count completions.
  integer ndone = 0, nerr = 0;
  always @(posedge clk) if (req_done) begin
    ndone = ndone + 1;
    if (req_error) nerr = nerr + 1;
  end

  integer wd;
  initial begin
    for (wd = 0; wd < 400000; wd = wd + 1) @(posedge clk);
    $fatal(1, "TB_PC9821_HDD_EJECT_REQ: watchdog timeout");
  end

  task automatic settle;
    integer i;
    begin
      for (i = 0; i < 64; i = i + 1) @(negedge clk);
    end
  endtask

  task automatic mount(input unit, input [63:0] sz);
    begin
      @(negedge clk);
      if (unit) img_mounted1 = 1; else img_mounted = 1;
      img_size = sz;
      @(negedge clk);
      img_mounted = 0; img_mounted1 = 0;
      settle;
    end
  endtask

  // ==== STIMULUS ====
  // One eject of drive 0 at `off` cycles after (positive) or before (negative) a request for it.
  integer off, c, served0, d0, e0, mode;
  reg wr;
  reg [63:0] ejsz;
  reg ej_issued, rq_issued;
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    mount(1'b1, 64'd8192);
    if (!mounted1) begin $display("  FAIL: drive 1 did not mount"); fails = fails + 1; end
    // Each alignment for a READ and for a WRITE (an unanswered write wedges X_WAIT_BLOCK
    // exactly as a read does), and for eject sizes 0, 1 and 511: every size under one sector
    // is the unmount (pc9821_block_io's `eject = img_mounted && (img_size < 512)`).
    for (mode = 0; mode < 6; mode = mode + 1)
    for (off = -4; off <= 4; off = off + 1) begin
      wr   = mode[0];
      ejsz = (mode < 2) ? 64'd0 : (mode < 4) ? 64'd1 : 64'd511;
      mount(1'b0, 64'd8192);
      if (!mounted) begin $display("  FAIL [wr %0d size %0d off %0d]: drive 0 did not mount", wr, ejsz, off); fails = fails + 1; end
      d0 = ndone; e0 = nerr; served0 = guest_served;
      ej_issued = 0; rq_issued = 0;
      for (c = -4; c <= 4; c = c + 1) begin
        @(negedge clk);
        req_read = 0; req_write = 0; img_mounted = 0;
        if (c == 0) begin
          if (wr) req_write = 1; else req_read = 1;
          req_unit = 0; req_lba = 32'd3; rq_issued = 1;
        end
        if (c == off) begin img_mounted = 1; img_size = ejsz; ej_issued = 1; end
      end
      @(negedge clk);
      req_read = 0; req_write = 0; img_mounted = 0;
      settle;
      if (ndone - d0 != 1) begin
        $display("  FAIL [wr %0d size %0d off %0d]: drive 0's request got %0d completions, want exactly 1", wr, ejsz, off, ndone - d0);
        fails = fails + 1;
      end
      if (off <= 0 && (nerr - e0 != 1 || guest_served != served0)) begin
        $display("  FAIL [wr %0d size %0d off %0d]: a request in or after the eject's cycle must be answered with an error and never reach the engine (errors %0d, engine requests %0d)",
                 wr, ejsz, off, nerr - e0, guest_served - served0);
        fails = fails + 1;
      end
      // drive 1 must still be served
      d0 = ndone; e0 = nerr; served0 = guest_served;
      @(negedge clk);
      if (wr) req_write = 1; else req_read = 1;
      req_unit = 1; req_lba = 32'd5;
      @(negedge clk);
      req_read = 0; req_write = 0;
      settle;
      if (ndone - d0 != 1 || nerr != e0 || guest_served - served0 != 1 || last_guest_unit != 1'b1) begin
        $display("  FAIL [wr %0d size %0d off %0d]: drive 1's request after the eject: completions %0d, errors %0d, engine requests %0d (want 1, 0, 1)",
                 wr, ejsz, off, ndone - d0, nerr - e0, guest_served - served0);
        fails = fails + 1;
      end
      if (busy) begin $display("  FAIL [wr %0d size %0d off %0d]: still busy", wr, ejsz, off); fails = fails + 1; end
    end

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_HDD_EJECT_REQ: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_HDD_EJECT_REQ: FAIL (%0d errors)", fails);
  end

endmodule
