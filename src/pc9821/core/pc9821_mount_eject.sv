// THE OSD's EJECT ACTIONS, turned into the mount event every image consumer already understands.
//
// WHAT AN EJECT IS AT THIS SEAM. Every consumer of an hps_io image slot (pc9821_block_share's
// slot latches, pc9821_fdd_media's mount latch, pc9821_disk_change_reset's IDE reset) reads one
// event: img_mounted for the slot, with img_size / img_readonly "valid only for active bit in
// img_mounted" (sys/hps_io.sv:144-145). An image smaller than one sector is an UNMOUNT to all of
// them - pc9821_block_io's own rule (`eject = img_mounted && (img_size < 512)`) - so an eject is a
// mount event with img_size 0. Whether Main_MiSTer itself ever sends one (an unmount from its file
// browser) is the ARM program's behaviour, which is not in this repo; this module does not depend
// on it. The OSD's `T` entries (z486_mister.sv's CONF_STR, one per slot) give the user an eject
// that always exists, and this module synthesises that one-cycle event.
//
// THE EVENTS ARE MERGED, NEVER RACED (docs/single-cycle-event-discipline.md):
//   * R7, deferred not lost: an eject request is a rising edge of its OSD bit, and it is held in
//     `pend` until the host channel is quiet - no hps_io mount level on ANY slot this cycle or the
//     last - and then issued. Because the issue is gated on `hps_d == 0` (the host event the
//     output stage takes in the same cycle), the shared img_size / img_readonly registers are
//     never claimed by a host mount and an eject at once:
//     the size mux below is exclusive by construction (asserted, R8).
//   * R4, one at a time: two pending ejects are issued on successive cycles, lowest slot first,
//     each as its own one-hot pulse, so a consumer latching per slot sees exactly one event.
//   * R3, set vs clear: an eject edge arriving in the cycle its own slot is being issued is MERGED
//     into that issue (the pending bit is cleared) - it is the same request, and re-arming it would
//     issue a second eject, i.e. a second IDE reset, for one OSD action.
//   * Every event is its own edge: an eject's one-cycle pulse on slot X never touches another
//     event on slot X - neither the host mount whose level just ended nor one that starts right
//     after it - so a consumer that reads the RISING EDGE of img_mounted[X] (pc9821_fdd_media's
//     `mnt_ev`, the ATAPI's mount edge) sees each eject and each mount once. hps_io's event is
//     delayed one extra clk_sys (`hps_d`), which gives the issue one cycle of look-ahead: an eject
//     is issued only when hps_io is quiet this cycle and the last (so no host level on any slot
//     is adjacent to the pulse on either side) and the slot's own output was low last cycle. Ejects
//     of DIFFERENT slots still go out on successive cycles: each is a separate bit.
//   * Pass-through otherwise: hps_io's own events go through unchanged, TWO clk_sys later. The
//     outputs are registered together (the event, its size and its flag stay aligned), so the
//     merge (quiet -> issue -> the 64-bit size mux) is not in one cycle with every consumer's
//     latch enables and size compares (pc9821_block_io's eject test and capacity, block_share's
//     slot latches, fdd_media's mnt_size, the ATAPI's mount edge): on the lane head's fits that
//     single-cycle cone reached the block engine from hps_io's img_mounted and from `pend` at
//     -2.9 / -2.8 ns (seeds 3, 7; about 190 endpoints each). Only the event bits take the extra
//     stage: hps_io writes img_size only in a 0x1d transaction's data bytes and img_readonly with
//     img_mounted's own 0x1c set (sys/hps_io.sv:490-495, "'h1d: if(byte_cnt<5) img_size"), and
//     img_mounted falls only when the transaction ends (sys/hps_io.sv:334, "img_mounted <= 0;"),
//     so both are still the mount's values in the cycle after its level ends. A mount arrives from
//     the HPS over SPI on a millisecond scale and the CPU waits for the pack, so 22 ns moves
//     nothing a guest can see.
`default_nettype none

module pc9821_mount_eject #(
    parameter integer N = 4           // the image slots that have an OSD eject (hps_io slots 0..N-1)
) (
    input  wire         clk,
    // hps_io's image events, as the framework delivers them.
    input  wire [N-1:0] hps_mounted,
    input  wire [63:0]  hps_size,
    input  wire         hps_readonly,
    // The OSD eject actions, one status bit per slot (a `T` entry: a level the menu raises and
    // drops). The request is the rising edge.
    input  wire [N-1:0] eject_req,
    // The events the core's consumers read in place of hps_io's.
    output wire [N-1:0] img_mounted,
    output wire [63:0]  img_size,
    output wire         img_readonly
);

  // No reset anywhere here, like the mount latches this feeds: an eject requested while the core
  // is held (the firmware pack still loading) must still be delivered when it can be.
  reg [N-1:0] eject_q;
  reg [N-1:0] pend;
  reg [N-1:0] hps_d;        // hps_io's event, one clk_sys late (the issue's look-ahead)
  reg [N-1:0] mounted_q;    // the registered event, size and flag (the outputs)
  wire [63:0] size_q;
  wire        readonly_q;
  initial begin
    eject_q = {N{1'b0}};
    pend    = {N{1'b0}};
    hps_d   = {N{1'b0}};
    mounted_q  = {N{1'b0}};
  end

  wire [N-1:0] eject_ev = eject_req & ~eject_q;
  // The lowest pending slot, and whether the channel is free to carry it this cycle. The pulse
  // reaches the output next cycle, beside hps_d (the size mux's other claimant, so it must be
  // quiet); the output cycle after it carries hps_mounted's bits now (quiet, so no host level
  // starts against the pulse); the output cycle before it is mounted_q now (the slot's own bit
  // low, so no host level ends against it).
  wire [N-1:0] pick     = pend & (~pend + {{(N-1){1'b0}}, 1'b1});
  wire         quiet    = ~|hps_mounted && ~|hps_d && ~|(pick & mounted_q);
  wire [N-1:0] issue    = quiet ? pick : {N{1'b0}};

  always @(posedge clk) begin
    eject_q <= eject_req;
    // R3: the issue clears its own bit AFTER the new edges are merged in, so an edge coinciding
    // with its own issue is absorbed by it (see the header).
    pend    <= (pend | eject_ev) & ~issue;
  end

  // An ejected slot has no medium to protect; consumers latch the flag with the event, and the
  // block engine rejects every request against an unmounted slot whatever this says.
  always @(posedge clk) begin
    hps_d      <= hps_mounted;
    mounted_q  <= hps_d | issue;
  end
  // The size and flag take ONE stage beside the event's two, so the cycle the stage registers
  // for a host event is the one AFTER the host's level (hps_d): pc9821_static_stage asserts there
  // that hps_io's size and flag still hold the level's values (the header's argument). An issue
  // never shares that cycle (asserted below), so the mux is on the host's values there.
  pc9821_static_stage #(.W(65), .DEPTH(1)) u_size_stage (
      .clk(clk), .d((|issue) ? 65'd0 : {hps_readonly, hps_size}), .q({readonly_q, size_q}),
      .chk_en(|hps_d));
  assign img_mounted  = mounted_q;
  assign img_size     = size_q;
  assign img_readonly = readonly_q;

  // synthesis translate_off
  // R8: the shared size/readonly registers are never claimed by a host mount and an eject in one
  // cycle, an eject is always exactly one slot, and an eject's pulse never joins another event's
  // level on its slot (the output is low on that slot the cycle before and the cycle after).
  reg [N-1:0] issue_q;
  initial issue_q = {N{1'b0}};
  always @(posedge clk) issue_q <= issue;
  always @(posedge clk) begin
    if ((|issue) && (|hps_d))
      $error("pc9821_mount_eject: an eject issued while hps_io is mounting (size mux collision)");
    if ((issue & (issue - {{(N-1){1'b0}}, 1'b1})) != {N{1'b0}})
      $error("pc9821_mount_eject: more than one slot ejected in one cycle");
    if ((|(issue & mounted_q)) || (|(issue_q & (hps_d | issue))))
      $error("pc9821_mount_eject: an eject joined another event's level on its slot");
  end
  // synthesis translate_on

endmodule

`default_nettype wire
