`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The OPNA register-write queue's storage is one 64x11 M10K, not 704 flip-flops with 64 per-word write enables: 64 host writes fill the queue, the drain fires them back in order with their exact address/data/stretch payload, and the drain's cycle-by-cycle behaviour (its fire strobe, state, read and write pointers and count) is identical to the pre-M10K register-array implementation run as an oracle on the same stimulus, so the block RAM's registered output replaces the old drain register one-for-one and the DRAIN_GAP/SHORT_GAP pacing is unchanged. Both models carry the S1 fire-retry discipline (a fire meeting a host access holds and retries; the pop moves only when the fire completes), so what this bench proves is the STORAGE equivalence, edge for edge.
//
// ---- the oracle is the OLD queue, written out again ----
// A rewrite moved the wrq from three per-slot register arrays (wrq_addr 2 bits,
// wrq_data 8, wrq_str 1 = 704 flip-flops, one 11-bit write enable per slot) into one
// 64x11 M10K simple dual port: one write port, one registered read port. The read was
// already one clk deep, so the RAM's output register keeps the drain's latency
// identical. That is a latency claim, so this bench runs the OLD register-array
// queue+drain as a second reference on the SAME stimulus and requires the drain's
// every observable to match the DUT on every clk edge. A one-cycle read slip moves
// dr_fire, a lost address bit moves the fired payload, a changed write port drops or
// duplicates a word, and a changed gap constant moves the fire spacing - and every
// write-only test passes all of those. The oracle's FSM tracks the DUT's protocol
// (including the S1 retry); its STORAGE is the pre-M10K register arrays.
//
// The DUT is the real pc9821_opna, so the queue is exercised through its own host
// port: io_wr with op_addr = io_addr[2:1] is the write, and the drain's fire strobe
// and payload are the queue's own internal dr_* signals. The chip behind it never
// replies to a write, so nothing here depends on the vendored core's timing.
//
// The stimulus fills the queue to its full depth (64 writes back to back, so the
// drain cannot pop while io_wr is held and the queue really reaches 64), then releases
// the port and lets it drain. The writes alternate a register-select byte (0x188, a
// SHORT_GAP word) and a data byte (0x18A), and the select alternates an FM register
// (0xA4, so the data word stretches to DRAIN_GAP) with an SSG register (0x07, so it
// does not), so both gap constants are on the fire spacing. The bench asserts the
// queue reached 64, every one of the 64 fired in FIFO order with the payload written,
// and the DUT matched the oracle at every clk edge.

module tb_pc9821_wrq;

  // ==== DUT ====
  reg clk = 0;
  always #5 clk = ~clk;          // 10 ns
  reg reset = 1;

  // The real PC-9801-86 board glue. SYS_CLOCK_HZ sets the 7.9872 MHz chip enable the
  // drain gaps are counted in, exactly as a fit does at 50 MHz.
  reg  [15:0] io_addr = 16'h0188;
  reg         io_wr = 0;
  reg         io_rd = 0;
  reg  [7:0]  io_din = 8'h00;
  reg         extend = 0;
  reg  [5:0]  joystick = 6'b111111;
  reg         rhythm_we = 1'b0;
  reg  [11:0] rhythm_waddr = 12'd0;
  reg  [15:0] rhythm_wdata = 16'd0;
  wire [7:0]  io_dout;
  wire        io_rd_wait;
  wire signed [19:0] snd_l, snd_r;
  wire        irq;

  pc9821_opna #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk (clk), .reset (reset),
      .io_addr (io_addr), .io_wr (io_wr), .io_rd (io_rd), .io_din (io_din),
      .io_dout (io_dout), .io_rd_wait (io_rd_wait),
      .extend (extend),
      .joystick (joystick),
      .snd_l (snd_l), .snd_r (snd_r),
      .irq (irq),
      .rhythm_we (rhythm_we), .rhythm_waddr (rhythm_waddr),
      .rhythm_wdata (rhythm_wdata)
  );

  // ==== the OLD module as the oracle ====
  // The old queue: three per-slot register arrays and the drain FSM. It is
  // driven by the same host-port signals (and the DUT's own 7.9872 MHz chip enable and
  // stretch bit), and its registered read output is exposed so the bench can compare.
  wire [10:0] ref_dr_word;
  wire        ref_dr_fire;
  wire [1:0]  ref_dr_state;
  wire [5:0]  ref_wrq_rd, ref_wrq_wr;
  wire [6:0]  ref_wrq_cnt;

  wrq_ref oracle (
      .clk (clk), .reset (reset), .cen (dut.cen),
      .host_wr (io_wr), .host_rd (io_rd), .io_wr (io_wr),
      .op_addr (io_addr[2:1]), .io_din (io_din),
      .stretch (dut.wrq_stretch),
      .dr_word (ref_dr_word), .dr_fire (ref_dr_fire), .dr_state (ref_dr_state),
      .wrq_rd (ref_wrq_rd), .wrq_wr (ref_wrq_wr), .wrq_cnt (ref_wrq_cnt)
  );

  // ==== CHECKS ====

  integer errors = 0;
  integer i;

  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The words the DUT pushed, in order, recorded at each push edge. The drain must
  // return them in exactly this order with the same payload.
  reg [1:0] exp_addr [0:63];
  reg [7:0] exp_data [0:63];
  reg       exp_str  [0:63];
  integer   n_push = 0;
  integer   n_fire = 0;

  reg compare_en = 0;

  // Compare the DUT against the oracle on every clk edge. The FSM and the pointers
  // must match every clk (that is the latency check); the word the drain holds while
  // presenting must match; and each fired payload must be the oldest word pushed.
  always @(posedge clk) begin
    #1;
    if (compare_en) begin
      if (dut.dr_fire  !== ref_dr_fire)  fail("drain fire strobe differs from the oracle");
      if (dut.dr_state !== ref_dr_state) fail("drain state differs from the oracle");
      if (dut.wrq_rd   !== ref_wrq_rd)   fail("queue read pointer differs from the oracle");
      if (dut.wrq_wr   !== ref_wrq_wr)   fail("queue write pointer differs from the oracle");
      if (dut.wrq_cnt  !== ref_wrq_cnt)  fail("queue count differs from the oracle");
      // While presenting (state 1) the queue holds the addressed word; a wrong read
      // address or a one-cycle-late read shows here.
      if (dut.dr_state == 2'd1 && dut.dr_word !== ref_dr_word)
        fail("presented word differs from the oracle");
      // The fired payload must be the oldest word pushed, in FIFO order. dr_go
      // is the write LANDING (dr_fire and a host-free cycle): the S1 retry can
      // hold dr_fire over a host access without firing, and only landings count.
      if (dut.dr_go) begin
        if (n_fire >= 64) begin
          fail("a 65th word fired: the queue held more than it was given");
        end else if (dut.dr_data !== exp_data[n_fire] ||
                     dut.dr_addr !== exp_addr[n_fire] ||
                     dut.dr_str  !== exp_str[n_fire]) begin
          $display("FAIL fire %0d: dut addr/data/str=%b/%02x/%b want %b/%02x/%b",
                   n_fire, dut.dr_addr, dut.dr_data, dut.dr_str,
                   exp_addr[n_fire], exp_data[n_fire], exp_str[n_fire]);
          errors = errors + 1;
        end
        n_fire = n_fire + 1;
      end
    end
  end

  // ==== STIMULUS ====

  integer n;

  initial begin
    // ---- reset, then let the OPNA's reset stretcher finish ----
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (200) @(posedge clk);
    compare_en = 1;

    // ---- fill the queue to full depth: 64 host writes, no drain pop ----
    // io_wr is held high for exactly 64 clks, so wrq_cnt reaches its full 64 and
    // wrq_cnt[6] blocks any further push. Even writes are register selects (0x188,
    // op_addr 0 never stretches) and odd writes are data (0x18A); the select
    // alternates an FM register (stretch -> DRAIN_GAP) with an SSG one (SHORT_GAP).
    // Each write is recorded as it is driven, so the fired stream is compared against
    // what the host actually wrote; the stretch bit is read after the inputs settle.
    io_rd = 0;
    for (i = 0; i < 64; i = i + 1) begin
      @(negedge clk);
      if (i[0] == 1'b0) begin
        io_addr = 16'h0188;
        io_din  = ((i >> 1) & 1) ? 8'h07 : 8'hA4;
      end else begin
        io_addr = 16'h018A;
        io_din  = i[7:0];
      end
      io_wr = 1'b1;
      #1;
      exp_addr[n_push] = io_addr[2:1];
      exp_data[n_push] = io_din;
      exp_str[n_push]  = dut.wrq_stretch;
      n_push = n_push + 1;
    end

    // ---- the queue took every write and none overflowed ----
    // Sample before io_wr drops: the next edge would let the drain pop the first word.
    @(negedge clk);
    if (n_push !== 64) begin
      $display("FAIL the queue accepted %0d of 64 writes", n_push);
      errors = errors + 1;
    end
    if (dut.wrq_cnt !== 7'd64) begin
      $display("FAIL the full queue reads %0d entries, not 64", dut.wrq_cnt);
      errors = errors + 1;
    end
    io_wr = 1'b0;

    // ---- release the port and drain; every word must fire, in order ----
    n = 0;
    while (n_fire < 64 && n < 400_000) begin
      @(negedge clk);
      n = n + 1;
    end
    if (n_fire !== 64) begin
      $display("FAIL the queue drained %0d of 64 words", n_fire);
      errors = errors + 1;
    end else begin
      $display("  WRQ: 64 written, 64 drained in order in %0d clk", n);
    end
    @(posedge clk); #1;
    if (dut.wrq_cnt !== 7'd0) begin
      $display("FAIL the drained queue reads %0d entries, not 0", dut.wrq_cnt);
      errors = errors + 1;
    end
    compare_en = 0;

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_WRQ: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_WRQ: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_WRQ: TIMEOUT");
  end

endmodule

// The old register-write queue, verbatim but for its inputs being brought
// out: three per-slot register arrays, the FIFO pointers, and the drain FSM with the
// same DRAIN_GAP/SHORT_GAP pacing. Its registers are the ground truth the M10K's
// registered read output has to reproduce edge for edge.
module wrq_ref (
  input             clk,
  input             reset,
  input             cen,
  input             host_wr,
  input             host_rd,
  input             io_wr,
  input      [1:0]  op_addr,
  input      [7:0]  io_din,
  input             stretch,
  output     [10:0] dr_word,
  output            dr_fire,
  output     [1:0]  dr_state,
  output     [5:0]  wrq_rd,
  output     [5:0]  wrq_wr,
  output     [6:0]  wrq_cnt
);

  localparam integer WRQ_DEPTH = 64;
  localparam integer WRQ_BITS  = 6;
  localparam integer DRAIN_GAP = 216;
  localparam integer SHORT_GAP = 2;

  reg  [1:0]          wrq_addr [0:WRQ_DEPTH-1];
  reg  [7:0]          wrq_data [0:WRQ_DEPTH-1];
  reg                 wrq_str  [0:WRQ_DEPTH-1];
  reg  [WRQ_BITS-1:0] wrq_wr_r, wrq_rd_r;
  reg  [WRQ_BITS:0]   wrq_cnt_r;
  wire                wrq_empty = (wrq_cnt_r == 0);

  reg  [1:0]          d_state;
  reg  [7:0]          d_gap;
  reg  [1:0]          d_addr;
  reg  [7:0]          d_data;
  reg                 d_str;
  reg                 d_fire;

  wire                wrq_push = host_wr && !wrq_cnt_r[WRQ_BITS];
  // S1 discipline (mirrors the DUT): the write lands only on a host-free cycle,
  // and the pop moves only when the fire completes.
  wire                d_go     = d_fire && !host_rd && !io_wr;
  wire                wrq_pop  = d_go;

  assign dr_word  = {d_str, d_addr, d_data};
  assign dr_fire  = d_fire;
  assign dr_state = d_state;
  assign wrq_rd   = wrq_rd_r;
  assign wrq_wr   = wrq_wr_r;
  assign wrq_cnt  = wrq_cnt_r;

  always @(posedge clk) begin
    if (reset) begin
      wrq_wr_r <= {WRQ_BITS{1'b0}};
      wrq_rd_r <= {WRQ_BITS{1'b0}};
      wrq_cnt_r <= {(WRQ_BITS + 1){1'b0}};
      d_state <= 2'd0;
      d_gap   <= 8'd0;
      d_fire  <= 1'b0;
    end else begin
      if (wrq_push) begin
        wrq_addr[wrq_wr_r] <= op_addr;
        wrq_data[wrq_wr_r] <= io_din;
        wrq_str[wrq_wr_r]  <= stretch;
        wrq_wr_r <= wrq_wr_r + 1'b1;
      end
      case (d_state)
        2'd0: if (!wrq_empty && d_gap == 8'd0) begin
                d_addr  <= wrq_addr[wrq_rd_r];
                d_data  <= wrq_data[wrq_rd_r];
                d_str   <= wrq_str[wrq_rd_r];
                d_state <= 2'd1;
              end
        2'd1: if (!d_fire) begin
                if (!host_rd && !io_wr) d_fire <= 1'b1;
              end else if (d_go) begin
                d_fire  <= 1'b0;
                wrq_rd_r <= wrq_rd_r + 1'b1;
                d_gap   <= d_str ? DRAIN_GAP[7:0] : SHORT_GAP[7:0];
                d_state <= 2'd2;
              end
        2'd2: if (cen) begin
                if (d_gap == 8'd0) d_state <= 2'd0;
                else               d_gap <= d_gap - 8'd1;
              end
        default: d_state <= 2'd0;
      endcase
      wrq_cnt_r <= wrq_cnt_r + {WRQ_BITS{1'b0}} + wrq_push - {WRQ_BITS{1'b0}} - wrq_pop;
    end
  end

endmodule
