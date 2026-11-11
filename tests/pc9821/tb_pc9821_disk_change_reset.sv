`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DISK_CHANGE_RESET: The image slot a mount lands in decides whether the core asks for a platform reset: a mount on hps_io slot 0 (the ATA/HDD image) while the firmware pack is loaded raises reset_req for exactly ONE cycle, a mount on slot 1 (the FDC0 floppy, the OSD's S1,D88FDDHDMFDI,Mount FDD1 entry) raises nothing at all however long it is held, and a mount on either slot before the pack is loaded raises nothing either (the boot mount is excluded by ordering, since the MGL lists the image before the pack) - so changing a floppy cannot re-POST the machine, which is the rule and a FAIL-FIRST scoping proof against the reset wire that ORed both slots; a held mount level raises nothing on every new clock (the request is the rising edge) and a second separate mount pulses again; a mount on slot 3 (the second hard disk) resets exactly as slot 0's does (one cycle with the pack loaded, none before it), and so does every change of the OSD's IDE bank 1 field, in either direction (one cycle each with the pack loaded, none before it).
//
// The slot-1 case is the rule that changing a floppy must not reset the machine, and it
// FAILS against a reset wire that ORs both slots together - which is what this core did before
// it - so the bench is the scoping proof, not a restatement. A mount level that is merely still
// high raises nothing on every new clock (the request is the rising edge), and a separate second
// mount pulses again. One quirk is pinned as-is because it is what the wire this module replaces
// did: the edge detector's flop is cleared by reset_async, so a mount level held ACROSS the
// release is read as an edge in the first clock after it - harmless (the platform is being reset
// by that same path at that instant), and pinned so it is not silently re-shaped.
//
// Every count below is taken at a POSEDGE, because that is the only instant reset_req can be
// observed: the request is combinational from img_mounted and its own flop, and the flop clears
// it on the same clock edge the mount is sampled - so a poll taken between the two edges sees
// only zeroes and would have PASSED against the ORed wire this change removes.
// ==== DUT ====

module tb_pc9821_disk_change_reset;

  reg clk = 0;
  always #5 clk = ~clk;

  reg        reset_async = 1;
  reg [1:0]  img_mounted = 2'b00;
  reg        pack_loaded = 1'b0;
  reg        hdd1_mounted = 1'b0;    // hps_io slot 3, the second hard disk
  reg        bank1_hdd = 1'b0;       // the OSD's IDE bank 1 field
  wire       reset_req;

  pc9821_disk_change_reset dut (
      .clk(clk),
      .reset_async(reset_async),
      .img_mounted(img_mounted),
      .pack_loaded(pack_loaded),
      .hdd1_mounted(hdd1_mounted),
      .ide_bank1_hdd(bank1_hdd),
      .reset_req(reset_req)
  );

  integer fails = 0;

  // The one-cycle-request counter: `counting` brackets a window, `pulses` is how many clocks
  // reset_req was high inside it.
  reg        counting = 1'b0;
  integer    pulses = 0;
  always @(posedge clk) if (counting && reset_req) pulses = pulses + 1;

  integer k;

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_DISK_CHANGE_RESET: watchdog timeout (no verdict reached)");
  end

  task automatic check(input ok, input [8*64-1:0] what);
    begin
      if (!ok) begin
        $display("  FAIL: %0s", what);
        fails = fails + 1;
      end
    end
  endtask

  // Hold `slot` mounted for `cycles` clocks (plus four released clocks) and report how many
  // clocks reset_req was high over the whole window.
  task automatic mount_slot(input integer slot, input integer cycles, output integer highs);
    begin
      @(negedge clk);
      pulses   = 0;
      counting = 1'b1;
      img_mounted[slot] = 1'b1;
      for (k = 0; k < cycles; k = k + 1) @(negedge clk);
      img_mounted[slot] = 1'b0;
      for (k = 0; k < 4; k = k + 1) @(negedge clk);
      counting = 1'b0;
      highs = pulses;
    end
  endtask

  integer highs;

  // ==== CHECKS ====
  initial begin
    reset_async = 1;
    repeat (6) @(negedge clk);
    reset_async = 0;
    repeat (2) @(negedge clk);

    // ---------------- C1: the initial boot mount must not reset ----------------
    // The pack is not loaded yet, so the boot-time image mount is excluded by ordering.
    mount_slot(0, 4, highs);
    check(highs == 0, "C1 an HDD mount before the pack is loaded raises no reset");
    // The same for the second disk and for the field (a saved config's value arrives at start).
    @(negedge clk); pulses = 0; counting = 1'b1;
    hdd1_mounted = 1'b1; repeat (4) @(negedge clk); hdd1_mounted = 1'b0;
    bank1_hdd = 1'b1; repeat (4) @(negedge clk); bank1_hdd = 1'b0; repeat (4) @(negedge clk);
    counting = 1'b0;
    check(pulses == 0, "C1 an HDD2 mount or an IDE bank 1 change before the pack raises no reset");
    mount_slot(1, 4, highs);
    check(highs == 0, "C1 a floppy mount before the pack is loaded raises no reset");

    // ---------------- C2: a floppy mount NEVER resets ----------------
    // Held for longer than any hps_io pulse, so neither the edge nor the level can leak out.
    pack_loaded = 1'b1;
    repeat (2) @(negedge clk);
    mount_slot(1, 16, highs);
    check(highs == 0, "C2 a floppy mount with the pack loaded raises NO platform reset");

    // A floppy mount in the SAME window as a still-low HDD slot bit: nothing may fire on the
    // floppy's bit, however the host orders the two.
    @(negedge clk);
    pulses = 0; counting = 1'b1;
    img_mounted = 2'b10;
    repeat (16) @(negedge clk);
    img_mounted = 2'b00;
    repeat (4) @(negedge clk);
    counting = 1'b0;
    check(pulses == 0, "C2 the floppy bit alone raises no reset");

    // ---------------- C3: the HDD mount still pulses, once per mount ----------------
    repeat (2) @(negedge clk);
    mount_slot(0, 8, highs);
    check(highs == 1, "C3 an HDD mount with the pack loaded raises a ONE-cycle reset");

    repeat (4) @(negedge clk);
    mount_slot(0, 4, highs);
    check(highs == 1, "C3 a second HDD mount raises its own one-cycle reset");

    // ---------------- C4: a mount level held across the reset release ----------------
    // The edge detector's D flop is cleared by reset_async (exactly as the wire it replaces
    // was), so the first clock AFTER the release sees the held mount level as an edge and
    // requests one cycle. That is harmless and unchanged - the platform is being reset by that
    // same reset_async path at that instant - but it is pinned here so the quirk is not
    // silently re-shaped later; what must NOT happen is a request on every clock of a held
    // level.
    reset_async = 1;
    img_mounted = 2'b01;
    repeat (4) @(negedge clk);
    pulses = 0; counting = 1'b1;
    reset_async = 0;
    repeat (6) @(negedge clk);
    check(pulses == 1, "C4 the release edge requests one reset while the mount level is held");
    pulses = 0;
    repeat (6) @(negedge clk);
    counting = 1'b0;
    check(pulses == 0, "C4 a still-held mount level raises nothing further");
    img_mounted = 2'b00;
    repeat (2) @(negedge clk);
    mount_slot(0, 4, highs);
    check(highs == 1, "C4 the next HDD mount after the reset still raises one reset");

    // ---------------- C5: the second hard disk's mount resets like slot 0's ----------------
    // The IDE BIOS registers its disks at POST (the Xe10 IDE ROM's IDENTIFY loop,
    // BANK3@0x0789-0x07B7), so a disk that appears under a running guest needs the re-POST.
    repeat (4) @(negedge clk);
    @(negedge clk); pulses = 0; counting = 1'b1;
    hdd1_mounted = 1'b1; repeat (8) @(negedge clk); hdd1_mounted = 1'b0; repeat (4) @(negedge clk);
    counting = 1'b0;
    check(pulses == 1, "C5 an HDD2 mount with the pack loaded raises a ONE-cycle reset");

    // ---------------- C6: a change of the IDE bank 1 field resets, both directions ----------------
    repeat (4) @(negedge clk);
    @(negedge clk); pulses = 0; counting = 1'b1;
    bank1_hdd = 1'b1; repeat (8) @(negedge clk);
    counting = 1'b0;
    check(pulses == 1, "C6 IDE bank 1 CD-ROM -> HDD2 raises a ONE-cycle reset");
    @(negedge clk); pulses = 0; counting = 1'b1;
    bank1_hdd = 1'b0; repeat (8) @(negedge clk);
    counting = 1'b0;
    check(pulses == 1, "C6 IDE bank 1 HDD2 -> CD-ROM raises a ONE-cycle reset");

    if (fails == 0) begin
      // ==== VERDICT ====
      $display("TB_PC9821_DISK_CHANGE_RESET: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_DISK_CHANGE_RESET: FAIL (%0d errors)", fails);
  end

endmodule
