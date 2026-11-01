/* crt31k.s - the PC-9821's 31 kHz dot clock, measured.
 *
 *   CRT31K > CRT31K.TXT          (or RUN31K.BAT)
 *
 * WHY. Port 0x09A8 bit 0 switches a PC-9821's normal-mode display between 24 kHz and
 * 31 kHz. The GDC SYNC parameters for 31 kHz are known (the BIOS's own table; HSB.EXE
 * `IGDC:31` writes the same bytes: master 10 4E 47 0C 07 0D 90 89 = 100 chars x 8 dots =
 * 800 dots a line, 449 lines a frame), but the DOT CLOCK the hardware switches to is not:
 * NP2kai io/gdc.c `gdcclk[]` uses 25 260 000 Hz with the comment that the 31 kHz clock is
 * unknown; VGA 640x400@70 would be 25 175 000 Hz. This probe measures it.
 *
 * METHOD. The master GDC status (port 0x60) bit 5 is VSYNC. For each mode the probe times
 * NFRAMES rising VSYNC edges with the ARTIC counter (0x5C/0x5F, 307200 Hz) under cli, three
 * runs per mode. The decoder (crt31k_decode.py) turns frames/ticks into the frame rate and,
 * with the programmed totals printed beside it, into the line rate and the dot clock:
 *   dot = 307200 * frames / ticks * VTOTAL * HTOTAL_DOTS.
 * The 24 kHz runs come first and check the method itself: they must give ~21 052 600 Hz
 * with the same arithmetic (848 x 440).
 *
 * WHAT IT WRITES, IN ORDER (all restored, then a RESTORE line proves it):
 *   1. 0x09A8 bit 0 <- 1 (31 kHz), exactly as HSB.EXE does (in, or 1, out).
 *   2. The MASTER GDC only (0x62 command / 0x60 parameter): RESET, VSYNC-master,
 *      SYNC(DE=1) <31 kHz table>, PITCH 80, ZOOM 0, SCROLL 00 00 F0 3F - HSB's sequence.
 *      The graphics GDC (slave) is not touched: VSYNC comes from the master, and the
 *      graphics planes are not displayed in a text-mode DOS session.
 *   3. Back to 24 kHz: 0x09A8 <- its as-found value, then the same master sequence with the
 *      BIOS's 24 kHz table (10 4E 07 25 07 07 90 65).
 * The monitor will lose sync while the 31 kHz runs are timed (a few seconds) unless it
 * accepts 31 kHz; that does not affect the measurement. REBOOT AFTER RUNNING: the master
 * GDC is left at the BIOS default 25-line setup, which a resident 30-line driver would not
 * expect.
 *
 * SAFETY. No disk access except DOS stdout. No memory writes outside this program. A VSYNC
 * that does not arrive within ~0.2 s ends that run with `TIMEOUT` (the restore still runs).
 *
 * BUILD: make -C tools/hwprobe crt31k/crt31k.com
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

    .equ    NFRAMES_24, 60
    .equ    NFRAMES_31, 70
    .equ    RUNS, 3
    .equ    EDGE_TIMEOUT, 61440         /* ARTIC ticks: 0.2 s */

_start:
    mov     si, offset msg_begin
    call    puts

    /* as-found 0x09A8 */
    mov     dx, 0x09A8
    in      al, dx
    mov     [p9a8_found], al
    mov     si, offset msg_found
    call    puts
    call    puthex8
    call    crlf

    /* ---- 24 kHz baseline (the machine's current mode, untouched) ---- */
    mov     si, offset msg_mode24
    call    puts
    mov     cx, NFRAMES_24
    call    measure_runs

    /* ---- switch to 31 kHz ---- */
    mov     dx, 0x09A8
    in      al, dx
    or      al, 0x01
    out     dx, al
    call    iowait
    in      al, dx
    mov     [p9a8_31], al
    mov     si, offset msg_set31
    call    puts
    call    puthex8
    call    crlf

    mov     si, offset sync31
    call    gdc_master_program
    call    settle

    mov     si, offset msg_mode31
    call    puts
    mov     cx, NFRAMES_31
    call    measure_runs

    /* ---- restore 24 kHz ---- */
    mov     dx, 0x09A8
    mov     al, [p9a8_found]
    out     dx, al
    call    iowait
    mov     si, offset sync24
    call    gdc_master_program
    call    settle

    mov     si, offset msg_mode24b
    call    puts
    mov     cx, NFRAMES_24
    mov     byte ptr [one_run], 1
    call    measure_runs

    mov     si, offset msg_restore
    call    puts
    mov     al, [p9a8_found]
    call    puthex8
    mov     si, offset msg_now
    call    puts
    mov     dx, 0x09A8
    in      al, dx
    call    puthex8
    call    crlf

    mov     si, offset msg_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* measure_runs: CX = frames per run. Prints RUNS (or 1 if one_run) lines
 * "RUN frames=N ticks=T" or "RUN TIMEOUT". */
measure_runs:
    mov     [nframes], cx
    mov     bx, RUNS
    cmp     byte ptr [one_run], 0
    je      mr_loop
    mov     bx, 1
mr_loop:
    push    bx
    cli
    call    wait_vsync_rise             /* sync to an edge first */
    jc      mr_timeout
    call    artic_read
    mov     [t0], eax
    mov     cx, [nframes]
mr_frames:
    call    wait_vsync_rise
    jc      mr_timeout
    loop    mr_frames
    call    artic_read
    mov     [t1], eax
    sti
    mov     si, offset msg_run
    call    puts
    movzx   eax, word ptr [nframes]
    call    putdec32
    mov     si, offset msg_ticks
    call    puts
    mov     eax, [t1]
    sub     eax, [t0]
    and     eax, 0x00FFFFFF             /* the ARTIC is 24 bits */
    call    putdec32
    call    crlf
    jmp     mr_next
mr_timeout:
    sti
    mov     si, offset msg_timeout
    call    puts
mr_next:
    pop     bx
    dec     bx
    jnz     mr_loop
    ret

/* wait_vsync_rise: wait for master GDC status bit 5 to go 0 then 1. CF=1 on timeout. */
wait_vsync_rise:
    push    eax
    push    ebx
    call    artic_read
    mov     ebx, eax
wv_low:
    in      al, 0x60
    test    al, 0x20
    jz      wv_high
    call    wv_check
    jc      wv_out
    jmp     wv_low
wv_high:
    in      al, 0x60
    test    al, 0x20
    jnz     wv_ok
    call    wv_check
    jc      wv_out
    jmp     wv_high
wv_ok:
    clc
wv_out:
    pop     ebx
    pop     eax
    ret
wv_check:                               /* CF=1 if more than EDGE_TIMEOUT ticks since EBX */
    push    eax
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, EDGE_TIMEOUT
    cmc                                 /* CF=1 when eax >= EDGE_TIMEOUT */
    pop     eax
    ret

/* gdc_master_program: DS:SI = table of {cmd, nparams, params...}, 0xFF ends. */
gdc_master_program:
    cli
gm_next:
    lodsb
    cmp     al, 0xFF
    je      gm_done
    call    gdc_wait_room
    out     0x62, al
    call    iowait
    lodsb
    movzx   cx, al
    jcxz    gm_next
gm_param:
    call    gdc_wait_room
    lodsb
    out     0x60, al
    call    iowait
    loop    gm_param
    jmp     gm_next
gm_done:
    sti
    ret

gdc_wait_room:                          /* wait while the FIFO is full (status bit 1) */
    push    ax
gw_loop:
    in      al, 0x60
    test    al, 0x02
    jnz     gw_loop
    pop     ax
    ret

/* settle: ~0.5 s for the raster to restart after the SYNC change. */
settle:
    push    eax
    push    ebx
    call    artic_read
    mov     ebx, eax
st_loop:
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, 153600
    jb      st_loop
    pop     ebx
    pop     eax
    ret

iowait:
    out     0x5F, al                    /* the PC-98 I/O wait port */
    ret

artic_read:                             /* EAX = 24-bit ARTIC count; EBX/ECX preserved whole */
    /* High byte, low word, high byte again: if the high byte moved, the low word was read
     * at the wrap, and its own value says which side (a small low word belongs to the new
     * high byte). Reading low/high/low instead double-counts a wrap that lands between
     * the first two reads (a +65536 jump, which a later delta sees as a timeout). */
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005f
    in      al, dx
    movzx   ebx, al                     /* H1 */
    mov     dx, 0x005c
    in      ax, dx
    movzx   ecx, ax                     /* L */
    mov     dx, 0x005f
    in      al, dx
    movzx   eax, al                     /* H2 */
    cmp     eax, ebx
    je      ar_same
    cmp     ecx, 0x8000
    jb      ar_use_h2
    mov     eax, ebx                    /* L read before the wrap: H1 */
ar_use_h2:
ar_same:
    shl     eax, 16
    or      eax, ecx
    pop     ecx
    pop     ebx
    pop     dx
    ret

putc:                                   /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret

crlf:
    push    si
    mov     si, offset msg_crlf
    call    puts
    pop     si
    ret

puts:                                   /* DS:SI, NUL terminated */
    push    ax
    push    dx
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
    pop     dx
    pop     ax
    ret

puthex8:                                /* AL */
    push    ax
    push    dx
    push    ax
    shr     al, 4
    call    ph_nib
    pop     ax
    and     al, 0x0F
    call    ph_nib
    pop     dx
    pop     ax
    ret
ph_nib:
    add     al, '0'
    cmp     al, '9'
    jbe     ph_out
    add     al, 'A' - '9' - 1
ph_out:
    mov     dl, al
    call    putc
    ret

putdec32:                               /* EAX unsigned */
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 10
    xor     ecx, ecx
pd_div:
    xor     edx, edx
    div     ebx
    push    dx
    inc     ecx
    test    eax, eax
    jnz     pd_div
pd_out:
    pop     dx
    add     dl, '0'
    call    putc
    dec     ecx
    jnz     pd_out
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* ------------------------------------------------------------------ */
    .balign 4
t0:         .long 0
t1:         .long 0
nframes:    .word 0
one_run:    .byte 0
p9a8_found: .byte 0
p9a8_31:    .byte 0

/* HSB.EXE's master sequence (code image 0x218A / 0x223A); the SYNC bytes equal NP2kai
 * bios/bios18.c gdcmastersync[1] (24) and [2] (31). {cmd, nparams, params...}. */
sync24:
    .byte 0x00, 0
    .byte 0x6F, 0
    .byte 0x0F, 8, 0x10, 0x4E, 0x07, 0x25, 0x07, 0x07, 0x90, 0x65
    .byte 0x47, 1, 0x50
    .byte 0x46, 1, 0x00
    .byte 0x70, 4, 0x00, 0x00, 0xF0, 0x3F
    .byte 0xFF
sync31:
    .byte 0x00, 0
    .byte 0x6F, 0
    .byte 0x0F, 8, 0x10, 0x4E, 0x47, 0x0C, 0x07, 0x0D, 0x90, 0x89
    .byte 0x47, 1, 0x50
    .byte 0x46, 1, 0x00
    .byte 0x70, 4, 0x00, 0x00, 0xF0, 0x3F
    .byte 0xFF

msg_begin:   .asciz "BEGIN:CRT31K artic_hz=307200\r\n"
msg_found:   .asciz "09A8 found="
msg_set31:   .asciz "09A8 after_set31="
msg_mode24:  .asciz "MODE 24K htotal_dots=848 vtotal=440 (as found)\r\n"
msg_mode31:  .asciz "MODE 31K htotal_dots=800 vtotal=449\r\n"
msg_mode24b: .asciz "MODE 24K htotal_dots=848 vtotal=440 (restored)\r\n"
msg_run:     .asciz "RUN frames="
msg_ticks:   .asciz " ticks="
msg_timeout: .asciz "RUN TIMEOUT\r\n"
msg_restore: .asciz "RESTORE 09A8 was="
msg_now:     .asciz " now="
msg_end:     .asciz "END:CRT31K (reboot now)\r\n"
msg_crlf:    .asciz "\r\n"
