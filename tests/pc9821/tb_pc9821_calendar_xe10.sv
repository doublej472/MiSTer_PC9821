`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CALENDAR_XE10: the calendar's interval interrupt (0x128, IRQ15) answers the real Xe10's XE10T /AUDIT CAL rows through the real pc9821_calendar: with bit 7 set it raises ONE request per tick whether or not the handler reads 0x128 (0x81 = 32 Hz, 0x80 = 64 Hz, 0x83 = 16 Hz: 16, 32 and 8 rising edges in half a second, read or not), 0x82 stops the tick, bit 7 clear (0x00, 0x01) raises nothing while the tick still runs, and the read-back is the written enable and rate with bit 4 the tick flag a read clears (0x91/0x90/0x93 after unread ticks, 0x81/0x80/0x83 after each tick was read, 0x82 stopped, 0x10/0x11 with the interrupt disabled). And the line's shape answers kit 2's /AUDIT2 CALIRR rows (docs/probes/KIT2-XE10-AUDIT2.TXT:27-41) on a 1 MHz instance: after 0x128 <- 81, 80 or 83 and a 0x128 read the line is already high (`first=1`), and over 100 ms it stays high but for one low pulse of at most 7 us per tick (the machine's 1-2 ARTIC ticks), with as many rises as falls, whether nothing reads 0x128 (N) or a read follows every rise (R): the read leaves the line high.
//
// Expected values: docs/probes/XE10T-XE10-AUDIT.TXT, the `X AUDIT CAL cfg=.. mode=R|N n=..
// win=153600 v=..` rows (INT 17h deliveries in 0.5 s with a handler that reads 0x128 (R) and one
// that never does (N), and the 0x128 byte after the window):
//   cfg=81 R n=16 v=81, N n=16 v=91      cfg=80 R n=32 v=80, N n=32 v=90
//   cfg=83 R n=9 v=83,  N n=8 v=93       cfg=82 R n=0 v=82,  N n=0 v=82
//   cfg=00 R n=0 v=10,  N n=0 v=10       cfg=01 R n=0 v=11,  N n=0 v=11
// A count is the machine's +-1 (the window's phase against the tick is free: as found 17/16,
// 0x83 9/8). The edge count stands in for INT 17h: the 8259 is edge-triggered, so a delivery
// needs a rising edge of the line.
//
// CALIRR (kit 2): each row writes its value, reads 0x128 once, then samples the masked slave
// IRR bit 7 (the line) for 100 ms, N or R (a 0x128 read at every rise):
//   cfg=81 mode=N first=1 samples=97792 ones=97789 rises=3 falls=3 e=-5311,+5312,-14912,+14913,..
//   cfg=81 mode=R first=1 ... ones=97790 rises=2 falls=2 e=-8013,+8015,-17615,+17616
//   cfg=80 mode=N first=1 ... ones=97784 rises=7 falls=7 e=-609,+611,-5410,+5411,...
//   cfg=83 mode=N first=1 ... ones=97791 rises=1 falls=1 e=-14994,+14995
// (edges in ARTIC ticks, 3.26 us each). The low runs are 1-2 ticks, so the bench allows 7 us.
//
// FAIL-FIRST: the core held the request until 0x128 was read (one edge in an N window: the
// core's rc6 capture, docs/probes/core/XE10T-CORE-rc6-s3-AUDIT2.TXT, N n=1 at every rate), ticked
// at 64/32 Hz with bit 7 clear (cfg=00 R n=32, cfg=01 R n=16) and read back 0x80 | rate.

`default_nettype none

module tb_pc9821_calendar_xe10;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg        cmd_we = 0, mode_we = 0, tick_we = 0, tick_rd = 0;
  reg  [7:0] cmd_din = 0, mode_din = 0, tick_din = 0;
  wire [7:0] mode_dout, tick_dout;
  wire       cdat, irq;

  // ==== DUT ====
  // A 1600 Hz "clk_sys": 64 Hz is 25 cycles and half a second is 800, so a whole /AUDIT
  // window is bench-sized. The rates are the module's own SYS_CLOCK_HZ-derived dividers.
  localparam integer HZ  = 1600;
  localparam integer WIN = HZ / 2;
  pc9821_calendar #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .rst_n(rst_n),
      .rtc_bcd(56'd0), .rtc_load(1'b0),
      .cmd_we(cmd_we), .cmd_din(cmd_din),
      .mode_we(mode_we), .mode_din(mode_din), .mode_dout(mode_dout),
      .tick_we(tick_we), .tick_rd(tick_rd), .tick_din(tick_din), .tick_dout(tick_dout),
      .cdat(cdat), .irq(irq));

  // The CALIRR instance: a 1 MHz clk_sys, so a 5 us pulse is 5 cycles and 100 ms is 100000.
  localparam integer HZ2 = 1_000_000;
  reg        t2_we = 0, t2_rd = 0;
  reg  [7:0] t2_din = 0;
  wire [7:0] t2_mode_dout, t2_dout;
  wire       t2_cdat, irq2;
  pc9821_calendar #(.SYS_CLOCK_HZ(HZ2)) dut2 (
      .clk(clk), .rst_n(rst_n),
      .rtc_bcd(56'd0), .rtc_load(1'b0),
      .cmd_we(1'b0), .cmd_din(8'h00),
      .mode_we(1'b0), .mode_din(8'h00), .mode_dout(t2_mode_dout),
      .tick_we(t2_we), .tick_rd(t2_rd), .tick_din(t2_din), .tick_dout(t2_dout),
      .cdat(t2_cdat), .irq(irq2));

  integer errors = 0;

  // ==== STIMULUS ====
  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic write_128(input [7:0] d);
    begin
      @(negedge clk); tick_din = d; tick_we = 1;
      @(negedge clk); tick_we = 0;
    end
  endtask

  task automatic read_128(output [7:0] d);
    begin
      @(negedge clk); tick_rd = 1; d = tick_dout;
      @(negedge clk); tick_rd = 0;
    end
  endtask

  // One /AUDIT CAL row: write the setting, then count IRQ15's rising edges over half a
  // second; with `rd` set a "handler" reads 0x128 a few cycles after each rising edge (the
  // probe's mode R), else nothing reads it (mode N). `after` is the byte read at the end.
  task automatic cal_row(input [7:0] cfg, input bit rd, output integer n, output [7:0] after);
    time t_end;
    reg prev;
    reg [7:0] junk;
    begin
      write_128(cfg);
      n = 0;
      prev = irq;
      t_end = $time + WIN * 10;            // half a second of 10 ns clocks
      while ($time < t_end) begin
        @(posedge clk); #1;
        if (irq && !prev) begin
          n = n + 1;
          if (rd) begin
            repeat (2) @(posedge clk);
            read_128(junk);
          end
        end
        prev = irq;
      end
      read_128(after);
    end
  endtask

  // One CALIRR row on dut2: write cfg, read 0x128, sample the line for 100 ms (each clock),
  // with `rd` a 0x128 read two clocks after every rise.
  task automatic calirr_row(input [7:0] cfg, input bit rd, input integer ticks);
    integer samples, ones, rises, falls, run, maxrun, k;
    reg prev, first;
    begin
      @(negedge clk); t2_din = cfg; t2_we = 1;
      @(negedge clk); t2_we = 0;
      @(negedge clk); t2_rd = 1;
      @(negedge clk); t2_rd = 0;
      first = irq2; prev = irq2;
      samples = 0; ones = 0; rises = 0; falls = 0; run = 0; maxrun = 0; k = 0;
      while (samples < HZ2 / 10) begin
        @(posedge clk); #1;
        samples = samples + 1;
        if (irq2) ones = ones + 1;
        if (irq2 && !prev) begin
          rises = rises + 1;
          k = 3;                             // the read lands two clocks after the rise
        end
        if (!irq2 && prev) falls = falls + 1;
        if (!irq2) begin run = run + 1; if (run > maxrun) maxrun = run; end
        else run = 0;
        prev = irq2;
        if (rd && k != 0) begin
          k = k - 1;
          if (k == 1) begin
            @(negedge clk); t2_rd = 1;
            @(negedge clk); t2_rd = 0;
            samples = samples + 2;           // the two clocks the read took (the line sampled again below)
          end
        end
      end
      $display("  CALIRR cfg=%02x mode=%s first=%0d samples=%0d ones=%0d rises=%0d falls=%0d maxlow=%0d us",
               cfg, rd ? "R" : "N", first, samples, ones, rises, falls, maxrun);
      if (first !== 1'b1)
        fail($sformatf("CALIRR cfg=%02x mode=%s: the line is low after the write and read (Xe10 first=1)",
                       cfg, rd ? "R" : "N"));
      if (maxrun > 7 || maxrun < 1)
        fail($sformatf("CALIRR cfg=%02x mode=%s: a low run of %0d us (the Xe10's 1-2 ARTIC ticks)",
                       cfg, rd ? "R" : "N", maxrun));
      if (rises != falls || falls < ticks - 1 || falls > ticks + 1)
        fail($sformatf("CALIRR cfg=%02x mode=%s: %0d falls / %0d rises in 100 ms, one per tick (%0d)",
                       cfg, rd ? "R" : "N", falls, rises, ticks));
      if ((samples - ones) > 8 * (ticks + 1))
        fail($sformatf("CALIRR cfg=%02x mode=%s: low for %0d of %0d samples (Xe10: 1-8 of 97792)",
                       cfg, rd ? "R" : "N", samples - ones, samples));
    end
  endtask

  // ==== CHECKS ====
  task automatic check_row(input [7:0] cfg, input bit rd, input integer n_xe10,
                           input [7:0] v_xe10);
    integer n;
    reg [7:0] v;
    begin
      cal_row(cfg, rd, n, v);
      $display("  cfg=%02x mode=%s n=%0d v=%02x (Xe10 n=%0d v=%02x)", cfg, rd ? "R" : "N", n, v,
               n_xe10, v_xe10);
      if ((n < n_xe10 - 1) || (n > n_xe10 + 1))
        fail($sformatf("cfg=%02x mode=%s: %0d requests in half a second, the Xe10 %0d", cfg,
                       rd ? "R" : "N", n, n_xe10));
      if (v !== v_xe10)
        fail($sformatf("cfg=%02x mode=%s: 0x128 reads %02x after the window, the Xe10 %02x", cfg,
                       rd ? "R" : "N", v, v_xe10));
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    //          cfg    mode  n    v       (docs/probes/XE10T-XE10-AUDIT.TXT `X AUDIT CAL`)
    check_row(8'h81, 1'b1, 16, 8'h81);
    check_row(8'h81, 1'b0, 16, 8'h91);
    check_row(8'h80, 1'b1, 32, 8'h80);
    check_row(8'h80, 1'b0, 32, 8'h90);
    check_row(8'h83, 1'b1,  9, 8'h83);
    check_row(8'h83, 1'b0,  8, 8'h93);
    check_row(8'h82, 1'b1,  0, 8'h82);
    check_row(8'h82, 1'b0,  0, 8'h82);
    check_row(8'h00, 1'b1,  0, 8'h10);
    check_row(8'h00, 1'b0,  0, 8'h10);
    check_row(8'h01, 1'b1,  0, 8'h11);
    check_row(8'h01, 1'b0,  0, 8'h11);

    // ---- CALIRR (kit 2): the line's shape. One enabled tick first raises it (the as-found
    // window started low and rose at its first tick, `cfg=FF mode=N first=0 ... e=+9462`).
    @(negedge clk); t2_din = 8'h81; t2_we = 1;
    @(negedge clk); t2_we = 0;
    while (!irq2) @(posedge clk);
    //          cfg    mode  ticks in 100 ms (31.25 / 15.625 / 62.5 ms periods)
    calirr_row(8'h81, 1'b0, 3);
    calirr_row(8'h81, 1'b1, 3);
    calirr_row(8'h80, 1'b0, 6);
    calirr_row(8'h80, 1'b1, 6);
    calirr_row(8'h83, 1'b0, 2);
    calirr_row(8'h83, 1'b1, 2);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CALENDAR_XE10: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CALENDAR_XE10: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_CALENDAR_XE10: TIMEOUT");
  end

endmodule

`default_nettype wire
