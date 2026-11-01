`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDD_MOUNT_RESET: a MOUNT SURVIVES THE CORE RESET - the flow (mount an image in the OSD while the machine runs, then select Reset in the OSD) leaves the image mounted: present is still asserted and the medium's sector bytes still come out through the real shared block adapter after the reset releases, because the parsed container/geometry and the slots' metadata live in a power-on-only domain while only the transfer/FSM state resets; a reset that lands IN the header walk re-arms and re-runs that walk instead of losing the mount (its img_mounted pulse already fired and the framework never re-pulses it), and the HDD slot's latched metadata (mounted/readonly/capacity) survives the same reset. FAIL-FIRST: the pre-change tree reset present and st with the walk's mount already consumed, so the post-reset request never answered and the guest boots to BASIC.
//
// WHY THE MOUNT MUST SURVIVE WITHOUT A SECOND PULSE. hps_io pulses `img_mounted` from one
// place only - the HPS's "notify image selection" transaction (sys/hps_io.sv:461 in the
// `'h1c` handler, cleared at every transaction end by :318) - and the OSD Reset is a STATUS
// bit (the `'h1e` handler), so the framework does NOT re-announce an already-mounted image
// when the user resets. The core must therefore keep the mount itself. This bench never
// re-pulses either, so an implementation that needs the pulse to repeat cannot pass.
//
// WHY THE ARMS MOUNT WHILE RUNNING. The companion bench (tb_pc9821_fdd_mount_hold) covers
// the OTHER order - the pulse arriving while the module is held, which the `mnt_req` latch
// already fixes - and its harness note records the trap: a bench that mounts at the wrong
// moment hides the class. The user's flow is mount-THEN-reset, so every arm here takes the
// mount at a running point and the variable is only when (or whether) the reset lands.
//
// REFERENCES (external). The reset is the OSD's own: z486_mister's `reset_req = buttons[1] |
// status[0] | disk_change_reset` and CONF_STR's "T[0],Reset" both feed the synchroniser whose
// `reset_sync_r[2]` is pc9821_system's `reset`, and pc9821_system wires the floppy medium's
// reset as `reset || !cpu_run` (the `!cpu_run` half is fdd_mount_hold's business, not this
// bench's - cpu_run stays HIGH across an OSD reset because the firmware pack is still
// loaded). The D88 layout and the sector walk are the ones tb_pc9821_fdd_media_d88 pins
// against NP2kai's own readers; this bench reuses that minimal image so the mount's RESULT is
// checked (present AND the medium's bytes), not just a flag. The HDD slot arm pins
// pc9821_block_share's slot metadata (its a_mounted/a_readonly/a_capacity outputs), the
// values pc9821_ata reads continuously through `mounted`/`capacity`.
//
// ==== DUT ====
// The real pair: pc9821_fdd_media + the shared block adapter, exactly as pc9821_system wires
// them (the medium's reset is `reset || !cpu_run`, the adapter's is `!reset`), with the host
// side a model of the MiSTer block reader (sd_ack held for the transfer, one 16-bit word per
// clk at sd_buff_addr, (sd_blk_cnt+1) sectors per handshake).
`define IMGMAX 1310720

module tb_pc9821_fdd_mount_reset;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== the image: a synthetic D88 laid out byte by byte ====
  // 0x2B0 header, then track 0 with two sectors (R=1 and R=2, both 1024 B). fd_size is the
  // exact end of track 0. The same construction tb_pc9821_fdd_mount_hold uses.
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

  task automatic build_d88;
    begin
      put_d88_header;
      put_sec_header(T0_OFF + 0,    8'h00, 8'h00, 8'h01, 8'h03, 2, 1024);
      put_sec_data  (T0_OFF + 16,   8'h01, 1024);
      put_sec_header(T0_OFF + 1040, 8'h00, 8'h00, 8'h02, 8'h03, 2, 1024);
      put_sec_data  (T0_OFF + 1056, 8'h02, 1024);
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
  wire [1:0] present;
  wire       writeprotect;
  reg        req = 0, req_hdr = 0, adv = 0;
  reg [1:0]  unit = 0;
  reg [7:0]  req_c = 0, req_h = 0, req_r = 0, req_n = 0, req_idx = 0;
  wire       ready, rdy, hdrv, err;
  wire [7:0] dout, hdr_r, hdr_n, hdr_sects;

  wire        blk_rd, blk_busy, blk_done, blk_slot;

  wire        blk_error;   // the adapter's completion verdict (pc9821_fdd_media's blk_err)
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr;
  wire [15:0] blk_fill_data;
  wire [31:0] dbg_hps_cycles;

  // The HDD slot's mount, for the metadata arm (R4): its pulse latches a_mounted /
  // a_readonly / a_capacity in the shared adapter, which is what pc9821_ata reads.
  reg        a_img_mounted = 0;
  reg [63:0] a_img_size = 0;
  wire       a_mounted, a_readonly;
  wire [31:0] a_capacity;

  // THE INTEGRATION'S OWN RESET TERM, with cpu_run pinned HIGH: an OSD reset asserts
  // `reset` while the firmware pack stays loaded (pc9821_system wires
  // `.reset(reset || !cpu_run)` into the medium and `.rst_n(!reset)` into the adapter).
  wire cpu_run = 1'b1;

  pc9821_fdd_media dut (
      .clk(clk), .reset(reset || !cpu_run),
      .img_mounted(img_mounted), .img_size(img_size), .img_readonly(1'b1),
      .img1_mounted(1'b0), .img1_size(64'd0),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_slot(blk_slot),
      .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
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
      // slot 0: the hard disk - only its metadata is exercised (R4)
      .a_img_mounted(a_img_mounted), .a_img_readonly(1'b0), .a_img_size(a_img_size),
      .a_mounted(a_mounted), .a_readonly(a_readonly), .a_capacity(a_capacity),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(), .a_sd_blk_cnt(), .a_sd_rd(), .a_sd_wr(), .a_sd_ack(1'b0),
      .a_sd_buff_din(),
      // slot 1: the first floppy
      .b_img_mounted(img_mounted), .b_img_readonly(1'b1), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_lba(blk_lba), .b_req_slot(blk_slot),
      .b_req_done(blk_done), .b_req_error(blk_error),
      .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_sd_lba(sd_lba), .b_sd_blk_cnt(sd_blk_cnt), .b_sd_rd(sd_rd), .b_sd_wr(sd_wr),
      .b_sd_ack(sd_ack), .b_sd_buff_din(sd_buff_din),
      // slot 2: the second floppy - nothing mounted
      .c_img_mounted(1'b0), .c_img_readonly(1'b1), .c_img_size(64'd0),
      .c_sd_lba(), .c_sd_blk_cnt(), .c_sd_rd(), .c_sd_wr(), .c_sd_ack(1'b0),
      .c_sd_buff_din(),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // ==== CHECKS ====
  integer fails = 0;
  integer i, n;
  reg [7:0] got [0:4095];
  integer   nget;

  task automatic expecti(input integer g, input integer w, input [8*72-1:0] what);
    begin
      if (g !== w) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, g, w);
        fails = fails + 1;
      end
    end
  endtask

  // One mount pulse with the module in whatever state the caller left it, then let the
  // header walk finish.
  task automatic pulse_mount(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); img_mounted = 1;
      @(posedge clk);
      @(negedge clk); img_mounted = 0;
      repeat (4000) @(negedge clk);
    end
  endtask

  // THE OSD RESET, modelled at the terms the integration drives: `reset` asserted for a
  // span while cpu_run stays high (the firmware pack is still loaded), then released.
  task automatic osd_reset(input integer hold_cycles);
    begin
      @(negedge clk); reset = 1;
      repeat (hold_cycles) @(negedge clk);
      reset = 0;
      repeat (10) @(negedge clk);
    end
  endtask

  // One request; then wait for the answer level.
  task automatic do_req(input integer hdr, input [7:0] c, hh, r, nn, idx);
    begin
      n = 0;
      while (!ready && n < 100000) begin @(negedge clk); n = n + 1; end
      if (!ready) begin
        $display("  FAIL: ready never came (hdr=%0d C=%02x H=%02x R=%02x N=%02x idx=%0d)",
                 hdr[0], c, hh, r, nn, idx);
        fails = fails + 1;
      end
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

  task automatic expect_present(input [8*72-1:0] what);
    begin
      if (present[0] !== 1'b1) begin
        $display("  FAIL: %0s: present=%0d, the medium did not mount", what, present[0]);
        fails = fails + 1;
      end
    end
  endtask

  // The whole arm: one sector must come out of the medium byte-exact.
  task automatic expect_sector(input [7:0] r, input [8*72-1:0] what);
    begin
      do_req(0, 8'h00, 8'h00, r, 8'h03, 8'h00);
      expecti(err, 0, what);
      drain_bytes(4096);
      expecti(nget, 1024, what);
      check_sector(r, 1024);
    end
  endtask

  initial begin
    reset = 1;
    repeat (6) @(negedge clk);
    reset = 0;
    repeat (2) @(negedge clk);

    build_d88;

    // ---------------- R0: CONTROL - a mount while running, then a read -----------------
    // No reset anywhere in this arm: if it fails the harness is broken, not the DUT.
    pulse_mount(IMG_BYTES);
    $display("PROBE R0 present after a mount while running (CONTROL): %0d", present[0]);
    expect_present("R0 the control mount did not take (the harness is broken, not the DUT)");
    expecti(writeprotect, 1, "R0 the medium is write-protected");
    expect_sector(8'h01, "R0 the control read did not return the sector");

    // ---------------- R1: THE OWNER'S FLOW - mount while running, then OSD Reset -------
    // The image is mounted and READABLE first (so the arm cannot fail for a pre-existing
    // reason), then the OSD reset lands with cpu_run still high. The bench never re-pulses
    // img_mounted - hps_io will not either. PRE-CHANGE: present drops to 0 in the reset
    // branch and st goes ST_NONE with the walk's mount already consumed, so the post-reset
    // request never answers and the guest finds no floppy.
    expect_sector(8'h02, "R1 the pre-reset read did not return the sector");
    $display("PROBE R1 present before the OSD reset: %0d", present[0]);
    osd_reset(50);
    $display("PROBE R1 present after the OSD reset (mount while running): %0d", present[0]);
    expect_present("R1 the OSD reset unmounted the image the user had mounted");
    expect_sector(8'h01, "R1 the medium stopped answering after the OSD reset");

    // ---------------- R2: RESET DURING THE HEADER WALK --------------------------------
    // A remount, with the reset landing ten cycles into the walk: the pulse is consumed by
    // walk_en at the walk's start, so an aborted walk that is not re-armed loses the mount
    // for good (no pulse will ever come again). PRE-CHANGE: present stays 0 forever.
    img_size = IMG_BYTES;
    @(negedge clk); img_mounted = 1;
    @(posedge clk);
    @(negedge clk); img_mounted = 0;
    repeat (10) @(negedge clk);           // the walk is now streaming its header
    osd_reset(50);
    repeat (4000) @(negedge clk);         // the re-armed walk has time to finish
    $display("PROBE R2 present after a reset inside the header walk: %0d", present[0]);
    expect_present("R2 a reset inside the header walk lost the mount");
    expect_sector(8'h01, "R2 the medium stopped answering after the aborted walk");

    // ---------------- R3: RESET MID-TRANSFER ------------------------------------------
    // A sector read is streaming when the reset lands. The transfer itself is allowed to
    // die (the whole machine resets, the FDC abandons the command) but the PARSE must not:
    // the next request is served from the surviving geometry.
    do_req(0, 8'h00, 8'h00, 8'h02, 8'h03, 8'h00);
    n = 0;
    while ((nget < 100) && !err && (n < 200000)) begin
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
    osd_reset(50);
    $display("PROBE R3 present after a reset mid-transfer: %0d", present[0]);
    expect_present("R3 a reset mid-transfer unmounted the image");
    expect_sector(8'h02, "R3 the medium stopped answering after the aborted transfer");

    // ---------------- R4: THE HDD SLOT'S METADATA SURVIVES THE SAME RESET -------------
    // pc9821_block_share latches each slot's mounted/readonly/capacity and pc9821_ata reads
    // those values continuously; they must not be cleared by the core reset either (the
    // mount pulse for slot 0 already fired and the adapter's engine deliberately keeps its
    // own mount state across rst_n). A 32 MiB image is 65536 sectors.
    a_img_size = 64'd33_554_432;
    @(negedge clk); a_img_mounted = 1;
    @(posedge clk);
    @(negedge clk); a_img_mounted = 0;
    repeat (4) @(negedge clk);
    expecti(a_mounted,  1,      "R4 the HDD slot latched mounted");
    expecti(a_readonly, 0,      "R4 the HDD slot latched readonly=0");
    expecti(a_capacity, 65536,  "R4 the HDD slot latched its capacity");
    osd_reset(50);
    $display("PROBE R4 hdd mounted/capacity after the OSD reset: %0d / %0d",
             a_mounted, a_capacity);
    expecti(a_mounted,  1,      "R4 the OSD reset cleared the HDD slot's mounted");
    expecti(a_readonly, 0,      "R4 the OSD reset cleared the HDD slot's readonly");
    expecti(a_capacity, 65536,  "R4 the OSD reset cleared the HDD slot's capacity");

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_MOUNT_RESET: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_MOUNT_RESET: FAIL (%0d errors)", fails);
  end

  // In-bench watchdog: every wait here is cycle-bounded, so this only fires if the
  // DUT stops responding altogether.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_FDD_MOUNT_RESET: TIMEOUT (no verdict reached)");
  end

endmodule
