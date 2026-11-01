#!/usr/bin/env python3
"""Generate tools/hwprobe/gdcfig/gdcfig.s - a deterministic picture drawn by the graphics GDC.

GDCFIG draws lines, arcs (whole circles from eight octant arcs, and partial arcs with a DM
start), rectangles, area fills, patterned lines, the four ROPs and 8x8 graphics characters
(zoom 1/2/4, slanted, two directions, through the GRCG) with the slave uPD7220's own figure
commands (FIGS 0x4C, FIGD 0x6C, GCHRD 0x68, TEXTW 0x78, ZOOM 0x46, CSRW 0x49), then waits
for a key with the picture up. The SAME binary run on the core and on a real PC-9821 gives
two pictures to compare dot for dot (todo item 126: the arcs have no capture yet).

Every figure's parameters are computed HERE, with the uPD7220 datasheet's parameter table
(the same formulas NP2kai's own BIOS uses: bios/bios18.c, gdcsub_setvectl for lines), and
emitted as a byte stream the probe replays through ports 0xA2/0xA0, waiting on status
bit 1 (FIFO FULL) before each byte as the datasheet's protocol says. Nothing depends on a
timer or on the machine's speed, so the picture is the same on every run.

Usage: python3 tools/hwprobe/gdcfig/gdcfig_gen.py   (rewrites gdcfig.s next to it)
"""

from __future__ import annotations

import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "gdcfig.s"

E, B, R, G = 0, 1, 2, 3          # the GDC's plane field (EAD bits 15:14): NP2kai gdcplaneseg
OP_A2, OP_A0, OP_IDLE, OP_GRCG_MODE, OP_GRCG_TILE, OP_END = 1, 2, 3, 4, 5, 0

stream: list[tuple[int, int, str]] = []


def cmd(b, note=""):
    stream.append((OP_A2, b & 0xFF, note))


def par(b):
    stream.append((OP_A0, b & 0xFF, ""))


def w14(v):
    return v & 0x3FFF


def csrw(x, y, plane):
    ead = (plane << 14) | (y * 40 + (x >> 4))
    cmd(0x49, f"CSRW ({x},{y}) plane {plane}")
    par(ead & 0xFF)
    par(ead >> 8)
    par((x & 15) << 4)


def figs(p1, dc=0, d=8, d2=8, d1=0x3FFF, dm=0x3FFF):
    cmd(0x4C, f"FIGS P1={p1:02X} DC={dc} D={d} D2={d2} D1={d1} DM={dm}")
    par(p1)
    for v in (dc, d, d2, d1, dm):
        par(w14(v) & 0xFF)
        par(w14(v) >> 8)


def rop(r):
    cmd(0x20 | r, f"ROP {r} (WDAT mode, no data)")


def textw(ra):                  # RA8..RA15
    cmd(0x78, "TEXTW " + " ".join(f"{b:02X}" for b in ra))
    for b in ra:
        par(b)


def pattern(p16):                # FIGD's line pattern: RA9:RA8
    textw([p16 & 0xFF, p16 >> 8, 0, 0, 0, 0, 0, 0])


def zoom(z):
    cmd(0x46, f"ZOOM {z}")
    par(z - 1)


def idle():
    stream.append((OP_IDLE, 0, "wait until the draw is done"))


def line(x0, y0, x1, y1, plane):
    """NP2kai gdcsub_setvectl (the datasheet's line parameters)."""
    ope = 0
    dy = abs(y1 - y0)
    dx = x1 - x0
    if dx == 0:
        ope = 7 if y0 <= y1 else 3
    else:
        if dx > 0:
            if y0 >= y1:
                ope += 2
        else:
            dx = -dx
            ope += 4
            if y0 <= y1:
                ope += 2
        if ope & 2:
            if dx <= dy:
                ope += 1
        else:
            if dx >= dy:
                ope += 1
    if not ((ope + 1) & 2):
        dx, dy = dy, dx
    csrw(x0, y0, plane)
    figs(0x08 | ope, dc=dx, d=2 * dy - dx, d2=2 * dy - 2 * dx, d1=2 * dy, dm=0x3FFF)
    cmd(0x6C, f"FIGD line ({x0},{y0})-({x1},{y1})")


# The octant arcs of a circle: (start offset from the centre, octant). Octant n's axial step
# is direction n (even) / n+1 (odd) - NP2kai gdcsub_vectc's eight cases.
ARC_STARTS = {0: (-1, 0), 7: (1, 0), 3: (-1, 0), 4: (1, 0),
              1: (0, -1), 6: (0, -1), 2: (0, 1), 5: (0, 1)}


def arc(cx, cy, r, octant, plane, dm=0):
    """The datasheet's arc: DC = r sin 45, D = r - 1, D2 = 2(r - 1), D1 = -1, DM = r sin(theta)."""
    sx, sy = ARC_STARTS[octant]
    csrw(cx + sx * r, cy + sy * r, plane)
    figs(0x20 | octant, dc=int(r / math.sqrt(2)), d=r - 1, d2=2 * (r - 1), d1=0x3FFF, dm=dm)
    cmd(0x6C, f"FIGD arc r={r} octant {octant} DM={dm}")


def circle(cx, cy, r, plane):
    for o in range(8):
        arc(cx, cy, r, o, plane)


def rect(x, y, a, b, plane, direction=0):
    """The datasheet's rectangle: DC = 3, D = A - 1, D2 = B - 1, D1 = -1, DM = A - 1."""
    csrw(x, y, plane)
    figs(0x40 | direction, dc=3, d=a - 1, d2=b - 1, d1=0x3FFF, dm=a - 1)
    cmd(0x6C, f"FIGD rect {a}x{b} dir {direction}")


def area(x, y, w, h, plane):
    """GCHRD area fill (solid PRAM), direction 0: DC = w - 1 columns of D = h dots."""
    textw([0xFF] * 8)
    zoom(1)
    csrw(x, y, plane)
    figs(0x10, dc=w - 1, d=h, d2=h)
    cmd(0x68, f"GCHRD area {w}x{h}")


def dot(x, y, plane):
    csrw(x, y, plane)
    figs(0x00)
    cmd(0x6C, f"FIGD dot ({x},{y})")


GLYPH = [".XXXXX..",
         "X.....X.",
         "X.......",
         "X..XXXX.",
         "X.....X.",
         "X.....X.",
         ".XXXXX..",
         "........"]


def glyph_ra(rows):
    """RA8 = the top row ... RA15 = the bottom row, bit 0 = the leftmost dot (direction 2)."""
    return [sum(1 << i for i, c in enumerate(r) if c == "X") for r in rows]


def char(x, y, z, direction=2, slant=False, plane=B):
    """GCHRD 8x8: DC = 7 rows, D = 8 dots; (x, y) is the bottom-left dot for direction 2."""
    textw(glyph_ra(GLYPH))
    zoom(z)
    csrw(x, y, plane)
    figs((0x80 if slant else 0) | 0x10 | direction, dc=7, d=8, d2=8)
    cmd(0x68, f"GCHRD char zoom {z} dir {direction}{' slanted' if slant else ''}")


def build():
    # ---- 1. a fan of 24 lines, every 15 degrees (plane R) ----
    rop(3)
    pattern(0xFFFF)
    for k in range(24):
        a = 2 * math.pi * k / 24
        line(160, 120, 160 + round(95 * math.cos(a)), 120 + round(95 * math.sin(a)), R)
    # ---- 2. circles of radius 15, 40, 70, 95 from eight octant arcs (plane G) ----
    for r in (15, 40, 70, 95):
        circle(480, 120, r, G)
    # partial arcs from a DM start (r sin 20 = 19 of 55), and a dashed circle (plane B)
    arc(480, 120, 55, 0, B, dm=19)
    arc(480, 120, 55, 1, B, dm=19)
    pattern(0xCCCC)
    circle(560, 330, 30, B)
    # ---- 3. rectangles (plane B), straight and turned ----
    pattern(0xFFFF)
    # direction 0 walks side A down first, then side B right: (x, y) is the top-left corner
    rect(30, 230, 60, 120, B)
    rect(45, 240, 40, 90, B)
    rect(230, 235, 40, 25, B, direction=1)
    rect(330, 290, 20, 30, B, direction=3)
    rect(250, 330, 30, 15, B, direction=5)
    # ---- 4. an area fill and the ROPs across it (plane R) ----
    area(420, 230, 64, 32, R)
    pattern(0xFFFF)
    rop(1)
    line(400, 240, 505, 255, R)          # COMPLEMENT: a gap through the fill, a line outside it
    rop(2)
    line(410, 270, 500, 236, R)          # CLEAR: a gap through the fill only
    rop(0)
    pattern(0xF00F)
    line(400, 250, 505, 250, R)          # REPLACE with a pattern: 0 bits clear, 1 bits set
    rop(3)
    # ---- 5. patterned lines (plane B, SET) ----
    for i, p in enumerate((0xFFFF, 0xF0F0, 0xAAAA, 0xFF00, 0x8421)):
        pattern(p)
        line(30, 310 + 6 * i, 200, 310 + 6 * i, B)
    pattern(0xFFFF)
    for i in range(8):
        dot(30 + 4 * i, 345, G)
    # ---- 6. graphics characters through the GRCG RMW in white (B, R, G tiles FF, E 00) ----
    idle()
    stream.append((OP_GRCG_MODE, 0xC0, "GRCG RMW, all planes"))
    for t in (0xFF, 0xFF, 0xFF, 0x00):
        stream.append((OP_GRCG_TILE, t, ""))
    char(200, 380, 1)
    char(220, 380, 2)
    char(250, 380, 4)
    char(300, 380, 2, slant=True)
    char(360, 372, 2, direction=0)
    idle()
    stream.append((OP_GRCG_MODE, 0x00, "GRCG off"))
    # ---- 7. two overlapping complemented area fills (plane G) ----
    rop(1)
    area(420, 300, 48, 40, G)
    area(444, 320, 48, 40, G)
    rop(3)
    idle()
    stream.append((OP_END, 0, ""))


TEMPLATE_HEAD = r"""/* gdcfig.s - GENERATED by gdcfig_gen.py (do not edit; run the generator).
 *
 * A deterministic picture drawn by the graphics GDC's own figure commands: a fan of lines,
 * circles from octant arcs and partial arcs, rectangles (straight and turned), an area fill
 * with COMPLEMENT/CLEAR/REPLACE lines across it, patterned lines, dots, and 8x8 graphics
 * characters (zoom 1/2/4, slanted, two directions) through the GRCG. Run the SAME binary on
 * the core and on a real PC-9821 and compare the two pictures (todo item 126).
 *
 * It sets 640x400 colour graphics (INT 18h AH=42h CH=C0h, AH=40h), clears the four planes,
 * turns the GRCG off and replays the stream below through ports 0xA2/0xA0, waiting on
 * status bit 1 (FIFO FULL) before each byte. It then waits for DRAWING (bit 3) to clear
 * and for a key, and exits with the picture still displayed (the GRCG left off).
 * Assumes the 2.5 MHz GDC strap's pitch of 40 words per line (the BIOS's own setting).
 *
 * Build: make -C tools/hwprobe gdcfig/gdcfig.com
 * Run:   GDCFIG       (from a plain DOS prompt; press a key when the picture is checked)
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     dx, offset s_clear          /* clear the text screen, hide the key line */
    call    puts
    mov     ah, 0x42                    /* 640x400 colour, display page 0 */
    mov     ch, 0xC0
    int     0x18
    mov     ah, 0x40                    /* graphics display on */
    int     0x18
    xor     al, al
    out     0xA6, al                    /* the CPU/GDC access page 0 */
    out     0x7C, al                    /* GRCG off */
    /* clear the four planes (B A800, R B000, G B800, E E000) */
    cld
    mov     bx, offset planes
1:  mov     ax, [bx]
    or      ax, ax
    jz      2f
    mov     es, ax
    xor     di, di
    xor     ax, ax
    mov     cx, 0x4000
    rep     stosw
    add     bx, 2
    jmp     1b
2:  mov     ax, cs
    mov     es, ax

    /* replay the stream: {op, value} byte pairs */
    mov     si, offset stream
3:  lodsw                               /* al = op, ah = value */
    cmp     al, 1
    je      op_a2
    cmp     al, 2
    je      op_a0
    cmp     al, 3
    je      op_idle
    cmp     al, 4
    je      op_gmode
    cmp     al, 5
    je      op_gtile
    jmp     done
op_a2:
    call    wait_notfull
    mov     al, ah
    out     0xA2, al
    jmp     3b
op_a0:
    call    wait_notfull
    mov     al, ah
    out     0xA0, al
    jmp     3b
op_idle:
    call    wait_idle
    jmp     3b
op_gmode:
    mov     al, ah
    out     0x7C, al
    jmp     3b
op_gtile:
    mov     al, ah
    out     0x7E, al
    jmp     3b

done:
    call    wait_idle
    mov     dx, offset s_done
    call    puts
    mov     ah, 0x08                    /* wait for a key, no echo */
    int     0x21
    mov     ax, 0x4C00
    int     0x21

wait_notfull:                           /* status bit 1: the FIFO is FULL */
    push    ax
4:  in      al, 0xA0
    test    al, 0x02
    jnz     4b
    pop     ax
    ret
wait_idle:                              /* DRAWING (bit 3) clear and the FIFO EMPTY (bit 2) */
    push    ax
5:  in      al, 0xA0
    and     al, 0x0C
    cmp     al, 0x04
    jne     5b
    pop     ax
    ret
puts:                                   /* DX = '$'-terminated string */
    push    ax
    mov     ah, 0x09
    int     0x21
    pop     ax
    ret

s_clear:    .ascii "\x1b[2J\x1b[>1h\x1b[>5h$"
s_done:     .ascii "GDCFIG v1 done - press a key$"
planes:     .word 0xA800, 0xB000, 0xB800, 0xE000, 0
stream:
"""


def render() -> str:
    L = [TEMPLATE_HEAD]
    for op, val, note in stream:
        c = f"   /* {note} */" if note else ""
        L.append(f"    .byte {op}, 0x{val:02X}{c}\n")
    return "".join(L)


def main():
    build()
    OUT.write_text(render())
    n = sum(1 for s in stream if s[0] in (OP_A2, OP_A0))
    print(f"wrote {OUT} ({n} GDC bytes)")


if __name__ == "__main__":
    main()
