/* risky.s - the write-then-read rows the earlier kits left out because a write may hang or
 * move memory under DOS (todo items 28, 35, 97, 98). One item per run; the kit power-cycles
 * the machine after each.
 *
 *   RISKY /43F [/O FILE]  item 28: 0x043F written with every value 00-FF (one row each). The
 *       read is a strap-like answer, not a mirror (docs/probes/EMS.TXT `43F read-back after
 *       20/20/80/82/restore: C4 C4 C5 C7 CB`; docs/probes/SHADOWW.TXT `043F=5A -> C8`). Per row,
 *       under cli: write V, read 0x043F twice, read the F8000 window's first word and a 32 KiB
 *       dword sum (which ROM bank 0x043F's 0xE nibble shows), the B0000 word (the EMS window,
 *       0x2 nibble), then put the firmware's state back - 0x043F <- 0x20 (the EMS identity the
 *       BIOS mode-set writes, pc9821_iobus.sv ems_state) and 0x043D <- 0x02 (the bank restore
 *       SHADOWW.TXT proved: `BANK restore: 043D left at 02 (reproduces the as-found bank byte)`)
 *       - and read all three again. Values the machine already took without harm come first
 *       (the 0x2, 0x8, 0xE nibbles, 0xA0 the cache flush), unknown nibbles last. 0x8x's shadow
 *       enable is sticky, but the ITF already wrote 0x80 at boot (BANK4@0x1CD). A `ROW 43F vv`
 *       line is written and committed to the file before each write; run again with the same
 *       /O FILE after a hang and the sweep resumes after the value that hung (RESUME line).
 *   RISKY /989 [/O FILE]  item 35: 0x9890/0x9896/0x9892/0x9894 each written 00, 55, AA, 08 and
 *       put back to its as-found read; all five 0x989x/0x98E0 ports read after every write,
 *       and a fixed CPU loop timed on the ARTIC (does a write move the CPU clock? The ITF writes
 *       9894 <- 00, 9892 <- 00, 98E0 <- 05 and then resets the CPU when 0x9894 bit 3 is set,
 *       BANK4@0xFCAED-0xFCB11). Last row: 0x98E0 <- 05, the ITF's own value (no put-back:
 *       0x98E0 reads open bus FF, docs/probes/R10.TXT /MODE).
 *   RISKY /461 [/O FILE]  item 97: the 0x0461 window (128 KiB at 0x80000, page = value << 16,
 *       pc9821_memory_map.sv win0) at pages 00, 01, 02, 03, 04, 06 and the identity 08: four
 *       window words beside the same physical words read directly, and a marker written
 *       through the window over this program's own buffer (when the page covers it) read back
 *       directly - alias or hole. docs/probes/WIN.TXT read FFFF at page 0 with no comparison.
 *       Restored to the as-found read (09 maps as 08, WIN.TXT `after restore`).
 *   RISKY /43B [/O FILE]  item 98: 0x043B bit 2 (the 15-16 MiB system space): unreal-mode
 *       (FS 4 GiB) dword reads of 0xF00000 (PEGC window), 0xF80000 (hole), 0xFA0000 (the
 *       0xA0000 mirror) beside 0x0A0000, 0xFE8000 beside 0x0E8000, 0xFFFFF0 beside 0x0FFFF0,
 *       and a write/read/put-back at 0xF80000, as found and with bit 2 cleared, set, and each
 *       with bit 3 flipped (bit 3 reads F3/FB unstable on the machine, XE10CFG-XE10-CFG0.TXT);
 *       A20 opened for the run and put back; WBINVD after every 0x043B write. Real mode only
 *       (a V86 monitor: SKIP), plain DOS, nothing resident above 1 MiB.
 * Every item ends with RESTORE lines and `END:RISKY <item>`. Output: stdout, or /O FILE
 * (appended to; every line written and committed at once, INT 21h AH=68h, as xe10t's ROW
 * lines are). risky_decode.py tabulates a capture (--selftest).
 *
 * Build: make -C tools/hwprobe risky/risky.com
 * Run:   RISKY /43F /O R43F.TXT     (one item per boot; power-cycle after)
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    cld
    mov     bx, 0x1000                  /* keep 64 KiB, allocate a 32 KiB resume buffer */
    mov     ah, 0x4A
    int     0x21
    mov     bx, 0x0800
    mov     ah, 0x48
    int     0x21
    jc      1f
    mov     [bufseg], ax
1:
    /* ---- the command tail ---- */
    mov     si, 0x81
pa_next:
    lodsb
    cmp     al, 13
    je      pa_done
    cmp     al, '/'
    jne     pa_next
    mov     ax, [si]
    and     ax, 0xDFDF                  /* upper case for letters; digits keep bit 5 below */
    mov     bx, [si]
    cmp     bx, 0x3334                  /* "43" */
    jne     2f
    mov     al, [si+2]
    and     al, 0xDF
    cmp     al, 'F'
    jne     3f
    or      byte ptr [items], 1
    jmp     pa_next
3:  cmp     al, 'B'
    jne     pa_next
    or      byte ptr [items], 8
    jmp     pa_next
2:  cmp     bx, 0x3839                  /* "98" */
    jne     4f
    or      byte ptr [items], 2
    jmp     pa_next
4:  cmp     bx, 0x3634                  /* "46" */
    jne     5f
    or      byte ptr [items], 4
    jmp     pa_next
5:  cmp     al, 'O'
    jne     pa_next
    inc     si
6:  lodsb                               /* skip blanks */
    cmp     al, ' '
    je      6b
    cmp     al, 9
    je      6b
    dec     si
    mov     di, offset fname
7:  lodsb
    cmp     al, ' '
    jbe     8f
    cmp     al, '/'
    je      8f
    stosb
    cmp     di, offset fname + 63
    jb      7b
8:  mov     byte ptr [di], 0
    dec     si
    jmp     pa_next
pa_done:
    cmp     byte ptr [items], 0
    jne     9f
    mov     si, offset s_usage
    call    out_s
    call    out_nl
    mov     ax, 0x4C02
    int     0x21
9:
    /* ---- the output file: open (append) or create ---- */
    cmp     byte ptr [fname], 0
    je      10f
    mov     dx, offset fname
    mov     ax, 0x3D02
    int     0x21
    jnc     11f
    mov     dx, offset fname
    xor     cx, cx
    mov     ah, 0x3C
    int     0x21
    jc      10f
    mov     [handle], ax
    jmp     10f
11: mov     [handle], ax
    mov     byte ptr [existed], 1
    call    scan_resume                 /* finds the last `ROW 43F vv` */
    mov     bx, [handle]
    xor     cx, cx
    xor     dx, dx
    mov     ax, 0x4202
    int     0x21
10:
    mov     si, offset s_banner
    call    out_s
    call    out_nl
    test    byte ptr [items], 2
    jz      12f
    call    item_989
12: test    byte ptr [items], 4
    jz      13f
    call    item_461
13: test    byte ptr [items], 8
    jz      14f
    call    item_43b
14: test    byte ptr [items], 1
    jz      15f
    call    item_43f
15: mov     bx, [handle]
    cmp     bx, 2
    jbe     16f
    mov     ah, 0x3E
    int     0x21
16: mov     ax, 0x4C00
    int     0x21

/* ======================================================================
 * item 28: 0x043F
 * ====================================================================== */
item_43f:
    mov     si, offset s_b43f
    call    out_s
    call    out_nl
    mov     dx, 0x043F
    in      al, dx
    mov     [f_first], al
    call    rom_view                    /* f8w, f8s, b0w as found */
    mov     ax, [v_f8w]
    mov     [a_f8w], ax
    mov     eax, [v_f8s]
    mov     [a_f8s], eax
    mov     ax, [v_b0w]
    mov     [a_b0w], ax
    mov     si, offset s_asf43f
    call    out_s
    mov     al, [f_first]
    call    hex8
    mov     si, offset s_f8w
    call    out_s
    mov     ax, [a_f8w]
    call    hex16
    mov     si, offset s_f8s
    call    out_s
    mov     eax, [a_f8s]
    call    hex32
    mov     si, offset s_b0w
    call    out_s
    mov     ax, [a_b0w]
    call    hex16
    call    out_nl
    /* the start index: 0, or one past the value a previous run hung on */
    xor     bx, bx
    cmp     byte ptr [res_have], 0
    je      21f
    mov     al, [res_val]
    mov     di, offset ord43f
    mov     cx, 256
    repne   scasb
    mov     bx, di
    sub     bx, offset ord43f           /* index of the hung value + 1 */
    mov     si, offset s_resume
    call    out_s
    mov     al, [res_val]
    call    hex8
    mov     si, offset s_resume2
    call    out_s
    call    out_nl
21: cmp     bx, 256
    jae     29f
    mov     al, [ord43f+bx]
    mov     [cur], al
    push    bx
    mov     si, offset s_row43f
    call    out_s
    mov     al, [cur]
    call    hex8
    call    out_nl                      /* committed before the write */
    cli
    mov     dx, 0x043F
    mov     al, [cur]
    out     dx, al
    wbinvd
    in      al, dx
    mov     [r1], al
    out     0x5F, al                    /* ~0.6 us wait (the machine's wait port) */
    out     0x5F, al
    in      al, dx
    mov     [r2], al
    call    rom_view
    mov     ax, [v_f8w]
    mov     [w_f8w], ax
    mov     eax, [v_f8s]
    mov     [w_f8s], eax
    mov     ax, [v_b0w]
    mov     [w_b0w], ax
    mov     dx, 0x043F                  /* the firmware's state back */
    mov     al, 0x20
    out     dx, al
    mov     dx, 0x043D
    mov     al, 0x02
    out     dx, al
    wbinvd
    mov     dx, 0x043F
    in      al, dx
    mov     [r3], al
    call    rom_view
    sti
    /* R43F vv r1 r2 f8w f8sum b0w | 20/02 -> r3 f8w f8sum b0w ok|BAD */
    mov     si, offset s_r43f
    call    out_s
    mov     al, [cur]
    call    hex8
    call    putsp
    mov     al, [r1]
    call    hex8
    call    putsp
    mov     al, [r2]
    call    hex8
    call    putsp
    mov     ax, [w_f8w]
    call    hex16
    call    putsp
    mov     eax, [w_f8s]
    call    hex32
    call    putsp
    mov     ax, [w_b0w]
    call    hex16
    mov     si, offset s_rst
    call    out_s
    mov     al, [r3]
    call    hex8
    call    putsp
    mov     ax, [v_f8w]
    call    hex16
    call    putsp
    mov     eax, [v_f8s]
    call    hex32
    call    putsp
    mov     ax, [v_b0w]
    call    hex16
    mov     eax, [v_f8s]
    cmp     eax, [a_f8s]
    jne     22f
    mov     ax, [v_b0w]
    cmp     ax, [a_b0w]
    jne     22f
    mov     si, offset s_ok
    jmp     23f
22: mov     si, offset s_bad
23: call    out_s
    call    out_nl
    pop     bx
    inc     bx
    jmp     21b
29: mov     si, offset s_rs43f
    call    out_s
    mov     dx, 0x043F
    in      al, dx
    call    hex8
    call    out_nl
    mov     si, offset s_e43f
    call    out_s
    call    out_nl
    ret

/* the F8000 window's first word and its 32 KiB dword sum, the B0000 word (interrupts as the
 * caller has them; reads only) */
rom_view:
    push    ds
    push    si
    push    cx
    push    bx
    mov     ax, 0xF800
    mov     ds, ax
    mov     bx, [0]
    xor     si, si
    xor     edx, edx
    mov     cx, 0x2000
1:  add     edx, [si]
    add     si, 4
    loop    1b
    mov     ax, 0xB000
    mov     ds, ax
    mov     cx, [0]
    mov     ax, cs
    mov     ds, ax
    mov     [v_f8w], bx
    mov     [v_f8s], edx
    mov     [v_b0w], cx
    pop     bx
    pop     cx
    pop     si
    pop     ds
    ret

/* the resume point: the last `ROW 43F vv` in the existing file (read into bufseg) */
scan_resume:
    cmp     word ptr [bufseg], 0
    je      9f
    push    ds
    mov     bx, [handle]
    mov     cx, 0x7FF0
    xor     dx, dx
    mov     ax, [bufseg]
    mov     ds, ax
    mov     ah, 0x3F
    int     0x21
    pop     ds
    jc      9f
    mov     cx, ax                      /* bytes read */
    cmp     cx, 10
    jb      9f
    sub     cx, 9
    push    es
    mov     es, [bufseg]
    xor     di, di
1:  cmp     dword ptr es:[di], 0x20574F52     /* "ROW " */
    jne     2f
    cmp     dword ptr es:[di+4], 0x20463334   /* "43F " */
    jne     2f
    mov     al, es:[di+8]
    call    hexval
    jc      2f
    mov     ah, al
    mov     al, es:[di+9]
    call    hexval
    jc      2f
    shl     ah, 4
    or      al, ah
    mov     [res_val], al
    mov     byte ptr [res_have], 1
2:  inc     di
    loop    1b
    pop     es
9:  ret
hexval:                                 /* AL ascii hex -> AL 0-15, CF on a non-digit */
    sub     al, '0'
    jb      8f
    cmp     al, 9
    jbe     7f
    sub     al, 7
    cmp     al, 10
    jb      8f
    cmp     al, 15
    ja      8f
7:  clc
    ret
8:  stc
    ret

/* ======================================================================
 * item 35: 0x989x
 * ====================================================================== */
item_989:
    mov     si, offset s_b989
    call    out_s
    call    out_nl
    xor     bx, bx                      /* each port read alone first, its ROW committed */
30: mov     si, offset s_rd989
    call    out_s
    mov     dx, [p989r+bx]
    mov     ax, dx
    call    hex16
    call    out_nl
    mov     si, offset s_rdv
    call    out_s
    mov     ax, dx
    call    hex16
    mov     al, '='
    call    out_c
    in      al, dx
    call    hex8
    call    out_nl
    add     bx, 2
    cmp     bx, 10
    jb      30b
    mov     si, offset s_asf989
    call    out_s
    call    read989
    call    out_nl
    mov     si, offset s_loop
    call    out_s
    call    timeloop
    call    hex16
    call    putsp
    call    timeloop
    call    hex16
    call    putsp
    call    timeloop
    call    hex16
    call    out_nl
    xor     bx, bx                      /* port index */
31: cmp     bx, 4
    jae     38f
    push    bx
    shl     bx, 1
    mov     dx, [p989+bx]
    mov     [curp], dx
    in      al, dx
    mov     [r0], al
    xor     bx, bx                      /* pattern index */
32: cmp     bx, 4
    jae     34f
    mov     al, [pat989+bx]
    mov     [cur], al
    push    bx
    call    row989
    cli
    mov     dx, [curp]
    mov     al, [cur]
    out     dx, al
    sti
    call    res989
    pop     bx
    inc     bx
    jmp     32b
34: mov     al, [r0]                    /* put back the as-found read */
    mov     [cur], al
    call    row989
    cli
    mov     dx, [curp]
    mov     al, [r0]
    out     dx, al
    sti
    mov     si, offset s_restore
    call    out_s
    mov     ax, [curp]
    call    hex16
    mov     al, '='
    call    out_c
    mov     al, [r0]
    call    hex8
    call    out_nl
    call    res989
    pop     bx
    inc     bx
    jmp     31b
38: mov     word ptr [curp], 0x98E0      /* last: the ITF's own 98E0 <- 05 */
    mov     byte ptr [cur], 0x05
    call    row989
    cli
    mov     dx, 0x98E0
    mov     al, 0x05
    out     dx, al
    sti
    call    res989
    mov     si, offset s_rs989
    call    out_s
    call    out_nl
    mov     si, offset s_e989
    call    out_s
    call    out_nl
    ret
row989:
    mov     si, offset s_row989
    call    out_s
    mov     ax, [curp]
    call    hex16
    call    putsp
    mov     al, [cur]
    call    hex8
    jmp     out_nl
res989:                                 /* W989 pppp vv -> the five reads, loop ticks x2 */
    mov     si, offset s_w989
    call    out_s
    mov     ax, [curp]
    call    hex16
    call    putsp
    mov     al, [cur]
    call    hex8
    mov     si, offset s_arrow
    call    out_s
    call    read989
    mov     si, offset s_loopx
    call    out_s
    call    timeloop
    call    hex16
    call    putsp
    call    timeloop
    call    hex16
    jmp     out_nl
read989:                                /* prints 9890=xx 9892=xx 9894=xx 9896=xx 98E0=xx */
    push    bx
    xor     bx, bx
1:  mov     dx, [p989r+bx]
    mov     ax, dx
    call    hex16
    mov     al, '='
    call    out_c
    in      al, dx
    call    hex8
    call    putsp
    add     bx, 2
    cmp     bx, 10
    jb      1b
    pop     bx
    ret
/* a fixed CPU loop (65535 x dec/jnz) timed on the ARTIC (307.2 kHz): AX = ticks */
timeloop:
    push    bx
    push    cx
    cli
    call    artic16
    mov     bx, ax
    mov     cx, 0xFFFF
1:  dec     cx
    jnz     1b
    call    artic16
    sti
    sub     ax, bx
    pop     cx
    pop     bx
    ret
artic16:                                /* AX = ARTIC bits 15-0: mid, low, mid until the mids agree */
    push    dx
1:  in      al, 0x5D
    mov     dl, al
    in      al, 0x5C
    mov     ah, al
    in      al, 0x5D
    cmp     al, dl
    jne     1b
    mov     al, ah
    mov     ah, dl
    pop     dx
    ret

/* ======================================================================
 * item 97: 0x0461
 * ====================================================================== */
item_461:
    mov     si, offset s_b461
    call    out_s
    call    out_nl
    mov     dx, 0x0461
    in      al, dx
    mov     [r0], al
    mov     dx, 0x0463
    in      al, dx
    mov     [r1], al
    /* this program's marker cell: physical address */
    xor     eax, eax
    mov     ax, cs
    shl     eax, 4
    add     eax, offset mark461
    mov     [mphys], eax
    push    es
    mov     ax, 0x8000
    mov     es, ax
    mov     ax, es:[0]
    mov     [a_w80], ax
    pop     es
    mov     si, offset s_asf461
    call    out_s
    mov     al, [r0]
    call    hex8
    mov     si, offset s_463
    call    out_s
    mov     al, [r1]
    call    hex8
    mov     si, offset s_mphys
    call    out_s
    mov     eax, [mphys]
    call    hex32
    mov     si, offset s_w80
    call    out_s
    mov     ax, [a_w80]
    call    hex16
    call    out_nl
    xor     bx, bx
41: cmp     bx, 7
    jae     49f
    mov     al, [pg461+bx]
    mov     [cur], al
    push    bx
    mov     si, offset s_row461
    call    out_s
    mov     al, [cur]
    call    hex8
    call    out_nl
    /* does the window cover the marker? off = mphys - (page << 16), 0 <= off < 0x20000 */
    movzx   eax, byte ptr [cur]
    shl     eax, 16
    mov     edx, [mphys]
    sub     edx, eax
    mov     byte ptr [mk_in], 0
    cmp     edx, 0x20000
    jae     42f
    mov     byte ptr [mk_in], 1
    mov     [mk_off], edx
42: cli
    mov     dx, 0x0461
    mov     al, [cur]
    out     dx, al
    wbinvd
    in      al, dx
    mov     [r2], al
    push    es
    push    ds
    /* the window words: 8000:0000, 8000:0400, 9000:0000, 9000:FFFE */
    mov     ax, 0x8000
    mov     es, ax
    mov     ax, es:[0]
    mov     [ww+0], ax
    mov     ax, es:[0x400]
    mov     [ww+2], ax
    mov     ax, 0x9000
    mov     es, ax
    mov     ax, es:[0]
    mov     [ww+4], ax
    mov     ax, es:[0xFFFE]
    mov     [ww+6], ax
    /* the same physical words directly: segment page << 12 */
    movzx   ax, byte ptr [cur]
    shl     ax, 12
    mov     es, ax
    mov     ax, es:[0]
    mov     [dw_+0], ax
    mov     ax, es:[0x400]
    mov     [dw_+2], ax
    mov     ax, es
    add     ax, 0x1000
    mov     es, ax
    mov     ax, es:[0]
    mov     [dw_+4], ax
    mov     ax, es:[0xFFFE]
    mov     [dw_+6], ax
    pop     ds
    pop     es
    /* the marker: write ~marker through the window, read the cell directly */
    mov     word ptr [mk_r], 0
    cmp     byte ptr [mk_in], 0
    je      43f
    mov     word ptr [mark461], 0x3C5A
    mov     edx, [mk_off]               /* window address 0x80000 + off -> seg:ofs */
    add     edx, 0x80000
    mov     eax, edx
    shr     eax, 4
    and     dx, 0x000F
    push    es
    mov     es, ax
    mov     di, dx
    mov     ax, es:[di]
    mov     [mk_w0], ax                 /* what the window shows there */
    mov     word ptr es:[di], 0xC3A5
    wbinvd
    mov     ax, es:[di]
    mov     [mk_w1], ax                 /* the window after the write */
    pop     es
    mov     ax, [mark461]
    mov     [mk_r], ax                  /* the cell, read directly */
    mov     word ptr [mark461], 0x3C5A
43: mov     dx, 0x0461                  /* put back */
    mov     al, [r0]
    out     dx, al
    wbinvd
    in      al, dx
    mov     [r3], al
    push    es
    mov     ax, 0x8000
    mov     es, ax
    mov     ax, es:[0]
    mov     [w80b], ax
    pop     es
    sti
    /* R461 pp rb=xx win=w w w w dir=w w w w mark=in:w0 w1 cell | rs=xx 80000=w ok|BAD */
    mov     si, offset s_r461
    call    out_s
    mov     al, [cur]
    call    hex8
    mov     si, offset s_rb
    call    out_s
    mov     al, [r2]
    call    hex8
    mov     si, offset s_win
    call    out_s
    mov     si, offset ww
    call    hex4w
    mov     si, offset s_dir
    call    out_s
    mov     si, offset dw_
    call    hex4w
    mov     si, offset s_mark
    call    out_s
    cmp     byte ptr [mk_in], 0
    jne     44f
    mov     si, offset s_none
    call    out_s
    jmp     45f
44: mov     ax, [mk_w0]
    call    hex16
    call    putsp
    mov     ax, [mk_w1]
    call    hex16
    call    putsp
    mov     ax, [mk_r]
    call    hex16
45: mov     si, offset s_rs
    call    out_s
    mov     al, [r3]
    call    hex8
    mov     si, offset s_w80
    call    out_s
    mov     ax, [w80b]
    call    hex16
    cmp     ax, [a_w80]
    jne     46f
    mov     si, offset s_ok
    jmp     47f
46: mov     si, offset s_bad
47: call    out_s
    call    out_nl
    pop     bx
    inc     bx
    jmp     41b
49: mov     si, offset s_rs461
    call    out_s
    mov     al, [r0]
    call    hex8
    mov     si, offset s_now
    call    out_s
    mov     dx, 0x0461
    in      al, dx
    call    hex8
    call    out_nl
    mov     si, offset s_e461
    call    out_s
    call    out_nl
    ret
hex4w:                                  /* four words at SI */
    push    cx
    mov     cx, 4
1:  lodsw
    call    hex16
    call    putsp
    loop    1b
    pop     cx
    ret

/* ======================================================================
 * item 98: 0x043B
 * ====================================================================== */
item_43b:
    mov     si, offset s_b43b
    call    out_s
    call    out_nl
    smsw    ax
    test    al, 1
    jz      51f
    mov     si, offset s_v86
    call    out_s
    call    out_nl
    jmp     59f
51: mov     dx, 0x043B
    in      al, dx
    mov     [r0], al
    in      al, dx
    mov     [r1], al
    in      al, 0xF6
    mov     [f6], al
    mov     si, offset s_asf43b
    call    out_s
    mov     al, [r0]
    call    hex8
    call    putsp
    mov     al, [r1]
    call    hex8
    mov     si, offset s_f6
    call    out_s
    mov     al, [f6]
    call    hex8
    call    out_nl
    call    unreal_fs
    /* the six write values: none (as found), r&~4, r|4, (r&~4)^8, (r|4)^8, r */
    mov     al, [r0]
    mov     ah, al
    and     ah, 0xFB
    mov     [v43b+1], ah
    mov     ah, al
    or      ah, 0x04
    mov     [v43b+2], ah
    mov     ah, al
    and     ah, 0xFB
    xor     ah, 0x08
    mov     [v43b+3], ah
    mov     ah, al
    or      ah, 0x04
    xor     ah, 0x08
    mov     [v43b+4], ah
    mov     [v43b+5], al
    xor     bx, bx
52: cmp     bx, 6
    jae     58f
    mov     al, [v43b+bx]
    mov     [cur], al
    push    bx
    mov     si, offset s_row43b
    call    out_s
    test    bx, bx
    jnz     53f
    mov     si, offset s_asis
    call    out_s
    jmp     54f
53: mov     al, [cur]
    call    hex8
54: call    out_nl
    pop     bx
    push    bx
    cli
    call    a20_open
    test    bx, bx
    jz      55f
    mov     dx, 0x043B
    mov     al, [cur]
    out     dx, al
55: wbinvd
    mov     dx, 0x043B
    in      al, dx
    mov     [r2], al
    in      al, dx
    mov     [r3], al
    xor     di, di                      /* the reads */
56: mov     esi, [adr43b+di]
    mov     eax, fs:[esi]
    mov     [val43b+di], eax
    add     di, 4
    cmp     di, 32
    jb      56b
    mov     esi, 0x00F80000             /* write / read / put back */
    mov     eax, fs:[esi]
    mov     [wt0], eax
    not     eax
    mov     fs:[esi], eax
    wbinvd
    mov     eax, fs:[esi]
    mov     [wt1], eax
    mov     eax, [wt0]
    mov     fs:[esi], eax
    wbinvd
    mov     eax, fs:[esi]
    mov     [wt2], eax
    test    byte ptr [f6], 1            /* A20 as found (bit 0 = 1: masked) */
    jz      57f
    call    a20_mask
57: sti
    /* R43B vv rb=xx xx  F00000=.. F80000=.. FA0000=.. 0A0000=.. FE8000=.. 0E8000=.. FFFFF0=.. 0FFFF0=.. W=a b c */
    mov     si, offset s_r43b
    call    out_s
    pop     bx
    push    bx
    test    bx, bx
    jnz     571f
    mov     si, offset s_asis
    call    out_s
    jmp     572f
571:mov     al, [cur]
    call    hex8
572:mov     si, offset s_rb
    call    out_s
    mov     al, [r2]
    call    hex8
    call    putsp
    mov     al, [r3]
    call    hex8
    xor     di, di
573:call    putsp
    mov     eax, [adr43b+di]
    call    hex24
    mov     al, '='
    call    out_c
    mov     eax, [val43b+di]
    call    hex32
    add     di, 4
    cmp     di, 32
    jb      573b
    mov     si, offset s_wt
    call    out_s
    mov     eax, [wt0]
    call    hex32
    call    putsp
    mov     eax, [wt1]
    call    hex32
    call    putsp
    mov     eax, [wt2]
    call    hex32
    call    out_nl
    pop     bx
    inc     bx
    jmp     52b
58: mov     si, offset s_rs43b
    call    out_s
    mov     al, [r0]
    call    hex8
    mov     si, offset s_now
    call    out_s
    mov     dx, 0x043B
    in      al, dx
    call    hex8
    mov     si, offset s_f6
    call    out_s
    in      al, 0xF6
    call    hex8
    call    out_nl
59: mov     si, offset s_e43b
    call    out_s
    call    out_nl
    ret
a20_open:                               /* the ITF's own enable (a20map.s) */
    push    ax
    xor     al, al
    out     0xF2, al
    mov     al, 0x02
    out     0xF6, al
    pop     ax
    ret
a20_mask:
    push    ax
    mov     al, 0x03
    out     0xF6, al
    pop     ax
    ret
/* FS with a 4 GiB limit, back in real mode (memmap.s unreal_fs; 0x66 LGDT, a20map.s) */
unreal_fs:
    xor     eax, eax
    mov     ax, cs
    shl     eax, 4
    add     eax, offset gdt
    mov     [gdtr+2], eax
    cli
    .byte 0x66
    lgdt    [gdtr]
    mov     eax, cr0
    or      al, 1
    mov     cr0, eax
    jmp     1f
1:  mov     bx, 8
    mov     fs, bx
    and     al, 0xFE
    mov     cr0, eax
    jmp     2f
2:  xor     ax, ax
    mov     fs, ax
    sti
    ret

/* ======================================================================
 * output: every line written and committed at once
 * ====================================================================== */
out_c:
    push    bx
    mov     bx, [olen]
    mov     [obuf+bx], al
    inc     bx
    cmp     bx, 250
    jb      1f
    dec     bx
1:  mov     [olen], bx
    pop     bx
    ret
out_s:
    push    ax
1:  lodsb
    test    al, al
    jz      2f
    call    out_c
    jmp     1b
2:  pop     ax
    ret
out_nl:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     al, 13
    call    out_c
    mov     al, 10
    call    out_c
    mov     bx, [handle]
    mov     cx, [olen]
    mov     dx, offset obuf
    mov     ah, 0x40
    int     0x21
    mov     word ptr [olen], 0
    mov     bx, [handle]
    cmp     bx, 2
    jbe     1f
    mov     ah, 0x68
    int     0x21
1:  pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret
putsp:
    push    ax
    mov     al, ' '
    call    out_c
    pop     ax
    ret
hexd:
    push    ax
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     1f
    add     al, 7
1:  call    out_c
    pop     ax
    ret
hex8:
    push    ax
    push    ax
    shr     al, 4
    call    hexd
    pop     ax
    call    hexd
    pop     ax
    ret
hex16:
    push    ax
    xchg    al, ah
    call    hex8
    xchg    al, ah
    call    hex8
    pop     ax
    ret
hex24:
    push    eax
    ror     eax, 16
    call    hex8
    rol     eax, 16
    call    hex16
    pop     eax
    ret
hex32:
    push    eax
    ror     eax, 16
    call    hex16
    rol     eax, 16
    call    hex16
    pop     eax
    ret

s_banner:  .asciz "RISKY v1 write-then-read rows (tools/hwprobe/risky): items 28 /43F, 35 /989, 97 /461, 98 /43B"
s_usage:   .asciz "usage: RISKY /43F|/989|/461|/43B [/O FILE]"
s_b43f:    .asciz "BEGIN:RISKY 43F"
s_asf43f:  .asciz "ASFOUND 43F="
s_f8w:     .asciz " f8w="
s_f8s:     .asciz " f8sum="
s_b0w:     .asciz " b0w="
s_resume:  .asciz "RESUME after "
s_resume2: .asciz " (its ROW has no R43F line: the write hung)"
s_row43f:  .asciz "ROW 43F "
s_r43f:    .asciz "R43F "
s_rst:     .asciz " | 20/02 -> "
s_ok:      .asciz " ok"
s_bad:     .asciz " BAD"
s_rs43f:   .asciz "RESTORE 043F<-20 043D<-02 (the BIOS's state), 043F reads "
s_e43f:    .asciz "END:RISKY 43F"
s_b989:    .asciz "BEGIN:RISKY 989"
s_asf989:  .asciz "ASFOUND "
s_loop:    .asciz "LOOP ticks (65535 x dec/jnz, ARTIC) "
s_loopx:   .asciz "loop="
s_row989:  .asciz "ROW 989 "
s_rd989:   .asciz "ROW 989 RD "
s_rdv:     .asciz "RD989 "
s_w989:    .asciz "W989 "
s_arrow:   .asciz " -> "
s_restore: .asciz "RESTORE "
s_rs989:   .asciz "RESTORE 9890/9892/9894/9896 put back above; 98E0 left (write-only, reads FF)"
s_e989:    .asciz "END:RISKY 989"
s_b461:    .asciz "BEGIN:RISKY 461"
s_asf461:  .asciz "ASFOUND 0461="
s_463:     .asciz " 0463="
s_mphys:   .asciz " marker@"
s_w80:     .asciz " 80000="
s_row461:  .asciz "ROW 461 "
s_r461:    .asciz "R461 "
s_rb:      .asciz " rb="
s_win:     .asciz " win(80000 80400 90000 9FFFE)="
s_dir:     .asciz "dir="
s_mark:    .asciz "mark(win before/after, cell)="
s_none:    .asciz "-"
s_rs:      .asciz " | rs="
s_rs461:   .asciz "RESTORE 0461<-"
s_now:     .asciz " now "
s_e461:    .asciz "END:RISKY 461"
s_b43b:    .asciz "BEGIN:RISKY 43B"
s_v86:     .asciz "SKIP: PE set (a V86 monitor is loaded); run from plain DOS"
s_asf43b:  .asciz "ASFOUND 043B="
s_f6:      .asciz " F6="
s_row43b:  .asciz "ROW 43B "
s_r43b:    .asciz "R43B "
s_asis:    .asciz "AS"
s_wt:      .asciz " W(F80000 before/~written/put back)="
s_rs43b:   .asciz "RESTORE 043B<-"
s_e43b:    .asciz "END:RISKY 43B"

/* 0x043F order: nibbles 2, 8, E, A, C, 0, 1, 3, 4, 5, 6, 7, 9, B, D, F; low nibble 0-F */
ord43f:
    .irp hi, 0x20, 0x80, 0xE0, 0xA0, 0xC0, 0x00, 0x10, 0x30, 0x40, 0x50, 0x60, 0x70, 0x90, 0xB0, 0xD0, 0xF0
    .irp lo, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .byte \hi + \lo
    .endr
    .endr
p989:      .word 0x9890, 0x9896, 0x9892, 0x9894
p989r:     .word 0x9890, 0x9892, 0x9894, 0x9896, 0x98E0
pat989:    .byte 0x00, 0x55, 0xAA, 0x08
pg461:     .byte 0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08
    .balign 4
adr43b:    .long 0x00F00000, 0x00F80000, 0x00FA0000, 0x000A0000, 0x00FE8000, 0x000E8000, 0x00FFFFF0, 0x000FFFF0
val43b:    .long 0, 0, 0, 0, 0, 0, 0, 0
wt0:       .long 0
wt1:       .long 0
wt2:       .long 0
v_f8s:     .long 0
a_f8s:     .long 0
w_f8s:     .long 0
mphys:     .long 0
mk_off:    .long 0
    .balign 8
gdt:       .quad 0
           .quad 0x00CF92000000FFFF
gdtr:      .word 15
           .long 0
v_f8w:     .word 0
v_b0w:     .word 0
a_f8w:     .word 0
a_b0w:     .word 0
w_f8w:     .word 0
w_b0w:     .word 0
a_w80:     .word 0
w80b:      .word 0
ww:        .word 0, 0, 0, 0
dw_:       .word 0, 0, 0, 0
mk_w0:     .word 0
mk_w1:     .word 0
mk_r:      .word 0
mark461:   .word 0x3C5A
curp:      .word 0
handle:    .word 1
olen:      .word 0
bufseg:    .word 0
items:     .byte 0
existed:   .byte 0
res_have:  .byte 0
res_val:   .byte 0
cur:       .byte 0
r0:        .byte 0
r1:        .byte 0
r2:        .byte 0
r3:        .byte 0
f6:        .byte 0
f_first:   .byte 0
mk_in:     .byte 0
v43b:      .byte 0, 0, 0, 0, 0, 0
fname:     .space 64
obuf:      .space 256
