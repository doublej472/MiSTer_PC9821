`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_WATCHDOG:
// The stall-watchdog telemetry record is a function of the diagnostic fields and nothing else: all 351 bytes are compared against a golden capture of this formatter, and the 137 bytes that carry fields are shown to move with them. The record is also shown to be ONE line - exactly one LF, as its last byte, and no CR anywhere, because a CR arrives as a second newline through a tty and that is the blank line between records that was removed. The record is also a SNAPSHOT: its bytes are the fields' values at the report's accept (snap), held while the record is read, so setting the fields again without a new snapshot reprints the old bytes and a paced emission can never splice two counter values into one field (a telemetry tear); a NEW snapshot takes the new values.
//
// TWO PROPERTIES ARE THE POINT OF THE REWRITE AND ARE ASSERTED DIRECTLY. The record is
// ONE line: exactly one 0x0A, as its LAST byte, and NO 0x0D anywhere. The old record was four lines
// ended CR LF, and a serial tty's ICRNL maps CR to LF on the way into a capture, so every one of
// those pairs landed in a capture log as TWO newlines - the blank line between records. A byte
// that moved back to a CR would restore the bug while every field still matched, so the newline
// shape is checked rather than assumed.
//
// The fixture is this record byte for byte, with the field values chosen so every field byte is a
// distinct non-zero nibble: the field bytes then cannot coincide with the literal text, which is
// what makes the 137/214 split checkable. tools/decode_telemetry.py decodes this record by character
// index; the fields and their order are its contract, and
// tools/check_telemetry_contract.py holds the widths to it.

module tb_pc9821_watchdog;

  // ==== DUT ====
  reg  [15:0] idx;                   // 0..350 is the live range
  reg  [15:0] cpu_cs;
  reg  [31:0] cpu_eip;
  reg  [ 7:0] io_debug_status;
  reg  [ 0:0] triple_fault_reset;
  reg  [ 0:0] hdd_mounted;
  reg  [31:0] hdd_capacity;
  reg  [ 0:0] gdc_disp;
  reg  [ 7:0] vid_frame_cnt;
  reg  [ 7:0] hdd_req_cnt;
  reg  [ 7:0] hdd_err_cnt;
  reg  [ 0:0] hdd_busy;
  reg  [31:0] hdd_hps_cycles;   // HP
  reg  [ 0:0] vid_lit_seen;
  reg  [ 7:0] vid_lit_cnt;
  reg  [ 7:0] ata_dbg_state;
  reg  [31:0] ata_dbg_cmd;
  reg  [ 3:0] io_dbg_gate;
  reg  [ 0:0] mounted_at_run;
  reg  [15:0] gdc_dbg_sad;
  reg  [ 7:0] gdc_dbg_pitch;
  reg  [ 0:0] gdc_dbg_col40;
  reg  [ 0:0] gdc_dbg_disp;
  reg  [ 7:0] kbd_dbg_events;
  reg  [ 7:0] kbd_dbg_delivered;
  reg  [ 7:0] kbd_dbg_rd_data;
  reg  [ 7:0] kbd_dbg_wr_ctrl;
  reg  [ 0:0] kbd_dbg_rts;
  reg  [ 0:0] kbd_dbg_rx_en;
  reg  [ 0:0] kbd_irq;
  reg  [ 7:0] kbd_dbg_last_del;
  reg  [ 7:0] kbd_dbg_ctrl0;
  reg  [ 7:0] kbd_dbg_ctrl1;
  reg  [ 7:0] irq_dbg_imr;
  reg  [ 7:0] irq_dbg_irr;
  reg  [ 7:0] irq_dbg_isr;
  reg  [ 7:0] inta_din;
  reg  [ 7:0] cpu_irq_state;
  reg  [ 7:0] inta_count;
  reg  [15:0] artic_hi;   // U: the ARTIC counter's upper half
  reg  [ 7:0] io_itf_stage;
  reg  [15:0] last_io_addr;   // IO: the most recent I/O access
  reg  [ 7:0] last_io_data;   // IV: its data byte
  reg         last_io_rd;
  reg         last_io_wr;
  reg  [7:0]  fdc_dbg_state;   // FST: {IRQ, DRQ, st, x_st}
  reg  [7:0]  fdc_dbg_cmd;     // FCM: {MT, opcode}
  reg [31:0]  fdc_dbg_result;  // FRS: {res0, res1, res2, exec_st0}
  reg [31:0]  fdc_dbg_chrn;    // FCH: {C, H, R, N}
  reg [31:0]  ata_dbg_lba;     // ALB: the transfer LBA
  reg [15:0]  ata_dbg_sec;     // ASE: {sector_count, error_reg}
  wire [7:0]  ch;

  // The snapshot's clock: the record latches the fields on `snap`, one pulse at its accept.
  reg        clk = 0;
  reg        snap = 0;
  always #5 clk = ~clk;

  pc9821_watchdog_msg dut (.*);

  // The record for the field vector in <fields_a> below:
  //   W CS=A123 EIP=456789AB ST=CD TF=1 D=1 C=EF123456 V=1 F=67 R=89 E=AB B=1 P=1 N=CD A=EF
  //     ATA=12345678 G=A M=1 SAD=1234 PIT=56 C40=1 DSP=1 PS2=78 DLV=9A RD41=BC WR43=DE RTS=1
  //     RXE=1 IRQ=1 LSC=F1 C0=23 C1=45 IMR=67 IRR=89 ISR=AB VEC=CD CPU=EF INTA=12 U=3456
  //     IO=ABCD DR=1 IV=EF HP=9ABCDEF1 FST=BC FCM=DE FRS=ABCDEF12 FCH=3456789A ALB=BCDEF123
  //     ASE=4567 T=78 ? LF
  // Index 349 is '?', the formatter's own byte: pc9821_dbg_record.sv substitutes the trigger letter
  // there, and this bench drives the formatter alone, so '?' is what this module must produce.
  localparam [2807:0] GOLDEN_MSG = {
      8'h57, 8'h20, 8'h43, 8'h53, 8'h3D, 8'h41, 8'h31, 8'h32,
      8'h33, 8'h20, 8'h45, 8'h49, 8'h50, 8'h3D, 8'h34, 8'h35,
      8'h36, 8'h37, 8'h38, 8'h39, 8'h41, 8'h42, 8'h20, 8'h53,
      8'h54, 8'h3D, 8'h43, 8'h44, 8'h20, 8'h54, 8'h46, 8'h3D,
      8'h31, 8'h20, 8'h44, 8'h3D, 8'h31, 8'h20, 8'h43, 8'h3D,
      8'h45, 8'h46, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36,
      8'h20, 8'h56, 8'h3D, 8'h31, 8'h20, 8'h46, 8'h3D, 8'h36,
      8'h37, 8'h20, 8'h52, 8'h3D, 8'h38, 8'h39, 8'h20, 8'h45,
      8'h3D, 8'h41, 8'h42, 8'h20, 8'h42, 8'h3D, 8'h31, 8'h20,
      8'h50, 8'h3D, 8'h31, 8'h20, 8'h4E, 8'h3D, 8'h43, 8'h44,
      8'h20, 8'h41, 8'h3D, 8'h45, 8'h46, 8'h20, 8'h41, 8'h54,
      8'h41, 8'h3D, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36,
      8'h37, 8'h38, 8'h20, 8'h47, 8'h3D, 8'h41, 8'h20, 8'h4D,
      8'h3D, 8'h31, 8'h20, 8'h53, 8'h41, 8'h44, 8'h3D, 8'h31,
      8'h32, 8'h33, 8'h34, 8'h20, 8'h50, 8'h49, 8'h54, 8'h3D,
      8'h35, 8'h36, 8'h20, 8'h43, 8'h34, 8'h30, 8'h3D, 8'h31,
      8'h20, 8'h44, 8'h53, 8'h50, 8'h3D, 8'h31, 8'h20, 8'h50,
      8'h53, 8'h32, 8'h3D, 8'h37, 8'h38, 8'h20, 8'h44, 8'h4C,
      8'h56, 8'h3D, 8'h39, 8'h41, 8'h20, 8'h52, 8'h44, 8'h34,
      8'h31, 8'h3D, 8'h42, 8'h43, 8'h20, 8'h57, 8'h52, 8'h34,
      8'h33, 8'h3D, 8'h44, 8'h45, 8'h20, 8'h52, 8'h54, 8'h53,
      8'h3D, 8'h31, 8'h20, 8'h52, 8'h58, 8'h45, 8'h3D, 8'h31,
      8'h20, 8'h49, 8'h52, 8'h51, 8'h3D, 8'h31, 8'h20, 8'h4C,
      8'h53, 8'h43, 8'h3D, 8'h46, 8'h31, 8'h20, 8'h43, 8'h30,
      8'h3D, 8'h32, 8'h33, 8'h20, 8'h43, 8'h31, 8'h3D, 8'h34,
      8'h35, 8'h20, 8'h49, 8'h4D, 8'h52, 8'h3D, 8'h36, 8'h37,
      8'h20, 8'h49, 8'h52, 8'h52, 8'h3D, 8'h38, 8'h39, 8'h20,
      8'h49, 8'h53, 8'h52, 8'h3D, 8'h41, 8'h42, 8'h20, 8'h56,
      8'h45, 8'h43, 8'h3D, 8'h43, 8'h44, 8'h20, 8'h43, 8'h50,
      8'h55, 8'h3D, 8'h45, 8'h46, 8'h20, 8'h49, 8'h4E, 8'h54,
      8'h41, 8'h3D, 8'h31, 8'h32, 8'h20, 8'h55, 8'h3D, 8'h33,
      8'h34, 8'h35, 8'h36, 8'h20, 8'h49, 8'h4F, 8'h3D, 8'h41,
      8'h42, 8'h43, 8'h44, 8'h20, 8'h44, 8'h52, 8'h3D, 8'h31,
      8'h20, 8'h49, 8'h56, 8'h3D, 8'h45, 8'h46, 8'h20, 8'h48,
      8'h50, 8'h3D, 8'h39, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45,
      8'h46, 8'h31, 8'h20, 8'h46, 8'h53, 8'h54, 8'h3D, 8'h42,
      8'h43, 8'h20, 8'h46, 8'h43, 8'h4D, 8'h3D, 8'h44, 8'h45,
      8'h20, 8'h46, 8'h52, 8'h53, 8'h3D, 8'h41, 8'h42, 8'h43,
      8'h44, 8'h45, 8'h46, 8'h31, 8'h32, 8'h20, 8'h46, 8'h43,
      8'h48, 8'h3D, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, 8'h38,
      8'h39, 8'h41, 8'h20, 8'h41, 8'h4C, 8'h42, 8'h3D, 8'h42,
      8'h43, 8'h44, 8'h45, 8'h46, 8'h31, 8'h32, 8'h33, 8'h20,
      8'h41, 8'h53, 8'h45, 8'h3D, 8'h34, 8'h35, 8'h36, 8'h37,
      8'h20, 8'h54, 8'h3D, 8'h37, 8'h38, 8'h3F,
      8'h0A
  };

  function [7:0] golden_byte(input integer i);
    golden_byte = GOLDEN_MSG[(350 - i) * 8 +: 8];
  endfunction

  reg [7:0] got_a [0:350];
  reg [7:0] got_b [0:350];
  integer i, diff_ab, both_nonzero, lf_at, cr_seen;

  // ==== STIMULUS ====
  // Vector A: every field a distinct NON-ZERO nibble and every one-bit flag 1, so no field byte is
  // the digit 0 and none can coincide with a literal byte. The hex digits A-F appear where a
  // literal cannot be one, which is what makes the 137/214 split below exact rather than approximate.
  task automatic fields_a; begin
    cpu_cs = 16'hA123;
    cpu_eip = 32'h456789AB;
    io_debug_status = 8'hCD;
    triple_fault_reset = 1'b1;
    hdd_mounted = 1'b1;
    hdd_capacity = 32'hEF123456;
    gdc_disp = 1'b1;
    vid_frame_cnt = 8'h67;
    hdd_req_cnt = 8'h89;
    hdd_err_cnt = 8'hAB;
    hdd_busy = 1'b1;
    hdd_hps_cycles = 32'h9ABCDEF1;
    vid_lit_seen = 1'b1;
    vid_lit_cnt = 8'hCD;
    ata_dbg_state = 8'hEF;
    ata_dbg_cmd = 32'h12345678;
    io_dbg_gate = 4'hA;
    mounted_at_run = 1'b1;
    gdc_dbg_sad = 16'h1234;
    gdc_dbg_pitch = 8'h56;
    gdc_dbg_col40 = 1'b1;
    gdc_dbg_disp = 1'b1;
    kbd_dbg_events = 8'h78;
    kbd_dbg_delivered = 8'h9A;
    kbd_dbg_rd_data = 8'hBC;
    kbd_dbg_wr_ctrl = 8'hDE;
    kbd_dbg_rts = 1'b1;
    kbd_dbg_rx_en = 1'b1;
    kbd_irq = 1'b1;
    kbd_dbg_last_del = 8'hF1;
    kbd_dbg_ctrl0 = 8'h23;
    kbd_dbg_ctrl1 = 8'h45;
    irq_dbg_imr = 8'h67;
    irq_dbg_irr = 8'h89;
    irq_dbg_isr = 8'hAB;
    inta_din = 8'hCD;
    cpu_irq_state = 8'hEF;
    inta_count = 8'h12;
    artic_hi = 16'h3456;
    io_itf_stage = 8'h78;
    last_io_addr = 16'hABCD;   // IO=ABCD
    last_io_data = 8'hEF;      // IV=EF
    last_io_rd = 1'b1;         // DR=1 (read)
    last_io_wr = 1'b0;
    fdc_dbg_state = 8'hBC;     // FST=BC
    fdc_dbg_cmd = 8'hDE;       // FCM=DE
    fdc_dbg_result = 32'hABCDEF12;  // FRS=ABCDEF12
    fdc_dbg_chrn = 32'h3456789A;    // FCH=3456789A
    ata_dbg_lba = 32'hBCDEF123;     // ALB=BCDEF123
    ata_dbg_sec = 16'h4567;         // ASE=4567
  end endtask

  // Vector B: every field zero. Every field byte becomes the digit 0 and the literal bytes cannot
  // move, so the positions that differ between A and B are exactly the positions that carry a field.
  task automatic fields_b; begin
    cpu_cs = 0;
    cpu_eip = 0;
    io_debug_status = 0;
    triple_fault_reset = 0;
    hdd_mounted = 0;
    hdd_capacity = 0;
    gdc_disp = 0;
    vid_frame_cnt = 0;
    hdd_req_cnt = 0;
    hdd_err_cnt = 0;
    hdd_busy = 0;
    hdd_hps_cycles = 0;
    vid_lit_seen = 0;
    vid_lit_cnt = 0;
    ata_dbg_state = 0;
    ata_dbg_cmd = 0;
    io_dbg_gate = 0;
    mounted_at_run = 0;
    gdc_dbg_sad = 0;
    gdc_dbg_pitch = 0;
    gdc_dbg_col40 = 0;
    gdc_dbg_disp = 0;
    kbd_dbg_events = 0;
    kbd_dbg_delivered = 0;
    kbd_dbg_rd_data = 0;
    kbd_dbg_wr_ctrl = 0;
    kbd_dbg_rts = 0;
    kbd_dbg_rx_en = 0;
    kbd_irq = 0;
    kbd_dbg_last_del = 0;
    kbd_dbg_ctrl0 = 0;
    kbd_dbg_ctrl1 = 0;
    irq_dbg_imr = 0;
    irq_dbg_irr = 0;
    irq_dbg_isr = 0;
    inta_din = 0;
    cpu_irq_state = 0;
    inta_count = 0;
    artic_hi = 0;
    io_itf_stage = 0;
    last_io_addr = 0;
    last_io_data = 0;
    last_io_rd = 0;
    last_io_wr = 0;
    fdc_dbg_state = 0;
    fdc_dbg_cmd = 0;
    fdc_dbg_result = 0;
    fdc_dbg_chrn = 0;
    ata_dbg_lba = 0;
    ata_dbg_sec = 0;
  end endtask

  task automatic capture(input integer which);
    begin
      snap = 1'b1; @(posedge clk); #1; snap = 1'b0;   // the record's SNAPSHOT: one pulse at its accept
      for (i = 0; i < 351; i = i + 1) begin
        idx = i[15:0];
        #1;
        if (which == 0) got_a[i] = ch;
        else            got_b[i] = ch;
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    fields_a;
    capture(0);
    fields_b;
    capture(1);

    $write("RECORD-A ");
    for (i = 0; i < 351; i = i + 1) $write("%c", got_a[i]);
    $write("\n");

    // 1. Every byte, against the formatter this module's layout was captured from.
    for (i = 0; i < 351; i = i + 1)
      if (got_a[i] !== golden_byte(i))
        $fatal(1, "watchdog record byte %0d changed: the golden capture has %02x, this formatter emits %02x",
               i, golden_byte(i), got_a[i]);

    // 2. ONE LINE: exactly one LF, it is the last byte, and there is no CR at all. This is the fix
    //    the record exists for - a CR would come back as a second newline through a tty's ICRNL.
    lf_at = -1; cr_seen = 0;
    for (i = 0; i < 351; i = i + 1) begin
      if (got_a[i] == 8'h0D) cr_seen = cr_seen + 1;
      if (got_a[i] == 8'h0A) begin
        if (lf_at >= 0) $fatal(1, "the record carries more than one LF (%0d and %0d): it is ONE line", lf_at, i);
        lf_at = i;
      end
    end
    if (cr_seen != 0)
      $fatal(1, "%0d CR byte(s) in the record: a tty's ICRNL turns each into a second newline, which is the blank line between records this rewrite removed", cr_seen);
    if (lf_at != 350)
      $fatal(1, "the record's only LF is at %0d, not at the end (350)", lf_at);

    // 3. The trigger's position: the SECOND-TO-LAST byte is the formatter's '?', which
    //    pc9821_dbg_record.sv overwrites with the path letter, and the LF is after it.
    if (got_a[349] !== "?")
      $fatal(1, "the second-to-last byte is %02x, not '?': pc9821_dbg_record substitutes the trigger there and tools/check_telemetry_contract.py checks the index", got_a[349]);

    // 4. The split the ROM depends on: 137 bytes carry fields, 214 are literal.
    diff_ab = 0;
    for (i = 0; i < 351; i = i + 1) if (got_a[i] !== got_b[i]) diff_ab = diff_ab + 1;
    if (diff_ab != 137)
      $fatal(1, "%0d record bytes move with the fields, not 137: a literal became a field byte or the reverse", diff_ab);

    // 5. The field bytes B produces are the digit 0 (every field zero), and only those, which is
    //    the other direction of the split: a literal that turned into a field byte would move, and
    //    a field byte that turned into a literal would not.
    for (i = 0; i < 351; i = i + 1)
      if (got_a[i] !== got_b[i] && got_b[i] !== "0")
        $fatal(1, "record byte %0d moves with the fields but is %02x with every field zero, not the digit 0",
               i, got_b[i]);

    // 6. An index outside the record is NUL, which is the arm the case this replaced had as its
    //    default. The watchdog itself stops at 350.
    idx = 16'd351;  #1; if (ch !== 8'h00) $fatal(1, "idx 351 answered %02x, not NUL", ch);
    idx = 16'd511;  #1; if (ch !== 8'h00) $fatal(1, "idx 511 answered %02x, not NUL", ch);
    idx = 16'hFFFF; #1; if (ch !== 8'h00) $fatal(1, "idx 65535 answered %02x, not NUL", ch);

    // 7. THE SNAPSHOT (the telemetry tear fix): the record's digits are the fields' values at
    //    the report's accept (snap), HELD while the record is read - live digits would follow
    //    the fields, and a carry crossing between two digits of one field splices two values
    //    into a torn composite (a telemetry tear, the same shape the
    //    PRF/GFX formatters had). Set the fields back to vector A and re-read with NO new
    //    snapshot: the record must reprint vector B's bytes exactly. On a formatter that reads
    //    live this fails deterministically (every field byte follows A); a NEW snapshot then
    //    takes A again, byte for byte against the golden.
    fields_a;
    for (i = 0; i < 351; i = i + 1) begin
      idx = i[15:0];
      #1;
      got_a[i] = ch;
    end
    for (i = 0; i < 351; i = i + 1)
      if (got_a[i] !== got_b[i])
        $fatal(1, "record byte %0d moved under the snapshot: %02x -> %02x (the digits must be the report's accept instant)",
               i, got_b[i], got_a[i]);
    capture(0);                       // a NEW snapshot takes vector A
    for (i = 0; i < 351; i = i + 1)
      if (got_a[i] !== golden_byte(i))
        $fatal(1, "a new snapshot did not take the fields: byte %0d is %02x, want %02x",
               i, got_a[i], golden_byte(i));

    $display("WATCHDOG-RECORD bytes=351 field_bytes=%0d literal_bytes=%0d lf_at=%0d cr=%0d",
             diff_ab, 351 - diff_ab, lf_at, cr_seen);
    // ==== VERDICT ====
    $display("TB_PC9821_WATCHDOG: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #1_000_000;
    $fatal(1, "the watchdog-message bench did not finish in 1 ms of simulated time");
  end

endmodule
