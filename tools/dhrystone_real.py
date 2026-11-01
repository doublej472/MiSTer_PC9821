#!/usr/bin/env python3
"""Dhrystone on the REAL SDRAM controller: the second Dhrystone line, a pinned gate.

The CPU contract's Dhrystone (`make -C src/z486/tests dhrystone JOBS=4`, 242611 cycles) runs
the z486 against the fork's idealised memory (first beat +5, store busy 3 cycles), which is the
right instrument for the CPU and blind to the memory system. This tool runs the SAME binary
and the SAME testbench with every non-I/O access timed by the core's SDRAM backend instead -
split_sdram_backend over sdram_sync_bridge over src/memory/sdram.v at the shipping 90 MHz, CL2,
ADQM=1, FAST_GRADE=0 - against sdram_chip_model with its protocol checks, the -7 grade's AC
checks and the tREFI monitor on, so a controller change shows up as a cycle count here.

The testbench is the fork's own src/z486/tests/dhrystone/tb_dhrystone.sv, patched at build time
by the anchored insertions below (DHRY_REAL_SDRAM); nothing of the fork is copied into this tree,
and an anchor that no longer matches the fork's file is a hard error, never a silent skip. The
data still comes from the testbench's memory array (the controller is the timing slave: its ready
pulse and per-beat resp_valid time each access). The figure is the cycle count from the first
accepted access to the end, so the controller's 200 us power-up wait is not in it.

  tools/dhrystone_real.py                  build, run, and fail (exit 1) unless the figure is PINNED
  tools/dhrystone_real.py --expect N       ... against N instead (--expect 0: report only)
  tools/dhrystone_real.py --no-build       reuse the last build

The binary is the gate's (src/z486/tests/dhrystone/build/dhrystone.hex); if it is missing the
tool runs `make -C src/z486/tests dhrystone-pc98` once to build it.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DHRY = ROOT / "src/z486/tests/dhrystone"
CORE = ROOT / "src/z486"
OUT = ROOT / ".build/dhrystone_real"
HEX = DHRY / "build/dhrystone.hex"
FREQ = 90_000_000
# The pinned figure (the gate, AGENTS.md). A controller change that moves it reports the new value
# with its attribution, as a CPU change does for the first Dhrystone line.
PINNED = 271807

# Text inserted before an anchor of the fork's tb_dhrystone.sv: the controller's request wires.
INSERT_BEFORE = ("""`ifdef DHRY_INTERNAL_CPU_CACHE
    assign cpu_din = bus_din;
    assign read_ready = bus_ready;
    assign cpu_resp_valid = bus_resp_valid;
""", """`ifdef DHRY_REAL_SDRAM
    wire rs_mem_op = read_valid && !cpu_io && !inta;
    wire rs_ready, rs_resp;
    wire [31:0] rs_din;
`endif
""")

# (anchor, replacement): the CPU's read/accept/response wiring goes to the controller for every
# non-I/O access, the testbench's own memory model answers only I/O and interrupt acknowledges,
# and the controller and chip model are instantiated beside it.
REPLACE = [
    ("""    assign cpu_din = bus_din;
    assign read_ready = bus_ready;
    assign cpu_resp_valid = bus_resp_valid;

    wire [31:2] bus_addr = read_addr;""",
     """`ifdef DHRY_REAL_SDRAM
    assign cpu_din = rs_resp ? rs_din : bus_din;
    assign read_ready = rs_mem_op ? rs_ready : bus_ready;
    assign cpu_resp_valid = bus_resp_valid | rs_resp;
`else
    assign cpu_din = bus_din;
    assign read_ready = bus_ready;
    assign cpu_resp_valid = bus_resp_valid;
`endif

    wire [31:2] bus_addr = read_addr;"""),
    ("""        if (bus_valid && bus_ready && !bus_busy) begin
            if (bus_inta) begin""",
     """`ifdef DHRY_REAL_SDRAM
        if (bus_valid && bus_ready && !bus_busy && (bus_io || bus_inta)) begin
`else
        if (bus_valid && bus_ready && !bus_busy) begin
`endif
            if (bus_inta) begin"""),
    ("""    string memfile;""",
     """`ifdef DHRY_REAL_SDRAM
    // The core's SDRAM backend at the shipping settings, timing every non-I/O access; the data
    // stays in `mem` (the controller is the timing slave).
    wire rs_busy;
    wire [31:0] rs_ctl_dout; wire rs_ctl_resp, rs_ctl_ready;
    wire [15:0] rs_dq; wire [12:0] rs_a; wire [1:0] rs_ba, rs_dqm; wire rs_nwe, rs_nras, rs_ncas, rs_ncs, rs_cke;
    wire [31:0] rs_addr_w = {read_addr, 2'b00};
    split_sdram_backend #(.FREQ(%(freq)d), .ADQM(1'b1), .FAST_GRADE(1'b0), .GATHER_K(4)) rs_be (
        .clk(clk), .reset(!reset_n), .refresh_allowed(1'b1), .sdram_size(2'd2), .busy(rs_busy),
        .mem0_valid(rs_mem_op), .mem0_ready(rs_ctl_ready), .mem0_write(cpu_write),
        .mem0_addr(rs_addr_w), .mem0_din(read_data), .mem0_din_hi(32'd0),
        .mem0_gath(1'b0), .mem0_gath_extra(441'd0),
        .mem0_dout(rs_ctl_dout), .mem0_resp_valid(rs_ctl_resp), .mem0_be(read_be),
        .mem0_burstcount(cpu_burstcount),
        .mem1_valid(1'b0), .mem1_ready(), .mem1_write(1'b0), .mem1_addr(32'd0), .mem1_din(32'd0),
        .mem1_dout(), .mem1_resp_valid(), .mem1_be(4'hF), .mem1_burstcount(8'd1),
        .mem2_valid(1'b0), .mem2_ready(), .mem2_write(1'b0), .mem2_addr(32'd0), .mem2_din(32'd0),
        .mem2_dout(), .mem2_resp_valid(), .mem2_be(4'hF), .mem2_burstcount(8'd1),
        .mem3_valid(1'b0), .mem3_ready(), .mem3_write(1'b0), .mem3_addr(32'd0), .mem3_din(32'd0),
        .mem3_dout(), .mem3_resp_valid(), .mem3_be(4'hF), .mem3_burstcount(8'd1),
        .sdram_dq(rs_dq), .sdram_a(rs_a), .sdram_ba(rs_ba), .sdram_dqm(rs_dqm),
        .sdram_nwe(rs_nwe), .sdram_nras(rs_nras), .sdram_ncas(rs_ncas), .sdram_ncs(rs_ncs),
        .sdram_cke(rs_cke));
    sdram_chip_model #(.CAS(2), .FREQ_HZ(%(freq)d), .GRADE(7), .REFRESH_INTERVAL(%(trefi)d)) rs_chip (
        .clk(clk), .DQ(rs_dq), .A(rs_a), .BA(rs_ba), .nRAS(rs_nras), .nCAS(rs_ncas), .nWE(rs_nwe), .nCS(rs_ncs));
    assign rs_ready = rs_ctl_ready;
    assign rs_resp = rs_ctl_resp;
    reg [31:0] rs_rd_addr = 32'd0;
    integer rs_first_accept = -1;
    integer rs_n_rd = 0, rs_n_wr = 0;
    wire [31:0] rs_rd_idx = rs_rd_addr & (MEM_SIZE - 1);
    assign rs_din = {mem[rs_rd_idx+3], mem[rs_rd_idx+2], mem[rs_rd_idx+1], mem[rs_rd_idx+0]};
    always @(posedge clk) begin
        if (rs_mem_op && rs_ctl_ready) begin
            if (rs_first_accept < 0) rs_first_accept <= cycle;
            if (cpu_write) begin
                reg [31:0] ba2;
                ba2 = rs_addr_w & (MEM_SIZE - 1);
                rs_n_wr <= rs_n_wr + 1;
                if (read_be[0]) mem[ba2+0] <= read_data[7:0];
                if (read_be[1]) mem[ba2+1] <= read_data[15:8];
                if (read_be[2]) mem[ba2+2] <= read_data[23:16];
                if (read_be[3]) mem[ba2+3] <= read_data[31:24];
            end else begin
                rs_n_rd <= rs_n_rd + 1;
                rs_rd_addr <= rs_addr_w;
            end
        end
        if (rs_ctl_resp) rs_rd_addr <= rs_rd_addr + 32'd4;
    end
    final $display("DHRYSTONE_REAL cycles=%%0d (cycle %%0d minus the first accept %%0d) reads=%%0d writes=%%0d",
                   cycle - rs_first_accept, cycle, rs_first_accept, rs_n_rd, rs_n_wr);
`endif

    string memfile;"""),
]


def patched_tb() -> str:
    src = (DHRY / "tb_dhrystone.sv").read_text()
    anchor, before = INSERT_BEFORE
    if src.count(anchor) != 1:
        raise SystemExit(f"dhrystone_real: the fork's tb_dhrystone.sv no longer holds the anchor:\n{anchor}")
    src = src.replace(anchor, before + anchor)
    for old, new in REPLACE:
        if src.count(old) != 1:
            raise SystemExit(f"dhrystone_real: the fork's tb_dhrystone.sv no longer holds the anchor:\n{old}")
        new = new % {"freq": FREQ, "trefi": FREQ // 128_000} if "%(freq)" in new else new
        src = src.replace(old, new)
    return src


def build() -> Path:
    sys.path.insert(0, str(DHRY))
    import run_dhrystone as rd  # the fork's own source list and microcode copy
    OUT.mkdir(parents=True, exist_ok=True)
    tb = OUT / "tb_dhrystone_real.sv"
    tb.write_text(patched_tb())
    rd.copy_ucode_files(CORE, OUT)
    srcs = [tb, *rd.rtl_sources("z486_current", CORE),
            ROOT / "src/memory/sdram.v", ROOT / "src/memory/sdram_sync_bridge.sv",
            ROOT / "src/memory/split_sdram_backend.sv", ROOT / "tests/pc9821/sdram_chip_model.sv",
            DHRY / "sim_main_dhrystone.cpp"]
    cmd = ["verilator", "--timing", "-Wall", "-Wno-fatal", "-Wno-UNOPTFLAT", "-Wno-SYNCASYNCNET",
           "-cc", "--exe", "-O3", "--build", "-j", os.environ.get("JOBS", "4"),
           f"-I{CORE}", f"-I{CORE / 'tests'}", f"-I{DHRY.parent}", f"-I{CORE / 'x87'}",
           "-CFLAGS", "-std=c++14 -O3", "--trace-fst", "--trace-structs",   # sim_main_dhrystone.cpp links the tracer
           "+define+Z486_INTERNAL_CACHE", "+define+Z486_CURRENT_CORE", "+define+DHRY_PC98_MAP",
           "+define+DHRY_REAL_SDRAM", "--top-module", "tb_dhrystone", *map(str, srcs)]
    r = subprocess.run(cmd, cwd=OUT, capture_output=True, text=True)
    (OUT / "build.log").write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        raise SystemExit(f"dhrystone_real: build failed (see {OUT / 'build.log'})")
    return OUT / "obj_dir/Vtb_dhrystone"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--expect", type=int, default=PINNED,
                    help=f"the figure required (default: the pin, {PINNED}); 0 reports without checking")
    ap.add_argument("--no-build", action="store_true", help="reuse the last build")
    opts = ap.parse_args()
    if not HEX.exists():
        subprocess.run(["make", "-C", str(ROOT / "src/z486/tests"), "dhrystone-pc98", "JOBS=4"], check=True)
    exe = OUT / "obj_dir/Vtb_dhrystone"
    if not opts.no_build or not exe.exists():
        exe = build()
    r = subprocess.run([str(exe), f"+mem={HEX}", "+cycles=3000000"], cwd=OUT,
                       capture_output=True, text=True, timeout=1200)
    (OUT / "run.log").write_text(r.stdout + r.stderr)
    m = re.search(r"^DHRYSTONE_REAL cycles=(\d+) .* reads=(\d+) writes=(\d+)", r.stdout, re.M)
    if r.returncode != 0 or m is None or "TEST PASSED!" not in r.stdout:
        print(f"DHRYSTONE_REAL: FAIL - the run did not complete (see {OUT / 'run.log'})")
        return 1
    cycles = int(m.group(1))
    print(f"DHRYSTONE_REAL: {cycles} cycles on the real controller at {FREQ // 1_000_000} MHz "
          f"(reads {m.group(2)}, writes {m.group(3)})")
    if opts.expect == 0:
        print(f"DHRYSTONE_REAL: REPORTED, not checked (--expect 0; the pin is {PINNED})")
        return 0
    if cycles != opts.expect:
        print(f"DHRYSTONE_REAL: FAIL - {cycles} cycles, the pinned figure is {opts.expect}")
        return 1
    print(f"DHRYSTONE_REAL: PASS ({cycles} cycles, as pinned)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
