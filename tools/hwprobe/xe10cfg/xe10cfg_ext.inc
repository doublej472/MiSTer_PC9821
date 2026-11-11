/* xe10cfg_ext.inc - the 2026-11 kit additions to XE10CFG (included at the end of xe10cfg.s).
 *
 *   CPU line (default dump, item 53): MSW, CR0 (skipped under V86), SIDT/SGDT with the 32-bit
 *     operand (limit + 32-bit base) and the FPU answer to FNINIT/FNSTSW/FNSTCW (status 0000 and
 *     control 037F = an FPU answered; the sentinels 5A5A stay when none did).
 *   MODE68OFF (/WR, answered in docs/probes/KIT1-XE10-CFGWR.TXT): 0x68 read, `out 0x68,0x0E` (DISP off), read at once and after
 *     ~20 ms (a frame), `out 0x68,0x0F` (DISP on, the ITF's value), read.
 *   /CG (items 94b, 172, 181, the CG read half, the two-byte ten < 0x20 question): read-only; only
 *     0xA1/0xA3/0xA5 are written (saved first, put back before sti). See cg_mode.
 *   /CGWR (the CG window write half): writes code 0x7E57 (JIS 0x777E, both halves) through the window
 *     at every offset 0..0x1F, reads every offset and both halves through 0xA9, puts the saved
 *     bytes back, and proves the whole user-CG store is unchanged against a snapshot.
 *   /IDE (items 21, 27): 0x0432 sweep, 0x074E with the slave selected, 0x0433 with an IDE
 *     interrupt pending (CHECK POWER MODE). Each row's ROW line is committed first.
 *   /W4A0 (item 157): the EGC word read `in ax,0x4A0`, the read that is suspected of freezing
 *     the machine once. FLAGGED: run it last, in its own batch, and power-cycle after it.
 *
 * Buffers live above the image in the program's own 64 KiB segment (a .COM owns it).
 */
    .equ CGBUF,   0x8000        /* 2 x 127 x 2 x 16 = 8128: the user-CG store, A5 00/20 */
    .equ CGSNAP,  0xC000        /* /CGWR: the after-snapshot of the store (8128) */
    .equ WINBUF,  0xA000        /* 10 x 32: whole 32-byte window reads */
    .equ PBUF,    0xA200        /* 10 x 16: the same codes through 0xA9 */
    .equ XBUF,    0x4000        /* 336 x 12 = 4032: the wrap table CRCs (7 ku x 48 ten; above the image) */
    .equ XRAW,    0xAD00        /* 5 x 96: raw rows of five codes */
    .equ XSCR,    0xAF00        /* 96: one code's scratch (P20 16, P00 16, W20 32, W00 32) */
    .equ XTMP,    0xAF80        /* 16: even/odd extraction */
    .equ WINSEG,  0xA400
    /* every .equ is defined before its first use: GAS reads a not-yet-defined symbol in an
     * Intel-syntax immediate as a memory operand (tools/hwprobe/Makefile, XE10T's guard) */
    .equ REP_SZ,  52            /* one CGREP record: diff, first, 4 words, 2 dwords, 32 raw */
    .equ XRAW_KU_A3, 0x10       /* the CGXRAW codes' ku - 0x20 (ku 0x30) */

/* ---------------------------------------------------------------------------------------- */
/* CPU line                                                                                  */
/* ---------------------------------------------------------------------------------------- */
cpu_line:
    smsw    ax
    mov     [cpu_msw], ax
    mov     dword ptr [cpu_cr0], 0xFFFFFFFF
    test    al, 1
    jnz     1f                  /* V86 (a memory manager): mov from CR0 would fault */
    mov     eax, cr0
    mov     [cpu_cr0], eax
1:  .byte   0x66
    sidt    [cpu_idt]
    .byte   0x66
    sgdt    [cpu_gdt]
    mov     word ptr [fpu_sw], 0x5A5A
    mov     word ptr [fpu_cw], 0x5A5A
    fninit
    fnstsw  word ptr [fpu_sw]
    fnstcw  word ptr [fpu_cw]
    mov     dx, offset s_cpu
    call    puts
    mov     ax, [cpu_msw]
    call    puthex16
    mov     dx, offset s_cr0
    call    puts
    mov     eax, [cpu_cr0]
    call    puthex32
    mov     dx, offset s_idt
    call    puts
    mov     ax, [cpu_idt]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     eax, [cpu_idt + 2]
    call    puthex32
    mov     dx, offset s_gdt
    call    puts
    mov     ax, [cpu_gdt]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     eax, [cpu_gdt + 2]
    call    puthex32
    mov     dx, offset s_fsw
    call    puts
    mov     ax, [fpu_sw]
    call    puthex16
    mov     dx, offset s_fcw
    call    puts
    mov     ax, [fpu_cw]
    call    puthex16
    call    putnl
    ret

puthex32:                       /* EAX */
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
    call    puthex16
    ret

/* ---------------------------------------------------------------------------------------- */
/* /WR: 0x68 with the display off (docs/probes/KIT1-XE10-CFGWR.TXT)                          */
/* ---------------------------------------------------------------------------------------- */
mode68off_test:
    mov     dx, 0x0068
    in      al, dx
    mov     [m68o + 0], al
    pushf
    cli
    mov     al, 0x0E            /* FF1 index 7 (DISP) = 0 */
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [m68o + 1], al
    mov     ecx, 6144           /* 20 ms of the 307200 Hz ARTIC: more than one frame */
    call    artic_wait
    mov     dx, 0x0068
    in      al, dx
    mov     [m68o + 2], al
    mov     al, 0x0F            /* DISP on again: the ITF's own value */
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [m68o + 3], al
    popf
    mov     dx, offset s_m68o
    call    puts
    mov     si, offset m68o
    mov     cx, 4
    call    print_bytes
    call    putnl
    ret

/* print_bytes: CX bytes at DS:SI, each as ` xx`... without the first blank: "aa bb cc" */
print_bytes:
    jcxz    3f
    jmp     2f
1:  call    putsp
2:  mov     al, [si]
    call    puthex8
    inc     si
    loop    1b
3:  ret

/* print_hexrun: CX bytes at DS:SI as one run of hex digits (no blanks) */
print_hexrun:
    jcxz    2f
1:  mov     al, [si]
    call    puthex8
    inc     si
    loop    1b
2:  ret

/* artic_read: EAX = the 24-bit ARTIC count (0x5C word, 0x5F high byte), as ym29/crt24k */
artic_read:
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005F
    in      al, dx
    movzx   ebx, al
    mov     dx, 0x005C
    in      ax, dx
    movzx   ecx, ax
    mov     dx, 0x005F
    in      al, dx
    movzx   eax, al
    cmp     eax, ebx
    je      1f
    cmp     ecx, 0x8000
    jb      1f
    mov     eax, ebx
1:  shl     eax, 16
    or      eax, ecx
    pop     ecx
    pop     ebx
    pop     dx
    ret

/* artic_wait: spin ECX ARTIC ticks (safe under cli) */
artic_wait:
    push    eax
    push    ebx
    call    artic_read
    mov     ebx, eax
1:  call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, ecx
    jb      1b
    pop     ebx
    pop     eax
    ret

/* crc16: CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection) over CX bytes at DS:SI
 * taken every BX bytes. Returns AX. xe10cfg_decode.py's crc16() is the same function. */
crc16:
    push    cx
    push    si
    push    dx
    mov     ax, 0xFFFF
1:  mov     dl, [si]
    xor     ah, dl
    push    cx
    mov     cx, 8
2:  shl     ax, 1
    jnc     3f
    xor     ax, 0x1021
3:  loop    2b
    pop     cx
    add     si, bx
    loop    1b
    pop     dx
    pop     si
    pop     cx
    ret

/* ---------------------------------------------------------------------------------------- */
/* CG register helpers                                                                       */
/* ---------------------------------------------------------------------------------------- */
cg_save_regs:
    mov     dx, 0x00A1
    in      al, dx
    mov     [cg_a1], al
    mov     dx, 0x00A3
    in      al, dx
    mov     [cg_a3], al
    mov     dx, 0x00A5
    in      al, dx
    mov     [cg_a5], al
    ret
cg_put_regs:
    mov     dx, 0x00A1
    mov     al, [cg_a1]
    out     dx, al
    mov     dx, 0x00A3
    mov     al, [cg_a3]
    out     dx, al
    mov     dx, 0x00A5
    mov     al, [cg_a5]
    out     dx, al
    ret
/* cg_sel: AL = A1, AH = A3, BL = A5 (the ITF's order: A1, A3, A5) */
cg_sel:
    push    dx
    mov     dx, 0x00A1
    out     dx, al
    mov     dx, 0x00A3
    xchg    al, ah
    out     dx, al
    xchg    al, ah
    mov     dx, 0x00A5
    xchg    al, bl
    out     dx, al
    xchg    al, bl
    pop     dx
    ret
/* cg_port16: the 16 lines of the selected code through 0xA9 (A5 = BL | line) -> DS:DI.. */
cg_port16:
    push    cx
    push    dx
    xor     cx, cx
1:  mov     al, bl
    or      al, cl
    mov     dx, 0x00A5
    out     dx, al
    call    io_delay
    mov     dx, 0x00A9
    in      al, dx
    mov     [di], al
    inc     di
    inc     cx
    cmp     cx, 16
    jb      1b
    pop     dx
    pop     cx
    ret
/* cg_win32: window offsets 0..0x1F (ES = 0xA400) -> DS:DI.. */
cg_win32:
    push    si
    push    cx
    xor     si, si
    mov     cx, 32
1:  mov     al, es:[si]
    mov     [di], al
    inc     di
    inc     si
    loop    1b
    pop     cx
    pop     si
    ret
/* cg_store_dump: the whole writable user-CG store through the window's odd offsets into DS:DI
 * (A3 0x56 then 0x57; A1 0x01..0x7F; A5 0x00 then 0x20; 16 bytes each). ES = 0xA400, IF = 0. */
cg_store_dump:
    mov     byte ptr [c_a3], 0x56
1:  mov     byte ptr [c_a1], 0x01
2:  mov     byte ptr [c_h], 0x00
3:  mov     al, [c_a1]
    mov     ah, [c_a3]
    mov     bl, [c_h]
    call    cg_sel
    mov     si, 1
    mov     cx, 16
4:  mov     al, es:[si]
    mov     [di], al
    inc     di
    add     si, 2
    loop    4b
    add     byte ptr [c_h], 0x20
    cmp     byte ptr [c_h], 0x40
    jb      3b
    inc     byte ptr [c_a1]
    cmp     byte ptr [c_a1], 0x80
    jb      2b
    inc     byte ptr [c_a3]
    cmp     byte ptr [c_a3], 0x58
    jb      1b
    ret

/* ---------------------------------------------------------------------------------------- */
/* /CG                                                                                       */
/* ---------------------------------------------------------------------------------------- */
/* Sections, all collected under cli and printed afterwards:
 *   CGS aaaa hh <32 hex>   the user-CG store: code A1=aa A3=0x56/0x57, A5=hh (00 or 20), the 16
 *                          odd window offsets 1,3,..,0x1F (lines 0..15): the ITF's record read
 *                          (BANK4@0x4677: A5 bit 5 clear, [es:2*row+1]). Code 0x2056 A5=00 is
 *                          the record (rows 0..0xD), 0x2156 A5=00 rows 3/4 the record's 0x13/0x14,
 *                          0x1056 A5=20 rows 0/1 the ITF's saved-table length, 0x1256 A5=00 row 7
 *                          the mode byte, 0x1056.. A5=20 up the saved port table (item 181)
 *   CGW aaaa hh <64 hex>   window offsets 0..0x1F, even and odd (the CG window read half)
 *   CGP aaaa hh <32 hex>   the same code through 0xA9 (A5 = hh | line, lines 0..15)
 *   CGREP aaaa hh diff=n first=xxxx   the 4 KiB window against its first 32 bytes
 *   CGWORD aaaa hh w0= w1= w1E= w1F= d0= d1=   16/32-bit window reads
 *   CGX aaaa P20= P00= W20E= W20O= W00E= W00O=   the two-byte wrap table: ku 0x21/0x30/0x42/0x7C
 *                          (A3 = 01/10/22/5C, kit 2 adds 09/0C/58) x ten (A1) 0x00..0x2F, CRC-16 of the 16 port bytes
 *                          with A5 = 0x20|line and = line, and of the even and the odd window
 *                          bytes with A5 = 0x20 and 0x00
 *   CGXRAW aaaa <192 hex>  P20, P00, W20 (32), W00 (32) of five codes in ku 0x30 */
cg_mode:
    call    cg_save_regs
    push    es
    mov     ax, WINSEG
    mov     es, ax
    cli
    mov     di, CGBUF
    call    cg_store_dump
    /* whole-window reads and port reads of the five record codes */
    mov     si, offset cgfull
    mov     di, WINBUF
    mov     bp, PBUF
1:  mov     ax, [si]
    cmp     ax, 0xFFFF
    je      2f
    mov     bl, [si + 2]
    call    cg_sel
    call    cg_win32
    push    di
    mov     di, bp
    call    cg_port16
    mov     bp, di
    pop     di
    add     si, 3
    jmp     1b
2:  /* repeat over the 4 KiB window */
    mov     si, offset cgrep
    mov     di, offset rep_res
3:  mov     ax, [si]
    cmp     ax, 0xFFFF
    je      6f
    mov     bl, [si + 2]
    call    cg_sel
    push    di
    mov     di, offset rep_blk
    call    cg_win32
    pop     di
    xor     cx, cx              /* mismatches */
    mov     word ptr [di + 2], 0xFFFF
    mov     bx, 32
4:  mov     al, es:[bx]
    push    bx
    and     bx, 31
    cmp     al, [rep_blk + bx]
    pop     bx
    je      5f
    inc     cx
    cmp     word ptr [di + 2], 0xFFFF
    jne     5f
    mov     [di + 2], bx
5:  inc     bx
    cmp     bx, 0x1000
    jb      4b
    mov     [di], cx
    /* word and dword reads */
    mov     ax, es:[0]
    mov     [di + 4], ax
    mov     ax, es:[1]
    mov     [di + 6], ax
    mov     ax, es:[0x1E]
    mov     [di + 8], ax
    mov     ax, es:[0x1F]
    mov     [di + 10], ax
    mov     eax, es:[0]
    mov     [di + 12], eax
    mov     eax, es:[1]
    mov     [di + 16], eax
    push    si
    mov     si, offset rep_blk  /* keep block 0 raw */
    lea     bx, [di + 20]
    mov     cx, 32
7:  mov     al, [si]
    mov     [bx], al
    inc     si
    inc     bx
    loop    7b
    pop     si
    add     di, REP_SZ
    add     si, 3
    jmp     3b
6:  /* the two-byte wrap table */
    mov     di, XBUF
    mov     word ptr [xraw_p], XRAW
    mov     si, offset xku
8:  mov     ah, [si]
    cmp     ah, 0xFF
    je      9f
    mov     byte ptr [c_a1], 0
10: mov     al, [c_a1]
    mov     ah, [si]
    call    x_one
    inc     byte ptr [c_a1]
    cmp     byte ptr [c_a1], 0x30
    jb      10b
    inc     si
    jmp     8b
9:  call    cg_put_regs
    sti
    pop     es
    /* ---- print ---- */
    mov     si, CGBUF
    mov     byte ptr [c_a3], 0x56
11: mov     byte ptr [c_a1], 0x01
12: mov     byte ptr [c_h], 0x00
13: mov     dx, offset s_cgs
    call    puts
    call    put_code_h
    mov     cx, 16
    call    print_hexrun
    call    putnl
    add     byte ptr [c_h], 0x20
    cmp     byte ptr [c_h], 0x40
    jb      13b
    inc     byte ptr [c_a1]
    cmp     byte ptr [c_a1], 0x80
    jb      12b
    inc     byte ptr [c_a3]
    cmp     byte ptr [c_a3], 0x58
    jb      11b
    /* CGW / CGP */
    mov     bx, offset cgfull
    mov     si, WINBUF
    mov     bp, PBUF
14: cmp     word ptr [bx], 0xFFFF
    je      15f
    call    load_code_h
    mov     dx, offset s_cgw
    call    puts
    call    put_code_h
    mov     cx, 32
    call    print_hexrun
    call    putnl
    push    si
    mov     si, bp
    mov     dx, offset s_cgp
    call    puts
    call    put_code_h
    mov     cx, 16
    call    print_hexrun
    call    putnl
    mov     bp, si
    pop     si
    add     bx, 3
    jmp     14b
15: /* CGREP / CGWORD / CGW of the repeat codes */
    mov     bx, offset cgrep
    mov     di, offset rep_res
16: cmp     word ptr [bx], 0xFFFF
    je      17f
    call    load_code_h
    mov     dx, offset s_cgrep
    call    puts
    call    put_code_h
    mov     dx, offset s_diff
    call    puts
    mov     ax, [di]
    call    puthex16
    mov     dx, offset s_first
    call    puts
    mov     ax, [di + 2]
    call    puthex16
    call    putnl
    mov     dx, offset s_cgword
    call    puts
    call    put_code_h
    mov     dx, offset s_w0
    call    puts
    mov     ax, [di + 4]
    call    puthex16
    mov     dx, offset s_w1
    call    puts
    mov     ax, [di + 6]
    call    puthex16
    mov     dx, offset s_w1e
    call    puts
    mov     ax, [di + 8]
    call    puthex16
    mov     dx, offset s_w1f
    call    puts
    mov     ax, [di + 10]
    call    puthex16
    mov     dx, offset s_d0
    call    puts
    mov     eax, [di + 12]
    call    puthex32
    mov     dx, offset s_d1
    call    puts
    mov     eax, [di + 16]
    call    puthex32
    call    putnl
    mov     dx, offset s_cgw
    call    puts
    call    put_code_h
    lea     si, [di + 20]
    mov     cx, 32
    call    print_hexrun
    call    putnl
    add     di, REP_SZ
    add     bx, 3
    jmp     16b
17: /* CGX */
    mov     si, XBUF
    mov     bx, offset xku
18: mov     al, [bx]
    cmp     al, 0xFF
    je      20f
    mov     [c_a3], al
    mov     byte ptr [c_a1], 0
19: mov     dx, offset s_cgx
    call    puts
    mov     al, [c_a1]
    call    puthex8
    mov     al, [c_a3]
    call    puthex8
    xor     cx, cx
21: push    cx
    mov     di, cx
    shl     di, 1
    mov     dx, [xnames + di]
    call    puts
    mov     ax, [si]
    call    puthex16
    add     si, 2
    pop     cx
    inc     cx
    cmp     cx, 6
    jb      21b
    call    putnl
    inc     byte ptr [c_a1]
    cmp     byte ptr [c_a1], 0x30
    jb      19b
    inc     bx
    jmp     18b
20: /* CGXRAW */
    mov     si, XRAW
    mov     bx, offset xrawlist
22: mov     al, [bx]
    cmp     al, 0xFF
    je      23f
    mov     dx, offset s_cgxraw
    call    puts
    call    puthex8
    mov     al, XRAW_KU_A3
    call    puthex8
    call    putsp
    mov     cx, 96
    call    print_hexrun
    call    putnl
    inc     bx
    jmp     22b
23: call    cg_regs_line
    ret

/* load_code_h: BX -> {A1, A3, A5} table entry -> c_a1/c_a3/c_h */
load_code_h:
    mov     al, [bx]
    mov     [c_a1], al
    mov     al, [bx + 1]
    mov     [c_a3], al
    mov     al, [bx + 2]
    mov     [c_h], al
    ret
/* put_code_h: "aaaa hh " from c_a1/c_a3/c_h */
put_code_h:
    mov     al, [c_a1]
    call    puthex8
    mov     al, [c_a3]
    call    puthex8
    call    putsp
    mov     al, [c_h]
    call    puthex8
    call    putsp
    ret
cg_regs_line:
    mov     dx, offset s_cgrest
    call    puts
    mov     dx, 0x00A1
    in      al, dx
    call    puthex8
    call    putsp
    mov     dx, 0x00A3
    in      al, dx
    call    puthex8
    call    putsp
    mov     dx, 0x00A5
    in      al, dx
    call    puthex8
    mov     dx, offset s_was
    call    puts
    mov     al, [cg_a1]
    call    puthex8
    call    putsp
    mov     al, [cg_a3]
    call    puthex8
    call    putsp
    mov     al, [cg_a5]
    call    puthex8
    call    putnl
    ret

/* x_one: AL = A1 (ten), AH = A3 (ku - 0x20); ES = window, IF = 0. Appends 6 CRC words at
 * DS:DI (DI advances) and, for the XRAW codes, the 96 raw bytes at [xraw_p]. */
x_one:
    push    si
    push    ax
    mov     bl, 0x20
    call    cg_sel
    push    di
    mov     di, XSCR
    call    cg_port16           /* P20: A5 = 0x20 | line */
    pop     di
    pop     ax
    push    ax
    mov     bl, 0x00
    call    cg_sel
    push    di
    mov     di, XSCR + 16
    call    cg_port16           /* P00: A5 = line */
    pop     di
    pop     ax
    push    ax
    mov     bl, 0x20
    call    cg_sel
    push    di
    mov     di, XSCR + 32
    call    cg_win32            /* W20 */
    pop     di
    pop     ax
    push    ax
    mov     bl, 0x00
    call    cg_sel
    push    di
    mov     di, XSCR + 64
    call    cg_win32            /* W00 */
    pop     di
    /* the six CRCs */
    mov     bx, 1
    mov     cx, 16
    mov     si, XSCR
    call    crc16
    mov     [di], ax
    mov     si, XSCR + 16
    call    crc16
    mov     [di + 2], ax
    mov     bx, 2
    mov     si, XSCR + 32
    call    crc16
    mov     [di + 4], ax
    mov     si, XSCR + 33
    call    crc16
    mov     [di + 6], ax
    mov     si, XSCR + 64
    call    crc16
    mov     [di + 8], ax
    mov     si, XSCR + 65
    call    crc16
    mov     [di + 10], ax
    add     di, 12
    pop     ax
    /* raw copy for the listed codes */
    cmp     ah, XRAW_KU_A3
    jne     3f
    mov     bx, offset xrawlist
1:  cmp     byte ptr [bx], 0xFF
    je      3f
    cmp     al, [bx]
    je      2f
    inc     bx
    jmp     1b
2:  push    di
    mov     di, [xraw_p]
    mov     si, XSCR
    mov     cx, 96
4:  mov     al, [si]
    mov     [di], al
    inc     si
    inc     di
    loop    4b
    mov     [xraw_p], di
    pop     di
3:  pop     si
    ret

/* ---------------------------------------------------------------------------------------- */
/* /CGWR (the CG window write half)                                                                */
/* ---------------------------------------------------------------------------------------- */
/* Code 0x7E57 (A1 = 0x7E, A3 = 0x57; JIS 0x777E): no firmware cell (the record 0x2056, the
 * mirror 0x0156, the table length 0x1056, the mode byte 0x1256, the saved table from 0x1056 up
 * and the configuration image at 0x7157/0x7257 are all elsewhere). Under cli:
 *   1. the whole store is dumped (CGBUF): the before-snapshot, and the target's saved bytes;
 *   2. per half (A5 = 00, then 20): every window offset 0..0x1F is written with base+i
 *      (base A0 for A5 = 00, 50 for A5 = 20), then all 32 offsets are read (CGWR POST) and the
 *      16 lines through 0xA9 (CGWR PORT);
 *   3. the saved 16 bytes of each half are written back through the odd offsets;
 *   4. the whole store is dumped again (CGSNAP) and compared with the before-snapshot: any cell
 *      that differs is listed (CGWR CHANGED), and the count printed (CGWR RESTORE diff=n).
 * Expected (NP2kai mem/memtram.c memtram_wr8: odd offsets write the glyph at cgwindow.high,
 * even offsets are dropped; memtram_rd8: even offsets read the low page): POST odd bytes =
 * base+i; even bytes = the low page, which the Xe10 reads as 8F for code 0x572F
 * (docs/probes/VRAM.TXT; pc9821_cg.sv CG_LOW_DUMMY) where NP2kai's array reads 00; QEMU
 * round-trips them (base+i); PORT = the odd bytes. */
cgwr_mode:
    call    cg_save_regs
    push    es
    mov     ax, WINSEG
    mov     es, ax
    cli
    mov     di, CGBUF
    call    cg_store_dump
    mov     di, offset wr_pre
    mov     ax, 0x577E
    mov     bl, 0x00
    call    cg_sel
    call    cg_win32
    mov     ax, 0x577E
    mov     bl, 0x20
    call    cg_sel
    call    cg_win32
    /* the saved halves: odd bytes */
    mov     si, offset wr_pre + 1
    mov     di, offset wr_save
    mov     cx, 32
1:  mov     al, [si]
    mov     [di], al
    add     si, 2
    inc     di
    loop    1b
    /* write tests */
    mov     byte ptr [c_h], 0x00
    mov     byte ptr [wr_base], 0xA0
    mov     di, offset wr_post
    mov     bp, offset wr_port
2:  mov     ax, 0x577E
    mov     bl, [c_h]
    call    cg_sel
    xor     si, si
    mov     al, [wr_base]
3:  mov     es:[si], al
    inc     al
    inc     si
    cmp     si, 32
    jb      3b
    call    cg_win32
    push    di
    mov     di, bp
    mov     bl, [c_h]
    call    cg_port16
    mov     bp, di
    pop     di
    add     byte ptr [c_h], 0x20
    mov     byte ptr [wr_base], 0x50
    cmp     byte ptr [c_h], 0x40
    jb      2b
    /* put the saved bytes back */
    mov     byte ptr [c_h], 0x00
    mov     si, offset wr_save
4:  mov     ax, 0x577E
    mov     bl, [c_h]
    call    cg_sel
    mov     bx, 1
5:  mov     al, [si]
    mov     es:[bx], al
    inc     si
    add     bx, 2
    cmp     bx, 33
    jb      5b
    add     byte ptr [c_h], 0x20
    cmp     byte ptr [c_h], 0x40
    jb      4b
    mov     di, CGSNAP
    call    cg_store_dump
    call    cg_put_regs
    sti
    pop     es
    /* ---- print ---- */
    mov     dx, offset s_wr_pre
    call    puts
    mov     si, offset wr_pre
    mov     cx, 64
    call    print_hexrun
    call    putnl
    mov     dx, offset s_wr_post
    call    puts
    mov     si, offset wr_post
    mov     cx, 64
    call    print_hexrun
    call    putnl
    mov     dx, offset s_wr_port
    call    puts
    mov     si, offset wr_port
    mov     cx, 32
    call    print_hexrun
    call    putnl
    /* compare the snapshots */
    xor     bp, bp              /* differing cells */
    xor     bx, bx
6:  mov     al, [CGBUF + bx]
    cmp     al, [CGSNAP + bx]
    je      7f
    inc     bp
    cmp     bp, 16
    ja      7f
    mov     dx, offset s_wr_chg
    call    puts
    mov     ax, bx
    call    puthex16
    mov     dl, ' '
    call    putc
    mov     al, [CGBUF + bx]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [CGSNAP + bx]
    call    puthex8
    call    putnl
7:  inc     bx
    cmp     bx, 8128
    jb      6b
    mov     dx, offset s_wr_rest
    call    puts
    mov     ax, bp
    call    puthex16
    or      bp, bp
    jz      8f
    mov     dx, offset s_rt_diff
    call    puts
8:  call    putnl
    call    cg_regs_line
    ret

/* ---------------------------------------------------------------------------------------- */
/* /W4A0 (item 157): FLAGGED - the EGC word read                                             */
/* ---------------------------------------------------------------------------------------- */
w4a0_mode:
    mov     dx, offset s_row_b
    call    puts
    call    commit
    pushf
    cli
    mov     dx, 0x04A0
    in      al, dx
    mov     [w4_b + 0], al
    mov     dx, 0x04A1
    in      al, dx
    mov     [w4_b + 1], al
    popf
    mov     dx, offset s_w4b
    call    puts
    mov     si, offset w4_b
    mov     cx, 2
    call    print_bytes
    call    putnl
    mov     dx, offset s_row_w
    call    puts
    call    commit
    pushf
    cli
    mov     dx, 0x04A0
    in      ax, dx
    mov     [w4_w + 0], ax
    in      ax, dx
    mov     [w4_w + 2], ax
    popf
    mov     dx, offset s_w4w
    call    puts
    mov     ax, [w4_w]
    call    puthex16
    call    putsp
    mov     ax, [w4_w + 2]
    call    puthex16
    call    putnl
    ret

/* ---------------------------------------------------------------------------------------- */
/* /IDE (items 21, 27)                                                                       */
/* ---------------------------------------------------------------------------------------- */
/* Rows (a ROW line committed before each; IF = 0 and the slave IMR's IRQ9 bit (bit 1) masked
 * inside each, the as-found 0x0432 and 0x064C put back before sti):
 *   IDEB w=vv r432= st= ast= da= 433= d640=   0x0432 <- vv for vv in 00 01 02 03 2A 80, then
 *        0x0432, 0x064E (status), 0x074C (alternate status), 0x074E (drive address), 0x0433, and
 *        a word from 0x0640 only when the status has BSY and DRQ clear and is not FF (d640=----
 *        otherwise); 0x0432 put back after each
 *   IDES dh= da= st= ast= back=   0x064C <- B0 (the slave) on the as-found bank: 0x074E, 0x064E,
 *        0x074C, then 0x064C put back and read
 *   IDEI pre= irr0= ... the as-found bank and device: CHECK POWER MODE (0xE5, no data) when
 *        the status is ready; 0x0433 and the slave IRR before the command, after BSY drops (the
 *        interrupt pending: alternate status only), 0x064E read (the acknowledge), and after it;
 *        the sector count (the power mode: FF active) and the wait in ARTIC ticks */
ide_mode:
    mov     dx, 0x0432
    in      al, dx
    mov     [ide_432], al
    mov     dx, 0x064C
    in      al, dx
    mov     [ide_64c], al
    mov     dx, 0x000A
    in      al, dx
    mov     [ide_simr], al
    mov     dx, offset s_ide_state
    call    puts
    mov     al, [ide_432]
    call    puthex8
    mov     dx, offset s_ide_64c
    call    puts
    mov     al, [ide_64c]
    call    puthex8
    mov     dx, offset s_ide_simr
    call    puts
    mov     al, [ide_simr]
    call    puthex8
    call    putnl
    /* ---- the bank sweep ---- */
    mov     si, offset ide_banks
1:  mov     al, [si]
    cmp     al, 0xFF
    je      3f
    mov     [ide_w], al
    mov     dx, offset s_row_ideb
    call    puts
    call    puthex8
    call    putnl
    call    commit
    pushf
    cli
    call    ide_mask
    mov     dx, 0x0432
    mov     al, [ide_w]
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [ib + 0], al
    mov     dx, 0x064E
    in      al, dx
    mov     [ib + 1], al
    mov     dx, 0x074C
    in      al, dx
    mov     [ib + 2], al
    mov     dx, 0x074E
    in      al, dx
    mov     [ib + 3], al
    mov     dx, 0x0433
    in      al, dx
    mov     [ib + 4], al
    mov     byte ptr [ib_dok], 0
    mov     al, [ib + 1]
    cmp     al, 0xFF
    je      2f
    test    al, 0x88
    jnz     2f
    mov     dx, 0x0640
    in      ax, dx
    mov     [ib_d], ax
    mov     byte ptr [ib_dok], 1
2:  mov     dx, 0x0432
    mov     al, [ide_432]
    out     dx, al
    call    io_delay
    call    ide_unmask
    popf
    mov     dx, offset s_ideb
    call    puts
    mov     al, [ide_w]
    call    puthex8
    mov     dx, offset s_r432
    call    puts
    mov     al, [ib + 0]
    call    puthex8
    mov     dx, offset s_st
    call    puts
    mov     al, [ib + 1]
    call    puthex8
    mov     dx, offset s_ast
    call    puts
    mov     al, [ib + 2]
    call    puthex8
    mov     dx, offset s_da
    call    puts
    mov     al, [ib + 3]
    call    puthex8
    mov     dx, offset s_433
    call    puts
    mov     al, [ib + 4]
    call    puthex8
    mov     dx, offset s_d640
    call    puts
    cmp     byte ptr [ib_dok], 0
    je      4f
    mov     ax, [ib_d]
    call    puthex16
    jmp     5f
4:  mov     dx, offset s_nodata
    call    puts
5:  call    putnl
    inc     si
    jmp     1b
3:  /* ---- the slave select ---- */
    mov     dx, offset s_row_ides
    call    puts
    call    commit
    pushf
    cli
    call    ide_mask
    mov     ecx, 30720          /* up to 100 ms for BSY to clear */
    call    ide_wait_nbsy
    mov     dx, 0x064C
    mov     al, 0xB0
    out     dx, al
    call    io_delay
    mov     dx, 0x074E
    in      al, dx
    mov     [is + 0], al
    mov     dx, 0x064E
    in      al, dx
    mov     [is + 1], al
    mov     dx, 0x074C
    in      al, dx
    mov     [is + 2], al
    mov     dx, 0x064C
    mov     al, [ide_64c]
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [is + 3], al
    call    ide_unmask
    popf
    mov     dx, offset s_ides
    call    puts
    mov     al, [ide_64c]
    call    puthex8
    mov     dx, offset s_da
    call    puts
    mov     al, [is + 0]
    call    puthex8
    mov     dx, offset s_st
    call    puts
    mov     al, [is + 1]
    call    puthex8
    mov     dx, offset s_ast
    call    puts
    mov     al, [is + 2]
    call    puthex8
    mov     dx, offset s_back
    call    puts
    mov     al, [is + 3]
    call    puthex8
    call    putnl
    /* ---- 0x0433 with an interrupt pending ---- */
    mov     dx, offset s_row_idei
    call    puts
    call    commit
    pushf
    cli
    call    ide_mask
    mov     dx, 0x0433
    in      al, dx
    mov     [ii + 0], al        /* pre 433 */
    call    s_irr
    mov     [ii + 1], al        /* pre slave IRR */
    mov     byte ptr [ii_ran], 0
    mov     ecx, 30720
    call    ide_wait_nbsy
    jc      6f                  /* busy: no command */
    mov     dx, 0x064E
    in      al, dx
    test    al, 0x40            /* DRDY */
    jz      6f
    call    artic_read
    mov     [ii_t0], eax
    mov     dx, 0x064E
    mov     al, 0xE5            /* CHECK POWER MODE: no data, INTRQ at the end */
    out     dx, al
    mov     byte ptr [ii_ran], 1
    mov     ecx, 30720
    call    ide_wait_nbsy
    call    artic_read
    sub     eax, [ii_t0]
    and     eax, 0x00FFFFFF
    mov     [ii_dt], eax
    mov     ecx, 307            /* 1 ms more for INTRQ */
    call    artic_wait
    mov     dx, 0x0433
    in      al, dx
    mov     [ii + 2], al        /* 433 pending */
    call    s_irr
    mov     [ii + 3], al        /* IRR pending */
    mov     dx, 0x0433
    in      al, dx
    mov     [ii + 4], al        /* 433 again */
    mov     dx, 0x074C
    in      al, dx
    mov     [ii + 5], al        /* alt status */
    mov     dx, 0x064E
    in      al, dx
    mov     [ii + 6], al        /* status: the acknowledge */
    call    io_delay
    mov     dx, 0x0433
    in      al, dx
    mov     [ii + 7], al        /* 433 after */
    call    s_irr
    mov     [ii + 8], al        /* IRR after */
    mov     dx, 0x0644
    in      al, dx
    mov     [ii + 9], al        /* sector count: the power mode */
    mov     dx, 0x0642
    in      al, dx
    mov     [ii + 10], al       /* error */
6:  mov     al, 0x0B            /* OCW3 back to ISR, as irqwd/ym29 leave it */
    out     0x08, al
    mov     dx, 0x064C          /* the as-found drive/head byte (a command may change it) */
    mov     al, [ide_64c]
    out     dx, al
    call    ide_unmask
    popf
    mov     dx, offset s_idei
    call    puts
    mov     al, [ii_ran]
    add     al, '0'
    mov     dl, al
    call    putc
    mov     dx, offset s_idei2
    call    puts
    mov     si, offset ii
    mov     cx, 11
    call    print_bytes
    mov     dx, offset s_dt
    call    puts
    mov     eax, [ii_dt]
    call    puthex32
    call    putnl
    /* ---- restore report ---- */
ide_restore_report:
    mov     dx, offset s_ide_rest
    call    puts
    mov     dx, 0x0432
    in      al, dx
    call    puthex8
    mov     dx, offset s_ide_64c
    call    puts
    mov     dx, 0x064C
    in      al, dx
    call    puthex8
    mov     dx, offset s_ide_simr
    call    puts
    mov     dx, 0x000A
    in      al, dx
    call    puthex8
    call    putnl
    ret


/* ---------------------------------------------------------------------------------------- */
/* /IDE2 (kit 2: items 21, 27, the ports-xe10 lane's rows)                                   */
/* ---------------------------------------------------------------------------------------- */
/* The CF the kit boots from sits behind the bank select, so: nothing but the command register
 * is written to a task file (CHECK POWER MODE 0xE5: no data, no medium access), the as-found
 * 0x0432 and 0x064C are put back inside every row (IF = 0, IRQ9 masked), and a ROW line is
 * committed before each. Run it in its own boot.
 *   IDE2B w=vv 432= err= cnt= sec= cyl= cyh= dh= st= ast= da= 433=   0x0432 <- vv for vv in 04 06
 *        07 10 20 22 23 40: the task file 0x0642-0x064E (0x0640, the data port, is not read),
 *        0x074C, 0x074E, 0x0433
 *   IDE2C w=vv n=f ran= pre433/preirr/433/433@00/irr/ast/st/433ack/irrack/count/err dt=   CHECK
 *        POWER MODE with 0x0432 = vv (02, 07: the bank-0 device in those states; 01: the bank-1
 *        device, 0x0433 read with 0x0432 = 01 and again with 00 while it pends; 00 with n=1:
 *        nIEN set in the device control 0x074C (0x0A) during the command, 0x08 written after) */
ide2_mode:
    mov     dx, 0x0432
    in      al, dx
    mov     [ide_432], al
    mov     dx, 0x064C
    in      al, dx
    mov     [ide_64c], al
    mov     dx, 0x000A
    in      al, dx
    mov     [ide_simr], al
    mov     dx, offset s_ide_state
    call    puts
    mov     al, [ide_432]
    call    puthex8
    mov     dx, offset s_ide_64c
    call    puts
    mov     al, [ide_64c]
    call    puthex8
    mov     dx, offset s_ide_simr
    call    puts
    mov     al, [ide_simr]
    call    puthex8
    call    putnl
    mov     si, offset ide2_banks
1:  mov     al, [si]
    cmp     al, 0xFF
    je      3f
    mov     [ide_w], al
    mov     dx, offset s_row_ide2b
    call    puts
    call    puthex8
    call    putnl
    call    commit
    pushf
    cli
    call    ide_mask
    mov     dx, 0x0432
    mov     al, [ide_w]
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [i2b + 0], al
    mov     di, 1
    mov     dx, 0x0642
2:  in      al, dx
    mov     [i2b + di], al
    inc     di
    add     dx, 2
    cmp     dx, 0x0650
    jb      2b
    mov     dx, 0x074C
    in      al, dx
    mov     [i2b + 8], al
    mov     dx, 0x074E
    in      al, dx
    mov     [i2b + 9], al
    mov     dx, 0x0433
    in      al, dx
    mov     [i2b + 10], al
    mov     dx, 0x0432
    mov     al, [ide_432]
    out     dx, al
    call    io_delay
    mov     dx, 0x064C
    mov     al, [ide_64c]
    out     dx, al
    call    ide_unmask
    popf
    mov     dx, offset s_ide2b
    call    puts
    mov     al, [ide_w]
    call    puthex8
    mov     dx, offset s_ide2b2
    call    puts
    push    si
    mov     si, offset i2b
    mov     cx, 11
    call    print_bytes
    pop     si
    call    putnl
    inc     si
    jmp     1b
3:  mov     si, offset ide2_cpm
4:  mov     al, [si]
    cmp     al, 0xFF
    je      5f
    mov     [ide_w], al
    mov     al, [si + 1]
    mov     [ide_n], al
    call    ide2_cpm_row
    add     si, 2
    jmp     4b
5:  jmp     ide_restore_report

ide2_cpm_row:
    push    si
    mov     dx, offset s_row_ide2c
    call    puts
    mov     al, [ide_w]
    call    puthex8
    call    putsp
    mov     al, [ide_n]
    call    puthex8
    call    putnl
    call    commit
    pushf
    cli
    call    ide_mask
    mov     di, offset ii
    mov     cx, 11
    mov     al, 0xEE
6:  mov     [di], al
    inc     di
    loop    6b
    mov     dword ptr [ii_dt], 0
    mov     byte ptr [ii_ran], 0
    mov     dx, 0x0432
    mov     al, [ide_w]
    out     dx, al
    call    io_delay
    cmp     byte ptr [ide_n], 0
    je      7f
    mov     dx, 0x074C
    mov     al, 0x0A            /* device control: nIEN */
    out     dx, al
    call    io_delay
7:  mov     dx, 0x0433
    in      al, dx
    mov     [ii + 0], al
    call    s_irr
    mov     [ii + 1], al
    mov     ecx, 30720
    call    ide_wait_nbsy
    jc      8f
    mov     dx, 0x064E
    in      al, dx
    cmp     al, 0xFF
    je      8f
    test    al, 0x40            /* DRDY */
    jz      8f
    call    artic_read
    mov     [ii_t0], eax
    mov     dx, 0x064E
    mov     al, 0xE5            /* CHECK POWER MODE */
    out     dx, al
    mov     byte ptr [ii_ran], 1
    mov     ecx, 30720
    call    ide_wait_nbsy
    call    artic_read
    sub     eax, [ii_t0]
    and     eax, 0x00FFFFFF
    mov     [ii_dt], eax
    mov     ecx, 307
    call    artic_wait
    mov     dx, 0x0433
    in      al, dx
    mov     [ii + 2], al        /* 433 with 0x0432 = w */
    mov     dx, 0x0432
    xor     al, al
    out     dx, al
    call    io_delay
    mov     dx, 0x0433
    in      al, dx
    mov     [ii + 3], al        /* 433 with 0x0432 = 00 */
    mov     dx, 0x0432
    mov     al, [ide_w]
    out     dx, al
    call    io_delay
    call    s_irr
    mov     [ii + 4], al
    mov     dx, 0x074C
    in      al, dx
    mov     [ii + 5], al
    mov     dx, 0x064E
    in      al, dx
    mov     [ii + 6], al        /* the acknowledge */
    call    io_delay
    mov     dx, 0x0433
    in      al, dx
    mov     [ii + 7], al
    call    s_irr
    mov     [ii + 8], al
    mov     dx, 0x0644
    in      al, dx
    mov     [ii + 9], al
    mov     dx, 0x0642
    in      al, dx
    mov     [ii + 10], al
8:  cmp     byte ptr [ide_n], 0
    je      9f
    mov     dx, 0x074C
    mov     al, 0x08            /* nIEN clear again */
    out     dx, al
    call    io_delay
9:  mov     al, 0x0B
    out     0x08, al
    mov     dx, 0x0432
    mov     al, [ide_432]
    out     dx, al
    call    io_delay
    mov     dx, 0x064C
    mov     al, [ide_64c]
    out     dx, al
    call    ide_unmask
    popf
    mov     dx, offset s_ide2c
    call    puts
    mov     al, [ide_w]
    call    puthex8
    mov     dx, offset s_ide2n
    call    puts
    mov     al, [ide_n]
    add     al, '0'
    mov     dl, al
    call    putc
    mov     dx, offset s_ide2r
    call    puts
    mov     al, [ii_ran]
    add     al, '0'
    mov     dl, al
    call    putc
    mov     dx, offset s_ide2c2
    call    puts
    mov     si, offset ii
    mov     cx, 11
    call    print_bytes
    mov     dx, offset s_dt
    call    puts
    mov     eax, [ii_dt]
    call    puthex32
    call    putnl
    pop     si
    ret

/* ---------------------------------------------------------------------------------------- */
/* /6C (item 36): 0x6C <- 80, F0, FF, 70, each read back and held 3 s for the camera (MAME    */
/* maps 0x6C as border_color_w: a border colour would show on the video), then 00 (the        */
/* as-found read was 00, KIT1-XE10-CFGWR.TXT) and read again.                                 */
/*   P6C w=vv r=rr   r6C asfound=rr / restored=rr                                             */
/* ---------------------------------------------------------------------------------------- */
p6c_mode:
    in      al, 0x6C
    mov     [p6c_af], al
    mov     dx, offset s_p6c_af
    call    puts
    mov     al, [p6c_af]
    call    puthex8
    call    putnl
    mov     si, offset p6c_vals
1:  mov     al, [si]
    cmp     al, 0xFF
    jne     2f
    cmp     byte ptr [si + 1], 0xFF
    je      3f
2:  mov     [ide_w], al
    mov     dx, offset s_row_p6c
    call    puts
    call    puthex8
    call    putnl
    call    commit
    mov     al, [ide_w]
    out     0x6C, al
    call    io_delay
    in      al, 0x6C
    mov     [p6c_r], al
    mov     dx, offset s_p6c
    call    puts
    mov     al, [ide_w]
    call    puthex8
    mov     dx, offset s_p6c_r
    call    puts
    mov     al, [p6c_r]
    call    puthex8
    call    putnl
    mov     ecx, 921600         /* 3 s */
    call    artic_wait
    inc     si
    jmp     1b
3:  xor     al, al
    out     0x6C, al
    call    io_delay
    mov     dx, offset s_p6c_rs
    call    puts
    in      al, 0x6C
    call    puthex8
    call    putnl
    ret


/* ---------------------------------------------------------------------------------------- */
/* /FD (kit 2, the fdc-xe10 lane's rows: items 59, 190)                                      */
/* ---------------------------------------------------------------------------------------- */
/*   FDBDA 055C=xx 0564=<32 bytes to 0x0583>          read-only, first (the boot's own state)
 *   FDVFO pre irr= isr= msr= | after-09/08 irr= msr= | 200ms irr= | after-0C first= irr= msr=
 *        0x94 <- 09, 08 (TMSK clear), 200 ms, 0x94 <- 0C: does the slave IRR bit 3 (IR11) rise,
 *        and when (ARTIC ticks from the 0C write, sampled for 400 ms, FFFFFF = never)? IR11
 *        masked in the slave IMR throughout (IF = 0); a pending result is drained with SENSE
 *        INTERRUPT STATUS (bytes printed) and the IMR put back. Reboot after it. */
fd_mode:
    mov     dx, offset s_fdbda
    call    puts
    push    es
    xor     ax, ax
    mov     es, ax
    mov     al, es:[0x055C]
    call    puthex8
    mov     dx, offset s_fdbda2
    call    puts
    mov     bx, 0x0564
1:  mov     al, es:[bx]
    call    puthex8
    inc     bx
    cmp     bx, 0x0584
    jb      1b
    pop     es
    call    putnl
    mov     dx, offset s_row_fdvfo
    call    puts
    call    commit
    in      al, 0x0A
    mov     [ide_simr], al
    pushf
    cli
    or      al, 0x08
    out     0x0A, al
    call    s_irr
    mov     [fdv + 0], al
    mov     al, 0x0B
    out     0x08, al
    out     0x5F, al
    in      al, 0x08
    mov     [fdv + 1], al
    in      al, 0x90
    mov     [fdv + 2], al
    mov     al, 0x09
    out     0x94, al
    call    io_delay
    mov     al, 0x08
    out     0x94, al
    call    io_delay
    call    s_irr
    mov     [fdv + 3], al
    in      al, 0x90
    mov     [fdv + 4], al
    mov     ecx, 61440          /* 200 ms */
    call    artic_wait
    call    s_irr
    mov     [fdv + 5], al
    mov     al, 0x0C
    out     0x94, al
    call    artic_read
    mov     ebx, eax
    mov     dword ptr [fdv_t], 0x00FFFFFF
2:  call    s_irr
    test    al, 0x08
    jz      3f
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    mov     [fdv_t], eax
    jmp     4f
3:  call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, 122880         /* 400 ms */
    jb      2b
4:  call    s_irr
    mov     [fdv + 6], al
    in      al, 0x90
    mov     [fdv + 7], al
    /* drain: SENSE INTERRUPT STATUS while the request is up (at most 4), 2 result bytes each */
    mov     word ptr [fdv_sis], 0xEEEE
    mov     cx, 4
5:  call    s_irr
    test    al, 0x08
    jz      6f
    mov     ah, 0x08
    call    fdc_put
    jc      6f
    call    fdc_get
    jc      6f
    mov     [fdv_sis], al
    call    fdc_get
    jc      6f
    mov     [fdv_sis + 1], al
    loop    5b
6:  call    s_irr
    mov     [fdv + 8], al
    mov     al, 0x0B
    out     0x08, al
    mov     al, [ide_simr]
    out     0x0A, al
    popf
    mov     dx, offset s_fdvfo
    call    puts
    mov     si, offset fdv
    mov     cx, 9
    call    print_bytes
    mov     dx, offset s_fdvt
    call    puts
    mov     eax, [fdv_t]
    call    puthex32
    mov     dx, offset s_fdvs
    call    puts
    mov     al, [fdv_sis]
    call    puthex8
    call    putsp
    mov     al, [fdv_sis + 1]
    call    puthex8
    call    putnl
    ret
/* fdc_put: AH -> the data port 0x92 when MSR (0x90) shows RQM and DIO = 0 (50 ms); CF on timeout */
fdc_put:
    push    ecx
    push    ebx
    call    artic_read
    mov     ebx, eax
1:  in      al, 0x90
    and     al, 0xC0
    cmp     al, 0x80
    je      2f
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, 15360
    jb      1b
    stc
    jmp     3f
2:  mov     al, ah
    out     0x92, al
    clc
3:  pop     ebx
    pop     ecx
    ret
/* fdc_get: AL <- 0x92 when MSR shows RQM and DIO = 1 (50 ms); CF on timeout */
fdc_get:
    push    ecx
    push    ebx
    call    artic_read
    mov     ebx, eax
1:  in      al, 0x90
    and     al, 0xC0
    cmp     al, 0xC0
    je      2f
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, 15360
    jb      1b
    stc
    jmp     3f
2:  in      al, 0x92
    clc
3:  pop     ebx
    pop     ecx
    ret

ide_mask:                       /* slave IMR |= 0x02 (IRQ9) */
    push    ax
    mov     al, [ide_simr]
    or      al, 0x02
    out     0x0A, al
    pop     ax
    ret
ide_unmask:
    push    ax
    mov     al, [ide_simr]
    out     0x0A, al
    pop     ax
    ret
s_irr:                          /* AL = the slave IRR (OCW3 0x0A) */
    mov     al, 0x0A
    out     0x08, al
    out     0x5F, al
    in      al, 0x08
    ret
/* ide_wait_nbsy: wait up to ECX ARTIC ticks for 0x074C bit 7 to clear; CF = 1 on timeout */
ide_wait_nbsy:
    push    eax
    push    ebx
    push    dx
    call    artic_read
    mov     ebx, eax
1:  mov     dx, 0x074C
    in      al, dx
    test    al, 0x80
    jz      2f
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, ecx
    jb      1b
    stc
    jmp     3f
2:  clc
3:  pop     dx
    pop     ebx
    pop     eax
    ret

/* ---------------------------------------------------------------------------------------- */
/* data                                                                                      */
/* ---------------------------------------------------------------------------------------- */
s_cpu:      .ascii "CPU msw=$"
s_cr0:      .ascii " cr0=$"
s_idt:      .ascii " idt=$"
s_gdt:      .ascii " gdt=$"
s_fsw:      .ascii " fpu_sw=$"
s_fcw:      .ascii " fpu_cw=$"
s_m68o:     .ascii "MODE68OFF before/after-0E/after-0E-20ms/after-0F $"
s_cgs:      .ascii "CGS $"
s_cgw:      .ascii "CGW $"
s_cgp:      .ascii "CGP $"
s_cgrep:    .ascii "CGREP $"
s_diff:     .ascii "diff=$"
s_first:    .ascii " first=$"
s_cgword:   .ascii "CGWORD $"
s_w0:       .ascii "w0=$"
s_w1:       .ascii " w1=$"
s_w1e:      .ascii " w1E=$"
s_w1f:      .ascii " w1F=$"
s_d0:       .ascii " d0=$"
s_d1:       .ascii " d1=$"
s_cgx:      .ascii "CGX $"
s_cgxraw:   .ascii "CGXRAW $"
s_xp20:     .ascii " P20=$"
s_xp00:     .ascii " P00=$"
s_xw20e:    .ascii " W20E=$"
s_xw20o:    .ascii " W20O=$"
s_xw00e:    .ascii " W00E=$"
s_xw00o:    .ascii " W00O=$"
s_wr_pre:   .ascii "CGWR 7E57 PRE  (A5=00 offsets 0-1F, then A5=20) $"
s_wr_post:  .ascii "CGWR 7E57 POST (wrote A0+i at A5=00, 50+i at A5=20, every offset) $"
s_wr_port:  .ascii "CGWR 7E57 PORT (0xA9 lines 0-F at A5=00, then A5=20) $"
s_wr_chg:   .ascii "CGWR CHANGED cell=$"
s_wr_rest:  .ascii "CGWR RESTORE diff=$"
s_row_b:    .ascii "ROW W4A0 BYTE in al,0x4A0 / in al,0x4A1\r\n$"
s_w4b:      .ascii "W4A0 bytes 04A0/04A1 $"
s_row_w:    .ascii "ROW W4A0 WORD in ax,0x4A0 x2 (FLAGGED: suspected of freezing the machine; power-cycle after)\r\n$"
s_w4w:      .ascii "W4A0 word $"
s_ide_state: .ascii "IDE STATE 432=$"
s_ide_rest: .ascii "IDE RESTORE 432=$"
s_ide_64c:  .ascii " 64C=$"
s_ide_simr: .ascii " simr=$"
s_row_ideb: .ascii "ROW IDE BANK w=$"
s_row_ides: .ascii "ROW IDE SLAVE\r\n$"
s_row_idei: .ascii "ROW IDE IRQ433\r\n$"
s_ideb:     .ascii "IDEB w=$"
s_r432:     .ascii " r432=$"
s_st:       .ascii " st=$"
s_ast:      .ascii " ast=$"
s_da:       .ascii " da=$"
s_433:      .ascii " 433=$"
s_d640:     .ascii " d640=$"
s_nodata:   .ascii "----$"
s_ides:     .ascii "IDES dh=$"
s_back:     .ascii " back=$"
s_idei:     .ascii "IDEI ran=$"
s_idei2:    .ascii " pre433/preirr/433/irr/433b/ast/st/433ack/irrack/count/err $"
s_dt:       .ascii " dt=$"
xnames:     .word s_xp20, s_xp00, s_xw20e, s_xw20o, s_xw00e, s_xw00o

/* {A1, A3, A5}: the record (0x2056), its rows 0x10.. (0x2156), the saved-table length and table
 * head (0x1056), the mode byte (0x1256), the software-DIP mirror (0x0156), each with A5 00 / 20 */
cgfull:
    .byte 0x20, 0x56, 0x00,  0x20, 0x56, 0x20
    .byte 0x21, 0x56, 0x00,  0x21, 0x56, 0x20
    .byte 0x10, 0x56, 0x00,  0x10, 0x56, 0x20
    .byte 0x12, 0x56, 0x00,  0x12, 0x56, 0x20
    .byte 0x01, 0x56, 0x00,  0x01, 0x56, 0x20
    .word 0xFFFF
/* the 4 KiB repeat: the record code, a JIS code (JIS 0x3021, A1 = 0x21, A3 = 0x10) and an ANK
 * code (A1 = 0, A3 = 0x41) */
cgrep:
    .byte 0x20, 0x56, 0x00
    .byte 0x21, 0x10, 0x00
    .byte 0x00, 0x41, 0x00
    .word 0xFFFF
s_fdbda:    .ascii "FDBDA 055C=$"
s_fdbda2:   .ascii " 0564..0583=$"
s_row_fdvfo: .ascii "ROW FD VFO\r\n$"
s_fdvfo:    .ascii "FDVFO preirr/preisr/premsr/irr09-08/msr09-08/irr200ms/irr0C/msr0C/irrdrain $"
s_fdvt:     .ascii " rise=$"
s_fdvs:     .ascii " sis=$"
fdv:        .space 10
    .balign 4
fdv_t:      .long 0
fdv_sis:    .word 0
s_row_ide2b: .ascii "ROW IDE2 BANK $"
s_row_ide2c: .ascii "ROW IDE2 CPM $"
s_ide2b:    .ascii "IDE2B w=$"
s_ide2b2:   .ascii " 432/err/cnt/sec/cyl/cyh/dh/st/ast/da/433 $"
s_ide2c:    .ascii "IDE2C w=$"
s_ide2n:    .ascii " n=$"
s_ide2r:    .ascii " ran=$"
s_ide2c2:   .ascii " pre433/preirr/433/433@00/irr/ast/st/433ack/irrack/count/err $"
s_row_p6c:  .ascii "ROW 6C $"
s_p6c_af:   .ascii "P6C asfound=$"
s_p6c:      .ascii "P6C w=$"
s_p6c_r:    .ascii " r=$"
s_p6c_rs:   .ascii "P6C restored-00 r=$"
ide2_banks: .byte 0x04, 0x06, 0x07, 0x10, 0x20, 0x22, 0x23, 0x40, 0xFF
ide2_cpm:   .byte 0x02, 0, 0x07, 0, 0x01, 0, 0x00, 1, 0xFF, 0xFF
p6c_vals:   .byte 0x80, 0xF0, 0xFF, 0x70, 0xFF, 0xFF   /* 0xFF then 0xFF ends the list */
ide_n:      .byte 0
p6c_af:     .byte 0
p6c_r:      .byte 0
i2b:        .space 12
ide_banks:  .byte 0x00, 0x01, 0x02, 0x03, 0x2A, 0x80, 0xFF   /* item 27's set */
xku:        .byte 0x01, 0x10, 0x22, 0x5C, 0x09, 0x0C, 0x58, 0xFF  /* ku 0x21, 0x30, 0x42, 0x7C; kit 2 adds 0x29, 0x2C, 0x78 (the video-xe10 lane's CG rows) */
xrawlist:   .byte 0x00, 0x01, 0x1F, 0x20, 0x21, 0xFF
c_a1:       .byte 0
c_a3:       .byte 0
c_h:        .byte 0
wr_base:    .byte 0
m68o:       .space 4
w4_b:       .space 2
ide_432:    .byte 0
ide_64c:    .byte 0
ide_simr:   .byte 0
ide_w:      .byte 0
ib:         .space 5
ib_dok:     .byte 0
is:         .space 4
ii:         .space 11
ii_ran:     .byte 0
    .balign 4
ii_t0:      .long 0
ii_dt:      .long 0
w4_w:       .space 4
ib_d:       .word 0
xraw_p:     .word 0
cpu_msw:    .word 0
cpu_cr0:    .long 0
cpu_idt:    .space 6
cpu_gdt:    .space 6
fpu_sw:     .word 0
fpu_cw:     .word 0
rep_blk:    .space 32
rep_res:    .space REP_SZ * 3
wr_pre:     .space 64
wr_save:    .space 32
wr_post:    .space 64
wr_port:    .space 32
