`timescale 1ns/1ps

// tb_pc9821_pcm86_underrun - the 86-PCM DAC on a STARVED buffer must output silence.
//
// ==== WHAT THIS PROVES ====
// The 86-PCM DAC on a STARVED buffer outputs SILENCE, not the last frame: with playback enabled (0xA468 bit 7) and the count below the 0xA46A format's frame_bytes - the references' own 'effectively empty' level, pcm86_ia466's virbuf <= stepmask / qemu's count < frame_bytes - every sample period is exactly 0 on both channels. NP2kai zeroes smp/lastsmp on all four *_bufempty paths (sound/pcm86g.c:105-109,188-194,259-263,341-347) and qemu stores l = r = 0 as the DAC state (opna_pcm_consume, hw/audio/pc98-opna.c:289-325), so neither repeats the previous frame. FAIL-FIRST: it FIRST requires a frame to be observed at the output, so the starved window is measured against a live non-zero hold - the pre-fix RTL held that frame forever and fails by name. The frame-size boundary is covered too (one byte of a 2-byte 16-bit frame is silent even though count != 0), and the drain recovers when the frame completes.
//
// TB_PC9821_PCM86_UNDERRUN: when playback is enabled (0xA468 bit 7) and the sample buffer
// cannot supply a whole frame for a sample period -- count < the 0xA46A format's
// frame_bytes, the references' own "effectively empty" level -- the card's DAC outputs
// ZERO for that period. It does NOT repeat the frame before it. The zero-order hold is
// only for the gap BETWEEN frames: with playback left enabled and a drained buffer, a
// held sample is a stuck DC level, which eats headroom on one rail at the machine's single
// final clamp (pc9821_audio_mix's mix_dry) for as long as the guest leaves the DAC on.
//
// ==== WHERE THE EXPECTED VALUES COME FROM (never from this RTL) ====
//   * NP2kai (PRIMARY) - each of the four generator paths abandons its sample state when the
//     buffer runs short, so the following output periods are silent:
//       pm16_bufempty   sound/pcm86g.c:105-109   (`smp = 0; lastsmp = 0;`)
//       ps16_bufempty   sound/pcm86g.c:188-194   (`smp_l/r = 0; lastsmp_l/r = 0;`)
//       pm8_bufempty    sound/pcm86g.c:259-263
//       pm8_stereo8_bufempty sound/pcm86g.c:341-347
//     and the level those paths guard is NP2kai's own "effectively empty": the generator
//     takes a frame only when realbuf >= the frame size (a byte for 8-bit, two for 16-bit),
//     the same condition pcm86_ia466 reports as the empty BIT (`virbuf <= stepmask`,
//     cbus/pcm86io.c:288-295).
//   * qemu - `opna_pcm_consume` leaves l = r = 0 when `pcm_count < frame_bytes` and stores
//     those zeros as the DAC state (`pcm_last_l = l;` hw/audio/pc98-opna.c:289-325), so
//     `opna_pcm_render` adds 0 for every following period (`:347-348`).
//   BOTH references therefore put ZERO on the output, not the previous frame.
//
// ==== WHY IT IS FAIL-FIRST ====
// The checks below FIRST require a frame to be played and observed at the output (so the
// starved window is measured against a live, NON-ZERO hold), and only then require that the
// starved periods read exactly 0. An implementation that holds the last frame instead (the
// pre-fix RTL) passes the first part and fails the second, by name, with the held value
// printed.
//
// ==== DUT ====
// The real pc9821_pcm86 (its own ports and its own sample clock) with the SDRAM third-port
// stand-in the buffer benches use. The bench drives the ports directly: 0xA466 volume,
// 0xA468 mode/playback, 0xA46A format, 0xA46C data. It honours `io_wr_wait`, so no byte is
// dropped by the write FIFO and the only thing under test is the DAC's starved behaviour.
//
// ==== CHECKS ====
// CHK-1 playback DISABLED with a byte buffered: the output is 0 (the reference's contract
//       for bit 7 clear), so CHK-2's zero cannot be an accident of the enable path.
// CHK-2 ONE 8-bit frame played, then the buffer drained with playback still ENABLED: the
//       frame is observed at the output (non-zero), and every sample period after it is
//       exactly 0. Pre-fix the held frame stays forever.
// CHK-3 the frame-size boundary: in 16-bit-left mode (2 bytes per frame) a single byte in
//       the buffer is NOT a frame, so the period is silent even though `count != 0`; the
//       completing byte then plays the frame. A fix that zeroed only at count == 0 fails
//       here by holding the previous frame.
// CHK-4 recovery: a frame written after a silent period plays, and it is played INSIDE the
//       sample period the drain picks it up in (a ONE-period limit, not three), so a frame in
//       flight is never the reason a period reads silent.
//
// ==== VERDICT ====
// PASS when a starved period is exactly 0 on both channels after a frame has been observed,
// and the drain resumes. FAIL naming the check and printing the held value.

module tb_pc9821_pcm86_underrun;

  localparam integer CLK_HZ = 100_000_000;

  reg clk = 0;
  always #5 clk = ~clk;             // 10 ns, so rate index 0 (44100 Hz) is 2267.6 clk/sample
  reg reset = 1;
  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  // ---- host port ----------------------------------------------------------
  reg  [15:0] io_addr = 0;
  reg         io_wr   = 0;
  reg         io_rd   = 0;
  reg  [7:0]  io_din  = 0;
  wire [7:0]  io_dout;
  wire        io_rd_wait, io_wr_wait;
  // ---- output + the buffer level the "effectively empty" rule is about ----
  wire signed [15:0] snd_l, snd_r;
  wire        irq;
  wire [15:0] count;

  // ---- the buffer's SDRAM third port --------------------------------------
  wire        sdram_valid, sdram_ready, sdram_write, sdram_resp_valid;
  wire [31:0] sdram_addr, sdram_din, sdram_dout;
  wire  [3:0] sdram_be;
  wire  [7:0] sdram_burstcount;

  pc9821_pcm86 #(.SYS_CLOCK_HZ(CLK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
    .snd_l(snd_l), .snd_r(snd_r), .irq(irq), .dbg_count(count),
    .buf_base(32'd0),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  pcm86_sdram_model u_sdram (
    .clk(clk), .reset(reset),
    .valid(sdram_valid), .ready(sdram_ready), .write(sdram_write),
    .addr(sdram_addr), .din(sdram_din), .dout(sdram_dout),
    .resp_valid(sdram_resp_valid), .be(sdram_be)
  );

  // The DUT's own sample strobe, so the bench waits in SAMPLE PERIODS rather than in a
  // cycle count derived from the rate table.
  integer ticks = 0;
  always @(posedge clk) if (!reset && dut.sample_tick) ticks = ticks + 1;

  task automatic fail(input [1023:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // A host write: one clk-wide request_write strobe, held off while the buffer's write
  // FIFO back-pressures, exactly as pc9821_iobus holds its S_IOWAIT state.
  task automatic port_write(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      while (io_wr_wait) @(negedge clk);
      io_addr = addr;
      io_din  = data;
      io_wr   = 1'b1;
      @(negedge clk);
      io_wr   = 1'b0;
    end
  endtask

  task automatic wait_ticks(input integer n);
    integer target;
    begin
      target = ticks + n;
      while (ticks < target) @(posedge clk);
    end
  endtask

  // Poll the LEFT output for the value a played frame must produce, for up to `limit`
  // sample periods. qemu's law is `sample * volume / 15` (hw/audio/pc98-opna.c:347-348) and
  // the 0xA466 write 0xA0 is vol5 = 15, i.e. unity, so a played frame's level is the sample
  // itself to within the implementation's one-LSB Q16 truncation (65535/65536, strictly
  // below unity). The check is therefore `sample-1 <= out <= sample`, never an exact
  // equality against this tree's arithmetic.
  task automatic expect_frame(input signed [15:0] sample, input integer limit,
                              input [1023:0] what, output integer seen);
    integer target;
    begin
      seen   = 0;
      target = ticks + limit;
      while ((ticks <= target) && !seen) begin
        @(negedge clk);
        if ((snd_l <= sample) && (snd_l >= sample - 16'sd1)) seen = 1;
      end
      if (!seen) begin
        $display("FAIL: %0s -- left output is %0d, expected %0d..%0d",
                 what, snd_l, sample - 16'sd1, sample);
        errors = errors + 1;
      end
    end
  endtask

  // Watch both channels for `n` sample periods and return the largest magnitude seen. The
  // starved expectation is exactly 0, so anything else is the held frame showing through.
  task automatic window_max_abs(input integer n, output integer peak);
    integer target;
    begin
      peak   = 0;
      target = ticks + n;
      while (ticks < target) begin
        @(negedge clk);
        if (snd_l > peak) peak = snd_l;
        if (-snd_l > peak) peak = -snd_l;
        if (snd_r > peak) peak = snd_r;
        if (-snd_r > peak) peak = -snd_r;
      end
    end
  endtask

  // The starved measurement. A frame legitimately occupies its OWN sample period, so the
  // window has to start at the period boundary AFTER the state that should silence it: wait
  // out the current period first, then measure `n` whole periods from the next one. Measuring
  // immediately would count the frame's own period and cannot tell a hold from a play.
  task automatic expect_silence(input integer n, output integer peak);
    begin
      wait_ticks(1);
      window_max_abs(n, peak);
    end
  endtask

  integer seen, peak;

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (50) @(posedge clk);

    // =====================================================================
    // CHK-1: playback DISABLED with a byte buffered -> silence. Both
    // references gate the generator on 0xA468 bit 7 (NP2kai pcm86gen_getpcm,
    // sound/pcm86g.c:370-376; qemu opna_pcm_render, pc98-opna.c:333-335).
    // =====================================================================
    port_write(16'h0A466, 8'hA0);        // vol5 = ~0xA0 & 0xF = 15, i.e. unity
    port_write(16'h0A46A, 8'h60);        // 8-bit LEFT: one byte per frame
    port_write(16'h0A46C, 8'h7F);        // 0x7F00 signed, the frame CHK-2 will play
    if (count !== 16'd1)
      fail("the buffered byte did not land (0xA466/DAC path or the file is broken)");
    window_max_abs(2, peak);
    if (peak != 0) begin
      $display("FAIL: CHK-1 playback disabled still output %0d", peak);
      errors = errors + 1;
    end
    $display("  CHK-1 playback off, one byte buffered: peak=%0d (expected 0)", peak);

    // =====================================================================
    // CHK-2 (the fail-first): play the frame, then starve the buffer with
    // playback STILL ENABLED. The frame must be observed, and every period
    // after it must be exactly 0.
    // =====================================================================
    port_write(16'h0A468, 8'h80);        // playback enable, rate index 0 (44100 Hz)
    expect_frame(16'sh7F00, 3, "CHK-2 the buffered frame never played", seen);
    if (!seen) $display("       (nothing to starve: the first failure is above)");
    if (count !== 16'd0)
      fail("CHK-2 the frame did not drain: the buffer is not starved yet");
    expect_silence(3, peak);
    $display("  CHK-2 frame 0x7F00 played, then 3 starved periods: peak=%0d", peak);
    if (peak != 0) begin
      $display("       the held frame is still on the output -- NP2kai/qemu emit 0 here");
      fail("CHK-2 a STARVED period is not silence: the DAC repeats the last frame");
    end

    // =====================================================================
    // CHK-3: the "effectively empty" boundary is a whole FRAME, not count == 0.
    // 16-bit LEFT is 2 bytes per frame, so one byte in the buffer is not a
    // frame and the period is silent; the second byte then plays the sample.
    // =====================================================================
    port_write(16'h0A468, 8'h08);        // playback off + buffer reset (bit 3 edge)
    port_write(16'h0A46A, 8'h20);        // DAC ctrl: 16-bit LEFT (fmt 2)
    port_write(16'h0A46C, 8'h12);        // frame 0x1234, high byte first
    port_write(16'h0A46C, 8'h34);
    port_write(16'h0A468, 8'h80);        // playback enable again
    expect_frame(16'sh1234, 3, "CHK-3 the 16-bit frame never played", seen);
    if (count !== 16'd0)
      fail("CHK-3 the 16-bit frame did not drain");
    port_write(16'h0A46C, 8'h56);        // ONE byte: fewer than a frame
    if (count !== 16'd1)
      fail("CHK-3 the half-frame byte did not land");
    expect_silence(3, peak);
    $display("  CHK-3 one byte of a 16-bit frame, 3 periods: peak=%0d", peak);
    if (peak != 0) begin
      $display("       count=1 of a 2-byte frame must read as EMPTY (pcm86_ia466's");
      $display("       virbuf <= stepmask / qemu's count < frame_bytes), not as a hold");
      fail("CHK-3 a partial frame was played from the previous frame's held value");
    end

    // =====================================================================
    // CHK-4: recovery -- the completing byte plays the frame, so the zeroing
    // did not wedge the drain engine. The 1-Period limit is also the drain's
    // LATENCY bound: a frame that the buffer can supply is read (four SDRAM
    // round trips at most) and latched INSIDE the same sample period, so a
    // starved period is only ever the buffer being short, never the engine
    // still working on the previous frame.
    // =================================================================
    port_write(16'h0A46C, 8'h78);        // completes the frame: 0x5678
    expect_frame(16'sh5678, 1, "CHK-4 the drain never recovered after the under-run", seen);
    expect_silence(2, peak);
    $display("  CHK-4 recovery frame 0x5678 played, then starved again: peak=%0d", peak);
    if (peak != 0)
      fail("CHK-4 the output did not return to silence after the recovery frame");

    if (errors == 0) begin
      $display("TB_PC9821_PCM86_UNDERRUN: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_UNDERRUN: FAIL (%0d errors)", errors);
  end

  // A hard stop, so a wedged handshake cannot hang the gate.
  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_PCM86_UNDERRUN: TIMEOUT");
  end

endmodule

// pcm86_sdram_model: the SDRAM third-port handshake and a 32 KiB byte store, for the PCM86
// (declared per bench, as the other PCM86 benches do).
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
