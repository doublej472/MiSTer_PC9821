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
`// check-equiv: memory` maps such a ROM to cells before the proof.  A line
`// check-equiv: modules <file> <name>...` (file relative to the model) pastes
those whole modules from a shipped RTL file before the model, so a model can
instantiate them; a `import <pkg>::*;` in a pasted module's header (which yosys
cannot parse) becomes copies of the package localparams the module names,
taken from the line `// check-equiv: package <file>`.  yosys is required: a
missing yosys is a FAIL, never a skip.

A verdict is read from yosys's own log, not only its exit status: the proof must
print its SUCCESS line, and the mutant must fail with a counterexample (the
"model found: FAIL!" line).  A mutant that fails any other way (an elaboration
error that only MUTANT=1 reaches, a crash) is an ERROR, not a catch.
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


def paste_modules(path: pathlib.Path, text: str) -> str:
    """The modules a `modules` directive names, as yosys-readable text."""
    ms = list(re.finditer(r"^// check-equiv: modules (\S+) (.+)$", text, re.M))
    if not ms:
        return ""
    pkg = re.search(r"^// check-equiv: package (\S+)$", text, re.M)
    params = {}
    if pkg:
        for m in re.finditer(r"^localparam\b[^\n]*?\b([A-Za-z_]\w*)\s*=[^\n]*;",
                             (path.parent / pkg.group(1)).resolve().read_text(), re.M):
            params[m.group(1)] = m.group(0)
    out = []
    for m in ms:
        src = (path.parent / m.group(1)).resolve().read_text()
        for name in m.group(2).split():
            mm = re.search(r"^module " + re.escape(name) + r"\b.*?^endmodule\b", src, re.S | re.M)
            if not mm:
                raise SystemExit(f"check-equiv: module {name} not found in {m.group(1)}")
            body = mm.group(0)
            imp = re.search(r"^\s*import \w+::\*;\n", body, re.M)
            if imp:
                if not pkg:
                    raise SystemExit(f"check-equiv: {path.name} pastes {name}, which imports a "
                                     "package, but names no `// check-equiv: package` file")
                body = body[:imp.start()] + body[imp.end():]
                used = [params[w] for w in dict.fromkeys(re.findall(r"\b[A-Za-z_]\w*\b", body))
                        if w in params]
                end = body.index("\n);\n") + 4
                body = body[:end] + "\n".join(used) + "\n" + body[end:]
            out.append(body)
    return "\n".join(out) + "\n"


def model_source(path: pathlib.Path) -> pathlib.Path:
    """The model as yosys reads it: with any `functions` directive expanded,
    and @@Z486_ROOT@@ (for an `include or a $readmemh of a shipped file)
    replaced by the absolute z486 root."""
    text = path.read_text()
    pasted = paste_modules(path, text)
    if pasted:
        text = pasted + text
    ms = list(re.finditer(r"^// check-equiv: functions (\S+) (.+)$", text, re.M))
    if not ms:
        if "@@Z486_ROOT@@" not in text and not pasted:
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


def run(path: pathlib.Path, mutant: int) -> str:
    """'proved', 'refuted' (a counterexample) or 'error' (anything else)."""
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
    r = subprocess.run(["yosys", "-p", script],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log = r.stdout
    if r.returncode == 0 and re.search(r"^(SAT proof finished - no model found|"
                                       r"Induction step proven): SUCCESS!$", log, re.M):
        return "proved"
    if r.returncode != 0 and re.search(r"model found(?: for base case)?: FAIL!$", log, re.M):
        return "refuted"
    tail = "\n".join(log.splitlines()[-6:])
    print(f"    {path.name} MUTANT={mutant}: yosys gave no verdict (exit {r.returncode}):\n{tail}")
    return "error"


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
        ok = run(p, 0) == "proved"
        mut_caught = run(p, 1) == "refuted"
        verdict = "PASS" if (ok and mut_caught) else "FAIL"
        if verdict == "FAIL":
            bad += 1
        print(f"  {p.stem:32s} proof={'proved' if ok else 'REFUTED'} "
              f"mutant={'caught' if mut_caught else 'MISSED'}  {verdict}")
    print(f"check-equiv: {len(proofs) - bad}/{len(proofs)} PASS")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
