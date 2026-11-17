#!/usr/bin/env python3
"""
Protected Mode Test Runner for z486

Runs assembly tests in protected mode with configurable segment descriptors
and paging. Tests report results via I/O ports.

Usage:
    ./test_protected_mode.py                    # Run all tests
    ./test_protected_mode.py seg_paging         # Run specific test
    ./test_protected_mode.py seg_paging -v      # Verbose with traces
    ./test_protected_mode.py seg_paging --trace # Generate VCD trace
"""

import sys
import subprocess
import os
import argparse
import struct
import json
import re
import shutil
import tempfile
from pathlib import Path

# Paths
SCRIPT_DIR = Path(__file__).resolve().parent
TESTS_DIR = SCRIPT_DIR / "programs"
VERILATOR_EXE = Path(os.environ.get(
    "Z486_TESTBENCH", SCRIPT_DIR / "obj_dir/Vtb_protected_mode"
))

# Throttle selector -> CPU clock-edge rate in kHz, mirroring cpu_throttle.sv's
# rate_khz() (the bench prints the RTL's value at start-up and
# test_throttle_rate.py checks this table against it).  The testbench's clk is
# 85 MHz for this purpose (TB_CLOCK_KHZ).  A throttled run is the same program
# with the CPU's clock gated, so its cycle budget (and wall-clock limit) grows
# by the clock ratio, rounded up, plus one for the cycles that memory and I/O
# add on the unthrottled side.
THROTTLE_TB_KHZ = 85000
THROTTLE_RATE_KHZ = {0: 0, 1: 33000, 2: 25000, 3: 16000, 4: 12000, 5: 8000,
                     6: 6000, 7: 4000, 8: 3000, 9: 2000, 10: 1500, 11: 1000,
                     12: 750, 13: 500}
THROTTLE_CYCLE_SCALE = {sel: 1 if not khz else -(-THROTTLE_TB_KHZ // khz) + 1
                        for sel, khz in THROTTLE_RATE_KHZ.items()}
THROTTLE_CYCLE_SCALE.update({14: 1, 15: 1})   # reserved: full speed


def throttle_setting(sim_args):
    """The +cpu_speed=N selector carried in SIM_PLUSARGS (0 = full speed)."""
    m = re.search(r'\+cpu_speed=(\d+)', sim_args)
    return int(m.group(1)) & 15 if m else 0

# I/O port results
STATUS_PASS = 0x01
STATUS_FAIL = 0xFF

#==============================================================================
# Page Table Generation
#==============================================================================

def generate_page_table_entry(frame_addr, flags='RW'):
    """Generate a 32-bit page table entry.

    Args:
        frame_addr: Physical frame address (must be 4KB aligned)
        flags: 'RW' for read/write, 'RO' for read-only, 'U' adds user bit

    Returns:
        32-bit PTE value
    """
    pte = (frame_addr & 0xFFFFF000)  # Frame address [31:12]
    pte |= 0x01  # Present
    if 'W' in flags.upper():
        pte |= 0x02  # Read/Write
    if 'U' in flags.upper():
        pte |= 0x04  # User
    pte |= 0x20  # Accessed
    return pte


def generate_page_tables(mappings, page_dir_addr=0x0000):
    """Generate page directory and page tables for given mappings.

    Args:
        mappings: List of (linear_start, physical_start, num_pages, flags)
        page_dir_addr: Physical address of page directory

    Returns:
        Dict mapping physical addresses to byte data
    """
    memory = {}

    # Page directory (4KB, 1024 entries)
    page_dir = [0] * 1024

    # Track page tables we need to create
    # Key: PDE index, Value: physical address of page table
    page_tables = {}
    next_pt_addr = page_dir_addr + 0x1000  # First PT after page dir

    for linear_start, physical_start, num_pages, flags in mappings:
        for i in range(num_pages):
            linear_addr = linear_start + i * 0x1000
            physical_addr = physical_start + i * 0x1000

            # PDE index = linear[31:22]
            pde_idx = (linear_addr >> 22) & 0x3FF
            # PTE index = linear[21:12]
            pte_idx = (linear_addr >> 12) & 0x3FF

            # Create page table if needed
            if pde_idx not in page_tables:
                page_tables[pde_idx] = next_pt_addr
                next_pt_addr += 0x1000

                # Initialize page table to all zeros
                pt_base = page_tables[pde_idx]
                for j in range(1024):
                    memory[pt_base + j*4] = struct.pack('<I', 0)

                # Create PDE pointing to this page table
                pde = generate_page_table_entry(page_tables[pde_idx], 'RWU')  # permissive PDE; the PTE still restricts
                page_dir[pde_idx] = pde

            # A user mapping needs a user PDE as well.
            if 'U' in flags.upper():
                page_dir[pde_idx] |= 0x04

            # Create PTE
            pt_base = page_tables[pde_idx]
            pte = generate_page_table_entry(physical_addr, flags)
            memory[pt_base + pte_idx*4] = struct.pack('<I', pte)

    # Write page directory
    for i, pde in enumerate(page_dir):
        memory[page_dir_addr + i*4] = struct.pack('<I', pde)

    return memory


#==============================================================================
# Test Configuration
#==============================================================================

# Segment descriptor flags:
# [15:12] = type, [11] = S, [10:9] = DPL, [8] = P, [7] = D_B, [6] = G, [5] = A
# Data RW:  type=0010, S=1, DPL=00, P=1, D_B=1, G=1, A=1 -> 0x21E0
# Code RX:  type=1010, S=1, DPL=00, P=1, D_B=1, G=1, A=1 -> 0xA1E0

def seg_flags(code=False, dpl=0, db32=True, granularity_4k=True):
    """Build segment descriptor flags."""
    flags = 0
    if code:
        flags |= 0xA000  # Code, readable (type=1010)
    else:
        flags |= 0x2000  # Data, writable (type=0010)
    flags |= 0x0800      # S=1 (code/data, not system)
    flags |= (dpl & 3) << 9  # DPL
    flags |= 0x0100      # P=1 (present)
    if db32:
        flags |= 0x0080  # D/B=1 (32-bit)
    if granularity_4k:
        flags |= 0x0040  # G=1 (4KB granularity)
    flags |= 0x0020      # A=1 (accessed)
    return flags


# Tests are discovered by scanning programs/*.json (each config file sits beside
# its .asm). The JSON is the setup: start_mode, cr0/cr3/eip, initial_selectors,
# seg_cache descriptors, page_tables, mem_latency, cycles, etc. Numeric fields may
# be written as "0x..." hex strings for readability. To add a test, drop in a
# .asm + .json -- no Python edit needed.

def _unhex(v):
    """Recursively turn "0x.." strings from loaded JSON back into ints."""
    if isinstance(v, str) and v[:2] == '0x':
        try:
            return int(v, 16)
        except ValueError:
            return v
    if isinstance(v, dict):
        return {k: _unhex(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_unhex(x) for x in v]
    return v


def load_tests(tests_dir):
    tests = {}
    for jf in sorted(tests_dir.glob('*.json')):
        with open(jf) as f:
            tests[jf.stem] = _unhex(json.load(f))
    return tests


TESTS = load_tests(TESTS_DIR)


#==============================================================================
# Build and Run
#==============================================================================

def build_testbench(verbose=False):
    """Build or refresh the protected-mode Verilator testbench."""
    if os.environ.get("Z486_TESTBENCH"):
        if VERILATOR_EXE.exists():
            print(f"Using protected-mode testbench: {VERILATOR_EXE}")
            return True
        print(f"Error: requested testbench does not exist: {VERILATOR_EXE}")
        return False

    cmd = ['make', 'obj_dir/Vtb_protected_mode']
    print(f"Building protected-mode testbench: {' '.join(cmd)}")

    result = subprocess.run(
        cmd,
        cwd=SCRIPT_DIR,
        capture_output=not verbose,
        text=True
    )
    if result.returncode != 0:
        print("Error: failed to build protected-mode testbench")
        if not verbose:
            if result.stdout:
                print(result.stdout)
            if result.stderr:
                print(result.stderr)
        return False
    if not VERILATOR_EXE.exists():
        print(f"Error: expected testbench was not produced: {VERILATOR_EXE}")
        return False
    return True


def assemble(asm_file, bin_file, lst_file, verbose=False):
    """Assemble .asm to .bin using NASM."""
    cmd = ['nasm', '-f', 'bin', '-o', str(bin_file), '-l', str(lst_file), str(asm_file)]
    if verbose:
        print(f"  Assembling: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"NASM error:\n{result.stderr}")
        return False
    return True


def build_memory_image(test_config, code_bin, output_hex, verbose=False):
    """Build combined memory image with code and page tables.

    Memory layout:
        0x00000000 - Page Directory (4KB)
        0x00001000 - Page Tables (as needed)
        0x00010000 - Code area (CS maps here)
        0x00020000 - Data area (DS maps here)
        0x00060000 - Stack area (SS maps here)
    """
    memory = {}

    # Generate page tables
    pt_mappings = test_config.get('page_tables', [])
    if pt_mappings:
        pt_mem = generate_page_tables(pt_mappings,
                                      page_dir_addr=test_config['cr3'] & 0xFFFFF000)
        for addr, data in pt_mem.items():
            for i, byte in enumerate(data):
                memory[addr + i] = byte

    # Load code binary
    code_data = code_bin.read_bytes()
    # Code goes at physical address where CS linear range maps
    # From page_tables config: CS linear 0x10000000 -> physical 0x00010000
    code_phys_addr = 0x00010000
    for pt in pt_mappings:
        if pt[0] == test_config['seg_cache']['CS']['base']:
            code_phys_addr = pt[1]
            break

    for i, byte in enumerate(code_data):
        memory[code_phys_addr + i] = byte

    if verbose:
        print(f"  Code loaded at physical 0x{code_phys_addr:08X} ({len(code_data)} bytes)")
        print(f"  Page tables at physical 0x00000000")

    # Write hex file
    with open(output_hex, 'w') as f:
        # Find max address
        if memory:
            max_addr = max(memory.keys())
            for addr in range(0, max_addr + 1):
                byte = memory.get(addr, 0)
                f.write(f"{byte:02X}\n")

    return code_phys_addr  # Return physical address where code was loaded


def run_simulation(test_name, test_config, hex_file, code_phys_base, verbose=False, trace=False, cycles=10_000, trace_file=None, wall_timeout=120):
    """Run Verilator simulation with test configuration."""
    cmd = [str(VERILATOR_EXE)]
    start_mode = test_config.get('start_mode', 'protected').lower()
    start_protected = 0 if start_mode == 'real' else 1

    init_selectors = test_config.get('initial_selectors', {})
    default_cs = (code_phys_base >> 4) & 0xFFFF if start_protected == 0 else 0x0008
    init_cs = init_selectors.get('CS', default_cs)
    init_ds = init_selectors.get('DS', 0x0010 if start_protected else 0x0000)
    init_ss = init_selectors.get('SS', 0x0018 if start_protected else 0x0000)
    init_es = init_selectors.get('ES', 0x0020 if start_protected else 0x0000)
    init_fs = init_selectors.get('FS', 0x0028 if start_protected else 0x0000)
    init_gs = init_selectors.get('GS', 0x0030 if start_protected else 0x0000)
    d_init = test_config.get('d_init', 1 if start_protected else 0)

    # Extra sim plusargs from the environment (e.g. SIM_PLUSARGS="+pf_evt")
    for extra in os.environ.get('SIM_PLUSARGS', '').split():
        cmd.append(extra)
    # Per-test instrumentation requirements.  Keeping these in the test JSON
    # makes a regression prove that its intended internal condition occurred.
    for extra in test_config.get('sim_plusargs', []):
        cmd.append(extra if extra.startswith('+') else f'+{extra}')
    cmd.append(f"+mem={hex_file}")
    cmd.append(f"+cycles={cycles}")
    cmd.append(f"+eip={test_config['eip']}")
    cmd.append(f"+cr0={test_config['cr0']}")
    cmd.append(f"+cr3={test_config['cr3']}")
    cmd.append(f"+code_phys_base={code_phys_base}")
    cmd.append(f"+start_protected={start_protected}")
    cmd.append(f"+init_cs={init_cs}")
    cmd.append(f"+init_ds={init_ds}")
    cmd.append(f"+init_ss={init_ss}")
    cmd.append(f"+init_es={init_es}")
    cmd.append(f"+init_fs={init_fs}")
    cmd.append(f"+init_gs={init_gs}")
    cmd.append(f"+d_init={d_init}")
    if test_config.get('continue_on_hlt', False):
        cmd.append("+continue_on_hlt")
    if test_config.get('expect_triple_fault', False):
        cmd.append("+expect_triple_fault")
    if 'mem_latency' in test_config:
        cmd.append(f"+mem_latency={test_config['mem_latency']}")

    # Segment descriptor cache parameters
    seg_cache = test_config.get('seg_cache', {})
    if seg_cache:
        for seg_name in ['CS', 'DS', 'SS', 'ES', 'FS', 'GS']:
            seg = seg_cache[seg_name]
            prefix = seg_name.lower()
            cmd.append(f"+{prefix}_base={seg['base']}")
            cmd.append(f"+{prefix}_limit={seg['limit']}")
            cmd.append(f"+{prefix}_flags={seg['flags']}")

    if verbose:
        cmd.extend(["+trace_instr", "+trace_io", "+trace_descw", "+trace_prot", "+trace_ldsg", "+trace_gate", "+trace_ucode", "+trace_mem"])
    if trace:
        cmd.append("+trace")
        if trace_file is not None:
            cmd.append(f"+tracefile={trace_file}")

    if verbose:
        print(f"  Running: {' '.join(cmd[:5])}...")

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=wall_timeout)

    if verbose:
        print(result.stdout)
        if result.stderr:
            print(f"  stderr: {result.stderr}")

    # Check result
    failed = "TEST FAILED" in result.stdout
    timeout = "TIMEOUT" in result.stdout
    passed = (result.returncode == 0 and "TEST PASSED" in result.stdout
              and not failed and not timeout)

    return passed, failed, timeout, result.stdout


def run_test(test_name, verbose=False, trace=False, keep_files=False, cycles=20_000):
    """Run a single protected mode test."""
    if test_name not in TESTS:
        return False, f"Unknown test: {test_name}"

    test_config = TESTS[test_name]
    # A test that times a fast path or a cache hit, or needs a fast path to
    # reach its trigger, has nothing to check while the fast paths or the L1
    # caches are off or toggling.
    sim_args = os.environ.get('SIM_PLUSARGS', '')
    if test_config.get('fast_paths_only') and any(
            arg in sim_args for arg in ('z486_fast_off', 'z486_fast_toggle',
                                        'z486_hardwired_off', 'z486_cache_off',
                                        'z486_cache_toggle')):
        return True, "SKIP (fast paths only)"
    # A program that times itself with the testbench cycle counter (port 0xFC)
    # checks a clock count, which the throttle legitimately stretches.
    speed = throttle_setting(sim_args)
    if speed and test_config.get('unthrottled_only'):
        return True, "SKIP (clock-count premise)"
    asm_file = TESTS_DIR / test_config['asm']
    # Intermediate files go to a private directory unless kept, so several
    # runners (one per throttle setting) can share the program directory.
    work_dir = TESTS_DIR if keep_files else Path(tempfile.mkdtemp(prefix=f"z486_{test_name}_"))
    bin_file = work_dir / f"{test_name}.bin"
    lst_file = work_dir / f"{test_name}.lst"
    hex_file = work_dir / f"{test_name}.hex"

    if not asm_file.exists():
        return False, f"Assembly file not found: {asm_file}"

    try:
        # Assemble
        if verbose:
            print(f"  Building {test_name}...")
        if not assemble(asm_file, bin_file, lst_file, verbose):
            return False, "Assembly failed"

        # Build memory image
        if verbose:
            print(f"  Generating page tables...")
        code_phys_base = build_memory_image(test_config, bin_file, hex_file, verbose)
        if code_phys_base is None:
            return False, "Memory image generation failed"

        # Run simulation
        if verbose:
            print(f"  Running simulation...")
        trace_file = None
        if trace:
            trace_dir = TESTS_DIR / "traces"
            trace_dir.mkdir(parents=True, exist_ok=True)
            trace_file = trace_dir / f"{test_name}.vcd"
            if trace_file.exists():
                trace_file.unlink()
            if verbose:
                print(f"  Trace file: {trace_file}")
        sim_cycles = test_config.get('cycles', cycles)
        scale = THROTTLE_CYCLE_SCALE[speed]
        passed, failed, timeout, output = run_simulation(
            test_name, test_config, hex_file, code_phys_base, verbose, trace,
            sim_cycles * scale, trace_file, wall_timeout=120 * scale
        )

        if passed:
            if test_config.get('expect_fail'):
                return False, "XPASS - expected to fail but passed"
            return True, "PASS"
        elif failed:
            if test_config.get('expect_fail'):
                return True, "XFAIL - expected failure (unported fix)"
            return False, "FAIL - test reported failure"
        elif timeout:
            if test_config.get('expect_fail'):
                return True, "XFAIL - expected timeout (unported fix)"
            return False, "TIMEOUT"
        else:
            return False, "Unknown result"

    except subprocess.TimeoutExpired:
        return False, "Simulation timeout (wall clock)"
    except Exception as e:
        if verbose:
            import traceback
            traceback.print_exc()
        return False, f"Error: {e}"
    finally:
        # Cleanup
        if not keep_files:
            shutil.rmtree(work_dir, ignore_errors=True)


#==============================================================================
# Main
#==============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Run z486 protected mode tests',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
    ./test_protected_mode.py                    # Run all tests
    ./test_protected_mode.py seg_paging         # Run specific test
    ./test_protected_mode.py seg_paging -v      # Verbose
    ./test_protected_mode.py seg_paging --trace # Generate VCD
        '''
    )
    parser.add_argument('tests', nargs='*', help='Tests to run (default: all)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output')
    parser.add_argument('--trace', action='store_true', help='Generate VCD trace')
    parser.add_argument('--keep', action='store_true', help='Keep intermediate files')
    parser.add_argument('-c', '--cycles', type=int, default=20_000, help='Max cycles')
    parser.add_argument('--list', action='store_true', help='List available tests')
    parser.add_argument('--strict', action='store_true', help='Reject expected failures (release gate)')

    args = parser.parse_args()

    if args.list:
        print("Available tests:")
        for name in TESTS:
            print(f"  {name}")
        return 0

    if not build_testbench(args.verbose):
        return 1

    # Check NASM exists
    result = subprocess.run(['which', 'nasm'], capture_output=True)
    if result.returncode != 0:
        print("Error: NASM assembler not found")
        print("Install with: brew install nasm")
        return 1

    # Determine tests to run
    tests_to_run = args.tests if args.tests else list(TESTS.keys())
    if os.environ.get("Z486_ENABLE_X87") != "1":
        requested_x87 = [name for name in tests_to_run
                         if TESTS[name].get("requires_x87", False)]
        if args.tests and requested_x87:
            print("Error: x87 test(s) require the x87-enabled testbench: "
                  + ", ".join(requested_x87))
            print("Run `make test-x87-integration` or set Z486_ENABLE_X87=1 "
                  "and Z486_TESTBENCH to obj_dir_x87/Vtb_protected_mode.")
            return 1
        tests_to_run = [name for name in tests_to_run
                        if not TESTS[name].get("requires_x87", False)]

    if os.environ.get("Z486_PC98_MAP") != "1":
        requested_pc98 = [name for name in tests_to_run
                          if TESTS[name].get("requires_pc98_map", False)]
        if args.tests and requested_pc98:
            print("Error: PC-98 map tests require `make test-pc98-map`: "
                  + ", ".join(requested_pc98))
            return 1
        tests_to_run = [name for name in tests_to_run
                       if not TESTS[name].get("requires_pc98_map", False)]

    # A program that needs bench memory above 1 MiB (an A20 alias with its own
    # backing) runs only on obj_dir_bigmem (`make test-bigmem`).
    if os.environ.get("Z486_BIGMEM") != "1":
        requested_big = [name for name in tests_to_run
                         if TESTS[name].get("requires_bigmem", False)]
        if args.tests and requested_big:
            print("Error: test(s) need the 4 MiB testbench (`make test-bigmem`): "
                  + ", ".join(requested_big))
            return 1
        tests_to_run = [name for name in tests_to_run
                        if not TESTS[name].get("requires_bigmem", False)]

    if args.strict:
        expected = [name for name in tests_to_run if TESTS[name].get('expect_fail')]
        if expected:
            print('Error: expected failures are not release passes: ' + ', '.join(expected))
            return 1

    # Run tests.  A SKIP counts toward the summary's pass total (callers parse
    # that line), but is labelled SKIP and counted on a line of its own.
    passed_count = 0
    failed_count = 0
    skipped_count = 0

    print(f"Running {len(tests_to_run)} protected mode test(s)...\n")

    for test_name in tests_to_run:
        if args.verbose:
            print(f"Testing {test_name}:")

        passed, message = run_test(
            test_name,
            verbose=args.verbose,
            trace=args.trace,
            keep_files=args.keep,
            cycles=args.cycles
        )

        if passed and message.startswith("SKIP"):
            passed_count += 1
            skipped_count += 1
            color = "\033[93m"  # Yellow
            status = "SKIP"
        elif passed:
            passed_count += 1
            color = "\033[92m"  # Green
            status = "PASS"
        else:
            failed_count += 1
            color = "\033[91m"  # Red
            status = "FAIL"

        reset = "\033[0m"
        print(f"{color}{status}{reset} {test_name:20s} - {message}")

    # Summary
    print(f"\n{'='*60}")
    total = passed_count + failed_count
    percentage = (passed_count * 100 / total) if total > 0 else 0
    print(f"Summary: {passed_count}/{total} tests passed ({percentage:.1f}%)")
    if skipped_count:
        print(f"{skipped_count} of the {passed_count} passes were skipped, not run")

    return 0 if failed_count == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
