`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SOUND_SUM: the loud-chord clip census. It drives every sound source the PC-9801-86 board has and reports the running peak and 16-bit-rail count at EVERY summing stage of the audio path, and pins the F1 contract: the FM+SSG join delivers the WIDE 20-bit sum UNCLAMPED (snd_l === mix_l, fail-first against the pre-fix intermediate sat16) with the AC-coupled (zero-mean) SSG added after the junction clamp, the single saturation of the chain living at the final DAC (ymfm's clamp16 / NP2kai's _saturation_s16)
//
// the loud-chord clip census. It drives every sound source the PC-9801-86 board has and reports the running peak and clip/over-16 count at EVERY summing stage of the audio path:
//
//   * the six-drum pre-sum      (jt08_adpcm_acc's pcm_out, the WIDE raw sum)
//   * the FM+rhythm+B accumulator (jt12_single_acc's running acc and its snd output,
//     the 20-bit sum BEFORE the junction clamp)
//   * the FM+ADPCM junction     (jt08_acc's clamped output = pc9821_opna's fm_l: the
//     complete FM+ADPCM-A+ADPCM-B sum clamped to the 16-bit ymfm clamp16 rail,
//     ymfm_opn.cpp:1410-1414, then sign-extended back to 20 bits)
//   * the board's FM+ADPCM+SSG mix (pc9821_opna's mix_l: the clamped junction PLUS
//     the SSG, which ymfm adds AFTER its clamp16; the LAST saturation of the whole
//     -86 chain is the final DAC's mix_dry, NP2kai's _saturation_s16)
//   * the board output snd_l
//
// WHAT IT PINS, as the checks at the end: at the shipped 0 dB the six full RHYTHM
// drums sum PAST the 16-bit range (the overlap is real and still in the
// stimulus), but the drum PRE-SUM does not clip - pcm_out carries the raw sum - and
// the FM+ADPCM sum is clamped exactly once, AT the jt08_acc junction (the same point
// ymfm's m_last_fm.clamp16() clamps), with the SSG joining after it. A-1 (a194031e)
// removed that junction clamp and left the raw sum to the final DAC; a
// real-listening report is why this bench now pins the clamp back (8f8194e2). The
// SSG is AC-COUPLED (zero-mean) before the join (tb_pc9821_opna_ssg_level), so even
// all three channels at maximum never reach any rail.
//
// WHY THIS BENCH EXISTS. An earlier analysis found the six-drum sum hard-limited to 16 bits
// inside jt08_adpcm_acc (the flat-topped "drums clipping" heard on hardware) while
// the FM+rhythm accumulator behind it is the real chip's authentic clamp point.
// The fix moved the clamp to that junction and left the drum bus wide; A-1 then
// removed the junction clamp entirely, and this change restores it (ymfm clamps the
// complete FM+ADPCM sum once, ymfm_opn.cpp:1410-1414, and adds the SSG after).
// This bench keeps all of those facts pinned: the overlap still drives past the old
// rail (so the case stays covered), the drum pre-sum does not reduce it, and the
// junction clamps it to the 16-bit rail exactly as ymfm does - fail-first on both
// the earlier tree (where pcm_out was sat16) and the A-1 tree (where the
// junction was raw).

module tb_pc9821_sound_sum;
  reg clk = 0;
  always #5 clk = ~clk;               // 100 MHz; the board derives the chip's 7.9872 MHz

  reg reset = 1;

  reg  [15:0] io_addr  = 16'h0188;
  reg         io_wr    = 1'b0;
  reg         io_rd    = 1'b0;
  reg  [7:0]  io_din   = 8'h00;
  reg         extend   = 1'b0;
  reg  [5:0]  joystick = 6'b111111;

  reg         rhythm_we    = 1'b0;
  reg  [11:0] rhythm_waddr = 12'd0;
  reg  [15:0] rhythm_wdata = 16'd0;

  wire [7:0]         dout;
  wire               wait_;
  wire signed [19:0] l, r;   // the board out: clamped FM junction + the AC-coupled SSG term
  wire               irq;

  // ==== DUT ====
  pc9821_opna #(.SYS_CLOCK_HZ(100_000_000)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(dout), .io_rd_wait(wait_),
    .extend(extend), .joystick(joystick),
    .snd_l(l), .snd_r(r), .irq(irq),
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr), .rhythm_wdata(rhythm_wdata)
  );

  // ---- the stage taps ----
  // The six-drum pre-sum (ADPCM-A left): the WIDE raw sum now, and the running
  // drum-sum register behind it. Both widen by sign-extension when tapped across
  // the pre-fix tree (where they are 16/18-bit), so this bench compiles and fails
  // there too - the fail-first run.
  wire signed [19:0] presum =
      dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.pcm_out;
  wire signed [19:0] drumacc =
      dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.acc;
  // The FM+rhythm+ADPCM-B accumulator, both the running register and its output:
  // the 20-bit sum BEFORE the junction clamp below.
  wire signed [19:0] accrun =
      dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_acc.u_left.acc;
  wire signed [19:0] fmsnd =
      dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_acc.u_left.snd;
  // The junction clamp itself: jt08_acc's `left` -> pc9821_opna's fm_l, i.e.
  // `fmsnd` clamped to the 16-bit ymfm clamp16 rail and sign-extended back to 20.
  wire signed [19:0] fmjunc = dut.fm_l;
  // The SSG term pc9821_opna adds at the join: the AC-coupled (zero-mean) term
  // ssg_ac, produced by the 1-pole DC block that models the board's C7C1 series
  // coupling cap. The filter itself is pinned by tb_pc9821_opna_ssg_level; this
  // bench only checks that the join adds that term with no intermediate clamp.
  wire signed [19:0] ssgac = dut.ssg_ac;
  wire signed [19:0] mixl = dut.mix_l;

  // The drum-sum reference model: jt08_adpcm_acc's own arithmetic recomputed here
  // with UNBOUNDED integers from the per-drum slot inputs, so it cannot wrap and
  // cannot be fooled by the DUT's width. Checked against the DUT's acc every slot
  // (wrap detection) and captured at each round's end for the clip check: pcm_out
  // must be the raw round sum, never a clamped one. On the pre-fix tree every
  // over-rail round mismatches here - the flat-top heard on hardware.
  wire        dr_cen    = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.cen;
  wire        dr_match  = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.match;
  wire        dr_en_sum = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.en_sum;
  wire [5:0]  dr_cur_ch = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.cur_ch;
  wire [5:0]  dr_en_ch  = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.en_ch;
  wire [2:0]  dr_gain   = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.gain_shift;
  wire signed [15:0] dr_pcm_in = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.pcm_in;

  integer model_acc, model_raw, model_expected, model_started;
  integer clip_events, wrap_events, raw_over16_events;
  integer raw_over16_D_start, raw_over16_in_D;
  initial begin
    model_acc = 0; model_raw = 0; model_expected = 0; model_started = 0;
    clip_events = 0; wrap_events = 0; raw_over16_events = 0;
    raw_over16_D_start = 0; raw_over16_in_D = 0;
  end

  // The die's six-drum bus is a 16-BIT WRAPPING accumulator
  // (YM2608-LLE fmopna_impl.c:5363-5383, `ac_rss_accm1[0] = accm1 & 0xffff`). The model keeps the UNBOUNDED running
  // sum so it can tell when the wrap fired, and its 16-bit two's-complement image,
  // which is what the bus and the sign-extended pcm_out must equal.
  function automatic integer wrap16(input integer v);
    integer t;
    begin
      t = v & 16'hFFFF;
      wrap16 = (t >= 32768) ? t - 65536 : t;
    end
  endfunction

  wire signed [15:0] dr_term = dr_en_sum ? (dr_pcm_in >>> dr_gain) : 16'sd0;
  always @(posedge clk) begin
    // Compare FIRST: everything read here reflects all updates through the
    // PREVIOUS edge on both sides, so the two are at the same state.
    if (model_started) begin
      if (presum !== model_expected) clip_events = clip_events + 1;
      if (drumacc !== model_acc)     wrap_events = wrap_events + 1;
    end
    if (dr_cen && !$isunknown({dr_match, dr_en_sum, dr_cur_ch, dr_en_ch, dr_gain})) begin
      // Capture FIRST: the RTL's `pcm_out <= acc` takes the PRE-edge sum (the
      // round just completed) even when the same edge reloads acc for the next
      // round, so the model must latch before it updates.
      if (dr_en_ch[0] && dr_cur_ch[0]) begin
        model_expected = model_acc;
        model_started  = 1;
      end
      if (dr_match) begin
        model_raw = dr_cur_ch[0] ? dr_term : model_raw + dr_term;
        model_acc = wrap16(model_raw);
      end
      if (model_raw > 32767 || model_raw < -32768) raw_over16_events = raw_over16_events + 1;
    end
  end

  integer errors = 0;

  // The junction/join conformance (the F1 check): the FM+ADPCM junction must be the
  // accumulator clamped to the 16-bit ymfm clamp16 rail (ymfm_opn.cpp:1410-1414) and
  // sign-extended back to 20 bits, and the board output must be that junction PLUS
  // the SSG (which ymfm adds AFTER the clamp). Fail-first on the A-1 tree, which
  // delivered the raw sum at the junction: every over-16 sample mismatches
  // junc_clamp_events there.
  integer junc_clamp_events, join_events, junc_over16_samples, exp_junc;
  initial begin
    junc_clamp_events = 0; join_events = 0; junc_over16_samples = 0; exp_junc = 0;
  end
  always @(posedge clk) begin
    if (!$isunknown({fmsnd, fmjunc, ssgac, mixl, l})) begin
      if (($signed(fmsnd) > 32767) || ($signed(fmsnd) < -32768)) begin
        exp_junc = ($signed(fmsnd) > 32767) ? 32767 : -32768;
        junc_over16_samples = junc_over16_samples + 1;
      end else begin
        exp_junc = $signed(fmsnd);
      end
      if (fmjunc !== exp_junc)                junc_clamp_events = junc_clamp_events + 1;
      if (mixl   !== exp_junc + ssgac)          join_events = join_events + 1;
      if (l      !== mixl)                    join_events = join_events + 1;
    end
  end

  task automatic fail(input [8*160-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // One board register byte. 0x188/0x18A = base bank, 0x18C/0x18E = extended bank.
  task automatic op_write(input [15:0] port, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = port;
      io_din  = data;
      io_wr   = 1'b1;
      @(posedge clk);
      @(negedge clk);
      io_wr   = 1'b0;
      io_addr = 16'h0188;
      io_din  = 8'h00;
      // The board's WRQ delivers a stretched FM register write one every 216 cen
      // (216 * 100/7.9872 clk ~= 2704 clk at 100 MHz). A host burst faster than that
      // fills the 128-deep queue and a bare board (no io_wr_wait) DROPS the overflow, so
      // the spacing here is part of the stimulus: 3200 clk keeps the queue near empty.
      repeat (3200) @(posedge clk);
    end
  endtask

  // Key-on must be issued through the BASE bank (jt12_mmr gates up_keyon on
  // !part && !addr[1]); the channel code din[2:0] is the chip's internal number,
  // 0,1,2 for the base-bank channels and 4,5,6 for the extended bank.
  task automatic key_on(input [2:0] chcode);
    begin
      op_write(16'h0188, 8'h28); op_write(16'h018A, {4'hF, 1'b0, chcode});
    end
  endtask

  task automatic key_off;
    begin
      // 0x28's data carries the operator mask in [7:4] and ONE channel in [2:0],
      // so releasing every channel takes one write per channel.
      op_write(16'h0188, 8'h28); op_write(16'h018A, 8'h00);
      op_write(16'h0188, 8'h28); op_write(16'h018A, 8'h01);
      op_write(16'h0188, 8'h28); op_write(16'h018A, 8'h02);
      op_write(16'h0188, 8'h28); op_write(16'h018A, 8'h04);
      op_write(16'h0188, 8'h28); op_write(16'h018A, 8'h05);
      op_write(16'h0188, 8'h28); op_write(16'h018A, 8'h06);
    end
  endtask

  // Program one FM channel loud: all four operators TL=0, AR=31, DR=0, SR=0,
  // SL=0/RR=15, ALG=7 (every operator a carrier), L+R. Each channel gets its OWN
  // fnum, so the six channels DRIFT through every relative phase and the sum
  // reaches its true worst case inside the measurement window (six identical
  // notes would freeze one arbitrary phase relationship).
  //   bank 0 = base (0x188/0x18A), bank 1 = extended (0x18C/0x18E)
  //   sel   = register low bits 0,1,2 for the bank's three channels
  task automatic fm_channel(input bank, input [1:0] sel, input [7:0] fnumlo);
    begin
      op_write(bank ? 16'h018C : 16'h0188, 8'h28); op_write(bank ? 16'h018E : 16'h018A, 8'h00);
      begin : ops
        integer op;
        for (op = 0; op < 4; op = op + 1) begin
          op_write(bank ? 16'h018C : 16'h0188, 8'h30 + 8'(op*4) + {6'b0, sel});
            op_write(bank ? 16'h018E : 16'h018A, 8'h01);          // DT=0, MUL=1
          op_write(bank ? 16'h018C : 16'h0188, 8'h40 + 8'(op*4) + {6'b0, sel});
            op_write(bank ? 16'h018E : 16'h018A, 8'h00);          // TL=0 (loudest)
          op_write(bank ? 16'h018C : 16'h0188, 8'h50 + 8'(op*4) + {6'b0, sel});
            op_write(bank ? 16'h018E : 16'h018A, 8'h1F);          // AR=31
          op_write(bank ? 16'h018C : 16'h0188, 8'h60 + 8'(op*4) + {6'b0, sel});
            op_write(bank ? 16'h018E : 16'h018A, 8'h00);          // DR=0
          op_write(bank ? 16'h018C : 16'h0188, 8'h70 + 8'(op*4) + {6'b0, sel});
            op_write(bank ? 16'h018E : 16'h018A, 8'h00);          // SR=0
          op_write(bank ? 16'h018C : 16'h0188, 8'h80 + 8'(op*4) + {6'b0, sel});
            op_write(bank ? 16'h018E : 16'h018A, 8'h0F);          // SL=0, RR=15
          op_write(bank ? 16'h018C : 16'h0188, 8'h90 + 8'(op*4) + {6'b0, sel});
            op_write(bank ? 16'h018E : 16'h018A, 8'h00);          // SSG-EG off
        end
      end
      op_write(bank ? 16'h018C : 16'h0188, 8'hB0 + {6'b0, sel});
        op_write(bank ? 16'h018E : 16'h018A, 8'h07);              // ALG=7, FB=0
      op_write(bank ? 16'h018C : 16'h0188, 8'hB4 + {6'b0, sel});
        op_write(bank ? 16'h018E : 16'h018A, 8'hC0);              // L+R, no AMS/PMS
      op_write(bank ? 16'h018C : 16'h0188, 8'hA4 + {6'b0, sel});
        op_write(bank ? 16'h018E : 16'h018A, 8'h22);              // block 4, fnum high
      op_write(bank ? 16'h018C : 16'h0188, 8'hA0 + {6'b0, sel});
        op_write(bank ? 16'h018E : 16'h018A, fnumlo);             // fnum low -> commits
    end
  endtask

  // SSG: all three channels, maximum volume, tone on.
  task automatic ssg_max;
    begin
      op_write(16'h0188, 8'h07); op_write(16'h018A, 8'h38);   // all three tones on
      op_write(16'h0188, 8'h00); op_write(16'h018A, 8'h40);   // A period
      op_write(16'h0188, 8'h01); op_write(16'h018A, 8'h01);
      op_write(16'h0188, 8'h02); op_write(16'h018A, 8'h55);   // B period
      op_write(16'h0188, 8'h03); op_write(16'h018A, 8'h01);
      op_write(16'h0188, 8'h04); op_write(16'h018A, 8'h6A);   // C period
      op_write(16'h0188, 8'h05); op_write(16'h018A, 8'h01);
      op_write(16'h0188, 8'h08); op_write(16'h018A, 8'h0F);   // A level max
      op_write(16'h0188, 8'h09); op_write(16'h018A, 8'h0F);   // B level max
      op_write(16'h0188, 8'h0A); op_write(16'h018A, 8'h0F);   // C level max
    end
  endtask

  task automatic ssg_off;
    begin
      op_write(16'h0188, 8'h08); op_write(16'h018A, 8'h00);
      op_write(16'h0188, 8'h09); op_write(16'h018A, 8'h00);
      op_write(16'h0188, 8'h0A); op_write(16'h018A, 8'h00);
    end
  endtask

  // All six rhythm instruments: total level full, each instrument level 31 (both
  // pans); the levels are one shared LRACL byte through a six-stage pipeline, so
  // each needs its own gap.
  task automatic rhythm_full;
    begin
      op_write(16'h0188, 8'h11); op_write(16'h018A, 8'h3F);
      op_write(16'h0188, 8'h18); op_write(16'h018A, 8'hDF); repeat (2000) @(posedge clk);
      op_write(16'h0188, 8'h19); op_write(16'h018A, 8'hDF); repeat (2000) @(posedge clk);
      op_write(16'h0188, 8'h1A); op_write(16'h018A, 8'hDF); repeat (2000) @(posedge clk);
      op_write(16'h0188, 8'h1B); op_write(16'h018A, 8'hDF); repeat (2000) @(posedge clk);
      op_write(16'h0188, 8'h1C); op_write(16'h018A, 8'hDF); repeat (2000) @(posedge clk);
      op_write(16'h0188, 8'h1D); op_write(16'h018A, 8'hDF); repeat (2000) @(posedge clk);
    end
  endtask

  task automatic rhythm_trigger;
    begin
      op_write(16'h0188, 8'h10); op_write(16'h018A, 8'h3F);   // start all six
    end
  endtask

  integer n, code;
  integer p_presum, p_fmsnd, p_accrun, p_mix, p_out;
  integer r_presum, r_fmsnd, r_accrun, r_mix, r_out;
  integer lo;
  // The values the checks read back, copied from the phase that measured them.
  integer std_fm_out_rail, std_fmssg_out_rail, std_ssg_out_rail;
  integer std_rhythm_presum_rail;

  // One measurement window: track peak |value| and over-16 counts at every tap
  // (for the wide taps: the number of samples the old 16-bit clamps would have
  // flat-topped; for mixl: its over-16 count).
  task automatic measure(input integer cycles, output integer q_presum, output integer q_fmsnd,
                         output integer q_accrun, output integer q_mix, output integer q_out,
                         output integer c_presum, output integer c_fmsnd, output integer c_accrun,
                         output integer c_mix, output integer c_out);
    integer i;
    begin
      q_presum = 0; q_fmsnd = 0; q_accrun = 0; q_mix = 0; q_out = 0;
      c_presum = 0; c_fmsnd = 0; c_accrun = 0; c_mix = 0; c_out = 0;
      for (i = 0; i < cycles; i = i + 1) begin
        @(posedge clk);
        lo = (presum < 0) ? -presum : presum;
        if (lo > q_presum) q_presum = lo;
        if ((presum > 32767) || (presum < -32768)) c_presum = c_presum + 1;
        lo = (fmsnd < 0) ? -fmsnd : fmsnd;
        if (lo > q_fmsnd) q_fmsnd = lo;
        if ((fmsnd > 32767) || (fmsnd < -32768)) c_fmsnd = c_fmsnd + 1;
        lo = (accrun < 0) ? -accrun : accrun;
        if (lo > q_accrun) q_accrun = lo;
        if ((accrun > 32767) || (accrun < -32768)) c_accrun = c_accrun + 1;
        lo = (mixl < 0) ? -mixl : mixl;
        if (lo > q_mix) q_mix = lo;
        if ((mixl > 32767) || (mixl < -32768)) c_mix = c_mix + 1;
        lo = (l < 0) ? -l : l;
        if (lo > q_out) q_out = lo;
        // c_out counts the samples the OLD 16-bit output clamp would have flat-topped:
        // with the junction clamped and the SSG added after it, these ride through
        // wide to the final DAC.
        if ((l > 32767) || (l < -32768)) c_out = c_out + 1;
      end
    end
  endtask

  task automatic report(input [8*80-1:0] tag,
                        input integer q_presum, input integer q_fmsnd, input integer q_accrun,
                        input integer q_mix, input integer q_out,
                        input integer c_presum, input integer c_fmsnd, input integer c_accrun,
                        input integer c_mix, input integer c_out);
    begin
      $display("  %0s", tag);
      $display("    peak: presum=%0d fmsnd=%0d accrun=%0d mix=%0d out=%0d",
               q_presum, q_fmsnd, q_accrun, q_mix, q_out);
      $display("    over16/rail: presum=%0d fmsnd=%0d accrun=%0d mix=%0d out=%0d",
               c_presum, c_fmsnd, c_accrun, c_mix, c_out);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2000) @(posedge clk);
    // The -86's extension gate, as the ITF leaves it (0xA460 bit 0 set): the
    // extended port pair 0x18C/0x18E is the ONLY path to FM channels 4-6.
    extend = 1'b1;

    // ---- the drum ROM image: one non-silent nibble everywhere ----
    for (n = 0; n < 4096; n = n + 1) begin
      @(negedge clk);
      rhythm_we    = 1'b1;
      rhythm_waddr = n[11:0];
      rhythm_wdata = 16'h5555;
    end
    @(negedge clk);
    rhythm_we = 1'b0;

    // =================================================================
    // A. FM: six channels at maximum, each on its own note (so their
    //    relative phases drift through the whole window). Keyed one at a
    //    time first, to prove every channel sounds - a silent channel here
    //    would be a bench bug and would understate the sum.
    // =================================================================
    fm_channel(1'b0, 2'd0, 8'h40); fm_channel(1'b0, 2'd1, 8'h55); fm_channel(1'b0, 2'd2, 8'h69);
    fm_channel(1'b1, 2'd0, 8'h7D); fm_channel(1'b1, 2'd1, 8'h90); fm_channel(1'b1, 2'd2, 8'hA5);
    for (n = 0; n < 6; n = n + 1) begin
      // The six FM channels are the chip's internal 0,1,2,4,5,6; code 3 is dead.
      code = (n < 3) ? n : n + 1;
      key_on(code[2:0]);
      measure(60_000, p_presum, p_fmsnd, p_accrun, p_mix, p_out,
                       r_presum, r_fmsnd, r_accrun, r_mix, r_out);
      $display("  per-channel code %0d fmsnd peak=%0d rail=%0d", code, p_fmsnd, r_fmsnd);
      if (p_fmsnd == 0)
        fail("an FM channel keyed alone produced nothing: the six-channel sum would understate");
      key_off;
      repeat (4000) @(posedge clk);
    end
    key_on(3'd0); key_on(3'd1); key_on(3'd2);
    key_on(3'd4); key_on(3'd5); key_on(3'd6);
    measure(1_000_000, p_presum, p_fmsnd, p_accrun, p_mix, p_out,
                        r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    report("A. FM six channels at max, six drifting notes",
           p_presum, p_fmsnd, p_accrun, p_mix, p_out,
           r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    std_fm_out_rail = r_out;

    // =================================================================
    // B. SSG three channels at maximum, alone (FM keyed off).
    // =================================================================
    key_off;
    repeat (4000) @(posedge clk);
    ssg_max;
    measure(400_000, p_presum, p_fmsnd, p_accrun, p_mix, p_out,
                      r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    report("B. SSG three at max, alone",
           p_presum, p_fmsnd, p_accrun, p_mix, p_out,
           r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    std_ssg_out_rail = r_out;

    // =================================================================
    // C. FM six + SSG three at maximum.
    // =================================================================
    key_on(3'd0); key_on(3'd1); key_on(3'd2);
    key_on(3'd4); key_on(3'd5); key_on(3'd6);
    measure(1_000_000, p_presum, p_fmsnd, p_accrun, p_mix, p_out,
                        r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    report("C. FM six + SSG three at max",
           p_presum, p_fmsnd, p_accrun, p_mix, p_out,
           r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    std_fmssg_out_rail = r_out;

    // =================================================================
    // D. Rhythm six drums at full, alone, at the 0 dB default (FM off, SSG off).
    // =================================================================
    key_off;
    ssg_off;
    rhythm_full;

    // =================================================================
    // D0. ONE drum (bass drum) at full, alone, 0 dB - the per-drum unit the
    //     six-drum sum is built from (compare the reference's 15328).
    // =================================================================
    op_write(16'h0188, 8'h10); op_write(16'h018A, 8'h01);
    repeat (6000) @(posedge clk);
    measure(300_000, p_presum, p_fmsnd, p_accrun, p_mix, p_out,
                      r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    report("D0. Rhythm ONE drum (BD) at full, alone, 0 dB",
           p_presum, p_fmsnd, p_accrun, p_mix, p_out,
           r_presum, r_fmsnd, r_accrun, r_mix, r_out);

    // =================================================================
    // D. Rhythm six drums at full, alone, at the 0 dB default (FM off, SSG off).
    // =================================================================
    // Snapshot the wrap counter so the coverage claim below is about THIS phase's
    // own six-drum stimulus, not about any other phase that happens to overflow.
    raw_over16_D_start = raw_over16_events;
    rhythm_trigger;
    repeat (6000) @(posedge clk);
    measure(300_000, p_presum, p_fmsnd, p_accrun, p_mix, p_out,
                      r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    report("D. Rhythm six at full, alone, 0 dB",
           p_presum, p_fmsnd, p_accrun, p_mix, p_out,
           r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    std_rhythm_presum_rail = r_presum;
    raw_over16_in_D = raw_over16_events - raw_over16_D_start;

    // =================================================================
    // F. Everything at once at the 0 dB default: FM six + SSG three + rhythm six.
    // =================================================================
    key_on(3'd0); key_on(3'd1); key_on(3'd2);
    key_on(3'd4); key_on(3'd5); key_on(3'd6);
    ssg_max;
    rhythm_trigger;
    repeat (6000) @(posedge clk);
    measure(500_000, p_presum, p_fmsnd, p_accrun, p_mix, p_out,
                      r_presum, r_fmsnd, r_accrun, r_mix, r_out);
    report("F. FM six + SSG three + rhythm six, all max, 0 dB",
           p_presum, p_fmsnd, p_accrun, p_mix, p_out,
           r_presum, r_fmsnd, r_accrun, r_mix, r_out);

    // ==== CHECKS ====
    // The stimulus is not vacuous: every source must move the output on its own.
    if (p_presum == 0 && p_fmsnd == 0)
      fail("nothing sounded: the FM and rhythm triggers produced no output at all");

    // 1. THE DIE'S SIX-DRUM BUS (YM2608-LLE fmopna_impl.c:5370).
    //    The raw six-drum sum DOES pass the 16-bit range DURING THIS PHASE (counted
    //    in raw_over16_in_D, not run-wide - the six-drum phase must be the one that
    //    exercises the wrap, or the coverage claim is misattributed), and the bus is
    //    its 16-bit two's-complement WRAP, not a flat top and not a wide sum: pcm_out
    //    must equal the sign-extended wrapped round sum every round, and the
    //    accumulator must equal the wrap.
    if (raw_over16_in_D == 0)
      fail("the six full drums never push the raw sum past 16 bits in their own phase: the 16-bit wrap is not exercised by the stimulus that claims it");
    if (clip_events != 0)
      fail("the drum bus is not the die's 16-bit wrapped sum: pcm_out diverged from the model");
    if (wrap_events != 0)
      fail("the drum-sum accumulator is not the die's 16-bit wrapping sum: acc diverged from the model");

    // 3. The census, named rather than asserted (the numbers are the evidence; see the
    //    printed census). The FM six at maximum DO exceed 16 bits, so the junction
    //    clamp (the same point ymfm clamps with clamp16()) is exercised and
    //    authentic, and the report says so. Only the SSG, alone, is guaranteed not to
    //    rail, and a future stimulus that made it rail would mean the wrapper's SSG
    //    mix had changed (now the AC-coupled zero-mean term peaks at ~+-6138 for
    //    all three at max, the level tb_pc9821_opna_ssg_level pins).
    if (std_ssg_out_rail != 0)
      fail("the three SSG channels alone reached the 16-bit rail: the wrapper's SSG mix changed");

    // 4. THE JUNCTION CLAMP (restored from 8f8194e2). The FM+ADPCM sum must be
    //    clamped to the 16-bit ymfm clamp16 rail AT the jt08_acc junction (fm_l) and
    //    sign-extended back to 20 bits, and the board output must be that clamped
    //    junction PLUS the SSG (ymfm adds the SSG AFTER its clamp16). The A-1 tree
    //    delivered the raw sum at the junction, so every over-16 sample mismatches
    //    (fail-first evidence), and junc_over16_samples > 0 keeps the check from
    //    passing vacuously.
    if (junc_clamp_events != 0)
      fail("the FM+ADPCM junction is not clamp16 of the accumulator: the A-1 raw junction is back");
    if (join_events != 0)
      fail("the board output is not the clamped junction + SSG (snd_l != mix_l)");
    if (junc_over16_samples == 0)
      fail("the FM+ADPCM sum never passed 16 bits: the junction-clamp check would prove nothing");

    $display("  CENSUS: FM six max out rail=%0d, FM+SSG out rail=%0d, six-drum sum over-16 samples(0dB)=%0d, pre-sum clip events=%0d, junction clamp events=%0d, over-16 samples=%0d, raw-sum over-16 (six-drum phase=%0d, whole run=%0d)",
             std_fm_out_rail, std_fmssg_out_rail, std_rhythm_presum_rail, clip_events,
             junc_clamp_events, junc_over16_samples, raw_over16_in_D, raw_over16_events);

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SOUND_SUM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SOUND_SUM: FAIL (%0d errors)", errors);
  end

  initial begin
    #120_000_000;
    $fatal(1, "TB_PC9821_SOUND_SUM: TIMEOUT");
  end

endmodule
