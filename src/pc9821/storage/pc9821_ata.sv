// PC-98 ATA device: task file, PIO reads and writes, sector buffer.
//
// NP2kai cbus/ideio.c is the primary register/port behavior reference.
// This module owns task-file and PIO state; pc98_iobus only serializes byte
// accesses. A separate block adapter fills the 512-byte sector buffer.

`default_nettype none

module pc9821_ata (
    input wire clk,
    input wire rst_n,

    input  wire        io_rd,
    input  wire        io_wr,
    input  wire [15:0] io_addr,
    input  wire [ 7:0] io_din,
    output reg  [ 7:0] io_dout,

    input wire mounted,
    input wire readonly,
    input wire [31:0] capacity,


    output reg         block_read,
    output reg         block_write,
    output wire [31:0] block_lba,   // meaningful on the block_read/block_write pulse (see lba_plus1)
    input  wire        block_done,
    input  wire        block_error,
    input  wire        block_buf_we,
    input  wire [ 7:0] block_buf_addr,
    input  wire [15:0] block_buf_data,

    // Write transfers: the block adapter drains the sector buffer, addressing it
    // with block_rd_addr and reading the data back on block_rd_data.
    input  wire [ 7:0] block_rd_addr,
    output wire [15:0] block_rd_data,

    output wire irq,

    // Detection/busy snapshot for the stall watchdog:
    // {DP,MOUNT,CH0,state,BSY,DRQ}. tools/decode_telemetry.py decodes this byte
    // as the telemetry's A field by POSITION, and tb_pc9821_ata_dbg.sv pins the
    // layout field by field, so neither may drift.
    // DP = mounted AND the bank selector is at the interface's bank, so DP=0
    // with MOUNT=1 means "an image exists but the selected bank has no
    // interface" - what the machine's own DOS prompt shows.
    output wire [7:0] dbg_state,

    // Command-level trace for the same watchdog: {aborts, last_cmd, commands,
    // abort reason}. R=0 with E=0 in the watchdog message means no block read was
    // ever requested, which is consistent both with "the guest never issued a
    // command" (everything below zero) and with "every command we received was
    // rejected" (aborts > 0). This separates those two cases, which no reset
    // of the existing counters could.
    output wire [31:0] dbg_cmd,

    // Transfer context for the same watchdog: WHERE and WHY. dbg_lba is current_lba,
    // the LBA the in-flight or last transfer started at (it advances per sector as a
    // read drains, so at a freeze it names the sector being fetched); dbg_sec is the
    // task file's {sector_count, error_reg} - what the transfer still owes the guest
    // and what the error register says (0x04 ABRT with the abort reason in dbg_cmd
    // separates "our own block engine failed" from "the guest asked for the
    // impossible"). Pure views of state this module already holds; with the telemetry
    // compiled out (PERF_LOG_EN=0) the outputs are unconnected and prune away.
    output wire [31:0] dbg_lba,
    output wire [15:0] dbg_sec
);

  localparam [7:0] ATA_ERR_ABRT = 8'h04;
  localparam [7:0] ATA_ST_ERR = 8'h01;
  localparam [7:0] ATA_ST_DRQ = 8'h08;
  localparam [7:0] ATA_ST_DSC = 8'h10;
  localparam [7:0] ATA_ST_DRDY = 8'h40;
  localparam [7:0] ATA_ST_BSY = 8'h80;
  localparam [7:0] ATA_READY = ATA_ST_DRDY | ATA_ST_DSC;

  localparam [2:0] X_IDLE = 3'd0, X_WAIT_BLOCK = 3'd1, X_PIO_IDENT = 3'd2,
                   X_PIO_READ = 3'd3, X_PIO_WRITE = 3'd4, X_WAIT_WRITE = 3'd5,
                   X_DRAIN = 3'd6;

  // SET MULTIPLE MODE (0xC6) stores the block length in sectors, and READ
  // MULTIPLE (0xC4) raises the data interrupt once per BLOCK rather than once per
  // sector. NP2kai `ideio.c`: `drv->mulmode = drv->sc` for 2/4/.../128, then
  // `readsec` raises the interrupt only while `mulcnt == 0`. This model IMPLEMENTS
  // all three commands but does NOT advertise them (word 47 = 0): it buffers one
  // sector at a time, so a block stream can outrun the HPS fetch and drop DRQ, and
  // the Xe10 ROM's READ MULTIPLE does not check DRQ. See identify_word word 47.
  reg [7:0] set_multiple;   // NP2kai mulmode; power-up IDEIO_MULTIPLE_MAX = 128
  reg [7:0] block_pos;      // sectors presented in the current block (0 = the block boundary)
  reg [7:0] block_size;     // sectors per block for the in-flight command (1 = single-sector)

  reg [2:0] xfer_state;
  reg       mounted_seen;
  reg [7:0] error_reg;
  reg [7:0] sector_count;
  reg [7:0] sector_number;
  reg [7:0] cylinder_low;
  reg [7:0] cylinder_high;
  reg [7:0] drive_head;
  reg [7:0] status_reg;
  reg [7:0] channel_reg;
  // 0x0432 is the IDE *bank* select: latched, readable, a window on the
  // interface at the selected bank. One drive is modelled, bank 0's master (IDE unit 0).
  // WHICH bank is connected is decided by BIT 0, the channel select, not by byte
  // equality: QEMU selects with `cur_bus = &bus[val & 1]`, NP2kai's task file
  // follows `(bank & 0x7f) < 2`. Equality was too narrow AND too wide - a DWORD
  // PIO driver's `bank|0x08` (0x09) dropped the whole task file, while 0x03, the
  // same channel with other bits set, floated.
  // The stored byte is NOT masked, deliberately: NP2kai masks 0x71 and QEMU 0x39
  // and they disagree about bits 3 and 6, whose read-back is unmeasured; with
  // the test on bit 0 the mask is not load-bearing, so the guest reads back what
  // it wrote - which the ROM's save/restore brackets depend on.
  // Getting this wrong costs the whole boot: a bit-7 gate answered a floating
  // bank, the pre-command DRDY poll read the float, the dispatcher skipped the
  // handler, and ZERO commands reached the drive (cmds=0, reached IPL=0). Banks
  // 0x02/0x03 are unmeasured. Evidence
  //
  // Declared here, with the register block, because the window is not only about the
  // bytes a register ANSWERS with: the task file's SIDE EFFECTS below (the 0x064E
  // acknowledge, the 0x0642 ERR clear, the data port's word pointer and its buffer
  // write) are gated on this wire too. NP2kai drops the whole access when getidedrv()
  // is NULL - the bank select is the outer of its two tests (cbus/ideio.c:50-60, e.g.
  // ideio_i64e:1421-1442, ideio_i642:1324-1338, ideio_w16:1503-1515) - and the
  // machine's window is measured in the write direction (docs/probes/ATA.TXT). Ungated, a stray access at
  // the wrong bank would swallow a pending
  // interrupt, clear the drive's ERR snapshot, or splice two bytes into the sector the
  // adapter was about to write to the image.
  // THE LAYOUT IS FIXED: the one hard disk is ALWAYS bank 0's master (IDE
  // unit 0) and bank 1 belongs to the CD-ROM (pc9821_atapi, bank 1's master, owns that bank's
  // reads when it is built); without the CD bank 1 is an empty connector and floats here. That is
  // the stock CD-equipped Xe10's layout and NP2kai's default (HDD at unit 0, CD at unit 2). The
  // probed Xe10 answers at bank 1 and floats bank 0 (docs/probes/IDE.TXT, ATA.TXT) only because
  // its CF card sits in the CD connector; the float VALUES below are that machine's empty-bank
  // measurement, applied to the empty bank. There is no second hard disk.
  wire bank_has_interface = !channel_reg[0];
  // DEVICE 1 (0x064C bit 4) IS ABSENT: the disk is its bank's master (the Xe10
  // firmware never probes a slave, BANK3@0x0789-0x07B7). An absent device 1 follows ATA-3 r6
  // s.9.5.1: STATUS and ALTERNATE STATUS read 0x00, and a command
  // written for it is not executed - no DRQ, no data, no IRQ - except EXECUTE DEVICE DIAGNOSTIC,
  // which device 0 runs for the pair. Software that runs on the real Xe10 depends on it: the
  // Linux/98 image boots there with its IDE driver (pc98_ide.c), whose
  // pc98ide_identify selects 0xF0 and gives the unit up when STATUS reads 0x00 or 0xFF, or 0x00
  // after IDENTIFY; a "master answers for DEV=1" model gives it a phantom hdb that aliases
  // the master. Re-selecting device 0 restores everything: the master's own state is untouched.
  wire        slave_sel     = drive_head[4];
  function automatic slave_ignores(input [7:0] cmd);
    slave_ignores = drive_head[4] && (cmd != 8'h90);
  endfunction
  reg irq_disable;
  // The interrupt-pending state and INTRQ. Pending follows NP2kai cbus/ideio.c: a completion
  // under nIEN neither raises nor clears it (setintr's `if (!(drv->ctrl & IDECTRL_NIEN))`), and
  // a status read under nIEN does not acknowledge it (ideio_i64e). INTRQ is released while
  // nIEN is set (ATA-3 s.7.2.9: "When nIEN=1 ... the INTRQ signal shall be in a high impedance
  // state"), so it cannot hide the other bank's edge on the ORed IRQ9 (pc9821_system; MAME
  // pc9801.cpp ideirq INPUT_MERGER_ANY_HIGH). tb_pc9821_atapi C18.
  reg irq_pend;
  assign irq = irq_pend && !irq_disable;
  reg soft_reset;
  reg [8:0] pio_byte;
  reg [8:0] sectors_left;
  // The LBA domain is LBA28: the task file names at most 2^28-1 (CHS tops out at
  // 65535*4080 + 4079 < 2^28 too), so every LBA this module holds or issues is 28 bits and the
  // port's upper four bits are zero. A transfer that would carry past sector 2^28-1 (an image
  // over 128 GiB) cannot be addressed by the interface in the first place.
  reg [27:0] current_lba;
  // THE REQUEST LBA IS current_lba OR ONE PAST IT. Every block_read/block_write pulse is set on
  // the same edge as this flag, and on that edge the request's LBA is the NEW current_lba (a
  // command start, a write commit) or the new current_lba + 1 (the read-ahead: issued after a
  // fetch with current_lba unchanged as current + 1, or on the guest's last word with
  // current_lba stepping to current + 1 as current + 2). So the port is formed from current_lba
  // instead of being a second 28-bit register. Between pulses it follows current_lba; its only
  // reader, pc9821_block_share, samples it on the pulse alone (`a_pend_lba <= a_req_lba`).
  reg        lba_plus1;
  assign block_lba = {4'd0, current_lba + {27'd0, lba_plus1}};

  // Read-ahead: two 256-word sector buffers so sector N+1's HPS
  // fetch overlaps sector N's PIO drain. active_buf is the buffer the guest
  // reads; fill_buf is the one the adapter fills. They ping-pong once per
  // completed sector, and the adapter never writes the guest's buffer.
  reg active_buf, fill_buf;
  // A read-ahead block request is outstanding / has landed / failed.
  reg prefetch_busy, prefetch_valid, prefetch_error;

  // IDENTIFY geometry words. The machine's own drive (docs/probes/IDE.TXT) reports a
  // FACTORY default of 16 heads x 63 sectors in words 1/3/4/6 and the CURRENT,
  // IDP-adopted geometry in words 54/55/56, with the current LBA capacity in words
  // 57/58 equal to the image size ROUNDED DOWN to a multiple of the adopted geometry:
  // w54 = floor(capacity / (heads*sectors)), w57/58 = w54 * heads * sectors =
  // capacity - (capacity mod (heads*sectors)). The captured 7,880,544-sector drive
  // reads w1=0x1E8A (7818 = 7880544/1008), w3=0x0010, w4=0x7E00 (63*512),
  // w6=0x003F, while w54=0xE259 (57945 = 7880544/136), w55=0x0008, w56=0x0011,
  // w57/58=0x00783F48 (7,880,520) and w60/61=0x00783F60 (7,880,544). NP2kai
  // recomputes the current words the same way (setidentify ideio.c:115-120) but puts
  // the host geometry in w1/3/6; the capture wins.
  //
  // heads*sectors is the IDP-adopted value (1..4080), so no constant-division identity
  // covers it. A 32-clock shift-and-subtract divider recomputes w54/w57/58 and w1 in two
  // passes (the adopted geometry, then the factory 16*63 = 1008 for w1), and it runs
  // continuously: a lap is 64 clocks, so a new capacity or IDP geometry reaches the words
  // within 128 clocks. A combinational divider on the I/O read path misses timing --
  // the same reason the earlier single-divisor /136 form was a divider and then a DSP
  // product before this geometry became variable.
  reg [31:0] div_sq;          // the dividend shifting out of the top, the quotient shifting in
  /* verilator lint_off UNUSEDSIGNAL */   // the remainder stays below the divisor (<= 4080), so bit 12 never leaves 0
  reg [12:0] div_remainder;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [4:0]  div_count;
  reg        div_pass;
  reg [15:0] default_cylinders;   // word 1: the factory 16-head/63-sector count
  reg [15:0] current_cylinders;   // word 54: the adopted geometry's count
  reg [31:0] current_capacity;    // words 57/58: capacity rounded down to the adopted geometry
  // Geometry adopted from INITIALIZE DEVICE PARAMETERS. A real drive adopts
  // what the host asks for (NP2kai ideio.c, QEMU cmd_init_drive_params), and
  // the PC-98 BIOS narrows a 16-head/63-sector drive with exactly this command,
  // so refusing the request turns a working disk into an aborted one. The
  // reset values keep the platform default (the 8-head/17-sector geometry the
  // BIOS narrows TO) until a guest asks for something else.
  reg [3:0]  idp_head_max;   // highest head number, i.e. heads - 1
  reg [7:0]  idp_sectors;

  // Two 512-byte sectors as 256 words each, indexed by {bank, word}. Kept as a
  // single 16-bit write port with a synchronous read so Quartus infers M10K
  // memory (two blocks): as 512 separate 8-bit entries with two writes per
  // cycle and a whole-array reset it was built from ~4100 flip-flops (~1.5k
  // ALMs), and with the asynchronous read it was MLAB -- the design's only
  // "ALMs used for memory" (160) plus 104 LUT of read muxing. The single
  // write port is what lets the memory infer at all: a second write port turns
  // this back into several thousand flip-flops.
  (* ramstyle = "M10K, no_rw_check" *) reg [15:0] sector_buf[0:511];

  // One write port and one synchronous read port, each muxed by transfer
  // direction: a read transfer is filled by the block adapter and read out by
  // the guest, a write transfer is filled by the guest and drained by the block
  // adapter. Keeping exactly one port of each kind is what lets Quartus go on
  // inferring the buffer here.
  reg  [7:0] pio_lo;   // low byte of the word the guest is writing
  wire       buf_wr_guest = (xfer_state == X_PIO_WRITE);
  // The adapter fills the buffer in X_WAIT_BLOCK (first sector) and in
  // X_PIO_READ (the read-ahead while the guest drains the current sector).
  wire       buf_wr_fetch = block_buf_we &&
                            (xfer_state == X_WAIT_BLOCK || xfer_state == X_PIO_READ);
  // The guest's half of the write port is inside the bank window like every other
  // task-file access: at a bank with no interface a 16-bit `out` reaches nothing
  // (NP2kai ideio_w16 needs getidedrv(), cbus/ideio.c:1503-1515), and a word that did
  // land would splice two bytes of another value into the sector the adapter is about
  // to write to the image. The ADAPTER's fill is not gated - it is the backend, not a
  // task-file access, and it only runs under the transfer state above.
  wire       buf_wr_en    = buf_wr_guest
                          ? (io_wr && io_addr == 16'h0641 && status_reg[3] &&
                             bank_has_interface)
                          : buf_wr_fetch;
  wire [8:0]  buf_wr_addr = buf_wr_guest ? {active_buf, pio_byte[8:1]}
                                         : {fill_buf, block_buf_addr};
  wire [15:0] buf_wr_data = buf_wr_guest ? {io_din, pio_lo} : block_buf_data;

  // Which sector of the current block the presented sector is, and the step to
  // the next: NP2kai `readsec` raises the interrupt while its counter is 0 and
  // then advances it, wrapping at the negotiated block length.
  function automatic [7:0] block_step(input [7:0] pos, input [7:0] size);
    begin
      block_step = ((size == 8'd0) || (pos + 8'd1 >= size)) ? 8'd0 : (pos + 8'd1);
    end
  endfunction

  // NP2kai `writesec` increments its in-block counter and THEN tests it, so a
  // write raises the boundary interrupt on the value after the step; block_size 1
  // wraps every sector and reproduces WRITE SECTORS' one-interrupt-per-sector.
  wire [7:0] write_pos_next = block_step(block_pos, block_size);

  always @(posedge clk) if (buf_wr_en) sector_buf[buf_wr_addr] <= buf_wr_data;

  // Which direction the in-flight block transfer is, so the sector buffer's read
  // port stays pointed at the ADAPTER for the whole of it - including a drain,
  // where the transfer has been abandoned but the adapter is still reading.
  // Keying the mux on the state alone sent a draining write's reads back to the
  // guest's byte serializer, so the adapter drained the wrong addresses.
  reg         block_dir_write;
  wire        buf_rd_block = block_dir_write &&
                             (xfer_state == X_WAIT_WRITE || xfer_state == X_DRAIN);
  // A write transfer is always bank 0; a read is the buffer the guest is draining.
  wire [8:0]  buf_rd_addr  = buf_rd_block ? {1'b0, block_rd_addr}
                                          : {active_buf, pio_byte[8:1]};
  // Synchronous M10K read: sector_word trails buf_rd_addr by one clk. Both
  // consumers present their address a cycle before they latch the data -- the
  // block adapter's drain samples "the address presented last cycle", and the
  // guest's PIO byte pointer only moves on the 0x0641 strobe of the PREVIOUS
  // word (or a command write), so it is stable across the read latch of every
  // 0x0640/0x0641 access and the one-cycle read is invisible at both ports.
  // That one cycle is the entire cost of moving the buffer out of MLAB.
  reg  [15:0] sector_word_q;
  always @(posedge clk) sector_word_q <= sector_buf[buf_rd_addr];
  wire [15:0] sector_word  = sector_word_q;

  assign block_rd_data = sector_word;

  wire [15:0] chk_word = identify_word(pio_byte[8:1]);   // the one IDENTIFY table instance
  wire [15:0] pio_word = (xfer_state == X_PIO_IDENT)
      ? ((pio_byte[8:1] == 8'd255) ? identify_integrity
                                   : chk_word)
      : sector_word;

  // NP2kai's ideio_r16 also gates the data read on the transfer DIRECTION
  // (drv->bufdir == IDEDIR_IN); qemu's ide_data_readw requires ide_is_pio_out.
  // A read during a WRITE data phase must not answer the buffer the guest is assembling.
  wire data_dir_in = (xfer_state == X_PIO_READ) || (xfer_state == X_PIO_IDENT);

  // The measured float of a bank with no interface: the even task-file registers
  // 0x0E, the second channel's 0x740-0x74A and the 0x74C/0x74E pair 0x0F, and
  // 0x0641 the module's own 0xFF. The value is not cosmetic - the ROM's poll does
  // `test al,0x27` and 0xFF passes it where 0x0E fails.
  // 0x0430/0x0432/0x0433/0x0435 are the interface's own registers, live at every
  // bank value: they select and report the interface, not the task file behind it.
  wire aux_port = (io_addr == 16'h0430) || (io_addr == 16'h0432) ||
                  (io_addr == 16'h0433) || (io_addr == 16'h0435);
  wire device_present = mounted && bank_has_interface;
  // Within a connected bank the data port keeps the ATA rule (0xFF while DRQ is
  // clear); the window above decides whether the port is connected at all, and
  // it applies to reads and writes alike.
  wire [27:0] lba28 = {drive_head[3:0], cylinder_high, cylinder_low, sector_number};
  // The geometry validation and the CHS address are registered rather than
  // combinational on the task-file registers: the bare form would chain
  // idp_head_max -> chs_valid -> the command decode -> abort_command into one
  // 20 ns path. A one-cycle-old view is safe because a
  // task-file register write costs at least two clk_sys cycles on the I/O bus, so
  // a command never sees a stale value.
  reg [15:0] idp_stride;      // heads * sectors
  always @(posedge clk) begin
    if (!rst_n)
      idp_stride <= 16'd136;   // 8 heads * 17 sectors, the platform default
    else
      idp_stride <= ({12'd0, idp_head_max} + 16'd1) * {8'd0, idp_sectors};
  end
  // The divider's divisor and one step of its shift-and-subtract arithmetic. The
  // first pass divides by the adopted heads*sectors, the second by the factory
  // 16*63 = 1008 for word 1. stride <= 16*255 = 4080, so 12 bits; the trial
  // widens to 13 for the bring-down bit and the remainder stays below the divisor.
  wire [12:0] div_divisor = div_pass ? 13'd1008 : idp_stride[12:0];
  wire [12:0] div_trial = {div_remainder[11:0], div_sq[31]};
  wire        div_ge    = (div_trial >= div_divisor);
  wire [12:0] div_remainder_next = div_ge ? (div_trial - div_divisor) : div_trial;
  wire [31:0] div_quotient_next = {div_sq[30:0], div_ge};
  reg        chs_sec_ok, chs_head_ok;
  reg [27:0] chs_lba_q;
  always @(posedge clk) begin
    chs_sec_ok  <= (sector_number >= 8'd1) && (sector_number <= idp_sectors);
    // Four bits, because an adopted geometry can have 16 heads; a three-bit
    // slice would silently wrap that to zero.
    chs_head_ok <= (drive_head[3:0] <= idp_head_max);
    chs_lba_q   <= 28'(({16'd0, cylinder_high, cylinder_low} * idp_stride) +
                       ({28'd0, drive_head[3:0]} * {24'd0, idp_sectors}) +
                       ({24'd0, sector_number} - 32'd1));
  end
  wire chs_valid = chs_sec_ok && chs_head_ok;
  wire [27:0] chs_lba = chs_lba_q;
  wire [27:0] requested_lba = drive_head[6] ? lba28 : chs_lba;

  // The sector count a data command transfers: 0 means 256 (ATA). One wire, so the range check
  // and the block start cannot disagree about the count.
  wire [8:0] data_count = (sector_count == 8'd0) ? 9'd256 : {1'b0, sector_count};
  // End-of-image guard: after `requested_lba < capacity` is proven the
  // command must also FIT, i.e. count <= capacity - lba, which is exactly lba + count - 1 <=
  // capacity - 1. Subtracting only after lba < capacity is proven keeps the subtraction exact
  // (no 32-bit underflow) and lets the last sector through while a count-2 request at
  // capacity-1 is rejected. Registered like chs_lba_q: a task-file write costs at least two
  // clk_sys, so the one-cycle-old view a command sees is never stale.
  reg [32:0] lba_room_q;
  always @(posedge clk) lba_room_q <= {1'b0, capacity} - {5'd0, requested_lba};
  // lba_room_q[32] (the borrow) is "requested_lba > capacity"; room 0 is "== capacity" and fails
  // the count compare (count >= 1), which also covers capacity == 0. So this one test is
  // `requested_lba >= capacity || capacity == 0 || !range_ok`.
  wire range_ok = !lba_room_q[32] && ({23'd0, data_count} <= lba_room_q[31:0]);

  // A block transfer the adapter has been handed and has not finished answering.
  // It stays true through X_DRAIN, because a drain is exactly a transfer that was
  // abandoned while the adapter was still serving it.
  wire block_in_flight = (xfer_state == X_WAIT_BLOCK) ||
                         (xfer_state == X_WAIT_WRITE) ||
                         (xfer_state == X_DRAIN) ||
                         prefetch_busy;

  // Whether the one-shot block_done pulse is being RETIRED by the completion
  // handlers below in this same cycle. Those handlers run before the task-file
  // write handler, so an SRST write colliding with the pulse must not park in
  // X_DRAIN on the pre-consumption state: the pulse is already eaten, and the
  // drain would wait for a completion that never recurs (BSY forever). The
  // X_WAIT_BLOCK arm counts as retired only when it does NOT re-issue a prefetch
  // (block_error or the last sector): when sectors_left > 1 it issues a fresh
  // request whose completion is still owed, and the drain is correct.
  wire block_done_retired = block_done &&
      ((xfer_state == X_DRAIN) ||
       (xfer_state == X_WAIT_WRITE) ||
       ((xfer_state == X_PIO_READ) && prefetch_busy) ||
       ((xfer_state == X_WAIT_BLOCK) && (block_error || (sectors_left <= 9'd1))));

  // SINGLE-CYCLE EVENT DISCIPLINE (docs/single-cycle-event-discipline.md): the read-ahead
  // completion is consumed by EXACTLY ONE handler per cycle. `prefetch_retire`
  // is the retire decode shared by both candidate consumers;
  // `last_word_take` names the one where the guest's last-word read takes the
  // arriving sector in place (not the last-word handler being the later NBA to
  // override the prefetch-latch arm - two consumers of one block_done, resolved
  // by source position, R2).
  wire prefetch_retire = (xfer_state == X_PIO_READ) && prefetch_busy && block_done;
  wire last_word_take = io_rd && (io_addr == 16'h0641) && status_reg[3] &&
                        (xfer_state == X_PIO_READ) && (pio_byte == 9'd510) &&
                        (sectors_left > 9'd1) && prefetch_retire;

  // Every completion handler below consumes the pulse it retires (H7), so a
  // task-file COMMAND write landing in the same clk sees the POST-retire device,
  // not the pre-consumption state the 0x64E guard reads (pulses.md H8: a command
  // presented against a stale transfer state was silently dropped). With the
  // completion retired this cycle the dispatch takes over exactly as it would
  // had the completion been observed one cycle earlier.
  wire block_done_retire_now = block_done &&
      ((xfer_state == X_DRAIN) || (xfer_state == X_WAIT_WRITE) ||
       (xfer_state == X_WAIT_BLOCK) || ((xfer_state == X_PIO_READ) && prefetch_busy));
  // The dispatch that supersedes a retiring transfer. Its begin_block_read /
  // begin_block_write own the block request from here: the retiring handler's
  // read-ahead re-issue must not also go out (the adapter serves one request,
  // and the orphan completion would then land on the new transfer's state).
  wire command_takeover = io_wr && bank_has_interface && (io_addr == 16'h064E) &&
      device_present && !slave_ignores(io_din) && block_done_retire_now &&
      (status_reg[7] || (xfer_state != X_IDLE));

  function automatic [15:0] identify_word(input [7:0] index);
    begin
      case (index)
        8'd0: identify_word = 16'h044A;  // general config, the machine's own drive
        8'd1: identify_word = default_cylinders;
        8'd3: identify_word = 16'h0010;  // factory default heads
        8'd4: identify_word = 16'h7E00;  // 63 sectors * 512 bytes per track
        8'd5: identify_word = 16'h0200;  // unformatted bytes per sector
        8'd6: identify_word = 16'h003F;  // factory default sectors per track
        // Serial number: the core's own identity, kept consistent with the model
        // string below (NP2kai setidentify's serial, cbus/ideio.c:65) rather than
        // the captured CF card's. Two characters per word, first character high.
        8'd10: identify_word = 16'h3832;
        8'd11: identify_word = 16'h3439;
        8'd12: identify_word = 16'h3139;
        8'd13: identify_word = 16'h3334;
        8'd14: identify_word = 16'h3131;
        8'd15: identify_word = 16'h3932;
        8'd16, 8'd17, 8'd18, 8'd19: identify_word = 16'h2020;
        // Obsolete buffer words, reported by the machine's drive.
        8'd20: identify_word = 16'h0002;
        8'd21: identify_word = 16'h0002;
        // NP2kai tmp[22] = 4 ECC bytes.
        8'd22: identify_word = 16'h0004;
        // Firmware revision, the core's own (NP2kai cbus/ideio.c:66).
        8'd23: identify_word = 16'h4135;
        8'd24: identify_word = 16'h552E;
        8'd25: identify_word = 16'h3132;
        8'd26: identify_word = 16'h3030;
        // Model string "QUANTUM FIREBALL CR" padded with spaces, two chars per word
        // (NP2kai setidentify cbus/ideio.c:100-106).
        8'd27: identify_word = 16'h5155;   // 'Q','U'
        8'd28: identify_word = 16'h414E;   // 'A','N'
        8'd29: identify_word = 16'h5455;   // 'T','U'
        8'd30: identify_word = 16'h4D20;   // 'M',' '
        8'd31: identify_word = 16'h4649;   // 'F','I'
        8'd32: identify_word = 16'h5245;   // 'R','E'
        8'd33: identify_word = 16'h4241;   // 'B','A'
        8'd34: identify_word = 16'h4C4C;   // 'L','L'
        8'd35: identify_word = 16'h2043;   // ' ','C'
        8'd36: identify_word = 16'h5220;   // 'R',' '
        8'd37, 8'd38, 8'd39, 8'd40, 8'd41, 8'd42, 8'd43, 8'd44,
        8'd45, 8'd46: identify_word = 16'h2020;   // space padding
        // NP2kai tmp[47] = 0x8000 | IDEIO_MULTIPLE_MAX (128); this model
        // WITHDRAWS that advertisement. It buffers one sector at a time, so a
        // streamed block can outrun the HPS fetch and drop DRQ, and the Xe10 ROM's
        // READ MULTIPLE (BANK3 0x9603) consumes 256*M words after ONE interrupt
        // without checking DRQ -- it would splice 0x00 into the file. 0 makes the
        // ROM take the gap-immune single-sector READ SECTORS path. The commands
        // are still implemented (see set_multiple). Evidence
        8'd47: identify_word = 16'h0000;
        // Capabilities: LBA only. The machine's 0x0B00 also sets DMA (bit 8) and
        // IORDY (bit 11); this model is PIO-only with fixed-cycle transfers and
        // no DMA command, so those bits stay clear (tb_pc9821_ata_advertised
        // enforces advertised => executable).
        8'd49: identify_word = 16'h0200; // LBA supported
        // The machine's obsolete PIO transfer-cycle word.
        8'd51: identify_word = 16'h0200;
        // Field validity: words 54-58 and 64-70 are populated. Bit 2 (word 88
        // UDMA valid) stays clear because no UDMA is advertised or implemented.
        8'd53: identify_word = 16'h0003;
        8'd54: identify_word = current_cylinders;
        8'd55: identify_word = {12'd0, idp_head_max} + 16'd1;
        8'd56: identify_word = {8'd0, idp_sectors};
        8'd57: identify_word = current_capacity[15:0];
        8'd58: identify_word = current_capacity[31:16];
        // NP2kai tmp[59] = 0x0100 | mulmode. Word 59's valid bit must agree with
        // word 47: with no multiple advertisement the current setting is not valid.
        8'd59: identify_word = 16'h0000;
        8'd60: identify_word = capacity[15:0];
        8'd61: identify_word = capacity[31:16];
        // NP2kai tmp[64] = 0x0003 (PIO mode 3, 4).
        8'd64: identify_word = 16'h0003;
        8'd80: identify_word = 16'h0000;  // the machine claims no ATA major level
        // NP2kai tmp[82] = 0x4200 (NOP, DEVICE RESET, Write Cache). The machine's
        // 0x7003 also claims READ/WRITE BUFFER, security and SMART, none of which
        // this model executes; 0x4200 is the honest command-set answer.
        8'd82: identify_word = 16'h4200;
        // bit 14 = this device passed power-on diagnostics. The machine's word is
        // 0x4000 (no cable-ID bits); NP2kai's 0x407b (cbus/ideio.c:200) is a
        // different device's answer and is not copied.
        8'd93: identify_word = 16'h4000;
        8'd217: identify_word = 16'h0001; // nominal rotation rate: non-rotating
        default: identify_word = 16'd0;
      endcase
    end
  endfunction

  // Word 255: the ATA integrity word. Bits 7:0 are the fixed 0xA5 signature and
  // bits 15:8 the two's complement that makes the sum of all 512 bytes of the
  // page 0 mod 256. The checksum is over THIS device's own 255 words, so a driver
  // that verifies the page sees a self-consistent result; the captured CF card's
  // E9 would not validate a different model/capacity, so it is not copied.
  //
  // The integrity word (IDENTIFY word 255: 0xA5 signature + the two's-complement checksum of the
  // other 255 words) is the byte sum of the words THIS transfer delivered, accumulated as the guest
  // reads them (the 0x0641 strobe that steps pio_byte), so the page is walked by the one
  // identify_word instance the data port already reads. Recomputing it in the background
  // from a SECOND instance of the table (one word per clk after each divider run) costs ~70 ALMs
  // (module-alone) and reads the same words the guest is about to read. The two agree for
  // every transfer in which the page does not change between its words; the only difference is a
  // geometry change in the middle of one IDENTIFY, which the background form would have folded in
  // and this one reports as the words were delivered. (Word 255 itself is 0 in the sum.)
  reg [ 7:0] chk_sum8;    // running byte sum, mod 256, of the words delivered since the command
  wire [15:0] identify_integrity = {8'h00 - chk_sum8 - 8'hA5, 8'hA5};
  wire ident_step = io_rd && io_addr == 16'h0641 && status_reg[3] && bank_has_interface &&
                    (xfer_state == X_PIO_IDENT) && (pio_byte[8:1] != 8'd255);
  always @(posedge clk) begin
    if (!rst_n || xfer_state != X_PIO_IDENT) chk_sum8 <= 8'd0;
    else if (ident_step) chk_sum8 <= chk_sum8 + chk_word[7:0] + chk_word[15:8];
  end

  always @* begin
    io_dout = 8'hFF;
    if (!aux_port && !bank_has_interface) begin
      // A bank with no interface behind it floats, and the machine's float is
      // an exact value: the task-file registers 0x0642-0x064E at 0x0E, the data
      // register 0x0640 at 0xFF (confirmed twice), the second channel's
      // 0x740-0x74A and the 0x74C/0x74E pair 0x0F, and 0x0641 the 0xFF below.
      case (io_addr)
        16'h0640: io_dout = 8'hFF;
        16'h0642, 16'h0644, 16'h0646, 16'h0648, 16'h064A,
        16'h064C, 16'h064E: io_dout = 8'h0E;
        // The second channel's task file (0x740-0x74A) floats at 0x0F, not
        // 0x0E: the machine reads 0x0F at each even register
        // (`0740 0F 0742 0F... 074A 0F`) and at the
        // 0x74C/0x74E pair ("ATA BLOCK as left by POST/DOS").
        16'h0740, 16'h0742, 16'h0744, 16'h0746, 16'h0748, 16'h074A,
        16'h074C, 16'h074E: io_dout = 8'h0F;
        default: ;
      endcase
    end else if (!device_present && io_addr >= 16'h0640 && io_addr <= 16'h064E) begin
      // No drive on the selected channel: NP2kai getidedrv() returns NULL and every
      // task-file handler returns 0xff (ideio_i64e, ideio_i646); qemu
      // pc98_ide_cmd_read is the same. This also covers the image not yet mounted.
      io_dout = 8'hFF;
    end else case (io_addr)
      // 0x0430 bit 6 is NOT set, despite the machine reading 0x41. Both
      // references define bit 6 as "the selected channel has a slave" and this
      // model has one master. The probe has answered 0x41 twice, reproducibly,
      // with the internal IDE present, so bit 6 is a STRAP bit here and the read
      // returns the measurement.
      16'h0430: io_dout = 8'h41;
      16'h0432: io_dout = channel_reg;
      // 0x0433 is the source-identification port, NOT an IRQ-pending flag.
      // NP2kai's ideio_i433 answers bit 1 (0x02) = "the selected bank has a
      // connected device": (bank[1] & 1) ? 0x02 : 0x00, forced clear when the
      // selected unit has no drive at all (cbus/ideio.c:660-675). This model's
      // "selected bank" is channel_reg[0] and its "connected device" is the
      // mounted image, so bit 1 = device_present exactly. QEMU's
      // irq_levels form (bit 0 = pending ch0 IRQ) has both the bit position and
      // the meaning wrong, so a driver identifying the interface would read an IRQ
      // sample as a connection answer. Measured 0x00 at
      // the idle DOS prompt with bank 0x00 (probes/PROBE.TXT `0433=00`), which
      // every model answers alike.
      16'h0433: io_dout = device_present ? 8'h02 : 8'h00;
      16'h0435: io_dout = 8'h00;
      // The data register answers only a READ transfer (direction gated above).
      16'h0640: io_dout = (status_reg[3] && data_dir_in) ? pio_word[7:0] : 8'h00;
      16'h0641: io_dout = (status_reg[3] && data_dir_in) ? pio_word[15:8] : 8'h00;
      16'h0642: io_dout = error_reg;
      16'h0644: io_dout = sector_count;
      16'h0646: io_dout = sector_number;
      16'h0648: io_dout = cylinder_low;
      16'h064A: io_dout = cylinder_high;
      16'h064C: io_dout = drive_head;
      16'h064E: io_dout = slave_sel ? 8'h00 : status_reg;
      16'h074C: io_dout = slave_sel ? 8'h00 : status_reg;  // alternate status, never clears the IRQ
      // 0x74C/0x74E mirror each other only while the bank floats (both 0x0F:
      // "ATA BLOCK as left by POST/DOS"). With the bank mapped
      // they differ - 0x74C reads the idle status 0x50, 0x74E reads 0x00
      // (docs/probes/ATA.TXT). The drive-address form this core used
      // to synthesise is the AT convention; the measurement wins.
              16'h074E: io_dout = 8'h00;
      // THE SECOND CHANNEL'S TASK FILE AT THE LIVE BANK reads 0x00 at every even
      // register and 0xFF at its odd partner. The machine says so three times
      // (docs/probes/IDE.TXT, "task file with 0432=01 (live bank)":
      // `0740=00 0741=FF 0742=00 0744=00 0746=00 0748=00 074A=00`), and without these
      // arms the mapped bank fell through to io_dout's initial 0xFF (the
      // read-back weak spot AGENTS.md names).
      // The odd bytes keep the initial 0xFF, which is the one measured odd value.
      16'h0740, 16'h0742, 16'h0744, 16'h0746, 16'h0748, 16'h074A: io_dout = 8'h00;
      default:  ;
    endcase
  end

  // Command-level diagnostics (see the dbg_cmd port description).
  reg [7:0] dbg_cmd_cnt, dbg_last_cmd, dbg_abort_cnt;
  reg [3:0] dbg_abort_reason;
  // 1 = block engine error, 2 = read-path validation, 3 = IDP, 4 = (retired:
  // READ MULTIPLE now completes), 5 = SET MULTIPLE with an unsupported count,
  // 6 = SET FEATURES, 7 = write-path validation, 8 = unsupported command.
  assign dbg_cmd = {dbg_abort_cnt, dbg_last_cmd, dbg_cmd_cnt,
                    {4'b0, dbg_abort_reason}};
  // The transfer context (see the port comments): the record's ALB and ASE fields.
  assign dbg_lba = {4'd0, current_lba};
  assign dbg_sec = {sector_count, error_reg};

  // The reason is carried in the debug byte's spare low nibble: without it a
  // hardware log cannot distinguish "the guest asked for something we do not
  // implement" from "our own block engine failed", and the two need opposite
  // fixes.
  task automatic abort_command(input [3:0] reason);
    begin
      dbg_abort_reason <= reason;
      error_reg <= ATA_ERR_ABRT;
      // NP2kai cmdabort sets status = DRDY | ERR with DSC CLEAR (cbus/ideio.c); qemu
      // ide_abort_command is the same 0x41. Keeping DSC (0x51) made a guest that
      // classifies on the exact {ERROR,STATUS} pair see a different status.
      status_reg <= ATA_ST_DRDY | ATA_ST_ERR;
      xfer_state <= X_IDLE;
      pio_byte <= 9'd0;
      // Abandon any read-ahead with the transfer. A block error while the FSM waits in
      // X_WAIT_BLOCK leaves prefetch_busy set, so `block_in_flight` reports a transfer
      // forever and the next SRST parks in X_DRAIN: BSY set, every command ignored.
      // Mirrors begin_block_read.
      prefetch_busy  <= 1'b0;
      prefetch_valid <= 1'b0;
      // The error record of a read-ahead completion retired THIS cycle survives
      // the discard (set-wins, race-idiom R3): `prefetch_error` always equals
      // the error of the completion last retired, so an abort that consumes an
      // errored prefetch still records what it consumed. With no retiring
      // completion this is the plain discard it has always been.
      prefetch_error <= prefetch_retire && block_error;
      // Every other completion respects nIEN (0x74C bit 1, `irq_disable`); an
      // abort is a completion too, and a guest that has disabled interrupts for
      // polled I/O must not be interrupted by one. BANK3 clears nIEN on the
      // second write of the SRST pair (BANK3@0xF9135 `out 0x74C,0x06`, then
      // @0xF9140 `out 0x74C,0x00`; our handler loads irq_disable from bit 1 of
      // each write), so this only changes behaviour for a guest that raises it
      // deliberately.
      irq_pend <= irq_pend || !irq_disable;
      dbg_abort_cnt <= dbg_abort_cnt + 8'd1;
    end
  endtask

  task automatic begin_block_write(input [27:0] lba, input [8:0] count,
                                   input [7:0] block);
    begin
      current_lba  <= lba;
      sectors_left <= count;
      // Same interrupt cadence as the read side, but the write path tests the
      // stepped position (see `write_pos_next`).
      block_size <= block;
      block_pos  <= 8'd0;
      error_reg  <= 8'd0;
      status_reg <= ATA_READY | ATA_ST_DRQ;
      xfer_state <= X_PIO_WRITE;
      pio_byte   <= 9'd0;
      pio_lo     <= 8'd0;
      // A write is filled by the guest and drained from bank 0.
      active_buf     <= 1'b0;
      prefetch_valid <= 1'b0;
      // No interrupt is RAISED at command time: a device raises it when the data
      // for a sector has been taken. A pending level is not retracted here
      // either: NP2kai lowers irq only at the 0x064E status read (ideio_i64e's
      // pic_resetirq) and its command dispatch never does, so an unacked
      // request must survive the command issue for the ISR that has not run yet.
    end
  endtask

  task automatic begin_block_read(input [27:0] lba, input [8:0] count,
                                  input [7:0] block);
    begin
      current_lba <= lba;
      lba_plus1 <= 1'b0;   // block_lba = lba
      block_read <= 1'b1;
      block_dir_write <= 1'b0;
      sectors_left <= count;
      // The interrupt cadence for this command: one per `block` sectors, so a
      // single-sector READ SECTORS (block 1) keeps its one-interrupt-per-sector
      // behaviour and READ MULTIPLE raises one per negotiated block.
      block_size <= block;
      block_pos  <= 8'd0;
      status_reg <= ATA_ST_BSY;
      error_reg <= 8'd0;
      xfer_state <= X_WAIT_BLOCK;
      pio_byte <= 9'd0;
      // The first fetch lands in bank 0; the guest drains it from there and the
      // read-ahead takes bank 1. Any prefetch left over from an aborted command
      // is abandoned with the buffers.
      active_buf     <= 1'b0;
      fill_buf       <= 1'b0;
      prefetch_busy  <= 1'b0;
      prefetch_valid <= 1'b0;
      prefetch_error <= 1'b0;
    end
  endtask

  // The reference advances the task-file address registers as each sector transfers:
  // NP2kai incsec() (drv->sn++ in LBA mode; the sn/hd/cy carry in CHS mode, cbus/ideio.c)
  // and qemu ide_set_sector(). `next_lba` is the LBA of the sector being presented next.
  /* verilator lint_off UNUSEDSIGNAL */   // capacity is under 2^28 sectors, so next_lba[31:28] is never read
  task automatic advance_taskfile(input [27:0] next_lba);
    begin
      if (drive_head[6]) begin
        sector_number <= next_lba[7:0];
        cylinder_low  <= next_lba[15:8];
        cylinder_high <= next_lba[23:16];
        drive_head    <= {drive_head[7:4], next_lba[27:24]};
      end else if (sector_number >= idp_sectors) begin
        sector_number <= 8'd1;
        if (drive_head[3:0] >= idp_head_max) begin
          drive_head[3:0] <= 4'd0;
          if (cylinder_low == 8'hFF) begin
            cylinder_low  <= 8'h00;
            cylinder_high <= cylinder_high + 8'd1;
          end else cylinder_low <= cylinder_low + 8'd1;
        end else drive_head[3:0] <= drive_head[3:0] + 4'd1;
      end else sector_number <= sector_number + 8'd1;
    end
  endtask
  /* verilator lint_on UNUSEDSIGNAL */

  always @(posedge clk) begin
    if (!rst_n) begin
      xfer_state     <= X_IDLE;
      // An ATA device reports 0x01 (AMNF) in ERROR once its power-on diagnostic
      // has run, and the PC-98 disk BIOS uses precisely that to decide a drive
      // is usable: a device that has never been reset reads 0x00 there and is
      // rejected before it is identified, leaving the geometry empty.
      error_reg      <= 8'h01;
      sector_count   <= 8'd1;
      sector_number  <= 8'd1;
      cylinder_low   <= 8'd0;
      cylinder_high  <= 8'd0;
      drive_head     <= 8'hA0;
      status_reg     <= ATA_READY;
      channel_reg    <= 8'd0;
      irq_disable    <= 1'b0;
      soft_reset     <= 1'b0;
      pio_byte       <= 9'd0;
      sectors_left   <= 9'd0;
      current_lba    <= 28'd0;
      div_sq          <= capacity;
      div_remainder   <= 13'd0;
      div_count       <= 5'd0;
      div_pass        <= 1'b0;
      default_cylinders <= 16'd0;
      current_cylinders <= 16'd0;
      current_capacity  <= 32'd0;
      idp_head_max <= 4'd7;   // 8 heads until IDP says otherwise
      idp_sectors  <= 8'd17;
      // NP2kai's devinit leaves mulmode at IDEIO_MULTIPLE_MAX (128), which is the
      // value IDENTIFY word 59 reports, so a guest that reads word 59 and reads
      // without a SET MULTIPLE still sees the advertised default.
      set_multiple <= 8'd128;
      block_size   <= 8'd1;
      block_pos    <= 8'd0;
      block_read     <= 1'b0;
      block_write    <= 1'b0;
      lba_plus1      <= 1'b0;
      // Reset because leaving it out makes the buffer's read mux depend on an X in
      // simulation. Every transfer sets it correctly before it can matter -- a read
      // through begin_block_read and a write at the sector-complete edge -- so no
      // current path can observe the difference.
      block_dir_write <= 1'b0;
      pio_lo         <= 8'd0;
      active_buf     <= 1'b0;
      fill_buf       <= 1'b0;
      prefetch_busy  <= 1'b0;
      prefetch_valid <= 1'b0;
      prefetch_error <= 1'b0;
      irq_pend       <= 1'b0;
      dbg_cmd_cnt    <= 8'd0;
      dbg_last_cmd   <= 8'd0;
      dbg_abort_cnt  <= 8'd0;
      mounted_seen   <= mounted;
      // sector_buf is intentionally not reset: it is a RAM, and every path
      // that reads it runs only after a block transfer has filled it.
    end else begin
      block_read <= 1'b0;
      block_write <= 1'b0;

      // A status read acknowledges a *pending* device IRQ. It is applied here,
      // before every completion edge in this block, because the last assignment
      // wins: a polled 0x64E read that lands in the same cycle as a block
      // completion must not swallow the new request before the PIC's edge
      // detector sees it. Polled status reads are the norm on this machine: the
      // authentic IDE ROM polls 0x64E in a tight loop. Alternate status (0x74C)
      // must NOT acknowledge.
      // The acknowledge is inside the bank window: NP2kai's ideio_i64e calls
      // pic_resetirq only inside its `if (drv)` arm and returns 0xff otherwise
      // (cbus/ideio.c:1421-1442), so a poll at a bank with no interface behind it must
      // leave the request pending - otherwise the ROM's ISR, which brackets its reads
      // with a bank select, can lose an interrupt it has not been served for yet.
      // ... and only with nIEN clear: NP2kai ideio_i64e resets the request under
      // `if (!(drv->ctrl & IDECTRL_NIEN))`, so a polled status read leaves it pending.
      if (io_rd && io_addr == 16'h064E && bank_has_interface && !irq_disable) irq_pend <= 1'b0;
      // A read of ERROR does NOT clear STATUS.ERR. The machine keeps it: its DEVICE RESET
      // reads "after 0x08 status = 51 ; after 0x08 ERROR(0642) = 04" and the next status read
      // (after only a 0x064C write) is still 51 ("pre/final status = 51 58",
      // docs/probes/IDE.TXT:343,349; ideprobe.s sec_diag/sec_irq). That capture outranks
      // NP2kai ideio_i642's `drv->status &= ~IDESTAT_ERR;`, and qemu does not clear it either.
      // pc9821_atapi keeps ERR across the read for the same reason. tb_pc9821_ata_err_sticky.

      // The guest may probe the drive before the host has mounted an image (the
      // image arrives asynchronously over hps_io, and a probe that fails is not
      // retried). status_reg is otherwise only updated by task-file writes, so
      // without this a drive that appears after the first probe would report
      // not-ready forever. Latch READY (or not-present) whenever the mounted
      // state changes, as long as no transfer is in flight.
      mounted_seen <= mounted;
      if (mounted != mounted_seen && xfer_state == X_IDLE) begin
        status_reg <= mounted ? ATA_READY : 8'd0;
        // A drive that has run its power-on diagnostic reports ERROR = 0x01
        // (AMNF), and that byte *is* the PC-98 disk BIOS's presence test: after
        // SRST it accepts the unit only if 0x0642 reads 0x01 (BANK3@0xF9170-
        // 0xF9176, and the same test in the pre-SRST probe at
        // BANK3@0xF8D76-0xF8D7D). Clearing it on a mount made an image inserted
        // after cpu_run permanently undetectable.
        error_reg  <= mounted ? 8'h01 : 8'd0;
      end

      // The geometry divider runs FREE: pass 0 (the adopted stride, words 54/57/58) then pass 1
      // (1008, word 1), 32 clocks each, forever. It reads `capacity` and `idp_stride` live, so a
      // change in either is folded in by the next lap (at most 64 clocks, a few hundred ns); a lap
      // that straddles a change publishes one mixed result that the next lap replaces. A
      // change-detect (a 32-bit and a 16-bit copy of the inputs, their comparators and a
      // separate dividend copy) would buy no more, for ~100 ALMs.
      div_sq        <= {div_sq[30:0], div_ge};
      div_remainder <= div_remainder_next;
      if (div_count == 5'd31) begin
        div_pass      <= ~div_pass;
        div_sq        <= capacity;
        div_remainder <= 13'd0;
        if (div_pass)
          default_cylinders <= (|div_quotient_next[31:16]) ? 16'hFFFF : div_quotient_next[15:0];
        else begin
          current_cylinders <= (|div_quotient_next[31:16]) ? 16'hFFFF : div_quotient_next[15:0];
          current_capacity  <= capacity - {19'd0, div_remainder_next};
        end
      end
      div_count <= div_count + 5'd1;

      // The buffer write port is driven by the mux above the always block, so
      // reads and writes share one MLAB port pair rather than needing two.

      // Drain: a soft reset abandoned the transfer but the adapter is still
      // serving it, and its completion must be consumed before a new request can
      // be issued - pc9821_block_io turns the level handshake into one request /
      // one completion pulse, so a pulse arriving while it is busy is neither
      // latched nor queued. Leaving X_IDLE here would let the next command issue a
      // request the adapter never sees.
      if (xfer_state == X_DRAIN && block_done) begin
        xfer_state <= X_IDLE;
        status_reg <= device_present ? ATA_READY : 8'd0;
        // The drain's block_done is the abandoned read-ahead's, if one was in
        // flight; both buffers are discarded.
        prefetch_busy  <= 1'b0;
        prefetch_valid <= 1'b0;
        prefetch_error <= 1'b0;
      end

      // Read-ahead completion: sector N+1's data lands in fill_buf while the
      // guest drains sector N. Latch it; the drain's last word presents it.
      // SINGLE CONSUMER (H7): when the guest's last-word read takes the arriving
      // sector in the same clk (`last_word_take`), the last-word handler below
      // is this completion's owner and this latch STANDS DOWN - one block_done,
      // one consumer. The old comment told this handler to "precede" the
      // last-word handler so its NBA would lose the override; that was two
      // consumers resolved by source position (R2).
      if (prefetch_retire && !last_word_take) begin
        prefetch_busy  <= 1'b0;
        prefetch_valid <= 1'b1;
        prefetch_error <= block_error;
      end

      if (xfer_state == X_WAIT_BLOCK && block_done) begin
        if (block_error) abort_command(4'd1);
        else begin
          // The completed fetch is in fill_buf: hand that buffer to the guest,
          // and prefetch the sector after it into the freed buffer.
          active_buf <= fill_buf;
          fill_buf   <= ~fill_buf;
          status_reg <= ATA_READY | ATA_ST_DRQ;
          xfer_state <= X_PIO_READ;
          pio_byte   <= 9'd0;
          // NP2kai's readsec raises the interrupt only while its in-block counter
          // is zero, and never LOWERS it -- so a non-boundary sector leaves the
          // line as it was and the level stays until the guest's 0x064E read.
          if (block_pos == 8'd0) irq_pend <= irq_pend || !irq_disable;
          block_pos  <= block_step(block_pos, block_size);
          prefetch_busy  <= 1'b0;
          prefetch_valid <= 1'b0;
          // No follow-up request when a same-cycle command dispatch supersedes
          // this transfer (H8): the takeover's own request owns the adapter.
          if (sectors_left > 9'd1 && !command_takeover) begin
            lba_plus1     <= 1'b1;   // block_lba = current_lba + 1
            block_read    <= 1'b1;
            prefetch_busy <= 1'b1;
          end
        end
      end

      // Guest write of one 16-bit data word: assemble it from the byte pair at
      // 0640 (low) and 0641 (high), exactly mirroring the read order, and commit
      // it to the sector buffer on the high byte. The buffer store itself is the
      // muxed write port above. Both halves are task-file accesses and follow the
      // bank window (see buf_wr_en): at a floating bank the pair reaches nothing.
      if (io_wr && io_addr == 16'h0640 && bank_has_interface) pio_lo <= io_din;

      if (io_wr && io_addr == 16'h0641 && status_reg[3] && bank_has_interface &&
          xfer_state == X_PIO_WRITE) begin
        if (pio_byte == 9'd510) begin
          // Sector complete: hand the buffer to the block adapter. DRQ drops
          // while the write is in flight, so the guest waits on BSY.
          pio_byte    <= 9'd0;
          lba_plus1   <= 1'b0;   // block_lba = current_lba
          block_write <= 1'b1;
          block_dir_write <= 1'b1;
          status_reg  <= ATA_ST_BSY;
          xfer_state  <= X_WAIT_WRITE;
          // A pending level is left alone here (see begin_block_write): NP2kai
          // never lowers irq outside the 0x064E ack, and dropping it at the
          // commit retracts a request the guest has not serviced - the exact
          // loss the last-word handler below refuses to inflict.
        end else pio_byte <= pio_byte + 9'd2;
      end

      // Block write finished: either ask the guest for the next sector or
      // complete the command.
      if (xfer_state == X_WAIT_WRITE && block_done) begin
        if (block_error) abort_command(4'd1);
        else if (sectors_left <= 9'd1) begin
          status_reg   <= ATA_READY;
          xfer_state   <= X_IDLE;
          sector_count <= 8'd0;
          // NP2kai's final sector always interrupts, even when it is a partial
          // block (`ideio_w16`: `if (sc) writesec() else setintr()`).
          irq_pend      <= irq_pend || !irq_disable;
          advance_taskfile(current_lba + 28'd1);
        end else begin
          sector_count <= sector_count - 8'd1;
          current_lba  <= current_lba + 28'd1;
          sectors_left <= sectors_left - 9'd1;
          status_reg   <= ATA_READY | ATA_ST_DRQ;
          xfer_state   <= X_PIO_WRITE;
          pio_byte     <= 9'd0;
          block_pos    <= write_pos_next;
          // WRITE MULTIPLE raises one interrupt per BLOCK; WRITE SECTORS wraps
          // every sector, so this is unchanged for 0x30.
          if (write_pos_next == 8'd0) irq_pend <= irq_pend || !irq_disable;
          advance_taskfile(current_lba + 28'd1);
        end
      end

      // The byte serializer presents a 16-bit IN from 0640 as low byte at
      // 0640 then high byte at 0641. Advance only after the high byte, and only in a READ
      // phase: DRQ is set on the WRITE path too (the WRITE SECTORS arm sets READY|DRQ), so
      // gating this on DRQ alone let a stray 0641 read during a PIO write advance the byte
      // index by a whole word - and at 510 hand the sector over two words early - where the
      // write mirror below requires X_PIO_WRITE for exactly the same reason. The bank
      // window is the third term, for the same reason again: NP2kai's ideio_r16 returns
      // 0xff WITHOUT advancing bufpos when getidedrv() is NULL (cbus/ideio.c:1584-1595),
      // so a stray 16-bit `in` at a floating bank must not step the pointer and leave the
      // next honest word answering half of the previous one.
      if (io_rd && io_addr == 16'h0641 && status_reg[3] && bank_has_interface &&
          ((xfer_state == X_PIO_READ) || (xfer_state == X_PIO_IDENT))) begin
        if (pio_byte == 9'd510) begin
          pio_byte <= 9'd0;
          if (xfer_state == X_PIO_IDENT || sectors_left <= 9'd1) begin
            status_reg <= ATA_READY;
            xfer_state <= X_IDLE;
            sector_count <= 8'd0;
            // NP2kai does NOT lower the data-phase interrupt here: readsec's setintr
            // stays pending until a 0x064E read calls pic_resetirq (ideio_i64e).
            // Forcing irq low at the last word dropped a request the guest had not acked.
            if (xfer_state == X_PIO_READ) advance_taskfile(current_lba + 28'd1);
          end else if (prefetch_valid || last_word_take) begin
            // The next sector is already in fill_buf, so present it without a
            // serialized HPS round trip here: one IRQ, as for
            // every other sector, and DRQ with this sector's data behind it.
            // `last_word_take` names this handler as the owner of a completion
            // arriving in this same clk (H7): the folded check reads its error
            // straight from `block_error`, and the record below is written ONCE
            // per retired completion (`prefetch_error == block_error`).
            if (prefetch_error || (last_word_take && block_error))
              abort_command(4'd1);
            else begin
              active_buf     <= fill_buf;
              fill_buf       <= ~fill_buf;
              prefetch_valid <= 1'b0;
              prefetch_busy  <= 1'b0;
              prefetch_error <= block_error;
              sector_count   <= sector_count - 8'd1;
              current_lba    <= current_lba + 28'd1;
              sectors_left   <= sectors_left - 9'd1;
              status_reg     <= ATA_READY | ATA_ST_DRQ;
              if (block_pos == 8'd0) irq_pend <= irq_pend || !irq_disable;
              block_pos      <= block_step(block_pos, block_size);
              advance_taskfile(current_lba + 28'd1);
              if (sectors_left > 9'd2) begin
                lba_plus1     <= 1'b1;   // block_lba = (current_lba + 1) + 1
                block_read    <= 1'b1;
                prefetch_busy <= 1'b1;
              end
            end
          end else begin
            // The read-ahead is still in flight: wait for it, as a serial
            // path waits after issuing the request. The pending level is left
            // alone for the same reason as the final-word handler above: the
            // level stays until the guest's 0x064E read, and dropping it here
            // makes a deferred ISR's 0x0433 source check read 0x00 - no ack, and
            // for READ MULTIPLE no next raise until a block boundary the guest
            // can no longer reach.
            sector_count <= sector_count - 8'd1;
            current_lba  <= current_lba + 28'd1;
            sectors_left <= sectors_left - 9'd1;
            status_reg   <= ATA_ST_BSY;
            xfer_state   <= X_WAIT_BLOCK;
            advance_taskfile(current_lba + 28'd1);
          end
        end else pio_byte <= pio_byte + 9'd2;
      end

      if (io_wr) begin
        // The task file is connected only at the bank the interface is on: a
        // write at a floating bank reaches nothing, which is the write half of
        // the measured float. 0x0430/0x0432/0x0433 are the interface's own
        // registers rather than the task file and stay live at every bank --
        // 0x0432 is the window itself and must latch what the guest writes.
        if (!bank_has_interface &&
            !(io_addr == 16'h0430 || io_addr == 16'h0432 ||
              io_addr == 16'h0433)) begin
          ;
        end else case (io_addr)
          16'h0430: ;  // connection report latch is read-only in this model
          16'h0432: begin
            // A write with bit 7 SET IS A NO-OP (NP2kai `ideio_o430`:
            // `if (!(dat & 0x80))`; QEMU `pc98_ide_chsel_write`). The machine's ROM
            // depends on it: its `out 0x432,0x80` sites are save/restore brackets,
            // so under a latching model the value saved and restored is 0x80 and
            // the interface stays DISCONNECTED for the whole data phase. The ROM's
            // bank writes are `(slot & 0x0E) >> 1`, always bit-7 clear, so this
            // guard drops none of them.
            if (!io_din[7]) begin
              channel_reg <= io_din;
              // Selecting a bank does NOT touch the drive status. BANK3's ISR
              // writes this port, reads 0x0642 and 0x064E into the
              // {ERROR,STATUS} pair it latches, and its callers classify from
              // that snapshot (BANK3 file offsets 0x1A1C-0x1A27 read it,
              // 0x906F-0x907C and 0x0A53 classify from it); rewriting status_reg
              // here erased it. QEMU's pc98-ide does not touch IDE status on a
              // bank write either.
            end
          end
          // 0x433 is read-only on real hardware: QEMU states the Xa7 BIOS writes 0x01
              // here after reading status and that accepting it as a no-op matches the
              // observed sequence, and NP2kai's write handler is empty. Clearing the
              // request here could drop an interrupt the guest has not serviced yet.
              16'h0433: ;
          16'h0642: ;  // write precomp, retained nowhere
          16'h0644: sector_count <= io_din;
          16'h0646: sector_number <= io_din;
          16'h0648: cylinder_low <= io_din;
          16'h064A: cylinder_high <= io_din;
          16'h064C: begin
            drive_head <= io_din;
            // A device/head write leaves STATUS alone: the machine reads 0x51 after
            // `out 0x064C,0xA0` following an aborted command (docs/probes/IDE.TXT:349
            // "pre/final status = 51 58"), and NP2kai ideio_o64c only latches dr/hd. The
            // rewrite that stood here dates from two disks per bank (each select showed its
            // own disk's state); with one disk the mount-change latch below keeps STATUS
            // in step with `mounted`. tb_pc9821_ata_err_sticky.
          end
          16'h064E: begin
            // Count every command write, accepted or not: the watchdog's
            // cmd/abort counters together say which of the two it was.
            dbg_cmd_cnt  <= dbg_cmd_cnt + 8'd1;
            dbg_last_cmd <= io_din;
            // Real hardware ignores a command write while BSY. Without this a
            // guest that does not poll would re-dispatch the FSM mid-transfer:
            // the in-flight block request's completion never matches its state,
            // so sector_count and DRQ are left inconsistent and the sector
            // buffer holds half a sector of the wrong LBA. The BSY/state test
            // reads PRE-update values, so a write colliding with the very
            // completion that clears BSY is judged against a STALE transfer
            // state (pulses.md H8) and its command byte vanished. When the
            // completion is retired in this same clk (`block_done_retire_now`)
            // the dispatch takes over against the post-retire device, exactly
            // as if the completion had been observed one cycle earlier.
            if ((status_reg[7] || xfer_state != X_IDLE) && !block_done_retire_now) begin
              ;
            end else if (!device_present) begin
              status_reg <= 8'd0;
              irq_pend <= 1'b0;
            end else if (slave_ignores(io_din)) begin
              ;  // addressed to the absent device 1: no state change, no DRQ, no IRQ
            end else begin
              // A TAKEOVER RETIRES THE OLD TRANSFER, WHATEVER THE NEW COMMAND IS. The
              // completion arms above move a retiring X_WAIT_BLOCK/X_WAIT_WRITE into its
              // next DRQ phase (or leave X_PIO_READ standing); a command that runs no
              // transfer of its own (RECALIBRATE, SET FEATURES, ...) writes only its
              // status, so that DRQ state stood under a non-DRQ 0x50 and every later
              // command was ignored until SRST. This is the takeover's own default: the
              // case below overrides it for every command that starts a transfer.
              // NP2kai ideio_o64e dispatches a command against the drive whatever it was
              // doing (cbus/ideio.c). tb_pc9821_ata_takeover_idle.
              if (block_done_retire_now) xfer_state <= X_IDLE;
              case (io_din)
                8'h20, 8'h21: begin  // READ SECTORS (with/without retry)
                  // 0x21 is the without-retry twin of 0x20 and transfers exactly the
                  // same data: NP2kai `case 0x20: case 0x21:` share one readsec
                  // (cbus/ideio.c:902-912). The machine's own IDE option ROM reaches
                  // both: its command byte is `(flags & 0xF7) | table[class]`
                  // (BANK3 file 0x1085-0x10A9), and flags bit 0 is set from the INT
                  // 1Bh caller's fn bit 5 (BANK3 file 0x03B0-0x03B8 `test
                  // [bp+0x1],0x20`), so a without-retry read arrives as 0x21.
                  // Aborting it (a default arm) routes the ROM into its error
                  // recovery - SRST, RECALIBRATE and the 0x01F3 settle of
                  // 121*(0x28-[es:0x2060]) ARTIC units, up to 4.03 s of emulated time
                  // per trigger (tb_pc9821_ata_th5load fail-firsts this). Retry is a
                  // drive-internal policy the model has none of, so the pair is one
                  // command here exactly as in the reference.
                  if ((!drive_head[6] && !chs_valid) ||
                      !range_ok)
                    abort_command(4'd2);
                  else
                    begin_block_read(requested_lba, data_count, 8'd1);
                end
                8'h91: begin  // INITIALIZE DEVICE PARAMETERS
                  // Adopt what the host asks for, as both references do: NP2kai
                  // stores surfaces/sectors from the command and QEMU runs
                  // cmd_init_drive_params, whose purpose is to narrow the power-on
                  // geometry to what the platform uses. The head nibble is the
                  // highest head NUMBER, i.e. heads - 1.
                  if (sector_count == 8'd0)
                    abort_command(4'd3);
                  else begin
                    idp_head_max <= drive_head[3:0];
                    idp_sectors  <= sector_count;
                    error_reg <= 8'd0;
                    status_reg <= ATA_READY;
                    irq_pend <= irq_pend || !irq_disable;
                  end
                end
                8'hC4: begin  // READ MULTIPLE
                  // Same transfer as READ SECTORS; only the interrupt cadence
                  // differs (one per block). See `set_multiple` above.
                  if ((!drive_head[6] && !chs_valid) ||
                      !range_ok)
                    abort_command(4'd2);
                  else
                    begin_block_read(requested_lba, data_count, set_multiple);
                end
                8'hC6: begin  // SET MULTIPLE MODE
                  // NP2kai accepts exactly 2, 4, 8, 16, 32, 64 and 128 and aborts
                  // anything else. Storing the negotiated block length is what the
                  // IDENTIFY words 47 and 59 already promise.
                  if (sector_count == 8'd2 || sector_count == 8'd4 ||
                      sector_count == 8'd8 || sector_count == 8'd16 ||
                      sector_count == 8'd32 || sector_count == 8'd64 ||
                      sector_count == 8'd128) begin
                    set_multiple <= sector_count;
                    error_reg    <= 8'd0;
                    status_reg   <= ATA_READY;
                    irq_pend      <= irq_pend || !irq_disable;
                  end else abort_command(4'd5);
                end
                8'hEC: begin  // IDENTIFY DEVICE
                  error_reg <= 8'd0;
                  status_reg <= ATA_READY | ATA_ST_DRQ;
                  xfer_state <= X_PIO_IDENT;
                  pio_byte <= 9'd0;
                  sectors_left <= 9'd1;
                  irq_pend <= irq_pend || !irq_disable;
                end
                // Power and idle commands. The PC-98 IDE BIOS polls the status register
                // for *exactly* READY|DSC (0x50) after IDLE IMMEDIATE; aborting here (0x51
                // with ERR set) made it spin until it timed out, leaving the drive class
                // and geometry unset. NP2kai and QEMU both complete these successfully.
                8'hE0, 8'hE1: begin
                  // STANDBY IMMEDIATE / IDLE IMMEDIATE
                  error_reg  <= 8'd0;
                  status_reg <= ATA_READY;
                  irq_pend    <= irq_pend || !irq_disable;
                end
                8'hF8: begin  // READ NATIVE MAX ADDRESS
                  // NP2kai ideio.c:1162-1173 loads the capacity-derived address into the task
                  // file before interrupting (sn = totals & 0xff, cy = (totals >> 8) & 0xffff,
                  // hd low nibble = (totals >> 24) & 0xf), leaving the high drive/head bits.
                  // finding 4: this once shared the power arm, so a caller read its
                  // OLD address back instead of the drive's native maximum.
                  sector_number <= capacity[7:0];
                  cylinder_low  <= capacity[15:8];
                  cylinder_high <= capacity[23:16];
                  drive_head    <= {drive_head[7:4], capacity[27:24]};
                  error_reg  <= 8'd0;
                  status_reg <= ATA_READY;
                  irq_pend    <= irq_pend || !irq_disable;
                end
                8'h00: ;  // NOP: NP2kai's `case 0x00:` is an empty break (cbus/ideio.c),
                          // so it changes neither status nor error and raises no interrupt.
                8'h40, 8'h41: begin  // READ VERIFY (with/without retry)
                  // NP2kai clears BSY and raises the interrupt with no error; qemu routes
                  // it to cmd_verify. Aborting made a driver that verifies before a read
                  // see an error neither reference produces.
                  status_reg <= ATA_READY;
                  irq_pend    <= irq_pend || !irq_disable;
                end
                8'hE5: begin  // CHECK POWER MODE: active, reported in the count
                  sector_count <= 8'hFF;
                  error_reg    <= 8'd0;
                  status_reg   <= ATA_READY;
                  irq_pend      <= irq_pend || !irq_disable;
                end
                8'h08: begin  // DEVICE RESET: re-establish the signature
                  // A DEVICE RESET is an ABORT, and this model answers it the way the
                  // machine does: the probe's own DIAG section polls 0x064E for !BSY and
                  // then reads 0x0642 -- "after 0x08 status = 51 ; after 0x08
                  // ERROR(0642) = 04" (docs/probes/IDE.TXT:343,
                  // tools/hwprobe/ideprobe/ideprobe.s:826 (`/* DEVICE RESET */`)). The ATA definition agrees
                  // (ABRT = 0x04, with STATUS.ERR set on an abort), so the machine and the
                  // spec outrank 0x01 (AMNF): that is another drive's post-diagnostic
                  // presence signature, and a guest classifying the reset by STATUS.ERR (the
                  // ATA contract) would read a failed reset as success.
                  // ERROR 0x01 remains the *SRST* (0x74C bit 2) and EXECUTE DEVICE
                  // DIAGNOSTIC signature, which is what the PC-98 disk BIOS's presence test
                  // after SRST reads (see the 0x74C handler).
                  error_reg     <= ATA_ERR_ABRT;
                  sector_count  <= 8'd1;
                  sector_number <= 8'd1;
                  cylinder_low  <= 8'd0;
                  cylinder_high <= 8'd0;
                  status_reg    <= (device_present ? ATA_READY : 8'd0) | ATA_ST_ERR;
                  xfer_state    <= X_IDLE;
                  irq_pend       <= irq_pend || !irq_disable;
                end
                8'h90: begin  // EXECUTE DEVICE DIAGNOSTIC: pass, signature
                  error_reg     <= 8'h01;
                  sector_count  <= 8'd1;
                  sector_number <= 8'd1;
                  cylinder_low  <= 8'd0;
                  cylinder_high <= 8'd0;
                  status_reg    <= ATA_READY;
                  irq_pend       <= irq_pend || !irq_disable;
                end
                8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17,
                8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F: begin
                  // RECALIBRATE: seek to cylinder 0 and clear any error.
                  cylinder_low  <= 8'd0;
                  cylinder_high <= 8'd0;
                  error_reg     <= 8'd0;
                  status_reg    <= ATA_READY;
                  irq_pend       <= irq_pend || !irq_disable;
                end
                8'hEF: begin  // SET FEATURES
                  // Accept every subcommand: the machine's ROM issues 0xEF as an
                  // immediate and we cannot tell which. Nothing in this model
                  // depends on the setting, so success is honest about the effect
                  // (none) and non-blocking.
                  error_reg  <= 8'd0;
                  status_reg <= ATA_READY;
                  irq_pend    <= irq_pend || !irq_disable;
                end
                8'hE7: begin  // FLUSH CACHE: no write cache in this model
                  error_reg <= 8'd0;
                  status_reg <= ATA_READY;
                  irq_pend <= irq_pend || !irq_disable;
                end
                8'h30, 8'h31: begin  // WRITE SECTORS (with/without retry)
                  // 0x31 is 0x30's without-retry twin: NP2kai `case 0x30: case 0x31:`
                  // share one writeinit (cbus/ideio.c:914-923), and the ROM's command
                  // byte computation (see 0x21 above) reaches it the same way.
                  // Rejected when the image is read-only or mounted read-only, so
                  // the guest sees a clean abort rather than a half-completed
                  // block. The same geometry and range checks as the read path.
                  if (readonly || (!drive_head[6] && !chs_valid) ||
                      !range_ok)
                    abort_command(4'd7);
                  else
                    begin_block_write(requested_lba, data_count, 8'd1);
                end
                8'hC5: begin  // WRITE MULTIPLE
                  // The write sibling of READ MULTIPLE: same transfer and range
                  // checks as WRITE SECTORS, with the negotiated block length and
                  // one interrupt per block (NP2kai `0xc5` -> `writeinit`).
                  if (readonly || (!drive_head[6] && !chs_valid) ||
                      !range_ok)
                    abort_command(4'd7);
                  else
                    begin_block_write(requested_lba, data_count, set_multiple);
                end
                default: abort_command(4'd8);
              endcase
            end
          end
          16'h074C: begin
            irq_disable <= io_din[1];
            soft_reset  <= io_din[2];
            if (io_din[2]) begin
              // SRST asserted: NP2kai ideio_o74c clears status and error for both
              // drives on the set edge (cbus/ideio.c); qemu ide_ctrl_write resets the
              // bus. It does NOT set BSY. BSY is held only while a block transfer the
              // soft reset abandoned is still being drained by the adapter.
              error_reg <= 8'd0;
              if (block_in_flight && !block_done_retired) begin
                status_reg <= ATA_ST_BSY;
                xfer_state <= X_DRAIN;
              end else begin
                status_reg <= 8'd0;
                xfer_state <= X_IDLE;
              end
              irq_pend <= 1'b0;
            end else if (soft_reset) begin
              // Re-establish the post-diagnostic signature: ERROR=0x01 with the
              // task file back to CHS 0/0/1, as NP2kai's drvreset() does.
              error_reg     <= 8'h01;
              sector_count  <= 8'd1;
              sector_number <= 8'd1;
              cylinder_low  <= 8'd0;
              cylinder_high <= 8'd0;
              // NP2kai's drvreset reloads hd = 0 but leaves the high nibble alone, so
              // 0x64C reads back the drive-select the guest wrote with head 0.
              drive_head[3:0] <= 4'd0;
              pio_byte <= 9'd0;
              irq_pend <= 1'b0;
              // The signature is published only once the adapter is free, so a
              // guest polling for READY is not told the drive is ready to accept
              // a command it cannot yet serve.
              if (block_in_flight && !block_done_retired) begin
                status_reg <= ATA_ST_BSY;
                xfer_state <= X_DRAIN;
              end else begin
                status_reg <= device_present ? ATA_READY : 8'd0;
                xfer_state <= X_IDLE;
              end
            end
          end
          16'h074E: ;
          default:  ;
        endcase
      end
    end
  end

  // Detection snapshot for the stall watchdog (declared here so it follows the
  // register declarations; iverilog rejects the reference before them).
  assign dbg_state = {device_present, mounted, channel_reg[0],
                      xfer_state, status_reg[7], status_reg[3]};

endmodule
`default_nettype wire
