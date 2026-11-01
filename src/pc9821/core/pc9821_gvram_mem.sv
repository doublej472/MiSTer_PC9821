`default_nettype none

// pc9821_gvram_mem: the 256 KiB GVRAM as four byte-lane true-dual-port M10K arrays.
//
// Layout: a 32-bit word carries one byte per plane, {E,G,R,B}, and the word index is
// {page, plane_offset[14:0]} - exactly what the client port presents and the scanout's fetch
// forms, so no address arithmetic and no gvram_base. Port A is the CPU datapath (and through it
// the GRCG and the EGC, which are CLIENTS, never concurrent); port B the scanout's fetch, so three
// requesters need two physical ports and no double-pumped clock.
//
// FOUR BYTE LANES, NOT ONE 32-BIT WORD, and that is a synthesis decision, not a layout one. A raw
// `reg [31:0] mem [0:65535]` with PER-BYTE write enables AND a second read port does not
// synthesize: `quartus_map` on the array alone runs past 20 minutes at 24 GB of RSS and never
// finishes (whole-word writes, or byte enables with ONE port, finish in seconds). Four `reg [7:0]`
// arrays of 65536 carry the same data and byte enables - a lane is written only when enabled - and
// each is a plain whole-byte two-port M10K, so the split synthesizes in seconds. 4 x 65536 x 8
// bits = 2,097,152 = 256 KiB = 256 M10K blocks.
module pc9821_gvram_mem (
    input  wire        clk,

    // ---- Port A: the CPU/GRCG/EGC datapath ----
    input  wire [15:0] a_addr,
    input  wire [31:0] a_din,
    input  wire  [3:0] a_be,
    input  wire        a_we,
    input  wire        a_en,
    output reg  [31:0] a_dout,

    // ---- Port B: the scanout's line fetch, read-only ----
    input  wire [15:0] b_addr,
    input  wire        b_en,
    output wire [31:0] b_dout
);

  // One registered read per port and one whole-byte write per lane on port A. `no_rw_check` is
  // KEPT on purpose: it is what lets each lane stay ONE M10K. Dropping it makes synthesis
  // implement OLD_DATA on the mixed port by duplicating every lane (the array's 256 blocks become
  // 512, past the design's headroom), and the cross-port read-during-write it leaves undefined is
  // terminated by the forward below instead of being handed to the block's DONT_CARE mode.
  // Power-up is zero (M10K's own state), the same value the SDRAM model started at.
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem0 [0:65535];
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem1 [0:65535];
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem2 [0:65535];
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem3 [0:65535];

  // THE WRITE DECODE IS EXPLICIT PER LANE, NOT A NESTED (ce, we, byteena) TREE. The
  // nested `if (a_en) if (a_we) if (a_be[i])` let the inferred altsyncram wrapper decode
  // the three terms per block - a fit's worst family (ext_addr_r -> u_gmem's
  // porta_we_reg) spent `mem0~0` + `mem1_rtl_0|auto_generated|decode2` (two LUT levels,
  // the second fanning out over the array's blocks) between the arbiter's gma_we cone and
  // every block's portawe pin. Each lane's enable is exactly `a_en && a_we && a_be[i]`.
  // MEASURED CAVEAT: the explicit product did NOT remove
  // the wrapper's second level - the RAM inference re-splits the shared form below
  // (`{4{wr_any}} & a_be`) back into a (wren, byteena) pair, and the fit's tail is again
  // `wr_any~3` + `decode2` + portawe. The remaining increment inside this seam is to
  // build each lane's product so the inference takes it as the whole wren term (or keep
  // the wrapper's decode and shorten its hop). Every capture is bit-identical either way:
  // the write condition per lane is the same product, the read keeps its `a_en` gate, and
  // the port-B forward below reads the same pins on the same edges
  // (tb_pc9821_gvram_porta_equiv pins the port stream cycle-exactly).
  wire        wr_any  = a_en && a_we;
  wire  [3:0] lane_we = {4{wr_any}} & a_be;

  always @(posedge clk) begin
    if (lane_we[0]) mem0[a_addr] <= a_din[ 7: 0];
    if (lane_we[1]) mem1[a_addr] <= a_din[15: 8];
    if (lane_we[2]) mem2[a_addr] <= a_din[23:16];
    if (lane_we[3]) mem3[a_addr] <= a_din[31:24];
    // Registered read: a caller presents the address and samples a_dout one clk_sys later. On a
    // write this is the block's port-A read-during-write value, a don't-care, and NO caller
    // consumes it: the FSM issues a read with a_we low and captures the data in its next state.
    if (a_en) a_dout <= {mem3[a_addr], mem2[a_addr], mem1[a_addr], mem0[a_addr]};
  end

  // ---- Port B: the registered read, and the cross-port write-forward ----
  // Port A and port B are independent, so a port-B fetch CAN read the word a port-A store writes
  // in the SAME clk_sys - the CPU store and the scanout's line read share no arbiter - and
  // `no_rw_check` leaves that mixed-port read to the M10K's DONT_CARE mode. A word is FOUR
  // independent byte-lane blocks, so a full-word write racing a fetch could tear the dword (some
  // lanes old, some new). Terminate it here so the fetched word is deterministic whatever the
  // block does: `b_rd` is the block's own registered read, and when the read's address collided
  // with a store the byte this edge commits is forwarded on every lane the store ENABLES; every
  // lane it does not enable is not written, so `b_rd`'s byte is already the committed one. The
  // fetched word is then always a whole committed word, never a mix. The forward registers beside
  // the read (same clk_sys), so port B's latency is unchanged at one clk_sys.
  reg  [31:0] b_rd;
  reg         rdw_hit_q;
  reg  [31:0] rdw_din_q;
  reg   [3:0] rdw_be_q;

  wire rdw_hit = a_en && a_we && (a_addr == b_addr);

  always @(posedge clk) begin
    if (b_en) b_rd <= {mem3[b_addr], mem2[b_addr], mem1[b_addr], mem0[b_addr]};
  end

  always @(posedge clk) begin
    rdw_hit_q <= b_en && rdw_hit;
    rdw_din_q <= a_din;
    rdw_be_q  <= a_be;
  end

  assign b_dout = rdw_hit_q
                ? { rdw_be_q[3] ? rdw_din_q[31:24] : b_rd[31:24],
                    rdw_be_q[2] ? rdw_din_q[23:16] : b_rd[23:16],
                    rdw_be_q[1] ? rdw_din_q[15: 8] : b_rd[15: 8],
                    rdw_be_q[0] ? rdw_din_q[ 7: 0] : b_rd[ 7: 0] }
                : b_rd;

endmodule

`default_nettype wire
