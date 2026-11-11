`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDD_MOUNT_HOLD: pc9821_fdd_media LATCHES a mount that arrives while the module is held in reset and applies it, with the image size that came with it, when the module is released - so the HPS boot mount, whose single-cycle img_mounted pulse lands before the firmware pack download finishes, is no longer discarded. The module's reset term is pc9821_system's `reset || !cpu_run` and cpu_run is low for the whole pack download, so the pre-change tree took that pulse into the reset branch and never mounted: the guest booted with no floppy. FAIL-FIRST: the same mount with the module released (the control) is present, and with cpu_run held low across the pulse the pre-change tree answered present=0. The bench covers the ordering that matters - the image is listed before the pack finishes - and the second hazard in the same window: hps_io's img_size is valid only while img_mounted is asserted, so the size is latched with the request and a foreign disk-sized value arriving after the pulse cannot change the medium that mounts (that arm mounts a RAW image while held, overwrites img_size with 8000000, releases, and requires present=1 and the raw image's sector bytes; the pre-latch tree parsed with the foreign size and answered present=0).
//
// WHY THE RESET TERM IS MODELLED HERE. The D88 bench (tb_pc9821_fdd_media_d88) wires the
// module's reset to the platform reset alone and mounts after the reset has lifted, so it
// cannot see this: the whole finding lives in the `!cpu_run` half of the term, which the
// integration adds (pc9821_system wires `.reset(reset || !cpu_run)` into the floppy medium).
// This harness therefore drives that same term from its own `cpu_run` register, so the only
// variable between its arms is WHEN the mount pulse arrives relative to cpu_run.
//
// REFERENCES (external). hps_io's `img_mounted` is a single-cycle pulse and its `img_size` is
// "valid only for active bit in img_mounted" - sys/hps_io.sv:145 "size of image in bytes" -
// which is why both are latched together; `pc9821_block_share` - the shared adapter this module's fetches go
// through - latches each slot's size at the same pulse for the same reason (its a_capacity/
// b_capacity arm). The D88 layout and the sector walk are the ones tb_pc9821_fdd_media_d88
// pins against NP2kai's own readers; this bench reuses a minimal instance of it so the
// mount's RESULT is checked (present AND the medium's bytes), not just the flag.
//
// ==== DUT ====
// The real pair: pc9821_fdd_media + the shared block adapter, exactly as pc9821_system wires
// them, with the host side a model of the MiSTer block reader (sd_ack held for the transfer,
// one 16-bit word per clk at sd_buff_addr, (sd_blk_cnt+1) sectors per handshake).
`define IMGMAX 1310720

module tb_pc9821_fdd_mount_hold;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== the image: a synthetic D88 laid out byte by byte ====
  // 0x2B0 header, then track 0 with two sectors (R=1 and R=2, both 1024 B). fd_size is the
  // exact end of track 0.
  localparam integer T0_OFF = 688;                                    // 0x2B0
  localparam integer IMG_BYTES = T0_OFF + 16 + 1024 + 16 + 1024;       // 2768

  reg [7:0] img [0:`IMGMAX-1];

  function automatic [7:0] secpat(input [7:0] r, input integer j);
    secpat = (j * 7 + r * 13) & 8'hFF;
  endfunction

  task automatic put_d88_header;
    integer t, j;
    begin
      for (j = 0; j < 688; j = j + 1) img[j] = 8'h00;
      img[8'h1B] = 8'h20;                     // fd_type: DISKTYPE_2HD (major 2)
      img[8'h1C] = IMG_BYTES[7:0];            // fd_size, little-endian 32-bit
      img[8'h1D] = IMG_BYTES[15:8];
      img[8'h1E] = IMG_BYTES[23:16];
      img[8'h1F] = IMG_BYTES[31:24];
      for (t = 0; t < 164; t = t + 1) begin
        img[8'h20 + 4*t + 0] = 8'h00;
        img[8'h20 + 4*t + 1] = 8'h00;
        img[8'h20 + 4*t + 2] = 8'h00;
        img[8'h20 + 4*t + 3] = 8'h00;
      end
      img[8'h20 + 0] = T0_OFF[7:0];           // track 0 -> 0x2B0
      img[8'h20 + 1] = T0_OFF[15:8];
    end
  endtask

  task automatic put_sec_header(input integer off, input [7:0] c, h, r, nn,
                                input integer nsec, input integer size);
    begin
      img[off+0] = c; img[off+1] = h; img[off+2] = r; img[off+3] = nn;
      img[off+4] = nsec[7:0]; img[off+5] = nsec[15:8];
      img[off+6] = 8'h00;                     // mfm_flg: 0x00 = MFM, the mode these reads use (0x40 = FM, NP2kai searchsector_d88)
      img[off+14] = size[7:0]; img[off+15] = size[15:8];
    end
  endtask

  task automatic put_sec_data(input integer off, input [7:0] r, input integer size);
    integer j;
    begin
      for (j = 0; j < size; j = j + 1) img[off + j] = secpat(r, j);
    end
  endtask

  // The D88 used by the control and the held-mount arms.
  task automatic build_d88;
    begin
      put_d88_header;
      put_sec_header(T0_OFF + 0,    8'h00, 8'h00, 8'h01, 8'h03, 2, 1024);
      put_sec_data  (T0_OFF + 16,   8'h01, 1024);
      put_sec_header(T0_OFF + 1040, 8'h00, 8'h00, 8'h02, 8'h03, 2, 1024);
      put_sec_data  (T0_OFF + 1056, 8'h02, 1024);
    end
  endtask

  // A RAW image: 154 half-tracks x 8 sectors x 1024 B = NP2kai's fdd_xdf row
  // {0,154,8,3,2HD,0}. Its first 0x2B0 bytes are the C0H0R1 sector's own data, which is
  // what makes the D88 container test reject it (fd_type's major nibble is neither 2
  // (DISKTYPE_2HD) nor the tolerated 3) - the
  // same construction tb_pc9821_fdd_media_d88's D7 arm uses.
  localparam integer RAW_BYTES = 1261568;
  task automatic build_raw;
    integer i;
    begin
      for (i = 0; i < `IMGMAX; i = i + 1) img[i] = 8'h00;
      for (i = 0; i < 1024; i = i + 1) img[0 + i]        = secpat(8'h01, i);   // C0 H0 R1
      for (i = 0; i < 1024; i = i + 1) img[7*1024 + i]   = secpat(8'h02, i);   // C0 H0 R8
    end
  endtask

  // ==== the HPS block reader (a model of the MiSTer host side) ====
  reg        sd_ack = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] sd_lba;
  wire        sd_rd, sd_wr;
  wire [5:0]  sd_blk_cnt;
  wire [15:0] sd_buff_din;

  reg [12:0] widx, wtotal;
  reg [31:0] hlba;
  reg        hbusy, hlast;

  function automatic [15:0] img_word(input [31:0] lba, input [7:0] w);
    integer base;
    begin
      base = lba * 512 + w * 2;
      img_word = {img[base + 1], img[base]};
    end
  endfunction

  always @(posedge clk) begin
    if (reset) begin
      sd_ack <= 1'b0; sd_buff_wr <= 1'b0; hbusy <= 1'b0; hlast <= 1'b0; widx <= 13'd0;
    end else if (!hbusy) begin
      sd_buff_wr <= 1'b0;
      if (sd_rd) begin
        hbusy  <= 1'b1;
        sd_ack <= 1'b1;
        widx   <= 13'd0;
        hlba   <= sd_lba;
        wtotal <= ({7'd0, sd_blk_cnt} + 13'd1) * 13'd256 - 13'd1;
      end
    end else begin
      // The LAST word needs its own cycle with the handshake still up - dropping sd_ack on
      // the same edge would cancel the presentation before the adapter ever saw the word.
      sd_buff_wr   <= 1'b1;
      sd_buff_addr <= widx;
      sd_buff_dout <= img_word(hlba + {19'd0, widx[12:8]}, widx[7:0]);
      if (hlast) begin
        hbusy      <= 1'b0;
        sd_ack     <= 1'b0;
        sd_buff_wr <= 1'b0;
        hlast      <= 1'b0;
      end else if (widx == wtotal) begin
        hlast <= 1'b1;
      end else begin
        widx <= widx + 13'd1;
      end
    end
  end

  // ==== the floppy medium and its shared adapter ====
  reg        img_mounted = 0;
  reg [63:0] img_size = 0;
  wire       present, writeprotect;
  reg        req = 0, req_hdr = 0, adv = 0;
  reg [1:0]  unit = 0;
  reg [7:0]  req_c = 0, req_h = 0, req_r = 0, req_n = 0, req_idx = 0;
  wire       ready, rdy, hdrv, err;
  wire [7:0] dout, hdr_r, hdr_n, hdr_sects;

  wire        blk_rd, blk_busy, blk_done;

  wire        blk_error;   // the adapter's completion verdict (pc9821_fdd_media's blk_err)
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr;
  wire [15:0] blk_fill_data;
  wire [31:0] dbg_hps_cycles;

  // THE INTEGRATION'S OWN RESET TERM, and the arms' one variable: cpu_run is
  // pc9821_memory_subsystem's pack-present signal (rom_ready && !load_error &&
  // !selected_download), LOW for the whole pack download while the HPS mounts the image.
  reg cpu_run = 1'b1;

  pc9821_fdd_media dut (
      .clk(clk), .reset(reset || !cpu_run),
      .img_mounted(img_mounted), .img_size(img_size), .img_readonly(1'b1),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .present(present), .writeprotect(writeprotect),
      .req(req), .req_hdr(req_hdr), .unit(unit),
      .req_c(req_c), .req_h(req_h), .req_tc(req_c), .req_hd(req_h[0]), .req_mf(1'b1), .req_2hd(1'b1), .req_rpm(1'b0), .req_r(req_r), .req_n(req_n), .req_idx(req_idx),
      .ready(ready), .rdy(rdy), .hdrv(hdrv), .err(err), .dout(dout), .adv(adv),
      .hdr_r(hdr_r), .hdr_n(hdr_n), .hdr_sects(hdr_sects)
  );

  pc9821_block_share share (
      // Slot D (the second hard disk): unmounted; every disk request is for slot A.




      .clk(clk), .rst_n(!reset),
      // the hard disk's slot: unmounted, no requests
      .a_img_mounted(1'b0), .a_img_readonly(1'b1), .a_img_size(64'd0),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(), .a_sd_blk_cnt(), .a_sd_rd(), .a_sd_wr(), .a_sd_ack(1'b0),
      .a_sd_buff_din(),
      // the floppy's slot
      .b_img_mounted(img_mounted), .b_img_readonly(1'b1), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_lba(blk_lba),
      .b_req_done(blk_done), .b_req_error(blk_error),
      .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_sd_lba(sd_lba), .b_sd_blk_cnt(sd_blk_cnt), .b_sd_rd(sd_rd), .b_sd_wr(sd_wr),
      .b_sd_ack(sd_ack), .b_sd_buff_din(sd_buff_din),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // ==== CHECKS ====
  integer fails = 0;
  integer i, n;
  reg [7:0] got [0:4095];
  integer   nget;

  task automatic expecti(input integer g, input integer w, input [8*60-1:0] what);
    begin
      if (g !== w) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, g, w);
        fails = fails + 1;
      end
    end
  endtask

  // One mount pulse with the module in whatever state the caller left it, then let the
  // header walk finish. `cpu_run` is deliberately NOT touched here: it is the arms' one
  // variable.
  task automatic pulse_mount(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); img_mounted = 1;
      @(posedge clk);
      @(negedge clk); img_mounted = 0;
      repeat (4000) @(negedge clk);
    end
  endtask

  // One request; then wait for the answer level.
  task automatic do_req(input integer hdr, input [7:0] c, hh, r, nn, idx);
    begin
      n = 0;
      while (!ready && n < 100000) begin @(negedge clk); n = n + 1; end
      @(negedge clk);
      req = 1; req_hdr = hdr[0];
      req_c = c; req_h = hh; req_r = r; req_n = nn; req_idx = idx;
      @(posedge clk);
      @(negedge clk); req = 0;
      nget = 0;
      n = 0;
      while (!rdy && !hdrv && !err && n < 200000) begin @(negedge clk); n = n + 1; end
      if (!rdy && !hdrv && !err) begin
        $display("  FAIL: request never answered (hdr=%0d C=%02x H=%02x R=%02x N=%02x idx=%0d)",
                 hdr[0], c, hh, r, nn, idx);
        fails = fails + 1;
      end
    end
  endtask

  // Drain until the module is idle again. NOT `while (rdy)`: a block fetch in flight drops
  // rdy for hundreds of cycles mid-sector, which is the transfer PAUSING, not finishing.
  task automatic drain_bytes(input integer maxb);
    begin
      n = 0;
      while ((nget < maxb) && !err && !ready && n < 400000) begin
        n = n + 1;
        if (rdy) begin
          got[nget] = dout;
          nget = nget + 1;
          adv = 1'b1;
          @(posedge clk);
          @(negedge clk); adv = 1'b0;
        end
        @(negedge clk);
      end
    end
  endtask

  task automatic check_sector(input [7:0] r, input integer size);
    reg [7:0] want;
    begin
      for (i = 0; i < size; i = i + 1) begin
        want = secpat(r, i);
        if (got[i] !== want) begin
          $display("  FAIL: sector R=%0d byte %0d is %02x, the image holds %02x",
                   r, i, got[i], want);
          fails = fails + 1;
        end
      end
    end
  endtask

  task automatic expect_present(input what);
    begin
      if (present !== 1'b1) begin
        $display("  FAIL: %0s: present=%0d, the medium did not mount", what, present);
        fails = fails + 1;
      end
    end
  endtask

  initial begin
    reset = 1;
    repeat (6) @(negedge clk);
    reset = 0;
    repeat (2) @(negedge clk);

    // ---------------- H0: CONTROL - a mount with the module released ------------------
    // The same harness, the same pulse: with cpu_run already high the module is NOT held,
    // so the mount must be taken. If this arm fails the harness is broken, not the DUT.
    cpu_run = 1'b1;
    build_d88;
    pulse_mount(IMG_BYTES);
    $display("PROBE H0 present after a mount with the module released (CONTROL): %0d", present);
    expect_present("H0 the control mount did not take (the harness is broken, not the DUT)");
    expecti(writeprotect, 1, "H0 the medium is write-protected");
    do_req(0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expecti(err, 0, "H0 no error");
    drain_bytes(4096);
    expecti(nget, 1024, "H0 a 1024-byte sector");
    check_sector(8'h01, 1024);

    // ---------------- H1: the mount lands while !cpu_run holds the module ------------
    // The integration's reset term is `reset || !cpu_run`; hps_io's img_mounted is a
    // single-cycle pulse that arrives BEFORE the pack finishes. Model exactly that: hold
    // cpu_run low, pulse, then raise cpu_run and check whether the medium ever mounts.
    // PRE-CHANGE: the pulse is taken into the reset branch and present stays 0.
    //
    // THE DRIVE IS EJECTED FIRST, so `present` reads 0 before the hold and the mid-hold
    // check means what it says - the pending mount has not been applied yet (the module is
    // held) - rather than measuring the old side effect in which the hold's reset CLEARED a
    // previous parse (the mount-across-reset fix made the parsed metadata survive `reset`, so
    // a drive that was mounted when the hold began now stays presented through it; the
    // deferral this arm proves is unchanged).
    pulse_mount(64'd0);                    // an eject: a sub-sector mount clears present
    expecti(present, 0, "H1 the eject did not clear present");
    cpu_run = 1'b0;
    repeat (4) @(negedge clk);
    img_size = IMG_BYTES;
    @(negedge clk); img_mounted = 1;
    @(posedge clk);
    @(negedge clk); img_mounted = 0;
    repeat (4) @(negedge clk);
    expecti(present, 0, "H1 the medium is not present while the module is held");
    cpu_run = 1'b1;
    repeat (4000) @(negedge clk);
    $display("PROBE H1 present after a mount pulse taken while !cpu_run held the module: %0d",
             present);
    expect_present("H1 the boot mount was discarded by the reset term");
    // ... and the medium is USABLE, not merely flagged present: its bytes come out.
    do_req(0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expecti(err, 0, "H1 no error after the held mount");
    drain_bytes(4096);
    expecti(nget, 1024, "H1 a 1024-byte sector after the held mount");
    check_sector(8'h01, 1024);
    do_req(0, 8'h00, 8'h00, 8'h02, 8'h03, 8'h00);
    drain_bytes(4096);
    check_sector(8'h02, 1024);

    // ---------------- H2: the SIZE is latched with the request ------------------------
    // hps_io holds ONE img_size for whichever slot mounted LAST, and both slots share it
    // (the disk's `.img_size` and the floppy's `.fdd_size` are the same register), so a
    // disk mount between this pulse and the release must not re-point the medium. Mount a
    // RAW floppy while held, overwrite img_size with a disk-sized foreign value, then
    // release: the module must still parse the RAW image at 1261568 bytes.
    // PRE-CHANGE (a request latch without the size latch): present=0, because ST_PARSE
    // tests 8000000 against the geometry rows and finds no row.
    cpu_run = 1'b0;
    repeat (4) @(negedge clk);
    build_raw;
    img_size = RAW_BYTES;
    @(negedge clk); img_mounted = 1;
    @(posedge clk);
    @(negedge clk); img_mounted = 0;
    img_size = 64'd8_000_000;                  // the other slot's mount overwrites it
    repeat (4) @(negedge clk);
    cpu_run = 1'b1;
    repeat (4000) @(negedge clk);
    $display("PROBE H2 present after a held mount whose size was overwritten: %0d", present);
    expect_present("H2 the mount used the foreign size instead of the one it was mounted with");
    do_req(0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    expecti(err, 0, "H2 no error");
    drain_bytes(4096);
    expecti(nget, 1024, "H2 a 1024-byte sector");
    check_sector(8'h01, 1024);
    do_req(0, 8'h00, 8'h00, 8'h08, 8'h03, 8'h00);
    drain_bytes(4096);
    check_sector(8'h02, 1024);

    // A mount that arrives while the module is RUNNING still works after all of that
    // (the latch must not have eaten the live path).
    cpu_run = 1'b1;
    build_d88;
    pulse_mount(IMG_BYTES);
    expect_present("H2 a live mount after the held ones did not take");
    do_req(0, 8'h00, 8'h00, 8'h01, 8'h03, 8'h00);
    drain_bytes(4096);
    check_sector(8'h01, 1024);

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_MOUNT_HOLD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_MOUNT_HOLD: FAIL (%0d errors)", fails);
  end

  // In-bench watchdog: every wait here is cycle-bounded, so this only fires if the
  // DUT stops responding altogether.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_FDD_MOUNT_HOLD: TIMEOUT (no verdict reached)");
  end

endmodule
