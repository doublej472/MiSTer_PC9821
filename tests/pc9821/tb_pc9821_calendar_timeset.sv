`timescale 1ns/1ps

// tb_pc9821_calendar_timeset - the uPD4990A TIMESET command (opcode 2) and the
// month|weekday field it writes, driven by the machine's OWN writer, byte for
// byte (bios/xe10/BANK7.BIN @0x5D62: opcode 1 SHIFT, 48 data bits, opcode 2 time
// set, opcode 0 hold; docs/probes/TRS.TXT is the machine running it).
//
// The data bits are presented the way that writer presents them - the 3-bit
// field held at 7, the serial command channel, for the payload too, with only
// bit 5 (DATA) changing:
//   5d62  mov ah,1 ; call 0x5DA2       ; opcode 1 SHIFT
//   5d76  mov al,0x07                  ; field 7, DATA 0
//   5d7a  mov al,0x27                  ; field 7, DATA 1
//   5d81  or  al,0x10 ; out 0x20,al    ; CLK high, DATA still asserted
// That is the point of this bench. An earlier version sent the payload with the
// field held OFF 7 and so drove a sequence no machine issues - the fixture
// encoded the same assumption the RTL did, which is why it passed on RTL that
// cannot load the time the machine's own writer sends.
//
// docs/probes/TRS.TXT:209-213 - which is /TIMESET on the real machine - reports
// "fields matching the written pattern (bit0/bit4) = 06 00 of 6", so the round
// trip DID work; that machine's counters then did not TICK, which is the
// battery/counter-hold observation, not a failed write.
//
// The field layout is NP2kai's: NP2kai io/upd4990.c cmd 3 does `calendar_get(reg + REGLEN-6)` and calendar.c
// date2bcd fills reg[2..7] = year, (month<<4)|week, day, hour, minute, second;
// the chip shifts reg[7] out first, so the WIRE order is seconds-first, then
// month|weekday, then year. The month is the byte's HIGH nibble and holds the
// month's DECIMAL value (1..12, so Oct..Dec are 0xA/0xB/0xC), read back by
// NP2kai as `bcd[1] >> 4` and packed as `(month << 4) + week`.
//
// This is the path no bench drove at all before: an earlier check found the module read the
// month range off [43:40] - the YEAR's low BCD digit - and stored the whole
// month|weekday byte into c_month, so a time whose year ended in 0 was silently
// dropped and a stored month re-emitted the weekday twice.

// ==== WHAT THIS PROVES ====
// TB_PC9821_CALENDAR_TIMESET: The uPD4990A TIMESET command (opcode 2) loads the counters from the 48-bit input stream the machine's own writer sends - bios/xe10/BANK7.BIN@0x5D62 (and docs/probes/TRS.TXT running it), opcode 1 SHIFT, 48 data bits, opcode 2 - and the time reads back through the ITF's own 48-clock reader unchanged. The payload bits are presented the way that writer presents them: the 3-bit field is held at 7, the serial command channel, with only bit 5 (DATA) changing (0x07/0x27), so an input accumulator gated on the field drops every payload bit and the time never loads. It pins the two field decodes the old code got wrong: the month lives in the HIGH nibble of the month|weekday byte at [39:36] (not the year's low BCD digit at [43:40]), so a write is no longer dropped when the year ends in 0; and the month is stored and re-emitted as its DECIMAL value (NP2kai's `(month << 4) | week`), so October, November and December round-trip as 0xA/0xB/0xC where the old low-nibble slice gave 0/1/2. A time set in October, November or December then CARRIES like a framework-loaded date (2026-10-31 23:59:59 rolls to November 1, 2026-11-30 to December 1, 2026-12-31 to January 1 of 2027): the stored month is internal packed BCD (0x10/0x12), which the round-trip reads cannot see, so a month stored as its binary value 0xA/0xC re-emits correctly yet breaks the day and year carry. THE CHIP REFUSES NO SET: the Xe10's own fourteen XE10Z /CAL sets (docs/probes/XE10Z-XE10.TXT:234-247) are replayed after the probe's BASE set, and every byte of each read at once and one and two seconds later is the capture's - a seconds units digit past 9 clears and carries into the tens and a tens past 5 carries a minute (5A reads 00 with the minute 30 -> 31, 3F reads 40), the other fields fold without a carry (minute 60 -> 00, hour 24 -> 00, day 2A -> 20, month 13 -> 1, year A0 -> 00, weekday 7 -> 0), day 32, day 00 and month 0 load as sent, and a day at or past its month's length rolls to 01 (day 32 in June, Feb 30 2020); FAIL-FIRST, the core refused eight of the rows and loaded four unfolded. And the set restarts the second: a set 20 ms before a tick of the running second still reads its own time 100 ms later, as the capture's 28 reads 1.1 s apart each moved exactly one second (FAIL-FIRST: the running divider ticked first).

module tb_pc9821_calendar_timeset;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // The framework RTC: 2026-09-12 12:34:56, weekday 5. Loaded once, so a time set that
  // did not load shows up as this baseline rather than as zeros.
  reg  [55:0] rtc_bcd = 56'h05_26_09_12_12_34_56;
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
      .tick_we(tick_we), .tick_din(tick_din), .tick_dout(tick_dout),
      .tick_rd(tick_rd),
      .cdat(cdat), .irq(irq));
  // ==== STIMULUS ====

  // One second, forced across the 1 Hz boundary: the divider's own length is not what
  // this bench checks (tb_pc9821_calendar_rollover admits the same shortcut).
  task tick_once;
    begin
      @(negedge clk);
      dut.hz_div = 27'd49_999_999;
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  task fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  // Writes are set up on the falling edge so the DUT samples them at the
  // following rising edge, one value per clock: a write placed *at* the posedge
  // races the DUT's own edge detector.
  task cal_write(input [7:0] d);
    begin
      @(negedge clk);
      cmd_din = d; cmd_we = 1;
      @(negedge clk);
      cmd_we = 0;
    end
  endtask

  task cal_mode(input [7:0] d);
    begin
      @(negedge clk);
      mode_din = d; mode_we = 1;
      @(negedge clk);
      mode_we = 0;
    end
  endtask

  // The firmware's send routine (BANK7@0x5DA2): the 3-bit field is held at 7, each
  // opcode bit goes out on DATA (bit 5) LSB-first with a CLK rising edge, then a
  // STB pulse latches the command from the serial register.
  task send_serial(input [3:0] opcode);
    integer i;
    reg [3:0] ah;
    reg [7:0] al;
    begin
      ah = opcode;
      for (i = 0; i < 4; i = i + 1) begin
        al = ah[0] ? 8'h27 : 8'h07;   // DATA, field 7, CLK low
        cal_write(al);
        cal_write(al | 8'h10);        // CLK rising, field still 7
        ah = ah >> 1;
      end
      al = al & 8'hEF;                // CLK low
      cal_write(al);
      cal_write(al | 8'h08);          // STB rising latches the command
      cal_write(al & 8'hF7);          // STB falling
    end
  endtask

  // One payload bit, exactly as the machine's own writer presents it
  // (BANK7@0x5D76-0x5D8E): the field held at 7 - the serial command channel -
  // with the bit on DATA (bit 5), then a CLK rise and fall. The RTL takes
  // cmd_din[5] on the rising edge whatever the field is; a field-gated
  // accumulator takes nothing here and this bench fails.
  task send_data_bit(input b);
    begin
      cal_write(b ? 8'h27 : 8'h07);   // DATA presented, field 7, CLK low
      cal_write(b ? 8'h37 : 8'h17);   // CLK rising: the accumulator takes bit 5
      cal_write(b ? 8'h27 : 8'h07);   // CLK falling
    end
  endtask

  // The 48 payload bits: LSB-first per byte, seconds byte first, month|weekday
  // then year, the order the reader walks out (BANK7@0x5D22; NP2kai date2bcd).
  task send_time(input [7:0] sec, input [7:0] min, input [7:0] hour,
                 input [7:0] day, input [7:0] mw,  input [7:0] year);
    integer i, k;
    reg [7:0] f [0:5];
    begin
      f[0] = sec; f[1] = min; f[2] = hour; f[3] = day; f[4] = mw; f[5] = year;
      for (i = 0; i < 6; i = i + 1)
        for (k = 0; k < 8; k = k + 1)
          send_data_bit(f[i][k]);
    end
  endtask

  // The machine's /TIMESET sequence: SHIFT first (which clears the input
  // accumulator), the 48 data bits, then TIMESET to latch them, then hold.
  task timeset(input [7:0] sec, input [7:0] min, input [7:0] hour,
               input [7:0] day, input [7:0] mw,  input [7:0] year);
    begin
      send_serial(4'd1);
      send_time(sec, min, hour, day, mw, year);
      send_serial(4'd2);
      send_serial(4'd0);
    end
  endtask

  // The ITF's reader (BANK7@0x5D22): TIMEREAD latches the counters and SHIFT arms
  // the walk, then 8 clocks per byte assemble with the shr/rcr pair so the first
  // bit out lands in bit 0. The module emits the payload first (no prefix), so the
  // six bytes are seconds, minutes, hour, day, month|weekday, year.
  task read_clock(output [7:0] sec, output [7:0] min, output [7:0] hour,
                  output [7:0] day, output [7:0] mw,  output [7:0] year);
    integer i, k;
    reg [7:0] b;
    reg [7:0] got [0:5];
    begin
      send_serial(4'd3);
      send_serial(4'd1);
      for (i = 0; i < 6; i = i + 1) begin
        b = 8'h00;
        for (k = 0; k < 8; k = k + 1) begin
          b[k] = cdat;             // sample before the clock advances
          cal_write(8'h17);        // CLK rising, field 7
          cal_write(8'h07);        // CLK falling
        end
        got[i] = b;
      end
      sec = got[0]; min = got[1]; hour = got[2];
      day = got[3]; mw  = got[4]; year = got[5];
    end
  endtask

  reg [7:0] s, m, h, d, mw, y;
  // XE10Z /CAL rows P0..P13, docs/probes/XE10Z-XE10.TXT:234-247, as the capture prints them
  // (wire order: sec, min, hour, day, month|weekday, year).
  reg [47:0] xz_set [0:13];
  reg [47:0] xz_r0 [0:13];
  reg [47:0] xz_r1 [0:13];
  reg [47:0] xz_r2 [0:13];
  initial begin
    xz_set[0] = 48'h58592331C599; xz_r0[0] = 48'h58592331C599; xz_r1[0] = 48'h59592331C599; xz_r2[0] = 48'h000000011600;
    xz_set[1] = 48'h5A3012156320; xz_r0[1] = 48'h003112156320; xz_r1[1] = 48'h013112156320; xz_r2[1] = 48'h023112156320;
    xz_set[2] = 48'h3F3012156320; xz_r0[2] = 48'h403012156320; xz_r1[2] = 48'h413012156320; xz_r2[2] = 48'h423012156320;
    xz_set[3] = 48'h586012156320; xz_r0[3] = 48'h580012156320; xz_r1[3] = 48'h590012156320; xz_r2[3] = 48'h000112156320;
    xz_set[4] = 48'h585924156320; xz_r0[4] = 48'h585900156320; xz_r1[4] = 48'h595900156320; xz_r2[4] = 48'h000001156320;
    xz_set[5] = 48'h585923326320; xz_r0[5] = 48'h585923326320; xz_r1[5] = 48'h595923326320; xz_r2[5] = 48'h000000017420;
    xz_set[6] = 48'h003012006320; xz_r0[6] = 48'h003012006320; xz_r1[6] = 48'h013012006320; xz_r2[6] = 48'h023012006320;
    xz_set[7] = 48'h585923302120; xz_r0[7] = 48'h585923302120; xz_r1[7] = 48'h595923302120; xz_r2[7] = 48'h000000013220;
    xz_set[8] = 48'h585923282121; xz_r0[8] = 48'h585923282121; xz_r1[8] = 48'h595923282121; xz_r2[8] = 48'h000000013221;
    xz_set[9] = 48'h5859232A6320; xz_r0[9] = 48'h585923206320; xz_r1[9] = 48'h595923206320; xz_r2[9] = 48'h000000216420;
    xz_set[10] = 48'h00301215D320; xz_r0[10] = 48'h003012151320; xz_r1[10] = 48'h013012151320; xz_r2[10] = 48'h023012151320;
    xz_set[11] = 48'h003012150320; xz_r0[11] = 48'h003012150320; xz_r1[11] = 48'h013012150320; xz_r2[11] = 48'h023012150320;
    xz_set[12] = 48'h0030121563A0; xz_r0[12] = 48'h003012156300; xz_r1[12] = 48'h013012156300; xz_r2[12] = 48'h023012156300;
    xz_set[13] = 48'h003012156720; xz_r0[13] = 48'h003012156020; xz_r1[13] = 48'h013012156020; xz_r2[13] = 48'h023012156020;
  end

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    rtc_load = 1;
    @(negedge clk);
    rtc_load = 0;
    repeat (4) @(posedge clk);

    // The baseline the framework loaded, before any TIMESET. September so its month
    // nibble (9) is one the old low-nibble slice happened to get right.
    read_clock(s, m, h, d, mw, y);
    if (s !== 8'h56 || m !== 8'h34 || h !== 8'h12 ||
        d !== 8'h12 || mw !== 8'h95 || y !== 8'h26)
      fail("the framework RTC did not read back before any time set");

    // ---------------------------------------------------------------
    // TIMESET, October, year ending in 0. Both old defects bite here: the month
    // range was read off [43:40] (the year's low digit, 0) so the write was
    // dropped, and the stored month was the whole month|weekday byte.
    // ---------------------------------------------------------------
    timeset(8'h34, 8'h12, 8'h23, 8'h28, 8'hA5, 8'h20);   // 2020-10-28, wday 5
    read_clock(s, m, h, d, mw, y);
    $display("timset Oct: sec=%02x min=%02x hour=%02x day=%02x mw=%02x year=%02x",
             s, m, h, d, mw, y);
    if (s !== 8'h34) fail("TIMESET did not load seconds");
    if (m !== 8'h12) fail("TIMESET did not load minutes");
    if (h !== 8'h23) fail("TIMESET did not load the hour");
    if (d !== 8'h28) fail("TIMESET did not load the day");
    if (mw !== 8'hA5) fail("October did not round-trip as month 0xA (year ended in 0)");
    if (y !== 8'h20) fail("TIMESET did not load the year");

    // ---------------------------------------------------------------
    // November and December: the month nibble must carry the DECIMAL value
    // 0xB and 0xC, where slicing c_month[3:0] gave 1 and 2.
    // ---------------------------------------------------------------
    timeset(8'h03, 8'h02, 8'h01, 8'h05, 8'hB2, 8'h26);   // 2026-11-05, wday 2
    read_clock(s, m, h, d, mw, y);
    $display("timset Nov: sec=%02x min=%02x hour=%02x day=%02x mw=%02x year=%02x",
             s, m, h, d, mw, y);
    if (s !== 8'h03 || m !== 8'h02 || h !== 8'h01 || d !== 8'h05 ||
        mw !== 8'hB2 || y !== 8'h26)
      fail("November did not round-trip as month 0xB");

    timeset(8'h00, 8'h00, 8'h00, 8'h31, 8'hC6, 8'h26);   // 2026-12-31, wday 6
    read_clock(s, m, h, d, mw, y);
    $display("timset Dec: sec=%02x min=%02x hour=%02x day=%02x mw=%02x year=%02x",
             s, m, h, d, mw, y);
    if (s !== 8'h00 || m !== 8'h00 || h !== 8'h00 || d !== 8'h31 ||
        mw !== 8'hC6 || y !== 8'h26)
      fail("December did not round-trip as month 0xC");

    // ---------------------------------------------------------------
    // A month of 0 is LOADED as sent: the Xe10's chip refuses no set (XE10Z /CAL P11,
    // docs/probes/XE10Z-XE10.TXT:245 `set=003012150320 r0=003012150320`). The year's low
    // BCD digit here is 6, so this also pins that the month is read from [39:36].
    // ---------------------------------------------------------------
    timeset(8'h07, 8'h07, 8'h07, 8'h07, 8'h05, 8'h26);   // month nibble 0
    read_clock(s, m, h, d, mw, y);
    if (mw !== 8'h05 || d !== 8'h07 || y !== 8'h26 || s !== 8'h07)
      fail("a TIMESET with month 0 was not loaded as sent (XE10Z P11)");
    timeset(8'h00, 8'h00, 8'h00, 8'h31, 8'hC6, 8'h26);   // back to 2026-12-31, wday 6

    // ---------------------------------------------------------------
    // A short stream (fewer than 48 data bits) must not load a date.
    // ---------------------------------------------------------------
    send_serial(4'd1);
    send_data_bit(1'b1);            // one bit only, then the time-set (5 clocks
                                    // in all, the SHIFT opcode's four having been
                                    // cleared by its own STB)
    send_serial(4'd2);
    send_serial(4'd0);
    read_clock(s, m, h, d, mw, y);
    if (mw !== 8'hC6 || d !== 8'h31 || y !== 8'h26)
      fail("a TIMESET with fewer than 48 data bits was applied");

    // ---------------------------------------------------------------
    // A TIMESET date must CARRY like a framework-loaded one. The stored month is
    // internal packed BCD (0x10 for October, 0x12 for December), which the
    // round-trip reads above cannot see: a month stored as its binary value (0x0A,
    // 0x0C) still re-emits as 0xA/0xC. It shows only when the counters carry, as
    // the month length and the December-to-January rule read the stored month.
    // Expected values are the calendar's own rule (as tb_pc9821_calendar_rollover:
    // October has 31 days, December rolls into January of the next year).
    // ---------------------------------------------------------------
    timeset(8'h59, 8'h59, 8'h23, 8'h31, 8'hA5, 8'h26);   // 2026-10-31 23:59:59
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'hB || y !== 8'h26 || h !== 8'h00)
      fail("a TIMESET 2026-10-31 23:59:59 did not roll to November 1");

    timeset(8'h59, 8'h59, 8'h23, 8'h31, 8'hC5, 8'h26);   // 2026-12-31 23:59:59
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'h1 || y !== 8'h27)
      fail("a TIMESET 2026-12-31 23:59:59 did not roll to January 1 of 2027");

    timeset(8'h59, 8'h59, 8'h23, 8'h30, 8'hB5, 8'h26);   // 2026-11-30 23:59:59
    tick_once;
    read_clock(s, m, h, d, mw, y);
    if (d !== 8'h01 || mw[7:4] !== 4'hC || y !== 8'h26)
      fail("a TIMESET 2026-11-30 (30-day month) did not roll to December 1");

    // ---------------------------------------------------------------
    // THE XE10'S OWN SETS (XE10Z /CAL, docs/probes/XE10Z-XE10.TXT:234-247): for each row the
    // probe's BASE set (10:00:00, day 10, month A weekday 1, year 10), then the row's pattern,
    // then a read at once (r0) and one and two seconds later (r1, r2; the probe reads at
    // +1.1 s and +2.2 s, here one forced tick apart). Every expected byte is the capture's.
    // FAIL-FIRST: the core refused P1, P3-P6, P10, P11 (r0 = the BASE) and loaded P2, P9,
    // P12 and P13 without the chip's fold (3F, 2A, A0 and weekday 7 read back as sent).
    // ---------------------------------------------------------------
    for (integer r = 0; r < 14; r = r + 1) begin
      timeset(8'h00, 8'h00, 8'h10, 8'h10, 8'hA1, 8'h10);
      timeset(xz_set[r][47:40], xz_set[r][39:32], xz_set[r][31:24],
              xz_set[r][23:16], xz_set[r][15:8],  xz_set[r][7:0]);
      read_clock(s, m, h, d, mw, y);
      if ({s, m, h, d, mw, y} !== xz_r0[r]) begin
        $display("XE10Z P%0d: set %012x r0 %02x%02x%02x%02x%02x%02x, the Xe10 read %012x",
                 r, xz_set[r], s, m, h, d, mw, y, xz_r0[r]);
        fail("an XE10Z /CAL set did not read back (r0) as the Xe10's");
      end
      tick_once;
      read_clock(s, m, h, d, mw, y);
      if ({s, m, h, d, mw, y} !== xz_r1[r]) begin
        $display("XE10Z P%0d: r1 %02x%02x%02x%02x%02x%02x, the Xe10 read %012x",
                 r, s, m, h, d, mw, y, xz_r1[r]);
        fail("an XE10Z /CAL set did not count (r1) as the Xe10's");
      end
      tick_once;
      read_clock(s, m, h, d, mw, y);
      if ({s, m, h, d, mw, y} !== xz_r2[r]) begin
        $display("XE10Z P%0d: r2 %02x%02x%02x%02x%02x%02x, the Xe10 read %012x",
                 r, s, m, h, d, mw, y, xz_r2[r]);
        fail("an XE10Z /CAL set did not count (r2) as the Xe10's");
      end
    end

    // ---------------------------------------------------------------
    // THE SET RESTARTS THE SECOND. Every one of the Xe10's 28 reads 1.1 s apart after a set
    // moved exactly one second (docs/probes/XE10Z-XE10.TXT:234-247), whatever the set's phase
    // in the running second. A set placed 20 ms before a tick of a free-running divider
    // reads, 100 ms later, the time it set (FAIL-FIRST: the running divider ticked 20 ms
    // after the set and the read was one second on).
    // ---------------------------------------------------------------
    timeset(8'h00, 8'h30, 8'h12, 8'h15, 8'h63, 8'h20);
    @(negedge clk);
    dut.hz_div = 27'd49_000_000;      // 20 ms before the next tick of the running second
    timeset(8'h20, 8'h30, 8'h12, 8'h15, 8'h63, 8'h20);
    repeat (5_000_000) @(posedge clk);   // 100 ms
    read_clock(s, m, h, d, mw, y);
    if (s !== 8'h20) fail("a set did not restart the second: it moved within 100 ms");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CALENDAR_TIMESET: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CALENDAR_TIMESET: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_CALENDAR_TIMESET: timeout");
  end

endmodule
