`timescale 1ns/1ps

// A TWO-REQUESTER guest-memory backend for the GVRAM benches: the same shape
// sdram_backend_model.sv reproduces from src/memory/sdram.v, but with the two requesters the GVRAM
// now has - the CPU's D1 accesses and the scanout's line fetch - against ONE store, so a
// write through the CPU port is visible to a scanout read of the same word.
//
// It arbitrates the two ports (a request already in flight owns the store) and reproduces the
// controller's timing: `ready` is a one-cycle pulse at the accept, a write is answered by the
// accept alone, and a read answers one `resp_valid` beat per word after ACCEPT_TO_RESP cycles.
// Storage is byte-enabled, so a one-plane store (be = a single lane) preserves the other lanes,
// which is what sdram.v's own read-modify-write does on a DQM-less module.
module sdram_2port_model #(
    parameter integer ACCEPT_TO_RESP = 2,
    parameter integer WRITE_BUSY     = 2,
    parameter integer WORDS_LOG2     = 16,
    parameter [31:0]  BASE           = 32'd0
) (
    input  wire        clk,
    input  wire        reset,

    // requester 0 (the CPU / mem_*)
    input  wire        valid0,
    output wire        ready0,
    input  wire        write0,
    input  wire [31:0] addr0,
    input  wire [31:0] din0,
    // The GVRAM's opt-in TWO-WORD write: word 1 of a burstcount0 == 2
    // write, at the NEXT dword. Ignored by every other requester and by reads.
    input  wire [31:0] din0_hi,
    input  wire  [3:0] be0,
    input  wire  [7:0] burstcount0,
    output reg  [31:0] dout0,
    output reg         resp_valid0,

    // requester 1 (the scanout / mem3_*): a READ BURST of up to 15 dwords, one
    // `resp_valid` beat per dword as sdram.v answers it.
    input  wire        valid1,
    output wire        ready1,
    input  wire        write1,
    input  wire [31:0] addr1,
    input  wire [31:0] din1,
    input  wire  [3:0] be1,
    input  wire  [7:0] burstcount1,
    output reg  [31:0] dout1,
    output reg         resp_valid1
);
  localparam integer WORDS = (1 << WORDS_LOG2);

  localparam [1:0] S_IDLE = 2'd0, S_BUSY = 2'd1, S_BEAT = 2'd2, S_DONE = 2'd3;

  reg [1:0]  state;
  reg [31:0] mem [0:WORDS-1];

  reg        r_ready0, r_ready1;
  reg        a_owner;          // which requester owns the transaction in flight
  reg        a_write;
  reg [31:0] a_delay;
  reg [7:0]  a_burst;          // beats this read owes
  reg [7:0]  a_n;              // beats emitted so far
  reg [31:0] a_rd_addr;        // walks a burst's beats

  assign ready0 = r_ready0;
  assign ready1 = r_ready1;

  wire accept = (state == S_IDLE) && !r_ready0 && !r_ready1 && (valid0 || valid1);
  wire grant1 = valid1 && !valid0;

  wire [31:0] off0 = addr0 - BASE;
  wire [31:0] off1 = addr1 - BASE;
  wire [WORDS_LOG2-1:0] widx0 = off0[WORDS_LOG2+1:2];
  wire [WORDS_LOG2-1:0] widx1 = off1[WORDS_LOG2+1:2];

  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0000_0000;
  end

  always @(posedge clk) begin
    if (reset) begin
      state       <= S_IDLE;
      r_ready0    <= 1'b0;
      r_ready1    <= 1'b0;
      a_owner     <= 1'b0;
      a_write     <= 1'b0;
      a_delay     <= 32'd0;
      a_burst     <= 8'd1;
      a_n         <= 8'd0;
      a_rd_addr   <= 32'd0;
      dout0       <= 32'd0;
      dout1       <= 32'd0;
      resp_valid0 <= 1'b0;
      resp_valid1 <= 1'b0;
    end else begin
      r_ready0 <= 1'b0;
      r_ready1 <= 1'b0;
      resp_valid0 <= 1'b0;
      resp_valid1 <= 1'b0;

      case (state)
        S_IDLE: if (accept) begin
          a_owner <= grant1;
          a_write <= grant1 ? write1 : write0;
          a_rd_addr <= grant1 ? addr1 : addr0;
          a_burst <= ((grant1 ? burstcount1 : burstcount0) == 8'd0) ? 8'd1
                                                                   : (grant1 ? burstcount1 : burstcount0);
          a_n     <= 8'd0;
          if (grant1) begin
            r_ready1 <= 1'b1;
            if (write1) begin
              if (be1[0]) mem[widx1][7:0]   <= din1[7:0];
              if (be1[1]) mem[widx1][15:8]  <= din1[15:8];
              if (be1[2]) mem[widx1][23:16] <= din1[23:16];
              if (be1[3]) mem[widx1][31:24] <= din1[31:24];
            end
          end else begin
            r_ready0 <= 1'b1;
            if (write0) begin
              if (be0[0]) mem[widx0][7:0]   <= din0[7:0];
              if (be0[1]) mem[widx0][15:8]  <= din0[15:8];
              if (be0[2]) mem[widx0][23:16] <= din0[23:16];
              if (be0[3]) mem[widx0][31:24] <= din0[31:24];
              // The pair's second column: word 1 rides din0_hi (the model's own widx0 is
              // addr0 >> 2, so +1 dword is widx0 + 1 wrapping inside the array).
              if ((burstcount0 == 8'd2) && ((widx0 + 1) < WORDS)) begin
                if (be0[0]) mem[widx0 + 1][7:0]   <= din0_hi[7:0];
                if (be0[1]) mem[widx0 + 1][15:8]  <= din0_hi[15:8];
                if (be0[2]) mem[widx0 + 1][23:16] <= din0_hi[23:16];
                if (be0[3]) mem[widx0 + 1][31:24] <= din0_hi[31:24];
              end
            end
          end
          a_delay <= a_write ? WRITE_BUSY : ACCEPT_TO_RESP;
          state   <= ((a_write ? WRITE_BUSY : ACCEPT_TO_RESP) == 0) ?
                     (a_write ? S_DONE : S_BEAT) : S_BUSY;
        end

        S_BUSY: if (a_delay == 32'd0) state <= a_write ? S_DONE : S_BEAT;
                else                 a_delay <= a_delay - 32'd1;

        // One `resp_valid` pulse per dword of the burst, `a_burst` of them -- the
        // shape sdram.v answers a read with, and the reason the scanout can fetch a
        // whole 15-column run per grant.
        S_BEAT: begin
          if (a_owner) begin
            dout1       <= mem[a_rd_addr[WORDS_LOG2+1:2]];
            resp_valid1 <= 1'b1;
          end else begin
            dout0       <= mem[a_rd_addr[WORDS_LOG2+1:2]];
            resp_valid0 <= 1'b1;
          end
          a_rd_addr <= a_rd_addr + 32'd4;
          if (a_n == (a_burst - 8'd1)) begin
            a_n   <= 8'd0;
            state <= S_DONE;
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

  function [31:0] peek(input [31:0] a);
    reg [31:0] off;
    begin
      off  = a - BASE;
      peek = mem[off[WORDS_LOG2+1:2]];
    end
  endfunction
endmodule
