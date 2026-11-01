//
// Multiply/Divide Unit
// Microcode-driven integer multiply and non-restoring divide
//
module mul_div
    import z486_pkg::*;
(
    input  logic        clk,
    input  logic        reset_n,
    input  logic        exec,               // Execute current mul/div micro-op
    input  logic        instr_start,        // Clear per-instruction DSP completion
    input  logic        repeat_active,      // Sequencer is repeating multiply step
    input  logic [6:0]  aluop,
    input  logic [6:0]  dest,
    input  logic [1:0]  op_size,
    input  logic        is_signed_mul,
    input  logic [31:0] sigma,
    input  logic [31:0] tmpb,
    input  logic [31:0] tmpd,
    input  logic [31:0] dest_value,
    input  logic        gate_detect,        // x87 descriptor gate: data_unit loads desc_raw_hi into TMPB
    input  logic [31:0] desc_raw_hi,        // that descriptor's high dword

    output logic [31:0] result,
    output logic        sigma_write,        // Private datapath writes SIGMA
    output logic [31:0] sigma_value,
    output logic        tmpb_write,         // Private datapath writes TMPB
    output logic [31:0] tmpb_value,
    output logic        counter_early_exit, // DSP completion terminates repeat loop
    output logic        div_overflow,
    output logic        div_overflow_cond,  // div_overflow without exec (== div_overflow when exec)
    output logic        div_quotient_zero,
    output logic [5:0]  div_flags,          // {OF,SF,ZF,AF,PF,CF} of the last divide step
    output logic        mul_flag_overflow   // IMCS / SZ_EX2 / USTEP_IMUL_FLAGS CF=OF
);

localparam logic DIV_OP_MASK   = 1'b0;
localparam logic DIV_OP_NEGATE = 1'b1;

logic [31:0] divtmp;
logic [31:0] multmp;
logic [31:0] result_r;
logic        div_r_nonneg;
logic        idiv_dividend_neg;
logic        idiv_divisor_neg;
logic        div_first_cycle;

logic [31:0] div_iter_q_next;
logic [31:0] div_iter_r_next;
logic        div_iter_r_nonneg_next;
logic [5:0]  div_iter_flags_next;
logic [5:0]  div_flags_r;
assign div_flags = div_flags_r;
logic [31:0] div_divisor_masked;
logic [31:0] div_divisor_abs;
logic [31:0] divisor_abs_r;              // div_divisor_abs, registered on the TMPB / operand-size edges
logic [1:0]  op_size_r;                  // op_size, to notice an operand-size change
logic        div_dividend_neg;
logic        div_divisor_neg;
logic [31:0] prediv_q_in;
logic [31:0] prediv_r_in;

wire [63:0] mul_product;
wire [31:0] mul_upper = op_size == 2'd0 ? {24'h0, mul_product[39:32]} :
                        op_size == 2'd1 ? {16'h0, mul_product[47:32]} :
                                                mul_product[63:32];
wire        mul_is_active_op = aluop == ALUJMP_IMUL3 || aluop == ALUJMP_IMUL4;
wire        dsp_done;
wire        dsp_active;
logic       dsp_completed;
wire        mul_start = exec && mul_is_active_op && !dsp_active &&
                        !dsp_completed && !dsp_done;

assign result = result_r;
assign counter_early_exit = dsp_done && repeat_active && mul_is_active_op;
assign div_quotient_zero = div_op_by_size(DIV_OP_MASK, divtmp, op_size) == 32'd0;

dsp_mul dsp_multiplier (
    .clk(clk),
    .reset_n(reset_n),
    .start(mul_start),
    .op_size(op_size),
    .is_signed(is_signed_mul),
    .multiplicand(multmp),
    .multiplier(tmpb),
    .product(mul_product),
    .done(dsp_done),
    .active(dsp_active)
);

always_ff @(posedge clk) begin
    if (!reset_n) begin
        dsp_completed       <= 1'b0;
        div_r_nonneg        <= 1'b1;
        idiv_dividend_neg   <= 1'b0;
        idiv_divisor_neg    <= 1'b0;
        div_first_cycle     <= 1'b0;
        div_flags_r         <= 6'd0;
        divisor_abs_r       <= 32'd0;
        op_size_r           <= 2'd0;
    end else begin
        // divisor_abs_r tracks div_abs_by_size(tmpb, op_size) on the edges its
        // two sources change: the TMPB writes below (which win), and an
        // operand-size change, where the live f(tmpb, op_size) is the new
        // value.  z486 loads op_size_du at instruction start and the divide
        // microcode never rewrites it, so through the window div_overflow
        // evaluates in, op_size == op_size_r.
        op_size_r <= op_size;
        if (op_size != op_size_r)
            divisor_abs_r <= div_abs_by_size(tmpb, op_size);
        if (instr_start)
            dsp_completed <= 1'b0;
        else if (dsp_done)
            dsp_completed <= 1'b1;

        if (exec) begin
            if (dest == DEST_MDTMP)
                multmp <= dest_value;
            if (dest == DEST_MDTMP4) begin
                divtmp               <= dest_value;
                div_r_nonneg          <= 1'b1;
                idiv_dividend_neg     <= 1'b0;
                idiv_divisor_neg      <= 1'b0;
                div_first_cycle       <= 1'b1;
            end

            case (aluop)
                ALUJMP_DIV7: begin
                    divtmp           <= div_iter_q_next;
                    div_r_nonneg      <= div_iter_r_nonneg_next;
                    div_first_cycle  <= 1'b0;
                    div_flags_r      <= div_iter_flags_next;
                end
                ALUJMP_PREDIV: begin
                    divtmp               <= div_iter_q_next;
                    div_r_nonneg          <= div_iter_r_nonneg_next;
                    idiv_dividend_neg     <= div_dividend_neg;
                    idiv_divisor_neg      <= div_divisor_neg;
                    div_first_cycle       <= 1'b0;
                end
                ALUJMP_DIV5:
                    div_r_nonneg <= 1'b1;
                default: ;
            endcase

            if (aluop == ALUJMP_IMUL3 || aluop == ALUJMP_IMUL4)
                result_r <= op_size == 2'd0 ? {24'h0, mul_product[31:24]} :
                            op_size == 2'd1 ? {16'h0, mul_product[31:16]} :
                                                    mul_product[31:0];
            else if (aluop == ALUJMP_DIV7 || aluop == ALUJMP_PREDIV)
                result_r <= div_iter_q_next;
            else if (dest == DEST_MDTMP4)
                result_r <= dest_value;

            // The divisor's absolute value, registered on the edges data_unit
            // writes TMPB, in the same priority (DEST_TMPB first, then
            // gate_detect, then this unit's PREDIV write-back last), plus the
            // op_size-change refresh above, so divisor_abs_r ==
            // div_abs_by_size(tmpb, op_size_r) every cycle and the live
            // negate+mask leaves the div_overflow / ROM-address cone.  f =
            // abs∘mask is idempotent, so the PREDIV write of f(tmpb) back into
            // tmpb leaves the register at the same value; tests/equiv/
            // div_abs_reg.v proves the invariant and the lemma.
            if (dest == DEST_TMPB)
                divisor_abs_r <= div_abs_by_size(dest_value, op_size);
            if (gate_detect)
                divisor_abs_r <= div_abs_by_size(desc_raw_hi, op_size);
            if (aluop == ALUJMP_PREDIV)
                divisor_abs_r <= div_divisor_abs;
        end
    end
end

// synthesis translate_off
// The registered divisor abs must equal the live form of the TMPB/op_size pair
// it tracks, every cycle; the PREDIV write of f(TMPB) back into TMPB, the
// DEST_TMPB and gate_detect loads and an operand-size change are all checked
// here too.  (op_size_r is the size the register is keyed to; div_overflow
// reads it at the live op_size, equal to op_size_r through the divide window.)
always @(posedge clk)
    if (reset_n && (divisor_abs_r !== div_abs_by_size(tmpb, op_size_r)))
        $fatal(1, "mul_div: divisor_abs_r %08x != live abs %08x (tmpb %08x, size %0d)",
               divisor_abs_r, div_abs_by_size(tmpb, op_size_r), tmpb, op_size_r);
// synthesis translate_on

always_comb begin
    logic [63:0] full64;

    div_dividend_neg = div_sign_bit(sigma, op_size);
    div_divisor_neg = div_sign_bit(tmpb, op_size);
    div_divisor_masked = div_op_by_size(DIV_OP_MASK, tmpb, op_size);
    div_divisor_abs = div_abs_by_size(tmpb, op_size);
    prediv_q_in = div_op_by_size(DIV_OP_MASK, divtmp, op_size);
    prediv_r_in = div_op_by_size(DIV_OP_MASK, sigma, op_size);

    // The double-width dividend {sigma, divtmp} at the operand size, negated
    // by one 64-bit negator: a 16- or 32-bit negation is the low bits of the
    // 64-bit one of the zero-extended value.
    full64 = (op_size == 2'd0) ? {48'h0, sigma[7:0], divtmp[7:0]} :
             (op_size == 2'd1) ? {32'h0, sigma[15:0], divtmp[15:0]} :
                                 {sigma, divtmp};
    if (div_dividend_neg)
        full64 = ~full64 + 64'h1;
    case (op_size)
        2'd0: begin
            prediv_r_in = {24'h0, full64[15:8]};
            prediv_q_in = {24'h0, full64[7:0]};
        end
        2'd1: begin
            prediv_r_in = {16'h0, full64[31:16]};
            prediv_q_in = {16'h0, full64[15:0]};
        end
        default: begin
            prediv_r_in = full64[63:32];
            prediv_q_in = full64[31:0];
        end
    endcase
end

always_comb begin
    logic        use_prediv;
    logic [31:0] q_in;
    logic [31:0] r_in;
    logic [31:0] d_in;
    logic        r_nonneg_in;

    use_prediv = aluop == ALUJMP_PREDIV;
    q_in = use_prediv ? prediv_q_in : divtmp;
    r_in = use_prediv ? prediv_r_in : sigma;
    d_in = use_prediv ? divisor_abs_r : div_divisor_masked;
    r_nonneg_in = use_prediv ? 1'b1 : div_r_nonneg;
    div7_calc(q_in, r_in, d_in, r_nonneg_in, op_size,
              div_iter_q_next, div_iter_r_next, div_iter_r_nonneg_next,
              div_iter_flags_next);
end

always_comb begin
    logic [31:0] quotient;
    logic [31:0] signed_max;
    logic        signs_differ;

    quotient = div_op_by_size(DIV_OP_MASK, result_r, op_size);
    signed_max = op_size == 2'd0 ? 32'h0000_0080 :
                 op_size == 2'd1 ? 32'h0000_8000 : 32'h8000_0000;
    signs_differ = idiv_dividend_neg ^ idiv_divisor_neg;
    div_overflow_cond = (
        (div_first_cycle &&
         ((aluop == ALUJMP_DIV7 &&
           (div_divisor_masked == 32'd0 ||
            div_op_by_size(DIV_OP_MASK, sigma, op_size) >= div_divisor_masked)) ||
          (aluop == ALUJMP_PREDIV &&
           prediv_overflow_by_size(sigma, divtmp, op_size, divisor_abs_r)))) ||
        (aluop == ALUJMP_IDIV2 &&
         (signs_differ ? quotient > signed_max : quotient >= signed_max)));
    div_overflow = exec && div_overflow_cond;
end

always_comb begin
    sigma_write = exec;
    sigma_value = sigma;
    case (aluop)
        ALUJMP_IMUL3,
        ALUJMP_IMUL4: sigma_value = mul_upper;
        ALUJMP_SZ_EX2: sigma_value = 32'd0;
        ALUJMP_DIV5: begin
            sigma_write = !div_r_nonneg;
            sigma_value = div_op_by_size(
                DIV_OP_MASK, sigma + div_divisor_masked, op_size);
        end
        ALUJMP_PREDIV,
        ALUJMP_DIV7: sigma_value = div_iter_r_next;
        ALUJMP_IDIV1: begin
            sigma_write = idiv_dividend_neg;
            sigma_value = div_op_by_size(DIV_OP_NEGATE, sigma, op_size);
        end
        ALUJMP_IDIV2: sigma_value =
            (idiv_dividend_neg ^ idiv_divisor_neg) ?
            div_op_by_size(DIV_OP_NEGATE, result_r, op_size) :
            div_op_by_size(DIV_OP_MASK, result_r, op_size);
        default: sigma_write = 1'b0;
    endcase
end

assign tmpb_write = exec && aluop == ALUJMP_PREDIV;
assign tmpb_value = div_divisor_abs;

always_comb begin
    logic        target_sign;
    logic [31:0] upper;

    target_sign = op_size == 2'd0 ? sigma[7] :
                  op_size == 2'd1 ? sigma[15] : sigma[31];
    upper = tmpd;
    if (aluop == ALUJMP_SZ_EX2) begin
        if (!is_signed_mul)
            target_sign = 1'b0;
    end else begin
        target_sign = is_signed_mul && target_sign;
        case (op_size)
            2'd0: upper = {24'h0, sigma[15:8]};
            2'd1: upper = {16'h0, sigma[31:16]};
            default: upper = tmpd;
        endcase
    end
    mul_flag_overflow = mul_overflow_by_size(upper, target_sign, op_size);
    // USTEP_IMUL_FLAGS retires IMUL r,r/m(,imm) straight from the DSP
    // product: the high half (mul_upper) against the sign of the low half,
    // which the product holds at bit 31 for every size.
    if (aluop == ALUJMP_USTEP_IMUL_FLAGS)
        mul_flag_overflow = mul_overflow_by_size(mul_upper, is_signed_mul && mul_product[31], op_size);
end

function automatic logic div_sign_bit(input [31:0] value, input [1:0] size);
    case (size)
        2'd0: div_sign_bit = value[7];
        2'd1: div_sign_bit = value[15];
        default: div_sign_bit = value[31];
    endcase
endfunction

// The masked absolute value of a divisor at the operand size: the value the
// original div_divisor_abs formed as sign ? mask(~value + 1) : mask(value).  A
// named function so tests/equiv/div_abs_reg.v can paste the shipped text.
function automatic logic [31:0] div_abs_by_size(input logic [31:0] value, input logic [1:0] size);
    logic [31:0] v;
    v = div_sign_bit(value, size) ? (~value) + 32'h1 : value;
    case (size)
        2'd0: div_abs_by_size = {24'h0, v[7:0]};
        2'd1: div_abs_by_size = {16'h0, v[15:0]};
        default: div_abs_by_size = v;
    endcase
endfunction

function automatic logic [31:0] div_op_by_size(
    input logic op,
    input logic [31:0] value,
    input logic [1:0] size
);
    // A k-bit two's-complement negation is the low k bits of the 32-bit one,
    // so one 32-bit negator serves every size before the size mask.
    logic [31:0] v;
    v = (op == DIV_OP_NEGATE) ? (~value) + 32'h1 : value;
    case (size)
        2'd0: div_op_by_size = {24'h0, v[7:0]};
        2'd1: div_op_by_size = {16'h0, v[15:0]};
        default: div_op_by_size = v;
    endcase
endfunction

// The PREDIV overflow test (divisor zero, or |dividend|'s upper half >= the
// divisor) without the 64-bit dividend negator in front of the compare: the
// upper half of the negated {H, L} is ~H + (L == 0) at the size, and a negative
// H (its sign bit set) has ~H < 2^(n-1), so the add never wraps.  Thus
// ~H + c >= d  <=>  ~H >= d || (c && ~H == d - 1) for d != 0, and the compare
// reads the masked sigma/divtmp registers directly (the fitted op_size ->
// full64 negator -> compare -> div_overflow -> ucode ROM address cone).
// tests/equiv/prediv_overflow_fast.v proves it equal to
// (d == 0 || prediv_r_in >= d) for every sigma, divtmp, size and d.
function automatic logic prediv_overflow_by_size(input logic [31:0] h_raw,
                                                 input logic [31:0] l_raw,
                                                 input logic [1:0]  size,
                                                 input logic [31:0] d);
    logic        neg;
    logic [31:0] hx;
    neg = div_sign_bit(h_raw, size);
    hx = div_op_by_size(DIV_OP_MASK, neg ? ~h_raw : h_raw, size);
    prediv_overflow_by_size = (d == 32'd0) || (hx >= d) ||
        (neg && (div_op_by_size(DIV_OP_MASK, l_raw, size) == 32'd0) &&
         (hx == d - 32'd1));
endfunction

function automatic logic mul_overflow_by_size(
    input [31:0] upper,
    input logic sign,
    input [1:0] size
);
    case (size)
        2'd0: mul_overflow_by_size = upper[7:0] != {8{sign}};
        2'd1: mul_overflow_by_size = upper[15:0] != {16{sign}};
        default: mul_overflow_by_size = upper != {32{sign}};
    endcase
endfunction

task automatic div7_calc(
    input  logic [31:0] q_in,
    input  logic [31:0] r_in,
    input  logic [31:0] d_in,
    input  logic        r_nonneg_prev_in,
    input  logic [1:0]  size,
    output logic [31:0] q_out,
    output logic [31:0] r_out,
    output logic        r_nonneg_out,
    output logic [5:0]  flags_out
);
    int unsigned width;
    logic [31:0] q;
    logic [31:0] r;
    logic [31:0] d;
    logic [34:0] width_mask;
    logic [34:0] r_extended;
    logic [33:0] r_shifted;
    logic [34:0] r_alu_a;
    logic [34:0] r_next_full;
    logic [31:0] q_next;
    logic [34:0] sign_mask;

    case (size)
        2'd0: width = 8;
        2'd1: width = 16;
        default: width = 32;
    endcase
    q = div_op_by_size(DIV_OP_MASK, q_in, size);
    r = div_op_by_size(DIV_OP_MASK, r_in, size);
    d = div_op_by_size(DIV_OP_MASK, d_in, size);
    width_mask = (35'd1 << width) - 35'd1;
    r_extended = {3'b0, r} & width_mask;
    if (!r_nonneg_prev_in)
        r_extended = r_extended | (35'd1 << width);
    r_shifted = (r_extended << 1) | {{33{1'b0}}, q[width-1]};
    sign_mask = ~((35'd1 << (width + 2)) - 35'd1);
    r_alu_a = r_shifted[width+1] ?
        ({1'b0, r_shifted} | sign_mask) : {1'b0, r_shifted};
    // One adder: a - d is a + ~d + 1.
    r_next_full = r_alu_a + ({3'b0, d} ^ {35{r_nonneg_prev_in}}) +
                  {34'd0, r_nonneg_prev_in};
    r_nonneg_out = ~r_next_full[width+2];
    q_next = q << 1;
    q_next[0] = r_nonneg_out;
    q_out = div_op_by_size(DIV_OP_MASK, q_next, size);
    r_out = div_op_by_size(DIV_OP_MASK, r_next_full[31:0], size);

    // The step's ALU flags at the operand width: the 386 leaves those of the
    // last step after DIV (SingleStepTests 386 captures), where a Cyrix part
    // leaves the flags unchanged.
    begin
        logic [31:0] a, res;
        logic        a_msb, b_msb, res_msb, carry;
        a   = r_shifted[31:0] & width_mask[31:0];
        res = r_next_full[31:0] & width_mask[31:0];
        a_msb   = a[width-1];
        b_msb   = d[width-1];
        res_msb = res[width-1];
        // The step's carry/borrow out of the operand width is the carry into
        // bit `width` of the step's own add/subtract (r_alu_a and a agree
        // below it, and d is zero above it): sum bit ^ operand bit, for both
        // the add and the subtract (borrow = a < d = no carry).
        carry   = r_next_full[width] ^ r_alu_a[width];
        flags_out[0] = carry;
        flags_out[1] = ~^res[7:0];
        flags_out[2] = a[4] ^ d[4] ^ res[4];
        flags_out[3] = res == 32'd0;
        flags_out[4] = res_msb;
        flags_out[5] = r_nonneg_prev_in ? ((a_msb ^ b_msb) & (a_msb ^ res_msb))
                                        : (~(a_msb ^ b_msb) & (a_msb ^ res_msb));
    end
endtask

endmodule
