/* lib.inc - XE10T's one shared library: output (file + checksums), the timers, deadlines,
 * the watchdog, the section frame, the restore report and the measurement harness.
 * Sections never read a timer or print a row themselves (rule R8); they call this file.
 *
 * Register conventions: every routine here preserves every register it does not name as
 * an output, and DS = CS on entry. Generated bodies may change ES/FS/GS freely and DS only
 * between their setup and post templates (both of which are also in the control).
 */

/* ======================================================================
 * Output: a 4 KiB buffer flushed to the capture file at every section end
 * (DOS write + commit, R9). Every byte goes through out_c, which keeps the
 * section CRC-16 (CCITT-FALSE) and the run CRC-32 (zlib) - the decoder's
 * truncation and integrity checks.
 * ====================================================================== */
out_c:                                  /* AL = byte */
    push    bx
    push    eax
    mov     bx, word ptr [ob_len]
    mov     byte ptr [OUTBUF + bx], al
    inc     bx
    mov     word ptr [ob_len], bx
    cmp     byte ptr [crc_on], 0
    je      1f
    call    crc32_step
1:  cmp     byte ptr [in_sec], 0
    je      2f
    push    ax
    mov     ax, word ptr [sec_crc]
    pop     bx                          /* BL = byte */
    push    bx
    call    crc16_step_bl
    mov     word ptr [sec_crc], ax
    pop     ax
2:  cmp     word ptr [ob_len], OUTBUF_FLUSH
    jb      3f
    cmp     byte ptr [fl_hold], 0       /* held (an IDE bank switched): wait for the */
    je      21f                         /* section's next safe point unless it is full */
    cmp     word ptr [ob_len], OUTBUF_HARD
    jb      3f
21: call    out_flush_nocommit
3:  pop     eax
    pop     bx
    ret

/* crc16_step_bl: AX = crc16 state, BL = byte -> AX = new state. CCITT-FALSE. */
crc16_step_bl:
    push    cx
    xor     ah, bl
    mov     cx, 8
1:  shl     ax, 1
    jnc     2f
    xor     ax, 0x1021
2:  loop    1b
    pop     cx
    ret

/* crc32_step: [run_crc] updated with AL (reflected 0xEDB88320). */
crc32_step:
    push    eax
    push    ecx
    push    edx
    mov     edx, dword ptr [run_crc]
    movzx   ecx, al
    xor     edx, ecx
    mov     cx, 8
1:  shr     edx, 1
    jnc     2f
    xor     edx, 0xEDB88320
2:  loop    1b
    mov     dword ptr [run_crc], edx
    pop     edx
    pop     ecx
    pop     eax
    ret

out_flush_nocommit:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     cx, word ptr [ob_len]
    jcxz    1f
    mov     bx, word ptr [out_handle]
    mov     dx, OUTBUF
    mov     ah, 0x40
    int     0x21
    mov     word ptr [ob_len], 0
1:  pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* out_flush: write the buffer and commit the file (INT 21h AH=68h), so a later hang
 * loses nothing already printed (R9). */
out_flush:
    call    out_flush_nocommit
    push    ax
    push    bx
    mov     bx, word ptr [out_handle]
    cmp     bx, 2
    jbe     1f
    mov     ah, 0x68
    int     0x21
1:  pop     bx
    pop     ax
    ret

out_s:                                  /* SI = asciz */
    push    si
    push    ax
1:  lodsb
    test    al, al
    jz      2f
    call    out_c
    jmp     1b
2:  pop     ax
    pop     si
    ret

/* out_inline: the asciz string that follows the call is printed; execution resumes
 * after its NUL. Used through the PS macro. */
out_inline:
    push    bp
    mov     bp, sp
    push    si
    push    ax
    mov     si, word ptr [bp+2]
    call    out_s
1:  lodsb                               /* skip to past the NUL */
    test    al, al
    jnz     1b
    mov     word ptr [bp+2], si
    pop     ax
    pop     si
    pop     bp
    ret

out_nl:
    push    ax
    mov     al, 13
    call    out_c
    mov     al, 10
    call    out_c
    pop     ax
    ret

out_sp:
    push    ax
    mov     al, ' '
    call    out_c
    pop     ax
    ret

/* out_d: EAX unsigned decimal */
out_d:
    push    eax
    push    ebx
    push    cx
    push    edx
    mov     ebx, 10
    xor     cx, cx
1:  xor     edx, edx
    div     ebx
    push    dx
    inc     cx
    test    eax, eax
    jnz     1b
2:  pop     ax
    add     al, '0'
    call    out_c
    loop    2b
    pop     edx
    pop     cx
    pop     ebx
    pop     eax
    ret

out_x2:                                 /* AL hex */
    push    ax
    push    ax
    shr     al, 4
    call    out_nib
    pop     ax
    call    out_nib
    pop     ax
    ret
out_nib:
    push    ax
    and     al, 15
    add     al, '0'
    cmp     al, '9'
    jbe     1f
    add     al, 7
1:  call    out_c
    pop     ax
    ret
out_x4:                                 /* AX hex */
    push    ax
    xchg    al, ah
    call    out_x2
    xchg    al, ah
    call    out_x2
    pop     ax
    ret
out_x8:                                 /* EAX hex */
    push    eax
    ror     eax, 16
    call    out_x4
    ror     eax, 16
    call    out_x4
    pop     eax
    ret

/* out_kd: print " <key>=" then EAX decimal. SI = key asciz. */
out_kd:
    call    out_sp
    call    out_s
    push    ax
    mov     al, '='
    call    out_c
    pop     ax
    jmp     out_d

/* con_s: SI = asciz to the console (stderr handle 2), progress only - never the capture. */
con_s:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    mov     dx, si
    xor     cx, cx
1:  lodsb
    test    al, al
    jz      2f
    inc     cx
    jmp     1b
2:  mov     bx, 2
    mov     ah, 0x40
    int     0x21
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ======================================================================
 * Timers
 *
 * ARTIC: 24-bit free-running counter, 307200 Hz (3255.208 ns): 0x5C/0x5D low
 * word, 0x5F bits 23:16 (0x5D/0x5E both mirror bits 15:8 - never read 0x5E).
 * A 16-bit IN at 0x5C is two byte cycles and can tear across a carry out of
 * bit 7, so the word is read until two consecutive reads agree to within 2;
 * the high byte is read before and after and the whole read repeats if it
 * moved (rule R8: one reader, preserves every register but EAX).
 * ====================================================================== */
artic_read:
    push    bx
    push    cx
    push    dx
1:  in      al, 0x5F
    mov     cl, al
    call    artic_lo                    /* BX = coherent low word */
    in      al, 0x5F
    cmp     al, cl
    jne     1b
    movzx   eax, cl
    shl     eax, 16
    mov     ax, bx
    pop     dx
    pop     cx
    pop     bx
    ret

artic_lo:                               /* BX = coherent low word; clobbers AX, DX */
    mov     dx, 0x5C
    in      ax, dx
1:  mov     bx, ax
    in      ax, dx
    push    ax
    sub     ax, bx
    cmp     ax, 2
    pop     ax
    ja      1b
    mov     bx, ax
    ret

/* artic_sync: wait for the next ARTIC edge (the low byte changes), return EAX = the
 * counter just after it. The ARTIC is the deadline source itself, so this one loop is
 * bounded by an iteration count (65535 reads, > 50 ms) and sets [artic_dead] on expiry. */
artic_sync:
    push    cx
    in      al, 0x5C
    mov     ah, al
    mov     cx, 0xFFFF
1:  in      al, 0x5C
    cmp     al, ah
    jne     2f
    loop    1b
    mov     byte ptr [artic_dead], 1
2:  pop     cx
    jmp     artic_read

/* artic_since: EAX = ticks since EAX (24-bit modular). */
artic_since:
    push    ebx
    mov     ebx, eax
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    pop     ebx
    ret

/* PIT channel 0, latched (0x77 <- 0x00), two reads of 0x71 in the byte order pit_cal
 * measured (the order is never assumed: R5). AX = the count. */
pit_read:
    push    dx
    pushf
    cli
    mov     al, 0x00
    out     0x77, al
    in      al, 0x71
    mov     dl, al
    in      al, 0x71
    mov     dh, al
    cmp     byte ptr [pit_swap], 0
    je      1f
    xchg    dl, dh
1:  mov     ax, dx
    popf
    pop     dx
    ret

/* pit_sub: EAX = (EAX - EDX) reduced modulo [pit_mod] (PIT counts down). */
pit_sub:
    and     eax, 0xFFFF
    and     edx, 0xFFFF
    sub     eax, edx
    jns     1f
    add     eax, dword ptr [pit_mod]
1:  ret

/* pit_cal: which of the two bytes 0x71 returns is the LSB: over 64 paired reads
 * the LSB changes on almost every read and the MSB almost never (idelat's method). */
pit_cal:
    push    eax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    pushf
    cli
    xor     si, si                      /* first-byte changes */
    xor     di, di                      /* second-byte changes */
    mov     al, 0
    out     0x77, al
    in      al, 0x71
    mov     bl, al
    in      al, 0x71
    mov     bh, al
    mov     cx, 64
1:  mov     al, 0
    out     0x77, al
    in      al, 0x71
    cmp     al, bl
    je      2f
    inc     si
2:  mov     bl, al
    in      al, 0x71
    cmp     al, bh
    je      3f
    inc     di
3:  mov     bh, al
    loop    1b
    mov     byte ptr [pit_swap], 0
    cmp     di, si
    jbe     4f
    mov     byte ptr [pit_swap], 1
4:  popf
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     eax
    ret

/* ======================================================================
 * Deadlines (R7) and the watchdog
 * ====================================================================== */
/* dl_start: EAX = deadline length in ARTIC ticks. */
dl_start:
    push    eax
    mov     dword ptr [dl_len], eax
    call    artic_read
    mov     dword ptr [dl_t0], eax
    pop     eax
    ret

/* dl_check: CF = 1 when the deadline has expired. Also runs the watchdog. */
dl_check:
    push    eax
    call    wd_check
    mov     eax, dword ptr [dl_t0]
    call    artic_since
    cmp     eax, dword ptr [dl_len]
    cmc                                 /* CF = (elapsed >= len) */
    pop     eax
    ret

/* dl_elapsed: EAX = ticks since dl_start. */
dl_elapsed:
    mov     eax, dword ptr [dl_t0]
    jmp     artic_since

/* timeout_line: SI = what (asciz). Prints `TIMEOUT <SEC> <what> elapsed=<ticks>`. */
timeout_line:
    push    eax
    push    si
    PS      "TIMEOUT "
    mov     si, word ptr [sec_name]
    call    out_s
    call    out_sp
    pop     si
    call    out_s
    call    dl_elapsed
    PS      " elapsed="
    call    out_d
    call    out_nl
    pop     eax
    ret

/* wd_check: when armed and the section has run past its budget, print WATCHDOG,
 * unwind the stack to the section level and jump to the section's exit code, which
 * restores what the section touched (R9, the cooperative watchdog). */
wd_check:
    cmp     byte ptr [wd_armed], 0
    jne     1f
    ret
1:  push    eax
    mov     eax, dword ptr [wd_t0]
    call    artic_since
    cmp     eax, dword ptr [wd_len]
    jae     2f
    pop     eax
    ret
2:  mov     byte ptr [wd_armed], 0
    mov     dword ptr [wd_el], eax
    push    cs
    pop     ds
    cld
    sti
    PS      "WATCHDOG "
    mov     si, word ptr [sec_name]
    call    out_s
    mov     eax, dword ptr [wd_el]
    PS      " elapsed="
    call    out_d
    call    out_nl
    mov     sp, word ptr [wd_sp]
    jmp     word ptr [wd_exit]

/* ======================================================================
 * The section frame
 *
 * sec_begin: SI = name, EAX = watchdog budget (ticks), BX = exit label.
 *   Prints BEGIN:<name>, arms the section CRC, the row count and the watchdog.
 *   The caller's SP after the return is the unwind point for a watchdog abort.
 * sec_end: prints END:<name> rows=<n> sum=<crc16> and flushes + commits.
 * ====================================================================== */
sec_begin:
    mov     word ptr [sec_name], si
    mov     word ptr [wd_exit], bx
    mov     dword ptr [wd_len], eax
    push    ax
    mov     ax, sp
    add     ax, 4                       /* past the saved AX and the return address */
    mov     word ptr [wd_sp], ax
    pop     ax
    push    eax
    push    si
    mov     si, offset con_dot
    call    con_s
    pop     si
    call    con_s
    PS      "BEGIN:"
    call    out_s
    call    out_nl
    call    out_flush                   /* a hang shows as this BEGIN with no END */
    mov     word ptr [sec_crc], 0xFFFF
    mov     word ptr [sec_rows], 0
    mov     byte ptr [in_sec], 1
    mov     byte ptr [sec_fault], 0
    inc     word ptr [n_sections]
    cmp     byte ptr [run_fault], 0
    je      1f
    PS      "FAULT "
    call    out_s
    PS      " after="
    push    si
    mov     si, word ptr [fault_sec]
    call    out_s
    pop     si
    call    out_nl
1:  call    artic_read
    mov     dword ptr [wd_t0], eax
    mov     byte ptr [wd_armed], 1
    pop     eax
    ret

/* sec_disarm: the first call of every exit path (normal or watchdog). */
sec_disarm:
    mov     byte ptr [wd_armed], 0
    sti
    cld
    ret

sec_end:
    push    eax
    push    si
    mov     byte ptr [wd_armed], 0
    mov     byte ptr [rm_on], 0
    mov     byte ptr [fl_hold], 0
    mov     word ptr [rm_port], 0xFFFF
    mov     byte ptr [in_sec], 0
    PS      "END:"
    mov     si, word ptr [sec_name]
    call    out_s
    PS      " rows="
    movzx   eax, word ptr [sec_rows]
    call    out_d
    PS      " sum="
    mov     ax, word ptr [sec_crc]
    call    out_x4
    call    out_nl
    call    out_flush
    cmp     byte ptr [sec_fault], 0
    je      1f
    mov     byte ptr [run_fault], 1
    mov     ax, word ptr [sec_name]
    mov     word ptr [fault_sec], ax
1:  pop     si
    pop     eax
    ret

/* row_start: SI = kind asciz ("R " etc). Prints `<kind><SEC> ` and counts a row. */
row_start:
    inc     word ptr [sec_rows]
info_start:
    push    si
    call    out_s
    mov     si, word ptr [sec_name]
    call    out_s
    call    out_sp
    pop     si
    ret

/* skip_line: SI = reason asciz -> `SKIP <SEC> reason=<..>` */
skip_line:
    push    si
    PS      "SKIP "
    mov     si, word ptr [sec_name]
    call    out_s
    PS      " reason="
    pop     si
    call    out_s
    jmp     out_nl

/* row_mark: SI = tag asciz ([tag_sfx] appended when set), AX = port (0xFFFF: none).
 * Prints `ROW <SEC> <tag> [port=xxxx]` and writes + commits the file (unless [fl_hold])
 * BEFORE a row that touches a device runs: a bus cycle that never completes stops the CPU,
 * which no software watchdog can recover from, so the last line on disk must name the row.
 * Not a measurement line (rows= does not count it). */
row_mark:
    push    si
    push    si
    mov     si, offset k_ROW
    call    info_start
    pop     si
    call    out_s
    push    si
    mov     si, word ptr [tag_sfx]
    test    si, si
    jz      1f
    call    out_s
1:  pop     si
    cmp     ax, 0xFFFF
    je      2f
    PS      " port="
    call    out_x4
2:  call    out_nl
    cmp     byte ptr [fl_hold], 0
    jne     3f
    call    out_flush
3:  pop     si
    ret

/* ======================================================================
 * The restore report (R13)
 *
 * rs_line: SI = what, EAX = was, EDX = now, CL = hex digits (2/4/8),
 *          CH = kind (0 readback, 1 default, 2 self), BL bit0 = was known,
 *          bit1 = now known. readback: OK iff was == now. default/self: OK
 *          unless both are known and differ. A FAIL marks the section faulted.
 * ====================================================================== */
rs_line:
    push    eax
    push    si
    push    eax
    PS      "RESTORE "
    push    si
    mov     si, word ptr [sec_name]
    call    out_s
    pop     si
    call    out_sp
    call    out_s
    PS      " was="
    pop     eax
    test    bl, 1
    jz      1f
    call    out_hexw
    jmp     2f
1:  PS      "-"
2:  PS      " now="
    push    eax
    mov     eax, edx
    test    bl, 2
    jz      3f
    call    out_hexw
    jmp     4f
3:  PS      "-"
4:  pop     eax
    PS      " kind="
    mov     si, offset k_readback
    cmp     ch, 0
    je      5f
    mov     si, offset k_default
    cmp     ch, 1
    je      5f
    mov     si, offset k_self
5:  call    out_s
    /* verdict */
    cmp     bl, 3
    jne     6f
    cmp     eax, edx
    jne     7f
6:  cmp     ch, 0
    jne     8f
    cmp     bl, 3
    je      8f
7:  PS      " FAIL"
    mov     byte ptr [sec_fault], 1
    jmp     9f
8:  PS      " OK"
9:  call    out_nl
    pop     si
    pop     eax
    ret

out_hexw:                               /* EAX in CL hex digits */
    cmp     cl, 2
    je      out_x2
    cmp     cl, 4
    je      out_x4
    jmp     out_x8

/* rs_port8: DX = port, AL = saved byte, SI = name: re-read the port and print a
 * readback RESTORE line. */
rs_port8:
    push    eax
    push    bx
    push    cx
    push    edx
    movzx   eax, al
    push    ax
    in      al, dx
    movzx   edx, al
    pop     ax
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    pop     edx
    pop     cx
    pop     bx
    pop     eax
    ret

/* rs_default: SI = name, EAX = the documented default written: a write-only register. */
rs_default:
    push    bx
    push    cx
    push    edx
    mov     edx, eax
    mov     cx, 0x0102
    mov     bl, 2
    call    rs_line
    pop     edx
    pop     cx
    pop     bx
    ret

/* ======================================================================
 * The measurement harness (R1, R2, R3, R16, R18)
 *
 * A case is a descriptor (CASE macro): tag, unit, n (units per window), iters
 * (loop count), unroll, and four code templates: setup, acc (the measured
 * access), adv (the shell's address step), post. gen_code assembles, at run
 * time, the BODY
 *     setup; mov ebp,iters; pad to 16; L: { acc; adv; k x nop } x unroll;
 *     dec ebp; jnz L (rel16); post; ret
 * Each unit runs acc THEN adv, so adv prepares the NEXT unit and setup must prepare
 * the first (a string row's setup loads CX/SI/DI; a divide row's loads the dividend).
 * and the CONTROL, the same bytes with every acc removed - so the control is
 * byte-identical to the body except the access, by construction, and both CRCs
 * (shell=, bshell=) are printed for the decoder to check. run_case times the
 * control and the body alternately, rep times each, under cli, each window
 * started on an ARTIC edge, and prints min/median/max of the four columns.
 * A sweep case (CF_SWEEP) runs at k = 0,2,4,8,16,32 nops after each access: the
 * knee gives the device period whatever the shell costs (R1).
 * ====================================================================== */


/* gen_emit: copy [SI..BX) to ES:DI; CRC the bytes into [gen_crc] when AL != 0. */
gen_emit:
    push    ax
    push    bx
    push    si
    mov     ah, al
1:  cmp     si, bx
    jae     3f
    mov     al, byte ptr [si]
    stosb
    test    ah, ah
    jz      2f
    push    bx
    push    ax
    mov     bl, al
    mov     ax, word ptr [gen_crc]
    call    crc16_step_bl
    mov     word ptr [gen_crc], ax
    pop     ax
    pop     bx
2:  inc     si
    jmp     1b
3:  pop     si
    pop     bx
    pop     ax
    ret

/* gen_byte: AL = byte to emit and CRC. */
gen_byte:
    push    bx
    push    ax
    stosb
    mov     bl, al
    mov     ax, word ptr [gen_crc]
    call    crc16_step_bl
    mov     word ptr [gen_crc], ax
    pop     ax
    pop     bx
    ret

/* gen_code: SI = descriptor, DI = destination (in CS), AL = 1 with the access, 0 for the
 * control, [cur_k] = nops. Returns AX = shell CRC (acc and the jnz displacement excluded),
 * CF = 1 if the code would overflow GEN_MAX. */
gen_code:
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es
    push    bp
    push    cs
    pop     es
    mov     byte ptr [gen_acc], al
    mov     word ptr [gen_crc], 0xFFFF
    mov     word ptr [gen_base], di
    mov     bp, si                      /* BP = descriptor */
    /* setup */
    mov     si, word ptr [bp+CD_T+0]
    mov     bx, word ptr [bp+CD_T+2]
    mov     al, 1
    call    gen_emit
    /* mov ebp, iters */
    mov     al, 0x66
    call    gen_byte
    mov     al, 0xBD
    call    gen_byte
    mov     cx, 4
    lea     si, [bp+CD_ITERS]
1:  mov     al, byte ptr [si]
    call    gen_byte
    inc     si
    loop    1b
    /* pad to 16 */
2:  test    di, 15
    jz      3f
    mov     al, 0x90
    call    gen_byte
    jmp     2b
3:  mov     dx, di                      /* DX = loop top */
    mov     cx, word ptr [bp+CD_UNR]
4:  cmp     byte ptr [gen_acc], 0
    je      5f
    mov     si, word ptr [bp+CD_T+4]
    mov     bx, word ptr [bp+CD_T+6]
    mov     al, 0                       /* the access: not in the shell CRC */
    call    gen_emit
5:  mov     si, word ptr [bp+CD_T+8]
    mov     bx, word ptr [bp+CD_T+10]
    mov     al, 1
    call    gen_emit
    push    cx
    mov     cx, word ptr [cur_k]
    jcxz    7f
6:  mov     al, 0x90
    call    gen_byte
    loop    6b
7:  pop     cx
    mov     ax, di
    sub     ax, word ptr [gen_base]
    cmp     ax, GEN_MAX - 64
    jae     9f
    loop    4b
    /* dec ebp ; jnz rel16 */
    mov     al, 0x66
    call    gen_byte
    mov     al, 0x4D
    call    gen_byte
    mov     al, 0x0F
    call    gen_byte
    mov     al, 0x85
    call    gen_byte
    mov     ax, dx
    sub     ax, di
    sub     ax, 2
    stosw                               /* displacement: not CRCed (it must differ) */
    /* post, ret */
    mov     si, word ptr [bp+CD_T+12]
    mov     bx, word ptr [bp+CD_T+14]
    mov     al, 1
    call    gen_emit
    mov     al, 0xC3
    call    gen_byte
    mov     ax, di
    sub     ax, word ptr [gen_base]
    cmp     ax, GEN_MAX
    jae     9f
    mov     ax, word ptr [gen_crc]
    clc
    jmp     10f
9:  stc
10: pop     bp
    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    ret

/* time_call: BX = code entry. Starts on an ARTIC edge; EAX = ARTIC ticks, EDX = PIT
 * counts (mod pit_mod) of the window. Interrupt state is the caller's. */
time_call:
    push    ecx
    push    esi
    push    edi
    push    ebp
    push    ds
    push    es
    push    fs
    push    gs
    cld
    call    artic_sync
    mov     esi, eax                    /* a0 */
    call    pit_read
    movzx   edi, ax                     /* p0 */
    pushad
    call    bx
    popad
    push    cs
    pop     ds
    cld
    call    pit_read
    movzx   edx, ax                     /* p1 */
    call    artic_read
    sub     eax, esi
    and     eax, 0x00FFFFFF
    push    eax
    mov     eax, edi
    call    pit_sub                     /* EAX = p0 - p1 mod */
    mov     edx, eax
    pop     eax
    pop     gs
    pop     fs
    pop     es
    pop     ds
    pop     ebp
    pop     edi
    pop     esi
    pop     ecx
    ret

/* run_list: SI = case table (CD_SIZE descriptors, ended by a zero tag word). */
run_list:
    push    si
1:  cmp     word ptr [si], 0
    je      2f
    call    run_case
    add     si, CD_SIZE
    jmp     1b
2:  pop     si
    ret

sweep_ks:   .byte 0, 2, 4, 8, 16, 32, 0xFF

/* run_case: SI = descriptor. */
run_case:
    pushad
    mov     word ptr [cur_case], si
    mov     ax, word ptr [si+CD_FLAGS]
    mov     word ptr [cur_flags], ax
    test    ax, CF_BUF | CF_TRAM
    jz      1f
    cmp     word ptr [buf_seg], 0
    jne     1f
    mov     si, offset rs_nobuf
    call    skip_line
    jmp     rc_out
1:  cmp     byte ptr [rm_on], 0         /* the section asked for a ROW line per case */
    je      11f
    push    si
    mov     ax, word ptr [rm_port]
    mov     si, word ptr [si+CD_TAG]
    call    row_mark
    pop     si
11: mov     word ptr [k_ptr], offset sweep_ks
rc_k:
    mov     bx, word ptr [k_ptr]
    movzx   ax, byte ptr [bx]
    cmp     al, 0xFF
    je      rc_out
    mov     word ptr [cur_k], ax
    mov     si, word ptr [cur_case]
    push    si
    mov     si, word ptr [si+CD_TAG]    /* progress on the console */
    call    con_s
    mov     si, word ptr [tag_sfx]      /* with its port suffix (/IO), as the capture */
    test    si, si
    jz      12f
    call    con_s
12: mov     si, offset con_sp
    call    con_s
    pop     si
    mov     di, GEN_CTL
    mov     al, 0
    call    gen_code
    jc      rc_big
    mov     word ptr [shell_c], ax
    mov     di, GEN_BODY
    mov     al, 1
    call    gen_code
    jc      rc_big
    mov     word ptr [shell_b], ax
    mov     word ptr [poll_to], 0
    xor     cx, cx                      /* repeat index */
rc_rep:
    call    wd_check
    test    word ptr [cur_flags], CF_NOCLI
    jnz     2f
    cli
2:  mov     bx, GEN_CTL
    call    time_call
    mov     di, cx
    shl     di, 2
    mov     dword ptr [A_CART + di], eax
    mov     dword ptr [A_CPIT + di], edx
    mov     bx, GEN_BODY
    call    time_call
    mov     dword ptr [A_ART + di], eax
    mov     dword ptr [A_PIT + di], edx
    sti
    inc     cx
    cmp     cx, word ptr [reps]
    jb      rc_rep
    /* R18: one more body window with interrupts ON, printed as if1=, so the decoder can
     * bound what an ISR would add to an unprotected loop of the same shape */
    mov     bx, GEN_BODY
    sti
    call    time_call
    mov     dword ptr [if1_art], eax
    call    print_row
    test    word ptr [cur_flags], CF_SWEEP
    jz      rc_out
    inc     word ptr [k_ptr]
    jmp     rc_k
rc_big:
    mov     si, offset rs_codebig
    call    skip_line
rc_out:
    popad
    ret

/* sort4: sort the four rep arrays (insertion sort, [reps] dwords each). */
sort_arr:                               /* BX = array base */
    pushad
    mov     cx, word ptr [reps]
    mov     si, 1
1:  cmp     si, cx
    jae     4f
    mov     di, si
2:  test    di, di
    jz      3f
    push    di
    shl     di, 2
    mov     eax, dword ptr [bx+di-4]
    mov     edx, dword ptr [bx+di]
    cmp     eax, edx
    jbe     5f
    mov     dword ptr [bx+di-4], edx
    mov     dword ptr [bx+di], eax
    pop     di
    dec     di
    jmp     2b
5:  pop     di
3:  inc     si
    jmp     1b
4:  popad
    ret

/* out_mmm: BX = sorted array -> "min/med/max" */
out_mmm:
    push    eax
    push    di
    mov     eax, dword ptr [bx]
    call    out_d
    mov     al, '/'
    call    out_c
    mov     di, word ptr [reps]
    shr     di, 1
    shl     di, 2
    mov     eax, dword ptr [bx+di]
    call    out_d
    mov     al, '/'
    call    out_c
    mov     di, word ptr [reps]
    dec     di
    shl     di, 2
    mov     eax, dword ptr [bx+di]
    call    out_d
    pop     di
    pop     eax
    ret

print_row:
    pushad
    mov     bx, A_ART
    call    sort_arr
    mov     bx, A_PIT
    call    sort_arr
    mov     bx, A_CART
    call    sort_arr
    mov     bx, A_CPIT
    call    sort_arr
    mov     bp, word ptr [cur_case]
    mov     si, offset k_R
    call    row_start
    mov     si, word ptr [bp+CD_TAG]
    call    out_s
    mov     si, word ptr [tag_sfx]
    test    si, si
    jz      1f
    call    out_s
1:  PS      " unit="
    mov     si, word ptr [bp+CD_UNIT]
    call    out_s
    mov     eax, dword ptr [bp+CD_N]
    mov     si, offset k_n
    call    out_kd
    movzx   eax, word ptr [cur_k]
    mov     si, offset k_nop
    call    out_kd
    movzx   eax, word ptr [reps]
    mov     si, offset k_rep
    call    out_kd
    PS      " art="
    mov     bx, A_ART
    call    out_mmm
    PS      " pit="
    mov     bx, A_PIT
    call    out_mmm
    PS      " ctl_art="
    mov     bx, A_CART
    call    out_mmm
    PS      " ctl_pit="
    mov     bx, A_CPIT
    call    out_mmm
    PS      " shell="
    mov     ax, word ptr [shell_c]
    call    out_x4
    PS      " bshell="
    mov     ax, word ptr [shell_b]
    call    out_x4
    mov     eax, dword ptr [if1_art]
    mov     si, offset k_if1
    call    out_kd
    test    word ptr [cur_flags], CF_POLL
    jz      2f
    movzx   eax, word ptr [poll_to]
    mov     si, offset k_to
    call    out_kd
2:  call    out_nl
    popad
    ret

/* ======================================================================
 * Trial statistics (T rows): up to TR_MAX dword samples in each of 4 fields.
 * tr_reset; tr_put (BX = field 0..3, EAX = value, at [tr_n]); tr_next;
 * tr_print (SI = tag, the field names in [tr_names]).
 * ====================================================================== */

tr_reset:
    mov     word ptr [tr_n], 0
    ret

tr_put:                                 /* BX = field, EAX = value */
    push    bx
    push    di
    shl     bx, 8                       /* field * 256 bytes = 64 dwords */
    mov     di, word ptr [tr_n]
    shl     di, 2
    mov     dword ptr [TR_BUF + bx + di], eax
    pop     di
    pop     bx
    ret

tr_next:
    cmp     word ptr [tr_n], TR_MAX - 1
    jae     1f
    inc     word ptr [tr_n]
1:  ret

/* tr_print: SI = tag, CX = number of fields, [tr_names] = word array of field-name ptrs. */
tr_print:
    pushad
    push    word ptr [reps]
    mov     ax, word ptr [tr_n]
    test    ax, ax
    jz      9f
    mov     word ptr [reps], ax         /* the sorter and out_mmm use [reps] */
    push    si
    mov     si, offset k_T
    call    row_start
    pop     si
    call    out_s
    mov     si, word ptr [tag_sfx]
    test    si, si
    jz      1f
    call    out_s
1:  movzx   eax, word ptr [tr_n]
    mov     si, offset k_trials
    call    out_kd
    xor     dx, dx
2:  cmp     dx, cx
    jae     8f
    mov     bx, dx
    shl     bx, 8
    add     bx, TR_BUF
    call    sort_arr
    call    out_sp
    mov     si, dx
    shl     si, 1
    add     si, word ptr [tr_names]
    mov     si, word ptr [si]
    call    out_s
    mov     al, '='
    call    out_c
    call    out_mmm
    inc     dx
    jmp     2b
8:  call    out_nl
9:  pop     word ptr [reps]
    popad
    ret
