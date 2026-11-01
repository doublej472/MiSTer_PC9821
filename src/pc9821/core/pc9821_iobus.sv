// Native z486 PC-9821 I/O fabric: the system control registers, the device-bus
// decode, and the z486 byte-enable lane serializer.

`default_nettype none

module pc9821_iobus #(
    // Software DIP storage: twelve bytes per bank, control port 0x8F1F (bit 7
    // enable, bit 6 bank select), battery-backed, so a real machine powers up
    // holding what SETUP last stored. Writes are ENABLED because the authentic
    // ITF writes both banks back and read-back verifies them before it draws
    // anything (BANK4 0x44E/0x47A/0x7E9).
    parameter SDIP_WRITES_ENABLED = 1,
    parameter [31:0] SYS_CLOCK_HZ = 32'd50_000_000,
    // WHICH I/O-LATENCY PROFILE the bus implements. A COMPILE-TIME choice only: there is no OSD
    // bit, no status[] bit and no runtime mux - build_profile.py picks it exactly the way it
    // picks CLOCK_RATE_HZ, pc9821_system forwards it like SYS_FREQ, and the class table below is
    // DERIVED from it. The unselected table const-folds away (verified:
    // the min profile's module-alone A&S equals a build without the profile table).
    //   0 = "min"      the default table: every class but 0x5F and the 8253 is the
    //                  FSM floor, IO_MIN_HOLD = 4 clk_sys, bit-identical at every clock.
    //   1 = "faithful" the machine's measured per-class, per-direction access TIMES, with the
    //                  EGC register file's address-parity split deliberately held back.
    //   2 = "faithful + EGC-file parity": as 1, plus the EGC file's even-address read class.
    //                  This is the sub-knob for the one measured class whose MECHANISM is still
    //                  unresolved (item 82): level 1 omits it rather than guessing it.
    parameter [1:0] IO_LATENCY_PROFILE = 2'd0,
    // WHETHER THE MPU-PC98II IS ON THE BUS (z486_mister.sv's MPU_EN, which build_profile.py
    // writes from mpu_en, on in every preset). COMPILE-TIME ONLY, like IO_LATENCY_PROFILE: with 0
    // the two 0xE0D0/0xE0D2 match lines below are constants, so the device half's OR tree is
    // the one this bus had before the card existed. pc9821_system passes its own MPU_EN here.
    parameter MPU_EN = 1'b0,
    // WHETHER THE SDRAM PHASE INSTRUMENT IS ON THE BUS (z486_mister.sv's SDRAM_PHASE_DYN, a
    // test-only build): its two device ports 0x5FF0/0x5FF2 (pc9821_device_select's sdph_cs).
    // With 0 the select is a constant 0 and the decode is the base one.
    parameter SDRAM_PHASE_DYN = 1'b0,
    // WHETHER IDE UNIT 2 (bank 1's master) HOLDS A DRIVE: pc9821_system's CDROM_EN, since the
    // ATAPI CD-ROM is always that unit (the fixed layout). COMPILE-TIME: a
    // drive on a connector does not come and go with the disc in it. 0 sets port 0xF0 bit 6
    // (active low, see ide_unit0_present), so the ITF leaves the empty connector out of its IDE
    // drive bitmap. The default 1 is the measured strap's own bit 6 (clear).
    parameter IDE_UNIT2_PRESENT = 1'b1
) (
    input wire clk,
    input wire reset,

    // WHICH MACHINE'S PORT-0xF0 MACHINE-ID STRAP the core answers, the OSD's four-bit
    // Machine field: 0 = PC-9821Xe10 (the measured strap, the config-less default),
    // 1 = PC-9821Xe, and 2..15 reserved. The pack file IS the firmware set (the MGL
    // chooses it); this field selects only the strap byte the two ITFs read differently
    // (see the HX_00F0 read arm and its machine_id_strap LUT). THE FIELD APPLIES ONLY ON
    // A MACHINE RESET / RELOAD: the strap reads the reset-qualified latch bios_set_eff
    // (beside that LUT), never this live pin, so a mid-run OSD change cannot move the
    // machine's identity under the running firmware. The field is four bits because
    // status[5] is already the DDR framebuffer's BGR/RGB control.
    input wire [3:0] bios_set,

    // IDE UNIT 0 (bank 0's master) HAS A DRIVE: port 0xF0 bit 5 reads 0. The machine's ITF reads
    // 0xF0 bits 5/6 as the two IDE connectors' drive-present lines - bit 5 = unit 0, bit 6 = unit
    // 2, active low - and builds from them the IDE drive bitmap (BANK4@0x19DF-0x19F2), the D8000
    // IDE-ROM gate (BANK4@0x0207), the 0x435/0xB00 chipset set-up (BANK4@0x1BCB, @0x1E43) and the
    // 0x457 work byte (BANK4@0x1B6C-0x1B8F; NP2kai bios.c:322's 0x457 formula keys the same two
    // units). The measured Xe10 byte 0xA9 has bit 5 SET (no drive on bank 0) and bit 6 clear (the
    // measured machine's CF card in the CD connector, bank 1). The core's layout is fixed - the hard disk on
    // bank 0, the CD-ROM on bank 1, the stock Xe10's and NP2kai's (HDD unit 0, CD unit 2) - so bit
    // 5 follows the hard disk's image and bit 6 follows IDE_UNIT2_PRESENT (the CD build).
    input wire       ide_unit0_present,

    // THE GDC-CLOCK STRAP, the OSD's GDC Clock field: 0 = 2.5 MHz (the measured machine),
    // 1 = 5 MHz. On the machine this is port 0x31 bit 7 - the "DIP switch 2" strap, which
    // reads 0xF3 with bit 7 SET - and it is the whole software-visible GDC clock: the main
    // BIOS copies that bit into work-area 0x54D bit 5 (BIOS.ROM@0xFD93C-0xFD945) and the
    // display-mode helper derives 0x54D bit 2 from it (BIOS.ROM@0xF65AF-0xF65DF), which is
    // the bit the games read (rec98/th01/hardware/scrollup.cpp:22-27; TH03's own 5 MHz
    // refusal, th03/op_01.cpp:836-847). 5 MHz is bit 7 CLEAR, i.e. 0x73.
    // WHICH PORT 0x31 IS NOT: the 14-byte software-DIP/CG record at store 0x810. That
    // store is the ITF's own configuration mirror - only BANK4 ever selects CG code 0x2056
    // - the ITF never writes 0x54D at all, and the main BIOS never reads the record, so a
    // bit seeded there could not reach 0x54D.
    // SAME RESET-QUALIFIED RULE AS bios_set: the BIOS samples the strap once at POST, so
    // the latch gdc_strap_eff - not this live pin - is what answers the port. A mid-run OSD
    // change cannot move the clock under the running firmware, and needs no core restart to
    // be seen once the guest has one.
    input wire gdc_clock_5m,
    // OSD: the FDD-mode switch, 0x00BE bit 2 (1 = Fixed, 0 = Auto); pc9821_fdc latches it on
    // reset, as POST samples it. See pc9821_fdc's dip_fixed for the evidence.
    input wire fdd_dip_fixed,

    // z486's one-cycle `triple_fault_reset` (a fault arriving during #DF
    // delivery). It is the machine's CPU-RESET class, the same one `out 0xF0`
    // and the 0x534 bit request, so it is handled here beside the A20 gate and
    // never becomes a framework button or a platform reset.
    input wire triple_fault_reset,

    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_din,
    input  wire [3:0]  cpu_be,
    input  wire        cpu_valid,
    input  wire        cpu_write,
    output reg  [31:0] cpu_dout,
    output reg         cpu_ready,
    output reg         cpu_resp_valid,

    input wire [7:0] debug_status,
    // Serial calendar data output, sampled into bit 0 of system port 0x33.
    input wire        cal_cdat,

    // The OSD's selected guest RAM in MiB (1/2/4/8/16/32/64/96), and the enable for the
    // memory-switch pair's own strap cell below. UNDRIVEN IN EVERY BENCH THAT DOES NOT DRIVE
    // IT ON PURPOSE, which is why the seed is gated rather than always on: an unconnected
    // input is 0, i.e. "no seed". SAMPLED AT MACHINE RESET ONLY (cfg_ram_mib_eff below):
    // the strap cell is a memory-switch cell like the two pc9821_crtc latches, so a mid-run
    // OSD change cannot move it under the running firmware.
    input  wire [6:0] cfg_ram_mib,
    input  wire       cfg_seed_en,

    // The machine-reset seed's one cycle: asserted at the reset ASSERTION (the walk state is
    // deliberately not reset-held, so it must start while this module is in reset - see the
    // seed block). Exported so the CG record is re-seeded by the reset too, from one event.
    // The store's restore walk has this one source and no zero mode.
    output wire       sdip_seed_pulse,

    // Byte transaction presented to the compartmentalized device fabric.
    output wire        device_io_wr,
    output wire        device_io_rd,
    output wire [15:0] device_io_addr,
    output wire  [7:0] device_io_din,
    input  wire  [7:0] device_io_dout,
    // THE DEVICE-BUS CHIP SELECTS, from the ONE decode inside this file: pc9821_device_select
    // instantiated at the bottom over `device_io_addr`. They are this fabric's port-claim
    // products, so they cross here rather than being decoded again beside it; the claim itself
    // (dev_bus_cs) stays inside as `device_port`, because nothing outside needs it.
    // pc9821_system routes the selects to the devices and builds device_io_dout from them.
    output wire        pic_master_cs,
    output wire        pic_slave_cs,
    output wire        pit_cs,
    output wire        interrupt_cs,
    output wire        cal_cs,
    output wire        kbd_cs,
    output wire        ata_cs,
    output wire        opna_cs,
    output wire        pcm_cs,
    output wire        gameport_cs,
    output wire        mpu_cs,
    output wire        sdph_cs,
    output wire        gdc_cs,
  // Devices whose read data is not valid in the strobe cycle raise this to ask
  // for one more cycle. Only the GDC needs it, because it reads its CG and ANK
  // arrays out of block RAM one cycle behind the address. Every other device
  // must keep the one-cycle timing, because devices act on that strobe: the ATA
  // advances its PIO byte pointer on it and the PIT gates its output on it.
  input wire        device_rd_wait,
  // A device whose read needs MORE than the one extra cycle HOLDS this HIGH: the
  // S_DEVWAIT state stays put while it is set, so the CPU waits and then captures the
  // data the device presents when it drops. Only the CG block uses it, and only while
  // its SDRAM glyph burst is in flight - the machine's own CG-ROM read is synchronous,
  // so the core stalls the guest rather than answer the previous code's glyph
  // An UNDRIVEN input is 0, so every other device and every
  // bench keeps the one-cycle timing.
  input wire        device_rd_hold,
  // The write back-pressure. A device whose WRITE cannot be accepted right now
  // (its buffer would drop the byte) HOLDS this HIGH: the S_IOWAIT state stays
  // put while it is set AND the access is a device write, so the CPU stalls
  // before the S_BYTE strobe ever fires and the write is never lost. This is
  // what turns the OPNA register queue's and the 86-PCM 0xA46C FIFO's silent
  // drop-on-full into back-pressure (NP2kai applies every write). Checked before
  // the strobe, exactly like device_rd_wait is honoured at it. Reads are
  // unaffected. An UNDRIVEN input is 0, so every other device and every bench
  // keeps the existing timing.
  input wire        device_wr_wait,

    // 32 KiB ROM-window state at 0xF8000-0xFFFFF (0x043D / 0x043F).
    output reg [3:0] top_bank,
    // The EMS page window at 0xB0000-0xBFFFF, selected by 0x043F's 0x2 high nibble. The
    // machine has THREE measured states, not a page field
    //   0x20 = the identity decode, i.e. the ordinary VRAM planes; this is what the
    //          BIOS's own mode-set stub writes (BANK7@0xD2A writes 0x20|strap) and the
    //          ITF writes back after its test (BANK4@0xF834D), so it must leave
    //          0xB0000-0xBFFFF as GVRAM or every mode set breaks the planes;
    //   0x22 = the 64 KiB memory window - the ITF's pass path fills and verifies all
    //          0x4000 dwords of it at ES=0xB000 (BANK4@0xF82C7-0xF8317), so it is RAM;
    //   any other 0x2x (measured 0x24, and 0x21 does not share 0x20's store) = unmapped.
    // ems_state encodes exactly that: 0 = identity/VRAM, 1 = the RAM page, 2 = unmapped.
    output reg [1:0] ems_state,
    // 0xA460 bit 0: the PC-9801-86's extension enable. On the real card that
    // bit, not a strap, is what makes the 0x18C/0x18E bank answer (NP2kai
    // cbus/pcm86io.c fmboard_extenable; cbus/board86.c returns 0xFF until it is
    // set). Latched here, consumed by pc9821_opna.
    output reg sound_extend,
    // System port C bit 3, the PC-98 BEEPER MUTE. It is a MUTE, not an enable:
    // SET silences the speaker, CLEAR lets the PIT's channel-2 square wave
    // through (NP2kai sound/beepc.c ANDs the PIT output with this bit). The
    // firmware has the same polarity -- the ITF unmutes before stage 0x1F and
    // re-mutes after (BANK4@0x37F clears bit 3, BANK4@0x3CB sets it). Reset
    // value is the MEASURED one, 0xB8, which has bit 3 SET
    // so the beeper is silent until the firmware clears it.
    output wire       beep_mute,
    // The 2-bit BEEPER VOLUME from software-DIP port 0x871E bits [3:2]: ITF
    // SETUP writes it and it scales the speaker amplitude in z486_mister (0 =
    // exact mute). NP2kai models the same register: io/dipsw.c:44-57 takes
    // (value >> 2) & 3 from a 0x871E write into BEEP_VOL, io/dipsw.c:97-103
    // reads it back, sound/beepg.c scales the beeper by it (linear, 0 = mute).
    output wire [1:0] beep_vol,
    // FDC interrupt at the 2HD window, slave PIC IRQ11. Level: set when a
    // RECALIBRATE/SEEK completes and cleared when SENSE INTERRUPT STATUS drains
    // the last pending completion. pc9821_system wires it to slave_irq[3] (the
    // BIOS installs its FDC ISR at IVT vector 0x13, i.e. slave IRQ11 -- see
    // pc9821_fdc).
    output wire       fdc_irq,
    // The SAME interrupt at the 2DD window, slave PIC IRQ10. Only one of the two
    // is ever asserted: the strap (0x00BE bit 0, pc9821_fdc's chgreg) routes the
    // one controller's completion to IRQ11 (2HD, the default) or IRQ10 (2DD).
    // NP2kai fdc_intwait does exactly this (io/fdc.c:43-56: pic_setirq(0x0b) for
    // chgreg & 1, pic_setirq(0x0a) otherwise), and pc9821_system lands it on
    // slave_irq[2], the 1'b0 that reserved IRQ10.
    output wire       fdc_irq10,
    // ---- floppy media seam (pc9821_fdd_media; the FDC is its only consumer) ----
    // The media module itself lives in pc9821_system beside the disk image slot, so this
    // file carries the seam rather than the module. See pc9821_fdc's port comment for the
    // contract: a one-cycle `req` naming (C,H,R,N) or a READ ID header ordinal, a level
    // `rdy` that gates the DMA request, and sticky `err`/`hdrv` levels.
    input  wire [3:0] fdd_present,
    // [u] the mounted medium's write-protect state, from pc9821_fdd_media: the FDC's SENSE DRIVE
    // STATUS WP bit and its write commands' FDC_DriveCheck(TRUE) (pc9821_fdc's port comment).
    input  wire [3:0] fdd_wp,   // [u], units 2/3 zero: pc9821_fdc's writeprotect shape
    // [u] pc9821_fdd_media's media-change tag (a toggle per mount event) and the guest's frame
    // pulse: the FDC's NP2kai ready-change interrupt and insert delay (pc9821_fdc's ports).
    input  wire [3:0] fdd_chg,
    input  wire       fdd_frame_tick,
    output wire       fdd_req,
    output wire       fdd_req_hdr,
    output wire [1:0] fdd_unit,
    output wire [7:0] fdd_c,
    output wire [7:0] fdd_h,
    output wire [7:0] fdd_tc,   // the physical cylinder (pc9821_fdc's media_tc)
    output wire       fdd_hd,   // the physical side (pc9821_fdc's media_hd)
    output wire       fdd_mf,   // the command's MF bit (pc9821_fdc's media_mf)
    output wire       fdd_2hd,  // the media mode, 0x00BE bit 1 (pc9821_fdc's media_2hd)
    output wire       fdd_rpm,  // the unit's 0x04BE rpm bit (pc9821_fdc's media_rpm)
    output wire [7:0] fdd_r,
    output wire [7:0] fdd_n,
    output wire [7:0] fdd_idx,
    // The write leg (pc9821_fdc's media_wr / media_din): the request is a WRITE DATA sector, and
    // the byte each `fdd_adv` stores.
    output wire       fdd_req_wr,
    output wire [7:0] fdd_din,
    // the controller abandoned the request in flight (pc9821_fdc's media_abort, one cycle)
    output wire       fdd_abort,
    input  wire       fdd_ready,
    input  wire       fdd_rdy,
    input  wire       fdd_hdrv,
    input  wire       fdd_err,
    input  wire [7:0] fdd_dout,
    input  wire [7:0] fdd_hr,
    input  wire [7:0] fdd_hn,
    input  wire [7:0] fdd_hs,
    output wire       fdd_adv,
    // ---- the uPD71071's bus-master memory port (pc9821_memory_subsystem) ----
    // Exported so the memory subsystem arbitrates the transfer as its third owner.
    // A floppy READ moves bytes FDC -> memory (a store); WRITE DATA moves them memory ->
    // FDC (a DMA read, answered on dma_mem_resp_valid).
    output wire [31:0] dma_mem_addr,
    output wire [1:0]  dma_mem_gvwin,   // dma_mem_addr's plane-window class (pc9821_dmac mem_gvwin)
    output wire [31:0] dma_mem_din,
    output wire [3:0]  dma_mem_be,
    output wire        dma_mem_req,
    output wire        dma_mem_we,
    input  wire        dma_mem_ready,
    input  wire [31:0] dma_mem_dout,
    input  wire        dma_mem_resp_valid,
    // The bus mouse's IRQ13 request: pc9821_mouse's periodic one-clk pulse
    // (mouseint's pic_setirq(0x0d), io/mouseif.c:131-140), routed to the slave
    // PIC's IR5 in pc9821_system.
    output wire       mouse_irq,
    // hps_io's parsed PS/2 mouse packet (sys/hps_io.sv:106-107), consumed by
    // pc9821_mouse below: [24] toggles once per packet, [23:16] Y (PS/2:
    // positive up), [15:8] X (positive right), [2:0] {middle, right, left}.
    input  wire [24:0] ps2_mouse,
    // 0x0461, the base of the movable 128 KiB window at 0x80000-0x9FFFF:
    // physical(win0_sel*0x10000 + offset), where win0_sel is the page number
    // the guest wrote with bit 0 dropped. 0x08 is the identity, 0x0E points at
    // 0xE0000-0xFFFFF, 0x0C at 0xC0000-0xDFFFF (BANK4@0x01D3/0x0201/0x0265).
    output reg [7:0] win0_sel,
    // `win0_sel != 8'h08` (the window moved off the identity), REGISTERED on the same edges as
    // win0_sel from the same next value, so it equals the compare in every cycle without the
    // compare's LUT levels on the memory map's address cone (docs/timing.md C7-head). Reset:
    // win0_sel resets to the identity 0x08, so this resets to 0.
    output reg       win0_sel_moved,
    // 0x043B bit 2: the 15-16 MiB SYSTEM-SPACE hole. BIT 2 SET asks for RAM there (the
    // hole NOT used); bit 2 CLEAR enables it - no RAM at 0xF00000-0xF9FFFF, and
    // 0xFA0000-0xFFFFFF aliasing the low 0xA0000-0xFFFFF. Reset leaves the hole OFF, so
    // 15-16 MiB is RAM until the guest clears the bit. Consumed by pc9821_memory_subsystem,
    // which translates BEFORE its route selects.
    output wire sys16m_en,
    output wire ide_rom_enable,
    // 0x063C bits 1-0, the 0xD8000 window's ROM bank select (docs/probes/D8BANK-XE10.TXT):
    // pc9821_memory_map serves the select-1/3 banks; 0 and 2 are the IDE option ROM.
    output wire [1:0] d8_bank,
    // The IDE option ROM's private 8 KiB work RAM at 0xDA000-0xDBFFF is behind
    // this visibility gate (port 0x1E8E bit 0, latched below): with it clear the
    // machine reads 0xFF at the window and drops its stores (docs/probes/
    // SHADOWW.TXT:226-231 - the marker read-back FFFF under 0x80, 5AA5 under
    // 0x81), so pc9821_memory_map routes the gated state to the absent-area
    // responder. Exported because the gate is a MEMORY property, not a port
    // answer: the read-back arm below is machine-exact as it stands (FE/FF, the
    // capture's "1E8E read-back after 80/81/restore = FE FF FE"), and NP2kai's
    // 0x80/0x81 read plus its ignore-0x80 write are both machine-refuted.
    output reg ide_ram_gate,
    // 0x043F's 0x8 nibble: the writable shadow over the 0xF8000-0xFFFFF window. The ITF
    // writes 0x80 here before it stores its candidate-drive bitmap (BANK4@0x1CD/0x19CE)
    // and the option ROM reads that store back later, so the enable makes the memory map
    // serve the window's shadow instead of the pristine pack (pc9821_memory_map). It is a
    // LATCH, not a bank: the machine's probe shows 0x80/0x82 leave the window's ROM word
    // unchanged (docs/probes/SHADOW.TXT). Reset clears it, which is what lets
    // the ITF's own ROM sum -- which runs before its 0x80 write -- read the pack.
    output reg        top_shadow_en,
    // 0x053D bit 1: the writable BIOS RAM copy (QEMU bios_ram_gate). The ITF
    // sets it before it builds the shadow (BANK4@0xF825B/0xFA508), and with it
    // clear the machine shows ROM and discards stores, so the memory map uses
    // it to gate firmware-window writes.
    output reg bios_ram_gate,
    output reg a20_enable,
    output reg cpu_reset_req,
    output reg [15:0] unmapped_writes,
    output reg [15:0] unmapped_reads,
    output reg [15:0] last_unmapped_port,
    output reg  [7:0] post_code,
    output reg        post_write,

    // EGC gate: the EGC's extended-mode bit (FF2 num 2) AND the GRCG's CG-mode
    // bit (0x7C bit 7), supplied by pc9821_gdc_text. Both are required and both
    // are satisfied by every real sequence -- master.lib EGC_ON writes
    // `out 6Ah,07h / out 6Ah,05h / out 7Ch,80h / out 6Ah,06h`, and the main
    // BIOS's own enable (BANK7@0x0B08) is the same shape -- so the register
    // file is write-only while the EGC is off.
    input wire        egc_gate,

    // The 0x9A0 extended-video index/query state from pc9821_crtc (its
    // gdc_ff2_state output, which documents the bit layout). This module owns
    // the port and the ff2 index latch; the bits the query table reads live with
    // the GDC registers (NP2kai gdc_i9a0, io/gdc.c:969-1030).
    input wire [10:0] gdc_ff2_state,

    // The EGC register file, latched from 0x04A0-0x04AE. The engine lives in
    // pc9821_egc.sv (in the memory path); the register decode is this module's,
    // like every other system-port latch here. Byte ports write the low byte at
    // the even address and the high byte at the odd one, which is exactly
    // NP2kai's egc_o4a0 (NP2kai/io/egc.c:24-95).
    output reg [15:0] egc_access,
    output reg [15:0] egc_fgbg,
    output reg [15:0] egc_ope,
    output reg [15:0] egc_fg,
    output reg [15:0] egc_mask,
    output reg [15:0] egc_bg,
    output reg [15:0] egc_sft,
    output reg [15:0] egc_leng,
    // One-cycle flag: a write to 0x4AC/0x4AE landed this cycle. Those two
    // registers re-arm the shifter (NP2kai egcshift(), io/egc.c:78-95), which
    // is the only thing in the register file with a side effect.
    output reg        egc_shift_we,

    // IDE option-ROM gate state for the stall watchdog:
    // {ide_rom_enable, rom_gate_ide, pci_d8_select[1:0]}. These are the two
    // things the guest must establish before the 0xD8000 window contains the
    // disk BIOS, and in simulation the working boot reads 0xC (window enabled,
    // 0x053D gate set, 0x063C select 00 = the IDE ROM). Reading something else on hardware
    // says where boot stopped.
    output wire [3:0] dbg_gate,

    // The authentic ITF's own POST stage code, latched from port 0x0610. The ITF
    // writes 0x1A, 0x1B, 0x1C, 0x1D ... in order as it works through POST, so the
    // value names the test it is in: 0x1D is the EMS check at BANK4@0xF8290.
    output wire [7:0] dbg_itf_stage,

    // The ARTIC timestamp counter's UPPER HALF - the exact 16 bits the firmware reads with
    // `in ax,0x5E` from ports 0x5E/0x5F. Exported for the watchdog message's U field, because
    // the ARTIC value moves during a stall while the last unmapped port does not.
    output wire [15:0] dbg_artic_hi,

    // The MOST RECENT I/O access, for the watchdog message: the port, the byte, and which
    // direction it went. A guest freeze loop polls one port with interrupts off, so the polled
    // port is the thing a serial capture needs and is otherwise invisible. One small latch, not
    // the bus's own state: it holds the value of the last completed access rather than following
    // the current one, so the watchdog (a different, slow path) reads a settled word.
    output reg  [15:0] dbg_last_io_addr,
    output reg  [7:0]  dbg_last_io_data,
    output reg         dbg_last_io_rd,
    output reg         dbg_last_io_wr,

    // The FDC's own diagnostics, passed through from pc9821_fdc for the stall record's
    // FST/FCM/FRS/FCH fields: {IRQ, DRQ, st, x_st}, the last command byte, the last
    // result word and the CHRN of the sector in flight. The controller lives behind
    // this module's register decode, so its taps cross here; see pc9821_fdc for what
    // each field means. Unconnected outputs prune away with the telemetry (PERF_LOG_EN).
    output wire [7:0]  dbg_fdc_state,
    output wire [7:0]  dbg_fdc_cmd,
    output wire [31:0] dbg_fdc_result,
    output wire [31:0] dbg_fdc_chrn,

    // The core's NATIVE WHOLE-L1 FLUSH (src/z486/docs/platform-integration.md):
    // every flush trigger below collapses to one cache_flush_req pulse, and the
    // write completes when the core answers cache_flush_done. The CPU's snoop
    // input is driven separately, by the DMA's accepted writes (pc9821_system).
    output wire        cache_flush_req,
    input  wire        cache_flush_busy,
    input  wire        cache_flush_done,

    // 0x09A8 bit 0, the 24/31 kHz select (its latch below): the dot clock and the monitor range
    // the raster runs on (pc9821_dot_ce, pc9821_crtc) and the video PLL's configuration (the top).
    output wire        crt31k
);

  import pc9821_ports_pkg::*;
  // The telemetry reports this: it is the firmware's own progress marker, so on
  // hardware it names the test the machine is in rather than leaving it to be
  // inferred from whatever the screen does or does not show.
  reg [7:0] itf_stage;   // declared before its only reader: a reg may not be referenced
  assign dbg_itf_stage = itf_stage;   // first (iverilog read the name as a 1-bit net)

  // The ARTIC counter's upper half as the firmware reads it: `in ax,0x5E` returns byte 0x5E in
  // AL (cnt[15:8], the 0x5D mirror) and byte 0x5F in AH (cnt[23:16]), so the word is cnt[23:8].
  // The firmware's delay() helper in the IDE option ROM spins on exactly this value
  // (BANK3@0x0B1B and 0x0B2A), so reporting it is what settles whether that loop can ever exit.
  assign dbg_artic_hi = artic_cnt[23:8];

  // How long ONE I/O access occupies the bus. A per-class machine property: the class
  // gate belongs to the ACCESS, not the device. Every class but the TWO the firmware
  // itself needs is IO_MIN_HOLD: the FSM's own S_IDLE -> S_IOWAIT -> S_BYTE -> S_REPLY
  // plus the hold inserted before S_BYTE (the hold is the class value minus those three
  // cycles). The machine-measured classes (EGC 400 ns, text GDC 460 ns, graphics GDC
  // 680 ns, default 840 ns, in 0x5F-ratio units) are NOT modelled: they are deliberately
  // dropped to the FSM floor to cut the CPU's I/O-bus wait. What that costs at a higher clk_sys is that the
  // FLOOR is a fixed clk_sys count where the machine's class values are real times, so
  // one access is 80 ns at 50 MHz but 33 ns at 120 MHz - measured at both
  // clocks (an open decision, docs/trade-candidates.md).
  // TWO FLOORS survive, because the firmware is the gate and neither is a timing
  // choice: 0x005F is its own I/O-wait port, and the 8253 ports must outlast one
  // 2.4576 MHz PIT tick or the ITF's timer self-test reads its just-written byte back.
  // Both are TIMES in cycles.
  localparam [15:0] IO_MIN_HOLD = 16'd4;   // the FSM floor: the minimum bus occupancy
  localparam [15:0] IO_PIT_HOLD = 16'((SYS_CLOCK_HZ + 32'd2_457_599) / 32'd2_457_600);  // 8253: ceil(one PIT tick)
  // 0x005F's DOCUMENTED anchor: the firmware's own I/O-wait port, whose delay loops were
  // calibrated to the machine's documented 600 ns. NO profile charges that 600 ns:
  // the faithful profile's read is IO_NS_5F_R (826) and its write IO_NS_5F_W (1621), and the
  // min profile charges IO_NS_5F_W in BOTH directions (its arm below says why). The
  // documented anchor is therefore a comment, not a localparam (it would be an unused one).

  // ---- the FAITHFUL profile's class table: the machine's measured access TIMES ----
  // Every value is the `abs_ns` column of docs/probes/IO.TXT (the 2026-09-24 Xe10 capture,
  // decoded by tools/hwprobe/ioprobe/ioprobe_decode.py; its figures are device-clock-referred
  // and therefore absolute), converted to cycles from SYS_CLOCK_HZ with the same ceil idiom
  // IO_WAIT_5F uses - so a class is the same REAL TIME at every profile clock and not a
  // clk_sys count (tb_pc9821_sysclk_invariance checks that at 50 and 100 MHz).
  // The capture prices READS and WRITES differently, which is why the faithful function takes
  // the direction. Class / direction / the IO.TXT row it is from:
  //   823 R   862 W   default (the 61 measured default ports). The reads are that group's own
  //                   rows; the only measured default-class WRITES are the OPNA 0x188/0x18A
  //                   (864.7/861.5) - and the unrelated 8253 0x77 write is also 861.5, so ~862
  //                   is a bus write cost, not one device's.
  //   386 R   356 W   EGC named 0x6A/0xA6 (reads 387.8/384.6, writes 356.0)
  //   823 R   359 W   the GRCG mode/tile pair 0x7C/0x7E. 0x7C READS at 823.3 - the default read
  //                   class, NOT the EGC one - and writes at 359.2; 0x7E is UNMEASURED and
  //                   takes its pair's values (it carries 82 % of the Rusty wipe's writes).
  //   444 both        text GDC 0x60/0x62 (reads 445.0/441.9; the write direction is unmeasured
  //                   and takes the class's read value - the same choice for the rows below)
  //   676 both        graphics GDC 0xA0/0xA2 (reads 673.9/677.1)
  //   823 R   862 W   IDE PIO data 0x640/0x641 and the task-file/interface registers (reads 820-827)
  //   823 R   861 W   the 8253 0x71/0x73/0x75/0x77 and the 0x3FD9 alias (write 861.5; still
  //                   outlasts one 2.4576 MHz tick, so the ITF self-test floor is kept)
  //   826 R  1621 W   0x005F: its READ is the default class (826.5); its WRITE is IO.TXT's
  //                   1621 ns anchor, the port the firmware's own delay loops measure - the
  //                   value the min profile charges in BOTH directions (a wr-dependent
  //                   value at 0x5F trips a Quartus fitter bug).
  //   823 R   356 W   EGC register file 0x4A0-0x4AF ODD addresses (reads 823.3-826.5)
  //  9290 R   356 W   EGC register file EVEN addresses (reads 8608.5-9365.1, i.e. 8.6-9.4 us);
  //                   profile 2 only - the mechanism is unresolved (item 82), so profile 1
  //                   leaves these at the odd/default read class instead of guessing.
  //   391 both        0x09A0, the PEGC index/data query (`PEGC9A0`, read 391.0 ns). It is the
  //                   EGC named class' near neighbour and 2.1x FASTER than the default, so the
  //                   default arm over-charged it. The write direction is
  //                   unmeasured and takes the class's read value, the same choice the two GDC
  //                   rows make. 0x09A8/0x09AE are NOT in it: neither is measured at all.
  //   296 both        0x0FAA, the accelerator's index port (`ACCFAA`, read 295.6 ns) - the
  //                   fastest port the capture prices, 2.8x under the default (audit-iobus F6,
  //                   which also notes the port has no behaviour model). Its write direction is
  //                   unmeasured; 0xFAB/0xFAC are NOT in the class, they are unmeasured.
  // ceil, so a class is never short of the machine's; the (SYS_CLOCK_HZ * ns + 1e9-1) / 1e9
  // 64-bit form keeps the product inside 64 bits at every profile clock (max 9290 ns x 120 MHz).
  localparam [15:0] IO_NS_SLOW_R  = 16'((SYS_CLOCK_HZ * 64'd823  + 64'd999_999_999) / 64'd1_000_000_000);  // default read / 0x7C,0x7E read
  localparam [15:0] IO_NS_SLOW_W  = 16'((SYS_CLOCK_HZ * 64'd862  + 64'd999_999_999) / 64'd1_000_000_000);  // default write
  localparam [15:0] IO_NS_EGC_R   = 16'((SYS_CLOCK_HZ * 64'd386  + 64'd999_999_999) / 64'd1_000_000_000);  // 0x6A/0xA6 read
  localparam [15:0] IO_NS_EGC_W   = 16'((SYS_CLOCK_HZ * 64'd356  + 64'd999_999_999) / 64'd1_000_000_000);  // EGC/GRCG/EGC-file write
  localparam [15:0] IO_NS_GRCG_W  = 16'((SYS_CLOCK_HZ * 64'd359  + 64'd999_999_999) / 64'd1_000_000_000);  // 0x7C/0x7E write
  localparam [15:0] IO_NS_GDC1    = 16'((SYS_CLOCK_HZ * 64'd444  + 64'd999_999_999) / 64'd1_000_000_000);  // text GDC 0x60/0x62
  localparam [15:0] IO_NS_GDC2    = 16'((SYS_CLOCK_HZ * 64'd676  + 64'd999_999_999) / 64'd1_000_000_000);  // graphics GDC 0xA0/0xA2
  localparam [15:0] IO_NS_PIT_W   = 16'((SYS_CLOCK_HZ * 64'd861  + 64'd999_999_999) / 64'd1_000_000_000);  // 8253 write
  localparam [15:0] IO_NS_5F_R    = 16'((SYS_CLOCK_HZ * 64'd826  + 64'd999_999_999) / 64'd1_000_000_000);  // 0x5F read
  localparam [15:0] IO_NS_5F_W    = 16'((SYS_CLOCK_HZ * 64'd1621 + 64'd999_999_999) / 64'd1_000_000_000);  // 0x5F write (docs/probes/IO.TXT)
  localparam [15:0] IO_NS_EGCF_HI = 16'((SYS_CLOCK_HZ * 64'd9290 + 64'd999_999_999) / 64'd1_000_000_000);  // EGC file even read (profile 2)
  localparam [15:0] IO_NS_9A0     = 16'((SYS_CLOCK_HZ * 64'd391  + 64'd999_999_999) / 64'd1_000_000_000);  // 0x09A0 read/write
  localparam [15:0] IO_NS_FAA     = 16'((SYS_CLOCK_HZ * 64'd296  + 64'd999_999_999) / 64'd1_000_000_000);  // 0x0FAA read/write

  function automatic [15:0] io_access_cycles(input [15:0] portnum, input wr);
    begin
      if (IO_LATENCY_PROFILE == 2'd0) begin
        // ---- the min profile: the smallest waits the firmware needs, not the floor -------
        // Every class but the firmware's own hardware needs is IO_MIN_HOLD. The 0x5F arm takes
        // the machine's measured 1621 ns (item 82, docs/probes/IO.TXT), because the
        // BIOS POST's timer-interrupt test (BANK4@0x487) polls with `out 0x5f` and the poll
        // window must outlast a 2.4576 MHz terminal count or it prints TIMER INTERRUPT ERROR
        // (the 600 ns anchor was ~7 us, the terminal count ~10.6 us).
        // It is ONE value, not the faithful profile's read/write PAIR, and that is forced by a
        // fitter bug, not a design choice: a `wr`-dependent value at 0x5F - written either as
        // `wr ? IO_NS_5F_W : IO_WAIT_5F` or as an if/else - trips a Quartus 17.0 internal error
        // (Sub-system DTM, `visit_atom_stratixv_style_io_obuf`, at physical synthesis) and the
        // fit never produces an RBF; the constant form fits. Measured: both spellings 5/5 crashing, the constant 1/1 fitting, same seed. The 8253 arm just
        // below IS direction-aware and fits, so the bug is specific to this arm's netlist
        // perturbation, not to `wr`-dependence in general. The read therefore also pays the
        // write's time; 0x5F reads are not used by the firmware (0 `in 0x5F` sites against 391
        // `out 0x5F`), and one value per address port is this profile's shape anyway.
        // The faithful profile prices both directions at the capture's times (its arm below);
        // the io_latency_profile bench displays the two tables.
        // The EGC register file is one 16-byte block, matched as a block because
        // the case arms below are exact addresses.
        if ((portnum & 16'hFFF0) == 16'h04A0)
          io_access_cycles = IO_MIN_HOLD;
        else case (portnum)
          16'h005F:            io_access_cycles = IO_NS_5F_W;  // the I/O-wait port: the machine's write time, ONE value (see above)
          // The 8253 and its 0x3FD9 alias. The floor is there for the WRITE: the ITF's POST
          // timer self-test programs a count into the counter and reads it back, and the load
          // needs one 2.4576 MHz tick to land, so the write keeps IO_PIT_HOLD. The READ needs
          // no floor at all (the machine reads it at the default class: the capture's PITD0
          // and PITD1 rows, 823.3 ns), and this profile's default is the FSM floor - charging
          // reads the 420 ns floor was a 2x under-charge in the slow
          // direction and a needless wait in this one.
          16'h0071, 16'h0073, 16'h0075, 16'h0077,
          16'h3FD9, 16'h3FDB, 16'h3FDD, 16'h3FDF: io_access_cycles = wr ? IO_PIT_HOLD
                                                                     : IO_MIN_HOLD;  // the 8253 and its 0x3FD9 alias, the ITF self-test floor (write only)
          16'h0640, 16'h0641:  io_access_cycles = IO_MIN_HOLD;  // the IDE PIO data port
          16'h0642, 16'h0644, 16'h0646, 16'h0648, 16'h064A,
          16'h064C, 16'h064E, 16'h074C, 16'h074E,
          16'h0430, 16'h0432, 16'h1E8E: io_access_cycles = IO_MIN_HOLD;  // the IDE task file
          16'h0060, 16'h0062:  io_access_cycles = IO_MIN_HOLD;  // the text GDC
          16'h00A0, 16'h00A2:  io_access_cycles = IO_MIN_HOLD;  // the graphics GDC
          16'h006A, 16'h007C, 16'h007E, 16'h00A6: io_access_cycles = IO_MIN_HOLD;  // the EGC's mode/GRCG pair/page ports
          default:             io_access_cycles = IO_MIN_HOLD;  // every other class
        endcase
      end else begin
        // ---- the faithful profile: the machine's measured class times, per direction ----
        if ((portnum & 16'hFFF0) == 16'h04A0)
          // Writes are the EGC's fast class; an even-address READ is the 8.6-9.4 us class (only
          // at profile 2); an odd-address read is the default read class.
          io_access_cycles = wr ? IO_NS_EGC_W
                                : ((IO_LATENCY_PROFILE >= 2'd2) && !portnum[0]) ? IO_NS_EGCF_HI
                                                                               : IO_NS_SLOW_R;
        else case (portnum)
          16'h005F:            io_access_cycles = wr ? IO_NS_5F_W : IO_NS_5F_R;
          16'h0071, 16'h0073, 16'h0075, 16'h0077,
          16'h3FD9, 16'h3FDB, 16'h3FDD, 16'h3FDF: io_access_cycles = wr ? IO_NS_PIT_W : IO_NS_SLOW_R;
          16'h0640, 16'h0641, 16'h0642, 16'h0644, 16'h0646, 16'h0648, 16'h064A,
          16'h064C, 16'h064E, 16'h074C, 16'h074E,
          16'h0430, 16'h0432, 16'h1E8E: io_access_cycles = wr ? IO_NS_SLOW_W : IO_NS_SLOW_R;
          16'h0060, 16'h0062:  io_access_cycles = IO_NS_GDC1;
          16'h00A0, 16'h00A2:  io_access_cycles = IO_NS_GDC2;
          16'h006A, 16'h00A6:  io_access_cycles = wr ? IO_NS_EGC_W : IO_NS_EGC_R;
          16'h007C, 16'h007E:  io_access_cycles = wr ? IO_NS_GRCG_W : IO_NS_SLOW_R;
          16'h09A0:            io_access_cycles = IO_NS_9A0;  // the PEGC index/data query, 391 ns
          16'h0FAA:            io_access_cycles = IO_NS_FAA;  // the accelerator index port, 296 ns
          default:             io_access_cycles = wr ? IO_NS_SLOW_W : IO_NS_SLOW_R;
        endcase
      end
    end
  endfunction
  // ONE I/O ACCESS PAYS EVERY LANE IT FETCHES, not just the first lane's class. On the
  // machine each byte of a multi-byte access is its own bus cycle and is therefore classed on
  // its own -- docs/probes/IO.TXT prices 0x005F's READ as an access in its own right (826.5 ns)
  // -- so `in ax,0x5E`, the ARTIC timestamp read the firmware does 20 times across BANK3,
  // BANK6, BANK7 and BIOS.ROM (`E5 5E`), pays the 0x5F read class on its HIGH lane. This core
  // priced the whole access from the FIRST lane and charged every further lane one cycle: the
  // 0x5F lane's class was never paid, a word read of two same-class ports paid one class
  // instead of two, and profile 2's `in ax,0x4A0` dropped the HIGH lane's 9290 ns class. The
  // RULE: the per-lane cost is a machine fact (each byte
  // is an access), while what a multi-lane access costs as a WHOLE was never captured (the
  // ioprobe measures one port at a time), so the sum of the lanes' classes is what the
  // evidence supports and nothing else is invented.
  //
  //   be_walk:  every lane the FSM steps through. Each costs its own S_BYTE cycle (the "one
  //            cycle per further lane").
  //   be_fetch: the subset of those that reaches the bus and so pays a class. The one
  //            divergence is the terminated high lane of a word read at 0x7C (term7c_hi):
  //            the machine never fetches it (NP2kai's minus_term table; see the comment beside
  //            term7c_hi), so it walks and pays its cycle but no class -- charging it would
  //            put two GRCG-class reads on an ordinary guest access.
  //
  // The hold is the lanes' classes less the FSM's own cycles. Each FETCHED lane contributes
  // exactly its class (S_IOWAIT's hold plus its own S_BYTE cycle), and each lane that walks but
  // is not fetched contributes exactly that one S_BYTE cycle; the two cycles the FSM owns
  // regardless (S_IDLE and S_REPLY) come off once. A single lane costs exactly class - 3, and
  // a walked-but-unfetched high lane one class plus one cycle. tb_pc9821_io_class measures a two-lane read of 0x5E/0x5F against it (34 clk_sys
  // in the min profile: 4 + 30).
  function automatic [15:0] io_access_hold(input [15:0] lane0_port,
                                          input [3:0] be_walk, input [3:0] be_fetch,
                                          input wr);
    reg [15:0] total;
    reg [15:0] port;
    integer    l;
    begin
      total = 16'd0;
      port  = lane0_port;
      for (l = 0; l < 4; l = l + 1) begin
        if (be_walk[l] && be_fetch[l])
          total = total + io_access_cycles(port, wr) - 16'd1;   // the lane's class, its S_BYTE cycle included
        port = port + 16'd1;
      end
      total = total - 16'd2;       // S_IDLE and S_REPLY, once per access
      io_access_hold = total;
    end
  endfunction

  // The FSM's own three cycles (S_IDLE -> S_BYTE -> S_REPLY) are part of the
  // access, so the hold inserted before S_BYTE is the remainder.
  // 12 bits: profile 2 at the heaviest profile clock (120 MHz) prices an EGC-file even read at
  // 1115 clk_sys, so `in eax,0x4A0` -- four lanes, two of them even -- sums to 2428 cycles and
  // the hold to 2422, inside 4095. The min profile's maximum is far below it.
  reg [11:0] io_hold;
  reg [2:0] state;
  reg [31:0] base_addr, write_data;
  reg [3:0] pending_be;
  reg request_write;
  reg [31:0] read_data;
  reg flush_start;
  // The flush request is ONE pulse per trigger: there is no per-kind slot or
  // alias descriptor. The core's native flush walks EVERY set of both caches
  // (136 cycles) rather than sweeping the changed window's encoding set line by
  // line (2,048+ snoop lines, up to 65,536 for the sys16m remap). The accepted
  // trade (src/z486/docs/platform-integration.md): a bank flip clears the whole
  // L1 rather than only the moved window's lines - slightly fewer retained
  // lines, one constant latency, no sequencer.
  //
  // ONE TRIGGER FAMILY feeds the one pulse (the launch site is beside
  // `flush_required`, below): the I/O fabric's. The DMA side uses a per-write
  // snoop instead (T24). `flush_start` is the REGISTERED one-cycle request the
  // launch site drives; the FSM does not set it.
  assign cache_flush_req = flush_start;
  wire flush_busy = cache_flush_busy;
  wire flush_done = cache_flush_done;
  reg rom_gate_ide;
  // 0x063C: a byte latch the machine reads back, whose bits 1-0 bank the 0xD8000 window
  // (docs/probes/D8BANK-XE10.TXT; NP2kai io/pcidev.c pci_o063c/pci_i063c latch the whole byte).
  /* verilator lint_off UNUSEDSIGNAL */   // bits 7:2 are only read back
  reg [7:0] pci_d8_select;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [7:0] system_port_c;

  // ---- the read-back devices ----
  // 0x09A0's ff2 query index (NP2kai gdc.ff2, written by gdc_o9a0) and its
  // "nothing written yet" state: the machine answers 0x01 there (probes/R10.TXT
  // `09A0=01`, eleven snapshots, and PORTS.TXT), which is the one capture the
  // power-up INDEX cannot reconstruct - NP2kai's zeroed ff2 would answer 0xFF
  // (its case 0x00), so the arm answers the measured byte until the first write
  // and the NP2kai table from then on. The write-then-read protocol itself is
  // machine-confirmed: probes/PROBE.TXT `FF 9A0 after writing 0x0A: 00`, which
  // is exactly the table's index-0x0A answer with analog-256 clear. The owed
  // probe (write idx / read for idx 0x00..0x0D plus a power-up read) settles
  // both loose ends.
  reg [7:0] gdc_ff2;
  reg       gdc_ff2_written;
  // 0x09A8: the 24/31 kHz select beside it, a LATCH (docs/probes/RDBACK.TXT
  // `port=09A8 before=00 wrote=01 after=01 back=00`). Bit 0 only, NP2kai's width
  // (gdc_o9a8/gdc_i9a8 keep GDCDISP_31 and return `(gdc.display >> GDCDISP_31) & 1`);
  // the machine's high bits are unmeasured (todo item 3). Set, it switches the raster to the
  // separate 31 kHz dot clock (docs/probes/CRT31K.TXT `09A8 after_set31=01` and the 70.06 Hz
  // frame that follows; pc9821_vclk_pkg) - the crt31k output.
  reg       gdc_9a8_31k;
  assign crt31k = gdc_9a8_31k;

  // The bus mouse's uPD8255 PPI at 0x7FD9-0x7FDF and its 0xBFDB timer port
  // live in pc9821_mouse (instantiated with the FDC below): the three port
  // latches, the mode word, the X/Y delta counters and buttons, and the
  // periodic IRQ13 event. The hit decode stays here (the ports are this
  // fabric's system ports); the read arms answer its dout and the write arms
  // below let its strobes consume the bytes.

  // The printer port trio (NP2kai io/printif.c): 0x40 echoes lastData (the last
  // byte written) and 0x44 the i44Data strobe latch, so a read-modify-write
  // round-trips (prt_i40/prt_i44, printif.c:78-111). Power-up values are the
  // MACHINE's captures (PORTS.TXT `0040 00`, `0044 81`), which NP2kai's own
  // statics (0xFF/0x00) disagree with - the captures win, the echo shape is
  // NP2kai's. 0x42's status carries the SELECT-BUSY one-shot: SEVEN consecutive
  // DC1 (0x11) data bytes arm it (prt_o40, printif.c:44-66: the counter must
  // EXCEED 5, so the 6th byte leaves it at 6 and the 7th trips the flag) and the
  // next read answers bit 2 CLEAR once (prt_i42's negative-logic busy,
  // printif.c:83-112).
  reg [7:0] prt_last_data;
  reg [7:0] prt_i44_data;
  reg [3:0] prt_select_count;
  reg       prt_select_busy;

  // Bit 3 only; the whole register stays private to this block.
  assign beep_mute = system_port_c[3];


  // 0x053D bit 4 is the whole gate on this machine. A non-PCI PC-98 has no $PCI
  // BIOS for 0x063C to select (QEMU's own mem_dwin_write carries a "TODO: IDE
  // BIOS/PCI/PnP ROM content banking at 0xd8000"), and the authentic main BIOS
  // preselects this window with 0x063C = (read & 0xFC) | 3 immediately before
  // `call far D800:000C` (BANK6 offset 0x567C-0x5698), so requiring the low two
  // bits to be 01 hides the option ROM exactly when the disk path needs it. The
  // latch is kept for the 0x063C read-back only.
  assign ide_rom_enable = rom_gate_ide;
  assign dbg_gate = {ide_rom_enable, rom_gate_ide, pci_d8_select[1:0]};
  assign d8_bank = pci_d8_select[1:0];

  // The pc9821_cache_flush instance that stood here is replaced by the
  // cache_flush_req pulse (declared above) and the core's busy/done handshake.
  // S_FLUSH's `if (flush_done)` is the ONE consumer of the done pulse; the
  // request's one consumer is the core's flush_req_seen latch.
  //
  // R7/R8 (docs/single-cycle-event-discipline.md): the core LATCHES a request
  // observed while cache_flush_busy is high and runs a second, redundant walk
  // after the current one (src/z486/cache_unit.sv, cf_plat_pending_r). The launch site (beside
  // `flush_required`) pulses only while no walk is committed, because an event
  // arriving during a walk is COVERED by that walk (the coverage rule, argued
  // there); this fires if that ever stops being true. `cache_flush_busy` is also
  // high for a guest INVD/WBINVD walk, which covers an event the same way: it
  // sweeps both L1s and holds the CPU for its whole window.
  // translate_off
  // The two `case (1'b1)` over `hit` (the read arm below and the write arm in the S_BYTE block)
  // carry `synthesis parallel_case`: every line is an equality of port_addr with a DISTINCT constant
  // (the 109 `assign hit[...]` lines below), so at most one is ever set and the case's source-order priority is
  // never exercised. Without the directive the synthesiser, which cannot see that, builds a
  // priority chain behind every arm. This is the guard for that claim.
`ifdef VERILATOR
  always @(posedge clk) begin
    if (!reset && ($countones(hit) > 1))
      $fatal(1, "pc9821_iobus: more than one hit[] line set for port %04h", port_addr);
  end
`endif
  always @(posedge clk) begin
    if (!reset && flush_start && flush_busy)
      $fatal(1, "pc9821_iobus: cache_flush request issued while the core is busy (a redundant walk)");
  end
  // translate_on

  /* verilator lint_off UNUSEDSIGNAL */   // be[3] is unused on purpose: the FOURTH lane is
  function automatic [1:0] first_lane(input [3:0] be);   // the ELSE branch, so with no earlier enable set the access must be lane 3
  /* verilator lint_on UNUSEDSIGNAL */
    begin
      if (be[0]) first_lane = 2'd0;
      else if (be[1]) first_lane = 2'd1;
      else if (be[2]) first_lane = 2'd2;
      else first_lane = 2'd3;
    end
  endfunction

  // Device reads take one extra cycle (S_DEVWAIT) so a device may present its
  // data from a registered block-RAM read. The address, byte enables and lane
  // must not advance during that cycle. They do not: S_BYTE enters S_DEVWAIT
  // without clearing its lane's enable, and only S_DEVWAIT's exit clears it, so
  // the lowest pending enable IS the held lane in every S_DEVWAIT cycle and the
  // lane needs no held copy or state select (tools/check_iobus_lane_inv.py proves
  // it by induction; the select sat at the head of the device-bus cones).
  wire [1:0] lane = first_lane(pending_be);
  /* verilator lint_off UNUSEDSIGNAL */   // only the low 16 bits are the port address
  wire [31:0] lane_addr = base_addr + {30'd0, lane};   // (port_addr below); the upper
  /* verilator lint_on UNUSEDSIGNAL */    // half is not read by anything here
  wire [15:0] port_addr = lane_addr[15:0];
  // THE WORD-READ TERMINATION AT THE GRCG MODE PORT. NP2kai's
  // iocore_inp16 treats a word IN at 0x7C as "upper -" terminated: the
  // minus_term table lists 0x7c (io/iocore16.tbl:23-26) and the handler returns
  // the REG8 zero-extended into REG16 (io/iocore.c:781-782), so `in ax,7Ch`
  // answers 0x00:modereg and port 0x7D is NEVER fetched. The lane walk splits
  // every access into byte ports, so without this the high lane read 0x7D's
  // open-bus 0xFF and the word came back 0xFF:modereg. Latched at S_IDLE with
  // the other access qualifiers: the walk's pending_be shrinks as lanes land,
  // so the captured byte alone cannot tell a word's high lane from a lone byte
  // read at 0x7D (which stays open bus - NP2kai's definp8 - byte reads are not
  // terminated). 0x7E is NOT in minus_term (the table lists 0x7a, 0x7c, then
  // 0xa0), so `in ax,7Eh` keeps the default byte split (io/iocore.c:789-792)
  // and its high byte is 0x7F's open bus, not zero. Only the
  // 0x7C chunk is folded here; the rest of NP2kai's minus_term set (0x60-0x7A
  // and 0xA0-0xAC word reads) still byte-splits. Hardware-unmeasured: no probe
  // has word-read these ports. The folded lane (port 0x7D)
  // is not on the device fabric, so the S_BYTE capture is the only site.
  reg term7c_hi;
  // The lanes the access steps through and the subset of them that reaches the bus, captured
  // from the request at S_IDLE (cpu_be == 0 is not a real access but must still resolve to one
  // lane). io_access_hold prices each fetched lane's class; see its comment for why a walked
  // lane is not always a fetched one.
  wire [3:0] access_be_walk  = (cpu_be == 4'd0) ? 4'b0001 : cpu_be;
  wire       access_term7c   = !cpu_write && (cpu_addr[15:0] == 16'h007C) &&
                               (cpu_be[1:0] == 2'b11);
  wire [3:0] access_be_fetch = access_term7c ? (access_be_walk & 4'b1101) : access_be_walk;
  // Reset state is the ITF: the CPU fetches its first instruction from
  // F800:0000. Values 0-7 are the eight 32 KiB ROM banks selected by port
  // 0x043F; 8 and 9 are the two special states 0x043D selects between. They
  // are not the same thing: the eight banks are the separate ROM set (a
  // PC-9821Xe10 dump has BANK4 as the ITF and BANK7 as a top bank whose bytes
  // differ from the 96 KiB main BIOS), while BANK_BIOS_TOP is the main BIOS's
  // own top 32 KiB. QEMU pc98 models this the same way.
  localparam [3:0] BANK_ITF = 4'd8;
  localparam [3:0] BANK_BIOS_TOP = 4'd9;

  wire [7:0] lane_wdata = write_data[{lane, 3'b000} +: 8];
  wire [3:0] lane_mask = 4'b0001 << lane;
  wire last_lane = (pending_be & ~lane_mask) == 4'd0;
  wire next_ide_from_gate = lane_wdata[4];
  // 0x053D bit 1 is the writable-BIOS-copy gate, and it decides whether the
  // firmware windows read RAM or ROM (QEMU
  // mem_apply_top_bank enables its f8000_ram/e8000_ram aliases on this bit).
  // A change of it therefore changes what a cached line of those windows means,
  // so it is a flush trigger exactly as bit 4 is.
  wire next_bios_from_gate = lane_wdata[1];
  // The ROM window state a 0x043D/0x043F write would install. QEMU's
  // mem_bankflip_write / mem_bankctl_write only act when the value changes,
  // and the same must hold here: an EMS write to 0x043F, or a 0x043D write
  // that reselects the current state, must not cost a 2048-line invalidation.
  wire [3:0] next_bank_043d =
      (lane_wdata == 8'h02 || lane_wdata == 8'h12) ? BANK_BIOS_TOP :
      (lane_wdata == 8'h00 || lane_wdata == 8'h10 ||
       lane_wdata == 8'h18) ? BANK_ITF : top_bank;
  wire [3:0] next_bank_043f =
      (lane_wdata[7:4] == 4'hE) ? {1'b0, lane_wdata[3:1]} : top_bank;
  // The EMS window's 0x043F 0x2-nibble state a write would install (see the
  // ems_state declaration): 0x20 the identity, 0x22 the RAM page, any other 0x2x
  // unmapped. EVERY OTHER NIBBLE LEAVES THE STATE ALONE: qemu's
  // mem_bankctl_write switches on data & 0xf0 and acts only in its 0x20 (EMS)
  // and 0xE0 (bank) cases (pc98-mem.c:684-701), so 0x80/0xA0/0xC0 fall through
  // with the EMS window untouched (see the hit[HX_043F] write arm).
  wire [1:0] next_ems_state =
      (lane_wdata[7:4] == 4'h2) ? ((lane_wdata[3:0] == 4'h0) ? 2'd0 :
                                   (lane_wdata[3:0] == 4'h2) ? 2'd1 : 2'd2) :
                                   ems_state;
  // 0x043F's 0x8 nibble turns the window's writable shadow on (see the port declaration).
  // It is sticky until reset: the nibble is a one-way enable, and no site in the ROM set
  // writes it back to zero.
  wire next_top_shadow_en = (lane_wdata[7:4] == 4'h8) ? 1'b1 : top_shadow_en;
  // The window-base page a 0x0461 write installs. Bit 0 is not part of the page
  // number: measured, 0x0461 = 0x09 maps exactly where 0x08 maps (the machine's
  // /WIN restore reads 0x80000 = 0000 and 0x90000 = 502F with the register at
  // 09 -- both its own) and 0x0461 = 0x01 behaves as 0x00. QEMU drops the same
  // bit before its alias offset (pc98-mem.c:295,708); the machine drops it from
  // the *page* but reads it back set -- see the read arms.
  wire [7:0] next_win0 = lane_wdata & 8'hFE;
  // 0x043B bit 2 flips the 15-16 MiB system-space window (sys16m_en): the whole
  // 0xF00000-0xFFFFFF range changes between RAM and the PEGC window / hole /
  // low-memory mirror (the 0xFFF00000 high alias stays PEGC VRAM either way). That remaps content under cached
  // L1 lines exactly as a bank flip does, so a write that MOVES the bit must
  // flush both remapped ranges.
  wire next_sys16m_en = ~lane_wdata[2];

  // The ROM-window state change (bank or shadow) and the EMS-window state
  // change are separate terms: one 0x043F write can still touch both storage
  // classes' routing (0xE0 moves the ROM bank while the EMS state stands), and
  // the two storages' encoding sets are disjoint enough that the sweep below
  // must cover the union then.
  wire fw_map_change = ((hit[HX_043D]) && (next_bank_043d != top_bank)) ||
                       ((hit[HX_043F]) && (next_bank_043f != top_bank)) ||
                       ((hit[HX_043F]) && (next_top_shadow_en != top_shadow_en));
  // ems_state swaps three storages under 0xB0000-0xBFFFF (planes / the EMS
  // page / open bus), so every 0x2x write must sweep the window's encodings
  // (aliases.md A4).
  wire ems_map_change = (hit[HX_043F]) && (next_ems_state != ems_state);
  // 0x063C's bits 1-0 swap the ROM under 0xD8000-0xDBFFF (selects 0/2 the IDE option ROM,
  // 1 BANK0 0x0000-0x3FFF, 3 BANK0 0x4000-0x7FFF: docs/probes/D8BANK-XE10.TXT), and the
  // L1 I$ caches that window's code. The Xe10 BIOS's INT 1Fh AH=CEh thunk writes the select
  // and far-returns straight into D800:0018 with no flush of its own (BIOS.ROM F560:00EE
  // `out dx,al` ... F560:00F7 `retf`), so a write that changes what the window shows must
  // flush like every other remap here, or the IDE ROM's stale lines run in BANK0's place
  // (Windows 95's EMM386 /T hang: the IDE ROM's INT 1Bh entry ran on BANK0's stack frame).
  // The view is the select with bit 1 ignored while bit 0 is clear (0 and 2 show the same ROM).
  wire [1:0] d8_view_now  = pci_d8_select[0] ? pci_d8_select[1:0] : 2'b00;
  wire [1:0] d8_view_next = lane_wdata[0] ? lane_wdata[1:0] : 2'b00;
  wire d8_map_change = (hit[HX_063C]) && (d8_view_next != d8_view_now);
  wire mapping_flush_required = request_write &&
      (fw_map_change || ems_map_change || d8_map_change ||
       (hit[HX_0461]) && (win0_sel != next_win0) ||
       (hit[HX_043B]) && (sys16m_en != next_sys16m_en) ||
       ((hit[HX_053D]) &&
        ((ide_rom_enable != next_ide_from_gate) ||
         (bios_ram_gate  != next_bios_from_gate))));

  // 0x043F = 0xA0 is the 486 cache flush, not a bank select. The firmware
  // writes it immediately before every `mov cr0` (BANK7 offset 0x5F83;
  // BANK4 0x6020/0x6044, which also bracket a CR0.CD|NW change) and before its
  // RAM checks (BANK4 0x16B9/0x1779/0x1894/0x23A1). Nothing else in the 0xA
  // nibble is ever written.
  wire cache_flush_required = request_write && (hit[HX_043F]) &&
                              (lane_wdata == 8'hA0);
  wire flush_required = mapping_flush_required || cache_flush_required;

  // Every trigger above owes exactly ONE thing: a cache_flush_req pulse (see
  // flush_start's declaration). The core's whole-L1 walk (136 cycles) is a
  // superset of every range a trigger remaps, so every trigger is the same
  // pulse; tb_pc9821_cache_flush holds the trigger contract.

  // ==== THE FLUSH LAUNCH SITE: ONE REGISTER, EVERY TRIGGER ====
  // The I/O fabric's triggers (a bank/EMS/D8/window remap and the 0x043F=0xA0
  // guest flush) collapse to the ONE pulse below. The DMA side does not feed
  // this site: the uPD71071's accepted writes snoop the CPU's L1 per write
  // (the machine's EADS#, driven at the top level from dma_mem_addr/mem_we/
  // mem_ready), so a DMA/FDC completion is subsumed by its own writes and owes
  // no walk (T24): a whole-L1 walk holds the CPU for 136 clk_sys, the per-write
  // set-clear holds it for none and is strictly more faithful.
  // A trigger landing while no walk is COMMITTED launches one; a trigger landing
  // while one is committed (flush_start pulsing, or flush_busy walking) is COVERED
  // by that walk and needs no second one. What a flush owes is only "every line is
  // invalid when the CPU next looks, with no stale refill before that": l1_cache
  // and l1_icache hold cpu_ready low for the whole window from the request cycle to
  // the walk's end (z486's flush_block), so nothing refills during it and every set
  // is swept before it ends. The I/O family's trigger lands on the S_BYTE edge,
  // inside the covering walk's blocked window. R4's merge is structural: two
  // triggers in one cycle fold into the ONE pulse below.
  wire flush_trig  = (state == S_BYTE) && flush_required;
  wire flush_committed = flush_start || flush_busy;
  wire flush_launch = flush_trig & ~flush_committed;
  // The two DMA-side completion events are NOT coherency consumers (T24): the per-write DMA snoop at the top level covers
  // every byte, with or without a terminal count. The outputs stay connected so a
  // reader can see they were deliberately dropped rather than left dangling.
  /* verilator lint_off UNUSEDSIGNAL */  // retired T24, kept connected on purpose
  wire dma_mem_tc;    // pc9821_dmac's memory-side terminal count
  wire fdc_res_done;  // pc9821_fdc's command result drain
  /* verilator lint_on UNUSEDSIGNAL */
  always @(posedge clk) begin
    if (reset) flush_start <= 1'b0;
    else       flush_start <= flush_launch;
  end

  // ONE decode for every SYSTEM port this fabric knows. ONE bank of 109 match lines below, and
  // every consumer keys off those lines instead of re-comparing the address: the classifier is
  // one OR tree, and the read and write cases are `case (1'b1)` over the same one-hot lines.
  //
  // The DEVICE half is not here: pc9821_device_select owns that claim (dev_bus_cs), because the
  // same 85-port set also had to be split into chip selects by a second decode in the same file's
  // sibling, and two hand-kept lists drift. The instance at
  // the bottom of this file is that one decode; `device_port` is its claim.
  //
  // 109 bits is the system-port set. Order is ascending in pc9821_ports_pkg.sv.
  wire [108:0] hit;

  // The per-port comments below are carried verbatim from the two classifier plane
  // functions this decode replaced; each sits above the first port it named. The
  // ports are sorted (device then system) so a comment can appear above a different
  // member of the group it describes.
  // master/slave PIC
  // PREDECODE. The 109 match lines below are an equality of the 16-bit port with a distinct
  // constant; the constants share only 14 distinct high bytes and 82 distinct low bytes, so each
  // line is `hb_<high byte> && lb_<low byte>` over two shared byte compares instead of its own
  // 16-bit compare (module-alone, tools/res_exp_map.py with the FDC/mouse/DMAC around it: -36
  // ALMs, measured on the earlier 194-line form, before the device ports moved to
  // pc9821_device_select).
  // tools/check_iobus_hit_equiv.py proves every line equal to the full compare over all 65,536 ports.
  wire hb_00 = (port_addr[15:8] == 8'h00);
  wire hb_01 = (port_addr[15:8] == 8'h01);
  wire hb_04 = (port_addr[15:8] == 8'h04);
  wire hb_05 = (port_addr[15:8] == 8'h05);
  wire hb_06 = (port_addr[15:8] == 8'h06);
  wire hb_09 = (port_addr[15:8] == 8'h09);
  wire hb_0E = (port_addr[15:8] == 8'h0E);
  wire hb_0F = (port_addr[15:8] == 8'h0F);
  wire hb_18 = (port_addr[15:8] == 8'h18);
  wire hb_1E = (port_addr[15:8] == 8'h1E);
  wire hb_7F = (port_addr[15:8] == 8'h7F);
  wire hb_98 = (port_addr[15:8] == 8'h98);
  wire hb_A4 = (port_addr[15:8] == 8'hA4);
  wire hb_BF = (port_addr[15:8] == 8'hBF);
  wire lb_00 = (port_addr[7:0] == 8'h00);
  wire lb_01 = (port_addr[7:0] == 8'h01);
  wire lb_02 = (port_addr[7:0] == 8'h02);
  wire lb_03 = (port_addr[7:0] == 8'h03);
  wire lb_05 = (port_addr[7:0] == 8'h05);
  wire lb_07 = (port_addr[7:0] == 8'h07);
  wire lb_09 = (port_addr[7:0] == 8'h09);
  wire lb_0B = (port_addr[7:0] == 8'h0B);
  wire lb_0D = (port_addr[7:0] == 8'h0D);
  wire lb_0F = (port_addr[7:0] == 8'h0F);
  wire lb_10 = (port_addr[7:0] == 8'h10);
  wire lb_11 = (port_addr[7:0] == 8'h11);
  wire lb_19 = (port_addr[7:0] == 8'h19);
  wire lb_1B = (port_addr[7:0] == 8'h1B);
  wire lb_21 = (port_addr[7:0] == 8'h21);
  wire lb_23 = (port_addr[7:0] == 8'h23);
  wire lb_25 = (port_addr[7:0] == 8'h25);
  wire lb_27 = (port_addr[7:0] == 8'h27);
  wire lb_29 = (port_addr[7:0] == 8'h29);
  wire lb_30 = (port_addr[7:0] == 8'h30);
  wire lb_31 = (port_addr[7:0] == 8'h31);
  wire lb_32 = (port_addr[7:0] == 8'h32);
  wire lb_33 = (port_addr[7:0] == 8'h33);
  wire lb_34 = (port_addr[7:0] == 8'h34);
  wire lb_35 = (port_addr[7:0] == 8'h35);
  wire lb_36 = (port_addr[7:0] == 8'h36);
  wire lb_37 = (port_addr[7:0] == 8'h37);
  wire lb_39 = (port_addr[7:0] == 8'h39);
  wire lb_3B = (port_addr[7:0] == 8'h3B);
  wire lb_3C = (port_addr[7:0] == 8'h3C);
  wire lb_3D = (port_addr[7:0] == 8'h3D);
  wire lb_3E = (port_addr[7:0] == 8'h3E);
  wire lb_3F = (port_addr[7:0] == 8'h3F);
  wire lb_40 = (port_addr[7:0] == 8'h40);
  wire lb_42 = (port_addr[7:0] == 8'h42);
  wire lb_44 = (port_addr[7:0] == 8'h44);
  wire lb_49 = (port_addr[7:0] == 8'h49);
  wire lb_5C = (port_addr[7:0] == 8'h5C);
  wire lb_5D = (port_addr[7:0] == 8'h5D);
  wire lb_5E = (port_addr[7:0] == 8'h5E);
  wire lb_5F = (port_addr[7:0] == 8'h5F);
  wire lb_60 = (port_addr[7:0] == 8'h60);
  wire lb_61 = (port_addr[7:0] == 8'h61);
  wire lb_63 = (port_addr[7:0] == 8'h63);
  wire lb_67 = (port_addr[7:0] == 8'h67);
  wire lb_8E = (port_addr[7:0] == 8'h8E);
  wire lb_90 = (port_addr[7:0] == 8'h90);
  wire lb_92 = (port_addr[7:0] == 8'h92);
  wire lb_94 = (port_addr[7:0] == 8'h94);
  wire lb_A0 = (port_addr[7:0] == 8'hA0);
  wire lb_A1 = (port_addr[7:0] == 8'hA1);
  wire lb_A2 = (port_addr[7:0] == 8'hA2);
  wire lb_A3 = (port_addr[7:0] == 8'hA3);
  wire lb_A4 = (port_addr[7:0] == 8'hA4);
  wire lb_A5 = (port_addr[7:0] == 8'hA5);
  wire lb_A6 = (port_addr[7:0] == 8'hA6);
  wire lb_A7 = (port_addr[7:0] == 8'hA7);
  wire lb_A8 = (port_addr[7:0] == 8'hA8);
  wire lb_A9 = (port_addr[7:0] == 8'hA9);
  wire lb_AA = (port_addr[7:0] == 8'hAA);
  wire lb_AB = (port_addr[7:0] == 8'hAB);
  wire lb_AC = (port_addr[7:0] == 8'hAC);
  wire lb_AD = (port_addr[7:0] == 8'hAD);
  wire lb_AE = (port_addr[7:0] == 8'hAE);
  wire lb_AF = (port_addr[7:0] == 8'hAF);
  wire lb_BE = (port_addr[7:0] == 8'hBE);
  wire lb_BF = (port_addr[7:0] == 8'hBF);
  wire lb_C8 = (port_addr[7:0] == 8'hC8);
  wire lb_CA = (port_addr[7:0] == 8'hCA);
  wire lb_CC = (port_addr[7:0] == 8'hCC);
  wire lb_D7 = (port_addr[7:0] == 8'hD7);
  wire lb_D9 = (port_addr[7:0] == 8'hD9);
  wire lb_DB = (port_addr[7:0] == 8'hDB);
  wire lb_DD = (port_addr[7:0] == 8'hDD);
  wire lb_DF = (port_addr[7:0] == 8'hDF);
  wire lb_E0 = (port_addr[7:0] == 8'hE0);
  wire lb_F0 = (port_addr[7:0] == 8'hF0);
  wire lb_F1 = (port_addr[7:0] == 8'hF1);
  wire lb_F2 = (port_addr[7:0] == 8'hF2);
  wire lb_F3 = (port_addr[7:0] == 8'hF3);
  wire lb_F4 = (port_addr[7:0] == 8'hF4);
  wire lb_F6 = (port_addr[7:0] == 8'hF6);
  // uPD4990A/4993A calendar: command latch, mode latch, tick rate.
  // keyboard uPD8251A data/status
  // text GDC, mode, CRTC and palette
  // PIT channels/control
  // CG window: code high/low, line, pattern (0x56xx user CG RAM)
  // graphics display/access page select
  // PC-9801-86 sound: the base register-select/data pair (0x188/0x18A)
  // and the extension bank (0x18C/0x18E). They go through the device bus
  // so the OPNA gets its own chip select and, for reads, the one read
  // cycle a registered chip output needs.
  // PC-98 IDE connection/channel and task-file registers
  // The second channel's task file. The machine answers 0x740-0x74A
  // with the measured float (0x0F at each even register, 0xFF at each
  // odd partner: `0740 0F... 074A 0F`). They route to pc9821_ata, whose own float case answers the byte.
  // The PC-9801-118's game port, 0x1480-0x1487, which the card answers on all eight
  // addresses (NP2kai cbus/board118.c:816-822). They have to be claimed HERE or the
  // GDC's low-byte decode owns them; pc9821_device_select names the card's select.
  // The 0x3FD9..0x3FDF alias of the same four registers, which is the
  // only form the authentic ITF uses (BANK4@0x373 reads 0x3FDB).
  // The same card's OTHER device, the 86-PCM block (0xA462-0xA46E, the
  // even ports; the odd partners stay open bus as separate port values).
  // It has its own chip select, pc9821_system's pcm_cs, and answers its
  // registers in the strobe cycle. 0xA460 is NOT here: it is card-level
  // glue shared with the OPNA and stays a system port above.
  // The Roland MPU-PC98II, the C-bus MIDI card (pc9821_mpu), at the pair MMD.COM hard-codes:
  // +0 is the data register and +2 the status/command register (NP2kai cbus/mpu98ii.c:1177-1179
  // attaches exactly `port` and `port | 2`). The card is presented on the DEVICE bus, so these
  // two are device ports that pc9821_system routes, like the OPNA and the game port. MPU_EN 0
  // ties them off, which leaves the device half and the whole decode exactly as it was.
  assign hit[HX_0001] = (hb_00 && lb_01);
  assign hit[HX_0003] = (hb_00 && lb_03);
  assign hit[HX_0005] = (hb_00 && lb_05);
  assign hit[HX_0007] = (hb_00 && lb_07);
  assign hit[HX_0009] = (hb_00 && lb_09);
  assign hit[HX_000B] = (hb_00 && lb_0B);
  assign hit[HX_000D] = (hb_00 && lb_0D);
  assign hit[HX_000F] = (hb_00 && lb_0F);
  assign hit[HX_0011] = (hb_00 && lb_11);
  assign hit[HX_0019] = (hb_00 && lb_19);
  assign hit[HX_001B] = (hb_00 && lb_1B);
  assign hit[HX_0021] = (hb_00 && lb_21);
  assign hit[HX_0023] = (hb_00 && lb_23);
  assign hit[HX_0025] = (hb_00 && lb_25);
  assign hit[HX_0027] = (hb_00 && lb_27);
  assign hit[HX_0029] = (hb_00 && lb_29);
  assign hit[HX_0031] = (hb_00 && lb_31);
  assign hit[HX_0032] = (hb_00 && lb_32);
  assign hit[HX_0033] = (hb_00 && lb_33);
  assign hit[HX_0035] = (hb_00 && lb_35);
  assign hit[HX_0037] = (hb_00 && lb_37);
  // ports the machine answers and this core answered as open bus.
  // 0x0040 is the printer data port (`0040 00`).
  // 0x11/0x1B/0x21/0x23/0x25/0x27/0x29 are the uPD71071 DMA
  // controller's read ports; the engine is NOT modelled here, so the
  // read arms below answer the machine's measured strap bytes only.
  // These are telemetry entries too: the ITF writes 0x11/0x1B
  // (BANK4@0xFCA7F/0xFCA81).
  assign hit[HX_0040] = (hb_00 && lb_40);
  assign hit[HX_0042] = (hb_00 && lb_42);
  assign hit[HX_0044] = (hb_00 && lb_44);
  assign hit[HX_005C] = (hb_00 && lb_5C);
  assign hit[HX_005D] = (hb_00 && lb_5D);
  assign hit[HX_005E] = (hb_00 && lb_5E);
  assign hit[HX_005F] = (hb_00 && lb_5F);
  // Present-but-unimplemented devices, answered explicitly rather than
  // by open bus so a guest probe gets an honest "absent" and fails fast.
  assign hit[HX_0090] = (hb_00 && lb_90);
  assign hit[HX_0092] = (hb_00 && lb_92);
  assign hit[HX_0094] = (hb_00 && lb_94);
  // Devices the authentic ITF drives that this fabric does not model. Decoded so
  // their traffic stops appearing in the unmapped-port telemetry (the watchdog's
  // U= field). Every one is write-only or unread in every reference, and only
  // 0xA7 has a machine-measured read; the read arms return those values and leave
  // the rest on the open bus, so a guest sees the same byte either way.
  //   0x00A7   the CG-ROM block's slot between 0xA5 and 0xA9 ("kanji rom")
  //   0x7FD9.. the bus mouse's uPD8255 PPI, and its timer port 0xBFDB
  //   0x0E00.. the DMA controller's extended "high page" bank registers
  //   0x0FAA.. the two-stage accelerator control pair and its display relay
  assign hit[HX_00A7] = (hb_00 && lb_A7);
  // The FDC's channel-group (2HD/2DD media) register at 0x00BE/0x00BF (NP2kai
  // fdc_obe/fdc_ibe, io/fdc.c:1096-1114): same class as the 0x04BE RPM register
  // above, routed to the same pc9821_fdc instance. DOS's FDD driver reads the
  // media strap here.
  // NP2kai attaches the pair wide (its 0x0cff mask); the decode stays exact,
  // aliases unmeasured on this machine.
  assign hit[HX_00BE] = (hb_00 && lb_BE);
  assign hit[HX_00BF] = (hb_00 && lb_BF);
  // The FDC's SECOND port window, 0xC8/0xCA/0xCC: the same uPD765 register file
  // (0 = MSR, 1 = data, 2 = DOR) reached through the door the 0x00BE strap selects.
  // NP2kai binds the SAME handler table at 0x0090 and 0x00C8 with the 0x00f9 mask
  // (fdc_bind, io/fdc.c:1162-1171), so (port >> 1) & 3 indexes the register in
  // either bank; qemu-pc98's one FDCtrl has `case 0x90` and `case 0xc8` as adjacent
  // arms of one switch (hw/block/pc98-fdc.c:2808-2818) and registers DMA ch2 AND
  // ch3 to the same transfer handler (:2986-2987); MAME maps one upd765a_device at
  // both windows (pc9821.cpp:725,732) under its own `// TODO: should really be one
  // FDC` (pc9801.h:162). The register index below is unchanged for both windows
  // because 0xC8 >> 1 == 0x90 >> 1 in bits 2:1. See the fdc_cs/fdc instance below
  // for the strap gate that decides which window answers.
  assign hit[HX_00C8] = (hb_00 && lb_C8);
  assign hit[HX_00CA] = (hb_00 && lb_CA);
  assign hit[HX_00CC] = (hb_00 && lb_CC);
  assign hit[HX_00F0] = (hb_00 && lb_F0);
  assign hit[HX_00F1] = (hb_00 && lb_F1);
  assign hit[HX_00F2] = (hb_00 && lb_F2);
  assign hit[HX_00F4] = (hb_00 && lb_F4);
  assign hit[HX_00F6] = (hb_00 && lb_F6);
  assign hit[HX_0134] = (hb_01 && lb_34);
  assign hit[HX_0149] = (hb_01 && lb_49);
  assign hit[HX_0434] = (hb_04 && lb_34);
  assign hit[HX_0436] = (hb_04 && lb_36);
  assign hit[HX_0439] = (hb_04 && lb_39);
  assign hit[HX_043B] = (hb_04 && lb_3B);
  assign hit[HX_043D] = (hb_04 && lb_3D);
  assign hit[HX_043F] = (hb_04 && lb_3F);
  assign hit[HX_0461] = (hb_04 && lb_61);
  assign hit[HX_0463] = (hb_04 && lb_63);
  // The EGC register file, 0x04A0-0x04AE. It is NOT a device port: the
  // device fabric routes 0x04A0/0x04A2 to pc9821_gdc_text on the low byte
  // alone (0xA0/0xA2 = the GDC2 status), so a device-port decode would
  // answer the GDC2 status byte there instead of the machine's 0xFF. The
  // ports are decoded here, their writes latch below, and their reads are
  // the measured open bus.
  assign hit[HX_04A0] = (hb_04 && lb_A0);
  assign hit[HX_04A1] = (hb_04 && lb_A1);
  assign hit[HX_04A2] = (hb_04 && lb_A2);
  assign hit[HX_04A3] = (hb_04 && lb_A3);
  assign hit[HX_04A4] = (hb_04 && lb_A4);
  assign hit[HX_04A5] = (hb_04 && lb_A5);
  assign hit[HX_04A6] = (hb_04 && lb_A6);
  assign hit[HX_04A7] = (hb_04 && lb_A7);
  assign hit[HX_04A8] = (hb_04 && lb_A8);
  assign hit[HX_04A9] = (hb_04 && lb_A9);
  assign hit[HX_04AA] = (hb_04 && lb_AA);
  assign hit[HX_04AB] = (hb_04 && lb_AB);
  assign hit[HX_04AC] = (hb_04 && lb_AC);
  assign hit[HX_04AD] = (hb_04 && lb_AD);
  assign hit[HX_04AE] = (hb_04 && lb_AE);
  assign hit[HX_04AF] = (hb_04 && lb_AF);
  // The FDC's 1.44M/RPM register (NP2kai io/fdc.c:1117-1134, fdc_o4be/fdc_i4be;
  // support144 = 1 on every PC-9821, so the Xe10's 1.44M FDD has it). It rides the
  // pc9821_fdc instance below with the rest of the controller's ports. NP2kai attaches
  // 0x00BE wide (aliases unmeasured on this machine, so the decode stays exact).
  assign hit[HX_04BE] = (hb_04 && lb_BE);
  assign hit[HX_0530] = (hb_05 && lb_30);
  assign hit[HX_0531] = (hb_05 && lb_31);
  assign hit[HX_0534] = (hb_05 && lb_34);
  assign hit[HX_053D] = (hb_05 && lb_3D);
  assign hit[HX_053E] = (hb_05 && lb_3E);
  // 0x0567: the ITF writes it seven times (BANK4 offsets 0xA7A, 0xB1F, 0xB31, 0x125F,
  // 0x142E, 0x14AD, 0x23F2, each `out dx,al`) and NEVER reads it back, and no reference gives
  // the port any readable state, so the read is the open bus 0xFF and the write is dropped.
  // CAPTURE-PENDING in both directions: no machine value exists (the PORTS presence scan's
  // list is derived from this core's own decode, so it cannot see a port the core does not
  // claim -- audit-iobus F11/F12). A read at 0x567 is the one-access measurement that settles
  // it; writing it is not needed to find out whether anything answers.
  assign hit[HX_0567] = (hb_05 && lb_67);
  assign hit[HX_0610] = (hb_06 && lb_10);
  // Real ports this firmware writes that are not modelled. They are
  // decoded only so they stop incrementing unmapped_writes/
  // unmapped_reads, which are the boot-stop telemetry: 0x610 alone is
  // written 33 times by the ITF (BANK4 offset 0x167 onward).
  // 0x0611 is the other one with NO arm at all (0x610 at least latches the ITF's watchdog
  // stage): no reference and no firmware site gives it anything, so it reads open bus 0xFF and
  // its write is dropped. Like 0x567 it is CAPTURE-PENDING in both directions.
  assign hit[HX_0611] = (hb_06 && lb_11);
  assign hit[HX_063C] = (hb_06 && lb_3C);
  assign hit[HX_063D] = (hb_06 && lb_3D);
  assign hit[HX_063E] = (hb_06 && lb_3E);
  assign hit[HX_063F] = (hb_06 && lb_3F);
  assign hit[HX_09A0] = (hb_09 && lb_A0);
  assign hit[HX_09A8] = (hb_09 && lb_A8);
  assign hit[HX_09AE] = (hb_09 && lb_AE);
  assign hit[HX_0E00] = (hb_0E && lb_00);
  assign hit[HX_0E02] = (hb_0E && lb_02);
  assign hit[HX_0E05] = (hb_0E && lb_05);
  assign hit[HX_0E07] = (hb_0E && lb_07);
  assign hit[HX_0E09] = (hb_0E && lb_09);
  assign hit[HX_0E0B] = (hb_0E && lb_0B);
  assign hit[HX_0E0F] = (hb_0E && lb_0F);
  assign hit[HX_0EE0] = (hb_0E && lb_E0);
  assign hit[HX_0FAA] = (hb_0F && lb_AA);
  assign hit[HX_0FAB] = (hb_0F && lb_AB);
  assign hit[HX_0FAC] = (hb_0F && lb_AC);
  // The 0x18F0/0x18F2 pair (see the declaration). System ports, not
  // device ports: the device fabric would answer 0x18F2 with the GDC's
  // low-byte route and the pair would never reach its own arms.
  assign hit[HX_18F0] = (hb_18 && lb_F0);
  assign hit[HX_18F1] = (hb_18 && lb_F1);
  assign hit[HX_18F2] = (hb_18 && lb_F2);
  assign hit[HX_18F3] = (hb_18 && lb_F3);
  assign hit[HX_1E8E] = (hb_1E && lb_8E);
  assign hit[HX_7FD9] = (hb_7F && lb_D9);
  assign hit[HX_7FDB] = (hb_7F && lb_DB);
  assign hit[HX_7FDD] = (hb_7F && lb_DD);
  assign hit[HX_7FDF] = (hb_7F && lb_DF);
  // The ITF reads 0x9894 at BANK4@0xFCAED (bit 3) and reads/writes
  // 0x9892 beside it. 0x98E0 is deliberately NOT decoded: the machine
  // reads open bus there (/MODE), and the ITF's only
  // write to it (BANK4@0xFCB01) is unmapped traffic that names the
  // fatal branch on the deployed build's telemetry.
  assign hit[HX_9892] = (hb_98 && lb_92);
  assign hit[HX_9894] = (hb_98 && lb_94);
  assign hit[HX_98D7] = (hb_98 && lb_D7);
  // 0xA460 is the -86's extend/ID register: card-level glue both devices
  // depend on. Bit 0 is the extension enable (exported as sound_extend,
  // which opens the OPNA's 0x18C/0x18E bank and switches it 3ch/mono <->
  // 6ch/stereo); bits 6:4 are the board's read-only sound-ID strap. The
  // read answers 0x40 | bit 0, because 0x40 is the -86's ID in both
  // references (NP2kai cbus/pcm86io.c, qemu-pc98 PC98_OPNA_SOUND_ID) and a
  // write moves bit 0 ALONE -- so the ITF's write-back reads 0x41, not
  // 0x73. What the machine itself ANSWERS is UNMEASURED.
  assign hit[HX_A460] = (hb_A4 && lb_60);
  assign hit[HX_BFDB] = (hb_BF && lb_DB);

  // ---------------- Software DIP switches: 0x8F1F control, 0x841E-0x8F1E data
  // One byte per port, addressed by the port's high nibble (0x84..0x8F), stored only
  // while bit 7 of the control port is set: 0x80 opens the bank and 0xC0 latches it
  // (itf.S sdip_init), so only 0x80 or 0x00 leave it writable.
  //
  // Battery-backed, so a real machine comes up holding what SETUP last stored, and
  // the ITF validates that image before it draws anything -- it prints "SET THE
  // SOFTWARE DIP-SWITCH" and stops. The power-up values are READ OFF THE MACHINE
  // bank A is 7C 02 76 3E 7C 7F FF BF 7F 7F 49 98, with 0x84 the
  // configuration byte whose low nibble is the memory size and 0x8E/0x8F its checksum.
  // 0x043B bit 2 is the hole's REQUEST, inverted: SET = RAM at 15-16 MiB, CLEAR = the hole.
  // NP2kai issue #107 prints exactly that (bit 2 set = "Memory hole at 15-16MB not enabled") and
  // qemu keys the same bit inverted (`enable = !(data & 0x04)`, pc98-mem.c mem_sys16m_write).
  // The firmware writes it at five sites (BANK4 offsets 0x0906/0x1263/0x1416/0x1492/0x2456:
  // 0x04, 0x00, 0x00, ah|0x04, 0x04), so the state is the guest's decision.
  reg sys16m_en_q;
  assign sys16m_en = sys16m_en_q;

  // 0x534: the cold/warm + soft-reset latch. The read is the CPU-mode strap
  // (0xEC, bit 0 clear); writing bit 0 asks for a soft reset. BANK4@0x2574
  // reads, flips bit 0 and writes it back, then executes hlt with NO trampoline
  // at all, so a dropped write is an unrecoverable hang.
  reg [7:0] cpu_mode_strap;

  // Port 0x9894 is a STRAP, not a latch.
  // Only bit 3 is a contract and it must be CLEAR: BANK4@0xFCAED
  // continues the POST only while it is clear, and bit 3 set diverts into the clock
  // reprogram and `out 0xF0,0`. BANK7@0xFD867 forwards the same bit as a reset
  // operand that no reference consumes. The machine reads 0xF0 with bit 3 clear,
  // stably, at a DOS prompt (/MODE), and the ITF's own writes to
  // 0x9894 do not move that read. 0x98E0 stays undecoded for the same reason: open bus.
  // Straps and latches, seeded with the MEASURED machine values
  // (0x436=0x04, 0x439=0xB4, 0x63D=0xEC, 0x63F=0x6C, 0x149=0x00).
  // The firmware read-modify-writes all but the last and branches on 0x63D bit 6, so
  // a constant would corrupt every one of them: on 0x63D the machine reads 0xEC where
  // QEMU returns 0x04, and bit 6, which BANK4@0x1901/0x2383/0x41D6 test, is 1 only
  // for 0xEC. 0x461 is NOT in that list: every `mov dx,0x0461` site is followed by
  // `mov al,imm / out dx,al`, so the firmware only ever WRITES it, and its read-back
  // (value | 1) is a contract for a guest rather than for the ROM.
  reg [7:0] config_436, config_439, config_63f, latch_149;
  // Memory-switch register file: port 0x530 is the address latch, 0x531 the data
  // byte at that address. Contract: write<addr> to 0x530 selects a register;
  // read/write<data> at 0x531 acts on the selected register; read of 0x530
  // returns the selected address. Power-up content is 0x00 (the file is
  // uninitialised on the machine until firmware writes it).
  //
  // It is a LATCH, not a strap: the firmware programmes it before it reads it
  // (BANK4@0x9211/0x8C12/0x9146 write the address to 0x530 and data to 0x531,
  // then BANK4@0x8DC8 reads 0x531 back and stores the result into the user-CG
  // store), so the loop closes on the firmware's own writes with no measurement.
  // The extended-memory size that block walks against comes from a *different* CG
  // page (code 0x7157 row 0x27), so this file models the pair correctly but is not
  // by itself the memory-size gate. A real machine's
  // resting value on the pair is UNMEASURED and the probe never writes it.
  reg [7:0] msw_addr;
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] msw_reg [0:255];
  // Power-up contents only, via INIT. A synchronous reset loop over the array
  // would force it into 2,048 flip-flops instead of one RAM block (measured: the
  // reset form cost +2,104 registers and moved LABs from 93.9% to 95.2%).
  // The machine's resting value on the pair is unmeasured, so 0x00 is the
  // honest blank, matching an uninitialised CG RAM.
  initial begin : msw_init
    integer j;
    msw_addr = 8'h00;
    for (j = 0; j < 256; j = j + 1) msw_reg[j] = 8'h00;
    msw_79_written = 1'b0;
  end

  // Simple dual port: this write port and a separately registered read port. The
  // register-array form fell out of RAM inference into 2,048 flip-flops on 17.0.2 and
  // nearly doubled the entity, and inference needs the read registered. M10K
  // not MLAB: this design is LAB-bound, so an MLAB form's 10 LABs are the wrong trade.
  // msw_addr moves only on a 0x530 write, cycles before any 0x531 read, so msw_rdata
  // already holds the addressed byte at the S_BYTE edge that latches lane_rdata.
  reg [7:0] msw_rdata;
  always @(posedge clk) begin
    if ((state == S_BYTE) && request_write && (hit[HX_0531]))
      msw_reg[msw_addr] <= lane_wdata;
    msw_rdata <= msw_reg[msw_addr];
  end

  // THE ONE CELL OF THE FILE ANYONE HAS MEASURED. The read-only /MEMSW probe left the pair
  // holding address 0x79 with data 0x1E, and 0x1E = 30 is the EXTENDED size that same
  // machine's own POST reports (+30720KB on a 32 MiB machine: 32 total - 1 MiB of base -
  // 0.625 MiB of low memory). So cell 0x79 is the machine's stored extended size in MiB, and
  // the array above cannot hold it because the array is blank on this core by design.
  // It is a READ fallback, not a write: the cell keeps whatever it is here until the guest
  // writes that address itself, at which point the guest wins for good. THE OTHER 255 CELLS
  // ARE UNMEASURED and nothing is invented for them.
  //
  // THE STRAP IS THE TOTAL-MINUS-2 INVERSE OF THAT MEASUREMENT (the recorded
  // derivation: `msw_reg[0x79] = miB - 2`), saturated at 0 below 2 MiB where the subtraction
  // has no meaning. Both readings of the machine's own arithmetic agree on every size the OSD
  // can select: 32 total - 1.625 MiB truncates to 14 at 16 MiB, exactly as 16 - 2 does, and at
  // 32 MiB both give the measured 0x1E. The pre-fix form - (miB >= 18) ? miB - 2 : 0 - was an
  // UNSOURCED threshold contradicting that derivation's own stated inverse (the commit shipped both at
  // once): it answered 0x00 = "0 MiB extended" at every guest below 18 MiB, including the 16
  // MiB OSD default, where the machine's rule says 0x0E = 14. tb_pc9821_iobus pins both sides
  // (0x0E at 16 MiB, the measured 0x1E at 32 MiB, and the guest write winning afterwards).
  // FALSIFIER, named for the next reader: only the 32 MiB value is machine-measured; if a
  // /MEMSW read of cell 0x79 on a machine configured at a different size shows 0x00 below
  // 18 MiB, this line reverses back to the threshold.
  // The strap's OSD source is SAMPLED AT MACHINE RESET ONLY (cfg_ram_mib_eff, the same
  // strobe bios_set_eff/gdc_strap_eff latch on): a memory-switch cell must not move under
  // the running firmware when the OSD's RAM Size field changes mid-run.
  reg        msw_79_written;
  /* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
  reg  [6:0] cfg_ram_mib_eff = 7'd16;
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) begin
    if (reset) cfg_ram_mib_eff <= cfg_ram_mib;
  end
  wire [7:0] msw_79_strap = (cfg_ram_mib_eff > 7'd2) ? ({1'b0, cfg_ram_mib_eff} - 8'd2) : 8'h00;


  // 0x18F0/0x18F2: the pair the authentic ITF drives immediately before its
  // stage-0x1B VRAM fill and READS BACK at BANK4@0x054A6. THE INTERFACE IS FORCED BY
  // THE FIRMWARE, NOT INVENTED: the routine at BANK4@0x5460 writes four words to
  // 0x18F2, re-selects 0x18F0, then reads four words back from the beginning into the
  // CG store. So writing 0x18F0 RESETS the pointer, 0x18F2 RETURNS WHAT WAS WRITTEN
  // (anything else changes the pixels), and the accesses are WORD-wide, so 0x18F3 is
  // the upper half.
  //
  // The SHAPE is NP2kai's (io/pcidev.c:303-321) -- but its row wraps at 4, giving four
  // bytes per select where this routine writes eight, so that part is disproved by the
  // dump; its author marked the port "mysterious" and disabled all four attach calls.
  // LIMITS: one linear 64-byte buffer, unk_sel recorded but NOT banking it, and reads
  // with no prior write unknown. /XP18F settles the last two.
  reg  [7:0] unk_sel;                  // 0x18F0's select, also its read-back
  reg  [5:0] unk_ptr;                  // byte pointer into the window
  (* ramstyle = "M10K" *) reg [7:0] unk_win [0:63];
  wire       unk_port = (hit[HX_18F2]) || (hit[HX_18F3]);
  initial begin : unk_init
    integer j;
    unk_sel = 8'h00;
    unk_ptr = 6'd0;
    for (j = 0; j < 64; j = j + 1) unk_win[j] = 8'h00;
  end

  // Simple dual port with the read registered, as for msw_reg above; 17.0.2 named this
  // array "uninferred due to asynchronous read logic". The pointer advances one
  // byte on EVERY access, so the registered read must address the byte live at the next
  // edge -- unk_ptr + 1 while this S_BYTE advances it -- which is what reads a word's two
  // bytes back in order across consecutive S_BYTE cycles. The read index is masked to the
  // array's 64 entries: at unk_ptr == 63 the +1 would address unk_win[64], one past the end
  // (the firmware re-selects 0x18F0 every eight bytes and never wraps, but a >64-byte walk
  // must fetch a defined byte, not X).
  reg [7:0] unk_rdata;
  always @(posedge clk) begin
    if ((state == S_BYTE) && request_write && unk_port)
      unk_win[unk_ptr] <= lane_wdata;
    unk_rdata <= unk_win[(unk_ptr + ((state == S_BYTE && unk_port) ? 6'd1 : 6'd0)) & 6'h3F];
  end

  // 0x0463, window 1 at 0xA0000-0xBFFFF: a latch with NO mapping effect. Measured
  // every value written leaves 0xA0000-0xBFFFF exactly as it
  // was, while the register reads back (value | 1) like 0x0461. No firmware bank
  // in 160 KiB writes the port. Reset 0x0A is QEMU's, confirmed by the measured
  // first touch 0x463 = 0x0B. Its stored byte has no consumer, so only the
  // read-back is a contract.
  reg [7:0] win1_sel;
  // The ITF writes a unique per-stage code to 0x610 at each POST stage
  // (BANK4@0x61..0x2329, values 0x01..0x2B). Write-only on the machine; latching
  // it turns the watchdog's U= field into an exact "where did the ITF stop".
  // (The register itself is declared beside dbg_itf_stage, its only reader.)

  // ------------------------------------------------------------------ the uPD71071
  // THE DMA CONTROLLER IS pc9821_dmac, NOT A REGISTER STUB HERE. The
  // register window 0x01..0x29 (odd) is this file's decode and the whole register file,
  // the byte flip-flop, the transfer engine and the TC/DACK contract live in that module,
  // which is instantiated below: the eight self-test bytes at 0x01..0x0F, the 0x11 status
  // latch, the 0x19 clear-byte-pointer arm, the 0x1B master clear, the four 0x21..0x27 bank
  // latches (the capture-proven low nibble) and the 0x29 bound selector are that module's
  // state, and tb_pc9821_dma_regs drives their sequences THROUGH this file against it.
  //
  // THE REGISTER INDEX IS (port - 1) >> 1, the 8237/uPD71071 window's own layout: 0x01/0x03
  // are channel 0's address and count, 0x05..0x0F channels 1..3, 0x11/0x13 the status and
  // software-request registers, 0x15 the single mask, 0x17 the mode, 0x19/0x1B the clear
  // flip-flop and master clear, 0x1D/0x1F the mask commands, 0x21..0x27 the bank bytes and
  // 0x29 the bound selector. The ITF and the disk BIOS write 0x15 and 0x17 (BANK4.BIN:0x664F,
  // BIOS.ROM:0x17A69), so those ports must be decoded, not accepted and dropped.
  wire       dma_port = (port_addr <= 16'h0029) && port_addr[0];
  wire [4:0] dma_idx  = port_addr[5:1];
  wire       dma_sel  = (state == S_BYTE) && dma_port;
  // The fabric captures its read byte IN the access cycle, so it takes the engine's
  // COMBINATIONAL port rather than its registered one: the registered byte is presented at
  // the end of the access, and the access's own side effects (the address/count flip-flop and
  // the 0x11 terminal-count clear) commit at that same edge, so a same-cycle reader must see
  // the value BEFORE it. This keeps the port's access class at the FSM floor.
  wire [7:0] dma_reg_dout;
  /* verilator lint_off UNUSEDSIGNAL */   // DACK bits 0/1 have no consumer (no device sits on
  // channels 0/1). The MEMORY-TO-DEVICE legs (dev_we, dev_dout) are the FDC's WRITE DATA bytes,
  // and DACK bits 2 and 3 are the FDC's too: its strap picks between them.
  wire [3:0] dma_dev_dack;
  wire       dma_dev_we, dma_dev_stb, dma_dev_tc;
  wire [1:0] dma_dev_ch;
  wire [7:0] dma_dev_dout;
  /* verilator lint_on UNUSEDSIGNAL */
  wire       fdc_drq;
  wire [7:0] fdc_dma_out;
  wire       fdc_irq_raw;
  wire       fdc_strap_2hd;    // pc9821_fdc's chgreg bit 0: 1 = the 2HD window is selected
  wire       fdc_drq_ch2 = fdc_drq & fdc_strap_2hd;
  wire       fdc_drq_ch3 = fdc_drq & ~fdc_strap_2hd;
  wire [1:0] fdc_dma_ch  = fdc_strap_2hd ? 2'd2 : 2'd3;

  pc9821_dmac u_dma (
      .clk(clk), .reset(reset),
      .sel(dma_sel), .write(request_write), .idx(dma_idx), .din(lane_wdata),
      // The registered byte is left open ON PURPOSE: this fabric takes the combinational
      // one (see dma_reg_dout), and the registered port exists for the engine's own benches,
      // which sample a device register a cycle after the access.
      /* verilator lint_off PINCONNECTEMPTY */
      .dout(), .dout_comb(dma_reg_dout),
      /* verilator lint_on PINCONNECTEMPTY */
      // The one device consumer this phase has: the FDC, whose STRAP picks the
      // channel. Channel 2 is the 2HD interface and channel 3 the 2DD one --
      // NP2kai FDC_DMACH2HD = 2 / FDC_DMACH2DD = 3 (io/fdc.c:22-27), attached by
      // the one fdc_reset and chosen per event by fdc_dmaready (:85-92) from
      // `chgreg & 1`; the machine's own firmware programs ch2 or ch3 from the same
      // bit (ITF 0x14B3: 0x19/0x17/0x23/0x09/0x0B/0x15,0x02 for the 2HD window,
      // 0x19/0x17/0x25/0x0D/0x0F/0x15,0x03 for the 2DD one); qemu registers BOTH
      // channels to the same transfer handler. Only the selected channel's DRQ is
      // raised, so the other engine never sees this device.
      .dev_drq({fdc_drq_ch3, fdc_drq_ch2, 2'b00}),
      .dev_dack(dma_dev_dack), .dev_we(dma_dev_we), .dev_stb(dma_dev_stb),
      .dev_tc(dma_dev_tc), .dev_ch(dma_dev_ch), .dev_dout(dma_dev_dout),
      .dev_din(fdc_dma_out),
      .mem_addr(dma_mem_addr), .mem_gvwin(dma_mem_gvwin), .mem_we(dma_mem_we), .mem_be(dma_mem_be),
      .mem_din(dma_mem_din), .mem_dout(dma_mem_dout), .mem_req(dma_mem_req),
      .mem_ready(dma_mem_ready), .mem_resp_valid(dma_mem_resp_valid),
      // mem_tc stays connected to its unused wire (see the flush launch site):
      // the coherency consumer moved to the per-write snoop (T24).
      .mem_tc(dma_mem_tc)
  );

  // ARTIC free-running timestamp counter, 0x5C..0x5F. 32 bits at 307200 Hz (QEMU
  // pc98-sys.c TIMESTAMP_HZ and NP2kai artic.c agree).
  //
  // BYTE LAYOUT: 0x5C=[7:0], 0x5D=[15:8], 0x5E MIRRORS 0x5D (both cnt[15:8]), 0x5F=[23:16].
  // NP2kai settles it (io/artic.c artic_bind attaches 0x5D and 0x5E to the same handler,
  // `(UINT8)(cnt >> 8)`, and artic_r16 shifts `cnt >>= 8` for `port & 2`), and the machine
  // reads 0x5E equal to 0x5D or one ahead (a tick lands between the two byte reads).
  //
  // The firmware uses it as a time base (BANK3@0xB16 delay(cx), called from the ATA
  // soft reset, and the BANK7@0x6DFD/0x6E53/0x0E11 timeouts); open bus returns at once.
  localparam [31:0] ARTIC_HZ = 32'd307200;
  // The ARTIC counter is the time base for every firmware delay(). Its rate has ONE home: the
  // system clock, passed down from pc9821_system.SYS_FREQ exactly as the OPNA, PCM86 and
  // interrupt peers receive it. A second, un-overridable home here would leave the base profile
  // correct while mis-timing every delay under the debug and production clock profiles.
  // The rate is the DEVICE's 307200 Hz against that clock, and the two share a large common
  // factor (3200 at 50 MHz: 307200 = 2^12*3*5^2, 50000000 = 2^7*5^8), so the phase needs only
  // MOD states: dividing sum = phase + ARTIC_HZ and tick = sum >= SYS_CLOCK_HZ by G is EXACT,
  // so the tick SEQUENCE is identical at every clock profile rather than merely on average and
  // the guest-visible artic_cnt does not move. pc9821_pit.sv:75 (`A 14-bit accumulator replaces the 33-bit`)
  // is the same transform on the 2.4576 MHz source.
  function automatic integer artic_gcd(input integer a, input integer b);
    integer t;
    begin
      while (b != 0) begin t = b; b = a % b; a = t; end
      artic_gcd = a;
    end
  endfunction
  localparam integer ARTIC_GCD = artic_gcd(ARTIC_HZ, SYS_CLOCK_HZ);
  localparam integer ARTIC_INC = ARTIC_HZ / ARTIC_GCD;       // 96 at 50 MHz, 48 at 100 MHz
  localparam integer ARTIC_MOD = SYS_CLOCK_HZ / ARTIC_GCD;   // 15625 at 50 MHz
  localparam integer ARTIC_W   = $clog2(ARTIC_MOD + 1);      // 14 at 50 MHz
  reg  [ARTIC_W-1:0] artic_phase;
  reg  [31:0]        artic_cnt;
  wire [ARTIC_W:0]   artic_sum  = {1'b0, artic_phase} + ARTIC_INC[ARTIC_W-1:0];
  wire               artic_tick = (artic_sum >= ARTIC_MOD[ARTIC_W:0]);
  // The wrapped phase, read only on a tick, so the truncated subtract's low ARTIC_W bits are
  // the exact difference (the borrow bit is not taken - the comparator above already decided).
  wire [ARTIC_W-1:0] artic_wrap = artic_sum[ARTIC_W-1:0] - ARTIC_MOD[ARTIC_W-1:0];
  // ONE SNAPSHOT PER ACCESS. The lane walk reads a word/dword's bytes in successive S_BYTE
  // cycles, so a tick between them that carried out of a byte tore the value: `in ax,5Eh` at
  // cnt = 0x00FFFF read 0x01FF, 65,536 ticks (213 ms) ahead, and a firmware delay() spinning
  // on `now - start` exited early. Both references take one counter value per access (NP2kai
  // io/artic.c artic_r16: `cnt = artic_getcnt(); if (port & 2) cnt >>= 8;`; MAME pc9801.cpp
  // timestamp_r). A tick that lands while an access to the 0x5C-0x5F dword is in flight is
  // DEFERRED (SCED R7) to the cycle the access ends, so the counter's rate is unchanged: an
  // I/O access is far shorter than the 3.26 us tick period, so one pending tick suffices
  // (asserted below). tb_pc9821_artic_atomic.
  wire artic_freeze = (state != S_IDLE) && (base_addr[15:2] == 14'h0017);
  reg  artic_pend;

  /* verilator lint_off UNUSEDSIGNAL */   // the machine's register is 8 bits; only bit 7
  reg [7:0] sdip_ctrl;   // (access enable) and bit 6 (bank select) are defined, and they are the ones read (sdip_writable, sdip_bank_index)
  /* verilator lint_on UNUSEDSIGNAL */
  // Bit 7 is the access enable; bit 6 is the BANK SELECT, not a write-protect.
  // The authentic ITF writes real data with 0xC0 selected in three independent
  // places (BANK4 offsets 0x47A and 0x7E9, BANK3 0x2A8F) and reads bank B
  // through the same control (BANK3 0x2E9), so `!ctrl[6]` made the device
  // unwritable exactly where the firmware writes it.
  wire sdip_writable = SDIP_WRITES_ENABLED && sdip_ctrl[7];
  // Two banks of twelve bytes: the ITF writes 12 bytes under 0x80 and 12 more
  // under 0xC0 (BANK4 offsets 0x44E and 0x47A) and verifies both -- odd parity
  // on bank A idx 0..4 and 7..11, an XOR pair on idx 5/6, odd parity on bank B
  // idx 0..9 (BANK4 offsets 0x6BA-0x726).
  // A BLOCK MEMORY, not 192 flops, for the same reason msw_reg above is one: this design is
  // LAB-bound and only the flop form pays. Measured (tools/res_exp_map.py, the shape alone):
  // the asynchronous-read flop form is 289 ALMs / 376 combinational ALUTs / 192 registers,
  // the clocked-read form 11 ALMs / 20 ALUTs / 2 registers -- the array is 192 bits of pure
  // guest data (the fit's own stuck-port accounting finds NO constant bit in it, unlike the
  // flush packet's 250 declared registers, 146 of which were tied to GND). M10K rather than
  // MLAB, again as msw_reg: one M10K block costs no logic ALMs, while the MLAB form holds a
  // whole LAB (10 ALMs) for 192 bits.
  //
  // THE READ REGISTER IS THE ONE THING THIS CHANGES, and it is not a guest-visible one:
  // `sdip_q` holds the byte at `sdip_bank_index` as of the PREVIOUS clk, and that is the byte
  // every access wants, because the read index is a function of port_addr[11:8] and
  // sdip_ctrl[6] alone -- both fixed from S_IOWAIT through every S_BYTE of an access (the lane
  // walk moves only port_addr[1:0], and 0x..1E-0x..21 cannot cross a 0x100 boundary). The
  // minimum class hold is IO_MIN_HOLD = 4 clk, so S_BYTE is never the cycle after S_IDLE and
  // the registered byte has always settled by the capture. Nothing reads the array
  // combinationally: the read arm reads `sdip_q`, and beep_vol is fed by the
  // per-bank `sdip_vol_a`/`sdip_vol_b` mirrors below rather than by a same-cycle array read.
  (* ramstyle = "M10K" *) reg [7:0] sdip[0:23];
  reg  [7:0] sdip_q;

  // Power-up image via initial, matching msw_reg. Eliminates 192
  // synchronous resets and 24-way parallel muxes.
  initial begin : sdip_init
    // The index is 5 bits, not an integer. sdip is a 24-entry array and sdip_powerup
    // takes a 5-bit index, so an integer loop variable truncated silently at the call.
    reg [4:0] j;
    for (j = 0; j < 5'd24; j = j + 1) sdip[j] = sdip_powerup(j);
  end

  // CONSEQUENCE OF THE READ REGISTER: beep_vol is a SAME-CYCLE consumer of the store -- the
  // amplitude the speaker mixes in the very cycle the 0x871E write lands -- so it gets a
  // shadow rather than waiting for the read register. It is loaded from the byte the write
  // port stored, in the same cycle, so it cannot disagree with the read-back. BOTH banks'
  // images are mirrored and SELECTED by sdip_ctrl[6], the same as reading the selected bank's
  // byte (`sdip[beep_vol_sel][3:2]`): a bank-select write moves the volume
  // to the other bank's byte in the next cycle without any write to the 0x871E port.
  reg  [1:0] sdip_vol_a;   // index 3  (0x871E, bank A)
  reg  [1:0] sdip_vol_b;   // index 15 (0x871E, bank B)
  // The mouse's Port C strap nibble, one 3-bit image per bank, {bit 2, bits 1:0} -
  // index 0/10 for bank A and 12/22 for bank B (the write port below owns them).
  reg  [2:0] sdip_mstrap_a;
  reg  [2:0] sdip_mstrap_b;

  // The beeper volume (z486_mister's speaker amplitude scale): bits [3:2] of the
  // 0x871E byte - EXACTLY the bits a 0x871E read returns, so the amplitude can
  // never disagree with the read-back (the read side is the weak spot). 0x871E
  // is sdip[3] with the bank-A select clear and sdip[15] with it set (qemu
  // pc98-sys.c sdip_index: nibble-4 / nibble+8 over the 24 bytes), so the
  // volume tracks the selected bank's byte like every other read of the port.
  // The power-up code is 3 because the MEASURED 0x871E power-up image is 0x3E
  // (sdip_powerup[3], probe2) and (0x3E >> 2) & 3 = 3. NP2kai is bankless and
  // latches BEEP_VOL on any 0x871E write (io/dipsw.c:44-57); the banked write
  // behaviour on the real machine is unsettled.
  // beep_vol is the selected shadow, loaded by the one write port below.
  assign beep_vol = sdip_ctrl[6] ? sdip_vol_b : sdip_vol_a;
  // The mouse's strap nibble follows the same bank select as every other read of the store
  // (sdip_bank_index): the ACTIVE bank's two source bytes, not a constant.
  wire [2:0] mouse_dip_strap = sdip_ctrl[6] ? sdip_mstrap_b : sdip_mstrap_a;

  // The addressed restore micro-sequencer that walks the store one byte per cycle lives with
  // the store itself (see THE MACHINE-RESET SEED below): it must run DURING this module's
  // reset window, which the FSM block's reset branch below forbids.

  // Per-index access rules for the twelve switch bytes.
  //
  //   data_mask: the bits the guest may write. Only 0x84's bit 1 is withheld: it is
  //              an unmeasured strap (the measured power-up byte 0x7C has it clear,
  //              NP2kai withholds it, io/dipsw.c, and nothing measures otherwise).
  //              EVERY OTHER BIT IS WRITABLE, THE PARITY BITS INCLUDED - because the
  //              machine writes them and the firmware depends on writing them. The
  //              old mask froze each register's parity bit (bit 0 for 0x84, bit 4 for
  //              0x85, bit 7 for the rest - NP2kai's per-register table, which is a
  //              PARITY table, not a strap table: io/dipsw.c derives those bits at
  //              read and never stores them). Freezing them broke the ITF's own
  //              repair: its factory install (BANK4@0xFC7E4, tables BANK4@0x480C and
  //              BANK4@0x4818) composes over the measured machine image (bank A idx 7
  //              = 0xBF, docs/probes/PORTS.TXT:258) to stored 0x5C/0xFF at 0x881E and
  //              0x8B1E - both EVEN parity - so the next check fails again and every
  //              repair re-installs the same bytes: the SET THE SOFTWARE DIP-SWITCH
  //              loop, escapable only by a machine reset. The machine demonstrably
  //              repairs: the Xa7C9W capture (qemu-pc98/roms/pc98bios/memsw.inc)
  //              holds the factory byte 0x7F at exactly the cell where a write mask
  //              traps, and the firmware's own writers write those bits (SETUP's
  //              parity idiom BANK3@0xFA219 `and al,0xEF / jnp +2 / or al,0x10 /
  //              out 0x851E`; the ITF's `or al,0x80 / out 0x8E1E`, BANK4@0xF82FC).
  //              NP2kai disagrees on the write (it masks) and is OVERRULED by the
  //              machine - the same adjudication as for the read side of this very
  //              mechanism (below). FALSIFIER, named so the next reader
  //              knows what would overturn this: no capture measures a PARITY-BIT
  //              write directly (RDBACK covers 0x871E, whose bit 7 is 0 both sides).
  //              If `probe2 /RDBACK` at 0x8B1E or 0x881E (a read-only session) shows
  //              the machine MASKING that bit on write, this change reverses.
  //
  // A READ RETURNS THE STORED BYTE VERBATIM, with no odd-parity bit forced on the
  // read (which would read a written 0x0C back as 0x8C). The machine shows this
  // at the one port of the twelve anyone has written and read back:
  // docs/probes/RDBACK.TXT line 162 is `port=871E before=3E wrote=0C after=0C
  // back=3E` -- an EVEN-parity byte coming straight back. NP2kai forces the bit
  // through the CPU parity flag (`iflags[ret] & 0x04`) and so does not reproduce
  // the machine here; qemu-pc98 stores and returns the byte verbatim
  // (pc98-sys.c `pc98_sdip_read`/`pc98_sdip_write`), agreeing with the capture,
  // which outranks NP2kai. The two models agree on every image the machine
  // fetches at power-up: those bytes are odd-parity except index 6, so both
  // return them unchanged -- which is why the ITF's own odd-parity verifier
  // (`test al,0ffh / jnp`, BANK4@0x46C0-0x4726) passes either way. They differ
  // on an EVEN-parity byte written by a guest (guest-visible). ONLY 0x871E IS
  // MEASURED: the rule is applied to the block because the store, the mask and the
  // read are one mechanism, not twelve (a write-then-read round for the other
  // eleven is the owed capture).
  function automatic [7:0] sdip_data_mask(input [3:0] idx);
    case (idx)
      4'h0: sdip_data_mask = 8'hFD;   // bit 1 only: an unmeasured strap (see above)
      default: sdip_data_mask = 8'hFF; // everything else, parity bits included
    endcase
  endfunction

  // The power-up image of the two banks (index 0 is 0x841E, 23 is 0x8F1E). THE ONE
  // COPY of the default machine configuration: the reset path and the OSD's "Reset
  // DIPs" load the same bytes, so they cannot drift apart.
  //
  // Bank A is the set MEASURED on the real PC-9821Xe10 with probe2 (read-only):
  // Hosts read these to decide installed memory, CPU class and
  // display type, so a wrong bit is a wrong machine description.
  //
  // Bank B comes from the firmware's own factory table, which the ITF writes into
  // bank B at BANK4 offset 0x818: every byte has the odd parity the verifier demands.
  // The index is 0..23, so 5 bits: an integer here widened every case item to 32 bits, which
  // is 24 WIDTHEXPAND warnings for a comparison 5 bits wide. Both call sites pass at most 5
  // significant bits, so it is exact.
  function automatic [7:0] sdip_powerup(input [4:0] idx);
    case (idx)
      5'd0:  sdip_powerup = 8'h7C;   // 0x84
      5'd1:  sdip_powerup = 8'h02;   // 0x85 -- the MEASURED byte; bit 4 (its parity bit)
                                      // is presented on the read, not stored (below)
      5'd2:  sdip_powerup = 8'h76;   // 0x86
      5'd3:  sdip_powerup = 8'h3E;   // 0x87
      5'd4:  sdip_powerup = 8'h7C;   // 0x88
      5'd5:  sdip_powerup = 8'h7F;   // 0x89
      5'd6:  sdip_powerup = 8'hFF;   // 0x8A
      5'd7:  sdip_powerup = 8'hBF;   // 0x8B
      5'd8:  sdip_powerup = 8'h7F;   // 0x8C
      5'd9:  sdip_powerup = 8'h7F;   // 0x8D
      5'd10: sdip_powerup = 8'h49;   // 0x8E
      5'd11: sdip_powerup = 8'h98;   // 0x8F
      5'd12: sdip_powerup = 8'h8F;   // 0x841E
      5'd13: sdip_powerup = 8'h80;   // 0x851E
      5'd14: sdip_powerup = 8'h80;   // 0x861E
      5'd15: sdip_powerup = 8'h80;   // 0x871E
      5'd16: sdip_powerup = 8'h80;   // 0x881E
      5'd17: sdip_powerup = 8'h80;   // 0x891E
      5'd18: sdip_powerup = 8'h80;   // 0x8A1E
      5'd19: sdip_powerup = 8'h80;   // 0x8B1E
      5'd20: sdip_powerup = 8'h80;   // 0x8C1E
      5'd21: sdip_powerup = 8'h80;   // 0x8D1E
      5'd22: sdip_powerup = 8'h80;   // 0x8E1E
      5'd23: sdip_powerup = 8'h80;   // 0x8F1E
      default: sdip_powerup = 8'h80;
    endcase
  endfunction

  // The twelve data ports are 0x841E, 0x851E, ... 0x8F1E: the varying part is
  // the SECOND byte, so the index is port_addr[11:8]. Using [15:12] returned
  // 8 for every port, i.e. all twelve read sdip[4], and the authentic ITF's
  // parity-verified write-back of its switch image could never pass.
  wire [3:0] sdip_index = port_addr[11:8] - 4'h4;   // 0x84..0x8F -> 0..11
  // The bank offset is +12, NOT +16: bank B's register n is at nibble n+4, and
  // QEMU computes its index straight from the port nibble --
  //   `return (sdip_bank & 0x40) ? nibble + 8 : nibble - 4;`  (pc98-sys.c:484-489)
  // over `uint8_t sdip[24]` -- so bank B occupies 12..23. Concatenating the
  // bank bit in front of `sdip_index` gives index+16 (16..27), which both
  // offsets bank B by four and puts indices 8..11 OUTSIDE the 24-byte store --
  // and bank-B indices 8 and 9 are exactly two of the bytes the authentic ITF
  // verifies (BANK4 offsets 0x707-0x726). The reset seeds below are already laid
  // out with bank B at 12..23, so the seed table and the index disagreed.
  wire [4:0] sdip_bank_index = sdip_ctrl[6] ? ({1'b0, sdip_index} + 5'd12)
                                            : {1'b0, sdip_index};
  wire sdip_data_port = (port_addr[7:0] == 8'h1E) &&
                        (port_addr[15:8] >= 8'h84) &&
                        (port_addr[15:8] <= 8'h8F);
  wire sdip_ctrl_port = (port_addr == 16'h8F1F);

  // ==================== THE MACHINE-RESET SEED ====================
  // The store is battery-backed on the machine, and this module's `initial` block above is its
  // power-up image - but `initial` runs at CONFIGURATION time, so without a seed a PLATFORM
  // reset (or an OSD Reset) would leave the store exactly as the guest and the firmware had
  // left it, and only a fabric reload would re-apply the image. The machine-reset seed is the
  // one in-run restore.
  // The authentic ITF validates this bank at every boot and, when a byte fails its
  // odd-parity verify, installs its FACTORY image over all twelve bytes of BOTH banks
  // (`BANK4@0xFC7B2`, the table at `BANK4@0x480C`), so a reset without the seed brings that
  // message back; the seed re-applies the image on the same strobe every other
  // configuration latch in this module uses (this module's `reset` IS `reset || !cpu_run`, the
  // machine-reset / pack-reload strobe - see bios_set_eff below), so a machine reset restores
  // what a fabric reload restores.
  //
  // It drives the EXISTING addressed walk rather than a second mechanism: 24 cycles, one byte
  // per cycle through the store's single write port (that shape is what keeps the array in
  // M10K instead of 192 flops, and the `sdip_seq_*` state lives HERE rather than in the FSM block because it must run DURING the reset window - see below).
  //
  // THE WALK STARTS ON THE RESET ASSERTION, NOT ON ITS RELEASE, and that is what keeps the boot
  // golden exact: in every real reset window (a reload's seconds, an OSD reset's SDRAM
  // calibration) 24 cycles fit inside the window, the walk is over before the CPU may leave
  // reset, and the hold below is never asked for at all. `sdip_seed_pulse` (the assertion
  // one-shot) is exported for the CG record in pc9821_cg, which is re-seeded from the same event.
  //
  // THE HOLD. If the strobe is SHORTER than the walk (a `reset` pulse with the pack already
  // loaded), the walk outlives the window and the CPU could reach its first DIP read with a
  // half-seeded bank - the failure mode where a fix still shows the message on a fast reset.
  // So `cpu_reset_req` is asserted for the whole walk (see the FSM's default assignment below):
  // pc9821_system already routes that request into pc9821_cpu_reset_gate, which re-arms the
  // CPU-reset hold every cycle it is high, so the CPU cannot issue ANY access while a byte of
  // the walk is still unwritten. It is a NO-OP in the golden path - `sdip_seq_active` is 0 by the
  // time the CPU may leave reset - and it also covers the OSD actions, whose 24-cycle walk a
  // front-panel press pays 480 ns for (a read mid-walk would see a partial bank there too).
  //
  // The walk state is deliberately NOT reset-held (its `initial` values are its power-up values,
  // PROCASSINIT): it must run during the reset window and survive its release, which is exactly
  // what the FSM block's reset branch would forbid. The state could not be corrupted by a
  // power-up value of 1 either: the walk writes `sdip_powerup` unconditionally (the zero
  // mode left with the OSD `Zero DIPs` action), and the walk state is 0 at power-up.
  reg       sdip_seq_active;
  reg [4:0] sdip_seq_idx;
  reg       sdip_reset_d;
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  initial begin
    sdip_seq_active = 1'b0;
    sdip_seq_idx    = 5'd0;
    sdip_reset_d    = 1'b0;   // so the strobe's ASSERTION is a rising edge at configuration time too
  end
  /* verilator lint_on PROCASSINIT */
  wire sdip_seed_start = reset && !sdip_reset_d;   // one cycle at the machine-reset assertion
  assign sdip_seed_pulse = sdip_seed_start;        // ... and the CG record's restoring event

  // The one-cycle seed start (see the port comment): the machine-reset assertion starts a
  // 24-cycle addressed sequence writing one byte per cycle, and then the store is left to the
  // guest -- the ITF writes and read-back-verifies both banks at BANK4 offsets 0x44E/0x47A/0x7E9,
  // so a persistent load would be a bug. This walk has the reset seed as its only source and
  // no zero mode.
  always @(posedge clk) begin
    sdip_reset_d <= reset;
    if (sdip_seed_start) begin
      sdip_seq_active <= 1'b1;
      sdip_seq_idx    <= 5'd0;
    end else if (sdip_seq_active) begin
      // The byte itself is written by the store's one write port (beside the array); this arm
      // owns only the walk, and a guest write owning the port in the same cycle leaves the byte
      // for that step unwritten -- the same assignment priority the flop form had.
      if (sdip_seq_idx == 5'd23) begin
        sdip_seq_active <= 1'b0;
        sdip_seq_idx    <= 5'd0;
      end else begin
        sdip_seq_idx <= sdip_seq_idx + 5'd1;
      end
    end
  end

  // THE STORE'S ONE WRITE PORT, shared by the guest's 0x..1E write and the addressed walk.
  // The guest wins a collision, which is exactly what the two-assignment flop form did for a
  // collision on the SAME cell (there the later, guest, non-blocking assignment won); on a
  // collision on DIFFERENT cells the flop form wrote both, so this form drops the walk's
  // byte for that one cycle and its walk advances past it -- one byte of a 24-byte walk,
  // and only when a guest write to the 0x84-0x8F data block lands in the same 20 ns as the
  // action. The guest byte is still built from the addressed cell and the per-index data
  // mask, so 0x84's bit 1 - the one withheld bit - keeps its power-up image value.
  wire       sdip_guest_we = (state == S_BYTE) && request_write && sdip_data_port && sdip_writable;
  wire [7:0] sdip_guest_data = (sdip_q & ~sdip_data_mask(sdip_index)) |
                               (lane_wdata & sdip_data_mask(sdip_index));
  wire       sdip_we       = sdip_guest_we || sdip_seq_active;
  wire [4:0] sdip_waddr    = sdip_guest_we ? sdip_bank_index : sdip_seq_idx;
  wire [7:0] sdip_wdata    = sdip_guest_we ? sdip_guest_data
                                : sdip_powerup(sdip_seq_idx);
  always @(posedge clk) begin
    if (sdip_we) sdip[sdip_waddr] <= sdip_wdata;
    // 0x871E is index 3 in bank A and index 15 in bank B; each shadow carries the same bits
    // the store just took, in the same cycle.
    if (sdip_we && (sdip_waddr == 5'd3))  sdip_vol_a <= sdip_wdata[3:2];
    if (sdip_we && (sdip_waddr == 5'd15)) sdip_vol_b <= sdip_wdata[3:2];
    // The mouse's Port C strap nibble (pc9821_mouse's `dip_strap`): a SHADOW rather than a
    // second combinational read of sdip[], for the same reason as the two above and one
    // more - an asynchronous read port on this array makes Quartus refuse the block RAM and
    // build all 192 bits in LUTs (the declaration's measured note). The two sources are
    // index 0 (0x841E, NP2kai's dipsw[0]) and index 10 (0x8E1E, whose bit 4 is NP2kai's
    // dipsw[2] bit 7 - io/dipsw.c:105-111); bank B's are 12 and 22. Each site updates only
    // its own bits, so the index that was not written keeps the store's value.
    if (sdip_we && (sdip_waddr == 5'd0))  sdip_mstrap_a[1:0] <= ~sdip_wdata[5:4];
    if (sdip_we && (sdip_waddr == 5'd10)) sdip_mstrap_a[2]   <= sdip_wdata[4];
    if (sdip_we && (sdip_waddr == 5'd12)) sdip_mstrap_b[1:0] <= ~sdip_wdata[5:4];
    if (sdip_we && (sdip_waddr == 5'd22)) sdip_mstrap_b[2]   <= sdip_wdata[4];
    sdip_q <= sdip[sdip_bank_index];
  end

  // The shadows' power-up values are the 0x871E images' bits [3:2] (sdip_powerup(3) = 0x3E,
  // sdip_powerup(15) = 0x80), as the array's own init is. They are NOT reset, like the array.
  // The image byte is taken through a local because 17.0.2 refuses a bit-select on a function
  // CALL result in Verilog-2001 mode, which Verilator accepts; the waiver is for the bits of
  // that local the field does not cover, and they are genuinely unused here.
  /* verilator lint_off UNUSEDSIGNAL */
  initial begin
    reg [7:0] img;
    img = sdip_powerup(5'd3);   sdip_vol_a = img[3:2];
    img = sdip_powerup(5'd15);  sdip_vol_b = img[3:2];
    img = sdip_powerup(5'd0);   sdip_mstrap_a[1:0] = ~img[5:4];
    img = sdip_powerup(5'd10);  sdip_mstrap_a[2]   = img[4];
    img = sdip_powerup(5'd12);  sdip_mstrap_b[1:0] = ~img[5:4];
    img = sdip_powerup(5'd22);  sdip_mstrap_b[2]   = img[4];
  end
  /* verilator lint_on UNUSEDSIGNAL */

  integer i;

  // The classifier is the OR of the shared match lines above: one plane, not two
  // 85-arm and 102-arm equality cases. sdip_data_port/sdip_ctrl_port have no single match
  // line (0x841E-0x8F1E is a stride-of-0x100 run), so they keep their own test.
  // device_port is pc9821_device_select's dev_bus_cs: the ONE device-bus claim, a product of the
  // same decode that splits it into chip selects (the instance below), so a port cannot be
  // claimed in one list and unreachable in the other.
  wire device_port = dev_bus_cs;
  wire system_port = |hit[108:0] || sdip_data_port || sdip_ctrl_port || dma_port;
  assign device_io_addr = port_addr;
  assign device_io_din = lane_wdata;
  assign device_io_wr = (state == S_BYTE) && request_write && device_port;
  assign device_io_rd = (state == S_BYTE) && !request_write && device_port;

  // The FDC (0x90/0x92/0x94, the 1.44M/RPM register at 0x04BE, and the
  // channel-group/media register at 0x00BE/0x00BF). A system port,
  // so it is not on the device fabric; it sees the same one-cycle S_BYTE strobes and
  // presents its read byte combinationally, exactly like the other system-port arms
  // below.
  // The controller answers through ONE of its two windows: the 2HD one at
  // 0x90/0x92/0x94 or the 2DD one at 0xC8/0xCA/0xCC, whichever the strap names. The
  // unselected window is not decoded here at all, so it falls through to the open
  // bus 0xFF and its writes are dropped -- exactly NP2kai's gate,
  // `if (((port >> 4) ^ fdc.chgreg) & 1) return 0xff;` in fdc_i90/fdc_i92/fdc_i94
  // and the same test at the top of fdc_o92/fdc_o94 (io/fdc.c:1040, 1050, 1068,
  // 975, 996). qemu-pc98 does NOT gate (both windows route to one handler,
  // hw/block/pc98-fdc.c:2808-2818) and MAME aliases with a TODO saying it should
  // not (pc9801.cpp:567-569, pc9801.h:162): the two are recorded as a dissent, and
  // NP2kai's documented behaviour is what is modelled. The two windowless
  // registers -- the strap itself at 0x00BE/0x00BF and the 1.44M/RPM register at
  // 0x04BE -- stay reachable in both modes, which is what lets a guest come back.
  wire fdc_win_2hd = hit[HX_0090] || hit[HX_0092] || hit[HX_0094];
  wire fdc_win_2dd = hit[HX_00C8] || hit[HX_00CA] || hit[HX_00CC];
  wire fdc_win_sel = fdc_win_2dd ? ~fdc_strap_2hd : fdc_strap_2hd;
  wire fdc_cs = ((fdc_win_2hd || fdc_win_2dd) && fdc_win_sel) ||
                (hit[HX_00BE]) || (hit[HX_00BF]) ||
                (hit[HX_04BE]);
  wire fdc_wr = (state == S_BYTE) && request_write && fdc_cs;
  wire fdc_rd = (state == S_BYTE) && !request_write && fdc_cs;
  wire [7:0] fdc_dout;
  pc9821_fdc #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) fdc (
      .clk(clk), .reset(reset), .dip_fixed(fdd_dip_fixed), .cs(fdc_cs),
      // 0x90/0x92/0x94 and 0xC8/0xCA/0xCC take the register index from
      // addr[2:1] -- the same index in either bank, which is NP2kai's
      // `(port >> 1) & 3` over its one handler table; 0x04BE is the separate
      // 1.44M/RPM register and 0x00BE/0x00BF the channel-group register, named
      // explicitly rather than relying on low-bit aliasing.
      .addr((hit[HX_00BE] || hit[HX_00BF]) ? 3'd4 :
            hit[HX_04BE] ? 3'd3 : {1'b0, port_addr[2:1]}),
      .win_2dd(fdc_win_2dd), .strap_2hd(fdc_strap_2hd),
      .wr(fdc_wr), .rd(fdc_rd), .din(lane_wdata), .dout(fdc_dout),
      .irq(fdc_irq_raw),
      .media_present(fdd_present),
      .writeprotect(fdd_wp),
      .media_chg(fdd_chg), .frame_tick(fdd_frame_tick),
      .media_req(fdd_req), .media_req_hdr(fdd_req_hdr), .media_unit(fdd_unit),
      .media_c(fdd_c), .media_h(fdd_h), .media_tc(fdd_tc), .media_hd(fdd_hd), .media_mf(fdd_mf), .media_2hd(fdd_2hd), .media_rpm(fdd_rpm), .media_r(fdd_r), .media_n(fdd_n),
      .media_idx(fdd_idx),
      .media_ready(fdd_ready), .media_rdy(fdd_rdy), .media_hdrv(fdd_hdrv),
      .media_err(fdd_err), .media_dout(fdd_dout),
      .media_hr(fdd_hr), .media_hn(fdd_hn), .media_hs(fdd_hs),
      .media_adv(fdd_adv),
      .media_wr(fdd_req_wr), .media_din(fdd_din), .media_abort(fdd_abort),
      // The controller's single device port: the DRQ it raises and the byte it
      // presents go to u_dma on the STRAP's channel, and every engine handshake it
      // sees is qualified by that same channel, so the other channel's strobe can
      // never alias it. Verified against the engine: pc9821_dmac is four-channel
      // generic (ch_addr[0:3]/ch_count[0:3], `dev_dack = (state == S_DEV) ?
      // (4'b0001 << cur) : 4'b0000` :494, `dev_ch = cur` :508), and its channel-3
      // register ports (0x0D/0x0F/0x23) and 0x15 single-mask bit are already decoded
      // by dma_port/dma_idx above -- so this select is the WHOLE DMA-side change.
      .dma_drq(fdc_drq),
      .dma_dack(fdc_strap_2hd ? dma_dev_dack[2] : dma_dev_dack[3]),
      .dma_stb(dma_dev_stb && (dma_dev_ch == fdc_dma_ch)),
      .dma_tc(dma_dev_tc && (dma_dev_ch == fdc_dma_ch)),
      .dma_dout(fdc_dma_out),
      // WRITE DATA's bytes: the engine's direction and its memory-to-port byte. Both are the
      // engine's one device-port pair, qualified by this controller's own DACK/strobe above.
      .dma_we(dma_dev_we), .dma_din(dma_dev_dout),
      // res_done stays connected to its unused wire (see the flush launch site):
      // the per-write snoop (T24) covers the EOT end too.
      .res_done(fdc_res_done),
      .dbg_state(dbg_fdc_state), .dbg_cmd(dbg_fdc_cmd),
      .dbg_result(dbg_fdc_result), .dbg_chrn(dbg_fdc_chrn)
  );

  // One controller, two destinations: the strap picks IRQ11 or IRQ10 (NP2kai
  // fdc_intwait, io/fdc.c:43-56).
  assign fdc_irq   = fdc_irq_raw & fdc_strap_2hd;
  assign fdc_irq10 = fdc_irq_raw & ~fdc_strap_2hd;

  // The bus mouse (0x7FD9-0x7FDF and the 0xBFDB timer port): another system
  // port on the same one-cycle S_BYTE strobes, with the whole uPD8255 + delta
  // counter + IRQ13 device in its own module (NP2kai io/mouseif.c throughout -
  // see pc9821_mouse's header for the citations and the one MAME-sourced
  // behaviour). Its IRQ is the slave PIC's IRQ13 (mouseint's pic_setirq(0x0d)).
  wire mouse_cs = hit[HX_7FD9] || hit[HX_7FDB] || hit[HX_7FDD] ||
                  hit[HX_7FDF] || hit[HX_BFDB];
  wire mouse_wr = (state == S_BYTE) && request_write && mouse_cs;
  wire mouse_rd = (state == S_BYTE) && !request_write && mouse_cs;
  wire [7:0] mouse_dout;
  pc9821_mouse #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) mouse (
      .clk(clk), .reset(reset), .cs(mouse_cs),
      .addr(hit[HX_BFDB] ? 3'd4 : {1'b0, port_addr[2:1]}),
      .wr(mouse_wr), .rd(mouse_rd), .din(lane_wdata), .dout(mouse_dout),
      .dip_strap(mouse_dip_strap),
      .ps2_mouse(ps2_mouse), .irq(mouse_irq)
  );

  // THE PORT-0xF0 MACHINE-ID STRAP, one entry per Machine field value the OSD offers: the
  // read is a four-bit-indexed LUT. The pack file IS the firmware set; the two ITFs read
  // this byte's bit 5 differently - the Xe10 tests bits 5
  // AND 6 together (BANK4@0xF8207: and al,0x60; xor al,0x60), the Xe tests BIT 5 ALONE
  // (BANK4@0xF81DF: test al,0x20). With bit 5 set the Xe skips the 0xD8000 option-ROM
  // shadow copy its own boot needs, the IDE ROM never runs and the guest runs away.
  // 0xA9 is the MEASURED Xe10 strap; 0x89 is the same byte with
  // bit 5 clear. Sets 2..15 have no pack and no measured strap, so they answer the
  // measured Xe10 byte 0xA9 - the known-good default - rather than an invented value.
  // This LUT must NOT be moved back onto status[5]/status[6]: those bits already drive the
  // DDR framebuffer's BGR/RGB and 1555/565 format (z486_mister.sv fb_fmt[4:3]), so the OSD
  // field lives on O[31:28]. owns both tables.
  // The 0x9A0 query table (NP2kai gdc_i9a0 verbatim, io/gdc.c:969-1030): the
  // indexed bit of the GDC's extension state, OR'd with gdc.clock bit 1 into
  // EVERY response (`ret |= (gdc.clock & 2)`). Index 0 answers 0xFF, and so does
  // index 0x0B on the machine (RDBACK.TXT; NP2kai's constant 1 is refuted); an
  // unlisted index answers 0.
  function automatic [7:0] gdc_ff2_query(input [7:0] idx, input [10:0] s);
    reg [7:0] ret;
    begin
      ret = 8'h00;
      case (idx)
        8'h00: ret = 8'hFF;
        8'h01: ret = {7'b0, s[0]};   // mode1[1]
        8'h02: ret = {7'b0, s[1]};   // mode1[4] (200-line)
        8'h03: ret = {7'b0, s[2]};   // mode1[7] (DISP)
        8'h04: ret = {7'b0, s[3]};   // mode2[0] (16-colour select)
        8'h05: ret = {7'b0, s[6]};   // display PLAZMA
        8'h07: ret = {7'b0, s[4]};   // mode2[2] (EGC extended)
        8'h08: ret = {7'b0, s[5]};   // mode2[3] (register write enable)
        8'h09: ret = {7'b0, s[7]};   // gdc.clock[0]
        8'h0A: ret = {7'b0, s[9]};   // GDCANALOG_256 (the PEGC probe's bit 0)
        // NP2kai answers a constant 1 here (`case 0x0b: ret = 1;`); the Xe10 reads 0xFF
        // (docs/probes/RDBACK.TXT `port=09A0 before=01 wrote=0B after=FF back=00`), and the
        // capture outranks it. 0xFF already carries the clock-bit OR below.
        8'h0B: ret = 8'hFF;
        8'h0D: ret = {7'b0, s[10]};  // GDCANALOG_256E
        default: ret = 8'h00;
      endcase
      gdc_ff2_query = ret | {6'b0, s[8], 1'b0};   // ret |= (gdc.clock & 2)
    end
  endfunction

  function automatic [7:0] machine_id_strap(input [3:0] set);
    case (set)
      4'd0:    machine_id_strap = 8'hA9;   // PC-9821Xe10, the measured strap
      4'd1:    machine_id_strap = 8'h89;   // PC-9821Xe, 0xA9 with bit 5 clear
      default: machine_id_strap = 8'hA9;   // sets 2..15 unimplemented: the Xe10 strap
    endcase
  endfunction

  // THE EFFECTIVE MACHINE SET: the OSD field above, re-sampled ONLY on this module's reset,
  // which pc9821_system drives with the core's machine-reset/reload strobe
  // `reset || !cpu_run` (pc9821_system's iobus instance) - the platform reset OR the
  // pack-reload window, never the warm CPU-reset class (out 0xF0 / 0x534 / a z486
  // shutdown). The 0xF0 arm below reads THIS register, so a mid-run OSD toggle has zero
  // effect on the strap byte until the next machine reset / reload: the two ITFs read the
  // strap's bit 5 differently and the byte must be stable for the whole boot (and across
  // the guest's own CPU resets, which re-enter the same ITF on the same machine). Same
  // re-sample rule as pc9821_system's ram_size_sel: it tracks the OSD while the strobe is
  // asserted and freezes at release. tb_pc9821_bios_select pins this contract.
  /* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
  reg [3:0] bios_set_eff = 4'd0;          // power-on default: set 0, the Xe10
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) begin
    if (reset) bios_set_eff <= bios_set;
  end

  // The GDC-clock strap's latch: the same one-decision, one-reset rule as bios_set_eff.
  /* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
  reg gdc_strap_eff = 1'b0;               // power-on default: 2.5 MHz, the measured machine
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) begin
    if (reset) gdc_strap_eff <= gdc_clock_5m;
  end

  // THE DIP-2 REGISTER BYTE PORT 0x31 ANSWERS, and the PARITY BIT of SDIP bank A index 1.
  //
  // The authentic ITF's verify of that register (BANK4@0xFC6C0-0xFC6DA) is a MERGE with
  // the port-0x31 read, not a parity test on the stored byte:
  //
  //   in al,0x851E / mov ah,al / in al,0x31 / and ax,0x10EF / or al,ah / out al,(0x851E)
  //   -> merged = (port31 & 0xEF) | (sdip1 & 0x10), and `test al,0FFh` / `jnp` requires it
  //      to have ODD parity.
  //
  // Bit 4 of that register IS the DIP-2 byte's parity bit (NP2kai's per-register parity
  // positions, io/dipsw.c: bit 4 for 0x85; the merge is the machine's own statement of the
  // same fact) and it is NOT guest data - the port read below derives it from the strap,
  // so no write moves what the ITF merges. It is also the ONE bank-A byte the ITF does not
  // test directly: the direct pass
  // covers 0x84, 0x86-0x88, the 0x89^0x8A XOR pair and 0x8B-0x8F, and 0x851E is handled in
  // between as this merge. So it is the store's only bit that must FOLLOW the DIP-2 data,
  // and the only DIP-2 bit this core moves is port 0x31 bit 7 (the GDC clock).
  //
  // WHY IT IS DERIVED AND NOT SEEDED. The store is a battery-backed image loaded by an
  // `initial` block, which runs at configuration time - before any OSD field exists - so a
  // seed CANNOT depend on the GDC Clock selection: it would hold the 2.5 MHz byte 0x02 on a
  // card configured for 5 MHz, and the merge (0x73 & 0xEF) | (0x02 & 0x10) = 0x63 is EVEN.
  // The ITF then takes its repair path (BANK4@0xFC7B2) and prints SET THE SOFTWARE
  // DIP-SWITCH (BANK4@0xFC8DE-0xFC903) and writes 0xF0 = 0x00, which on this core raises
  // cpu_reset_req: POST -> message -> reset -> POST, an endless loop.
  // Deriving the bit is also what makes the two straps the same machine: 0xF3 with bit 4
  // clear merges ODD (0xE3, 5 ones), 0x73 with bit 4 SET merges ODD (0x73, 5 ones).
  //
  // The parity is taken over the port-0x31 DATA the ITF merges (its bit 4 masked off), from
  // the SAME reset-qualified latch the port answers with - not the live field - so the two
  // bytes the ITF merges can never disagree. At entry 0 (2.5 MHz) the derived bit is 0,
  // which is the measured store byte's own value: the default state is bit-identical.
  //
  // TWO INDEPENDENT FIRMWARE WITNESSES, so this is the machine's convention and not our
  // inference. The ITF's verify above (BANK4@0xFC6CC-0xFC6DA) is one; the OTHER is the
  // SETUP's own per-index SDIP accessor table, which does the same thing per register:
  //
  //   BANK3@0xFA20B (READ index 1)   in al,0x851E / mov ah,al / in al,0x31
  //                                  / and ax,0x10EF / or al,ah / ret
  //   BANK3@0xFA219 (WRITE index 1)  and al,0xEF / jnp +2 / or al,0x10 / out al,0x851E
  //                                  (file offsets 0x220B/0x2219; BANK3 is one of the banks
  //                                  the 0xF8000 window shows, so phys = 0xF8000 + off - the
  //                                  ITF reaches it as `lcall 0xFA00:0x0000`, BANK4@0x2551)
  //
  // i.e. the firmware's WRITER sets bit 4 with the parity idiom (make the byte odd over its
  // other bits), and its READER returns port 0x31's data with that bit. Index 0's pair does
  // the same at bit 0 (`and al,0xFE / jnp / or al,0x01`) and the rest at bit 7, which is
  // NP2kai's per-register table. So the value this read presents is the value the machine's
  // own SETUP would have STORED, and sdip_data_mask keeps index 1 at 0xEF because a guest
  // write to bit 4 could only be that same parity maintenance - the read owns it instead.
  wire [7:0] dip2_reg    = gdc_strap_eff ? 8'h73 : 8'hF3;
  wire       dip2_parity = ~(^(dip2_reg & 8'hEF));

  // The port read of SDIP bank A index 1 (0x851E) presents that bit. The STORE keeps the
  // measured byte and every consumer of the store keeps reading the store: this is the port
  // read only, which is what the ITF merges and what its configuration screen renders. It
  // does not violate the read-back-verbatim rule - that rule is about GUEST data and is
  // pinned at 0x871E (index 3, docs/probes/RDBACK.TXT:162) - because bit 4 of index 1 is a
  // bit no guest write can own. Bank B's 0x851E is a DIFFERENT cell (index 13, seed 0x80)
  // and IS directly parity-checked (BANK4@0xFC71C), so the patch is confined by the bank
  // index: sdip_bank_index is 1 for bank A index 1 and 13 for bank B's.
  wire [7:0] sdip_read_byte = (sdip_bank_index == 5'd1)
                              ? {sdip_q[7:5], dip2_parity, sdip_q[3:0]}
                              : sdip_q;

  reg [7:0] lane_rdata;
  always @* begin
    if (device_port) lane_rdata = device_io_dout;
    // The uPD71071 register file (pc9821_dmac). Its COMBINATIONAL port, because this fabric
    // captures its read byte in the access cycle (see the declaration): the engine's read
    // side effects commit at that cycle's edge, so the byte the CPU receives is the one the
    // register held when the access arrived.
    else if (dma_port) lane_rdata = dma_reg_dout;
    else case (1'b1) // synthesis parallel_case
      // The core's own POST/debug port. 0x1F is NOT decoded: on a real PC-98 it is
      // the uPD71071 DMA bank register.
      // DELIBERATE DIVERGENCE: the machine has nothing at 0x0EE0 and answers
      // the open bus 0xFF there (docs/probes/PORTS.TXT's `0EE0=FF`), and IO.TXT times that read
      // as the default class, while this core drives the watchdog's status byte. It is the same
      // SHAPE as the 0x9A8 constant the audit refuted - a probe port whose read is not the
      // machine's - but this one is deliberate: the port is in no reference's decode and no
      // firmware site touches it (every BANK's disassembly: not one 0xEE0 operand), so it can
      // only be read by a guest that deliberately reads a port nothing answers, and the byte is
      // the only in-sim view of the platform state (docs/pc9821-port-status.md's `ST` field).
      hit[HX_0EE0]: lane_rdata = debug_status;
      // Floppy disk controller (pc9821_fdc). It answers the machine's measured
      // idle bytes (0x90 = 0x80 RQM, 0x92 = 0x80, 0x94 = 0x44 with bit 4 = 0, no
      // diskette) and moves MSR through a command so the BIOS's FDD probe
      // completes instead of spinning on the ack no device ever sent. 0x04BE is
      // the 1.44M/RPM register (NP2kai fdc_i4be: rpm | 0xFE).
      hit[HX_0090], hit[HX_0092], hit[HX_0094],
      hit[HX_00C8], hit[HX_00CA], hit[HX_00CC], hit[HX_04BE],
      hit[HX_00BE], hit[HX_00BF]: lane_rdata = fdc_dout;
      // The WSS ports 0x0F40/0x0F44/0x0F45 and 0x8F1F have no arm: the machine reads the
      // open bus 0xFF there, which the default below already answers.
      // 0x043B bit 2 round-trips the guest's own request bit (NP2kai echoes the
      // live latch: necio_o043b stores `dat & 0x04` and necio_i043b returns it,
      // io/necio.c:24-27) on the machine's measured base byte. The constant 0xFB
      // was the measured DOS-prompt byte - taken after the firmware's own 0x00
      // writes - so a constant would freeze it: a guest RMW would read 0xFB
      // whatever it had written. Read bit 2 is the WRITE bit (the request), so
      // write 0x04 reads 0xFF and write 0x00 reads 0xFB - the "0xFF/0xFB class"
      // - and the hole state sys16m_en is its
      // inverse (bit 2 SET = RAM asked for = the hole NOT used).
      hit[HX_043B]: lane_rdata = sys16m_en ? 8'hFB : 8'hFF;
      // 0x1E8E reports whether the IDE BIOS's private DA000 RAM is
      // connected. Bit 0 set means yes; the machine reads 0xFE at the DOS
      // prompt, i.e. the upper bits read as one and bit 0 is the state, so the
      // honest model is {7'b1111_111, gate}. Bit 0 round-trips with the read,
      // which is what makes the IDE ROM's save/0x81/restore idiom idempotent.
      hit[HX_1E8E]: lane_rdata = {7'b1111_111, ide_ram_gate};
      // 0x9A0: an INDEX/DATA QUERY, not a constant (NP2kai gdc_i9a0,
      // io/gdc.c:969-1030). A write selects the index and
      // the read returns the indexed bit of the GDC's extension state. Two
      // machine captures pin both halves: the write-then-read protocol
      // (probes/PROBE.TXT `FF 9A0 after writing 0x0A: 00` = the table's
      // index-0x0A answer with analog-256 clear, i.e. the PEGC probe is NOT
      // acknowledged) and the un-written rest byte 0x01 (`09A0=01`, eleven
      // snapshots), which the arm answers until the first write because the
      // power-up INDEX is unmeasured. Bit 0 at index 0x0A is the live analog-256
      // bit, clear on this core.
      hit[HX_09A0]: lane_rdata = gdc_ff2_written ?
                            gdc_ff2_query(gdc_ff2, gdc_ff2_state) : 8'h01;
      // Measured 0x45 at the DOS prompt: a strap byte, not a mirror of any write.
      hit[HX_0032]: lane_rdata = 8'h45;
      // 0x0044 echoes the strobe latch (NP2kai prt_i44, io/printif.c:114-117):
      // a write-then-read round-trips instead of answering the constant 0x81.
      // The power-up value is the machine's capture
      // (PORTS.TXT `0044 81`), which NP2kai's 0x00 static disagrees with.
      hit[HX_0044]: lane_rdata = prt_i44_data;
      hit[HX_00F4]: lane_rdata = 8'hFC;
      hit[HX_0134]: lane_rdata = 8'h0F;
      hit[HX_0434]: lane_rdata = 8'hBE;
      hit[HX_053E]: lane_rdata = 8'hFC;
      // 0xF6 reads the machine's constant 0x5E, released OR masked: a20map masks with
      // `out 0xF6,0x03` and reads "after masking: F6=5E F2=FF" while its masked reads wrap
      // bit 20 (docs/probes/A20MAP-XE10.TXT:2,9,19). The mask state shows at 0xF2 only.
      // NP2kai cpuio_if6 / MAME report bit 0 = masked; the capture outranks them. The ITF
      // needs a driven byte here (open bus broke its restore), which this still is.
      hit[HX_00F6]: lane_rdata = 8'h5E;
      // Measured: 0xA9 (bit 0 always 1, bit 5 = the other channel's interface
      // absent, bit 6 clear = this channel's present), 0xF1 = 0xFF open bus,
      // 0xF2 = 0xFE. QEMU models 0xF1 as 0x2E and 0xF6 as 0x5E; the machine
      // agrees on 0xF6 and disagrees on 0xF1.
      //
      // THE MACHINE-IDENTITY LUT: the loaded pack IS the machine, so 0xF0 answers
      // machine_id_strap of the RESET-QUALIFIED bios_set_eff (not the live OSD field) -
      // 0xA9 for the Xe10 (entry 0, the config-less default), 0x89 for the Xe, the
      // measured Xe10 byte for the reserved sets.
      hit[HX_00F0]: lane_rdata = (machine_id_strap(bios_set_eff) & ~{2'b00, ide_unit0_present, 5'b00000})
                                 | {1'b0, !IDE_UNIT2_PRESENT, 6'b000000};
      hit[HX_00F1]: lane_rdata = 8'hFF;
      // 0xF2 tracks the A20 state: NP2kai's cpuio_if2 returns
      // 0xFF - bit20(CPU_ADRSMASK) (io/cpuio.c:71-78), i.e. 0xFE with the gate
      // released and 0xFF with it masked. The single machine sample (0xFE) was
      // taken with A20 released and cannot separate the two models; a constant
      // 0xFE would make a gate-state probe read released while A20 is masked.
      hit[HX_00F2]: lane_rdata = a20_enable ? 8'hFE : 8'hFF;
      // Measured on a PC-9821Xe10 (tools/hwprobe): DIP switch 2 reads 0xF3, i.e. bit 7
      // SET, which is the BIOS's 2.5 MHz GDC clock (BIOS.ROM@0xFD93C). The ITF's memory
      // check polls bit 2, which is clear either way, but the other bits are the
      // machine's straps and should not read as zero. The OSD's GDC Clock field selects
      // between that measured strap and 0x73 (bit 7 clear = 5 MHz), and the read uses the
      // reset-qualified latch for the reason on the port declaration above. The byte is
      // named once (dip2_reg, above) because the SDIP bank-A index-1 read derives that
      // register's PARITY BIT from it: the two bytes the ITF's merge combines must come
      // from one value, or the merge could be EVEN with both ports behaving as written.
      hit[HX_0031]: lane_rdata = dip2_reg;
      // Bit 0 is the calendar's serial data output; the rest is the machine's
      // fixed strap. Returning it as a constant made every calendar read look
      // like an even second.
      // Measured: 0xF9 with the calendar's data bit set, so the fixed part is
      // 0xF8 (bit 3 is the monitor strap); 0xE8 inverted two strap bits.
      hit[HX_0033]: lane_rdata = 8'hF8 | {7'b0, cal_cdat};
      hit[HX_0035]: lane_rdata = system_port_c;
      // Measured 0x94. The firmware READS this port for straps
      // (bits 0/1/2, at eight BIOS sites and five ITF sites), so this is not
      // cosmetic -- 0xFF told it a different machine. NP2kai's prt_i42 computes
      // 0x84 | the 8 MHz strap (0x20) | dipsw[0] bits 2/7 (0x10/0x08) | the
      // V30/EPSON bit (0x02) (io/printif.c:83-112); for the Xe10 that is
      // 0x84|0x10 = 0x94, the measured byte, plus the read side effect: seven consecutive DC1 data bytes arm a one-shot
      // SELECT-BUSY (prt_o40 - the counter must exceed 5) and the next read
      // answers bit 2 CLEAR once and disarms.
      hit[HX_0042]: lane_rdata = prt_select_busy ? (8'h94 & ~8'h04) : 8'h94;
      // ARTIC timestamp counter: a 24-bit counter at 307200 Hz, but NOT four adjacent bytes.
      // 0x5E MIRRORS 0x5D (both cnt[15:8]) - NP2kai's artic_bind() attaches 0x5D and 0x5E to the
      // same handler, and the real machine reads 0x5E equal to 0x5D or 0x5D+1 (one tick lands
      // between the two byte reads). So `in ax,0x5E` = cnt[23:8], advancing every 256 ticks =
      // 833 us, NOT cnt[31:16] (65536 ticks = 213 ms) - every firmware delay() was 256x too long.
      // The write side keeps 0x5F as an accepted-and-ignored I/O wait, which is why 0x5F is a
      // read/write-asymmetric port.
      hit[HX_005C]: lane_rdata = artic_cnt[7:0];
      hit[HX_005D]: lane_rdata = artic_cnt[15:8];
      hit[HX_005E]: lane_rdata = artic_cnt[15:8];   // the 0x5D mirror
      hit[HX_005F]: lane_rdata = artic_cnt[23:16];
      hit[HX_043D]: lane_rdata = 8'hFF;   // write-only; measured as open bus
      hit[HX_043F]: lane_rdata = 8'hC4;   // measured
      hit[HX_0436]: lane_rdata = config_436;
      hit[HX_0439]: lane_rdata = config_439;
      // 0x0461: the page the register holds, read back with bit 0 set:
      // measured 0461=00 rb=01, =08 rb=09, =0A rb=0B, =0C
      // rb=0D, =0E rb=0F, =0F rb=0F, =10 rb=11, =41 rb=41, =7F rb=7F. QEMU
      // returns (value & 0xFE) (pc98-mem.c:708); the machine returns (value | 1).
      hit[HX_0461]: lane_rdata = win0_sel | 8'h01;
      hit[HX_0149]: lane_rdata = latch_149;
      // Measured at the DOS prompt: 0x63D = 0xEC, 0x63E =
      // 0xFE, 0x63F = 0x6C. The firmware tests only 0x63D bit 6, which is set
      // in 0xEC (do not adopt QEMU's 0x04, which would flip the branch), and
      // read-modify-writes 0x63F.
      // 0x610 is the authentic ITF's POST stage code, and it is WRITE-ONLY to the guest:
      // probe2 /RDBACK wrote 0x1A there and read open bus both before and after
      // (`port=0610 before=FF wrote=1A after=FF back=FF`, docs/probes/RDBACK.TXT:161).
      // NP2kai has no handler for the port at all, so its
      // define-default 0xFF agrees. The `itf_stage` LATCH stays - it feeds
      // dbg_itf_stage and the watchdog's U= POST field, which is how the stage the
      // ITF stopped at is named - but the guest read must not expose it.
      hit[HX_0610]: lane_rdata = 8'hFF;
      // 0x0463: measured with the same eight values the 0x0461 sweep used, and
      // the same read-back rule: (value | 1), never the value. See the note on
      // win1_sel for why the map does not consume it.
      hit[HX_0463]: lane_rdata = win1_sel | 8'h01;
      hit[HX_063D]: lane_rdata = 8'hEC;
      hit[HX_063E]: lane_rdata = 8'hFE;
      hit[HX_063F]: lane_rdata = config_63f;
      hit[HX_0534]: lane_rdata = cpu_mode_strap;
      // Measured 0x1F at the DOS prompt. Bit 4 is the option-ROM window and bit 1
      // is the writable BIOS copy, the SAME bit the write arm takes it from, so a
      // read-modify-write round-trips the gate instead of silently setting it (the
      // old layout put it in bit 3 and hardwired bit 1 to 1). Bits 3, 2 and 0 are
      // straps read back 1; the top three bits are 0.
      hit[HX_053D]: lane_rdata = {3'b000, rom_gate_ide, 2'b11, bios_ram_gate, 1'b1};
      // The machine reads 0xFC: bits 7:2 are ones and only the 2-bit content
      // field is a latch, so the RMW idioms (`and 0xFC / or 3`, `and 3`) work.
      // Measured 0xFC: the low two bits read 00 even while the option ROM
      // is visible, so the readback does NOT mirror the internal selection.
      hit[HX_063C]: lane_rdata = pci_d8_select;
      // ---- ports the machine answers with a driven byte, measured 2026-09-12 ----
      //
      // 0x09A8: the 24/31 kHz select latch (its declaration has the capture). The
      // power-up read is the machine's `09A8=00 09A9=FF`.
      hit[HX_09A8]: lane_rdata = {7'b0, gdc_9a8_31k};
      // 0x98D7: the mouse IRQ register (Linux pc98 std_resources.c reserves it
      // as "mouse irq"). The machine reads 0x0D, twice, with no writes
      // (/MODE, `98D7=0D 0D`). NO firmware site reads it -- the ITF
      // only writes it (BANK4@0xFC991) -- so this arm is fidelity, not a boot
      // fix; the write stays accepted-and-ignored (its arm below).
      hit[HX_98D7]: lane_rdata = 8'h0D;
      // 0x0040 echoes lastData, the last byte written (NP2kai prt_i40,
      // io/printif.c:78-81): a write-then-read round-trips instead of answering
      // the constant 0x00. The power-up value is the
      // machine's capture (PORTS.TXT `0040 00`).
      hit[HX_0040]: lane_rdata = prt_last_data;
      // The 0x989x mode/clock register file, measured on the machine
      // (/MODE: every port read twice, no writes) as 0xF0 at both
      // ports. Bit 3 is the contract and it must read CLEAR -- the declaration
      // note above owns the reasoning. Whether a WRITE moves these bytes is
      // UNMEASURED; the firmware's only write site is unreachable on this core
      // because 0x534 reads 0xEC. Oracle: /MODEW, sec.5.
      hit[HX_9894]: lane_rdata = 8'hF0;
      hit[HX_9892]: lane_rdata = 8'hF0;
      // ---- the bus mouse's uPD8255 PPI (pc9821_mouse; NP2kai io/mouseif.c).
      // The whole read model - the button/nibble
      // composition of 0x7FD9, Port B's 0x40, Port C's masked latch and the
      // write-only 0x7FDF - is mouseif_i7fd9/i7fdb/i7fdd verbatim in that
      // module; the power-up composed answer is 0xEF (buttons 0xE0 with the
      // latch_x = -1 reset nibble, mouseif_reset:325-326).
      hit[HX_7FD9], hit[HX_7FDB], hit[HX_7FDD],
      hit[HX_7FDF]: lane_rdata = mouse_dout;
      // 0xA7 sits inside the CG-ROM port block (0xA1 code high, 0xA3 code low,
      // 0xA5 line, 0xA9 pattern), which the core already serves. POST drives it as
      // a byte port three times in BANK4 (0xFC103, 0xFC2F7, 0xFC2FB), so it is
      // real traffic. (The fourth site the notes name, BANK6@0x1DCB, is not a port
      // access: those bytes are the operand of the `call rel16` at 0x1DCA.) No
      // firmware site reads 0xA7, and the machine answers open bus there with no
      // writes (00A7=FF in all four captured states), so the read
      // is the measured 0xFF and carries no state.
      hit[HX_00A7]: lane_rdata = 8'hFF;
      // The DMA extended bank registers (QEMU hw/dma/pc98-dma.c marks them
      // write-only; NP2kai attaches output handlers only), the 0x0E00/0x0E02 word
      // pair and 0x0E0F, and the accelerator's 0xFAA/0xFAB index/data pair with its
      // 0xFAC relay latch have NO readable state in any reference and no machine
      // measurement, so they have no read arm and fall through to the open bus
      // below. Only their writes are decoded, so the guest-visible read is the same
      // 0xFF it would be undecoded.
      // Memory-switch register file (see the declaration): 0x530 is the address
      // latch, 0x531 the data byte it selects.
      // The EGC register file is WRITE-ONLY on the machine: the read-only snapshot
      // reads 0xFF at all sixteen ports (docs/probes/) and NP2kai
      // attaches out handlers only. The 0xFF this core already answered was
      // accidentally right; it stays.
      hit[HX_04A0], hit[HX_04A1], hit[HX_04A2], hit[HX_04A3],
      hit[HX_04A4], hit[HX_04A5], hit[HX_04A6], hit[HX_04A7],
      hit[HX_04A8], hit[HX_04A9], hit[HX_04AA], hit[HX_04AB],
      hit[HX_04AC], hit[HX_04AD], hit[HX_04AE], hit[HX_04AF]: lane_rdata = 8'hFF;
      // 0x18F0/0x18F2 (see the declaration). The select reads back; the data
      // port returns the byte the pointer addresses. The POINTER ADVANCE is in
      // the sequential block, next to the DMA flip-flop's, so this arm returns
      // the byte BEFORE the advance, which is what makes a word read return
      // {0x18F3, 0x18F2} in the order the firmware wrote them.
      hit[HX_18F0], hit[HX_18F1]: lane_rdata = unk_sel;
      hit[HX_18F2], hit[HX_18F3]: lane_rdata = unk_rdata;
      hit[HX_0530]: lane_rdata = msw_addr;
      hit[HX_0531]: lane_rdata = (cfg_seed_en && (msw_addr == 8'h79) && !msw_79_written)
                             ? msw_79_strap : msw_rdata;
      // 0xA460 (see the port list): the -86's board ID with the extension
      // latch in bit 0. The ID nibble is read-only -- writing the port can only
      // move bit 0, in both references -- so this is the strap ORed with the
      // latch, not the last byte written.
      hit[HX_A460]: lane_rdata = 8'h40 | {7'b0, sound_extend};
      // The twelve software-DIP data ports read their stored byte verbatim -- no
      // parity bit is forced (see the store's comment beside sdip_data_mask for
      // the capture that refutes the recompute and the one port it measures).
      // THE ONE EXCEPTION IS BANK A INDEX 1: bit 4 there is the register's OWN
      // parity bit and is presented from the reset-qualified strap
      // (sdip_read_byte, above). That is not a guest byte, so read-back verbatim
      // is not what it is about - the ITF's merge requires the bit and no write
      // can own it.
      default:  lane_rdata = sdip_data_port ? sdip_read_byte : 8'hFF;
    endcase
  end

  // The last-I/O-access latch: the port, the byte and the direction of the most recent access,
  // captured where that access LANDS so the byte is the one the CPU received (or the guest
  // wrote). A write lands in S_BYTE; a read lands in S_BYTE too, except for a device that asks
  // for the extra read cycle (device_rd_wait), whose data only becomes valid in S_DEVWAIT - the
  // same reason the read capture above is split across those two states.
  always @(posedge clk) begin
    if (reset) begin
      dbg_last_io_addr <= 16'd0;
      dbg_last_io_data <= 8'd0;
      dbg_last_io_rd   <= 1'b0;
      dbg_last_io_wr   <= 1'b0;
    end else if (state == S_BYTE &&
                 !(device_port && !request_write && device_rd_wait)) begin
      dbg_last_io_addr <= port_addr;
      dbg_last_io_data <= request_write ? lane_wdata : lane_rdata;
      dbg_last_io_rd   <= !request_write;
      dbg_last_io_wr   <= request_write;
    end else if (state == S_DEVWAIT) begin
      dbg_last_io_addr <= port_addr;
      dbg_last_io_data <= lane_rdata;
      dbg_last_io_rd   <= 1'b1;
      dbg_last_io_wr   <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      cpu_dout <= 32'hFFFF_FFFF;
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      base_addr <= 32'd0;
      write_data <= 32'd0;
      pending_be <= 4'd0;
      request_write <= 1'b0;
      read_data <= 32'hFFFF_FFFF;
      term7c_hi <= 1'b0;
      top_bank <= BANK_ITF;
      ems_state <= 2'd0;
      top_shadow_en <= 1'b0;
      // The option-ROM window is OPEN from reset on a non-PCI machine, which is
      // what this core models. QEMU pc98_mem_reset: `ide_rom_gate = has_pci ? 0
      // : 1`, with the comment "the BX2 firmware expects the IDE ROM visible
      // from reset". The authentic ITF proves it: its early code copies 8 KiB
      // out of 0xD8000 *before* it ever writes 0x53D, and with the gate shut it
      // copies zeros and fails its own AA55 check at BANK4@0xFC681 -- which is
      // what stopped the authentic boot.
      rom_gate_ide <= 1'b1;
      bios_ram_gate <= 1'b0;
      // Measured 0xFE at the DOS prompt = gate off. The ITF does not rely on
      // this reset: it writes 0x81 itself (BANK4 offset 0x9BF7).
      ide_ram_gate <= 1'b0;
      // The window select resets to the IDE option ROM. On the Xe10 that is
      // bits 1-0 = 00 (the machine reads FC, and selects 0 and 2 both show the
      // IDE ROM: docs/probes/D8BANK-XE10.TXT); QEMU's DWIN_IDE = 1 is a different
      // encoding - on the Xe10 select 1 is BANK0.BIN's first half. The authentic
      // ITF's non-PCI path writes only 0x53D = 0x10 before copying 8 KiB out of
      // 0xD8000, so the reset bank must be the IDE ROM or no INT 1Bh handler is
      // ever installed.
      pci_d8_select <= 8'hFC;
      system_port_c <= 8'hB8;   // measured 0x35 = 0xB8 (was 0xF9)
      gdc_ff2 <= 8'h00;
      gdc_ff2_written <= 1'b0;   // the un-written read is the machine's 0x01
      gdc_9a8_31k <= 1'b0;       // the machine's power-up `09A8=00`
      prt_last_data <= 8'h00;    // the machine's `0040 00`
      prt_i44_data  <= 8'h81;    // the machine's `0044 81`
      prt_select_count <= 4'd0;
      prt_select_busy  <= 1'b0;
      // A20 comes up MASKED. On the PC-98 the gate clears physical bit 20 (the
      // Xe10's A20MAP verdict BIT20-ONLY, docs/probes/A20MAP-XE10.TXT; NP2kai and
      // QEMU model it as a 1 MiB wrap) and power-on leaves it closed: NP2kai's CPU reset sets CPU_ADRSMASK = 0x000fffff
      // (i386c/ia32/interface.c:87) and QEMU's PC-98 CPU resets a20_mask to
      // 0xfffff (target/i386/cpu.c:9421, the pc98-a20-mask property). The
      // authentic ITF depends on it: its ADDRESS 20 LINE check at BANK4@0xF8358
      // writes 1 MiB and requires the read at physical 0 to match, and no
      // 0xF2/0xF6 write precedes it anywhere in the ROM set (the first is the
      // ITF's own BANK4@0xF8589). The gate is moved only by 0xF0/0xF2/0xF6.
      a20_enable <= 1'b0;
      cpu_reset_req <= 1'b0;
      unmapped_writes <= 16'd0;
      unmapped_reads <= 16'd0;
      last_unmapped_port <= 16'd0;
      post_code <= 8'd0;
      post_write <= 1'b0;
      sdip_ctrl <= 8'd0;
      sys16m_en_q  <= 1'b0;   // hole OFF out of reset: 15-16 MiB is RAM until the guest asks
      cpu_mode_strap <= 8'hEC;   // QEMU pc98_cpu_mode_read
      msw_addr <= 8'h00;
      config_436 <= 8'h04;
      config_439 <= 8'hB4;
      config_63f <= 8'h6C;
      latch_149  <= 8'h00;
      // The -86 extension bank is closed out of reset: 0x18C/0x18E answer
      // 0xFF until a 0xA460 bit-0 write opens it (NP2kai).
      sound_extend <= 1'b0;
      win0_sel   <= 8'h08;       // the identity the firmware restores
      win0_sel_moved <= 1'b0;    // (8'h08 != 8'h08)
      win1_sel   <= 8'h0A;       // QEMU win_map[1] resets to 0x0a; measured 0x0B
      itf_stage  <= 8'h00;
      // Power-up values are NP2kai's egc_reset() (mem/memegc.c:69-80):
      // access 0xFFF0 (all four planes enabled -- the field is active low),
      // fgbg 0x00FF (read plane B, no colour-register pattern select, so the
      // mask register IS writable), mask 0xFFFF, leng 0x000F, ope/fg/bg/sft 0.
      egc_access <= 16'hFFF0;
      egc_fgbg   <= 16'h00FF;
      egc_ope    <= 16'h0000;
      egc_fg     <= 16'h0000;
      egc_mask   <= 16'hFFFF;
      egc_bg     <= 16'h0000;
      egc_sft    <= 16'h0000;
      egc_leng   <= 16'h000F;
      egc_shift_we <= 1'b0;
      artic_phase <= {ARTIC_W{1'b0}};
      artic_cnt   <= 32'd0;
      artic_pend  <= 1'b0;
      // The DIP store's addressed walk is NOT reset here: it must be able to run during
      // this reset window (THE MACHINE-RESET SEED beside the store owns it, with its own power-up
      // values). Resetting it here would clear every step the seed walk takes.
      for (i = 0; i < 4; i = i + 1) begin
      end
      // The bank and bound latches' power-up bytes: the machine's AS-FOUND AT THE
      // DOS PROMPT (RDBACK.TXT:153-157, PORTS.TXT:169-172), not chip reset values.
      // 0x25's 0x0E is ONE sample on the channel DOS's own transfers use; the
      // other three read 0x00 there and so does 0x29. The latch itself is what the
      // capture proves (write A5 -> read 05); see the declaration above.
      // The bank bytes are indexed BY CHANNEL, so these seeds are the ports'
      // as-found bytes (RDBACK.TXT:153-156 `port=0025 before=0E`,
      // PORTS.TXT:170 `0025%0E`) placed on the channel each port maps to: 0x21->1,
      // 0x23->2, 0x25->3, 0x27->0. Read through the ports they are therefore
      // unchanged: 00, 00, 0E, 00.
    end else begin
      // ARTIC free-running counter (see the declaration).
      if (artic_tick) artic_phase <= artic_wrap;
      else            artic_phase <= artic_sum[ARTIC_W-1:0];
      // The tick and the deferred tick merge into one next-state (R4): frozen, a tick only
      // sets the pending bit; free, the counter takes this cycle's tick plus any pending one.
      if (artic_freeze) begin
        if (artic_tick) artic_pend <= 1'b1;
      end else begin
        artic_cnt  <= artic_cnt + {31'd0, artic_tick} + {31'd0, artic_pend};
        artic_pend <= 1'b0;
      end
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      // The addressed walk's HOLD: while the 24-byte walk is running the CPU is kept in its reset
      // class, so its first DIP read cannot land on a half-seeded bank. It is a no-op in every
      // real reset window (the seed walk finishes inside it -- see THE MACHINE-RESET SEED) and it
      // also covers a front-panel OSD action's walk. The two one-shot requests below still
      // outrank this default when they fire.
      cpu_reset_req <= sdip_seq_active;
      post_write <= 1'b0;
      egc_shift_we <= 1'b0;

      case (state)
        S_IDLE: begin
          if (cpu_valid) begin
            base_addr <= {cpu_addr[31:2], 2'b00};
            write_data <= cpu_din;
            pending_be <= access_be_walk;
            request_write <= cpu_write;
            // A 16-bit-or-wider READ at 0x7C whose chunk takes in lane 1.
            term7c_hi <= access_term7c;
            read_data <= 32'hFFFF_FFFF;
            // The port is the lane address (cpu_addr carries the base and the
            // lane select rides in the byte enables), and EVERY lane the access fetches
            // pays its own class (io_access_hold), because on the machine each byte of a
            // multi-byte access is a bus cycle of its own.
            /* verilator lint_off WIDTHTRUNC */   // io_access_hold returns at most 16'd2422 of 4095 (profile 2 at 120 MHz: `in eax,0x4A0` over the EGC register file, 1115 + 99 + 1115 + 99 = 2428 cycles, less the FSM's own), so it always fits io_hold's 12 bits; the min profile's maximum is far below it
            io_hold <= io_access_hold(cpu_addr[15:0] & 16'hFFFC,
                                      access_be_walk, access_be_fetch, cpu_write);
            /* verilator lint_on WIDTHTRUNC */
            state <= S_IOWAIT;
          end
        end

        // The bus-time hold. The address, byte enables and data are already
        // registered, and no device strobe is issued here (device_io_wr/rd
        // require S_BYTE), so the access is simply made to take its time. The
        // CPU holds cpu_valid until cpu_ready, so the guest stalls in the
        // access exactly as it would on the machine. A device write that the
        // device cannot accept (device_wr_wait: the OPNA queue's or the 86-PCM
        // FIFO's back-pressure) stalls HERE, before the S_BYTE strobe, so the
        // write is presented exactly once and never dropped - the same idea as
        // device_rd_hold holding S_DEVWAIT. Reads keep their one-cycle timing.
        S_IOWAIT: begin
          // A device write that the device cannot accept stalls HERE, before the
          // S_BYTE strobe, so the write is presented exactly once and never
          // dropped (device_wr_wait). Reads keep their one-cycle timing.
          //
          // The wait is re-checked EVERY CYCLE once the bus-time hold has
          // expired: io_hold HOLDS at zero rather than wrapping 0 -> 2047, which
          // would quantize the re-check to 2048-cycle chunks and leave a freed
          // device waiting up to 2047 dead cycles (the shortest-stall rule). The bus-time class hold itself is untouched.
          if (io_hold == 12'd0) begin
            if (!(device_port && request_write && device_wr_wait)) state <= S_BYTE;
          end else begin
            io_hold <= io_hold - 12'd1;
          end
        end

        S_BYTE: begin
          // The byte count is decremented when the data lands, so the lane and
          // address stay put across a wait.
          if (device_port && !request_write && !flush_required &&
              device_rd_wait) begin
            state <= S_DEVWAIT;
          end else begin
          pending_be <= pending_be & ~lane_mask;
          // The 0x18F2/0x18F3 window pointer advances on EVERY access, read or
          // write, exactly one byte per access -- so a 16-bit `out dx,ax` moves it
          // twice and the two bytes land in consecutive cells, which is the shape
          // the firmware's write-then-read-back requires (see the declaration).
          if ((state == S_BYTE) && unk_port) unk_ptr <= unk_ptr + 6'd1;
          if (!device_port && !system_port) begin
            last_unmapped_port <= port_addr;
            if (request_write) begin
              if (unmapped_writes != 16'hFFFF)
                unmapped_writes <= unmapped_writes + 16'd1;
            end else if (unmapped_reads != 16'hFFFF) begin
              unmapped_reads <= unmapped_reads + 16'd1;
            end
          end
          if (request_write) begin
            // A flush trigger does not pulse from this arm: the shared launch
            // site beside `flush_required` turns `flush_trig` (this S_BYTE visit)
            // into the one cache_flush_req pulse, so the FSM cannot launch twice
            // for one walk (R4).
            case (1'b1) // synthesis parallel_case
              // 0x043D: flip the window between the ITF and the top BIOS
              // bank. Matches QEMU pc98 mem_bankflip_write (0x00/0x10/0x18 ->
              // ITF, 0x02/0x12 -> top BIOS); NP2kai's CPU_ITFBANK naming is
              // inverted relative to this but describes the same behaviour.
              hit[HX_043D]: begin
                case (lane_wdata)
                  8'h00, 8'h10, 8'h18: top_bank <= BANK_ITF;
                  8'h02, 8'h12: top_bank <= BANK_BIOS_TOP;
                  default: ;
                endcase
              end
              // 0x043F: direct bank selection for the same window, which is
              // what makes the eight 32 KiB ROM banks reachable. QEMU's
              // mem_bankctl_write: case 0xe0 -> top_bank = (data >> 1) & 7.
              // The 0x20 nibble addresses the EMS page window (ems_state, above); the
              // other nibbles are ROM selects, the cache flush and the mode straps.
              hit[HX_043F]: begin
                // The 0x8 nibble is the top-window shadow enable; every other nibble's
                // state is set below exactly as before.
                top_shadow_en <= next_top_shadow_en;
                if (lane_wdata[7:4] == 4'hE) begin
                  top_bank <= {1'b0, lane_wdata[3:1]};
                end else if (lane_wdata[7:4] == 4'h2) begin
                  // The low nibble chooses which of the three measured states the window
                  // takes (see the ems_state declaration). 0x20 is the identity, so it is
                  // the state that must NOT divert the planes.
                  ems_state <= (lane_wdata[3:0] == 4'h0) ? 2'd0 :
                               (lane_wdata[3:0] == 4'h2) ? 2'd1 : 2'd2;
                end
                // Every OTHER nibble leaves ems_state alone: qemu's
                // mem_bankctl_write acts only on 0x20 (EMS) and 0xE0 (bank)
                // (pc98-mem.c:684-701), so 0x80 (the shadow enable above) / 0xA0
                // (the 486 cache flush the firmware emits before every `mov cr0`)
                // / 0xC4 fall through with the EMS window untouched - an
                // EMM386-style driver that enables 0x22 and then toggles paging
                // keeps its page (tb_pc9821_ems pins it).
              end
              hit[HX_0035]: system_port_c <= lane_wdata;
              hit[HX_0037]: if (lane_wdata[7:4] == 4'd0) begin
                if (lane_wdata[0])
                  system_port_c <= system_port_c |
                                   (8'b0000_0001 << lane_wdata[3:1]);
                else
                  system_port_c <= system_port_c &
                                   ~(8'b0000_0001 << lane_wdata[3:1]);
                // Port C is a plain 8255 BSR latch: the BSR byte only sets or resets
                // the bit the 0x35 read-back shows. It is NOT a second A20 control,
                // and driving A20 from it breaks the authentic ITF: its second
                // protected-mode block RELEASES the gate with `out 0xF2,0` /
                // `out 0xF6,2` (BANK4@0xF8952/0xF8956) and then pulses port C bit 4
                // with the BSR bytes 0x09/0x08 around its extended-memory walk,
                // masking that walk's 128 KiB zero-fill onto physical 0-0x1FFFF and
                // destroying the GDT image at 0x8000 and the IDT at 0x9000 it had
                // just installed. Neither reference connects port C to the gate.
              end
              hit[HX_053D]: begin
                rom_gate_ide <= lane_wdata[4];
                bios_ram_gate <= lane_wdata[1];
              end
              hit[HX_063C]: pci_d8_select <= lane_wdata;
              hit[HX_00F0]: begin
                // `out 0xF0,<n>`: the CPU-mode reset, a CPU-ONLY reset. NP2kai's handler
                // is unconditional (io/cpuio.c cpuio_of0 latches the CPU mode, clears A20,
                // raises CPU_RESETREQ, discards the data byte) and CPU_RESETREQ is CPU_SHUT
                // plus the IDE/host/PCI base resets, not a whole-machine reset; QEMU's 8255
                // port-C "arm" bits are its model alone. After it the CPU returns through
                // the reset vector of whichever bank is mapped at 0xF8000 (BANK4@0xFA67D)
                // and the firmware resumes on a frame it saved in RAM, so RAM, the stack
                // and the ROM window must survive -- which is why the narrow reset is right.
                //
                // NOT modelled deliberately: NP2kai also re-inits the IDE base
                // (`ideio_basereset`), invisible to every tier we have.
                cpu_reset_req <= 1'b1;
                a20_enable <= 1'b0;
              end
              hit[HX_00F2]: a20_enable <= 1'b1;
              // A20 mask: ONLY 0x02 (release) and 0x03 (mask) act. NP2kai cpuio_of6
              // `switch(dat) { case 0x02: ... case 0x03: ... }` and MAME pc9801.cpp
              // a20_ctrl_w (`if(data == 0x02) ... else if(data == 0x03) ... else
              // logerror(...unmapped data write...)`) agree, and no capture contradicts
              // them; the bit-1 decode that stood here also acted on 0x5E, the byte the
              // port reads back. tb_pc9821_iobus.
              hit[HX_00F6]: if (lane_wdata[7:1] == 7'h01) a20_enable <= ~lane_wdata[0];
              hit[HX_0EE0]: begin
                post_code <= lane_wdata;
                post_write <= 1'b1;
              end
              hit[HX_0090], hit[HX_0092], hit[HX_0094],
              hit[HX_00C8], hit[HX_00CA], hit[HX_00CC], hit[HX_04BE],
              hit[HX_00BE], hit[HX_00BF]: ;  // FDC writes are consumed by pc9821_fdc
              // Bit 2 SET asks for RAM at 15-16 MiB, so the hole enable is its INVERSE (qemu
              // `enable = !(data & 0x04)`; NP2kai #107's debug print agrees). The ITF's own
              // stage-0x25 write of 0x04 at 0xF8906 is that request, immediately before its
              // memory test - reading the bit straight through put the hole exactly where the
              // test wanted RAM, which is the MEMORY ERROR at 0x00F00000.
              hit[HX_043B]: sys16m_en_q <= ~lane_wdata[2];
              // Bit 0 round-trips with the read, which is what makes the IDE
              // ROM's save/0x81/restore idiom (BANK3 offsets 0xDA9/0xDB7)
              // idempotent. QEMU accepts only the exact bytes 0x80/0x81
              // (pc98-mem.c:788-801); bit 0 is equivalent for every value the
              // firmware writes or reads back.
              hit[HX_1E8E]: ide_ram_gate <= lane_wdata[0];
              // 0x9A0: the ff2 query INDEX (NP2kai gdc_o9a0 stores dat,
              // io/gdc.c:963-967). The read is the query - see its arm above.
              hit[HX_09A0]: begin
                gdc_ff2 <= lane_wdata;
                gdc_ff2_written <= 1'b1;
              end
              // 0x9A8: the latch (see its declaration).
              hit[HX_09A8]: gdc_9a8_31k <= lane_wdata[0];
              // 0x5F is the firmware's I/O wait on the write side.
              hit[HX_005F]: ;
              // Write-only in every observed firmware site: accepted and
              // ignored so the unmapped-write counter stays meaningful.
              hit[HX_98D7], hit[HX_09AE],
              // The bus mouse's uPD8255 PPI latches and its 0xBFDB timer port
              // are consumed by pc9821_mouse on the same strobe (the three
              // latches, the 8255 control word's mode and bit set/reset forms,
              // and the timing field - NP2kai mouseif_o7fd9/o7fdb/o7fdd/o7fdf
              // and mouseif_obfdb, io/mouseif.c:179-218, 309-312).
              hit[HX_7FD9], hit[HX_7FDB], hit[HX_7FDD], hit[HX_7FDF],
              hit[HX_BFDB]: ;
              // The printer port trio (NP2kai prt_o40/prt_o44, io/printif.c:44-76):
              // 0x40 stores lastData (and runs the SELECT-BUSY workaround - seven
              // consecutive DC1 bytes arm the one-shot busy 0x42's read clears),
              // 0x44 the strobe latch. Both echo on read (their arms above).
              hit[HX_0040]: begin
                prt_last_data <= lane_wdata;
                if (lane_wdata == 8'h11) begin
                  if (prt_select_count > 4'd5) prt_select_busy <= 1'b1;
                  else prt_select_count <= prt_select_count + 4'd1;
                end else prt_select_count <= 4'd0;
              end
              hit[HX_0044]: prt_i44_data <= lane_wdata;
              // The devices decoded above. None is modelled: the CG-ROM block's 0xA7
              // (BANK4@0xFC103, 0xFC2F7, 0xFC2FB), the DMA extended bank registers
              // and 0x0E0F (BANK4@0xFCB81-0xFCB9E, BANK2@0x0005), and the
              // accelerator's index/data pair with its relay latch (BANK4@0xFD27B
              // writes 0xFAC, and 0xFD28F/0xFD3AE/0xFD3C6/0xFD3E4 write the 0xFAA
              // pair as a 16-bit `out dx,ax`, so 0xFAB is the pair's high byte).
              hit[HX_00A7],
              hit[HX_0E00], hit[HX_0E02], hit[HX_0E05], hit[HX_0E07],
              hit[HX_0E09], hit[HX_0E0B], hit[HX_0E0F],
              hit[HX_0FAA], hit[HX_0FAB], hit[HX_0FAC]: ;
              // The ITF's clock pair (BANK4@0xFCAF5). Writing 0x9894 must not
              // move what the read answers (see the declaration): the measured
              // datum is the machine's no-write read 0xF0, and whether a write
              // moves it is unmeasured until /MODEW runs. 0x98E0 is not
              // decoded, on purpose.
              hit[HX_9894], hit[HX_9892]: ;
              // The EGC register file. Every write is gated by the EGC enable
              // (NP2kai egc_o4a0 checks `vramop.operate & (1<<VOPBIT_EGC)` before
              // it does anything, so a guest that writes 0x4A4 without enabling
              // the EGC sees no effect), and the MASK register is gated again by
              // the foreground/background colour field: while 0x4A2's bits 13-14
              // are non-zero the mask register is not writable (egc_o4a0 case
              // 0x08/0x09). The firmware relies on exactly that -- BANK7@0x35A1
              // sets 0x4A2 = 0x40FF and never touches 0x4A8.
              //
              // The two COLOUR registers are gated the other way: 0x4A6/0x4AA (FG/BG)
              // accept a write only while 0x4A2's bits 13-14 name FG or BG, and are
              // ignored while the pattern comes from the PAT registers (00) -- the EGC
              // conformance suite v1.3 words it as "FG/BG writes are performed only
              // after selecting FG/BG in port 04A2h", and its W00_FG_x/W01_BG_x rows show
              // the retained FG/BG surviving an 0x4A6/0x4AA write made under PAT
              // (docs/probes/egc-conformance/, EGCWRITE.CSV). NP2kai has no such gate
              // (egc_o4a0 case 0x06/0x0a write egc.fg/egc.bg unconditionally), and the
              // 11 (reserved) selector's routing is not pinned by any PASS row.
              hit[HX_04A0]: if (egc_gate) egc_access[7:0]   <= lane_wdata;
              hit[HX_04A1]: if (egc_gate) egc_access[15:8]  <= lane_wdata;
              hit[HX_04A2]: if (egc_gate) egc_fgbg[7:0]     <= lane_wdata;
              hit[HX_04A3]: if (egc_gate) egc_fgbg[15:8]    <= lane_wdata;
              hit[HX_04A4]: if (egc_gate) egc_ope[7:0]      <= lane_wdata;
              hit[HX_04A5]: if (egc_gate) egc_ope[15:8]     <= lane_wdata;
              hit[HX_04A6]: if (egc_gate && (egc_fgbg[14:13] != 2'b00))
                          egc_fg[7:0]   <= lane_wdata;
              hit[HX_04A7]: if (egc_gate && (egc_fgbg[14:13] != 2'b00))
                          egc_fg[15:8]  <= lane_wdata;
              hit[HX_04A8]: if (egc_gate && (egc_fgbg[14:13] == 2'b00))
                          egc_mask[7:0]  <= lane_wdata;
              hit[HX_04A9]: if (egc_gate && (egc_fgbg[14:13] == 2'b00))
                          egc_mask[15:8] <= lane_wdata;
              hit[HX_04AA]: if (egc_gate && (egc_fgbg[14:13] != 2'b00))
                          egc_bg[7:0]   <= lane_wdata;
              hit[HX_04AB]: if (egc_gate && (egc_fgbg[14:13] != 2'b00))
                          egc_bg[15:8]  <= lane_wdata;
              hit[HX_04AC]: if (egc_gate) begin
                 egc_sft[7:0] <= lane_wdata;
                 egc_shift_we <= 1'b1;
               end
              hit[HX_04AD]: if (egc_gate) begin
                 egc_sft[15:8] <= lane_wdata;
                 egc_shift_we <= 1'b1;
               end
              hit[HX_04AE]: if (egc_gate) begin
                 egc_leng[7:0] <= lane_wdata;
                 egc_shift_we <= 1'b1;
               end
              hit[HX_04AF]: if (egc_gate) begin
                 egc_leng[15:8] <= lane_wdata;
                 egc_shift_we <= 1'b1;
               end
              // Memory-switch register file (see the declaration). The array writes are in
              // the port block beside each declaration; these arms keep only the state the
              // array does not hold.
              hit[HX_18F0]: begin unk_sel <= lane_wdata; unk_ptr <= 6'd0; end
              hit[HX_18F2], hit[HX_18F3]: ;
              hit[HX_0530]: msw_addr <= lane_wdata;
              // The guest's own byte for the one cell this core seeds: NOT cleared by the
              // reset arm, deliberately - it has to outlive a reset, as the array does.
              hit[HX_0531]: if (msw_addr == 8'h79) msw_79_written <= 1'b1;
              hit[HX_0610]: itf_stage  <= lane_wdata;
              hit[HX_0436]: config_436 <= lane_wdata;
              hit[HX_0439]: config_439 <= lane_wdata;
              hit[HX_063F]: config_63f <= lane_wdata;
              hit[HX_0461]: begin
                win0_sel       <= next_win0;
                win0_sel_moved <= (next_win0 != 8'h08);
              end
              hit[HX_0463]: win1_sel   <= lane_wdata;
              hit[HX_0149]: latch_149  <= lane_wdata;
              // 0xA460: bit 0 is the -86 extension enable (see the port list
              // and the read arm in lane_rdata). Nothing else about the port is
              // modelled: the ID nibble is a strap and the write cannot move it.
              hit[HX_A460]: sound_extend <= lane_wdata[0];
              // 0x534 bit 0 = soft reset request (see the declaration).
              hit[HX_0534]: if (lane_wdata[0]) begin
                cpu_reset_req <= 1'b1;
                a20_enable <= 1'b0;
              end
              // 0x31: the ITF writes the complement of an SDIP image byte here
              // (BANK4@0x46AB/0x47D7/0x4AE9) and then reads the *strap* back
              // later in the same routine (BANK4@0x46D2), so latching the write
              // would make the ITF's own bit-4 merge self-defeating. The read
              // stays the measured constant 0xF3; the write is ignored.
              hit[HX_0031]: ;
              default: begin
                if (sdip_ctrl_port) begin
                  sdip_ctrl <= lane_wdata;
                end
                // The 0x..1E data write itself is the store's one write port, beside the array
                // (sdip_guest_we/sdip_guest_data): only the writable bits are stored there,
                // the strap bits keeping the power-up image's values, which is
                // how a real machine behaves (the straps are not software-visible).
              end
            endcase
          end else begin
            read_data[{lane, 3'b000} +: 8] <= (term7c_hi && (lane == 2'd1))
                                            ? 8'h00 : lane_rdata;
            // The read side effects: 0x11 clears
            // dmac.stat's low nibble on the read (NP2kai dmac_i11,
            // io/dmac.c:290-295) and 0x42 consumes its one-shot SELECT-BUSY
            // (prt_i42, io/printif.c:83-112). Exactly once per access, here at
            // S_BYTE where the byte is captured.
            if (hit[HX_0042]) prt_select_busy <= 1'b0;
          end
          state <= flush_required ? S_FLUSH :
                   (last_lane ? S_REPLY : S_BYTE);
          end
        end

        S_DEVWAIT: begin
          // device_io_rd was a one-cycle pulse during S_BYTE, so a device that
          // acts on the strobe (a status read clearing an interrupt, say) acts
          // exactly once; only the data capture moves a cycle later. A device
          // that sets device_rd_hold keeps this state: the capture (and the
          // pending-be clear) happens on the cycle it drops, so the byte read is
          // the one the device presents at that point, not a stale one.
          if (!device_rd_hold) begin
            read_data[{lane, 3'b000} +: 8] <= lane_rdata;
            pending_be <= pending_be & ~lane_mask;
            state <= last_lane ? S_REPLY : S_BYTE;
          end
        end

        S_FLUSH: if (flush_done)
          state <= last_lane ? S_REPLY : S_BYTE;

        S_REPLY: begin
          cpu_dout <= read_data;
          cpu_ready <= 1'b1;
          cpu_resp_valid <= !request_write;
          state <= S_HOLD;
        end

        // One cycle only: the accept (a write) or the accept+response (a read) was
        // delivered in S_REPLY. It must NOT wait for cpu_valid to deassert -- a
        // pipelined CPU need not present one request per valid, and two back-to-back
        // accesses to this port with valid held would deadlock here. See
        // pc9821_memory_subsystem.sv's responder contract; the same state is implemented the same
        // unconditional way in pc9821_window_responder.sv:331 (S_HOLD: state <= S_IDLE) -- the one
        // engine of the TRAM and CG windows -- in
        // pc9821_open_bus.sv:73 (S_HOLD: state <= S_IDLE) and
        // pc9821_grcg.sv:511 (G_HOLD:  gstate <= G_IDLE) - each file's one-cycle unconditional hold
        // ARM, which is the anchor, not the accept state it is entered from.
        //
        // The bubble is PROTOCOL, and z486 asserts it: its ext_valid_r clears on the
        // accept edge (src/z486/bus_unit.sv:350 `ext_valid_r <= 1'b0`), so the CPU cannot
        // re-present in the very next cycle
        // -- there is a one-cycle gap in which this state runs. R8's check below pins
        // that no request is taken twice, which is what makes the unconditional exit
        // safe: the guarantee is ASSERTED rather than relied on.
        S_HOLD: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase

      // The CPU's own shutdown is its CPU-RESET class, exactly as `out 0xF0`
      // and 0x534 are: re-raise the CPU-reset request (pc9821_system's
      // pc9821_cpu_reset_gate turns it into the platform's 16-cycle hold) and mask
      // A20 so the CPU re-enters through the masked reset vector, which is the
      // state the firmware's resume frame expects. WARM, not a platform reset:
      // only `cpu_reset_req` and `a20_enable` move, so RAM, the ROM window, the
      // latches and the peripherals survive -- the main BIOS resumes through
      // the frame at BANK7@0xFD867 and the ITF through its retf at 0xFC11B.
      // Placed after the case so it overrides a device write in the same cycle.
      if (triple_fault_reset) begin
        cpu_reset_req <= 1'b1;
        a20_enable    <= 1'b0;
      end
    end
  end

`ifdef VERILATOR
  // ---------------------------------------------------------------------------
  // R6/R8: THE UNCONDITIONAL BUBBLE'S CONTRACT (docs/single-cycle-event-discipline.md
  // R6/R8). S_HOLD is one cycle by construction - it does not observe
  // cpu_valid - and that is safe only because the CPU drops its request for the
  // gap cycle. Both halves are pinned here rather than left to the comment; they
  // cost nothing in synthesis and run in every bench that builds this module.
  // ---------------------------------------------------------------------------
  reg hold_q;       // S_HOLD last cycle: the state is one cycle wide, never two
  reg win0_reset_seen;   // a reset has loaded win0_sel and its flag (Verilator powers it up 0)
  always @(posedge clk) if (reset) win0_reset_seen <= 1'b1;
  reg req_live;     // S_IDLE took a request and cpu_valid has not gone low since
  always @(posedge clk) begin
    if (reset) begin
      hold_q   <= 1'b0;
      req_live <= 1'b0;
    end else begin
      // win0_sel_moved is the registered `win0_sel != 8'h08` the memory map reads in place of the
      // compare (proven by tools/check_win0_moved_inv.py; pinned here in every bench). From the
      // first reset on: before it both power up 0, which is not a state the core runs in.
      if (win0_reset_seen && (win0_sel_moved != (win0_sel != 8'h08)))
        $error("pc9821_iobus: win0_sel_moved=%b disagrees with win0_sel=%02x", win0_sel_moved, win0_sel);
      // ARTIC's deferral holds ONE tick (R7/R8): a second tick inside one frozen access
      // would be lost.
      if (artic_freeze && artic_tick && artic_pend)
        $error("pc9821_iobus: a second ARTIC tick inside one 0x5C-0x5F access - the deferral holds one");
      // (1) ONE CYCLE. A second S_HOLD cycle means a level wait came back.
      if ((state == S_HOLD) && hold_q)
        $error("pc9821_iobus: S_HOLD lasted more than one cycle - the bubble must not observe cpu_valid (R6)");
      // (2) NO REQUEST TAKEN TWICE (the producer's guarantee). An accept is followed
      //     by a gap: src/z486/bus_unit.sv:350 `ext_valid_r <= 1'b0` clears it at the ready edge,
      //     so a held level reaching S_IDLE again would mean the CPU never released
      //     and the same access is being served a second time.
      if ((state == S_IDLE) && cpu_valid && req_live)
        $error("pc9821_iobus: cpu_valid was never released between two I/O accesses - the CPU's accept gap is what the unconditional S_HOLD bubble rests on (R6/R8)");
      hold_q <= (state == S_HOLD);
      if (!cpu_valid)         req_live <= 1'b0;
      else if (state == S_IDLE) req_live <= 1'b1;
    end
  end
`endif

  // ==================== THE ONE DEVICE-BUS DECODE =========================
  // The chip selects and the bus claim are one decode, over this fabric's own latched port
  // address (see dev_bus_cs's header in pc9821_device_select.sv). Nothing here is registered:
  // device_io_addr is `port_addr`, which the access FSM already holds stable for the whole
  // access, so the selects are valid in the access's own cycle. The claim stays inside this file (device_port above): nothing
  // outside needs it, only the chip selects cross the port list.
  wire dev_bus_cs;
  pc9821_device_select #(.MPU_EN(MPU_EN), .SDRAM_PHASE_DYN(SDRAM_PHASE_DYN)) u_device_select (
      .addr(device_io_addr),
      .pic_master_cs(pic_master_cs), .pic_slave_cs(pic_slave_cs), .pit_cs(pit_cs),
      .interrupt_cs(interrupt_cs), .cal_cs(cal_cs), .kbd_cs(kbd_cs),
      .ata_cs(ata_cs), .opna_cs(opna_cs), .pcm_cs(pcm_cs), .gameport_cs(gameport_cs),
      .mpu_cs(mpu_cs), .sdph_cs(sdph_cs), .dev_bus_cs(dev_bus_cs), .gdc_cs(gdc_cs)
  );

endmodule

`default_nettype wire
