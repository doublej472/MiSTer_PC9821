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
//   A  pc9821_audio_cic4      decimate 4    2 457 600 -> 614 400 Hz   (boxcar^5: u_fir_a)
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

module pc9821_audio_out (
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

    pc9821_audio_cic4 u_cic (
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

    // ---- stage C: 5/32 polyphase resampler ---------------------------------
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

    pc9821_audio_fir_engine #(
        .TAPS(19), .STRIDE(1), .RAM_AW(5), .CMIRROR(9), .COEF_AW(4), .SHIFT(17), .HOLD_OUT(0)
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

    pc9821_audio_fir_engine #(
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
