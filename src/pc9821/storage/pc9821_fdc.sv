// PC-98 floppy-disk-controller (NEC uPD72065 / uPD765A class) model.
//
// Two jobs, in one instance, because the machine has one controller behind one
// register set:
//
//  1. THE PROBE SUBSET. It exists so the main BIOS's FDD probe resolves: with no FDC
//     response the probe polls DS:0x55E (BANK7@0x723F) forever for a nibble only the FDC
//     ISR at IVT vector 0x13 (slave PIC IRQ11) writes. The model answers the probe's
//     sequence -- SPECIFY, RECALIBRATE per drive, SENSE DRIVE STATUS and READ ID --
//     raises IRQ11 on each completing command, and serves SENSE INTERRUPT STATUS so the
//     ISR can OR one bit per drive into 0x55E. The captured sequence, the waived
//     deviations and the 0x92 idle byte (the machine's 0x80, not NP2kai's zeroed
//     lastdata latch) are all still here.
//
//  2. THE DATA PATH: with media mounted
//     in a drive, READ DATA and READ ID behave as NP2kai io/fdc.c specifies, including
//     the seven-byte result phase and the DMA byte handshake on the uPD71071's channel 2.
//     The disk medium itself is pc9821_fdd_media, reached over the sector seam below.
//
// WHY THE TWO PATHS STILL COEXIST. The media-present data path answers in the result
// phase, NP2kai's shape (fdcsend_success7/error7, io/fdc.c:98-158); the no-media answer is
// the deferred completion - the command runs, claims its drive, and its ST0
// arrives through SENSE INTERRUPT STATUS - because changing its SHAPE would change every
// existing, bench-pinned no-media answer in this tree in one go. WHAT IS NO LONGER
// DEFERRED IS THE CLASS: the ST0 those commands leave is NP2kai's own per-state value now
// (see `rec_st0` / `data_st0` below), and that is what makes an equipped drive with no
// diskette report as PRESENT to the BIOS instead of absent. `media_present` gates which
// path a command takes, so it is part of the contract, not an optimisation.
//
// Ports (decoded in pc9821_iobus): 0x90 MSR, 0x92 data, 0x94 DOR, 0x04BE the
// 1.44M/RPM register (NP2kai io/fdc.c:1117-1134), and 0x00BE/0x00BF the
// channel-group/media register (fdc_obe/fdc_ibe, io/fdc.c:1096-1114). THE SAME
// THREE REGISTER PORTS ARE ALSO REACHED AT 0xC8/0xCA/0xCC: the machine has ONE
// controller behind two port windows and the 0x00BE strap (chgreg bit 0, exported
// as `strap_2hd`) selects which window answers, which IRQ the completion goes to
// (11 vs 10) and which DMA channel carries it (2 vs 3). See pc9821_iobus for the
// gate and the routing, and `win_2dd` below for the one per-window byte.
// THE INACTIVE WINDOW reads 0xFF: NP2kai io/fdc.c fdc_i90 `if (((port >> 4) ^ fdc.chgreg) & 1)
// { return(0xff); }`, and the machine agrees - docs/probes/FDMODE-XE10.TXT `PORT 00C8=FF` with the
// 1 MB interface selected. (MAME maps its one uPD765 at both windows with the mode check left as
// a TODO, pc9801.cpp `map(0x00c8, 0x00cb).m(m_fdc_2hd, ...)`; outranked by the capture.) With
// 0x00BE bit 2 = the FDD-mode switch (`dip_fixed`, below). FIXED (1): the BIOS POST does NOT
// initialise the 640 KB window while bit 0 selects the 1 MB one (BANK7@0x7CAE: bit 2 set and
// bit 0 set -> [0x501] bit 7, clear on this machine -> skip), so no MSR wait at 0xC8 happens,
// IRQ10 stays masked, and INT 1Bh DA/UA 0x7x answers AH = 0x40 at its IRQ10 check
// (BANK7@0x74D3) - the measured unit's own answer (FDMODE-XE10.TXT `SENSE DA=70 AH=40 CF=1`).
// AUTO (0): POST initialises the 640 KB window too (BANK7@0x7736, IRQ10 unmasked at 0x7761),
// so a 2DD boot disk that calls INT 1Bh with DA/UA 0x70 is served.
// MSR bits:
// 7 RQM, 6 DIO, 5 NDM, 4 CB, 3:0 the per-drive busy bits -- the byte is
// NP2kai's fdc.status verbatim (fdc_i90, io/fdc.c:1035-1043); the firmware
// polls bit 4 then tests (MSR & 0xC0) == 0x80 to write.
//
// THE DATA-PHASE CONTRACT (NP2kai io/fdc.c, the primary software reference):
//   * FDC_ReadData (:461-510) takes FDC_DMACH2HD = 2 (:22-25) and walks R from the
//     command's R to EOT; at EOT it wraps R to 1 and, with MT set, flips head and
//     continues on the other side of the same cylinder, then finishes (C++).
//   * fdc_dataread (:897-952) moves one byte per call and terminates the command on the
//     DMA's terminal count, answering success7 with R forced to 1 (:925-932).
//   * fdcsend_success7 (:120-158) is {hd<<2|us, 0, 0, C, H, R, N};
//     fdcsend_error7 (:98-119) is {(stat>>0), (stat>>8), (stat>>16), C, H, R, N}, and
//     a missing sector is ST0 = us|hd<<2|IC0 and ST1 = ND (readsector, :417-427).
//   * status: RQM|CB|DIO through both the data phase (readsector, :440-454) and the
//     result phase, with the drive-busy bit and NDM following fdc.status's own fields.
//
// The counter is the FDC's own (128 << N bytes per sector) and the media's read pointer
// follows it byte for byte, so neither can run ahead of the other.

`default_nettype none

module pc9821_fdc #(
    parameter integer SYS_CLOCK_HZ = 50_000_000,
    // Recalibrate completion delay. The real chip's seek time is milliseconds;
    // the firmware only needs it long enough to be asynchronous (~tens of us),
    // and it must stay far below the probe's 96*65536-iteration poll timeout.
    // 20 us, so 1000 cycles at 50 MHz.
    parameter [15:0] RECAL_CYCLES = 16'(SYS_CLOCK_HZ / 50_000)
) (
    input  wire       clk,
    input  wire       reset,
    // THE FDD-MODE SWITCH, read back as 0x00BE/0x00BF bit 2: 1 = Fixed, 0 = Auto-Detection.
    // Both settings exist on the machine: MAME pc9801.cpp fdc_mode_r `(m_dsw3->read() & 3) << 2`
    // with DSW3:1 "FDD Fix Mode" (Fixed / Auto-Detection); the measured unit is set to Fixed
    // (docs/probes/FDMODE-XE10.TXT `PORT 00BE=FF`), NP2kai's fdc_ibe reads Auto (bit 2 = 0).
    // A switch is sampled by POST, so the input is latched on reset only (dip_fixed_q): a
    // change applies at the next machine reset, never under the running firmware.
    input  wire       dip_fixed,
    input  wire       cs,
    input  wire [2:0] addr,   // 0 = 0x90 MSR, 1 = 0x92 data, 2 = 0x94 DOR, 3 = 0x04BE 1.44M/RPM, 4 = 0x00BE/0x00BF channel group
    input  wire       wr,
    input  wire       rd,
    input  wire [7:0] din,
    output reg  [7:0] dout,
    output reg        irq,
    // THE COMMAND-RESULT DRAIN, one cycle.
    // Pulsed when the guest reads the LAST byte of a command's result phase - the
    // command's final event. It was the cache-flush trigger's anchor for transfers
    // that end WITHOUT a DMA terminal count (the EOT end leaves the uPD71071's count
    // unexhausted, so pc9821_dmac's mem_tc never fires for it); the per-write DMA
    // snoop (T24) replaced that, so pc9821_iobus now keeps the output on a retired
    // wire and nothing consumes it. Kept (not deleted) so the event stays observable
    // and a future consumer has the same anchor.
    output wire       res_done,
    // WHICH PORT WINDOW this access arrived at: 1 = the 2DD bank at 0xC8/0xCA/0xCC,
    // 0 = the 2HD one at 0x90/0x92/0x94 (or either windowless register, 0x04BE and
    // 0x00BE/0x00BF). One controller is reachable through two doors and the guest's
    // strap picks which; this input says only which door was used, so the control
    // port can answer its per-window byte below.
    input  wire       win_2dd,
    // THE INTERFACE STRAP, exported: chgreg bit 0 (NP2kai's `fdc.chgreg & 1`). 1
    // selects the 2HD window at 0x90 and, with it, IRQ11 and DMA channel 2; 0
    // selects the 2DD window at 0xC8 with IRQ10 and channel 3. NP2kai reads it live
    // in fdc_i90/fdc_i92/fdc_i94 and at the top of fdc_o92/fdc_o94 (the I/O port
    // gate, io/fdc.c:975/996/1040/1050/1068), picks the IRQ from it in fdc_intwait
    // (:43-56) and the DMA channel in fdc_dmaready (:85-92); the firmware's window
    // branch and its channel select are the same bit (see the header). iobus gates
    // the window decode and routes the IRQ/DMA strobes with it.
    output wire       strap_2hd,

    // ---- the drive/media seam (pc9821_fdd_media) ----
    // One bit per drive: the media module has a supported image for that unit. The
    // data path below is taken for a unit whose bit is set and the probe subset's
    // no-media answers are kept for a unit whose bit is clear (see the header).
    input  wire [3:0] media_present,   // one bit per unit; units 2/3 are never equipped
    // [u] the MEDIUM is write-protected, FOUR bits like `media_present` so the unit index
    // (din[1:0]) is in range for both (units 2/3 are always 0): the D88 header's own protect bit OR the mount's
    // read-only flag (pc9821_fdd_media computes it, NP2kai's `fddfile[].protect`). Two consumers,
    // both NP2kai's: SENSE DRIVE STATUS's WP bit (FDC_SenseDeviceStatus) and the write commands'
    // FDC_DriveCheck(TRUE) (io/fdc.c:175-193), which answers IC0|NW for a protected medium and
    // lets WRITE DATA / WRITE DELETED DATA through otherwise (Stage B, the write path).
    input  wire [3:0] writeprotect,   // [u], units 2/3 always zero (the seam's shape)
    // [u] THE MEDIA-CHANGE TAG, a LEVEL from pc9821_fdd_media that toggles once per mount event
    // of drive u (insert, swap or eject - hps_io's mount edge). A toggle rather than a pulse so
    // the event crosses the module boundary as data this module consumes alone (R1/R6): the
    // change is `media_chg ^ chg_q`, and chg_q follows the tag through reset, so a mount that
    // lands while the controller is held (the power-on mount during the pack download) is NOT a
    // change the guest is told about - NP2kai's fdc_reset zeroes fdc.stat[] the same way
    // (io/fdc.c:1236 `ZeroMemory(&fdc, sizeof(fdc));`). Units 2/3 are never equipped (tie 0).
    /* verilator lint_off UNUSEDSIGNAL */   // [3:2]: units 2/3 are never equipped (FDD_DRIVES)
    input  wire [3:0] media_chg,
    /* verilator lint_on UNUSEDSIGNAL */
    // THE GUEST'S FRAME, one clk_sys pulse per VSYNC (pc9821_crtc's vsync_edge). NP2kai counts its
    // insert delay in calls of diskdrv_callback, which pccore_exec makes once per emulated screen
    // frame (pccore.c:2016 `diskdrv_callback();`, inside the per-frame pccore_exec that runs to
    // screendisp), so the delay is a number of guest frames, not a wall-clock constant.
    input  wire       frame_tick,
    output wire       media_req,      // one-cycle: start the request named below
    output wire       media_req_hdr,  // 1 = the sector HEADER at media_idx (READ ID)
    output wire [1:0] media_unit,
    // THE SECTOR'S ID (media_c/media_h, with media_r/media_n) AND THE TRACK IT IS LOOKED FOR ON
    // (media_tc/media_hd) ARE SEPARATE. NP2kai locates a sector on the physical track
    // `(fdc.treg[fdc.us] << 1) + fdc.hd` (fdd_d88.c fdd_read_d88 `trkseek(fdd, (fdc.treg[...`)
    // and matches the header against the COMMAND's C/H (searchsector_d88 `->c == fdc.C`,
    // `->h == fdc.H`), so a medium whose ID C/H differ from its physical cylinder/side is read
    // where the head is, not where the ID says.
    output wire [7:0] media_c,
    output wire [7:0] media_h,
    output wire [7:0] media_tc,       // the physical cylinder: the drive's track register
    output wire       media_hd,       // the physical side: the command's HD bit
    // THE COMMAND'S RECORDING MODE, MF (bit 6 of the opcode byte; 1 = MFM): NP2kai's
    // `fdc.mf = fdc.cmd & 0x40` (io/fdc.c get_mtmfsk), which the medium checks - an FM command
    // finds no sector on an MFM medium. The BIOS boot tries FM first and retries MFM on ND.
    output wire       media_mf,
    // THE MEDIA MODE the medium is read in: the 0x00BE register's bit 1 (NP2kai CTRL_FDMEDIA,
    // io/fdc.c fdc_obe) and the unit's 0x04BE rpm bit (fdc.rpm[us]); see pc9821_fdd_media req_2hd.
    output wire       media_2hd,
    output wire       media_rpm,
    output wire [7:0] media_r,
    output wire [7:0] media_n,
    output wire [7:0] media_idx,
    // THE WRITE LEG (Stage B). `media_wr` is held with the request and says it is a WRITE DATA
    // sector: the medium locates the sector exactly as for a read, then `rdy` means "a byte can
    // be TAKEN at the pointer" and each `adv` stores `media_din` there. The medium writes the
    // sector back to the image before it is `ready` again, which is what the controller waits
    // on before it posts the sector's result (NP2kai's writesector: fdd_write() runs before
    // fdcsend_success7, io/fdc.c:394-405 and :457-485).
    output wire       media_wr,
    output wire [7:0] media_din,
    // THE CONTROLLER ABANDONED THE REQUEST IN FLIGHT (one cycle): a READ DATA whose terminal
    // count ends inside a sector (NP2kai answers at once and simply stops reading, io/fdc.c
    // :1016-1026), or a DOR reset in the middle of a data command (fdcstatusreset, :851-855,
    // drops the event). The medium is then mid-sector with bytes owed that nobody will take;
    // without this it stayed there, `ready` never rose again and the next data command waited
    // forever. One consumer, pc9821_fdd_media (single-cycle-event-discipline R1).
    output wire       media_abort,
    input  wire       media_ready,    // level: the media can accept a request
    input  wire       media_rdy,      // level: the requested sector's byte is available
    input  wire       media_hdrv,     // level: the READ ID answer is available
    input  wire       media_err,      // level: the request failed (sector/header gone)
    input  wire [7:0] media_dout,     // the byte at the media's read pointer
    input  wire [7:0] media_hr,
    input  wire [7:0] media_hn,
    input  wire [7:0] media_hs,       // the track's sector count (READ ID's crcn wrap)
    output wire       media_adv,      // one-cycle: consume the media byte
    // ---- the uPD71071 device port: DMA channel 2 (2HD) ----
    // The controller is the PORT side of a port-to-memory transfer, so it drives the
    // byte the engine stores (pc9821_dmac's dev_din) and qualifies the handshake with
    // its own channel's DACK. iobus wires `dma_stb`/`dma_tc` from dev_ch == 2.
    output wire       dma_drq,        // level: a byte is ready for the DMA controller
    input  wire       dma_dack,       // this channel's DACK (dev_dack[2])
    input  wire       dma_stb,        // the strobe cycle (dev_stb && dev_ch == 2)
    input  wire       dma_tc,         // terminal count, WITH the final strobe
    output wire [7:0] dma_dout,       // the byte presented to the engine's data input
    // The MEMORY-TO-PORT leg, for WRITE DATA: the engine's direction (pc9821_dmac's dev_we,
    // 1 = memory to port) and the byte it read from memory (its dev_dout), valid in the strobe
    // cycle. A strobe in the other direction carries no byte for a write: NP2kai's DMA calls
    // fdc_dataread for a port-to-memory channel, and that does nothing in FDCEVENT_BUFRECV
    // (io/fdc.c:985-1036 has no BUFRECV arm), so only a memory-to-port strobe moves a byte here.
    input  wire       dma_we,
    input  wire [7:0] dma_din,
    // ---- debug taps for the stall record (pc9821_watchdog_msg's FST/FCM/FRS/FCH) ----
    // Pure views of state this module already holds - no logic of their own - so a
    // failing floppy transfer can be read out of a serial capture. With the telemetry
    // compiled out (PERF_LOG_EN=0) these outputs are unconnected and prune away.
    output wire [7:0] dbg_state,      // {IRQ, DRQ, st[2:0], x_st[2:0]}
    output wire [7:0] dbg_cmd,        // the last command byte: {cmd_mt, 2'b00, cmd[4:0]}
    output wire [31:0] dbg_result,    // {res0, res1, 0, exec_st0}: the last result
    output wire [31:0] dbg_chrn       // {x_c, x_h, x_r, x_n}: the sector in flight
);
  localparam [2:0] A_MSR  = 3'd0, A_DATA = 3'd1, A_DOR = 3'd2, A_REG144 = 3'd3,
                   A_CHGREG = 3'd4;

  localparam [2:0] ST_IDLE   = 3'd0,  // ready for a command byte
                   ST_PARAM  = 3'd1,  // collecting parameters
                   ST_EXEC   = 3'd2,  // command running, CB set
                   ST_RESULT = 3'd3;  // result bytes available, DIO set

  reg [2:0]  st;
  reg [4:0]  cmd;
  reg        cmd_mt;           // the command byte's MT (bit 7), for READ DATA's walk
  reg        cmd_mf;           // the command byte's MF (bit 6): 1 = MFM (NP2kai get_mtmfsk)
  reg [3:0]  param_left;
  reg [2:0]  p_idx;            // parameters received for the command in flight
  reg [7:0]  cmds [0:7];       // the parameter bytes, NP2kai's fdc.cmds[]
  reg [1:0]  drv;
  reg [15:0] delay;

  // THE DEFERRED COMPLETION'S ST0, latched when the command is accepted. A SEEK or
  // RECALIBRATE that finds media completes with the reference's SE|us; the same commands
  // with NO media get the per-state class `deferred_st0` - NP2kai's SE|NR for an equipped
  // drive, its SE|IC0|NR (or SE|IC0|EC under the forced-ready strap) for a unit that is
  // not there - as do the other commands that reach ST_EXEC. Latching the byte at accept
  // time keeps `drv`/`cmds` free to move on and lets both classes share one completion
  // path.
  reg [7:0]  exec_st0;

  // The MSR low nibble and bit 5, NP2kai's fdc.status fields (fdc_i90 returns
  // the register verbatim, io/fdc.c:1035-1043). busy is one drive-busy bit per
  // unit, (1 << us), carried from the command's claim point to the drain of the
  // result that reports it: RECALIBRATE/SEEK claim at their CMDRECV arm
  // (fdc.c:562-563, 773-774), SENSE DRIVE STATUS at its result build
  // (fdc.c:300-302) and the interrupt sends at theirs (fdc.c:111-113,
  // 148-150); fdc_dataread's result drain clears the bit (fdc.c:907-909). nd
  // is SPECIFY's ND latch (fdc.c:265) and drives NDM only over a data command's
  // transfer window (fdc.c:362-366/450-454/686-690).
  reg [3:0]  busy;
  reg        nd;

  // Track register per drive, NP2kai's fdc.treg[us] (io/fdc.h:66-79). Only the media
  // path and SEEK move it, and ST3's T0 bit reports treg == 0 (:277-281), so the
  // no-media answers the probe subset pinned are unchanged.
  reg [7:0]  treg [0:3];
  // NP2kai's fdc_lasttreg[us] (io/fdc.c:21 `static int fdc_lasttreg[4]`): the track register
  // as the last SEEK left it (FDC_Seek :850 `fdc_lasttreg[fdc.us] = fdc.treg[fdc.us];`). READ
  // DATA and WRITE DATA replace treg with the command's C ONLY when it differs
  // (:301-303/:435-437 `if (fdc_lasttreg[fdc.us] != fdc.treg[fdc.us]) { fdc.treg[fdc.us] =
  // fdc.C;`), so after a SEEK the head stays on the seeked cylinder whatever ID C the command
  // names. NOT the datasheet uPD765 (whose READ DATA never moves PCN): the reference's own
  // provisional rule, followed as the primary reference and recorded as such.
  reg [7:0]  lasttreg [0:3];
  reg [7:0]  crcn;             // READ ID's per-track header ordinal (fdd_d88.c:494-552)

  // 0x04BE, the 1.44M/RPM register (NP2kai io/fdc.c:1117-1134): the write keeps the
  // DRIVE SELECT (its bits 6:5, the only field fdc_i4be ever reads back) and, when its
  // bit 4 is set, bit 0 to the RPM of that drive; the read answers rpm[sel] | 0xFE.
  reg [1:0]  reg144_sel;
  reg [3:0]  rpm;

  // 0x00BE/0x00BF, the FDD channel-group register (NP2kai fdc_obe/fdc_ibe,
  // io/fdc.c:1096-1114): the write stores the byte (its bit 1 selects 2HD vs 2DD
  // media) and the read answers (chgreg & 3) | 0xF8 | dip_fixed << 2 (0xFC with the FDD-mode
  // switch at Fixed, 0xF8 at Auto; the A_CHGREG read) - DOS's FDD driver reads the
  // 2HD/2DD media strap here. Reset is NP2kai fdc_reset's `fdc.chgreg = 3`.
  // fdc_ibe reads back only bits 1:0 (NP2kai io/fdc.c:1202); bit 2 gates the insert's ready
  // interrupt (fdd/diskdrv.c:239, `ai_gate` below); bits 7:3 carry no behaviour.
  /* verilator lint_off UNUSEDSIGNAL */
  reg [7:0]  chgreg;
  /* verilator lint_on UNUSEDSIGNAL */

  // The control/DOR port (0x94 / 0xCC) is READ-WRITE in NP2kai: the read is fdc_i94's
  // computed byte (A_DOR above), and the WRITE (fdc_o94, io/fdc.c:996-1032) STORES the
  // byte and RESETS the controller on a bit-4 change or a 0->1 bit-7 edge. `ctrlreg` is
  // that stored byte, reset to 0 exactly as fdc_reset's ZeroMemory leaves it.
  reg [7:0]  ctrlreg;

  // One queued completion per drive (bit d = drive d completed) and its ST0, for the
  // commands whose result the probe subset defers to SENSE INTERRUPT STATUS.
  reg [3:0]  pend;
  reg [7:0]  pend_st0 [0:3];

  // The result phase, up to seven bytes: {ST0, ST1, ST2, C, H, R, N}. ST0 and ST1 are stored (res0 /
  // res1 are also what the probe subset's one- and two-byte answers use, the status byte and the PCN);
  // ST2 is always 0, and C/H/R/N are the SECTOR REGISTERS x_c/x_h/x_r/x_n themselves, which each
  // result site leaves holding the bytes it reports (the command is over, so nothing else reads them
  // before the next command loads them) - instead of five more stored bytes behind a copy at every site.
  reg [7:0]  res0, res1;
  reg [2:0]  res_len, res_idx;
  reg        res_pop;        // this result consumes a pending status when drained
  reg        res_rel;        // and/or releases its drive's busy bit
  reg        res_irq;        // this result's interrupt is raised with it (data path)
  reg [1:0]  res_drv;

  // The result byte the data port presents (ST2 is always 0; C/H/R/N are the sector registers).
  wire [7:0] res_byte = (res_idx == 3'd0) ? res0 :
                        (res_idx == 3'd1) ? res1 :
                        (res_idx == 3'd2) ? 8'h00 :
                        (res_idx == 3'd3) ? x_c :
                        (res_idx == 3'd4) ? x_h :
                        (res_idx == 3'd5) ? x_r : x_n;

  wire [1:0] pend_drv = pend[0] ? 2'd0 : pend[1] ? 2'd1 : pend[2] ? 2'd2 : 2'd3;

  // ------------------------------------------------------------------ data path state
  localparam [2:0] X_IDLE  = 3'd0,  // no data command in flight
                   X_REQ   = 3'd1,  // a media request is being issued / awaited
                   X_XFER  = 3'd2,  // the sector's bytes are moving
                   X_WEND  = 3'd3,  // a WRITE sector's bytes are in: wait for the medium to
                                    // have written it, then take FDC_WriteData's next step
                   X_NDW   = 3'd4;  // the sector is not there: search until the 2nd index pulse
  reg [2:0]  x_st;
  reg        x_isid;          // the request in flight is a READ ID header
  // THE WRITE COMMAND'S STATE (Stage B). x_wr: the command in flight is WRITE DATA / WRITE
  // DELETED DATA. x_disc: the medium could not locate this sector, so its bytes are TAKEN AND
  // DROPPED and the sector then fails - NP2kai receives the whole 128 << N buffer before
  // writesector() looks the sector up (FDC_WriteData's CMDRECV arms FDCEVENT_BUFRECV straight
  // after FDC_DriveCheck, io/fdc.c:427-455; fdd_write() runs once the buffer is full,
  // :394-405), so the guest's DMA count moves by a sector before the IC0|ND answer. x_pad: the
  // DMA's terminal count arrived mid-sector, so the rest of the sector is completed from the
  // medium's own bytes (see the X_XFER arm). x_tc: the terminal count has been seen.
  reg        x_wr;
  // x_fmt: the command in flight is FORMAT (WRITE ID) on a raw image - NP2kai's
  // fdd_formatinit_xdf (diskimage/fd/fdd_xdf.c:433-517) fills SC sectors of 128 << N bytes with
  // the filler D at the head's track and answers at once, taking no ID byte over DMA. Each
  // sector is a write request here, its bytes the filler (media_din) at one per cycle.
  reg        x_fmt;
  reg        x_disc;
  reg        x_pad;
  reg        x_tc;
  reg [1:0]  x_us;
  reg        x_hd;
  reg [7:0]  x_c, x_h, x_r, x_n, x_eot;
  reg        x_mt;
  reg        x_mf;             // the data command's MF bit, carried to the medium (media_mf)
  reg [7:0]  x_idx;
  reg [15:0] x_left;          // bytes still owed in THIS sector
  reg        x_req_sent;      // this request's `req` pulse has gone out
  reg        nd_idx;          // X_NDW: the first index pulse of the search has passed

  // THE SPINDLE'S INDEX HOLE, a free-running revolution of the selected drive: 360 rpm on the
  // 1 MB interface (1.2 MB media) unless the unit's 0x04BE rpm bit selects 300 rpm (1.44 MB),
  // and 300 rpm on the 640 KB interface (NP2kai io/fdc.c fdc_o4be `fdc.rpm[...]`; the 3-mode
  // drive's two spindle speeds). The period is real time (SYS_CLOCK_HZ cycles per second), so
  // a clk_sys change cannot move it. Both drives are taken as one spindle phase: only one unit
  // is selected at a time and the search starts at an arbitrary angle either way.
  // idx_pulse is a one-cycle strobe with one consumer, the X_NDW arm.
  localparam integer REV_360 = SYS_CLOCK_HZ / 6;     // 1/6 s per revolution
  localparam integer REV_300 = SYS_CLOCK_HZ / 5;     // 1/5 s per revolution
  localparam integer REV_W   = $clog2(REV_300);
  reg  [REV_W-1:0] spin;
  wire             idx_pulse = (spin == {REV_W{1'b0}});
  wire             spin_360  = strap_2hd && !rpm[x_us];
  always @(posedge clk) begin
    if (reset)          spin <= REV_W'(REV_360 - 1);
    else if (idx_pulse) spin <= spin_360 ? REV_W'(REV_360 - 1) : REV_W'(REV_300 - 1);
    else                spin <= spin - 1'b1;
  end

  // The machine's FDD strap: two drives, units 0 and 1. The BIOS's probe
  // recalibrates all FOUR units (BANK7 0xFF6CC -> 0xFF22B, `inc bl; cmp bl,4`) and
  // then marks a unit present only when its SENSE INTERRUPT STATUS byte has neither
  // IC0 (0x40) nor IC1 (0x80) set (BANK7 0xFF716, `test byte [0x564+unit*8],0xC0`).
  // Units 2/3 are not there at all: their SENSE DRIVE STATUS answers the fault bit
  // 0x80 instead of TS/T0 (NP2kai fdc.c:281-283, qemu pc98-fdc.c:2234).
  localparam [1:0] FDD_DRIVES = 2'd2;
  function automatic bit drive_equipped(input [1:0] u);
    drive_equipped = (u < FDD_DRIVES);
  endfunction

  // AN EQUIPPED DRIVE WITH NO DISKETTE IS PRESENT (NP2kai).
  // NP2kai's FDC_Recalibrate gives every equipped-but-empty drive SE|NR = 0x28|u
  // (io/fdc.c:613-621), which the BIOS's present test reads as PRESENT because it looks only
  // at the IC bits (`BANK7 0xFF716`: `test byte [0x564+unit*8],0xC0` -> `or [0x55C],al`), so
  // both drives mark and [0x55C] = 0x03. The Xe10 captures read 0x01
  // (docs/probes/itf-paired-7287bed6/*/D2{COLD,WARM}.TXT), but drive 1 was
  // UNPOWERED when they were taken, so they measure a dead drive, not the machine; an earlier
  // model copied them (unit 1 answering the IC0 class when empty). A capture with both drives
  // powered is todo item 59.

  // The command byte's parameter count, from NP2kai's FDCCMD_TABLE (fdc.c:30). THE
  // OPCODE IS THE LOW FIVE BITS: the uPD765 carries MF (bit 6) and the other flags
  // ABOVE the opcode, and NP2kai dispatches on `fdc.cmd & 0x1f`, so 0x06 and 0x46
  // are READ DATA and 0x0A and 0x4A READ ID. Decoding the whole byte answered the MF
  // variants "invalid", which raises NO interrupt, and the BIOS's FDC interrupt wait
  // (BANK7 0x7D0A, polling DS:0x55E) then never returns -- the Rusty freeze.
  function automatic [3:0] cmd_params(input [4:0] c);
    begin
      case (c)
        5'h02: cmd_params = 4'd8;   // NP2kai's FDC_Ope[0x02] is FDC_ReadData (fdc.c:805)
        5'h03: cmd_params = 4'd2;   // SPECIFY
        5'h04: cmd_params = 4'd1;   // SENSE DRIVE STATUS
        5'h05: cmd_params = 4'd8;   // WRITE DATA (NP2kai FDC_WriteData)
        5'h06: cmd_params = 4'd8;   // READ DATA (0x06 or 0x46, MF=1)
        5'h07: cmd_params = 4'd1;   // RECALIBRATE (drive byte)
        5'h09: cmd_params = 4'd8;   // WRITE DELETED DATA (same handler)
        5'h0A: cmd_params = 4'd1;   // READ ID (0x0A or 0x4A, MF=1)
        5'h0C: cmd_params = 4'd8;   // READ DELETED DATA (same handler)
        5'h0D: cmd_params = 4'd5;   // FORMAT / WRITE ID (NP2kai FDC_WriteID)
        5'h0F: cmd_params = 4'd2;   // SEEK
        default: cmd_params = 4'd0;
      endcase
    end
  endfunction

  // The read-class opcodes: NP2kai's FDC_Ope[0x02]/[0x06]/[0x0C] all reach
  // FDC_ReadData (fdc.c:802-843).
  function automatic bit cmd_is_read(input [4:0] c);
    cmd_is_read = (c == 5'h02) || (c == 5'h06) || (c == 5'h0C);
  endfunction
  function automatic bit cmd_is_write(input [4:0] c);
    cmd_is_write = (c == 5'h05) || (c == 5'h09);
  endfunction

  // The ST0 a command leaves behind when its drive cannot serve it (the deferred path).
  // The classes live below, next to the drive state they depend on: `deferred_st0`.

  // PARAMETER 0 IN THE CYCLE IT LANDS. cmds[] is registered, so at a
  // ONE-PARAMETER command's last (and only) byte they still hold the PREVIOUS command's
  // values; NP2kai's get_hdus reads fdc.cmds[0] after the byte is stored. Reading the
  // register here instead sent RECALIBRATE's completion to unit 0 whatever the guest
  // asked for (tb_pc9821_fdc_conform's recal_unequipped_st0 / busy_msr_recal_u2).
  wire [2:0] cur_p0 = (p_idx == 3'd0) ? din[2:0] : cmds[0][2:0];
  // PARAMETER 1 IN THE CYCLE IT LANDS - the same trap `cur_p0` documents: cmds[] is
  // registered, and SEEK's parameter 1 (the NCN) is its LAST byte, so cmds[1] still holds
  // the PREVIOUS command's value at the moment SEEK executes. Read `din` on that cycle.
  wire [7:0] cur_p1 = (p_idx == 3'd1) ? din : cmds[1];

  // ---- the drive state, in ONE place, used by every answer (the plan's W1) ------------
  // NP2kai's two facts about a drive are `fdc.equip` (a configured mask, io/fdc.c:1240)
  // and `fdd_diskready` (== an image is mounted, diskimage/fddfile.c:639-645), plus the
  // guest's forced-ready strap (`fdc.ctrlreg & 0x40`, io/fdc.c:367). Every command's
  // answer below is a function of these.
  wire [3:0] drv_equipped = (4'd1 << FDD_DRIVES) - 4'd1;  // units 0..FDD_DRIVES-1
  // ---- THE READY CHANGE, NP2kai's diskdrv.c, replicated ---------------------------------
  // NP2kai's media change is diskdrv_setfddex (fdd/diskdrv.c:256-284), called for an insert
  // (with a file) and an eject (fname NULL) alike, on an equipped drive:
  //   * fdd_eject(drv), then `fdc.stat[drv] = FDCRLT_AI | FDCRLT_NR | drv; fdc.us = drv;
  //     fdc_interrupt();` - UNCONDITIONALLY, so every mount event (even an eject of an empty
  //     drive) leaves ST0 = 0xC8|u (AI = 0xC0, NR = 0x08, io/fdc.h) for SENSE INTERRUPT STATUS
  //     and raises the interrupt;
  //   * an insert then waits DISK_DELAY = 20 calls of diskdrv_callback (:15, :290-306) - 20
  //     guest frames - during which fdd_diskready() is FALSE (the image was ejected and
  //     fdd_set has not run; diskimage/fddfile.c:639-645 is `fname[0] != 0`), so READY/ST3 RDY
  //     read not-ready and a data command answers FDC_DriveCheck's IC0|NR;
  //   * at the end of the delay diskdrv_readyfddex (:225-249) runs fdd_set and, ONLY IF
  //     `(!(fdc.chgreg & 4)) || (fdc.ctrlreg & 0x08)` - the 0xBE register's bit 2 clear, or the
  //     DOR's motor bit set - raises `fdc.stat[drv] = FDCRLT_AI | drv` (0xC0|u) and the interrupt.
  //     The eject leg above has no such gate.
  // Here `armed[u]` is the delay's "inserted but not yet ready" state: set by the change, it
  // masks the drive's media from every answer below, and it clears - raising the ready AI under
  // NP2kai's gate - once the delay has run out AND the medium has parsed (pc9821_fdd_media's
  // `present`; a parse slower than the delay simply extends it, and an eject or an unparsable
  // image never clears it, which is harmless: the drive has no media either way and the next
  // change re-arms it).
  localparam [4:0] DISK_DELAY = 5'd20;   // NP2kai fdd/diskdrv.c:15 "#define DISK_DELAY 20"
  reg  [1:0] chg_q;                      // media_chg as last seen (no reset: it tracks in reset)
  initial chg_q = 2'b00;
  reg  [1:0] armed;
  reg  [4:0] ins_dly [0:1];
  wire [1:0] chg_ev   = media_chg[1:0] ^ chg_q;
  wire       ai_gate  = !chgreg[2] || ctrlreg[3];
  // The gated ready is DEFERRED to the motor bit's rise, not lost: NP2kai fdc_o94 does
  // `if (fdc.chgreg & 4) { if ((fdc.ctrlreg ^ dat) & 0x08) { if (dat & 0x08) { for (i...)
  // if (fdd_diskready(i)) { fdc.int_stat[i] = FDCRLT_AI | i; ...` (io/fdc.c) - every drive
  // that is ready then reports AI|drv. tb_pc9821_fdc_ready_change R3b.
  wire       dor_ai   = cs && wr && (addr == A_DOR) && chgreg[2] && !ctrlreg[3] && din[3];
  wire [1:0] ai_ready;
  genvar gu;
  generate
    for (gu = 0; gu < 2; gu = gu + 1) begin : g_ai
      assign ai_ready[gu] = armed[gu] && (ins_dly[gu] == 5'd0) && media_present[gu];
    end
  endgenerate
  wire [3:0] drv_media    = media_present & ~{2'b00, armed};
  wire [3:0] drv_forced   = {4{ctrlreg[6]}};
  wire [3:0] drv_ready    = drv_equipped & (drv_media | drv_forced);
  wire [1:0] cur_u        = cur_p0[1:0];
  wire       cur_hd       = cur_p0[2];

  // RECALIBRATE (0x07) / SEEK (0x0F) that cannot be served, NP2kai FDC_Recalibrate
  // (io/fdc.c:592-628):
  //   not equipped                     -> us|SE|IC0|NR = 0x68|u
  //   ...with the guest's forced ready  -> us|SE|IC0|EC = 0x70|u (:604-611)
  //   equipped, no media               -> us|SE|NR     = 0x28|u (:613-621)
  // A unit with media never reaches this (it takes the ready path, SE|us = 0x20|u).
  wire [7:0] rec_st0 =
        drv_media[cur_u]                           ? (8'h20 | {6'd0, cur_u}) :
        !drv_equipped[cur_u]                       ? ((ctrlreg[6] ? 8'h70 : 8'h68) |
                                                      {6'd0, cur_u}) :
                                                     (8'h28 | {6'd0, cur_u});

  // The data commands' class when the drive cannot serve them: NP2kai's FDC_DriveCheck
  // (:175-186) answers us|hd<<2|IC0|NR = 0x48|hd<<2|u for a drive that is not ready (a
  // WRITE on a drive that IS ready but protected answers 0x40|hd<<2|u with ST1 NW = 0x02
  // instead, and that arm is in the media path). READ ID's own failure is
  // us|hd<<2|IC0 = 0x40|hd<<2|u with ST1 ND = 0x04 (FDC_ReadID,:494-560); the STATUS byte
  // is the ST0 half of error7, so ND is not part of it.
  wire [7:0] data_st0 = (cmd == 5'h0A) ? (8'h40 | {5'd0, cur_hd, cur_u})
                                       : (8'h48 | {5'd0, cur_hd, cur_u});
  // SEEK (0x0F) has ONE not-ready class, whatever the equip and forced-ready state:
  // NP2kai FDC_Seek tests only `if (!fdd_diskready(fdc.us))` and then does
  // `fdc.int_stat[fdc.us] |= FDCRLT_IC0 | FDCRLT_NR;` = us|SE|IC0|NR = 0x68|u. The
  // equip and forced-ready arms above are FDC_Recalibrate's alone. tb_pc9821_fdc_conform.
  wire [7:0] seek_st0 = 8'h68 | {6'd0, cur_u};
  wire [7:0] deferred_st0 = (cmd == 5'h07) ? rec_st0 :
                            (cmd == 5'h0F) ? seek_st0 : data_st0;

  // 128 << N, clamped at N >= 8 exactly as NP2kai does (`if (fdc.N < 8) ... else 128<<8`,
  // fdd_d88.c:427-432).
  wire [15:0] x_secbytes = (x_n[7:4] != 4'd0) ? 16'd32768 : (16'd128 << x_n[3:0]);

  // --------------------------------------------------------------- the media request
  // A read-class command names its sector; READ ID names the header ordinal. The track
  // is the drive's track register, which NP2kai's fdd_readid_d88 uses directly
  // (`trkseek(fdd, (fdc.treg[us] << 1) + fdc.hd)`, :494-500) and which READ DATA has
  // just set to the command's C (`fdc.treg[us] = fdc.C`, FDC_ReadData :468-470).
  // ONE cycle, asserted only while the media says it can take it, so a request is never
  // dropped and never repeated: the media's answer levels are sticky until the next
  // request, and a second `req` would clear a level the controller is still reading.
  assign media_req     = (x_st == X_REQ) && !x_req_sent && media_ready;
  // A FORMAT sector request is flagged as `req_hdr` AND `media_wr` together (a write never sets
  // req_hdr otherwise), so the medium can refuse it where it cannot format (a D88).
  assign media_req_hdr = x_isid || x_fmt;
  assign media_unit    = x_us;
  assign media_c       = x_isid ? treg[x_us] : x_c;
  assign media_h       = x_isid ? {7'd0, x_hd} : x_h;
  assign media_tc      = treg[x_us];
  assign media_hd      = x_hd;
  assign media_mf      = x_mf;
  assign media_2hd     = chgreg[1];
  assign media_rpm     = rpm[x_us];
  assign media_r       = x_r;
  assign media_n       = x_n;
  // A WRITE request carries the command's EOT in the ordinal field (a write has no header
  // ordinal): NP2kai's fdd_write_xdf fails a raw write whose EOT is past the track's sector count
  // (`if (fdc.eot > fdd->inf.xdf.sectors)` -> 0xc0, diskimage/fd/fdd_xdf.c:399-404).
  assign media_idx     = x_wr ? x_eot : x_idx;

  // --------------------------------------------------------------- the DMA handshake
  // The engine's S_DEV cycle is the byte's cycle: dev_stb and the channel's dack are
  // high together and the engine latches dev_din at the end of it, so the byte must be
  // present combinationally while they are. `rdy` is the media's own "the byte at the
  // pointer is available", so a stalled block fetch drops DRQ and the engine simply
  // waits - the transfer pauses, it never loses a byte.
  wire xfer_now  = (x_st == X_XFER) && !x_wr && media_rdy;
  wire xfer_dma  = (st == ST_IDLE) && dma_dack && dma_stb;
  wire xfer_pio  = cs && rd && (addr == A_DATA);
  wire xfer_go   = xfer_now && (xfer_dma || xfer_pio);
  // THE WRITE DIRECTION: the same one-byte-per-strobe handshake with the byte flowing the other
  // way (NP2kai fdc_datawrite in FDCEVENT_BUFRECV, io/fdc.c:945-956: one byte per call into
  // fdc.buf). `wx_ok` is "this sector can take a byte now": the medium's `rdy`, or always while
  // the bytes are being dropped (x_disc). A PAD byte is not the guest's: after a mid-sector
  // terminal count the controller completes the sector by writing the medium's own byte back
  // (media_din = media_dout), one per cycle, so the medium leaves its data state and writes the
  // block back. NP2kai writes its whole fdc.buf there, whose tail is whatever the buffer held
  // before (fdc_datawrite's `|| (fdc.tc)` arm, :952); keeping the medium's bytes is the one
  // value this model can name, and it is recorded as a divergence (no guest programs a count
  // that ends inside a sector).
  wire wx_ok     = x_disc || media_rdy;
  wire wx_dma    = xfer_dma && dma_we;
  wire wx_pio    = cs && wr && (addr == A_DATA);
  wire wx_go     = (x_st == X_XFER) && x_wr && wx_ok && (x_pad || wx_dma || wx_pio);
  wire wx_tcnow  = !x_pad && wx_dma && dma_tc;   // the guest's final byte, with its TC
  assign media_wr  = x_wr;
  assign media_din = x_fmt ? cmds[4] : x_pad ? media_dout : (wx_dma ? dma_din : din);
  assign media_adv = xfer_go || (wx_go && !x_disc);
  assign dma_drq   = xfer_now || ((x_st == X_XFER) && x_wr && !x_pad && wx_ok);
  assign dma_dout  = xfer_now ? media_dout : 8'hFF;
  // The DOR write that resets the controller (fdc_o94's condition, the A_DOR arm below).
  wire dor_reset = cs && wr && (addr == A_DOR) &&
                   (|((ctrlreg ^ din) & 8'h10) || (|((ctrlreg ^ din) & 8'h80) && din[7]));
  assign media_abort = (dor_reset && (x_st != X_IDLE)) ||
                       (xfer_go && dma_tc && xfer_dma && (x_left != 16'd1));

  integer k;

  // The FDD-mode switch as POST reads it: sampled on reset only (see dip_fixed).
  /* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
  reg dip_fixed_q = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) begin
    if (reset) dip_fixed_q <= dip_fixed;
  end

  always @(posedge clk) begin
    if (reset) begin
      st <= ST_IDLE;
      cmd <= 5'd0;
      cmd_mt <= 1'b0;
      param_left <= 4'd0;
      p_idx <= 3'd0;
      drv <= 2'd0;
      delay <= 16'd0;
      exec_st0 <= 8'h00;
      pend <= 4'd0;
      busy <= 4'd0;
      nd <= 1'b0;
      res0 <= 8'h80;
      res1 <= 8'h00;
      res_len <= 3'd0;
      res_idx <= 3'd0;
      res_pop <= 1'b0;
      res_rel <= 1'b0;
      res_irq <= 1'b0;
      res_drv <= 2'd0;
      reg144_sel <= 2'd0;
      ctrlreg <= 8'h00;
      rpm <= 4'h0;
      chgreg <= 8'h03;   // NP2kai fdc_reset: fdc.chgreg = 3 (io/fdc.c:1159)
      crcn <= 8'h00;
      for (k = 0; k < 4; k = k + 1) treg[k] <= 8'h00;
      for (k = 0; k < 4; k = k + 1) lasttreg[k] <= 8'h00;
      x_st <= X_IDLE;
      x_isid <= 1'b0;
      x_us <= 2'd0;
      x_hd <= 1'b0;
      x_c <= 8'h00;
      x_h <= 8'h00;
      x_r <= 8'h00;
      x_n <= 8'h00;
      x_eot <= 8'h00;
      x_mt <= 1'b0;
      x_idx <= 8'h00;
      x_left <= 16'd0;
      x_req_sent <= 1'b0;
      x_wr <= 1'b0;
      x_fmt <= 1'b0;
      x_disc <= 1'b0;
      x_pad <= 1'b0;
      x_tc <= 1'b0;
      for (k = 0; k < 4; k = k + 1) pend_st0[k] <= 8'h00;
      for (k = 0; k < 8; k = k + 1) cmds[k] <= 8'h00;
      armed <= 2'b00;
      ins_dly[0] <= 5'd0;
      ins_dly[1] <= 5'd0;
    end else begin
      // A command that raises an interrupt queues its completion status. The
      // BIOS waits for the interrupt BEFORE reading any result (its driver calls
      // the 0x7D0E wait and only then touches the DMA), so every interrupt
      // command completes straight to the interrupt and none of them leaves a
      // result phase standing: a result phase would leave MSR at 0xD0 and the
      // ISR's own SENSE INTERRUPT STATUS write would never take it.
      if ((st == ST_EXEC) && (delay == 16'd0)) begin
        pend[drv] <= 1'b1;
        pend_st0[drv] <= exec_st0;
        st <= ST_IDLE;
      end else if (st == ST_EXEC) begin
        delay <= delay - 16'd1;
      end

      // Result-byte fetch (0x92 read while DIO is set): advance, and when the
      // result is drained either return to the command phase or pop the pending
      // interrupt status, which is what deasserts the level IRQ.
      if (cs && (st == ST_RESULT) && rd && (addr == A_DATA)) begin
        res_idx <= res_idx + 3'd1;
        if (res_idx + 3'd1 >= res_len) begin
          st <= ST_IDLE;
          if (res_pop) pend[res_drv] <= 1'b0;
          if (res_rel) busy[res_drv] <= 1'b0;
          if (res_irq) begin
            res_irq <= 1'b0;
            res_rel <= 1'b0;
          end
        end
      end

      // Command / parameter byte (0x92 write).
      if (cs && wr && (addr == A_DATA) && (st == ST_IDLE) && (x_st == X_IDLE)) begin
        cmd <= din[4:0];             // opcode only; MF and the flags sit above it
        cmd_mt <= din[7];
        cmd_mf <= din[6];
        p_idx <= 3'd0;
        if (din[4:0] == 5'h08) begin
          // SENSE INTERRUPT STATUS: report the oldest pending completion, else
          // the empty ST0 = 0x80. The empty result is ONE byte deliberately: the
          // BIOS ISR exits on ST0 = 0x80 after reading only ST0, and a stranded
          // PCN byte would leave the controller in the result phase with the next
          // command write's poll unable to reach (MSR & 0xC0) == 0x80.
          if (|pend) begin
            res_drv <= pend_drv;
            res0 <= pend_st0[pend_drv];
            res1 <= treg[pend_drv];  // PCN = the present cylinder (NP2kai fdc.treg[us])
            res_len <= 3'd2;
            res_pop <= 1'b1;
            res_rel <= 1'b1;
            res_irq <= 1'b0;
          end else begin
            res0 <= 8'h80;
            res_len <= 3'd1;
            res_pop <= 1'b0;
            res_rel <= 1'b0;
            res_irq <= 1'b0;
          end
          res_idx <= 3'd0;
          st <= ST_RESULT;
        end else if (cmd_params(din[4:0]) != 4'd0) begin
          param_left <= cmd_params(din[4:0]);
          st <= ST_PARAM;
        end else begin
          // Invalid/unsupported command: the standard 0x80 status, one byte.
          res0 <= 8'h80;
          res_len <= 3'd1;
          res_pop <= 1'b0;
          res_rel <= 1'b0;
          res_irq <= 1'b0;
          res_idx <= 3'd0;
          st <= ST_RESULT;
        end
      end else if (cs && wr && (addr == A_DATA) && (st == ST_PARAM)) begin
        cmds[p_idx] <= din;
        if (param_left == 4'd1) begin
          // Last parameter. SPECIFY finishes quietly; SENSE DRIVE STATUS returns
          // ST3 immediately; a read-class command with media takes the reference
          // data path; everything else completes as today.
          if (cmd == 5'h03) begin
            nd <= din[0];   // NP2kai fdc.c:265: fdc.nd = fdc.cmds[1] & 1
            st <= ST_IDLE;
          end else if (cmd == 5'h04) begin
            // ST3 for an equipped drive: TS (0x08) and T0 (0x10) when treg == 0, RDY
            // (0x20) when the drive is ready, WP (0x40) on a protected disk; a unit that
            // is not there answers the fault bit 0x80 instead (NP2kai FDC_SenseDeviceStatus,
            // fdc.c:354-384; qemu pc98-fdc.c:2234). NP2kai's RDY is
            // `fdd_diskready(us) || (fdc.ctrlreg & 0x40)` (:367) and its WP is the image's own
            // protect flag (:370-372) - on this machine the D88 header's bit OR the mount's
            // read-only flag, i.e. `writeprotect`, NOT "media is present".
            res0 <= drive_equipped(din[1:0]) ? (8'h08 | {5'd0, din[2:0]} |
                                                  (treg[din[1:0]] == 8'h00 ? 8'h10 : 8'h00) |
                                                  (drv_ready[din[1:0]] ? 8'h20 : 8'h00) |
                                                  (writeprotect[din[1:0]] ? 8'h40 : 8'h00))
                                               : (8'h80 | {5'd0, din[2:0]});
            res_len <= 3'd1;
            res_pop <= 1'b0;
            res_rel <= 1'b1;         // the ST3 result claims and releases the drive
            res_irq <= 1'b0;
            res_drv <= din[1:0];
            busy[din[1:0]] <= 1'b1;  // (fdc.c:300-302)
            res_idx <= 3'd0;
            st <= ST_RESULT;
          end else if (drive_equipped(cur_u) &&
                       ((cmd == 5'h0F) ? drv_media[cur_u]
                                       : ((cmd == 5'h07) && (drv_media[cur_u] || ctrlreg[6])))) begin
            // SEEK (0x0F) / RECALIBRATE (0x07) ON A READY DRIVE - NOT accepted-but-ignored.
            // NP2kai's FDC_Seek (io/fdc.c:773-779) and FDC_Recalibrate (:527-563) move the
            // TRACK REGISTER on a ready drive (SEEK: treg := NCN = cmds[1]; RECALIBRATE:
            // treg := 0), reset R (this model's crcn ordinal), claim the drive and complete
            // with int_stat = us | SE = 0x20|us - SE with NO IC0 and NO NR. Without this the
            // track register was only ever written by READ DATA, so a driver that positions
            // the head with SEEK/RECALIBRATE reads the wrong track. The unit is parameter 0 (get_hdus),
            // and SEEK's parameter 1 is the NCN.
            //
            // READY here is media mounted OR, for RECALIBRATE ONLY, the guest's forced-ready
            // strap: NP2kai's FDC_Recalibrate reaches this success path for an equipped drive
            // with no media when `ctrlreg & 0x40` is set, setting treg := ncn with NO NR
            // (:613-621). FDC_Seek has no such arm: a SEEK needs media (fdd_diskready). An UNEQUIPPED unit stays in
            // the IC0 class even then (it sets 0x70|us, SE|IC0|EC, :604-611), which is why
            // the equip test is part of this condition and not only of the class below.
            crcn <= 8'h00;
            x_st <= X_IDLE;
            drv  <= cur_u;
            exec_st0 <= 8'h20 | {6'd0, cur_u};
            treg[cur_u] <= (cmd == 5'h0F) ? cur_p1 : 8'h00;
            if (cmd == 5'h0F) lasttreg[cur_u] <= cur_p1;   // FDC_Seek :850
            busy[cur_u] <= 1'b1;
            delay <= RECAL_CYCLES;
            st <= ST_EXEC;
          end else if (drv_media[cur_u] && (cmd_is_read(cmd) || cmd_is_write(cmd) ||
                                            (cmd == 5'h0D) || (cmd == 5'h0A))) begin
            // THE REFERENCE DATA PATH (the drive has media). The unit and head come
            // from parameter 0, C/H/R/N from parameters 1..4 (NP2kai get_hdus/get_chrn,
            // fdc.c:201-215), EOT from parameter 5. A DATA command REQUIRES MEDIA: a
            // ready-but-empty drive has no sector to fetch, and the reference's own
            // FDC_DriveCheck refuses it with IC0|NR (:175-186), which is the class the
            // deferred path below answers.
            x_us   <= cur_u;
            x_hd   <= cur_hd;
            x_c    <= cmds[1];
            x_h    <= cmds[2];
            x_r    <= cmds[3];
            x_n    <= cmds[4];
            x_eot  <= cmds[5];
            x_mt   <= cmd_mt;
            x_mf   <= cmd_mf;
            x_isid <= 1'b0;
            x_idx  <= crcn;
            x_wr   <= 1'b0;
            x_fmt  <= 1'b0;
            x_disc <= 1'b0;
            x_pad  <= 1'b0;
            x_tc   <= 1'b0;
            st     <= ST_IDLE;
            if (cmd_is_write(cmd) && !writeprotect[cur_p0[1:0]]) begin
              // WRITE DATA / WRITE DELETED DATA on a writable medium (Stage B): NP2kai's
              // FDC_WriteData CMDRECV (io/fdc.c:427-455) - get_hdus/get_chrn/get_eotgsldtl,
              // FDC_DriveCheck(TRUE) passes, and the controller waits for the first sector's
              // 128 << N bytes. treg := C as READ DATA does (the read arm's note on
              // fdc_lasttreg applies unchanged). The sector is located when it is requested
              // (X_REQ); see x_disc for a sector that is not there.
              if (drive_equipped(cur_p0[1:0]) && (lasttreg[cur_p0[1:0]] != treg[cur_p0[1:0]]))
                treg[cur_p0[1:0]] <= cmds[1];
              x_wr <= 1'b1;
              x_st <= X_REQ;
              x_req_sent <= 1'b0;
              busy[cur_p0[1:0]] <= 1'b1;
            end else if ((cmd == 5'h0D) && !writeprotect[cur_p0[1:0]]) begin
              // FORMAT (WRITE ID) on a writable medium. FDC_WriteID (io/fdc.c:723-765):
              // get_hdus, N = cmds[1], SC = cmds[2], D = cmds[4], FDC_DriveCheck(TRUE), then
              // fdd_formatinit(). For a raw image that is fdd_formatinit_xdf: SC sectors of
              // 128 << N bytes of D written at ((treg << 1) + hd) * SC * (128 << N), and - since
              // fdd_isformating() is FALSE for it - `fdc.crcn = 1; fdcsend_success7();` with no ID
              // byte taken. Here the sectors are R = 1..SC at the track register's cylinder, written
              // through the write path with the filler as their bytes (no DMA request). A D88 has
              // NP2kai's track-rebuilding format (fdd_formating_d88), which this model does not
              // do: the medium refuses the request and the controller answers IC0|NW (X_REQ).
              x_c   <= treg[cur_p0[1:0]];
              x_h   <= {7'd0, cur_p0[2]};
              x_r   <= 8'h01;
              x_n   <= cmds[1];
              x_eot <= cmds[2];
              x_mt  <= 1'b0;
              x_wr  <= 1'b1;
              x_fmt <= 1'b1;
              x_pad <= 1'b1;
              crcn  <= 8'h01;
              x_st  <= X_REQ;
              x_req_sent <= 1'b0;
              busy[cur_p0[1:0]] <= 1'b1;
            end else if (cmd_is_write(cmd) || (cmd == 5'h0D)) begin
              // A PROTECTED MEDIUM: FDC_DriveCheck(TRUE) answers ST0 IC0|NW|hd<<2|us with ST1 NW
              // (io/fdc.c:175-193, fdcsend_error7 :98-119) before any byte moves. FORMAT (0x0D)
              // still answers this for every medium: the track-format path is not modelled (the
              // fdd-write report prices it), and success would claim a format that never
              // reached the image.
              x_st <= X_IDLE;
              res_drv <= cur_p0[1:0];
              busy[cur_p0[1:0]] <= 1'b1;
              res0 <= 8'h40 | {5'd0, cur_p0[2], cur_p0[1:0]};   // IC0 | hd<<2 | us
              res1 <= 8'h02;                                      // ST1 NW
              res_len <= 3'd7;
              res_pop <= 1'b0;
              res_rel <= 1'b1;
              res_irq <= 1'b1;
              res_idx <= 3'd0;
              st <= ST_RESULT;
            end else if (cmd == 5'h0A) begin
              // READ ID: one sector header, the crcn-th on the track (fdd_readid_d88,
              // :494-552). The track register is the seek's, not the header's.
              x_isid <= 1'b1;
              x_st <= X_REQ;
              x_req_sent <= 1'b0;
              busy[cur_p0[1:0]] <= 1'b1;
            end else begin
              // READ DATA: treg := C unless a SEEK set it (FDC_ReadData, the lasttreg rule
              // above), then the first sector.
              if (drive_equipped(cur_p0[1:0]) && (lasttreg[cur_p0[1:0]] != treg[cur_p0[1:0]]))
                treg[cur_p0[1:0]] <= cmds[1];
              x_st <= X_REQ;
              x_req_sent <= 1'b0;
              busy[cur_p0[1:0]] <= 1'b1;
            end
          end else begin
            // The unit is PARAMETER 0 (NP2kai get_hdus, fdc.c:201), not the last
            // byte: SEEK's parameter 1 is the NCN and FORMAT's is the filler D.
            drv <= cur_p0[1:0];
            // The claim point: NP2kai sets (1 << us) where the command runs
            // (fdc.c:562-563 RECALIBRATE, 773-774 SEEK) and where the no-media
            // path sends its completion (fdc.c:111-113/148-150). The ST0 is the
            // per-state class (deferred_st0), latched now so the shared ST_EXEC
            // completion carries it.
            exec_st0 <= deferred_st0;
            busy[cur_p0[1:0]] <= 1'b1;
            delay <= RECAL_CYCLES;
            st <= ST_EXEC;
          end
        end else begin
          param_left <= param_left - 4'd1;
          p_idx <= p_idx + 3'd1;
        end
      end

      // ================================================================= the media path
      // A MEDIUM EJECTED OR SWAPPED UNDER A DATA COMMAND IS UNDEFINED: no arm
      // of its own here. pc9821_fdd_media aborts its request on the drive's mount edge with
      // `err`, which the X_REQ/X_XFER error arms below already turn into the missing-sector
      // error7 and its interrupt, so the controller never waits on a medium that is gone - and
      // what that result says is not a contract.
      case (x_st)
        X_IDLE: ;

        // The request is issued in the first cycle here (the media is back in its own
        // ST_READY by then), then its answer is waited on.
        X_REQ: begin
          if (!x_req_sent) begin
            if (media_ready) x_req_sent <= 1'b1;
          end else if (media_err && x_fmt) begin
            // The medium cannot format (a D88, or a raw format whose N/SC are not the image's
            // geometry): the IC0|NW answer every FORMAT got before Stage B, still honest - the
            // track was not formatted. NP2kai would rebuild a D88 track (fdd_formating_d88) and
            // write a mismatched raw geometry at its own offsets; both are recorded gaps.
            x_st <= X_IDLE;
            x_wr <= 1'b0;
            x_fmt <= 1'b0;
            res_drv <= x_us;
            res0 <= 8'h40 | {5'd0, x_hd, x_us};
            res1 <= 8'h02;                       // ST1 NW
            res_len <= 3'd7;
            res_pop <= 1'b0;
            res_rel <= 1'b1;
            res_irq <= 1'b1;
            res_idx <= 3'd0;
            st <= ST_RESULT;
          end else if (media_err && x_wr) begin
            // A WRITE SECTOR THE MEDIUM CANNOT LOCATE still takes its bytes first: NP2kai's
            // writesector() - and with it fdd_write()'s lookup - runs only once the sector's
            // 128 << N bytes are in (io/fdc.c:394-405, :945-956), so the IC0|ND answer comes
            // after the transfer (X_WEND).
            x_disc <= 1'b1;
            x_st   <= X_XFER;
            x_left <= x_secbytes;
          end else if (media_err) begin
            // The sector (or, for READ ID, any header) is not on the track: the controller
            // keeps searching the IDs until it has seen the index hole TWICE, and only then
            // ends the command (X_NDW below). The answer is readsector's missing-sector class.
            x_st <= X_NDW;
            nd_idx <= 1'b0;
            if (x_isid) crcn <= 8'h00;             // fdd_d88.c:545-546
          end else if (x_isid ? media_hdrv : media_rdy) begin
            if (x_isid) begin
              // success7 = {hd<<2|us, 0, 0, C, H, R, N} (fdcsend_success7 :120-158),
              // with C = the track register and H = the head (fdd_readid_d88 :522-526).
              // crcn advances and wraps at the track's own sector count (:513-518).
              x_st <= X_IDLE;
              crcn <= ((crcn + 8'd1) >= media_hs) ? 8'h00 : (crcn + 8'd1);
              res_drv <= x_us;
              res0 <= {5'd0, x_hd, x_us};
              res1 <= 8'h00;
              x_c <= treg[x_us];      // C = the track register, H = the head, R/N = the header's
              x_h <= {7'd0, x_hd};
              x_r <= media_hr;
              x_n <= media_hn;
              res_len <= 3'd7;
              res_pop <= 1'b0;
              res_rel <= 1'b1;
              res_irq <= 1'b1;
              res_idx <= 3'd0;
              st <= ST_RESULT;
            end else begin
              x_st <= X_XFER;
              x_left <= x_secbytes;
            end
          end
        end

        // One byte per (DMA strobe or PIO read), exactly fdc_dataread's one call per
        // byte (:897-952).
        // A BLOCK THAT FAILED MID-SECTOR (media_err with the medium still present: the shared
        // adapter rejected a fetch) ends the transfer with the same missing-sector error7 the
        // X_REQ arm answers, instead of waiting on a media_rdy the medium will never raise.
        X_XFER: if (media_err && !x_disc) begin
          x_st <= X_IDLE;
          res_drv <= x_us;
          res0 <= 8'h40 | {5'd0, x_hd, x_us};   // IC0 | hd<<2 | us
          res1 <= 8'h04;                        // ST1 ND
          res_len <= 3'd7;
          res_pop <= 1'b0;
          res_rel <= 1'b1;
          res_irq <= 1'b1;
          res_idx <= 3'd0;
          st <= ST_RESULT;
        end else if (x_wr) begin
          // ONE WRITE BYTE per strobe (or PIO write, or pad byte). The sector ends at its
          // 128 << N-th byte; a terminal count before that turns the rest into pad bytes
          // (wx_go's note) so the medium still completes and writes the sector back.
          if (wx_go) begin
            if (wx_tcnow) x_tc <= 1'b1;
            if (x_left == 16'd1) x_st <= X_WEND;
            else begin
              x_left <= x_left - 16'd1;
              if (wx_tcnow) x_pad <= 1'b1;
            end
          end
        end else if (xfer_go) begin
          if (dma_tc && xfer_dma) begin
            // The DMA engine's terminal count ends the command right here, and
            // NP2kai forces R = 1 into the result's R byte (:925-932).
            x_st <= X_IDLE;
            res_drv <= x_us;
            res0 <= {5'd0, x_hd, x_us};
            res1 <= 8'h00;
            x_r <= 8'h01;
            res_len <= 3'd7;
            res_pop <= 1'b0;
            res_rel <= 1'b1;
            res_irq <= 1'b1;
            res_idx <= 3'd0;
            st <= ST_RESULT;
          end else if (x_left == 16'd1) begin
            // The sector is complete: FDC_ReadData's FDCEVENT_NEXTDATA arm (:556-576) is the
            // same R/EOT/MT step a write sector takes, so both take it in X_WEND (a read's
            // medium is `ready` again on the next cycle, with no write-back to wait for).
            x_st <= X_WEND;
          end else begin
            x_left <= x_left - 16'd1;
          end
        end

        // THE SECTOR'S BYTES ARE IN (read or write). A write's medium writes them back and is
        // `ready` again when the image holds them, and only then does the command move on -
        // NP2kai's order, where writesector()'s fdd_write() precedes the next sector and the
        // result (io/fdc.c:457-485). Its failure (and a sector that was never found, x_disc) is
        // writesector's `us|hd<<2|IC0|ND` error7 (:400-403). Success is the R/EOT/MT step both
        // commands share - FDC_WriteData's BUFRECV, `if ((fdc.tc) || (fdc.R++ == fdc.eot)) {
        // R = 1; if (mt) { hd ^= 1; H ^= 1; if (tc || !H) { C++; success7 } } else { C++;
        // success7 } }`, and FDC_ReadData's NEXTDATA (:556-576), which is the same without the
        // tc term (a read's terminal count ends it in X_XFER) - so a write's terminal count ends
        // the command with C+1 and R = 1 (and, under MT, the head flipped), unlike READ DATA's,
        // which leaves C alone (:1016-1026). H is the command's own H unless MT flipped it
        // (success7 sends fdc.H).
        X_WEND: if (x_disc || (media_ready && media_err)) begin
          x_st <= X_IDLE;
          x_wr <= 1'b0;
          x_fmt <= 1'b0;
          res_drv <= x_us;
          res0 <= 8'h40 | {5'd0, x_hd, x_us};   // IC0 | hd<<2 | us
          res1 <= 8'h04;                        // ST1 ND
          res_len <= 3'd7;
          res_pop <= 1'b0;
          res_rel <= 1'b1;
          res_irq <= 1'b1;
          res_idx <= 3'd0;
          st <= ST_RESULT;
        end else if (media_ready) begin
          x_pad <= x_fmt;                        // a FORMAT's next sector is filler again
          if (x_tc || (x_r == x_eot)) begin
            x_r <= 8'h01;
            if (x_mt) begin
              x_hd <= ~x_hd;
              x_h  <= x_h ^ 8'h01;
            end
            if (!x_mt || x_tc || ((x_h ^ 8'h01) == 8'h00)) begin
              // success7 = {hd<<2|us, 0, 0, C, H, R, N} with the step's own C/H/hd. A FORMAT
              // ends here too (R reached SC); NP2kai's success7 then sends fdc.C/H/R as the
              // previous commands left them (FDC_WriteID sets only N), which this model does not
              // keep - the bytes are the write step's, and the uPD765 defines them as meaningless
              // for FORMAT.
              x_st <= X_IDLE;
              x_wr <= 1'b0;
              x_fmt <= 1'b0;
              res_drv <= x_us;
              res0 <= {5'd0, (x_mt ? ~x_hd : x_hd), x_us};
              res1 <= 8'h00;
              x_c <= x_c + 8'd1;      // (x_h, x_r and x_hd took the step's values above)
              res_len <= 3'd7;
              res_pop <= 1'b0;
              res_rel <= 1'b1;
              res_irq <= 1'b1;
              res_idx <= 3'd0;
              st <= ST_RESULT;
            end else begin
              // MT at side 0's EOT: the other side of the same cylinder, from R = 1.
              x_st <= X_REQ;
              x_req_sent <= 1'b0;
            end
          end else begin
            x_r <= x_r + 8'd1;
            x_st <= X_REQ;
            x_req_sent <= 1'b0;
          end
        end

        // THE ID SEARCH THAT FINDS NOTHING. uPD765A/uPD72065 READ DATA: "If the FDC detects the
        // Index Hole twice without finding the right sector (indicated in R), then the FDC sets
        // the ND (No Data) flag in Status Register 1"; READ ID sets MA the same way. MAME
        // src/devices/machine/upd765.cpp index_callback, SCAN_ID: `if(fi.counter == 2) {
        // fi.sub_state = SCAN_ID_FAILED;`. So the command (and its interrupt) ends at the second
        // index pulse after the search began, 1 to 2 revolutions later - never at once.
        // DIVERGENCE: NP2kai answers in the command phase (readsector :417-427) and only defers
        // the interrupt by 512 CPU clocks (fdc_interrupt `nevent_set(NEVENT_FDCINT, 512, ...)`);
        // the chip's own behaviour is followed. A guest that writes its "result pending" flag
        // after the last parameter byte (Star Cruiser's loader, 0060:1011 then `mov [0x100],3`)
        // loses the interrupt to an instant answer and waits forever.
        // The answer: readsector's class (fdc.c:417-427), ST0 = us|hd<<2|IC0, ST1 = ND, with
        // the interrupt (fdcsend_error7 :98-119).
        X_NDW: if (idx_pulse) begin
          if (nd_idx) begin
            x_st <= X_IDLE;
            res_drv <= x_us;
            res0 <= 8'h40 | {5'd0, x_hd, x_us};
            res1 <= 8'h04;                       // ST1 ND
            res_len <= 3'd7;
            res_pop <= 1'b0;
            res_rel <= 1'b1;
            res_irq <= 1'b1;
            res_idx <= 3'd0;
            st <= ST_RESULT;
          end else nd_idx <= 1'b1;
        end

        default: x_st <= X_IDLE;
      endcase

      // A media path that has finished hands the drive back to the command decoder
      // (the busy bit and the level interrupt follow the result phase, above).

      // THE READY-CHANGE INTERRUPTS (the block above `drv_media`). They are the LAST writes of
      // pend/pend_st0 in this block on purpose, and that is NP2kai's own rule, not an accident of
      // order: diskdrv assigns `fdc.stat[drv]` outright, so a change overwrites whatever
      // completion the drive had queued (R3: an interrupt request, set-wins; a SENSE INTERRUPT
      // STATUS drain of the same drive in the same cycle consumed the OLD status and the change
      // stays pending). A change and the ready of the same drive cannot coincide: the change
      // re-arms the drive and reloads its delay, so `ai_ready` is computed from the pre-change
      // state and the change's arm wins the same-cycle write below.
      for (k = 0; k < 2; k = k + 1) begin
        if (chg_ev[k]) begin
          pend[k]     <= 1'b1;
          pend_st0[k] <= 8'hC8 | k[7:0];          // FDCRLT_AI | FDCRLT_NR | drv (diskdrv.c:264)
          armed[k]    <= 1'b1;
          ins_dly[k]  <= DISK_DELAY;
        end else begin
          if (frame_tick && (ins_dly[k] != 5'd0)) ins_dly[k] <= ins_dly[k] - 5'd1;
          if (ai_ready[k]) armed[k] <= 1'b0;
          // Both AI|drv sources, one write (R4): the delay's ready with the gate open
          // (diskdrv.c:240) and the motor bit's rise for an already-ready drive (fdc_o94).
          if ((ai_ready[k] && ai_gate) || (dor_ai && drv_media[k] && !armed[k])) begin
            pend[k]     <= 1'b1;
            pend_st0[k] <= 8'hC0 | k[7:0];        // FDCRLT_AI | drv
          end
        end
      end

      // 0x04BE: NP2kai's fdc_o4be stores the byte and conditionally one RPM bit.
      if (cs && wr && (addr == A_REG144)) begin
        reg144_sel <= din[6:5];
        if (din[4]) rpm[din[6:5]] <= din[0];
      end

      // 0x00BE/0x00BF: the channel-group register (NP2kai fdc_obe stores dat).
      if (cs && wr && (addr == A_CHGREG)) chgreg <= din;

      // 0x94 / 0xCC, the control/DOR port. NP2kai's fdc_o94 (io/fdc.c:996-1032) is NOT a
      // no-op write: a change of bit 4 (FDC enable) or a 0->1 edge of bit 7 (controller
      // reset) calls fdcstatusreset(), which sets fdc.event = NEUTRAL and fdc.status = RQM
      // (:851-855) - i.e. it ABORTS the command in progress and returns the controller to
      // the command phase, DIO/CB and the drive-busy nibble cleared. The machine's own BIOS
      // resets the controller this way: `mov al,0x98 / or dl,0x04 / out dx,al`
      // (BANK7@0x7467), and 0x98 has bit 7 set,
      // so NP2kai resets there. Before this arm the write was dropped, so a guest's FDC
      // recovery/disk-change path could not revive a wedged controller. fdc_o94's `fdc_dmaready(0); dmac_check();`
      // is covered by dropping x_st to X_IDLE: dma_drq is combinationally
      // `x_st == X_XFER && media_rdy`, so it falls with the transfer. The deferred
      // completion queue (pend) is NP2kai's int_stat[], which fdcstatusreset does NOT touch.
      if (cs && wr && (addr == A_DOR)) begin
        if (|((ctrlreg ^ din) & 8'h10) ||
            (|((ctrlreg ^ din) & 8'h80) && din[7])) begin
          st         <= ST_IDLE;
          x_st       <= X_IDLE;
          busy       <= 4'd0;
          res_irq    <= 1'b0;
          res_pop    <= 1'b0;
          res_rel    <= 1'b0;
          x_req_sent <= 1'b0;
        end
        ctrlreg <= din;
      end
    end
  end

  // The change tag as last seen. It follows the tag in AND out of reset, so a mount event during
  // reset is absorbed (see the media_chg port) and every other one is seen exactly once.
  always @(posedge clk) chg_q <= media_chg[1:0];

  // NDM (MSR bit 5): exactly NP2kai's rule, set while a data command transfers
  // in non-DMA mode (`if (fdc.nd) fdc.status |= FDCSTAT_NDM`, fdc.c:362-366
  // write / 450-454 read / 686-690 format). The transfer window is this model's
  // execution state for READ DATA and FORMAT, and the media path's own transfer
  // state; RECALIBRATE/SEEK/READ ID have no transfer window in NP2kai and never
  // carry the bit.
  wire ndm_run = nd && (((st == ST_EXEC) && ((cmd == 5'h06) || (cmd == 5'h0D))) ||
                        (x_st != X_IDLE));

  always @* begin
    dout = 8'hFF;
    if (cs) case (addr)
      // RQM is bit 7 always; CB (bit 4) is set from the command byte through the
      // parameter phase (NP2kai fdc_datawrite), DIO (bit 6) only in the result
      // phase. The low nibble and NDM are fdc.status's own fields, above.
      // RQM|DIO|CB from the moment a read-class command is accepted: NP2kai's data and
      // result phases both carry DIO (readsector :450-454, fdcsend_success7 :141-143).
      // A WRITE's data phase is RQM|CB with NO DIO - the guest supplies the bytes (NP2kai
      // FDC_WriteData CMDRECV, io/fdc.c:441-446). RQM is held off while the medium cannot take
      // a byte (a block fetch or write-back in flight): NP2kai's buffer always can, this
      // medium's cannot, and a PIO writer polls RQM before every byte, so a byte written then
      // would otherwise be dropped. A DMA write waits on DRQ, which follows the same term.
      // A NON-DMA READ shows RQM only while a byte is there (xfer_now): a PIO reader takes a
      // byte on every RQM|DIO|NDM, and while a sector is being located or fetched the
      // 0x92 port answers the idle 0x80 or a stale byte - bytes inserted into the stream.
      // NP2kai's data is synchronous and it drops RQM between sectors (fdc_dataread:
      // `fdc.status &= ~(FDCSTAT_RQM | FDCSTAT_NDM);`). tb_pc9821_fdc_read T13. A DMA read
      // waits on DRQ (the same xfer_now), so its MSR is left as it was.
      A_MSR:  dout = ((x_st != X_IDLE)  ? (x_wr ? (wx_ok ? 8'h90 : 8'h10)
                                               : ((nd && !xfer_now) ? 8'h50 : 8'hD0)) :
                      // CB alone, NO RQM: this model holds the command decoder in ST_EXEC
                      // (the SEEK/RECALIBRATE delay, the no-media deferral) and takes no byte
                      // there, so RQM must not invite one - a byte written on RQM=1/DIO=0 is
                      // the FDC's by the uPD765 handshake, and it was silently dropped.
                      // NP2kai ends SEEK's command phase at once instead (FDC_Seek:
                      // `fdc.status |= FDCSTAT_RQM; fdc.status &= ~FDCSTAT_CB;`); a waiting
                      // driver loses at most the delay here, never the byte.
                      // tb_pc9821_fdc_conform seek_then_sis.
                      (st == ST_EXEC)  ? 8'h10 :     // CB
                      (st == ST_PARAM) ? 8'h90 :     // RQM | CB
                      (st == ST_RESULT) ? 8'hD0 :    // RQM | DIO
                                          8'h80)     // RQM
                     | {4'b0000, busy}
                     | (ndm_run ? 8'h20 : 8'h00);
      // The data port: the result bytes in the result phase, the sector byte while a
      // transfer runs, the machine's own idle 0x80 otherwise (/ 0092 = 80, all five
      // snapshots).
      A_DATA: dout = (st == ST_RESULT) ? res_byte :
                     (x_st == X_XFER)  ? media_dout : 8'h80;
      // NP2kai's fdc_i94 computes this byte on a READ (io/fdc.c:1064-1078); the WRITE
      // fdc_o94 is NOT ignored - it resets the controller (the A_DOR write arm above).
      // For this machine the byte is 0x40 | 0x04 = 0x44 (no DMA request, external-priority
      // strap). IT IS
      // PER-WINDOW: fdc_i94's `if (!(port & 0x10))` (io/fdc.c:1064-1078) sets DMA
      // (0x20) and ready (0x10) for the 2DD door at 0xCC only, so the 2HD door keeps
      // the 0x44 this machine has been measured at (docs/probes/PORTS.TXT, byte 0x44
      // at 0x94) and the 2DD door answers 0x74. qemu-pc98 disagrees in the other
      // direction (FDSTAT_DMA at 0x94, not at 0xcc -- hw/block/pc98-fdc.c:2816-2827)
      // while MAME agrees with NP2kai (the 0xCC byte adds 0x20 and a ready nibble,
      // pc9801.cpp:571-580), so the reference hierarchy picks NP2kai;
      // tb_pc9821_fdc_2dd_bank's control_port_byte_2dd names both readings.
      A_DOR:  dout = win_2dd ? 8'h74 : 8'h44;
      // 1.44M/RPM: NP2kai's fdc_i4be answers rpm[reg144[6:5]] | 0xFE.
      A_REG144: dout = 8'hFE | {7'b0, rpm[reg144_sel]};
      // Channel group: bits 1:0 read back as written, bit 2 is the FDD-mode switch (dip_fixed)
      // and bits 7:3 read 1, both 0x00BE and 0x00BF alike. THE MACHINE: docs/probes/
      // FDMODE-XE10.TXT `PORT 00BE=FF` / `PORT 00BF=FF` with the strap at its reset value 3 on
      // a unit switched to Fixed (MAME pc9801.cpp fdc_mode_r `(m_dsw3->read() & 3) << 2`).
      // NP2kai's fdc_ibe `(fdc.chgreg & 3) | 8 | 0xf0` is the Auto reading of the same byte.
      A_CHGREG: dout = {5'b11111, dip_fixed_q, chgreg[1:0]};
      default: dout = 8'hFF;
    endcase
  end

  // THE COMPLETION IS PRESENTED ONLY WHEN THE CONTROLLER IS IDLE. The BIOS masks
  // IRQ11, issues its four RECALIBRATEs back to back, and unmasks at the end of the
  // burst; with an unconditional `|pend` the level was already high from the earlier
  // completions, so the ISR entered while the LAST command was still executing, read
  // MSR = 0x90 (RQM|CB) and took its "read the data register now" arm. The register was
  // never in a result phase, the arm's wait timed out, and the ISR exited through its
  // give-up path -- so it never issued the SENSE INTERRUPT STATUS handshake that ORs a
  // bit per drive into 0x55E, and the FDD probe polls 0x55E to its timeout. Withholding
  // the level while a command EXECUTES is exactly the model's stated purpose. The data
  // path's own interrupt (res_irq) is raised with its seven-byte result and cleared when
  // that result drains, NP2kai's shape (fdcsend_error7 -> fdc_interrupt, :111-118).
  assign irq = (|pend && (st != ST_EXEC)) || res_irq;
  // The result-phase drain event (see the port comment): the LAST result byte's
  // read, qualified exactly as the drain arm that consumes it below.
  assign res_done = cs && rd && (addr == A_DATA) && (st == ST_RESULT) &&
                    (res_idx + 3'd1 >= res_len);

  // The interface strap, exported for the window gate and the IRQ/DMA routing (see the
  // port comment): NP2kai's gate is `((port >> 4) ^ fdc.chgreg) & 1`.
  assign strap_2hd = chgreg[0];

  // The debug taps (see the port comments). dbg_state's halves are the two questions a
  // hung transfer asks: IRQ says a result is waiting, DRQ says a sector byte is waiting
  // on the DMA engine, st is the command FSM (ST_IDLE..ST_RESULT) and x_st the media
  // data path (X_IDLE..X_XFER). The values are the record's FST/FCM/FRS/FCH fields.
  assign dbg_state  = {irq, dma_drq, st, x_st};
  assign dbg_cmd    = {cmd_mt, 2'b00, cmd};
  assign dbg_result = {res0, res1, 8'h00, exec_st0};
  assign dbg_chrn   = {x_c, x_h, x_r, x_n};

endmodule

`default_nettype wire
