// EGC (Enhanced Graphics Charger) engine for the PC-9821 core.
//
// Transforms a CPU access to the 0xA8000-0xBFFFF / 0xE0000-0xE7FFF window onto a source
// quad, ROP, mask, plane enables and a bit shifter, instead of a plain one-plane store.
// State names are NP2kai's (mem/memegc.c, io/egc.c). Modes the target software uses:
// 0x0000 WS_CPU; 0x1400 WS_PATREG|SHIFT_CPU; 0x3100 COMPAREREAD|WS_PATREG|RL_MEMREAD;
// 0x28F0 and 0x29F0 COMPAREREAD|WS_ROP|ROP 0xF0 (the second with RL_MEMREAD).
//
// The DESCENDING direction (sft bit 12) is IMPLEMENTED as the mirror of the ascending form:
// NP2kai's bytemask_d0/d1 (the bit-reverse of u0/u1) and its `(cur >> l) | (prev << r)`
// arithmetic, with the unit's byte order reversed.
//
// The source stream is consumed as NP2kai's egc.buf row buffer: the feed writes the unit's two
// source bytes at inptr and the produce reads at outptr, which trails it, so a moved shift emits
// the bytes fed a unit or two earlier. Each plane has its own ring, and the produce's four states
// read the COMMITTED entries, so no `rd` bypass is needed.

`default_nettype none

// The EGC sequencer's states, exported so a bench names them instead of a binary value.
// They are DENSE: S_IDLE = 0 and the rest count 1,2,3... with no hole.
/* verilator lint_off DECLFILENAME */  // the sequencer's state enum lives with the module it names
package pc9821_egc_pkg;
  typedef enum logic [3:0] {
    EGC_IDLE     = 4'd0,
    EGC_RD_RESP  = 4'd1,
    EGC_EVAL     = 4'd2,
    EGC_WR       = 4'd3,
    EGC_WR_ACC   = 4'd4,
    EGC_RESP2    = 4'd5,
    EGC_HOLD     = 4'd6,
    EGC_WR_B_ACC = 4'd7,
    EGC_FEED     = 4'd8,
    EGC_STEP_LO  = 4'd9,
    EGC_STEP_HI  = 4'd10,
    EGC_COMMIT   = 4'd11
  } egc_state_e;
endpackage
/* verilator lint_on DECLFILENAME */

module pc9821_egc (
    input wire clk,
    input wire reset,

    // Register file, latched by pc9821_iobus from ports 0x04A0-0x04AE.
    // These are the LIVE iobus latches; the engine copies them into `acc_*` at each access's
    // S_IDLE accept, because the store's ready is decoupled and a register
    // write can land while an op is still in flight.
  /* verilator lint_off UNUSEDSIGNAL */   // the EGC's registers are 16 bits on the machine but only some bits are defined and used:
  // reg_access[3:0] is the ROP, reg_fgbg carries fg/bg as two 4-bit planes, reg_ope[1:0] is
  // the op, reg_sft[2:0] and [7] the shift, reg_leng is 16-bit. The undefined bits stay
  // latched because the guest writes the whole word and pc9821_iobus latches it; they are
  // simply not decoded.
    input wire [15:0] reg_access,
    input wire [15:0] reg_fgbg,
    input wire [15:0] reg_ope,
    input wire [15:0] reg_fg,
    input wire [15:0] reg_mask,
    input wire [15:0] reg_bg,
    input wire [15:0] reg_sft,
    input wire [15:0] reg_leng,
    // One-cycle flag: 0x4AC/0x4AE was written, so the shifter is re-armed
    // (NP2kai egcshift(), mem/memegc.c:51-107).
    input wire        reg_shift_we,
  /* verilator lint_on UNUSEDSIGNAL */

    // The CPU's access, already known to be inside a plane window. cpu_offset is
    // the byte offset inside the plane (the window's address bits [14:0]),
    // cpu_plane which of the four windows was addressed, and cpu_page the access
    // page (port 0xA6).
    input wire        cpu_page,
    input wire [14:0] cpu_offset,
    input wire [1:0]  cpu_plane,
    input wire [31:0] cpu_din,
    input wire [3:0]  cpu_be,
    input wire        cpu_valid,
    input wire        cpu_write,
    output reg [31:0] cpu_dout,
    output reg        cpu_ready,
    output reg        cpu_resp_valid,

    // The D1 client port (declared in pc9821_gvram_arb.sv): the same four byte-lanes,
    // four per-plane byte enables and plane-offset addressing the GRCG and the
    // scanout use. One access
    // carries one byte of each plane at cl_addr's column; an EGC unit is a dword
    // of each plane, so a read is four columns and a write is up to four.
    output reg         cl_valid,
    input  wire        cl_ready,
    output reg         cl_write,
    output reg  [15:0] cl_addr,
    output wire [31:0] cl_wdata,
    // The zero-datum lane-skip's flags for cl_wdata (pc9821_gvram_arb's lane_datum0),
    // registered beside it: cl_datum0[k] says cl_wdata's byte k is 0x00. Always exactly
    // {cl_wdata[31:24]==0, cl_wdata[23:16]==0, cl_wdata[15:8]==0, cl_wdata[7:0]==0},
    // so the arb muxes 4-bit results instead of comparing 32-bit muxed write data.
    output wire [3:0]  cl_datum0,
    output reg  [3:0]  cl_wbe,
    // The multi-column request: cl_burst says ONE request covers
    // several consecutive columns. A WRITE carries its column pair in cl_wdata2, word 0 = the
    // lower column; a READ is the unit's enabled columns (cl_wbe) and the client answers one word
    // per cl_done. Every other access leaves cl_burst low and cl_wdata2 don't-care.
    output reg         cl_burst,
    output wire [63:0] cl_wdata2,
    input  wire [31:0] cl_rdata,
    input  wire        cl_done,

    // Telemetry: the sequencer away from S_IDLE, so pc9821_gvram can count the cycles
    // the EGC holds the CPU and the time a blit spends.
    output wire        dbg_busy,

    // Operation telemetry: one pulse per CPU command the EGC accepts and one per unit it
    // commits, so pc9821_perf_msg can report ET/EU beside EG and a capture reads EG/ET (cycles per
    // transaction) against EG/EU (cycles per unit) - the split between "many operations" and "long
    // operations" (whether the cost is in decoupling the EGC or in its per-unit burst/pass).
    output wire        dbg_egc_txn,
    output wire        dbg_egc_unit
);

  import pc9821_egc_pkg::*;

  // ---------------------------------------------------------------
  // The transaction's OWN register image, latched at the S_IDLE accept
  // ---------------------------------------------------------------
  // Reading the eight registers LIVE throughout the produce would be safe only if a store held
  // the CPU until its op drained. A store releases the CPU at the accept (a WRITE's
  // cpu_ready pulses in S_FEED), so a guest `out 0x4A0..0x4AE` can land while the produce still
  // runs and change the op - or, for 0x4AC/0x4AE, abort it. NP2kai's EGC op is one atomic memory
  // access, so it can never see that; the registers are therefore latched here, as
  // acc_off/acc_be/acc_din/acc_plane/acc_page already are, and every cone reads the latched copy.
  // The re-arm is applied at an engine boundary by `shifter_arm`/`shift_arm_pend`, so it is
  // neither mid-produce nor lost.
  //
  // OBSERVATION LEMMA (C3): the image keeps only the bits a cone decodes, packed at the offsets
  // below. Nothing else writes these registers (the reset arm and the S_IDLE accept are the only
  // writers), and every read of them is listed beside its declaration; a consumer of a dropped
  // bit is a Verilator SELRANGE error, and tools/check_egc_snapshot.py proves the packing equal
  // to the full-width image for every 16-bit guest write, checks the single-writer property, and
  // fails when a read appears outside the retained set. The `ifdef VERILATOR` fence at the end of
  // this file re-derives every consumer from a full-width shadow each cycle.
  reg [3:0]  acc_access;   // reg_access[3:0] - plane_en[3:0] (:154-157)
  reg [3:0]  acc_fgbg;     // {reg_fgbg[9:8], reg_fgbg[14:13]} - fgbg_sel, read_plane (:159-160)
  reg [13:0] acc_ope;      // reg_ope[13:0] - ope_cmprd/sftcpu/mode/pat_rd/pat_wr, ROP table (:182-201, :824)
  reg [15:0] acc_fg;
  reg [15:0] acc_mask;
  reg [15:0] acc_bg;
  reg [8:0]  acc_sft;      // {reg_sft[12], reg_sft[7:0]} - dir at [8], the bit addresses at [7:0] (:255-257, :1011, :1210-1211)
  reg [11:0] acc_leng;     // reg_leng[11:0] - the shifter arming length (:1212)

  // ---------------------------------------------------------------
  // Static register decode
  // ---------------------------------------------------------------
  wire        plane_en[0:3];
  assign plane_en[0] = !acc_access[0];   // NP2kai: active LOW (memegc.c:1157)
  assign plane_en[1] = !acc_access[1];
  assign plane_en[2] = !acc_access[2];
  assign plane_en[3] = !acc_access[3];

  wire [1:0]  fgbg_sel   = acc_fgbg[1:0];     // colour-register pattern source (reg_fgbg[14:13])
  wire [1:0]  read_plane = acc_fgbg[3:2];     // the plane a shifted read returns (reg_fgbg[9:8])
  // NP2kai's BYTE path feeds the shifter and returns egc_src in the DEFAULTS of its fgbg switch,
  // which 0x6000 falls into; only 0x2000 (bgc) and 0x4000 (fgc) bypass it (egc_opeb case 0x1000).
  // So the byte path's "no colour quad" test is 00 OR 11, not the 00 the pattern quads use.
  wire        byte_no_color = (fgbg_sel == 2'b00) || (fgbg_sel == 2'b11);
  // COMPAREREAD (OPE bit 13) is the colour-key compare, and it is UNCONDITIONAL on 0x4A2's
  // pattern source: the machine compares with P = PAT (00) exactly as it does with FG/BG, so
  // this bit is the whole gate. The PAT case WAS believed unmeasurable - every compare row has
  // had to select FG or BG to load the reference colour at all (v1.3 "FG/BG writes are performed
  // only after selecting FG/BG in port 04A2h", EGCWRITE.CSV) - but the read is separable from
  // that write gate, and three families measure it: `RD22_PATSEL` (PASS on the Xe10 with 4492,
  // the retained-FG mask, where a raw return would have to be 4CB3 - the value a core gating on
  // the colour source produces), plus the pattern source the CK00_*_MASK,
  // B08_CMP_* and RD10_RAMP_* families are actually driven with. That stimulus is witnessed by
  // the same capture run on a core with a non-comparing arm: those 48 rows all read back the
  // addressed PLANE word (5555, the ramp's B plane) there while the machine returns the mask, i.e.
  // that core took a non-comparing arm - and with bit 13 clear no mask can be produced at all, so
  // bit 13 is set and 0x4A2's bits 14-13 are 00. RD21 (`compare-reference-retained-FG-while-P-is-BG`)
  // independently fixes the reference as the retained FG for BOTH colour selections.
  // NP2kai has no compare branch here at all (mem/memegc.c:1170-1172 returns `mem[addr]`), and
  // MAME gates its compare on the selector (pc9801_v.cpp:866-874); the machine disagrees with
  // both and wins. See docs/probes/egc-conformance/ and the EGC compare report.
  wire        ope_cmprd  = acc_ope[13];       // COMPAREREAD (the colour-key compare)
  wire        ope_sftcpu = acc_ope[10];       // SHIFT_CPU
  wire [1:0]  ope_mode   = acc_ope[12:11];    // WS_CPU / WS_ROP / WS_PATREG
  wire        pat_rd     = (acc_ope[9:8] == 2'b01);   // RL_MEMREAD
  wire        pat_wr     = (acc_ope[9:8] == 2'b10);

  // The colour registers expand to a per-plane 16-bit quad, all ones or all
  // zeros: NP2kai maskword[value & 15] (io/egc.c:12-27).
  function [15:0] colour_plane(input [15:0] colour, input [1:0] p);
    begin
      colour_plane = colour[{2'b0, p}] ? 16'hFFFF : 16'h0000;
    end
  endfunction

  // A ROP code needs the destination exactly when its 8-entry truth table
  // depends on dst. acc_ope[7:0] is that table, indexed by {src,dst,pat} (the
  // same index the ROP select below reads), so compare each (src,pat) pair
  // across dst (index bit 1). Equivalent to NP2kai's opefn[] class decode
  // (mem/memegc.c:935-997) for all 256 codes.
  wire rop_needs_dst = |((acc_ope[7:0] ^ (acc_ope[7:0] >> 2)) & 8'h33);

  // ---------------------------------------------------------------
  // Shifter state (NP2kai egcshift + shiftinput_* + egcsftb_*_sub)
  // ---------------------------------------------------------------
  // The per-plane state the plane loop walks (the pattern register patreg[p] and the shifter's
  // output quad sdata[p], NP2kai's egc.patreg / egc_src) is kept as a RING that rotates one step
  // per loop cycle instead of a four-entry array behind 4:1 read muxes and per-plane write
  // enables. The loop steps plane pb = 0,1,2,3 in four consecutive cycles (pl = 1..4) and every
  // unit runs all four, so at loop cycle j the plane being written (pb = j) is ALWAYS slot 0 and
  // the plane stage A reads (pa = j+1) is always slot 1; after the fourth rotation the ring is
  // aligned again (slot p = plane p), which is the only time anything outside the loop looks at
  // it (the `sdata`/`patreg` views below). S_STEP_HI's stage A reads plane 0 before the first
  // rotation, i.e. slot 0.
  reg [15:0] pat_r0, pat_r1, pat_r2, pat_r3;
  reg [15:0] sd_r0, sd_r1, sd_r2, sd_r3;
  /* verilator lint_off UNUSEDSIGNAL */   // the aligned view tb_pc9821_egc peeks (sdata[0]); the RTL itself reads the ring slots
  wire [15:0] sdata  [0:3];   // aligned views (only meaningful outside the loop)
  assign sdata[0] = sd_r0;
  assign sdata[1] = sd_r1;
  assign sdata[2] = sd_r2;
  assign sdata[3] = sd_r3;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [15:0] srcmask;         // AND-mask for the unit just shifted
  // `remain` is loaded from the 12-bit length plus one (max 4096) and only decreases or
  // holds, so 13 bits hold it; `stack`'s feed adds at most 16 only when the old stack is
  // <= 16 (otherwise nothing) and a produce only holds or decreases, so its reachable
  // maximum is 32 and 6 bits hold it (research-res-egc: the shifter bookkeeping is
  // over-wide by 19 state bits).
  reg [12:0] remain;          // bits left before the shifter re-arms (max 4096)
  reg [5:0]  stack;           // bits buffered ahead of the output position (max 32)
  reg [3:0]  dstbit;          // destination bit address (sft bits 7:4)
  reg [3:0]  srcbit;          // source bit address (sft bits 3:0)
  // NP2kai's egc.buf row buffer and its two byte pointers (egc.inptr/egc.outptr), one ring per
  // plane. The feed writes the unit's two source bytes at inptr and the produce reads at outptr,
  // which trails it; a moved shift therefore carries in the bytes fed a unit or two earlier, and
  // a dstbit >= 8 step or a whole-byte source offset moves outptr relative to inptr by one. The
  // feed and the produce share no clock: `S_FEED` writes the ring and the produce's
  // window read is presented the next state, so the produce reads the COMMITTED entries.
  // `efunc`/`e_s8l`/`e_s8r` are NP2kai's egc.func / sft8bitl / sft8bitr (egcshift()).
  // The ring is block RAM, split by entry parity so the produce's four-entry read
  // window [base, base+3] fits the two-port M10K: `ebuf_e` holds the even entries (ring entry 2k
  // at word k) and `ebuf_o` the odd, each a 32-bit word carrying all four planes' byte at that
  // offset. `pc9821_dpram` (true dual port) gives each copy two read ports; the feed's one write
  // per copy shares one of them. The parity split also stops Quartus merging the two copies, which
  // would leave four read ports on one memory, over the M10K limit.
  reg [5:0]  inptr, outptr;
  wire [2:0] efunc   = sft_dir ? (sft_right ? 3'd5 : (sft_moved ? 3'd3 : 3'd1))
                               : (sft_right ? 3'd4 : (sft_moved ? 3'd2 : 3'd0));
  wire [3:0] e_s8l   = sft_right ? (sft_src8 - sft_dst8) : (8 - (sft_dst8 - sft_src8));
  wire [3:0] e_s8r   = sft_right ? (8 - (sft_src8 - sft_dst8)) : (sft_dst8 - sft_src8);

  reg [31:0] lastvram [0:3];  // the quad of the last backend read

  wire [2:0] sft_src8 = acc_sft[2:0];
  wire [2:0] sft_dst8 = acc_sft[6:4];   // the byte-unit feeder's 3-bit sub-byte shift
  wire       sft_dir  = acc_sft[8];    // the descending direction: the mirror (see the header)
  wire       sft_moved = (sft_src8 != sft_dst8);
  wire       sft_right = (sft_src8 > sft_dst8);

  // Plane geometry is not this module's business: a column address is
  // {page, plane_offset} and the plane identity is the byte-enable lane (D1).

  // ---------------------------------------------------------------
  // The shifter's byte transform
  // ---------------------------------------------------------------
  // bytemask_d0/d1 are bytemask_u0/u1 with every entry's bits REVERSED (0x80 <-> 0x01), which is
  // the whole of the descending direction's difference in the mask tables (NP2kai mem/memegc.c
  // :20-38 versus :40-54). Reversing the emitted 8 bits is the same table, so this is one
  // bit-reverse network instead of a second 64-entry case.
  function [7:0] bitrev8(input [7:0] v);
    integer k;
    begin
      for (k = 0; k < 8; k = k + 1) bitrev8[k] = v[7 - k];
    end
  endfunction

  // The mask tables, NP2kai's bytemask_u0/u1 (mem/memegc.c:26-38) as closed forms. mask_u0's
  // row is the start bit, its column remain-1, so it is `0xFF << (7 - start) >> (remain-1)`;
  // mask_u1 is its own one-row case. Only the ascending tables are needed (mask_step bit-reverses).
  function [7:0] mask_u0(input [5:0] idx);
    begin
      mask_u0 = (8'hFF << (3'd7 - idx[5:3])) >> idx[2:0];
    end
  endfunction

  function [7:0] mask_u1(input [2:0] idx);
    begin
      mask_u1 = 8'hFF << (3'd7 - idx);
    end
  endfunction

  // One output byte's mask and the remain/dstbit update: NP2kai's
  // egcsftb_upn_sub/upl_sub head (mem/memegc.c:109-137, :288-320). Returns
  // {mask, remain, dstbit}. `rm` is the 13-bit remain (max 4096).
  function [24:0] mask_step(input [3:0] db, input [12:0] rm);
    reg [7:0]  m;
    reg [12:0] rm_out;
    reg [3:0]  db_out;
    begin
      if (db >= 4'd8) begin
        m = 8'h00; rm_out = rm; db_out = db - 4'd8;
      end else if (db != 4'd0) begin
        if ({9'd0, db} + rm >= 13'd8) begin
          m = mask_u0({2'b0, db} + 6'd56);
          rm_out = rm - (13'd8 - {9'd0, db});
        end else begin
  /* verilator lint_off WIDTHEXPAND */   // mask_u0 takes a 6-bit index and the argument is computed 13 bits wide. It cannot
  /* verilator lint_off WIDTHTRUNC */
  // truncate: this branch is reached only when db + rm < 8 with db != 0, so the sum is at
  // most 7 + 5*8 = 47 < 64.
          m = mask_u0({2'b0, db} + ((rm - 13'd1) << 3)); rm_out = 13'd0;
        end
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on WIDTHTRUNC */
        db_out = 4'd0;
      end else if (rm >= 13'd8) begin
        m = 8'hFF; rm_out = rm - 13'd8; db_out = 4'd0;
      end else begin
        m = mask_u1(rm[2:0] - 3'd1); rm_out = 13'd0; db_out = 4'd0;
      end
      mask_step = {sft_dir ? bitrev8(m) : m, rm_out, db_out};
    end
  endfunction

  // ---------------------------------------------------------------
  // The operand's first byte lane: from the CPU's BYTE ENABLES, not the address
  // ---------------------------------------------------------------
  // z486's address output is 30 bits ("Physical address [31:2]", src/z486/z486.sv:78
  // `addr`) and pc9821_system forms the guest address as {z_addr, 2'b00}
  // (src/pc9821/core/pc9821_system.sv:647 and :1061, the `.cpu_addr` connections), so
  // every access reaches this module DWORD-ALIGNED and the operand's byte lane is
  // carried ONLY by cpu_be (src/z486/z486_pkg.sv:1169 `calc_be`). Deriving the lane
  // from cpu_offset[1:0] made it 0 for every access, so a 16-bit unit on lanes 2:3
  // (be = 1100) became a BYTE unit on lane 0.
  //
  // The walk descends from the lowest enabled lane, so the first unit starts there;
  // the sequencer's later units already take their lane from acc_be.
  function [1:0] first_lane(input [3:0] be);
    begin
      first_lane = be[0] ? 2'd0 :
                   be[1] ? 2'd1 :
                   be[2] ? 2'd2 :
                   be[3] ? 2'd3 : 2'd0;
    end
  endfunction

  // A 16-bit unit is formed where the enables cover both bytes of an EVEN lane
  // pair -- NP2kai's memegc_wr16/rd16 split a 32-bit access into low 16 at addr and
  // high 16 at addr+2, and an odd start falls back to two byte units. The 3-byte
  // unaligned-dword halves (be = 1110 / 0111) NEVER form a word unit: each is two
  // ODD memegc_wr16/rd16s (memegc.c:1421-1424 over :1397-1413), i.e. three byte
  // operations, and merging the even lane pair into one word unit diverges wherever
  // the bit-length re-arm falls between its two lanes.
  function word_unit(input [3:0] be, input [1:0] lane);
    begin
      word_unit = !lane[0] && (lane != 2'd3) && be[lane] && be[lane + 2'd1] &&
                  (be != 4'b1110) && (be != 4'b0111);
    end
  endfunction

  // The first column at or after `from` whose byte enable the access covers, or 4 when there is
  // none: the read pass fetches only the columns the CPU touches, not the dword's four.
  function [2:0] next_be_col(input [3:0] be, input [2:0] from);
    integer i;
    begin
      next_be_col = 3'd4;
      for (i = 3; i >= 0; i = i - 1)
        if (be[i] && (i[2:0] >= from)) next_be_col = i[2:0];
    end
  endfunction

  // The LAST column the access's byte enables cover, or 4 when there is none: the read burst's
  // highest column, which ends the S_RD_RESP drain.
  function [2:0] last_be_col(input [3:0] be);
    integer i;
    begin
      last_be_col = 3'd4;
      for (i = 0; i <= 3; i = i + 1)
        if (be[i]) last_be_col = i[2:0];
    end
  endfunction

  // The first ENABLED lane at or after `from`, or 4 when none remains. The unit walk advances
  // to this lane, not to `unit_lane + width`: a byte-enable set with a hole (0101, 1001, 1010,
  // 1011, 1101) has no NP2kai counterpart - its memegc_wr8/wr16/wr32 take an (address, size)
  // pair - but the EGC's own cpu_be port makes a set of enabled lanes a set of bytes the CPU
  // wrote, so every enabled lane after a hole must still be walked.
  function [3:0] next_set_lane(input [3:0] be, input [3:0] from);
    integer i;
    begin
      next_set_lane = 4'd4;
      for (i = 3; i >= 0; i = i - 1)
        if (be[i] && (i[3:0] >= from)) next_set_lane = i[3:0];
    end
  endfunction

  // The first unit's lane. The misaligned word (be = 0110) and the 3-byte beat
  // (be = 1110) with sft bit 12 set start at their HIGH byte - the direction term;
  // see `byte_walk_next`.
  wire [1:0] cpu_lane0 = (((cpu_be == 4'b0110) || (cpu_be == 4'b1110)) && reg_sft[12])
                           ? 2'd2 : first_lane(cpu_be);

  // ---------------------------------------------------------------
  // Bus sequencer state
  // ---------------------------------------------------------------
  // The read column's and the burst write's requests are presented from the state that decides
  // them, so the D1 accept lands in the first poll cycle instead of two dedicated setup states
  // one state per request, not three.
  // The produce: `S_FEED` writes the unit's source bytes into the M10K ring, `S_STEP_LO`/
  // `S_STEP_HI` each run ONE `mask_step`, and the plane loop (see THE PLANE-SERIAL DATAPATH)
  // steps the four planes and commits. Reads loop in `S_EVAL` (so the benches' read-evaluate
  // probe still holds) and writes in `S_COMMIT`. EGC_RESP2 is not entered (a read's ready
  // leaves from its last plane step); the package keeps the value so the numbering, and the
  // bench-only parallel reference that uses it, stay fixed.
  localparam egc_state_e S_IDLE = EGC_IDLE, S_RD_RESP = EGC_RD_RESP, S_EVAL = EGC_EVAL,
             S_WR = EGC_WR, S_WR_ACC = EGC_WR_ACC, S_HOLD = EGC_HOLD,
             S_WR_B_ACC = EGC_WR_B_ACC, S_FEED = EGC_FEED, S_STEP_LO = EGC_STEP_LO,
             S_STEP_HI = EGC_STEP_HI, S_COMMIT = EGC_COMMIT;

  pc9821_egc_pkg::egc_state_e state;
  // Telemetry: any state but S_IDLE is the EGC owning the CPU's transaction.
  assign dbg_busy = (state != S_IDLE);
  // `req_acc` is 1 once the request currently on the D1 port has been accepted. The write pass
  // POSTS its request -- it advances on the accept, not on the completion -- so a posted write's
  // `cl_done` can arrive in the cycle the next unit's read is accepted; a wait state must not take
  // that pulse for its own request. Cleared where a request is presented, set on its accept.
  reg        req_acc;
  // `plane_idx` indexes a COLUMN of the unit's dword, not a plane: the planes
  // travel as the four byte-enable lanes of one access.
  reg [1:0]  plane_idx;
  reg [3:0]  unit_lane;
  reg        unit_word;
  reg        unit_write;
  reg        unit_read;
  reg [31:0] acc_din;
  reg [3:0]  acc_be;
  /* verilator lint_off UNUSEDSIGNAL */   // acc_off[1:0] are not part of the address: the EGC operates on 32-bit dwords, so only
  // acc_off[14:2] is consulted.
  reg [14:0] acc_off;
  reg [1:0]  acc_plane;
  // The access PAGE, latched at the S_IDLE accept. `cl_addr` is {page, plane offset}, and
  // with the CPU released at the accept (a store's ready pulses there) z486 can move
  // `cpu_page` for its next access while the produce is still writing, so the page must be latched exactly as acc_off/acc_plane/acc_be/acc_din are.
  reg        acc_page;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [31:0] resp_data;
  // 1 once lastvram holds the CURRENT access's dword (all four columns read), 0 at
  // access start. A 32-bit access is two 16-bit units over the SAME dword, so the second
  // unit must not re-run the four-column read: it reuses lastvram.
  reg        dword_valid;

  wire [4:0]  unit_shift = unit_lane[1] ? 5'd16 : 5'd0;   // byte lane within the dword
  /* verilator lint_off UNUSEDSIGNAL */   // unit_off's low two bits are set from the lane and read nowhere: the EGC addresses
  // dwords, and every use takes the offset as {unit_off[14:2], 2'b00}.
  wire [14:0] unit_off   = {acc_off[14:2], unit_lane[1:0]};
  wire        unit_ext   = unit_lane[0];                  // NP2kai `ext = addr & 1`
  /* verilator lint_on UNUSEDSIGNAL */
  wire [14:0] unit_dword = {unit_off[14:2], 2'b00};

  // The read pass presents its covered columns as ONE burst
  // the run [first, last] the CPU's byte enables cover. `cpu_col0`/`acc_col0` are the burst's
  // first column (S_IDLE's read and S_STEP_HI's write fetch); `acc_col1` its last, which ends the
  // S_RD_RESP drain. The latched acc_be equals cpu_be once S_IDLE's read reaches S_RD_RESP, so
  // acc_col1 is the last column of either presentation.
  wire [2:0] cpu_col0 = next_be_col(cpu_be, 3'd0);
  wire [2:0] acc_col0 = next_be_col(acc_be, 3'd0);
  /* verilator lint_off UNUSEDSIGNAL */  // bit [2] is the "no enabled column" sentinel, truncated by acc_col1[1:0]
  wire [2:0] acc_col1_full = last_be_col(acc_be);
  wire [1:0] acc_col1 = acc_col1_full[1:0];
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------
  // THE PLANE-SERIAL DATAPATH
  // ---------------------------------------------------------------
  // The engine's per-plane work - the shifter's two output bytes, the ROP, the mask merge, the
  // pattern latch, the compare and the read pick - runs on ONE 16-bit plane datapath that steps
  // the four planes in turn, instead of four parallel copies. It is a two-stage plane pipeline:
  //   stage A (plane `pa`): the shifter's lo/hi output bytes for that plane, from the ring's
  //           registered window, into `st_lo`/`st_hi`;
  //   stage B (plane `pb`, one cycle later): that plane's egc_src assembly, pattern latch, ROP,
  //           merge and read pick, written into the plane's own state (sdata/patreg) and into
  //           the unit's COLUMN ACCUMULATORS (`wacc_lo`/`wacc_hi`: byte p of each is plane p).
  // Stage A of plane 0 runs in S_STEP_HI (where the window and both step masks first exist);
  // the loop state (S_EVAL for a read unit, S_COMMIT for a write unit) then steps `pl` 1..4:
  // pl = 1..3 runs stage A of plane pl and stage B of plane pl-1, pl = 4 runs stage B of plane 3
  // and COMMITS the unit (srcmask/stack/pointers, the read's response piece).
  //
  // ALWAYS FOUR STEPS, whatever 0x4A0 enables: the Xe10's EGC time is flat across 1-4 enabled
  // planes (docs/probes/EGCP.TXT, EGC3100SP/EGC28F0SP 677 ns net at 1, 2, 3 and 4 planes), so the
  // step count never depends on the plane mask.
  //
  // NOTHING OUTSIDE CAN TELL. The cross-plane results (the compare read's AND over the planes,
  // the source/pattern latches) accumulate across the steps and are exposed only at the unit's
  // commit, exactly where the parallel form exposed them; the write is presented from the
  // accumulators only after all four planes are in them, as the same column requests the
  // parallel form issued (one column = byte p of plane p for all four planes, written to the
  // four plane arrays in ONE clk_sys by pc9821_gvram_mem), so no client ever sees a column with
  // some planes written. The CPU's next access waits for S_IDLE as before, which is after the
  // whole write (tb_pc9821_egc_serial_equiv proves every write and read datum against the
  // parallel engine, tests/pc9821/pc9821_egc_par.sv).
  reg  [2:0]  pl;
  wire        in_loop   = (state == S_EVAL) || (state == S_COMMIT);
  wire        loop_last = in_loop && pl[2];
  wire [1:0]  pa        = (state == S_STEP_HI) ? 2'd0 : pl[1:0];
  wire        st_load   = (state == S_STEP_HI) || (in_loop && !pl[2]);
  wire [1:0]  pb        = pl[1:0] - 2'd1;         // pl = 1..4 -> plane 0..3
  reg  [7:0]  st_lo, st_hi;                       // stage A -> stage B
  reg  [31:0] wacc_lo, wacc_hi;                   // the unit's two write columns, byte p = plane p
  reg  [3:0]  wbe_lo, wbe_hi;                     // their per-plane write enables
  reg  [15:0] cmp_acc;                            // the compare's running AND over the planes
  reg  [15:0] rp_pick;                            // the read plane's response piece

  // The produce COMMITS in the loop's last step (S_EVAL for a read, S_COMMIT for a write).
  wire        produce_commit_step = loop_last;

  // The FEED needs every plane's source bytes at once (one ring word carries all four), so its
  // extracts stay four-wide; they are wiring and a lane select, not a datapath.
  wire [15:0] quad_word [0:3];
  wire [7:0]  quad_byte [0:3];
  /* verilator lint_off WIDTHTRUNC */   // CPU byte and dword extraction (this line and the generate loop below). unit_lane is the
  // byte lane in [0,3], so {unit_lane,3'b000} is at most 24 and the 5-bit extraction index
  // never wraps.
  wire [15:0] cpu_word = acc_din[unit_shift +: 16];
  wire [7:0]  cpu_byte = acc_din[{unit_lane, 3'b000} +: 8];   // lane in [0,3]

  // Quartus Prime 17.0.2 rejects a genvar declared in the for-initialiser
  // (Error 10170: syntax error near text "genvar", "genvar" is a reserved
  // keyword), so the one loop variable is declared here and reused by every
  // generate loop below. Behaviour is identical to `for (genvar gp = ...)`.
  genvar gp;

  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_extract
      assign quad_word[gp] = lastvram[gp][unit_shift +: 16];
      assign quad_byte[gp] = lastvram[gp][{unit_lane, 3'b000} +: 8];
    end
  endgenerate

  // Stage B's plane: its destination dword and the extracts the unit needs from it.
  wire [31:0] lv_b = lastvram[pb];
  wire [15:0] dq_w = lv_b[unit_shift +: 16];
  wire [7:0]  dq_b = lv_b[{unit_lane, 3'b000} +: 8];
  /* verilator lint_on WIDTHTRUNC */
  // The HIGH byte's old contents, at dword byte lane+1 (lane 3 never has one: a word unit starts
  // on an even lane, so the value there is a don't-care that the write enables never select).
  wire [7:0]  wold_hi = (unit_lane == 4'd0) ? lv_b[15:8] :
                        (unit_lane == 4'd1) ? lv_b[23:16] : lv_b[31:24];

  // ---------------------------------------------------------------
  // The shifter's feed and produce step for the current unit
  // ---------------------------------------------------------------
  // A READ with SHIFT_CPU clear feeds the shifter with the source quad and
  // produces. A WRITE produces when the mode drives the shifter from the CPU data. The three
  // NP2kai feeds differ: EGCOPE_SHIFTW2 (the 16-bit WS_PATREG case and the 16-bit WS_CPU default)
  // is UNCONDITIONAL; EGCOPE_SHIFTW (16-bit WS_ROP) and EGCOPE_SHIFTB (every byte case) are
  // guarded by SHIFT_CPU, and the byte WS_PATREG feed lives only in the switch's DEFAULT branch,
  // so the bgc/fgc colour quads never reach it (memegc.c egc_opeb/egc_opew).
  wire feed_from_cpu = unit_write &&
                       ((ope_mode == 2'b10 && (unit_word || (ope_sftcpu && byte_no_color))) ||
                        (ope_mode == 2'b01 && ope_sftcpu) ||
                        (ope_mode == 2'b00 && unit_word));
  wire feed_from_mem = unit_read && !ope_sftcpu;
  wire do_produce    = feed_from_cpu || feed_from_mem;

  wire [7:0] feed_lo [0:3];
  wire [7:0] feed_hi [0:3];
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_feed
      assign feed_lo[gp] = unit_write ? (unit_word ? cpu_word[7:0] : cpu_byte)
                                      : (unit_word ? quad_word[gp][7:0]
                                                   : quad_byte[gp]);
      assign feed_hi[gp] = unit_write ? cpu_word[15:8] : quad_word[gp][15:8];
    end
  endgenerate

  // ---------------------------------------------------------------
  // The buffer reads: NP2kai's egcsftb_*_sub data paths (mem/memegc.c:109-369)
  // ---------------------------------------------------------------
  // The feed writes the unit's source bytes at inptr (S_FEED) and the produce reads the window at
  // outptr the NEXT state (S_STEP_LO presents the address, S_STEP_HI onwards consumes it), so the
  // produce reads the COMMITTED entries and there is no `rd` bypass. The window address is a
  // function of the pre-commit pointers, so the RAM keeps returning the same window through the
  // whole plane loop (and through a write's destination fetch): stage A reads it at each plane.
  // The feed gate, NP2kai's `if (egc.stack <= 16)` in shiftinput_byte/incw/decw
  // (mem/memegc.c:590-637): when the stack is already past 16 the pointer, stack and
  // srcbit updates are skipped - but NOT the feed's ring write (EGCOPE_SHIFTB/W write
  // egc.inptr[] before shiftinput_* even runs, :639-706) and NOT the produce.
  wire       feed_gate   = (stack <= 6'd16);
  wire [5:0]  fd_lo = (unit_word && sft_dir) ? (inptr - 6'd1) : inptr;
  // `fd_hi[0]` is not read: the feed's write only needs the word index (`fd_hi[5:1]`) and which
  // copy to write, and fd_hi always has the opposite parity to fd_lo, so `fd_even` selects it.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [5:0]  fd_hi = (unit_word && sft_dir) ? inptr : (inptr + 6'd1);
  /* verilator lint_on UNUSEDSIGNAL */
  // The produce's read window [ebuf_base, ebuf_base+3]: every sub_data read (o-1..o+1 for o in
  // {outptr_feed, outptr_feed+mv1}) lands inside it. `ebuf_base[0]` selects the parity copy each
  // window byte lives in; the copies' registered outputs hold [m, m+1] and [m, m+2] (see ports).
  wire [5:0]  outptr_feed = outptr + ((feed_gate && unit_word && (srcbit >= 4'd8))
                                      ? (sft_dir ? -6'd1 : 6'd1) : 6'd0);
  wire [5:0]  ebuf_base = outptr_feed - (sft_dir ? 6'd2 : 6'd1);
  wire [4:0]  ebuf_m    = ebuf_base[5:1];
  wire [31:0] ebuf_e_q0, ebuf_e_q1, ebuf_o_q0, ebuf_o_q1;   // the two copies' read ports
  // Stage A's plane byte of each window word: the plane select comes BEFORE the window select,
  // so one byte-wide window and one sub_data pair serve whichever plane is stepping.
  wire [7:0]  win_e0 = ebuf_e_q0[{pa, 3'b000} +: 8];
  wire [7:0]  win_e1 = ebuf_e_q1[{pa, 3'b000} +: 8];
  wire [7:0]  win_o0 = ebuf_o_q0[{pa, 3'b000} +: 8];
  wire [7:0]  win_o1 = ebuf_o_q1[{pa, 3'b000} +: 8];
  function [7:0] rd(input [5:0] a);
    begin
      // window bytes: even base = E[m],O[m],E[m+1],O[m+1]; odd base = O[m],E[m+1],O[m+1],E[m+2]
      case (a - ebuf_base)
        6'd0:    rd = ebuf_base[0] ? win_o0 : win_e0;
        6'd1:    rd = ebuf_base[0] ? win_e0 : win_o0;
        6'd2:    rd = ebuf_base[0] ? win_o1 : win_e1;
        default: rd = ebuf_base[0] ? win_e1 : win_o1;
      endcase
    end
  endfunction

  // One sub call's data byte, at the pre-move outptr `o` with the pre-step `db`. The partial
  // (`db != 0`) branches emit ONE source byte and hold outptr; every other branch is the
  // two-byte combination. dnr/dnl move outptr FIRST, so they read `o-1` and `o` (egcsftb_dnr_sub
  // :267-296, egcsftb_dnl_sub :327-369).
  function [7:0] sub_data(input [5:0] o, input [3:0] db);
    reg [7:0] b0, b1, bm0, bm1;
    begin
      b0 = rd(o); b1 = rd(o + 6'd1);
      case (efunc)
        3'd0, 3'd1: sub_data = b0;                                                 // upn/dnn
        3'd2: sub_data = (db != 4'd0) ? (b0 >> e_s8r)
                                      : ((b0 << e_s8l) | (b1 >> e_s8r));           // upr
        3'd4: sub_data = (b0 << e_s8l) | (b1 >> e_s8r);                            // upl
        3'd3: begin bm0 = rd(o - 6'd1); bm1 = rd(o);
                    sub_data = (db != 4'd0) ? (b0 << e_s8r)
                                            : ((bm1 >> e_s8l) | (bm0 << e_s8r)); end
        default: begin bm0 = rd(o - 6'd1); bm1 = rd(o);
                    sub_data = (bm1 >> e_s8l) | (bm0 << e_s8r); end            // dnl
      endcase
    end
  endfunction

  // The same call's outptr move, as a modulo-64 delta: +1 for the up forms, -1 for the down forms
  // (6'h3F), 0 for a partial or an early return (a dstbit >= 8 step emits nothing and does not
  // move, memegc.c:109-119).
  function [5:0] sub_move(input [3:0] db);
    begin
      if (db >= 4'd8) sub_move = 6'd0;
      else case (efunc)
        3'd0, 3'd4: sub_move = 6'd1;                                        // upn/upl: ++
        3'd2:       sub_move = (db != 4'd0) ? 6'd0 : 6'd1;                  // upr: partial holds
        3'd1, 3'd5: sub_move = 6'h3F;                                       // dnn/dnl: --
        default:    sub_move = (db != 4'd0) ? 6'd0 : 6'h3F;                 // dnr
      endcase
    end
  endfunction

  // The feed first adds the unit's source bits to the stack (NP2kai
  // shiftinput_incw/shiftinput_byte: `stack += 16 - srcbit` for a word, `+= 8 -
  // srcbit` for a byte) and clears srcbit, all behind `if (egc.stack <= 16)`
  // (mem/memegc.c:590-637): a stack-gated feed leaves stack, srcbit AND the
  // pointers unchanged - it only writes the ring (see feed_gate/feed_commit).
  // Only the BYTE feed has an `srcbit >= 8` branch, where a source bit address of
  // 8..15 consumes a whole byte and adds nothing; the WORD feed adds 16 - srcbit
  // whatever srcbit is (:611-623 against :590-609). Then the produce step spends
  // them (`if (stack < (16 - dstbit)) { srcmask = 0; return; }`).
  wire [5:0] stack_add = unit_word ? (6'd16 - {2'd0, srcbit})
                                    : ((srcbit >= 4'd8) ? 6'd0
                                                        : (6'd8 - {2'd0, srcbit[2:0]}));
  wire [5:0] stack_fed = feed_gate ? (stack + stack_add) : stack;
  wire [5:0] stack_room = unit_word ? (6'd16 - {2'd0, dstbit})
                                    : (6'd8 - {2'd0, dstbit});
  wire        produce_gated = (stack_fed < stack_room);

  // ---- step_lo: ONE `mask_step`, computed in S_STEP_LO from the live shifter state. Its two
  // ---- outputs the next step needs (`pr_db_lo`, `pr_remain_1`) are LATCHED.
  wire [24:0] step_lo = mask_step(dstbit, remain);
  wire [7:0]  m_lo_c  = produce_gated ? 8'h00 : step_lo[24:17];
  wire [12:0] rem1_c  = produce_gated ? remain : step_lo[16:4];
  wire [3:0]  dblo_c  = produce_gated ? dstbit : step_lo[3:0];
  reg  [12:0] pr_remain_1;
  reg  [3:0]  pr_db_lo;

  // ---- step_hi: the second `mask_step`, from the LATCHED step_lo outputs, so neither state
  // ---- carries both mask_step cones. The second byte of a 16-bit unit, and only
  // while bit length is left: NP2kai `if (egc.remain) { sub(H); if (egc.remain) return; } else
  // srcmask._b[H] = 0;`. Its outputs the commit needs (`pr_db_n`, `pr_remain_n`) are latched in
  // S_STEP_HI.
  wire        produce_hi = !produce_gated && unit_word && (pr_remain_1 != 13'd0);
  wire [24:0] step_hi = mask_step(pr_db_lo, pr_remain_1);
  wire [7:0]  m_hi_c   = produce_hi ? step_hi[24:17] : 8'h00;
  wire [12:0] remn_c   = produce_hi ? step_hi[16:4] : pr_remain_1;
  wire [3:0]  dbn_c    = produce_hi ? step_hi[3:0] : pr_db_lo;
  reg  [12:0] pr_remain_n;
  reg  [3:0]  pr_db_n;

  // DESCENDING the first produce step is the HIGH lane's (egcsftw_dnl0 calls dnl_sub(H) then _L), so
  // its mask - m_lo, the step_lo result - lands high; when the bit length ends after that one step
  // the stale half is the LOW one (see prod_lo_ok). ASCENDING the low lane goes first.
  wire [15:0] srcmask_n   = (unit_word && sft_dir) ? {m_lo_c, m_hi_c} : {m_hi_c, m_lo_c};
  // egc.srcmask is a 16-BIT register and NP2kai writes only the produced lane of it: a byte feed
  // sets `srcmask._b[ext] = 0xff` and then that byte's mask, leaving the OTHER lane exactly as it
  // was (memegc.c shiftinput_byte + egcsftb_*0). `srcmask_n` puts the produced byte at lane 0
  // always, so a byte unit at an odd lane must place it at lane 1 and keep lane 0.
  wire [15:0] srcmask_u   = unit_word ? srcmask_n :
                            (unit_ext ? {m_lo_c, srcmask[7:0]} : {srcmask[15:8], m_lo_c});
  // The mask the unit's write uses: NP2kai's `egc.mask2.w &= egc.srcmask.w` reads the register
  // the feed commits at the same step, i.e. the POST-produce srcmask. Every consumer (S_STEP_HI's
  // fetch decision and stage B's merge) runs before the commit, where `srcmask_u` is stable (its
  // inputs `dstbit`/`remain`/`stack` move only at the commit, `pr_db_lo`/`pr_remain_1` only in
  // S_STEP_LO), so the post-produce value is `srcmask_u` for a producing unit and the held
  // register otherwise.
  wire [15:0] srcmask_eff = do_produce ? srcmask_u : srcmask;
  // Stage B reads it REGISTERED: S_STEP_HI latches it (both step masks exist there and nothing it
  // depends on moves until the commit), so the plane loop's merge starts at a register instead of
  // carrying the mask_step cone into the write accumulators.
  reg  [15:0] srcmask_q;
  // A gated unit still FEEDS: NP2kai's shiftinput_* adds to the stack unconditionally and only
  // the produce step is gated, so discarding the feed here left `stack` frozen whenever
  // srcbit > dstbit and the shifter never produced at all (it emitted an all-zero srcmask).
  wire [5:0] stack_n     = produce_gated ? stack_fed : (stack_fed - stack_room);
  // NP2kai updates srcbit only inside the feed's `if (egc.stack <= 16)` block
  // (mem/memegc.c:590-637): a stack-gated feed leaves it unchanged instead of
  // clearing it (or stepping a byte's 8..15 down by 8).
  wire [3:0]  srcbit_n    = !feed_gate ? srcbit
                            : unit_word ? 4'd0
                            : ((srcbit >= 4'd8) ? (srcbit - 4'd8) : 4'd0);
  // egcshift() re-runs when the bit length runs out (`if (!remain) egcshift()`). The bit length
  // after the second step is latched in S_STEP_HI.
  wire        shifter_rearm = !produce_gated && (pr_remain_n == 13'd0);

  // The two produce steps and the data each lane takes. ASCENDING the low byte's sub runs first
  // and the high's only if bit length is left (produce_hi); DESCENDING the HIGH byte's step runs
  // first whenever the unit is not gated, the low's only if left. Each step reads the buffer at
  // outptr plus the previous step's move (`sub_data`/`sub_move` above); a dstbit >= 8 first step
  // emits nothing and does not move, so the second step reads the same position. Both lanes'
  // operands exist from S_STEP_HI on (`pr_db_lo` is S_STEP_LO's latch), so stage A computes the
  // plane's two bytes together.
  //
  // A BYTE unit runs ONE sub call - NP2kai's egcsftb_*0 dispatches one egcsftb_*_sub - so its
  // byte takes the FIRST step's slot (outptr_feed, the pre-step dstbit) in BOTH directions; the
  // `outptr_feed + mv1` second-step slot is only the DESCENDING WORD's low lane:
  // egcsftb_dnn_sub reads outptr[0] before its move (:174-178) and egcsftb_dnl_sub moves first
  // and then reads (outptr[1], outptr[0]) = (pre, pre-1) (memegc.c:145-179, :331-369) - both take
  // the PRE-move outptr as their primary byte.
  wire db_early   = (dstbit >= 4'd8);
  wire prod_hi_ok = unit_word && (sft_dir ? (!produce_gated && !db_early) : produce_hi);
  wire prod_lo_ok = !produce_gated && (unit_word && sft_dir ? produce_hi : !db_early);
  wire [5:0] mv1 = sub_move(dstbit);
  wire [5:0] mv2 = produce_hi ? sub_move(pr_db_lo) : 6'd0;
  wire [5:0] mv_total = produce_gated ? 6'd0 : (mv1 + mv2);
  // The feed's pointer arithmetic: NP2kai's shiftinput_incw/decw move inptr +2 (word) or +1
  // (byte) in the feed's direction and move outptr one byte the same way when srcbit >= 8 (word
  // only); both are skipped when the stack is already past 16 (memegc.c:590-640), exactly as
  // the stack/srcbit updates above (`feed_gate`).
  wire [5:0] inptr_n     = sft_dir ? (inptr - (unit_word ? 6'd2 : 6'd1))
                                   : (inptr + (unit_word ? 6'd2 : 6'd1));
  wire  [5:0] lane_o_lo  = (unit_word && sft_dir) ? outptr_feed + mv1 : outptr_feed;
  wire  [3:0] lane_db_lo = (unit_word && sft_dir) ? pr_db_lo : dstbit;
  wire  [5:0] lane_o_hi  = sft_dir ? outptr_feed : outptr_feed + mv1;
  wire  [3:0] lane_db_hi = sft_dir ? dstbit : pr_db_lo;
  // Stage A. A lane that does not produce keeps the plane's held egc_src byte (the ok-mux
  // fallbacks): the read response returns it and the assembly writes it back unchanged.
  wire [15:0] sd_a     = (state == S_STEP_HI) ? sd_r0 : sd_r1;   // plane pa: slot 0 before the first rotation, slot 1 after
  wire [7:0]  prod_lo  = prod_lo_ok ? sub_data(lane_o_lo, lane_db_lo)
                                    : (unit_ext ? sd_a[15:8] : sd_a[7:0]);
  wire [7:0]  prod_hi  = prod_hi_ok ? sub_data(lane_o_hi, lane_db_hi) : sd_a[15:8];

  // ---------------------------------------------------------------
  // Stage B: the plane's egc_src, pattern, ROP, merge and read pick
  // ---------------------------------------------------------------
  // A unit that FEEDS nothing (or whose produce is gated) leaves egc_src alone: NP2kai's byte
  // WS_PATREG default returns egc_src, and with SHIFT_CPU clear (or a colour quad) no
  // EGCOPE_SHIFTB ran, so the byte the write stores - and the byte a read returns - is the HELD
  // sdata, not a produce the gate never committed.
  wire        held_src = produce_gated || !do_produce;
  wire [15:0] sd_b  = sd_r0;                       // plane pb is always slot 0
  wire [15:0] sdn_b = unit_word ? {st_hi, st_lo} :
                      unit_ext  ? {st_lo, sd_b[7:0]} : {sd_b[15:8], st_lo};
  wire [15:0] src_b = held_src ? sd_b : sdn_b;
  // RL_MEMWRITE latches the pattern register from the destination BEFORE the ROP runs
  // (mem/memegc.c:1337-1343 `egc.patreg.w[p] = ...; data = egc_opew(...)`), so the ROP's pattern
  // operand is the post-latch value. Which planes latch is the MACHINE's split: a COMPAREREAD
  // (OPE bit 13) read captures ALL FOUR planes from ONE read, a normal RL_MEMREAD read only the
  // SELECTED PAT plane, and a PLOAD_W write all four. EGCREAD.CSV RD17_P_*
  // (compare-plus-pload-captured-source) reports four DIFFERENT plane values after a compare
  // read - 35DF D010 67D9 4912 - where RD02_PAT_S0..S3 (normal-pload-read-updates-selected-PAT-
  // only) leaves the three unselected planes holding their previous values; B05_PLOAD_READ is the
  // same rule from four normal reads; W10_PLOADW_CAPTURE (EGCWRITE.CSV) is the write's. README.TXT
  // states the read split in words: "Normal PLOAD_R loads the selected PAT plane only.  Four-plane
  // PAT setup uses four selected reads.  Compare+PLOAD_R is tested separately."
  //
  // The games issue the compare half: TH01's egc_copy_rect_1_to_0_16
  // (rec98/th01/hardware/egcrect.cpp:23 (tmp = egc_chunk(vo))) and TH04/TH05's tiles_render_all
  // (rec98/th04/main/tile/render_a.asm:21 (ax, es:[si])) do ONE read and ONE write per word under
  // egc_setup_copy()'s 0x3100 (COMPAREREAD|WS_PATREG|RL_MEMREAD, egc_impl.hpp:4-12), so a
  // selected-plane-only capture would leave three of the destination's four planes holding
  // whatever the register last held (tb_pc9821_egc section 1b is the fail-first for it).
  wire        lat_b = (unit_write && pat_wr) ||
                      (unit_read && pat_rd && (ope_cmprd || (pb == read_plane)));
  wire [15:0] pr_b  = pat_r0;
  wire [15:0] patreg_new = !lat_b    ? pr_b :
                           unit_word ? dq_w :
                           unit_ext  ? {dq_b, pr_b[7:0]} : {pr_b[15:8], dq_b};
  wire [15:0] fgc_b = colour_plane(acc_fg, pb);
  wire [15:0] bgc_b = colour_plane(acc_bg, pb);
  wire [15:0] pat_b = (fgbg_sel == 2'b01) ? bgc_b :
                      (fgbg_sel == 2'b10) ? fgc_b :
                      (fgbg_sel == 2'b11) ? (pb[1] ? bgc_b : fgc_b) :
                      (pat_rd ? src_b : patreg_new);
  wire [15:0] patreg_data_b = (fgbg_sel == 2'b01) ? bgc_b :
                              (fgbg_sel == 2'b10) ? fgc_b : patreg_new;

  // The ROP result: NP2kai's opefn[] table (mem/memegc.c:935-997, with the per-class bodies at
  // :709-960) is the 8-entry ternary truth table of (pat, src, dst) held in acc_ope[7:0] itself
  // -- bit {src,dst,pat} of the code is the function's value for that triple. Each output bit is
  // one 8:1 select over that table.
  wire [15:0] rop_b;
  genvar gb;
  generate
    for (gb = 0; gb < 16; gb = gb + 1) begin : g_rop_bit
      assign rop_b[gb] = acc_ope[{1'b0, src_b[gb], dq_w[gb], pat_b[gb]}];
    end
  endgenerate

  // Word path (NP2kai egc_opew), per mode, and the plane-independent masks.
  wire [15:0] mask2_w = acc_mask & ((state == S_STEP_HI) ? srcmask_eff : srcmask_q);
  wire [15:0] word_data_b = (ope_mode == 2'b10) ? patreg_data_b :
                            (ope_mode == 2'b01) ? rop_b : cpu_word;
  // Byte path (NP2kai egc_opeb). Note the WS_PATREG default branch returns the
  // shifter output and ANDs srcmask, where the 16-bit path returns the pattern
  // register; and the WS_CPU byte path does not AND srcmask at all.
  wire [7:0] mask_b_sft = mask2_w[8*{2'b0, unit_ext} +: 8];
  wire [7:0] mask_b_reg = acc_mask[8*{2'b0, unit_ext} +: 8];
  wire [7:0] byte_data_b =
      (ope_mode == 2'b01) ? (unit_ext ? rop_b[15:8] : rop_b[7:0]) :
      (ope_mode == 2'b10) ? ((fgbg_sel == 2'b01) ? bgc_b[7:0] :
                             (fgbg_sel == 2'b10) ? fgc_b[7:0] :
                             (unit_ext ? src_b[15:8] : src_b[7:0])) :
      cpu_byte;
  // The colour-quad byte cases return BEFORE mask2 &= srcmask (memegc.c egc_opeb case 0x1000),
  // and 0x6000 takes the default, so only 0x2000/0x4000 keep the plain mask register.
  wire [7:0] byte_mask =
      (ope_mode == 2'b01) ? mask_b_sft :
      (ope_mode == 2'b10) ? (byte_no_color ? mask_b_sft : mask_b_reg) :
      mask_b_reg;
  wire [15:0] wmask_w  = unit_word ? mask2_w : {2{byte_mask}};
  wire [7:0]  wmask_lo = wmask_w[7:0];
  wire [7:0]  wmask_hi = unit_word ? wmask_w[15:8] : 8'h00;
  wire [15:0] wdata_b  = unit_word ? word_data_b : {2{byte_data_b}};
  // Byte-by-byte merge: the reference does `mem &= ~mask2; mem |= data & mask2` on every enabled
  // plane, which for the byte enables below is the same write.
  wire [7:0]  wr_byte_lo = (wdata_b[7:0]  & wmask_lo) | (dq_b    & ~wmask_lo);
  wire [7:0]  wr_byte_hi = (wdata_b[15:8] & wmask_hi) | (wold_hi & ~wmask_hi);
  wire        wr_lane_lo = plane_en[pb] && (wmask_lo != 8'h00);
  wire        wr_lane_hi = plane_en[pb] && unit_word && (wmask_hi != 8'h00);

  // The read pass is skipped whenever the transform does not need the old contents. The mask is
  // the same for every plane, so "some enabled plane needs a merge" is one term.
  wire any_plane_en = plane_en[0] || plane_en[1] || plane_en[2] || plane_en[3];
  wire unit_needs_rmw = any_plane_en &&
                        ((wmask_lo != 8'hFF && wmask_lo != 8'h00) ||
                         (unit_word && wmask_hi != 8'hFF && wmask_hi != 8'h00));
  wire need_read_w = rop_needs_dst || (pat_wr && unit_write) || unit_needs_rmw;
  // The access's own dword still has to be fetched. A WRITE that needs no destination and no
  // partial-mask merge is presented directly; only a read or a read-modify-write
  // spends a state fetching first.
  wire eval_fetch = (unit_read || need_read_w) && !dword_valid;

  // The CPU read result. A SHIFT_CPU read returns the READ plane's memory (mem/memegc.c:1091-1098
  // `mem[ad + planead[pl]]`, pl = fgbg[9:8]), not the addressed window plane.
  //
  // COMPAREREAD (OPE bit 13) is the EGC's colour-key compare, and the hardware returns a MASK,
  // one bit per pixel of the unit, set where that pixel's four-plane colour equals the retained
  // FG colour (0x4A6) - over the planes 0x4A0 ACCESS enables, a disabled plane being don't-care.
  // The reference is FG whatever 0x4A2's pattern selector says (EGCREAD.CSV RD21/RD22) and the
  // bit compares in the PAT mode as well (RD22_PATSEL - see the ope_cmprd block above), it is the
  // UNSHIFTED plane data (RD18/RD23/RD24 are the suite's INFO fingerprints, where the hardware
  // matches neither model exactly), and the aperture is irrelevant (RD13/RD14).
  // NP2kai does not model this: egc_readword returns the addressed plane raw (`mem[addr]`,
  // mem/memegc.c:1170-1172, the compare branch above it commented out) and egc_readbyte returns
  // `mem[addr]` for the same bit (:1102). MAME pc9801_v.cpp:863-874 has the AND-of-equalities but
  // gates it on 0x4A2's selector for the reference colour and ignores ACCESS; the Xe10 CSVs agree
  // with neither on those two points, and the hardware wins. See docs/probes/egc-conformance/.
  // The AND runs over the steps in `cmp_acc` and is exposed only in the commit step's response.
  wire [15:0] eq_b = !plane_en[pb] ? 16'hFFFF :
                     unit_word     ? ~(dq_w ^ fgc_b) : {8'hFF, ~(dq_b ^ fgc_b[7:0])};
  wire [15:0] cmp_now  = (pb == 2'd0) ? eq_b : (cmp_acc & eq_b);
  wire [15:0] pick_b   = ope_sftcpu ? (unit_word ? dq_w : {8'h00, dq_b}) :
                         unit_word  ? {st_hi, st_lo} :
                                      {8'h00, held_src ? (unit_ext ? sd_b[15:8] : sd_b[7:0]) : st_lo};
  wire [15:0] pick_now = (pb == read_plane) ? pick_b : rp_pick;
  wire [15:0] resp_piece = ope_cmprd ? cmp_now : pick_now;

  // ---------------------------------------------------------------
  // The ring's block-RAM ports
  // ---------------------------------------------------------------
  // Two ports per parity copy. Port A takes the FEED's write in S_FEED (one entry per copy, since
  // fd_lo and fd_hi are consecutive and so differ in parity) and the window's first read
  // (`ea0`/`oa0`) in S_STEP_LO onwards, so the produce's window bytes are registered from an
  // address the RAM took AFTER the write committed; port B is the window's second read. That is
  // why no feed bypass is needed: the produce consumes the COMMITTED entry.
  wire [31:0] feed_lo_w = {feed_lo[3], feed_lo[2], feed_lo[1], feed_lo[0]};
  wire [31:0] feed_hi_w = {feed_hi[3], feed_hi[2], feed_hi[1], feed_hi[0]};
  // The feed's ring write is NOT stack-gated: NP2kai's EGCOPE_SHIFTB/SHIFTW write egc.inptr[]
  // before shiftinput_* runs (mem/memegc.c:639-706), so a feed arriving with the stack past 16
  // still writes at the frozen inptr (last writer wins); only the pointer/stack/srcbit updates
  // behind `if (egc.stack <= 16)` are skipped (:590-637).
  wire        feed_commit = (state == S_FEED) && do_produce;
  wire        fd_even = !fd_lo[0];
  wire [4:0]  fd_lo_k = fd_lo[5:1];
  wire [4:0]  fd_hi_k = fd_hi[5:1];
  wire        we_e    = feed_commit && (fd_even || unit_word);
  wire        we_o    = feed_commit && (!fd_even || unit_word);
  wire [4:0]  wa_e    = fd_even ? fd_lo_k : fd_hi_k;
  wire [4:0]  wa_o    = fd_even ? fd_hi_k : fd_lo_k;
  wire [31:0] wd_e    = fd_even ? feed_lo_w : feed_hi_w;
  wire [31:0] wd_o    = fd_even ? feed_hi_w : feed_lo_w;
  wire [4:0]  ea0 = ebuf_m + {4'd0, ebuf_base[0]};
  wire [4:0]  ea1 = ea0 + 5'd1;
  wire [4:0]  oa0 = ebuf_m;
  wire [4:0]  oa1 = ebuf_m + 5'd1;
  // `reset` does not clear the ring (it is block RAM), and a descending byte unit's first
  // produce reads an entry no byte feed since the reset wrote, so a mid-run reset would serve
  // a pre-reset byte where the register form and the reference gave 0. Scrub
  // both copies to zero for 32 cycles after reset, holding the CPU off until it is done.
  reg  [4:0] scrub;
  reg        scrubbing;
  wire       scrub_we = scrubbing;
  // Port A takes the feed's write in S_FEED and the window's first read in S_STEP_LO onwards; port
  // B is the window's second read. `pc9821_dpram` is true-dual-port M10K, so both reads have a
  // port. Port B's address is the live `ebuf_base`, which is stable from S_FEED to the commit.
  // THE TWO READ PORTS ARE NOT OPTIONAL, AND THE TDP SHAPE IS WHAT THEY COST. Measured (fitter RAM
  // Summary, base profile): each copy is `True Dual Port`, A 32x32 / B 32x32, 1,024 requested bits,
  // against 2 M10K blocks each - 4 for the pair at ~5 % fill. The MODE follows the port SHAPE, not
  // port B's write capability: a port-B-read-only 32x32 shape still infers `True Dual Port` because
  // port A reads as well as writes, and only a true 1-write + 1-read shape infers `Simple Dual
  // Port` (1 block; both priced in tools/res_exp_map.py). MLAB is not a fallback either - the
  // fitter answers `No - Unsupported Mode` for this geometry, and 32x32 of MLAB would be 2 LABs of
  // the BINDING resource against 2 free M10K blocks.
  pc9821_dpram #(.AW(5), .DW(32)) u_ebuf_e (
      .clock_a(clk), .address_a(scrub_we ? scrub : (we_e ? wa_e : ea0)),
      .data_a(scrub_we ? 32'd0 : wd_e), .wren_a(scrub_we | we_e), .q_a(ebuf_e_q0),
      .clock_b(clk), .en_b(1'b1), .address_b(ea1), .data_b(32'd0), .wren_b(1'b0), .q_b(ebuf_e_q1));
  pc9821_dpram #(.AW(5), .DW(32)) u_ebuf_o (
      .clock_a(clk), .address_a(scrub_we ? scrub : (we_o ? wa_o : oa0)),
      .data_a(scrub_we ? 32'd0 : wd_o), .wren_a(scrub_we | we_o), .q_a(ebuf_o_q0),
      .clock_b(clk), .en_b(1'b1), .address_b(oa1), .data_b(32'd0), .wren_b(1'b0), .q_b(ebuf_o_q1));

  // ---------------------------------------------------------------
  // The write pass: the accumulators' columns
  // ---------------------------------------------------------------
  // A unit is a byte (one column, the unit's lane) or a 16-bit pair of the dword's byte lanes (two
  // columns, lanes L and L+1); word_unit never forms a wider one. `plane_idx` walks those columns
  // in ascending order. The pair goes out as ONE request when both columns are FULL words (a
  // partial column would need the array's per-lane enables, which the burst does not carry).
  wire [1:0] col_lo   = unit_lane[1:0];
  wire [1:0] col_last = unit_word ? (col_lo + 2'd1) : col_lo;
  wire       wsel_hi  = (plane_idx != col_lo);
  wire [3:0] cur_wbe  = wsel_hi ? wbe_hi : wbe_lo;
  wire       cur_en   = (cur_wbe != 4'h0);
  wire       wr_burst2 = unit_word && (wbe_lo == 4'hF) && (wbe_hi == 4'hF);
  // The request's data are the accumulators themselves: they move only in stage B, which runs
  // after the previous request was accepted (S_WR_B_ACC waits for the accept, S_WR_ACC for the
  // completion), and the arbiter takes an EGC request's data in its accept cycle.
  assign cl_wdata  = wsel_hi ? wacc_hi : wacc_lo;
  assign cl_wdata2 = {wacc_hi, wacc_lo};
  assign cl_datum0 = {(cl_wdata[31:24] == 8'h00), (cl_wdata[23:16] == 8'h00),
                      (cl_wdata[15:8]  == 8'h00), (cl_wdata[7:0]   == 8'h00)};

  // The all-byte walks (be = 0110 / 1110 / 0111): NP2kai's odd memegc_wr16/rd16 pair
  // order restricted to each beat's lanes. be = 0110 is one odd wr16; be = 1110 /
  // 0111 are the two odd wr16s of an unaligned dword at addr 1 / addr 3
  // (memegc.c:1421-1424 over :1397-1413). Each odd pair runs HIGH-byte-first when
  // sft bit 12 (descending) is set; a pair whose far byte lives in the neighbouring
  // beat keeps its beat-local position (the cross-beat order of memegc's logical
  // dispatch vs the 486's beat order is capture-pending on real hardware; the
  // beat-local restriction of memegc's order is what pc9821_egc_ref's op() walks and
  // what this mirrors, for the be = 0110 pair and for the 3-byte beats).
  function [3:0] byte_walk_next(input [3:0] be, input desc, input [3:0] cur);
    begin
      if (be == 4'b1110)        // lanes 1,2,3: asc 1,2,3 / desc 2,1,3
        byte_walk_next = desc ? ((cur == 4'd2) ? 4'd1 : (cur == 4'd1) ? 4'd3 : 4'd4)
                              : ((cur == 4'd1) ? 4'd2 : (cur == 4'd2) ? 4'd3 : 4'd4);
      else if (be == 4'b0111)   // lanes 0,1,2: asc 0,1,2 / desc 0,2,1
        byte_walk_next = desc ? ((cur == 4'd0) ? 4'd2 : (cur == 4'd2) ? 4'd1 : 4'd4)
                              : ((cur == 4'd0) ? 4'd1 : (cur == 4'd1) ? 4'd2 : 4'd4);
      else                      // be = 0110, lanes 1,2: asc 1,2 / desc 2,1
        byte_walk_next = desc ? ((cur == 4'd2) ? 4'd1 : 4'd4)
                              : ((cur == 4'd1) ? 4'd2 : 4'd4);
    end
  endfunction

  // The CPU access may cover up to four bytes; the reference splits a 32-bit
  // access into two 16-bit EGC operations, low half first (memegc_wr32/rd32
  // call memegc_wr16/rd16 at addr and addr+2), and an odd address into two byte
  // operations. That is the unit sequence this sequencer walks.
  //
  // The misaligned 16-bit access (be = 0110) and the 3-byte unaligned beats
  // (be = 1110 / 0111) are NP2kai's ODD memegc_wr16/rd16 operations: all byte
  // units, walked in `byte_walk_next`'s pair order (HIGH-byte-first when sft bit 12
  // is set). Word units keep their order in both directions (memegc_wr32/rd32 call
  // wr16/rd16 at addr then addr+2 unconditionally) and every other enable set keeps
  // the lane walk: none of them has a memegc_* counterpart.
  wire       byte_walk = (acc_be == 4'b0110) || (acc_be == 4'b1110) || (acc_be == 4'b0111);
  /* verilator lint_off WIDTHTRUNC */   // next_lane is 4 bits because it is unit_lane + 2, and next_set_lane
  // returns 4 for "no lane"; every index into acc_be is guarded by that value being <= 3.
  wire [3:0] next_lane = unit_lane + (unit_word ? 4'd2 : 4'd1);
  wire [3:0] next_set  = byte_walk ? byte_walk_next(acc_be, sft_dir, unit_lane)
                                   : next_set_lane(acc_be, next_lane);
  wire       more_units = (next_set <= 4'd3);
  wire       next_word = word_unit(acc_be, next_set[1:0]);
  /* verilator lint_on WIDTHTRUNC */

  // ---------------------------------------------------------------
  // Operation telemetry
  // ---------------------------------------------------------------
  // A TRANSACTION is one CPU access: the S_IDLE accept that latches acc_din/acc_be/acc_off and
  // picks the first unit. A UNIT is one byte/word lane group the sequencer walks within it - the
  // NP2kai wr16/rd16 split, so a 32-bit access is usually two word units, a 16-bit one one, and an
  // enable set with a hole walks a unit per enabled lane. `produce_commit_step` is high for the
  // cycle a unit commits (the plane loop's last step), which is exactly once per unit, so EU is
  // the transaction's work quantum and EU/ET the mean units per transaction.
  assign dbg_egc_txn  = (state == S_IDLE) && cpu_valid && !scrubbing;
  assign dbg_egc_unit = produce_commit_step;

  // ---------------------------------------------------------------
  // Sequencer
  // ---------------------------------------------------------------
  // The shifter re-arm's engine boundary. `shifter_arm` applies the pending or the
  // just-arrived 0x4AC/0x4AE write at S_IDLE, where no produce is in flight; `shift_arm_pend`
  // holds one that arrived during a produce so it is applied before the next op instead of being
  // lost. Both are declared before the always block that reads them (`default_nettype none`).
  reg  shift_arm_pend;
  wire shifter_arm = (state == S_IDLE) && (shift_arm_pend || reg_shift_we);
  // The D1 request presentation, folded into ONE next-state expression (R2): three request
  // arms set it (the write pass's destination fetch in S_STEP_HI, the read burst's first
  // column in S_IDLE, and the write pass's column in S_WR, burst or single) and the accept
  // clears it. As booleans:
  //   next = set | (old & ~cl_ready)   [an arm that presents this cycle sets;
  //                                     the accept clears every other cycle it lands on]
  // `req_acc` (below) is the taken flag that pairs with it: a posted write's completion
  // pulse must not be taken for the next request's (R5).
  wire cl_valid_set = ((state == S_STEP_HI) && !unit_read && eval_fetch &&
                       (acc_col0 != 3'd4)) ||
                      ((state == S_IDLE) && cpu_valid && !scrubbing && !cpu_write &&
                       (cpu_col0 != 3'd4)) ||
                      ((state == S_WR) && ((wr_burst2 && (plane_idx == col_lo)) || cur_en));
  integer sp;
  integer rp;
  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      plane_idx <= 2'd0;
      unit_lane <= 4'd0;
      unit_word <= 1'b0;
      unit_write <= 1'b0;
      unit_read <= 1'b0;
      acc_din <= 32'd0;
      acc_be <= 4'd0;
      acc_off <= 15'd0;
      acc_plane <= 2'd0;
      acc_page  <= 1'b0;
      resp_data <= 32'hFFFF_FFFF;
      dword_valid <= 1'b0;
      cpu_dout <= 32'hFFFF_FFFF;
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      cl_valid <= 1'b0;
      cl_write <= 1'b0;
      cl_addr  <= 16'd0;
      cl_wbe   <= 4'hF;
      cl_burst  <= 1'b0;
      req_acc   <= 1'b0;
      pat_r0 <= 16'h0000; pat_r1 <= 16'h0000; pat_r2 <= 16'h0000; pat_r3 <= 16'h0000;
      sd_r0  <= 16'h0000; sd_r1  <= 16'h0000; sd_r2  <= 16'h0000; sd_r3  <= 16'h0000;
      for (sp = 0; sp < 4; sp = sp + 1) begin
        lastvram[sp] <= 32'h0000;
      end
      srcmask <= 16'hFFFF;
      // NP2kai's egc_reset ends in egcshift() at leng 0x000F (io/egc.c:69-80), so
      // `remain` is 16 and the FIRST post-reset produce carries the full bit length:
      // the first store of a guest that never writes 0x4AC/0x4AE after reset must be
      // masked 0xFFFF, not the one-bit 0x0080 a remain of 1 would produce.
      remain  <= 13'd16;
      stack   <= 6'd0;
      dstbit  <= 4'd0;
      srcbit  <= 4'd0;
      inptr   <= 6'd0;
      outptr  <= 6'd0;
      pr_remain_1 <= 13'd0;
      pr_db_lo <= 4'd0;
      pr_remain_n <= 13'd0;
      pr_db_n <= 4'd0;
      srcmask_q <= 16'hFFFF;
      pl       <= 3'd1;
      st_lo    <= 8'h00;
      st_hi    <= 8'h00;
      wacc_lo  <= 32'd0;
      wacc_hi  <= 32'd0;
      wbe_lo   <= 4'd0;
      wbe_hi   <= 4'd0;
      cmp_acc  <= 16'hFFFF;
      rp_pick  <= 16'h0000;
      acc_access <= 4'h0;      // 0xFFF0's plane-enable bits
      acc_fgbg   <= 4'h0;      // 0x00FF: pattern source 00, read plane 0
      acc_ope    <= 14'h0000;
      acc_fg     <= 16'h0000;
      acc_mask   <= 16'hFFFF;
      acc_bg     <= 16'h0000;
      acc_sft    <= 9'h000;
      acc_leng   <= 12'h00F;
`ifdef VERILATOR
      acc_ref_access <= 16'hFFF0;
      acc_ref_fgbg   <= 16'h00FF;
      acc_ref_ope    <= 16'h0000;
      acc_ref_sft    <= 16'h0000;
      acc_ref_leng   <= 16'h000F;
`endif
      shift_arm_pend <= 1'b0;
      scrub          <= 5'd0;
      scrubbing      <= 1'b1;
    end else begin
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      // The 32-cycle ring scrub (see the port-A mux): walk both copies' 32 words once, then
      // stop. `S_IDLE`'s accept below is held off while `scrubbing`, so the first CPU access
      // after a reset cannot read the ring before it is clean.
      if (scrubbing) begin
        if (scrub == 5'd31) scrubbing <= 1'b0;
        scrub <= scrub + 5'd1;
      end
      // The step_lo outputs the second step needs are latched at S_STEP_LO, step_hi's at
      // S_STEP_HI, so no produce state carries both mask_step cones.
      if (state == S_STEP_LO) begin
        pr_remain_1 <= rem1_c;
        pr_db_lo    <= dblo_c;
      end
      if (state == S_STEP_HI) begin
        pr_remain_n <= remn_c;
        pr_db_n     <= dbn_c;
        srcmask_q   <= srcmask_eff;
      end

      // ---- the plane pipeline ----
      if (st_load) begin
        st_lo <= prod_lo;
        st_hi <= prod_hi;
      end
      if (in_loop) begin
        // Stage B of plane pb: its egc_src assembly (a non-producing unit writes the held value
        // back unchanged, see held_src), its pattern latch, its write columns and its read pick.
        {sd_r3, sd_r2, sd_r1, sd_r0} <= {do_produce ? sdn_b : sd_r0, sd_r3, sd_r2, sd_r1};
        {pat_r3, pat_r2, pat_r1, pat_r0} <= {patreg_new, pat_r3, pat_r2, pat_r1};
        // the write accumulators rotate the same way: plane pb's byte enters at the top, so after
        // the fourth step byte p is plane p again
        wacc_lo <= {wr_byte_lo, wacc_lo[31:8]};
        wacc_hi <= {wr_byte_hi, wacc_hi[31:8]};
        wbe_lo  <= {wr_lane_lo, wbe_lo[3:1]};
        wbe_hi  <= {wr_lane_hi, wbe_hi[3:1]};
        cmp_acc <= cmp_now;
        rp_pick <= pick_now;
      end

      // The client port's accept, in every state, as ONE next-state expression (R2 - the
      // fold's two terms are declared above): valid is held until ready, exactly as sdram.v's
      // own requesters hold it, and the accept contradicts a request state's own presentation
      // so a late accept is never taken for a second access.
      cl_valid <= cl_valid_set | (cl_valid & ~cl_ready);
      // `req_acc`: a request is presented in S_IDLE/S_STEP_HI/S_WR (the read burst, the write
      // pass's destination fetch, and the write pass), each clearing it in the branch that
      // presents; it is set the first cycle `cl_ready` accepts that request and held through that
      // request's `cl_done` pulses (the read burst's columns arrive one each). Every `cl_done`
      // wait takes `cl_done && req_acc`, so a posted write's pulse is not mistaken for the next
      // request's.
      if (cl_valid && cl_ready) req_acc <= 1'b1;

      // Shifter re-arm on 0x4AC/0x4AE (NP2kai egcshift). srcmask is part of it: NP2kai's handlers
      // follow egcshift() with `srcmask = 0xffff` (io/egc.c:91-113) and egc_opew ANDs srcmask into
      // mask2 in all three mode cases including the non-producing default (mem/memegc.c:1046-1078),
      // so the first write after a re-arm is masked 0xFFFF and not the previous partial value.
      // Applied at an ENGINE BOUNDARY, not mid-produce: `reg_shift_we` can arrive while
      // an op drains (does not hold the CPU), so a pending form applies it at the first
      // S_IDLE - never under a produce in flight, and never lost. It reads the LIVE reg_sft/reg_leng
      // (the registers the write itself set), not the op's latched acc_* image.
      if (shifter_arm) begin
        remain  <= {1'd0, reg_leng[11:0]} + 13'd1;
        stack   <= 6'd0;
        srcbit  <= reg_sft[3:0];
        dstbit  <= reg_sft[7:4];
        srcmask <= 16'hFFFF;
        // egcshift() re-points both byte pointers at the arm's base.
        inptr   <= reg_sft[12] ? 6'd32 : 6'd0;
        outptr  <= reg_sft[12] ? 6'd32 : 6'd0;
      end
      if (shifter_arm)    shift_arm_pend <= 1'b0;
      else if (reg_shift_we) shift_arm_pend <= 1'b1;

      // The unit's COMMIT, in the plane loop's last step (S_EVAL for a read, S_COMMIT for a
      // write): every plane has passed stage B, so the shifter's shared state moves now.
      if (produce_commit_step) begin
        if (do_produce) begin
          srcmask <= srcmask_u;
          // egcshift() zeroes the buffer's bit count as well as its pointers, and the produce
          // calls it whenever the bit length runs out -- so a re-arm discards the leftover stack
          // rather than carrying it into the next arm. The step results are the LATCHED ones.
          stack   <= shifter_rearm ? 6'd0 : stack_n;
          dstbit  <= shifter_rearm ? acc_sft[7:4] : pr_db_n;
          srcbit  <= shifter_rearm ? acc_sft[3:0] : srcbit_n;
          remain  <= shifter_rearm ? ({1'b0, acc_leng} + 13'd1) : pr_remain_n;
          // The feed wrote the unit's source bytes at inptr in S_FEED and advances it here
          // (outptr too, for the word feed's srcbit >= 8 step); the produce advances outptr by its
          // two sub calls. A re-arm re-points both at the arm's base.
          if (shifter_rearm) begin
            inptr  <= sft_dir ? 6'd32 : 6'd0;
            outptr <= sft_dir ? 6'd32 : 6'd0;
          end else begin
            if (feed_gate) inptr <= inptr_n;
            outptr <= outptr_feed + (produce_gated ? 6'd0 : mv_total);
          end
        end
        // The read's response piece: the compare's AND over all four planes, or the read
        // plane's pick, now that the last plane has been through stage B.
        if (unit_read) begin
          if (unit_word) resp_data[unit_shift +: 16] <= resp_piece;
  /* verilator lint_off WIDTHTRUNC */   // the byte lane's offset within the dword. unit_lane is in [0,3], so the index is at most
  // 24 and 5 bits hold it; the 7-bit source expression is what Verilator flags.
          else           resp_data[{unit_lane, 3'b000} +: 8] <= resp_piece[7:0];
  /* verilator lint_on WIDTHTRUNC */
        end
      end

      case (state)
        // S_FEED writes the unit's source bytes into the ring; S_STEP_LO presents the window's
        // read and latches the first mask_step; S_STEP_HI latches the second and runs stage A of
        // plane 0; the plane loop (S_EVAL for a read, S_COMMIT for a write) does the rest.
        S_FEED:    state <= S_STEP_LO;
        S_STEP_LO: state <= S_STEP_HI;
        // S_STEP_HI has BOTH step masks, so this is where the write's destination-fetch decision
        // is made (`need_read_w` needs the mask the produce is about to commit). A READ goes to
        // its loop (its source was already fetched in S_IDLE); a WRITE that needs its destination
        // fetches it here and enters its loop afterwards (stage A's plane 0 result waits in
        // st_lo/st_hi, and the ring window holds). The read burst is one request for the run
        // [acc_col0, acc_col1], one cl_done per column in column order.
        S_STEP_HI: begin
                   pl <= 3'd1;
                   if (unit_read) state <= S_EVAL;
                   else if (eval_fetch && (acc_col0 != 3'd4)) begin
                     plane_idx <= acc_col0[1:0];
                     cl_write <= 1'b0;
                     cl_burst <= 1'b1;
                     cl_addr  <= {acc_page, unit_dword + {13'd0, acc_col0[1:0]}};
                     cl_wbe   <= acc_be;
                     req_acc  <= 1'b0;
                     state    <= S_RD_RESP;
                   end else begin
                     // No covered column (or no fetch owed): nothing to fetch.
                     if (eval_fetch) dword_valid <= 1'b1;
                     state <= S_COMMIT;
                   end
                   end
        // The WRITE's plane loop. Its last step commits and hands the full accumulators to S_WR.
        S_COMMIT: begin
          if (!pl[2]) pl <= pl + 3'd1;
          else begin
            plane_idx <= col_lo;
            cl_burst  <= 1'b0;
            state     <= S_WR;
          end
        end

        S_IDLE: if (cpu_valid && !scrubbing) begin
          acc_din <= cpu_din;
          acc_be <= cpu_be;
          acc_off <= cpu_offset;
          acc_plane <= cpu_plane;
          acc_page  <= cpu_page;
          // The op's own configuration image. The eight registers are read LIVE by the
          // produce states, and the CPU is released at this accept, so they are latched
          // here and every cone reads the latched copy - NP2kai's atomic op equivalent.
          acc_access <= reg_access[3:0];
          acc_fgbg   <= {reg_fgbg[9:8], reg_fgbg[14:13]};
          acc_ope    <= reg_ope[13:0];
          acc_fg     <= reg_fg;
          acc_mask   <= reg_mask;
          acc_bg     <= reg_bg;
          acc_sft    <= {reg_sft[12], reg_sft[7:0]};
          acc_leng   <= reg_leng[11:0];
`ifdef VERILATOR
          // The observation-lemma fence's full-width shadow: the same two writers, the same
          // guard, so the equality it checks below is the snapshot's own next-state function.
          acc_ref_access <= reg_access;
          acc_ref_fgbg   <= reg_fgbg;
          acc_ref_ope    <= reg_ope;
          acc_ref_sft    <= reg_sft;
          acc_ref_leng   <= reg_leng;
`endif
          // ACCEPT-AND-DECOUPLE: a CPU WRITE is ACCEPTED here and its ready pulses at the
          // next edge; the produce pipeline (S_FEED -> S_STEP_LO -> S_STEP_HI -> the plane loop
          // -> S_WR) and its writes to the array then complete BEHIND the CPU. The write-path
          // tail states do not assert ready, so a ready z486 has consumed is never re-presented
          // to it as the next request's accept. Coherency is the stall: the EGC does not accept
          // the next CPU access until it is back in S_IDLE, which is after the last plane step
          // AND the last column request of the write, so a later CPU read always sees all four
          // planes committed (tb_pc9821_egc_serial_equiv's read-after-posted-write section). A
          // READ's ready comes from its last plane step (its data is not ready until the walk has
          // captured it).
          unit_lane <= {2'b0, cpu_lane0};
          unit_write <= cpu_write;
          unit_read <= !cpu_write;
          if (cpu_write) cpu_ready <= 1'b1;   // the store's ACCEPT; see the block above
          // A 16-bit unit is formed where the CPU's own byte enables cover both
          // bytes of an even lane pair -- that is how NP2kai's memegc_wr16/rd16
          // split a 32-bit access (low 16 bits at addr, high 16 at addr+2), and an
          // odd start falls back to two byte units.
          unit_word <= word_unit(cpu_be, cpu_lane0);
          resp_data <= 32'hFFFF_FFFF;
          dword_valid <= 1'b0;
          // A CPU read ALWAYS needs the dword (unit_read is the branch's first term), so it can
          // present its first column here rather than in a setup state. A write goes
          // straight into the produce; its fetch decision is made in S_STEP_HI.
          if (!cpu_write && (cpu_col0 != 3'd4)) begin
            plane_idx <= cpu_col0[1:0];
            cl_write <= 1'b0;
            cl_burst <= 1'b1;
            cl_addr  <= {cpu_page, cpu_offset[14:2], cpu_col0[1:0]};
            cl_wbe   <= cpu_be;
            req_acc  <= 1'b0;
            state    <= S_RD_RESP;
          end else if (!cpu_write) begin
            dword_valid <= 1'b1;
            state <= S_FEED;
          end else state <= S_FEED;
        end

        // The read burst's words, drained one cl_done at a time in column order. Each D1 access
        // returns all four planes' byte at a column, so one pass fills lastvram for every plane
        // at once: the pattern register, the shifter's source and a ROP's destination all come
        // from it. The request covers only the run the CPU's byte enables cover, so a
        // 16-bit unit costs two columns, not four; the last covered column ends the drain.
        // `req_acc` gates the drain: the run is one accepted request whose columns
        // arrive as one `cl_done` each, so a posted write's coincident pulse is not taken for one.
        S_RD_RESP: if (cl_done && req_acc) begin
          for (rp = 0; rp < 4; rp = rp + 1)
            lastvram[rp][{plane_idx, 3'b000} +: 8] <=
                cl_rdata[{rp[1:0], 3'b000} +: 8];
          if (plane_idx == acc_col1) begin
            cl_burst    <= 1'b0;
            dword_valid <= 1'b1;
            // A read's source is done: the produce starts in S_FEED. A write's destination fetch
            // returns to its plane loop.
            state <= unit_write ? S_COMMIT : S_FEED;
          end else begin
            // The next word of the SAME request; nothing is presented again.
            plane_idx <= plane_idx + 2'd1;
          end
        end

        // The READ's plane loop. Its last step commits the unit and its response piece; the
        // response's ready leaves from here (visible in S_HOLD) and the data from S_HOLD, the
        // same ready-then-data order the responder contract requires.
        S_EVAL: begin
          if (!pl[2]) pl <= pl + 3'd1;
          else if (more_units) begin
            unit_lane <= next_set;
            unit_word <= next_word;
            // The next unit reuses this access's dword (`dword_valid`), so it produces in place.
            state <= S_FEED;
          end else begin
            cpu_ready <= 1'b1;
            state <= S_HOLD;
          end
        end

        // The write pass presents the unit's columns from the accumulators: as ONE two-column
        // burst when both of a 16-bit unit's columns are full words, else one D1 column per
        // enabled column in ascending order, each carrying that byte of every plane the access
        // register enables. A column whose four plane enables are all clear is not a backend
        // access at all, which is how a write of one plane costs one column and not four.
        S_WR: begin
          if (wr_burst2 && plane_idx == col_lo) begin
            cl_burst  <= 1'b1;
            cl_write  <= 1'b1;
            cl_addr   <= {acc_page, unit_dword + {13'd0, col_lo}};
            cl_wbe    <= 4'hF;
            req_acc   <= 1'b0;
            state     <= S_WR_B_ACC;
          end else if (cur_en) begin
            cl_burst <= 1'b0;
            cl_write <= 1'b1;
            cl_addr  <= {acc_page, unit_dword + {13'd0, plane_idx}};
            cl_wbe   <= cur_wbe;
            req_acc  <= 1'b0;
            state    <= S_WR_ACC;
          end else if (plane_idx == col_last) begin
            if (more_units) begin
              unit_lane <= next_set;
              unit_word <= next_word;
              state <= S_FEED;
            end else begin
              state <= S_HOLD;
            end
          end else begin
            plane_idx <= plane_idx + 2'd1;
          end
        end
        S_WR_ACC: if (cl_done && req_acc) begin
          if (plane_idx != col_last) begin
            plane_idx <= plane_idx + 2'd1;
            state <= S_WR;
          end else if (more_units) begin
            unit_lane <= next_set;
            unit_word <= next_word;
            state <= S_FEED;
          end else begin
            state <= S_HOLD;
          end
        end

        // The write pass's two-column burst. POSTED: the pass advances on the ACCEPT, not on
        // `cl_done`, so the write drains in the array while the next unit proceeds.
        S_WR_B_ACC: if (cl_valid && cl_ready) begin
          cl_burst <= 1'b0;
          if (more_units) begin
            unit_lane <= next_set;
            unit_word <= next_word;
            state <= S_FEED;
          end else begin
            state <= S_HOLD;
          end
        end

        // One cycle only, and UNCONDITIONAL (R6): `if (unit_write || !cpu_valid)` left this
        // state by observing a level drop, which is the banned shape - the GRCG's G_HOLD is the
        // same state one module over and is unconditional. What the read arm needs is the
        // CPU's accept gap, not the level: src/z486/bus_unit.sv:350 `ext_valid_r <= 1'b0` clears it
        // at the ready edge, and a direct read's own `direct_rd_pending` keeps the next request off the
        // bus until the response lands, so the same request cannot be re-presented before S_IDLE is
        // reached. The assertion in the VERILATOR block below pins it.
        S_HOLD: begin
          // The read response lands one cycle after the ready (S_EVAL's last step); a write has
          // no response and pulses nothing here.
          if (unit_read) begin
            cpu_dout <= resp_data;
            cpu_resp_valid <= 1'b1;
          end
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end


`ifdef VERILATOR
  // ---------------------------------------------------------------------------
  // C3 OBSERVATION-LEMMA FENCE: the narrowed accepted-request snapshot against its full-width
  // shadow. The shadow has the SAME two writers as the snapshot (the reset arm and S_IDLE's
  // accept), so `acc_* == slice(acc_ref_*)` is that state's own invariant, and every consumer is
  // re-derived from the shadow and must equal the value the narrowed field produced. A dropped
  // or misplaced bit fails here in every bench that builds this module.
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */   // the shadow keeps the DROPPED bits on purpose: the
  // comparison below is what proves no consumer can see them
  reg [15:0] acc_ref_access, acc_ref_fgbg, acc_ref_ope, acc_ref_sft, acc_ref_leng;
  /* verilator lint_on UNUSEDSIGNAL */
  integer fi;
  always @(posedge clk) if (!reset) begin
    if (acc_access !== acc_ref_access[3:0])
      $fatal(1, "pc9821_egc snapshot fence: acc_access %0h != %0h", acc_access, acc_ref_access[3:0]);
    if (acc_fgbg !== {acc_ref_fgbg[9:8], acc_ref_fgbg[14:13]})
      $fatal(1, "pc9821_egc snapshot fence: acc_fgbg %0h != %0h", acc_fgbg,
             {acc_ref_fgbg[9:8], acc_ref_fgbg[14:13]});
    if (acc_ope !== acc_ref_ope[13:0])
      $fatal(1, "pc9821_egc snapshot fence: acc_ope %0h != %0h", acc_ope, acc_ref_ope[13:0]);
    if (acc_sft !== {acc_ref_sft[12], acc_ref_sft[7:0]})
      $fatal(1, "pc9821_egc snapshot fence: acc_sft %0h != %0h", acc_sft,
             {acc_ref_sft[12], acc_ref_sft[7:0]});
    if (acc_leng !== acc_ref_leng[11:0])
      $fatal(1, "pc9821_egc snapshot fence: acc_leng %0h != %0h", acc_leng, acc_ref_leng[11:0]);
    // The decode cones, from the full-width image.
    for (fi = 0; fi < 4; fi = fi + 1)
      if (plane_en[fi] !== !acc_ref_access[fi])
        $fatal(1, "pc9821_egc snapshot fence: plane_en[%0d]", fi);
    if (fgbg_sel !== acc_ref_fgbg[14:13])   $fatal(1, "pc9821_egc snapshot fence: fgbg_sel");
    if (read_plane !== acc_ref_fgbg[9:8])   $fatal(1, "pc9821_egc snapshot fence: read_plane");
    if (ope_cmprd !== acc_ref_ope[13])      $fatal(1, "pc9821_egc snapshot fence: ope_cmprd");
    if (ope_sftcpu !== acc_ref_ope[10])     $fatal(1, "pc9821_egc snapshot fence: ope_sftcpu");
    if (ope_mode !== acc_ref_ope[12:11])    $fatal(1, "pc9821_egc snapshot fence: ope_mode");
    if (pat_rd !== (acc_ref_ope[9:8] == 2'b01)) $fatal(1, "pc9821_egc snapshot fence: pat_rd");
    if (pat_wr !== (acc_ref_ope[9:8] == 2'b10)) $fatal(1, "pc9821_egc snapshot fence: pat_wr");
    if (rop_needs_dst !==
        |((acc_ref_ope[7:0] ^ (acc_ref_ope[7:0] >> 2)) & 8'h33))
      $fatal(1, "pc9821_egc snapshot fence: rop_needs_dst");
    if (sft_src8 !== acc_ref_sft[2:0])      $fatal(1, "pc9821_egc snapshot fence: sft_src8");
    if (sft_dst8 !== acc_ref_sft[6:4])      $fatal(1, "pc9821_egc snapshot fence: sft_dst8");
    if (sft_dir  !== acc_ref_sft[12])       $fatal(1, "pc9821_egc snapshot fence: sft_dir");
    if (sft_moved !== (acc_ref_sft[2:0] != acc_ref_sft[6:4]))
      $fatal(1, "pc9821_egc snapshot fence: sft_moved");
    if (sft_right !== (acc_ref_sft[2:0] > acc_ref_sft[6:4]))
      $fatal(1, "pc9821_egc snapshot fence: sft_right");
    // The ROP table's ternary index is the one consumer whose INDEX is data: prove every one of
    // the 16 selects still lands on the same guest bit.
    for (fi = 0; fi < 16; fi = fi + 1)
      if (rop_b[fi] !== acc_ref_ope[{1'b0, src_b[fi], dq_w[fi], pat_b[fi]}])
        $fatal(1, "pc9821_egc snapshot fence: rop_b[%0d]", fi);
  end
`endif

`ifdef VERILATOR
  // ---------------------------------------------------------------------------
  // R6/R8: THE UNCONDITIONAL S_HOLD BUBBLE'S CONTRACT (docs/single-cycle-event-
  // discipline.md R6/R8). S_HOLD is one cycle by construction - it does not observe
  // cpu_valid - and that is safe because the CPU's own accept gap keeps a completed request
  // off the bus (src/z486/bus_unit.sv:350 `ext_valid_r <= 1'b0` clears it at the ready edge). Both halves are pinned here; they cost nothing in synthesis and run in
  // every bench that builds this module.
  // ---------------------------------------------------------------------------
  reg hold_q;    // S_HOLD last cycle: the state is one cycle wide, never two
  reg req_live;  // S_IDLE took a request and cpu_valid has not gone low since
  // The take itself: S_IDLE's own arm (`if (cpu_valid && !scrubbing)`) - `req_live` must
  // follow THAT, not the level, or the post-reset scrub (where the state is S_IDLE and the
  // CPU may already be asserting while it waits) would look like a second take.
  wire cpu_take = (state == S_IDLE) && cpu_valid && !scrubbing;
  always @(posedge clk) begin
    if (reset) begin
      hold_q   <= 1'b0;
      req_live <= 1'b0;
    end else begin
      // (1) ONE CYCLE. A second S_HOLD cycle means a level wait came back.
      if ((state == S_HOLD) && hold_q)
        $error("pc9821_egc: S_HOLD lasted more than one cycle - the bubble must not observe cpu_valid (R6)");
      // (2) NO REQUEST TAKEN TWICE (the producer's guarantee). Every accept clears the
      //     CPU's external valid for a cycle, so a level that was never released before a
      //     fresh take would mean the same access is served again.
      if (cpu_take && req_live)
        $error("pc9821_egc: cpu_valid was never released between two EGC accesses - the CPU's accept gap is what the unconditional S_HOLD bubble rests on (R6/R8)");
      hold_q <= (state == S_HOLD);
      if (!cpu_valid)  req_live <= 1'b0;
      else if (cpu_take) req_live <= 1'b1;
    end
  end
`endif

endmodule

`default_nettype wire
