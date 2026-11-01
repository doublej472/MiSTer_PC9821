`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The framework's write-only pll_cfg_hdmi and the full pll_cfg, each driven by its own copy of the real pc9821_vpll_ctl with identical stimulus (the N counter at address 3, the M counter at address 4, the 32-bit fraction K at address 7 and a start at address 2 at power-up, on the 24 kHz-to-31 kHz change and on the 31 kHz-to-24 kHz change), accept the same sequence of management writes and produce the same sequence of DPRIO writes (address and data, including the read-modify-write of the bypass-enable and odd-division registers at 0x15/0x17 and the fraction's two words at 0x18/0x19) and byte-identical 64-word PLL reconfiguration register files after every step, so swapping one core for the other cannot change the dot clock the guest's raster runs on; waitrequest pacing is allowed to differ and is not compared, the PLL model answers reads with the value last written two clocks after the address (where the vendor core's readLatency=3 capture point samples it), and the final registers are pinned to the words the stimulus wrote (N 0x10000 bypass at 3, M 0x0808 24 kHz / 0x20A09 31 kHz at 4, K 0 / 0x20B00000 at 7, the bypass/odd-division read-modify-write at 0x15/0x17, and every other register zero) rather than to either core's internal state. FAIL-FIRST: a pll_cfg_hdmi mutant that puts the M counter at the N counter's DPRIO address, or that never recognises the start register, makes the sequences or the register files differ, and both are compared; the bench also fails if the model's reads are not returned, because the bypass write-back would then not preserve the preloaded bits.
//
// THE REGISTER MAP is Altera's Cyclone V PLL reconfiguration interface (altera_pll_reconfig, as
// sys/pll_cfg/pll_cfg_hdmi.v and altera_pll_reconfig_core.v drive it): management address 2 =
// start, 3 = N counter, 4 = M counter, 5 = C counters, 7 = M's fraction K; a counter word is
// {odd[17], bypass[16], high[15:8], low[7:0]}. pc9821_vpll_ctl writes N (bypass), M, K and start
// (M 0x0808 = 16 for the 24 kHz clock, 0x20A09 = 19 with its odd bit for the 31 kHz clock; K 0 and
// 0x20B00000), which both cores must program identically.
//
// WHY TWO CONTROLLERS. One controller per core: each waits on ITS OWN core's mgmt_waitrequest,
// so a core that stalls longer does not desynchronise the other's write sequence -- that is the
// stimulus an OSD change produces, replayed against both cores. The two accepted management
// write sequences must still be equal, and the DPRIO programming they lead to must be equal.
//
// WHAT IT IS BLIND TO: the PLL's analog relock time (the model drops `locked` for LOCK_GAP
// clocks after a start and then raises it) and the fitter's placement (which counter values the
// real PLL starts from; the model begins at zero, as the core's own power-up init writes it, and
// preloads the bypass/odd-division registers with a nonzero pattern so the read-modify-write is
// actually exercised).

module tb_pc9821_pll_cfg_lockstep;
  localparam integer SETTLE    = 64;
  localparam integer LOCK_GAP  = 160;
  localparam integer MAX_CYCLE = 200_000;

  reg clk = 0;
  always #10 clk = ~clk;   // the 50 MHz reference both cores run on

  integer cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  // A run that never settles fails here rather than hanging the gate.
  initial begin
    #(MAX_CYCLE * 20);
    $fatal(1, "TB_PC9821_PLL_CFG_LOCKSTEP: watchdog after %0d cycles", MAX_CYCLE);
  end

  // ==== DUT ====
  reg want_31k  = 1'b0;
  reg pll_locked = 1'b0;

  // ---- side A: the full framework core (altera_pll_reconfig_top/-core) ----
  wire        a_wait, a_wr;
  wire  [5:0] a_addr;
  wire [31:0] a_wdata;
  wire        a_31, a_busy;
  wire [63:0] a_to_pll, a_from_pll;

  pc9821_vpll_ctl #(.SETTLE(SETTLE)) ctl_a (
    .clk(clk), .want_31k(want_31k), .pll_locked(pll_locked), .mgmt_waitrequest(a_wait),
    .mgmt_write(a_wr), .mgmt_address(a_addr), .mgmt_writedata(a_wdata),
    .vclk_31(a_31), .busy(a_busy)
  );
  /* verilator lint_off PINCONNECTEMPTY */
  pll_cfg dut_a (
    .mgmt_clk(clk), .mgmt_reset(1'b0),
    .mgmt_waitrequest(a_wait), .mgmt_read(1'b0), .mgmt_readdata(),
    .mgmt_write(a_wr), .mgmt_address(a_addr), .mgmt_writedata(a_wdata),
    .reconfig_to_pll(a_to_pll), .reconfig_from_pll(a_from_pll)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- side B: the cut-down framework core the top level now instantiates ----
  wire        b_wait, b_wr;
  wire  [5:0] b_addr;
  wire [31:0] b_wdata;
  wire        b_31, b_busy;
  wire [63:0] b_to_pll, b_from_pll;

  pc9821_vpll_ctl #(.SETTLE(SETTLE)) ctl_b (
    .clk(clk), .want_31k(want_31k), .pll_locked(pll_locked), .mgmt_waitrequest(b_wait),
    .mgmt_write(b_wr), .mgmt_address(b_addr), .mgmt_writedata(b_wdata),
    .vclk_31(b_31), .busy(b_busy)
  );
  pll_cfg_hdmi dut_b (
    .mgmt_clk(clk), .mgmt_reset(1'b0),
    .mgmt_waitrequest(b_wait),
    .mgmt_write(b_wr), .mgmt_address(b_addr), .mgmt_writedata(b_wdata),
    .reconfig_to_pll(b_to_pll), .reconfig_from_pll(b_from_pll)
  );

  // ---- the PLL reconfiguration register-file model, one per core ----
  // 64 x 16-bit DPRIO registers, reads returned two clocks after their address (the vendor
  // core's comment: "Issue two consecutive reads then wait; readLatency=3", counting the issue
  // cycle itself; its FOUR/FIVE capture registers sample the two reads one cycle apart), `locked`
  // on bit 16 and phase_done tied low on bit 17 of reconfig_from_pll.
  localparam integer LAT = 2;
  reg [15:0] preg_a [0:63];
  reg [15:0] preg_b [0:63];
  reg  [5:0] prd_a  [0:LAT-1];
  reg  [5:0] prd_b  [0:LAT-1];
  integer i, j;

  initial begin
    for (i = 0; i < 64; i = i + 1) begin
      preg_a[i] = 16'd0;
      preg_b[i] = 16'd0;
    end
    for (i = 0; i < LAT; i = i + 1) begin
      prd_a[i] = 6'd0;
      prd_b[i] = 6'd0;
    end
  end

  assign a_from_pll = {46'd0, 1'b0, pll_locked, preg_a[prd_a[LAT-1]]};
  assign b_from_pll = {46'd0, 1'b0, pll_locked, preg_b[prd_b[LAT-1]]};

  always @(posedge clk) begin
    if (a_to_pll[2]) begin
      if (a_to_pll[27]) preg_a[a_to_pll[9:4]][15:8] <= a_to_pll[25:18];
      if (a_to_pll[26]) preg_a[a_to_pll[9:4]][7:0]  <= a_to_pll[17:10];
    end
    if (b_to_pll[2]) begin
      if (b_to_pll[27]) preg_b[b_to_pll[9:4]][15:8] <= b_to_pll[25:18];
      if (b_to_pll[26]) preg_b[b_to_pll[9:4]][7:0]  <= b_to_pll[17:10];
    end
    prd_a[0] <= a_to_pll[3] ? a_to_pll[9:4] : 6'd0;
    prd_b[0] <= b_to_pll[3] ? b_to_pll[9:4] : 6'd0;
    for (j = 1; j < LAT; j = j + 1) begin
      prd_a[j] <= prd_a[j-1];
      prd_b[j] <= prd_b[j-1];
    end
  end

  // ==== CHECKS ====
  integer fails = 0;
  task automatic expect_true(input bit c, input string what);
    if (!c) begin $display("FAIL: %s", what); fails++; end
  endtask

  // The accepted management writes and the DPRIO writes each core produced, in order.
  localparam integer N_MGMT = 64;
  localparam integer N_DPRIO = 1024;
  reg  [5:0]  a_maddr [0:N_MGMT-1];
  reg [31:0]  a_mdata [0:N_MGMT-1];
  reg  [5:0]  b_maddr [0:N_MGMT-1];
  reg [31:0]  b_mdata [0:N_MGMT-1];
  reg  [5:0]  a_daddr [0:N_DPRIO-1];
  reg [15:0]  a_ddata [0:N_DPRIO-1];
  reg  [5:0]  b_daddr [0:N_DPRIO-1];
  reg [15:0]  b_ddata [0:N_DPRIO-1];
  integer a_nm = 0, b_nm = 0, a_nd = 0, b_nd = 0;

  wire a_start = a_wr && !a_wait && (a_addr == 6'd2);
  wire b_start = b_wr && !b_wait && (b_addr == 6'd2);

  always @(posedge clk) begin
    if (a_wr && !a_wait) begin
      a_maddr[a_nm] <= a_addr;
      a_mdata[a_nm] <= a_wdata;
      a_nm <= a_nm + 1;
    end
    if (b_wr && !b_wait) begin
      b_maddr[b_nm] <= b_addr;
      b_mdata[b_nm] <= b_wdata;
      b_nm <= b_nm + 1;
    end
    // The reconfiguration bus: a write is `reconfig_to_pll[2]`, its address [9:4] and its data
    // [25:10]; byteen [27:26] is always 2'b11 for these counters.
    if (a_to_pll[2]) begin
      a_daddr[a_nd] <= a_to_pll[9:4];
      a_ddata[a_nd] <= a_to_pll[25:10];
      a_nd <= a_nd + 1;
    end
    if (b_to_pll[2]) begin
      b_daddr[b_nd] <= b_to_pll[9:4];
      b_ddata[b_nd] <= b_to_pll[25:10];
      b_nd <= b_nd + 1;
    end
  end

  // `locked` follows the model: high once enabled, dropped for LOCK_GAP clocks after any start
  // write accepted by either core, then high again. `force_unlock` plays the lock-loss stimulus.
  reg        lock_enable = 1'b0;
  reg        force_unlock = 1'b0;
  reg [31:0] lock_gap = 0;
  always @(posedge clk) begin
    if (force_unlock) begin
      lock_gap   <= 0;
      pll_locked <= 1'b0;
    end else if (a_start || b_start) begin
      lock_gap   <= LOCK_GAP;
      pll_locked <= 1'b0;
    end else if (lock_gap != 0) begin
      lock_gap   <= lock_gap - 1;
      pll_locked <= (lock_gap == 1);
    end else begin
      pll_locked <= lock_enable;
    end
  end

  task automatic wait_idle(input string what);
    integer t;
    t = 0;
    while ((a_busy || b_busy) && t < MAX_CYCLE) begin
      @(posedge clk);
      t = t + 1;
    end
    expect_true(!a_busy && !b_busy, $sformatf("%s: both controllers release busy", what));
  endtask

  // Every comparison of the two cores' programming, in one place.
  task automatic compare_all(input string what);
    integer k;
    expect_true(a_nm == b_nm,
      $sformatf("%s: %0d accepted management writes vs %0d", what, a_nm, b_nm));
    for (k = 0; k < a_nm && k < b_nm; k = k + 1)
      if (a_maddr[k] !== b_maddr[k] || a_mdata[k] !== b_mdata[k])
        expect_true(1'b0, $sformatf("%s: mgmt write %0d is %0d/0x%08h vs %0d/0x%08h",
                    what, k, a_maddr[k], a_mdata[k], b_maddr[k], b_mdata[k]));
    expect_true(a_nd == b_nd,
      $sformatf("%s: %0d DPRIO writes vs %0d", what, a_nd, b_nd));
    for (k = 0; k < a_nd && k < b_nd; k = k + 1)
      if (a_daddr[k] !== b_daddr[k] || a_ddata[k] !== b_ddata[k])
        expect_true(1'b0, $sformatf("%s: DPRIO write %0d is @0x%02h 0x%04h vs @0x%02h 0x%04h",
                    what, k, a_daddr[k], a_ddata[k], b_daddr[k], b_ddata[k]));
    for (k = 0; k < 64; k = k + 1)
      if (preg_a[k] !== preg_b[k])
        expect_true(1'b0, $sformatf("%s: DPRIO register 0x%02h is 0x%04h vs 0x%04h",
                    what, k, preg_a[k], preg_b[k]));
  endtask

  // The register file a 24 kHz / 31 kHz configuration must leave, from the model's own preloaded
  // bits and the counter words the stimulus wrote -- never read out of either core. The full core
  // codes N bypass as bit 5 of 0x15 and M bypass as bit 4 (clear here: M is programmed), the M/N
  // odd-division bits as 0x17 bits 4/5, and the 32-bit fraction K as two 16-bit DPRIO words
  // (low at 0x18, high at 0x19); N itself is not programmed when it is bypassed.
  task automatic expect_picture(input reg [15:0] m_word, input reg [31:0] k_word, input string what);
    integer k;
    expect_true(preg_a[6'h12] == m_word,
      $sformatf("%s: M register 0x%04h, want 0x%04h", what, preg_a[6'h12], m_word));
    expect_true(preg_a[6'h13] == 16'h0000,
      $sformatf("%s: N register 0x%04h, want 0x0000 (N bypassed, not programmed)", what, preg_a[6'h13]));
    expect_true(preg_a[6'h15] == 16'h1224,
      $sformatf("%s: bypass register 0x%04h, want 0x1224 (N bypass set, M bypass clear)", what, preg_a[6'h15]));
    expect_true(preg_a[6'h17] == (m_word[0] ? 16'h0F1F : 16'h0F0F),
      $sformatf("%s: odd-div register 0x%04h, want 0x%04h (M odd %0d, N odd 0)",
                what, preg_a[6'h17], m_word[0] ? 16'h0F1F : 16'h0F0F, m_word[0]));
    expect_true(preg_a[6'h18] == k_word[15:0] && preg_a[6'h19] == k_word[31:16],
      $sformatf("%s: K registers 0x%04h/0x%04h, want 0x%04h/0x%04h", what,
                preg_a[6'h19], preg_a[6'h18], k_word[31:16], k_word[15:0]));
    for (k = 0; k < 64; k = k + 1)
      if (k != 6'h12 && k != 6'h13 && k != 6'h15 && k != 6'h17 && k != 6'h18 && k != 6'h19)
        expect_true(preg_a[k] == 16'h0000,
          $sformatf("%s: untouched register 0x%02h is 0x%04h", what, k, preg_a[k]));
  endtask

  task automatic expect_change(input integer m0, input reg [31:0] m_full, input reg [31:0] k_word,
                              input string what);
    expect_true(a_nm == m0 + 4, $sformatf("%s: %0d management writes, want 4", what, a_nm - m0));
    expect_true(a_maddr[m0] == 6'd3 && a_mdata[m0] == 32'h0001_0000 &&
                a_maddr[m0+1] == 6'd4 && a_mdata[m0+1] == m_full &&
                a_maddr[m0+2] == 6'd7 && a_mdata[m0+2] == k_word &&
                a_maddr[m0+3] == 6'd2,
                $sformatf("%s: writes %0d/0x%08h %0d/0x%08h %0d/0x%08h %0d (want 3/0x10000, 4/0x%08h, 7/0x%08h, 2)",
                          what, a_maddr[m0], a_mdata[m0], a_maddr[m0+1], a_mdata[m0+1],
                          a_maddr[m0+2], a_mdata[m0+2], a_maddr[m0+3], m_full, k_word));
  endtask

  integer w0, d0, busy_at;
  initial begin
    // The core's power-up init writes all 64 DPRIO registers to zero; preload the preserved
    // bits afterwards so the bypass/odd-division read-modify-write has something to preserve.
    #(450 * 20);
    preg_a[6'h15] = 16'h1234; preg_b[6'h15] = 16'h1234;
    preg_a[6'h17] = 16'h0F3F; preg_b[6'h17] = 16'h0F3F;
    lock_enable = 1'b1;

    // ---- power-up: the PLL is at its generated configuration, the OSD wants native ----
    expect_true(a_busy && b_busy, "busy at power-up");
    wait_idle("power-up");
    expect_true(a_31 == b_31 && !a_31, "both controllers name the 24 kHz configuration");
    expect_change(0, 32'h0000_0808, 32'h0000_0000, "power-up");
    expect_picture(16'h0808, 32'h0000_0000, "power-up");
    compare_all("power-up");

    // ---- nothing changes: no write on either side ----
    w0 = a_nm; d0 = a_nd;
    repeat (2000) @(posedge clk);
    expect_true(a_nm == w0 && b_nm == w0 && a_nd == d0 && !a_busy && !b_busy,
                "idle: no management or DPRIO write, neither side busy");
    compare_all("idle");

    // ---- 0x09A8 bit 0 set: both cores must reach the same new M and K ----
    @(posedge clk); want_31k = 1'b1;
    repeat (4) @(posedge clk);
    expect_true(a_busy && b_busy && a_31 && b_31, "busy and 31 kHz selected on the request");
    wait_idle("31 kHz");
    expect_change(w0, 32'h0002_0A09, 32'h20B0_0000, "31 kHz");
    expect_picture(16'h0A09, 32'h20B0_0000, "31 kHz");
    compare_all("31 kHz");

    // ---- back to the 24 kHz clock ----
    w0 = a_nm; d0 = a_nd;
    @(posedge clk); want_31k = 1'b0;
    repeat (4) @(posedge clk);
    expect_true(a_busy && b_busy && !a_31 && !b_31, "busy and 24 kHz selected on the request");
    wait_idle("24 kHz");
    expect_change(w0, 32'h0000_0808, 32'h0000_0000, "24 kHz");
    expect_picture(16'h0808, 32'h0000_0000, "24 kHz");
    compare_all("24 kHz");

    // ---- lock lost while idle: busy until relocked and settled, and no write ----
    w0 = a_nm; d0 = a_nd;
    @(posedge clk); force_unlock = 1'b1;
    repeat (10) @(posedge clk);
    expect_true(a_busy && b_busy, "busy while the PLL is unlocked");
    repeat (200) @(posedge clk);
    force_unlock = 1'b0;
    repeat (SETTLE / 2) @(posedge clk);
    expect_true(a_busy && b_busy, "still busy inside the settle window");
    wait_idle("lock loss");
    expect_true(a_nm == w0 && a_nd == d0, "a lock loss writes nothing on either side");
    compare_all("lock loss");

    // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_PLL_CFG_LOCKSTEP: %0d check(s) failed", fails);
    $display("TB_PC9821_PLL_CFG_LOCKSTEP: PASS");
    $finish;
  end
endmodule
