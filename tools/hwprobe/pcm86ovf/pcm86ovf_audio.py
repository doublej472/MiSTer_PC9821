#!/usr/bin/env python3
"""pcm86ovf_audio.py - decode a line-out recording of PCMOVF stage 2 (`PCMOVF /A`,
tools/hwprobe/pcm86ovf/pcm86ovf.s "STAGE 2"): which bytes the PC-9801-86 PCM FIFO actually PLAYS
after it is written past full.

    pcm86ovf_audio.py REC.WAV            the report, per rep and case
    pcm86ovf_audio.py --selftest         synthetic recordings rendered from each model
    pcm86ovf_audio.py --render MODEL OUT.WAV [--fs 44100]   one synthetic recording (a check)

THE STIMULUS (the probe's, mirrored here; check_source() compares the tables with the .s file):
16-bit stereo, big-endian frames (L high, L low, R high, R low) at 33075 / 8 = 4134.375 Hz.
  S      the 32768-byte fill, frame i of 8192: L = +/-0x3000 (30 00 / D0 00), R = 0x4040 / 0xC0C0
         (40 40 / C0 C0, + on even i); L alternates like R except in its first and last 48 frames,
         where its sign is PRBS (bit 1 = minus), so the first and last frames played say which
         frames they are.
  M      the d bytes written past full: 70 00 90 00 90 00 70 00 repeating (L, R anti-phase).
  sync   three bursts of 1024 frames L = R = +/-0x7000, 0.5 s apart, at the start of each rep.
  cases  d = 0 1 2 3 4 5 8 64 0, case k's playback starting 2.5 + 3.0 k s after the rep's sync.

WHAT IS FITTED. Per case the recording is cut into frame-centre values per channel (the frame
clock from the 2067 Hz alternation, a few samples averaged at each centre), and the played byte
stream is searched as S[b0:32768] + M[0:m] (b0 = 0..80 bytes lost from the oldest end, m = 0..d
marker bytes kept at the newest end) plus "markers only" (WRAP) and "nothing", each rendered
through a 3-tap per-channel response fitted on the rep's d = 0 case (gain, polarity, the output
filter). b0 is chosen on the first 140 frames and m on the last 140. A byte slip that is not a
multiple of 4 is unmistakable: L or R collapses to a few LSB (1 or 3 bytes) or L and R swap (2).

THE MODELS each case is named against (the (b0, m) they predict; frames, not bytes, are what can
be heard, so models that give the same frames are listed together):
  DROP-NEW         (0, 0)               the bytes written past full are discarded
  KEEP-ALL         (0, d)               every byte plays: NP2kai (the extra bytes go to its rescue
                                        margin, realbuf, cbus/pcm86io.c pcm86_oa46c), or a FIFO
                                        larger than 32 KiB
  CORE-SLIP4       (4 ceil(d/4), d)     the core: each byte at full drops the oldest 4-byte group
                                        (src/pcm86/pc9821_pcm86.sv `count <= 16'h7FFD;`)
  OVERWRITE-OLDEST (d, d)               a ring whose new byte overwrites the oldest (a d-byte slip)
  WRAP             markers only         the count wrapped: only the d new bytes play
"""
from __future__ import annotations

import math
import os
import re
import struct
import sys
import tempfile

import numpy as np

FR = 33075 / 8.0
NFR = 8192
HEAD = 48
FULL = 32768
DEPTHS = (0, 1, 2, 3, 4, 5, 8, 64, 0)
PRBS = bytes([0x1B, 0x4B, 0x77, 0xA6, 0xFA, 0x03, 0xC1, 0x50, 0x3C, 0xD1, 0x5C, 0xF9])
MK = bytes([0x70, 0x00, 0x90, 0x00, 0x90, 0x00, 0x70, 0x00])
SYNC_T = (0.0, 0.5, 1.0)
CASE_T0, CASE_DT, CASE_START = 2.0, 3.0, 0.5
REP_T = 29.0
B0_MAX = 80
WIN = 140
HERE = os.path.dirname(os.path.abspath(__file__))


# ---- the stimulus -----------------------------------------------------------------------------
def prbs_bit(j: int) -> int:
    return (PRBS[j >> 3] >> (j & 7)) & 1


def s_bytes() -> bytes:
    out = bytearray()
    for i in range(NFR):
        if i < HEAD:
            neg = prbs_bit(i)
        elif i >= NFR - HEAD:
            neg = prbs_bit(i - (NFR - 2 * HEAD))
        else:
            neg = i & 1
        r = 0xC0 if i & 1 else 0x40
        out += bytes([0xD0 if neg else 0x30, 0xF8 if neg else 0x08, r, r])
    return bytes(out)


S = s_bytes()


def m_bytes(d: int) -> bytes:
    return bytes(MK[j & 7] for j in range(d))


def sync_bytes() -> bytes:
    out = bytearray()
    for i in range(1024):
        v = 0x90 if i & 1 else 0x70     # the probe tests CX's bit 0 counting down from 1024
        out += bytes([v, 0, v, 0])
    return bytes(out)


def frames(b: bytes) -> np.ndarray:
    """(N, 2) float: the signed 16-bit L, R of each whole 4-byte frame"""
    n = len(b) // 4
    a = np.frombuffer(b[:4 * n], dtype=">i2").astype(np.float64)
    return a.reshape(n, 2)


def model_streams(d: int) -> dict:
    """model name -> the bytes it plays"""
    k = -(-d // 4)
    return {"DROP-NEW": S, "KEEP-ALL": S + m_bytes(d), "CORE-SLIP4": S[4 * k:] + m_bytes(d),
            "OVERWRITE-OLDEST": S[d:] + m_bytes(d), "WRAP": m_bytes(d) if d else S}


def check_source() -> list:
    """the .s tables against this file's"""
    errs = []
    try:
        src = open(os.path.join(HERE, "pcm86ovf.s")).read()
    except OSError:
        return ["pcm86ovf.s not found"]
    for name, want in (("a_prbs", PRBS), ("a_mk", MK), ("a_dtab", bytes(DEPTHS))):
        m = re.search(r"^%s:\s+\.byte\s+(.*)$" % name, src, re.M)
        got = bytes(int(x, 0) for x in m.group(1).split(",")) if m else None
        if got != want:
            errs.append("%s differs from the probe's" % name)
    return errs


# ---- WAV I/O ----------------------------------------------------------------------------------
def read_wav(path: str):
    data = open(path, "rb").read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    pos, fmt, raw = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
            if fmt[0] == 0xFFFE and len(body) >= 26:
                fmt = (struct.unpack("<H", body[24:26])[0],) + fmt[1:]
        elif cid == b"data":
            raw = body
        pos += 8 + size + (size & 1)
    if fmt is None or raw is None:
        raise ValueError("no fmt or data chunk")
    tag, ch, fs, _, align, bits = fmt
    if tag == 3:
        x = np.frombuffer(raw[:len(raw) // align * align], dtype="<f%d" % (bits // 8)).astype(np.float64)
    elif tag == 1 and bits in (16, 32):
        x = np.frombuffer(raw[:len(raw) // align * align], dtype="<i%d" % (bits // 8)).astype(np.float64)
        x /= 2.0 ** (bits - 1)
    elif tag == 1 and bits == 24:
        b = np.frombuffer(raw[:len(raw) // align * align], dtype=np.uint8).reshape(-1, 3)
        v = (b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16))
        v = np.where(v & 0x800000, v - 0x1000000, v)
        x = v.astype(np.float64) / 2.0 ** 23
    else:
        raise ValueError("unsupported WAV format tag %d, %d bits" % (tag, bits))
    x = x.reshape(-1, ch)
    if ch < 2:
        raise ValueError("the recording must be STEREO (L and R carry different patterns)")
    return fs, x[:, :2]


def write_wav(path: str, fs: int, x: np.ndarray):
    y = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    with open(path, "wb") as f:
        n = y.size * 2
        f.write(b"RIFF" + struct.pack("<I", 36 + n) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, fs, fs * 4, 4, 16))
        f.write(b"data" + struct.pack("<I", n) + y.tobytes())


# ---- rendering (the selftest's recordings) ----------------------------------------------------
def render(model: str, fs: int = 44100, reps: int = 1, clk: float = 1.0002, gain: float = 0.35,
           invert: bool = False, cutoff: float = 15000.0, noise: float = 2e-4, seed: int = 1):
    """a recording of the probe on a machine whose FIFO follows MODEL"""
    fr = FR * clk
    lead = 1.3
    total = lead + reps * (REP_T + 0.3) + 1.0
    out = np.zeros((int(total * fs), 2))

    def put(t0, b):
        fv = frames(b) / 32768.0
        i0 = int(math.ceil(t0 * fs))
        i1 = int((t0 + len(fv) / fr) * fs)
        t = np.arange(i0, i1) / fs
        idx = np.minimum(((t - t0) * fr).astype(np.int64), len(fv) - 1)
        out[i0:i1] = fv[idx]
    for r in range(reps):
        base = lead + r * (REP_T + 0.3)
        for ts in SYNC_T:
            put(base + ts + 0.0004, sync_bytes())
        for k, d in enumerate(DEPTHS):
            b = model_streams(d)[model]
            if b:
                put(base + CASE_T0 + k * CASE_DT + CASE_START + 0.0007, b)
    # the output filter: a windowed-sinc low-pass, then AC coupling (a 40 ms mean removed)
    n = 63
    tt = np.arange(n) - (n - 1) / 2
    h = np.sinc(2 * cutoff / fs * tt) * np.hamming(n)
    h /= h.sum()
    for c in range(2):
        y = np.convolve(out[:, c], h, mode="same")
        w = int(0.04 * fs)
        cs = np.concatenate([[0.0], np.cumsum(y)])
        m = (cs[w:] - cs[:-w]) / w
        m = np.concatenate([np.full(w // 2, m[0]), m, np.full(len(y) - len(m) - w // 2, m[-1])])
        out[:, c] = y - m
    out *= -gain if invert else gain
    out += np.random.default_rng(seed).normal(0, noise, out.shape)
    return out


# ---- analysis -----------------------------------------------------------------------------------
def envelope_segments(x: np.ndarray, fs: int):
    blk = max(1, int(0.005 * fs))
    nb = len(x) // blk
    e = np.sqrt((x[:nb * blk] ** 2).reshape(nb, blk, 2).mean(axis=1)).max(axis=1)
    thr = 0.12 * np.percentile(e, 99.5)
    on = e > thr
    segs = []
    i = 0
    while i < nb:
        if on[i]:
            j = i
            while j < nb and (on[j] or (j + 4 < nb and on[j:j + 5].any())):
                j += 1
            segs.append((i * blk / fs, j * blk / fs))
            i = j
        else:
            i += 1
    return segs


def find_reps(segs):
    """the sync triplets -> each rep's base time (its first burst's onset)"""
    reps = []
    for i in range(len(segs) - 2):
        a, b, c = segs[i:i + 3]
        dur = [s[1] - s[0] for s in (a, b, c)]
        if all(0.15 <= x <= 0.4 for x in dur) and abs(b[0] - a[0] - 0.5) < 0.06 and abs(c[0] - a[0] - 1.0) < 0.08:
            if not reps or a[0] - reps[-1] > 5.0:
                reps.append(a[0])
    return reps


def frame_grid(x: np.ndarray, fs: int, t0: float, t1: float):
    """the frame clock in [t0, t1]: -> (frame rate, phase reference) from the alternation"""
    i0, i1 = int(t0 * fs), int(t1 * fs)
    seg = x[i0:i1]
    mid = seg[len(seg) // 4: 3 * len(seg) // 4]
    best = None
    for c in range(2):
        y = mid[:, c] - mid[:, c].mean()
        nfft = 1 << int(math.ceil(math.log2(len(y) * 8)))
        sp = np.abs(np.fft.rfft(y * np.hanning(len(y)), nfft))
        f = np.fft.rfftfreq(nfft, 1 / fs)
        band = (f > FR / 2 * 0.95) & (f < FR / 2 * 1.05)
        k = np.argmax(np.where(band, sp, 0))
        if best is None or sp[k] > best[0]:
            a, b_, cc = sp[k - 1], sp[k], sp[k + 1]
            off = 0.5 * (a - cc) / (a - 2 * b_ + cc) if (a - 2 * b_ + cc) != 0 else 0
            best = (sp[k], c, f[k] + off * fs / nfft)
    _, ch, fc = best
    y = seg[:, ch]
    t = (np.arange(i0, i1)) / fs
    nb = 24
    edges = np.linspace(0, len(y), nb + 1).astype(int)
    ph = []
    for j in range(nb):
        s = slice(edges[j], edges[j + 1])
        ph.append(np.angle(np.sum(y[s] * np.exp(-2j * np.pi * fc * t[s]))))
    ph = np.unwrap(np.array(ph))
    tc = np.array([(t[edges[j]] + t[edges[j + 1] - 1]) / 2 for j in range(nb)])
    w = np.ones(nb)
    w[:3] = w[-3:] = 0.2
    slope = np.polyfit(tc, ph, 1, w=w)[0]
    fc -= slope / (2 * np.pi)
    phi = np.angle(np.sum(y * np.exp(-2j * np.pi * fc * t)))
    return 2 * fc, phi, fc


def frame_phase(x, fs, fc, t0, t1):
    """the alternation's phase over [t0, t1] at the carrier fc (for a case too short to fit fc)"""
    i0, i1 = int(t0 * fs), int(t1 * fs)
    t = np.arange(i0, i1) / fs
    y = x[i0:i1]
    c = int(np.argmax(np.abs(y).sum(axis=0)))
    return float(np.angle(np.sum(y[:, c] * np.exp(-2j * np.pi * fc * t))))


def frame_values(x, fs, fr, phi, fc, t0, t1):
    """frame-centre values per channel for the frames whose centres lie in [t0, t1]: the centre of
    a frame is an extreme of the alternation, 2 pi fc t + phi = m pi"""
    m0 = int(math.ceil((2 * np.pi * fc * t0 + phi) / np.pi))
    m1 = int((2 * np.pi * fc * t1 + phi) / np.pi)
    ms = np.arange(m0, m1 + 1)
    tc = (ms * np.pi - phi) / (2 * np.pi * fc)
    P = 1.0 / fr
    i0 = max(0, int((t0 - 0.01) * fs))
    i1 = min(len(x), int((t1 + 0.01) * fs) + 2)
    idx = np.arange(i0, i1)
    v = np.zeros((len(ms), 2))
    for off in (-0.15, 0.0, 0.15):
        tt = (tc + off * P) * fs
        for c in range(2):
            v[:, c] += np.interp(tt, idx, x[i0:i1, c])
    return v / 3.0


def onset(v: np.ndarray) -> int:
    a = np.abs(v).max(axis=1)
    ref = np.percentile(a, 90)
    idx = np.nonzero(a > 0.3 * ref)[0]
    return int(idx[0]) if len(idx) else 0


def isi(xf: np.ndarray) -> np.ndarray:
    """(N, 2) -> (N, 2, 4): x[i-1], x[i], x[i+1], 1 per channel"""
    z = np.zeros((1, 2))
    prev = np.vstack([z, xf[:-1]])
    nxt = np.vstack([xf[1:], z])
    return np.stack([prev, xf, nxt, np.ones_like(xf)], axis=2)


def fit_response(v, m_on, xf):
    """the 3-tap response per channel, from a case whose stream is known (d = 0): -> (h, offset)"""
    best = None
    A = isi(xf / 32768.0)
    for o in range(m_on - 6, m_on + 7):
        lo, hi = max(0, o), min(len(v), o + len(xf))
        if hi - lo < len(xf) // 2:
            continue
        res = 0.0
        for c in range(2):      # the alignment on the centre tap alone (side taps could absorb a shift)
            Ac = A[lo - o:hi - o, c, :][:, [1, 3]]
            h, *_ = np.linalg.lstsq(Ac, v[lo:hi, c], rcond=None)
            res += float(np.sum((Ac @ h - v[lo:hi, c]) ** 2))
        if best is None or res < best[0]:
            best = (res, o)
    o = best[1]
    lo, hi = max(0, o), min(len(v), o + len(xf))
    hs = []
    for c in range(2):
        Ac = A[lo - o:hi - o, c, :]
        h, *_ = np.linalg.lstsq(Ac, v[lo:hi, c], rcond=None)
        hs.append(h)
    return np.array(hs), o


def predict(xf, h):
    A = isi(xf / 32768.0) if len(xf) else np.zeros((0, 2, 4))
    p = np.zeros((len(xf), 2))
    for c in range(2):
        p[:, c] = A[:, c, :3] @ h[c, :3]
    return p


def window_res(v, p, o, lo, hi, dc):
    """the residual of prediction p placed at measured index o, over measured frames [lo, hi)"""
    lo, hi = max(lo, 0), min(hi, len(v))
    q = np.zeros((hi - lo, 2)) + dc
    a, b = max(lo, o), min(hi, o + len(p))
    if b > a:
        q[a - lo:b - lo] += p[a - o:b - o]
    return float(np.sum((v[lo:hi] - q) ** 2))


def analyse_case(v, h, dc, d):
    m_on = onset(v)
    cands = {}
    # stage A: the head (b0) and the alignment
    lo, hi = m_on - 8, m_on + WIN
    headA = []
    for b0 in range(0, B0_MAX + 1):
        p = predict(frames(S[b0:b0 + 4 * (WIN + 16)]), h)
        for o in range(m_on - 5, m_on + 6):
            headA.append((window_res(v, p, o, lo, hi, dc), b0, o))
    for name, b in (("WRAP", m_bytes(d)), ("NOTHING", b"")):
        p = predict(frames(b), h)
        for o in range(m_on - 5, m_on + 6):
            cands[name] = min(cands.get(name, 1e300), window_res(v, p, o, lo, hi, dc))
    headA.sort()
    r0, b0, o = headA[0]
    nxt = [x for x in headA if x[1] != b0]
    head_margin = (nxt[0][0] / r0) if nxt and r0 > 0 else float("inf")
    if min(cands["WRAP"], cands["NOTHING"]) < r0:
        name = "WRAP" if cands["WRAP"] <= cands["NOTHING"] else "NOTHING"
        return {"b0": None, "m": None, "kind": name, "head_margin": None, "tail_margin": None,
                "frames": frames(m_bytes(d)) if name == "WRAP" else frames(b"")}
    # stage B: the tail (m), with b0 and the alignment fixed
    tail = []
    for m in range(0, d + 1):
        b = S[b0:] + m_bytes(m)
        xf = frames(b)
        n = len(xf)
        p = predict(xf[max(0, n - WIN - 2):], h)
        po = o + max(0, n - WIN - 2)
        tail.append((window_res(v, p, po, o + n - WIN, o + n + 20, dc), m))
    tail.sort()
    rm, m = tail[0]
    # an m that gives the same frames as a better one is the same answer
    same_frames = [mm for r, mm in tail if len(S[b0:] + m_bytes(mm)) // 4 == len(S[b0:] + m_bytes(m)) // 4]
    nxt = [r for r, mm in tail if mm not in same_frames]
    tail_margin = (nxt[0] / rm) if nxt and rm > 0 else float("inf")
    return {"b0": b0, "m": m, "kind": "STREAM", "head_margin": head_margin, "tail_margin": tail_margin,
            "frames": frames(S[b0:] + m_bytes(m))}


def name_models(res, d):
    got = res["frames"]
    names = [n for n, b in model_streams(d).items() if frames(b).shape == got.shape and np.array_equal(frames(b), got)]
    if res["kind"] == "NOTHING":
        return ["NOTHING-PLAYED"]
    return names or ["OTHER"]


def analyse(fs, x):
    out = []
    segs = envelope_segments(x, fs)
    reps = find_reps(segs)
    out.append("WAV fs=%d length=%.1f s, %d sound segments, %d rep(s) found (sync at %s s)" % (
        fs, len(x) / fs, len(segs), len(reps), ", ".join("%.2f" % r for r in reps)))
    results = []
    for ri, base in enumerate(reps):
        h = None
        fc0 = FR / 2
        for k, d in enumerate(DEPTHS):
            ts = base + CASE_T0 + k * CASE_DT + CASE_START
            cand = [s for s in segs if ts - 0.45 <= s[0] <= ts + 0.45]
            if not cand:
                out.append("REP %d case %d d=%-2d no sound within 0.45 s of %.2f s -> NOTHING-PLAYED (or WRAP "
                           "below the envelope)" % (ri + 1, k, d, ts))
                results.append((ri + 1, k, d, ["NOTHING-PLAYED", "WRAP"]))
                continue
            s0 = cand[0][0]
            s1 = max(s[1] for s in segs if s0 <= s[0] <= ts + 2.4)
            if s1 - s0 > 0.3:
                fr, phi, fc = frame_grid(x, fs, s0, s1)
            else:
                fc = fc0
                fr, phi = 2 * fc, frame_phase(x, fs, fc, s0, s1)
            v = frame_values(x, fs, fr, phi, fc, s0 - 0.02, s1 + 0.03)
            if h is None:
                if d != 0:
                    out.append("REP %d: case 0 missing, no response fit" % (ri + 1))
                    break
                h, _ = fit_response(v, onset(v), frames(S))
                fc0 = fc
                out.append("REP %d response from case 0: frame rate %.3f Hz (nominal %.3f), taps L %s R %s" % (
                    ri + 1, fr, FR, np.array2string(h[0, :3], precision=3), np.array2string(h[1, :3], precision=3)))
            res = analyse_case(v, h, h[:, 3], d)
            names = name_models(res, d)
            results.append((ri + 1, k, d, names))
            if res["kind"] == "STREAM":
                out.append("REP %d case %d d=%-2d played S[%d:] + %d marker bytes (%d frames), margins head %.1fx "
                           "tail %.1fx -> %s" % (ri + 1, k, d, res["b0"], res["m"], len(res["frames"]),
                                                 res["head_margin"], res["tail_margin"], " = ".join(names)))
            else:
                out.append("REP %d case %d d=%-2d %s -> %s" % (ri + 1, k, d, res["kind"], " = ".join(names)))
    out.append("PREDICTED played stream S[b0:] + m markers: " + "; ".join(
        "d=%d core (%d,%d) overwrite-oldest (%d,%d) keep-all/NP2kai (0,%d) drop-new (0,0)" % (
            d, 4 * (-(-d // 4)), d, d, d, d) for d in sorted(set(DEPTHS)) if d))
    return out, results


# ---- selftest -------------------------------------------------------------------------------------
def selftest() -> int:
    bad = 0
    for e in check_source():
        print("selftest: " + e)
        bad += 1
    runs = [("CORE-SLIP4", dict()), ("DROP-NEW", dict(invert=True)), ("KEEP-ALL", dict(fs=48000)),
            ("OVERWRITE-OLDEST", dict(cutoff=9000.0)), ("WRAP", dict()),
            ("CORE-SLIP4", dict(fs=48000, clk=0.9996, cutoff=7000.0, noise=2e-3, gain=0.1, invert=True))]
    for model, kw in runs:
        fs = kw.pop("fs", 44100)
        x = render(model, fs=fs, **kw)
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "t.wav")
            write_wav(p, fs, x)
            fs2, x2 = read_wav(p)
        lines, results = analyse(fs2, x2)
        if not results:
            print("selftest %s: no rep found" % model)
            bad += 1
            continue
        for rep, k, d, names in results:
            ok = model in names
            if model == "WRAP" and d > 0:
                # a few marker frames can fall under the envelope: NOTHING-PLAYED is the same answer
                ok = "WRAP" in names or "NOTHING-PLAYED" in names
            if not ok:
                print("selftest %s case %d d=%d: got %s" % (model, k, d, names))
                bad += 1
        print("selftest %s: %d cases checked" % (model, len(results)))
    print("selftest: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main(argv) -> int:
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) >= 4 and argv[1] == "--render":
        fs = int(argv[argv.index("--fs") + 1]) if "--fs" in argv else 44100
        write_wav(argv[3], fs, render(argv[2], fs=fs, reps=2))
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 2
    fs, x = read_wav(argv[1])
    lines, _ = analyse(fs, x)
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
