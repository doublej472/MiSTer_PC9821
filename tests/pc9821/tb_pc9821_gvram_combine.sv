`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_COMBINE: the plane-write shapes a sprite put/restore makes, on the REAL pc9821_gvram datapath over its block-RAM array (no SDRAM controller is in this bench): four single-lane stores to one column, four 16-bit stores to one column and the single-plane DWORD fill each complete stores through the plane windows (their plane-byte rate is MEASURED and REPORTED, not asserted - the plain client's own accept cadence bounds it); a line painted one plane lane at a time reads back through the plane windows with all four bytes of each of its first 8 columns (read-after-write) and reaches the SCANOUT's line fetch as the four plane bytes of every one of its 80 columns; and Phase E, TH01's CROSS-PAGE restore shape - four plane lanes per column re-written over the same words with the access page (0xA6) toggled per column-visit, eight rounds - leaves the restored bytes of both pages and the scanout's view of both pages exactly what was written. Phases A-C fail only if a shape completes no store at all; no backend transaction is counted (there is no backend).
//
// HISTORY. This bench was written to measure a word-keyed write-combining buffer in front of an
// SDRAM-backed GVRAM (a one-lane store on a DQM-less module was a ~13 clk_sys read-modify-write)
// and to assert its backend transaction counts. The GVRAM moved to block RAM and the buffer was
// removed, so each store is its own access and there is nothing to count; what survives, and is
// asserted, is the data path in the shapes the buffer was built for (phases D and E) and that each
// measurement phase still completes stores. The MB/s figures are reported only.

`default_nettype none

module tb_pc9821_gvram_combine;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam [31:0]  GVRAM_BASE = 32'h0300_0000;

  localparam integer LINE_COLS = 80;

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

  // ---- The real controller, at the built configuration, against the chip model ----

  

  

  // ==== STIMULUS ====
  integer errors = 0;
  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ---- The plane writers, on the client port ----
  // drv_mode 0: four SINGLE-LANE stores to one column   (1 plane byte/access, 1 word/column)
  // drv_mode 1: four 16-BIT stores to one column        (2 plane bytes/access, 2 words/column)
  // drv_mode 2: the single-plane DWORD fill             (4 plane bytes/access, 4 FRESH words/store)
  // Modes 0 and 1 write the SAME words from four plane windows, which is the coalescer's case;
  // mode 2 writes four different words, which it cannot merge.
  reg        drv_on = 1'b0;
  reg  [1:0] drv_mode = 2'd0;
  reg  [1:0] drv_plane = 2'd0;
  reg [14:0] drv_col = 15'd0;
  integer    drv_stores = 0;

  always @(posedge clk) begin
    if (reset) begin
      drv_on <= 1'b0; drv_plane <= 2'd0; drv_col <= 15'd0;
      win_plane <= 2'd0; win_offset <= 15'd0; cpu_be <= 4'hF; cpu_din <= 32'd0;
      cpu_valid <= 1'b0; cpu_write <= 1'b0;
    end else if (drv_on) begin
      cpu_valid <= 1'b1;
      cpu_write <= 1'b1;
      cpu_be    <= (drv_mode == 2'd2) ? 4'hF :
                   (drv_mode == 2'd0) ? (4'b0001 << drv_col[1:0]) : 4'b0011;
      win_plane <= drv_plane;
      win_offset<= drv_col;
      cpu_din   <= 32'h5A5A_5A5A;
      if (cpu_ready) begin
        drv_stores <= drv_stores + 1;
        if (drv_mode == 2'd2) begin
          drv_col <= drv_col + 15'd4;
        end else if (drv_mode == 2'd1) begin
          if (drv_plane == 2'd3) begin drv_plane <= 2'd0; drv_col <= drv_col + 15'd4; end
          else drv_plane <= drv_plane + 2'd1;
        end else begin
          if (drv_plane == 2'd3) begin drv_plane <= 2'd0; drv_col <= drv_col + 15'd1; end
          else drv_plane <= drv_plane + 2'd1;
        end
      end
    end
  end

  // ==== CHECKS ====
  real    multi_mbps, word_mbps, fill_mbps;
  integer a_cyc0, a_cyc1, a_st0, a_st1, a_win;
  integer w_cyc0, w_cyc1, w_st0, w_st1, w_win;
  integer b_cyc0, b_cyc1, b_st0, b_st1, b_win;

  task automatic read_line_col(input sel, input [6:0] a, output [31:0] v);
    begin
      line_rd_sel = sel;
      line_rd_addr = a;
      @(posedge clk);
      #1;
      v = line_data;
    end
  endtask

  // One CPU plane-window store of ONE lane, at a column whose low bits ride the byte enable.
  task automatic put_lane(input [1:0] plane, input [14:0] col, input [7:0] val);
    begin
      @(negedge clk);
      win_plane  = plane;
      win_offset = col;
      cpu_din    = {4{val}};
      cpu_be     = 4'b0001 << col[1:0];
      cpu_write  = 1'b1;
      cpu_valid  = 1'b1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      repeat (3) @(posedge clk);
    end
  endtask

  // One CPU plane-window load of one column, dword lanes.
  task automatic get_col(input [1:0] plane, input [14:0] col, output [7:0] val);
    reg [31:0] d;
    begin
      @(negedge clk);
      win_plane = plane; win_offset = col;
      cpu_be = 4'hF; cpu_write = 1'b0; cpu_valid = 1'b1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_be = 4'hF;
      #1;
      while (!cpu_resp_valid) begin @(posedge clk); #1; end
      d = cpu_dout;
      @(negedge clk);
      repeat (3) @(posedge clk);
      val = d[{col[1:0], 3'b000} +: 8];
    end
  endtask

  integer i, ci, pi;
  reg [7:0] got, want;
  reg [31:0] lw;

  // One CPU plane-window store of ONE lane at a chosen ACCESS PAGE (port 0xA6's register): the same
  // store put_lane makes above, with the page of the request chosen per call.
  task automatic put_lane_pg(input pageno, input [1:0] plane, input [14:0] col, input [7:0] val);
    begin
      @(negedge clk);
      access_page = pageno;
      win_plane   = plane;
      win_offset  = col;
      cpu_din     = {4{val}};
      cpu_be      = 4'b0001 << col[1:0];
      cpu_write   = 1'b1;
      cpu_valid   = 1'b1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      repeat (3) @(posedge clk);
    end
  endtask

  // One plane-window column load at a chosen access page (get_col above, with the page).
  task automatic get_col_pg(input pageno, input [1:0] plane, input [14:0] col, output [7:0] val);
    reg [31:0] d;
    begin
      @(negedge clk);
      access_page = pageno;
      win_plane = plane; win_offset = col;
      cpu_be = 4'hF; cpu_write = 1'b0; cpu_valid = 1'b1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_be = 4'hF;
      #1;
      while (!cpu_resp_valid) begin @(posedge clk); #1; end
      d = cpu_dout;
      @(negedge clk);
      repeat (3) @(posedge clk);
      val = d[{col[1:0], 3'b000} +: 8];
    end
  endtask

  task automatic run_phase(input [1:0] mode, input integer win,
                           output integer st, output real mbps,
                           input real bytes_per_store);
    integer c0, s0;
    begin
      drv_mode = mode;
      drv_plane = 2'd0;
      drv_col = 15'd0;
      drv_on = 1'b1;
      repeat (4000) @(posedge clk);
      c0 = cyc; s0 = drv_stores;
      repeat (win) @(posedge clk);
      st  = drv_stores - s0;
      mbps = (st * bytes_per_store) * (FREQ / 1_000_000.0) / (cyc - c0);
      drv_on = 1'b0;
      // The driver owns the port while dron is up, so its last `cpu_valid`/`cpu_write` would
      // otherwise stay asserted and the plain path would keep re-issuing the stale request while
      // the correctness phase drives the port by hand. Release it before the tasks take over.
      cpu_valid  = 1'b0;
      cpu_write  = 1'b0;
      cpu_be     = 4'hF;
      repeat (200) @(posedge clk);
    end
  endtask

  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);


    // ---- PHASE A: FOUR single-lane stores to one column. Four stores carry four plane bytes into
    // ONE word, and the buffer must merge them: the read-modify-write the same four bytes cost
    // before the combiner existed is FOUR backend transactions.
    run_phase(2'd0, 40000, a_st1, multi_mbps, 1.0);
    $display("NOTE gvram_combine: A four single-lane stores to ONE column: %0d stores in %0d clk_sys = %0.1f MB/s of plane bytes",
             a_st1, 40000, multi_mbps);

    // ---- PHASE B: FOUR 16-bit stores to one column. The same coalescing, two plane bytes per
    // access - the shape th01/formats/ptn_main.cpp's ptn_put_quarter_8 actually issues.
    run_phase(2'd1, 40000, w_st1, word_mbps, 2.0);
    $display("NOTE gvram_combine: B four 16-bit stores to one column: %0d stores in %0d clk_sys = %0.1f MB/s of plane bytes",
             w_st1, 40000, word_mbps);

    // ---- PHASE C: the single-plane DWORD fill. Four FRESH words per store, which the combiner
    // cannot merge: it must read each word for its other three planes and write it back once.
    // This is the measured baseline shape (3.8 MB/s, 52 clk_sys/store, 4 transactions).
    run_phase(2'd2, 40000, b_st1, fill_mbps, 4.0);
    $display("NOTE gvram_combine: C single-plane DWORD fill (four fresh words per store): %0d stores in %0d clk_sys = %0.1f MB/s of plane bytes",
             b_st1, 40000, fill_mbps);

    // ---- PHASE D: the coalesced bytes must reach the SCANOUT, and a plane read must forward ----
    // Paint a line at 0x2000 through the four plane windows, ONE lane at a time, so every column
    // arrives as four stores to the same word - the coalescer's case. Column c carries
    // {E=c^C0, G=c^30, R=c^0C, B=c^03}.
    for (ci = 0; ci < LINE_COLS; ci = ci + 1) begin
      put_lane(2'd0, 15'h2000 + ci[14:0], ci[7:0] ^ 8'h03);
      put_lane(2'd1, 15'h2000 + ci[14:0], ci[7:0] ^ 8'h0C);
      put_lane(2'd2, 15'h2000 + ci[14:0], ci[7:0] ^ 8'h30);
      put_lane(2'd3, 15'h2000 + ci[14:0], ci[7:0] ^ 8'hC0);
    end

    // READ-AFTER-WRITE FORWARDING: a plane-window read of the column just written in all four
    // planes must return all four bytes (the held word, not the SDRAM content behind it).
    for (ci = 0; ci < 8; ci = ci + 1) begin
      for (pi = 0; pi < 4; pi = pi + 1) begin
        want = (pi == 0) ? ((ci[7:0]) ^ 8'h03) :
               (pi == 1) ? ((ci[7:0]) ^ 8'h0C) :
               (pi == 2) ? ((ci[7:0]) ^ 8'h30) : ((ci[7:0]) ^ 8'hC0);
        get_col(pi[1:0], 15'h2000 + ci[14:0], got);
        if (got !== want) begin
          $display("FAIL col %0d plane %0d: read %02x want %02x (read-after-write forwarding)", ci, pi, got, want);
          errors = errors + 1;
        end
      end
    end

    // The SCANOUT reads SDRAM on its own requester, so the buffer must have FLUSHED the word
    // before the fetch. One line tick, then the 80 columns must be the pattern.
    scan_enable    = 1'b1;
    scan_page      = 1'b0;
    scan_line_base = 15'h2000;
    @(negedge clk);
    scan_line_tick = 1'b1;
    @(negedge clk);
    scan_line_tick = 1'b0;
    for (i = 0; i < 4000 && !line_ready; i = i + 1) @(posedge clk);
    if (!line_ready) fail("the line fetch never signalled a complete line after the flush");
    line_rd_sel = ~line_sel;
    for (ci = 0; ci < LINE_COLS; ci = ci + 1) begin
      read_line_col(line_rd_sel, ci[6:0], lw);
      if (lw !== {ci[7:0] ^ 8'hC0, ci[7:0] ^ 8'h30, ci[7:0] ^ 8'h0C, ci[7:0] ^ 8'h03}) begin
        $display("FAIL the fetch read column %0d as %08x, want the four coalesced plane bytes", ci, lw);
        errors = errors + 1;
      end
    end
    scan_enable = 1'b0;

    // ---- PHASE E: the CROSS-PAGE restore ----
    // TH01's sprite background-restore walks its columns with the access page (port 0xA6) toggled
    // between the source and destination halves, so a restore comes round the same words
    // repeatedly with the page changing under it. The shape below is that pattern in miniature:
    // TWO columns x two pages, each column's four plane lanes in four stores, the four-word set
    // re-visited eight times with the page toggling once per column-visit. It asserts the restored
    // bytes of both pages through the plain path and the scanout's view of both pages. (When the
    // GVRAM sat behind a write-combining buffer this phase also counted the buffer's write-backs on
    // a page change; that instrument went with the buffer.)
    begin : phase_e
      integer e_round, e_col, e_pg, e_lane, e_visits;
      reg [7:0]  e_got, e_want, e_base;
      reg [31:0] e_exp;
      e_visits = 0;
      repeat (200) @(posedge clk);
      for (e_round = 0; e_round < 8; e_round = e_round + 1) begin
        for (e_col = 0; e_col < 2; e_col = e_col + 1) begin
          for (e_pg = 0; e_pg < 2; e_pg = e_pg + 1) begin
            for (e_lane = 0; e_lane < 4; e_lane = e_lane + 1)
              put_lane_pg(e_pg[0], e_lane[1:0], 15'h3000 + e_col[14:0],
                          e_pg[7:0] * 8'd16 + e_col[7:0] * 8'd4 + e_lane[7:0]);
            e_visits = e_visits + 1;
          end
        end
      end

      // The scanout's view of both pages: a line fetch of each page after the restore must read
      // exactly the bytes written to that page.
      for (e_pg = 0; e_pg < 2; e_pg = e_pg + 1) begin
        scan_enable = 1'b0;
        repeat (4) @(posedge clk);          // the scanout off is what clears line_ready
        scan_enable    = 1'b1;
        scan_page      = e_pg[0];
        scan_line_base = 15'h3000;
        @(negedge clk);
        scan_line_tick = 1'b1;
        @(negedge clk);
        scan_line_tick = 1'b0;
        for (i = 0; i < 4000 && !line_ready; i = i + 1) @(posedge clk);
        if (!line_ready) fail("the cross-page restore's line fetch never completed");
        line_rd_sel = ~line_sel;
        for (ci = 0; ci < 2; ci = ci + 1) begin
          e_base = e_pg[7:0] * 8'd16 + ci[7:0] * 8'd4;
          e_exp  = {e_base + 8'd3, e_base + 8'd2, e_base + 8'd1, e_base};
          read_line_col(line_rd_sel, ci[6:0], lw);
          if (lw !== e_exp) begin
            $display("FAIL phase E: the scanout reads access page %0d column %0d as %08x, want %08x",
                     e_pg, ci, lw, e_exp);
            errors = errors + 1;
          end
        end
        scan_enable = 1'b0;
      end

      $display("NOTE gvram_combine: E cross-page restore: %0d column-visits (2 columns x 2 access pages x 8 rounds)",
               e_visits);

      // The restored bytes, page by page, through the plain path.
      for (e_pg = 0; e_pg < 2; e_pg = e_pg + 1) begin
        for (e_col = 0; e_col < 2; e_col = e_col + 1) begin
          for (e_lane = 0; e_lane < 4; e_lane = e_lane + 1) begin
            e_want = e_pg[7:0] * 8'd16 + e_col[7:0] * 8'd4 + e_lane[7:0];
            get_col_pg(e_pg[0], e_lane[1:0], 15'h3000 + e_col[14:0], e_got);
            if (e_got !== e_want) begin
              $display("FAIL phase E: access page %0d column %0d plane %0d: read %02x want %02x",
                       e_pg, e_col, e_lane, e_got, e_want);
              errors = errors + 1;
            end
          end
        end
      end
    end

    // ---- CHECKS: the path still completed its stores ----
    // The coalescer's transaction-count instruments are gone with the write-combining buffer
    //: in block RAM each store IS its own access, so the only tripwire left is that
    // every measurement phase actually completed stores and that the bytes are correct (above).
    if (a_st1 == 0 || w_st1 == 0 || b_st1 == 0)
      fail("a measurement phase completed no store: the write path is wedged");

    $display("NOTE gvram_combine: coalesced column / uncoalesced fill plane-byte rate = %0.2fx (four plane stores to one word vs four fresh words per store)",
             multi_mbps / ((fill_mbps == 0.0) ? 1.0 : fill_mbps));
    $display("NOTE gvram_combine: the four-plane rate is bounded by the plain client's own accept cadence (C_IDLE + C_RESP for a write: the write arm has no C_RESP2/C_HOLD), not by the GVRAM");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_COMBINE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_GVRAM_COMBINE: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_GVRAM_COMBINE: FAIL");
    end
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_GVRAM_COMBINE: FAIL (timed out)");
  end

endmodule

`default_nettype wire
