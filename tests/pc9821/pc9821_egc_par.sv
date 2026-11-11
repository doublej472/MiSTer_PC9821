// pc9821_egc_par -- BENCH-ONLY reference: the PLANE-PARALLEL EGC exactly as it shipped before
// the serial EGC (pc9821 81c98be5, src/pc9821/core/pc9821_egc.sv), kept verbatim except for
// the module name and the shared state package (which the shipped module still defines). It is
// the "old" side of tb_pc9821_egc_serial_equiv: the serial engine must agree with it on every
// GVRAM write and every CPU read datum. It is never part of a build list.

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

module pc9821_egc_par (
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
    output reg  [31:0] cl_wdata,
    // The zero-datum lane-skip's flags for cl_wdata (pc9821_gvram_arb's lane_datum0),
    // registered beside it: cl_datum0[k] says cl_wdata's byte k is 0x00. Always exactly
    // {cl_wdata[31:24]==0, cl_wdata[23:16]==0, cl_wdata[15:8]==0, cl_wdata[7:0]==0},
    // so the arb muxes 4-bit results instead of comparing 32-bit muxed write data.
    output reg  [3:0]  cl_datum0,
    output reg  [3:0]  cl_wbe,
    // The multi-column request: cl_burst says ONE request covers
    // several consecutive columns. A WRITE carries its column pair in cl_wdata2, word 0 = the
    // lower column; a READ is the unit's enabled columns (cl_wbe) and the client answers one word
    // per cl_done. Every other access leaves cl_burst low and cl_wdata2 don't-care.
    output reg         cl_burst,
    output reg  [63:0] cl_wdata2,
    input  wire [31:0] cl_rdata,
    input  wire        cl_done,

    // Telemetry: the sequencer away from S_IDLE, so pc9821_gvram can count the cycles
    // the EGC holds the CPU and the time a blit spends.
    output wire        dbg_busy,

    // Operation telemetry: one pulse per CPU command the EGC accepts and one per unit it
    // commits, so pc9821_perf_msg can report ET/EU beside EG and a capture reads EG/ET (cycles per
    // transaction) against EG/EU (cycles per unit) - the split between "many operations" and "long
    // operations" that decides whether the fix is to decouple the EGC or to shorten its per-unit
    // burst/pass.
    output wire        dbg_egc_txn,
    output wire        dbg_egc_unit
);

  import pc9821_egc_pkg::*;

  // ---------------------------------------------------------------
  // The transaction's OWN register image, latched at the S_IDLE accept
  // ---------------------------------------------------------------
  // The eight registers are read LIVE throughout the produce, which was safe only while a store
  // held the CPU until its op drained. released the CPU at the accept (a WRITE's
  // cpu_ready pulses in S_FEED), so a guest `out 0x4A0..0x4AE` can land while the produce still
  // runs and change the op - or, for 0x4AC/0x4AE, abort it. NP2kai's EGC op is one atomic memory
  // access, so it can never see that; the registers are therefore latched here, as
  // acc_off/acc_be/acc_din/acc_plane/acc_page already are, and every cone reads the latched copy.
  // The re-arm is applied at an engine boundary by `shifter_arm`/`shift_arm_pend`, so it is
  // neither mid-produce nor lost.
  /* verilator lint_off UNUSEDSIGNAL */   // the high bits are not decoded, exactly as the reg_* ports above
  reg [15:0] acc_access, acc_fgbg, acc_ope, acc_fg, acc_mask, acc_bg, acc_sft, acc_leng;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------
  // Static register decode
  // ---------------------------------------------------------------
  wire        plane_en[0:3];
  assign plane_en[0] = !acc_access[0];   // NP2kai: active LOW (memegc.c:1157)
  assign plane_en[1] = !acc_access[1];
  assign plane_en[2] = !acc_access[2];
  assign plane_en[3] = !acc_access[3];

  wire [1:0]  fgbg_sel   = acc_fgbg[14:13];   // colour-register pattern source
  wire [1:0]  read_plane = acc_fgbg[9:8];     // the plane a shifted read returns
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
  // the retained-FG mask, where a raw return would have to be 4CB3 - the value this core
  // produced while it gated on the colour source), plus the pattern source the CK00_*_MASK,
  // B08_CMP_* and RD10_RAMP_* families are actually driven with. That stimulus is witnessed by
  // the pre-fix core's own column of the same capture: those 48 rows all read back the addressed
  // PLANE word (5555, the ramp's B plane) on this core while the machine returns the mask, i.e.
  // the core took a non-comparing arm - and with bit 13 clear no mask can be produced at all, so
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
  reg [15:0] patreg [0:3];    // the four-plane pattern register
  reg [15:0] sdata  [0:3];    // the shifter's output quad (NP2kai egc_src)
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
  // The ring is block RAM now, split by entry parity so the produce's four-entry read
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
  wire [2:0] sft_dst8 = acc_sft[6:4];
  wire       sft_dir  = acc_sft[12];   // the descending direction: the mirror (see the header)
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
  // carried ONLY by cpu_be (src/z486/z486_pkg.sv:1181 `calc_be`). Deriving the lane
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
  // The produce is FOUR states now, not one. `S_FEED` writes the unit's source bytes
  // into the M10K ring, `S_STEP_LO`/`S_STEP_HI` each run ONE `mask_step` and one `sub_data` lane,
  // and the COMMIT state assembles the result. Reads commit in `S_EVAL` (their response state is
  // the same state, so the probe still holds) and writes in `S_COMMIT`. The numbers of
  // the older states are unchanged so the benches' state probes keep their meaning.
  localparam egc_state_e S_IDLE = EGC_IDLE, S_RD_RESP = EGC_RD_RESP, S_EVAL = EGC_EVAL,
             S_WR = EGC_WR, S_WR_ACC = EGC_WR_ACC, S_RESP2 = EGC_RESP2, S_HOLD = EGC_HOLD,
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
  // `plane_idx` indexes a COLUMN of the unit's dword now, not a plane: the planes
  // travel as the four byte-enable lanes of one D1 access (D1/D2).
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
  // The access PAGE, latched at the S_IDLE accept. `cl_addr` is {page, plane offset} and
  // the write pass reads the page LIVE today; with the CPU released at the accept (a store's ready
  // now pulses there) z486 can move `cpu_page` for its next access while the produce is still
  // writing, so the page must be latched exactly as acc_off/acc_plane/acc_be/acc_din are.
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
      // The same extracts at the STAGED unit index: the read response assembles one state
      // after the commit, where the unit walk has already moved unit_lane/unit_word, so its
      // quad reads must use the committed unit's own index.
      assign quad_word_q[gp] = lastvram[gp][unit_shift_q +: 16];
      assign quad_byte_q[gp] = lastvram[gp][{unit_lane_q, 3'b000} +: 8];
    end
  endgenerate

  /* verilator lint_on WIDTHTRUNC */
  // RL_MEMWRITE latches the pattern register from the destination BEFORE the ROP runs
  // (mem/memegc.c:1337-1343 `egc.patreg.w[p] = ...; data = egc_opew(...)`). `pat_latch_now`
  // marks the state whose edge commits that latch so the pattern operand takes the POST-latch
  // value; the value is only consumed where the unit is committed.
  // The produce COMMITS in the read's evaluate state (S_EVAL) or the write's commit state
  // (S_COMMIT); both run the same commit block.
  wire        produce_commit_step = (state == S_EVAL) || (state == S_COMMIT);
  wire        pat_latch_now = produce_commit_step &&
                              ((unit_read && pat_rd) || (unit_write && pat_wr));
  // Pattern source for the ROP functions and for the WS_PATREG data quad.
  wire [15:0] pat_quad [0:3];
  wire [15:0] patreg_lat [0:3];   // patreg with the presenting unit's latch applied
  wire [15:0] fgc_quad [0:3];
  wire [15:0] bgc_quad [0:3];
  wire [15:0] patreg_data [0:3];
  // COMPAREREAD's compare mask, one bit per pixel of the unit (see resp_word/resp_byte below
  // for the hardware source): a plane's bit is "equal" where that plane's data matches the
  // retained FG colour's bit for it, and the mask is the AND over the ACCESS-enabled planes -
  // a plane whose ACCESS bit is set is not compared at all, so it contributes all ones.
  wire [15:0] cmp_w_eq [0:3];
  wire [7:0]  cmp_b_eq [0:3];
  wire [15:0] quad_word_q [0:3];   // the staged-index quad extracts (the late consume, below)
  wire [7:0]  quad_byte_q [0:3];
  // The committed produce as every post-commit consumer sees it: exactly the value the sdata
  // assembly writes for a producing unit (a byte unit's single lane is `pr_prod_lo` in EITHER
  // half), the HELD sdata otherwise. Declared here, assigned below beside the pipeline
  // registers.
  wire [15:0] src_word [0:3];
  // A read's PLOAD_R (RL_MEMREAD) loads only the SELECTED PAT plane: the byte/word source bytes
  // for the unit being committed, restricted to read_plane. A write's PLOAD_W loads all four
  // (W10_PLOADW_CAPTURE, EGCWRITE.CSV). `patreg_lat` is the same restriction for the presenting
  // unit's pattern operand.
  // A word latch loads the whole register; a byte latch loads only the operand's lane.
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_quad
      wire pat_latch_plane = !(unit_read && pat_rd) || (gp[1:0] == read_plane);
      assign patreg_lat[gp] = (!pat_latch_now || !pat_latch_plane) ? patreg[gp] :
                              unit_word     ? quad_word[gp] :
                              unit_ext      ? {quad_byte[gp], patreg[gp][7:0]}
                                            : {patreg[gp][15:8], quad_byte[gp]};
      assign fgc_quad[gp] = colour_plane(acc_fg, gp[1:0]);
      assign bgc_quad[gp] = colour_plane(acc_bg, gp[1:0]);
      // The compare reads the STAGED quad: cmp_w_eq/cmp_b_eq feed only the response, which
      // assembles one state after the commit.
      assign cmp_w_eq[gp] = plane_en[gp] ? ~(quad_word_q[gp] ^ fgc_quad[gp]) : 16'hFFFF;
      assign cmp_b_eq[gp] = plane_en[gp] ? ~(quad_byte_q[gp] ^ fgc_quad[gp][7:0]) : 8'hFF;
      assign pat_quad[gp] =
          (fgbg_sel == 2'b01) ? bgc_quad[gp] :
          (fgbg_sel == 2'b10) ? fgc_quad[gp] :
          (fgbg_sel == 2'b11) ? (gp[1] ? bgc_quad[gp] : fgc_quad[gp]) :
          // The ROP's pattern operand is the committed produce (`src_word`: the pipeline
          // pair for a producing unit, the HELD sdata otherwise).
          (pat_rd ? src_word[gp] : patreg_lat[gp]);
      assign patreg_data[gp] =
          (fgbg_sel == 2'b01) ? bgc_quad[gp] :
          (fgbg_sel == 2'b10) ? fgc_quad[gp] : patreg_lat[gp];
    end
  endgenerate

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
  // outptr the NEXT state (S_STEP_LO presents the address, S_STEP_HI consumes it), so the produce
  // reads the COMMITTED entries and there is no `rd` bypass.
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
  // `outptr_feed`/`ebuf_base` are functions of `outptr`/`srcbit`, which the commit state updates,
  // so they are STABLE across S_FEED -> S_STEP_LO -> S_STEP_HI -> the commit; the window select and
  // the RAM read addresses can read them live.
  wire [31:0] ebuf_e_q0, ebuf_e_q1, ebuf_o_q0, ebuf_o_q1;   // the two copies' read ports
  function [7:0] rd(input [1:0] p, input [5:0] a);
    reg [31:0] w;
    begin
      // window bytes: even base = E[m],O[m],E[m+1],O[m+1]; odd base = O[m],E[m+1],O[m+1],E[m+2]
      case (a - ebuf_base)
        6'd0:    w = ebuf_base[0] ? ebuf_o_q0 : ebuf_e_q0;
        6'd1:    w = ebuf_base[0] ? ebuf_e_q0 : ebuf_o_q0;
        6'd2:    w = ebuf_base[0] ? ebuf_o_q1 : ebuf_e_q1;
        default: w = ebuf_base[0] ? ebuf_e_q1 : ebuf_o_q1;
      endcase
      rd = w[{p, 3'b000} +: 8];
    end
  endfunction

  // One sub call's data byte, at the pre-move outptr `o` with the pre-step `db`. The partial
  // (`db != 0`) branches emit ONE source byte and hold outptr; every other branch is the
  // two-byte combination. dnr/dnl move outptr FIRST, so they read `o-1` and `o` (egcsftb_dnr_sub
  // :267-296, egcsftb_dnl_sub :327-369).
  function [7:0] sub_data(input [1:0] p, input [5:0] o, input [3:0] db);
    reg [7:0] b0, b1, bm0, bm1;
    begin
      b0 = rd(p, o); b1 = rd(p, o + 6'd1);
      case (efunc)
        3'd0, 3'd1: sub_data = b0;                                                 // upn/dnn
        3'd2: sub_data = (db != 4'd0) ? (b0 >> e_s8r)
                                      : ((b0 << e_s8l) | (b1 >> e_s8r));           // upr
        3'd4: sub_data = (b0 << e_s8l) | (b1 >> e_s8r);                            // upl
        3'd3: begin bm0 = rd(p, o - 6'd1); bm1 = rd(p, o);
                    sub_data = (db != 4'd0) ? (b0 << e_s8r)
                                            : ((bm1 >> e_s8l) | (bm0 << e_s8r)); end
        default: begin bm0 = rd(p, o - 6'd1); bm1 = rd(p, o);
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

  // ---- step_hi: the second `mask_step`, computed in S_STEP_HI from the LATCHED step_lo outputs,
  // ---- so neither state carries both mask_step cones. The second byte of a 16-bit unit, and only
  // while bit length is left: NP2kai `if (egc.remain) { sub(H); if (egc.remain) return; } else
  // srcmask._b[H] = 0;`. Its outputs the commit needs (`pr_db_n`, `pr_remain_n`) are latched here.
  wire        produce_hi = !produce_gated && unit_word && (pr_remain_1 != 13'd0);
  wire [24:0] step_hi = mask_step(pr_db_lo, pr_remain_1);
  wire [7:0]  m_hi_c   = produce_hi ? step_hi[24:17] : 8'h00;
  wire [12:0] remn_c   = produce_hi ? step_hi[16:4] : pr_remain_1;
  wire [3:0]  dbn_c    = produce_hi ? step_hi[3:0] : pr_db_lo;
  reg  [12:0] pr_remain_n;
  reg  [3:0]  pr_db_n;

  // DESCENDING the first produce step is the HIGH lane's (egcsftw_dnl0 calls dnl_sub(H) then _L), so
  // its mask - m_lo, the step_lo result - lands high; when the bit length ends after that one step
  // the stale half is the LOW one (see prod_lo_ok). ASCENDING the low lane goes first. `m_lo_c` is
  // a live wire (its inputs, `dstbit`/`remain`, only move at the commit) and `m_hi_c` is stable
  // from S_STEP_LO's latch onward, so the assembly is a register/step read, not a second cone.
  wire [15:0] srcmask_n   = (unit_word && sft_dir) ? {m_lo_c, m_hi_c} : {m_hi_c, m_lo_c};
  // egc.srcmask is a 16-BIT register and NP2kai writes only the produced lane of it: a byte feed
  // sets `srcmask._b[ext] = 0xff` and then that byte's mask, leaving the OTHER lane exactly as it
  // was (memegc.c shiftinput_byte + egcsftb_*0). `srcmask_n` puts the produced byte at lane 0
  // always, so a byte unit at an odd lane must place it at lane 1 and keep lane 0; otherwise the
  // mask a later word unit ANDs in carries a zeroed byte. mask2 reads the same register the update
  // writes, so both uses take this value.
  wire [15:0] srcmask_u   = unit_word ? srcmask_n :
                            (unit_ext ? {m_lo_c, srcmask[7:0]} : {srcmask[15:8], m_lo_c});
  // The produce's own mask select for `mask2_w` below: `srcmask_u` is the value the produce is
  // ABOUT to commit, which is what S_STEP_HI's fetch decision (`need_read_w`) must see before it.
  // S_STEP_HI is the state where BOTH step masks exist (`m_lo_c` is live, `m_hi_c` comes from the
  // latched step_lo outputs), so `srcmask_u` there is exactly the mask that commits. Every other
  // use of the mask (the write lane's `mask2_w`) reads the registered `srcmask`. The ROP's src is
  // the REGISTERED `sdata` the write lane reads from S_WR. `eval_fetch` must NOT appear
  // here: `need_read_w` is derived from `mask2_w`, so gating this on the fetch closes a loop.
  wire        produce_now = (state == S_STEP_HI) && do_produce;
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
  // emits nothing and does not move, so the second step reads the same position. The two steps
  // SHARE one `sub_data` lane per plane (the `lane_o`/`lane_db` operand mux below): `prod_lo` is
  // consumed only at the S_STEP_HI edge (its latch into `pr_prod_lo`) and `prod_hi` only at the
  // commit edge (its latch into `pr_prod_hi`), never in the same state, so one time-multiplexed
  // lane replaces the two parallel ones. Both bytes land in pipeline registers and every
  // consumer samples the pair one state after the commit (the consume edge below).
  //
  // A BYTE unit runs ONE sub call - NP2kai's egcsftb_*0 dispatches one egcsftb_*_sub - so its
  // byte takes the FIRST step's slot (outptr_feed, the pre-step dstbit) in BOTH directions; the
  // `outptr_feed + mv1` second-step slot is only the DESCENDING WORD's low lane. This select
  // used to send every descending byte unit to the second-step slot, reading the ring one
  // position early: egcsftb_dnn_sub reads outptr[0] before its move (:174-178) and
  // egcsftb_dnl_sub moves first and then reads (outptr[1], outptr[0]) = (pre, pre-1)
  // (memegc.c:145-179, :331-369) - both take the PRE-move outptr as their primary byte,
  // which is sub_data at the pre-move `o`, not at o + mv1. (Correcting an earlier claim that "within-unit descending
  // byte placement IS correct" held for the WORD units' two calls only; the byte unit's single
  // call had the same missing direction term. Exposed by the extended matrix's descending
  // byte-produce cases, which compare by value against NP2kai.)
  reg [7:0] prod_lo [0:3];
  reg [7:0] prod_hi [0:3];
  reg [7:0] pr_prod_lo [0:3];   // the low lane's produce byte, latched at the S_STEP_HI edge
  reg [7:0] sbyte_next [0:3];   // the byte a byte-unit returns/uses, post-produce
  // THE PRE-EMPTIVE PIPELINE REGISTER (and its consume-side staging).
  // `pr_prod_hi` is the shared lane's SECOND stage: the high lane's produce byte latched at the
  // commit edge - exactly the value the pre-pipeline form wrote into sdata's high half there.
  // Every consumer of the hi lane (sdata's assembly, the read response, the ROP's src/pat in
  // S_WR) is retimed to sample the pipeline registers ONE STATE AFTER the commit, so the
  // produce cone ends at pr_prod_hi/pr_prod_lo and the consumers' cones start at registers.
  // The staging registers carry what the one-state-later consume needs and the unit walk has
  // already moved by then: commit_q marks the consume cycle, do_prod_q is the staged
  // `do_produce` gate on sdata's assembly, sbyte_held_q is the staged sbyte_next hold-select,
  // and unit_word_q/unit_lane_q are the committed unit's own walk position.
  reg [7:0] pr_prod_hi [0:3];   // the high lane's produce byte, latched at the commit edge
  reg       commit_q;           // one cycle after a produce commit: the consume edge
  reg       do_prod_q;          // staged do_produce (the sdata assembly gate)
  reg       sbyte_held_q;       // staged (produce_gated || !do_produce) for sbyte_next
  reg [3:0] unit_lane_q;        // the committed unit's lane/word shape for the late consume
  reg       unit_word_q;
  wire [4:0] unit_shift_q = unit_lane_q[1] ? 5'd16 : 5'd0;
  wire       unit_ext_q   = unit_lane_q[0];
  wire [15:0] sdata_next [0:3];   // the word the delayed sdata assembly writes
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_src_word
      assign sdata_next[gp] = unit_word_q ? {pr_prod_hi[gp], pr_prod_lo[gp]} :
                              unit_ext_q  ? {pr_prod_lo[gp], sdata[gp][7:0]} :
                                            {sdata[gp][15:8], pr_prod_lo[gp]};
      assign src_word[gp] = sbyte_held_q ? sdata[gp] : sdata_next[gp];
    end
  endgenerate
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
  // SHARED PRODUCE LANE: one `sub_data` lane per plane, time-multiplexed over the two step
  // slots by `produce_commit_step` - the exact phase predicate (prod_lo is consumed at the
  // S_STEP_HI edge, prod_hi at the commit edge, never both in one state).
  wire        lane_hi_phase = produce_commit_step;
  wire  [5:0] lane_o  = lane_hi_phase ? (sft_dir ? outptr_feed : outptr_feed + mv1)
                                      : ((unit_word && sft_dir) ? outptr_feed + mv1 : outptr_feed);
  wire  [3:0] lane_db = lane_hi_phase ? (sft_dir ? dstbit : pr_db_lo)
                                      : ((unit_word && sft_dir) ? pr_db_lo : dstbit);
  integer pp;
  always @* begin
    for (pp = 0; pp < 4; pp = pp + 1) begin
      prod_lo[pp] = prod_lo_ok
                      ? sub_data(pp[1:0], lane_o, lane_db)
                      : (unit_ext ? sdata[pp][15:8] : sdata[pp][7:0]);
      prod_hi[pp] = prod_hi_ok
                      ? sub_data(pp[1:0], lane_o, lane_db)
                      : sdata[pp][15:8];
      // A unit that FEEDS nothing leaves egc_src alone: NP2kai's byte WS_PATREG default returns
      // egc_src, and with SHIFT_CPU clear (or a colour quad) no EGCOPE_SHIFTB ran, so the byte the
      // write stores - and the byte a read would return - is the HELD sdata, not a produce the
      // gate never committed. (`pr_prod_lo` is the committed produce; it is what the source
      // register takes when `do_produce`.) Sampled one state after the commit, so the
      // hold-select is the STAGED one and the held source is the pre-assembly sdata (the
      // assembly happens at this same edge and a non-blocking read sees the old value, which is
      // exactly the held byte the pre-pipeline form saw).
      sbyte_next[pp] = sbyte_held_q
                         ? (unit_ext_q ? sdata[pp][15:8] : sdata[pp][7:0]) : pr_prod_lo[pp];
    end
  end

  // ---------------------------------------------------------------
  // The unit's data quad and mask
  // ---------------------------------------------------------------
  // The ROP result, per plane: NP2kai's opefn[] table (mem/memegc.c:935-997,
  // with the per-class bodies at :709-960) is the 8-entry ternary truth table
  // of (pat, src, dst) held in acc_ope[7:0] itself -- bit {src,dst,pat} of the
  // code is the function's value for that triple (bit-identical to the old
  // class/term networks for all 256 codes). Each output bit is one 8:1 select
  // over that table instead of the minterm expansion.
  wire [15:0] rop_out [0:3];
  wire [7:0]  rop_out_byte [0:3];
  genvar gb;
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_rop
      wire [15:0] pat = pat_quad[gp];
      // The ROP's src: the committed produce. The write lane presents from S_WR, one state after
      // the produce edge, so the pipeline registers already hold this unit's produce -- feeding
      // the live produce here kept `dstbit -> mask_step -> rd -> sub_data -> prod_lo/prod_hi -> ROP ->
      // wr_din_p -> cl_wdata` one combinational edge the fitter cannot prove clear in S_WR.
      // (sdata itself assembles one state later still, so the ROP reads `src_word` - the
      // pipeline pair for a producing unit, the held sdata for one that never fed, whose
      // lane byte the ok-mux fallbacks do NOT carry.)
      wire [15:0] src = src_word[gp];
      wire [15:0] dst = quad_word[gp];
      for (gb = 0; gb < 16; gb = gb + 1) begin : g_rop_bit
        assign rop_out[gp][gb] =
            acc_ope[{1'b0, src[gb], dst[gb], pat[gb]}];
      end
      assign rop_out_byte[gp] = unit_ext ? rop_out[gp][15:8] : rop_out[gp][7:0];
    end
  endgenerate

  // Word path (NP2kai egc_opew), per mode. NP2kai's `egc.mask2.w &= egc.srcmask.w` reads the
  // REGISTER, which the feed commits at the same step -- so the mask is `srcmask_u` only in the
  // state whose edge commits it, and the registered `srcmask` everywhere else (S_WR presents the
  // write's columns one state later, where the live stack has already moved on and a re-derived
  // `srcmask_u` would differ from what the shifter actually wrote).
  wire [15:0] mask2_w = acc_mask & (produce_now ? srcmask_u : srcmask);
  wire [15:0] word_data [0:3];
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_word_data
      assign word_data[gp] =
          (ope_mode == 2'b10) ? patreg_data[gp] :
          (ope_mode == 2'b01) ? rop_out[gp] : cpu_word;
    end
  endgenerate

  // Byte path (NP2kai egc_opeb). Note the WS_PATREG default branch returns the
  // shifter output and ANDs srcmask, where the 16-bit path returns the pattern
  // register; and the WS_CPU byte path does not AND srcmask at all.
  wire [7:0] mask_b_sft = mask2_w[8*{2'b0, unit_ext} +: 8];
  wire [7:0] mask_b_reg = acc_mask[8*{2'b0, unit_ext} +: 8];
  // The shifter byte the write stores. NP2kai reads egc_src, which only a FEED moves, so the
  // byte is the committed one: `src_word` holds this unit's produce in S_WR, one state after the
  // produce edge, where the live `stack` has moved on and re-deriving the produce from it gives a
  // byte the shifter never emitted (the same rule as mask2_w above).
  wire [7:0] sbyte_fed [0:3];
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_sbyte_fed
      assign sbyte_fed[gp] = unit_ext ? src_word[gp][15:8] : src_word[gp][7:0];
    end
  endgenerate
  wire [7:0] byte_data [0:3];
  wire [7:0] byte_mask [0:3];
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_byte_data
      assign byte_data[gp] =
          (ope_mode == 2'b01) ? rop_out_byte[gp] :
          (ope_mode == 2'b10) ? ((fgbg_sel == 2'b01) ? bgc_quad[gp][{unit_ext,3'b000} +: 8] :
                                 (fgbg_sel == 2'b10) ? fgc_quad[gp][{unit_ext,3'b000} +: 8] :
                                 sbyte_fed[gp]) :
          cpu_byte;
      // The colour-quad byte cases return BEFORE mask2 &= srcmask (memegc.c egc_opeb case 0x1000),
      // and 0x6000 takes the default, so only 0x2000/0x4000 keep the plain mask register.
      assign byte_mask[gp] =
          (ope_mode == 2'b01) ? mask_b_sft :
          (ope_mode == 2'b10) ? (byte_no_color ? mask_b_sft : mask_b_reg) :
          mask_b_reg;
    end
  endgenerate

  // ---------------------------------------------------------------
  // Column write issue: one D1 column per byte of the unit's plane dword
  // ---------------------------------------------------------------
  // An EGC unit is a 16-bit half of a dword of each plane. The D1 port carries
  // one byte of every plane per access, so the per-plane enables and data this
  // module already computes transpose into a per-column {P3,P2,P1,P0} pair:
  // column i is byte i of each plane's dword, i.e. the plane byte at
  // (cpu_offset & ~3) + i. Nothing about the transform changes -- only which
  // wire the result leaves by.
  wire [15:0] wdata_bits [0:3];
  wire [15:0] wmask_bits [0:3];
  wire [7:0]  wold_lo    [0:3];
  wire [7:0]  wold_hi    [0:3];
  wire [3:0]  wr_be_p    [0:3];   // one plane's byte enables within the dword
  wire [31:0] wr_din_p   [0:3];   // one plane's merged dword
  wire [3:0]  col_wbe    [0:3];   // per column: one enable per plane
  wire [31:0] col_wdata  [0:3];
  wire        col_en     [0:3];
  wire        unit_needs_rmw_p [0:3];

  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_col_plane
      wire [7:0] wmask_lo = wmask_bits[gp][7:0];
      wire [7:0] wmask_hi;
      wire [7:0] wdata_lo;
      wire [7:0] wdata_hi;
      wire       wr_lane_lo;
      wire       wr_lane_hi;
      wire [7:0] wr_byte_lo;
      wire [7:0] wr_byte_hi;

      assign wdata_bits[gp] = unit_word ? word_data[gp] : {2{byte_data[gp]}};
      assign wmask_bits[gp] = unit_word ? mask2_w : {2{byte_mask[gp]}};
      assign wmask_hi = unit_word ? wmask_bits[gp][15:8] : 8'h00;
      assign wdata_lo = wdata_bits[gp][7:0];
      assign wdata_hi = wdata_bits[gp][15:8];
  /* verilator lint_off WIDTHTRUNC */   // the byte lane's offset within the dword, for the
  // low byte. unit_lane is in [0,3] so {unit_lane,3'b000} is at most 24 and the 5-bit
  // extraction index never wraps; the 7-bit source expression is what Verilator flags.
      assign wold_lo[gp] = lastvram[gp][{unit_lane, 3'b000} +: 8];
  /* verilator lint_on WIDTHTRUNC */
  // The HIGH byte's old contents. `{unit_lane,3'b000} + 8` is 8/16/24 for lanes 0/1/2 and 32
  // for lane 3 - a 32-bit vector indexed [39:32] is an OUT-OF-RANGE part select, which reads x
  // (IEEE 1364-2005 5.2.1), and the stray `lint_on WIDTHTRUNC` that used to sit on this line
  // left it outside the region its sibling is waived in. `wr_be_p` places the high byte at
  // dword byte {lane+1}, so lanes 0/1/2 need [15:8]/[23:16]/[31:24] and lane 3's is never
  // enabled at all ({wr_lane_lo, 3'b0}): the ternary is therefore value-identical wherever
  // this can matter and in range everywhere.
  // (`wr_din_p`'s high-byte shift by 32 is the deliberate 'this lane has no high byte' case.)
      assign wold_hi[gp] = (unit_lane == 4'd0) ? lastvram[gp][15:8] :
                           (unit_lane == 4'd1) ? lastvram[gp][23:16] :
                                                 lastvram[gp][31:24];
      assign wr_lane_lo = plane_en[gp] && (wmask_lo != 8'h00);
      assign wr_lane_hi = plane_en[gp] && unit_word && (wmask_hi != 8'h00);

      assign wr_be_p[gp] = (unit_lane == 4'd0) ? {2'b0, wr_lane_hi, wr_lane_lo} :
                           (unit_lane == 4'd1) ? {1'b0, wr_lane_hi, wr_lane_lo, 1'b0} :
                           (unit_lane == 4'd2) ? {wr_lane_hi, wr_lane_lo, 2'b0} :
                                                 {wr_lane_lo, 3'b0};
      // Byte-by-byte merge: the reference does `mem &= ~mask2; mem |= data & mask2`
      // on every enabled plane, which for the byte enables above is the same write.
      assign wr_byte_lo = (wdata_lo & wmask_lo) | (wold_lo[gp] & ~wmask_lo);
      assign wr_byte_hi = (wdata_hi & wmask_hi) | (wold_hi[gp] & ~wmask_hi);
  /* verilator lint_off WIDTHEXPAND */   // the shift amount must stay 6+ bits wide. For lane 3 the high byte shifts by 8+24 = 32,
  /* verilator lint_off WIDTHTRUNC */
  // and a 32-bit left shift by 32 is the deliberate 'this lane has no high byte' case.
  // Narrowing the sum to 5 bits would make it 0 and write the high byte into the LOW
  // position instead.
      assign wr_din_p[gp] = ({24'd0, wr_byte_lo} << {unit_lane, 3'b000}) |
                            (unit_word ? ({24'd0, wr_byte_hi} <<
                                          ({unit_lane, 3'b000} + 5'd8)) : 32'd0);

  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on WIDTHTRUNC */
      // The read pass is skipped whenever the transform does not need the old
      // contents: the target sequences' writes need neither destination bits nor
      // a partial mask, so they cost four column writes and no reads.
      assign unit_needs_rmw_p[gp] = (wmask_lo != 8'hFF && wr_lane_lo) ||
                                    (unit_word && wmask_hi != 8'hFF && wr_lane_hi);

      assign col_wbe[gp]   = {wr_be_p[3][gp], wr_be_p[2][gp],
                              wr_be_p[1][gp], wr_be_p[0][gp]};
      assign col_wdata[gp] = {wr_din_p[3][8*gp +: 8], wr_din_p[2][8*gp +: 8],
                              wr_din_p[1][8*gp +: 8], wr_din_p[0][8*gp +: 8]};
      assign col_en[gp]    = (col_wbe[gp] != 4'h0);
    end
  endgenerate

  wire need_read_w = rop_needs_dst || (pat_wr && unit_write) ||
                     unit_needs_rmw_p[0] || unit_needs_rmw_p[1] ||
                     unit_needs_rmw_p[2] || unit_needs_rmw_p[3];
  // The access's own dword still has to be fetched. A WRITE that needs no destination and no
  // partial-mask merge is presented directly; only a read or a read-modify-write
  // spends a state fetching first.
  wire eval_fetch = (unit_read || need_read_w) && !dword_valid;

  // ---------------------------------------------------------------
  // The ring's block-RAM ports
  // ---------------------------------------------------------------
  // Two ports per parity copy. Port A takes the FEED's write in S_FEED (one entry per copy, since
  // fd_lo and fd_hi are consecutive and so differ in parity) and the window's first read
  // (`ea0`/`oa0`) in S_STEP_LO onwards, so the produce's window bytes are registered from an
  // address the RAM took AFTER the write committed; port B is the window's second read. That is
  // what replaces the old feed bypass: the produce consumes the COMMITTED entry.
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
  // port. Port B's address is the live `ebuf_base`, which is stable across the four produce states.
  // THE TWO READ PORTS ARE NOT OPTIONAL, AND THE TDP SHAPE IS WHAT THEY COST. Measured (fitter RAM
  // Summary, base profile): each copy is `True Dual Port`, A 32x32 / B 32x32, 1,024 requested bits,
  // against 2 M10K blocks each - 4 for the pair at ~5 % fill. The MODE follows the port SHAPE, not
  // port B's write capability: a port-B-read-only 32x32 shape still infers `True Dual Port` because
  // port A reads as well as writes, and only a true 1-write + 1-read shape infers `Simple Dual
  // Port` (1 block; both priced in tools/res_exp_map.py). MLAB is not a fallback either - the
  // fitter answers `No - Unsupported Mode` for this geometry, and 32x32 of MLAB would be 2 LABs of
  // the BINDING resource against 2 free M10K blocks. So the only way off the second block per copy
  // is to give up a read port, i.e. to spread the window's two reads over two cycles: a longer
  // produce, and a guest-visible latency change this module is not the right place to make.
  pc9821_dpram #(.AW(5), .DW(32)) u_ebuf_e (
      .clock_a(clk), .address_a(scrub_we ? scrub : (we_e ? wa_e : ea0)),
      .data_a(scrub_we ? 32'd0 : wd_e), .wren_a(scrub_we | we_e), .q_a(ebuf_e_q0),
      .clock_b(clk), .en_b(1'b1), .address_b(ea1), .data_b(32'd0), .wren_b(1'b0), .q_b(ebuf_e_q1));
  pc9821_dpram #(.AW(5), .DW(32)) u_ebuf_o (
      .clock_a(clk), .address_a(scrub_we ? scrub : (we_o ? wa_o : oa0)),
      .data_a(scrub_we ? 32'd0 : wd_o), .wren_a(scrub_we | we_o), .q_a(ebuf_o_q0),
      .clock_b(clk), .en_b(1'b1), .address_b(oa1), .data_b(32'd0), .wren_b(1'b0), .q_b(ebuf_o_q1));

  // The write pass as ONE request needs the unit's TWO columns -- a 16-bit unit is a pair of the
  // dword's four byte lanes, and word_unit never forms a wider one -- enabled together AND each a
  // FULL word: a partial column would need the controller's per-word read-modify-write, which a
  // burst cannot carry. Any other enable set keeps the per-column walk.
  wire wr_burst_lo = !col_en[2] && !col_en[3] && col_en[0] && col_en[1] &&
                     (col_wbe[0] == 4'hF) && (col_wbe[1] == 4'hF);
  wire wr_burst_hi = !col_en[0] && !col_en[1] && col_en[2] && col_en[3] &&
                     (col_wbe[2] == 4'hF) && (col_wbe[3] == 4'hF);
  wire wr_burst2 = wr_burst_lo || wr_burst_hi;
  wire [1:0]  wb_c0    = wr_burst_hi ? 2'd2 : 2'd0;
  wire [63:0] wb_data2 = wr_burst_hi ? {col_wdata[3], col_wdata[2]}
                                     : {col_wdata[1], col_wdata[0]};

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
  wire [3:0] next_set  = byte_walk ? byte_walk_next(acc_be, acc_sft[12], unit_lane)
                                   : next_set_lane(acc_be, next_lane);
  wire       more_units = (next_set <= 4'd3);
  wire       next_word = word_unit(acc_be, next_set[1:0]);
  /* verilator lint_on WIDTHTRUNC */

  // The CPU read result, and its placement in the response lanes. A SHIFT_CPU read returns the
  // READ plane's memory (mem/memegc.c:1091-1098 `mem[ad + planead[pl]]`, pl = fgbg[9:8]), not the
  // addressed window plane.
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
  wire [15:0] cmp_word = cmp_w_eq[0] & cmp_w_eq[1] & cmp_w_eq[2] & cmp_w_eq[3];
  wire [7:0]  cmp_byte = cmp_b_eq[0] & cmp_b_eq[1] & cmp_b_eq[2] & cmp_b_eq[3];
  wire [15:0] resp_word = ope_cmprd  ? cmp_word :
                          ope_sftcpu ? quad_word_q[read_plane] :
                          {pr_prod_hi[read_plane], pr_prod_lo[read_plane]};
  wire [7:0]  resp_byte = ope_cmprd  ? cmp_byte :
                          ope_sftcpu ? quad_byte_q[read_plane] :
                          sbyte_next[read_plane];

  // ---------------------------------------------------------------
  // Operation telemetry
  // ---------------------------------------------------------------
  // A TRANSACTION is one CPU access: the S_IDLE accept that latches acc_din/acc_be/acc_off and
  // picks the first unit. A UNIT is one byte/word lane group the sequencer walks within it - the
  // NP2kai wr16/rd16 split, so a 32-bit access is usually two word units, a 16-bit one one, and an
  // enable set with a hole walks a unit per enabled lane. `produce_commit_step` is high for the
  // cycle a unit's produce commits (S_EVAL for a read, S_COMMIT for a write), which is exactly
  // once per unit: every unit passes through S_FEED/S_STEP_LO/S_STEP_HI to one of those two, so EU
  // is the transaction's work quantum and EU/ET the mean units per transaction.
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
  // clears it. The set used to be three separate `<=` sites inside the case with the clear
  // ABOVE it, so the set won by position - the position was the mechanism. As booleans:
  //   next = set | (old & ~cl_ready)   [an arm that presents this cycle sets;
  //                                     the accept clears every other cycle it lands on]
  // `req_acc` (below) is the taken flag that pairs with it: a posted write's completion
  // pulse must not be taken for the next request's (R5).
  wire cl_valid_set = ((state == S_STEP_HI) && !unit_read && eval_fetch &&
                       (acc_col0 != 3'd4)) ||
                      ((state == S_IDLE) && cpu_valid && !scrubbing && !cpu_write &&
                       (cpu_col0 != 3'd4)) ||
                      ((state == S_WR) && ((wr_burst2 && (plane_idx == 2'd0)) ||
                                           col_en[plane_idx]));
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
      cl_wdata <= 32'd0;
      cl_datum0 <= 4'b1111;
      cl_wbe   <= 4'hF;
      cl_burst  <= 1'b0;
      cl_wdata2 <= 64'd0;
      req_acc   <= 1'b0;
      for (sp = 0; sp < 4; sp = sp + 1) begin
        patreg[sp] <= 16'h0000;
        sdata[sp]  <= 16'h0000;
        lastvram[sp] <= 32'h0000;
      end
      srcmask <= 16'hFFFF;
      // NP2kai's egc_reset ends in egcshift() at leng 0x000F (io/egc.c:69-80), so
      // `remain` is 16 and the FIRST post-reset produce carries the full bit length:
      // the first store of a guest that never writes 0x4AC/0x4AE after reset must be
      // masked 0xFFFF, not the one-bit 0x0080 a remain of 1 produced.
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
      for (sp = 0; sp < 4; sp = sp + 1) pr_prod_lo[sp] <= 8'h00;
      for (sp = 0; sp < 4; sp = sp + 1) pr_prod_hi[sp] <= 8'h00;
      commit_q     <= 1'b0;
      do_prod_q    <= 1'b0;
      sbyte_held_q <= 1'b0;
      unit_word_q  <= 1'b0;
      unit_lane_q  <= 4'd0;
      acc_access <= 16'hFFF0;
      acc_fgbg   <= 16'h00FF;
      acc_ope    <= 16'h0000;
      acc_fg     <= 16'h0000;
      acc_mask   <= 16'hFFFF;
      acc_bg     <= 16'h0000;
      acc_sft    <= 16'h0000;
      acc_leng   <= 16'h000F;
      shift_arm_pend <= 1'b0;
      scrub          <= 5'd0;
      scrubbing      <= 1'b1;
    end else begin
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      commit_q  <= 1'b0;
      do_prod_q <= 1'b0;
      // The 32-cycle ring scrub (see the port-A mux): walk both copies' 32 words once, then
      // stop. `S_IDLE`'s accept below is held off while `scrubbing`, so the first CPU access
      // after a reset cannot read the ring before it is clean.
      if (scrubbing) begin
        if (scrub == 5'd31) scrubbing <= 1'b0;
        scrub <= scrub + 5'd1;
      end
      // The step_lo outputs the second step needs and the low lane's produce byte are latched at
      // their own step edges, so no produce state carries both mask_step cones or both
      // sub_data lanes. The masks m_lo_c/m_hi_c themselves are wires: m_lo_c is stable (its
      // `dstbit`/`remain` inputs only move at the commit) and m_hi_c is stable from S_STEP_LO's
      // latch onward.
      if (state == S_STEP_LO) begin
        pr_remain_1 <= rem1_c;
        pr_db_lo    <= dblo_c;
      end
      if (state == S_STEP_HI) begin
        pr_remain_n <= remn_c;
        pr_db_n     <= dbn_c;
        for (sp = 0; sp < 4; sp = sp + 1) pr_prod_lo[sp] <= prod_lo[sp];
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

      // Registered state updates for the unit being committed: the read commits in S_EVAL (its
      // response state) and the write in S_COMMIT, both after the three produce steps have run
      // These states are never a fetch cycle (the write's fetch is decided in
      // S_STEP_HI and runs before S_COMMIT), so no `eval_fetch` guard is needed.
      if (produce_commit_step) begin
        if (unit_read && pat_rd) begin
          // COMPAREREAD (OPE bit 13) captures ALL FOUR planes from ONE read; a normal read
          // captures the SELECTED PAT plane only. The split is the MACHINE's, and it decides
          // whether a copy works at all, because the WS_PATREG write that follows takes its
          // datum from this register (NP2kai mem/memegc.c egc_opew case 0x1000 returns
          // &egc.patreg; its byte case returns egc_src). EGCREAD.CSV RD17_P_*
          // (compare-plus-pload-captured-source) reports four DIFFERENT plane values after a
          // compare read - 35DF D010 67D9 4912 - where RD02_PAT_S0..S3
          // (normal-pload-read-updates-selected-PAT-only) leaves the three unselected planes
          // holding their previous values; B05_PLOAD_READ is the same rule from four normal
          // reads (`four-normal-reads-load-four-PAT-planes`). README.TXT states the split in
          // words: "Normal PLOAD_R loads the selected PAT plane only.  Four-plane PAT setup
          // uses four selected reads.  Compare+PLOAD_R is tested separately."
          //
          // The games issue the compare half: TH01's egc_copy_rect_1_to_0_16
          // (rec98/th01/hardware/egcrect.cpp:23 (tmp = egc_chunk(vo))) and TH04/TH05's tiles_render_all
          // (rec98/th04/main/tile/render_a.asm:21 (ax, es:[si])) do ONE read and ONE write per word under
          // egc_setup_copy()'s 0x3100 (COMPAREREAD|WS_PATREG|RL_MEMREAD, egc_impl.hpp:4-12),
          // so a selected-plane-only capture leaves three of the destination's four planes
          // holding whatever the register last held - a background of one flat colour.
          // (tb_pc9821_egc section 1b is the fail-first for it; section 1 covers the normal
          // read's selected-plane-only half through four selected reads.)
          if (ope_cmprd) begin
            for (sp = 0; sp < 4; sp = sp + 1) begin
              if (unit_word) patreg[sp] <= quad_word[sp];
              else if (unit_ext) patreg[sp][15:8] <= quad_byte[sp];
              else patreg[sp][7:0] <= quad_byte[sp];
            end
          end else begin
            if (unit_word) patreg[read_plane] <= quad_word[read_plane];
            else if (unit_ext) patreg[read_plane][15:8] <= quad_byte[read_plane];
            else patreg[read_plane][7:0] <= quad_byte[read_plane];
          end
        end else if (unit_write && pat_wr) begin
          // PLOAD_W captures all four planes (W10_PLOADW_CAPTURE).
          for (sp = 0; sp < 4; sp = sp + 1) begin
            if (unit_word) patreg[sp] <= quad_word[sp];
            else if (unit_ext) patreg[sp][15:8] <= quad_byte[sp];
            else patreg[sp][7:0] <= quad_byte[sp];
          end
        end
        if (do_produce) begin
          srcmask <= srcmask_u;
          // egcshift() zeroes the buffer's bit count as well as its pointers, and the produce
          // calls it whenever the bit length runs out -- so a re-arm discards the leftover stack
          // rather than carrying it into the next arm. The step results are the LATCHED ones.
          stack   <= shifter_rearm ? 6'd0 : stack_n;
          dstbit  <= shifter_rearm ? acc_sft[7:4] : pr_db_n;
          srcbit  <= shifter_rearm ? acc_sft[3:0] : srcbit_n;
          remain  <= shifter_rearm ? ({1'd0, acc_leng[11:0]} + 13'd1) : pr_remain_n;
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
          // The feed's block-RAM write committed in S_FEED, in the port block beside
          // `feed_commit`. (The two lane bytes land in the pipeline registers -
          // pr_prod_lo at the S_STEP_HI edge, pr_prod_hi here - and sdata's assembly
          // from the pair runs one state later, in the consume block below.)
          for (sp = 0; sp < 4; sp = sp + 1) pr_prod_hi[sp] <= prod_hi[sp];
        end
        // Consume-side staging: what the one-state-later consumers need and the unit
        // walk has already moved by then.
        commit_q     <= 1'b1;
        do_prod_q    <= do_produce;
        sbyte_held_q <= (produce_gated || !do_produce);
        unit_word_q  <= unit_word;
        unit_lane_q  <= unit_lane;
      end

      // THE CONSUME EDGE, one state after the commit. sdata's assembly and the read
      // response read the pipeline registers - their cones START at registers - and the
      // staged unit shape places the response piece exactly where the pre-pipeline form
      // placed it at the commit edge. (A non-blocking read of sdata here sees the
      // pre-assembly value, which is exactly the held byte the sbyte_next select wants.)
      if (do_prod_q) begin
        for (sp = 0; sp < 4; sp = sp + 1) sdata[sp] <= sdata_next[sp];
      end
      if (commit_q && unit_read) begin
        if (unit_word_q) resp_data[unit_shift_q +: 16] <= resp_word;
  /* verilator lint_off WIDTHTRUNC */   // the byte lane's offset within the dword. unit_lane_q is in [0,3], so the index is at most
  // 24 and 5 bits hold it; the 7-bit source expression is what Verilator flags.
        else           resp_data[{unit_lane_q, 3'b000} +: 8] <= resp_byte;
  /* verilator lint_on WIDTHTRUNC */
      end

      case (state)
        // The produce's four states. S_FEED writes the unit's source bytes into the
        // ring; S_STEP_LO presents the window's first read and latches the first mask_step;
        // S_STEP_HI consumes the window, latches the low lane's byte and the second mask_step;
        // the COMMIT state (S_EVAL for a read, S_COMMIT for a write) assembles sdata/srcmask and
        // moves the pointers. The produce reads the ring only after the feed's write committed.
        S_FEED:    state <= S_STEP_LO;
        S_STEP_LO: state <= S_STEP_HI;
        // S_STEP_HI has BOTH step masks, so this is where the write's source-fetch decision is
        // made (`need_read_w` needs the mask the produce is about to commit). A READ commits in
        // S_EVAL (its source was already fetched in S_IDLE); a WRITE that needs its destination
        // fetches it here and commits in S_COMMIT afterwards. The read burst is one request for
        // the run [acc_col0, acc_col1], one cl_done per column in column
        // order; a dead column costs no request and a 16-bit unit asks for two columns, not four.
        S_STEP_HI: if (unit_read) state <= S_EVAL;
                   else if (eval_fetch && (acc_col0 != 3'd4)) begin
                     plane_idx <= acc_col0[1:0];
                     cl_write <= 1'b0;
                     cl_burst <= 1'b1;
                     cl_addr  <= {acc_page, unit_dword + {13'd0, acc_col0[1:0]}};
                     cl_wbe   <= acc_be;
                     cl_wdata <= 32'd0;
                     cl_datum0 <= 4'b1111;
                     req_acc  <= 1'b0;
                     state    <= S_RD_RESP;
                   end else begin
                     // No covered column (or no fetch owed): nothing to fetch.
                     if (eval_fetch) dword_valid <= 1'b1;
                     state <= S_COMMIT;
                   end
        // The write's commit state: the produce block above has committed at this edge, so the
        // write pass presents the unit from the registered `sdata`/`srcmask` in S_WR.
        S_COMMIT: begin
          plane_idx <= 2'd0;
          cl_burst  <= 1'b0;
          state     <= S_WR;
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
          acc_access <= reg_access;
          acc_fgbg   <= reg_fgbg;
          acc_ope    <= reg_ope;
          acc_fg     <= reg_fg;
          acc_mask   <= reg_mask;
          acc_bg     <= reg_bg;
          acc_sft    <= reg_sft;
          acc_leng   <= reg_leng;
          // ACCEPT-AND-DECOUPLE: a CPU WRITE is ACCEPTED here and its ready pulses at the
          // next edge; the produce pipeline (S_FEED -> S_STEP_LO -> S_STEP_HI -> S_COMMIT -> S_WR)
          // and its writes to the array then complete BEHIND the CPU. The write-path tail
          // states do not assert ready, so a ready z486 has consumed is never re-presented to
          // it as the next request's accept. Coherency is the stall: the EGC does not accept the
          // next CPU access until it is back in S_IDLE, so a later CPU read always sees the
          // committed dword. A READ keeps its ready in S_EVAL (its data is not ready until the walk
          // has captured it).
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
            cl_wdata <= 32'd0;
            cl_datum0 <= 4'b1111;
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
            // returns to its commit.
            state <= unit_write ? S_COMMIT : S_FEED;
          end else begin
            // The next word of the SAME request; nothing is presented again.
            plane_idx <= plane_idx + 2'd1;
          end
        end

        // The READ's commit state: the produce's pipeline registers capture the unit at this
        // edge and the consume block above assembles the response piece one state later.
        // The write side commits in S_COMMIT instead.
        S_EVAL: begin
          if (more_units) begin
            unit_lane <= next_set;
            unit_word <= next_word;
            // The next unit reuses this access's dword (`dword_valid`), so it produces in place.
            state <= S_FEED;
          end else begin
            state <= S_RESP2;
          end
        end

        // The write pass reads the REGISTERED produce output and presents the unit: as ONE
        // two-column burst when the unit's two columns are both fully masked, else one
        // D1 column per byte of the dword in ascending order, each carrying that byte of every
        // plane the access register enables. A column whose four plane enables are all clear is
        // not a backend access at all, which is how a write of one plane costs one column and not
        // four. Reading `sdata`/`srcmask` from S_WR is what registers the produce's cone.
        S_WR: begin
          if (wr_burst2 && plane_idx == 2'd0) begin
            // The write pass as ONE request for the unit's two consecutive columns
            // now presented here from the registered produce output rather than from the produce
            // step itself.
            cl_burst  <= 1'b1;
            cl_wdata2 <= wb_data2;
            cl_write  <= 1'b1;
            cl_addr   <= {acc_page, unit_dword + {13'd0, wb_c0}};
            cl_wbe    <= 4'hF;
            cl_wdata  <= col_wdata[wb_c0];
            cl_datum0 <= {(col_wdata[wb_c0][31:24] == 8'h00),
                          (col_wdata[wb_c0][23:16] == 8'h00),
                          (col_wdata[wb_c0][15:8]  == 8'h00),
                          (col_wdata[wb_c0][7:0]   == 8'h00)};
            req_acc   <= 1'b0;
            state     <= S_WR_B_ACC;
          end else if (col_en[plane_idx]) begin
            cl_burst <= 1'b0;
            cl_write <= 1'b1;
            cl_addr  <= {acc_page, unit_dword + {13'd0, plane_idx}};
            cl_wbe   <= col_wbe[plane_idx];
            cl_wdata <= col_wdata[plane_idx];
            cl_datum0 <= {(col_wdata[plane_idx][31:24] == 8'h00),
                          (col_wdata[plane_idx][23:16] == 8'h00),
                          (col_wdata[plane_idx][15:8]  == 8'h00),
                          (col_wdata[plane_idx][7:0]   == 8'h00)};
            req_acc  <= 1'b0;
            state    <= S_WR_ACC;
          end else if (plane_idx == 2'd3) begin
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
          if (plane_idx != 2'd3) begin
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

        // The write pass's two-column burst is presented by S_EVAL itself.
        // POSTED: the pass advances on the ACCEPT, not on `cl_done`, so the write
        // drains in the WCB while the next unit's read proceeds; the WCB's read-after-write
        // covers the gap.
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

        // The response piece assembles at this state's closing edge (the consume block
        // above), so the read's completion and presentation both move one cycle later than
        // the pre-pipeline form: cpu_ready registers here (visible in S_HOLD) and
        // cpu_dout/cpu_resp_valid register in S_HOLD (visible the cycle after). That one
        // cycle is the pipelined produce's whole guest-visible cost; writes are unchanged.
        S_RESP2: begin
          cpu_ready <= 1'b1;
          state <= S_HOLD;
        end

        // One cycle only, and UNCONDITIONAL (R6): `if (unit_write || !cpu_valid)` left this
        // state by observing a level drop, which is the banned shape - the GRCG's G_HOLD is the
        // same state one module over and is unconditional, and the EGC's own read arm sits here
        // for a cycle after its response registers either way. What the read arm needs is the
        // CPU's accept gap, not the level: src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0` clears it
        // at the ready edge, and a direct read's own `direct_rd_pending` keeps the next request off the
        // bus until the response lands (since the pipelined produce the response registers at
        // this state's closing edge, one cycle later than the pre-pipeline form registered it
        // in S_RESP2), so the same request cannot be re-presented before S_IDLE is reached.
        // The assertion in the VERILATOR block below pins it: a request taken twice would be
        // the double-serve this change could allow.
        S_HOLD: begin
          // The read response lands one cycle after the ready above (see S_RESP2); a
          // write has no response and pulses nothing here.
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
  // R6/R8: THE UNCONDITIONAL S_HOLD BUBBLE'S CONTRACT (docs/single-cycle-event-
  // discipline.md R6/R8). S_HOLD is one cycle by construction - it no
  // longer observes cpu_valid - and that is safe because the CPU's own accept gap keeps a
  // completed request off the bus (src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0` clears it at
  // the ready edge). Both halves are pinned here; they cost nothing in synthesis and run in
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
