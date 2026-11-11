// WHICH image slot's mount may request a platform reset, separated from z486_mister.sv so
// that it can be TESTED (the same reason pc9821_cpu_reset_gate is a module).
//
// THE HDD SLOTS' MOUNTS RESET (slot 0, and slot 3 - the second hard disk), AND SO DOES A CHANGE
// OF THE OSD'S IDE BANK 1 FIELD; THE FLOPPY SLOT'S MOUNT DOES NOT. hps_io pulses img_mounted for
// a few cycles when the host mounts an image in a slot. Slot 0 is the ATA/HDD image
// (`CONF_STR` "S0,..."), and a mount there while the firmware pack is loaded means the guest
// is running against a disk it has not re-probed, so the core asks for the same platform
// reset as the OSD Reset action and POST re-probes it -- the behaviour this core has always
// had, and not this module's to change. Slot 1 is the FDC0 floppy
// (z486_mister.sv's CONF_STR "S1,D88FDDHDMFDI,Mount FDD1;").
//
// The floppy must NOT reset the machine: changing a floppy disk does not reset the whole
// machine. On real hardware -- and in NP2kai, the primary
// software reference -- a floppy swap resets nothing: the guest simply sees the new medium on
// its next access to the drive. NP2kai's own media test is a live one
// (`fdd_diskready`, diskimage/fddfile.c:92-98: the drive's image name is non-empty) and its
// image mount swaps the file handle in place, so a mount changes what the NEXT FDC command
// reads and nothing else. This core's pc9821_fdd_media re-parses the image on every mount and
// pc9821_fdc reads it through `media_present`, so a floppy mount reaches the guest the same
// way.
//
// WHAT NP2kai HAS THAT THIS MODEL DOES NOT (recorded, not invented): NP2kai also raises a
// MEDIA-CHANGE interrupt from the DOR (0x94) write when the channel-group register's bit 2 is
// set -- `if (fdc.chgreg & 4) { if ((fdc.ctrlreg ^ dat) & 0x08) { if (dat & 0x08) { for each
// ready drive: fdc.int_stat[i] = FDCRLT_AI | i ... } } }` (io/fdc.c:1020-1032). That is the
// signal DOS's disk-change detection reads, and it needs the DOR write path (FDC reset, DMA
// readiness, the AI status class) that this model does not have yet; the DOR is read-only here
// (pc9821_fdc.sv's A_DOR answers NP2kai's fdc_i94 byte). It belongs with the FDC's drive
// mechanics, the floppy's ready-change path.
//
// THE SECOND HARD DISK AND THE BANK-1 FIELD reset for the slot-0 reason: the IDE BIOS sizes and
// registers its drives at POST (the Xe10 IDE ROM's IDENTIFY loop, BANK3@0x0789-0x07B7), so a disk
// that appears on, or a drive that changes on, a cable under a running guest is one it has not
// probed. A change of the field in either direction swaps the CD drive and the second disk on
// bank 1, so both edges reset.
`default_nettype none

module pc9821_disk_change_reset (
    input  wire       clk,
    input  wire       reset_async,   // z486_mister.sv's platform reset, asynchronous here
    // The two hps_io mount pulses, one bit per slot: 0 = the ATA/HDD image, 1 = FDC0.
    /* verilator lint_off UNUSEDSIGNAL */   // bit 1 (the floppy slot) is deliberately NOT a
    // term here: ignoring it is this module's purpose, and the port stays the two-bit vector the
    // top level already has (hps_io's img_mounted[VDNUM-1:0]) rather than a single bit, so the
    // slot a future floppy-change path would need is visible rather than silently dropped.
    input  wire [1:0] img_mounted,
    /* verilator lint_on UNUSEDSIGNAL */
    // The firmware pack is loaded (pc9821_rom_loader's rom_ready). The initial boot mount is
    // excluded by ordering rather than by a timer: the MGL lists the image before the pack
    // (tools/deploy_mister.sh, tools/mister_load.sh), so a boot mount rises while this is
    // still low. rom_ready survives a platform reset, which is what keeps it a valid "pack
    // present" marker across the reset the HDD slot requests.
    input  wire       pack_loaded,
    // hps_io slot 3's mount pulse: the second hard disk.
    input  wire       hdd1_mounted,
    // The OSD's IDE bank 1 field (1 = the second hard disk is bank 1's master), a level.
    input  wire       ide_bank1_hdd,
    output wire       reset_req
);

  // The hard-disk slots' previous levels (a MOUNT is the rising edge) and the field's (a CHANGE
  // is either edge).
  reg hdd_mounted_d, hdd1_mounted_d, ide_bank1_hdd_d;

  always @(posedge clk or posedge reset_async) begin
    if (reset_async) begin
      hdd_mounted_d   <= 1'b0;
      hdd1_mounted_d  <= 1'b0;
      ide_bank1_hdd_d <= 1'b0;
    end else begin
      hdd_mounted_d   <= img_mounted[0];
      hdd1_mounted_d  <= hdd1_mounted;
      ide_bank1_hdd_d <= ide_bank1_hdd;
    end
  end

  // ONE cycle per event, and only for the hard-disk slots and the field. A level is enough:
  // reset_req feeds the top level's reset synchroniser, which holds the core in reset until its
  // shift releases. Before the pack is loaded nothing resets: the field is sampled at the
  // platform reset / reload strobe that the pack load itself ends (pc9821_system).
  assign reset_req = ((img_mounted[0] & ~hdd_mounted_d) | (hdd1_mounted & ~hdd1_mounted_d) |
                      (ide_bank1_hdd ^ ide_bank1_hdd_d)) & pack_loaded;

endmodule

`default_nettype wire
