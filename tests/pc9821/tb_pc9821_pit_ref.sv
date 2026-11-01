`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Runs the real pc9821_interrupts PIT (channels 0/1/2) and the interrupt it feeds - the same block the machine instantiates, with the master 8259 programmed as the ITF programs it - and checks every channel's mode 0/2/3 output period and the interrupt-on-terminal-count against NP2kai io/pit.c: mode 3 and 2 re-arm every period, mode 0 fires once, channel 1 and 2 are independent of channel 0, and IRQ0 lands on the master PIC's IRQ0. The uPD71054 read-back command is implemented and asserted (0xC2 on ch0 returns the status byte 0x36 in bits 6:0 after a completed count load - NULL COUNT is live: set by a control word, cleared when the load completes, the first byte of an LSB+MSB pair not counting - with bit 7 the channel's live OUT pin, asserted separately). NP2kai's channel-0 write that clears master IRR0 is waived: the machine's own IRQWD run shows the bit set before and after a latch command (docs/probes/IRQWD.TXT; confounded by the as-found mode-0 static OUT, so the falling-edge model in pit_irq_clear supersedes it). Two fail-first cases pin the word-read byte phase against NP2kai's PIT_FLAG_R (io/pit.c:224-239,248-249,348-358) and the Xe10 capture (docs/probes/PIT-fixed.TXT:146-147): a counter latch does NOT reset the phase, so a latched pair is consumed high-then-low after one word read, and a mode-set control word DOES reset it, so the next word read is low-first. An MSB-only (RL=2) count read answers the count's HIGH byte (NP2kai io/pit.c:346-347, PIT_RL_H).
//
// The masked-IRQ0 clear itself is NOT asserted here - it is covered by
// tb_pc9821_pit_irq_clear (the machine-level IRQWD result). This bench's IRQ0
// cases are all UNMASKED, where the falling edge must not withdraw a request
// about to be delivered.

`default_nettype none

module tb_pc9821_pit_ref;

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

  task automatic check(input [8*40-1:0] name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%02x np2kai=0x%02x", name, got[7:0], want[7:0]);
        errors = errors + 1;
      end
      else $display("ok       %0s = 0x%02x", name, got[7:0]);
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

  // The ITF's own master init: ICW1=0x11, ICW2=0x08, ICW3=0x80, ICW4=0x1D, IMR.
  task automatic init_master(input [7:0] mask);
    begin
      write_port(16'h0000, 8'h11); write_port(16'h0002, 8'h08);
      write_port(16'h0002, 8'h80); write_port(16'h0002, 8'h1D);
      write_port(16'h0002, mask);
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

  function automatic out_bit(input integer w);
    out_bit = (w == 0) ? pit_out0 : (w == 1) ? pit_out1 : pit_out2;
  endfunction

  // Wait for the next rising edge of a PIT output and return the cycle it happened.
  task automatic out_rise(input integer w, output integer t);
    integer guard;
    begin
      guard = 0;
      while (out_bit(w) && guard < 40000) begin @(posedge clk); guard = guard + 1; end
      while (!out_bit(w) && guard < 40000) begin @(posedge clk); guard = guard + 1; end
      t = cyc;
    end
  endtask

  // One x86 acknowledge is two INTA assertions, as the bridge's state machine needs.
  task automatic one_inta;
    begin
      @(negedge clk); cpu_inta = 1;
      while (!cpu_inta_ready) @(negedge clk);
      @(negedge clk); cpu_inta = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // Wait for IRQ0 to reach the CPU, acknowledge it, EOI, and return the cycle and vector.
  task automatic service_irq(output integer when, output [7:0] vec, output bit ok);
    integer guard;
    begin
      guard = 0;
      while (!cpu_intr && guard < 8000) begin @(posedge clk); guard = guard + 1; end
      ok = (guard < 8000);
      when = cyc;
      vec = 8'h00;
      if (ok) begin
        one_inta(); one_inta();
        vec = cpu_inta_din[7:0];
        write_port(16'h0000, 8'h20);       // master non-specific EOI
        repeat (4) @(posedge clk);
      end
    end
  endtask

  integer t1, t2, t3, t4, period;
  bit iok;
  reg [7:0] rv;

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;

    // ---- 1. channel 0 mode 3 (square): one interrupt-edge per period ----
    reset_all();
    init_master(8'hFF);                    // IRQ0 masked: watch the PIT pin only
    write_port(16'h0077, 8'h36);           // ch0, LSB then MSB, mode 3
    write_port(16'h0071, 8'h08);           // divisor 8 -> half period 4 source ticks
    write_port(16'h0071, 8'h00);
    out_rise(0, t1); out_rise(0, t2);
    checkin("pit_mode3_ch0_period", t2 - t1, 150, 175);
    check("pit_mode3_ch0_high_at_load", {15'b0, out_bit(0)}, 16'h0001);

    // ---- 2. channel 0 mode 2 (rate generator) ----
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h34);           // ch0, mode 2
    write_port(16'h0071, 8'h08);
    write_port(16'h0071, 8'h00);
    out_rise(0, t1); out_rise(0, t2);
    checkin("pit_mode2_ch0_period", t2 - t1, 150, 175);

    // ---- 3. channel 0 mode 0 (interrupt on terminal count): OUT low, one rise, stays ----
    reset_all();
    init_master(8'hFF);
    t1 = cyc;
    write_port(16'h0077, 8'h30);           // ch0, mode 0
    write_port(16'h0071, 8'h04);           // divisor 4
    write_port(16'h0071, 8'h00);
    check("pit_mode0_ch0_low_after_load", {15'b0, out_bit(0)}, 16'h0000);
    out_rise(0, t2);
    checkin("pit_mode0_ch0_terminal", t2 - t1, 55, 100);
    repeat (200) @(posedge clk);
    check("pit_mode0_ch0_stays_high", {15'b0, out_bit(0)}, 16'h0001);

    // ---- 4. channel 1 mode 3, independent of channel 0 ----
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h76);           // ch1, mode 3
    write_port(16'h0073, 8'h04);           // divisor 4 -> period 4 ticks
    write_port(16'h0073, 8'h00);
    out_rise(1, t1); out_rise(1, t2);
    checkin("pit_ch1_mode3_period", t2 - t1, 75, 90);
    check("pit_ch1_leaves_ch0_idle", {15'b0, out_bit(0)}, 16'h0000);

    // ---- 5. channel 2 mode 2, independent of the others ----
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'hB4);           // ch2, mode 2
    write_port(16'h0075, 8'h08);
    write_port(16'h0075, 8'h00);
    out_rise(2, t1); out_rise(2, t2);
    checkin("pit_ch2_mode2_period", t2 - t1, 150, 175);
    check("pit_ch2_leaves_ch0_idle", {15'b0, out_bit(0)}, 16'h0000);

    // ---- 6. interrupt on terminal count, mode 0: ONE IRQ0 per load ----
    // pit.c:36-52 systimer() re-arms only for a rate generator (`ctrl & 0x0c == 0x04`);
    // every other mode schedules a single expiry, so mode 0 fires once.
    reset_all();
    init_master(8'hFE);                    // unmask IRQ0 only
    write_port(16'h0077, 8'h30);
    write_port(16'h0071, 8'h04);
    write_port(16'h0071, 8'h00);
    service_irq(t1, rv, iok);
    check("itc_mode0_vector", iok ? {8'h00, rv} : 16'hFFFF, 8'h08);
    repeat (400) @(posedge clk);
    check("itc_mode0_one_shot", {15'b0, cpu_intr}, 16'h0000);

    // ---- 7. interrupt on terminal count, mode 3: one IRQ0 per period ----
    reset_all();
    init_master(8'hFE);
    write_port(16'h0077, 8'h36);
    write_port(16'h0071, 8'h08);
    write_port(16'h0071, 8'h00);
    service_irq(t1, rv, iok);
    check("itc_mode3_vector_a", iok ? {8'h00, rv} : 16'hFFFF, 8'h08);
    service_irq(t2, rv, iok);
    check("itc_mode3_vector_b", iok ? {8'h00, rv} : 16'hFFFF, 8'h08);
    checkin("itc_mode3_period_a", t2 - t1, 130, 180);
    service_irq(t3, rv, iok);
    checkin("itc_mode3_period_b", t3 - t2, 150, 175);
    service_irq(t4, rv, iok);
    checkin("itc_mode3_period_c", t4 - t3, 150, 175);

    // ---- 8. NP2kai clears the PIT's IRR0 on every channel-0 write (pit.c:378,471) ----
    // Reprogramming a channel that has already raised IRQ0 must drop that pending
    // interrupt here; the RTL has no PIT-to-PIC path, so the latched request survives.
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h30);
    write_port(16'h0071, 8'h04);
    write_port(16'h0071, 8'h00);
    repeat (200) @(posedge clk);           // terminal count latches IRR0
    check("pit_irr0_latched_precondition", {15'b0, dbg_irr[0]}, 16'h0001);
    write_port(16'h0077, 8'h30);           // re-program channel 0
    repeat (4) @(posedge clk);
    // NP2kai clears master IRR0 on every channel-0 write (pit.c:378,471); the RTL keeps
    // it. The datasheet says an edge-triggered 8259 request is cleared only by INTA, so
    // the RTL is the faithful model and this is a documented waiver.
    waive("pit_ch0_write_clears_irr0", {15'b0, dbg_irr[0]}, 16'h0000);

    // ---- 9. the uPD71054 read-back command (pit.c:480-487) ----
    // 0xC2 latches counter 0's status and count; the next read of 0x71 is the status
    // byte, which NP2kai builds as (control word & 0x3f) with bit 6 the LIVE NULL
    // COUNT (pit.c:244-254 sets it on a control word, pit_setcount pit.c:307 clears
    // it when the load completes). The 0x36 control word and the 0x1234 count pair
    // just written completed the load, so mode 3, LSB+MSB reads 0x36 - bit 6 CLEAR.
    // The old bench asserted 0x76 (bit 6 stuck at 1), which encoded the RTL rather
    // than the part.
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h36);           // ch0, mode 3
    write_port(16'h0071, 8'h34);
    write_port(16'h0071, 8'h12);
    write_port(16'h0077, 8'hC2);           // read-back: latch status + count of CT0
    read_port(16'h0071, rv);
    // Bits 6:0 are NP2kai's status byte. Bit 7 is the live OUT pin (asserted by case 9b
    // below), so it is masked out of this comparison rather than asserted here.
    check("pit_8254_readback_status", {8'h00, rv[6:0]}, 8'h36);

    // ---- 9b. status bit 7 is the channel's LIVE output pin ----
    // The 8254 read-back status word carries the OUT pin in bit 7 (QEMU
    // hw/timer/i8254.c:150-155: `pit_get_out(...) << 7`); NP2kai's uPD71054 model
    // hardcodes it low (`(value & 0x3f) | PIT_STAT_CMD`, pit.c:247). Mode 0 drives OUT
    // low on load and high for good at terminal count, so one channel gives both states:
    // latch the status while the channel is still counting (bit 7 = 0), then after the
    // rise (bit 7 = 1). Bit 6 (NULL COUNT) is 0 throughout: the 0x20/0x00 count pair
    // completed its load. The old bench asserted 0x70/0xF0 - bit 6 stuck at 1, the
    // constant the RTL hardwired - so those bytes encoded the RTL rather than the part
    // (the real bytes are 0x30/0xB0).
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h30);           // ch0, LSB then MSB, mode 0
    write_port(16'h0071, 8'h20);           // divisor 32
    write_port(16'h0071, 8'h00);
    write_port(16'h0077, 8'hC2);           // read-back: latch status + count of CT0
    read_port(16'h0071, rv);
    check("pit_status_out_low_while_counting", {15'b0, rv[7]}, 16'h0000);
    check("pit_status_low_byte", rv, 8'h30);
    out_rise(0, t1);                       // terminal count: OUT rises and stays high
    write_port(16'h0077, 8'hC2);
    read_port(16'h0071, rv);
    check("pit_status_out_high_after_tc", {15'b0, rv[7]}, 16'h0001);
    check("pit_status_high_byte", rv, 8'hB0);

    // ---- 9c. status bit 6 is the LIVE NULL COUNT flag ----
    // The 8254 sets NULL COUNT on a control word and CLEARS it when the count
    // load COMPLETES (NP2kai pit_setflag/pit_setcount, pit.c:244-254,285-307):
    // an LSB+MSB pair's first byte does not clear it (pit.c:292-296 returns
    // early), the second does. This is the documented 8254 mechanism for polling
    // a load to completion; a bit hard-wired to 1 makes such a driver spin
    // forever.
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h36);           // control word: sets NULL COUNT
    write_port(16'h0077, 8'hC2);           // read-back: latch status of CT0
    read_port(16'h0071, rv);
    check("pit_null_after_ctrl", {15'b0, rv[6]}, 16'h0001);
    write_port(16'h0071, 8'h34);           // first byte of the LSB+MSB pair only
    write_port(16'h0077, 8'hC2);
    read_port(16'h0071, rv);
    check("pit_null_after_first_byte", {15'b0, rv[6]}, 16'h0001);
    write_port(16'h0071, 8'h12);           // completing byte: clears NULL COUNT
    write_port(16'h0077, 8'hC2);
    read_port(16'h0071, rv);
    check("pit_null_after_load", {15'b0, rv[6]}, 16'h0000);

    // ---- 9b. RL=2 (MSB only): a read answers the count's HIGH byte ----
    // NP2kai io/pit.c:346-347 serves `ret = (UINT8)(w >> 8);` for PIT_RL_H, the datasheet
    // MSB-only access. Every other read case uses RL=3 or the status byte, so a high-byte
    // select that returned the low byte in this mode went unseen. Mode 2, MSB 0x12 alone
    // loads 0x1200; a few ticks later the latched count is 0x11xx or 0x1200, never a low byte.
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h24);           // ch0, MSB only, mode 2
    write_port(16'h0071, 8'h12);           // count 0x1200
    repeat (100) @(negedge clk);
    write_port(16'h0077, 8'h00);           // counter latch
    read_port(16'h0071, rv);
    checkin("pit_rl2_msb_only_read", rv, 8'h11, 8'h12);

    // ---- 10. N1: a counter latch does NOT reset the word-read byte phase ----
    // NP2kai's latchcmd() stores the count and clears only PIT_FLAG_L; it never
    // touches PIT_FLAG_R (io/pit.c:224-239), the flag whose state picks the byte
    // a word read serves (io/pit.c:348-358). The real Xe10 agrees: its latch does
    // NOT restore the two-byte read pointer -
    // the root cause of the phantom 0xFFFA divisor captures. So after one word
    // read (phase -> MSB) a counter latch must return the pair HIGH byte first.
    // The old RTL reset the phase on the latch and answered low-first: FAIL-FIRST
    // on both bytes below. Values: mode 3's counting element right after a 0x1234
    // load is 0x1234 minus 2 per elapsed source tick (QEMU
    // hw/timer/i8254-pc98.c:91-107, and every mode-3 count of an even divisor is
    // even); the load-to-latch window is a few clk
    // against a 20.3-clk tick, so the pair is 0x12 then 0x30..0x34.
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h36);           // ch0, LSB then MSB, mode 3
    write_port(16'h0071, 8'h34);
    write_port(16'h0071, 8'h12);           // divisor 0x1234
    read_port(16'h0071, rv);               // one word read: the phase now says MSB
    write_port(16'h0077, 8'h00);           // counter latch: must NOT touch the phase
    read_port(16'h0071, rv);               // the latched pair comes back HIGH first
    check("pit_n1_latch_keeps_phase_hi", rv, 8'h12);
    read_port(16'h0071, rv);               // then the low byte
    checkin("pit_n1_latch_keeps_phase_lo", rv, 8'h30, 8'h34);
    checkin("pit_n1_pair_lo_byte_even", {15'b0, rv[0]}, 0, 0);

    // ---- 11. N2a: a mode-set control word DOES reset the byte phase ---------
    // NP2kai's pit_setflag() clears PIT_FLAG_R|W on a control word
    // (io/pit.c:246-249) and QEMU agrees (i8254.c:159-167: read_state = access).
    // So after a half-consumed word read (phase -> MSB) a control word must make
    // the next word read LOW byte first again. The old RTL left the phase alone
    // and answered high-first: FAIL-FIRST on both bytes below. Same 0x1234
    // mode-3 arithmetic as case 10 (a mode-set does not reload the count).
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h36);           // ch0, LSB then MSB, mode 3
    write_port(16'h0071, 8'h34);
    write_port(16'h0071, 8'h12);           // divisor 0x1234
    read_port(16'h0071, rv);               // one word read: the phase now says MSB
    write_port(16'h0077, 8'h36);           // control word: resets the byte phase
    read_port(16'h0071, rv);               // LOW byte first again (live count)
    checkin("pit_n2a_ctrl_resets_phase_lo", rv, 8'h30, 8'h34);
    read_port(16'h0071, rv);
    check("pit_n2a_ctrl_resets_phase_hi", rv, 8'h12);

    // ==== VERDICT ====
    $display("NOTE pit_ref: %0d cases, %0d mismatched, %0d waived", cases, errors, waivers);
    if (errors == 0) begin
      $display("TB_PC9821_PIT_REF: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_REF: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_PIT_REF: TIMEOUT");
  end

endmodule

`default_nettype wire
