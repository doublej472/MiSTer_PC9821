#!/usr/bin/env python3
"""rstdtr_decode.py - decode RSTDTR captures (todo item 53): IDTR/GDTR right after a CPU-only reset.

    rstdtr_decode.py RSTDTR.TXT [OTHER.TXT]     one capture, or two (core vs machine) side by side
    rstdtr_decode.py --selftest

The 486 manuals give IDTR limit 03FF after reset (Intel486 PRM 1992 Table 10-1); NP2kai
(i386c/ia32/interface.c) sets FFFF for both. The DOS-prompt values (XE10CFG's CPU line) went
through the POST; these did not (rstdtr.s header).
"""
from __future__ import annotations

import re
import sys

LINE = re.compile(r'RSTDTR pre idt=([0-9A-F]{4}):([0-9A-F]{8}) gdt=([0-9A-F]{4}):([0-9A-F]{8}) cr0=([0-9A-F]{8}) '
                  r'\| reset idt=([0-9A-F]{4}):([0-9A-F]{8}) gdt=([0-9A-F]{4}):([0-9A-F]{8}) cr0=([0-9A-F]{8}) '
                  r'edx=([0-9A-F]{8}) a20=([01])')


def parse(text: str) -> dict | None:
    for ln in text.splitlines():
        m = LINE.match(ln.strip())
        if m:
            g = m.groups()
            return dict(pre_idt=g[0], pre_gdt=g[2], pre_cr0=g[4], idt=g[5], idt_base=g[6], gdt=g[7],
                        gdt_base=g[8], cr0=g[9], edx=g[10], a20=g[11], done='END:RSTDTR' in text)
    return None


def verdict(d: dict) -> str:
    def name(lim):
        return {'03FF': 'the manuals\' 03FF', 'FFFF': 'NP2kai\'s FFFF'}.get(lim, lim)
    return (f'after the reset: IDTR limit {d["idt"]} ({name(d["idt"])}), GDTR limit {d["gdt"]} ({name(d["gdt"])});'
            f' DOS prompt: {d["pre_idt"]}/{d["pre_gdt"]}; reset EDX {d["edx"]}, CR0 {d["cr0"]}')


def selftest() -> int:
    t = ('BEGIN:RSTDTR\r\nRSTDTR pre idt=FFFF:00000000 gdt=FFFF:00000000 cr0=00000032 | reset idt=FFFF:00000000 '
         'gdt=FFFF:00000000 cr0=00000032 edx=00000435 a20=0\r\nEND:RSTDTR\r\n')
    d = parse(t)
    ok = d is not None and d['idt'] == 'FFFF' and d['done'] and 'NP2kai' in verdict(d)
    ok &= parse('nothing') is None
    print('SELFTEST', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


def main(argv) -> int:
    if argv[1:] == ['--selftest']:
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    for p in argv[1:]:
        d = parse(open(p, 'rb').read().decode('ascii', 'replace'))
        print(f'{p}: ' + ('no RSTDTR line (a hang in the reset path?)' if d is None else verdict(d)
                          + ('' if d['done'] else ' [no END line]')))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
