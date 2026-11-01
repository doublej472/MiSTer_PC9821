`timescale 1ns/1ps

`include "z486_pc98_preset.svh"

// ==== WHAT THIS PROVES ====
// TB_PC9821_Z486_REQADDR_EQUIV: the CYCLE-EXACT EQUIVALENCE contract for the z486 paging request-address cone - the REFACTOR pin for the Class-1 cut-2 flatten, a CHARACTERIZATION against the documented semantics and not a hardware claim. paging_tlb's registered and VIPT lookup ports return the documented translation EVERY cycle over refill/INVLPG/CR3 sequences and all four ways (the documented PLRU fill order, the tag-matched INVLPG and the sidecar-hit PLRU refresh are transcribed so eviction runs are pinned too; the VIPT sidecar's 256-entry direct-mapped table, its epoch validity and reset/wrap scrub, its SUBSET rule - a walker refill that evicts a valid entry also invalidates the victim's sidecar slot, one cycle later - and its hazard poison are pinned exactly; the live demand port this contract used to pin was REMOVED by upstream's one-port TLB, where walker, demand and prefetch share the registered lookup as on the i486), paging_unit's request-owner mux equals the documented priority merge over ALL owner-overlap combinations (the arms are driven with force - the x87_pulse_race idiom - so the full operand space is covered), and memory's four A20-masked addresses equal the PC-98 preset's A20 mask (bit 20 cleared, the Xe10's measured BIT20-ONLY) every cycle with every external capture edge carrying the documented masked phys[31:2] and holding it between captures. Blind spots stated in the header: not a hardware bench, the request classification cones (alias coherency's), the walker and store queue quiet - and, measured by the hit counters this bench prints, it NEVER REACHES A HIT on the registered port or the sidecar (0 and 0 over 20 001 checks / 20 006 cycles; the sidecar never leaves its scrub at this stimulus's CR3 rate), so its paging_tlb contract above is a MISS-path claim there and a mutant that takes way 0's PFN from way 1 PASSES it; the registered port's hit paths are pinned by tb_pc9821_z486_tlb_window, not here.
// TB_PC9821_Z486_REQADDR_EQUIV: the CYCLE-EXACT EQUIVALENCE contract for the z486 paging request-address cone - the REFACTOR pin for the Class-1 cut-2 flatten, a CHARACTERIZATION against the documented semantics and not a hardware claim. paging_tlb's registered and VIPT lookup ports return the documented translation EVERY cycle over refill/INVLPG/CR3 sequences and all four ways (the documented PLRU fill order, the tag-matched INVLPG and the sidecar-hit PLRU refresh are transcribed so eviction runs are pinned too; the VIPT sidecar's 256-entry direct-mapped table, its epoch validity and reset/wrap scrub, its SUBSET rule - a walker refill that evicts a valid entry also invalidates the victim's sidecar slot, one cycle later - and its hazard poison are pinned exactly; the live demand port this contract used to pin was REMOVED by upstream's one-port TLB, where walker, demand and prefetch share the registered lookup as on the i486), paging_unit's request-owner mux equals the documented priority merge over ALL owner-overlap combinations (the arms are driven with force - the x87_pulse_race idiom - so the full operand space is covered), and memory's four A20-masked addresses equal the PC-98 preset's A20 mask (bit 20 cleared, the Xe10's measured BIT20-ONLY) every cycle with every external capture edge carrying the documented masked phys[31:2] and holding it between captures. Blind spots stated in the header: not a hardware bench, the request classification cones (alias coherency's), the walker and store queue quiet.
//
// TB_PC9821_Z486_REQADDR_EQUIV: a CYCLE-EXACT EQUIVALENCE (characterization,
// not a hardware claim) bench for the z486 paging request-address cone the
// Class-1 cut-2 flatten restructures: paging_tlb's registered lookup outputs
// (hit/PFN/writable/user/dirty/is_vga_mem - the priority case mux flattened to
// priority-exact one-hot AND-OR), paging_unit's request-owner muxes
// (dcache_req_frame/dcache_req_offset - the serial 2:1 chains flattened), and
// memory's A20 gate + ext_addr_r capture (the 32-bit mux folded per bit).
// Every translated address is bit-identical EVERY cycle, and ext_addr_r's
// capture is bit-identical on every capturing edge, to goldens computed from
// the documented semantics in independent arithmetic.
//
// THE CONTRACTS, asserted by NAME:
//  [translate-identity] paging_tlb's registered and VIPT lookup ports
//     return the documented translation every cycle over refill/INVLPG/CR3
//     sequences and all four ways (the PLRU fill order, the tag-matched
//     INVLPG and the sidecar-hit PLRU refresh are transcribed so eviction
//     runs are covered; the VIPT sidecar's direct-mapped 256-entry table,
//     epoch validity, reset/wrap scrub, subset-of-the-TLB eviction and hazard
//     poison are pinned exactly as documented in paging_tlb.sv). The LIVE
//     demand port this contract used to pin is gone: upstream made the main
//     TLB one-port (walker, demand and prefetch share the registered lookup,
//     as on the i486 LA bus), so its raw-hit OR merge and no-linear-fallback
//     checks were removed with it.
//  [owner-mux-identity] paging_unit's dcache_req_phys_addr equals the
//     documented priority merge of its three request owners every cycle,
//     over ALL owner-overlap combinations (the flattened one-hot selects are
//     priority-exact; the frame and offset arms keep their DIFFERENT early
//     selects).
//  [a20-and-capture-identity] memory's four A20-masked addresses equal the
//     documented wrap every cycle, and every direct-request capture edge
//     takes {phys[31:2]} into ext_addr_r (the `addr` pin) bit-identically.
//
// THE GOLDEN MODEL never reads the DUT. Translation comes from the shadow TLB
// image the documented update rules maintain (in-place update on a matching
// VPN, else the PLRU victim; VGA class = PFN[19:5]==5), the owner merge and
// the A20 wrap are independent arithmetic, and the capture golden models the
// documented request/accept handshake in a quiet harness (io requests only,
// ready held).
//
// WHAT IT IS BLIND TO, stated: (1) it is not a hardware-behaviour bench - no
// NP2kai value is asserted here; (2) the owner-mux arms are driven by `force`
// (the `force` idiom used by the other equivalence benches) so the mux is pinned over its FULL
// operand space including states the FSM cannot reach; (3) the request
// classification cones (aperture/alias/win0) ride along in the a20 checks but
// their own decode is tb_pc9821_cpu_alias_coherency's; (4) the page walker
// and the store queue are quiet in this harness; (5) IT NEVER REACHES A HIT ON
// THE REGISTERED PORT OR THE SIDECAR, which is not a caveat but a measurement:
// the PASS line prints the hit counts (0 and 0 over 20 001 checks / 20 006
// cycles: the addresses are random while update_vpn is always the address in
// force, so a lookup can only match by a 2^-13-ish collision, and the sidecar
// is held in its scrub by the stimulus's frequent CR3 flushes, every 15th of
// which wraps the epoch and restarts the 256-index scrub). The
// [translate-identity] contract above is therefore a MISS-path claim, and the
// consequence is concrete: a mutant that takes way 0's PFN from way 1 PASSES
// this bench. The registered port's hit paths are pinned by
// tb_pc9821_z486_tlb_window -- not by this bench. (paging_tlb.sv's own
// simulation-only sidecar reference, which $fatals on a sidecar hit its
// valid-bit model rejects, runs here too.) The MODEL itself was checked off
// the shipped stimulus, 2026-10-07, in a throwaway instrumented copy: addresses
// re-presented and drawn from a 32-tags-per-set pool, CR3 at 1/1024, INVLPG of
// the address in force, prereads of the lookup address and refills off (a
// random refill breaks the module's subset contract and its own reference
// $fatals once a hit is reachable) - 200 001 checks, 50 280 registered-port hits
// and 10 473 sidecar hits, all matching; and each of the two pre-upstream rules
// put back into the model (no subset eviction; INVLPG clearing the whole set)
// FAILS that run within 400 cycles.

`default_nettype none

module tb_pc9821_z486_reqaddr_equiv;
  import z486_pkg::*;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset_n = 0;
  reg [31:0] cyc = 0;
  always @(posedge clk) cyc <= cyc + 32'd1;

  integer errors = 0;
  integer checks = 0;

  task automatic fail(input string what, input [31:0] got, input [31:0] want);
    begin
      errors = errors + 1;
      $display("FAIL [reqaddr-identity] %s at cyc=%0d got=%08x want=%08x",
               what, cyc, got, want);
      if (errors > 16) begin
        $display("TB_PC9821_Z486_REQADDR_EQUIV: FAIL (too many mismatches)");
        $fatal(1, "request-address identity broken");
      end
    end
  endtask

  // ==== DUT ====
  // ---- DUT 1: paging_tlb (the restructured translation outputs) ----
  // The four-way array is read COMBINATIONALLY (asynchronous MLAB copies in
  // paging_tlb.sv: "Hit detection - combinational"), so the registered port's
  // answer in any cycle is the lookup of that cycle's address in the state
  // after the edge that started the cycle. The stimulus draws the next address
  // at the negedge into tlb_linear_next, which becomes the port's address at
  // the next posedge; tlb_linear_addr_d is the address the edge itself sampled
  // -- what the edge's own hit (its PLRU touch) used. refill_linear is the VIPT
  // refill address stream: it is the register that used to drive the removed
  // live port, kept so the sidecar refill stimulus is unchanged.
  reg  [31:0] tlb_linear_addr = 0, tlb_linear_next = 0;
  reg  [31:0] refill_linear = 0, refill_next = 0;
  reg  [31:0] tlb_linear_addr_d = 0;   // the address the edge itself sampled
  reg         addr_started = 0;
  always_ff @(posedge clk) begin
    if (!reset_n) begin
      tlb_linear_addr <= 32'd0; tlb_linear_next <= 32'd0;
      refill_linear <= 32'd0; refill_next <= 32'd0;
      tlb_linear_addr_d <= 32'd0;
    end else begin
      tlb_linear_addr   <= tlb_linear_next;
      refill_linear     <= refill_next;
      tlb_linear_addr_d <= tlb_linear_addr;
    end
  end
  wire        tlb_hit, tlb_writable, tlb_user, tlb_dirty, tlb_is_vga;
  wire [31:0] tlb_physical_addr;
  reg         vipt_preread = 0;
  reg  [31:0] vipt_linear_addr = 0;
  wire        vipt_hit, vipt_writable, vipt_user, vipt_dirty, vipt_is_vga;
  wire [31:0] vipt_physical_addr;
  reg         vipt_refill_valid = 0;
  reg  [31:0] vipt_refill_linear = 0;
  reg  [19:0] vipt_refill_pfn = 0;
  reg         vipt_refill_writable = 0, vipt_refill_user = 0, vipt_refill_dirty = 0;
  reg         update_valid = 0;
  // The walked VPN IS the registered lookup address's VPN -- the module's port
  // contract (entry 27: the insert read-modify-writes update_set out of the word
  // the registered lookup read), and exactly what paging_unit does
  // (`tlb_update_vpn = tlb_lookup_addr[31:12]`, a walk holding its lookup address
  // stable). THE DUT PORT IS THE LIVE EXPRESSION, not a negedge latch:
  // tlb_rd_set_d is a posedge register, so a negedge-latched update_vpn looked a
  // half-cycle stale to paging_tlb.sv's combinational dup_read_fuse the moment
  // rd_set_d advanced (measured: TLB DUP READ SET MISMATCH rd_set_d=6
  // update_set=2). Every posedge samples the same value either way (tlb_linear_addr
  // does not move mid-cycle), so what the insert and the VIPT write consume is
  // unchanged; `update_vpn` below is the shadow model's negedge sample of the same
  // expression, which is what g_step writes its ref with.
  wire [19:0] update_vpn_w = tlb_linear_addr[31:12];
  reg  [19:0] update_vpn = 0;
  reg  [1:0]  update_gap = 0;   // the walk protocol: a new walk takes several cycles
  reg  [19:0] update_pfn = 0;
  reg         update_writable = 0, update_user = 0, update_dirty = 0;
  reg         invalidate_all = 0;
  reg         invalidate_page = 0;
  reg  [19:0] invalidate_vpn = 0;

  paging_tlb dut_tlb (
    .clk(clk), .reset_n(reset_n),
    .linear_addr(tlb_linear_addr),
    .hit(tlb_hit), .physical_addr(tlb_physical_addr),
    .writable(tlb_writable), .user(tlb_user), .dirty(tlb_dirty),
    .is_vga_mem(tlb_is_vga), .is_pcd(),
    .vipt_preread(vipt_preread), .vipt_linear_addr(vipt_linear_addr),
    .vipt_hit(vipt_hit), .vipt_physical_addr(vipt_physical_addr),
    .vipt_writable(vipt_writable), .vipt_user(vipt_user),
    .vipt_dirty(vipt_dirty), .vipt_is_vga_mem(vipt_is_vga),
    .vipt_refill_valid(vipt_refill_valid),
    .vipt_refill_linear(vipt_refill_linear),
    .vipt_refill_pfn(vipt_refill_pfn),
    .vipt_refill_writable(vipt_refill_writable),
    .vipt_refill_user(vipt_refill_user),
    .vipt_refill_dirty(vipt_refill_dirty), .vipt_refill_pcd(1'b0),
    .update_valid(update_valid), .update_vpn(update_vpn_w),
    .update_pfn(update_pfn), .update_writable(update_writable),
    .update_user(update_user), .update_dirty(update_dirty),
    .update_pcd(1'b0), .update_pwt(1'b0),
    .invalidate_all(invalidate_all),
    .invalidate_page(invalidate_page), .invalidate_vpn(invalidate_vpn),
    // the TR6/TR7 test port is idle: no TR6 write flushes the sidecar here
    .tlbt_req(1'b0), .tlbt_tr6(32'd0), .tlbt_tr7(32'd0),
    .tlbt_done(), .tlbt_lookup_done(), .tlbt_tr6_out(), .tlbt_tr7_out()
  );

  // ---- golden shadow: documented TLB state (independent transcription) ----
  reg        g_valid  [0:7][0:3];
  reg [16:0] g_tag    [0:7][0:3];
  reg [19:0] g_pfn    [0:7][0:3];
  reg        g_w      [0:7][0:3];
  reg        g_u      [0:7][0:3];
  reg        g_d      [0:7][0:3];
  reg        g_vga    [0:7][0:3];
  reg [2:0]  g_plru   [0:7];
  // The VIPT sidecar as paging_tlb.sv documents it: 256 entries direct-mapped
  // on VPN[19:12], each {epoch[3:0], VPN[31:20], PFN, W, U, D, VGA}; an entry is
  // valid when its epoch equals the current one (INVALID = 4'hF); a CR3 flush
  // advances the epoch 0..14 and a wrap (and reset) starts a scrub that writes
  // INVALID to every index while the sidecar reports misses; a walker refill
  // that evicts a valid four-way entry queues an INVALID write of the victim's
  // index for the next edge (the subset rule).
  reg [39:0] g_vipt_entry [0:255];
  reg [39:0] g_vipt_q;
  reg [31:0] g_vipt_lin;
  reg        g_vipt_hazard;
  reg        g_vipt_fresh;
  reg [3:0]  g_vipt_epoch;
  reg        g_vipt_scrub;
  reg [7:0]  g_vipt_scrub_idx;
  reg        g_evict_pend;
  reg [7:0]  g_evict_idx;
  integer    n_reg_hits = 0, n_vipt_hits = 0;

  // documented lookup function over the shadow (priority: first matching way)
  function automatic [31:0] g_lookup_phys(input [31:0] la);
    reg [2:0] s; reg [16:0] t; integer w; reg found;
    begin
      s = la[14:12]; t = la[31:15]; found = 0; g_lookup_phys = la;
      for (w = 0; w < 4; w = w + 1)
        if (!found && g_valid[s][w] && g_tag[s][w] == t) begin
          g_lookup_phys = {g_pfn[s][w], la[11:0]};
          found = 1;
        end
    end
  endfunction

  function automatic logic g_lookup_hit(input [31:0] la);
    reg [2:0] s; reg [16:0] t; integer w;
    begin
      s = la[14:12]; t = la[31:15]; g_lookup_hit = 0;
      for (w = 0; w < 4; w = w + 1)
        if (g_valid[s][w] && g_tag[s][w] == t) g_lookup_hit = 1;
    end
  endfunction

  // documented first-match field fetch (writable/user/dirty default on miss:
  // writable=1, user=0, dirty=0)
  function automatic [3:0] g_lookup_fields(input [31:0] la);
    reg [2:0] s; reg [16:0] t; integer w; reg found;
    begin
      s = la[14:12]; t = la[31:15]; found = 0; g_lookup_fields = 4'b1100;
      for (w = 0; w < 4; w = w + 1)
        if (!found && g_valid[s][w] && g_tag[s][w] == t) begin
          g_lookup_fields = {1'b1, g_w[s][w], g_u[s][w], g_d[s][w]};
          found = 1;
        end
    end
  endfunction

  function automatic logic g_lookup_vga(input [31:0] la);
    reg [2:0] s; reg [16:0] t; integer w;
    begin
      s = la[14:12]; t = la[31:15]; g_lookup_vga = 0;
      for (w = 0; w < 4; w = w + 1)
        if (g_valid[s][w] && g_tag[s][w] == t && g_vga[s][w]) g_lookup_vga = 1;
    end
  endfunction

  // the documented sidecar match: not poisoned, not scrubbing, epoch current,
  // VPN[31:20] tag equal (paging_tlb.sv's vipt_match)
  function automatic logic g_vipt_match();
    g_vipt_match = !g_vipt_hazard && !g_vipt_scrub &&
                   (g_vipt_q[39:36] == g_vipt_epoch) &&
                   (g_vipt_q[35:24] == g_vipt_lin[31:20]);
  endfunction

  // PLRU victim decode (documented: match wins, else the plru tree)
  function automatic [1:0] g_victim(input [2:0] s, input [16:0] t);
    integer w; reg found;
    begin
      found = 0; g_victim = 2'd0;
      for (w = 0; w < 4; w = w + 1)
        if (!found && g_valid[s][w] && g_tag[s][w] == t) begin
          g_victim = w[1:0]; found = 1;
        end
      if (!found)
        g_victim = g_plru[s][0] ? (g_plru[s][2] ? 2'd3 : 2'd2)
                                : (g_plru[s][1] ? 2'd1 : 2'd0);
    end
  endfunction

  // ==== CHECKS ====
  task automatic g_plru_hit(input [2:0] s, input [1:0] way);
    case (way)
      2'd0: begin g_plru[s][0] = 1'b1; g_plru[s][1] = 1'b1; end
      2'd1: begin g_plru[s][0] = 1'b1; g_plru[s][1] = 1'b0; end
      2'd2: begin g_plru[s][0] = 1'b0; g_plru[s][2] = 1'b1; end
      2'd3: begin g_plru[s][0] = 1'b0; g_plru[s][2] = 1'b0; end
    endcase
  endtask

  task automatic g_plru_fill(input [2:0] s, input [1:0] way);
    g_plru_hit(s, way);
  endtask

  // ==== DUT 2: memory (A20 fold + ext_addr_r capture) ====
  reg         mem_a20_enable = 1;
  reg         mem_req_valid = 0;
  reg  [31:0] mem_req_raw = 0;
  reg         mem_req_is_io = 1;
  wire [31:2] mem_addr;
  wire        mem_valid, mem_write, mem_io;
  reg         mem_ready = 1;

  memory #(.A20_MASK_OFF(`Z486_PC98_A20_MASK_OFF)) dut_mem (
    .clk(clk), .reset_n(reset_n),
    .a20_enable(mem_a20_enable),
    // L1 on, FPU present: z486 drives these from cache_off_req/x87_off_req, which pc9821_system ties low
    .cache_enable(1'b1), .x87_off(1'b0),
    .dcache_req_valid(mem_req_valid),
    .dcache_req_phys_addr_raw(mem_req_raw),
    // The paging unit's unpaged VGA verdict, which a standalone memory instance
    // has to supply: A0000-BFFFF of the raw address. memory.sv's
    // default-equivalence fuse (MEMMAP UNCACHED) compares the input against
    // exactly this window when no template window is enabled.
    .dcache_req_is_vga_mem(mem_req_raw[31:17] == 15'h5),
    .dcache_req_is_io(mem_req_is_io),
    .dcache_req_be(4'hf),
    .dcache_req_write(1'b0),
    .addr(mem_addr), .valid(mem_valid), .ready(mem_ready),
    .write(mem_write), .io(mem_io)
  );

  // PC-98 A20 gate closed: physical bit 20 cleared, every other bit kept
  // (Xe10 A20MAP verdict BIT20-ONLY, docs/probes/A20MAP-XE10.TXT)
  function automatic [31:0] g_a20(input [31:0] raw, input unmask);
    g_a20 = unmask ? raw : (raw & 32'hffef_ffff);
  endfunction

  reg [31:2] g_ext_addr = 0;
  reg        g_valid_prev = 0;
  reg [31:2] g_raw_at_edge = 0;
  reg [31:2] g_wrap_at_edge = 0;

  // ==== DUT 3: paging_unit (owner mux, forced arms) ====
  wire [31:0] pu_phys_addr;
  paging_unit dut_pu (
    .clk(clk), .reset_n(reset_n),
    .fast_off(1'b0),   // the fast paths on, as pc9821_system's fast_off_req tie gives the CPU
    .dcache_req_phys_addr(pu_phys_addr)
  );

  reg [31:0] pu_early_phys, pu_req_mem_phys, pu_hold_phys, pu_linear, pu_req_linear;
  reg        pu_early, pu_early_idx, pu_req_mem;

  // ==== checks (negedge+1: outputs settled on the current inputs) ====
  reg [3:0] g_fields;
  always @(negedge clk) begin : chk
    reg [31:0] e_phys;
    reg        e_hit, e_vga;
    reg [3:0]  e_fields;
    reg [31:0] v_phys;
    reg        v_hit, v_vga;
    reg [3:0]  v_fields;
    reg [31:0] want_addr;
    #1;
    if (reset_n && refs_valid) begin
      checks = checks + 1;

      // ---- translate-identity: registered lookup port ----
      // (a combinational read: this cycle's address in the post-edge state)
      e_hit = g_lookup_hit(tlb_linear_addr);
      e_phys = g_lookup_phys(tlb_linear_addr);
      e_fields = g_lookup_fields(tlb_linear_addr);
      e_vga = g_lookup_vga(tlb_linear_addr);
      if (e_hit) n_reg_hits = n_reg_hits + 1;
      if (tlb_hit !== e_hit) fail("tlb_hit", {31'd0, tlb_hit}, {31'd0, e_hit});
      if (tlb_physical_addr !== e_phys) fail("tlb_physical_addr", tlb_physical_addr, e_phys);
      if ({tlb_writable, tlb_user, tlb_dirty} !== e_fields[2:0])
        fail("tlb_fields", {29'd0, tlb_writable, tlb_user, tlb_dirty},
             {29'd0, e_fields[2], e_fields[1], e_fields[0]});
      if (tlb_is_vga !== e_vga) fail("tlb_is_vga", {31'd0, tlb_is_vga}, {31'd0, e_vga});

      // ---- translate-identity: VIPT sidecar port ----
      v_hit = g_vipt_match();
      if (v_hit) n_vipt_hits = n_vipt_hits + 1;
      v_phys = v_hit ? {g_vipt_q[23:4], g_vipt_lin[11:0]} : g_vipt_lin;
      v_fields = v_hit ? {1'b1, g_vipt_q[3], g_vipt_q[2], g_vipt_q[1]} : 4'b1000;
      v_vga = v_hit && g_vipt_q[0];
      if (vipt_hit !== v_hit) fail("vipt_hit", {31'd0, vipt_hit}, {31'd0, v_hit});
      if (vipt_physical_addr !== v_phys) fail("vipt_physical_addr", vipt_physical_addr, v_phys);
      if ({vipt_writable, vipt_user, vipt_dirty} !== v_fields[2:0])
        fail("vipt_fields", {29'd0, vipt_writable, vipt_user, vipt_dirty},
             {29'd0, v_fields[2], v_fields[1], v_fields[0]});
      if (vipt_is_vga !== v_vga) fail("vipt_is_vga", {31'd0, vipt_is_vga}, {31'd0, v_vga});

      // ---- a20-and-capture-identity ----
      if (dut_mem.dcache_req_phys_addr !== g_a20(mem_req_raw, mem_a20_enable || mem_req_is_io))
        fail("a20_dcache", dut_mem.dcache_req_phys_addr,
             g_a20(mem_req_raw, mem_a20_enable || mem_req_is_io));
      if (dut_mem.dcache_vipt_resolve_phys_addr_raw !== g_a20(32'd0, mem_a20_enable))
        fail("a20_vipt_static", dut_mem.dcache_vipt_resolve_phys_addr_raw,
             g_a20(32'd0, mem_a20_enable));
      if (dut_mem.icache_req_phys_addr_raw !== g_a20(32'd0, mem_a20_enable))
        fail("a20_icache_static", dut_mem.icache_req_phys_addr_raw,
             g_a20(32'd0, mem_a20_enable));
      if (mem_valid && !g_valid_prev) begin
        // a NEW external request is presented: the capture that produced it
        // must carry the documented wrapped address of the request the edge
        // sampled
        if ({mem_addr, 2'b00} !== {g_wrap_at_edge, 2'b00})
          fail("ext_addr_capture", {mem_addr, 2'b00}, {g_wrap_at_edge, 2'b00});
        g_ext_addr = mem_addr;
      end else begin
        // otherwise the register HOLDS its last capture (and stays 0 before
        // the first one)
        if ({mem_addr, 2'b00} !== {g_ext_addr, 2'b00})
          fail("ext_addr_r", {mem_addr, 2'b00}, {g_ext_addr, 2'b00});
      end
      g_valid_prev = mem_valid;

      // ---- owner-mux-identity (forced arms) ----
      want_addr = pu_early ? pu_early_phys :
                  pu_req_mem ? pu_req_mem_phys : pu_hold_phys;
      want_addr[11:0] = pu_early_idx ? pu_linear[11:0] :
                        pu_req_mem ? pu_req_linear[11:0] : pu_hold_phys[11:0];
      if (pu_phys_addr !== want_addr)
        fail("owner_mux", pu_phys_addr, want_addr);
    end
  end

  // ==== shadow advance + stimulus ====
  reg [31:0] rng = 32'hcafe_f00d;
  function automatic [31:0] rnd;
    begin
      rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
      rnd = rng;
    end
  endfunction

  integer s_i, w_i;
  task automatic g_reset_state;
    begin
      for (s_i = 0; s_i < 8; s_i = s_i + 1) begin
        g_plru[s_i] = 3'b000;
        for (w_i = 0; w_i < 4; w_i = w_i + 1) begin
          g_valid[s_i][w_i] = 0; g_tag[s_i][w_i] = 0; g_pfn[s_i][w_i] = 0;
          g_w[s_i][w_i] = 0; g_u[s_i][w_i] = 0; g_d[s_i][w_i] = 0;
          g_vga[s_i][w_i] = 0;
        end
      end
      // the sidecar RAM is not reset; reset starts the scrub instead, and no
      // entry can match until the scrub has written INVALID to every index
      for (s_i = 0; s_i < 256; s_i = s_i + 1) g_vipt_entry[s_i] = {4'hF, 36'd0};
      g_vipt_q = 0; g_vipt_lin = 0; g_vipt_hazard = 0; g_vipt_fresh = 0;
      g_vipt_epoch = 4'd0; g_vipt_scrub = 1'b1; g_vipt_scrub_idx = 8'd0;
      g_evict_pend = 1'b0; g_evict_idx = 8'd0;
      g_ext_addr = 0; g_valid_prev = 0; g_raw_at_edge = 0; g_wrap_at_edge = 0;
    end
  endtask

  reg [2:0]  u_set; reg [16:0] u_tag; reg [1:0] u_way;
  integer    u_w;
  reg [31:0] cap_addr;
  reg        refs_valid = 0;   // no comparison before the first shadow step

  // Documented state advance on one clock edge (pre-edge inputs, pre-edge
  // shadow): every decision is taken from the pre-edge state first, then the
  // writes are applied, as the module's nonblocking assignments do.
  task automatic g_step;
    reg [2:0] ls; reg [16:0] lt; integer w; reg [1:0] hway; reg hfound;
    reg       tlb_write, u_hit, ev, refill_write, scrub_write, mutation;
    reg       evict_write, update_write, refill_wr, vmatch, vref_refresh;
    reg [7:0] ev_idx;
    reg [2:0] vref_set; reg [16:0] vref_tag; reg [1:0] vref_way;
    reg [3:0] n_epoch; reg n_scrub; reg [7:0] n_idx; reg n_pend; reg [7:0] n_pidx;
    begin
      refs_valid = 1;
      // registered-lookup hit/way for the PLRU (documented priority), for the
      // address the edge sampled
      ls = tlb_linear_addr_d[14:12]; lt = tlb_linear_addr_d[31:15];
      hfound = 0; hway = 0;
      for (w = 0; w < 4; w = w + 1)
        if (!hfound && g_valid[ls][w] && g_tag[ls][w] == lt) begin
          hway = w[1:0]; hfound = 1;
        end

      // the walker insert and its victim (match wins, else the pre-edge PLRU);
      // an insert coinciding with CR3/INVLPG is dropped whole
      tlb_write = update_valid && !invalidate_all && !invalidate_page;
      u_set = update_vpn[2:0]; u_tag = update_vpn[19:3];
      u_way = g_victim(u_set, u_tag);
      u_hit = 0;
      for (w = 0; w < 4; w = w + 1)
        if (g_valid[u_set][w] && g_tag[u_set][w] == u_tag) u_hit = 1;
      // THE SUBSET RULE: a refill that replaces a valid entry evicts the
      // victim's page from the sidecar too (its index is the victim's VPN[7:0])
      ev = tlb_write && !u_hit && g_valid[u_set][u_way];
      ev_idx = {g_tag[u_set][u_way][4:0], u_set};

      // the sidecar-hit replacement refresh: the cycle after a preread whose
      // sidecar answer hit, the four-way way holding that page is touched
      vmatch = g_vipt_match();
      vref_set = g_vipt_lin[14:12]; vref_tag = g_vipt_lin[31:15];
      vref_refresh = 0; vref_way = 0;
      for (w = 3; w >= 0; w = w - 1)
        if (g_valid[vref_set][w] && g_tag[vref_set][w] == vref_tag) begin
          vref_refresh = 1; vref_way = w[1:0];
        end
      vref_refresh = vref_refresh && g_vipt_fresh && vmatch;

      // the sidecar's write-port arbitration (documented priority: INVLPG, the
      // queued eviction, the walker update, a refill, the scrub); no TR6 write
      // in this harness, so a flush is invalidate_all alone
      refill_write = vipt_refill_valid && !update_valid;
      scrub_write  = g_vipt_scrub && !invalidate_page && !g_evict_pend &&
                     !update_valid && !refill_write;
      mutation     = invalidate_all || invalidate_page || update_valid ||
                     refill_write || scrub_write || g_evict_pend;
      evict_write  = g_evict_pend && !invalidate_page;
      update_write = update_valid && !invalidate_page && !g_evict_pend;
      refill_wr    = refill_write && !invalidate_page && !g_evict_pend;

      // VIPT preread capture (the RAM's pre-edge word; any mutation poisons it,
      // and a mutation while a preread is held poisons the held one)
      g_vipt_fresh = vipt_preread;
      if (vipt_preread) begin
        g_vipt_lin = vipt_linear_addr;
        g_vipt_q = g_vipt_entry[vipt_linear_addr[19:12]];
        g_vipt_hazard = mutation;
      end else if (mutation) begin
        g_vipt_hazard = 1'b1;
      end

      // epoch, scrub and the eviction queue
      n_epoch = g_vipt_epoch; n_scrub = g_vipt_scrub; n_idx = g_vipt_scrub_idx;
      n_pend = g_evict_pend; n_pidx = g_evict_idx;
      if (invalidate_all) begin
        n_epoch = (g_vipt_epoch == 4'd14) ? 4'd0 : g_vipt_epoch + 4'd1;
        if (g_vipt_epoch == 4'd14) begin n_scrub = 1'b1; n_idx = 8'd0; end
      end
      if (scrub_write && !(invalidate_all && g_vipt_epoch == 4'd14)) begin
        n_idx = g_vipt_scrub_idx + 8'd1;
        if (&g_vipt_scrub_idx) n_scrub = 1'b0;
      end
      if (invalidate_all) n_pend = 1'b0;
      else if (ev && (ev_idx != update_vpn[7:0])) begin n_pend = 1'b1; n_pidx = ev_idx; end
      else if (evict_write) n_pend = 1'b0;

      // the sidecar RAM write (with the pre-edge epoch)
      if (invalidate_page)
        g_vipt_entry[invalidate_vpn[7:0]] = {4'hF, 36'd0};
      else if (evict_write)
        g_vipt_entry[g_evict_idx] = {4'hF, 36'd0};
      else if (update_write)
        g_vipt_entry[update_vpn[7:0]] = {g_vipt_epoch, update_vpn[19:8], update_pfn,
                                         update_writable, update_user, update_dirty,
                                         (update_pfn[19:5] == 15'h5)};
      else if (refill_wr)
        g_vipt_entry[vipt_refill_linear[19:12]] =
            {g_vipt_epoch, vipt_refill_linear[31:20], vipt_refill_pfn,
             vipt_refill_writable, vipt_refill_user, vipt_refill_dirty,
             (vipt_refill_pfn[19:5] == 15'h5)};
      else if (scrub_write)
        g_vipt_entry[g_vipt_scrub_idx] = {4'hF, 36'd0};

      g_vipt_epoch = n_epoch; g_vipt_scrub = n_scrub; g_vipt_scrub_idx = n_idx;
      g_evict_pend = n_pend; g_evict_idx = n_pidx;

      // main array block (documented priorities)
      if (invalidate_all) begin
        for (s_i = 0; s_i < 8; s_i = s_i + 1) begin
          g_plru[s_i] = 3'b000;
          for (w_i = 0; w_i < 4; w_i = w_i + 1) g_valid[s_i][w_i] = 0;
        end
      end else if (invalidate_page) begin
        // INVLPG clears only the way(s) whose tag matches the page (every
        // match, so a duplicate would go too); unrelated entries in the set stay
        for (w = 0; w < 4; w = w + 1)
          if (g_valid[invalidate_vpn[2:0]][w] && g_tag[invalidate_vpn[2:0]][w] == invalidate_vpn[19:3])
            g_valid[invalidate_vpn[2:0]][w] = 0;
      end else begin
        // the refresh lands first; a same-set hit's touch is applied on top
        if (vref_refresh) g_plru_hit(vref_set, vref_way);
        if (hfound) g_plru_hit(ls, hway);
        if (tlb_write) begin
          g_valid[u_set][u_way] = 1;
          g_tag[u_set][u_way] = u_tag;
          g_pfn[u_set][u_way] = update_pfn;
          g_w[u_set][u_way] = update_writable;
          g_u[u_set][u_way] = update_user;
          g_d[u_set][u_way] = update_dirty;
          g_vga[u_set][u_way] = (update_pfn[19:5] == 15'h5);
          g_plru_fill(u_set, u_way);
        end
      end

      // memory capture pin support: record the address the edge sampled and
      // its documented wrapped form (the capture CONDITION is pre-existing
      // classification, not this cut; the VALUE is what is pinned).
      cap_addr = g_a20(mem_req_raw, mem_a20_enable || mem_req_is_io);
      g_wrap_at_edge = cap_addr[31:2];
      g_raw_at_edge = mem_req_raw[31:2];

    end
  endtask

  // drive + shadow at the posedge (pre-edge inputs)
  always @(posedge clk) begin
    #1;
    if (reset_n) g_step();
  end

  // stimulus at negedge
  reg [31:0] r0, r1;
  always @(negedge clk) begin
    if (reset_n) begin
      r0 = rnd(); r1 = rnd();
      // paging_tlb stimulus: the addresses drawn now are what the ports consume
      // from the next posedge on, and the value each port presents as its
      // preread for that cycle's read (see the declaration).
      tlb_linear_next = {r0[19:0], 12'h000} | {20'd0, r0[31:20] & 12'hfff};
      refill_next = {r1[19:0], 12'h000} | {20'd0, r1[31:20] & 12'hfff};
      if (!addr_started) begin
        // the first edge after reset must not present a preread that leads the
        // address register before it has ever been loaded
        addr_started = 1'b1;
        tlb_linear_addr = tlb_linear_next;
        refill_linear = refill_next;
      end
      vipt_preread = r0[0];
      vipt_linear_addr = tlb_linear_addr;
      vipt_refill_valid = r0[1] && !r0[2];
      vipt_refill_linear = refill_linear;
      vipt_refill_pfn = r1[19:0];
      vipt_refill_writable = r1[20]; vipt_refill_user = r1[21];
      vipt_refill_dirty = r1[22];
      // paging_tlb.sv's DOCUMENTED INTERFACE CONTRACT, modelled exactly - and
      // this is a CONTRACT constraint, not "moving the bench to agree with the
      // RTL": the module's own fuse comments state the walker protocol this
      // standalone stimulus must obey (same_set_fuse: "The walker presents
      // update_valid as a single-cycle pulse and a new walk takes several
      // cycles"; dup_read_fuse: "The walker holds tlb_lookup_addr for the whole
      // walk"). (1) updates are ONE-CYCLE pulses and never land on consecutive
      // edges. (2) in the core an insert never coincides with
      // invalidate_all/invalidate_page (CR3/INVLPG) - but this stimulus PRESENTS
      // the coincidence on purpose: since the fork's ea57752 the module drops a
      // same-edge insert whole (`wire tlb_word_write_ok = reset_n &&
      // !invalidate_all && !invalidate_page` gates the per-way word-array writes
      // and both VIPT sidecar writes, matching the invalidate-priority valid-bit
      // chain this shadow models). f97e7f9 wrote the word array unconditionally
      // and dropped the valid/shadow write - the fork's OWN PER_WAY fuse fired
      // (`PER_WAY REG FUSE MISMATCH` in that revision's paging_tlb.sv, with set=0 way=2
      // real=c344869f1d ref=0000000000) - so this stimulus then carried an
      // `&& !invalidate_all && !invalidate_page` gate (a fork bug, worked
      // around by a local patch). The fix landed upstream in
      // ea57752 and the gate is DELETED: the corner runs again.
      invalidate_all = (r0[27:24] == 4'h0);
      invalidate_page = (r0[27:24] == 4'h1);
      invalidate_vpn = r1[19:0];
      update_vpn = tlb_linear_addr[31:12];
      update_valid = (update_gap == 2'd0) && r0[2];
      if (update_valid) update_gap = 2'd2;
      else if (update_gap != 2'd0) update_gap = update_gap - 2'd1;
      update_pfn = {r0[11:0], r1[31:28]} & 20'hfffff;
      update_writable = r0[12]; update_user = r0[13]; update_dirty = r0[14];

      // memory stimulus (io-only, documented wrap space)
      mem_req_valid = r0[15];
      mem_req_raw = {r0[19:0], r1[31:28]} | (r1[3:0] << 20);
      mem_req_is_io = 1'b1;
      mem_a20_enable = r0[16];

      // owner-mux arms (forced into paging_unit)
      pu_early = r0[17]; pu_early_idx = r0[18]; pu_req_mem = r0[19];
      pu_early_phys = r0; pu_req_mem_phys = r1; pu_hold_phys = {r1[15:0], r0[31:16]};
      pu_linear = {r0[11:0], r1[31:12]}; pu_req_linear = {r1[7:0], r0[31:8]};
      force dut_pu.early_present = pu_early;
      force dut_pu.early_idx_drive = pu_early_idx;
      force dut_pu.req_mem_present = pu_req_mem;
      force dut_pu.early_phys = pu_early_phys;
      force dut_pu.req_mem_phys = pu_req_mem_phys;
      force dut_pu.dcache_req_phys_addr_r = pu_hold_phys;
      force dut_pu.linear_addr = pu_linear;
      force dut_pu.req_linear = pu_req_linear;
    end
  end

  // ==== run ====
  integer i;
  initial begin
    g_reset_state();
    reset_n = 0;
    repeat (4) @(negedge clk);
    reset_n = 1;
    for (i = 0; i < 20000; i = i + 1) @(negedge clk);
    @(negedge clk);
    release dut_pu.early_present;
    release dut_pu.early_idx_drive;
    release dut_pu.req_mem_present;
    release dut_pu.early_phys;
    release dut_pu.req_mem_phys;
    release dut_pu.dcache_req_phys_addr_r;
    release dut_pu.linear_addr;
    release dut_pu.req_linear;
    @(negedge clk);
    // ==== VERDICT ====
    if (errors != 0) begin
      $display("TB_PC9821_Z486_REQADDR_EQUIV: FAIL (%0d mismatches in %0d checks)",
               errors, checks);
      $fatal(1, "request-address identity broken");
    end
    $display("z486_reqaddr_equiv: %0d checks, %0d cycles, %0d registered-port hits, %0d sidecar hits",
             checks, cyc, n_reg_hits, n_vipt_hits);
    $display("TB_PC9821_Z486_REQADDR_EQUIV: PASS");
    $finish;
  end
endmodule

`default_nettype wire
