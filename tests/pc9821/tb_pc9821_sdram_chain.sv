`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_CHAIN: the SDRAM controller's write path runs at the module's own timing floor without breaking it - at 90 MHz CL2 (base), 120 MHz CL3 (heavyoc) and 50 MHz CL2 (the clock of the integrated boot tier, run_boot_real.sh, where tWR is one clock and tDAL three), through split_sdram_backend at the deployed settings (ADQM=1, FAST_GRADE=0, a 64 MB module) against sdram_chip_model with the -7 grade's AC checks on (AS4C32M16SB datasheet Rev 1.4 Table 16: tRCD, tRP, tRAS for explicit and auto precharge, tRC, tRRD, tWR as the precharge's start, tRFC, tMRD) and the AUTO REFRESH gap held to tREFI: single-dword stores that alternate between two rows of one bank (no row can stay open) are accepted no further apart than the supported set's write floor - an ACT, the two halves' WRITEs tRCD (21 ns) after it, then tWR (15 ns) and tRP (21 ns) to the next ACT, or tRC (68 ns) if longer, each in whole clocks: 7 at 90 MHz, 9 at 120 MHz, 6 at 50 MHz - and port 0's two-word writes alternating the same way no further apart than the same floor with their four halves (9, 11 and 8), a gap that holds an AUTO REFRESH on the pins being reported and not judged; every such store's next ACT, exactly tDAL after its auto-precharged WRITE, is legal by the datasheet's own rule (tWR + tRP in nanoseconds from the WRITE), which the chip model judges at each clock; a randomized soak of single and byte-masked stores in a few hot rows with an L1-like re-presentation (the next store 0-2 clocks after the accept), 4-dword line reads, reads pipelined behind stores, sequential line streams and background reads on ports 1 and 3 reads every word back as the scoreboard holds it; and ready pulses exactly once per request (no request is accepted twice while its requester still presents it in the ready cycle).
//
// WHY. Every store paid an IDLE latch, an ACT, tRCD, its two halves and an auto-precharge, then
// one clock more than tDAL and tRC needed before IDLE (the exit was set before the IDLE and ACT
// stages existed), so a store stream ran at one accept per 8 clocks where the module allows 7.
// The soak is the instrument for the write path's shape changes: it presents the shapes the
// L1 drains (stores re-presented a clock or two after their accept, reads right behind stores),
// and every command it causes is judged by the chip model.
//
// Expected values: the floor is computed here from nanoseconds (the supported set's bounds,
// docs/sdram.md: tRCD/tRP 21, tRC 68, tWR 15 ns, each converted to whole clocks by ceil(t / tCK)
// as that page requires; the controller's front end puts an accept one ACT apart), not from the
// controller's constants; read-back values are what the bench stored.
//
// THE 50 MHZ RIG. The integrated boot tier on the real controller (run_boot_real.sh) runs at
// 50 MHz, where tWR is one clock: a store's next ACT comes three clocks (60 ns) after its
// auto-precharged WRITE, against the datasheet's tWR + tRP = 35 ns. A tRP check counted in
// clocks from a fixed two-clock tWR rejects that legal sequence; this rig presents it on every
// store, so the chip model must judge it from nanoseconds.

`default_nettype none

module tb_pc9821_sdram_chain_rig #(
    parameter integer FREQ = 90_000_000
);
  localparam real    TCK   = 1.0e9 / FREQ;
  localparam integer CAS   = (FREQ < 100_000_000) ? 2 : 3;   // the hardware's cutover (sdram.v CAS_I)
  // ceil(ns / tCK), exactly
  function automatic integer cyc_of(input integer ns);
    cyc_of = int'((64'(ns) * FREQ + 64'd999_999_999) / 64'd1_000_000_000);
  endfunction
  localparam integer C_RCD = cyc_of(21);
  // The write floor: ACT at 0, the WRITEs at tRCD and tRCD+1 clocks, the precharge tWR after the
  // second, tRP to the next ACT; or tRC.
  localparam integer FLOOR_DAL = C_RCD + 1 + cyc_of(15) + cyc_of(21);
  localparam integer FLOOR_RC  = cyc_of(68);
  localparam integer FLOOR     = (FLOOR_DAL > FLOOR_RC) ? FLOOR_DAL : FLOOR_RC;
  // ... and for a two-word write: four halves, the last at tRCD + 3 clocks.
  localparam integer FLOOR_PAIR = ((C_RCD + 3 + cyc_of(15) + cyc_of(21)) > FLOOR_RC) ? (C_RCD + 3 + cyc_of(15) + cyc_of(21)) : FLOOR_RC;

  reg clk = 1'b0;
  always #(TCK / 2.0) clk = ~clk;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  reg reset = 1'b1;
  reg v0 = 1'b0, w0 = 1'b0; reg [31:0] a0 = 32'd0, d0 = 32'd0, h0 = 32'd0; reg [3:0] be0 = 4'hF; reg [7:0] bc0 = 8'd1;
  reg v1 = 1'b0; reg [31:0] a1 = 32'd0; reg [7:0] bc1 = 8'd1;
  reg v3 = 1'b0; reg [31:0] a3 = 32'd0; reg [7:0] bc3 = 8'd10;
  wire r0, r1, r3, rs0, rs1, rs3;
  wire [31:0] do0, do1, do3;
  wire busy;
  wire [15:0] dq; wire [12:0] sa; wire [1:0] sba, sdqm; wire nwe, nras, ncas, ncs, cke;
  split_sdram_backend #(.FREQ(FREQ), .ADQM(1'b1), .FAST_GRADE(1'b0), .GATHER_K(4)) be_i (
    .clk(clk), .reset(reset), .refresh_allowed(1'b1), .sdram_size(2'd2), .busy(busy),
    .mem0_valid(v0), .mem0_ready(r0), .mem0_write(w0), .mem0_addr(a0), .mem0_din(d0), .mem0_din_hi(h0),
    .mem0_gath(1'b0), .mem0_gath_extra(441'd0), .mem0_dout(do0), .mem0_resp_valid(rs0), .mem0_be(be0), .mem0_burstcount(bc0),
    .mem1_valid(v1), .mem1_ready(r1), .mem1_write(1'b0), .mem1_addr(a1), .mem1_din(32'd0), .mem1_dout(do1),
    .mem1_resp_valid(rs1), .mem1_be(4'hF), .mem1_burstcount(bc1),
    .mem2_valid(1'b0), .mem2_ready(), .mem2_write(1'b0), .mem2_addr(32'd0), .mem2_din(32'd0), .mem2_dout(),
    .mem2_resp_valid(), .mem2_be(4'hF), .mem2_burstcount(8'd1),
    .mem3_valid(v3), .mem3_ready(r3), .mem3_write(1'b0), .mem3_addr(a3), .mem3_din(32'd0), .mem3_dout(do3),
    .mem3_resp_valid(rs3), .mem3_be(4'hF), .mem3_burstcount(bc3),
    .sdram_dq(dq), .sdram_a(sa), .sdram_ba(sba), .sdram_dqm(sdqm), .sdram_nwe(nwe), .sdram_nras(nras),
    .sdram_ncas(ncas), .sdram_ncs(ncs), .sdram_cke(cke));
  sdram_chip_model #(.CAS(CAS), .FREQ_HZ(FREQ), .GRADE(7), .REFRESH_INTERVAL(FREQ / 128_000)) chip (
    .clk(clk), .DQ(dq), .A(sa), .BA(sba), .nRAS(nras), .nCAS(ncas), .nWE(nwe), .nCS(ncs));

  // ==== CHECKS ====
  integer errors = 0;
  bit     done = 1'b0;
  reg [31:0] sb [bit [29:0]];          // the scoreboard: the dword each address holds
  integer nw = 0, nr = 0, pul0 = 0;
  always @(posedge clk) if (r0) pul0 <= pul0 + 1;
  // AUTO REFRESH commands seen on the pins ({RAS#, CAS#, WE#} = 0, 0, 1): a store gap that holds
  // one is not a write-floor sample.
  integer nref = 0;
  always @(posedge clk) if (!ncs && !nras && !ncas && nwe) nref <= nref + 1;

  // One port-0 store, held until its accept; returns the accept cycle. The scoreboard commits at
  // the accept (accept order is the controller's write order).
  task automatic store(input [31:0] ad, input [31:0] dd, input [3:0] bb, output integer at);
    integer i;
    begin
      @(negedge clk); v0 = 1'b1; w0 = 1'b1; a0 = ad; d0 = dd; be0 = bb; bc0 = 8'd1;
      forever begin @(posedge clk); if (r0) break; end
      at = cyc;
      if (!sb.exists(ad[31:2])) sb[ad[31:2]] = 32'd0;
      for (i = 0; i < 4; i = i + 1) if (bb[i]) sb[ad[31:2]][i*8 +: 8] = dd[i*8 +: 8];
      nw = nw + 1;
      @(negedge clk); v0 = 1'b0; w0 = 1'b0;
    end
  endtask

  // Port 0's two-word write (burst count 2: d0 at ad, h0 at ad + 4).
  task automatic store_pair(input [31:0] ad, input [31:0] dd, input [31:0] hh, output integer at);
    begin
      @(negedge clk); v0 = 1'b1; w0 = 1'b1; a0 = ad; d0 = dd; h0 = hh; be0 = 4'hF; bc0 = 8'd2;
      forever begin @(posedge clk); if (r0) break; end
      at = cyc;
      sb[ad[31:2]] = dd; sb[ad[31:2] + 1] = hh;
      nw = nw + 1;
      @(negedge clk); v0 = 1'b0; w0 = 1'b0; bc0 = 8'd1;
    end
  endtask

  task automatic read4(input [31:0] ad);
    integer b; reg [31:0] base;
    begin
      base = {ad[31:4], 4'b0};
      @(negedge clk); v0 = 1'b1; w0 = 1'b0; a0 = base; bc0 = 8'd4;
      forever begin @(posedge clk); if (r0) break; end
      @(negedge clk); v0 = 1'b0;
      for (b = 0; b < 4; b = b + 1) begin
        forever begin @(posedge clk); if (rs0) break; end
        if (sb.exists(base[31:2] + b) && (do0 !== sb[base[31:2] + b])) begin
          errors = errors + 1;
          $display("FAIL chain %0d MHz: read %08x got %08x want %08x (cycle %0d)", FREQ / 1_000_000, base + 4 * b, do0, sb[base[31:2] + b], cyc);
        end
      end
      nr = nr + 1;
    end
  endtask

  // A read issued right before a few stores: its answer is the data at its accept (snapshotted
  // there), checked as its beats arrive while the stores run behind it.
  reg [31:0] pq_w [0:15][0:3]; reg pq_v [0:15][0:3]; integer pq_wr = 0, pq_rd = 0, pq_beat = 0;
  reg [31:0] pq_base [0:15];
  bit pq_busy = 1'b0;
  always @(posedge clk) if (rs0 && pq_busy && (pq_rd != pq_wr)) begin
    if (pq_v[pq_rd % 16][pq_beat] && (do0 !== pq_w[pq_rd % 16][pq_beat])) begin
      errors = errors + 1;
      $display("FAIL chain %0d MHz: pipelined read %08x beat %0d got %08x want %08x", FREQ / 1_000_000,
               pq_base[pq_rd % 16], pq_beat, do0, pq_w[pq_rd % 16][pq_beat]);
    end
    if (pq_beat == 3) begin pq_beat <= 0; pq_rd <= pq_rd + 1; end else pq_beat <= pq_beat + 1;
  end

  function automatic [31:0] pick(input integer sel_in);
    integer sel;
    begin
      sel = sel_in % 100;
      if (sel < 55)      pick = 32'h0000_0000 + (($urandom % 512) * 4);   // hot row 0, bank 0
      else if (sel < 75) pick = 32'h0000_0800 + (($urandom % 512) * 4);   // row 1, bank 0
      else if (sel < 90) pick = 32'h0010_0000 + (($urandom % 512) * 4);   // another row, bank 0
      else               pick = 32'h0100_0000 + (($urandom % 512) * 4);   // bank 1
    end
  endfunction

  // Background reads on ports 1 and 3 (the font reader's and the scanout's shapes).
  bit bg_on = 1'b0;
  always @(posedge clk) if (!reset && bg_on) begin
    if (!v1 && (($urandom % 400) == 0)) begin v1 <= 1'b1; a1 <= 32'h0000_0000 + (($urandom % 512) * 4); bc1 <= 8'(1 + ($urandom % 4)); end
    if (v1 && r1) v1 <= 1'b0;
    if (!v3 && (($urandom % 250) == 0)) begin v3 <= 1'b1; a3 <= 32'h0200_0000 + (($urandom % 400) * 4); bc3 <= 8'd10; end
    if (v3 && r3) v3 <= 1'b0;
  end

  integer k, q, at, prev, prev_ref, gap, worst, ops, burst, b;
  reg [31:0] ad;

  task automatic run();
    begin
      repeat (5) @(posedge clk);
      reset = 1'b0;
      repeat (50) @(posedge clk);
      wait (!busy);
      repeat (20) @(posedge clk);

      // ---- THE WRITE FLOOR: stores alternating between two rows of bank 0 ----
      worst = 0; prev = -1;
      for (k = 0; k < 12; k = k + 1) begin
        store(((k & 1) ? 32'h0000_0800 : 32'h0000_0000) + 32'(k * 4), 32'hA000_0000 + k, 4'hF, at);
        if (prev >= 0 && (nref != prev_ref))
          $display("NOTE chain %0d MHz: an AUTO REFRESH fell between two stores (%0d clocks apart, not judged)", FREQ / 1_000_000, at - prev);
        else if (prev >= 0 && (at - prev) > worst) worst = at - prev;
        prev = at; prev_ref = nref;
      end
      $display("MEASURED chain %0d MHz: alternating-row stores accepted %0d clocks apart at worst (floor %0d)", FREQ / 1_000_000, worst, FLOOR);
      if (worst > FLOOR) begin
        errors = errors + 1;
        $display("FAIL chain %0d MHz: alternating-row stores %0d clocks apart, above the module's write floor of %0d", FREQ / 1_000_000, worst, FLOOR);
      end
      for (k = 0; k < 12; k = k + 1) read4(((k & 1) ? 32'h0000_0800 : 32'h0000_0000) + 32'(k * 4));
      // ... and two-word writes, alternating the same way
      worst = 0; prev = -1;
      for (k = 0; k < 12; k = k + 1) begin
        store_pair(((k & 1) ? 32'h0000_0800 : 32'h0000_0000) + 32'(64 + k * 8), 32'hB000_0000 + k, 32'hC000_0000 + k, at);
        if (prev >= 0 && (nref != prev_ref))
          $display("NOTE chain %0d MHz: an AUTO REFRESH fell between two pairs (%0d clocks apart, not judged)", FREQ / 1_000_000, at - prev);
        else if (prev >= 0 && (at - prev) > worst) worst = at - prev;
        prev = at; prev_ref = nref;
      end
      $display("MEASURED chain %0d MHz: alternating-row pairs accepted %0d clocks apart at worst (floor %0d)", FREQ / 1_000_000, worst, FLOOR_PAIR);
      if (worst > FLOOR_PAIR) begin
        errors = errors + 1;
        $display("FAIL chain %0d MHz: alternating-row pairs %0d clocks apart, above the module's floor of %0d", FREQ / 1_000_000, worst, FLOOR_PAIR);
      end
      for (k = 0; k < 12; k = k + 1) read4(((k & 1) ? 32'h0000_0800 : 32'h0000_0000) + 32'(64 + k * 8));

      // ---- THE SOAK ----
      bg_on = 1'b1;
      for (ops = 0; ops < 3000; ops = ops + 1) begin
        q = $urandom % 40;
        if (q < 5) begin
          read4(pick($urandom));
        end else if (q < 9) begin
          // sequential line reads, sometimes with a store to the following line
          ad = 32'h0000_0000 + 16 * ($urandom % 24);
          for (b = 0; b < 2 + ($urandom % 8); b = b + 1) begin
            read4(ad + 16 * b);
            if (($urandom % 4) == 0) store(ad + 16 * b + 16 + 4 * ($urandom % 4), $urandom, 4'hF, at);
          end
        end else if (q < 13) begin
          // a read with stores right behind it
          ad = {pick($urandom) >> 4, 4'b0};
          @(negedge clk); v0 = 1'b1; w0 = 1'b0; a0 = ad; bc0 = 8'd4;
          forever begin @(posedge clk); if (r0) break; end
          for (b = 0; b < 4; b = b + 1) begin
            pq_v[pq_wr % 16][b] = sb.exists(ad[31:2] + b);
            pq_w[pq_wr % 16][b] = pq_v[pq_wr % 16][b] ? sb[ad[31:2] + b] : 32'd0;
          end
          pq_base[pq_wr % 16] = ad; pq_wr = pq_wr + 1; nr = nr + 1; pq_busy = 1'b1;
          @(negedge clk); v0 = 1'b0;
          repeat (2) @(posedge clk);
          for (b = 0; b < 1 + ($urandom % 5); b = b + 1)
            store(pick($urandom), $urandom, (($urandom % 4) == 0) ? 4'(1 + ($urandom % 15)) : 4'hF, at);
          repeat (24) @(posedge clk);
          pq_busy = 1'b0;
        end else begin
          // a store burst, the next store 0-2 clocks after each accept (the L1's drain)
          burst = 1 + ($urandom % 8);
          for (b = 0; b < burst; b = b + 1) begin
            store(pick($urandom), $urandom, (($urandom % 4) == 0) ? 4'(1 + ($urandom % 15)) : 4'hF, at);
            repeat ($urandom % 3) @(posedge clk);
          end
        end
        if (($urandom % 64) == 0) repeat ($urandom % 40) @(posedge clk);
      end
      bg_on = 1'b0;
      repeat (200) @(posedge clk);
      if (pul0 != nw + nr) begin
        errors = errors + 1;
        $display("FAIL chain %0d MHz: port 0 saw %0d ready pulses for %0d requests (a request accepted twice)", FREQ / 1_000_000, pul0, nw + nr);
      end
      $display("TB_PC9821_SDRAM_CHAIN %0d MHz: stores %0d reads %0d errors %0d", FREQ / 1_000_000, nw, nr, errors);
      done = 1'b1;
    end
  endtask
endmodule

module tb_pc9821_sdram_chain;
  // ==== DUT ====
  tb_pc9821_sdram_chain_rig #(.FREQ(90_000_000))  r90 ();
  tb_pc9821_sdram_chain_rig #(.FREQ(120_000_000)) r120 ();
  tb_pc9821_sdram_chain_rig #(.FREQ(50_000_000))  r50 ();

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_SDRAM_CHAIN: FAIL (watchdog; done 90=%0d 120=%0d 50=%0d)", r90.done, r120.done, r50.done);
  end

  // ==== VERDICT ====
  initial begin
    $urandom(7);
    fork
      r90.run();
      r120.run();
      r50.run();
    join
    if (r90.done && r120.done && r50.done && (r90.errors == 0) && (r120.errors == 0) && (r50.errors == 0)) begin
      $display("TB_PC9821_SDRAM_CHAIN: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_SDRAM_CHAIN: FAIL (errors 90=%0d 120=%0d 50=%0d)", r90.errors, r120.errors, r50.errors);
    end
  end
endmodule

`default_nettype wire
