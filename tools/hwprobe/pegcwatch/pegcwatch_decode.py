#!/usr/bin/env python3
"""pegcwatch_decode.py - read a PEGCWATCH capture into the PEGC-scope verdict.

Usage:
    python3 tools/hwprobe/pegcwatch/pegcwatch_decode.py PEGC.TXT [PEGC2.TXT ...]
    python3 tools/hwprobe/pegcwatch/pegcwatch_decode.py --rows PEGC.TXT   (every row, raw)

PEGCWATCH (tools/hwprobe/pegcwatch/pegcwatch.s) runs a child under two chained
hooks and prints the PEGC state it left behind. THE ONE QUESTION this reads off
is: does DOOM's `pc9821.drv` need only PEGC's display half (packed
scanout + the 256-entry palette + the VRAM route - 41-51 LABs) or also its
plane/dot engine (69-76 LABs)?

THE ROW SET, and what each one is evidence for:

  BASE / POST   the 8-byte PEGC state before the hooks and again after the child
                returned. `A0A` is 0x9A0 index 0x0A = the analog-256 / PEGC mode
                bit, the machine's OWN 256-colour probe; `P6A` is port 0x6A read
                back (NP2kai gdc_i6a returns gdc.mode2); `W54D` is the BIOS/GDC
                graphics work byte, whose bit 7 the firmware's own PEGC select
                sets; A04/A08/A0D/A03/M68 are the surrounding mode bits.
  MODE n T=...  one row per OBSERVED change of (P6A, A0A, A04, W54D), stamped with
                the ARTIC tick. This is the timeline: it dates the transition and
                shows the 0x6A value that caused it (0x21 = the PEGC select).
  I18 n ...     one INT 18h call: the registers, then PRE6A/PREA0A and
                POST6A/POSTA0A around the CHAINED BIOS handler. A row whose
                PRE/POST differ is the BIOS performing that transition - which is
                how "which INT/AH entered the mode" gets answered from the run
                rather than guessed out of the ROM.
  PLREG ADDR=   one per sampled register, with LAST (last byte seen) and NZ (seen
                non-zero). Read only while the PEGC MMIO view is on, because with
                it off 0xE0000-0xE7FFF is GVRAM and those addresses are pixels.
  SAMP          coverage: samples taken, samples taken with the view ON, the first
                tick the 256-colour bit was seen set, and the INT 18h counts.
  HOOK / VEC    the as-found and restored vectors (the proof nothing was left
                hooked); RUN is the loader's CF/AX; FAIL/NOFAIL the self-check.
  BEGIN / END   the capture's frame: END missing means the wrapper or the child
                died and everything above it is still valid.

THE VERDICT, and the two ways this decoder refuses to give one:

  POST A0A=00, no MODE row with A0A=01   -> PEGC 256-colour was NOT entered by
                                            this run: no PEGC demand from it.
  A0A=01 somewhere, every PLREG NZ=0     -> DISPLAY HALF ONLY (41-51 LABs).
  A0A=01 somewhere, any PLREG NZ=1       -> DISPLAY + PLANE ENGINE (69-76 LABs),
                                            and the row names which register.

  * `VIEWON=0` with `A0A=01`: not one sample was taken with the MMIO view up
    (the usual cause is an extender child that stops delivering INT 1Ch to a
    real-mode handler once it is in protected mode). The display half is then
    CONFIRMED and the plane engine is UNOBSERVED - a capture that did not look,
    not a driver that did nothing - and this decoder says so and exits 3 rather
    than reading NZ=0 as "no engine".
  * `SAMP N=0001 VIEWON=0000 MODE256T=FFFFFFFF` with no INT 18h call at all is
    NO OBSERVATION: the child may never have reached its video set-up (a loader
    failure shows up in RUN CF=01 and its DOS AX code). Exit 2.

A PLREG NZ=1 pair is worth splitting when it appears: 0E0004/0E0006 are the PPM
bank selects for the packed-pixel windows (0xA8000/0xB0000) - a driver that
merely PAGES GVRAM to write pixels - while 0E0104-0E0118 are the plane engine's
own registers (ROP, mask, length, shift, palette compare), which no packed-pixel
paint touches. The decoder prints them as two groups.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import argparse
import re
import sys

ARTIC_HZ = 307_200.0

# Every row kind this decoder recognises. Keep this list in step with the emitter's
# own message table, so a row the decoder reads and the emitter never prints cannot
# ship as a silent "no observation".
KINDS = ("BEGIN", "USAGE", "BASE", "CMD", "HOOK", "MEM", "MODE", "MODES",
         "I18", "PLANE", "PLREG", "SAMP", "RUN", "VEC", "NOFAIL", "FAIL",
         "WARN", "END")

# 0x9A0 index -> what the bit means (NP2kai io/gdc.c gdc_i9a0; the same table is
# in this core's pc9821_iobus.sv gdc_ff2_query).
A9A0 = {
    "A0A": "0x9A0 idx 0x0A = analog-256 (the PEGC/256-colour mode bit)",
    "A04": "0x9A0 idx 0x04 = mode2 bit 0 (the analog-16 select)",
    "A08": "0x9A0 idx 0x08 = mode2 bit 3 (PEGC register write enable)",
    "A0D": "0x9A0 idx 0x0D = GDCANALOG_256E",
    "A03": "0x9A0 idx 0x03 = mode1 bit 7 (DISP)",
    "P6A": "port 0x6A = the extended-video mode f/f (NP2kai gdc_i6a -> mode2)",
    "W54D": "0000:054D = the BIOS/GDC graphics work byte (bit 7 = the PEGC select)",
    "M68": "port 0x68 = MODE FF1",
}

# The ten sampled window offsets, split by what they are evidence FOR.
WINDOW_GROUP = {
    0x0004: "PPM bank A8 (0xA8000-0xAFFFF) - window paging, the cheap half",
    0x0006: "PPM bank B0 (0xB0000-0xB7FFF) - window paging, the cheap half",
    0x0104: "PLANE ENGINE plane access / write mask",
    0x0108: "PLANE ENGINE ROP low",
    0x0109: "PLANE ENGINE ROP high",
    0x010C: "PLANE ENGINE pixel mask",
    0x0110: "PLANE ENGINE block length",
    0x0112: "PLANE ENGINE read/write bit shift",
    0x0114: "PLANE ENGINE palette compare 1",
    0x0118: "PLANE ENGINE palette compare 2",
}
ENGINE_OFFSETS = {o for o, d in WINDOW_GROUP.items() if d.startswith("PLANE")}

ROW = re.compile(r"^PEGCWATCH\s+(\S+)\s*(.*)$")
KV = re.compile(r"([A-Z0-9_]+)=(\S+)")


ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")


def clean(s: str) -> str:
    """Strip the console's escape and overstrike noise from a row's payload.

    The capture is a DOS console redirect, so a row can carry ANSI sequences and `\b` overstriking
    (`file` calls the real DOOM capture "ASCII text, with escape sequences, with overstriking").
    Before this, one leaked `[` landed in the CMD row's TAIL and the child's name read as
    `doom.exe  tail: [`.
    """
    s = ANSI.sub("", s)
    out: list[str] = []
    for ch in s:
        if ch == "\x08":      # overstriking: print, backspace, print again
            if out:
                out.pop()
            continue
        out.append(ch)
    return "".join(out)


class Capture:
    def __init__(self, path: str, text: str):
        self.path = path
        self.text = text
        self.rows: list[tuple[str, dict[str, str], str]] = []
        # ROWS ARE FOUND BY SCANNING FOR THE MARKER, NOT BY SPLITTING INTO LINES. The machine's
        # console can lose a row's line terminator, and the real DOOM capture has exactly that:
        # `PEGCWATCH NOFAILPEGCWATCH END V=1` arrived as ONE physical line, so line-anchored matching
        # read a single row named `NOFAILPEGCWATCH` and the END marker vanished - a COMPLETE run
        # reported as `TORN CAPTURE`, which is the worst direction for the error to point. Splitting
        # on the marker makes each occurrence start a row, so a lost newline costs nothing; a row's
        # payload still ends at its own line break.
        for part in re.split(r"PEGCWATCH\s+", text)[1:]:
            seg = clean(part.split("\n", 1)[0].split("\r", 1)[0]).strip()
            if not seg:
                continue
            kind = seg.split()[0]
            rest = seg[len(kind):].strip()
            self.rows.append((kind, dict(KV.findall(rest)), rest))
        self.kinds = [k for k, _, _ in self.rows]

    def of(self, kind: str):
        return [(kv, rest) for k, kv, rest in self.rows if k == kind]

    def one(self, kind: str):
        rows = self.of(kind)
        return rows[0][0] if rows else {}

    @property
    def complete(self) -> bool:
        return "END" in self.kinds and "BEGIN" in self.kinds


def hexint(d: dict, key: str, default=None):
    v = d.get(key)
    if v is None:
        return default
    try:
        return int(v, 16)
    except ValueError:
        return default


def artic_ns(t: int) -> float:
    return t * 1e9 / ARTIC_HZ


def cap_state(kv: dict) -> dict[str, int]:
    return {k: hexint(kv, k, 0) for k in ("P6A", "A0A", "A04", "A08", "A0D", "A03", "W54D", "M68")}


def fmt_state(s: dict[str, int]) -> str:
    return " ".join(f"{k}={s[k]:02X}" for k in ("P6A", "A0A", "A04", "A08", "A0D", "A03", "W54D", "M68"))


def report(cap: Capture, show_rows: bool) -> int:
    print(f"=== PEGCWATCH capture: {cap.path}")
    cmd = cap.one("CMD")
    if cmd:
        print(f"    child: {cmd.get('NAME', '?')}  tail: {cmd.get('TAIL', '[]')}")
    base = cap.one("BASE")
    post = cap.one("POST")
    modes = [kv for kv, _ in cap.of("MODE")]
    i18 = [kv for kv, _ in cap.of("I18")]
    plreg = [kv for kv, _ in cap.of("PLREG")]
    samp = cap.one("SAMP")
    plane = cap.one("PLANE")
    run = cap.one("RUN")

    if show_rows:
        for line in cap.text.splitlines():
            if line.strip().startswith("PEGCWATCH"):
                print(f"    {line.strip()}")

    print()
    print("STATE")
    for label, kv in (("BASE", base), ("POST", post)):
        if kv:
            print(f"  {label} T={kv.get('T', '?')}  {fmt_state(cap_state(kv))}")

    # --- the timeline -----------------------------------------------------
    print()
    print("TRANSITIONS OBSERVED (MODE rows; T in ARTIC ticks = 1/307200 s)")
    if not modes:
        print("  (none: the sampled tuple never changed in this run)")
    for i, kv in enumerate(modes):
        t = hexint(kv, "T", 0)
        note = ""
        if hexint(kv, "A0A", 0) & 1:
            note = "  <- analog-256 SET"
        if hexint(kv, "P6A", 0) == 0x21:
            note += "  <- 0x6A=0x21 (the PEGC MMIO view select)"
        if hexint(kv, "W54D", 0) & 0x80:
            note += "  <- work byte 0x54D bit 7 set (the firmware's PEGC select)"
        print(f"  MODE {i} T={t} ({artic_ns(t) / 1e6:.2f} ms)  "
              f"P6A={kv.get('P6A')} A0A={kv.get('A0A')} A04={kv.get('A04')} "
              f"W54D={kv.get('W54D')}{note}")

    # --- the INT 18h calls ------------------------------------------------
    print()
    print(f"INT 18h CALLS (the BIOS graphics entry): {len(i18)} recorded, "
          f"{samp.get('I18', '0')} delivered")
    bios_caused = 0
    for i, kv in enumerate(i18):
        pre_a = hexint(kv, "PREA0A", 0)
        post_a = hexint(kv, "POSTA0A", 0)
        ax = hexint(kv, "AX", 0)
        flag = ""
        if pre_a != post_a:
            flag = "  <- THIS CALL CHANGED THE 256-COLOUR BIT"
            bios_caused += 1
        elif hexint(kv, "PRE6A", 0) != hexint(kv, "POST6A", 0):
            flag = "  <- this call changed port 0x6A"
        print(f"  I18 {i} AX={ax:04X} (AH={ax >> 8:02X} AL={ax & 0xFF:02X}) "
              f"BX={kv.get('BX')} CX={kv.get('CX')} DX={kv.get('DX')} "
              f"PRE(6A={kv.get('PRE6A')},A0A={kv.get('PREA0A')}) "
              f"POST(6A={kv.get('POST6A')},A0A={kv.get('POSTA0A')}){flag}")

    # --- the plane/PPM sample --------------------------------------------
    print()
    viewon = hexint(samp, "VIEWON", 0)
    print(f"PLANE/PPM REGISTER SAMPLE (VIEWON={hexint(samp, 'VIEWON', 0)} of "
          f"N={hexint(samp, 'N', 0)} samples, NOP={plane.get('NOP', '?')})")
    if plane:
        print(f"  ever-non-zero bitmask NZ={plane.get('NZ')}")
    nz_rows: list[tuple[int, int, int]] = []
    for kv in plreg:
        addr = int(kv.get("ADDR", "0"), 16)  # printed as 0E<off>
        off = addr & 0xFFFF
        last = int(kv.get("LAST", "0"), 16)
        nz = int(kv.get("NZ", "0"), 16)
        grp = WINDOW_GROUP.get(off, "?")
        mark = ""
        if nz and off in ENGINE_OFFSETS:
            mark = "   <== PLANE ENGINE USED"
        elif nz:
            mark = "   <== window paging only (the cheap half)"
        if nz:
            nz_rows.append((off, last, nz))
        print(f"  0E{off:04X}  LAST={last:02X}  NZ={nz}  {grp}{mark}")

    # --- coverage and self-checks ---------------------------------------
    print()
    if samp:
        m256t = samp.get("MODE256T", "FFFFFFFF")
        t_txt = "never" if m256t.upper().startswith("FFFFFF") else f"tick {m256t}"
        print(f"COVERAGE: samples={samp.get('N')} viewON={samp.get('VIEWON')} "
              f"first-256-colour={t_txt} I18={samp.get('I18')} "
              f"I18kept={samp.get('I18KEPT')} I18dropped={samp.get('I18DROP')} "
              f"I18nested-passed={samp.get('I18REC')}")
    if run:
        print(f"LOADER: CF={run.get('CF')} AX={run.get('AX')}"
              + ("   (CF=01 = DOS refused the load; AX is DOS's error)"
                 if run.get("CF") == "01" else ""))
    vecs = cap.of("VEC")
    unrestored = [rest for _, rest in vecs if "BAD" in rest]
    if unrestored:
        print("!! VECTOR NOT RESTORED: " + "; ".join(unrestored))
    if "FAIL" in cap.kinds:
        print(f"!! self-check FAIL present: {cap.of('FAIL')}")
    if not cap.complete:
        print("!! TORN CAPTURE: no PEGCWATCH END V=1 - the wrapper or the child died.")
        print("   Everything up to the last row is still evidence; re-run UNREDIRECTED")
        print("   to see which row stopped it (the child's own screen is its own).")

    # --- the verdict -----------------------------------------------------
    print()
    a0a_seen = post and (cap_state(post)["A0A"] & 1)
    if not a0a_seen:
        a0a_seen = any(hexint(kv, "A0A", 0) & 1 for kv in modes)
    mode256 = bool(a0a_seen)

    print("VERDICT")
    if not cap.complete:
        print("  INCOMPLETE - the capture has no END row; re-run before reading this.")
        return 2

    if "CMD" not in cap.kinds and "POST" not in cap.kinds:
        print("  CALIBRATION capture: no child was run, so there is no PEGC verdict in it.")
        print("  What it is for: the BASE row is the DOS-prompt state the readback rows are")
        print("  calibrated against. Expect A0A=00 and P6A=00; a BASE row that disagrees")
        print("  means the readback itself is the finding. VIEWON=0 is also expected here")
        print("  (with the MMIO view off, 0xE0000-0xE7FFF is GVRAM and the PLREG rows are")
        print("  framebuffer bytes, not registers) - which is why this is not a verdict.")
        return 0

    if not mode256:
        print("  PEGC 256-colour was NOT entered by this run (A0A stayed clear and no")
        print("  MODE row saw it set). Either the child never reached its video set-up,")
        print("  or its driver is not a PEGC driver. Check the COVERAGE line and the")
        print("  LOADER line above before believing the first reading.")
        if not i18 and hexint(samp, "N", 0) <= 1:
            print("  NO OBSERVATION: no INT 18h call was recorded and the sampler ran")
            print("  at most once - the child did not get as far as its video set-up.")
            return 2
        return 0

    print("  PEGC 256-colour WAS entered (analog-256 set).")
    if bios_caused:
        print(f"  ... and the BIOS did it: {bios_caused} INT 18h row(s) show PRE/POST")
        print("      straddling the transition, so that AH is the route (see the rows).")
    else:
        print("  ... by the driver's own port writes (no INT 18h row changed the bit),")
        print("      so the capture's MODE row with P6A=21 is the write that did it.")

    if viewon == 0:
        print("  PLANE ENGINE: UNOBSERVED, not absent - not one sample was taken with")
        print("  the PEGC MMIO view on (VIEWON=0), which is what an extender child in")
        print("  protected mode does to a real-mode INT 1Ch hook. The DISPLAY HALF is")
        print("  confirmed; the plane engine is an open question. Options: re-run and")
        print("  check VIEWON grew, or accept the display half and let a functional")
        print("  test (a garbled fill on the core) be the engine evidence.")
        if nz_rows:
            print("  NOTE: PLREG rows claim NZ=1 while VIEWON=0 - the emitter only sets")
            print("  NZ from a view-on sample, so this capture was edited or torn; do not")
            print("  read those rows as engine use.")
        return 3
    if not nz_rows:
        print("  DISPLAY HALF ONLY: not one plane/PPM register was seen non-zero over")
        print(f"  {viewon} view-on samples, so this driver paints through the window and")
        print("  never programs the engine. 41-51 LABs, not 69-76.")
        return 0

    grp_engine = [o for o, _, _ in nz_rows if o in ENGINE_OFFSETS]
    grp_window = [o for o, _, _ in nz_rows if o not in ENGINE_OFFSETS]
    if grp_engine:
        print("  DISPLAY + PLANE ENGINE: the engine's own registers were seen non-zero:")
        print("    " + ", ".join(f"0E{o:04X}" for o in grp_engine))
        if grp_window:
            print("  (and the window-paging registers too: "
                  + ", ".join(f"0E{o:04X}" for o in grp_window) + ")")
        print("  Budget the full 69-76 LABs, not the display half.")
        return 0
    print("  DISPLAY + WINDOW PAGING ONLY: only the PPM bank registers were seen")
    print("  non-zero (" + ", ".join(f"0E{o:04X}" for o in grp_window) + "), which is a driver")
    print("  PAGING GVRAM to write pixels - still the cheap half; no engine register")
    print("  (0E0104-0E0118) moved. 41-51 LABs.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("captures", nargs="+")
    ap.add_argument("--rows", action="store_true",
                    help="print every PEGCWATCH row raw, in order, as well as the table")
    args = ap.parse_args()
    rc = 0
    for path in args.captures:
        try:
            text = open(path, "r", encoding="latin-1").read()
        except OSError as exc:
            print(f"!! cannot read {path}: {exc}")
            rc = max(rc, 2)
            continue
        result = report(Capture(path, text), args.rows)
        rc = max(rc, result)
    return rc


if __name__ == "__main__":
    sys.exit(main())
