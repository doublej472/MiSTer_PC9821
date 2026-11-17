#!/usr/bin/env python3
"""shbank_decode.py - decode an SHBANK capture (tools/hwprobe/shbank/shbank.s): which image the
0xF8000-0xFFFFF window shows after each 0x043D/0x043F write order, beside the core's answer.

    shbank_decode.py CAPTURE [CAPTURE2]   one capture, or two (core first, then the machine)
    shbank_decode.py --selftest

A row's window is NAMED by its signature (8 id bytes, the sum of F8000:0000-0FFF, F8E8F/F8E90)
against the capture's own reference rows: TOP = the as-found state (the main BIOS top with its
shadow; ASF, and REF 02), ITF = REF 00, bank x = REF Ex (043D=00 first, SHADOWW.TXT st04/st05).
A signature several references share is named by all of them (on the Xe10 the ITF is BANK4, so
ITF = REF E8; bank 7 is TOP's ROM, so REF EE differs from TOP only at F8E90: 00 against 04).

THE PREDICTIONS (state: ITF, TOP or bank 0-7):
  core-fix   the core with the shadow-bank fix (pc9821_iobus.sv next_bank_043f: a 0x043F
             0xEx select is HELD OFF while 0x043D = 0x02 is latched, top_bank == BANK_BIOS_TOP);
             0x043D 00/10/18 -> ITF, 02/12 -> TOP (`8'h00, 8'h10, 8'h18: top_bank <= BANK_ITF;`)
  core-old   the core before that fix = QEMU pc98 (mem_bankflip_write / mem_bankctl_write): every
             0xEx select moves the window, whatever 0x043D last wrote
"""
from __future__ import annotations

import re
import sys

ROW = re.compile(r"^RES (\w+) (\w\w) : (.*?) id=(.*?) sum=(\w+) e8f=(\w+) e90=(\w+) restore43D=(\w+) (\w+)")
ASF = re.compile(r"^ASF (before|after) id=(.*?) sum=(\w+) e8f=(\w+) e90=(\w+)")


def parse(text: str) -> dict:
    cap = {"rows": [], "asf": {}, "done": False, "lastrow": None}
    for raw in text.splitlines():
        line = raw.strip()
        m = ROW.match(line)
        if m:
            kind, arg, writes, idb, s, e8f, e90, r43, ok = m.groups()
            cap["rows"].append({"name": "%s %s" % (kind, arg), "writes": writes,
                                "sig": (idb.strip(), s, e8f, e90), "rest": r43, "ok": ok})
            continue
        m = ASF.match(line)
        if m:
            cap["asf"][m.group(1)] = (m.group(2).strip(), m.group(3), m.group(4), m.group(5))
        if line.startswith("ROW "):
            cap["lastrow"] = line[4:]
        if line == "SHBANK DONE":
            cap["done"] = True
    return cap


def writes_of(s: str):
    return [(p, int(v, 16)) for p, v in re.findall(r"(043D|043F)=(\w\w)", s)]


def predict(writes, fix: bool) -> str:
    st = "TOP"                      # the as-found state at a DOS prompt (SHADOWW.TXT st01)
    for port, v in writes:
        if port == "043D":
            if v in (0x00, 0x10, 0x18):
                st = "ITF"
            elif v in (0x02, 0x12):
                st = "TOP"
        elif (v >> 4) == 0xE and not (fix and st == "TOP"):
            st = "bank %d" % ((v >> 1) & 7)
    return st


def names(cap) -> dict:
    """signature -> the reference names that show it"""
    ref = {}
    asf = cap["asf"].get("before")
    if asf:
        ref.setdefault(asf, []).append("TOP")
    for r in cap["rows"]:
        if r["name"].startswith("REF "):
            a = r["name"][4:]
            n = "ITF" if a == "00" else "TOP" if a == "02" else "bank %d" % ((int(a, 16) >> 1) & 7)
            if n not in ref.setdefault(r["sig"], []):
                ref[r["sig"]].append(n)
    return ref


def report(cap) -> list:
    out = []
    ref = names(cap)
    for k in ("before", "after"):
        if k in cap["asf"]:
            out.append("ASF %s: %s" % (k, " ".join(cap["asf"][k])))
    if cap["asf"].get("before") != cap["asf"].get("after"):
        out.append("  WARNING: the as-found window differs after the run")
    for r in cap["rows"]:
        shown = ref.get(r["sig"], ["UNKNOWN"])
        w = writes_of(r["writes"])
        pf, po = predict(w, True), predict(w, False)
        v = []
        if pf in shown:
            v.append("core-fix")
        if po in shown:
            v.append("core-old/QEMU")
        out.append("%-7s %-34s shows %-22s | core-fix %-7s core-old/QEMU %-7s -> %s%s" % (
            r["name"], r["writes"], "=".join(shown), pf, po, "+".join(v) if v else "NEITHER",
            "" if r["ok"] == "OK" else "  (restore NOMATCH, 043D left 02)"))
    if not cap["done"]:
        out.append("NOT DONE: the last row started was %s (a hang there)" % cap["lastrow"])
    return out


# ---- selftest ---------------------------------------------------------------------------------------
SIGS = {"TOP": ("A1 00 00 00 00 00 00 00", "1234", "00", "04"),
        "ITF": ("EB 00 00 00 00 00 00 00", "5678", "B0", "57")}


def bank_sig(n):
    if n == 7:
        return ("A1 00 00 00 00 00 00 00", "1234", "00", "00")
    if n == 4:
        return SIGS["ITF"]
    return ("%02X 11 22 33 44 55 66 77" % (0x10 + n), "%04X" % (0x100 * n), "00", "%02X" % n)


def plant(fix: bool) -> str:
    src = open(__file__.replace("shbank_decode.py", "shbank.s")).read()
    rows = re.findall(r'^n_\w+:\s+\.ascii "(.*?)\$"', src, re.M)
    L = ["SHBANK v1", "STATE first-touch 043D=FF 043F=C4 053D=1F",
         "ASF before id=%s sum=%s e8f=%s e90=%s" % SIGS["TOP"]]
    for name in rows:
        st = predict(writes_of(name.split(" : ")[1]), fix)
        sig = SIGS.get(st) or bank_sig(int(st.split()[1]))
        L.append("ROW " + name)
        L.append("RES %s id=%s sum=%s e8f=%s e90=%s restore43D=02 OK" % ((name,) + sig))
    L += ["ASF after id=%s sum=%s e8f=%s e90=%s" % SIGS["TOP"], "SHBANK DONE"]
    return "\r\n".join(L) + "\r\n"


def selftest() -> int:
    bad = 0
    for fix, want in ((True, "core-fix"), (False, "core-old/QEMU")):
        cap = parse(plant(fix))
        rep = report(cap)
        rows = [ln for ln in rep if " -> " in ln]
        if len(rows) != len(cap["rows"]) or not rows:
            bad += 1
        for ln in rows:
            if want not in ln.rsplit(" -> ", 1)[1]:
                print("selftest %s: %s" % (want, ln))
                bad += 1
    # the two models must disagree somewhere, or the probe could not tell them apart
    a = [ln.rsplit(" -> ", 1)[1] for ln in report(parse(plant(True))) if " -> " in ln]
    if all("core-old" in x for x in a):
        print("selftest: no row separates core-fix from core-old")
        bad += 1
    print("selftest: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main(argv) -> int:
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    for p in argv[1:]:
        print("==== " + p)
        print("\n".join(report(parse(open(p, "rb").read().decode("ascii", "replace")))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
