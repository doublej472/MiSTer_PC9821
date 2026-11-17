#!/usr/bin/env bash
# End to end: the debug instruments' RTL bytes through tools/decode_dbglog.py.
#
# The benches check the records against the bench's own tables; this checks the same bytes against
# the TOOL a hardware session reads them with. It builds tb_pc9821_dbg_cpu and tb_pc9821_dbg_system
# (tools/bench.py), runs each with +DBGLOG_OUT so it writes what its UART captured, and requires
# decode_dbglog.py to frame every byte (0 outside records) and to find the records the stimulus
# drove: the CPU bench's trace (16 entries, then a stage-2 trigger), snoop events (and the
# snoop replay flagging exactly the read beats at written dwords), samples and a
# LOST record; the system bench's ALIVE record, samples and the forced OUT 0xA4, the floppy
# log's ALIVE and its forced FDC write, and the I/O trigger that write fires.
#
#   bash tests/pc9821/run_dbglog_e2e.sh        prints DBGLOG E2E: PASS
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=.build/dbglog-e2e
rm -rf "$OUT"; mkdir -p "$OUT"
python3 tools/bench.py dbg_cpu >"$OUT/bench-cpu.log" 2>&1 || { tail -20 "$OUT/bench-cpu.log"; exit 1; }
python3 tools/bench.py dbg_system >"$OUT/bench-system.log" 2>&1 || { tail -20 "$OUT/bench-system.log"; exit 1; }
tests/pc9821/build/bench-dbg_cpu/obj/Vtb_pc9821_dbg_cpu "+DBGLOG_OUT=$OUT/cpu" >/dev/null
tests/pc9821/build/bench-dbg_system/obj/Vtb_pc9821_dbg_system "+DBGLOG_OUT=$OUT/system.bin" >/dev/null
python3 - "$OUT" <<'PY'
import collections, sys
sys.path.insert(0, "tools")
import decode_dbglog as d
out = sys.argv[1]
bad = 0

def load(name):
    return d.parse(open(f"{out}/{name}", "rb").read())

def count(cap):
    return collections.Counter(r.type for r in cap.recs)

def need(label, ok):
    global bad
    if not ok:
        print("FAIL:", label)
        bad += 1

# DUT A of the CPU bench: sampler + snoop + RELOAD/stage-2 trace
a = load("cpu.0")
c = count(a)
# the capture ends wherever the bench stopped, so one partial record may remain at its tail
need(f"cpu.0: {a.skipped} byte(s) outside records (a partial tail is at most 33)", a.skipped <= 33)
need("cpu.0: 16 trace entries and one trigger", c[0x43] == 16 and c[0x44] == 1)
ent, trg = d.trace_of(a)
need("cpu.0: the trigger is stage 2 at 0x3D950", trg and trg["stage"] == 2 and trg["addr"] == 0x3D950 and trg["data"] == 0xDEADBEEF)
need("cpu.0: trace entries are consecutive instructions", all(ent[i + 1]["eip"] == ent[i]["eip"] + 1 for i in range(len(ent) - 1)))
need("cpu.0: snoop writes and read beats present", c[0x30] > 0 and c[0x31] > 0)
need("cpu.0: a collision LOST record", c[0x32] == 1)
need("cpu.0: samples present", c[0x20] > 50)
# the snoop replay (--snoop-check) flags exactly the in-window read beats at dwords a write defined:
# the bench's read beats return a hash of the address, never the written value, so each such beat
# disagrees with the replayed writes. From the stimulus (tb_pc9821_dbg_cpu.sv section 2): FA10,
# FA14 (byte 1 only, be=2), FA20, FA24 (be=2), FA40, FA50 (the 0xFA00 + 4k loop) and FBFC
# (0xCAFE0001); FA80, FB00, FB10 and FBF8 were never written, and FC00 is past the window.
import contextlib, io, re
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    mism = d.cmd_snoop_check(a, [], 1000)
flagged = sorted({int(m, 16) for m in re.findall(r"^MISMATCH .*? read ([0-9A-F]{8})=", buf.getvalue(), re.M)})
want = [0x2FA10, 0x2FA14, 0x2FA20, 0x2FA24, 0x2FA40, 0x2FA50, 0x2FBFC]
need(f"cpu.0: the snoop replay flags {mism} read beat(s) at {[f'{x:05X}' for x in flagged]}, "
     f"want the 7 at written dwords {[f'{x:05X}' for x in want]}", mism == 7 and flagged == want)
# DUT D: the overrun
dd = load("cpu.3")
cd = count(dd)
need("cpu.3: events delivered and LOST records, samples after skips", cd[0x30] > 0 and cd[0x32] > 0 and cd[0x21] > 0)
need("cpu.3: LOST totals plus delivered events = the 3972 events driven (900 writes and 72 read beats while stalled, 3000 writes while draining)",
     sum(r.f["lost"] for r in dd.recs if r.type == 0x32) + cd[0x30] + cd[0x31] == 3972)
# the system bench: the display log, a sampler and the forced OUT
s = load("system.bin")
cs = count(s)
need(f"system: {s.skipped} byte(s) outside records", s.skipped <= 33)
need("system: ALIVE, samples, one OUT 0xA4 = 01",
     cs[0x1F] >= 1 and cs[0x20] + cs[0x21] >= 4 and
     sum(1 for r in s.recs if r.type == 0x16 and r.f["port"] == 0xA4 and r.f["val"] == 1) == 1)
need("system: the floppy log's ALIVE and one FDC write 0x92 = 03 (decoded as a SPECIFY byte)",
     cs[0x5F] >= 1 and sum(1 for r in s.recs if r.type == 0x50 and r.f["a"] == 3) == 1 and
     any("WR 92 <- 03" in d.fdc_line(r) for r in s.recs if r.type == 0x50))
_, strg = d.trace_of(s)
need("system: 2^DBG_TRACE_AW = 64 trace entries and the I/O trigger's record decodes as OUT 0x92 = 03, match 1",
     cs[0x43] == 64 and strg is not None and strg["tag"] == 4 and strg["last"] == 0 and
     "OUT port=0092 val=03 match #1" in d.trigger_text(strg))
print("DBGLOG E2E:", "FAIL" if bad else "PASS (RTL bytes -> decode_dbglog.py)")
sys.exit(1 if bad else 0)
PY
