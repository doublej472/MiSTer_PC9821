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
// THE TWO PATHS. The media-present data path answers in the result phase, NP2kai's shape
// (fdcsend_success7/error7, io/fdc.c:98-158). A DATA command (READ DATA, READ ID, WRITE,
// FORMAT) on a drive with no medium answers the same seven-byte result with its interrupt
// after a short execution phase (`exec_res` below; the machine's shape); a
// SEEK or RECALIBRATE that cannot be served is the deferred completion - its ST0 arrives
// through SENSE INTERRUPT STATUS, as the chip's seek commands always do. The ST0 those
// commands leave is the per-state class (`rec_st0` / `data_st0` below), and that is what makes
// an equipped drive with no diskette report as PRESENT to the BIOS instead of absent.
// `media_present` gates which path a command takes, so it is part of the contract.
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
// 0x00BE bit 2 = SETUP's fixed/auto choice (`fd_auto`, below). FIXED (1): the BIOS POST does NOT
// initialise the 640 KB window while bit 0 selects the 1 MB one (BANK7@0x7CAE: bit 2 set and
// bit 0 set -> [0x501] bit 7, clear on this machine -> skip), so no MSR wait at 0xC8 happens,
// IRQ10 stays masked, and INT 1Bh DA/UA 0x7x answers AH = 0x40 at its IRQ10 check
// (BANK7@0x74D3) - the measured unit's own answer (FDMODE-XE10.TXT `SENSE DA=70 AH=40 CF=1`).
// AUTO (0): the IPL retry toggles the interface (`in BE / xor 1 / out BE`, BANK7@0x7E2E-0x7E5E,
// reached from BANK7@0x7CAE when bit 2 is 0), so a 2DD boot disk is also tried on the 640 KB
// window. The 640 KB set-up at BANK7@0x7736 (IRQ10 unmasked at 0x7761) is NOT what a hard-disk
// boot leaves at the DOS prompt: docs/probes/FDMODE-XE10-FDMF3.TXT (Auto (1M), after a hard-disk
// boot) reads `PORT 000A=75` (IRQ10 masked) and `SENSE DA=70 AH=40 CF=1`, as the fixed mode does.
// The interface left at the prompt depends on how many boot attempts failed.
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
//     DMA's terminal count. NP2kai answers success7 there with R forced to 1 and C unchanged
//     (:925-932); THE MACHINE DOES NOT: its uPD765 takes the same end-of-sector step at the
//     terminal count as at EOT (`stp_*` below; docs/probes/XE10T-XE10-FDC.TXT READ1/READ8).
//   * fdcsend_success7 (:120-158) is {hd<<2|us, 0, 0, C, H, R, N};
//     fdcsend_error7 (:98-119) is {(stat>>0), (stat>>8), (stat>>16), C, H, R, N}, and
//     a missing sector is ST0 = us|hd<<2|IC0 and ST1 = ND (readsector, :417-427).
//   * status: NP2kai shows RQM|CB|DIO through both the data phase (readsector, :440-454) and
//     the result phase, with a drive-busy bit. THE MACHINE does not: in DMA mode its MSR reads
//     CB alone (10) through a READ DATA's data phase and D0 in its result phase, with no busy
//     bit in either (docs/probes/XE10T-XE10-FDC2A.TXT `DMA_MSR`; the MSR read below).
//   * at EOT with no terminal count the machine ends a READ DATA ABNORMALLY (IC = 01, ST1 EN,
//     C/H/R the last sector's), where NP2kai advances C and ends normally (X_WEND below).
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
    // SETUP'S FLOPPY DISK MODE, read back as 0x00BE/0x00BF bits 3:2 (pc9821_iobus's bank-A
    // 0x861E shadow; docs/bios-setup.md, DIP switch 3 bits 1:0: 0 640K, 1 auto (640K), 2 1M,
    // 3 auto (1M)). THE MACHINE: the four settings read 0x00BE = F4 / F0 / FF / FB after POST
    // (docs/probes/XE10CFG-XE10-CFGF0/CFGF1/CFG0/CFGF3.TXT; FF is FD with a disk in drive 0),
    // i.e. bit 3 = 0x861E bit 1 (1M) and bit 2 = NOT 0x861E bit 0 (fixed) - the same two bits
    // MAME's fdc_mode_r reads from its DSW3 (`(m_dsw3->read() & 3) << 2`). The BIOS's floppy
    // set-up takes the interface from bit 3 (BANK7@0x5982-0x598A `in al,0xbe / test al,0x8 /
    // mov al,0 / jz / mov al,3` ... `out 0xbe,al`). Each input is 0 at the factory setting
    // (1M), so an undriven port is the measured machine: fd_640k = NOT 0x861E bit 1 clears
    // bit 3, fd_auto = 0x861E bit 0 clears bit 2. Live, not latched: the store is what SETUP
    // writes and the shadow follows it, as port 0x31 bit 4 follows 0x871E bit 5.
    // Bit 2 is the BIOS's fixed/auto test: set (fixed) with bit 0 set, POST skips the 640 KB
    // interface (BANK7@0x7CAE); clear (auto), POST sets that interface up too (BANK7@0x7736).
    input  wire       fd_640k,
    input  wire       fd_auto,
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
  // THE EXECUTION PHASE ENDS IN A SEVEN-BYTE RESULT (a data command on a drive that is not
  // ready), not in a queued status: the result bytes are latched with the command and the
  // result phase opens, with its interrupt, when the delay runs out (the ST_EXEC completion).
  reg        exec_res;

  // The MSR low nibble and bit 5, NP2kai's fdc.status fields (fdc_i90 returns
  // the register verbatim, io/fdc.c:1035-1043). busy is one drive-busy bit per
  // unit, (1 << us), carried from the command's claim point to the drain of the
  // result that reports it: RECALIBRATE/SEEK claim at their CMDRECV arm
  // (fdc.c:562-563, 773-774), SENSE DRIVE STATUS at its result build
  // (fdc.c:300-302) and the interrupt sends at theirs (fdc.c:111-113,
  // 148-150); fdc_dataread's result drain clears the bit (fdc.c:907-909). THE MACHINE sets no
  // busy bit for READ DATA or READ ID, with or without a medium: MSR 10 then D0 for drive 1,
  // not 11/D1, and 10/D0 for drive 2, not 12/D2 (docs/probes/XE10T-XE10-FDC2A.TXT and
  // -FDC2C.TXT, `DMA_MSR` and `NRID`/`NRRD`) - the uPD765A datasheet's D0B-D3B, set only while
  // a drive is in seek mode. So those commands claim no bit here; WRITE DATA and FORMAT keep
  // NP2kai's claim (not captured). nd
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
  // media) and the read answers (chgreg & 3) | 0xF0 | SETUP's floppy disk mode in bits 3:2
  // (0xFC at the factory 1M; the A_CHGREG read) - DOS's FDD driver reads the
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
                   X_NDW   = 3'd4,  // the sector is not there: search until the 2nd index pulse
                   X_IDW   = 3'd5;  // READ ID: the header is found, its ID field is passing
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

  // THE ID FIELD UNDER THE HEAD (X_IDW). READ ID answers when the next ID field has passed the
  // head, not when the command's last byte is written: the uPD765A reads "the first ID field
  // it can find" off the spinning medium (MAME upd765.cpp read_id_continue: `live_start(fi,
  // SEARCH_ADDRESS_MARK_HEADER)`, the result only at COMMAND_DONE). THE MACHINE: twenty back-to-
  // back READ IDs on an Xe10 complete one sector apart, each returning the next R (docs/probes/
  // XE10T-XE10-FDC.TXT `T FDC READID trials=20 c2c_art=5908/5917/9842`: 5910 ARTIC ticks =
  // 19.2 ms on an 8-sector 1.2 MB track whose revolution is 166.7 ms, the longer 9842 at the
  // index gap). The wait here is one sector period of the spinning track, REV / sectors (the
  // medium's own count, media_hs), counted in real time as an accumulator that adds the
  // sector count each cycle until it reaches a revolution, so no divider is needed and a
  // clk_sys change cannot move it. It is the back-to-back spacing the capture measures; the
  // angle at which an isolated command starts, and the longer gap at the index, are not
  // modelled (a lone command waits the full period, the upper end of the chip's range).
  // DIVERGENCE: NP2kai answers READ ID at once and defers only the interrupt by 512 CPU clocks
  // (io/fdc.c fdc_interrupt `nevent_set(NEVENT_FDCINT, 512, fdc_intwait, NEVENT_ABSOLUTE)`);
  // the chip and the capture are followed. An instant answer loses the interrupt of a guest that
  // marks its command pending after the last byte: Windows 95's HSFLOP.PDR media check sends
  // READ ID and only then sets its "interrupt expected" bit, so the ISR dropped the
  // completion, the driver timed out after 800 ms and took the drive for empty
  // (tb_pc9821_fdc_readid_wait).
  reg  [REV_W:0]   idw;        // X_IDW: sector counts accumulated towards one revolution
  reg  [7:0]       idw_hs;     // X_IDW: the track's sector count (>= 1), latched at the header
  wire [REV_W:0]   idw_rev  = spin_360 ? (REV_W+1)'(REV_360) : (REV_W+1)'(REV_300);
  wire [REV_W:0]   idw_next = idw + {{(REV_W-7){1'b0}}, idw_hs};
  wire             idw_done = (idw_next >= idw_rev);

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

  // ---- THE DRIVE POLL AFTER A CONTROLLER RESET ---------------------------------------------
  // uPD765A datasheet, the drive polling feature: after a reset the controller takes every drive
  // as NOT READY and, while it waits in the command phase, polls the drives' ready lines once
  // every 1.024 ms (8 MHz clock; the interval is a fixed number of FDC clocks, so it scales with
  // the clock); the first poll that sees a drive's ready line differ from that assumption leaves
  // ST0 = AI|unit (0xC0|u) for the drive and raises INT, and SENSE INTERRUPT STATUS drains one
  // drive per command. MAME upd765.cpp models it: soft_reset `flopi[i].ready = !ready_polled;`,
  // end_reset (the RESET release) restarts the poll at `attotime::from_usec(1024)`, and
  // run_drive_ready_polling sets `flopi[fid].st0 = ST0_ABRT | fid | (ready ? 0 : ST0_NR);` (ST0_ABRT
  // = 0xC0) for a changed drive, but returns at once `if(main_phase != PHASE_CMD || (fifocfg &
  // FIF_POLL) || command_pos)` - a poll that falls inside a command is skipped and the next one
  // takes the change. pc9801.cpp fdc_2hd_ctrl_w drives the chip's
  // RESET from 0x94 bit 7 (`m_fdc_2hd->reset_w(BIT(data, 7));`), so the poll runs from bit 7's
  // FALL, and the chip is `UPD765A(config, m_fdc_2hd, 8'000'000, true, true);`.
  // NP2kai io/fdc.c fdc_o94 states the same fact (`// FDCリセット後 1,024ms以内にINTがアクティブになる`,
  // "INT becomes active within 1.024 ms after an FDC reset") but implements it as
  // `if(dat & 0x08){ // XXX: Workaround for OSASK`, a 6-frame delay from bit 7's RISE (FDC_INT_DELAY,
  // "Delay 100ms"), because its fdc_intdelay ticks only once per frame (pccore.c `fdc_intdelay();`);
  // that workaround is not followed (100 ms per reset, and the Windows 95 floppy driver resets on
  // first use, on every media-probe step and after a disk change). NOT kept from NP2kai: its arm
  // needs the motor bit 0x08 in the releasing write; the machine's does not. A reset released with
  // the motor bit CLEAR (0x90 then 0x10) interrupts exactly as one with it set (0x98 then 0x18):
  // docs/probes/XE10T-XE10-FDC2A.TXT:63-65 (`RST_M ... t_irq_art=330 rises=1 ... sis=C000,80`,
  // `RST_NM da=90 w=90/10 irr_pre=10 t_irq_art=329 rises=1 t_irq2_art=- sis=C000,80`; drive 2's
  // -FDC2C.TXT rows read 333/334 ticks and C100), 1.07 ms at the 3.255 us ARTIC tick - the
  // datasheet's first poll - and with both drives empty neither interrupts (-FDC2B.TXT), which
  // the `drv_ready` term of the AI below already answers. Kept from NP2kai: statuses already
  // pending for drives that are not ready are not discarded (NP2kai's fdcstatusreset leaves int_stat alone; MAME's soft_reset
  // clears them) - a ready drive's pending status is replaced by its AI, as both agree.
  // WHO NEEDS IT: HSFLOP.PDR (Windows 95 4.00.950, NEC build) resets with 0x98 then 0x18 when
  // SENSE DRIVE STATUS reads READY and sleeps until the FDC interrupt.
  // THE TIME BASE is the FDC's own clock: POLL_FDC_CLKS FDC clocks at FDC_CLOCK_HZ, converted to
  // SYS_CLOCK_HZ cycles, so a clk_sys change cannot move it. One FDC clock is modelled for both
  // windows (MAME has one 8 MHz chip behind both, pc9821.cpp maps 0x90 and 0xC8 to m_fdc_2hd).
  // rst_poll is a one-cycle event with one consumer, the AI|drv write in the ready-change loop.
  localparam integer FDC_CLOCK_HZ  = 8_000_000;   // MAME pc9801.cpp UPD765A at 8'000'000
  localparam integer POLL_FDC_CLKS = 8192;        // 1.024 ms at 8 MHz (uPD765A datasheet)
  localparam integer POLL_CYCLES   = int'((64'(SYS_CLOCK_HZ) * 64'(POLL_FDC_CLKS)) / 64'(FDC_CLOCK_HZ));
  localparam integer POLL_W        = $clog2(POLL_CYCLES);
  reg  [POLL_W-1:0] poll_cnt;
  reg               poll_arm;     // a release has been seen and its first poll has not hit yet
  wire       dor_wr   = cs && wr && (addr == A_DOR);
  wire       rst_rel  = dor_wr && ctrlreg[7] && !din[7];
  // The poll hits only in the command phase with no command byte arriving: MAME's
  // `main_phase != PHASE_CMD || ... || command_pos` skip (R5: a skipped poll is deferred to the
  // next one, never dropped).
  wire       poll_idle = (st == ST_IDLE) && (x_st == X_IDLE) && !(cs && wr && (addr == A_DATA));
  wire       poll_hit  = poll_arm && (poll_cnt == {POLL_W{1'b0}});
  wire       rst_poll  = poll_hit && poll_idle && !dor_wr;
  always @(posedge clk) begin
    if (reset) begin
      poll_arm <= 1'b0;
      poll_cnt <= {POLL_W{1'b0}};
    end else if (dor_wr && din[7]) begin
      // Bit 7 set holds the chip in reset (no polling): MAME upd765.cpp soft_reset stops the
      // poll until end_reset.
      poll_arm <= 1'b0;
      poll_cnt <= POLL_W'(POLL_CYCLES - 1);
    end else if (rst_rel) begin
      // Its fall, whatever the motor bit, restarts the interval.
      poll_arm <= 1'b1;
      poll_cnt <= POLL_W'(POLL_CYCLES - 1);
    end else if (poll_hit) begin
      // Any other control write leaves the poll running: only the chip's RESET pin is wired to
      // the latch (pc9801.cpp `m_fdc_2hd->reset_w(BIT(data, 7));`) and upd765.cpp reset_w
      // returns at once when the level does not change (`if(bool(state) == !BIT(dor, 2))
      // return;`); NP2kai fdc_o94 never cancels a loaded int_timer. A hit in the cycle of such a
      // write is deferred to the next poll (rst_poll's !dor_wr, R5: deferred, never dropped).
      poll_arm <= !rst_poll;
      poll_cnt <= POLL_W'(POLL_CYCLES - 1);
    end else if (poll_arm) begin
      poll_cnt <= poll_cnt - 1'b1;
    end
  end

  // ---- THE VFO TIMER (0x94/0xCC bit 0 TTRG, bit 2 TMSK) --------------------------------------
  // undoc98 io_fdd.txt (I/O 0094h/00CCh write): TTRG drives the VFO's TRIG IN - "writing this
  // bit as 1 raises an interrupt 100 ms later" - and TMSK enables that timer interrupt (1 =
  // enabled, 0 = masked). It is the interface's, not the uPD765A's: it reaches the same INT line
  // and leaves the controller's status alone. THE MACHINE: the BIOS's hand-back 0x94 <- 09, 0C
  // raises ONE interrupt 91.2 / 90.0 ms later with SENSE INTERRUPT STATUS answering 80
  // (docs/probes/XE10T-XE10-FDC2A.TXT `VFO da=90 irr_pre=10 t_irq_art=28018 rises=1 irr_end=18`,
  // -FDC2C.TXT `t_irq_art=27649`; 3.255 us ARTIC ticks), and the line then STAYS high: the same
  // run's later READ DATA completions raise no new IRQ11 edge (DMA_REF/DMA_MSR/DMA_92 `end=T
  // t_irq_art=-`) until RST_M's 0x98 - TMSK clear - lets its reset interrupt rise again
  // (`RST_M ... irr_pre=10 t_irq_art=330 rises=1`). THE BIOS's IRQ11 handler uses it as the motor-
  // off clock: finding no controller status it decrements 0x0485 and re-triggers with 0D, 0C
  // while the count is not zero, else writes 0x00 (BANK7@0x7AAB-0x7AD1); the count runs down
  // between the captures (`bda0485=74`, `6F`, `00`), so a re-trigger is a fresh request - the
  // trigger drops the output. AN EXPIRY WHILE TMSK IS CLEAR IS HELD: after a cold boot kit 2 wrote
  // 0x94 <- 09, 08 (trigger, TMSK clear), waited 200 ms, then 0x94 <- 0C (TMSK set, no trigger),
  // and the slave IRR's bit 3 was clear through the wait and set within 3 ARTIC ticks of the 0C,
  // and still set after a SENSE INTERRUPT STATUS that answered 80 (docs/probes/KIT2-XE10-FD0.TXT:4,
  // `irr09-08/msr09-08/irr200ms/irr0C/msr0C/irrdrain 10 80 90 98 80 98 rise=00000003 sis=80`).
  // So the one-shot's output (vfo_out) is set at the expiry and cleared only by a trigger, and
  // TMSK gates it onto the line. Windows 95's HSFLOP.PDR is unaffected: in both of its recorded
  // runs (the w95fd lane's --dbg-fdc captures, 236 and 5441 writes to 0x94) every write that sets
  // TMSK without a trigger follows a trigger write within 1 ms, so no held expiry is ever shown.
  // The period is the two captures' mean, 90.6 ms, in real time (SYS_CLOCK_HZ cycles): the VFO is
  // an analogue one-shot, not a count of the FDC clock. vfo_trig is a one-cycle event with one
  // consumer (this block); the output is a level.
  localparam integer VFO_CYCLES = int'((64'(SYS_CLOCK_HZ) * 64'd906) / 64'd10000);   // 90.6 ms
  localparam integer VFO_W      = $clog2(VFO_CYCLES + 1);
  wire              vfo_trig = dor_wr && din[0];
  reg  [VFO_W-1:0]  vfo_cnt;
  reg               vfo_run;
  reg               vfo_out;   // the one-shot's output: set at the expiry, cleared by a trigger
  reg               vfo_q;
  always @(posedge clk) begin
    if (reset) begin
      vfo_run <= 1'b0;
      vfo_cnt <= {VFO_W{1'b0}};
      vfo_out <= 1'b0;
      vfo_q   <= 1'b0;
    end else if (vfo_trig) begin
      vfo_run <= 1'b1;
      vfo_cnt <= VFO_W'(VFO_CYCLES - 1);
      vfo_out <= 1'b0;
      vfo_q   <= 1'b0;
    end else begin
      if (vfo_run) begin
        if (vfo_cnt == {VFO_W{1'b0}}) vfo_run <= 1'b0;
        else                          vfo_cnt <= vfo_cnt - 1'b1;
      end
      // The output is held whatever TMSK says; TMSK gates it onto the line, and a write that
      // changes TMSK acts at once (the note above).
      vfo_out <= vfo_out || (vfo_run && (vfo_cnt == {VFO_W{1'b0}}));
      vfo_q   <= (vfo_out || (vfo_run && (vfo_cnt == {VFO_W{1'b0}}))) &&
                 (dor_wr ? din[2] : ctrlreg[2]);
    end
  end

  // ---- THE SELECTED DRIVE'S RDY LINE (0xCC bit 4, the 640K I/F mode) ------------------------
  // undoc98 io_fdd.txt (I/O 0094h,00CCh [READ]) calls bit 4 "RDY - the state of the FDD's RDY
  // pin [640KB I/F only]", and the drive answers on that pin only while the controller selects
  // it. The uPD765A datasheet's polling feature: once SPECIFY has been sent, the drive select
  // lines go into a polling mode, and in between commands the chip polls all four drives for a
  // change of their ready lines (the 1.024 ms interval the reset poll above uses). So the pin
  // shows the drive a command addressed from that command's unit byte until the first poll
  // after the command, and another drive after that.
  // THE BIOS reads it exactly that way: BANK7@0x7E67-0x7E7E issues SENSE DRIVE STATUS for the
  // unit (`mov ah,4 / call 0x7db1 / call 0x7dcf / call 0x7dea`) and on the 640K door then
  // ignores ST3 and reads `in al,0xcc / test al,0x10` at once. Its 640K path waits on the bit
  // after turning the motor on (BANK7@0x74E7-0x750D, up to 16 tries) and, when the 640K AI is
  // off, answers a data command AH=60h (not ready) if it is clear (BANK7@0x7525-0x7535:
  // `test byte [0x500],4 / jnz / call 0x7e67 / jnz / mov ah,0x60`). [0x500] bit 2 is "the 640KB
  // I/F mode's AI enable" (undoc98 memsys.txt, 0000:0500h bit 2, set only by INT 1Bh function
  // 83h, BANK7@0x765C). The IPL's interface toggle at Floppy mode Auto (BANK7@0x7E2E-0x7E3F)
  // never sets it, so a 2DD disk booted through the toggle reads every sector through this bit.
  // THE MACHINE: docs/probes/FDMODE-XE10-FDMF0.TXT and -FDMF1.TXT read 0xCC = 64 (bit 4 clear) at
  // the DOS prompt with a disk in drive 0, before and after the probe's SENSE (each read comes
  // after DOS output, not straight after a command), which is the "another drive" half; the
  // same captures' [0x500] = 05 shows the AI on, so that BIOS never consulted the bit there.
  // The drive's own ready is `drv_media` (a medium, its insert delay done), the forced-ready
  // bit is not on this pin (undoc98: FRY is ORed in "before the FDC", not into this read), and
  // the motor latch is not modelled in it (NP2kai's fdc_i94 0x74 has no motor term; MAME's
  // floppy ready_r, pc9801.cpp:580, does). Item 180 holds the capture that pins the timing.
  // sel_set (a unit byte at the data port) and the controller-reset write (the control port)
  // are at different addresses, so the two never coincide (R3).
  reg  [1:0]        sel_u;
  reg  [POLL_W-1:0] sel_cnt;
  wire       sel_set  = cs && wr && (addr == A_DATA) && (st == ST_PARAM) && (p_idx == 3'd0) &&
                        (cmd != 5'h03);   // every command's first parameter is HD|US but SPECIFY's
  wire       cmd_idle = (st == ST_IDLE) && (x_st == X_IDLE);
  always @(posedge clk) begin
    if (reset || (dor_wr && din[7])) begin
      sel_u   <= 2'd0;
      sel_cnt <= {POLL_W{1'b0}};
    end else if (sel_set) begin
      sel_u   <= din[1:0];
      sel_cnt <= POLL_W'(POLL_CYCLES - 1);
    end else if (sel_cnt != {POLL_W{1'b0}}) begin
      // No poll runs while a command is in progress, so the select holds until it ends.
      sel_cnt <= cmd_idle ? sel_cnt - 1'b1 : POLL_W'(POLL_CYCLES - 1);
    end
  end
  wire       sel_rdy  = (sel_cnt != {POLL_W{1'b0}}) && drv_equipped[sel_u] && drv_media[sel_u];

  // The ready-change loop's AI|drv sources (see that loop, which these one-hot wires feed, one
  // write): the insert delay's ready with the gate open (diskdrv.c:240), the motor bit's rise for
  // an already-ready drive (fdc_o94) and the first drive poll after a controller reset for a
  // ready drive (rst_poll, above). A drive's mount event (chg_ev) outranks them in that loop.
  wire [1:0] rdy_ai;
  generate
    for (gu = 0; gu < 2; gu = gu + 1) begin : g_rdy_ai
      assign rdy_ai[gu] = (ai_ready[gu] && ai_gate) || (dor_ai && drv_media[gu] && !armed[gu]) ||
                          (rst_poll && drv_ready[gu]);
    end
  endgenerate

  // ---- THE INT LINE: the uPD765A's INT flag, not the level of the status queue -------------------
  // MAME upd765.cpp keeps INT as a flag of its own (`irq`): command_end and
  // run_drive_ready_polling set it, and EVERY data-port access clears it - fifo_w `irq = false;
  // check_irq();` for each command and parameter byte, fifo_r the same for each result byte - as
  // does soft_reset (the RESET pin, 0x94 bit 7 on this machine: pc9801.cpp `reset_w(BIT(data, 7))`);
  // SENSE INTERRUPT STATUS "drops the irq always, but also returns the first full st0 it finds".
  // The queued statuses (pend/pend_st0) are NOT the line: they stay for SENSE INTERRUPT STATUS.
  // NP2kai agrees on the point that matters - each fdc_interrupt() is a fresh PIC request
  // (io/pic.c pic_setirq sets the IRR bit on every call), so no queued status can absorb a later
  // interrupt. Driving the line from `|pend` (the model before this) broke exactly that on the
  // PC-98's edge-triggered slave 8259: a status the guest left undrained (the Windows 95 driver's
  // ISR leaves without SENSE INTERRUPT STATUS when it enters with MSR CB set) held the line high,
  // and every later completion - the reset's drive poll HSFLOP.PDR sleeps on, a READ DATA's
  // result - rose on a line that was already high and was never seen.
  // WHEN a ready change is presented follows the datasheet's drive polling as MAME models it: the
  // poll returns at once `if(main_phase != PHASE_CMD || ... || command_pos)`, so a change that
  // arrives while a command is being written, executed or read back is presented once the
  // controller is idle in the command phase again (`int_def`, R7: deferred, never dropped). NP2kai's
  // diskdrv raises a media change at once, inside a command too; the datasheet is followed here as
  // for the reset poll. A completion (ST_EXEC's end) is presented at once, as before.
  // R3: set-wins - an event in the cycle of a data-port access or a DOR reset is kept.
  // R4: the coincidences are named in the two next-state lines in the command block (the int_q/
  // int_def writes) and fired together in tb_pc9821_fdc_int_line L6.
  reg        int_q;        // INT, MAME's `irq`
  reg        int_def;      // a ready change waiting for the command phase
  wire       int_acc   = cs && (rd || wr) && (addr == A_DATA);   // fifo_r / fifo_w
  wire       int_rst   = dor_wr && din[7];                        // soft_reset
  wire       int_rdy   = |(chg_ev | rdy_ai);                      // a ready change this cycle
  // A queued completion this cycle. A not-ready data command's result is not one: its line is
  // res_irq, raised with the result as every data-path result's is.
  wire       int_done  = (st == ST_EXEC) && (delay == 16'd0) && !exec_res;
  wire       int_set   = int_done || ((int_rdy || int_def) && poll_idle);

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

  // The data commands' class when the drive cannot serve them: us|hd<<2|IC0|NR =
  // 0x48|hd<<2|u, READ ID included. THE MACHINE: READ ID and READ DATA on an empty drive both
  // answer ST0 48|u, and READ ID on the unequipped unit 2 answers 4A (docs/probes/
  // XE10T-XE10-FDC2A.TXT, -FDC2B.TXT, -FDC2C.TXT rows NRID, NRRD, NRID_U2: `st0=49`, `st0=48`,
  // `st0=4A`). NP2kai's FDC_DriveCheck (:175-186) agrees for READ DATA and the writes; its
  // READ ID answers us|hd<<2|IC0 = 0x40|hd<<2|u (FDC_ReadID, :494-560), with no NR - the
  // capture outranks it. (A WRITE on a drive that IS ready but protected answers 0x40|hd<<2|u
  // with ST1 NW = 0x02 instead, and that arm is in the media path.)
  wire [7:0] data_st0 = 8'h48 | {5'd0, cur_hd, cur_u};
  // THE NOT-READY EXECUTION PHASE, from the command's last byte to its result and interrupt
  // (the machine's MSR reads CB, 10, meanwhile). THE MACHINE, in ARTIC ticks of 3.255 us from
  // that byte: READ DATA's result is already up at the first MSR poll, 6 ticks (19.5 us) on
  // (XE10T-XE10-FDC2A.TXT `NRRD ... msr0=10 msr_end=D0 msr=D0:1:6`); READ ID's MSR still reads
  // 10 at that poll and its interrupt comes at 9 ticks, 29.3 us (-FDC2B.TXT `NRID da=90 end=I
  // t_end_art=9 ... msr=10:1:6`). The model takes 10 us and 25 us, inside those windows, in real
  // time (SYS_CLOCK_HZ cycles), so a clk_sys change cannot move them. The writes and FORMAT are
  // not captured and take READ DATA's.
  localparam [15:0] NR_DATA_CYCLES = 16'(SYS_CLOCK_HZ / 100_000);   // 10 us
  localparam [15:0] NR_RID_CYCLES  = 16'(SYS_CLOCK_HZ / 40_000);    // 25 us
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

  // THE END-OF-SECTOR STEP, the uPD765's ID update after each sector of READ DATA / WRITE DATA
  // (uPD765A datasheet, the table of C/H/R/N at the end of a read/write command; MAME
  // src/devices/machine/upd765.cpp read_data_continue/write_data_continue, `command[4]++`
  // below EOT and `command[2]++; command[4] = 1;` at it). For the sector just transferred:
  //   R <  EOT                        -> R+1, C and H unchanged;
  //   R == EOT, MT=0                  -> C+1, R = 1;
  //   R == EOT, MT=1, on side 0 (H=0) -> H flipped, R = 1, C unchanged (side 1 is next);
  //   R == EOT, MT=1, on side 1 (H=1) -> H flipped, C+1, R = 1.
  // The SAME step ends a command at a terminal count (the command stops after that sector),
  // which is what the machine answers: a C0 READ DATA of R1 with EOT=1, and of R1..R8 with
  // EOT=8, both ended by the DMA's count on the last sector, report C=01 H=00 R=01
  // (docs/probes/XE10T-XE10-FDC.TXT `X READ8 sectors=8 ... c=01 h=00 r=01`; DMAROUTE-XE10.TXT
  // `RES=01000001000102` likewise). NP2kai diverges at the terminal count: READ DATA forces
  // R = 1 and leaves C (fdc_dataread :1016-1026), WRITE DATA answers R = 1, C+1 whatever R was
  // (FDC_WriteData `if ((fdc.tc) || (fdc.R++ == fdc.eot))`); the capture outranks both. A
  // terminal count BEFORE EOT (R+1) is the datasheet's and MAME's row, not yet captured (todo).
  wire       stp_eot  = (x_r == x_eot);
  wire       stp_flip = stp_eot && x_mt;
  wire       stp_cinc = stp_eot && (!x_mt || (x_h == 8'h01));
  wire [7:0] stp_r    = stp_eot ? 8'h01 : (x_r + 8'd1);
  wire [7:0] stp_h    = stp_flip ? (x_h ^ 8'h01) : x_h;
  wire [7:0] stp_c    = stp_cinc ? (x_c + 8'd1) : x_c;

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
      exec_res <= 1'b0;
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
      idw <= '0;
      idw_hs <= 8'd1;
      for (k = 0; k < 4; k = k + 1) pend_st0[k] <= 8'h00;
      for (k = 0; k < 8; k = k + 1) cmds[k] <= 8'h00;
      armed <= 2'b00;
      ins_dly[0] <= 5'd0;
      ins_dly[1] <= 5'd0;
      int_q   <= 1'b0;
      int_def <= 1'b0;
    end else begin
      // THE INT FLAG (its section above the RECALIBRATE classes), one write each. R3 set-wins: a
      // completion or a ready change in the cycle of a data-port access or a DOR reset is kept.
      // R4: a ready change while the controller is busy is deferred (int_def) and presented at
      // the first idle cycle; one at idle is presented at once.
      int_q   <= (int_q & ~(int_acc | int_rst)) | int_set;
      int_def <= (int_def & ~(poll_idle | int_rst)) | (int_rdy & ~poll_idle);
      // A command that raises an interrupt queues its completion status. The
      // BIOS waits for the interrupt BEFORE reading any result (its driver calls
      // the 0x7D0E wait and only then touches the DMA), so every interrupt
      // command completes straight to the interrupt and none of them leaves a
      // result phase standing: a result phase would leave MSR at 0xD0 and the
      // ISR's own SENSE INTERRUPT STATUS write would never take it.
      if ((st == ST_EXEC) && (delay == 16'd0)) begin
        if (exec_res) begin
          // A not-ready data command: its seven-byte result (latched at its acceptance, below)
          // and its interrupt, the data path's shape. The flag is that ONE command's: it is
          // consumed here, so a later SEEK/RECALIBRATE on a ready drive (whose arm below does
          // not write it) completes through SENSE INTERRUPT STATUS again. Left set, every ready
          // seek after one not-ready data command replayed the stale not-ready result instead
          // (the BIOS's READ ID of an empty unit 1 at boot, then Windows 95 HSFLOP.PDR's
          // RECALIBRATE of unit 0 found MSR D1 and no seek status: "device not ready";
          // tb_pc9821_fdc_read T9d).
          exec_res <= 1'b0;
          res_irq <= 1'b1;
          st <= ST_RESULT;
        end else begin
          pend[drv] <= 1'b1;
          pend_st0[drv] <= exec_st0;
          st <= ST_IDLE;
        end
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
            exec_res <= 1'b0;   // completes through SENSE INTERRUPT STATUS (exec_res's note)
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
            end else begin
              // READ DATA: treg := C unless a SEEK set it (FDC_ReadData, the lasttreg rule
              // above), then the first sector. No busy bit (`busy`'s note).
              if (drive_equipped(cur_p0[1:0]) && (lasttreg[cur_p0[1:0]] != treg[cur_p0[1:0]]))
                treg[cur_p0[1:0]] <= cmds[1];
              x_st <= X_REQ;
              x_req_sent <= 1'b0;
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
            st <= ST_EXEC;
            if ((cmd == 5'h07) || (cmd == 5'h0F)) begin
              exec_res <= 1'b0;
              busy[cur_p0[1:0]] <= 1'b1;
              delay <= RECAL_CYCLES;
            end else begin
              // A DATA COMMAND ON A DRIVE THAT IS NOT READY (no medium, its insert delay still
              // running, or a unit the machine does not equip): the seven-byte result
              // {ST0, 0, 0, C, H, R, N} with its interrupt after the not-ready execution phase
              // (NR_*_CYCLES), and SENSE INTERRUPT STATUS then answers 80 - the machine's
              // NRRD/NRID/NRID_U2 rows (`data_st0`'s note), NP2kai's fdcsend_error7 shape
              // (:98-119). The result bytes are latched now; no command byte is taken while the
              // command executes, so nothing else writes them before the result opens. C/H/R/N:
              // READ DATA and the writes load the command's own (NRRD answers its command's
              // c=00 h=00 r=01 n=03, NP2kai's get_chrn); READ ID and FORMAT carry none, and the
              // machine's READ ID answers what the previous command left (NRID_U2 after NRRD).
              // No busy bit for READ DATA / READ ID (`busy`'s note); the writes and FORMAT keep
              // NP2kai's claim.
              exec_res <= 1'b1;
              delay    <= (cmd == 5'h0A) ? NR_RID_CYCLES : NR_DATA_CYCLES;
              res_drv  <= cur_u;
              res0     <= deferred_st0;
              res1     <= 8'h00;
              res_len  <= 3'd7;
              res_pop  <= 1'b0;
              res_rel  <= 1'b1;
              res_irq  <= 1'b0;
              res_idx  <= 3'd0;
              if (cmd_is_read(cmd) || cmd_is_write(cmd)) begin
                x_c <= cmds[1];
                x_h <= cmds[2];
                x_r <= cmds[3];
                x_n <= cmds[4];
              end
              if (cmd_is_write(cmd) || (cmd == 5'h0D)) busy[cur_p0[1:0]] <= 1'b1;
            end
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
            // The medium cannot take this FORMAT sector. On the FIRST sector (R = 1) it cannot
            // format the track at all (a D88, or a raw format whose N is not the image's): the
            // IC0|NW answer every FORMAT got before Stage B, still honest - the track was not
            // formatted. NP2kai would rebuild a D88 track (fdd_formating_d88) and write a
            // mismatched raw geometry at its own offsets; both are recorded gaps.
            // PAST THE TRACK'S LAST SECTOR (R > 1: SC more than the track holds, SC = 0 counting
            // as 256) the track is full, and the chip ends the command at the index pulse with
            // success: the uPD765A formats until the index comes round again (NEC uPD765A data
            // sheet, FORMAT A TRACK), and MAME upd765.cpp counts SC down through 0 (`command[3]--`)
            // with its live write ended by the index, answering ST0 = hd<<2|us and no ST1 bit.
            // Windows 95's full format sends SC = 0 (tb_pc9821_fdd_write W15c). NP2kai writes
            // SC * (128 << N) bytes (fdd_formatinit_xdf `size = (128 << fdc.N) * fdc.sc`), so
            // SC = 0 writes nothing there; the chip is followed.
            x_st <= X_IDLE;
            x_wr <= 1'b0;
            x_fmt <= 1'b0;
            res_drv <= x_us;
            res0 <= (x_r == 8'h01) ? (8'h40 | {5'd0, x_hd, x_us}) : {5'd0, x_hd, x_us};
            res1 <= (x_r == 8'h01) ? 8'h02 : 8'h00;  // ST1 NW only when nothing was formatted
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
              // The header is found: C = the track register, H = the head (fdd_readid_d88
              // :522-526), R/N = the header's; crcn advances and wraps at the track's own
              // sector count (:513-518). The answer waits for the ID field to pass (X_IDW).
              x_st <= X_IDW;
              crcn <= ((crcn + 8'd1) >= media_hs) ? 8'h00 : (crcn + 8'd1);
              x_c <= treg[x_us];
              x_h <= {7'd0, x_hd};
              x_r <= media_hr;
              x_n <= media_hn;
              idw <= '0;
              idw_hs <= (media_hs == 8'd0) ? 8'd1 : media_hs;
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
            // The DMA engine's terminal count ends the command right here, and the result
            // carries the end-of-sector step of the sector it ended in (`stp_*`): the machine
            // answers C=01 R=01 for a C0 READ DATA whose count ends on R = EOT
            // (docs/probes/XE10T-XE10-FDC.TXT `X READ1 ... c=01 h=00 r=01`), where NP2kai
            // forces R = 1 with C unchanged (fdc_dataread :1016-1026). ST0's HD is the head the
            // sector was read on.
            x_st <= X_IDLE;
            res_drv <= x_us;
            res0 <= {5'd0, x_hd, x_us};
            res1 <= 8'h00;
            x_c <= stp_c;
            x_h <= stp_h;
            x_r <= stp_r;
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
        // writesector's `us|hd<<2|IC0|ND` error7 (:400-403). Success is the end-of-sector step
        // (`stp_*`, the uPD765's table; see there): the command ends at a terminal count (a
        // write's, x_tc; a read's ends in X_XFER) or when the step advances C, and otherwise
        // reads/writes the next sector - the same R on side 1 after MT's flip at side 0's EOT.
        // H is the command's own H unless MT flipped it (success7 sends fdc.H). ST0's HD is the
        // head after the step, NP2kai's (success7 sends fdc.hd, which FDC_WriteData flips at
        // EOT under MT); MAME reports the side of the last sector instead when a terminal count
        // ends it (upd765.cpp `if((command[3] & 1) && !done) fi.st0 |= 4;`). Not captured.
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
        end else if (!x_wr && stp_cinc) begin
          // A READ THAT REACHES EOT WITH NO TERMINAL COUNT ENDS ABNORMALLY (a read's count ends
          // in X_XFER, so here there was none): ST0 IC = 01 with the head of the last sector,
          // ST1 EN, and C/H/R the LAST SECTOR's, not stepped. THE MACHINE: docs/probes/
          // XE10T-XE10-FDC2A.TXT:43 (`EOT_NT`, R1 EOT=8 with a 9-sector count: `st0=40 st1=80
          // st2=00 c=00 h=00 r=08 n=03`) and :45 (`EOT_MT`, MT with a 17-sector count: `st0=44
          // st1=80 st2=00 c=00 h=01 r=08 n=03`), drive 2's -FDC2C.TXT rows alike (41, 45); the
          // uPD765A datasheet's EN ("the FDC tries to access a sector beyond the final sector of
          // a cylinder") and MAME upd765.cpp read_data_continue. NP2kai ends it normally with
          // C+1, R=1 (FDC_ReadData :484-495); the capture outranks it. The terminal-count rows of
          // the same captures are the `stp_*` step (TC_R3, TC_MT0, TC_MT1). A WRITE at EOT keeps
          // the normal end below: not captured.
          x_st <= X_IDLE;
          res_drv <= x_us;
          res0 <= 8'h40 | {5'd0, x_hd, x_us};   // IC0 | hd<<2 | us
          res1 <= 8'h80;                        // ST1 EN
          res_len <= 3'd7;
          res_pop <= 1'b0;
          res_rel <= 1'b1;
          res_irq <= 1'b1;
          res_idx <= 3'd0;
          st <= ST_RESULT;
        end else if (media_ready) begin
          x_pad <= x_fmt;                        // a FORMAT's next sector is filler again
          x_c <= stp_c;
          x_h <= stp_h;
          x_r <= stp_r;
          if (stp_flip) x_hd <= ~x_hd;
          if (x_tc || stp_cinc) begin
            // success7 = {hd<<2|us, 0, 0, C, H, R, N} with the step's own C/H/R. A FORMAT
            // ends here too (R reached SC); NP2kai's success7 then sends fdc.C/H/R as the
            // previous commands left them (FDC_WriteID sets only N), which this model does not
            // keep - the bytes are the write step's, and the uPD765 defines them as meaningless
            // for FORMAT.
            x_st <= X_IDLE;
            x_wr <= 1'b0;
            x_fmt <= 1'b0;
            res_drv <= x_us;
            res0 <= {5'd0, (stp_flip ? ~x_hd : x_hd), x_us};
            res1 <= 8'h00;
            res_len <= 3'd7;
            res_pop <= 1'b0;
            res_rel <= 1'b1;
            res_irq <= 1'b1;
            res_idx <= 3'd0;
            st <= ST_RESULT;
          end else begin
            // The next sector: R+1, or (MT at side 0's EOT) the other side of the same
            // cylinder from R = 1.
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

        // READ ID's ID field passes the head (its note at `idw`): one sector period, then
        // success7 = {hd<<2|us, 0, 0, C, H, R, N} (fdcsend_success7 :120-158) with the
        // interrupt. A controller reset meanwhile drops x_st to X_IDLE (the A_DOR arm).
        X_IDW: if (idw_done) begin
          x_st <= X_IDLE;
          res_drv <= x_us;
          res0 <= {5'd0, x_hd, x_us};
          res1 <= 8'h00;
          res_len <= 3'd7;
          res_pop <= 1'b0;
          res_rel <= 1'b1;
          res_irq <= 1'b1;
          res_idx <= 3'd0;
          st <= ST_RESULT;
        end else begin
          idw <= idw_next;
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
          // The three AI|drv sources, one write (R4): `rdy_ai` (above the INT line).
          if (rdy_ai[k]) begin
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
                        ((x_st != X_IDLE) && !x_isid));

  always @* begin
    dout = 8'hFF;
    if (cs) case (addr)
      // RQM is bit 7 always; CB (bit 4) is set from the command byte through the
      // parameter phase (NP2kai fdc_datawrite), DIO (bit 6) only in the result
      // phase. The low nibble and NDM are fdc.status's own fields, above.
      // A NON-DMA read is RQM|DIO|CB from the moment it is accepted: NP2kai's data and
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
      // waits on DRQ (the same xfer_now); its MSR is the machine's CB alone (below).
      // READ ID has no data phase: while it searches for an ID field the MSR is CB alone, no
      // RQM, no DIO (MAME upd765.cpp msr_r, PHASE_EXEC: `msr |= MSR_CB;` with RQM only for a
      // data byte), so a poller does not take the idle data port for a result byte.
      // A DMA-MODE READ (SPECIFY ND = 0) shows CB ALONE, RQM low, through its whole data phase:
      // THE MACHINE's MSR reads 10 from the command to the result phase's D0
      // (docs/probes/XE10T-XE10-FDC2A.TXT `DMA_MSR ... msr=10:18698:6,D0:65535:98835`, every
      // sample of an 8-sector read; -FDC2C.TXT alike) - the uPD765A datasheet's DMA mode, where
      // the bytes move on DRQ/DACK and RQM is not raised. NP2kai shows RQM|DIO (D1); a driver
      // that polls for RQM|DIO to read the result while the transfer runs took a data byte for a
      // result byte (the core's own XE10KIT1 DMAROUTE run read `80 80 ...`).
      A_MSR:  dout = ((x_st != X_IDLE)  ? (x_isid ? 8'h10 :
                                           x_wr ? (wx_ok ? 8'h90 : 8'h10)
                                                : (!nd ? 8'h10 : xfer_now ? 8'hD0 : 8'h50)) :
                      // CB alone, NO RQM: this model holds the command decoder in ST_EXEC
                      // (the SEEK/RECALIBRATE delay, a not-ready data command) and takes no byte
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
      // IT IS PER-WINDOW. THE MACHINE: the 2HD door at 0x94 reads 0x44 (every 1M-mode FDMODE
      // capture, docs/probes/FDMODE-XE10.TXT `PORT 0094=44`), and the 2DD door at 0xCC reads 0x64
      // in the 640K I/F mode (docs/probes/FDMODE-XE10-FDMF0.TXT and -FDMF1.TXT, `PORT 00CC=64`
      // before and after a SENSE that found the disk in drive 0). undoc98 io_fdd.txt names the
      // bits: bit 5 DMACH "fixed 1 in the 640KB I/F mode", bits 3:2 TYP1/TYP0 = 01, and bit 4
      // "RDY - the state of the FDD's RDY pin [640KB I/F only]". NP2kai's fdc_i94 sets bit 4
      // whenever the 2DD door is read (0x74) and MAME pc9801.cpp:580 ORs a live
      // `fdc_drive_ready_r(m_fdc_2hd) << 4`; the capture outranks both where it reads: away from
      // a command bit 4 is the captured 0, and straight after a command it is the addressed
      // drive's ready (`sel_rdy`, THE SELECTED DRIVE'S RDY LINE above), which the BIOS's 640K
      // read path needs (BANK7@0x7E7A `in al,0xcc / test al,0x10`).
      A_DOR:  dout = win_2dd ? {3'b011, sel_rdy, 4'b0100} : 8'h44;
      // 1.44M/RPM: bit 0 is NP2kai's fdc_i4be rpm[reg144[6:5]]; bit 4 is "1.44 MB access
      // possible", which undoc98 io_fdd.txt (I/O 04BEh read) says reads 0 for every drive in the
      // 640KB I/F mode. THE MACHINE: `PORT 04BE=EE` with the strap at 0 (FDMODE-XE10-FDMF0.TXT
      // 00BE=F4, -FDMF1.TXT 00BE=F0) and FE with it at 1 (FDMODE-XE10.TXT 00BE=FF, -FDMF3.TXT
      // 00BE=FB, and -FDM0.TXT 00BE=FD, where 0xBE bit 1 is 0 and bit 4 still reads 1 - so the
      // bit follows the interface strap, bit 0, not MAME fdc_3mode_r's `BIT(m_fdc_mode, 1)`).
      // NP2kai's constant 0xFE is the 1M reading.
      A_REG144: dout = {3'b111, chgreg[0], 3'b111, rpm[reg144_sel]};
      // Channel group: bits 1:0 read back as written, bits 3:2 SETUP's floppy disk mode
      // (fd_640k, fd_auto: see those ports) and bits 7:4 read 1. THE MACHINE: docs/probes/
      // FDMODE-XE10.TXT `PORT 00BE=FF` with the strap at its reset value 3 and SETUP at 1M
      // (MAME pc9801.cpp fdc_mode_r `(m_dsw3->read() & 3) << 2`). NP2kai's fdc_ibe
      // `(fdc.chgreg & 3) | 8 | 0xf0` is the auto (1M) reading of the same byte. 0x00BF reads
      // FF (pc9821_iobus's read arm), so only 0x00BE reaches this arm on a read.
      A_CHGREG: dout = {4'b1111, ~fd_640k, ~fd_auto, chgreg[1:0]};
      default: dout = 8'hFF;
    endcase
  end

  // THE LINE IS THE INT FLAG (int_q, its section above) WHILE A STATUS IS QUEUED, plus the data
  // path's own interrupt. The BIOS masks IRQ11, issues its four RECALIBRATEs back to back and
  // unmasks at the end of the burst; each RECALIBRATE's command bytes lower the flag, so the line
  // is low while the LAST one executes and rises at its completion, and the ISR enters with the
  // controller idle (MSR 0x80) and runs the SENSE INTERRUPT STATUS handshake that ORs a bit per
  // drive into 0x55E.
  // (A line driven by `|pend` alone was already high from the earlier completions there, and the
  // ISR took its "read the data register now" arm on MSR = 0x90 and gave up.) The data path's own
  // interrupt (res_irq) is raised with its seven-byte result and cleared when that result drains,
  // NP2kai's shape (fdcsend_error7 -> fdc_interrupt, :111-118).
  // The VFO timer's output (THE VFO TIMER, above) is the interface's own request on the same line.
  assign irq = (int_q && |pend) || res_irq || vfo_q;
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

`ifndef SYNTHESIS
  // R8: the INT flag never stands while a command executes. Every command reaches ST_EXEC through
  // its data-port bytes, which lower the flag, and a ready change meanwhile is deferred (int_def),
  // so a flag up in ST_EXEC is an interrupt presented inside a command (the ISR would read MSR CB
  // and leave without SENSE INTERRUPT STATUS). tb_pc9821_fdc_int_line L3/L7.
  always @(posedge clk)
    if (!reset && int_q && (st == ST_EXEC))
      $error("pc9821_fdc: the INT flag is up while a command executes");
`endif

endmodule

`default_nettype wire
