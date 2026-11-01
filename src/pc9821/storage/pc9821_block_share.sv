// ONE HPS block adapter shared by the hard disk and the TWO FLOPPY DRIVES (docs/trade-candidates.md
// T9, extended by the second drive).
//
// WHY THIS MODULE EXISTS. pc9821_block_io is the engine that turns hps_io's block handshake
// into one request / one completion for a drive, with a read-ahead window behind it
// (pc9821_block_io.sv's own header). Two instances of it - one at the system level for
// pc9821_ata and one inside pc9821_fdd_media - would serve two devices that reach the SAME
// hps_io channel:
//
//   * hps_io presents one slot's request at a time. Its status word carries a single selected
//     slot (`sdn`, sys/hps_io.sv:204 (reg [3:0] sdn;) with one `sd_blk_cnt`/`sd_rd`/`sd_wr`
//     per status read, and the ARM answers with `sd_ack` for that one slot,
//     sys/hps_io.sv:331 "sd_ack <= disk[VD:0]; sdn_ack <= io_din[11:8];".
//   * the payload is ONE bus for both slots: `sd_buff_addr` / `sd_buff_wr` / `sd_buff_dout`
//     (z486_mister.sv:874 (wire [12:0] sd_buff_addr;) and its neighbours, NOT a per-slot
//     array), so two engines could not both ingest a word stream even if both were
//     acknowledged.
//
// So the second engine's FETCH/WINDOW/SERVE state was never needed twice: the two devices have
// always been serialized at the medium, and the only thing the second instance bought was a
// second independently-latched request. This module keeps that - a one-deep request queue per
// device - around a single engine, and hands the engine to one device at a time.
//
// THREE IMAGE SLOTS, TWO DEVICES, AND THE DRIVE TAG THAT JOINS THEM. The machine has two
// floppy drives and each has its own image slot (hps_io slot 1 = FDD0, slot 2 = FDD1), so the
// engine can be asked for three different media: the disk's (slot A), the first floppy's
// (slot B) or the second's (slot C). They reach it over TWO device ports, not three, because
// the floppy's two drives are ONE device here: pc9821_fdd_media has one byte stream and one
// fetch in flight (the FDC serves one unit at a time), so its requests all arrive on the B
// port - and `b_req_slot` says which of the two floppy images that request belongs to. The
// engine therefore has to be loaded with the RIGHT one of the three, which is why the slot is
// part of the ownership record below and part of the same-owner test. A window that held one
// medium's blocks while another medium's request was answered out of it would serve the second
// drive's first sector out of the first drive's cached blocks - no byte of that is correct. The
// engine's window is the DISK's and carries its owner's tag (pc9821_block_io.sv's header), so
// the floppy's requests never use it at all and a block of one drive's image cannot be answered
// out of another's - not even between the two floppy drives, which share one device port and
// one engine.
//
// WHAT THE REAL MACHINE DOES (the question this change has to answer before it is a change).
// The machine does NOT serialize the two devices: its FDC owns DMA channel 2 and its own
// command timeline (NP2kai io/fdc.c:88 `dmac.dmach[FDC_DMACH2HD]`, :56-58 its own NEVENT_FDCINT
// event), while the IDE drive is PIO through the CPU with ITS own completion event
// (NP2kai cbus/ideio.c:306-321, `nevent_set(NEVENT_SASIIO, delay, ...)`), so a floppy transfer
// and a disk transfer can be in flight at once on hardware (qemu-pc98 agrees in shape: the IDE
// request is asynchronous, hw/ide/core.c:705 `blk_aio_preadv`, and the FDC's sector fetch is a
// synchronous `blk_pread` inside its own engine, hw/block/fdc.c:1647). Neither software
// reference models a shared MEDIUM adapter, so neither can be asked about arbitration - what
// they show is two independent engines, which is what the hardware is.
//
// What that costs here is bounded and is NOT new: this core has never had two transfers in
// flight (the channel above is one deep), and the arbitration below reproduces the alternation
// hps_io already performed (`sdn` is round-robin-started,
// sys/hps_io.sv:210 "for(i = VDNUM - 1; i >= 0; i = i - 1) begin"), at the same granularity -
// one handshake per device. The loser of a hand-over waits for the winner's in-flight handshake
// and is served next; a device that keeps streaming cannot starve the other, because ownership
// is released as soon as the engine is idle (burst tail included) and the next grant goes to
// the device that did NOT own last. That is latency, which is accepted as malleable for
// storage (docs/trade-candidates.md), not a value: no status bit, no
// completion order the guest can observe, and no byte changes.
//
// THE ENGINE'S IMAGE IS THE OWNER'S. pc9821_block_io latches ONE image (mounted / readonly /
// capacity, from its `img_mounted` / `img_size` inputs) and rejects a request against it, so
// this module latches each slot's image itself and loads the engine with the owner's at every
// hand-over. A mount of the owner's OWN slot is forwarded in place, so the engine's eject
// semantics (an unmount aborts the transfer it is serving, with an error) are exactly the
// ones its own instance had.
//
// THE ENGINE'S READ-AHEAD WINDOW IS THE DISK'S (T19). The load that a hand-over performs is a
// metadata load and NOT a window flush any more: the engine's window is tagged with the image
// it serves (`req_window` below), so a hand-over to the floppy loads the engine with the
// floppy's image and leaves the disk's read-ahead where it was, and the floppy is served the
// one block it asked for. That is the fix for the measured cost of sharing: with the load as
// the flush, a floppy access every four disk sectors cost the disk 24 host handshakes per 32
// sectors against 6 with no floppy at all, because the disk had to earn its run again after
// every one of them (tb_pc9821_block_hostcost's interleaved pattern). What still invalidates the window is a replacement
// of the IMAGE its blocks came from - a mount (or eject) of the disk's own slot A - which is
// `bio_win_flush`, and it is asserted whether or not the disk currently owns the engine, so a
// re-mounted image can never be answered out of the old one's blocks. A mount of a floppy slot
// does not touch the disk's window; the floppy's own image is protected by the tag instead, so
// no block of one medium can be answered out of the other's blocks.

`default_nettype none

module pc9821_block_share (
    input wire clk,
    input wire rst_n,

    // ---------------------------------------------------------------- image slot A: the hard disk
    input  wire        a_img_mounted,
    input  wire        a_img_readonly,
    input  wire [63:0] a_img_size,
    output reg         a_mounted,
    output wire        a_readonly,
    output reg  [31:0] a_capacity,

    // The disk's request contract, which is pc9821_ata's own: one-cycle `req_read` /
    // `req_write` PULSES (pc9821_ata.sv clears block_read/block_write at the top of its clocked
    // block, so a request lasts one clk_sys), one `req_done` pulse per request, `req_error`
    // beside it.
    input  wire        a_req_read,
    input  wire        a_req_write,
    input  wire [31:0] a_req_lba,
    // Whether the disk's request belongs to the ENGINE'S read-ahead window image. It is 1 for
    // every guest request; pc9821_hdd_image drives it 0 for its mount probe so reading the
    // header sector at LBA 0 neither fills the window nor moves the sequential-read run (a
    // raw image's first guest access then keeps the exact miss it had before HDI support).
    input  wire        a_req_window,
    output wire        a_req_done,
    output wire        a_req_error,
    // The disk's block path is busy: its request is queued or the engine is serving it. The
    // watchdog record's HP field publishes it (pc9821_watchdog_msg.sv), where it means the
    // same thing the disk instance's own `busy` did - a transfer outstanding - plus the wait
    // for the engine the two devices now share.
    output wire        a_busy,
    output wire        a_buf_we,
    output wire [ 7:0] a_buf_addr,
    output wire [15:0] a_buf_data,
    // pc9821_block_io drives the write direction's read address (it is `sd_buff_addr`'s low
    // byte) and samples the drive's sector buffer at it, so the address is this module's output
    // and the data its input.
    output wire [ 7:0] a_buf_rd_addr,
    input  wire [15:0] a_buf_rd_data,

    output wire [31:0] a_sd_lba,
    output wire [ 5:0] a_sd_blk_cnt,
    output wire        a_sd_rd,
    output wire        a_sd_wr,
    input  wire        a_sd_ack,
    output wire [15:0] a_sd_buff_din,

    // ---------------------------------------------------------------- image slot B: the floppy
    input  wire        b_img_mounted,
    input  wire        b_img_readonly,
    input  wire [63:0] b_img_size,

    // The floppy's contract is pc9821_fdd_media's: a LEVEL held until the adapter takes it or
    // completes it (`blk_req_rd` is released on blk_done OR on blk_busy, so `b_busy` here means
    // exactly "the request is in hand") and a 16-bit block index. `b_req_read` is that level for
    // EITHER direction; `b_req_write`, held with it, makes it a block WRITE-BACK (the medium's
    // `blk_req_wr`), whose payload the host reads out of the medium's buffer at `b_buf_rd_addr`.
    input  wire        b_req_read,
    input  wire        b_req_write,
    input  wire [15:0] b_req_lba,
    // WHICH FLOPPY IMAGE this request is for: 0 = slot B (the first drive, hps_io slot 1),
    // 1 = slot C (the second, hps_io slot 2). Held by the requester with the level above, and
    // latched here at the same moment as the index so a withdrawn level cannot change it.
    input  wire        b_req_slot,
    output wire        b_req_done,
    output wire        b_req_error,
    output wire        b_busy,
    output wire        b_buf_we,
    output wire [ 7:0] b_buf_addr,
    output wire [15:0] b_buf_data,
    // The write direction's read port into the medium's block buffer, exactly as the disk's
    // (a_buf_rd_*): the address is hps_io's sd_buff_addr low byte, the data a registered read.
    output wire [ 7:0] b_buf_rd_addr,
    input  wire [15:0] b_buf_rd_data,

    output wire [31:0] b_sd_lba,
    output wire [ 5:0] b_sd_blk_cnt,
    output wire        b_sd_rd,
    output wire        b_sd_wr,
    input  wire        b_sd_ack,
    output wire [15:0] b_sd_buff_din,

    // ---------------------------------------------------------------- image slot C: the second floppy drive
    // The same contract as slot B, one device port over: pc9821_fdd_media asks for this image
    // by setting b_req_slot, so there is no second device port and no second request queue.
    input  wire        c_img_mounted,
    input  wire        c_img_readonly,
    input  wire [63:0] c_img_size,

    output wire [31:0] c_sd_lba,
    output wire [ 5:0] c_sd_blk_cnt,
    output wire        c_sd_rd,
    output wire        c_sd_wr,
    input  wire        c_sd_ack,
    output wire [15:0] c_sd_buff_din,

    // ---------------------------------------------------------------- the one host channel
    // Shared by both slots, exactly as hps_io presents it: one bus for the whole core, not a
    // per-slot array -- z486_mister.sv:874 (wire [12:0] sd_buff_addr;) and the three wires
    // beside it.
    input  wire        sd_buff_wr,
    input  wire [12:0] sd_buff_addr,
    input  wire [15:0] sd_buff_dout,

    output wire [31:0] dbg_hps_cycles
);

  // ==== the image slots' metadata ====
  // The rules are pc9821_block_io's own, so the values this module hands the disk and the
  // engine are the ones each instance produced before: mounted is `img_size >= 512` and
  // capacity is `img_size[40:9]`, saturating when the size does not fit 41 bits. They are
  // latched HERE, once per slot, because the engine holds one image at a time while the disk
  // reads its own continuously (IDENTIFY, the range check, the presence probe) - an engine
  // output that followed the owner would flap those values under the guest whenever the floppy
  // was served.
  // Both floppy slots are latched from the SAME hps_io `img_readonly` wire (the framework has
  // one such register, valid for the mount that just happened), exactly as `img_size` feeds
  // both slots' sizes; what differs per slot is when the latch takes it.
  //
  // B/C CAPACITY IS SATURATED AT 2^16, WHICH IS ALL THE FLOPPY CAN ADDRESS. The engine's only
  // uses of a capacity are `mounted` (non-zero) and `req_reject = req_lba >= capacity`, and a
  // floppy request's LBA is 16 bits end to end (pc9821_block_io's block index, `b_req_lba` here,
  // and `b_pend_lba` - the value the grant latches - are all [15:0]). 65536 is the smallest
  // saturated value that ACCEPTS LBA 65535 exactly as the untruncated capacity did, so
  // min(capacity, 65536) preserves both tests for every reachable floppy request. Slot A is the
  // disk and keeps its guest-visible 32-bit capacity untouched.
  localparam [16:0] CAP_SAT = 17'h10000;
  // size[8:0] is the partial final block's byte count; only whether it is non-zero is read.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic [16:0] cap_sat(input [63:0] size);
    begin
      if (|size[63:41])        cap_sat = CAP_SAT;   // the engine's own saturating row
      else if (|size[40:25])   cap_sat = CAP_SAT;   // the value itself is above 65535
      // A PARTIAL FINAL BLOCK IS A BLOCK OF THE IMAGE. A D88's extent is its header's fd_size,
      // which is not a multiple of 512 (the 0x2B0-byte header alone guarantees that for most
      // images), so the medium's last sector can end inside a block the floor `size[24:9]` does
      // not count - and the engine rejected that block. While pc9821_fdd_media ignored the
      // verdict the read was served from the buffer's previous block instead (a stale 512-byte
      // copy), and tb_pc9821_fdd_two_units could not tell, because its data pattern repeats
      // every 256 bytes. The capacity is therefore the CEILING: the bytes past the image in that
      // block are never consumed, because the medium bounds every read by the image's own
      // extent (its `img_left`). A SUB-SECTOR size is still the eject it always was (capacity 0,
      // so the engine's `mounted` - capacity non-zero - is clear): that is pc9821_block_io's own
      // `img_size < 512` rule, and no floppy format is smaller than one block.
      else if (size[24:9] == 16'd0) cap_sat = 17'd0;
      else                     cap_sat = {1'b0, size[24:9]} + {16'd0, |size[8:0]};
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  reg        b_readonly;
  reg [16:0] b_capacity;
  reg        c_readonly;
  reg [16:0] c_capacity;

  // a_readonly's power-up 1 sits on an internal register: Quartus ignores a power-up value on
  // an output port (docs/policies.md, the power-up rule).
  /* verilator lint_off PROCASSINIT */  // the power-up value, kept by Quartus on an internal register
  reg a_readonly_r = 1'b1;
  /* verilator lint_on PROCASSINIT */
  assign a_readonly = a_readonly_r;
  initial begin
    a_mounted  = 1'b0;
    a_capacity = 32'd0;
    b_readonly = 1'b1;
    b_capacity = 17'd0;
    c_readonly = 1'b1;
    c_capacity = 17'd0;
  end

  // Each floppy slot's capacity as its latch will take it. The in-place forward below reads these
  // same two nets (md_size is b_img_size / c_img_size), so cap_sat is built twice, not three times.
  wire [16:0] b_cap_d = cap_sat(b_img_size);
  wire [16:0] c_cap_d = cap_sat(c_img_size);

  always @(posedge clk) begin
    if (a_img_mounted) begin
      a_mounted  <= (a_img_size >= 64'd512);
      a_readonly_r <= a_img_readonly;
      a_capacity <= (|a_img_size[63:41]) ? 32'hFFFFFFFF : a_img_size[40:9];
    end
    if (b_img_mounted) begin
      b_readonly <= b_img_readonly;
      b_capacity <= b_cap_d;
    end
    if (c_img_mounted) begin
      c_readonly <= c_img_readonly;
      c_capacity <= c_cap_d;
    end
  end

  // ==== the engine ====
  // THREE SLOTS, TWO DEVICES. `owner` says which DEVICE the engine serves (0 = the disk,
  // 1 = the floppy) and is what the alternation and the two devices' busy levels are about;
  // `owner_slot`/`eng_slot` say WHICH FLOPPY IMAGE is being served / is loaded (only
  // meaningful when the floppy owns the engine). The 2-bit `{owner, slot}` pair is the engine's
  // whole image context, so the same-owner test below has to compare both halves.
  localparam [1:0] ARB_IDLE = 2'd0,   // no transfer: arbitrate
                   ARB_META = 2'd1,   // an owner was chosen: load the engine with its image
                   ARB_REQ  = 2'd2,   // hand the latched request to the engine
                   ARB_HELD = 2'd3;   // serving: hold ownership until the engine is idle again

  reg [1:0]  arb;
  reg        owner;        // 1 = the floppy, 0 = the hard disk: the DEVICE the engine serves
  reg        owner_slot;   // which of the floppy's two images (valid when owner is 1)
  reg        last_owner;   // who owned last, so the next grant alternates
  reg        eng_owner;    // whose image the engine's metadata latch holds (device)
  reg        eng_slot;     // and which of the floppy's two images it holds
  reg        eng_loaded;   // the engine's metadata latch has been loaded at least once

  // The engine's image selection as one value, so "is the engine already holding what the next
  // grant needs" is a single comparison rather than two that can drift apart.
  wire [1:0] eng_sel   = {eng_owner, eng_slot};
  // ... and as the selection being SERVED, which is the registered one except in ARB_META,
  // where this cycle's winner drives the engine's load (see md_inplace below).
  wire [1:0] owner_sel = (arb == ARB_META) ? {owner, owner_slot} : eng_sel;
  // WHICH IMAGE THE GRANT IS FOR, as {device, floppy-slot}: the disk (2'd0) or the floppy drive
  // whose request is queued. This is the value loaded into the engine's metadata latch at
  // ARB_META and compared against `eng_sel` to decide whether a load is needed at all, so a
  // switch between the two floppy drives loads the right image into the engine exactly as a
  // switch between the disk and the floppy does.
  // {device, slot}: 00 = the hard disk (A), 10 = FDD0 (B), 11 = FDD1 (C).
  wire [1:0] grant_sel = grant_b_now ? {1'b1, b_pend_slot} : 2'd0;

  // One-deep request queues. A device's request is TAKEN here (never refused) and served in its
  // turn; a pulse that arrives while that device's own entry is still waiting is dropped, which
  // is pc9821_block_io's documented contract ("neither latched nor queued") and the one thing
  // neither device's FSM can produce - the disk waits in X_WAIT_BLOCK for its completion, the
  // floppy for `bready`.
  reg        a_pend;
  reg        a_pend_write;
  reg [31:0] a_pend_lba;
  reg        b_pend;
  reg        b_pend_write; // the queued B request is a block WRITE-BACK
  reg [15:0] b_pend_lba;
  reg        b_pend_slot;  // which floppy image the queued B request is for

  // THE FLOPPY WRITE FENCE. A floppy image can be swapped while the core runs (the OSD mounts
  // one in place of another), and hps_io names a request by SLOT, not by image: a
  // write-back of the OLD image's block that is still queued here, or granted but not yet
  // acknowledged by the host, when the slot's mount lands would be served by the ARM into the
  // NEW image - a block of one disk written into another. So a floppy WRITE whose slot sees a
  // mount between its take and its hand-over to the engine is KILLED: never handed over, and
  // answered with an error (the medium has already ended the request on the same mount edge;
  // the error only retires its outstanding fetch). Once the engine holds it, the engine's own
  // withdraw does the same until the host acknowledges (pc9821_block_io's `wr_withdraw`); after
  // the acknowledge the ARM is already serving it and a mount cannot interleave (one ARM thread),
  // so it lands in the image it was issued for. Reads need no fence: the medium marks a read
  // fetch that straddles its own mount edge stale and never uses its data.
  // R3 (set vs clear): `w_kill` is set by a mount of the write's slot while it is queued or
  // granted and cleared at ARB_REQ, where the same cycle's mount is ORed in combinationally, so
  // a mount coinciding with the clear is consumed by it rather than lost.
  reg        w_kill;
  reg        w_kill_done;   // the killed write's one completion, an error (one cycle)
  wire       b_mnt_take  = b_req_slot  ? c_img_mounted : b_img_mounted;
  wire       b_mnt_pend  = b_pend_slot ? c_img_mounted : b_img_mounted;

  // The granted request, latched at the moment of the grant. The grant is a COMMITMENT: a
  // requester may withdraw its level the cycle after (the floppy does - it releases
  // `blk_req_rd` as soon as `b_busy` says the request is in hand - and an ATA soft reset
  // abandons a transfer that is already in flight and then waits in X_DRAIN for its
  // completion), so the engine is fed from here and not from the device's level.
  reg [31:0] grant_lba;
  reg        grant_write;

  wire a_want = a_pend;
  wire b_want = b_pend;
  // Both devices asking: the one that did NOT own last goes first, so handshakes alternate
  // (hps_io's own round-robin start) and a device streaming a long transfer cannot
  // hold the engine against the other.
  wire grant_a_now = a_want && (!b_want || !last_owner);
  wire grant_b_now = b_want && (!a_want ||  last_owner);
  wire granting    = (arb == ARB_IDLE) && (a_want || b_want);
  wire grant_a     = granting && grant_a_now;
  wire grant_b     = granting && grant_b_now;

  // The engine's image, selected by the owner being served. `owner_sel` is {device, floppy-slot},
  // so this mux is the whole three-slot choice: slot A is the disk and slots B/C are the two
  // floppy drives.
  // A mount of the owner's own slot is forwarded in place: the RAW values are that image's, and
  // the latch above loads from exactly those same inputs on the same edge, so forwarding the raw
  // is what keeps the engine's load and the device-facing latch in agreement. That matters in
  // ARB_META most of all, because the cycle a mount pulse ENDS on is the only cycle in which
  // there is no later in-place forward to repair the load: taking the pre-edge latch there would
  // load the engine with the OLD image (a grown image's requests rejected at its new LBAs; an
  // eject invisible to it, so an ejected slot's READ SECTORS is served instead of failed) while
  // the share hands the device the NEW metadata. `bio_img_mounted` is asserted in ARB_META
  // regardless (below), so this only picks the load's source, never whether there is one.
  wire        md_mount    = owner_sel[1] ? (owner_sel[0] ? c_img_mounted  : b_img_mounted)
                                         : a_img_mounted;
  /* verilator lint_off UNUSEDSIGNAL */   // [8:0]: only the disk slot's floor rule reads the size; the floppy ceiling is b/c_cap_d
  wire [63:0] md_size     = owner_sel[1] ? (owner_sel[0] ? c_img_size     : b_img_size)
                                         : a_img_size;
  /* verilator lint_on UNUSEDSIGNAL */
  wire        md_readonly = owner_sel[1] ? (owner_sel[0] ? c_img_readonly : b_img_readonly)
                                         : a_img_readonly;
  wire [31:0] md_capacity = owner_sel[1] ? (owner_sel[0] ? {15'd0, c_capacity} : {15'd0, b_capacity})
                                         : a_capacity;
  wire        md_latch_ro = owner_sel[1] ? (owner_sel[0] ? c_readonly     : b_readonly)
                                         : a_readonly;
  wire        md_inplace  = md_mount;

  wire bio_img_mounted;
  wire [63:0] bio_img_size;
  wire bio_img_readonly;
  wire bio_req_read;
  wire bio_req_write;
  wire [31:0] bio_req_lba;
  wire bio_sd_ack;

  // IS THIS REQUEST THE WINDOW'S? The window holds one image's blocks and it is the DISK's
  // (pc9821_block_io's header): the disk's requests may hit and fill it, a floppy request is
  // served the single block it asks for and touches neither the window nor its run. `eng_owner`
  // is the owner the engine is actually loaded with, so this is 1 exactly when the disk is -
  // and the disk's own `a_req_window` can still withdraw a request that is not the window's
  // (pc9821_hdd_image's mount probe).
  wire bio_req_window = !eng_owner && a_req_window;
  // ... and the window is invalidated by a replacement of the image it holds - the disk's slot
  // - which is what `img_mounted` on slot A means, mount or eject. A floppy mount does not
  // invalidate it: the tag above is what keeps the two media apart there.

  wire bio_win_flush  = a_img_mounted;

  assign bio_img_mounted  = (arb == ARB_META) | md_inplace;
  // {23'd0, capacity, 9'd0} inverts pc9821_block_io's own rule exactly: bits [63:41] are zero
  // for every 32-bit capacity, so the engine recomputes `img_size[40:9]` = the capacity it is
  // being given, and `img_size >= 512` = "capacity is non-zero" = that slot's mounted state.
  // The in-place forward goes through the SAME capacity rule as the slot's latch (cap_sat's
  // ceiling for a floppy slot, the disk's own floor-and-saturate for a disk slot), so the engine
  // and the latch can never disagree about the partial final block of a floppy image.
  wire [31:0] md_cap_now  = owner_sel[1] ? {15'd0, (owner_sel[0] ? c_cap_d : b_cap_d)}
                                         : ((|md_size[63:41]) ? 32'hFFFFFFFF : md_size[40:9]);
  assign bio_img_size     = {23'd0, (md_inplace ? md_cap_now : md_capacity), 9'd0};
  assign bio_img_readonly = md_inplace ? md_readonly : md_latch_ro;

  // The request the engine is handed, and only in ARB_REQ: one cycle, as both devices' own
  // contracts already are. A floppy write the fence killed (above) is not handed over at all.
  wire b_mnt_grant = owner_slot ? c_img_mounted : b_img_mounted;
  wire kill_now    = (arb == ARB_REQ) && owner && grant_write && (w_kill || b_mnt_grant);
  assign bio_req_read  = (arb == ARB_REQ) && !grant_write;
  assign bio_req_write = (arb == ARB_REQ) &&  grant_write && !kill_now;
  assign bio_req_lba   = grant_lba;

  wire        bio_busy;
  wire        bio_req_done;
  wire        bio_req_error;
  wire        bio_buf_we;
  wire [ 7:0] bio_buf_addr;
  wire [15:0] bio_buf_data;
  wire [ 7:0] bio_buf_rd_addr;
  wire [31:0] bio_sd_lba;
  wire [ 5:0] bio_sd_blk_cnt;
  wire        bio_sd_rd;
  wire        bio_sd_wr;
  wire [15:0] bio_sd_buff_din;

  // SERIAL_REQ: ARB_HELD waits for !bio_busy and a request is sent only from ARB_REQ, so the
  // engine is idle at every request it gets (see the parameter's note in pc9821_block_io).
  pc9821_block_io #(.SERIAL_REQ(1)) engine (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(bio_img_mounted), .img_readonly(bio_img_readonly), .img_size(bio_img_size),
      /* verilator lint_off PINCONNECTEMPTY */   // the engine's metadata OUTPUTS are the
      // values the owner's slot is being given, and this module already holds that slot's own
      // (a_mounted/a_readonly/a_capacity) - the disk reads those continuously, so an output that
      // followed the owner would flap the disk's capacity whenever the floppy was served.
      .mounted(), .readonly(), .capacity(),
      /* verilator lint_on PINCONNECTEMPTY */
      .req_read(bio_req_read), .req_write(bio_req_write), .req_lba(bio_req_lba),
      .req_window(bio_req_window), .win_flush(bio_win_flush),
      .req_done(bio_req_done), .req_error(bio_req_error),
      .buf_we(bio_buf_we), .buf_addr(bio_buf_addr), .buf_data(bio_buf_data),
      // The write direction reads the OWNER's buffer: the disk's sector buffer or the floppy
      // medium's block buffer. Only the owner can have a transfer in flight, so this is a
      // select, not an arbiter (the fill port's gate below is the same reading).
      .buf_rd_addr(bio_buf_rd_addr), .buf_rd_data(eng_owner ? b_buf_rd_data : a_buf_rd_data),
      .sd_lba(bio_sd_lba), .sd_blk_cnt(bio_sd_blk_cnt), .sd_rd(bio_sd_rd), .sd_wr(bio_sd_wr),
      .sd_ack(bio_sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .sd_buff_din(bio_sd_buff_din),
      .busy(bio_busy), .dbg_hps_cycles(dbg_hps_cycles)
  );

  // ==== the host side ====
  // The slot the engine is wired to. During a transfer this is always the owner: ownership is
  // granted before a request is handed over and released only when the engine is idle, so a
  // fetch in flight and its `sd_ack` always belong to the same slot. A floppy request names its
  // own image through `eng_slot`, so exactly one of the three slots' request pins is ever driven.
  assign a_sd_lba     = !eng_owner ? bio_sd_lba     : 32'd0;
  assign a_sd_blk_cnt = !eng_owner ? bio_sd_blk_cnt : 6'd0;
  assign a_sd_rd      = !eng_owner ? bio_sd_rd      : 1'b0;
  assign a_sd_wr      = !eng_owner ? bio_sd_wr      : 1'b0;
  assign b_sd_lba     = (eng_owner && !eng_slot) ? bio_sd_lba     : 32'd0;
  assign b_sd_blk_cnt = (eng_owner && !eng_slot) ? bio_sd_blk_cnt : 6'd0;
  assign b_sd_rd      = (eng_owner && !eng_slot) ? bio_sd_rd      : 1'b0;
  assign b_sd_wr      = (eng_owner && !eng_slot) ? bio_sd_wr      : 1'b0;
  assign c_sd_lba     = (eng_owner &&  eng_slot) ? bio_sd_lba     : 32'd0;
  assign c_sd_blk_cnt = (eng_owner &&  eng_slot) ? bio_sd_blk_cnt : 6'd0;
  assign c_sd_rd      = (eng_owner &&  eng_slot) ? bio_sd_rd      : 1'b0;
  assign c_sd_wr      = (eng_owner &&  eng_slot) ? bio_sd_wr      : 1'b0;
  assign bio_sd_ack   = eng_owner ? (eng_slot ? c_sd_ack : b_sd_ack) : a_sd_ack;
  // The owner's buffer, which the host reads in the write direction (hps_io samples the
  // acknowledged slot's sd_buff_din, so every slot sees the engine's one value).
  assign a_sd_buff_din = bio_sd_buff_din;
  assign b_sd_buff_din = bio_sd_buff_din;
  assign c_sd_buff_din = bio_sd_buff_din;

  // The write direction's read address, to both devices' buffers: hps_io's sd_buff_addr.
  assign a_buf_rd_addr = bio_buf_rd_addr;
  assign b_buf_rd_addr = bio_buf_rd_addr;

  // ==== the device side ====
  // The fill port goes to the device the engine is serving. Only the owner can have a fetch in
  // flight, so this is a gate and not an arbiter - and it keeps a tail word out of the other
  // device's one-block buffer even if ownership changed with words still on the wire. The
  // floppy's two drives share this one port because they share one byte stream (and one
  // one-block buffer): the slot tag tells them WHICH IMAGE the words belong to, not which
  // buffer they land in.
  assign a_buf_we   = bio_buf_we && !eng_owner;
  assign b_buf_we   = bio_buf_we &&  eng_owner;
  assign a_buf_addr = bio_buf_addr;
  assign a_buf_data = bio_buf_data;
  assign b_buf_addr = bio_buf_addr;
  assign b_buf_data = bio_buf_data;

  // One completion per request, to the device that asked.
  assign a_req_done  = bio_req_done  && !eng_owner;
  assign a_req_error = bio_req_error && !eng_owner;
  assign b_req_done  = (bio_req_done  &&  eng_owner) || w_kill_done;
  assign b_req_error = (bio_req_error &&  eng_owner) || w_kill_done;

  // "The request is in hand": the level pc9821_fdd_media releases `blk_req_rd` on. It is the
  // queue entry or the ownership, so it never falls between the two.
  assign b_busy = b_pend || (owner && (arb != ARB_IDLE));
  assign a_busy = a_pend || (!owner && (arb != ARB_IDLE));

  always @(posedge clk) begin
    if (!rst_n) begin
      arb          <= ARB_IDLE;
      owner        <= 1'b0;
      owner_slot   <= 1'b0;
      last_owner   <= 1'b0;
      eng_owner    <= 1'b0;
      eng_slot     <= 1'b0;
      eng_loaded   <= 1'b0;
      a_pend       <= 1'b0;
      a_pend_write <= 1'b0;
      a_pend_lba   <= 32'd0;
      b_pend       <= 1'b0;
      b_pend_write <= 1'b0;
      b_pend_lba   <= 16'd0;
      b_pend_slot  <= 1'b0;
      w_kill       <= 1'b0;
      w_kill_done  <= 1'b0;
      grant_lba    <= 32'd0;
      grant_write  <= 1'b0;
    end else begin
      // ==== the request queues ====
      // Take a device's request unless its own entry is still occupied. The disk's is a pulse
      // and the floppy's a level held until `b_busy` takes it, so both are one-shots here; the
      // `!pend` guard is what makes the floppy's level single-shot even on the cycle the level
      // and the grant coincide. The floppy's image tag is latched with its index, so the image
      // the request is for cannot change after the requester withdraws the level.
      if ((a_req_read || a_req_write) && !a_pend) begin
        a_pend       <= 1'b1;
        a_pend_write <= a_req_write;
        a_pend_lba   <= a_req_lba;
      end
      if (b_req_read && !b_pend) begin
        b_pend       <= 1'b1;
        b_pend_write <= b_req_write;
        b_pend_lba   <= b_req_lba;
        b_pend_slot  <= b_req_slot;
      end
      // The write fence's set (one statement, R2): a mount of the write's slot at its take,
      // while it waits in the queue, or while it is granted and not yet handed over. The medium
      // has one fetch outstanding, so the queued and the granted write are never two at once and
      // one flag serves both phases.
      w_kill_done <= kill_now;
      if (kill_now)
        w_kill <= 1'b0;
      else if ((b_req_read && !b_pend && b_req_write && b_mnt_take) ||
               (b_pend && b_pend_write && b_mnt_pend) ||
               (owner && grant_write && (arb == ARB_META) && b_mnt_grant))
        w_kill <= 1'b1;

      // ==== hand-over and service ====
      case (arb)
        ARB_IDLE: if (a_want || b_want) begin
          // The grant. The engine is idle here - ownership is only released below when it is -
          // so the request it is handed is the one it accepts.
          owner       <= grant_b_now;
          // The floppy's image tag is only meaningful when the floppy owns the engine, so it is
          // gated on the grant: a disk grant then leaves `eng_sel` exactly 2'd0 (the disk's own
          // value), and a back-to-back disk transfer does NOT pay a metadata reload because a
          // stale floppy slot was still latched beside it.
          owner_slot  <= grant_b_now && b_pend_slot;
          last_owner  <= grant_b_now;
          grant_lba   <= grant_b_now ? {16'd0, b_pend_lba} : a_pend_lba;
          grant_write <= grant_b_now ? b_pend_write : a_pend_write;
          // Same image: the engine still holds it, so there is nothing to load and nothing to
          // invalidate. DIFFERENT IMAGE - including the OTHER floppy drive - is a metadata
          // load, which the engine does without touching its read-ahead window (T19).
          arb <= (eng_loaded && (grant_sel == eng_sel)) ? ARB_REQ : ARB_META;
        end

        ARB_META: begin
          // This cycle drives the engine's img_mounted with the new owner's image, and the
          // engine's latch takes it at this edge. It does NOT clear the window: the window is
          // only invalidated when the image its own blocks came from is replaced, which is
          // `bio_win_flush` above.
          eng_owner  <= owner;
          eng_slot   <= owner_slot;
          eng_loaded <= 1'b1;
          arb        <= ARB_REQ;
        end

        // A killed floppy write was never handed to the engine, so there is nothing to hold:
        // the engine is idle and its one (error) completion is w_kill_done.
        ARB_REQ: arb <= kill_now ? ARB_IDLE : ARB_HELD;

        // The transfer, and a burst's background tail after its served sector, keep the engine
        // busy; ownership is held until it is fully idle, so the other device is handed the
        // engine only when this one's fetch is finished with it. The WINDOW it may leave behind
        // is the disk's (`req_window`), and the tag keeps the incoming device from using it.
        default: if (!bio_busy) arb <= ARB_IDLE;
      endcase

      // ==== the granted entries ====
      // Written after the take above, so the grant wins the cycle it happens in: the request
      // the engine was just handed leaves the queue, and a request that arrives in that same
      // cycle is dropped exactly as pc9821_block_io's own contract drops one ("neither latched
      // nor queued").
      if (grant_a) a_pend <= 1'b0;
      if (grant_b) b_pend <= 1'b0;
    end
  end

endmodule

`default_nettype wire
