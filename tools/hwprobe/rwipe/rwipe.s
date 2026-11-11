/* rwipe.s - times a program's own phases while it runs in its real environment.
 *
 *   RWIPE [/T:tag] [/O:file] [/N] [/C] [/S] [/B] [/P] prog [args]   run prog, append a log
 *   RWIPE /Q                                                    ERRORLEVEL 1 if INT 60h is set
 *
 * WHAT IT IS FOR. A logo program's sine wipe (99 unpaced steps of GRCG stores, I/O and long
 * arithmetic, no wait) is reported to run several times slower on the real machine than on the
 * core, and a replica of the step (PROBE2 /WIPE) does not show it. This wrapper runs the REAL
 * program, with the REAL driver chain, and stamps its phases with the ARTIC counter (307200 Hz,
 * 24 bits: 0x5C word, 0x5F high byte), so the step cost is measured in the environment where
 * it was observed. The same binary runs on the core and on the machine.
 *
 * HOW. The child is run with INT 21h AX=4B00h. While it runs, INT 18h is wrapped; at the
 * child's first INT 18h AH=41h, if the call comes from offset 0009h of a code segment whose
 * bytes at five fixed offsets match five 32-bit hashes (rol-5/xor; the hashes, not the bytes,
 * are in this source), three far calls are written over that segment's code:
 *   P1 the wipe loop (7 bytes): a far call to wdrv, then a short jump past the loop. wdrv runs
 *      the same 99 calls of the step with the same arguments, the same loop variable, and an
 *      ARTIC stamp before and after each step;
 *   P2 inside the step, after its GVRAM fill (5 bytes): the stub stamps and then executes the
 *      two instructions it replaced;
 *   P3 inside the step, after its 100 rows (7 bytes): the stub executes the GRCG-off write,
 *      stamps, and executes the load it replaced.
 * The program's own code does all of the work; the probe adds 4 stamps per step (each a few
 * I/O reads). While the wipe runs, the 16 hardware interrupt vectors 08h-17h are wrapped: each
 * request is counted and the time spent in it (outermost level only) is summed, so a resident
 * driver's cost inside the wipe is measured, not inferred. INT 60h (PMD) and INT 64h (PPSDRV)
 * calls are logged with their time. /N runs the child with no patch (the overhead control).
 *
 *   /C   interrupts off (cli) for the whole wipe: the wipe with no interrupt service at all.
 *   /S   INT 60h/64h replaced by stubs (AH=09h answers AL=FFh: no music driver), so the
 *        program runs without music even when the drivers are resident (and runs at all when
 *        they are not: an empty INT 60h vector is not called).
 *   /B   the child is the game's shell (BOOT.COM): INT 21h is wrapped; the EXEC of the logo
 *        program is bracketed (INT 60h/64h hooked for its run); at the EXEC of the program after
 *        it (OP.COM) the music is stopped (INT 60h AH=01h, as that program's first call does) and
 *        the shell is ended with AH=4Ch, so the batch goes on with the shell's drivers resident.
 *        Vectors the shell set into its own memory are put back from a copy taken before.
 *   /P   the program after the logo (OP.COM) is run too, up to just after its music stop:
 *        with /B the shell runs it as usual (and is ended at the EXEC after it); without /B it is
 *        the child itself (the drivers must be resident). While it runs, its INT 21h calls
 *        0Eh 3Bh 3Dh 3Eh 3Fh 48h-4Ah 4Ch are logged (3Bh/3Dh/3Fh also at their return, with CF),
 *        and so are its INT 18h 0Ch/0Dh/12h/40h-42h calls (0Dh..0Ch brackets its CG glyph
 *        upload through 0xA1-0xA9), every disk BIOS call (INT 1Bh, entry and return, plus a
 *        count and the total time) and every critical error (INT 24h; without /B it answers
 *        Fail, as the game's shell's own handler does). At its first INT 18h AH=41h (return
 *        offset 013Bh), when six hashed code windows match, the `jnc` after its drum-bank load
 *        (offset 01DCh) becomes two NOPs, so right after the music stop it takes its own error
 *        exit, which restores its vectors, the IMR and the screen and stops the music again.
 *        If the windows do not match, the program is ended there with AH=4Ch (code FEh), before
 *        it has hooked anything that outlives it.
 *   /T:  a tag of up to 8 characters for the log; /O: the log file (default RWIPE.TXT, appended).
 *   /Q   no run: ERRORLEVEL 1 if the INT 60h vector is not 0000:0000, else 0.
 *
 * Before the child runs it records port 0x31, both IMRs, 0000:0500-0501, the largest free
 * block, a 1,000,000-iteration dec/jnz loop (cli) and 30 VSYNC periods (0xA0 bit 5) in ARTIC
 * ticks, and the vectors 08h 0Ah 14h 18h 21h 60h 64h. After the child: if any vector this
 * program set no longer points to it (a driver chained over it), it stays resident with its
 * handlers passing straight through, and says so (UNHOOK STUCK=n).
 *
 * The log (rwipe_decode.py reads it): RWIPE BEGIN/ENV/CAL/VEC/EXEC/PATCH/EV/WIPE/STEP/ISR/
 * BOOT/MUSIC/OP/UNHOOK/END rows; times are raw 24-bit ARTIC values in hex. At most 256 EV rows;
 * disk BIOS calls stop being logged at 224, so the events after them still fit.
 *
 * BUILD: make -C tools/hwprobe rwipe/rwipe.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    jmp     main

/* ---- variables ------------------------------------------------------------------------- */
    .balign 4
old18:      .long 0
old21:      .long 0
old60:      .long 0
old64:      .long 0
old1b:      .long 0
old24:      .long 0
op_v05:     .long 0
op_v06:     .long 0
n1b:        .long 0
t1b:        .long 0
t1b0:       .long 0
n24:        .word 0
oldv:       .space 64
clab_step:  .word 0x02C0
clab_cs:    .word 0
w_t0:       .long 0
w_t1:       .long 0
isr_t0:     .long 0
exec_t0:    .long 0
exec_t1:    .long 0
cal_loop:   .long 0
cal_frm:    .long 0
vecs:       .space 28
clab_ds:    .word 0
cur_i:      .word 0
ev_n:       .word 0
w_flags:    .word 0
w_sflags:   .word 0
exec_ax:    .word 0
rc:         .word 0
freep:      .word 0
save_sp:    .word 0
save_ss:    .word 0
boot_psp:   .word 0
boot_end:   .word 0
restored:   .word 0
stuck:      .word 0
isr_stuck:  .word 0
opos:       .word 0
fh:         .word 0
pblock:     .word 0, 0, 0, 0x5C, 0, 0x6C, 0
active:     .byte 0
patched:    .byte 0
went:       .byte 0
isr_depth:  .byte 0
exec_cf:    .byte 0
music:      .byte 0
mstop:      .byte 0
boot_stop:  .byte 0
h60:        .byte 0                 /* 0 none, 1 logging hook, 2 stub */
h21:        .byte 0
nomem:      .byte 0
opt_n:      .byte 0
opt_c:      .byte 0
opt_s:      .byte 0
opt_b:      .byte 0
opt_q:      .byte 0
opt_p:      .byte 0
op_phase:   .byte 0
op_done:    .byte 0
op_seen:    .byte 0
op_patch:   .byte 0                 /* 0 none, 1 patched, 2 windows did not match */
p31:        .byte 0
imrm:       .byte 0
imrs:       .byte 0
b500:       .byte 0
b501:       .byte 0
w_imrm:     .byte 0
w_imrs:     .byte 0
ev_name:    .space 8
tmpname:    .space 14
tag:        .space 10
fname:      .asciz "RWIPE.TXT"
            .space 54
child:      .space 80
ctail:      .space 130
s_clab:     .asciz "CLABLOGO.EXE"
s_op:       .asciz "OP.COM"

/* the signature windows: offset, length, rol-5/xor hash of the bytes (computed from the
 * program file; no program bytes are kept here) */
sigs:
    .word 0x0005, 5
    .long 0x0B63B7CB
    .word 0x02C0, 8
    .long 0x805B1AFE
    .word 0x02DF, 10
    .long 0x76B49064
    .word 0x037F, 10
    .long 0x46A9AF19
    .word 0x04A1, 37
    .long 0xFD96C8D4
    .word 0xFFFF
/* the program after the logo (OP.COM), offsets in its PSP segment: the entry, the INT 18h AH=41h
 * call, the drum-bank load with the patched `jnc` (01DCh), its error exit, its music-stop
 * routine, its CG glyph upload loop */
op_sigs:
    .word 0x0100, 16
    .long 0x3C61A4DB
    .word 0x0137, 6
    .long 0x6C76F7B6
    .word 0x01D6, 20
    .long 0xC10B4016
    .word 0x021E, 32
    .long 0xD81F04F5
    .word 0x1043, 18
    .long 0x423327F2
    .word 0x10DF, 24
    .long 0x5A4B8D03
    .word 0xFFFF

isr_tab:
    .irp k, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .word isrw_\k
    .endr

/* ---- resident handlers ----------------------------------------------------------------- */

/* artic_read: EAX = the 24-bit ARTIC (stamp.s / xe10t lib.inc's reader); preserves the rest */
artic_read:
    push    bx
    push    cx
    push    dx
1:  in      al, 0x5F
    mov     cl, al
    mov     dx, 0x5C
    in      ax, dx
2:  mov     bx, ax
    in      ax, dx
    push    ax
    sub     ax, bx
    cmp     ax, 2
    pop     ax
    ja      2b
    mov     bx, ax
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

/* stamp_bx: DS:[BX] = ARTIC; preserves every register */
stamp_bx:
    push    eax
    call    artic_read
    mov     [bx], eax
    pop     eax
    ret

/* ev_log: DS = CS. AX = value, CL = class; ev_name (8 bytes) is copied and cleared. */
ev_log:
    pushf
    cli
    pushad
    push    es
    push    cs
    pop     es
    mov     di, [ev_n]
    cmp     di, 256
    jae     9f
    shl     di, 4
    add     di, offset ev_buf
    push    ax
    call    artic_read
    mov     [di], eax
    pop     ax
    mov     [di + 4], cl
    mov     [di + 6], ax
    add     di, 8
    mov     si, offset ev_name
    mov     cx, 8
    rep     movsb
    inc     word ptr [ev_n]
9:  mov     di, offset ev_name
    xor     al, al
    mov     cx, 8
    rep     stosb
    pop     es
    popad
    popf
    ret

/* ev_log_lim: ev_log while fewer than 224 rows are taken (used for the disk BIOS rows) */
ev_log_lim:
    cmp     word ptr [ev_n], 224
    jae     1f
    call    ev_log
1:  ret

/* INT 18h: log AH=40h-42h; at AH=41h from offset 0009h try the patch */
hook18:
    cmp     byte ptr cs:[active], 0
    je      h18_pass
    push    bp
    mov     bp, sp
    push    ds
    push    es
    pushad
    push    cs
    pop     ds
    cmp     ah, 0x40
    jb      h18_lo
    cmp     ah, 0x42
    ja      h18_done
    mov     cl, 1
    call    ev_log
    cmp     ah, 0x41
    jne     h18_done
    cmp     byte ptr [op_phase], 0
    jne     h18_op
    cmp     byte ptr [patched], 0
    jne     h18_done
    cmp     byte ptr [opt_n], 0
    jne     h18_done
    cmp     word ptr [bp + 2], 0x0009
    jne     h18_done
    mov     es, [bp + 4]
    mov     si, offset sigs
    call    sig_check
    mov     byte ptr [patched], 2
    mov     cl, 3
    jc      1f
    call    apply_patch
    mov     byte ptr [patched], 1
    mov     cl, 2
1:  mov     ax, es
    mov     [clab_cs], ax
    call    ev_log
    jmp     h18_done
h18_lo:                                   /* OP phase: 0Ch/0Dh text on/off, 12h cursor off */
    cmp     byte ptr [op_phase], 0
    je      h18_done
    cmp     ah, 0x0C
    je      1f
    cmp     ah, 0x0D
    je      1f
    cmp     ah, 0x12
    jne     h18_done
1:  mov     cl, 1
    call    ev_log
    jmp     h18_done
h18_op:                                   /* OP phase, AH=41h: the exit patch */
    cmp     byte ptr [op_patch], 0
    jne     h18_done
    cmp     word ptr [bp + 2], 0x013B
    jne     h18_done
    mov     es, [bp + 4]
    mov     si, offset op_sigs
    call    sig_check
    jc      1f
    mov     word ptr es:[0x01DC], 0x9090
    mov     byte ptr [op_patch], 1
    mov     ax, es
    mov     cl, 0x0B
    call    ev_log
    jmp     h18_done
1:  mov     byte ptr [op_patch], 2
    mov     ax, es
    mov     cl, 0x0C
    call    ev_log
    xor     ax, ax                        /* end it: put back the two vectors it has set that */
    mov     es, ax                        /* DOS does not restore (05h, 06h), then AH=4Ch */
    cli
    mov     eax, [op_v05]
    mov     es:[0x05 * 4], eax
    mov     eax, [op_v06]
    mov     es:[0x06 * 4], eax
    sti
    mov     ax, 0x4CFE
    int     0x21
    jmp     .
h18_done:
    popad
    pop     es
    pop     ds
    pop     bp
h18_pass:
    jmp     dword ptr cs:[old18]

/* sig_check: ES = candidate code segment, DS:SI = its window table; CF set on any mismatch */
sig_check:
1:  mov     di, [si]
    cmp     di, 0xFFFF
    je      8f
    mov     cx, [si + 2]
    xor     edx, edx
2:  rol     edx, 5
    movzx   eax, byte ptr es:[di]
    xor     edx, eax
    inc     di
    loop    2b
    cmp     edx, [si + 4]
    jne     9f
    add     si, 8
    jmp     1b
8:  clc
    ret
9:  stc
    ret

/* apply_patch: ES = the program's code segment (matched) */
apply_patch:
    cli
    mov     ax, cs
    mov     byte ptr es:[0x04A1], 0x9A
    mov     word ptr es:[0x04A2], offset wdrv
    mov     word ptr es:[0x04A4], ax
    mov     word ptr es:[0x04A6], 0x1EEB         /* jmp short 0x4C6 */
    mov     byte ptr es:[0x02DF], 0x9A
    mov     word ptr es:[0x02E0], offset stub2
    mov     word ptr es:[0x02E2], ax
    mov     byte ptr es:[0x037F], 0x9A
    mov     word ptr es:[0x0380], offset stub3
    mov     word ptr es:[0x0382], ax
    mov     word ptr es:[0x0384], 0x9090
    sti
    ret

/* INT 60h / 64h: log and chain (h60 = 1) or stub (h60 = 2) */
hook60:
    cmp     byte ptr cs:[active], 0
    je      1f
    push    ds
    push    cx
    push    cs
    pop     ds
    mov     cl, 4
    call    ev_log
    cmp     ah, 0
    jne     2f
    mov     byte ptr [music], 1
2:  pop     cx
    pop     ds
1:  jmp     dword ptr cs:[old60]
hook64:
    cmp     byte ptr cs:[active], 0
    je      1f
    push    ds
    push    cx
    push    cs
    pop     ds
    mov     cl, 5
    call    ev_log
    pop     cx
    pop     ds
1:  jmp     dword ptr cs:[old64]
stub60:
    push    ds
    push    cx
    push    cs
    pop     ds
    mov     cl, 6
    call    ev_log
    pop     cx
    pop     ds
    cmp     ah, 0x09
    jne     1f
    mov     al, 0xFF
1:  iret
stub64:
    push    ds
    push    cx
    push    cs
    pop     ds
    mov     cl, 7
    call    ev_log
    pop     cx
    pop     ds
    iret

/* INT 21h (/B, /P): bracket the logo program's EXEC; in /P run OP.COM with its calls logged; end
 * the shell at the EXEC after the last program it is to run */
hook21:
    cmp     byte ptr cs:[active], 0
    je      h21_pass
    cmp     byte ptr cs:[op_phase], 0
    je      h21_x
    cmp     ah, 0x4B
    je      h21_x
    cmp     ah, 0x3B
    je      h21_cd
    cmp     ah, 0x3D
    je      h21_open
    cmp     ah, 0x3F
    je      h21_logw
    cmp     ah, 0x0E
    je      h21_log1
    cmp     ah, 0x3E
    je      h21_log1
    cmp     ah, 0x48
    jb      h21_pass
    cmp     ah, 0x4A
    jbe     h21_log1
    cmp     ah, 0x4C
    jne     h21_pass
h21_log1:                                 /* OP phase: entry only */
    push    ds
    push    cx
    push    cs
    pop     ds
    mov     cl, 0x0E
    call    ev_log
    pop     cx
    pop     ds
    jmp     h21_pass
h21_cd:                                   /* CHDIR: AL of the logged value = the path's first byte */
    push    ds
    push    cx
    push    ax
    push    bx
    mov     bx, dx
    mov     al, [bx]
    pop     bx
    push    cs
    pop     ds
    mov     cl, 0x0E
    call    ev_log
    pop     ax
    pop     cx
    pop     ds
    jmp     h21_wrap
h21_open:                                 /* OPEN: the basename in the row */
    push    ds
    push    es
    pushad
    call    get_name
    mov     ax, 0x3D00
    mov     cl, 0x0E
    call    ev_log
    popad
    pop     es
    pop     ds
    jmp     h21_wrap
h21_logw:
    push    ds
    push    cx
    push    cs
    pop     ds
    mov     cl, 0x0E
    call    ev_log
    pop     cx
    pop     ds
h21_wrap:                                 /* the call, then its return: CLS 0Fh, or 10h with CF */
    pushf
    call    dword ptr cs:[old21]
    pushf
    push    ds
    push    cx
    push    cs
    pop     ds
    mov     cl, 0x0F
    jnc     1f
    mov     cl, 0x10
1:  call    ev_log
    pop     cx
    pop     ds
    popf
    retf    2

h21_x:
    cmp     ax, 0x4B00
    jne     h21_pass
    push    ds
    push    es
    pushad
    call    get_name
    mov     ax, 0x4B00
    mov     cl, 8
    call    ev_log
    cmp     byte ptr [op_done], 0
    jne     h21_stop
    mov     si, offset tmpname
    mov     di, offset s_clab
    call    strcmp
    je      h21_clab
    mov     si, offset tmpname
    mov     di, offset s_op
    call    strcmp
    je      h21_opx
    popad
    pop     es
    pop     ds
h21_pass:
    jmp     dword ptr cs:[old21]

h21_opx:
    cmp     byte ptr [opt_p], 0
    je      h21_stop
    call    op_begin
    popad
    pop     es
    pop     ds
    pushf
    call    dword ptr cs:[old21]          /* OP.COM runs here, to its patched exit */
    pushf
    push    ds
    pushad
    push    cs
    pop     ds
    mov     cl, 0x0D
    call    ev_log
    call    op_end
    popad
    pop     ds
    popf
    retf    2

/* get_name: the basename of the caller's DS:DX, upper case, into cs:tmpname, and up to its '.'
 * (8 characters at most) into cs:ev_name; returns DS = ES = CS */
get_name:
    mov     si, dx
    mov     bx, dx
1:  lodsb
    test    al, al
    jz      2f
    cmp     al, '\\'
    je      3f
    cmp     al, ':'
    jne     1b
3:  mov     bx, si
    jmp     1b
2:  mov     si, bx
    push    cs
    pop     es
    mov     di, offset tmpname
    mov     cx, 13
4:  lodsb
    cmp     al, 'a'
    jb      5f
    cmp     al, 'z'
    ja      5f
    sub     al, 0x20
5:  stosb
    test    al, al
    jz      6f
    loop    4b
    mov     byte ptr es:[di], 0
6:  push    cs
    pop     ds
    mov     si, offset tmpname
    mov     di, offset ev_name
    mov     cx, 8
7:  lodsb
    test    al, al
    jz      8f
    cmp     al, '.'
    je      8f
    stosb
    loop    7b
8:  ret

/* op_begin / op_end: DS = CS. The OP phase: INT 60h/64h logged, INT 1Bh and 24h wrapped. */
op_begin:
    call    hook6064
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     eax, es:[0x05 * 4]
    mov     [op_v05], eax
    mov     eax, es:[0x06 * 4]
    mov     [op_v06], eax
    mov     eax, es:[0x1B * 4]
    mov     [old1b], eax
    mov     word ptr es:[0x1B * 4], offset hook1b
    mov     es:[0x1B * 4 + 2], cs
    mov     eax, es:[0x24 * 4]
    mov     [old24], eax
    mov     word ptr es:[0x24 * 4], offset hook24
    mov     es:[0x24 * 4 + 2], cs
    mov     byte ptr [op_seen], 1
    mov     byte ptr [op_phase], 1
    sti
    pop     es
    ret
op_end:
    mov     byte ptr [op_phase], 0
    mov     byte ptr [op_done], 1
    push    es
    xor     ax, ax
    mov     es, ax
    mov     cx, cs
    cli
    cmp     word ptr es:[0x1B * 4], offset hook1b
    jne     1f
    cmp     es:[0x1B * 4 + 2], cx
    jne     1f
    mov     eax, [old1b]
    mov     es:[0x1B * 4], eax
    jmp     2f
1:  inc     word ptr [stuck]
2:  cmp     word ptr es:[0x24 * 4], offset hook24
    jne     3f
    cmp     es:[0x24 * 4 + 2], cx
    jne     3f
    mov     eax, [old24]
    mov     es:[0x24 * 4], eax
3:  sti
    pop     es
    call    unhook6064
    ret

/* INT 1Bh (OP phase): every disk BIOS call, at entry (CLS 11h) and return (12h, or 13h with CF) */
hook1b:
    cmp     byte ptr cs:[op_phase], 0
    jne     1f
    jmp     dword ptr cs:[old1b]
1:  push    ds
    push    cx
    push    cs
    pop     ds
    inc     dword ptr [n1b]
    mov     cl, 0x11
    call    ev_log_lim
    push    eax
    call    artic_read
    mov     [t1b0], eax
    pop     eax
    pop     cx
    pop     ds
    pushf
    call    dword ptr cs:[old1b]
    pushf
    push    ds
    push    cx
    push    cs
    pop     ds
    push    eax
    call    artic_read
    sub     eax, [t1b0]
    and     eax, 0x00FFFFFF
    add     [t1b], eax
    pop     eax
    mov     cl, 0x12
    push    bp
    mov     bp, sp
    test    byte ptr [bp + 6], 1
    pop     bp
    jz      2f
    mov     cl, 0x13
2:  call    ev_log_lim
    pop     cx
    pop     ds
    popf
    retf    2

/* INT 24h (OP phase): a critical error (CLS 14h, AX as DOS passes it); chained to the shell's
 * handler in /B, answered Fail (AL=3, as the game's shell does) without /B */
hook24:
    push    ds
    push    cx
    push    cs
    pop     ds
    inc     word ptr [n24]
    mov     cl, 0x14
    call    ev_log
    pop     cx
    pop     ds
    cmp     byte ptr cs:[opt_b], 0
    je      1f
    jmp     dword ptr cs:[old24]
1:  mov     al, 3
    iret

h21_clab:
    call    hook6064
    popad
    pop     es
    pop     ds
    pushf
    call    dword ptr cs:[old21]          /* the logo program runs here */
    pushf
    push    ds
    pushad
    push    cs
    pop     ds
    mov     cl, 9
    call    ev_log
    cmp     byte ptr [opt_p], 0           /* /P: INT 60h/64h stay logged through OP.COM */
    jne     1f
    call    unhook6064
1:  popad
    pop     ds
    popf
    retf    2

h21_stop:
    mov     byte ptr [boot_stop], 1
    mov     ah, 0x62
    pushf
    call    dword ptr cs:[old21]
    mov     [boot_psp], bx
    dec     bx
    mov     es, bx
    mov     ax, es:[3]
    inc     bx
    add     ax, bx
    mov     [boot_end], ax
    mov     ax, 0x4C00
    mov     cl, 10
    call    ev_log
    mov     byte ptr [active], 0
    mov     ax, 0x4C00
    pushf
    call    dword ptr cs:[old21]          /* does not return: the shell ends */
    jmp     .

/* strcmp: DS:SI vs DS:DI, ZF on equal */
strcmp:
1:  mov     al, [si]
    cmp     al, [di]
    jne     2f
    test    al, al
    jz      2f
    inc     si
    inc     di
    jmp     1b
2:  ret

/* hook6064: DS = CS. Hook INT 60h/64h for logging if they are set and not already ours. */
hook6064:
    cmp     byte ptr [h60], 0
    jne     9f
    push    es
    xor     ax, ax
    mov     es, ax
    mov     eax, es:[0x60 * 4]
    test    eax, eax
    jz      8f
    cli
    mov     [old60], eax
    mov     eax, es:[0x64 * 4]
    mov     [old64], eax
    mov     word ptr es:[0x60 * 4], offset hook60
    mov     es:[0x60 * 4 + 2], cs
    mov     word ptr es:[0x64 * 4], offset hook64
    mov     es:[0x64 * 4 + 2], cs
    sti
    mov     byte ptr [h60], 1
8:  pop     es
9:  ret

/* unhook6064: DS = CS. Put INT 60h/64h back where they still point to this program. */
unhook6064:
    cmp     byte ptr [h60], 0
    je      9f
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     dx, offset hook60
    mov     bx, offset hook64
    cmp     byte ptr [h60], 2
    jne     1f
    mov     dx, offset stub60
    mov     bx, offset stub64
1:  mov     cx, cs
    cmp     es:[0x60 * 4], dx
    jne     2f
    cmp     es:[0x60 * 4 + 2], cx
    jne     2f
    mov     eax, [old60]
    mov     es:[0x60 * 4], eax
    jmp     3f
2:  inc     word ptr [stuck]
3:  cmp     es:[0x64 * 4], bx
    jne     4f
    cmp     es:[0x64 * 4 + 2], cx
    jne     4f
    mov     eax, [old64]
    mov     es:[0x64 * 4], eax
    jmp     5f
4:  cmp     dword ptr [old64], 0
    je      5f
    inc     word ptr [stuck]
5:  sti
    mov     byte ptr [h60], 0
    pop     es
9:  ret

/* ---- the wipe driver and the step stubs ------------------------------------------------- */

/* wdrv: far, called by P1 in place of the loop `for i = 1 to 99: step((99-i)*2, i)` */
wdrv:
    pushad
    push    ds
    push    es
    mov     cs:[clab_ds], ds
    push    cs
    pop     ds
    mov     byte ptr [went], 1
    mov     bx, offset w_t0
    call    stamp_bx
    pushf
    pop     ax
    mov     [w_flags], ax
    in      al, 0x02
    mov     [w_imrm], al
    in      al, 0x0A
    mov     [w_imrs], al
    call    isr_install
    pushf
    pop     ax
    mov     [w_sflags], ax
    cmp     byte ptr [opt_c], 0
    je      1f
    cli
1:  mov     word ptr [cur_i], 1
2:  mov     es, [clab_ds]
    mov     ax, [cur_i]
    mov     es:[0xBB70], ax
    mov     bx, ax
    shl     bx, 4
    add     bx, offset steps_buf
    call    stamp_bx
    mov     ax, 99
    sub     ax, [cur_i]
    shl     ax, 1
    push    ax
    push    word ptr [cur_i]
    mov     ds, [clab_ds]
    call    dword ptr cs:[clab_step]
    push    cs
    pop     ds
    mov     bx, [cur_i]
    shl     bx, 4
    add     bx, offset steps_buf + 12
    call    stamp_bx
    inc     word ptr [cur_i]
    cmp     word ptr [cur_i], 99
    jbe     2b
    push    word ptr [w_sflags]
    popf
    mov     bx, offset w_t1
    call    stamp_bx
    call    isr_remove
    pop     es
    pop     ds
    popad
    retf

/* stub2: replaces `xor ax,ax / mov [bp-4],ax` after the fill */
stub2:
    push    ds
    push    bx
    push    cs
    pop     ds
    mov     bx, [cur_i]
    shl     bx, 4
    add     bx, offset steps_buf + 4
    call    stamp_bx
    pop     bx
    pop     ds
    xor     ax, ax
    mov     [bp - 4], ax
    retf

/* stub3: replaces `mov al,0 / out 0x7C,al / mov al,[0xBB6E]` after the rows */
stub3:
    mov     al, 0
    out     0x7C, al
    push    ds
    push    bx
    push    cs
    pop     ds
    mov     bx, [cur_i]
    shl     bx, 4
    add     bx, offset steps_buf + 8
    call    stamp_bx
    pop     bx
    pop     ds
    mov     al, [0xBB6E]
    retf

/* ---- interrupt accounting during the wipe ----------------------------------------------- */
    .irp k, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
isrw_\k:
    push    \k
    call    isr_in
    pushf
    call    dword ptr cs:[oldv + 4 * \k]
    push    \k
    call    isr_out
    iret
    .endr

isr_in:
    push    bp
    mov     bp, sp
    push    ds
    push    eax
    push    bx
    push    cs
    pop     ds
    mov     bx, [bp + 4]
    shl     bx, 2
    inc     dword ptr [isr_cnt + bx]
    cmp     byte ptr [isr_depth], 0
    jne     1f
    call    artic_read
    mov     [isr_t0], eax
1:  inc     byte ptr [isr_depth]
    pop     bx
    pop     eax
    pop     ds
    pop     bp
    ret     2

isr_out:
    push    bp
    mov     bp, sp
    push    ds
    push    eax
    push    bx
    push    cs
    pop     ds
    mov     bx, [bp + 4]
    shl     bx, 2
    dec     byte ptr [isr_depth]
    jnz     1f
    call    artic_read
    sub     eax, [isr_t0]
    and     eax, 0x00FFFFFF
    add     [isr_tick + bx], eax
1:  pop     bx
    pop     eax
    pop     ds
    pop     bp
    ret     2

/* isr_install / isr_remove: DS = CS; vectors 08h-17h */
isr_install:
    push    es
    xor     ax, ax
    mov     es, ax
    pushf
    cli
    xor     bx, bx
1:  mov     si, bx
    shl     si, 2
    mov     eax, es:[0x20 + si]
    mov     [oldv + si], eax
    mov     di, bx
    shl     di, 1
    mov     ax, [isr_tab + di]
    mov     es:[0x20 + si], ax
    mov     es:[0x22 + si], cs
    inc     bx
    cmp     bx, 16
    jb      1b
    popf
    pop     es
    ret
isr_remove:
    push    es
    xor     ax, ax
    mov     es, ax
    pushf
    cli
    xor     bx, bx
1:  mov     si, bx
    shl     si, 2
    mov     di, bx
    shl     di, 1
    mov     ax, [isr_tab + di]
    cmp     es:[0x20 + si], ax
    jne     2f
    mov     ax, cs
    cmp     es:[0x22 + si], ax
    jne     2f
    mov     eax, [oldv + si]
    mov     es:[0x20 + si], eax
    jmp     3f
2:  inc     word ptr [isr_stuck]
3:  inc     bx
    cmp     bx, 16
    jb      1b
    popf
    pop     es
    ret

/* ---- transient part --------------------------------------------------------------------- */
main:
    cld
    push    cs
    pop     ds
    push    cs
    pop     es
    cli
    mov     sp, offset stack_top
    sti
    mov     di, offset buf_start
    mov     cx, offset stack_top
    sub     cx, di
    shr     cx, 1
    xor     ax, ax
    rep     stosw
    call    parse
    cmp     byte ptr [opt_q], 0
    je      1f
    xor     ax, ax
    mov     es, ax
    cmp     dword ptr es:[0x60 * 4], 0
    mov     al, 0
    je      0f
    mov     al, 1
0:  mov     ah, 0x4C
    int     0x21
1:  /* shrink to image + buffers + stack */
    mov     bx, offset stack_top
    add     bx, 15
    shr     bx, 4
    mov     ah, 0x4A
    int     0x21
    /* environment */
    in      al, 0x31
    mov     [p31], al
    in      al, 0x02
    mov     [imrm], al
    in      al, 0x0A
    mov     [imrs], al
    xor     ax, ax
    mov     es, ax
    mov     al, es:[0x500]
    mov     [b500], al
    mov     al, es:[0x501]
    mov     [b501], al
    mov     bx, 0xFFFF
    mov     ah, 0x48
    int     0x21
    mov     [freep], bx
    push    cs
    pop     es
    call    calibrate
    /* the vectors as found, and a copy of the whole table (for /B) */
    xor     ax, ax
    mov     ds, ax
    mov     si, 0
    mov     di, offset ivt_save
    mov     cx, 512
    rep     movsw
    push    cs
    pop     ds
    mov     si, offset vlist
    mov     di, offset vecs
2:  lodsb
    cmp     al, 0xFF
    je      3f
    movzx   bx, al
    shl     bx, 2
    mov     eax, [ivt_save + bx]
    stosd
    jmp     2b
3:  /* hooks */
    xor     ax, ax
    mov     es, ax
    cli
    mov     eax, es:[0x18 * 4]
    mov     [old18], eax
    mov     word ptr es:[0x18 * 4], offset hook18
    mov     es:[0x18 * 4 + 2], cs
    mov     al, [opt_b]
    or      al, [opt_p]
    jz      4f
    mov     eax, es:[0x21 * 4]
    mov     [old21], eax
    mov     word ptr es:[0x21 * 4], offset hook21
    mov     es:[0x21 * 4 + 2], cs
    mov     byte ptr [h21], 1
4:  cmp     byte ptr [opt_s], 0
    je      5f
    mov     eax, es:[0x60 * 4]
    mov     [old60], eax
    mov     eax, es:[0x64 * 4]
    mov     [old64], eax
    mov     word ptr es:[0x60 * 4], offset stub60
    mov     es:[0x60 * 4 + 2], cs
    mov     word ptr es:[0x64 * 4], offset stub64
    mov     es:[0x64 * 4 + 2], cs
    mov     byte ptr [h60], 2
    jmp     6f
5:  cmp     byte ptr [opt_b], 0
    jne     6f
    sti
    call    hook6064
6:  sti
    push    cs
    pop     es
    /* /B: the game's shell stops (hlt) unless it gets 0x8480 paragraphs (BOOT.COM 0x1DA-0x1EA);
     * its environment copy comes out of the same block first, so ask for a margin */
    cmp     byte ptr [opt_b], 0
    je      1f
    cmp     word ptr [freep], 0x84C0
    jae     1f
    mov     byte ptr [nomem], 1
    mov     word ptr [exec_ax], 0x0008
    mov     byte ptr [exec_cf], 1
    jmp     7f
1:  mov     byte ptr [active], 1
    /* the run */
    mov     bx, offset exec_t0
    call    stamp_bx
    mov     word ptr [pblock + 2], offset ctail
    mov     [pblock + 4], cs
    mov     [pblock + 8], cs
    mov     [pblock + 12], cs
    mov     [save_sp], sp
    mov     [save_ss], ss
    mov     ax, 0x4B00
    mov     dx, offset child
    mov     bx, offset pblock
    int     0x21
    cli
    mov     ss, cs:[save_ss]
    mov     sp, cs:[save_sp]
    sti
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    mov     [exec_ax], ax
    setc    byte ptr [exec_cf]
    jmp     11f
7:  /* (not run: the hooks are taken down below) */
    jmp     12f
11:
    mov     bx, offset exec_t1
    call    stamp_bx
    mov     byte ptr [active], 0
12: cmp     byte ptr [exec_cf], 0
    jne     7f
    mov     ah, 0x4D
    int     0x21
    mov     [rc], ax
7:  /* /B: vectors the shell left pointing into its own (freed) memory go back */
    cmp     byte ptr [boot_stop], 0
    je      8f
    call    boot_restore
8:  /* stop the music the child started (a later program's first call does the same) */
    call    unhook6064
    cmp     byte ptr [music], 0
    je      9f
    cmp     byte ptr [opt_s], 0
    jne     9f
    xor     ax, ax
    mov     es, ax
    cmp     dword ptr es:[0x60 * 4], 0
    je      9f
    mov     ah, 0x01
    int     0x60
    mov     byte ptr [mstop], 1
9:  push    cs
    pop     es
    call    unhook_main
    call    report
    cmp     word ptr [stuck], 0
    jne     10f
    mov     ax, 0x4C00
    int     0x21
10: mov     dx, offset stack_top
    add     dx, 15
    shr     dx, 4
    mov     ax, 0x3100
    int     0x21

vlist:  .byte 0x08, 0x0A, 0x14, 0x18, 0x21, 0x60, 0x64, 0xFF

/* boot_restore: every vector whose segment is inside the ended shell's block goes back */
boot_restore:
    xor     ax, ax
    mov     es, ax
    xor     si, si
    cli
1:  mov     ax, es:[si + 2]
    cmp     ax, [boot_psp]
    jb      2f
    cmp     ax, [boot_end]
    jae     2f
    mov     eax, [ivt_save + si]
    mov     es:[si], eax
    inc     word ptr [restored]
2:  add     si, 4
    cmp     si, 1024
    jb      1b
    sti
    push    cs
    pop     es
    ret

/* unhook_main: INT 18h and 21h back, where they still point here */
unhook_main:
    xor     ax, ax
    mov     es, ax
    cli
    mov     ax, cs
    cmp     word ptr es:[0x18 * 4], offset hook18
    jne     1f
    cmp     es:[0x18 * 4 + 2], ax
    jne     1f
    mov     eax, [old18]
    mov     es:[0x18 * 4], eax
    jmp     2f
1:  inc     word ptr [stuck]
2:  cmp     byte ptr [h21], 0
    je      4f
    mov     ax, cs
    cmp     word ptr es:[0x21 * 4], offset hook21
    jne     3f
    cmp     es:[0x21 * 4 + 2], ax
    jne     3f
    mov     eax, [old21]
    mov     es:[0x21 * 4], eax
    jmp     4f
3:  inc     word ptr [stuck]
4:  sti
    push    cs
    pop     es
    ret

/* calibrate: a dec/jnz loop and 30 VSYNC periods, in ARTIC ticks */
calibrate:
    cli
    call    artic_read
    mov     ebx, eax
    mov     ecx, 1000000
1:  dec     ecx
    jnz     1b
    call    artic_read
    sti
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    mov     [cal_loop], eax
    /* VSYNC: 0xA0 bit 5; a rising edge, then 30 more; 2 s deadline */
    call    artic_read
    mov     [dl0], eax
    call    vs_rise
    jc      9f
    call    artic_read
    mov     ebx, eax
    mov     cx, 30
2:  call    vs_rise
    jc      9f
    loop    2b
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    mov     [cal_frm], eax
9:  ret
vs_rise:                                  /* wait for 0xA0 bit 5 low then high; CF on timeout */
1:  call    vs_dl
    jc      9f
    in      al, 0xA0
    test    al, 0x20
    jnz     1b
2:  call    vs_dl
    jc      9f
    in      al, 0xA0
    test    al, 0x20
    jz      2b
    clc
9:  ret
vs_dl:
    push    eax
    call    artic_read
    sub     eax, [dl0]
    and     eax, 0x00FFFFFF
    cmp     eax, 614400
    pop     eax
    cmc
    ret
dl0:    .long 0

/* parse: the command tail */
parse:
    mov     si, 0x81
    movzx   cx, byte ptr [0x80]
    add     cx, si
    mov     [tend], cx
p_next:
    call    skipsp
    cmp     si, [tend]
    jae     p_done
    lodsb
    cmp     al, '/'
    jne     p_prog
    lodsb
    and     al, 0xDF
    cmp     al, 'N'
    jne     1f
    mov     byte ptr [opt_n], 1
    jmp     p_next
1:  cmp     al, 'C'
    jne     2f
    mov     byte ptr [opt_c], 1
    jmp     p_next
2:  cmp     al, 'S'
    jne     3f
    mov     byte ptr [opt_s], 1
    jmp     p_next
3:  cmp     al, 'B'
    jne     4f
    mov     byte ptr [opt_b], 1
    jmp     p_next
4:  cmp     al, 'Q'
    jne     44f
    mov     byte ptr [opt_q], 1
    jmp     p_next
44: cmp     al, 'P'
    jne     5f
    mov     byte ptr [opt_p], 1
    jmp     p_next
5:  cmp     al, 'T'
    jne     6f
    mov     di, offset tag
    mov     dx, 8
    jmp     p_word
6:  cmp     al, 'O'
    jne     p_next
    mov     di, offset fname
    mov     dx, 60
p_word:                                   /* /X:word -> DI, at most DX characters */
    cmp     si, [tend]
    jae     p_done
    cmp     byte ptr [si], ':'
    jne     1f
    inc     si
1:  cmp     si, [tend]
    jae     2f
    mov     al, [si]
    cmp     al, ' '
    jbe     2f
    inc     si
    test    dx, dx
    jz      1b
    mov     [di], al
    inc     di
    dec     dx
    jmp     1b
2:  mov     byte ptr [di], 0
    jmp     p_next
p_prog:
    dec     si
    mov     di, offset child
1:  cmp     si, [tend]
    jae     2f
    mov     al, [si]
    cmp     al, ' '
    jbe     2f
    mov     [di], al
    inc     si
    inc     di
    jmp     1b
2:  mov     byte ptr [di], 0
    /* the rest of the tail, as is, becomes the child's tail */
    mov     di, offset ctail + 1
    xor     bx, bx
3:  cmp     si, [tend]
    jae     4f
    cmp     bx, 126
    jae     4f
    mov     al, [si]
    mov     [di], al
    inc     si
    inc     di
    inc     bx
    jmp     3b
4:  mov     byte ptr [di], 13
    mov     [ctail], bl
p_done:
    ret
skipsp:
1:  cmp     si, [tend]
    jae     2f
    cmp     byte ptr [si], ' '
    ja      2f
    inc     si
    jmp     1b
2:  ret
tend:   .word 0

/* ---- the log ---------------------------------------------------------------------------- */
report:
    call    log_open
    mov     di, offset out_buf
    mov     si, offset s_begin
    call    puts
    mov     si, offset tag
    call    puts
    mov     si, offset s_child
    call    puts
    mov     si, offset child
    call    puts
    mov     si, offset s_opt
    call    puts
    mov     al, 'N'
    cmp     byte ptr [opt_n], 0
    je      1f
    stosb
1:  mov     al, 'C'
    cmp     byte ptr [opt_c], 0
    je      1f
    stosb
1:  mov     al, 'S'
    cmp     byte ptr [opt_s], 0
    je      1f
    stosb
1:  mov     al, 'B'
    cmp     byte ptr [opt_b], 0
    je      1f
    stosb
1:  mov     al, 'P'
    cmp     byte ptr [opt_p], 0
    je      1f
    stosb
1:  mov     al, '-'
    stosb
    mov     si, offset s_tail
    call    puts
    movzx   cx, byte ptr [ctail]
    mov     si, offset ctail + 1
    jcxz    2f
1:  lodsb
    cmp     al, ' '
    jae     3f
    mov     al, '_'
3:  stosb
    loop    1b
2:  call    crlf
    /* ENV */
    mov     si, offset s_env
    call    puts
    mov     al, [p31]
    call    hex8
    mov     si, offset s_imr
    call    puts
    mov     al, [imrm]
    call    hex8
    mov     al, '/'
    stosb
    mov     al, [imrs]
    call    hex8
    mov     si, offset s_b500
    call    puts
    mov     al, [b500]
    call    hex8
    mov     si, offset s_b501
    call    puts
    mov     al, [b501]
    call    hex8
    mov     si, offset s_free
    call    puts
    mov     ax, [freep]
    call    hex16
    call    crlf
    /* CAL */
    mov     si, offset s_cal
    call    puts
    mov     eax, [cal_loop]
    call    dec32
    mov     si, offset s_frm
    call    puts
    mov     eax, [cal_frm]
    call    dec32
    call    crlf
    /* VEC */
    mov     si, offset s_vec
    call    puts
    mov     si, offset vlist
    mov     bx, offset vecs
1:  lodsb
    cmp     al, 0xFF
    je      2f
    push    ax
    mov     al, ' '
    stosb
    pop     ax
    call    hex8
    mov     al, '='
    stosb
    mov     ax, [bx + 2]
    call    hex16
    mov     al, ':'
    stosb
    mov     ax, [bx]
    call    hex16
    add     bx, 4
    jmp     1b
2:  call    crlf
    /* EXEC */
    mov     si, offset s_exec
    call    puts
    mov     al, [exec_cf]
    call    hex8
    mov     si, offset s_ax
    call    puts
    mov     ax, [exec_ax]
    call    hex16
    mov     si, offset s_rc
    call    puts
    mov     ax, [rc]
    call    hex16
    mov     si, offset s_t0
    call    puts
    mov     eax, [exec_t0]
    call    hex24
    mov     si, offset s_t1
    call    puts
    mov     eax, [exec_t1]
    call    hex24
    call    crlf
    /* PATCH */
    mov     si, offset s_patch
    call    puts
    mov     al, [patched]
    call    hex8
    mov     si, offset s_cs
    call    puts
    mov     ax, [clab_cs]
    call    hex16
    call    crlf
    /* EV */
    xor     bx, bx
1:  cmp     bx, [ev_n]
    jae     2f
    mov     si, offset s_ev
    call    puts
    mov     al, bl
    call    hex8
    mov     si, offset s_t
    call    puts
    mov     bp, bx
    shl     bp, 4
    add     bp, offset ev_buf
    mov     eax, ds:[bp]
    call    hex24
    mov     si, offset s_cls
    call    puts
    mov     al, ds:[bp + 4]
    call    hex8
    mov     si, offset s_ax
    call    puts
    mov     ax, ds:[bp + 6]
    call    hex16
    mov     si, offset s_name
    call    puts
    mov     cx, 8
    lea     si, [bp + 8]
3:  lodsb
    test    al, al
    jz      4f
    stosb
    loop    3b
4:  call    crlf
    inc     bx
    jmp     1b
2:  /* WIPE */
    cmp     byte ptr [went], 0
    je      w_skip
    mov     si, offset s_wipe
    call    puts
    mov     eax, [w_t0]
    call    hex24
    mov     si, offset s_t1
    call    puts
    mov     eax, [w_t1]
    call    hex24
    mov     si, offset s_flags
    call    puts
    mov     ax, [w_flags]
    call    hex16
    mov     si, offset s_imr
    call    puts
    mov     al, [w_imrm]
    call    hex8
    mov     al, '/'
    stosb
    mov     al, [w_imrs]
    call    hex8
    mov     si, offset s_istuck
    call    puts
    mov     ax, [isr_stuck]
    call    hex16
    call    crlf
    mov     bx, 1
1:  mov     si, offset s_step
    call    puts
    movzx   eax, bx
    call    dec32
    mov     bp, bx
    shl     bp, 4
    add     bp, offset steps_buf
    mov     si, offset s_s
    call    puts
    mov     eax, ds:[bp]
    call    hex24
    mov     si, offset s_f
    call    puts
    mov     eax, ds:[bp + 4]
    call    hex24
    mov     si, offset s_r
    call    puts
    mov     eax, ds:[bp + 8]
    call    hex24
    mov     si, offset s_e
    call    puts
    mov     eax, ds:[bp + 12]
    call    hex24
    call    crlf
    inc     bx
    cmp     bx, 99
    jbe     1b
    xor     bx, bx
2:  mov     eax, [isr_cnt + bx]
    test    eax, eax
    jz      3f
    mov     si, offset s_isr
    call    puts
    mov     ax, bx
    shr     ax, 2
    add     al, 8
    call    hex8
    mov     si, offset s_n
    call    puts
    mov     eax, [isr_cnt + bx]
    call    dec32
    mov     si, offset s_tk
    call    puts
    mov     eax, [isr_tick + bx]
    call    dec32
    call    crlf
3:  add     bx, 4
    cmp     bx, 64
    jb      2b
w_skip:
    /* BOOT / MUSIC / UNHOOK / END */
    mov     si, offset s_boot
    call    puts
    mov     al, [boot_stop]
    call    hex8
    mov     si, offset s_psp
    call    puts
    mov     ax, [boot_psp]
    call    hex16
    mov     si, offset s_end
    call    puts
    mov     ax, [boot_end]
    call    hex16
    mov     si, offset s_rest
    call    puts
    mov     ax, [restored]
    call    hex16
    mov     si, offset s_nomem
    call    puts
    mov     al, [nomem]
    call    hex8
    call    crlf
    mov     si, offset s_music
    call    puts
    mov     al, [music]
    call    hex8
    mov     si, offset s_mstop
    call    puts
    mov     al, [mstop]
    call    hex8
    call    crlf
    mov     si, offset s_oprow
    call    puts
    mov     al, [op_seen]
    call    hex8
    mov     si, offset s_oppat
    call    puts
    mov     al, [op_patch]
    call    hex8
    mov     si, offset s_n1b
    call    puts
    mov     eax, [n1b]
    call    dec32
    mov     si, offset s_t1b
    call    puts
    mov     eax, [t1b]
    call    dec32
    mov     si, offset s_n24
    call    puts
    movzx   eax, word ptr [n24]
    call    dec32
    mov     si, offset s_evn
    call    puts
    movzx   eax, word ptr [ev_n]
    call    dec32
    call    crlf
    mov     si, offset s_unhook
    call    puts
    mov     ax, [stuck]
    call    hex16
    call    crlf
    mov     si, offset s_endl
    call    puts
    call    crlf
    call    flush
    mov     bx, [fh]
    cmp     bx, 0xFFFF
    je      9f
    mov     ah, 0x3E
    int     0x21
    mov     dx, offset s_ok
    cmp     byte ptr [werr], 0
    je      8f
9:  mov     dx, offset s_nolog
8:  mov     ah, 0x09
    int     0x21
    ret

/* log_open: open (or create) the log and seek to its end; fh = 0xFFFF on failure.
 * The log is written in pieces (flush), so the buffer stays small and the shell run (/B)
 * leaves the game's shell the memory it asks for. */
log_open:
    mov     word ptr [fh], 0xFFFF
    mov     ax, 0x3D02
    mov     dx, offset fname
    int     0x21
    jnc     1f
    mov     ah, 0x3C
    xor     cx, cx
    mov     dx, offset fname
    int     0x21
    jc      9f
1:  mov     [fh], ax
    mov     bx, ax
    mov     ax, 0x4202
    xor     cx, cx
    xor     dx, dx
    int     0x21
9:  ret

/* flush: write out_buf..DI to the log; DI = out_buf; every other register kept */
flush:
    pusha
    mov     cx, di
    sub     cx, offset out_buf
    jz      9f
    mov     bx, [fh]
    cmp     bx, 0xFFFF
    je      9f
    mov     ah, 0x40
    mov     dx, offset out_buf
    int     0x21
    jc      8f
    cmp     ax, cx
    je      9f
8:  mov     byte ptr [werr], 1
9:  popa
    mov     di, offset out_buf
    ret
werr:   .byte 0

puts:                                     /* NUL string DS:SI -> ES:DI */
    lodsb
    test    al, al
    jz      1f
    stosb
    jmp     puts
1:  ret
crlf:
    mov     ax, 0x0A0D
    stosw
    cmp     di, offset out_buf + 2048
    jb      1f
    call    flush
1:  ret
hex8:
    push    ax
    shr     al, 4
    call    1f
    pop     ax
    and     al, 0x0F
1:  add     al, '0'
    cmp     al, '9'
    jbe     2f
    add     al, 7
2:  stosb
    ret
hex16:
    push    ax
    mov     al, ah
    call    hex8
    pop     ax
    jmp     hex8
hex24:
    push    eax
    shr     eax, 16
    call    hex8
    pop     eax
    jmp     hex16
dec32:                                    /* EAX unsigned decimal */
    push    ebx
    push    ecx
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
    stosb
    loop    2b
    pop     edx
    pop     ecx
    pop     ebx
    ret

s_begin:  .asciz "RWIPE BEGIN V=2 TAG="
s_child:  .asciz " CHILD="
s_opt:    .asciz " OPT="
s_tail:   .asciz " TAIL="
s_env:    .asciz "RWIPE ENV P31="
s_imr:    .asciz " IMR="
s_b500:   .asciz " B500="
s_b501:   .asciz " B501="
s_free:   .asciz " FREE="
s_cal:    .asciz "RWIPE CAL ARTIC=307200 LOOP1M="
s_frm:    .asciz " FRAME30="
s_vec:    .asciz "RWIPE VEC"
s_exec:   .asciz "RWIPE EXEC CF="
s_ax:     .asciz " AX="
s_rc:     .asciz " RC="
s_t0:     .asciz " T0="
s_t1:     .asciz " T1="
s_t:      .asciz " T="
s_patch:  .asciz "RWIPE PATCH ST="
s_cs:     .asciz " CS="
s_ev:     .asciz "RWIPE EV N="
s_cls:    .asciz " CLS="
s_name:   .asciz " NAME="
s_wipe:   .asciz "RWIPE WIPE T0="
s_flags:  .asciz " FLAGS="
s_istuck: .asciz " ISRSTUCK="
s_step:   .asciz "RWIPE STEP I="
s_s:      .asciz " S="
s_f:      .asciz " F="
s_r:      .asciz " R="
s_e:      .asciz " E="
s_isr:    .asciz "RWIPE ISR V="
s_n:      .asciz " N="
s_tk:     .asciz " TICKS="
s_boot:   .asciz "RWIPE BOOT STOP="
s_psp:    .asciz " PSP="
s_end:    .asciz " END="
s_rest:   .asciz " RESTORED="
s_nomem:  .asciz " NOMEM="
s_music:  .asciz "RWIPE MUSIC SEEN="
s_mstop:  .asciz " STOPPED="
s_oprow:  .asciz "RWIPE OP SEEN="
s_oppat:  .asciz " PATCH="
s_n1b:    .asciz " N1B="
s_t1b:    .asciz " T1B="
s_n24:    .asciz " N24="
s_evn:    .asciz " EVN="
s_unhook: .asciz "RWIPE UNHOOK STUCK="
s_endl:   .asciz "RWIPE END"
s_ok:     .ascii "RWIPE: log written\r\n$"
s_nolog:  .ascii "RWIPE: LOG FILE NOT WRITTEN\r\n$"

    .balign 16
endimg:
/* buffers past the image (zeroed at start; inside the block kept by the shrink) */
    .equ buf_start, endimg
    .equ steps_buf, buf_start               /* 100 x 16: S, F, R, E */
    .equ ev_buf,    steps_buf + 1600        /* 256 x 16 */
    .equ isr_cnt,   ev_buf + 4096           /* 16 x 4 */
    .equ isr_tick,  isr_cnt + 64            /* 16 x 4 */
    .equ ivt_save,  isr_tick + 64           /* 1024 (used before the log is built) */
    .equ out_buf,   ivt_save                /* 3072: flushed every 2048 */
    .equ stack_top, out_buf + 3072 + 1024
