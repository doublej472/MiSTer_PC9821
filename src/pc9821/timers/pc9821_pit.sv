// 8253 PIT - PC-9821 MiSTer core. 3 independent 16-bit down-counters, modes 0
// (interrupt), 2 (rate generator) and 3 (square wave), the one-shots 1 and 4/5, with a
// latched count readback.
//
// PC-9821 ports: 0x71 channel 0 (timer tick -> IRQ 0), 0x73 channel 1, 0x75 channel 2,
// 0x77 control word. The input clock is 2.4576 MHz, which is load-bearing rather than
// trivia: the ITF requires an I/O access to outlast one PIT tick (50e6/2.4576e6 = 20.34
// cycles at clk_sys), which is why io_access_cycles has a floor rather than a minimum.
//
// The main BIOS programs channel 0 as mode 3 with a divisor for ~100 Hz.

`default_nettype none

module pc9821_pit #(
    parameter SYS_CLOCK_HZ   = 25000000,
    parameter INPUT_CLOCK_HZ = 2457600
) (
    input wire clk,   // the system clock (not the PIT input clock;
                      // the PIT counts down at the system rate
                      // divided by the programmed period)
    input wire rst_n,

    // CPU I/O interface (from pc98_iobus)
    input  wire       cs,    // chip select (I/O address match)
    input  wire [1:0] addr,  // channel select (0=ch0, 1=ch1, 2=ch2, 3=ctrl)
    input  wire       wr,    // I/O write strobe
    input  wire       rd,    // I/O read strobe
    input  wire [7:0] din,   // I/O write data
    output wire [7:0] dout,  // I/O read data

    // outputs
    output wire out0,  // channel 0 output (timer tick -> IRQ 0)
    output wire out1,  // channel 1 output
    output wire out2   // channel 2 output
);

  // per-channel state
  reg [15:0] count[0:2];  // current countdown value
  reg [15:0] reload[0:2];  // programmed reload value
  reg [1:0] rw_mode[0:2];  // read/write format (0=latch, 1=LSB, 2=MSB, 3=LB+MB)
  reg [2:0] mode[0:2];  // operating mode (0-5; a written 6/7 is stored as 2/3)
  // The control word's bits the behaviour does not need but the read-back status returns
  // verbatim (NP2kai io/pit.c pit_setflag: `pitch->ctrl = (UINT8)((value & 0x3f) | ...)`,
  // latched whole as the status): mode_hi[ch] says a 6/7 was written, bcd[ch] is bit 0.
  reg mode_hi[0:2];
  reg bcd[0:2];
  // Modes 1/4/5 are one-shots: one OUT event per count write (NP2kai io/pit.c systimer
  // re-arms PIT_FLAG_I only for `(pitch->ctrl & 0x0c) == 0x04`, modes 2/3). armed[ch] is set
  // by a count load and cleared by the terminal-count event, so the counter can wrap and keep
  // counting (8254 mode 4: no reload) without a second strobe.
  reg armed[0:2];
  reg running[0:2];  // channel is counting
  reg lsb_written[0:2];  // for 16-bit access: LSB written, waiting for MSB
  reg output_ff[0:2];  // output flip-flop (for square-wave mode)
  reg [15:0] read_latch[0:2];  // latched count for readback
  reg read_latched[0:2];  // a latch command is pending for this channel
  reg read_latch_2nd[0:2];  // the second word byte of a latched pair is
                            // outstanding (NP2kai's PIT_FLAG_L,
                            // io/pit.c:331-335: a word latch is consumed over
                            // two reads, one read in a byte mode)
  reg read_hi[0:2];       // word-read byte phase: 0 = the next word read returns
                          // the LSB, 1 the MSB. It advances ONLY on word data
                          // reads and resets ONLY on a mode-set control word
                          // (NP2kai's PIT_FLAG_R: toggled at io/pit.c:358,
                          // cleared at io/pit.c:248-249, untouched by a latch
                          // at io/pit.c:224-239 - and the Xe10's latch does not
                          // restore the read pointer either)
  reg read_stat_pend[0:2];  // a read-back STATUS byte is waiting (read before the count)
  reg [7:0] read_status[0:2];
  reg null_count[0:2];  // 8254 NULL COUNT: the count register has not been loaded
                        // (since reset or the last control word)

  // Exact reduced-fraction enable from the system clock.
  // At 50 MHz and 2.4576 MHz, ratio 2457600/50000000 reduces by gcd 3200 to
  // 768/15625 in lowest terms. A 14-bit accumulator replaces the 33-bit
  // adder + 33-bit comparator + 32-bit subtractor.
  function automatic integer gcd(input integer a, input integer b);
    integer t;
    begin
      while (b != 0) begin
        t = b;
        b = a % b;
        a = t;
      end
      gcd = a;
    end
  endfunction

  localparam integer DIV_GCD = gcd(INPUT_CLOCK_HZ, SYS_CLOCK_HZ);
  localparam integer INC_VAL = INPUT_CLOCK_HZ / DIV_GCD;
  localparam integer MOD_VAL = SYS_CLOCK_HZ / DIV_GCD;
  localparam integer PHASE_W = $clog2(MOD_VAL + 1);

  reg [PHASE_W-1:0] pit_phase;
  wire [PHASE_W:0] pit_sum = {1'b0, pit_phase} + INC_VAL[PHASE_W-1:0];
  // pit_diff's top bit is deliberately unread: it is consumed only when pit_tick is set, and
  // pit_tick means pit_sum >= MOD_VAL, so pit_diff < 2**PHASE_W and that bit is always zero.
  // The extra bit stays so the subtraction cannot wrap.
  // MOD_VAL is sliced to pit_sum's width because PHASE_W = $clog2(MOD_VAL+1) guarantees
  // MOD_VAL < 2**PHASE_W, so every bit above PHASE_W is zero and the comparison is exact -
  // and a same-width compare needs no 32-bit expansion. Line 71 already did this; 72 did not.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [PHASE_W:0] pit_diff = pit_sum - MOD_VAL[PHASE_W:0];
  wire pit_tick = (pit_sum >= MOD_VAL[PHASE_W:0]);
  /* verilator lint_on UNUSEDSIGNAL */

  // Mode 3 counts half-periods. For odd divisors the high phase gets the
  // extra source clock; a programmed zero means 65536 and yields 32768/32768.
  function automatic [15:0] mode3_half(input [15:0] value, input high_phase);
    reg [16:0] full_count;
    begin
      full_count = (value == 16'd0) ? 17'h10000 : {1'b0, value};
      mode3_half = full_count[16:1] + (high_phase ? {15'd0, full_count[0]} : 16'd0);
    end
  endfunction

  // The value a READ presents for a channel: the 8253/8254 counting element.
  // In mode 3 that element holds the FULL divisor and decrements by 2 per source
  // clock (the high phase carries the extra clock of an odd divisor), where this
  // core counts half-periods down by 1. QEMU reads the element back as
  // count - ((2 * d) % count) with d the ticks since the load
  // (hw/timer/i8254-pc98.c:100-103); against the half-period remainder c that is
  // exactly 2*c - 1 on an odd divisor's high phase and 2*c everywhere else
  // (2*c mod 2^16, so a 65536 divisor wraps through 0 like the part). Only the
  // reload's bit 0 matters - a divisor's parity - so that is what is passed.
  // The conversion lives ONLY here: the output toggle and tick cadence are untouched,
  // and (N - read) / 2 is again the elapsed ticks games calibrate with.
  function automatic [15:0] count_element(
      input [15:0] cnt,
      input        rld_odd,
      input [2:0]  md,
      input        high_phase
  );
    begin
      count_element = (md == 3'd3)
          ? ({cnt[14:0], 1'b0} - {15'd0, high_phase && rld_odd})
          : cnt;
    end
  endfunction

  // The counting element of each channel, formed once and selected by the three consumers below
  // (the read-back latch command, the control-word latch and the live read mux), so the
  // mode-3 `2*c - 1` decrement exists three times, not once per consumer.
  wire [15:0] elem0 = count_element(count[0], reload[0][0], mode[0], output_ff[0]);
  wire [15:0] elem1 = count_element(count[1], reload[1][0], mode[1], output_ff[1]);
  wire [15:0] elem2 = count_element(count[2], reload[2][0], mode[2], output_ff[2]);
  wire [15:0] elem_ri [0:2];
  assign elem_ri[0] = elem0;
  assign elem_ri[1] = elem1;
  assign elem_ri[2] = elem2;

  // Single next-count calculation for the tick path.
  // Replaces separate 9-way muxes across mode 0, mode 2, mode 3, and default.
  function automatic [15:0] pit_tick_next(
      input [15:0] cnt,
      input [15:0] rld,
      input [2:0]  md,
      input        out_ff
  );
    begin
      if (cnt > 16'd1) begin
        pit_tick_next = cnt - 16'd1;
      end else if (md == 3'd3) begin
        pit_tick_next = mode3_half(rld, ~out_ff);
      end else if (cnt == 16'd0) begin
        pit_tick_next = 16'hFFFF;
      end else if (md == 3'd2) begin
        pit_tick_next = rld;
      end else begin
        // Modes 0, 1, 4 and 5 do not reload: the counter reaches 0 and wraps
        // (8254 datasheet, modes 0/1/4/5).
        pit_tick_next = 16'd0;
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // I/O write
  // ---------------------------------------------------------------
  integer ch;
  integer ri;
  // write_load/write_val are LOCAL VARIABLES, not state, and the blocking assignments below
  // are what make that work. Each is defaulted at the top of the block, set by whichever case
  // arm decoded the write, and read four lines later to drive ONE SHARED reload path - all
  // three data-write arms end at the same `if (write_load)`. With non-blocking assignments the
  // value would not be visible to that `if` in the same evaluation, and the count reload would
  // have to be duplicated into every arm; that single-path shape is a fix, not an
  // accident. Both are re-derived every cycle, so nothing is carried between cycles.
  /* verilator lint_off BLKSEQ */   // deliberate local variables in a clocked block
  reg write_load;
  reg [15:0] write_val;
  // The R4 merged OUT events (see the single next-state loop at the bottom of
  // the block): t_out_* is the tick's OUT transition, w_out_* the level a count
  // reload or mode-set wants to drive. Both are per-cycle blocking locals,
  // re-derived every cycle; output_ff itself has ONE writer (the merge loop),
  // so no assignment order can decide a coincidence.
  reg t_out_ev  [0:2];
  reg t_out_val [0:2];
  reg w_out_ev  [0:2];
  reg w_out_val [0:2];
  // armed[ch]'s events, merged once at the bottom (R4): a count load arms, a mode-set
  // disarms, the terminal-count strobe disarms. A load in the strobe's own cycle is a new
  // count and wins, exactly as its count[ch] assignment does.
  reg arm_load  [0:2];
  reg arm_clear [0:2];
  // R7 deferred level: a reload that collides with a tick OUT transition owes
  // its idle level for the next cycle without one (defer, not lose).
  reg out_pend     [0:2];
  reg out_pend_val [0:2];
  always @(posedge clk) begin
    write_load = 1'b0;
    write_val  = 16'd0;
    for (ch = 0; ch < 3; ch = ch + 1) begin
      t_out_ev[ch]  = 1'b0;
      t_out_val[ch] = 1'b0;
      w_out_ev[ch]  = 1'b0;
      w_out_val[ch] = 1'b0;
      arm_load[ch]  = 1'b0;
      arm_clear[ch] = 1'b0;
    end
    if (!rst_n) begin
      for (ch = 0; ch < 3; ch = ch + 1) begin
        count[ch]        <= 16'h0;
        reload[ch]       <= 16'h0;
        rw_mode[ch]      <= 2'd3;
        mode[ch]         <= 3'd0;
        mode_hi[ch]      <= 1'b0;
        bcd[ch]          <= 1'b0;
        armed[ch]        <= 1'b0;
        running[ch]      <= 1'b0;
        lsb_written[ch]  <= 1'b0;
        output_ff[ch]    <= 1'b0;
        read_latched[ch] <= 1'b0;
        read_latch[ch]   <= 16'h0;
        read_hi[ch]      <= 1'b0;
        read_latch_2nd[ch] <= 1'b0;
        read_stat_pend[ch] <= 1'b0;
        read_status[ch]  <= 8'h00;
        null_count[ch]   <= 1'b1;  // no count loaded yet
        out_pend[ch]     <= 1'b0;
        out_pend_val[ch] <= 1'b0;
      end
      pit_phase <= {PHASE_W{1'b0}};
    end else begin
      if (pit_tick) pit_phase <= pit_diff[PHASE_W-1:0];
      else pit_phase <= pit_sum[PHASE_W-1:0];

      if (pit_tick) begin
        // decrement the counters
        for (ch = 0; ch < 3; ch = ch + 1) begin
          if (running[ch]) begin
            count[ch] <= pit_tick_next(count[ch], reload[ch], mode[ch], output_ff[ch]);
            case (mode[ch])
              3'd0, 3'd1: begin  // interrupt on terminal count; mode 1 counted from the load
                // Mode 0 keeps counting past the terminal count (wraps through
                // 0 to 0xFFFF and down) with OUT latched high - QEMU
                // (s->count - d) & 0xffff (hw/timer/i8254-pc98.c:97) and
                // NP2kai's remain both keep moving, so a read must too.
                // Clearing running here froze the counter at 0 forever.
                if ((count[ch] == 16'd1) && (output_ff[ch] != 1'b1)) begin
                  t_out_ev[ch] = 1'b1; t_out_val[ch] = 1'b1;
                end
              end
              3'd2: begin  // rate generator: high except one source clock
                if (((count[ch] == 16'd1) ? 1'b0 : 1'b1) != output_ff[ch]) begin
                  t_out_ev[ch] = 1'b1; t_out_val[ch] = (count[ch] != 16'd1);
                end
              end
              3'd3: begin  // square wave: toggle output at each half-period
                if (count[ch] <= 16'd1) begin
                  t_out_ev[ch] = 1'b1; t_out_val[ch] = ~output_ff[ch];
                end
              end
              default: begin  // modes 4/5: one low strobe of one CLK at terminal count
                // 8254 mode 4: "When the initial count expires, OUT will go low for
                // one CLK pulse and then go high again"; the counter wraps and does
                // not strobe again until a new count is written (armed).
                if ((count[ch] == 16'd1) && armed[ch]) begin
                  t_out_ev[ch] = 1'b1; t_out_val[ch] = 1'b0;
                  arm_clear[ch] = 1'b1;
                end else if ((count[ch] == 16'd0) && !output_ff[ch]) begin
                  t_out_ev[ch] = 1'b1; t_out_val[ch] = 1'b1;
                end
              end
            endcase
          end
        end
      end

      // A read consumes the latched value. Without this the latch set by one
      // command would stay pending for good, so the channel would report a
      // frozen count forever and every read returned the LSB
      // regardless of the programmed access mode.
      if (cs && rd && addr != 2'd3) begin
        if (read_stat_pend[addr]) begin
          // The 8254 returns a latched STATUS byte before the count bytes; one read
          // consumes it, then the count sequence runs normally.
          read_stat_pend[addr] <= 1'b0;
        end else case (rw_mode[addr])
          2'd1, 2'd2: begin
            // One byte read consumes the whole pair in a byte mode.
            read_latched[addr]   <= 1'b0;
            read_latch_2nd[addr] <= 1'b0;
          end
          default: begin
            // TWO independent jobs here. The byte PHASE (read_hi) advances on
            // every word read, live or latched; the latch is consumed over two
            // word reads in that phase's order (NP2kai's PIT_FLAG_R / PIT_FLAG_L
            // split, io/pit.c:331-358). Folding both into one bit would let a
            // latch reset the phase.
            read_hi[addr] <= ~read_hi[addr];
            if (read_latched[addr]) begin
              read_latched[addr]   <= 1'b0;
              read_latch_2nd[addr] <= 1'b1;
            end else begin
              read_latch_2nd[addr] <= 1'b0;
            end
          end
        endcase
      end

      if (cs && wr) begin
        if (addr == 2'd3) begin
          // Channel select 3 is the 8254 read-back command (uPD71054 on the PC-9821,
          // NP2kai io/pit.c:480-487; QEMU hw/timer/i8254.c:143-159). Bits 3:1 select
          // the counter, bit 5 (0) latches the count and bit 4 (0) the status, each
          // independently. An 8253 has no read-back, but this machine's part is a 8254.
          if (din[7:6] == 2'd3) begin
            // One counter per set bit of RB3:1: RB1 selects CT0, RB2 CT1, RB3 CT2
            // (NP2kai's `for (chnum=0; chnum<3; chnum++) if (dat & (2 << chnum))`,
            // ioc.c:482-486). A command with no counter bit set selects nothing.
            for (ri = 0; ri < 3; ri = ri + 1) begin
              if (din[ri+1]) begin
                if (!din[5]) begin
                  // latchcmd() stores the count and clears only the
                  // latch-consumption flag (NP2kai PIT_FLAG_L,
                  // io/pit.c:233-236); it does NOT reset the byte phase
                  // (PIT_FLAG_R), and the Xe10's latch does not restore the
                  // read pointer either.
                  read_latched[ri]   <= 1'b1;
                  read_latch[ri]     <= elem_ri[ri];
                  read_latch_2nd[ri] <= 1'b0;
                end
                if (!din[4]) begin
                  // Status = the control word's bits 5:0 with bit 6 the LIVE
                  // NULL COUNT and bit 7 the LIVE OUT pin. NP2kai's pit_setflag
                  // sets PIT_STAT_CMD on a control word and pit_setcount clears
                  // it when the count load completes (io/pit.c:247,307); the
                  // 8254 status word carries OUT in bit 7 and QEMU builds it the
                  // same way (hw/timer/i8254.c:150-155, `pit_get_out(...) << 7`).
                  read_stat_pend[ri] <= 1'b1;
                  read_status[ri]    <= {output_ff[ri], null_count[ri],
                                         rw_mode[ri], mode[ri][2] | mode_hi[ri],
                                         mode[ri][1:0], bcd[ri]};
                end
              end
            end
          end else begin
            ch = {30'd0, din[7:6]};
            if (din[5:4] == 2'd0) begin
              // Counter latch command. NP2kai's latchcmd() sets the C flag,
              // clears the L (second-byte) flag and stores the count
              // (io/pit.c:224-239) - and does NOT touch PIT_FLAG_R: the pair is
              // consumed in whatever order the byte phase is in, which is what
              // the Xe10 shows (its latch does not restore the read pointer).
              read_latched[ch]   <= 1'b1;
              read_latch[ch]     <= elem_ri[ch];
              read_latch_2nd[ch] <= 1'b0;
            end else begin
              rw_mode[ch] <= din[5:4];
              mode[ch] <= (din[3:1] >= 3'd6) ? (din[3:1] - 3'd4) : din[3:1];
              mode_hi[ch] <= din[3] && din[2];
              arm_clear[ch] = 1'b1;
              bcd[ch] <= din[0];
              lsb_written[ch] <= 1'b0;
              // A mode-set control word is the ONLY thing that resets the
              // word-read byte phase (NP2kai's pit_setflag clears
              // PIT_FLAG_R|W, io/pit.c:246-249).
              read_hi[ch] <= 1'b0;
              // A mode-set control word arms NULL COUNT: the 8254 flags the
              // count register as not loaded until a count write completes it
              // (NP2kai pit_setflag's `(value & 0x3f) | PIT_STAT_CMD`,
              // io/pit.c:247).
              null_count[ch] <= 1'b1;
              // A mode-set command must NOT stop the channel: the authentic ITF's timer self-test
              // (BANK4@0x373) writes
              // control/data/control and then requires the data read to differ
              // from the value it wrote (error if the read equals it), on a
              // channel that is still counting. The real part continues the
              // count in progress until a new count is written, and NP2kai's
              // pit_setflag (pit.c:244-254) does not stop the channel either.
              // Only mode 0 starts low; modes 1-5 set OUT high on the control word
              // (8254 datasheet: "After the Control Word is written, OUT is high"
              // for modes 1, 4 and 5; modes 2 and 3 likewise).
              w_out_ev[ch]  = 1'b1;
              w_out_val[ch] = (din[3:1] != 3'd0);
            end
          end
        end else begin
          // channel data write
          ch = {30'd0, addr[1:0]};
          case (rw_mode[ch])
            2'd1: begin  // LSB only
              reload[ch][7:0] <= din;
              write_load       = 1'b1;
              write_val        = {reload[ch][15:8], din};
            end
            2'd2: begin  // MSB only
              reload[ch][15:8] <= din;
              write_load        = 1'b1;
              write_val         = {din, reload[ch][7:0]};
            end
            2'd3: begin  // LSB then MSB
              if (!lsb_written[ch]) begin
                reload[ch][7:0] <= din;
                lsb_written[ch] <= 1'b1;
              end else begin
                reload[ch][15:8] <= din;
                lsb_written[ch]  <= 1'b0;
                write_load        = 1'b1;
                write_val         = {din, reload[ch][7:0]};
              end
            end
            default: ;
          endcase

          // Single reload path across all write arms
          if (write_load) begin
            running[ch] <= 1'b1;
            arm_load[ch] = 1'b1;
            // The load is complete (an LSB-only/MSB-only byte, or the MSB of an
            // LSB+MSB pair - the first byte of a pair never reaches this path):
            // NULL COUNT clears, exactly as NP2kai pit_setcount does at the end
            // of io/pit.c:285-307.
            null_count[ch] <= 1'b0;
            count[ch] <= (mode[ch] == 3'd3) ? mode3_half(write_val, 1'b1) : write_val;
            // Reloading mode 0 starts a new one-shot and drives OUT low,
            // allowing the next terminal count to create a fresh IRQ edge.
            // The level rides the R4 merge below (w_out_*), so a same-cycle
            // terminal-count OUT edge is never swallowed by it.
            // A mode-2/3 count write does NOT drive OUT: only the control word
            // sets it high (8254; the mode-set arm above). NP2kai's ch0 write
            // restarts the count and raises no interrupt (io/pit.c pit_o71), and
            // the 8254 leaves OUT alone. Forcing OUT high here turned every count
            // write landing in the low half into a phantom IRQ0 edge - master.lib's
            // BGM handler rewrites the ch0 count on every tick
            // (tb_pc9821_pit_reload_edge).
            // Mode 1 is counted from the load (NP2kai has no gate and fires one IRQ0
            // after the count; the 8254 drives OUT low at the trigger), so it starts
            // its one-shot the same way.
            if ((mode[ch] == 3'd0) || (mode[ch] == 3'd1)) begin
              w_out_ev[ch] = 1'b1; w_out_val[ch] = 1'b0;
            end
          end
        end
      end

      // THE R4 MERGE: output_ff's one and only writer. Two events want it in
      // one cycle -- a tick OUT transition (an edge the PIC's edge detector
      // must see; losing one is losing an IRQ0) and a count reload's idle level
      // -- and resolving them by source order lets the reload eat the transition
      // (mode 0: the terminal-count rise `<= 1'b1` swallowed by the reload's
      // `<= 1'b0`). Resolution, named and total: the TRANSITION lands this
      // cycle, the reload's level is DEFERRED to the first cycle with no tick
      // OUT event (out_pend, R7: defer, not lose). A newer level request
      // replaces an older deferred one, exactly as the last write wins
      // count[ch] above; a deferred level already met by the transition is
      // cancelled.
      for (ch = 0; ch < 3; ch = ch + 1) begin
        armed[ch] <= arm_load[ch] || (armed[ch] && !arm_clear[ch]);
        if (t_out_ev[ch]) begin
          output_ff[ch] <= t_out_val[ch];
          if (w_out_ev[ch]) begin
            out_pend[ch]     <= (w_out_val[ch] != t_out_val[ch]);
            out_pend_val[ch] <= w_out_val[ch];
          end else begin
            out_pend[ch]     <= out_pend[ch] && (out_pend_val[ch] != t_out_val[ch]);
          end
        end else if (w_out_ev[ch]) begin
          output_ff[ch] <= w_out_val[ch];
          out_pend[ch]  <= 1'b0;
        end else if (out_pend[ch]) begin
          output_ff[ch] <= out_pend_val[ch];
          out_pend[ch]  <= 1'b0;
        end
      end
    end
  end
  /* verilator lint_on BLKSEQ */

  // ---------------------------------------------------------------
  // I/O read
  // ---------------------------------------------------------------
  reg [7:0] dout_reg;
  reg [15:0] read_w;
  always @(*) begin
    if (cs && rd) begin
      if (addr == 2'd3) begin
        // Write-only on the real part: a PC-9821Xe10 reads 0xFF here, and
        // NP2kai agrees (its handler is NULL). Returning 0x00 looked like a
        // readable register holding zero.
        dout_reg = 8'hFF;
      end else if (read_stat_pend[addr]) begin
        // A latched read-back status byte comes out whole, before the count.
        dout_reg = read_status[addr];
      end else begin
        // Return the latched count while one is pending, otherwise the live
        // counter's counting-element value, taking the byte(s) the programmed
        // access mode asks for.
        read_w = (read_latched[addr] || read_latch_2nd[addr]) ? read_latch[addr]
                : elem_ri[addr];
        case (rw_mode[addr])
          2'd1:    dout_reg = read_w[7:0];    // LSB only
          2'd2:    dout_reg = read_w[15:8];   // MSB only
          default: dout_reg = read_hi[addr] ? read_w[15:8] : read_w[7:0];
        endcase
      end
    end else begin
      dout_reg = 8'hFF;
    end
  end
  assign dout = dout_reg;

  assign out0 = output_ff[0];
  assign out1 = output_ff[1];
  assign out2 = output_ff[2];

endmodule

`default_nettype wire
