`timescale 1ns/1ps

// tb_pc9821_pcm86_overflow_align - an overfilled 86-PCM buffer stays frame-aligned.

// ==== WHAT THIS PROVES ====
// TB_PC9821_PCM86_OVERFLOW_ALIGN: overfilling the 86-PCM's 32 KiB buffer by a byte count that is not a whole frame keeps the drain FRAME-ALIGNED: the read pointer slips in NP2kai's 4-byte groups (cbus/pcm86io.c pcm86_oa46c: `g_pcm86.realbuf -= 4; g_pcm86.readpos = (g_pcm86.readpos + 4) & PCM86_BUFMSK;`), a multiple of every format's frame size, so after a 16-bit-stereo buffer is overfilled by 2 bytes every played frame still takes its left sample from a frame's first two bytes and its right sample from its last two - never the 1-byte slip that swaps channels and splits samples for the rest of the session.
//
// ---- where the expectation comes from ----
//   NP2kai cbus/pcm86io.c pcm86_oa46c: on `realbuf >= PCM86_REALBUFSIZE` it does
//     `g_pcm86.realbuf -= 4; g_pcm86.readpos = (g_pcm86.readpos + 4) & PCM86_BUFMSK;` (the
//     comment on its disabled twin says "align4"): the read side drops whole 4-byte groups.
//   NP2kai sound/pcm86g.c pcm86stereo16: a frame is PCM86GET16 left then PCM86GET16 right,
//     high byte first.
// FAIL-FIRST: before the fix the read pointer slipped ONE byte per overflow write, so after a
// 2-byte overfill the left output took the right sample of one frame (0x21xx) and the right
// output the left sample of the next.

module tb_pc9821_pcm86_overflow_align;

  // 50 MHz, matching the core's SYS_FREQ (tb_pc9821_pcm86_bufrst's harness).
  localparam integer CLK_HZ = 50_000_000;

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

  // The sample buffer's SDRAM side (src/pcm86/pc9821_pcm86_buf.sv): the third
  // port of the memory controller, which the bench stands in for.
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

  // ==== DUT ====
  pc9821_pcm86 #(.SYS_CLOCK_HZ(CLK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .dbg_count(dbg_count),
    .buf_base(32'd0),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  integer errors = 0;

  // ==== CHECKS ====
  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
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

  // Reads are answered from registers on the address alone (io_rd_wait is
  // tied low), so sampling io_dout after the address settles is the read.
  task automatic rd(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; io_rd = 1'b1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 1'b0;
    end
  endtask

  // ---- the IRQ wire monitor -----------------------------------------------
  // The wire is the interrupt the edge-latched PIC consumes (pc9821_pic.sv:168
  // ir_set = ir_in & ~ir_prev), so the bench counts RISING EDGES, falling
  // edges, and high cycles inside a stimulus-opened mask window. The
  // discipline that keeps both sides race-free: this monitor acts ONLY at
  // posedges, while the stimulus drives the ports, opens/closes mask_window
  // and reads these counters ONLY at negedges - every repeat(N)-then-assert
  // block below re-aligns to a negedge first.
  localparam [15:0] P_FIFO = 16'h0A468;
  localparam [15:0] P_DAC  = 16'h0A46A;
  localparam [15:0] P_DATA = 16'h0A46C;

  reg     irq_q = 1'b0;
  reg     mask_window = 1'b0;
  integer irq_rises = 0, irq_falls = 0, masked_high = 0;
  always @(posedge clk) begin
    if (irq && !irq_q) irq_rises = irq_rises + 1;
    if (!irq && irq_q) irq_falls = irq_falls + 1;
    // masked_high is PER WINDOW: zero while the window is shut (the stimulus
    // opens it at a negedge, after the masking write has settled), so it counts
    // only cycles the wire is high INSIDE the current window.
    if (!mask_window) masked_high = 0;
    else if (irq)     masked_high = masked_high + 1;
    irq_q <= irq;
  end


  integer n;
  integer f;

  // A 0xA46C byte the way pc9821_iobus delivers it: the access is HELD while the buffer's
  // write FIFO back-pressures (io_wr_wait), so no byte is lost to a full FIFO.
  task automatic wr_data(input [7:0] data);
    begin
      @(negedge clk);
      io_addr = P_DATA;
      while (io_wr_wait) @(negedge clk);
      io_din = data; io_wr = 1'b1;
      @(posedge clk);
      #1 io_wr = 1'b0;
      @(negedge clk);
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (50) @(posedge clk);

    wr(P_FIFO, 8'h00);                     // playback off, IRQ off, rate 0
    wr(P_DAC, 8'h32);                      // 16-bit stereo
    wr(16'h0A466, 8'hA0);                  // volume 15 (vol5 = ~0)
    // 8192 frames fill the 32 KiB buffer exactly, then 2 more bytes overfill it.
    for (f = 0; f < 8192 + 1; f = f + 1) begin
      wr_data(8'h11); wr_data(f[7:0]);          // left  = 0x11xx
      if (f < 8192) begin
        wr_data(8'h21); wr_data(f[7:0]);        // right = 0x21xx
      end
    end
    wr(P_FIFO, 8'h80);                     // play

    // ==== CHECKS ====
    for (n = 0; n < 6; n = n + 1) begin
      repeat (1200) @(posedge clk);
      if (snd_l[15:12] !== 4'h1 || snd_r[15:12] !== 4'h2) begin
        $display("frame %0d: L=%04x R=%04x", n, snd_l, snd_r);
        fail("OVERFLOW_ALIGN: a played frame is not frame-aligned after the overfill");
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PCM86_OVERFLOW_ALIGN: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_OVERFLOW_ALIGN: FAIL (%0d errors)", errors);
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_PCM86_OVERFLOW_ALIGN: TIMEOUT");
  end

endmodule

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
