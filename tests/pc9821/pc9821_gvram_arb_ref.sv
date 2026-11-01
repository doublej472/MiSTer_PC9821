// TEST REFERENCE: pc9821_gvram_arb as of 3b134fe4 (before an area-reduction pass), renamed. Never edited; tb_pc9821_gvram_arb_equiv proves the shipped module against it.
// PC-9821 GVRAM arbiter: one owner latch, one client mux, and the CPU's array datapath.
//
// This is the thin arbiter: its job is to pick which client owns the
// array's port A, to hold that choice for the life of the transaction, and to run the
// plain-path lane walk and the array-access FSM that drive port A. The array itself is
// pc9821_gvram_mem, instantiated beside this module by pc9821_memory_subsystem, and the
// GRCG and the EGC are instantiated there too and speak their D1 client ports in from here.
// The scanout line buffer is a separate sibling (pc9821_gvram_scan) that only reads port B.
//
// Client port: <c>_valid held until <c>_ready; <c>_addr is {page, plane_offset[14:0]}, a
// PLANE byte offset and never a physical address; data is {P3,P2,P1,P0}, a byte per plane;
// <c>_wbe is the ONLY thing that varies the write width. One access per cycle, so a
// multi-column access is the client's job. {page, offset[14:0]} indexes a dword carrying
// {E,G,R,B}, in the pixel fold's lane order (0 = blue at 0xA8000, 1 = red, 2 = green,
// 3 = intensity), so nothing permutes.
//
// THIS MODULE ALSO OWNS THE GVRAM'S PER-OPERATION COST (the acceptance period below): by
// design decision the machine's drawing pace is the specification for this device, and the
// constants are the Xe10 capture's own - see the GVRAM_PERIODS block.
`default_nettype none

module pc9821_gvram_arb_ref #(
    // The build's clk_sys frequency, the only input the time-derived periods below are
    // converted with (pc9821_memory_subsystem passes SYS_FREQ; a bench passes its own).
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input wire clk,
    input wire reset,

    // The CPU's access page (port 0xA6). Display uses the scanout's own latch.
    input wire        access_page,

    // ---- CPU plane-window route: the D1 client the CPU's own accesses use ----
    // `cpu_valid` is already gated by pc9821_memory_subsystem's route-owner mux,
    // so it means exactly "this CPU access is a GVRAM access".
    input  wire [1:0]   win_plane,
    /* verilator lint_off UNUSEDSIGNAL */  // only [14:2] is the plane-window word here; the low two
    input  wire [14:0]  win_offset,        // bits are the byte lane, which the plain path takes from cpu_be
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0]  cpu_din,
    input  wire [3:0]   cpu_be,
    input  wire         cpu_line_read,
    input  wire         cpu_valid,
    input  wire         cpu_write,
    output wire [31:0]  cpu_dout,
    output wire [127:0] cpu_line_dout,
    output wire         cpu_ready,
    output wire         cpu_resp_valid,
    output wire         cpu_line_resp_valid,

    // ---- The engine gates the dispatch reads (from pc9821_grcg and the EGC enable) ----
    input wire grcg_expand_gate,   // the GRCG's mode bit 7: it owns stores
    input wire grcg_tcr_gate,      // mode bit 7 set, bit 6 clear: it owns TCR reads
    input wire egc_gate,           // the EGC's real enable (0x6A num 2 AND 0x7C bit 7)

    // ---- GRCG client port (pc9821_grcg) ----
    input  wire        grcg_cl_valid,
    input  wire        grcg_cl_write,
    input  wire [15:0] grcg_cl_addr,
    input  wire [3:0]  grcg_cl_be,
    input  wire [31:0] grcg_cl_wdata,
    input  wire [3:0]  grcg_cl_wbe,
    input  wire        grcg_cl_cap,        // the GRCG's capture-cycle presentation is the live arm
    input  wire        grcg_cl_cap_rmw,    // raw arm taps (see pc9821_grcg): mode[6] /
    input  wire [3:0]  grcg_cl_hold_be,    // be_q / rmw_q / cl_datum0_r /
    input  wire        grcg_cl_hold_rmw,   // cl_mergeable_r, so the lane/we cone reads
    input  wire [3:0]  grcg_cl_hold_datum0,   // the arms' own operands and cl_cap alone
    input  wire [3:0]  grcg_cl_hold_mergeable, // lands on the final mux selects
    input  wire [31:0] grcg_cl_tile,
    input  wire        grcg_cl_rmw,
    input  wire        grcg_cl_burst,
    input  wire [63:0] grcg_cl_wdata2,
    output wire        grcg_cl_ready,
    input  wire [31:0] grcg_cpu_dout,
    input  wire        grcg_cpu_ready,
    input  wire        grcg_cpu_resp_valid,
    input  wire        grcg_dbg_busy,
    input  wire        grcg_dbg_rmw,
    input  wire        grcg_dbg_write,

    // ---- EGC client port (pc9821_egc) ----
    input  wire        egc_cl_valid,
    input  wire        egc_cl_write,
    input  wire [15:0] egc_cl_addr,
    input  wire [31:0] egc_cl_wdata,
    input  wire [3:0]  egc_cl_datum0,    // byte-zero flags of egc_cl_wdata, precomputed there
    input  wire [3:0]  egc_cl_wbe,
    input  wire        egc_cl_burst,
    input  wire [63:0] egc_cl_wdata2,
    output wire        egc_cl_ready,
    input  wire [31:0] egc_cpu_dout,
    input  wire        egc_cpu_ready,
    input  wire        egc_cpu_resp_valid,
    input  wire        egc_dbg_busy,

    // Which engine owns the current CPU transaction (the engines' cpu_valid gate).
    output wire        own_grcg,
    output wire        own_egc,

    // The data and completion the array answers back to whichever engine owns it.
    output wire [31:0] cl_rdata,
    output wire        grcg_cl_done,
    output wire        egc_cl_done,

    // ---- The array's port A (pc9821_gvram_mem) ----
    output reg  [15:0] gma_addr,
    output reg  [31:0] gma_din,
    output reg   [3:0] gma_be,
    output reg         gma_we,
    output reg         gma_en,
    input  wire [31:0] gma_dout,

    // ---- Graphics telemetry ----
    output wire [127:0] dbg_gfx_stats,
    output wire         dbg_walk_start,
    output wire         dbg_walk_cycle,
    // Visible-region telemetry, and the page-coincidence level.
    output wire         dbg_gr_owned,
    output wire         dbg_eg_owned,
    // ...and the PLAIN client's, which is the arm the other two leave out: a plane-window
    // store is neither the GRCG's nor the EGC's, so a page leak through it was invisible to
    // both the visible-region counters and the page-coincidence probe. See inc_pw below.
    output wire         dbg_pw_owned,
    output wire         dbg_access_page
);

  // ---------------------------------------------------------------------------
  // Client-port wires, one group per client. Exactly the D1 shape above.
  // ---------------------------------------------------------------------------
  // Client 0 -- the CPU chain. The GRCG, the EGC and the CPU's own plane access
  // all act on ONE CPU transaction, which does not complete until the GVRAM work
  // does, so there is no arbitration between them: the dispatch below selects the
  // one that owns the transaction and the others stay off the port.
  wire        cc_valid;
  wire        cc_ready;
  wire        cc_write;
  wire [15:0] cc_addr;
  wire [31:0] cc_wdata;
  wire [3:0]  cc_wbe;
  wire [31:0] cc_rdata;
  wire        cc_done;

  // Client 1 -- the scanout's line fetch is a sibling (pc9821_gvram_scan) that reads the
  // array's own port B, so it never appears on this module's port A.

  // The plain path's states (the client the CPU's own plane-window accesses use), declared HERE
  // because the dispatch's owner latch below reads `C_IDLE`.
  localparam [3:0] C_IDLE  = 4'd0,
                   C_VAL   = 4'd1,
                   C_WAIT  = 4'd2,
                   C_RESP  = 4'd3,
                   // The response strobe, one cycle after the accept. A READ needs it (the
                   // responder contract in pc9821_memory_subsystem.sv forbids asserting ready
                   // and the data strobe in the same cycle); a WRITE does not, so a write
                   // never enters here (see C_RESP).
                   C_RESP2 = 4'd4,
                   // The non-line access: ONE backend visit carrying the CPU's byte enables, so
                   // the four lanes are resolved without a client round trip between them
                   // C_IDLE presents the base word and enters here, so
                   // the accept cycle is the present cycle. The line read keeps the
                   // C_VAL/C_WAIT column walk.
                   C_MWAIT = 4'd5;

  // ---------------------------------------------------------------------------
  // Dispatch: which engine owns a CPU transaction
  // ---------------------------------------------------------------------------
  // EGC first, then GRCG, then the plain path -- NP2kai's order, and the reason the two
  // engines can coexist: with the EGC gate on, a store is the EGC's and the GRCG never sees
  // it, so an EGC backend write can never be re-expanded into a GRCG tile write
  // A GVRAM read is the GRCG's only when the tile-compare mode is
  // armed (0x80: mode bit 7 set, bit 6 clear); a 0xC0 (RMW) read is the plain path as
  // NP2kai's vacctbl has it. A 128-bit line fill is never the GRCG's.
  // `gstate`/`m_mode`/`cs` are declared here because the owner latch below reads them and the
  // module is `default_nettype none`: a name used above its declaration would become an
  // implicit 1-bit wire, and the latch must see the plain client's transaction in flight.
  reg  [2:0]  gstate;
  reg         m_mode;
  reg  [3:0]  cs;

  // ---- The IN-FLIGHT OWNER ----
  // The owner is LATCHED for the whole life of a client transaction and only re-evaluated when
  // no transaction is in flight. This is what lets a STORE be ACCEPTED (its ready pulsed) with
  // the array work completed BEHIND the CPU: after the accept the CPU presents its next access
  // at once, and that access's live cpu_write/be/enables must NOT move the dispatch off the
  // owner still draining the walk. Without the latch, a decoupled GRCG RMW store's own
  // `cpu_write` drop flipped `cc_owns_grcg` to 0 mid-walk and the walk's merge took the plain
  // arm (the same live-`cpu_write` class fixed on the done net and on C_MWAIT).
  // `any_inflight` is the union of the three clients' busy conditions plus the array FSM's own
  // walk; every term is a REGISTER, so the latch cannot move combinationally.
  wire        any_inflight = (gstate != G_IDLE) || m_mode || (cs != C_IDLE) ||
                             grcg_dbg_busy || egc_dbg_busy;
  wire        cc_owns_egc_comb  = egc_gate && !cpu_line_read;
  wire        cc_owns_grcg_comb = !cc_owns_egc_comb &&
                                  ((cpu_write && grcg_expand_gate) ||
                                   (!cpu_write && grcg_tcr_gate && !cpu_line_read));
  reg         own_egc_q, own_grcg_q;
  always @(posedge clk) begin
    if (reset) begin
      own_egc_q  <= 1'b0;
      own_grcg_q <= 1'b0;
    end else if (!any_inflight) begin
      own_egc_q  <= cc_owns_egc_comb;
      own_grcg_q <= cc_owns_grcg_comb;
    end
  end
  wire cc_owns_egc   = any_inflight ? own_egc_q  : cc_owns_egc_comb;
  wire cc_owns_grcg  = any_inflight ? own_grcg_q : cc_owns_grcg_comb;
  wire cc_owns_plain = !cc_owns_egc && !cc_owns_grcg;

  // The plain path's client handshake registers. Declared here, before the client mux below
  // reads them, so no name is used above its declaration under `default_nettype none`.
  reg         c_cl_valid;
  reg [15:0]  c_cl_addr;
  reg [31:0]  c_cl_wdata;
  reg [3:0]   c_cl_datum0;
  reg [3:0]   c_cl_wbe;

  assign cc_valid = cc_owns_plain ? c_cl_valid :
                    cc_owns_grcg  ? grcg_cl_valid : egc_cl_valid;
  assign cc_write = cc_owns_plain ? cpu_write :
                    cc_owns_grcg  ? grcg_cl_write : egc_cl_write;
  assign cc_addr  = cc_owns_plain ? c_cl_addr :
                    cc_owns_grcg  ? grcg_cl_addr : egc_cl_addr;
  assign cc_wdata = cc_owns_plain ? c_cl_wdata :
                    cc_owns_grcg  ? grcg_cl_wdata : egc_cl_wdata;
  assign cc_wbe   = cc_owns_plain ? c_cl_wbe :
                    cc_owns_grcg  ? grcg_cl_wbe : egc_cl_wbe;
  // The multi-word write exists on the EGC's and the GRCG's arms; the plain client presents
  // zero, and the backend reads it only when cc_burst is high.
  wire        cc_burst;
  wire [63:0] cc_wdata2;
  assign cc_burst  = (cc_owns_egc && egc_cl_burst) || (cc_owns_grcg && grcg_cl_burst);
  assign cc_wdata2 = cc_owns_grcg ? grcg_cl_wdata2 : egc_cl_wdata2;

  wire cc_plain_ready = cc_owns_plain && cc_ready;
  wire cc_grcg_ready  = cc_owns_grcg  && cc_ready;
  wire cc_egc_ready   = cc_owns_egc   && cc_ready;
  wire cc_plain_done  = cc_owns_plain && cc_done;
  wire cc_egc_done    = cc_owns_egc   && cc_done;
  // The engine client ports answer on the same accept and completion conditions.
  assign grcg_cl_ready = cc_grcg_ready;
  assign egc_cl_ready  = cc_egc_ready;
  assign grcg_cl_done  = cc_done;
  assign egc_cl_done   = cc_egc_done;
  // Which engine owns the CPU transaction the engines' cpu_valid is gated on.
  assign own_grcg      = cc_owns_grcg;
  assign own_egc       = cc_owns_egc;

  // The GRCG's completion is the ARRAY's `cc_done`, NOT the dispatch-gated one
  // `cc_owns_grcg` follows the LIVE `cpu_write`, which the CPU drops the cycle its ready is seen,
  // so an owner-gated done would vanish before the FSM could observe it and wedge the store.
  // The GRCG's request is the only one in flight while it waits, so the bare `cc_done` is its own.

  // ---------------------------------------------------------------------------
  // The plain path: the D1 client the CPU's own plane-window accesses use
  // ---------------------------------------------------------------------------
  // One D1 access per enabled byte, because D1 transfers one byte per plane per
  // access: a 32-bit CPU access is four, a 16-bit is two, a byte is one. A plane's
  // four bytes live in four different interleaved words, which is the layout's
  // stated price on this path.
  // z486 presents a dword-aligned address with the enables in cpu_be, so byte lane
  // k sits at plane offset {win_offset[14:2], k}.
  // A 128-bit line read is 16 consecutive bytes of ONE plane: 16 column reads,
  // taking that plane's lane from each. This route MUST assemble cpu_line_dout, or
  // z486's line fill reads nothing. Its states are declared above.

  reg [3:0]   c_be;
  reg [1:0]   c_plane;
  reg [31:0]  c_dout_r;
  reg [127:0] c_line_r;
  reg [4:0]   c_line_n;
  reg [14:0]  c_line_base;
  reg         c_line_mode;
  // Telemetry: the captured access was a store. Latched because the CPU may drop
  // cpu_write after the accept while the client is still walking; C_RESP's write/read split
  // also reads it, so the decode cannot flip mid-transaction either.
  reg         c_write_q;
  // The decoupled STORE's ready: a one-cycle REGISTERED level the cycle after the
  // access is accepted. Registered, not combinational on C_IDLE, so the ready is presented in a
  // whole clk_sys - the responder handshake z486 needs - rather than only in the accept cycle.
  reg         c_store_ready_q;

  wire [14:0] c_col  = c_line_base + {10'd0, c_line_n[3:0]};

  // The zero-datum flags of the CPU's store datum, latched beside c_cl_wdata so the plain
  // arm of lane_datum0 is a register like the engines' arms.
  wire  [3:0] cpu_din_datum0 = {(cpu_din[31:24] == 8'h00), (cpu_din[23:16] == 8'h00),
                                (cpu_din[15:8]  == 8'h00), (cpu_din[7:0]   == 8'h00)};
  // The capture arm's merge-eligible flags (byte != 0x00 && != 0xFF), the same precompute
  // on the live datum the zero flags are; the GRCG's cl_datum0/cl_mergeable muxes (and
  // their cap_tdw override select) are deliberately NOT in this cone.
  wire  [3:0] cpu_din_datmid = {(cpu_din[31:24] != 8'h00) && (cpu_din[31:24] != 8'hFF),
                                (cpu_din[23:16] != 8'h00) && (cpu_din[23:16] != 8'hFF),
                                (cpu_din[15:8]  != 8'h00) && (cpu_din[15:8]  != 8'hFF),
                                (cpu_din[7:0]   != 8'h00) && (cpu_din[7:0]   != 8'hFF)};

  // ---------------------------------------------------------------------------
  // GVRAM_PERIODS - the machine's per-operation drawing cost, as a TIME
  // ---------------------------------------------------------------------------
  // A DESIGN DECISION: for the GVRAM the standing
  // rule - "this hold is not a target to match; the machine's slow-VRAM figures are
  // slow-VRAM artifacts, not a specification" - is REVERSED. The machine's drawing pace IS
  // the specification for this device, so the GVRAM's per-access cost is modelled from the
  // Xe10's own capture. The constants are the CAPTURE's, never our RTL's, and the address
  // (a byte/word through a plane window) and the direction are the CPU's, which is the
  // shape gfxbenc2's loops issue.
  //
  // Every constant is a NANOSECOND time converted from SYS_CLOCK_HZ exactly as
  // pc9821_iobus's IO_WAIT_5F is, so one operation costs the same WALL CLOCK at 50, 80,
  // 100 and 120 MHz: the rate is the device's, not clk_sys's (AGENTS.md "Rates come from
  // the device, not from clk_sys counts"; tb_pc9821_sysclk_invariance proves it).
  //
  //   class        ns   capture source
  //   ----------  ----  ---------------------------------------------------------
  //   plain READ    478  docs/probes/GFX2.TXT (gfxbenc2 on the Xe10, decoded by
  //                      tools/hwprobe/gfxbenc2/gfxbenc2_decode.py, "NET OF CONTROL"):
  //                      the PW4RW row's 300.0 ns/access and the PLANE_COPY row's
  //                      320.4 ns/access are two independent measurements of ONE plane
  //                      word's read PLUS write (mean 310.2); the write half is the fill
  //                      below (142), so the read is 2*310.2 - 142 = 478.4. Cross-checks
  //                      in the same captures: GFXB.TXT's plain READ row (0.6135 us/word,
  //                      GVRAM0 READ=3184 KiB/s through the project's own KiB=1024 decoder
  //                      convention, gross of its rep lodsw loop) and GFX2's read half of PW4RW
  //                      (+1934 clk_sys/sprite over 64 reads = 604 ns/read gross of the
  //                      loop's OR).
  //   plain WRITE   142  docs/probes/GFXB.TXT GVRAM0(A8000) WRITE=13753 KB/s = 0.1420
  //                      us/word - the plain GRCG-off fill (a rep stosw stream), the
  //                      machine-portable 0.145 the plan cites. GFX2's PW1-PW4 write rows
  //                      agree to 15% once their shell control row (CTRLPW) is subtracted.
  //   GRCG store    104  GFX2 GRCG_RMW - CTRLGC = (4614 - 2952)/16 stores = 103.9 ns: the
  //                      GRCG's OWN read-merge-write, ONE CPU store, whatever the plane
  //                      mask. It is FAST - a CPU-driven 4-plane RMW is 8 plane accesses
  //                      (the PW4RW row) - so the two shapes are modelled at their own
  //                      measured costs and one is never applied to the other.
  //
  // WHERE THE COST SITS. The period is this device's ACCEPTANCE period on its one client
  // port: how long one CPU access occupies the GVRAM before the next can be taken. It is
  // charged per CPU ACCESS (the capture's unit - every gfxbenc2 loop issues one CPU word
  // access at a time), never per lane, and the class decode below is written so that one
  // period pays for one CPU access. The transaction's own walk is untouched - the same array
  // accesses over the same FSM - so every access COUNT the walk benches pin is unchanged;
  // only the time moves. A stream of one shape therefore costs max(period, walk) per access,
  // and the walk (1 clk per write lane, 2 per read lane) is far inside every period, so a
  // stream measures the captured cost itself.
  //
  // AN ISOLATED STORE'S READY IS STILL ITS OWN ACCEPT (the store decouple): what this
  // period bounds is the RATE the device takes accesses at, which is exactly what a
  // machine's posted write stalls on - the first store of a burst is not held, the burst's
  // sustained rate is the captured one.
  //
  // NOT MODELLED HERE (and why): the 0xA6 access-page switch (+1374 clk_sys/sprite in the
  // same capture) is an I/O-BUS cost, not a GVRAM plane access, and belongs to
  // pc9821_iobus's class floors (a separate decision). The EGC's own backend requests are the
  // ENGINE's produce steps: the
  // capture's EGC rows are gross-only with no matched control (the decoder's own note), so
  // no EGC-specific constant exists to charge them with and this seam does not invent one -
  // that engine's pace is its produce pipeline, a separate seam.
  localparam [15:0] GVRAM_RD_HOLD = 16'((SYS_CLOCK_HZ * 64'd478 + 64'd500_000_000) / 64'd1_000_000_000);
  localparam [15:0] GVRAM_WR_HOLD = 16'((SYS_CLOCK_HZ * 64'd142 + 64'd500_000_000) / 64'd1_000_000_000);
  localparam [15:0] GVRAM_GR_HOLD = 16'((SYS_CLOCK_HZ * 64'd104 + 64'd500_000_000) / 64'd1_000_000_000);

  // WHAT ONE PERIOD PAYS FOR is ONE CPU ACCESS, which is the capture's own unit and the reason
  // the class decode is not simply "every client request":
  //   * the plain client presents exactly one request per CPU access, so each of its requests a
  //     period makes;
  //   * the GRCG's store is ONE CPU store the capture priced (103.9 ns) even when the chip serves
  //     it with TWO client requests (the dword TDW/0xFF-datum two-pair burst), so a store's period
  //     is ARMED IN ITS CAPTURE CYCLE alone (`grcg_cl_cap`: the cycle the chip captures the CPU
  //     store and presents its first request in) and the second pair only WAITS out what remains -
  //     exactly one period per store. A GRCG READ has no capture cycle of its own (the TCR request
  //     leaves in G_TB), so it arms on its own request;
  //   * the EGC's requests are the ENGINE's own produce steps, not CPU accesses: the capture has
  //     no matched control for the EGC rows (the decoder's own note: they are gross-only), so no
  //     EGC-specific constant exists to charge them with, and this seam does not invent one. The
  //     EGC's pace is its own pipeline (a separate seam) and its requests neither arm nor
  //     wait on this period.
  // The transaction's class, read in its ACCEPT cycle. The plain client's direction is its own
  // latch there (c_write_q is the access it presents), the GRCG's is its registered cl_write (a
  // TCR read is a window READ, so it takes the read period).
  wire        acc_wr    = cc_owns_plain ? c_write_q : cc_write;
  wire [15:0] acc_hold  = (cc_owns_grcg && acc_wr) ? GVRAM_GR_HOLD :
                          acc_wr                    ? GVRAM_WR_HOLD : GVRAM_RD_HOLD;
  // A GRCG store's period is armed by the FIRST request it is accepted on - which is usually its
  // capture cycle, but is a LATER cycle whenever the device is still busy with the previous
  // access (the capture cycle's presentation is then not accepted, and `grcg_cl_cap` has fallen by
  // the time it is). `gr_arm_pend` carries that intent across the wait so a stream of stores is
  // still paced one period per CPU store.
  reg         gr_arm_pend;
  wire        acc_arm   = cc_owns_plain ? 1'b1 :
                          cc_owns_grcg  ? (cc_write ? (grcg_cl_cap || gr_arm_pend) : 1'b1) : 1'b0;
  // `hold_left` is WIDTH-SIZED TO WHAT IT CAN HOLD, not to the 16 bits the constant-only form
  // happened to have. It counts IDLE INTERVALS, so its range is 0..(the accepted access's period
  // - 1), and the periods are one nanosecond table scaled by SYS_CLOCK_HZ: the READ class (478 ns)
  // is the largest of the three by construction (against 142 and 104), so the largest load is
  // GVRAM_RD_HOLD - 24 at 50 MHz and 57 at 120 MHz. $clog2 of it bounds both (5 bits, then 6),
  // with a one-bit floor for a parameter set whose periods round to zero clk_sys.
  localparam integer HOLD_BITS = ($clog2(GVRAM_RD_HOLD) < 1) ? 1 : $clog2(GVRAM_RD_HOLD);
  // ... and that bound is the READ class only because the READ class is the widest of the three.
  // The three constants are one nanosecond table over one SYS_CLOCK_HZ, so the order is fixed by
  // the capture's own numbers - but it is fixed HERE by the constants, not by remembering them: a
  // profile or capture edit that reordered them would otherwise truncate the shortest-width
  // counter silently, which is the failure class this guard exists for.
  generate
    if ((GVRAM_WR_HOLD > GVRAM_RD_HOLD) || (GVRAM_GR_HOLD > GVRAM_RD_HOLD)) begin : gen_hold_width_check
      initial
        $error("pc9821_gvram_arb: a non-READ period is wider than GVRAM_RD_HOLD, which HOLD_BITS is $clog2 of: hold_left could not name the load");
    end
  endgenerate
  reg  [HOLD_BITS-1:0] hold_left;
  wire        hold_busy = (hold_left != {HOLD_BITS{1'b0}});

  // The one gate every accept path reads: the array FSM's dispatch, the walk's first lane and
  // `cc_ready` itself, so no arm of the dispatch can start on the accepting cycle. The EGC's
  // requests are exempt (see above), so they are taken at the engine's own rate.
  wire        accept_ok = (gstate == G_IDLE) && !m_mode && (cc_owns_egc || !hold_busy);

  // The counter holds IDLE INTERVALS, not the period itself: the accepted access's own cycle is
  // the first of the N, so N-1 intervals remain before the device will take another one - which
  // makes the accept-to-accept spacing exactly N clk_sys, i.e. exactly the capture's time (a
  // counter loaded with N would space them N+1, one clk_sys of over-price on every operation).
  always @(posedge clk) begin
    if (reset) begin
      hold_left   <= {HOLD_BITS{1'b0}};
      gr_arm_pend <= 1'b0;
    end else begin
      // the pending arming first, so the accept that consumes it cannot be overwritten by the
      // same cycle's capture pulse (a capture whose presentation IS accepted arms through the
      // combinational `grcg_cl_cap` term above, so the latch is only for the delayed accept)
      if (cc_ready && cc_owns_grcg) gr_arm_pend <= 1'b0;
      else if (grcg_cl_cap)         gr_arm_pend <= 1'b1;
      if (cc_ready && acc_arm)
        hold_left <= (acc_hold == 16'd0) ? {HOLD_BITS{1'b0}} : acc_hold[HOLD_BITS-1:0] - 1'b1;
      else if (hold_left != {HOLD_BITS{1'b0}}) hold_left <= hold_left - 1'b1;
    end
  end

`ifdef VERILATOR
  // (8) THE CAPTURE'S OWN ARMING LEAVES NO PEND (docs/single-cycle-event-discipline.md R2/R3/R8:
  //     a single-cycle event both consumed and produced in one cycle must STATE its rule and
  //     ASSERT it, not resolve the collision with a comment). `grcg_cl_cap` is one cycle wide and
  //     does two jobs in that cycle: it arms a GRCG store's period COMBINATIONALLY (acc_arm above)
  //     and it sets `gr_arm_pend` for a capture whose presentation is not accepted until later.
  //     When the capture's own presentation IS the accepted one, the accept must win and the pend
  //     must stay clear - the second pair of that same CPU store may only wait out the remainder
  //     of a period already charged, never re-arm one. The check is one cycle later, where the
  //     outcome is a register and can be seen.
  reg cap_taken_q;
  always @(posedge clk) begin
    if (reset) cap_taken_q <= 1'b0;
    else begin
      if (cap_taken_q && gr_arm_pend)
        $error("pc9821_gvram_arb: a capture accepted in its own cycle left gr_arm_pend set - the next request of that CPU store would re-arm a period already charged (R2/R3/R8)");
      cap_taken_q <= grcg_cl_cap && cc_ready;
    end
  end
`endif

  // The plain path's ONE-VISIT access: the backend sees the base word, the CPU's four byte
  // enables and the plane lane, and resolves every enabled lane itself. `cc_lane_many` is the
  // mux the backend keys on; the EGC and the line walk leave it low. The GRCG's store is the
  // same one-visit shape: its lanes are the CPU's byte enables and its merge is the
  // GRCG's own, so it presents cc_lane_many too -- EXCEPT when it marks the access a burst
  // (cl_burst), which the backend's own multi-column path must own.
  wire        c_many       = (cs == C_MWAIT);
  // The GRCG's store class comes from its OWN latched `cl_write`/`cl_be`, not the live `cpu_write`/
  // `cpu_be`: a decoupled store's ready is seen by z486 the cycle the walk starts, so the CPU's
  // request signals are already moving for the next access.
  wire        cc_lane_many = (cc_owns_plain && c_many && !c_line_mode) ||
                             (cc_owns_grcg && grcg_cl_write && !grcg_cl_burst);
  wire [3:0]  cc_lane_be   = cc_owns_grcg ? grcg_cl_be : c_be;
  wire [1:0]  cc_byte_lane = c_plane;

  always @(posedge clk) begin
    if (reset) begin
      cs          <= C_IDLE;
      c_be        <= 4'd0;
      c_plane     <= 2'd0;
      c_dout_r    <= 32'd0;
      c_line_r    <= 128'd0;
      c_line_n    <= 5'd0;
      c_line_base <= 15'd0;
      c_line_mode <= 1'b0;
      c_write_q   <= 1'b0;
      c_store_ready_q <= 1'b0;
      c_cl_valid  <= 1'b0;
      c_cl_addr   <= 16'd0;
      c_cl_wdata  <= 32'd0;
      c_cl_datum0 <= 4'b1111;
      c_cl_wbe    <= 4'hF;
    end else begin
      if (cc_plain_ready) c_cl_valid <= 1'b0;
      c_store_ready_q <= 1'b0;   // one-cycle pulse: set below on the accept, cleared here otherwise
      case (cs)
        C_IDLE: if (cpu_valid && cc_owns_plain) begin
          c_be        <= cpu_be;
          c_plane     <= win_plane;
          c_dout_r    <= 32'd0;
          // c_line_r IS NOT CLEARED HERE, and that is a CONTRACT, not an omission (-10 ALMs /
          // -15 ALUTs module-alone). The
          // 128-bit line datum is read ONLY through `cpu_line_dout`, and every reader of that
          // takes it under the STROBE `cpu_line_resp_valid` - pc9821_memory_subsystem's line mux
          // selects it on `gvram_cpu_line_resp_valid`, pc9821_system registers data and strobe
          // together, and z486's caches consume it only in the `mem_line_resp_valid` arm
          // (src/z486/l1_cache.sv:1131, src/z486/l1_icache.sv:731, `end else if (mem_line_resp_valid) begin`). AT THE STROBE EVERY LANE HOLDS
          // THIS ACCESS'S DATA: a line read walks C_VAL/C_WAIT writing lane
          // `{c_line_n[3:0], 3'b000}` for c_line_n = 0..15 - c_line_n is reset to 0 below, and
          // the only exit from C_WAIT is the 16th fill - so all 16 bytes have landed before
          // C_RESP/C_RESP2 can strobe. The RESET clear stays: it is what keeps the value defined
          // (never X) between power-up and the first line read.
          c_line_n    <= 5'd0;
          c_line_base <= {win_offset[14:4], 4'b0000};
          c_line_mode <= cpu_line_read;
          c_write_q   <= cpu_write;
          if (cpu_line_read) begin
            cs <= C_VAL;
          end else begin
            // Present the one-visit access in the accept cycle: the request's word is the
            // dword's base and the CPU's enables ride c_be, so the backend can start the
            // walk next cycle instead of after a separate presentation state.
            c_cl_valid <= 1'b1;
            c_cl_addr  <= {access_page, {win_offset[14:2], 2'b00}};
            c_cl_wdata <= cpu_din;
            c_cl_datum0 <= cpu_din_datum0;
            c_cl_wbe   <= 4'hF;
            // A STORE is ACCEPTED here and its ready pulses in the NEXT clk_sys; the
            // walk completes behind it. A READ's ready stays in C_RESP.
            if (cpu_write) c_store_ready_q <= 1'b1;
            cs         <= C_MWAIT;
          end
        end

        C_VAL: begin
          c_cl_valid <= 1'b1;
          c_cl_addr  <= {access_page, c_col};
          c_cl_wdata <= 32'd0;
          c_cl_datum0 <= 4'b1111;
          c_cl_wbe   <= 4'hF;
          cs         <= C_WAIT;
        end

        C_WAIT: if (cc_plain_done) begin
          c_line_r[{c_line_n[3:0], 3'b000} +: 8] <=
              cc_rdata[{c_plane, 3'b000} +: 8];
          if (c_line_n == 5'd15) begin
            c_line_n <= 5'd16;
            cs       <= C_RESP;
          end else begin
            c_line_n <= c_line_n + 5'd1;
            cs       <= C_VAL;
          end
        end

        // The non-line access: present the base word, the four byte enables and the plane
        // lane, and let the backend walk the enabled lanes in place. The client's
        // C_NEXT/C_VAL/C_WAIT round trip per lane costs roughly 40 of a coalesced
        // column's 54 clk_sys. The presentation happens in C_IDLE (see there),
        // so this state only waits for the walk to finish.
        C_MWAIT: if (cc_plain_done) begin
          // THE DIRECTION IS THE LATCH, NOT `cpu_write`. z486 completes a store ON THE ACCEPT and
          // drops `z_valid` (and this `cpu_write` with it) in the accept cycle, so reading the LIVE
          // input here took the READ arm's tail for a store: `cs <= C_RESP`, whose ready then
          // re-fired one clk_sys after the store had already completed and could complete the NEXT
          // access as if it were the GVRAM's (tb_pc9821_gvram_fill's second store vanished, its
          // ready having been taken from the store before it).
          if (!c_write_q) begin
            c_dout_r <= cc_rdata;
            cs       <= C_RESP;
          end else begin
            // A WRITE is done: `cpu_ready` pulses in THIS cycle (see its assign below) and the
            // store's last lane committed on the edge that set `cc_done`, so C_RESP would only
            // hold the CPU one clk_sys longer for a state whose whole job was a later pulse.
            cs <= C_IDLE;
          end
        end

        // The accept: cpu_ready pulses in this state and the CPU completes on it - for a READ,
        // whose response strobe follows in C_RESP2; a WRITE pulsed its ready in C_MWAIT instead.
        // A WRITE needs nothing else -- z486's memory.sv completes an external write on `ready`
        // (normal_req_complete's store term, and the store queue's drain) and consumes
        // `resp_valid` only for a READ (`direct_rd_resp_now` is gated `!ext_write_r`), and the
        // plane windows are uncacheable, so no read beat can follow a store. Asserting a strobe
        // for a write was never this client's contract: the GRCG and the iobus do not either.
        // A READ keeps C_RESP2, whose data the CPU latches on the strobe, and then goes straight
        // back to C_IDLE: ready, not the strobe, is what the next accept waits on, so no bubble
        // is needed to keep the strobe out of the next transaction's issue. The next accept must
        // NOT be gated on "cpu_valid || the presented transaction changed": z486 may present an
        // access IDENTICAL to the one just served - a `rep stosw` GVRAM fill writes the same
        // plane and offset with the same byte enables repeatedly - so such a test is false
        // forever, the ready never comes, and the guest stops mid-instruction.
        C_RESP:  if (c_write_q) cs <= C_IDLE; else cs <= C_RESP2;
        C_RESP2: cs <= C_IDLE;
        default: cs <= C_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // The CPU's D1 accesses: the ONE-VISIT walk over the M10K array
  // ---------------------------------------------------------------------------
  // The client presents the base word, its byte enables and the plane lane once; the dispatch
  // below resolves each enabled lane IN PLACE, without the client's C_NEXT/C_VAL/C_WAIT round trip
  // between them. A lane's word is base+k with one plane byte in lane k. With
  // the array in block RAM a lane's access is ONE clk_sys (a byte-enabled write) or two (a read and
  // its registered data), so a lane's access is ONE or two clk_sys. The array itself IS the
  // read-after-write view, so a partial store needs no read of the other planes.
  //
  // The PLAIN client holds c_cl_addr/c_cl_wdata/c_be/c_plane/cpu_write until cc_done, so cc_addr
  // and friends ARE the latched access for its whole walk. The POSTED EGC write does NOT
  // it advances on the ACCEPT and can move cc_addr under the walk, so the walk latches its base
  // word (m_base) at the presentation and adds m_lane to THAT.
  // The walk's own step/mode registers (declared here; `m_mode` itself is declared above, beside
  // the owner latch that reads it).
  reg        m_write;   // the walk's direction, latched at the presenting accept
  reg  [2:0] m_lane;
  reg [15:2] m_base;    // the walk's base word (low two bits are always 0), latched at the accept

  // ---------------------------------------------------------------------------
  // The array-access FSM's state
  // ---------------------------------------------------------------------------
  // One access is: issue it on port A, and (for a read) capture the registered data one clk_sys
  // later. A write completes in its issue cycle, a read in its capture cycle. The walk issues one
  // lane per clk_sys (writes) or per two (reads), and the EGC read burst issues one word per
  // clk_sys after its first.
  localparam [2:0] G_IDLE = 3'd0,  // dispatch; issues the first access of a transaction
                   G_RDC  = 3'd1,  // capture a single/walk read (and advance the walk)
                   G_RMWC = 3'd2,  // capture a GRCG RMW's old word and issue its merged write
                   G_W2B  = 3'd3,  // issue a two-word burst's second word
                   G_RBC  = 3'd4;  // capture an EGC read-burst word, pulse done, issue the next

  // `gstate` is declared above, beside the owner latch that reads it.
  reg [31:0] b_rdata;
  reg        b_done_r;
  reg [15:0] b_addr_q;    // the access address, latched at the issue (for the multi-cycle tails)
  reg [31:0] b_w2_hi_q;   // the two-word burst's HIGH word, latched at the issue (word 0 rides ef)
  reg [15:0] rb_word;     // the EGC read burst's current word
  reg  [2:0] rb_left_n;   // words still owed, including the one being captured

  // The walk owns the port until its last lane, so EVERY field it needs must be latched at the
  // presenting accept: the POSTED EGC write releases on `cc_ready` but the walk keeps
  // going with `cc_ready` low, so the client's `cc_write`/`cc_wbe` are free to move. `m_base` is
  // the same latch for the address; this is the direction. (The plain client holds its own signals
  // until `cc_done`, but latching is harmless there and keeps one rule.) The ACCEPT cycle is the
  // one cycle where no walk is in flight yet, so there the client's own `cc_write` is the
  // direction.
  // The walk's direction. INSIDE the walk it is the latched `m_write`. In the ACCEPT cycle it is
  // the client's own latched direction, NOT the live `cc_write`: a decoupled store's ready is seen
  // by z486 the cycle the walk starts, so its `cpu_write` is already dropping - the plain
  // client latched it into `c_write_q` at its C_IDLE accept, the GRCG's `cl_write` and the EGC's
  // `cl_write` are their own registers.
  wire        ef_wr   = m_mode ? m_write : (cc_owns_plain ? c_write_q : cc_write);

  // ---- The two LIVE inputs the walk must capture ----
  // The owner latch (above) holds cc_owns_* for the transaction's life, so the walk's
  // cc_wbe/cc_wdata and the owner's own registers stay put. Two inputs are STILL live when the
  // CPU is released at the accept, and both must be latched here:
  //   * `cc_lane_be` is `cpu_be` on the GRCG's arm, and z486 moves cpu_be for its NEXT access the
  //     cycle after the decoupled ready;
  //   * the GRCG's tile word is read LIVE from its register file, and the guest's `out 0x7E` can
  //     now run while the walk drains (it could not while the walk held the CPU).
  reg  [3:0]  m_lane_be;
  reg [31:0]  m_tile;
  wire [31:0] w_tile    = m_mode ? m_tile    : grcg_cl_tile;

  // ---- Which lanes the walk visits ----
  // A lane the CPU left clear has nothing to do, and neither has a GRCG RMW lane whose CPU datum
  // byte is 0x00: the merge's mask is the active-low plane enable broadcast per plane AND-ed with
  // that datum byte, so a zero datum leaves the merged word equal to the old one at EVERY plane -
  // no old value to read and nothing to write. Such a lane is DEAD and the walk steps over it, so a
  // store that changes nothing (a sprite erase's empty mask row, the audit's data-0x00 case) stops
  // paying a read and a write per lane. Every other enabled lane is live. The old read test asked
  // the whole 32-bit mask, so a single-plane put or a mixed 32-bit datum paid a read on every lane.
  // `lane_datum0` is PRECOMPUTED at the client data registers: each client exports the exact
  // byte-zero image of its own cl_wdata (c_cl_datum0 latched beside c_cl_wdata, the GRCG's
  // capture mux included), so this is a 4-bit owner mux instead of four byte comparators
  // over the 32-bit cc_wdata mux - the write-data mux and the comparators are OUTSIDE the
  // gma_we cone this feeds, and the value is bit-exact for the GRCG RMW zero-lane skip.
  wire [3:0]  lane_datum0_hold = cc_owns_plain ? c_cl_datum0 :
                                 cc_owns_grcg  ? grcg_cl_hold_datum0 : egc_cl_datum0;
  wire        lane_rmw_hold = ef_wr && cc_owns_grcg && grcg_cl_hold_rmw;
  wire        lane_rmw_cap  = ef_wr && cc_owns_grcg && grcg_cl_cap_rmw;
  // The lane enables per CASE, muxed on the RESULT (mux-late), formed from the RAW arm
  // taps (pc9821_grcg exports both sides of its presentation mux): the GRCG capture
  // cycle's arm takes the LIVE cpu_be with the live zero-skip (cpu_din_datum0, the same
  // flags cl_datum0 carries there), the hold arm the latched images. The capture select
  // (the GRCG's cl_cap = cap_store, which carries the device-alias decode) is then the
  // ONLY deep signal and lands on the final mux alone - the fitted paths ran
  // store_accept -> cc_lane_be -> lane_live and then flags -> cl_datum0/cl_mergeable muxes
  // -> tdw_burst -> lane_skip -> lane_live through the muxed ports' select chains before
  // this form.
  // BIT-EXACTNESS of the capture arm: cl_be is cpu_be and cl_datum0 is cpu_din_datum0
  // there except a TDW capture's 4'b0000 override - and a TDW capture with lane_rmw set is
  // exactly the 0xFF-datum burst, whose covered bytes are 0xFF (cpu_din_datum0 already 0)
  // and whose uncovered bytes are masked out by cpu_be = 0 below, so the two skip images
  // agree lane-for-lane.
  wire [3:0]  lane_skip_hold  = lane_rmw_hold ? lane_datum0_hold : 4'd0;
  wire [3:0]  lane_live_hold  = (m_mode ? m_lane_be :
                                (cc_owns_grcg ? grcg_cl_hold_be : c_be)) & ~lane_skip_hold;
  wire [3:0]  lane_live_cap   = cpu_be & ~(lane_rmw_cap ? cpu_din_datum0 : 4'd0);
  wire        cap_arm         = grcg_cl_cap && !m_mode;
`ifdef VERILATOR
  // (7) THE STEP-5 CAP-ARM INVARIANT (R8, docs/single-cycle-event-discipline.md), kept
  // beside the cross-module checks below: the GRCG's live capture presentation is only
  // read while the GRCG owns the transaction and no walk is in flight - `lane_live` and
  // `gr_merge` select the capture arm on exactly this condition, and the raw-tap
  // bit-exactness proof assumes it (the cl_cap && m_mode case would read the hold taps
  // where the old operand-muxed form read the capture's - unreachable, but asserted now,
  // not just proven on paper). It holds because cap_store is gated on the GRCG's own
  // cpu_valid (which includes cc_owns_grcg) and the GRCG captures only from its G_IDLE,
  // which the no-accept-mid-walk discipline (check (3)) keeps clear of the walk. The one
  // divergent class it protects (a TDW capture with lane_rmw set) is pinned end to end by
  // tb_pc9821_gvram_porta_equiv's cap_tdw+RMW pair-burst stimulus.
  always @(posedge clk) begin
    if (!reset && grcg_cl_cap && !(cc_owns_grcg && !m_mode))
      $error("pc9821_gvram_arb: cl_cap high while !(cc_owns_grcg && !m_mode) - the capture arm is only valid under its owner with no walk in flight (cap_arm invariant, step 5)");
  end
`endif
  wire [3:0]  lane_live       = cap_arm ? lane_live_cap : lane_live_hold;

  // cc_addr's low two bits are 0 (the client presents the base), so a lane's word is just the
  // base with the lane in those bits - wiring, not an adder. The lane's data is one byte,
  // replicated, so the write enables that one lane.
  //
  // `w_lane` is the lane THIS cycle's port-A access is for: the walk's latched lane, or - in the
  // ACCEPT cycle of a one-visit access - the walk's FIRST lane, which that cycle both accepts and
  // resolves. Issuing it there removes a dispatch bubble: the access below is a function of
  // `w_lane` alone
  // so no second presentation state is needed. `w_base` is the same choice for the address.
  wire [2:0]  w_lane = m_mode ? m_lane : w_first_lane;
  // The base word's LOW two bits are always 0 (every walk client presents the base word), so the
  // address takes them from w_lane and carries only the upper 14 here.
  wire [15:2] w_base = m_mode ? m_base : cc_addr[15:2];

  // The first live lane, and the next live lane strictly above `w_lane`: both descend so the walk
  // ascends.
  integer mi;
  reg [2:0] w_first_lane, w_next_lane;
  always @* begin
    w_first_lane = 3'd4;
    for (mi = 3; mi >= 0; mi = mi - 1)
      if (lane_live[mi]) w_first_lane = mi[2:0];
    w_next_lane = 3'd4;
    for (mi = 3; mi >= 0; mi = mi - 1)
      if (lane_live[mi] && (mi[2:0] > w_lane)) w_next_lane = mi[2:0];
  end

  // The walk resolves its first lane in its own accept cycle, so it is in flight from that cycle to
  // its last lane. `walk_first` IS that accept cycle (no live lane at all is a completed no-op with
  // no access, and is not a walk); `walk_act` is the union of the two, for the access below; and
  // `walk_gr` marks the GRCG's store arm of it.
  wire walk_first  = (gstate == G_IDLE) && accept_ok && !m_mode && cc_valid && cc_lane_many &&
                     (w_first_lane != 3'd4);
  wire walk_act    = m_mode || walk_first;
  wire walk_gr     = walk_act && cc_owns_grcg;

  wire [7:0]  ef_byte = cc_wdata[{w_lane[1:0], 3'b000} +: 8];
  wire [15:0] ef_addr = !walk_act ? cc_addr : {w_base, w_lane[1:0]};
  wire  [3:0] ef_wbe  = walk_gr ? cc_wbe :
                        !walk_act ? cc_wbe :
                        (4'h1 << cc_byte_lane);
  wire [31:0] ef_data = walk_gr ? w_tile :
                        !walk_act ? cc_wdata :
                        {4{ef_byte}};

  // ---- The GRCG's ONE-VISIT store ----
  // walk_gr marks the store walk: each enabled CPU byte lane is resolved with the GRCG's merge, not
  // the plain path's one-plane byte. `gr_mask` is the merge's 32-bit byte mask - the plane enable
  // ~mode[3:0] broadcast per plane, ANDed with the CPU data byte for RMW - so the merge computes
  // (old & ~mask) | (tile & mask): TDW gets tile where enabled, RMW gets (old & ~d) | (tile & d)
  // per PLANE BIT, which no 4-bit plane mask can express.
  wire [31:0] gr_emask  = { {8{cc_wbe[3]}}, {8{cc_wbe[2]}}, {8{cc_wbe[1]}}, {8{cc_wbe[0]}} };
  wire  [7:0] gr_d      = cc_wdata[{w_lane[1:0], 3'b000} +: 8];
  wire [31:0] gr_mask   = grcg_cl_rmw ? (gr_emask & {4{gr_d}}) : gr_emask;
  // A GRCG RMW lane whose datum byte is 0xFF needs no read: the merge is the tile whatever old was
  // (the read-skip), and a datum byte of 0x00 needs no access at all (the lane
  // is dead above). Any OTHER datum byte with a bit inside a plane DOES need the old word, because
  // a block RAM byte enable can only enable a WHOLE byte and the merge is per BIT.
  // The merge class per arm, the same raw-tap form (every consumer of gr_merge is already
  // under ef_wr, and walk_gr under cc_owns_grcg, so lane_rmw_*'s extra terms are masked).
  // Under a TDW capture the muxed flags were forced to 4'b0000, but gr_merge is unobserv-
  // able there: a cap_tdw request takes the burst_fits arm of G_IDLE, whose gma_we is the
  // constant 1 and whose state step never consults gr_merge - so the capture arm reads
  // cpu_din_datmid directly, bit-exact on every observed cycle.
  wire        gr_merge  = walk_gr &&
              (cap_arm ? (lane_rmw_cap  && cpu_din_datmid[w_lane[1:0]])
                       : (lane_rmw_hold && grcg_cl_hold_mergeable[w_lane[1:0]]));

  // ---- The EGC's read pass as ONE burst, now over the array ----
  // The unit's enabled columns are a contiguous run; the client asks for all of them at once and
  // receives one word per cl_done, in column order. The run's length is the access's own byte
  // enables (a 16-bit unit asks for two columns, not four).
  wire [1:0]  rb_c0     = ef_wbe[0] ? 2'd0 : ef_wbe[1] ? 2'd1 : ef_wbe[2] ? 2'd2 : 2'd3;
  wire [1:0]  rb_c1     = ef_wbe[3] ? 2'd3 : ef_wbe[2] ? 2'd2 : ef_wbe[1] ? 2'd1 : 2'd0;
  wire [2:0]  rd_cnt    = {1'b0, rb_c1} - {1'b0, rb_c0} + 3'd1;
  wire cc_rd_burst = cc_burst && !cc_write && !m_mode;

  // The two-word burst (the EGC's unit pair, the GRCG's TDW column pair) writes both of its words
  // as one request; with byte enables native to the array there is no dirty hold to fear, so a
  // full-word pair always fits. Both burst clients only emit FULL-WORD write bursts, and an
  // assertion below holds that no partial burst is issued.
  wire burst_fits = cc_burst && cc_write && !m_mode;
`ifdef VERILATOR
  // ---------------------------------------------------------------------------
  // CROSS-MODULE INVARIANTS AS ASSERTIONS. Each check pins a contract that
  // used to live in a comment only - an audit
  // found the dispatch/done routing holds together through these invariants and nothing
  // asserted them. They cost nothing in synthesis (`ifdef VERILATOR`) and run in every
  // bench that builds this module. R8 of docs/single-cycle-event-discipline.md: a
  // comment that documents a race names the assertion that pins it.
  // ---------------------------------------------------------------------------
  reg txn_live_q;   // $past(any_inflight || cc_ready) for check (1), assigned in block (5)
  always @(posedge clk) begin
    // The partial-burst guard, first: both burst clients only emit FULL-WORD write bursts.
    if (cc_burst && cc_write && !m_mode && (ef_wbe != 4'hF))
      $error("pc9821_gvram_arb: partial write burst (ef_wbe=%b) - the two-word path writes full words",
             ef_wbe);
    // (1) A DONE IS BORN OF A TRANSACTION (exact form): every `b_done_r`
    //     cycle follows a cycle in which a transaction was in flight OR being accepted
    //     (`cc_ready` covers the one-lane walk and the no-op, whose done issues in their own
    //     accept cycle). NB the stronger form states `b_done_r |-> any_inflight` at
    //     the done CYCLE - that form is false for the EGC's posted write: its S_HOLD tail
    //     exits one cycle before the burst's done lands (the done is deliberately UNOBSERVED,
    //     req_acc cleared at the presentation and S_WR_B_ACC advancing on the accept), so the
    //     owner latch may re-evaluate at that done cycle without mis-routing anything anyone
    //     waits for. The wedge class that remains is a MASKED done with a waiter, pinned by
    //     (2) below.
    if (!reset && b_done_r && !txn_live_q)
      $error("pc9821_gvram_arb: a done pulse with no transaction accepted or in flight the cycle before (check 1)");
    // (2) NO MASKED DONE WITH A WAITER (the no-re-present rule): `cc_done =
    //     b_done_r && !cc_ready` deletes a completion when a request is accepted in the done
    //     cycle, so while any client is in flight awaiting that completion the two must not
    //     coincide or the waiting FSM (G_STW/G_TDW/S_WR_ACC/S_RD_RESP/C_MWAIT/C_WAIT) hangs
    //     forever. The unobserved posted-write done (nobody in flight) is the one masked pulse
    //     the design allows.
    if (!reset && b_done_r && cc_ready && any_inflight)
      $error("pc9821_gvram_arb: a done masked by a same-cycle accept while a client is in flight - the waiting client wedges (check 2)");
    // (3) NO ACCEPT MID-WALK (the ordering premise): the posted EGC write
    //     advances on its ACCEPT and has no write buffer to forward from, so read-after-
    //     write ordering rests on the array accepting no client until the walk drains.
    //     Structural in cc_ready's expression today; pinned so it stays so.
    if (!reset && cc_ready && ((gstate != G_IDLE) || m_mode))
      $error("pc9821_gvram_arb: a client accepted mid-drain - the posted write's read-after-write ordering has no WCB to fall back on (check 3)");
    // (4) THE BURST'S MERGE-REDUCTION PRECONDITION: the two-word path
    //     writes cc_wdata2 raw and never consults gr_mask/gr_merge, so a GRCG RMW burst is
    //     legal only when the merge reduces to the tile - a 0xFF datum per presented word.
    //     The GRCG's pair test enforces exactly this today; if its burst classification
    //     ever loosens, this fires instead of planes being silently corrupted.
    if (!reset && cc_ready && cc_burst && cc_write && cc_owns_grcg && grcg_cl_rmw &&
        (grcg_cl_wdata != 32'hFFFF_FFFF))
      $error("pc9821_gvram_arb: GRCG RMW burst with datum %08x - the burst path drops the merge, so a burst needs a 0xFF datum (check 4)",
             grcg_cl_wdata);
  end

  // (5) THE DECOUPLED-STORE OWNER-LATCH CONTRACT, first half (checks 2 and 3): the
  //     in-flight owner latch must not follow the live cpu_write/gate drop mid-walk - a
  //     decoupled store's ready is seen by z486 the cycle the walk starts, so the CPU's
  //     request signals are already moving for the next access while this walk drains.
  reg  in_flight_d, own_egc_d, own_grcg_d;
  always @(posedge clk) begin
    if (reset) begin
      txn_live_q <= 1'b0;
      in_flight_d <= 1'b0;
      own_egc_d   <= 1'b0;
      own_grcg_d  <= 1'b0;
    end else begin
      txn_live_q <= any_inflight || cc_ready;
      if (any_inflight && in_flight_d &&
          ((cc_owns_egc != own_egc_d) || (cc_owns_grcg != own_grcg_d)))
        $error("pc9821_gvram_arb: the in-flight owner moved mid-transaction (egc %b->%b grcg %b->%b) - the owner latch must hold for the transaction's life",
               own_egc_d, cc_owns_egc, own_grcg_d, cc_owns_grcg);
      in_flight_d <= any_inflight;
      own_egc_d   <= cc_owns_egc;
      own_grcg_d  <= cc_owns_grcg;
    end
  end

  // (6) ... second half: the arb latches the tile word and the lane
  //     enables at the accept but reads the GRCG's `cl_rmw`/`cl_wbe`/`cl_wdata` LIVE into
  //     gr_mask/gr_emask/gr_d deep into the walk, so the GRCG must hold those from its
  //     capture until its own cl_done. It does (rmw_q/cl_wbe_r/cl_wdata_r held until the
  //     next capture, and no capture before G_STW's cl_done); if the GRCG ever posts like
  //     the EGC, this fires instead of G_RMWC silently corrupting the word.
  reg        gr_walk_d, grcg_cl_rmw_d;
  reg  [3:0] grcg_cl_wbe_d;
  reg [31:0] grcg_cl_wdata_d;
  always @(posedge clk) begin
    if (reset) begin
      gr_walk_d       <= 1'b0;
      grcg_cl_rmw_d   <= 1'b0;
      grcg_cl_wbe_d   <= 4'hF;
      grcg_cl_wdata_d <= 32'd0;
    end else begin
      if (walk_gr && gr_walk_d &&
          ((grcg_cl_rmw != grcg_cl_rmw_d) || (grcg_cl_wbe != grcg_cl_wbe_d) ||
           (grcg_cl_wdata != grcg_cl_wdata_d)))
        $error("pc9821_gvram_arb: the GRCG's cl_rmw/cl_wbe/cl_wdata moved mid-walk - it must hold them until its own cl_done (check 6)");
      gr_walk_d       <= walk_gr;
      grcg_cl_rmw_d   <= grcg_cl_rmw;
      grcg_cl_wbe_d   <= grcg_cl_wbe;
      grcg_cl_wdata_d <= grcg_cl_wdata;
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // The walk's pulses to the telemetry
  // ---------------------------------------------------------------------------
  // A walk starts only from the one-visit accept that resolves its own first lane. It is a
  // one-cycle pulse, so pc9821_perf_msg reads it as an
  // EVENT count and walk_act is high for every clk_sys of the walk: GC/GW is the mean walk in
  // clk_sys, per client access.
  assign dbg_walk_start = walk_first;
  assign dbg_walk_cycle = walk_act;

  // ---------------------------------------------------------------------------
  // The array-access FSM
  // ---------------------------------------------------------------------------
  // The state and its registers are declared above, beside the walk that reads `gstate` for its own
  // accept cycle. `g_walk` is the walk's access arm - it presents the lane `w_lane` names, in the
  // accept cycle as well as inside the walk - and g_single is everything else the G_IDLE state
  // dispatches: the one-word access, the client bursts, and the non-line column walk.
  wire g_walk   = (gstate == G_IDLE) && walk_act;
  wire g_single = (gstate == G_IDLE) && accept_ok && !m_mode && cc_valid && !cc_lane_many;

  // Port A's presented access. The G_IDLE arms are the dispatch; the other states are the
  // multi-cycle tails. `ef_*` is stable across a walk's whole run (the client holds it) and a
  // single access samples it in the accept cycle, so no per-access latch is needed except the
  // address and payload the tails name.
  always @* begin
    gma_en   = 1'b0;
    gma_we   = 1'b0;
    gma_addr = b_addr_q;
    gma_din  = 32'd0;
    gma_be   = 4'hF;
    case (gstate)
      G_IDLE: begin
        if (g_walk) begin
          gma_en   = 1'b1;
          gma_addr = ef_addr;
          gma_din  = ef_data;
          gma_be   = ef_wbe;
          gma_we   = ef_wr && !gr_merge;
        end else if (g_single) begin
          gma_en   = 1'b1;
          gma_addr = ef_addr;
          if (cc_rd_burst) begin
            gma_we = 1'b0;
          end else if (burst_fits) begin
            gma_din = cc_wdata2[31:0];
            gma_be  = 4'hF;
            gma_we  = 1'b1;
          end else if (!cc_burst) begin
            gma_din = ef_data;
            gma_be  = ef_wbe;
            gma_we  = ef_wr && !gr_merge;
          end
        end
      end
      G_RMWC: begin
        gma_en   = 1'b1;
        gma_we   = 1'b1;
        gma_addr = b_addr_q;
        gma_din  = (gma_dout & ~gr_mask) | (w_tile & gr_mask);
        gma_be   = 4'hF;
      end
      G_W2B: begin
        gma_en   = 1'b1;
        gma_we   = 1'b1;
        // The two-word burst's second word at the NEXT 15-bit offset of the
        // SAME page. The plain `+ 16'd1` carried into the page bit at
        // {page, 0x7FFF} and wrote the other page's offset 0, where every
        // GVRAM path in NP2kai wraps the offset at 15 bits (LOW15,
        // mem/memvram.c:42,114,136 and mem/memegc.c:1131,1327) and this
        // module's own column walk c_col already wraps the same way
        // (aliases.md A8).
        gma_addr = {b_addr_q[15], (b_addr_q[14:0] + 15'd1)};
        gma_din  = b_w2_hi_q;
        gma_be   = 4'hF;
      end
      G_RBC: if (rb_left_n != 3'd1) begin
        gma_en   = 1'b1;
        gma_we   = 1'b0;
        gma_addr = rb_word + 16'd1;
      end
      default: ;
    endcase
  end

  assign cc_rdata = b_rdata;
  assign cl_rdata = cc_rdata;  // `ready` is the accept: the dispatch cycle of a transaction. A walk owns the port from its OWN
  // accept cycle on - that cycle both accepts the client and resolves the walk's first lane
  // - so no client is accepted mid-walk, which is what keeps the posted EGC from losing
  // a unit it saw accepted. The GVRAM's own acceptance period (GVRAM_PERIODS) narrows this
  // further and never widens it: an accept needs the array idle AND the previous access's
  // period spent.
  // The accept: the client's request AND the device's own acceptance period (GVRAM_PERIODS).
  // `accept_ok` is the single gate - the FSM's dispatch, `walk_first` and `g_single` all read it
  // too, so a request the period holds off is not presented on port A either.
  assign cc_ready = cc_valid && accept_ok;
  // `cc_done` must not fire in the cycle `cc_ready` accepts a request: `b_done_r` belongs to the
  // owner that just completed, so a just-accepted client would capture that owner's stale rdata.
  assign cc_done  = b_done_r && !cc_ready;

  always @(posedge clk) begin
    if (reset) begin
      gstate    <= G_IDLE;
      b_rdata   <= 32'd0;
      b_done_r  <= 1'b0;
      b_addr_q  <= 16'd0;
      b_w2_hi_q <= 32'd0;
      rb_word   <= 16'd0;
      rb_left_n <= 3'd0;
      m_mode    <= 1'b0;
      m_write   <= 1'b0;
      m_lane    <= 3'd0;
      m_base    <= 14'd0;
      m_lane_be <= 4'd0;
      m_tile    <= 32'd0;
    end else begin
      b_done_r <= 1'b0;

      case (gstate)
        G_IDLE: begin
          if (cc_valid && accept_ok && cc_lane_many) begin
            // The plain/GRCG one-visit access: accept it (cc_ready pulses this cycle) and resolve
            // its FIRST lane in this same cycle - the access presented on port A now IS that
            // lane's (walk_first). No live lane at all is a completed no-op with no
            // access and no walk.
            b_rdata  <= 32'd0;
            b_addr_q <= ef_addr;
            if (w_first_lane == 3'd4) begin
              b_done_r <= 1'b1;
            end else begin
              m_mode  <= 1'b1;
              m_write <= ef_wr;
              m_base  <= cc_addr[15:2];
              // The two live walk inputs: the owner's lane enables and the GRCG's tile.
              m_lane_be <= cc_lane_be;
              m_tile    <= grcg_cl_tile;
              if (ef_wr && gr_merge) begin
                // The merge needs the old word: the read rides THIS cycle and G_RMWC completes it
                // from the registered data, then steps on. m_lane stays on the lane being merged
                // so that `gr_mask` and the G_RMWC step both name the right word.
                m_lane <= w_first_lane;
                gstate <= G_RMWC;
              end else if (ef_wr) begin
                // A store lane (the GRCG's tile, or the plain path's one-plane byte): the write
                // rode this cycle. Step to the next live lane, or end the walk.
                if (w_next_lane == 3'd4) begin m_mode <= 1'b0; b_done_r <= 1'b1; end
                else m_lane <= w_next_lane;
              end else begin
                // A read: the one issued this cycle is captured next cycle (G_RDC), which steps on.
                m_lane <= w_first_lane;
                gstate <= G_RDC;
              end
            end
          end
          else if (m_mode) begin
            b_addr_q <= ef_addr;
            if (ef_wr && gr_merge) gstate <= G_RMWC;
            else if (ef_wr) begin
              if (w_next_lane == 3'd4) begin m_mode <= 1'b0; b_done_r <= 1'b1; end
              else m_lane <= w_next_lane;
            end else gstate <= G_RDC;
          end
          else if (cc_valid && accept_ok) begin
            b_addr_q <= ef_addr;
            if (cc_rd_burst) begin
              rb_word   <= ef_addr;
              rb_left_n <= rd_cnt;
              gstate    <= G_RBC;
            end else if (burst_fits) begin
              b_w2_hi_q <= cc_wdata2[63:32];
              gstate <= G_W2B;
            end
            else if (ef_wr && gr_merge) gstate <= G_RMWC;
            else if (ef_wr) b_done_r <= 1'b1;
            else gstate <= G_RDC;
          end
        end

        // The plain or walk read's registered data, one clk_sys after the issue. A walk read takes
        // its lane's plane byte and advances; a plain read returns the whole word.
        G_RDC: begin
          if (m_mode) begin
            b_rdata[{m_lane[1:0], 3'b000} +: 8] <= gma_dout[{cc_byte_lane, 3'b000} +: 8];
            if (w_next_lane == 3'd4) begin m_mode <= 1'b0; b_done_r <= 1'b1; end
            else m_lane <= w_next_lane;
          end else begin
            b_rdata  <= gma_dout;
            b_done_r <= 1'b1;
          end
          gstate <= G_IDLE;
        end

        // The GRCG RMW's old word is in `gma_dout`; the merge is combinational on it, and the full
        // merged word is written back (the unmasked bytes are the old bytes, so writing them is a
        // no-op).
        G_RMWC: begin
          if (m_mode) begin
            if (w_next_lane == 3'd4) begin m_mode <= 1'b0; b_done_r <= 1'b1; end
            else m_lane <= w_next_lane;
          end else b_done_r <= 1'b1;
          gstate <= G_IDLE;
        end

        // The two-word burst's second word. `cc_done` fires once for the whole pair, which is the
        // EGC's and the GRCG's contract for a burst.
        G_W2B: begin
          b_done_r <= 1'b1;
          gstate   <= G_IDLE;
        end

        // The EGC read burst: capture the word issued last clk_sys, pulse one done for it, and
        // issue the next word in the same cycle.
        G_RBC: begin
          b_rdata  <= gma_dout;
          b_done_r <= 1'b1;
          if (rb_left_n == 3'd1) begin
            gstate <= G_IDLE;
          end else begin
            rb_word   <= rb_word + 16'd1;
            rb_left_n <= rb_left_n - 3'd1;
            gstate    <= G_RBC;
          end
        end

        default: gstate <= G_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // CPU-side handshake, selected by the same dispatch
  // ---------------------------------------------------------------------------
  // ACCEPT-AND-DECOUPLE. A plane-window STORE's ready pulses in the cycle its access is
  // ACCEPTED (C_IDLE, the cycle the plain client latches it and the walk resolves its first lane),
  // and the array work completes BEHIND the CPU. The ready is not gated on the walk: the walk's
  // cycles are the ONE thing the firmware does not time. Coherency is the STALL: a later CPU access
  // cannot be accepted off either client until this one has drained (the plain client holds
  // `cs != C_IDLE`, the engine holds its own FSM off G_IDLE/S_IDLE), so a CPU READ of a column
  // still in flight always sees the committed word - the bypass would only matter if the CPU could
  // run ahead, and z486 completes an external store ON its ready and re-presents the next access
  // into a still-busy client. A READ keeps C_RESP and then C_RESP2, which the responder contract
  // requires to be separate cycles (and it is not decoupled: its data is not ready until the walk
  // captures it).
  //
  // WHAT THE ACCEPTANCE PERIOD (GVRAM_PERIODS) ADDS, and what it does not change: a store's
  // ready is still its ACCEPT and its walk still drains behind the CPU, but the GVRAM takes the
  // next access only after the captured per-operation time, so a STREAM's sustained cost is the
  // machine's (see tb_pc9821_gvram_latency). A single store after an idle GVRAM is not held.
  assign cpu_ready           = cc_owns_plain ? ((cs == C_RESP) || c_store_ready_q) :
                               cc_owns_grcg  ? grcg_cpu_ready : egc_cpu_ready;
  assign cpu_resp_valid      = cc_owns_plain ? ((cs == C_RESP2) && !c_line_mode) :
                               cc_owns_grcg  ? grcg_cpu_resp_valid :
                                               egc_cpu_resp_valid;
  assign cpu_dout            = cc_owns_plain ? c_dout_r :
                               cc_owns_grcg  ? grcg_cpu_dout : egc_cpu_dout;
  assign cpu_line_resp_valid = cc_owns_plain && (cs == C_RESP2) && c_line_mode;
  assign cpu_line_dout       = c_line_r;

  // ---------------------------------------------------------------------------
  // Graphics telemetry counters. Free-running; read as DELTAS between records (2 s at
  // 50 MHz is 100e6 cycles, far inside a 32-bit counter, so nothing wraps and no reset is needed).
  //   GF_GR  cycles the GRCG owned an RMW store (the per-lane walk's whole cost: the CPU is held)
  //   GF_GT  cycles the GRCG owned a TDW store
  //   GF_EG  cycles the EGC owned the access
  //   GF_PW  cycles the plain client owned a plane-window WRITE
  // A TCR read is the GRCG's but is neither GR nor GT, and a plane READ is the plain client's but
  // not PW, so the four terms answer the sprite frame's split rather than the whole GVRAM time.
  // ---------------------------------------------------------------------------
  wire inc_gr = grcg_dbg_busy &&  grcg_dbg_write &&  grcg_dbg_rmw;
  wire inc_gt = grcg_dbg_busy &&  grcg_dbg_write && !grcg_dbg_rmw;
  wire inc_eg = egc_dbg_busy;
  wire inc_pw = (cs != C_IDLE) && !c_line_mode && c_write_q;
  // The two owners as bare per-cycle pulses, for pc9821_perf_msg's visible-region counters
  // Their sum is exactly the cycle set GF_GR + GF_GT above counts, and inc_eg is
  // GF_EG, so a capture can compare a visible-region figure against the whole-interval one.
  assign dbg_gr_owned = inc_gr || inc_gt;
  assign dbg_eg_owned = inc_eg;
  // The plain client's ownership, exported for the same reason as the two above: it is
  // the ONLY GVRAM write owner that is not the GRCG or the EGC, and Farland Story's page
  // copies are plain stores (its later heartbeats move GW/GC/PW while GS/GR/GT stay flat),
  // so a probe that watches only the GRCG cannot see the game's own store path.
  assign dbg_pw_owned = inc_pw;
  // The page-coincidence probe's CPU-side level. `access_page` is the port-0xA6
  // register; pc9821_gvram_scan carries the display page it latched for the line in flight.
  assign dbg_access_page = access_page;

  reg [31:0] gf_gr, gf_gt, gf_eg, gf_pw;
  always @(posedge clk) begin
    if (reset) begin
      gf_gr <= 32'd0; gf_gt <= 32'd0; gf_eg <= 32'd0; gf_pw <= 32'd0;
    end else begin
      if (inc_gr) gf_gr <= gf_gr + 32'd1;
      if (inc_gt) gf_gt <= gf_gt + 32'd1;
      if (inc_eg) gf_eg <= gf_eg + 32'd1;
      if (inc_pw) gf_pw <= gf_pw + 32'd1;
    end
  end
  assign dbg_gfx_stats = {gf_gr, gf_gt, gf_eg, gf_pw};

endmodule

`default_nettype wire
