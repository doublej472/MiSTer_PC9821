#!/usr/bin/env python3
"""Generate a build profile's main PLL and constraints from ONE template each.

This is the engine behind build_profile.py (which owns the configuration, the top level and
the qsf). It replaced the static profiles/<name>/ tree and the old regen_pll.sh script. Four things
live here, each a function of the configuration and nothing else:

  * the PLL (generate_pll): tools/profile/pll_template.v carries the altera_pll megafunction's
    Retrieval-info XML with three placeholders (output 0/1 frequencies and output 1's phase).
    Output 0 is clk_sys - which is also the SDRAM controller's and its PHY's clock - and output
    1 is the SDRAM_CLK pin clock, clk_sys's frequency phase-shifted. (Until the split-clock
    configuration was removed (2026-10-09) there were three outputs:
    a separate clk_sdram on output 1 and the pin clock on output 2.)
    qmegawiz re-derives pll/pll_0002.v and pll.qip from it inside the Quartus container,
    post-processed exactly as a GUI generation (the device the CLI cannot know is restored,
    the speed-grade line it invents and its side files are dropped). The result is cached
    under .build/pll-cache/<key>/, key = sha256 of the request, the template, the generator
    version and the container image digest, so a sweep generates each PLL once. The generated
    pll_0002.v is READ BACK and the generation fails unless outputs 0/1 run at exactly clk_sys
    and output 1's phase is within one VCO phase step of the request.

  * the SDRAM pin-clock phase (derive_sdram_phase): the phase that maximises the worst of the
    command/address/write-data output setup/hold and the DQ read-capture setup/hold, under the
    SDC's own SDRAM I/O model, at every timing corner the device has, as a closed-form
    function of the SDRAM clock period (= clk_sys's). See IO_MODEL below for the model and its
    provenance.

  * the constraints (render_sdc): tools/profile/z486_mister.sdc.in with its one computed
    block (the configuration's name and clock, as comments) filled in. The clk_sys <->
    clk_sdram multicycle that block used to carry (crossing_multicycle) went with the
    split-clock configuration: there is one clock, so nothing crosses.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
from decimal import Decimal
from fractions import Fraction
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
PROJECT_DIR = TOOLS_DIR.parent
PROFILE_DIR = TOOLS_DIR / "profile"
PLL_TEMPLATE = PROFILE_DIR / "pll_template.v"
SDC_TEMPLATE = PROFILE_DIR / "z486_mister.sdc.in"
# The one PLL file that does not depend on the request: tracked in the tree, and the
# generator checks the wizard still produces it byte-for-byte rather than writing it.
TRACKED_PLL_QIP2 = Path("rtl/pll/pll_0002.qip")

# Bump when the generation or its post-processing changes, so stale cache entries are not
# reused (the key covers the template and the image, not this file's code).
GENERATOR_VERSION = "3"   # 2: two outputs (clk_sys, the SDRAM pin clock), clock-unify
                          # 3: the dynamic-phase-shift ports on every wrapper (sdram_phase_dyn)

# The three files the build needs, relative to the PLL directory (rtl/).
PLL_FILES = (Path("pll.v"), Path("pll.qip"), Path("pll/pll_0002.v"))
# What qmegawiz emits beside them and the build does not use.
PLL_SIDE_FILES = ("pll.bsf", "pll.cmp", "pll.ppf", "pll.sip", "pll.spd", "pll_sim",
                  "pll_sim.f")

# Output 0 = clk_sys (requesters, SDRAM controller and PHY), output 1 = the SDRAM_CLK pin clock.
PLL_OUTPUTS = 2
PIN_CLOCK_OUTPUT = 1
REFERENCE_CLOCK_HZ = 50_000_000      # the template's gui_reference_clock_frequency
QMEGAWIZ = "/opt/intelFPGA/quartus/bin/qmegawiz"
DEFAULT_IMAGE = "docker.io/raetro/quartus:mister"

SDC_BLOCK_PLACEHOLDER = "@PROFILE_SPECIFIC@"
SDC_PROFILE_BEGIN = "# >>> PROFILE-SPECIFIC"
SDC_PROFILE_END = "# <<< PROFILE-SPECIFIC"


class GenerationError(RuntimeError):
    pass


# ---------------------------------------------------------------------------------------
# Number formatting
# ---------------------------------------------------------------------------------------

def mhz_text(hz: int) -> str:
    """A frequency as the wizard's gui_* MHz text: 50_000_000 -> '50.0', 33_333_333 -> '33.333333'."""
    text = format((Decimal(hz) / Decimal(1_000_000)).normalize(), "f")
    return text if "." in text else text + ".0"


def parse_mhz(text: str) -> int:
    """'100.000000 MHz' or '100.0' -> Hz, exactly (refuses a sub-Hz remainder)."""
    value = Decimal(text.replace("MHz", "").strip()) * 1_000_000
    if value != value.to_integral_value():
        raise ValueError(f"{text!r} is not a whole number of Hz")
    return int(value)


def hz_from_mhz_arg(text: str) -> int:
    """A CLI/profile-file MHz value -> Hz, exactly."""
    return parse_mhz(str(text))


def ns(x: Fraction | float) -> str:
    return f"{float(x):.3f}"


# ---------------------------------------------------------------------------------------
# The SDRAM pin-clock phase, derived from the SDC's own I/O model
# ---------------------------------------------------------------------------------------

# THE MODEL. The SDC's "SDRAM board I/O" section is the model: the AS4C32M16SB-7 limits as
# set_output_delay -max 1.5 / -min -0.8 and set_input_delay -max 6.0 / -min 2.5 against
# PC9821_SDRAM_CLK (the pin-clock output forwarded to the SDRAM_CLK pin), with the read capture on dq_r at
# the setup-2 edge and its default (shifted) hold check. Everything else in the window is the
# FPGA's own I/O delay, which STA reports. The slacks below were measured by an SDRAM-I/O
# STA script (report_timing on the SDRAM pins) at all four timing corners, with the DQ hold multicycle
# removed (z486_mister.sdc.in's note), on TWO fitted base databases, and are referred to
# phi0 = 4000 ps, T0 = 10 ns:
#   FIT_A  the 2026-10-07 base fit (50/100 MHz, phase 4000 ps, rtl-hash 89efa58e7f796e3c):
#          offset 0;
#   FIT_B  the profile-gen base fit (phase 5937.5 ps, rtl-hash 30372f34ffbeb920):
#          offset -1.9375 (= 4000 ps).
# Displacing the forwarded clock by -2..+3 ns moved every slack by exactly +-1 ns per ns, so
# the model is linear in the phase. The two READ groups agree between the fits to 0.5 ps (dq_r
# is the IOE input register on a fixed pin); the two OUTPUT groups differ by ~0.8-1.1 ns (the
# command/DQ output registers are not all packed into the IOE - the fit warns that the
# SDRAM_* fast-output-register wildcard misses some - so their delay moves with placement).
# The model is therefore the per-group ENVELOPE (the worse) of the two fits.
IO_MODEL_PHASE0_NS = 4.0
IO_MODEL_PERIOD0_NS = 10.0
IO_FITS: dict[str, dict[str, dict[str, float]]] = {
    "FIT_A": {
        "7_slow_1100mv_100c":   {"out_setup": 0.668, "out_hold": 2.398, "in_setup": 1.976, "in_hold": 0.016},
        "7_slow_1100mv_-40c":   {"out_setup": 0.735, "out_hold": 2.542, "in_setup": 2.408, "in_hold": -0.255},
        "MIN_fast_1100mv_100c": {"out_setup": 1.544, "out_hold": 3.801, "in_setup": 5.176, "in_hold": -1.481},
        "MIN_fast_1100mv_-40c": {"out_setup": 1.603, "out_hold": 3.861, "in_setup": 5.585, "in_hold": -1.906},
    },
    "FIT_B": {
        "7_slow_1100mv_100c":   {"out_setup": -0.092, "out_hold": 3.482, "in_setup": 1.976, "in_hold": 0.016},
        "7_slow_1100mv_-40c":   {"out_setup": -0.021, "out_hold": 3.598, "in_setup": 2.408, "in_hold": -0.255},
        "MIN_fast_1100mv_100c": {"out_setup": 1.157, "out_hold": 4.377, "in_setup": 5.176, "in_hold": -1.481},
        "MIN_fast_1100mv_-40c": {"out_setup": 1.260, "out_hold": 4.344, "in_setup": 5.585, "in_hold": -1.906},
    },
}
IO_MODEL: dict[str, dict[str, float]] = {
    corner: {group: min(fit[corner][group] for fit in IO_FITS.values())
             for group in IO_FITS["FIT_A"][corner]}
    for corner in IO_FITS["FIT_A"]
}
#
# (The two fits were 50/100 split-clock builds, so their reference period T0 is the 100 MHz
# clk_sdram's; the model is a function of the SDRAM clock period whichever clock that is, and
# since the split-clock removal it is clk_sys's.)
# Their dependence on the phase phi and the SDRAM clock period T follows from the edge pairing
# (phi in (0, T)):
#   out_setup : latch = the SDRAM_CLK edge at phi            -> +phi
#   out_hold  : latch = the previous SDRAM_CLK edge, phi - T -> -phi + T
#   in_setup  : launch phi, latch 2T (setup 2)               -> -phi + 2T
#   in_hold   : launch phi, latch T (setup-2's default hold)  -> +phi - T
# The per-group worst is taken over the command/address pins and the DQ pins as outputs.
# d(slack)/d(phi) and d(slack)/d(T), per group.
IO_SLOPES = {
    "out_setup": (+1, 0),
    "out_hold": (-1, +1),
    "in_setup": (-1, +2),
    "in_hold": (+1, -1),
}
# Keep the phase strictly inside (0, T): the STA pairings above (and the DQ setup-2 count)
# assume it, and a phase at an edge flips the pairing.
PHASE_GUARD_NS = 0.1


def predict_io(phase_ns: float, period_ns: float) -> dict[str, dict[str, float]]:
    """Every corner's four group slacks at this phase and SDRAM clock (= clk_sys) period."""
    dphi = phase_ns - IO_MODEL_PHASE0_NS
    dt = period_ns - IO_MODEL_PERIOD0_NS
    out: dict[str, dict[str, float]] = {}
    for corner, groups in IO_MODEL.items():
        out[corner] = {g: round(s + IO_SLOPES[g][0] * dphi + IO_SLOPES[g][1] * dt, 3)
                       for g, s in groups.items()}
    return out


def io_worst(prediction: dict[str, dict[str, float]]) -> tuple[float, str, str]:
    worst = None
    for corner, groups in prediction.items():
        for group, slack in groups.items():
            if worst is None or slack < worst[0]:
                worst = (slack, corner, group)
    assert worst is not None
    return worst


def derive_sdram_phase(clk_hz: int) -> dict:
    """The phase (ps) that maximises the worst I/O slack over every corner and group.

    Every group is +phi or -phi, so the worst over the increasing ones is A(T) + (phi - phi0)
    and over the decreasing ones B(T) - (phi - phi0); the max-min is where they meet:

        phi*(T) = phi0 + (B(T) - A(T)) / 2,   worst*(T) = (A(T) + B(T)) / 2
        A(T) = min over corners of min(out_setup, in_hold - (T - T0))
        B(T) = min over corners of min(out_hold + (T - T0), in_setup + 2 (T - T0))

    clamped into (0, T) by PHASE_GUARD_NS.
    """
    period_ns = 1e9 / clk_hz
    dt = period_ns - IO_MODEL_PERIOD0_NS
    a = min(min(g["out_setup"], g["in_hold"] - dt) for g in IO_MODEL.values())
    b = min(min(g["out_hold"] + dt, g["in_setup"] + 2 * dt) for g in IO_MODEL.values())
    phase_ns = IO_MODEL_PHASE0_NS + (b - a) / 2
    clamped = False
    lo, hi = PHASE_GUARD_NS, period_ns - PHASE_GUARD_NS
    if not lo <= phase_ns <= hi:
        clamped = True
        phase_ns = min(max(phase_ns, lo), hi)
    phase_ps = int(round(phase_ns * 1000))
    prediction = predict_io(phase_ps / 1000, period_ns)
    worst = io_worst(prediction)
    return {
        "phase_ps": phase_ps,
        "period_ns": round(period_ns, 6),
        "A_ns": round(a, 3),
        "B_ns": round(b, 3),
        "worst_ns": worst[0],
        "worst_corner": worst[1],
        "worst_group": worst[2],
        "clamped": clamped,
    }


# ---------------------------------------------------------------------------------------
# The PLL: render, generate (cached), read back
# ---------------------------------------------------------------------------------------

@dataclasses.dataclass(frozen=True)
class PllRequest:
    clk_sys_hz: int        # outputs 0 (clk_sys, the SDRAM controller's clock too) and 1
    phase_ps: int          # output 1's phase: the SDRAM_CLK pin clock
    # The wizard's dynamic-phase-shift ports (gui_en_dps_ports), for the run-time SDRAM_CLK phase
    # instrument (build_profile.py sdram_phase_dyn, a test-only build). Off: the wizard's ordinary
    # PLL, whose wrapper postprocess() gives the same five port names tied off, so z486_mister.sv
    # instantiates `pll` one way in every build and the instance path (emu|pll|pll_inst) the SDC
    # names never moves.
    dps: bool = False

    def as_dict(self) -> dict:
        return dataclasses.asdict(self)


def template_device(template_text: str) -> str:
    m = re.search(r'<generic name="device" value="([^"]+)" />', template_text)
    if not m or m.group(1) == "Unknown":
        raise GenerationError(f"{PLL_TEMPLATE} names no device to restore")
    return m.group(1)


def render_pll_v(req: PllRequest, template_text: str | None = None) -> str:
    text = PLL_TEMPLATE.read_text() if template_text is None else template_text
    subs = {
        "@OUT0_MHZ@": mhz_text(req.clk_sys_hz),
        "@OUT1_MHZ@": mhz_text(req.clk_sys_hz),
        "@PHASE1_PS@": str(req.phase_ps),
        "@EN_DPS@": "true" if req.dps else "false",
    }
    for key, value in subs.items():
        if text.count(key) != 1:
            raise GenerationError(f"{PLL_TEMPLATE}: expected exactly one {key}")
        text = text.replace(key, value)
    return text


def container_runtime() -> str:
    return os.environ.get("CONTAINER_RUNTIME", "podman")


def container_image() -> str:
    return os.environ.get("QUARTUS_IMAGE", DEFAULT_IMAGE)


def image_digest(runtime: str, image: str) -> str:
    """The image's digest (or ID), so a different Quartus can never reuse a cached PLL."""
    for fmt in ("{{.Digest}}", "{{.Id}}"):
        try:
            out = subprocess.run([runtime, "image", "inspect", "--format", fmt, image],
                                 capture_output=True, text=True, check=False)
        except FileNotFoundError as exc:
            raise GenerationError(f"container runtime '{runtime}' not found "
                                  "(set CONTAINER_RUNTIME)") from exc
        value = out.stdout.strip()
        if out.returncode == 0 and value and value != "<none>":
            return value
    raise GenerationError(f"cannot inspect the Quartus image {image} with {runtime} "
                          "(pull it first, or set QUARTUS_IMAGE)")


def cache_root(project_dir: Path = PROJECT_DIR) -> Path:
    env = os.environ.get("PC9821_PLL_CACHE", "").strip()
    return Path(env) if env else project_dir / ".build" / "pll-cache"


def cache_key(req: PllRequest, digest: str) -> str:
    h = hashlib.sha256()
    h.update(json.dumps(req.as_dict(), sort_keys=True).encode())
    h.update(b"\0")
    h.update(PLL_TEMPLATE.read_bytes())
    h.update(b"\0")
    h.update(digest.encode())
    h.update(b"\0")
    h.update(GENERATOR_VERSION.encode())
    return h.hexdigest()[:24]


# The wizard's dynamic-phase-shift port declarations on the `pll` wrapper (qmegawiz with
# gui_en_dps_ports = true writes exactly these, in this order, after `locked`).
DPS_PORTS = ("phase_en", "scanclk", "updn", "cntsel", "phase_done")
DPS_WRAPPER_PORTS = (
    "\t\tinput  wire       phase_en,   //   (tools/profile_gen.py: tied off, no DPS)\n"
    "\t\tinput  wire       scanclk,\n"
    "\t\tinput  wire       updn,\n"
    "\t\tinput  wire [4:0] cntsel,\n"
    "\t\toutput wire       phase_done\n")
# The assignment the wizard's DPS generation puts in pll_0002.qip in place of the ordinary
# generation's PLL_AUTO_RESET OFF / PLL_BANDWIDTH_PRESET AUTO pair (both of which are the Quartus
# defaults for this PLL). The tracked qip is used for both, so a DPS build is fitted with the same
# PLL settings as the base one; UNFORCE_MERGE only frees the fitter to keep counters unmerged, and
# outputs 0 and 1 differ in phase, so they cannot be merged anyway.
DPS_QIP_LINE = ('set_instance_assignment -name UNFORCE_MERGE_PLL_OUTPUT_COUNTER ON -to '
                '"*pll_0002*|altera_pll:altera_pll_i*|*"')


def add_tied_dps_ports(text: str) -> str:
    """The ordinary wrapper with the DPS port names declared and tied off (phase_done = 0)."""
    if any(re.search(rf"\b{p}\b", text.split("endmodule")[0]) for p in DPS_PORTS):
        raise GenerationError("the non-DPS pll.v already names a DPS port")
    text, n = re.subn(r"(\t\toutput wire\s+locked)(\s+)(//[^\n]*)\n(\t\);)",
                      lambda m: f"{m.group(1)},{m.group(2)}{m.group(3)}\n{DPS_WRAPPER_PORTS}{m.group(4)}",
                      text, count=1)
    if n != 1:
        raise GenerationError("qmegawiz's pll.v has no `locked` port to follow with the DPS ports")
    text, n = re.subn(r"\n(endmodule)", "\n\tassign phase_done = 1'b0;\n\n\\1", text, count=1)
    if n != 1:
        raise GenerationError("qmegawiz's pll.v has no endmodule")
    return text


def postprocess(work: Path, device: str, dps: bool = False) -> None:
    """What a GUI generation has and the project-less CLI cannot know."""
    pll_v = work / "pll.v"
    text = pll_v.read_text()
    text, n = re.subn(r'(<generic name="device" value=")[^"]*(" />)',
                      lambda m: m.group(1) + device + m.group(2), text)
    if n != 1:
        raise GenerationError("qmegawiz's pll.v has no single device generic to restore")
    if not dps:
        text = add_tied_dps_ports(text)
    pll_v.write_text(text)

    qip = work / "pll.qip"
    dev_b64 = base64.b64encode(device.encode()).decode()
    text = qip.read_text()
    key = base64.b64encode(b"device").decode()                  # ZGV2aWNl
    text, n = re.subn(rf"{key}::[A-Za-z0-9+/=]*::{key}", f"{key}::{dev_b64}::{key}", text)
    if n != 1:
        raise GenerationError("qmegawiz's pll.qip has no single device parameter to restore")
    grade = base64.b64encode(b"gui_device_speed_grade").decode().rstrip("=")
    text = "".join(line for line in text.splitlines(keepends=True) if grade not in line)
    qip.write_text(text)

    for name in PLL_SIDE_FILES:
        path = work / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()


def run_qmegawiz(work: Path, runtime: str, image: str) -> None:
    cmd = [runtime, "run", "--rm", "-v", f"{work}:/work:Z", "-w", "/work", image,
           "bash", "-lc", f"{QMEGAWIZ} -silent pll.v"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0 or not (work / "pll" / "pll_0002.v").exists():
        raise GenerationError(
            f"qmegawiz failed (exit {proc.returncode}):\n{proc.stdout[-2000:]}{proc.stderr[-2000:]}")


# ---- read-back ------------------------------------------------------------------------

def read_back(pll_dir: Path) -> dict:
    """The generated PLL's actual outputs (pll_0002.v) and its requested generics (pll.v)."""
    v2 = (pll_dir / "pll" / "pll_0002.v").read_text()
    out: dict = {}
    for i in range(PLL_OUTPUTS):
        m = re.search(rf'\.output_clock_frequency{i}\("([^"]*)"\)', v2)
        if not m:
            raise GenerationError(f"pll_0002.v has no output_clock_frequency{i}")
        out[f"freq{i}_hz"] = parse_mhz(m.group(1))
        m = re.search(rf'\.phase_shift{i}\("(-?\d+) ps"\)', v2)
        if not m:
            raise GenerationError(f"pll_0002.v has no phase_shift{i}")
        out[f"phase{i}_ps"] = int(m.group(1))
    m = re.search(r'\.number_of_clocks\((\d+)\)', v2)
    out["number_of_clocks"] = int(m.group(1)) if m else None
    m = re.search(r'\.pll_subtype\("([^"]*)"\)', v2)
    out["pll_subtype"] = m.group(1) if m else None
    pv = (pll_dir / "pll.v").read_text()
    head = pv.split("endmodule")[0]
    out["wrapper_ports"] = [p for p in DPS_PORTS if re.search(rf"\b{p}\b", head)]
    out["dps_connected"] = re.search(r"\.phase_en\s*\(\s*phase_en\s*\)", head) is not None
    req: dict = {}
    for key in ("gui_number_of_clocks", "gui_output_clock_frequency0",
                "gui_output_clock_frequency1", "gui_phase_shift1", "device", "gui_en_dps_ports"):
        m = re.search(rf'<generic name="{key}" value="([^"]*)" />', pv)
        req[key] = m.group(1) if m else None
    out["requested"] = req
    return out


def vco_candidates(freqs_hz: list[int], phase_ps: int) -> list[int]:
    """Every integer-N VCO (300-1600 MHz, a multiple of every output) the phase is consistent with.

    The wizard reports the phase truncated to whole ps, and an output's phase is a whole
    number of VCO/8 steps, so a VCO is consistent when some multiple of its step lies in
    [phase, phase + 1) ps.
    """
    step_l = math.lcm(*freqs_hz)
    out = []
    k = 1
    while k * step_l <= 1_600_000_000:
        vco = k * step_l
        k += 1
        if vco < 300_000_000:
            continue
        step = Fraction(10**12, 8 * vco)                    # ps
        n = math.ceil(Fraction(phase_ps) / step)
        if n * step < phase_ps + 1:
            out.append(vco)
    return out


def verify_readback(req: PllRequest, rb: dict) -> list[str]:
    """Every way the generated PLL is not the requested one."""
    problems = []
    for i in range(PLL_OUTPUTS):
        if rb[f"freq{i}_hz"] != req.clk_sys_hz:
            problems.append(f"output {i} runs at {rb[f'freq{i}_hz']:_} Hz, requested "
                            f"{req.clk_sys_hz:_} Hz (the integer-N PLL cannot make it exactly from "
                            "50 MHz - pick a nearby frequency)")
    if rb["phase0_ps"] != 0:
        problems.append(f"output 0 has phase {rb['phase0_ps']} ps; it must be 0 (clk_sys is the "
                        "reference the SDC's SDRAM I/O model is measured against)")
    if rb.get("number_of_clocks") not in (None, PLL_OUTPUTS):
        problems.append(f"the PLL has {rb['number_of_clocks']} outputs, expected {PLL_OUTPUTS}")
    actual = rb[f"phase{PIN_CLOCK_OUTPUT}_ps"]
    vcos = vco_candidates([rb[f"freq{i}_hz"] for i in range(PLL_OUTPUTS)], actual)
    if not vcos:
        problems.append(f"output {PIN_CLOCK_OUTPUT}'s phase {actual} ps is not a whole number of "
                        "VCO/8 steps for any VCO the outputs allow")
    else:
        # The most lenient consistent VCO: the coarsest step the wizard could have been on.
        step_ps = 1e12 / (8 * min(vcos))
        if abs(actual - req.phase_ps) > step_ps:
            problems.append(f"output {PIN_CLOCK_OUTPUT}'s phase is {actual} ps, requested "
                            f"{req.phase_ps} ps: off by more than one VCO phase step "
                            f"({step_ps:.1f} ps)")
    r = rb["requested"]
    if r.get("gui_number_of_clocks") not in (None, str(PLL_OUTPUTS)):
        problems.append(f"pll.v requests {r.get('gui_number_of_clocks')} outputs, not {PLL_OUTPUTS}")
    for key in ("gui_output_clock_frequency0", "gui_output_clock_frequency1"):
        if r.get(key) != mhz_text(req.clk_sys_hz):
            problems.append(f"pll.v requests {key} = {r.get(key)} MHz, not {mhz_text(req.clk_sys_hz)}")
    if r.get("gui_phase_shift1") != str(req.phase_ps):
        problems.append(f"pll.v requests phase {r.get('gui_phase_shift1')} ps, not {req.phase_ps}")
    if r.get("device") in (None, "Unknown"):
        problems.append("pll.v carries no device (the post-processing did not restore it)")
    # The dynamic-phase-shift ports: requested, generated (pll_subtype DPS) and connected exactly
    # when the configuration asks for the run-time phase instrument; the wrapper declares the five
    # port names either way (z486_mister.sv instantiates it one way).
    want = "true" if req.dps else "false"
    if r.get("gui_en_dps_ports") not in (None, want):
        problems.append(f"pll.v requests gui_en_dps_ports = {r.get('gui_en_dps_ports')}, the "
                        f"configuration means {want}")
    sub = rb.get("pll_subtype")
    if sub is not None and (sub == "DPS") != req.dps:
        problems.append(f"pll_0002.v is pll_subtype {sub}: the configuration "
                        f"{'needs' if req.dps else 'must not have'} the DPS ports")
    if "wrapper_ports" in rb and list(rb["wrapper_ports"]) != list(DPS_PORTS):
        problems.append(f"pll.v declares {rb['wrapper_ports']} of the DPS ports {list(DPS_PORTS)}: "
                        "z486_mister.sv connects all five")
    if "dps_connected" in rb and rb["dps_connected"] != req.dps:
        problems.append("pll.v " + ("does not pass" if req.dps else "passes") +
                        " the DPS ports to the PLL")
    return problems


def phase_step_ps(rb: dict) -> float | None:
    vcos = vco_candidates([rb[f"freq{i}_hz"] for i in range(PLL_OUTPUTS)],
                          rb[f"phase{PIN_CLOCK_OUTPUT}_ps"])
    return 1e12 / (8 * min(vcos)) if vcos else None


def generate_pll(req: PllRequest, dest_rtl: Path, *, project_dir: Path = PROJECT_DIR,
                 log=print) -> dict:
    """Write the requested PLL's three files under dest_rtl; return its read-back record."""
    runtime, image = container_runtime(), container_image()
    digest = image_digest(runtime, image)
    root = cache_root(project_dir)
    key = cache_key(req, digest)
    entry = root / key
    record_path = entry / "readback.json"
    if not record_path.exists():
        template_text = PLL_TEMPLATE.read_text()
        device = template_device(template_text)
        root.mkdir(parents=True, exist_ok=True)
        work = root / f"{key}.tmp-{os.getpid()}"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        try:
            (work / "pll.v").write_text(render_pll_v(req, template_text))
            log(f"==> generating the PLL (clk_sys {req.clk_sys_hz:_} Hz, SDRAM pin-clock phase "
                f"{req.phase_ps} ps) with qmegawiz in {image}")
            run_qmegawiz(work, runtime, image)
            postprocess(work, device, req.dps)
            tracked = project_dir / TRACKED_PLL_QIP2
            got_qip = (work / "pll" / "pll_0002.qip").read_text()
            if req.dps:
                lines = [l.strip() for l in got_qip.splitlines() if l.strip()]
                want = [l.strip() for l in tracked.read_text().splitlines()
                        if l.strip() and "PLL_AUTO_RESET" not in l
                        and "PLL_BANDWIDTH_PRESET" not in l] + [DPS_QIP_LINE]
                if lines != want:
                    raise GenerationError(f"qmegawiz's DPS pll/pll_0002.qip is not the tracked one "
                                          f"with {DPS_QIP_LINE}: {lines}")
            elif tracked.exists() and got_qip.encode() != tracked.read_bytes():
                raise GenerationError(f"qmegawiz's pll/pll_0002.qip differs from the tracked "
                                      f"{TRACKED_PLL_QIP2}")
            (work / "pll" / "pll_0002.qip").unlink()
            rb = read_back(work)
            problems = verify_readback(req, rb)
            if problems:
                raise GenerationError("the generated PLL is not the requested one:\n  "
                                      + "\n  ".join(problems))
            rb["request"] = req.as_dict()
            rb["image"] = image
            rb["image_digest"] = digest
            rb["generator_version"] = GENERATOR_VERSION
            rb["phase_step_ps"] = phase_step_ps(rb)
            (work / "readback.json").write_text(json.dumps(rb, indent=2, sort_keys=True) + "\n")
            try:
                os.rename(work, entry)
            except OSError:
                # A concurrent generation of the same key won the rename; theirs is identical.
                shutil.rmtree(work, ignore_errors=True)
        except BaseException:
            shutil.rmtree(work, ignore_errors=True)
            raise
    else:
        log(f"==> PLL cache hit {entry}")
    rb = json.loads(record_path.read_text())
    for rel in PLL_FILES:
        dst = dest_rtl / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes((entry / rel).read_bytes())
    # Re-verify the files actually installed, not just the cache's record of them.
    problems = verify_readback(req, read_back(dest_rtl))
    if problems:
        raise GenerationError("the installed PLL is not the requested one:\n  "
                              + "\n  ".join(problems))
    rb["cache_entry"] = str(entry)
    return rb


# ---------------------------------------------------------------------------------------
# The video PLL: a second, fixed-ratio PLL for CLK_VIDEO (pc9821_video_out)
# ---------------------------------------------------------------------------------------
#
# The analog picture needs a video clock that is an EXACT multiple of the dot rate the raster runs on,
# so every pixel and sync period is a constant number of clocks. The video PLL is a FRACTIONAL-N PLL
# on the 50 MHz reference, N bypassed, C0 = 19: CLK_VIDEO = 50 MHz x (M + K/2^32) / 19, and
# pc9821_vpll_ctl reprograms it at run time between (src/pc9821/video/pc9821_vclk_pkg.sv holds the
# numbers; VCLK_SETTINGS below must equal them):
#   24 kHz  M 16, K 0           800/19 MHz = 42.105 263 MHz   (2 x 400/19 MHz)
#   31 kHz  M 19, K 0x20B00000  50.336 015 MHz                 (2 x the captured 25.168 MHz, -0.94 ppm)
# The wizard GENERATES it at the build's fastest clock, the 31 kHz configuration, so the fitter times
# the video domain at that period (19.866 ns). pc9821_vpll_ctl writes N, M and K on every
# reconfiguration, so the generated values matter only for the timing analysis and the first lock.
# The read-back checks the wizard's counters and fraction, not just its rounded frequency text.
VPLL_TEMPLATE = PROFILE_DIR / "vpll_template.v"
VPLL_FILES = (Path("vpll.v"), Path("vpll.qip"), Path("vpll/vpll_0002.v"), Path("vpll/vpll_0002.qip"))
VPLL_SIDE_FILES = ("vpll.bsf", "vpll.cmp", "vpll.ppf", "vpll.sip", "vpll.spd", "vpll_sim",
                   "vpll_sim.f")
VPLL_GENERATOR_VERSION = "2"
# The run-time settings (pc9821_vclk_pkg): {name: (M, K)}.
VCLK_SETTINGS = {"24k": (16, 0), "31k": (19, 0x20B0_0000)}
VPLL_C = 19
# {VpllRequest.tv: (requested MHz text, the wizard's reported frequency, M hi/lo, K, VCO text)}
# The 31 kHz generation (tv False) is the only one: there is no TV converter, so no other rate is
# ever generated. The `tv` key stays so the request (and the stamp it is recorded in) is unchanged.
VPLL_CONFIGS = {
    False: ("50.336015", "50.336014 MHz", (10, 9), 0x20B0_0000, "956.384266 MHz"),
}
VPLL_C0 = (10, 9)            # C0 = 19: high 10, low 9 (odd division)


def vpll_generated_hz(tv: bool) -> Fraction:
    _, _, m_hilo, k, _ = VPLL_CONFIGS[tv]
    return Fraction(50_000_000) * (sum(m_hilo) + Fraction(k, 1 << 32)) / VPLL_C


VCLK_PKG = Path("src/pc9821/video/pc9821_vclk_pkg.sv")


def vclk_pkg_problems(text: str) -> list[str]:
    """pc9821_vclk_pkg (what the RTL programs and the dot enable runs at) against VCLK_SETTINGS and
    VPLL_C (what the generator and its read-back assume), and the base generation at 31 kHz."""
    def val(name):
        m = re.search(rf"localparam\s+int\s+unsigned\s+{name}\s*=\s*(32'h([0-9A-Fa-f_]+)|(\d+))\s*;", text)
        if not m:
            return None
        return int(m.group(2).replace("_", ""), 16) if m.group(2) else int(m.group(3))
    problems = []
    for key, suffix in (("24k", "24"), ("31k", "31")):
        got = (val(f"VPLL_M{suffix}"), val(f"VPLL_K{suffix}"))
        if got != VCLK_SETTINGS[key]:
            problems.append(f"{VCLK_PKG}: the {key} setting is M {got[0]} K {got[1]}, tools/profile_gen.py "
                            f"VCLK_SETTINGS says M {VCLK_SETTINGS[key][0]} K {VCLK_SETTINGS[key][1]}")
    if val("VPLL_C") != VPLL_C:
        problems.append(f"{VCLK_PKG}: VPLL_C is {val('VPLL_C')}, the generated PLL's C0 is {VPLL_C}")
    gen = VPLL_CONFIGS[False]
    if (sum(gen[2]), gen[3]) != VCLK_SETTINGS["31k"]:
        problems.append("the base build's video PLL is not generated at the 31 kHz setting (VPLL_CONFIGS)")
    return problems


# The video clock's period as generated (ns), for the SDC's crossing bound.
VPLL_PERIOD_NS = {tv: Fraction(10 ** 9) / vpll_generated_hz(tv) for tv in VPLL_CONFIGS}


@dataclasses.dataclass(frozen=True)
class VpllRequest:
    tv: bool               # always False: the 31 kHz generation (VPLL_CONFIGS) is the only one

    def as_dict(self) -> dict:
        return dataclasses.asdict(self)


def render_vpll_v(req: VpllRequest, template_text: str | None = None) -> str:
    text = VPLL_TEMPLATE.read_text() if template_text is None else template_text
    subs = {"@VPLL_MHZ@": VPLL_CONFIGS[req.tv][0],
            "@VPLL_M@": str(sum(VPLL_CONFIGS[req.tv][2])),
            "@VPLL_K@": str(VPLL_CONFIGS[req.tv][3])}
    for key, value in subs.items():
        if text.count(key) != 1:
            raise GenerationError(f"{VPLL_TEMPLATE}: expected exactly one {key}")
        text = text.replace(key, value)
    return text


def read_back_vpll(pll_dir: Path) -> dict:
    """The generated video PLL's frequency, counters and reconfigurability (vpll/vpll_0002.v)."""
    v2 = (pll_dir / "vpll" / "vpll_0002.v").read_text()

    def one(pattern: str, what: str) -> str:
        m = re.search(pattern, v2)
        if not m:
            raise GenerationError(f"vpll_0002.v has no {what}")
        return m.group(1)
    out = {
        "freq0": one(r'\.output_clock_frequency0\("([^"]*)"\)', "output_clock_frequency0"),
        "vco": one(r'\.pll_output_clk_frequency\("([^"]*)"\)', "pll_output_clk_frequency"),
        "m": (int(one(r'\.m_cnt_hi_div\((\d+)\)', "m_cnt_hi_div")),
              int(one(r'\.m_cnt_lo_div\((\d+)\)', "m_cnt_lo_div"))),
        "c0": (int(one(r'\.c_cnt_hi_div0\((\d+)\)', "c_cnt_hi_div0")),
               int(one(r'\.c_cnt_lo_div0\((\d+)\)', "c_cnt_lo_div0"))),
        "n_bypass": one(r'\.n_cnt_bypass_en\("([^"]*)"\)', "n_cnt_bypass_en"),
        "frac_vco": one(r'\.fractional_vco_multiplier\("([^"]*)"\)', "fractional_vco_multiplier"),
        "k": int(one(r'\.pll_fractional_division\("(\d+)"\)', "pll_fractional_division")),
        "subtype": one(r'\.pll_subtype\("([^"]*)"\)', "pll_subtype"),
        "reconf_ports": "reconfig_to_pll" in (pll_dir / "vpll.v").read_text(),
    }
    m = re.search(r'\.number_of_clocks\((\d+)\)', v2)
    out["number_of_clocks"] = int(m.group(1)) if m else None
    return out


def verify_readback_vpll(req: VpllRequest, rb: dict) -> list[str]:
    _, freq_text, m_hilo, k, vco = VPLL_CONFIGS[req.tv]
    problems = []
    if rb["freq0"] != freq_text:
        problems.append(f"the video PLL runs at {rb['freq0']}, expected {freq_text}")
    if (tuple(rb["m"]) != m_hilo or rb.get("k") != k or tuple(rb["c0"]) != VPLL_C0
            or rb["n_bypass"] != "true"):
        problems.append(f"the video PLL's counters are M {tuple(rb['m'])} K {rb.get('k')} C0 "
                        f"{tuple(rb['c0'])} N bypass {rb['n_bypass']}, expected M {m_hilo} K {k} "
                        f"C0 {VPLL_C0} N bypass true (50 MHz x (M + K/2^32) / 19)")
    if rb.get("frac_vco") != "true":
        problems.append(f"the video PLL is not fractional-N (fractional_vco_multiplier "
                        f"{rb.get('frac_vco')}): pc9821_vpll_ctl's K writes need it")
    if rb["vco"] != vco:
        problems.append(f"the video PLL's VCO is {rb['vco']}, expected {vco}")
    if rb["subtype"] != "Reconfigurable" or not rb["reconf_ports"]:
        problems.append(f"the video PLL is {rb['subtype']} (reconfiguration ports "
                        f"{rb['reconf_ports']}), expected Reconfigurable: pc9821_vpll_ctl moves it "
                        "between the 24 kHz and 31 kHz dot clocks in every build")
    if rb.get("number_of_clocks") not in (None, 1):
        problems.append(f"the video PLL has {rb['number_of_clocks']} outputs, expected 1")
    return problems


def generate_vpll(req: VpllRequest, dest_rtl: Path, *, project_dir: Path = PROJECT_DIR,
                  log=print) -> dict:
    """Write the requested video PLL's files under dest_rtl; return its read-back record."""
    runtime, image = container_runtime(), container_image()
    digest = image_digest(runtime, image)
    root = cache_root(project_dir)
    h = hashlib.sha256()
    for part in (json.dumps(req.as_dict(), sort_keys=True).encode(), VPLL_TEMPLATE.read_bytes(),
                 digest.encode(), ("vpll" + VPLL_GENERATOR_VERSION).encode()):
        h.update(part)
        h.update(b"\0")
    entry = root / ("vpll-" + h.hexdigest()[:24])
    record_path = entry / "readback.json"
    if not record_path.exists():
        template_text = VPLL_TEMPLATE.read_text()
        device = template_device(template_text)
        root.mkdir(parents=True, exist_ok=True)
        work = root / f"{entry.name}.tmp-{os.getpid()}"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        try:
            (work / "vpll.v").write_text(render_vpll_v(req, template_text))
            log(f"==> generating the video PLL ({VPLL_CONFIGS[req.tv][0]} MHz, fractional, "
                f"reconfigurable) with qmegawiz in {image}")
            cmd = [runtime, "run", "--rm", "-v", f"{work}:/work:Z", "-w", "/work", image,
                   "bash", "-lc", f"{QMEGAWIZ} -silent vpll.v"]
            proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
            if proc.returncode != 0 or not (work / "vpll" / "vpll_0002.v").exists():
                raise GenerationError(f"qmegawiz failed on the video PLL (exit {proc.returncode}):\n"
                                      f"{proc.stdout[-2000:]}{proc.stderr[-2000:]}")
            # The device a project-less generation cannot know, as for the main PLL.
            for name, pat, fmt in (
                    ("vpll.v", r'(<generic name="device" value=")[^"]*(" />)', None),):
                path = work / name
                text, n = re.subn(pat, lambda m: m.group(1) + device + m.group(2), path.read_text())
                if n != 1:
                    raise GenerationError(f"qmegawiz's {name} has no single device generic to restore")
                path.write_text(text)
            qip = work / "vpll.qip"
            key = base64.b64encode(b"device").decode()
            text, n = re.subn(rf"{key}::[A-Za-z0-9+/=]*::{key}",
                              f"{key}::{base64.b64encode(device.encode()).decode()}::{key}",
                              qip.read_text())
            if n != 1:
                raise GenerationError("qmegawiz's vpll.qip has no single device parameter to restore")
            grade = base64.b64encode(b"gui_device_speed_grade").decode().rstrip("=")
            qip.write_text("".join(line for line in text.splitlines(keepends=True) if grade not in line))
            for name in VPLL_SIDE_FILES:
                path = work / name
                if path.is_dir():
                    shutil.rmtree(path)
                elif path.exists():
                    path.unlink()
            rb = read_back_vpll(work)
            problems = verify_readback_vpll(req, rb)
            if problems:
                raise GenerationError("the generated video PLL is not the requested one:\n  "
                                      + "\n  ".join(problems))
            rb["request"] = req.as_dict()
            rb["image_digest"] = digest
            (work / "readback.json").write_text(json.dumps(rb, indent=2, sort_keys=True) + "\n")
            try:
                os.rename(work, entry)
            except OSError:
                shutil.rmtree(work, ignore_errors=True)
        except BaseException:
            shutil.rmtree(work, ignore_errors=True)
            raise
    else:
        log(f"==> video PLL cache hit {entry}")
    rb = json.loads(record_path.read_text())
    for rel in VPLL_FILES:
        dst = dest_rtl / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes((entry / rel).read_bytes())
    problems = verify_readback_vpll(req, read_back_vpll(dest_rtl))
    if problems:
        raise GenerationError("the installed video PLL is not the requested one:\n  "
                              + "\n  ".join(problems))
    rb["cache_entry"] = str(entry)
    return rb


# ---------------------------------------------------------------------------------------
# The SDC
# ---------------------------------------------------------------------------------------

def render_sdc_block(name: str, clk_sys_hz: int) -> str:
    return "\n".join([
        f"{SDC_PROFILE_BEGIN}   (computed by tools/profile_gen.py; the ONLY block that differs)",
        f"# {name}: clk_sys {mhz_text(clk_sys_hz)} MHz (T {ns(Fraction(10**9, clk_sys_hz))} ns). The "
        "SDRAM controller and its PHY run on clk_sys,",
        "# so there is no second clock domain: no crossing multicycle, no gray-pointer bound.",
        SDC_PROFILE_END,
    ])


# SDRAM_CLK structure (compile-time, one decision: sdram_clk_ddio):
#  * DDIO off (clk_sys < 100 MHz, today's build): SDRAM_CLK is PLL output 1 (general[1]), phase-shifted
#    by derive_sdram_phase; the SDRAM runs CL2, tAC max 6.0 ns.
#  * DDIO on (clk_sys >= 100 MHz, the CL3 builds): SDRAM_CLK is clk_sys inverted through an output
#    DDIO cell (z486_mister.sv sdram_clk_ddr), T/2 fixed, so the generated clock's source is the clk_sys
#    pin itself (general[0]; output 1 is spare, derive_sdram_phase moot) and it is `-invert`ed. tAC max
#    is the CL3 figure, 5.4 ns (AS4C32M16SB Rev 1.4 Table 16, tAC `CL* = 3`: max 5 (-6) / 5.4 (-7), the
#    -7 bound; the SDRAM controller runs CL3 from 100 MHz, sdram.v CAS_I). Load derating not modelled.
#    The IO_MODEL is NOT used for the DDIO structure (its phase axis does not exist there); the
#    fitted four-corner slacks are the evidence (+0.06..+0.09 ns worst at 110/120 MHz).
SDRAM_TAC_CL2_NS = "6.0"
SDRAM_TAC_CL3_NS = "5.4"
SDRAM_DDIO_MIN_HZ = 100_000_000   # == sdram.v's CL3 threshold; z486_mister.sv SDRAM_CLK_DDIO


def sdram_clk_ddio(clk_sys_hz: int) -> bool:
    return clk_sys_hz >= SDRAM_DDIO_MIN_HZ


# The SDRAM DQ read capture (build_profile.py sdram_dq_ddio -> sdram.v DQ_IN_DDIO). Either way it
# is the IOE input cell's rising-edge register, so the I/O model above (measured on the packed
# register) describes both; what differs is the register's NAME in the fitted netlist, which the
# SDC's capture collection must match exactly 16 times:
#  * on (the default): sdram.v instantiates altddio_in as `dq_cap` (in generate block g_dq_ddio);
#    Quartus expands it into 16 cyclonev_ddio_in atoms (db/ddio_in_*.tdf), and TimeQuest names
#    each one's rising-edge register after its output, `...|altddio_in:g_dq_ddio.dq_cap|
#    ddio_in_*:auto_generated|dataout_h[n]` (read back from the netlist). The falling-edge half
#    has no consumer, but the FITTED netlist keeps it as a timing node, `...|ddio_ina[n]~DFFLO`
#    (absent post-map); timed single-cycle on the falling edge it reports a false ~-5 ns setup
#    failure on every pin (fitted seed 9, census sdram_io_in), so its input path is cut.
#  * off: g_dq_ff's `dq_r_ff`, a fabric register the qsf's FAST_INPUT_REGISTER packs into the cell.
DQ_DDIO_INSTANCE = "altddio_in:dq_cap"
DQ_CAPTURE_REGS = {
    True: "*|sdram:ctrl|*dq_cap|*dataout_h[*]",
    False: "*|sdram:ctrl|*dq_r_ff[*]",
}
DQ_DDIO_LO_REGS = "*|sdram:ctrl|*dq_cap|*ddio_ina[*]~DFFLO"


def render_dq_lo_cut(dq_ddio: bool) -> str:
    if not dq_ddio:
        return "# (the packed register is a single-edge cell: no low half to cut)"
    return "\n".join([
        "# The input DDIO cells' unused falling-edge halves: timing nodes in the fitted netlist",
        "# (16), absent from the post-map one (0); anything else means the pattern went stale.",
        f"set pc9821_sdram_dq_lo [get_registers -nowarn {{{DQ_DDIO_LO_REGS}}}]",
        "set pc9821_sdram_dq_lo_n [get_collection_size $pc9821_sdram_dq_lo]",
        "if {$pc9821_sdram_dq_lo_n != 0 && $pc9821_sdram_dq_lo_n != 16} {",
        '    error "PC9821: expected 0 (post-map) or 16 (fitted) unused SDRAM DQ input DDIO low halves"',
        "}",
        "if {$pc9821_sdram_dq_lo_n == 16} {",
        "    set_false_path -from [get_ports SDRAM_DQ[*]] -to $pc9821_sdram_dq_lo",
        "}",
    ])


# The SDRAM output registers (build_profile.py sdram_out_ddio -> sdram.v OUT_DDIO). Either way each
# output pin leaves from its I/O cell's register, loaded on the rising clk_sys edge, and the output
# constraints are on the PORTS, so they need no register names; what the cells add is the clock-phase
# mux of an output DDIO (cyclonev_ddio_out: DFFHI and DFFLO both load on the rising edge, and the
# clock selects DFFHI while high, DFFLO while low). TimeQuest times that select as a clock-as-data
# path from BOTH clk_sys edges to the pin; with datain_h == datain_l the falling-edge switch picks
# an equal value and moves nothing, so the falling-edge launch to the SDRAM outputs is cut (it read
# a false ~-4.6 ns on a one-module fit). The rising-edge select path and the OE cell's register are
# the real launches and stay timed. The guard counts the cells, so a build whose parameter did not
# reach sdram.v (no cells, packed registers) cannot pass with the exception silently inert.
OUT_DDIO_INSTANCES = ("altddio_out:cmd_out", "altddio_out:ca_out", "altddio_out:dq_out_cell")
# Read back from a fitted netlist (and its post-map one: the same 90 names): each altddio_out bit
# is `...|sdram:ctrl|altddio_out:g_out_ddio.ca_out|ddio_out_*:auto_generated|ddio_outa[n]~DFFHI0`
# and `...~DFFLO` (cmd_out 3 bits, ca_out 18, dq_out_cell 16), each OE cell
# `...|sdram:ctrl|g_out_ddio.dq_oe_q[n]` (16: the per-pin DQ output-enable registers, fabric
# registers by design, see sdram.v; their path to the pins is timed by the output delays below).
OUT_CELL_REGS = "*|sdram:ctrl|*_out*|*ddio_outa[*]~DFF* *|sdram:ctrl|*dq_oe_q[*]"
OUT_CELL_COUNT = 2 * (3 + 18 + 16) + 16


def render_out_cut(out_ddio: bool) -> str:
    if not out_ddio:
        return "# (the packed output registers are single-edge cells: no clock-phase mux to cut)"
    return "\n".join([
        "# The output cells (sdram.v OUT_DDIO): the DDIO clock-phase mux's falling-edge switch selects",
        "# a value equal to the one already on the pin (datain_h == datain_l), so it launches nothing.",
        f"set pc9821_sdram_out_cells [get_registers -nowarn {{{OUT_CELL_REGS}}}]",
        f"if {{[get_collection_size $pc9821_sdram_out_cells] != {OUT_CELL_COUNT}}} {{",
        f'    error "PC9821: expected {OUT_CELL_COUNT} SDRAM output-cell registers ({OUT_CELL_REGS})"',
        "}",
        "set_false_path -fall_from $pc9821_clk_sys -to $pc9821_sdram_out",
    ])


# The main PLL's output-counter clock names: the ordinary altera_pll names them
# general[N].gpll~PLL_OUTPUT_COUNTER, the dynamic-phase-shift one (pll_subtype DPS, sdram_phase_dyn)
# cyclonev_pll|counter[N].output_counter (read back from a fitted DPS build's sta.rpt Clocks table).
def pll_counter(n: int, dps: bool) -> str:
    return f"cyclonev_pll|counter[{n}].output_counter" if dps else f"general[{n}]"


def render_sdc(name: str, clk_sys_hz: int, tv: bool = False, dq_ddio: bool = True,
               out_ddio: bool = True, clk_ddio: bool | None = None, dps: bool = False) -> str:
    text = SDC_TEMPLATE.read_text()
    if text.count(SDC_BLOCK_PLACEHOLDER) != 1:
        raise GenerationError(f"{SDC_TEMPLATE}: expected exactly one {SDC_BLOCK_PLACEHOLDER}")
    # The clk_sys <-> video clock crossings are bounded by one period of the destination: the video
    # clock's GENERATED (fastest) configuration (50.336 MHz), and clk_sys's own period.
    for token, value in (("@VCLK_PERIOD_NS@", f"{float(VPLL_PERIOD_NS[tv]):.3f}"),
                         ("@CLK_SYS_PERIOD_NS@", f"{1e9 / clk_sys_hz:.3f}")):
        if text.count(token) != 1:
            raise GenerationError(f"{SDC_TEMPLATE}: expected exactly one {token}")
        text = text.replace(token, value)
    # clk_ddio: the configuration's SDRAM_CLK structure (build_profile.py Config.sdram_clk_ddio), which
    # is sdram_clk_ddio(clk_sys_hz) except in a --dbg-sdram-cl2 measurement build.
    ddio = sdram_clk_ddio(clk_sys_hz) if clk_ddio is None else clk_ddio
    if text.count("@CLK_SYS_COUNTER@") != 1:
        raise GenerationError(f"{SDC_TEMPLATE}: expected exactly one @CLK_SYS_COUNTER@")
    text = text.replace("@CLK_SYS_COUNTER@", pll_counter(0, dps))
    for token, off, on in (
            ("@SDRAM_PIN_CLK_COUNTER@", pll_counter(PIN_CLOCK_OUTPUT, dps), pll_counter(0, dps)),
            ("@SDRAM_CLK_INVERT@", "", " -invert"),
            ("@SDRAM_TAC_NS@", SDRAM_TAC_CL2_NS, SDRAM_TAC_CL3_NS)):
        if text.count(token) != 1:
            raise GenerationError(f"{SDC_TEMPLATE}: expected exactly one {token}")
        text = text.replace(token, on if ddio else off)
    for token, value in (("@SDRAM_DQ_CAPTURE_REGS@", DQ_CAPTURE_REGS[dq_ddio]),
                         ("@SDRAM_DQ_LO_CUT@", render_dq_lo_cut(dq_ddio)),
                         ("@SDRAM_OUT_CELL_CUT@", render_out_cut(out_ddio))):
        if text.count(token) < 1:
            raise GenerationError(f"{SDC_TEMPLATE}: expected {token}")
        text = text.replace(token, value)
    return text.replace(SDC_BLOCK_PLACEHOLDER, render_sdc_block(name, clk_sys_hz))


def sdc_block_shape_problems(text: str, label: str) -> list[str]:
    """Only comments may sit inside the computed block (it carried the split-clock build's
    multicycles and max-delays until that configuration was removed; a constraint there now is a
    stale render or a hand edit).

    A generated comment that lost its '#' is parsed as an SDC command and aborts the fit with
    Read_sdc failed (it happened: `function of the profile's ratio...` at line 55).
    """
    problems = []
    inside = False
    seen = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.startswith(SDC_PROFILE_BEGIN):
            inside = seen = True
            continue
        if line.startswith(SDC_PROFILE_END):
            inside = False
            continue
        stripped = line.lstrip()
        if inside and stripped and not stripped.startswith("#"):
            problems.append(f"{label}:{n} is inside the computed block but is not a comment: "
                            f"{stripped[:60]!r}")
    if not seen:
        problems.append(f"{label} has no '{SDC_PROFILE_BEGIN}' block")
    return problems


# ---------------------------------------------------------------------------------------
# A small CLI for the evidence steps (build_profile.py is the user-facing one)
# ---------------------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="PLL/SDC generator (see build_profile.py)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("pll", help="generate one PLL into DIR/rtl (cached)")
    g.add_argument("dir", type=Path)
    g.add_argument("--clk-sys-hz", type=int, required=True)
    g.add_argument("--phase-ps", type=int, required=True)
    p = sub.add_parser("phase", help="print the derived SDRAM pin-clock phase for clk_sys frequencies")
    p.add_argument("clk_sys_mhz", nargs="+")
    args = ap.parse_args(argv)
    if args.cmd == "pll":
        rb = generate_pll(PllRequest(args.clk_sys_hz, args.phase_ps), args.dir / "rtl",
                          log=lambda msg: print(msg, file=sys.stderr))
        print(json.dumps(rb, indent=2, sort_keys=True))
        return 0
    if args.cmd == "phase":
        for text in args.clk_sys_mhz:
            d = derive_sdram_phase(hz_from_mhz_arg(text))
            print(f"{text:>8} MHz: phase {d['phase_ps']} ps, worst {d['worst_ns']:+.3f} ns "
                  f"({d['worst_group']} @ {d['worst_corner']}){' CLAMPED' if d['clamped'] else ''}")
        return 0
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except GenerationError as exc:
        print(f"profile_gen: {exc}", file=sys.stderr)
        raise SystemExit(1)
