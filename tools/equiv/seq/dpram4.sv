// pc9821_dpram (src/pc9821/common/pc9821_dpram.sv) cut to four words with no initialiser, for
// tools/check_seq_equiv.py's recorded crtc proofs: the same model on both sides of a proof whose
// cut does not read the RAM, so its size is not part of the claim (yosys cannot map the 16K-word
// array with its initialiser into the SAT model).
`default_nettype none

// pc9821_dpram: inferred true dual-port RAM, independent port clocks.
// Portable to iverilog (unit tests) and Quartus (M10K inference).
//
// Port B has a read enable. This matters for the GDC scanout: its read port is
// clocked by clk_sys while the consumer runs on a fractional clk_vid_ce, so a
// free-running read would return the byte for the current dot when the enables
// have gaps and the previous dot's byte when they do not. Gating the read with
// the enable makes the data phase depend only on the dot that presented the
// address, which is what lets the fetch latches be written once.
// Port A: read/write. Port B: read/write. No cross-port write collision
// handling - callers must avoid simultaneous writes to the same address
// (the scanout port is read-only).
module pc9821_dpram #(
    parameter AW = 14,
    parameter DW = 8,
    // DEPTH 0 means the full 1<<AW array. A non-zero DEPTH declares a SHORTER array.
    // The font store needs this: the JIS subset is 51,200 words, and rounding that up to
    // 1<<16 would cost 22 extra M10K blocks the device does not have. The address port
    // stays AW wide; addresses at or above DEPTH are never presented by any caller.
    parameter integer DEPTH = 0,
    // Optional power-up contents, used for the battery-backed machine
    // configuration the hardware keeps inside text VRAM. A real machine has it
    // present before the guest runs, and firmware that validates it refuses to
    // boot without. INIT_LEN bytes are written contiguously from INIT_OFFSET.
    // TWO regions, because the battery-backed configuration runs in two disjoint
    // address runs (the software-DIP record at 0x810 and its port mirror at
    // 0x40..0x5B, both in the CG store); INIT2_* is the second run and is applied
    // after the first, so a hypothetical overlap resolves to INIT2.
    parameter         INIT_EN     = 1'b0,
    parameter [255:0] INIT_BYTES  = 256'h0,
    parameter integer INIT_LEN    = 32,
    parameter         INIT_OFFSET = 0,
    parameter         INIT2_EN     = 1'b0,
    parameter [255:0] INIT2_BYTES  = 256'h0,
    parameter integer INIT2_LEN    = 32,
    parameter         INIT2_OFFSET = 0
) (
    input  wire          clock_a,
    input  wire [AW-1:0] address_a,
    input  wire [DW-1:0] data_a,
    input  wire          wren_a,
    output reg  [DW-1:0] q_a,

    input  wire          clock_b,
    input  wire          en_b,
    input  wire [AW-1:0] address_b,
    input  wire [DW-1:0] data_b,
    input  wire          wren_b,
    output reg  [DW-1:0] q_b
);

  localparam integer RAM_DEPTH = (DEPTH == 0) ? (1 << AW) : DEPTH;
  // READ-DURING-WRITE, declared to the fitter: port B is read-only in every shipped instance
  // and port A's read is never sampled on the cycle it writes a caller's byte (the GDC's cg_ram
  // says so for its restore path; the trace and rhythm instances leave q_a unconnected), so a
  // cross-port read of an address written the same cycle is don't-care. Without a declaration
  // Quartus reports the dual-clock RDW as undefined with unspecified bypass (Warning 276027).
  // M10K, matching pc9821_iobus's msw_reg.
  (* ramstyle = "M10K, no_rw_check" *) reg [DW-1:0] ram[0:3];

  integer init_i;

  always @(posedge clock_a) begin
    if (wren_a) begin
      ram[address_a[1:0]] <= data_a;
      q_a <= data_a;
    end else begin
      q_a <= ram[address_a[1:0]];
    end
  end

  always @(posedge clock_b) begin
    if (wren_b) begin
      ram[address_b[1:0]] <= data_b;
      q_b <= data_b;
    end else if (en_b) begin
      q_b <= ram[address_b[1:0]];
    end
  end

endmodule

`default_nettype wire
