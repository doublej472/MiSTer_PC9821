#!/usr/bin/env python3
# ztype.py - type a string on the MiSTer through /dev/uinput (runs ON the MiSTer; tools/mister_regress.py
# copies it to /tmp/zreg/ and deletes it afterwards).
#
# THE MiSTer IS 32-BIT ARM, so `struct input_event` is `@llHHi` (16 bytes). A 64-bit `qq` timeval makes
# Main_MiSTer silently ignore EVERY key - the first attempt did exactly that. Wait ~1.5 s after
# UI_DEV_CREATE before the first event or the first keys are lost. There is no evdev module on the box:
# the ioctls are issued by hand.
#
# Usage: ztype.py [--layout us|jis] [--hold MS] [--gap MS] [--dry] 'text\n'
#        ztype.py [--layout us|jis] --list      ztype.py --selftest
#   '\n' = Enter, '~C' = Ctrl+C, '~U' '~D' '~L' '~R' = the arrow keys, '~E' = Esc,
#   '~k<code>;' = one raw Linux key code (e.g. ~k28; = Enter), '~s<code>;' = the same with Shift held,
#   '~w<ms>;' = wait that long.
#   --layout L  the core's OSD "Keyboard" setting the text is typed for (default us, the core's position 0).
#   --hold MS   how long each key stays down (default 40). --gap MS: the pause after the release (default 40).
#   --dry       print the key events instead of opening /dev/uinput.  --list: the character table.
#   --selftest  check every mapped character of both layouts through the whole chain (runs anywhere, no
#               device; needs the repository for src/pc9821/input/pc9821_kbd.sv and z486_mister.sv).
#
# THE CHAIN a character travels: Linux key code -> Main_MiSTer's PS/2 set-2 table (input.cpp, ev2ps2[]) ->
# hps_io ps2_key -> src/pc9821/input/pc9821_kbd.sv translate() (per the OSD Keyboard layout) -> PC-98 key code
# -> the BIOS key table,
# which turns the PC-98 code (plus SHIFT) into the character DOS sees. The table below gives the PC-98 code
# each entry is meant to reach; --selftest re-derives it through the chain and checks the character against
# the BIOS table rows in BIOS_NORMAL/BIOS_SHIFT.
#
# The PC-98 keyboard is JIS: most shifted symbols differ from the US caps. From the BIOS key table (NP2kai
# bios/keytable.res, normal and shift rows; the Xe10 BIOS dump's own table at BANK7 0x632B holds the same
# characters): shift+2 '"', shift+6 '&', shift+7 "'", shift+8 '(', shift+9 ')', shift+'-' '=', '^' unshifted
# right of '-', '@' and '[' right of P, ':' right of ';' with '*' on its shift, '_' only as shift+RO.
# History: 'dir b:' typed 'dir b+' (':' was the US shift+';') and 'cd v_b1' typed 'cd v=b1' ('_' was
# shift+'-', which is '=' on the JIS caps); '=' typed '^', '&' typed "'" and '*' typed '(' the same way.
# A card run typed every symbol in MAP on one DOS command line and read each one back on the screenshot.
#
# THE RO KEY (PC-98 0x33, '_' on shift; unshifted the BIOS gives 0xFF, nothing). Main_MiSTer sends KEY_RO
# (Linux 89) as set-2 0x51 only since its commit 3967553 (2026-10-17, "map KEY_RO to PS/2 set 2 code 51h");
# before that it sent 0x13. KEY_102ND (Linux 86) has been set-2 0x61 all along and pc9821_kbd.sv maps 0x61
# to 0x33 too, so ztype sends '_' as shift+KEY_102ND: it works on either Main.
#
# THE LAYOUT. pc9821_kbd.sv translates four set-2 codes per the OSD "Keyboard" field (translate(), THE
# LAYOUT): in US, KEY_GRAVE gives '@' (shift '~'), KEY_LEFTBRACE '[' ('{'), KEY_RIGHTBRACE ']' ('}') and
# KEY_BACKSLASH the YEN key '\' ('|'); in JIS, KEY_LEFTBRACE gives '@', KEY_RIGHTBRACE '[', KEY_BACKSLASH
# ']' and KEY_YEN (Linux 124) the YEN key. --layout picks the table for the card's setting; the default is
# the core's position 0 (US), which a card with no saved config runs.
#
# HOLD TIME. The PC-98 keyboard sends a make code on press and a break code on release; the BIOS buffer
# gets the make, but a program that polls the key state (the BIOS key-state map at 0x52A, or the
# keyboard port directly) sees the key only while it is down. On a card, arrows reached NEC DOS's line
# editor and a game menu at 0, 5 and 40 ms holds. Past 500 ms the core's typematic repeat (pc9821_kbd.sv,
# NP2kai's 500 ms delay and 50 ms interval) re-sends the key: a 1 s hold typed 12 characters.
import fcntl, os, struct, sys, time
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1
SH, CTRL = 42, 29
ARROWS = {'U': 103, 'L': 105, 'R': 106, 'D': 108, 'E': 1}   # KEY_UP/LEFT/RIGHT/DOWN, KEY_ESC

# char -> (Linux key code, shift, PC-98 key code it must reach)
MAP = {}
for i, c in enumerate("1234567890"): MAP[c] = (2 + i, False, 0x01 + i)
for i, c in enumerate("qwertyuiop"): MAP[c] = (16 + i, False, 0x10 + i)
for i, c in enumerate("asdfghjkl"): MAP[c] = (30 + i, False, 0x1D + i)
for i, c in enumerate("zxcvbnm"): MAP[c] = (44 + i, False, 0x29 + i)
for c in list(MAP):
    if c.isalpha(): MAP[c.upper()] = (MAP[c][0], True, MAP[c][2])
MAP.update({
    ' ': (57, False, 0x34), '\n': (28, False, 0x1C),
    '-': (12, False, 0x0B), '^': (13, False, 0x0C), ';': (39, False, 0x26), ':': (40, False, 0x27),
    ',': (51, False, 0x30), '.': (52, False, 0x31), '/': (53, False, 0x32),
    '!': (2, True, 0x01), '"': (3, True, 0x02), '#': (4, True, 0x03), '$': (5, True, 0x04), '%': (6, True, 0x05),
    '&': (7, True, 0x06), "'": (8, True, 0x07), '(': (9, True, 0x08), ')': (10, True, 0x09),
    '=': (12, True, 0x0B), '`': (13, True, 0x0C), '+': (39, True, 0x26), '*': (40, True, 0x27),
    '<': (51, True, 0x30), '>': (52, True, 0x31), '?': (53, True, 0x32),
    '_': (86, True, 0x33),                       # KEY_102ND, not KEY_RO: see THE RO KEY above
})
# The layout keys (see THE LAYOUT above): Linux key per layout for the PC-98 keys 0x1A '@~', 0x1B '[{',
# 0x28 ']}' and 0x0D (YEN, BIOS 0x5C '\\' and shift '|').
LAYOUT_KEYS = {'us': {0x1A: 41, 0x1B: 26, 0x28: 27, 0x0D: 43},     # KEY_GRAVE, LEFTBRACE, RIGHTBRACE, BACKSLASH
               'jis': {0x1A: 26, 0x1B: 27, 0x28: 43, 0x0D: 124}}   # KEY_LEFTBRACE, RIGHTBRACE, BACKSLASH, YEN
LAYOUT_CHARS = {0x1A: '@~', 0x1B: '[{', 0x28: ']}', 0x0D: '\\|'}
DEFAULT_LAYOUT = 'us'   # the OSD Keyboard field's position 0 (z486_mister.sv "O[51],Keyboard,US,JIS")


def char_map(layout):
    """The character table for one layout: char -> (Linux key code, shift, PC-98 key code)."""
    m = dict(MAP)
    for pc98, code in LAYOUT_KEYS[layout].items():
        lo, hi = LAYOUT_CHARS[pc98]
        m[lo] = (code, False, pc98)
        m[hi] = (code, True, pc98)
    return m

# --selftest reference data. BIOS_NORMAL/BIOS_SHIFT: the BIOS key table's normal and shift rows for PC-98
# codes 0x00-0x34 (NP2kai bios/keytable.res; '.' = a non-printing entry; YEN 0x0D is 0x5C '\').
BIOS_NORMAL = ".1234567890-^\\..qwertyuiop@[.asdfghjkl;:]zxcvbnm,./. "
BIOS_SHIFT = ".!\"#$%&'()0=`|..QWERTYUIOP~{.ASDFGHJKL+*}ZXCVBNM<>?_ "
# Main_MiSTer input.cpp ev2ps2[] (the PS/2 set-2 table) for the Linux codes ztype sends; 0x100 = E0 prefix.
# (41 KEY_GRAVE 0x0e, 89 KEY_RO 0x51, 124 KEY_YEN 0x6a.)
EV2PS2 = {1: 0x76, 2: 0x16, 3: 0x1E, 4: 0x26, 5: 0x25, 6: 0x2E, 7: 0x36, 8: 0x3D, 9: 0x3E, 10: 0x46, 11: 0x45,
          12: 0x4E, 13: 0x55, 16: 0x15, 17: 0x1D, 18: 0x24, 19: 0x2D, 20: 0x2C, 21: 0x35, 22: 0x3C, 23: 0x43,
          24: 0x44, 25: 0x4D, 26: 0x54, 27: 0x5B, 28: 0x5A, 29: 0x14, 30: 0x1C, 31: 0x1B, 32: 0x23, 33: 0x2B,
          34: 0x34, 35: 0x33, 36: 0x3B, 37: 0x42, 38: 0x4B, 39: 0x4C, 40: 0x52, 42: 0x12, 43: 0x5D, 44: 0x1A,
          45: 0x22, 46: 0x21, 47: 0x2A, 48: 0x32, 49: 0x31, 50: 0x3A, 51: 0x41, 52: 0x49, 53: 0x4A, 57: 0x29,
          86: 0x61, 103: 0x175, 105: 0x16B, 106: 0x174, 108: 0x172, 41: 0x0E, 89: 0x51, 124: 0x6A}
ARROW_PC98 = {103: 0x3A, 105: 0x3B, 106: 0x3C, 108: 0x3D, 1: 0x00}   # NP2kai keytable.res row 38h: up, left, right, down


def parse(text, cmap=None):
    """text -> a list of steps: ('key', code, shift) | ('ctrl', code) | ('wait', ms)."""
    cmap = cmap or char_map(DEFAULT_LAYOUT)
    text = text.replace('\\n', '\n')
    out, i = [], 0
    while i < len(text):
        if text[i] == '~' and i + 1 < len(text) and text[i + 1] in 'ksw':
            j = text.index(';', i); n = int(text[i + 2:j])
            out.append(('wait', n) if text[i + 1] == 'w' else ('key', n, text[i + 1] == 's'))
            if text[i + 1] != 'w': out.append(('wait', 250))
            i = j + 1; continue
        if text.startswith('~C', i): out.append(('ctrl', 46)); i += 2; continue
        if text[i] == '~' and i + 1 < len(text) and text[i + 1] in ARROWS:
            out.append(('key', ARROWS[text[i + 1]], False)); i += 2; continue
        ch = text[i]; i += 1
        if ch not in cmap: raise SystemExit('unmapped: %r' % ch)
        out.append(('key', cmap[ch][0], cmap[ch][1]))
    return out


def events(steps, hold, gap):
    """steps -> a list of (type, code, value) or ('sleep', ms)."""
    ev = []
    def key(c, v): ev.extend([(EV_KEY, c, v), (EV_SYN, 0, 0)])
    for s in steps:
        if s[0] == 'wait': ev.append(('sleep', s[1])); continue
        mod = SH if s[0] == 'key' and s[2] else CTRL if s[0] == 'ctrl' else None
        if mod: key(mod, 1); ev.append(('sleep', 30))
        key(s[1], 1); ev.append(('sleep', hold)); key(s[1], 0); ev.append(('sleep', gap))
        if mod: key(mod, 0); ev.append(('sleep', 30))
    return ev


def translate_table(sv):
    """Parse translate() of pc9821_kbd.sv: {layout: {(extended, set2): pc98}} for 'us' and 'jis'.
    A row is `8'hXX: translate = 8'hYY;` (both layouts) or `8'hXX: translate = jis ? 8'hJJ : 8'hUU;`."""
    import re
    t, ext = {'us': {}, 'jis': {}}, None
    for line in open(sv):
        if 'function automatic [7:0] translate' in line: ext = True; continue
        if ext is None: continue
        if 'end else begin' in line: ext = False
        if 'endfunction' in line: break
        m = re.match(r"\s*((?:8'h[0-9A-Fa-f]{2},\s*)*8'h[0-9A-Fa-f]{2}):\s*translate\s*=\s*"
                     r"(?:jis\s*\?\s*8'h([0-9A-Fa-f]{2})\s*:\s*)?8'h([0-9A-Fa-f]{2})", line)
        if m:
            uv = int(m.group(3), 16)
            jv = int(m.group(2), 16) if m.group(2) else uv
            for k in re.findall(r"8'h([0-9A-Fa-f]{2})", m.group(1)):
                for lay, v in (('us', uv), ('jis', jv)):
                    if v != 0xFF: t[lay][(ext, int(k, 16))] = v
    return t


def selftest():
    import re
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.join(here, '..', '..')
    tables = translate_table(os.path.join(root, 'src', 'pc9821', 'input', 'pc9821_kbd.sv'))
    bad, n = [], 0
    for lay in ('us', 'jis'):
        tr = tables[lay]
        assert tr.get((True, 0x75)) == 0x3A and tr.get((False, 0x1C)) == 0x1D, 'translate() parse failed'
        cmap = char_map(lay)
        for ch, (code, sh, want) in sorted(cmap.items()):
            ps2 = EV2PS2[code]
            got = tr.get((bool(ps2 & 0x100), ps2 & 0xFF))
            row = BIOS_SHIFT if sh else BIOS_NORMAL
            out = row[got] if got is not None and got < len(row) else None
            if ch == '\n': out = '\n' if got == 0x1C else None
            if got != want or out != ch:
                bad.append('%s %r: Linux %d -> set-2 %03X -> PC-98 %s (want %02X) -> %r'
                           % (lay, ch, code, ps2, None if got is None else '%02X' % got, want, out))
        for code, want in ARROW_PC98.items():
            ps2 = EV2PS2[code]
            got = tr.get((bool(ps2 & 0x100), ps2 & 0xFF))
            if got != want: bad.append('%s Linux %d -> set-2 %03X -> PC-98 %s (want %02X)' % (lay, code, ps2, None if got is None else '%02X' % got, want))
        for ch in ']}\\|@[':
            if ch not in cmap: bad.append('%s: %r is not typeable' % (lay, ch))
        n += len(cmap)
    # Every set-2 code whose translation differs between the layouts is one LAYOUT_KEYS covers.
    diff = sorted(k for k in set(tables['us']) | set(tables['jis']) if tables['us'].get(k) != tables['jis'].get(k))
    keyed = sorted({(False, EV2PS2[c] & 0xFF) for lay in LAYOUT_KEYS for c in LAYOUT_KEYS[lay].values()
                    if (EV2PS2[c] & 0xFF) in [k[1] for k in diff]})
    if [k for k in diff] != keyed: bad.append('layout rows %r != the keys ztype switches %r' % (diff, keyed))
    conf = open(os.path.join(root, 'z486_mister.sv')).read()
    m = re.search(r'"O\[51\],Keyboard,(\w+),', conf)
    if not m or m.group(1).lower() != DEFAULT_LAYOUT:
        bad.append('DEFAULT_LAYOUT %r is not the OSD Keyboard position 0 %r' % (DEFAULT_LAYOUT, m and m.group(1)))
    st = parse('cd v_b1~L~k28;')
    if st[4] != ('key', 86, True) or st[7] != ('key', 105, False) or st[8:] != [('key', 28, False), ('wait', 250)]:
        bad.append('parse: %r' % st)
    if parse(']', char_map('jis')) != [('key', 43, False)] or parse(']', char_map('us')) != [('key', 27, False)]:
        bad.append('parse ] per layout')
    ev = events([('key', 86, True)], 300, 40)
    if ev[2:7] != [('sleep', 30), (EV_KEY, 86, 1), (EV_SYN, 0, 0), ('sleep', 300), (EV_KEY, 86, 0)]:
        bad.append('events: %r' % ev)
    print('\n'.join(bad) or 'ztype selftest: %d characters over both layouts, the arrows and Esc check through the chain' % n)
    return 1 if bad else 0


def main(argv):
    hold, gap, dry, rest, layout = 40, 40, False, [], DEFAULT_LAYOUT
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--hold': hold = int(argv[i + 1]); i += 1
        elif a == '--gap': gap = int(argv[i + 1]); i += 1
        elif a == '--dry': dry = True
        elif a == '--layout':
            layout = argv[i + 1].lower(); i += 1
            if layout not in LAYOUT_KEYS: raise SystemExit('--layout: us or jis')
        elif a == '--selftest': return selftest()
        elif a == '--list':
            for ch, (code, sh, pc) in sorted(char_map(layout).items()):
                print('%-4r %sLinux %3d -> PC-98 %02X' % (ch, 'shift+' if sh else '      ', code, pc))
            for n, code in sorted(ARROWS.items()): print('~%s         Linux %3d -> PC-98 %02X' % (n, code, ARROW_PC98[code]))
            return 0
        else: rest.append(a)
        i += 1
    if len(rest) != 1: raise SystemExit('usage: ztype.py [--layout us|jis] [--hold MS] [--gap MS] [--dry] TEXT | --list | --selftest')
    ev = events(parse(rest[0], char_map(layout)), hold, gap)
    if dry:
        for e in ev: print(*e)
        return 0
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in range(1, 128): fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    os.write(fd, struct.pack('80sHHHHi', b'ztype', 3, 1, 1, 1, 0) + b'\0' * (64 * 4 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(1.5)
    for e in ev:
        if e[0] == 'sleep': time.sleep(e[1] / 1000.0)
        else: os.write(fd, struct.pack('@llHHi', 0, 0, *e))
    time.sleep(0.5)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
