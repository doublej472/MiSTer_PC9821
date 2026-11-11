`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_SYNC: the SDRAM backend - split_sdram_backend over sdram_sync_bridge, the controller on clk_sys at FREQ = clk_sys, the only build since the split-clock configuration was removed - keeps its requester-side contract at EVERY preset clock, 90 MHz (base, the shipping build), 95 MHz (the fastest CL2 clock), 100 MHz (mediumoc), 120 MHz (heavyoc, at the SDRAM part's limit) and 50 MHz (the clock the other bridge benches run), each driven by the SAME requester program against sdram_chip_model at the deployed module settings (ADQM=1, FAST_GRADE=0, GATHER_K=4) with its protocol checks and the -7 grade's AC checks (AS4C32M16SB datasheet Rev 1.4 Table 16) on and the AUTO REFRESH gap held to tREFI = 64 ms / 8192: every ready is one clk_sys cycle and answers a presented request, every read answers exactly one resp_valid per dword on the port that asked and nowhere else, a write answers none, every word read back is the word written (single dwords, 4-dword line fills, byte-masked stores, 8/10-dword bursts), port 0's dout holds its last word between its own pulses while ports 1-3 answer in between (the hold the controller does not keep and the bridge must), and all four ports are served while they contend. The single-dword read/write round trip, the 4-dword line fill, the posted-store and line-fill stream rates and the byte-store cost are MEASURED at each clock in clk_sys cycles and ns and REPORTED, not asserted. Every MODE REGISTER SET the controller issues programs the CAS latency the hardware requires - CL2 below 100 MHz (90, 95, 50), CL3 at 100 MHz and up (100, 120), the cutover two DE10-Nano boards set on 2026-10-13 - and the device model returns read data at that latency, so a controller reading at the CL2 edge at 100 MHz also fails the data checks. FAIL-FIRST: a bare pass-through without port 0's hold fails the dout0 hold check. FAIL-FIRST: with CL2 kept at 100 MHz (the old FREQ <= 100 MHz rule) the 100 MHz harness fails its MRS and read-data checks.
//
// Until 2026-10-09 this bench ran the same program on the clock-domain build (sdram_clock_bridge,
// a 100 MHz clk_sdram) and the same-clock build side by side. The split-clock build is gone,
// so each harness here is the one build at one clock.
// "As the CPU sees it" means at split_sdram_backend's requester ports: the memory subsystem and
// the z486 cache add their own clk_sys cycles on top.
//
// WHAT IT DOES NOT PROVE: sdram_chip_model checks commands at clock resolution, not a timing-accurate
// device; the AC timing against the strict module model at each clock is tb_pc9821_sdram_strict's,
// and whether the board meets the I/O timing at a clock is the fit's STA, not a simulation.

`default_nettype none

// One backend at one clock, its device model and a requester program. The top instantiates one
// per preset clock and runs the same program on each.
module tb_pc9821_sdram_sync_harness #(
    parameter integer FREQ = 90_000_000,        // clk_sys = the controller's clock
    parameter real    SYS_NS = 1000.0 / 90       // one clk_sys, for the ns report
) (
    input wire clk           // clk_sys: requesters, controller and device model
);
  // The controller's derived tRP/tWR in cycles (sdram.v ns_to_cycles of 20 ns / 15 ns for the -7
  // grade), passed to the device model so its checks match the clock under test.
  //
  // CAS is the EXPECTED latency, set by hardware, not read off the RTL: CL2 strictly below
  // 100 MHz, CL3 at 100 MHz and up. On two DE10-Nano boards (2026-10-13, 100 MHz clk_sys =
  // SDRAM, the disk-integrity probe) CL2 failed on one board for 9 of 11 placements while CL3
  // placements passed on both, and 95 MHz CL2 passed the full regression on both boards
  // (2026-10-13). The device model returns data CAS clocks after each READ, so a
  // controller sampling at the CL2 edge at 100 MHz reads the wrong half and fails the data
  // checks; the MRS check below also pins the mode register's CAS field (A[6:4]) to CAS.
  localparam integer KHZ   = (FREQ + 999) / 1000;
  localparam integer T_RP  = (20 * KHZ + 999_999) / 1_000_000;
  localparam integer T_WR  = (15 * KHZ + 999_999) / 1_000_000;
  localparam integer CAS   = (FREQ < 100_000_000) ? 2 : 3;
  localparam integer MHZ   = FREQ / 1_000_000;

  // ==== DUT ====
  reg  [3:0]       valid = 4'b0;
  reg  [3:0]       wr = 4'b0;
  reg  [3:0][31:0] addr = '0;
  reg  [3:0][31:0] din = '0;
  reg  [3:0][3:0]  be = {4{4'hF}};
  reg  [3:0][7:0]  burst = {4{8'd1}};
  wire [3:0]       ready;
  wire [3:0]       resp;
  wire [3:0][31:0] dout;
  reg              reset = 1'b1;
  wire             busy;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  split_sdram_backend #(
      .FREQ(FREQ), .ADQM(1'b1), .FAST_GRADE(1'b0), .GATHER_K(4)
  ) backend (
      .clk(clk), .reset(reset), .refresh_allowed(1'b1),
      .sdram_size(2'd2), .busy(busy),
      .mem0_valid(valid[0]), .mem0_ready(ready[0]), .mem0_write(wr[0]), .mem0_addr(addr[0]),
      .mem0_din(din[0]), .mem0_din_hi(32'd0), .mem0_gath(1'b0), .mem0_gath_extra(441'd0),
      .mem0_dout(dout[0]), .mem0_resp_valid(resp[0]), .mem0_be(be[0]), .mem0_burstcount(burst[0]),
      .mem1_valid(valid[1]), .mem1_ready(ready[1]), .mem1_write(wr[1]), .mem1_addr(addr[1]),
      .mem1_din(din[1]), .mem1_dout(dout[1]), .mem1_resp_valid(resp[1]), .mem1_be(be[1]),
      .mem1_burstcount(burst[1]),
      .mem2_valid(valid[2]), .mem2_ready(ready[2]), .mem2_write(wr[2]), .mem2_addr(addr[2]),
      .mem2_din(din[2]), .mem2_dout(dout[2]), .mem2_resp_valid(resp[2]), .mem2_be(be[2]),
      .mem2_burstcount(burst[2]),
      .mem3_valid(valid[3]), .mem3_ready(ready[3]), .mem3_write(wr[3]), .mem3_addr(addr[3]),
      .mem3_din(din[3]), .mem3_dout(dout[3]), .mem3_resp_valid(resp[3]), .mem3_be(be[3]),
      .mem3_burstcount(burst[3]),
      .sdram_dq(DQ), .sdram_a(SDRAM_A), .sdram_ba(SDRAM_BA), .sdram_dqm(SDRAM_DQM),
      .sdram_nwe(nWE), .sdram_nras(nRAS), .sdram_ncas(nCAS), .sdram_ncs(nCS), .sdram_cke(CKE)
  );

  // The AUTO REFRESH gap is held to tREFI = 64 ms / 8192 rows (the AS4C32M16SB datasheet's 8192
  // refreshes per 64 ms) on the pins; the AC checks use the -7 column (FAST_GRADE=0).
  sdram_chip_model #(.CAS(CAS), .T_RP(T_RP), .T_WR(T_WR), .FREQ_HZ(FREQ), .GRADE(7),
                     .REFRESH_INTERVAL(FREQ / 128_000)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====
  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // The MODE REGISTER SET on the pins (CS#/RAS#/CAS#/WE# all low): JEDEC SDR's mode register
  // carries the CAS latency in A[6:4]. Every MRS the controller issues must program CAS.
  integer mrs_count = 0;
  integer mrs_bad   = 0;
  always @(posedge clk) if (!nCS && !nRAS && !nCAS && !nWE) begin
    mrs_count <= mrs_count + 1;
    if (SDRAM_A[6:4] != 3'(CAS)) begin
      mrs_bad <= mrs_bad + 1;
      $display("FAIL %0d MHz: MODE REGISTER SET programs CAS latency %0d, expected CL%0d (A=%h, cyc %0d)",
               MHZ, SDRAM_A[6:4], CAS, SDRAM_A, cyc);
    end
  end

  // The software model: what each dword address holds. Every port works in its own region, so
  // a per-port program order is the whole ordering this model needs.
  reg [31:0] model [int unsigned];

  // Per-port response capture (sampled mid-cycle, at the negedge: every DUT output is a
  // register or a mux of registers on clk, so it is stable there).
  integer          beats_owed [0:3];
  integer          beats_got  [0:3];
  reg [31:0]       got_data   [0:3][0:15];
  integer          got_cyc    [0:3][0:15];
  reg [3:0]        ready_q = 4'b0;
  // `valid` as the DUT saw it at the last clk edge: the accept that a ready answers happened at
  // that edge, and the driver may already have dropped valid in the ready cycle itself.
  reg [3:0]        valid_at_edge = 4'b0;
  always @(posedge clk) valid_at_edge <= valid;
  reg [31:0]       p0_last = 32'd0;
  reg              p0_have = 1'b0;
  integer          hold_checks = 0;
  integer          ready_checks = 0;
  initial for (int p = 0; p < 4; p++) begin beats_owed[p] = 0; beats_got[p] = 0; end

  always @(negedge clk) if (!reset) begin
    for (int p = 0; p < 4; p++) begin
      // A ready answers a presented request and lasts one cycle.
      if (ready[p]) begin
        ready_checks = ready_checks + 1;
        if (!valid_at_edge[p]) begin
          errors = errors + 1;
          $display("FAIL %0d MHz: port %0d ready with no request presented (cyc %0d)", MHZ, p, cyc);
        end
        if (ready_q[p]) begin
          errors = errors + 1;
          $display("FAIL %0d MHz: port %0d ready held for two cycles (cyc %0d)", MHZ, p, cyc);
        end
      end
      // A response goes only to a port that is owed one.
      if (resp[p]) begin
        if (beats_got[p] >= beats_owed[p]) begin
          errors = errors + 1;
          $display("FAIL %0d MHz: port %0d resp_valid with no read beat owed (cyc %0d)", MHZ, p, cyc);
        end else begin
          got_data[p][beats_got[p]] = dout[p];
          got_cyc[p][beats_got[p]]  = cyc;
          beats_got[p] = beats_got[p] + 1;
        end
      end
    end
    ready_q = ready;
    // Port 0's hold: between its own pulses dout0 still reads the last port-0 word.
    if (resp[0]) begin
      p0_last = dout[0];
      p0_have = 1'b1;
    end else if (p0_have) begin
      hold_checks = hold_checks + 1;
      if (dout[0] !== p0_last) begin
        errors = errors + 1;
        if (errors < 20)
          $display("FAIL %0d MHz: dout0 moved between port-0 pulses: %08x, last port-0 word %08x (cyc %0d)",
                   MHZ, dout[0], p0_last, cyc);
      end
    end
  end

  // ==== STIMULUS ====
  // One request on port p; returns the cycle counts from the first valid cycle to the ready
  // cycle and (for a read) to the first and last response beat.
  task automatic request(input int p, input bit w, input [31:0] a, input [31:0] d,
                         input [3:0] b, input int n,
                         output int t_ready, output int t_first, output int t_last);
    int t0;
    @(negedge clk);
    valid[p] = 1'b1; wr[p] = w; addr[p] = a; din[p] = d; be[p] = b; burst[p] = 8'(n);
    beats_got[p] = 0;
    beats_owed[p] = w ? 0 : n;
    t0 = cyc;
    // ready is sampled mid-cycle; the cycle it is seen in is the ready cycle.
    forever begin
      @(negedge clk);
      if (ready[p]) break;
    end
    t_ready = cyc - t0;
    valid[p] = 1'b0;
    if (w) begin
      for (int i = 0; i < 4; i++)
        if (b[i]) begin
          reg [31:0] m;
          m = model.exists(a >> 2) ? model[a >> 2] : 32'd0;
          m[i*8 +: 8] = d[i*8 +: 8];
          model[a >> 2] = m;
        end
      t_first = 0; t_last = 0;
    end else begin
      int guard = 0;
      while (beats_got[p] < n) begin
        @(negedge clk);
        guard++;
        if (guard > 4000) begin
          errors = errors + 1;
          $display("FAIL %0d MHz: port %0d read of %0d beats got %0d", MHZ, p, n, beats_got[p]);
          break;
        end
      end
      t_first = got_cyc[p][0] - t0;
      t_last  = got_cyc[p][n-1] - t0;
      for (int i = 0; i < n; i++) begin
        reg [31:0] want;
        want = model.exists((a >> 2) + i) ? model[(a >> 2) + i] : 32'hXXXX_XXXX;
        if (got_data[p][i] !== want) begin
          errors = errors + 1;
          $display("FAIL %0d MHz: port %0d read %08x beat %0d = %08x, want %08x",
                   MHZ, p, a + 4*i, i, got_data[p][i], want);
        end
      end
    end
  endtask

  // The measurements, filled by run(): sums over N_LAT samples, and the minimum.
  localparam integer N_LAT = 8;
  localparam integer IDLE_GAP = 40;    // clk_sys; > any transaction's tail at these clocks
  integer w1_rdy_sum = 0, w1_rdy_min = 1 << 30;
  integer r1_sum = 0,     r1_min = 1 << 30;
  integer r4_first_sum = 0, r4_last_sum = 0, r4_last_min = 1 << 30;
  integer b1_rdy_sum = 0;
  integer wstream_cycles = 0, rstream_cycles = 0, bstream_cycles = 0;
  localparam integer N_WSTREAM = 64, N_RSTREAM = 32, N_BSTREAM = 64;
  integer served [0:3];
  bit done = 1'b0;

  function automatic [31:0] lfsr(input [31:0] x);
    lfsr = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
  endfunction

  // A port's contention program: its own region, a mix of the shapes that port carries.
  task automatic port_program(input int p, input int nops);
    int tr, tf, tl;
    reg [31:0] seed;
    reg [31:0] base;
    seed = 32'h1357_9BDF ^ (p * 32'h0101_0101);
    base = 32'h0040_0000 + p * 32'h0008_0000;     // 512 KiB apart: distinct rows and banks
    // Seed the region the reads will cover.
    for (int i = 0; i < 64; i++) begin
      seed = lfsr(seed);
      request(p, 1'b1, base + 4*i, seed, 4'hF, 1, tr, tf, tl);
    end
    for (int k = 0; k < nops; k++) begin
      reg [31:0] off;
      seed = lfsr(seed);
      off = {seed[5:0], 2'b00} & 32'h0000_00C0;     // a 16-dword-aligned start inside the region
      case (p)
        0: case (seed[9:8])
             2'd0: request(0, 1'b0, base + {seed[7:2], 2'b00}, 0, 4'hF, 1, tr, tf, tl);
             2'd1: request(0, 1'b0, base + (off & 32'hF0), 0, 4'hF, 4, tr, tf, tl);
             2'd2: request(0, 1'b1, base + {seed[7:2], 2'b00}, lfsr(seed), 4'hF, 1, tr, tf, tl);
             2'd3: request(0, 1'b1, base + {seed[7:2], 2'b00}, lfsr(seed), 4'b0001 << seed[11:10], 1, tr, tf, tl);
           endcase
        1: request(1, 1'b0, base + (off & 32'hE0), 0, 4'hF, 8, tr, tf, tl);       // a glyph block
        2: request(2, seed[8], base + {seed[7:2], 2'b00}, lfsr(seed), 4'hF, 1, tr, tf, tl);   // PCM
        3: request(3, 1'b0, base + {2'b00, seed[7:2], 2'b00} % 32'hD8, 0, 4'hF, 10, tr, tf, tl);  // packed line
      endcase
      served[p] = served[p] + 1;
      repeat (seed[13:12]) @(negedge clk);
    end
  endtask

  task automatic run();
    int tr, tf, tl, t0;
    for (int p = 0; p < 4; p++) served[p] = 0;
    repeat (8) @(negedge clk);
    reset = 1'b0;
    // The controller's own power-up hold (200 us at FREQ) ends with busy low.
    wait (!busy);
    repeat (20) @(negedge clk);

    // ---- latency, port 0 alone, from IDLE: each sample on its own row, after a gap long enough
    // for the previous transaction (and its write recovery) to have left the controller, so the
    // number is the request's own round trip and not the tail of the one before it ----
    for (int s = 0; s < N_LAT; s++) begin
      reg [31:0] a;
      a = 32'h0010_0000 + s * 32'h0000_4000;        // a new 16 KiB step: a new row each time
      for (int i = 0; i < 4; i++) request(0, 1'b1, a + 4*i, 32'h5A5A_0000 + s*16 + i, 4'hF, 1, tr, tf, tl);
      repeat (IDLE_GAP) @(negedge clk);
      request(0, 1'b1, a + 32'h10, 32'hA5A5_0000 + s, 4'hF, 1, tr, tf, tl);
      w1_rdy_sum += tr; if (tr < w1_rdy_min) w1_rdy_min = tr;
      repeat (IDLE_GAP) @(negedge clk);
      request(0, 1'b0, a, 0, 4'hF, 1, tr, tf, tl);
      r1_sum += tf; if (tf < r1_min) r1_min = tf;
      repeat (IDLE_GAP) @(negedge clk);
      request(0, 1'b0, a, 0, 4'hF, 4, tr, tf, tl);
      r4_first_sum += tf; r4_last_sum += tl; if (tl < r4_last_min) r4_last_min = tl;
      repeat (IDLE_GAP) @(negedge clk);
      request(0, 1'b1, a + 1, 32'h0000_C300, 4'b0010, 1, tr, tf, tl);
      b1_rdy_sum += tr;
      repeat (IDLE_GAP) @(negedge clk);
    end

    // ---- the posted-store stream: back-to-back single dwords, as the store buffer drains ----
    t0 = cyc;
    for (int i = 0; i < N_WSTREAM; i++)
      request(0, 1'b1, 32'h0020_0000 + 4*i, 32'hC0DE_0000 + i, 4'hF, 1, tr, tf, tl);
    wstream_cycles = cyc - t0;
    // ---- the line-fill stream: back-to-back 4-dword reads of what was just stored ----
    t0 = cyc;
    for (int i = 0; i < N_RSTREAM; i++)
      request(0, 1'b0, 32'h0020_0000 + 16*(i % (N_WSTREAM/4)), 0, 4'hF, 4, tr, tf, tl);
    rstream_cycles = cyc - t0;
    // ---- the byte-store stream (a DMA byte, one lane at a time) ----
    t0 = cyc;
    for (int i = 0; i < N_BSTREAM; i++)
      request(0, 1'b1, 32'h0030_0000 + i, 32'(i) << (8 * (i % 4)), 4'b0001 << (i % 4), 1, tr, tf, tl);
    bstream_cycles = cyc - t0;
    for (int i = 0; i < N_BSTREAM / 4; i++)
      request(0, 1'b0, 32'h0030_0000 + 4*i, 0, 4'hF, 1, tr, tf, tl);

    // ---- contention: all four ports at once ----
    fork
      port_program(0, 120);
      port_program(1, 40);
      port_program(2, 80);
      port_program(3, 40);
    join
    done = 1'b1;
  endtask

  task automatic report(input string name);
    real ns;
    ns = SYS_NS;
    $display("MEASURE %-18s single-dword write  valid->ready  avg %5.2f clk (min %0d) = %6.1f ns",
             name, w1_rdy_sum * 1.0 / N_LAT, w1_rdy_min, w1_rdy_sum * ns / N_LAT);
    $display("MEASURE %-18s single-dword read   valid->data   avg %5.2f clk (min %0d) = %6.1f ns",
             name, r1_sum * 1.0 / N_LAT, r1_min, r1_sum * ns / N_LAT);
    $display("MEASURE %-18s 4-dword line fill   valid->first  avg %5.2f clk = %6.1f ns; valid->last avg %5.2f clk (min %0d) = %6.1f ns",
             name, r4_first_sum * 1.0 / N_LAT, r4_first_sum * ns / N_LAT,
             r4_last_sum * 1.0 / N_LAT, r4_last_min, r4_last_sum * ns / N_LAT);
    $display("MEASURE %-18s byte store          valid->ready  avg %5.2f clk = %6.1f ns",
             name, b1_rdy_sum * 1.0 / N_LAT, b1_rdy_sum * ns / N_LAT);
    $display("MEASURE %-18s store stream  %0d dwords in %0d clk = %5.2f clk/dword = %6.1f ns/dword = %6.2f MB/s",
             name, N_WSTREAM, wstream_cycles, wstream_cycles * 1.0 / N_WSTREAM,
             wstream_cycles * ns / N_WSTREAM, (N_WSTREAM * 4.0) / (wstream_cycles * ns) * 1000.0);
    $display("MEASURE %-18s line stream   %0d lines in %0d clk = %5.2f clk/line = %6.1f ns/line = %6.2f MB/s",
             name, N_RSTREAM, rstream_cycles, rstream_cycles * 1.0 / N_RSTREAM,
             rstream_cycles * ns / N_RSTREAM, (N_RSTREAM * 16.0) / (rstream_cycles * ns) * 1000.0);
    $display("MEASURE %-18s byte stream   %0d bytes in %0d clk = %5.2f clk/byte = %6.1f ns/byte",
             name, N_BSTREAM, bstream_cycles, bstream_cycles * 1.0 / N_BSTREAM,
             bstream_cycles * ns / N_BSTREAM);
    $display("MEASURE %-18s contention served p0..p3 = %0d %0d %0d %0d; %0d ready checks, %0d dout0 hold checks, %0d error(s)",
             name, served[0], served[1], served[2], served[3], ready_checks, hold_checks, errors);
    $display("MEASURE %-18s mode register: %0d MRS seen, expected CL%0d, %0d programmed another latency",
             name, mrs_count, CAS, mrs_bad);
  endtask
endmodule

module tb_pc9821_sdram_sync;
  // One harness per preset clock (build_profile.py): base/trace 90,
  // mediumoc 100, heavyoc 120; 95 MHz, the fastest clock that keeps CL2 (the CAS cutover's
  // other side); and 50 MHz, the clock the other bridge benches run.
  reg clk90 = 1'b0, clk95 = 1'b0, clk100 = 1'b0, clk120 = 1'b0, clk50 = 1'b0;
  always #(1000.0 / 90 / 2.0)   clk90  = ~clk90;
  always #(1000.0 / 95 / 2.0)   clk95  = ~clk95;
  always #(10.0 / 2.0)          clk100 = ~clk100;
  always #(1000.0 / 120 / 2.0)  clk120 = ~clk120;
  always #(20.0 / 2.0)          clk50  = ~clk50;

  // ==== DUT ====
  tb_pc9821_sdram_sync_harness #(.FREQ(90_000_000),  .SYS_NS(1000.0 / 90))  h90  (.clk(clk90));
  tb_pc9821_sdram_sync_harness #(.FREQ(95_000_000),  .SYS_NS(1000.0 / 95))  h95  (.clk(clk95));
  tb_pc9821_sdram_sync_harness #(.FREQ(100_000_000), .SYS_NS(10.0))         h100 (.clk(clk100));
  tb_pc9821_sdram_sync_harness #(.FREQ(120_000_000), .SYS_NS(1000.0 / 120)) h120 (.clk(clk120));
  tb_pc9821_sdram_sync_harness #(.FREQ(50_000_000),  .SYS_NS(20.0))         h50  (.clk(clk50));

  // ==== CHECKS ====
  // Each harness checks its own contract and data; the verdict needs all five clean, all five to
  // have finished the whole program, the contention phase to have served every port in each, and
  // each controller to have issued at least one MRS, every one programming the expected CL.
  initial begin
    #(20.0 * 4_000_000);
    $fatal(1, "TB_PC9821_SDRAM_SYNC: watchdog - the program did not finish (done 90=%0d 95=%0d 100=%0d 120=%0d 50=%0d)",
           h90.done, h95.done, h100.done, h120.done, h50.done);
  end

  function automatic bit clean(input integer errors, input bit done, input integer hold_checks,
                               input integer s0, input integer s1, input integer s2,
                               input integer s3, input integer mrs_count, input integer mrs_bad);
    clean = errors == 0 && done && hold_checks > 1000 &&
            s0 == 120 && s1 == 40 && s2 == 80 && s3 == 40 &&
            mrs_count >= 1 && mrs_bad == 0;
  endfunction

  // ==== VERDICT ====
  initial begin
    $display("TB_PC9821_SDRAM_SYNC: the controller on clk_sys at 90, 95, 100, 120 and 50 MHz");
    fork
      h90.run();
      h95.run();
      h100.run();
      h120.run();
      h50.run();
    join
    h90.report("90/90 (base)");
    h95.report("95/95 (CL2 top)");
    h100.report("100/100 (mediumoc)");
    h120.report("120/120 (heavyoc)");
    h50.report("50/50");
    if (clean(h90.errors,  h90.done,  h90.hold_checks,  h90.served[0],  h90.served[1],  h90.served[2],  h90.served[3],  h90.mrs_count,  h90.mrs_bad) &&
        clean(h95.errors,  h95.done,  h95.hold_checks,  h95.served[0],  h95.served[1],  h95.served[2],  h95.served[3],  h95.mrs_count,  h95.mrs_bad) &&
        clean(h100.errors, h100.done, h100.hold_checks, h100.served[0], h100.served[1], h100.served[2], h100.served[3], h100.mrs_count, h100.mrs_bad) &&
        clean(h120.errors, h120.done, h120.hold_checks, h120.served[0], h120.served[1], h120.served[2], h120.served[3], h120.mrs_count, h120.mrs_bad) &&
        clean(h50.errors,  h50.done,  h50.hold_checks,  h50.served[0],  h50.served[1],  h50.served[2],  h50.served[3],  h50.mrs_count,  h50.mrs_bad)) begin
      $display("TB_PC9821_SDRAM_SYNC: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_SDRAM_SYNC: FAIL (errors 90=%0d 95=%0d 100=%0d 120=%0d 50=%0d; MRS bad %0d/%0d/%0d/%0d/%0d; hold checks %0d/%0d/%0d/%0d/%0d)",
             h90.errors, h95.errors, h100.errors, h120.errors, h50.errors,
             h90.mrs_bad, h95.mrs_bad, h100.mrs_bad, h120.mrs_bad, h50.mrs_bad,
             h90.hold_checks, h95.hold_checks, h100.hold_checks, h120.hold_checks, h50.hold_checks);
    end
  end
endmodule
