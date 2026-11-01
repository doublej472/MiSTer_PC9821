// z486_stub - the CPU's PORT SHELL for pc9821_system reset-seed benches.
//
// tests/pc9821/tb_pc9821_system_reset_seed checks the POWER-UP/RESET state of
// pc9821_system's own telemetry and line-response flops (its
// checks F6/F7). Those checks need a CPU that produces a KNOWN interrupt-acknowledge
// pattern and nothing else, and the real z486 tree cannot be elaborated in the
// 4-state simulator those checks are for (it uses `static` block lifetimes
// Icarus does not implement). So this stub replaces `z486` with the same port
// shell: every output is a constant except `inta`, which issues exactly two
// 2-cycle pulses a fixed number of clks after EVERY reset_n release (one
// "epoch"), so the bench can assert the INTA telemetry counter is exactly 2 per
// epoch and no pre-reset pulse is ever counted.
//
// This module is TEST SCAFFOLDING ONLY - it is never part of a shipped build.

`default_nettype none

module z486 #(
    parameter PROTECT_UMA_ROM = 0,
    parameter DCACHE_SET_BITS = 7,
    parameter ICACHE_SET_BITS = 7,
    parameter ENABLE_X87 = 0,
    parameter ENABLE_DEVICE_MMIO = 0,
    parameter [31:0] DEVICE_MMIO_MASK = 32'hff00_0000,
    // The vendored memory-map template's parameters, in z486.sv's order; the
    // stub carries them so pc9821_system's `Z486_PC98_MAP_PARAMS splice has
    // every name to bind to. Inert here.
    parameter [31:0] A20_MASK_OFF = 32'hffef_ffff,
    parameter [31:0] A20_MASK_ON  = 32'hffff_ffff,
    parameter        VGA_ENABLE = 0,
    parameter        VGA_PRE_WRAP = 1,
    parameter [1:0]  VGA_CLASS = 2'd1,
    parameter [31:0] VGA_BASE = 32'h000a_0000,
    parameter [31:0] VGA_TOP  = 32'h000b_ffff,
    parameter        APERTURE_ENABLE = 0,
    parameter [1:0]  APERTURE_CLASS = 2'd1,
    parameter [31:0] APERTURE_BASE = 32'h000a_0000,
    parameter [31:0] APERTURE_TOP  = 32'h000f_ffff,
    parameter        ALIAS_ENABLE = 0,
    parameter [1:0]  ALIAS_CLASS = 2'd1,
    parameter [31:0] ALIAS0_BASE = 32'h00f0_0000,
    parameter [31:0] ALIAS0_TOP  = 32'h00ff_ffff,
    parameter [31:0] ALIAS1_BASE = 32'hfff0_0000,
    parameter [31:0] ALIAS1_TOP  = 32'hfff7_ffff,
    parameter [31:0] ALIAS2_BASE = 32'hffff_8000,
    parameter [31:0] ALIAS2_TOP  = 32'hffff_ffff,
    parameter        WIN0_ENABLE = 0,
    parameter [1:0]  WIN0_CLASS = 2'd2,
    parameter [31:0] WIN0_BASE = 32'h0008_0000,
    parameter [31:0] WIN0_TOP  = 32'h0009_ffff,
    parameter        NO_ALLOC_ENABLE = 0,
    parameter [1:0]  NO_ALLOC_CLASS = 2'd2,
    parameter [31:0] NO_ALLOC_BOUND = 32'h0800_0000,
    parameter        RAM_BOUND_ENABLE = 0,
    parameter        ENABLE_DEBUG_TELEMETRY = 0,
    // Which L1 fill datapaths to build (z486_fill_mode_t on the real z486); the
    // stub carries it so pc9821_system's `.FILL_MODE(z486_cache_map_pkg::...)`
    // binding has a name to land on. Inert here.
    parameter [1:0] FILL_MODE = 2'd0
) (
    input              clk,
    input              reset_n,
    input              device_mmio_enable,
    input      [31:0]  device_mmio_base,
    // The L1 fill-exclusion bound and the window-0 overlay verdict (the cache-fix
    // lane's A1/A5 inputs on the real z486); inert in this stub.
    input      [31:0]  ram_cache_top,
    input              win0_unmapped,

    output     [31:2]  addr,
    output      [3:0]  be,
    output      [7:0]  burstcount,
    output             line_read,
    input      [31:0]  din,
    input      [127:0] line_din,
    output     [31:0]  dout,
    output             valid,
    input              ready,
    output             write,
    output             io,
    input              resp_valid,
    input              line_resp_valid,

    input              intr,
    input              nmi,
    output             inta,

    input      [31:0]  snoop_addr,
    input              snoop_valid,

    // The native whole-L1 flush handshake (iobus pulses cache_flush, the core
    // answers done). Zero-latency model: done follows the request combinationally,
    // so a flush-triggering write cannot wedge in the iobus's S_FLUSH.
    input              cache_flush,
    output             cache_flush_busy,
    output             cache_flush_done,

    input              a20_enable,
    input              fast_off_req,    // z486's diagnostic off switches; ignored by the stub
    input              cache_off_req,
    input              x87_off_req,
    input              single_step,

    output     [15:0]  dbg_CS,
    output     [31:0]  dbg_EIP,
    output     [31:0]  dbg_CS_base,
    output             dbg_pe,
    output             dbg_vm,
    output     [31:0]  dbg_x87_state,
    output             dbg_vec_fetch,
    output      [7:0]  dbg_vec_num,
    output     [31:0]  dbg_EAX,
    output     [31:0]  dbg_EBX,
    output             dbg_CF,
    output      [7:0]  dbg_irq_state,
    output             dbg_il,
    output             dbg_im,
    output             dbg_dl,
    output             dbg_dm,

    // THE TELEMETRY PORTS MUST MIRROR THE REAL z486's EXACTLY, widths included, because
    // benches that compile pc9821_system.sv instantiate THIS stub in the CPU's place and
    // pc9821_system connects every one of them: a port the real CPU has and the stub does
    // not is a PINNOTFOUND on every such bench (12 of them failed to build that way until
    // this list caught up -- sysclk_invariance, system_reset_seed and l1_counters among
    // them, and tools/check_port_lists.py was red on the same entries). Same contract as
    // the rest of the stub: quiet, tied off, no behaviour. Widths from src/z486/z486.sv
    // and the cpu_dbg_* declarations beside them in pc9821_system.sv.
    output             dbg_gate_read,   // one pulse per accepted IDT/IVT gate read
    output     [31:0]  dbg_gate_addr,   // its linear address
    output      [2:0]  dbg_pf_code,     // latched page-fault error code
    output     [31:0]  dbg_pf_addr,     // latched faulting linear address
    output     [31:0]  dbg_eflags,
    output             dbg_page_fault,
    output     [31:0]  dbg_walk_pde,    // page walker: last PDE read
    output     [31:0]  dbg_walk_pte,    // page walker: last PTE read
    output     [31:0]  dbg_cr3,
    output     [15:0]  dbg_SP,
    output             dbg_issue,       // instruction issue pulse
    output     [31:0]  dbg_issue_eip,   // and the IP that will execute next

    output reg         triple_fault_reset,
    output             lock
);

  // The idle bus: no requests, no fault, no debug movement.
  assign lock        = 1'b0;
  assign addr        = 30'd0;
  assign be          = 4'd0;
  assign burstcount  = 8'd0;
  assign line_read   = 1'b0;
  assign dout        = 32'd0;
  assign valid       = 1'b0;
  assign write       = 1'b0;
  assign io          = 1'b0;
  assign dbg_CS      = 16'd0;
  assign dbg_EIP     = 32'd0;
  assign dbg_CS_base = 32'd0;
  assign dbg_pe      = 1'b0;
  assign dbg_vm      = 1'b0;
  assign dbg_x87_state = 32'd0;
  assign dbg_vec_fetch = 1'b0;
  assign dbg_vec_num   = 8'd0;
  assign dbg_EAX       = 32'd0;
  assign dbg_EBX       = 32'd0;
  assign dbg_CF        = 1'b0;
  assign dbg_irq_state = 8'd0;
  assign dbg_il      = 1'b0;
  assign dbg_im      = 1'b0;
  assign dbg_dl      = 1'b0;
  assign dbg_dm      = 1'b0;
  assign dbg_gate_read  = 1'b0;
  assign dbg_gate_addr  = 32'd0;
  assign dbg_pf_code    = 3'd0;
  assign dbg_pf_addr    = 32'd0;
  assign dbg_eflags     = 32'd0;
  assign dbg_page_fault = 1'b0;
  assign dbg_walk_pde   = 32'd0;
  assign dbg_walk_pte   = 32'd0;
  assign dbg_cr3        = 32'd0;
  assign dbg_SP         = 16'd0;
  assign dbg_issue      = 1'b0;
  assign dbg_issue_eip  = 32'd0;
  assign cache_flush_busy = 1'b0;
  assign cache_flush_done = cache_flush;

  // Two 2-cycle INTA pulses every 50 clks on an ABSOLUTE schedule from time 0:
  // z_inta rises at posedges 9, 21, 59, 71, 109, 121, ... (clks 8-9 and 20-21 of
  // each 50-clk period, registered). The counter free-runs on purpose: pc9821_system
  // only releases the CPU reset once a pack has loaded (cpu_run = rom_ready), which
  // this bench does not do, so the schedule cannot key on reset_n - and an absolute
  // schedule is what lets the bench place its reset windows BETWEEN pulse windows.
  reg [5:0] sched_clk = 6'd0;
  reg       inta_r = 1'b0;
  assign inta = inta_r;
  always @(posedge clk) begin
    sched_clk <= (sched_clk == 6'd49) ? 6'd0 : sched_clk + 6'd1;
    inta_r    <= ((sched_clk >= 6'd8)  && (sched_clk < 6'd10)) ||
                 ((sched_clk >= 6'd20) && (sched_clk < 6'd22));
  end

  always @(posedge clk) triple_fault_reset <= 1'b0;

endmodule

`default_nettype wire
