// PC-9821 GVRAM CPU-side port share: the CPU's plane-window access and the graphics
// GDC's draw-engine visit, one at a time (the GDC2 WRITE slice).
//
// The GVRAM cluster (pc9821_gvram_arb + the GRCG and EGC store paths) has ONE CPU-side
// port - the dispatch it runs is the CPU transaction's, not a bus arbiter's ("there is
// no arbitration between them", pc9821_gvram_arb's client-0 note). The GDC draw engine
// is a second master of the same port, and on the machine its writes travel the SAME
// GRCG/EGC tile path a CPU store of the same shape takes (NP2kai io/gdc_pset.c's
// dispatch: withegc -> egc_writeword, withtdw/withrmw -> the tile words, else the
// plain ROP - and the ITF's own GVRAM test at BANK4@0xFA70F passes on the Xe10 only
// because a GDC store there is served by the GRCG's TDW tile write). So a visit is
// presented as a CPU plane-window access of the same operands, and this module picks
// which master owns the port and routes the answers back.
//
// THE GRANT AND THE RESPONSE TAG ARE TWO DIFFERENT THINGS, and the second one is why
// this is not a plain mux. The cluster's read data strobe NEVER shares the accept's
// cycle (the responder contract in pc9821_memory_subsystem) and can come LATER - so a
// response owed to a transaction accepted before the switch must still reach the side
// that issued it. `resp_gdc_q` tags each response with the owner of the transaction
// whose ready produced it; the mux select (`gdc_own_q`) only decides whose OPERANDS the
// cluster sees. The grant itself waits for the CPU side to be quiet (no request
// presented), because a request already presented must not have its operands pulled
// out from under its own accept.
`default_nettype none

module pc9821_gvram_share (
    input wire clk,
    input wire reset,

    // The CPU's plane-window request (already decoded as "this access is GVRAM").
    input  wire        cpu_req,
    input  wire        cpu_write,
    input  wire        cpu_line_read,
    input  wire        cpu_page,
    input  wire  [1:0] cpu_plane,
    input  wire [14:0] cpu_offset,
    input  wire [31:0] cpu_din,
    input  wire  [3:0] cpu_be,

    // The engine gates the dispatch reads (the GRCG's mode bits, the EGC's gate).
    input  wire        gate_egc,
    input  wire        gate_grcg,
    input  wire        gate_tcr,

    // The cluster's answers toward the CPU. A line read's WORD BEATS are never a visit's
    // (a GDC draw is a word stream) and are passed through ungated: only the CPU ever
    // presents cpu_line_read. The share is NOT held for the walk: pc9821_gvram_arb accepts a
    // line read at the walk's start, z486 drops its request on that accept, and a waiting visit
    // may be granted while the walk still runs. That is safe because the arbiter's in-flight
    // owner latch keeps the visit from being dispatched until the walk ends, and the walk reads
    // only its own latched operands (c_plane, c_page, c_line_base), never this port's live
    // page, plane or offset (tb_pc9821_gvram_line_page).
    output wire        cpu_ready,
    output wire        cpu_resp_valid,
    output wire [31:0] cpu_dout,
    output wire        cpu_line_word_valid,
    output wire [31:0] cpu_line_word,

    // The GDC draw engine's visit (pc9821_gdc2's WRITE engine). `gdc_valid` holds
    // until `gdc_ready`; a read's datum answers on `gdc_resp`/`gdc_rdata` later.
    input  wire        gdc_valid,
    input  wire        gdc_write,
    input  wire        gdc_route_egc,
    input  wire        gdc_route_grcg,
    input  wire        gdc_page,
    input  wire  [1:0] gdc_plane,
    input  wire [14:0] gdc_offset,
    input  wire [31:0] gdc_din,
    input  wire  [3:0] gdc_be,
    output wire        gdc_ready,
    output wire        gdc_resp_valid,
    output wire [31:0] gdc_rdata,

    // The cluster side (pc9821_gvram_arb's CPU route and the two engines' store ports).
    output wire        gvr_valid,
    output wire        gvr_write,
    output wire        gvr_line_read,
    output wire        gvr_page,
    output wire  [1:0] gvr_plane,
    output wire [14:0] gvr_offset,
    output wire [31:0] gvr_din,
    // gvr_din's per-byte 0x00 and 0xFF flags (byte k is gvr_din[8k+7:8k]), formed on each
    // operand before the select (docs/timing.md C7-dz): the GRCG and the arbiter read these in place
    // of their own compares on gvr_din, so the operand mux leaves the datum-class cone.
    output wire  [3:0] gvr_din_z,
    output wire  [3:0] gvr_din_f,
    output wire  [3:0] gvr_be,
    output wire        gvr_gate_egc,
    output wire        gvr_gate_grcg,
    output wire        gvr_gate_tcr,
    input  wire        gvr_ready,
    input  wire        gvr_resp_valid,
    input  wire [31:0] gvr_dout,
    input  wire        gvr_line_word_valid,
    input  wire [31:0] gvr_line_word
);

  // The mux select: a visit owns the port from its grant until its own completion -
  // a store's ready, a read's response strobe. It is a REGISTER, so the operands
  // cannot move under a cycle where the cluster is accepting.
  reg gdc_own_q;
  // Whose transaction the cluster's next word response belongs to. Set at every
  // accept-side ready from the owner of that transaction; a store's ready sets it and
  // no strobe follows, which is harmless - the next read's ready re-sets it.
  reg resp_gdc_q;
  // The visit's request has been accepted; its completion may still be pending (a
  // read's response comes later), so this is what the hold-until-accept assertion
  // below keys on rather than the mux select alone.
  reg visit_taken_q;

  function automatic [3:0] bytes_00(input [31:0] d);
    bytes_00 = {(d[31:24] == 8'h00), (d[23:16] == 8'h00), (d[15:8] == 8'h00), (d[7:0] == 8'h00)};
  endfunction
  function automatic [3:0] bytes_ff(input [31:0] d);
    bytes_ff = {(d[31:24] == 8'hFF), (d[23:16] == 8'hFF), (d[15:8] == 8'hFF), (d[7:0] == 8'hFF)};
  endfunction

  wire grant = gdc_valid && !cpu_req && !gdc_own_q;

  // THE VISIT'S OPERANDS ARE CAPTURED AT ITS GRANT. The visitor holds its request and its
  // operands from the raise until its ready (R7, the `gdc_valid` contract above), and the port
  // is granted afresh for every visit (the grant needs !gdc_own_q), so the operands the cluster
  // reads in any owned cycle are the ones presented on the grant edge. Taking them into
  // registers on that edge changes no cycle and no value (the Verilator checks below hold the
  // live operands to the captured ones until the accept), and it means the operand select
  // below is `gdc_own_q ? <register> : cpu_x`: whatever logic forms the visitor's operands -
  // the draw engine's, or the memory subsystem's DMA/draw-engine choice - stays out of the
  // cluster's store path, which the CPU's operands share. The request itself is the captured
  // bit cleared at the accept: after its ready a visit presents no further access (a read
  // then only waits for its response), which is what the live request did.
  reg        vq_valid, vq_write, vq_route_egc, vq_route_grcg, vq_page;
  reg  [1:0] vq_plane;
  reg [14:0] vq_offset;
  reg [31:0] vq_din;
  reg  [3:0] vq_din_z, vq_din_f, vq_be;
  always @(posedge clk) begin
    if (reset) vq_valid <= 1'b0;
    else if (grant) vq_valid <= 1'b1;
    else if (gdc_own_q && gvr_ready) vq_valid <= 1'b0;
    if (grant) begin
      vq_write      <= gdc_write;
      vq_route_egc  <= gdc_route_egc;
      vq_route_grcg <= gdc_route_grcg;
      vq_page       <= gdc_page;
      vq_plane      <= gdc_plane;
      vq_offset     <= gdc_offset;
      vq_din        <= gdc_din;
      vq_din_z      <= bytes_00(gdc_din);
      vq_din_f      <= bytes_ff(gdc_din);
      vq_be         <= gdc_be;
    end
  end

  // A store completes on its ready; a read completes on its (later) response strobe.
  wire visit_done = gdc_own_q && (vq_write ? gvr_ready : (gvr_resp_valid && resp_gdc_q));

  always @(posedge clk) begin
    if (reset) begin
      gdc_own_q  <= 1'b0;
      resp_gdc_q <= 1'b0;
      visit_taken_q <= 1'b0;
    end else begin
      if (grant)      gdc_own_q <= 1'b1;
      else if (visit_done) gdc_own_q <= 1'b0;
      if (gvr_ready)  resp_gdc_q <= gdc_own_q;
      if (grant)      visit_taken_q <= 1'b0;
      else if (gvr_ready && gdc_own_q) visit_taken_q <= 1'b1;
    end
  end

  // The operands. The engine's route is latched per draw (pc9821_gdc2's
  // gdcpset_prepare analog), so a mid-draw mode change cannot re-route a draw: while a
  // visit owns the port the gates presented to the cluster are the visit's own, and a
  // read visit is always the plain path (its merge read is the engine's own, never a
  // GRCG TCR or an EGC read).
  assign gvr_valid      = gdc_own_q ? vq_valid : cpu_req;
  assign gvr_write      = gdc_own_q ? vq_write : cpu_write;
  assign gvr_line_read  = gdc_own_q ? 1'b0 : cpu_line_read;
  assign gvr_page       = gdc_own_q ? vq_page : cpu_page;
  assign gvr_plane      = gdc_own_q ? vq_plane : cpu_plane;
  assign gvr_offset     = gdc_own_q ? vq_offset : cpu_offset;
  assign gvr_din        = gdc_own_q ? vq_din : cpu_din;
  assign gvr_din_z      = gdc_own_q ? vq_din_z : bytes_00(cpu_din);
  assign gvr_din_f      = gdc_own_q ? vq_din_f : bytes_ff(cpu_din);
  assign gvr_be         = gdc_own_q ? vq_be : cpu_be;
  assign gvr_gate_egc   = gdc_own_q ? vq_route_egc : gate_egc;
  assign gvr_gate_grcg  = gdc_own_q ? vq_route_grcg : gate_grcg;
  assign gvr_gate_tcr   = gdc_own_q ? 1'b0 : gate_tcr;

  // The answers. The ready's owner is the mux select of its own cycle; the response's
  // owner is the tag (it can outlive the switch).
  assign cpu_ready      = gvr_ready && !gdc_own_q;
  assign gdc_ready      = gvr_ready && gdc_own_q;
  assign cpu_resp_valid = gvr_resp_valid && !resp_gdc_q;
  assign gdc_resp_valid = gvr_resp_valid && resp_gdc_q;
  assign cpu_dout       = gvr_dout;
  assign gdc_rdata      = gvr_dout;
  assign cpu_line_word_valid = gvr_line_word_valid;
  assign cpu_line_word  = gvr_line_word;

`ifdef VERILATOR
  // The engine's contract on this boundary: a visit is presented until it is accepted
  // (docs/single-cycle-event-discipline.md R7 - deferred consumption, never a dropped
  // request). A request that falls before its ready would strand the cluster's accept.
  always @(posedge clk) begin
    if (!reset && gdc_own_q && !visit_taken_q && !gdc_valid)
      $error("pc9821_gvram_share: the GDC visit dropped mem_valid before its ready - the request must hold until accepted (R7)");
    // The captured operands are the live ones until the accept (what makes the capture
    // value-identical), and an accepted visit raises no second access while it still owns
    // the port (what makes the cleared vq_valid equal to the live request).
    if (!reset && gdc_own_q && !visit_taken_q &&
        ({gdc_write, gdc_route_egc, gdc_route_grcg, gdc_page, gdc_plane, gdc_offset, gdc_din, gdc_be} !=
         {vq_write, vq_route_egc, vq_route_grcg, vq_page, vq_plane, vq_offset, vq_din, vq_be}))
      $error("pc9821_gvram_share: a visit's operands moved between its grant and its accept");
    if (!reset && gdc_own_q && visit_taken_q && gdc_valid)
      $error("pc9821_gvram_share: an accepted visit presented a further request while it still owns the port");
  end
`endif

endmodule

`default_nettype wire
