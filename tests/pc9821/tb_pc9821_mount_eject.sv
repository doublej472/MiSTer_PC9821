`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MOUNT_EJECT: the OSD's per-slot Eject actions (T[8..10]: HDD, FDD1, FDD2, and in a --cdrom build T[11]: CD-ROM, on hps_io slot 4 with slot 3 unused) become the slot's own mount event with img_size 0, the sub-sector unmount every image consumer already reads, through pc9821_mount_eject in front of the real pc9821_disk_change_reset and pc9821_block_share: an HDD eject with the pack loaded unmounts the disk's latch and raises reset_req for exactly one cycle however long the OSD holds its bit; an FDD eject delivers one size-0 event on its own slot and raises no reset; an eject before the pack is loaded unmounts without a reset; an eject requested while hps_io is mounting another slot is deferred until the channel is quiet, never shares a cycle with a host mount, and leaves the host mount's size on its own slot; two ejects requested in one cycle (the disk and a floppy) are issued one slot per cycle and reset once, for the disk; a host mount of a slot after its eject mounts it again (and resets once); and hps_io's own events pass through unchanged, two clk_sys later (the outputs are registered behind one look-ahead stage); every eject and every mount is its own rising edge on its slot, as an edge-reading consumer (pc9821_fdd_media's mnt_ev) counts them: an eject pressed while hps_io is mounting THAT slot is delivered after the mount as a second event (the mount's size, then size 0), and a host mount of a slot that starts in the cycle right after its eject was issued is its own event after the eject, with its own size; with the module spanning all five slots as the --cdrom top instantiates it, a CD-ROM eject delivers one size-0 event on slot 4 and raises no reset, and an HDD eject pressed while hps_io is mounting the CD is deferred past that mount, which keeps its own size; and a mount's img_readonly rides with its event as its size does (a read-only floppy or disk mount arrives read-only, latched by the block engine, and the next writable mount arrives writable). FAIL-FIRST: the base tree has no eject path at all (no module, no OSD entry), so this bench does not build on it; and with -DPRE_CD_EJECT (the pre-change top: the module over slots 0..2 only, the CD's slot passed straight through with no eject) the CD-ROM cases fail; with the previous single-stage module (the eject issued in the first cycle hps_io is quiet, the host event one clk_sys late) the eject after a same-slot mount and the mount right after an eject each merge into one level, and E10/E11 fail.
//
// EXPECTED VALUES. The eject's meaning - a mount event whose size is under one sector - is
// pc9821_block_io's own unmount rule (`eject = img_mounted && (img_size < 512)`) and hps_io's
// event contract (img_size/img_readonly "valid only for active bit in img_mounted",
// sys/hps_io.sv:144-145). The reset policy - an IDE slot's change resets once, a floppy's never -
// is a design decision (a floppy change must not reset, a disk change must). Nothing is taken from
// the RTL under test.
// ==== DUT ====

module tb_pc9821_mount_eject;

  reg clk = 0;
  always #5 clk = ~clk;

  reg  [4:0]  hps_mounted = 5'b00000;
  reg  [63:0] hps_size = 64'd0;
  reg         hps_ro = 1'b0;
  reg  [4:0]  eject_req = 5'b00000;
  wire [4:0]  img_mounted;
  wire [63:0] img_size;
  wire        img_ro;

  // N = 5, as the --cdrom z486_mister.sv instantiates it (N = HPS_VDNUM): slots 0..2 (HDD, FDD1,
  // FDD2), slot 3 (the removed second disk's, tied off: eject_req[3] = 0, no host mount), slot 4
  // the CD-ROM. The base build's N = 3 is the same module with the top two slots absent.
`ifndef PRE_CD_EJECT
  wire [4:0] eject_wired = {eject_req[4], 1'b0, eject_req[2:0]};
  pc9821_mount_eject #(.N(5)) dut (
      .clk(clk), .hps_mounted(hps_mounted), .hps_size(hps_size), .hps_readonly(hps_ro),
      .eject_req(eject_wired),
      .img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_ro)
  );
`else
  // the pre-change top: the module over slots 0..2, slots 3/4 passed straight through
  pc9821_mount_eject #(.N(3)) dut (
      .clk(clk), .hps_mounted(hps_mounted[2:0]), .hps_size(hps_size), .hps_readonly(hps_ro),
      .eject_req(eject_req[2:0]),
      .img_mounted(img_mounted[2:0]), .img_size(img_size), .img_readonly(img_ro)
  );
  assign img_mounted[4:3] = hps_mounted[4:3];
`endif

  reg  reset_async = 1'b1;
  reg  pack_loaded = 1'b0;
  wire reset_req;
  pc9821_disk_change_reset dcr (
      .clk(clk), .reset_async(reset_async), .img_mounted(img_mounted[1:0]),
      .pack_loaded(pack_loaded), .reset_req(reset_req)
  );

  wire        a_mounted;
  wire        a_ro;
  wire [31:0] a_capacity;
  pc9821_block_share share (
      .clk(clk), .rst_n(1'b1),
      .a_img_mounted(img_mounted[0]), .a_img_readonly(img_ro), .a_img_size(img_size),
      .a_mounted(a_mounted), .a_readonly(a_ro), .a_capacity(a_capacity),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_window(1'b1),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(), .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(), .a_sd_blk_cnt(), .a_sd_rd(), .a_sd_wr(), .a_sd_ack(1'b0), .a_sd_buff_din(),
      .b_img_mounted(img_mounted[1]), .b_img_readonly(img_ro), .b_img_size(img_size),
      .b_req_read(1'b0), .b_req_lba(16'd0), .b_req_slot(1'b0),
      .b_req_done(), .b_req_error(), .b_busy(),
      .b_buf_we(), .b_buf_addr(), .b_buf_data(),
      .b_sd_lba(), .b_sd_blk_cnt(), .b_sd_rd(), .b_sd_wr(), .b_sd_ack(1'b0), .b_sd_buff_din(),
      .c_img_mounted(img_mounted[2]), .c_img_readonly(img_ro), .c_img_size(img_size),
      .c_sd_lba(), .c_sd_blk_cnt(), .c_sd_rd(), .c_sd_wr(), .c_sd_ack(1'b0), .c_sd_buff_din(),



      .sd_buff_wr(1'b0), .sd_buff_addr(13'd0), .sd_buff_dout(16'd0),
      .dbg_hps_cycles()
  );

  // ==== CHECKS ====
  integer fails = 0;
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_MOUNT_EJECT: watchdog timeout (no verdict reached)");
  end
  always @(posedge clk)
    if (fails > 200) $fatal(1, "TB_PC9821_MOUNT_EJECT: FAIL (more than 200 errors, stopped)");

  task automatic check(input ok, input [8*80-1:0] what);
    begin
      if (!ok) begin $display("  FAIL: %0s", what); fails = fails + 1; end
    end
  endtask

  // Event monitor, sampled at every posedge: reset_req cycles, one event count per slot
  // (rising edges of img_mounted[i]), the size each event carried, and the collision a shared
  // img_size cannot carry (a host mount and an eject in one cycle).
  integer resets = 0;
  integer ev [0:4];
  reg [63:0] ev_size [0:4];
  reg [4:0]  prev_m = 5'b00000;
  // The module registers its outputs behind one look-ahead stage (two clk_sys), so a host event
  // passes through as hps_mounted of two cycles before.
  reg [4:0]  hps_mounted_d = 5'b00000;
  reg [4:0]  hps_mounted_dd = 5'b00000;
  integer collide = 0;
  integer j;
  reg [63:0] ev_first [0:4];   // the size the FIRST event since clear_counts carried
  reg        ev_ro [0:4];      // the img_readonly the LAST event carried
  initial for (j = 0; j < 5; j = j + 1) begin ev[j] = 0; ev_size[j] = 64'hDEAD; ev_first[j] = 64'hDEAD; end
  always @(posedge clk) begin
    if (reset_req) resets = resets + 1;
    for (j = 0; j < 5; j = j + 1)
      if (img_mounted[j] && !prev_m[j]) begin
        if (ev[j] == 0) ev_first[j] = img_size;
        ev[j] = ev[j] + 1; ev_size[j] = img_size; ev_ro[j] = img_ro;
      end
    if ((|hps_mounted_dd) && (img_mounted != hps_mounted_dd)) collide = collide + 1;
    prev_m = img_mounted;
    hps_mounted_dd = hps_mounted_d;
    hps_mounted_d = hps_mounted;
  end

  task automatic clear_counts;
    begin
      resets = 0; collide = 0;
      for (j = 0; j < 5; j = j + 1) begin ev[j] = 0; ev_size[j] = 64'hDEAD; ev_first[j] = 64'hDEAD; end
    end
  endtask

  // hps_io's mount: img_size first (the 0x1d transaction), then img_mounted held for the
  // 0x1c transaction's length (sys/hps_io.sv:490 set, :334 clear).
  task automatic host_mount(input integer slot, input [63:0] size, input integer w);
    begin
      host_mount_ro(slot, size, w, 1'b0);
    end
  endtask

  task automatic host_mount_ro(input integer slot, input [63:0] size, input integer w,
                               input ro);
    begin
      @(negedge clk); hps_size = size; hps_ro = ro;
      @(negedge clk); hps_mounted[slot] = 1'b1;
      repeat (w) @(negedge clk);
      hps_mounted = 5'b00000;
      repeat (8) @(negedge clk);
    end
  endtask

  // The OSD's T entry: the menu raises the status bit and drops it later.
  task automatic osd_eject(input [4:0] slots, input integer w);
    begin
      @(negedge clk); eject_req = slots;
      repeat (w) @(negedge clk);
      eject_req = 5'b00000;
      repeat (8) @(negedge clk);
    end
  endtask

  localparam [63:0] HDD0_BYTES = 64'd2048 * 512;
  integer k;

  // ==== STIMULUS ====
  initial begin
    repeat (4) @(negedge clk);
    reset_async = 1'b0;
    repeat (4) @(negedge clk);

    // ---------------- E0: power-on mounts before the pack: no reset ----------------
    host_mount(0, HDD0_BYTES, 20);
    check(resets == 0, "E0 a boot mount before the pack is loaded raises no reset");
    check(a_mounted, "E0 the disk is latched mounted");
    check(collide == 0, "E0 host events pass through unchanged");
    pack_loaded = 1'b1;

    // ---------------- E1: Eject HDD (held for 200 cycles) ----------------------------
    clear_counts;
    osd_eject(5'b00001, 200);
    check(ev[0] == 1, "E1 one event on slot 0 for one held OSD action");
    check(ev_size[0] == 64'd0, "E1 the eject event carries img_size 0");
    check(ev[1] == 0 && ev[2] == 0 && ev[3] == 0 && ev[4] == 0, "E1 no event on any other slot");
    check(resets == 1, "E1 an HDD eject resets exactly once");
    check(!a_mounted, "E1 slot 0's latch is unmounted");

    // ---------------- E2: re-mount HDD from the host: mounts and resets once ----------
    clear_counts;
    host_mount(0, HDD0_BYTES, 20);
    check(resets == 1, "E2 a host mount after the eject resets once");
    check(a_mounted && a_capacity == 32'd2048, "E2 slot 0 mounted again with its capacity");

    // ---------------- E3: Eject FDD1 / FDD2: one size-0 event, no reset ---------------
    clear_counts;
    osd_eject(5'b00010, 50);
    osd_eject(5'b00100, 50);
    check(ev[1] == 1 && ev_size[1] == 64'd0, "E3 one size-0 event on FDD1's slot");
    check(ev[2] == 1 && ev_size[2] == 64'd0, "E3 one size-0 event on FDD1's slot");
    check(resets == 0, "E3 a floppy eject raises no reset");
    check(a_mounted, "E3 the disk is untouched by a floppy eject");

    // ---------------- E4: an eject requested DURING a host mount of another slot ------
    // HDD eject is pressed while hps_io is mounting FDD0 (held 60 cycles): it must wait for
    // the quiet channel, and the host mount's size must reach FDD0 unchanged.
    clear_counts;
    fork
      host_mount(1, 64'd1261568, 60);
      begin repeat (10) @(negedge clk); osd_eject(5'b00001, 5); end
    join
    repeat (10) @(negedge clk);
    check(collide == 0, "E4 the eject never shares a cycle with a host mount");
    check(ev[1] == 1 && ev_size[1] == 64'd1261568, "E4 the host mount's size reaches FDD0");
    check(ev[0] == 1 && ev_size[0] == 64'd0, "E4 the deferred HDD eject is delivered");
    check(!a_mounted, "E4 the disk is unmounted");
    check(resets == 1, "E4 one reset for the disk that changed");

    // ---------------- E5: two ejects in ONE cycle -----------------------------------
    host_mount(0, HDD0_BYTES, 20);
    clear_counts;
    osd_eject(5'b00101, 30);
    check(ev[0] == 1 && ev[2] == 1, "E5 each requested slot gets exactly one event");
    check(ev_size[0] == 64'd0 && ev_size[2] == 64'd0, "E5 both events carry size 0");
    check(resets == 1, "E5 one reset, for the disk (a floppy never resets)");
    check(!a_mounted, "E5 the disk is unmounted");

    // ---------------- E6: an eject before the pack is loaded: unmount, no reset ------
    host_mount(0, HDD0_BYTES, 20);
    pack_loaded = 1'b0;
    clear_counts;
    osd_eject(5'b00001, 10);
    check(resets == 0, "E6 no reset before the pack is loaded");
    check(!a_mounted, "E6 the slot is unmounted anyway");

    // ---------------- E7: an edge landing on its own issue is merged ---------------
    // Re-press the same eject on consecutive cycles while hps_io is busy: still one event.
    pack_loaded = 1'b1;
    host_mount(0, HDD0_BYTES, 20);
    clear_counts;
    fork
      host_mount(2, 64'd1261568, 40);
      begin
        repeat (5) @(negedge clk);
        for (k = 0; k < 3; k = k + 1) begin
          eject_req = 5'b00001; @(negedge clk); eject_req = 5'b00000; @(negedge clk);
        end
      end
    join
    repeat (20) @(negedge clk);
    // ... and a press whose edge lands in the very cycle its pending eject is issued (the first
    // quiet cycle after a host mount) is merged into that issue, not re-armed as a second one.
    host_mount(0, HDD0_BYTES, 20);
    @(negedge clk); hps_size = 64'd1261568; hps_mounted = 5'b00100;
    repeat (3) @(negedge clk); eject_req = 5'b00001;            // pending while deferred
    @(negedge clk); eject_req = 5'b00000;
    repeat (3) @(negedge clk);
    hps_mounted = 5'b00000; eject_req = 5'b00001;               // quiet AND a new edge, one cycle
    @(negedge clk); eject_req = 5'b00000;
    repeat (20) @(negedge clk);
    check(ev[0] == 3, "E7 eject, re-mount, eject: a coincident press is merged");
    check(resets == 3, "E7 one reset per delivered HDD change (eject, re-mount, eject)");
    check(collide == 0, "E7 no collision with the host mount");

    // ---------------- E8: Eject CD-ROM (slot 4): one size-0 event, no reset ------------
    // A CD swap is a media change the drive reports itself (NP2kai ideio_notify), never a
    // machine reset: pc9821_disk_change_reset reads slots 1:0 only, the HDD and FDD1.
    host_mount(0, HDD0_BYTES, 20);
    host_mount(4, 64'd2048 * 300, 20);
    clear_counts;
    osd_eject(5'b10000, 100);
    check(ev[4] == 1 && ev_size[4] == 64'd0, "E8 one size-0 event on the CD-ROM's slot");
    check(ev[0] == 0 && ev[1] == 0 && ev[2] == 0 && ev[3] == 0, "E8 no event on any other slot");
    check(resets == 0, "E8 a CD-ROM eject raises no reset");
    check(a_mounted, "E8 the disk is untouched by a CD-ROM eject");

    // ---------------- E9: an HDD eject pressed while hps_io is mounting the CD ----------
    // The shared img_size carries the CD's size for the whole host mount, so the eject must wait
    // for it: the CD's slot gets its own size, the disk its size-0 event afterwards.
    clear_counts;
    fork
      host_mount(4, 64'd2048 * 300, 60);
      begin repeat (10) @(negedge clk); osd_eject(5'b00001, 5); end
    join
    repeat (10) @(negedge clk);
    check(collide == 0, "E9 the HDD eject never shares a cycle with the CD's host mount");
    check(ev[4] == 1 && ev_size[4] == 64'd2048 * 300, "E9 the CD's host mount keeps its size");
    check(ev[0] == 1 && ev_size[0] == 64'd0, "E9 the deferred HDD eject is delivered");
    check(resets == 1, "E9 one reset, for the disk");

    // ---------------- E10: an eject pressed while hps_io is mounting THAT slot ----------
    // FDD1's eject is pressed during hps_io's mount of FDD1 itself: the eject waits for the quiet
    // channel and must then be its own rising edge, not a tail joined to the mount's level that an
    // edge-reading consumer (fdd_media's mnt_ev) would never see. Two events: the mount (its own
    // size), then the eject (size 0). Swept over the host level's length.
    for (k = 1; k <= 4; k = k + 1) begin
      clear_counts;
      fork
        host_mount(1, 64'd1261568, k * 3);
        begin repeat (2) @(negedge clk); osd_eject(5'b00010, 1); end
      join
      repeat (10) @(negedge clk);
      check(ev[1] == 2, "E10 the mount and the deferred eject of the same slot are two events");
      check(ev_first[1] == 64'd1261568, "E10 the first event is the mount, with its size");
      check(ev_size[1] == 64'd0, "E10 the second event is the eject, size 0");
      check(collide == 0, "E10 the eject never shares a cycle with the host mount");
    end

    // ---------------- E11: a host mount starting next to an eject's issue -------------
    // FDD1's eject is pressed on a quiet channel; hps_io's mount of FDD1 rises in the cycle the
    // eject would be issued (k = 0) or 1..3 cycles after it. The eject and the mount are always
    // two events. From k = 1 the eject has gone out and the mount follows it (size 0, then the
    // mount's size: the drive ends up holding the new image); at k = 0 the channel was not quiet,
    // so the eject waits for the mount (the mount's size, then size 0), as in E10.
    for (k = 0; k < 5; k = k + 1) begin
      clear_counts;
      @(negedge clk); hps_size = 64'd1261568; hps_ro = 1'b0;
      @(negedge clk); eject_req = 5'b00010;     // the edge is taken at the next posedge
      @(negedge clk); eject_req = 5'b00000;     // the cycle after it: the eject's issue cycle
      if (k > 0) repeat (k) @(negedge clk);     // k = 1: the cycle right after the issue
      hps_mounted = 5'b00010;
      repeat (6) @(negedge clk); hps_mounted = 5'b00000;
      repeat (10) @(negedge clk);
      check(ev[1] == 2, "E11 an eject and a host mount next to it are two events");
      if (k == 0) begin
        check(ev_first[1] == 64'd1261568, "E11 k=0 the mount goes first, with its size");
        check(ev_size[1] == 64'd0, "E11 k=0 the deferred eject follows it, size 0");
      end
      else begin
        check(ev_first[1] == 64'd0, "E11 the first event is the eject, size 0");
        check(ev_size[1] == 64'd1261568, "E11 the last event is the mount, with its size");
      end
      check(collide == 0, "E11 the eject never shares a cycle with the host mount");
    end

    // ---------------- E12: a mount's write-protect flag rides with its event ------------
    // hps_io's img_readonly is "valid only for active bit in img_mounted" (sys/hps_io.sv:144-145),
    // exactly as img_size is: a read-only image mounted from the OSD must arrive read-only at
    // its event (the guest's write protect), and the next writable mount of the slot must
    // arrive writable - the flag is the event's, not sticky.
    clear_counts();
    host_mount_ro(1, 64'd1261568, 20, 1'b1);
    check(ev[1] == 1, "E12 a read-only mount is one event");
    check(ev_size[1] == 64'd1261568, "E12 the read-only mount carries its size");
    check(ev_ro[1] == 1'b1, "E12 a read-only mount arrives with img_readonly = 1");
    clear_counts();
    host_mount_ro(0, HDD0_BYTES, 20, 1'b1);
    check(ev[0] == 1 && ev_ro[0] == 1'b1, "E12 a read-only disk mount arrives with img_readonly = 1");
    check(a_ro == 1'b1, "E12 the disk's block engine latches the read-only flag");
    clear_counts();
    host_mount_ro(1, 64'd1261568, 20, 1'b0);
    check(ev[1] == 1 && ev_ro[1] == 1'b0, "E12 a writable mount after a read-only one arrives writable");
    clear_counts();
    host_mount_ro(0, HDD0_BYTES, 20, 1'b0);
    check(a_ro == 1'b0, "E12 a writable disk remount clears the latched read-only flag");

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_MOUNT_EJECT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_MOUNT_EJECT: FAIL (%0d errors)", fails);
  end

endmodule
