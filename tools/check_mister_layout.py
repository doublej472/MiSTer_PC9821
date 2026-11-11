#!/usr/bin/env python3
"""The MiSTer tooling's naming contracts, checked against the tools that implement them.

WHY THIS IS A PYTHON CHECK AND NOT A BENCH. The facts being checked are SOURCE TEXT, not
signal levels: which name MiSTer keys a core's config file on, and which pack a card's MGL
loads. No Verilator bench can read a shell script, and the failure this guards is four shell
scripts drifting apart from each other and from the card.

THE DEFECT THIS EXISTS TO CATCH, found on a real card. Three tools built the config path
as /media/fat/config/<RBF-name>.CFG, i.e. PC9821Z486.CFG. MiSTer keys that file on the MGL's
<setname>, which is PC9821, so the real file is PC9821.CFG - and PC9821Z486.CFG has never
existed on any card. The card's config directory is keyed that way for every core, which is
how it was confirmed: it holds Genesis.CFG, SNES.CFG and MegaCD.CFG.

The damage was not the path. tools/mister_load.sh exists to WARN that a config file written
before the OSD lists were rotated now selects a different, unbootable RAM size - the old 16 MB
value is now list entry 4, which is 1 MB, and a 1 MB guest cannot boot the Xe10 BIOS: it
freezes with a blank screen, indistinguishable from broken RTL. Its test was
`ssh ... "test -f '$CFG'"` with the wrong path, so the test was ALWAYS false and the script
always printed "none needed". THE WARNING COULD NOT FIRE, whatever the card held.

The second defect is the same shape. tools/mister_packs.sh treated pc98pack-z486.bin as "the"
active pack - a stale 512 KiB leftover from before the pack outgrew 512 KiB - while the MGLs
on the card load pc98pack-xe10.bin and pc98pack-xe.bin. Its `prune` then deleted every
pc98pack*.bin that was NOT that name, i.e. it deleted the two packs the MGLs load and kept the
one nothing uses. Running it would have broken the card's boot.

THE THIRD DEFECT WAS IN THIS FILE. The first version of this checker keyed setname
DECLARATIONS by VARIABLE NAME, and two of the four tools declare a variable called SETNAME, so
the second file's value silently overwrote the first. Every declaration collapsed to one
element and the agreement check could not fire BETWEEN files at all - it passed with
mister_load.sh declaring WRONGCORE while deploy_mister.sh declared PC9821, two files that
between them decide both the config path and the <setname> the card's MGL carries. The same
by-name conflation sat one level down in the variable lookup, accepting `$SETNAME` in a file
that never sets it because another file did. A check that cannot fail is not evidence, and
this was that disease inside the checker written to catch it.

WHAT IS ASSERTED, every value read out of the tools themselves so nothing here is a copy:
  1. Every tool that names the config file keys it on a setname variable, never on the RBF
     name. `$CORE.CFG` fails because CORE is not a setname variable, and a literal
     PC9821Z486.CFG fails because it is not the setname.
  2. Every <setname> a tool emits agrees with every setname declared, whether it emits the
     value literally or through a variable, so the MGL a card loads and the config a tool
     inspects cannot drift apart. Declarations are keyed by (file, variable) for this, and
     the variable lookup is per file: keying by variable name alone let one file's SETNAME
     overwrite another's, and resolving $VAR against every file's declarations let a tool use
     a variable it never sets. Both were demonstrated blind before they were fixed.
  3. Every card pack name a tool hard-codes is pc98pack-<machine>.bin for a machine the tools
     declare, so a tool cannot address a pack no MGL can load.
  4. The check is not vacuous: it fails if it found no setname, no MGL emission or no config
     path, so a rename that empties it cannot pass it silently.
  6. No tool writes anything under the card's Scripts/ folder, and the offline staging tree
     holds no Scripts/ directory: no script is installed on the MiSTer, and the image
     converters run on a computer (docs/user/images.md "Converting images").
  5. Every MGL image slot a tool writes (mister_load.sh, deploy_mister.sh, mister_regress.py's
     mgl_text) is the hps_io slot z486_mister.sv's CONF_STR gives that drive (S0 HDD, S1/S2 the
     floppies, S3 HDD2, S4 the CD-ROM).
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The tools that touch the card layout. Naming a fifth one here is what makes it checked.
# tools/decode_telemetry.py reads a capture and touches no card path, so it is not listed.
TOOLS = [
    "tools/mister_load.sh",
    "tools/deploy_mister.sh",
    "tools/mister_packs.sh",
    "tools/run_on_mister.sh",
]

# `SETNAME=PC9821` / `setname=PC9821`, indented or not. The variable NAME is captured too,
# because a config path has to key on THAT variable: capturing only the value would let
# `$CORE.CFG` pass. A value containing `$` is a reference, not a declaration.
RE_DECL = re.compile(r"^\s*([A-Za-z_]\w*)=([A-Za-z0-9_.-]+)\s*(?:#.*)?$", re.M)
# `<setname>PC9821</setname>` or `<setname>$SETNAME</setname>` in an MGL the tool emits.
RE_EMIT = re.compile(r"<setname>([^<]*)</setname>")
# A config path, at any prefix. The lookbehind only rejects a word character directly before
# `config/`, so `/media/fat/config/X.CFG` matches while `xconfig/X.CFG` does not.
RE_CONFIG = re.compile(r"(?<!\w)config/([A-Za-z0-9_.${}-]+)\.CFG")
# `PC9821Z486` out of `CORE=${MISTER_CORE:-PC9821Z486}`, for the message only.
RE_CORE = re.compile(r"^\s*CORE=\$\{[A-Za-z_]+:-([A-Za-z0-9_.-]+)\}", re.M)
# A card pack name.
RE_PACK = re.compile(r"pc98pack-([A-Za-z0-9_]+)\.bin")
# The machines a tool can address: `MACHINES="xe10 xe"` and `machine=xe10`.
RE_MACHINES = re.compile(r"^\s*MACHINES=\"?([a-z0-9 ]+)\"?\s*$", re.M)
RE_MACHINE_DEFAULT = re.compile(r"^\s*machine=([A-Za-z0-9_]+)\s*$", re.M)
# `$NAME` and `${NAME}`.
RE_VARREF = re.compile(r"\$\{?(\w+)\}?")


def strip_comments(text: str) -> str:
    """Full-line shell comments only.

    Prose legitimately names files that must not be treated as code: mister_load.sh explains
    the stale-pack incident by naming one, and a checker that failed on the explanation would
    be wrong. Full-line stripping covers the headers where that prose lives; a trailing
    comment that names a pack is a risk this accepts deliberately rather than miscounting.
    """
    return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def rel(p: Path) -> str:
    """A short name for a file, inside the tree or not (the checker also runs on copies)."""
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def staging_leaves_no_config(deploy: Path) -> list[str]:
    """Run the staging tool over a tree that ALREADY holds a config, and look at the result.

    This one is behavioural rather than textual, because the defect was behavioural: a
    gitignored leftover survived every re-run while the script went on printing that none was
    staged. Its own output gave it away - it printed "No config/... is staged" two lines after
    its own `ls` listed the config directory holding a 16-byte file whose byte 7 was 0x80.

    The planted name is PC9821.CFG, the one MiSTer actually reads, because that is the worst
    case: 0x80 is status[63:61] = 4, and post-rotation list entry 4 is 1 MB - a size that
    cannot boot the Xe10 BIOS. The old name PC9821Z486.CFG was inert only by accident.

    Runs on a throwaway copy so it writes nothing into the tree. Takes the script as an
    argument so it can be pointed at a candidate that has yet to be fixed, which is how this
    check was shown to be capable of failing.
    """
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        (t / "tools").mkdir()
        shutil.copy2(deploy, t / "tools" / deploy.name)
        (t / "output_files").mkdir()
        (t / "output_files" / "z486_mister.rbf").write_bytes(b"")
        (t / "build").mkdir()
        (t / "build" / "pc98pack.bin").write_bytes(b"\0" * 1024)
        planted = t / "mister_deploy" / "config" / "PC9821.CFG"
        planted.parent.mkdir(parents=True)
        planted.write_bytes(bytes([0x10, 0, 0, 0, 0, 0, 0, 0x80] + [0] * 8))

        r = subprocess.run(["bash", str(t / "tools" / deploy.name)],
                           capture_output=True, text=True, cwd=str(t))
        if r.returncode != 0:
            return ["%s exited %d on a staging tree that already held a config; it must "
                    "sweep one, not refuse to run: %s"
                    % (deploy.name, r.returncode, (r.stderr or r.stdout).strip()[:300])]
        left = sorted(str(p.relative_to(t)) for p in (t / "mister_deploy").rglob("*")
                      if p.is_file() and p.suffix.lower() == ".cfg")
        found: list[str] = []
        if left:
            found.append("%s left a config in its own staging tree: %s - copying that tree "
                         "onto a card would overwrite the RAM size the user selected"
                         % (deploy.name, ", ".join(left)))
        if (t / "mister_deploy" / "Scripts").exists():
            found.append("%s staged a Scripts/ directory: no script is installed on the MiSTer"
                         % deploy.name)
        return found


# THE MGL SLOT INDICES. An MGL's `<file type="s" index="N">` mounts into hps_io slot N, which is
# the digit of CONF_STR's `S{N},...,Mount <drive>` entry (Main_MiSTer menu.cpp takes the index
# from the digit; sys/hps_io.sv turns it into img_mounted[N]). Each tool that writes an MGL names
# the drive by the variable or keyword it mounts, so the index it writes for that drive must be
# the S-slot the top level gives the drive - a drive moved to another slot (HDD2 = 3, the CD
# kept at 4) would otherwise mount the user's file into the wrong drive.
MGL_DRIVE_OF = {
    "IMGNAME": "HDD", "hdd.img": "HDD",            # mister_load.sh, deploy_mister.sh
    "FDDNAME0": "FDD1", "FDDNAME1": "FDD2", "HDD2NAME": "HDD2",   # mister_load.sh
    "hdd": "HDD", "fdd0": "FDD1", "fdd1": "FDD2", "hdd2": "HDD2", "cd": "CD-ROM",  # mister_regress.py
}
RE_SH_SLOT = re.compile(r'type=\\?"s\\?" index=\\?"(\d+)\\?" path=\\?"\$?\{?([\w.]+)')
RE_PY_SLOT = re.compile(r"for idx, p in \(((?:\(\d+, \w+\),? ?)+)\):")
# A path under the card's Scripts/ folder (`/media/fat/Scripts`, `$deploy/Scripts/...`).
RE_SCRIPTS = re.compile(r"(?:/|\$\w+/|\b)Scripts(?:/|\b)")
RE_CONF_MOUNT = re.compile(r"S(\d+),[A-Z0-9]*,Mount ([^;\"]+);")


def mgl_slots() -> tuple[list[str], str]:
    """Pass 6: every MGL slot a tool writes against the top level's CONF_STR S-entries."""
    top = (ROOT / "z486_mister.sv").read_text()
    slot_of = {drive: int(n) for n, drive in RE_CONF_MOUNT.findall(top)}
    bad: list[str] = []
    seen: list[str] = []
    if not slot_of:
        return ["z486_mister.sv: no `S{n},...,Mount <drive>` entry found, so the MGL slot "
                "check is vacuous"], ""
    uses: list[tuple[str, int, str]] = []
    for name in ("tools/mister_load.sh", "tools/deploy_mister.sh"):
        for n, var in RE_SH_SLOT.findall(strip_comments((ROOT / name).read_text())):
            uses.append((name, int(n), var))
    m = RE_PY_SLOT.search((ROOT / "tools/mister_regress.py").read_text())
    if m:
        for n, var in re.findall(r"\((\d+), (\w+)\)", m.group(1)):
            uses.append(("tools/mister_regress.py", int(n), var))
    else:
        bad.append("tools/mister_regress.py: mgl_text's slot table not found")
    for where, n, var in uses:
        drive = MGL_DRIVE_OF.get(var)
        if drive is None:
            bad.append("%s: writes an MGL slot %d for `%s`, which this check cannot name a "
                       "drive for (add it to MGL_DRIVE_OF)" % (where, n, var))
        elif slot_of.get(drive) != n:
            bad.append("%s: mounts %s (`%s`) at MGL index %d, but CONF_STR gives %s slot %s"
                       % (where, drive, var, n, drive, slot_of.get(drive, "none")))
        else:
            seen.append("%s=%d" % (drive, n))
    if not uses:
        bad.append("no tool writes an MGL slot, so the MGL slot check is vacuous")
    return bad, " ".join(sorted(set(seen)))


def main(argv: list[str]) -> int:
    paths = [Path(a) for a in argv[1:]] or [ROOT / t for t in TOOLS]
    missing = [p for p in paths if not p.is_file()]
    if missing:
        for p in missing:
            print("  MISSING: %s" % p)
        return 1

    raw = {p: p.read_text() for p in paths}
    code = {p: strip_comments(t) for p, t in raw.items()}
    failures: list[str] = []

    # ---- pass 1: every setname a tool declares, keyed BY FILE, not by variable name --------
    # KEYED BY (file, variable), NOT BY VARIABLE NAME. Two of these four tools declare a
    # variable called SETNAME, so keying by name alone let the second file's value overwrite
    # the first: every declaration collapsed to one element and the disagreement check below
    # could not fire BETWEEN files at all. It was shown to pass with mister_load.sh declaring
    # WRONGCORE while deploy_mister.sh declared PC9821 - two files that between them decide
    # both the config path and the <setname> the card's MGL carries. That is the same "a check
    # that cannot fail" disease this file exists to catch, inside the checker.
    declared: dict[tuple[str, str], str] = {}
    for p in paths:
        for var, val in RE_DECL.findall(raw[p]):
            if var.lower() == "setname":
                declared[(rel(p), var)] = val

    def declared_in(where: str) -> set[str]:
        """The setname variables that THIS file declares. A variable set in one script is not
        visible in another, so resolving these globally would accept `$SETNAME` in a file that
        never sets it - the same by-name conflation, one level down."""
        return {v for (f, v) in declared if f == where}

    # ---- pass 2: every setname a tool puts in an MGL -------------------------------------
    emitted: list[tuple[str, str]] = []
    # Every place a setname is asserted, with its file and its value, so a disagreement can be
    # reported by naming the files rather than by listing loose values.
    sources: list[tuple[str, str, str | None]] = [
        (f, "declares %s" % v, val) for (f, v), val in declared.items()]
    for p in paths:
        here = rel(p)
        for val in RE_EMIT.findall(code[p]):
            if "$" in val:
                for var in RE_VARREF.findall(val):
                    if var in declared_in(here):
                        emitted.append((here, "$" + var))
                        sources.append((here, "emits <setname>$%s</setname>" % var, None))
                    else:
                        failures.append(
                            "%s: emits <setname>$%s</setname>, but %s does not declare it "
                            "(that file declares: %s)"
                            % (here, var, here,
                               ", ".join(sorted(declared_in(here))) or "nothing"))
            else:
                emitted.append((here, val))
                sources.append((here, "emits <setname>%s</setname>" % val, val))

    literals = {val for _, _, val in sources if val is not None}
    if not declared:
        failures.append("no tool declares a setname, so this check is vacuous")
    if not emitted:
        failures.append("no tool emits <setname>, so this check is vacuous")
    if len(literals) > 1:
        by_val: dict[str, list[str]] = {}
        for f, how, val in sources:
            if val is not None:
                by_val.setdefault(val, []).append("%s %s" % (f, how))
        failures.append(
            "the tools disagree about the setname - one of them decides the config path while "
            "another decides the <setname> the card's MGL carries: "
            + "; ".join("%s from %s" % (v, ", ".join(sorted(by_val[v])))
                         for v in sorted(by_val)))
    setname = sorted(literals)[0] if literals else None

    core = next((m.group(1) for p in paths if (m := RE_CORE.search(raw[p]))), None)

    # ---- pass 3: every config path must key on a setname ----------------------------------
    # Full-line comments are stripped, exactly as for the pack check below, and for the same
    # reason: prose has to be able to NAME the wrong path in order to explain what went wrong.
    # The defect is a path the shell actually uses, and that is always on a code line; a path
    # inside an echo string or a command substitution is code and is still checked.
    config_paths = 0
    for p in paths:
        here = rel(p)
        for name in RE_CONFIG.findall(code[p]):
            config_paths += 1
            if "$" in name:
                for var in RE_VARREF.findall(name):
                    if var not in declared_in(here):
                        failures.append(
                            "%s: the config path keys on $%s, which %s does not declare "
                            "(that file declares: %s) - MiSTer keys that file on <setname>, "
                            "not on the RBF name"
                            % (here, var, here,
                               ", ".join(sorted(declared_in(here))) or "nothing"))
            elif setname is not None and name != setname:
                extra = " - that is the RBF name, not the setname" if name == core else ""
                failures.append("%s: the config path is literally %s.CFG but the setname "
                                "is %s%s" % (here, name, setname, extra))
    if config_paths == 0:
        failures.append("no tool names a config path, so this check is vacuous")

    # ---- pass 4: a hard-coded card pack must name a declared machine ----------------------
    machines: set[str] = set()
    for p in paths:
        for group in RE_MACHINES.findall(raw[p]):
            machines.update(group.split())
        machines.update(RE_MACHINE_DEFAULT.findall(raw[p]))
    pack_refs = 0
    if not machines:
        failures.append("no tool declares a machine list, so the pack check is vacuous")
    for p in paths:
        for name in RE_PACK.findall(code[p]):
            pack_refs += 1
            if machines and name not in machines:
                failures.append(
                    "%s: addresses pc98pack-%s.bin, but the tools declare only the machine(s) "
                    "%s - that pack is one no MGL can load"
                    % (rel(p), name, ", ".join(sorted(machines))))

    # ---- pass 5: the staging tool cannot leave a config behind ---------------------------
    # Behavioural, because the defect was: the script's own printed claim was false. Pointed at
    # whichever staging tool was named, so it can be run against a candidate that is not yet
    # fixed - which is how this check was shown to be capable of failing.
    deploy_tool = next((p for p in paths if p.name == "deploy_mister.sh"), None)
    if deploy_tool is not None:
        staging = staging_leaves_no_config(deploy_tool)
        failures.extend(staging)
        staging_ok = not staging
    else:
        staging_ok = None

    # ---- pass 6: the MGL slot indices the tools write match CONF_STR's S-slots -----------
    # Only for the tree's own tools (a run pointed at candidate files checks those alone).
    if argv[1:]:
        slots_seen = None
    else:
        slot_bad, slots_seen = mgl_slots()
        failures.extend(slot_bad)

    # ---- pass 7: nothing is installed under the card's Scripts/ folder --------------------
    # Comments are stripped (prose may say that nothing goes there); a code line naming the
    # folder is a copy, a mkdir or a delete aimed at it.
    scripts_refs = [rel(p) for p in paths if RE_SCRIPTS.search(code[p])]
    for where in scripts_refs:
        failures.append("%s names the card's Scripts/ folder on a code line: no script is "
                        "installed on the MiSTer, so no tool writes there" % where)

    # ---- report ---------------------------------------------------------------------------
    print("  setname                 : %s" % (setname or "NONE"))
    print("  declared                : %s"
          % (", ".join("%s: %s=%s" % (f, v, val)
                       for (f, v), val in sorted(declared.items())) or "none"))
    print("  emitted in an MGL       : %s"
          % (", ".join("%s (%s)" % (v, f) for f, v in emitted) or "none"))
    print("  config paths checked    : %d" % config_paths)
    print("  machines declared       : %s" % (", ".join(sorted(machines)) or "none"))
    print("  card pack names checked : %d" % pack_refs)
    print("  staging sweep           : %s"
          % ("cannot leave a config file" if staging_ok else
             "NOT CHECKED (no deploy_mister.sh among the files given)" if staging_ok is None else
             "LEFT A CONFIG FILE - see below"))
    print("  Scripts/ folder         : %s"
          % ("named by %s" % ", ".join(scripts_refs) if scripts_refs else "no tool writes there"))
    print("  MGL slot indices        : %s"
          % ("NOT CHECKED (files given)" if slots_seen is None else slots_seen or "none"))

    if failures:
        print()
        for f in failures:
            print("  FAIL: %s" % f)
        print()
        print("MISTER LAYOUT CHECK: FAIL - %d problem(s)." % len(failures))
        return 1

    print()
    print("MISTER LAYOUT CHECK: PASS - the tools agree on setname '%s'; every config path "
          "keys on it; every card pack names a declared machine." % setname)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
