#!/usr/bin/env python3
"""av_audio_stats - health report for a captured audio recording.

Reads any file ffmpeg can decode (WAV/FLAC/...) as 48 kHz 16-bit stereo and
reports what a listener would notice without listening:

  level      RMS and peak in dBFS, per channel, and the share of clipped
             samples (|x| >= 32767)
  DC         per-channel mean as a percentage of full scale
  channels   L/R RMS imbalance; a channel more than 30 dB under the other is
             flagged as missing
  silence    stretches longer than --silence-min seconds with the 100 ms RMS
             under --silence-db (default -60 dBFS, above the capture noise)
  dropouts   runs of exactly-zero samples (both channels) of at least
             --dropout-ms inside a stretch that is otherwise active
  clicks     samples whose second difference exceeds --click-k times the local
             (50 ms) RMS of the second difference, in a signal that is active
  spectrum   share of energy in 20-100 Hz, 100-1k, 1k-10k, 10k-24k, and the
             strongest sharp spectral peak (frequency, prominence over the
             median bin) - a sustained tone's pitch can be checked against
             what the source should produce

A recording is analysed whole, and with --window S in S-second slices so a
silence/dropout can be placed in time.  Output is text, or JSON with --json.
Recordings are never read from or written to the repo; this tool only reads.

USAGE
  python3 tools/av_audio_stats.py REC [REC ...] [--window S] [--json]
  python3 tools/av_audio_stats.py --selftest
"""

import argparse
import json
import subprocess
import sys

import numpy as np

SR = 48000


def load(path):
    p = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "s16le", "-ac", "2",
         "-ar", str(SR), "-"], capture_output=True, check=True)
    x = np.frombuffer(p.stdout, dtype="<i2").reshape(-1, 2)
    return x


def db(v):
    return 20 * np.log10(max(v, 1e-9) / 32768.0)


def runs(mask):
    """(start, length) of True runs in a boolean array."""
    if not mask.any():
        return []
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    s = np.where(d == 1)[0]
    e = np.where(d == -1)[0]
    return list(zip(s, e - s))


def analyse(x, silence_db=-60.0, silence_min=1.0, dropout_ms=5.0, click_k=40.0):
    n = len(x)
    f = x.astype(np.float64)
    r = {"seconds": round(n / SR, 2)}
    if n < SR // 10:
        r["error"] = "too short"
        return r
    rms = np.sqrt((f ** 2).mean(axis=0))
    pk = np.abs(f).max(axis=0)
    r["rms_dbfs"] = [round(float(db(v)), 2) for v in rms]
    r["peak_dbfs"] = [round(float(db(v)), 2) for v in pk]
    r["rms_dbfs_all"] = round(float(db(np.sqrt((f ** 2).mean()))), 2)
    r["peak_dbfs_all"] = round(float(db(pk.max())), 2)
    r["clipped_pct"] = round(100.0 * (np.abs(x) >= 32767).sum() / x.size, 4)
    r["dc_pct"] = [round(float(100.0 * m / 32768.0), 3) for m in f.mean(axis=0)]
    imb = db(rms[0]) - db(rms[1])
    r["lr_imbalance_db"] = round(float(imb), 2)
    r["channel_missing"] = bool(abs(imb) > 30 and rms.max() > 50)

    # 100 ms RMS envelope (mono power)
    blk = SR // 10
    nb = n // blk
    e = np.sqrt((f[:nb * blk] ** 2).mean(axis=1).reshape(nb, blk).mean(axis=1))
    edb = 20 * np.log10(np.maximum(e, 1e-9) / 32768.0)
    quiet = edb < silence_db
    sil = [(round(float(s) * 0.1, 1), round(float(l) * 0.1, 1)) for s, l in runs(quiet)
           if l * 0.1 >= silence_min]
    r["silence_stretches"] = sil
    r["silent_share_pct"] = round(float(100.0 * quiet.mean()), 1)
    r["active_share_pct"] = round(float(100.0 * (~quiet).mean()), 1)

    # exact-zero runs on both channels, only where the neighbourhood is active
    z = (x[:, 0] == 0) & (x[:, 1] == 0)
    mn = int(dropout_ms * SR / 1000)
    drops = []
    for s, l in runs(z):
        if l < mn or l > SR:
            continue
        a = max(0, s - SR // 20)
        b = min(n, s + l + SR // 20)
        pre = np.abs(f[a:s]).mean() if s > a else 0
        post = np.abs(f[s + l:b]).mean() if b > s + l else 0
        if pre > 20 and post > 20:
            drops.append((round(float(s) / SR, 3), round(l * 1000.0 / SR, 1)))
    r["dropouts"] = drops

    # clicks: second difference spikes vs local RMS of the second difference
    m = f.mean(axis=1)
    d2 = np.abs(np.diff(m, 2))
    w = SR // 20
    k = len(d2) // w
    if k > 2:
        loc = np.sqrt((d2[:k * w] ** 2).reshape(k, w).mean(axis=1))
        locx = np.repeat(loc, w)
        act = locx > 30.0
        hit = (d2[:k * w] > click_k * np.maximum(locx, 1e-9)) & act
        r["clicks"] = int(hit.sum())
        r["clicks_per_min"] = round(float(hit.sum() * 60.0 / (n / SR)), 1)
    else:
        r["clicks"] = 0
        r["clicks_per_min"] = 0.0

    # spectrum
    nf = 1 << 16
    segs = (n - nf) // (nf // 2)
    if segs >= 1:
        win = np.hanning(nf)
        acc = np.zeros(nf // 2 + 1)
        for i in range(segs):
            seg = m[i * nf // 2: i * nf // 2 + nf] * win
            acc += np.abs(np.fft.rfft(seg)) ** 2
        fr = np.fft.rfftfreq(nf, 1.0 / SR)
        tot = acc.sum() + 1e-9

        def band(lo, hi):
            return round(float(100.0 * acc[(fr >= lo) & (fr < hi)].sum() / tot), 1)

        r["band_pct"] = {"20-100": band(20, 100), "100-1k": band(100, 1000),
                         "1k-10k": band(1000, 10000), "10k-24k": band(10000, 24000)}
        sel = (fr >= 40) & (fr < 20000)
        a2 = acc[sel]
        i = int(a2.argmax())
        med = float(np.median(a2)) + 1e-9
        r["peak_hz"] = round(float(fr[sel][i]), 1)
        r["peak_prominence_db"] = round(float(10 * np.log10(max(a2[i], 1e-12) / med)), 1)
    return r


def windows(x, w):
    out = []
    for i in range(0, len(x) - w // 2, w):
        seg = x[i:i + w]
        if len(seg) >= SR:
            out.append((i // SR, analyse(seg)))
    return out


def fmt(r):
    if "error" in r:
        return "  " + r["error"]
    L = []
    L.append(f"  {r['seconds']} s  RMS {r['rms_dbfs']} (all {r['rms_dbfs_all']}) dBFS  "
             f"peak {r['peak_dbfs']} (all {r['peak_dbfs_all']}) dBFS  clipped {r['clipped_pct']}%")
    L.append(f"  DC% {r['dc_pct']}  L-R {r['lr_imbalance_db']} dB  channel_missing={r['channel_missing']}")
    L.append(f"  silence>1s {r['silence_stretches']}  silent {r['silent_share_pct']}%  dropouts {r['dropouts']}")
    L.append(f"  clicks {r['clicks']} ({r['clicks_per_min']}/min)")
    if "band_pct" in r:
        L.append(f"  bands% {r['band_pct']}  peak {r['peak_hz']} Hz (+{r['peak_prominence_db']} dB over median)")
    return "\n".join(L)


def selftest():
    rng = np.random.default_rng(1)
    t = np.arange(SR * 8) / SR
    tone = 8000 * np.sin(2 * np.pi * 1000 * t) + rng.normal(0, 200, t.size)
    x = np.stack([tone, tone * 0.9], axis=1)
    # plant: 2 s silence at 3..5 s, a 20 ms zero run at 6 s, a click at 7 s,
    # DC on none, clipping on 50 samples
    x[3 * SR:5 * SR] = 0
    x[6 * SR:6 * SR + 960] = 0
    x[int(7.0 * SR)] += 20000
    x[100:150] = 32767
    x = np.clip(x, -32768, 32767).astype(np.int16)
    r = analyse(x)
    ok = True

    def chk(c, msg):
        nonlocal ok
        if not c:
            ok = False
            print("SELFTEST FAIL:", msg, file=sys.stderr)
    chk(any(abs(s - 3.0) < 0.2 and abs(l - 2.0) < 0.3 for s, l in r["silence_stretches"]), "silence")
    chk(len(r["dropouts"]) == 1 and abs(r["dropouts"][0][0] - 6.0) < 0.01, "dropout %r" % r["dropouts"])
    chk(r["clicks"] >= 1, "click")
    chk(r["clipped_pct"] > 0, "clip")
    chk(abs(r["peak_hz"] - 1000) < 5, "peak hz %r" % r.get("peak_hz"))
    # missing channel
    y = x.copy()
    y[:, 1] = 0
    chk(analyse(y)["channel_missing"], "channel missing")
    # DC
    d = (np.stack([tone, tone], axis=1) + 3000).clip(-32768, 32767).astype(np.int16)
    chk(analyse(d)["dc_pct"][0] > 5, "dc")
    # a clean tone must not raise anything
    c = np.stack([tone, tone], axis=1).astype(np.int16)
    rc = analyse(c)
    chk(not rc["silence_stretches"] and not rc["dropouts"] and rc["clicks"] == 0
        and rc["clipped_pct"] == 0 and not rc["channel_missing"], "clean tone flagged %r" % rc)
    print("av_audio_stats selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recs", nargs="*")
    ap.add_argument("--window", type=float, default=0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    res = {}
    for p in a.recs:
        x = load(p)
        res[p] = {"whole": analyse(x)}
        if a.window:
            res[p]["windows"] = [(t, w) for t, w in windows(x, int(a.window * SR))]
        if not a.json:
            print(p)
            print(fmt(res[p]["whole"]))
            for t, w in res[p].get("windows", []):
                print(f" [{t}s]")
                print(fmt(w))
    if a.json:
        print(json.dumps(res, indent=1, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
