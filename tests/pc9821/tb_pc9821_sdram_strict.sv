`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_STRICT:
// The platform's SDRAM controller, at the platform's OWN settings (ADQM=1 so the byte mask rides A11/A12, FAST_GRADE=0, a 128 MB module and GATHER_K=4), at EVERY preset clock - 90 MHz CL2 (base, the shipping build), 100 MHz CL3 (mediumoc) and 120 MHz CL3 (heavyoc) - and at 50 MHz CL2 (the integrated boot tier's clock, where tWR is one clock and a store's tDAL three), one rig per clock running the same program, the 90 MHz one with the module size arriving from the HPS only after the controller's power-up init has finished (so the second chip must have been initialised without it) - is driven against the MiSTer community's STRICT XSDS module model set to the -7 speed grade (the slowest part of the supported set, AS4C32M16SB datasheet Rev 1.4 Table 16: tRCD/tRP 21, tRC/tRFC 63, tRRD/tMRD/tWR 14, tRAS 42 ns), with CKE tied to VCC and DQML/DQMH strapped to A11/A12, and the MODULE ITSELF is the judge: every command it sees is decoded against the CONTROLLER_GUIDE's protocol and AC-timing rules plus the model's local checks (tMRD to any command, tRAS for both auto-precharge forms with no tRAS lockout, tRP before AUTO REFRESH), every AUTO REFRESH is recorded per chip, and a single violation anywhere in the run fails this bench through the model's own error count rather than through anything this bench believes. The traffic is a real one: the power-up hold the model requires, a dword write/read-back walk across BOTH chips and across rows and banks, byte-masked writes (the mask-on-address path the XSDS board forces), a burst read spanning a row boundary, a port-0 gather session, a store and a gather session whose byte enables are all 0 (each must write nothing and still close its row before the next ACT to that bank), and bursts across the 64 MB chip boundary (a 4-dword and a 15-dword read and a two-word write that start in chip 0's last row and continue in chip 1's first, every word checked against single-dword writes and against distinct data at chip 0's first row, so a second segment on the wrong chip select reads or writes the wrong word). The module is clocked the MiSTer way - by the forwarded SDRAM_CLK, lagging the controller clock by the pin-clock lead the configuration's STA I/O model implies, with read data returning through the FPGA's I/O path - so the controller's DQ capture register samples the module where the fit's STA places that capture, about 1 ns before the module's CAS-latency edge. Each chip's AUTO REFRESH commands, read off the module's own pins (RAS#/CAS#/WE# = 0/0/1, the chip by Cs1_n), arrive at least twice in the run and never more than 64 ms / 8192 = 7812.5 ns apart (nor that long before the run ends; on the late-size rig chip 1 is counted from the moment the size names it, since nothing can address it before), since the model only warns on tREFI.
//
// WHY. Three benches already check THIS controller, and all three check it against our own
// understanding of it (tb_pc9821_sdram_act, _preact, _gather_map). The community model is an
// independent authority derived from the official schematic and the AS4C32M16SB datasheet, and
// its CONTROLLER_GUIDE states the rules a controller must follow - including two this platform
// has never been able to test: that BOTH chips must be refreshed independently (8192 AUTO
// REFRESH per chip per 64 ms) and that CS1_n selects a chip rather than deselecting the module.
// The strict model flags a violation as $error and counts it, so "we pass it" is evidence and
// not an opinion.
//
// THE SPEED GRADE. The XSDS board carries -6 parts, but a module with -7 parts is in the supported
// set (docs/sdram.md) and its limits are the slower ones, so the model runs at the -7 column
// (xsds_128mbyte_sdram_model.sv LOCAL FIX 4); a controller that meets -7 meets -6 on every rule
// the model checks.
//
// SCOPE: this is the CONTROLLER's contract, not the core's. Nothing here says the platform
// drives the controller correctly - only that what the controller puts on the pins is legal.
//
// FAIL-FIRST BY CONSTRUCTION: the model is instantiated with STRICT_TIMING=1, so a protocol or
// timing violation during the walk sets its error count and the verdict below fails.

`default_nettype none

// One controller at one clock, its module model and the program. The top instantiates one per
// preset clock and runs the same program on each.
module tb_pc9821_sdram_strict_rig #(
  parameter  integer FREQ   = 90_000_000,
  // 1: sdram_size reads 0 (no report yet) until the controller has finished its power-up init,
  // then 3 - the HPS's UIO report (sys/hps_io.sv's sdram_sz) arriving after the controller's
  // 200 us, which nothing in Main_MiSTer's start-up order rules out.
  parameter  bit     SIZE_LATE = 1'b0
);
  // The platform's deployed settings (z486_mister.sv): the controller on clk_sys at FREQ, and the
  // XSDS board's wiring.
  //
  // HISTORY: this bench
  // was red at every clock because the community model mis-modelled READs, not because the
  // controller was wrong - it restarted its CAS-latency count on every READ (dropping the first of
  // the controller's two back-to-back BL=1 READs per dword), launched read data one clock late,
  // and forced the bus Hi-Z at the edge the previous beat is captured on. Those are LOCAL FIXes in
  // tests/pc9821/xsds_128mbyte_sdram_model.sv, pinned by tb_pc9821_xsds_readpipe. The gather
  // check's own stimulus also had a typo (0x1100 for "byte 0 = 0x11"): fixed to 0x0011.
  localparam real    TCK_NS = 1e9 / FREQ;        // 11.1 ns at 90 MHz
  localparam integer POWERUP_CYCLES = (FREQ / 1_000_000) * 230;   // 230 us > the model's 200 us

  reg clk = 1'b0;
  always #(TCK_NS / 2.0) clk = ~clk;

  // ==== THE BOARD: the MiSTer pin clock and the FPGA's I/O path ====
  // On MiSTer the module is NOT clocked by the controller's clock: SDRAM_CLK is a forwarded,
  // phase-shifted copy (here a PLL output at tools/profile_gen.py's derived phase; Template
  // cores use an altddio_out at 180 degrees, Genesis_MiSTer's
  // rtl/sdram.sv:248-249), and the read data comes back to the controller's IOE input register
  // (dq_r, FAST_INPUT_REGISTER, sys/sys.tcl:97) through the pad and input path. So this bench
  // gives the module its own clock and a read-return delay, with the controller unchanged:
  //   * PIN_LEAD  - the module's clock edge lags the controller edge that launched the command
  //     or write data by this much (the FPGA's output path folded in: only the lead between
  //     the pin change and the module's edge is visible to the module's tIS/tIH/tDS/tDH);
  //   * DQ_RETURN - the module's DQ reaches dq_r this much later.
  // Both come from the configuration's STA I/O model (tools/profile_gen.py IO_MODEL at the
  // derived phase, all four corners), NOT from the controller: PIN_LEAD is the centre of the
  // command window [tIS + min out_setup, T - tIH - min out_hold], and DQ_RETURN places the
  // dq_r sample at the centre of the read window [tAC - T + min in_setup, tOH - min in_hold]
  // relative to the module's CAS-latency edge (-0.961 ns; the window is -4.18..+2.25 ns below
  // ~95 MHz). Below ~95 MHz
  // the lead is T - 3.743 ns and the return a constant 4.704 ns. A negative PIN_LEAD_PS means "derive".
  // The board's own trace delay is not characterised (z486_mister.sdc's "Board skew is not yet
  // characterized"), exactly as in the STA model the values come from.
  parameter  integer PIN_LEAD_PS  = -1;
  parameter  integer DQ_RETURN_PS = 4704;
  localparam real    PIN_LEAD_NS  = (PIN_LEAD_PS >= 0)      ? PIN_LEAD_PS / 1000.0
                                  : (FREQ == 120_000_000)   ? 3.546
                                  : (FREQ == 100_000_000)   ? 6.046
                                  :                           TCK_NS - 3.743;
  localparam real    DQ_RETURN_NS = DQ_RETURN_PS / 1000.0;

  // The module's clock: SDRAM_CLK at the module, clk shifted by PIN_LEAD. Generated, not
  // delayed, because Verilator evaluates an intra-assignment delay's right-hand side when the
  // delay EXPIRES (measured: `b <= #11.7 a` lands the later value of a), so `<= #lead clk`
  // with a lead over half a period would not be a delayed clock at all.
  reg sdram_clk = 1'b0;
  initial begin
    #(PIN_LEAD_NS);
    forever #(TCK_NS / 2.0) sdram_clk = ~sdram_clk;
  end

  reg resetn          = 1'b0;
  reg nce             = 1'b0;
  reg refresh_allowed = 1'b1;
  reg  [1:0] sdram_size = SIZE_LATE ? 2'd0 : 2'd3;   // 128 MB (SIZE_LATE: after the init)
  wire busy;

  wire [15:0] SDRAM_DQ;      // the controller's pins
  wire [15:0] MODULE_DQ;     // the module's pins (THE BOARD, below)
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_DQM;
  wire  [1:0] SDRAM_BA;
  wire        SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;
  wire        SDRAM_nCS;

  integer errors = 0;
  integer checks = 0;
  bit     done   = 1'b0;

  // ==== DUT ====
  reg         valid0 = 1'b0;
  wire        ready0;
  reg         wr0    = 1'b0;
  reg  [26:0] addr0  = 27'd0;
  reg  [31:0] din0   = 32'd0;
  reg  [31:0] din0_hi = 32'd0;
  reg         gath0  = 1'b0;
  reg [440:0] gath0_extra = 441'd0;
  wire [31:0] dout0;
  wire        resp_valid0, burst_done0;
  reg   [3:0] be0 = 4'hF;
  reg   [3:0] burst_cnt0 = 4'd1;

  // Ports 1..3: mem1 the font/glyph reader, mem2 the 86-PCM buffer, mem3 idle in this machine
  // (the GVRAM scanout moved to M10K). They exist here so CONTENTION can be generated: every
  // claim this controller makes about fairness, about the refresh margin ("an accepted burst
  // cannot be interrupted") and about the pre-ACT reservation is a claim about what happens
  // when four requesters fight, and a single-requester bench cannot reach any of them.
  reg         valid1 = 1'b0, valid2 = 1'b0, valid3 = 1'b0;
  wire        ready1, ready2, ready3;
  reg         wr1 = 1'b0, wr2 = 1'b0, wr3 = 1'b0;
  reg  [26:0] addr1 = 27'd0, addr2 = 27'd0, addr3 = 27'd0;
  reg  [31:0] din1 = 32'd0, din2 = 32'd0, din3 = 32'd0;
  wire [31:0] dout1, dout2, dout3;
  reg   [3:0] be1 = 4'hF, be2 = 4'hF, be3 = 4'hF;
  wire        resp_valid1, resp_valid2, resp_valid3;
  reg   [3:0] burst_cnt1 = 4'd1, burst_cnt2 = 4'd1, burst_cnt3 = 4'd1;
  wire        burst_done1, burst_done2, burst_done3;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] dq_cap_seen = dut.g_dq_ddio.dq_cap_h;   // the DDIO branch is the one built
  wire  [2:0] cmd_cell_seen = dut.g_out_ddio.cmd_cell; // and so is the output-cell branch
  /* verilator lint_on UNUSEDSIGNAL */

  sdram #(
      // The platform's parameters, verbatim from z486_mister.sv.
      .FREQ(FREQ), .ADQM(1'b1), .FAST_GRADE(1'b0),
      .GATHER_K(4),
      // The DQ capture cell every preset builds (build_profile.py sdram_dq_ddio, SDRAM_DQ_DDIO).
      // The reference below to the selected branch's register fails elaboration if it is not.
      .DQ_IN_DDIO(1'b1),
      // The output-register cells every preset builds (build_profile.py sdram_out_ddio,
      // SDRAM_OUT_DDIO): the pins this bench's strict module model checks are the cells' values.
      .OUT_DDIO(1'b1)
  ) dut (
      .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
      .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
      .SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE),
      .clk(clk), .resetn(resetn), .nce(nce), .refresh_allowed(refresh_allowed), .busy(busy),
      .sdram_size(sdram_size),
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0), .din0(din0),
      .din0_hi(din0_hi), .gath0(gath0), .gath0_extra(gath0_extra),
      .dout0(dout0), .be0(be0), .resp_valid0(resp_valid0),
      .burst_cnt0(burst_cnt0), .burst_done0(burst_done0),
      .valid1(valid1), .ready1(ready1), .wr1(wr1), .addr1(addr1), .din1(din1), .dout1(dout1),
      .be1(be1), .resp_valid1(resp_valid1), .burst_cnt1(burst_cnt1), .burst_done1(burst_done1),
      .valid2(valid2), .ready2(ready2), .wr2(wr2), .addr2(addr2), .din2(din2), .dout2(dout2),
      .be2(be2), .resp_valid2(resp_valid2), .burst_cnt2(burst_cnt2), .burst_done2(burst_done2),
      .valid3(valid3), .ready3(ready3), .wr3(wr3), .addr3(addr3), .din3(din3), .dout3(dout3),
      .be3(be3), .resp_valid3(resp_valid3), .burst_cnt3(burst_cnt3), .burst_done3(burst_done3)
  );

  // ==== EACH CHIP'S REFRESH, read off the module's own pins ====
  // The model only WARNS on a long AUTO REFRESH interval (record_refresh's tREFI check is an
  // issue_warn, not counted in module_error_count) and its 8192-in-64-ms window check needs a
  // 64 ms run, so neither can fail this bench: a controller that refreshed one chip only, or at
  // half the rate, passed (mutants "chip 1 never refreshed" and
  // "refresh interval doubled"). The requirement itself is the model header's "Each chip
  // independently requires 8192 AUTO REFRESH commands per 64 ms" (xsds_128mbyte_sdram_model.sv
  // :35, the AS4C32M16SB datasheet's 64 ms / 8192 rows); this controller distributes them one
  // per interval, so per chip no two consecutive AUTO REFRESHes - and no refresh and the end of
  // the run - may be further apart than 64 ms / 8192 = 7812.5 ns, which is sufficient for every
  // 64 ms window. AUTO REFRESH is {RAS#, CAS#, WE#} = 0,0,1 on the module clock; Cs1_n picks the
  // chip (Cs1_n=0 chip 0, =1 chip 1, header :28-29).
  localparam real T_REF_INTERVAL_NS = 64_000_000.0 / 8192.0;
  realtime ref_last [0:1];
  realtime ref_maxgap [0:1];
  integer  ref_count [0:1];
  initial begin
    ref_count[0] = 0; ref_count[1] = 0;
    ref_maxgap[0] = 0.0; ref_maxgap[1] = 0.0;
  end
  always @(posedge sdram_clk)
    if (!SDRAM_nRAS && !SDRAM_nCAS && SDRAM_nWE) begin
      if (ref_count[SDRAM_nCS] != 0 && ($realtime - ref_last[SDRAM_nCS]) > ref_maxgap[SDRAM_nCS])
        ref_maxgap[SDRAM_nCS] = $realtime - ref_last[SDRAM_nCS];
      ref_last[SDRAM_nCS] = $realtime;
      ref_count[SDRAM_nCS] = ref_count[SDRAM_nCS] + 1;
    end

  // ==== THE JUDGE: the community's strict XSDS model ====
  // Its ports are the connector's: there is no DQM port because the board straps DQML/DQMH to
  // A11/A12, which the model extracts itself -- so our SDRAM_DQM output is deliberately unused.
  xsds_128mbyte_sdram_model #(
      .DEBUG(1'b0), .STRICT_TIMING(1'b1), .WARN_TREFI(1'b1), .INIT_UNWRITTEN_TO_X(1'b0),
      .GRADE(7)
  ) model (
      .Clk(sdram_clk), .Cs1_n(SDRAM_nCS), .Ras_n(SDRAM_nRAS), .Cas_n(SDRAM_nCAS), .We_n(SDRAM_nWE),
      .Ba(SDRAM_BA), .Addr(SDRAM_A), .Dq(MODULE_DQ)
  );

  // The DQ bus, split at the board: MODULE_DQ is the module's pins, SDRAM_DQ the controller's.
  // Write data goes out undelayed (its output path is inside PIN_LEAD, like the commands');
  // what the module drives comes back DQ_RETURN later. The return is gated by the controller's
  // own output enable only so the two sides never resolve two drivers on one Verilator net.
  assign MODULE_DQ = dut.dq_oen ? 16'hzzzz : dut.dq_out;
  // The return is a TRANSPORT delay (every change, in order, DQ_RETURN later): a queue of
  // timestamped samples, for the same Verilator reason as the clock above.
  wire        module_oe = model.u_chip0.dq_oe | model.u_chip1.dq_oe;
  reg  [15:0] ret_dq = 16'h0000;
  reg         ret_oe = 1'b0;
  typedef struct { realtime t; logic [15:0] v; logic oe; } dq_ev_t;
  dq_ev_t dq_line [$];
  always @(MODULE_DQ or module_oe) dq_line.push_back('{$realtime + DQ_RETURN_NS, MODULE_DQ, module_oe});
  initial forever begin
    wait (dq_line.size() != 0);
    if (dq_line[0].t > $realtime) #(dq_line[0].t - $realtime);
    ret_dq = dq_line[0].v;
    ret_oe = dq_line[0].oe;
    void'(dq_line.pop_front());
  end
  assign SDRAM_DQ = (ret_oe && dut.dq_oen) ? ret_dq : 16'hzzzz;

  // ==== STIMULUS ====
  task automatic settle(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(negedge clk);
    end
  endtask

  // One port-0 transaction. A write is accepted and done; a read waits for its words.
  task automatic wr_dword(input [26:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      @(negedge clk);
      addr0 = a; din0 = d; be0 = be; wr0 = 1'b1; burst_cnt0 = 4'd1; gath0 = 1'b0;
      valid0 = 1'b1;
      g = 0;
      while (!ready0 && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_STRICT: no accept for the write at %07x (%0d MHz)", a, FREQ / 1_000_000);
      @(negedge clk);
      valid0 = 1'b0; wr0 = 1'b0;
      settle(8);
    end
  endtask

  // Port 0's two-word write (burst_cnt == 2: din0, then din0_hi at the next dword).
  task automatic wr_pair(input [26:0] a, input [31:0] d0, input [31:0] d1);
    integer g;
    begin
      @(negedge clk);
      addr0 = a; din0 = d0; din0_hi = d1; be0 = 4'hF; wr0 = 1'b1; burst_cnt0 = 4'd2; gath0 = 1'b0;
      valid0 = 1'b1;
      g = 0;
      while (!ready0 && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_STRICT: no accept for the pair at %07x (%0d MHz)", a, FREQ / 1_000_000);
      @(negedge clk);
      valid0 = 1'b0; wr0 = 1'b0; burst_cnt0 = 4'd1;
      settle(12);
    end
  endtask

  // A port-0 read of n dwords; the words land in rbuf[0..n-1].
  reg [31:0] rbuf [0:15];
  task automatic rd_burst(input [26:0] a, input [3:0] n);
    integer g;
    integer got;
    begin
      @(negedge clk);
      addr0 = a; be0 = 4'hF; wr0 = 1'b0; burst_cnt0 = n; gath0 = 1'b0;
      valid0 = 1'b1;
      g = 0;
      while (!ready0 && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_STRICT: no accept for the read at %07x (%0d MHz)", a, FREQ / 1_000_000);
      @(negedge clk);
      valid0 = 1'b0;
      got = 0;
      for (g = 0; g < 16; g = g + 1) rbuf[g] = 32'h0;
      g = 0;
      while ((got < n) && (g < 8000)) begin
        @(negedge clk);
        if (resp_valid0) begin
          rbuf[got] = dout0;
          got = got + 1;
        end
        g = g + 1;
      end
      if (got < n)
        $fatal(1, "TB_PC9821_SDRAM_STRICT: read of %0d word(s) at %07x returned only %0d (%0d MHz)", n, a, got, FREQ / 1_000_000);
      g = 0;
      while (!burst_done0 && g < 8000) begin @(negedge clk); g = g + 1; end
      settle(4);
    end
  endtask

  task automatic rd_dwords(input [26:0] a, input [3:0] n, output [31:0] w0, output [31:0] w1);
    begin
      rd_burst(a, n);
      w0 = rbuf[0];
      w1 = rbuf[1];
    end
  endtask

  task automatic chk32(input [31:0] got, input [31:0] want, input [8*100-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s (%0d MHz): got %08x, want %08x", tag, FREQ / 1_000_000, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // A port-0 gather session: up to GATHER_K same-row partial stores under one ACT. Entry 0
  // rides addr0/din0/be0 and entries 1.. ride gath0_extra as {addr[26:0], din[31:0], be[3:0]}.
  localparam integer GENT_W = 27 + 32 + 4;
  task automatic gather_write(input [26:0] a, input [31:0] d0, input [3:0] be_a,
                              input [31:0] d1, input [3:0] be_b);
    integer g;
    begin
      @(negedge clk);
      addr0 = a; din0 = d0; be0 = be_a;
      gath0_extra = 441'd0;
      gath0_extra[0 +: GENT_W] = {a + 27'd4, d1, be_b};    // one entry up, same row
      wr0 = 1'b1; burst_cnt0 = 4'd2; gath0 = 1'b1;
      valid0 = 1'b1;
      g = 0;
      while (!ready0 && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_STRICT: no accept for the gather at %07x (%0d MHz)", a, FREQ / 1_000_000);
      @(negedge clk);
      valid0 = 1'b0; wr0 = 1'b0; gath0 = 1'b0;
      settle(40);                                            // the session drains
    end
  endtask

  reg [31:0] r0, r1;
  integer i;
  integer g;

  // ==== CHECKS ====
  task automatic run();
    begin
    // The model's own power-up rule: hold everything in NOP for > 200 us before letting the
    // controller start its init sequence.
    settle(POWERUP_CYCLES);
    resetn = 1'b1;
    // The controller's OWN power-up hold is 200 us counted AFTER resetn rises (rst_cnt), on top
    // of the 200 us this bench already held it in reset, so the first command reaches the model
    // well past its 200 us requirement.
    settle(POWERUP_CYCLES + 4000);
    g = 0;
    while (busy && g < 100_000) begin @(negedge clk); g = g + 1; end
    if (busy) $fatal(1, "TB_PC9821_SDRAM_STRICT: the controller never left its power-up init (%0d MHz)", FREQ / 1_000_000);
    if (SIZE_LATE) begin
      settle(50);
      sdram_size = 2'd3;                   // the module size arrives now
      // Chip 1's refresh account starts here: before the report the controller refreshes the
      // module it was told of (one chip), and nothing can address chip 1 either. From now on
      // its first refresh is due within tREFI like every later one.
      ref_count[1] = 1; ref_maxgap[1] = 0.0; ref_last[1] = $realtime;
      settle(4);
    end

    // ---- a dword write/read-back walk: both chips, several banks, a row-crossing burst ----
    // chip 0: 16 addresses across banks; chip 1: the same offsets above the 64 MB boundary
    // (cs1_n is the high chip bit, so an address with bit 26 set is a different chip).
    for (i = 0; i < 16; i = i + 1) begin
      wr_dword(27'(27'h000_1000 + (i * 27'h0100)), 32'hA5A5_0000 + i, 4'hF);
      rd_dwords(27'(27'h000_1000 + (i * 27'h0100)), 4'd1, r0, r1);
      chk32(r0, 32'hA5A5_0000 + i, "chip 0 dword walk");
    end
    for (i = 0; i < 16; i = i + 1) begin
      wr_dword(27'(27'h400_1000 + (i * 27'h0100)), 32'h5A5A_0000 + i, 4'hF);
      rd_dwords(27'(27'h400_1000 + (i * 27'h0100)), 4'd1, r0, r1);
      chk32(r0, 32'h5A5A_0000 + i, "chip 1 dword walk");
    end

    // ---- byte-masked writes: the mask rides A11/A12 on this board, so a masked write is the
    //      path with the most to get wrong. Write a full dword, then overwrite ONE byte of it
    //      and require the other three intact.
    wr_dword(27'h000_8000, 32'h1122_3344, 4'hF);
    wr_dword(27'h000_8000, 32'h0000_AA00, 4'b0010);          // byte lane 1 only
    rd_dwords(27'h000_8000, 4'd1, r0, r1);
    chk32(r0, 32'h1122_AA44, "byte-masked write keeps its neighbours");

    // ---- a 2-dword burst read (port 0's pair path) ----
    wr_dword(27'h000_9000, 32'hDEAD_BEEF, 4'hF);
    wr_dword(27'h000_9004, 32'hFEED_FACE, 4'hF);
    rd_dwords(27'h000_9000, 4'd2, r0, r1);
    chk32(r0, 32'hDEAD_BEEF, "burst read word 0");
    chk32(r1, 32'hFEED_FACE, "burst read word 1");

    // ---- the gather session (our own extension: two partial stores, one ACT) ----
    wr_dword(27'h000_A000, 32'hFFFF_FFFF, 4'hF);
    wr_dword(27'h000_A004, 32'hFFFF_FFFF, 4'hF);
    gather_write(27'h000_A000, 32'h0000_0011, 4'b0001, 32'h0022_0000, 4'b0100);
    rd_dwords(27'h000_A000, 4'd2, r0, r1);
    chk32(r0, 32'hFFFF_FF11, "gather entry 0 (byte 0 only)");
    chk32(r1, 32'hFF22_FFFF, "gather entry 1 (byte 2 only)");

    // ---- stores with NO byte enabled: they write nothing and must still close their row ----
    // A store's auto-precharge rides its last WRITE; one that issued no WRITE left its bank open,
    // and the next ACT to that bank (the read of another row below) is a protocol violation the
    // model counts. Same for a gather session whose every entry is masked.
    wr_dword(27'h000_8000, 32'hFFFF_FFFF, 4'b0000);
    rd_dwords(27'h000_8800, 4'd1, r0, r1);                   // bank 0, the next row
    rd_dwords(27'h000_8000, 4'd1, r0, r1);
    chk32(r0, 32'h1122_AA44, "a store with no byte enabled writes nothing");
    gather_write(27'h000_A000, 32'h0000_0000, 4'b0000, 32'h0000_0000, 4'b0000);
    rd_dwords(27'h000_A800, 4'd1, r0, r1);                   // bank 0, the next row
    rd_dwords(27'h000_A000, 4'd2, r0, r1);
    chk32(r0, 32'hFFFF_FF11, "an all-masked gather writes nothing (entry 0)");
    chk32(r1, 32'hFF22_FFFF, "an all-masked gather writes nothing (entry 1)");

    // ---- THE 64 MB CHIP BOUNDARY ----
    // On a 128 MB module the dword after 0x3FFFFFC is chip 1's first (bit 26 is Cs1_n), so a
    // burst that starts in chip 0's last row is SPLIT at the row and its second segment must
    // carry chip 1's select, bank 0 and row 0 (sdram.v's rc_* row+1 carry). Chip 0's own row 0
    // (bank 0) holds DIFFERENT data, so a second segment that kept chip 0's select - or a carry
    // that did not toggle the chip - reads or writes those words instead, and the data checks
    // below see it (and the model sees a READ to a bank that chip never activated).
    for (i = 0; i < 12; i = i + 1) begin
      wr_dword(27'(27'h000_0000 + i * 4), 32'h0C00_0000 + i, 4'hF);       // chip 0, bank 0, row 0
      wr_dword(27'(27'h400_0000 + i * 4), 32'hC1C1_0000 + i, 4'hF);       // chip 1, bank 0, row 0
    end
    for (i = 0; i < 4; i = i + 1)
      wr_dword(27'(27'h3FF_FFF0 + i * 4), 32'hC0C0_FF00 + i, 4'hF);       // chip 0's last 4 dwords
    rd_burst(27'h3FF_FFF8, 4'd4);                    // 2 in chip 0's last row, 2 in chip 1
    chk32(rbuf[0], 32'hC0C0_FF02, "chip-boundary 4-dword read, word 0 (chip 0)");
    chk32(rbuf[1], 32'hC0C0_FF03, "chip-boundary 4-dword read, word 1 (chip 0)");
    chk32(rbuf[2], 32'hC1C1_0000, "chip-boundary 4-dword read, word 2 (chip 1)");
    chk32(rbuf[3], 32'hC1C1_0001, "chip-boundary 4-dword read, word 3 (chip 1)");
    rd_burst(27'h3FF_FFF0, 4'd15);                   // 4 in chip 0, 11 in chip 1
    for (i = 0; i < 4; i = i + 1)
      chk32(rbuf[i], 32'hC0C0_FF00 + i, "chip-boundary 15-dword read, chip 0 part");
    for (i = 4; i < 15; i = i + 1)
      chk32(rbuf[i], 32'hC1C1_0000 + (i - 4), "chip-boundary 15-dword read, chip 1 part");
    // The two-word write split at the boundary: its second word is chip 1's first dword.
    wr_pair(27'h3FF_FFFC, 32'hB0B0_0001, 32'hB1B1_0002);
    rd_dwords(27'h3FF_FFFC, 4'd1, r0, r1);
    chk32(r0, 32'hB0B0_0001, "chip-boundary pair, word 0 (chip 0)");
    rd_dwords(27'h400_0000, 4'd1, r0, r1);
    chk32(r0, 32'hB1B1_0002, "chip-boundary pair, word 1 (chip 1)");
    rd_dwords(27'h000_0000, 4'd1, r0, r1);
    chk32(r0, 32'h0C00_0000, "chip-boundary pair left chip 0's row 0 alone");

    // ------------------------------------------------------------------
    // THE CONTENTION PHASE. Every port asserts at once, continuously, with different shapes:
    // port 0 the longest legal read burst, port 1 byte-masked writes (the mask-on-address
    // path), port 2 a gather session per iteration (the OTHER long transaction), port 3 short
    // reads. Nothing here checks the data - the point is the SHAPE of what reaches the pins,
    // and the model is the judge. This is the only phase in which the round-robin arbiter, the
    // pre-ACT reservation and the refresh-versus-burst margin are exercised at all.
    // ------------------------------------------------------------------
    for (i = 0; i < 400; i = i + 1) begin
      // All four presented on the same cycle, deliberately.
      @(negedge clk);
      valid0 = 1'b1; wr0 = 1'b0; addr0 = 27'(27'h000_2000 + (i & 27'h3F) * 27'h40);
      burst_cnt0 = 4'd15; be0 = 4'hF; gath0 = 1'b0;               // the longest legal burst
      valid1 = 1'b1; wr1 = 1'b1; addr1 = 27'(27'h000_C000 + (i & 27'h3F) * 27'h40);
      din1 = 32'hC0DE_0000 + i; be1 = 4'b0101; burst_cnt1 = 4'd1;
      valid2 = 1'b1; wr2 = 1'b1; addr2 = 27'(27'h000_E000 + (i & 27'h1F) * 27'h40);
      din2 = 32'h0000_5A00; be2 = 4'b0010; burst_cnt2 = 4'd1; gath0 = 1'b0;
      gath0_extra = 441'd0;
      gath0_extra[0 +: GENT_W] = {27'(27'h000_E000 + (i & 27'h1F) * 27'h40 + 27'h4), 32'h0000_00A5, 4'b1000};
      valid3 = 1'b1; wr3 = 1'b0; addr3 = 27'(27'h400_3000 + (i & 27'h3F) * 27'h20);
      burst_cnt3 = 4'd2; be3 = 4'hF;
      // Drop each as its own accept arrives; the round-robin decides the order.
      for (g = 0; g < 400; g = g + 1) begin
        @(negedge clk);
        if (ready0) valid0 = 1'b0;
        if (ready1) valid1 = 1'b0;
        if (ready2) valid2 = 1'b0;
        if (ready3) valid3 = 1'b0;
        if (!valid0 && !valid1 && !valid2 && !valid3) g = 400;
      end
      valid0 = 1'b0; valid1 = 1'b0; valid2 = 1'b0; valid3 = 1'b0;
      wr1 = 1'b0; wr2 = 1'b0;
      settle(60);                                                 // let every response drain
    end
    // An AUTO REFRESH pair (two chips, 2 x tRC) may legitimately be running here, so the
    // controller gets a bound to fall idle rather than one sample.
    checks = checks + 1;
    g = 0;
    while (busy && g < 200) begin @(negedge clk); g = g + 1; end
    if (busy) begin
      $display("FAIL contention (%0d MHz): the controller is still busy 200 clocks after the load drained", FREQ / 1_000_000);
      errors = errors + 1;
    end

    // ---- each chip's refresh cadence (the monitor above) ----
    for (i = 0; i < 2; i = i + 1) begin
      checks = checks + 1;
      if (ref_count[i] < 2) begin
        $display("FAIL refresh (%0d MHz): chip %0d saw %0d AUTO REFRESH command(s) in the run", FREQ / 1_000_000, i, ref_count[i]);
        errors = errors + 1;
      end else if (ref_maxgap[i] > T_REF_INTERVAL_NS || ($realtime - ref_last[i]) > T_REF_INTERVAL_NS) begin
        $display("FAIL refresh (%0d MHz): chip %0d's AUTO REFRESH gap %0.1f ns (to the end %0.1f ns) exceeds 64 ms / 8192 = %0.1f ns",
                 FREQ / 1_000_000, i, ref_maxgap[i], $realtime - ref_last[i], T_REF_INTERVAL_NS);
        errors = errors + 1;
      end else
        $display("NOTE sdram_strict %0d MHz: chip %0d: %0d AUTO REFRESH, widest gap %0.1f ns", FREQ / 1_000_000, i, ref_count[i], ref_maxgap[i]);
    end

    // ---- THE VERDICT IS THE MODEL'S ----
    // module_error_count() is the strict model's own tally of protocol and AC-timing
    // violations; nothing this bench believes can excuse one.
    checks = checks + 1;
    if (model.module_error_count() != 0) begin
      $display("FAIL (%0d MHz): the strict XSDS model recorded %0d protocol/timing violation(s)", FREQ / 1_000_000, model.module_error_count());
      errors = errors + 1;
    end
    $display("TB_PC9821_SDRAM_STRICT %0d MHz: %0d check(s), %0d mismatch(es), model violations %0d",
             FREQ / 1_000_000, checks, errors, model.module_error_count());
    done = 1'b1;
    end
  endtask
endmodule

module tb_pc9821_sdram_strict;
  // ==== DUT ====
  // One rig per preset clock (build_profile.py): base 90 MHz CL2, mediumoc 100 MHz CL3, heavyoc
  // 120 MHz CL3; and one at 50 MHz CL2, the clock of the integrated boot tier on the real
  // controller (run_boot_real.sh). Each rig generates its own controller clock and module clock.
  // The 90 MHz rig also takes the module size late (SIZE_LATE); the others have it from power-up.
  tb_pc9821_sdram_strict_rig #(.FREQ(90_000_000), .SIZE_LATE(1'b1)) r90 ();
  tb_pc9821_sdram_strict_rig #(.FREQ(100_000_000)) r100 ();
  tb_pc9821_sdram_strict_rig #(.FREQ(120_000_000)) r120 ();
  tb_pc9821_sdram_strict_rig #(.FREQ(50_000_000))  r50 ();

  initial begin
    #200_000_000;                          // 200 ms of sim time: a watchdog, not a budget
    $fatal(1, "TB_PC9821_SDRAM_STRICT: FAIL (watchdog; done 90=%0d 100=%0d 120=%0d 50=%0d)", r90.done, r100.done, r120.done, r50.done);
  end

  // ==== VERDICT ====
  initial begin
    fork
      r90.run();
      r100.run();
      r120.run();
      r50.run();
    join
    if (r90.done && r100.done && r120.done && r50.done &&
        (r90.errors == 0) && (r100.errors == 0) && (r120.errors == 0) && (r50.errors == 0)) begin
      $display("TB_PC9821_SDRAM_STRICT: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_SDRAM_STRICT: FAIL (errors 90=%0d 100=%0d 120=%0d 50=%0d)", r90.errors, r100.errors, r120.errors, r50.errors);
    end
  end

endmodule

`default_nettype wire
