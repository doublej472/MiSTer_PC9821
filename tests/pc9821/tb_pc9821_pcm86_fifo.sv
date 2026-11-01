`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PCM86_FIFO:
// The PC-9801-86's 86-PCM block against NP2kai, FIFO level rather than waveform: the reset values 0xA468 = 0x00 and 0xA46A = 0x32, 0xA466's full and empty bits at NP2kai's own thresholds (virbuf >= 0x8000 for full, virbuf <= stepmask for empty, so the empty boundary moves with the 0xA46A format field), the logical count saturating at 0x8000 and the oldest byte being dropped past it, the 0xA468 read substituting the interrupt for bit 4, and the buffer-low interrupt rising at the 0xA46A threshold and re-asserting on a bit-4-clear write while the buffer is still below threshold. The four spare ports NP2kai leaves as a dummy read (0xA462, 0xA464, 0xA46C, 0xA46E) are ASSERTED to answer pcm86_inpdummy's 0x00. And the 0xA46C write FIFO back-pressures its writer when full -- twelve pushes at the strobe cadence with the SDRAM port withheld are all held and land byte-exact, never dropped -- which is what io_wr_wait and the bus's S_IOWAIT hold now guarantee. The remaining measured divergences are named and printed rather than asserted: a 0xA468 bit-7 rising edge does not restart the sample clock where pcm86_oa468 resets lastclock, and an arming write with the count already at or below the threshold raises the interrupt on the next cycle where NP2kai waits datawriteirqwait.

// Reference: NP2kai (PRIMARY) cbus/pcm86io.c
// (pcm86_oa468, pcm86_oa46a, pcm86_oa46c, pcm86_ia466, pcm86_ia468, pcm86_inpdummy)
// and sound/pcm86c.c (pcm86_reset, pcm86_setpcmrate, pcm86rate8, pcm86_cb). Every
// expected byte and threshold below is quoted from one of those.

// ==== DUT ====
module tb_pc9821_pcm86_fifo;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;

  reg         reset = 1;
  reg  [15:0] io_addr = 16'hFFFF;
  reg         io_wr = 0, io_rd = 0;
  reg  [7:0]  io_din = 8'h00;
  wire [7:0]  io_dout;
  wire        io_rd_wait, io_wr_wait, irq;
  wire signed [15:0] snd_l, snd_r;
  wire [15:0] dbg_count;

  localparam [15:0] P_SPARE0 = 16'h0A462;
  localparam [15:0] P_SPARE1 = 16'h0A464;
  localparam [15:0] P_VOLUME = 16'h0A466;
  localparam [15:0] P_FIFO   = 16'h0A468;
  localparam [15:0] P_DAC    = 16'h0A46A;
  localparam [15:0] P_DATA   = 16'h0A46C;
  localparam [15:0] P_SPARE2 = 16'h0A46E;

  wire        sdram_valid, sdram_ready, sdram_write, sdram_resp_valid;
  wire [31:0] sdram_addr, sdram_din, sdram_dout;
  wire  [3:0] sdram_be;
  wire  [7:0] sdram_burstcount;
  reg         sdram_stall = 1'b0;   // withhold the SDRAM port (S6's burst case)
  pcm86_sdram_model u_sdram (
    .clk(clk), .reset(reset), .stall(sdram_stall),
    .valid(sdram_valid), .ready(sdram_ready), .write(sdram_write),
    .addr(sdram_addr), .din(sdram_din), .dout(sdram_dout),
    .resp_valid(sdram_resp_valid), .be(sdram_be)
  );

  pc9821_pcm86 #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
    .snd_l(snd_l), .snd_r(snd_r), .irq(irq), .dbg_count(dbg_count),
    .buf_base(32'd0),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  integer errors = 0;
  integer divergences = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  // One full sample period in clk at the reset rate: 50e6 / 44100 = 1133.8, and the
  // accumulator's step is floor()ed, so 1134.
  localparam integer PERIOD0 = 1134;

  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // A case where NP2kai and this RTL differ: PRINT it and count it, do not assert it.
  task automatic diverge(input [8*80-1:0] what, input [15:0] got, input [15:0] np2);
    begin
      $display("DIVERGENCE %0s: RTL=%04x NP2kai=%04x", what, got, np2);
      divergences = divergences + 1;
    end
  endtask

  // ==== STIMULUS ====
  task automatic write_port(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk); io_addr = addr; io_din = data;
      // S6 back-pressure: pc9821_iobus holds the access in S_IOWAIT while the
      // 0xA46C write FIFO is full; the bench presents the address and strobes
      // io_wr only once the buffer can take the byte, exactly as the held bus
      // does, so a full FIFO WAITS here and no byte is dropped.
      #1 while (io_wr_wait) @(negedge clk);
      io_wr = 1'b1;
      @(negedge clk); io_wr = 1'b0; io_din = 8'h00;
      @(negedge clk);
    end
  endtask

  // The block's read arm is combinational on the address, so one cycle with io_rd
  // high answers it.
  task automatic read_port(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk); io_addr = addr; io_rd = 1'b1;
      #1 data = io_dout;
      @(negedge clk); io_rd = 1'b0;
      @(negedge clk);
    end
  endtask

  // 0xA466's two level bits, at whatever the current count and format are.
  task automatic read_466(output [7:0] data);
    begin
      read_port(P_VOLUME, data);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] v, rb;
  integer   k, n, t0, delay;

  initial begin
    repeat (8) @(posedge clk);
    reset = 0;
    repeat (8) @(posedge clk);

    // ---- 1. the reset register values (NP2kai pcm86_reset) ----------------
    // memset zeroes the struct, then fifosize = 0x80 and dactrl = 0x32 are stored;
    // stepbit = 2 and stepmask = 3 follow from dactrl's format field.
    read_port(P_FIFO, rb);
    if (rb !== 8'h00) fail("0xA468 is not 0x00 out of reset");
    read_port(P_DAC, rb);
    if (rb !== 8'h32) fail("0xA46A is not the reset dactrl 0x32");
    read_466(v);
    if (v[7] !== 1'b0) fail("0xA466 reports full out of reset");
    if (v[6] !== 1'b1) fail("0xA466 does not report empty out of reset");

    // ---- 2. the empty boundary moves with the format field ----------------
    // pcm86_ia466: `else if (virbuf <= stepmask) ret |= 0x40`, with
    // stepbit = pcm86bits[(val >> 4) & 7] = {1,1,1,2,0,0,0,1}, so stepmask is
    // 3 for format 3 (16-bit stereo), 1 for 0-2 and 7, and 0 for 4-6 (8-bit).
    // The guest writes the format through 0xA468 bit 5 = 0 and then 0xA46A.
    write_port(P_FIFO, 8'h08);             // buffer reset; fifo = 0x08 leaves bit 5 clear
    write_port(P_FIFO, 8'h00);
    write_port(P_DAC, 8'h60);              // 8-bit left: 1 byte per frame, stepmask 0
    write_port(P_DATA, 8'h11);
    read_466(v);
    if (v[6] !== 1'b0) fail("one byte buffered reads empty in 1-byte-frame mode (NP2kai virbuf <= 0)");
    write_port(P_FIFO, 8'h08);             // reset
    write_port(P_FIFO, 8'h00);
    write_port(P_DAC, 8'h20);              // 16-bit left: 2 bytes per frame, stepmask 1
    write_port(P_DATA, 8'h11);
    read_466(v);
    if (v[6] !== 1'b1) fail("one byte buffered does not read empty in 2-byte-frame mode (NP2kai virbuf <= 1)");
    write_port(P_DATA, 8'h22);
    read_466(v);
    if (v[6] !== 1'b0) fail("two bytes buffered reads empty in 2-byte-frame mode");
    write_port(P_FIFO, 8'h08);             // reset
    write_port(P_FIFO, 8'h00);
    write_port(P_DAC, 8'h30);              // 16-bit stereo: 4 bytes per frame, stepmask 3
    for (k = 0; k < 3; k = k + 1) write_port(P_DATA, 8'h44);
    read_466(v);
    if (v[6] !== 1'b1) fail("three bytes buffered does not read empty in 4-byte-frame mode (NP2kai virbuf <= 3)");
    write_port(P_DATA, 8'h55);
    read_466(v);
    if (v[6] !== 1'b0) fail("four bytes buffered reads empty in 4-byte-frame mode");
    if (v[7] !== 1'b0) fail("the full bit set with four bytes buffered");

    // ---- 3. the buffer reset edge and the count --------------------------
    // pcm86_oa468 resets wrtpos/readpos/realbuf/virbuf on the 0->1 edge of bit 3.
    write_port(P_FIFO, 8'h08);
    if (dbg_count !== 16'd0) fail("the 0xA468 bit-3 buffer reset did not zero the count");
    write_port(P_FIFO, 8'h00);
    write_port(P_DAC, 8'h60);              // back to 1-byte frames
    for (k = 0; k < 5; k = k + 1) write_port(P_DATA, 8'hA0 + k[7:0]);
    if (dbg_count !== 16'd5) begin
      $display("FAIL: five 0xA46C writes left the count at %0d", dbg_count);
      errors = errors + 1;
    end

    // ---- 4. the buffer-low interrupt: threshold, fire, and the bit-4 clear ---
    // pcm86_oa46a: with 0xA468 bit 5 set the port is the threshold,
    // fifosize = (val + 1) << 7 (0xFF means 0x7ffc). pcm86_cb raises irqflag
    // when virbuf <= fifosize; pcm86_ia468 substitutes it for bit 4 of the fifo
    // byte (it masks ~0x10), and only a write with bit 4 clear withdraws it
    // (pcm86_oa468). The count must be ABOVE the threshold when bit 5 is set, or
    // the arming write itself fires -- that case is the divergence below.
    write_port(P_FIFO, 8'h28);             // buffer reset + threshold mode
    write_port(P_DAC, 8'h01);              // (1 + 1) << 7 = 0x100
    write_port(P_FIFO, 8'h08);             // buffer reset, threshold mode off
    write_port(P_DAC, 8'h60);              // 1-byte frames
    for (k = 0; k < 16'h0140; k = k + 1) write_port(P_DATA, k[7:0]);
    write_port(P_FIFO, 8'h20);             // threshold mode on; count 0x140 > 0x100
    read_port(P_FIFO, rb);
    if (rb[4] !== 1'b0) fail("the interrupt rose above the programmed threshold");
    write_port(P_FIFO, 8'hA0);             // arm + playback
    read_port(P_FIFO, rb);
    if (rb[4] !== 1'b0) fail("the interrupt rose above the programmed threshold after the arm");
    n = 0;
    while ((dbg_count > 16'h0100) && (n < 400000)) begin @(posedge clk); n = n + 1; end
    if (dbg_count > 16'h0100) fail("the buffer never drained to the programmed threshold");
    read_port(P_FIFO, rb);
    if (rb[4] !== 1'b1) fail("the interrupt did not rise when the count crossed the 0x100 threshold");
    if (irq !== 1'b1) fail("the interrupt line is low with the interrupt pending");
    write_port(P_FIFO, 8'hB0);             // bit 4 SET: this write must NOT clear
    read_port(P_FIFO, rb);
    if (rb[4] !== 1'b1) fail("a 0xA468 write with bit 4 SET cleared the interrupt");
    // B-3: a bit-4-clear write cannot extinguish a still-true level. The buffer
    // is still at/below 0x100, so the same write re-asserts the flag (NP2kai
    // pcm86_oa468 clears irqflag first, then the level sets it again).
    write_port(P_FIFO, 8'h20);             // bit 4 clear, level still true
    read_port(P_FIFO, rb);
    if (rb[4] !== 1'b1) fail("0xA468 bit 4 did not re-assert on a clear while the buffer is below threshold");
    if (irq !== 1'b1) fail("the interrupt line dropped on a clear while the buffer is still below threshold");

    // The arming write with the count ALREADY at or below the threshold: this RTL
    // raises bit 4 on the next cycle, where NP2kai's pcm86_cb waits
    // datawriteirqwait (20000 * multiple) after the write that armed
    // lastclockforwait, so a read taken now is 0 there.
    write_port(P_FIFO, 8'h08);             // reset buffer, playback off, bit 5 off
    write_port(P_FIFO, 8'h20);             // threshold mode on; count 0, nothing armed
    for (k = 0; k < 2; k = k + 1) write_port(P_DATA, 8'h77);
    read_port(P_FIFO, rb);
    if (rb[4] !== 1'b1)
      fail("the interrupt did not rise with the count below the threshold and a fresh data write");
    diverge("interrupt state immediately after arming with count already <= threshold", rb[4], 16'd0);

    // ---- 5. full at 0x8000, and the oldest byte dropped past it ----------
    // pcm86_oa46c: virbuf stops at PCM86_LOGICALBUF = 0x8000 and the byte is
    // still stored; the reference then slips readpos when realbuf passes the
    // rescue margin. The guest-visible count must sit at the ceiling, not wrap.
    write_port(P_FIFO, 8'h08);             // buffer reset
    write_port(P_FIFO, 8'h00);
    write_port(P_DAC, 8'h60);              // 1-byte frames, so count is bytes
    // The boundary itself, from below: NP2kai pcm86_ia466 sets bit 7 on
    // `g_pcm86.virbuf >= PCM86_LOGICALBUF` (cbus/pcm86io.c:261), so one byte short
    // of 0x8000 is NOT full (and not empty). Without this the bench saw full only
    // AT 0x8000 and a bit that rose a byte early passed.
    for (k = 0; k < 16'h7FFF; k = k + 1) write_port(P_DATA, 8'h5A);
    read_466(v);
    if ((v & 8'hC0) !== 8'h00) fail("0xA466 reports full (or empty) one byte short of 0x8000 (NP2kai: virbuf >= 0x8000)");
    write_port(P_DATA, 8'h5A);
    if (dbg_count !== 16'h8000) begin
      $display("FAIL: after 0x8000 writes the count is %04x", dbg_count);
      errors = errors + 1;
    end
    read_466(v);
    if ((v & 8'hC0) !== 8'h80) fail("0xA466 does not report full with the buffer at 0x8000");
    for (k = 0; k < 8; k = k + 1) write_port(P_DATA, 8'hA5);
    if (dbg_count !== 16'h8000) fail("a write at full left the count off the 0x8000 ceiling");

    // ---- 6. the 0xA468 bit-7 rising edge and the sample clock -------------
    // pcm86_oa468 restarts the sample clock on the 0->1 edge of bit 7
    // (`lastclock = cur << 6`), so on the reference the first sample after the
    // enable lands one full period later. Enabling mid-period therefore measures
    // a FULL period on NP2kai and the REST of the period here.
    write_port(P_FIFO, 8'h08);             // buffer reset
    write_port(P_FIFO, 8'h00);             // playback off
    write_port(P_DAC, 8'h60);              // 1-byte frames
    for (k = 0; k < 4; k = k + 1) write_port(P_DATA, 8'h30 + k[7:0]);
    // Wait for the phase bit's rising edge: that is the middle of a sample period.
    @(negedge clk); io_addr = P_VOLUME; io_rd = 1'b1;
    while (io_dout[0] !== 1'b0) @(posedge clk);
    while (io_dout[0] !== 1'b1) @(posedge clk);
    io_rd = 1'b0;
    @(negedge clk); io_addr = P_FIFO; io_din = 8'h80; io_wr = 1'b1;
    t0 = cyc;
    @(negedge clk); io_wr = 1'b0; io_din = 8'h00;
    n = 0;
    while ((dbg_count === 16'd4) && (n < PERIOD0 * 3)) begin @(posedge clk); n = n + 1; end
    delay = cyc - t0;
    if (dbg_count !== 16'd3) fail("playback never consumed the first sample after the enable");
    else begin
      $display("NOTE 0xA468 enable-to-first-sample delay: %0d clk of a %0d-clk period", delay, PERIOD0);
      if (delay <= PERIOD0 / 8) fail("the first sample was consumed within an eighth of a period of the enable");
      if (delay < (PERIOD0 * 3) / 4)
        diverge("0xA468 bit-7 rising edge does not restart the sample clock (delay in clk)", delay, PERIOD0);
    end

    // ---- 7. the four ports NP2kai answers with a dummy read ---------------
    // pcm86io_bind attaches pcm86_inpdummy to 0xA462, 0xA464, 0xA46C and 0xA46E
    // on the non-WaveStar path (cbus/pcm86io.c:342-346,430-490); it returns 0.
    // The primary reference's byte is ASSERTED.
    read_port(P_SPARE0, rb);
    if (rb !== 8'h00) fail("0xA462 is not NP2kai's pcm86_inpdummy 0x00");
    read_port(P_SPARE1, rb);
    if (rb !== 8'h00) fail("0xA464 is not NP2kai's pcm86_inpdummy 0x00");
    read_port(P_DATA, rb);
    if (rb !== 8'h00) fail("0xA46C is not NP2kai's pcm86_inpdummy 0x00");
    read_port(P_SPARE2, rb);
    if (rb !== 8'h00) fail("0xA46E is not NP2kai's pcm86_inpdummy 0x00");

    // ---- 8. S6: a full write FIFO back-pressures the writer; no byte is dropped ----
    // With the SDRAM port withheld (the model's stall), the depth-4 write FIFO
    // fills and the 0xA46C writer must be HELD (io_wr_wait -> the bus's S_IOWAIT
    // hold write_port models above) instead of the old silent drop. Twelve
    // pushes at the strobe cadence with the port withheld for the first 60 clks
    // must all land, byte-exact in the SDRAM store, once it is released.
    begin : s6
      integer j;
      // Playback off and the engine quiesced BEFORE the stall: a drain read
      // still in flight when the port is withheld would answer late and could
      // subtract a frame from the reset count.
      write_port(P_FIFO, 8'h00);
      repeat (64) @(negedge clk);
      sdram_stall = 1'b1;
      write_port(P_FIFO, 8'h08);             // buffer reset, playback off
      write_port(P_FIFO, 8'h00);
      write_port(P_DAC, 8'h60);              // 1-byte frames
      for (j = 0; j < 4; j = j + 1) write_port(P_DATA, 8'hC0 + j[7:0]);
      // The FIFO is full and the engine cannot drain it: the writer must be
      // held rather than handed a dropped byte.
      @(negedge clk); io_addr = P_DATA;
      #1;
      if (!io_wr_wait) fail("S6: a full write FIFO did not raise io_wr_wait (the byte would be dropped)");
      @(negedge clk); io_addr = 16'hFFFF;
      fork
        begin
          for (j = 4; j < 12; j = j + 1) write_port(P_DATA, 8'hC0 + j[7:0]);
        end
        begin
          repeat (60) @(negedge clk);   // ~5 held pushes into the burst
          sdram_stall = 1'b0;           // the engine drains from here
        end
      join
      repeat (400) @(negedge clk);      // let the engine flush the FIFO
      if (dbg_count !== 16'd12) begin
        $display("FAIL: S6: 12 held 0xA46C writes left the count at %0d", dbg_count);
        errors = errors + 1;
      end
      for (j = 0; j < 12; j = j + 1)
        if (u_sdram.mem[j] !== (8'hC0 + j[7:0]))
          fail($sformatf("S6: SDRAM byte %0d reads %02h, want %02h (a held write was lost or reordered)",
                        j, u_sdram.mem[j], 8'hC0 + j[7:0]));
    end

    // ==== VERDICT ====
    $display("NOTE TB_PC9821_PCM86_FIFO: %0d NP2kai divergence(s) named above", divergences);
    if (errors == 0) begin
      $display("TB_PC9821_PCM86_FIFO: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_FIFO: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: the full 0x8000 fill is the long part, tens of milliseconds.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_PCM86_FIFO: TIMEOUT");
  end
endmodule

// pcm86_sdram_model: the SDRAM third-port handshake and a 32 KiB byte store, for the
// PCM86 benches (one per bench, as the tree does for the SDRAM chip model).
module pcm86_sdram_model (
  input  wire        clk, reset,
  input  wire        stall,   // withhold ready/resp (S6's burst case)
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
      2'd0: if (valid && !stall) begin
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
              if (!stall) begin
                resp_valid <= 1'b1;
                st         <= 2'd0;
              end
            end
    endcase
  end
endmodule
