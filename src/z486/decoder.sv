//
// Instruction Decoder
// D1 structural decode and entry point lookup, D2 literal capture and issue set-up
//

`include "z486_platform.svh"
module decoder
    import z486_pkg::*;
(
    input               clk,
    input               reset_n,

    // Prefetch queue interface (two-cursor protocol)
    input        [63:0] k1q,            // registered raw window at the D1 cursor
    input        [63:0] k1q_early,      // speculative next window for entry-ROM preread
    input        [5:0]  k1q_avail,      // bytes fetched beyond the D1 cursor
    input        [5:0]  k1q_avail_raw,  // its two bounds: k1q_avail =
    input        [5:0]  k1q_avail_lim,  //   min(k1q_avail_raw, k1q_avail_lim)
    output       [3:0]  k1p_adv,        // D1 cursor advance (0-11 bytes: a prefix,
                                        //   or the whole rest of the instruction
                                        //   at handoff - struct AND literal bytes)
    output       [3:0]  k1p_preread_adv,// structural advance without D2 backpressure
    output       [3:0]  k1p_adv_u,      // the advance if D1 steps (a prefix/0F: 1,
                                        //   else the handoff's), byte availability aside
    output              k1p_step_ok,    // the preread cursor steps by it this cycle
    output              k1p_commit_u,   // and the committed cursor steps with it
    input        [31:0] k2q,            // 4 bytes at pop_cursor + k2p_off
    input        [5:0]  k2q_avail,      // bytes fetched beyond that point
    output       [4:0]  k2p_off,        // literal offset from the pop cursor
    output              pop_now,        // instruction completed D2: pop its bytes
    output       [4:0]  pop_len,        //   (registered length from the skeleton)

    // Mode signals
    input               D,              // Default operand/address size (CS.D bit)
    input               pe_enable,      // Protected mode enable (CR0.PE)

    // Control signals
    input               q_flush,        // Flush decoder on branch
    input               i_issue,        // D2 transfers into EX

    // Decoded instruction output
    output dec_entry_t  i_bus,          // Decoded instruction
    output              decq_empty,     // Legacy name: unified D2 has no skeleton
    output              decq_has_jmp_call, // JMP/CALL rel in flight (halt speculative prefetch)
    // Microsequencer ROM port B: the skeleton's first word is read ahead
    output              pb_load,        // the skeleton takes a new instruction this edge
    output       [11:0] pb_entry,       //   and this is its entry point

    // Unified D2 payload and empty-pipe D1 launch
    output dec_entry_t  d2_entry,       // instruction completing D2
    output              d2_push,        // d2_entry is complete this cycle
    output              d1_issue_direct,// handoff has no older D2 skeleton
    output dec_entry_t  d1_issue_entry, // live structural entry for empty-pipe launch
    output       [31:0] d2_branch_disp, // a relative branch's displacement, as
                                        //   (branch_rel8 ? sext8 : ) d2_entry's
    output              fetch_blocked   // decoder is waiting for unfetched bytes
);

typedef enum logic [1:0] {
    LIT_NONE = 2'd0,
    LIT_IMM  = 2'd1,
    LIT_DISP = 2'd2
} lit_kind_t;

// The skeleton: a structurally-complete entry plus the literal plan.
// Literal fields (immediate/displacement) and the entry point are pending.
typedef struct packed {
    dec_entry_t entry;
    lit_kind_t  lit1_kind;
    lit_kind_t  lit2_kind;
    logic [2:0] lit1_size;
    logic [2:0] lit2_size;
    logic       lit1_sign_extend;
    logic       lit2_sign_extend;
    logic       lit1_mirror_disp;
    logic       lit2_mirror_disp;
    logic       fields_fit;          // both literal fields fit the first D2 window
    logic       need_sib;
    logic [4:0] body_len;            // bytes from the opcode on (no prefixes, no 0F)
    logic [4:0] adv_len;             // body_len including a SIB byte in view (D1 cursor)
    logic [2:0] pending_imm_size;
    logic       pending_imm_sign_extend;
} decoder_work_t;

`include "pla_control.svh"
`include "pla_entry.svh"
`include "length_table.svh"

//=============================================================================
// D1 - structural decode
//=============================================================================

// Prefix state is not part of dec_entry_t until a non-prefix opcode is decoded.
logic        prefix_66;
logic        prefix_67;
logic        prefix_0f;
logic        prefix_rep;
logic [3:0]  prefix_count;
logic [1:0]  prefix_rep_lock;
logic [2:0]  prefix_seg;
reg         code32_r;     // Local CS.D copy; frontend flush hides its one-cycle update latency.
reg         skel_v;       // D2 holds an instruction


// Byte aliases at the D1 cursor.  The cursor does not advance until the
// skeleton handoff, so during the SIB sub-cycle the sib byte is byte 2.
wire [7:0] opcode = k1q[7:0];
wire [7:0] modrm  = k1q[15:8];
wire [7:0] sib_b  = k1q[23:16];
wire       data32 = code32_r ^ prefix_66;
wire       addr32 = code32_r ^ prefix_67;
wire [15:0] entry_rom_sel;

// min(a, b) >= x  <=>  a >= x && b >= x: every D1 availability test compares
// both bounds of k1q_avail, so prefetch's min (a compare and a 6-bit select)
// is not in front of the compares on the pf_rptr -> k1q_avail -> entry-ROM
// address path. tests/equiv/k1_avail_ge.v proves the identity.
function automatic logic avail_ge(input logic [5:0] raw, input logic [5:0] lim,
                                  input logic [5:0] need);
    avail_ge = (raw >= need) && (lim >= need);
endfunction
// synthesis translate_off
always @(posedge clk)
    if (reset_n && (k1q_avail !== ((k1q_avail_raw > k1q_avail_lim) ? k1q_avail_lim : k1q_avail_raw)))
        $fatal(1, "decoder: k1q_avail %0d is not min(%0d, %0d)",
               k1q_avail, k1q_avail_raw, k1q_avail_lim);
// synthesis translate_on

wire consume_prefix = !prefix_0f && is_prefix(opcode) &&
                      avail_ge(k1q_avail_raw, k1q_avail_lim, 6'd1);
wire consume_0f     = !prefix_0f && (opcode == 8'h0f) &&
                      avail_ge(k1q_avail_raw, k1q_avail_lim, 6'd1);

// The entries recipe_effective_entry (ucode_recipes.svh, generated) redirects,
// one compare each; and that function with each `entry == C` replaced by its
// hit bit (the hits are one-hot or zero: the constants are distinct).
function automatic logic [5:0] ov_hits(input logic [11:0] e);
    ov_hits = {e == 12'h0B6, e == 12'h04E, e == 12'h04A,
               e == 12'h53C, e == 12'h4C1, e == 12'h4D7};
endfunction
function automatic logic [11:0] recipe_effective_entry_hit(
    input logic [11:0] entry,
    input logic [5:0]  hit,
    input logic [7:0]  opcode,
    input logic [7:0]  modrm
);
    recipe_effective_entry_hit = entry;
    if (hit[0] && ((opcode == 8'hD8) || ((opcode == 8'hD9) && (modrm[5:3] == 3'd0))))
        recipe_effective_entry_hit = 12'h9C5;
    if (hit[1] && (modrm[7:6] == 2'b11))
        recipe_effective_entry_hit = 12'h9D1;
    if (hit[2] && (modrm[7:6] != 2'b11) && ((opcode == 8'hD9) || (opcode == 8'hDB)) &&
        ((modrm[5:3] == 3'd2) || (modrm[5:3] == 3'd3)))
        recipe_effective_entry_hit = 12'h9D3;
    if (hit[3] && (modrm[7:6] != 2'b11))
        recipe_effective_entry_hit = 12'h9CB;
    if (hit[4] && (modrm[7:6] != 2'b11) &&
        ((((opcode == 8'hF6) || (opcode == 8'hF7)) && ((modrm[5:3] == 3'd2) || (modrm[5:3] == 3'd3))) ||
         (((opcode == 8'hFE) || (opcode == 8'hFF)) && ((modrm[5:3] == 3'd0) || (modrm[5:3] == 3'd1)))))
        recipe_effective_entry_hit = 12'h9CE;
    if (hit[5] && (opcode == 8'h90))
        recipe_effective_entry_hit = 12'h9C9;
endfunction
// ov_hits of the second-level group ROM's word, as a function of that ROM's
// own address {group, ModR/M.reg, memory}: the ROM is constant, so the hit
// vector is too, and this decode runs beside the ROM read instead of behind
// it (the k1q -> group ROM -> entry compare -> overlay -> port-B address
// cone loses the 12-bit compare). tests/equiv/group_overlay_addr.v proves
// group_ov_hits(a) == ov_hits(group_entry_rom[a]) for every address against
// the shipped pla_group_entry.hex, so a regenerated ROM that this table does
// not follow is refuted there.
function automatic logic [5:0] group_ov_hits(input logic [9:0] grom_addr);
    begin
        // The six words' address sets are disjoint (one word per address).
        casez (grom_addr)
            10'b101000???1: group_ov_hits = 6'b000001;
            10'b1101110001: group_ov_hits = 6'b000001;
            10'b1010110001: group_ov_hits = 6'b000001;
            10'b1010?????0: group_ov_hits = 6'b000010;
            10'b110110???0: group_ov_hits = 6'b000010;
            10'b101?000??0: group_ov_hits = 6'b000010;
            10'b10101?001?: group_ov_hits = 6'b000010;
            10'b1101110011: group_ov_hits = 6'b000010;
            10'b101100001?: group_ov_hits = 6'b000010;
            10'b1101111001: group_ov_hits = 6'b000010;
            10'b101010?01?: group_ov_hits = 6'b000010;
            10'b11011101?1: group_ov_hits = 6'b000100;
            10'b10101101?1: group_ov_hits = 6'b000100;
            10'b000000???1: group_ov_hits = 6'b001000;
            10'b01010?00?1: group_ov_hits = 6'b010000;
            10'b01011001?1: group_ov_hits = 6'b010000;
            10'b001000???0: group_ov_hits = 6'b100000;
            default: group_ov_hits = 6'd0;
        endcase
    end
endfunction

decoder_work_t struct_work;
logic [2:0]    struct_len;
// Some simulators do not include signals referenced only inside a task in an
// always_comb sensitivity set. Pass the task's live decode inputs explicitly
// so structural decode is reevaluated when the D1 window advances.
wire [53:0] struct_work_inputs = {
    opcode, modrm, sib_b, prefix_0f, prefix_rep, prefix_count, data32, addr32,
    prefix_rep_lock, prefix_seg, entry_rom_sel, pe_enable
};
logic [11:0]   struct_ov_entry; // the overlaid entry point, taken per entry source
always_comb build_struct_work(struct_work_inputs, struct_work, struct_len, struct_ov_entry);

wire struct_bytes_ok = avail_ge(k1q_avail_raw, k1q_avail_lim, {3'b000, struct_len});

// skel_free: d2_done's terms are k2q_avail / out_full / phase - all
// register-derived, never i_issue (L1) - so the same-edge free is legal.
wire d2_done;
// D1 holds its instruction until D2 takes it (no buffer between them).
wire d1_slot_ready = !skel_v || i_issue;

// D1 decodes opcode, ModR/M and SIB together, as decoder 31 always takes
// three bytes on K1Q (US5293592). An instruction with a SIB byte waits until
// that byte is in view; the decoded address mode then goes to D2 in the
// skeleton, where the address is formed.
wire sib_in_view = avail_ge(k1q_avail_raw, k1q_avail_lim, 6'd3);
wire d1_struct_ready = struct_bytes_ok &&
                       (!struct_work.need_sib || sib_in_view);
wire d1_preread_handoff = !consume_prefix && !consume_0f && d1_struct_ready;
wire d1_handoff = !consume_prefix && !consume_0f && d1_slot_ready &&
                  d1_struct_ready;

// Preread the macro-entry PLA from M10K one cycle before D1 handoff. The
// speculative cursor deliberately ignores D2 backpressure; when D1 cannot
// advance, retain the entry corresponding to its current window. This removes
// both the combinational PLA and D2/VIPT readiness from the ucode-ROM address.
logic prefix_0f_early, prefix_rep_early;
always_comb begin
    prefix_0f_early = prefix_0f;
    prefix_rep_early = prefix_rep;
    if (q_flush) begin
        prefix_0f_early = 1'b0;
        prefix_rep_early = 1'b0;
    end else begin
        if (consume_0f)
            prefix_0f_early = 1'b1;
        else if (consume_prefix && ((opcode == 8'hf2) || (opcode == 8'hf3)))
            prefix_rep_early = 1'b1;
        if (d1_preread_handoff) begin
            prefix_0f_early = 1'b0;
            prefix_rep_early = 1'b0;
        end
    end
end

wire [9:0] entry_rom_addr = {k1q_early[7:0],
                             prefix_rep_early, prefix_0f_early};
`Z486_BLOCK_RAM reg [63:0] entry_rom [0:1023];
initial $readmemh("pla_entry_rom.hex", entry_rom);
reg [63:0] entry_rom_q;
always_ff @(posedge clk)
    entry_rom_q <= entry_rom[entry_rom_addr];

reg [63:0] entry_rom_hold_r;
reg        entry_rom_use_q_r;
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        entry_rom_hold_r <= 64'd0;
        entry_rom_use_q_r <= 1'b0;
    end else begin
        if (entry_rom_use_q_r)
            entry_rom_hold_r <= entry_rom_q;
        entry_rom_use_q_r <= q_flush || (k1p_adv == k1p_preread_adv);
    end
end
wire [63:0] entry_rom_current = entry_rom_use_q_r
                              ? entry_rom_q : entry_rom_hold_r;
assign entry_rom_sel = entry_rom_current[{data32, pe_enable}*16 +: 16];

// The first-level group code already encodes data-size and opcode-map mode.
// Keep the ModR/M-dependent second-level entry table in an asynchronous ROM so
// Quartus can constant-fold it as one compact lookup rather than retaining the
// original deep priority PLA on the D1 -> microcode-address cone.
`Z486_DISTRIBUTED_RAM reg [15:0] group_entry_rom [0:1023];
initial $readmemh("pla_group_entry.hex", group_entry_rom);

decoder_work_t handoff_work;
always_comb begin
    handoff_work = struct_work.need_sib ? capture_sib(struct_work, sib_b)
                                        : struct_work;
end
// A LOCK-prefixed RMW keeps its original routine: the RMW_FAST overlays read
// the operand from the L1 and write it through the direct store port, while a
// locked RMW must read memory under LOCK# (lock_insn, the locked-read path).
// LOCK is #UD on every other overlay's opcode, so no overlay is taken under it.
// The overlay redirect taken per entry source in structural decode
// (struct_ov_entry; capture_sib leaves the entry, opcode and ModR/M alone):
// each arm of the entry mux carries its own overlaid entry, the group ROM's
// hits decoded from its address (group_ov_hits), so the D1 entry -> overlay ->
// port-B ROM address cone (k1q -> group ROM -> entry mux -> d1_issue_entry)
// has no entry compare behind the ROM or the mux.
// tests/equiv/overlay_entry_hit.v proves recipe_effective_entry_hit(e,
// ov_hits(e), ...) equal to the generated recipe_effective_entry(e, ...);
// tests/equiv/group_overlay_addr.v proves the group arm's address form; a
// translate_off fuse holds struct_ov_entry == the overlay of
// struct_work.entry.entry_point every non-flush cycle.
wire [11:0] handoff_overlay_entry = struct_ov_entry;
// synthesis translate_off
// The group arm's address form needs the group row to be the live opcode's
// (the entry-ROM word is current), which the entry-ROM fuse holds in every
// non-flush cycle; the same qualification here.
always @(posedge clk)
    if (reset_n && !q_flush && (^entry_rom_sel !== 1'bx) &&
        (struct_ov_entry !== recipe_effective_entry_hit(
                        struct_work.entry.entry_point,
                        ov_hits(struct_work.entry.entry_point),
                        struct_work.entry.opcode, struct_work.entry.modrm)))
        $fatal(1, "D1 OVERLAY ENTRY MISMATCH: ov=%03x entry=%03x op=%02x modrm=%02x ref=%03x sel=%04x",
               struct_ov_entry, struct_work.entry.entry_point,
               struct_work.entry.opcode, struct_work.entry.modrm,
               recipe_effective_entry_hit(struct_work.entry.entry_point,
                        ov_hits(struct_work.entry.entry_point),
                        struct_work.entry.opcode, struct_work.entry.modrm), entry_rom_sel);
// synthesis translate_on
wire [11:0] handoff_entry_point = (handoff_work.entry.rep_lock == PREFIX_LOCK)
                                ? handoff_work.entry.entry_point
                                : handoff_overlay_entry;
decoder_work_t handoff_d2;
always_comb begin
    handoff_d2 = handoff_work;
    handoff_d2.entry.entry_point = handoff_entry_point;
    // recipe_entry_action decodes the action from the raw entry with the
    // overlay qualifiers beside it (proved equal to recipe_action of
    // handoff_entry_point by tests/equiv/recipe_entry_action.v), so the action
    // compares do not wait for the overlay's 12-bit entry mux.
    handoff_d2.entry.ucode_action = recipe_entry_action(
        handoff_work.entry.entry_point,
        handoff_work.entry.opcode,
        handoff_work.entry.modrm,
        handoff_work.entry.rep_lock == PREFIX_LOCK);
    // Resolve the direct ALU memory-load class in D1. Re-decoding opcode and
    // ModR/M from i_bus put this classification in series with VIPT hit
    // resolution and same-edge chained issue on the microcode-ROM address path.
    handoff_d2.entry.vipt_alu = !handoff_work.entry.has_0f &&
        (handoff_work.entry.opcode[7:6] == 2'b00) &&
        !handoff_work.entry.opcode[2] && handoff_work.entry.opcode[1] &&
        handoff_work.entry.has_modrm &&
        (handoff_work.entry.modrm[7:6] != 2'b11) &&
        (handoff_work.entry.opcode[5:3] != 3'b111);
    // The recipe hazard mask is derived from this registered structural entry
    // during D2. Keeping it out of D1 avoids serializing entry-PLA decode and
    // mask generation on the raw-window-to-skeleton path.
    handoff_d2.entry.recipe_gpr_read_mask = 8'h00;
    {handoff_d2.entry.ea_index_onehot, handoff_d2.entry.ea_base_onehot} =
        dec_ea_onehots(handoff_work.entry);
    // Match the i486 complex-EA rule: a displacement on an address that also
    // reads base and index requires a second D2 addition cycle. POP r/m may
    // add a synthetic post-pop ESP displacement even when none was encoded.
    handoff_d2.entry.ea_complex =
        (|handoff_d2.entry.ea_base_onehot) &&
        (|handoff_d2.entry.ea_index_onehot) &&
        ((handoff_work.lit1_kind == LIT_DISP) ||
         (handoff_work.lit2_kind == LIT_DISP) ||
         handoff_work.entry.ea_uses_post_pop_esp);
    handoff_d2.entry.mem_seg = handoff_work.entry.stack_op ? SEG_SS :
        apply_seg_override_type(
            calc_default_seg_type(handoff_work.entry.modrm,
                                  handoff_work.entry.sib,
                                  handoff_work.entry.has_sib,
                                  handoff_work.entry.addr32),
            handoff_work.entry.seg);
    handoff_d2.fields_fit = (handoff_work.lit2_kind == LIT_NONE) ||
        ({1'b0, handoff_work.lit1_size} + {1'b0, handoff_work.lit2_size} <= 4'd4);
end
// First literal byte, as an offset from the POP cursor (prefix bytes are
// not popped until D2 completes): total length minus the literal bytes.
wire [4:0] handoff_lit_off = handoff_work.entry.length -
                             ({2'b00, handoff_work.lit1_size} +
                              {2'b00, handoff_work.lit2_size});
// D1 cursor advance at handoff: the whole REST of the instruction (struct
// bytes AND the literal bytes D2 will capture), so the cursor lands on the
// next instruction's first byte.  It may pass not-yet-fetched literal
// bytes; k1q_avail clamps to 0 in that case and D1 waits for the fill.
// Prefix and 0F bytes took their own D1 clocks and already advanced the
// cursor, so the advance is the body length alone, as code control 36
// advances K1P (US5293592). No prefix arithmetic sits in the K1Q loop.
// The SIB byte's length term is part of D1's two-table length (adv_len).
wire [4:0] handoff_adv = struct_work.adv_len;
// Relative to the registered raw D1 window, the first literal follows only
// opcode/ModR/M/SIB.
wire [4:0] handoff_raw_lit_off_w = handoff_work.body_len -
                                   ({2'b00, handoff_work.lit1_size} +
                                    {2'b00, handoff_work.lit2_size});
// synthesis translate_off
always @(posedge clk)
    if (reset_n && (d1_handoff || d1_preread_handoff) &&
        (handoff_work.entry.length !=
         handoff_work.body_len + {1'b0, prefix_count} + (prefix_0f ? 5'd1 : 5'd0)))
        $fatal(1, "D1 body length %0d + prefixes disagrees with length %0d",
               handoff_work.body_len, handoff_work.entry.length);
always @(posedge clk)
    if (reset_n && (d1_handoff || d1_preread_handoff) &&
        (handoff_adv != handoff_work.body_len))
        $fatal(1, "D1 cursor advance %0d disagrees with the captured length %0d",
               handoff_adv, handoff_work.body_len);
// synthesis translate_on
wire [1:0] handoff_raw_lit_off = handoff_raw_lit_off_w[1:0];

// The entry PLA result is valid during D1 handoff, one cycle before the
// registered skeleton completes D2. It directly launches an empty D2 pipe.
wire [3:0] handoff_lit_size = {1'b0, handoff_work.lit1_size} +
                              {1'b0, handoff_work.lit2_size};
wire handoff_one_d2 = (handoff_work.lit2_kind == LIT_NONE ||
                       handoff_lit_size <= 4'd4) &&
                      avail_ge(k1q_avail_raw, k1q_avail_lim, {1'b0, handoff_adv});
// The raw window end is the literal offset plus the literal bytes D2 takes in
// its first step: (body_len - (lit1 + lit2)) + (fits ? lit1 + lit2 : lit1).
// The literals are part of the body (body_len >= lit1 + lit2, a fuse below),
// so that is body_len when both literals fit and body_len - lit2 otherwise,
// without the literal-offset subtract and the re-add in series on the
// k1q -> literal sizes -> skel_window_valid_r path.
// tests/equiv/raw_window_end.v proves it equal to the two-step form under
// that premise.
function automatic logic [5:0] raw_window_end(input logic [4:0] body_len,
                                              input logic [2:0] lit1_size,
                                              input logic [2:0] lit2_size,
                                              input logic lit2_none);
    raw_window_end = (lit2_none || ({1'b0, lit1_size} + {1'b0, lit2_size} <= 4'd4))
                   ? {1'b0, body_len}
                   : {1'b0, body_len - {2'b00, lit2_size}};
endfunction
wire [5:0] handoff_raw_end = raw_window_end(handoff_work.body_len,
                                            handoff_work.lit1_size,
                                            handoff_work.lit2_size,
                                            handoff_work.lit2_kind == LIT_NONE);
wire handoff_raw_valid = avail_ge(k1q_avail_raw, k1q_avail_lim, handoff_raw_end);
// synthesis translate_off
wire [3:0] handoff_raw_need = (handoff_work.lit2_kind == LIT_NONE ||
                               handoff_lit_size <= 4'd4)
                            ? handoff_lit_size
                            : {1'b0, handoff_work.lit1_size};
always @(posedge clk)
    if (reset_n && d1_handoff &&
        (({1'b0, handoff_work.body_len} < {2'b00, handoff_work.lit1_size} +
                                          {2'b00, handoff_work.lit2_size}) ||
         (handoff_raw_end != {1'b0, handoff_raw_lit_off_w} + {2'b00, handoff_raw_need})))
        $fatal(1, "D1: raw window end %0d: body %0d lit1 %0d lit2 %0d",
               handoff_raw_end, handoff_work.body_len,
               handoff_work.lit1_size, handoff_work.lit2_size);
// synthesis translate_on
// Launch the synchronous ROM as soon as structural decode owns an empty D2.
// D2 holds the returned word while late or second literals are captured.
assign d1_issue_direct = d1_handoff && !skel_v;
always_comb begin
    d1_issue_entry = handoff_d2.entry;
end

// TIMING: no !q_flush in the advance/pop legs. q_flush carries the deep uc_exec/mem-block cone
assign k1p_adv = (consume_prefix || consume_0f) ? 4'd1 :
                d1_handoff ? handoff_adv[3:0] :
                4'd0;
assign k1p_preread_adv = (consume_prefix || consume_0f) ? 4'd1 :
                        d1_preread_handoff ? handoff_adv[3:0] :
                        4'd0;
// The same advances split into the step's size (k1p_adv_u, from the opcode
// and the length tables) and whether the byte-availability tests let D1 take
// it (k1p_step_ok; k1p_commit_u adds D2's backpressure), so prefetch forms
// the advanced D1 window from k1p_adv_u and picks it or the held window last:
// the pf pointers -> k1q_avail -> d1_struct_ready -> cursor adder -> window
// mux -> k1q_r / entry-ROM address cone ends at that pick. A prefix or 0F
// steps when one byte is in view; the instruction when d1_struct_ready (which
// needs a byte, so the two are exclusive with an empty view):
//   k1p_preread_adv == (k1p_step_ok ? k1p_adv_u : 0), and k1p_adv equals it
//   whenever k1p_commit_u or !k1p_step_ok (else k1p_adv is 0).
// tests/equiv/kpre_window_split.v proves the windows prefetch builds from
// them equal to the ones it built from k1p_adv / k1p_preread_adv; fuses
// below hold these identities every cycle.
wire d1_pre_u = !prefix_0f && (is_prefix(opcode) || (opcode == 8'h0f));
assign k1p_adv_u    = d1_pre_u ? 4'd1 : handoff_adv[3:0];
assign k1p_step_ok  = d1_pre_u ? avail_ge(k1q_avail_raw, k1q_avail_lim, 6'd1) : d1_struct_ready;
assign k1p_commit_u = k1p_step_ok && (d1_pre_u || d1_slot_ready);
// synthesis translate_off
always @(posedge clk)
    if (reset_n && ((k1p_preread_adv !== (k1p_step_ok ? k1p_adv_u : 4'd0)) ||
                    (k1p_adv !== ((k1p_step_ok && (d1_pre_u || d1_slot_ready)) ? k1p_adv_u : 4'd0))))
        $fatal(1, "D1 split advance mismatch: adv=%0d pre=%0d u=%0d ok=%b commit=%b",
               k1p_adv, k1p_preread_adv, k1p_adv_u, k1p_step_ok, k1p_commit_u);
// synthesis translate_on

//=============================================================================
// The skeleton register (D1 -> D2 pipeline boundary; Step 2's lookahead)
//=============================================================================

decoder_work_t skel;
reg [4:0]      skel_lit_off;
reg [31:0]     skel_raw_hi_r;    // upper half of the opcode-relative D1 window
reg [1:0]      skel_raw_lit_off_r;
reg [31:0]     skel_lit_r;       // shared low raw half or pop-relative literal
reg            skel_window_valid_r;
reg            skel_window_raw_r; // skel_lit_r is the low half of the D1 window
wire           head_v = skel_v;  // temporary trace compatibility alias

// The raw literal window registers on the D1 handoff edge.
wire incoming_capture = d1_handoff;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        code32_r <= 1'b0;
        skel_v <= 1'b0;
        prefix_66 <= 1'b0;
        prefix_67 <= 1'b0;
        prefix_0f <= 1'b0;
        prefix_rep <= 1'b0;
        prefix_count <= 4'd0;
        prefix_rep_lock <= PREFIX_NOREPLOCK;
        prefix_seg <= PREFIX_NOSEG;
    end else if (q_flush) begin
        code32_r <= D;
        skel_v <= 1'b0;
        prefix_66 <= 1'b0;
        prefix_67 <= 1'b0;
        prefix_0f <= 1'b0;
        prefix_rep <= 1'b0;
        prefix_count <= 4'd0;
        prefix_rep_lock <= PREFIX_NOREPLOCK;
        prefix_seg <= PREFIX_NOSEG;
    end else begin
        code32_r <= D;
        if (consume_prefix || consume_0f) begin
            if (consume_0f) begin
                prefix_0f <= 1'b1;
            end else begin
                prefix_count <= prefix_count + 4'd1;
                unique case (opcode)
                    8'h66: prefix_66 <= 1'b1;
                    8'h67: prefix_67 <= 1'b1;
                    // LOCK is sticky against a REP/REPNE in the same
                    // prefix run: the group shares one field, and LOCK on a
                    // string instruction must still raise #UD (Intel486 PRM,
                    // LOCK: "#UD if LOCK is used with an instruction not
                    // listed"), whichever prefix comes last.
                    8'hf0: prefix_rep_lock <= PREFIX_LOCK;
                    8'hf2: begin
                        if (prefix_rep_lock != PREFIX_LOCK)
                            prefix_rep_lock <= PREFIX_REPNE;
                        prefix_rep <= 1'b1;
                    end
                    8'hf3: begin
                        if (prefix_rep_lock != PREFIX_LOCK)
                            prefix_rep_lock <= PREFIX_REP;
                        prefix_rep <= 1'b1;
                    end
                    8'h26, 8'h2e, 8'h36, 8'h3e, 8'h64, 8'h65:
                        prefix_seg <= prefix_seg_code(opcode);
                    default: ;
                endcase
            end
        end

        if (d1_handoff) begin
            // The skeleton carries the prefix state; clear for the next one.
            prefix_66 <= 1'b0;
            prefix_67 <= 1'b0;
            prefix_0f <= 1'b0;
            prefix_rep <= 1'b0;
            prefix_count <= 4'd0;
            prefix_rep_lock <= PREFIX_NOREPLOCK;
            prefix_seg <= PREFIX_NOSEG;
        end

        // D2 takes D1's instruction when it is empty or its instruction issues.
        if (d1_handoff) begin
            skel <= handoff_d2;
            skel_v <= 1'b1;
            skel_lit_off <= handoff_lit_off;
        end else if (i_issue) begin
            skel_v <= 1'b0;
        end
    end
end

//=============================================================================
// D2 - literal capture + entry resolution
//=============================================================================

// Phase A = fields as handed off; phase B = field A captured (workB holds
// the merged entry), literal window advanced by lit1_size.
reg            d2_phaseB;
decoder_work_t workB;

wire [2:0] sizeA    = skel.lit1_size;
wire [2:0] sizeB    = skel.lit2_size;
wire       has_litA = (skel.lit1_kind != LIT_NONE);
wire       has_litB = (skel.lit2_kind != LIT_NONE);
wire [3:0] sizeAB   = {1'b0, sizeA} + {1'b0, sizeB};

// Once field A is in the registered window, the live literal port is free to
// preread field B while D2 interprets A.
wire d2_window_valid = skel_window_valid_r;
wire prefetch_fieldB = skel_v && d2_window_valid && !d2_phaseB &&
                       has_litB && !skel.fields_fit;
wire [4:0] resident_lit_off = skel_lit_off +
                              ((d2_phaseB || prefetch_fieldB)
                                  ? {2'b00, sizeA} : 5'd0);
assign k2p_off = resident_lit_off;

// D1 carries raw bytes, not parsed literals. D2 selects the literal start from
// the registered window; the second field uses the live literal port only when
// both fields do not fit in this 32-bit view.
decoder_work_t capA;
decoder_work_t capAB;
decoder_work_t capB;
wire [31:0] skel_raw_lit_win =
    skel_raw_lit_off_r == 2'd0 ? skel_lit_r :
    skel_raw_lit_off_r == 2'd1 ? {skel_raw_hi_r[7:0],  skel_lit_r[31:8]}  :
    skel_raw_lit_off_r == 2'd2 ? {skel_raw_hi_r[15:0], skel_lit_r[31:16]} :
                                 {skel_raw_hi_r[23:0], skel_lit_r[31:24]};
wire [31:0] skel_lit_win = skel_window_raw_r ? skel_raw_lit_win : skel_lit_r;
// A relative branch (Jcc, JMP, CALL rel) has one literal, a displacement (or
// an immediate that mirrors into it), starting at raw offset 1 (the opcode is the
// whole structural part; a 0F was consumed as a prefix) - tests/equiv/
// branch_lit_plan.v proves that plan from the decode tables. So its
// displacement is the registered window at a constant offset, sized by the
// registered skeleton: the speculative branch-target cone (literal offset ->
// 4:1 window mux -> capture -> D2 merge -> spec_disp -> target adder -> line
// compares -> spec launch) starts at registers. tests/equiv/
// spec_branch_disp.v proves it equal to the d2_entry displacement form under
// that plan; a translate_off fuse holds it at every D2 completion of a
// relative branch.
wire [31:0] skel_branch_win = skel_window_raw_r ? {skel_raw_hi_r[7:0], skel_lit_r[31:8]}
                                                : skel_lit_r;
assign d2_branch_disp = skel.entry.branch_rel8
                      ? {{24{skel_branch_win[7]}}, skel_branch_win[7:0]}
                      : literal_value(skel_branch_win, skel.lit1_size, skel.lit1_sign_extend);
wire [31:0] winB = (sizeA == 3'd1) ? { 8'h00, skel_lit_win[31:8]}  :
                   (sizeA == 3'd2) ? {16'h0,  skel_lit_win[31:16]} :
                   (sizeA == 3'd3) ? {24'h0,  skel_lit_win[31:24]} : 32'h0;
always_comb begin
    capA  = capture_literal(skel, skel_lit_win,
                            skel.lit1_kind, skel.lit1_size,
                            skel.lit1_sign_extend, skel.lit1_mirror_disp);
    capAB = capture_literal(capA, winB, capA.lit2_kind, capA.lit2_size,
                            capA.lit2_sign_extend, capA.lit2_mirror_disp);
    capB  = capture_literal(workB, skel_lit_win,
                            workB.lit2_kind, workB.lit2_size,
                            workB.lit2_sign_extend, workB.lit2_mirror_disp);
end

wire       finishing = d2_phaseB || skel.fields_fit;
wire [3:0] need_now  = d2_phaseB ? {1'b0, sizeB} :
                       !has_litA ? 4'd0 :
                       skel.fields_fit ? sizeAB : {1'b0, sizeA};
wire       bytes_ok  = (k2q_avail >= {2'b00, need_now});
wire       d2_can    = skel_v && d2_window_valid;
wire       d2_complete = d2_can && finishing;
assign     d2_done   = i_issue;
// Field A may capture while the output side is full (no push happens here).
wire       d2_stepA  = d2_can && !finishing;
wire       d2_late_capture = skel_v && !d2_window_valid && bytes_ok;

// A retained prefetch fault becomes architectural only when one of the decode
// stages is genuinely blocked on bytes, not while D1 is merely waiting for
// D2 to take its instruction.
wire d1_bytes_blocked = !skel_v && !consume_prefix && !consume_0f &&
                        !d1_struct_ready;
wire d2_bytes_blocked = skel_v && !d2_window_valid && !bytes_ok;
assign fetch_blocked = d1_bytes_blocked || d2_bytes_blocked;

decoder_work_t d2_final;
always_comb begin
    d2_final = d2_phaseB ? capB :
               !has_litA ? skel :
               !has_litB ? capA :
               skel.fields_fit ? capAB : capA;
end

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        d2_phaseB <= 1'b0;
    end else if (q_flush) begin
        d2_phaseB <= 1'b0;
    end else if (incoming_capture) begin
        d2_phaseB <= 1'b0;
    end else if (d2_done) begin
        d2_phaseB <= 1'b0;
    end else if (d2_stepA) begin
        workB <= capA;
        d2_phaseB <= 1'b1;
    end
end

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        skel_raw_hi_r <= 32'h0;
        skel_raw_lit_off_r <= 2'd0;
        skel_lit_r <= 32'h0;
        skel_window_valid_r <= 1'b0;
        skel_window_raw_r <= 1'b0;
    end else if (q_flush) begin
        skel_window_valid_r <= 1'b0;
    end else if (d1_handoff) begin
        skel_lit_r <= k1q[31:0];
        skel_raw_hi_r <= k1q[63:32];
        skel_raw_lit_off_r <= handoff_raw_lit_off;
        skel_window_valid_r <= handoff_raw_valid;
        skel_window_raw_r <= 1'b1;
    end else if (d2_stepA) begin
        skel_lit_r <= k2q;
        skel_window_valid_r <= (k2q_avail >= {3'b000, sizeB});
        skel_window_raw_r <= 1'b0;
    end else if (d2_late_capture) begin
        skel_lit_r <= k2q;
        skel_window_valid_r <= 1'b1;
        skel_window_raw_r <= 1'b0;
    end else if (d2_done) begin
        skel_window_valid_r <= 1'b0;
    end
end

// Literal capture does not change structural EA fields; use the selectors and
// segment index registered at the D1 handoff directly.
dec_entry_t push_entry;
always_comb begin
    // Literal capture changes only these two fields. Keep the full structural
    // entry out of the phase-B mux so its EA and recipe controls remain direct
    // registered skeleton outputs.
    push_entry = skel.entry;
    push_entry.immediate = d2_final.entry.immediate;
    push_entry.displacement = d2_final.entry.displacement;
    // Literals do not affect recipe register dependencies. Use the registered
    // D1 skeleton so a second literal phase cannot enter this hazard path.
    push_entry.recipe_gpr_read_mask = recipe_gpr_read_mask(skel.entry);
end

assign d2_entry = push_entry;
assign d2_push  = d2_complete;
assign i_bus = push_entry;
assign decq_empty = !skel_v;

// Port B reads the incoming skeleton's entry word on the edge it is loaded,
// so the word is resident for the instruction's whole D2 residency.
assign pb_load = d1_handoff;
assign pb_entry = handoff_d2.entry.entry_point;

assign pop_now = d2_done;
assign pop_len = skel.entry.length;

// synthesis translate_off
// Focused recipe legality checks. The generated inventory is authoritative;
// these assertions verify that its early role agrees with its hazard metadata.
wire [2:0] push_recipe_early = recipe_early_kind(push_entry.entry_point);
recipe_meta_t push_recipe_fc;
assign push_recipe_fc = recipe_metadata(push_entry);
reg recipe_cov_en = 1'b0;
initial recipe_cov_en = $test$plusargs("recipe_cov");
always @(posedge clk) begin
    if (reset_n && d2_done && push_recipe_fc.hardwired) begin
        if (push_recipe_early == RECIPE_EARLY_SEQ)
            $fatal(1, "hardwired recipe missing: entry=%03x opcode=%02x modrm=%02x 0f=%b",
                   push_entry.entry_point, push_entry.opcode, push_entry.modrm,
                   push_entry.has_0f);
        unique case (push_recipe_early)
            RECIPE_EARLY_NONE:
                if (push_recipe_fc.uses_ea || push_recipe_fc.br_rel)
                    $fatal(1, "hardwired recipe NONE role mismatch: entry=%03x fc=%04x",
                           push_entry.entry_point, push_recipe_fc);
            RECIPE_EARLY_EA, RECIPE_EARLY_LOAD, RECIPE_EARLY_STORE,
            RECIPE_EARLY_RMW, RECIPE_EARLY_STACK:
                if (!push_recipe_fc.uses_ea)
                    $fatal(1, "hardwired recipe address role mismatch: entry=%03x kind=%0d fc=%04x",
                           push_entry.entry_point, push_recipe_early, push_recipe_fc);
            RECIPE_EARLY_BRANCH:
                if (!push_recipe_fc.br_rel)
                    $fatal(1, "hardwired recipe branch role mismatch: entry=%03x fc=%04x",
                           push_entry.entry_point, push_recipe_fc);
            default:
                $fatal(1, "hardwired recipe invalid early kind: entry=%03x kind=%0d",
                       push_entry.entry_point, push_recipe_early);
        endcase
        if (recipe_cov_en)
            $display("RECIPE_COV entry=%03x kind=%0d opcode=%02x modrm=%02x fc=%04x",
                     push_entry.entry_point, push_recipe_early,
                     push_entry.opcode, push_entry.modrm, push_recipe_fc);
    end
end

reg D1_EVT = 1'b0;
initial if ($test$plusargs("pf_cur")) D1_EVT = 1'b1;
always @(posedge clk) begin
    if (D1_EVT && d1_handoff)
        $display("%0t D1HO op=%02x modrm=%02x len=%0d adv=%0d(sib=%b slen=%0d) litoff=%0d A=%0d/%0d B=%0d/%0d pcnt=%0d 0f=%b",
                 $time, handoff_work.entry.opcode, handoff_work.entry.modrm,
                 handoff_work.entry.length, k1p_adv, struct_work.need_sib, struct_len,
                 handoff_lit_off, handoff_work.lit1_kind, handoff_work.lit1_size,
                 handoff_work.lit2_kind, handoff_work.lit2_size,
                 prefix_count, prefix_0f);
    if (D1_EVT && d2_done)
        $display("%0t D2DN op=%02x len=%0d imm=%08x disp=%08x phB=%b",
                 $time, push_entry.opcode, push_entry.length,
                 push_entry.immediate, push_entry.displacement, d2_phaseB);
end
always @(posedge clk) begin
    if (reset_n && d1_handoff && (handoff_raw_lit_off_w[4:2] != 3'b000))
        $fatal(1, "D1: raw literal offset exceeds opcode window: off=%0d op=%02x",
               handoff_raw_lit_off_w, handoff_work.entry.opcode);
    // The literal plan must tile the instruction exactly: pop_len bytes =
    // struct bytes (k2p_off) + literal bytes.
    if (reset_n && skel_v &&
        ({1'b0, skel.entry.length} !==
         {1'b0, skel_lit_off} + {3'b000, skel.lit1_size} + {3'b000, skel.lit2_size}))
        $fatal(1, "D2: literal plan does not tile: len=%0d k2p_off=%0d A=%0d B=%0d",
               skel.entry.length, skel_lit_off, skel.lit1_size, skel.lit2_size);
    if (reset_n && d2_phaseB && !skel_v)
        $fatal(1, "D2: phase B with no skeleton");
    // The relative-branch displacement against the d2_entry form it replaced
    // on the speculative-target path, and the literal plan its proof assumes.
    if (reset_n && skel_v && (skel.entry.rel_branch_kind != REL_BRANCH_NONE) &&
        (!((skel.lit1_kind == LIT_DISP) || ((skel.lit1_kind == LIT_IMM) && skel.lit1_mirror_disp)) ||
         !((skel.lit1_size == 3'd1) || (skel.lit1_size == 3'd2) || (skel.lit1_size == 3'd4)) ||
         (skel.lit2_kind != LIT_NONE) || d2_phaseB ||
         (skel_window_raw_r && (skel_raw_lit_off_r != 2'd1))))
        $fatal(1, "D2: relative branch literal plan: op=%02x lit1=%0d/%0d mirror=%b lit2=%0d phB=%b raw=%b off=%0d",
               skel.entry.opcode, skel.lit1_kind, skel.lit1_size, skel.lit1_mirror_disp,
               skel.lit2_kind, d2_phaseB, skel_window_raw_r, skel_raw_lit_off_r);
    if (reset_n && d2_push && (push_entry.rel_branch_kind != REL_BRANCH_NONE) &&
        (d2_branch_disp !== (push_entry.branch_rel8
                             ? {{24{push_entry.displacement[7]}}, push_entry.displacement[7:0]}
                             : push_entry.displacement)))
        $fatal(1, "D2: branch displacement %08x disagrees with d2_entry %08x (op=%02x rel8=%b)",
               d2_branch_disp, push_entry.displacement, push_entry.opcode,
               push_entry.branch_rel8);
end
// synthesis translate_on

// JMP/CALL rel is unconditionally taken, so its speculative fall-through prefetch is always wasted.
function automatic logic entry_jmp_call(input dec_entry_t e);
    entry_jmp_call = (e.rel_branch_kind == REL_BRANCH_JMP) ||
                     (e.rel_branch_kind == REL_BRANCH_CALL);
endfunction

assign decq_has_jmp_call =
    (d2_push && entry_jmp_call(push_entry)) ||
    // D1 holds a decoded instruction until D2 takes it.
    (d1_preread_handoff && handoff_one_d2 && entry_jmp_call(d1_issue_entry));

//=============================================================================
// Structural Decode
//=============================================================================

task automatic build_struct_work(
    input logic [53:0]    sensitivity_inputs,
    output decoder_work_t w,
    output logic [2:0]    s_len,
    output logic [11:0]   ov_entry
);
    logic [11:0] ctl_bits;
    logic [15:0] entry_first;
    logic [15:0] entry_grom;
    logic [15:0] entry_final;
    logic        entry_group;
    logic [5:0]  group_code;
    logic [9:0]  grom_addr;
    logic        has_modrm;
    logic        has_sib;
    logic [2:0]  disp_size;
    logic [2:0]  imm_total_size;
    logic [2:0]  imm_first_size;
    logic        imm_sign_extend;
    logic        invalid_lock;
    logic        instr_bswap;
    logic        instr_loadall;
    logic        instr_mov_tr;
    logic        instr_xadd;
    logic        instr_cmpxchg;
    logic        instr_invd;
    logic [11:0] entry_486;
    logic        is_setcc;
    logic        is_movzx_movsx;
    logic        is_movzx_word;
    logic        is_xlat;
    logic        is_byte_operand;
    logic [3:0]  len_opc;
    logic [2:0]  len_disp;
    begin
        w = '0;
        s_len = 3'd1;
        ctl_bits = pla_control_opcode_lookup(prefix_0f, opcode);

        w.entry.opcode = opcode;
        w.entry.has_0f = prefix_0f;
        w.entry.has_rep = prefix_rep;
        w.entry.prefix_count = prefix_count;
        w.entry.data32 = data32;
        w.entry.addr32 = addr32;
        w.entry.rep_lock = prefix_rep_lock;
        w.entry.seg = prefix_seg;
        w.entry.has_d_bit = ctl_bits[11] & ~ctl_bits[10] & ctl_bits[9] &
                             ctl_bits[8] & ctl_bits[2] & ctl_bits[1];
        w.entry.has_embedded_register = ~ctl_bits[2];
        w.entry.has_w_bit = ctl_bits[1];
        w.entry.is_pushpop_seg = ctl_bits[3];
        w.entry.update_flags = ctl_bits[4];

        has_modrm = ctl_bits[2] & ~ctl_bits[0];
        imm_sign_extend = 1'b0;
        imm_total_size = 3'd0;
        imm_first_size = 3'd0;

        // A PE/D change flushes the frontend, so a skeleton is never consumed
        // across a mode switch.
        entry_first = entry_rom_sel;
        // The group row is the first-level entry itself: a ModR/M opcode's
        // first-level word is a group row exactly when entry[11:6] == 0, and
        // its row is entry[5:0] (scripts/gen_pla_group.py derives
        // pla_group_lookup from that rule and checks it on every opcode).
        // entry_first comes from the preread entry-ROM word, so the group
        // ROM address no longer waits for the k1q -> opcode-class PLA
        // (pla_group_lookup, the k1q_r fan-out -> WideNor -> group ROM cone).
        // tests/equiv/group_from_entry.v proves the two forms equal for
        // every {data32, opcode, pe, 0F, rep}; a translate_off fuse below
        // holds them equal every non-flush cycle.
        group_code = entry_first[5:0];
        entry_group = has_modrm && (entry_first[11:6] == 6'd0);
        grom_addr = {group_code, modrm[5:3], (modrm[7:6] != 2'b11)};
        entry_grom = group_entry_rom[grom_addr];
        entry_final = entry_group ? entry_grom : entry_first;
        invalid_lock = check_lock_invalid(prefix_rep_lock, prefix_0f, opcode,
                                          has_modrm, modrm);
        instr_bswap = prefix_0f && (opcode[7:3] == 5'b11001);
        // The 80386 CROM still holds LOADALL (0F 07); a 486 raises #UD.
        instr_loadall = prefix_0f && (opcode == 8'h07);
        // The 486 adds TR3-TR5 to the 80386's TR6/TR7: all five share the
        // MOV TRn routines.
        instr_mov_tr = prefix_0f && ((opcode == 8'h24) || (opcode == 8'h26)) &&
                       (modrm[5:3] >= 3'd3);
        // Other 486 additions with optimizer-owned entries.
        instr_xadd = prefix_0f && (opcode[7:1] == 7'b1100000);
        instr_cmpxchg = prefix_0f && (opcode[7:1] == 7'b1011000);
        instr_invd = prefix_0f && (opcode[7:1] == 7'b0000100);
        entry_486 = instr_bswap ? UADDR_BSWAP :
                    instr_xadd ? ((modrm[7:6] == 2'b11) ? UADDR_XADD_R : UADDR_XADD_M) :
                    instr_cmpxchg ? ((modrm[7:6] == 2'b11) ? UADDR_CMPXCHG_R
                                                           : UADDR_CMPXCHG_M) :
                    UADDR_INVD;
        w.entry.boundary_action = invalid_lock ? BOUNDARY_ACTION_NONE :
            decode_boundary_action(prefix_0f, opcode, has_modrm, modrm);
        w.entry.seg_reg_sel = decode_segment_register(prefix_0f, opcode,
                                                       has_modrm, modrm);
        w.entry.cmptest_is_cmp = (opcode[7:2] == 6'b100000) ||
                                 (opcode[7:3] == 5'b00111) || instr_cmpxchg;
        w.entry.decoded_alu_op = instr_xadd ? ALU_ADD :
                                 decode_instruction_alu_op(prefix_0f, opcode,
                                                           has_modrm, modrm);
        w.entry.mul_signed = (!prefix_0f &&
                              (opcode == 8'h69 || opcode == 8'h6B)) ||
                             (prefix_0f && opcode == 8'hAF) ||
                             (!prefix_0f && has_modrm &&
                              (opcode == 8'hF6 || opcode == 8'hF7) &&
                              modrm[5:3] == 3'd5);
        w.entry.div_quotient_zf = !prefix_0f && has_modrm &&
                                  (opcode == 8'hF6 || opcode == 8'hF7) &&
                                  modrm[5:3] == 3'd6;
        w.entry.flag_op = decode_flag_op(prefix_0f, opcode);
        if (!prefix_0f && opcode[7:3] == 5'b11011)
            w.entry.fop = {opcode[2:0], modrm};
        w.entry.shift_is_double = prefix_0f &&
            ((opcode == 8'hA4) || (opcode == 8'hA5) ||
             (opcode == 8'hAC) || (opcode == 8'hAD));
        w.entry.shift_right = opcode[3];
        w.entry.shift_operation = modrm[5:3];
        w.entry.port_io = !prefix_0f &&
            ((opcode[7:2] == 6'b011011) ||  // 6C-6F: INS/OUTS
             (opcode[7:2] == 6'b111001) ||  // E4-E7: IN/OUT imm8
             (opcode[7:2] == 6'b111011));   // EC-EF: IN/OUT DX
        if ((!prefix_0f && (opcode[7:4] == 4'h7)) ||
            ( prefix_0f && (opcode[7:4] == 4'h8)))
            w.entry.rel_branch_kind = REL_BRANCH_JCC;
        else if (!prefix_0f && ((opcode == 8'hEB) || (opcode == 8'hE9)))
            w.entry.rel_branch_kind = REL_BRANCH_JMP;
        else if (!prefix_0f && (opcode == 8'hE8))
            w.entry.rel_branch_kind = REL_BRANCH_CALL;
        w.entry.branch_rel8 = !prefix_0f &&
                              ((opcode[7:4] == 4'h7) || (opcode == 8'hEB));
        // CMPXCHG's JNcond takes its mismatch path when ZF is clear.
        w.entry.branch_condition = instr_cmpxchg ? 4'h4 : opcode[3:0];
        if (!prefix_0f && (opcode[7:1] == 7'b1110000))
            w.entry.repeat_kind = opcode[0] ? REPEAT_KIND_LOOPE
                                             : REPEAT_KIND_LOOPNE;
        w.entry.entry_point = invalid_lock ? UADDR_INVALID_LOCK :
                              instr_loadall ? UADDR_INVALID_LOCK :
                              instr_mov_tr ? (opcode[1] ? UADDR_MOV_TR_TO
                                                        : UADDR_MOV_TR_FROM) :
                              (instr_bswap || instr_xadd || instr_cmpxchg || instr_invd)
                                  ? entry_486 : entry_final[11:0];
        // The overlaid entry, taken on each arm of the entry mux above (same
        // selects, same order) instead of on its result; the group ROM's arm
        // with its hits decoded from its address (group_ov_hits), in parallel
        // with the ROM read.
        ov_entry = (invalid_lock || instr_loadall)
                     ? recipe_effective_entry_hit(UADDR_INVALID_LOCK,
                                                  ov_hits(UADDR_INVALID_LOCK), opcode, modrm) :
                   instr_mov_tr
                     ? recipe_effective_entry_hit(opcode[1] ? UADDR_MOV_TR_TO : UADDR_MOV_TR_FROM,
                                                  ov_hits(opcode[1] ? UADDR_MOV_TR_TO
                                                                    : UADDR_MOV_TR_FROM),
                                                  opcode, modrm) :
                   (instr_bswap || instr_xadd || instr_cmpxchg || instr_invd)
                     ? recipe_effective_entry_hit(entry_486, ov_hits(entry_486), opcode, modrm) :
                   entry_group
                     ? recipe_effective_entry_hit(entry_grom[11:0], group_ov_hits(grom_addr),
                                                  opcode, modrm) :
                   recipe_effective_entry_hit(entry_first[11:0], ov_hits(entry_first[11:0]),
                                              opcode, modrm);
        w.entry.stack_op = (invalid_lock || instr_bswap || instr_xadd || instr_cmpxchg ||
                            instr_invd || instr_loadall || instr_mov_tr) ? 1'b0 : entry_final[13];
        w.entry.stack_dir = (invalid_lock || instr_bswap || instr_xadd || instr_cmpxchg ||
                             instr_invd || instr_loadall || instr_mov_tr) ? 1'b0 : entry_final[12];
        // BSWAP has a fixed r32 operand even in a 16-bit code segment.
        if (instr_bswap)
            w.entry.data32 = 1'b1;

        // Resolve architectural widths once in D1. These exceptions are the
        // same ones that cannot be represented by the generic W-bit rule.
        is_setcc = prefix_0f && (opcode[7:4] == 4'b1001);
        is_movzx_movsx = prefix_0f && (opcode[7:4] == 4'b1011) &&
                          (opcode[2:1] == 2'b11);
        is_movzx_word = is_movzx_movsx && opcode[0];
        is_xlat = !prefix_0f && (opcode == 8'hD7);
        is_byte_operand = is_setcc ? 1'b1 :
                          is_movzx_movsx ? 1'b0 :
                          is_xlat ? 1'b1 :
                          (w.entry.has_embedded_register && w.entry.has_w_bit)
                              ? ~opcode[3] :
                          w.entry.has_w_bit ? ~opcode[0] : 1'b0;
        w.entry.operand_size = is_byte_operand ? 2'd0 :
                               is_movzx_word ? 2'd2 :
                               w.entry.data32 ? 2'd2 : 2'd1;
        w.entry.source_size = is_movzx_movsx
                            ? (opcode[0] ? 2'd1 : 2'd0)
                            : w.entry.operand_size;

        if (has_modrm) begin
            has_sib = addr32 && (modrm[7:6] != 2'b11) && (modrm[2:0] == 3'b100);
            disp_size = has_sib ? 3'd0 : modrm_disp_size(addr32, modrm, 8'h00, 1'b0);
            s_len = 3'd2;

            unique case (ctl_bits[11:10])
                2'b00: imm_total_size = 3'd1;
                2'b01: imm_total_size = data32 ? 3'd4 : 3'd2;
                2'b10: imm_total_size = 3'd0;
                default: begin
                    imm_total_size = 3'd1;
                    imm_sign_extend = 1'b1;
                end
            endcase

            if ((opcode[7:1] == 7'b1111011) && (modrm[5:3] >= 3'd2))
                imm_total_size = 3'd0;

            w.entry.has_modrm = 1'b1;
            w.entry.modrm = modrm;
            w.entry.has_sib = has_sib;
            w.entry.sib = 8'h00;
            w.entry.imm_size = imm_total_size;
            w.need_sib = has_sib;
            w.pending_imm_size = has_sib ? imm_total_size : 3'd0;
            w.pending_imm_sign_extend = has_sib ? imm_sign_extend : 1'b0;
            select_register_fields(prefix_0f, opcode, 1'b1, modrm,
                                   w.entry.src_reg_sel, w.entry.dst_reg_sel);

            if (!has_sib) begin
                if (disp_size != 3'd0) begin
                    w.lit1_kind = LIT_DISP;
                    w.lit1_size = disp_size;
                    // Normalize disp8 while D2 captures the literal so the
                    // live EA path consumes one ready 32-bit addend.
                    w.lit1_sign_extend = (disp_size == 3'd1);
                end
                if (imm_total_size != 3'd0) begin
                    if (w.lit1_kind == LIT_NONE) begin
                        w.lit1_kind = LIT_IMM;
                        w.lit1_size = imm_total_size;
                        w.lit1_sign_extend = imm_sign_extend;
                    end else begin
                        w.lit2_kind = LIT_IMM;
                        w.lit2_size = imm_total_size;
                        w.lit2_sign_extend = imm_sign_extend;
                    end
                end
            end
        end else begin
            has_sib = 1'b0;
            disp_size = 3'd0;
            select_register_fields(prefix_0f, opcode, 1'b0, 8'h00,
                                   w.entry.src_reg_sel, w.entry.dst_reg_sel);

            if (!prefix_0f && opcode[7:2] == 6'b101000) begin
                // MOV AL/eAX,moffs and MOV moffs,AL/eAX.
                w.entry.has_moffs = 1'b1;
                imm_total_size = addr32 ? 3'd4 : 3'd2;
                imm_first_size = imm_total_size;
            end else begin
                unique case (ctl_bits[11:6])
                    6'b100111: imm_total_size = 3'd1;
                    6'b110111: imm_total_size = data32 ? 3'd4 : 3'd2;
                    6'b000111: begin
                        imm_total_size = 3'd1;
                        imm_sign_extend = 1'b1;
                    end
                    6'b010111: imm_total_size = 3'd2;
                    6'b011111: imm_total_size = data32 ? 3'd4 : 3'd2;
                    6'b100010: begin
                        imm_total_size = 3'd1;
                        imm_sign_extend = 1'b1;
                    end
                    6'b101111: imm_total_size = 3'd3;
                    6'b111111: imm_total_size = data32 ? 3'd6 : 3'd4;
                    default:   imm_total_size = 3'd0;
                endcase

                imm_first_size = imm_total_size;
                unique case (ctl_bits[11:6])
                    6'b100010: imm_first_size = 3'd0;
                    6'b101111: imm_first_size = 3'd2;
                    6'b111111: imm_first_size = data32 ? 3'd4 : 3'd2;
                    default: ;
                endcase
            end

            w.entry.imm_size = imm_total_size;
            if (imm_total_size != 3'd0) begin
                if (imm_first_size != 3'd0) begin
                    w.lit1_kind = LIT_IMM;
                    w.lit1_size = imm_first_size;
                    w.lit1_sign_extend = imm_sign_extend && (imm_first_size == 3'd1);
                    w.lit1_mirror_disp = 1'b1;
                end
                if (imm_total_size != imm_first_size) begin
                    if (w.lit1_kind == LIT_NONE) begin
                        w.lit1_kind = LIT_DISP;
                        w.lit1_size = imm_total_size - imm_first_size;
                        w.lit1_sign_extend = imm_sign_extend;
                    end else begin
                        w.lit2_kind = LIT_DISP;
                        w.lit2_size = imm_total_size - imm_first_size;
                        w.lit2_sign_extend = imm_sign_extend;
                    end
                end
            end
        end

        // The cursor advance is on the K1Q loop: take the opcode-side length
        // from one flat table and the displacement from the raw ModR/M bits,
        // in parallel, then add once. entry.length keeps the serial terms;
        // the handoff check ties the two in simulation.
        len_opc = d1_length_lookup(prefix_0f, opcode, data32, addr32,
                                   modrm[5] | modrm[4]);
        len_disp = (addr32 && (modrm[7:6] != 2'b11) && (modrm[2:0] == 3'b100))
                 ? 3'd0 : modrm_disp_size(addr32, modrm, 8'h00, 1'b0);
        w.body_len = {2'b00, len_opc[2:0]} +
                     (len_opc[3] ? {2'b00, len_disp} : 5'd0);
        // The D1 cursor advance: opcode side plus ModR/M side (SIB byte and
        // displacement), two parallel table lookups and one add.
        w.adv_len = {2'b00, len_opc[2:0]} +
                    (len_opc[3] ? {2'b00, d1_modrm_length_lookup(addr32, modrm, sib_b[2:0])}
                                : 5'd0);
        w.entry.length = {1'b0, prefix_count} + (prefix_0f ? 5'd1 : 5'd0) +
                         {2'b00, s_len} + {2'b00, disp_size} +
                         {2'b00, imm_total_size};
        w.entry.ind_is_ea = w.entry.has_modrm || w.entry.stack_op ||
                            w.entry.has_moffs;
    end
endtask

// synthesis translate_off
// Check the generated contents and speculative-cursor alignment anywhere D1
// is live. The X guard excludes only the startup preread.
wire [15:0] pla_entry_now =
    pla_entry_lookup({data32, opcode, prefix_rep, pe_enable, 1'b1, prefix_0f});
always_ff @(posedge clk) begin
    if (reset_n && !q_flush &&
        (^{entry_rom_sel, pla_entry_now} !== 1'bx) &&
        (entry_rom_sel !== pla_entry_now))
        $fatal(1, "entry ROM mismatch: op=%02x rom=%04x pla=%04x",
               opcode, entry_rom_sel, pla_entry_now);
end
// The group select and row taken from the entry-ROM word (build_struct_work)
// against the opcode-class PLA they replaced, wherever D1 is live.
wire [6:0]  pla_group_now = pla_group_lookup({data32, opcode, pe_enable, prefix_0f});
wire [11:0] grp_ctl_now = pla_control_opcode_lookup(prefix_0f, opcode);
wire        grp_has_modrm_now = grp_ctl_now[2] && !grp_ctl_now[0];
wire        grp_old_now = pla_group_now[6] && grp_has_modrm_now;
wire        grp_new_now = grp_has_modrm_now && (entry_rom_sel[11:6] == 6'd0);
always_ff @(posedge clk) begin
    if (reset_n && !q_flush && (^{entry_rom_sel, pla_group_now} !== 1'bx) &&
        ((grp_old_now !== grp_new_now) ||
         (grp_old_now && (pla_group_now[5:0] !== entry_rom_sel[5:0]))))
        $fatal(1, "D1 group from entry ROM mismatch: op=%02x 0f=%b rom=%04x grp=%02x",
               opcode, prefix_0f, entry_rom_sel, pla_group_now);
end
// synthesis translate_on

function automatic decoder_work_t capture_sib(input decoder_work_t in,
                                              input logic [7:0]   sib_byte);
    decoder_work_t out;
    logic [2:0] disp_size;
    begin
        out = in;
        disp_size = modrm_disp_size(in.entry.addr32, in.entry.modrm,
                                    sib_byte, in.entry.has_sib);

        out.need_sib = 1'b0;
        out.entry.sib = sib_byte;
        out.entry.ea_uses_post_pop_esp = !in.entry.has_0f &&
            (in.entry.opcode == 8'h8F) && (sib_byte[2:0] == 3'b100);
        out.entry.length = in.entry.length + 5'd1 + {2'b00, disp_size};
        out.body_len = in.body_len + 5'd1 + {2'b00, disp_size};

        if (disp_size != 3'd0) begin
            out.lit1_kind = LIT_DISP;
            out.lit1_size = disp_size;
            out.lit1_sign_extend = (disp_size == 3'd1);
        end

        if (in.pending_imm_size != 3'd0) begin
            if (out.lit1_kind == LIT_NONE) begin
                out.lit1_kind = LIT_IMM;
                out.lit1_size = in.pending_imm_size;
                out.lit1_sign_extend = in.pending_imm_sign_extend;
            end else begin
                out.lit2_kind = LIT_IMM;
                out.lit2_size = in.pending_imm_size;
                out.lit2_sign_extend = in.pending_imm_sign_extend;
            end
        end

        out.pending_imm_size = 3'd0;
        out.pending_imm_sign_extend = 1'b0;
        capture_sib = out;
    end
endfunction

function automatic decoder_work_t capture_literal(
    input decoder_work_t in,
    input logic [31:0]   win,    // literal bytes at offset 0 of this view
    input lit_kind_t     kind,
    input logic [2:0]    size,
    input logic          sign_extend,
    input logic          mirror_disp
);
    decoder_work_t out;
    logic [31:0] value;
    begin
        out = in;
        value = literal_value(win, size, sign_extend);
        if (kind == LIT_IMM) begin
            out.entry.immediate = value;
            if (mirror_disp)
                out.entry.displacement = value;
        end else if (kind == LIT_DISP) begin
            if (in.lit1_kind == LIT_NONE) begin
                unique case (size)
                    3'd1: out.entry.displacement = {out.entry.displacement[31:8], value[7:0]};
                    3'd2: out.entry.displacement = {out.entry.displacement[31:16], value[15:0]};
                    3'd3: out.entry.displacement = {out.entry.displacement[31:24], value[23:0]};
                    default: out.entry.displacement = value;
                endcase
            end else begin
                out.entry.displacement = value;
            end
        end

        if (kind == out.lit1_kind) begin
            out.lit1_kind = LIT_NONE;
            out.lit1_size = 3'd0;
            out.lit1_sign_extend = 1'b0;
            out.lit1_mirror_disp = 1'b0;
        end else begin
            out.lit2_kind = LIT_NONE;
            out.lit2_size = 3'd0;
            out.lit2_sign_extend = 1'b0;
            out.lit2_mirror_disp = 1'b0;
        end
        capture_literal = out;
    end
endfunction

//=============================================================================
// Helpers
//=============================================================================

function automatic logic [4:0] decode_instruction_alu_op(
    input logic       has_0f_in,
    input logic [7:0] opcode_in,
    input logic       has_modrm_in,
    input logic [7:0] modrm_in
);
    logic [1:0] bit_sel;
    begin
        // Ordinary ALU opcodes encode the operation in opcode[5:3]; group
        // forms encode the same three-bit value in ModR/M.reg.
        decode_instruction_alu_op = opcode_in[7] && has_modrm_in
                                  ? {2'b00, modrm_in[5:3]}
                                  : {2'b00, opcode_in[5:3]};

        if (!has_0f_in && (opcode_in[7:4] == 4'h4))
            decode_instruction_alu_op = {4'b1100, opcode_in[3]};
        else if (!has_0f_in && has_modrm_in &&
                 (((opcode_in == 8'hF6 || opcode_in == 8'hF7) &&
                   (modrm_in[5:3] == 3'd2 || modrm_in[5:3] == 3'd3)) ||
                  ((opcode_in == 8'hFE || opcode_in == 8'hFF) &&
                   (modrm_in[5:3] == 3'd0 || modrm_in[5:3] == 3'd1))))
            decode_instruction_alu_op = {3'b110, modrm_in[4:3]};
        else if ((!has_0f_in && opcode_in == 8'h98) ||
                 (has_0f_in && opcode_in[7:4] == 4'hB &&
                  opcode_in[2:1] == 2'b11)) begin
            if (opcode_in[0] || !opcode_in[5])
                decode_instruction_alu_op = opcode_in[3] ? ALU_SEXT : ALU_ZEXT;
            else
                decode_instruction_alu_op = opcode_in[3] ? ALU_SEXT_B : ALU_ZEXT_B;
        end else if (has_0f_in &&
                     ((opcode_in == 8'hA3) || (opcode_in == 8'hAB) ||
                      (opcode_in == 8'hB3) || (opcode_in == 8'hBB) ||
                      (opcode_in == 8'hBA))) begin
            bit_sel = (opcode_in == 8'hBA) ? modrm_in[4:3] : opcode_in[4:3];
            unique case (bit_sel)
                2'b00: decode_instruction_alu_op = ALU_PASS;
                2'b01: decode_instruction_alu_op = ALU_OR;
                2'b10: decode_instruction_alu_op = ALU_ANDN;
                2'b11: decode_instruction_alu_op = ALU_XOR;
            endcase
        end else if (!has_0f_in &&
                     (opcode_in == 8'h37 || opcode_in == 8'h3F))
            decode_instruction_alu_op = opcode_in[3] ? ALU_AAS : ALU_AAA;
        else if (!has_0f_in &&
                     (opcode_in == 8'h27 || opcode_in == 8'h2F))
            decode_instruction_alu_op = opcode_in[3] ? ALU_DAS : ALU_DAA;
    end
endfunction

function automatic flag_op_t decode_flag_op(
    input logic       has_0f_in,
    input logic [7:0] opcode_in
);
    begin
        decode_flag_op = FLAG_OP_NONE;
        if (!has_0f_in) begin
            unique case (opcode_in)
                8'hF5: decode_flag_op = FLAG_OP_CMC;
                8'hF8: decode_flag_op = FLAG_OP_CLC;
                8'hF9: decode_flag_op = FLAG_OP_STC;
                8'hFA: decode_flag_op = FLAG_OP_CLI;
                8'hFB: decode_flag_op = FLAG_OP_STI;
                8'hFC: decode_flag_op = FLAG_OP_CLD;
                8'hFD: decode_flag_op = FLAG_OP_STD;
                default: ;
            endcase
        end
    end
endfunction

function automatic boundary_action_t decode_boundary_action(
    input logic       has_0f_in,
    input logic [7:0] opcode_in,
    input logic       has_modrm_in,
    input logic [7:0] modrm_in
);
    begin
        decode_boundary_action = BOUNDARY_ACTION_NONE;
        if (!has_0f_in) begin
            unique case (opcode_in)
                8'h9d, 8'hcf: decode_boundary_action = BOUNDARY_ACTION_PRESERVE_RF;
                8'h17:        decode_boundary_action = BOUNDARY_ACTION_LOAD_SS;
                8'h8e: begin
                    if (has_modrm_in && modrm_in[5:3] == 3'd2)
                        decode_boundary_action = BOUNDARY_ACTION_LOAD_SS;
                end
                8'hcc, 8'hcd: decode_boundary_action = BOUNDARY_ACTION_SOFT_INT;
                8'hce:        decode_boundary_action = BOUNDARY_ACTION_INTO;
                8'hfb:        decode_boundary_action = BOUNDARY_ACTION_STI;
                default: ;
            endcase
        end
    end
endfunction

function automatic logic [2:0] decode_segment_register(
    input logic       has_0f_in,
    input logic [7:0] opcode_in,
    input logic       has_modrm_in,
    input logic [7:0] modrm_in
);
    begin
        decode_segment_register = 3'd0;
        if (!has_0f_in) begin
            if (opcode_in[7:5] == 3'b000 && opcode_in[2:1] == 2'b11)
                decode_segment_register = {1'b0, opcode_in[4:3]};
            else begin
                unique case (opcode_in)
                    8'h8c, 8'h8e:
                        if (has_modrm_in)
                            decode_segment_register = modrm_in[5:3];
                    8'hc4: decode_segment_register = 3'd0;
                    8'hc5: decode_segment_register = 3'd3;
                    default: ;
                endcase
            end
        end else begin
            unique case (opcode_in)
                8'ha0, 8'ha1: decode_segment_register = 3'd4;
                8'ha8, 8'ha9: decode_segment_register = 3'd5;
                8'hb2:        decode_segment_register = 3'd2;
                8'hb4:        decode_segment_register = 3'd4;
                8'hb5:        decode_segment_register = 3'd5;
                default: ;
            endcase
        end
    end
endfunction

function automatic logic is_prefix(input logic [7:0] b);
    unique case (b)
        8'h26, 8'h2e, 8'h36, 8'h3e,
        8'h64, 8'h65, 8'h66, 8'h67,
        8'hf0, 8'hf2, 8'hf3: is_prefix = 1'b1;
        default: is_prefix = 1'b0;
    endcase
endfunction

function automatic logic [2:0] prefix_seg_code(input logic [7:0] b);
    unique case (b)
        8'h2e: prefix_seg_code = PREFIX_CS;
        8'h36: prefix_seg_code = PREFIX_SS;
        8'h3e: prefix_seg_code = PREFIX_DS;
        8'h26: prefix_seg_code = PREFIX_ES;
        8'h64: prefix_seg_code = PREFIX_FS;
        8'h65: prefix_seg_code = PREFIX_GS;
        default: prefix_seg_code = PREFIX_NOSEG;
    endcase
endfunction

function automatic logic [31:0] literal_value(
    input logic [31:0] bytes,
    input logic [2:0]  size,
    input logic        sign_extend
);
    begin
        unique case (size)
            3'd1: literal_value = sign_extend ? {{24{bytes[7]}}, bytes[7:0]} :
                                                 {24'h0, bytes[7:0]};
            3'd2: literal_value = {16'h0, bytes[15:0]};
            3'd3: literal_value = {8'h0, bytes[23:0]};
            3'd4: literal_value = bytes;
            default: literal_value = 32'h0;
        endcase
    end
endfunction

function automatic logic [2:0] modrm_disp_size(
    input logic       addr32_in,
    input logic [7:0] modrm_in,
    input logic [7:0] sib_in,
    input logic       has_sib_in
);
    if (modrm_in[7:6] == 2'b11)
        modrm_disp_size = 3'd0;
    else if (modrm_in[7:6] == 2'b01)
        modrm_disp_size = 3'd1;
    else if (modrm_in[7:6] == 2'b10)
        modrm_disp_size = addr32_in ? 3'd4 : 3'd2;
    else if (addr32_in && has_sib_in && sib_in[2:0] == 3'b101)
        modrm_disp_size = 3'd4;
    else if (addr32_in && !has_sib_in && modrm_in[2:0] == 3'b101)
        modrm_disp_size = 3'd4;
    else if (!addr32_in && modrm_in[2:0] == 3'b110)
        modrm_disp_size = 3'd2;
    else
        modrm_disp_size = 3'd0;
endfunction

task automatic select_register_fields(
    input  logic        has_0f_in,
    input  logic [7:0]  opcode_in,
    input  logic        has_modrm_in,
    input  logic [7:0]  modrm_in,
    output logic [2:0]  src_reg_sel_out,
    output logic [2:0]  dst_reg_sel_out
);
    begin
        src_reg_sel_out = has_modrm_in ? modrm_in[5:3] : opcode_in[2:0];
        dst_reg_sel_out = has_modrm_in ? (opcode_in[1] ? modrm_in[5:3] :
                                                        modrm_in[2:0]) :
                                         opcode_in[2:0];

        if (has_0f_in && has_modrm_in) begin
            src_reg_sel_out = modrm_in[5:3];
            dst_reg_sel_out = modrm_in[2:0];
            if (opcode_in == 8'h22 || opcode_in == 8'h23 || opcode_in == 8'h26)
                src_reg_sel_out = modrm_in[2:0];
            // UMOV r,r/m (0F 12/13) is MOV 8A/8B: the D bit makes ModRM.reg
            // the destination.
            if (opcode_in == 8'h12 || opcode_in == 8'h13) begin
                src_reg_sel_out = modrm_in[2:0];
                dst_reg_sel_out = modrm_in[5:3];
            end
        end else if (!has_0f_in) begin
            unique casez (opcode_in)
                8'b00???10?: begin
                    src_reg_sel_out = 3'd0;
                    dst_reg_sel_out = 3'd0;
                end
                8'b00???0??: begin
                    src_reg_sel_out = opcode_in[1] ? modrm_in[2:0] : modrm_in[5:3];
                    dst_reg_sel_out = opcode_in[1] ? modrm_in[5:3] : modrm_in[2:0];
                end
                8'h8a, 8'h8b: begin
                    src_reg_sel_out = modrm_in[2:0];
                    dst_reg_sel_out = modrm_in[5:3];
                end
                8'h8c, 8'h8e: begin
                    src_reg_sel_out = modrm_in[5:3];
                    dst_reg_sel_out = modrm_in[2:0];
                end
                8'h62: begin
                    src_reg_sel_out = modrm_in[5:3];
                    dst_reg_sel_out = modrm_in[2:0];
                end
                8'h8f, 8'hfe, 8'hff: dst_reg_sel_out = modrm_in[2:0];
                8'h63: begin
                    src_reg_sel_out = modrm_in[5:3];
                    dst_reg_sel_out = modrm_in[2:0];
                end
                8'h69, 8'h6b: begin
                    src_reg_sel_out = modrm_in[5:3];
                    dst_reg_sel_out = modrm_in[2:0];
                end
                8'b100000??: dst_reg_sel_out = modrm_in[2:0];
                8'hc0, 8'hc1, 8'hd0, 8'hd1,
                8'hd2, 8'hd3: dst_reg_sel_out = modrm_in[2:0];
                8'h86, 8'h87: begin
                    src_reg_sel_out = modrm_in[5:3];
                    dst_reg_sel_out = (modrm_in[7:6] == 2'b11) ? modrm_in[2:0] :
                                                                    modrm_in[5:3];
                end
                8'hd8, 8'hd9, 8'hda, 8'hdb,
                8'hdc, 8'hdd, 8'hde, 8'hdf: begin
                    src_reg_sel_out = modrm_in[5:3];
                    dst_reg_sel_out = modrm_in[2:0];
                end
                8'b10010???: begin
                    src_reg_sel_out = opcode_in[2:0];
                    dst_reg_sel_out = 3'd0;
                end
                8'b101000??, 8'ha8, 8'ha9: begin
                    src_reg_sel_out = 3'd0;
                    dst_reg_sel_out = 3'd0;
                end
                8'hc6, 8'hc7, 8'hf6, 8'hf7: dst_reg_sel_out = modrm_in[2:0];
                default: ;
            endcase
        end
    end
endtask

endmodule
