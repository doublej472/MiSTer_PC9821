`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_Z486_TLB_WINDOW: paging_tlb's REGISTERED lookup port - since upstream's one-port TLB its ONLY four-way lookup port (walker, demand and prefetch share it as on the i486; the live demand port this bench also checked was REMOVED with it) - never hands back a translation the array does not hold. When the data array was read one cycle early, in the cycle after a walker insert the port held the PRE-insert word while the valid bits were post-insert: when the insert replaced the same VPN's entry (a CR3 switch or an INVLPG+PTE edit, where invalidate_all resets PLRU to 000 and way 0 can still carry that VPN's old tag) the pair reported a HIT with the old physical frame, the old permission bits and the old VGA class. The bench drives the port contract directly, with a golden transcribed from the module's documented update rules (in-place match else PLRU victim; CR3 clears every valid bit and resets PLRU; INVLPG clears only the tag-matched way), over seven directed sequences: the CR3 re-walk of the same VPN, an INVLPG re-walk that changes the permission bits, a re-walk that replaces a DIFFERENT VPN's way (the probing lookup must then miss), a four-way fill whose fifth insert evicts by PLRU, and the VGA-class change - all with the window probe in the cycle right after the insert. Every cycle the port must EITHER equal the documented post-edge state field for field (hit/frame/writable/user/dirty/is_vga_mem) OR take the no-hit form, and OUTSIDE the window it must equal the documented state exactly, so the refusal may not be blanket: a probe of another set in the window keeps its hit and an INVLPG cycle needs no refusal at all. FAIL-FIRST: on the pre-window-guard RTL the same bench reports the stale HIT (frame=old, want=new) in each of the three same-set re-walk sequences. Blind spots stated in the header: not a hardware bench, the walker/paging_unit FSM and the VIPT sidecar are outside it.
//
// The header above is the manifest claim VERBATIM (tools/check_tests.py holds the two
// together). What follows is the same claim as prose plus the two things a reader needs
// to audit it: where the golden comes from, and what it is blind to.
//
// WHAT THE GOLDEN IS. The model is the module's own documented state, transcribed: 8
// sets x 4 ways, an in-place update when the set already holds the walked VPN else the
// PLRU victim, CR3 clearing every valid bit and resetting PLRU to 000, INVLPG clearing
// only the way whose tag matches the page (paging_tlb.sv's inval_match), a hit and an
// insert each pointing the PLRU away from the way they touched, and the no-hit answer in
// the module's own documented shape: the REGISTERED port falls back to the linear
// address with writable=1/user=0/dirty=0. The driver still clocks `lin` from `nxt` (the
// one-cycle-early read shape the window guard was written for); the array is now read
// combinationally from asynchronous MLAB copies, so the window is closed structurally
// and the port must simply equal the documented state every cycle -- which the window
// arm below accepts as `exact`.
//
// THE LIVE PORT IS GONE. Upstream made the four-way TLB one-port (walker, demand and
// prefetch share the registered lookup, as on the i486 LA bus), removing
// linear_addr_live / live_hit / live_physical_addr / live_writable / live_user /
// live_dirty / live_is_vga_mem; the per-cycle live-port check (documented state or its
// pfn-0 no-hit form) went with it. Every registered-port check is unchanged.
//
// WHAT IT IS BLIND TO, stated: (1) it is not a hardware-behaviour bench -- no NP2kai
// value is asserted; (2) the paging FSM is out of scope: which real consumer can be in
// the window cycle is what decides the cost of the refusal, and that reach is argued in
// the fork's own log for this change, not measured here; (3) the VIPT sidecar is left
// unexercised (vipt_preread tied off), and the walker/paging_unit are not instantiated.
//
// FAIL-FIRST, how it was taken: the same bench built against the pre-window-guard
// paging_tlb.sv (git show <commit>^:src/z486/paging_tlb.sv) reports 9 mismatches and 4
// STALE HITs -- frame=001230c8 where the array holds 004560c8 -- and exits 1.

`default_nettype none

module tb_pc9821_z486_tlb_window;
  import z486_pkg::*;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset_n = 0;
  integer errors = 0;

  // A schedule that does not finish is a hang, not a pass.
  initial begin #2_000_000; $fatal(1, "watchdog: the TLB window schedule did not finish"); end

  // ==========================================================================
  // ==== DUT ====
  // The module's port contract, driven directly: `linear_addr` is the
  // registered lookup address (a register, so it moves ON the clock edge),
  // `lookup_addr_next` its NEXT value -- the clocked read is issued one cycle
  // early, which is what the RD_ALIGN fuse states -- and while `update_valid` is
  // asserted the contract requires the lookup address to be the walked address:
  // every insert below is driven that way.
  // ==========================================================================
  typedef struct packed {
    logic [31:0] addr;
    logic [19:0] uvpn;
    logic [19:0] upfn;
    logic [19:0] i_vpn;
    logic        uv;
    logic        i_all;
    logic        i_page;
    logic        uw;
    logic        uu;
    logic        ud;
  } step_t;

  localparam integer MAXS = 512;
  step_t  sched [0:MAXS-1];
  integer nsteps = 0;

  reg  [31:0] lin = 0, nxt = 0;
  reg         uv = 0, i_all = 0, i_page = 0;
  reg  [19:0] uvpn = 0, upfn = 0, i_vpn = 0;
  reg         uw = 1, uu = 0, ud = 0;
  reg  [31:0] k = 0;                    // the schedule entry in force this cycle

  wire        dut_hit, dut_wr, dut_us, dut_di, dut_vga;
  wire [31:0] dut_phys;

  paging_tlb dut (
    .clk(clk), .reset_n(reset_n),
    .linear_addr(lin),
    .hit(dut_hit), .physical_addr(dut_phys), .writable(dut_wr), .user(dut_us),
    .dirty(dut_di), .is_vga_mem(dut_vga), .is_pcd(),
    .vipt_preread(1'b0), .vipt_linear_addr(32'h0),
    .vipt_hit(), .vipt_physical_addr(), .vipt_writable(), .vipt_user(),
    .vipt_dirty(), .vipt_is_vga_mem(),
    .vipt_refill_valid(1'b0), .vipt_refill_linear(32'h0), .vipt_refill_pfn(20'h0),
    .vipt_refill_writable(1'b0), .vipt_refill_user(1'b0), .vipt_refill_dirty(1'b0),
    .vipt_refill_pcd(1'b0),
    .update_valid(uv), .update_vpn(uvpn), .update_pfn(upfn),
    .update_writable(uw), .update_user(uu), .update_dirty(ud),
    .update_pcd(1'b0), .update_pwt(1'b0),
    .invalidate_all(i_all), .invalidate_page(i_page), .invalidate_vpn(i_vpn),
    .tlbt_req(1'b0), .tlbt_tr6(32'd0), .tlbt_tr7(32'd0),
    .tlbt_done(), .tlbt_lookup_done(), .tlbt_tr6_out(), .tlbt_tr7_out()
  );

  // The driver: `nxt` leads `lin` by one cycle and both move with the clock, so
  // lookup_addr_next_d == linear_addr holds at every instant (RD_ALIGN).
  always_ff @(posedge clk) begin
    if (!reset_n) begin
      k     <= 0;
      lin   <= sched[0].addr;
      nxt   <= sched[1].addr;
      uv    <= sched[0].uv;
      uvpn  <= sched[0].uvpn;
      upfn  <= sched[0].upfn;
      uw    <= sched[0].uw; uu <= sched[0].uu; ud <= sched[0].ud;
      i_all <= sched[0].i_all; i_page <= sched[0].i_page; i_vpn <= sched[0].i_vpn;
    end else if (k + 1 < nsteps) begin
      k   <= k + 1;
      lin <= nxt;
      nxt <= (k + 2 < nsteps) ? sched[k + 2].addr : sched[k + 1].addr;
      uv    <= sched[k + 1].uv;
      uvpn  <= sched[k + 1].uvpn;
      upfn  <= sched[k + 1].upfn;
      uw    <= sched[k + 1].uw; uu <= sched[k + 1].uu; ud <= sched[k + 1].ud;
      i_all <= sched[k + 1].i_all; i_page <= sched[k + 1].i_page;
      i_vpn <= sched[k + 1].i_vpn;
    end
  end

  // ==========================================================================
  // ==== CHECKS ====  (the golden model lives here; it never reads the DUT)
  //
  // The golden is the documented TLB: 8 sets x 4 ways of {valid, tag, pfn,
  // writable, user, dirty} plus the PLRU bits, updated by the module's own
  // documented rules. Its per-cycle answer is what the OLD combinational read of
  // the lookup address returned -- the state the array holds in this cycle.
  // ==========================================================================
  reg        g_v   [0:7][0:3];
  reg [16:0] g_tag [0:7][0:3];
  reg [19:0] g_pfn [0:7][0:3];
  reg        g_w   [0:7][0:3];
  reg        g_u   [0:7][0:3];
  reg        g_d   [0:7][0:3];
  reg [2:0]  g_plru [0:7];
  integer    gs, gw_i;

  // The stale oracle: the word the CLOCKED read holds in the cycle after a
  // write. It is the pre-edge content of the set the insert writes, taken at
  // that edge -- combined with the current (post-edge) valid bits this is
  // exactly the request an unguarded port would have answered, so the bench can
  // prove its own stimulus reaches the bug's shape instead of assuming it.
  reg [16:0] s_tag [0:3];
  reg [19:0] s_pfn [0:3];
  reg        s_w [0:3], s_u [0:3], s_d [0:3];

  always_ff @(posedge clk) begin
    if (!reset_n) begin
      for (gs = 0; gs < 8; gs = gs + 1) begin
        g_plru[gs] <= 3'b000;
        for (gw_i = 0; gw_i < 4; gw_i = gw_i + 1) begin
          g_v[gs][gw_i] <= 1'b0;
          g_tag[gs][gw_i] <= 17'h0;
          g_pfn[gs][gw_i] <= 20'h0;
          g_w[gs][gw_i] <= 1'b0; g_u[gs][gw_i] <= 1'b0; g_d[gs][gw_i] <= 1'b0;
        end
      end
      for (gw_i = 0; gw_i < 4; gw_i = gw_i + 1) begin
        s_tag[gw_i] <= 17'h0; s_pfn[gw_i] <= 20'h0;
        s_w[gw_i] <= 1'b0; s_u[gw_i] <= 1'b0; s_d[gw_i] <= 1'b0;
      end
    end else begin
      // what the read issued on THIS edge will hold next cycle: the word of the
      // update set as it is before the edge (the port contract makes the walked
      // address the registered lookup address, so this set is the one read)
      for (gw_i = 0; gw_i < 4; gw_i = gw_i + 1) begin
        s_tag[gw_i] <= g_tag[uvpn[2:0]][gw_i];
        s_pfn[gw_i] <= g_pfn[uvpn[2:0]][gw_i];
        s_w[gw_i] <= g_w[uvpn[2:0]][gw_i];
        s_u[gw_i] <= g_u[uvpn[2:0]][gw_i];
        s_d[gw_i] <= g_d[uvpn[2:0]][gw_i];
      end

      if (i_all) begin
        // CR3: every valid bit cleared (tags stay), PLRU reset to 000
        for (gs = 0; gs < 8; gs = gs + 1) begin
          g_plru[gs] <= 3'b000;
          g_v[gs][0] <= 1'b0; g_v[gs][1] <= 1'b0;
          g_v[gs][2] <= 1'b0; g_v[gs][3] <= 1'b0;
        end
      end else if (i_page) begin
        // INVLPG: every valid way whose tag is the page's (paging_tlb.sv's
        // inval_match); unrelated entries in the set survive
        for (gw_i = 0; gw_i < 4; gw_i = gw_i + 1)
          if (g_v[i_vpn[2:0]][gw_i] && (g_tag[i_vpn[2:0]][gw_i] == i_vpn[19:3]))
            g_v[i_vpn[2:0]][gw_i] <= 1'b0;
      end else begin
        if (golden_hit) begin
          case (golden_way)
            2'd0: begin g_plru[lin[14:12]][0] <= 1'b1; g_plru[lin[14:12]][1] <= 1'b1; end
            2'd1: begin g_plru[lin[14:12]][0] <= 1'b1; g_plru[lin[14:12]][1] <= 1'b0; end
            2'd2: begin g_plru[lin[14:12]][0] <= 1'b0; g_plru[lin[14:12]][2] <= 1'b1; end
            2'd3: begin g_plru[lin[14:12]][0] <= 1'b0; g_plru[lin[14:12]][2] <= 1'b0; end
          endcase
        end
        if (uv) begin
          g_v[uvpn[2:0]][golden_victim[1:0]] <= 1'b1;
          g_tag[uvpn[2:0]][golden_victim[1:0]] <= uvpn[19:3];
          g_pfn[uvpn[2:0]][golden_victim[1:0]] <= upfn;
          g_w[uvpn[2:0]][golden_victim[1:0]] <= uw;
          g_u[uvpn[2:0]][golden_victim[1:0]] <= uu;
          g_d[uvpn[2:0]][golden_victim[1:0]] <= ud;
          // the insert points the PLRU away from the way it filled, with the
          // same encoding as a hit (last write wins over the hit update above)
          case (golden_victim)
            3'd0: begin g_plru[uvpn[2:0]][0] <= 1'b1; g_plru[uvpn[2:0]][1] <= 1'b1; end
            3'd1: begin g_plru[uvpn[2:0]][0] <= 1'b1; g_plru[uvpn[2:0]][1] <= 1'b0; end
            3'd2: begin g_plru[uvpn[2:0]][0] <= 1'b0; g_plru[uvpn[2:0]][2] <= 1'b1; end
            default: begin g_plru[uvpn[2:0]][0] <= 1'b0; g_plru[uvpn[2:0]][2] <= 1'b0; end
          endcase
        end
      end
    end
  end

  // The golden lookup for the current lookup address: first matching valid way
  // in the module's priority order, else the documented no-hit form.
  reg        golden_hit;
  reg [1:0]  golden_way;
  reg [2:0]  golden_victim;
  always_comb begin : golden_lookup
    integer kk;
    reg     m;
    golden_hit = 1'b0;
    golden_way = 2'd0;
    m = 1'b0;
    for (kk = 0; kk < 4; kk = kk + 1) begin
      if (!m && g_v[lin[14:12]][kk[1:0]] && (g_tag[lin[14:12]][kk[1:0]] == lin[31:15])) begin
        m = 1'b1;
        golden_way = kk[1:0];
      end
    end
    golden_hit = m;
    golden_victim = m ? {1'b0, golden_way} :
                    (g_plru[uvpn[2:0]][0] ? (g_plru[uvpn[2:0]][2] ? 3'd3 : 3'd2)
                                          : (g_plru[uvpn[2:0]][1] ? 3'd1 : 3'd0));
  end

  reg        g_hit, g_wr, g_us, g_di, g_vga;
  reg [31:0] g_phys;
  always_comb begin : golden_answer
    integer kk;
    reg     m;
    g_hit = 1'b0;
    g_phys = lin; g_wr = 1'b1; g_us = 1'b0; g_di = 1'b0; g_vga = 1'b0;
    m = 1'b0;
    for (kk = 0; kk < 4; kk = kk + 1) begin
      if (!m && g_v[lin[14:12]][kk[1:0]] && (g_tag[lin[14:12]][kk[1:0]] == lin[31:15])) begin
        m = 1'b1;
        g_phys = {g_pfn[lin[14:12]][kk[1:0]], lin[11:0]};
        g_wr = g_w[lin[14:12]][kk[1:0]];
        g_us = g_u[lin[14:12]][kk[1:0]];
        g_di = g_d[lin[14:12]][kk[1:0]];
        g_vga = (g_pfn[lin[14:12]][kk[1:0]][19:5] == 15'h5);
      end
    end
    g_hit = m;
  end

  // The stale oracle's answer for the current address: the word in hand (the
  // pre-edge fields of the written set) with the CURRENT valid bits.
  reg        o_hit, o_wr, o_us, o_di, o_vga;
  reg [31:0] o_phys;
  always_comb begin : stale_oracle
    integer kk;
    reg     m;
    o_hit = 1'b0;
    o_phys = lin; o_wr = 1'b1; o_us = 1'b0; o_di = 1'b0; o_vga = 1'b0;
    m = 1'b0;
    for (kk = 0; kk < 4; kk = kk + 1) begin
      if (!m && g_v[lin[14:12]][kk[1:0]] && (s_tag[kk[1:0]] == lin[31:15])) begin
        m = 1'b1;
        o_phys = {s_pfn[kk[1:0]], lin[11:0]};
        o_wr = s_w[kk[1:0]]; o_us = s_u[kk[1:0]]; o_di = s_d[kk[1:0]];
        o_vga = (s_pfn[kk[1:0]][19:5] == 15'h5);
      end
    end
    o_hit = m;
  end

  // Per-cycle verdicts, and the census the PASS line reports.
  integer wnd_cycles = 0;      // cycles whose read set the previous edge wrote
  integer wnd_hits = 0;        // ... in which the port reported a hit
  integer oracle_wrong = 0;    // ... in which the stale word would have been wrong

  task automatic fail(input string what);
    begin
      errors = errors + 1;
      $display("FAIL [tlb-window] %s at cycle %0d: lin=%08x hit=%b phys=%08x wr=%b us=%b di=%b vga=%b | array hit=%b phys=%08x wr=%b us=%b di=%b vga=%b",
               what, k, lin, dut_hit, dut_phys, dut_wr, dut_us, dut_di, dut_vga,
               g_hit, g_phys, g_wr, g_us, g_di, g_vga);
      if (errors > 16) begin
        $display("TB_PC9821_Z486_TLB_WINDOW: FAIL (too many mismatches)");
        $fatal(1, "the registered TLB port handed back a stale translation");
      end
    end
  endtask

  task automatic check_cycle();
    reg        window_now;
    reg        refused, exact;
    reg        orc_wrong;
    begin
      // The window: the edge that started this cycle wrote the set this read was
      // issued for -- the write is entry k-1's (its controls are what that edge
      // sampled) and the read index is this cycle's address's set (RD_ALIGN).
      window_now = (k >= 1) && sched[k - 1].uv &&
                   (sched[k - 1].addr[14:12] == sched[k].addr[14:12]);

      exact   = (dut_hit === g_hit) && (dut_phys === g_phys) && (dut_wr === g_wr) &&
                (dut_us === g_us) && (dut_di === g_di) && (dut_vga === g_vga);
      refused = !dut_hit && (dut_phys === lin) && dut_wr && !dut_us && !dut_di && !dut_vga;

      if (window_now) begin
        wnd_cycles = wnd_cycles + 1;
        if (dut_hit) wnd_hits = wnd_hits + 1;
        // the stale word an unguarded clocked read would answer with -- only
        // meaningful when the previous edge really wrote the array
        orc_wrong = !(sched[k - 1].i_all || sched[k - 1].i_page) && o_hit &&
                    (!g_hit || (o_phys !== g_phys) || (o_wr !== g_wr) ||
                     (o_us !== g_us) || (o_di !== g_di) || (o_vga !== g_vga));
        if (orc_wrong) begin
          oracle_wrong = oracle_wrong + 1;
          if (dut_hit && (dut_phys === o_phys) && (dut_wr === o_wr) &&
              (dut_us === o_us) && (dut_di === o_di) && (dut_vga === o_vga))
            fail("STALE HIT: the port answered with the pre-write word the insert replaced");
        end
        if (!(exact || refused))
          fail("the window answer is neither the documented state nor the no-hit form");
      end else begin
        if (!exact)
          fail("outside the window the port must BE the documented state (a refusal here loses a hit)");
      end
    end
  endtask

  // ==========================================================================
  // ==== STIMULUS ====
  // One schedule entry per cycle. The address of entry k is the registered
  // lookup address of cycle k, and every entry carries the walked VPN as its
  // own VPN -- the module's port contract while update_valid is asserted.
  // ==========================================================================
  localparam [19:0] VPN_A  = 20'h3_2443;   // set 3
  localparam [19:0] VPN_A2 = 20'h3_244b;   // set 3, another tag
  localparam [19:0] VPN_A3 = 20'h3_2453;   // set 3
  localparam [19:0] VPN_A4 = 20'h3_245b;   // set 3
  localparam [19:0] VPN_A5 = 20'h3_2463;   // set 3
  localparam [19:0] VPN_B  = 20'h3_2441;   // set 1
  localparam [19:0] VPN_C  = 20'h3_2442;   // set 2
  localparam [31:0] LIN_A  = {VPN_A,  12'h0c8};
  localparam [31:0] LIN_A2 = {VPN_A2, 12'h0c8};
  localparam [31:0] LIN_A3 = {VPN_A3, 12'h0d0};
  localparam [31:0] LIN_A4 = {VPN_A4, 12'h0e0};
  localparam [31:0] LIN_A5 = {VPN_A5, 12'h0f0};
  localparam [31:0] LIN_B  = {VPN_B,  12'h010};
  localparam [31:0] LIN_C  = {VPN_C,  12'h020};
  localparam [19:0] PFN_OLD = 20'h0_0123;     // PFN[19:5] != 5: not the VGA class
  localparam [19:0] PFN_NEW = 20'h0_0456;
  localparam [19:0] PFN_A   = 20'h0_0789;
  localparam [19:0] PFN_B   = 20'h0_0abc;
  localparam [19:0] PFN_C   = 20'h0_0def;
  localparam [19:0] PFN_D   = 20'h0_0111;
  localparam [19:0] PFN_E   = 20'h0_0222;
  localparam [19:0] PFN_VGA = 20'h0_000b0;    // PFN[19:5] == 5: the VGA class

  task automatic push_step(input [31:0] a, input [19:0] vpn, input [19:0] pfn,
                           input logic u, input logic w, input logic us, input logic d,
                           input logic ia, input logic ip, input [19:0] ivpn);
    begin
      if (nsteps >= MAXS)
        $fatal(1, "the TLB window schedule overflowed %0d steps", MAXS);
      sched[nsteps].addr = a;
      sched[nsteps].uvpn = vpn;
      sched[nsteps].upfn = pfn;
      sched[nsteps].uv   = u;
      sched[nsteps].uw   = w;
      sched[nsteps].uu   = us;
      sched[nsteps].ud   = d;
      sched[nsteps].i_all = ia;
      sched[nsteps].i_page = ip;
      sched[nsteps].i_vpn = ivpn;
      nsteps = nsteps + 1;
    end
  endtask

  task automatic idle(input [31:0] a, input integer n);
    integer kk;
    begin
      for (kk = 0; kk < n; kk = kk + 1)
        push_step(a, a[31:12], 20'h0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 20'h0);
    end
  endtask

  task automatic ins(input [31:0] a, input [19:0] pfn,
                     input logic w, input logic us, input logic d);
    begin
      push_step(a, a[31:12], pfn, 1'b1, w, us, d, 1'b0, 1'b0, 20'h0);
    end
  endtask

  task automatic flush_all(input [31:0] a);
    begin
      push_step(a, a[31:12], 20'h0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 20'h0);
    end
  endtask

  task automatic flush_page(input [31:0] a, input [19:0] vpn);
    begin
      push_step(a, a[31:12], 20'h0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, vpn);
    end
  endtask

  // seq 1: the stale-tag case -- a CR3 switch re-walks the same VPN into the way
  // that still carries its old tag (invalidate_all resets PLRU to 000).
  task automatic seq_cr3_rewalk();
    begin
      flush_all(LIN_A);
      idle(LIN_A, 2);
      ins(LIN_A, PFN_OLD, 1'b1, 1'b0, 1'b0);   // way 0
      idle(LIN_A, 1);                          // WINDOW (the pre-fix stale miss)
      idle(LIN_A, 2);                          // hit: PFN_OLD
      flush_all(LIN_A);                        // valid cleared, tags stay
      idle(LIN_A, 1);                          // miss
      ins(LIN_A, PFN_NEW, 1'b1, 1'b0, 1'b0);   // the re-walk
      idle(LIN_A, 1);                          // WINDOW: pre-fix stale HIT PFN_OLD
      idle(LIN_A, 3);                          // hit: PFN_NEW
    end
  endtask

  // seq 2: an INVLPG + PTE edit changes the permission bits for the same VPN.
  task automatic seq_invlpg_permissions();
    begin
      flush_all(LIN_A);
      ins(LIN_A, PFN_OLD, 1'b1, 1'b1, 1'b1);   // writable, user, dirty
      idle(LIN_A, 1);                          // WINDOW
      idle(LIN_A, 1);                          // hit with those bits
      flush_page(LIN_A, VPN_A);
      idle(LIN_A, 1);                          // miss
      ins(LIN_A, PFN_NEW, 1'b0, 1'b0, 1'b0);   // read-only, clean
      idle(LIN_A, 1);                          // WINDOW: pre-fix stale HIT with the OLD bits
      idle(LIN_A, 2);                          // hit with the new bits
    end
  endtask

  // seq 3: the insert replaces a DIFFERENT VPN's way, so the probing lookup (the
  // replaced VPN) is no longer mapped at all -- a stale hit here is a frame the
  // page tables no longer map.
  task automatic seq_replaced_vpn();
    begin
      flush_all(LIN_A);
      ins(LIN_A, PFN_A, 1'b1, 1'b0, 1'b0);
      idle(LIN_A, 1);                          // WINDOW
      idle(LIN_A, 1);                          // hit
      flush_all(LIN_A);
      idle(LIN_A, 1);                          // miss
      ins(LIN_A2, PFN_B, 1'b1, 1'b0, 1'b0);    // victim = way 0, the way VPN_A's tag sits in
      idle(LIN_A, 1);                          // WINDOW: pre-fix stale HIT PFN_A
      idle(LIN_A2, 1);                         // WINDOW: the walked VPN
      idle(LIN_A, 2);                          // must MISS
      idle(LIN_A2, 2);                         // hit: PFN_B
    end
  endtask

  // seq 4: a probe of ANOTHER set in the window read a word no write touched,
  // so its hit must survive -- the refusal may not be blanket.
  task automatic seq_other_set_keeps_hit();
    begin
      flush_all(LIN_B);
      ins(LIN_B, PFN_C, 1'b1, 1'b0, 1'b0);     // set 1
      idle(LIN_B, 2);                          // hit: PFN_C
      ins(LIN_A, PFN_D, 1'b1, 1'b0, 1'b0);     // a write into set 3
      idle(LIN_B, 1);                          // NOT a window for this read: must HIT PFN_C
      idle(LIN_A, 1);                          // WINDOW: refused, or the documented answer
      idle(LIN_B, 2);                          // hit: PFN_C
    end
  endtask

  // seq 5: an INVLPG writes no array word, so the cycle after it needs no
  // refusal at all (the valid bits are flops, read live).
  task automatic seq_invlpg_other_set();
    begin
      flush_all(LIN_B);
      ins(LIN_B, PFN_C, 1'b1, 1'b0, 1'b0);
      idle(LIN_B, 2);                          // hit
      flush_page(LIN_C, VPN_C);                // set 2, which holds no entry
      idle(LIN_B, 1);                          // must still HIT PFN_C
      flush_all(LIN_B);
      idle(LIN_B, 2);                          // miss
    end
  endtask

  // seq 6: fill all four ways, then a fifth insert evicts by PLRU (way 0, the
  // way that held VPN_A): the evicted VPN must miss afterwards and the three
  // survivors must still answer with their own frames -- the read-modify-write
  // preserved them.
  task automatic seq_four_ways_evict();
    begin
      flush_all(LIN_A);
      ins(LIN_A,  PFN_A, 1'b1, 1'b0, 1'b0);    // way 0
      idle(LIN_B, 1);
      ins(LIN_A2, PFN_B, 1'b1, 1'b0, 1'b0);    // way 2
      idle(LIN_B, 1);
      ins(LIN_A3, PFN_C, 1'b1, 1'b0, 1'b0);    // way 1
      idle(LIN_B, 1);
      ins(LIN_A4, PFN_D, 1'b1, 1'b0, 1'b0);    // way 3
      idle(LIN_B, 1);
      ins(LIN_A5, PFN_E, 1'b1, 1'b0, 1'b0);    // way 0: evicts VPN_A
      idle(LIN_A5, 1);                         // WINDOW
      idle(LIN_A, 2);                          // evicted: must MISS
      idle(LIN_A2, 1);                         // hit: PFN_B
      idle(LIN_A3, 1);                         // hit: PFN_C
      idle(LIN_A4, 1);                         // hit: PFN_D
      idle(LIN_A5, 2);                         // hit: PFN_E
    end
  endtask

  // seq 7: the same re-walk shape changing the VGA class (PFN[19:5] == 5).
  task automatic seq_vga_class();
    begin
      flush_all(LIN_A);
      ins(LIN_A, PFN_OLD, 1'b1, 1'b0, 1'b0);
      idle(LIN_A, 1);                          // WINDOW
      idle(LIN_A, 1);                          // hit, not VGA
      flush_all(LIN_A);
      idle(LIN_A, 1);                          // miss
      ins(LIN_A, PFN_VGA, 1'b1, 1'b0, 1'b0);
      idle(LIN_A, 1);                          // WINDOW: pre-fix stale HIT, is_vga_mem = 0
      idle(LIN_A, 2);                          // hit, VGA class
    end
  endtask

  task automatic build_schedule();
    begin
      seq_cr3_rewalk();
      seq_invlpg_permissions();
      seq_replaced_vpn();
      seq_other_set_keeps_hit();
      seq_invlpg_other_set();
      seq_four_ways_evict();
      seq_vga_class();
    end
  endtask

  // ==========================================================================
  // ==== VERDICT ====
  // ==========================================================================
  initial begin
    build_schedule();
    reset_n = 0;
    repeat (4) @(negedge clk);
    reset_n = 1;
    // Cycle 0 is the schedule's own first entry (a flush or an idle); every
    // later cycle is checked as it comes into force.
    while (k < nsteps - 1) begin
      @(posedge clk);
      #1;
      check_cycle();
    end

    // The bench may not pass vacuously: the window must really have been driven,
    // and the stale word must really have been wrong in some of them (that is
    // the shape the pre-guard RTL fails on).
    if (wnd_cycles < 8) begin
      errors = errors + 1;
      $display("FAIL [tlb-window] only %0d windows driven: the stimulus stopped reaching the window",
               wnd_cycles);
    end
    if (oracle_wrong < 3) begin
      errors = errors + 1;
      $display("FAIL [tlb-window] only %0d window cycles where the stale word is WRONG: the stimulus no longer reaches the bug",
               oracle_wrong);
    end

    if (errors != 0) begin
      $display("TB_PC9821_Z486_TLB_WINDOW: FAIL (%0d mismatches)", errors);
      $fatal(1, "the registered TLB port handed back a stale translation");
    end
    $display("z486_tlb_window: %0d cycles, %0d window cycles, %0d refused in the window, %0d answered in the window, %0d of the windows would have answered with a stale frame",
             nsteps, wnd_cycles, wnd_cycles - wnd_hits, wnd_hits, oracle_wrong);
    $display("TB_PC9821_Z486_TLB_WINDOW: PASS");
    $finish;
  end
endmodule

`default_nettype wire
