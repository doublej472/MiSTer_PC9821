// tb_pc9821_calendar — the uPD4990A/4993A serial calendar, driven the way the
// machine's firmware drives it.
//
// Both command forms are exercised. The serial form is the one the AUTHENTIC
// BIOS uses: `send_serial` below replays the exact 0x20 byte stream of its send
// routine (BANK7@0x5DA2) -- the field held at 7, the four opcode bits LSB-first
// on DATA with a CLK each, then the STB pulse. The parallel form writes the
// command in the field bits directly. Both are cross-checked against NP2kai
// io/upd4990.c and, where they agree, QEMU hw/misc/pc98-sys.c; the sequences are
// deliberately NOT taken from any firmware vendored in this tree, because our
// own code is not an oracle for what the hardware does.
//
//   * a rising edge of STB (0x20 bit 3) latches the command: from bits 2:0 when
//     the field is 1/2/3, or from the serial register when the field is 7
//   * a rising edge of CLK (bit 4) advances the shift register
//   * TIMEREAD latches the counters but does not start the shift; SHIFT does
//     (NP2kai io/upd4990.c:33-49), which is why the firmware's read sends both
//   * uPD4993A mode (0x22 bit 5) prefixes the 48 payload bits with four zeros
//   * each byte is emitted least significant bit first, seconds byte first
//
// The reader assembles each byte with its shr/rcr pair, so the first bit out is
// the LSB of the field; the byte order and the bit order within a byte both have
// to be exactly right or every field is wrong in a way that still looks like a
// plausible date.
`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CALENDAR:
// Both uPD4990A/4993A command forms. The serial form is the one the authentic BIOS uses: `send_serial` replays the exact 0x20 byte stream of its send routine (BANK7@0x5DA2, field held at 7, four opcode bits LSB-first on DATA with a CLK each, then an STB pulse) and the clock is read back through the firmware's own 0x33/shr/rcr loop. Also the parallel form's LSB-first bit order (BANK7@0x5D34), the reset and measured register values, and the tick-clear behaviour. The 4993A four-bit prefix vs suffix is an open question and is not settled here; the read uses the module's documented zero prefix.


module tb_pc9821_calendar;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // Fixed BCD time: 2026-09-12 12:34:56, Friday. The framework's RTC arrives in
  // this exact field order (seconds first), which is why no date arithmetic is
  // needed anywhere in the module.
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

  task fail(input [8*72-1:0] message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  // Writes are set up on the falling edge so the DUT samples them at the
  // following rising edge, and held for a full cycle: driving them *at* the
  // posedge races the DUT's own clocked logic.
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

  task cal_tick(input [7:0] d);
    begin
      @(negedge clk);
      tick_din = d; tick_we = 1;
      @(negedge clk);
      tick_we = 0;
    end
  endtask

  // The firmware's send routine (BANK7@0x5DA2), byte for byte: the 3-bit field
  // is held at 7, each opcode bit goes out on DATA (bit 5) LSB-first with a CLK
  // rising edge, and then a STB pulse latches the command from the serial
  // register. `al` tracks the last DATA/CLK byte exactly as the routine's own
  // register does.
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

  // The firmware's read loop (BANK7@0x5D3A-0xDD51): each bit is sampled from
  // 0x33 bit 0, a CLK rising edge walks the shift register on, and the byte is
  // assembled with the shr/rcr pair so the first bit out lands in bit 0.
  // `clk_hi`/`clk_lo` are the CLK-high and CLK-low 0x20 bytes: the parallel
  // reader uses 0x13/0x03, the authentic firmware's serial reader 0x17/0x07.
  // `skip` is the number of leading bits to discard: four in uPD4993A mode, none
  // in the plain uPD4990A form.
  task read_fields(input integer skip, input [7:0] clk_hi, input [7:0] clk_lo,
                   output [7:0] f0, output [7:0] f1, output [7:0] f2,
                   output [7:0] f3, output [7:0] f4, output [7:0] f5);
    integer i, b;
    reg [7:0] acc;
    reg       bitv;
    begin
      for (i = 0; i < skip; i = i + 1) begin
        cal_write(clk_hi);
        cal_write(clk_lo);
      end
      for (b = 0; b < 6; b = b + 1) begin
        acc = 8'h00;
        for (i = 0; i < 8; i = i + 1) begin
          bitv = cdat;           // sample before the clock advances
          cal_write(clk_hi);     // rising CLK advances the shift register
          cal_write(clk_lo);
          acc = (acc >> 1) | (bitv << 7);   // the firmware's shrb/rcrb pair
        end
        case (b)
          0: f0 = acc;   // seconds
          1: f1 = acc;   // minutes
          2: f2 = acc;   // hour
          3: f3 = acc;   // day
          4: f4 = acc;   // month | weekday
          5: f5 = acc;   // year
        endcase
      end
    end
  endtask

  // The parallel form: the command is the field bits of the STB write. It sends
  // TIMEREAD then SHIFT, as the part requires.
  task read_clock(input integer skip, output [7:0] f0, output [7:0] f1,
                  output [7:0] f2, output [7:0] f3, output [7:0] f4,
                  output [7:0] f5);
    begin
      cal_write(8'h0b);          // TIMEREAD | STB: rising STB takes the command
      cal_write(8'h03);          // TIMEREAD: STB falls
      cal_write(8'h09);          // SHIFT | STB
      cal_write(8'h01);          // SHIFT: STB falls, the output shift is armed
      read_fields(skip, 8'h13, 8'h03, f0, f1, f2, f3, f4, f5);
    end
  endtask

  // The serial form, exactly as the authentic firmware issues it: opcode 3
  // (TIMEREAD) then opcode 1 (SHIFT), then the read loop with the firmware's own
  // 0x17/0x07 CLK bytes.
  task firmware_read_clock(output [7:0] f0, output [7:0] f1,
                           output [7:0] f2, output [7:0] f3, output [7:0] f4,
                           output [7:0] f5);
    begin
      send_serial(4'h3);
      send_serial(4'h1);
      read_fields(0, 8'h17, 8'h07, f0, f1, f2, f3, f4, f5);
    end
  endtask

  // Sample the serial stream IN EMISSION ORDER -- first bit out becomes the
  // highest bit -- so the test can assert the ORDER itself. The defect this
  // catches is an order defect, and a check on sreg's value would pass on either
  // arm; only the emitted sequence pins it. The authentic reader takes exactly
  // 48 clocks (BANK7@0x5D22), so the payload must occupy the FIRST 48 out and
  // anything the uPD4993A form adds must come AFTER it.
  task read_stream(output [51:0] bits);
    integer i;
    begin
      bits = 52'h0;
      for (i = 0; i < 52; i = i + 1) begin
        bits = (bits << 1) | {51'b0, cdat};
        cal_write(8'h17);              // CLK high
        cal_write(8'h07);              // CLK low
      end
    end
  endtask

  // read_stream puts the FIRST bit out at bit 51, and every byte is emitted LSB
  // first, so each byte reads back bit-reversed in that packing. Reverse them
  // here rather than changing the sampler: the sampler mirrors the wire, and the
  // reversal is a property of how the part sends a byte.
  function [7:0] brev(input [7:0] v);
    brev = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
  endfunction
  // SECONDS FIRST. emit_payload is DECLARED {year, month|wday, day, hour, min,
  // sec}, so sec sits at its LOW end -- and sreg[0], which leaves first, takes
  // emit_payload[0]. So the emission order is the reverse of the declaration
  // order, and writing this expectation in declaration order is the same mistake
  // the RTL's time-set mapping made. Four bits of the extended form come LAST:
  // NP2kai reg[1] = 0x01 (io/upd4990.c:43-49), i.e. 1,0,0,0, which the machine's
  // TRS.TXT 52-bit captures also end with.
  wire [51:0] want_stream = {brev(8'h56), brev(8'h34), brev(8'h12),
                             brev(8'h12), brev(8'h95), brev(8'h26), 4'b1000};

  reg [51:0] stream;
  reg [7:0] s, m, h, d, mw, y;
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    // The framework sends the RTC once, at core start.
    @(negedge clk);
    rtc_load = 1;
    @(negedge clk);
    rtc_load = 0;
    repeat (4) @(posedge clk);

    // ---------------------------------------------------------------
    // 0x22 and 0x128 as the machine presents them
    // ---------------------------------------------------------------
    // Measured on the real machine: the POST/DOS leave 0x22 = 0xEF, bit 5 set
    // (4993 extended format), where the old reset value was QEMU's 0xFF. Only
    // the read differs; bit 5 is set either way, so the shift-out path is
    // unchanged.
    if (mode_dout !== 8'hEF) fail("0x22 did not power up 0xEF (4993 mode set)");
    if (tick_dout !== 8'h81) fail("0x128 did not power up as 0x81 (1/32 s)");
    if (irq !== 1'b0)        fail("IRQ15 asserted at reset");

    // The BIOS selects the extended format before its first read.
    cal_mode(8'hEF);
    if (mode_dout !== 8'hEF) fail("0x22 mode latch did not store 0xEF");

    // ---------------------------------------------------------------
    // The SERIAL command channel, which is the only form the authentic
    // firmware uses (BANK7@0x5DA2): opcode 3 then opcode 1 over the field-7
    // DATA/CLK/STB sequence, then the firmware's own 0x33 read loop. This runs
    // first so the shift register starts unarmed; a core that decodes only the
    // parallel field never sets `shifting` here and reads six zero bytes.
    // ---------------------------------------------------------------
    firmware_read_clock(s, m, h, d, mw, y);
    $display("serial read: sec=%02x min=%02x hour=%02x day=%02x mw=%02x year=%02x",
             s, m, h, d, mw, y);
    if (s  !== 8'h56) fail("serial TIMEREAD: seconds read back wrong");
    if (m  !== 8'h34) fail("serial TIMEREAD: minutes read back wrong");
    if (h  !== 8'h12) fail("serial TIMEREAD: hour read back wrong");
    if (d  !== 8'h12) fail("serial TIMEREAD: day read back wrong");
    if (mw !== 8'h95) fail("serial TIMEREAD: month|weekday read back wrong");
    if (y  !== 8'h26) fail("serial TIMEREAD: year read back wrong");

    // ---------------------------------------------------------------
    // The parallel read path, uPD4993A mode: four prefix bits then seconds
    // through year, least significant bit first.
    // ---------------------------------------------------------------
    read_clock(0, s, m, h, d, mw, y);
    $display("read: sec=%02x min=%02x hour=%02x day=%02x mw=%02x year=%02x",
             s, m, h, d, mw, y);
    if (s  !== 8'h56) fail("seconds read back wrong");
    if (m  !== 8'h34) fail("minutes read back wrong");
    if (h  !== 8'h12) fail("hour read back wrong");
    if (d  !== 8'h12) fail("day read back wrong");
    if (mw !== 8'h95) fail("month|weekday read back wrong");
    if (y  !== 8'h26) fail("year read back wrong");

    // A second read must give the same date: TIMEREAD re-latches and SHIFT
    // re-arms.
    read_clock(0, s, m, h, d, mw, y);
    if (s !== 8'h56 || y !== 8'h26) fail("second read did not repeat the time");

    // ---------------------------------------------------------------
    // EMISSION ORDER: the payload must come out FIRST and the four extra bits
    // of the extended form must come AFTER it, ending 1,0,0,0 (NP2kai reg[1] =
    // 0x01). This is the check the old arms fail, and the one nothing in the
    // tree made.
    // ---------------------------------------------------------------
    send_serial(4'h3);
    send_serial(4'h1);
    read_stream(stream);
    $display("stream=%013x want=%013x", stream, want_stream);
    if (stream[51:4] !== want_stream[51:4])
      fail("extended read: the payload does not come out first");
    if (stream[3:0] !== 4'b1000)
      fail("extended read: the four extra bits are not the reference's 1,0,0,0");

    // ---------------------------------------------------------------
    // Plain uPD4990A form: no prefix, so the payload starts immediately.
    // ---------------------------------------------------------------
    cal_mode(8'h00);
    read_clock(0, s, m, h, d, mw, y);
    if (s !== 8'h56 || m !== 8'h34 || h !== 8'h12 ||
        d !== 8'h12 || mw !== 8'h95 || y !== 8'h26)
      fail("plain 48-bit form misread");

    // ---------------------------------------------------------------
    // 1 Hz carry chain: 12:34:59 -> 12:35:00, and minute 59 -> hour.
    // ---------------------------------------------------------------
    cal_mode(8'hEF);
    rtc_bcd[7:0] = 8'h59;        // seconds = 59
    @(negedge clk); rtc_load = 1; @(negedge clk); rtc_load = 0;
    // Reach into the 1 Hz divider rather than waiting 50 M cycles (a test-only
    // shortcut; the divider itself is exercised by the reset value and by the
    // tick below).
    @(negedge clk);
    dut.hz_div = 26'd49_999_999;
    repeat (2) @(posedge clk);
    if (dut.c_min !== 8'h35) fail("seconds roll-over did not carry into minutes");

    // ---------------------------------------------------------------
    // Tick rate register and the IRQ it raises.
    // ---------------------------------------------------------------
    cal_tick(8'h82);   // the enable (bit 7) set, as the ITF writes it; tb_pc9821_calendar_xe10 owns bit 7 clear
    if (tick_dout !== 8'h82) fail("0x128 read did not report rate 2 (off)");
    repeat (200) @(posedge clk);
    if (irq !== 1'b0) fail("IRQ15 asserted while the tick is off");
    cal_tick(8'h81);
    if (tick_dout !== 8'h81) fail("0x128 read did not report rate 1");
    // 1/32 s at 50 MHz is 1,562,499 cycles; preset the divider rather than
    // spinning that long.
    @(negedge clk);
    dut.tick_div = 22'd1_562_498;
    repeat (2) @(posedge clk);
    @(negedge clk);
    // The tick sets the tick flag, bit 4 (the Xe10 reads 0x91 with a tick unread,
    // docs/probes/XE10T-XE10-AUDIT.TXT CAL128 `v=91`), and IRQ15 rises at the end of the
    // tick's short low pulse (docs/probes/KIT2-XE10-AUDIT2.TXT:27-41, 1-2 ARTIC ticks low);
    // reading 0x128 clears the flag (0x81 after it) and leaves the line high (`cfg=81 mode=R
    // ... ones=97790`).
    if (irq !== 1'b0) fail("IRQ15 is not low in the tick's pulse");
    if (tick_dout !== 8'h91) fail("0x128 did not report the tick flag (0x91) with a tick unread");
    repeat (300) @(posedge clk);         // the 5 us pulse is 250 clocks at 50 MHz
    if (irq !== 1'b1) fail("the tick did not raise IRQ15 at its pulse's end");
    @(negedge clk); tick_rd = 1;
    @(negedge clk); tick_rd = 0;
    repeat (2) @(posedge clk);
    if (irq !== 1'b1) fail("the 0x128 read lowered IRQ15 (the Xe10's line stays high)");
    if (tick_dout !== 8'h81) fail("the 0x128 read did not clear the tick flag (0x81)");
  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_CALENDAR: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CALENDAR: FAIL (%0d errors)", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_CALENDAR: timeout");
  end

endmodule
