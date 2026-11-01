// Floppy MEDIA for pc9821_fdc: a D88 or raw sector image served over a byte seam.
//
// The controller half (pc9821_fdc) owns the 765 command engine, this module owns the
// image. TWO DRIVES, each with its own hps_io image slot, read AND written (Stage B: a
// WRITE DATA sector is located exactly as a read, its bytes overwrite the resident block
// buffer, and every block it touches is written back to the image - see WRITES below).
//
// WHY TWO DRIVES SHARE THIS MODULE rather than being two instances of it. The machine
// equips two drives (NP2kai's MAX_FDDFILE = 4, io/fdc.h:76-105: one `_FDDFILE` per drive
// with its own treg[4]/rpm[4]/stat[4] beside it) and the controller serves ONE of them at
// a time: a command names its unit and the byte seam below carries exactly that unit
// (pc9821_fdd_media's `unit`, pc9821_fdc's media_unit/x_us), so a request for drive 0 is
// finished - the controller has drained its sector - before any request for drive 1 is
// issued. What therefore has to exist TWICE is only what SURVIVES a request: each drive's
// mount, its format decision, its geometry and its D88 track table. The byte stream, the
// D88 walk and the FSM it runs in are one engine, because two of them would be two copies
// of logic the controller never exercises concurrently (the same reading that made the HPS
// block adapter ONE engine behind pc9821_block_share, T9). Per-drive state is marked
// "[u]" below and indexed by that unit; everything else is the request in flight.
//
// WHAT THE TWO DRIVES SHARE, and why that is the model's shape and not a shortcut: the
// engine. A mount of one drive while the other is being read is DEFERRED (the walk begins
// when the engine is idle - see the mount latch), so a mount can never abort or corrupt a
// transfer in progress, which is also what keeps the controller's request from being
// dropped in that window.
//
// WHY THIS MODULE EXISTS. The core already has an HPS block adapter with the exact
// handshake an image slot needs (pc9821_block_io: one req_read pulse in, one req_done
// out, the 512-byte sector streamed into a fill port), so the media layer is that
// adapter plus image knowledge: a D88 track table, a per-sector header walk, and a
// forward-only byte stream the controller can pull at its own pace.
//
// FORMATS.
//   D88 (fdd/d88head.h in the vendored NP2kai reference): a 0x2B0-byte header -
//   fd_name[17], reserved[9], protect(0x1A), fd_type(0x1B), fd_size(0x1C..0x1F) and
//   trackp[164][4] at 0x20 as little-endian 32-bit track offsets - followed by per-track
//   runs of [16-byte _D88SEC][sector data], where _D88SEC is c,h,r,n, sectors(LE16 at
//   4), mfm_flg(6), del_flg(7), stat(8), seektime(9), reserved[3](10..12), rpm_flg(13),
//   size(LE16 at 14). The sector's file offset is found by walking the run and testing
//   (c,h,r,n) exactly as NP2kai's searchsector_d88 does
//   (diskimage/fd/fdd_d88.c:220-258); the sector's stored byte count is the `size`
//   field, and a read returns min(128 << N, size) bytes from the file and ZEROES for
//   the rest (fdd_read_d88, :400-447), which is why the emit stream below has a
//   separate zero tail.
//   D88's own track index is (C << 1) | H (fdd_seek_d88, :369-373), and its fd_type
//   major nibble is the disk class (DISKTYPE_2D/2DD/2HD = 0/1/2, diskimage/fddfile.h:42):
//   a 2HD image carries major 2, which is what MAME maps 0x20 to (DSHD, d88_dsk.cpp:455-459)
//   and what the one real D88 in this tree carries at byte 0x1B
//   (X68000_MiSTer releases/BLANK_disk_X68000.D88). THE 2D/2DD CLASSES (majors
//   0/1) MOUNT AS WELL (Phase 2): NP2kai's reader takes all three and answers each track's
//   geometry from its own _D88SEC headers (the switch over the major, fdd_d88.c:92-118),
//   and this module serves the walked track table with no class assumption. What is still
//   NOT modelled of that switch is the 2D track fold (fdd_d88.c:93-99); its rpm/media-type
//   tests ARE (req_2hd/req_rpm, the mode_ok gate) - see the container test below. A major of 3 is ALSO accepted,
//   as a flagged tolerance for the tooling that writes it - see the container test below.
//   RAW (XDF/HDM/FDD/BIN family): body only, geometry from the file size, the rows of
//   NP2kai's own guesser table (diskimage/fd/fdd_xdf.c's supportxdf, :20-74). EVERY
//   headersize-0 ROW OF THAT TABLE IS IN (Phase 2 completed the size guesser): Phase 1's
//   1024-byte 8-sector rows (154/156/158/160 half-tracks) plus every row that varies the
//   two geometry terms - the 512-byte rows (HD5/HD4/DMF at 15/18/21 sectors and the 2DD
//   DD6/DD9 at 8/9), the 256-byte rows (H01 at 26 and - shadowed, see the DD6 arm - DDB at
//   16) and the 9-sector 1024-byte row (HD9). NOT the #if-0 rows (:20-22) and NOT the
//   headersize-256 rows (:51-55): those carry file offsets this body-only reader does not
//   model. The sector's file offset is the plain ((((C*2+H) * sects) + R-1) << (7 + N)) of
//   fdd_read_xdf (:352-355, headersize 0 in these rows), and a read with N != the
//   geometry's N fails with NP2kai's 0xC0 (ND) (:341-343).
//
// THE SEAM (see pc9821_fdc's port comment for the controller's side). A request is a
// one-cycle `req` pulse naming the drive's (C,H,R,N) - or, with req_hdr, the ordinal of
// the sector HEADER to report for READ ID, which is NP2kai's fdc.crcn walk
// (fdd_readid_d88 :494-552, fdd_readid_common fddfile.c:319-345). The drive it is for is
// `unit`, and every value the request is served with comes from THAT drive's own state.
// This module then:
//   * `rdy` rises when the byte at the read pointer is available, and `dout` presents
//     it; `adv` consumes it. `rdy` DROPS while a block fetch is in flight, so the
//     controller's DRQ falls with it and the DMA engine simply waits - the transfer
//     stalls, it never loses a byte.
//   * `hdrv` rises with the READ ID answer in hdr_r/hdr_n/hdr_sects (C and H are the
//     controller's own track register and head - see the port comment).
//   * `err` is sticky for the current request (sector not found, or no image).
// Both completions return to ST_READY so the next request can be issued, and `ready`
// is the level the controller waits on before pulsing `req`.
//
// BLOCK GRANULARITY. One 512-byte block buffer is the whole cache: the D88 walk and the
// sector data are both forward-only, so one block is enough, and consecutive LBAs hit the
// shared block adapter's read-ahead window (8 sectors per handshake, 16 KiB, the same window
// the hard disk reads through) instead of paying the measured ~4600 clk_sys per handshake.
//
// THE BLOCK ADAPTER IS NOT OURS ANY MORE (docs/trade-candidates.md T9): one
// pc9821_block_io engine is SHARED by the two floppy drives and pc9821_ata, arbitrated by
// pc9821_block_share, because every slot reaches one hps_io channel that serves one block
// transfer at a time (see that module's header for the evidence and for what the devices'
// requests may therefore cost each other). This module keeps the parts that the floppy's
// own - the images, their formats, their byte streams - and talks to the adapter over the
// block seam below: a request held until the adapter takes it, the DRIVE it belongs to
// (`blk_slot`, which picks the image the shared engine is loaded with), one completion, and
// the sector's 512 bytes on the fill port - and, for a write-back, the request flagged
// `blk_req_wr` with the block read back out of the buffer by the host (blk_rd_addr/blk_rd_data).
//
// WRITES (Stage B). The controller asks for a sector with `req_wr` set; the walk to the
// sector's first data byte is the READ's walk, byte for byte (the same seek, the same D88
// header match, the same file-byte bound), because a write must land exactly where the read
// of the same sector would have come from. Then each `adv` STORES `din` at the read pointer
// instead of only stepping past it. The block buffer is the READ-MODIFY-WRITE buffer: the
// block that holds the sector's first byte is already resident (the walk fetched it), the
// sector's bytes overwrite their positions in it, and when the stream leaves the block (its
// 512th byte) or the sector's last file byte lands, the block is WRITTEN BACK to the image
// whole - so the bytes of the block that are not the sector's (another sector's data, the
// next sector's D88 header, a sector that straddles two host blocks) go back exactly as they
// were read. A block is written back before the next one is fetched into the same buffer (the
// write-back has priority in the one-outstanding fetch engine), and the medium is `ready`
// again only once the sector's last block has been written, which is what the controller waits
// on before it answers (NP2kai writes the sector in writesector() before the result,
// io/fdc.c:394-405). The bytes a read would ZERO-fill (past a D88 sector's stored size, or past
// the image) are taken and dropped, the same bound the read applies to file bytes.
// Who refuses a write is the controller (FDC_DriveCheck(TRUE) on `writeprotect`); the shared
// adapter also rejects a write to a slot mounted read-only.

`default_nettype none

module pc9821_fdd_media (
    input wire clk,
    input wire reset,

    // ONE PAIR OF PORTS PER DRIVE, named after the hps_io SLOT each is fed from: `img_*` is
    // slot 1 (the OSD's FDD0 entry) and `img1_*` is slot 2 (FDD1). pc9821_block_share (shared
    // with the hard disk) owns each slot's metadata latch and the read-ahead; this module only
    // needs to know WHICH image it is parsing, for the D88/raw container test below.
    input  wire        img_mounted,
    input  wire [63:0] img_size,
    input  wire        img1_mounted,
    input  wire [63:0] img1_size,
    // THE MOUNT'S READ-ONLY FLAG. It is ONE bit for both slots because hps_io holds one
    // register, "valid only for active bit in img_mounted" (sys/hps_io.sv:129), so it is
    // latched PER DRIVE at that drive's own mount pulse - exactly as img_size is, and for the
    // same reason. It is the MiSTer stand-in for the first term of NP2kai's protect condition,
    // `(attr & 1) || (fdd->inf.d88.head.protect & 0x10) || (ro)` (diskimage/fd/fdd_d88.c:306):
    // a read-only file attribute. It is one of the two things that decide `writeprotect`,
    // which the controller reports in ST3 and refuses a write on.
    input  wire        img_readonly,

    // The block seam: the shared adapter's floppy port (pc9821_block_share's B side).
    output reg         blk_req_rd,     // level, held until the adapter takes it or completes it
    output reg  [15:0] blk_req_lba,
    // WHICH DRIVE'S IMAGE the request above belongs to, held with it: the shared adapter holds
    // three image slots (the disk's and one per floppy drive) and this is what tells it which
    // metadata to load into its engine and which slot's pins to drive. It is stable for the
    // whole request because it is latched with blk_req_lba and the module has one fetch in
    // flight at a time.
    output reg         blk_slot,
    input  wire        blk_done,
    // THE COMPLETION'S VERDICT (pc9821_block_share's b_req_error, beside blk_done). The adapter
    // answers a fetch with an error when the slot it is for was ejected or remounted under it
    // (pc9821_block_io's eject: "an unmount aborts the transfer it is serving, with an error")
    // or when the block lies past the image. A block that came back with an error is NOT the
    // medium's data: before this port the fetch engine marked it resident anyway, and a read
    // that an eject cut off was served out of whatever the buffer last held.
    input  wire        blk_err,
    input  wire        blk_busy,       // the request is in hand (pc9821_block_share's b_busy)
    input  wire        blk_fill_we,
    input  wire [ 7:0] blk_fill_addr,
    input  wire [15:0] blk_fill_data,
    // THE WRITE-BACK. `blk_req_wr` is held with blk_req_rd and says the request is a BLOCK
    // WRITE of blk_req_lba (the buffer's block); the host then reads the buffer word by word at
    // `blk_rd_addr` (hps_io's sd_buff_addr, through the shared engine) and samples `blk_rd_data`
    // one clock later - the same synchronous read the disk's sector buffer gives it
    // (pc9821_ata's sector_word_q).
    output reg         blk_req_wr,
    input  wire [ 7:0] blk_rd_addr,
    output reg  [15:0] blk_rd_data,

    // Drive state for the controller's FDC_DriveCheck (io/fdc.c:175-193), ONE BIT PER DRIVE:
    // bit 0 is drive 0 (hps_io slot 1) and bit 1 is drive 1 (slot 2), which is the per-unit
    // vector pc9821_fdc's media_present already is. POWER-ON-ONLY state: the reset branch
    // deliberately does not clear it (a mount must survive the OSD Reset; see the mount-latch
    // comment), so the `initial` below is what makes the FPGA and the bench agree that no
    // drive is equipped at power-up.
    output reg  [1:0]  present,        // an image is mounted AND its format is supported
    // [u] the medium is WRITE-PROTECTED, one bit per drive. Two sources, ORed exactly as
    // NP2kai ORs them (diskimage/fd/fdd_d88.c:306): the D88 header's own protect bit (byte
    // 0x1A, bit 4 - `UINT8 protect; // Write Protect bit:4`, fdd_head_d88.h:15) and the
    // mount's read-only flag. A raw body has no protect field, so the mount's flag is its
    // whole answer. The controller's FDC_DriveCheck(TRUE) refuses a write on it (IC0|NW).
    output reg  [1:0]  writeprotect,
    // [u] THE MEDIA-CHANGE TAG: toggles once per mount event of drive u (`mnt_ev`, insert, swap
    // or eject alike, in and out of reset). pc9821_fdc turns each toggle into NP2kai's ready-
    // change interrupt (fdd/diskdrv.c:256-284) - a level carrying a count, so the event crosses
    // the boundary as data with one consumer (single-cycle-event-discipline R1/R6).
    output reg  [1:0]  chg,

    // The sector seam.
    input  wire        req,            // one-cycle: start the request below
    input  wire        req_hdr,        // 0 = sector data, 1 = the header at req_idx
    // the sector request is a WRITE. With req_hdr ALSO set it is a FORMAT sector (pc9821_fdc's
    // raw-image FORMAT): written like a write, but refused on a D88 (see ST_SEEK).
    input  wire        req_wr,
    // The controller ABANDONED the request in flight (pc9821_fdc's media_abort, one cycle): a
    // terminal count inside a READ's sector, or a DOR reset mid-command. The request ends here
    // and the engine returns to idle; a write's owed write-back is dropped, as NP2kai's
    // fdcstatusreset drops a half-received buffer unwritten (io/fdc.c:851-855). A write whose
    // last block is already going back (ST_WB) is NOT cut: its bytes are all in, which in NP2kai
    // means writesector() has already run.
    input  wire        abort,
    /* verilator lint_off UNUSEDSIGNAL */   // only bit 0 is ever set: a request for a unit
    // whose media_present bit is clear is refused by the CONTROLLER (pc9821_fdc's command
    // decode tests media_present[cur_p0[1:0]] before it reaches this seam), and units 2/3 are
    // never equipped, so `unit[1]` carries no behaviour.
    input  wire [1:0]  unit,
    /* verilator lint_on UNUSEDSIGNAL */
    // The sector's ID (req_c/req_h/req_r/req_n, matched against a D88 header) and the TRACK it
    // is looked for on (req_tc/req_hd: pc9821_fdc's track register and the command's HD bit).
    // NP2kai seeks `(fdc.treg[fdc.us] << 1) + fdc.hd` for a D88 and a raw image alike
    // (fdd_d88.c fdd_read_d88, fdd_xdf.c fdd_read_xdf `seekp = (fdc.treg[fdc.us] << 1) + fdc.hd;`)
    // and compares the header with the command's C/H (searchsector_d88), so the two pairs differ
    // on a medium whose IDs do not name their own cylinder/side.
    input  wire [7:0]  req_c,
    input  wire [7:0]  req_h,
    input  wire [7:0]  req_tc,
    input  wire        req_hd,
    // The command's MF bit (1 = MFM, pc9821_fdc's media_mf). A RAW image is all MFM: NP2kai's
    // fdd_seeksector_common refuses any other mode for a read or a write (diskimage/fddfile.c
    // `if ((fdc.mf != 0xff) && (fdc.mf != 0x40))` -> 0xc0) and fdd_readid_common refuses READ
    // ID too (`if ((!fdc.mf) || ...` -> 0xe0). A D88 READ DATA whose (C,H,R,N) header matches
    // but whose mfm_flg disagrees with MF ends the search with no sector (searchsector_d88
    // `if ((fdc.mf != 0xff) && !((fdc.mf ^ (((D88SEC)p)->mfm_flg)) & 0x40)) break;`): mfm_flg
    // 0x00 is MFM and 0x40 FM. A D88 WRITE does not test it (fdd_write_d88's
    // searchsector_d88(FALSE)). A D88 READ ID DOES, a recorded divergence from NP2kai's D88
    // reader (fdd_readid_d88 tests rpmcheck only) and NOT a choice of ours: NP2kai's own raw
    // path refuses it (diskimage/fddfile.c fdd_readid_common `if ((!fdc.mf) || ...`), so its two
    // readers disagree, and the controller cannot do otherwise - the uPD765 family separates the
    // ID address mark in MF's own encoding, the MFM A1 sync (missing-clock 0x4489) or the FM IDAM
    // clock pattern (0xF57E), so an FM READ ID never recognises an MFM-recorded ID field. MAME
    // models exactly that (src/devices/machine/upd765.cpp read_id_start `mfm = command[0] &
    // 0x40;`, the search `if(mfm && cur_live.shift_reg == 0x4489)` / `if(!mfm && ... == 0xf57e)`,
    // and SCAN_ID_FAILED `st1 |= ST1_ND|ST1_MA;`). The answer keeps NP2kai's READ ID failure
    // status, ST1 = ND (FDC_ReadID `FDCRLT_IC0 | FDCRLT_ND`); MAME adds MA. It matters for boot:
    // the Xe10 BIOS issues an FM READ ID first and, when it answers, reads the boot sector in FM
    // only, so a D88 whose track 0 is MFM did not boot (NP2kai's HLE BIOS never takes this path).
    input  wire        req_mf,
    // THE CONTROLLER'S MEDIA MODE for this request: req_2hd is the 0x00BE register's bit 1
    // (NP2kai CTRL_FDMEDIA: `if (fdc.chgreg & 2) CTRL_FDMEDIA = DISKTYPE_2HD; else 2DD`,
    // io/fdc.c fdc_obe) and req_rpm the drive's 1.44 MB / 360 rpm bit (0x04BE, fdc.rpm[us]).
    // A medium only answers in its own mode, NP2kai's d88trk_read switch over the D88 class
    // (diskimage/fd/fdd_d88.c: 2D/2DD fail `if ((rpm) || (type != DISKTYPE_2DD))`, 2HD fails
    // `if (CTRL_FDMEDIA != DISKTYPE_2HD)` or `(fdtype_minor == 0) && (rpm)`) and the raw
    // reader's fdd_seeksector_common (diskimage/fddfile.c `(CTRL_FDMEDIA !=
    // fdd->inf.xdf.disktype) || (fdc.rpm[fdc.us] != fdd->inf.xdf.rpm)` -> failure). A failed
    // request answers ND, so a 2DD disk read in 2HD mode misses and the BIOS boot moves on to
    // its other mode. NOT MODELLED: the 2D class's track fold (`track = ((track >> 1) & 0xfe)
    // | (track & 1)`, fdd_d88.c) - a 2D image is gated like a 2DD one but read unfolded.
    input  wire        req_2hd,
    input  wire        req_rpm,
    input  wire [7:0]  req_r,
    input  wire [7:0]  req_n,
    input  wire [7:0]  req_idx,        // header ordinal for req_hdr (NP2kai fdc.crcn)
    output wire        ready,          // level: the module can accept a `req` now
    output wire        rdy,            // level: dout holds the byte at the read pointer
    output wire        hdrv,           // level: hdr_* hold the READ ID answer
    output wire        err,            // level: this request failed
    output wire [7:0]  dout,
    input  wire        adv,            // one-cycle: dout consumed (a write: din stored there)
    input  wire [7:0]  din,            // the byte a write request stores at `adv`
    // ONE NAME PER PORT DECLARATION: tools/check_port_lists.py reads an ANSI port list
    // mechanically and takes the last identifier of each declaration, so a multi-name
    // declaration hides every name but the first from the port-list audit.
    // The READ ID answer. There is no hdr_c/hdr_h: NP2kai answers READ ID with the TRACK
    // REGISTER and the head, NOT the header's own C/H copy (fdd_readid_d88,
    // diskimage/fd/fdd_d88.c:522-526), so the controller supplies those two itself and a
    // header-C/header-H port would be a wire nothing may read.
    output reg  [7:0]  hdr_r,
    output reg  [7:0]  hdr_n,
    output reg  [7:0]  hdr_sects       // the sector count of the track that answered
);

  initial present = 2'b00;
  initial chg = 2'b00;

  // ---------------------------------------------------------------- the HPS side
  // THE BLOCK INDEX IS SIXTEEN BITS, and the format extent bounds below are what fix that
  // width. Every seek that forms one (`blk_lba <= seek_off[24:9]`) has already been bounded:
  // the D88 arm by the extent test (`walk_fdsz <= D88_MAX_EXTENT` in d88_looks_valid) and the
  // raw arm by its matched row's own size (RAW_MAX_EXTENT below NAMES the widest row, at
  // 160 half-tracks x 21 sectors x 512 bytes = 1,720,320 bytes since Phase 2), so the
  // biggest block index either format can name is 2,000,000 >> 9 = 3906 -- sixteen bits
  // carry it sixteen times over. The width matters because the 32-bit forms of these two
  // registers were 64 flops, and the adapter's own req_lba_q/win_base/run_next lose their
  // high half with them, once the port below can only ever carry a 16-bit value: 765 -> 670
  // registers and 832 -> 725 ALMs for this module alone (tools/res_exp_map.py). The guard makes the
  // invariant LIVE rather
  // than remembered: it fails the BUILD, not a read, if anyone raises the extent bound past
  // what sixteen bits can name. Every seek either format admits was walked against the
  // 32-bit form when the narrowing landed.
  localparam [31:0] D88_MAX_EXTENT = 32'd2_000_000;
  generate
    if ((D88_MAX_EXTENT >> 9) > 32'd65535) begin : gen_blk_index_width_check
      initial
        $error("pc9821_fdd_media: the D88 extent bound %0d bytes needs a block index wider than the 16 bits blk_lba/blk_req_lba are declared at",
               D88_MAX_EXTENT);
    end
  endgenerate

  // THE ADAPTER IS SHARED, not instantiated here (docs/trade-candidates.md T9):
  // one pc9821_block_io engine serves this device and pc9821_ata through
  // pc9821_block_share, which arbitrates the one hps_io block channel the two slots share and
  // loads the engine with whichever image it is serving. It costs this module nothing but the
  // seam below, and it hands the floppy back the engine's 8-sector read-ahead window that T7
  // had turned off for this instance (the window's area is now spent once instead of twice).
  // tb_pc9821_block_share is the fail-first guard for the arbitration; tb_pc9821_fdd_media_d88
  // runs this module through the real engine and the real host model.

  // The 512-byte block buffer. `bready` means it holds the block at `blk_lba`. It is ALSO the
  // write path's read-modify-write buffer (WRITES above): its one write port takes the
  // adapter's fill words or a write request's assembled word (never both - a fill only lands
  // while a fetch is outstanding, and a write byte only while the block is resident), and the
  // host reads it back for a write-back through the registered port further down.
  (* ramstyle = "M10K, no_rw_check" *) reg [15:0] blk [0:255];

  // ---------------------------------------------------------------- the D88 header
  // trackp[164][4] as little-endian 32-bit file offsets (d88head.h:20-29): the D88 header's
  // own table is 164 entries per drive (656 B PER DRIVE) and NP2kai holds one `ptr[164]` per
  // open image (diskimage/fddfile.h:64-72). BOTH DRIVES SHARE THIS ONE ARRAY, because a
  // request for either drive must seek in ITS image's table and the address that does it is
  // the concatenation {drive, track} - one BIT of address, no logic.
  // THAT CONCATENATION IS NINE BITS, so the array must span the whole 512-slot address space:
  // drive 1's table occupies 256..419, and at 328 entries only 0..327 existed, so a drive-1
  // request at track >= 72 read - and the header walk wrote - OUTSIDE the array, leaving the
  // upper half of every drive-1 2HD image unreadable. 512 x 32 = 16,384 bits, still two M10K
  // blocks, the same count 328 x 32 = 10,496
  // took. One drive's entry is never read for the other, because `tp_unit` is the drive the
  // request being served belongs to.
  // NO RESET AND NO POWER-UP VALUE. A reset (or an initial value) on an array like this is
  // what blocks RAM inference in Quartus and puts the whole thing in LOGIC: the A&S report for
  // this module with the reset loop present read 5,951 registers against `blk`'s 2,048-bit
  // altsyncram in the RAM summary - i.e. 5,248 flops of addressable register file (~2,600 ALMs
  // at this design's measured 2.00 registers per ALM), which is why the merged tip needed
  // 44,563 ALMs against a 41,910-ALM device. It is safe to drop because the mount walk WRITES
  // all 164 entries - bytes 0x20..0x2AF of the 0x2B0-byte header are exactly the table, and
  // ST_MNT indexes them (mcnt >> 2) - 8 - BEFORE anything reads one: the first read is
  // `seek_off` in a request, and a request is only reachable through ST_READY, which ST_PARSE
  // enters after the last header byte. The `ramstyle` request is a hint; the reset was the
  // blocker.
  (* ramstyle = "M10K, no_rw_check" *) reg [21:0] trackp [0:511];   // {BIG, offset[20:0]}: see the WIDTHS note
  /* verilator lint_off UNUSEDSIGNAL */   // the MINOR nibble is the rpm/2HS selector, which
  // is Phase 2 (it needs the 0x4BE rpm register and the 2HS geometry); the major nibble is
  // the disk class and is the whole of the format test below. ONE REGISTER, not one per drive:
  // it is consumed in ST_PARSE, at the end of the walk that filled it, and never survives it.
  reg  [7:0]  fd_type;
  // The D88 header's protect byte (0x1A), consumed in ST_PARSE beside fd_type and never
  // surviving that parse for the same reason: the per-drive ANSWER it feeds is latched there.
  reg  [7:0]  fd_protect;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------- per-drive state [u]
  // WHAT HAS TO EXIST PER DRIVE, and nothing else. `fd_size` and
  // `is_d88`/`raw_tracks`/`raw_sects`/`raw_n` are the parsed format of each drive's image
  // (the raw geometry is three terms per drive - see the raw geometry section);
  // `mnt_req`/`mnt_size` are its pending mount. `req_u` is the drive of the request in
  // flight and `mnt_u` the drive whose header is being walked, so both the FSM and the
  // byte stream stay single-instance.
  // WIDTHS: every size this module compares or subtracts is an image extent, and an image it will
  // serve has an extent of at most D88_MAX_EXTENT (2,000,000) bytes (a D88 by its extent test, a raw
  // image because it matched a row of at most RAW_MAX_EXTENT = 1,720,320). Both are below 2^21, so a
  // size is stored as its low 21 bits plus ONE "BIG" flag (any bit at or above bit 21 set, which no
  // servable image has): a BIG value fails every test a servable one passes (<= D88_MAX_EXTENT, a
  // raw row's exact size, a seek below the extent) and passes every "extent <= the file" test, which
  // is all the 32-bit forms ever decided with those upper bits.
  reg  [21:0] fd_size [0:1];        // [u] the D88 header's declared image extent {BIG, bytes[20:0]}
  reg  [ 1:0] is_d88;               // [u] the image parsed as a D88 (else a raw body)
  reg  [ 7:0] raw_tracks [0:1];     // [u] half-tracks (raw): 154..160, so a byte names the whole range
  reg  [ 7:0] raw_sects  [0:1];     // [u] sectors per track (raw): the row's own 8..26
  reg  [ 1:0] cls_2dd;              // [u] the medium is a 2D/2DD one (D88 major 0/1, raw DD rows)
  reg  [ 1:0] cls_rpm1;             // [u] a raw 1.44 MB row (fdd_xdf.c rpm 1: HD4, DMF)
  reg  [ 1:0] cls_minor;            // [u] a D88 2HD whose fd_type minor is non-zero (rpm either)
  reg  [ 7:0] raw_n      [0:1];     // [u] N of the raw geometry: 1..3 (256..1024-byte sectors)
  reg  [ 1:0] mnt_req;              // [u] a mount arrived and has not been walked yet
  // [u] the img_size that came WITH that mount, ENCODED AS {the high half is non-zero, the low
  // 32-bit word}. Those are the only two facts either reader uses - ST_PARSE's gate on whether the
  // high half of the size was zero, plus the low word in `fdd_xdf.c`'s size-row match and in the
  // two ST_SEEK compares - so the 31 bits above bit 32 are not stored. The tuple survives reset
  // exactly as before: this block is the one with no reset (see its own note).
  reg  [21:0] mnt_size [0:1];       // [u] the img_size that came WITH that mount {BIG, bytes[20:0]}
  // [u] and the img_readonly that came with it, latched in the same statements because it is
  // the same kind of fact (a one-bit hps_io register valid only at the mount). It must SURVIVE
  // the walk, because ST_PARSE computes the drive's protect state from it - this latch block
  // has no reset by design (it IS the mount's survival), so mnt_ro is power-on state like
  // mnt_size and clears only when a later mount for that drive overwrites it.
  reg  [ 1:0] mnt_ro;               // [u] the mount's read-only flag
  reg         req_u;                // the drive the request in flight belongs to
  reg         mnt_u;                // the drive whose header walk is in progress

  // ---------------------------------------------------------------- the mount EVENT [u]
  // hps_io's img_mounted is not one cycle wide: it is set by the `'h1c` image-selection
  // transaction's data strobe and cleared only when that transaction ends (sys/hps_io.sv:318
  // "img_mounted <= 0;" under `~io_enable`, :461 the set), so it is a LEVEL for as many clk_sys
  // cycles as the HPS takes to finish the command. A mount is therefore its RISING EDGE (the
  // same reading pc9821_disk_change_reset takes of the HDD slots), so a held level is one
  // media change, not one per cycle. The previous-level flop has no reset, like the mount latch
  // it feeds: a mount that lands while the module is held must still be seen as one edge.
  reg  [ 1:0] mnt_lvl_q;
  initial mnt_lvl_q = 2'b00;
  always @(posedge clk) mnt_lvl_q <= {img1_mounted, img_mounted};
  wire [ 1:0] mnt_ev = {img1_mounted, img_mounted} & ~mnt_lvl_q;
  always @(posedge clk) chg <= chg ^ mnt_ev;   // no reset, like the edge it counts
  // A FETCH IN FLIGHT ACROSS A CONTEXT CHANGE IS STALE. The fetch engine has one outstanding
  // block; when the context it was issued for ends under it (a request the mount aborts below,
  // or a header walk starting) its completion must not mark the buffer resident for the NEW
  // context - `blk_req_lba == blk_lba` alone cannot tell them apart when both name the same
  // block (block 0 of an image remounted under its own walk, say). Set by the context change,
  // cleared only by the completion it marks.
  reg         bstale;

  // ---------------------------------------------------------------- raw geometry
  // NP2kai's size guesser (fdd_xdf.c's supportxdf, :20-74) transcribed ROW BY ROW: the
  // value constants first (the table repeats them across rows), then each row's BYTE SIZE
  // as the product of its own terms - fdd_set_xdf's match value (`size = xdf->tracks;
  // size *= xdf->sectors; size <<= (7 + xdf->n); size += xdf->headersize`, :122-126,
  // headersize 0 in every row here) - with the row's table line cited beside it. ONLY THE
  // headersize-0 ROWS: the #if-0 rows (:20-22) and the headersize-256 rows (:51-55,
  // DIP/FIM) carry file offsets this body-only reader does not model.
  //
  // THE TWO GEOMETRY TERMS ARE PER-DRIVE REGISTERS NOW (raw_sects/raw_n beside
  // raw_tracks), and that is Phase 2's whole change to this section: every Phase-1 row was
  // 8 sectors of 1024 bytes, so the terms were CONSTANTS (the multiply and the shift they
  // made were constant-folded away) - and the rows of fdd_xdf.c that DO vary them (the
  // 512-byte rows, the 2DD rows, the 256-byte rows and HD9's 9 sectors) are exactly what
  // restores the registers. The arithmetic this costs is small BY CONSTRUCTION, not by
  // hope: 128 << N is one of three fixed shifts and track * sects is written as the
  // shift-add chain below (rq_track is at most 511 - one 8-bit C shifted left with H in bit
  // 0 - so the product is 9x8 and 511 * 26 fits 16 bits). The old fear (the 32x32
  // `track * sects` against a constant took four DSP blocks) was a WIDTH accident of that
  // constant form, and tools/res_exp_map.py prices the forms module-alone
  // under real Quartus (the numbers are at raw_off below).
  //
  // Eight bits, like the registers they load: the rows span 154..160 half-tracks and the
  // registers are compared against a request track, so nothing here is wider than a byte.
  localparam [7:0] RAW_T154 = 8'd154, RAW_T156 = 8'd156,
                   RAW_T158 = 8'd158, RAW_T160 = 8'd160;
  // Sectors per track per family (8/9/15/18/21/26) and N per family (1/2/3, i.e.
  // 256/512/1024-byte sectors, 128 << N).
  localparam [7:0] RAW_S8  = 8'd8,  RAW_S9  = 8'd9,  RAW_S15 = 8'd15,
                   RAW_S18 = 8'd18, RAW_S21 = 8'd21, RAW_S26 = 8'd26;
  localparam [7:0] RAW_N1 = 8'd1, RAW_N2 = 8'd2, RAW_N3 = 8'd3;

  // The rows' byte sizes. TABLE ORDER where it matters: fdd_set_xdf's scan takes the FIRST
  // size match (:120-134) and one size is double-claimed - see RAW_SZ_DD6 below.
  localparam [31:0] RAW_SZ_HD5 = {24'd0, RAW_T160} * {24'd0, RAW_S15} * (32'd128 << RAW_N2);
  localparam [31:0] RAW_SZ_XDF = {24'd0, RAW_T154} * {24'd0, RAW_S8}  * (32'd128 << RAW_N3);
  localparam [31:0] RAW_SZ_HD4 = {24'd0, RAW_T160} * {24'd0, RAW_S18} * (32'd128 << RAW_N2);
  localparam [31:0] RAW_SZ_DMF = {24'd0, RAW_T160} * {24'd0, RAW_S21} * (32'd128 << RAW_N2);
  localparam [31:0] RAW_SZ_H01 = {24'd0, RAW_T154} * {24'd0, RAW_S26} * (32'd128 << RAW_N1);
  localparam [31:0] RAW_SZ_HD9 = {24'd0, RAW_T154} * {24'd0, RAW_S9}  * (32'd128 << RAW_N3);
  // fdd_xdf.c:41 is the FIRST 655,360-byte row - :47's DDB {0, 160, 16, 1, DISKTYPE_2DD}
  // (BKDSK(DDB) BASIC 2DD) is the SAME size - and fdd_set_xdf's scan takes the first match
  // with a .ddb-EXTENSION tiebreak only a filename can give (:129-133). The extension does
  // not exist at this seam, so the DD6 row's 8x512 geometry is the answer and the DDB row
  // is shadowed (its terms, transcribed:160 half-tracks, 16 sectors, N 1).
  localparam [31:0] RAW_SZ_DD6 = {24'd0, RAW_T160} * {24'd0, RAW_S8}  * (32'd128 << RAW_N2);
  localparam [31:0] RAW_SZ_DD9 = {24'd0, RAW_T160} * {24'd0, RAW_S9}  * (32'd128 << RAW_N2);
  localparam [31:0] RAW_SZ_T156 = {24'd0, RAW_T156} * {24'd0, RAW_S8} * (32'd128 << RAW_N3);
  localparam [31:0] RAW_SZ_T158 = {24'd0, RAW_T158} * {24'd0, RAW_S8} * (32'd128 << RAW_N3);
  localparam [31:0] RAW_SZ_T160 = {24'd0, RAW_T160} * {24'd0, RAW_S8} * (32'd128 << RAW_N3);

  // THE RAW ARM'S OWN BLOCK-INDEX GUARD (the D88 guard above tests D88_MAX_EXTENT alone, so
  // raising a raw constant past what `blk_lba` can name would leave that check silent while a
  // requester still built a truncated index).
  // EVERY expression that forms blk_lba is covered by an extent bound:
  //   * ST_SEEK's `blk_lba <= seek_off[24:9]` - the D88 arm through `fd_size <=
  //     D88_MAX_EXTENT` (d88_looks_valid, so seek_off < D88_MAX_EXTENT) and the raw arm
  //     through raw_off = ((track * sects) + r - 1) << (7 + n) with track < raw_tracks
  //     <= RAW_TMAX and r <= raw_sects, i.e. strictly inside the MATCHED row's own extent
  //     (a raw image's size IS one of those rows - ST_PARSE selects the row by matching it);
  //   * consume()'s `blk_lba <= blk_lba + 1`, the byte walk's forward step, whose end is
  //     img_left = (the image size) - seek_off, so the walk ends inside the same bound.
  // The bound is therefore the WIDEST ROW, and it is taken by name rather than remembered:
  // RAW_MAX_EXTENT below NAMES that row, gen_raw_extent_bound_check fails the BUILD if any
  // row of the table above exceeds it (a row added without being added here), and
  // gen_raw_blk_index_width_check fails the build if the bound itself outgrows the 16-bit
  // index. 64-BIT ARITHMETIC ON PURPOSE in the bound: at 32 bits a large enough constant
  // would overflow the very expression being guarded and the check would pass while raw_off
  // wrapped (a raise to 70000 half-tracks is still inside 32 bits).
  localparam [31:0] RAW_TMAX =
      (RAW_T154 >= RAW_T156 && RAW_T154 >= RAW_T158 && RAW_T154 >= RAW_T160) ? {24'd0, RAW_T154} :
      (RAW_T156 >= RAW_T158 && RAW_T156 >= RAW_T160)                         ? {24'd0, RAW_T156} :
      (RAW_T158 >= RAW_T160)                                                 ? {24'd0, RAW_T158} :
                                                                               {24'd0, RAW_T160};
  // The widest row's extent BY NAME: the DMF row (fdd_xdf.c:35, 160 x 21 x 512 =
  // 1,720,320 bytes) since Phase 2; Phase 1's widest was the 160 x 8 x 1024 row's
  // 1,310,720. Every row is named in gen_raw_extent_bound_check, so this name cannot go
  // stale without the build saying so.
  localparam [63:0] RAW_MAX_EXTENT = {32'd0, RAW_SZ_DMF};
  generate
    if ((RAW_SZ_HD5  > RAW_MAX_EXTENT[31:0]) || (RAW_SZ_XDF  > RAW_MAX_EXTENT[31:0]) ||
        (RAW_SZ_HD4  > RAW_MAX_EXTENT[31:0]) || (RAW_SZ_DMF  > RAW_MAX_EXTENT[31:0]) ||
        (RAW_SZ_H01  > RAW_MAX_EXTENT[31:0]) || (RAW_SZ_HD9  > RAW_MAX_EXTENT[31:0]) ||
        (RAW_SZ_DD6  > RAW_MAX_EXTENT[31:0]) || (RAW_SZ_DD9  > RAW_MAX_EXTENT[31:0]) ||
        (RAW_SZ_T156 > RAW_MAX_EXTENT[31:0]) || (RAW_SZ_T158 > RAW_MAX_EXTENT[31:0]) ||
        (RAW_SZ_T160 > RAW_MAX_EXTENT[31:0])) begin : gen_raw_extent_bound_check
      initial
        $error("pc9821_fdd_media: a raw row exceeds RAW_MAX_EXTENT (%0d bytes) - the bound NAMES the widest row and must be repointed when a row grows past it",
               RAW_MAX_EXTENT);
    end
    if ((RAW_MAX_EXTENT >> 9) > 64'd65535) begin : gen_raw_blk_index_width_check
      initial
        $error("pc9821_fdd_media: the widest raw geometry (%0d half-tracks, %0d bytes) needs a block index wider than the 16 bits blk_lba/blk_req_lba are declared at",
               RAW_TMAX, RAW_MAX_EXTENT);
    end
  endgenerate

  // ---------------------------------------------------------------- the byte stream
  // ONE block is resident. `foff` is the byte index inside it (0..511), so the word
  // index is foff[8:1] and the lane is foff[0]: the HPS block stream is little-endian
  // 16-bit words (the block seam's blk_fill_data, word i at bytes 2i, 2i+1).
  reg         bready;      // the block at blk_lba is resident
  reg         bwant;       // a fetch of blk_lba is owed
  reg         rbusy;       // the fetch engine has a request outstanding
  reg  [ 9:0] foff;        // 0..511 within the block
  reg  [15:0] blk_lba;     // 16 bits: see D88_MAX_EXTENT above
  reg  [20:0] img_left;    // bytes left in the image from the read pointer (<= the extent, < 2^21)

  wire [15:0] cur_word = blk[foff[8:1]];
  wire [7:0]  cur_byte = foff[0] ? cur_word[15:8] : cur_word[7:0];

  // ---------------------------------------------------------------- the write-back state
  // `bdirty`: the resident block holds bytes a write stored that the image does not have yet.
  // `wbwant`/`wb_lba`: a block write-back is owed for block `wb_lba` (it is issued BEFORE any
  // read fetch, so the buffer is read out before it is refilled). `wlo`/`wlo_v`: a write's even
  // byte, held until its odd partner arrives so the word is written whole (see blk's write
  // port).
  reg         bdirty;
  reg         wbwant;
  reg  [15:0] wb_lba;
  reg  [ 7:0] wlo;
  reg         wlo_v;

  // ---------------------------------------------------------------- the image FSM
  localparam [3:0] ST_NONE  = 4'd0,   // no image parsed
                   ST_MNT   = 4'd1,   // streaming the 0x2B0-byte D88 header
                   ST_PARSE = 4'd2,   // the header has landed; decide the format
                   ST_READY = 4'd3,   // present, waiting for a request
                   ST_SEEK  = 4'd4,   // latching the request's start
                   ST_WAIT  = 4'd5,   // waiting for the block that carries the start
                   ST_SCAN  = 4'd6,   // reading one 16-byte _D88SEC
                   ST_SKIP  = 4'd7,   // skipping a non-matching sector's data
                   ST_DATA  = 4'd8,   // emitting the sector's bytes (a write: storing them)
                   ST_WB    = 4'd9;   // a write's bytes are in: its last block is going back
  reg [3:0] st;

  // ---------------------------------------------------------------- the mount latch [u]
  // A MOUNT IS A TUPLE - the pulse AND the size that came with it - AND IT IS LATCHED, not
  // lost. pc9821_system wires this module's reset as `reset || !cpu_run`,
  // and cpu_run is LOW for the whole firmware-pack download, while the HPS mounts an image
  // (MGL delay ~1 s) BEFORE the pack finishes (~4 s). hps_io's img_mounted is a SINGLE-CYCLE
  // pulse (z486_mister wires img_mounted[1] into this drive's slot and img_mounted[2] into the
  // other's), so before this latch the pulse was taken into the reset branch and discarded
  // with it: the guest booted with no floppy however the image was listed. mnt_req[u]
  // remembers that a mount for drive u arrived while the module was held, and the FSM applies
  // it - and only then - on the first cycle after the release.
  //
  // THE SIZE IS LATCHED WITH IT, because hps_io holds ONE img_size for whichever slot mounted
  // LAST (sys/hps_io.sv:130 "size of image in bytes") and EVERY slot reads it (z486_mister
  // wires it into the disk's .img_size and into BOTH floppy slots). Deferring the pulse and
  // then sampling the LIVE size would parse this medium with another slot's size;
  // pc9821_block_share - the adapter these fetches go through - latches each slot's size at
  // the same pulse for the same reason. Two slots can have their pulses outstanding at once
  // (the MGL lists both floppies before the pack download finishes), so the size is per drive
  // and the walk uses the one that came with ITS mount. There is no img_readonly to latch: it
  // stopped being a port of this module when the shared adapter took the slot metadata (T9),
  // and the medium is write-protected by construction.
  //
  // A WALK STARTS WHEN THE ENGINE IS IDLE, and that is a rule rather than an optimisation:
  // a mount for drive 1 that landed while drive 0's sector was streaming would otherwise
  // re-enter ST_MNT, reset blk_lba/foff and clear `bready` under the request the controller is
  // reading, which stalls its DMA mid-sector for good. Deferring it costs the mount one
  // command's worth of waiting and can never be observed as a dropped byte.
  // The engine is IDLE - the only state a walk may begin in - when no request is in flight and
  // none is being accepted on this very cycle (a `req` that is taken this cycle is served
  // first; the mount is one cycle younger than a request that is already being handed over).
  // A HELD MODULE IS NOT AN IDLE ONE: while `reset` is asserted the FSM cannot walk, so
  // `mnt_req` must not be consumed here - the reset term is `reset || !cpu_run` and the HPS
  // mounts images BEFORE the firmware pack finishes, so a pending mount that is cleared while
  // held is a floppy the guest never sees (the mount-latch case above, in its per-drive form).
  //
  // A WALK ABORTED BY A RESET IS RE-ARMED, NOT LOST. `walk_en` consumes the drive's mnt_req
  // entry at the walk's START, so an OSD Reset mid-walk (mount an image, then select
  // Reset) would abort the walk with its pulse already spent - and nothing would ever
  // re-announce the image, because hps_io pulses img_mounted from the HPS's
  // image-selection transaction alone (sys/hps_io.sv:461, the `'h1c` handler) and an OSD
  // Reset is a STATUS bit write, not a mount. The latch block below therefore RE-ARMS the
  // drive whose walk the reset is aborting (`walking` names the two states a walk lives in),
  // so the walk re-runs after the release. That is idempotent by construction: a walk re-reads
  // block 0 and rewrites only its own drive's parse registers, and the size it parses against
  // is still the mnt_size latched with the original pulse. `walk_en` is gated on !reset for
  // the same reason - the reset branch stops the walk from starting, so the consume must not
  // fire either (tb_pc9821_fdd_mount_reset's R2 arm).
  wire        fsm_idle = !reset && ((st == ST_NONE) || (st == ST_READY)) && !req;
  wire [ 1:0] mnt_want = mnt_req & {2{fsm_idle}};
  // A walk begins for the drive that STARTED its header, which is the drive of the request in
  // flight for the walk being restarted below, and otherwise the waiting drive (drive 0 first
  // - the order is arbitrary, both are served).
  wire        walk_u   = (st == ST_PARSE && mnt_req[mnt_u]) ? mnt_u
                                                           : ~mnt_want[0];
  wire        walk_en  = !reset && (((st == ST_PARSE) && mnt_req[mnt_u]) || (|mnt_want));
  // A header walk owns the FSM: these are the only two states one lives in (ST_MNT streams
  // the header, ST_PARSE decides the format), so `reset` arriving here is a walk being cut
  // off after its mnt_req entry was consumed - the case the re-arm below exists for.
  wire        walking  = (st == ST_MNT) || (st == ST_PARSE);

  // ---------------------------------------------------------------- the media change [u]
  // A MOUNT ON A DRIVE IS A MEDIA CHANGE THE GUEST MUST SEE, NOT A DEFERRED BOOKKEEPING STEP
  // (floppies mount, swap and eject while the core runs, without a reset).
  // Three things follow from the edge, and each is the drive's own:
  //   * READY DROPS AT ONCE. `present[u]` clears on the mount edge (the trailing write at the
  //     end of the FSM block, so it applies even while the module is held) and rises again only
  //     when the new image's walk parses a format - so the controller's media_present, and with
  //     it ST3's RDY and the data-path decision, goes not-ready for the whole change. Without
  //     it, a mount of a drive whose sibling was streaming would leave `present` - and the OLD
  //     image's geometry - standing until the deferred walk began.
  //   * A REQUEST IN FLIGHT FOR THAT DRIVE IS ABORTED, with `err`, instead of being finished
  //     out of a medium that is gone: were the walk to wait for it (`fsm_idle`), an eject
  //     mid-sector would stream the rest of the sector, and every later block of it, from
  //     fetches the adapter rejects - i.e. from whatever the block buffer last held.
  //     WHAT THE GUEST SEES THEN IS UNDEFINED; the abort exists for the HOST side only. A request left
  //     standing on a medium that is gone holds the engine (`fsm_idle` stays false while it
  //     waits for bytes a stalled or reset controller will never take), so the new image's walk
  //     could never start and the drive - and its sibling - would stay dead until a core reset.
  //     Ending it on the edge is the one term that rules that out.
  //   * A HEADER WALK OF THAT DRIVE needs nothing extra: ST_PARSE re-runs the walk from block 0
  //     when its drive's mnt_req was re-armed meanwhile (`walk_en` below), so the new image is
  //     the one parsed. (Abandoning the walk on the edge would only save the rest of a
  //     0x2B0-byte header stream.)
  // A mount of the OTHER drive aborts nothing (its walk waits for `fsm_idle`).
  // ST_WB is a request too: a mount edge while a write's last block is owed ENDS it with `err`
  // and drops the owed write-back - the block belongs to the image that has just gone, and a
  // write-back issued after the edge would land in whatever image the slot holds now.
  wire        in_request = (st == ST_SEEK) || (st == ST_WAIT) || (st == ST_SCAN) ||
                           (st == ST_SKIP) || (st == ST_DATA) || (st == ST_WB);
  wire        abort_req  = !reset && in_request && mnt_ev[req_u];
  // A fetch for the LIVE context that came back with an error (blk_err): the block is not the
  // medium's, so the request (or walk) that wanted it ends here rather than reading it.
  // A request ACCEPTED while a fetch is outstanding is a context change too: that fetch is the
  // previous request's read-ahead of its next block (consume() asks for it at every block wrap),
  // and it may be one past the image - so its verdict, an error included, is not this request's.
  wire        req_accept = !reset && (st == ST_READY) && req && present[unit[0]] && !mnt_ev[unit[0]];
  // A failed WRITE-BACK fails the request whatever block the cursor has moved on to: the
  // written sector did not reach the image, so the controller must not be told it did.
  wire        blk_fail   = blk_done && blk_err && !bstale &&
                           (blk_req_wr || (blk_req_lba == blk_lba)) && !req_accept;
  wire        fail_ctx   = blk_fail && (in_request || (st == ST_MNT));
  wire        abort_fdc  = !reset && abort && in_request && (st != ST_WB);
  wire        abort_now  = abort_req || fail_ctx || abort_fdc;

  always @(posedge clk) begin
    // The pulse first, the consume second, and the consume only clears THE DRIVE IT WALKS, so
    // a mount that arrives in the same cycle as its own walk begins is not lost: the walk that
    // is starting IS that mount's walk (it reads the size latched here, at ST_PARSE, long
    // after this edge).
    if (mnt_ev[0])
      begin mnt_size[0] <= {(|img_size[63:21]),  img_size[20:0]};
            mnt_ro[0] <= img_readonly;                            mnt_req[0] <= 1'b1; end
    if (mnt_ev[1])
      begin mnt_size[1] <= {(|img1_size[63:21]), img1_size[20:0]};
            mnt_ro[1] <= img_readonly;                            mnt_req[1] <= 1'b1; end
    if (walk_en)      mnt_req[walk_u] <= 1'b0;   // consumed by the walk starting now
    // ... and a walk the reset is aborting is NOT consumed-and-lost: re-arm its drive, which
    // is mnt_u as of this edge (the reset branch retires mnt_u after it). This block has no
    // reset by design - it IS the mount's survival - so the re-arm is a conditional write in
    // the same latch, not a second mechanism.
    if (reset && walking) mnt_req[mnt_u] <= 1'b1;
  end

  // The drive whose header is being walked (mnt_u) and the one the request in flight belongs
  // to (req_u) are the only two contexts the shared FSM needs.

  // mount parse
  reg [10:0] mcnt;         // byte index into the 0x2B0-byte header
  // THE TRACK TABLE'S WORD-IN-PROGRESS. Its entries are 4-byte little-endian words that arrive
  // one BYTE per clock, and writing them with a variable part-select (`trackp[i][sel +: 8]`) is
  // exactly what Quartus's HDL reader refuses: `Warning (10999): can't infer memory for variable
  // 'trackp' with attribute "M10K, no_rw_check"`, which puts all 5,248 bits of the table back in
  // logic (~2,600 ALMs at this design's 2.00 registers per ALM - the merged tip's whole A&S
  // overage). Assembling the word here makes every write a FULL WORD, the shape the reader
  // accepts, with the enable decoded from mcnt's low bits. Bytes shift in at the TOP, so
  // {cur_byte, tp_w} is the 32-bit little-endian word for the entry; the table is read only
  // after the walk, so a half-built entry is never observable.
  reg [20:0] tp_w;
  reg        tp_big;       // the entry's bytes above bit 20 so far
  // trackp[drive][0] LATCHED, i.e. `trackp[mnt_u * 164]` of the drive being walked. The
  // container test below is the table's SECOND reader, and a second read address (even a
  // constant one) is a second read port, which the inference template does not have: there is
  // one variable read (`seek_off`) and the table infers only when that is all there is. This
  // register holds exactly what the walked drive's entry 0 held once its last byte landed,
  // which is what the test needs - it runs in ST_PARSE, after the walk.
  reg [21:0] tp0;

  // request latches
  reg        rq_hdr;
  reg        rq_wr;        // the request is a WRITE (WRITES in the header)
  reg        rq_fmt;       // ... and a FORMAT sector (req_hdr with req_wr)
  reg [7:0]  rq_c, rq_h, rq_r, rq_n, rq_idx;
  reg [7:0]  rq_tc;
  reg        rq_hd;
  reg        rq_mf;
  reg        rq_2hd, rq_rpm;
  // The request's mode against its drive's medium (see req_2hd): 1 = the medium answers.
  wire       mode_ok = is_d88[req_u]
                       ? (cls_2dd[req_u] ? (!rq_2hd && !rq_rpm) : (rq_2hd && !(!cls_minor[req_u] && rq_rpm)))
                       : ((cls_2dd[req_u] == !rq_2hd) && (cls_rpm1[req_u] == rq_rpm));

  // scan / emit
  reg [4:0]  hi;           // header byte index 0..16; hi[4] means "all 16 in"
  reg [7:0]  hb [0:15];    // the header being read
  // The _D88SEC u16 fields are little-endian pairs: `sectors` at bytes 4-5 and the stored
  // size at 14-15 (fdd/d88head.h:33-49). Reading the HIGH byte alone as the count made
  // every track look like a zero-sector track, so the walk gave up on its first mismatch.
  wire [15:0] hdr_sectors = {hb[5], hb[4]};
  wire [15:0] hdr_size    = {hb[15], hb[14]};
  // THE SECTOR'S FILE BYTE COUNT IS BOUNDED BY THE IMAGE, not only by the header's own
  // `size` field. A malformed or truncated D88
  // whose header claims more than the declared extent holds would otherwise let consume()
  // walk past img_left, advance blk_lba past the image, and - because the shared adapter
  // pulses blk_done on a REJECTED fetch too - mark the STALE buffer resident, serving
  // repeated stale blocks as sector data with no error. Bounding the file count here keeps
  // the block walk inside the extent, and the remainder is the same ZERO tail a short header
  // already gets (fdd_read_d88 returns min(128<<N, size) file bytes and zeroes after,
  // diskimage/fd/fdd_d88.c:400-447). For a well-formed image the header size is consistent
  // and this is a no-op.
  wire [15:0] scan_file_want = (hdr_size > rq_sec_bytes) ? rq_sec_bytes : hdr_size;
  // `scan_file_want` is at most 65535 (the header's own 16-bit field), so when it exceeds
  // img_left the image's remaining count is itself below 65536 and img_left[15:0] IS
  // img_left; otherwise scan_file_want passes through. Exact, and 16 bits wide.
  wire [15:0] scan_file_ok   = ({5'd0, scan_file_want} > img_left) ? img_left[15:0]
                                                                  : scan_file_want;
  reg [7:0]  seen;         // headers walked on this track
  reg [15:0] skip_left;    // data bytes still to skip
  reg [15:0] emit_left;    // bytes still to emit for the sector
  reg [15:0] file_left;    // of those, the bytes that come from the file
  reg        aerr;         // the sticky error for the current request
  reg        ahdrv;        // the READ ID answer is standing

  // 128 << N, clamped at N >= 8 exactly as NP2kai does (`if (fdc.N < 8) ... else 128<<8`).
  wire [15:0] rq_sec_bytes = (rq_n[7:4] != 4'd0) ? 16'd32768 : (16'd128 << rq_n[3:0]);

  // ---------------------------------------------------------------- the write byte
  // A write request's `adv` with a FILE byte left (file_left: the bytes a read would take from
  // the image; the rest is the zero tail, taken and dropped). The buffer is 16 bits wide and the
  // stream a byte at a time, so a word is written WHOLE: an odd byte writes {din, its even
  // partner} - the partner held in `wlo` when this write stored it, or the buffer's own byte
  // when the sector began on the odd half - and an even byte that is the sector's LAST file byte
  // writes {the buffer's own odd byte, din}. Every merge reads a word this write has NOT yet
  // written (the even byte is held in `wlo`, never written alone mid-sector), so no merge
  // depends on reading back a word written the cycle before. `w_byte` is the FSM's own
  // ST_DATA write condition (the same `adv`, the same file_left test, the same reset/abort
  // gating), which is what keeps the buffer and the dirty state in step.
  wire        w_byte    = rq_wr && adv && (st == ST_DATA) && (file_left != 16'd0) &&
                          !reset && !abort_now;
  wire        w_wrap    = w_byte && (foff == 10'd511);
  wire        w_word_we = w_byte && (foff[0] || (file_left == 16'd1));
  wire [15:0] w_word    = foff[0] ? {din, (wlo_v ? wlo : cur_word[7:0])}
                                  : {cur_word[15:8], din};
  // The block holds a stored byte that is not yet in the image, after this cycle (a byte at the
  // block's last position is scheduled for write-back with its block at the wrap instead).
  wire        w_dirty   = w_wrap ? 1'b0 : (bdirty || w_byte);
  // The write's last byte (the sector's 128 << N-th, file byte or zero tail), and whether a
  // block write-back is SCHEDULED this cycle: at a wrap, or at the last byte while the block
  // it ends in holds a stored byte. R3 (set vs clear): a schedule never meets the fetch
  // engine's issue of an earlier one, because a write byte needs the block resident (`rdy`), and
  // a block is only resident again after the previous write-back has been issued and completed
  // (the write-back goes first); a zero-tail byte can follow a wrap's schedule without the block,
  // but then `bdirty` is clear and nothing is scheduled. Asserted below (R8).
  wire        w_last    = rq_wr && adv && (st == ST_DATA) && (emit_left == 16'd1) &&
                          !reset && !abort_now;
  wire        w_sched   = w_wrap || (w_last && w_dirty);

  always @(posedge clk) begin
    if (blk_fill_we)    blk[blk_fill_addr] <= blk_fill_data;
    else if (w_word_we) blk[foff[8:1]]     <= w_word;
  end
  // The host's read port for a write-back: hps_io presents sd_buff_addr and samples
  // sd_buff_din at its own strobe, many clocks later, so a registered read is what the disk's
  // buffer gives it too. No reset and no initial value: either would stop the read inferring a
  // block RAM port (docs/fitting.md's inference trap).
  always @(posedge clk) blk_rd_data <= blk[blk_rd_addr];

  // The track index is (treg << 1) | HD, the D88 file layout's own ordering, on the PHYSICAL
  // track (req_tc/req_hd) - not the ID C/H the header walk below matches.
  wire [31:0] rq_track = ({24'd0, rq_tc} << 1) | {31'd0, rq_hd};
  // The raw file offset, fdd_read_xdf's ((C*2+H) * sects + R-1) << (7+N) (:352-355) with
  // the requesting DRIVE's own geometry terms. THE PRODUCT IS WRITTEN AS THE SHIFT-ADD
  // CHAIN, NOT A `*`, and 128 << N as a mux of FIXED shifts - because the module-alone A&S
  // probe (tools/res_exp_map.py on this one module as top, the production settings)
  // says that is what it must be: the register form
  // with a plain 9x8 `*` measures 707 ALMs / 561 registers AND ONE DSP BLOCK (the report's
  // "Fixed Point Unsigned Multiplier" - even 9x8 goes to a DSP with Auto DSP Block
  // Replacement on), while this chain form measures 702 / 561 / ZERO DSPs against the old
  // constant form's 688 / 548 / 0. The geometry registers therefore cost +14 ALMs and +13
  // registers module-alone - NOT the four DSPs of the 32x32 shape the constant form was
  // priced against (its WIDTH was the accident: rq_track is at most 511 - one 8-bit C
  // shifted left with H in bit 0 - so rq_track[8:0] is the whole value, never a
  // truncation, and 511 * 26 fits 16 bits).
  // THE OFFSET IS FORMED FROM THE REQUEST AS IT IS ACCEPTED and latched with it (FD-a, a
  // timing seam: otherwise the shift-add product and the N mux run from the rq_* latches through
  // seek_off into ST_SEEK's bounds compares and img_left in ONE clk_sys path). raw_off is
  // loaded on the accept edge - the edge rq_c/rq_h/rq_r/req_u load from these same live
  // fields - from the accepting drive's raw_sects/raw_n, which nothing writes in ST_READY or
  // ST_SEEK (only ST_PARSE does), so in ST_SEEK, its only reader (through seek_off), it holds
  // exactly the value the combinational form of the latches held there.
  wire [ 8:0] a_track9   = {req_tc, 1'b0} | {8'd0, req_hd};   // rq_track's [8:0], live
  wire [16:0] a_t9e      = {8'd0, a_track9};
  wire [ 7:0] a_sects    = raw_sects[unit[0]];
  wire [ 7:0] a_n        = raw_n[unit[0]];
  // One masked partial product per bit of the sector count, summed - correct for any byte
  // raw_sects can hold, of which the rows use 8..26.
  wire [16:0] raw_ts     = (a_sects[0] ? a_t9e        : 17'd0)
                         + (a_sects[1] ? (a_t9e << 1) : 17'd0)
                         + (a_sects[2] ? (a_t9e << 2) : 17'd0)
                         + (a_sects[3] ? (a_t9e << 3) : 17'd0)
                         + (a_sects[4] ? (a_t9e << 4) : 17'd0)
                         + (a_sects[5] ? (a_t9e << 5) : 17'd0)
                         + (a_sects[6] ? (a_t9e << 6) : 17'd0)
                         + (a_sects[7] ? (a_t9e << 7) : 17'd0);
  wire [24:0] raw_secno  = {8'd0, raw_ts} + {17'd0, req_r} - 25'd1;   // < 13,541 + 255: the rows' tracks*sects
  // 128 << N for the rows' N in 1..3: three fixed shifts, which are wire slices. raw_n is
  // written only from the row loads (RAW_N1/2/3), so the middle arm is N=2 and every value
  // the register cannot hold.
  wire [24:0] raw_off_a  = (a_n == RAW_N1) ? (raw_secno <<  8) :
                           (a_n == RAW_N3) ? (raw_secno << 10) :
                                             (raw_secno <<  9);
  reg  [24:0] raw_off;     // raw_off_a at the accept (no reset: read only in ST_SEEK)

  // The start offset the request names.
  // THE TABLE'S ONE READ PORT, as a registered read (the canonical simple-dual-port template:
  // one write port in the FSM, one clocked read here). The address presented is the request's
  // own track index ON THE CYCLE THE FSM ACCEPTS IT - which is the same cycle the `req` pulse
  // and its C/H are valid - so `track_q` already holds that request's word when ST_SEEK reads it
  // one cycle later. Registers of its own buy nothing, and a COMBINATIONAL read (which is what
  // this was: `trackp[rq_track[7:0]]` used directly in the ternary below) is the shape Quartus
  // refuses to put in a block - `Warning (10999)` with the attribute, or a silent fall-back into
  // LUTs without one - which is how the 5,248 bits of this table came to cost ~2,600 ALMs.
  // Reading during the write walk is don't-care: the FSM only consults `seek_off` in ST_SEEK,
  // and later requests present their own address, which overwrites whatever this read caught.
  // The 8-bit track index is (C << 1) | H truncated to the table's own address width - the
  // same value the bounds check above rejects when it is out of range - and the ninth bit
  // selects the DRIVE, so the two tables are one array with one read port rather than two
  // arrays (two arrays would infer two blocks and need the read address muxed anyway).
  // The drive the presented address belongs to is the request being ACCEPTED this cycle (its
  // `unit` is valid with `req`) and the one in flight otherwise; the write walk never reads.
  wire [7:0] tp_track = {req_tc[6:0], 1'b0} | {7'd0, req_hd};
  wire       tp_unit  = ((st == ST_READY) && req) ? unit[0] : req_u;
  wire [8:0] tp_raddr = {tp_unit, (((st == ST_READY) && req) ? tp_track : rq_track[7:0])};
  reg  [21:0] track_q;
  always @(posedge clk) track_q <= trackp[tp_raddr];

  // THE REQUEST'S OWN DRIVE CONTEXT, from the latches `req_u` and the per-drive arrays. Every
  // read of a per-drive value below goes through these, so nothing in the FSM can consult the
  // other drive's geometry by accident.
  // A BIG track pointer is at least 2^21 > any extent, so it is carried as bit 24: it is never
  // zero, and it fails the `< the extent` test exactly as the 32-bit pointer did. (raw_off
  // is below 2^24 for every row: 13,541 sectors at most, shifted by 10.)
  wire [24:0] seek_off = is_d88[req_u] ? {track_q[21], 3'd0, track_q[20:0]} : raw_off;
  assign ready = (st == ST_READY);
  assign rdy   = (st == ST_DATA) && (emit_left != 16'd0) &&
                 ((file_left == 16'd0) || bready);
  assign dout  = (file_left != 16'd0) ? cur_byte : 8'h00;
  assign hdrv  = ahdrv;
  assign err   = aerr;

  // ONE BYTE CONSUMED. Called from the reading states with a non-blocking update, so the
  // stream pointer, the FSM's own counters and the block wrap all commit on the SAME edge.
  // A `bstep` flag read back in the next cycle would instead leave the pointer one byte
  // behind every counter the FSM advances beside it -- which is exactly the one-byte lag
  // that mis-placed every D88 header field.
  task automatic consume();
    begin
      if (img_left != 21'd0) img_left <= img_left - 21'd1;
      if (foff == 10'd511) begin
        foff    <= 10'd0;
        blk_lba <= blk_lba + 16'd1;
        bready  <= 1'b0;
        bwant   <= 1'b1;
      end else begin
        foff <= foff + 10'd1;
      end
    end
  endtask

  integer i;

  // The D88 container test, on the walk IN PROGRESS (the values it just parsed from drive
  // mnt_u's header). fd_type's major nibble is the disk CLASS, and the format's own classes
  // are majors 0/1/2 (DISKTYPE_2D/2DD/2HD, diskimage/fddfile.h:42-44); a 2HD image carries
  // major 2, which is what MAME maps 0x20 to (DSHD, d88_dsk.cpp:455-459) and what the real
  // D88 at X68000_MiSTer releases/BLANK_disk_X68000.D88 carries. THE 2D/2DD CLASSES
  // (majors 0/1) ARE TAKEN (Phase 2), exactly as NP2kai's switch over fdtype_major takes all
  // three and answers "not found" for any other (fdd_d88.c:92-118): the D88 path asserts no
  // geometry of its own - it serves whatever the walked track table holds - so a 2D/2DD
  // image's per-track N and sector count come from its own _D88SEC headers, like the 2HD
  // one's. The rpm/CTRL_FDMEDIA tests of all three arms (:95-113) ARE modelled
  // (req_2hd/req_rpm, mode_ok); the raw rows apply fdd_seeksector_common's disktype/rpm test the
  // same way. DOCUMENTED DIVERGENCE, not modelled: the 2D arm's track fold (it rejects odd
  // cylinders and remaps the track index, fdd_d88.c:93-99) - a 2D image is read unfolded.
  // MAJOR 3 IS A FLAGGED TOLERANCE, NOT THE FORMAT'S CODE. MAME maps 0x30 to SSDD, a
  // single-sided 42-track class (d88_dsk.cpp:462-466), and NP2kai's D88 reader rejects every
  // major but 0/1/2 (fdd_d88.c:92-118). It is accepted anyway because some PC-98 tooling
  // writes 0x30 for a 1.44 MB image, this core already shipped against it, and the D88 path
  // asserts no geometry of its own (above), so a 1.23 MB and a 1.44 MB image both work and a
  // track with no live pointer answers "sector not found". It is treated as the SAME class as
  // major 2 and nothing else; removing the tolerance is a one-term edit. The structural terms
  // separate a D88 from a RAW image whose first bytes happen to look like a header: the
  // declared extent must be inside the file and at least one track pointer must be live. (A
  // raw image would have to satisfy all of them at once, which its sector data does not.)
  wire [21:0] walk_size = mnt_size[mnt_u];
  wire [21:0] walk_fdsz = fd_size[mnt_u];   // latched byte by byte in the walk above
  wire        d88_major_ok = (fd_type[7:4] == 4'd0) || (fd_type[7:4] == 4'd1) ||
                             (fd_type[7:4] == 4'd2) || (fd_type[7:4] == 4'd3);
  wire d88_looks_valid = d88_major_ok &&
                         !walk_fdsz[21] && (walk_fdsz[20:0] >= 21'd688) &&
                         (walk_fdsz[20:0] <= D88_MAX_EXTENT[20:0]) &&
                         (walk_size[21] || (walk_fdsz[20:0] <= walk_size[20:0])) &&
                         (tp0 != 22'd0) && !tp0[21] && (tp0[20:0] < walk_fdsz[20:0]);

  always @(posedge clk) begin
    if (reset) begin
      // THE IDLE STATE THE SURVIVING PARSE IMPLIES. `present` is the mounted metadata and is
      // NOT in this reset domain (below), so the FSM's idle state follows it: ST_READY when a
      // walk has completed and a request can be served from the geometry that survives,
      // ST_NONE otherwise - where the re-armed mnt_req (the latch block above) restarts the
      // walk this reset aborted. Resetting into ST_NONE unconditionally would leave,
      // with no img_mounted pulse ever coming again, `ready` (st == ST_READY) never rising and
      // the mounted image dead to the guest (tb_pc9821_fdd_mount_reset's R1 arm).
      st           <= (|present) ? ST_READY : ST_NONE;
      // NO MEDIUM, NO PROTECT: the flag is the MOUNTED MEDIUM's state, so a drive that has never
      // been walked (or whose medium was ejected) reports 0, not "protected". That matters because
      // SENSE DRIVE STATUS reads the bit directly: a drive with no diskette has nothing to write
      // to, so claiming WP would be inventing a property of a medium that is not there.
      writeprotect <= 2'b00;
      bready       <= 1'b0;
      bwant        <= 1'b0;
      rbusy        <= 1'b0;
      bstale       <= 1'b0;
      blk_req_rd   <= 1'b0;
      blk_req_wr   <= 1'b0;
      blk_req_lba  <= 16'd0;
      blk_slot     <= 1'b0;
      // A WRITE CUT OFF BY A RESET IS LOST from the block it had reached on: the owed
      // write-back is dropped with the request (the reset term is `reset || !cpu_run`, i.e. an
      // OSD Reset). The blocks already written back stay written; the sector can be torn, as a
      // drive reset mid-write tears it.
      bdirty       <= 1'b0;
      wbwant       <= 1'b0;
      wb_lba       <= 16'd0;
      wlo          <= 8'h00;
      wlo_v        <= 1'b0;
      rq_wr        <= 1'b0;
      rq_fmt       <= 1'b0;
      foff         <= 10'd0;
      blk_lba      <= 16'd0;
      img_left     <= 21'd0;
      mcnt         <= 11'd0;
      tp_w         <= 21'd0;
      tp_big       <= 1'b0;
      tp0          <= 22'd0;
      fd_type      <= 8'h00;
      fd_protect   <= 8'h00;
      req_u        <= 1'b0;
      mnt_u        <= 1'b0;
      hi           <= 5'd0;
      seen         <= 8'd0;
      skip_left    <= 16'd0;
      emit_left    <= 16'd0;
      file_left    <= 16'd0;
      aerr         <= 1'b0;
      ahdrv        <= 1'b0;
      hdr_r        <= 8'h00;
      hdr_n        <= 8'h00;
      hdr_sects    <= 8'd0;
      rq_hdr       <= 1'b0;
      rq_c         <= 8'h00;
      rq_h         <= 8'h00;
      rq_tc        <= 8'h00;
      rq_hd        <= 1'b0;
      rq_mf        <= 1'b1;
      rq_2hd       <= 1'b1;
      rq_rpm       <= 1'b0;
      rq_r         <= 8'h00;
      rq_n         <= 8'h00;
      rq_idx       <= 8'h00;
      // THE METADATA IS NOT IN THIS RESET DOMAIN. NOT trackp: see its declaration - a reset
      // on that array is what put its 5,248 flops in logic instead of an M10K block.
      // `is_d88`/`fd_size`/`raw_tracks`/`raw_sects`/`raw_n` are per drive and are written by
      // the walk of the drive
      // they belong to before any request that drive serves. `present` - and with it the
      // parsed container/geometry above - is the guest's "a disk is in this drive"
      // (pc9821_fdc's media_present) and must SURVIVE a core reset: hps_io pulses img_mounted
      // only when the HPS selects an image (sys/hps_io.sv:461) and never re-announces one
      // across an OSD Reset, so clearing `present` here is what unmounted a floppy the user
      // had mounted the moment they hit Reset (tb_pc9821_fdd_mount_reset). mnt_req/mnt_size
      // are deliberately NOT reset either: a mount landing while the module is held is
      // exactly what they are for, and a walk this reset aborts is re-armed into the same
      // latch (its always block above). What DOES reset is the transfer/FSM state - the walk
      // counters, the block cursor, the in-flight request - and `st`, whose reset value is
      // computed from `present` at the top of this branch.
      // hb is 16 register bytes indexed by a live counter and is written by the walk before it
      // is read, which is cheap to keep clean.
      for (i = 0; i < 16;  i = i + 1) hb[i] <= 8'h00;
    end else begin
      // ===== the block fetch engine: one outstanding block, `bwant` asks for it =====
      // A WRITE-BACK GOES FIRST (`wbwant`): the block it writes is the one in the buffer, and the
      // read the cursor wants next would overwrite it. With one request outstanding at a time,
      // the read is issued only after the write-back has completed and the host has read the
      // buffer out.
      if (wbwant && !rbusy && !blk_req_rd) begin
        blk_req_lba <= wb_lba;
        blk_req_wr  <= 1'b1;
        blk_slot    <= req_u;          // a write-back only exists inside a request
        blk_req_rd  <= 1'b1;
        rbusy       <= 1'b1;
        wbwant      <= 1'b0;
      end else if (bwant && !rbusy && !blk_req_rd) begin
        blk_req_lba <= blk_lba;
        blk_req_wr  <= 1'b0;
        // The drive's image this block belongs to, latched with the index it goes with: the
        // shared adapter loads its engine with the slot named here, and the walk (ST_MNT) and
        // a request (ST_SEEK onward) are the only two things that can be fetching.
        blk_slot    <= (st == ST_MNT) ? mnt_u : req_u;
        blk_req_rd  <= 1'b1;
        rbusy       <= 1'b1;
        bwant       <= 1'b0;
      end
      // The request is taken once the shared adapter has it (`blk_busy` = pc9821_block_share's
      // b_busy, which rises the cycle after the request is queued); blk_done is the completion,
      // which for a single-block request is also the cycle the last word lands in the buffer.
      // RELEASE THE REQUEST ON EITHER EDGE. `blk_busy` is the adapter taking it, but a request
      // the adapter REJECTS (past the image) pulses blk_done without ever raising busy, so
      // waiting for busy alone left blk_req_rd stuck high and the fetch engine unable to issue
      // anything again -- a dead stop on the next sector.
      if (blk_done || (blk_req_rd && blk_busy)) blk_req_rd <= 1'b0;
      // The completion is qualified by the block it DELIVERED: a request issued from a
      // finished transfer's last byte wrap (or from a previous request) can land after the
      // FSM has already moved `blk_lba` to the block it wants next, and an unqualified
      // bready would then present that stale block as the one being read.
      // ... and by the CONTEXT it was issued for: a completion that is stale (its context was
      // aborted or replaced while it was outstanding), carries an error, or lands in the very
      // cycle its context ends is NOT the block the FSM is now waiting for. R3 (set vs clear):
      // a context change coinciding with the completion retires that completion - nothing is
      // left outstanding, so `bstale` is not set for it; otherwise the change marks the fetch
      // still in flight stale and only its own completion clears the mark.
      if (blk_done) begin
        rbusy  <= 1'b0;
        bstale <= 1'b0;
        // A write-back's completion is NOT a fill: the buffer already holds what it wrote.
        if (!bstale && !blk_err && !walk_en && !abort_now && !req_accept && !blk_req_wr &&
            (blk_req_lba == blk_lba))
          bready <= 1'b1;
      end else if ((walk_en || abort_now || req_accept) && rbusy) begin
        bstale <= 1'b1;
      end

      // ===== the image lifecycle =====
      // A WALK BEGINS for one drive when (a) the engine is idle and a mount for it is waiting
      // (the live pulse, or one remembered while the module was held), or (b) the drive being
      // walked was mounted AGAIN before its header finished streaming - the bytes already in the
      // table belong to an image that is no longer mounted, so the walk starts over instead of
      // being parsed. Either way the header is read from block 0 and parsed against the size
      // that came with THAT drive's mount (mnt_size[u]), never against the live img_size.
      if (walk_en) begin
        // A walk re-reads the header from block 0. The adapter's own eject (a sub-sector
        // mount) clears this drive's `present` here through ST_PARSE finding no format.
        st                <= ST_MNT;
        mnt_u             <= walk_u;
        present[walk_u]   <= 1'b0;
        is_d88[walk_u]    <= 1'b0;
        writeprotect[walk_u] <= 1'b0;   // re-parsing: no protect state until ST_PARSE says
        mcnt              <= 11'd0;
        blk_lba           <= 16'd0;
        foff              <= 10'd0;
        bready            <= 1'b0;
        bwant             <= 1'b1;
        aerr              <= 1'b0;
        ahdrv             <= 1'b0;
        bdirty            <= 1'b0;
        wbwant            <= 1'b0;
      end else if (abort_now) begin
        // THE MEDIUM WENT AWAY UNDER THE REQUEST (or its block came back failed): answer `err`,
        // which the controller turns into a result phase and an interrupt, and return to the
        // idle state, where the mount latch's entry (if this was a mount) starts the new
        // image's walk on the next cycle. A walk that is abandoned has no requester to answer:
        // its drive's `present` is already clear (walk_en cleared it), so it simply stops.
        if (st != ST_MNT) aerr <= 1'b1;
        st     <= ST_READY;
        bwant  <= 1'b0;
        bready <= 1'b0;
        // ... and a write-back owed to that medium is DROPPED, never issued: after a mount edge
        // the slot names the NEW image, and a block of the old one written there is corruption
        // of a disk the guest never wrote to. (One already handed to the shared adapter is
        // withdrawn there - pc9821_block_share's write fence.)
        bdirty <= 1'b0;
        wbwant <= 1'b0;
      end else begin
        case (st)
          ST_NONE: ;

          // ---- the D88 header, 0x2B0 bytes streamed straight out of blocks 0 and 1 ----
          ST_MNT: if (bready) begin
            consume();
            if (mcnt == 11'h01A) fd_protect <= cur_byte;             // 0x1A is the protect byte
            if (mcnt == 11'h01B) fd_type <= cur_byte;               // 0x1B is fd_type
            // 0x1C..0x1F, LE32, [u]: bytes 0/1 whole, byte 2's low five bits, and BIG from the rest
            if (mcnt == 11'h01C) begin fd_size[mnt_u][7:0]  <= cur_byte; fd_size[mnt_u][21] <= 1'b0; end
            if (mcnt == 11'h01D) fd_size[mnt_u][15:8] <= cur_byte;
            if (mcnt == 11'h01E) begin
              fd_size[mnt_u][20:16] <= cur_byte[4:0];
              if (|cur_byte[7:5]) fd_size[mnt_u][21] <= 1'b1;
            end
            if (mcnt == 11'h01F && (|cur_byte)) fd_size[mnt_u][21] <= 1'b1;
            if ((mcnt >= 11'h020) && (mcnt < 11'h2B0)) begin
              if (mcnt[1:0] == 2'd0) tp_w[7:0]   <= cur_byte;
              if (mcnt[1:0] == 2'd1) tp_w[15:8]  <= cur_byte;
              if (mcnt[1:0] == 2'd2) begin
                tp_w[20:16] <= cur_byte[4:0];
                tp_big      <= |cur_byte[7:5];
              end
              if (mcnt[1:0] == 2'd3) begin
                // {cur_byte, tp_w} is the 32-bit little-endian entry: tp_w holds the three
                // bytes already shifted in, newest at its top. The drive's table is selected
                // by the walk's own drive, so a walk of one drive can never write the other's.
                trackp[{mnt_u, mcnt[9:2] - 8'd8}] <= {tp_big | (|cur_byte), tp_w};
                if (mcnt[9:2] == 8'd8) tp0 <= {tp_big | (|cur_byte), tp_w};
              end
            end
            if (mcnt == 11'h2AF) st <= ST_PARSE;
            mcnt <= mcnt + 11'd1;
          end

          ST_PARSE: begin
            if (d88_looks_valid) begin
              is_d88[mnt_u]  <= 1'b1;
              cls_2dd[mnt_u]   <= (fd_type[7:4] == 4'd0) || (fd_type[7:4] == 4'd1);
              cls_rpm1[mnt_u]  <= 1'b0;
              cls_minor[mnt_u] <= (fd_type[3:0] != 4'd0);
              present[mnt_u] <= 1'b1;
              // THE MEDIUM'S OWN PROTECT STATE: the D88 header's bit 4 OR the mount's
              // read-only flag - NP2kai's condition (diskimage/fd/fdd_d88.c:306), with the
              // mount flag standing in for the file attribute. Bit 4 is the only bit the D88
              // spec defines in that byte.
              writeprotect[mnt_u] <= fd_protect[4] | mnt_ro[mnt_u];
              st             <= ST_READY;
            end else begin
              is_d88[mnt_u]  <= 1'b0;
              // A raw body carries no protect field, so the mount's flag is its whole answer.
              writeprotect[mnt_u] <= mnt_ro[mnt_u];
              cls_2dd[mnt_u]   <= 1'b0;
              cls_rpm1[mnt_u]  <= 1'b0;
              cls_minor[mnt_u] <= 1'b0;
              // The size rows of fdd_xdf.c's supportxdf (headersize 0): each arm is a
              // row of the table, its label is the row's own {half-tracks, sectors, N}
              // product (RAW_SZ_*), and the three geometry registers load THAT row's
              // terms. TABLE ORDER IS MATCH ORDER - fdd_set_xdf takes the first size in
              // the table that matches (:120-134) - which is what resolves the one
              // double-claimed size (the DD6 arm's note above RAW_SZ_DD6).
              if (!walk_size[21]) begin   // the size is below 2^21 (every row is)
                case ({11'd0, walk_size[20:0]})
                  RAW_SZ_HD5: begin                       // fdd_xdf.c:26-27 {0,160,15,2,2HD,0}
                    raw_tracks[mnt_u] <= RAW_T160; raw_sects[mnt_u] <= RAW_S15;
                    raw_n[mnt_u] <= RAW_N2; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_XDF: begin                       // fdd_xdf.c:30-31 {0,154,8,3,2HD,0}
                    raw_tracks[mnt_u] <= RAW_T154; raw_sects[mnt_u] <= RAW_S8;
                    raw_n[mnt_u] <= RAW_N3; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_HD4: begin                       // fdd_xdf.c:33-34 {0,160,18,2,2HD,1}
                    cls_rpm1[mnt_u] <= 1'b1;
                    raw_tracks[mnt_u] <= RAW_T160; raw_sects[mnt_u] <= RAW_S18;
                    raw_n[mnt_u] <= RAW_N2; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_DMF: begin                       // fdd_xdf.c:35    {0,160,21,2,2HD,1}
                    cls_rpm1[mnt_u] <= 1'b1;
                    raw_tracks[mnt_u] <= RAW_T160; raw_sects[mnt_u] <= RAW_S21;
                    raw_n[mnt_u] <= RAW_N2; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_H01: begin                       // fdd_xdf.c:38-39 {0,154,26,1,2HD,0}
                    raw_tracks[mnt_u] <= RAW_T154; raw_sects[mnt_u] <= RAW_S26;
                    raw_n[mnt_u] <= RAW_N1; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_HD9: begin                       // fdd_xdf.c:40    {0,154,9,3,2HD,0}
                    raw_tracks[mnt_u] <= RAW_T154; raw_sects[mnt_u] <= RAW_S9;
                    raw_n[mnt_u] <= RAW_N3; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_DD6: begin                       // fdd_xdf.c:41    {0,160,8,2,2DD,0}
                    cls_2dd[mnt_u] <= 1'b1;
                    raw_tracks[mnt_u] <= RAW_T160; raw_sects[mnt_u] <= RAW_S8;
                    raw_n[mnt_u] <= RAW_N2; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_DD9: begin                       // fdd_xdf.c:42    {0,160,9,2,2DD,0}
                    cls_2dd[mnt_u] <= 1'b1;
                    raw_tracks[mnt_u] <= RAW_T160; raw_sects[mnt_u] <= RAW_S9;
                    raw_n[mnt_u] <= RAW_N2; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_T156: begin                      // fdd_xdf.c:70    {0,156,8,3,2HD,0}
                    raw_tracks[mnt_u] <= RAW_T156; raw_sects[mnt_u] <= RAW_S8;
                    raw_n[mnt_u] <= RAW_N3; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_T158: begin                      // fdd_xdf.c:71    {0,158,8,3,2HD,0}
                    raw_tracks[mnt_u] <= RAW_T158; raw_sects[mnt_u] <= RAW_S8;
                    raw_n[mnt_u] <= RAW_N3; present[mnt_u] <= 1'b1;
                  end
                  RAW_SZ_T160: begin                      // fdd_xdf.c:72    {0,160,8,3,2HD,0}
                    raw_tracks[mnt_u] <= RAW_T160; raw_sects[mnt_u] <= RAW_S8;
                    raw_n[mnt_u] <= RAW_N3; present[mnt_u] <= 1'b1;
                  end
                  default:     present[mnt_u] <= 1'b0;
                endcase
              end else present[mnt_u] <= 1'b0;
              st <= ST_READY;
            end
          end

          // The answer LEVELS (err, hdrv) stand until the NEXT request clears them, so the
          // controller can never miss a one-cycle pulse; `ready` is the level it waits on.
          ST_READY: begin
            // A REQUEST FOR A DRIVE WITH NO MEDIUM - or one whose mount edge is this very cycle -
            // is answered `err` at once and never reaches the seek, so it cannot be served from
            // the geometry of an image that is gone. The controller does not issue one while its
            // media_present is clear; this covers the cycle the two cross.
            if (req && (!present[unit[0]] || mnt_ev[unit[0]])) begin
              aerr  <= 1'b1;
              ahdrv <= 1'b0;
            end else if (req) begin
              aerr  <= 1'b0;
              ahdrv <= 1'b0;
              req_u <= unit[0];   // the drive EVERY read below is indexed by
              rq_hdr <= req_hdr && !req_wr;
              rq_wr  <= req_wr;
              rq_fmt <= req_wr && req_hdr;
              rq_c   <= req_c;
              rq_h   <= req_h;
              rq_tc  <= req_tc;
              rq_hd  <= req_hd;
              rq_mf  <= req_mf;
              rq_2hd <= req_2hd;
              rq_rpm <= req_rpm;
              rq_r   <= req_r;
              rq_n   <= req_n;
              rq_idx <= req_idx;
              raw_off <= raw_off_a;   // the same accept edge (see raw_off_a)
              // seek_off needs the just-latched geometry, so the seek itself is one
              // state later (ST_SEEK reads the latched rq_* through the combinational
              // wires above).
              st <= ST_SEEK;
            end
          end

          ST_SEEK: begin
            // A RAW image has no headers on the medium at all: READ ID is answered from
            // the geometry (fdd_readid_common, diskimage/fddfile.c:319-345), so this
            // branch touches no block. Its ordinal bound is the geometry's sector count,
            // and R = the ordinal + 1 with N = the row's N (:325-340).
            if (!is_d88[req_u] && rq_hdr) begin
              if ((rq_track < {24'd0, raw_tracks[req_u]}) && (rq_idx < raw_sects[req_u]) && rq_mf && mode_ok) begin
                hdr_r     <= rq_idx + 8'd1;
                hdr_n     <= raw_n[req_u];
                hdr_sects <= raw_sects[req_u];
                ahdrv     <= 1'b1;
              end else begin
                aerr <= 1'b1;
              end
              st <= ST_READY;
            end
            // Bounds, on the reference's own terms: a D88 track pointer of zero (or one
            // at/over the declared extent) is "sector not found"; a raw request out of
            // range is NP2kai's fdd_seeksector_common failure (diskimage/fddfile.c:294-310:
            // treg >= tracks>>1 fails, R outside 1..sectors fails) and a raw N that is not
            // the geometry's N is its fdd_read_xdf 0xC0 (diskimage/fd/fdd_xdf.c:341-343).
            // EVERY term is the DRIVE'S OWN (req_u) - the three raw geometry registers are
            // indexed by it: the geometry the FDC reached the data path with is the one that
            // drive was mounted with (pc9821_fdc's media_present), and a second drive's
            // image must not answer this request's bounds.
            // A WRITE adds two refusals: a FORMAT sector on a D88 (NP2kai formats a D88 by
            // rebuilding the track, fdd_formating_d88 - not modelled), and a raw write whose EOT
            // (carried in req_idx) is past the track's sector count, fdd_write_xdf's
            // `if (fdc.eot > fdd->inf.xdf.sectors)` -> 0xc0 (diskimage/fd/fdd_xdf.c:399-404). A
            // raw FORMAT's EOT is its SC, which fdd_formatinit_xdf does not test, so the raw
            // EOT test is a write's only.
            else if (!mode_ok || (is_d88[req_u]
                  ? ((seek_off == 25'd0) || (seek_off >= {4'd0, fd_size[req_u][20:0]}) ||
                     (rq_track > 32'd163) || rq_fmt)
                  : ((rq_track >= {24'd0, raw_tracks[req_u]}) || (rq_r == 8'd0) ||
                     (!rq_mf && !rq_fmt) ||
                     (rq_r > raw_sects[req_u]) || (rq_n != raw_n[req_u]) ||
                     (rq_wr && !rq_fmt && (rq_idx > raw_sects[req_u])) ||
                     (seek_off >= {4'd0, mnt_size[req_u][20:0]})))) begin
              aerr <= 1'b1;
              st   <= ST_READY;
            end else begin
              blk_lba  <= seek_off[24:9];   // 16 bits: bounded by D88_MAX_EXTENT, and (raw) by
                                            // the widest row's extent RAW_MAX_EXTENT; both
                                            // are guarded above
              foff     <= {1'b0, seek_off[8:0]};
              img_left <= (is_d88[req_u] ? fd_size[req_u][20:0] : mnt_size[req_u][20:0]) - seek_off[20:0];
              bready   <= 1'b0;
              bwant    <= 1'b1;
              bdirty   <= 1'b0;
              wlo_v    <= 1'b0;
              seen     <= 8'd0;
              hi       <= 5'd0;
              skip_left<= 16'd0;
              st       <= ST_WAIT;
            end
          end

          // A raw DATA request streams its sector straight from the seek (the raw path
          // above already handled the header case); a D88 request walks its track.
          ST_WAIT: if (bready) begin
            if (is_d88[req_u]) begin
              st <= ST_SCAN;
            end else begin
              emit_left <= rq_sec_bytes;
              file_left <= rq_sec_bytes;
              st        <= ST_DATA;
            end
          end

          // ---- one 16-byte _D88SEC ----
          ST_SCAN: begin
            if (hi[4]) begin
              // All 16 bytes are in hb. A data match is (c,h,r,n) equal, exactly
              // searchsector_d88's test (fdd_d88.c:232-236); the READ ID walk instead
              // takes the req_idx-th header (fdd_readid_d88, :513-518).
              if ((!rq_hdr && (hb[0] == rq_c) && (hb[1] == rq_h) &&
                   (hb[2] == rq_r) && (hb[3] == rq_n)) ||
                  (rq_hdr && (seen == rq_idx))) begin
                if (!rq_wr && (rq_mf == hb[6][6])) begin
                  // the header matched in the other recording mode: no sector (the
                  // searchsector_d88 `break` above the port note)
                  aerr <= 1'b1;
                  st   <= ST_READY;
                end else if (rq_hdr) begin
                  hdr_r     <= hb[2];
                  hdr_n     <= hb[3];
                  hdr_sects <= hdr_sectors[7:0];
                  ahdrv     <= 1'b1;
                  st        <= ST_READY;
                end else begin
                  // The stored byte count is the header's size field; the read returns
                  // min(128 << N, size) file bytes and zeroes after that
                  // (fdd_read_d88, :427-443), with the file count also bounded by the
                  // image (scan_file_ok above, P2-e). The stream is already positioned
                  // on the first data byte, so no seek is needed.
                  emit_left <= rq_sec_bytes;
                  file_left <= scan_file_ok;
                  st <= ST_DATA;
                end
              end else begin
                seen <= seen + 8'd1;
                // `if (++sec >= sectors) break` (fdd_d88.c:250-252): the track's own
                // count bounds the walk, and 40 is NP2kai's hard bound on the loop.
                if (({8'd0, seen} + 16'd1 >= hdr_sectors) || (seen >= 8'd39) ||
                    (img_left < 21'd16)) begin
                  aerr <= 1'b1;
                  st   <= ST_READY;
                end else begin
                  skip_left <= hdr_size;
                  hi        <= 5'd0;
                  st        <= ST_SKIP;
                end
              end
            end else if (bready && (img_left != 21'd0)) begin
              hb[hi[3:0]] <= cur_byte;
              hi  <= hi + 5'd1;
              consume();
            end else if (bready) begin
              aerr <= 1'b1;
              st   <= ST_READY;
            end
          end

          ST_SKIP: if (skip_left == 16'd0) begin
            st <= ST_SCAN;
          end else if (bready && (img_left != 21'd0)) begin
            skip_left <= skip_left - 16'd1;
            consume();
          end else if (bready) begin
            aerr <= 1'b1;
            st   <= ST_READY;
          end

          ST_DATA: if (adv) begin
            emit_left <= emit_left - 16'd1;
            if (file_left != 16'd0) begin
              file_left <= file_left - 16'd1;
              consume();
            end
            // A WRITE: the byte went into the buffer (blk's write port, w_byte above). Leaving the
            // block (its 512th byte) schedules it for write-back with the cursor's block index
            // before consume() moves it on; the read of the next block waits behind it.
            // The sector's LAST byte schedules the block it ends in the same way (if a byte of it
            // is still unwritten-back), and the request ends only when that write-back has
            // completed (ST_WB). Each register below is written once here (R2).
            if (w_byte) begin
              wlo   <= din;
              wlo_v <= !foff[0];
            end
            if (w_sched) begin
              wbwant <= 1'b1;
              wb_lba <= blk_lba;
            end
            if (w_byte || w_last) bdirty <= w_last ? 1'b0 : w_dirty;
            if (emit_left == 16'd1) st <= rq_wr ? ST_WB : ST_READY;
          end

          // THE WRITE'S LAST BLOCK IS GOING BACK: `ready` (and with it the controller's next
          // step and its result) waits until no write-back is owed or outstanding. A failed one
          // ends the request with `err` (fail_ctx), a mount edge with abort_req.
          ST_WB: if (!wbwant && !(rbusy && blk_req_wr)) st <= ST_READY;

          default: st <= ST_READY;
        endcase
      end
    end
    // READY DROPS ON THE MOUNT EDGE (the media-change block above), in AND out of reset: a
    // mount that lands while the module is held is still a medium that is no longer the one
    // parsed. R3 (set vs clear): this is the LAST write to these bits, so a mount edge that
    // coincides with ST_PARSE setting the same drive's `present` wins - the parse belonged to
    // the image being replaced, and the mount latch's fresh entry walks the new one.
    for (i = 0; i < 2; i = i + 1)
      if (mnt_ev[i]) begin
        present[i]      <= 1'b0;
        writeprotect[i] <= 1'b0;
      end
  end

`ifndef SYNTHESIS
  // R8: a write-back is never scheduled in the cycle the fetch engine issues the previous one
  // (w_sched's R3 note) - that coincidence would lose the earlier block's write-back.
  always @(posedge clk)
    if (!reset && w_sched && wbwant)
      $error("pc9821_fdd_media: a write-back scheduled while one is still owed (a block would be lost)");
  // R8: the medium never presents a byte for a drive that has no medium. `present[req_u]`
  // clears on the mount edge and the same edge aborts the request (abort_req), so a `rdy`
  // standing with its drive not present is a media change that leaked a byte of the old image.
  always @(posedge clk)
    if (!reset && rdy && !present[req_u])
      $error("pc9821_fdd_media: rdy for drive %0d with no medium (a media change leaked a byte)",
             req_u);
`endif

endmodule

`default_nettype wire
