/* shbank.s - SHBANK, the 0xF8000-0xFFFFF window's bank-switch ORDERS that docs/probes/SHADOWW.TXT
 * (probe2 /SHADOW /WRITE, st01-st08) left uncaptured: what the window shows after a 0x043D and
 * 0x043F write sequence. Run on the core first, then on the real PC-9821Xe10 (the same binary).
 *
 *   SHBANK > SHBANK.TXT        (no arguments; a few seconds; plain DOS, no EMM386)
 *
 * THE METHOD is probe2's /SHADOW (probe2.s sec_shadow / sh_st_loop / sh_restore_bank), without
 * its memory write: every row runs with interrupts off (cli) and makes no BIOS or DOS call until
 * the window is back, so a bank switch never unmaps code that runs; this program and its data
 * are conventional memory. Per row: the as-found 0x053D (the writable-copy gate, bit 1, left as
 * found: the gate is ON at a DOS prompt, SHADOWW.TXT:112 `053D=1F`) is rewritten, the row's
 * writes are made in order (an I/O-wait delay after each, probe2's io_delay), and the window's
 * signature is read: F8000:0000-0007, the byte sum of F8000:0000-0FFF, and F8E8F/F8E90 (the
 * byte the shadow holds as 04 and BANK7's ROM as 00 at a DOS prompt, SHADOWW.TXT st01 `00/04`,
 * st05 `00/00`). Then 0x053D and 0x043F go back to their first-touch bytes and 0x043D is
 * restored by probe2's search (its read is a strap, 0xFF): the first of 02 00 10 12 18 that
 * reproduces the as-found signature. A row line is committed to disk (INT 21h AH=68h) before
 * each row's writes, so a hang leaves the row's name as the file's last line.
 *
 * THE ROWS (tools/hwprobe/shbank/shbank_decode.py names each signature, and the core's answer):
 *   REF x    043D=00, 043F=x                 the signature of bank x, x = E0 E2 .. EE (the
 *                                            references for every other row: SHADOWW st04/st05)
 *   AFT x    043D=02, 043F=x, 043D=00        (uncaptured 1) a 0x043F select made under 02 and
 *                                            then 00: bank x (two latches) or the ITF?
 *   RE0      043D=00, 043F=EE, 043D=00       (uncaptured 2) back to the ITF, or still bank 7?
 *   UND x    043D=02, 043F=x                 (uncaptured 3) the selects other than E8/EE under 02
 *                                            (E8 and EE too, as controls: SHADOWW st06/st03)
 *   ALT a    043D=00, 043F=E8, 043D=a        (uncaptured 4) a = 10, 12, 18 in place of 02: the
 *                                            BIOS top (02-like) or the ITF (00-like)?
 *   ALU a    043D=00, 043F=EE, 043D=a        the same with bank 7 selected first
 *   ALX a    043D=a, 043F=E8                 a in place of 00 before a select
 *   ASF      no writes (the as-found state, before and after: the restore check)
 *
 * BUILD: make -C tools/hwprobe shbank/shbank.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ SIGLEN, 12                 /* the signature: 8 id bytes, a 16-bit sum, F8E8F, F8E90 */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    mov     dx, offset s_hdr
    call    puts
    pushf
    pop     ax
    mov     [if_was], ah
    cli
    mov     dx, 0x043D
    in      al, dx
    mov     [was43d], al
    mov     dx, 0x043F
    in      al, dx
    mov     [was43f], al
    mov     dx, 0x053D
    in      al, dx
    mov     [was53d], al
    call    sig_read
    mov     si, offset sig
    mov     di, offset sig_asf
    mov     cx, SIGLEN
    rep     movsb
    call    if_back
    mov     dx, offset s_state
    call    puts
    mov     al, [was43d]
    call    puthex8
    mov     dx, offset s_43f
    call    puts
    mov     al, [was43f]
    call    puthex8
    mov     dx, offset s_53d
    call    puts
    mov     al, [was53d]
    call    puthex8
    call    putnl
    mov     dx, offset s_asf
    call    puts
    call    sig_print
    call    commit
    /* own pages: this program must not live in 0xF0000-0xFFFFF (it never does under DOS) */
    mov     ax, cs
    cmp     ax, 0xE000
    jb      1f
    mov     dx, offset s_highcs
    call    puts
    jmp     9f
1:  mov     si, offset rows
2:  cmp     byte ptr [si], 0
    je      8f
    push    si
    mov     dx, offset s_row
    call    puts
    mov     dx, [si + 1]
    call    puts
    call    putnl
    call    commit                  /* the row's name is on disk before its writes */
    pop     si
    push    si
    movzx   cx, byte ptr [si]       /* the number of writes */
    add     si, 3
    cli
    mov     dx, 0x053D
    mov     al, [was53d]
    out     dx, al
    call    io_delay
3:  mov     dx, [si]
    mov     al, [si + 2]
    out     dx, al
    call    io_delay
    add     si, 3
    loop    3b
    call    sig_read
    call    restore
    call    if_back
    pop     si
    push    si
    mov     dx, offset s_res
    call    puts
    mov     dx, [si + 1]
    call    puts
    call    putsp
    call    sig_print_inline
    mov     dx, offset s_rest
    call    puts
    mov     al, [rest43d]
    call    puthex8
    mov     dx, offset s_ok
    cmp     byte ptr [rest_ok], 0
    jne     4f
    mov     dx, offset s_bad
4:  call    puts
    call    commit
    pop     si
    movzx   ax, byte ptr [si]
    mov     bx, ax
    add     ax, ax
    add     ax, bx                  /* 3 bytes per write */
    add     si, ax
    add     si, 3
    jmp     2b
8:  cli
    call    sig_read
    call    if_back
    mov     dx, offset s_end
    call    puts
    call    sig_print
9:  mov     dx, offset s_done
    call    puts
    call    commit
    mov     ax, 0x4C00
    int     0x21

/* restore: 0x053D and 0x043F to their first-touch bytes, then 0x043D by search (probe2.s
 * sh_restore_bank): the first candidate whose window signature equals the as-found one. Under
 * cli. [rest43d] = the value left written, [rest_ok] = 1 when one reproduced it (else 02 left). */
restore:
    push    si
    push    di
    push    cx
    mov     dx, 0x053D
    mov     al, [was53d]
    out     dx, al
    call    io_delay
    mov     dx, 0x043F
    mov     al, [was43f]
    out     dx, al
    call    io_delay
    mov     byte ptr [rest_ok], 0
    mov     si, offset cands
1:  mov     al, [si]
    cmp     al, 0xFF
    je      3f
    mov     [rest43d], al
    mov     dx, 0x043D
    out     dx, al
    call    io_delay
    push    si
    push    word ptr [sig_buf_p]
    mov     word ptr [sig_buf_p], offset sig_chk
    call    sig_read
    pop     word ptr [sig_buf_p]
    mov     si, offset sig_chk
    mov     di, offset sig_asf
    mov     cx, SIGLEN
    repe    cmpsb
    pop     si
    je      2f
    inc     si
    jmp     1b
2:  mov     byte ptr [rest_ok], 1
    jmp     4f
3:  mov     al, 0x02
    mov     [rest43d], al
    mov     dx, 0x043D
    out     dx, al
    call    io_delay
4:  pop     cx
    pop     di
    pop     si
    ret

/* sig_read: the window's signature into [sig_buf_p] (default sig): 8 bytes F8000:0000, the
 * 16-bit sum of F8000:0000-0FFF, F8E8F, F8E90 (SIGLEN = 12) */
sig_read:
    push    ax
    push    bx
    push    cx
    push    si
    push    di
    push    ds
    push    es
    mov     di, [sig_buf_p]
    mov     ax, 0xF800
    mov     ds, ax
    xor     si, si
    mov     cx, 8
1:  mov     al, [si]
    mov     es:[di], al     /* es = our segment */
    inc     si
    inc     di
    loop    1b
    xor     si, si
    xor     bx, bx
    mov     cx, 0x1000
2:  lodsb
    xor     ah, ah
    add     bx, ax
    loop    2b
    mov     es:[di], bx
    mov     al, [0x0E8F]
    mov     es:[di + 2], al
    mov     al, [0x0E90]
    mov     es:[di + 3], al
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     bx
    pop     ax
    ret

/* sig_print: "id=xx xx xx xx xx xx xx xx sum=xxxx e8f=xx e90=xx" + newline */
sig_print:
    call    sig_print_inline
    call    putnl
    ret
sig_print_inline:
    push    si
    push    cx
    mov     dx, offset s_id
    call    puts
    mov     si, offset sig
    mov     cx, 8
1:  lodsb
    call    puthex8
    cmp     cx, 1
    je      2f
    call    putsp
2:  loop    1b
    mov     dx, offset s_sum
    call    puts
    mov     ax, [sig + 8]
    xchg    al, ah
    call    puthex8
    xchg    al, ah
    call    puthex8
    mov     dx, offset s_e8f
    call    puts
    mov     al, [sig + 10]
    call    puthex8
    mov     dx, offset s_e90
    call    puts
    mov     al, [sig + 11]
    call    puthex8
    pop     cx
    pop     si
    ret

/* if_back: the interrupt flag as found on entry */
if_back:
    test    byte ptr [if_was], 0x02
    jz      1f
    sti
1:  ret

/* io_delay: probe2's: eight reads of the I/O-wait port 0x5F so a latch settles */
io_delay:
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

commit:
    push    ax
    push    bx
    mov     ah, 0x68
    mov     bx, 1
    int     0x21
    pop     bx
    pop     ax
    ret

puthex8:
    push    ax
    push    dx
    push    ax
    shr     al, 4
    call    1f
    pop     ax
    and     al, 0x0F
    call    1f
    pop     dx
    pop     ax
    ret
1:  add     al, '0'
    cmp     al, '9'
    jbe     2f
    add     al, 7
2:  mov     dl, al
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret
putsp:
    push    ax
    push    dx
    mov     dl, ' '
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     ax
    ret
putnl:
    push    dx
    mov     dx, offset s_nl
    call    puts
    pop     dx
    ret
puts:
    push    ax
    mov     ah, 0x09
    int     0x21
    pop     ax
    ret

/* ---- data ---- */
s_hdr:      .ascii "SHBANK v1: the F8000 window after 043D/043F write orders (SHADOWW.TXT's method, no memory write)\r\n$"
s_state:    .ascii "STATE first-touch 043D=$"
s_43f:      .ascii " 043F=$"
s_53d:      .ascii " 053D=$"
s_asf:      .ascii "ASF before $"
s_end:      .ascii "ASF after $"
s_row:      .ascii "ROW $"
s_res:      .ascii "RES $"
s_rest:     .ascii " restore43D=$"
s_ok:       .ascii " OK\r\n$"
s_bad:      .ascii " NOMATCH\r\n$"
s_highcs:   .ascii "SHBANK SKIP: loaded at or above E000:0000\r\n$"
s_done:     .ascii "SHBANK DONE\r\n$"
s_nl:       .ascii "\r\n$"
s_id:       .ascii "id=$"
s_sum:      .ascii " sum=$"
s_e8f:      .ascii " e8f=$"
s_e90:      .ascii " e90=$"

cands:      .byte 0x02, 0x00, 0x10, 0x12, 0x18, 0xFF

/* ROW name, then the writes; one row: .byte n; .word name; then n x {.word port; .byte value} */
    .macro W port, val
    .word \port
    .byte \val
    .endm
    .macro ROWH n, name
    .byte \n
    .word \name
    .endm

rows:
    ROWH 2, n_ref_e0
    W 0x043D, 0x00
    W 0x043F, 0xE0
    ROWH 2, n_ref_e2
    W 0x043D, 0x00
    W 0x043F, 0xE2
    ROWH 2, n_ref_e4
    W 0x043D, 0x00
    W 0x043F, 0xE4
    ROWH 2, n_ref_e6
    W 0x043D, 0x00
    W 0x043F, 0xE6
    ROWH 2, n_ref_e8
    W 0x043D, 0x00
    W 0x043F, 0xE8
    ROWH 2, n_ref_ea
    W 0x043D, 0x00
    W 0x043F, 0xEA
    ROWH 2, n_ref_ec
    W 0x043D, 0x00
    W 0x043F, 0xEC
    ROWH 2, n_ref_ee
    W 0x043D, 0x00
    W 0x043F, 0xEE
    ROWH 1, n_ref_00
    W 0x043D, 0x00
    ROWH 1, n_ref_02
    W 0x043D, 0x02
    ROWH 3, n_aft_e0
    W 0x043D, 0x02
    W 0x043F, 0xE0
    W 0x043D, 0x00
    ROWH 3, n_aft_e2
    W 0x043D, 0x02
    W 0x043F, 0xE2
    W 0x043D, 0x00
    ROWH 3, n_aft_e6
    W 0x043D, 0x02
    W 0x043F, 0xE6
    W 0x043D, 0x00
    ROWH 3, n_aft_e8
    W 0x043D, 0x02
    W 0x043F, 0xE8
    W 0x043D, 0x00
    ROWH 3, n_aft_ee
    W 0x043D, 0x02
    W 0x043F, 0xEE
    W 0x043D, 0x00
    ROWH 3, n_re0
    W 0x043D, 0x00
    W 0x043F, 0xEE
    W 0x043D, 0x00
    ROWH 2, n_und_e0
    W 0x043D, 0x02
    W 0x043F, 0xE0
    ROWH 2, n_und_e2
    W 0x043D, 0x02
    W 0x043F, 0xE2
    ROWH 2, n_und_e4
    W 0x043D, 0x02
    W 0x043F, 0xE4
    ROWH 2, n_und_e6
    W 0x043D, 0x02
    W 0x043F, 0xE6
    ROWH 2, n_und_e8
    W 0x043D, 0x02
    W 0x043F, 0xE8
    ROWH 2, n_und_ea
    W 0x043D, 0x02
    W 0x043F, 0xEA
    ROWH 2, n_und_ec
    W 0x043D, 0x02
    W 0x043F, 0xEC
    ROWH 2, n_und_ee
    W 0x043D, 0x02
    W 0x043F, 0xEE
    ROWH 3, n_alt_10
    W 0x043D, 0x00
    W 0x043F, 0xE8
    W 0x043D, 0x10
    ROWH 3, n_alt_12
    W 0x043D, 0x00
    W 0x043F, 0xE8
    W 0x043D, 0x12
    ROWH 3, n_alt_18
    W 0x043D, 0x00
    W 0x043F, 0xE8
    W 0x043D, 0x18
    ROWH 3, n_alu_10
    W 0x043D, 0x00
    W 0x043F, 0xEE
    W 0x043D, 0x10
    ROWH 3, n_alu_12
    W 0x043D, 0x00
    W 0x043F, 0xEE
    W 0x043D, 0x12
    ROWH 3, n_alu_18
    W 0x043D, 0x00
    W 0x043F, 0xEE
    W 0x043D, 0x18
    ROWH 2, n_alx_10
    W 0x043D, 0x10
    W 0x043F, 0xE8
    ROWH 2, n_alx_12
    W 0x043D, 0x12
    W 0x043F, 0xE8
    ROWH 2, n_alx_18
    W 0x043D, 0x18
    W 0x043F, 0xE8
    .byte 0

n_ref_e0:   .ascii "REF E0 : 043D=00 043F=E0$"
n_ref_e2:   .ascii "REF E2 : 043D=00 043F=E2$"
n_ref_e4:   .ascii "REF E4 : 043D=00 043F=E4$"
n_ref_e6:   .ascii "REF E6 : 043D=00 043F=E6$"
n_ref_e8:   .ascii "REF E8 : 043D=00 043F=E8$"
n_ref_ea:   .ascii "REF EA : 043D=00 043F=EA$"
n_ref_ec:   .ascii "REF EC : 043D=00 043F=EC$"
n_ref_ee:   .ascii "REF EE : 043D=00 043F=EE$"
n_ref_00:   .ascii "REF 00 : 043D=00$"
n_ref_02:   .ascii "REF 02 : 043D=02$"
n_aft_e0:   .ascii "AFT E0 : 043D=02 043F=E0 043D=00$"
n_aft_e2:   .ascii "AFT E2 : 043D=02 043F=E2 043D=00$"
n_aft_e6:   .ascii "AFT E6 : 043D=02 043F=E6 043D=00$"
n_aft_e8:   .ascii "AFT E8 : 043D=02 043F=E8 043D=00$"
n_aft_ee:   .ascii "AFT EE : 043D=02 043F=EE 043D=00$"
n_re0:      .ascii "RE0 EE : 043D=00 043F=EE 043D=00$"
n_und_e0:   .ascii "UND E0 : 043D=02 043F=E0$"
n_und_e2:   .ascii "UND E2 : 043D=02 043F=E2$"
n_und_e4:   .ascii "UND E4 : 043D=02 043F=E4$"
n_und_e6:   .ascii "UND E6 : 043D=02 043F=E6$"
n_und_e8:   .ascii "UND E8 : 043D=02 043F=E8$"
n_und_ea:   .ascii "UND EA : 043D=02 043F=EA$"
n_und_ec:   .ascii "UND EC : 043D=02 043F=EC$"
n_und_ee:   .ascii "UND EE : 043D=02 043F=EE$"
n_alt_10:   .ascii "ALT 10 : 043D=00 043F=E8 043D=10$"
n_alt_12:   .ascii "ALT 12 : 043D=00 043F=E8 043D=12$"
n_alt_18:   .ascii "ALT 18 : 043D=00 043F=E8 043D=18$"
n_alu_10:   .ascii "ALU 10 : 043D=00 043F=EE 043D=10$"
n_alu_12:   .ascii "ALU 12 : 043D=00 043F=EE 043D=12$"
n_alu_18:   .ascii "ALU 18 : 043D=00 043F=EE 043D=18$"
n_alx_10:   .ascii "ALX 10 : 043D=10 043F=E8$"
n_alx_12:   .ascii "ALX 12 : 043D=12 043F=E8$"
n_alx_18:   .ascii "ALX 18 : 043D=18 043F=E8$"

    .balign 2
sig_buf_p:  .word sig
sig:        .fill SIGLEN, 1, 0
sig_chk:    .fill SIGLEN, 1, 0
sig_asf:    .fill SIGLEN, 1, 0
was43d:     .byte 0
was43f:     .byte 0
was53d:     .byte 0
rest43d:    .byte 0
rest_ok:    .byte 0
if_was:     .byte 0
