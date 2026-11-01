#!/usr/bin/env python3
"""Combinational equivalence proofs for zero-cycle rewrites (yosys SAT).

Each tests/equiv/<name>.v holds a module <name> with one output `mismatch`
that compares a rewritten expression against the form it replaced, and a
`parameter MUTANT = 0`.  The proof is `sat -prove mismatch 0` over EVERY
input bit.  Each proof is run twice:

  MUTANT=0  must PROVE (the rewrite is bit-identical for all inputs);
  MUTANT=1  must FAIL with a counterexample (a planted error the proof has to
            see - so a proof that is vacuous, or a model that no longer
            reaches `mismatch`, cannot pass silently).

The models restate the RTL expressions they prove; each file names its RTL
site.  A model whose first line is `// check-equiv: tempinduct` is sequential
and is proved by temporal induction from its declared power-up values.  A line
`// check-equiv: functions <file> <name>...` (file relative to the model; one
line per file, any number of lines) pastes those functions' text from a GENERATED RTL file at the model's
`// @@FUNCTIONS@@` line, so the proof runs on the shipped text rather than a
restatement.  @@Z486_ROOT@@ in a model stands for the z486 root directory (an
`include of a shipped header, a $readmemh of a shipped ROM image); a line
`// check-equiv: memory` maps such a ROM to cells before the proof.  yosys is required: a missing yosys is a FAIL, never a skip.
"""
import pathlib
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
EQUIV = HERE / "equiv"


def extract_functions(src: pathlib.Path, names: list[str]) -> str:
    text = src.read_text()
    out = []
    for name in names:
        m = re.search(r"^function automatic[^\n]*\b" + re.escape(name) + r"\b.*?^endfunction\s*$",
                      text, re.S | re.M)
        if not m:
            raise SystemExit(f"check-equiv: function {name} not found in {src}")
        out.append(m.group(0))
    return "\n".join(out)


def model_source(path: pathlib.Path) -> pathlib.Path:
    """The model as yosys reads it: with any `functions` directive expanded,
    and @@Z486_ROOT@@ (for an `include or a $readmemh of a shipped file)
    replaced by the absolute z486 root."""
    text = path.read_text()
    ms = list(re.finditer(r"^// check-equiv: functions (\S+) (.+)$", text, re.M))
    if not ms:
        if "@@Z486_ROOT@@" not in text:
            return path
        out_dir = HERE / "obj_dir" / "equiv"
        out_dir.mkdir(parents=True, exist_ok=True)
        out = out_dir / path.name
        out.write_text(text.replace("@@Z486_ROOT@@", str(HERE.parent)))
        return out
    # One or more directive lines, each naming a file and its functions.
    funcs = "\n".join(extract_functions((path.parent / m.group(1)).resolve(), m.group(2).split())
                      for m in ms)
    if "// @@FUNCTIONS@@" not in text:
        raise SystemExit(f"check-equiv: {path.name} has no // @@FUNCTIONS@@ line")
    out_dir = HERE / "obj_dir" / "equiv"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / path.name
    out.write_text(text.replace("// @@FUNCTIONS@@", funcs).replace("@@Z486_ROOT@@", str(HERE.parent)))
    return out


def run(path: pathlib.Path, mutant: int) -> bool:
    top = path.stem
    # A model whose first line is "// check-equiv: tempinduct" is sequential: it
    # is proved by temporal induction from its declared power-up values.
    seq = path.read_text().startswith("// check-equiv: tempinduct")
    path = model_source(path)
    sat = ("sat -tempinduct -prove mismatch 0 -verify" if seq
           else "sat -prove mismatch 0 -verify -show-inputs")
    # "// check-equiv: memory" maps an inferred memory (a $readmemh ROM image)
    # to cells the SAT solver can model.
    mem = "memory; " if re.search(r"^// check-equiv: memory$", path.read_text(), re.M) else ""
    script = (f"read_verilog -sv {path}; chparam -set MUTANT {mutant} {top}; "
              f"prep -top {top}; flatten; {mem}{sat}")
    r = subprocess.run(["yosys", "-q", "-p", script],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return r.returncode == 0


def main() -> int:
    if shutil.which("yosys") is None:
        print("check-equiv: FAIL - yosys not found (required, not optional)")
        return 1
    proofs = sorted(EQUIV.glob("*.v"))
    if not proofs:
        print("check-equiv: no proofs in tests/equiv/")
        return 0
    bad = 0
    for p in proofs:
        ok = run(p, 0)
        mut_caught = not run(p, 1)
        verdict = "PASS" if (ok and mut_caught) else "FAIL"
        if verdict == "FAIL":
            bad += 1
        print(f"  {p.stem:32s} proof={'proved' if ok else 'REFUTED'} "
              f"mutant={'caught' if mut_caught else 'MISSED'}  {verdict}")
    print(f"check-equiv: {len(proofs) - bad}/{len(proofs)} PASS")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
