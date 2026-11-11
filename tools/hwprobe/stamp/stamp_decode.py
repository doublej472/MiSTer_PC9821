#!/usr/bin/env python3
"""stamp_decode.py - boot times from the kit's BOOTLOG.TXT (STAMP lines; todo item 181).

    stamp_decode.py BOOTLOG.TXT
    stamp_decode.py --selftest

Each line: `STAMP <tag> rtc=YYMMDDhhmmss (YYMMDD 000000 when the calendar lost its date) edge=xxxxxx arrive=xxxxxx`, taken at a calendar second
edge; `arrive` is the ARTIC (307200 Hz, 24 bits) when the program started, `edge` at the edge.
A `B<n>` tag is the first command of a boot's AUTOEXEC; the line before it is the stamp taken
just before that boot's reboot: `SW...` before a software reboot (RBOOT /Y, immediately), `RST...`
at the PRESS RESET prompt (the owner's reaction time is inside the figure: an upper bound),
`...-ESC` when Esc replaced the RESET. Boot time = the B line's arrival - the previous edge.
The ARTIC at arrival is printed as seconds too: if it equals the boot time, the counter restarts
at that reset and is itself the time since it.
"""
from __future__ import annotations

import datetime
import re
import sys

LINE = re.compile(r'STAMP (\S+) rtc=(\d{12}) edge=([0-9A-F]{6}) arrive=([0-9A-F]{6})')
HZ = 307200


def rtc_time(r: str) -> datetime.datetime:
    """The calendar reading as a datetime. A calendar that lost its date reads YYMMDD 000000
    (a real Xe10 did, counting up from 00:00:00 after power-on): the time of day alone is then
    used on day 1, which keeps the differences within a run of under 24 h."""
    try:
        return datetime.datetime.strptime(r, '%y%m%d%H%M%S')
    except ValueError:
        return datetime.datetime.strptime('000101' + r[6:], '%y%m%d%H%M%S')


def parse(text: str):
    out = []
    for ln in text.splitlines():
        m = LINE.search(ln)
        if not m:
            continue
        t = rtc_time(m[2])
        edge, arr = int(m[3], 16), int(m[4], 16)
        before = ((edge - arr) & 0xFFFFFF) / HZ
        out.append({'tag': m[1], 'edge_t': t, 'arrive_t': t - datetime.timedelta(seconds=before),
                    'arrive_artic_s': arr / HZ})
    return out


def report(st) -> list[str]:
    o = []
    for prev, cur in zip(st, st[1:]):
        if not cur['tag'].startswith('B'):
            continue
        dt = (cur['arrive_t'] - prev['edge_t']).total_seconds()
        if prev['tag'] == 'B':
            kind = 'no stamp before it: a power-cycle after a hang (the time includes the hang)'
        elif prev['tag'].startswith('RST') and not prev['tag'].endswith('-ESC'):
            kind = 'RESET button (owner reaction included: upper bound)'
        else:
            kind = 'software reboot (RBOOT /Y)'
        o.append(f'{prev["tag"]:>10} -> {cur["tag"]:<6} {dt:7.2f} s  {kind}; ARTIC at arrival {cur["arrive_artic_s"]:.2f} s')
    return o or ['no boot pairs']


def selftest() -> int:
    t = ('STAMP B1 rtc=261108100000 edge=04B000 arrive=000000\r\n'
         'STAMP RST1 rtc=261108100010 edge=100000 arrive=0FB000\r\n'
         'STAMP B2 rtc=261108100025 edge=04B000 arrive=000000\r\n')
    r = report(parse(t))
    ok = len(r) == 1 and '14.00 s' in r[0] and 'RESET button' in r[0] and 'ARTIC at arrival 0.00' in r[0]
    z = report(parse(t.replace('rtc=261108', 'rtc=000000')))
    ok = ok and z == r
    print(f'{"PASS" if ok else "FAIL"}: stamp_decode selftest')
    return 0 if ok else 1


def main(argv) -> int:
    if argv[1:] == ['--selftest']:
        return selftest()
    if len(argv) == 2:
        for ln in report(parse(open(argv[1], encoding='latin-1').read())):
            print(ln)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
