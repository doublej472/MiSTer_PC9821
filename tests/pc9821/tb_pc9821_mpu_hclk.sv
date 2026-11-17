`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MPU_HCLK: The MPU-PC98's clock-to-host (0xFD) rate dither is the card's FOUR-phase one: run as the XE10Z /MPU probe runs it (0xFF, then for each 0xE7 follow byte 04..0B: 0xE7 v, 0x95, 33 consecutive 0xFD messages timed, 0x94), each row's 32 intervals, in stepclocks, are q = v >> 2 plus a 4-periodic extra-clock pattern that is a rotation of the Xe10's own row (docs/probes/XE10Z-XE10.TXT:223-230: 0000, 1000, 0101, 0111, 0000, 0100, 1010, 1011 for v = 04..0B), so each row's mean is the card's q + f/4 - FAIL-FIRST, the core's 3-bit phase gave an eight-phase dither (1000 0000 at v = 05, a mean of q + f/8) that is no rotation of the card's row. Where the rotation starts at each row is not asserted (the capture does not settle it, todo item 200).
//
// The DUT runs at SYS_CLOCK_HZ = 2 MHz, so one stepclock (SYS_CLOCK_HZ / 200, the 5 ms of tempo
// 100 / timebase 120) is 10_000 clk and a row costs at most 33 x 3 stepclocks. The interval
// between two 0xFD arrivals is rounded to whole stepclocks, as xe10z_decode.py rounds the card's
// ARTIC intervals to whole internal clocks (one clock = 1524 ticks there, the v = 04 median).

module tb_pc9821_mpu_hclk;

  // ==== DUT ====
  localparam integer SYS_HZ = 2_000_000;
  localparam integer STEP   = SYS_HZ / 200;       // one stepclock, in clk
  localparam integer NFD    = 33;                 // the probe's FD stamps per rate: 32 intervals

  reg         clk = 1'b0;
  reg         reset = 1'b1;
  always #10 clk = ~clk;

  reg         cs = 1'b0;
  reg  [15:0] addr = 16'hE0D0;
  reg         wr = 1'b0;
  reg         rd = 1'b0;
  reg  [7:0]  din = 8'h00;
  wire [7:0]  dout;
  /* verilator lint_off UNUSEDSIGNAL */   // the MIDI line and the IRQ are not what this bench measures
  wire        uart_tx;
  wire        irq;
  /* verilator lint_on UNUSEDSIGNAL */

  pc9821_mpu #(.SYS_CLOCK_HZ(SYS_HZ)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .uart_tx(uart_tx), .irq(irq));

  // The Xe10's extra clocks per interval, one 4-periodic row per 0xE7 byte 04..0B, read from
  // docs/probes/XE10Z-XE10.TXT:223-230 (each row's 32 intervals divided by 1524 ARTIC ticks and
  // rounded, less q; every row is 4-periodic over all 32): e.g. `MPU v=06 ... d=05F4,0C31,05B9,
  // 0BF3,...` = 1,2,1,2 clocks -> 0,1,0,1. Bit i of the nibble is the extra at interval i.
  function automatic [3:0] card_row(input [3:0] v);
    case (v)
      4'h4: card_row = 4'b0000;   // 0000
      4'h5: card_row = 4'b0001;   // 1000
      4'h6: card_row = 4'b1010;   // 0101
      4'h7: card_row = 4'b1110;   // 0111
      4'h8: card_row = 4'b0000;   // 0000
      4'h9: card_row = 4'b0010;   // 0100
      4'hA: card_row = 4'b0101;   // 1010
      4'hB: card_row = 4'b1101;   // 1011
      default: card_row = 4'b0000;
    endcase
  endfunction

  // ==== STIMULUS ====
  // The bus strobes as pc9821_iobus presents them (one clk, driven from the negedge), as
  // tb_pc9821_mpu does.
  task automatic bus_wr(input [15:0] a, input [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; din = b; wr = 1'b1; rd = 1'b0;
      @(negedge clk);
      wr = 1'b0; cs = 1'b0;
    end
  endtask

  task automatic bus_rd(input [15:0] a, output [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; rd = 1'b1; wr = 1'b0;
      #1;
      b = dout;
      @(negedge clk);
      rd = 1'b0; cs = 1'b0;
    end
  endtask

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // Read the response queue until it stays empty for 1000 clk (the probe's mpu_drain).
  task automatic drain;
    reg [7:0] st, b;
    integer quiet;
    begin
      quiet = 0;
      while (quiet < 1000) begin
        bus_rd(16'hE0D2, st);
        if (!st[7]) begin bus_rd(16'hE0D0, b); quiet = 0; end
        else quiet = quiet + 2;
      end
    end
  endtask

  // A command and its ACK (the probe's mpu_cmd).
  task automatic mpu_cmd(input [7:0] c);
    reg [7:0] st, b;
    integer n;
    begin
      bus_wr(16'hE0D2, c);
      b = 8'h00;
      for (n = 0; n < 2000 && b != 8'hFE; n = n + 1) begin
        bus_rd(16'hE0D2, st);
        if (!st[7]) bus_rd(16'hE0D0, b);
      end
      chk(b == 8'hFE, "a command was not ACKed");
    end
  endtask

  // ==== CHECKS ====
  integer errors = 0;
  task automatic chk(input condition, input string msg);
    begin
      if (!condition) begin
        errors = errors + 1;
        $display("FAIL %s", msg);
      end
    end
  endtask

  integer stamp [0:NFD-1];
  integer kint  [0:NFD-2];

  initial begin : run
    reg [7:0] st, b;
    integer v, n, i, s, q, sum, guard;
    reg [3:0] row;
    reg rot_ok, any_ok;
    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (5) @(posedge clk);
    drain;
    mpu_cmd(8'hFF);                               // reset: tempo 100, timebase 120
    drain;
    for (v = 4; v < 12; v = v + 1) begin
      drain;
      mpu_cmd(8'hE7);
      bus_wr(16'hE0D0, v[7:0]);
      mpu_cmd(8'h95);                             // clock to host ON
      n = 0;
      guard = 0;
      while (n < NFD && guard < NFD * 4 * STEP) begin
        bus_rd(16'hE0D2, st);
        guard = guard + 2;
        if (!st[7]) begin
          bus_rd(16'hE0D0, b);
          if (b == 8'hFD) begin stamp[n] = cyc; n = n + 1; end
        end
      end
      chk(n == NFD, "fewer than 33 0xFD messages in a row");
      mpu_cmd(8'h94);                             // clock to host OFF
      q   = v >> 2;
      row = card_row(v[3:0]);
      sum = 0;
      for (i = 0; i < NFD - 1; i = i + 1) begin
        kint[i] = (stamp[i + 1] - stamp[i] + STEP / 2) / STEP;
        sum = sum + kint[i];
      end
      // A rotation of the card's row: some s for which every interval is q + row[(i + s) & 3].
      any_ok = 1'b0;
      for (s = 0; s < 4; s = s + 1) begin
        rot_ok = 1'b1;
        for (i = 0; i < NFD - 1; i = i + 1)
          if (kint[i] != q + row[(i + s) & 3]) rot_ok = 1'b0;
        if (rot_ok) any_ok = 1'b1;
      end
      $display("v=%02x q=%0d sum=%0d/32 first=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d %s", v, q, sum,
               kint[0], kint[1], kint[2], kint[3], kint[4], kint[5], kint[6], kint[7],
               any_ok ? "card row" : "NOT the card's row");
      chk(any_ok, "a row's intervals are not a rotation of the Xe10's 4-phase row");
      // The mean: 32 intervals of q + f/4 are 32q + 8f stepclocks.
      chk(sum == 32 * q + 8 * (v & 3), "a row's mean is not the card's q + f/4");
      drain;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_MPU_HCLK: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_MPU_HCLK: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_MPU_HCLK: timeout");
  end

endmodule
