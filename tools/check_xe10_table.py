#!/usr/bin/env python3
"""Re-derive every value of the Xe10 class table (tools/xe10_classes.csv) from its cited capture row.

Each row names a capture (`source`), a line in it and a `quantity`; this check parses the capture
with tools/hwprobe/xe10t/xe10t_decode.py (the decoder the probes are read with, so the arithmetic
is that decoder's and not a second copy of it) and fails when:
  * the cited line is not a timed row of the decoder's grammar (an R row, nop 0, not refused, no
    CONTROL-MISMATCH), or not a capture row the class may come from: the row's tag must be one of
    the class's families (GRW/GRD/TCRW... for the GVRAM, XCR/XCW... for the text RAM, PKR/PKW for
    the PEGC packed bank), its raster phase the row's (the display-stopped `O` state stands for V)
    and its display mode the row's (an XE10X /RDLAT tag carries 24/31/48; the older kits ran at 24);
  * the value the decoder gives for the quantity, to one decimal, is not the row's `ns`:
      pit   the PIT ns per unit (r["pit_ns"]);  art  the ARTIC ns per unit (r["gross_ns"]);
      net   pit less the control loop's pit at the same nop (r["pit_ns"] - r["ctl_pit_ns"]): what
            the access itself costs, the shell taken out (a latency class);
      pair  pit / 2 of a word-across-a-dword row (a _W3 tag): one access of the pair;
      rwipe docs/probes/RWIPE-XE10.TXT's STEP line: the logo wipe's 4000-word `rep stosw` fill,
            (F - S) ARTIC ticks x 1e9 / 307200 / 4000;
  * a latency class cites anything but `net`, or a rate class cites `net`;
  * an XE10X /RDLAT sweep exists for the cited tag and the decoder's shape verdict for it is not
    the class's (LATENCY for a read, RATE for a store): the table's shape column is the capture's.

Usage:
  tools/check_xe10_table.py              check the table (exit 1 on any failure)
  tools/check_xe10_table.py --selftest   the rules on planted rows
"""
from __future__ import annotations

import copy
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools/hwprobe/xe10t"))
import gen_xe10_table as gen  # noqa: E402
import xe10t_decode as dec  # noqa: E402

ARTIC_HZ = 307200
RWIPE_WORDS = 4000

# The capture families a class may cite: {(device, cls): {section: (tag regex, ...)}}. A /MISAL2
# tag is FAM_K_PH (K the dword offset), a /MISAL tag FAM_xK_PH, an /RDLAT tag FAM_MODEPH, an XE10T
# tag a bare name (its rows run with the display stopped).
FAMILIES = {
    ("gvram", "rd_plain_1w"): {"RDLAT": ("GRW",), "MISAL2": ("GRW_0",), "CELLS": ("BRW",)},
    ("gvram", "rd_plain_2w"): {"RDLAT": ("GRD",), "MISAL2": ("GRD_0", "GRW_1"), "CELLS": ("BRD",)},
    ("gvram", "rd_tcr_1w"):   {"RDLAT": ("TCRW",), "MISAL2": ("TCRW_0",)},
    ("gvram", "rd_tcr_2w"):   {"MISAL2": ("TCRW_1",), "CELLS": ("TCRWM", "TCRD")},
    ("gvram", "wr_plain_1w"): {"RDLAT": ("GW",), "MISAL": ("PLN_W0",), "GVRAM": ("W16",), "CELLS": ("BW",)},
    ("gvram", "wr_plain_2w"): {"MISAL": ("PLN_D0", "PLN_W1"), "GVRAM": ("W32",), "CELLS": ("GWM", "GD", "BD")},
    ("gvram", "wr_tdw_1w"):   {"RDLAT": ("TDW",), "MISAL": ("TDW_W0", "TDW_W3"), "GRCG": ("TDW16",)},
    ("gvram", "wr_tdw_2w"):   {"MISAL": ("TDW_D0", "TDW_W1"), "GRCG": ("TDW32",), "CELLS": ("TDWM", "TDD")},
    ("gvram", "wr_rmw_1w"):   {"RDLAT": ("RMW",), "MISAL": ("RMW_W0",), "GRCG": ("RMWSTOSW",),
                               "RWIPE": ("FILL",)},
    ("gvram", "wr_rmw_2w"):   {"MISAL": ("RMW_D0", "RMW_W1"), "GRCG": ("RMW32",), "CELLS": ("RMWM", "RMD")},
    ("tram", "rd_1w"):        {"RDLAT": ("XCR", "XCRS", "XARS"), "MISAL2": ("XCR_0", "XAR_0"),
                               "CELLS": ("XCR", "XCRS", "XARS")},
    ("tram", "rd_2w"):        {"MISAL2": ("XCR_1", "XAR_1"), "CELLS": ("XCRM",)},
    ("tram", "wr_1w"):        {"RDLAT": ("XCW", "XCWS", "XAWS"), "MISAL2": ("XCW_0", "XAW_0", "XCB_0"),
                               "CELLS": ("XCW", "XCWS", "XAWS")},
    ("tram", "wr_2w"):        {"MISAL2": ("XCW_1", "XAW_1"), "CELLS": ("XCWM",)},
    ("pegc", "rd"):           {"RDLAT": ("PKR",), "MISAL2": ("PKR_0", "PKR_1"), "CELLS": ("PKR",),
                               "PKAB": ("PKR", "PKRF")},
    ("pegc", "wr"):           {"RDLAT": ("PKW",), "MISAL2": ("PKW_0", "PKD_0"), "CELLS": ("PKW",),
                               "PKAB": ("PKW", "PKW_0", "PKW1ST", "PKWAFT", "PKWLATE", "PKDF")},
}
# XE10Y /CELLS (kit 3) tags FAM_<MODE><PH>: 31 = 31 kHz with the 256-colour mode off; 3P = 31 kHz
# 640x400 with it on and 48 = 640x480 with it on (both the table's mode 48); 2P = 24 kHz with it
# on, the table's fourth column 24P (its text read differs: CELLS XCR_2PA 759.0 against 692.2).
CELLS_MODE = {"31": "31", "3P": "48", "48": "48", "2P": "24P"}


class Captures:
    def __init__(self):
        self._c = {}

    def get(self, rel: str):
        if rel not in self._c:
            path = ROOT / rel
            data = path.read_bytes()
            if "RWIPE" in path.name:
                self._c[rel] = ("rwipe", data.decode("latin-1").splitlines())
            else:
                cap = dec.parse(data, path.name)
                dec.analyse(cap)
                self._c[rel] = ("xe10t", cap)
        return self._c[rel]


def tag_cell(sec: str, tag: str):
    """-> (family, mode, phase) of a capture tag, phase O folded into V."""
    if sec == "RDLAT":
        m = re.fullmatch(r"([A-Z]+)_(24|31|48)([OAV])", tag)
        if not m:
            return None
        fam, mode, ph = m.groups()
    elif sec == "CELLS":
        m = re.fullmatch(r"([A-Z]+)_(31|2P|3P|48)([AV])", tag)
        if not m:
            return None
        fam, mode, ph = m.group(1), CELLS_MODE[m.group(2)], m.group(3)
    elif sec == "PKAB":      # XE10Y /PKAB: <tag>_<group><round>, every window at 24 kHz on the A place
        m = re.fullmatch(r"(.+)_(M|R|FA|FV|C|N|D)([1-9])", tag)
        if not m:
            return None
        fam, mode, ph = m.group(1), "24", "V" if m.group(2) == "FV" else "A"
    elif sec in ("MISAL", "MISAL2"):
        m = re.fullmatch(r"(.+)_([OAV])", tag)
        if not m:
            return None
        fam, ph = m.groups()
        mode = "24"
    else:   # XE10T's own sections: the prompt state, the display stopped
        fam, mode, ph = tag, "24", "O"
    return fam, mode, "V" if ph == "O" else ph


def derive(row: dict, caps: Captures) -> tuple[float | None, str | None]:
    """-> (value, None) or (None, why)."""
    kind, obj = caps.get(row["source"])
    line = int(row["line"])
    q = row["quantity"]
    fams = FAMILIES.get((row["device"], row["cls"]))
    if fams is None:
        return None, f"no capture families for class {row['device']}/{row['cls']}"
    if kind == "rwipe":
        if q != "rwipe" or "RWIPE" not in fams:
            return None, "an RWIPE capture is cited only as the rwipe fill of a GRCG RMW word class"
        if not (1 <= line <= len(obj)):
            return None, f"line {line} is past the capture"
        toks = obj[line - 1].split()
        if toks[:2] != ["RWIPE", "STEP"]:
            return None, f"line {line} is not an RWIPE STEP line"
        kv = dict(t.split("=", 1) for t in toks[2:] if "=" in t)
        cell_mode = row["mode"] if row["basis"] == "measured" else row["basis"][-2:]
        if row["phase"] != "A" or cell_mode != "24":
            return None, "the wipe's fill steps run on graphics lines at 24 kHz (phase A, mode 24)"
        return (int(kv["F"], 16) - int(kv["S"], 16)) * 1e9 / ARTIC_HZ / RWIPE_WORDS, None
    if q == "rwipe":
        return None, "rwipe cites an RWIPE capture"
    rr = [r for r in obj.rows if r["line"] == line]
    if not rr or rr[0]["kind"] != "R":
        return None, f"line {line} is not an R row"
    r = rr[0]
    if r.get("refused") or "CONTROL-MISMATCH" in r["flags"]:
        return None, f"line {line} ({r['tag']}) is refused by the decoder ({','.join(r['flags'])})"
    if r["nop"] != 0:
        return None, f"line {line} ({r['tag']}) is nop={r['nop']}, the table takes nop 0"
    tags = fams.get(r["sec"])
    if tags is None:
        return None, f"line {line} is section {r['sec']}, which class {row['cls']} does not cite"
    cell = tag_cell(r["sec"], r["tag"])
    if cell is None or cell[0] not in tags:
        return None, f"line {line} tag {r['tag']} is not one of {row['cls']}'s families {tags}"
    if (cell[1], cell[2]) != (row["mode"] if row["basis"] == "measured" else row["basis"][-2:],
                              row["phase"]):
        return None, (f"line {line} tag {r['tag']} is mode {cell[1]} phase {cell[2]}, the row is "
                      f"{row['mode']}{row['phase']} ({row['basis']})")
    if q == "pit":
        return r["pit_ns"], None
    if q == "pair":
        if not cell[0].endswith("_W3"):
            return None, f"pair cites a word-across-a-dword row (a _W3 tag), not {r['tag']}"
        return r["pit_ns"] / 2, None
    if q == "art":
        return r["gross_ns"], None
    if q == "net":
        return r["pit_ns"] - r["ctl_pit_ns"], None
    return None, f"quantity {q!r}"


def rdlat_shape(row: dict, caps: Captures) -> tuple[str | None, str | None]:
    """The decoder's LATENCY/RATE verdict for the cited RDLAT tag's sweep, or (None, None)."""
    kind, obj = caps.get(row["source"])
    if kind != "xe10t":
        return None, None
    rr = [r for r in obj.rows if r["line"] == int(row["line"])]
    if not rr or rr[0]["sec"] not in ("RDLAT", "CELLS"):
        return None, None
    tag = rr[0]["tag"]
    pts = sorted((r["nop"], r["pit_ns"], r["ctl_pit_ns"]) for r in obj.rows
                 if r["sec"] == rr[0]["sec"] and r["kind"] == "R" and r["tag"] == tag and not r.get("refused"))
    if len(pts) < 2 or pts[0][0] != 0:
        return None, None
    return dec.rd_shape(pts)["verdict"], tag


def check(rows: list[dict], caps: Captures, out=print) -> int:
    bad = 0
    for p in gen.problems(rows):
        out("FAIL table shape: " + p)
        bad += 1
    for row in rows:
        want_q = ("net",) if row["shape"] == "latency" else ("pit", "art", "rwipe", "pair")
        if row["quantity"] not in want_q:
            out(f"FAIL {row['name']}: a {row['shape']} class cites {row['quantity']}, not {'/'.join(want_q)}")
            bad += 1
            continue
        v, why = derive(row, caps)
        if why:
            out(f"FAIL {row['name']}: {row['source']}:{row['line']}: {why}")
            bad += 1
            continue
        if "%.1f" % v != row["ns"]:
            out(f"FAIL {row['name']}: {row['source']}:{row['line']} derives {v:.1f} ns ({row['quantity']}), "
                f"the table says {row['ns']}")
            bad += 1
            continue
        verdict, tag = rdlat_shape(row, caps)
        if verdict is not None and verdict != row["shape"].upper():
            out(f"FAIL {row['name']}: the capture's {tag} sweep is {verdict}, the class is {row['shape']}")
            bad += 1
    return bad


def selftest() -> int:
    rows = gen.read_rows()
    caps = Captures()
    fails = 0

    def expect(what: str, rws: list[dict], want_fail: bool):
        nonlocal fails
        msgs = []
        n = check(rws, caps, out=msgs.append)
        ok = (n > 0) == want_fail
        print(("ok   " if ok else "FAIL ") + what + ("" if not msgs else f"  [{msgs[0]}]"))
        if not ok:
            fails += 1

    expect("the table as committed passes", rows, False)
    r = copy.deepcopy(rows)
    r[0]["ns"] = "%.1f" % (float(r[0]["ns"]) + 0.5)
    expect("a drifted value (+0.5 ns) fails", r, True)
    r = copy.deepcopy(rows)
    i = next(k for k, x in enumerate(r) if x["name"] == "GV_RD_PLAIN_1W_24A")
    r[i]["line"] = str(int(r[i]["line"]) + 1)          # the nop=2 row of the same sweep
    expect("a citation moved to a nop>0 row fails", r, True)
    r = copy.deepcopy(rows)
    j = next(k for k, x in enumerate(r) if x["name"] == "GV_RD_PLAIN_1W_24V")
    r[i]["line"], r[i]["ns"] = r[j]["line"], r[j]["ns"]   # an A row citing the V capture row
    expect("an A row citing a V capture row fails", r, True)
    r = copy.deepcopy(rows)
    k = next(k for k, x in enumerate(r) if x["name"] == "TX_RD_1W_24V")
    r[k]["line"], r[k]["ns"] = r[j]["line"], r[j]["ns"]   # a text class citing a GVRAM row
    expect("a text RAM class citing a GVRAM row fails", r, True)
    r = copy.deepcopy(rows)
    r[i]["quantity"] = "pit"
    r[i]["ns"] = "%.1f" % derive(dict(r[i], quantity="pit"), caps)[0]
    expect("a latency class priced on the gross pit fails", r, True)
    r = copy.deepcopy(rows)
    m = next(k for k, x in enumerate(r) if x["name"] == "TX_WR_1W_31V")
    r[m]["shape"] = "latency"
    expect("a store class marked latency fails (shape rule and the capture's RATE verdict)", r, True)
    r = copy.deepcopy(rows)
    f = next(k for k, x in enumerate(r) if x["name"] == "TX_RD_2W_31V")
    r[f]["ns"] = "%.1f" % (float(r[f]["ns"]) - 1)
    expect("a fallback row that is not its source row's copy fails", r, True)
    r = copy.deepcopy(rows)
    g = next(k for k, x in enumerate(r) if x["name"] == "TX_RD_1W_24PA")
    h = next(k for k, x in enumerate(r) if x["name"] == "TX_RD_1W_24A")
    for fld in ("ns", "source", "line"):
        r[g][fld] = r[h][fld]                          # the 24P cell priced on a 24 kHz row
    expect("a measured 24P cell citing a 256-colour-off 24 kHz row fails", r, True)
    # the kit-3 sections' tags (XE10Y /CELLS, /PKAB) map to the table's cells
    for sec, tag, want in (("CELLS", "TCRWM_31A", ("TCRWM", "31", "A")), ("CELLS", "XCWM_3PV", ("XCWM", "48", "V")),
                           ("CELLS", "PKW_2PA", ("PKW", "24P", "A")), ("CELLS", "BRW_48A", ("BRW", "48", "A")),
                           ("PKAB", "PKW_0_M2", ("PKW_0", "24", "A")), ("PKAB", "PKW1ST_FV3", ("PKW1ST", "24", "V")),
                           ("CELLS", "TCRWM_24A", None)):
        got = tag_cell(sec, tag)
        ok = got == want
        print(("ok   " if ok else "FAIL ") + f"tag_cell({sec}, {tag}) = {got}")
        fails += 0 if ok else 1
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        rc = selftest()
        print("check_xe10_table selftest: " + ("PASS" if rc == 0 else "FAIL"))
        return rc
    rows = gen.read_rows()
    bad = check(rows, Captures())
    if bad:
        print(f"check_xe10_table: {bad} failure(s)")
        return 1
    meas = sum(1 for r in rows if r["basis"] == "measured")
    print(f"check_xe10_table: all {len(rows)} classes re-derive from their capture rows "
          f"({meas} measured, {len(rows) - meas} fallbacks)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
