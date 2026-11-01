`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PLAIN_WRITE: profiles the PLAIN plane-window WRITE path - the shape the GFX counters show dominates TH05's MUSIC ROOM - against the REAL pc9821_gvram, whose plane store now lives in on-chip M10K block RAM, and asserts the three shapes' stored bytes are BYTE-EXACT when read back through the same plane windows: the four plane windows of one column (the sprite/music-room column write), a single-plane consecutive 16-bit run (the graphics library's rep movsw fill), and the GRCG RMW 16-bit store whose merge needs the old word (data 0xF0). Each shape is timed over a fixed window (clk_sys/store and the client's own cs split) as the measurement, and the plain WRITE's accept cadence is asserted: a store completes on ready and never enters the response strobe C_RESP2, which only a READ needs.
//
// WHY THE READ-BACK IS THE ASSERTION. The plane store is on-chip M10K block RAM, so
// there is no SDRAM controller and no write-combining buffer on this path to profile: the old
// two-word write-back pair and the permanently-zero backend counters that claimed it are gone
//. What remains is the current contract - the bytes the read-back sees are
// the bytes the CPU stored, and a WRITE completes on its ready without the separate response
// strobe a READ needs. The byte checks below are the assertion; the timing and cs
// lines are the measurement, so a faster path cannot pass by writing the wrong bytes.
//
// The three shapes are the ones the plain path is asked for:
//   A  the four plane windows of one column (the sprite / music-room column write);
//   B  a single-plane consecutive 16-bit run (the graphics library's 16-bit fill);
//   C  the GRCG RMW store (16-bit, data 0xF0, so the merge needs the old word).
//
// The cs line is also the accept-cadence instrument: a WRITE now costs C_IDLE + ... only
// (the write arm has no C_RESP2 or C_HOLD -- a store completes on `ready`), and
// RESP2 stays nonzero only because a read still needs its separate response strobe. The
// assertion below holds that line: a write-only window never enters C_RESP or C_RESP2.

`default_nettype none

module tb_pc9821_plain_write;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam [31:0]  GVRAM_BASE = 32'h0300_0000;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  reg        access_page = 1'b0;
  reg  [1:0] win_plane = 2'd0;
  reg [14:0] win_offset = 15'd0;
  reg [31:0] cpu_din = 32'd0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 1'b0;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'hFFFF, egc_fgbg = 16'd0, egc_ope = 16'd0,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'd0;
  reg        egc_shift_we = 1'b0;

  reg        scan_enable = 1'b0, scan_line_tick = 1'b0, scan_page = 1'b0;
  reg [14:0] scan_line_base = 15'd0;
  reg  [6:0] line_rd_addr = 7'd0;
  reg        line_rd_sel = 1'b0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;


  pc9821_gvram_dut dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));


  

  

  // ==== STIMULUS ====
  // The counters that turn the stimulus into a measurement. The plane store is on-chip M10K
  // block RAM now, so the only cost instrument left is the client's own cs split:
  // there is no backend transaction and no write-combining buffer to count. The dead
  // txn_rd/txn_wr/txn_wr_pair/txn_wr_single counters and the report that printed them as zero
  // while a PASS note called the pair "byte-exact" are deleted.
  integer cs_cnt [0:7];
  reg     meas_en = 1'b0;
  always @(posedge clk) if (meas_en) cs_cnt[dut.u_arb.cs] <= cs_cnt[dut.u_arb.cs] + 1;

  // The last window's store count, so the per-phase NOTE can report it.
  integer win_stores;

  integer errors = 0;
  task automatic fail(input [255:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== the streaming driver: cpu_valid held, the shape a function of the access index ====
  // mode 0: the four plane windows of one column (16-bit stores, 4 planes)
  // mode 1: a single-plane consecutive 16-bit run (the `rep movsw` fill)
  // mode 2: the GRCG RMW store (16-bit, plane 0 window, data 0xF0)
  // A 16-bit store's TWO enabled byte lanes are two consecutive PLANE bytes (the base word and
  // the base word + 1); the CPU's 16-bit datum sits in the dword half its address selects, so the
  // byte pair rides {16'h0, hi, lo} for an offset with bit 1 clear and {hi, lo, 16'h0} with it set.
  integer mode = 0;
  integer n = 0;
  integer stores = 0;
  reg [14:0] drv_off = 15'd0;
  reg [1:0]  drv_plane = 2'd0;
  reg  [3:0] drv_be = 4'b0011;
  reg [31:0] drv_din = 32'd0;
  reg drv_on = 1'b0;
  reg drv_stop = 1'b0;   // ask the driver to finish the access it has accepted, then drop

  function [7:0] pair_lo(input integer p);
    begin pair_lo = 8'h20 + p[7:0]; end
  endfunction
  function [7:0] pair_hi(input integer p);
    begin pair_hi = 8'h10 + p[7:0]; end
  endfunction

  always @* begin
    case (mode)
      0: begin
        drv_plane = n[1:0];
        drv_off   = 15'h1000 + 15'(4 * ((n >> 2) & 63));
        drv_be    = 4'b0011;
        drv_din   = {16'd0, pair_hi(n[1:0]), pair_lo(n[1:0])};
      end
      1: begin
        drv_plane = 2'd0;
        drv_off   = 15'h2000 + 15'(2 * (n & 255));
        drv_be    = drv_off[1] ? 4'b1100 : 4'b0011;
        // word `off` carries off&0xFF, word off+1 carries (off+1)&0xFF, in BOTH lane orders.
        drv_din   = drv_off[1] ? {8'((drv_off + 15'd1) & 15'hFF), 8'(drv_off & 15'hFF), 16'd0}
                               : {16'd0, 8'((drv_off + 15'd1) & 15'hFF), 8'(drv_off & 15'hFF)};
      end
      default: begin
        drv_plane = 2'd0;
        drv_off   = 15'h3000 + 15'(4 * (n & 255));
        drv_be    = 4'b0011;
        drv_din   = 32'h0000_F0F0;   // data byte 0xF0 (same for both lanes): the merge reads old
      end
    endcase
  end

  always @(posedge clk) begin
    if (reset) begin
      cpu_valid <= 1'b0; cpu_write <= 1'b0;
    end else if (drv_on) begin
      cpu_valid  <= 1'b1;
      cpu_write  <= 1'b1;
      win_plane  <= drv_plane;
      win_offset <= drv_off;
      cpu_be     <= drv_be;
      cpu_din    <= drv_din;
      if (cpu_ready) begin
        stores <= stores + 1;
        n      <= n + 1;
        // The window never ends mid-access: a real CPU holds valid AND write until the accept
        // (z486 clears them only after `ready`), and the GVRAM walk reads BOTH live -- the
        // GRCG's merge mask is `cc_owns_grcg`, which is `cpu_write && the gate`. Dropping
        // `cpu_write` while a walk is in flight would flip the fill's mask to the plain path's.
        if (drv_stop) drv_on <= 1'b0;
      end
    end else begin
      cpu_valid <= 1'b0;
      cpu_write <= 1'b0;
    end
  end

  // ==== CHECKS ====
  // The hand-driven plane access, for the read-back, and the byte comparisons.
  task automatic plane_op(input [1:0] p, input [14:0] off, input [31:0] din, input [3:0] be,
                          input wr, output [31:0] dout);
    begin
      @(negedge clk);
      win_plane = p; win_offset = off; cpu_din = din; cpu_be = be;
      cpu_write = wr; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end else dout = 32'd0;
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
    end
  endtask

  // One plane BYTE, at a plane byte offset (the lane rides cpu_be).
  task automatic get_byte(input [1:0] p, input [14:0] off, output [7:0] v);
    reg [31:0] d;
    begin
      plane_op(p, {off[14:2], 2'b00}, 32'd0, 4'b0001 << off[1:0], 1'b0, d);
      v = d[{off[1:0], 3'b000} +: 8];
    end
  endtask

  task automatic grcg_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); grcg_we = 1'b1; grcg_addr = a; grcg_din = d;
      @(posedge clk);
      @(negedge clk); grcg_we = 1'b0;
    end
  endtask

  // One timed window of the streaming driver, reporting the shape's per-store cost and holding
  // the one current-contract assertion this tier owns: a write-only window never enters the
  // response strobe a READ needs.
  task automatic run_window(input [255:0] what, input integer win);
    integer s0;
    integer j;
    begin
      for (j = 0; j <= 7; j = j + 1) cs_cnt[j] = 0;
      meas_en = 1'b1;
      drv_on = 1'b1;
      s0 = stores;
      repeat (win) @(posedge clk);
      drv_stop = 1'b1;
      while (drv_on) @(posedge clk);
      drv_stop = 1'b0;
      meas_en = 1'b0;
      win_stores = stores - s0;
      if (win_stores == 0) fail("a write phase completed no store -- the plain path is wedged");
      // A store completes on `ready`; only a READ uses C_RESP/C_RESP2. This window
      // drives no read, so any cycle in either state is the write path regressing to the old
      // two-strobe shape (READ=3, RESP2=4 in pc9821_gvram's client FSM).
      if (cs_cnt[3] != 0 || cs_cnt[4] != 0)
        fail("a write-only window entered the read response strobe (C_RESP/C_RESP2)");
      $display("NOTE plain_write: %0s: %0d store(s) in %0d clk_sys = %0.2f clk_sys/store",
               what, win_stores, win, win * 1.0 / win_stores);
      $display("NOTE plain_write: %0s: client cs IDLE=%0d RESP=%0d RESP2=%0d MWAIT=%0d",
               what, cs_cnt[0], cs_cnt[3], cs_cnt[4], cs_cnt[5]);
      repeat (600) @(posedge clk);
    end
  endtask

  integer i, k, p;
  reg [7:0] got;
  reg [7:0] want;

  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);


    // ---- A: the four plane windows of one column ----
    mode = 0; n = 0;
    run_window("A four-plane 16-bit column write", 40000);
    for (k = 0; k < 64; k = k + 1) begin
      for (p = 0; p < 4; p = p + 1) begin
        want = 8'h20 + p[7:0];
        get_byte(p[1:0], 15'(16'h1000 + 4*k), got);
        if (got !== want) begin
          $display("FAIL A plane %0d column %0d even byte = %02x want %02x", p, k, got, want);
          errors = errors + 1;
        end
        want = 8'h10 + p[7:0];
        get_byte(p[1:0], 15'(16'h1000 + 4*k + 1), got);
        if (got !== want) begin
          $display("FAIL A plane %0d column %0d odd byte = %02x want %02x", p, k, got, want);
          errors = errors + 1;
        end
      end
    end
    $display("NOTE plain_write: A read back 512 plane bytes of the four-plane column block");

    // ---- B: the single-plane consecutive 16-bit run ----
    mode = 1; n = 0;
    run_window("B single-plane 16-bit fill", 40000);
    for (k = 0; k < 128; k = k + 1) begin
      get_byte(2'd0, 15'(16'h2000 + 2*k), got);
      if (got !== 8'((16'h2000 + 2*k) & 16'hFF)) begin
        $display("FAIL B offset %04x = %02x want %02x", 16'h2000 + 2*k, got,
                 8'((16'h2000 + 2*k) & 16'hFF));
        errors = errors + 1;
      end
      get_byte(2'd0, 15'(16'h2000 + 2*k + 1), got);
      if (got !== 8'((16'h2000 + 2*k + 1) & 16'hFF)) begin
        $display("FAIL B offset %04x = %02x want %02x", 16'h2000 + 2*k + 1, got,
                 8'((16'h2000 + 2*k + 1) & 16'hFF));
        errors = errors + 1;
      end
    end
    $display("NOTE plain_write: B read back 256 plane bytes of the consecutive fill");

    // ---- C: the GRCG RMW store ----
    // Arm RMW (0x7C = 0xC0) with every tile byte 0xAA and store data 0xF0, so the merge
    // (old & ~d) | (tile & d) over a fresh (zero) word makes every plane byte 0xAA & 0xF0 = 0xA0.
    grcg_w(8'h7C, 8'hC0);
    grcg_w(8'h7E, 8'hAA);
    grcg_w(8'h7E, 8'hAA);
    grcg_w(8'h7E, 8'hAA);
    grcg_w(8'h7E, 8'hAA);
    mode = 2; n = 0;
    run_window("C GRCG RMW 16-bit store", 40000);
    for (k = 0; k < 128; k = k + 1) begin
      for (p = 0; p < 4; p = p + 1) begin
        get_byte(p[1:0], 15'(16'h3000 + 4*k), got);
        if (got !== 8'hA0) begin
          $display("FAIL C plane %0d offset %04x = %02x want a0", p, 16'h3000 + 4*k, got);
          errors = errors + 1;
        end
        get_byte(p[1:0], 15'(16'h3000 + 4*k + 1), got);
        if (got !== 8'hA0) begin
          $display("FAIL C plane %0d offset %04x = %02x want a0", p, 16'h3000 + 4*k + 1, got);
          errors = errors + 1;
        end
      end
    end
    $display("NOTE plain_write: C read back 1024 plane bytes of the GRCG RMW block");
    grcg_w(8'h7C, 8'h00);

    // ---- The plane store is on-chip M10K block RAM now: there is no SDRAM
    //      controller and no write-combining buffer on this path, so no write-back pair to
    //      count. The byte checks above are the assertion, and they are the stronger one. ----

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("NOTE plain_write: all three shapes' plane bytes read back byte-exact; no write-only window entered the read response strobe");
      $display("TB_PC9821_PLAIN_WRITE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_PLAIN_WRITE: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_PLAIN_WRITE: FAIL");
    end
  end

  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_PLAIN_WRITE: FAIL (timed out)");
  end

endmodule

`default_nettype wire
