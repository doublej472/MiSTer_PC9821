// tb_pc9821_kbd_warmreset - the keyboard's warm-reset state and stale-event replay.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_KBD_WARMRESET:
// The keyboard's warm-reset state: key_down is cleared by the MODULE reset, so the first make after a card reset is delivered instead of swallowed as a re-send of a held key, while the 8251 bit-3 keyboard reset KEEPS it (NP2kai keyboard_resetsignal keeps keystat.ref), so a held key's break still reaches the guest and a duplicate make stays silent; the PS/2 event edge detector tracks through reset, so a completed event held on ps2_key with its toggle bit set cannot replay as a fresh key at reset release (the L2 replay); and ctrl_writes and the dbg telemetry are reset state - the first two control writes after a reset land in dbg_ctrl0/dbg_ctrl1 and none of the telemetry is X in 4-state sim (run under iverilog for the fail-first X-lock).
//
// (a) `key_down` is cleared by the MODULE reset, so the first make after it is
//     DELIVERED instead of being swallowed as a "re-send of a held key".
//     The 8251 bit-3 keyboard reset is different: NP2kai's
//     keyboard_resetsignal() (io/serial.c:111-119) resets the receive record -
//     cmd, status, both queues, the pending parameter and the repeat buffer -
//     but KEEPS keystat.ref, so the held key's BREAK still matches and reaches
//     the guest. Clearing it here (the old behaviour, an epoch bump on bit 3)
//     broke that: the guest had been told the key was down, the 8251 reset does
//     not touch the guest's state, and the release was swallowed - the key
//     stuck down until it was pressed again.
// (b) The PS/2 event edge detector tracks THROUGH reset, so a completed event
//     held on ps2_key with the toggle bit still set cannot REPLAY as a fresh key
//     at reset release (the L2 replay). Before the fix
//     `ps2_key_prev` reset to 0 while the unreset `ps2_key_q`/`event_code` path
//     kept the last event, and `ps_event = (ps2_key_q[1] != ps2_key_prev)` fired
//     spuriously on the first cycle - the last key (or its X) came back.
// (c) `ctrl_writes` and the dbg telemetry are reset state: after a module reset
//     the FIRST two control writes land in dbg_ctrl0/dbg_ctrl1 (the "wrong 8251
//     sequence" telemetry), and none of the telemetry is X in 4-state sim.
//     Run under a 4-state simulator (iverilog) to
//     see the fail-first X-lock of `ctrl_writes <= ctrl_writes + 1`.
//
// ==== THE 4-STATE RUN ====
// (a) and (b) are behavioural and 2-state-visible, so the gate covers them. (c)'s "none of
// the telemetry is X in 4-state sim" is NOT part of what tools/bench.py --all proves:
// the gate's engine is 2-state and zero-initialised. The backing run is
// `python3 tools/check_4state_xlock.py kbd_warmreset` (iverilog, 4-state, by hand,
// outside the build path), which runs all three sections. Its `--selftest` drops
// `ctrl_writes <= 8'd0;` from the reset and REQUIRES the run to FAIL: the counter X-locks
// and the dbg_ctrl0/dbg_ctrl1 latches stay X with it.

`timescale 1ns / 1ps

module tb_pc9821_kbd_warmreset;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  wire [7:0] dbg_events, dbg_delivered, dbg_rd_data, dbg_wr_ctrl, dbg_last_del;
  wire [7:0] dbg_ctrl0, dbg_ctrl1;

  // ==== DUT ====
  pc9821_kbd dut (
      .clk(clk),
      .rst_n(rst_n),
      .cs(cs),
      .a0(a0),
      .wr(wr),
      .rd(rd),
      .din(din),
      .dout(dout),
      .irq(irq),
      .ps2_key(ps2_key),
      .dbg_events(dbg_events), .dbg_delivered(dbg_delivered),
      .dbg_rd_data(dbg_rd_data), .dbg_wr_ctrl(dbg_wr_ctrl),
      .dbg_rts(), .dbg_rx_en(),
      .dbg_last_del(dbg_last_del),
      .dbg_ctrl0(dbg_ctrl0), .dbg_ctrl1(dbg_ctrl1)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;

  // ==== CHECKS ====
  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_port(input control_port, input [7:0] data);
    begin
      @(negedge clk);
      a0  = control_port;
      din = data;
      cs  = 1;
      wr  = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      wr = 0;
    end
  endtask

  task send_key(input pressed, input extended, input [7:0] code);
    begin
      @(negedge clk);
      toggle  = ~toggle;
      ps2_key = {toggle, pressed, extended, code};
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  task read_byte(input [7:0] expected);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        $display("FAIL: no receive IRQ: byte %02x never arrived @ %0t", expected, $time);
        errors = errors + 1;
      end else begin
        @(negedge clk);
        a0 = 0;
        cs = 1;
        rd = 1;
        #1 value = dout;
        if (value !== expected) begin
          $display("FAIL: keyboard byte got %02x want %02x", value, expected);
          errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        cs = 0;
        rd = 0;
        #1;
      end
    end
  endtask

  initial begin
    // ==== (b) THE L2 REPLAY ====
    // A completed event is held on ps2_key (toggle bit 1) while the module is in
    // reset; its processing belongs to BEFORE the reset and must not run after.
    @(negedge clk);
    ps2_key = {1'b1, 1'b1, 1'b0, 8'h5A};   // stale completed MAKE of Enter (0x1C)
    toggle = 1'b1;                          // ...whose toggle bit the send_key task must flip
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (10) @(negedge clk);
    if (irq || dut.status_reg[1] || dut.fifo_cnt !== 5'd0) begin
      fail("a stale pre-reset ps2_key event replayed after reset: the last key came back");
    end

    // The event path must still deliver FRESH events (a real ps2_key[10] toggle).
    send_key(1'b1, 1'b0, 8'h5A);           // fresh toggle: make 0x5A -> 0x1C
    read_byte(8'h1C);

    // ==== (a) rst_n MUST CLEAR key_down ====
    // Enter is down (its make just delivered). A warm reset, then the SAME make
    // again with no break in between: the reference delivers it.
    repeat (4) @(negedge clk);
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);
    send_key(1'b1, 1'b0, 8'h5A);           // make 0x1C again, NO break since the last one
    read_byte(8'h1C);

    // ==== (a) THE 8251 BIT-3 RESET MUST *KEEP* key_down ====
    // The ITF's own 0x3A -> 0x32 pair (BANK4@0x04BEA/0x04BF6). NP2kai
    // keyboard_resetsignal (io/serial.c:111-119) keeps keystat.ref - only the
    // half-written parameter and the repeat buffer go - so a key held across
    // the reset still has a matching BREAK (its release must reach the guest)
    // and a re-delivered make is still the same physical press (M2: silent).
    write_port(1'b1, 8'h3A);
    write_port(1'b1, 8'h32);
    repeat (2) @(negedge clk);
    send_key(1'b1, 1'b0, 8'h5A);           // duplicate make: MUST be silent
    repeat (4) @(posedge clk); #1;
    if (irq) fail("the 8251 bit-3 reset cleared key_down: a duplicate make was delivered");
    send_key(1'b0, 1'b0, 8'h5A);           // ...and the held key's break must arrive
    read_byte(8'h9C);

    // ==== (c) ctrl_writes / dbg telemetry are RESET state ====
    repeat (2) @(negedge clk);
    if ($isunknown(dut.ctrl_writes) || $isunknown(dbg_ctrl0) || $isunknown(dbg_ctrl1) ||
        $isunknown(dbg_events) || $isunknown(dbg_delivered) || $isunknown(dbg_rd_data) ||
        $isunknown(dbg_wr_ctrl) || $isunknown(dbg_last_del)) begin
      fail("X in the 8251 control-write telemetry (ctrl_writes X-locks the dbg latches)");
    end
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);
    write_port(1'b1, 8'h40);               // first control write of THIS run
    write_port(1'b1, 8'h41);               // second
    if (dbg_ctrl0 !== 8'h40 || dbg_ctrl1 !== 8'h41) begin
      $display("FAIL: dbg_ctrl0/1 = %02x/%02x want 40/41: the first two control writes after reset must latch (got %02x/%02x before this reset)",
               dbg_ctrl0, dbg_ctrl1, 8'h5E, 8'h05);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_WARMRESET: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_WARMRESET: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_KBD_WARMRESET: TIMEOUT");
  end

endmodule
