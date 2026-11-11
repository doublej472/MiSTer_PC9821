// SDRAM controller for Tang and MiSTer SDRAM modules -- nand2mario
//
// A 32-bit low-latency controller for 32/64/128MB MiSTer SDRAM modules; a 128MB module holds
// two complementary-CS 64MB chips. The timings below are derived from FREQ, up to 133 MHz.
//
// Latencies (CAS = 2 below 100 MHz, 3 at 100 MHz and up; CAS_I below):
// - Read latency is T_RCD + CAS + 2*burst_cnt - 1 cycles from ACT to last data.
// - Write: ACT at t0, the two half WRITEs at t=T_RCD and t=T_RCD+1 (auto-precharge on the second),
//   the next ACT tDAL after it (tDAL + 1 where EXIT_TRIM is off); `ready` pulses at the accept.
// - Read burst of at most 15 dwords; one crossing a row boundary is split AT it, one ACT each.
// - Write is a single 32-bit word with byte-enable support, EXCEPT PORT 0's TWO-word pair:
//   burst_cnt == 2 holds the row open for two columns, the second on din0_hi, and is split
//   the same way when its row cannot hold it whole. A write on any OTHER port
//   is one word whatever its count says (`ef_wr_burst`'s port term): only port 0 has an upper
//   payload word to write.
// - Refresh is done automatically at the next IDLE after the counter expires (refresh_allowed==1).
// - FOUR requesters are served ROUND-ROBIN, not by fixed priority (see the arbiter below).
//   The scheme that stood here starved the non-CPU requesters.
// - PORT 0's GATHER-RMW SESSION (G3): a write with `gath0` set carries up to
//   GATHER_K same-row partial stores (the PEGC posted store buffer's drain; entry 0 on
//   addr0/din0/be0, entries 1.. on gath0_extra), and is serviced as ONE session:
//   one ACT, one length-1 half READ per half any entry's be touches with SOME but not
//   ALL of its bytes, one DQ turnaround, one merged half WRITE per touched half
//   (auto-precharge on the last), one precharge exit. The row stays open across the
//   reads and the writes, so K byte stores cost one ACT and one precharge between them
//   instead of the single-RMW path's per-store re-ACT. Entries must share the physical
//   row of entry 0 (asserted below); only port 0 can gather.

module sdram
#(
    parameter         FREQ = 64_800_000,
    // The SDRAM_DQML/DQMH pins always carry a[12:11]: MiSTer SDRAM modules have no separate DQM
    // pins. 1: the byte mask rides A[12:11] (the MiSTer 128MB XSDS module wires the chips'
    // DQML/DQMH to A11/A12), so the byte mask is placed on a[12:11] during a WRITE and no
    // read-modify-write is needed. 0: a partial store is a read-modify-write. See
    // docs/sdram.md, "DQM wiring".
    parameter         ADQM = 1'b0,
    parameter         FAST_GRADE = 1'b1,  // 1: Alliance -6 speed grade, 0: -7 speed grade
    // G3 gather-RMW session: the most entries one session carries (1..GATHER_MAX). The
    // caller's request count (burst_cnt0 with gath0) must never exceed it; the upper
    // gath0_extra slots are then read by nothing and fold out of the netlist.
    parameter integer GATHER_K = 4,
    // The DQ read-capture cell (compile-time; build_profile.py's sdram_dq_ddio writes
    // z486_mister.sv's SDRAM_DQ_DDIO, which reaches here). 1: dq_r is the rising-edge half of an
    // explicitly instantiated IOE input DDIO cell (altddio_in). 0: dq_r is a plain register the
    // fitter packs into the same input cell (the qsf's FAST_INPUT_REGISTER). The two are the same
    // physical register and the same cycle; what differs is how Quartus 17.0.2 reaches it, and the
    // packed form crashes its physical synthesis on some netlists (`Internal Error: Sub-system:
    // DTM, File: /quartus/ddb/dtm/dtm_node.cpp, Line: 772` in visit_atom_stratixv_style_io_ibuf).
    parameter         DQ_IN_DDIO = 1'b0,
    // The output registers' cells (compile-time; build_profile.py's sdram_out_ddio writes
    // z486_mister.sv's SDRAM_OUT_DDIO, which reaches here). 1: every SDRAM output and DQ output-
    // enable register sits in its own pin's I/O cell without a fabric register being packed
    // and duplicated there: outputs are instantiated altddio_out cells, the DQ output enable one
    // dont_merge fabric register per pin (the output stage's note says why it is not in the cell)
    // loaded with the FSM's next value. 0: the FSM's fabric registers drive the pins and the qsf's
    // FAST_OUTPUT_REGISTER / FAST_OUTPUT_ENABLE_REGISTER pack them into the same cells. The same
    // register, the same clk edge; but the packed form crashes the physical synthesis of
    // Quartus 17.0.2 on some netlists (`Internal Error: Sub-system: DTM, File: /quartus/ddb/dtm/
    // dtm_node.cpp, Line: 772` in visit_atom_stratixv_style_io_obuf), the output twin of the
    // DQ_IN_DDIO crash.
    parameter         OUT_DDIO = 1'b0,
    // MEASUREMENT OVERRIDES for a test build (build_profile.py --dbg-sdram-cl2 /
    // --dbg-sdram-trcd-cycles; 0 in every preset, where they do nothing): DBG_CL forces the CAS
    // latency, DBG_TRCD_TRP the tRCD and tRP cycle counts (tDAL follows tRP), in place of the
    // values derived from FREQ below. They exist to separate a timing-table cause from an I/O
    // window cause at one clock (docs/sdram-margin.md, the 100 MHz CL2 test point).
    parameter integer DBG_CL = 0,
    parameter integer DBG_TRCD_TRP = 0
)
(
    // SDRAM side interface (16-bit data bus)
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output     [1:0]  SDRAM_DQM,
    output     [1:0]  SDRAM_BA,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nCS,
    output            SDRAM_CKE,    // always 1

    // Logic side interface (32-bit)
    input             clk,
    input             resetn,
    input             nce,            // for x2 wrapper, 1: do not accept new request or auto-refresh 
    input             refresh_allowed,      // set to 1 to allow auto-refresh
    output            busy,
    input       [1:0] sdram_size,    // 1/2/3 = 32/64/128MB; 0 uses 32MB geometry

    // 4 requesters, round-robin (valid/ready handshake; a request is held until ready)
    input             valid0,       // request valid (held until ready)
    output            ready0,       // 1-cycle pulse: request accepted
    input             wr0,          // 1: write (single dword), 0: read
    input      [26:0] addr0,        // byte address (bits [1:0] ignored)
    input      [31:0] din0,         // 32-bit write data
    // A CONTROLLER feature kept for tb_pc9821_sdram_wburst; the core's one caller is
    // pc9821_pegc_storebuf's pair drain (split_sdram_backend's mem0_din_hi).
    input      [31:0] din0_hi,      // port 0's two-word write: word 1 of the burst
    // PORT 0's GATHER-RMW SESSION request (the header): gath0 qualifies the request as a
    // gather of `burst_cnt0` (1..GATHER_K) same-row partial stores; entry 0 rides
    // addr0/din0/be0 and entry j (1..) is gath0_extra[(j-1)*GENT_W +: GENT_W] =
    // {addr[26:0], din[31:0], be[3:0]}. The extra entries' row bits are assertion-only
    // (the session serves every entry's own COLUMN against entry 0's row), so at
    // GATHER_K < 8 the unused upper slots are pruned whole.
    input             gath0,
    input      [440:0] gath0_extra,   // 7 x GENT_W; GENT_W/GATHER_MAX below
    output     [31:0] dout0,        // 32-bit read data, valid in the resp_valid0 cycle only
    input       [3:0] be0,          // byte enable
    output            resp_valid0,  // pulses when a 32-bit read word is ready
    input       [3:0] burst_cnt0,   // read burst dwords (max 15); write burst dwords when wr0
    output            burst_done0,  // pulses when read burst completes

    input             valid1,
    output            ready1,
    input             wr1,
    input      [26:0] addr1,
    input      [31:0] din1,
    output     [31:0] dout1,
    input       [3:0] be1,
    output            resp_valid1,
    input       [3:0] burst_cnt1,
    output            burst_done1,

    input             valid2,
    output            ready2,
    input             wr2,
    input      [26:0] addr2,
    input      [31:0] din2,
    output     [31:0] dout2,
    input       [3:0] be2,
    output            resp_valid2,
    input       [3:0] burst_cnt2,
    output            burst_done2,

    // Requester 3: the PEGC 256-colour packed scanout's line fetch (pc9821_pegc_scan, through
    // pc9821_memory_subsystem's pmem_* and split_sdram_backend's mem3_*). The controller serves
    // it round-robin like the other three, with the scanout deadline below (SB_WAIT_MAX).
    input             valid3,
    output            ready3,
    input             wr3,
    input      [26:0] addr3,
    input      [31:0] din3,
    output     [31:0] dout3,
    input       [3:0] be3,
    output            resp_valid3,
    input       [3:0] burst_cnt3,
    output            burst_done3
);

localparam integer GATHER_MAX = 8;         // the widest gather the payload can carry
localparam integer GENT_W     = 27 + 32 + 4;  // {addr, din, be} per extra gather entry

function integer ns_to_cycles;
    input integer ns;
    integer prod;
    begin
        prod = ns * ((FREQ + 999) / 1000);
        ns_to_cycles = (prod + 1_000_000 - 1) / 1_000_000;
        if (ns_to_cycles < 1)
            ns_to_cycles = 1;
    end
endfunction

// The timing constants meet the SLOWEST part of the supported set (docs/sdram.md) at every clock,
// in nanoseconds converted to cycles by ns_to_cycles. -7 (FAST_GRADE=0, the grade z486_mister.sv
// builds): tRCD = tRP = 21 ns, the AS4C32M16SB-7's figure (Alliance AS4C32M16SB datasheet Rev 1.4,
// Table 16); tRC = 68 ns and tWR = 15 ns, the supported set's bounds (the -7 part itself needs 63
// and 14). -6 (FAST_GRADE=1): Table 16's -6 column, 18/18/60/12.
localparam integer T_RP_NS = FAST_GRADE ? 18 : 21;
localparam integer T_RCD_NS = FAST_GRADE ? 18 : 21;
localparam integer T_RC_NS = FAST_GRADE ? 60 : 68;
localparam integer T_WR_NS = FAST_GRADE ? 12 : 15;
// tRAS (Table 16: 42 ns, both grades) and the datasheet's own tWR (14 ns -7, 12 ns -6). The
// datasheet promises NO tRAS lockout for auto-precharge, and places the implied precharge one
// clock (the burst length) after a READ with auto-precharge ("any subsequent command cannot occur
// within a time delay of {tRP(min.) + burst length}") and tWR after a WRITE with auto-precharge's
// data ("{(burst length -1) + tWR + tRP(min.)}"). tWR there is the part's own minimum - the
// EARLIEST the precharge may begin - so the guard uses the datasheet value, not T_WR_NS's
// conservative 15 ns.
localparam integer T_RAS_NS   = 42;
localparam integer T_WR_DS_NS = FAST_GRADE ? 12 : 14;

// CAS latency: CL2 strictly BELOW 100 MHz, CL3 at 100 MHz and up.
// Hardware evidence (two DE10-Nano boards, source 56eadc9a, clk_sys = SDRAM = 100 MHz, the
// disk-integrity probe): CL2 failed on one board for 9 of 11 placements; CL3 passed on both
// boards for 4 of the first 6 placements screened (the other 2 failed on both boards, the
// pattern of an internal-path placement failure, not the SDRAM). 95 MHz CL2 passed the full
// 8-item regression on both boards. Timing model: tools/profile_gen.py derive_sdram_phase
// gives a worst I/O slack of +0.246 ns at 80..95 MHz (out_hold; read capture in_setup +0.351
// at 95) but +0.035 ns at 100 MHz (in_setup, the read capture, slow 100C corner), and at
// 100 MHz CL2's tCK = 10 ns is exactly the AS4C32M16SB's CL2 minimum for both grades (Table 16:
// tCK at CL2 10 ns), so CL2 has no margin there either; the cutover rests on the hardware evidence.
// DBG_CL (a test-point build only) forces the latency instead.
localparam integer CAS_I   = (DBG_CL != 0) ? DBG_CL : (FREQ < 100_000_000) ? 2 : 3;
// T_RC and T_WR deliberately take NO <=75MHz shortcut either. A shortcut of 4 cycles of tRC
// and 1 of tWR for every FREQ <= 75MHz gives 53.3ns / 13.3ns at 75MHz against the -7 set's 68ns
// tRC and 15ns tWR, so it breaks the -7 grade (and the -6 grade above 66.7MHz), including the
// module default 64.8MHz / FAST_GRADE=0 (4 cycles = 61.7ns < 68ns).
// ns_to_cycles is a correct ceiling at EVERY frequency (and gives the same or smaller values
// below ~60MHz, where such a shortcut over-counts).
localparam integer T_WR_I  = ns_to_cycles(T_WR_NS);
localparam integer T_MRD_I = 2;
// T_RP and T_RCD take no <=75MHz shortcut either. ONE cycle for every FREQ <= 75MHz is only
// legal while one clock already covers tRCD/tRP: 20ns at 50MHz is short of the -7 part's 21ns,
// and 15.4ns at 64.8MHz is short of both grades. ns_to_cycles derives the ceiling at every
// frequency.
localparam integer T_RP_I  = (DBG_TRCD_TRP != 0) ? DBG_TRCD_TRP : ns_to_cycles(T_RP_NS);
localparam integer T_RCD_I = (DBG_TRCD_TRP != 0) ? DBG_TRCD_TRP : ns_to_cycles(T_RCD_NS);
localparam integer T_RC_I  = ns_to_cycles(T_RC_NS);
localparam integer T_DAL_I = T_WR_I + T_RP_I;

// The tRAS guards. An access's auto-precharge must not BEGIN inside tRAS of its ACT (the note at
// T_RAS_NS). Offsets count clocks from the ACT on the pins, as `cycle` does in every access state:
//  * a READ segment of H halves issues its last READ (the auto-precharged one) at T_RCD+H-1, so its
//    precharge begins at T_RCD+H, which must reach T_RAS_I; a segment shorter than that delays its
//    first READ by RD_SHIFT (2 halves: every dword read; 1 half: the ADQM=0 read-modify-write);
//  * a WRITE whose last (auto-precharged) half is issued at offset L begins its precharge tWR (the
//    datasheet's) later, so L must reach T_RAS_WR_I. Two halves put L at T_RCD+1; ADQM=1 always
//    writes both halves (the unwanted one fully masked), so only an ADQM=0 single-half write is
//    delayed, by WR_SHIFT1.
// At 90 MHz CL2 -7 (T_RCD 2, T_RAS_I 4, T_RAS_WR_I 3) RD_SHIFT2 is 0, and WR_SHIFT1 (1) applies only
// to ADQM=0 single-half writes, so the shipped read and write timing is unchanged; at 120 MHz
// (T_RCD 3, T_RAS_I 6: 5 clocks = 41.7 ns) a single-dword read waits RD_SHIFT2 = 1 clock.
localparam integer T_RAS_I    = ns_to_cycles(T_RAS_NS);
localparam integer T_RAS_WR_I = ns_to_cycles(T_RAS_NS - T_WR_DS_NS);
localparam integer RD_SHIFT1  = (T_RAS_I > T_RCD_I + 1) ? (T_RAS_I - T_RCD_I - 1) : 0;
localparam integer RD_SHIFT2  = (T_RAS_I > T_RCD_I + 2) ? (T_RAS_I - T_RCD_I - 2) : 0;
localparam integer WR_SHIFT1  = (T_RAS_WR_I > T_RCD_I) ? (T_RAS_WR_I - T_RCD_I) : 0;
localparam         RD_GUARD   = (RD_SHIFT2 != 0);

// The write exits' trim. A write state used to return to IDLE one clock later than tDAL and tRC
// needed (its exit was set before the IDLE latch and the ACT stage existed): the next ACT, two
// clocks after the exit (IDLE, then the ACT stage), came tDAL + 1 after the last WRITE. EXIT_TRIM
// takes that clock back, so the next ACT lands exactly tDAL after the last WRITE (and, for a
// single store, tRCD + tDAL + 1 >= tRC after its own ACT, held at elaboration below). An AUTO
// REFRESH is issued from IDLE itself, one clock before an ACT could be, so a trimmed exit sets
// rp_hold and IDLE holds a pending refresh for that one clock. Off where tDAL is under three
// clocks: the two-half write's DQ release (at T_RCD+2) would fall after the trimmed exit. Off,
// too, where the trimmed single store's ACT-to-ACT (tRCD + tDAL + 1) would fall short of tRC:
// 133 MHz on the -7 table (3 + 5 + 1 = 9 < 10 clocks), whose exit stays the untrimmed one.
localparam integer EXIT_TRIM  = ((T_DAL_I >= 3) && (T_RCD_I + T_DAL_I + 1 >= T_RC_I)) ? 1 : 0;

// CAS and the timing intervals are declared at their MINIMUM width, and every comparison
// against them elsewhere in this file zero-extends the parameter. Verilator reports each one as
// WIDTHEXPAND; the extension is EXACT, because each value is bounded well inside 4 bits at any
// supported FREQ (T_RC is the largest, 10 cycles at 133 MHz). Widening these to match their
// comparands was tried and does NOT remove the warnings - it moves them onto the initialisers,
// because the values arrive through `integer` - so they are waived where they fire instead.
// T_WR had no reader at all: the write path reaches T_WR_I through T_DAL_I. Removed rather than
// left looking like a timing knob that nothing consults.
localparam [3:0] CAS   = CAS_I[3:0];
localparam [3:0] T_MRD = T_MRD_I[3:0];
localparam [3:0] T_RP  = T_RP_I[3:0];
localparam [3:0] T_RCD = T_RCD_I[3:0];
localparam [3:0] T_RC  = T_RC_I[3:0];

generate
if (FREQ > 133_000_000) begin : gen_freq_check
    initial
        $error("ERROR: This timing table is only characterized up to 133MHz.");
end
// The guards above cover the access shapes whose auto-precharge can come inside tRAS; these are
// the shapes they assume cannot (a two-half write and a four-half read segment), held at
// elaboration so a clock where they could fails to build instead of violating tRAS.
if ((T_RAS_WR_I > T_RCD_I + 1) || (T_RAS_I > T_RCD_I + 4)) begin : gen_tras_check
    initial
        $error("ERROR: tRAS is not met by a two-half write or a four-half read at this FREQ.");
end
// A store's write exit puts the next ACT tRCD + tDAL + 2 - EXIT_TRIM clocks after its own ACT.
// EXIT_TRIM is off wherever the trim alone would break tRC, so this fires only on a table whose
// untrimmed exit breaks it too (a --dbg-sdram-trcd-cycles override below the derived tRCD).
if (T_RCD_I + T_DAL_I + 2 - EXIT_TRIM < T_RC_I) begin : gen_trc_check
    initial
        $error("ERROR: a store's write exit would break tRC at this FREQ.");
end
// A read's exits start the next row command CAS + 3 clocks after its last (auto-precharged) READ
// without consulting tRP (the AUTO REFRESH from IDLE, the split read's second ACT, RMW_ACT), and
// the bank precharges from 1 clock after that READ, so tRP must fit in CAS + 2 clocks. Every
// derived table meets it (worst: tRP 3 at CL3); a --dbg-sdram-trcd-cycles override may not.
if (T_RP_I > CAS_I + 2) begin : gen_rp_check
    initial
        $error("ERROR: tRP exceeds CAS + 2 clocks, which a read's exit assumes.");
end
endgenerate

/* verilator lint_off PROCASSINIT */   // NO reset arm assigns busy_buf, so this initialiser IS
                                      // its power-up value and must be BUSY until the init
                                      // sequence finishes, or the controller accepts a request
                                      // before the SDRAM is out of its 200us calibration.
reg busy_buf = 1'b1;
/* verilator lint_on PROCASSINIT */
reg nce_r;
always @(posedge clk) nce_r <= nce;
reg busy_r;
always @(posedge clk) busy_r <= busy;
assign busy = ~nce_r ? busy_buf : busy_r;    // use busy_buf value the next cycle of CE

// Tri-state DQ (the pins are driven at the end of the module: OUT_DDIO)
/* verilator lint_off PROCASSINIT */   // the initialiser IS the power-up value: DQ released (Hi-Z)
reg        dq_oen = 1'b1;   // 0: drive dq_out, 1: Hi-Z
/* verilator lint_on PROCASSINIT */
reg [15:0] dq_out;
wire [15:0] dq_in = SDRAM_DQ;

// Single registered DQ capture.  This is the ONLY register that reads the DQ
// pins, so FAST_INPUT_REGISTER packs it into the IOB input cell -> deterministic,
// placement-independent read timing (were rd_lo16/dout_word/dout_buf each to read
// the raw pin, only one could pack into the IOB and the rest would capture
// through placement-dependent fabric routing).  dq_r lags dq_in by one cycle, so
// the READ/RMW_READ capture thresholds below are pushed out by 1.
// The cell is chosen by DQ_IN_DDIO (the parameter's note): either way dq_r is dq_in one clk
// edge later, so the capture thresholds below do not depend on it. The SDC names the capture
// register of the selected branch (tools/profile_gen.py, render_sdc).
wire [15:0] dq_r;
generate if (DQ_IN_DDIO) begin : g_dq_ddio
`ifdef VERILATOR
    // altddio_in's dataout_h is its datain registered on the rising inclock edge.
    reg [15:0] dq_cap_h;
    always @(posedge clk) dq_cap_h <= dq_in;
    assign dq_r = dq_cap_h;
`else
    /* The low (falling-edge) half has no consumer; the SDC cuts its input path. */
    altddio_in #(
        .intended_device_family("Cyclone V"),
        .invert_input_clocks("OFF"),
        .lpm_hint("UNUSED"),
        .lpm_type("altddio_in"),
        .power_up_high("OFF"),
        .width(16)
    ) dq_cap (
        .datain(dq_in), .inclock(clk), .dataout_h(dq_r), .dataout_l(),
        .aclr(1'b0), .aset(1'b0), .inclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
`endif
end else begin : g_dq_ff
    reg [15:0] dq_r_ff;
    always @(posedge clk) dq_r_ff <= dq_in;
    assign dq_r = dq_r_ff;
end endgenerate

// Command/address
// THE COMMAND REGISTER MUST POWER UP IN NOP (2026-10-05). tb_pc9821_sdram_strict, driving this
// controller into the XSDS strict module model, caught the module being handed a
// MODE_REGISTER_SET at 5.5 ns. The cause is here: the strobes are combinational from `cmd`
// (assign below), `cmd` had no power-up value, and 3'b000 IS CMD_SetModeReg - so from the
// moment the FPGA configured until the reset arm clocked once, the module's pins carried CS=0
// with RAS=CAS=WE=0, an MRS whose address carried mode register 0 (an illegal CL0, a wrong
// burst length). The SDRAM controller guide warns that a violated power-up sequence "may lead to
// unpredictable start-up modes", and an unpredictable mode register IS a wrong CAS latency -
// stale or corrupt reads. The 200 us hold itself already existed (rst_cnt below, counted after
// resetn rises, so the FPGA's configuration time adds to it); this initialiser is the missing
// half. `a` is given one too so no address is left undefined either.
/* verilator lint_off PROCASSINIT */   // the initialisers ARE the power-up values (the note above);
                                      // the FSM then assigns both procedurally, as intended
reg [2:0]  cmd = 3'b111;   // NOP at power-up (see the note above; 3'b000 is CMD_SetModeReg)
reg [12:0] a = 13'd0;
// dqm_a: a TWIN of a[12:11] for the SDRAM_DQML/DQMH pins.
// Every full-width write of `a` goes through ax() into {dqm_a, a}, so dqm_a == a[12:11] on every
// cycle by construction (the two partial writes, a[10] and a[10:0], never touch bits 12:11), and
// the pins carry exactly what they carried when they were wired to a[12:11]. Its reason is
// Quartus 17.0.2: with one register driving both SDRAM_A[12:11] and SDRAM_DQM*, the fitter
// duplicates it into the two fast output registers, and on some netlists that duplication ends
// in the DTM internal error (dtm_node.cpp:772). dont_merge keeps
// synthesis from folding the twin back into a[12:11].
(* dont_merge *) reg [1:0] dqm_a = 2'b00;
/* verilator lint_on PROCASSINIT */
function [14:0] ax(input [12:0] v);
    ax = {v[12:11], v};
endfunction
reg [1:0]  sd_ba;           // SDRAM_BA
reg        sd_ncs;          // SDRAM_nCS
`ifdef VERILATOR
always @(posedge clk)
    if (dqm_a !== a[12:11])
        $fatal(1, "sdram: dqm_a %b != a[12:11] %b (the DQM twin must equal it every cycle)",
               dqm_a, a[12:11]);
`endif

// Per-port ready pulse (1 cycle, request accepted)
reg [3:0] ready_pulse;
assign ready0 = ready_pulse[0];
assign ready1 = ready_pulse[1];
assign ready2 = ready_pulse[2];
assign ready3 = ready_pulse[3];

// Read data path
// doutN IS VALID ONLY IN ITS resp_validN CYCLE. The only instantiation is sdram_sync_bridge,
// which keeps port 0's hold for its readers (ports 1-3 are read in their own resp_valid cycle),
// so per-port holding registers here (128 flops plus a 2:1 mux per port) would never be
// observed, and every port presents the one completed word (proved differentially against a
// per-port-hold controller+bridge pair).
reg  [31:0] dout_word;             // most recent completed word (active port)
reg         data_resp_pulse;       // 1-cycle pulse when a 32-bit word completes

assign resp_valid0 = (req_id_buf == 2'd0) ? data_resp_pulse : 1'b0;
assign resp_valid1 = (req_id_buf == 2'd1) ? data_resp_pulse : 1'b0;
assign resp_valid2 = (req_id_buf == 2'd2) ? data_resp_pulse : 1'b0;
assign resp_valid3 = (req_id_buf == 2'd3) ? data_resp_pulse : 1'b0;

assign dout0  = dout_word;
assign dout1  = dout_word;
assign dout2  = dout_word;
assign dout3  = dout_word;

// Burst-done pulse (on final word of a read burst)
reg burst_done_pulse;
assign burst_done0 = (req_id_buf == 2'd0) ? burst_done_pulse : 1'b0;
assign burst_done1 = (req_id_buf == 2'd1) ? burst_done_pulse : 1'b0;
assign burst_done2 = (req_id_buf == 2'd2) ? burst_done_pulse : 1'b0;
assign burst_done3 = (req_id_buf == 2'd3) ? burst_done_pulse : 1'b0;

// FSM. ACT is the row-activate stage: IDLE latches the granted request and ACT issues the row
// from those latches one cycle later, so the arbiter -> address mux -> pin-register path is one
// register shorter. Every requester pays one
// clk_sdram cycle per
// accepted request for it, and REFRESH_DELAY below counts that cycle.
reg [3:0] state;
localparam INIT     = 4'd0;
localparam CONFIG   = 4'd1;
localparam IDLE     = 4'd2;
localparam ACT      = 4'd3;
localparam READ     = 4'd4;
localparam RMW_READ = 4'd5;
localparam WRITE    = 4'd6;
localparam REFRESH  = 4'd7;
localparam RMW_ACT  = 4'd8;
localparam WRITE_BURST = 4'd9;   // port 0's opt-in multi-word write (burst_cnt >= 2)
localparam WRITE_BURST_ACT= 4'd10;  // ... and the same for the write pair
localparam GATH_RD = 4'd11;      // G3 gather-RMW session: the half reads (row stays open)
localparam GATH_WR = 4'd12;      // ... and the merged half writes back to the same columns

// RAS# CAS# WE#
localparam CMD_SetModeReg  = 3'b000;
localparam CMD_AutoRefresh = 3'b001;
localparam CMD_PreCharge   = 3'b010;
localparam CMD_BankActivate= 3'b011;
localparam CMD_Write       = 3'b100;
localparam CMD_Read        = 3'b101;
localparam CMD_NOP         = 3'b111;

// Mode register: burst length = 1, sequential
localparam [2:0] BURST_LEN   = 3'b000;   // 1
localparam       BURST_MODE  = 1'b0;     // sequential
localparam [10:0] MODE_REG   = {4'b0000, CAS[2:0], BURST_MODE, BURST_LEN};

// Refresh period. tREFI is 64ms/8192 rows = FREQ/128000 cycles (390.625 at 50MHz), and the
// counter target must sit BELOW it by the whole gap from "refresh_cnt expired" to "REFRESH on
// the pins": two registered cycles (need_refresh, then cmd) plus one in-flight transaction,
// because a refresh is only issued from IDLE and an accepted burst cannot be interrupted. The
// longest legal transaction is a 15-dword read that SPLITS
// (the first row takes what fits, 1 dword worst case, then the second row's ACT and its 14 dwords),
// so the margin is both
// ACT/T_RCD/CAS chains, the second ACT's own cycle, and the ACT stage every transaction pays.
// Measured without this margin: the pin-to-pin interval was 392 cycles at rest -- 0.35% over
// tREFI, so the counter missed tREFI even when idle -- and 395 under a saturating 4-dword stream
// (1.1% over the 64ms budget). A pre-ACT reservation
// needs no term of its own: it is
// made only while no refresh is pending, and it adds one fixed three-cycle data drain plus that
// same longest READ before the refresh. The G3 gather session is the OTHER long transaction
// (GATHER_K entries of two-half read-merge-write under one ACT): its accept-to-IDLE is
// 1 + w0 + wtot + T_DAL_I - 2 with w0 <= T_RCD+CAS+2*GATHER_K and wtot <= 2*GATHER_K, so the
// same two-cycle margin is T_RCD+CAS+4*GATHER_K+T_DAL_I+1 -- below the read-split term at
// GATHER_K <= 7 and at every supported FREQ except the 133MHz corner, where the max binds.
localparam integer REFRESH_DELAY_READS = 3 + (T_RCD_I + CAS_I + 2*1 - 1)
                                      + (T_RCD_I + CAS_I + 2*14 - 1) + 2 + 1;
localparam integer REFRESH_DELAY_GATH = T_RCD_I + CAS_I + 4*GATHER_K + T_DAL_I + 1;
localparam integer REFRESH_DELAY  = (REFRESH_DELAY_GATH > REFRESH_DELAY_READS)
                                      ? REFRESH_DELAY_GATH : REFRESH_DELAY_READS;
localparam integer REFRESH_RAW    = (FREQ/1000) * 64 / 8192;
localparam integer REFRESH_TARGET = REFRESH_RAW - REFRESH_DELAY;
// At a slow test frequency (1 MHz, say) tREFI is shorter in cycles than the delay, so the
// margin cannot apply; keep the raw tREFI there or the refresh would re-arm during its own
// REFRESH state and starve every request.
localparam integer REFRESH_CYCLES = (REFRESH_TARGET < 1) ? REFRESH_RAW : REFRESH_TARGET;
localparam integer REFRESH_CNT_W = (REFRESH_CYCLES < 2) ? 1 : $clog2(REFRESH_CYCLES + 1);

reg cfg_now;
reg [3:0] cfg_cbr;         // init AutoRefreshes (CBR) issued so far for the current chip

reg [4:0]  cycle;             // small scheduler counter (saturates)
/* verilator lint_off UNUSEDSIGNAL */   // Only [25:2] are ever read. [26] is the second-chip
                                      // select and is latched separately as req_chip_buf; [1:0]
                                      // is the byte within the dword, which this controller
                                      // ignores by contract (see the addr0 port comment).
reg [26:0] addr_buf;
/* verilator lint_on UNUSEDSIGNAL */
reg [31:0] din_buf;
reg [31:0] din_hi_buf;        // port 0's two-word write payload, word 1 (word 0 is din_buf)
reg [3:0]  be_buf;
reg [1:0]  req_id_buf;
reg        req_wr_buf;        // granted request's wr/be/burst, held for the ACT stage below
reg [3:0]  burst_buf;
reg        wr_split;          // the pair starts in the row's LAST column, so it spans two rows
reg        wr_second;         // WRITE_BURST is writing the pair's second row
reg [2:0]  wr_seg_h;          // halves in the write burst's CURRENT row segment
// The two-word write: burst_cnt == 2 EXACTLY, ON PORT 0 ONLY. Any other count - and any other
// port, whose upper payload word does not exist - selects the single-word path, which is what a
// write's burst count has ALWAYS meant here: the controller writes one word and the count is
// ignored, so no existing caller's behaviour moves. Port 0's one caller that presents 2 is
// pc9821_pegc_storebuf's pair drain (full dwords only; the pair mask contract below).
// THE PORT TERM IS THE FIX, not a tidiness change: without it a burst_cnt == 2
// write on ports 1/2/3 took this path as well, latched port 0's `din0_hi` as its second word (tied
// to 32'd0 in this machine) and wrote four zero bytes the caller never asked for. Latent until
// then - no live caller presents 2 (z486's L1 store drain 8'd1, its line fill 8'd4 on a READ, the
// loader and the PCM buffer 8'd1, the font reader 8) - so tb_pc9821_sdram's port-1 arm is the
// stimulus that reaches it, and split_sdram_backend's port-0 guard names the next caller that asks.
// A gather request is NEVER the pair: burst_buf is its entry count, not a burst shape.
wire [3:0] ef_wr_burst = ((req_id_buf == 2'd0) && !req_gath_buf && (burst_buf == 4'd2)) ? 4'd2 : 4'd1;
reg        req_gath_buf;        // the granted request is a gather session
reg        req_large_buf;
reg        req_chip_buf;
reg        init_chip;

// Speculative pre-ACT. Once the running read has issued every CAS its
// command bus is idle until the data drains, so the row of the NEXT request is activated then
// and `cycle` continues from it at the accept. The reservation is HELD, not acknowledged: ready
// still pulses at the accept, so the one-accept-per-transaction and response-order contract is
// unchanged; only the ACT and its T_RCD leave the accept's serial path.
reg        pnd_valid;         // a row is open for the request latched below
reg        pnd_go;            // issue that BankActivate this cycle
reg  [1:0] pnd_id;
reg [26:0] pnd_addr;
reg        pnd_chip;
reg        pnd_large;
reg  [4:0] pnd_age;           // cycles since the pre-ACT was issued
// The reservation's PAYLOAD, latched beside pnd_addr (S2-j). Re-reading burst/be/din at the
// reserved take through the live request mux (req_*), whose select is the round-robin cone,
// would keep `take_id -> req mux -> burst_buf/din_buf/be_buf/rd_total_halfs/rd_seg_halfs` in
// the S2 cone. The requester holds valid AND the whole payload until its one-cycle ready
// (sdram_sync_bridge.sv, "the requester contract, ASSERTED"), and the reservation is made only for the current pick, so the
// payload at the take equals the payload at the reservation; latch it at the reservation and read
// it at the take, exactly as S2-a did one field over for the next-row field. Asserted below.
reg  [3:0] pnd_burst;
reg  [3:0] pnd_be;
reg [31:0] pnd_din;
`ifdef VERILATOR
reg  [3:0] pb_burst_chk;      // the take's own live request (the earlier mux form), kept as the check
reg  [3:0] pb_be_chk;
reg [31:0] pb_din_chk;
reg        pnd_take_d;
`endif

reg [REFRESH_CNT_W-1:0] refresh_cnt;
reg        need_refresh;

// READ pipeline counters (16-bit halfwords)
reg [4:0]  rd_total_halfs;    // = 2 * effective dword count (<= 30)
reg [4:0]  rd_seg_halfs;      // halves the burst's FIRST row holds; the rest needs a second ACT
reg        rd_row2;           // that second row has been opened (the split must fire once)
reg [4:0]  rd_issued;         // # of CAS commands already issued
reg [4:0]  rd_received;       // # of 16-bit words captured from dq
reg [8:0]  rd_col_base;       // starting dword column (0..511)
// The `cycle` value at which this read's FIRST CAS is issued: T_RCD for a normal ACT, the
// pre-ACT's elapsed age (never below T_RCD) for a reserved one. The data capture is keyed to
// THIS, not to the ACT, because a reserved read enters READ with `cycle` already past T_RCD.
reg [4:0]  rd_cas0;
reg [15:0] rd_lo16;           // latch low-half before composing 32-bit
reg [1:0]  rmw_issued;
reg [1:0]  rmw_received;
reg [1:0]  rmw_total_reads;
reg [1:0]  rmw_read_halfs;
reg [31:0] rmw_old_data;
reg [1:0]  wr_halfs;          // bit0=write low 16-bit half, bit1=write high 16-bit half

// ---- G3 gather-RMW session state (the header) ----
// One latched copy per session entry: the column it writes, its data and byte enables,
// and the read half that merges into it. gk_rmap/gk_wmap are REGISTERED at the accept
// (a pure function of the accepted be masks and entry count): read slot s is the s-th half
// any entry touches with SOME but not ALL of its bytes, write slot s is the s-th touched
// half, both in entry order, low half first. They are stable for the whole session, so the
// registered value equals the combinational form's value at every consumer cycle (the
// first consumer, GATH_RD, is >= 2 cycles after the accept).
reg  [8:0] gk_col  [0:GATHER_MAX-1];
reg [31:0] gk_din  [0:GATHER_MAX-1];
reg  [3:0] gk_be   [0:GATHER_MAX-1];
reg [31:0] gk_old  [0:GATHER_MAX-1];
reg  [5:0] gk_ri, gk_rc;        // read slots issued / captured
reg  [5:0] gk_wc;               // write-phase cycle counter (the session outgrows `cycle`)
reg  [3:0] gk_rmap [0:2*GATHER_MAX-1];   // {entry[2:0], half}
reg  [3:0] gk_wmap [0:2*GATHER_MAX-1];
reg  [5:0] gk_rtot, gk_wtot;
// The maps are formed ONE CYCLE AFTER the accept (docs/timing.md S2-b), from the be masks and the
// entry count the accept latched (gk_be[], burst_buf), so the arbiter's request mux (take_id ->
// req_be/gath0_extra) does not feed the scan. The accept is followed by ACT, so the first
// consumer (GATH_RD's read issue and gk_w0, and the look-ahead's first load for a write, GATH_RD's
// last cycle) is still >= 2 cycles after the accept and reads the formed maps: the same function
// of the same values, one cycle earlier than anything reads it. Asserted (VERILATOR) against the
// earlier accept-time form below.
reg        gk_map_d;
reg        gk_padded;           // ADQM: the session was padded to two write slots (gk_map_form)
// rp_hold: the previous cycle left a write state with exactly tDAL to an ACT, which is one clock
// short for an AUTO REFRESH issued from IDLE; IDLE holds the refresh for that one cycle.
reg        rp_hold;
`ifdef VERILATOR
reg  [3:0] gk_rmap_chk [0:2*GATHER_MAX-1];
reg  [3:0] gk_wmap_chk [0:2*GATHER_MAX-1];
reg  [5:0] gk_rtot_chk, gk_wtot_chk;
`endif

// The slot maps and totals are computed at the ACCEPT (see the gk_latch block below),
// from the same per-entry be masks and entry count that latch there. Registering them
// moves the 7-level entry-count -> gk_wmap scan off the gk_be -> dq_out clk_sdram cone;
// they are pure functions of the accepted be masks and stable for the whole session, so
// the registered value equals the combinational form's value at every consumer cycle (the
// first consumer, GATH_RD, is >= 2 cycles after the accept).

// The write stream's merge: write slot s writes the merged half of its entry - the read
// half with its be bytes replaced - and a half no entry byte touches is not written at
// all (it is not in the map). A half whose be fills it both ways merges to the new half
// alone, so a full-half entry needs no read and the one expression covers both.
//
// Class-1 depth cut (the gk_n -> gk_wmap -> dq_out clk_sdram cone): the
// per-byte new-vs-old select is hoisted OUT of the critical path into a per-entry
// pre-computed 32-bit merged word (gk_mword, a pure function of the gk_be/gk_din/
// gk_old registers), so the critical tail pays only the 4-entry word mux and a single
// half select instead of the array-read mux plus the two-level byte merge.
// Value-identical: gk_mword[ee] is byte_merge(din[ee], old[ee], be[ee]) and gk_wdat is
// the selected half of it, exactly the unhoisted expression. Proven over every free input by SAT
// (14 -> 12 4-LUT levels on the cone).
//
// Class-2 pipeline (an accepted latency stage): the slot maps themselves are REGISTERED at
// the accept, so the gk_n -> gk_wmap -> dq_out combinational cone above is cut
// (gk_wmap[gk_wc] reads a flop). The gk_mword
// hoist stays: it is the per-entry merged word the write tail selects a half of, and it
// keeps the tail at a 4-entry word mux plus one half select.
wire [31:0] gk_mword [0:GATHER_K-1];
generate
    genvar gme;
    for (gme = 0; gme < GATHER_K; gme = gme + 1) begin : gen_gk_mword
        assign gk_mword[gme] = {
            gk_be[gme][3] ? gk_din[gme][31:24] : gk_old[gme][31:24],
            gk_be[gme][2] ? gk_din[gme][23:16] : gk_old[gme][23:16],
            gk_be[gme][1] ? gk_din[gme][15:8]  : gk_old[gme][15:8],
            gk_be[gme][0] ? gk_din[gme][7:0]   : gk_old[gme][7:0]};
    end
endgenerate
wire  [2:0] gk_ws   = gk_wmap[gk_wc[3:0]][2:0];   // gk_wmap[s][3] is gi[2], always 0 (gi < GATHER_K)
wire  [1:0] gk_ws_e = gk_ws[2:1];   // entry index 0..3
wire        gk_ws_h = gk_ws[0];
wire [15:0] gk_wdat = gk_ws_h ? gk_mword[gk_ws_e][31:16] : gk_mword[gk_ws_e][15:0];

// ADQM (the "GD" gather): with the byte mask riding a[12:11] there is nothing to read and
// nothing to merge, so the session is ACT + one masked WRITE per touched half. The data is
// the entry's OWN half and the mask is its own byte enables; gk_rtot is forced to 0 at the
// accept, which makes GATH_RD issue no reads and turns gk_w0 into T_RCD.
wire [2:0]  gk_ws_gi  = {1'b0, gk_ws_e};   // gk_din/gk_be are [0:GATHER_MAX-1]; the entry is < GATHER_K
wire [15:0] gk_gd_dat  = gk_ws_h ? gk_din[gk_ws_gi][31:16] : gk_din[gk_ws_gi][15:0];
wire [1:0]  gk_gd_mask = gk_ws_h ? {~gk_be[gk_ws_gi][3], ~gk_be[gk_ws_gi][2]}
                                 : {~gk_be[gk_ws_gi][1], ~gk_be[gk_ws_gi][0]};

// The cycle of the first merged write: no read at all starts at T_RCD like the plain
// write arm; otherwise the stream starts once every read has LANDED (its capture is one
// dq_r stage behind the pins) and the last read's data has left the DQ bus. Write j is
// j cycles later and needs capture j, which lands j cycles later too, so one start
// covers the whole stream.
// An ADQM=0 session that writes ONE half and reads none would auto-precharge that write at
// T_RCD: it waits WR_SHIFT1 for tRAS (the guards' note); ADQM=1 sessions are padded instead.
wire  [5:0] gk_w0 = (gk_rtot == 6'd0) ? ({2'b0, T_RCD} + ((!ADQM && (gk_wtot == 6'd1)) ? WR_SHIFT1[5:0] : 6'd0))
                    : {2'b0, T_RCD} + {2'b0, CAS} + ((gk_rtot > 6'd3) ? gk_rtot : 6'd3);
wire        gk_on = (state == GATH_RD) || (state == GATH_WR);

// S1-a look-ahead (timing-wins, 0 cycles): the merged write's command fields, one slot early.
// GATH_WR walks gk_wc 0,1,2,... one slot per cycle, and the slot map, the entries' columns
// and (ADQM) data/byte enables are all latched at the accept and stable for the session, so
// the fields of the slot the NEXT cycle writes are known a cycle ahead: slot gk_wc+1 inside
// GATH_WR, slot 0 in GATH_RD (whose last cycle is always the one before the first write; it
// is the only way into GATH_WR). The pins then load from these flops and the
// gk_wmap[gk_wc] read (fan-out ~45) with its entry mux leaves the clk_sdram cones into
// dq_out and a[] (base worst: gk_wmap -> Mux0 -> Selector145 -> 5.7 ns hop -> dq_out DDIO).
// Value-identical at every write; the SIM-ONLY check below holds it. The ADQM=0 merged data
// (gk_wdat) reads gk_old, which the read capture can still update in the cycle before a
// write, so it is not looked ahead (the shipped core is ADQM=1).
wire  [5:0] gk_wn    = (state == GATH_WR) ? (gk_wc + 6'd1) : 6'd0;
wire  [3:0] gk_wn_m  = gk_wmap[gk_wn[3:0]];
wire  [2:0] gk_wn_gi = {1'b0, gk_wn_m[2:1]};
wire  [8:0] gk_wn_col = gk_col[gk_wn_m[3:1]];
reg  [15:0] gk_la_dat;          // ADQM: the slot's own half (gk_gd_dat one slot early)
reg   [1:0] gk_la_mask;         // ADQM: its DQM on a[12:11] (gk_gd_mask one slot early)
reg   [9:0] gk_la_col16;        // the slot's 16-bit column (col16 one slot early)
reg         gk_la_last;         // the slot is the session's last write (auto-precharge)
always @(posedge clk) begin
    gk_la_dat   <= gk_wn_m[0] ? gk_din[gk_wn_gi][31:16] : gk_din[gk_wn_gi][15:0];
    gk_la_mask  <= gk_wn_m[0] ? {~gk_be[gk_wn_gi][3], ~gk_be[gk_wn_gi][2]}
                              : {~gk_be[gk_wn_gi][1], ~gk_be[gk_wn_gi][0]};
    gk_la_col16 <= {req_large_buf ? gk_wn_col : {1'b0, gk_wn_col[7:0]}, gk_wn_m[0]};
    gk_la_last  <= (gk_wn == (gk_wtot - 6'd1));
end

// Row-crossing splits and the row+1 carry. {bank,row} is addr[25:11] on the large
// geometry and addr[24:10] on the small one -- 15 bits either way -- so rc_next is the NEXT
// ROW as a plain increment of that field: row 8191 of a bank carries into row 0 of the NEXT
// bank instead of wrapping back into row 0 of the same one, and on a 128MB module (two
// complementary-CS chips) the bank wrap at chip 0's end carries into chip 1. The split paths'
// ACT uses rc_next, and -- just as importantly -- the second segment's READ/WRITE COMMANDS
// must carry the same bank/chip: before the carry they could keep addr_buf's bank because the
// next row was always in it.
// The next-row field, REGISTERED ONE CYCLE AFTER THE ACCEPT from the accept's own latches
// (docs/timing.md S2-a). It was first registered AT the accept from the live request mux (a
// re-test of S4b's refuted candidate, measured with a sweep per side), which took the incrementer,
// its geometry mux and the rc_chip compare off the READ/WRITE command mux but left them behind
// the arbiter's request mux (`req_addr`), in the clk_sys S2 cone (storebuf pass_req -> the
// arbiter's Mux -> rc_of's adder -> rc_chip_buf). Now they read addr_buf/req_large_buf/
// req_chip_buf and the accept's latched geometry (rc_sz3_buf) in the cycle after the accept
// (rc_acc_d), so their inputs are registers. EXACT: every reader is a row-crossing second segment
// (the split ACT and rd_row2 commands in READ, wr_second in WRITE_BURST, the WRITE_BURST_ACT /
// GATH second row), none of which can run in the cycle after an accept - that cycle is ACT
// (new_req) or the first READ cycle with rd_row2 = 0 and nothing issued (pnd_take) - and in
// every later cycle rc_* holds the same function of the same latches as before. Both facts are
// asserted (VERILATOR, rc_next_chk below: the earlier accept-time form kept as a check register),
// so every bench that runs the controller - the row-crossing ones included (sdram_act, sdram_col16,
// sdram_wburst, sdram_strict) - checks them on every cycle.
/* verilator lint_off UNUSEDSIGNAL */   // reason: rc_of reads the {bank,row} field
// only - bit 26 (the 128MB chip select) and bits 9:0 (the column) are NOT part of the
// next-ROW field, and the callers pass the whole 27-bit address.
function [14:0] rc_of(input [26:0] ad, input lg);
    rc_of = {lg ? ad[25:24] : ad[24:23],
             lg ? ad[23:11] : ad[22:10]} + 15'd1;
endfunction
/* verilator lint_on UNUSEDSIGNAL */
reg  [14:0] rc_next_buf;
reg         rc_chip_buf;
reg         rc_acc_d;     // the cycle after an accept: rc_* are formed from its latches here
reg         rc_sz3_buf;   // the accept's (sdram_size == 3), the two-chip geometry
`ifdef VERILATOR
reg  [14:0] rc_next_chk;  // the earlier form, registered AT the accept from the live request
reg         rc_chip_chk;
`endif

function [31:0] byte_merge(input [31:0] old_data, input [31:0] new_data, input [3:0] be);
    byte_merge = {be[3] ? new_data[31:24] : old_data[31:24],
                  be[2] ? new_data[23:16] : old_data[23:16],
                  be[1] ? new_data[15:8]  : old_data[15:8],
                  be[0] ? new_data[7:0]   : old_data[7:0]};
endfunction

// Simple refresh request. need_refresh is STICKY: it sets when the free-running refresh_cnt
// crosses REFRESH_CYCLES and clears only when a refresh is actually ISSUED (refresh_go).
// Clearing it whenever refresh_cnt wrapped through 0 would silently DROP a refresh blocked past
// the wrap (by !refresh_allowed or nce), and the next attempt would come a whole counter wrap
// later -- 1024 cycles at 100MHz (10.24us > tREFI). Setting wins over clearing
// so a wrap that re-crosses REFRESH_CYCLES while one refresh is still pending cannot lose it.
// refresh_go is exactly the FSM's IDLE refresh branch: its condition, not a copy that can drift.
wire refresh_go = (state == IDLE) && ~nce && !pnd_take && need_refresh && refresh_allowed && !rp_hold;
/* verilator lint_off WIDTHEXPAND */   // minimum-width timing parameters; see the note at their declaration
always @(posedge clk) begin
    if (!resetn) begin
        need_refresh<= 1'b0;
    end else begin
        if (refresh_cnt == REFRESH_CYCLES)
            need_refresh <= 1'b1;
        else if (refresh_go)
            need_refresh <= 1'b0;
    end
end

/* verilator lint_on WIDTHEXPAND */

// ---- The round-robin TDM arbiter ----
// rr_ptr is the requester with priority this turn. The winner is the lowest-indexed requester
// at or after rr_ptr; if none are requesting there, the search wraps to the ones before it. The
// pointer advances past the winner on every accept, so with all four requesting the order is a
// strict rotation 0,1,2,3,0,... and a requester waits at most the other three slots. Work is
// conserved: an idle slot is skipped, not held, so a lone requester runs at full rate.
reg [1:0] rr_ptr;
wire [3:0] req_vec = {valid3, valid2, valid1, valid0};
wire [3:0] rr_at_or_after = (rr_ptr == 2'd0) ? req_vec :
                            (rr_ptr == 2'd1) ? (req_vec & 4'b1110) :
                            (rr_ptr == 2'd2) ? (req_vec & 4'b1100) :
                                               (req_vec & 4'b1000);
wire [3:0] rr_sel = (rr_at_or_after != 4'b0000) ? rr_at_or_after : req_vec;
wire [1:0] rr_id = rr_sel[0] ? 2'd0 :
                   rr_sel[1] ? 2'd1 :
                   rr_sel[2] ? 2'd2 :
                   rr_sel[3] ? 2'd3 : 2'd0;   // 0 only when nothing requests (rr_valid low)
wire       rr_valid = |req_vec;

// ---- Bounded scanout priority: one guaranteed slot per rotation ----
// Round-robin alone already bounds a requester's wait at three accepts when all four ask, but
// that bound is a property of rr_ptr's phase rather than a rule. This makes it a rule for the
// scanout (requester 3, the PEGC packed scanout's line fetch): once the rotation has passed it over SB_WAIT_MAX
// times it becomes the winner, so its slot cannot be postponed by where the pointer happens to
// sit. It is a DEADLINE, not a level - it can only bring the scanout forward to a slot the
// rotation already owed it, never hold one away from anyone else, so no requester starves. A
// strict fixed priority is what stopped the ITF's boot fill, and is not this.
localparam [1:0] SB_WAIT_MAX = 2'd3;
reg  [1:0] sb_wait;      // accepts granted to other requesters since the scanout was last served
wire       sb_deadline = valid3 && (sb_wait == SB_WAIT_MAX);
wire [1:0] arb_pick    = sb_deadline ? 2'd3 : rr_id;
wire       arb_new     = rr_valid | sb_deadline;
// A reserved request is served first: its row is already open, so it cannot be postponed behind
// a refresh (AutoRefresh needs every bank precharged). It is a slot the rotation already granted,
// so sb_wait is credited to it exactly as a normal accept would be.
wire       pnd_take    = (state == IDLE) && !nce && pnd_valid;
wire       arb_take    = (state == IDLE) && !nce && !pnd_valid &&
                         !(need_refresh && refresh_allowed) && arb_new;
wire [1:0] take_id     = pnd_take ? pnd_id : arb_pick;

// The pre-ACT latches `pnd_addr` at the reservation, so the ACT and the READ that follows use
// ONE row even if the request mux moves meanwhile: there is no row mismatch inside the take.
// The residual risk is that a port whose payload moved (port 0 carries two routes) is still
// credited, so assert the reserved port's presented address is unchanged at the take.
`ifdef VERILATOR
wire [26:0] pnd_live_addr = (pnd_id == 2'd0) ? addr0 : (pnd_id == 2'd1) ? addr1 :
                            (pnd_id == 2'd2) ? addr2 : addr3;
always @(posedge clk)
    if (resetn && pnd_take && (pnd_live_addr !== pnd_addr))
        $error("sdram: pre-ACT reservation taken with a moved payload: reserved=%h live=%h",
               pnd_addr, pnd_live_addr);

// THE GATHER REQUEST CONTRACT (second lines; the store buffer is the first). A gather is
// port 0's, is a write, carries 1..GATHER_K entries, and every entry shares entry 0's
// PHYSICAL row - {chip, bank, row} exactly as rc_base computes it below - because the
// session ACTs that row once and serves every entry's own column against it. The store
// buffer groups by that same key (pc9821_pegc_storebuf, sdram_size threaded to it), and a
// grouping bug that survives both would write the wrong row silently, so it is asserted
// here from the crossed payload rather than trusted.
/* verilator lint_off UNUSEDSIGNAL */   // ga[9:0] is the column; only the row key is checked here
function [15:0] gk_rowkey(input [26:0] ga);
    begin
        gk_rowkey = {((sdram_size == 2'd3) && ga[26]),
                     (sdram_size[1] ? ga[25:24] : ga[24:23]),
                     (sdram_size[1] ? ga[23:11] : ga[22:10])};
    end
endfunction
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */   // the loop counters vs the 4-bit burst count
always @(posedge clk) begin : gk_contract
    integer gi;
    /* verilator lint_off UNUSEDSIGNAL */   // lent's din/be are the entry's own payload; only its row key is checked here
    reg [62:0] lent;
    /* verilator lint_on UNUSEDSIGNAL */
    if (resetn && ready_pulse[0] && gath0) begin
        if (!wr0 || (burst_cnt0 == 4'd0) || (burst_cnt0 > GATHER_K[3:0]))
            $fatal(1, "sdram: gather request is wr0=%b with burst_cnt0=%0d (want a write of 1..%0d entries)",
                   wr0, burst_cnt0, GATHER_K);
        for (gi = 1; gi < GATHER_K; gi = gi + 1) begin
            if (gi < ((burst_cnt0 == 4'd0) ? 4'd1 : burst_cnt0)) begin
                lent = gath0_extra[(gi-1)*GENT_W +: GENT_W];
                if (gk_rowkey(lent[62:36]) !== gk_rowkey(addr0))
                    $fatal(1, "sdram: gather entry %0d is in row %h but entry 0 is in row %h -- one ACT cannot serve both",
                           gi, gk_rowkey(lent[62:36]), gk_rowkey(addr0));
            end
        end
    end
end
/* verilator lint_on WIDTHEXPAND */

// THE PAIR WRITE'S MASK CONTRACT. Port 0's two-word write (WRITE_BURST) drives DQM 00 on all four
// halves, so it writes every byte of both words and never reads be0. Its one caller sends only
// full dwords (pc9821_pegc_storebuf's pair_ok requires both entries' be == 4'hF); a pair with a
// partial be0 would overwrite the bytes it leaves out, so it is refused here rather than trusted.
always @(posedge clk)
    if (resetn && ready_pulse[0] && wr0 && !gath0 && (burst_cnt0 == 4'd2) && (be0 != 4'hF))
        $fatal(1, "sdram: port 0 two-word write with be0=%h; the pair path writes all four bytes of both words", be0);
`endif

always @(posedge clk) begin
    if (!resetn || !valid3) sb_wait <= 2'd0;
    else if (pnd_take || arb_take)
        sb_wait <= (take_id == 2'd3) ? 2'd0 :
                   ((sb_wait == SB_WAIT_MAX) ? SB_WAIT_MAX : sb_wait + 2'd1);
end

// Main FSM
/* verilator lint_off WIDTHEXPAND */   // the same minimum-width timing parameters
// The FSM is written as its NEXT state (*_n, combinational) and one register block: the
// output cells (OUT_DDIO, the parameter's note) register the next value of each pin themselves,
// so it must exist as a net. Every *_n defaults to its register (hold) at the block's top; the
// arms below assign exactly what the clocked form assigned, on the same cycle.
reg [12:0] a_n;
reg [26:0] addr_buf_n;
reg [3:0] be_buf_n;
reg [3:0] burst_buf_n;
reg burst_done_pulse_n;
reg busy_buf_n;
reg [3:0] cfg_cbr_n;
reg [2:0] cmd_n;
reg [4:0] cycle_n;
reg data_resp_pulse_n;
reg [31:0] din_buf_n;
reg [31:0] din_hi_buf_n;
reg [31:0] dout_word_n;
reg dq_oen_n;
reg [15:0] dq_out_n;
reg [1:0] dqm_a_n;
reg [3:0] gk_be_n [0:GATHER_MAX-1];
reg [8:0] gk_col_n [0:GATHER_MAX-1];
reg [31:0] gk_din_n [0:GATHER_MAX-1];
reg gk_map_d_n;
reg gk_padded_n;
reg rp_hold_n;
reg [31:0] gk_old_n [0:GATHER_MAX-1];
reg [5:0] gk_rc_n;
reg [5:0] gk_ri_n;
reg [3:0] gk_rmap_n [0:2*GATHER_MAX-1];
reg [5:0] gk_rtot_n;
reg [5:0] gk_wc_n;
reg [3:0] gk_wmap_n [0:2*GATHER_MAX-1];
reg [5:0] gk_wtot_n;
reg init_chip_n;
reg [26:0] pnd_addr_n;
reg [4:0] pnd_age_n;
reg [3:0] pnd_be_n;
reg [3:0] pnd_burst_n;
reg pnd_chip_n;
reg [31:0] pnd_din_n;
reg pnd_go_n;
reg [1:0] pnd_id_n;
reg pnd_large_n;
reg pnd_valid_n;
reg rc_acc_d_n;
reg rc_chip_buf_n;
reg [14:0] rc_next_buf_n;
reg rc_sz3_buf_n;
reg [4:0] rd_cas0_n;
reg [8:0] rd_col_base_n;
reg [4:0] rd_issued_n;
reg [15:0] rd_lo16_n;
reg [4:0] rd_received_n;
reg rd_row2_n;
reg [4:0] rd_seg_halfs_n;
reg [4:0] rd_total_halfs_n;
reg [3:0] ready_pulse_n;
reg [REFRESH_CNT_W-1:0] refresh_cnt_n;
reg req_chip_buf_n;
reg req_gath_buf_n;
reg [1:0] req_id_buf_n;
reg req_large_buf_n;
reg req_wr_buf_n;
reg [1:0] rmw_issued_n;
reg [31:0] rmw_old_data_n;
reg [1:0] rmw_read_halfs_n;
reg [1:0] rmw_received_n;
reg [1:0] rmw_total_reads_n;
reg [1:0] rr_ptr_n;
reg [1:0] sd_ba_n;
reg sd_ncs_n;
reg [3:0] state_n;
reg [1:0] wr_halfs_n;
reg wr_second_n;
reg [2:0] wr_seg_h_n;
reg wr_split_n;
`ifdef VERILATOR
reg [3:0] gk_rmap_chk_n [0:2*GATHER_MAX-1];
reg [5:0] gk_rtot_chk_n;
reg [3:0] gk_wmap_chk_n [0:2*GATHER_MAX-1];
reg [5:0] gk_wtot_chk_n;
reg [3:0] pb_be_chk_n;
reg [3:0] pb_burst_chk_n;
reg [31:0] pb_din_chk_n;
reg rc_chip_chk_n;
reg [14:0] rc_next_chk_n;
`endif

always @* begin
    automatic reg new_req;
    reg [1:0] req_id;
    reg [26:0] req_addr;
    reg [31:0] req_din;
    reg [3:0] req_be;
    reg req_wr;
    reg [3:0] req_burst;
    reg req_gath;              // the gather qualifier (port 0 only; asserted below)

    // hold: every next-state value starts as its register
    begin : fsm_hold
        integer hi;
        a_n = a;
        addr_buf_n = addr_buf;
        be_buf_n = be_buf;
        burst_buf_n = burst_buf;
        burst_done_pulse_n = burst_done_pulse;
        busy_buf_n = busy_buf;
        cfg_cbr_n = cfg_cbr;
        cmd_n = cmd;
        cycle_n = cycle;
        data_resp_pulse_n = data_resp_pulse;
        din_buf_n = din_buf;
        din_hi_buf_n = din_hi_buf;
        dout_word_n = dout_word;
        dq_oen_n = dq_oen;
        dq_out_n = dq_out;
        dqm_a_n = dqm_a;
        for (hi = 0; hi < GATHER_MAX; hi = hi + 1) gk_be_n[hi] = gk_be[hi];
        for (hi = 0; hi < GATHER_MAX; hi = hi + 1) gk_col_n[hi] = gk_col[hi];
        for (hi = 0; hi < GATHER_MAX; hi = hi + 1) gk_din_n[hi] = gk_din[hi];
        gk_map_d_n = gk_map_d;
        gk_padded_n = gk_padded;
        for (hi = 0; hi < GATHER_MAX; hi = hi + 1) gk_old_n[hi] = gk_old[hi];
        gk_rc_n = gk_rc;
        gk_ri_n = gk_ri;
        for (hi = 0; hi < 2*GATHER_MAX; hi = hi + 1) gk_rmap_n[hi] = gk_rmap[hi];
        gk_rtot_n = gk_rtot;
        gk_wc_n = gk_wc;
        for (hi = 0; hi < 2*GATHER_MAX; hi = hi + 1) gk_wmap_n[hi] = gk_wmap[hi];
        gk_wtot_n = gk_wtot;
        init_chip_n = init_chip;
        pnd_addr_n = pnd_addr;
        pnd_age_n = pnd_age;
        pnd_be_n = pnd_be;
        pnd_burst_n = pnd_burst;
        pnd_chip_n = pnd_chip;
        pnd_din_n = pnd_din;
        pnd_go_n = pnd_go;
        pnd_id_n = pnd_id;
        pnd_large_n = pnd_large;
        pnd_valid_n = pnd_valid;
        rc_acc_d_n = rc_acc_d;
        rc_chip_buf_n = rc_chip_buf;
        rc_next_buf_n = rc_next_buf;
        rc_sz3_buf_n = rc_sz3_buf;
        rd_cas0_n = rd_cas0;
        rd_col_base_n = rd_col_base;
        rd_issued_n = rd_issued;
        rd_lo16_n = rd_lo16;
        rd_received_n = rd_received;
        rd_row2_n = rd_row2;
        rd_seg_halfs_n = rd_seg_halfs;
        rd_total_halfs_n = rd_total_halfs;
        ready_pulse_n = ready_pulse;
        refresh_cnt_n = refresh_cnt;
        req_chip_buf_n = req_chip_buf;
        req_gath_buf_n = req_gath_buf;
        req_id_buf_n = req_id_buf;
        req_large_buf_n = req_large_buf;
        req_wr_buf_n = req_wr_buf;
        rmw_issued_n = rmw_issued;
        rmw_old_data_n = rmw_old_data;
        rmw_read_halfs_n = rmw_read_halfs;
        rmw_received_n = rmw_received;
        rmw_total_reads_n = rmw_total_reads;
        rr_ptr_n = rr_ptr;
        sd_ba_n = sd_ba;
        sd_ncs_n = sd_ncs;
        state_n = state;
        wr_halfs_n = wr_halfs;
        wr_second_n = wr_second;
        wr_seg_h_n = wr_seg_h;
        wr_split_n = wr_split;
`ifdef VERILATOR
        for (hi = 0; hi < 2*GATHER_MAX; hi = hi + 1) gk_rmap_chk_n[hi] = gk_rmap_chk[hi];
        gk_rtot_chk_n = gk_rtot_chk;
        for (hi = 0; hi < 2*GATHER_MAX; hi = hi + 1) gk_wmap_chk_n[hi] = gk_wmap_chk[hi];
        gk_wtot_chk_n = gk_wtot_chk;
        pb_be_chk_n = pb_be_chk;
        pb_burst_chk_n = pb_burst_chk;
        pb_din_chk_n = pb_din_chk;
        rc_chip_chk_n = rc_chip_chk;
        rc_next_chk_n = rc_next_chk;
`endif
    end

    // defaults each cycle
    cmd_n               = CMD_NOP;
    data_resp_pulse_n  = 1'b0;
    burst_done_pulse_n  = 1'b0;
    ready_pulse_n    = 4'b0000;
    rc_acc_d_n       = 1'b0;     // set by the two accept arms of IDLE below
    gk_map_d_n       = 1'b0;     // set by the gather accept below
    rp_hold_n        = 1'b0;     // set by a write exit that leaves exactly tDAL to an ACT

    // saturating cycle counter
    cycle_n = (cycle == 5'd31) ? cycle : (cycle + 5'd1);
    refresh_cnt_n = refresh_cnt + 1'b1;

    // Request arbiter: round-robin, one request accepted per turn, with the scanout's deadline
    // able to bring its owed slot forward (see arb_pick above)
    new_req = arb_new;
    req_id  = pnd_take ? pnd_id : arb_pick;
    case (req_id)
    2'd0: begin
        req_addr = addr0;
        req_din = din0;
        req_be = be0;
        req_wr = wr0;
        req_burst = burst_cnt0;
        req_gath = gath0;
    end
    2'd1: begin
        req_addr = addr1;
        req_din = din1;
        req_be = be1;
        req_wr = wr1;
        req_burst = burst_cnt1;
        req_gath = 1'b0;
    end
    2'd2: begin
        req_addr = addr2;
        req_din = din2;
        req_be = be2;
        req_wr = wr2;
        req_burst = burst_cnt2;
        req_gath = 1'b0;
    end
    default: begin
        req_addr = addr3;
        req_din = din3;
        req_be = be3;
        req_wr = wr3;
        req_burst = burst_cnt3;
        req_gath = 1'b0;
    end
    endcase;

    case (state)
    // Power-on wait -> CONFIG sequence
    INIT: begin
        if (cfg_now) begin
            state_n  = CONFIG;
            cycle_n  = 5'd0;
            cfg_cbr_n = 4'd0;
        end
        busy_buf_n = 1'b1;
        dq_oen_n   = 1'b1;     // tri-state DQ during init
    end

    CONFIG: begin
        sd_ncs_n = init_chip;
        // t=0: PRECHG ALL. The cfg_cbr gate keeps this arm single-shot: `cycle` re-bases
        // to 0 after every CBR below and would otherwise re-issue the precharge.
        if ((cycle == 5'd0) && (cfg_cbr == 4'd0)) begin
            cmd_n   = CMD_PreCharge;
            a_n[10] = 1'b1;                // precharge all
        end
        // EIGHT AutoRefresh (CBR) cycles. The AS4C32M16SB needs at least two (datasheet Rev 1.4,
        // Note 11 Power up Sequence: "A minimum of 2 Auto-Refresh dummy cycles"); eight is what
        // other SDR parts' power-up sequences ask for (the AS4C64M8SD's section 3.2: "A minimum
        // of eight Auto Refresh cycles (CBR) are also required"), and costs six tRC once at power-up.
        // They stay BEFORE the Mode Register Set, the same order this sequence always used. The
        // first lands tRP after PRECHARGE ALL and each of the rest tRC after its predecessor
        // (tRFC <= tRC, Table 16), matching the tRC-spaced pair this replaces.
        //
        // The 5-bit `cycle` saturates at 31 and cannot count T_RP + 8*T_RC + T_MRD (60 at
        // 100MHz), so instead of three fixed compare points the CBR slot re-bases `cycle`
        // after each refresh and cfg_cbr counts them off.
        if ((cfg_cbr < 4'd8) && (cycle == ((cfg_cbr == 4'd0) ? T_RP : T_RC))) begin
            cmd_n     = CMD_AutoRefresh;
            cfg_cbr_n = cfg_cbr + 4'd1;
            cycle_n   = 5'd0;
        end
        // t=T_RC after the 8th CBR: Set Mode Register
        if ((cfg_cbr == 4'd8) && (cycle == T_RC)) begin
            cmd_n     = CMD_SetModeReg;
            a_n[10:0] = MODE_REG;
        end
        // t=...+T_MRD: done with this chip select. BOTH are initialised, whatever sdram_size says:
        // the size is the HPS's report (hps_io's sdram_sz, from a UIO command), and whether it has
        // arrived by the end of the first chip's 200 us is a matter of Main_MiSTer's start-up
        // order. A second chip left without its PRECHARGE/REFRESH/MRS would run on an undefined
        // mode register (CAS latency, burst length) once the size arrives and addr[26] selects it.
        // On a one-chip module the second pass drives CS# high, which the chip ignores; it costs
        // one init sequence (T_RP + 8 T_RC + T_MRD clocks) once.
        if ((cfg_cbr == 4'd8) && (cycle == (T_RC+T_MRD))) begin
            if (!init_chip) begin
                init_chip_n = 1'b1;
                cfg_cbr_n = 4'd0;
                cycle_n = 5'd0;
            end else begin
                init_chip_n = 1'b0;
                sd_ncs_n = 1'b0;
                state_n = IDLE;
                busy_buf_n = 1'b0;
                refresh_cnt_n = 0;
            end
        end
    end

    IDLE: if (~nce) begin     // change state on when nce == 0
        busy_buf_n = 1'b0;
        if (pnd_take) begin
            // The reserved request's row is already open, so it skips the ACT stage: `cycle`
            // continues from the pre-ACT, keeping T_RCD measured from that ACT on the pins.
            automatic reg [8:0] pb_col0 = pnd_large ? pnd_addr[10:2] : {1'b0, pnd_addr[9:2]};
            automatic reg [3:0] pb_burst = (pnd_burst == 0) ? 4'd1 : pnd_burst;
            automatic reg [9:0] pb_left = (pnd_large ? 10'd512 : 10'd256) - {1'b0, pb_col0};
            // The next-row field for THIS reserved request (see rc_of) is formed in the next
            // cycle from the latches written here (rc_acc_d).
            addr_buf_n       = pnd_addr;
            din_buf_n        = pnd_din;
            din_hi_buf_n     = din0_hi;
            be_buf_n         = pnd_be;
            req_id_buf_n     = pnd_id;
            req_large_buf_n  = pnd_large;
            req_chip_buf_n   = pnd_chip;
            rc_acc_d_n       = 1'b1;
            rc_sz3_buf_n     = (sdram_size == 2'd3);
`ifdef VERILATOR
            rc_next_chk_n    = rc_of(pnd_addr, pnd_large);
            rc_chip_chk_n    = pnd_chip ^ ((sdram_size == 2'd3) && (rc_of(pnd_addr, pnd_large) == 15'd0));
`endif
            req_wr_buf_n     = 1'b0;
            burst_buf_n      = pnd_burst;
            ready_pulse_n[pnd_id] = 1'b1;
            rr_ptr_n         = pnd_id + 2'd1;   // priority passes to the next slot
            busy_buf_n       = 1'b1;
            rd_col_base_n    = pnd_large ? pnd_addr[10:2] : {1'b0, pnd_addr[9:2]};
            rd_total_halfs_n = {(pnd_burst == 0) ? 4'd1 : pnd_burst, 1'b0};
`ifdef VERILATOR
            // S2-j check: the take's live request mux (the earlier form the latches replaced),
            // asserted against the latches one cycle later in pnd_take_contract below.
            pb_burst_chk_n   = req_burst;
            pb_be_chk_n      = req_be;
            pb_din_chk_n     = req_din;
`endif
            // The reserved read's row split too:
            // the pre-ACT opened pnd_addr's row and the
            // take re-arms the segment counter from the SAME latch the ACT read arm uses, so a
            // crossing reserved burst splits exactly as an ordinary one does.
            rd_seg_halfs_n   = (pb_left >= {6'd0, pb_burst}) ? {pb_burst, 1'b0}
                                                            : (pb_left[3:0] << 1);
            rd_row2_n        = 1'b0;
            rd_issued_n      = 5'd0;
            rd_received_n    = 5'd0;
            cycle_n          = (pnd_age == 5'd31) ? pnd_age : (pnd_age + 5'd1);
            begin : take_cas0
                // The first CAS: T_RCD after the pre-ACT (plus RD_SHIFT2 for a two-half segment,
                // the tRAS guard), and never before the take's own next cycle.
                automatic reg [4:0] tk_c0 = {1'b0, T_RCD} + ((RD_GUARD && (((pb_left >= {6'd0, pb_burst})
                                                ? {pb_burst, 1'b0} : (pb_left[3:0] << 1)) == 5'd2))
                                                ? RD_SHIFT2[4:0] : 5'd0);
                automatic reg [4:0] tk_nx = (pnd_age == 5'd31) ? pnd_age : (pnd_age + 5'd1);
                rd_cas0_n = (tk_nx > tk_c0) ? tk_nx : tk_c0;
            end
            pnd_valid_n      = 1'b0;
            state_n          = READ;
        end else if (need_refresh && refresh_allowed) begin
            // Refresh takes priority over new requests to prevent starvation. Under rp_hold the
            // last write's precharge is one clock short of done: wait it out (nothing is accepted
            // either, so the refresh goes next cycle).
            if (!rp_hold) begin
                cmd_n         = CMD_AutoRefresh;
                sd_ncs_n   = 1'b0;
                refresh_cnt_n = 0;
                busy_buf_n    = 1'b1;
                cycle_n       = 5'd1;
                state_n       = REFRESH;
            end
        end else if (new_req) begin
            // Latch request and pulse accepted. The pin registers are NOT driven from the live
            // mux here: the ACT stage below does that from these latches.
            // The next-row field for THIS request (see rc_of) is formed in the next cycle
            // from the latches written here (rc_acc_d).
            addr_buf_n       = req_addr;
            din_buf_n        = req_din;
            din_hi_buf_n     = din0_hi;
            be_buf_n         = req_be;
            req_id_buf_n     = req_id;
            req_large_buf_n  = sdram_size[1];
            req_chip_buf_n   = (sdram_size == 2'd3) && req_addr[26];
            rc_acc_d_n       = 1'b1;
            rc_sz3_buf_n     = (sdram_size == 2'd3);
`ifdef VERILATOR
            rc_next_chk_n    = rc_of(req_addr, sdram_size[1]);
            rc_chip_chk_n    = ((sdram_size == 2'd3) && req_addr[26])
                            ^ ((sdram_size == 2'd3) && (rc_of(req_addr, sdram_size[1]) == 15'd0));
`endif
            req_wr_buf_n     = req_wr;
            req_gath_buf_n   = req_gath;
            burst_buf_n      = req_burst;
            // The gather session's entries latch HERE, at the accept: the requester may
            // move its payload the cycle after this ready pulse, and the session runs
            // long past it. Entry 0 is the ordinary request; entries 1.. come off
            // gath0_extra, each {addr[26:0], din[31:0], be[3:0]}.
            if (req_gath) begin : gk_latch
                integer li;
                /* verilator lint_off UNUSEDSIGNAL */   // lent's row bits feed the assertion above, not the latches
                reg [62:0] lent;
                /* verilator lint_on UNUSEDSIGNAL */
                for (li = 0; li < GATHER_K; li = li + 1) begin
                    if (li == 0) begin
                        // Entry 0 is PORT 0's: the arbiter's case sets req_gath = gath0 only for
                        // 2'd0 (and 1'b0 for ports 1-3, below), so req_gath true implies
                        // req_id == 0, hence req_addr/din/be == addr0/din0/be0. Reading the port
                        // directly takes the round-robin cone and the request mux off gk_col[0]/
                        // gk_din[0]/gk_be[0] (S2-g); the same register gets the same value.
                        gk_col_n[0] = addr0[10:2];
                        gk_din_n[0] = din0;
                        gk_be_n[0]  = be0;
                        gk_old_n[0] = 32'd0;
                    end else begin
                        // {addr[26:0], din[31:0], be[3:0]}: addr [62:36], din [35:4], be [3:0]
                        lent = gath0_extra[(li-1)*GENT_W +: GENT_W];
                        gk_col_n[li] = lent[46:38];        // addr[10:2]
                        gk_din_n[li] = lent[35:4];
                        gk_be_n[li]  = lent[3:0];
                        gk_old_n[li] = 32'd0;
                    end
                end
                gk_ri_n = 6'd0;
                gk_rc_n = 6'd0;
                gk_wc_n = 6'd0;

                // The slot maps and totals are formed in the NEXT cycle (gk_map_d, after the
                // state case) from the be masks and the entry count latched here.
                gk_map_d_n = 1'b1;
`ifdef VERILATOR
                // ... and the earlier accept-time form, kept as the check of that (gk_contract2).
                begin : gk_map_latch
                    integer mi, mh, mra, mwa;
                    reg [3:0] mbe_i, mbe_h, mn_ns;
                    mra = 0; mwa = 0;
                    for (mi = 0; mi < 2*GATHER_MAX; mi = mi + 1) begin
                        gk_rmap_chk_n[mi] = 4'd0;
                        gk_wmap_chk_n[mi] = 4'd0;
                    end
                    mn_ns = (req_burst == 4'd0) ? 4'd1 : req_burst;
                    for (mi = 0; mi < GATHER_K; mi = mi + 1) begin
                        if (mi == 0) mbe_i = req_be;
                        else         mbe_i = gath0_extra[(mi-1)*GENT_W +: 4];
                        for (mh = 0; mh < 2; mh = mh + 1) begin
                            mbe_h = mh[0] ? mbe_i[3:2] : mbe_i[1:0];
                            if ((mi < mn_ns) && (mbe_h != 2'b00)) begin
                                gk_wmap_chk_n[mwa] = {mi[2:0], mh[0]};
                                mwa = mwa + 1;
                                if (mbe_h != 2'b11) begin
                                    gk_rmap_chk_n[mra] = {mi[2:0], mh[0]};
                                    mra = mra + 1;
                                end
                            end
                        end
                    end
                    gk_rtot_chk_n = ADQM ? 6'd0 : mra[5:0];
                    gk_wtot_chk_n = mwa[5:0];
                    if (ADQM && (mwa < 2)) begin   // the padding gk_map_form adds
                        gk_wmap_chk_n[1] = (mwa == 1) ? {gk_wmap_chk_n[0][3:1], ~gk_wmap_chk_n[0][0]} : 4'b0001;
                        if (mwa == 0) gk_wmap_chk_n[0] = 4'b0000;
                        gk_wtot_chk_n = 6'd2;
                    end
                end
`endif
            end
            ready_pulse_n[req_id] = 1'b1;
            rr_ptr_n         = req_id + 2'd1;   // priority passes to the next slot
            busy_buf_n  = 1'b1;
            state_n     = ACT;
        end
    end

    // ACT to the selected bank/row, from the request latched in IDLE. This is the registered
    // address stage: SDRAM_A/SDRAM_BA/SDRAM_nCS
    // are driven from the
    // latches, so the arbiter -> address mux -> pin-register path loses a logic stage and the
    // pins gain one clk_sdram cycle. The scheduler counter is re-armed here, so T_RCD, T_DAL
    // and T_RC are counted from the ACT on the pins exactly as they were counted from IDLE.
    ACT: begin
        cmd_n       = CMD_BankActivate;
        sd_ncs_n = req_chip_buf;
        sd_ba_n  = req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
        {dqm_a_n, a_n}         = ax(req_large_buf ? addr_buf[23:11] : addr_buf[22:10]);
        cycle_n     = 5'd1;

        if (req_wr_buf) begin
            if (req_gath_buf) begin
                // G3 gather-RMW session: one ACT was just issued for every entry; the
                // half reads come next and the row stays open for the merged writes.
                state_n = GATH_RD;
            end else if (ef_wr_burst > 4'd1) begin
                // Port 0's opt-in two-word write: one ACT, both column writes, one precharge.
                // burst_cnt != 2 (every other caller) falls through to the arms below. A pair
                // starting in the row's last column cannot fit, and is written as one word per
                // row through WRITE_BURST_ACT.
                automatic reg [8:0] wcol  = req_large_buf ? addr_buf[10:2]
                                                          : {1'b0, addr_buf[9:2]};
                automatic reg [9:0] wleft = (req_large_buf ? 10'd512 : 10'd256)
                                            - {1'b0, wcol};
                automatic reg [2:0] wseg  = (wleft >= {6'd0, ef_wr_burst})
                                            ? ({1'b0, ef_wr_burst[1:0]} << 1) : 3'd2;
                wr_split_n  = (wleft < {6'd0, ef_wr_burst});
                wr_second_n = 1'b0;
                wr_seg_h_n  = wseg;
                state_n     = WRITE_BURST;
            end else if (ADQM) begin
                // MiSTer standard (JTFRAME's ADQM): the chip's DQM is wired to A[12:11], so a
                // partial store is ONE masked WRITE -- the mask rides a[12:11], with no read and
                // no re-activated merge write. docs/sdram.md, "DQM wiring".
                // BOTH halves are always written, a half no byte enable touches with DQM = 11
                // (it writes nothing). That keeps the auto-precharge on the second half, at
                // T_RCD+1, which is what meets tRAS (the guards' note: one half at T_RCD puts the
                // precharge 36 ns after the ACT at 90 MHz), and it is what makes a store with no
                // byte enabled at all close its row: with neither half written there was no WRITE,
                // so no auto-precharge, and the bank stayed open into the next ACT or refresh.
                // The exit does not move (it is T_RCD + T_DAL_I either way).
                wr_halfs_n = 2'b11;
                state_n    = WRITE;
            end else if (be_buf == 4'b0011) begin
                wr_halfs_n = 2'b01;
                state_n    = WRITE;
            end else if (be_buf == 4'b1100) begin
                wr_halfs_n = 2'b10;
                state_n    = WRITE;
            end else if (be_buf != 4'b1111) begin
                rmw_issued_n   = 2'd0;
                rmw_received_n = 2'd0;
                rmw_old_data_n = 32'd0;
                if (be_buf[1:0] != 2'b00 && be_buf[3:2] == 2'b00) begin
                    rmw_read_halfs_n  = 2'b01;
                    rmw_total_reads_n = 2'd1;
                    wr_halfs_n        = 2'b01;
                end else if (be_buf[3:2] != 2'b00 && be_buf[1:0] == 2'b00) begin
                    rmw_read_halfs_n  = 2'b10;
                    rmw_total_reads_n = 2'd1;
                    wr_halfs_n        = 2'b10;
                end else begin
                    rmw_read_halfs_n  = 2'b11;
                    rmw_total_reads_n = 2'd2;
                    wr_halfs_n        = 2'b11;
                end
                state_n        = RMW_READ;
            end else begin
                wr_halfs_n = 2'b11;
                state_n = WRITE;
            end
        end else begin
            automatic reg [3:0] eff_burst;
            automatic reg [8:0] col0;
            automatic reg [9:0] row_left;   // dwords from col0 to the end of its row (>= 1)
            // A 32MB chip has 256 dword columns; 64MB chips have 512.
            eff_burst       = (burst_buf == 0) ? 1 : burst_buf;
            col0            = req_large_buf ? addr_buf[10:2] : {1'b0, addr_buf[9:2]};
            row_left        = (req_large_buf ? 10'd512 : 10'd256) - col0;
            rd_col_base_n     = col0;
            rd_total_halfs_n  = {eff_burst,1'b0};     // *2
            // eff_burst <= 15 and a row holds >= 256 dwords, so a burst crosses at most ONE row
            // boundary: the first row takes what fits, the rest is a second ACT plus burst.
            rd_seg_halfs_n    = (row_left >= {6'd0, eff_burst}) ? {eff_burst,1'b0}
                                                              : (row_left[3:0] << 1);
            rd_row2_n         = 1'b0;
            rd_issued_n       = 5'd0;
            rd_received_n     = 5'd0;
            // A two-half segment's READs wait RD_SHIFT2 for tRAS (the guards' note; 0 below
            // ~107 MHz at -7, so the folded constant there).
            rd_cas0_n         = {1'b0, T_RCD} + ((RD_GUARD && (((row_left >= {6'd0, eff_burst})
                                    ? {eff_burst, 1'b0} : (row_left[3:0] << 1)) == 5'd2))
                                    ? RD_SHIFT2[4:0] : 5'd0);
            state_n           = READ;
        end
    end

    // Issue length-1 READ commands every cycle after T_RCD.
    // Each READ returns one 16-bit half. We compose 32-bit words from pairs.
    READ: begin
        // The pre-ACT's tRP guard, referenced to the last CAS. The row-split ACT
        // above waits for full data drain before its second ACT -- the bank's auto-precharge
        // only completes T_RP after the read data has finished -- and this guard must agree
        // with it. The reserved ACT is sampled pnd_go+1 = 2 cycles after this condition fires
        // and the last CAS is sampled at rd_cas0 + halfs = T_RCD + halfs after this read's
        // ACT, so `halfs + T_RP` left only T_RP+2-T_RCD between them: short by T_RCD-2 under
        // the precharge-at-READ-A reading of tRP (a violation outright at 125MHz), and short by
        // T_RCD+CAS-2 under the read-data-completion reading. Adding T_RCD+CAS-2 measures tRP
        // from the last data-out under EITHER reading and makes the two ACT paths agree.
        // Cycle cost: NONE at T_RCD <= 2 (the window still reaches the take-bound ACT and the
        // reserved read's CAS keeps its cycle count exactly); at T_RCD == 3 the safe window is
        // empty (no overlap ACT is legal there), so the reservation drops and a would-be
        // reserved follow-up read pays T_RCD more cycles -- unavoidable without relaxing tRP.
        // Where the tRAS guard can delay a segment's first CAS, the window is measured from the
        // CAS this read actually started at (rd_cas0) rather than T_RCD.
        automatic reg [5:0] rp_need = {1'b0, rd_total_halfs} + T_RP + CAS - 6'd2
                                    + (RD_GUARD ? {1'b0, rd_cas0} : {2'b0, T_RCD});
        automatic reg       rd_finish = (cycle >= (rd_cas0 + CAS + 2)) &&
                                        (rd_received < rd_issued) &&
                                        ((rd_received + 5'd1) == rd_total_halfs);
        // Issue CAS READ one per cycle once T_RCD reached (rd_cas0 where the tRAS guard can
        // delay a segment; the two are the same cycle wherever RD_GUARD is off)
        if ((RD_GUARD ? (cycle >= rd_cas0) : (cycle >= T_RCD)) && (rd_issued < rd_total_halfs)) begin
            if ((rd_issued == rd_seg_halfs) && !rd_row2) begin
                // The burst has run out of the row it started in. Drain it -- every issued half
                // has landed -- then open the next row and carry on in this same state, which is
                // the ACT the READ arm of ACT performs, from the same latches.
                if (rd_received == rd_issued) begin
                    cmd_n         = CMD_BankActivate;
                    sd_ncs_n   = rc_chip_buf;
                    sd_ba_n    = rc_next_buf[14:13];
                    {dqm_a_n, a_n}           = ax(rc_next_buf[12:0]);
                    rd_col_base_n = 9'd0;
                    rd_row2_n     = 1'b1;
                    // The second row's CAS timing is measured from `cycle == 1` again, so the data
                    // capture re-bases on T_RCD. A reserved (pre-ACT) read entered with rd_cas0 =
                    // pnd_age+1 > T_RCD, which would start this segment's capture late.
                    rd_cas0_n     = {1'b0, T_RCD} + ((RD_GUARD && ((rd_total_halfs - rd_seg_halfs) == 5'd2))
                                                    ? RD_SHIFT2[4:0] : 5'd0);
                    cycle_n       = 5'd1;
                end
            end else begin
                // Column (S4a): this segment's half-column, combinational from the latches so
                // the pin-address path carries no compare/shift/dw chain and adds no
                // feedback register (a register form hit the Quartus DTM fitter bug).
                // Segment 1: {rd_col_base,half} counts up from issued 0 -> {base,1'b0}+issued.
                // Segment 2 (rd_row2): columns restart at 0 in the row the split ACT opened,
                // so issued counts from rd_seg_halfs -> issued-rd_seg_halfs. rd_issued >= rd_seg_halfs
                // at a CAS is equivalent to rd_row2: the split drains before any later CAS issues.
                automatic reg [9:0] col16 = rd_row2
                    ? ({5'b0, rd_issued} - {5'b0, rd_seg_halfs})
                    : ({rd_col_base, 1'b0} + {5'b0, rd_issued});
                cmd_n      = CMD_Read;
                // The second segment lives in the row the split ACT opened, which is the NEXT
                // BANK's (and possibly the next chip's) after the F5 carry: its commands must
                // carry that bank/chip, not addr_buf's.
                sd_ncs_n = rd_row2 ? rc_chip_buf : req_chip_buf;
                sd_ba_n = rd_row2 ? rc_next_buf[14:13]
                                    : (req_large_buf ? addr_buf[25:24] : addr_buf[24:23]);
                // Auto-precharge on the last half of EACH segment: the first row must be closed
                // before the second ACT opens the next row (same bank).
                {dqm_a_n, a_n}         = ax(req_large_buf
                           ? {2'b00, ((rd_issued == rd_total_halfs-1) ||
                                      (rd_issued == (rd_seg_halfs-1))), col16}
                           : {2'b00, ((rd_issued == rd_total_halfs-1) ||
                                      (rd_issued == (rd_seg_halfs-1))), 1'b0, col16[8:0]});
                rd_issued_n = rd_issued + 5'd1;
            end
        end

        // Capture returning 16-bit data CAS+2 after the FIRST CAS (rd_cas0), +1 for the dq_r
        // stage, rather than after the ACT: a reserved read's CAS is issued after its T_RCD.
        if ((cycle >= (rd_cas0 + CAS + 2)) && (rd_received < rd_issued)) begin
            if (!rd_received[0]) begin
                rd_lo16_n = dq_r;                  // low half
            end else begin
                dout_word_n = {dq_r, rd_lo16};     // high half completes a 32-bit word
                data_resp_pulse_n = 1'b1;

                // If that was the last half in the burst, signal burst_done and go idle
                if (rd_received + 5'd1 == rd_total_halfs) begin
                    burst_done_pulse_n = 1'b1;
                    busy_buf_n = 1'b0;
                    state_n    = IDLE;
                end
            end
            rd_received_n = rd_received + 5'd1;
        end

        // Speculative pre-ACT. Every CAS is out, so the command bus is
        // free until the data drains; activate the next request's row now, if the arbiter has a
        // READ pending on ANOTHER port and both tRC (from this transaction's ACT) and tRP (from
        // its last CAS) leave room. Another port, because port 0 carries several routes (the CPU,
        // DMA, the PEGC store buffer) whose response spacing the subsystem's route queue is
        // sized for. `req_addr`/`req_wr` are the arbiter's pick this cycle, and the requesters
        // hold their request until ready, so the reservation cannot be taken from them.
        if (!rd_finish && !pnd_valid && !pnd_go && !nce && !need_refresh && arb_new && !req_wr &&
            (req_id != req_id_buf) &&
            (rd_issued >= rd_total_halfs) && (cycle >= T_RC) && ({1'b0, cycle} >= rp_need)) begin
            pnd_addr_n  = req_addr;
            pnd_id_n    = req_id;
            pnd_chip_n  = (sdram_size == 2'd3) && req_addr[26];
            pnd_large_n = sdram_size[1];
            pnd_burst_n = req_burst;
            pnd_be_n    = req_be;
            pnd_din_n   = req_din;
            pnd_go_n    = 1'b1;
        end
        if (pnd_go) begin
            cmd_n       = CMD_BankActivate;
            sd_ncs_n = pnd_chip;
            sd_ba_n  = pnd_large ? pnd_addr[25:24] : pnd_addr[24:23];
            {dqm_a_n, a_n}         = ax(pnd_large ? pnd_addr[23:11] : pnd_addr[22:10]);
            pnd_go_n    = 1'b0;
            pnd_valid_n = 1'b1;
            pnd_age_n   = 5'd1;
        end else if (pnd_valid) begin
            pnd_age_n = (pnd_age == 5'd31) ? pnd_age : (pnd_age + 5'd1);
        end
    end

    // Boards without DQM must read the original dword and merge bytes locally.
    RMW_READ: begin
        // The first READ's cycle: T_RCD, later by RD_SHIFT1/RD_SHIFT2 when the auto-precharged
        // last READ would begin its precharge inside tRAS (the guards' note).
        automatic reg [4:0] rmw_c0 = {1'b0, T_RCD} + ((rmw_total_reads == 2'd1) ? RD_SHIFT1[4:0]
                                                                                  : RD_SHIFT2[4:0]);
        if ((cycle >= rmw_c0) && (rmw_issued < rmw_total_reads)) begin
            automatic reg [9:0] col16;
            automatic reg       half_sel;
            half_sel = (rmw_read_halfs == 2'b10) ? 1'b1 :
                       (rmw_read_halfs == 2'b01) ? 1'b0 :
                       rmw_issued[0];
            cmd_n      = CMD_Read;
            sd_ncs_n = req_chip_buf;
            sd_ba_n = req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            col16    = {req_large_buf ? addr_buf[10:2] : {1'b0, addr_buf[9:2]}, half_sel};
            {dqm_a_n, a_n}        = ax(req_large_buf
                      ? {2'b00, (rmw_issued == rmw_total_reads-1), col16}
                      : {2'b00, (rmw_issued == rmw_total_reads-1), 1'b0, col16[8:0]});
            rmw_issued_n = rmw_issued + 2'd1;
        end

        if ((cycle >= (rmw_c0 + CAS + 2)) && (rmw_received < rmw_issued)) begin
            automatic reg       half_sel;
            automatic reg [31:0] old_word;
            half_sel = (rmw_read_halfs == 2'b10) ? 1'b1 :
                       (rmw_read_halfs == 2'b01) ? 1'b0 :
                       rmw_received[0];
            old_word = rmw_old_data;

            if (!half_sel) begin
                old_word[15:0] = dq_r;
            end else begin
                old_word[31:16] = dq_r;
            end

            rmw_old_data_n = old_word;

            if (rmw_received + 2'd1 == rmw_total_reads) begin
                din_buf_n = byte_merge(old_word, din_buf, be_buf);
                be_buf_n  = (wr_halfs == 2'b01) ? 4'b0011 :
                           (wr_halfs == 2'b10) ? 4'b1100 : 4'b1111;
                state_n   = RMW_ACT;
                cycle_n   = 5'd0;
            end
            rmw_received_n = rmw_received + 2'd1;
        end
    end

    // Re-open the row after the auto-precharged RMW read, then do a full-word write.
    RMW_ACT: begin
        if (cycle == 5'd0) begin
            cmd_n      = CMD_BankActivate;
            sd_ncs_n = req_chip_buf;
            sd_ba_n = req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            {dqm_a_n, a_n}        = ax(req_large_buf ? addr_buf[23:11] : addr_buf[22:10]);
            cycle_n    = 5'd1;
            state_n    = WRITE;
        end
    end

    // Write selected 16-bit halves. MiSTer SDRAM modules have no DQM, so
    // partial byte writes are converted to the smallest safe half-word write.
    WRITE: begin
        // The first write's cycle: T_RCD, except an ADQM=0 single-half write, whose one (auto-
        // precharged) half waits WR_SHIFT1 for tRAS (the guards' note). ADQM=1 always writes two.
        automatic reg [4:0] wr_c0 = (!ADQM && (wr_halfs != 2'b11)) ? (T_RCD + WR_SHIFT1[4:0])
                                                                    : {1'b0, T_RCD};
        // low half at wr_c0
        if (cycle == wr_c0 && wr_halfs[0]) begin
            cmd_n      = CMD_Write;
            sd_ncs_n = req_chip_buf;
            sd_ba_n = req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            // ADQM: A[12:11] carry the low half's byte mask (A12=UDQM, A11=LDQM, active high).
            // Every other command drives a[12:11]=00 (READ) or row bits (ACT); MRS keeps 00.
            {dqm_a_n, a_n}        = ax(req_large_buf
                      ? {(ADQM ? {~be_buf[1], ~be_buf[0]} : 2'b00), !wr_halfs[1]/*AP if final*/, addr_buf[10:2], 1'b0}
                      : {(ADQM ? {~be_buf[1], ~be_buf[0]} : 2'b00), !wr_halfs[1]/*AP if final*/, 1'b0, addr_buf[9:2], 1'b0});
            dq_out_n   = din_buf[15:0];
            dq_oen_n   = 1'b0;
        end

        // high half can immediately follow the low half; no idle bubble needed.
        if ((cycle == wr_c0 && !wr_halfs[0] && wr_halfs[1]) ||
            (cycle == (T_RCD+1) && wr_halfs == 2'b11)) begin
            cmd_n      = CMD_Write;
            sd_ncs_n = req_chip_buf;
            sd_ba_n = req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            {dqm_a_n, a_n}        = ax(req_large_buf
                      ? {(ADQM ? {~be_buf[3], ~be_buf[2]} : 2'b00), 1'b1/*AP*/, addr_buf[10:2], 1'b1}
                      : {(ADQM ? {~be_buf[3], ~be_buf[2]} : 2'b00), 1'b1/*AP*/, 1'b0, addr_buf[9:2], 1'b1});
            dq_out_n   = din_buf[31:16];
            dq_oen_n   = 1'b0;
        end

        if ((cycle == (wr_c0+1) && wr_halfs != 2'b11) ||
            (cycle == (T_RCD+2) && wr_halfs == 2'b11)) begin
            dq_oen_n = 1'b1;
        end

        // The auto-precharged write must return to IDLE late enough for tDAL = tWR + tRP before
        // the next ACT AND for tRC between this write's ACT and the NEXT transaction's ACT. Both
        // arms exit at T_RCD + T_DAL_I - EXIT_TRIM: untrimmed, one clock more than a two-half write
        // needs for tDAL to an ACT (which follows IDLE and the ACT stage); trimmed, exactly that,
        // with rp_hold keeping an AUTO REFRESH (issued from IDLE itself) a clock off. An ADQM=0
        // single half delayed past T_RCD+1 moves the exit with it.
        if (cycle == (((!ADQM && (wr_halfs != 2'b11) && (WR_SHIFT1 > 1))
                       ? (T_RCD + T_DAL_I + WR_SHIFT1[4:0] - 5'd1) : (T_RCD + T_DAL_I)) - EXIT_TRIM[4:0])) begin
            busy_buf_n = 1'b0;
            rp_hold_n  = (EXIT_TRIM != 0);
            state_n    = IDLE;
        end
    end

    // Port 0's opt-in two-word write (burst_cnt == 2, the only count that reaches here). One ACT
    // opens the row; both dwords are written at consecutive columns as four 16-bit WRITE commands,
    // one per cycle from T_RCD; auto-precharge rides the LAST half of each row segment. That is the
    // same write latency the single arm uses per word, and the burst's exit keeps the single arm's rule --
    // T_DAL_I after the last write -- so tDAL and tRC are unchanged. A pair the row cannot hold
    // whole is one word per row, four halves in all.
    WRITE_BURST: begin
        // cycle and T_RCD are both < 32 here, so the half index fits 5 bits with room to spare.
        /* verilator lint_off WIDTHTRUNC */
        automatic reg [4:0] h  = cycle - T_RCD;                 // half index 0..wr_seg_h-1
        automatic reg [4:0] hl = {2'b0, wr_seg_h};
        automatic reg wk = wr_second | h[1];     // dword of the PAIR whose half this is
        automatic reg [8:0] cb = wr_second ? 9'd0 : (req_large_buf ? addr_buf[10:2]
                                                                   : {1'b0, addr_buf[9:2]});
        automatic reg       last_half = (h == (hl - 5'd1));
        /* verilator lint_on WIDTHTRUNC */
        automatic reg [31:0] wdat;
        wdat = wk ? din_hi_buf : din_buf;

        // The COLUMN is the segment's own dword index (h[2:1]), not wk: the pair's second word is
        // column 0 of its row, so a split segment's address must restart there.
        if ((cycle >= T_RCD) && (h < hl)) begin
            cmd_n       = CMD_Write;
            // As in the READ arm: the pair's second segment writes the row its split ACT
            // opened -- the NEXT bank's/chip's after the row+1 carry.
            sd_ncs_n = wr_second ? rc_chip_buf : req_chip_buf;
            sd_ba_n  = wr_second ? rc_next_buf[14:13]
                                   : (req_large_buf ? addr_buf[25:24] : addr_buf[24:23]);
            {dqm_a_n, a_n}         = ax(req_large_buf
                       ? {2'b00, last_half, (cb + {7'd0, h[2:1]}), h[0]}
                       : {2'b00, last_half, 1'b0, (cb[7:0] + {6'd0, h[2:1]}), h[0]});
            dq_out_n    = h[0] ? wdat[31:16] : wdat[15:0];
            dq_oen_n    = 1'b0;
        end

        // The split's second ACT is issued from WRITE_BURST_ACT the clock after this, so that
        // exit keeps its full tDAL; only the final exit (to IDLE and the ACT stage) is trimmed.
        if (cycle == (T_RCD + hl + (T_DAL_I - 2) - (((EXIT_TRIM != 0) && !(wr_split && !wr_second)) ? 5'd1 : 5'd0))) begin
            if (wr_split && !wr_second) begin
                wr_second_n = 1'b1;
                cycle_n     = 5'd0;
                state_n     = WRITE_BURST_ACT;
            end else begin
                dq_oen_n   = 1'b1;
                busy_buf_n = 1'b0;
                rp_hold_n  = (EXIT_TRIM != 0);
                state_n    = IDLE;
            end
        end
    end

    // The second row of a split write pair.
    // Entered at the exit the whole burst would
    // have taken, so the ACT is one T_DAL_I after the first row's last WRITE -- exactly where the
    // next transaction's ACT would have been -- and the second row's writes follow T_RCD later.
    WRITE_BURST_ACT: begin
        if (cycle == 5'd0) begin
            cmd_n       = CMD_BankActivate;
            sd_ncs_n = rc_chip_buf;
            sd_ba_n  = rc_next_buf[14:13];
            {dqm_a_n, a_n}         = ax(rc_next_buf[12:0]);
            cycle_n     = 5'd1;
            state_n     = WRITE_BURST;
        end
    end

    REFRESH: begin
        // A 128 MB module is two chips with complementary CS, and EACH needs its own
        // AutoRefresh. Two REFRESH commands are separated by tRC exactly as two ACTs are,
        // and the CONFIG sequence above already spaces its own pair by T_RC
        // (cycle == T_RP + T_RC). This path issued the second one on the cycle after the
        // first, which is a tRC violation, and tRC is not a tolerance: a refresh inside
        // another refresh's tRC window is undefined behaviour. The exit moves out with it
        // so the next ACTIVATE still has T_RC after the second REFRESH.
        //
        // Coverage note: the refresh path was in NO test before this - every bench's
        // transactions complete inside the auto-refresh interval, so no bench had
        // ever seen a REFRESH command at all. tb_pc9821_sdram now drives one to happen.
        if ((cycle == T_RC) && (sdram_size == 2'd3)) begin
            cmd_n = CMD_AutoRefresh;
            sd_ncs_n = 1'b1;
        end
        if (cycle == ((sdram_size == 2'd3) ? (T_RC + T_RC) : T_RC)) begin
            sd_ncs_n = 1'b0;
            state_n    = IDLE;
            busy_buf_n = 1'b0;
        end
    end

    // The G3 gather-RMW session's half reads (the header). Every half any entry's be
    // touches with SOME but not ALL of its bytes is read once, back-to-back, length-1
    // CAS, and deliberately WITHOUT auto-precharge: the row stays open so the merged
    // writes below need no re-ACT (the single-RMW path's per-store re-open is what this
    // session exists to amortise). gk_rmap walks the slots in entry order.
    GATH_RD: begin
        if ((cycle >= T_RCD) && (gk_ri < gk_rtot)) begin : gk_issue
            automatic reg [3:0] rmap_v;
            automatic reg [8:0] gcol;
            automatic reg [9:0] col16;
            rmap_v = gk_rmap[gk_ri[3:0]];
            gcol   = gk_col[rmap_v[3:1]];
            col16  = {req_large_buf ? gcol : {1'b0, gcol[7:0]}, rmap_v[0]};
            cmd_n      = CMD_Read;
            sd_ncs_n = req_chip_buf;
            sd_ba_n = req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            {dqm_a_n, a_n}        = ax(req_large_buf
                      ? {2'b00, 1'b0, col16}
                      : {2'b00, 1'b0, 1'b0, col16[8:0]});
            gk_ri_n    = gk_ri + 6'd1;
        end
        // The writes start at gk_w0 (see its derivation): the whole stream is out when
        // every read was ISSUED and the first write may drive the bus.
        if ((gk_ri == gk_rtot) && (cycle >= (gk_w0 - 6'd1))) begin
            gk_wc_n = 6'd0;
            state_n = GATH_WR;
        end
    end

    // The merged half writes: one per touched half, to each entry's own column, in the
    // same slot order as the reads. Auto-precharge rides the LAST write (one precharge
    // for the whole session), and the exit keeps the write arm's own tDAL/tRC rule.
    GATH_WR: begin
        if (gk_wc < gk_wtot) begin : gk_wissue
            automatic reg [3:0] wmap_v;
            automatic reg [8:0] gcol;
            automatic reg [9:0] col16;
            wmap_v = gk_wmap[gk_wc[3:0]];
            gcol   = gk_col[wmap_v[3:1]];
            col16  = {req_large_buf ? gcol : {1'b0, gcol[7:0]}, wmap_v[0]};
            cmd_n       = CMD_Write;
            sd_ncs_n = req_chip_buf;
            sd_ba_n  = req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            // The fields come from the S1-a look-ahead flops (gk_la_*, formed one cycle
            // ahead from the same latched session state); col16/gk_gd_* are the live
            // forms they are checked against.
            {dqm_a_n, a_n}         = ax(req_large_buf
                       ? {(ADQM ? gk_la_mask : 2'b00), gk_la_last, gk_la_col16}
                       : {(ADQM ? gk_la_mask : 2'b00), gk_la_last, 1'b0, gk_la_col16[8:0]});
            dq_out_n    = ADQM ? gk_la_dat : gk_wdat;
`ifdef VERILATOR
            if (resetn && ((gk_la_col16 !== col16) || (gk_la_last !== (gk_wc == (gk_wtot - 6'd1))) ||
                           (ADQM && ((gk_la_dat !== gk_gd_dat) || (gk_la_mask !== gk_gd_mask)))))
                $fatal(1, "sdram: S1-a look-ahead slot %0d disagrees: col %h/%h last %b dat %h/%h mask %b/%b",
                       gk_wc, gk_la_col16, col16, gk_la_last, gk_la_dat, gk_gd_dat, gk_la_mask, gk_gd_mask);
`endif
            dq_oen_n    = 1'b0;
        end
        if (gk_wc == gk_wtot) dq_oen_n = 1'b1;
        // The exit leaves exactly tDAL after the last write to an ACT (two clocks later, through
        // IDLE and the ACT stage; EXIT_TRIM), and rp_hold keeps a refresh (issued from IDLE itself,
        // one clock earlier than an ACT) from starting before tDAL. A padded session's extra slot
        // is inside that count.
        if (gk_wc == (gk_wtot + T_DAL_I - 6'd2 - EXIT_TRIM[5:0])) begin
            busy_buf_n = 1'b0;
            rp_hold_n  = (EXIT_TRIM != 0);
            state_n    = IDLE;
        end
        gk_wc_n = gk_wc + 6'd1;
    end

    default: state_n = IDLE;
    endcase

    // The gather session's slot maps, one cycle after its accept, from its latches (S2-b): the
    // scan runs over gk_be[]/burst_buf, not over the accept's req_be/gath0_extra.
    if (gk_map_d) begin : gk_map_form
        integer mi, mh, mra, mwa;
        reg [3:0] mbe_i, mbe_h, mn_ns;
        mra = 0; mwa = 0;
        for (mi = 0; mi < 2*GATHER_MAX; mi = mi + 1) begin
            gk_rmap_n[mi] = 4'd0;
            gk_wmap_n[mi] = 4'd0;
        end
        mn_ns = (burst_buf == 4'd0) ? 4'd1 : burst_buf;
        for (mi = 0; mi < GATHER_K; mi = mi + 1) begin
            mbe_i = gk_be[mi];
            for (mh = 0; mh < 2; mh = mh + 1) begin
                mbe_h = mh[0] ? mbe_i[3:2] : mbe_i[1:0];
                if ((mi < mn_ns) && (mbe_h != 2'b00)) begin
                    gk_wmap_n[mwa] = {mi[2:0], mh[0]};
                    mwa = mwa + 1;
                    if (mbe_h != 2'b11) begin
                        gk_rmap_n[mra] = {mi[2:0], mh[0]};
                        mra = mra + 1;
                    end
                end
            end
        end
        gk_rtot_n = ADQM ? 6'd0 : mra[5:0];
        gk_wtot_n = mwa[5:0];
        // ADQM: a session with fewer than two touched halves is PADDED to two write slots, the
        // extra one a fully masked write (DQM = 11) to a half no entry touches, so the session's
        // auto-precharge rides the second slot - closing the row even when no byte is enabled at
        // all, and beginning the precharge tRAS after the ACT (the WRITE arm's note). One touched
        // half: its own entry's other half (whose enables are 00); none: entry 0's two halves.
        gk_padded_n = 1'b0;
        if (ADQM && (mwa < 2)) begin
            gk_wmap_n[1] = (mwa == 1) ? {gk_wmap_n[0][3:1], ~gk_wmap_n[0][0]} : 4'b0001;
            if (mwa == 0) gk_wmap_n[0] = 4'b0000;
            gk_wtot_n   = 6'd2;
            gk_padded_n = 1'b1;
        end
    end

    // The next-row field, one cycle after the accept, from its latches (see rc_of above).
    if (rc_acc_d) begin : rc_form
        automatic reg [14:0] rc_n = rc_of(addr_buf, req_large_buf);
        rc_next_buf_n = rc_n;
        rc_chip_buf_n = req_chip_buf ^ (rc_sz3_buf && (rc_n == 15'd0));
    end

    // The gather session's read capture runs across BOTH session states: write j needs
    // only capture j and both streams walk the same slot order, so the tail of the
    // capture overlaps the head of the writes (gk_w0 is derived so no write ever
    // reads its merge base before it lands).
    if (gk_on && (cycle >= (T_RCD + CAS + 2)) && (gk_rc < gk_ri)) begin : gk_capture
        automatic reg [3:0] rmap_v;
        automatic reg [31:0] od;
        rmap_v = gk_rmap[gk_rc[3:0]];
        od     = gk_old[rmap_v[3:1]];
        gk_old_n[rmap_v[3:1]] = rmap_v[0] ? {dq_r, od[15:0]} : {od[31:16], dq_r};
        gk_rc_n = gk_rc + 6'd1;
    end

    // Reset
    if (!resetn) begin
        state_n      = INIT;
        busy_buf_n   = 1'b1;
        dq_oen_n     = 1'b1;
        sd_ba_n   = 2'b00;
        sd_ncs_n  = 1'b0;
        {dqm_a_n, a_n}          = ax(13'd0);
        cmd_n        = CMD_NOP;

        cycle_n      = 5'd0;
        cfg_cbr_n    = 4'd0;
        refresh_cnt_n= {REFRESH_CNT_W{1'b0}};
        rmw_issued_n = 2'd0;
        rmw_received_n = 2'd0;
        rmw_total_reads_n = 2'd0;
        rmw_read_halfs_n = 2'b00;
        rmw_old_data_n = 32'd0;
        wr_halfs_n = 2'b11;
        wr_split_n = 1'b0;
        wr_second_n = 1'b0;
        wr_seg_h_n = 3'd0;
        req_gath_buf_n = 1'b0;
        gk_ri_n = 6'd0;
        gk_rc_n = 6'd0;
        gk_wc_n = 6'd0;
        req_large_buf_n = 1'b0;
        req_chip_buf_n = 1'b0;
        rc_next_buf_n  = 15'd0;
        rc_chip_buf_n  = 1'b0;
        rc_acc_d_n     = 1'b0;
        rc_sz3_buf_n   = 1'b0;
        gk_map_d_n     = 1'b0;
        gk_padded_n    = 1'b0;
        rp_hold_n      = 1'b0;
`ifdef VERILATOR
        rc_next_chk_n  = 15'd0;
        rc_chip_chk_n  = 1'b0;
`endif
        init_chip_n = 1'b0;
        pnd_valid_n = 1'b0;
        pnd_go_n    = 1'b0;
        pnd_id_n    = 2'd0;
        pnd_addr_n  = 27'd0;
        pnd_chip_n  = 1'b0;
        pnd_large_n = 1'b0;
        pnd_burst_n = 4'd0;
        pnd_be_n    = 4'd0;
        pnd_din_n   = 32'd0;
        pnd_age_n   = 5'd0;
`ifdef VERILATOR
        pb_burst_chk_n = 4'd0;
        pb_be_chk_n    = 4'd0;
        pb_din_chk_n   = 32'd0;
`endif

        ready_pulse_n = 4'b0000;
        rr_ptr_n      = 2'd0;

        rd_total_halfs_n = 5'd0;
        rd_seg_halfs_n   = 5'd0;
        rd_row2_n        = 1'b0;
        rd_issued_n      = 5'd0;
        rd_received_n    = 5'd0;
        rd_cas0_n        = 5'd0;

        data_resp_pulse_n = 1'b0;
        burst_done_pulse_n = 1'b0;
    end
end
/* verilator lint_on WIDTHEXPAND */

/* verilator lint_off PROCASSINIT */   // busy_buf/cmd/a/dqm_a/dq_oen's initialisers ARE their power-up
                                      // values (their declarations' notes); this block loads them after
always @(posedge clk) begin : fsm_reg
    integer ri;
    a <= a_n;
    addr_buf <= addr_buf_n;
    be_buf <= be_buf_n;
    burst_buf <= burst_buf_n;
    burst_done_pulse <= burst_done_pulse_n;
    busy_buf <= busy_buf_n;
    cfg_cbr <= cfg_cbr_n;
    cmd <= cmd_n;
    cycle <= cycle_n;
    data_resp_pulse <= data_resp_pulse_n;
    din_buf <= din_buf_n;
    din_hi_buf <= din_hi_buf_n;
    dout_word <= dout_word_n;
    dq_oen <= dq_oen_n;
    dq_out <= dq_out_n;
    dqm_a <= dqm_a_n;
    for (ri = 0; ri < GATHER_MAX; ri = ri + 1) gk_be[ri] <= gk_be_n[ri];
    for (ri = 0; ri < GATHER_MAX; ri = ri + 1) gk_col[ri] <= gk_col_n[ri];
    for (ri = 0; ri < GATHER_MAX; ri = ri + 1) gk_din[ri] <= gk_din_n[ri];
    gk_map_d <= gk_map_d_n;
    gk_padded <= gk_padded_n;
    rp_hold <= rp_hold_n;
    for (ri = 0; ri < GATHER_MAX; ri = ri + 1) gk_old[ri] <= gk_old_n[ri];
    gk_rc <= gk_rc_n;
    gk_ri <= gk_ri_n;
    for (ri = 0; ri < 2*GATHER_MAX; ri = ri + 1) gk_rmap[ri] <= gk_rmap_n[ri];
    gk_rtot <= gk_rtot_n;
    gk_wc <= gk_wc_n;
    for (ri = 0; ri < 2*GATHER_MAX; ri = ri + 1) gk_wmap[ri] <= gk_wmap_n[ri];
    gk_wtot <= gk_wtot_n;
    init_chip <= init_chip_n;
    pnd_addr <= pnd_addr_n;
    pnd_age <= pnd_age_n;
    pnd_be <= pnd_be_n;
    pnd_burst <= pnd_burst_n;
    pnd_chip <= pnd_chip_n;
    pnd_din <= pnd_din_n;
    pnd_go <= pnd_go_n;
    pnd_id <= pnd_id_n;
    pnd_large <= pnd_large_n;
    pnd_valid <= pnd_valid_n;
    rc_acc_d <= rc_acc_d_n;
    rc_chip_buf <= rc_chip_buf_n;
    rc_next_buf <= rc_next_buf_n;
    rc_sz3_buf <= rc_sz3_buf_n;
    rd_cas0 <= rd_cas0_n;
    rd_col_base <= rd_col_base_n;
    rd_issued <= rd_issued_n;
    rd_lo16 <= rd_lo16_n;
    rd_received <= rd_received_n;
    rd_row2 <= rd_row2_n;
    rd_seg_halfs <= rd_seg_halfs_n;
    rd_total_halfs <= rd_total_halfs_n;
    ready_pulse <= ready_pulse_n;
    refresh_cnt <= refresh_cnt_n;
    req_chip_buf <= req_chip_buf_n;
    req_gath_buf <= req_gath_buf_n;
    req_id_buf <= req_id_buf_n;
    req_large_buf <= req_large_buf_n;
    req_wr_buf <= req_wr_buf_n;
    rmw_issued <= rmw_issued_n;
    rmw_old_data <= rmw_old_data_n;
    rmw_read_halfs <= rmw_read_halfs_n;
    rmw_received <= rmw_received_n;
    rmw_total_reads <= rmw_total_reads_n;
    rr_ptr <= rr_ptr_n;
    sd_ba <= sd_ba_n;
    sd_ncs <= sd_ncs_n;
    state <= state_n;
    wr_halfs <= wr_halfs_n;
    wr_second <= wr_second_n;
    wr_seg_h <= wr_seg_h_n;
    wr_split <= wr_split_n;
`ifdef VERILATOR
    for (ri = 0; ri < 2*GATHER_MAX; ri = ri + 1) gk_rmap_chk[ri] <= gk_rmap_chk_n[ri];
    gk_rtot_chk <= gk_rtot_chk_n;
    for (ri = 0; ri < 2*GATHER_MAX; ri = ri + 1) gk_wmap_chk[ri] <= gk_wmap_chk_n[ri];
    gk_wtot_chk <= gk_wtot_chk_n;
    pb_be_chk <= pb_be_chk_n;
    pb_burst_chk <= pb_burst_chk_n;
    pb_din_chk <= pb_din_chk_n;
    rc_chip_chk <= rc_chip_chk_n;
    rc_next_chk <= rc_next_chk_n;
`endif
end
/* verilator lint_on PROCASSINIT */

// ------------------------------------------------------------------------------------------
// The output pins. Every SDRAM output is the IOE output register's value: the register a pin's
// value leaves from is the one in its I/O cell, clocked by clk, loaded with the next value (the
// *_n nets above), so each pin changes on the same clk edge as the register the FSM reads back.
// OUT_DDIO chooses how that register reaches the I/O cell (the parameter's note):
//  * 1: instantiated cells. Command/address/DQM/DQ data: altddio_out with datain_h == datain_l
//    (both halves are loaded on the RISING edge, cyclonev_ddio_out's DFFHI and DFFLO, and the
//    clock-phase mux picks between two equal values, so the pin is a single-rate register; the
//    falling-edge mux path carries no transition and the SDC cuts it). DQ output enable: one
//    dont_merge FABRIC register per pin (dq_oe_q), kept out of the I/O cell (build_profile.py
//    writes FAST_OUTPUT_ENABLE_REGISTER OFF for SDRAM_DQ[*] as the qsf's last such line); its
//    path to the pin is timed by the SDC's SDRAM output delays like the data. Neither I/O-cell
//    form works: driven by a cyclonev_ddio_oe atom the build was black on hardware (2026-10-22,
//    one fit; Intel's own Cyclone V DQ path, Quartus ip/altera/altdq_dqs2/
//    altdq_dqs2_acv_cyclonev.sv, has that instance commented out), and packed into the pins one
//    per pin (Intel's pattern; hardware-good, 2bb5d1fb) it still hit the DTM io_obuf crash
//    (one seed of 12). tools/check_sdram_pins.py fails a fit that is not this form.
//  * 0: the fabric registers drive the pins and the qsf's FAST_OUTPUT_REGISTER /
//    FAST_OUTPUT_ENABLE_REGISTER pack them (the fitter duplicates dq_oen into 16 OE registers).
// Power-up: NOP on the command pins (cmd's note), zero on the rest, DQ released (dq_oen).
// MiSTer SDRAM modules repurpose the DQM connector pins as the upper address bits, so the DQM
// pins carry dqm_a, the twin of a[12:11].
assign SDRAM_CKE = 1'b1;
generate if (OUT_DDIO) begin : g_out_ddio
    // Only the cells themselves differ between simulation and synthesis: the next values they
    // load and the pins they drive are wired here, once, for both.
    wire  [2:0] cmd_next = cmd_n;
    wire [17:0] ca_next  = {sd_ncs_n, sd_ba_n, a_n, dqm_a_n};
    wire  [2:0] cmd_pins;
    wire [17:0] ca_pins;
    wire [15:0] dq_pins;
    wire [15:0] oen_pins;   // 1 = Hi-Z
    // The DQ output enable: one fabric register per pin (the stage's note), the same clk edge as
    // the cells. dont_merge keeps the 16 apart so each can be placed beside its own pin.
    /* verilator lint_off PROCASSINIT */   // DQ released at power-up, as dq_oen
    (* dont_merge *) reg [15:0] dq_oe_q = 16'hFFFF;
    /* verilator lint_on PROCASSINIT */
    always @(posedge clk) dq_oe_q <= {16{dq_oen_n}};
    assign oen_pins = dq_oe_q;
    assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd_pins;
    assign {SDRAM_nCS, SDRAM_BA, SDRAM_A, SDRAM_DQM} = ca_pins;
    genvar oi;
    for (oi = 0; oi < 16; oi = oi + 1) begin : g_dq_pin
        assign SDRAM_DQ[oi] = oen_pins[oi] ? 1'bZ : dq_pins[oi];
    end
`ifdef VERILATOR
    // The cells' behaviour: each is its next value registered on the rising clk edge.
    /* verilator lint_off PROCASSINIT */   // the cells' power-up values (the stage's note)
    reg  [2:0] cmd_cell = 3'b111;
    reg [17:0] ca_cell  = 18'd0;
    reg [15:0] dq_cell  = 16'd0;
    always @(posedge clk) begin
        cmd_cell <= cmd_next;
        ca_cell  <= ca_next;
        dq_cell  <= dq_out_n;
    end
    /* verilator lint_on PROCASSINIT */
    assign cmd_pins = cmd_cell;
    assign ca_pins  = ca_cell;
    assign dq_pins  = dq_cell;
    // The pins are twins of the registers the FSM reads back: both load the same *_n on every
    // edge, so from the first edge on they are equal on every cycle.
    /* verilator lint_off PROCASSINIT */   // 0 until the first edge has loaded both sides
    reg cells_live = 1'b0;
    always @(posedge clk) cells_live <= 1'b1;
    /* verilator lint_on PROCASSINIT */
    always @(posedge clk)
        if (cells_live && ((cmd_pins !== cmd) || (ca_pins !== {sd_ncs, sd_ba, a, dqm_a}) ||
            (dq_pins !== dq_out) || (oen_pins !== {16{dq_oen}})))
            $fatal(1, "sdram: an output cell differs from its register (cmd %b/%b ca %h/%h dq %h/%h oen %h/%b)",
                   cmd_pins, cmd, ca_pins, {sd_ncs, sd_ba, a, dqm_a}, dq_pins, dq_out, oen_pins, dq_oen);
`else
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
        .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
        .power_up_high("ON"), .width(3)
    ) cmd_out (
        .datain_h(cmd_next), .datain_l(cmd_next), .outclock(clk), .dataout(cmd_pins),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
        .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
        .power_up_high("OFF"), .width(18)
    ) ca_out (
        .datain_h(ca_next), .datain_l(ca_next), .outclock(clk), .dataout(ca_pins),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
        .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
        .power_up_high("OFF"), .width(16)
    ) dq_out_cell (
        .datain_h(dq_out_n), .datain_l(dq_out_n), .outclock(clk), .dataout(dq_pins),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
`endif
end else begin : g_out_ff
    assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
    assign SDRAM_nCS = sd_ncs;
    assign SDRAM_BA  = sd_ba;
    assign SDRAM_A   = a;
    assign SDRAM_DQM = dqm_a;
    assign SDRAM_DQ  = dq_oen ? {16{1'bZ}} : dq_out;
end endgenerate

// Generate cfg_now pulse after initialization delay (normally 200us)
reg  [23:0]   rst_cnt;        // enough for 200us at ~65MHz
reg           rst_done, rst_done_p1;

/* verilator lint_off WIDTHEXPAND */   // the same minimum-width timing parameters
always @(posedge clk) begin
    rst_done_p1 <= rst_done;
    cfg_now     <= rst_done & ~rst_done_p1;     // rising edge

    if (rst_cnt != (FREQ/1000)*200/1000) begin  // count to 200us
        rst_cnt  <= rst_cnt + 24'd1;
        rst_done <= 1'b0;
    end else begin
        rst_done <= 1'b1;
    end

    if (!resetn) begin
        rst_cnt  <= 24'd0;
        rst_done <= 1'b0;
    end
end
/* verilator lint_on WIDTHEXPAND */

`ifdef VERILATOR
// S2-a's two facts (see rc_of): outside the cycle after an accept the next-row registers equal the
// accept-time form, and in that cycle nothing reads them (ACT, or the first READ cycle of a
// reserved take: rd_row2 = 0, nothing issued, a non-empty first segment, so neither the split ACT
// nor a second-segment command can fire).
// S2-b: outside the cycle after a gather accept the slot maps equal the accept-time form, and that
// cycle is ACT (no gather state reads them there).
always @(posedge clk) begin : gk_contract2
    integer ci;
    if (resetn && gk_map_d && (state != ACT))
        $fatal(1, "sdram: the cycle after a gather accept is state %0d, not ACT", state);
    if (resetn && !gk_map_d && req_gath_buf && ((state == GATH_RD) || (state == GATH_WR))) begin
        if ((gk_rtot != gk_rtot_chk) || (gk_wtot != gk_wtot_chk))
            $fatal(1, "sdram: gather totals %0d/%0d differ from the accept-time form %0d/%0d",
                   gk_rtot, gk_wtot, gk_rtot_chk, gk_wtot_chk);
        for (ci = 0; ci < 2*GATHER_MAX; ci = ci + 1)
            if ((gk_rmap[ci] != gk_rmap_chk[ci]) || (gk_wmap[ci] != gk_wmap_chk[ci]))
                $fatal(1, "sdram: gather slot %0d map %h/%h differs from the accept-time form %h/%h",
                       ci, gk_rmap[ci], gk_wmap[ci], gk_rmap_chk[ci], gk_wmap_chk[ci]);
    end
end

always @(posedge clk) begin : rc_contract
    if (resetn && !rc_acc_d && ((rc_next_buf != rc_next_chk) || (rc_chip_buf != rc_chip_chk)))
        $fatal(1, "sdram: rc_next_buf/rc_chip_buf %h/%b differ from the accept-time form %h/%b",
               rc_next_buf, rc_chip_buf, rc_next_chk, rc_chip_chk);
    if (resetn && rc_acc_d && !((state == ACT) ||
        ((state == READ) && !rd_row2 && (rd_issued == 5'd0) && (rd_seg_halfs != 5'd0))))
        $fatal(1, "sdram: the cycle after an accept is state %0d (rd_row2=%b issued=%0d seg=%0d) - a reader of rc_* could see the unformed value",
               state, rd_row2, rd_issued, rd_seg_halfs);
end

// S2-j: the reserved-take latches (burst_buf/be_buf/din_buf, written from the pnd_* reservation
// latches) equal the take's OWN live request mux, which is what the arm read before the cut. The
// requester holds the payload until ready, so this holds on every take; a take that latched any
// other port's field (e.g. burst_buf <= burst_cnt0) fails here.
always @(posedge clk) begin : pnd_take_contract
    pnd_take_d <= resetn && pnd_take;
    if (pnd_take_d && ((burst_buf !== pb_burst_chk) || (be_buf !== pb_be_chk) || (din_buf !== pb_din_chk)))
        $fatal(1, "sdram: reserved-take latches %0d/%h/%h differ from the take's live request %0d/%h/%h",
               burst_buf, be_buf, din_buf, pb_burst_chk, pb_be_chk, pb_din_chk);
end
`endif

endmodule
