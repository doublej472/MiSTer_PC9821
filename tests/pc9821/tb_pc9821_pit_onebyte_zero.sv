// tb_pc9821_pit_onebyte_zero - a one-byte PIT count write zeroes the byte it does not write.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_ONEBYTE_ZERO: a one-byte count write on PIT channel 0 ZEROES the count byte it does not write, as the Xe10 times it with XE10Y /K3M: after a mode-0 LSB+MSB count of 1234h, control 10h (LSB only) and 56h raise OUT 10 ARTIC ticks after the write (the 0056h control's 11, not the 1256h one's 588), and after 12F0h, control 20h (MSB only) and 01h raise it after 33 (the 0100h control's 33, not the 01F0h one's 63); every case's read-back status (control E2h) is the capture's st0 (30h, 10h, 20h).

// ---- where the expectation comes from ----
//   The machine, XE10Y /K3M (tools/hwprobe/xe10t/sec_kit3.inc k3_pitw: control 30h and the
//   count LSB then MSB, then the one-byte control and its byte, OUT timed by read-back status
//   bit 7 against the 307.2 kHz ARTIC), three runs on the Xe10:
//     docs/probes/XE10Y-XE10-K3M.TXT:31 `case=C0056 st0=30 irr0=0 out_art=11`
//     docs/probes/XE10Y-XE10-K3M.TXT:32 `case=C1256 st0=30 irr0=0 out_art=588`
//     docs/probes/XE10Y-XE10-K3M.TXT:33 `case=L1234_56 st0=10 irr0=0 out_art=10`
//     docs/probes/XE10Y-XE10-K3M.TXT:34 `case=C0100 st0=30 irr0=0 out_art=33`
//     docs/probes/XE10Y-XE10-K3M.TXT:35 `case=C01F0 st0=30 irr0=0 out_art=63`
//     docs/probes/XE10Y-XE10-K3M.TXT:36 `case=M12F0_01 st0=20 irr0=0 out_art=33`
//     docs/probes/XE10Y-XE10-K3M2.TXT:31-36 and docs/probes/XE10Y-XE10-RUN3-KATA.TXT:31-36:
//     the same rows within one ARTIC tick (587, 62, 34).
//   Each window below is the three runs' spread, widened by two ARTIC ticks below (the probe
//   reads the ARTIC at an arbitrary phase of its tick and then polls OUT in a loop, so its
//   rows sit up to a tick above the count's own duration) and one above (quantisation). Each
//   one-byte case must also time within one tick of its zeroed-byte control (L1234_56 against
//   C0056, M12F0_01 against C0100), as all three captures do; the retained-byte answers
//   (588 and 63) lie far outside both.
// FAIL-FIRST: before the fix the core kept the other byte: L1234_56 timed 1256h (588 ARTIC
// ticks, docs/probes/core/XE10Y-CORE-xt-3409ab24-s3-XE10-K3M.TXT) and M12F0_01 01F0h (63).

`default_nettype none

module tb_pc9821_pit_onebyte_zero;

  localparam integer SYS_HZ = 50_000_000;
  localparam integer ART_HZ = 307_200;   // the ARTIC the probe times against

  reg clk = 0;
  always #10 clk = ~clk;   // 50 MHz
  reg rst_n = 0;
  reg cs = 0, wr = 0, rd = 0;
  reg  [1:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire out0, out1, out2;

  // ==== DUT ====
  pc9821_pit #(.SYS_CLOCK_HZ(SYS_HZ)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .out0(out0), .out1(out1), .out2(out2)
  );

  integer errors = 0;
  integer checks = 0;
  integer cyc = 0;
  integer last_art = 0;
  integer art_c0056 = 0, art_c0100 = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== STIMULUS ====
  task write_pit(input [1:0] port, input [7:0] value);
    begin
      @(negedge clk);
      addr = port; din = value; cs = 1; wr = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0; wr = 0;
    end
  endtask

  task read_pit(input [1:0] port, output [7:0] value);
    begin
      @(negedge clk);
      addr = port; cs = 1; rd = 1;
      #1 value = dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0; rd = 0;
    end
  endtask

  // ==== CHECKS ====
  task expect_range(input [8*40-1:0] name, input integer got, input integer lo,
                    input integer hi);
    begin
      checks = checks + 1;
      if (got < lo || got > hi) begin
        $display("MISMATCH %0s: got %0d, want %0d..%0d", name, got, lo, hi);
        errors = errors + 1;
      end else $display("ok       %0s = %0d", name, got);
    end
  endtask

  // k3_pitw: control 30h + count (LSB, MSB); then, when one_ctl != 0, that control and
  // its byte. The status is read (E2h) right after, then OUT is timed from the last write.
  task k3_pitw(input [8*40-1:0] name, input [15:0] count, input [7:0] one_ctl,
               input [7:0] one_byte, input [7:0] want_st0, input integer art_lo,
               input integer art_hi);
    integer t0;
    integer art;
    reg [7:0] st0;
    begin
      write_pit(2'd3, 8'h30);
      write_pit(2'd0, count[7:0]);
      write_pit(2'd0, count[15:8]);
      if (one_ctl != 8'h00) begin
        write_pit(2'd3, one_ctl);
        write_pit(2'd0, one_byte);
      end
      t0 = cyc;
      write_pit(2'd3, 8'hE2);
      read_pit(2'd0, st0);
      expect_range({name, " st0"}, st0, want_st0, want_st0);
      while (!out0 && (cyc - t0) < SYS_HZ / 50) @(posedge clk);
      art = ((cyc - t0) * (ART_HZ / 100) + (SYS_HZ / 200)) / (SYS_HZ / 100);
      expect_range({name, " out_art"}, art, art_lo, art_hi);
      last_art = art;
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // The controls, then each one-byte case after the count whose other byte it must zero.
    // Windows: the captures' [min - 2, max + 1] (K3M, K3M2, RUN3-KATA rows 31-36).
    k3_pitw("C0056",    16'h0056, 8'h00, 8'h00, 8'h30, 9, 12);
    art_c0056 = last_art;
    k3_pitw("C1256",    16'h1256, 8'h00, 8'h00, 8'h30, 585, 589);
    k3_pitw("L1234_56", 16'h1234, 8'h10, 8'h56, 8'h10, 8, 11);
    expect_range("L1234_56 - C0056", last_art - art_c0056, -1, 1);
    k3_pitw("C0100",    16'h0100, 8'h00, 8'h00, 8'h30, 31, 34);
    art_c0100 = last_art;
    k3_pitw("C01F0",    16'h01F0, 8'h00, 8'h00, 8'h30, 60, 64);
    k3_pitw("M12F0_01", 16'h12F0, 8'h20, 8'h01, 8'h20, 31, 35);
    expect_range("M12F0_01 - C0100", last_art - art_c0100, -1, 1);

    // ==== VERDICT ====
    $display("  %0d checks", checks);
    if (errors == 0) begin
      $display("TB_PC9821_PIT_ONEBYTE_ZERO: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_ONEBYTE_ZERO: FAIL (%0d errors)", errors);
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_PIT_ONEBYTE_ZERO: TIMEOUT");
  end

endmodule

`default_nettype wire
