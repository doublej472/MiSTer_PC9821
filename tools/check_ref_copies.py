#!/usr/bin/env python3
"""Hold the frozen equivalence references in tests/pc9821/ to the revision each was copied from.

An equivalence bench (tb_pc9821_<x>_equiv) proves a rewritten module against a copy of the module
as it was before the rewrite. Such a copy proves "the same as then", which is only true while the
copy IS what it was then. A FROZEN copy below must carry exactly the code of its source file at
its revision: comments, whitespace and the text inside string literals (message wording) may
differ, the declared module name is renamed, and nothing else may change. A code edit to a frozen
copy fails here, so an edit that quietly turns "the old design" into something else is seen.

A LOCKSTEP copy is different by design: a deliberate behaviour change to the shipped module is
mirrored into it in the same commit, so the pair stays comparable (its header says which changes).
There is no revision to compare it with; it is listed so every *_ref.sv is accounted for.

The comparison needs the revisions, which a squashed release does not carry: a missing revision
is a loud SKIP (exit 2), never a pass.

Usage:
  tools/check_ref_copies.py              compare every frozen copy with its revision
  tools/check_ref_copies.py --selftest   a planted code edit must fail, a comment/message edit pass

Exit 0 = every frozen copy matches, 1 = a copy differs (or a reference is unlisted),
2 = a revision is missing (SKIP).
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TB = "tests/pc9821"

# copy -> (revision, source path at that revision, module renames {old: new}[, parts of the
# source the copy leaves out on purpose, as regexes over the source text; its header says why])
FROZEN = {
    "pc9821_pic_ref.sv": ("6b457f7f", "src/pc9821/interrupts/pc9821_pic.sv",
                          {"pc9821_pic": "pc9821_pic_ref"}),
    "pc9821_gvram_arb_ref.sv": ("3b134fe4", "src/pc9821/core/pc9821_gvram_arb.sv",
                                {"pc9821_gvram_arb": "pc9821_gvram_arb_ref"}),
    "pc9821_audio_volume_ref.sv": ("628dffdb^", "src/pc9821/audio/pc9821_audio_volume.sv",
                                   {"pc9821_audio_volume": "pc9821_audio_volume_ref"}),
    "pc9821_pegc_storebuf_ref.sv": ("7c421753^", "src/pc9821/core/pc9821_pegc_storebuf.sv",
                                    {"pc9821_pegc_storebuf": "pc9821_pegc_storebuf_ref"}),
    # the shared state package stays in the shipped pc9821_egc.sv, which still defines it
    "pc9821_egc_par.sv": ("81c98be5^", "src/pc9821/core/pc9821_egc.sv",
                          {"pc9821_egc": "pc9821_egc_par"},
                          [r"\bpackage\s+pc9821_egc_pkg\b.*?\bendpackage\b"]),
}

# copy -> what keeps it in step (its header lists the mirrored changes), or a copy derived by
# hand from a revision, which has no file to compare it with either
LOCKSTEP = {
    "pc9821_crtc_ref.sv": "tb_pc9821_crtc_geom_equiv",
    "pc9821_gdc2_ref.sv": "tb_pc9821_gdc2_equiv",
    "pc9821_fdd_media_ref.sv": "tb_pc9821_fdd_media_equiv",
    # frozen at 284a2442 until the MSF converter's past-99-minute change was mirrored into it
    "pc9821_atapi_ref.sv": "tb_pc9821_atapi_equiv",
    "pc9821_pcm86_ref.sv": "tb_pc9821_pcm86_equiv",
    "pc9821_pegc_ref.sv": "tb_pc9821_pegc_equiv",
    "pc9821_audio_out_ref.sv": "tb_pc9821_audio_out_equiv",
    # not a plain file copy: z486_mister.sv's CLK_AUDIO mix with its wires turned into ports
    "pc9821_audio_mix_ref.sv": "tb_pc9821_audio_mix_equiv",
}

# *_ref.sv files that are behavioural models transcribed from a reference emulator, not copies.
MODELS = {"pc9821_egc_ref.sv", "pc9821_grcg_ref.sv"}


def code(text: str, renames: dict[str, str] | None = None) -> list[str]:
    """The text's code as tokens: comments dropped, string literals emptied, layout ignored,
    and each `module <old>` declaration renamed."""
    # one pass, so `//` inside a string and `"` inside a comment are both read correctly
    tok = re.compile(r'"(?:\\.|[^"\\\n])*"|//[^\n]*|/\*.*?\*/', re.S)
    text = tok.sub(lambda m: '""' if m.group(0).startswith('"') else
                   "\n" * m.group(0).count("\n"), text)
    for old, new in (renames or {}).items():
        text = re.sub(r"\bmodule(\s+)%s\b" % re.escape(old), r"module\g<1>%s" % new, text)
    return re.findall(r'""|[\w$\'`]+|\S', text)


def git_show(rev: str, path: str) -> str | None:
    r = subprocess.run(["git", "show", f"{rev}:{path}"], cwd=ROOT, capture_output=True, text=True)
    return None if r.returncode else r.stdout


def differences(ref_text: str, src_text: str, renames: dict[str, str]) -> list[str]:
    """The first few differing token runs, with context (empty = the copy is the source)."""
    import difflib
    a, b = code(src_text, renames), code(ref_text)
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op != "equal":
            ctx = " ".join(a[max(0, i1 - 6):i1])
            out.append(f"after `{ctx}`: source `{' '.join(a[i1:i2])}` / copy `{' '.join(b[j1:j2])}`")
    return out[:6]


def check() -> int:
    bad, skip = [], []
    on_disk = {p.name for p in (ROOT / TB).glob("pc9821_*_ref.sv")} | {"pc9821_egc_par.sv"}
    for name in sorted(on_disk - set(FROZEN) - set(LOCKSTEP) - MODELS):
        bad.append(f"{name}: not listed as FROZEN, LOCKSTEP or a model in this tool")
    for name in sorted((set(FROZEN) | set(LOCKSTEP) | MODELS) - on_disk):
        bad.append(f"{name}: listed here, but there is no {TB}/{name}")
    for name, (rev, path, renames, *omit) in sorted(FROZEN.items()):
        if name not in on_disk:
            continue
        src = git_show(rev, path)
        if src is None:
            skip.append(f"{name}: revision {rev}:{path} is not in this clone")
            continue
        for rx in (omit[0] if omit else []):
            src, n = re.subn(rx, "", src, count=1, flags=re.S)
            if n != 1:
                bad.append(f"{name}: the omitted part {rx!r} is not in {rev}:{path}")
        diff = differences((ROOT / TB / name).read_text(), src, renames)
        if diff:
            bad.append(f"{name}: its code is not {rev}:{path}'s:\n      " + "\n      ".join(diff))
        else:
            print(f"  {name}: the code of {rev}:{path}")
    for name, bench in sorted(LOCKSTEP.items()):
        if not (ROOT / TB / f"{bench}.sv").is_file():
            bad.append(f"{name}: its lockstep bench {bench} does not exist")
        print(f"  {name}: lockstep (mirrored edits allowed; {bench} keeps the pair equal)")
    for b in bad:
        print("FAIL:", b)
    if bad:
        print(f"REF COPIES: FAIL ({len(bad)} problem(s))")
        return 1
    if skip:
        for s in skip:
            print("SKIP:", s)
        print("REF COPIES: SKIP (the history the frozen copies are compared with is absent: NOT a pass)")
        return 2
    print(f"REF COPIES: PASS ({len(FROZEN)} frozen copies match their revisions, "
          f"{len(LOCKSTEP)} lockstep, {len(MODELS)} models)")
    return 0


def selftest() -> int:
    src = ('module m #(parameter W = 4) (input wire [W-1:0] a, output wire y);\n'
           '  // the reduction\n  assign y = &a;\n'
           '  initial if (W < 1) $error("m: W must be positive");\nendmodule\n')
    ren = {"m": "m_ref"}
    copy = src.replace("module m ", "module m_ref ")
    cases = [
        ("the copy itself", copy, False),
        ("a comment edited", copy.replace("// the reduction", "// AND of every bit"), False),
        ("a message reworded", copy.replace("m: W must", "m_ref: W must"), False),
        ("re-wrapped whitespace", copy.replace("assign y = &a;", "assign y =\n    &a;"), False),
        ("a code edit", copy.replace("&a", "|a"), True),
        ("a dropped statement", copy.replace("  assign y = &a;\n", ""), True),
        ("code hidden in a comment", copy.replace("  assign y = &a;", "  // assign y = &a;"), True),
    ]
    fails = []
    for label, text, want_diff in cases:
        if bool(differences(text, src, ren)) != want_diff:
            fails.append(f"{label}: {'not caught' if want_diff else 'refused'}")
    if fails:
        print("REF COPIES SELFTEST: FAIL")
        for f in fails:
            print("  -", f)
        return 1
    print(f"REF COPIES SELFTEST: PASS ({len(cases)} plants)")
    return check()


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv else check())
