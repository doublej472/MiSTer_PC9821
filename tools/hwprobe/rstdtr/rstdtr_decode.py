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

LINE = re.compile(r'RSTDTR pre idt=(?P<pre_idt>[0-9A-F]{4}):(?P<pre_idt_base>[0-9A-F]{8}) '
                  r'gdt=(?P<pre_gdt>[0-9A-F]{4}):(?P<pre_gdt_base>[0-9A-F]{8}) cr0=(?P<pre_cr0>[0-9A-F]{8}) '
                  r'\| reset idt=(?P<idt>[0-9A-F]{4}):(?P<idt_base>[0-9A-F]{8}) '
                  r'gdt=(?P<gdt>[0-9A-F]{4}):(?P<gdt_base>[0-9A-F]{8}) cr0=(?P<cr0>[0-9A-F]{8}) '
                  r'edx=(?P<edx>[0-9A-F]{8}) a20=(?P<a20>[01])')


def parse(text: str) -> dict | None:
    for ln in text.splitlines():
        m = LINE.match(ln.strip())
        if m:
            return dict(m.groupdict(), done='END:RSTDTR' in text)
    return None


def verdict(d: dict) -> str:
    def name(lim):
        return {'03FF': 'the manuals\' 03FF', 'FFFF': 'NP2kai\'s FFFF'}.get(lim, lim)
    return (f'after the reset: IDTR limit {d["idt"]} ({name(d["idt"])}), GDTR limit {d["gdt"]} ({name(d["gdt"])});'
            f' DOS prompt: {d["pre_idt"]}/{d["pre_gdt"]}; reset EDX {d["edx"]}, CR0 {d["cr0"]}'
            + (f', A20 {d["a20"]}' if d["a20"] != '0' else ''))


def selftest() -> int:
    t = ('BEGIN:RSTDTR\r\nRSTDTR pre idt=FFFF:00000000 gdt=FFFF:00000011 cr0=00000032 | reset idt=03FF:00000022 '
         'gdt=FFFF:00000033 cr0=00000030 edx=00000435 a20=1\r\nEND:RSTDTR\r\n')
    d = parse(t)
    # every field from its own group (a mis-indexed positional group would swap these)
    ok = d is not None and d['done'] and (
        d['pre_idt'], d['pre_gdt'], d['pre_gdt_base'], d['pre_cr0'], d['idt'], d['idt_base'],
        d['gdt'], d['gdt_base'], d['cr0'], d['edx'], d['a20']) == (
        'FFFF', 'FFFF', '00000011', '00000032', '03FF', '00000022', 'FFFF', '00000033',
        '00000030', '00000435', '1')
    ok &= "manuals' 03FF" in verdict(d) and "NP2kai's FFFF" in verdict(d) and 'A20 1' in verdict(d)
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
