// tb_pc9821_atapi - the ATAPI CD-ROM on bank 1's master, against NP2kai's answers.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATAPI: The CD-ROM answers as bank 1's ATAPI MASTER with the REAL pc9821_ata's one disk on bank 0, every expected value taken from NP2kai (cbus/ideio.c, cbus/atapicmd.c), from the Xe10's own IDE ROM or from the image the host model serves, never from the RTL: the IDE ROM's probe of bank 1's master (BANK3@0x0A0A) passes step by step - the pre-reset presence test (STATUS 0x00, the 0xEB/0x14 signature marking the unit ATAPI, ERROR 0x01), IDENTIFY DEVICE ending ERR+ABRT, the ready poll with its SRST-and-retry, and a PACKET INQUIRY whose byte 0 is 5 - so the ROM records a CD-ROM; device 0 on bank 1 reads the signature 0x01/0x01/0x14/0xEB with STATUS 0x00 after DEVICE RESET (ERROR 0x01, an interrupt) and 0x51/ERROR 0x01 after an SRST pulse, device 1 on bank 1 is an absent slave (STATUS and ALTERNATE STATUS 0x00, a command for it not executed), and bank 0's master is the hard disk; IDENTIFY DEVICE aborts with the signature and IDENTIFY PACKET DEVICE returns word 0 = 0x8580 and the model "NEC CD-ROM DRIVE:98"; a PACKET command shows the CoD phase (0x644 = 0x01, DRQ, no interrupt), INQUIRY returns NP2kai's 36 bytes ("NEC     CD-ROM DRIVE:98 1.0 ", type 5, removable) in a data phase whose 0x644/0x648/0x64A say IO and the byte count, then completes with 0x50 and 0x644 = 0x03; TEST UNIT READY with no medium and the first one after a mount answer CHECK with NOT READY / 0x3A in REQUEST SENSE (0x28 once NEC mode is on via MODE SENSE page 0x0F), the next one GOOD; READ CAPACITY returns the sector count and 2048; READ(10) streams each 2048-byte sector of an ISO and of a PCD (from the raw sector's MODE1 user data) through the slot's block handshake with one interrupt and byte count 2048 per sector, and a read past the end answers ILLEGAL REQUEST / 0x21; READ TOC format 0 returns the descriptors (LBA, MSF and NEC BCD forms) of a one-track ISO and of a three-track PCD header, lead-out 0xAA; MODE SENSE page 0x2A returns NP2kai's page with medium type 0x03 for a data+audio disc; PLAY AUDIO MSF streams the audio sectors' {R,L} samples into the CD-DA port and READ SUB-CHANNEL reports playing/paused/completed with the current position, which wanders by NP2kai's rand() & 7 frames while paused or completed; and PATACD.SYS's unit probe (bank 0/1, master/slave, IDENTIFY PACKET with the 0xEC fallback, word 0 bits 15:14 = 10, INQUIRY type 5, polled with nIEN, NOP after the packet command) finds the CD at bank 1's master, reads an all-zero identify page for the absent slave beside the disk, and finds nothing at the other three units; and the OSD's Eject CD-ROM (pc9821_mount_eject's size-0 event on slot 4, status[11] as the --cdrom top wires it) leaves no medium - TEST UNIT READY answers NOT READY / 0x3A every time and MODE SENSE reports medium type 0x70 - and a re-mount answers NOT READY / 0x28 once (NEC mode), then GOOD, and reads again; and a READ(10) whose block request waits while hps_io streams ANOTHER slot's words takes none of them; and a PLAY AUDIO MSF issued while the previous play's audio sector is still being fetched streams its own first sector whole and completes at its own end (NP2kai's synchronous playaudio: the superseded fetch's completion does not advance the new play); and with nIEN set a drive RELEASES INTRQ (ATA-3 Device Control: high impedance) so an unacknowledged CD request cannot hide the disk's next IRQ9 edge on the ORed line (MAME pc9801.cpp ideirq INPUT_MERGER_ANY_HIGH), while the request itself follows NP2kai's ideio.c - a completion under nIEN neither raises nor clears it and a status read under nIEN does not acknowledge it. 0x0433 reads 00 at bank 1 with nothing pending (the Xe10's `433=00`, not NP2kai ideio_i433's connected-device 0x02), and the CD's pending interrupt is its bit 1 at either bank selection until the status read (qemu-pc98 irq_levels). The MSF converter is pinned at its 4500-frame boundary: a mount of N sectors makes the converter's frame count N + 150 (atapicmd.c's 150-frame lead-in), so media of 4349/4350/4351 and 4424/4425/4426 sectors put the minute compare one frame below, exactly on and one frame above its edge and the seconds step's 74/75/76-frame tail there, and READ TOC MSF/BCD must answer 00:59:74, 01:00:00, 01:00:01, 01:00:74, 01:01:00 and 01:01:01. The CD-DA player reads ahead: behind a host that takes 20 ms per slot-4 request (longer than the 13.3 ms one sector lasts) an 800 ms play reaches the real src/soc/cdda.v ring's output whole, every sample in order and equal to the disc with no silent sample inside it; READ SUB-CHANNEL reports NP2kai's dacurpos, the next sector its mixer loads - one past the sector being heard, exactly lba0 + ceil(k / 588) after k samples have reached the speakers (ideio.c playdevaudio increments dacurpos as it loads a sector, before mixing it) - and reports completed only once every sample has left the ring; PAUSE and STOP silence the output at once, a paused drive reports that same position plus NP2kai's rand() & 7, and RESUME continues from the start of the sector that was being heard with no gap. A sector finishing in the very cycle of a PAUSE is merged into the held position (one past it) and one finishing in a STOP's cycle is discarded with the play (position 0). Another disc mounted over a playing one stops the play at once as NP2kai's mixer does when the medium goes away (ideio.c playdevaudio: daflag 0x14): no sample of the old disc reaches the speakers after the mount, no sector of the new disc is fetched, READ SUB-CHANNEL answers 0x14 at NP2kai's position, and the TEST UNIT READY that reports the new disc stops the player (0x13, position 0). A core reset in the middle of a play stops it as NP2kai's ideio_reset does on every machine reset (cbus/cbuscore.c resetfn[]; devinit daflag 0x15): the speakers go silent at once, no audio sector is fetched, the disc stays mounted and READ SUB-CHANNEL answers 0x15 with no position. A play's first sector completing in the very cycle of a PAUSE, or of another disc's mount over the playing one, counts as loaded, as NP2kai's dacurpos counts a sector the moment its mixer reads it (ideio.c playdevaudio): READ SUB-CHANNEL then reports one past it - 0x12 at lba0 + 1 + rand() & 7 with the lowest of 32 reports exactly lba0 + 1, and 0x14 at exactly lba0 + 1 - never lba0. A PAUSED play survives an eject and a different disc as it does in NP2kai (ideio_notify touches only the media flags; atapi_cmd_pauseresume tests only daflag 0x12): READ SUB-CHANNEL still answers 0x12 at the same position after the remount, a RESUME before any TEST UNIT READY answers GOOD and 0x11 and streams the NEW disc's samples from the paused sector, and the TEST UNIT READY that reports the new disc then stops the player (0x13, position 0). With NO disc in the drive (an eject clears NP2kai's READY flag) a RESUME of that pause, or a PLAY, answers GOOD with NO SENSE (atapi_cmd_pauseresume / playaudio_sub cmddone) and the play stops with 0x14, not 0x13, as NP2kai's playdevaudio stops it when the device is not READY: READ SUB-CHANNEL answers CHECK with the sense untouched while no disc is in, no sample is streamed, and after a remount it answers 0x14 at exactly the paused dacurpos (or the PLAY's start) with no rand(), a further RESUME changes nothing, and the TEST UNIT READY that reports the disc stops the player (0x13, position 0). A single-track image of raw 2352-byte sectors with no PCD header - the ECMA-130 sync at its start and a size that is a whole number of sectors, NP2kai's openiso/issec2352 image - mounts as one data track of size / 2352 sectors: READ CAPACITY answers that count and 2048, READ TOC one data track (0x14) with the lead-out at it, and READ(10) returns each sector's user bytes 16 bytes in (sec2352_read), or 24 in for MODE2 form 1 (after the CD-ROM XA subheader); the expected bytes are the image's own user data by construction of the ECMA-130 layout; a file that starts with the sync but is not a whole number of 2352-byte sectors reads as an ISO (size / 2048 sectors). A disc change in the middle of a READ(10) fails it as NP2kai's synchronous read does once the old disc is ejected (atapicmd.c atapi_dataread: sxsi_read fails, `drv->asc = 0x21; senderror(drv);`): a change during a data phase lets the buffered sector of the old disc drain whole and then answers CHECK, ILLEGAL REQUEST / 0x21 with no sector of the new disc, and a change while a sector's fetch is at the host presents no data phase and answers the same.
//
// The CD is pc9821_atapi; the IDE read mux is the one pc9821_system builds (`cd_io_own` picks
// the CD's byte). The host model serves hps_io slot 4 from an in-memory image: an ISO of
// ISO_SECS sectors, or a PCD built HERE from the format description (tools/cue2pcd.py's
// docstring: a 2352-byte header - "PC98CD01", the track count, the lead-out, the per-track
// control/LBA words, and the READ TOC address fields as LBA BE / MSF / BCD - then raw
// 2352-byte sectors; a MODE1 sector's user data at +16).
//
// FAIL-FIRST: with -DNO_CD (the bench's own switch: the CD instance is left out and the mux
// sees the pre-change system, where pc9821_ata's absent slave answers device 1) the very first
// case fails - STATUS of device 1 reads 0x00 but 0x648/0x64A read the master's cylinder
// registers, not 0x14/0xEB - and the bench stops there. With -DNO_CD_EJECT (the OSD's CD-ROM
// eject tied off, as the pre-change top had slot 4) C15 fails: TEST UNIT READY after the eject
// answers GOOD and MODE SENSE still reports a disc.
// ==== DUT ====

module tb_pc9821_atapi;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer errors = 0;

  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] ata_dout, cd_dout;
  wire cd_own, cd_irq, ata_irq;
  // pc9821_system's IDE read mux, the CD's INTRQ ORed into 0x0433 as bank 1's bit
  wire [7:0] dout = cd_own ? cd_dout : (ata_dout | {6'd0, cd_irq && (io_addr == 16'h0433), 1'b0});

  // The master: a mounted hard disk with no block engine behind it (no command here reads it).
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_ata ata (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(ata_dout),
      .mounted(1'b1), .readonly(1'b0), .capacity(32'd20160),

      .block_read(), .block_write(), .block_lba(),
      .block_done(1'b0), .block_error(1'b0), .block_buf_we(1'b0), .block_buf_addr(8'd0),
      .block_buf_data(16'd0), .block_rd_addr(8'd0), .block_rd_data(),
      .irq(ata_irq), .dbg_state(), .dbg_cmd(), .dbg_lba(), .dbg_sec()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  reg         img_mounted = 0;
  reg  [63:0] img_size = 0;
  wire [31:0] sd_lba;
  wire [5:0]  sd_blk_cnt;
  wire        sd_rd;
  reg         sd_ack = 0, sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  reg         cdda_req = 1;
  wire        cdda_wr;
  wire [31:0] cdda_data;
  wire [7:0]  log_byte;
  // C13: the REAL src/soc/cdda.v ring behind the player (its CDDA_REQ throttles the fetches and it
  // drains at 44.1 kHz from CLK_AUDIO), instead of the bench's always-ready cdda_req
  reg  clk_audio = 0;
  always #20.345 clk_audio = ~clk_audio;   // 24.576 MHz
  reg  use_real_cdda = 0;
  wire real_cdda_req;
  wire [15:0] real_cdda_l, real_cdda_r;
  wire cdda_req_mux = use_real_cdda ? real_cdda_req : cdda_req;
  // The always-ready model's ring plays each sector the moment its last sample is written (its
  // CDDA_PLAYED one cycle after the 588th CDDA_WR since the last flush); room for four whenever
  // it has room at all.
  wire cdda_flush;
  reg  [9:0] pm_n = 0;
  reg        pm_played = 0;
  always @(posedge clk) begin
    pm_played <= 1'b0;
    if (cdda_flush) pm_n <= 10'd0;
    else if (cdda_wr) begin
      if (pm_n == 10'd587) begin pm_n <= 10'd0; pm_played <= 1'b1; end
      else pm_n <= pm_n + 10'd1;
    end
  end
  wire real_cdda_req4, real_cdda_played;
  reg  c23_quiet = 0;   // C23: the model fetches one sector at a time and reports nothing played
  wire cdda_req4_mux   = use_real_cdda ? real_cdda_req4 : (cdda_req && !c23_quiet);
  // C23: a played pulse forced into the exact cycle the drive executes a PAUSE (0x4B) or a
  // START STOP UNIT (0x1B) packet
  reg  [7:0] c23_op = 8'h00;
  wire c23_hit = (c23_op != 8'h00) && cd.exec_go && cd.cmd == 8'hA0 && cd.cdb[0] == c23_op;
  wire cdda_played_mux = use_real_cdda ? real_cdda_played : ((pm_played && !c23_quiet) || c23_hit);
  /* verilator lint_off PINMISSING */
  cdda #(24576000) real_cdda (
      .CLK(clk), .CDDA_REQ(real_cdda_req), .CDDA_REQ4(real_cdda_req4), .CDDA_PLAYED(real_cdda_played),
      .CDDA_FLUSH(cdda_flush && use_real_cdda),
      .CDDA_WR(cdda_wr && use_real_cdda), .CDDA_DATA(cdda_data),
      .VOLUME_L(4'hF), .VOLUME_R(4'hF), .CLK_AUDIO(clk_audio), .AUDIO_CE(real_cdda_ce),
      .AUDIO_L(real_cdda_l), .AUDIO_R(real_cdda_r));
  /* verilator lint_on PINMISSING */
  // C13 sample check: every non-silent 44.1 kHz output sample of the real ring, in order, must be
  // the next little-endian L,R pair of the played sectors (abyte), starting at the PLAY's first byte.
  wire real_cdda_ce;
  // A zero output sample while the play is under way (after its first sample, before its last)
  // where the disc's next sample is not zero is a GAP: the ring ran dry (C20).
  integer c13_k = 0, c13_bad = 0, c13_lba0 = 0, c13_gap = 0, c13_want = 0;
  bit     c13_hold = 0;   // C22: silence is expected (paused), not a gap
  always @(posedge clk_audio) if (use_real_cdda && real_cdda_ce) begin
    automatic integer l = c13_lba0 + (c13_k * 4) / 2352;
    automatic integer i = (c13_k * 4) % 2352;
    automatic logic [15:0] wl = {abyte(l, i + 1), abyte(l, i)};
    automatic logic [15:0] wr = {abyte(l, i + 3), abyte(l, i + 2)};
    if (real_cdda_l != 0 || real_cdda_r != 0) begin
      if (real_cdda_l !== wl || real_cdda_r !== wr) c13_bad = c13_bad + 1;
      c13_k = c13_k + 1;
    end else if (!c13_hold && c13_k > 0 && c13_k < c13_want && (wl != 0 || wr != 0))
      c13_gap = c13_gap + 1;
  end
  wire        log_we;
  // C21/C22/C24: the samples that had reached the speakers when the drive EXECUTED the last READ
  // SUB-CHANNEL (the poll's own port traffic takes microseconds; a sample lasts 22.7 us)
  integer subq_k = 0;
`ifndef NO_CD
  always @(posedge clk) if (cd.exec_go && cd.cmd == 8'hA0 && cd.cdb[0] == 8'h42) subq_k <= c13_k;
`endif
  // NP2kai's reported position after k samples of a play from LBA lba0: dacurpos is the next
  // sector its mixer LOADS, and playdevaudio loads a sector (dacurpos++) before mixing its first
  // sample (ideio.c), so after k samples dacurpos = lba0 + ceil(k / 588). The output sample is
  // counted a fraction of a sample after the ring hands it over, so within 3 samples of a
  // sector boundary both neighbours are accepted; everywhere else the value is exact.
  function automatic integer np2_pos_lo(input integer lba0, input integer k);
    np2_pos_lo = lba0 + ((k < 3 ? 0 : k - 3) + 587) / 588;
  endfunction
  function automatic integer np2_pos_hi(input integer lba0, input integer k);
    np2_pos_hi = lba0 + (k + 3 + 587) / 588;
  endfunction

  // THE OSD's EJECT, as z486_mister.sv wires it in a --cdrom build: every hps_io slot goes through
  // pc9821_mount_eject #(.N(HPS_VDNUM = 5)), and slot 4's eject_req is status[11] ("T[11],Eject
  // CD-ROM"). The bench's host drives slot 4 only (img_mounted / img_size are hps_io's). With
  // -DNO_CD_EJECT the eject is tied off - the pre-change top, where slot 4 had no eject - and C15
  // fails at its first check.
  reg         osd_eject_cd = 0;
  wire [4:0]  me_mounted;
  wire [63:0] me_size;
`ifdef NO_CD_EJECT
  wire [4:0]  me_eject = 5'b00000;
`else
  wire [4:0]  me_eject = {osd_eject_cd, 4'b0000};
`endif
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_mount_eject #(.N(5)) mount_eject (
      .clk(clk), .hps_mounted({img_mounted, 4'b0000}), .hps_size(img_size), .hps_readonly(1'b0),
      .eject_req(me_eject), .img_mounted(me_mounted), .img_size(me_size), .img_readonly()
  );
  /* verilator lint_on PINCONNECTEMPTY */

`ifndef NO_CD
  pc9821_atapi #(.AUDIO_EN(1'b1), .LOG_EN(1'b1), .LOG_CLK_HZ(100_000)) cd (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(cd_dout),
      .io_own(cd_own), .irq(cd_irq),
      .img_mounted(me_mounted[4]), .img_size(me_size),
      .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_ack(sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .cdda_req(cdda_req_mux), .cdda_req4(cdda_req4_mux), .cdda_played(cdda_played_mux),
      .cdda_flush(cdda_flush), .cdda_wr(cdda_wr), .cdda_data(cdda_data),
      .log_byte(log_byte), .log_we(log_we), .log_accept(1'b1)
  );
`else
  assign cd_dout = 8'hFF; assign cd_own = 1'b0; assign cd_irq = 1'b0;
  assign sd_lba = 32'd0; assign sd_blk_cnt = 6'd0; assign sd_rd = 1'b0;
  assign cdda_wr = 1'b0; assign cdda_data = 32'd0;
  assign log_byte = 8'h00; assign log_we = 1'b0;
`endif
  // the drive's command log (LOG_EN), every byte as the UART FIFO would take it
  byte unsigned logq[$];
  always @(posedge clk) if (log_we) logq.push_back(log_byte);

  task automatic fail(input string msg);
    begin
      errors = errors + 1;
      $display("FAIL: %s", msg);
    end
  endtask

  // ==== the images ====
  localparam integer ISO_SECS = 20;
  localparam integer PCD_SECS = 30;   // track 1 data 0..9, track 2 audio 10..19, track 3 20..29
  // The 2048 user bytes of data sector L, and the 2352 bytes of audio sector L.
  function automatic [7:0] dbyte(input integer l, input integer i);
    dbyte = 8'((i ^ (i >> 8) * 29) + l * 13 + 1);
  endfunction
  // disc_id tells two audio discs apart (C24 mounts a second disc over a playing one)
  integer disc_id = 0;
  function automatic [7:0] abyte(input integer l, input integer i);
    abyte = 8'(l * 91 + i * 7 + 3 + (i >> 8) + disc_id * 53);
  endfunction
  function automatic [7:0] bcd8(input integer v);
    bcd8 = 8'(((v / 10) << 4) | (v % 10));
  endfunction
  byte img [];
  integer pcd_mode = 0;
  integer pcd_secs = PCD_SECS;   // C20 mounts a longer PCD (more audio sectors) by raising this
  task automatic make_iso;
    begin
      img = new[ISO_SECS * 2048];
      for (int l = 0; l < ISO_SECS; l++)
        for (int i = 0; i < 2048; i++) img[l * 2048 + i] = dbyte(l, i);
      pcd_mode = 0;
    end
  endtask
  task automatic pcd_entry(input integer e, input [7:0] ctrl, input integer lba);
    integer f;
    begin
      img[16 + 4 * e] = ctrl;
      img[16 + 4 * e + 1] = 8'(lba); img[16 + 4 * e + 2] = 8'(lba >> 8);
      img[16 + 4 * e + 3] = 8'(lba >> 16);
      img[512 + 4 * e] = 8'(lba >> 24); img[512 + 4 * e + 1] = 8'(lba >> 16);
      img[512 + 4 * e + 2] = 8'(lba >> 8); img[512 + 4 * e + 3] = 8'(lba);
      f = lba + 150;
      img[1024 + 4 * e] = 0; img[1024 + 4 * e + 1] = 8'(f / 4500);
      img[1024 + 4 * e + 2] = 8'((f / 75) % 60); img[1024 + 4 * e + 3] = 8'(f % 75);
      img[1536 + 4 * e] = 0; img[1536 + 4 * e + 1] = bcd8(f / 4500);
      img[1536 + 4 * e + 2] = bcd8((f / 75) % 60); img[1536 + 4 * e + 3] = bcd8(f % 75);
    end
  endtask
  task automatic make_pcd;
    integer base;
    begin
      img = new[(pcd_secs + 1) * 2352];
      foreach (img[k]) img[k] = 0;
      img[0] = "P"; img[1] = "C"; img[2] = "9"; img[3] = "8";
      img[4] = "C"; img[5] = "D"; img[6] = "0"; img[7] = "1";
      img[8] = 3; img[9] = 1;
      img[12] = 8'(pcd_secs); img[13] = 8'(pcd_secs >> 8);
      pcd_entry(0, 8'h14, 0); pcd_entry(1, 8'h10, 10); pcd_entry(2, 8'h10, 20);
      pcd_entry(3, 8'h10, pcd_secs);
      for (int l = 0; l < pcd_secs; l++) begin
        base = (l + 1) * 2352;
        if (l < 10) begin
          img[base] = 0; for (int i = 1; i < 11; i++) img[base + i] = 8'hFF; img[base + 11] = 0;
          img[base + 15] = 1;
          for (int i = 0; i < 2048; i++) img[base + 16 + i] = dbyte(l, i);
        end else
          for (int i = 0; i < 2352; i++) img[base + i] = abyte(l, i);
      end
      pcd_mode = 1;
    end
  endtask

  // C28: n raw 2352-byte sectors in the ECMA-130 layout - the 12-byte sync, the header (BCD
  // M:S:F of LBA + 150, the MODE byte), then MODE1's 2048 user bytes at +16, or MODE2 form 1's
  // 8-byte subheader (submode 0x08, data, twice) and the user bytes at +24 - followed by `extra`
  // filler bytes. EDC/ECC and filler are 0xE5, never user data.
  localparam integer RAW_SECS = 20;
  task automatic make_raw(input integer n, input integer mode, input integer extra);
    integer base, f, u;
    begin
      img = new[n * 2352 + extra];
      foreach (img[k]) img[k] = 8'hE5;
      for (int l = 0; l < n; l++) begin
        base = l * 2352;
        img[base] = 0; for (int i = 1; i < 11; i++) img[base + i] = 8'hFF; img[base + 11] = 0;
        f = l + 150;
        img[base + 12] = bcd8(f / 4500); img[base + 13] = bcd8((f / 75) % 60);
        img[base + 14] = bcd8(f % 75); img[base + 15] = 8'(mode);
        u = (mode == 2) ? 24 : 16;
        if (mode == 2) begin
          for (int i = 16; i < 24; i++) img[base + i] = 8'h00;
          img[base + 18] = 8'h08; img[base + 22] = 8'h08;
        end
        for (int i = 0; i < 2048; i++) img[base + u + i] = dbyte(l, i);
      end
      pcd_mode = 0;
    end
  endtask
  task automatic mount_img;
    begin
      img_size = img.size();
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);   // the header fetch and the lead-out MSF
    end
  endtask

  // ==== hps_io's side of slot 4 ====
  integer host_reqs = 0;
  integer host_sec_reqs = 0;   // C24/C25: requests for anything but the header (LBA 0)
  integer host_delay = 6;   // clk cycles from the request to the ack (C13 models the ARM's latency)
  bit host_foreign = 0;     // C16: stream another slot's words (acks low) before serving the request
  // C26: hold the acknowledge of the next SECTOR request (not the header) after its last word,
  // and drop it - which completes the fetch (e_done) - in the very cycle the drive executes a
  // packet with opcode hold_op (exec_go). With hold_op 0 the case itself drops it, on the same
  // falling edge that raises a mount (the case clears host_hold there).
  bit       host_hold = 0;
  reg [7:0] hold_op = 8'h00;
  integer   host_last_lba = -1;   // C27: the slot LBA of the latest sector request
  always @(negedge clk) begin : host
    reg [31:0] lba; integer words;
    if (sd_rd && !sd_ack) begin
      lba = sd_lba; words = (sd_blk_cnt + 1) * 256;
      host_reqs = host_reqs + 1;
      if (lba != 0) begin host_sec_reqs = host_sec_reqs + 1; host_last_lba = lba; end
      repeat (host_delay) @(negedge clk);
      if (host_foreign) begin
        // hps_io still serving ANOTHER slot (the hard disk's): its words on the shared bus,
        // with this slot's sd_ack low.
        for (int w = 0; w < 512; w++) begin
          sd_buff_addr = 13'(w); sd_buff_dout = 16'hD15C ^ 16'(w);
          sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0; @(negedge clk);
        end
        host_foreign = 0;
      end
      sd_ack = 1;
      repeat (3) @(negedge clk);
      for (int w = 0; w < words; w++) begin
        longint o; o = longint'(lba) * 512 + w * 2;
        sd_buff_addr = 13'(w);
        sd_buff_dout = {(o + 1 < img.size()) ? img[o + 1] : 8'h00, (o < img.size()) ? img[o] : 8'h00};
        sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0; @(negedge clk);
      end
      repeat (2) @(negedge clk);
`ifndef NO_CD
      if (host_hold && lba != 0) begin : held
        integer n;
        n = 0;
        while (host_hold && !(hold_op != 8'h00 && cd.exec_go && cd.cmd == 8'hA0 &&
                              cd.cdb[0] == hold_op) && n < 20000000) begin
          @(negedge clk); n++;
        end
        if (n >= 20000000) $fatal(1, "TB_PC9821_ATAPI: FAIL - C26: the held fetch's event never came");
        host_hold = 0;
      end
`endif
      sd_ack = 0;
    end
  end

  task automatic mount(input bit pcd);
    begin
      if (pcd) make_pcd; else make_iso;
      img_size = img.size();
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);   // the header fetch and (ISO) the lead-out MSF
    end
  endtask
  // C19: an ISO of exactly n sectors. The mount's header is the drive's own iso_word for an ISO,
  // so the image's content is irrelevant; only its SIZE reaches the converter (iso_cap -> the
  // lead-out's frames). Verilator zero-fills the dynamic array.
  task automatic mount_iso_sectors(input integer n);
    begin
      img = new[n * 2048];
      pcd_mode = 0;
      img_size = img.size();
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);
    end
  endtask

  // ==== the CD-DA port ====
  integer cdda_n = 0;
  // C18: the IRQ9 line as pc9821_system builds it (the two banks' INTRQ ORed, as MAME's
  // INPUT_MERGER_ANY_HIGH "ideirq" does), and its rising edges - what the edge-latched PIC sees.
  wire    irq9_line = ata_irq | cd_irq;
  reg     irq9_q = 1'b0;
  integer irq9_rises = 0;
  always @(posedge clk) begin
    irq9_q <= irq9_line;
    if (irq9_line && !irq9_q) irq9_rises <= irq9_rises + 1;
  end
  // C17's own window of the stream (cdda_log stops at 16384 entries, which earlier cases use).
  reg  [31:0] c17_log [0:4095];
  integer     c17_n = 0;
  reg         c17_on = 0;
  always @(posedge clk) if (c17_on && cdda_wr) begin
    if (c17_n < 4096) c17_log[c17_n] <= cdda_data;
    c17_n <= c17_n + 1;
  end
  // C27: the first CD-DA word written once c27_arm is raised (cdda_log stops at 16384 entries)
  bit        c27_arm = 0, c27_got = 0;
  reg [31:0] c27_w = 0;
  always @(posedge clk) if (c27_arm && !c27_got && cdda_wr) begin c27_w = cdda_data; c27_got = 1; end
  reg [31:0] cdda_log [0:16383];
  always @(posedge clk) if (cdda_wr) begin
    if (cdda_n < 16384) cdda_log[cdda_n] <= cdda_data;
    cdda_n <= cdda_n + 1;
  end

  // ==== port access (one strobe cycle, the iobus's shape) ====
  task automatic wr(input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_din = d; io_wr = 1;
      @(negedge clk); io_wr = 0;
    end
  endtask
  task automatic rd(input [15:0] a, output [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_rd = 1; #1 d = dout;
      @(negedge clk); io_rd = 0;
    end
  endtask
  task automatic rdw(output [15:0] w);
    reg [7:0] lo, hi;
    begin rd(16'h0640, lo); rd(16'h0641, hi); w = {hi, lo}; end
  endtask
  task automatic expect8(input [15:0] a, input [7:0] want, input string what);
    reg [7:0] got;
    begin
      rd(a, got);
      if (got !== want) begin
        errors = errors + 1;
        $display("FAIL: %s: port %04x read %02x, want %02x", what, a, got, want);
      end
    end
  endtask
  // Wait for !BSY by polling the alternate status (no interrupt side effect); bounded.
  task automatic wait_notbusy(input string what);
    reg [7:0] s; integer n;
    begin
      n = 0;
      do begin rd(16'h074C, s); n = n + 1; end while (s[7] && n < 20000);
      if (s[7]) $fatal(1, "TB_PC9821_ATAPI: FAIL - %s: BSY never cleared", what);
    end
  endtask
  task automatic sel_cd;
    begin wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0); end
  endtask
  // the CD's interrupt, as the IDE ROM's ISR takes it: wait for the line (bounded), then the
  // STATUS read that acknowledges it
  reg [7:0] isr_err;
  task automatic wait_irq(output [7:0] st, input string what);
    integer n;
    begin
      n = 0;
      while (!cd_irq && n < 200000) begin @(negedge clk); n++; end
      if (!cd_irq) $fatal(1, "TB_PC9821_ATAPI: FAIL - %s: no interrupt", what);
      // the ROM's ISR (BANK3@0x1A1C-0x1A27): ERROR first, then STATUS
      rd(16'h0642, isr_err);
      rd(16'h064E, st);
    end
  endtask

  // ==== a packet command, polled; the reply lands in rbuf[0..rlen-1] ====
  byte rbuf [0:8191];
  integer rlen;
  reg [7:0] pk_status;
  task automatic packet(input byte c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, input string what);
    reg [7:0] s, ir, bl, bh; reg [15:0] w; integer cnt, phases;
    begin
      byte cdb [0:11];
      cdb = '{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, 8'h00, 8'h00};
      rlen = 0;
      wr(16'h064E, 8'hA0);
      rd(16'h074C, s);
      if (s !== 8'h58) begin errors++; $display("FAIL: %s: packet phase status %02x, want 58", what, s); end
      rd(16'h0644, ir);
      if (ir !== 8'h01) begin errors++; $display("FAIL: %s: packet phase 0x644 %02x, want 01 (CoD)", what, ir); end
      for (int k = 0; k < 6; k++) begin
        wr(16'h0640, cdb[2 * k]); wr(16'h0641, cdb[2 * k + 1]);
      end
      phases = 0;
      forever begin
        wait_notbusy(what);
        rd(16'h074C, s);
        if (!s[3]) break;
        rd(16'h0644, ir); rd(16'h0648, bl); rd(16'h064A, bh);
        if (ir !== 8'h02) begin errors++; $display("FAIL: %s: data phase 0x644 %02x, want 02", what, ir); end
        cnt = {bh, bl};
        for (int k = 0; k < (cnt + 1) / 2; k++) begin
          rdw(w);
          if (rlen < 8190) begin rbuf[rlen] = w[7:0]; rbuf[rlen + 1] = w[15:8]; end
          rlen = rlen + 2;
        end
        rlen = rlen - (cnt & 1);
        phases++;
        if (phases > 64) $fatal(1, "TB_PC9821_ATAPI: FAIL - %s: runaway data phases", what);
      end
      rd(16'h064E, pk_status);
    end
  endtask
  task automatic expect_done(input string what);
    reg [7:0] ir;
    begin
      if (pk_status !== 8'h50) begin errors++; $display("FAIL: %s: completion status %02x, want 50", what, pk_status); end
      rd(16'h0644, ir);
      if (ir !== 8'h03) begin errors++; $display("FAIL: %s: completion 0x644 %02x, want 03", what, ir); end
    end
  endtask
  task automatic expect_check(input [3:0] key, input [7:0] code, input string what);
    begin
      if (pk_status !== 8'h51) begin errors++; $display("FAIL: %s: status %02x, want 51 (CHK)", what, pk_status); end
      packet(8'h03, 0, 0, 0, 8'd18, 0, 0, 0, 0, 0, {what, " / REQUEST SENSE"});
      if (rlen != 18 || rbuf[0] !== 8'h70 || rbuf[2][3:0] !== key || rbuf[12] !== code) begin
        errors++;
        $display("FAIL: %s: sense len %0d key %x asc %02x, want 18/%x/%02x", what, rlen,
                 rbuf[2], rbuf[12], key, code);
      end
      // The rest of NP2kai's fixed-format page (atapicmd.c case 0x03: `ZeroMemory(drv->buf, 18)`,
      // `buf[7] = 11; // length`, buf[13] = asc >> 8, which is 0 for every ASC this drive
      // reports): the additional length and every other byte zero.
      else for (int k = 1; k < 18; k++)
        if (k != 2 && k != 12 && rbuf[k] !== ((k == 7) ? 8'h0B : 8'h00)) begin
          errors++;
          $display("FAIL: %s: sense byte %0d = %02x, want %02x", what, k, rbuf[k],
                   (k == 7) ? 8'h0B : 8'h00);
          break;
        end
    end
  endtask
  task automatic expect_bytes(input byte want [$], input string what);
    begin
      if (rlen != want.size()) begin errors++; $display("FAIL: %s: %0d bytes, want %0d", what, rlen, want.size()); end
      else foreach (want[k]) if (rbuf[k] !== want[k]) begin
        errors++; $display("FAIL: %s: byte %0d = %02x, want %02x", what, k, rbuf[k], want[k]);
        break;
      end
    end
  endtask

  // A format-1 READ SUB-CHANNEL reply in NEC BCD whose position is NP2kai's: atapicmd.c
  // readsubch takes `pos = dacurpos`, adds `rand() & 7` while paused or completed (0x12/0x13),
  // finds the track holding pos and reports pos + 150 absolute and pos - track start relative.
  // So a report at `base` with that jitter lies in base..base+7, and its track, absolute and
  // relative fields agree on one pos. Returns the relative frame count (-1 on a failure).
  function automatic integer bcd2i(input byte b); return (b >> 4) * 10 + (b & 15); endfunction
  task automatic expect_subq_np2(input byte st, input integer base, input integer jit,
                                 input string what, output integer rel);
    integer a, r, pos, trk, tstart;
    begin
      rel = -1;
      // bcd2i accepts any nibble, so a binary 0x0A would read as 10: every MSF byte must be
      // BCD first (atapicmd.c storemsf's isBCD form in NEC mode).
      for (int k = 9; k <= 15; k++) if (k != 12)
        if (rbuf[k][3:0] > 4'd9 || rbuf[k][7:4] > 4'd9)
          fail($sformatf("%s: MSF byte %0d = %02x is not BCD", what, k, rbuf[k]));
      a = bcd2i(rbuf[9]) * 4500 + bcd2i(rbuf[10]) * 75 + bcd2i(rbuf[11]);
      r = bcd2i(rbuf[13]) * 4500 + bcd2i(rbuf[14]) * 75 + bcd2i(rbuf[15]);
      pos = a - 150;
      trk = (pos >= 20) ? 3 : (pos >= 10) ? 2 : 1;     // make_pcd's tracks: LBA 0, 10, 20
      tstart = (trk - 1) * 10;
      if (rlen != 16 || rbuf[1] !== st || rbuf[3] !== 8'h12 || rbuf[4] !== 8'h01)
        fail($sformatf("%s: header %02x %02x %02x %02x (%0d bytes), want 00 %02x 00 12 / 01",
                       what, rbuf[0], rbuf[1], rbuf[2], rbuf[3], rlen, st));
      else if (pos < base || pos > base + jit)
        fail($sformatf("%s: position %0d, want %0d..%0d (dacurpos + rand() & 7)", what, pos, base, base + jit));
      else if (rbuf[6] !== 8'(trk) || rbuf[7] !== 8'h01 || r != pos - tstart ||
               rbuf[5] !== ((trk == 1) ? 8'h14 : 8'h10))
        fail($sformatf("%s: track %02x index %02x ctrl %02x rel %0d, want track %0d index 1 rel %0d",
                       what, rbuf[6], rbuf[7], rbuf[5], r, trk, pos - tstart));
      else rel = r;
    end
  endtask

  // the data of a READ(10), checked against the image's sectors
  task automatic read10(input integer lba, input integer n, input string what);
    begin
      packet(8'h28, 0, 8'(lba >> 24), 8'(lba >> 16), 8'(lba >> 8), 8'(lba), 0, 8'(n >> 8), 8'(n), 0, what);
      expect_done(what);
      if (rlen != n * 2048) begin errors++; $display("FAIL: %s: %0d bytes, want %0d", what, rlen, n * 2048); end
      else for (int s = 0; s < n; s++) for (int i = 0; i < 2048; i++)
        if (rbuf[s * 2048 + i] !== dbyte(lba + s, i)) begin
          errors++; $display("FAIL: %s: sector %0d byte %0d = %02x, want %02x", what, lba + s, i,
                             rbuf[s * 2048 + i], dbyte(lba + s, i));
          return;
        end
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] b;
  reg [15:0] w;
  byte    c30_cdb [0:11];   // C30's READ(10) packet
  integer c30_reqs;
  initial begin
    repeat (8) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);

    // ==== C0: the Xe10 IDE ROM's probe of bank 1's master (BANK3@0x0A0A, at power-on) ====
    // The ROM's own steps, in its order: the bank select (0x0D0D); the pre-reset presence test
    // (0x0D39: STATUS with bit 1 masked must be 0x00, then 0x64A = 0xEB and 0x648 = 0x14 mark
    // the unit ATAPI, then ERROR must read 0x01); IDENTIFY DEVICE (table entry 0x0A = 0xEC),
    // whose ERR + ABRT sends an ATAPI unit to 0x0A9B; there each command's ready poll (0x10AA:
    // for an ATAPI unit STATUS with bits 0/1 masked must be 0x00 or 0x50, anything else with
    // BSY/DRDY/DSC set gets an SRST through 0x74C (0x1132, which again requires ERROR 0x01) and a
    // retry (0x0C70)); then PACKET (0x1881: byte count 0x0800, DRQ with BSY clear, six words,
    // interrupt-driven phases) carrying INQUIRY with allocation 2, whose byte 0 & 0x3F must be 5
    // for the ROM to record a CD-ROM (0x0AF5-0x0B09).
    begin
      reg [7:0] st; reg [15:0] wd; integer tries, cnt;
      wr(16'h0432, 8'h01);
      rd(16'h064E, st);
      if ((st & 8'hFD) !== 8'h00) fail("C0 presence: STATUS at power-on is not 0x00");
      expect8(16'h064A, 8'hEB, "C0 presence: 0x64A");
      expect8(16'h0648, 8'h14, "C0 presence: 0x648");
      expect8(16'h0642, 8'h01, "C0 presence: ERROR must be 0x01 (the ROM's master test)");
      wr(16'h064C, 8'hA0);
      rd(16'h064E, st);
      if ((st & 8'hFC) !== 8'h00 && (st & 8'hFC) !== 8'h50) fail("C0 the ready poll before IDENTIFY failed");
      wr(16'h064E, 8'hEC);
      wait_irq(st, "C0 IDENTIFY DEVICE");
      if (!st[0]) fail("C0 IDENTIFY DEVICE did not end with ERR");
      if (isr_err !== 8'h04) fail("C0 IDENTIFY DEVICE: the ISR's ERROR read is not ABRT");
      // the ready poll, with the ROM's SRST + retry
      tries = 0;
      rd(16'h064E, st);
      while ((st & 8'hFC) !== 8'h00 && (st & 8'hFC) !== 8'h50 && tries < 3) begin
        wr(16'h074C, 8'h06); repeat (20) @(negedge clk); wr(16'h074C, 8'h00);
        cnt = 0;
        do begin rd(16'h064E, st); cnt++; end while (st[7] && cnt < 1000);
        expect8(16'h0642, 8'h01, "C0 the ROM's SRST: ERROR must read 0x01");
        rd(16'h064E, st);
        tries++;
      end
      if ((st & 8'hFC) !== 8'h00 && (st & 8'hFC) !== 8'h50) fail("C0 the ready poll never passed");
      wr(16'h0648, 8'h00); wr(16'h064A, 8'h08); wr(16'h064C, 8'hA0); wr(16'h064E, 8'hA0);
      cnt = 0;
      do begin rd(16'h064E, st); cnt++; end while ((st & 8'h88) !== 8'h08 && cnt < 1000);
      if ((st & 8'h88) !== 8'h08) fail("C0 PACKET: no DRQ for the command packet");
      wr(16'h0640, 8'h12); wr(16'h0641, 8'h00); wr(16'h0640, 8'h00); wr(16'h0641, 8'h00);
      wr(16'h0640, 8'h02); wr(16'h0641, 8'h00); wr(16'h0640, 8'h00); wr(16'h0641, 8'h00);
      wr(16'h0640, 8'h00); wr(16'h0641, 8'h00); wr(16'h0640, 8'h00); wr(16'h0641, 8'h00);
      wait_irq(st, "C0 INQUIRY data phase");
      if (!st[3]) fail("C0 INQUIRY: the first interrupt has no DRQ");
      rdw(wd);
      if (wd[5:0] !== 6'h05) fail("C0 INQUIRY byte 0 & 0x3F is not 5 (the ROM records no CD-ROM)");
      wait_irq(st, "C0 INQUIRY completion");
      if ((((st & 8'hF1) ^ 8'h50) & 8'hEF) !== 8'h00) fail("C0 INQUIRY completion status is not the ROM's success");
    end
    if (errors != 0) $fatal(1, "TB_PC9821_ATAPI: FAIL - the IDE ROM's probe of the CD fails (%0d errors)", errors);
    wr(16'h074C, 8'h04); wr(16'h074C, 8'h00);   // back to a reset drive for C1

    // ==== C1: the signature on bank 1's master; DEV 1 is an absent slave; the disk on bank 0 ====
    wr(16'h064E, 8'h08); rd(16'h064E, b);         // DEVICE RESET: the signature again
    sel_cd;
    expect8(16'h064E, 8'h00, "C1 STATUS after DEVICE RESET");
    expect8(16'h0644, 8'h01, "C1 sector count");
    expect8(16'h0646, 8'h01, "C1 sector number");
    expect8(16'h0648, 8'h14, "C1 signature low");
    expect8(16'h064A, 8'hEB, "C1 signature high");
    if (errors != 0) $fatal(1, "TB_PC9821_ATAPI: FAIL - no ATAPI signature on bank 1's master (%0d errors)", errors);
    wr(16'h064C, 8'hB0);
    expect8(16'h064E, 8'h00, "C1 bank 1 device 1 is absent: STATUS 0x00");
    expect8(16'h074C, 8'h00, "C1 bank 1 device 1 is absent: ALTERNATE STATUS 0x00");
    wr(16'h064E, 8'hA1);
    expect8(16'h074C, 8'h00, "C1 a command for the absent slave is not executed");
    wr(16'h0432, 8'h00); wr(16'h064C, 8'hA0);
    expect8(16'h064E, 8'h50, "C1 bank 0's master is the hard disk");
    expect8(16'h0648, 8'h00, "C1 the disk's cylinder low");
    wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0);
    // 0x0433 is the per-bank interrupt-pending port, not NP2kai's connect flag: with nothing
    // pending it reads 00 at every bank (docs/probes/KIT1-XE10-IDE1.TXT:4-14 `433=00`).
    begin : c1_ack reg [7:0] st; rd(16'h064E, st); end   // the CD's status read: acknowledges anything pending
    expect8(16'h0433, 8'h00, "C1 0x0433 reads 00 at bank 1 with nothing pending");

    // ==== C2: DEVICE RESET and SRST ====
    sel_cd;
    wr(16'h064E, 8'h08);
    if (!cd_irq) fail("C2 DEVICE RESET raised no interrupt");
    // Bank 1's pending interrupt is 0x0433 bit 1 (qemu-pc98 hw/ide/pc98-ide.c:203,
    // `ret = s->irq_levels & 0x03;`), at either bank selection.
    expect8(16'h0433, 8'h02, "C2 0x0433 bit 1: the CD's interrupt pending");
    wr(16'h0432, 8'h00);
    expect8(16'h0433, 8'h02, "C2 0x0433 bit 1 with bank 0 selected");
    wr(16'h0432, 8'h01);
    expect8(16'h0642, 8'h01, "C2 ERROR after DEVICE RESET");
    expect8(16'h064E, 8'h00, "C2 STATUS after DEVICE RESET");
    if (cd_irq) fail("C2 the STATUS read did not lower the interrupt");
    expect8(16'h0433, 8'h00, "C2 0x0433 clears with the CD's status read");
    expect8(16'h0648, 8'h14, "C2 signature low after DEVICE RESET");
    expect8(16'h064A, 8'hEB, "C2 signature high after DEVICE RESET");
    wr(16'h074C, 8'h04); wr(16'h074C, 8'h00);
    expect8(16'h074C, 8'h51, "C2 STATUS after SRST (ideio_o74c: DRDY|DSC|ERR)");
    expect8(16'h0642, 8'h01, "C2 ERROR after SRST");
    expect8(16'h0648, 8'h14, "C2 signature low after SRST");
    expect8(16'h064A, 8'hEB, "C2 signature high after SRST");

    // ==== C3: IDENTIFY DEVICE aborts; IDENTIFY PACKET DEVICE ====
    wr(16'h0648, 8'h00); wr(16'h064A, 8'h00);
    wr(16'h064E, 8'hEC);
    expect8(16'h064E, 8'h41, "C3 IDENTIFY DEVICE aborts (DRDY|ERR)");
    expect8(16'h0642, 8'h04, "C3 ABRT");
    expect8(16'h0648, 8'h14, "C3 the abort leaves the signature (drvreset)");
    expect8(16'h064A, 8'hEB, "C3 the abort leaves the signature (drvreset)");
    wr(16'h064E, 8'hA1);
    wait_notbusy("C3 IDENTIFY PACKET");
    expect8(16'h074C, 8'h58, "C3 IDENTIFY PACKET data phase");
    begin
      reg [15:0] id [0:255];
      for (int k = 0; k < 256; k++) rdw(id[k]);
      if (id[0] !== 16'h8580) fail("C3 word 0 is not 0x8580");
      if ({id[27], id[28], id[29], id[30], id[31], id[32], id[33], id[34], id[35], id[36]} !==
          {"NE", "C ", "CD", "-R", "OM", " D", "RI", "VE", ":9", "8 "})
        fail("C3 model is not \"NEC CD-ROM DRIVE:98\"");
      if (id[82] !== 16'h0214 || id[49] !== 16'h0200) fail("C3 words 49/82");
    end
    expect8(16'h064E, 8'h50, "C3 after the page: DRDY|DSC, no DRQ");

    // ==== C4: INQUIRY, the packet protocol ====
    packet(8'h12, 0, 0, 0, 8'd36, 0, 0, 0, 0, 0, "C4 INQUIRY");
    expect_done("C4 INQUIRY");
    expect_bytes('{8'h05, 8'h80, 8'h00, 8'h21, 8'h1F, 8'h00, 8'h00, 8'h00,
                   "N", "E", "C", " ", " ", " ", " ", " ",
                   "C", "D", "-", "R", "O", "M", " ", "D", "R", "I", "V", "E", ":", "9", "8", " ",
                   "1", ".", "0", " "}, "C4 INQUIRY bytes");
    packet(8'h12, 0, 0, 0, 8'd8, 0, 0, 0, 0, 0, "C4 INQUIRY alloc 8");
    if (rlen != 8) fail("C4 INQUIRY's allocation length did not cap the reply");

    // ==== C5: no medium ====
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C5 TUR, no medium");
    expect_check(4'h2, 8'h3A, "C5 TUR, no medium");

    // ==== C6: an ISO ====
    mount(0);
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C6 first TUR after the mount");
    expect_check(4'h2, 8'h3A, "C6 first TUR after the mount (not NEC mode: 0x3A)");
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C6 second TUR");
    expect_done("C6 second TUR");
    packet(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C6 READ CAPACITY");
    expect_bytes('{8'h00, 8'h00, 8'h00, 8'(ISO_SECS), 8'h00, 8'h00, 8'h08, 8'h00}, "C6 READ CAPACITY");
    read10(3, 2, "C6 READ(10) ISO 3+2");
    read10(ISO_SECS - 1, 1, "C6 READ(10) ISO last sector");
    packet(8'h28, 0, 0, 0, 0, 8'(ISO_SECS - 1), 0, 0, 2, 0, "C6 READ(10) across the end");
    if (rlen != 2048) fail("C6 READ across the end did not deliver its in-range sector first");
    expect_check(4'h5, 8'h21, "C6 READ(10) across the end");
    packet(8'h43, 0, 0, 0, 0, 0, 0, 0, 8'd100, 0, "C6 READ TOC LBA");
    expect_done("C6 READ TOC LBA");
    expect_bytes('{8'h00, 8'h12, 8'h01, 8'h01,
                   8'h00, 8'h14, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                   8'h00, 8'h14, 8'hAA, 8'h00, 8'h00, 8'h00, 8'h00, 8'(ISO_SECS)}, "C6 READ TOC LBA");
    packet(8'h43, 8'h02, 0, 0, 0, 0, 0, 0, 8'd100, 0, "C6 READ TOC MSF");
    expect_bytes('{8'h00, 8'h12, 8'h01, 8'h01,
                   8'h00, 8'h14, 8'h01, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00,
                   8'h00, 8'h14, 8'hAA, 8'h00, 8'h00, 8'h00, 8'h02, 8'(ISO_SECS)}, "C6 READ TOC MSF");

    // ==== C7: a PCD, NEC mode ====
    packet(8'h5A, 0, 8'h0F, 0, 0, 0, 0, 0, 8'd24, 0, "C7 MODE SENSE page 0x0F");
    expect_done("C7 MODE SENSE 0x0F");
    expect_bytes('{8'h00, 8'h16, 8'h01, 0, 0, 0, 0, 0,
                   8'h0F, 8'h10, 0, 0, 8'h11, 8'h18, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
                 "C7 MODE SENSE 0x0F (ISO: data only)");
    mount(1);
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C7 first TUR after the mount");
    expect_check(4'h2, 8'h28, "C7 first TUR after the mount (NEC mode: 0x28)");
    packet(8'h5A, 0, 8'h2A, 0, 0, 0, 0, 0, 8'd28, 0, "C7 MODE SENSE page 0x2A");
    expect_bytes('{8'h00, 8'h1A, 8'h03, 0, 0, 0, 0, 0,
                   8'h2A, 8'h12, 8'h00, 8'h00, 8'h71, 8'h65, 8'h29, 8'h07,
                   8'h02, 8'hC2, 8'h00, 8'hFF, 8'h00, 8'h80, 8'h02, 8'hC2, 0, 0, 0, 0},
                 "C7 MODE SENSE 0x2A (data + audio)");
    packet(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C7 READ CAPACITY");
    expect_bytes('{0, 0, 0, 8'(PCD_SECS), 0, 0, 8'h08, 0}, "C7 READ CAPACITY");
    read10(2, 3, "C7 READ(10) PCD 2+3");
    packet(8'h43, 0, 0, 0, 0, 0, 0, 0, 8'd100, 0, "C7 READ TOC LBA");
    expect_bytes('{8'h00, 8'h22, 8'h01, 8'h03,
                   0, 8'h14, 8'h01, 0, 0, 0, 0, 0,
                   0, 8'h10, 8'h02, 0, 0, 0, 0, 8'd10,
                   0, 8'h10, 8'h03, 0, 0, 0, 0, 8'd20,
                   0, 8'h10, 8'hAA, 0, 0, 0, 0, 8'(PCD_SECS)}, "C7 READ TOC LBA");
    packet(8'h43, 8'h02, 0, 0, 0, 0, 8'd2, 0, 8'd100, 0, "C7 READ TOC MSF (BCD) from track 2");
    expect_bytes('{8'h00, 8'h1A, 8'h01, 8'h03,
                   0, 8'h10, 8'h02, 0, 0, 8'h00, 8'h02, bcd8(10),
                   0, 8'h10, 8'h03, 0, 0, 8'h00, 8'h02, bcd8(20),
                   0, 8'h10, 8'hAA, 0, 0, 8'h00, 8'h02, bcd8(PCD_SECS)},
                 "C7 READ TOC MSF BCD");
    packet(8'h43, 0, 0, 0, 0, 0, 8'd5, 0, 8'd100, 0, "C7 READ TOC from track 5");
    if (pk_status !== 8'h51) fail("C7 READ TOC past the last track did not answer CHECK");

    // ==== C8: CD-DA ====
    packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C8 SUB-CHANNEL before play");
    // The reported medium changes stopped the player (atapicmd.c TUR: daflag 0x13, position 0),
    // so the status is "completed" at track 1, 00:02:00, in BCD (NEC mode).
    // (plus NP2kai's 0..7-frame wander at 0x13: expect_subq_np2)
    begin
      integer rl;
      expect_subq_np2(8'h13, 0, 7, "C8 SUB-CHANNEL before play (stopped at 0)", rl);
    end
    begin
      integer n0, f0, f1;
      f0 = 10 + 150; f1 = 13 + 150;
      n0 = cdda_n;
      packet(8'h47, 0, 0, bcd8(f0 / 4500), bcd8((f0 / 75) % 60), bcd8(f0 % 75),
             bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0, "C8 PLAY AUDIO MSF");
      expect_done("C8 PLAY AUDIO MSF");
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C8 SUB-CHANNEL playing");
      if (rbuf[1] !== 8'h11 || rbuf[5] !== 8'h10 || rbuf[6] !== 8'h02)
        fail("C8 SUB-CHANNEL while playing: not 0x11 in track 2");
      for (int t = 0; t < 400000 && cdda_n - n0 < 3 * 588; t++) @(negedge clk);
      repeat (20000) @(negedge clk);
      if (cdda_n - n0 != 3 * 588) begin
        errors++; $display("FAIL: C8 %0d stereo samples streamed, want %0d (3 sectors)", cdda_n - n0, 3 * 588);
      end else
        for (int s = 0; s < 3 * 588; s++) begin
          integer l, o;
          l = 10 + s / 588; o = (s % 588) * 4;
          if (cdda_log[n0 + s] !== {abyte(l, o + 3), abyte(l, o + 2), abyte(l, o + 1), abyte(l, o)}) begin
            errors++; $display("FAIL: C8 sample %0d = %08x, want {R,L} of sector %0d", s, cdda_log[n0 + s], l);
            break;
          end
        end
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C8 SUB-CHANNEL completed");
      if (rbuf[1] !== 8'h13) fail("C8 SUB-CHANNEL after the play: not 0x13 (completed)");
      // the position: absolute 13 + 150 frames, relative 3 into track 2, in BCD (NEC mode)
      // (plus NP2kai's 0..7-frame wander at 0x13: expect_subq_np2)
      begin
        integer rl;
        expect_subq_np2(8'h13, 13, 7, "C8 SUB-CHANNEL position", rl);
      end
      // PAUSE / RESUME
      cdda_req = 0;
      packet(8'h47, 0, 0, bcd8(f0 / 4500), bcd8((f0 / 75) % 60), bcd8(f0 % 75),
             bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0, "C8 PLAY again");
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C8 PAUSE");
      expect_done("C8 PAUSE");
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C8 SUB-CHANNEL paused");
      if (rbuf[1] !== 8'h12) fail("C8 SUB-CHANNEL after PAUSE: not 0x12");
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 8'h01, 0, "C8 RESUME");
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C8 SUB-CHANNEL resumed");
      if (rbuf[1] !== 8'h11) fail("C8 SUB-CHANNEL after RESUME: not 0x11");
      cdda_req = 1;
      // a READ while playing does not stop the player (atapicmd.c atapi_cmd_read)
      read10(1, 1, "C8 READ(10) while playing");
      for (int t = 0; t < 400000; t++) begin
        @(negedge clk);
        if (t % 4096 == 0) begin
          packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C8 poll");
          if (rbuf[1] == 8'h13) break;
        end
      end
      if (rbuf[1] !== 8'h13) fail("C8 the second play never completed");
    end

    // ==== C9: PATACD.SYS's unit probe (storage-expand report appendix A) ====
    begin
      integer found;
      found = -1;
      wr(16'h074C, 8'h02);   // polled: nIEN
      for (int u = 0; u < 4 && found < 0; u++) begin
        reg [7:0] s, r; reg [15:0] w0; integer ok;
        wr(16'h0432, 8'(u >> 1));
        wr(16'h064C, (u & 1) ? 8'hB0 : 8'hA0);
        rd(16'h064C, r);
        if (r[4] != u[0]) continue;          // the DEV read-back compare
        wr(16'h064E, 8'hA1);
        rd(16'h074C, s);
        for (int k = 0; k < 2000 && s[7]; k++) rd(16'h074C, s);
        if (s[0]) begin                       // the 0xEC fallback
          wr(16'h064E, 8'hEC);
          rd(16'h074C, s);
          for (int k = 0; k < 2000 && s[7]; k++) rd(16'h074C, s);
        end
        // PATACD.SYS 0x2FC/0x23E/0x33D: after the command it waits for BSY clear and checks
        // STATUS.ERR alone, then reads the 256 identify words (0xF14) WHETHER OR NOT DRQ is set;
        // word 0 = 0 is "no device" (0xF5B), anything else is a device it prints (0x1084).
        if (s[0]) continue;
        rd(16'h064E, s);
        if (s[0]) continue;
        rdw(w0);
        for (int k = 1; k < 256; k++) rdw(w);
        if ((u & 1) && w0 !== 16'h0000)
          fail($sformatf("C9 PATACD's IDENTIFY of the absent slave at bank %0d read word 0 = %04x, want 0000 (ATA-3 s.9.5.1)", u >> 1, w0));
        if (w0[15:14] != 2'b10) continue;
        packet(8'h12, 0, 0, 0, 8'd36, 0, 0, 0, 0, 0, "C9 INQUIRY");
        ok = (rbuf[0][4:0] == 5);
        wr(16'h064E, 8'h00);                  // NOP after the packet command, BSY spin
        rd(16'h074C, s);
        for (int k = 0; k < 2000 && s[7]; k++) rd(16'h074C, s);
        if (s[7]) $fatal(1, "TB_PC9821_ATAPI: FAIL - C9 NOP left the drive BSY");
        if (ok) found = u;
      end
      if (found != 2) begin errors++; $display("FAIL: C9 PATACD's probe found unit %0d, want 2 (bank 1 master)", found); end
      if (cd_irq) fail("C9 an interrupt was raised under nIEN");
    end

    // ==== C10: NEC's own drivers' probes (storage-expand report appendix A) ====
    // NECCDD.SYS: the bank presence test (0x432 <- 7, read back), bank 1's master (0x64C <-
    // 0xE0), INQUIRY's vendor + product against "NEC     CD-ROM DRIVE". NECCD.SYS: the signature
    // at the DEV the BIOS left (0) - ALTERNATE STATUS 0, 0x64A = 0xEB, 0x648 = 0x14 - after a reset.
    wr(16'h074C, 8'h00);
    wr(16'h0432, 8'h07);
    // 07 reads back 01: bit 1 without bit 5 never reads back on the machine
    // (docs/probes/KIT1-XE10-IDE1.TXT:10 `w=03 r432=01`) and bit 2 is NP2kai's 0x71 mask's
    // (`ideio.bank[(port >> 1) & 1] = dat & 0x71;`), the read-back NECCDD runs on there too.
    expect8(16'h0432, 8'h01, "C10 NECCDD: the bank register reads back 01");
    // NECCDD then selects bank 1 with 01 before any task-file access (its file offsets
    // 0x2014-0x201A: `mov al,1`, `out dx,al`, `mov dx,0x64e`): with bit 2 still set the task
    // file would read the 0x0432 read-back (docs/probes/KIT2-XE10-IDE2.TXT:8).
    expect8(16'h064E, 8'h01, "C10 0x064E with 07 latched reads the 0x0432 read-back 01");
    wr(16'h0432, 8'h01);
    wr(16'h064C, 8'hE0);
    packet(8'h12, 0, 0, 0, 8'd36, 0, 0, 0, 0, 0, "C10 NECCDD INQUIRY");
    if (rlen < 28 || {rbuf[8], rbuf[9], rbuf[10], rbuf[11], rbuf[12], rbuf[13], rbuf[14], rbuf[15],
                      rbuf[16], rbuf[17], rbuf[18], rbuf[19], rbuf[20], rbuf[21], rbuf[22], rbuf[23],
                      rbuf[24], rbuf[25], rbuf[26], rbuf[27]} !== "NEC     CD-ROM DRIVE")
      fail("C10 NECCDD: INQUIRY does not start NEC     CD-ROM DRIVE at bank 1's master");
    wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0);
    wr(16'h064E, 8'h08); rd(16'h064E, b);
    expect8(16'h074C, 8'h00, "C10 NECCD: ALTERNATE STATUS 0 at DEV 0 after a reset");
    expect8(16'h064A, 8'hEB, "C10 NECCD: 0x64A");
    expect8(16'h0648, 8'h14, "C10 NECCD: 0x648");

    // ==== C11: the command log (LOG_EN, tools/decode_cdlog.py's format) ====
    // A TEST UNIT READY on a loaded, settled medium logs CMD (0xA0, the drive's DRHD, DEV 0, the
    // STATUS before it), CDB (00 x 12) and DONE (STATUS 0x50, ERROR 0, interrupt reason 3, sense
    // 0/0/0), each framed 0xA5, type, a 16-bit time.
    begin
      int i, k, got_cmd, got_cdb, got_done;
      wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0);
      repeat (2000) @(negedge clk);
      // the first record since power-up is ALIVE (0xA5 0x0A t t 0x5A)
      if (logq.size() < 5 || logq[0] != 8'hA5 || logq[1] != 8'h0A || logq[4] != 8'h5A)
        fail("C11 the log does not start with the ALIVE record");
      logq.delete();
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C11 TUR");
      repeat (2000) @(negedge clk);
      got_cmd = 0; got_cdb = 0; got_done = 0; i = 0;
      while (i + 4 <= logq.size()) begin
        if (logq[i] != 8'hA5) begin i++; continue; end
        k = logq[i+1];
        if (k == 1 && i + 8 <= logq.size() && logq[i+4] == 8'hA0 && logq[i+6] == 8'h00 && got_cmd == 0) got_cmd = 1;
        if (k == 2 && i + 16 <= logq.size() && got_cmd == 1 && got_cdb == 0) begin
          got_cdb = 1;
          for (int j = 4; j < 16; j++) if (logq[i+j] != 8'h00) got_cdb = 0;
        end
        if (k == 4 && i + 18 <= logq.size() && got_cdb == 1 && logq[i+16] == 8'h00 && logq[i+17] == 8'h00 &&
            logq[i+4] == 8'h50 && logq[i+5] == 8'h00 && logq[i+6] == 8'h03 &&
            logq[i+9] == 8'h00 && logq[i+10] == 8'h00 && logq[i+11] == 8'h00) got_done = 1;
        i += (k == 1) ? 8 : (k == 2) ? 16 : (k == 3 || k == 11) ? 12 : (k == 4) ? 18 : (k == 5 || k == 6) ? 9 : 5;
      end
      if (!(got_cmd && got_cdb && got_done))
        fail($sformatf("C11 the log lacks CMD/CDB/DONE for a TUR (%0d/%0d/%0d, %0d bytes)",
                       got_cmd, got_cdb, got_done, logq.size()));
      // an INQUIRY's DONE carries the sum, XOR and count of the 18 words the guest read
      begin
        logic [15:0] es, ex, gs, gx, gn; int found;
        logq.delete();
        packet(8'h12, 0, 0, 0, 8'd36, 0, 0, 0, 0, 0, "C11 INQUIRY");
        repeat (2000) @(negedge clk);
        es = 0; ex = 0;
        for (int w = 0; w < 18; w++) begin es += {rbuf[2*w+1], rbuf[2*w]}; ex ^= {rbuf[2*w+1], rbuf[2*w]}; end
        found = 0; i = 0;
        while (i + 4 <= logq.size()) begin
          if (logq[i] != 8'hA5) begin i++; continue; end
          k = logq[i+1];
          if (k == 4 && i + 18 <= logq.size()) begin
            gs = {logq[i+12], logq[i+13]}; gx = {logq[i+14], logq[i+15]}; gn = {logq[i+16], logq[i+17]};
            found = 1;
            if (gs !== es || gx !== ex || gn !== 16'd18)
              fail($sformatf("C11 INQUIRY DONE read %0d words sum %04x xor %04x, the guest saw 18 / %04x / %04x", gn, gs, gx, es, ex));
          end
          i += (k == 1) ? 8 : (k == 2) ? 16 : (k == 3 || k == 11) ? 12 : (k == 4) ? 18 : (k == 5 || k == 6) ? 9 : 5;
        end
        if (!found) fail("C11 no DONE record for the INQUIRY");
      end
    end

    // ==== C12: a medium mounted while the core is held in reset (the MiSTer's MGL mounts slot 4
    // with delay="1" while the pack loads, and the drive is in reset until cpu_run) ====
    // The header fetch must still land in the buffer: READ TOC then answers the PCD's descriptors
    // exactly as C7's mount at run time does. (The hardware capture of 28bbd257: TOC entries read
    // from an empty header, so NECCD.SYS re-validated the disc forever and DOS said "Not ready".)
    mount(0);   // an ISO first, so the header region holds something else
    rst_n = 0;
    mount(1);
    rst_n = 1;
    repeat (8) @(negedge clk);
    wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0); wr(16'h074C, 8'h02);
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C12 first TUR after the mount");
    packet(8'h43, 0, 0, 0, 0, 0, 0, 0, 8'd100, 0, "C12 READ TOC LBA");
    expect_bytes('{8'h00, 8'h22, 8'h01, 8'h03,
                   0, 8'h14, 8'h01, 0, 0, 0, 0, 0,
                   0, 8'h10, 8'h02, 0, 0, 0, 0, 8'd10,
                   0, 8'h10, 8'h03, 0, 0, 0, 0, 8'd20,
                   0, 8'h10, 8'hAA, 0, 0, 0, 0, 8'(PCD_SECS)}, "C12 READ TOC LBA after a mount in reset");

    // ==== C13: CD-DA through the REAL cdda ring, with the medium mounted in reset and a slow host ====
    // The MiSTer's case: the MGL mounts the CD while the core is held in reset, the ARM takes
    // about 1 ms to answer each slot-4 request, and src/soc/cdda.v's CDDA_REQ paces the fetches.
    // A PLAY AUDIO MSF of N sectors must report 0x11 while it plays and 0x13 (completed,
    // atapicmd.c) once the N sectors - N/75 s of audio - have streamed, not much later.
    begin
      integer f0, f1, t, done_at;
      rst_n = 0;
      mount(1);
      rst_n = 1;
      repeat (8) @(negedge clk);
      use_real_cdda = 1; c13_lba0 = 10; c13_want = 6 * 588;
      host_delay = 100000;          // 1 ms at this bench's 100 MHz clk
      wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0); wr(16'h074C, 8'h02);
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C13 first TUR after the mount");
      f0 = 10 + 150; f1 = 16 + 150;  // 6 sectors = 80 ms of audio (binary MSF: not NEC mode)
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C13 PLAY AUDIO MSF");
      expect_done("C13 PLAY AUDIO MSF");
      packet(8'h42, 0, 0, 8'h01, 0, 0, 0, 0, 8'd4, 0, "C13 SUB-CHANNEL header");
      if (rbuf[1] !== 8'h11) fail($sformatf("C13 audio status %02x right after PLAY, want 0x11", rbuf[1]));
      done_at = -1;
      for (t = 0; t < 400; t++) begin          // up to 400 ms, polled every 1 ms
        repeat (100000) @(negedge clk);
        packet(8'h42, 0, 0, 8'h01, 0, 0, 0, 0, 8'd4, 0, "C13 poll");
        if (rbuf[1] == 8'h13) begin done_at = t; break; end
        if (rbuf[1] !== 8'h11) begin fail($sformatf("C13 audio status %02x while playing", rbuf[1])); break; end
      end
      if (done_at < 0) fail("C13 the 80 ms play never completed in 400 ms (status stays 0x11)");
      // the drive reports the end when the last sector is FETCHED into src/soc/cdda.v's ring, at
      // most the ring's 2048 samples (46 ms) ahead of the speakers. NP2kai counts the sectors as
      // its mixer consumes them, so it reports up to that much later; a game polling for the end
      // sees it slightly early here, never late.
      else if (done_at < 80 - 47) fail($sformatf("C13 the play completed after %0d ms, faster than its 80 ms of audio", done_at));
      else $display("C13: 6 sectors played in %0d ms", done_at);
      repeat (6000000) @(negedge clk);   // 60 ms: let the ring drain to the speakers
      $display("C13: %0d samples out of the ring, %0d wrong", c13_k, c13_bad);
      if (c13_k < 6 * 588 - 600) fail($sformatf("C13 only %0d CD-DA samples reached cdda's AUDIO_L/R, want about %0d", c13_k, 6 * 588));
      if (c13_bad != 0) fail($sformatf("C13 %0d CD-DA samples at cdda's output differ from the disc", c13_bad));
      host_delay = 6;
      use_real_cdda = 0;
    end

    // ==== C14: a completed play's position wanders (atapicmd.c readsubch, rand() & 7) ====
    // NP2kai reports `dacurpos + (rand() & 7)` while the status is 0x12 or 0x13. Policenauts'
    // ITP.EXE waits for the end of its Konami-logo clip by polling the Q channel's RELATIVE
    // position (MSCDEX IOCTL input 0x0C) and leaves only when it is lower than the previous poll,
    // so a completed drive whose position stands still keeps the game at the logo for good. Each
    // report must lie in the end..end+7 window, and the polls must go backwards at least once.
    begin
      integer f0, f1, rl, prev, back, moved, first;
      wr(16'h074C, 8'h02);
      packet(8'h5A, 0, 8'h0F, 0, 0, 0, 0, 0, 8'd24, 0, "C14 MODE SENSE page 0x0F (NEC BCD MSF)");
      f0 = 10 + 150; f1 = 13 + 150;
      packet(8'h47, 0, 0, bcd8(f0 / 4500), bcd8((f0 / 75) % 60), bcd8(f0 % 75),
             bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0, "C14 PLAY AUDIO MSF");
      expect_done("C14 PLAY AUDIO MSF");
      for (int t = 0; t < 400000; t++) begin
        @(negedge clk);
        if (t % 4096 == 0) begin
          packet(8'h42, 0, 0, 8'h01, 0, 0, 0, 0, 8'd4, 0, "C14 poll");
          if (rbuf[1] == 8'h13) break;
        end
      end
      if (rbuf[1] !== 8'h13) fail("C14 the play never completed");
      prev = -1; back = 0; moved = 0; first = -1;
      for (int k = 0; k < 16; k++) begin
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C14 Q channel at 0x13");
        expect_subq_np2(8'h13, 13, 7, $sformatf("C14 Q channel poll %0d", k), rl);
        if (rl < 0) break;
        if (first < 0) first = rl;
        if (rl != first) moved = 1;
        if (prev >= 0 && rl < prev) back++;
        prev = rl;
      end
      if (rl >= 0 && !moved)
        fail($sformatf("C14 16 polls at 0x13 all report relative frame %0d: NP2kai's rand() & 7 never moves it", first));
      else if (rl >= 0 && back == 0)
        fail("C14 the relative position never went backwards in 16 polls at 0x13 (ITP.EXE's exit condition)");
      else if (rl >= 0) $display("C14: 16 polls at 0x13, the position went backwards %0d times", back);
    end

    // ==== C15: the OSD's Eject CD-ROM, and a re-mount ====
    // The eject is pc9821_mount_eject's size-0 event on slot 4 (as the top wires T[11]). Expected
    // values are NP2kai's: an eject is ideio_notify(drv, 0), which clears IDEIO_MEDIA_LOADED
    // (cbus/ideio.c:2090-2091); TEST UNIT READY with the medium not loaded is NOT READY / MEDIUM
    // NOT PRESENT 0x3A, every time, not a one-shot (cbus/atapicmd.c:217-231); MODE SENSE's medium
    // type is 0x70 "door closed, no disc present" (atapicmd.c:1067-1068). A re-mount is
    // ideio_notify(drv, 1): LOADED and CHANGED set (ideio.c:2083), so the first TUR is NOT READY
    // with 0x28 in NEC mode (C14 left it on: atapicmd.c:234-243), the next one GOOD, and the
    // medium reads again.
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C15 TUR before the eject");
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C15 TUR before the eject (2)");
    expect_done("C15 the medium is ready before the eject");
    @(negedge clk); osd_eject_cd = 1; repeat (200) @(negedge clk); osd_eject_cd = 0;
    repeat (100) @(negedge clk);
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C15 TUR after the OSD eject");
    expect_check(4'h2, 8'h3A, "C15 TUR after the OSD eject (no medium)");
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C15 second TUR after the eject");
    expect_check(4'h2, 8'h3A, "C15 second TUR after the eject (still no medium)");
    packet(8'h5A, 0, 8'h2A, 0, 0, 0, 0, 0, 8'd28, 0, "C15 MODE SENSE page 0x2A, ejected");
    if (rlen < 3 || rbuf[2] !== 8'h70)
      fail($sformatf("C15 MODE SENSE medium type %02x after the eject, want 0x70 (no disc)", rbuf[2]));
    mount(0);
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C15 first TUR after the re-mount");
    expect_check(4'h2, 8'h28, "C15 first TUR after the re-mount (NEC mode: 0x28)");
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C15 second TUR after the re-mount");
    expect_done("C15 second TUR after the re-mount");
    read10(3, 1, "C15 READ(10) after the re-mount");

    // ==== C16: another slot's transfer while the CD's request waits for its acknowledge ====
    // hps_io serves one slot at a time over one word bus; only sd_ack (per slot) says whose the
    // words are (sys/hps_io.sv:347). A READ(10) whose block request is presented while the host
    // still streams another slot's 512 words must take none of them and read its own sector.
    host_foreign = 1;
    read10(5, 1, "C16 READ(10) behind another slot's transfer");

    // ==== C17: a PLAY issued while the previous play's audio sector is still being fetched ====
    // NP2kai's player is synchronous: atapicmd.c playaudio sets dacurpos/dalength and the
    // next sector it streams is the NEW start (no fetch can be in flight across a command).
    // So a PLAY of one sector (LBA 20) issued while the engine is mid-fetch of the previous
    // play's sector must still stream all 588 stereo samples of sector 20, and complete at
    // position 21 - the superseded fetch's completion must not advance the new play.
    mount(1);
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C17 TUR after the mount");
    packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C17 second TUR");
    expect_done("C17 the medium is ready");
    cdda_req = 1;
    begin
      integer f0, f1, g0, g1, hit, rl;
      f0 = 10 + 150; f1 = 13 + 150; g0 = 20 + 150; g1 = 21 + 150;
      packet(8'h47, 0, 0, bcd8(f0 / 4500), bcd8((f0 / 75) % 60), bcd8(f0 % 75),
             bcd8(f1 / 4500), bcd8((f1 / 75) % 60), bcd8(f1 % 75), 0, "C17 first PLAY");
      for (int t = 0; t < 200000 && !(cd.e_st != 2'd0 && cd.e_kind == 2'd2); t++) @(negedge clk);
      if (!(cd.e_st != 2'd0 && cd.e_kind == 2'd2)) fail("C17 setup: no audio fetch started");
      c17_on = 1;
      packet(8'h47, 0, 0, bcd8(g0 / 4500), bcd8((g0 / 75) % 60), bcd8(g0 % 75),
             bcd8(g1 / 4500), bcd8((g1 / 75) % 60), bcd8(g1 % 75), 0, "C17 PLAY during a fetch");
      expect_done("C17 PLAY during a fetch");
      for (int t = 0; t < 400000; t++) begin
        @(negedge clk);
        if (t % 4096 == 0) begin
          packet(8'h42, 0, 0, 8'h01, 0, 0, 0, 0, 8'd4, 0, "C17 poll");
          if (rbuf[1] == 8'h13) break;
        end
      end
      if (rbuf[1] !== 8'h13) fail("C17 the second play never completed");
      repeat (20000) @(negedge clk);
      c17_on = 0;
      // sector 20's 588 samples, contiguous, somewhere in the window
      hit = 0;
      for (int b = 0; b + 588 <= c17_n && b + 588 <= 4096 && !hit; b++) begin
        hit = 1;
        for (int s2 = 0; s2 < 588 && hit; s2++)
          if (c17_log[b + s2] !== {abyte(20, s2 * 4 + 3), abyte(20, s2 * 4 + 2),
                                   abyte(20, s2 * 4 + 1), abyte(20, s2 * 4)}) hit = 0;
      end
      if (!hit) fail($sformatf("C17 sector 20 was not streamed (%0d samples after the second PLAY)", c17_n));
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C17 SUB-CHANNEL completed");
      expect_subq_np2(8'h13, 21, 7, "C17 SUB-CHANNEL position after the superseding play", rl);
    end

    // ==== C18: nIEN and the shared IRQ9 line ====
    // ATA-3 s.7.2.9 (Device Control): "nIEN is the enable bit for the device assertion of INTRQ
    // to the host. When nIEN=0, and the device is selected, INTRQ shall be enabled through a
    // tri-state buffer. When nIEN=1, or the device is not selected, the INTRQ signal shall be
    // in a high impedance state." The two banks' INTRQs are ORed onto IRQ9 (MAME pc9801.cpp
    // INPUT_MERGER_ANY_HIGH "ideirq"), so a device whose driver set nIEN must RELEASE the line,
    // or its unacknowledged request hides every later edge of the other bank's drive.
    // The interrupt-pending state follows NP2kai cbus/ideio.c: setintr does nothing under
    // nIEN (`if (!(drv->ctrl & IDECTRL_NIEN))`), and a status read clears the request only
    // with nIEN clear (ideio_i64e, the same test), so a request survives a polled status read.
    begin
      integer r0;
      reg [7:0] s;
      // (a) a CD request left unacknowledged, then nIEN set by its driver: the line is released.
      wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0); wr(16'h074C, 8'h00);
      wr(16'h064E, 8'h08);                       // CD DEVICE RESET: a request
      if (!cd_irq) fail("C18 setup: the CD DEVICE RESET raised no request");
      rd(16'h074C, s);                           // ALTERNATE STATUS only: not an acknowledge
      wr(16'h074C, 8'h02);                       // the CD driver goes polled
      repeat (2) @(negedge clk);
      if (cd_irq) fail("C18 the CD holds INTRQ with nIEN set (ATA-3: high impedance)");
      // (b) the disk on bank 0 must now reach the PIC as a fresh edge.
      wr(16'h0432, 8'h00); wr(16'h064C, 8'hA0); wr(16'h074C, 8'h00);
      r0 = irq9_rises;
      wr(16'h064E, 8'h10);                       // RECALIBRATE: completes with an interrupt
      repeat (20) @(negedge clk);
      if (irq9_rises - r0 != 1) fail("C18 the disk's interrupt made no IRQ9 edge behind the CD's request");
      rd(16'h064E, s);
      // (c) a disk request survives a status read made under nIEN, and drives the line again
      //     once nIEN clears (ideio_i64e resets only with NIEN clear).
      wr(16'h064E, 8'h10);
      repeat (20) @(negedge clk);
      if (!ata_irq) fail("C18 setup: RECALIBRATE raised no disk request");
      wr(16'h074C, 8'h02);
      repeat (2) @(negedge clk);
      if (ata_irq) fail("C18 the disk holds INTRQ with nIEN set (ATA-3: high impedance)");
      rd(16'h064E, s);                           // a polled status read: not an acknowledge
      wr(16'h074C, 8'h00);
      repeat (2) @(negedge clk);
      if (!ata_irq) fail("C18 a status read under nIEN cleared the disk's request (NP2kai ideio_i64e keeps it)");
      rd(16'h064E, s);
      if (ata_irq) fail("C18 the status read with nIEN clear did not acknowledge");
      // (d) a completion under nIEN neither raises nor clears the request (NP2kai setintr).
      wr(16'h064E, 8'h10);
      repeat (20) @(negedge clk);
      wr(16'h074C, 8'h02);
      wr(16'h064E, 8'h10);                       // completes under nIEN
      repeat (20) @(negedge clk);
      wr(16'h074C, 8'h00);
      repeat (2) @(negedge clk);
      if (!ata_irq) fail("C18 a completion under nIEN cleared the pending disk request (NP2kai setintr is a no-op)");
      rd(16'h064E, s);
      wr(16'h074C, 8'h02);
      wr(16'h064E, 8'h10);                       // nothing pending, completes under nIEN
      repeat (20) @(negedge clk);
      wr(16'h074C, 8'h00);
      repeat (2) @(negedge clk);
      if (ata_irq) fail("C18 a completion under nIEN raised a request (NP2kai setintr is a no-op)");
    end

    // ==== C19: the MSF converter at its 4500-frame boundary ====
    // The converter walks frames -> M:S:F in two phases: subtract 4500 while cv_x >= 4500 (the
    // minutes), then 75 a step (the seconds), and the conversion ends when cv_x < 75. A mount of
    // N sectors makes the converter's input N + 150 frames (the 150-frame lead-in of
    // atapicmd.c's storemsf), so these six sizes pin the minute compare one frame below, exactly
    // on and one frame above its edge, and the seconds step's last frames (74/75/76). Every
    // expected M:S:F is arithmetic on that frame count, never this RTL's own answer.
    begin
      integer n, mm, ss, ff;
      sel_cd;
      for (int t = 0; t < 6; t++) begin
        case (t)
          0: n = 4349;   // 4499 frames: the minute compare is FALSE by one frame
          1: n = 4350;   // 4500 frames: EXACTLY one minute step (the compare's true edge)
          2: n = 4351;   // 4501 frames
          3: n = 4424;   // 4574 frames: the seconds step's 74-frame tail
          4: n = 4425;   // 4575 frames: exactly one whole 75-frame step after the minute
          5: n = 4426;   // 4576 frames
          default: n = 20;
        endcase
        mount_iso_sectors(n);
        mm = (n + 150) / 4500;
        ss = ((n + 150) / 75) % 60;
        ff = (n + 150) % 75;
        packet(8'h43, 8'h02, 0, 0, 0, 0, 0, 0, 8'd100, 0, "C19 READ TOC MSF");
        expect_done("C19 READ TOC MSF");
        expect_bytes('{8'h00, 8'h12, 8'h01, 8'h01,
                       8'h00, 8'h14, 8'h01, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00,
                       8'h00, 8'h14, 8'hAA, 8'h00, 8'h00, bcd8(mm), bcd8(ss), bcd8(ff)},
                     $sformatf("C19 READ TOC MSF at %0d sectors (%02d:%02d:%02d)", n, mm, ss, ff));
      end
    end

    // ==== C20: CD-DA from a slow host: 20 ms from each slot-4 request to its acknowledge ====
    // One audio sector is 1/75 s = 13.3 ms of sound. A drive that fetches one sector per host
    // request, one request at a time, cannot keep up once the host takes longer than that per
    // request, whatever the ring holds: the ring runs dry and the speakers get silence between
    // sectors. The MiSTer's ARM answers a slot request in a time this core does not control (it
    // differs between cards and Main_MiSTer builds). Here every request waits 20 ms. A 60-sector
    // play (800 ms) must reach the speakers whole: every sample, in order, equal to the disc, and
    // no silent sample between its first and its last.
    begin
      integer f0, f1, t, done_at;
      pcd_secs = 120;              // track 1 data 0..9, audio from 10 to the lead-out at 120
      rst_n = 0;
      mount(1);
      rst_n = 1;
      repeat (8) @(negedge clk);
      sel_cd;
      wr(16'h074C, 8'h02);
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C20 first TUR after the mount");
      c13_k = 0; c13_bad = 0; c13_gap = 0; c13_lba0 = 30; c13_want = 60 * 588;
      use_real_cdda = 1;
      host_delay = 2000000;         // 20 ms at this bench's 100 MHz clk
      f0 = 30 + 150; f1 = 90 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C20 PLAY AUDIO MSF");
      expect_done("C20 PLAY AUDIO MSF");
      done_at = -1;
      for (t = 0; t < 200; t++) begin           // up to 2 s, polled every 10 ms
        repeat (1000000) @(negedge clk);
        packet(8'h42, 0, 0, 8'h01, 0, 0, 0, 0, 8'd4, 0, "C20 poll");
        if (rbuf[1] == 8'h13) begin done_at = t; break; end
      end
      repeat (6000000) @(negedge clk);          // 60 ms: the ring drains
      $display("C20: %0d of %0d samples reached the speakers, %0d wrong, %0d silent gaps, play done after %0d0 ms",
               c13_k, c13_want, c13_bad, c13_gap, done_at);
      if (done_at < 0) fail("C20 the 800 ms play never completed in 2 s");
      if (c13_gap != 0) fail($sformatf("C20 %0d silent samples inside the play: the ring ran dry behind a 20 ms host", c13_gap));
      if (c13_k != c13_want) fail($sformatf("C20 %0d samples reached the speakers, want %0d", c13_k, c13_want));
      if (c13_bad != 0) fail($sformatf("C20 %0d samples differ from the disc", c13_bad));
      host_delay = 6;
      use_real_cdda = 0;
    end

    // ==== C21: READ SUB-CHANNEL reports NP2kai's position, not the read-ahead ====
    // NP2kai's dacurpos is the next sector its mixer loads: playdevaudio loads a sector and
    // increments dacurpos before mixing it (ideio.c), so while sector S is heard the Q channel's
    // absolute address is S + 1 - after k samples of the play, lba0 + ceil(k / 588) (np2_pos_lo/
    // hi). The drive here reads ahead into the ring; every poll's address must be exactly that
    // for the samples that had reached the speakers when the drive executed the poll, and
    // "completed" (0x13) may only be reported once all of the play's samples have left it.
    begin
      integer f0, f1, t, pos, heard, worst, done_at, lo, hi;
      c13_k = 0; c13_bad = 0; c13_gap = 0; c13_lba0 = 30; c13_want = 40 * 588;
      use_real_cdda = 1;
      host_delay = 100000;          // 1 ms
      f0 = 30 + 150; f1 = 70 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C21 PLAY AUDIO MSF");
      expect_done("C21 PLAY AUDIO MSF");
      worst = 0; done_at = -1;
      for (t = 0; t < 100; t++) begin           // every 10 ms
        repeat (1000000) @(negedge clk);
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C21 poll");
        heard = c13_lba0 + (subq_k + 587) / 588;   // NP2kai's dacurpos for these samples
        lo = np2_pos_lo(c13_lba0, subq_k); hi = np2_pos_hi(c13_lba0, subq_k);
        pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;   // the absolute MSF (binary: not NEC mode)
        if (rbuf[1] == 8'h13) begin
          done_at = t;
          if (c13_k < c13_want - 588)
            fail($sformatf("C21 completed (0x13) with only %0d of %0d samples played", c13_k, c13_want));
          break;
        end
        if (pos - heard > worst) worst = pos - heard;
        if (heard - pos > worst) worst = heard - pos;
        if (pos < lo || pos > hi)
          fail($sformatf("C21 sub-channel reports LBA %0d after %0d samples, want NP2kai's %0d (%0d..%0d)",
                         pos, subq_k, heard, lo, hi));
      end
      $display("C21: the reported position was at most %0d sector(s) from NP2kai's; completed after %0d0 ms", worst, done_at);
      if (done_at < 0) fail("C21 the play never completed");
      repeat (6000000) @(negedge clk);
      if (c13_k != c13_want || c13_bad != 0 || c13_gap != 0)
        fail($sformatf("C21 %0d/%0d samples, %0d wrong, %0d gaps", c13_k, c13_want, c13_bad, c13_gap));
      use_real_cdda = 0;
    end

    // ==== C22: PAUSE, RESUME and STOP act on what is heard ====
    // A PAUSE silences the speakers at once (the ring's read-ahead is dropped, nothing already
    // fetched keeps playing) and holds the sector being heard; RESUME continues from the start
    // of that sector, in order, with no gap; STOP silences at once too. (atapicmd.c: pauseresume
    // and stop_daplay stop NP2kai's mixer callback from taking any more of the disc.)
    begin
      integer f0, f1, t, k_at, sec_at, pos, pmin;
      c13_k = 0; c13_bad = 0; c13_gap = 0; c13_lba0 = 30; c13_want = 40 * 588;
      use_real_cdda = 1;
      host_delay = 100000;
      f0 = 30 + 150; f1 = 70 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C22 PLAY AUDIO MSF");
      repeat (15000000) @(negedge clk);         // 150 ms in
      c13_hold = 1;
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C22 PAUSE");
      expect_done("C22 PAUSE");
      repeat (2000) @(negedge clk);             // 20 us: the sample in the CDC pipe
      k_at = c13_k; sec_at = c13_lba0 + c13_k / 588;
      repeat (5000000) @(negedge clk);          // 50 ms
      if (c13_k != k_at)
        fail($sformatf("C22 %0d samples reached the speakers in the 50 ms after PAUSE", c13_k - k_at));
      // NP2kai: a PAUSE leaves dacurpos one past the sector being heard (it was loaded), and a
      // paused drive reports dacurpos + (rand() & 7). Over 32 polls the wander's low end shows:
      // the smallest report must be NP2kai's dacurpos itself, not merely inside the window.
      pmin = 1 << 30;
      for (int q = 0; q < 32; q++) begin
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C22 SUB-CHANNEL paused");
        pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
        if (pos < pmin) pmin = pos;
        if (rbuf[1] !== 8'h12 || pos < np2_pos_lo(c13_lba0, k_at) || pos > np2_pos_hi(c13_lba0, k_at) + 7)
          fail($sformatf("C22 paused: status %02x at LBA %0d, want 0x12 at %0d..%0d (NP2kai's dacurpos + rand() & 7)",
                         rbuf[1], pos, np2_pos_lo(c13_lba0, k_at), np2_pos_hi(c13_lba0, k_at) + 7));
      end
      if (pmin > np2_pos_hi(c13_lba0, k_at))
        fail($sformatf("C22 paused: 32 reports never came down to NP2kai's dacurpos %0d (lowest %0d)",
                       np2_pos_hi(c13_lba0, k_at), pmin));
      c13_k = (c13_k / 588) * 588;              // RESUME restarts the sector that was being heard
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 8'h01, 0, "C22 RESUME");
      expect_done("C22 RESUME");
      // the silence lasts until the refetched sector's first sample arrives (one 1 ms host
      // request); from then on any silent sample is a gap
      begin
        integer k_res, n;
        k_res = c13_k; n = 0;
        while (c13_k == k_res && n < 1000000) begin @(negedge clk); n++; end
        if (c13_k == k_res) fail("C22 nothing reached the speakers in the 10 ms after RESUME");
      end
      c13_hold = 0;
      for (t = 0; t < 100; t++) begin
        repeat (1000000) @(negedge clk);
        packet(8'h42, 0, 0, 8'h01, 0, 0, 0, 0, 8'd4, 0, "C22 poll");
        if (rbuf[1] == 8'h13) break;
      end
      repeat (6000000) @(negedge clk);
      if (c13_k != c13_want || c13_bad != 0 || c13_gap != 0)
        fail($sformatf("C22 after RESUME: %0d/%0d samples, %0d wrong, %0d gaps", c13_k, c13_want, c13_bad, c13_gap));
      // STOP (START STOP UNIT, atapicmd.c stop_daplay) in the middle of a play
      c13_k = 0; c13_bad = 0; c13_gap = 0;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C22 PLAY again");
      repeat (15000000) @(negedge clk);
      c13_hold = 1;
      packet(8'h1B, 0, 0, 0, 8'h01, 0, 0, 0, 0, 0, "C22 START STOP UNIT");
      repeat (2000) @(negedge clk);
      k_at = c13_k;
      repeat (5000000) @(negedge clk);
      if (c13_k != k_at)
        fail($sformatf("C22 %0d samples reached the speakers in the 50 ms after STOP", c13_k - k_at));
      $display("C22: PAUSE held sector %0d, STOP after %0d samples, both silent at once", sec_at, k_at);
      c13_hold = 0;
      host_delay = 6;
      use_real_cdda = 0;
      pcd_secs = PCD_SECS;
    end

    // ==== C23: a sector finishing in the very cycle of a PAUSE or a STOP ====
    // R4/R8: two events reach the player's positions in one cycle. A PAUSE holds the sector being
    // heard, and a sector that finished in the PAUSE's own cycle has been heard: the held (and
    // fetch) position is one past it. A STOP discards everything: position 0, whatever finished.
    // The model ring is held (CDDA_REQ low) so nothing is fetched and the only movement is the
    // forced pulse.
    begin
      integer f0, f1;
      sel_cd;
      cdda_req = 0; c23_quiet = 1;
      f0 = 12 + 150; f1 = 19 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C23 PLAY AUDIO MSF");
      // the first sector (12) has been fetched and is playing: one forced pulse of the model ring
      // is ITS end, so give the player a fetched position past it the honest way - let the model
      // fetch exactly one sector
      cdda_req = 1;
      wait (cd.dacurpos == 20'd13);
      cdda_req = 0;
      repeat (4000) @(negedge clk);
      c23_op = 8'h4B;
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C23 PAUSE with a sector finishing in its cycle");
      c23_op = 8'h00;
      if (cd.daplaypos !== 20'd13 || cd.dacurpos !== 20'd13 || cd.dalength !== 20'd6)
        fail($sformatf("C23 PAUSE + played in one cycle: played %0d fetch %0d length %0d, want 13 13 6",
                       cd.daplaypos, cd.dacurpos, cd.dalength));
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 8'h01, 0, "C23 RESUME");
      repeat (100) @(negedge clk);
      c23_op = 8'h1B;
      packet(8'h1B, 0, 0, 0, 8'h01, 0, 0, 0, 0, 0, "C23 STOP with a sector finishing in its cycle");
      c23_op = 8'h00;
      if (cd.daplaypos !== 20'd0 || cd.dacurpos !== 20'd0 || cd.daflag !== 3'd3)
        fail($sformatf("C23 STOP + played in one cycle: played %0d fetch %0d flag %0d, want 0 0 3",
                       cd.daplaypos, cd.dacurpos, cd.daflag));
      $display("C23: PAUSE and STOP each merged a sector finishing in their own cycle");
      cdda_req = 1; c23_quiet = 0;
    end

    // ==== C24: another disc mounted over a playing one ====
    // The OSD mounts a second PCD while a track plays, without an eject first. The medium has
    // gone away under the player: NP2kai's mixer finds the sxsi device not READY and stops with
    // daflag 0x14, dacurpos left where it was (ideio.c playdevaudio). So from the mount on
    // nothing of the old disc reaches the speakers (the ring's read-ahead is dropped), nothing of
    // the new disc is fetched at the old play's position, READ SUB-CHANNEL answers 0x14 at
    // NP2kai's position, and the TEST UNIT READY that reports the new disc stops the player
    // (atapicmd.c: 0x13, position 0).
    begin
      integer f0, f1, k_at, req_at, pos;
      pcd_secs = 120; disc_id = 0;
      host_delay = 100000;          // 1 ms
      mount(1);
      repeat (500000) @(negedge clk);   // the header behind the 1 ms host
      sel_cd;
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C24 TUR reporting the first disc");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C24 TUR");
      expect_done("C24 TUR");
      c13_k = 0; c13_bad = 0; c13_gap = 0; c13_lba0 = 30; c13_want = 40 * 588;
      use_real_cdda = 1;
      f0 = 30 + 150; f1 = 70 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C24 PLAY AUDIO MSF");
      expect_done("C24 PLAY AUDIO MSF");
      repeat (15000000) @(negedge clk);         // 150 ms in
      if (c13_k < 100 || c13_bad != 0)
        fail($sformatf("C24 the first disc's play: %0d samples, %0d wrong", c13_k, c13_bad));
      // the second disc, mounted over the first
      c13_hold = 1;
      disc_id = 1; make_pcd;
      img_size = img.size();
      @(negedge clk); img_mounted = 1;
      repeat (2) @(negedge clk);
      req_at = host_sec_reqs;
      img_mounted = 0;
      repeat (2000) @(negedge clk);             // 20 us: the sample in the CDC pipe
      k_at = c13_k;
      repeat (20000000) @(negedge clk);         // 200 ms: more than the ring holds
      if (c13_k != k_at)
        fail($sformatf("C24 %0d samples reached the speakers in the 200 ms after the mount", c13_k - k_at));
      if (host_sec_reqs != req_at)
        fail($sformatf("C24 %0d sector requests of the new disc after the mount", host_sec_reqs - req_at));
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C24 SUB-CHANNEL after the mount");
      expect_done("C24 SUB-CHANNEL after the mount");
      pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
      if (rlen != 16 || rbuf[1] !== 8'h14 || pos < np2_pos_lo(30, k_at) || pos > np2_pos_hi(30, k_at))
        fail($sformatf("C24 SUB-CHANNEL after the mount: status %02x at LBA %0d, want 0x14 at %0d..%0d",
                       rbuf[1], pos, np2_pos_lo(30, k_at), np2_pos_hi(30, k_at)));
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C24 TUR reporting the second disc");
      if (pk_status !== 8'h51) fail($sformatf("C24 TUR after the mount: status %02x, want 51 (the change)", pk_status));
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C24 SUB-CHANNEL after the TUR");
      pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
      if (rbuf[1] !== 8'h13 || pos < 0 || pos > 7)
        fail($sformatf("C24 SUB-CHANNEL after the TUR: status %02x at LBA %0d, want 0x13 at 0..7", rbuf[1], pos));
      $display("C24: a mount over a play after %0d samples: silent at once, no sector fetched, 0x14 at LBA %0d",
               k_at, np2_pos_lo(30, k_at));
      c13_hold = 0;
    end

    // ==== C25: the core reset stops CD-DA ====
    // NP2kai runs ideio_reset on every machine reset (cbus/cbuscore.c resetfn[]): it zeroes the
    // IDE state, so the play stops (daplaying 0), and devinit sets daflag 0x15 (ideio.c). From the
    // reset on the speakers are silent and no audio sector is fetched; the disc stays mounted,
    // and READ SUB-CHANNEL then answers 0x15 with no position (atapicmd.c readsubch: the
    // position fields are filled only for a daflag other than 0x15).
    begin
      integer f0, f1, k_at, req_at;
      c13_k = 0; c13_bad = 0; c13_gap = 0; c13_lba0 = 30; c13_want = 40 * 588;
      f0 = 30 + 150; f1 = 70 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C25 PLAY AUDIO MSF");
      expect_done("C25 PLAY AUDIO MSF");
      repeat (15000000) @(negedge clk);         // 150 ms in
      if (c13_k < 100 || c13_bad != 0)
        fail($sformatf("C25 the play before the reset: %0d samples, %0d wrong", c13_k, c13_bad));
      c13_hold = 1;
      @(negedge clk); rst_n = 0;
      repeat (2) @(negedge clk);
      req_at = host_sec_reqs;
      repeat (98) @(negedge clk); rst_n = 1;
      repeat (2000) @(negedge clk);
      k_at = c13_k;
      repeat (20000000) @(negedge clk);         // 200 ms
      if (c13_k != k_at)
        fail($sformatf("C25 %0d samples reached the speakers in the 200 ms after the reset", c13_k - k_at));
      if (host_sec_reqs != req_at)
        fail($sformatf("C25 %0d audio sector requests after the reset", host_sec_reqs - req_at));
      sel_cd;
      wr(16'h074C, 8'h02);
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C25 SUB-CHANNEL after the reset");
      expect_done("C25 SUB-CHANNEL after the reset");
      expect_bytes('{8'h00, 8'h15, 8'h00, 8'h12, 8'h01, 8'h00, 8'h00, 8'h00,
                     8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00},
                   "C25 SUB-CHANNEL after the reset (0x15, no position)");
      $display("C25: a reset after %0d samples of a play: silent at once, no sector fetched, 0x15", k_at);
      c13_hold = 0;
      host_delay = 6;
      use_real_cdda = 0;
      pcd_secs = PCD_SECS; disc_id = 0;
    end

    // ==== C26: the play's first sector completing in the very cycle of a PAUSE or a mount ====
    // NP2kai's dacurpos counts a sector as loaded the moment its mixer reads it (ideio.c
    // playdevaudio: `drv->dacurpos++;` right after the sxsicd_readraw, before any of it is mixed),
    // so a PAUSE taken once the play's first sector has been read reports one past it: 0x12 at
    // lba0 + 1 + (rand() & 7) (atapicmd.c readsubch). Here that first fetch's completion (e_done:
    // every sample is in the ring) lands in the PAUSE's own cycle (R4: both events land), so the
    // lowest of 32 reports must be lba0 + 1, never lba0. The mount over a playing drive is the
    // same merge with 0x14, which readsubch reports with no jitter: exactly lba0 + 1.
    begin
      integer f0, f1, pos, pmin;
      sel_cd;
      pcd_secs = 120; disc_id = 0;
      mount(1);
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C26 TUR reporting the disc");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C26 TUR");
      expect_done("C26 TUR");
      // one sector per request, nothing played (the model ring never reports a sector heard)
      c23_quiet = 1; cdda_req = 1;
      host_hold = 1; hold_op = 8'h4B;
      f0 = 40 + 150; f1 = 60 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C26 PLAY AUDIO MSF");
      expect_done("C26 PLAY AUDIO MSF");
      repeat (6000) @(negedge clk);             // the first sector streams; its ack is held
      if (!host_hold) fail("C26 the first sector's fetch ended before the PAUSE");
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C26 PAUSE with the first sector completing in its cycle");
      expect_done("C26 PAUSE");
      if (host_hold) fail("C26 the held fetch did not complete in the PAUSE's cycle");
      pmin = 1 << 30;
      for (int q = 0; q < 32; q++) begin
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C26 SUB-CHANNEL paused");
        pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
        if (pos < pmin) pmin = pos;
        if (rbuf[1] !== 8'h12 || pos < 41 || pos > 48)
          fail($sformatf("C26 paused after the first sector: status %02x at LBA %0d, want 0x12 at 41..48 (dacurpos 41 + rand() & 7)",
                         rbuf[1], pos));
      end
      if (pmin != 41)
        fail($sformatf("C26 paused after the first sector: lowest of 32 reports %0d, want NP2kai's dacurpos 41", pmin));
      packet(8'h1B, 0, 0, 0, 8'h01, 0, 0, 0, 0, 0, "C26 STOP");
      // the same merge against a mount (another disc over the playing one): 0x14, no jitter
      host_hold = 1; hold_op = 8'h00;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C26 PLAY again");
      expect_done("C26 PLAY again");
      repeat (6000) @(negedge clk);
      if (!host_hold) fail("C26 the first sector's fetch ended before the mount");
      disc_id = 1; make_pcd;
      img_size = img.size();
      // the mount edge and the held fetch's completion in one cycle
      @(negedge clk); img_mounted = 1; sd_ack = 0; host_hold = 0;
      repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);            // the new disc's header
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C26 SUB-CHANNEL after the mount");
      pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
      if (rbuf[1] !== 8'h14 || pos != 41)
        fail($sformatf("C26 mount after the first sector: status %02x at LBA %0d, want 0x14 at 41", rbuf[1], pos));
      $display("C26: the first sector completing in a PAUSE's and in a mount's cycle reports %0d (NP2kai: 41)", pmin);
      c23_quiet = 0;
      disc_id = 0;
    end

    // ==== C27: a PAUSED play survives an eject and a different disc; RESUME plays on ====
    // NP2kai keeps the player across a media change: ideio_notify touches only drv->media
    // (ideio.c: `drv->media |= (IDEIO_MEDIA_CHANGED | IDEIO_MEDIA_LOADED);` / `drv->media &=
    // ~(IDEIO_MEDIA_LOADED | IDEIO_MEDIA_COMBINE);`), a paused drive's mixer is not running so
    // nothing finds the medium gone (playaudio returns at once with daplaying clear), and
    // atapi_cmd_pauseresume tests only daflag (`if (drv->daflag == 0x12) { ... daflag = 0x11; }`).
    // Only the TEST UNIT READY that reports the change stops it (0x13, position 0). So PLAY,
    // PAUSE, eject, mount another disc, and RESUME before any TUR: SUB-CHANNEL still answers 0x12
    // at the same position after the remount, RESUME answers GOOD and 0x11, and the play
    // continues at that position on the NEW disc (the core refetches the sector that was being
    // heard from its start - the PAUSE granularity the header records - so the first sector is
    // the paused position's sector or the one before it, and its samples are the new disc's).
    begin
      integer f0, f1, pos, pmin_a, pmin_b, pmax, n, sec0;
      reg [31:0] first_w;
      sel_cd;
      pcd_secs = 120; disc_id = 0;
      mount(1);
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C27 TUR reporting the disc");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C27 TUR");
      expect_done("C27 TUR");
      host_delay = 100000;          // 1 ms per request: the play is still under way at the PAUSE
      f0 = 30 + 150; f1 = 70 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C27 PLAY AUDIO MSF");
      expect_done("C27 PLAY AUDIO MSF");
      repeat (300000) @(negedge clk);           // 3 ms: a few sectors in
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C27 PAUSE");
      expect_done("C27 PAUSE");
      // A paused report is dacurpos + (rand() & 7), so the paused dacurpos B is pinned only to
      // max - 7 .. min of the reports: every report before AND after the remount must fit ONE
      // such window (the same B), and the refetched sector must be B - 1 or B for some B in it.
      pmin_a = 1 << 30; pmax = -1;
      for (int q = 0; q < 64; q++) begin
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C27 SUB-CHANNEL paused");
        pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
        if (pos < pmin_a) pmin_a = pos;
        if (pos > pmax) pmax = pos;
        if (rbuf[1] !== 8'h12) fail($sformatf("C27 paused: status %02x, want 0x12", rbuf[1]));
      end
      if (pmin_a <= 30 || pmin_a >= 70)
        fail($sformatf("C27 paused at LBA %0d, want inside the play 31..69", pmin_a));
      // the OSD's eject (a size-0 mount), then a different disc
      img_size = 0;
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);
      disc_id = 1; make_pcd;
      img_size = img.size();
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (500000) @(negedge clk);           // the header behind the 1 ms host
      pmin_b = 1 << 30;
      for (int q = 0; q < 64; q++) begin
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C27 SUB-CHANNEL after the remount");
        pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
        if (pos < pmin_b) pmin_b = pos;
        if (pos > pmax) pmax = pos;
        if (rbuf[1] !== 8'h12)
          fail($sformatf("C27 after eject and remount: status %02x, want 0x12 (NP2kai keeps the pause)", rbuf[1]));
      end
      if (pmin_b < pmin_a) pmin_a = pmin_b;     // the lowest report of either run
      if (pmax - pmin_a > 7)
        fail($sformatf("C27 after eject and remount: reports span LBA %0d..%0d, more than one dacurpos + rand() & 7",
                       pmin_a, pmax));
      c27_got = 0; c27_arm = 1;
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 8'h01, 0, "C27 RESUME on the new disc");
      expect_done("C27 RESUME");
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C27 SUB-CHANNEL after RESUME");
      if (rbuf[1] !== 8'h11) fail($sformatf("C27 after RESUME: status %02x, want 0x11", rbuf[1]));
      n = 0;
      while (!c27_got && n < 1000000) begin @(negedge clk); n++; end
      c27_arm = 0;
      if (!c27_got) fail("C27 nothing was streamed in the 10 ms after RESUME");
      else begin
        first_w = c27_w;
        sec0 = -1;
        for (int l = pmax - 8; l <= pmin_a; l++)
          if (first_w == {abyte(l, 3), abyte(l, 2), abyte(l, 1), abyte(l, 0)}) sec0 = l;
        if (sec0 < 0)
          fail($sformatf("C27 after RESUME: first sample %08x is not the start of the new disc's sector %0d..%0d",
                         first_w, pmax - 8, pmin_a));
      end
      // the TEST UNIT READY that reports the new disc stops the player (atapicmd.c: 0x13, 0)
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C27 TUR reporting the new disc");
      if (pk_status !== 8'h51) fail($sformatf("C27 TUR after the remount: status %02x, want 51 (the change)", pk_status));
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C27 SUB-CHANNEL after the TUR");
      pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
      if (rbuf[1] !== 8'h13 || pos < 0 || pos > 7)
        fail($sformatf("C27 SUB-CHANNEL after the TUR: status %02x at LBA %0d, want 0x13 at 0..7", rbuf[1], pos));
      $display("C27: paused at LBA %0d across an eject and a new disc; RESUME played the new disc from sector %0d",
               pmin_a, sec0);
      host_delay = 6;
      pcd_secs = PCD_SECS; disc_id = 0;
    end

    // ==== C28: a single-track image of raw 2352-byte sectors (no PCD header) ====
    // NP2kai opens a CD image as 2048-byte sectors or, failing that, as raw 2352-byte sectors
    // whose size is a whole number of them, one data track (fdd/sxsicd.c openiso: issec2352
    // `if ((fsize % 2352) != 0) goto sec2352_err; return(fsize / 2352);`, `trk[0].type = 0x14`,
    // the lead-out at totals) and reads each sector's 2048 user bytes 16 bytes in (sec2352_read
    // `fpos = (pos * 2352) + 16;`). The image here is built from the ECMA-130 sector layout: the
    // 12-byte sync 00 FF x10 00, the 4-byte header (BCD M:S:F, mode), then for MODE1 the 2048
    // user bytes at +16, and for MODE2 form 1 (CD-ROM XA) an 8-byte subheader and the user bytes
    // at +24. So the expected data is the image's own user bytes BY CONSTRUCTION (dbyte), the
    // capacity the image's sector count, and READ TOC one data track ending at it - the same
    // replies C6 pins for an ISO. A file that starts with the sync but is not a whole number of
    // sectors is not a raw image: it reads as an ISO (size / 2048 sectors).
    begin
      sel_cd;
      make_raw(RAW_SECS, 1, 0);
      mount_img;
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C28 first TUR after the mount");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C28 second TUR");
      expect_done("C28 second TUR");
      packet(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C28 READ CAPACITY (MODE1/2352)");
      expect_bytes('{8'h00, 8'h00, 8'h00, 8'(RAW_SECS), 8'h00, 8'h00, 8'h08, 8'h00},
                   "C28 READ CAPACITY (MODE1/2352): the sector count, 2048");
      read10(0, 1, "C28 READ(10) MODE1/2352 sector 0");
      read10(3, 2, "C28 READ(10) MODE1/2352 3+2");
      read10(RAW_SECS - 1, 1, "C28 READ(10) MODE1/2352 last sector");
      packet(8'h28, 0, 0, 0, 0, 8'(RAW_SECS), 0, 0, 1, 0, "C28 READ(10) past the end");
      expect_check(4'h5, 8'h21, "C28 READ(10) past the end");
      packet(8'h43, 0, 0, 0, 0, 0, 0, 0, 8'd100, 0, "C28 READ TOC LBA");
      expect_done("C28 READ TOC LBA");
      expect_bytes('{8'h00, 8'h12, 8'h01, 8'h01,
                     8'h00, 8'h14, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                     8'h00, 8'h14, 8'hAA, 8'h00, 8'h00, 8'h00, 8'h00, 8'(RAW_SECS)},
                   "C28 READ TOC LBA (one data track, lead-out at the sector count)");
      packet(8'h43, 8'h02, 0, 0, 0, 0, 0, 0, 8'd100, 0, "C28 READ TOC MSF");
      expect_bytes('{8'h00, 8'h12, 8'h01, 8'h01,
                     8'h00, 8'h14, 8'h01, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00,
                     8'h00, 8'h14, 8'hAA, 8'h00, 8'h00, 8'h00, 8'h02, 8'(RAW_SECS)},
                   "C28 READ TOC MSF");
      // MODE2 form 1: the user bytes 24 in
      make_raw(RAW_SECS, 2, 0);
      mount_img;
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C28 first TUR (MODE2)");
      packet(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C28 READ CAPACITY (MODE2/2352)");
      expect_bytes('{8'h00, 8'h00, 8'h00, 8'(RAW_SECS), 8'h00, 8'h00, 8'h08, 8'h00},
                   "C28 READ CAPACITY (MODE2/2352)");
      read10(2, 3, "C28 READ(10) MODE2 form 1 2+3");
      // the sync at the start but a size that is not a whole number of 2352-byte sectors
      make_raw(RAW_SECS, 1, 2048);
      mount_img;
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C28 first TUR (not whole sectors)");
      packet(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C28 READ CAPACITY (not whole sectors)");
      expect_bytes('{8'h00, 8'h00, 8'h00, 8'((RAW_SECS * 2352 + 2048) / 2048), 8'h00, 8'h00, 8'h08, 8'h00},
                   "C28 READ CAPACITY (not whole 2352-byte sectors: an ISO, size / 2048)");
      $display("C28: raw 2352-byte MODE1 and MODE2 form 1 images read as one %0d-sector data track", RAW_SECS);
    end

    // ==== C29: RESUME (and PLAY) with no disc in the drive: the play stops with 0x14 ====
    // NP2kai: an eject clears the device's READY flag (fdd/sxsi.c sxsi_disconnect / the empty
    // fname path: `sxsi->flag = 0;`). atapi_cmd_pauseresume answers cmddone (GOOD, NO SENSE)
    // whatever the medium and sets daflag 0x11 from 0x12; atapi_cmd_playaudio_sub does the same
    // for a PLAY. The mixer's playdevaudio then tests the device before anything else (`if
    // ((sxsi == NULL) || (sxsi->devtype != SXSIDEV_CDROM) || (!(sxsi->flag & SXSIFLAG_READY)))
    // { drv->daflag = 0x14; return (FAILURE); }`), leaving dacurpos alone. With no disc, READ
    // SUB-CHANNEL answers senderror (CHECK, the sense left as the last cmddone set it: NO SENSE);
    // once a disc is mounted again, and before the TEST UNIT READY that reports it, it answers
    // 0x14 at exactly the untouched dacurpos (no rand() for 0x14). A further RESUME is a no-op
    // (it tests only daflag == 0x12), and the reporting TUR stops the player (0x13, position 0).
    begin
      integer f0, f1, pos, pmin, pmax, n, perr;
      sel_cd;
      pcd_secs = 120; disc_id = 0;
      mount(1);
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C29 TUR reporting the disc");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C29 TUR");
      expect_done("C29 TUR");
      host_delay = 100000;          // 1 ms per request: the play is still under way at the PAUSE
      f0 = 30 + 150; f1 = 70 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C29 PLAY AUDIO MSF");
      expect_done("C29 PLAY AUDIO MSF");
      repeat (300000) @(negedge clk);
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C29 PAUSE");
      expect_done("C29 PAUSE");
      // the paused dacurpos B lies in pmax - 7 .. pmin (each report is B + rand() & 7)
      pmin = 1 << 30; pmax = -1;
      for (int q = 0; q < 64; q++) begin
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C29 SUB-CHANNEL paused");
        pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
        if (pos < pmin) pmin = pos;
        if (pos > pmax) pmax = pos;
        if (rbuf[1] !== 8'h12) fail($sformatf("C29 paused: status %02x, want 0x12", rbuf[1]));
      end
      if (pmin <= 30 || pmin >= 70)
        fail($sformatf("C29 paused at LBA %0d, want inside the play 31..69", pmin));
      // the OSD's eject (a size-0 mount); RESUME with no disc
      img_size = 0;
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);
      c27_got = 0; c27_arm = 1;
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 8'h01, 0, "C29 RESUME with no disc");
      expect_done("C29 RESUME with no disc (NP2kai cmddone)");
      packet(8'h03, 0, 0, 0, 8'd18, 0, 0, 0, 0, 0, "C29 REQUEST SENSE after RESUME");
      if (rbuf[2][3:0] !== 4'h0 || rbuf[12] !== 8'h00)
        fail($sformatf("C29 sense after RESUME: key %x asc %02x, want NO SENSE", rbuf[2], rbuf[12]));
      repeat (200000) @(negedge clk);
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C29 SUB-CHANNEL with no disc");
      expect_check(4'h0, 8'h00, "C29 SUB-CHANNEL with no disc (senderror, sense untouched)");
      // a different disc; SUB-CHANNEL before the reporting TUR
      disc_id = 1; make_pcd;
      img_size = img.size();
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (500000) @(negedge clk);           // the header behind the 1 ms host
      c27_arm = 0;
      if (c27_got) fail("C29 a sample was streamed after RESUME with no disc");
      for (int q = 0; q < 8; q++) begin
        packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C29 SUB-CHANNEL after the remount");
        pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
        if (rbuf[1] !== 8'h14 || pos < pmax - 7 || pos > pmin)
          fail($sformatf("C29 after RESUME with no disc: status %02x at LBA %0d, want 0x14 at the paused dacurpos (%0d..%0d)",
                         rbuf[1], pos, pmax - 7, pmin));
        if (q == 0) perr = pos;
        else if (pos != perr)
          fail($sformatf("C29 0x14 reports moved: LBA %0d then %0d (0x14 takes no rand())", perr, pos));
      end
      // RESUME again: daflag is not 0x12, so nothing starts
      c27_got = 0; c27_arm = 1;
      packet(8'h4B, 0, 0, 0, 0, 0, 0, 0, 8'h01, 0, "C29 RESUME of a 0x14 drive");
      expect_done("C29 RESUME of a 0x14 drive");
      n = 0;
      while (!c27_got && n < 300000) begin @(negedge clk); n++; end
      c27_arm = 0;
      if (c27_got) fail("C29 RESUME of a 0x14 drive streamed a sample");
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C29 SUB-CHANNEL after the second RESUME");
      pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
      if (rbuf[1] !== 8'h14 || pos != perr)
        fail($sformatf("C29 after the second RESUME: status %02x at LBA %0d, want 0x14 at %0d", rbuf[1], pos, perr));
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C29 TUR reporting the new disc");
      if (pk_status !== 8'h51) fail($sformatf("C29 TUR after the remount: status %02x, want 51 (the change)", pk_status));
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C29 SUB-CHANNEL after the TUR");
      pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
      if (rbuf[1] !== 8'h13 || pos < 0 || pos > 7)
        fail($sformatf("C29 SUB-CHANNEL after the TUR: status %02x at LBA %0d, want 0x13 at 0..7", rbuf[1], pos));
      // PLAY with no disc (atapi_cmd_playaudio_sub: dacurpos = the start, cmddone): 0x14 there
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C29 TUR");
      img_size = 0;
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);
      f0 = 50 + 150; f1 = 60 + 150;
      packet(8'h47, 0, 0, 8'(f0 / 4500), 8'((f0 / 75) % 60), 8'(f0 % 75),
             8'(f1 / 4500), 8'((f1 / 75) % 60), 8'(f1 % 75), 0, "C29 PLAY AUDIO MSF with no disc");
      expect_done("C29 PLAY AUDIO MSF with no disc (NP2kai cmddone)");
      repeat (200000) @(negedge clk);
      disc_id = 0; make_pcd;
      img_size = img.size();
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (500000) @(negedge clk);
      packet(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 8'd16, 0, "C29 SUB-CHANNEL after PLAY with no disc");
      pos = rbuf[9] * 4500 + rbuf[10] * 75 + rbuf[11] - 150;
      if (rbuf[1] !== 8'h14 || pos != 50)
        fail($sformatf("C29 after PLAY with no disc: status %02x at LBA %0d, want 0x14 at 50", rbuf[1], pos));
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C29 TUR reporting the disc again");
      $display("C29: RESUME with no disc stops with 0x14 at the paused LBA %0d (NP2kai playdevaudio)", perr);
      host_delay = 6;
      pcd_secs = PCD_SECS; disc_id = 0;
    end

    // ==== C30: a disc change in the middle of a READ(10) fails the command ====
    // NP2kai reads one sector per data phase (atapicmd.c atapi_dataread): a swap first ejects the
    // old disc (fdd/sxsi.c sxsi_devopen: `sxsi->flag = 0;` and the nc_read stub), so the next
    // sector's sxsi_read fails and the command ends `drv->asc = 0x21; senderror(drv);` -
    // CHECK, ILLEGAL REQUEST / 0x21 - never with a sector of the new disc. The sector already
    // in the drive's buffer stays readable (drv->buf). (a) the change lands while the guest
    // drains a sector: the sector drains whole, then CHECK 5/21h; (b) it lands while a
    // sector's fetch is still at the host (the host then serves the NEW image): no data phase,
    // CHECK 5/21h. Disc B is an ISO of the same size whose bytes differ from disc A's.
    begin
      reg [7:0] s, ir; reg [15:0] wd; integer bad;
      host_delay = 6;
      mount(1'b0);                                          // disc A, an ISO
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C30 TUR (change)");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C30 TUR");
      // (a) READ(10) LBA 2, 3 sectors; the change lands in the first data phase
      wr(16'h064E, 8'hA0);
      foreach (c30_cdb[k]) c30_cdb[k] = 8'h00;
      c30_cdb[0] = 8'h28; c30_cdb[5] = 8'd2; c30_cdb[8] = 8'd3;
      for (int k = 0; k < 6; k++) begin wr(16'h0640, c30_cdb[2 * k]); wr(16'h0641, c30_cdb[2 * k + 1]); end
      wait_notbusy("C30a first sector");
      rd(16'h074C, s);
      if (!s[3]) fail($sformatf("C30a first data phase status %02x, want DRQ", s));
      foreach (img[k]) img[k] = img[k] ^ 8'hA5;            // disc B
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      repeat (20000) @(negedge clk);
      if (!cd.loaded) fail("C30a setup: disc B is not loaded before the drain");
      bad = 0;
      c30_reqs = host_sec_reqs;
      for (int k = 0; k < 1024; k++) begin
        rdw(wd);
        if (wd !== {dbyte(2, 2 * k + 1), dbyte(2, 2 * k)}) bad++;
      end
      if (bad != 0) fail($sformatf("C30a the buffered sector of disc A changed (%0d words)", bad));
      wait_notbusy("C30a after the drain");
      rd(16'h064E, pk_status);
      if (host_sec_reqs != c30_reqs)
        fail("C30a the end of the data phase fetched a sector of the new disc");
      expect_check(4'h5, 8'h21, "C30a READ(10) across a disc change (NP2kai: the next sxsi_read fails)");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C30a TUR (change)");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C30a TUR");
      // (b) READ(10) LBA 4, 2 sectors; the change lands while the first fetch is at the host
      host_delay = 3000;
      c30_reqs = host_sec_reqs;
      wr(16'h064E, 8'hA0);
      c30_cdb[5] = 8'd4; c30_cdb[8] = 8'd2;
      for (int k = 0; k < 6; k++) begin wr(16'h0640, c30_cdb[2 * k]); wr(16'h0641, c30_cdb[2 * k + 1]); end
      while (host_sec_reqs == c30_reqs) @(negedge clk);
      repeat (10) @(negedge clk);
      foreach (img[k]) img[k] = img[k] ^ 8'h5A;            // disc C, served to the old fetch
      @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
      host_delay = 6;
      wait_notbusy("C30b the fetch across the change");
      rd(16'h074C, s);
      if (s[3]) fail($sformatf("C30b a sector fetched across a disc change was presented (status %02x)", s));
      rd(16'h064E, pk_status);
      expect_check(4'h5, 8'h21, "C30b READ(10) whose fetch spans a disc change");
      repeat (20000) @(negedge clk);
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C30b TUR (change)");
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "C30b TUR");
      $display("C30: a disc change fails the READ(10) in flight with 5/21h");
    end

    if (errors == 0) begin
      // ==== VERDICT ====
      $display("TB_PC9821_ATAPI: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_ATAPI: FAIL (%0d errors)", errors);
  end

  initial begin
    #5_000_000_000;
    $fatal(1, "TB_PC9821_ATAPI: TIMEOUT");
  end

endmodule
