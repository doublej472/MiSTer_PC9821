// TEST REFERENCE: a frozen copy of src/pc9821/audio/pc9821_audio_out.sv before its FIR MAC rewrite, kept as the equivalence reference of tb_pc9821_audio_out_equiv; not maintained, except the saturation-rail fix both carry (see y_l below).
// The 48 kHz output stage: the core's audio register, decimated from the mixer's 2.4576 MHz
// grid to the framework's 48 kHz sample rate with a real anti-alias filter.
//
// WHY THIS EXISTS. z486_mister.sv writes core_audio_l_r on audio_volume_valid, once per
// 10 CLK_AUDIO cycles (24.576 MHz/10 = 2.4576 MHz), so AUDIO_L/R are a real-time
// zero-order-hold staircase of the sources at their own rates (55 467 Hz for the OPNA's DAC,
// 44 100 Hz for PCM86 and CD-DA). sys/audio_out.sv SAMPLES that register once per 512 clk
// (48 kHz) and has no resampler; sys/iir_filter.v is a +5 dB shaper, not an anti-alias
// filter (measured: -0.7 dB at 24 kHz, -16.3 dB at 45.5 kHz). Sampling the staircase bare
// folds its zero-order-hold images straight into the audible band: a 10 kHz FM tone puts its
// 45 467 Hz image at 2 533 Hz, measured at -13.2 dB relative to the tone.
// Nothing downstream can remove that; it has to be filtered
// before the decimation, which is what this module is.
//
// THE FILTER PLAN. The ratio is 2 457 600/48 000 = 256/5 exactly, taken in three stages so
// that every stage's transition band is wide compared with its own input rate (which is what
// makes a decimator cheap - a single stage with the same final transition would need ~1800
// taps at the grid rate):
//
//   A  pc9821_audio_cic4_ref      decimate 4    2 457 600 -> 614 400 Hz   (boxcar^5: u_fir_a now)
//   B  this engine (TAPS=19)  decimate 2      614 400 -> 307 200 Hz   Q17 FIR
//   C  this engine (TAPS=247) 5/32 polyphase  307 200 ->  48 000 Hz   Q17 FIR, 1235-tap
//                                                                     prototype
//
// Each stage's stopband edge is set by where a fold first reaches the 0-20 kHz passband:
//   A  within +-20 kHz of a multiple of 614.4 kHz         (its boxcar-4 nulls sit there)
//   B  287.2 kHz .. 307.2 kHz                             (307.2 - 20)
//   C  28 kHz and up in its 307.2 kHz input domain        (48 - 20)
// The three were designed (and the tables below generated) by a filter-design script that
// also checked the worst in-band alias over the WHOLE input band. Measured
// design results: cascade flat within 0.071 dB over 0-20 kHz, worst in-band alias
// -100.7 dB, group delay 417 us (20 output samples, dominated by C's 8 kHz transition at a
// 48 kHz output - the price of the stopband).
//
// PRESENTATION. The output registers load once per 512 CLK_AUDIO cycles from a free-running
// counter, so the framework sees exactly one new value per 512 clk (48 kHz), stable in
// between - which is what sys/audio_out.sv's "two consecutive edges agree" latch
// (sys/audio_out.sv:170 (cl2 == cl1)) wants. Each stage's compute is triggered by its input and
// finishes well inside one output period: C's run is 250 clk, the earliest it can start (the
// output whose v[q_j] arrives last) is 480 clk into its 512-clk period, so the worst case
// finishes ~219 clk before the presentation at 511 - check tb_pc9821_audio_out_rate's
// "every presentation carries a new sample" for what happens when that margin is lost.
//
// The authentic OPNA-side junction is untouched: this module takes the SHIPPED mix_pre
// (post single-clamp, post-acompr) and adds nothing upstream of it. The clamp at jt08_acc,
// the six-drum 16-bit wrap, the SSG's separate analog path with its zero-mean series-cap
// join and the psg * 33/16 balance are all outside this file and unchanged.
//
// The CLK_AUDIO domain has no reset in this design (the mixer has none either); every
// register here carries a power-up seed so nothing X-locks in 4-state simulation.
`default_nettype none

module pc9821_audio_out_ref (
    input  wire               clk,          // CLK_AUDIO, 24.576 MHz
    input  wire               valid,        // the mixer's 2.4576 MHz strobe
    input  wire signed [15:0] in_l,         // the shipped mix_pre_l
    input  wire signed [15:0] in_r,         // the shipped mix_pre_r
    output reg  signed [15:0] out_l,        // 48 kHz: one new sample every 512 clk
    output reg  signed [15:0] out_r
);

    // ---- stage A ------------------------------------------------------------
    wire               cic_valid;
    wire signed [15:0] cic_l, cic_r;

    pc9821_audio_cic4_ref u_cic (
        .clk(clk), .valid(valid), .in_l(in_l), .in_r(in_r),
        .out_valid(cic_valid), .out_l(cic_l), .out_r(cic_r)
    );

    // ---- stage B: decimate by 2 --------------------------------------------
    /* verilator lint_off PROCASSINIT */   // this domain has no reset: seeds are power-up
    reg  [4:0]  b_wptr  = 0;
    reg         b_par   = 0;
    reg         b_wr    = 0;
    reg  [4:0]  b_waddr = 0;
    reg         b_start = 0;
    reg  [4:0]  b_saddr = 0;
    wire        b_done;
    wire signed [15:0] b_l, b_r;
    wire [3:0]  b_caddr;

    always @(posedge clk) begin
        b_wr    <= 1'b0;
        b_start <= 1'b0;
        if (cic_valid) begin
            b_wr    <= 1'b1;
            b_waddr <= b_wptr;
            b_wptr  <= b_wptr + 5'd1;
            // decimate by 2: one FIR output per two CIC outputs
            if (b_par) begin
                b_start <= 1'b1;
                b_saddr <= b_wptr;
            end
            b_par <= ~b_par;
        end
    end

    // ---- stage C: 5/16 polyphase resampler ---------------------------------
    // t_j = 32j/5 input samples (307 200 / 48 000 = 6.4): the integer part q_j moves by 6
    // (or 7 when the phase wraps) and the phase steps by 2 through 0,2,4,1,3 - one
    // accumulator produces both. The ratio must be EXACT or some presentations fall between
    // two C outputs and repeat a sample: with the 16/5 (96 kHz) ratio this bench measured
    // gaps of 512 AND 1024 clk, which is what a wrong ratio looks like from outside.
    reg  [7:0]  c_wptr   = 0;
    reg         c_wr     = 0;
    reg  [7:0]  c_waddr  = 0;
    reg         c_start  = 0;
    reg  [7:0]  c_saddr  = 0;
    reg  [2:0]  c_phase  = 0;
    reg  [2:0]  c_frac   = 0;
    reg  [7:0]  c_q      = 0;
    reg  [7:0]  c_idx    = 0;
    /* verilator lint_on PROCASSINIT */
    wire signed [15:0] c_l, c_r;
    wire [9:0]  c_caddr;

    always @(posedge clk) begin
        c_wr    <= 1'b0;
        c_start <= 1'b0;
        if (b_done) begin
            c_wr    <= 1'b1;
            c_waddr <= c_wptr;
            c_wptr  <= c_wptr + 8'd1;
            c_idx   <= c_idx + 8'd1;
            if (c_idx == c_q) begin
                c_start <= 1'b1;
                c_saddr <= c_wptr;
                c_phase <= c_frac;
                if (c_frac >= 3'd3) begin
                    c_frac <= c_frac - 3'd3;      // +2 mod 5
                    c_q    <= c_q + 8'd7;
                end else begin
                    c_frac <= c_frac + 3'd2;
                    c_q    <= c_q + 8'd6;
                end
            end
        end
    end

    // ---- coefficient ROMs ---------------------------------------------------
    // B: 10 stored entries of a 19-tap symmetric prototype -> LUT logic is cheaper than a
    // memory. C: 618 stored entries of a 1235-tap symmetric prototype -> 11 124 bits, two
    // M10Ks (the 1024-entry array is what makes the address a plain 10-bit slice). The C read
    // register deliberately carries NO power-up value and NO reset: either one makes Quartus
    // refuse the memory and build the whole table out of LUTs.
    reg signed [17:0] coeff_b [0:15];
    (* ramstyle = "M10K" *) reg signed [17:0] coeff_c [0:1023];
    reg signed [17:0] b_coef_q;
    reg signed [17:0] c_coef_q;

    // BEGIN GENERATED: COEFF
    localparam [18*10-1:0] COEFF_B = {   // index 0 is the lowest slice (MSB-first concatenation, so this list runs last-to-first)
        18'sh0ffff, 18'sh09aa2, 18'sh00000, 18'sh3de88, 18'sh00000, 18'sh007df, 18'sh00000, 18'sh3fef4, 18'sh00000, 18'sh00004
    };
    localparam [18*618-1:0] COEFF_C = {   // index 0 is the lowest slice (MSB-first concatenation, so this list runs last-to-first)
        18'sh05000, 18'sh04fdf, 18'sh04f7c, 18'sh04ed7, 18'sh04df2, 18'sh04ccd, 18'sh04b6b, 18'sh049ce, 18'sh047f8, 18'sh045eb,
        18'sh043ab, 18'sh0413c, 18'sh03ea0, 18'sh03bdb, 18'sh038f3, 18'sh035e9, 18'sh032c4, 18'sh02f88, 18'sh02c39, 18'sh028db,
        18'sh02574, 18'sh02209, 18'sh01e9d, 18'sh01b35, 18'sh017d6, 18'sh01484, 18'sh01144, 18'sh00e19, 18'sh00b07, 18'sh00812,
        18'sh0053d, 18'sh0028c, 18'sh00000, 18'sh3fd9d, 18'sh3fb64, 18'sh3f958, 18'sh3f77a, 18'sh3f5cb, 18'sh3f44d, 18'sh3f2fe,
        18'sh3f1e1, 18'sh3f0f5, 18'sh3f038, 18'sh3efab, 18'sh3ef4c, 18'sh3ef1b, 18'sh3ef14, 18'sh3ef37, 18'sh3ef81, 18'sh3eff0,
        18'sh3f082, 18'sh3f133, 18'sh3f201, 18'sh3f2e8, 18'sh3f3e7, 18'sh3f4f9, 18'sh3f61b, 18'sh3f74b, 18'sh3f884, 18'sh3f9c4,
        18'sh3fb08, 18'sh3fc4c, 18'sh3fd8e, 18'sh3fecb, 18'sh00000, 18'sh0012a, 18'sh00248, 18'sh00357, 18'sh00454, 18'sh0053f,
        18'sh00615, 18'sh006d6, 18'sh00780, 18'sh00813, 18'sh0088d, 18'sh008ee, 18'sh00937, 18'sh00967, 18'sh0097f, 18'sh0097f,
        18'sh00967, 18'sh00939, 18'sh008f6, 18'sh0089e, 18'sh00834, 18'sh007b9, 18'sh0072f, 18'sh00696, 18'sh005f1, 18'sh00543,
        18'sh0048c, 18'sh003ce, 18'sh0030c, 18'sh00248, 18'sh00184, 18'sh000c0, 18'sh00000, 18'sh3ff45, 18'sh3fe90, 18'sh3fde3,
        18'sh3fd40, 18'sh3fca7, 18'sh3fc1b, 18'sh3fb9b, 18'sh3fb2a, 18'sh3fac7, 18'sh3fa73, 18'sh3fa2f, 18'sh3f9fa, 18'sh3f9d6,
        18'sh3f9c2, 18'sh3f9be, 18'sh3f9c9, 18'sh3f9e3, 18'sh3fa0c, 18'sh3fa42, 18'sh3fa85, 18'sh3fad4, 18'sh3fb2e, 18'sh3fb92,
        18'sh3fbfe, 18'sh3fc72, 18'sh3fcec, 18'sh3fd6b, 18'sh3fded, 18'sh3fe72, 18'sh3fef7, 18'sh3ff7d, 18'sh00000, 18'sh00081,
        18'sh000fd, 18'sh00174, 18'sh001e6, 18'sh00250, 18'sh002b2, 18'sh0030b, 18'sh0035b, 18'sh003a1, 18'sh003dd, 18'sh0040d,
        18'sh00433, 18'sh0044e, 18'sh0045d, 18'sh00462, 18'sh0045b, 18'sh0044a, 18'sh0042f, 18'sh0040a, 18'sh003db, 18'sh003a5,
        18'sh00366, 18'sh00321, 18'sh002d5, 18'sh00283, 18'sh0022e, 18'sh001d4, 18'sh00178, 18'sh0011a, 18'sh000bc, 18'sh0005d,
        18'sh00000, 18'sh3ffa5, 18'sh3ff4c, 18'sh3fef7, 18'sh3fea6, 18'sh3fe5a, 18'sh3fe14, 18'sh3fdd4, 18'sh3fd9a, 18'sh3fd68,
        18'sh3fd3d, 18'sh3fd1a, 18'sh3fcfe, 18'sh3fceb, 18'sh3fce0, 18'sh3fcdc, 18'sh3fce0, 18'sh3fcec, 18'sh3fd00, 18'sh3fd1a,
        18'sh3fd3b, 18'sh3fd62, 18'sh3fd8f, 18'sh3fdc1, 18'sh3fdf7, 18'sh3fe31, 18'sh3fe6f, 18'sh3feaf, 18'sh3fef1, 18'sh3ff35,
        18'sh3ff79, 18'sh3ffbd, 18'sh00000, 18'sh00042, 18'sh00082, 18'sh000bf, 18'sh000f9, 18'sh00130, 18'sh00163, 18'sh00191,
        18'sh001ba, 18'sh001df, 18'sh001fe, 18'sh00217, 18'sh0022b, 18'sh00239, 18'sh00241, 18'sh00243, 18'sh00240, 18'sh00237,
        18'sh0022a, 18'sh00217, 18'sh001ff, 18'sh001e3, 18'sh001c2, 18'sh0019e, 18'sh00177, 18'sh0014d, 18'sh00121, 18'sh000f2,
        18'sh000c3, 18'sh00092, 18'sh00061, 18'sh00030, 18'sh00000, 18'sh3ffd1, 18'sh3ffa3, 18'sh3ff77, 18'sh3ff4d, 18'sh3ff26,
        18'sh3ff01, 18'sh3fee0, 18'sh3fec3, 18'sh3fea9, 18'sh3fe93, 18'sh3fe80, 18'sh3fe72, 18'sh3fe68, 18'sh3fe63, 18'sh3fe61,
        18'sh3fe63, 18'sh3fe6a, 18'sh3fe74, 18'sh3fe82, 18'sh3fe93, 18'sh3fea7, 18'sh3febe, 18'sh3fed8, 18'sh3fef4, 18'sh3ff12,
        18'sh3ff32, 18'sh3ff53, 18'sh3ff75, 18'sh3ff98, 18'sh3ffbb, 18'sh3ffde, 18'sh00000, 18'sh00022, 18'sh00042, 18'sh00062,
        18'sh0007f, 18'sh0009b, 18'sh000b5, 18'sh000cc, 18'sh000e1, 18'sh000f3, 18'sh00103, 18'sh0010f, 18'sh00119, 18'sh00120,
        18'sh00124, 18'sh00125, 18'sh00123, 18'sh0011f, 18'sh00117, 18'sh0010d, 18'sh00101, 18'sh000f3, 18'sh000e2, 18'sh000d0,
        18'sh000bc, 18'sh000a7, 18'sh00091, 18'sh00079, 18'sh00061, 18'sh00049, 18'sh00030, 18'sh00018, 18'sh00000, 18'sh3ffe8,
        18'sh3ffd2, 18'sh3ffbc, 18'sh3ffa7, 18'sh3ff94, 18'sh3ff82, 18'sh3ff72, 18'sh3ff64, 18'sh3ff57, 18'sh3ff4c, 18'sh3ff44,
        18'sh3ff3d, 18'sh3ff38, 18'sh3ff36, 18'sh3ff35, 18'sh3ff37, 18'sh3ff3a, 18'sh3ff3f, 18'sh3ff46, 18'sh3ff4f, 18'sh3ff59,
        18'sh3ff64, 18'sh3ff71, 18'sh3ff7f, 18'sh3ff8d, 18'sh3ff9d, 18'sh3ffad, 18'sh3ffbd, 18'sh3ffce, 18'sh3ffdf, 18'sh3fff0,
        18'sh00000, 18'sh00010, 18'sh00020, 18'sh0002e, 18'sh0003c, 18'sh00049, 18'sh00055, 18'sh00060, 18'sh0006a, 18'sh00073,
        18'sh0007a, 18'sh0007f, 18'sh00084, 18'sh00087, 18'sh00088, 18'sh00089, 18'sh00087, 18'sh00085, 18'sh00082, 18'sh0007d,
        18'sh00077, 18'sh00070, 18'sh00068, 18'sh00060, 18'sh00056, 18'sh0004c, 18'sh00042, 18'sh00037, 18'sh0002c, 18'sh00021,
        18'sh00016, 18'sh0000b, 18'sh00000, 18'sh3fff5, 18'sh3ffeb, 18'sh3ffe1, 18'sh3ffd8, 18'sh3ffd0, 18'sh3ffc8, 18'sh3ffc1,
        18'sh3ffba, 18'sh3ffb5, 18'sh3ffb0, 18'sh3ffad, 18'sh3ffaa, 18'sh3ffa8, 18'sh3ffa7, 18'sh3ffa7, 18'sh3ffa8, 18'sh3ffa9,
        18'sh3ffac, 18'sh3ffaf, 18'sh3ffb3, 18'sh3ffb7, 18'sh3ffbd, 18'sh3ffc2, 18'sh3ffc8, 18'sh3ffcf, 18'sh3ffd5, 18'sh3ffdc,
        18'sh3ffe4, 18'sh3ffeb, 18'sh3fff2, 18'sh3fff9, 18'sh00000, 18'sh00007, 18'sh0000d, 18'sh00013, 18'sh00019, 18'sh0001f,
        18'sh00024, 18'sh00028, 18'sh0002c, 18'sh0002f, 18'sh00032, 18'sh00035, 18'sh00036, 18'sh00037, 18'sh00038, 18'sh00038,
        18'sh00037, 18'sh00036, 18'sh00035, 18'sh00032, 18'sh00030, 18'sh0002d, 18'sh0002a, 18'sh00026, 18'sh00022, 18'sh0001e,
        18'sh0001a, 18'sh00016, 18'sh00012, 18'sh0000d, 18'sh00009, 18'sh00004, 18'sh00000, 18'sh3fffc, 18'sh3fff8, 18'sh3fff4,
        18'sh3fff1, 18'sh3ffed, 18'sh3ffea, 18'sh3ffe8, 18'sh3ffe5, 18'sh3ffe3, 18'sh3ffe2, 18'sh3ffe0, 18'sh3ffdf, 18'sh3ffdf,
        18'sh3ffdf, 18'sh3ffdf, 18'sh3ffdf, 18'sh3ffe0, 18'sh3ffe1, 18'sh3ffe2, 18'sh3ffe4, 18'sh3ffe5, 18'sh3ffe7, 18'sh3ffe9,
        18'sh3ffec, 18'sh3ffee, 18'sh3fff1, 18'sh3fff3, 18'sh3fff6, 18'sh3fff8, 18'sh3fffb, 18'sh3fffe, 18'sh00000, 18'sh00002,
        18'sh00005, 18'sh00007, 18'sh00009, 18'sh0000b, 18'sh0000c, 18'sh0000e, 18'sh0000f, 18'sh00010, 18'sh00011, 18'sh00012,
        18'sh00012, 18'sh00013, 18'sh00013, 18'sh00013, 18'sh00012, 18'sh00012, 18'sh00011, 18'sh00011, 18'sh00010, 18'sh0000f,
        18'sh0000e, 18'sh0000c, 18'sh0000b, 18'sh0000a, 18'sh00008, 18'sh00007, 18'sh00006, 18'sh00004, 18'sh00003, 18'sh00001,
        18'sh00000, 18'sh3ffff, 18'sh3fffd, 18'sh3fffc, 18'sh3fffb, 18'sh3fffa, 18'sh3fff9, 18'sh3fff9, 18'sh3fff8, 18'sh3fff7,
        18'sh3fff7, 18'sh3fff7, 18'sh3fff6, 18'sh3fff6, 18'sh3fff6, 18'sh3fff6, 18'sh3fff6, 18'sh3fff7, 18'sh3fff7, 18'sh3fff7,
        18'sh3fff8, 18'sh3fff8, 18'sh3fff9, 18'sh3fffa, 18'sh3fffa, 18'sh3fffb, 18'sh3fffc, 18'sh3fffc, 18'sh3fffd, 18'sh3fffe,
        18'sh3ffff, 18'sh3ffff, 18'sh00000, 18'sh00001, 18'sh00001, 18'sh00002, 18'sh00002, 18'sh00003, 18'sh00003, 18'sh00004,
        18'sh00004, 18'sh00004, 18'sh00004, 18'sh00004, 18'sh00005, 18'sh00005, 18'sh00005, 18'sh00005, 18'sh00004, 18'sh00004,
        18'sh00004, 18'sh00004, 18'sh00004, 18'sh00003, 18'sh00003, 18'sh00003, 18'sh00003, 18'sh00002, 18'sh00002, 18'sh00002,
        18'sh00001, 18'sh00001, 18'sh00001, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh3ffff, 18'sh3ffff, 18'sh3ffff, 18'sh3ffff,
        18'sh3ffff, 18'sh3ffff, 18'sh3fffe, 18'sh3fffe, 18'sh3fffe, 18'sh3fffe, 18'sh3fffe, 18'sh3fffe, 18'sh3fffe, 18'sh3fffe,
        18'sh3fffe, 18'sh3fffe, 18'sh3fffe, 18'sh3fffe, 18'sh3ffff, 18'sh3ffff, 18'sh3ffff, 18'sh3ffff, 18'sh3ffff, 18'sh3ffff,
        18'sh3ffff, 18'sh3ffff, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000,
        18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00001, 18'sh00001, 18'sh00001, 18'sh00001, 18'sh00001, 18'sh00001,
        18'sh00001, 18'sh00001, 18'sh00001, 18'sh00001, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000,
        18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000,
        18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000, 18'sh00000
    };
    // END GENERATED: COEFF

    integer ci;
    initial begin
        for (ci = 0; ci < 10; ci = ci + 1) coeff_b[ci] = COEFF_B[ci*18 +: 18];
        for (ci = 10; ci < 16; ci = ci + 1) coeff_b[ci] = 18'sd0;
        for (ci = 0; ci < 618; ci = ci + 1) coeff_c[ci] = COEFF_C[ci*18 +: 18];
        for (ci = 618; ci < 1024; ci = ci + 1) coeff_c[ci] = 18'sd0;
    end

    always @(posedge clk) begin
        b_coef_q <= coeff_b[b_caddr];
        c_coef_q <= coeff_c[c_caddr];
    end

    pc9821_audio_fir_engine_ref #(
        .TAPS(19), .STRIDE(1), .RAM_AW(5), .CMIRROR(9), .COEF_AW(4), .SHIFT(17)
    ) u_fir_b (
        .clk(clk),
        .wr_en(b_wr), .wr_addr(b_waddr), .wr_l(cic_l), .wr_r(cic_r),
        .start(b_start), .start_addr(b_saddr), .phase(3'd0),
        .coef_addr(b_caddr), .coef_data(b_coef_q),
        /* verilator lint_off PINCONNECTEMPTY */   // busy is a simulation-only observation:
        .busy(),                                  // the top schedules from its own counters
        /* verilator lint_on PINCONNECTEMPTY */
        .done(b_done), .out_l(b_l), .out_r(b_r)
    );

    pc9821_audio_fir_engine_ref #(
        .TAPS(247), .STRIDE(5), .RAM_AW(8), .CMIRROR(617), .COEF_AW(10), .SHIFT(17)
    ) u_fir_c (
        .clk(clk),
        .wr_en(c_wr), .wr_addr(c_waddr), .wr_l(b_l), .wr_r(b_r),
        .start(c_start), .start_addr(c_saddr), .phase(c_phase),
        .coef_addr(c_caddr), .coef_data(c_coef_q),
        /* verilator lint_off PINCONNECTEMPTY */
        .busy(), .done(),
        /* verilator lint_on PINCONNECTEMPTY */
        .out_l(c_l), .out_r(c_r)
    );

    // ---- presentation: exactly one new sample per 512 CLK_AUDIO cycles ------
    // 2 457 600/48 000 = 512 and 24 576 000/48 000 = 512: the framework's DAC rate is this
    // register's change rate, exactly. A 9-bit counter has 512 states, so the load lands on
    // every (pr == 511) - 511, 1023, ... - i.e. 512 cycles apart, never 511.
    /* verilator lint_off PROCASSINIT */   // no reset in this domain: the seed is power-up
    reg [8:0] pr = 0;
    /* verilator lint_on PROCASSINIT */

    always @(posedge clk) begin
        pr <= pr + 9'd1;
        if (pr == 9'd511) begin
            out_l <= c_l;
            out_r <= c_r;
        end
    end

endmodule

`default_nettype wire
// CIC decimator, order 5, decimate by 4: 2.4576 MHz -> 614.4 kHz.
//
// Stage A of the 48 kHz output stage (see pc9821_audio_out_ref.sv for the whole plan). Its job
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
// ==== LOCAL CHANGE (resaudit-audioio P0, 2026-09-27) ================================
// The module is RE-IMPLEMENTED as one more instance of the shared pc9821_audio_fir_engine_ref
// (stages B/C are u_fir_b/u_fir_c in pc9821_audio_out_ref.sv; this is u_fir_a). The
// integrator/comb form that used to live here is just the FACTORED form of the full-rate
// FIR (1 + z^-1 + z^-2 + z^-3)^5, evaluated at the decimated phase - its 16 taps are
//
//   h = [1, 5, 15, 35, 65, 101, 135, 155, 155, 135, 101, 65, 35, 15, 5, 1]  (sum 1024 = 4^5)
//
// and the shipped output d5[25:10] was exactly floor((sum h_k x[4m-k]) / 1024) in 16-bit
// two's complement. The old mod-2^27 wraparound was exact because the true sum fits 26
// bits signed (|sum| <= 2^15 * 2^10 = 2^25, matching the +1 integrator-headroom note the
// old form carried at IW = 27); the engine computes acc = sum x*(h_k<<7) in 42 bits (no
// wrap possible, |acc| <= 2^32) and takes acc[32:17] = the same floor - its overflow clamp
// never fires for these coefficients. The value stream, the decimation phase (vcnt == 3,
// the old form's `decim`), the out_valid cadence and the gain are UNCHANGED: no gain, no
// clamp position and no filter response moved. Proof, both legs (run
// when the change landed): an arithmetic model (both modules' exact arithmetic re-implemented
// from their own semantics, 16 stimulus classes, 0 mismatches) and an RTL co-sim against the
// pre-change module (1160 output pairs, 0 mismatches).
//
// What the change BUYS (module-alone A&S, both variants real-topped): 284 ALMs / 530 ALUTs /
// 560 registers -> 124 ALMs / 148 ALUTs / 225 registers, +2 M10K +2 DSP (this instance's own two history
// RAMs and two multipliers; the baseline fit carried 71 free M10K and 57 free DSP).
//
// What it COSTS (a latency trade): compute latency grows by ~18 CLK_AUDIO
// cycles (~0.74 us) - a run is TAPS+3 = 19
// clk after the trigger valid (+2 clk start handoff) where the adder cascade answered in
// ~3 clk. Both finish inside the 40-clk group (2.4576 MHz valid spacing), runs never
// overlap (40-clk spacing vs 21-clk worst run), and the output sample STREAM and the
// 48 kHz cadence are unchanged; the chain's own group delay is 417 us, so this is +0.18%
// on an internal path nothing observes. The chain co-sim (run_chain.sh -> TB_EQUIV_CHAIN)
// measures the latency as PIN-EXACT: 0 mismatches over 334 848 clk x 5 stimulus classes,
// so the presentation margins absorb the shift at every 512-clk boundary.
//
// The old form sampled x_l AT the valid edge (its st==0 step) and x_r ONE CLK LATER (its
// st==1 step - the two-step integrator schedule). This form reproduces that sampling
// EXACTLY: the history write lands one clk after the valid and carries in_l latched at the
// valid edge and in_r as seen at the write edge. With production inputs (mix_pre is written
// ON the valid and held for 10 clk) the two edges see the same value and the replica is
// inert, but a stimulus that changes in_r between them (tb_pc9821_audio_out_timeline's
// per-clk staircases) sees the OLD form's own asymmetry - and this form matches it, so the
// rewrite is bit-exact for EVERY input stream, not only the production contract one. The
// first chain co-sim run proved the difference is real (98 presentations of 1-2 LSB on the
// right channel alone) before the replica was added.
//
// Two hardware rules this form must keep (invisible to every bench):
// - NO power-up seed and NO reset on q_l/q_r in the engine and on coef_q below - either
//   makes Quartus refuse the RAM and build the table out of LUTs (the kbd_lut trap,
//   res-mlab-REPORT section 7.2) and the whole area win evaporates with zero functional
//   change.
// - CMIRROR = 15, deliberately: the engine's mirror (midx = 2*CMIRROR - idx) supports
//   ODD-length prototypes only (2*CMIRROR+1 taps), and this prototype is EVEN (16 taps,
//   symmetry centre 7.5). An integer mirror centre is wrong - CMIRROR=8 mirrors tap 9 to
//   coeff[7] (155<<7 where the response wants 135<<7), a plausible-but-wrong filter that
//   only sample-exact comparison catches (measured: the co-sim fails from output 0).
//   So the full 16-entry table is stored and
//   the mirror never fires.
// ==== end LOCAL CHANGE ==============================================================
`default_nettype none

module pc9821_audio_cic4_ref (
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
    // in_r is taken live at the write edge. That is the old form's sampling asymmetry
    // replicated to the cycle (x_l at the valid edge, x_r one clk later - see the LOCAL
    // CHANGE block), and with the production held-input contract it is inert.
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
            in_l_q  <= in_l;      // x_l sampled AT the valid edge (old st==0)
            wptr    <= wptr + 5'd1;
            vcnt    <= vcnt + 2'd1;
            if (vcnt == 2'd3) begin   // the same decimation phase as the old form's `decim`
                start <= 1'b1;
                saddr <= wptr;
            end
        end
    end

    // ---- coefficient ROM (all 16 entries of the 16-tap prototype) ----
    // h = (1+x+x^2+x^3)^5, coef = h<<7, Q17 as the engine expects. LUT logic at this size,
    // like pc9821_audio_out_ref's coeff_b. coef_q is the registered read and deliberately
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
    pc9821_audio_fir_engine_ref #(
        .TAPS(16), .STRIDE(1), .RAM_AW(5), .CMIRROR(15), .COEF_AW(4), .SHIFT(17)
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
// One decimating FIR MAC engine for the 48 kHz output stage, used twice per channel: as
// stage B (decimate by 2) and as stage C (the 5/16 polyphase resampler). It owns its two
// history RAMs and two multipliers (left and right in parallel, so one tap costs one clock),
// reads its coefficients through a port so the PARENT holds one shared ROM for both
// channels, and is otherwise a pure "run TAPS taps and hand back the answer" machine.
//
// Fixed 2-deep MAC pipeline, one tap per clock (addresses issued at cycle c):
//   end of c   : history and coefficient registers load  (RAM in here, ROM in the parent)
//   end of c+1 : product registers load
//   c+2        : the product is accumulated
// A run is therefore TAPS+3 clocks and the accumulator's final value is latched in the last.
//
// History addressing: the tap window is the TAPS samples ending at `start_addr`, read as
// start_addr - k on a circular buffer. The buffer is deliberately larger than the window
// (32 vs 19, 128 vs 123) so a write landing during a run can never overwrite a sample the run
// still needs - and a write to the address being read that cycle reads back the OLD value,
// which is the value that tap wants anyway.
//
// Coefficients are Q17 signed and the table is symmetric about CMIRROR; the parent stores
// only the first half, so the address is mirrored here (one compare and one subtractor, and
// half the ROM - 308 entries fits one M10K where 615 would not).
//
// The CLK_AUDIO domain has no reset, so every register is seeded and the state machine only
// ever moves to a defined state (st has no undefined encoding: 2'd0 and 2'd1 are the only
// live ones and `default` returns to idle).
`default_nettype none

module pc9821_audio_fir_engine_ref #(
    parameter integer TAPS    = 19,   // taps per output (per channel)
    parameter integer STRIDE  = 1,    // coefficient address step per tap
    parameter integer RAM_AW  = 5,    // history RAM address width (window + margin)
    parameter integer CMIRROR = 9,    // prototype symmetry centre: coefficient (2*CMIRROR - m)
    parameter integer COEF_AW = 4,    // coefficient address width after mirroring
    parameter integer SHIFT   = 17    // Q17 coefficients -> output
)(
    input  wire                    clk,

    // History write port: one sample of each channel per pulse.
    input  wire                    wr_en,
    input  wire [RAM_AW-1:0]       wr_addr,
    input  wire signed [15:0]      wr_l,
    input  wire signed [15:0]      wr_r,

    // One run.
    input  wire                    start,
    input  wire [RAM_AW-1:0]       start_addr,   // address of the newest sample of the window
    input  wire [2:0]              phase,        // polyphase offset (0 when STRIDE = 1)

    // Coefficients live outside so both channels share one ROM (and one read port). The
    // parent's read must be the registered one: no power-up value and no reset on it, or
    // Quartus refuses the memory and builds the table out of LUTs.
    output wire [COEF_AW-1:0]      coef_addr,
    input  wire signed [17:0]      coef_data,

    output reg                     busy,
    output reg                     done,
    output reg  signed [15:0]      out_l,
    output reg  signed [15:0]      out_r
);

    (* ramstyle = "M10K" *) reg signed [15:0] ram_l [0:(1<<RAM_AW)-1];
    (* ramstyle = "M10K" *) reg signed [15:0] ram_r [0:(1<<RAM_AW)-1];

    // Power-up contents: silence. A memory cannot be reset, so this seed is the whole of its
    // initialisation (the same reason ssg_reg in pc9821_opna carries none) - without it the
    // first outputs after power-up would be built from X.
    integer i;
    initial begin
        for (i = 0; i < (1<<RAM_AW); i = i + 1) begin
            ram_l[i] = 16'sd0;
            ram_r[i] = 16'sd0;
        end
    end

    /* verilator lint_off PROCASSINIT */   // the seeds ARE this domain's power-up state
    reg [RAM_AW-1:0] base = 0;
    reg [1:0]        st   = 0;      // 0 idle, 1 running
    reg [7:0]        cyc  = 0;      // 1 .. TAPS+3 (TAPS <= 123 here, so 8 bits is exact)
    reg [2:0]        ph   = 0;

    // One-deep request buffer: every `start` produces exactly one `done`, even if a start
    // lands while a run is in flight. The caller's schedule never needs it (B runs 22 of
    // every 160 clk, C 126 of every 512) - but a silently dropped start would be a dropped
    // audio sample, and that is worth three registers to make impossible.
    reg              pend      = 0;
    reg [RAM_AW-1:0] pend_addr = 0;
    reg [2:0]        pend_ph   = 0;
    /* verilator lint_on PROCASSINIT */

    // Sample address for this cycle's tap. Free-running wraparound is the point: the RAM's
    // address space is a power of two, so base-k wraps by itself.
    wire [RAM_AW-1:0] tap_addr = base - (cyc[RAM_AW-1:0] - 1'b1);

    // Coefficient index, mirrored about the prototype centre. Stride and phase are applied
    // on the prototype BEFORE mirroring, which is what makes the five phases work.
    // Widths are explicit: the index never exceeds the prototype length (123*5 = 615), so
    // 12 bits carry stride*k + phase exactly and the product cannot truncate.
    localparam [11:0] STRIDE_W = 12'(STRIDE);
    localparam [11:0] MID_W    = 12'(CMIRROR);
    wire [11:0] kk   = {4'b0, cyc} - 12'd1;
    wire [11:0] idx  = (STRIDE_W * kk) + {9'b0, ph};
    /* verilator lint_off UNUSEDSIGNAL */   // bits above COEF_AW are the prototype length
    wire [11:0] midx = (idx > MID_W) ? ((MID_W + MID_W) - idx) : idx;
    /* verilator lint_on UNUSEDSIGNAL */
    assign coef_addr = midx[COEF_AW-1:0];

    // Pipeline stage 1: history and coefficient. q_* is the RAM's registered read (coef_data
    // is already registered in the parent, one clock after coef_addr).
    //
    // q_l/q_r carry NO power-up value and NO reset, and that is a hardware rule, not a
    // style one: a seed or a reset on the register that captures a memory read makes Quartus
    // refuse the RAM and build the whole history out of LUTs (the kbd_lut trap,
    // res-mlab-REPORT section 7.2). Their first value before any run is X in 4-state
    // simulation and is never used - the engine only accumulates inside a run, and a run
    // always issues TAPS addresses first.
    reg signed [15:0] q_l, q_r;
    // Pipeline stage 2: product.
    reg signed [33:0] prod_l, prod_r;
    // Pipeline stage 3: accumulator. 34-bit products with 7 bits of tap growth (TAPS <= 128).
    reg signed [41:0] acc_l, acc_r;

    // Q17 accumulator -> 16-bit, saturating. The accumulator's 42 bits are products (34)
    // plus tap growth (<= 7); SHIFT+15 is the sign bit of the 16-bit result, so anything
    // above it that is not that sign is an overflow, saturated toward the sign of the true
    // sum, acc[41]. FIXED here as in the engine: the 3b134fe4 text took the rail from
    // acc[OSB], which on an overflow is the inverted sign (+overshoot -> -32768), and the
    // filters' step overshoot (5-9%) does reach this clamp from the signal; with the old
    // rail kept here the equivalence bench agreed with the same bug in the RTL.
    localparam integer OSB = SHIFT + 15;               // 32
    localparam integer OVW = 41 - OSB;                 // 9
    wire ovf_l = (acc_l[41:OSB+1] != {OVW{acc_l[OSB]}});
    wire ovf_r = (acc_r[41:OSB+1] != {OVW{acc_r[OSB]}});
    wire signed [15:0] y_l = ovf_l ? (acc_l[41] ? 16'sh8000 : 16'sh7FFF) : acc_l[OSB -: 16];
    wire signed [15:0] y_r = ovf_r ? (acc_r[41] ? 16'sh8000 : 16'sh7FFF) : acc_r[OSB -: 16];

    always @(posedge clk) begin
        done <= 1'b0;

        if (wr_en) begin
            ram_l[wr_addr] <= wr_l;
            ram_r[wr_addr] <= wr_r;
        end

        q_l <= ram_l[tap_addr];
        q_r <= ram_r[tap_addr];
        prod_l <= q_l * coef_data;
        prod_r <= q_r * coef_data;

        case (st)
            2'd0: begin
                      // Consume a buffered request first, then take this cycle's start. The
                      // order matters: a start arriving exactly now must survive, so it is
                      // captured (last write wins) rather than lost to the consume.
                      if (pend) begin
                          base  <= pend_addr;
                          ph    <= pend_ph;
                          cyc   <= 8'd1;
                          acc_l <= 42'sd0;
                          acc_r <= 42'sd0;
                          st    <= 2'd1;
                          busy  <= 1'b1;
                          pend  <= 1'b0;
                      end
                      if (start) begin
                          pend      <= 1'b1;
                          pend_addr <= start_addr;
                          pend_ph   <= phase;
                      end
                  end
            2'd1: begin
                      if (start) begin
                          pend      <= 1'b1;
                          pend_addr <= start_addr;
                          pend_ph   <= phase;
                      end
                      // Tap k is issued at cyc = k+1 and accumulated at cyc = k+3.
                      if ((cyc >= 8'd3) && (cyc <= 8'(TAPS + 2))) begin
                          acc_l <= acc_l + {{8{prod_l[33]}}, prod_l};
                          acc_r <= acc_r + {{8{prod_r[33]}}, prod_r};
                      end
                      if (cyc == 8'(TAPS + 3)) begin
                          out_l <= y_l;
                          out_r <= y_r;
                          done  <= 1'b1;
                          busy  <= 1'b0;
                          st    <= 2'd0;
                      end
                      else cyc <= cyc + 8'd1;
                  end
            default: st <= 2'd0;
        endcase
    end

endmodule

`default_nettype wire
