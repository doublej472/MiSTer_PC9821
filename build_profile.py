#!/usr/bin/env python3
"""Configure the z486 MiSTer Quartus build: clocks, PLL, constraints, compile-time knobs.

A BUILD CONFIGURATION is one value with these fields, and this script is the ONE place that
decides it:

  clk_sys_hz          the core clock (PLL output 0) and z486_mister.sv's CLOCK_RATE_HZ. The SDRAM
                      controller and its PHY run on it too: there is no separate SDRAM clock (the
                      split-clock configuration - sdram_hz, sdram_sync, --sdram-mhz,
                      --no-sdram-sync - was removed)
  sdram_phase_ps      output 1's phase (the SDRAM_CLK pin clock, clk_sys's frequency). DERIVED by
                      default from the SDC's SDRAM I/O model for clk_sys
                      (tools/profile_gen.py, derive_sdram_phase); an explicit value overrides
  trace_en            TRACE_EN (the instruction trace ring)
  perf_log_en         PERF_LOG_EN (the serial console's performance-log telemetry)
  io_latency_profile  IO_LATENCY_PROFILE (0 = min bus, 1/2 = the faithful class table)
  mpu_en              MPU_EN, and with it CONF_STR_HEADER (the UART/MIDI OSD declaration)
  cdrom_en            CDROM_EN, and with it CONF_STR_CD + HPS_VDNUM (the CD-ROM's OSD
                      slot 4 and its Eject on status[11]); ON in every preset
                      since 2026-10-10, --no-cdrom the opt-out
  cdrom_audio_en      CDROM_AUDIO_EN: the CD drive's CD-DA player (needs cdrom_en; --no-cdrom
                      drops it unless --cdrom-audio asks for it, which is then refused)
  cdrom_log_en        CDROM_LOG_EN: the CD drive's command log on the debug UART (a debug instrument;
                      needs cdrom_en, and is refused with trace_en or perf_log_en, which share that
                      UART arm)
  dbg                 the DEBUG-UART INSTRUMENT FRAMEWORK, every part off in every preset (see the
                      "debug instruments" block below): cpu (the sampler), snoop LO:HI (the
                      memory window), gdc (the display log), the trace's trigger (trig, trig2,
                      arm_s, post) and sample_ms; the CD log is cdrom_log_en (--dbg-cd). All are
                      compile-time parameters; nothing is built unless asked for
  sdram_phase_dyn     SDRAM_PHASE_DYN: the run-time SDRAM_CLK phase instrument, a MEASUREMENT build
                      (--dbg-sdram-phase; off in every preset): the main PLL generated with its
                      dynamic-phase-shift ports in use and a guest stepper at 0x5FF0/0x5FF2
                      (src/pc9821/core/pc9821_sdram_phase_ctl.sv, tools/hwprobe/sdshmoo). Refused with
                      the DDIO SDRAM_CLK (clk_sys >= 100 MHz), whose clock is not PLL output 1
  dbg_sdram_cl2       SDRAM_DBG_CL = 2: a MEASUREMENT build that keeps CL2 and the phase-shifted
                      SDRAM_CLK (PLL output 1) at any clock, including >= 100 MHz where the derived
                      structure is CL3 through the DDIO cell (--dbg-sdram-cl2; off in every preset)
  dbg_sdram_trcd      SDRAM_DBG_TRCD_TRP: tRCD/tRP forced to N cycles (--dbg-sdram-trcd-cycles N;
                      0 = derived from clk_sys, every preset). With dbg_sdram_cl2 these are the
                      100 MHz CL2 test point that separates a tRCD/tRP cause from an I/O window one
  alsa_en             the framework's HPS (Linux) audio input; off = VERILOG_MACRO MISTER_DISABLE_ALSA
  vga_dbl_en          VIDEO_DBL_EN: the analog line doubler (24.8 -> 49.7 kHz, OSD "Analog video")
  sdram_dq_ddio       SDRAM_DQ_DDIO: the SDRAM read capture as an instantiated IOE input DDIO cell
                      (on in every preset); off = a fabric register the fitter packs there, which
                      crashes Quartus 17.0.2's physical synthesis on some netlists (DTM, io_ibuf)
  sdram_out_ddio      SDRAM_OUT_DDIO: every SDRAM output and DQ output-enable register as an
                      instantiated IOE cell (on in every preset); off = fabric registers the fitter
                      packs there, which crashes the same physical synthesis (DTM, io_obuf)
  hdmi_rclk           the framework's HDMI scaler clock (pll_hdmi) on a REGIONAL clock network
                      instead of the fitter's choice: one fit-side GLOBAL_SIGNAL assignment that
                      keeps sys/ascal.vhd's output stage and the HDMI OSD in one quadrant
  hdmi_rclk_q2        with hdmi_rclk: that quadrant is the bottom-right one beside the HDMI pins
                      (its clock control block CLKCTRL_R29), not the fitter's choice
  fit_technique       the qsf's OPTIMIZATION_TECHNIQUE
  qsf_set             further fitter/synthesis qsf assignments, NAME -> VALUE: each replaces the
                      SPEED stack's row of that name (the value @default drops the row, so
                      Quartus's own default applies) or is appended to the managed block. Every
                      name/value pair is checked by Quartus itself (quartus_sh's
                      set_global_assignment, in the container) when the configuration is applied

The five named PROFILES below are presets of that value. Any field of a preset can be
overridden on the command line or from a profile file (JSON, or TOML), and --custom starts
from base's values under the name 'custom'. Applying a configuration:

  * rewrites the top level's localparams, every one top_localparams() lists: CLOCK_RATE_HZ,
    TRACE_EN, PERF_LOG_EN, IO_LATENCY_PROFILE, MPU_EN, CONF_STR_HEADER, SDRAM_CLK_DDIO,
    SDRAM_DQ_DDIO, SDRAM_OUT_DDIO, SDRAM_PHASE_DYN, SDRAM_DBG_CL, SDRAM_DBG_TRCD_TRP, CDROM_EN,
    CONF_STR_CD, HPS_VDNUM, CDROM_AUDIO_EN, CDROM_LOG_EN, VIDEO_DBL_EN, CONF_STR_VIDEO and every
    DBG_* instrument parameter;
  * rewrites the qsf's managed block: the production SPEED fit stack with the configured
    technique, the framework feature macros (MISTER_DISABLE_ALSA for a feature that is off;
    MISTER_DISABLE_YC is always set - the composite/S-Video encoder is TV-only and the TV converter
    was removed), and the configuration itself as a machine-readable '# Active config:' JSON
    record (the qsf is hashed into every fit's attribution, so the record travels with it);
  * GENERATES the main PLL into rtl/ (qmegawiz in the Quartus container, cached under
    .build/pll-cache/, read back and verified) and the constraints into z486_mister.sdc
    (tools/profile/z486_mister.sdc.in with its computed block for the configured clock). Both
    outputs are git-ignored; the templates are the source.

    ./build_profile.py base                       # 90 MHz clk_sys, SDRAM on clk_sys - the default, shipping build
    ./build_profile.py trace                      # base + trace ring + perf log, AREA fit (debug)
    ./build_profile.py iofaithful                 # base + the FAITHFUL I/O class table
    ./build_profile.py mediumoc                   # 100 MHz clk_sys and SDRAM (past timing closure)
    ./build_profile.py heavyoc                    # 120 MHz clk_sys and SDRAM (at the SDRAM's limit)
    ./build_profile.py base --trace
    ./build_profile.py --custom --clk-sys-mhz 90  # the SDRAM follows clk_sys
    ./build_profile.py --profile-file sweep.toml  # every field above, plus 'preset'/'name'
    ./build_profile.py base --sdram-phase-ps 8000 # pin the phase instead of deriving it
    ./build_profile.py base --qsf-set PHYSICAL_SYNTHESIS_EFFORT=NORMAL --qsf-set 'OPTIMIZATION_MODE=AGGRESSIVE AREA'
    ./build_profile.py --check                    # top level, qsf, PLL and SDC all agree
    ./build_profile.py --selftest                 # --check must catch planted disagreements
    ./build_profile.py --pll-into DIR             # generate DIR's active PLL + SDC into DIR
    ./build_profile.py --print-config [args]      # the resolved configuration as JSON
    ./build_profile.py --quartus-check [args]     # Quartus's verdict on each qsf_set override
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT = "z486_mister"
PROJECT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_DIR / "tools"))
import profile_gen as pg  # noqa: E402

QSF_NAME = "z486_mister.qsf"
TOP_NAME = "z486_mister.sv"
SDC_NAME = "z486_mister.sdc"

PROFILE_BLOCK_BEGIN = "# BEGIN build_profile.py settings"
PROFILE_BLOCK_END = "# END build_profile.py settings"
# The SDRAM DQ output enable of the cell build (sdram_out_ddio) stays a FABRIC register: no I/O-cell
# OE register at all. sys/sys.tcl (sourced after the managed block) and the qsf's own pin section set
# FAST_OUTPUT_ENABLE_REGISTER ON for SDRAM_DQ[*], and in Quartus the LAST assignment to a target
# wins, so this line is kept as the qsf's final line (the crash lab's override position). Packed -
# even one register per pin - the OE registers still hit the DTM io_obuf crash (dob-lane2 seed 11);
# driven by a cyclonev_ddio_oe atom the build was black on hardware.
OE_FABRIC_COMMENT = ("# build_profile.py (sdram_out_ddio): the SDRAM DQ output enable is a fabric register "
                     "- keep this the LAST FAST_OUTPUT_ENABLE_REGISTER line")
OE_FABRIC_LINE = "set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER OFF -to SDRAM_DQ[*]"
OE_ASSIGN_RE = re.compile(r"^\s*set_instance_assignment\s+-name\s+FAST_OUTPUT_ENABLE_REGISTER\s+(\w+)\s+-to\s+SDRAM_DQ\[\*\]\s*$")
CONFIG_RECORD_PREFIX = "# Active config: "

FIT_TECHNIQUES = ("SPEED", "AREA", "BALANCED")
# clk_sys IS the SDRAM controller's clock, so its range is the controller's: sdram.v derives its
# timing up to 133 MHz, and the board's SDRAM part has a hard limit at about 120 MHz, which
# heavyoc sits at.
CLK_SYS_MIN_HZ = 25_000_000
# The PC-98 dot rate, 400/19 MHz (pc9821_dot_ce): clk_sys must exceed it (the dot enable's guard).
PIXEL_HZ = 21_052_632
CLK_SYS_MAX_HZ = 133_000_000
SDRAM_PART_LIMIT_HZ = 120_000_000
# The split-clock configuration's fields, removed on 2026-10-09.
# The OSD's "CD audio volume" field, which CONF_STR_CD carries in a build with the CD drive's
# audio player. Position 0 is 0 dB, the unity level shipped before the field existed (the owner's
# choice, 2026-10-31: the clipping that had prompted a -6 dB default was a wrong-rail clamp in the
# output FIR, tb_pc9821_audio_out_sat, not a level problem); NP2kai's default CD-DA level,
# davolume 128/255 = -6 dB, stays a step. The list descends in 2 dB steps and ends at Off (the
# owner's order, 2026-10-31). pc9821_osd maps each position to pc9821_audio_volume's
# gain code, and tools/check_osd_contract.py holds the two together.
CD_VOLUME_FIELD = "O[66:64],CD audio volume,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off;"
RETIRED_FIELDS = ("sdram_hz", "sdram_mhz", "sdram_sync")
RETIRED_LOCALPARAMS = ("SDRAM_RATE_HZ", "SDRAM_SYNC")
# SDRAM_DQ_DDIO's path from the top level to the cell it selects (sdram.v DQ_IN_DDIO): each file
# must carry its hop, or the controller builds its default (the packed register) whatever the
# record says, and the SDC then names a register the netlist does not have. sdram.v's DDIO arm must
# instantiate the cell under the name the SDC's capture collection uses (pg.DQ_DDIO_INSTANCE).
DQ_DDIO_WIRING = (
    (TOP_NAME, ".DQ_IN_DDIO(SDRAM_DQ_DDIO)"),
    ("src/memory/split_sdram_backend.sv", ".DQ_IN_DDIO(DQ_IN_DDIO)"),
    ("src/memory/sdram_sync_bridge.sv", ".DQ_IN_DDIO(DQ_IN_DDIO)"),
)
SDRAM_V = "src/memory/sdram.v"
# The timing-table overrides' path to sdram.v (DBG_CL / DBG_TRCD_TRP): the same three hops.
DBG_TIMING_WIRING = (
    (TOP_NAME, ".DBG_CL(SDRAM_DBG_CL)"), (TOP_NAME, ".DBG_TRCD_TRP(SDRAM_DBG_TRCD_TRP)"),
    ("src/memory/split_sdram_backend.sv", ".DBG_CL(DBG_CL)"),
    ("src/memory/split_sdram_backend.sv", ".DBG_TRCD_TRP(DBG_TRCD_TRP)"),
    ("src/memory/sdram_sync_bridge.sv", ".DBG_CL(DBG_CL)"),
    ("src/memory/sdram_sync_bridge.sv", ".DBG_TRCD_TRP(DBG_TRCD_TRP)"),
)


# sdram.v's timing table and its elaboration checks, at the grade z486_mister.sv builds (-7,
# FAST_GRADE 0): a model, so validate() can refuse a clock or a measurement override the RTL
# would refuse (Quartus may not stop on an `initial $error`), and so --selftest can sweep the
# whole legal clock range. --selftest also elaborates sdram.v with Verilator at every MHz of that
# range (and every override at the preset clocks) and requires the RTL's values and its fired
# checks to equal this model's, so the model cannot drift from the file it describes.
SDRAM_NS_7 = {"rcd": 21, "rp": 21, "rc": 68, "wr": 15, "ras": 42, "wr_ds": 14}


def sdram_table(clk_hz: int, dbg_cl: int = 0, dbg_trcd: int = 0) -> dict:
    """sdram.v's localparams at FREQ = clk_hz, FAST_GRADE 0 (its ns_to_cycles, CAS_I, EXIT_TRIM)."""
    def cyc(ns: int) -> int:
        return max((ns * ((clk_hz + 999) // 1000) + 999_999) // 1_000_000, 1)
    ns = SDRAM_NS_7
    t = {"CAS_I": dbg_cl or (2 if clk_hz < 100_000_000 else 3),
         "T_RCD_I": dbg_trcd or cyc(ns["rcd"]), "T_RP_I": dbg_trcd or cyc(ns["rp"]),
         "T_RC_I": cyc(ns["rc"]), "T_WR_I": cyc(ns["wr"]), "T_RAS_I": cyc(ns["ras"]),
         "T_RAS_WR_I": cyc(ns["ras"] - ns["wr_ds"])}
    t["T_DAL_I"] = t["T_WR_I"] + t["T_RP_I"]
    t["EXIT_TRIM"] = int(t["T_DAL_I"] >= 3 and t["T_RCD_I"] + t["T_DAL_I"] + 1 >= t["T_RC_I"])
    return t


def sdram_table_problems(clk_hz: int, dbg_cl: int = 0, dbg_trcd: int = 0) -> dict[str, str]:
    """The sdram.v elaboration checks (generate-block name -> what it guards) this table fires."""
    t = sdram_table(clk_hz, dbg_cl, dbg_trcd)
    fired = {}
    if clk_hz > 133_000_000:
        fired["gen_freq_check"] = "the timing table is characterized only up to 133 MHz"
    if t["T_RAS_WR_I"] > t["T_RCD_I"] + 1 or t["T_RAS_I"] > t["T_RCD_I"] + 4:
        fired["gen_tras_check"] = (f"tRAS ({t['T_RAS_I']} clocks) is not met by a two-half write or a "
                                   f"four-half read at tRCD {t['T_RCD_I']}")
    if t["T_RCD_I"] + t["T_DAL_I"] + 2 - t["EXIT_TRIM"] < t["T_RC_I"]:
        fired["gen_trc_check"] = (f"a store's next ACT, tRCD + tDAL + {2 - t['EXIT_TRIM']} = "
                                  f"{t['T_RCD_I'] + t['T_DAL_I'] + 2 - t['EXIT_TRIM']} clocks after its "
                                  f"own, is short of tRC ({t['T_RC_I']})")
    if t["T_RP_I"] > t["CAS_I"] + 2:
        fired["gen_rp_check"] = (f"tRP {t['T_RP_I']} exceeds CAS {t['CAS_I']} + 2 clocks, which a "
                                 "read's exit assumes")
    return fired


def sdram_rtl_table(clk_hz: int, dbg_cl: int, dbg_trcd: int, scratch: Path) -> tuple[dict, set]:
    """sdram.v elaborated by Verilator (--json-only) at FREQ = clk_hz, FAST_GRADE 0: the localparams
    sdram_table models and the names of the elaboration-check generate blocks that exist."""
    with tempfile.TemporaryDirectory(dir=scratch) as mdir:
        run = subprocess.run(
            ["verilator", "--json-only", "-Wno-fatal", "-Wno-lint", "-Wno-style",
             f"-GFREQ={clk_hz}", "-GFAST_GRADE=0", "-GADQM=1", f"-GDBG_CL={dbg_cl}",
             f"-GDBG_TRCD_TRP={dbg_trcd}", "--top-module", "sdram", "--Mdir", mdir,
             str(PROJECT_DIR / SDRAM_V)], capture_output=True, text=True)
        if run.returncode:
            raise RuntimeError(f"verilator --json-only failed: {run.stderr.strip()[-400:]}")
        tree = json.loads((Path(mdir) / "Vsdram.tree.json").read_text())
    want = set(sdram_table(clk_hz))
    vals, checks, todo = {}, set(), [tree]
    while todo:
        node = todo.pop()
        if isinstance(node, list):
            todo.extend(node)
            continue
        if not isinstance(node, dict):
            continue
        if (node.get("type") == "VAR" and node.get("name") in want and node.get("valuep")
                and node["valuep"][0].get("type") == "CONST"):
            vals[node["name"]] = int(node["valuep"][0]["name"].split("h")[-1], 16)
        if node.get("type") == "GENBLOCK" and re.fullmatch(r"gen_\w+_check", node.get("name", "")):
            checks.add(node["name"])
        todo.extend(v for v in node.values() if isinstance(v, (list, dict)))
    return vals, checks


def sdram_table_selftest() -> int:
    """The derived table builds at every MHz of the legal clock range, and the model equals the RTL."""
    failures = 0
    mhz = list(range(-(-CLK_SYS_MIN_HZ // 10**6), CLK_SYS_MAX_HZ // 10**6 + 1))
    bad = {m: sorted(sdram_table_problems(m * 10**6)) for m in mhz if sdram_table_problems(m * 10**6)}
    if bad:
        print(f"SELFTEST FAIL: sdram.v's derived timing table fails its own checks at {bad} (MHz)")
        failures += 1
    else:
        print(f"selftest: sdram.v's derived table passes its checks at every MHz {mhz[0]}..{mhz[-1]}")
    if shutil.which("verilator") is None:
        print("SELFTEST FAIL: verilator is not on PATH, so the sdram.v table model is unchecked")
        return failures + 1
    points = [(m * 10**6, 0, 0) for m in mhz]
    points += [(p.clk_sys_hz, cl, n) for p in {c.clk_sys_hz: c for c in PROFILES.values()}.values()
               for cl in (0, 2) for n in range(16)]
    scratch = Path(tempfile.mkdtemp(prefix="build-profile-sdram-"))
    try:
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            rtl = list(pool.map(lambda pt: sdram_rtl_table(*pt, scratch), points))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    wrong = []
    for (hz, cl, n), (vals, checks) in zip(points, rtl):
        model = sdram_table(hz, cl, n)
        if vals != model or checks != set(sdram_table_problems(hz, cl, n)):
            wrong.append(f"{hz / 1e6:g} MHz CL{cl or '-'} tRCD{n or '-'}: RTL {vals} {sorted(checks)}, "
                         f"model {model} {sorted(sdram_table_problems(hz, cl, n))}")
    if wrong:
        print("SELFTEST FAIL: sdram.v's elaborated table differs from build_profile's model:\n  "
              + "\n  ".join(wrong[:8]))
        failures += 1
    else:
        print(f"selftest: sdram.v elaborated at {len(points)} points (every MHz, every tRCD/tRP "
              "override at the preset clocks) equals the model, values and fired checks")
    return failures
# SDRAM_OUT_DDIO's path to sdram.v OUT_DDIO, the same three hops; sdram.v's g_out_ddio arm must
# instantiate the cells under the names the SDC's output-cell guard counts (pg.OUT_DDIO_INSTANCES).
OUT_DDIO_WIRING = (
    (TOP_NAME, ".OUT_DDIO(SDRAM_OUT_DDIO)"),
    ("src/memory/split_sdram_backend.sv", ".OUT_DDIO(OUT_DDIO)"),
    ("src/memory/sdram_sync_bridge.sv", ".OUT_DDIO(OUT_DDIO)"),
)


@dataclasses.dataclass(frozen=True)
class Config:
    name: str
    description: str
    # The core clock, which the SDRAM controller and its PHY run on as well (one clock domain).
    clk_sys_hz: int
    # None = derived from the I/O model for clk_sys (the default); an int pins it.
    sdram_phase_ps: int | None = None
    # Rewrites TRACE_EN. False for every shipped profile: the shipped bitstream must not carry
    # the trace's ring or its logic; True only for 'trace'.
    trace_en: bool = False
    # Rewrites PERF_LOG_EN: the serial console's watchdog/PRF/GFX telemetry. 'trace' only.
    perf_log_en: bool = False
    # Rewrites IO_LATENCY_PROFILE, which pc9821_system forwards into pc9821_iobus. 0 is the min
    # profile (the shipped fast bus); 1/2 the faithful bus. The unselected table const-folds.
    io_latency_profile: int = 0
    # Rewrites MPU_EN (and CONF_STR_HEADER, which follows it). ON in every preset except 'trace'
    # (MIDI by default once it fits). Measured on 11a1e82c, seeds 2-5: base
    # + MPU + ALSA 4,105 LABs mean / clk_sys -4.85 ns vs base 4,105 / -5.09; base + MPU alone
    # 4,140 / -5.10 (LAB packing noise is ~40 per variant). --no-mpu is the opt-out.
    mpu_en: bool = True
    # (`ide_disk2_en`, the second IDE hard disk, was RETIRED on 2026-10-08 with the disk itself:
    # a record that still carries the key parses, the key is ignored, and `--check` then reports
    # the block as not the one its record renders until the configuration is re-applied.)
    # Rewrites CDROM_EN, and with it the CD's OSD entries (CONF_STR_CD) and hps_io's slot
    # count (HPS_VDNUM): the CD-ROM's "S4" slot and its ATAPI drive (pc9821_atapi, bank 1's
    # master; the hard disk is bank 0's master with or without it). ON in every preset;
    # --no-cdrom is the opt-out.
    cdrom_en: bool = True
    # Rewrites CDROM_AUDIO_EN: the CD drive's CD-DA player and the cdda ring behind it. It only
    # means something with cdrom_en (the line is written as cdrom_en AND this), so the default
    # True gives a full drive whenever the drive is on, and --no-cdrom-audio a data-only one.
    cdrom_audio_en: bool = True
    # Rewrites CDROM_LOG_EN: a DEBUG INSTRUMENT, the drive's conversation as binary records on the
    # debug UART (pc9821_atapi LOG_EN). Off in every preset; the
    # line is written as cdrom_en AND this AND NOT perf_log_en (the telemetry owns that source).
    cdrom_log_en: bool = False
    # The framework feature sys/sys_top.v compiles out under a VERILOG_MACRO. ALSA (the HPS
    # Linux audio path: alsa.sv + its DDR reader + the audio_out mix input) is ON with the MIDI card
    # (it fits), so MidiLink's software synths are
    # audible; it was off from 2026-10-08 (docs/trade-candidates.md T31) when the design had no
    # room. Measured in a fit: alsa -265 ALMs, plus its sys_top glue. The composite/S-Video
    # encoder (yc_out) is TV-only and is ALWAYS off: MISTER_DISABLE_YC is set in every build (the
    # 15 kHz TV converter that fed it was removed).
    alsa_en: bool = True
    # Rewrites VIDEO_DBL_EN (and CONF_STR_VIDEO, the OSD "Analog video" field that turns it on at run
    # time). The line doubler (pc9821_line_doubler: 6 M10K) puts a 49.7 kHz, every-line-twice picture
    # on the analog port for VGA monitors that cannot sync to the machine's 24.8 kHz. It needs clk_sys
    # above 2 x 21.0526 MHz (validate()).
    vga_dbl_en: bool = True
    # Rewrites SDRAM_DQ_DDIO (sdram.v DQ_IN_DDIO) and the SDC's DQ capture collection. On: the DQ
    # read-capture register is the rising-edge half of an INSTANTIATED IOE input DDIO cell
    # (altddio_in). Off: a fabric register the fitter packs into that cell (FAST_INPUT_REGISTER).
    # The same register in the same cell on the same cycle; but the packed form crashes Quartus
    # 17.0.2 at the start of physical synthesis on some netlists (`Internal Error: Sub-system: DTM,
    # File: /quartus/ddb/dtm/dtm_node.cpp, Line: 772`, visit_atom_stratixv_style_io_ibuf), and which
    # seeds crash moves with unrelated netlist changes. Off stays selectable for A/Bs.
    sdram_dq_ddio: bool = True
    # Rewrites SDRAM_OUT_DDIO (sdram.v OUT_DDIO) and the SDC's output-cell exception. On: every SDRAM
    # output register (command, address, BA, DQM, DQ data) and the DQ output enable is an
    # in its pin's I/O cell without a packed fabric register: instantiated altddio_out cells (both
    # halves equal), and the DQ output enable one dont_merge FABRIC register per pin, never in the
    # I/O cell (OE_FABRIC_LINE; a cyclonev_ddio_oe there was black on hardware, a packed one per pin
    # still crashed the fitter), loaded with the
    # FSM's next value. Off: the FSM's fabric registers, packed into those cells by the qsf's
    # FAST_OUTPUT_REGISTER / FAST_OUTPUT_ENABLE_REGISTER. The same register on the same clk edge;
    # but the packed form crashes Quartus 17.0.2 at the start of physical synthesis on some netlists
    # (`Internal Error: Sub-system: DTM, File: /quartus/ddb/dtm/dtm_node.cpp, Line: 772`,
    # visit_atom_stratixv_style_io_obuf). Off stays selectable for A/Bs.
    sdram_out_ddio: bool = True
    # The framework's pll_hdmi clock (sys/ascal.vhd's output stage, the HDMI OSD) on a REGIONAL
    # clock network (HDMI_RCLK_LINE). A fit-side PLACEMENT knob, not a feature: no RTL and no
    # constant changes. See HDMI_RCLK_LINE for why; recorded in the '# Active config' JSON only
    # when set.
    hdmi_rclk: bool = False
    # With hdmi_rclk: the regional clock's control block is CLKCTRL_R29, whose region is the
    # bottom-right quadrant (HDMI_RCLK_Q2_LINE), not the fitter's pick.
    hdmi_rclk_q2: bool = False
    # Rewrites SDRAM_PHASE_DYN and generates the main PLL with its dynamic-phase-shift ports in use
    # (tools/profile_gen.py PllRequest.dps): the run-time SDRAM_CLK phase instrument, a measurement
    # build for the SDRAM window shmoo. OFF in every preset; recorded in the '# Active config' JSON
    # only when set, so every record written before it existed means exactly what it meant.
    sdram_phase_dyn: bool = False
    # Rewrite SDRAM_DBG_CL / SDRAM_DBG_TRCD_TRP (sdram.v DBG_CL / DBG_TRCD_TRP): MEASUREMENT
    # overrides of the controller's timing table, off/0 in every preset and recorded only when set.
    # dbg_sdram_cl2 also keeps the phase-shifted SDRAM_CLK structure (sdram_clk_ddio False) and the
    # SDC's CL2 tAC at any clock, so a 100 MHz CL2 build is the pre-cutover structure.
    dbg_sdram_cl2: bool = False
    dbg_sdram_trcd: int = 0
    # The managed qsf block's OPTIMIZATION_TECHNIQUE. AREA in every preset since 2026-10-12
    # (docs/trade-candidates.md T40): on the storage-pass tree, seeds 2-7 per side, AREA placed
    # 38,947 ALMs / 4,170 LABs mean vs SPEED's 39,337 / 4,181, clk_sys slack mean -7.23 /
    # worst -7.44 ns, and its seed-2 RBF passed the full hardware regression on two MiSTers. The
    # design is LAB-bound, so the technique that frees LABs is the default. SPEED stays
    # selectable (--fit-technique SPEED) for A/Bs.
    fit_technique: str = "AREA"
    # Further qsf assignments over the SPEED stack, as sorted (NAME, VALUE) pairs (values
    # unquoted; render_qsf_block quotes a multi-word one). Empty for every preset unless its
    # entry says otherwise; recorded in the '# Active config' JSON only when non-empty, so a
    # record written before the field existed means exactly what it meant then.
    qsf_set: tuple[tuple[str, str], ...] = ()
    # The debug-UART instrument framework (pc9821_dbg_cpu / pc9821_gdc_log / pc9821_dbg_mux;
    # docs/debug-instruments.md, docs/mister-testing.md "The debug UART"), as sorted (KEY, VALUE)
    # pairs of normalize_dbg's keys. EMPTY for every preset: each part is a compile-time parameter
    # that builds nothing when absent. Recorded in the '# Active config' JSON only when non-empty.
    dbg: tuple[tuple[str, object], ...] = ()
    # The preset this configuration started from (None for a preset itself).
    preset: str | None = None

    def __post_init__(self) -> None:
        # One canonical form (sorted, unquoted), so equal overrides are equal configurations.
        object.__setattr__(self, "qsf_set", normalize_qsf_set(self.qsf_set))
        object.__setattr__(self, "dbg", normalize_dbg(self.dbg))

    @property
    def dbg_params(self) -> dict:
        """The debug framework's localparam values (see dbg_localparams)."""
        return dbg_param_values(dict(self.dbg))

    @property
    def dbg_active(self) -> bool:
        """Any instrument that takes the UART arm besides the CD log."""
        return bool(self.dbg)

    @property
    def conf_str_header(self) -> str:
        """The OSD header's first element, for z486_mister.sv's CONF_STR_HEADER.

        It follows mpu_en rather than being a second knob, so there is ONE decision point. It
        cannot be built in the RTL from MPU_EN: a string ternary is zero-padded to the longer
        branch's width on the high side, so the false branch would carry leading NULs and move
        the base bitstream (z486_mister.sv's CONF_STR_HEADER comment has the measurement).
        """
        return "PC9821;UART115200(Turbo 115200),MIDI;" if self.mpu_en else "PC9821;;"

    @property
    def conf_str_cd(self) -> str:
        """z486_mister.sv's CONF_STR_CD: the HDD's Eject, plus the CD-ROM's Mount and Eject.

        The OSD lists each drive's Mount directly followed by its Eject, HDD, CD-ROM, FDD1,
        FDD2, so the CD's pair sits between "S0,IMGHDIVHD,Mount HDD;" and "S1,...,Mount FDD1;". A
        profile-rewritten LINE for the same reason as conf_str_header: a string ternary on
        CDROM_EN would be NUL-padded on the high side. Never empty (an empty Verilog string is a
        NUL byte), so the HDD's always-present Eject leads it. status[11] was only ever a T
        trigger (the removed second disk's Eject), so reusing it cannot meet a saved option value.
        With the CD drive's audio player (cdrom_audio_en) the line also carries the "CD audio
        volume" field (status[66:64], decoded by pc9821_osd; bits no field has ever used), so a
        build without CD-DA does not offer a control with nothing to act on.
        """
        line = "T[8],Eject HDD;"
        if self.cdrom_en:
            line += "S4,ISOPCD,Mount CD-ROM;T[11],Eject CD-ROM;"
            if self.cdrom_audio_en:
                line += CD_VOLUME_FIELD
        return line

    @property
    def conf_str_video(self) -> str:
        """z486_mister.sv's CONF_STR_VIDEO: the analog converters' fields.

        "Analog video" (status[81:80]) lists Native first and then the BUILT converter in the order
        z486_mister.sv's VIDEO_SEL_* constants number it (the doubler); the doubler adds "Scanlines"
        (status[83:82]). A rewritten line for the same reason as CONF_STR_CD. It ENDS WITH the
        separator that closes the video section, so it is never empty (an empty Verilog string is
        a NUL byte), and a build with no converter on the analog port gets that one separator
        rather than a filler separator beside it.
        """
        modes = ["Doubled 49kHz"] if self.vga_dbl_en else []
        line = ""
        if modes:
            line += "O[81:80],Analog video,Native 24kHz," + ",".join(modes) + ";"
        if self.vga_dbl_en:
            line += "O[83:82],Scanlines (doubled),None,25%,50%,75%;"
        return line + "-;"

    @property
    def hps_vdnum(self) -> int:
        """hps_io's VDNUM: 0 HDD, 1-2 FDD; with the CD, 4 CD and slot 3 an unused, tied-off index."""
        return 5 if self.cdrom_en else 3

    @property
    def sdram_clk_ddio(self) -> bool:
        """SDRAM_CLK through a clk_sys output DDIO (clk_sys >= 100 MHz, the CL3 builds); derived
        in one place (pg.sdram_clk_ddio) and written to SDRAM_CLK_DDIO and the SDC from it."""
        return pg.sdram_clk_ddio(self.clk_sys_hz) and not self.dbg_sdram_cl2

    def phase(self) -> tuple[int, str]:
        if self.sdram_phase_ps is not None:
            return self.sdram_phase_ps, "override"
        return pg.derive_sdram_phase(self.clk_sys_hz)["phase_ps"], "derived"

    def pll_request(self) -> pg.PllRequest:
        return pg.PllRequest(self.clk_sys_hz, self.phase()[0], dps=self.sdram_phase_dyn)

    def vpll_request(self) -> pg.VpllRequest:
        """The video PLL: FRACTIONAL and RECONFIGURABLE in every build, GENERATED at its fastest
        run-time setting, the 31 kHz clock (50.336 MHz), so the fitter times the video domain at
        19.87 ns (tools/profile_gen.py, the video PLL section). pc9821_vpll_ctl moves it to the
        24 kHz clock after lock and back on 0x09A8 bit 0. The TV converter is gone, so the
        TV-rate proxy generation is never asked for."""
        return pg.VpllRequest(False)

    def record(self) -> dict:
        """The machine-readable configuration: every field a fit depends on, phase resolved."""
        phase, source = self.phase()
        rec = {
            "name": self.name,
            "preset": self.preset,
            "clk_sys_hz": self.clk_sys_hz,
            "sdram_phase_ps": phase,
            "sdram_phase_source": source,
            "trace_en": self.trace_en,
            "perf_log_en": self.perf_log_en,
            "io_latency_profile": self.io_latency_profile,
            "mpu_en": self.mpu_en,
            "cdrom_en": self.cdrom_en,
            "cdrom_audio_en": self.cdrom_audio_en,
            "cdrom_log_en": self.cdrom_log_en,
            "alsa_en": self.alsa_en,
            "vga_dbl_en": self.vga_dbl_en,
            "sdram_dq_ddio": self.sdram_dq_ddio,
            "sdram_out_ddio": self.sdram_out_ddio,
            "fit_technique": self.fit_technique,
        }
        if self.hdmi_rclk:
            rec["hdmi_rclk"] = True
        if self.hdmi_rclk_q2:
            rec["hdmi_rclk_q2"] = True
        if self.sdram_phase_dyn:
            rec["sdram_phase_dyn"] = True
        if self.dbg_sdram_cl2:
            rec["dbg_sdram_cl2"] = True
        if self.dbg_sdram_trcd:
            rec["dbg_sdram_trcd"] = self.dbg_sdram_trcd
        if self.qsf_set:
            rec["qsf_set"] = dict(self.qsf_set)
        if self.dbg:
            rec["dbg"] = dict(self.dbg)
        return rec

    def record_json(self) -> str:
        return json.dumps(self.record(), sort_keys=True, separators=(",", ":"))

    def knobs(self) -> tuple:
        """Everything that reaches the build, for comparing configurations."""
        return (self.clk_sys_hz, self.phase(), self.trace_en,
                self.perf_log_en, self.io_latency_profile, self.mpu_en, self.cdrom_en,
                self.cdrom_audio_en, self.cdrom_log_en, self.alsa_en, self.fit_technique,
                self.qsf_set, self.dbg, self.vga_dbl_en, self.hdmi_rclk, self.hdmi_rclk_q2,
                self.sdram_dq_ddio, self.sdram_out_ddio, self.sdram_phase_dyn,
                self.dbg_sdram_cl2, self.dbg_sdram_trcd)

    def validate(self) -> list[str]:
        problems = []
        if not re.fullmatch(r"\w+", self.name):
            problems.append(f"profile name {self.name!r} must be a single word (letters, digits, _)")
        if not CLK_SYS_MIN_HZ <= self.clk_sys_hz <= CLK_SYS_MAX_HZ:
            problems.append(f"clk_sys {self.clk_sys_hz:_} Hz is outside "
                            f"{CLK_SYS_MIN_HZ // 10**6}..{CLK_SYS_MAX_HZ // 10**6} MHz: it is also "
                            "the SDRAM controller's clock, and sdram.v's timing derivation tops out "
                            "at 133 MHz")
        if self.io_latency_profile not in (0, 1, 2):
            problems.append(f"io_latency_profile {self.io_latency_profile} is not 0, 1 or 2")
        if self.clk_sys_hz <= PIXEL_HZ:
            problems.append(f"clk_sys {self.clk_sys_hz:_} Hz cannot carry the {PIXEL_HZ:_} Hz dot "
                            "enable (pc9821_dot_ce); the analog converters run on the video PLL's "
                            "clock and no longer constrain clk_sys")
        if self.hdmi_rclk_q2 and not self.hdmi_rclk:
            problems.append("hdmi_rclk_q2 places pll_hdmi's REGIONAL clock control block; it needs "
                            "hdmi_rclk")
        if self.sdram_phase_dyn and self.sdram_clk_ddio:
            problems.append("sdram_phase_dyn shifts PLL output 1, but at clk_sys >= 100 MHz "
                            "SDRAM_CLK is clk_sys through an output DDIO cell (SDRAM_CLK_DDIO): "
                            "there is no phase to shift")
        if not 0 <= self.dbg_sdram_trcd <= 15:
            problems.append(f"dbg_sdram_trcd {self.dbg_sdram_trcd} is not 0 (derived) or 1..15 cycles")
        elif CLK_SYS_MIN_HZ <= self.clk_sys_hz <= CLK_SYS_MAX_HZ:
            for why in sdram_table_problems(self.clk_sys_hz, 2 if self.dbg_sdram_cl2 else 0,
                                            self.dbg_sdram_trcd).values():
                problems.append(f"sdram.v refuses this timing table at {self.clk_sys_hz:_} Hz"
                                + (f" with tRCD/tRP forced to {self.dbg_sdram_trcd}"
                                   if self.dbg_sdram_trcd else "") + f": {why}")
        if self.fit_technique not in FIT_TECHNIQUES:
            problems.append(f"fit_technique {self.fit_technique!r} is not one of {FIT_TECHNIQUES}")
        # The CD drive's two options are folded into CDROM_AUDIO_EN / CDROM_LOG_EN as ANDs (see
        # top_localparams), so a request the fold would drop is refused here, not built silently.
        if self.cdrom_audio_en and not self.cdrom_en:
            problems.append("cdrom_audio_en is the CD drive's CD-DA player; it needs cdrom_en")
        if self.cdrom_log_en and not self.cdrom_en:
            problems.append("cdrom_log_en logs the CD drive's commands; it needs cdrom_en")
        if self.cdrom_log_en and (self.trace_en or self.perf_log_en):
            problems.append("cdrom_log_en: the CD log shares the debug UART arm with the trace/"
                            f"telemetry (trace_en {self.trace_en}, perf_log_en {self.perf_log_en}), "
                            "whose bytes would cut a record in two (and perf_log_en owns that source, "
                            "so CDROM_LOG_EN would be written 0): build the CD log without them")
        problems += qsf_set_problems(self.qsf_set)
        problems += dbg_problems(self)
        if self.sdram_phase_ps is not None:
            period_ps = 1e12 / self.clk_sys_hz
            if not 0 < self.sdram_phase_ps < period_ps:
                problems.append(
                    f"sdram_phase_ps {self.sdram_phase_ps} is outside (0, {period_ps:.0f}) ps: the "
                    "SDC's I/O edge pairing (and its DQ setup-2 count) assume a phase inside one "
                    "clock period")
        return problems


# The production fit's aggressive SPEED stack, used by EVERY configuration (no seed is pinned
# here so the seed sweep can vary it); fit_technique replaces its OPTIMIZATION_TECHNIQUE row.
SPEED_FIT_ASSIGNMENTS: tuple[tuple[str, str], ...] = (
    ("OPTIMIZE_POWER_DURING_FITTING", "OFF"),
    ("FINAL_PLACEMENT_OPTIMIZATION", "ALWAYS"),
    ("FITTER_EFFORT", '"AUTO FIT"'),
    ("ENABLE_BENEFICIAL_SKEW_OPTIMIZATION", "ON"),
    ("OPTIMIZATION_MODE", '"HIGH PERFORMANCE EFFORT"'),
    ("ALLOW_POWER_UP_DONT_CARE", "ON"),
    ("QII_AUTO_PACKED_REGISTERS", '"SPARSE AUTO"'),
    ("ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION", "ON"),
    ("PHYSICAL_SYNTHESIS_COMBO_LOGIC", "ON"),
    ("PHYSICAL_SYNTHESIS_EFFORT", "EXTRA"),
    ("PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION", "ON"),
    ("PHYSICAL_SYNTHESIS_REGISTER_RETIMING", "ON"),
    ("OPTIMIZATION_TECHNIQUE", "SPEED"),
    ("MUX_RESTRUCTURE", "ON"),
    ("REMOVE_REDUNDANT_LOGIC_CELLS", "ON"),
    ("AUTO_DELAY_CHAINS_FOR_HIGH_FANOUT_INPUT_PINS", "ON"),
    ("PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA", "ON"),
    ("ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP", "ON"),
    ("SYNTH_GATED_CLOCK_CONVERSION", "ON"),
    # OFF since 2026-10-09: ON crashed Quartus 17.0.2 (DTM
    # dtm_node.cpp:772) on the CD, trace (AREA) and 80/100 split-clock netlists, and OFF reads
    # ~40 fewer LABs on base and the 80/80 build with clk_sys no worse, over 5-8 seeds a side.
    ("PRE_MAPPING_RESYNTHESIS", "OFF"),
    ("ROUTER_CLOCKING_TOPOLOGY_ANALYSIS", "ON"),
    ("ECO_OPTIMIZE_TIMING", "ON"),
    ("PERIPHERY_TO_CORE_PLACEMENT_AND_ROUTING_OPTIMIZATION", "ON"),
    ("PHYSICAL_SYNTHESIS_ASYNCHRONOUS_SIGNAL_PIPELINING", "ON"),
    ("ALM_REGISTER_PACKING_EFFORT", "LOW"),
    ("OPTIMIZE_POWER_DURING_SYNTHESIS", "OFF"),
    ("ROUTER_REGISTER_DUPLICATION", "ON"),
    ("FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION", "ALWAYS"),
)
CONTROLLED_ASSIGNMENTS = frozenset(name for name, _ in SPEED_FIT_ASSIGNMENTS)
FIT_TECHNIQUE_ASSIGNMENT = "OPTIMIZATION_TECHNIQUE"

# ---- the framework HDMI scaler clock's network (pll_hdmi on a REGIONAL clock) ----------------
# sys/ascal.vhd's output stage and the HDMI OSD run on pll_hdmi (148.5 MHz); their setup margin is
# thin framework logic whose outcome is placement-limited (docs/fitting.md, the pll_hdmi deploy gate).
# The fitter picks the clock's network per seed. On a GLOBAL net it is free to place the 3.3k
# registers anywhere, and in the bad draws it exiles them (to the top left of the die, or across
# the HPS edge, 2.8k-5.8k LAB sites for the p5-p95 box); on a REGIONAL net they stay in one
# quadrant (~600-900 sites). Over 304 archived fits the fitter's regional draws averaged
# +0.018 ns (106/111 at or above -0.35) and its global ones -0.226 (129/193), +0.258 ns
# within the 50 sweeps that drew both (2026-10-20). Forcing REGIONAL makes the
# choice instead of the draw. LogicLock regions would be the general form, but the project's
# Quartus 17.0.2 Lite strips them (Critical Warning 140003: "Current license file does not
# support LogicLock regions"); GLOBAL_SIGNAL is honoured. The node is the PLL output counter,
# the atom fit.rpt's clock-network table names.
PLL_HDMI_NODE = ("pll_hdmi:pll_hdmi|pll_hdmi_0002:pll_hdmi_inst|altera_pll:altera_pll_i|"
                 "altera_cyclonev_pll:cyclonev_pll|divclk[0]")
HDMI_RCLK_LINE = ('set_instance_assignment -name GLOBAL_SIGNAL "REGIONAL CLOCK" '
                  f'-to "{PLL_HDMI_NODE}"')
# A clock-network assignment belongs to the configuration: a re-apply strips every one, and
# --check refuses a copy outside the managed block (it would decide a network whatever the record
# says).
# The forced regional clock may land in either bottom quadrant (the fit log's "Regional Clock
# Region 1 from (0, 0) to (44, 36)" via CLKCTRL_R39, "Region 2 from (45, 0) to (89, 36)" via
# CLKCTRL_R29). Region 1 is the CPU's area; Region 2 holds the HDMI pins and the DSP columns
# sys/ascal.vhd uses. The location names the fitter-inserted clock buffer (~CLKENA0), as fit.rpt
# prints it.
HDMI_RCLK_Q2_LINE = f'set_location_assignment CLKCTRL_R29 -to "{PLL_HDMI_NODE}~CLKENA0"'
CLKCTRL_LOCATION_LINE_RE = re.compile(r"^\s*set_location_assignment\s+CLKCTRL_")
GLOBAL_SIGNAL_LINE_RE = re.compile(r"^\s*set_instance_assignment\s+-name\s+GLOBAL_SIGNAL\b")

# ---- debug instruments: the debug-UART framework -------------------------------------------
# Every part is a compile-time parameter of pc9821_system (z486_mister.sv's DBG_* localparams),
# OFF in every preset, and the unselected part does not exist in the netlist. They share the
# debug UART with pc9821_atapi's command log (cdrom_log_en, --dbg-cd) through pc9821_dbg_mux, which
# interleaves them on record boundaries, and tools/decode_dbglog.py reads the one stream.
#
#   cpu        --dbg-cpu           pc9821_dbg_cpu's sampler: CS:EIP, INTA counts per vector, PIC
#                                  state, VSYNC and port events, every sample_ms (default 10)
#   snoop      --dbg-snoop LO:HI   its memory snoop: every CPU write into [LO, HI) and every read
#                                  beat from it (physical addresses, hex)
#   gdc        --dbg-gdc           pc9821_gdc_log: the display programming (alias --gdc-log)
#   trig       --dbg-trig SPEC     its frozen instruction trace and the trigger that freezes it:
#                                  pc:CS:EIP (first issue there), wr:ADDR (first CPU write covering
#                                  that byte) or reload:ADDR (a nonzero 16-bit word written after a
#                                  zero one - the pn-stall stub-header reload)
#   trig2      --dbg-trig2 LO:HI   a second stage: the trigger only arms it, and the first CPU write
#                                  into [LO, HI) after it freezes the trace
#   arm_s      --dbg-arm-s N       nothing triggers before N seconds of uptime (boot traffic)
#   post       --dbg-post N        issues recorded after the final trigger (default 32)
#   sample_ms  --dbg-sample-ms N   the sampler's period in ms (1..255, default 10)
DBG_FLAGS = ("cpu", "gdc")
DBG_VALUES = ("snoop", "trig", "trig2", "sample_ms", "arm_s", "post")
DBG_DEFAULTS = {"sample_ms": 10, "arm_s": 0, "post": 32}
DBG_KINDS = {"pc": 1, "wr": 2, "reload": 3}


def _hex(text: str, what: str) -> int:
    try:
        return int(str(text).strip(), 16)
    except ValueError:
        raise SystemExit(f"{what}: {text!r} is not a hexadecimal number")


def parse_dbg_range(text, what: str) -> tuple[int, int]:
    """'LO:HI' (hex, optional 0x) -> (lo, hi) with 0 <= lo < hi <= 2**32."""
    lo, sep, hi = str(text).partition(":")
    if not sep:
        raise SystemExit(f"{what}: expected LO:HI (hex physical addresses), got {text!r}")
    lo, hi = _hex(lo, what), _hex(hi, what)
    if not 0 <= lo < hi <= 1 << 32:
        raise SystemExit(f"{what}: need 0 <= LO < HI <= 0x100000000, got {lo:#x}:{hi:#x}")
    return lo, hi


def parse_dbg_trig(text) -> tuple[str, int, int]:
    """'pc:CS:EIP' | 'wr:ADDR' | 'reload:ADDR' (hex) -> (kind name, cs, address)."""
    parts = str(text).strip().lower().split(":")
    kind = parts[0]
    if kind not in DBG_KINDS:
        raise SystemExit(f"--dbg-trig {text!r}: the kind is one of {', '.join(DBG_KINDS)} "
                         "(pc:CS:EIP, wr:ADDR, reload:ADDR)")
    if kind == "pc":
        if len(parts) != 3:
            raise SystemExit(f"--dbg-trig {text!r}: pc takes CS:EIP (pc:CS:EIP, hex)")
        cs, addr = _hex(parts[1], "--dbg-trig CS"), _hex(parts[2], "--dbg-trig EIP")
        if not 0 <= cs <= 0xFFFF or not 0 <= addr <= 0xFFFFFFFF:
            raise SystemExit(f"--dbg-trig {text!r}: CS is 16 bits and EIP 32")
        return kind, cs, addr
    if len(parts) != 2:
        raise SystemExit(f"--dbg-trig {text!r}: {kind} takes one address ({kind}:ADDR, hex)")
    addr = _hex(parts[1], "--dbg-trig ADDR")
    if not 0 <= addr <= 0xFFFFFFFF:
        raise SystemExit(f"--dbg-trig {text!r}: the address is 32 bits")
    return kind, 0, addr


def normalize_dbg(items) -> tuple[tuple[str, object], ...]:
    """A dict or (KEY, VALUE) pairs -> the canonical sorted pairs: a flag only when on, a value
    only when it differs from its default, ranges and triggers re-rendered in one hex form."""
    pairs = items.items() if isinstance(items, dict) else items
    out: dict[str, object] = {}
    for key, value in pairs:
        key = str(key).strip().lower()
        if key not in DBG_FLAGS + DBG_VALUES:
            raise SystemExit(f"dbg: unknown key {key!r}; allowed: {', '.join(DBG_FLAGS + DBG_VALUES)}")
        if value is None:
            continue
        if key in DBG_FLAGS:
            if bool(value):
                out[key] = True
        elif key in ("snoop", "trig2"):
            lo, hi = parse_dbg_range(value, f"dbg {key}")
            out[key] = f"{lo:#x}:{hi:#x}"
        elif key == "trig":
            kind, cs, addr = parse_dbg_trig(value)
            out[key] = f"pc:{cs:#x}:{addr:#x}" if kind == "pc" else f"{kind}:{addr:#x}"
        else:
            try:
                number = int(value)
            except (TypeError, ValueError):
                raise SystemExit(f"dbg {key}: {value!r} is not an integer")
            if number != DBG_DEFAULTS[key]:
                out[key] = number
    return tuple(sorted(out.items()))


def dbg_param_values(dbg: dict) -> dict:
    """The framework's localparam values for a normalized dbg dict."""
    lo, hi = parse_dbg_range(dbg["snoop"], "dbg snoop") if "snoop" in dbg else (0, 0)
    lo2, hi2 = parse_dbg_range(dbg["trig2"], "dbg trig2") if "trig2" in dbg else (0, 0)
    kind, cs, addr = parse_dbg_trig(dbg["trig"]) if "trig" in dbg else ("", 0, 0)
    return {
        "gdc": int(bool(dbg.get("gdc"))), "cpu": int(bool(dbg.get("cpu"))),
        "sample_ms": dbg.get("sample_ms", DBG_DEFAULTS["sample_ms"]),
        "snoop_en": int("snoop" in dbg), "snoop_lo": lo, "snoop_hi": hi & 0xFFFFFFFF if hi < 1 << 32 else 0xFFFFFFFF,
        "trig_kind": DBG_KINDS.get(kind, 0), "trig_addr": addr, "trig_cs": cs,
        "trig2_lo": lo2, "trig2_hi": hi2 & 0xFFFFFFFF if hi2 < 1 << 32 else 0xFFFFFFFF,
        "arm_s": dbg.get("arm_s", DBG_DEFAULTS["arm_s"]), "post": dbg.get("post", DBG_DEFAULTS["post"]),
    }


def dbg_problems(config) -> list[str]:
    dbg = dict(config.dbg)
    problems = []
    if not dbg:
        return problems
    if config.trace_en or config.perf_log_en:
        problems.append("dbg: the debug instruments share the UART arm with the trace/telemetry "
                        f"(trace_en {config.trace_en}, perf_log_en {config.perf_log_en}), whose bytes "
                        "would cut a record in two: build the instruments without them")
    if "trig2" in dbg and "trig" not in dbg:
        problems.append("dbg: trig2 (a second stage) needs trig (the first)")
    for key, lo, hi in (("sample_ms", 1, 255), ("arm_s", 0, 1023), ("post", 0, 65535)):
        if key in dbg and not lo <= dbg[key] <= hi:
            problems.append(f"dbg: {key} {dbg[key]} is outside {lo}..{hi}")
    if "sample_ms" in dbg and "cpu" not in dbg:
        problems.append("dbg: sample_ms means something only with the sampler (cpu)")
    if ("arm_s" in dbg or "post" in dbg) and "trig" not in dbg:
        problems.append("dbg: arm_s / post mean something only with a trigger (trig)")
    return problems


def dbg_localparams(config) -> list[tuple[str, str, str]]:
    """(name, regex, line) for the top level's DBG_* localparams."""
    p = config.dbg_params
    spec = [
        ("DBG_GDC_EN", "", f"1'b{p['gdc']}"),
        ("DBG_CPU_EN", "", f"1'b{p['cpu']}"),
        ("DBG_SAMPLE_MS", "", f"{p['sample_ms']}"),
        ("DBG_SNOOP_EN", "", f"1'b{p['snoop_en']}"),
        ("DBG_SNOOP_LO", "[31:0] ", f"32'h{p['snoop_lo']:08x}"),
        ("DBG_SNOOP_HI", "[31:0] ", f"32'h{p['snoop_hi']:08x}"),
        ("DBG_TRIG_KIND", "", f"{p['trig_kind']}"),
        ("DBG_TRIG_ADDR", "[31:0] ", f"32'h{p['trig_addr']:08x}"),
        ("DBG_TRIG_CS", "[15:0] ", f"16'h{p['trig_cs']:04x}"),
        ("DBG_TRIG2_LO", "[31:0] ", f"32'h{p['trig2_lo']:08x}"),
        ("DBG_TRIG2_HI", "[31:0] ", f"32'h{p['trig2_hi']:08x}"),
        ("DBG_ARM_S", "", f"{p['arm_s']}"),
        ("DBG_POST", "", f"{p['post']}"),
    ]
    out = []
    for name, width, value in spec:
        decl = re.escape(width).replace(r"\ ", r"[ \t]+") if width else ""
        pattern = rf"^localparam[ \t]+{decl}{name}[ \t]*=[ \t]*[^;]+;[ \t]*$"
        out.append((name, pattern, f"localparam {width}{name} = {value};"))
    return out


# ---- qsf_set: further fitter/synthesis assignments over the SPEED stack -------------------
# The value that DROPS a stack row instead of setting it (Quartus's own default then applies).
QSF_SET_DEFAULT = "@default"
QSF_SET_NAME_RE = re.compile(r"[A-Z][A-Z0-9_]*")
# One or more space-separated words; quoting is render_qsf_block's job, so no quote, no '#'.
QSF_SET_VALUE_RE = re.compile(r"[A-Za-z0-9_.+\-]+(?: [A-Za-z0-9_.+\-]+)*")
# Names a configuration may not carry: each has an owner of its own, or is project structure
# rather than a fit setting (a wrong one would build a different design, not a different fit).
QSF_SET_FORBIDDEN = {
    "OPTIMIZATION_TECHNIQUE": "set it with fit_technique (--fit-technique)",
    "SEED": "the seed belongs to tools/build.py --seed and the sweeps",
    "VERILOG_MACRO": "the framework macros belong to alsa_en (MISTER_DISABLE_YC is always set)",
    "NUM_PARALLEL_PROCESSORS": "execution, not configuration (it does not change the result)",
    "FAMILY": "project structure", "DEVICE": "project structure",
    "TOP_LEVEL_ENTITY": "project structure", "ORIGINAL_QUARTUS_VERSION": "project structure",
    "LAST_QUARTUS_VERSION": "project structure", "PROJECT_OUTPUT_DIRECTORY": "project structure",
    "SEARCH_PATH": "project structure", "TIMEQUEST_MULTICORNER_ANALYSIS":
        "it changes what the timing summary reports, so fits would not be comparable",
}
QSF_SET_FORBIDDEN_SUFFIXES = ("_FILE",)    # VERILOG_FILE, SDC_FILE, QIP_FILE, ...


def qsf_set_problems(pairs) -> list[str]:
    """Shape problems of a qsf_set (Quartus itself checks the names and values: quartus_check)."""
    problems = []
    seen = set()
    for name, value in pairs:
        if name in seen:
            problems.append(f"qsf_set: {name} is given twice")
        seen.add(name)
        if not QSF_SET_NAME_RE.fullmatch(name):
            problems.append(f"qsf_set: {name!r} is not an assignment name (A-Z, 0-9, _)")
        elif name in QSF_SET_FORBIDDEN:
            problems.append(f"qsf_set: {name} cannot be overridden here: {QSF_SET_FORBIDDEN[name]}")
        elif name.endswith(QSF_SET_FORBIDDEN_SUFFIXES):
            problems.append(f"qsf_set: {name} names a source file (project structure)")
        if value == QSF_SET_DEFAULT:
            if name not in CONTROLLED_ASSIGNMENTS:
                problems.append(f"qsf_set: {name}={QSF_SET_DEFAULT} drops a row, but {name} is not "
                                "in the SPEED stack")
        elif not QSF_SET_VALUE_RE.fullmatch(value):
            problems.append(f"qsf_set: {name}={value!r}: a value is one or more words of "
                            "[A-Za-z0-9_.+-] separated by single spaces (unquoted)")
    return problems


def normalize_qsf_set(items) -> tuple[tuple[str, str], ...]:
    """A dict or (NAME, VALUE) pairs -> sorted pairs, names upper-cased, quotes stripped."""
    pairs = items.items() if isinstance(items, dict) else items
    out: dict[str, str] = {}
    for name, value in pairs:
        value = str(value).strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1].strip()
        out[str(name).strip().upper()] = value
    return tuple(sorted(out.items()))


def parse_qsf_set_args(items: list[str] | None) -> tuple[tuple[str, str], ...]:
    """--qsf-set NAME=VALUE (repeatable) -> pairs; the later of two equal names wins."""
    pairs = []
    for item in items or []:
        name, sep, value = item.partition("=")
        if not sep:
            raise SystemExit(f"--qsf-set {item!r}: expected NAME=VALUE")
        pairs.append((name, value))
    return normalize_qsf_set(dict(normalize_qsf_set(pairs)))


def qsf_value(value: str) -> str:
    """A qsf_set value as the qsf writes it: a multi-word value is quoted."""
    return f'"{value}"' if " " in value else value


def quartus_check_qsf_set(pairs, *, project_dir: Path = PROJECT_DIR) -> list[str]:
    """Ask Quartus whether it accepts each NAME/VALUE: quartus_sh -t runs set_global_assignment
    on a throwaway Cyclone V project in the container, which refuses an unknown name ("Illegal
    assignment") or an illegal value ("Value ... is illegal") - whereas a fit silently IGNORES
    either, so a typo would read as "this setting does nothing". Verdicts are cached per image
    digest in .build/qsf-check-cache.json (the check takes ~1 s)."""
    pairs = [(n, v) for n, v in pairs if v != QSF_SET_DEFAULT]
    if not pairs:
        return []
    runtime, image = pg.container_runtime(), pg.container_image()
    try:
        digest = pg.image_digest(runtime, image)
    except pg.GenerationError as exc:
        return [f"qsf_set cannot be checked by Quartus: {exc}"]
    cache_path = project_dir / ".build" / "qsf-check-cache.json"
    try:
        cache = json.loads(cache_path.read_text())
    except (OSError, ValueError):
        cache = {}
    verdicts = cache.setdefault(digest, {})
    todo = [(n, v) for n, v in pairs if f"{n}={v}" not in verdicts]
    if todo:
        def tcl_word(text: str) -> str:
            return "{" + text + "}"
        lines = ["project_new -overwrite qsfcheck",
                 'set_global_assignment -name FAMILY "Cyclone V"',
                 "set_global_assignment -name DEVICE 5CSEBA6U23I7"]
        for n, v in todo:
            lines.append(f"if {{[catch {{set_global_assignment -name {n} {tcl_word(v)}}} e]}} "
                         f"{{puts \"QSFCHECK REJECT {n}={v} :: $e\"}} "
                         f"else {{puts \"QSFCHECK ACCEPT {n}={v}\"}}")
        lines.append("project_close")
        with tempfile.TemporaryDirectory(prefix="qsf-check-") as tmp:
            Path(tmp, "check.tcl").write_text("\n".join(lines) + "\n")
            try:
                out = subprocess.run(
                    [runtime, "run", "--rm", "-v", f"{tmp}:/work:Z", "-w", "/work", image,
                     "/opt/intelFPGA/quartus/bin/quartus_sh", "-t", "check.tcl"],
                    capture_output=True, text=True, timeout=300).stdout
            except (OSError, subprocess.TimeoutExpired) as exc:
                return [f"qsf_set cannot be checked by Quartus ({runtime} {image}): {exc}"]
        for line in out.splitlines():
            m = re.match(r"QSFCHECK (ACCEPT|REJECT) ([A-Z0-9_]+)=(.*?)(?: :: (.*))?$", line)
            if m:
                verdicts[f"{m.group(2)}={m.group(3)}"] = (
                    "ok" if m.group(1) == "ACCEPT" else (m.group(4) or "rejected"))
        missing = [f"{n}={v}" for n, v in todo if f"{n}={v}" not in verdicts]
        if missing:
            return [f"qsf_set: Quartus gave no verdict for {missing}:\n{out[-2000:]}"]
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = cache_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(cache, indent=1, sort_keys=True) + "\n")
        tmp_path.replace(cache_path)
    return [f"qsf_set: Quartus 17.0.2 refuses {n}={v}: {verdicts[f'{n}={v}']}"
            for n, v in pairs if verdicts[f"{n}={v}"] != "ok"]

# The framework feature macros the configuration owns: (Config field, macro sys/sys_top.v tests
# with `ifndef`). A feature that is OFF is one `VERILOG_MACRO "<macro>=1"` line in the managed
# block; ON is no line. No such line may exist outside the block (--check), because sys_top only
# asks whether the macro is DEFINED - a stray copy elsewhere in the qsf would compile the feature
# out whatever the record says.
FRAMEWORK_MACROS: tuple[tuple[str, str], ...] = (
    ("alsa_en", "MISTER_DISABLE_ALSA"),
)
# The composite/S-Video encoder is TV-only and ALWAYS off now: the 15 kHz TV converter that fed it
# was removed, so its macro is written unconditionally rather than
# following a knob.
YC_MACRO = "MISTER_DISABLE_YC"
MACRO_LINE_RE = re.compile(r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"?([A-Za-z0-9_]+)')


def framework_macro_lines(config: "Config") -> list[str]:
    lines = [f'set_global_assignment -name VERILOG_MACRO "{macro}=1"'
             for field, macro in FRAMEWORK_MACROS if not getattr(config, field)]
    lines.append(f'set_global_assignment -name VERILOG_MACRO "{YC_MACRO}=1"')
    return lines


# EVERY preset runs the SDRAM on clk_sys: the split-clock configuration was removed. The 80/80
# build was hardware-verified as the shipping build: DOOM, PCM, Touhou 5,
# Rusty and Flame Zapper with the Xe10 firmware pack.
# 80 MHz is PAST timing closure (the ao486/MiSTer convention: the tools' Fmax is a worst-case-PVT
# number and real boards at room temperature run faster); docs/fitting.md ("Timing and area facts")
# holds the measured slack band and the hardware bound.
# 90 MHz since 2026-10-19, for margin across boards (95 MHz was close to marginal): CL2 (the CL3
# cutover is at 100 MHz).
_BASE_HZ = 90_000_000
_BASE_DESCRIPTION = ("90 MHz clk_sys, SDRAM on clk_sys (90/90, CL2), production AREA fit (no seed) - "
                     "the default and shipping build (past timing closure)")
PROFILES: dict[str, Config] = {
    "base": Config(
        name="base",
        description=_BASE_DESCRIPTION,
        clk_sys_hz=_BASE_HZ,
    ),
    "mediumoc": Config(
        name="mediumoc",
        description="100 MHz clk_sys, SDRAM on clk_sys (100/100) - NORMAL overclock (past timing closure)",
        clk_sys_hz=100_000_000,
    ),
    # 120 MHz is AT the board SDRAM part's hard limit (about 120 MHz).
    "heavyoc": Config(
        name="heavyoc",
        description="120 MHz clk_sys, SDRAM on clk_sys (120/120, AT the SDRAM part's ~120 MHz limit) - HEAVY overclock (past timing closure)",
        clk_sys_hz=120_000_000,
    ),
    # The instruction trace: IDENTICAL to base in clock and PLL, so the trace runs at exactly the
    # clock the shipped core does. THE DEBUG PROFILE. It asked for OPTIMIZATION_TECHNIQUE AREA
    # first (2026-09-27); every preset has used AREA since 2026-10-12 (see Config.fit_technique).
    "trace": Config(
        name="trace",
        description="90 MHz clk_sys, SDRAM on clk_sys (clock/PLL identical to base) + the instruction trace ring and perf log, fit with OPTIMIZATION_TECHNIQUE AREA (the debug build)",
        clk_sys_hz=_BASE_HZ,
        trace_en=True,
        perf_log_en=True,
        # The debug build keeps its room for the trace ring: no MIDI card, no HPS audio.
        mpu_en=False,
        alsa_en=False,
        fit_technique="AREA",
    ),
    # The I/O-latency profile: IDENTICAL to base in clock, PLL and fit settings, so the only
    # difference is the I/O class table (IO_LATENCY_PROFILE 2 prices every class at the
    # machine's measured time, docs/probes/IO.TXT; 1 holds back the EGC even-read class).
    "iofaithful": Config(
        name="iofaithful",
        description="90 MHz clk_sys, SDRAM on clk_sys (identical to base) + the FAITHFUL I/O class table",
        clk_sys_hz=_BASE_HZ,
        io_latency_profile=2,
    ),
}


# ---------------------------------------------------------------------------------------
# Resolving a configuration from a preset, a profile file and CLI overrides
# ---------------------------------------------------------------------------------------

PROFILE_FILE_KEYS = {
    "name", "description", "preset", "clk_sys_hz", "clk_sys_mhz",
    "sdram_phase_ps", "trace_en", "perf_log_en", "io_latency_profile", "mpu_en",
    "cdrom_en", "cdrom_audio_en", "cdrom_log_en", "alsa_en", "fit_technique", "qsf_set",
    "dbg", "vga_dbl_en", "hdmi_rclk", "hdmi_rclk_q2", "sdram_dq_ddio", "sdram_out_ddio",
    "sdram_phase_dyn", "dbg_sdram_cl2", "dbg_sdram_trcd",
}


def add_override_args(parser: argparse.ArgumentParser) -> None:
    """The configuration overrides, shared by build_profile.py, tools/build.py and seed_sweep."""
    g = parser.add_argument_group("build configuration (override any field of the preset)")
    g.add_argument("--custom", action="store_true",
                   help="start from base's values under the name 'custom'")
    g.add_argument("--profile-file", type=Path,
                   help="a JSON or TOML file of configuration fields (and optionally 'preset', "
                        "'name', 'description'); CLI overrides apply on top of it")
    g.add_argument("--name", help="the recorded profile name (default: the preset's, or "
                                  "'custom' when anything differs from it)")
    g.add_argument("--clk-sys-mhz", help="clk_sys in MHz (exact, e.g. 56.25); the SDRAM "
                                         "controller runs on it too")
    g.add_argument("--clk-sys-hz", type=int, help="clk_sys in Hz")
    g.add_argument("--sdram-phase-ps",
                   help="SDRAM_CLK (PLL output 1) phase in ps, or 'auto' to derive it")
    g.add_argument("--trace", dest="trace_en", action=argparse.BooleanOptionalAction,
                   default=None, help="TRACE_EN (the instruction trace ring)")
    g.add_argument("--perf-log", dest="perf_log_en", action=argparse.BooleanOptionalAction,
                   default=None, help="PERF_LOG_EN (the serial performance log)")
    g.add_argument("--io-latency", dest="io_latency_profile", type=int, choices=(0, 1, 2),
                   help="IO_LATENCY_PROFILE")
    g.add_argument("--mpu", dest="mpu_en", action=argparse.BooleanOptionalAction, default=None,
                   help="MPU_EN (and the MIDI CONF_STR header)")
    g.add_argument("--cdrom", dest="cdrom_en", action=argparse.BooleanOptionalAction,
                   default=None, help="CDROM_EN (and the CD-ROM OSD slot / VDNUM)")
    g.add_argument("--cdrom-audio", dest="cdrom_audio_en", action=argparse.BooleanOptionalAction,
                   default=None, help="CDROM_AUDIO_EN (the CD drive's CD-DA player)")
    g.add_argument("--cdrom-log", "--dbg-cd", dest="cdrom_log_en", action=argparse.BooleanOptionalAction,
                   default=None, help="CDROM_LOG_EN (debug: the CD's command log on the debug UART)")
    g.add_argument("--dbg-cpu", dest="dbg_cpu", action=argparse.BooleanOptionalAction, default=None,
                   help="debug: the CPU sampler (CS:EIP, INTA counts, PIC state, VSYNC) on the debug UART")
    g.add_argument("--dbg-gdc", "--gdc-log", dest="dbg_gdc", action=argparse.BooleanOptionalAction,
                   default=None, help="debug: the display programming (both GDCs) on the debug UART")
    g.add_argument("--dbg-snoop", dest="dbg_snoop", metavar="LO:HI",
                   help="debug: every CPU write and read beat in the physical window [LO, HI) (hex)")
    g.add_argument("--dbg-trig", dest="dbg_trig", metavar="SPEC",
                   help="debug: freeze the instruction trace on pc:CS:EIP, wr:ADDR or reload:ADDR (hex)")
    g.add_argument("--dbg-trig2", dest="dbg_trig2", metavar="LO:HI",
                   help="debug: a second stage - the first CPU write into [LO, HI) after --dbg-trig")
    g.add_argument("--dbg-sample-ms", dest="dbg_sample_ms", type=int, metavar="N",
                   help="debug: the sampler's period in ms (default 10)")
    g.add_argument("--dbg-arm-s", dest="dbg_arm_s", type=int, metavar="N",
                   help="debug: no trigger fires before N seconds of uptime")
    g.add_argument("--dbg-post", dest="dbg_post", type=int, metavar="N",
                   help="debug: issues recorded after the final trigger (default 32)")
    g.add_argument("--alsa", dest="alsa_en", action=argparse.BooleanOptionalAction, default=None,
                   help="the framework's HPS audio input (off = MISTER_DISABLE_ALSA; the "
                        "composite/S-Video encoder is always off - it is TV-only)")
    g.add_argument("--vga-dbl", dest="vga_dbl_en", action=argparse.BooleanOptionalAction,
                   default=None, help="VIDEO_DBL_EN (the analog line doubler, 49.7 kHz)")
    g.add_argument("--sdram-dq-ddio", dest="sdram_dq_ddio", action=argparse.BooleanOptionalAction,
                   default=None, help="SDRAM_DQ_DDIO: the SDRAM read capture as an instantiated "
                        "IOE input DDIO cell (off = a packed fabric register, the A/B side)")
    g.add_argument("--sdram-out-ddio", dest="sdram_out_ddio", action=argparse.BooleanOptionalAction,
                   default=None, help="SDRAM_OUT_DDIO: every SDRAM output and DQ output-enable "
                        "register as an instantiated IOE cell (off = packed fabric registers, the "
                        "A/B side)")
    g.add_argument("--hdmi-rclk", dest="hdmi_rclk", action=argparse.BooleanOptionalAction,
                   default=None, help="the framework pll_hdmi clock on a REGIONAL clock network "
                        "(a fit-side placement knob for the pll_hdmi margin)")
    g.add_argument("--hdmi-rclk-q2", dest="hdmi_rclk_q2", action=argparse.BooleanOptionalAction,
                   default=None, help="with --hdmi-rclk: that regional clock in the bottom-right "
                        "quadrant (CLKCTRL_R29), beside the HDMI pins")
    g.add_argument("--dbg-sdram-phase", dest="sdram_phase_dyn",
                   action=argparse.BooleanOptionalAction, default=None,
                   help="debug: SDRAM_PHASE_DYN, the run-time SDRAM_CLK phase instrument (the PLL's "
                        "phase-shift ports and a guest stepper at 0x5FF0/0x5FF2); a measurement "
                        "build, never shipped")
    g.add_argument("--dbg-sdram-cl2", dest="dbg_sdram_cl2", action=argparse.BooleanOptionalAction,
                   default=None, help="debug: SDRAM_DBG_CL 2 and the phase-shifted SDRAM_CLK at any "
                        "clock (the pre-cutover 100 MHz CL2 structure); a measurement build")
    g.add_argument("--dbg-sdram-trcd-cycles", dest="dbg_sdram_trcd", type=int, metavar="N",
                   help="debug: SDRAM_DBG_TRCD_TRP, tRCD and tRP forced to N cycles (0 = derived)")
    g.add_argument("--fit-technique", choices=FIT_TECHNIQUES, help="OPTIMIZATION_TECHNIQUE")
    g.add_argument("--qsf-set", action="append", metavar="NAME=VALUE",
                   help="a fitter/synthesis qsf assignment over the SPEED stack (repeatable; "
                        f"VALUE {QSF_SET_DEFAULT} drops the stack's row); recorded in the "
                        "configuration and checked by Quartus when applied")


def override_argv(ns: argparse.Namespace) -> list[str]:
    """The overrides in `ns`, as build_profile.py arguments (for passing through)."""
    out: list[str] = []
    if getattr(ns, "custom", False):
        out.append("--custom")
    for flag, attr in (("--profile-file", "profile_file"), ("--name", "name"),
                       ("--clk-sys-mhz", "clk_sys_mhz"), ("--clk-sys-hz", "clk_sys_hz"),
                       ("--sdram-phase-ps", "sdram_phase_ps"),
                       ("--io-latency", "io_latency_profile"),
                       ("--fit-technique", "fit_technique"),
                       ("--dbg-sdram-trcd-cycles", "dbg_sdram_trcd")):
        value = getattr(ns, attr, None)
        if value is not None:
            out += [flag, str(Path(value).resolve()) if attr == "profile_file" else str(value)]
    for flag, attr in (("trace", "trace_en"),
                       ("perf-log", "perf_log_en"), ("mpu", "mpu_en"), ("cdrom", "cdrom_en"),
                       ("cdrom-audio", "cdrom_audio_en"), ("cdrom-log", "cdrom_log_en"), ("alsa", "alsa_en"),
                       ("vga-dbl", "vga_dbl_en"), ("hdmi-rclk", "hdmi_rclk"),
                       ("hdmi-rclk-q2", "hdmi_rclk_q2"), ("sdram-dq-ddio", "sdram_dq_ddio"),
                       ("sdram-out-ddio", "sdram_out_ddio"), ("dbg-sdram-phase", "sdram_phase_dyn"),
                       ("dbg-sdram-cl2", "dbg_sdram_cl2")):
        value = getattr(ns, attr, None)
        if value is not None:
            out.append(f"--{flag}" if value else f"--no-{flag}")
    for name, value in parse_qsf_set_args(getattr(ns, "qsf_set", None)):
        out += ["--qsf-set", f"{name}={value}"]
    for key in DBG_FLAGS:
        value = getattr(ns, f"dbg_{key}", None)
        if value is not None:
            out.append(f"--dbg-{key}" if value else f"--no-dbg-{key}")
    for key in DBG_VALUES:
        value = getattr(ns, f"dbg_{key}", None)
        if value is not None:
            out += [f"--dbg-{key.replace('_', '-')}", str(value)]
    return out


def load_profile_file(path: Path) -> dict:
    text = path.read_bytes()
    if path.suffix.lower() == ".toml":
        import tomllib
        data = tomllib.loads(text.decode())
    else:
        data = json.loads(text)
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: a profile file is a table/object of configuration fields")
    retired = sorted(set(data) & set(RETIRED_FIELDS))
    if retired:
        raise SystemExit(f"{path}: {retired} belonged to the split-clock configuration, which was "
                         "removed (2026-10-09): the SDRAM runs on clk_sys, so set clk_sys_hz / "
                         "clk_sys_mhz alone")
    unknown = set(data) - PROFILE_FILE_KEYS
    if unknown:
        raise SystemExit(f"{path}: unknown field(s) {sorted(unknown)}; allowed: "
                         f"{sorted(PROFILE_FILE_KEYS)}")
    return data


def _phase_value(value) -> int | None:
    if value is None or str(value).lower() == "auto":
        return None
    return int(value)


def resolve_config(preset_name: str | None, ns: argparse.Namespace) -> Config:
    """preset (or --custom / the file's 'preset') < profile file < CLI flags."""
    data = load_profile_file(ns.profile_file) if getattr(ns, "profile_file", None) else {}
    if preset_name is None:
        preset_name = data.get("preset")
    custom = bool(getattr(ns, "custom", False))
    if preset_name is None:
        if not custom and not data and not any(override_argv(ns)):
            raise SystemExit("choose a preset, --custom, or --profile-file")
        preset_name = "base"
        custom = True
    if preset_name not in PROFILES:
        raise SystemExit(f"unknown preset {preset_name!r}; presets: {', '.join(PROFILES)}")
    preset = PROFILES[preset_name]
    fields: dict = dataclasses.asdict(preset)

    def take(key, value):
        if value is not None:
            fields[key] = value

    take("clk_sys_hz", data.get("clk_sys_hz"))
    if "clk_sys_mhz" in data:
        take("clk_sys_hz", pg.hz_from_mhz_arg(data["clk_sys_mhz"]))
    if "sdram_phase_ps" in data:
        fields["sdram_phase_ps"] = _phase_value(data["sdram_phase_ps"])
    for key in ("trace_en", "perf_log_en", "io_latency_profile", "mpu_en",
                "cdrom_en", "cdrom_audio_en", "cdrom_log_en", "alsa_en", "fit_technique",
                "vga_dbl_en", "hdmi_rclk", "hdmi_rclk_q2", "sdram_dq_ddio", "sdram_out_ddio",
                "sdram_phase_dyn", "dbg_sdram_cl2", "dbg_sdram_trcd"):
        take(key, data.get(key))
    # qsf_set merges name by name: the preset's, then the file's table, then each --qsf-set.
    qsf_set = dict(preset.qsf_set)
    if "qsf_set" in data:
        if not isinstance(data["qsf_set"], dict):
            raise SystemExit("profile file: qsf_set is a table of NAME = VALUE")
        qsf_set.update(normalize_qsf_set(data["qsf_set"]))

    take("clk_sys_hz", getattr(ns, "clk_sys_hz", None))
    if getattr(ns, "clk_sys_mhz", None) is not None:
        fields["clk_sys_hz"] = pg.hz_from_mhz_arg(ns.clk_sys_mhz)
    if getattr(ns, "sdram_phase_ps", None) is not None:
        fields["sdram_phase_ps"] = _phase_value(ns.sdram_phase_ps)
    for key in ("trace_en", "perf_log_en", "io_latency_profile", "mpu_en",
                "cdrom_en", "cdrom_audio_en", "cdrom_log_en", "alsa_en", "fit_technique",
                "vga_dbl_en", "hdmi_rclk", "hdmi_rclk_q2", "sdram_dq_ddio", "sdram_out_ddio",
                "sdram_phase_dyn", "dbg_sdram_cl2", "dbg_sdram_trcd"):
        take(key, getattr(ns, key, None))
    qsf_set.update(parse_qsf_set_args(getattr(ns, "qsf_set", None)))
    fields["qsf_set"] = normalize_qsf_set(qsf_set)
    # dbg merges key by key like qsf_set: the preset's (none), the file's table, then each flag.
    dbg = dict(preset.dbg)
    if "dbg" in data:
        if not isinstance(data["dbg"], dict):
            raise SystemExit("profile file: dbg is a table of KEY = VALUE")
        dbg.update(data["dbg"])
    for key in DBG_FLAGS + DBG_VALUES:
        value = getattr(ns, f"dbg_{key}", None)
        if value is not None:
            dbg[key] = value
    fields["dbg"] = normalize_dbg(dbg)

    # The CD-DA player is part of the drive: --no-cdrom takes it too unless the player was asked for
    # by name (then validate() refuses the pair rather than folding the request away).
    if not fields["cdrom_en"] and data.get("cdrom_audio_en") is None \
            and getattr(ns, "cdrom_audio_en", None) is None:
        fields["cdrom_audio_en"] = False

    candidate = Config(**fields)
    changed = custom or candidate.knobs() != preset.knobs()
    name = getattr(ns, "name", None) or data.get("name") or ("custom" if changed else preset.name)
    description = data.get("description") or (
        preset.description if not changed else
        f"custom (from {preset.name}): {fields['clk_sys_hz'] / 1e6:g} MHz clk_sys, SDRAM on clk_sys")
    config = dataclasses.replace(candidate, name=name, description=description,
                                 preset=None if not changed and name == preset.name else preset.name)
    problems = config.validate()
    if problems:
        raise SystemExit("invalid configuration:\n  " + "\n  ".join(problems))
    return config


def config_from_record(record: dict, description: str = "") -> Config:
    phase = record["sdram_phase_ps"] if record.get("sdram_phase_source") == "override" else None
    return Config(
        # A record from before the split-clock removal may still carry sdram_hz / sdram_sync;
        # they are not fields any more, and agreement() reports such a record as retired.
        name=record["name"], description=description, clk_sys_hz=record["clk_sys_hz"],
        sdram_phase_ps=phase, trace_en=record["trace_en"],
        perf_log_en=record["perf_log_en"], io_latency_profile=record["io_latency_profile"],
        mpu_en=record["mpu_en"], fit_technique=record["fit_technique"],
        # Records written before these fields existed mean the defaults they had then.
        cdrom_en=record.get("cdrom_en", False),
        # CDROM_AUDIO_EN was always written as cdrom_en AND cdrom_audio_en, so a no-CD record's
        # player flag means nothing and reads as off (validate() refuses the pair otherwise).
        cdrom_audio_en=record.get("cdrom_audio_en", True) and record.get("cdrom_en", False),
        cdrom_log_en=record.get("cdrom_log_en", False),
        # A record written before this field existed was a build with ALSA ON (the macro was not
        # set), so that is what it means; --check then flags its block, which lacks nothing, as
        # agreeing - and a re-apply moves it to the new default. yc_en / tv15k_en are retired
        # fields: a record carrying them is read for everything else, and its YC choice is moot
        # (YC is always off now).
        alsa_en=record.get("alsa_en", True),
        # A record written before the analog converters existed was a build without them.
        vga_dbl_en=record.get("vga_dbl_en", False),
        # A record without this key is a build whose pll_hdmi network was the fitter's choice.
        hdmi_rclk=record.get("hdmi_rclk", False),
        hdmi_rclk_q2=record.get("hdmi_rclk_q2", False),
        # A record without this key is a build without the run-time phase instrument.
        sdram_phase_dyn=record.get("sdram_phase_dyn", False),
        dbg_sdram_cl2=record.get("dbg_sdram_cl2", False),
        dbg_sdram_trcd=record.get("dbg_sdram_trcd", 0),
        # A record written before this field existed was a build whose DQ capture was packed.
        sdram_dq_ddio=record.get("sdram_dq_ddio", False),
        # Likewise its output registers.
        sdram_out_ddio=record.get("sdram_out_ddio", False),
        # A record written before qsf_set existed carries none, which is what it meant.
        qsf_set=normalize_qsf_set(record.get("qsf_set", {})),
        dbg=normalize_dbg(record.get("dbg", {})),
        preset=record.get("preset"))


# ---------------------------------------------------------------------------------------
# The qsf block
# ---------------------------------------------------------------------------------------

def fit_assignments(config: Config) -> tuple[tuple[str, str], ...]:
    """The SPEED stack with the technique, each qsf_set override in its row's place (or the
    row dropped for @default), then the overrides the stack has no row for, by name."""
    if FIT_TECHNIQUE_ASSIGNMENT not in CONTROLLED_ASSIGNMENTS:
        raise SystemExit(f"build_profile.py: {FIT_TECHNIQUE_ASSIGNMENT} is not a row of "
                         "SPEED_FIT_ASSIGNMENTS, so no fit_technique can reach the qsf")
    over = dict(config.qsf_set)
    rows = []
    for name, value in SPEED_FIT_ASSIGNMENTS:
        if name == FIT_TECHNIQUE_ASSIGNMENT:
            value = config.fit_technique
        if name in over:
            if over[name] == QSF_SET_DEFAULT:
                continue
            value = qsf_value(over[name])
        rows.append((name, value))
    rows += [(name, qsf_value(value)) for name, value in config.qsf_set
             if name not in CONTROLLED_ASSIGNMENTS]
    return tuple(rows)


def outside_block_lines(text: str, names) -> list[str]:
    """Assignment lines OUTSIDE the managed block that set any of `names`."""
    block = qsf_block_text(text) or ""
    assignment_re = re.compile(r"^\s*set_global_assignment\s+-name\s+([A-Z0-9_]+)\b")
    return [line.strip() for line in text.replace(block, "").splitlines()
            if (m := assignment_re.match(line)) and m.group(1) in names]


def render_qsf_block(config: Config) -> str:
    phase, source = config.phase()
    lines = [
        PROFILE_BLOCK_BEGIN,
        f"# Active profile: {config.name}",
        f"# Active clock rate: {config.clk_sys_hz:_} Hz (clk_sys, the SDRAM's clock too)",
        f"# Active SDRAM phase: {phase} ps ({source})",
        CONFIG_RECORD_PREFIX + config.record_json(),
        f"# {config.description}",
    ]
    if config.qsf_set:
        lines.append("# qsf_set: " + ", ".join(f"{n}={v}" for n, v in config.qsf_set))
    lines += [f"set_global_assignment -name {n} {v}" for n, v in fit_assignments(config)]
    lines += framework_macro_lines(config)
    if config.hdmi_rclk:
        lines.append(HDMI_RCLK_LINE)
    if config.hdmi_rclk_q2:
        lines.append(HDMI_RCLK_Q2_LINE)
    lines.append(PROFILE_BLOCK_END)
    return "\n".join(lines)


def remove_managed_qsf_content(text: str) -> str:
    block_re = re.compile(
        rf"\n?{re.escape(PROFILE_BLOCK_BEGIN)}.*?{re.escape(PROFILE_BLOCK_END)}\n?", re.DOTALL)
    text = block_re.sub("\n", text)
    text = "\n".join(line for line in text.splitlines()
                     if line.strip() not in (OE_FABRIC_COMMENT, OE_FABRIC_LINE))
    assignment_re = re.compile(r"^\s*set_global_assignment\s+-name\s+([A-Z0-9_]+)\b")
    owned_macros = {macro for _, macro in FRAMEWORK_MACROS} | {YC_MACRO}
    kept = [line for line in text.splitlines()
            if not ((m := assignment_re.match(line)) and m.group(1) in CONTROLLED_ASSIGNMENTS)
            and not ((m := MACRO_LINE_RE.match(line)) and m.group(1) in owned_macros)
            and not GLOBAL_SIGNAL_LINE_RE.match(line)
            and not CLKCTRL_LOCATION_LINE_RE.match(line)]
    return "\n".join(kept).rstrip() + "\n"


def insert_qsf_block(text: str, config: Config) -> str:
    block = render_qsf_block(config)
    marker = "set_global_assignment -name TIMEQUEST_MULTICORNER_ANALYSIS OFF"
    if marker in text:
        text = text.replace(marker, marker + "\n" + block, 1)
    else:
        text = text.rstrip() + "\n\n" + block + "\n"
    if config.sdram_out_ddio:
        text = text.rstrip() + "\n\n" + OE_FABRIC_COMMENT + "\n" + OE_FABRIC_LINE + "\n"
    return text


def dq_oe_register_problems(text: str, config: Config, qsf) -> list[str]:
    """The last FAST_OUTPUT_ENABLE_REGISTER assignment to SDRAM_DQ[*] decides (OE_FABRIC_LINE)."""
    lines = text.splitlines()
    values = [m.group(1) for line in lines if (m := OE_ASSIGN_RE.match(line))]
    last = values[-1] if values else None
    # sys/sys.tcl sets it ON when it is sourced, so the OFF must also come after that line.
    sys_at = max((i for i, line in enumerate(lines) if line.strip() == "source sys/sys.tcl"), default=-1)
    off_at = max((i for i, line in enumerate(lines) if line.strip() == OE_FABRIC_LINE), default=-1)
    if config.sdram_out_ddio and (last != "OFF" or off_at < sys_at):
        return [f"{qsf}: the cell build's SDRAM DQ output enable must stay in the fabric - "
                f"`{OE_FABRIC_LINE}` must be the last FAST_OUTPUT_ENABLE_REGISTER assignment to "
                "SDRAM_DQ[*], after `source sys/sys.tcl` (re-apply the profile)"]
    if not config.sdram_out_ddio and "OFF" in values:
        return [f"{qsf}: the packed build (sdram_out_ddio off) carries `{OE_FABRIC_LINE}`"]
    return []


def qsf_block_text(text: str) -> str | None:
    m = re.search(rf"{re.escape(PROFILE_BLOCK_BEGIN)}.*?{re.escape(PROFILE_BLOCK_END)}", text,
                  re.DOTALL)
    return None if m is None else m.group(0)


def read_record(root: Path) -> tuple[dict | None, str]:
    """The '# Active config' JSON record of root's qsf, and the description line after it."""
    qsf = root / QSF_NAME
    if not qsf.exists():
        return None, ""
    block = qsf_block_text(qsf.read_text()) or ""
    m = re.search(rf"^{re.escape(CONFIG_RECORD_PREFIX)}(\{{.*\}})\n# (.*)$", block, re.MULTILINE)
    if not m:
        return None, ""
    return json.loads(m.group(1)), m.group(2)


def active_config(root: Path) -> Config | None:
    record, description = read_record(root)
    return None if record is None else config_from_record(record, description)


# ---------------------------------------------------------------------------------------
# The top level
# ---------------------------------------------------------------------------------------

def top_localparams(config: Config) -> list[tuple[str, str, str]]:
    """(name, regex matching the line, the line to write)."""
    return [
        ("CLOCK_RATE_HZ", r"^localparam[ \t]+CLOCK_RATE_HZ[ \t]*=[ \t]*[0-9_]+;[ \t]*$",
         f"localparam CLOCK_RATE_HZ = {config.clk_sys_hz:_};"),
        ("TRACE_EN", r"^localparam[ \t]+TRACE_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam TRACE_EN = 1'b{int(config.trace_en)};"),
        ("PERF_LOG_EN", r"^localparam[ \t]+PERF_LOG_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam PERF_LOG_EN = 1'b{int(config.perf_log_en)};"),
        ("IO_LATENCY_PROFILE",
         r"^localparam[ \t]+\[1:0\][ \t]+IO_LATENCY_PROFILE[ \t]*=[ \t]*2'd[0-3];[ \t]*$",
         f"localparam [1:0] IO_LATENCY_PROFILE = 2'd{config.io_latency_profile};"),
        ("MPU_EN", r"^localparam[ \t]+MPU_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam MPU_EN = 1'b{int(config.mpu_en)};"),
        ("SDRAM_CLK_DDIO", r"^localparam[ \t]+SDRAM_CLK_DDIO[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam SDRAM_CLK_DDIO = 1'b{int(config.sdram_clk_ddio)};"),
        ("SDRAM_DQ_DDIO", r"^localparam[ \t]+SDRAM_DQ_DDIO[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam SDRAM_DQ_DDIO = 1'b{int(config.sdram_dq_ddio)};"),
        ("SDRAM_OUT_DDIO", r"^localparam[ \t]+SDRAM_OUT_DDIO[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam SDRAM_OUT_DDIO = 1'b{int(config.sdram_out_ddio)};"),
        ("SDRAM_PHASE_DYN", r"^localparam[ \t]+SDRAM_PHASE_DYN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam SDRAM_PHASE_DYN = 1'b{int(config.sdram_phase_dyn)};"),
        ("SDRAM_DBG_CL", r"^localparam[ \t]+integer[ \t]+SDRAM_DBG_CL[ \t]*=[ \t]*[0-9]+;[ \t]*$",
         f"localparam integer SDRAM_DBG_CL = {2 if config.dbg_sdram_cl2 else 0};"),
        ("SDRAM_DBG_TRCD_TRP",
         r"^localparam[ \t]+integer[ \t]+SDRAM_DBG_TRCD_TRP[ \t]*=[ \t]*[0-9]+;[ \t]*$",
         f"localparam integer SDRAM_DBG_TRCD_TRP = {config.dbg_sdram_trcd};"),
        ("CONF_STR_HEADER", r'^localparam[ \t]+CONF_STR_HEADER[ \t]*=[ \t]*"[^"]*";[ \t]*$',
         f'localparam CONF_STR_HEADER = "{config.conf_str_header}";'),
        ("CDROM_EN", r"^localparam[ \t]+CDROM_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam CDROM_EN = 1'b{int(config.cdrom_en)};"),
        ("CDROM_AUDIO_EN", r"^localparam[ \t]+CDROM_AUDIO_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam CDROM_AUDIO_EN = 1'b{int(config.cdrom_en and config.cdrom_audio_en)};"),
        ("CDROM_LOG_EN", r"^localparam[ \t]+CDROM_LOG_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam CDROM_LOG_EN = 1'b{int(config.cdrom_en and config.cdrom_log_en and not config.perf_log_en)};"),
        ("CONF_STR_CD", r'^localparam[ \t]+CONF_STR_CD[ \t]*=[ \t]*"[^"]*";[ \t]*$',
         f'localparam CONF_STR_CD = "{config.conf_str_cd}";'),
        ("HPS_VDNUM", r"^localparam[ \t]+HPS_VDNUM[ \t]*=[ \t]*[0-9]+;[ \t]*$",
         f"localparam HPS_VDNUM = {config.hps_vdnum};"),
        ("VIDEO_DBL_EN", r"^localparam[ \t]+VIDEO_DBL_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam VIDEO_DBL_EN = 1'b{int(config.vga_dbl_en)};"),
        ("CONF_STR_VIDEO", r'^localparam[ \t]+CONF_STR_VIDEO[ \t]*=[ \t]*"[^"]*";[ \t]*$',
         f'localparam CONF_STR_VIDEO = "{config.conf_str_video}";'),
        *dbg_localparams(config),
    ]


def rewrite_top(text: str, config: Config) -> str:
    for name, pattern, line in top_localparams(config):
        text, count = re.subn(pattern, line.replace("\\", "\\\\"), text, count=1,
                              flags=re.MULTILINE)
        if count != 1:
            raise SystemExit(f"Expected exactly one {name} localparam in {TOP_NAME}")
    return text


# ---------------------------------------------------------------------------------------
# Applying and generating
# ---------------------------------------------------------------------------------------

def generate_outputs(config: Config, root: Path, log=print) -> dict:
    """The PLLs (core and video) into root/rtl and the SDC into root/z486_mister.sdc."""
    try:
        rb = pg.generate_pll(config.pll_request(), root / "rtl", project_dir=PROJECT_DIR, log=log)
        pg.generate_vpll(config.vpll_request(), root / "rtl", project_dir=PROJECT_DIR, log=log)
    except pg.GenerationError as exc:
        raise SystemExit(f"PLL generation failed: {exc}")
    (root / SDC_NAME).write_text(render_config_sdc(config))
    return rb


def render_config_sdc(config: Config) -> str:
    # The video PLL is the reconfigurable fractional variant, generated at its fastest run-time
    # setting (the 31 kHz clock, 50.336 MHz), so the crossing bound is that period.
    return pg.render_sdc(config.name, config.clk_sys_hz, tv=False, dq_ddio=config.sdram_dq_ddio,
                         clk_ddio=config.sdram_clk_ddio, dps=config.sdram_phase_dyn,
                         out_ddio=config.sdram_out_ddio)


def describe(config: Config, rb: dict | None = None) -> str:
    phase, source = config.phase()
    actual = rb[f"phase{pg.PIN_CLOCK_OUTPUT}_ps"] if rb else phase
    pred = pg.predict_io(actual / 1000, 1e9 / config.clk_sys_hz)
    worst = pg.io_worst(pred)
    limit = (" (AT/ABOVE the SDRAM part's ~120 MHz limit)"
             if config.clk_sys_hz >= SDRAM_PART_LIMIT_HZ else "")
    return (f"{config.name}: clk_sys {config.clk_sys_hz:_} Hz = the SDRAM clock{limit}, "
            f"SDRAM_CLK phase {phase} ps ({source}; PLL actual {actual} ps), "
            f"I/O model worst {worst[0]:+.3f} ns ({worst[2]} @ {worst[1]}), "
            f"TRACE_EN {int(config.trace_en)} PERF_LOG_EN {int(config.perf_log_en)} "
            f"IO_LATENCY_PROFILE {config.io_latency_profile} MPU_EN {int(config.mpu_en)} SDRAM_CLK_DDIO {int(config.sdram_clk_ddio)} "
            f"SDRAM_DQ_DDIO {int(config.sdram_dq_ddio)} SDRAM_OUT_DDIO {int(config.sdram_out_ddio)} "
            f"CDROM_EN {int(config.cdrom_en)} "
            f"CDROM_AUDIO_EN {int(config.cdrom_en and config.cdrom_audio_en)} "
            + ("CDROM_LOG_EN 1 " if (config.cdrom_en and config.cdrom_log_en and not config.perf_log_en) else "") +
            f"ALSA {int(config.alsa_en)} YC 0 "
            f"VIDEO_DBL_EN {int(config.vga_dbl_en)} fit {config.fit_technique}"
            + (" pll_hdmi regional" if config.hdmi_rclk else "")
            + (" (CLKCTRL_R29)" if config.hdmi_rclk_q2 else "")
            + (" SDRAM_PHASE_DYN 1 (measurement build)" if config.sdram_phase_dyn else "")
            + (" SDRAM_DBG_CL 2" if config.dbg_sdram_cl2 else "")
            + (f" SDRAM_DBG_TRCD_TRP {config.dbg_sdram_trcd}" if config.dbg_sdram_trcd else "")
            + (" qsf_set " + ",".join(f"{n}={v}" for n, v in config.qsf_set)
               if config.qsf_set else "")
            + (" dbg " + ",".join(f"{n}={v}" for n, v in config.dbg) if config.dbg else ""))


def apply_config(config: Config, root: Path, *, dry_run: bool, generate: bool) -> None:
    top, qsf = root / TOP_NAME, root / QSF_NAME
    new_top = rewrite_top(top.read_text(), config)
    new_qsf = insert_qsf_block(remove_managed_qsf_content(qsf.read_text()), config)
    stray = outside_block_lines(new_qsf, {n for n, _ in config.qsf_set})
    if stray:
        raise SystemExit(f"qsf_set overrides a name {qsf} also sets outside the managed block "
                         f"({stray[0]!r}); remove that line first, so one value can win")
    if config.qsf_set and generate:
        # Quartus ignores an unknown assignment or an illegal value in a qsf without a word,
        # so every override is put to Quartus itself before the tree is touched.
        problems = quartus_check_qsf_set(config.qsf_set)
        if problems:
            raise SystemExit("invalid configuration:\n  " + "\n  ".join(problems))
    if dry_run:
        for path, new in ((top, new_top), (qsf, new_qsf)):
            if path.read_text() != new:
                print(f"Would update {path}")
        print("Would generate rtl/pll* and z486_mister.sdc for: " + describe(config))
        return
    # The PLL first: an unmakeable frequency fails here, before the tree is touched (the
    # generator installs nothing it has not read back and verified).
    rb = generate_outputs(config, root) if generate else None
    top.write_text(new_top)
    qsf.write_text(new_qsf)
    print("Applied " + describe(config, rb))
    if not generate:
        print("  (--no-generate: rtl/pll* and z486_mister.sdc were NOT written)")


# ---------------------------------------------------------------------------------------
# --check: the top level, the qsf, the generated PLL and the generated SDC all agree
# ---------------------------------------------------------------------------------------

def agreement(root: Path, *, require_generated: bool = False) -> list[str]:
    problems: list[str] = []
    qsf, top = root / QSF_NAME, root / TOP_NAME
    record, description = read_record(root)
    if record is None:
        return [f"no '{CONFIG_RECORD_PREFIX.strip()}' record in {qsf}: nothing can say which "
                "configuration this tree builds (run ./build_profile.py <profile>)"]
    try:
        config = config_from_record(record, description)
    except (KeyError, TypeError) as exc:
        return [f"the '# Active config' record in {qsf} is malformed: {exc}"]
    problems += config.validate()
    # A record from before the split-clock removal names an SDRAM clock of its own. One that says
    # anything but "the SDRAM on clk_sys" describes a build this tree can no longer make.
    if (record.get("sdram_hz", config.clk_sys_hz) != config.clk_sys_hz
            or record.get("sdram_sync", True) is False):
        problems.append(f"the '# Active config' record in {qsf} is a SPLIT-CLOCK build (sdram_hz "
                        f"{record.get('sdram_hz')}, sdram_sync {record.get('sdram_sync')}), which was "
                        "removed on 2026-10-09: re-apply a preset (the SDRAM runs on clk_sys)")

    # The whole managed block must be exactly what this record renders: that covers the name,
    # clock and phase comment lines and every fit assignment, the technique included.
    block = qsf_block_text(qsf.read_text())
    expected_block = render_qsf_block(config)
    if block != expected_block:
        got = (block or "").splitlines()
        want = expected_block.splitlines()
        diff = [f"    qsf: {g!r}\n    want: {w!r}" for g, w in zip(got, want) if g != w]
        if len(got) != len(want):
            diff.append(f"    ({len(got)} lines in the qsf block, {len(want)} expected)")
        problems.append(f"{qsf}'s managed block is not the one its own record renders "
                        "(edited by hand?):\n" + "\n".join(diff[:6]))
    problems += dq_oe_register_problems(qsf.read_text(), config, qsf)
    # An override must be the only line that sets its name, or the qsf's order would decide.
    for line in outside_block_lines(qsf.read_text(), {n for n, _ in config.qsf_set}):
        problems.append(f"{qsf} sets a qsf_set name outside the managed block ({line!r}), so the "
                        "record's value is not the only one Quartus sees")
    # The framework feature macros: the block's lines are covered by the comparison above; a copy
    # OUTSIDE the block would define the macro whatever the record says.
    outside = qsf.read_text().replace(block or "", "")
    for field, macro in FRAMEWORK_MACROS:
        stray = [line.strip() for line in outside.splitlines()
                 if (m := MACRO_LINE_RE.match(line)) and m.group(1) == macro]
        if stray:
            problems.append(f"{qsf} sets {macro} outside the managed block ({stray[0]!r}), so the "
                            f"record's {field}={getattr(config, field)} cannot hold: the macro "
                            "belongs to build_profile.py (re-apply the profile)")
    stray = [line.strip() for line in outside.splitlines()
             if GLOBAL_SIGNAL_LINE_RE.match(line) or CLKCTRL_LOCATION_LINE_RE.match(line)]
    if stray:
        problems.append(f"{qsf} sets a clock network outside the managed block ({stray[0]!r}): "
                        f"clock networks belong to the record (hdmi_rclk={config.hdmi_rclk}) - "
                        "re-apply the profile")
    if record.get("sdram_phase_source") == "derived":
        derived = pg.derive_sdram_phase(config.clk_sys_hz)["phase_ps"]
        if record["sdram_phase_ps"] != derived:
            problems.append(f"the record's derived phase {record['sdram_phase_ps']} ps is not what "
                            f"the I/O model derives today ({derived} ps): re-apply the profile")

    top_text = top.read_text()
    # The split-clock knobs are gone from the top level; one that reappears (an old branch merged
    # in) would be a second, unchecked SDRAM clock decision.
    for name in RETIRED_LOCALPARAMS:
        if re.search(rf"^localparam\b[^;]*\b{name}\b", top_text, re.MULTILINE):
            problems.append(f"{top} declares the retired split-clock localparam {name}: the SDRAM "
                            "runs on CLOCK_RATE_HZ, and nothing may decide a second clock")
    for name, pattern, line in top_localparams(config):
        m = re.search(pattern, top_text, re.MULTILINE)
        if m is None:
            problems.append(f"no {name} localparam in {top} to agree with")
        elif m.group(0).strip() != line:
            problems.append(f"{top} declares `{m.group(0).strip()}` but the active configuration "
                            f"'{config.name}' means `{line}`")

    problems += dq_ddio_wiring_problems(root)
    problems += out_ddio_wiring_problems(root)
    for name, hop in DBG_TIMING_WIRING:
        text = (root / name).read_text()
        if len(re.findall(re.escape(hop).replace(r"\(", r"\(\s*").replace(r"\)", r"\s*\)"), text)) != 1:
            problems.append(f"{root / name} does not pass `{hop}` down exactly once: a "
                            "measurement override would silently build the derived timing")

    sdc = root / SDC_NAME
    if sdc.exists():
        try:
            expected = render_config_sdc(config)
        except pg.GenerationError as exc:
            expected = None
            problems.append(f"the record cannot render an SDC: {exc}")
        actual = sdc.read_text()
        if expected is not None and actual != expected:
            problems.append(f"{sdc} is not the SDC the active configuration generates (a stale "
                            "copy, a hand edit, or a template change): re-apply the profile")
        problems += pg.sdc_block_shape_problems(actual, str(sdc))
    elif require_generated:
        problems.append(f"{sdc} was not generated")

    pll2 = root / "rtl" / "pll" / "pll_0002.v"
    if pll2.exists() and (root / "rtl" / "pll.v").exists():
        try:
            problems += [f"rtl/pll: {p}" for p in
                         pg.verify_readback(config.pll_request(), pg.read_back(root / "rtl"))]
        except pg.GenerationError as exc:
            problems.append(f"rtl/pll cannot be read back: {exc}")
    elif require_generated:
        problems.append(f"{root / 'rtl'} has no generated PLL (pll.v + pll/pll_0002.v)")

    if (root / pg.VCLK_PKG).exists():
        problems += pg.vclk_pkg_problems((root / pg.VCLK_PKG).read_text())
    elif require_generated:
        problems.append(f"{root / pg.VCLK_PKG} is missing: the video PLL settings cannot be checked")

    vpll2 = root / "rtl" / "vpll" / "vpll_0002.v"
    if vpll2.exists() and (root / "rtl" / "vpll.v").exists():
        try:
            problems += [f"rtl/vpll: {p}" for p in
                         pg.verify_readback_vpll(config.vpll_request(), pg.read_back_vpll(root / "rtl"))]
        except pg.GenerationError as exc:
            problems.append(f"rtl/vpll cannot be read back: {exc}")
    elif require_generated:
        problems.append(f"{root / 'rtl'} has no generated video PLL (vpll.v + vpll/vpll_0002.v)")
    return problems


def dq_ddio_wiring_problems(root: Path) -> list[str]:
    """SDRAM_DQ_DDIO reaches sdram.v, whose DDIO arm holds the cell the SDC names."""
    problems = []
    for name, hop in DQ_DDIO_WIRING:
        text = (root / name).read_text()
        if len(re.findall(re.escape(hop).replace(r"\(", r"\(\s*").replace(r"\)", r"\s*\)"), text)) != 1:
            problems.append(f"{root / name} does not pass the DQ capture choice down exactly once "
                            f"(`{hop}`): the controller would build its default cell")
    text = (root / SDRAM_V).read_text()
    arm = re.search(r"generate if \(DQ_IN_DDIO\) begin : g_dq_ddio(.*?)end else begin : g_dq_ff",
                    text, re.S)
    inst = pg.DQ_DDIO_INSTANCE.split(":")
    if not arm or not re.search(rf"\b{inst[0]}\b[^;]*?\)\s*{inst[1]}\s*\(", arm.group(1), re.S):
        problems.append(f"{root / SDRAM_V}'s DQ_IN_DDIO arm does not instantiate `{inst[0]}` as "
                        f"`{inst[1]}`, the cell the generated SDC's capture collection names")
    return problems


def out_ddio_wiring_problems(root: Path) -> list[str]:
    """SDRAM_OUT_DDIO reaches sdram.v, whose cell arm holds the cells the SDC counts."""
    problems = []
    for name, hop in OUT_DDIO_WIRING:
        text = (root / name).read_text()
        if len(re.findall(re.escape(hop).replace(r"\(", r"\(\s*").replace(r"\)", r"\s*\)"), text)) != 1:
            problems.append(f"{root / name} does not pass the output-cell choice down exactly once "
                            f"(`{hop}`): the controller would build its default (packed) registers")
    text = (root / SDRAM_V).read_text()
    arm = re.search(r"generate if \(OUT_DDIO\) begin : g_out_ddio(.*?)end else begin : g_out_ff",
                    text, re.S)
    # The DQ output enable must be the per-pin register, not a cyclonev_ddio_oe atom: a build that
    # drove the SDRAM DQ OE from that atom simulated and timed clean and was black on hardware.
    if re.search(r"^[^/]*\bcyclonev_ddio_oe\b", text, re.M):
        problems.append(f"{root / SDRAM_V} instantiates cyclonev_ddio_oe: the DQ output enable must "
                        "be the per-pin dq_oe_q register (a DDIO_OE-driven build was black on hardware)")
    for cell in pg.OUT_DDIO_INSTANCES:
        kind, inst = cell.split(":")
        if not arm or not re.search(rf"\b{kind}\b[^;]*?\)\s*{inst}\s*\(", arm.group(1), re.S):
            problems.append(f"{root / SDRAM_V}'s OUT_DDIO arm does not instantiate `{kind}` as "
                            f"`{inst}`, a cell the generated SDC's output-cell guard counts")
    return problems


# ---------------------------------------------------------------------------------------
# --selftest: --check must catch every planted disagreement
# ---------------------------------------------------------------------------------------

def _fake_pll(root: Path, config: Config, *, freq1_hz: int | None = None,
              off_steps: int = 0) -> None:
    """A PLL directory that reads back like a generated one (no container needed)."""
    req = config.pll_request()
    rtl = root / "rtl"
    (rtl / "pll").mkdir(parents=True, exist_ok=True)
    text = pg.add_tied_dps_ports(pg.render_pll_v(req))
    if req.dps:   # what the wizard writes with the ports: declared AND passed to pll_0002
        text = text.replace("\tassign phase_done = 1'b0;\n", "").replace(
            ".locked   (locked)", ".locked   (locked), .phase_en (phase_en), .scanclk (scanclk), "
            ".updn (updn), .cntsel (cntsel), .phase_done (phase_done)")
    (rtl / "pll.v").write_text(text)
    # What the wizard would report: the request rounded onto the finest VCO's step grid
    # (displaced by off_steps steps), truncated to whole ps.
    vco = max(v for v in range(300_000_000, 1_600_000_001, 1_000_000) if v % req.clk_sys_hz == 0)
    step = 1e12 / (8 * vco)
    phase_ps = int((round(req.phase_ps / step) + off_steps) * step)
    f1 = req.clk_sys_hz if freq1_hz is None else freq1_hz
    _fake_vpll(root, config)
    (rtl / "pll" / "pll_0002.v").write_text(
        f"\t\t.number_of_clocks({pg.PLL_OUTPUTS}),\n"
        f'\t\t.pll_subtype("{"DPS" if req.dps else "General"}"),\n'
        f'\t\t.output_clock_frequency0("{req.clk_sys_hz / 1e6:.6f} MHz"),\n'
        '\t\t.phase_shift0("0 ps"),\n'
        f'\t\t.output_clock_frequency1("{f1 / 1e6:.6f} MHz"),\n'
        f'\t\t.phase_shift1("{phase_ps} ps"),\n')


def _fake_vpll(root: Path, config: Config) -> None:
    """A video PLL directory that reads back like a generated one (no container needed)."""
    req = config.vpll_request()
    _, freq_text, (mh, ml), k, vco = pg.VPLL_CONFIGS[req.tv]
    rtl = root / "rtl"
    (rtl / "vpll").mkdir(parents=True, exist_ok=True)
    (rtl / "vpll.v").write_text(pg.render_vpll_v(req) + "// reconfig_to_pll\n")
    (rtl / "vpll" / "vpll_0002.v").write_text(
        "\t\t.number_of_clocks(1),\n"
        '\t\t.fractional_vco_multiplier("true"),\n'
        f'\t\t.output_clock_frequency0("{freq_text}"),\n'
        '\t\t.pll_subtype("Reconfigurable"),\n'
        f"\t\t.m_cnt_hi_div({mh}),\n\t\t.m_cnt_lo_div({ml}),\n"
        '\t\t.n_cnt_bypass_en("true"),\n'
        f"\t\t.c_cnt_hi_div0({pg.VPLL_C0[0]}),\n\t\t.c_cnt_lo_div0({pg.VPLL_C0[1]}),\n"
        f'\t\t.pll_output_clk_frequency("{vco}"),\n'
        f'\t\t.pll_fractional_division("{k}"),\n')


def selftest() -> int:
    plants = []

    def plant(label, tree="base"):
        def deco(fn):
            plants.append((label, fn, tree))
            return fn
        return deco

    def sub(path: Path, old: str, new: str) -> None:
        text = path.read_text()
        if old not in text:
            raise AssertionError(f"selftest: {old!r} not in {path}")
        path.write_text(text.replace(old, new, 1))

    @plant("top level: CLOCK_RATE_HZ disagrees with the record")
    def _(root, cfg):
        sub(root / TOP_NAME, f"CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};", "CLOCK_RATE_HZ = 50_000_000;")

    @plant("top level: the retired SDRAM_RATE_HZ reappears (an old branch merged in)")
    def _(root, cfg):
        sub(root / TOP_NAME, f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};",
            f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};\nlocalparam SDRAM_RATE_HZ = 100_000_000;")

    @plant("top level: the retired SDRAM_SYNC reappears (an old branch merged in)")
    def _(root, cfg):
        sub(root / TOP_NAME, f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};",
            f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};\nlocalparam SDRAM_SYNC = 1'b0;")

    @plant("top level: TRACE_EN flipped against the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "TRACE_EN = 1'b0;", "TRACE_EN = 1'b1;")

    @plant("top level: PERF_LOG_EN flipped against the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "PERF_LOG_EN = 1'b0;", "PERF_LOG_EN = 1'b1;")

    @plant("top level: IO_LATENCY_PROFILE disagrees with the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "IO_LATENCY_PROFILE = 2'd0;", "IO_LATENCY_PROFILE = 2'd2;")

    @plant("top level: MPU_EN flipped without its header")
    def _(root, cfg):
        sub(root / TOP_NAME, "MPU_EN = 1'b1;", "MPU_EN = 1'b0;")

    @plant("top level: SDRAM_CLK_DDIO on at 80 MHz (the DDIO clock cannot hold below 100 MHz)")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_CLK_DDIO = 1'b0;", "SDRAM_CLK_DDIO = 1'b1;")

    @plant("top level: SDRAM_CLK_DDIO dropped (off) in a 100 MHz+ build", tree="mediumoc")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_CLK_DDIO = 1'b1;", "SDRAM_CLK_DDIO = 1'b0;")

    @plant("top level: SDRAM_DQ_DDIO flipped against the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_DQ_DDIO = 1'b1;", "SDRAM_DQ_DDIO = 1'b0;")

    @plant("top level: the packed-capture build's SDRAM_DQ_DDIO left on", tree="packed")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_DQ_DDIO = 1'b0;", "SDRAM_DQ_DDIO = 1'b1;")

    @plant("top level: SDRAM_DQ_DDIO no longer reaches the backend")
    def _(root, cfg):
        sub(root / TOP_NAME, ".DQ_IN_DDIO(SDRAM_DQ_DDIO),", "")

    @plant("bridge: DQ_IN_DDIO not passed on to sdram.v")
    def _(root, cfg):
        sub(root / "src/memory/sdram_sync_bridge.sv", ",\n    .DQ_IN_DDIO(DQ_IN_DDIO)", "")

    @plant("top level: SDRAM_OUT_DDIO flipped against the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_OUT_DDIO = 1'b1;", "SDRAM_OUT_DDIO = 1'b0;")

    @plant("top level: the packed-output build's SDRAM_OUT_DDIO left on", tree="packedout")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_OUT_DDIO = 1'b0;", "SDRAM_OUT_DDIO = 1'b1;")

    @plant("top level: SDRAM_OUT_DDIO no longer reaches the backend")
    def _(root, cfg):
        sub(root / TOP_NAME, ".OUT_DDIO(SDRAM_OUT_DDIO),", "")

    @plant("backend: OUT_DDIO not passed on to the bridge")
    def _(root, cfg):
        sub(root / "src/memory/split_sdram_backend.sv", ",\n    .OUT_DDIO(OUT_DDIO)", "")

    @plant("bridge: OUT_DDIO not passed on to sdram.v")
    def _(root, cfg):
        sub(root / "src/memory/sdram_sync_bridge.sv", ",\n    .OUT_DDIO(OUT_DDIO)", "")

    @plant("qsf: the cell build's fabric-OE line dropped (the OE would be packed again)")
    def _(root, cfg):
        sub(root / QSF_NAME, OE_FABRIC_LINE + "\n", "")

    @plant("qsf: an ON line after the cell build's fabric-OE line (the last assignment wins)")
    def _(root, cfg):
        q = root / QSF_NAME
        q.write_text(q.read_text() + OE_FABRIC_LINE.replace(" OFF ", " ON ") + "\n")

    @plant("qsf: the packed build carrying the fabric-OE line", tree="packedout")
    def _(root, cfg):
        q = root / QSF_NAME
        q.write_text(q.read_text() + OE_FABRIC_LINE + "\n")

    @plant("sdram.v: the address cell renamed (the SDC's output-cell guard would miscount)")
    def _(root, cfg):
        sub(root / SDRAM_V, ") ca_out (", ") ca_out2 (")

    @plant("sdram.v: the DQ output enable from a cyclonev_ddio_oe atom (black on hardware)")
    def _(root, cfg):
        sub(root / SDRAM_V, "    assign oen_pins = dq_oe_q;\n",
            "    cyclonev_ddio_oe oe_x (.oe(dq_oen_n), .clk(clk), .dataout(oen_pins[0]));\n")

    @plant("SDC: an output-cell build without the cut on the cells' falling-edge mux path")
    def _(root, cfg):
        sub(root / SDC_NAME, "set_false_path -fall_from $pc9821_clk_sys -to $pc9821_sdram_out\n", "")

    @plant("SDC: the packed-output build carrying the output-cell exception", tree="packedout")
    def _(root, cfg):
        sub(root / SDC_NAME, pg.render_out_cut(False), pg.render_out_cut(True))

    @plant("sdram.v: the DDIO cell renamed (the SDC's capture collection would match nothing)")
    def _(root, cfg):
        sub(root / SDRAM_V, ") dq_cap (", ") dq_cap2 (")

    @plant("SDC: a DDIO build's capture collection names the packed register")
    def _(root, cfg):
        sub(root / SDC_NAME, pg.DQ_CAPTURE_REGS[True], pg.DQ_CAPTURE_REGS[False])

    @plant("SDC: a DDIO build without the cut on the cell's unused low half")
    def _(root, cfg):
        sub(root / SDC_NAME, "    set_false_path -from [get_ports SDRAM_DQ[*]] -to $pc9821_sdram_dq_lo\n", "")

    @plant("SDC: the DDIO build's generated clock lost its -invert", tree="mediumoc")
    def _(root, cfg):
        sub(root / SDC_NAME, "-divide_by 1 -invert", "-divide_by 1")

    @plant("SDC: the DDIO build forwards PLL output 1 (the DDIO is clocked by clk_sys)", tree="mediumoc")
    def _(root, cfg):
        sub(root / SDC_NAME, "[get_pins {emu|pll|pll_inst|altera_pll_i|general[0]*|divclk}]",
            "[get_pins {emu|pll|pll_inst|altera_pll_i|general[1]*|divclk}]")

    @plant("SDC: the CL3 build keeps the CL2 tAC", tree="mediumoc")
    def _(root, cfg):
        sub(root / SDC_NAME, "-max 5.4 [get_ports SDRAM_DQ", "-max 6.0 [get_ports SDRAM_DQ")

    @plant("SDC: the CL2 build takes the CL3 tAC (hold at 80 MHz is not modelled with it)")
    def _(root, cfg):
        sub(root / SDC_NAME, "-max 6.0 [get_ports SDRAM_DQ", "-max 5.4 [get_ports SDRAM_DQ")

    @plant("top level: CDROM_EN flipped without its OSD slot", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_EN = 1'b0;", "CDROM_EN = 1'b1;")

    @plant("top level: the default build's CDROM_EN dropped with its OSD slot left in place")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_EN = 1'b1;", "CDROM_EN = 1'b0;")

    @plant("top level: CDROM_LOG_EN on in a build whose record has no CD log")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_LOG_EN = 1'b0;", "CDROM_LOG_EN = 1'b1;")

    @plant("top level: DBG_GDC_EN on in a build whose record has no debug instruments")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_GDC_EN = 1'b0;", "DBG_GDC_EN = 1'b1;")

    @plant("top level: DBG_SNOOP_HI disagrees with the record's snoop window", tree="dbg")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_SNOOP_HI = 32'h0002fc00;", "DBG_SNOOP_HI = 32'h0002fe00;")

    @plant("top level: DBG_TRIG_KIND dropped although the record names a trigger", tree="dbg")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_TRIG_KIND = 3;", "DBG_TRIG_KIND = 0;")

    @plant("top level: the framework's DBG_POST edited away from the default 32")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_POST = 32;", "DBG_POST = 8;")

    @plant("qsf: the record gains a debug instrument the top level does not carry")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"', '"name":"base","dbg":{"gdc":true}')

    @plant("top level: a CD build whose CDROM_AUDIO_EN dropped the CD-DA player")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_AUDIO_EN = 1'b1;", "CDROM_AUDIO_EN = 1'b0;")

    @plant("top level: a doubler build whose VIDEO_DBL_EN dropped the line doubler")
    def _(root, cfg):
        sub(root / TOP_NAME, "VIDEO_DBL_EN = 1'b1;", "VIDEO_DBL_EN = 1'b0;")

    @plant("top level: CONF_STR_VIDEO offers a TV mode the build does not have")
    def _(root, cfg):
        sub(root / TOP_NAME, "Native 24kHz,Doubled 49kHz;", "Native 24kHz,Doubled 49kHz,TV 15kHz;")

    @plant("top level: HPS_VDNUM disagrees with CDROM_EN", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, "HPS_VDNUM = 3;", "HPS_VDNUM = 5;")

    @plant("top level: the default CD build's HPS_VDNUM back to 3 (no slot 4)")
    def _(root, cfg):
        sub(root / TOP_NAME, "HPS_VDNUM = 5;", "HPS_VDNUM = 3;")

    @plant("top level: CONF_STR_CD gains the retired second disk's entry", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, '"T[8],Eject HDD;";', '"T[8],Eject HDD;S3,IMGHDIVHD,Mount HDD1;";')

    @plant("top level: the CD-ROM's Eject offered in a build without the CD", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, '"T[8],Eject HDD;";', '"T[8],Eject HDD;T[11],Eject CD-ROM;";')

    cd_line = '"T[8],Eject HDD;S4,ISOPCD,Mount CD-ROM;T[11],Eject CD-ROM;' + CD_VOLUME_FIELD + '";'

    @plant("top level: a CD build whose CD line lost the CD-ROM's Eject")
    def _(root, cfg):
        sub(root / TOP_NAME, cd_line,
            '"T[8],Eject HDD;S4,ISOPCD,Mount CD-ROM;' + CD_VOLUME_FIELD + '";')

    @plant("top level: a CD build whose CD line lost the CD-ROM's slot")
    def _(root, cfg):
        sub(root / TOP_NAME, cd_line,
            '"T[8],Eject HDD;T[11],Eject CD-ROM;' + CD_VOLUME_FIELD + '";')

    @plant("top level: a CD-audio build whose CD line lost the CD audio volume field")
    def _(root, cfg):
        sub(root / TOP_NAME, cd_line,
            '"T[8],Eject HDD;S4,ISOPCD,Mount CD-ROM;T[11],Eject CD-ROM;";')

    @plant("qsf: the technique row edited by hand")
    def _(root, cfg):
        other = "SPEED" if cfg.fit_technique == "AREA" else "AREA"
        sub(root / QSF_NAME, f"OPTIMIZATION_TECHNIQUE {cfg.fit_technique}", f"OPTIMIZATION_TECHNIQUE {other}")

    @plant("qsf: the record's clk_sys changed (top level, PLL and SDC still the old one)")
    def _(root, cfg):
        sub(root / QSF_NAME, f'"clk_sys_hz":{cfg.clk_sys_hz}', '"clk_sys_hz":85000000')

    @plant("qsf: the record's derived phase is not what the I/O model derives")
    def _(root, cfg):
        sub(root / QSF_NAME, f'"sdram_phase_ps":{cfg.phase()[0]}', '"sdram_phase_ps":8000')

    @plant("qsf: a retired SPLIT-CLOCK record (sdram_hz != clk_sys) with its block")
    def _(root, cfg):
        sub(root / QSF_NAME, '"sdram_phase_ps":', f'"sdram_hz":100000000,"sdram_sync":false,"sdram_phase_ps":')

    @plant("qsf: the YC macro dropped from the block (record still says off)")
    def _(root, cfg):
        sub(root / QSF_NAME, 'set_global_assignment -name VERILOG_MACRO "MISTER_DISABLE_YC=1"\n', "")

    @plant("qsf: the record says ALSA off while the block builds it")
    def _(root, cfg):
        sub(root / QSF_NAME, '"alsa_en":true', '"alsa_en":false')

    @plant("SDC: the computed block's clock line edited")
    def _(root, cfg):
        sub(root / SDC_NAME, f"clk_sys {pg.mhz_text(cfg.clk_sys_hz)} MHz", "clk_sys 50.0 MHz")

    @plant("SDC: a retired split-clock multicycle inside the computed block")
    def _(root, cfg):
        sub(root / SDC_NAME, pg.SDC_PROFILE_END,
            "set_multicycle_path -from $pc9821_clk_sys -to $pc9821_clk_sdram -setup -end 3\n"
            + pg.SDC_PROFILE_END)

    @plant("SDC: a shared line edited")
    def _(root, cfg):
        sub(root / SDC_NAME, "set_output_delay -clock PC9821_SDRAM_CLK -max  1.5",
            "set_output_delay -clock PC9821_SDRAM_CLK -max  1.0")

    @plant("SDC: a computed comment lost its '#'")
    def _(root, cfg):
        sub(root / SDC_NAME, "# so there is no second clock domain", "so there is no second clock domain")

    @plant("PLL: output 1 (the SDRAM pin clock) is not at clk_sys")
    def _(root, cfg):
        _fake_pll(root, cfg, freq1_hz=100_000_000)

    @plant("PLL: output 1's phase is off by more than a VCO step")
    def _(root, cfg):
        _fake_pll(root, cfg, off_steps=-13)

    @plant("PLL: pll.v requests a different phase than the record")
    def _(root, cfg):
        sub(root / "rtl" / "pll.v", f'gui_phase_shift1" value="{cfg.phase()[0]}"',
            'gui_phase_shift1" value="4000"')

    @plant("PLL: a retired three-output (split-clock) PLL")
    def _(root, cfg):
        sub(root / "rtl" / "pll" / "pll_0002.v", f".number_of_clocks({pg.PLL_OUTPUTS})",
            ".number_of_clocks(3)")

    @plant("video PLL: its output is not 50 MHz x (M + K/2^32) / 19 (another C0)")
    def _(root, cfg):
        sub(root / "rtl" / "vpll" / "vpll_0002.v", "c_cnt_hi_div0(10)", "c_cnt_hi_div0(9)")

    @plant("video PLL: another M (the ratio to the 31 kHz dot rate is no longer the generated one)")
    def _(root, cfg):
        sub(root / "rtl" / "vpll" / "vpll_0002.v", "m_cnt_hi_div(10)", "m_cnt_hi_div(9)")

    @plant("video PLL: another fraction K")
    def _(root, cfg):
        sub(root / "rtl" / "vpll" / "vpll_0002.v", 'pll_fractional_division("548405248")',
            'pll_fractional_division("548405249")')

    @plant("video PLL: an integer-N PLL (pc9821_vpll_ctl's K writes do nothing)")
    def _(root, cfg):
        sub(root / "rtl" / "vpll" / "vpll_0002.v", 'fractional_vco_multiplier("true")',
            'fractional_vco_multiplier("false")')

    @plant("video PLL: not reconfigurable (pc9821_vpll_ctl cannot reach the 24 kHz clock)")
    def _(root, cfg):
        sub(root / "rtl" / "vpll" / "vpll_0002.v", 'pll_subtype("Reconfigurable")', 'pll_subtype("General")')

    @plant("video PLL: the RTL's 31 kHz fraction is not the generator's (pc9821_vclk_pkg)")
    def _(root, cfg):
        sub(root / pg.VCLK_PKG, "VPLL_K31   = 32'h20B0_0000", "VPLL_K31   = 32'h20B1_0000")

    @plant("video PLL: the RTL's 24 kHz M is not the generator's (pc9821_vclk_pkg)")
    def _(root, cfg):
        sub(root / pg.VCLK_PKG, "VPLL_M24   = 16", "VPLL_M24   = 17")

    @plant("video PLL: missing while generation is required")
    def _(root, cfg):
        (root / "rtl" / "vpll" / "vpll_0002.v").unlink()

    @plant("SDC: the video clock's crossing bound is the 24 kHz period, not the generated 31 kHz one")
    def _(root, cfg):
        sub(root / SDC_NAME, "set_max_delay -from $pc9821_clk_sys -to $pc9821_clk_vid 19.866",
            "set_max_delay -from $pc9821_clk_sys -to $pc9821_clk_vid 23.750")

    @plant("SDC: the video clock lost its asynchronous group")
    def _(root, cfg):
        sub(root / SDC_NAME, "set_clock_groups -asynchronous -group $pc9821_clk_vid",
            "# set_clock_groups -asynchronous -group $pc9821_clk_vid")

    @plant("SDC missing while generation is required")
    def _(root, cfg):
        (root / SDC_NAME).unlink()

    # qsf_set: the overrides are part of the record, so the block must render from it exactly.
    @plant("qsf: the record gains a qsf_set the block does not carry")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"',
            '"name":"base","qsf_set":{"PHYSICAL_SYNTHESIS_EFFORT":"NORMAL"}')

    @plant("qsf: an override's row edited by hand", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, "ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM",
            "ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL")

    @plant("qsf: a stack row the override drops (@default) put back by hand", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, "set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL",
            "set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON\n"
            "set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL")

    @plant("qsf: an override's name also set outside the managed block", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, "source sys/sys.tcl",
            "set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL\nsource sys/sys.tcl")

    @plant("qsf: the record's qsf_set names a forbidden assignment (SEED)", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, '"qsf_set":{', '"qsf_set":{"SEED":"3",')

    # sdram_phase_dyn: the top level's parameter and the generated PLL's ports follow the record.
    @plant("top level: SDRAM_PHASE_DYN flipped against the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_PHASE_DYN = 1'b0;", "SDRAM_PHASE_DYN = 1'b1;")

    @plant("top level: a phase-instrument build whose SDRAM_PHASE_DYN dropped it", tree="sdph")
    def _(root, cfg):
        sub(root / TOP_NAME, "SDRAM_PHASE_DYN = 1'b1;", "SDRAM_PHASE_DYN = 1'b0;")

    @plant("PLL: a phase-instrument build whose PLL has no DPS ports (pll_subtype General)", tree="sdph")
    def _(root, cfg):
        sub(root / "rtl" / "pll" / "pll_0002.v", 'pll_subtype("DPS")', 'pll_subtype("General")')

    @plant("PLL: a base build whose PLL was generated with the DPS ports")
    def _(root, cfg):
        sub(root / "rtl" / "pll" / "pll_0002.v", 'pll_subtype("General")', 'pll_subtype("DPS")')

    @plant("PLL: the wrapper lost a tied DPS port the top level connects")
    def _(root, cfg):
        sub(root / "rtl" / "pll.v", "input  wire       updn,\n", "")

    @plant("PLL: a phase-instrument build whose wrapper does not pass the ports on", tree="sdph")
    def _(root, cfg):
        sub(root / "rtl" / "pll.v", ".phase_en (phase_en), ", "")

    @plant("top level: SDRAM_DBG_CL set without the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "localparam integer SDRAM_DBG_CL = 0;", "localparam integer SDRAM_DBG_CL = 2;")

    @plant("top level: SDRAM_DBG_TRCD_TRP set without the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "localparam integer SDRAM_DBG_TRCD_TRP = 0;",
            "localparam integer SDRAM_DBG_TRCD_TRP = 3;")

    @plant("wiring: the tRCD/tRP override dropped at the bridge (sdram.v would build the derived value)")
    def _(root, cfg):
        sub(root / "src/memory/sdram_sync_bridge.sv", ".DBG_TRCD_TRP(DBG_TRCD_TRP)", "")

    @plant("qsf: the record gains dbg_sdram_cl2 the top level does not carry")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"', '"dbg_sdram_cl2":true,"name":"base"')

    @plant("qsf: the record gains sdram_phase_dyn the top level does not carry")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"', '"name":"base","sdram_phase_dyn":true')

    # hdmi_rclk: the clock-network line is part of the record, so the block must carry exactly it,
    # and no GLOBAL_SIGNAL line may exist outside the block.
    @plant("qsf: the record gains hdmi_rclk the block does not carry")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"', '"hdmi_rclk":true,"name":"base"')

    @plant("qsf: the pll_hdmi REGIONAL line dropped from the block by hand", tree="rclk")
    def _(root, cfg):
        sub(root / QSF_NAME, HDMI_RCLK_LINE + "\n", "")

    @plant("qsf: the pll_hdmi line edited to GLOBAL CLOCK by hand", tree="rclk")
    def _(root, cfg):
        sub(root / QSF_NAME, '"REGIONAL CLOCK"', '"GLOBAL CLOCK"')

    @plant("qsf: the record gains hdmi_rclk_q2 the block does not carry", tree="rclk")
    def _(root, cfg):
        sub(root / QSF_NAME, '"hdmi_rclk":true', '"hdmi_rclk":true,"hdmi_rclk_q2":true')

    @plant("qsf: the record asks hdmi_rclk_q2 without hdmi_rclk")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"', '"hdmi_rclk_q2":true,"name":"base"')

    @plant("qsf: a CLKCTRL location assignment outside the managed block")
    def _(root, cfg):
        sub(root / QSF_NAME, "source sys/sys.tcl", HDMI_RCLK_Q2_LINE + "\nsource sys/sys.tcl")

    @plant("qsf: a GLOBAL_SIGNAL assignment outside the managed block (no hdmi_rclk recorded)")
    def _(root, cfg):
        sub(root / QSF_NAME, "source sys/sys.tcl", HDMI_RCLK_LINE + "\nsource sys/sys.tcl")

    @plant("qsf: a second GLOBAL_SIGNAL outside the block beside a recorded hdmi_rclk", tree="rclk")
    def _(root, cfg):
        sub(root / QSF_NAME, "source sys/sys.tcl",
            HDMI_RCLK_LINE.replace("REGIONAL", "GLOBAL") + "\nsource sys/sys.tcl")

    configs = {
        "base": PROFILES["base"],
        "mediumoc": PROFILES["mediumoc"],
        # base itself is a CD build since 2026-10-10; the --no-cdrom opt-out is its own tree.
        "nocd": dataclasses.replace(PROFILES["base"], name="custom", preset="base", cdrom_en=False,
                                    cdrom_audio_en=False),
        "dbg": dataclasses.replace(PROFILES["base"], name="custom", preset="base", dbg=(
            ("cpu", True), ("snoop", "0x2fa00:0x2fc00"), ("trig", "reload:0x2fb20"),
            ("trig2", "0x3d900:0x3da00"), ("gdc", True))),
        "over": dataclasses.replace(PROFILES["base"], name="custom", preset="base", qsf_set=(
            ("PHYSICAL_SYNTHESIS_REGISTER_RETIMING", QSF_SET_DEFAULT),
            ("ROUTER_TIMING_OPTIMIZATION_LEVEL", "MAXIMUM"),
            ("OPTIMIZATION_MODE", "AGGRESSIVE PERFORMANCE"))),
        "rclk": dataclasses.replace(PROFILES["base"], name="custom", preset="base", hdmi_rclk=True),
        "sdph": dataclasses.replace(PROFILES["base"], name="custom", preset="base",
                                    sdram_phase_dyn=True),
        "packed": dataclasses.replace(PROFILES["base"], name="custom", preset="base",
                                      sdram_dq_ddio=False),
        "packedout": dataclasses.replace(PROFILES["base"], name="custom", preset="base",
                                         sdram_out_ddio=False),
    }
    failures = 0

    # The preset contract: every preset runs the SDRAM on clk_sys, base is 90 MHz, and a custom
    # clock moves the SDRAM with it.
    contract_parser = argparse.ArgumentParser(add_help=False)
    add_override_args(contract_parser)
    want_hz = {"base": 90_000_000, "trace": 90_000_000, "iofaithful": 90_000_000,
               "mediumoc": 100_000_000, "heavyoc": 120_000_000}
    if set(want_hz) != set(PROFILES):
        print(f"SELFTEST FAIL: preset contract names {sorted(want_hz)}, PROFILES has "
              f"{sorted(PROFILES)}")
        failures += 1
    for argv, want in (*(([n], hz) for n, hz in want_hz.items()),
                       (["--custom", "--clk-sys-mhz", "90"], 90_000_000)):
        got_cfg = resolve_config(None if argv[0].startswith("--") else argv[0],
                                 contract_parser.parse_args(
                                     argv if argv[0].startswith("--") else argv[1:]))
        req = got_cfg.pll_request()
        if got_cfg.clk_sys_hz != want or req.clk_sys_hz != want:
            print(f"SELFTEST FAIL: preset contract {' '.join(argv)} -> clk_sys "
                  f"{got_cfg.clk_sys_hz}, want {want}")
            failures += 1
        else:
            print(f"selftest: preset contract {' '.join(argv)} -> {want // 10**6} MHz clk_sys = SDRAM")
    # The CD contract: every preset builds the drive with its CD-DA player, none carries the debug
    # command log, and --no-cdrom / --no-cdrom-audio still opt out.
    for name, preset in PROFILES.items():
        if preset.dbg:
            print(f"SELFTEST FAIL: preset {name} builds a debug instrument ({dict(preset.dbg)}): "
                  "the framework is off in every preset")
            failures += 1
        if not (preset.cdrom_en and preset.cdrom_audio_en) or preset.cdrom_log_en:
            print(f"SELFTEST FAIL: preset {name} is not a full CD build without the log "
                  f"(cdrom_en {preset.cdrom_en}, cdrom_audio_en {preset.cdrom_audio_en}, "
                  f"cdrom_log_en {preset.cdrom_log_en})")
            failures += 1
    print(f"selftest: CD contract - all {len(PROFILES)} presets build the CD drive + CD-DA, no log")
    # The phase-instrument contract: off in every preset; --dbg-sdram-phase turns it on below
    # 100 MHz and is refused with the DDIO SDRAM_CLK; the RTL's on-arms hold the instances, so
    # the non-default value reaches them (a dropped branch cannot fall back silently).
    for name, preset in PROFILES.items():
        if preset.sdram_phase_dyn or preset.pll_request().dps:
            print(f"SELFTEST FAIL: preset {name} builds the SDRAM phase instrument")
            failures += 1
    got_cfg = resolve_config("base", contract_parser.parse_args(["--dbg-sdram-phase"]))
    if not (got_cfg.sdram_phase_dyn and got_cfg.pll_request().dps
            and got_cfg.record().get("sdram_phase_dyn") is True):
        print("SELFTEST FAIL: base --dbg-sdram-phase does not build the instrument")
        failures += 1
    if "sdram_phase_dyn" in PROFILES["base"].record():
        print("SELFTEST FAIL: the base record names sdram_phase_dyn (it must appear only when set)")
        failures += 1
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            resolve_config("mediumoc", contract_parser.parse_args(["--dbg-sdram-phase"]))
    except SystemExit:
        print("selftest: mediumoc --dbg-sdram-phase is refused (DDIO SDRAM_CLK)")
    else:
        print("SELFTEST FAIL: mediumoc --dbg-sdram-phase is accepted")
        failures += 1
    for name, preset in PROFILES.items():
        if preset.dbg_sdram_cl2 or preset.dbg_sdram_trcd:
            print(f"SELFTEST FAIL: preset {name} overrides the SDRAM timing table")
            failures += 1
    got_cfg = resolve_config(None, contract_parser.parse_args(
        ["--custom", "--clk-sys-mhz", "100", "--dbg-sdram-cl2", "--dbg-sdram-trcd-cycles", "3",
         "--dbg-sdram-phase"]))
    lines = {n: l for n, _, l in top_localparams(got_cfg)}
    if (got_cfg.sdram_clk_ddio or lines["SDRAM_DBG_CL"] != "localparam integer SDRAM_DBG_CL = 2;"
            or lines["SDRAM_DBG_TRCD_TRP"] != "localparam integer SDRAM_DBG_TRCD_TRP = 3;"
            or "-invert" in render_config_sdc(got_cfg).split("create_generated_clock", 1)[1][:200]
            or not got_cfg.pll_request().dps
            or "cyclonev_pll|counter[1].output_counter*|divclk" not in render_config_sdc(got_cfg)):
        print("SELFTEST FAIL: the 100 MHz CL2 test point is not CL2 + phase-shifted SDRAM_CLK + tRCD 3")
        failures += 1
    else:
        print("selftest: 100 MHz --dbg-sdram-cl2 --dbg-sdram-trcd-cycles 3 --dbg-sdram-phase resolves")
    # A tRCD/tRP override sdram.v refuses: tRP above CAS + 2 (a read's exits start the next row
    # command CAS + 3 clocks after the last READ), and one short of the write exit's tRC.
    for argv in (["--custom", "--clk-sys-mhz", "100", "--dbg-sdram-cl2", "--dbg-sdram-trcd-cycles", "5"],
                 ["--custom", "--clk-sys-mhz", "90", "--dbg-sdram-trcd-cycles", "5"],
                 ["--custom", "--clk-sys-mhz", "120", "--dbg-sdram-trcd-cycles", "6"],
                 ["--custom", "--clk-sys-mhz", "90", "--dbg-sdram-trcd-cycles", "1"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                resolve_config(None, contract_parser.parse_args(argv))
        except SystemExit:
            print(f"selftest: {' '.join(argv)} is refused (sdram.v's table checks)")
        else:
            print(f"SELFTEST FAIL: {' '.join(argv)} is accepted, but sdram.v refuses its table")
            failures += 1
    for argv in (["--custom", "--clk-sys-mhz", "100", "--dbg-sdram-cl2", "--dbg-sdram-trcd-cycles", "4"],
                 ["--custom", "--clk-sys-mhz", "100", "--dbg-sdram-cl2", "--dbg-sdram-trcd-cycles", "2"],
                 ["--custom", "--clk-sys-mhz", "133"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                resolve_config(None, contract_parser.parse_args(argv))
        except SystemExit:
            print(f"SELFTEST FAIL: {' '.join(argv)} is refused, but sdram.v builds its table")
            failures += 1
        else:
            print(f"selftest: {' '.join(argv)} resolves")
    failures += sdram_table_selftest()
    sys_text = (PROJECT_DIR / "src/pc9821/core/pc9821_system.sv").read_text()
    top_arm = re.search(r"generate if \(SDRAM_PHASE_DYN\) begin : g_sdph_dps(.*?)end else begin",
                        (PROJECT_DIR / TOP_NAME).read_text(), re.S)
    sys_arm = re.search(r"if \(SDRAM_PHASE_DYN\) begin : g_sdph(.*?)end else begin", sys_text, re.S)
    if (not top_arm or "pc9821_sdram_dps" not in top_arm.group(1) or not sys_arm
            or "pc9821_sdram_phase_ctl" not in sys_arm.group(1)
            or ".SDRAM_PHASE_DYN(SDRAM_PHASE_DYN)" not in sys_text):
        print("SELFTEST FAIL: the SDRAM_PHASE_DYN on-arms do not hold the instrument's instances")
        failures += 1
    else:
        print("selftest: SDRAM phase instrument off in every preset; its on-arms hold the instances")
    # The hdmi_rclk contract: the block carries the line exactly when the field is set, and a
    # re-apply without it strips the line.
    for on in (False, True):
        blk = render_qsf_block(dataclasses.replace(PROFILES["base"], hdmi_rclk=on))
        left = [line for line in remove_managed_qsf_content(blk + "\n").splitlines()
                if GLOBAL_SIGNAL_LINE_RE.match(line)]
        if (HDMI_RCLK_LINE in blk.splitlines()) != on or left:
            print(f"SELFTEST FAIL: hdmi_rclk={on}: block line present "
                  f"{HDMI_RCLK_LINE in blk.splitlines()}, {len(left)} line(s) survive a re-apply")
            failures += 1
    print("selftest: hdmi_rclk contract - the REGIONAL line follows the field and is stripped on re-apply")
    # The debug-framework contract: the options resolve to the localparams the RTL takes, a bad
    # combination is refused, and a spec that cannot mean what it says never reaches the top level.
    for argv, want in ((["base", "--dbg-snoop", "2fa00:2fc00"], {"snoop_en": 1, "snoop_lo": 0x2fa00, "snoop_hi": 0x2fc00}),
                       (["base", "--dbg-trig", "pc:f800:1234"], {"trig_kind": 1, "trig_cs": 0xf800, "trig_addr": 0x1234}),
                       (["base", "--dbg-trig", "wr:1002", "--dbg-post", "100"], {"trig_kind": 2, "trig_addr": 0x1002, "post": 100}),
                       (["base", "--dbg-cpu", "--dbg-sample-ms", "5"], {"cpu": 1, "sample_ms": 5}),
                       (["base", "--gdc-log"], {"gdc": 1})):
        got_cfg = resolve_config(argv[0], contract_parser.parse_args(argv[1:]))
        bad = {k: (got_cfg.dbg_params[k], v) for k, v in want.items() if got_cfg.dbg_params[k] != v}
        if bad:
            print(f"SELFTEST FAIL: {' '.join(argv)} resolves to {bad} (got, want)")
            failures += 1
        else:
            print(f"selftest: {' '.join(argv)} -> {want}")
    for argv in (["base", "--trace", "--dbg-cpu"], ["base", "--dbg-trig2", "1000:2000"],
                 ["base", "--perf-log", "--dbg-cd"], ["base", "--trace", "--dbg-cd"],
                 ["base", "--no-cdrom", "--cdrom-audio"], ["base", "--no-cdrom", "--dbg-cd"],
                 ["base", "--dbg-snoop", "2000:1000"], ["base", "--dbg-trig", "jump:1"],
                 ["base", "--dbg-sample-ms", "5"], ["base", "--dbg-post", "9"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                resolve_config(argv[0], contract_parser.parse_args(argv[1:]))
        except SystemExit:
            print(f"selftest: {' '.join(argv)} is refused")
        else:
            print(f"SELFTEST FAIL: {' '.join(argv)} is accepted")
            failures += 1
    for argv, field in ((["base", "--no-cdrom"], "cdrom_en"),
                        (["base", "--no-cdrom-audio"], "cdrom_audio_en")):
        got_cfg = resolve_config(argv[0], contract_parser.parse_args(argv[1:]))
        if getattr(got_cfg, field):
            print(f"SELFTEST FAIL: {' '.join(argv)} still sets {field}")
            failures += 1
        else:
            print(f"selftest: {' '.join(argv)} opts out ({field} off)")
    if not (PROFILES["base"].mpu_en and PROFILES["base"].alsa_en):
        print("SELFTEST FAIL: base must carry the MIDI card and the HPS audio")
        failures += 1
    for retired in ("--sdram-mhz", "--sdram-sync", "--no-sdram-sync"):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                contract_parser.parse_args([retired] + (["100"] if retired == "--sdram-mhz" else []))
        except SystemExit:
            print(f"selftest: the retired {retired} is refused")
        else:
            print(f"SELFTEST FAIL: the retired {retired} is still accepted")
            failures += 1
    # The SDRAM_CLK structure knob: derived from clk_sys in one place, off in every shipped
    # <100 MHz preset, on from 100 MHz, and the RTL's generate-if holds the DDIO cell in its on arm
    # (so the non-default value reaches the instance; a dropped branch cannot fall back silently).
    for pname, want in (("base", False), ("trace", False), ("mediumoc", True), ("heavyoc", True)):
        if PROFILES[pname].sdram_clk_ddio != want:
            print(f"SELFTEST FAIL: {pname} sdram_clk_ddio is {not want}, want {want}")
            failures += 1
    top_text = (PROJECT_DIR / TOP_NAME).read_text()
    arm = re.search(r"generate if \(SDRAM_CLK_DDIO\) begin : sdram_clk_ddio(.*?)end else begin", top_text, re.S)
    if not arm or "altddio_out" not in arm.group(1) or "assign SDRAM_CLK" in arm.group(1):
        print("SELFTEST FAIL: the top level's SDRAM_CLK_DDIO arm does not hold the altddio_out cell")
        failures += 1
    else:
        print("selftest: SDRAM_CLK_DDIO on-arm holds the DDIO cell; mediumoc/heavyoc on, base/trace off")
    with tempfile.TemporaryDirectory(prefix="build-profile-selftest-") as tmp:
        def fresh(cfg: Config) -> Path:
            root = Path(tmp) / "tree"
            shutil.rmtree(root, ignore_errors=True)
            root.mkdir()
            for name in (TOP_NAME, QSF_NAME, SDRAM_V, *(n for n, _ in DQ_DDIO_WIRING)):
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(PROJECT_DIR / name, root / name)
            (root / pg.VCLK_PKG).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT_DIR / pg.VCLK_PKG, root / pg.VCLK_PKG)
            apply_config(cfg, root, dry_run=False, generate=False)
            (root / SDC_NAME).write_text(render_config_sdc(cfg))
            _fake_pll(root, cfg)
            return root

        for tree, cfg in configs.items():
            clean = agreement(fresh(cfg), require_generated=True)
            if clean:
                print(f"SELFTEST FAIL: the clean {tree} tree reports problems:\n  "
                      + "\n  ".join(clean))
                failures += 1
            else:
                print(f"selftest: clean {tree} tree -> no problems")
        for label, fn, tree in plants:
            cfg = configs[tree]
            root = fresh(cfg)
            fn(root, cfg)
            found = agreement(root, require_generated=True)
            if found:
                print(f"selftest: caught  {label}: {found[0].splitlines()[0][:110]}")
            else:
                print(f"SELFTEST FAIL: missed {label}")
                failures += 1
    print(f"build_profile.py --selftest: {'PASS' if not failures else 'FAIL'} "
          f"({len(plants)} plants, {failures} failure(s))")
    return 1 if failures else 0


# ---------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------

def run_quartus() -> int:
    return subprocess.call(["quartus_sh", "--flow", "compile", PROJECT], cwd=PROJECT_DIR)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("profile", nargs="?", choices=sorted(PROFILES), help="the preset to apply")
    parser.add_argument("--list", action="store_true", help="list the presets")
    parser.add_argument("--show", action="store_true", help="show the recorded configuration")
    parser.add_argument("--check", action="store_true",
                        help="verify the top level, the qsf record, and (when present) the "
                             "generated PLL and SDC agree; exit 0/1")
    parser.add_argument("--tree", type=Path, default=PROJECT_DIR,
                        help="the tree --check/--show inspect (default: this checkout)")
    parser.add_argument("--require-generated", action="store_true",
                        help="with --check: the generated PLL and SDC must exist")
    parser.add_argument("--selftest", action="store_true",
                        help="plant PLL/SDC/top-level/qsf disagreements; --check must catch each")
    parser.add_argument("--pll-into", metavar="DIR", type=Path,
                        help="generate DIR's recorded configuration's PLL into DIR/rtl and its "
                             "SDC into DIR/; used by tools/build.py on its scratch tree")
    parser.add_argument("--print-config", action="store_true",
                        help="print the configuration the arguments resolve to (or the active "
                             "one) as JSON, and exit without changing anything")
    parser.add_argument("--quartus-check", action="store_true",
                        help="put the resolved (or the active) configuration's qsf_set to Quartus "
                             "in the container and report each verdict; exit 0/1")
    parser.add_argument("--no-generate", action="store_true",
                        help="apply without generating the PLL/SDC (no container needed)")
    parser.add_argument("--dry-run", action="store_true", help="print changes without writing")
    parser.add_argument("--compile", action="store_true", help="run quartus_sh after applying")
    add_override_args(parser)
    args = parser.parse_args(argv)
    has_config_args = bool(args.profile or override_argv(args))

    if args.list:
        for c in PROFILES.values():
            print(f"{c.name:10} {c.description}")
        return 0

    if args.selftest:
        return selftest()

    if args.print_config:
        config = resolve_config(args.profile, args) if has_config_args else active_config(args.tree)
        if config is None:
            raise SystemExit("no recorded configuration")
        print(config.record_json())
        return 0

    if args.quartus_check:
        config = resolve_config(args.profile, args) if has_config_args else active_config(args.tree)
        if config is None:
            raise SystemExit("no recorded configuration")
        problems = qsf_set_problems(config.qsf_set) or quartus_check_qsf_set(config.qsf_set)
        for problem in problems:
            print(f"QSF_SET: {problem}", file=sys.stderr)
        print(f"qsf_set: {len(config.qsf_set)} override(s), "
              f"{'REFUSED' if problems else 'all accepted by Quartus'}")
        return 1 if problems else 0

    if args.show:
        config = active_config(args.tree)
        print("No recorded configuration" if config is None else describe(config))
        return 0

    if args.check:
        problems = agreement(args.tree, require_generated=args.require_generated)
        for problem in problems:
            print(f"PROFILE MISMATCH: {problem}", file=sys.stderr)
        if problems:
            return 1
        config = active_config(args.tree)
        assert config is not None
        generated = (args.tree / SDC_NAME).exists() and (args.tree / "rtl/pll/pll_0002.v").exists()
        rb = pg.read_back(args.tree / "rtl") if generated else None
        print(f"profile agreement: '{config.name}' - top level, qsf record"
              f"{', generated PLL and SDC' if generated else ' (PLL/SDC not generated here)'} "
              f"agree: {describe(config, rb)}")
        return 0

    if args.pll_into:
        dest = args.pll_into
        config = active_config(dest) or active_config(PROJECT_DIR)
        if config is None:
            raise SystemExit(f"no '# Active config' record in {dest / QSF_NAME}; run "
                             "./build_profile.py <profile> first")
        rb = generate_outputs(config, dest)
        print(f"Generated {dest}/rtl/pll*, {dest}/rtl/vpll* and {dest}/{SDC_NAME}: {describe(config, rb)}")
        return 0

    if not has_config_args:
        parser.error("choose a preset (or --custom / --profile-file / overrides), or "
                     "--list/--show/--check")
    config = resolve_config(args.profile, args)
    apply_config(config, PROJECT_DIR, dry_run=args.dry_run, generate=not args.no_generate)
    if args.compile and not args.dry_run:
        return run_quartus()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
