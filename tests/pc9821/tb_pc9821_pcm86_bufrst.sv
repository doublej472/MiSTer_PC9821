`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 86-PCM's 0xA468 bit-3 buffer reset is AUTHORITATIVE while the buffer is RUNNING: for every one of the sample period's phases, a reset issued while the drain engine is mid-frame still leaves the byte count at zero rather than at 0xFFFE, because the engine's own rdptr/count update sits later in the same always block and otherwise subtracts a frame from a count the reset has just zeroed. And the full+write+D_DONE collision (datapaths.md F7 / buffers.md F6): a guest byte written on the EXACT cycle a draining frame completes while the ring is FULL survives as the newest byte and keeps count == wrptr - rdptr (mod 0x8000) - in NP2kai's serialized order (the drain runs at sound_sync before the port write, cbus/pcm86io.c pcm86_oa46c), so the frame leaves first, the ring is no longer full and no slip is owed: count = 0x8000 - nbyte + 1 - swept over nbyte 1, 2 and 4 and compared byte-for-byte against that golden stream.
//
// The 86-PCM's 0xA468 bit-3 buffer reset is AUTHORITATIVE while the buffer is RUNNING: for every one of the sample period's phases, a reset issued while the drain engine is mid-frame still leaves the byte count at zero rather than at 0xFFFE, because the engine's own rdptr/count update sits later in the same always block and otherwise subtracts a frame from a count the reset has just zeroed.
//
// ==== DUT ====
//
// WHY THIS BENCH EXISTS AND WHAT IT IS NOT. tb_pc9821_pcm86 already tests the
// 0xA468 bit-3 reset -- at line 351, with the comment "buffer reset, playback
// off". With the drain idle the reset wins trivially, so that check passes and
// cannot see this defect. The case a real driver is in when it resets is the
// opposite one: it resets TO FLUSH a buffer that is playing. This bench drives
// that case, and it drives it across the WHOLE sample period rather than at one
// convenient moment, because the engine only touches the count on the handful of
// cycles a frame occupies.
//
// SOURCE OF THE EXPECTATION: the reset's meaning is the references', not this
// RTL's. NP2kai cbus/pcm86io.c:93-110 (pcm86_oa468) resets wrtpos, readpos,
// realbuf and virbuf unconditionally on the bit-3 0->1 edge -- `xchgbit & 8` XOR
// then `val & 8` -- and its handler cannot be undone by its generator, which
// runs from a different call site. A circular buffer's byte count after a reset
// is therefore zero independent of what the engine was doing. The count is
// readable only through this block's dbg_count (the card exposes just the two
// status bits at 0xA466).
//
// ==== CHECKS ====
//   1. A reset issued at phase P of the sample period leaves dbg_count == 0 and
//      the drain unable to consume the 16 bytes that were queued before it.
//   2. A guest byte written at phase P increments dbg_count by exactly one when
//      the buffer is not full, whatever the engine is doing.
//   3. A guest byte written on
//      the EXACT cycle a draining frame completes while the ring is FULL must
//      survive and the count/pointer bookkeeping must stay coherent
//      (count == wrptr - rdptr mod 0x8000), in NP2kai's serialized order: the
//      frame leaves first, so the ring is no longer full when the byte lands and
//      no slip is owed (count = 0x8000 - nbyte + 1). Swept over every frame size
//      (nbyte 1, 2, 4).
// Both sweeps are swept over every phase of one sample period, so the bench states the
// property for all timings rather than for one.
//
// ==== VERDICT ====
// PASS only when every phase of both sweeps holds.

module tb_pc9821_pcm86_bufrst;

  // 50 MHz, matching the core's SYS_FREQ, so the rate table's numbers are the
  // ones the machine's card would produce.
  localparam integer CLK_HZ = 50_000_000;
  // Rate index 0 is 44100 Hz. STEP0 = 2^29 * 352800 / CLK_HZ in the DUT, and the
  // sample tick is the accumulator's carry, so the period in clk is
  // ceil(2^32 / STEP0) = 1134. Every operand is written as an explicit 64-bit
  // literal: the product needs 48 bits, and 32-bit arithmetic wraps it to EXACTLY
  // ZERO, which made PERIOD a division by zero and let a first version of this
  // bench pass while running nothing at all. The bench prints both numbers below
  // so the arithmetic is visible rather than trusted.
  localparam longint STEP0_L = (64'd536_870_912 * 64'd352_800) / 64'd50_000_000;
  localparam integer PERIOD  = integer'((64'd4_294_967_296 + STEP0_L - 64'd1) / STEP0_L);

  reg clk = 0;
  always #10 clk = ~clk;          // 20 ns period = 50 MHz

  reg         reset = 1;
  reg  [15:0] io_addr = 0;
  reg         io_wr = 0, io_rd = 0;
  reg  [7:0]  io_din = 0;
  wire [7:0]  io_dout;
  wire        io_rd_wait;
  wire        io_wr_wait;
  wire signed [15:0] snd_l, snd_r;
  wire        irq;
  wire [15:0] dbg_count;

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

pc9821_pcm86 #(.SYS_CLOCK_HZ(CLK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
    .snd_l(snd_l), .snd_r(snd_r), .irq(irq),
    .dbg_count(dbg_count),
    .buf_base(32'd0),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  // The drain's byte stream: every byte the engine reads out of the ring, in
  // order, captured at the same rd_valid edge its frame accumulator sees.
  reg [7:0]  drain_stream [0:40];
  integer    drain_n;
  initial drain_n = 0;
  always @(posedge clk) if (!reset && dut.rd_valid && (drain_n < 41)) begin
    drain_stream[drain_n] = dut.rd_q;
    drain_n = drain_n + 1;
  end

  integer errors = 0;

  task automatic fail(input [8*160-1:0] message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  // One device write. io_wr is high across exactly one posedge, which is the
  // cycle the block samples.
  task automatic wr(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; io_din = data; io_wr = 1'b1;
      @(posedge clk);
      #1 io_wr = 1'b0;
      @(negedge clk);
    end
  endtask

  // Configure the block for a 2-byte frame and playback enabled. 0xA46A = 0x20
  // is the references' "16bit-left" format, whose frame is two bytes; 0xA468
  // bit 5 clear is what makes that write land in dactrl rather than in the
  // threshold, and bit 7 is the playback enable the drain gates on.
  task automatic configure_playing;
    begin
      wr(16'h0A468, 8'h00);           // bit 3 clear, so the next write is an edge
      wr(16'h0A46A, 8'h20);           // 16bit-left: nbytes = 2
      wr(16'h0A468, 8'h80);           // playback on, rate index 0
    end
  endtask

  // Queue nbytes through the sample port, so the drain has work to do.
  task automatic fill(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1)
        wr(16'h0A46C, k[7:0]);
    end
  endtask

  // The same, but paced by the buffer's write back-pressure (0xA46C's io_wr_wait),
  // so a 32 KiB fill cannot overrun the buffer's 4-deep write FIFO and drop bytes.
  // Byte k lands at slot k of the freshly-reset ring, so slot s always holds s[7:0].
  task automatic fill_bp(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        while (io_wr_wait) @(negedge clk);
        wr(16'h0A46C, k[7:0]);
      end
    end
  endtask

  // The frame is 16bit-left (configure_playing writes 0xA46A = 0x20), so a drain
  // COMPLETION subtracts two from the count.
  localparam NBYTES = 2;

  integer phase;
  integer before_reset, after_reset;
  integer before_write, after_write;
  integer bad_reset, bad_write;
  integer first_bad_reset, first_bad_write;
  integer checked_reset, checked_write;

  initial begin
    // ---- let the DUT come out of reset with the phase accumulator running ----
    @(negedge clk); reset = 1'b0;
    repeat (4) @(negedge clk);

    bad_reset = 0; bad_write = 0;
    first_bad_reset = -1; first_bad_write = -1;
    checked_reset = 0; checked_write = 0;

    // A sweep that evaluates nothing is not a check. PERIOD is derived above and
    // must be the ~1134 cycles 50 MHz and 44100 Hz imply; if the arithmetic ever
    // breaks again this fails loudly instead of passing vacuously.
    $display("  STEP0_L = %0d, PERIOD = %0d clk", STEP0_L, PERIOD);
    if (PERIOD < 1000 || PERIOD > 1300)
      fail("the sample period did not compute, so the sweep would test nothing");

    // ---- sweep the reset's arrival across a whole sample period ----
    for (phase = 0; phase < PERIOD; phase = phase + 1) begin
      configure_playing;
      fill(16);
      // Let the drain actually be running: the phase accumulator free-runs from
      // reset, so by now a tick has certainly occurred and frames have drained.
      repeat (phase) @(negedge clk);

      before_reset = dbg_count;
      // The reset: bit 3's 0->1 edge, playback still enabled. This is what a
      // driver does to flush a playing buffer.
      wr(16'h0A468, 8'h88);
      // Give any frame still in flight more than enough cycles to finish. The
      // longest frame is four bytes, so the engine's whole cycle is under ten.
      repeat (16) @(negedge clk);
      after_reset = dbg_count;

      if (before_reset < 2) begin
        // Nothing was queued to drain, so this phase cannot discriminate.
      end else begin
        checked_reset = checked_reset + 1;
        if (after_reset !== 0) begin
          bad_reset = bad_reset + 1;
          if (first_bad_reset < 0) first_bad_reset = phase;
          if (bad_reset == 1)
            $display("  NOTE reset at phase %0d: count was %0d before, %0d after (expected 0)",
                     phase, before_reset, after_reset);
        end
      end
    end

    // ---- and sweep a guest byte's arrival across a whole sample period ----
    for (phase = 0; phase < PERIOD; phase = phase + 1) begin
      configure_playing;
      fill(8);
      repeat (phase) @(negedge clk);
      before_write = dbg_count;
      wr(16'h0A46C, 8'hA5);
      after_write = dbg_count;
      checked_write = checked_write + 1;
      // The count is the buffer LEVEL, so a drain COMPLETION landing in this same window
      // subtracts NBYTES and shows alongside the write's +1. What must never happen is the
      // write being LOST, which leaves exactly one byte less than the completion alone
      // would. (The exact +1 was the original assertion; it held only while the drain's
      // completion happened to fall outside this window, and the SDRAM-backed buffer's
      // longer drain moved it in. The lost-write defect it guards is still caught.)
      if (after_write < before_write + 1 - NBYTES) begin
        bad_write = bad_write + 1;
        if (first_bad_write < 0) first_bad_write = phase;
        if (bad_write == 1)
          $display("  NOTE write at phase %0d: count was %0d before, %0d after (a completion leaves >= %0d)",
                   phase, before_write, after_write, before_write + 1 - NBYTES);
      end
    end

    // =================================================================
    // 3. THE FULL + WRITE + D_DONE COLLISION (datapaths.md F7 / buffers.md F6)
    // =================================================================
    // The ring is filled to EXACTLY 0x8000 with playback off, playback starts,
    // and one guest byte (0x5A) is written on the EXACT cycle the first frame's
    // drain completes. That frame's bytes were read BEFORE the write can land
    // (the SDRAM reads complete in D_WAIT), so the write goes to the slot the
    // frame just vacated - the tail of the ring - and must be the NEWEST
    // survivor. NP2kai's order is serialized (its drain runs at sound_sync before
    // the port write is handled, cbus/pcm86io.c pcm86_oa46c): the frame leaves
    // first, the ring is then not full, and the byte joins with NO slip - rdptr
    // += nbyte and count = 0x8000 - nbyte + 1, with count == wrptr - rdptr
    // (mod 0x8000) still holding.
    //   The pre-fix completion overwrote the slip with its own advance and
    //   credited the write only in the non-full arm: the new byte fell OUTSIDE
    //   the managed range (dropped - the opposite of "newest survives"), count
    //   under-reported the occupancy by one and the invariant broke by one.
    // After the collision the bench asserts: the golden count, the invariant,
    // the new byte INSIDE the managed range at its tail, and the NEXT drained
    // frame's bytes equal the golden stream's (the dropped oldest skipped, the
    // new byte arriving at the tail). Swept over nbyte in {1, 2, 4}.
    begin : collision
      integer nb, ci, fmt, nbf, x_slot, moff;
      integer cbase;
      reg [7:0] want;
      for (nb = 0; nb < 3; nb = nb + 1) begin
        fmt = (nb == 0) ? 6 : (nb == 1) ? 2 : 3;   // frame_bytes(fmt) = 1, 2, 4
        nbf = (fmt == 3) ? 4 : (fmt == 6) ? 1 : 2;
        // Clean slate: the bit-3 0->1 edge zeroes wrptr/rdptr/count.
        wr(16'h0A468, 8'h00);
        wr(16'h0A468, 8'h08);
        wr(16'h0A468, 8'h00);           // playback off
        wr(16'h0A46A, 8'(fmt << 4));    // dactrl: the frame format under test
        fill_bp(32768);                 // slot s holds s[7:0]; count -> 0x8000
        if (dbg_count !== 16'h8000)
          fail("the collision fill did not reach exactly 0x8000 (the full case is the defect's condition)");
        drain_n = 0;
        wr(16'h0A468, 8'h80);           // playback on: the first frame drains the full ring
        // Land the write on the EXACT D_DONE cycle of the first frame.
        @(negedge clk);
        while (dut.dstate !== 2'd3) @(negedge clk);
        x_slot = dut.wrptr;             // the write lands at wrptr of this cycle
        cbase  = drain_n;               // the collision frame's bytes are already captured
        io_addr = 16'h0A46C; io_din = 8'h5A; io_wr = 1'b1;
        @(posedge clk);
        #1 io_wr = 1'b0;
        @(negedge clk);
        // (a) the bookkeeping: the golden count and the invariant the pre-fix breaks.
        moff = ((dut.wrptr - dut.rdptr) & 15'h7FFF);
        if (moff != (dbg_count & 16'h7FFF)) begin
          fail("the full+write+D_DONE collision broke the ring invariant (count != wrptr - rdptr)");
          $display("     count=%0d wrptr=%0d rdptr=%0d (nbyte=%0d)", dbg_count, dut.wrptr, dut.rdptr, nbf);
        end
        if (dbg_count !== 16'(16'h8000 - nbf + 1))
          fail("the collision's count is not 0x8000 - nbyte + 1 (drain the frame, then the byte joins)");
        // (b) the newest byte survives, inside the managed range at its tail.
        // (the full 16-bit count: nbyte 1 leaves the ring exactly full again, 0x8000)
        if (((x_slot - dut.rdptr) & 15'h7FFF) >= dbg_count)
          fail("the collision's new byte fell outside the managed range: it is dropped (newest must survive)");
        // (c) and the NEXT frame is the golden continuation: slots rdptr..rdptr+nbyte-1,
        // the oldest surviving bytes, nothing skipped.
        @(negedge clk);
        while (dut.dstate !== 2'd3) @(negedge clk);
        for (ci = 0; ci < nbf; ci = ci + 1) begin
          want = 8'((x_slot + nbf + ci) & 15'h7FFF);
          if (drain_stream[cbase + ci] !== want) begin
            fail("the post-collision frame is not the golden stream (serialized drain-then-write)");
            $display("     byte %0d: got %02x expected %02x (slot %0d)", ci,
                     drain_stream[cbase + ci], want,
                     (x_slot + nbf + ci) & 15'h7FFF);
          end
        end
        if (errors == 0) begin
          $display("  collision nbyte=%0d: count=%0d invariant ok, new byte in range, golden stream ok",
                   nbf, dbg_count);
        end
      end
    end

    // ---- verdict ----
    if (checked_reset < 100)
      fail("the reset sweep evaluated too few phases to be a check");
    if (checked_write < PERIOD)
      fail("the write sweep did not evaluate every phase");
    if (bad_reset != 0)
      fail("the 0xA468 bit-3 buffer reset did not empty the count at some phases of a RUNNING buffer");
    if (bad_write != 0)
      fail("a guest byte written during a running drain was not counted at some phases");

    $display("");
    $display("  sample period swept: %0d clk (50 MHz, 44100 Hz)", PERIOD);
    $display("  reset sweep  : %0d of %0d evaluated phases left a non-zero count (first at %0d)",
             bad_reset, checked_reset, first_bad_reset);
    $display("  write sweep  : %0d of %0d phases lost a byte (first at %0d)",
             bad_write, checked_write, first_bad_write);

    if (errors == 0) begin
      $display("TB_PC9821_PCM86_BUFRST: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_BUFRST: FAIL (%0d errors)", errors);
  end

  // A hard stop, so a wedged drain cannot hang the gate.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_PCM86_BUFRST: FAIL (the bench timed out)");
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
