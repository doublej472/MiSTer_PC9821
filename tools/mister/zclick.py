#!/usr/bin/env python3
# zclick.py - a uinput mouse on the MiSTer (runs ON the MiSTer; tools/mister_regress.py copies it to
# /tmp/zreg/ and deletes it afterwards): an optional relative move (dx dy), then a left click.
# Usage: zclick.py [options] [dx dy]
#   dx dy         relative move in mickeys, in --steps steps of dx//steps, dy//steps each (default 10
#                 steps, so the total is steps*(dx//steps): `-114 -76` moves -120 -80, as it always has)
#   --home        first a large up-left move in many small steps, so the guest's mouse driver clamps the
#                 cursor to the top-left corner of its range
#   --to X Y      --home, then move to the absolute pixel (X, Y): X*SX, Y*SY mickeys, split exactly into
#                 steps of at most 4 mickeys (or into --steps steps)
#   --scale SX SY mickeys per pixel for --to (default 1 1; measure it per driver with cursor probes)
#   --move-only   no click        --right   right button        --double   two clicks
#   --hold MS     button hold time (default 120)
#   --steps N     number of steps for the move
#   --dry         print the event stream instead of opening /dev/uinput (no device needed)
#   --selftest    check the event streams of a few command lines (runs anywhere, no device)
#
# THE MiSTer IS 32-BIT ARM, so `struct input_event` is `@llHHi` (16 bytes); a 64-bit `qq` timeval makes
# Main_MiSTer silently ignore every event. Wait ~1.5 s after UI_DEV_CREATE before the first event.
# Moves are sent as many small steps with a short sleep between them: a big per-event delta can hit a
# guest driver's acceleration, and the bus mouse latches at most +-127 per read (src/pc9821/input/pc9821_mouse.sv).
import fcntl, os, struct, sys, time
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x40045566, 0x5501, 0x5502
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
BTN_LEFT, BTN_RIGHT, REL_X, REL_Y = 0x110, 0x111, 0, 1
HOME_MICKEYS, HOME_STEP, TO_STEP, STEP_SLEEP = 2400, 40, 4, 0.015

def parse(argv):
    o = dict(home=False, to=None, scale=(1.0, 1.0), click=True, btn=BTN_LEFT, double=False, hold=120, steps=None,
             dry=False, rel=None)
    pos, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a == '--home': o['home'] = True
        elif a == '--to': o['to'] = (int(argv[i + 1]), int(argv[i + 2])); i += 2
        elif a == '--scale': o['scale'] = (float(argv[i + 1]), float(argv[i + 2])); i += 2
        elif a == '--move-only': o['click'] = False
        elif a == '--right': o['btn'] = BTN_RIGHT
        elif a == '--double': o['double'] = True
        elif a == '--hold': o['hold'] = int(argv[i + 1]); i += 1
        elif a == '--steps': o['steps'] = int(argv[i + 1]); i += 1
        elif a == '--dry': o['dry'] = True
        elif a.startswith('--'): sys.exit('zclick: unknown option ' + a)
        else: pos.append(int(a))
        i += 1
    if len(pos) not in (0, 2): sys.exit('zclick: give dx dy, or nothing')
    if pos: o['rel'] = tuple(pos)
    if o['steps'] is not None and o['steps'] < 1: sys.exit('zclick: --steps must be >= 1')
    return o

def split(total, n):
    """n integer deltas summing exactly to total"""
    return [(total * (k + 1)) // n - (total * k) // n for k in range(n)]

def plan(o):
    """the event stream: ('ev', type, code, value) and ('sleep', seconds) items, before device creation"""
    out = []
    def mv(xs, ys, gap=STEP_SLEEP):
        for x, y in zip(xs, ys):
            out.extend([('ev', EV_REL, REL_X, x), ('ev', EV_REL, REL_Y, y), ('ev', EV_SYN, 0, 0), ('sleep', gap)])
    if o['home'] or o['to']:
        n = HOME_MICKEYS // HOME_STEP
        mv([-HOME_STEP] * n, [-HOME_STEP] * n)
        out.append(('sleep', 0.3))
    if o['to']:
        tx, ty = round(o['to'][0] * o['scale'][0]), round(o['to'][1] * o['scale'][1])
        n = o['steps'] or max(1, -(-max(abs(tx), abs(ty)) // TO_STEP))
        mv(split(tx, n), split(ty, n))
    if o['rel']:
        dx, dy = o['rel']
        n = o['steps'] or 10
        mv([dx // n] * n, [dy // n] * n, 0.03)
    if o['click']:
        out.append(('sleep', 0.3))
        for k in range(2 if o['double'] else 1):
            if k: out.append(('sleep', 0.15))
            out.extend([('ev', EV_KEY, o['btn'], 1), ('ev', EV_SYN, 0, 0), ('sleep', o['hold'] / 1000.0),
                        ('ev', EV_KEY, o['btn'], 0), ('ev', EV_SYN, 0, 0)])
    out.append(('sleep', 0.5))
    return out

def totals(p):
    sx = sum(v for k, *r in p if k == 'ev' for t, c, v in [r] if t == EV_REL and c == REL_X)
    sy = sum(v for k, *r in p if k == 'ev' for t, c, v in [r] if t == EV_REL and c == REL_Y)
    btn = [(c, v) for k, *r in p if k == 'ev' for t, c, v in [r] if t == EV_KEY]
    return sx, sy, btn

def selftest():
    P = lambda s: plan(parse(s.split()))
    assert totals(P('')) == (0, 0, [(BTN_LEFT, 1), (BTN_LEFT, 0)])
    assert totals(P('400 120')) == (400, 120, [(BTN_LEFT, 1), (BTN_LEFT, 0)])
    assert totals(P('-114 -76'))[:2] == (-120, -80)                    # the legacy floor stepping, kept
    assert totals(P('--move-only 10 10'))[2] == []
    assert totals(P('--right --double'))[2] == [(BTN_RIGHT, 1), (BTN_RIGHT, 0)] * 2
    h = HOME_MICKEYS // HOME_STEP * HOME_STEP
    assert totals(P('--home --move-only'))[:2] == (-h, -h)
    assert totals(P('--to 321 99 --scale 1.5 2'))[:2] == (-h + 482, -h + 198)
    p = P('--to 321 99 --scale 1.5 2')
    assert max(abs(r[3]) for r in p if r[0] == 'ev' and r[1] == EV_REL) <= HOME_STEP
    q = [r for r in p if r[0] == 'ev' and r[1] == EV_REL][2 * (HOME_MICKEYS // HOME_STEP):]
    assert q and max(abs(r[3]) for r in q) <= TO_STEP
    assert totals(P('--to 100 50 --steps 7'))[:2] == (-h + 100, -h + 50)
    assert ('sleep', 0.25) in P('--hold 250')
    print('zclick selftest: OK')

if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        selftest(); sys.exit(0)
    o = parse(sys.argv[1:])
    p = plan(o)
    if o['dry']:
        for r in p: print(*r)
        sys.exit(0)
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY); fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL); fcntl.ioctl(fd, UI_SET_RELBIT, REL_X); fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
    os.write(fd, struct.pack('80sHHHHi', b'zclick', 3, 1, 2, 1, 0) + b'\0' * (64 * 4 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(1.5)
    for r in p:
        if r[0] == 'sleep': time.sleep(r[1])
        else: os.write(fd, struct.pack('@llHHi', 0, 0, r[1], r[2], r[3]))
    fcntl.ioctl(fd, UI_DEV_DESTROY)
