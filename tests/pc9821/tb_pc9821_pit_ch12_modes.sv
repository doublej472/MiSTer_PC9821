`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_CH12_MODES: the real pc9821_interrupts PIT's channels 1 and 2 (the beeper and the RS-232C clock, ports 0x73/0x75) in modes 1, 4 and 5 - the modes tb_pc9821_pit_ref does not drive - answer the uPD71054 read-back command and the counter latch as NP2kai io/pit.c does, and count at the machine's measured 2.4576 MHz (docs/probes/IDELAT-clean.TXT RATES pit_hz=2457600): for each channel and mode (control words 0x72/0x78/0x7A and 0xB2/0xB8/0xBA, LSB+MSB, binary) a status-only read-back (0xE4 for channel 1, 0xE8 for channel 2) returns the control word's low six bits with NULL COUNT (bit 6) set after the control word (pit_setflag: (value & 0x3f) | PIT_STAT_CMD), still set after the count's first byte and clear after its second (pit_setcount); a combined read-back (0xC4/0xC8) returns the status byte first and then the latched count low byte, high byte (pit_getstat: PIT_FLAG_S before the latch); one read-back naming both channels (0xEC) latches both statuses, each read from its own port; and a counter latch (0x40/0x80) taken a known time after the load freezes a count that is the loaded 0x4000 less the 2.4576 MHz ticks elapsed (within 2 counts), and a counter latch taken later holds the count of its own instant (read 500 clk_sys, 24 ticks, after the latch, it must equal the earlier count less the ticks between the two latches, within 2).
//
// WHY THIS BENCH EXISTS. tb_pc9821_pit_ref drives channel 0's read-back and the mode 0/2/3
// periods; channels 1 and 2 in modes 1, 4 and 5, and the read-back command on those two
// channels, had no test. No machine capture reaches these modes (the PIT captures,
// docs/probes/PIT-fixed.TXT, PITPH.TXT and KIT1-XE10-PIT.TXT, read channel 0's byte phase and
// divisor only), so the expected status bytes come from NP2kai io/pit.c and the count rate
// from the machine's own measured PIT clock. The gate is not modelled (NP2kai has none, and
// pc9821_pit counts modes 1 and 5 from the load as NP2kai's event model does), so the counts
// asserted are those of a counter that runs from its load; OUT (status bit 7) is not
// asserted here, since NP2kai hard-wires it low and pit_ref owns the live-OUT case.

`default_nettype none

module tb_pc9821_pit_ch12_modes;

  reg clk = 0;
  // 50 MHz, the frequency the system instantiates, so the PIT's divider matches
  // the shipped configuration (tb_pc9821_pit uses the same clock).
  always #10 clk = ~clk;
  reg reset_n = 0;

  reg  io_wr = 0, io_rd = 0;
  reg  [15:0] io_addr = 0;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg  master_cs = 0, slave_cs = 0, pit_cs = 0;
  reg  keyboard_irq = 0, vsync_irq = 0;
  reg  [3:0] master_aux_irq = 0;
  reg  [7:0] slave_irq = 0;
  wire cpu_intr;
  reg  cpu_inta = 0;
  wire [31:0] cpu_inta_din;
  wire cpu_inta_ready;
  wire pit_out0, pit_out1, pit_out2;
  wire [7:0] dbg_imr, dbg_irr, dbg_isr;
  wire [7:0] dbg_s_imr, dbg_s_isr;

  // ==== DUT ====
  pc9821_interrupts #(.SYS_CLOCK_HZ(50_000_000)) dut (.*);

  integer errors = 0, cases = 0, waivers = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  // ==== STIMULUS ====

  task automatic check(input string name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %s: rtl=0x%04x want=0x%04x", name, got, want);
        errors = errors + 1;
      end
      else $display("ok       %s = 0x%04x", name, got);
    end
  endtask

  // A case where NP2kai's own model diverges from the datasheet and this RTL follows
  // the hardware: PRINT the RTL/NP2kai bytes and count a waiver, do not assert either.
  task automatic waive(input [8*40-1:0] name, input [15:0] rtl, input [15:0] np2);
    begin
      cases = cases + 1;
      waivers = waivers + 1;
      $display("WAIVED   %0s: rtl=0x%02x np2kai=0x%02x (RTL follows the datasheet)",
               name, rtl[7:0], np2[7:0]);
    end
  endtask

  task automatic checkin(input [8*40-1:0] name, input integer got, input integer lo, input integer hi);
    begin
      cases = cases + 1;
      if (got < lo || got > hi) begin
        $display("MISMATCH %0s: rtl=%0d np2kai=%0d..%0d", name, got, lo, hi);
        errors = errors + 1;
      end
      else $display("ok       %0s = %0d", name, got);
    end
  endtask

  task automatic set_selects(input [15:0] portnum);
    begin
      master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pit_cs    = ((portnum[15:3] == 13'h000E) || (portnum[15:3] == 13'h07FB)) &&
                  portnum[0];
    end
  endtask

  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; set_selects(portnum); io_din = data; io_wr = 1;
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic read_port(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; set_selects(portnum); io_rd = 1;
      #1 data = io_dout;                  // sample the first byte before the next posedge consumes it
      @(negedge clk); io_rd = 0;
    end
  endtask


  task automatic reset_all;
    begin
      reset_n = 0; io_wr = 0; io_rd = 0; cpu_inta = 0;
      repeat (4) @(negedge clk);
      reset_n = 1;
      repeat (2) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  localparam integer TICK_NUM = 2_457_600;   // the machine's PIT clock (IDELAT-clean.TXT RATES)
  localparam integer SYS_HZ   = 50_000_000;  // this bench's clk (20 ns)
  integer ch, mi, t_load, t_latch, t_latch2, ticks, expect_cnt, c1, c2;
  reg [7:0] cw, st, lo, hi, lo2, hi2;
  reg [7:0] modes [0:2];
  reg [15:0] port_data;
  reg [7:0] rb_status, rb_both;

  initial begin
    modes[0] = 8'd1; modes[1] = 8'd4; modes[2] = 8'd5;
    for (ch = 1; ch <= 2; ch = ch + 1) begin
      port_data = (ch == 1) ? 16'h0073 : 16'h0075;
      rb_status = (ch == 1) ? 8'hE4 : 8'hE8;   // 11 1 0 CNT2 CNT1 CNT0 0: status only
      for (mi = 0; mi < 3; mi = mi + 1) begin
        reset_all();
        cw = {ch[1:0], 2'b11, modes[mi][2:0], 1'b0};
        // ---- control word: NULL COUNT set, bits 5:0 the control word's ----
        write_port(16'h0077, cw);
        write_port(16'h0077, rb_status);
        read_port(port_data, st);
        check($sformatf("ch%0d mode%0d status after control word", ch, modes[mi]),
              {8'h00, st[6:0]}, {8'h00, 1'b1, cw[5:0]});
        // ---- the count's first byte: still NULL ----
        write_port(port_data, 8'h00);
        write_port(16'h0077, rb_status);
        read_port(port_data, st);
        check($sformatf("ch%0d mode%0d NULL after the first byte", ch, modes[mi]),
              {15'd0, st[6]}, 16'd1);
        // ---- the second byte completes the load: NULL clear ----
        write_port(port_data, 8'h40);           // count 0x4000
        t_load = cyc;
        write_port(16'h0077, rb_status);
        read_port(port_data, st);
        check($sformatf("ch%0d mode%0d status after the load", ch, modes[mi]),
              {8'h00, st[6:0]}, {8'h00, 1'b0, cw[5:0]});
        // ---- combined read-back: status first, then the latched count ----
        repeat (400) @(negedge clk);
        write_port(16'h0077, rb_status & 8'hDF);   // D5 = 0: latch the count too
        t_latch = cyc;
        read_port(port_data, st);
        read_port(port_data, lo);
        read_port(port_data, hi);
        check($sformatf("ch%0d mode%0d combined read-back status", ch, modes[mi]),
              {8'h00, st[6:0]}, {8'h00, 1'b0, cw[5:0]});
        ticks = ((t_latch - t_load) * (TICK_NUM / 3200)) / (SYS_HZ / 3200);
        expect_cnt = 16'h4000 - ticks;
        c1 = {hi, lo};
        cases = cases + 1;
        if (c1 < expect_cnt - 2 || c1 > expect_cnt + 2) begin
          $display("MISMATCH ch%0d mode%0d read-back count %04x, want %04x +/- 2 (%0d ticks after the load)",
                   ch, modes[mi], c1, expect_cnt, ticks);
          errors = errors + 1;
        end else $display("ok       ch%0d mode%0d read-back count %04x", ch, modes[mi], c1);
        // ---- counter latch (control word with RL = 00), read twice apart ----
        repeat (2000) @(negedge clk);
        write_port(16'h0077, {ch[1:0], 6'b000000});
        t_latch2 = cyc;
        repeat (500) @(negedge clk);             // the latch holds while the counter runs
        read_port(port_data, lo2);
        read_port(port_data, hi2);
        c2 = {hi2, lo2};
        ticks = ((t_latch2 - t_latch) * (TICK_NUM / 3200)) / (SYS_HZ / 3200);
        cases = cases + 1;
        if (c2 < c1 - ticks - 2 || c2 > c1 - ticks + 2) begin
          $display("MISMATCH ch%0d mode%0d counter latch %04x, want %04x +/- 2 (%0d ticks after the read-back latch)",
                   ch, modes[mi], c2, c1 - ticks, ticks);
          errors = errors + 1;
        end else $display("ok       ch%0d mode%0d counter latch %04x", ch, modes[mi], c2);
      end
    end

    // ---- one read-back naming both channels: each status from its own port ----
    reset_all();
    write_port(16'h0077, 8'h78);           // ch1 mode 4
    write_port(16'h0077, 8'hBA);           // ch2 mode 5
    write_port(16'h0073, 8'h10); write_port(16'h0073, 8'h00);   // ch1 loaded: NULL clear
    write_port(16'h0077, 8'hEC);           // status only, CNT1 + CNT2
    read_port(16'h0073, st);
    check("both: ch1 status (loaded, mode 4)", {8'h00, st[6:0]}, 16'h0038);
    read_port(16'h0075, st);
    check("both: ch2 status (not loaded, mode 5)", {8'h00, st[6:0]}, 16'h007A);

    // ==== VERDICT ====
    $display("NOTE TB_PC9821_PIT_CH12_MODES: %0d cases", cases);
    if (errors == 0) begin
      $display("TB_PC9821_PIT_CH12_MODES: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_CH12_MODES: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PIT_CH12_MODES: TIMEOUT");
  end

endmodule
