#!/usr/bin/env python3
"""av_cdda_match - which CD audio track is a recording playing, and at what pitch/speed?

A capture of a CD-DA title is compared with the disc's own audio tracks.  Each
side is turned into a log-frequency spectrogram (96 bins per octave, 60 Hz to
6 kHz, hop 0.5 s, per-frame mean removed, so the match ignores level and EQ),
then a 10 s (default) slice of the recording is slid over every track.  The
best (track, offset) and the best log-frequency shift give:

  track/offset   where on the disc the recording is
  pitch ratio    2**(shift/96): 1.000 = the disc's own pitch.  A recording of
                 CD-DA played at the right rate and resampled correctly sits
                 within one bin (+-0.7 %).  A drive/core reading at the wrong
                 rate shows as a constant ratio (44.1 vs 48 kHz mix-ups are
                 +8.8 %, a 1.5x speed error is +58 %, far outside the +-6 % search).
  score          mean cosine similarity of the matched frames (0..1); a few
                 tenths over the runner-up track is a confident match.  Mixed
                 content (game FM/PCM over the CD music) lowers the score.

Tracks are read from a CUE sheet (or a .pcd image, as tools/cue2pcd.py writes) whose single FILE is a raw 2352-byte/sector
image (MODE1/2352 data tracks are skipped; AUDIO tracks are 16-bit LE stereo
44.1 kHz).  Nothing is written.

USAGE
  python3 tools/av_cdda_match.py REC.wav CUE [--start S] [--len S] [--tracks 2-30]
  python3 tools/av_cdda_match.py --selftest
"""

import argparse
import os
import re
import subprocess
import sys

import numpy as np

HOP = 0.5
BPO = 96
FLO, FHI = 60.0, 6000.0
NB = int(np.log2(FHI / FLO) * BPO)
CENT = FLO * 2.0 ** (np.arange(NB) / BPO)
MAXSHIFT = 8  # bins, +-5.8 %


def features(x, sr):
    """x mono float; returns (frames, NB) normalised log-frequency features."""
    n = 1 << int(np.ceil(np.log2(0.2 * sr)))
    hop = int(HOP * sr)
    win = np.hanning(n)
    fr = np.fft.rfftfreq(n, 1.0 / sr)
    # triangular filterbank on a log axis, one bin per CENT[k]
    edges = np.concatenate(([CENT[0] / 2 ** (1 / BPO)], CENT, [CENT[-1] * 2 ** (1 / BPO)]))
    fb = np.zeros((NB, len(fr)))
    for k in range(NB):
        lo, c, hi = edges[k], edges[k + 1], edges[k + 2]
        up = (fr >= lo) & (fr < c)
        dn = (fr >= c) & (fr < hi)
        fb[k, up] = (fr[up] - lo) / (c - lo)
        fb[k, dn] = (hi - fr[dn]) / (hi - c)
    out = []
    for s in range(0, len(x) - n, hop):
        m = np.abs(np.fft.rfft(x[s:s + n] * win))
        out.append(np.log1p(fb @ m))
    f = np.array(out)
    if len(f) == 0:
        return f
    # smooth over ~3 bins, remove the per-frame mean, unit norm
    k = np.exp(-0.5 * (np.arange(-4, 5) / 1.5) ** 2)
    k /= k.sum()
    f = np.apply_along_axis(lambda r: np.convolve(r, k, mode="same"), 1, f)
    f -= f.mean(axis=1, keepdims=True)
    nrm = np.linalg.norm(f, axis=1, keepdims=True)
    return f / np.maximum(nrm, 1e-9)


def read_pcd(path):
    """tracks of a .pcd image (2352-byte header sector, then the disc as raw sectors; see tools/cue2pcd.py).
    Same tuples as read_cue; the image path is the pcd itself, LBAs are shifted by the header sector."""
    h = open(path, "rb").read(2352)
    n, first = h[8], h[9]
    leadout = int.from_bytes(h[12:16], "little")
    ent = [int.from_bytes(h[16 + 4 * i:20 + 4 * i], "little") for i in range(n + 1)]
    tr = []
    for i in range(n):
        ctrl, lba = ent[i] & 0xFF, (ent[i] >> 8) & 0xFFFFFF
        end = (ent[i + 1] >> 8) & 0xFFFFFF if i + 1 < n else leadout
        tr.append([first + i, lba + 1, end + 1, not (ctrl & 0x04), path])  # +1: header sector
    return tr


def read_cue(path):
    """[(track_no, start_lba, end_lba or None, is_audio, imgpath)]"""
    if path.lower().endswith(".pcd"):
        return read_pcd(path)
    txt = open(path, errors="replace").read()
    m = re.search(r'FILE\s+"([^"]+)"', txt)
    img = m.group(1)
    if not os.path.isabs(img):
        img = os.path.join(os.path.dirname(os.path.abspath(path)), img)
    tr = []
    for t in re.finditer(r"TRACK\s+(\d+)\s+(\S+)\s+(?:.*?)INDEX\s+01\s+(\d+):(\d+):(\d+)", txt, re.S):
        no, mode = int(t.group(1)), t.group(2)
        lba = (int(t.group(3)) * 60 + int(t.group(4))) * 75 + int(t.group(5))
        tr.append([no, lba, None, mode.upper() == "AUDIO", img])
    size = os.path.getsize(img) // 2352
    for i, t in enumerate(tr):
        t[2] = tr[i + 1][1] if i + 1 < len(tr) else size
    return tr


def track_pcm(t):
    no, a, b, _, img = t
    with open(img, "rb") as f:
        f.seek(a * 2352)
        raw = f.read((b - a) * 2352)
    x = np.frombuffer(raw[: len(raw) // 4 * 4], dtype="<i2").reshape(-1, 2).astype(np.float64)
    return x.mean(axis=1) / 32768.0


def match(cap_feats, tracks_feats):
    """returns list of (score, track_no, offset_frames, shift_bins), best first."""
    n = len(cap_feats)
    res = []
    for no, tf in tracks_feats.items():
        if len(tf) < n:
            continue
        best = (-1, 0, 0)
        for s in range(-MAXSHIFT, MAXSHIFT + 1):
            c = np.roll(cap_feats, s, axis=1)  # shift capture bins by s
            sim = c @ tf.T  # n x m
            m = tf.shape[0] - n + 1
            # diagonal sums
            acc = np.zeros(m)
            for i in range(n):
                acc += sim[i, i:i + m]
            j = int(acc.argmax())
            if acc[j] / n > best[0]:
                best = (acc[j] / n, j, s)
        res.append((best[0], no, best[1], best[2]))
    res.sort(reverse=True)
    return res


def load_wav(path):
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "s16le", "-ac", "1",
                        "-ar", "48000", "-"], capture_output=True, check=True)
    return np.frombuffer(p.stdout, dtype="<i2").astype(np.float64) / 32768.0


def selftest():
    rng = np.random.default_rng(3)
    sr = 44100
    # two synthetic "tracks" of random note sequences with harmonics
    def track(seed, secs=60):
        r = np.random.default_rng(seed)
        t = np.arange(int(sr * secs)) / sr
        x = np.zeros_like(t)
        for k in range(int(secs / 0.5)):
            f = 110 * 2 ** (r.integers(0, 36) / 12)
            seg = slice(int(k * 0.5 * sr), int((k + 1) * 0.5 * sr))
            tt = t[seg]
            x[seg] = sum(np.sin(2 * np.pi * f * h * tt) / h for h in (1, 2, 3))
        return x
    A, B = track(1), track(2)
    tf = {2: features(A, sr), 3: features(B, sr)}
    ok = True
    for ratio in (1.0, 1.0595, 0.9439):  # in tune, +1 semitone, -1 semitone
        # recording = track B from 20 s, 12 s long, played ratio x too fast, at 48 kHz
        seg = B[20 * sr:32 * sr]
        n48 = int(len(seg) / ratio * 48000 / sr)
        rec = np.interp(np.arange(n48) * ratio * sr / 48000, np.arange(len(seg)), seg)
        rec = rec + rng.normal(0, 0.05, rec.size)
        cf = features(rec[: int(10 * 48000)], 48000)
        r = match(cf, tf)
        shift = r[0][3]
        est = 2.0 ** (-shift / BPO)  # capture rolled by +s means it was lower: undo
        good = r[0][1] == 3 and abs(r[0][2] * HOP - 20) < 1.5 and abs(est - ratio) < 0.02
        print("ratio %.4f -> track %d offset %.1fs shift %d bins score %.2f %s"
              % (ratio, r[0][1], r[0][2] * HOP, shift, r[0][0], "ok" if good else "BAD"))
        ok &= good
    print("av_cdda_match selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rec", nargs="?")
    ap.add_argument("cue", nargs="?")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--len", type=float, default=10)
    ap.add_argument("--tracks", default="")
    ap.add_argument("--series", type=float, default=0,
                    help="repeat every SERIES seconds to the end of the recording and print the best match each time "
                         "(track offsets should advance at exactly the slice spacing: a different rate is a speed error)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    tr = [t for t in read_cue(a.cue) if t[3]]
    if a.tracks:
        lo, hi = (a.tracks.split("-") + [a.tracks])[:2]
        tr = [t for t in tr if int(lo) <= t[0] <= int(hi)]
    x = load_wav(a.rec)
    tf = {t[0]: features(track_pcm(t), 44100) for t in tr}
    if a.series:
        st = a.start
        while st + a.len <= len(x) / 48000:
            seg = x[int(st * 48000): int((st + a.len) * 48000)]
            if np.sqrt((seg ** 2).mean()) > 3e-4:
                r = match(features(seg, 48000), tf)[0]
                print("rec %6.1f s -> track %2d offset %6.1f s shift %+d score %.3f" % (st, r[1], r[2] * HOP, r[3], r[0]))
            else:
                print("rec %6.1f s -> (silent)" % st)
            st += a.series
        return 0
    seg = x[int(a.start * 48000): int((a.start + a.len) * 48000)]
    res = match(features(seg, 48000), tf)
    for sc, no, off, sh in res[:5]:
        print("track %2d  offset %6.1f s  shift %+d bins (pitch ratio rec/disc ~ %.4f)  score %.3f"
              % (no, off * HOP, sh, 2.0 ** (-sh / BPO), sc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
