// OSD I/O TIMING = XE10 ON THE PEGC PACKED BANK: the CPU's packed 256-colour accesses (0xA8000 in
// the PEGC's packed mode) priced from the Xe10 class table, in front of the posted store buffer.
//
// The packed path is SDRAM-backed (pc9821_pegc_storebuf posts the stores and passes the reads to
// the backend), so it never went through pc9821_gvram_arb's table: on the core a packed word load
// cost about 225 ns and a store about 57 in BOTH I/O timing settings, against the machine's
// 600-790 and 135-183 (XE10X /RDLAT, docs/probes/XE10X-XE10-RDLAT1.TXT PKR/PKW rows, and
// XE10W /MISAL2, docs/probes/XE10W-XE10-MIS2RUN1.TXT). This stage sits between the memory map's
// backend arm and the store buffer and only GATES the handshake (valid to the buffer, ready back to
// the map); the buffer's acceptance FSM, its merging and its drain are untouched.
//
// THE TWO SHAPES, as for the GVRAM and the text RAM (XE10X /RDLAT sweeps 0..64 nops):
//   * a packed STORE is RATE-shaped on the machine (PKW hidden_frac 0.82-0.88 in every mode): a
//     packed store is accepted no sooner than the table's period after the previous one's accept;
//     the buffer still posts it (its ready is its accept), so the work between stores hides;
//   * a packed READ is LATENCY-shaped (PKR hidden_frac 0.03-0.08): the CPU's work after it adds.
//     The read is held here before it reaches the buffer, so its response lands the table's net
//     time after the CPU issued it. The response itself comes back on the map's shared response
//     path (the RAM's, too), which this stage does not touch; holding the request instead of the
//     answer is the same wait for the CPU, which is blocked on the read either way. The hold is
//     the table's time less the core's own unpaced packed read (XE10_PK_CPU_CYC below), so the
//     read costs the capture's time in all.
// The class is the direction, the raster phase (on a graphics line or not) and the display mode
// (24 kHz, 31 kHz, 31 kHz with the 256-colour display on, 24 kHz with it on - the table's 24P,
// whose packed cells are the 24 column's, measured with the display on). A packed access costs the same at any width (MIS2RUN1 PKD_0 dword store 135.1 = PKW_0 135.1,
// PKR_1 at offset 1 650.1 = PKR_0 647.7), so there is no width column; a word across a dword is two
// accesses here as on the machine (PKR_3 1.93-1.95 x PKR_0).
// THE 0xF00000 LINEAR APERTURE is priced the same: on the Xe10 it IS the packed bank 0 (a word
// stored at 0xA8000 reads at 0xF00000 and back) and costs what the packed bank costs, its loads
// LATENCY-shaped and its stores RATE-shaped (XE10Y /CELLS /APER with 0x043B as found; at 24 kHz
// with 256 colours a load 731.2 ns net and a store 144.6 ns, against the packed bank's 759.0 and
// 147.8 in the same kit's CELLS rows):
//   docs/probes/XE10Y-XE10-RUN3-APER2.TXT:40 `R CELLS PAR_2PA`
//   docs/probes/XE10Y-XE10-RUN3-APER2.TXT:32 `R CELLS PAW_2PA`
// so pc9821_memory_subsystem raises in_packed for it too (with [0xE0102] bit 0 set: closed, it
// is the open-bus responder's and never reaches this stage), and it takes the packed classes.
// NOT PRICED: every non-PEGC request (RAM, ROM): its valid and ready pass straight through, as
// does everything in Fast.
`default_nettype none

module pc9821_pegc_xe10_pace #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input  wire       clk,
    input  wire       reset,
    // OSD I/O timing = Xe10 (status[79]), the graphics GDC's fetch window (pc9821_gdc2's
    // gfx_grph_on) and the table's display-mode column (pc9821_memory_subsystem's xe10_mode):
    // levels, registered here.
    input  wire       timing_xe10,
    input  wire       gfx_scan_on,
    input  wire [1:0] xe10_mode,
    // The memory map's backend request (valid held until ready) and whether it is a PEGC packed
    // access: the packed arm (map_pegc_packed) or the open 0xF00000 aperture (peg_window).
    input  wire       in_valid,
    input  wire       in_write,
    input  wire       in_packed,
    output wire       in_ready,
    // To the store buffer: its in_valid and its in_ready.
    output wire       out_valid,
    input  wire       out_ready
);
  import pc9821_xe10_timing_pkg::*;

  // THE CORE'S OWN UNPACED PACKED READ, which the hold takes off the table's time: the Fast core
  // capture prices a packed word load at 192.3-203.5 ns net, 17.3-18.3 clk_sys at 90 MHz
  // (docs/probes/core/XE10X-CORE-h6-85942c3c-s3-FAST-RDLAT1.TXT:114-120 PKR_24O and the PKR rows
  // after it), the CPU's own cycles and the SDRAM round trip together. A measurement of THIS core
  // at the shipped clock, not a hardware fact; the SDRAM part of it is more cycles at a faster
  // profile clock (CL3 from 100 MHz), which this cycle count does not follow - a packed read at
  // 120 MHz runs a few ns over the table.
  localparam integer XE10_PK_CPU_CYC = 18;
  // Each entry is converted here by the table's rule (pc9821_xe10_timing_pkg): the nearest clk_sys.
  localparam [63:0]  PK_MAX  = (64'(SYS_CLOCK_HZ) * 64'(XE10_PK_MAX_NS_X10) + 64'd5_000_000_000) /
                               64'd10_000_000_000;
  localparam integer PK_BITS = ($clog2(PK_MAX + 1) < 1) ? 1 : $clog2(PK_MAX + 1);

  reg        timing_xe10_q, gfx_scan_q;
  reg  [1:0] mode_q;
  // The current row (0 = read, 1 = store), registered from the quasi-static levels: the load the
  // counter takes. A store's is its period less one (accept to accept is then exactly the period);
  // a read's is the table time less the core's own read and the arming cycle, floored at 0 (the
  // read is presented 1 + load cycles after it arrives).
  wire [2:0] pk_sel = {mode_q, 1'b0} + {2'b00, gfx_scan_q};   // 2 * mode + phase
  wire [2*PK_BITS-1:0] pk_ld;
  genvar pc;
  generate
    for (pc = 0; pc < 2; pc = pc + 1) begin : g_pk_row
      localparam integer BASE = XE10_PK_RD + XE10_PER_CLASS * pc;
      localparam integer SUBI = (pc == 0) ? (XE10_PK_CPU_CYC + 1) : 1;
      localparam [63:0]  SUB  = 64'(SUBI);
      wire [XE10_PER_CLASS*16-1:0] e;
      genvar pe;
      for (pe = 0; pe < XE10_PER_CLASS; pe = pe + 1) begin : g_e
        localparam [63:0] C = (64'(SYS_CLOCK_HZ) * {48'd0, XE10_NS_X10[16 * (BASE + pe) +: 16]} + 64'd5_000_000_000) / 64'd10_000_000_000;
        assign e[16 * pe +: 16] = 16'((C > SUB) ? (C - SUB) : 64'd0);
      end
      reg [PK_BITS-1:0] ld;
      always @(posedge clk) ld <= PK_BITS'(e[16 * pk_sel +: 16]);
      assign pk_ld[PK_BITS * pc +: PK_BITS] = ld;
    end
  endgenerate

  reg  [PK_BITS-1:0] st_left;   // a store's period: idle intervals before the next packed store
  reg  [PK_BITS-1:0] rd_left;   // a read's hold: cycles before it may go on
  reg                rd_armed;  // the presented read's hold has been loaded
  wire priced  = timing_xe10_q && in_packed;
  wire rd_pres = in_valid && !in_write && in_packed;
  // The gate: a priced store waits out the previous store's period, a priced read its own hold
  // (armed in the cycle it arrives, so it is never passed in that cycle).
  wire pass    = !priced || (in_write ? (st_left == {PK_BITS{1'b0}})
                                      : (rd_armed && (rd_left == {PK_BITS{1'b0}})));
  assign out_valid = in_valid && pass;
  assign in_ready  = out_ready && pass;
  wire accept      = in_valid && in_ready;

  always @(posedge clk) begin
    if (reset) begin
      timing_xe10_q <= 1'b0;
      gfx_scan_q    <= 1'b0;
      mode_q        <= 2'd0;
      st_left       <= {PK_BITS{1'b0}};
      rd_left       <= {PK_BITS{1'b0}};
      rd_armed      <= 1'b0;
    end else begin
      timing_xe10_q <= timing_xe10;
      gfx_scan_q    <= gfx_scan_on;
      mode_q        <= xe10_mode;
      // A packed store's accept loads its period; the counter runs down every cycle.
      if (accept && in_write && in_packed && timing_xe10_q) st_left <= pk_ld[PK_BITS +: PK_BITS];
      else if (st_left != {PK_BITS{1'b0}})                  st_left <= st_left - 1'b1;
      // A packed read arms its hold the cycle it is first presented; the accept clears the arming
      // (so a read presented right behind it arms its own), and a request that is not a packed
      // read drops it (nothing waits on an armed hold that is no longer presented).
      if (accept || !rd_pres)              rd_armed <= 1'b0;
      else if (!rd_armed && timing_xe10_q) rd_armed <= 1'b1;
      if (rd_pres && !rd_armed && !accept)    rd_left <= pk_ld[0 +: PK_BITS];
      else if (rd_left != {PK_BITS{1'b0}})    rd_left <= rd_left - 1'b1;
    end
  end
endmodule

`default_nettype wire
