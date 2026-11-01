`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_XE10_PACE: the EGC through the REAL pc9821_gvram_arb, pc9821_gvram_share and pc9821_gvram_mem keeps every egcplane shape at or under the Xe10's own NET cost per access (docs/probes/EGCP.TXT, the egcplane probe on the real Xe10 decoded by tools/hwprobe/egcplane/egcplane_decode.py: EGC1400 and EGC0CF0 write rows 0.6-0.8 ns net, so the CPU never waits on an EGC write; EGC3100SP and EGC28F0SP same-page read+write rows 676.9-677.5 ns net) at 80 MHz (base) AND at 50 MHz (the slowest clk_sys the build system offers a base-like build, `--custom --clk-sys-mhz 50`), driven by a CPU model that issues the probe's own loop (body_egc: one word read and/or one word write per row, 80-byte row stride, page 0) with the core's own measured loop-shell time between accesses, and the per-row time is IDENTICAL for 1, 2, 3 and 4 planes enabled through 0x4A0 (FFFE/FFFC/FFF8/FFF0) on every shape, as it is on the machine. It reports each shape's margin against the machine. FAIL-FIRST: an engine that spends 20 extra clk_sys per unit fails the write rows (the CPU starts waiting on posted writes).
//
// THE CPU MODEL. egcplane.s's body_egc row is `mov es:[di],ax` (write-only shapes) or
// `mov ax,es:[di]` ... `mov es:[di],ax` (read+write shapes) inside a shell of plain instructions;
// the probe's NET number is the row minus a control row with the accesses replaced by register
// operations (CTRLEW/CTRLER). The shell's length on THIS core is its own capture of the same
// binary (docs/probes/core/EGCP-core.TXT: the MiSTer at 80 MHz, the plane-parallel engine):
//   EGCP CTRLEW UNITS=1000 ARTIC=1510 CLK50=245768 PER=245768   -> 307.2 ns/row = 24.6 clk_sys at 80 MHz
//   EGCP CTRLER UNITS=1000 ARTIC=2064 CLK50=335937 PER=335937   -> 419.9 ns/row = 33.6 clk_sys at 80 MHz
// The shell runs on z486 at clk_sys, so it is the same number of CLK_SYS at every clock. A
// write-only row's shell is the nine instructions after the store (add, dec, jnz, mov, cmp, je,
// cmp, je, mov es); the read+write row's is three after the load (cmp, je, mov es) and the same
// nine after the store. So the model spends G_W = 24 clk_sys after a write (write-only rows),
// G_RW1 = 8 after a read's data and G_RW2 = 24 after a write (read+write rows) - each the FLOOR of
// the capture's share, so the model presents the next access no later than the core would. A
// store is posted (the shell runs on from the store's presentation; the CPU waits only when the
// NEXT access is not accepted), a load waits for its data. The NET per row is then
// (row time - shell time), exactly the probe's row-minus-control, and an EGC that finishes a
// posted write within the shell costs the CPU nothing - the machine's ~0.7 ns.
//
// What it does NOT model: the CPU's instruction fetch and cache, and the GFX2 (gfxbenc2) GROSS
// rows (EGC3100SP 975 ns/unit, EGC1400 227 ns/unit), whose shells are the Xe10's and are not
// comparable with this core's shell; the net rows above are the machine's own subtraction.

`default_nettype none

module egc_pace_rig #(
    parameter integer CLK_HZ = 80_000_000
) (
    output reg     done,
    output integer errs
);
  localparam real PERIOD_NS = 1.0e9 / CLK_HZ;
  reg clk = 0;
  always #(PERIOD_NS / 2.0) clk = ~clk;
  reg reset = 1;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  reg         access_page = 1'b0;
  reg  [1:0]  win_plane = 2'd0;
  reg [14:0]  win_offset = 15'd0;
  reg [31:0]  cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'hF;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_line_word_valid, gdc_mem_ready, gdc_mem_resp, grcg_expand;
  wire [31:0]  gdc_mem_rdata, line_data;
  wire         line_sel, line_ready;
  wire [127:0] dbg_gfx_stats;
  wire         dbg_walk_start, dbg_walk_cycle, dbg_egc_txn, dbg_egc_unit, dbg_grcg_store,
               dbg_gr_owned, dbg_eg_owned, dbg_access_page, dbg_scan_page_q;
  /* verilator lint_on UNUSEDSIGNAL */
  wire         cpu_ready, cpu_resp_valid;
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h0000,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(CLK_HZ)) dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(1'b0),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(1'b0), .grcg_addr(8'd0), .grcg_din(8'd0), .grcg_expand(grcg_expand),
      .egc_gate(1'b1), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .gdc_mem_valid(1'b0), .gdc_mem_ready(gdc_mem_ready), .gdc_mem_write(1'b0),
      .gdc_mem_route_egc(1'b0), .gdc_mem_route_grcg(1'b0), .gdc_mem_page(1'b0),
      .gdc_mem_plane(2'd0), .gdc_mem_offset(15'd0), .gdc_mem_din(32'd0), .gdc_mem_be(4'd0),
      .gdc_mem_resp(gdc_mem_resp), .gdc_mem_rdata(gdc_mem_rdata),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0), .scan_line_base(15'd0),
      .gfx_odd_line(1'b0), .line_rd_addr(7'd0), .line_rd_sel(1'b0),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready),
      .dbg_gfx_stats(dbg_gfx_stats), .dbg_walk_start(dbg_walk_start),
      .dbg_walk_cycle(dbg_walk_cycle), .dbg_egc_txn(dbg_egc_txn), .dbg_egc_unit(dbg_egc_unit),
      .dbg_grcg_store(dbg_grcg_store), .dbg_gr_owned(dbg_gr_owned),
      .dbg_eg_owned(dbg_eg_owned), .dbg_access_page(dbg_access_page),
      .dbg_scan_page_q(dbg_scan_page_q));

  // ==== STIMULUS ====
  localparam integer G_W = 24, G_RW1 = 8, G_RW2 = 24;   // the shell, see the header
  // The load's path OUTSIDE this DUT (z486's load issue and completion, the memory subsystem's
  // route to the GVRAM), CALIBRATED on the core's own capture of the plane-PARALLEL engine
  // (docs/probes/core/EGCP-core.TXT):
  //   EGCP EGC3100SPP1 UNITS=1000 ARTIC=3238 CLK50=527018 PER=527018  -> 238.9 ns net = 19.1 clk_sys at 80 MHz
  // where this model without it reads 11 clk_sys (137.5 ns) for the same engine - so 8 clk_sys of
  // every load are the CPU's, and they are added after each load's data so the model's net is the
  // core's measured net for the engine it was measured on.
  localparam integer G_RD_PATH = 8;
  localparam integer ROWS = 64;                         // four of the probe's 16-row sprites

  // One word access at the row's offset (lane from the offset's bit 1, the 486's byte enables).
  // Returns the cycle the access was presented and, for a load, the cycle its data arrived.
  // Called at a negedge (the caller's wait_until ends on one); the access is presented there, so
  // the shell's cycles and the access's own are not double-counted. The CPU's accept gap: a new
  // access is never presented in the cycle the previous one's valid was released.
  integer last_drop = -1;
  task automatic cpu_acc(input wr, input [14:0] off, output integer t_pres, output integer t_done);
    begin
      if (cyc == last_drop) @(negedge clk);
      win_offset = {off[14:2], 2'b00};
      win_plane  = 2'd0;
      cpu_be     = off[1] ? 4'b1100 : 4'b0011;
      cpu_din    = 32'hFFFF_FFFF;          // body_egc's `mov ax, 0xFFFF`
      cpu_write  = wr;
      cpu_valid  = 1'b1;
      t_pres = cyc;
      while (!cpu_ready) @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      last_drop = cyc;
      if (!wr) while (!cpu_resp_valid) @(negedge clk);
      t_done = cyc;
    end
  endtask

  task automatic wait_until(input integer t);
    begin
      while (cyc < t) @(negedge clk);
    end
  endtask

  // One shape: program the EGC (egcplane.s EGCROW: mask FFFF, leng 000F) and time ROWS rows.
  task automatic run_shape(input [15:0] access, input [15:0] fgbg, input [15:0] ope,
                           input [15:0] fg, input [15:0] sft, input rw, output integer cycles);
    integer r, t0, tp, td, next;
    reg [14:0] off;
    begin
      @(negedge clk);
      egc_access = access; egc_fgbg = fgbg; egc_ope = ope; egc_fg = fg; egc_mask = 16'hFFFF;
      egc_sft = sft; egc_leng = 16'h000F; egc_shift_we = 1'b1;
      @(negedge clk);
      egc_shift_we = 1'b0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      repeat (4) @(negedge clk);
      t0 = cyc;
      next = cyc;
      off = 15'h0100;
      for (r = 0; r < ROWS; r = r + 1) begin
        wait_until(next);
        if (rw) begin
          cpu_acc(1'b0, off, tp, td);
          wait_until(td + G_RD_PATH + G_RW1);
          cpu_acc(1'b1, off, tp, td);
          next = tp + G_RW2;
        end else begin
          cpu_acc(1'b1, off, tp, td);
          next = tp + G_W;
        end
        off = off + 15'd80;
      end
      wait_until(next);
      cycles = cyc - t0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    end
  endtask

  // A posted write's DRAIN: from its presentation to the engine's return to S_IDLE (where it can
  // take the next access), the longest seen in the shape. Reported beside the shell it hides in.
  // It is NOT plane-flat inside the engine, in this engine or the parallel one before it: four
  // enabled planes make a 16-bit unit's two columns full words, which go out as ONE posted
  // two-column request, while fewer planes go out as two single-column requests that each wait
  // for their completion - a few clk_sys longer, and entirely inside the shell, so the CPU's time
  // (what the machine's flat rows measure) is identical, which is what the flatness check asserts.
  reg     drain_on = 1'b0;
  integer drain_t0 = 0, drain_max = 0;
  always @(posedge clk) begin
    if (!drain_on && cpu_valid && cpu_write) begin
      drain_on <= 1'b1; drain_t0 <= cyc;
    end else if (drain_on && (cyc > drain_t0 + 1) && (dut.u_egc.state == pc9821_egc_pkg::EGC_IDLE)) begin
      drain_on <= 1'b0;
      if (cyc - drain_t0 > drain_max) drain_max <= cyc - drain_t0;
    end
  end

  // ==== CHECKS ====
  // The machine's net ns per row (docs/probes/EGCP.TXT through egcplane_decode.py), the
  // strictest of the four plane counts for each shape.
  localparam real XE_W_NET  = 0.6;     // EGC1400 / EGC0CF0: 0.6-0.8 ns net
  localparam real XE_RW_NET = 676.9;   // EGC3100SP 676.9-677.5, EGC28F0SP 676.9-677.5 ns net
  task automatic shape(input [8*12-1:0] name, input [15:0] fgbg, input [15:0] ope,
                       input [15:0] fg, input [15:0] sft, input rw);
    integer np, c, c1;
    real net, bar;
    begin
      c1 = 0;
      for (np = 1; np <= 4; np = np + 1) begin
        drain_max = 0;
        run_shape(16'hFFF0 | (16'hF & ~((16'h1 << np) - 16'h1)), fgbg, ope, fg, sft, rw, c);
        net = (c - ROWS * (rw ? (G_RW1 + G_RW2) : G_W)) * PERIOD_NS / ROWS;
        bar = rw ? XE_RW_NET : XE_W_NET;
        $display("NOTE egc_xe10_pace %0d MHz: %0s %0d plane(s): %0d clk_sys for %0d rows, net %0.1f ns/row vs Xe10 %0.1f (margin %0.1f ns); longest posted-write drain %0d clk_sys behind a %0d clk_sys shell",
                 CLK_HZ / 1_000_000, name, np, c, ROWS, net, bar, bar - net, drain_max, rw ? G_RW2 : G_W);
        if (net > bar) begin
          $display("FAIL egc_xe10_pace %0d MHz: %0s with %0d plane(s) costs %0.1f ns/row net, over the Xe10's %0.1f",
                   CLK_HZ / 1_000_000, name, np, net, bar);
          errs = errs + 1;
        end
        if (np == 1) c1 = c;
        else if (c != c1) begin
          $display("FAIL egc_xe10_pace %0d MHz: %0s takes %0d clk_sys with %0d planes but %0d with 1 - not flat across the plane mask",
                   CLK_HZ / 1_000_000, name, c, np, c1);
          errs = errs + 1;
        end
      end
    end
  endtask

  initial begin
    done = 1'b0;
    errs = 0;
    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (60) @(posedge clk);
    // egcplane.s: EGCSHAPE <name>, fgbg, ope, fg, sft, rw
    shape("EGC1400",   16'h40FF, 16'h1400, 16'h0009, 16'h0000, 1'b0);
    shape("EGC0CF0",   16'h00FF, 16'h0CF0, 16'h0009, 16'h0000, 1'b0);
    shape("EGC3100SP", 16'h00FF, 16'h3100, 16'h0009, 16'h0000, 1'b1);
    shape("EGC28F0SP", 16'h00FF, 16'h28F0, 16'h0009, 16'h0002, 1'b1);
    done = 1'b1;
  end
endmodule

module tb_pc9821_egc_xe10_pace;
  wire    done80, done50;
  integer errs80, errs50;
  egc_pace_rig #(.CLK_HZ(80_000_000)) rig80 (.done(done80), .errs(errs80));
  egc_pace_rig #(.CLK_HZ(50_000_000)) rig50 (.done(done50), .errs(errs50));

  initial begin
    #1;
    wait (done80 === 1'b1 && done50 === 1'b1);
    // ==== VERDICT ====
    if (errs80 == 0 && errs50 == 0) begin
      $display("TB_PC9821_EGC_XE10_PACE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_EGC_XE10_PACE: FAIL (%0d errors at 80 MHz, %0d at 50 MHz)", errs80, errs50);
      $fatal(1, "TB_PC9821_EGC_XE10_PACE: FAIL");
    end
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_EGC_XE10_PACE: TIMEOUT");
  end
endmodule

`default_nettype wire
