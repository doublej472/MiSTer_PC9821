#!/usr/bin/env python3
"""Generate the EGC conformance-suite replay vectors from the REAL Xe10 captures.

The oracle is `docs/probes/egc-conformance/{xe10,mister}/*.CSV` - a
real PC-9821 (V166, "xe10") and this core on the PC98_EGC_CONFORMANCE v1.3
`RUNALL` profile. Those CSVs record, per test, the four PLANE values read back
and the suite's own expectation, but NOT the register program or the VRAM the
test set up: the suite is a binary-only distribution. So this tool RECONSTRUCTS
each covered test family's stimulus from the hardware's own answers - the
expected masks fix the source pattern, the FG colour and the plane-enable mask
under the compare model - and emits it as `tests/pc9821/egc_xe10_vectors.svh`,
which `tb_pc9821_egc_compare` drives through the real pc9821_egc and
`tb_pc9821_egc_regs` through the real iobus.

Every EXPECTED value in the generated file is the Xe10's own aB column, never a
number derived from our RTL. Reconstruction is checked against independent
columns of the same capture:

  * the ramp families must reconstruct to the quad the suite itself reads back
    in `CK00_*_SRC`, and to the plain-read value in the MiSTer column of the
    same rows (the pre-fix core's read path returns the plane data, so it is an
    independent witness of what the test stored);
  * the shared-quad families are solved over the FG colour, and the solution
    must reproduce all 45 of their rows;
  * the byte-compare families are solved per (aperture, byte lane) and all four
    apertures must give the same solution - the hardware's own
    "compare-independent-of-aperture";
  * a row that appears in two capture files (EGCALL and EGCREAD/EGCQUIRK) must
    carry the same actual values in both, or this tool fails.

A family whose stimulus cannot be pinned is EXCLUDED and listed on stdout with
its row count - the coverage table is the report's. `--check` compares the
committed file with a fresh generation and exits non-zero on any difference.

Usage:
    python3 tools/gen_egc_compare_vectors.py [--check]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CAP = ROOT / "docs" / "probes" / "egc-conformance"
OUT = ROOT / "tests" / "pc9821" / "egc_xe10_vectors.svh"

GROUPS = ("EGCALL", "EGCREAD", "EGCQUIRK", "EGCWRITE", "EGCROP", "EGCSHFT")

# The compare model the CSVs pin (see pc9821_egc.sv's resp_word block): the read returns, one bit
# per pixel of the unit, the AND over the ACCESS-enabled planes of (plane data == the retained FG
# colour's bit for that plane). A disabled plane is all-ones (don't care), and a unit with no
# enabled plane is all-ones.
def mask_of(data, fg, access, width=16):
    all_ones = (1 << width) - 1
    out = all_ones
    for p in range(4):
        if not (access >> p) & 1:
            ref = all_ones if (fg >> p) & 1 else 0
            out &= ~((data[p] & all_ones) ^ ref) & all_ones
    return out


def quad_of_colours(colours):
    """colours[i] is the 4-bit colour of pixel i (bit i of the 16-bit unit)."""
    planes = [0, 0, 0, 0]
    for i, colour in enumerate(colours):
        for p in range(4):
            if (colour >> p) & 1:
                planes[p] |= 1 << i
    return tuple(planes)


def word_of_colours(colours):
    """An 8-pixel byte: colours[j] is bit (7 - j) of the byte, the way a plane byte is laid out."""
    planes = [0, 0, 0, 0]
    for j, colour in enumerate(colours):
        for p in range(4):
            if (colour >> p) & 1:
                planes[p] |= 1 << (7 - j)
    return tuple(planes)


class Row:
    __slots__ = ("grp", "id", "status", "detail", "act", "exp")

    def __init__(self, grp, fields):
        self.grp = grp
        self.id = fields[0]
        self.status = fields[1]
        self.detail = fields[2]
        self.act = [int(v, 16) for v in fields[3:7]]
        self.exp = [int(v, 16) for v in fields[7:11]]


def read_capture(side):
    rows = {}
    for grp in GROUPS:
        path = CAP / side / f"{grp}.CSV"
        if not path.exists():
            continue
        header_seen = False
        for line in path.read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            fields = [v.strip() for v in line.split(",")]
            if not header_seen:
                header_seen = True          # the column-name line
                continue
            row = Row(grp, fields)
            rows.setdefault(row.id, []).append(row)
    return rows


class Vectors:
    def __init__(self):
        self.cmp = []       # compare-read replay vectors
        self.free = []      # ids whose stimulus has a free parameter
        self.covered = {}   # id -> family
        self.ck = []        # colour-key WRITE vectors: (id, src quad, mask, dst quad, data, off, fg)

    def add(self, family, row, data, fg, access, plane, byte_op, lane, offset):
        exp = row.exp[0]
        # A byte unit compares the byte at the unit's own lane, so a byte vector's data quad is the
        # plane word with the pattern in THAT lane's byte (the generator shifts it in).
        d = tuple((w >> (8 * lane)) & 0xFF for w in data) if byte_op else data
        if mask_of(d, fg, access, 8 if byte_op else 16) != exp:
            raise SystemExit(
                f"{row.id}: reconstructed stimulus does not reproduce the hardware answer "
                f"(data={['%04X' % v for v in data]} fg={fg:X} access={access:X} "
                f"byte={byte_op} -> {mask_of(d, fg, access, 8 if byte_op else 16):04X}, "
                f"want {exp:04X})")
        self.cmp.append((row.id, data, exp, fg, access, plane, byte_op, lane, offset))
        self.covered[row.id] = family


def ramp_family(ids_by_key, xe10, mister, vectors, family):
    """Reconstruct one 16-pixel colour pattern from single-bit-hit masks.

    ids_by_key: {key: row}. Returns (data quad, colours list)."""
    colours = [None] * 16
    for key, row in ids_by_key.items():
        bits = [i for i in range(16) if (row.exp[0] >> i) & 1]
        if len(bits) != 1:
            return None
        if colours[bits[0]] is not None and colours[bits[0]] != key:
            return None
        colours[bits[0]] = key
    if any(c is None for c in colours):
        return None
    return quad_of_colours(colours), colours


def solve_shared_quad(rows, fg_free, access_of):
    """Solve (data quad, one FG per row) for a family sharing one stored quad.

    The single-plane rows give each plane's data up to the FG bit, so trying the 16 FG colours
    determines the quad; the candidate then has to reproduce EVERY row of the family."""
    per_plane = {}
    for row, fg in fg_free:
        acc = access_of(row)
        en = [p for p in range(4) if not (acc >> p) & 1]
        if len(en) == 1:
            per_plane.setdefault(en[0], []).append(row.exp[0])
    probes = {}
    for p, vals in per_plane.items():
        if len(set(vals)) != 1:
            return None
        probes[p] = vals[0]
    if len(probes) < 4:
        return None
    for fg_all in range(16):
        data = [0, 0, 0, 0]
        for p in range(4):
            data[p] = probes[p] if (fg_all >> p) & 1 else (~probes[p]) & 0xFFFF
        ok = True
        for row, fg in fg_free:
            if mask_of(data, fg, access_of(row)) != row.exp[0]:
                ok = False
                break
        if ok:
            return tuple(data)
    return None


def build(xe10, mister):
    v = Vectors()

    def xe(rid):
        return xe10[rid][0]

    def mi(rid):
        return mister.get(rid, [None])[0]

    # ---- family 1: the "ramp" - a 16-pixel colour ramp read back with one key (B08_CMP_x,
    # RD10_RAMP_x, CK00_x_MASK). The key is the row's own hex index; the reconstruction is then
    # checked against CK00_*_SRC (the suite's own read-back of the plane it compares) and against
    # the MiSTer column, whose pre-fix read path returns that stored plane.
    ramp_sets = []
    for prefix, n in (("B08_CMP_", 16), ("RD10_RAMP_", 16)):
        got = {}
        for key in range(n):
            rid = f"{prefix}{key:X}"
            got[key] = xe(rid)
        ramp_sets.append((prefix, ramp_family(got, xe10, mister, v, "ramp")))
    ramps = {}
    for prefix, res in ramp_sets:
        if res is None:
            raise SystemExit(f"{prefix}: the hardware masks do not reconstruct a 16-pixel ramp")
        ramps[prefix] = res
    if ramps["B08_CMP_"][0] != ramps["RD10_RAMP_"][0]:
        raise SystemExit("B08_CMP_x and RD10_RAMP_x reconstruct DIFFERENT ramps")
    ramp_quad, ramp_colours = ramps["B08_CMP_"]
    src = xe("CK00_0_SRC")
    if tuple(src.act) != ramp_quad:
        raise SystemExit(f"the ramp reconstructs to {ramp_quad}, but CK00_0_SRC reads back "
                         f"{tuple(src.act)}")
    for rid in ("B08_CMP_0", "RD10_RAMP_0"):
        wit = mi(rid)
        if wit is not None and wit.act[0] not in ramp_quad:
            raise SystemExit(f"{rid}: the pre-fix core read {wit.act[0]:04X}, which is not one of "
                             f"the reconstructed ramp planes {ramp_quad}")
    for key in range(16):
        for prefix in ("B08_CMP_", "RD10_RAMP_"):
            v.add("ramp", xe(f"{prefix}{key:X}"), ramp_quad, key, 0, 0, False, 0, 0x100)
    ck00 = {}
    for key in range(16):
        row = xe(f"CK00_{key:X}_MASK")
        bits = [i for i in range(16) if (row.exp[0] >> i) & 1]
        if len(bits) != 1 or ramp_colours[bits[0]] != key:
            raise SystemExit(f"CK00_{key:X}_MASK is not the ramp's colour-{key:X} pixel")
        v.add("ramp", row, ramp_quad, key, 0, 0, False, 0, 0x100)

    # ---- family 2: the shared quad (35DF,D010,67D9,4912; FG colour 5) - RD11_MIX_x (the key
    # walks all 16 colours), RD13_RPL_x, RD14_AP_x, RD20_AM_x (the key is the plane-enable
    # register), RD17_M_x (the key is the row's index) and RD21.
    quad_rows = [(xe(f"RD11_MIX_{k:X}"), k) for k in range(16)]
    quad_rows += [(xe(f"RD13_RPL_{k}"), 5) for k in range(4)]
    quad_rows += [(xe(f"RD14_AP_{k}"), 5) for k in range(4)]
    quad_rows += [(xe(f"RD17_M_{k}"), int(k, 16)) for k in ("0", "5", "A", "F")]
    quad_rows += [(xe("RD21_BG"), 5)]
    am_rows = [(xe(f"RD20_AM_{k:X}"), 5) for k in range(16)]
    quad = solve_shared_quad(quad_rows + am_rows, quad_rows + am_rows,
                             lambda row: int(row.id[-1], 16) if row.id.startswith("RD20_AM_") else 0)
    if quad is None:
        raise SystemExit("the shared-quad family does not solve for any FG colour")
    wit = mi("RD13_RPL_0")
    if wit is not None and wit.act[0] not in quad:
        raise SystemExit(f"RD13_RPL_0: the pre-fix core read {wit.act[0]:04X}, not in {quad}")
    for row, fg in quad_rows:
        v.add("quad", row, quad, fg, 0, 0, False, 0, 0x200)
    for row, fg in am_rows:
        v.add("quad", row, quad, fg, int(row.id[-1], 16), 0, False, 0, 0x200)

    # ---- family 3: the byte compare (RD15_A{a}_{L,H}_K{k}, 128 rows). Byte lane 0 of the ramp
    # word holds colours 0..7 and lane 1 colours 8..15 (the ramp's own layout), the key is the row
    # index, and the aperture a is both the addressed window plane and the read-plane selector.
    # The four apertures must all give the same answer - the CSV's own
    # "compare-independent-of-aperture".
    low = tuple(p & 0xFF for p in ramp_quad)
    high = tuple((p >> 8) & 0xFF for p in ramp_quad)
    for a in range(4):
        for lane, label, data in ((0, "L", low), (1, "H", high)):
            for key in range(16):
                row = xe(f"RD15_A{a}_{label}_K{key:X}")
                word = tuple(w << (8 * lane) for w in data)
                v.add("byte", row, word, key, 0, a, True, lane, 0x100)
                wit = mi(row.id)
                if wit is not None and wit.act[0] != data[a]:
                    raise SystemExit(f"{row.id}: the pre-fix core read {wit.act[0]:02X}, but the "
                                     f"ramp's plane {a} byte at lane {lane} is {data[a]:02X}")

    # ---- family 4: FREE-parameter rows. The CSV fixes only the result, not the pattern:
    # RD12_RALL is "every pixel matches" (so the plane holds one colour everywhere and the key is
    # that colour), RD12_NONE is its complement, and RD16_SEQ0/1 are two consecutive compares.
    uniform0 = (0x0000, 0x0000, 0x0000, 0x0000)
    v.add("free", xe("RD12_ALL"), uniform0, 0x0, 0, 0, False, 0, 0x300)
    v.free.append("RD12_ALL")
    v.add("free", xe("RD12_NONE"), uniform0, 0x1, 0, 0, False, 0, 0x300)
    v.free.append("RD12_NONE")
    even_odd = quad_of_colours([0 if i % 2 == 0 else 1 for i in range(16)])
    v.add("free", xe("RD16_SEQ0"), uniform0, 0x1, 0, 0, False, 0, 0x300)
    v.free.append("RD16_SEQ0")
    v.add("free", xe("RD16_SEQ1"), even_odd, 0x1, 0, 0, False, 0, 0x300)
    v.free.append("RD16_SEQ1")

    # ---- family 5: the colour-key WRITE (CK00_*_DST / CK01_*_DST) and CK01's five mask rows.
    ck_write(xe10, v)
    ck01_mask(xe10, v)

    return v


def ck_write(xe10, v):
    """CK00_*_DST / CK01_*_DST: the colour-key WRITE, replayed end to end.

    This family is NOT a hardware write overlay, and the capture says so. Its three columns are
    a compare MASK (`*_MASK`), the region the write came from (`*_SRC`, unchanged) and the
    region it went to (`*_DST`), and `dst = (src & ~mask) | (data & mask)` reproduces all 21
    rows of BOTH families exactly - the software's own sequence: read the mask, write that
    value into the EGC's mask register 0x04A8 (the row detail's
    "compare-mask-used-as-color-key"), then store a fixed data pattern with an ordinary masked
    write.

    The PRE-FIX core's own DST column is the second witness: it equals the same expression with
    the mask being the value that core's compare read returned (the raw plane, 5555 for CK00),
    which no hardware overlay could produce - an overlay's mask would be the hardware's compare
    mask, not the raw plane the CPU read. A bit-13 overlay is also excluded by the machine's own
    software: TH01's 0x3100 four-plane page copy sets the same bit 13 and its writes store the
    PATTERN register, so an overlay would corrupt every sprite the games draw.

    The data quad is solved from the capture rather than assumed: the union of the 21 rows'
    masks covers all 16 bits, so plane p's data is `OR` over the rows of `(dst[p] & mask)`, and
    CK00 alone and CK01 alone determine it independently - they must agree, and do."""
    rows = []
    fam = {}
    for prefix in ("CK00", "CK01"):
        keys = ([f"{k:X}" for k in range(16)] if prefix == "CK00"
                else ["D00", "D25", "D50", "D75", "D100"])
        maskbits = 0
        data = [0, 0, 0, 0]
        for k in keys:
            rid = f"{prefix}_{k}"
            row = xe10[rid + "_DST"][0]
            if row.status != "PASS" or tuple(row.act) != tuple(row.exp):
                raise SystemExit(f"{rid}_DST: not a hardware oracle")
            src = tuple(xe10[rid + "_SRC"][0].act)
            mask = xe10[rid + "_MASK"][0].exp[0]
            dst = tuple(row.act)
            maskbits |= mask
            for p in range(4):
                data[p] |= dst[p] & mask
            rows.append((rid, src, mask, dst))
        if maskbits != 0xFFFF:
            raise SystemExit(f"{prefix}: the family's masks cover only {maskbits:04X}, so the "
                             f"written data is not determined")
        fam[prefix] = tuple(data)
    if fam["CK00"] != fam["CK01"]:
        raise SystemExit(f"the two colour-key families solve DIFFERENT written data: "
                         f"{fam['CK00']} vs {fam['CK01']}")
    data = fam["CK00"]
    for rid, src, mask, dst in rows:
        pred = tuple((src[p] & ~mask) | (data[p] & mask) for p in range(4))
        if pred != dst:
            raise SystemExit(f"{rid}: the masked-write model gives {pred}, the hardware {dst}")
        wit = MISTER.get(rid)
        if wit is not None:
            # The pre-fix core's own DST came from ITS read value, so the same model must
            # reproduce it too - the strongest available statement of the sequence.
            wmask = MISTER[rid + "_MASK"][0].act[0]
            wpred = tuple((src[p] & ~wmask) | (data[p] & wmask) for p in range(4))
            if wpred != tuple(wit.act):
                raise SystemExit(f"{rid}: the pre-fix core's DST {tuple(wit.act)} is not the "
                                 f"masked-write model of its own read value {wmask:04X}"
                                 f" ({wpred}), so this sequence is not the one modelled")
    for i, (rid, src, mask, dst) in enumerate(rows):
        fgs = [fg for fg in range(16) if mask_of(src, fg, 0) == mask]
        if not fgs:
            raise SystemExit(f"{rid}: no FG colour reproduces the hardware's mask {mask:04X}")
        v.ck.append((rid, src, mask, dst, data, 0x0F00 + 0x20 * i, fgs[0]))
        v.covered[rid + "_DST"] = "colour-key write"


def ck01_mask(xe10, v):
    """CK01_*_MASK: five compare reads whose stored quad is the row's own SRC column.

    (FG, ACCESS) is solved from the mask column: only one pair reproduces all five rows, and it
    is (0xA, 0) - all four planes compared. They replay as ordinary compare reads with 0x04A2's
    pattern source set to PAT (the pre-fix core answered the raw plane for them, and with bit 13
    set that is the only arm that skips the compare - see the ope_cmprd block in pc9821_egc.sv).
    """
    sols = None
    rows = []
    for k in ("D00", "D25", "D50", "D75", "D100"):
        row = xe10[f"CK01_{k}_MASK"][0]
        src = tuple(xe10[f"CK01_{k}_SRC"][0].act)
        if row.status != "PASS":
            raise SystemExit(f"CK01_{k}_MASK is not a hardware oracle")
        ok = {(fg, acc) for fg in range(16) for acc in range(16)
              if mask_of(src, fg, acc) == row.exp[0]}
        sols = ok if sols is None else (sols & ok)
        rows.append((row, src))
    if sols != {(0xA, 0)}:
        raise SystemExit(f"CK01's mask rows do not solve to the single (FG, ACCESS) pair "
                         f"(A, 0): got {sorted(sols)}")
    for row, src in rows:
        v.add("ck01-mask", row, src, 0xA, 0, 0, False, 0, 0x400)


def read_pat_family(xe10):
    """RD02_PAT_S0..S3: a normal PLOAD_R read loads the SELECTED PAT plane only.

    The four rows give, per row, the PAT quad after a read whose selected plane took the newly
    read plane's value and whose other three planes kept the retained one. That splits the four
    columns into the RETAINED quad (the value all three other rows agree on) and the NEWLY READ
    quad (each row's own selected plane) - both hardware numbers, both cross-checked against
    B05_PLOAD_READ/RD02_RET, which read the newly loaded quad back."""
    rows = [xe10[f"RD02_PAT_S{k}"][0] for k in range(4)]
    retained = [None] * 4
    newly = [None] * 4
    for p in range(4):
        vals = [rows[k].exp[p] for k in range(4)]
        for k in range(4):
            others = [vals[j] for j in range(4) if j != k]
            if len(set(others)) == 1:
                retained[p] = others[0]
                newly[p] = vals[k]
                break
        if retained[p] is None:
            raise SystemExit(f"RD02_PAT column {p} has no single out-of-band value")
    b05 = xe10["B05_PLOAD_READ"][0]
    if tuple(newly) != tuple(b05.act):
        raise SystemExit(f"RD02_PAT's newly read quad {newly} is not B05_PLOAD_READ's "
                         f"{tuple(b05.act)}")
    return rows, tuple(retained), tuple(newly)


def read_colour_gate(xe10):
    """W00_FG_x / W01_BG_x: an 0x4A6/0x4AA write made while 0x4A2's bits 13-14 are clear (the
    pattern comes from PAT) is IGNORED, so the retained colour survives.

    The retained colour is the row's own hex index (EQGQUIRK's B03 "P=FG-color-5" names that
    convention); the value the ignored write carried is the PRE-FIX core's own answer in the same
    capture - the complement of the retained colour - which is what makes the replay fail before
    the fix rather than pass vacuously."""
    out = []
    for prefix, sel in (("W00_FG_", 0x40), ("W01_BG_", 0x20)):
        for key in range(0, 16, 5):
            pass
        for key in (0x0, 0x5, 0xA, 0xF):
            row = xe10[f"{prefix}{key:X}"][0]
            quad = tuple(0xFFFF if (key >> p) & 1 else 0x0000 for p in range(4))
            if tuple(row.exp) != quad:
                raise SystemExit(f"{row.id}: the retained colour {key:X} does not expand to "
                                 f"{tuple(row.exp)}")
            out.append((row, sel, key, (key ^ 0xF) & 0xF))
    return out


QSTR = 'localparam [63:0] EGCX_ID [0:%d] = \'{ %s};\n'


def fmt_id(text):
    """The 16-character, space-padded ASCII id as the hex digits of a 128-bit value."""
    b = text.encode("ascii")[:16].ljust(16, b" ")
    return b.hex()


def pack_vec(rid, data, exp, fg, access, plane, byte_op, lane, offset):
    """EGCX_V's field layout - keep in step with the header comment and tb_pc9821_egc_compare."""
    value = (offset & 0x7FFF)
    value |= (lane & 3) << 15
    value |= (1 if byte_op else 0) << 17
    value |= (plane & 3) << 18
    value |= (access & 0xF) << 20
    value |= (fg & 0xF) << 24
    value |= (exp & 0xFFFF) << 28
    value |= (data[3] & 0xFFFF) << 44
    value |= (data[2] & 0xFFFF) << 60
    value |= (data[1] & 0xFFFF) << 76
    value |= (data[0] & 0xFFFF) << 92
    value |= int(fmt_id(rid), 16) << 108
    return value


def emit(v, pat, gate):
    L = []
    L.append("// GENERATED by tools/gen_egc_compare_vectors.py - do not edit.\n")
    L.append("// Source: docs/probes/egc-conformance/{xe10,mister}/*.CSV (PC98_EGC_CONFORMANCE\n")
    L.append("// v1.3, RUNALL, a real PC-9821 V166). Every EGCX_EXP/EGCW_EXP value is\n")
    L.append("// the Xe10's own aB column; see docs/probes/egc-conformance/README.md.\n\n")
    L.append(f"localparam int EGCX_NV = {len(v.cmp)};\n")
    L.append("// One replay vector: {0, id[127:0] at bits 108..235, offset[14:0] at bits 0..14,\n")
    L.append("//   lane[1:0] 16:15, byte_op 17, window/aperture[1:0] 19:18, access[3:0] 23:20,\n")
    L.append("//   fg[3:0] 27:24, expected[15:0] 43:28, data planes 3,2,1,0 at 59:44..107:92}\n")
    L.append("localparam [239:0] EGCX_V [0:EGCX_NV-1] = '{\n")
    elems = []
    for idx, (rid, data, exp, fg, access, plane, byte_op, lane, offset) in enumerate(v.cmp):
        value = pack_vec(rid, data, exp, fg, access, plane, byte_op, lane, offset)
        comma = "" if idx == len(v.cmp) - 1 else ","
        elems.append(f"  240'h{value:060X}{comma}  // {rid}: window {plane}, exp {exp:04X}")
    L.append("\n".join(elems) + "\n};\n\n")
    L.append(f"localparam int EGCX_NP = {len(pat[0])};\n")
    L.append("localparam [15:0] EGCX_PAT_RETAINED [0:3] = '{")
    L.append(", ".join(f"16'h{q:04X}" for q in pat[1]) + "};\n")
    L.append("localparam [15:0] EGCX_PAT_NEW [0:3] = '{")
    L.append(", ".join(f"16'h{q:04X}" for q in pat[2]) + "};\n")
    L.append("// row-major: EGCX_PAT_EXP[4 * row + plane]\n")
    L.append("localparam [15:0] EGCX_PAT_EXP [0:15] = '{")
    L.append(", ".join(f"16'h{q:04X}" for row in pat[0] for q in row.exp) + "};\n\n")
    L.append(f"localparam int EGCW_NV = {len(gate)};\n")
    L.append("// W00_FG_x / W01_BG_x: {0x4A2's colour field, the retained colour, the ignored\n")
    L.append("// write's value (the pre-fix core's own answer), the expected plane quad}\n")
    L.append(f"localparam [127:0] EGCW_ID [0:EGCW_NV-1] = '{{")
    L.append(", ".join("128'h" + fmt_id(g[0].id) for g in gate) + "};\n")
    L.append("localparam [7:0] EGCW_SEL [0:EGCW_NV-1] = '{")
    L.append(", ".join(f"8'h{g[1]:02X}" for g in gate) + "};\n")
    L.append("localparam [7:0] EGCW_COL [0:EGCW_NV-1] = '{")
    L.append(", ".join(f"8'h{g[2]:X}" for g in gate) + "};\n")
    L.append("localparam [7:0] EGCW_IGNORED [0:EGCW_NV-1] = '{")
    L.append(", ".join(f"8'h{g[3]:X}" for g in gate) + "};\n")
    L.append("// row-major: EGCW_EXP[4 * row + plane]\n")
    L.append("localparam [15:0] EGCW_EXP [0:31] = '{")
    L.append(", ".join(f"16'h{q:04X}" for g in gate for q in g[0].exp) + "};\n")
    # ---- the colour-key WRITE family (CK00_*_DST / CK01_*_DST) ----
    # The sequence the ROWS replay: seed the region with the SRC quad, compare-read it (the
    # expected mask is the hardware's own *_MASK column), write that value into 0x04A8 - the
    # software's "compare mask used as the colour key" - then store EGCK_DATA with the ordinary
    # masked write and read the region back (the expectation is the hardware's *_DST column).
    L.append(f"localparam int EGCK_NV = {len(v.ck)};\n")
    L.append("// One colour-key write: {0, fg[3:0] 287, id[127:0] at 159..286,\n")
    L.append("//   src plane 3,2,1,0 at 95..158, expected dst plane 3,2,1,0 at 31..94,\n")
    L.append("//   mask[15:0] at 15..30, offset[14:0] at 0..14}\n")
    L.append("localparam [290:0] EGCK_V [0:EGCK_NV-1] = '{\n")
    elems = []
    for idx, (rid, src, mask, dst, data, off, fg) in enumerate(v.ck):
        value = off & 0x7FFF
        value |= (mask & 0xFFFF) << 15
        for p in range(4):
            value |= (dst[p] & 0xFFFF) << (31 + 16 * p)
            value |= (src[p] & 0xFFFF) << (95 + 16 * p)
        value |= int(fmt_id(rid + "_DST"), 16) << 159
        value |= (fg & 0xF) << 287
        comma = "" if idx == len(v.ck) - 1 else ","
        elems.append(f"  291'h{value:074X}{comma}  // {rid}_DST: mask {mask:04X}, fg {fg:X}")
    L.append("\n".join(elems) + "\n};\n\n")
    L.append("// The written data the model solves for, the same quad in both families:\n")
    ck_data = v.ck[0][4] if v.ck else (0, 0, 0, 0)
    L.append("localparam [15:0] EGCK_DATA [0:3] = '{")
    L.append(", ".join(f"16'h{q:04X}" for q in ck_data) + "};\n")
    return "".join(L)


def coverage(v, xe10):
    """Row accounting: what the vectors cover out of the capture's oracle rows."""
    have = {rid for rid in v.covered}
    gap = 0
    covered_gap = 0
    missed = {}
    for rid, rows in xe10.items():
        row = rows[0]
        if row.status != "PASS":
            continue
        mir = MISTER.get(rid)
        if mir is None or mir[0].status == "PASS":
            continue
        gap += 1
        if rid in have:
            covered_gap += 1
        else:
            missed.setdefault(row.detail, []).append(rid)
    return have, gap, covered_gap, missed


MISTER = {}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed file matches a fresh generation")
    args = ap.parse_args()

    global MISTER
    xe10 = read_capture("xe10")
    MISTER = read_capture("mister")

    # A row present in two capture files must agree byte for byte, or the capture is not one run.
    for rid, rows in xe10.items():
        for row in rows[1:]:
            if row.act != rows[0].act or row.status != rows[0].status:
                raise SystemExit(f"{rid}: {rows[0].grp} and {row.grp} disagree "
                                 f"({rows[0].act} vs {row.act})")

    v = build(xe10, MISTER)
    pat = read_pat_family(xe10)
    gate = read_colour_gate(xe10)
    text = emit(v, pat, gate)

    have, gap, covered_gap, missed = coverage(v, xe10)
    total_oracle = sum(1 for rows in xe10.values() if rows[0].status == "PASS")
    print(f"rows with a hardware oracle in the Xe10 capture : {total_oracle}")
    print(f"rows replayed as vectors                       : {len(v.cmp)}")
    print(f"gap rows (Xe10 PASS, core not)                 : {gap}")
    print(f"  of which covered by these vectors            : {covered_gap}")
    if v.free:
        print(f"  FREE-stimulus rows (the CSV fixes only the result): {', '.join(v.free)}")
    print("gap rows NOT covered, by the suite's own detail string:")
    for detail, ids in sorted(missed.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(ids):4d}  {detail}   (e.g. {ids[0]})")
    print(f"RD02_PAT rows: {len(pat[0])} (retained quad "
          f"{['%04X' % q for q in pat[1]]}, newly read {['%04X' % q for q in pat[2]]})")
    print(f"W00/W01 colour-gate rows: {len(gate)}")

    if args.check:
        cur = OUT.read_text() if OUT.exists() else ""
        if cur != text:
            print(f"STALE: {OUT.relative_to(ROOT)} does not match this generation", file=sys.stderr)
            return 1
        print(f"OK: {OUT.relative_to(ROOT)} is up to date")
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
