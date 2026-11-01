// A byte ring between a debug instrument's serialiser and the debug UART's handshake.
//
// Every debug instrument (pc9821_dbg_cpu, pc9821_gdc_log; docs/mister-testing.md,
// "The debug UART") builds its records into a ring because the UART
// carries ~11,500 bytes/s and an instrument can produce a burst of many times that. The producer
// pushes at most one byte per cycle; `room` tells it whether a whole record of up to MAX_REC bytes
// still fits, and it STARTS a record only when it does - so a record is never cut in the middle
// by a full ring, which is what lets pc9821_dbg_mux switch sources on record boundaries. A
// producer that has no room counts the record as LOST and reports the count itself.
//
// THE POINTERS ARE ONE BIT WIDER THAN THE INDEX (wp/rp are AW+1 bits, the memory is addressed by
// the low AW): full and empty differ only in that top bit, and `used` is the full-width
// difference. The first pn-stall instrument had an 8 KiB ring whose drain index was 11 bits wide:
// the drain read the wrong half after the first wrap and every record after it was garbage, with
// nothing wrong at the producer. tb_pc9821_dbg_ring runs the ring through several wraps at
// more than one depth, with the UART stalled, and checks every byte comes out in order.
//
// The memory is written in one always block and read in another, and the read register `q` has
// no reset and no initial value: either of those refuses block-RAM inference (docs/fitting.md, the
// "silent inference traps").
`default_nettype none
/* verilator lint_off PROCASSINIT */
module pc9821_dbg_ring #(
    parameter integer AW = 11,        // log2 of the ring depth in bytes
    parameter integer MAX_REC = 40    // the longest record a producer pushes after seeing `room`
) (
    input  wire       clk,
    input  wire       push,
    input  wire [7:0] din,
    output wire       room,           // at least MAX_REC bytes free
    output wire [7:0] log_byte,
    output wire       log_we,
    input  wire       log_accept
);
  localparam integer DEPTH = 1 << AW;
  (* ramstyle = "M10K" *) reg [7:0] mem [0:DEPTH-1];
  reg [AW:0] wp = {(AW+1){1'b0}};
  reg [AW:0] rp = {(AW+1){1'b0}};
  wire [AW:0] used = wp - rp;
  localparam [AW:0] ROOM_MAX = (AW+1)'(DEPTH - MAX_REC);   // `used` up to this leaves MAX_REC free
  assign room = used <= ROOM_MAX;

  always @(posedge clk) if (push) begin
    mem[wp[AW-1:0]] <= din;
    wp <= wp + 1'b1;
  end

  // the drain: a registered read, presented until the UART FIFO takes it
  reg [7:0] q;
  reg       qv = 1'b0;
  always @(posedge clk) begin
    if (!qv && rp != wp) begin q <= mem[rp[AW-1:0]]; rp <= rp + 1'b1; qv <= 1'b1; end
    else if (qv && log_accept) qv <= 1'b0;
  end
  assign log_byte = q;
  assign log_we   = qv;
endmodule
/* verilator lint_on PROCASSINIT */
`default_nettype wire
