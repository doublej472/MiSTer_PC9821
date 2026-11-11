// The debug UART's arbiter: N record-oriented sources onto the one byte stream.
//
// Every debug-UART record is `0xA5, type, ...` and its total length is a function of the type
// (dbg_rec_len below; tools/decode_dbglog.py carries the same table and
// tools/check_dbglog_contract.py holds the two together). The mux grants the stream to one
// source at a time, ROUND-ROBIN from the one after the last granted, and keeps the grant until
// that source's whole record has been accepted - so records from different instruments never
// interleave, however many are built. A source presents a byte (in_we) and holds it until its
// in_accept; sources are the instruments' ring drains, whose bytes of one record come out
// back-to-back in order (pc9821_dbg_ring).
//
// A byte that arrives while no record is in flight and is not 0xA5 is passed through as a
// one-byte record and takes no grant (a source that is not a debug instrument). An unknown type
// ends the record after the type byte; a source that emits a type missing from the table would
// therefore lose its grant early - the table is the contract, and the contract check holds it.
`default_nettype none
// Power-up values only (no reset reaches the debug path: it must keep logging across a guest reset).
/* verilator lint_off PROCASSINIT */
module pc9821_dbg_mux #(
    parameter integer N = 3
) (
    input  wire         clk,
    input  wire [8*N-1:0] in_byte,
    input  wire [N-1:0] in_we,
    output wire [N-1:0] in_accept,
    output wire [7:0]   out_byte,
    output wire         out_we,
    input  wire         out_accept
);
  // Total record length in bytes, by type. THE TABLE (keep equal to decode_dbglog.py's LEN):
  //   0x01-0x0B  the CD drive's command log (pc9821_atapi LOG_EN): 4 bytes of header + payload
  //   0x10-0x18  a display-port write (pc9821_gdc_log)      0x19 a text-attribute run
  //   0x1E       LOST display records                         0x1F ALIVE
  //   0x20/0x21  the CPU sampler (0x21: the previous sample was lost)
  //   0x30/0x31  a memory-snoop write / read beat             0x32 LOST snoop events
  //   0x43       one frozen-trace entry                       0x44 the trigger record
  //   0x50-0x56  a floppy-controller event (pc9821_fdc_log)   0x5E LOST, 0x5F ALIVE
  function automatic [5:0] dbg_rec_len(input [7:0] t);
    case (t)
      8'h01: dbg_rec_len = 6'd8;
      8'h02: dbg_rec_len = 6'd16;
      8'h03: dbg_rec_len = 6'd12;
      8'h04: dbg_rec_len = 6'd18;
      8'h05: dbg_rec_len = 6'd9;
      8'h06: dbg_rec_len = 6'd9;
      8'h07, 8'h08, 8'h09, 8'h0A: dbg_rec_len = 6'd5;
      8'h0B: dbg_rec_len = 6'd12;
      8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17, 8'h18: dbg_rec_len = 6'd7;
      8'h19: dbg_rec_len = 6'd9;
      8'h1E, 8'h1F: dbg_rec_len = 6'd7;
      8'h20, 8'h21: dbg_rec_len = 6'd34;
      8'h30, 8'h31: dbg_rec_len = 6'd15;
      8'h32: dbg_rec_len = 6'd8;
      8'h43: dbg_rec_len = 6'd15;
      8'h44: dbg_rec_len = 6'd13;
      8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56: dbg_rec_len = 6'd7;
      8'h5E, 8'h5F: dbg_rec_len = 6'd7;
      default: dbg_rec_len = 6'd2;
    endcase
  endfunction

  localparam integer SW = (N <= 1) ? 1 : $clog2(N);
  reg            locked = 1'b0;
  reg  [SW-1:0]  sel    = {SW{1'b0}};     // the granted source while locked
  reg  [SW-1:0]  last   = {SW{1'b0}};     // the last grant, for the rotation
  reg  [5:0]     left   = 6'd0;           // bytes of the record still to be accepted
  reg            typed  = 1'b0;           // the type byte has been accepted

  // the candidate source: the granted one, or the first requester after `last`
  reg            have;
  reg  [SW-1:0]  cur;
  /* verilator lint_off UNUSEDSIGNAL */   // ci is a loop index: only its low SW bits are a source
  integer        k, ci;
  /* verilator lint_on UNUSEDSIGNAL */
  always @* begin
    have = 1'b0;
    cur  = sel;
    ci   = 0;
    if (locked) begin
      cur  = sel;
      have = in_we[sel];
    end else begin
      for (k = 1; k <= N; k = k + 1) begin
        ci = (int'(last) + k) % N;
        if (!have && in_we[ci]) begin have = 1'b1; cur = SW'(ci); end
      end
    end
  end

  assign out_byte = in_byte[8*cur +: 8];
  assign out_we   = have;
  genvar g;
  generate for (g = 0; g < N; g = g + 1) begin : g_acc
    assign in_accept[g] = have && out_accept && (cur == g);
  end endgenerate

  always @(posedge clk) begin
    if (have && out_accept) begin
      if (!locked) begin
        if (out_byte == 8'hA5) begin locked <= 1'b1; sel <= cur; last <= cur; typed <= 1'b0; end
        else last <= cur;
      end else if (!typed) begin
        typed <= 1'b1;
        left  <= dbg_rec_len(out_byte) - 6'd2;
        if (dbg_rec_len(out_byte) <= 6'd2) locked <= 1'b0;
      end else begin
        left <= left - 6'd1;
        if (left == 6'd1) locked <= 1'b0;
      end
    end
  end
endmodule
/* verilator lint_on PROCASSINIT */
`default_nettype wire
