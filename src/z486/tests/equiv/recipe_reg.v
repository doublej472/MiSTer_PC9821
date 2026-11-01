// check-equiv: tempinduct
// check-equiv: functions ../../ucode_recipes.svh recipe_metadata
// hardwired_control.sv issue_recipe_r (the registered D2 recipe class) against
// the live recipe_metadata(issue_instr) it replaces.  issue_instr is the
// decoder's push_entry, which is the registered skeleton skel.entry with only
// its immediate, displacement and recipe_gpr_read_mask overwritten (decoder.sv
// push_entry); recipe_metadata reads none of those (ucode_recipes.svh:152), so
// the live class is exactly recipe_metadata(skel.entry).  skel.entry is
// written ONLY at d1_handoff (= pb_load, decoder.sv:569), and d1_slot_ready =
// !skel_v || i_issue (decoder.sv:216) keeps the incoming skeleton resident for
// at least one full cycle before any pb_*/head_issue_safe/fold_now consumer
// evaluates it, so registering recipe_metadata on the same pb_load edge that
// writes skel carries the identical value in every cycle a consumer can read.
//
// The model registers skel and recipe_r from the same free handoff word on
// load, clears recipe_r and skel_v on flush (the decoder clears skel_v and
// holds skel) and clears skel_v on issue, in the RTL's priority
// (reset > flush > load > issue; d1_handoff is inside the non-flush arm).  The
// live side takes the literal/register-mask fields from free inputs, so the
// proof also shows recipe_metadata ignores them.  Every field the function
// reads is free every cycle.  Sequential: proved by induction from reset.
// MUTANT=1 drops the registered class's hardwired bit (a hardwired recipe
// would be classified as sequenced) and must be refuted.
//
// dec_entry_t / recipe_meta_t below are the subset of z486_pkg.sv's types that
// recipe_metadata reads or writes; only their field names matter, since the
// proof compares the pasted function against a register loaded from the same
// word.
typedef struct packed {
    logic [7:0]  opcode;
    logic [7:0]  modrm;
    logic        has_modrm;
    logic        has_0f;
    logic        data32;
    logic [1:0]  rep_lock;
    logic [11:0] entry_point;
    logic [31:0] immediate;
    logic [31:0] displacement;
    logic [7:0]  recipe_gpr_read_mask;
} dec_entry_t;

typedef struct packed {
    logic       hardwired;
    logic       multi_ustep;
    logic [2:0] commit_sel;
    logic       slot_has_work;
    logic       reads_flags;
    logic       uses_ea;
    logic       reads_dst;
    logic       reads_src;
    logic       reads_ecx;
    logic       writes_srcreg;
    logic       op_byte;
    logic       jcc;
    logic       writes_flags;
    logic       br_rel;
} recipe_meta_t;

localparam [2:0] RECIPE_COMMIT_NONE   = 3'd0;
localparam [2:0] RECIPE_COMMIT_ALU    = 3'd1;
localparam [2:0] RECIPE_COMMIT_SHIFT  = 3'd2;
localparam [2:0] RECIPE_COMMIT_MEM    = 3'd3;
localparam [2:0] RECIPE_COMMIT_SIGSRC = 3'd4;
localparam [2:0] RECIPE_COMMIT_ESP    = 3'd5;
localparam [2:0] RECIPE_ACTION_X87_DIRECT = 3'd6;
localparam [1:0] PREFIX_NOREPLOCK     = 2'b00;

module recipe_reg #(parameter MUTANT = 0)
  (input clk, input rst, input load, input flush, input issue,
   // structural fields recipe_metadata reads
   input [7:0] opcode, input [7:0] modrm, input has_0f, input has_modrm,
   input data32, input [1:0] rep_lock, input [11:0] entry,
   // the fields D2 overwrites after the handoff; recipe_metadata ignores them
   input [31:0] imm_live, input [31:0] disp_live, input [7:0] rgrm_live,
   output mismatch);
// @@FUNCTIONS@@
  // The free handoff word, from the fields recipe_metadata reads.
  dec_entry_t handoff;
  always_comb begin
    handoff = '0;
    handoff.opcode      = opcode;
    handoff.modrm       = modrm;
    handoff.has_0f      = has_0f;
    handoff.has_modrm   = has_modrm;
    handoff.data32      = data32;
    handoff.rep_lock    = rep_lock;
    handoff.entry_point = entry;
    handoff.immediate   = imm_live;
    handoff.displacement = disp_live;
    handoff.recipe_gpr_read_mask = rgrm_live;
  end

  recipe_meta_t next_meta;
  always_comb begin
    next_meta = recipe_metadata(handoff);
    if (MUTANT) next_meta.hardwired = 1'b0;
  end

  dec_entry_t   skel     = '0;
  recipe_meta_t recipe_r = '0;
  logic         skel_v   = 1'b0;
  always @(posedge clk) begin
    if (rst) begin
      skel <= '0; recipe_r <= '0; skel_v <= 1'b0;
    end else if (flush) begin
      // The decoder clears skel_v and holds skel.
      recipe_r <= '0; skel_v <= 1'b0;
    end else if (load) begin
      skel <= handoff; recipe_r <= next_meta; skel_v <= 1'b1;
    end else if (issue) begin
      skel_v <= 1'b0;
    end
  end

  // push_entry: skel.entry with the three overwritten fields from free inputs.
  dec_entry_t live;
  always_comb begin
    live = skel;
    live.immediate = imm_live;
    live.displacement = disp_live;
    live.recipe_gpr_read_mask = rgrm_live;
  end

  assign mismatch = skel_v && (recipe_r != recipe_metadata(live));
endmodule
