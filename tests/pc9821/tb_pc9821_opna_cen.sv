`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_CEN:
// The YM2608's 7.9872 MHz clock enable in the PC-9801-86 glue is the exact phase-accumulator pulse train its definition gives, cycle for cycle from every reset release: at the core's 90 MHz clk the enable is high on cycle t after reset exactly when (t * CEN_STEP mod 2^32) + CEN_STEP carries out of 32 bits, with CEN_STEP = floor(2^32 * 7987200 / 90000000), never two cycles in a row, and 7987200 / 90000000 of the cycles over a long run; a reset at any phase restarts the train from t = 0. The enable is a register (one step ahead) instead of the adder's combinational carry, a timing-only change, and this is its equivalence check. jt12_div's six clock enables (clk_en, clk_en_2, clk_en_ssg, clk_en_666, clk_en_111, clk_en_55), which its LOCAL PATCH registers on the rising edge from the next cycle's cen (cen_nx) instead of on the falling edge from cen, equal upstream's falling-edge form (a verbatim copy of the pinned upstream jt12_div, driven by the same cen and prescaler setting) at every rising edge of the same runs. jt12_rst's ADPCM reset (rst_n), which its LOCAL PATCH registers on the rising edge from the next cycle's rst (rst_nx) instead of on the falling edge from rst, equals upstream's falling-edge form (a verbatim copy of the pinned upstream jt12_rst, driven by the same rst) at every rising edge of the same runs, through the first reset's release and six assert/release pairs.
//
// ==== DUT ====
// pc9821_opna at SYS_CLOCK_HZ = 90_000_000 (the base build's clk_sys), host port idle. The bench
// reads the glue's internal `cen` (sound.cen in pc9821_system) hierarchically.
//
// ==== CHECKS ====
// Every cycle of a 9e6-cycle run and of six runs after resets of assorted lengths: the enable
// equals the model's; it never stays high two cycles; it is low through reset; the long run
// holds floor(9e6 * STEP / 2^32) enables. The pre-change combinational-carry form passes the
// same bench (the change is value-identical); the mutations make it fail. At every rising edge
// of the same runs, jt12_div's six enables equal those of tb_ref_jt12_div_upstream (below: the
// pinned upstream module verbatim, renamed), which runs on the DUT's own cen and div_setting.
// jt12_rst's rst_n equals that of tb_ref_jt12_rst_upstream (the pinned upstream module
// verbatim, renamed) on the DUT's own rst at every rising edge, both edges of it counted.
//
// ==== WHERE THE EXPECTATIONS COME FROM ====
// The master clock is 7.9872 MHz: NP2kai sound/opngen.h:13 `#define OPNA_CLOCK (3993600 * 1)`,
// doubled for the FM engine by sound/opna.c:123 (the glue's clock-enable comment cites the
// same). The enable is a fractional divider of clk by 7987200 / 90000000; the expected train is
// computed here from that ratio's 32-bit phase accumulator definition (an independent model in
// 64-bit arithmetic: the carry of t*STEP + STEP over 2^32), not from the glue's RTL text.
//
// ==== VERDICT ====
// PASS when every cycle matches and the long-run count is exact; $fatal on the first mismatch.

module tb_pc9821_opna_cen;
  localparam integer SYS_CLOCK_HZ = 90_000_000;
  localparam longint STEP = (64'd4_294_967_296 * 64'd7_987_200) / SYS_CLOCK_HZ;

  reg clk = 1'b0;
  always #5.555 clk = ~clk;
  reg reset = 1'b1;

  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(16'h0000), .io_wr(1'b0), .io_rd(1'b0), .io_din(8'h00),
    .io_dout(), .io_rd_wait(), .io_rd_hold(), .io_wr_wait(),
    .extend(1'b1), .joystick(6'h3F),
    .snd_l(), .snd_r(), .irq(),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // jt12_div's enables against upstream's falling-edge form, at every rising edge (a posedge
  // reader sees the values both hold just before the edge).
  wire ref_en, ref_en2, ref_ssg, ref_666, ref_111, ref_55;
  tb_ref_jt12_div_upstream #(.use_ssg(1)) ref_div (
    .rst(dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.rst), .clk(clk),
    .cen(dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.cen),
    .div_setting(dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.div_setting),
    .clk_en(ref_en), .clk_en_2(ref_en2), .clk_en_ssg(ref_ssg),
    .clk_en_666(ref_666), .clk_en_111(ref_111), .clk_en_55(ref_55)
  );
  wire [5:0] div_dut = {dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.clk_en,
                        dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.clk_en_2,
                        dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.clk_en_ssg,
                        dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.clk_en_666,
                        dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.clk_en_111,
                        dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.clk_en_55};
  wire [5:0] div_ref = {ref_en, ref_en2, ref_ssg, ref_666, ref_111, ref_55};
  longint edges = 0, en_seen = 0;
  bit     div_check = 1'b0;    // from the first edge after the first reset (both power up apart)
  always @(posedge clk) begin
    if (div_check) begin
      if (div_dut !== div_ref)
        $fatal(1, "TB_PC9821_OPNA_CEN: FAIL jt12_div enables %06b, upstream's falling-edge form %06b (edge %0d)",
               div_dut, div_ref, edges);
      edges++;
      if (div_dut[5]) en_seen++;
    end
  end

  // jt12_rst's ADPCM reset (its LOCAL PATCH: both stages on the rising edge from rst_nx) against
  // upstream's falling-edge form driven by the same rst, at every rising edge; the releases and
  // assertions are counted so the comparison is known to have seen both edges.
  wire ref_rst_n;
  tb_ref_jt12_rst_upstream ref_rst (
    .rst(dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_rst.rst), .clk(clk), .rst_n(ref_rst_n)
  );
  wire    rst_n_dut = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_rst.rst_n;
  longint rst_rises = 0, rst_falls = 0;
  bit     rst_n_prev = 1'b0;
  always @(posedge clk) begin
    if (div_check) begin
      if (rst_n_dut !== ref_rst_n)
        $fatal(1, "TB_PC9821_OPNA_CEN: FAIL jt12_rst rst_n %0b, upstream's falling-edge form %0b (edge %0d)",
               rst_n_dut, ref_rst_n, edges);
      if (rst_n_dut && !rst_n_prev) rst_rises++;
      if (!rst_n_dut && rst_n_prev) rst_falls++;
    end
    rst_n_prev = rst_n_dut;
  end

  // The model: phase after t post-reset cycles, and the enable it gives on cycle t.
  longint t = 0;
  longint pulses = 0;
  longint run = 0;
  integer errors = 0;
  bit     prev_cen = 1'b0;
  function automatic bit model_cen(input longint tt);
    longint ph;
    ph = (tt * STEP) % 64'd4_294_967_296;
    return (ph + STEP) >= 64'd4_294_967_296;
  endfunction

  task automatic check_cycles(input longint n, input bit count_run);
    for (longint i = 0; i < n; i++) begin
      @(negedge clk);
      if (dut.cen !== model_cen(t)) begin
        $fatal(1, "TB_PC9821_OPNA_CEN: FAIL cen=%0b at t=%0d after reset, model %0b",
               dut.cen, t, model_cen(t));
      end
      if (dut.cen && prev_cen)
        $fatal(1, "TB_PC9821_OPNA_CEN: FAIL two enables in a row at t=%0d", t);
      prev_cen = dut.cen;
      if (count_run && dut.cen) pulses++;
      t++;
    end
  endtask

  task automatic do_reset(input integer len);
    @(posedge clk); reset <= 1'b1;
    @(posedge clk);   // the first edge that samples reset high
    repeat (len) begin
      @(negedge clk);
      if (dut.cen !== 1'b0) $fatal(1, "TB_PC9821_OPNA_CEN: FAIL cen high during reset");
    end
    @(posedge clk); reset <= 1'b0;
    t = 0; prev_cen = 1'b0;
  endtask

  initial begin
    do_reset(4);
    div_check = 1'b1;
    // A long run: 9,000,000 cycles = 0.1 s at 90 MHz is 798,720 master clocks
    // (9e6 * 7987200 / 9e7); the accumulator starting at 0 gives floor(9e6 * STEP / 2^32).
    check_cycles(64'd9_000_000, 1'b1);
    // The truncated STEP may drop the last one: floor(9e6 * STEP / 2^32) = 798719.
    if (pulses != ((64'd9_000_000 * STEP) >> 32) || (pulses != 64'd798_720 && pulses != 64'd798_719))
      $fatal(1, "TB_PC9821_OPNA_CEN: FAIL %0d enables in 9e6 cycles, expected 798720 (-1)", pulses);
    // Resets at assorted phases, each followed by a stretch long enough to wrap the accumulator.
    for (integer k = 0; k < 6; k++) begin
      do_reset(1 + k * 3);
      check_cycles(64'd1000 + k * 997, 1'b0);
    end
    if (en_seen == 0) $fatal(1, "TB_PC9821_OPNA_CEN: FAIL jt12_div's clk_en never fired");
    // the first reset's release, then six assert/release pairs
    if (rst_rises != 7 || rst_falls != 6)
      $fatal(1, "TB_PC9821_OPNA_CEN: FAIL jt12_rst rst_n rose %0d / fell %0d times, expected 7 / 6",
             rst_rises, rst_falls);
    $display("  jt12_rst rst_n equals upstream's falling-edge form at every edge (%0d releases, %0d assertions)",
             rst_rises, rst_falls);
    $display("  jt12_div enables equal upstream's falling-edge form at %0d edges (%0d clk_en)", edges, en_seen);
    $display("TB_PC9821_OPNA_CEN: PASS");
    $finish;
  end

  initial begin
    #300_000_000;
    $fatal(1, "TB_PC9821_OPNA_CEN: TIMEOUT");
  end
endmodule

// The pinned upstream jt12_div (PC88_MiSTer rtl/sound, src/opna/LICENSE-SCOPE.md), verbatim but
// for the module name: the reference for jt12_div's LOCAL PATCH.
module tb_ref_jt12_div_upstream(
    input           rst,
    input           clk,
    input           cen /* synthesis direct_enable */,
    input     [1:0] div_setting,
    output reg      clk_en,      // after prescaler
    output reg      clk_en_2,    // cen divided by 2
    output reg      clk_en_ssg,
    output reg      clk_en_666,  // 666 kHz
    output reg      clk_en_111,  // 111 kHz
    output reg      clk_en_55    //  55 kHz
);

parameter use_ssg=0;

reg [3:0] opn_pres, opn_cnt=4'd0;
reg [2:0] ssg_pres, ssg_cnt=3'd0;
reg [4:0] adpcm_cnt666  = 5'd0;
reg [2:0] adpcm_cnt111 = 3'd0, adpcm_cnt55=3'd0;
reg cen_int, cen_ssg_int, cen_adpcm_int, cen_adpcm3_int;

// prescaler values for FM
// reset: 1/3
// sel1/sel2
//    0 0    1/3
//    0 1    1/2
//    1 0    1/6  
//    1 1    1/2
//
// According to YM2608 document
//                  FM      SSG   div[1:0]
// reset value     1/6      1/4    10
// 2D              1/6      1/4    10   | 10
// 2D,2E           1/3      1/2    11   | 01
// 2F              1/2      1/1    00   & 00
//  

always @(*) begin
    casez( div_setting )
        2'b0?: begin // FM 1/2 - SSG 1/1
            opn_pres = 4'd2-4'd1;
            ssg_pres = 3'd0;
        end
        2'b10: begin // FM 1/6 - SSG 1/4 (reset value. Fixed for YM2610)
            opn_pres = 4'd6-4'd1;
            ssg_pres = 3'd3;
        end
        2'b11: begin // FM 1/3 - SSG 1/2
            opn_pres = 4'd3-4'd1;
            ssg_pres = 3'd1;
        end
    endcase // div_setting
end

`ifdef SIMULATION
initial clk_en_666 = 1'b0;
`endif

reg cen_55_int;
reg [1:0] div2=2'b0;

always @(negedge clk) begin
    cen_int        <= opn_cnt      == 4'd0;
    cen_ssg_int    <= ssg_cnt      == 3'd0;
    cen_adpcm_int  <= adpcm_cnt666 == 5'd0;
    cen_adpcm3_int <= adpcm_cnt111 == 3'd0;
    cen_55_int     <= adpcm_cnt55  == 3'd0;
    `ifdef FASTDIV
    // always enabled for fast sims (use with GYM output, the timers will not work well)
    clk_en     <= 1'b1;
    clk_en_2   <= 1'b1;
    clk_en_ssg <= 1'b1;
    clk_en_666 <= 1'b1;
    clk_en_55  <= 1'b1;
    `else
    clk_en     <= cen & cen_int;
    clk_en_2   <= cen && (div2==2'b00);
    clk_en_ssg <= use_ssg ? (cen & cen_ssg_int) : 1'b0;
    clk_en_666 <= cen & cen_adpcm_int;
    clk_en_111 <= cen & cen_adpcm_int & cen_adpcm3_int;
    clk_en_55  <= cen & cen_adpcm_int & cen_adpcm3_int & cen_55_int;
    `endif
end

// Div/2
always @(posedge clk)
    if( cen ) begin
        div2 <= div2==2'b10 ? 2'b00 : (div2+2'b01);
    end

// OPN
always @(posedge clk)
    if( cen ) begin
        if( opn_cnt == opn_pres ) begin
            opn_cnt <= 4'd0;  
        end
        else opn_cnt <= opn_cnt + 4'd1;
    end

// SSG
always @(posedge clk)
    if( cen ) begin
        if( ssg_cnt == ssg_pres ) begin
            ssg_cnt <= 3'd0;            
        end
        else ssg_cnt <= ssg_cnt + 3'd1;
    end

// ADPCM-A
always @(posedge clk)
    if( cen ) begin
        adpcm_cnt666 <= adpcm_cnt666==5'd11 ? 5'd0 : adpcm_cnt666 + 5'd1;
        if( adpcm_cnt666==5'd0 ) begin
            adpcm_cnt111 <= adpcm_cnt111==3'd5 ? 3'd0 : adpcm_cnt111+3'd1;
            if( adpcm_cnt111==3'd0)
                adpcm_cnt55 <= adpcm_cnt55==3'd1 ? 3'd0: adpcm_cnt55+3'd1;
        end
    end

endmodule // jt12_div

// The pinned upstream jt12_rst (PC88_MiSTer rtl/sound, src/opna/LICENSE-SCOPE.md), verbatim but
// for the module name: the reference for jt12_rst's LOCAL PATCH.
module tb_ref_jt12_rst_upstream(
    input   rst,
    input   clk,
    output  reg rst_n
);

reg r;

always @(negedge clk)
    if( rst ) begin
        r     <= 1'b0;
        rst_n <= 1'b0;
    end else begin
        { rst_n, r } <= { r, 1'b1 };
    end

endmodule // jt12_rst
