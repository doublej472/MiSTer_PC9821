`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The three gamma-correction curves are one 256x8 M10K per channel behind the MiSTer gamma_bus: a write to lane R, G or B at an address lands in that channel's table, and a pixel presented on RGB_in comes out of RGB_out through that table (or straight through when gamma_en is low) exactly two ce_pix edges later, value- and cycle-identical to the register-array module it replaced across a fully seeded table, every one of the 256 indices on all three channels, and ce_pix gaps.
//
// ---- the oracle is the OLD module, written out again ----
// A rewrite replaced gamma_fast's three curves with one simple-dual-port RAM per channel:
// a write-only port on clk_sys and a separately-registered read port on clk_vid, whose
// registered output plays the part the old registered look-up did (an earlier true dual
// port inferred only one of the three, because a dual-clock block RAM cannot carry the
// read on both of pc9821_dpram's ports). That is a pipeline-latency change unless it is
// done exactly right, so this bench runs the OLD module's structure as a second
// reference model on the SAME stimulus -- the same write port, the same read port, the
// same ce_pix gate -- and requires every output (RGB_out, HSync_out, VSync_out, DE_out)
// to match the DUT on every clock edge. A one-cycle latency slip, a swapped lane, a lost
// address bit or an ungated (free-running) read fails here and every single-cycle
// readback test passes.
//
// There is ONE clock. gamma_fast takes its write clock from gamma_bus[20], and
// z486_mister.sv drives that bit from the same clk_sys it wires to clk_vid (the SDC
// declares a single clock domain), so the bench drives gamma_bus[20] from clk_vid:
// the write side and the read side are the same clock, as on the card. The RTL's two
// port clocks are separate expressions, so this single-clock case is the special case
// of the dual-clock structure rather than a different design.
//
// The stimulus covers: a full seed of all three 256-entry tables with three distinct
// injective patterns (so a lane or address permutation cannot pass), a read-back of
// every one of the 256 indices on all three channels at once, and a ce_pix that drops
// low for one edge in seven so the enable hold is exercised.

module tb_pc9821_gamma;

  // The one clock. gamma_bus[20] carries it (see the banner).
  reg clk_vid = 0;
  always #5 clk_vid = ~clk_vid;   // 10 ns

  // ==== DUT ====
  // gamma_bus: hps_io drives bits [20:0]; gamma_fast drives bit 21 back. The TB
  // drives [19:0] (control/address/value) and bit 20 (the clock) and leaves bit 21
  // to the DUT.
  reg  [19:0] ctrl = 20'h0;       // [19]=gamma_en [18]=gamma_wr [17:16]=lane [15:8]=addr [7:0]=value
  wire [21:0] gamma_bus;
  assign gamma_bus[20]   = clk_vid;
  assign gamma_bus[19:0] = ctrl;

  reg  [23:0] rgb_in = 24'h0;
  reg         ce_pix = 0;
  reg         hs_i = 0, vs_i = 0, de_i = 0;

  wire [23:0] rgb_out;
  wire        hs_out, vs_out, hb_out, vb_out, de_out;

  gamma_fast dut (
      .clk_vid   (clk_vid),
      .ce_pix    (ce_pix),
      .gamma_bus (gamma_bus),
      // HBlank/VBlank are tied low, exactly as z486_mister.sv ties them: the
      // outputs are the only consumers and the reference model ignores them.
      .HSync     (hs_i), .VSync (vs_i), .HBlank (1'b0), .VBlank (1'b0), .DE (de_i),
      .RGB_in    (rgb_in),
      .HSync_out (hs_out), .VSync_out (vs_out), .HBlank_out (hb_out), .VBlank_out (vb_out),
      .DE_out    (de_out), .RGB_out (rgb_out)
  );

  // ==== the OLD module as the oracle ====
  // The old gamma_fast: three register arrays, a write case and the
  // registered look-up. This is the behaviour the RAM version must equal.
  wire        gamma_en = gamma_bus[19];
  wire        gamma_wr = gamma_bus[18];
  wire [9:0]  gamma_wr_addr = gamma_bus[17:8];
  wire [7:0]  gamma_value = gamma_bus[7:0];

  reg [7:0] ref_curve_r[256];
  reg [7:0] ref_curve_g[256];
  reg [7:0] ref_curve_b[256];

  always @(posedge clk_vid) if (gamma_wr) begin
    case (gamma_wr_addr[9:8])
      0: ref_curve_r[gamma_wr_addr[7:0]] <= gamma_value;
      1: ref_curve_g[gamma_wr_addr[7:0]] <= gamma_value;
      2: ref_curve_b[gamma_wr_addr[7:0]] <= gamma_value;
    endcase
  end

  reg [7:0]  ref_idx_r, ref_idx_g, ref_idx_b;
  reg [23:0] ref_rgb_out;
  reg        ref_hs_out, ref_vs_out, ref_de_out;

  always @(posedge clk_vid) begin
    reg hs, vs, de;
    if (ce_pix) begin
      {ref_idx_r, ref_idx_g, ref_idx_b} <= rgb_in;
      hs <= hs_i; vs <= vs_i; de <= de_i;
      ref_rgb_out <= gamma_en ? {ref_curve_r[ref_idx_r], ref_curve_g[ref_idx_g], ref_curve_b[ref_idx_b]}
                              : {ref_idx_r, ref_idx_g, ref_idx_b};
      ref_hs_out <= hs; ref_vs_out <= vs; ref_de_out <= de;
    end
  end

  // ==== CHECKS ====

  integer errors = 0;
  integer i, n, pass;
  reg compare_en = 0;

  // Three injective patterns, one per lane. An odd multiplier is a permutation of
  // the 256 indices, and the three differ on every index, so a lane swap or an
  // address-bit swap produces a value the reference does not.
  function [7:0] pat_r(input [7:0] idx); pat_r = idx * 8'd37  + 8'd11;  endfunction
  function [7:0] pat_g(input [7:0] idx); pat_g = idx * 8'd181 + 8'd7;   endfunction
  function [7:0] pat_b(input [7:0] idx); pat_b = idx * 8'd97  + 8'd201; endfunction

  // One gamma_bus write, held across exactly one posedge clk_vid.
  task gamma_write(input [1:0] lane, input [7:0] addr, input [7:0] val);
    begin
      @(negedge clk_vid);
      ctrl = {1'b0, 1'b1, lane, addr, val};
      @(negedge clk_vid);
      ctrl[18] = 1'b0;
    end
  endtask

  // Present one pixel with ce_pix high, gamma_en as given.
  task present(input [23:0] px, input en);
    begin
      @(negedge clk_vid);
      rgb_in = px; ce_pix = 1; ctrl[19] = en;
    end
  endtask

  // Compare the registered outputs, one clock after the DUT and the oracle have
  // both updated.
  task check_cycle(input [255:0] what);
    begin
      if (rgb_out !== ref_rgb_out) begin
        $display("FAIL %0s: RGB_out=%06x ref=%06x", what, rgb_out, ref_rgb_out);
        errors = errors + 1;
      end
      if (hs_out !== ref_hs_out || vs_out !== ref_vs_out || de_out !== ref_de_out) begin
        $display("FAIL %0s: sync out hs/vs/de=%b/%b/%b ref=%b/%b/%b",
                 what, hs_out, vs_out, de_out, ref_hs_out, ref_vs_out, ref_de_out);
        errors = errors + 1;
      end
    end
  endtask

  // ==== VERDICT: see the end of the run block ====
  always @(posedge clk_vid) begin
    #1;
    if (compare_en) check_cycle("stream");
  end

  initial begin
    repeat (4) @(posedge clk_vid);

    // ---- seed every entry of all three lanes through the gamma_bus ----
    for (i = 0; i < 256; i = i + 1) begin
      gamma_write(2'd0, i[7:0], pat_r(i[7:0]));
      gamma_write(2'd1, i[7:0], pat_g(i[7:0]));
      gamma_write(2'd2, i[7:0], pat_b(i[7:0]));
    end

    // ---- explicit read-back of every index, all three channels at once ----
    // Present {idx, idx, idx}; that reaches RGB_out two enabled edges later, and
    // each lane must return its OWN table's byte. This is the read-back stated in
    // the claim and it fails on a lane swap by construction.
    for (i = 0; i < 256; i = i + 1) begin
      present({i[7:0], i[7:0], i[7:0]}, 1'b1);
      @(negedge clk_vid);                // edge 1: DUT's registered read holds curve[idx]
      @(negedge clk_vid);                // edge 2: RGB_out holds that value
      #1;
      if (rgb_out !== {pat_r(i[7:0]), pat_g(i[7:0]), pat_b(i[7:0])}) begin
        $display("FAIL readback idx=%02x: RGB_out=%06x want=%06x", i,
                 rgb_out, {pat_r(i[7:0]), pat_g(i[7:0]), pat_b(i[7:0])});
        errors = errors + 1;
      end
    end

    // ---- cycle-for-cycle equivalence over a stream with CE gaps ----
    // Three passes of every index, with the three bytes mapped differently each
    // pass so a channel permutation cannot hide, gamma_en toggled, and ce_pix low
    // one edge in seven (the enable hold the free-running read would break).
    compare_en = 1;
    for (pass = 0; pass < 3; pass = pass + 1) begin
      for (n = 0; n < 256; n = n + 1) begin
        @(negedge clk_vid);
        ce_pix = ((n % 7) != 3);
        ctrl[19] = ((n % 5) != 0);
        hs_i = (n[3] ^ n[7]); vs_i = n[6]; de_i = ~n[2];
        rgb_in = (pass == 0) ? {pat_r(n[7:0]), pat_g(n[7:0]), pat_b(n[7:0])}
               : (pass == 1) ? {8'hFF - n[7:0], n[7:0] ^ 8'hA5, n[7:0]}
                             : {n[7:0], 8'h55, 8'hAA - n[7:0]};
      end
    end

    @(posedge clk_vid); #1;
    compare_en = 0;
    ce_pix = 0;

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GAMMA: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GAMMA: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_GAMMA: TIMEOUT");
  end

endmodule
