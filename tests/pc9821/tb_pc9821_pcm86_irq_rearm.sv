`timescale 1ns/1ps

// tb_pc9821_pcm86_irq_rearm - an acknowledged-then-refilled 86-PCM interrupt fires again.

// ==== WHAT THIS PROVES ====
// TB_PC9821_PCM86_IRQ_REARM: an 86-PCM buffer-low interrupt that is acknowledged (0xA468 written with bit 4 clear) while the buffer is STILL at or below the 0xA46A threshold - so the flag re-latches, as NP2kai's pcm86_oa468 forces it - and then refilled, raises a NEW interrupt edge when the buffer drains back to the threshold: every armed threshold event is a fresh request, as NP2kai delivers it (sound/pcm86c.c pcm86_cb: `pcm86->irqflag = 1; ... pic_setirq(pcm86->irq);` once per write-armed reqirq), instead of the line staying high from the re-latch so the edge-triggered PIC never sees the next one and playback stalls; a first event from a low line still gives exactly one edge.
//
// ---- where the expectation comes from ----
//   NP2kai cbus/pcm86io.c pcm86_oa468: the clear `if ((!(val & 0x10))) g_pcm86.irqflag = 0;`
//     is followed by the Policenauts force `if (g_pcm86.virbuf <= g_pcm86.fifosize)
//     g_pcm86.irqflag = 1;` - an acknowledge at a low level leaves the flag set.
//   NP2kai sound/pcm86c.c pcm86_cb: each write-armed `reqirq` that finds
//     `virbuf <= fifosize` does `pcm86->irqflag = 1; ... pic_setirq(pcm86->irq);` - a new
//     PIC request per event, whatever irqflag already held.
//   pc9821_pic.sv: `ir_set = ir_in & ~ir_prev` - only a rising edge requests.
// FAIL-FIRST: before the fix the line stayed high from the re-latch through the refill and
// the next threshold crossing, so the second interrupt never reached the PIC (1 edge, not 2).

module tb_pc9821_pcm86_irq_rearm;

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
  integer r0;
  reg [7:0] rb;

  task automatic fill(input integer bytes);
    integer k;
    begin
      for (k = 0; k < bytes; k = k + 1) wr(P_DATA, k[7:0]);
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (50) @(posedge clk);

    wr(P_FIFO, 8'h20);                     // IRQ enable, playback off, rate 0 (44.1 kHz)
    wr(P_DAC, 8'h00);                      // threshold (0+1)<<7 = 128 bytes
    wr(P_FIFO, 8'h00);                     // back to the DAC meaning, IRQ off
    wr(P_DAC, 8'h32);                      // 16-bit stereo: 4 bytes per frame
    fill(200);                             // above the threshold, arms the IRQ
    r0 = irq_rises;
    wr(P_FIFO, 8'hA0);                     // play + IRQ enable, bit 4 clear
    // ==== CHECKS ====
    wait (irq === 1'b1);
    repeat (5) @(posedge clk);
    if (irq_rises - r0 != 1) fail("REARM_FIRST_EVENT: the first threshold crossing must give exactly one edge");

    // The ISR: acknowledge FIRST (the buffer is still at the threshold, so the flag
    // re-latches), then refill above the threshold.
    wr(P_FIFO, 8'hA0);
    rd(P_FIFO, rb);
    if (rb[4] !== 1'b1) fail("REARM_RELATCH: 0xA468 bit 4 did not re-latch at a low level (NP2kai force)");
    fill(200);
    if (dbg_count <= 16'd128) fail("REARM_SETUP: the refill did not lift the buffer over the threshold");

    // Drain back to the threshold: a second request must reach the PIC as an edge.
    wait (dbg_count <= 16'd128);
    repeat (20) @(posedge clk);
    if (irq_rises - r0 != 2) begin
      $display("edges seen: %0d", irq_rises - r0);
      fail("REARM_SECOND_EVENT: the refilled buffer's next threshold crossing gave no new interrupt edge");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PCM86_IRQ_REARM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_IRQ_REARM: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PCM86_IRQ_REARM: TIMEOUT");
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
