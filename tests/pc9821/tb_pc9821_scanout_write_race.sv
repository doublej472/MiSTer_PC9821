`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SCANOUT_WRITE_RACE:
// The scanout's one-line-ahead ping-pong prefetch against a concurrent GVRAM write, on the REAL pc9821_gvram fetch and line buffer read through the REAL pc9821_video_mixer's read port, byte-exact: a write to the line currently on screen is not picked up until that line is fetched again (the displayed BRAM snapshot is byte-identical before and after the write, no mid-line tear); a write to the line already prefetched shows the OLD value for the whole line on the next raster (consistent, no half-written line); the WCB flush the line tick sets makes a dirty word reach SDRAM before the fetch reads it (the partial store is still only in the buffer at the tick, and the fetched line carries the merged word); and a full-word GRCG write racing the fetch never presents a corrupted column word (every fetched column is a whole old word or a whole new word) even when the fetch catches the group mid-write and tears the line at its own burst boundary.

`default_nettype none

module tb_pc9821_scanout_write_race;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;
  localparam [31:0] NEW_WORD   = 32'hE0E0_E0E0;
  localparam integer NW        = 80;

  // ==== DUT ====
  // pc9821_gvram, its two SDRAM requesters, and the shared backend store.
  reg  [1:0]  win_plane = 2'd0;
  reg  [14:0] win_offset = 15'd0;
  reg  [31:0] cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'hF;
  reg         cpu_line_read = 1'b0, cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  reg         grcg_we = 1'b0;
  reg  [7:0]  grcg_addr = 8'd0, grcg_din = 8'd0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;
  wire [6:0]  line_rd_addr;
  wire        line_rd_sel;
  reg         scan_enable = 1'b0;
  reg         scan_line_tick = 1'b0;
  reg         scan_page = 1'b0;
  reg [14:0]  scan_line_base = 15'd0;


  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) u_gvram (
      .clk(clk), .reset(reset),
      .access_page(1'b0),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(1'b0), .egc_access(16'hFFFF), .egc_fgbg(16'd0), .egc_ope(16'd0),
      .egc_fg(16'd0), .egc_mask(16'hFFFF), .egc_bg(16'd0),
      .egc_sft(16'd0), .egc_leng(16'd0), .egc_shift_we(1'b0),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  

  // The display read: the REAL mixer owns line_rd_addr and line_rd_sel exactly as
  // pc9821_system wires them, and line_data is the gvram's registered answer.
  reg  [9:0] dot_x = 10'd0;
  reg        h_active = 1'b1, v_active = 1'b1;
  wire [7:0] r_out, g_out, b_out;
  // The PEGC arm's inputs (pegc-scope-REPORT.md 4 row 4): tied off in the
  // 16-colour benches; tb_pc9821_video_mixer drives them.
  reg        mix_pegc_256 = 1'b0;
  reg        mix_pal256_wr_en = 1'b0;
  reg  [7:0] mix_pal256_wr_idx = 8'd0, mix_pal256_wr_data = 8'd0;
  reg  [1:0] mix_pal256_wr_chan = 2'd0;
  pc9821_video_mixer u_mixer (
      .dot_x(dot_x), .h_active(h_active), .v_active(v_active),
      .text_opaque(1'b0), .text_cell(1'b0), .text_colour(12'h000),
      .line_data(line_data), .line_ready(line_ready), .line_sel(line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .clk(clk), .rst_n(1'b1),
      .pal_mode16(1'b1), .pal_dig(32'd0),
      .pal_wr_en(1'b0), .pal_wr_idx(4'd0), .pal_wr_chan(2'd0), .pal_wr_data(4'd0),
      .pal_commit(1'b0),
      .fold_bypass(1'b0), .packed_idx(8'h00),
    .pegc_256(mix_pegc_256),
    .pal256_wr_en(mix_pal256_wr_en), .pal256_wr_idx(mix_pal256_wr_idx),
    .pal256_wr_chan(mix_pal256_wr_chan), .pal256_wr_data(mix_pal256_wr_data),
      .comp_rule(2'b00), .grph_disp(1'b1),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  // ==== STIMULUS ====
  integer errors = 0;
  integer c, p, t, g;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // The OLD image: every plane byte carries its plane in bits 4-5 and the plane
  // offset's low nibble in bits 0-3, so a fetched word names both its column and
  // whether it is stale (0x10..0x4F) or rewritten by the GRCG (0xE0).
  function [31:0] old_word(input [14:0] off);
    reg [7:0] nib;
    begin
      nib = {4'd0, off[3:0]};
      old_word = {8'h40 | nib, 8'h30 | nib, 8'h20 | nib, 8'h10 | nib};
    end
  endfunction

  function [14:0] bline(input integer idx);
    begin
      bline = idx * 80;
    end
  endfunction

  // Paint a picture line's whole OLD image straight into the backend store. This is
  // setup (the write paths have their own benches); the race under test is real.
  task automatic poke_old(input [14:0] base);
    begin
      for (c = 0; c < NW; c = c + 1) begin
        u_gvram.u_gmem.mem0[base + c] = old_word(base + c)[ 7: 0];
        u_gvram.u_gmem.mem1[base + c] = old_word(base + c)[15: 8];
        u_gvram.u_gmem.mem2[base + c] = old_word(base + c)[23:16];
        u_gvram.u_gmem.mem3[base + c] = old_word(base + c)[31:24];
      end
    end
  endtask

  // One raster line tick: the gvram takes the edge and starts fetching `base`.
  task automatic tick(input [14:0] base);
    begin
      scan_line_base = base;
      @(negedge clk); scan_line_tick = 1'b1;
      @(posedge clk);
      @(negedge clk); scan_line_tick = 1'b0;
    end
  endtask

  task automatic wait_fetch_start;
    begin
      g = 0;
      // The fetch goes active the clk_sys after the tick; there is no SDRAM request to watch.
      while (!u_gvram.u_scan.fetch_active && (g < 2000)) begin @(negedge clk); g = g + 1; end
    end
  endtask

  task automatic wait_fetch_done;
    begin
      g = 0;
      while (!u_gvram.u_scan.fetch_active && (g < 2000)) begin @(posedge clk); g = g + 1; end
      g = 0;
      // The fill is complete when the last column's registered read has landed: fetch_req_d is
      // the DUT's own one-clk_sys-deep in-flight flag.
      while (!(!u_gvram.u_scan.fetch_active && !u_gvram.u_scan.fetch_req_d) && (g < 4000)) begin
        @(posedge clk); g = g + 1;
      end
    end
  endtask

  // Sample the DISPLAYED line through the mixer's own read port one cycle after each
  // column's address, exactly the registered latency the pixel pipeline sees.
  reg [31:0] cap [0:NW-1];
  task automatic capture;
    begin
      for (c = 0; c < NW; c = c + 1) begin
        dot_x = c[9:0] << 3;
        @(posedge clk);
        #1;
        cap[c] = line_data;
      end
    end
  endtask

  // Classify the captured line against the old image and the GRCG's word. `alien` is a
  // byte that is neither, `mix` a word that mixes old and new bytes (the byte-tear).
  integer n_old, n_new, n_merge, n_mix, n_alien;
  // A partial store is expected to be visible whole in the fetched line: the WCB merge
  // writes the word back full, so `exp_off`'s byte carries the stored value and the
  // other three carry the old word. Any other mixed word is a byte-tear.
  integer exp_off = -1;
  reg [7:0] exp_byte = 8'h00;
  function [31:0] merge_word(input [14:0] off, input [7:0] b);
    begin
      merge_word = {old_word(off)[31:8], b};
    end
  endfunction
  task automatic classify(input [14:0] base);
    reg [31:0] w, ow;
    reg saw_old, saw_new, byte_bad;
    begin
      n_old = 0; n_new = 0; n_merge = 0; n_mix = 0; n_alien = 0;
      for (c = 0; c < NW; c = c + 1) begin
        w  = cap[c];
        ow = old_word(base + c);
        if (w === ow) n_old = n_old + 1;
        else if (w === NEW_WORD) n_new = n_new + 1;
        else if ((exp_off >= 0) && (c == exp_off) && (w === merge_word(base + c, exp_byte)))
          n_merge = n_merge + 1;
        else begin
          saw_old = 1'b0; saw_new = 1'b0; byte_bad = 1'b0;
          for (p = 0; p < 4; p = p + 1) begin
            if (w[8*p +: 8] === ow[8*p +: 8]) saw_old = 1'b1;
            else if (w[8*p +: 8] === 8'hE0) saw_new = 1'b1;
            else byte_bad = 1'b1;
          end
          if (byte_bad) n_alien = n_alien + 1;
          else          n_mix   = n_mix + 1;
        end
      end
    end
  endtask

  task automatic op(input [1:0] plane, input [14:0] off, input [31:0] din,
                    input [3:0] be, input wr, output [31:0] dout);
    begin
      @(negedge clk);
      win_plane = plane; win_offset = off; cpu_din = din; cpu_be = be;
      cpu_write = wr; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      dout = 32'd0;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      repeat (2) @(posedge clk);
    end
  endtask

  // A partial store through a plane window: one byte lane of one column word.
  task automatic put_byte(input [1:0] plane, input [14:0] off, input [7:0] val);
    reg [31:0] d;
    begin
      op(plane, off, {24'd0, val} << (off[1:0] * 8), 4'b0001 << off[1:0], 1'b1, d);
    end
  endtask

  // The GRCG TDW store: mode bit 7 on, four tile bytes, then a full-word store per
  // enabled CPU lane, so one grcg_store4 writes the four columns off..off+3, whole.
  task automatic grcg_begin(input [7:0] tile);
    begin
      @(negedge clk);
      grcg_we = 1'b1; grcg_addr = 8'h7C; grcg_din = 8'h80;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_addr = 8'h7E; grcg_din = tile;
      @(negedge clk); grcg_we = 1'b0;
    end
  endtask

  task automatic grcg_store4(input [14:0] off);
    reg [31:0] d;
    begin
      op(2'd0, off, 32'hFFFF_FFFF, 4'hF, 1'b1, d);
    end
  endtask

  task automatic grcg_end;
    begin
      @(negedge clk);
      grcg_we = 1'b1; grcg_addr = 8'h7C; grcg_din = 8'h00;
      @(negedge clk); grcg_we = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // ==== CHECKS ====
  integer base_a, base_b, base_x;
  integer trials, all_old, splits, byte_tears, g_new, grp_out;
  reg [31:0] cap_prev [0:NW-1];
  integer diff;

  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    for (g = 0; g < 65536; g = g + 1) begin
      u_gvram.u_gmem.mem0[g] = 8'd0; u_gvram.u_gmem.mem1[g] = 8'd0;
      u_gvram.u_gmem.mem2[g] = 8'd0; u_gvram.u_gmem.mem3[g] = 8'd0;
    end
    scan_enable = 1'b1;

    // (0) baseline: a painted line fetches and displays byte-exact, no writer.
    base_a = bline(1);
    poke_old(base_a);
    tick(base_a); wait_fetch_done();
    tick(base_a); wait_fetch_done();
    capture; classify(base_a);
    $display("NOTE scanout_write_race: baseline col old=%0d new=%0d mix=%0d alien=%0d",
             n_old, n_new, n_mix, n_alien);
    if (n_old != NW) fail("baseline: the displayed line is not the whole old image");

    // (a) a store to the CURRENTLY DISPLAYED line: not picked up mid-line.
    base_a = bline(2); base_b = bline(3);
    poke_old(base_a); poke_old(base_b);
    tick(base_a); wait_fetch_done();
    tick(base_b); wait_fetch_done();
    capture;
    for (c = 0; c < NW; c = c + 1) cap_prev[c] = cap[c];
    put_byte(2'd0, base_a + 5, 8'h99);
    capture;
    diff = 0;
    for (c = 0; c < NW; c = c + 1) if (cap[c] !== cap_prev[c]) diff = diff + 1;
    classify(base_a);
    $display("NOTE scanout_write_race: (a) displayed write col old=%0d new=%0d mix=%0d alien=%0d, %0d column(s) changed mid-line",
             n_old, n_new, n_mix, n_alien, diff);
    if (diff != 0) fail("(a) the displayed line changed under a store to the displayed line");
    if (n_old != NW) fail("(a) the displayed line is not the old image");
    if (u_gvram.u_gmem.mem0[base_a + 5] !== 8'h99)
      fail("(a) the store did not reach the array immediately (read-after-write)");
    exp_off = 5; exp_byte = 8'h99;
    tick(base_a); wait_fetch_done();
    tick(base_b); wait_fetch_done();
    capture; classify(base_a);
    exp_off = -1;
    $display("NOTE scanout_write_race: (a) next fetch of that line col old=%0d merged=%0d new=%0d mix=%0d alien=%0d",
             n_old, n_merge, n_new, n_mix, n_alien);
    if (cap[5][7:0] !== 8'h99) fail("(a) the write never appeared on the line's next fetch");

    // (b) a store to the NEXT line AFTER its prefetch: the display shows the old line.
    base_a = bline(4); base_b = bline(5);
    poke_old(base_a);
    tick(base_a); wait_fetch_done();
    grcg_begin(8'hE0); grcg_store4(base_a + 12); grcg_store4(base_a + 16); grcg_end();
    tick(base_b); wait_fetch_done();
    capture; classify(base_a);
    $display("NOTE scanout_write_race: (b) prefetched-line write, same raster col old=%0d new=%0d mix=%0d alien=%0d",
             n_old, n_new, n_mix, n_alien);
    if (n_mix != 0 || n_alien != 0) fail("(b) the displayed line is not a whole-old/whole-new line");
    if (n_old != NW) begin
      $display("FAIL (b) a write after the prefetch was already visible on the displayed line");
      errors = errors + 1;
    end
    tick(base_a); wait_fetch_done();
    tick(base_b); wait_fetch_done();
    capture; classify(base_a);
    $display("NOTE scanout_write_race: (b) that line on its NEXT fetch col old=%0d new=%0d mix=%0d alien=%0d",
             n_old, n_new, n_mix, n_alien);
    if (n_new != 8) fail("(b) the write did not appear as 8 new columns on the line's next fetch");

    // (c) the WCB flush before the scanout: a dirty word reaches SDRAM before the fetch.
    base_a = bline(6); base_x = bline(7);
    poke_old(base_a);
    put_byte(2'd0, base_a + 7, 8'hA5);
    // The array holds the store the instant its clk_sys edge passes, so the line's own fetch
    // reads the NEW byte. There is no write-back window for the fetch to read behind, which is
    // the old stripe defect by construction.
    if (u_gvram.u_gmem.mem0[base_a + 7] !== 8'hA5)
      fail("(c) the store did not reach the array immediately (read-after-write)");
    scan_line_base = base_a;
    @(negedge clk); scan_line_tick = 1'b1;
    @(posedge clk);
    @(negedge clk); scan_line_tick = 1'b0;
    wait_fetch_done();
    if (u_gvram.u_gmem.mem0[base_a + 7] !== 8'hA5)
      fail("(c) the array lost the store across the fetch");
    exp_off = 7; exp_byte = 8'hA5;
    tick(base_x); wait_fetch_done();
    capture; classify(base_a);
    exp_off = -1;
    $display("NOTE scanout_write_race: (c) flushed line col old=%0d merged=%0d new=%0d mix=%0d alien=%0d, column 7 byte0=%02x",
             n_old, n_merge, n_new, n_mix, n_alien, cap[7][7:0]);
    if (cap[7][7:0] !== 8'hA5) fail("(c) the fetched line does not carry the merged word");

    // (d) a full-word GRCG write of ONE four-column group racing the line fetch, at every
    //     group position: every fetched column word must be whole-old or whole-new, and the
    //     report names any group the fetch caught part-written.
    trials = 0; all_old = 0; splits = 0; byte_tears = 0;
    for (t = 0; t < 20; t = t + 1) begin
      base_a = bline(10 + t);
      base_x = bline(60);
      poke_old(base_a);
      tick(base_a);
      wait_fetch_start();
      grcg_begin(8'hE0); grcg_store4(base_a + (t * 4)); grcg_end();
      wait_fetch_done();
      tick(base_x); wait_fetch_done();
      capture; classify(base_a);
      trials = trials + 1;
      if (n_mix != 0 || n_alien != 0) begin
        byte_tears = byte_tears + 1;
        $display("FAIL (d) group col %0d: a fetched column word is neither old nor new: mix=%0d alien=%0d",
                 t * 4, n_mix, n_alien);
        errors = errors + 1;
      end
      g_new = 0; grp_out = 0;
      for (c = 0; c < NW; c = c + 1)
        if (cap[c] === NEW_WORD) begin
          if ((c >= (t * 4)) && (c < ((t * 4) + 4))) g_new = g_new + 1;
          else                                      grp_out = grp_out + 1;
        end
      if ((g_new == 0) && (grp_out == 0)) all_old = all_old + 1;
      else if ((g_new == 4) && (grp_out == 0))
        $display("NOTE scanout_write_race: (d) group col %0d read whole-new (4 of 4) before the fetch reached it",
                 t * 4);
      else begin
        splits = splits + 1;
        $display("NOTE scanout_write_race: (d) SPLIT: group col %0d read %0d of its 4 written columns new, %0d new column(s) outside it",
                 t * 4, g_new, grp_out);
      end
    end
    $display("NOTE scanout_write_race: (d) 4-column group position sweep: %0d trial(s), %0d all-old, %0d split, %0d byte-tear(s)",
             trials, all_old, splits, byte_tears);

    // (d2) a WHOLE-LINE write racing the fetch: 20 groups released at the fetch start.
    base_a = bline(70); base_x = bline(60);
    poke_old(base_a);
    tick(base_a);
    wait_fetch_start();
    grcg_begin(8'hE0);
    for (t = 0; t < 20; t = t + 1) grcg_store4(base_a + (t * 4));
    grcg_end();
    wait_fetch_done();
    tick(base_x); wait_fetch_done();
    capture; classify(base_a);
    $display("NOTE scanout_write_race: (d2) whole-line write raced: old=%0d new=%0d mix=%0d alien=%0d",
             n_old, n_new, n_mix, n_alien);
    if (n_mix != 0 || n_alien != 0) fail("(d2) a fetched column word is neither old nor new");
    if (n_new == NW)
      $display("NOTE scanout_write_race: (d2) the write stream completed before the fetch read any column");

    // The byte-tear detector must fire on one mixed word; the DUT never presents one,
    // so this is the only way the assertion is seen to be able to fail.
    base_a = bline(80);
    for (c = 0; c < NW; c = c + 1) cap[c] = old_word(base_a + c);
    cap[11] = {old_word(base_a + 11)[31:8], 8'hE0};
    classify(base_a);
    $display("NOTE scanout_write_race: detector self-check on one 1-of-4 mixed word: mix=%0d alien=%0d",
             n_mix, n_alien);
    if (n_mix != 1) fail("the byte-tear detector does not flag a mixed column word");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SCANOUT_WRITE_RACE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_SCANOUT_WRITE_RACE: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_SCANOUT_WRITE_RACE: TIMEOUT");
  end

endmodule

`default_nettype wire
