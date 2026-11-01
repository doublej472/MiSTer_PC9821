`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_MSG:
// The graphics telemetry record reports what its eight inputs mean and is one line: the four GVRAM path counters (the GRCG RMW walk, the GRCG TDW walk, the EGC, and the plain plane-window write) print the values pc9821_gvram computed, the DEVICE wait counts exactly the cycles an I/O request was outstanding and unaccepted and NOT a memory request, the frame and interrupt counters advance one per pulse, and the JIS row-cache walker's skipped-walk counter is printed as the value pc9821_gdc_text produced (it is a passthrough here, like the GVRAM counters) - all driven cycle by cycle and read back out of the record, so it cannot claim a split the handshake does not support. The record is also a SNAPSHOT: its digits are the fields' values at the report's accept (snap), held while the record is read, so moving every input after the snapshot and re-reading reprints the same bytes and a paced emission can never splice two counter values into one field (a telemetry tear); a NEW snapshot takes the new values.
//
// WHY THE COUNTERS ARE CHECKED HERE AND NOT ONLY THE BYTES. The record's whole claim is "this
// interval spent N cycles in the GRCG RMW walk, M waiting on a device, and F frames passed"; every
// part of that is arithmetic on an edge. A byte-level golden would pass with the wrong edge (an
// accepted request counted, a memory request counted as a device wait, a held level counted once
// instead of per cycle), so the bench drives each shape and asserts the delta it must produce.
//
// It also asserts the newline shape the decoder requires: exactly one 0x0A, as the last byte, and no
// 0x0D anywhere - a CR comes back as a second newline through a tty's ICRNL, which is the blank
// line between records the record was rewritten to remove.

module tb_pc9821_gfx_msg;

  // ==== DUT ====

  reg        clk, reset;
  reg  [31:0] gvram_gr, gvram_gt, gvram_eg, gvram_pw;
  reg        cpu_req, cpu_ack, cpu_io;
  reg        vsync, irq;
  reg  [15:0] wk_skips;
  reg  [6:0] idx;
  reg        snap;
  wire [7:0] ch;

  pc9821_gfx_msg dut (
    .clk(clk), .reset(reset),
    .gvram_gr(gvram_gr), .gvram_gt(gvram_gt), .gvram_eg(gvram_eg), .gvram_pw(gvram_pw),
    .cpu_req(cpu_req), .cpu_ack(cpu_ack), .cpu_io(cpu_io),
    .vsync(vsync), .irq(irq),
    .wk_skips(wk_skips),
    .snap(snap),
    .idx(idx), .ch(ch)
  );

  // The record's map, which is also what tools/decode_telemetry.py parses: "GFX", then eight
  // 12-byte fields (space, 2-char label, '=', 8 hex digits), then one LF. 100 bytes.
  localparam [6:0] REC_LEN  = 7'd100;
  localparam [6:0] GR_DIG0  = 7'd7;
  localparam [6:0] GT_DIG0  = 7'd19;
  localparam [6:0] EG_DIG0  = 7'd31;
  localparam [6:0] PW_DIG0  = 7'd43;
  localparam [6:0] DW_DIG0  = 7'd55;
  localparam [6:0] FR_DIG0  = 7'd67;
  localparam [6:0] IR_DIG0  = 7'd79;
  localparam [6:0] WK_DIG0  = 7'd91;
  localparam [6:0] REC_LF   = 7'd99;

  reg [7:0] rec [0:99];
  reg [7:0] rec_hold [0:99];
  integer i;
  integer k;
  reg [31:0] gr, gt, eg, pw, dw, fr, ir, wk;
  reg [31:0] dw_prev, fr_prev, ir_prev;

  always #5 clk = ~clk;

  task automatic read_rec; begin
    for (i = 0; i < 100; i = i + 1) begin
      idx = i[6:0];
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

  // One clk_sys: the handshakes are combinational inputs sampled on the edge, so a cycle of
  // stimulus is set up and then one edge is taken.
  task automatic cycle; begin
    @(posedge clk);
    #1;
  end endtask

  // IDLE BEFORE READING. read_rec takes 100 ns of simulated time, during which the clock keeps
  // running: a request or a pulse left asserted would be counted while the bench is reading the
  // record, and the delta it then checks would be the reading's own cost rather than the stimulus.
  task automatic idle; begin
    cpu_req = 1'b0; cpu_ack = 1'b0; cpu_io = 1'b0;
    vsync = 1'b0; irq = 1'b0;
  end endtask

  // A request shape: outstanding, accepted or not, and I/O or memory.
  task automatic req(input valid, input ack, input io); begin
    vsync = 1'b0; irq = 1'b0;
    cpu_req = valid; cpu_ack = ack; cpu_io = io;
  end endtask

  task automatic sample; begin
    idle;
    snap = 1'b1; cycle; snap = 1'b0;   // the record's SNAPSHOT: one pulse at its accept
    read_rec;
    gr = rec_val(GR_DIG0);
    gt = rec_val(GT_DIG0);
    eg = rec_val(EG_DIG0);
    pw = rec_val(PW_DIG0);
    dw = rec_val(DW_DIG0);
    fr = rec_val(FR_DIG0);
    ir = rec_val(IR_DIG0);
    wk = rec_val(WK_DIG0);
  end endtask

  // ==== CHECKS ====
  initial begin
    clk = 1'b0; reset = 1'b1;
    snap = 1'b0;
    gvram_gr = 32'h1234_5678; gvram_gt = 32'h0BAD_F00D;
    gvram_eg = 32'h00C0_FFEE; gvram_pw = 32'h0000_0007;
    wk_skips = 16'h0000;
    idle;
    idx = 7'd0;
    cycle; cycle;
    reset = 1'b0;
    cycle;

    // 1. The record's shape: prefix, labels in order, the separators, one LF at the end, no CR.
    read_rec;
    if ({rec[0], rec[1], rec[2]} !== "GFX")
      $fatal(1, "the record does not start GFX: %c%c%c", rec[0], rec[1], rec[2]);
    if ({rec[4], rec[5]} !== "GR" || {rec[16], rec[17]} !== "GT" || {rec[28], rec[29]} !== "EG" ||
        {rec[40], rec[41]} !== "PW" || {rec[52], rec[53]} !== "DW" || {rec[64], rec[65]} !== "FR" ||
        {rec[76], rec[77]} !== "IR" || {rec[88], rec[89]} !== "WK")
      $fatal(1, "the field labels are %c%c/%c%c/%c%c/%c%c/%c%c/%c%c/%c%c/%c%c, not GR/GT/EG/PW/DW/FR/IR/WK",
             rec[4], rec[5], rec[16], rec[17], rec[28], rec[29], rec[40], rec[41],
             rec[52], rec[53], rec[64], rec[65], rec[76], rec[77], rec[88], rec[89]);
    for (i = 0; i < 8; i = i + 1) begin
      if (rec[3 + 12*i] !== " ")
        $fatal(1, "field %0d is not delimited by a space at its start (byte %0d = %c)", i, 3 + 12*i, rec[3 + 12*i]);
      if (rec[6 + 12*i] !== "=")
        $fatal(1, "field %0d's label is not followed by '=' (byte %0d = %c)", i, 6 + 12*i, rec[6 + 12*i]);
    end
    for (i = 0; i < 100; i = i + 1) begin
      if ((i == REC_LF) ? (rec[i] !== 8'h0A) : (rec[i] == 8'h0A))
        $fatal(1, "byte %0d of the record is %02x: the record is ONE line and its only LF is the last byte",
               i, rec[i]);
      if (rec[i] == 8'h0D)
        $fatal(1, "byte %0d of the record is a CR: a tty's ICRNL turns it into a second newline, which is the blank line between records this record removed", i);
    end
    for (i = 0; i < 8; i = i + 1) begin
      for (k = 0; k < 8; k = k + 1) begin
        if (!((rec[7 + 12*i + k] >= "0" && rec[7 + 12*i + k] <= "9") ||
              (rec[7 + 12*i + k] >= "A" && rec[7 + 12*i + k] <= "F")))
          $fatal(1, "field %0d digit %0d is %c, not a hex digit", i, k, rec[7 + 12*i + k]);
      end
    end

    // 2. The four GVRAM path counters are printed as the values pc9821_gvram computed. They are
    //    INPUTS here, so this is the record's passthrough, not counter arithmetic.
    sample;
    if (gr !== 32'h1234_5678 || gt !== 32'h0BAD_F00D || eg !== 32'h00C0_FFEE || pw !== 32'h0000_0007)
      $fatal(1, "the GVRAM fields read GR=%08x GT=%08x EG=%08x PW=%08x, not the driven values",
             gr, gt, eg, pw);
    if (dw !== 0 || fr !== 0 || ir !== 0 || wk !== 0)
      $fatal(1, "the counters start at DW=%0d FR=%0d IR=%0d WK=%0d, not all zero", dw, fr, ir, wk);

    // 3. The DEVICE wait counts a cycle with an I/O request OUTSTANDING AND NOT ACCEPTED, and only
    //    that: an accepted I/O request is not waiting, and a memory request is not a device wait.
    dw_prev = dw;
    req(1'b1, 1'b0, 1'b1);
    cycle; cycle; cycle;
    sample;
    if (dw - dw_prev != 3)
      $fatal(1, "3 cycles of an unaccepted I/O request moved DW by %0d, not 3", dw - dw_prev);
    dw_prev = dw;
    req(1'b1, 1'b1, 1'b1);              // accepted: it completes, so it is not a wait
    cycle; cycle;
    sample;
    if (dw != dw_prev)
      $fatal(1, "an ACCEPTED I/O request added %0d to DW: completion is not waiting", dw - dw_prev);
    dw_prev = dw;
    req(1'b1, 1'b0, 1'b0);              // outstanding and unaccepted, but MEMORY not I/O
    cycle; cycle;
    sample;
    if (dw != dw_prev)
      $fatal(1, "an unaccepted MEMORY request added %0d to DW: DW is the I/O subset only", dw - dw_prev);

    // 4. FR and IR advance one per PULSE, and a pulse is one clk_sys wide - the contract the
    //    emitters meet (a vsync edge gated by the pixel enable, and an INTA edge).
    fr_prev = fr; ir_prev = ir;
    cpu_req = 1'b0; cpu_ack = 1'b0; cpu_io = 1'b0;
    vsync = 1'b1; irq = 1'b1;
    cycle; cycle;                       // two one-cycle pulses each
    sample;
    if (fr - fr_prev != 2)
      $fatal(1, "2 vsync pulses moved FR by %0d, not 2", fr - fr_prev);
    if (ir - ir_prev != 2)
      $fatal(1, "2 interrupt pulses moved IR by %0d, not 2", ir - ir_prev);

    // 5. The digits are the value's, most significant first, and leading zeros are PRINTED: the
    //    counters are free-running and read as deltas, so a dropped digit would silently shrink
    //    the interval a reader computes.
    if (dw != 32'd3 || fr != 32'd2 || ir != 32'd2)
      $fatal(1, "the record reads DW=%0d FR=%0d IR=%0d after 3 device-wait cycles and 2+2 pulses",
             dw, fr, ir);
    for (i = 0; i < 7; i = i + 1)
      if (rec[DW_DIG0 + i] !== "0")
        $fatal(1, "DW digit %0d is %c for a value of %0d: leading zeros are not printed",
               i, rec[DW_DIG0 + i], dw);
    if (rec[DW_DIG0 + 7] !== "3")
      $fatal(1, "DW's low digit is %c for %0d device-wait cycles", rec[DW_DIG0 + 7], dw);
    if (rec[FR_DIG0 + 7] !== "2")
      $fatal(1, "FR's low digit is %c for %0d frames", rec[FR_DIG0 + 7], fr);
    if (rec[IR_DIG0 + 7] !== "2")
      $fatal(1, "IR's low digit is %c for %0d interrupts", rec[IR_DIG0 + 7], ir);
    if (rec[GR_DIG0] !== "1" || rec[GR_DIG0 + 1] !== "2")
      $fatal(1, "GR's top two digits are %c%c for 0x12345678", rec[GR_DIG0], rec[GR_DIG0 + 1]);

    // 5b. WK is a passthrough, like the GVRAM counters: the record prints the walker's own
    //     saturating skip count. Driven to 0x0012, it must read back as such, with the top six
    //     digits zero (the counter is 16 bits, so the field is zero-extended).
    wk_skips = 16'h0012;
    sample;
    if (wk !== 32'h0000_0012)
      $fatal(1, "WK read %08x for a driven skip count of 0x0012", wk);
    for (i = 0; i < 6; i = i + 1)
      if (rec[WK_DIG0 + i] !== "0")
        $fatal(1, "WK digit %0d is %c for a 16-bit value of 0x%04x: the field is not zero-extended",
               i, rec[WK_DIG0 + i], wk_skips);
    wk_skips = 16'h0000;

    // 6. Past the record the formatter answers NUL, which is the arm the watchdog's own case has.
    idx = REC_LEN;     #1; if (ch !== 8'h00) $fatal(1, "idx 100 answered %02x, not NUL", ch);
    idx = 7'd127;      #1; if (ch !== 8'h00) $fatal(1, "idx 127 answered %02x, not NUL", ch);

    // 7. THE SNAPSHOT: a record's digits are the fields' values at the report's accept, HELD
    //    while the record is read. Eight live reads of a free-running counter sample eight
    //    different times, and a carry crossing between two of them splices two values into one
    //    torn field (the telemetry tear - this record is the report's paced
    //    TAIL, so every digit byte lands ~87 us apart in a real capture). Snapshot once, move
    //    EVERY input, re-read with no new snapshot: every byte must reprint unchanged. On a
    //    formatter that reads live this fails deterministically (the digits follow the inputs);
    //    a NEW snapshot must then take the new values.
    sample;
    for (i = 0; i < 100; i = i + 1) rec_hold[i] = rec[i];
    gvram_gr = 32'hDEAD_BEEF; gvram_gt = 32'h4321_1234;
    gvram_eg = 32'h8000_0001; gvram_pw = 32'hFFFF_FFF8;
    wk_skips = 16'hBEEF;
    req(1'b1, 1'b0, 1'b1);          // DW free-runs while the held record is re-read
    repeat (4) cycle;
    read_rec;
    for (i = 0; i < 100; i = i + 1)
      if (rec[i] !== rec_hold[i])
        $fatal(1, "record byte %0d moved under the snapshot: %02x -> %02x (the digits must be the report's accept instant)",
               i, rec_hold[i], rec[i]);
    idle;
    sample;                         // a NEW snapshot takes the new inputs
    if (gr !== 32'hDEAD_BEEF || gt !== 32'h4321_1234 || eg !== 32'h8000_0001 ||
        pw !== 32'hFFFF_FFF8 || wk !== 32'h0000_BEEF)
      $fatal(1, "a new snapshot did not take the new inputs: GR=%08x GT=%08x EG=%08x PW=%08x WK=%08x",
             gr, gt, eg, pw, wk);

    $display("GFX-RECORD bytes=100 GR=%08x GT=%08x EG=%08x PW=%08x dw_delta=3 fr_delta=2 ir_delta=2 wk=0x0012 snapshot=held",
             gr, gt, eg, pw);
    // ==== VERDICT ====
    $display("TB_PC9821_GFX_MSG: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #1_000_000;
    $fatal(1, "the graphics-record bench did not finish in 1 ms of simulated time");
  end

endmodule
