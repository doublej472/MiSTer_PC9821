// A guest-memory backend that answers the way src/memory/sdram.v DOCUMENTS, for
// benches that need to see defects which only exist at real backend timing.
//
// Why this file exists
// --------------------
// Every integrated tier in this tree drives the backend from its testbench as an
// immediate stub: `tb_pc9821_userdisk.sv` raises `ext_mem0_resp_valid` the cycle
// AFTER the accept, and `tb_pc9821_memory_subsystem.sv` holds `mem_ready` at 1.
// The real controller is not like that. `src/memory/sdram.v:7` states its own
// read latency -- "T_RCD + CAS + 2*burst_cnt - 1 cycles from ACT to last data" --
// and it serves ONE request at a time, accepting only in IDLE
// (`sdram.v:1169`, `IDLE: if (~nce) begin`). So a responder defect that depends on the response
// arriving several cycles after the accept is INVISIBLE to every bench built on
// a stub, which is not the same thing as absent. This module is the stub's
// replacement: swap it in and the bench sees the timing the FPGA has.
//
// The shape it reproduces, all of it from sdram.v:
//
//   * `ready` is a ONE-CYCLE pulse at the ACCEPT (`sdram.v:1333` assigns
//     `ready_pulse_n[req_id] = 1'b1` when the request is latched), and it is
//     REGISTERED, so it appears the cycle after the request is taken.
//   * The controller is then BUSY and accepts nothing until the transaction
//     completes, so `ready` cannot pulse twice for one request even though the
//     host holds `valid` until it sees the pulse.
//   * A WRITE is answered by the accept alone -- sdram.v pulses `resp_valid`
//     only for reads -- and the host treats that accept as the write's
//     completion. Ordering is still safe because the next request is not
//     accepted until this one is done. Byte enables are honoured, because the
//     GVRAM route writes one byte lane per access. (`sdram.v` calls this the
//     read-modify-write shape a module without DQM needs.)
//   * A READ produces ONE `resp_valid` PULSE PER 32-BIT BEAT, `burstcount` of
//     them, not one response for the whole burst. A 128-bit line read is four
//     such beats.
//
// The delays are PARAMETERS so one bench can run the same stimulus fast and
// slow and compare. `ACCEPT_TO_RESP = 0` and `WRITE_BUSY = 0` is the immediate
// stub the other tiers use; `ACCEPT_TO_RESP = 5` is roughly what the authentic
// clk_sys sees for a single-word read.
//
// LINE_RESP is the one deliberate deviation, and it is a switch so a bench can
// put the model on either side of a real disagreement: 1 makes this model
// assemble the 128-bit line form; 0 makes it behave like the top level once did,
// which tied `ext_mem0_line_resp_valid` to 1'b0 and `ext_mem0_line_dout` to
// 128'd0. The built design has NO producer for that port at all; the integrated
// tiers supply one. A bench that wants to know which world it is testing
// chooses here.
//
// Storage is modelled so a read-back returns what was written, and `peek`
// exposes it directly so a bench can tell "the route never delivered" from "the
// route delivered the wrong bytes".
`timescale 1ns/1ps

module sdram_backend_model #(
    // Cycles from the accept to the first read response beat. 5 is close to a
    // single-word read at the authentic clk_sys; 0 is the immediate stub.
    parameter integer ACCEPT_TO_RESP = 5,
    // Cycles the controller stays busy after accepting a write.
    parameter integer WRITE_BUSY     = 3,
    // 1: assemble the 128-bit line form. 0: no line response, as the built
    // design has.
    parameter integer LINE_RESP      = 0,
    // Storage is 2**WORDS_LOG2 words.
    parameter integer WORDS_LOG2     = 16
) (
    input  wire        clk,
    input  wire        reset,

    // Request side, named as pc9821_memory_subsystem's mem_* port so a bench can
    // bind it with the same names it binds a hand-written stub to.
    input  wire        valid,
    output wire        ready,
    input  wire        write,
    input  wire [31:0] addr,
    input  wire [31:0] din,
    // The GVRAM's opt-in TWO-WORD write, which sdram.v models as
    // `burstcount == 2`: word 0 on `din`, word 1 on `din_hi`, both at consecutive dwords from
    // `addr`. This model stored only `din` and so lost the second word of every pair the GVRAM's
    // write-combining buffer issues; the bench that binds it supplies the DUT's own
    // `mem_din_hi` where it has one.
    input  wire [31:0] din_hi,
    // The G3 gather-RMW session (sdram.v's header): gath qualifies a write of
    // `burstcount` (1..8) same-row partial stores, entry 0 on addr/din/be and
    // entries 1.. on gath_extra ({addr[26:0], din[31:0], be[3:0]} per entry). The
    // model applies them all at the one accept, byte-enabled, exactly as the
    // controller's session ends up doing - so a bench built on this model sees
    // every entry of a grouped drain, not just its first.
    input  wire        gath,
    input  wire [440:0] gath_extra,
    input  wire [3:0]  be,
    input  wire [7:0]  burstcount,

    // Response side.
    output reg  [31:0]  dout,
    output reg          resp_valid,
    output reg  [127:0] line_dout,
    output reg          line_resp_valid,

    // High while a transaction is in flight, from the accept until it completes.
    output wire         busy,
    // Requests accepted and beats returned, so a bench can prove the traffic
    // actually reached the backend rather than dying in the route above it.
    output reg  [31:0]  accepts,
    output reg  [31:0]  beats
);
  localparam integer WORDS = (1 << WORDS_LOG2);

  localparam [1:0] S_IDLE = 2'd0,
                   S_BUSY = 2'd1,   // a write draining, or a read's first delay
                   S_BEAT = 2'd2,   // emitting read beats
                   S_DONE = 2'd3;

  reg [1:0]  state;
  reg [31:0] mem [0:WORDS-1];

  reg        r_ready;         // the registered one-cycle accept pulse
  reg        a_write;
  reg [7:0]  a_burst;         // beats this read owes
  reg [7:0]  a_n;             // beats emitted so far
  reg [31:0] a_delay;
  reg [31:0] a_rd_addr;       // walks the beats
  reg [127:0] a_line;

  assign ready = r_ready;
  assign busy  = (state != S_IDLE);

  // Requests are taken when the controller is idle and the host is asking, and
  // only when no accept pulse is already going out -- the host holds `valid`
  // until it sees that pulse, so without this the same request would be taken
  // twice.
  wire accept = valid && (state == S_IDLE) && !r_ready;

  wire [WORDS_LOG2-1:0] widx = addr[WORDS_LOG2+1:2];

  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0000_0000;
  end

  always @(posedge clk) begin
    if (reset) begin
      state           <= S_IDLE;
      r_ready         <= 1'b0;
      a_write         <= 1'b0;
      a_burst         <= 8'd1;
      a_n             <= 8'd0;
      a_delay         <= 32'd0;
      a_rd_addr       <= 32'd0;
      a_line          <= 128'd0;
      dout            <= 32'd0;
      resp_valid      <= 1'b0;
      line_dout       <= 128'd0;
      line_resp_valid <= 1'b0;
      accepts         <= 32'd0;
      beats           <= 32'd0;
    end else begin
      r_ready         <= 1'b0;   // a pulse, never a level
      resp_valid      <= 1'b0;
      line_resp_valid <= 1'b0;

      case (state)
        S_IDLE: if (accept) begin
          accepts   <= accepts + 32'd1;
          a_write   <= write;
          a_burst   <= (burstcount == 8'd0) ? 8'd1 : burstcount;
          a_n       <= 8'd0;
          a_rd_addr <= addr;
          a_line    <= 128'd0;
          r_ready   <= 1'b1;
          if (write) begin
            // Byte-enabled write. No response: sdram.v pulses resp_valid for
            // reads only, and the host takes the accept as the write's
            // completion, safe because the next request waits for IDLE.
            if (be[0]) mem[widx][7:0]   <= din[7:0];
            if (be[1]) mem[widx][15:8]  <= din[15:8];
            if (be[2]) mem[widx][23:16] <= din[23:16];
            if (be[3]) mem[widx][31:24] <= din[31:24];
            // The pair's second dword, at the next column (sdram.v's WRITE_BURST).
            // A gather is NOT a pair whatever its count says: its extra entries carry
            // their own addresses.
            if (gath) begin : gath_apply
              integer j;
              reg [62:0] gent;
              reg [WORDS_LOG2-1:0] gidx;
              for (j = 1; j < 8; j = j + 1) begin
                if (j < ((burstcount == 8'd0) ? 8'd1 : burstcount)) begin
                  gent = gath_extra[(j-1)*63 +: 63];   // {addr[26:0], din[31:0], be[3:0]}
                  gidx = gent[38 +: WORDS_LOG2];       // addr[WORDS_LOG2+1:2]
                  if (gent[0]) mem[gidx][7:0]   <= gent[11:4];
                  if (gent[1]) mem[gidx][15:8]  <= gent[19:12];
                  if (gent[2]) mem[gidx][23:16] <= gent[27:20];
                  if (gent[3]) mem[gidx][31:24] <= gent[35:28];
                end
              end
            end else if ((burstcount == 8'd2) && ((widx + 1) < WORDS)) begin
              if (be[0]) mem[widx + 1][7:0]   <= din_hi[7:0];
              if (be[1]) mem[widx + 1][15:8]  <= din_hi[15:8];
              if (be[2]) mem[widx + 1][23:16] <= din_hi[23:16];
              if (be[3]) mem[widx + 1][31:24] <= din_hi[31:24];
            end
            a_delay   <= WRITE_BUSY;
            state     <= (WRITE_BUSY == 0) ? S_DONE : S_BUSY;
          end else begin
            a_delay   <= ACCEPT_TO_RESP;
            state     <= (ACCEPT_TO_RESP == 0) ? S_BEAT : S_BUSY;
          end
        end

        S_BUSY: if (a_delay == 32'd0) begin
          state <= a_write ? S_DONE : S_BEAT;
        end else begin
          a_delay <= a_delay - 32'd1;
        end

        // One pulse per beat, `a_burst` of them. This is the shape a stub that
        // answers a whole burst in a single cycle gets wrong.
        S_BEAT: begin
          dout       <= mem[a_rd_addr[WORDS_LOG2+1:2]];
          resp_valid <= 1'b1;
          beats      <= beats + 32'd1;
          a_line     <= {mem[a_rd_addr[WORDS_LOG2+1:2]], a_line[127:32]};
          a_rd_addr  <= a_rd_addr + 32'd4;
          if (a_n == (a_burst - 8'd1)) begin
            line_dout       <= {mem[a_rd_addr[WORDS_LOG2+1:2]], a_line[127:32]};
            line_resp_valid <= (LINE_RESP != 0);
            a_n             <= 8'd0;
            state           <= S_DONE;
          end else begin
            a_n   <= a_n + 8'd1;
            state <= S_BEAT;
          end
        end

        S_DONE: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  // Read storage without a transaction, so a bench can tell "the route never
  // delivered" from "the route delivered the wrong bytes".
  function [31:0] peek(input [31:0] a);
    begin
      peek = mem[a[WORDS_LOG2+1:2]];
    end
  endfunction
endmodule
