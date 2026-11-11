/* xe10cfg.s - the machine's configuration stores: the BIOS SETUP record, the software DIP
 * switches, the DIP-switch ports and the memory-switch cells (todo items 172, 99, 94;
 * the dip-audit questions P1, P2, P4, P6).
 *
 * WHY A NEW PROGRAM. probe2 holds most read-only sections but has under 400 bytes left below
 * the DOS .COM limit (tools/hwprobe/Makefile COM_MAX), so this set lives in its own small
 * probe. Everything it prints is one `KEY ...` line per value, so two captures (one per SETUP
 * change) compare line by line with `xe10cfg_decode.py --diff A B`.
 *
 *   XE10CFG > CFG.TXT          read-only dump (the default): no port or memory write except
 *                              the CG selection registers 0xA1/0xA3/0xA5 (read first, put
 *                              back) and the software-DIP control 0x8F1F (bank B select 0xC0,
 *                              then the firmware's resting 0x80, see below)
 *   XE10CFG /WR > CFGWR.TXT    the write-then-read round trips, each restored at once:
 *                              P1 (0x871E bit 5 -> port 0x31 bit 4?), P2 (does port 0x31
 *                              latch a write?), the parity-bit masks of 0x851E/0x881E/0x8B1E
 *                              (the DIP store parity bits, settled: stored), 0x9A8's width (settled: 2 bits), a 0x68 mode write
 *                              and the 0xDC000 work-RAM marker with 0x1E8E = 0x81
 *   XE10CFG /MSW5 xx           writes memory switch 5 (the cell at 0xA3FF2) = xx through the
 *                              mode flip-flop's memory-switch write enable (0x68 <- 0x0D,
 *                              store, 0x68 <- 0x0C, as the ITF's own init does at
 *                              BANK4@0x5BA0-0x5BDC) and prints was -> now. This write is
 *                              MEANT to persist (dip-audit P6: does SETUP's "memory switch:
 *                              keep" keep it across a reboot); `XE10CFG /MSW5 01` puts the
 *                              measured value back (docs/probes/MEMSW.TXT cells 48 05 0C 00 01
 *                              00 00 81), and SETUP's "initialise" rewrites every cell at the
 *                              next POST (BANK4@0x5B9A-0x5BE0).
 *
 * THE CG READS follow BANK3@0x2322, SETUP's own record helper: A1 <- 0x20 + (row >> 4),
 * A3 <- 0x56, A5 <- row & 0x0F, read 0xA9 (docs/bios-setup.md, "How SETUP stores a setting").
 * The dump reads code 0x2056 rows 0x00-0x0F and 0x20-0x2F, code 0x2156 rows 0x00-0x0F (rows 3/4
 * are the record's 0x13/0x14), code 0x0156 rows 0x00-0x0F and 0x20-0x2F (the software-DIP
 * mirror, bank A then bank B) and code 0x3056 rows 0x00-0x0F. Interrupts are off across the CG
 * walk and 0xA1/0xA3/0xA5 are put back before sti, as probe2 /MEMSW does.
 *
 * THE SOFTWARE-DIP BANKS. 0x8F1F bit 6 selects bank B and the firmware always returns it to
 * 0x80 afterwards: SETUP's bank-B accessor is `out 0x8F1F,0xC0 / in 0x841E / out 0x8F1F,0x80`
 * (BANK3@0x22E6-0x22F7) and the ITF's verifier does the same (BANK4@0x470F, @0x4728). 0x8F1F
 * reads 0xFF (docs/probes/R10.TXT `8F1F=FF FF`), so the as-found value cannot be read; that
 * 0x80 is the resting state is also what docs/probes/RDBACK.TXT shows (a 0x871E write lands at
 * the DOS prompt, so the access-enable bit 7 is set and bank A is selected). Bank A is read
 * before 0x8F1F is touched, again after 0x80, then bank B under 0xC0, then bank A after the
 * return to 0x80: the first and last bank-A lines must agree.
 *
 * Every write in /WR is made under cli and undone before sti; each prints
 * `RT port was=.. wrote=.. got=.. back=..` (and port 0x31 after the write and after the
 * restore). No DOS call is made inside a cli window. Plain DOS, no EMM386 (the 0xDC000 test
 * maps the IDE work RAM there).
 *
 * Build: make -C tools/hwprobe xe10cfg/xe10cfg.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     ax, 0x3301          /* Ctrl-Break checking off (DL = 0): a ^C must not skip a restore */
    mov     dl, 0
    int     0x21
    call    parse_args
    mov     dx, offset s_banner
    call    puts
    cmp     byte ptr [mode], 1
    je      do_wr
    cmp     byte ptr [mode], 2
    je      do_msw5
    cmp     byte ptr [mode], 3
    je      bad_args
    cmp     byte ptr [mode], 4
    je      do_cg
    cmp     byte ptr [mode], 5
    je      do_cgwr
    cmp     byte ptr [mode], 6
    je      do_w4a0
    cmp     byte ptr [mode], 7
    je      do_ide
    cmp     byte ptr [mode], 8
    je      do_ide2
    cmp     byte ptr [mode], 9
    je      do_6c
    cmp     byte ptr [mode], 10
    je      do_fd
    call    dump_all
    jmp     done
do_cg:
    call    cg_mode
    jmp     done
do_cgwr:
    call    cgwr_mode
    jmp     done
do_w4a0:
    call    w4a0_mode
    jmp     done
do_ide:
    call    ide_mode
    jmp     done
do_ide2:
    call    ide2_mode
    jmp     done
do_6c:
    call    p6c_mode
    jmp     done
do_fd:
    call    fd_mode
    jmp     done
do_wr:
    call    write_tests
    jmp     done
do_msw5:
    call    msw5_write
    jmp     done
bad_args:
    mov     dx, offset s_usage
    call    puts
done:
    mov     dx, offset s_end
    call    puts
    call    commit
    mov     ax, 0x4C00
    int     0x21

/* ---------------------------------------------------------------------------------------- */
/* argument parsing: mode 0 = dump, 1 = /WR, 2 = /MSW5 xx (value in msw5_val), 3 = bad       */
/* ---------------------------------------------------------------------------------------- */
parse_args:
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    add     cx, si              /* CX = end of the tail */
pa_skip:
    cmp     si, cx
    jae     pa_ret
    lodsb
    cmp     al, ' '
    je      pa_skip
    cmp     al, 9
    je      pa_skip
    cmp     al, '/'
    jne     pa_bad
    cmp     si, cx
    jae     pa_bad
    lodsb
    and     al, 0xDF            /* upper case */
    cmp     al, 'W'
    je      pa_wr
    cmp     al, 'M'
    je      pa_msw
    cmp     al, 'C'
    je      pa_cg
    cmp     al, 'I'
    je      pa_ide
    cmp     al, '6' & 0xDF          /* the digit, after the upper-casing above */
    je      pa_6c
    cmp     al, 'F'
    je      pa_fd
    jmp     pa_bad
pa_wr:                          /* /WR or /W4A0 */
    call    pa_next
    cmp     al, '4'
    je      pa_w4
    mov     byte ptr [mode], 1
    ret
pa_w4:
    mov     byte ptr [mode], 6
    ret
pa_ide:                         /* /IDE or /IDE2 */
    call    pa_next
    call    pa_next
    call    pa_next
    cmp     al, '2'
    je      1f
    mov     byte ptr [mode], 7
    ret
1:  mov     byte ptr [mode], 8
    ret
pa_6c:                          /* /6C */
    mov     byte ptr [mode], 9
    ret
pa_fd:                          /* /FD */
    mov     byte ptr [mode], 10
    ret
pa_cg:                          /* /CG or /CGWR */
    call    pa_next
    call    pa_next
    cmp     al, 'W'
    je      pa_cgwr
    mov     byte ptr [mode], 4
    ret
pa_cgwr:
    mov     byte ptr [mode], 5
    ret
pa_next:                        /* AL = the next tail character (a letter upper-cased), or 0 */
    xor     al, al
    cmp     si, cx
    jae     1f
    lodsb
    cmp     al, 'a'
    jb      1f
    and     al, 0xDF
1:  ret
pa_msw:
    /* skip the rest of the word "/MSW5", then blanks, then two hex digits */
1:  cmp     si, cx
    jae     pa_bad
    lodsb
    cmp     al, ' '
    jne     1b
2:  cmp     si, cx
    jae     pa_bad
    lodsb
    cmp     al, ' '
    je      2b
    call    hexval
    jc      pa_bad
    mov     bl, al
    cmp     si, cx
    jae     pa_bad
    lodsb
    call    hexval
    jc      pa_bad
    shl     bl, 4
    or      bl, al
    mov     [msw5_val], bl
    mov     byte ptr [mode], 2
    ret
pa_bad:
    mov     byte ptr [mode], 3
pa_ret:
    ret

hexval:                         /* AL = ASCII hex digit -> AL = 0..15, CF on error */
    cmp     al, '0'
    jb      hv_bad
    cmp     al, '9'
    jbe     hv_dig
    and     al, 0xDF
    cmp     al, 'A'
    jb      hv_bad
    cmp     al, 'F'
    ja      hv_bad
    sub     al, 'A' - 10
    clc
    ret
hv_dig:
    sub     al, '0'
    clc
    ret
hv_bad:
    stc
    ret

/* ---------------------------------------------------------------------------------------- */
/* the read-only dump                                                                        */
/* ---------------------------------------------------------------------------------------- */
dump_all:
    /* 1. ports, each read twice: `PORT pppp=aa bb` */
    mov     si, offset porttab
1:  mov     dx, [si]
    cmp     dx, 0xFFFF
    je      2f
    call    port_line
    add     si, 2
    jmp     1b
2:
    /* 2. the software-DIP banks */
    mov     dx, offset s_sdip_a0
    call    puts
    call    sdip_line
    cli
    mov     dx, 0x8F1F
    mov     al, 0x80
    out     dx, al
    call    sdip_read           /* -> sdip_buf */
    sti
    mov     dx, offset s_sdip_a1
    call    puts
    call    sdip_print
    cli
    mov     dx, 0x8F1F
    mov     al, 0xC0
    out     dx, al
    call    sdip_read
    mov     dx, 0x8F1F
    mov     al, 0x80
    out     dx, al
    sti
    mov     dx, offset s_sdip_b
    call    puts
    call    sdip_print
    mov     dx, offset s_sdip_a2
    call    puts
    call    sdip_line

    /* 3. the CG rows */
    call    cg_dump

    /* 4. the memory-switch cells, read-only: 0xA3FE2 + 4*i, i = 0..7 */
    mov     dx, offset s_msw
    call    puts
    push    es
    mov     ax, 0xA000
    mov     es, ax
    mov     bx, 0x3FE2
    mov     cx, 8
3:  mov     al, es:[bx]
    call    puthex8
    call    putsp
    add     bx, 4
    loop    3b
    pop     es
    call    putnl

    /* 5. the BIOS work bytes the boot and floppy set-up leave */
    mov     si, offset memtab
4:  mov     bx, [si]
    cmp     bx, 0xFFFF
    je      5f
    mov     dx, offset s_mem
    call    puts
    mov     ax, bx
    call    puthex16
    mov     dl, '='
    call    putc
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     al, [bx]
    pop     ds
    call    puthex8
    call    putnl
    add     si, 2
    jmp     4b
5:  call    cpu_line
    ret

/* PORT line for DX: two reads */
port_line:
    push    dx
    mov     dx, offset s_port
    call    puts
    pop     dx
    mov     ax, dx
    call    puthex16
    push    dx
    mov     dl, '='
    call    putc
    pop     dx
    in      al, dx
    mov     ah, al
    in      al, dx
    push    ax
    mov     al, ah
    call    puthex8
    call    putsp
    pop     ax
    call    puthex8
    call    putnl
    ret

/* sdip_read: the 12 bytes 0x841E..0x8F1E -> sdip_buf (no output, safe under cli) */
sdip_read:
    push    di
    mov     di, offset sdip_buf
    mov     dx, 0x841E
1:  in      al, dx
    mov     [di], al
    inc     di
    add     dx, 0x0100
    cmp     dx, 0x901E
    jne     1b
    pop     di
    ret
sdip_print:
    push    si
    mov     si, offset sdip_buf
    mov     cx, 12
1:  mov     al, [si]
    call    puthex8
    call    putsp
    inc     si
    loop    1b
    call    putnl
    pop     si
    ret
sdip_line:
    call    sdip_read
    call    sdip_print
    ret

/* cg_dump: for each cgtab entry (A1, A3, first A5, count): one line
 * `CG aaaa rr: b0 b1 ...` with aaaa = A1 A3 and rr the first A5 value. */
cg_dump:
    mov     dx, 0x00A1
    in      al, dx
    mov     [cg_a1], al
    mov     dx, 0x00A3
    in      al, dx
    mov     [cg_a3], al
    mov     dx, 0x00A5
    in      al, dx
    mov     [cg_a5], al
    cli
    mov     si, offset cgtab
    mov     di, offset cg_buf
cgd_ent:
    mov     al, [si]
    cmp     al, 0xFF
    je      cgd_put_back
    mov     dx, 0x00A1
    out     dx, al
    mov     al, [si+1]
    mov     dx, 0x00A3
    out     dx, al
    mov     bl, [si+2]
    mov     cl, [si+3]
    xor     ch, ch
cgd_row:
    mov     al, bl
    mov     dx, 0x00A5
    out     dx, al
    call    io_delay
    mov     dx, 0x00A9
    in      al, dx
    mov     [di], al
    inc     di
    inc     bl
    loop    cgd_row
    add     si, 4
    jmp     cgd_ent
cgd_put_back:
    mov     dx, 0x00A1
    mov     al, [cg_a1]
    out     dx, al
    mov     dx, 0x00A3
    mov     al, [cg_a3]
    out     dx, al
    mov     dx, 0x00A5
    mov     al, [cg_a5]
    out     dx, al
    sti
    /* print */
    mov     si, offset cgtab
    mov     di, offset cg_buf
cgp_ent:
    mov     al, [si]
    cmp     al, 0xFF
    je      cgp_done
    mov     dx, offset s_cg
    call    puts
    mov     al, [si]
    call    puthex8
    mov     al, [si+1]
    call    puthex8
    call    putsp
    mov     al, [si+2]
    call    puthex8
    mov     dl, ':'
    call    putc
    mov     cl, [si+3]
    xor     ch, ch
1:  call    putsp
    mov     al, [di]
    call    puthex8
    inc     di
    loop    1b
    call    putnl
    add     si, 4
    jmp     cgp_ent
cgp_done:
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

/* ---------------------------------------------------------------------------------------- */
/* /WR: write-then-read round trips                                                          */
/* ---------------------------------------------------------------------------------------- */
write_tests:
    mov     si, offset rttab
1:  mov     dx, [si]
    cmp     dx, 0xFFFF
    je      2f
    mov     bl, [si+2]          /* the value: written as-is (mode 0) or XORed into was (1) */
    mov     bh, [si+3]
    call    round_trip
    add     si, 4
    jmp     1b
2:  call    mode68_test
    call    mode68off_test      /* 0x68 with the display off (the 0xDC000 test is closed and no longer run) */
    ret

/* round_trip: DX = port, BL = value, BH = 0 write BL, 1 write was ^ BL.
 * Prints `RT pppp was=.. wrote=.. got=.. p31=.. back=.. p31=..`. */
round_trip:
    push    si
    mov     [rt_port], dx
    pushf
    cli
    in      al, dx
    mov     [rt_was], al
    mov     ah, bl
    test    bh, bh
    jz      1f
    xor     ah, al
1:  mov     [rt_wrote], ah
    mov     al, ah
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [rt_got], al
    mov     dx, 0x0031
    in      al, dx
    mov     [rt_p31a], al
    mov     dx, [rt_port]
    mov     al, [rt_was]
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [rt_back], al
    mov     dx, 0x0031
    in      al, dx
    mov     [rt_p31b], al
    popf
    mov     dx, offset s_rt
    call    puts
    mov     ax, [rt_port]
    call    puthex16
    mov     dx, offset s_rt_was
    call    puts
    mov     al, [rt_was]
    call    puthex8
    mov     dx, offset s_rt_wrote
    call    puts
    mov     al, [rt_wrote]
    call    puthex8
    mov     dx, offset s_rt_got
    call    puts
    mov     al, [rt_got]
    call    puthex8
    mov     dx, offset s_rt_p31
    call    puts
    mov     al, [rt_p31a]
    call    puthex8
    mov     dx, offset s_rt_back
    call    puts
    mov     al, [rt_back]
    call    puthex8
    mov     dx, offset s_rt_p31
    call    puts
    mov     al, [rt_p31b]
    call    puthex8
    mov     al, [rt_back]
    cmp     al, [rt_was]
    je      2f
    mov     dx, offset s_rt_diff
    call    puts
2:  call    putnl
    pop     si
    ret

/* mode68_test: 0x68 read, `out 0x68,0x0C` (memory-switch write protect: the ITF's MSW init
 * opens the cells with `out 0x68,0x0D` at BANK4@0x5BA0 and closes them with 0x0C at
 * BANK4@0x5BDC, so 0x0C is the state it leaves), 0x68 read. */
mode68_test:
    mov     dx, offset s_m68
    call    puts
    mov     dx, 0x0068
    in      al, dx
    call    puthex8
    call    putsp
    mov     al, 0x0C
    out     dx, al
    call    io_delay
    in      al, dx
    call    puthex8
    call    putnl
    ret

/* dc000_test: 0xDC000-0xDC00F with the IDE work-RAM gate 0x1E8E = 0x81. The as-found
 * 0x1E8E is read and written back, as probe2 /SHADOW does (docs/probes/SHADOWW.TXT: FE, 81 ->
 * FF, FE back). Under the gate the 16 bytes are saved, 5A A5 is stored at DC000/DC001, the 16
 * are read, the saved 16 are put back and read again. */
dc000_test:
    push    es
    mov     ax, 0xDC00
    mov     es, ax
    mov     dx, 0x1E8E
    in      al, dx
    mov     [dc_was1e], al
    /* gate as found: the 16 bytes (read-only) */
    mov     di, offset dc_off
    call    dc_read16
    pushf
    cli
    mov     dx, 0x1E8E
    mov     al, 0x81
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [dc_on1e], al
    mov     di, offset dc_save
    call    dc_read16
    mov     byte ptr es:[0], 0x5A
    mov     byte ptr es:[1], 0xA5
    mov     di, offset dc_mark
    call    dc_read16
    /* put the saved 16 back */
    xor     bx, bx
1:  mov     al, [dc_save + bx]
    mov     es:[bx], al
    inc     bx
    cmp     bx, 16
    jb      1b
    mov     di, offset dc_after
    call    dc_read16
    mov     dx, 0x1E8E
    mov     al, [dc_was1e]
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [dc_back1e], al
    popf
    pop     es
    mov     dx, offset s_dc_1e
    call    puts
    mov     al, [dc_was1e]
    call    puthex8
    call    putsp
    mov     al, [dc_on1e]
    call    puthex8
    call    putsp
    mov     al, [dc_back1e]
    call    puthex8
    call    putnl
    mov     dx, offset s_dc_off
    mov     si, offset dc_off
    call    dc_print
    mov     dx, offset s_dc_save
    mov     si, offset dc_save
    call    dc_print
    mov     dx, offset s_dc_mark
    mov     si, offset dc_mark
    call    dc_print
    mov     dx, offset s_dc_after
    mov     si, offset dc_after
    call    dc_print
    ret
dc_read16:                      /* ES:0..15 -> DS:DI */
    xor     bx, bx
1:  mov     al, es:[bx]
    mov     [di + bx], al
    inc     bx
    cmp     bx, 16
    jb      1b
    ret
dc_print:                       /* DX = label, SI = 16 bytes */
    call    puts
    mov     cx, 16
1:  mov     al, [si]
    call    puthex8
    call    putsp
    inc     si
    loop    1b
    call    putnl
    ret

/* ---------------------------------------------------------------------------------------- */
/* /MSW5 xx                                                                                  */
/* ---------------------------------------------------------------------------------------- */
msw5_write:
    push    es
    mov     ax, 0xA000
    mov     es, ax
    mov     al, es:[0x3FF2]
    mov     [msw_was], al
    pushf
    cli
    mov     dx, 0x0068
    in      al, dx
    mov     [m68_a], al
    mov     al, 0x0D            /* memory-switch write enable (dip-audit P6) */
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [m68_b], al
    mov     al, [msw5_val]
    mov     es:[0x3FF2], al
    mov     al, 0x0C            /* write protect again */
    out     dx, al
    call    io_delay
    in      al, dx
    mov     [m68_c], al
    mov     al, es:[0x3FF2]
    mov     [msw_now], al
    popf
    pop     es
    mov     dx, offset s_msw5
    call    puts
    mov     al, [msw_was]
    call    puthex8
    mov     dx, offset s_wrote
    call    puts
    mov     al, [msw5_val]
    call    puthex8
    mov     dx, offset s_now
    call    puts
    mov     al, [msw_now]
    call    puthex8
    call    putnl
    mov     dx, offset s_m68w
    call    puts
    mov     al, [m68_a]
    call    puthex8
    call    putsp
    mov     al, [m68_b]
    call    puthex8
    call    putsp
    mov     al, [m68_c]
    call    puthex8
    call    putnl
    ret

/* ---------------------------------------------------------------------------------------- */
/* output helpers (DOS INT 21h, stdout)                                                      */
/* ---------------------------------------------------------------------------------------- */
io_delay:                       /* eight reads of 0x5F, as probe2's io_delay */
    push    ax
    push    cx
    push    dx
    mov     dx, 0x005F
    mov     cx, 8
1:  in      al, dx
    loop    1b
    pop     dx
    pop     cx
    pop     ax
    ret
/* OUTPUT IS BUFFERED (512 bytes) and written with INT 21h AH=40h to handle 1: the /CG dump is
 * ~40 KB, which AH=02 writes one byte per DOS call. `commit` writes the buffer and commits the
 * file (AH=68h; an error on a console is ignored), so a ROW line is on the disk before the row
 * it names runs. No output call is made under cli. */
putc:                           /* DL = character */
    push    bx
    mov     bx, [obuf_n]
    mov     [obuf + bx], dl
    inc     bx
    mov     [obuf_n], bx
    pop     bx
    cmp     word ptr [obuf_n], 512
    jb      1f
    call    flush
1:  ret
puts:                           /* DX = '$'-terminated string */
    push    si
    push    dx
    mov     si, dx
1:  mov     dl, [si]
    cmp     dl, '$'
    je      2f
    call    putc
    inc     si
    jmp     1b
2:  pop     dx
    pop     si
    ret
flush:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     cx, [obuf_n]
    jcxz    1f
    mov     ah, 0x40
    mov     bx, 1
    mov     dx, offset obuf
    int     0x21
    mov     word ptr [obuf_n], 0
1:  pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret
commit:
    call    flush
    push    ax
    push    bx
    mov     ah, 0x68
    mov     bx, 1
    int     0x21
    pop     bx
    pop     ax
    ret
putsp:
    push    dx
    mov     dl, ' '
    call    putc
    pop     dx
    ret
putnl:
    push    dx
    mov     dl, 13
    call    putc
    mov     dl, 10
    call    putc
    pop     dx
    ret
puthexdig:                      /* AL = 0..15 */
    push    ax
    push    dx
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     6f
    add     al, 7
6:  mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret
puthex8:                        /* AL */
    push    ax
    push    ax
    shr     al, 4
    call    puthexdig
    pop     ax
    call    puthexdig
    pop     ax
    ret
puthex16:                       /* AX */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

/* ---------------------------------------------------------------------------------------- */
/* data                                                                                      */
/* ---------------------------------------------------------------------------------------- */
s_banner:   .ascii "XE10CFG configuration stores (tools/hwprobe/xe10cfg)\r\n$"
s_usage:    .ascii "USAGE: XE10CFG | /WR | /CG | /CGWR | /IDE | /IDE2 | /6C | /FD | /W4A0 | /MSW5 xx\r\n$"
s_end:      .ascii "XE10CFG DONE\r\n$"
s_port:     .ascii "PORT $"
s_mem:      .ascii "MEM $"
s_sdip_a0:  .ascii "SDIPA0 $"
s_sdip_a1:  .ascii "SDIPA1 $"
s_sdip_b:   .ascii "SDIPB $"
s_sdip_a2:  .ascii "SDIPA2 $"
s_msw:      .ascii "MSWCELLS $"
s_cg:       .ascii "CG $"
s_cgrest:   .ascii "CGREGS now $"
s_was:      .ascii " was $"
s_rt:       .ascii "RT $"
s_rt_was:   .ascii " was=$"
s_rt_wrote: .ascii " wrote=$"
s_rt_got:   .ascii " got=$"
s_rt_p31:   .ascii " p31=$"
s_rt_back:  .ascii " back=$"
s_rt_diff:  .ascii " NOT-RESTORED$"
s_m68:      .ascii "MODE68 before/after-0C $"
s_dc_1e:    .ascii "DC000 1E8E was/gate/back $"
s_dc_off:   .ascii "DC000 asfound $"
s_dc_save:  .ascii "DC000 gate81 $"
s_dc_mark:  .ascii "DC000 marked $"
s_dc_after: .ascii "DC000 restored $"
s_msw5:     .ascii "MSW5 A3FF2 was=$"
s_wrote:    .ascii " wrote=$"
s_now:      .ascii " now=$"
s_m68w:     .ascii "MODE68 before/after-0D/after-0C $"

/* The read-only port set: item 172 (1), dip-audit P4 (0x7FDB/0x7FDD/0x7FDF), item 36
 * (0x66/0x67/0x6C/0x6D), item 21 (0x0432/0x0433), 0x68, and the 0x9A8 width. 0xA46C is
 * the -86 FIFO data port; XE10T /AUDIT read it on the machine (docs/probes/XE10T-XE10-AUDIT.TXT
 * BA46C v=EE v2=EE), so a read with the FIFO idle is known to be harmless. */
porttab:
    .word 0x0031, 0x0033, 0x0035, 0x0037, 0x0042, 0x0066, 0x0067, 0x0068, 0x006C, 0x006D
    .word 0x00BE, 0x00BF, 0x00F4, 0x0432, 0x0433, 0x043B, 0x0534, 0x063F, 0x09A8
    .word 0x7FD9, 0x7FDB, 0x7FDD, 0x7FDF
    .word 0x0188, 0x018A, 0x018C, 0x018E
    .word 0xA460, 0xA462, 0xA464, 0xA466, 0xA468, 0xA46A, 0xA46C, 0xA46E
    .word 0x0C24, 0x0C2B, 0x0C2D
    .word 0x0F40, 0x0F41, 0x0F42, 0x0F43, 0x0F44, 0x0F45, 0x0F46, 0x0F47
    .word 0x0F48, 0x0F49, 0x0F4A, 0x0F4B, 0x0F4C, 0x0F4D, 0x0F4E, 0x0F4F
    .word 0xFFFF
memtab:
    .word 0x0480, 0x0494, 0x0500, 0x0501, 0x055C, 0x055D, 0x055E, 0x055F
    .word 0x059A, 0x059B        /* item 66: the IDE ROM's standby-settle word [0:59A] */
    .word 0xFFFF

/* CG rows: A1, A3, first A5, count (docs/bios-setup.md; BANK3@0x2322). */
cgtab:
    .byte 0x20, 0x56, 0x00, 16      /* the record, rows 0..0xF (left half) */
    .byte 0x20, 0x56, 0x20, 16      /* the same code, right half */
    .byte 0x21, 0x56, 0x00, 16      /* record rows 0x10..0x1F (0x13/0x14 used) */
    .byte 0x01, 0x56, 0x00, 16      /* the software-DIP mirror, bank A */
    .byte 0x01, 0x56, 0x20, 16      /* the software-DIP mirror, bank B */
    .byte 0x30, 0x56, 0x00, 16      /* code 0x3056 (row 0 bit 5 is a hidden item) */
    .byte 0xFF
CG_TOTAL = 96

/* /WR round trips: port, value, mode (0 = write the value, 1 = write was ^ value).
 *   0x0031 0x0C       P2: the complement of the measured F3 - does port 0x31 latch it?
 *   0x871E ^0x20      P1: the SETUP memory-switch bit (BANK3@0x1581); watch p31 bit 4
 *   0x851E ^0x10      its parity bit (bit 4; docs/bios-setup.md) - item 94
 *   0x881E 0xDC       the parity-bit write (the factory byte; the measured machine reads 7C)
 *   0x8B1E 0x7F       the parity-bit write
 *   0x09A8 ^0xFE      the latch width (bit 0, the 31 kHz select, kept as found) */
rttab:
    .word 0x0031
    .byte 0x0C, 0
    .word 0x871E
    .byte 0x20, 1
    .word 0x851E
    .byte 0x10, 1
    .word 0x881E
    .byte 0xDC, 0
    .word 0x8B1E
    .byte 0x7F, 0
    .word 0x09A8
    .byte 0xFE, 1
    .word 0x006C                /* item 36: the border-colour latch? (as found 00) */
    .byte 0x70, 0
    .word 0x006C
    .byte 0x5A, 0
    .word 0xFFFF

mode:       .byte 0
msw5_val:   .byte 0
msw_was:    .byte 0
msw_now:    .byte 0
m68_a:      .byte 0
m68_b:      .byte 0
m68_c:      .byte 0
cg_a1:      .byte 0
cg_a3:      .byte 0
cg_a5:      .byte 0
rt_was:     .byte 0
rt_wrote:   .byte 0
rt_got:     .byte 0
rt_back:    .byte 0
rt_p31a:    .byte 0
rt_p31b:    .byte 0
dc_was1e:   .byte 0
dc_on1e:    .byte 0
dc_back1e:  .byte 0
    .balign 2
rt_port:    .word 0
sdip_buf:   .space 12
dc_off:     .space 16
dc_save:    .space 16
dc_mark:    .space 16
dc_after:   .space 16
cg_buf:     .space CG_TOTAL
obuf_n:     .word 0
obuf:       .space 512

    .include "xe10cfg/xe10cfg_ext.inc"
