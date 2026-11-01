#!/usr/bin/env python3
"""Synthesize z486's cache_unit ALONE in Quartus and prove its split routing class.

Fork b980746 gave the bus unit a routing class per mem_req arm
(cache_unit dcache_req_cls_m1/_m0 = {DIRECT, uncached}); the selected arm must
equal the request's own {dcache_req_is_direct, dcache_req_is_uncached}. It does
in RTL (tests/equiv, Verilator, the fuse) - and Quartus 17.0 built it wrong: the
uncached bit as `class != NO_ALLOC` instead of `!= CACHEABLE`, so the core
black-screened on hardware (fixed by fork 1f78790). This gate catches that class
of defect where it lives, in the synthesized netlist: cache_unit is wrapped
with every port a virtual pin, synthesized with this project's qsf synthesis
settings (quartus_map, quartus_cdb --vqm, in the Quartus container), and yosys
SAT proves, for every input,

  (split_sel ? cls_m1 : cls_m0) == {is_direct, is_uncached}

under the paging unit's premise is_vga_mem == (split_sel ? route_m1 : route_m0)[1]
(the whole request's VGA bit is the selected arm's). Exit 0 = PASS, 1 = FAIL.

  python3 tools/check_cls_netlist.py [--src src/z486] [--work .build/cls-netlist]
"""
import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import vqm_equiv  # noqa: E402

# The PC-9821 instantiation's memory-map parameters (z486_pc98_preset.svh
# `Z486_PC98_MAP_PARAMS plus pc9821_system's RAM_BOUND_ENABLE) and the split.
PARAMS = """    .PROTECT_UMA_ROM(0), .ENABLE_DEVICE_MMIO(0),
    .A20_MASK_OFF(32'hffef_ffff), .VGA_ENABLE(1'b1), .VGA_PRE_WRAP(1'b0), .APERTURE_ENABLE(1'b1),
    .ALIAS_ENABLE(1'b1), .WIN0_ENABLE(1'b1), .NO_ALLOC_ENABLE(1'b1), .NO_ALLOC_BOUND(32'h0800_0000),
    .RAM_BOUND_ENABLE(1), .CLASS_SPLIT(1)"""
OUTS = ('dcache_req_cls_m1', 'dcache_req_cls_m0', 'dcache_req_is_uncached', 'dcache_req_is_direct')
SKIP_QSF = re.compile(r'-name (\w*FILE|SEARCH_PATH|TOP_LEVEL_ENTITY|PROJECT_OUTPUT_DIRECTORY|'
                      r'POST_FLOW_SCRIPT_FILE|PRE_FLOW_SCRIPT_FILE|QIP_FILE|SDC_FILE)\b')


def wrapper(cache_unit_sv):
    src = cache_unit_sv.read_text()
    hdr = src[src.index('module cache_unit'):]
    body = hdr[hdr.index('(\n', hdr.index(')')):]
    body = body[:body.index('\n);')]
    ports = []
    for line in body.splitlines():
        line = line.split('//')[0].strip().rstrip(',')
        m = re.match(r'(input|output)\s+(?:logic|wire)?\s*(\[[^\]]+\])?\s*(\w+)$', line)
        if m:
            ports.append((m.group(1), m.group(2) or '', m.group(3)))
    if not all(any(n == o for _, _, n in ports) for o in OUTS):
        raise SystemExit("check_cls_netlist: cache_unit has no split class outputs (CLASS_SPLIT gone?)")
    decl = [f"    {d} {w} {n}" for d, w, n in ports if d == 'input' or n in OUTS]
    conn = [f"    .{n}({n if (d == 'input' or n in OUTS) else ''})" for d, w, n in ports]
    return ("module clstest import z486_pkg::*; (\n" + ",\n".join(decl) + "\n);\n"
            "cache_unit #(\n" + PARAMS + "\n) u (\n" + ",\n".join(conn) + "\n);\nendmodule\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', default=str(ROOT / 'src' / 'z486'))
    ap.add_argument('--work', default=str(ROOT / '.build' / 'cls-netlist'))
    args = ap.parse_args()
    src, work = pathlib.Path(args.src).resolve(), pathlib.Path(args.work).resolve()
    if work.exists():
        shutil.rmtree(work)
    (work / 'src').mkdir(parents=True)
    for f in src.iterdir():
        if f.suffix in ('.sv', '.svh', '.hex', '.mif') and f.is_file():
            shutil.copy(f, work / 'src' / f.name)
    (work / 'clstest.sv').write_text(wrapper(src / 'cache_unit.sv'))
    qsf = [l for l in (ROOT / 'z486_mister.qsf').read_text().splitlines()
           if l.startswith('set_global_assignment') and not SKIP_QSF.search(l)]
    qsf += ['set_global_assignment -name TOP_LEVEL_ENTITY clstest',
            'set_global_assignment -name SEARCH_PATH src']
    qsf += [f'set_global_assignment -name SYSTEMVERILOG_FILE src/{n}.sv'
            for n in ('z486_pkg', 'z486_cache_map_pkg', 'l1_cache', 'l1_icache', 'cache_unit')]
    qsf += ['set_global_assignment -name SYSTEMVERILOG_FILE clstest.sv',
            'set_instance_assignment -name VIRTUAL_PIN ON -to *']
    (work / 'clstest.qsf').write_text('\n'.join(qsf) + '\n')
    (work / 'clstest.qpf').write_text('PROJECT_REVISION = "clstest"\n')
    rt = os.environ.get('CONTAINER_RUNTIME', 'podman')
    img = os.environ.get('QUARTUS_IMAGE', 'docker.io/raetro/quartus:mister')
    q = '/opt/intelFPGA/quartus/bin'
    cmd = [rt, 'run', '--rm', '-e', 'HOME=/tmp', '-v', f'{work}:/work', '-w', '/work', img, 'bash', '-c',
           f'{q}/quartus_map clstest && {q}/quartus_cdb clstest -c clstest --vqm=post_map.vqm']
    with open(work / 'quartus.log', 'w') as log:
        r = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    if r.returncode != 0 or not (work / 'post_map.vqm').exists():
        print(f"check_cls_netlist: FAIL - Quartus did not produce a netlist (see {work}/quartus.log)")
        return 1
    cells, assigns = vqm_equiv.parse(work / 'post_map.vqm')
    leaves, lines = {}, []
    e = vqm_equiv.Emitter('N', cells, assigns, leaves, lines)
    s = e.net('dcache_req_split_sel')
    pick = lambda b: f"(({s}) ? {e.net(f'dcache_req_cls_m1[{b}]')} : {e.net(f'dcache_req_cls_m0[{b}]')})"
    vga, r1, r0 = e.net('dcache_req_is_vga_mem'), e.net('dcache_req_route_m1[1]'), e.net('dcache_req_route_m0[1]')
    lines.append(f"wire premise = ({vga}) == (({s}) ? {r1} : {r0});")
    lines.append(f"assign unc_diff = premise & ({pick(0)} ^ {e.net('dcache_req_is_uncached')});")
    lines.append(f"assign dir_diff = {pick(1)} ^ {e.net('dcache_req_is_direct')};")
    text = ("module miter(" + ", ".join(['output unc_diff', 'output dir_diff'] +
                                       [f"input {v}" for v in leaves.values()]) + ");\n"
            + "\n".join(lines) + "\nendmodule\n")
    unc_ok, dir_ok = vqm_equiv.sat(text, ['unc_diff', 'dir_diff'])
    print(f"check_cls_netlist: uncached bit {'proved' if unc_ok else 'DIFFERS'}, "
          f"direct bit {'proved' if dir_ok else 'DIFFERS'} ({len(leaves)} input bits)")
    print("check_cls_netlist:", "PASS" if unc_ok and dir_ok else "FAIL")
    return 0 if unc_ok and dir_ok else 1


if __name__ == '__main__':
    sys.exit(main())
