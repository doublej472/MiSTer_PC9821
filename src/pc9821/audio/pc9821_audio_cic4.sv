// CIC decimator, order 5, decimate by 4: 2.4576 MHz -> 614.4 kHz.
//
// Stage A of the 48 kHz output stage (see pc9821_audio_out.sv for the whole plan). Its job
// is narrow and exact: kill the bands within +-20 kHz of every multiple of 614.4 kHz, which
// are the only input bands that fold straight into the 0-20 kHz passband when the grid is
// decimated by 4. A boxcar-of-4 has its nulls exactly there, and cascading five of them puts
// the fold-band edges at -143 dB/-145 dB.
// The passband droop is -0.071 dB at 20 kHz and is left in place rather than compensated:
// stage B's filter is designed against the CASCADE (the total is 0.071 dB worst departure
// over 0-20 kHz).
//
// The CLK_AUDIO domain has no reset in this design (the mixer it feeds has none either), so
// every register carries a power-up seed and the machine is self-recovering - the same
// convention as pc9821_audio_volume.
//
// ==== THE FORM: one instance of pc9821_audio_fir_engine ===========================
// The decimator is one more instance of the shared pc9821_audio_fir_engine (stages B/C are
// u_fir_b/u_fir_c in pc9821_audio_out.sv; this is u_fir_a). A CIC integrator/comb chain is
// the FACTORED form of the full-rate FIR (1 + z^-1 + z^-2 + z^-3)^5, evaluated at the
// decimated phase - its 16 taps are
//
//   h = [1, 5, 15, 35, 65, 101, 135, 155, 155, 135, 101, 65, 35, 15, 5, 1]  (sum 1024 = 4^5)
//
// and the integrator/comb output d5[25:10] is exactly floor((sum h_k x[4m-k]) / 1024) in
// 16-bit two's complement (its mod-2^27 wraparound is exact because the true sum fits 26 bits
// signed, |sum| <= 2^15 * 2^10 = 2^25, the +1 integrator headroom at IW = 27). The engine
// computes acc = sum x*(h_k<<7) in 42 bits (no wrap possible, |acc| <= 2^32) and takes
// acc[32:17] = the same floor - its overflow clamp never fires for these coefficients. The
// value stream, the decimation phase (vcnt == 3, the integrator/comb form's `decim`), the
// out_valid cadence and the gain are those of the integrator/comb form: no gain, no clamp
// position and no filter response differs. Proof, both legs: an arithmetic model (both forms'
// exact arithmetic re-implemented from their own semantics, 16 stimulus classes, 0
// mismatches) and an RTL co-sim against the integrator/comb module (1160 output pairs, 0
// mismatches).
//
// Area (module-alone A&S, both variants real-topped): 124 ALMs / 148 ALUTs / 225 registers,
// +2 M10K +2 DSP (this instance's own two history RAMs and two multipliers), against 284 ALMs /
// 530 ALUTs / 560 registers for the integrator/comb form.
//
// Latency (a latency trade): compute latency is ~18 CLK_AUDIO cycles (~0.74 us) longer than
// the integrator/comb form's - a run is TAPS+3 = 19
// clk after the trigger valid (+2 clk start handoff) where the adder cascade answered in
// ~3 clk. Both finish inside the 40-clk group (2.4576 MHz valid spacing), runs never
// overlap (40-clk spacing vs 21-clk worst run), and the output sample STREAM and the
// 48 kHz cadence are unchanged; the chain's own group delay is 417 us, so this is +0.18%
// on an internal path nothing observes. The chain co-sim (run_chain.sh -> TB_EQUIV_CHAIN)
// measures the latency as PIN-EXACT: 0 mismatches over 334 848 clk x 5 stimulus classes,
// so the presentation margins absorb the shift at every 512-clk boundary.
//
// The integrator/comb form samples x_l AT the valid edge (its st==0 step) and x_r ONE CLK
// LATER (its st==1 step - the two-step integrator schedule). This form reproduces that
// sampling EXACTLY: the history write lands one clk after the valid and carries in_l latched
// at the valid edge and in_r as seen at the write edge. With production inputs (mix_pre is
// written ON the valid and held for 10 clk) the two edges see the same value and the replica
// is inert, but a stimulus that changes in_r between them (tb_pc9821_audio_out_timeline's
// per-clk staircases) sees the integrator/comb form's own asymmetry - and this form matches
// it, so the form is bit-exact for EVERY input stream, not only the production contract one.
// Without the replica the chain co-sim differs (98 presentations of 1-2 LSB on the right
// channel alone).
//
// Two hardware rules this form must keep (invisible to every bench):
// - NO power-up seed and NO reset on q_l/q_r in the engine and on coef_q below - either
//   makes Quartus refuse the RAM and build the table out of LUTs (Info 276007, the trap
//   pc9821_audio_volume's gain ROM notes) and the whole area win evaporates with zero
//   functional change.
// - CMIRROR = 15, deliberately: the engine's mirror (midx = 2*CMIRROR - idx) supports
//   ODD-length prototypes only (2*CMIRROR+1 taps), and this prototype is EVEN (16 taps,
//   symmetry centre 7.5). An integer mirror centre is wrong - CMIRROR=8 mirrors tap 9 to
//   coeff[7] (155<<7 where the response wants 135<<7), a plausible-but-wrong filter that
//   only sample-exact comparison catches (measured: the co-sim fails from output 0).
//   So the full 16-entry table is stored and
//   the mirror never fires.
// ==== end THE FORM ===================================================================
`default_nettype none

module pc9821_audio_cic4 (
    input  wire               clk,
    input  wire               valid,       // 2.4576 MHz: one input sample per pulse
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    output wire               out_valid,   // 614.4 kHz: one pulse per 4 input samples
    output wire signed [15:0] out_l,
    output wire signed [15:0] out_r
);

    // ---- history write: one input sample per valid, free-running pointer ----
    // The write lands ONE CLK AFTER the valid: wr_pend/waddr_q/in_l_q hold the request and
    // in_r is taken live at the write edge. That is the integrator/comb form's sampling
    // asymmetry replicated to the cycle (x_l at the valid edge, x_r one clk later - see THE
    // FORM block), and with the production held-input contract it is inert.
    /* verilator lint_off PROCASSINIT */   // no reset in this domain: seeds are power-up
    reg [4:0] wptr = 0;
    reg [1:0] vcnt = 0;
    reg       start = 0;
    reg [4:0] saddr = 0;
    reg       wr_pend = 0;
    reg [4:0] waddr_q = 0;
    reg signed [15:0] in_l_q = 0;
    /* verilator lint_on PROCASSINIT */

    always @(posedge clk) begin
        start   <= 1'b0;
        wr_pend <= 1'b0;
        if (valid) begin
            wr_pend <= 1'b1;
            waddr_q <= wptr;
            in_l_q  <= in_l;      // x_l sampled AT the valid edge (the integrator/comb st==0)
            wptr    <= wptr + 5'd1;
            vcnt    <= vcnt + 2'd1;
            if (vcnt == 2'd3) begin   // the integrator/comb form's `decim` phase
                start <= 1'b1;
                saddr <= wptr;
            end
        end
    end

    // ---- coefficient ROM (all 16 entries of the 16-tap prototype) ----
    // h = (1+x+x^2+x^3)^5, coef = h<<7, Q17 as the engine expects. LUT logic at this size,
    // like pc9821_audio_out's coeff_b. coef_q is the registered read and deliberately
    // carries NO power-up value and NO reset (the kbd_lut trap above).
    reg signed [17:0] coeff [0:15];
    /* verilator lint_off PROCASSINIT */
    reg signed [17:0] coef_q;
    /* verilator lint_on PROCASSINIT */
    initial begin
        coeff[0]  = 18'sd128;     // h0  =   1 << 7
        coeff[1]  = 18'sd640;     // h1  =   5 << 7
        coeff[2]  = 18'sd1920;    // h2  =  15 << 7
        coeff[3]  = 18'sd4480;    // h3  =  35 << 7
        coeff[4]  = 18'sd8320;    // h4  =  65 << 7
        coeff[5]  = 18'sd12928;   // h5  = 101 << 7
        coeff[6]  = 18'sd17280;   // h6  = 135 << 7
        coeff[7]  = 18'sd19840;   // h7  = 155 << 7
        coeff[8]  = 18'sd19840;   // h8  = 155 << 7 (symmetry centre 7.5: h8 = h7)
        coeff[9]  = 18'sd17280;   // h9  = 135 << 7
        coeff[10] = 18'sd12928;   // h10 = 101 << 7
        coeff[11] = 18'sd8320;    // h11 =  65 << 7
        coeff[12] = 18'sd4480;    // h12 =  35 << 7
        coeff[13] = 18'sd1920;    // h13 =  15 << 7
        coeff[14] = 18'sd640;     // h14 =   5 << 7
        coeff[15] = 18'sd128;     // h15 =   1 << 7
    end

    wire [3:0] coef_addr;
    always @(posedge clk) coef_q <= coeff[coef_addr];

    // ---- the shared MAC engine (TAPS=16, STRIDE=1, window 16 in a 32-deep buffer) ----
    pc9821_audio_fir_engine #(
        .TAPS(16), .STRIDE(1), .RAM_AW(5), .CMIRROR(15), .COEF_AW(4), .SHIFT(17), .HOLD_OUT(0), .SAT(0)
    ) u_fir_a (
        .clk(clk),
        .wr_en(wr_pend), .wr_addr(waddr_q), .wr_l(in_l_q), .wr_r(in_r),
        .start(start), .start_addr(saddr), .phase(3'd0),
        .coef_addr(coef_addr), .coef_data(coef_q),
        /* verilator lint_off PINCONNECTEMPTY */
        .busy(),
        /* verilator lint_on PINCONNECTEMPTY */
        .done(out_valid), .out_l(out_l), .out_r(out_r)
    );

endmodule

`default_nettype wire
