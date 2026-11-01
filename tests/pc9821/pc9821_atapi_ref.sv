// pc9821_atapi_ref - the ATAPI CD-ROM drive AS IT WAS before its area restructuring (284a2442), kept as the
// golden model of tb_pc9821_atapi_equiv: every restructuring of src/pc9821/storage/pc9821_atapi.sv is
// proven against it by running the same random command stream through both and comparing every value
// the guest reads. It is a byte-for-byte copy of that file with the module renamed. Do NOT edit it.
//
// PC-98 ATAPI CD-ROM on the built-in IDE: ALWAYS bank 1's MASTER (IDE unit 2), the hard disk
// always bank 0's master (unit 0) - the stock CD-equipped Xe10's layout and NP2kai's default (HDD
// at unit 0, CD at unit 2). Fixed, independent of the build and of the
// media: the Xe10 capture's disk on bank 1 (docs/probes/IDE.TXT) is a CF card in the
// CD connector, a quirk of that one machine, not the layout to model.
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
// straight into src/soc/cdda.v's ring (one {R,L} word per stereo sample) whenever its CDDA_REQ
// says a sector fits; no buffer of this module holds audio.

`default_nettype none

// The slot-side registers (medium, engine, player, the host request pins) carry power-up values
// and no reset (see their declaration), which is this warning's shape.
/* verilator lint_off PROCASSINIT */
module pc9821_atapi_ref #(
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
    output reg         irq,

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

    // src/soc/cdda.v's write side: CDDA_REQ = there is room for a sector; one CDDA_WR edge per
    // stereo sample, {R, L}.
    input  wire        cdda_req,
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
  // atapicmd.c's daflag values: the READ SUB-CHANNEL audio status byte.
  localparam [2:0] DA_PLAY = 3'd1, DA_PAUSE = 3'd2, DA_DONE = 3'd3,
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
  reg [3:0] sk;
  reg [15:0] asc;   // {ASCQ, ASC} as NP2kai's drv->asc

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
  // The player, like the medium, is not reset by the core (NP2kai devinit: daflag 0x15).
  reg [2:0]  daflag = 3'd5;
  reg [19:0] dacurpos = 20'd0;
  reg [19:0] dalength = 20'd0;

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
  reg [10:0] e_n = 11'd0;      // wanted words
  reg        hdr_pend = 1'b0, data_pend = 1'b0;
  reg        e_odd = 1'b0;     // audio: the next wanted word is a right sample
  wire e_done = (e_st == E_STREAM) && !sd_ack;
  wire [12:0] e_rel = sd_buff_addr - {4'd0, e_w0};
  wire e_word = (e_st == E_STREAM) && sd_ack && sd_buff_wr &&
                (sd_buff_addr >= {4'd0, e_w0}) && (e_rel < {2'd0, e_n});

  // ---- MSF converter (frames -> M:S:F), sequential ----
  reg        cv_busy = 1'b0, cv_ph = 1'b0, cv_owner_mount = 1'b0, iso_msf_pend = 1'b0;
  reg [19:0] cv_x = 20'd0;
  reg [6:0]  cv_m = 7'd0; reg [5:0] cv_s = 6'd0;
  wire       cv_done = cv_busy && cv_ph && (cv_x < 20'd75);

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
  localparam [8:0] ROM_INQ = 9'd256;
  localparam [8:0] ROM_P01 = 9'd288, ROM_P0D = 9'd296, ROM_P0E = 9'd304, ROM_P2A = 9'd320,
                   ROM_P0F = 9'd340;
  // the changeable-values copy of each page follows its default copy
  localparam [8:0] ROM_C01 = 9'd292, ROM_C0D = 9'd300, ROM_C0E = 9'd312, ROM_C2A = 9'd330,
                   ROM_C0F = 9'd348;
  // An initialised array read through a register: Quartus infers the block ROM from this shape
  // (a registered case statement it built in LUTs). Words not listed are zero.
  (* romstyle = "M10K" *) reg [15:0] rom [0:511];
  initial begin
    for (int k = 0; k < 512; k++) rom[k] = 16'h0000;
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
    rom[288] = 16'h0601;
    rom[293] = 16'hFF37;
    rom[296] = 16'h060D;
    rom[298] = 16'h3C00;
    rom[299] = 16'h4B00;
    rom[301] = 16'h0F00;
    rom[302] = 16'hFFFF;
    rom[303] = 16'hFFFF;
    rom[304] = 16'h0E0E;
    rom[305] = 16'h0004;
    rom[307] = 16'h4B00;
    rom[308] = 16'hFF01;
    rom[309] = 16'hFF02;
    rom[313] = 16'h0002;
    rom[315] = 16'hFFFF;
    rom[316] = 16'hFF0F;
    rom[317] = 16'hFF0F;
    rom[320] = 16'h122A;
    rom[322] = 16'h6571;
    rom[323] = 16'h0729;
    rom[324] = 16'hC202;
    rom[325] = 16'hFF00;
    rom[326] = 16'h8000;
    rom[327] = 16'hC202;
    rom[334] = 16'hC202;
    rom[335] = 16'h0200;
    rom[337] = 16'hC202;
    rom[340] = 16'h100F;
    rom[342] = 16'h1811;
    rom[348] = 16'h100F;
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
  reg [19:0] sc_rpos;           // best entry's LBA
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

  // The ROM address for the builder's stage A (bi_a): the constant replies, and MODE SENSE's
  // page run (0x3F = pages 0x01, 0x0D, 0x0E, 0x2A in that order, atapicmd.c's fallthrough).
  wire [8:0] mq = bi_a - 9'd4;   // the word within the pages
  reg  [8:0] rom_addr;
  always @* begin
    case (bk)
      K_IDENT: rom_addr = bi_a;
      K_INQ:   rom_addr = ROM_INQ + bi_a;
      default: case (ms_page)   // K_MSENSE (the other kinds do not read the ROM)
        6'h0F:   rom_addr = (ms_chg ? ROM_C0F : ROM_P0F) + mq;
        6'h01:   rom_addr = (ms_chg ? ROM_C01 : ROM_P01) + mq;
        6'h0D:   rom_addr = (ms_chg ? ROM_C0D : ROM_P0D) + mq;
        6'h0E:   rom_addr = (ms_chg ? ROM_C0E : ROM_P0E) + mq;
        6'h2A:   rom_addr = (ms_chg ? ROM_C2A : ROM_P2A) + mq;
        default: rom_addr = (mq < 9'd4)  ? (ms_chg ? ROM_C01 : ROM_P01) + mq :
                            (mq < 9'd8)  ? (ms_chg ? ROM_C0D : ROM_P0D) + mq - 9'd4 :
                            (mq < 9'd16) ? (ms_chg ? ROM_C0E : ROM_P0E) + mq - 9'd8 :
                                           (ms_chg ? ROM_C2A : ROM_P2A) + mq - 9'd16;
      endcase
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
                 4'd1: bword = {12'd0, sk};
                 4'd3: bword = 16'h0B00;
                 4'd6: bword = asc;
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
  wire exec_go = (st == S_EXEC) && !abort_now &&
                 !((e_st != E_IDLE) && (e_kind != EK_AUDIO)) && !data_pend;
  // A READ(10) sector is in range of the medium (sxsi_read fails otherwise: ILLEGAL REQUEST,
  // ASC 0x21 - atapicmd.c atapi_dataread).
  function automatic in_range(input [31:0] lba, input [19:0] tot);
    in_range = (lba[31:20] == 12'd0) && (lba[19:0] < tot);
  endfunction
  // R3: the commands that rewrite the player POSITION (stop, seek, play, a reported medium
  // change) win over an audio completion's advance in the same cycle, and the ones that rewrite
  // the player FLAG (those plus PAUSE/RESUME) win over the engine's end-of-play write.
  wire tur_change = (cdb[0] == 8'h00) && loaded && changed;
  wire player_pos_cmd  = AUDIO_EN && ((exec_go && cmd == 8'hA0 &&
                         (tur_change || cdb[0] == 8'h1B || cdb[0] == 8'h2B ||
                          cdb[0] == 8'h45 || cdb[0] == 8'h47)) ||
                         (mount_edge && img_size < 64'd2048));
  wire player_flag_cmd = player_pos_cmd ||
                         (AUDIO_EN && exec_go && cmd == 8'hA0 && cdb[0] == 8'h4B);
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
      error <= 8'h00; sk <= SK_NO_SENSE; asc <= ASC_NONE;
      st <= S_IDLE;
      if (!nien) irq <= 1'b1;
    end
  endtask
  task automatic t_senderror(input [3:0] key, input [15:0] code, input set);
    begin
      sc <= INTR_IO | INTR_CD;
      status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_DRQ)) | ST_ERR | ST_DSC;
      if (set) begin error <= {key, error[3:0]}; sk <= key; asc <= code; end
      st <= S_IDLE;
      if (!nien) irq <= 1'b1;
    end
  endtask
  task automatic t_sendabort;
    begin
      sk <= SK_ABORTED; error <= ERR_ABRT;
      sc <= INTR_IO | INTR_CD;
      status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_DRQ)) | ST_ERR | ST_DSC;
      st <= S_IDLE;
      if (!nien) irq <= 1'b1;
    end
  endtask
  task automatic t_ata_abort;   // ideio.c cmdabort
    begin
      status <= ST_DRDY | ST_ERR; error <= ERR_ABRT;
      st <= S_IDLE;
      if (!nien) irq <= 1'b1;
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
  task automatic t_stop_play;   // atapicmd.c stop_daplay
    begin
      daflag <= DA_DONE; dacurpos <= 20'd0; dalength <= 20'd0;
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
      nien <= 1'b0; srst <= 1'b0; sk <= SK_NO_SENSE; asc <= ASC_NONE;
      irq <= 1'b0;
      st <= S_IDLE; cmd <= 8'h00; pkt_words <= 3'd0; data_lo <= 8'h00;
      ptr <= 10'd0; dp_words <= 11'd0; dp_read <= 1'b0; rd_lba <= 20'd0; rd_left <= 16'd0;
      bk <= K_IDENT; bi_a <= 9'd0; bi_b <= 9'd0; bv_b <= 1'b0; b_full <= 12'd0; b_alloc <= 16'd0;
      toc_e0 <= 7'd0; toc_base <= 10'd256; ms_page <= 6'h00; ms_chg <= 1'b0;
      sub_full <= 1'b0; sub_ctrl <= 8'h00; sub_point <= 8'h00;
      ab_m <= 8'd0; ab_s <= 8'd0; ab_f <= 8'd0; rl_m <= 8'd0; rl_s <= 8'd0; rl_f <= 8'd0;
      damsfbcd <= 1'b0;
      pp <= 3'd0; sc_e <= 7'd0; sc_r <= 7'd0; sc_rpos <= 20'd0; sc_hi <= 4'h0;
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
              if (!nien) irq <= 1'b1;
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
              8'h40, 8'h41: begin status <= status & ~ST_BSY; if (!nien) irq <= 1'b1; end
              8'hE0: if (!nien) irq <= 1'b1;
              8'hE1: if (status[6]) begin
                       status <= ST_DRDY | ST_DSC; error <= 8'h00; if (!nien) irq <= 1'b1;
                     end else t_ata_abort;
              8'hE5: begin sc <= 8'hFF; status <= status & ~ST_BSY; if (!nien) irq <= 1'b1; end
              8'hE7: begin status <= ST_DRDY; error <= 8'h00; if (!nien) irq <= 1'b1; end
              8'hDE, 8'hDF: begin
                status <= (status | ST_DRDY) & ~(ST_BSY | ST_DMRD | ST_DRQ | ST_ERR);
                if (!nien) irq <= 1'b1;
              end
              8'hF8: begin
                sn <= totals[7:0]; cy <= {4'd0, totals[19:8]}; drhd[3:0] <= 4'd0;
                if (!nien) irq <= 1'b1;
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
        if (io_addr == 16'h064E && !nien) irq <= 1'b0;
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
            sc <= INTR_IO; cy <= bxfer; sk <= SK_NO_SENSE; asc <= ASC_NONE;
          end
          status <= (status & ~(ST_BSY | ST_DMRD | ST_DSC | ST_ERR)) | ST_DRQ | ST_DSC;
          error <= 8'h00;
          ptr <= 10'd0; dp_words <= {2'd0, bn}; dp_read <= 1'b0;
          st <= S_DATA;
          if (!nien) irq <= 1'b1;
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
              pp <= 3'd0; sc_e <= 7'd0; sc_r <= 7'd0; sc_rpos <= 20'd0; st <= S_PREP;
              sc_pos <= dacurpos + ((daflag == DA_PAUSE || daflag == DA_DONE) ?
                                    {17'd0, sc_rnd[2:0]} : 20'd0);
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
            // entry sc_e's LBA, from its big-endian field: {byte1, byte2, byte3}
            if ({sc_hi, hq[7:0], hq[15:8]} <= sc_pos || sc_e == 7'd0) begin
              sc_r <= sc_e; sc_rpos <= {sc_hi, hq[7:0], hq[15:8]};
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
        error <= 8'h00; sk <= SK_NO_SENSE; asc <= ASC_NONE;
        ptr <= 10'd0; dp_words <= 11'd1024; dp_read <= 1'b1;
        st <= S_DATA;
        if (!nien) irq <= 1'b1;
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
  // Not reset (see the declarations). Events consumed here: `mount_edge`; `e_done` of an EK_HDR
  // or EK_AUDIO fetch; `cv_done` of the mount's conversion; the command decode's player
  // commands (exec_go), which own the player registers in their cycle (R3, above).
  always @(posedge clk) begin
    cdda_wr <= 1'b0;
    mounted_d <= img_mounted;

    // ---- the MSF converter: one start per cycle, else step / finish ----
    if (cv_start_abs || cv_start_rel || cv_start_iso) begin
      cv_busy <= 1'b1; cv_ph <= 1'b0; cv_m <= 7'd0; cv_s <= 6'd0;
      cv_owner_mount <= cv_start_iso;
      cv_x <= cv_start_iso ? iso_cap + 20'd150 :
              cv_start_abs ? sc_pos + 20'd150 : sc_pos - sc_rpos;
      if (cv_start_iso) iso_msf_pend <= 1'b0;
    end else if (cv_done) begin cv_busy <= 1'b0; cv_owner_mount <= 1'b0; end
    else if (cv_busy) begin
      if (!cv_ph) begin
        if (cv_x >= 20'd4500) begin cv_x <= cv_x - 20'd4500; cv_m <= cv_m + 7'd1; end
        else cv_ph <= 1'b1;
      end else begin
        cv_x <= cv_x - 20'd75; cv_s <= cv_s + 6'd1;
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
    if (AUDIO_EN) begin
      if (player_pos_cmd) begin
        if (mount_edge || tur_change || cdb[0] == 8'h1B) begin
          daflag <= DA_DONE; dacurpos <= 20'd0; dalength <= 20'd0;
        end else if (cdb[0] == 8'h2B) begin
          daflag <= DA_DONE; dalength <= 20'd0;
          dacurpos <= in_range(cdb_lba, totals) ? cdb_lba[19:0] : 20'd0;
        end else if (cdb[0] == 8'h45) begin
          // NP2kai reads the length as (cdb[7] << 16) | cdb[8], a typo for MMC's (cdb[7] << 8)
          // | cdb[8]; no driver on the tested disk issues 0x45 (storage report sec.3.2), so
          // MMC's field is used and the divergence is recorded in the report.
          daflag <= DA_PLAY; dacurpos <= cdb_lba[19:0]; dalength <= {4'd0, cdb_len78};
        end else begin   // 0x47 PLAY AUDIO MSF
          daflag <= DA_PLAY;
          dacurpos <= msf_pos_d[20] ? 20'd0 : msf_pos_d[19:0];
          dalength <= msf_len_d[20] ? 20'd0 : msf_len_d[19:0];
        end
      end else if (player_flag_cmd) begin   // 0x4B
        if (cdb[8][0]) begin if (daflag == DA_PAUSE) daflag <= DA_PLAY; end
        else if (daflag == DA_PLAY) daflag <= DA_PAUSE;
      end else begin
        if (e_done && e_kind == EK_AUDIO) begin
          dacurpos <= dacurpos + 20'd1; dalength <= dalength - 20'd1;
        end
        // the end of play: the length is spent, the lead-out is reached, or there is no PCD
        if (e_st == E_IDLE && daflag == DA_PLAY &&
            (dalength == 20'd0 || dacurpos >= totals || !is_pcd))
          daflag <= DA_DONE;
      end
    end

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
        end
      end
      E_CALC: begin
        // The byte offset of the wanted bytes: an ISO sector at L*2048; a PCD sector at
        // (L+1)*2352 (after the header sector), its MODE1 user data 16 bytes in.
        e_st <= E_WAIT; sd_rd <= 1'b1; e_odd <= 1'b0;
        if (e_kind == EK_HDR) begin
          sd_lba <= 32'd0; sd_blk_cnt <= 6'd3; e_w0 <= 9'd0; e_n <= 11'd1024;
        end else begin
          sd_lba <= {9'd0, e_off[31:9]};
          sd_blk_cnt <= (e_kind == EK_AUDIO) ? 6'(({3'd0, e_off[8:0]} + 12'd2351) >> 9)
                                             : 6'(({3'd0, e_off[8:0]} + 12'd2047) >> 9);
          e_w0 <= {1'b0, e_off[8:1]};
          e_n <= (e_kind == EK_AUDIO) ? 11'd1176 : 11'd1024;
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
        else begin cdda_wr <= 1'b1; cdda_data[31:16] <= sd_buff_dout; end
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
  //   0x0B PLAYER the CD-DA player: 0x10|flag (0x11 play, 0x12 pause, 0x13 done, 0x15 none), the
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
                   (e_done && e_kind == EK_AUDIO && dacurpos[3:0] == 4'hF));
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
                           5'd7: r_byte = cy[7:0]; 5'd8: r_byte = cy[15:8]; 5'd9: r_byte = {4'd0, sk};
                           5'd10: r_byte = asc[7:0]; 5'd11: r_byte = asc[15:8];
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
