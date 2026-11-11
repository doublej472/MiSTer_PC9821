#!/usr/bin/env python3
"""mkblob.py ELF OUT.bin - turn a linked Dhrystone image into SPEED.COM's blob.

The image is the gate's Dhrystone (src/z486/tests/dhrystone: dhry_1.c, dhry_2.c,
dhrystone_main.c, support.c, built with the gate Makefile's CFLAGS and linked with its
dhrystone.ld at address 0) behind speed/spd_start.S. Two edits, both checked:
  - the two `out 0xe4,eax` (E7 E4) instructions dhrystone_main issues as its MARK_START and
    MARK_END become `int 0x40` (CD 40): SPEED's handler reads the ARTIC there. The image is
    refused unless objdump finds exactly two, at instruction boundaries.
  - the image is padded with zeros up to `__end` (dhrystone.ld), so .bss travels as zeros and
    the loader copies one block.
"""
import os
import re
import subprocess
import sys


def main() -> int:
    elf, out = sys.argv[1], sys.argv[2]
    dis = subprocess.run(['objdump', '-d', '-Mintel', elf], capture_output=True, text=True, check=True).stdout
    sites = [int(m.group(1), 16) for m in re.finditer(r'^\s*([0-9a-f]+):\s+e7 e4\s+out\s+0xe4,eax', dis, re.M)]
    if len(sites) != 2:
        print(f'mkblob: expected 2 `out 0xe4,eax`, found {len(sites)}', file=sys.stderr)
        return 1
    if re.search(r'\bout\b', re.sub(r'^\s*[0-9a-f]+:\s+e7 e4\s+out\s+0xe4,eax.*$', '', dis, flags=re.M)):
        print('mkblob: another OUT instruction is in the image', file=sys.stderr)
        return 1
    syms = subprocess.run(['nm', elf], capture_output=True, text=True, check=True).stdout
    end = int(re.search(r'^([0-9a-f]+) \w __end$', syms, re.M).group(1), 16)
    start = int(re.search(r'^([0-9a-f]+) \w _start$', syms, re.M).group(1), 16)
    if start != 0:
        print('mkblob: _start is not at 0', file=sys.stderr)
        return 1
    subprocess.run(['objcopy', '-O', 'binary', elf, out], check=True)
    raw = bytearray(open(out, 'rb').read())
    if len(raw) > end:
        print('mkblob: image longer than __end', file=sys.stderr)
        return 1
    for s in sites:
        assert raw[s:s + 2] == b'\xe7\xe4'
        raw[s:s + 2] = b'\xcd\x40'
    raw += bytes(end - len(raw))
    if end > 0xE000:
        print('mkblob: image over 56 KiB (the loader puts the stack at 0xFFF0)', file=sys.stderr)
        return 1
    open(out, 'wb').write(raw)
    print(f'mkblob: {out} {end} bytes, markers at {sites[0]:#x} {sites[1]:#x}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
