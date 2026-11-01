/* gfxbench.s - GVRAM / TRAM bandwidth benchmark for the PC-9821.
 *
 * Measures, for each of three windows, the CPU's raw byte throughput through
 * the window: WRITE (fill with `rep stosw`) and READ (`rep lodsw`), timed with
 * the ARTIC counter (307200 Hz). Prints KB/sec for each.
 *
 *   GFXBENCH > OUT.TXT
 *
 * Why this exists: the MiSTer core stores the GVRAM in block RAM (256 blocks,
 * over half the device) because moving it to SDRAM once stalled the machine.
 * This benchmark measures the CPU-side demand so that decision can be made with
 * numbers: the scanout additionally reads ~7.2 MB/sec (640x400x4 planes x 56 Hz)
 * that a CPU benchmark cannot see, and SDRAM adds 100-160 ns per read.
 *
 * WARNING: writes pattern bytes into the windows (the A0000 text plane is the
 * visible console, so the screen is scribbled; A8000+ are the graphics planes
 * and are not shown in text mode). READ-ONLY with respect to the disk.
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

    .equ    PASSES, 8                   /* fills of each window, 32 KiB each */

_start:
    mov     si, offset msg_banner
    call    puts

    mov     ax, 0xA000                  /* text VRAM plane */
    mov     si, offset msg_tram
    call    measure

    mov     ax, 0xA800                  /* GVRAM plane 0 */
    mov     si, offset msg_gvram0
    call    measure

    mov     ax, 0xA200                  /* attribute plane */
    mov     si, offset msg_tram_attr
    call    measure

    mov     si, offset msg_end
    call    puts

    mov     ax, 0x4C00
    int     0x21

/* measure: AX = window segment, DS:SI = label. Prints "LABEL WRITE=.. KB/s READ=.. KB/s". */
measure:
    call    puts                        /* print the label */
    mov     si, offset msg_write
    call    puts                        /* print " WRITE=" */
    mov     bx, ax                      /* the window segment lives in BX from here */

    /* ---- write: fill 32 KiB PASSES times ---- */
    cli
    call    artic_read
    mov     dword ptr [t0], eax
    mov     cx, PASSES
wr_outer:
    push    cx
    mov     es, bx
    xor     di, di
    mov     ax, 0x1234                  /* pattern */
    mov     cx, 0x4000                  /* 16384 words = 32 KiB */
    cld
    rep stosw
    pop     cx
    loop    wr_outer
    call    artic_read
    mov     dword ptr [t1], eax
    sti
    call    kb_sec                      /* EAX = KiB/sec */
    call    putdec32

    mov     si, offset msg_read
    call    puts                        /* print " KB/s READ=" */

    /* ---- read: 32 KiB PASSES times ---- */
    cli
    call    artic_read
    mov     dword ptr [t0], eax
    mov     cx, PASSES
rd_outer:
    push    cx
    push    ds
    mov     ds, bx
    xor     si, si
    mov     cx, 0x4000
    cld
    rep lodsw                          /* read and discard */
    pop     ds
    pop     cx
    loop    rd_outer
    call    artic_read
    mov     dword ptr [t1], eax
    sti
    call    kb_sec                      /* EAX = KiB/sec */
    call    putdec32

    mov     si, offset msg_newline
    call    puts
    ret

/* kb_sec: EAX = (PASSES * 32 KiB) * 307200 / (t1 - t0), i.e. KiB/sec. */
kb_sec:
    mov     eax, dword ptr [t1]
    sub     eax, dword ptr [t0]
    mov     dword ptr [delta], eax
    test    eax, eax
    jz      kb_zero
    mov     eax, PASSES * 32            /* KiB processed */
    mov     edx, 307200
    mul     edx                         /* EDX:EAX = KiB * 307200 */
    mov     ecx, dword ptr [delta]
    div     ecx                         /* EAX = KiB/sec */
    ret
kb_zero:
    xor     eax, eax
    ret

/* ------------------------------------------------------------------ */
/* artic_read: EAX = the 24-bit free-running counter (307200 Hz).       */
/* ------------------------------------------------------------------ */
artic_read:
    /* EAX = the 24-bit ARTIC count; EBX/ECX/DX preserved whole. High byte, low word, high
     * byte again: if the high byte moved, the low word was read at the wrap and its own value
     * says which side (a small low word belongs to the new high byte). The previous
     * low/high/low read double-counted a wrap landing between its first two reads (a +65536
     * jump), and saved only BX/CX while writing EBX/ECX (crt31k found both on the core). */
    push    ebx
    push    ecx
    push    dx
    mov     dx, 0x005F
    in      al, dx
    movzx   ebx, al                     /* H1 */
    mov     dx, 0x005C
    in      ax, dx
    movzx   ecx, ax                     /* L */
    mov     dx, 0x005F
    in      al, dx
    movzx   eax, al                     /* H2 */
    cmp     eax, ebx
    je      ar_same
    cmp     ecx, 0x8000
    jb      ar_same                     /* L read after the wrap: H2 */
    mov     eax, ebx                    /* L read before the wrap: H1 */
ar_same:
    shl     eax, 16
    or      eax, ecx
    pop     dx
    pop     ecx
    pop     ebx
    ret

/* ------------------------------------------------------------------ */
/* output                                                              */
/* ------------------------------------------------------------------ */
putc:                               /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret

puts:                               /* DS:SI, NUL terminated */
    push    ax
    push    si
ps_loop:
    mov     al, [si]
    test    al, al
    jz      ps_done
    mov     dl, al
    call    putc
    inc     si
    jmp     ps_loop
ps_done:
    pop     si
    pop     ax
    ret

/* putdec32: print EAX as unsigned decimal, no leading zero suppression. */
putdec32:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 10
    xor     ecx, ecx
pd_div:
    xor     edx, edx
    div     ebx
    push    edx
    inc     ecx
    test    eax, eax
    jnz     pd_div
pd_out:
    pop     edx
    add     dl, '0'
    mov     al, dl
    mov     dl, al
    call    putc
    dec     ecx
    jnz     pd_out
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* ------------------------------------------------------------------ */
/* data                                                                */
/* ------------------------------------------------------------------ */
    .balign 4
t0:         .long 0
t1:         .long 0
delta:      .long 0

msg_banner:
    .asciz "BEGIN:GFXBENCH\r\n"
msg_tram:
    .asciz "TRAM(A0000)"
msg_gvram0:
    .asciz "GVRAM0(A8000)"
msg_tram_attr:
    .asciz "ATTR(A2000)"
msg_write:
    .asciz " WRITE="
msg_read:
    .asciz " KB/s READ="
msg_newline:
    .asciz " KB/s\r\n"
msg_end:
    .asciz "END:GFXBENCH\r\n"
