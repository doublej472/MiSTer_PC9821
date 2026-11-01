`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PERF_MSG:
// The per-interval performance record reports what its TWENTY-ONE fields mean and is one line: a cycle with a CPU memory request outstanding and unaccepted is a memory-wait cycle and one with the same request accepted is not, a transaction on the main SDRAM port counts once when it is ACCEPTED, split read from write, the other three SDRAM requester ports (font/PCM/scanout) count their own accepts (S1/S2/S3) and the scanout port's present-but-unaccepted cycles are counted separately (W3), the GVRAM walk's two pulses count walks started and walk cycles and neither counter sees the other one, the EGC transaction and unit pulses and the GRCG store pulse each count their own events and nothing else (so EG/ET and EG/EU split many operations from long operations), the GRCG's and the EGC's OWNERSHIP pulses count into GV/EV only while the raster is on a visible line (so a visible sprite-store cycle - one the beam can catch - is distinguishable from one in blanking), PD is a GAUGE that restarts at the vblank edge and tracks the last GRCG store's position in the frame (the sprite pass's wall-clock), PC counts a GRCG store IN FLIGHT while the access page EQUALS the page the scanout's line fetch is latched on (the page-coincidence leak: correct double-buffering keeps the two pages OPPOSITE, so a nonzero PC is a store the beam can catch) with SP and AP carrying the two page bits themselves, and CY advances every cycle - all driven cycle by cycle and read back out of the record, so it cannot claim a rate the handshake does not support. The record is also a SNAPSHOT: its digits are the counters' values at the report's accept (snap), held while the record is read, so moving the stimulus after the snapshot and re-reading reprints the same bytes and a paced emission can never splice two counter values into one field (a telemetry tear); a NEW snapshot takes the new values.
//
// WHY THE COUNTERS ARE CHECKED HERE AND NOT ONLY THE BYTES. The record's whole claim is
// "this interval spent N cycles waiting on memory and issued R reads and W writes", and every
// part of that claim is arithmetic: the wrong edge (a request that was ACCEPTED and not one that
// was merely present), a write counted as a read, a wait cycle counted while the request was
// being answered. A byte-level golden would pass with all of them wrong, so the bench drives the
// handshake shapes and the event pulses and asserts the deltas each one must produce.
//
// THE 256-BYTE RECORD AND ITS NUL CHECKS. The two NUL checks read REC_LEN and REC_LEN + 1, the
// first indices past the record; the indices are derived from REC_LEN and the stride rather than
// written as literals, so a field added or removed cannot leave a check asserting that a real hex
// digit is NUL.
//
// It also asserts the newline shape the decoder requires: exactly one 0x0A, as the last byte, and no
// 0x0D anywhere - a CR comes back as a second newline through a tty's ICRNL, which is the blank
// line between records the record was rewritten to remove.

module tb_pc9821_perf_msg;

  // ==== DUT ====

  reg        clk, reset;
  reg        cpu_req, cpu_ack;
  reg        sd_valid, sd_ready, sd_write;
  reg        sd1_valid, sd1_ready, sd2_valid, sd2_ready, sd3_valid, sd3_ready;
  reg        dbg_walk_start, dbg_walk_cycle;
  reg        dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;
  reg        dbg_gr_owned, dbg_eg_owned, dbg_pw_owned, v_active, vsync_edge;
  reg        dbg_access_page, dbg_scan_page_q;
  reg  [2:0] pf_code = 3'd0;
  reg [31:0] pf_addr = 32'd0;
  reg  [8:0] idx;
  reg        snap;
  wire [7:0] ch;

  pc9821_perf_msg dut (
    .clk(clk), .reset(reset),
    .cpu_req(cpu_req), .cpu_ack(cpu_ack),
    .sd_valid(sd_valid), .sd_ready(sd_ready), .sd_write(sd_write),
    .sd1_valid(sd1_valid), .sd1_ready(sd1_ready),
    .sd2_valid(sd2_valid), .sd2_ready(sd2_ready),
    .sd3_valid(sd3_valid), .sd3_ready(sd3_ready),
    .dbg_walk_start(dbg_walk_start), .dbg_walk_cycle(dbg_walk_cycle),
    .dbg_egc_txn(dbg_egc_txn), .dbg_egc_unit(dbg_egc_unit),
    .dbg_grcg_store(dbg_grcg_store),
    .dbg_gr_owned(dbg_gr_owned), .dbg_eg_owned(dbg_eg_owned),
    .dbg_pw_owned(dbg_pw_owned),
    .v_active(v_active), .vsync_edge(vsync_edge),
    .dbg_access_page(dbg_access_page), .dbg_scan_page_q(dbg_scan_page_q),
    .dbg_pf_code(pf_code), .dbg_pf_addr(pf_addr),
    .snap(snap),
    .idx(idx), .ch(ch)
  );

  // The record's map, which is also what tools/decode_telemetry.py parses: "PRF", then
  // TWENTY-ONE 12-byte fields (space, 2-char label, '=', 8 hex digits), then one LF. 256 bytes.
  //   prefix [0..2], field f at 3 + 12f: ' ' at +0, label at +1..+2, '=' at +3, digits at +4..+11
  localparam integer NFIELDS = 21;
  localparam [8:0] REC_LEN = 9'd256;
  localparam [8:0] F0      = 9'd3;      // the first field's delimiter
  localparam [8:0] STRIDE  = 9'd12;
  localparam [8:0] DIG0    = 9'd7;      // the first field's first hex digit
  localparam [8:0] REC_LF  = REC_LEN - 9'd1;

  reg [7:0] rec [0:255];
  reg [7:0] rec_hold [0:255];
  integer i, f;  reg [31:0] cy, mw, rd, wr, gw, gc, et, eu, gs, gv, ev, pd;
  reg [31:0] pc, sp, ap;
  reg [31:0] s1, s2, s3, w3, pf, pa;
  reg [31:0] cy_prev, mw_prev, rd_prev, wr_prev;
  reg [31:0] gw_prev, gc_prev, et_prev, eu_prev, gs_prev, gv_prev, ev_prev, pc_prev;
  reg [31:0] s1_prev, s2_prev, s3_prev, w3_prev;

  always #5 clk = ~clk;

  task automatic read_rec; begin
    for (i = 0; i < REC_LEN; i = i + 1) begin
      idx = i[8:0];
      #1;
      rec[i] = ch;
    end
  end endtask

  function [3:0] hexval(input [7:0] c);
    hexval = (c >= "A") ? (c - 8'h37) : (c - 8'h30);
  endfunction

  // The eight hex digits of one field, MOST significant first, as the record lays them out.
  function [31:0] rec_val(input integer dig0);
    integer k;
    begin
      rec_val = 32'd0;
      for (k = 0; k < 8; k = k + 1)
        rec_val = (rec_val << 4) | {28'd0, hexval(rec[dig0 + k])};
    end
  endfunction

  // ONE field's value read with the stimulus HELD, the way SP/AP must be read: they are LIVE status
  // bits, not registered counters, so idling before the read (as sample does) drives them to 0 and
  // a crossed wire would pass. This walks the eight digits without touching the inputs between. It
  // is a TASK, not a function: it waits on simulation time, which a function may not do.
  task automatic read_field(output [31:0] v, input integer fld);
    integer k;
    begin
      v = 32'd0;
      for (k = 0; k < 8; k = k + 1) begin
        idx = (DIG0 + fld * STRIDE + k);
        #1;
        v = (v << 4) | {28'd0, hexval(ch)};
      end
    end
  endtask

  // One clk_sys: the handshakes are combinational inputs sampled on the edge, so a cycle of
  // stimulus is set up and then one edge is taken.
  task automatic cycle; begin
    @(posedge clk);
    #1;
  end endtask

  // IDLE BEFORE READING. read_rec takes 100 ns of simulated time, during which the clock keeps
  // running: a request or a pulse left asserted would be counted while the bench is reading the
  // record, and the delta it then checks would be the reading's own cost rather than the
  // stimulus's. CY cannot be isolated this way at the COUNTER - it advances every cycle by
  // definition - but the record reads its snapshot, so the value a check sees is the snap
  // instant's and the CY delta check below stays a bound over the snaps.
  task automatic idle; begin
    cpu_req = 1'b0; cpu_ack = 1'b0;
    sd_valid = 1'b0; sd_ready = 1'b0; sd_write = 1'b0;
    sd1_valid = 1'b0; sd1_ready = 1'b0;
    sd2_valid = 1'b0; sd2_ready = 1'b0;
    sd3_valid = 1'b0; sd3_ready = 1'b0;
    dbg_walk_start = 1'b0; dbg_walk_cycle = 1'b0;
    dbg_egc_txn = 1'b0; dbg_egc_unit = 1'b0; dbg_grcg_store = 1'b0;
    dbg_gr_owned = 1'b0; dbg_eg_owned = 1'b0; dbg_pw_owned = 1'b0; v_active = 1'b0; vsync_edge = 1'b0;
    dbg_access_page = 1'b0; dbg_scan_page_q = 1'b0;
  end endtask

  task automatic wait_cpu(input req, input ack); begin
    idle;
    cpu_req = req; cpu_ack = ack;
  end endtask

  task automatic txn(input valid, input ready, input wr); begin
    idle;
    sd_valid = valid; sd_ready = ready; sd_write = wr;
  end endtask

  // ONE cycle of exactly these operation pulses: the pulses are set up before the edge and dropped
  // after it, so a pulse left high for two cycles would count twice, which is what the independent
  // drive below checks against.
  task automatic op_cycle(input p_et, input p_eu, input p_gs); begin
    idle;
    dbg_egc_txn = p_et; dbg_egc_unit = p_eu; dbg_grcg_store = p_gs;
    cycle;
    idle;
  end endtask

  task automatic sample; begin
    idle;
    snap = 1'b1; cycle; snap = 1'b0;   // the record's SNAPSHOT: one pulse at its accept
    read_rec;
    cy = rec_val(DIG0 + 0 * STRIDE);
    mw = rec_val(DIG0 + 1 * STRIDE);
    rd = rec_val(DIG0 + 2 * STRIDE);
    wr = rec_val(DIG0 + 3 * STRIDE);
    gw = rec_val(DIG0 + 4 * STRIDE);
    gc = rec_val(DIG0 + 5 * STRIDE);
    et = rec_val(DIG0 + 6 * STRIDE);
    eu = rec_val(DIG0 + 7 * STRIDE);
    gs = rec_val(DIG0 + 8 * STRIDE);
    gv = rec_val(DIG0 + 9 * STRIDE);
    ev = rec_val(DIG0 + 10 * STRIDE);
    pd = rec_val(DIG0 + 11 * STRIDE);
    pc = rec_val(DIG0 + 12 * STRIDE);
    sp = rec_val(DIG0 + 13 * STRIDE);
    ap = rec_val(DIG0 + 14 * STRIDE);
    s1 = rec_val(DIG0 + 15 * STRIDE);
    s2 = rec_val(DIG0 + 16 * STRIDE);
    s3 = rec_val(DIG0 + 17 * STRIDE);
    w3 = rec_val(DIG0 + 18 * STRIDE);
    pf = rec_val(DIG0 + 19 * STRIDE);
    pa = rec_val(DIG0 + 20 * STRIDE);
  end endtask

  // ==== CHECKS ====
  initial begin
    clk = 1'b0; reset = 1'b1;
    snap = 1'b0;
    idle;
    idx = 9'd0;
    cycle; cycle;
    reset = 1'b0;
    cycle;

    // 1. The record's shape: prefix, labels in order, the separators, one LF at the end, no CR.
    sample;
    if ({rec[0], rec[1], rec[2]} !== "PRF")
      $fatal(1, "the record does not start PRF: %c%c%c", rec[0], rec[1], rec[2]);
    for (f = 0; f < NFIELDS; f = f + 1) begin
      case (f)
        0: if ({rec[F0 + 1 + 0*STRIDE], rec[F0 + 2 + 0*STRIDE]} !== "CY")
             $fatal(1, "field 0's label is not CY");
        1: if ({rec[F0 + 1 + 1*STRIDE], rec[F0 + 2 + 1*STRIDE]} !== "MW")
             $fatal(1, "field 1's label is not MW");
        2: if ({rec[F0 + 1 + 2*STRIDE], rec[F0 + 2 + 2*STRIDE]} !== "RD")
             $fatal(1, "field 2's label is not RD");
        3: if ({rec[F0 + 1 + 3*STRIDE], rec[F0 + 2 + 3*STRIDE]} !== "WR")
             $fatal(1, "field 3's label is not WR");
        4: if ({rec[F0 + 1 + 4*STRIDE], rec[F0 + 2 + 4*STRIDE]} !== "GW")
             $fatal(1, "field 4's label is not GW");
        5: if ({rec[F0 + 1 + 5*STRIDE], rec[F0 + 2 + 5*STRIDE]} !== "GC")
             $fatal(1, "field 5's label is not GC");
        6: if ({rec[F0 + 1 + 6*STRIDE], rec[F0 + 2 + 6*STRIDE]} !== "ET")
             $fatal(1, "field 6's label is not ET");
        7: if ({rec[F0 + 1 + 7*STRIDE], rec[F0 + 2 + 7*STRIDE]} !== "EU")
             $fatal(1, "field 7's label is not EU");
        8: if ({rec[F0 + 1 + 8*STRIDE], rec[F0 + 2 + 8*STRIDE]} !== "GS")
             $fatal(1, "field 8's label is not GS");
        9: if ({rec[F0 + 1 + 9*STRIDE], rec[F0 + 2 + 9*STRIDE]} !== "GV")
             $fatal(1, "field 9's label is not GV");
        10: if ({rec[F0 + 1 + 10*STRIDE], rec[F0 + 2 + 10*STRIDE]} !== "EV")
             $fatal(1, "field 10's label is not EV");
        11: if ({rec[F0 + 1 + 11*STRIDE], rec[F0 + 2 + 11*STRIDE]} !== "PD")
             $fatal(1, "field 11's label is not PD");
        12: if ({rec[F0 + 1 + 12*STRIDE], rec[F0 + 2 + 12*STRIDE]} !== "PC")
             $fatal(1, "field 12's label is not PC");
        13: if ({rec[F0 + 1 + 13*STRIDE], rec[F0 + 2 + 13*STRIDE]} !== "SP")
             $fatal(1, "field 13's label is not SP");
        14: if ({rec[F0 + 1 + 14*STRIDE], rec[F0 + 2 + 14*STRIDE]} !== "AP")
             $fatal(1, "field 14's label is not AP");
        15: if ({rec[F0 + 1 + 15*STRIDE], rec[F0 + 2 + 15*STRIDE]} !== "S1")
             $fatal(1, "field 15's label is not S1");
        16: if ({rec[F0 + 1 + 16*STRIDE], rec[F0 + 2 + 16*STRIDE]} !== "S2")
             $fatal(1, "field 16's label is not S2");
        17: if ({rec[F0 + 1 + 17*STRIDE], rec[F0 + 2 + 17*STRIDE]} !== "S3")
             $fatal(1, "field 17's label is not S3");
        18: if ({rec[F0 + 1 + 18*STRIDE], rec[F0 + 2 + 18*STRIDE]} !== "W3")
             $fatal(1, "field 18's label is not W3");
        19: if ({rec[F0 + 1 + 19*STRIDE], rec[F0 + 2 + 19*STRIDE]} !== "PF")
             $fatal(1, "field 19's label is not PF");
        20: if ({rec[F0 + 1 + 20*STRIDE], rec[F0 + 2 + 20*STRIDE]} !== "PA")
             $fatal(1, "field 20's label is not PA");
      endcase
      if (rec[F0 + 0 + f*12] !== " ")
        $fatal(1, "field %0d is not delimited by a space at its start", f);
      if (rec[F0 + 3 + f*12] !== "=")
        $fatal(1, "field %0d's label is not followed by '='", f);
    end
    for (i = 0; i < REC_LEN; i = i + 1) begin
      if ((i == REC_LF) ? (rec[i] !== 8'h0A) : (rec[i] == 8'h0A))
        $fatal(1, "byte %0d of the record is %02x: the record is ONE line and its only LF is the last byte",
               i, rec[i]);
      if (rec[i] == 8'h0D)
        $fatal(1, "byte %0d of the record is a CR: a tty's ICRNL turns it into a second newline, which is the blank line between records this record removed", i);
      if (i >= DIG0 && ((i - DIG0) % 12) < 8) begin
        if (!((rec[i] >= "0" && rec[i] <= "9") || (rec[i] >= "A" && rec[i] <= "F")))
          $fatal(1, "byte %0d of the record is %c, not a hex digit", i, rec[i]);
      end
    end
    if (mw !== 0 || rd !== 0 || wr !== 0 ||
        gw !== 0 || gc !== 0 || et !== 0 || eu !== 0 || gs !== 0 ||
        gv !== 0 || ev !== 0 || pd !== 0 || pc !== 0 || sp !== 0 || ap !== 0 ||
        s1 !== 0 || s2 !== 0 || s3 !== 0 || w3 !== 0)
      $fatal(1, "the counters start at %0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d, not all zero",
             mw, rd, wr, gw, gc, et, eu, gs, gv, ev, pd, pc, sp, ap, s1, s2, s3, w3);
    if (cy == 0)
      $fatal(1, "CY is still zero after the reset sequence: it must advance every clk_sys");

    // 2. A cycle with a request OUTSTANDING AND NOT ACCEPTED is a memory-wait cycle; a cycle with
    //    the same request accepted is NOT. This is the pair pc9821_wdg_trigger calls
    //    "completed", driven as a level, one cycle at a time.
    sample;
    mw_prev = mw; cy_prev = cy;
    wait_cpu(1'b1, 1'b0);
    cycle; cycle; cycle;
    sample;
    if (mw - mw_prev != 3)
      $fatal(1, "3 cycles of an outstanding unaccepted request moved MW by %0d, not 3", mw - mw_prev);
    mw_prev = mw;
    wait_cpu(1'b1, 1'b1);            // the request is accepted: it completes, so it is not a wait
    cycle; cycle;
    sample;
    if (mw != mw_prev)
      $fatal(1, "an ACCEPTED request added %0d to MW: completion is not waiting", mw - mw_prev);
    wait_cpu(1'b0, 1'b1);            // accepted with nothing outstanding: still no wait
    cycle;
    sample;
    if (mw != mw_prev)
      $fatal(1, "an accept with no request outstanding added %0d to MW", mw - mw_prev);

    // 3. A transaction on the main port counts when it is ACCEPTED, once, and a write is not a
    //    read. A request that is present but not accepted counts nothing.
    mw_prev = mw; rd_prev = rd; wr_prev = wr;
    txn(1'b1, 1'b0, 1'b0);           // present, not accepted, a read
    cycle; cycle;
    sample;
    if (rd != rd_prev || wr != wr_prev)
      $fatal(1, "an UNACCEPTED request moved RD/WR by %0d/%0d: only an accepted transaction counts",
             rd - rd_prev, wr - wr_prev);
    txn(1'b1, 1'b1, 1'b0);
    cycle; cycle;
    sample;
    if (rd - rd_prev != 2 || wr != wr_prev)
      $fatal(1, "2 accepted reads moved RD by %0d (want 2) and WR by %0d (want 0)", rd - rd_prev, wr - wr_prev);
    rd_prev = rd; wr_prev = wr;
    txn(1'b1, 1'b1, 1'b1);
    cycle; cycle; cycle;
    sample;
    if (wr - wr_prev != 3 || rd != rd_prev)
      $fatal(1, "3 accepted writes moved WR by %0d (want 3) and RD by %0d (want 0)", wr - wr_prev, rd - rd_prev);
    rd_prev = rd; wr_prev = wr;
    txn(1'b1, 1'b0, 1'b1);           // present but not accepted, a write this time
    cycle; cycle;
    sample;
    if (wr != wr_prev)
      $fatal(1, "an unaccepted WRITE moved WR by %0d", wr - wr_prev);
    if (mw != mw_prev) $fatal(1, "the transaction stimulus moved MW by %0d", mw - mw_prev);

    // 4. CY advances on EVERY clk_sys and is the interval every other field is a fraction of. The
    //    deltas below are taken between two reads of the record, and reading it takes simulated
    //    time of the bench's own, so the check is a lower bound (the cycles driven) and an upper
    //    one (those cycles plus the scans) rather than an equality that would encode the read
    //    timing. The scan is REC_LEN cycles of 1 ns each, so the bound moves with the record's
    //    length (256 bytes, about 26 clk_sys) instead of being a literal that has to be bumped whenever
    //    a field is added. The lower bound is the property that matters: an interval counter that
    //    skipped a cycle would shrink every percentage in the capture.
    cy_prev = cy;
    idle;
    cycle; cycle; cycle; cycle; cycle;
    sample;
    if (cy - cy_prev < 5)
      $fatal(1, "5 driven clk_sys advanced CY by %0d: CY must advance every cycle", cy - cy_prev);
    if (cy - cy_prev > REC_LEN + 8)
      $fatal(1, "5 driven clk_sys advanced CY by %0d: CY advanced while idle", cy - cy_prev);

    // 7. The GVRAM walk's two pulses: a walk STARTS on dbg_walk_start and is IN FLIGHT
    //    on dbg_walk_cycle, and the two are counted by their own counters, so a capture can read
    //    GC/GW as the mean walk. The stimulus drives the two INDEPENDENTLY - which the module
    //    never does - so a crossed wire or a shared counter shows up as the wrong number in the
    //    wrong field rather than as a plausible mean.
    gw_prev = gw; gc_prev = gc;
    idle; dbg_walk_start = 1'b1; cycle;
    idle; dbg_walk_start = 1'b1; cycle;
    idle; dbg_walk_cycle = 1'b1; cycle; cycle; cycle;
    sample;
    if (gw - gw_prev != 2 || gc - gc_prev != 3)
      $fatal(1, "2 walk starts and 3 walk cycles moved GW/GC by %0d/%0d, want 2/3",
             gw - gw_prev, gc - gc_prev);
    gw_prev = gw; gc_prev = gc;
    idle; sd1_valid = 1'b1; sd1_ready = 1'b1; cycle; idle;   // a font-port accept is not a walk
    sample;
    if (gw != gw_prev || gc != gc_prev)
      $fatal(1, "a font-port accept moved GW/GC by %0d/%0d: the walk counters are crossed with the port counters",
             gw - gw_prev, gc - gc_prev);
    gw_prev = gw; gc_prev = gc;
    dbg_walk_cycle = 1'b1; cycle; idle;
    sample;
    if (gw != gw_prev || gc - gc_prev != 1)
      $fatal(1, "one walk-cycle pulse moved GW/GC by %0d/%0d, want 0/1", gw - gw_prev, gc - gc_prev);

    // 8. The EGC/GRCG operation pulses: ET, EU and GS each count their own pulse and
    //    nothing else, so the record cannot report a cycles-per-transaction or cycles-per-unit
    //    figure the engines did not produce. The three are driven INDEPENDENTLY - which the EGC
    //    never does (a unit implies a transaction) - so a crossed wire shows up as the wrong number
    //    in the wrong field rather than as a plausible mean.
    et_prev = et; eu_prev = eu; gs_prev = gs;
    op_cycle(1'b1, 1'b0, 1'b0);
    op_cycle(1'b1, 1'b0, 1'b0);
    op_cycle(1'b0, 1'b1, 1'b0);
    op_cycle(1'b0, 1'b1, 1'b0);
    op_cycle(1'b0, 1'b1, 1'b0);
    op_cycle(1'b0, 1'b0, 1'b1);
    op_cycle(1'b0, 1'b0, 1'b1);
    op_cycle(1'b0, 1'b0, 1'b1);
    sample;
    if (et - et_prev != 2 || eu - eu_prev != 3 || gs - gs_prev != 3)
      $fatal(1, "2 EGC-transaction, 3 EGC-unit and 3 GRCG-store pulses moved ET/EU/GS by %0d/%0d/%0d, want 2/3/3",
             et - et_prev, eu - eu_prev, gs - gs_prev);
    et_prev = et; eu_prev = eu; gs_prev = gs;
    idle; dbg_walk_start = 1'b1; cycle; idle;
    sample;
    if (et != et_prev || eu != eu_prev || gs != gs_prev)
      $fatal(1, "a walk-start pulse moved ET/EU/GS by %0d/%0d/%0d: the operation counters are crossed with the walk",
             et - et_prev, eu - eu_prev, gs - gs_prev);
    et_prev = et; eu_prev = eu; gs_prev = gs;
    idle; sd2_valid = 1'b1; sd2_ready = 1'b1; cycle; idle;   // a PCM-port accept is not an EGC transaction
    sample;
    if (et != et_prev || eu != eu_prev || gs != gs_prev)
      $fatal(1, "a PCM-port accept moved ET/EU/GS by %0d/%0d/%0d: the operation counters are crossed with the port counters",
             et - et_prev, eu - eu_prev, gs - gs_prev);

    // 8.5 The other three SDRAM requester ports. S1/S2/S3 count ACCEPTS on exactly RD/WR's rule
    //     (one per valid/ready handshake), and W3 counts the scanout port's PRESENT-but-unaccepted
    //     cycles - the line fetch waiting for the bus. The properties: an unaccepted request
    //     counts nothing toward its accept, a wait on a DIFFERENT port does not move W3, and an
    //     accepted scanout request is not a wait.
    s1_prev = s1; s2_prev = s2; s3_prev = s3; w3_prev = w3;
    idle; sd1_valid = 1'b1; sd1_ready = 1'b1; cycle;          // font: accept 1
    sd1_ready = 1'b0; cycle; cycle;                           // present, not accepted: nothing
    sd1_ready = 1'b1; cycle;                                  // font: accept 2
    idle; sd2_valid = 1'b1; sd2_ready = 1'b1; cycle;          // PCM: accept 1
    idle; sd3_valid = 1'b1; sd3_ready = 1'b0; cycle; cycle; cycle;   // scanout waiting: W3 +3
    sd3_ready = 1'b1; cycle;                                  // scanout: accept 1
    sd3_ready = 1'b0; cycle;                                  // scanout waiting: W3 +1
    sd3_ready = 1'b1; cycle;                                  // scanout: accept 2
    idle;
    sample;
    if (s1 - s1_prev != 2)
      $fatal(1, "2 accepted font-port requests moved S1 by %0d, want 2", s1 - s1_prev);
    if (s2 - s2_prev != 1)
      $fatal(1, "1 accepted PCM-port request moved S2 by %0d, want 1", s2 - s2_prev);
    if (s3 - s3_prev != 2)
      $fatal(1, "2 accepted scanout-port requests moved S3 by %0d, want 2", s3 - s3_prev);
    if (w3 - w3_prev != 4)
      $fatal(1, "4 present-but-unaccepted scanout cycles moved W3 by %0d, want 4", w3 - w3_prev);
    w3_prev = w3; s3_prev = s3; s1_prev = s1;
    idle; sd1_valid = 1'b1; sd1_ready = 1'b0; cycle; cycle;   // FONT waiting: W3 must stay put
    idle;
    sd3_valid = 1'b1; sd3_ready = 1'b1; cycle; idle;          // an accept is not a wait either
    sample;
    if (w3 != w3_prev)
      $fatal(1, "2 unaccepted FONT-port cycles moved W3 by %0d: W3 is the scanout port's alone", w3 - w3_prev);
    if (s1 - s1_prev != 0)
      $fatal(1, "2 unaccepted FONT-port cycles moved S1 by %0d: only an accept counts", s1 - s1_prev);
    if (s3 - s3_prev != 1)
      $fatal(1, "an accepted scanout request moved S3 by %0d, want 1", s3 - s3_prev);

    // 9. The digits are the value's, most significant first, and leading zeros are PRINTED: the
    //    counters are free-running and read as deltas, so a dropped digit would silently shrink
    //    the interval a reader computes. The values here are the ones the stimulus above earned.
    if (mw != 32'd3 || rd != 32'd2 || wr != 32'd3)
      $fatal(1, "the record reads MW=%0d RD=%0d WR=%0d after 3 wait cycles, 2 accepted reads and 3 accepted writes",
             mw, rd, wr);
    if (gw != 32'd3 || gc != 32'd4)
      $fatal(1, "the record reads GW=%0d GC=%0d after 3 walk starts (one of them section 8 drives to show a walk is not an EGC operation) and 4 walk cycles",
             gw, gc);
    if (et != 32'd2 || eu != 32'd3 || gs != 32'd3)
      $fatal(1, "the record reads ET=%0d EU=%0d GS=%0d after 2 EGC transactions, 3 EGC units and 3 GRCG stores",
             et, eu, gs);
    // PD is EXEMPT from this loop: it is a GAUGE, and before section 11 drives it its value is a
    // frame position thousands of cycles in, so its leading digits are legitimately nonzero. Its
    // digits are checked in section 11, where the value is controlled. GV/EV/PC are still zero
    // here (no GRCG ownership pulse has been driven yet) and SP/AP read 0 because idle drives the
    // two page bits low, so every other field's leading zeros must be printed.
    for (f = 1; f < NFIELDS; f = f + 1)
      if (f != 11)
        for (i = 0; i < 7; i = i + 1)
          if (rec[DIG0 + f*12 + i] !== "0")
            $fatal(1, "field %0d's digit %0d is %c: leading zeros are not printed",
                   f, i, rec[DIG0 + f*12 + i]);
    if (rec[DIG0 + 1*STRIDE + 7] !== "3")
      $fatal(1, "MW's low digit is %c for %0d memory-wait cycles", rec[DIG0 + 1*STRIDE + 7], mw);
    if (rec[DIG0 + 2*STRIDE + 7] !== "2")
      $fatal(1, "RD's low digit is %c for %0d accepted reads", rec[DIG0 + 2*STRIDE + 7], rd);
    if (rec[DIG0 + 3*STRIDE + 7] !== "3")
      $fatal(1, "WR's low digit is %c for %0d accepted writes", rec[DIG0 + 3*STRIDE + 7], wr);
    if (rec[DIG0 + 4*STRIDE + 7] !== "3")
      $fatal(1, "GW's low digit is %c for %0d walk starts", rec[DIG0 + 4*STRIDE + 7], gw);
    if (rec[DIG0 + 5*STRIDE + 7] !== "4")
      $fatal(1, "GC's low digit is %c for %0d walk cycles", rec[DIG0 + 5*STRIDE + 7], gc);
    if (rec[DIG0 + 6*STRIDE + 7] !== "2")
      $fatal(1, "ET's low digit is %c for %0d EGC transactions", rec[DIG0 + 6*STRIDE + 7], et);
    if (rec[DIG0 + 7*STRIDE + 7] !== "3")
      $fatal(1, "EU's low digit is %c for %0d EGC units", rec[DIG0 + 7*STRIDE + 7], eu);
    if (rec[DIG0 + 8*STRIDE + 7] !== "3")
      $fatal(1, "GS's low digit is %c for %0d GRCG stores", rec[DIG0 + 8*STRIDE + 7], gs);

    // 10. Past the record the formatter answers NUL, which is the arm the watchdog's own case has.
    //     The first two indices past the record (REC_LEN and REC_LEN + 1).
    idx = REC_LEN;     #1; if (ch !== 8'h00) $fatal(1, "idx %0d answered %02x, not NUL", REC_LEN, ch);
    idx = REC_LEN + 1; #1; if (ch !== 8'h00) $fatal(1, "idx %0d answered %02x, not NUL", REC_LEN + 1, ch);

    // 11. The visible-region pair and the pass gauge (report section 5.1.2). GV/EV count a
    //     graphics-owned cycle ONLY while v_active is high - a store the beam can catch - and the
    //     GATE is the property: the SAME ownership pulse with v_active low must count nowhere, or
    //     the record would report blanking-time work as visible spill. PD is the GAUGE: it restarts
    //     at the vblank edge and holds the LAST store's position in the frame, so it is a per-frame
    //     wall-clock and not a running total. This is the LAST section on purpose - it spends one
    //     more GRCG store, so section 9's exact operation counts are already asserted. NB the two
    //     GRCG-owned cycles driven in BLANKING below still move PC: PC is NOT gated by
    //     v_active, and idle holds both page bits at 0, so they are EQUAL. PC is checked in section
    //     12, which counts them as part of its own baseline.
    gv_prev = gv; ev_prev = ev; gs_prev = gs;
    idle; v_active = 1'b1; dbg_gr_owned = 1'b1; cycle; cycle; cycle; idle;   // 3 VISIBLE GRCG cycles
    idle; v_active = 1'b1; dbg_eg_owned = 1'b1; cycle; cycle;       idle;   // 2 VISIBLE EGC cycles
    idle;                  dbg_gr_owned = 1'b1; cycle; cycle;       idle;   // in blanking: nowhere
    idle;                  dbg_eg_owned = 1'b1; cycle;              idle;
    sample;
    if (gv - gv_prev != 3)
      $fatal(1, "3 GRCG-owned cycles with v_active added %0d to GV, want 3", gv - gv_prev);
    if (ev - ev_prev != 2)
      $fatal(1, "2 EGC-owned cycles with v_active added %0d to EV, want 2", ev - ev_prev);
    gv_prev = gv; ev_prev = ev;
    idle; v_active = 1'b1; dbg_grcg_store = 1'b1; cycle; idle;
    sample;
    if (gv != gv_prev || ev != ev_prev)
      $fatal(1, "a GRCG STORE pulse with the ownership line low moved GV/EV by %0d/%0d: the fields are crossed",
             gv - gv_prev, ev - ev_prev);
    // PD: the vblank edge restarts the count, the last store latches it.
    idle; vsync_edge = 1'b1; cycle; idle;
    repeat (5) cycle;
    idle; dbg_grcg_store = 1'b1; cycle; idle;
    sample;
    if (pd != 32'd5)
      $fatal(1, "PD reads %0d after one vblank edge, 5 idle cycles and one GRCG store, want 5", pd);
    if (gs - gs_prev != 2)
      $fatal(1, "the two GRCG-store pulses above moved GS by %0d, want 2", gs - gs_prev);
    // A store IN the edge's own cycle belongs to the NEW frame and reads 0, not the whole previous
    // frame's pass - the guard that keeps the first store after a wrap from reporting 886,160.
    idle; vsync_edge = 1'b1; dbg_grcg_store = 1'b1; cycle; idle;
    sample;
    if (pd != 32'd0)
      $fatal(1, "a GRCG store IN the vblank-edge cycle left PD at %0d, want 0", pd);
    // The new fields' digits, at a point where the values are known and small (the exemption in
    // section 9 covers PD; GV/EV/PC and the SP/AP statuses are checked here too so their digits are
    // covered on their own values rather than on the zeros they held earlier). PC is 5 here - the 3
    // visible and 2 blanking GRCG-owned cycles above, both with the pages EQUAL (idle holds both
    // page bits at 0) - so its leading digits are zero and its low digit is 5.
    for (f = 9; f < NFIELDS; f = f + 1)
      for (i = 0; i < 7; i = i + 1)
        if (rec[DIG0 + f*12 + i] !== "0")
          $fatal(1, "field %0d's digit %0d is %c: leading zeros are not printed",
                 f, i, rec[DIG0 + f*12 + i]);
    if (rec[DIG0 + 9*STRIDE + 7] !== "3")
      $fatal(1, "GV's low digit is %c for %0d visible GRCG cycles", rec[DIG0 + 9*STRIDE + 7], gv);
    if (rec[DIG0 + 10*STRIDE + 7] !== "2")
      $fatal(1, "EV's low digit is %c for %0d visible EGC cycles", rec[DIG0 + 10*STRIDE + 7], ev);
    if (rec[DIG0 + 11*STRIDE + 7] !== "0")
      $fatal(1, "PD's low digit is %c for a gauge of %0d", rec[DIG0 + 11*STRIDE + 7], pd);
    // PC is 8 here, and the decomposition is the check: section 11 drove 3 visible GRCG cycles
    // + 2 GRCG cycles in BLANKING (PC is not v_active-gated - the scan page is a level, and the
    // old form never gated it either) + 2 visible EGC + 1 blanking EGC. All 8 have both
    // page bits 0 (EQUAL). BEFORE the 2026-10-03 widening this read 5: the EGC's 3 counted
    // nowhere, which is the blindness the change removes.
    if (rec[DIG0 + 12*STRIDE + 7] !== "8")
      $fatal(1, "PC's low digit is %c for %0d page-coincident cycles", rec[DIG0 + 12*STRIDE + 7], pc);

    // 12. The page-coincidence probe: PC counts a clk_sys the GRCG OWNS the array
    //     (the same ownership pulse GV counts) AND the access page EQUALS the page the scanout's
    //     line fetch is latched on - the leak's own signature, since correct double-buffering keeps
    //     the two pages OPPOSITE. SP/AP are the two page LEVELS, read LIVE into the record. The
    //     EQUALITY is the property: the SAME ownership pulse with the pages opposite must count
    //     nowhere, or the field would flag every store as a leak, and a coincidence with NO store in
    //     flight must count nowhere either.
    pc_prev = pc;
    idle; dbg_gr_owned = 1'b1; dbg_access_page = 1'b0; dbg_scan_page_q = 1'b0; cycle; idle;  // equal
    idle; dbg_gr_owned = 1'b1; dbg_access_page = 1'b1; dbg_scan_page_q = 1'b1; cycle; idle;  // equal
    idle; dbg_gr_owned = 1'b1; dbg_access_page = 1'b0; dbg_scan_page_q = 1'b1; cycle; idle;  // OPPOSITE
    idle; dbg_gr_owned = 1'b1; dbg_access_page = 1'b1; dbg_scan_page_q = 1'b0; cycle; idle;  // OPPOSITE
    sample;
    if (pc - pc_prev != 2)
      $fatal(1, "2 page-coincident GRCG-store cycles moved PC by %0d, want 2 (the OPPOSITE pair must count nothing)", pc - pc_prev);
    pc_prev = pc;
    idle; dbg_gr_owned = 1'b0; dbg_access_page = 1'b1; dbg_scan_page_q = 1'b1; cycle; idle;
    sample;
    if (pc != pc_prev)
      $fatal(1, "a page coincidence with NO GRCG store in flight moved PC by %0d: PC is the store-in-flight AND the equality", pc - pc_prev);
    // ...AND THE PLAIN CLIENT'S ARM, which is the whole reason this counter was widened
    // (2026-10-03): Farland Story's page-to-page copies are PLAIN plane-window stores, so a
    // GRCG-only probe reads 0 through the very leak it was read for. The EQUALITY is still the
    // property - the same plain-write ownership with the pages OPPOSITE must count nowhere.
    pc_prev = pc;
    idle; dbg_pw_owned = 1'b1; dbg_access_page = 1'b0; dbg_scan_page_q = 1'b0; cycle; idle;  // equal
    idle; dbg_pw_owned = 1'b1; dbg_access_page = 1'b1; dbg_scan_page_q = 1'b0; cycle; idle;  // OPPOSITE
    sample;
    if (pc - pc_prev != 1)
      $fatal(1, "1 page-coincident PLAIN-window store cycle moved PC by %0d, want 1 (the OPPOSITE arm must count nothing)", pc - pc_prev);
    // ...and the EGC's arm, in the union for the same reason: a leak through an EGC-driven
    // redraw is a leak too.
    pc_prev = pc;
    idle; dbg_eg_owned = 1'b1; dbg_access_page = 1'b1; dbg_scan_page_q = 1'b1; cycle; idle;  // equal
    sample;
    if (pc - pc_prev != 1)
      $fatal(1, "1 page-coincident EGC-owned cycle moved PC by %0d, want 1", pc - pc_prev);
    // ...and a coincidence with NO write owner at all is not a store in flight. A READ walks
    // the array too (the plain client's read arm, a TCR read) and writes nothing, so the
    // counter is the union of the three WRITE owners and not of every walk.
    pc_prev = pc;
    idle; dbg_access_page = 1'b0; dbg_scan_page_q = 1'b0; cycle; idle;
    sample;
    if (pc != pc_prev)
      $fatal(1, "a page coincidence with NO write owner in flight moved PC by %0d", pc - pc_prev);
    // SP/AP are LIVE levels, not counters, so the read must HOLD the page bits: idling first (as
    // sample does) drives both to 0 and a wire that never reports the page at all would pass.
    idle; dbg_access_page = 1'b1; dbg_scan_page_q = 1'b0;
    read_field(sp, 13); read_field(ap, 14);
    if (sp !== 32'd0)
      $fatal(1, "SP reads %0d for a scanout page of 0", sp);
    if (ap !== 32'd1)
      $fatal(1, "AP reads %0d for an access page of 1", ap);
    idle; dbg_access_page = 1'b0; dbg_scan_page_q = 1'b1;
    read_field(sp, 13); read_field(ap, 14);
    if (sp !== 32'd1)
      $fatal(1, "SP reads %0d for a scanout page of 1", sp);
    if (ap !== 32'd0)
      $fatal(1, "AP reads %0d for an access page of 0", ap);
    sample;
    // 12.5 The CPU's LAST page fault (PF/PA). These are LIVE statuses - the core's own latches,
    //      not counters - so the read must report whatever the core is driving, and the two
    //      fields must be the code and the address rather than crossed. Driven here, after the
    //      leading-zero loops above, so their zeros were checked before and their values now.
    pf_code = 3'd6;                       // present=0, write=1, user=1
    pf_addr = 32'hDEAD_BEEF;
    sample;
    if (pf !== 32'd6)
      $fatal(1, "PF reads %0d for a page-fault code of 6", pf);
    if (pa !== 32'hDEAD_BEEF)
      $fatal(1, "PA reads %08x for a faulting linear address of DEADBEEF", pa);
    pf_code = 3'd0; pf_addr = 32'd0;
    sample;
    // PC is 12 now: the 8 section 11 left (both page bits 0, EQUAL - 5 GRCG cycles + 3 EGC), the
    // 2 GRCG-store cycles above, and the 2 added arms (one plain-window store and one EGC-owned
    // cycle, each at equality). Its low digit is therefore C - the record's digits are HEX.
    if (pc != 32'd12)
      $fatal(1, "PC reads %0d after the page-coincidence stimulus, want 12", pc);
    if (rec[DIG0 + 12*STRIDE + 7] !== "C")
      $fatal(1, "PC's low digit is %c for %0d page-coincident cycles", rec[DIG0 + 12*STRIDE + 7], pc);

    // 13. THE SNAPSHOT (the telemetry tear fix): a record's digits are the counters' values at
    //     the report's accept, HELD while the record is read. Eight live reads of a free-running
    //     counter sample eight different times, and a carry crossing between two of them splices
    //     two values into one torn field (a telemetry tear). Snapshot once,
    //     move the stimulus, re-read with no new snapshot: every byte must reprint unchanged -
    //     on a formatter that reads live this fails deterministically (CY alone has moved past
    //     the snapshotted digits). A NEW snapshot then takes the new counters exactly.
    sample;
    for (i = 0; i < REC_LEN; i = i + 1) rec_hold[i] = rec[i];
    mw_prev = mw; gc_prev = gc; cy_prev = cy;
    wait_cpu(1'b1, 1'b0);
    cycle; cycle; cycle;               // 3 memory-wait cycles move MW
    idle; dbg_walk_cycle = 1'b1;
    cycle; cycle;                      // 2 walk cycles move GC, CY moves regardless
    idle;                              // SP/AP stay LIVE by contract: hold the pages for the compare
    read_rec;
    for (i = 0; i < REC_LEN; i = i + 1)
      if (rec[i] !== rec_hold[i])
        $fatal(1, "record byte %0d moved under the snapshot: %02x -> %02x (the digits must be the report's accept instant)",
               i, rec_hold[i], rec[i]);
    sample;                            // a NEW snapshot takes the new counters
    if (mw - mw_prev != 3)
      $fatal(1, "the new snapshot read MW moved by %0d over 3 wait cycles, want 3", mw - mw_prev);
    if (gc - gc_prev != 2)
      $fatal(1, "the new snapshot read GC moved by %0d over 2 walk cycles, want 2", gc - gc_prev);
    if (cy - cy_prev < 5)
      $fatal(1, "CY advanced by only %0d under the snapshot: the counter itself advances every clk_sys", cy - cy_prev);

    sample;
    $display("PERF-RECORD bytes=%0d cy=%0d mw=%0d rd=%0d wr=%0d gw=%0d gc=%0d et=%0d eu=%0d gs=%0d gv=%0d ev=%0d pd=%0d pc=%0d sp=%0d ap=%0d s1=%0d s2=%0d s3=%0d w3=%0d pf=%0d pa=%08x",
             REC_LEN, cy, mw, rd, wr, gw, gc, et, eu, gs, gv, ev, pd, pc, sp, ap, s1, s2, s3, w3, pf, pa);
    // ==== VERDICT ====
    $display("TB_PC9821_PERF_MSG: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #1_000_000;
    $fatal(1, "the perf-record bench did not finish in 1 ms of simulated time");
  end

endmodule
