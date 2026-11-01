// PC-98 ATAPI CD-ROM on the built-in IDE: ALWAYS bank 1's MASTER (IDE unit 2), the hard disk
// always bank 0's master (unit 0) - the stock CD-equipped Xe10's layout and NP2kai's default (HDD
// at unit 0, CD at unit 2). Fixed, independent of the build and of the media: the Xe10
// capture's disk on bank 1 (docs/probes/IDE.TXT) is a CF card in the CD connector, a quirk of
// that one machine, not the layout to model.
//
// NP2kai is the primary reference for every register value and command answer here:
// NP2kai cbus/ideio.c (the task file, the ATA-level commands, the data port) and
// NP2kai cbus/atapicmd.c (the packet commands and the CD-DA player state). Where
// this model differs from NP2kai it says so at the line, with the reason.
//
// WHY A SEPARATE DEVICE BESIDE pc9821_ata. The two IDE devices on a bank share one register
// window and are told apart by DEV (0x064C bit 4); the two banks share the ports and are told
// apart by the 0x0432 bank select. pc9821_ata is bank 0's master and floats bank 1. This module
// is bank 1's master: it latches the bank select (0x0432) and DEV itself, owns the read data of
// the task file at bank 1 (`io_own`, which the system's read mux honours) - the absent slave's
// answers included - and executes the commands addressed to it.
// NP2kai stores a task-file write only into the SELECTED drive (ideio_o644..o64a call
// getidedrv()), so this device latches those writes only while it is selected; 0x064C and
// 0x074C reach both drives of the bank (ideio_o64c, ideio_o74c).
//
// THE MEDIUM. One hps_io slot (OSD "S4,ISOPCD,Mount CD-ROM"; "T[11],Eject CD-ROM" is its
// size-0 mount event): an ISO (2048-byte sectors, one data track) or a PCD (tools/cue2pcd.py:
// a 2352-byte header holding the track table and the READ TOC address fields ready-made, then
// raw 2352-byte sectors). The type is decided by CONTENT (the
// header's "PC98CD01" magic), as the floppy decides D88 by content. The first 2048 bytes of the
// file are fetched into the upper half of the buffer RAM at mount; for a PCD that IS the TOC, and
// for an ISO the same header fields are synthesised from the capacity (`iso_word`), so READ TOC
// and READ SUB-CHANNEL have one implementation for both formats.
//
// CD-DA (AUDIO_EN). PLAY AUDIO MSF/(10), PAUSE/RESUME, READ SUB-CHANNEL and the player state
// follow atapicmd.c's daflag/dacurpos/dalength model. The sectors stream from the same slot
// straight into src/soc/cdda.v's ring (one {R,L} word per stereo sample): one sector per host
// request when its CDDA_REQ says a sector fits, four in one request when CDDA_REQ4 says four
// fit; no buffer of this module holds audio. The ring reads ahead of the speakers, so a PAUSE,
// a STOP, a SEEK, a new PLAY, a mount and a core reset each flush it (CDDA_FLUSH). A PAUSE keeps
// sector granularity: RESUME refetches the sector that was being heard and plays it from its
// first sample, where NP2kai's mixer continues mid-sector from its one-sector dabuf (ideio.c
// playdevaudio) - up to one sector (13 ms) of it is heard twice.

`default_nettype none

// The slot-side registers (medium, engine, player, the host request pins) carry power-up values,
// and all but the player's have no reset (see their declaration), which is this warning's shape.
/* verilator lint_off PROCASSINIT */
module pc9821_atapi #(
    // The CD-DA player: the audio commands, the play state and the audio fetch. 0 builds the
    // data-only drive - the audio commands then abort as unknown opcodes (atapicmd_a0 default).
    parameter AUDIO_EN = 1'b1,
    // A DEBUG INSTRUMENT, off in every shipped build (build_profile.py --cdrom-log): the drive's
    // own conversation as compact binary records on the debug UART (tools/decode_cdlog.py
    // decodes them). LOG_CLK_HZ is clk's rate, for the records' millisecond timestamp.
    parameter LOG_EN = 1'b0,
    parameter integer LOG_CLK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        io_rd,
    input  wire        io_wr,
    input  wire [15:0] io_addr,
    input  wire [ 7:0] io_din,
    output reg  [ 7:0] io_dout,
    // This device answers the current read: the system's IDE read mux takes io_dout over
    // pc9821_ata's when it is set.
    output wire        io_own,
    output wire        irq,

    // The CD slot of hps_io (slot 4): the mount event, and the block request/ack/payload.
    input  wire        img_mounted,
    input  wire [63:0] img_size,
    output reg  [31:0] sd_lba = 32'd0,
    output reg  [ 5:0] sd_blk_cnt = 6'd0,
    output reg         sd_rd = 1'b0,
    input  wire        sd_ack,
    input  wire        sd_buff_wr,
    input  wire [12:0] sd_buff_addr,
    input  wire [15:0] sd_buff_dout,

    // src/soc/cdda.v's write side: CDDA_REQ = there is room for a sector, CDDA_REQ4 = room for
    // four; one CDDA_WR edge per stereo sample, {R, L}. CDDA_PLAYED pulses each time another
    // sector's worth of samples has left the ring for the speakers (the played position), and
    // cdda_flush empties the ring when the player stops, pauses or moves, at a mount, and for
    // every cycle of the core reset.
    input  wire        cdda_req,
    input  wire        cdda_req4,
    input  wire        cdda_played,
    output wire        cdda_flush,
    output reg         cdda_wr = 1'b0,
    output reg  [31:0] cdda_data = 32'd0,

    // LOG_EN: one byte per cycle while log_we is high, held until log_accept (the debug UART
    // FIFO's take). Tied off when LOG_EN is 0.
    output wire [ 7:0] log_byte,
    output wire        log_we,
    input  wire        log_accept
);

  // ---- NP2kai's constants (cbus/ideio.h, cbus/atapicmd.h) ----
  localparam [7:0] ST_BSY = 8'h80, ST_DRDY = 8'h40, ST_DMRD = 8'h20, ST_DSC = 8'h10,
                   ST_DRQ = 8'h08, ST_ERR = 8'h01;   // ST_ERR is ATAPI's CHK
  localparam [7:0] INTR_IO = 8'h02, INTR_CD = 8'h01;
  localparam [7:0] ERR_ABRT = 8'h04, ERR_AMNF = 8'h01;
  localparam [3:0] SK_NO_SENSE = 4'h0, SK_NOT_READY = 4'h2, SK_ILLEGAL = 4'h5,
                   SK_ABORTED = 4'hB;
  localparam [15:0] ASC_NONE = 16'h0000, ASC_INVALID_FIELD = 16'h0024,
                    ASC_NOT_READY_TO_READY = 16'h0028, ASC_NO_MEDIUM = 16'h003A,
                    ASC_LBA_OUT_OF_RANGE = 16'h0021;
  // The sense data is kept as the codes of the few values the drive ever reports (REQUEST SENSE
  // and the command log decode them): 4 + 16 flops and their per-site muxes became 2 + 3.
  localparam [1:0] SKC_NONE = 2'd0, SKC_NOT_READY = 2'd1, SKC_ILLEGAL = 2'd2, SKC_ABORTED = 2'd3;
  localparam [2:0] ASCC_NONE = 3'd0, ASCC_INVALID_FIELD = 3'd1, ASCC_NOT_READY_TO_READY = 3'd2,
                   ASCC_NO_MEDIUM = 3'd3, ASCC_LBA_OUT_OF_RANGE = 3'd4;
  function automatic [3:0] sk_val(input [1:0] c);
    case (c)
      SKC_NOT_READY: sk_val = SK_NOT_READY;
      SKC_ILLEGAL:   sk_val = SK_ILLEGAL;
      SKC_ABORTED:   sk_val = SK_ABORTED;
      default:       sk_val = SK_NO_SENSE;
    endcase
  endfunction
  function automatic [1:0] sk_enc(input [3:0] k);
    case (k)
      SK_NOT_READY: sk_enc = SKC_NOT_READY;
      SK_ILLEGAL:   sk_enc = SKC_ILLEGAL;
      SK_ABORTED:   sk_enc = SKC_ABORTED;
      default:      sk_enc = SKC_NONE;
    endcase
  endfunction
  function automatic [15:0] asc_val(input [2:0] c);
    case (c)
      ASCC_INVALID_FIELD:      asc_val = ASC_INVALID_FIELD;
      ASCC_NOT_READY_TO_READY: asc_val = ASC_NOT_READY_TO_READY;
      ASCC_NO_MEDIUM:          asc_val = ASC_NO_MEDIUM;
      ASCC_LBA_OUT_OF_RANGE:   asc_val = ASC_LBA_OUT_OF_RANGE;
      default:                 asc_val = ASC_NONE;
    endcase
  endfunction
  function automatic [2:0] asc_enc(input [15:0] a);
    case (a)
      ASC_INVALID_FIELD:      asc_enc = ASCC_INVALID_FIELD;
      ASC_NOT_READY_TO_READY: asc_enc = ASCC_NOT_READY_TO_READY;
      ASC_NO_MEDIUM:          asc_enc = ASCC_NO_MEDIUM;
      ASC_LBA_OUT_OF_RANGE:   asc_enc = ASCC_LBA_OUT_OF_RANGE;
      default:                asc_enc = ASCC_NONE;
    endcase
  endfunction
  // atapicmd.c's daflag values: the READ SUB-CHANNEL audio status byte.
  // DA_ERR is 0x14, the play stopped because the medium went away (ideio.c playdevaudio:
  // `drv->daflag = 0x14;` when the sxsi device is not READY).
  localparam [2:0] DA_PLAY = 3'd1, DA_PAUSE = 3'd2, DA_DONE = 3'd3, DA_ERR = 3'd4,
                   DA_NONE = 3'd5;   // 0x10 + value

  // ---- the window: which bank and which device are selected ----
  reg bank1;        // 0x0432 bit 0, latched like pc9821_ata's channel_reg (bit-7 writes ignored)
  reg dev1;         // 0x064C bit 4 of the last write at bank 1
  // This drive is the selected device: DEV 0, bank 1's master. NEC's own drivers depend on that
  // position: NECCDD.SYS selects 0xE0, NECCD.SYS talks to whatever DEV the BIOS left - DEV 0 -
  // and both look at bank 1 only. DEV 1 on bank 1 is an ABSENT slave, answered here as
  // pc9821_ata answers its own (ATA-3 r6 s.9.5.1: STATUS and ALTERNATE STATUS read 0x00 and a
  // command for it is not executed, except EXECUTE DEVICE DIAGNOSTIC).
  wire mine = !dev1;
  wire sel = bank1 && mine;
  wire tf_port = (io_addr[15:4] == 12'h064 && !io_addr[0]) ||
                 io_addr == 16'h0641 || io_addr == 16'h074C;
  // 0x0433 bit 1 = "the selected bank has a connected device" (NP2kai ideio_i433: bank[1] & 1,
  // and a device on that bank): with this drive on bank 1 that is true even with no hard disk.
  // As the bank's master the drive answers every task-file read at bank 1 (the absent slave's too).
  assign io_own = (bank1 && tf_port) || (bank1 && io_addr == 16'h0433);

  // ---- task file of this device ----
  // (FEATURES, 0x0642's write side, is not stored: ideio.c's CD arms never read drv->wp but
  // SET FEATURES', which aborts every subcommand for a CD.)
  reg [7:0] status, error, sc, sn, drhd;
  reg [15:0] cy;
  reg       nien, srst;
  // The interrupt-pending state, and INTRQ as the device drives it. ATA-3 s.7.2.9 (Device
  // Control): "When nIEN=1, or the device is not selected, the INTRQ signal shall be in a high
  // impedance state." The two banks' INTRQs are ORed onto IRQ9 (pc9821_system; MAME pc9801.cpp
  // INPUT_MERGER_ANY_HIGH "ideirq"), so a polled driver's unacknowledged request must not hold
  // the line, or it hides the other bank's next edge. tb_pc9821_atapi C18.
  reg       irq_pend;
  assign    irq = irq_pend && !nien;
  reg [1:0] skc;    // NP2kai's drv->sk, as SKC_*
  reg [2:0] ascc;   // {ASCQ, ASC} as NP2kai's drv->asc, as ASCC_*
  /* verilator lint_off UNUSEDSIGNAL */   // read only by the LOG_EN instrument (Quartus 17 cannot index a call)
  wire [15:0] asc_w = asc_val(ascc);
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- medium ----
  // The MEDIUM and the ENGINE are the slot's, not the guest's: a core reset neither unmounts
  // the image (hps_io does not re-send a mount) nor may it orphan a host transfer in flight, so
  // these registers take power-up values and are left out of the reset below.
  reg        loaded = 1'b0, changed = 1'b0, is_pcd = 1'b0, mounting = 1'b0;
  reg [19:0] iso_cap = 20'd0;  // ISO sectors (saturated)
  reg [19:0] leadout = 20'd0;  // PCD lead-out LBA
  reg [7:0]  tracks = 8'd0, first_trk = 8'd1, ctrl0 = 8'h00;
  wire [19:0] totals = !loaded ? 20'd0 : (is_pcd ? leadout : iso_cap);
  reg        damsfbcd;         // atapicmd.c: NEC mode (BCD MSF), set by MODE SENSE page 0x0F
  // The lead-out MSF of an ISO (for its synthesised TOC), from the MSF converter at mount.
  reg [6:0]  lo_m = 7'd0; reg [5:0] lo_s = 6'd0; reg [6:0] lo_f = 7'd0;
  reg [7:0]  lo_mb = 8'd0, lo_sb = 8'd0, lo_fb = 8'd0;   // the same in BCD

  // ---- CD-DA player state (atapicmd.c drv->daflag/dacurpos/dalength) ----
  // The player IS reset by the core, unlike the medium and the engine: NP2kai runs ideio_reset
  // on every machine reset (cbus/cbuscore.c resetfn[]: `ideio_reset,`), which zeroes `ideio`
  // (daplaying, so the play stops) and re-runs devinit (`drv->daflag = 0x15;`, dacurpos and
  // dalength 0). The reset stop is in the player block below; these are the power-up values.
  reg [2:0]  daflag = 3'd5;
  // READ-AHEAD. dacurpos/dalength are the FETCH side: the next sector to fetch into src/soc/
  // cdda.v's ring and how many remain. daplaypos is the sector the speakers are on: it follows
  // the ring's CDDA_PLAYED pulses, and it is what a PAUSE holds. A play completes when its last
  // sector has been played, not when it was fetched. dacurpos + dalength (the play's end) is
  // invariant under fetching.
  // THE REPORTED POSITION is NP2kai's dacurpos, which is the next sector its mixer will LOAD:
  // playdevaudio loads a sector into dabuf and increments dacurpos before mixing it (ideio.c
  // `drv->dacurpos++;` right after the sxsicd_readraw), so while a sector is being heard NP2kai
  // reports one past it. READ SUB-CHANNEL here reports daplaypos + da_lead_now: 1 while the
  // sector at daplaypos is in the ring (fetched: dacurpos > daplaypos) - the counterpart of
  // NP2kai's loaded dabuf - and, for a stopped play (PAUSE, 0x14), the same fact latched in
  // da_lead when it stopped (the flush empties the ring and rewinds the fetch side, but NP2kai's
  // dacurpos stays where it was).
  reg [19:0] dacurpos = 20'd0;
  reg [19:0] dalength = 20'd0;
  reg [19:0] daplaypos = 20'd0;
  reg        da_lead = 1'b0;
  reg [2:0]  e_nsec = 3'd1;     // audio sectors in the fetch in flight (1 or 4)
  // A position command (PLAY/STOP/SEEK) executed while an audio sector fetch is still in
  // flight SUPERSEDES that fetch: NP2kai's player is synchronous (atapicmd.c playaudio sets
  // dacurpos/dalength and streams from there), so nothing of the old play may follow it - its
  // samples are not written to the ring and its completion does not advance the new play
  // (which skipped the new play's first sector and left dalength one short).
  // tb_pc9821_atapi C17.
  reg        da_stale = 1'b0;

  // ---- the packet ----
  reg [7:0] cdb [0:11];
  reg [2:0] pkt_words;
  reg [7:0] data_lo;           // low byte of a data-port word the guest is writing

  // ---- the buffer: words 0..1023 the current data/response, 1024..2047 the header ----
  reg [15:0] buf_mem [0:2047];
  reg [10:0] buf_raddr;
  reg [15:0] buf_q;
  reg        buf_we;
  reg [10:0] buf_waddr;
  reg [15:0] buf_wdata;
  always @(posedge clk) buf_q <= buf_mem[buf_raddr];
  always @(posedge clk) if (buf_we) buf_mem[buf_waddr] <= buf_wdata;

  // ---- command FSM ----
  localparam [2:0] S_IDLE = 3'd0, S_PKT = 3'd1, S_EXEC = 3'd2, S_PREP = 3'd3, S_BUILD = 3'd4,
                   S_FETCH = 3'd5, S_DATA = 3'd6;
  reg [2:0]  st;
  reg [7:0]  cmd;              // the ATA command the data phase belongs to (0xA0 / 0xA1)
  reg [9:0]  ptr;              // guest word pointer in the data phase
  reg [10:0] dp_words;         // words in this data phase
  reg        dp_read;          // the phase is a READ(10) sector (more may follow)
  // 20 bits: a READ(10) only runs while rd_lba < totals <= 0xFFFFF (every fetch and every
  // advance is behind in_range), so the upper twelve bits the CDB carries are only ever tested
  // once, at the command's decode, and never reach this register.
  reg [19:0] rd_lba;
  reg [15:0] rd_left;

  // builder: writes a response into words 0.. of the buffer
  localparam [3:0] K_IDENT = 4'd0, K_INQ = 4'd1, K_SENSE = 4'd2, K_CAP = 4'd3, K_MSENSE = 4'd4,
                   K_SUBCH = 4'd5, K_TOC0 = 4'd6, K_TOC1 = 4'd7, K_GETCFG = 4'd8;
  reg [3:0]  bk;
  reg [8:0]  bi_a, bi_b;       // pipeline: stage A presents the header address, B writes
  reg        bv_b;
  reg [11:0] b_full;           // the reply's full length (<= 8 x 256 + 4 bytes, READ TOC at 255 tracks)
  reg [15:0] b_alloc;          // the command's allocation length
  // response parameters
  reg [6:0]  toc_e0;           // first TOC entry index
  reg [9:0]  toc_base;         // header word base of the address fields (LBA / MSF / BCD)
  reg [5:0]  ms_page;          // MODE SENSE page code
  reg        ms_chg;           // changeable values
  reg        sub_full;         // READ SUB-CHANNEL: 16 bytes (subQ, format 1) vs the 4-byte header
  // READ SUB-CHANNEL's prepared fields
  reg [7:0]  sub_ctrl, sub_point;
  // (stored already formatted: binary, or BCD in NEC mode - the converter's one formatter)
  reg [7:0]  ab_m, ab_s, ab_f, rl_m, rl_s, rl_f;

  // ---- engine: one hps_io request at a time ----
  localparam [1:0] E_IDLE = 2'd0, E_CALC = 2'd1, E_WAIT = 2'd2, E_STREAM = 2'd3;
  localparam [1:0] EK_HDR = 2'd0, EK_DATA = 2'd1, EK_AUDIO = 2'd2;
  reg [1:0]  e_st = 2'd0, e_kind = 2'd0;
  reg [19:0] e_pos = 20'd0;
  reg [8:0]  e_w0 = 9'd0;      // first wanted word in the transfer
  reg [12:0] e_n = 13'd0;      // wanted words (an audio fetch of 4 sectors is 4704)
  reg        hdr_pend = 1'b0, data_pend = 1'b0;
  reg        e_odd = 1'b0;     // audio: the next wanted word is a right sample
  wire e_done = (e_st == E_STREAM) && !sd_ack;
  wire audio_in_flight = (e_st != E_IDLE) && (e_kind == EK_AUDIO);
  wire [12:0] e_rel = sd_buff_addr - {4'd0, e_w0};
  wire e_word = (e_st == E_STREAM) && sd_ack && sd_buff_wr &&
                (sd_buff_addr >= {4'd0, e_w0}) && (e_rel < e_n);

  // ---- MSF converter (frames -> M:S:F), sequential ----
  reg        cv_busy = 1'b0, cv_ph = 1'b0, cv_owner_mount = 1'b0, iso_msf_pend = 1'b0;
  reg [19:0] cv_x = 20'd0;
  reg [6:0]  cv_m = 7'd0; reg [5:0] cv_s = 6'd0;
  // The step for the phase the converter is in: 4500 frames per minute while the M step runs,
  // 75 per second after it (atapicmd.c's frames -> M:S:F walk). ONE 20-bit subtractor and ONE
  // 20-bit compare serve both phases - the operand is selected by the same `cv_ph` that selected
  // the arm, so the phases stay mutually exclusive and the merged form is value- and
  // cycle-identical to the two-subtractor form (tools/check_seq_equiv.py --old proves it
  // register for register against the pre-change module).
  wire [19:0] cv_step = cv_ph ? 20'd75 : 20'd4500;
  wire        cv_step_ge = (cv_x >= cv_step);
  // The F step's last cycle, `cv_x < 75`, is the same compare at the phase-1 operand.
  wire       cv_done = cv_busy && cv_ph && !cv_step_ge;

  function automatic [7:0] bcd(input [6:0] v);
    reg [3:0] t;
    begin
      t = (v >= 7'd90) ? 4'd9 : (v >= 7'd80) ? 4'd8 : (v >= 7'd70) ? 4'd7 : (v >= 7'd60) ? 4'd6 :
          (v >= 7'd50) ? 4'd5 : (v >= 7'd40) ? 4'd4 : (v >= 7'd30) ? 4'd3 : (v >= 7'd20) ? 4'd2 :
          (v >= 7'd10) ? 4'd1 : 4'd0;
      bcd = {t, 4'(v - 7'(t) * 7'd10)};
    end
  endfunction
  // The converter's result, the one place an M:S:F is formatted: BCD, and the form NEC mode
  // asks for (atapicmd.c storemsf's isBCD).
  wire [7:0] cv_mb = bcd(cv_m), cv_sb = bcd({1'b0, cv_s}), cv_fb = bcd(cv_x[6:0]);
  wire [7:0] cv_mf = damsfbcd ? cv_mb : {1'b0, cv_m};
  wire [7:0] cv_sf = damsfbcd ? cv_sb : {2'b00, cv_s};
  wire [7:0] cv_ff = damsfbcd ? cv_fb : {1'b0, cv_x[6:0]};
  function automatic [7:0] unbcd(input [7:0] b);
    unbcd = 8'(b[7:4]) * 8'd10 + 8'(b[3:0]);
  endfunction
  // frames of an M:S:F triple (atapicmd.c atapi_cmd_playaudiomsf)
  function automatic [19:0] frames(input [7:0] m, input [7:0] s, input [7:0] f);
    frames = 20'(m) * 20'd4500 + 20'(s) * 20'd75 + 20'(f);
  endfunction

  // ---- constant replies (NP2kai), one ROM ----
  // The IDENTIFY PACKET page (ideio.c setidentify, IDETYPE_CDROM arm: word 0 0x8580, serial
  // "1.0" with word 12 = '0' + the sxsidrv unit 3, model "NEC CD-ROM DRIVE:98", words 49/51/53/
  // 64/80/82 and 93 = 0x4B00 for a slave), INQUIRY (atapicmd.c cdrom_inquiry, the YUIDEBUG form
  // that file defines: type 5, removable, "NEC     " "CD-ROM DRIVE:98 " "1.0 "; NECCDD.SYS
  // compares vendor+product against "NEC     CD-ROM DRIVE", storage-expand report appendix A),
  // and the MODE SENSE pages (atapicmd.c defval_/chgval_pagecode_01/0d/0e/2a, and the NEC page
  // 0x0F whose bytes 4/5 that code derives from page 0x2A's bytes 4..7: 0x11/0x18 default, 0/0
  // changeable). A block ROM, not a mux in the builder's word path. Word map (the ROM_* bases):
  //   0..255 IDENTIFY PACKET, 256..273 INQUIRY, 288.. the pages, default then changeable.
  localparam [9:0] ROM_INQ = 10'd256;
  // The MODE SENSE pages are laid out by the address the builder forms, NOT by where NP2kai keeps
  // them: {1, page, changeable, word}, 64 words per page, the two copies (default, changeable) 32
  // words apart, so the address is a concatenation. The page index is 0 = 0x01, 1 = 0x0D, 2 = 0x0E,
  // 3 = 0x2A, 4 = 0x0F, 5 = the run of all four (0x3F, and any code the drive does not know: atapicmd.c
  // falls through 0x01, 0x0D, 0x0E, 0x2A in that order), whose words are copied here rather than
  // chased by a chain of base-plus-offset arms (the pre-change drive's address function, in
  // tests/pc9821/pc9821_atapi_ref.sv, is the proof: tb_pc9821_atapi_equiv sweeps every page, both
  // value sets and every allocation length against it). 0..255 IDENTIFY PACKET, 256..273 INQUIRY.
  // An initialised array read through a register: Quartus infers the block ROM from this shape
  // (a registered case statement it built in LUTs). Words not listed are zero.
  (* romstyle = "M10K" *) reg [15:0] rom [0:1023];
  initial begin
    for (int k = 0; k < 1024; k++) rom[k] = 16'h0000;
    rom[0] = 16'h8580;
    rom[10] = 16'h312E;
    rom[11] = 16'h3020;
    rom[12] = 16'h0032;   // '0' + sxsidrv: unit 2 (bank 1's master)
    rom[13] = 16'h2020;
    rom[14] = 16'h2020;
    rom[15] = 16'h2020;
    rom[16] = 16'h2020;
    rom[17] = 16'h2020;
    rom[18] = 16'h2020;
    rom[19] = 16'h2020;
    rom[23] = 16'h2020;
    rom[24] = 16'h2020;
    rom[25] = 16'h2020;
    rom[26] = 16'h2020;
    rom[27] = 16'h4E45;
    rom[28] = 16'h4320;
    rom[29] = 16'h4344;
    rom[30] = 16'h2D52;
    rom[31] = 16'h4F4D;
    rom[32] = 16'h2044;
    rom[33] = 16'h5249;
    rom[34] = 16'h5645;
    rom[35] = 16'h3A39;
    rom[36] = 16'h3820;
    rom[37] = 16'h2020;
    rom[38] = 16'h2020;
    rom[39] = 16'h2020;
    rom[40] = 16'h2020;
    rom[41] = 16'h2020;
    rom[42] = 16'h2020;
    rom[43] = 16'h2020;
    rom[44] = 16'h2020;
    rom[45] = 16'h2020;
    rom[46] = 16'h2020;
    rom[49] = 16'h0200;
    rom[51] = 16'h0278;
    rom[53] = 16'h0003;
    rom[64] = 16'h0003;
    rom[80] = 16'h003E;
    rom[82] = 16'h0214;
    rom[93] = 16'h407B;   // ideio.c setidentify: the master's value
    rom[256] = 16'h8005;
    rom[257] = 16'h2100;
    rom[258] = 16'h001F;
    rom[260] = 16'h454E;
    rom[261] = 16'h2043;
    rom[262] = 16'h2020;
    rom[263] = 16'h2020;
    rom[264] = 16'h4443;
    rom[265] = 16'h522D;
    rom[266] = 16'h4D4F;
    rom[267] = 16'h4420;
    rom[268] = 16'h4952;
    rom[269] = 16'h4556;
    rom[270] = 16'h393A;
    rom[271] = 16'h2038;
    rom[272] = 16'h2E31;
    rom[273] = 16'h2030;
    // page 0x01, default values
    rom[512] = 16'h0601;   // word 0
    rom[517] = 16'hFF37;   // word 5
    rom[520] = 16'h060D;   // word 8
    rom[522] = 16'h3C00;   // word 10
    rom[523] = 16'h4B00;   // word 11
    rom[525] = 16'h0F00;   // word 13
    rom[526] = 16'hFFFF;   // word 14
    rom[527] = 16'hFFFF;   // word 15
    rom[528] = 16'h0E0E;   // word 16
    rom[529] = 16'h0004;   // word 17
    rom[531] = 16'h4B00;   // word 19
    rom[532] = 16'hFF01;   // word 20
    rom[533] = 16'hFF02;   // word 21
    rom[537] = 16'h0002;   // word 25
    rom[539] = 16'hFFFF;   // word 27
    rom[540] = 16'hFF0F;   // word 28
    rom[541] = 16'hFF0F;   // word 29
    // page 0x01, changeable values
    rom[545] = 16'hFF37;   // word 1
    rom[548] = 16'h060D;   // word 4
    rom[550] = 16'h3C00;   // word 6
    rom[551] = 16'h4B00;   // word 7
    rom[553] = 16'h0F00;   // word 9
    rom[554] = 16'hFFFF;   // word 10
    rom[555] = 16'hFFFF;   // word 11
    rom[556] = 16'h0E0E;   // word 12
    rom[557] = 16'h0004;   // word 13
    rom[559] = 16'h4B00;   // word 15
    rom[560] = 16'hFF01;   // word 16
    rom[561] = 16'hFF02;   // word 17
    rom[565] = 16'h0002;   // word 21
    rom[567] = 16'hFFFF;   // word 23
    rom[568] = 16'hFF0F;   // word 24
    rom[569] = 16'hFF0F;   // word 25
    rom[572] = 16'h122A;   // word 28
    rom[574] = 16'h6571;   // word 30
    rom[575] = 16'h0729;   // word 31
    // page 0x0D, default values
    rom[576] = 16'h060D;   // word 0
    rom[578] = 16'h3C00;   // word 2
    rom[579] = 16'h4B00;   // word 3
    rom[581] = 16'h0F00;   // word 5
    rom[582] = 16'hFFFF;   // word 6
    rom[583] = 16'hFFFF;   // word 7
    rom[584] = 16'h0E0E;   // word 8
    rom[585] = 16'h0004;   // word 9
    rom[587] = 16'h4B00;   // word 11
    rom[588] = 16'hFF01;   // word 12
    rom[589] = 16'hFF02;   // word 13
    rom[593] = 16'h0002;   // word 17
    rom[595] = 16'hFFFF;   // word 19
    rom[596] = 16'hFF0F;   // word 20
    rom[597] = 16'hFF0F;   // word 21
    rom[600] = 16'h122A;   // word 24
    rom[602] = 16'h6571;   // word 26
    rom[603] = 16'h0729;   // word 27
    rom[604] = 16'hC202;   // word 28
    rom[605] = 16'hFF00;   // word 29
    rom[606] = 16'h8000;   // word 30
    rom[607] = 16'hC202;   // word 31
    // page 0x0D, changeable values
    rom[609] = 16'h0F00;   // word 1
    rom[610] = 16'hFFFF;   // word 2
    rom[611] = 16'hFFFF;   // word 3
    rom[612] = 16'h0E0E;   // word 4
    rom[613] = 16'h0004;   // word 5
    rom[615] = 16'h4B00;   // word 7
    rom[616] = 16'hFF01;   // word 8
    rom[617] = 16'hFF02;   // word 9
    rom[621] = 16'h0002;   // word 13
    rom[623] = 16'hFFFF;   // word 15
    rom[624] = 16'hFF0F;   // word 16
    rom[625] = 16'hFF0F;   // word 17
    rom[628] = 16'h122A;   // word 20
    rom[630] = 16'h6571;   // word 22
    rom[631] = 16'h0729;   // word 23
    rom[632] = 16'hC202;   // word 24
    rom[633] = 16'hFF00;   // word 25
    rom[634] = 16'h8000;   // word 26
    rom[635] = 16'hC202;   // word 27
    // page 0x0E, default values
    rom[640] = 16'h0E0E;   // word 0
    rom[641] = 16'h0004;   // word 1
    rom[643] = 16'h4B00;   // word 3
    rom[644] = 16'hFF01;   // word 4
    rom[645] = 16'hFF02;   // word 5
    rom[649] = 16'h0002;   // word 9
    rom[651] = 16'hFFFF;   // word 11
    rom[652] = 16'hFF0F;   // word 12
    rom[653] = 16'hFF0F;   // word 13
    rom[656] = 16'h122A;   // word 16
    rom[658] = 16'h6571;   // word 18
    rom[659] = 16'h0729;   // word 19
    rom[660] = 16'hC202;   // word 20
    rom[661] = 16'hFF00;   // word 21
    rom[662] = 16'h8000;   // word 22
    rom[663] = 16'hC202;   // word 23
    rom[670] = 16'hC202;   // word 30
    rom[671] = 16'h0200;   // word 31
    // page 0x0E, changeable values
    rom[673] = 16'h0002;   // word 1
    rom[675] = 16'hFFFF;   // word 3
    rom[676] = 16'hFF0F;   // word 4
    rom[677] = 16'hFF0F;   // word 5
    rom[680] = 16'h122A;   // word 8
    rom[682] = 16'h6571;   // word 10
    rom[683] = 16'h0729;   // word 11
    rom[684] = 16'hC202;   // word 12
    rom[685] = 16'hFF00;   // word 13
    rom[686] = 16'h8000;   // word 14
    rom[687] = 16'hC202;   // word 15
    rom[694] = 16'hC202;   // word 22
    rom[695] = 16'h0200;   // word 23
    rom[697] = 16'hC202;   // word 25
    rom[700] = 16'h100F;   // word 28
    rom[702] = 16'h1811;   // word 30
    // page 0x2A, default values
    rom[704] = 16'h122A;   // word 0
    rom[706] = 16'h6571;   // word 2
    rom[707] = 16'h0729;   // word 3
    rom[708] = 16'hC202;   // word 4
    rom[709] = 16'hFF00;   // word 5
    rom[710] = 16'h8000;   // word 6
    rom[711] = 16'hC202;   // word 7
    rom[718] = 16'hC202;   // word 14
    rom[719] = 16'h0200;   // word 15
    rom[721] = 16'hC202;   // word 17
    rom[724] = 16'h100F;   // word 20
    rom[726] = 16'h1811;   // word 22
    rom[732] = 16'h100F;   // word 28
    // page 0x2A, changeable values
    rom[740] = 16'hC202;   // word 4
    rom[741] = 16'h0200;   // word 5
    rom[743] = 16'hC202;   // word 7
    rom[746] = 16'h100F;   // word 10
    rom[748] = 16'h1811;   // word 12
    rom[754] = 16'h100F;   // word 18
    // page 0x0F, default values
    rom[768] = 16'h100F;   // word 0
    rom[770] = 16'h1811;   // word 2
    rom[776] = 16'h100F;   // word 8
    // page 0x0F, changeable values
    rom[800] = 16'h100F;   // word 0
    // page 0x3F / other, default values
    rom[832] = 16'h0601;   // word 0
    rom[836] = 16'h060D;   // word 4
    rom[838] = 16'h3C00;   // word 6
    rom[839] = 16'h4B00;   // word 7
    rom[840] = 16'h0E0E;   // word 8
    rom[841] = 16'h0004;   // word 9
    rom[843] = 16'h4B00;   // word 11
    rom[844] = 16'hFF01;   // word 12
    rom[845] = 16'hFF02;   // word 13
    rom[848] = 16'h122A;   // word 16
    rom[850] = 16'h6571;   // word 18
    rom[851] = 16'h0729;   // word 19
    rom[852] = 16'hC202;   // word 20
    rom[853] = 16'hFF00;   // word 21
    rom[854] = 16'h8000;   // word 22
    rom[855] = 16'hC202;   // word 23
    rom[862] = 16'hC202;   // word 30
    rom[863] = 16'h0200;   // word 31
    // page 0x3F / other, changeable values
    rom[865] = 16'hFF37;   // word 1
    rom[869] = 16'h0F00;   // word 5
    rom[870] = 16'hFFFF;   // word 6
    rom[871] = 16'hFFFF;   // word 7
    rom[873] = 16'h0002;   // word 9
    rom[875] = 16'hFFFF;   // word 11
    rom[876] = 16'hFF0F;   // word 12
    rom[877] = 16'hFF0F;   // word 13
    rom[884] = 16'hC202;   // word 20
    rom[885] = 16'h0200;   // word 21
    rom[887] = 16'hC202;   // word 23
    rom[890] = 16'h100F;   // word 26
    rom[892] = 16'h1811;   // word 28
  end

  // The synthesised header of an ISO: one data track at LBA 0 and the lead-out at the capacity,
  // in the PCD header's layout (tools/cue2pcd.py) so READ TOC / READ SUB-CHANNEL read one form.
  // (Every value it reads is an ARGUMENT: Quartus 17 elaborated the module-scope lo_m/lo_s/lo_f
  // a function body read as "assigned a value but never read" (warning 10036) and dropped them.)
  function automatic [15:0] iso_word(input [9:0] a, input [19:0] cap, input [6:0] m,
                                     input [5:0] sec, input [6:0] fr,
                                     input [7:0] mb, input [7:0] sb, input [7:0] fb);
    case (a)
      10'd4:   iso_word = 16'h0101;                          // first track 1, 1 track
      10'd8:   iso_word = 16'h0014;                          // track 1: data, LBA 0
      10'd10:  iso_word = {cap[7:0], 8'h14};             // lead-out
      10'd11:  iso_word = {4'd0, cap[19:8]};
      10'd258: iso_word = {4'd0, cap[19:16], 8'h00};     // lead-out LBA, big-endian
      10'd259: iso_word = {cap[7:0], cap[15:8]};
      10'd513, 10'd769: iso_word = 16'h0002;                 // 00:02:00
      10'd514: iso_word = {1'b0, m, 8'h00};
      10'd515: iso_word = {1'b0, fr, 2'b00, sec};
      10'd770: iso_word = {mb, 8'h00};
      10'd771: iso_word = {fb, sb};
      default: iso_word = 16'h0000;
    endcase
  endfunction

  // ---- the header read port (builder and the SUB-CHANNEL scan) ----
  reg [9:0]  hdr_addr;          // combinational: the header word wanted this cycle
  reg [15:0] vh_q;              // the ISO's synthesised word, registered like the RAM read
  wire [15:0] hq = is_pcd ? buf_q : vh_q;
  always @(posedge clk) vh_q <= iso_word(hdr_addr, iso_cap, lo_m, lo_s, lo_f, lo_mb, lo_sb, lo_fb);

  // SUB-CHANNEL scan state (S_PREP)
  reg [2:0]  pp;                // prep phase
  reg [6:0]  sc_e, sc_r;        // entry being read, best entry
  reg [19:0] sc_rel;            // the best entry's distance to the position: sc_pos - its LBA (mod 2^20)
  // The position the report is built from, latched once per command. atapicmd.c readsubch:
  // `pos = drv->dacurpos; if ((daflag == 0x12) || (daflag == 0x13)) pos += (rand() & 7);` - a
  // paused or completed drive reports a position that wanders by up to 7 frames from poll to
  // poll. Policenauts depends on it: ITP.EXE's wait for the end of a CD-DA clip leaves only when
  // the Q channel's relative position goes BACKWARDS, so a position that stands still at 0x13
  // keeps it at the Konami logo for good (cdrom-REPORT sec.10.9). rand() is an 8-bit LFSR here,
  // stepped once per positioned report, as NP2kai calls rand() once per report.
  reg [19:0] sc_pos;
  reg [7:0]  sc_rnd = 8'h5A;
  reg [3:0]  sc_hi;            // byte 1 of the entry's big-endian LBA (bits 19:16)

  wire [20:0] sc_diff = {1'b0, sc_pos} - {1'b0, sc_hi, hq[7:0], hq[15:8]};

  // TOC word geometry
  wire [8:0] bt   = bi_a - 9'd2;
  wire [6:0] te_a = toc_e0 + 7'(bt[8:2]);
  always @* begin
    hdr_addr = 10'd0;
    if (st == S_BUILD) begin
      case (bt[1:0])
        2'd0: hdr_addr = 10'd8 + {2'd0, te_a, 1'b0};
        2'd2: hdr_addr = toc_base + {2'd0, te_a, 1'b0};
        2'd3: hdr_addr = toc_base + {2'd0, te_a, 1'b1};
        default: ;
      endcase
    end else if (st == S_PREP) begin
      case (pp)
        3'd0: hdr_addr = 10'd256 + {2'd0, sc_e, 1'b0};
        3'd1: hdr_addr = 10'd257 + {2'd0, sc_e, 1'b0};
        default: hdr_addr = 10'd8 + {2'd0, sc_r, 1'b0};
      endcase
    end
  end
  always @* begin
    if (st == S_BUILD || st == S_PREP) buf_raddr = {1'b1, hdr_addr};
    else                               buf_raddr = {1'b0, ptr};
  end

  // The ROM address for the builder's stage A (bi_a): the constant replies, and MODE SENSE's pages.
  wire [4:0] mq = bi_a[4:0] - 5'd4;   // the word within the pages (the low five bits are all the table spans)
  reg  [2:0] ms_pidx;
  always @* begin
    case (ms_page)
      6'h01:   ms_pidx = 3'd0;
      6'h0D:   ms_pidx = 3'd1;
      6'h0E:   ms_pidx = 3'd2;
      6'h2A:   ms_pidx = 3'd3;
      6'h0F:   ms_pidx = 3'd4;
      default: ms_pidx = 3'd5;
    endcase
  end
  reg  [9:0] rom_addr;
  always @* begin
    case (bk)
      K_IDENT: rom_addr = {1'b0, bi_a};
      K_INQ:   rom_addr = ROM_INQ + {1'b0, bi_a};
      default: rom_addr = {1'b1, ms_pidx, ms_chg, mq};   // K_MSENSE (the other kinds do not read the ROM)
    endcase
  end
  // No reset and no power-up value on the read register, or the ROM is refused (docs/fitting.md).
  reg [15:0] rom_q;
  always @(posedge clk) rom_q <= rom[rom_addr];

  // the builder's word at stage B
  wire [8:0] bt_b = bi_b - 9'd2;
  wire [6:0] te_b = toc_e0 + 7'(bt_b[8:2]);
  reg  [15:0] bword;
  always @* begin
    bword = 16'h0000;
    case (bk)
      K_IDENT, K_INQ: bword = rom_q;
      // REQUEST SENSE (atapicmd.c 0x03): fixed format, sense key, length 11, ASC/ASCQ.
      K_SENSE: case (bi_b[3:0])
                 4'd0: bword = 16'h0070;
                 4'd1: bword = {12'd0, sk_val(skc)};
                 4'd3: bword = 16'h0B00;
                 4'd6: bword = asc_val(ascc);
                 default: ;
               endcase
      // READ CAPACITY: NP2kai returns sxsi->totals (the sector COUNT, not the last LBA that
      // MMC defines) and 2048. The reference wins; the off-by-one is recorded in the report.
      K_CAP:   case (bi_b[1:0])
                 2'd0: bword = {4'd0, totals[19:16], 8'h00};
                 2'd1: bword = {totals[7:0], totals[15:8]};
                 2'd3: bword = 16'h0008;
                 default: ;
               endcase
      K_MSENSE: begin
        if (bi_b == 9'd0) bword = {ms_len[7:0], ms_len[15:8]};
        else if (bi_b == 9'd1)
          bword = {8'h00, !loaded ? 8'h70 :
                          (ctrl0 == 8'h10) ? 8'h02 : (tracks > 8'd1) ? 8'h03 : 8'h01};
        else if (bi_b >= 9'd4) bword = rom_q;
      end
      // READ SUB-CHANNEL (atapicmd.c 0x42): audio status, then the format-1 current position.
      K_SUBCH: case (bi_b[2:0])
                 3'd0: bword = {5'h02, daflag, 8'h00};
                 3'd1: bword = sub_full ? 16'h1200 : 16'h0000;
                 3'd2: bword = (daflag == DA_NONE) ? 16'h0001 : {sub_ctrl, 8'h01};
                 3'd3: bword = (daflag == DA_NONE) ? 16'h0000 : {8'h01, sub_point};
                 3'd4: bword = (daflag == DA_NONE) ? 16'h0000 : {ab_m, 8'h00};
                 3'd5: bword = (daflag == DA_NONE) ? 16'h0000 : {ab_f, ab_s};
                 3'd6: bword = (daflag == DA_NONE) ? 16'h0000 : {rl_m, 8'h00};
                 default: bword = (daflag == DA_NONE) ? 16'h0000 : {rl_f, rl_s};
               endcase
      // READ TOC format 0 (atapicmd.c 0x43): length, first = 1, last = the track count, then
      // one 8-byte descriptor per entry from the header: {0, ADR/CTRL, point, 0, address}.
      K_TOC0: begin
        if (bi_b == 9'd0)      bword = {toc_ds[7:0], toc_ds[15:8]};
        else if (bi_b == 9'd1) bword = {tracks, 8'h01};
        else case (bt_b[1:0])
          2'd0: bword = {hq[7:0], 8'h00};
          2'd1: bword = {8'h00, (te_b == tracks[6:0]) ? 8'hAA : (first_trk + 8'(te_b))};
          default: bword = hq;
        endcase
      end
      // READ TOC format 1 (multi-session): one session, track 1 data at LBA 0 / 00:02:00.
      K_TOC1: case (bi_b[2:0])
                3'd0: bword = 16'h0A00;
                3'd1: bword = 16'h0101;
                3'd2: bword = 16'h1400;
                3'd3: bword = 16'h0001;
                3'd5: bword = cdb[1][1] ? 16'h0002 : 16'h0000;
                default: ;
              endcase
      // GET CONFIGURATION (atapicmd.c 0x46): 512 zero bytes but [6] = 8 and [10] = 3.
      K_GETCFG: bword = (bi_b == 9'd3) ? 16'h0008 : (bi_b == 9'd5) ? 16'h0003 : 16'h0000;
      default: ;
    endcase
  end

  // ---- the guest's view ----
  wire data_in = (st == S_DATA) && status[3];
  always @* begin
    io_dout = 8'hFF;
    if (!sel && (io_addr == 16'h064E || io_addr == 16'h074C ||
                 io_addr == 16'h0640 || io_addr == 16'h0641)) io_dout = 8'h00;   // absent slave
    else case (io_addr)
      16'h0433: io_dout = 8'h02;
      16'h0640: io_dout = data_in ? buf_q[7:0]  : 8'h00;
      16'h0641: io_dout = data_in ? buf_q[15:8] : 8'h00;
      16'h0642: io_dout = error;
      16'h0644: io_dout = sc;
      16'h0646: io_dout = sn;
      16'h0648: io_dout = cy[7:0];
      16'h064A: io_dout = cy[15:8];
      16'h064C: io_dout = drhd;
      16'h064E, 16'h074C: io_dout = status;
      default: ;
    endcase
  end

  // ---- the mount edge (hps_io holds img_mounted for a whole transaction: its RISING edge is
  // the event, as pc9821_fdd_media reads its slots) ----
  reg mounted_d = 1'b0;
  wire mount_edge = img_mounted && !mounted_d;

  // ---- the command decode's CDB fields ----
  wire [31:0] cdb_lba  = {cdb[2], cdb[3], cdb[4], cdb[5]};
  wire [15:0] cdb_len78 = {cdb[7], cdb[8]};
  // (the BCD decode selects the BYTES, so each M:S:F is converted to frames once)
  wire [7:0] ms_a = damsfbcd ? unbcd(cdb[3]) : cdb[3];
  wire [7:0] ms_b = damsfbcd ? unbcd(cdb[4]) : cdb[4];
  wire [7:0] ms_c = damsfbcd ? unbcd(cdb[5]) : cdb[5];
  wire [7:0] me_a = damsfbcd ? unbcd(cdb[6]) : cdb[6];
  wire [7:0] me_b = damsfbcd ? unbcd(cdb[7]) : cdb[7];
  wire [7:0] me_c = damsfbcd ? unbcd(cdb[8]) : cdb[8];
  wire [19:0] msf_start = frames(ms_a, ms_b, ms_c);
  wire [19:0] msf_end   = frames(me_a, me_b, me_c);
  // PLAY AUDIO MSF's two clamps as one subtraction each, the borrow being the compare
  wire [20:0] msf_pos_d = {1'b0, msf_start} - 21'd150;     // borrow: start < 150
  wire [20:0] msf_len_d = {1'b0, msf_end} - {1'b0, msf_start};   // borrow: end < start
  // READ TOC's start track (atapicmd.c: 0 = 1, 0xAA = the lead-out)
  wire [7:0]  toc_st = (cdb[6] == 8'h00) ? 8'd1 : (cdb[6] == 8'hAA) ? tracks + 8'd1 : cdb[6];
  wire        toc_ok = (toc_st >= 8'd1) && (toc_st <= tracks + 8'd1);
  wire [7:0]  toc_ent = tracks - toc_st + 8'd2;       // entries including the lead-out
  wire [5:0]  pcode = cdb[2][5:0];
  wire [11:0] ms_cnt = (pcode == 6'h0F) ? 12'd24 : (pcode == 6'h01) ? 12'd16 :
                       (pcode == 6'h0D) ? 12'd16 : (pcode == 6'h0E) ? 12'd24 :
                       (pcode == 6'h2A) ? 12'd28 : 12'd60;
  wire        ms_known = (pcode == 6'h0F) || (pcode == 6'h01) || (pcode == 6'h0D) ||
                         (pcode == 6'h0E) || (pcode == 6'h2A) || (pcode == 6'h3F);

  // ONE clamp for every reply (senddata's MIN(size, limit)) instead of one per command arm.
  // b_full has 12 bits, so the clamp is a 12-bit compare plus 'alloc is above 12 bits'.
  wire [11:0] bxfer12 = (b_alloc[15:12] != 4'd0 || b_alloc[11:0] > b_full) ? b_full : b_alloc[11:0];
  wire [15:0] bxfer  = {4'd0, bxfer12};                // the data phase's byte count
  wire [8:0]  bn     = 9'((bxfer + 16'd1) >> 1);       // words to build
  wire [15:0] ms_len = bxfer - 16'd2;                  // MODE SENSE's length field
  wire [15:0] toc_ds = {4'd0, b_full} - 16'd2;                 // READ TOC's length field

  // ---- who may start what this cycle (one decision per resource) ----
  // The command executes once the engine holds no fetch that could still write the buffer:
  // a stale data sector of an abandoned READ, or a header that the builder might read.
  // It also waits out a mount edge's cycle (R7, deferred consumption): the mount owns the player
  // and the medium in that cycle (mount_stop, below), so a command decoded beside it would be
  // dropped or merged by luck; it executes one cycle later against the medium the mount left.
  // And it never executes under the core reset, which forces the command FSM idle.
  wire exec_go = (st == S_EXEC) && !abort_now && rst_n && !mount_edge &&
                 !((e_st != E_IDLE) && (e_kind != EK_AUDIO)) && !data_pend;
  // A READ(10) sector is in range of the medium (sxsi_read fails otherwise: ILLEGAL REQUEST,
  // ASC 0x21 - atapicmd.c atapi_dataread).
  function automatic in_range(input [31:0] lba, input [19:0] tot);
    in_range = (lba[31:20] == 12'd0) && (lba[19:0] < tot);
  endfunction
  // R3: the commands that rewrite the player POSITION (stop, seek, play, a reported medium
  // change) win over an audio completion's advance in the same cycle, and the ones that rewrite
  // the player FLAG (those plus PAUSE/RESUME, a mount and the core reset) win over the engine's
  // end-of-play write.
  wire tur_change = (cdb[0] == 8'h00) && loaded && changed;
  wire player_pos_cmd  = AUDIO_EN && exec_go && cmd == 8'hA0 &&
                         (tur_change || cdb[0] == 8'h1B || cdb[0] == 8'h2B ||
                          cdb[0] == 8'h45 || cdb[0] == 8'h47);
  // A MOUNT EVENT - an eject (size 0) or another image mounted over this one - takes the medium
  // away from a playing drive: NP2kai's mixer then finds the sxsi device not READY and stops
  // the play with 0x14 (ideio.c playdevaudio `drv->daflag = 0x14;`), leaving dacurpos where it
  // was. Nothing of the old disc may keep playing from the ring, and nothing of the new disc
  // may be fetched at the old play's position. A drive not playing keeps its state (NP2kai's
  // ideio_notify touches only the media flags); the TEST UNIT READY that reports the new medium
  // stops it (tur_change). tb_pc9821_atapi C24.
  wire mount_stop      = AUDIO_EN && mount_edge;
  // THE CORE RESET stops the player (NP2kai ideio_reset, above): daflag 0x15, positions 0.
  // Held for the whole reset, as the ring's flush is (cdda.v: every CDDA_FLUSH cycle empties
  // the ring, so a held flush is the same as one). tb_pc9821_atapi C25.
  wire reset_stop      = AUDIO_EN && !rst_n;
  wire player_flag_cmd = player_pos_cmd || mount_stop || reset_stop ||
                         (AUDIO_EN && exec_go && cmd == 8'hA0 && cdb[0] == 8'h4B);
  // The superseded audio fetch (da_stale, above): from the position command's own cycle its
  // samples are dropped, and its completion advances nothing.
  // A PAUSE of a playing drive is a flush too: the ring's read-ahead is dropped and the fetch
  // side rewinds to the start of the sector the speakers were on, which RESUME refetches.
  wire pause_now       = AUDIO_EN && exec_go && cmd == 8'hA0 && cdb[0] == 8'h4B &&
                         !cdb[8][0] && daflag == DA_PLAY;
  assign cdda_flush    = player_pos_cmd || pause_now || mount_stop || reset_stop;
  // NP2kai's reported position's lead over the sector being heard (da_lead, above): the
  // sector at daplaypos is loaded while it is in the ring.
  wire da_lead_now     = (daflag == DA_PLAY) ? (dacurpos != daplaypos)
                       : ((daflag == DA_PAUSE || daflag == DA_ERR) && da_lead);
  wire audio_stale_now = da_stale || (cdda_flush && audio_in_flight);
  wire audio_adv       = e_done && (e_kind == EK_AUDIO) && !da_stale;
  wire [19:0] play_next = daplaypos + {19'd0, cdda_played};
  // four sectors in one host request when the ring has room for them and the play has them
  wire        fetch4    = cdda_req4 && dalength >= 20'd4 && (dacurpos + 20'd4) <= totals;
  // The MSF converter's three starts (READ SUB-CHANNEL's two, the ISO mount's one) - at most one
  // per cycle, and only from an idle or just-finishing converter.
  wire cv_start_abs = (st == S_PREP) && (pp == 3'd4) && !cv_busy;
  wire cv_start_rel = (st == S_PREP) && (pp == 3'd5) && cv_done && !cv_owner_mount;
  wire cv_start_iso = iso_msf_pend && !cv_busy && !cv_start_abs;
  wire hdr_done = e_done && (e_kind == EK_HDR);
  wire toc_success = loaded && ((cdb[9][7:6] == 2'd0 && toc_ok) || cdb[9][7:6] == 2'd1);
  // A reset of the drive this cycle (DEVICE RESET, EXECUTE DEVICE DIAGNOSTIC, an SRST edge)
  // OWNS the command FSM: the internal progress arms (exec, builder, prep, fetch completion)
  // stand down, so the reset's state is the one written (R2). A stale EK_DATA completion that
  // coincides is consumed by the reset - its sector belongs to the command being reset.
  wire abort_now = io_wr && bank1 &&
                   ((io_addr == 16'h064E && (io_din == 8'h90 || (mine && io_din == 8'h08))) ||
                    (io_addr == 16'h074C && io_din[2] != srst));

  // The completion forms of atapicmd.c (senddata / cmddone / senderror / sendabort) and
  // ideio.c's cmdabort, as tasks of the one always block below.
  task automatic t_cmddone;
    begin
      sc <= INTR_IO | INTR_CD;
      status <= (status & ~(ST_BSY | ST_DRQ | ST_DSC | ST_ERR)) | ST_DRDY | ST_DSC;
      error <= 8'h00; skc <= SKC_NONE; ascc <= ASCC_NONE;
      st <= S_IDLE;
      if (!nien) irq_pend <= 1'b1;
    end
  endtask
  task automatic t_senderror(input [3:0] key, input [15:0] code, input set);
    begin
      sc <= INTR_IO | INTR_CD;
      status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_DRQ)) | ST_ERR | ST_DSC;
      if (set) begin error <= {key, error[3:0]}; skc <= sk_enc(key); ascc <= asc_enc(code); end
      st <= S_IDLE;
      if (!nien) irq_pend <= 1'b1;
    end
  endtask
  task automatic t_sendabort;
    begin
      skc <= SKC_ABORTED; error <= ERR_ABRT;
      sc <= INTR_IO | INTR_CD;
      status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_DRQ)) | ST_ERR | ST_DSC;
      st <= S_IDLE;
      if (!nien) irq_pend <= 1'b1;
    end
  endtask
  task automatic t_ata_abort;   // ideio.c cmdabort
    begin
      status <= ST_DRDY | ST_ERR; error <= ERR_ABRT;
      st <= S_IDLE;
      if (!nien) irq_pend <= 1'b1;
    end
  endtask
  task automatic t_signature;   // ideio.c drvreset, IDETYPE_CDROM: 0x01/0x01/0x14/0xEB
    begin
      drhd[3:0] <= 4'd0; sc <= 8'h01; sn <= 8'h01; cy <= 16'hEB14;
    end
  endtask
  task automatic t_build(input [3:0] kind, input [11:0] full, input [15:0] alloc);
    begin
      bk <= kind; b_full <= full; b_alloc <= alloc;
      bi_a <= 9'd0; bv_b <= 1'b0;
      st <= S_BUILD;
    end
  endtask

  // ================= the guest side: task file, packet, command FSM =================
  // Single-cycle events consumed here: the guest's port strobes; `e_done` of an EK_DATA fetch
  // (its one consumer is S_FETCH); `cv_done` while S_PREP owns the converter. Every state
  // transition is written in exactly one arm per cycle (the arms are exclusive on `st`).
  always @(posedge clk) begin
    if (!rst_n) begin
      bank1 <= 1'b0; dev1 <= 1'b0;
      // Power-on / reset: the signature with STATUS 0x00 (ideio.c drvreset), and ERROR = 0x01,
      // the passed power-on diagnostic every ATA/ATAPI device reports. NP2kai's devinit clears
      // ERROR for a CD, but the machine's own IDE ROM requires 0x01 before it treats a probed
      // unit as present: its pre-reset presence test reads STATUS, then the ATAPI signature
      // (0x64A = 0xEB, 0x648 = 0x14, which marks the unit ATAPI), then 0x642 and accepts only
      // 0x01 for a master (Xe10 IDE ROM BANK3@0x0D39-0x0DA6) - the real machine's software
      // outranks NP2kai, and with 0x00 the ROM drops the CD before identifying it.
      status <= 8'h00; error <= ERR_AMNF;
      sc <= 8'h01; sn <= 8'h01; cy <= 16'hEB14; drhd <= 8'h00;
      nien <= 1'b0; srst <= 1'b0; skc <= SKC_NONE; ascc <= ASCC_NONE;
      irq_pend <= 1'b0;
      st <= S_IDLE; cmd <= 8'h00; pkt_words <= 3'd0; data_lo <= 8'h00;
      ptr <= 10'd0; dp_words <= 11'd0; dp_read <= 1'b0; rd_lba <= 20'd0; rd_left <= 16'd0;
      bk <= K_IDENT; bi_a <= 9'd0; bi_b <= 9'd0; bv_b <= 1'b0; b_full <= 12'd0; b_alloc <= 16'd0;
      toc_e0 <= 7'd0; toc_base <= 10'd256; ms_page <= 6'h00; ms_chg <= 1'b0;
      sub_full <= 1'b0; sub_ctrl <= 8'h00; sub_point <= 8'h00;
      ab_m <= 8'd0; ab_s <= 8'd0; ab_f <= 8'd0; rl_m <= 8'd0; rl_s <= 8'd0; rl_f <= 8'd0;
      damsfbcd <= 1'b0;
      pp <= 3'd0; sc_e <= 7'd0; sc_r <= 7'd0; sc_rel <= 20'd0; sc_hi <= 4'h0;
      buf_we <= 1'b0; buf_waddr <= 11'd0; buf_wdata <= 16'd0;
      for (int i = 0; i < 12; i++) cdb[i] <= 8'h00;
    end else begin
      buf_we <= 1'b0;

      // ---------------- writes ----------------
      if (io_wr) begin
        case (io_addr)
          16'h0432: if (!io_din[7]) bank1 <= io_din[0];
          16'h064C: if (bank1) begin
                      dev1 <= io_din[4];
                      drhd <= io_din;
                    end
          16'h074C: if (bank1) begin
                      nien <= io_din[1];
                      srst <= io_din[2];
                      // ideio_o74c: SRST set clears status and error of both drives; its release
                      // re-establishes the signature with DRDY|DSC|ERR and ERROR = AMNF.
                      if (io_din[2] && !srst) begin
                        status <= 8'h00; error <= 8'h00; st <= S_IDLE;
                      end else if (!io_din[2] && srst) begin
                        t_signature;
                        status <= ST_DRDY | ST_DSC | ST_ERR; error <= ERR_AMNF; st <= S_IDLE;
                      end
                    end
          default: ;
        endcase
        if (sel) case (io_addr)
          16'h0644: sc <= io_din;
          16'h0646: sn <= io_din;
          16'h0648: cy[7:0] <= io_din;
          16'h064A: cy[15:8] <= io_din;
          16'h0640: data_lo <= io_din;
          16'h0641: if (st == S_PKT && status[3]) begin
                      // ideio_w16: the 12-byte packet, one word per 0x0641 write
                      cdb[{pkt_words, 1'b0}]        <= data_lo;
                      cdb[{pkt_words, 1'b0} + 4'd1] <= io_din;
                      pkt_words <= pkt_words + 3'd1;
                      if (pkt_words == 3'd5) begin
                        status <= (status & ~ST_DRQ) | ST_BSY;
                        st <= S_EXEC;
                      end
                    end
          default: ;
        endcase
        // ---- ATA commands (ideio_o64e). 0x90 reaches both drives of the bank. ----
        if (io_addr == 16'h064E && bank1 && (mine || io_din == 8'h90)) begin
          case (io_din)
            8'h90: begin   // EXECUTE DEVICE DIAGNOSTIC: drvreset, ERROR 0x01, no interrupt
              t_signature; status <= 8'h00; error <= ERR_AMNF; st <= S_IDLE;
            end
            8'h08: begin   // DEVICE RESET: drvreset (status 0), ERROR 0x01, interrupt
              t_signature; status <= 8'h00; error <= ERR_AMNF; st <= S_IDLE;
              if (!nien) irq_pend <= 1'b1;
            end
            default: if (st == S_IDLE || st == S_PKT || st == S_DATA) case (io_din)
              8'hA0: begin   // PACKET: DRDY|DRQ|DSC, interrupt reason CoD, no interrupt
                sc <= (sc & ~8'h06) | INTR_CD;
                status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_ERR)) |
                          ST_DRDY | ST_DRQ | ST_DSC;
                error <= 8'h00; pkt_words <= 3'd0; cmd <= 8'hA0; st <= S_PKT;
              end
              8'hA1: begin   // IDENTIFY PACKET DEVICE (built in S_EXEC, like a packet reply)
                status <= ST_DRDY | ST_DSC | ST_BSY; error <= 8'h00; cmd <= 8'hA1;
                st <= S_EXEC;
              end
              8'hEC: begin t_signature; t_ata_abort; end   // drvreset + cmdabort
              8'h40, 8'h41: begin status <= status & ~ST_BSY; if (!nien) irq_pend <= 1'b1; end
              8'hE0: if (!nien) irq_pend <= 1'b1;
              8'hE1: if (status[6]) begin
                       status <= ST_DRDY | ST_DSC; error <= 8'h00; if (!nien) irq_pend <= 1'b1;
                     end else t_ata_abort;
              8'hE5: begin sc <= 8'hFF; status <= status & ~ST_BSY; if (!nien) irq_pend <= 1'b1; end
              8'hE7: begin status <= ST_DRDY; error <= 8'h00; if (!nien) irq_pend <= 1'b1; end
              8'hDE, 8'hDF: begin
                status <= (status | ST_DRDY) & ~(ST_BSY | ST_DMRD | ST_DRQ | ST_ERR);
                if (!nien) irq_pend <= 1'b1;
              end
              8'hF8: begin
                sn <= totals[7:0]; cy <= {4'd0, totals[19:8]}; drhd[3:0] <= 4'd0;
                if (!nien) irq_pend <= 1'b1;
              end
              8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17,
              8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F,
              8'h20, 8'h21, 8'h30, 8'h31, 8'h91, 8'hB0, 8'hC4, 8'hC5, 8'hC6, 8'hDA,
              8'hEF: t_ata_abort;
              default: ;   // NOP (0x00) and the opcodes ideio.c only traces
            endcase
          endcase
        end
      end

      // ---------------- reads ----------------
      if (io_rd && sel) begin
        // ideio_i64e: a status read lowers the interrupt (when nIEN is clear)
        if (io_addr == 16'h064E && !nien) irq_pend <= 1'b0;
        // An ERROR read does NOT clear STATUS.ERR (CHK) here. NP2kai's ideio_i642 clears it, but
        // the machine's own IDE ROM rules that out for this drive: its interrupt handler reads
        // ERROR and THEN STATUS (Xe10 IDE ROM BANK3@0x1A1C-0x1A27) and its IDENTIFY DEVICE
        // handler classifies the command by that STATUS's ERR (BANK3@0x1514/0x1533). With the
        // clear, the ROM saw the ATAPI unit's aborted IDENTIFY as a success and registered the
        // CD as a hard disk (userdisk). The real
        // machine's software outranks NP2kai; ERR stays until the next command, as ATA defines.
      end
      // ideio_r16: the data port advances one word per 0x0641 read; the phase's end follows the
      // command (an IDENTIFY just drops DRQ; a packet reply completes; READ(10) fetches on).
      if (io_rd && sel && io_addr == 16'h0641 && data_in) begin
        if ({1'b0, ptr} + 11'd1 < dp_words) ptr <= ptr + 10'd1;
        else begin
          ptr <= 10'd0;
          if (cmd != 8'hA0) begin
            status <= status & ~ST_DRQ; st <= S_IDLE;
          end else if (!dp_read || rd_left == 16'd0) t_cmddone;
          else if (!(rd_lba < totals)) t_senderror(SK_ILLEGAL, ASC_LBA_OUT_OF_RANGE, 1'b1);
          else begin
            status <= (status & ~ST_DRQ) | ST_BSY;   // the next sector's fetch
            st <= S_FETCH;
          end
        end
      end

      // ---------------- builder ----------------
      if (st == S_BUILD && !abort_now) begin
        bi_a <= bi_a + 9'd1;
        bi_b <= bi_a; bv_b <= (bi_a < bn);
        if (bv_b) begin
          buf_we <= 1'b1; buf_waddr <= {2'b00, bi_b}; buf_wdata <= bword;
        end
        if (bi_a == bn) begin   // the last word's write is the one issued this cycle
          // senddata: interrupt reason IO, the byte count, DRQ|DSC, the sense cleared.
          // (An IDENTIFY PACKET's page goes out with DRDY|DSC|DRQ and touches neither.)
          if (cmd == 8'hA0) begin
            sc <= INTR_IO; cy <= bxfer; skc <= SKC_NONE; ascc <= ASCC_NONE;
          end
          status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_ERR)) | ST_DRQ | ST_DSC;
          error <= 8'h00;
          ptr <= 10'd0; dp_words <= {2'd0, bn}; dp_read <= 1'b0;
          st <= S_DATA;
          if (!nien) irq_pend <= 1'b1;
        end
      end

      // ---------------- the command (ideio 0xA1, atapicmd_a0) ----------------
      if (exec_go) begin
        if (cmd == 8'hA1) t_build(K_IDENT, 12'd512, 16'd512);
        else case (cdb[0])
          8'h00: begin   // TEST UNIT READY
            if (!loaded) t_senderror(SK_NOT_READY, ASC_NO_MEDIUM, 1'b1);
            else if (changed) begin
              // The first TUR after a change: NOT READY with ASC 0x28 in NEC mode (NECCDD) or
              // 0x3A otherwise (atapicmd.c - NP2kai, not MMC's UNIT ATTENTION 6/28), and the
              // player stops.
              t_senderror(SK_NOT_READY, damsfbcd ? ASC_NOT_READY_TO_READY : ASC_NO_MEDIUM, 1'b1);
            end else t_cmddone;
          end
          8'h03: t_build(K_SENSE, 12'd18, {8'd0, cdb[4]});
          8'h12: t_build(K_INQ, 12'd36, {8'd0, cdb[4]});
          8'h1B: begin   // START/STOP UNIT (stops the player; no tray to move)
            if (cdb[4][7:4] != 4'd0 || cdb[4][1]) t_senderror(SK_ILLEGAL, ASC_INVALID_FIELD, 1'b1);
            else if (!loaded) begin
              if (cdb[4][0]) t_senderror(4'd0, 16'd0, 1'b0);   // its READ TOC path's error
              else t_senderror(SK_NOT_READY, ASC_NO_MEDIUM, 1'b1);
            end else t_cmddone;
          end
          8'h1E: t_cmddone;   // PREVENT/ALLOW MEDIUM REMOVAL
          8'h25: t_build(K_CAP, 12'd8, 16'd8);
          8'h28: begin   // READ(10)
            rd_lba <= cdb_lba[19:0]; rd_left <= cdb_len78;
            if (cdb_len78 == 16'd0) t_sendabort;
            else if (!in_range(cdb_lba, totals))
              t_senderror(SK_ILLEGAL, ASC_LBA_OUT_OF_RANGE, 1'b1);
            else st <= S_FETCH;
          end
          8'h2B: t_cmddone;   // SEEK (the player side is below)
          8'h55: begin   // MODE SELECT: accepted without its parameter list (NP2kai workaround)
            if (cdb[1][0]) t_senderror(SK_ILLEGAL, ASC_INVALID_FIELD, 1'b1);
            else t_cmddone;
          end
          8'h5A: begin   // MODE SENSE(10)
            if (cdb_len78 >= 16'd8 && !ms_known) t_senderror(SK_ILLEGAL, ASC_INVALID_FIELD, 1'b1);
            else begin
              ms_page <= pcode;
              ms_chg <= cdb[2][6];
              // NEC page 0x0F switches the drive to BCD MSF (atapicmd.c damsfbcd)
              if (pcode == 6'h0F && cdb_len78 >= 16'd24) damsfbcd <= 1'b1;
              t_build(K_MSENSE, ms_cnt, cdb_len78);
            end
          end
          8'h42: begin   // READ SUB-CHANNEL
            sub_full <= cdb[2][6];
            if (!loaded) t_senderror(4'd0, 16'd0, 1'b0);
            else if (!cdb[2][6]) t_build(K_SUBCH, 12'd4, cdb_len78);
            else if (cdb[3] != 8'h01) t_senderror(4'd0, 16'd0, 1'b0);
            else if (!AUDIO_EN || daflag == DA_NONE) t_build(K_SUBCH, 12'd16, cdb_len78);
            else begin
              pp <= 3'd0; sc_e <= 7'd0; sc_r <= 7'd0; sc_rel <= 20'd0; st <= S_PREP;
              sc_pos <= daplaypos + {19'd0, da_lead_now} +
                        ((daflag == DA_PAUSE || daflag == DA_DONE) ? {17'd0, sc_rnd[2:0]} : 20'd0);
              sc_rnd <= {sc_rnd[6:0], 1'b0} ^ (sc_rnd[7] ? 8'h1D : 8'h00);
            end
          end
          8'h43: begin   // READ TOC
            toc_base <= !cdb[1][1] ? 10'd256 : damsfbcd ? 10'd768 : 10'd512;
            if (!loaded) t_senderror(4'd0, 16'd0, 1'b0);
            else if (cdb[9][7:6] == 2'd0) begin
              if (!toc_ok) t_senderror(4'd0, 16'd0, 1'b0);
              else begin
                toc_e0 <= 7'(toc_st - 8'd1);
                t_build(K_TOC0, {1'b0, toc_ent, 3'd0} + 12'd4, cdb_len78);
              end
            end else if (cdb[9][7:6] == 2'd1) t_build(K_TOC1, 12'd12, cdb_len78);
            else t_senderror(4'd0, 16'd0, 1'b0);
          end
          8'h46: t_build(K_GETCFG, 12'd512,   // NP2kai reads the length byte-swapped
                         ({cdb[8], cdb[7]} == 16'd0) ? 16'd12 : {cdb[8], cdb[7]});
          8'h45, 8'h47, 8'h4B: if (AUDIO_EN) t_cmddone; else t_sendabort;   // player: below
          default: t_sendabort;   // incl. 0x4E STOP PLAY/SCAN, 0xBE READ CD, 0xBD: NP2kai aborts
        endcase
      end

      // ---------------- READ SUB-CHANNEL's prep: find the track, convert the MSFs ----------
      if (st == S_PREP && !abort_now) begin
        case (pp)
          3'd0: pp <= 3'd1;                              // 256+2e presented
          3'd1: begin sc_hi <= hq[11:8]; pp <= 3'd2; end // BE LBA byte 1; 257+2e presented
          3'd2: begin
            // entry sc_e's LBA, from its big-endian field: {byte1, byte2, byte3}. The last entry
            // that starts at or before the position wins (entry 0 always starts the scan): the
            // subtraction's borrow IS the compare, and its difference IS the relative position.
            if (!sc_diff[20] || sc_e == 7'd0) begin
              sc_r <= sc_e; sc_rel <= sc_diff[19:0];
            end
            if (sc_e + 7'd1 >= tracks[6:0]) pp <= 3'd3;
            else begin sc_e <= sc_e + 7'd1; pp <= 3'd0; end
          end
          3'd3: pp <= 3'd4;                              // 8+2r presented
          3'd4: begin
            sub_ctrl <= hq[7:0]; sub_point <= first_trk + {1'b0, sc_r};
            if (cv_start_abs) pp <= 3'd5;
          end
          3'd5: if (cv_start_rel) begin
            ab_m <= cv_mf; ab_s <= cv_sf; ab_f <= cv_ff; pp <= 3'd6;
          end
          3'd6: if (cv_done && !cv_owner_mount) begin
            rl_m <= cv_mf; rl_s <= cv_sf; rl_f <= cv_ff;
            t_build(K_SUBCH, 12'd16, cdb_len78);
          end
          default: ;
        endcase
      end

      // ---------------- READ(10): one 2048-byte sector per data phase ----------------
      if (st == S_FETCH && e_done && e_kind == EK_DATA && !abort_now) begin
        // atapi_dataread: interrupt reason IO, 2048 bytes, DRQ, interrupt
        rd_lba <= rd_lba + 20'd1; rd_left <= rd_left - 16'd1;
        sc <= INTR_IO; cy <= 16'd2048;
        status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_ERR)) | ST_DRQ;
        error <= 8'h00; skc <= SKC_NONE; ascc <= ASCC_NONE;
        ptr <= 10'd0; dp_words <= 11'd1024; dp_read <= 1'b1;
        st <= S_DATA;
        if (!nien) irq_pend <= 1'b1;
      end

    end

    // ---------------- the engine's buffer writes ----------------
    // OUTSIDE the reset: the engine and the medium are the slot's, not the guest's (they are not
    // reset), and on the MiSTer the MGL mounts the CD (delay="1") while the core is still held in
    // reset loading its pack. Inside the reset branch the mount's header words were dropped, so
    // the medium came up loaded with an EMPTY header and every READ TOC answered from it: NECCD.SYS
    // re-validated the disc forever and DOS reported "CDR101: Not ready" (28bbd257 hardware log;
    // tb_pc9821_atapi C12). Last in the block, as before, so it still wins over a builder write.
    if (e_word && e_kind != EK_AUDIO) begin
      buf_we <= 1'b1;
      buf_waddr <= {(e_kind == EK_HDR), e_rel[9:0]};
      buf_wdata <= sd_buff_dout;
    end
  end

  // ================= the medium, the player, the engine and the converter =================
  // Not reset (see the declarations), except the player, which the core reset stops
  // (reset_stop). Events consumed here: `mount_edge`; `e_done` of an EK_HDR or EK_AUDIO fetch;
  // `cv_done` of the mount's conversion; the command decode's player commands (exec_go), which
  // own the player registers in their cycle (R3, above).
  always @(posedge clk) begin
    cdda_wr <= 1'b0;
    mounted_d <= img_mounted;

    // ---- the MSF converter: one start per cycle, else step / finish ----
    if (cv_start_abs || cv_start_rel || cv_start_iso) begin
      cv_busy <= 1'b1; cv_ph <= 1'b0; cv_m <= 7'd0; cv_s <= 6'd0;
      cv_owner_mount <= cv_start_iso;
      cv_x <= cv_start_rel ? sc_rel : (cv_start_iso ? iso_cap : sc_pos) + 20'd150;
      if (cv_start_iso) iso_msf_pend <= 1'b0;
    end else if (cv_done) begin cv_busy <= 1'b0; cv_owner_mount <= 1'b0; end
    else if (cv_busy) begin
      if (!cv_ph && !cv_step_ge) cv_ph <= 1'b1;   // the M step is done; the F step starts next cycle
      else begin
        cv_x <= cv_x - cv_step;                   // 4500 in phase 0, 75 in phase 1
        if (cv_ph) cv_s <= cv_s + 6'd1;
        else       cv_m <= cv_m + 7'd1;
      end
    end

    // ---- the medium ----
    if (mount_edge) begin
      loaded <= 1'b0; changed <= 1'b0; iso_msf_pend <= 1'b0;
      hdr_pend <= (img_size >= 64'd2048);
      mounting <= (img_size >= 64'd2048);
      iso_cap <= (|img_size[63:31]) ? 20'hFFFFF : img_size[30:11];
    end else if (hdr_done && !hdr_pend) begin
      // the header words are in place and no newer mount is waiting; the type is the magic's
      if (is_pcd) begin loaded <= 1'b1; changed <= 1'b1; mounting <= 1'b0; end
      else iso_msf_pend <= 1'b1;
    end else if (mounting && cv_done && cv_owner_mount && !hdr_pend &&
                 !(e_st != E_IDLE && e_kind == EK_HDR)) begin
      lo_m <= cv_m; lo_s <= cv_s; lo_f <= cv_x[6:0];
      lo_mb <= cv_mb; lo_sb <= cv_sb; lo_fb <= cv_fb;
      tracks <= 8'd1; first_trk <= 8'd1; ctrl0 <= 8'h14;
      loaded <= 1'b1; changed <= 1'b1; mounting <= 1'b0;
    end else if (exec_go && cmd == 8'hA0 &&
                 ((cdb[0] == 8'h00 && loaded) || (cdb[0] == 8'h43 && toc_success))) begin
      // a TEST UNIT READY reports the change once; READ TOC also clears it (atapicmd.c)
      changed <= 1'b0;
    end

    // ---- the player (atapicmd.c playaudio / stop_daplay / pauseresume / seek) ----
    // One arm per cycle, in this stated priority (R1): the reset, a mount, a position command,
    // PAUSE/RESUME, the play's own progress. exec_go is false in a reset or mount-edge cycle, so
    // the first two never meet a command; a completion or played pulse beside a reset or a
    // mount is discarded with the play (the flush in the same cycle empties the ring).
    if (AUDIO_EN) begin
      if (reset_stop) begin
        // ideio_reset: `ZeroMemory(&ideio, ...)` stops the play, devinit sets daflag 0x15
        daflag <= DA_NONE; dacurpos <= 20'd0; dalength <= 20'd0; daplaypos <= 20'd0;
        da_lead <= 1'b0;
      end else if (mount_stop) begin
        if (daflag == DA_PLAY) begin
          // stopped where the speakers were (the PAUSE's re-base, below), the flag 0x14
          daflag    <= DA_ERR;
          dacurpos  <= play_next;
          daplaypos <= play_next;
          dalength  <= dacurpos + dalength - play_next;
          da_lead   <= (dacurpos != play_next);
        end
      end else if (player_pos_cmd) begin
        da_lead <= 1'b0;
        if (tur_change || cdb[0] == 8'h1B) begin
          daflag <= DA_DONE; dacurpos <= 20'd0; dalength <= 20'd0; daplaypos <= 20'd0;
        end else if (cdb[0] == 8'h2B) begin
          daflag <= DA_DONE; dalength <= 20'd0;
          dacurpos  <= in_range(cdb_lba, totals) ? cdb_lba[19:0] : 20'd0;
          daplaypos <= in_range(cdb_lba, totals) ? cdb_lba[19:0] : 20'd0;
        end else if (cdb[0] == 8'h45) begin
          // NP2kai reads the length as (cdb[7] << 16) | cdb[8], a typo for MMC's (cdb[7] << 8)
          // | cdb[8]; no driver on the tested disk images issues 0x45, so
          // MMC's field is used (a recorded divergence from NP2kai).
          daflag <= DA_PLAY; dacurpos <= cdb_lba[19:0]; dalength <= {4'd0, cdb_len78};
          daplaypos <= cdb_lba[19:0];
        end else begin   // 0x47 PLAY AUDIO MSF
          daflag <= DA_PLAY;
          dacurpos  <= msf_pos_d[20] ? 20'd0 : msf_pos_d[19:0];
          daplaypos <= msf_pos_d[20] ? 20'd0 : msf_pos_d[19:0];
          dalength <= msf_len_d[20] ? 20'd0 : msf_len_d[19:0];
        end
      end else if (player_flag_cmd) begin   // 0x4B
        if (cdb[8][0]) begin if (daflag == DA_PAUSE) daflag <= DA_PLAY; end
        else if (daflag == DA_PLAY) daflag <= DA_PAUSE;
        if (pause_now) begin
          // the read-ahead is flushed (cdda_flush): the fetch side rewinds to the sector the
          // speakers are on, a sector played in this same cycle included; the play's end is kept.
          // da_lead keeps whether that sector had been fetched (NP2kai's dabuf held it).
          dacurpos  <= play_next;
          daplaypos <= play_next;
          dalength  <= dacurpos + dalength - play_next;
          da_lead   <= (dacurpos != play_next);
        end else begin
          // a RESUME (or a PAUSE of a drive not playing) leaves the positions alone, so a sector
          // completing or played in this same cycle still lands (R4: both events land)
          if (audio_adv) begin
            dacurpos <= dacurpos + {17'd0, e_nsec}; dalength <= dalength - {17'd0, e_nsec};
          end
          daplaypos <= play_next;
        end
      end else begin
        if (audio_adv) begin
          dacurpos <= dacurpos + {17'd0, e_nsec}; dalength <= dalength - {17'd0, e_nsec};
        end
        daplaypos <= play_next;
        // the end of play: the length is spent or the lead-out is reached AND the speakers have
        // played every fetched sector; or there is no PCD
        if (e_st == E_IDLE && daflag == DA_PLAY &&
            (((dalength == 20'd0 || dacurpos >= totals) && daplaypos >= dacurpos) || !is_pcd))
          daflag <= DA_DONE;
      end
    end

    // da_stale: set by a position command against an in-flight audio fetch (that fetch then
    // ends without effect), cleared when the fetch ends. One next-state (R4).
    if (AUDIO_EN)
      da_stale <= (cdda_flush && audio_in_flight && !e_done) ||
                  (da_stale && !(e_done && e_kind == EK_AUDIO));

    // ---- the engine: header (mount) > data (READ) > audio ----
    case (e_st)
      E_IDLE: begin
        if (hdr_pend && !mount_edge && st != S_EXEC && st != S_BUILD && st != S_PREP) begin
          hdr_pend <= 1'b0; e_kind <= EK_HDR; e_st <= E_CALC; is_pcd <= 1'b0;
        end else if (e_take_data) begin
          e_kind <= EK_DATA; e_pos <= rd_lba; e_st <= E_CALC;
        end else if (AUDIO_EN && daflag == DA_PLAY && !hdr_pend && !data_pend &&
                     !player_flag_cmd && cdda_req && dalength != 20'd0 &&
                     dacurpos < totals && is_pcd) begin
          e_kind <= EK_AUDIO; e_pos <= dacurpos; e_st <= E_CALC;
          e_nsec <= fetch4 ? 3'd4 : 3'd1;
        end
      end
      E_CALC: begin
        // The byte offset of the wanted bytes: an ISO sector at L*2048; a PCD sector at
        // (L+1)*2352 (after the header sector), its MODE1 user data 16 bytes in.
        e_st <= E_WAIT; sd_rd <= 1'b1; e_odd <= 1'b0;
        if (e_kind == EK_HDR) begin
          sd_lba <= 32'd0; sd_blk_cnt <= 6'd3; e_w0 <= 9'd0; e_n <= 13'd1024;
        end else begin
          sd_lba <= {9'd0, e_off[31:9]};
          sd_blk_cnt <= (e_kind != EK_AUDIO) ? 6'(({5'd0, e_off[8:0]} + 14'd2047) >> 9)
                      : (e_nsec == 3'd4)     ? 6'(({5'd0, e_off[8:0]} + 14'd9407) >> 9)
                                             : 6'(({5'd0, e_off[8:0]} + 14'd2351) >> 9);
          e_w0 <= {1'b0, e_off[8:1]};
          e_n <= (e_kind != EK_AUDIO) ? 13'd1024 : (e_nsec == 3'd4) ? 13'd4704 : 13'd1176;
        end
      end
      E_WAIT: if (sd_ack) begin sd_rd <= 1'b0; e_st <= E_STREAM; end
      default: if (!sd_ack) e_st <= E_IDLE;   // E_STREAM: the host dropped ack - done
    endcase
    // data_pend is the request flag between the command and the engine: set by the command
    // side's entry to S_FETCH, cleared by the engine's take (one owner each way).
    if (fetch_req) data_pend <= 1'b1;
    else if (e_take_data) data_pend <= 1'b0;

    if (e_word) begin
      if (e_kind == EK_HDR) begin
        // the PCD magic "PC98CD01" and the counts, captured as they stream past
        case (e_rel[9:0])
          10'd0: is_pcd <= (sd_buff_dout == 16'h4350);
          10'd1: is_pcd <= is_pcd && (sd_buff_dout == 16'h3839);
          10'd2: is_pcd <= is_pcd && (sd_buff_dout == 16'h4443);
          10'd3: is_pcd <= is_pcd && (sd_buff_dout == 16'h3130);
          10'd4: if (is_pcd) begin tracks <= sd_buff_dout[7:0]; first_trk <= sd_buff_dout[15:8]; end
          10'd6: if (is_pcd) leadout[15:0] <= sd_buff_dout;
          10'd7: if (is_pcd) leadout[19:16] <= sd_buff_dout[3:0];
          10'd8: if (is_pcd) ctrl0 <= sd_buff_dout[7:0];
          default: ;
        endcase
      end else if (AUDIO_EN && e_kind == EK_AUDIO) begin
        // little-endian 16-bit L, R pairs -> one {R, L} word per stereo sample
        e_odd <= !e_odd;
        // {R, L} is assembled in the output register itself (src/soc/cdda.v samples CDDA_DATA
        // only in the cycle after the cdda_wr edge, and the next L cannot land before it).
        if (!e_odd) cdda_data[15:0] <= sd_buff_dout;
        else begin cdda_wr <= !audio_stale_now; cdda_data[31:16] <= sd_buff_dout; end
      end
    end
  end

  // The command side's fetch request: entering S_FETCH (a READ(10)'s first sector, or the next
  // one at the end of a data phase). Mirrors the two arms above that set st <= S_FETCH.
  wire read_first = exec_go && cmd == 8'hA0 && cdb[0] == 8'h28 && cdb_len78 != 16'd0 &&
                    in_range(cdb_lba, totals);
  wire read_next  = io_rd && sel && io_addr == 16'h0641 && data_in && cmd == 8'hA0 &&
                    !({1'b0, ptr} + 11'd1 < dp_words) && dp_read && rd_left != 16'd0 &&
                    (rd_lba < totals);
  wire fetch_req = (read_first || read_next) && rst_n && !abort_now;
  wire e_take_data = (e_st == E_IDLE) && data_pend && !hdr_pend;

  // the engine's offset arithmetic (E_CALC): one multiply (a DSP block, not LAB logic)
  wire [31:0] e_l = {12'd0, e_pos};
  wire [31:0] e_off = !is_pcd ? (e_l << 11)
                    : (e_l * 32'd2352 + ((e_kind == EK_DATA) ? 32'd2368 : 32'd2352));

  // synthesis translate_off
  // SIM-ONLY (R8): the ring's CDDA_PLAYED can only report a sector the player fetched. Outside a
  // flush (which discards the ring and re-bases both positions), a played pulse while the
  // played position already equals the fetched one plus the fetch in flight is a sector that
  // was never fetched - a ring and player out of step. Collisions pinned by tb_pc9821_atapi C23
  // (a played pulse in the PAUSE's cycle and in the STOP's cycle).
  always @(posedge clk)
    if (AUDIO_EN && cdda_played && !cdda_flush && is_pcd &&
        daplaypos >= dacurpos + (audio_in_flight ? {17'd0, e_nsec} : 20'd0))
      $error("pc9821_atapi: CDDA_PLAYED for a sector never fetched (played %0d, fetched %0d)",
             daplaypos, dacurpos);
  // synthesis translate_on

  // ================= LOG_EN: the CD's conversation on the debug UART =================
  // Records, each 0xA5, a type, a 16-bit millisecond time (big-endian), then the type's payload:
  //   0x01 CMD    a task-file command write at bank 1: command, DRHD, DEV, STATUS before it (4)
  //   0x02 CDB    a packet as the drive executes it: the 12 CDB bytes (12)
  //   0x03 DATA / 0x04 DONE  the drive enters a data phase / completes (or an ATA command left it
  //               idle): STATUS, ERROR, interrupt
  //               reason (0x644), byte count low/high, sense key, ASC, ASCQ (8); DONE adds the
  //               data-port words the guest read since the command: sum, XOR, count (6)
  //   0x05 MOUNT  a slot-4 mount: img_size[39:0], big-endian (5)
  //   0x06 READY  the medium became loaded: PCD flag, tracks, sector count[23:0] (5)
  //   0x07 DEVCTL a 0x074C write at bank 1 (1)    0x08 (retired: BANK)
  //   0x0B PLAYER the CD-DA player: 0x10|flag (0x11 play, 0x12 pause, 0x13 done, 0x14 medium gone, 0x15 none), the
  //               position and the remaining length (3 bytes each), {engine idle, cdda_req} (8);
  //               on every flag change and every 16th streamed audio sector
  //   0x09 LOST   records dropped since the last one that got out (1)
  //   0x0A ALIVE  0x5A, once at power-up and after every core reset: proves the path to the UART
  //               even when the drive sees no traffic (1)
  // An event is latched as pending and serialised a byte per cycle into a 2 KiB ring that drains
  // to the UART at its own pace. The serialiser samples the live registers, which hold still for
  // far longer than a record takes (a guest access is tens of cycles); a second event of a type
  // still pending, or a full ring, counts as LOST.
  generate if (LOG_EN) begin : g_log
    localparam integer MS_DIV = LOG_CLK_HZ / 1000;
    reg [31:0] lg_div = 32'd0;
    reg [15:0] lg_ms = 16'd0;
    always @(posedge clk) begin
      if (lg_div == MS_DIV - 1) begin lg_div <= 32'd0; lg_ms <= lg_ms + 16'd1; end
      else lg_div <= lg_div + 32'd1;
    end
    reg [2:0] lg_st_d = 3'd0;
    reg       lg_loaded_d = 1'b0;
    always @(posedge clk) begin lg_st_d <= st; lg_loaded_d <= loaded; lg_rst_d <= rst_n; end
    wire ev_cmd  = io_wr && bank1 && io_addr == 16'h064E;
    wire ev_cdb  = exec_go && cmd == 8'hA0;
    // a phase change into DATA or IDLE, or an ATA command that completed in the cycle it was
    // written (EXECUTE DEVICE DIAGNOSTIC, an aborted IDENTIFY DEVICE, NOP...: st never moves)
    reg  lg_cmd_d = 1'b0;
    always @(posedge clk) lg_cmd_d <= io_wr && bank1 && io_addr == 16'h064E;
    wire ev_end  = ((st != lg_st_d) && (st == S_IDLE || st == S_DATA)) ||
                   (lg_cmd_d && st == S_IDLE && lg_st_d == S_IDLE);
    wire ev_mnt  = mount_edge;
    wire ev_rdy  = loaded && !lg_loaded_d;
    wire ev_ctl  = io_wr && bank1 && io_addr == 16'h074C;
    // (BANK records are retired: the guest's own disk traffic switches 0x0432 tens of thousands of
    // times a minute, which overran the ring on the hardware - 252,100 records, most of them LOST
    // around the CD's.) The PLAYER record instead: the CD-DA player's flag changed, or another 16
    // audio sectors were streamed - so a capture shows whether a play advances and when it ends.
    reg  [2:0] lg_daflag_d = 3'd0;
    always @(posedge clk) lg_daflag_d <= daflag;
    wire ev_play = AUDIO_EN && ((daflag != lg_daflag_d) ||
                   (e_done && e_kind == EK_AUDIO &&
                    ({1'b0, dacurpos[3:0]} + {2'd0, e_nsec}) >= 5'd16));
    reg  p_cmd = 0, p_cdb = 0, p_end = 0, p_mnt = 0, p_rdy = 0, p_ctl = 0, p_play = 0;
    reg  p_alive = 1'b1;   // power-up
    reg  lg_rst_d = 1'b0;
    wire ev_alive = rst_n && !lg_rst_d;   // the end of a core reset
    reg  [7:0] l_cmd = 0, l_cmd_st = 0, l_ctl = 0;
    reg        l_end_data = 0;
    reg  [7:0] lost = 0;
    // what the guest read from the data port since the last command: the sum and XOR of the words
    // and their count (DONE carries them), so a capture can be compared word-for-word in effect
    reg  [15:0] d_sum = 0, d_xor = 0, d_n = 0;
    // the record being serialised
    reg        busy = 0;
    reg  [3:0] r_type = 0;
    reg  [4:0] r_i = 0, r_len = 0;
    reg  [15:0] r_t = 0;
    // the ring
    (* ramstyle = "M10K" *) reg [7:0] ring [0:2047];
    reg [11:0] wp = 0, rp = 0;
    wire [11:0] used = wp - rp;
    wire room = used < 12'd2000;
    function automatic [4:0] plen(input [3:0] t);
      case (t)
        4'd1: plen = 5'd8;  4'd2: plen = 5'd16; 4'd3: plen = 5'd12; 4'd4: plen = 5'd18;
        4'd5, 4'd6: plen = 5'd9; 4'd11: plen = 5'd12; default: plen = 5'd5;
      endcase
    endfunction
    reg [7:0] r_byte;
    always @* begin
      r_byte = 8'h00;
      case (r_i)
        5'd0: r_byte = 8'hA5;
        5'd1: r_byte = {4'd0, r_type};
        5'd2: r_byte = r_t[15:8];
        5'd3: r_byte = r_t[7:0];
        default: case (r_type)
          4'd1: case (r_i) 5'd4: r_byte = l_cmd; 5'd5: r_byte = drhd; 5'd6: r_byte = {7'd0, dev1};
                           default: r_byte = l_cmd_st; endcase
          4'd2: r_byte = cdb[4'(r_i - 5'd4)];
          4'd3, 4'd4: case (r_i) 5'd4: r_byte = status; 5'd5: r_byte = error; 5'd6: r_byte = sc;
                           5'd7: r_byte = cy[7:0]; 5'd8: r_byte = cy[15:8]; 5'd9: r_byte = {4'd0, sk_val(skc)};
                           5'd10: r_byte = asc_w[7:0]; 5'd11: r_byte = asc_w[15:8];
                           5'd12: r_byte = d_sum[15:8]; 5'd13: r_byte = d_sum[7:0];
                           5'd14: r_byte = d_xor[15:8]; 5'd15: r_byte = d_xor[7:0];
                           5'd16: r_byte = d_n[15:8];   default: r_byte = d_n[7:0]; endcase
          4'd5: case (r_i) 5'd4: r_byte = img_size[39:32]; 5'd5: r_byte = img_size[31:24];
                           5'd6: r_byte = img_size[23:16]; 5'd7: r_byte = img_size[15:8];
                           default: r_byte = img_size[7:0]; endcase
          4'd6: case (r_i) 5'd4: r_byte = {7'd0, is_pcd}; 5'd5: r_byte = tracks;
                           5'd6: r_byte = {4'd0, totals[19:16]}; 5'd7: r_byte = totals[15:8];
                           default: r_byte = totals[7:0]; endcase
          4'd7: r_byte = l_ctl;
          4'd11: case (r_i) 5'd4: r_byte = {5'h02, daflag}; 5'd5: r_byte = {4'd0, dacurpos[19:16]};
                            5'd6: r_byte = dacurpos[15:8]; 5'd7: r_byte = dacurpos[7:0];
                            5'd8: r_byte = {4'd0, dalength[19:16]}; 5'd9: r_byte = dalength[15:8];
                            5'd10: r_byte = dalength[7:0]; default: r_byte = {6'd0, e_st == E_IDLE, cdda_req}; endcase
          4'd10: r_byte = 8'h5A;
          default: r_byte = lost;
        endcase
      endcase
    end
    // which pending record goes next (in the order a command produces them)
    wire       any_p = p_alive | p_cmd | p_cdb | p_end | p_mnt | p_rdy | p_ctl | p_play | (lost != 8'd0);
    wire [3:0] nxt = p_alive ? 4'd10 : p_ctl ? 4'd7 : p_cmd ? 4'd1 : p_cdb ? 4'd2 :
                     p_end ? (l_end_data ? 4'd3 : 4'd4) : p_mnt ? 4'd5 : p_rdy ? 4'd6 : p_play ? 4'd11 : 4'd9;
    wire start = !busy && any_p && room;
    wire done_rec = busy && (r_i == r_len - 5'd1);
    always @(posedge clk) begin
      // the events (a repeat of a type still pending is lost)
      if (ev_cmd)  begin if (p_cmd)  lost <= lost + 8'd1; p_cmd <= 1'b1; l_cmd <= io_din; l_cmd_st <= status; end
      if (ev_cdb)  begin if (p_cdb)  lost <= lost + 8'd1; p_cdb <= 1'b1; end
      if (ev_end)  begin if (p_end)  lost <= lost + 8'd1; p_end <= 1'b1; l_end_data <= (st == S_DATA); end
      if (ev_mnt)  p_mnt <= 1'b1;
      if (ev_rdy)  p_rdy <= 1'b1;
      if (ev_ctl)  begin p_ctl <= 1'b1; l_ctl <= io_din; end
      if (ev_play) p_play <= 1'b1;
      if (ev_alive) p_alive <= 1'b1;
      if (ev_cmd) begin d_sum <= 16'd0; d_xor <= 16'd0; d_n <= 16'd0; end
      else if (io_rd && sel && io_addr == 16'h0641 && data_in) begin
        d_sum <= d_sum + buf_q; d_xor <= d_xor ^ buf_q; d_n <= d_n + 16'd1;
      end
      if (start) begin
        busy <= 1'b1; r_type <= nxt; r_len <= plen(nxt); r_i <= 5'd0; r_t <= lg_ms;
        case (nxt)
          4'd1: if (!ev_cmd)  p_cmd  <= 1'b0;
          4'd2: if (!ev_cdb)  p_cdb  <= 1'b0;
          4'd3, 4'd4: if (!ev_end) p_end <= 1'b0;
          4'd5: if (!ev_mnt)  p_mnt  <= 1'b0;
          4'd6: if (!ev_rdy)  p_rdy  <= 1'b0;
          4'd7: if (!ev_ctl)  p_ctl  <= 1'b0;
          4'd11: if (!ev_play) p_play <= 1'b0;
          4'd10: if (!ev_alive) p_alive <= 1'b0;
          default: ;
        endcase
      end else if (!busy && any_p && !room && lost != 8'hFF && (p_cmd | p_cdb | p_end)) begin
        // the ring is full: drop the oldest kind of pending record and count it
        lost <= lost + 8'd1;
        if (p_cmd) p_cmd <= 1'b0; else if (p_cdb) p_cdb <= 1'b0; else p_end <= 1'b0;
      end
      if (busy) begin
        ring[wp[10:0]] <= r_byte;
        wp <= wp + 12'd1;
        r_i <= r_i + 5'd1;
        if (done_rec) begin
          busy <= 1'b0;
          if (r_type == 4'd9) lost <= 8'd0;
        end
      end
    end
    // the drain: a registered ring read, presented until the UART FIFO takes it
    reg [7:0] q;
    reg       qv = 1'b0;
    always @(posedge clk) begin
      if (!qv && rp != wp) begin q <= ring[rp[10:0]]; rp <= rp + 12'd1; qv <= 1'b1; end
      else if (qv && log_accept) qv <= 1'b0;
    end
    assign log_byte = q;
    assign log_we   = qv;
  end else begin : g_no_log
    assign log_byte = 8'h00;
    assign log_we   = 1'b0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire log_unused = log_accept;
    /* verilator lint_on UNUSEDSIGNAL */
  end endgenerate

endmodule
/* verilator lint_on PROCASSINIT */
`default_nettype wire
