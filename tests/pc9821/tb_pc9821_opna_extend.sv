`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 0xA460 bit 0 (extension enable) side effects the references model and the board glue was missing: NP2kai extendchannel() (cbus/board86.c:79-94) reconfigures the FM to THREE channels of MONO when the extension is disabled and keys OFF every rhythm drum by writing rhythm register 0x10 = 0xff, then restores six-channel stereo when enabled. The FM side effect is checked at the accumulator's pan mux (channels 0-2 forced center, 3-5 muted) and the drum side effect through the chip's own rhythm key-on latch, which must end at 0xff after the drop.
//
// The 0xA460 bit 0 (extension enable) SIDE EFFECTS the references model and the
// board glue was missing. NP2kai's extendchannel() (cbus/board86.c:79-94) does two
// things when the extension is disabled: it reconfigures the FM to THREE channels
// of MONO (opngen_setcfg(3, OPN_MONORAL | 0x07)), and it keys OFF every rhythm
// drum by writing rhythm register 0x10 = 0xff (rhythm_setreg). When enabled it
// restores six FM channels in stereo (opngen_setcfg(6, OPN_STEREO | 0x07)).
//
// The FM side effect is checked at the accumulator's pan mux (`rl_3ch`): in
// 3-channel mono mode every FM channel sees center (2'b11) for channels 0-2 and
// mute (2'b00) for channels 3-5, regardless of the channel's own pan register.
// The drum side effect is checked through the chip's own rhythm key-on latch
// (`aon_a`): keying drums on and then dropping the extension must leave the latch
// at 0xff (all six keyed off), exactly the write NP2kai issues.
//
// The expected values come from NP2kai cbus/board86.c:79-94, not from this RTL;
// the internal taps only let the bench observe the chip state that write produces.

module tb_pc9821_opna_extend;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;

  reg        reset = 1;
  reg        extend = 0;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait, io_wr_wait, irq;
  // WIDE since A-1: pc9821_opna's stereo sum is the raw FM+ADPCM+SSG 20-bit value with the
  // single clamp at the final DAC (pc9821_audio_mix's mix_dry), not a 17-bit clamped one. This
  // bench never reads these, but a 17-bit declaration would silently set the top three bits
  // of any sample that reached a check here.
  wire signed [19:0] snd_l, snd_r;
  reg  [5:0] joystick = 6'b111111;

  // ==== DUT ====
  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout),
    .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
    .extend(extend),
    .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  // The reference-mandated side effects, observed where the RTL implements them.
  wire        ch3_mono  = dut.ch3_mono;
  wire [7:0]  aon_a     = dut.u_opna.u_jt08.u_jt12.aon_a;
  wire [1:0]  rl        = dut.u_opna.u_jt08.u_jt12.rl;
  wire [1:0]  rl_3ch    = dut.u_opna.u_jt08.u_jt12.gen_adpcm.rl_3ch;
  wire [2:0]  cur_ch    = dut.u_opna.u_jt08.u_jt12.cur_ch;
  wire        ext_inj_busy = dut.ext_inj_busy;
  wire [6:0]  wrq_cnt    = dut.wrq_cnt;

  integer errors = 0;
  integer n, k;

  // ==== CHECKS ====
  task automatic fail(input [8*100-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
      @(negedge clk);
    end
  endtask

  // The games' own register write: index to 0x188, data to 0x18A.
  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      write_port(16'h0188, reg_index);
      write_port(16'h018A, data);
    end
  endtask

  // Wait until the board's write queue is empty (every queued/injected chip write
  // has been presented), then give the chip one extra cycle to latch it.
  task automatic wait_drain;
    begin
      n = 0;
      while ((wrq_cnt != 7'd0 || ext_inj_busy) && n < 20000) begin
        @(posedge clk); n = n + 1;
      end
      if (n >= 20000) fail("the OPNA write queue never drained");
      repeat (4) @(posedge clk);
    end
  endtask

  initial begin
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    // The glue stretches the chip reset over 16 clk&cen cycles; let it finish.
    repeat (2000) @(posedge clk);

    // ---- 1. extension disabled is 3-channel mono -------------------------
    // NP2kai board86_reset leaves `extend` clear and the FM in the 3-channel
    // configuration; the ITF enables the extension later.
    if (ch3_mono !== 1'b1)
      fail("ch3_mono is not asserted with the extension disabled");
    if (dut.u_opna.u_jt08.u_jt12.ch3_mono !== 1'b1)
      fail("ch3_mono did not reach jt12_top with the extension disabled");

    // ---- 2. enabling the extension restores six-channel stereo -----------
    extend = 1'b1;
    repeat (20) @(posedge clk);
    if (ch3_mono !== 1'b0)
      fail("ch3_mono is still asserted with the extension enabled");

    // ---- 3. the 3-channel mono pan mux -----------------------------------
    // With ch3_mono clear the mux passes the channel pan through unchanged;
    // with it set, channels 0-2 are forced center and 3-5 muted. Sample the
    // mux relation over a scan wrap so the check does not depend on one slot.
    extend = 1'b0;
    repeat (20) @(posedge clk);
    for (k = 0; k < 32; k = k + 1) begin
      @(posedge clk);
      if (rl_3ch !== ((ch3_mono ? ((cur_ch < 3'd3) ? 2'b11 : 2'b00) : rl)))
        fail("rl_3ch does not implement the 3-channel mono pan mapping");
    end

    // ---- 4. dropping the extension keys off every drum -------------------
    // Key drums on through the ordinary rhythm register, with the extension
    // enabled, then drop it. NP2kai extendchannel(0) writes 0x10 = 0xff, so the
    // chip's key-on latch must end at 0xff (all six keyed off).
    extend = 1'b1;
    repeat (20) @(posedge clk);
    sound_o(8'h10, 8'h3F);          // key on all six drums (bit 7 clear)
    wait_drain;
    if (aon_a !== 8'h3F) begin
      $display("FAIL: the rhythm key-on latch is %02x after keying drums on, expected 3f @ %0t", aon_a, $time);
      errors = errors + 1;
    end
    extend = 1'b0;                  // the drop the references key off on
    repeat (2) @(posedge clk);       // let the DUT register the edge and arm the injection
    wait_drain;
    if (aon_a !== 8'hFF) begin
      $display("FAIL: the rhythm key-on latch is %02x after the extension drop, expected ff @ %0t", aon_a, $time);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_EXTEND: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_EXTEND: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_OPNA_EXTEND: TIMEOUT");
  end
endmodule
