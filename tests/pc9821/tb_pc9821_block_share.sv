// tb_pc9821_block_share — ONE block adapter, two devices: the queueing contract.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_BLOCK_SHARE: The hard disk and the floppy share ONE pc9821_block_io engine instead of owning one each, and this bench pins what that changes: a request presented while the engine is serving the other device is QUEUED and completed rather than dropped (the disk asks with a one-cycle pulse, the floppy with a level held until b_busy takes it, both modelled from their own sources), each device receives exactly its own image's 256 words per block in order and nothing else or extra (also while hps_io streams ANOTHER slot's transfer as the request waits for its own acknowledge), only one slot's request ever reaches the host, and neither device can hold the engine for more than a few consecutive transfers. Both images deliberately overlap in LBA space (both devices read blocks 0..7 contended) and the window phase makes each device read blocks the other just cached into the read-ahead window, so a wrong-slot fetch or a stale window hit is a byte mismatch named by block and word - while the DISK's own window must SURVIVE the floppy's hand-over, so a disk block inside the burst it just fetched is replayed from the window with no host handshake at all (the bench FAILS at one handshake there while a hand-over still flushed the window). FAIL-FIRST: with the queue removed (the named noqueue variant) the request presented while the other device owns the engine is dropped and the phase reports sent/received counts.
// The hard disk and the floppy share ONE pc9821_block_io engine instead of owning one each, and this bench pins what that changes: a request presented while the engine is serving the other device is QUEUED and completed rather than dropped (the disk asks with a one-cycle pulse, the floppy with a level held until b_busy takes it, both modelled from their own sources), each device receives exactly its own image's 256 words per block in order and nothing else or extra (also while hps_io streams ANOTHER slot's transfer as the request waits for its own acknowledge), only one slot's request ever reaches the host, and neither device can hold the engine for more than a few consecutive transfers. Both images deliberately overlap in LBA space (both devices read blocks 0..7 contended) and the window phase has each one read a block the other just cached into the read-ahead window, so a wrong-slot fetch or a stale window hit is a byte mismatch named by block and word. FAIL-FIRST: with the queue removed (the named noqueue variant) the request presented while the other device owns the engine is dropped and the phase reports sent/received counts.

`timescale 1ns / 1ps

module tb_pc9821_block_share;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  integer fails = 0;

  // ==== two overlapping 64-block images ====
  // Word (lba, w) of a medium is {lba[7:0] ^ medium, w[7:0]} - a function of the block, the
  // medium and the word, so a word can only come from the right medium at the right address.
  localparam [7:0] MED_A = 8'hA5;   // the hard disk's image
  localparam [7:0] MED_B = 8'h5A;   // the floppy's image
  localparam integer BLOCKS = 64;

  function automatic [15:0] img_a_word(input [31:0] lba, input [7:0] w);
    begin img_a_word = {lba[7:0] ^ MED_A, w}; end
  endfunction

  function automatic [15:0] img_b_word(input [31:0] lba, input [7:0] w);
    begin img_b_word = {lba[7:0] ^ MED_B, w}; end
  endfunction

  // ==== DUT ====
  // the host: the MiSTer block reader for whichever slot is requesting
  reg        a_sd_ack = 0, b_sd_ack = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] a_sd_lba, b_sd_lba;
  wire        a_sd_rd, a_sd_wr, b_sd_rd, b_sd_wr;
  wire [5:0]  a_sd_blk_cnt, b_sd_blk_cnt;

  reg [12:0] widx, wtotal;
  reg [31:0] hlba;
  reg        hbusy, hlast, hslot;   // hslot: 1 = the acknowledged slot is the floppy's
  // ANOTHER SLOT's transfer (S6): hps_io serving a slot outside this module - the CD-ROM's
  // CD-DA stream on slot 4 - streams its words on the same sd_buff bus with neither a_sd_ack
  // nor b_sd_ack up. each request in `foreign_req` makes the host run one 1024-word transfer of that kind
  // before it serves whatever this module is presenting. The sequence raises `foreign_req`;
  // the host counts the transfers it has run in `foreign_done` (each has one writer).
  integer    foreign_req = 0;
  integer    foreign_done;
  reg        hforeign;

  always @(posedge clk) begin
    if (reset) begin
      a_sd_ack <= 1'b0; b_sd_ack <= 1'b0; sd_buff_wr <= 1'b0;
      hbusy <= 1'b0; hlast <= 1'b0; hslot <= 1'b0; widx <= 13'd0;
      hforeign <= 1'b0; foreign_done <= 0;
    end else if (!hbusy && (foreign_done != foreign_req) && !hforeign) begin
      hbusy <= 1'b1; hforeign <= 1'b1; widx <= 13'd0; wtotal <= 13'd1023;
      a_sd_ack <= 1'b0; b_sd_ack <= 1'b0;
    end else if (!hbusy) begin
      sd_buff_wr <= 1'b0;
      // ONE slot at a time, as hps_io presents it: a shared engine may only ever present one
      // device's request, because both slots' payloads arrive on the same sd_buff bus.
      if (a_sd_rd || b_sd_rd) begin
        hbusy     <= 1'b1;
        hslot     <= b_sd_rd;
        a_sd_ack  <= a_sd_rd;
        b_sd_ack  <= b_sd_rd;
        widx      <= 13'd0;
        hlba      <= b_sd_rd ? b_sd_lba : a_sd_lba;
        wtotal    <= ({7'd0, (b_sd_rd ? b_sd_blk_cnt : a_sd_blk_cnt)} + 13'd1) * 13'd256
                     - 13'd1;
      end
    end else begin
      // The word is presented for the whole cycle. The LAST word needs its own cycle with the
      // handshake still up - dropping sd_ack in the same edge would cancel the presentation
      // before the adapter ever saw the word.
      sd_buff_wr   <= 1'b1;
      sd_buff_addr <= widx;
      sd_buff_dout <= hforeign ? (16'hCD00 | {8'd0, widx[7:0]}) :
                      hslot ? img_b_word(hlba + {19'd0, widx[12:8]}, widx[7:0])
                            : img_a_word(hlba + {19'd0, widx[12:8]}, widx[7:0]);
      if (hlast) begin
        if (hforeign) begin hforeign <= 1'b0; foreign_done <= foreign_done + 1; end
        hbusy      <= 1'b0;
        a_sd_ack   <= 1'b0;
        b_sd_ack   <= 1'b0;
        sd_buff_wr <= 1'b0;
        hlast      <= 1'b0;
      end else if (widx == wtotal) begin
        hlast <= 1'b1;
      end else begin
        widx <= widx + 13'd1;
      end
    end
  end

  // ==== the two requesters, each its own device's contract ====
  reg        a_req_read = 0, a_req_write = 0;
  reg [31:0] a_req_lba = 0;
  wire       a_req_done, a_req_error, a_busy;
  wire       a_buf_we;
  wire [ 7:0] a_buf_addr;
  wire [15:0] a_buf_data;
  wire [ 7:0] a_buf_rd_addr;
  reg  [15:0] a_buf_rd_data = 0;

  reg        b_req_read = 0;
  reg [15:0] b_req_lba = 0;
  wire       b_req_done, b_req_error, b_busy;
  wire       b_buf_we;
  wire [ 7:0] b_buf_addr;
  wire [15:0] b_buf_data;

  reg a_img_mounted = 0, b_img_mounted = 0, img_readonly = 1;
  reg [63:0] a_img_size = 0, b_img_size = 0;
  wire a_mounted, a_readonly, a_capacity_unused, b_sd_din_unused, a_sd_din_unused;
  wire [31:0] a_capacity;
  wire [31:0] dbg_hps_unused;

  pc9821_block_share dut (
      // Slot D (the second hard disk): unmounted; every disk request is for slot A.




      .clk(clk), .rst_n(!reset),

      .a_img_mounted(a_img_mounted), .a_img_readonly(img_readonly), .a_img_size(a_img_size),
      .a_mounted(a_mounted), .a_readonly(a_readonly), .a_capacity(a_capacity),
      .a_req_read(a_req_read), .a_req_write(a_req_write), .a_req_lba(a_req_lba),
      .a_req_window(1'b1),
      .a_req_done(a_req_done), .a_req_error(a_req_error), .a_busy(a_busy),
      .a_buf_we(a_buf_we), .a_buf_addr(a_buf_addr), .a_buf_data(a_buf_data),
      .a_buf_rd_addr(a_buf_rd_addr), .a_buf_rd_data(a_buf_rd_data),
      .a_sd_lba(a_sd_lba), .a_sd_blk_cnt(a_sd_blk_cnt), .a_sd_rd(a_sd_rd), .a_sd_wr(a_sd_wr),
      .a_sd_ack(a_sd_ack), .a_sd_buff_din(a_sd_din_unused),

      .b_img_mounted(b_img_mounted), .b_img_readonly(img_readonly), .b_img_size(b_img_size),
      .b_req_read(b_req_read), .b_req_lba(b_req_lba),
      .b_req_done(b_req_done), .b_req_error(b_req_error), .b_busy(b_busy),
      .b_buf_we(b_buf_we), .b_buf_addr(b_buf_addr), .b_buf_data(b_buf_data),
      .b_sd_lba(b_sd_lba), .b_sd_blk_cnt(b_sd_blk_cnt), .b_sd_rd(b_sd_rd), .b_sd_wr(b_sd_wr),
      .b_sd_ack(b_sd_ack), .b_sd_buff_din(b_sd_din_unused),

      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),

      .dbg_hps_cycles(dbg_hps_unused)
  );

  // ==== CHECKS ====
  // what each device ASKS and what it RECEIVES
  integer a_sent = 0, a_got = 0, a_err = 0;
  integer b_sent = 0, b_got = 0, b_err = 0;
  integer a_words = 0, b_words = 0;
  reg [31:0] a_exp_lba = 0, b_exp_lba = 0;
  integer a_bad_addr = 0, b_bad_addr = 0, a_bad_data = 0, b_bad_data = 0;
  integer both_rd = 0;                         // cycles in which BOTH slots asked at once
  integer a_run = 0, b_run = 0;                // consecutive completions, for starvation
  integer a_max_run = 0, b_max_run = 0;

  always @(posedge clk) begin
    if (a_req_done) begin
      a_got <= a_got + 1;
      if (a_words !== 256) begin
        $display("  FAIL: A received %0d words for one block, expected 256 (block %0d)",
                 a_words, a_exp_lba);
        fails <= fails + 1;
      end
      if (a_req_error) a_err <= a_err + 1;
      a_words <= 0;
      a_run   <= a_run + 1;
      b_run   <= 0;
      if (a_run + 1 > a_max_run) a_max_run <= a_run + 1;
    end
  end

  always @(posedge clk) begin
    if (b_req_done) begin
      b_got <= b_got + 1;
      if (b_words !== 256) begin
        $display("  FAIL: B received %0d words for one block, expected 256 (block %0d)",
                 b_words, b_exp_lba);
        fails <= fails + 1;
      end
      if (b_req_error) b_err <= b_err + 1;
      b_words <= 0;
      b_run   <= b_run + 1;
      a_run   <= 0;
      if (b_run + 1 > b_max_run) b_max_run <= b_run + 1;
    end
  end

  // The block the disk is being handed: its OWN image's words, address 0..255 in order.
  always @(posedge clk) if (a_buf_we) begin
    if (a_buf_addr !== a_words[7:0]) a_bad_addr <= a_bad_addr + 1;
    if (a_buf_data !== img_a_word(a_exp_lba, a_buf_addr)) begin
      if (a_bad_data == 0)
        $display("  FAIL: A block %0d word %0d: got %04x, expected %04x",
                 a_exp_lba, a_buf_addr, a_buf_data, img_a_word(a_exp_lba, a_buf_addr));
      a_bad_data <= a_bad_data + 1;
    end
    a_words <= a_words + 1;
  end

  // The block the floppy is being handed: its OWN image's words.
  always @(posedge clk) if (b_buf_we) begin
    if (b_buf_addr !== b_words[7:0]) b_bad_addr <= b_bad_addr + 1;
    if (b_buf_data !== img_b_word(b_exp_lba, b_buf_addr)) begin
      if (b_bad_data == 0)
        $display("  FAIL: B block %0d word %0d: got %04x, expected %04x",
                 b_exp_lba, b_buf_addr, b_buf_data, img_b_word(b_exp_lba, b_buf_addr));
      b_bad_data <= b_bad_data + 1;
    end
    b_words <= b_words + 1;
  end

  // ONE SLOT AT A TIME: a shared engine may only ever present one device's request to the host.
  always @(posedge clk)
    if (!reset && (a_sd_rd || a_sd_wr) && (b_sd_rd || b_sd_wr)) both_rd <= both_rd + 1;

  // The DISK's host handshakes, so a phase can ask whether a block it should have had cached
  // cost one. A window hit is served by replaying the cache and never reaches the host.
  integer a_host_reqs = 0, a_host_base = 0;

  // The WORST cycle a request spent between being issued and completing, per device: T9's
  // contract is that the loser of a hand-over waits at most for the winner's in-flight
  // handshake, and the burst this engine fetches is what bounds that wait (BURST_SECTORS
  // blocks of 256 words one cycle apart).
  integer a_worst_wait = 0, b_worst_wait = 0;
  always @(posedge clk) if (!reset && a_sd_rd) a_host_reqs <= a_host_reqs + 1;

  // ==== the sequences ====
  task automatic a_issue(input [31:0] lba);
    begin
      a_req_lba = lba; a_exp_lba = lba; a_words = 0;
      @(negedge clk); a_req_read = 1;
      @(negedge clk); a_req_read = 0;
      a_sent = a_sent + 1;
    end
  endtask

  task automatic a_wait(input integer limit);
    integer k;
    begin
      k = 0;
      while (!a_req_done && k < limit) begin @(negedge clk); k = k + 1; end
      if (!a_req_done) begin
        $display("  FAIL: A's request for block %0d never completed (%0d cycles)",
                 a_exp_lba, limit);
        fails = fails + 1;
      end
      if (k > a_worst_wait) a_worst_wait = k;
      @(negedge clk);
    end
  endtask

  // The floppy's request is a level, released the way pc9821_fdd_media releases it: on
  // blk_busy (the adapter has it) or on its completion.
  task automatic b_issue(input [15:0] lba);
    begin
      b_req_lba = lba; b_exp_lba = lba; b_words = 0;
      @(negedge clk); b_req_read = 1;
      b_sent = b_sent + 1;
    end
  endtask

  task automatic b_wait(input integer limit);
    integer k;
    begin
      k = 0;
      while (!b_req_done && k < limit) begin
        @(negedge clk); k = k + 1;
        if (b_busy) b_req_read = 0;
      end
      if (!b_req_done) begin
        $display("  FAIL: B's request for block %0d never completed (%0d cycles)",
                 b_exp_lba, limit);
        fails = fails + 1;
      end
      if (k > b_worst_wait) b_worst_wait = k;
      b_req_read = 0;
      @(negedge clk);
    end
  endtask

  task automatic check_counts(input [8*48-1:0] what);
    begin
      if (a_sent !== a_got) begin
        $display("  FAIL: %0s: A issued %0d request(s) and received %0d completion(s)",
                 what, a_sent, a_got);
        fails = fails + 1;
      end
      if (b_sent !== b_got) begin
        $display("  FAIL: %0s: B issued %0d request(s) and received %0d completion(s)",
                 what, b_sent, b_got);
        fails = fails + 1;
      end
    end
  endtask

  integer i;

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_BLOCK_SHARE: watchdog timeout (no verdict reached)");
  end

  initial begin
    repeat (20) @(negedge clk);
    reset = 0;
    repeat (10) @(negedge clk);

    // ---- mount both images ----
    a_img_size = BLOCKS * 512; b_img_size = BLOCKS * 512;
    @(negedge clk); a_img_mounted = 1; b_img_mounted = 1;
    @(negedge clk); a_img_mounted = 0; b_img_mounted = 0;
    repeat (10) @(negedge clk);

    if (a_mounted !== 1'b1 || a_capacity !== BLOCKS) begin
      $display("  FAIL: the disk slot's metadata did not latch (mounted %0b, capacity %0d)",
               a_mounted, a_capacity);
      fails = fails + 1;
    end

    // ---- S1/S2: one request each, each while the engine is idle ----
    a_issue(32'd3);  a_wait(200000);
    b_issue(16'd3);  b_wait(200000);
    check_counts("single requests");

    // ---- S4: the WINDOW may not answer one medium out of the other's cache ----
    // Three contiguous disk reads make the third a burst (pc9821_block_io's run detector), so
    // the disk's window holds blocks 14..21 while the floppy asks for 15 - the same LBA out of
    // the other image. The window carries its OWNER's tag, so the floppy cannot be answered
    // from the disk's cache and the checkers above name the block and word if one ever is.
    a_issue(32'd12); a_wait(200000);
    a_issue(32'd13); a_wait(200000);
    a_issue(32'd14); a_wait(200000);   // burst from 14
    b_issue(16'd15); b_wait(200000);   // the floppy's block 15
    // ... and the DISK's window must have SURVIVED that hand-over: block 19 is inside the
    // burst the disk just fetched (14..21), so it must be replayed from the window with NO
    // host handshake at all. FAIL-FIRST: while the hand-over loaded the engine's metadata it
    // also flushed the window, and this cost the disk a fresh fetch.
    a_host_base = a_host_reqs;
    a_issue(32'd19); a_wait(200000);   // the disk's block 19
    if (a_host_reqs != a_host_base) begin
      $display("  FAIL: the disk's in-window block 19 cost %0d host handshake(s): the floppy's hand-over threw the disk's read-ahead window away",
               a_host_reqs - a_host_base);
      fails = fails + 1;
    end
    // ... and the floppy keeps its own side of the bargain: it is served ONE block per
    // handshake (docs/trade-candidates.md T7/T8), which is what leaves the disk's window - and
    // its run - alone. Three contiguous floppy reads used to make ITS third one a burst.
    b_issue(16'd16); b_wait(200000);
    b_issue(16'd17); b_wait(200000);
    b_issue(16'd18); b_wait(200000);
    a_host_base = a_host_reqs;
    a_issue(32'd16); a_wait(200000);   // the disk's block 16, inside its burst window
    if (a_host_reqs != a_host_base) begin
      $display("  FAIL: after three floppy reads the disk's in-window block 16 cost %0d host handshake(s): the floppy's reads are destroying the disk's window",
               a_host_reqs - a_host_base);
      fails = fails + 1;
    end
    check_counts("cross-medium window test");

    // ---- S3: contention. Both devices ask at once, every round ----
    // The engine can only serve one, so the queue must hold the other and the alternation must
    // hand it the engine next; a device held for more than a few consecutive transfers is a
    // starvation FAIL. Both read blocks 0..7, i.e. the same LBAs out of different images.
    a_sent = 0; a_got = 0; b_sent = 0; b_got = 0;
    for (i = 0; i < 8; i = i + 1) begin
      a_issue(i[31:0]);
      b_issue(i[15:0]);
      a_wait(200000);
      b_wait(200000);
    end
    check_counts("contended requests");
    if (a_got !== 8 || b_got !== 8) begin
      $display("  FAIL: contended requests completed A=%0d B=%0d of 8 each", a_got, b_got);
      fails = fails + 1;
    end
    if (a_max_run > 4 || b_max_run > 4) begin
      $display("  FAIL: a device held the engine for %0d/%0d consecutive transfers",
               a_max_run, b_max_run);
      fails = fails + 1;
    end

    // ---- S6: ANOTHER slot's transfer while a request waits for its own acknowledge ----
    // The request is presented (sd_rd up) while hps_io is still streaming a slot outside this
    // module - the CD-ROM's CD-DA on slot 4 - so 1024 words go by with this module's acks low.
    // Neither device may take one of them: the S5 checkers name any word that is not the
    // device's own image's, and the per-block count catches an early completion. FAIL-FIRST:
    // with pc9821_block_io counting every sd_buff_wr while in F_REQ, the disk's block arrived
    // as the foreign stream (Policenauts' intro).
    a_sent = 0; a_got = 0; b_sent = 0; b_got = 0;
    @(negedge clk); foreign_req = foreign_req + 1;
    a_issue(32'd40); a_wait(200000);
    @(negedge clk); foreign_req = foreign_req + 1;
    b_issue(16'd41); b_wait(200000);
    check_counts("requests behind another slot's transfer");
    if (foreign_done != 2) begin
      $display("  FAIL: the host ran %0d foreign transfer(s), expected 2", foreign_done);
      fails = fails + 1;
    end

    // ---- S5: the data itself ----
    if (a_bad_addr || b_bad_addr) begin
      $display("  FAIL: a block's words did not arrive in order (A %0d, B %0d)",
               a_bad_addr, b_bad_addr);
      fails = fails + 1;
    end
    if (a_bad_data) begin
      $display("  FAIL: the disk received %0d word(s) that are not its own image's", a_bad_data);
      fails = fails + 1;
    end
    if (b_bad_data) begin
      $display("  FAIL: the floppy received %0d word(s) that are not its own image's", b_bad_data);
      fails = fails + 1;
    end
    if (a_err || b_err) begin
      $display("  FAIL: a completion carried an error (A %0d, B %0d)", a_err, b_err);
      fails = fails + 1;
    end
    if (both_rd) begin
      $display("  FAIL: both slots requested in the same cycle %0d time(s)", both_rd);
      fails = fails + 1;
    end

    $display("BLOCK_SHARE WAIT: worst issue-to-completion A %0d clk, B %0d clk (a burst fetch is %0d blocks x 256 words + the arbitration)",
             a_worst_wait, b_worst_wait, 8);
    if (a_worst_wait > 4096 || b_worst_wait > 4096) begin
      $display("  FAIL: a request waited %0d/%0d clk (bound 4096, one burst fetch is ~2 kclk): a device is queueing behind the other's WHOLE transfer rather than its in-flight handshake",
               a_worst_wait, b_worst_wait);
      fails = fails + 1;
    end
    if (fails == 0)
      $display("BLOCK_SHARE SUMMARY: A %0d blocks, B %0d blocks, longest runs %0d/%0d",
               a_got, b_got, a_max_run, b_max_run);

    // ==== VERDICT ====
    // $fatal, not $finish: Verilator's $finish returns from the process with status 0, so a
    // failing run has to raise the exit code itself (this bench's counter is `fails`, which
    // is why tools/check_tests.py's `errors`-shaped detector could not see this verdict).
    if (fails == 0) begin
      $display("TB_PC9821_BLOCK_SHARE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_BLOCK_SHARE: FAIL (%0d failures)", fails);
  end

endmodule
