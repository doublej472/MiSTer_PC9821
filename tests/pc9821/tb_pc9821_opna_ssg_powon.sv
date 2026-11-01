// tb_pc9821_opna_ssg_powon - the SSG register file's POWER-ON mixer state.
//
// ==== WHAT THIS PROVES ====
// The jt49 SSG register file powers up at NP2kai's opna_reset state (sound/opna.c:137-139: reg7 = 0xBF, reg15 = 0xFF, the rest 0). This is the CHIP-SIDE seed alone: the board read shadow follows the machine's 0x00 (probes/OPNA.TXT CHIPID), so the two no longer agree and the guest-visible read is the shadow's - what this bench pins is the never-written power-on mixer, silent where the reference is silent: register 7 reads back 0xBF before any write and the never-written power-on mixer produces the exact same output stream as a twin chip explicitly programmed 0xBF at the fastest tone period and maximum amplitude (NP2kai psggeng.c:25 early-outs to exactly 0 at that mixer state, and a 0x00 power-on routes ALL tone and noise sources in).
//
// The vendored jt49 SSG powers up with the register state NP2kai's opna_reset
// gives the chip (sound/opna.c:137-139: s.reg[0x07] = 0xbf, s.reg[0x0f] = 0xff,
// all other SSG registers 0), so the first SSG use that never writes register 7
// behaves exactly like a chip the guest had set to the reference's power-on
// mixer: register 7 reads back 0xBF and the output stream is bit-identical to a
// twin chip the guest explicitly programmed with 0xBF. Register 7 is the
// active-low tone/noise enable mixer; a power-on 0x00 routes ALL tone and noise
// sources into all three channels, which is the one state the reference is
// specifically NOT in (NP2kai's psggen_getpcm early-outs to exactly 0 when
// ~reg7 & 0x3f == 0, i.e. when reg7 is 0xBF and nothing is routed).
//
// ---- the bench's own account of where this expectation comes from ----
// [source 1: NP2kai sound/opna.c opna_reset - the PRIMARY reference]
//     memset(&opna->s, 0, sizeof(opna->s));
//     ...
//     opna->s.reg[0x07] = 0xbf;
//     opna->s.reg[0x0e] = 0xff;
//     opna->s.reg[0x0f] = 0xff;
// and the read model this core ships (pc9821_opna.sv's ssg_reg shadow) seeded
// 7 = 0xBF / 15 = 0xFF for exactly this reason until the read-back fix moved
// the SHADOW's register-7 seed to the MACHINE's 0x00 (docs/probes/OPNA.TXT
// CHIPID: `0x18A with 0x188=07 ... : 00`). So the board shadow and this chip
// seed NO LONGER agree, and that is deliberate and named: this bench pins the
// CHIP's power-on register (the vendored jt49 regarray[7]) against NP2kai,
// where the capture proves only the READ. Before the earlier fix the CHIP reset
// all 16 registers to 0 while the SHADOW claimed 0xBF: the first
// read/modify/write of register 7 (master.lib's js_start does read/and 3Fh/
// or 80h/write-back) read the shadow and wrote 0x80, and a guest that trusted
// power-on silence got tone+noise from a core whose reference is silent. With
// the shadow at the machine's 0x00 that RMW now writes 0x80, exactly as the
// machine does (tb_pc9821_opna_regs section 2 asserts it) - so a guest that
// drives reg 7 through js_start hears what hardware routes; the CHIP's own
// un-written register is what this bench still pins.
// [source 2: NP2kai sound/psggeng.c:25 - why 0xBF is SILENCE]
//     if ((psg->mixer & 0x3f) == 0) { count = MIN(count, psg->puchicount); ... }
// psg->mixer is stored ~reg7 (psggenc.c:125), so reg7 = 0xBF makes the
// generator emit exactly 0 no matter what the periods and amplitudes say.
//
// ---- why this is a differential test and not an "average 0" test ----
// jt49 models the chip's UNCOUPLED DAC: with every source disconnected the
// channel holds its volume as a constant level (the real AY's DC output, which
// the board's output capacitor removes), where NP2kai's centred model emits
// exactly 0. Both are the same SILENCE - neither oscillates - so what "the
// power-on mixer is the reference's mixer" means here is exact stream equality
// against a twin that was explicitly programmed 0xBF, plus the 0xBF read-back.
// The gate is exercised at the tone's FASTEST period and MAX amplitude, which is
// the loudest a never-writing guest can be.

`timescale 1ns / 1ps

module tb_pc9821_opna_ssg_powon;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // Two identical chips: A is NEVER written at register 7 (it must power up at
  // the reference's mixer), B is explicitly programmed 0xBF (the reference).
  reg  [3:0] addr = 4'd0;
  reg        cs_a = 1'b1, cs_b = 1'b1, wr_n = 1'b1;
  reg  [7:0] din = 8'd0;
  wire [7:0] dout_a, dout_b;
  wire [11:0] snd_a, snd_b;

  // ==== DUT ====
  jt49 dut_a (
      .rst_n(rst_n), .clk(clk), .clk_en(1'b1), .addr(addr),
      .cs_n(cs_a), .wr_n(wr_n), .din(din), .sel(1'b1),
      .dout(dout_a), .sound(snd_a), .A(), .B(), .C(), .sample(),
      .IOA_in(8'hFF), .IOA_out(), .IOA_oe(),
      .IOB_in(8'hFF), .IOB_out(), .IOB_oe()
  );
  jt49 dut_b (
      .rst_n(rst_n), .clk(clk), .clk_en(1'b1), .addr(addr),
      .cs_n(cs_b), .wr_n(wr_n), .din(din), .sel(1'b1),
      .dout(dout_b), .sound(snd_b), .A(), .B(), .C(), .sample(),
      .IOA_in(8'hFF), .IOA_out(), .IOA_oe(),
      .IOB_in(8'hFF), .IOB_out(), .IOB_oe()
  );

  integer errors = 0;

  // ==== CHECKS ====
  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // One write; `both` selects which chip's chip-select is low (the reference-
  // state write 0xBF must reach chip B only - chip A is the never-written one).
  task wr(input [3:0] a, input [7:0] d, input both);
    begin
      @(negedge clk);
      addr = a; din = d; wr_n = 1'b0;
      cs_a = both ? 1'b0 : 1'b1;
      cs_b = 1'b0;
      @(negedge clk);
      cs_a = 1'b1; cs_b = 1'b1; wr_n = 1'b1;
    end
  endtask

  // Register read-back: jt49's dout presents regarray[addr] & the read mask
  // every clk (the vendored core registers the read unconditionally).
  task check_reg(input [3:0] a, input [7:0] want, input [8*110-1:0] what);
    begin
      addr = a;
      @(posedge clk);
      @(negedge clk);
      if (dout_a !== want) begin
        $display("FAIL: %0s: chip reg %0d reads %02x want %02x", what, a, dout_a, want);
        errors = errors + 1;
      end
    end
  endtask

  integer i;
  integer mismatches;

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    // (1) The chip's register 7 reads the reference's power-on value BEFORE any
    // write. The board shadow (pc9821_opna ssg_reg) does NOT agree any more: the
    // machine reads it as 0x00 (probes/OPNA.TXT CHIPID), so the shadow follows
    // the capture and this chip-side seed stays NP2kai's 0xBF (see the header).
    check_reg(4'h7, 8'hBF, "SSG reg 7 power-on read-back");

    // (2) The first SSG use without a reg-7 write: fastest tone A, amplitude A
    // maximum - and NEVER register 7 on either chip except B's one explicit
    // power-on-equivalent write.
    wr(4'h7, 8'hBF, 1'b0);    // chip B's reference state ONLY (A keeps its power-on)
    wr(4'h0, 8'h01, 1'b1);    // tone A period low = fastest
    wr(4'h1, 8'h00, 1'b1);    // tone A period high
    wr(4'h8, 8'h0F, 1'b1);    // amplitude A = maximum, fixed level (no envelope)

    // Let the tone/noise/divider pipelines settle, then compare the streams.
    repeat (200) @(negedge clk);
    mismatches = 0;
    for (i = 0; i < 2000; i = i + 1) begin
      @(negedge clk);
      if (snd_a !== snd_b) mismatches = mismatches + 1;
    end
    if (mismatches != 0) begin
      $display("FAIL: the never-written power-on mixer is NOT the reference's 0xBF mixer: %0d/2000 samples differ (tone A sounds where NP2kai is silent)", mismatches);
      errors = errors + 1;
    end

    // (3) And the state is still the reference's after the run.
    check_reg(4'h7, 8'hBF, "SSG reg 7 after the run");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_SSG_POWON: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_OPNA_SSG_POWON: FAIL (%0d errors)", errors);
  end

  initial begin
    #10_000_000;
    $fatal(1, "TB_PC9821_OPNA_SSG_POWON: TIMEOUT");
  end

endmodule
