# EGC conformance / fingerprint suite v1.3 - real-hardware captures

These are **real PC-9821 hardware** captures, so they sit at the TOP of this
repo's evidence hierarchy (AGENTS.md, "Evidence": real hardware beats
NP2kai, qemu-pc98, MAME and our own RTL). They are the oracle for the EGC
compare / colour-key work and for `tb_pc9821_egc_compare`.

## What ran, on what

`PC98_EGC_CONFORMANCE, version=1.3`, run as `RUNALL.BAT` (the full profile):
six DOS programs, each writing a CSV of one row per test plus a summary line in
the CSV header.

| file | what it covers |
|---|---|
| `EGCALL.CSV` | every group in one run (a superset of the other five) |
| `EGCREAD.CSV` | read / compare / read-shifter / colour-key |
| `EGCWRITE.CSV` | write / ALU / PLOAD_W / write-shifter / state |
| `EGCROP.CSV` | all 256 ternary ROPs |
| `EGCSHFT.CSV` | write shifter and length |
| `EGCQUIRK.CSV` | legacy / reserved-register fingerprints |

- `xe10/` - a real PC-9821 (V166 chipset, "xe10"), the ORACLE.
- `mister/` - this core (MiSTer) on the same binaries, baseline for the gap.

`README.TXT` and `FINGERPR.TXT` are the suite's own text files; they ship with
the results. `*.RC`, `SUMMARY.TXT` and `FAILED.TXT` are its verdict files
(`ALL.RC` = `EGCALL=1`, i.e. one FAIL row in the combined group, which the Xe10
shares with this core - see below).

The suite's developer documentation and host-side decoders are not in the
distribution, so the semantics in the RTL comments are derived from these CSVs
plus NP2kai (`../NP2kai/io/egc.c`, `../NP2kai/mem/memegc.c`) and MAME
(`src/mame/nec/pc9801_v.cpp`), and any disagreement is recorded where the RTL
touches it.

## CSV format

```
# PC98_EGC_CONFORMANCE,version=1.3,group=<group>
# SUMMARY,pass=N,fail=N,info=N
id,status,detail,aB,aR,aG,aI,eB,eR,eG,eI
```

`a*` are the four PLANE values the test read back (actual), `e*` the suite's own
expectation. `status` is PASS / FAIL / INFO; **INFO is not an error** - it
preserves behaviour the suite does not claim one model for, and is a
fingerprint, not an oracle. A FAIL that also fails on the Xe10 is not a bug
here: `W50_CPU_H` (`byte-WOP-CPU-addressed-lane-only`) fails on BOTH machines
and is left alone.

The two machines' CSVs are byte-identical for `EGCROP.CSV` (256/256 PASS) and
`EGCSHFT.CSV` (276/278 PASS), so the ROP and shifter arithmetic already agree
with the hardware.

## Oracle size and use

2,612 rows carry a hardware expectation. The compare/colour-key gap (Xe10 PASS
and this core not-PASS) was 524 rows against the RTL that made this capture: 262
in `EGCALL`, 238 in `EGCREAD`, 16 in `EGCQUIRK`, 8 in `EGCWRITE`. Of the 262
`EGCALL` ids, 241 are now replayed by
`tools/gen_egc_compare_vectors.py`, which reads the `xe10/` and `mister/` CSVs,
RECONSTRUCTS each covered family's stimulus from the hardware's own answers and
generates `tests/pc9821/egc_xe10_vectors.svh` for `tb_pc9821_egc_compare` (and
`tb_pc9821_egc_regs`) to replay. Run `python3
tools/gen_egc_compare_vectors.py --check` after touching anything that feeds
those vectors.

The nine ids still not replayed are named on that tool's stdout, and each has a
reason: `RD02_PAT_S0..S3` (covered by `tb_pc9821_egc_compare`'s PLOAD_R section)
and `W00/W01` (covered by `tb_pc9821_egc_regs` section D) come from the two small
families the generator emits separately, and `CK02_M0/M1/D0/D1`, `CK03_M_L/M_H`
and `CK04_MASK/DST` have their stored quad genuinely underdetermined - the masks
and the destination column admit many solutions (tried: the compare model with
the write's data as the CPU datum), so no stimulus can be reconstructed from the
capture alone. `RD22_PATSEL`'s own two columns do not fix its pattern either; what
it does fix is that bit 13 compares with the pattern source set to PAT, which is
the stimulus every replayed compare row is driven with.

Two findings from reading these columns, both recorded in the RTL
rather than here: the compare is active in the PAT mode (bit 13 is the
whole gate - `RD22_PATSEL` expects the retained-FG mask there), and the
`CK00/CK01 *_DST` rows are a SOFTWARE masked write, not a hardware overlay: the
suite reads the compare mask, stores it in `0x04A8` and writes a fixed data
pattern, and `dst = (src & ~mask) | (data & mask)` reproduces all 21 rows (the
written data solves to `A55A/3CC3/5AA5/9669`).

The `EGC*.EXE` binaries are third-party and are NOT committed here - only the
results they produced.
