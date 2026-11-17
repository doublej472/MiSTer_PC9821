`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 86-PCM's 0xA466 phase bit free-runs at the selected sample rate (its period one sample period at every one of the eight rate indices of NP2kai's pcm86rate8 table) and keeps toggling while playback is DISABLED, because a driver calibrates the card by watching that bit before it ever starts playback and would hang on a frozen one.
//
// ---- the bench's own account of where the expectation comes from ----
//
// THE CONTRACT, and why it is not the implementation written down. The bit is a
// divide of the card's sample clock, so what a guest can observe is its RATE. The
// thing that can silently be wrong is whether it runs when playback is off, and
// that is not a detail: the card's own driver measures this bit to work out the
// sample clock before it programs anything.
//
//   [source, from-NP2kai] cbus/pcm86io.c:286, pcm86_ia466:
//
//       ret = ((past << 1) >= stepclock) ? 1 : 0;
//
//   `past` is the time since the last sample, and it is advanced from the CPU
//   clock with NO reference to whether playback is enabled -- the `fifo & 0x80`
//   test a few lines above guards only RECALC_NOWCLKWAIT, a host-side timing
//   recalculation, not the phase computation. So on the reference the bit keeps
//   toggling with the buffer stopped.
//
//   [source, the RTL's own header, src/pcm86/pc9821_pcm86.sv] The block states the
//   same thing and names the alternative: "The accumulator free-runs whether or
//   not playback is enabled, because that calibration happens BEFORE playback
//   starts; qemu's does not, and a driver waiting for transitions on a frozen bit
//   is the hang qemu's own comment warns about."
//
// (The RTL header's "qemu's does not" is not what qemu does: qemu-pc98
// hw/audio/pc98-opna.c:474-491 opna_pcm_read computes bit 0 from the virtual clock,
// `muldiv64(now, rate*2, 1e9) & 1`, with no playback test either - it free-runs too, but
// at the table's 8x clock, not the sample rate. The references disagree on the RATE;
// this bench follows NP2kai's sample-rate period.)
//
// That is what makes this worth a test rather than a comment. A future change that
// "simplifies" the block toward qemu's shape is a plausible mistake, it would look
// like a tidy-up, and nothing in this tree would catch it -- the existing pcm86
// bench explicitly masks bit 0 ("the free-running sample phase, so it is masked")
// because its expectations are about the full/empty bits beside it.
//
// WHAT IS ASSERTED, and it is one behaviour seen two ways: the bit toggles while
// playback is disabled (a frozen bit fails, bounded, rather than hanging), and the
// period between its rising edges is one sample period at the selected rate. The
// second half is what makes the first half meaningful: a bit that toggled at the
// wrong rate would be just as useless to a driver calibrating against it.
//
// The rates are the reset rate (index 0, 44100 Hz, no 0xA468 write at all) and
// index 4 (11025 Hz). Both are checked with 0xA468 bit 7 CLEAR throughout, which is
// the state a driver calibrates in and the state the existing bench never visits.
//
// WHAT THIS DOES NOT COVER, stated so it is not assumed: this is from-a-reference
// only. No register of this card has ever been measured on the real machine,
// so if the machine turns out to
// freeze the bit, this bench is asserting the reference's behaviour and not the
// machine's, and the difference would be found by that probe and not here.

module tb_pc9821_pcm_phase;
  reg clk = 0;
  always #5 clk = ~clk;   // 10 ns = 50 MHz, the SYS_CLOCK_HZ below

  reg         reset = 1;
  reg  [15:0] io_addr = 16'hFFFF;
  reg         io_wr = 0, io_rd = 0;
  reg  [7:0]  io_din = 8'h00;
  wire [7:0]  io_dout;
  wire        io_rd_wait, irq;
  wire signed [15:0] snd_l, snd_r;
  wire [15:0] dbg_count;

  localparam [15:0] P_VOLUME = 16'h0A466;
  localparam [15:0] P_FIFO   = 16'h0A468;

  // ==== DUT ====
  // The sample buffer's SDRAM side (src/pcm86/pc9821_pcm86_buf.sv): the third port of the
// memory controller, which the bench stands in for.
wire        sdram_valid, sdram_ready, sdram_write, sdram_resp_valid;
wire [31:0] sdram_addr, sdram_din, sdram_dout;
wire  [3:0] sdram_be;
wire  [7:0] sdram_burstcount;
pcm86_sdram_model u_sdram (
  .clk(clk), .reset(reset),
  .valid(sdram_valid), .ready(sdram_ready), .write(sdram_write),
  .addr(sdram_addr), .din(sdram_din), .dout(sdram_dout),
  .resp_valid(sdram_resp_valid), .be(sdram_be)
);

pc9821_pcm86 #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk(clk), .reset(reset),
      .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
      .io_dout(io_dout), .io_rd_wait(io_rd_wait),
      .snd_l(snd_l), .snd_r(snd_r), .irq(irq), .dbg_count(dbg_count),
      .buf_base(32'd0),
      .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
      .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
      .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
      .sdram_burstcount(sdram_burstcount)
  );

  // ==== CHECKS ====

  integer errors = 0;

  // One write through the device bus, the way the I/O bus presents it: the
  // address and data are stable and io_wr is high for exactly one clk.
  //
  // It RESTORES the 0xA466 read address afterwards, and that is not tidiness: the
  // block's read arm is combinational on the address, so leaving the bus pointed
  // at 0xA468 makes every later sample of "the phase bit" read the control
  // register's bit 0 instead -- the rate's LSB, which is 0 for the rates this
  // bench uses. The first version of this bench did exactly that and reported the
  // accumulator frozen, which is how the mistake was found.
  task automatic write_port(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1'b1;
      @(posedge clk); #1;
      io_wr = 1'b0;
      @(negedge clk);
      io_addr = P_VOLUME; io_rd = 1'b1;   // back to the port whose bit 0 we watch
      #1;
    end
  endtask

  // Hold the 0xA466 read up and sample its bit 0. The block's read path is
  // combinational on the address (its own read arm is an always @* case), so no
  // handshake is needed: driving the address is enough to see the bit every clk.
  task automatic phase_read_start;
    begin
      @(negedge clk);
      io_addr = P_VOLUME; io_rd = 1'b1;
      #1;
    end
  endtask

  // The period, in clk cycles, between successive RISING edges of 0xA466 bit 0.
  //
  // Bounded on purpose: a frozen bit must FAIL, not hang. The budget is a little
  // over ten times the slowest period this bench measures, so a bit that toggles
  // at all -- even at a badly wrong rate -- is counted, and only a bit that never
  // toggles runs out. That is what makes this a test of the free-running property
  // rather than of the arithmetic.
  task automatic period_between_rises(output integer period, output integer ok,
                                      input integer budget, input [255:0] what);
    integer waited, prev, seen_high, started;
    begin
      period = 0; ok = 0; waited = 0; started = 0; seen_high = 0;
      prev = io_dout[0];
      while (waited < budget && !ok) begin
        @(posedge clk); waited = waited + 1;
        if (prev === 1'b0 && io_dout[0] === 1'b1) begin
          if (!started) begin
            started = 1; period = 0;
          end else begin
            ok = 1;
          end
        end
        if (started) period = period + 1;
        prev = io_dout[0];
      end
      if (!ok) begin
        $display("FAIL %0s: 0xA466 bit 0 did not produce two rising edges within %0d clk with playback disabled -- the phase accumulator is not free-running (a frozen bit is the hang a driver calibrating against it would suffer)", what, budget);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_period(input integer want, input integer tol, input [255:0] what);
    integer period, ok;
    begin
      period_between_rises(period, ok, want * 12 + 2000, what);
      if (ok) begin
        if (period < want - tol || period > want + tol) begin
          $display("FAIL %0s: 0xA466 bit 0 period is %0d clk, expected %0d +/- %0d", what, period, want, tol);
          errors = errors + 1;
        end
      end
    end
  endtask

  integer period, ok;

  initial begin
    // ---- reset, then leave it. 0xA468 reads 0x00 after reset, so bit 7 is
    // CLEAR and playback is DISABLED for everything below: this is the state a
    // driver calibrates in.
    repeat (8) @(posedge clk);
    reset = 0;
    repeat (8) @(posedge clk);

    if (dut.fifo[7] !== 1'b0) begin
      $display("FAIL: playback is enabled out of reset (0xA468 = %02x), so this bench would not be measuring the disabled case", dut.fifo);
      errors = errors + 1;
    end

    phase_read_start();

    // ---- 1. the reset rate: index 0, 352800/8 = 44100 Hz -> 1134 clk --------
    // 50e6 / 44100 = 1133.8, and the accumulator's step is floor()ed, so the
    // observed period is 1134.
    check_period(1134, 3, "free-running phase period at the reset rate (44100 Hz, playback disabled)");

    // ---- 2. rate index 4: 88200/8 = 11025 Hz -> 4535 clk --------------------
    // Still with playback disabled: only the rate field changes, and bit 7 stays
    // clear. If a change gated the accumulator on playback, check 1 would fail
    // first; if a change broke the rate table, this one fails.
    write_port(P_FIFO, 8'h04);
    repeat (4) @(posedge clk);
    if (dut.fifo[7] !== 1'b0) begin
      $display("FAIL: the 0xA468 write enabled playback (0xA468 = %02x, bit 7 must stay clear here)", dut.fifo);
      errors = errors + 1;
    end
    check_period(4535, 4, "free-running phase period at rate index 4 (11025 Hz, playback disabled)");

    // ---- 2b. every other rate index, playback still disabled ------------------
    // NP2kai sound/pcm86c.c:34-35 pcm86rate8[] = {352800, 264600, 176400, 132300,
    // 88200, 66150, 44010, 33075} (eight times each sample rate), so the period at index
    // i is 50e6 * 8 / pcm86rate8[i] clk: 1511.7, 2267.6, 3023.4, 6046.9, 9088.9 and
    // 12093.8 for indices 1, 2, 3, 5, 6 and 7, held to the nearest clk +/- 4.
    begin : all_rates
      integer r;
      integer rate8 [0:7];
      rate8[0] = 352800; rate8[1] = 264600; rate8[2] = 176400; rate8[3] = 132300;
      rate8[4] = 88200;  rate8[5] = 66150;  rate8[6] = 44010;  rate8[7] = 33075;
      for (r = 1; r < 8; r = r + 1) begin
        if (r == 4) continue;
        write_port(P_FIFO, 8'(r));
        repeat (4) @(posedge clk);
        check_period((400_000_000 + rate8[r] / 2) / rate8[r], 4,
                     "free-running phase period at a rate index from the pcm86rate8 table");
      end
      write_port(P_FIFO, 8'h04);
      repeat (4) @(posedge clk);
    end

    // ---- 3. and it is the same rate with playback ENABLED -------------------
    // The enable must not change the clock the guest calibrates against.
    write_port(P_FIFO, 8'h84);
    repeat (4) @(posedge clk);
    if (dut.fifo[7] !== 1'b1) begin
      $display("FAIL: 0xA468 bit 7 did not set playback (0xA468 = %02x)", dut.fifo);
      errors = errors + 1;
    end
    check_period(4535, 4, "free-running phase period at rate index 4 with playback ENABLED (the enable must not move the rate)");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PCM_PHASE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM_PHASE: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_PCM_PHASE: TIMEOUT");
  end

endmodule

// pcm86_sdram_model: the SDRAM third-port handshake and a 32 KiB byte store, for the PCM86
// benches. The buffer moved out of block RAM (src/pcm86/pc9821_pcm86_buf.sv), so each bench
// supplies the SDRAM side. The real controller answers a read after its CAS latency; this
// answers after one wait cycle, which is enough to exercise the request/valid handshake.
module pcm86_sdram_model (
  input  wire        clk, reset,
  input  wire        valid,
  output reg         ready,
  input  wire        write,
  input  wire [31:0] addr,
  input  wire [31:0] din,
  output reg  [31:0] dout,
  output reg         resp_valid,
  input  wire  [3:0] be
);
  reg [7:0]  mem [0:32767];
  reg [1:0]  st;
  reg [31:0] lat_addr;
  reg        lat_wr;
  integer    i;
  wire [14:0] wbase = {lat_addr[14:2], 2'b00};
  always @(posedge clk) begin
    ready      <= 1'b0;
    resp_valid <= 1'b0;
    if (reset) begin
      st <= 2'd0;
      for (i = 0; i < 32768; i = i + 1) mem[i] <= 8'h00;
    end else case (st)
      2'd0: if (valid) begin
              ready    <= 1'b1;
              lat_addr <= addr;
              lat_wr   <= write;
              st       <= 2'd1;
            end
      2'd1: begin
              if (lat_wr) begin
                if (be[0]) mem[wbase]     <= din[7:0];
                if (be[1]) mem[wbase + 1] <= din[15:8];
                if (be[2]) mem[wbase + 2] <= din[23:16];
                if (be[3]) mem[wbase + 3] <= din[31:24];
                st <= 2'd0;
              end else begin
                dout <= {mem[wbase + 3], mem[wbase + 2], mem[wbase + 1], mem[wbase]};
                st   <= 2'd2;
              end
            end
      default: begin
              resp_valid <= 1'b1;
              st         <= 2'd0;
            end
    endcase
  end
endmodule
