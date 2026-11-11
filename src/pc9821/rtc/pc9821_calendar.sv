// PC-9821 serial calendar (uPD4990A, and the uPD4993A extended form), from NP2kai
// io/upd4990.c, QEMU hw/misc/pc98-sys.c and the machine's own reader BANK7@0x5DA2.
//
// Four surfaces: 0x20 write = command latch (bits 2:0 command, 3 STB, 4 CLK,
// 5 DATA); 0x22 r/w = mode latch, bit 5 selects the uPD4993A format; 0x33 bit 0 =
// serial data out; 0x128 r/w = the interval interrupt (IRQ15): bit 7 enable, bits 1:0
// rate, bit 4 a tick flag that a read clears; the IRQ15 line is high with a short low pulse at
// each tick (see the tick block below).
//
// The command is taken on the RISING edge of STB and each rising CLK advances the
// shift register. Normally the opcode is the field in bits 2:0, but when that field
// is 7 it is shifted in serially on DATA, one bit per CLK - the only form the
// machine's firmware uses. The SAME field-7 channel carries the TIMESET payload: the
// machine's writer holds the field at 7 and puts each data bit on DATA
// (BANK7@0x5D76-0x5D8E: `mov al,0x07` / `mov al,0x27`), so the field does not
// separate command from data and the input accumulator takes every rising CLK,
// freezing at 48 so the opcode's own four clocks cannot reach the payload.
// TIMEREAD latches the counters into the output register; only a
// SHIFT command arms the walk-out, so a guest issuing TIMEREAD alone reads zeros, as NP2kai.
//
// In uPD4993A mode the 48-bit payload is followed by the reference's trailing 0x01 nibble
// (the machine's 52-bit captures end 1,0,0,0); see the TIMEREAD arm below.

`default_nettype none

module pc9821_calendar #(
    // The uPD4993A's 1 Hz calendar and its 64/32/16 Hz tick are the machine's real-time
    // rates, so their dividers count SYS_CLOCK_HZ cycles, not a fixed 50 MHz count.
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
  input  wire        clk,
  input  wire        rst_n,

  // Framework RTC, BCD: [7:0] seconds, [15:8] minutes, [23:16] hour,
  // [31:24] day, [39:32] month, [47:40] year, [55:48] weekday.
  input  wire [55:0] rtc_bcd,
  input  wire        rtc_load,      // one-shot when the guest is released

  input  wire        cmd_we,        // 0x20 write
  input  wire [7:0]  cmd_din,
  input  wire        mode_we,       // 0x22 write
  input  wire [7:0]  mode_din,
  output wire [7:0]  mode_dout,
  input  wire        tick_we,       // 0x128 write
  input  wire        tick_rd,       // 0x128 read: clears the tick flag (the IRQ15 line is left as it is)
  /* verilator lint_off UNUSEDSIGNAL */   // bit 7 (enable) and bits 1:0 (rate) are the register; the machine's read-back shows nothing else written (bits 6:5 and 3:2 read 0, bit 4 is the tick flag)
  input  wire [7:0]  tick_din,
  /* verilator lint_on UNUSEDSIGNAL */
  output wire [7:0]  tick_dout,
  output wire        cdat,          // 0x33 bit 0
  output wire        irq            // IRQ15 (slave bit 7)
);

  localparam [3:0] CMD_HOLD     = 4'd0;
  localparam [3:0] CMD_SHIFT    = 4'd1;
  localparam [3:0] CMD_TIMESET  = 4'd2;
  localparam [3:0] CMD_TIMEREAD = 4'd3;

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------
  reg [7:0] c_sec, c_min, c_hour, c_day, c_month, c_year, c_wday;
  reg [7:0] mode_reg;
  /* verilator lint_off UNUSEDSIGNAL */   // only bits[4:3] are the serial channel's 1->0 edge; the rest of the byte is not part of it
  reg [7:0] cmd_last;       // previous 0x20 write, for the edge detector
  /* verilator lint_on UNUSEDSIGNAL */
  reg [4:0] cmd_serial;     // serial command channel: bit 4 is the entry point
  reg [2:0] parallel;       // the DATA field that gates that channel

  reg [51:0] sreg;          // output shift register; bit 0 is sent first
  reg        shifting;
  reg [47:0] in_sreg;       // accumulating input register for TIMESET
  reg [5:0]  in_bits;       // data-phase clocks since the last SHIFT; a TIMESET needs 48

  reg [1:0]  tick_rate;     // 0 = 1/64 s, 1 = 1/32 s, 2 = off, 3 = 1/16 s
  reg        tick_en;       // 0x128 bit 7: the interrupt enable
  reg        tick_flag;     // 0x128 bit 4: a tick since the last read
  reg        tick_line;     // the IRQ15 request line
  reg [22:0] tick_div;
  reg [15:0] tick_low;      // what is left of the low pulse at a tick (0 = not in one)
  reg [26:0] hz_div;        // 27 bits hold the longest profile's 1 Hz count

  // c_month is packed BCD (0x01..0x12, the framework RTC's form and what
  // days_in_month expects), but the emitted month|weekday byte carries the month's
  // DECIMAL VALUE (1..12) in its high nibble, the way NP2kai packs the byte
  // (`(month << 4) + week`, calendar.c:177, read back as `bcd[1] >> 4`, :163).
  // Taking c_month[3:0] alone sent October (0x10) out as month 0.
  function [3:0] month_bcd_to_dec(input [7:0] m);
    month_bcd_to_dec = (m[7:4] != 4'd0) ? (m[3:0] + 4'd10) : m[3:0];
  endfunction
  function [7:0] month_dec_to_bcd(input [3:0] v);   // v = 1..12
    month_dec_to_bcd = (v >= 4'd10) ? (8'h10 | {4'h0, v - 4'd10}) : {4'h0, v};
  endfunction

  wire [7:0]  month_wday = {month_bcd_to_dec(c_month), c_wday[3:0]};

  // LSB-first per byte, seconds byte first, per BANK7@0x5DA2 and NP2kai.
  wire [47:0] emit_payload = {c_year, month_wday, c_day, c_hour, c_min, c_sec};

  assign mode_dout = mode_reg;
  assign tick_dout = {tick_en, 2'b00, tick_flag, 2'b00, tick_rate};
  assign cdat      = shifting ? sreg[0] : 1'b0;
  assign irq       = tick_line;

  // The command the STB edge latches. A field of 7 selects the serial channel: the
  // opcode then lives in cmd_serial, not in the field bits (NP2kai `parallel == 7`,
  // io/upd4990.c:24-31; QEMU's CAL_CMD_EXTEND, pc98-sys.c:55). NP2kai decodes the
  // FULL four bits (`cmd = serial & 0x0f`, io/upd4990.c:26), so 0x9/0xA/0xB are the
  // interrupt commands with no compiled case and must NOT alias SHIFT/TIMESET/
  // TIMEREAD (`serial & 7` was exactly that alias).
  wire [3:0] command = (cmd_din[2:0] == 3'd7) ? cmd_serial[3:0] : {1'b0, cmd_din[2:0]};

  // ---- BCD and calendar helpers ----
  // v + 1 in packed BCD. Callers test for the roll-over.
  function [7:0] bcd_next(input [7:0] v);
    bcd_next = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
  endfunction

  // Two-digit BCD year divisible by four: 10 mod 4 == 2, so (2*hi + lo) mod 4 == 0.
  function is_leap(input [7:0] y);
    /* verilator lint_off UNUSEDSIGNAL */   // the sum needs 5 bits; only [1:0] are read, the test being mod 4
    reg [4:0] v;
    /* verilator lint_on UNUSEDSIGNAL */
    begin
      v = {1'b0, y[7:4]} * 5'd2 + {1'b0, y[3:0]};
      is_leap = (v[1:0] == 2'b00);
    end
  endfunction

  function [7:0] days_in_month(input [7:0] m, input [7:0] y);
    case (m)
      8'h01: days_in_month = 8'h31;
      8'h02: days_in_month = is_leap(y) ? 8'h29 : 8'h28;
      8'h03: days_in_month = 8'h31;
      8'h04: days_in_month = 8'h30;
      8'h05: days_in_month = 8'h31;
      8'h06: days_in_month = 8'h30;
      8'h07: days_in_month = 8'h31;
      8'h08: days_in_month = 8'h31;
      8'h09: days_in_month = 8'h30;
      8'h10: days_in_month = 8'h31;
      8'h11: days_in_month = 8'h30;
      8'h12: days_in_month = 8'h31;
      default: days_in_month = 8'h31;
    endcase
  endfunction

  // Period in clk_sys cycles for the selected tick rate (1/64, 1/32, 1/16 s), minus one
  // because the counter resets at the compare. 781249 / 1562499 / 3124999 at 50 MHz.
  wire [22:0] tick_period = (tick_rate == 2'd3) ? 23'(SYS_CLOCK_HZ / 16 - 1) :
                            (tick_rate == 2'd1) ? 23'(SYS_CLOCK_HZ / 32 - 1) :
                                                  23'(SYS_CLOCK_HZ / 64 - 1);
  // The low pulse at a tick: 5 us, inside the 1-2 ARTIC ticks (3.3-6.5 us at 307.2 kHz) the
  // machine's line stays low (docs/probes/KIT2-XE10-AUDIT2.TXT:27-41, e.g. `cfg=81 mode=R ...
  // e=-8013,+8015,-17615,+17616`, `cfg=81 mode=N ... e=-5311,+5312`), at least one clock.
  localparam integer TICK_LOW_N = (SYS_CLOCK_HZ / 200_000 > 0) ? SYS_CLOCK_HZ / 200_000 : 1;
  // The tick block's line (see its comment): a tick with the interrupt enabled starts the low
  // pulse, its end raises the line, and a write that disables the tick (bit 7 clear or rate 2)
  // drops it; a read changes nothing.
  wire        tick_now     = !tick_we && (tick_rate != 2'd2) && (tick_div == tick_period);
  wire        tick_off_wr  = tick_we && (!tick_din[7] || tick_din[1:0] == 2'd2);
  wire        tick_line_nx = tick_off_wr ? 1'b0 :
                             tick_now    ? 1'b0 :
                             (tick_low == 16'd1) ? 1'b1 : tick_line;
  wire [15:0] tick_low_nx  = tick_off_wr ? 16'd0 :
                             (tick_now && tick_en) ? 16'(TICK_LOW_N) :
                             (tick_low != 16'd0) ? (tick_low - 16'd1) : 16'd0;
  localparam [26:0] HZ_DIV_MAX = 27'(SYS_CLOCK_HZ) - 27'd1;   // one second

  // ---- the 1 Hz ripple, counted from its roll signals ---------------------
  // The date is a ripple, and at most TWO fields carry a BCD increment in one
  // second: the deepest field that does not roll, and always the weekday on a
  // date change. Writing the ripple as nested branches gave every field its own
  // bcd_next adder (eight sites, ~60 ALMs measured with tools/res_exp_map.py);
  // selecting the incrementing field's VALUE first shares one adder between the
  // six clock fields. The roll signals are exactly the nested form's conditions: each implies
  // the one above it.
  wire sec_roll  = (c_sec == 8'h59);
  wire min_roll  = sec_roll  && (c_min  == 8'h59);
  wire hour_roll = min_roll  && (c_hour == 8'h23);
  wire day_roll  = hour_roll && (c_day  >= days_in_month(c_month, c_year));
  wire mon_roll  = day_roll  && (c_month == 8'h12);
  wire year_roll = mon_roll  && (c_year  == 8'h99);
  // The field that increments: the first that does not roll. All six false (a year
  // roll) selects c_year, which the year_roll arm answers with 00 anyway.
  wire [7:0] bcd_src = !sec_roll  ? c_sec   :
                       !min_roll  ? c_min   :
                       !hour_roll ? c_hour  :
                       !day_roll  ? c_day   :
                       !mon_roll  ? c_month : c_year;
  wire [7:0] bcd_inc  = bcd_next(bcd_src);
  // The weekday is a plain increment here, not bcd_next: its only consumer takes it
  // only while `c_wday < 6` (see the always block below), where c_wday[7:4]==0 and
  // c_wday[3:0]!=9, so bcd_next(c_wday) == c_wday + 1 with no carry. Every value
  // 6..15 is discarded by that consumer's `>= 8'h06 -> 0` arm, so this is equal at
  // every cycle the value is observed and saves a second 8-bit BCD adder.
  wire [7:0] wday_inc = c_wday + 8'd1;

  always @(posedge clk) begin
    if (!rst_n) begin
      c_sec <= 8'h00; c_min <= 8'h00; c_hour <= 8'h00;
      c_day <= 8'h01; c_month <= 8'h01; c_year <= 8'h00; c_wday <= 8'h00;
      mode_reg     <= 8'hEF;   // measured first touch on the real machine; bit 5 set
                               // = 4993 extended format, which DOS expects
      cmd_last     <= 8'h00;
      cmd_serial   <= 5'h00;
      parallel     <= 3'h0;
      sreg         <= 52'h0;
      shifting     <= 1'b0;
      in_sreg      <= 48'h0;
      in_bits      <= 6'd0;
      tick_rate    <= 2'd1;    // 1/32 s, the machine's power-up rate
      tick_en      <= 1'b1;    // read back 0x81 as before; the ITF writes 0x81 at power-on
      tick_flag    <= 1'b0;
      tick_line    <= 1'b0;
      tick_div     <= 23'd0;
      tick_low     <= 16'd0;
      hz_div       <= 27'd0;
    end else begin
      // ---------------- 1 Hz counters with BCD carries ----------------
      if (rtc_load) begin
        c_sec   <= rtc_bcd[7:0];
        c_min   <= rtc_bcd[15:8];
        c_hour  <= rtc_bcd[23:16];
        c_day   <= rtc_bcd[31:24];
        c_month <= rtc_bcd[39:32];
        c_year  <= rtc_bcd[47:40];
        c_wday  <= rtc_bcd[55:48];
        hz_div  <= 27'd0;
      end else if (hz_div == HZ_DIV_MAX) begin
        hz_div <= 27'd0;
        // The weekday counts DAYS, so it advances on every date change (hour_roll),
        // not only inside the month-rollover arm. The ITF reads this nibble as
        // month|weekday (BANK7@0x5D22), so it must advance on any date change.
        c_wday  <= hour_roll ? ((c_wday >= 8'h06) ? 8'h00 : wday_inc) : c_wday;
        c_sec   <= sec_roll  ? 8'h00 : bcd_inc;
        c_min   <= min_roll  ? 8'h00 : (sec_roll  ? bcd_inc : c_min);
        c_hour  <= hour_roll ? 8'h00 : (min_roll  ? bcd_inc : c_hour);
        c_day   <= day_roll  ? 8'h01 : (hour_roll ? bcd_inc : c_day);
        c_month <= mon_roll  ? 8'h01 : (day_roll  ? bcd_inc : c_month);
        c_year  <= year_roll ? 8'h00 : (mon_roll  ? bcd_inc : c_year);
      end else hz_div <= hz_div + 27'd1;

      // ---------------- periodic tick and IRQ15 ----------------
      // The Xe10 (docs/probes/XE10T-XE10-AUDIT.TXT, the CAL rows: INT 17h counted over
      // 0.5 s with a handler that reads 0x128 (R) and one that never does (N)):
      //   - ONE REQUEST PER TICK whether or not 0x128 is read: 0x81 R 16 / N 16, 0x80 R 32 /
      //     N 32, 0x83 R 9 / N 8 - so rate 1 = 32 Hz, 0 = 64 Hz, 3 = 16 Hz, and the request
      //     falls by itself before the next tick (an edge 8259 saw a new edge every tick);
      //   - 0x82 stops the tick (R 0 / N 0, read back 82: no tick flag either);
      //   - bit 7 clear disables the interrupt but not the tick: 0x00 and 0x01 deliver
      //     nothing (R 0 / N 0) and read back 10 / 11, the tick flag set;
      //   - bit 4 is that tick flag, cleared by a read: as found 91, then 81 (CAL128 `v=91`,
      //     RESTORE `P128_TICK was=91 now=81`), N rows read 91/90/93 after the window, R
      //     rows 81/80/83.
      // THE LINE IS HIGH WITH A SHORT LOW PULSE AT EACH TICK, and a read leaves it. Kit 2's
      // /AUDIT2 sampled the masked slave IRR bit 7 (which follows the line, WD_MASK) for 100 ms
      // at 0x128 = as found, 81, 80 and 83, with and without a 0x128 read at every rise
      // (docs/probes/KIT2-XE10-AUDIT2.TXT:27-41): high for 97784-97791 of 97792 samples, low
      // for 1-2 ARTIC ticks once per period (`cfg=81 mode=N ... e=-5311,+5312,-14912,+14913`,
      // 9600 ticks = 31.25 ms apart; 4800 at 80, 19200 at 83), the same with the reads
      // (`cfg=81 mode=R ... ones=97790`), so the PIC's edge is the pulse's end, one per tick.
      // Each row writes its 0x128 value and reads 0x128 before it samples, and the line was
      // already high at the first sample (`first=1`): neither drops it. Only the first window
      // (as found, after the earlier section left the tick off) started low and rose at the
      // first tick (`cfg=FF mode=N first=0 ... e=+9462`), so a line that has had no enabled
      // tick is low. The undoc98 / NP2kai rule this replaces (a read lowers the request,
      // io_cal.txt I/O 0128h, upd4990_i128 `pic_resetirq(15);`) is not the machine. The
      // machine's backup battery was dead for the run, which costs the calendar its time across
      // power-off, not its running count: the calendar ran at 1 s/s in the session and the four
      // rates' periods agree, so the shape stands. NOT MEASURED, so inferred: with bit 7 clear
      // or rate 2 (off) no interrupt comes (kit 1, XE10T-XE10-AUDIT.TXT `cfg=01 ... n=0`), and
      // the line is held low there.
      // The write still restarts the period, which the capture does not support (the first
      // fall after `0x128 <- 81` lands 5311 and 8013 ticks in, not a period); todo item 114.
      // One assignment per register per cycle: the line and the pulse count take their next
      // value from the arms below (tick_line_nx / tick_low_nx).
      tick_line <= tick_line_nx;
      tick_low  <= tick_low_nx;
      if (tick_we) begin
        tick_rate    <= tick_din[1:0];
        tick_en      <= tick_din[7];
        tick_div     <= 23'd0;
        tick_flag    <= 1'b0;
      end else if (tick_rate == 2'd2) begin
        tick_div <= 23'd0;
        if (tick_rd) tick_flag <= 1'b0;
      // tick_div never passes tick_period: the rate moves only on tick_we, which zeroes it.
      end else if (tick_div == tick_period) begin
        tick_div     <= 23'd0;
        // A tick landing on a read's cycle is a new tick: the flag sets (race-idiom R3, set
        // wins).
        tick_flag    <= 1'b1;
      end else begin
        tick_div <= tick_div + 23'd1;
        if (tick_rd) tick_flag <= 1'b0;
      end

      // ---------------- 0x22 mode latch ----------------
      if (mode_we) mode_reg <= mode_din;

      // ---------------- 0x20 command latch ----------------
      if (cmd_we) begin
        if (cmd_din[3] && !cmd_last[3]) begin
          // Rising STB latches the command. Over the SERIAL channel the firmware
          // holds the field at 7 and sends the four opcode bits on DATA, one CLK
          // each, before the STB pulse (BANK7@0x5DA2); `command` resolves that to
          // the opcode in cmd_serial. In the parallel form the command is the field
          // bits themselves. NP2kai's `parallel` field only a DATA write updates, so
          // its first read after reset returns an all-zero date - not copied.
          if (command == CMD_TIMEREAD) begin
            // Latch the counters into the output register. As on NP2kai
            // (io/upd4990.c:40-49), this does NOT arm the output shift: only a SHIFT
            // command does, which matters because the firmware sends TIMEREAD and then
            // four more CLK edges to clock in the SHIFT opcode (BANK7@0x5D25-0x5D2A).
            //
            // THE PAYLOAD EMITS FIRST IN BOTH FORMATS, the uPD4993A form's four extra
            // bits behind it. `cdat` is sreg[0] and the register shifts RIGHT, so the
            // LOW bits leave first: {4'b0001, emit_payload} puts the payload in the
            // low 48 bits and emits the reference's trailing nibble 1,0,0,0. NP2kai
            // sets reg[1] = 0x01 after a time read (io/upd4990.c:43-49, "uPD4990
            // Happy!! :)") and the shift walks reg[7] down to reg[0], so the 49th bit
            // out is 1; the machine's own 52-bit captures end "...1000" with the
            // payload at bit 0. The machine settles it - its reader at BANK7@0x5D22
            // consumes EXACTLY 48 clocks and skips nothing, so the payload must lead.
            sreg     <= {4'b0001, emit_payload};
            shifting <= 1'b0;
          end else if (command == CMD_SHIFT) begin
            // Register shift: walk the register out of 0x33 bit 0, one bit per CLK,
            // and start a fresh input accumulator for a time-set that follows.
            shifting <= 1'b1;
            in_sreg  <= 48'h0;
            in_bits  <= 6'd0;
          end else if (command == CMD_TIMESET) begin
            // Load the counters from the accumulated input stream if the BCD is in
            // range. THE FIELD POSITIONS MIRROR emit_payload: in_sreg shifts the
            // arriving bit in at bit 47 and off the bottom, so after 48 LSB-first
            // clocks the FIRST byte sent (seconds) sits in [7:0] and the last (the
            // year) in [47:40], the order the reader walks out (BANK7@0x5D22).
            //
            // The month|weekday byte at [39:32] is NOT bare BCD: its HIGH nibble
            // [39:36] is the month's decimal value (1..12; 0xA/0xB/0xC for
            // Oct..Dec) and its LOW nibble [35:32] the weekday, as NP2kai packs it.
            if (in_bits == 6'd48 &&   // frozen at 48: see the CLK arm
                in_sreg[7:0]   <= 8'h59 && in_sreg[15:8]  <= 8'h59 &&
                in_sreg[23:16] <= 8'h23 && in_sreg[31:24] >= 8'h01 &&
                /* verilator lint_off WIDTHEXPAND */   // 0x39:36 is the 4-bit month-VALUE nibble, compared against an 8-bit literal
                in_sreg[31:24] <= 8'h31 && in_sreg[39:36] >= 8'h01 &&
                /* verilator lint_on WIDTHEXPAND */
                /* verilator lint_off WIDTHEXPAND */   // 0x39:36 as above: the nibble holds the value 1..0xC
                in_sreg[39:36] <= 8'h0C) begin
                /* verilator lint_on WIDTHEXPAND */
              c_sec   <= in_sreg[7:0];
              c_min   <= in_sreg[15:8];
              c_hour  <= in_sreg[23:16];
              c_day   <= in_sreg[31:24];
              c_month <= month_dec_to_bcd(in_sreg[39:36]);
              c_wday  <= {4'h0, in_sreg[35:32]};
              c_year  <= in_sreg[47:40];
            end
            shifting <= 1'b0;
          end else if (command == CMD_HOLD) begin
            // Opcode 0 is a register hold: NP2kai sets regsft = 0 (io/upd4990.c:29-30),
            // stopping the position counter so the output pin holds. Only a SHIFT arms
            // the walk-out, so a hold must DISARM it rather than leave it running.
            shifting <= 1'b0;
          end
        end else if (cmd_din[4] && !cmd_last[4]) begin
          // Rising CLK advances the output shift and the input accumulator, and -
          // while the field is 7 - the serial command register (io/upd4990.c:87-90).
          if (shifting) sreg <= {cmd_din[5], sreg[51:1]};
          // The input accumulator takes a bit on EVERY rising CLK and FREEZES at 48.
          // The machine's writer holds the 3-bit field at 7 for the TIMESET payload
          // too (BANK7@0x5D76-0x5D8E: `mov al,0x07` / `mov al,0x27`, only DATA moving),
          // so a `parallel != 3'd7` gate drops every payload bit and the TIMESET arm's
          // `in_bits == 6'd48` test can never pass - the write is silently lost. The
          // gate's stated reason was that the opcode's own four CLK edges are not
          // data, and they are not: but they come AFTER the 48 payload clocks (4 for
          // SHIFT's opcode, 48 data, then 4 to clock in TIMESET), so freezing at 48
          // discards them with the payload intact. The reference does not gate either:
          // NP2kai stores the DATA bit at the command-driven position whatever the
          // field is (io/upd4990.c:81-90), and that position has walked past the
          // payload by the time the next opcode arrives.
          if (in_bits != 6'd48) begin
            // A right shift with the new bit at the top: after 48 LSB-first clocks the
            // FIRST byte sent sits in [7:0] (see the TIMESET arm). A former
            // `{cmd_din[5], in_sreg[46:0]}` left bits [46:0] in place and dropped [47],
            // so the accumulator kept only the LAST bit and a time set never loaded.
            in_sreg <= {cmd_din[5], in_sreg[47:1]};
            in_bits <= in_bits + 6'd1;
          end
          if (parallel == 3'd7) cmd_serial <= {1'b0, cmd_serial[4:1]};
        end else if (!cmd_din[3] && !cmd_din[4]) begin
          // DATA write: the 3-bit field, and - when that field is 7 - the serial
          // command register's data bit. Only the top bit is written: NP2kai inserts
          // DATA at bit 4 and the CLK edge shifts it down (io/upd4990.c:81-90).
          parallel <= cmd_din[2:0];
          if (cmd_din[2:0] == 3'd7) cmd_serial[4] <= cmd_din[5];
        end
        cmd_last <= cmd_din;
      end
    end
  end

endmodule

`default_nettype wire
