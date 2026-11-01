`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The calendar's own counters carry like a real date, read back through the ITF's own reader: the ITF clocks exactly 48 bits (BANK7@0x5D22, for each of 6 bytes 8 x in al,0x33 / shr al,1 / rcr ah,1) and skips nothing, so the seconds byte is the first byte out. The bench sets a boundary time through the framework load, advances exactly one second across the calendar's own 1 Hz divider, and reads the six fields back, asserting the second, minute, hour, day, month and year carries plus BCD validity - including 2024-02-28 becoming 02-29 while 2026-02-28 becomes 03-01, which a fixed 28-day February satisfies only by being wrong about a quarter of all years. It also reaches the three months past September, where the month|weekday byte's high nibble must carry the month's DECIMAL value: October, November and December emit 0xA/0xB/0xC, which slicing the packed-BCD month's low nibble turned into 0/1/2. It deliberately runs with the mode latch's bit 5 CLEAR, where this module emits the payload starting at bit 0, because that is the alignment the machine's own capture shows (docs/probes/TRS.TXT reports the seconds-field alignment as payload at bit 0, no prefix); the EXTENDED mode's alignment is a separate defect and is OUT OF SCOPE here - this file neither encodes nor prints it.
//
// ---- the bench's own account of where each expectation comes from ----
//
//  1. THE READ SHAPE IS THE ITF'S, NOT OURS. BANK7@0x5D22 sends command 3, then
//     command 1, then clocks 8 times per byte with `in al,0x33; shr al,1;
//     rcr ah,1', for each of 6 bytes, and stores them es:[bx+5] first and
//     es:[bx+0] last -- seconds first on the wire, year last (disassembled
//     from the dump). So the reader consumes EXACTLY 48 bits and
//     skips nothing. This bench replays that shape: sample bit 0 of the port,
//     then one CLK rise on 0x20, eight times per byte.
//     [source: the firmware dump, BANK7@0x5D22]
//
//  2. THE SECOND IS THE CALENDAR'S OWN. The ITF and DOS read a date, so the
//     counter must produce real dates: a day never exceeds its month's length,
//     December rolls into January of the next year, and February has 29 days in
//     a leap year. The machine's counters do NOT tick (its backup battery is
//     dead, docs/probes/TRS.TXT), so no capture can show a carry, and this is
//     the one expectation in the bench that is INFERRED from what a calendar
//     is rather than measured - stated plainly because a reader is entitled to
//     know which is which.
//     [source: inferred; the chip is a date counter]
//
//  3. THE DATA IS PACKED BCD WITH A FOUR-BIT YEAR AND A MONTH|WEEKDAY BYTE.
//     Fixing the field order needs no faith: the machine's own capture decodes
//     to bytes 30 05 01 02 10 00 after the probe wrote 01:05:30 on day 02 of
//     month 1 (docs/probes/TRS.TXT), which is exactly the payload layout
//     `emit_payload' assembles.
//     [source: the real machine, docs/probes/TRS.TXT]
//
//  4. THE 1 Hz BOUNDARY IS FORCED, AND THAT SHORTCUT IS ADMITTED. Reaching a
//     real one-second boundary takes 50,000,000 clk_sys cycles, so the bench
//     writes the divider's top value and lets one clock carry it over, the same
//     test-only shortcut tb_pc9821_calendar uses. What this does NOT test is
//     the divider's length itself; that the divider divides by 50,000,000 is
//     asserted by nothing here and is a finding, not a check.

module tb_pc9821_calendar_rollover;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [55:0] rtc_bcd = 56'h00_00_01_01_00_00_00;
  reg         rtc_load = 0;

  reg         cmd_we = 0, mode_we = 0, tick_we = 0, tick_rd = 0;
  reg  [7:0]  cmd_din = 0, mode_din = 0, tick_din = 0;
  wire [7:0]  mode_dout, tick_dout;
  wire        cdat, irq;
  integer     errors = 0;

  // ==== DUT ====
  pc9821_calendar dut (
    .clk(clk), .rst_n(rst_n),
    .rtc_bcd(rtc_bcd), .rtc_load(rtc_load),
    .cmd_we(cmd_we), .cmd_din(cmd_din),
    .mode_we(mode_we), .mode_din(mode_din), .mode_dout(mode_dout),
    .tick_we(tick_we), .tick_rd(tick_rd), .tick_din(tick_din),
    .tick_dout(tick_dout),
    .cdat(cdat), .irq(irq)
  );

  task fail(input [1023:0] message);
    begin
      errors = errors + 1;
      $display("FAIL: %0s", message);
    end
  endtask

  // Stimulus is driven on the NEGEDGE so the DUT samples each value at the
  // following posedge, one value per clock: a write placed on the posedge
  // itself races with the DUT's own edge and reads one bit late.
  task send_serial(input [3:0] op);
    integer i;
    reg [7:0] d;
    begin
      cmd_we = 1;
      for (i = 0; i < 4; i = i + 1) begin
        d = op[i] ? 8'h27 : 8'h07;                    // DATA write, field 7, CLK low
        @(negedge clk); cmd_din = d;
        @(negedge clk); cmd_din = d | 8'h10;          // CLK rise: shift
        @(negedge clk); cmd_din = d;                  // CLK fall
      end
      @(negedge clk); cmd_din = 8'h0F;                // STB rise: latch the command
      @(negedge clk); cmd_din = 8'h07;                // STB fall
      cmd_we  = 0;
      @(negedge clk);
    end
  endtask

  // Read the six fields exactly as the ITF's reader does: sample 0x33 bit 0,
  // then one CLK rise. Saved seconds-first, year-last.
  task read_clock(output [7:0] sec, output [7:0] min, output [7:0] hour,
                  output [7:0] day, output [7:0] mw,  output [7:0] year);
    integer i, k;
    reg [7:0] b;
    reg [7:0] got [0:5];
    begin
      send_serial(4'd3);                      // TIMEREAD: latch the counters
      send_serial(4'd1);                      // SHIFT: arm the output register
      cmd_we = 1;
      for (i = 0; i < 6; i = i + 1) begin
        b = 8'h00;
        for (k = 0; k < 8; k = k + 1) begin
          @(negedge clk); b[k] = cdat;                    // bit 0 of 0x33, before the clock
          cmd_din = 8'h17;                                // CLK rise: advance
          @(negedge clk); cmd_din = 8'h07;                // CLK fall, field 7, DATA 0
        end
        got[i] = b;
      end
      cmd_we = 0;
      sec = got[0]; min = got[1]; hour = got[2];
      day = got[3]; mw  = got[4]; year = got[5];
    end
  endtask

  // The framework hands the core one RTC word at core start.
  task set_time(input [55:0] t);
    begin
      rtc_bcd = t;
      @(negedge clk); rtc_load = 1;
      @(negedge clk); rtc_load = 0;
      @(negedge clk);
    end
  endtask

  // One second, forced across the 1 Hz boundary (see note 4 above). The deposit
  // lands mid-cycle so the DUT compares it on the next posedge.
  task tick_once;
    begin
      @(negedge clk);
      dut.hz_div = 26'd49_999_999;
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  // Every field must be packed BCD or the ITF's reader decodes nonsense.
  task check_bcd(input [8*16-1:0] what, input [7:0] v);
    begin
      if (v[3:0] > 4'd9 || v[7:4] > 4'd9)
        fail({what, ": not packed BCD"});
    end
  endtask

  // BCD-correct increment, the same rule the reader expects to see.
  function [7:0] bcd_plus1(input [7:0] v);
    bcd_plus1 = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
  endfunction

  // A boundary time: sec=59, min=59, hour=23, day, month, year, weekday.
  function [55:0] at_midnight(input [7:0] day, input [7:0] month,
                              input [7:0] year, input [7:0] wday);
    at_midnight = {wday, year, month, day, 8'h23, 8'h59, 8'h59};
  endfunction

  reg [7:0] s, m, h, d, mw, y;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    rtc_load = 1;
    @(negedge clk);
    rtc_load = 0;
    repeat (4) @(posedge clk);

    // The mode latch's bit 5 CLEAR: the alignment the machine's capture shows.
    // Bit 5 is the uPD4993A extra-nibble selector; leaving it clear keeps this
    // bench about the counters, not about that question.
    mode_din = 8'h00;
    @(negedge clk); mode_we = 1;
    @(negedge clk); mode_we = 0;
    @(negedge clk);

    // ---------------------------------------------------------------
    // The read path first: does the ITF's own shape return what was loaded?
    // A wrong bit order or byte order fails here before any carry is tested.
    // ---------------------------------------------------------------
    set_time(56'h05_26_09_12_12_34_56);          // 2026-09-12 12:34:56, wday 5
    read_clock(s, m, h, d, mw, y);
    $display("read back: sec=%02x min=%02x hour=%02x day=%02x mw=%02x year=%02x",
             s, m, h, d, mw, y);
    if (s !== 8'h56) fail("seconds did not read back through the ITF's reader");
    if (m !== 8'h34) fail("minutes did not read back");
    if (h !== 8'h12) fail("hour did not read back");
    if (d !== 8'h12) fail("day did not read back");
    if (mw !== 8'h95) fail("month|weekday did not read back as 0x95 (month 9, wday 5)");
    if (y !== 8'h26) fail("year did not read back");

    // ---------------------------------------------------------------
    // Carry: second -> minute -> hour, which the existing bench only tests
    // through the internal divider. Same thing, through the reader.
    // ---------------------------------------------------------------
    set_time({8'h05, 8'h26, 8'h09, 8'h12, 8'h12, 8'h59, 8'h59});   // 12:59:59
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (s !== 8'h00) fail("59 seconds did not wrap to 00");
    if (m !== 8'h00 || h !== 8'h13)
      fail("12:59:59 did not carry to 13:00:00");
    if (d !== 8'h12 || mw !== 8'h95) fail("an hour carry moved the date");

    // ---------------------------------------------------------------
    // Midnight: the day advances and the weekday advances with it.
    // ---------------------------------------------------------------
    set_time(at_midnight(8'h12, 8'h09, 8'h26, 8'h05));             // 2026-09-12
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (s !== 8'h00 || m !== 8'h00 || h !== 8'h00)
      fail("midnight did not clear sec/min/hour");
    if (d !== 8'h13) fail("2026-09-12 did not advance to day 13");
    if (mw !== 8'h96) fail("weekday did not advance with the date");
    if (mw[3:0] > 4'd6) fail("weekday left the 0..6 range");

    // ---------------------------------------------------------------
    // Month end, including the February that catches a fixed-28 rule.
    // ---------------------------------------------------------------
    set_time(at_midnight(8'h31, 8'h01, 8'h26, 8'h05));             // 2026-01-31
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'h2)
      fail("2026-01-31 did not roll to February 1");

    // Day 30, NOT 31: this case used to load April 31, which rolls to May 1 under a
    // 31-day April too, so it could not see the 30-day month it names.
    set_time(at_midnight(8'h30, 8'h04, 8'h26, 8'h05));             // 2026-04-30
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'h5)
      fail("2026-04-30 (30-day month) did not roll to May 1");

    // ...and the 30th of a 31-day month does NOT roll (the other side of the same table).
    set_time(at_midnight(8'h30, 8'h07, 8'h26, 8'h05));             // 2026-07-30
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h31 || mw[7:4] !== 4'h7)
      fail("2026-07-30 (31-day month) did not advance to July 31");

    set_time(at_midnight(8'h28, 8'h02, 8'h26, 8'h05));             // 2026-02-28
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'h3)
      fail("2026-02-28 (not a leap year: 2026 mod 4 = 2) did not roll to March 1");

    set_time(at_midnight(8'h28, 8'h02, 8'h24, 8'h05));             // 2024-02-28
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h29 || mw[7:4] !== 4'h2)
      fail("2024-02-28 (leap year: 2024 mod 4 = 0) did not roll to February 29");

    // The leap test is on the BCD year's DECIMAL value: 2024 and 2026 read the same
    // as binary 0x24 (36) and 0x26 (38), so a rule that tests the raw byte's low bits
    // passes both. 2012 (0x12 = 18 binary, mod 4 = 2) and 2018 (0x18 = 24, mod 4 = 0)
    // are the years where the two rules disagree.
    set_time(at_midnight(8'h28, 8'h02, 8'h12, 8'h05));             // 2012-02-28
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h29 || mw[7:4] !== 4'h2)
      fail("2012-02-28 (leap year: 2012 mod 4 = 0, BCD 0x12) did not roll to February 29");

    set_time(at_midnight(8'h28, 8'h02, 8'h18, 8'h05));             // 2018-02-28
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'h3)
      fail("2018-02-28 (not a leap year: 2018 mod 4 = 2, BCD 0x18) did not roll to March 1");

    set_time(at_midnight(8'h29, 8'h02, 8'h24, 8'h05));             // 2024-02-29
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'h3)
      fail("the leap day 2024-02-29 did not roll to March 1");

    set_time(at_midnight(8'h28, 8'h02, 8'h00, 8'h05));             // 2000-02-28
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h29 || mw[7:4] !== 4'h2)
      fail("2000-02-28 (a century that IS a leap year) did not roll to February 29");

    // ---------------------------------------------------------------
    // Year end.
    // ---------------------------------------------------------------
    set_time(at_midnight(8'h31, 8'h12, 8'h26, 8'h05));             // 2026-12-31
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'h1)
      fail("2026-12-31 did not roll to January 1");
    if (y !== 8'h27) fail("the year did not advance from 2026 to 2027");

    // ---------------------------------------------------------------
    // October, November, December. The month|weekday byte's HIGH nibble is the
    // month's DECIMAL value (NP2kai packs `(month << 4) + week`, calendar.c:177,
    // and reads back `bcd[1] >> 4`), so the three months past September must
    // emit 0xA/0xB/0xC. Slicing c_month[3:0] (the packed BCD month) gave 0/1/2.
    // ---------------------------------------------------------------
    set_time(at_midnight(8'h15, 8'h10, 8'h26, 8'h05));             // 2026-10-15
    read_clock(s, m, h, d, mw, y);
    if (mw[7:4] !== 4'hA) fail("October emitted the wrong month nibble (want 0xA)");
    if (d !== 8'h15) fail("reading October moved the day");

    set_time(at_midnight(8'h31, 8'h10, 8'h26, 8'h05));             // 2026-10-31, 31 days
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'hB)
      fail("2026-10-31 did not roll to November (want month nibble 0xB)");

    set_time(at_midnight(8'h30, 8'h11, 8'h26, 8'h05));             // 2026-11-30
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'hC)
      fail("2026-11-30 did not roll to December (want month nibble 0xC)");

    // ---------------------------------------------------------------
    // BCD validity of every field, at every boundary just walked, so a
    // binary (non-BCD) increment cannot pass on the cases above.
    // ---------------------------------------------------------------
    set_time(at_midnight(8'h09, 8'h06, 8'h26, 8'h05));
    tick_once;
    read_clock(s, m, h, d, mw, y);
    check_bcd("seconds", s); check_bcd("minutes", m); check_bcd("hour", h);
    check_bcd("day", d);     check_bcd("year", y);
    if (d !== 8'h10) fail("2026-06-09 did not advance to BCD 10, not 0A");

    // ---------------------------------------------------------------
    // The weekday must wrap within 0..6 rather than counting BCD.
    // ---------------------------------------------------------------
    set_time(at_midnight(8'h12, 8'h09, 8'h26, 8'h06));             // wday 6 = last
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (mw[3:0] !== 4'h0) fail("weekday 6 did not wrap to 0");
    if (mw[7:4] !== 4'h9) fail("the month changed when only the weekday should have");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CALENDAR_ROLLOVER: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CALENDAR_ROLLOVER: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "TB_PC9821_CALENDAR_ROLLOVER: FAIL (timed out - a task blocked)");
  end

endmodule
