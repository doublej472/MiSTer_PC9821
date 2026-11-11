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
//     `pend` until the host channel is quiet - no hps_io mount pulse on ANY slot this cycle - and
//     then issued. Because the issue is gated on `hps_mounted == 0` in the same cycle, the shared
//     img_size / img_readonly registers are never claimed by a host mount and an eject at once:
//     the size mux below is exclusive by construction (asserted, R8).
//   * R4, one at a time: two pending ejects are issued on successive cycles, lowest slot first,
//     each as its own one-hot pulse, so a consumer latching per slot sees exactly one event.
//   * R3, set vs clear: an eject edge arriving in the cycle its own slot is being issued is MERGED
//     into that issue (the pending bit is cleared) - it is the same request, and re-arming it would
//     issue a second eject, i.e. a second IDE reset, for one OSD action.
//   * Pass-through otherwise: hps_io's own events go straight through, unchanged and undelayed.
// RESIDUAL (documented, not modelled): an hps_io mount of slot X that rises in the cycle right
// AFTER this module issued an eject of slot X joins it into one continuous level, which the
// edge-reading consumers take as one event. The OSD is one menu on one ARM thread, so a trigger
// and an image selection are separate menu transactions, milliseconds apart.
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
  initial begin
    eject_q = {N{1'b0}};
    pend    = {N{1'b0}};
  end

  wire [N-1:0] eject_ev = eject_req & ~eject_q;
  // The lowest pending slot, and whether the channel is free to carry it this cycle.
  wire [N-1:0] pick     = pend & (~pend + {{(N-1){1'b0}}, 1'b1});
  wire         quiet    = ~|hps_mounted;
  wire [N-1:0] issue    = quiet ? pick : {N{1'b0}};

  always @(posedge clk) begin
    eject_q <= eject_req;
    // R3: the issue clears its own bit AFTER the new edges are merged in, so an edge coinciding
    // with its own issue is absorbed by it (see the header).
    pend    <= (pend | eject_ev) & ~issue;
  end

  assign img_mounted  = hps_mounted | issue;
  assign img_size     = (|issue) ? 64'd0 : hps_size;
  // An ejected slot has no medium to protect; consumers latch the flag with the event, and the
  // block engine rejects every request against an unmounted slot whatever this says.
  assign img_readonly = (|issue) ? 1'b0 : hps_readonly;

`ifndef SYNTHESIS
  // R8: the shared size/readonly registers are never claimed by a host mount and an eject in one
  // cycle, and an eject is always exactly one slot.
  always @(posedge clk) begin
    if ((|issue) && (|hps_mounted))
      $error("pc9821_mount_eject: an eject issued while hps_io is mounting (size mux collision)");
    if ((issue & (issue - {{(N-1){1'b0}}, 1'b1})) != {N{1'b0}})
      $error("pc9821_mount_eject: more than one slot ejected in one cycle");
  end
`endif

endmodule

`default_nettype wire
