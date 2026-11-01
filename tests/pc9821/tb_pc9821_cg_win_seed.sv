// tb_pc9821_cg_win_seed - the CG window read path's one-cycle mux/seed flops.
//
// ==== WHAT THIS PROVES ====
// The CG window read path's one-cycle mux/seed flops come up at 0: win_rd_d, cfg_seed_hit_q and cfg_seed_read_q are seeded, so cg_rd_win and the shared cg_ram/ANK port-A address are real addresses from the first cycle and a window read issued as the very first transaction after reset answers the same byte as the settled path instead of X (run under iverilog for the fail-first X-lock).
//
// The CG window's read mux register `win_rd_d` and the configuration-seed
// compare registers `cfg_seed_hit_q` / `cfg_seed_read_q` come up at 0, so:
//   - `cg_rd_win = cg_win_rd | win_rd_d` is NEVER X, so the shared cg_ram/ANK
//     port-A address `cg_rd_addr` is a real address from the first cycle - with
//     win_rd_d unseeded the OR is X before the first window access and the
//     ADDRESS mux is X, poisoning the registered read for that cycle;
//   - a configuration-seed window read (the ITF's 0xA400-window reads of
//     0x0497 / 0x1CA7 / 0x1C6x) that lands in the first cycle returns the
//     SEEDED byte and not X.
// The bench asserts the X-freedom of the whole first-transaction chain and that
// a window read issued as the very first transaction after reset returns the
// SAME byte as an identical settled read.
//
// ==== THE 4-STATE RUN ====
// tools/bench.py --all runs Verilator, which is 2-STATE and zero-initialised, so no seed's
// X-freedom is part of what the gate proves. The backing run is
// `python3 tools/check_4state_xlock.py cg_win_seed` (iverilog, 4-state, by hand, outside
// the build path). Its `--selftest` ablates each seed and REQUIRES the run to FAIL
// (win_rd_d, and cfg_seed_hit_q/cfg_seed_read_q: both are caught).
// THE X CHECK IS ONLY LIVE BEFORE THE FIRST CLK EDGE. Sampled at the first negedge - where
// it used to be - an unseeded build PASSES: win_rd_d has by then been loaded from
// cg_win_rd = 0 and the compare from a real address. It now runs at #1 with no clock yet,
// where those three flops are the one piece of state a seeded build defines.

`timescale 1ns / 1ps

module tb_pc9821_cg_win_seed;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg rst_n_sys = 0;

  reg  [4:0] cg_win_byte_sel = 5'd0;
  reg        cg_win_rd = 0;
  wire [7:0] cg_win_dout;

  // ==== DUT ====
  // The scanout and font-loader sides are idle; only the CPU-side views move.
  pc9821_cg dut (
      .clk_sys(clk_sys),
      .rst_n_sys(rst_n_sys),
      .pixel_ce(1'b0),
      .io_wr(1'b0),
      .io_rd(1'b0),
      .io_addr(8'hA1),
      .io_din(8'h00),
      .io_dout(),
      .cg_win_byte_sel(cg_win_byte_sel),
      .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout),
      .cg_win_din(8'h00),
      .cg_win_we(1'b0),
      .font_word_valid(1'b0),
      .font_word_data(32'd0),
      .font_ld_addr(18'd0),
      .font_ld_data(16'd0),
      .font_ld_we(1'b0),
      .cg_record_restore(1'b0),
      .cfg_ram_mib(7'd5),
      .cfg_seed_en(1'b1),
      .cfg_seed_reload(1'b0),
      .ank_rd_addr(11'd0),
      .jc_rd_bank(2'd0),
      .jc_rd_cell(7'd0),
      .jc_rd_word(2'd0),
      .cg_ram_vid_addr(13'd0),
      .tram_vid_q(8'h20),
      .v_pitch(8'd40),
      .v_col40(1'b0),
      .v_sad(16'd0),
      .wk_go(1'b0), .wk_k(10'd0), .wk_bank_in(2'd0),
      .hdot(10'd0)
  );

  integer errors = 0;
  reg [7:0] first_byte, settled_byte;

  // ==== CHECKS ====
  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // One window read: presented for 2 clks (the window holds its byte select for
  // the whole access), the response sampled on the second.
  task window_read(input [4:0] byte_sel, output [7:0] data);
    begin
      @(negedge clk_sys);
      cg_win_byte_sel = byte_sel;
      cg_win_rd = 1'b1;
      @(negedge clk_sys);
      #1 data = cg_win_dout;
      @(negedge clk_sys);
      cg_win_rd = 1'b0;
    end
  endtask

  integer i;

  initial begin
    // ==== THE SEED REGISTERS' OWN WINDOW ====
    // The three seeded flops have no reset: their declaration initialisers ARE
    // their power-up values. Everything else in the module is reset only by the
    // FIRST clk_sys posedge (t = 10), so before that edge the seeds are the one
    // piece of state that is defined in a seeded build and X in an unseeded one.
    // Sampled with NO clock yet: the seeded build reads 00/0, the unseeded X.
    // This is the whole window in which the claim below is falsifiable - after
    // the first edge the input register has been loaded from cg_win_rd = 0 and
    // the compare from a real address, so an unseeded build passes every later
    // check in this file. Verilator (2-state) cannot fail any of it; the
    // 4-state companion run is tools/check_4state_xlock.py.
    #1;
    if ($isunknown(dut.win_rd_d) || $isunknown(dut.cfg_seed_hit_q) ||
        $isunknown(dut.cfg_seed_read_q)) begin
      fail("X in the seeded CG window-read flops at power-up (their initialisers are their power-up value)");
    end

    @(negedge clk_sys);
    #1;
    if ($isunknown(dut.win_rd_d) || $isunknown(dut.cg_rd_win) || $isunknown(dut.cg_rd_addr) ||
        $isunknown(dut.cfg_seed_hit_q) || $isunknown(dut.cfg_seed_read_q) || $isunknown(cg_win_dout)) begin
      fail("X in the CG window read mux / seed flops at the first negedge");
    end

    repeat (3) @(negedge clk_sys);

    // ==== THE FIRST TRANSACTION AFTER RESET is a window read ====
    rst_n_sys = 1'b1;
    #1;
    // Sample the chain while the very first read is in flight.
    cg_win_byte_sel = 5'd03;
    cg_win_rd = 1'b1;
    for (i = 0; i < 2; i = i + 1) begin
      @(negedge clk_sys);
      #1;
      if ($isunknown(dut.win_rd_d) || $isunknown(dut.cg_rd_win) || $isunknown(dut.cg_rd_addr) ||
          $isunknown(dut.cfg_seed_hit_q) || $isunknown(dut.cfg_seed_read_q) || $isunknown(cg_win_dout)) begin
        fail("X in the CG window read path during the first transaction after reset");
        i = 2;
      end
    end
    first_byte = cg_win_dout;
    @(negedge clk_sys);
    cg_win_rd = 1'b0;

    // ==== the first read answers what the settled path answers ====
    repeat (4) @(negedge clk_sys);
    window_read(5'd03, settled_byte);
    if (first_byte !== settled_byte) begin
      $display("FAIL: the first window read answered %02x, the settled one %02x", first_byte, settled_byte);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CG_WIN_SEED: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_CG_WIN_SEED: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_CG_WIN_SEED: TIMEOUT");
  end

endmodule
