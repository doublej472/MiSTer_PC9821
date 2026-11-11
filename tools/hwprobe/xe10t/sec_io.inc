/* sec_io.inc - /IO and /PAL: the cost of one I/O access, port by port.
 *
 * READS ARE LIMITED TO PORTS THE REAL MACHINE HAS ALREADY READ. The first Xe10 run of
 * /ALL (binary 678d4070, 2026-11-01) froze hard in this section: the screen's last case was
 * ALT_, the EGC file's even/odd byte alternation at 0x4A0/0x4A1, and nothing after BEGIN:IO
 * reached the disk (the rows before it were in the 4 KiB buffer, written without a commit).
 * No WATCHDOG followed: a bus cycle that never completes stops the CPU, and no software
 * watchdog (the cooperative one here, or an interrupt-driven one) can run until it does. So
 * every read row below is a port, at the width, that a real-machine capture already read
 * and survived; every row prints a flushed `ROW IO <tag><port> port=<port>` line first, so
 * the last line on disk names the row that hangs. The evidence, per port:
 *   IO.TXT (ioprobe on the Xe10, 1024 byte reads each, cli): 0x5F 0x5C 0x00 0x02 0x08 0x0A
 *     (PIC IRR/IMR) 0x71 0x73 (PIT counters, unlatched: 1024 is even, so the LSB/MSB flip-
 *     flop ends where it began) 0x20 0x22 (calendar) 0x43 (8251 status) 0x60 0x62 0xA0 0xA2
 *     (GDC status / FIFO) 0x6A 0x7C 0xA6 0x4A0 0x4A1 0x4A2 (EGC: an even read takes about
 *     9.3 us there, pit=5BEE per 1024, an odd one the generic 2.3 us; both complete) 0x188
 *     0x18A 0x18C 0x18E (OPNA) 0xA460 (-86 ID) 0x430 0x432 0x433 0x435 (IDE bank) 0x642
 *     0x64C 0x64E 0x74C 0x74E (IDE task file / status, alternate status) 0x90 0x94 (FDC
 *     status, mode) 0x21 (DMA bank) 0x43B 0x43F 0x461 0x463 0x9A0 0xFAA (system);
 *   FDMODE-XE10.TXT: 0xBE (read once: FF); R10.TXT: 0x9A8 (read five times: 00);
 *   word reads: 0x5C (every capture: lib.inc artic_lo reads the ARTIC with `in ax, dx`) and
 *     0x188 (two byte cycles at 0x188/0x189 on the 8-bit OPNA; 0x189 read in PORTS.TXT).
 * Left out, with the reason:
 *   the 0x4A0/0x4A1 alternation (ALT_) and the 16-bit read at 0x4A0 - never done on the
 *     machine, the prime suspect of the freeze;
 *   0x640 word read (IDE data with no DRQ: an ATA device may hold IORDY), 0xA460 word read
 *     (0xA461 never read on the machine), 0xA466/0xA468 (the -86 FIFO status and control:
 *     /PCM86 reads them under its own preconditions);
 *   0x41 (keyboard data: a read can swallow a key), 0x11 (DMA status: a read clears TC),
 *     0x92 (FDC data: only /FDC's result phase reads it), the ATAPI/IDE command ports, the
 *     palette ports (opt-in /PAL).
 *
 * The writes no capture has (0x7E, 0x7C, 0xA4, 0xA6, the PIC EOIs with nothing in service,
 * 0x64, 0x6A, the OPNA address port, the EGC mask with the EGC off) and the two GDCs'
 * command+parameter writes gated on their FIFO (MASK 0x4A FF FF, then the status polled until
 * the FIFO is empty - a bounded in-body poll, reported as to=) follow the reads. Every write
 * value is a documented default or an idempotent value (listed in RESTORE). Each row: 1024
 * accesses (n), its own control.
 *
 * /PAL (opt-in): the digital palette ports 0xA8/0xAA/0xAC/0xAE written with their power-on
 * defaults 37/15/26/04 (so the screen does not change); refused in an analogue mode, where
 * those ports are the index/G/R/B registers.
 */
TPL i_set,      "mov dx, word ptr [cur_port]; mov ax, word ptr [cur_val]"
TPL i_in8,      "in al, dx"
TPL i_out8,     "out dx, al"
TPL i_in16,     "in ax, dx"
TPL i_out16,    "out dx, ax"
TPL i_nil,      ""
TPL i_gdcg,     "mov al, 0x4A; out 0xA2, al; mov al, 0xFF; out 0xA0, al; out 0xA0, al"
TPL i_gdcg_w,   "mov cx, 0xFFFF; 3: in al, 0xA0; test al, 4; jnz 4f; loop 3b; inc word ptr [poll_to]; 4:"
TPL i_gdct,     "mov al, 0x4A; out 0x62, al; mov al, 0xFF; out 0x60, al; out 0x60, al"
TPL i_gdct_w,   "mov cx, 0xFFFF; 3: in al, 0x60; test al, 4; jnz 4f; loop 3b; inc word ptr [poll_to]; 4:"

    .equ IO_R8, 0
    .equ IO_W8, 1
    .equ IO_R16, 2
    .equ IO_W16, 3

/* the four access shapes; the port and value come from [cur_port]/[cur_val] */
io_cases:
    CASE "R8_",  "io",   1024, 128, 8, i_set, i_in8,   i_nil, i_nil
    CASE "W8_",  "io",   1024, 128, 8, i_set, i_out8,  i_nil, i_nil, CF_SWEEP
    CASE "R16_", "io",   1024, 128, 8, i_set, i_in16,  i_nil, i_nil
    CASE "W16_", "io",   1024, 128, 8, i_set, i_out16, i_nil, i_nil
    ENDTAB
tab_gdcw:
    CASE "GDCWMASK_A0", "cmd3", 256, 64, 4, i_nil, i_gdcg, i_gdcg_w, i_nil, CF_POLL
    CASE "GDCWMASK_60", "cmd3", 256, 64, 4, i_nil, i_gdct, i_gdct_w, i_nil, CF_POLL
    ENDTAB
tl_io:      .word io_cases, tab_gdcw, 0
tc_io:      .asciz "R: only ports a machine capture read (IO.TXT, FDMODE, R10); W:5F=00 7E=00 7C=00 A4=00 A6=00 00=20(EOI) 08=20(EOI) 64=00 6A=06 188=30 4A8=FFFF(EGC off) A2/A0,62/60=MASK 4A FF FF"

/* port, op, flags (1 = sweep the write), value; 0xFFFF ends. The reads: see the header
 * for the machine capture each one comes from. */
    .macro IOE port, op, fl=0, val=0
    .word \port
    .byte \op, \fl
    .word \val
    .endm
io_list:
    IOE 0x005F, IO_R8
    IOE 0x005C, IO_R8
    IOE 0x0000, IO_R8
    IOE 0x0002, IO_R8
    IOE 0x0008, IO_R8
    IOE 0x000A, IO_R8
    IOE 0x0071, IO_R8
    IOE 0x0073, IO_R8
    IOE 0x0020, IO_R8
    IOE 0x0022, IO_R8
    IOE 0x0043, IO_R8
    IOE 0x0060, IO_R8
    IOE 0x0062, IO_R8
    IOE 0x00A0, IO_R8
    IOE 0x00A2, IO_R8
    IOE 0x006A, IO_R8
    IOE 0x007C, IO_R8
    IOE 0x00A6, IO_R8
    IOE 0x04A0, IO_R8
    IOE 0x04A1, IO_R8
    IOE 0x04A2, IO_R8
    IOE 0x0188, IO_R8
    IOE 0x018A, IO_R8
    IOE 0x018C, IO_R8
    IOE 0x018E, IO_R8
    IOE 0xA460, IO_R8
    IOE 0x0430, IO_R8
    IOE 0x0432, IO_R8
    IOE 0x0433, IO_R8
    IOE 0x0435, IO_R8
    IOE 0x0642, IO_R8
    IOE 0x064C, IO_R8
    IOE 0x064E, IO_R8
    IOE 0x074C, IO_R8
    IOE 0x074E, IO_R8
    IOE 0x0090, IO_R8
    IOE 0x0094, IO_R8
    IOE 0x00BE, IO_R8
    IOE 0x0021, IO_R8
    IOE 0x043B, IO_R8
    IOE 0x043F, IO_R8
    IOE 0x0461, IO_R8
    IOE 0x0463, IO_R8
    IOE 0x09A0, IO_R8
    IOE 0x09A8, IO_R8
    IOE 0x0FAA, IO_R8
    /* word reads */
    IOE 0x005C, IO_R16
    IOE 0x0188, IO_R16
    /* writes */
    IOE 0x005F, IO_W8, 1, 0x00
    IOE 0x007E, IO_W8, 1, 0x00
    IOE 0x007C, IO_W8, 0, 0x00
    IOE 0x00A4, IO_W8, 0, 0x00
    IOE 0x00A6, IO_W8, 0, 0x00
    IOE 0x0000, IO_W8, 0, 0x20
    IOE 0x0008, IO_W8, 0, 0x20
    IOE 0x0064, IO_W8, 0, 0x00
    IOE 0x006A, IO_W8, 0, 0x06
    IOE 0x0188, IO_W8, 0, 0x30
    IOE 0x04A8, IO_W16, 0, 0xFFFF
    .word 0xFFFF

/* PAL (opt-in): the digital palette defaults */
pal_list:
    .word 0x00A8
    .byte IO_W8, 0
    .word 0x37
    .word 0x00AA
    .byte IO_W8, 0
    .word 0x15
    .word 0x00AC
    .byte IO_W8, 0
    .word 0x26
    .word 0x00AE
    .byte IO_W8, 0
    .word 0x04
    .word 0xFFFF
tl_pal:     .word 0
tc_pal:     .asciz "W:A8=37 AA=15 AC=26 AE=04 (digital palette defaults; refused in analogue mode)"

n_iowrites: .asciz "IOW_DEFAULTS"
n_gdcmask:  .asciz "GDC_MASK"
n_pal:      .asciz "PAL_DIGITAL"
rs_analog:  .asciz "analogue_mode"

/* io_run_list: SI = port list -> one row per entry */
io_run_list:
1:  mov     ax, word ptr [si]
    cmp     ax, 0xFFFF                  /* the end marker (port 0x0000 is a real row) */
    je      9f
    mov     word ptr [cur_port], ax
    mov     ax, word ptr [si+4]
    mov     word ptr [cur_val], ax
    /* the port as the tag suffix */
    push    si
    mov     dword ptr [io_sfx], 0
    mov     byte ptr [io_sfx+4], 0
    mov     dword ptr [tmp_name], 0
    mov     ax, word ptr [cur_port]
    xchg    al, ah
    call    hex2_to_tmp
    xchg    al, ah
    call    hex2_to_tmp
    mov     eax, dword ptr [tmp_name]
    mov     dword ptr [io_sfx], eax
    mov     word ptr [tag_sfx], offset io_sfx
    pop     si
    /* the flushed ROW line first: a hang leaves it as the last line on disk */
    push    si
    mov     ax, word ptr [cur_port]
    movzx   bx, byte ptr [si+2]
    shl     bx, 5
    mov     si, word ptr [io_cases + bx + CD_TAG]
    call    row_mark
    pop     si
2:  movzx   bx, byte ptr [si+2]
    shl     bx, 5                       /* CD_SIZE = 32 */
    add     bx, offset io_cases
    push    si
    mov     si, bx
    test    byte ptr [si+CD_FLAGS], CF_SWEEP
    jz      3f
    pop     si
    push    si
    test    byte ptr [si+3], 1          /* sweep only the flagged writes */
    mov     si, bx
    jnz     3f
    /* a write without a sweep: a one-row copy of the descriptor without CF_SWEEP */
    push    es
    push    cs
    pop     es
    push    di
    push    cx
    mov     di, offset io_desc
    mov     cx, CD_SIZE / 2
    rep     movsw
    pop     cx
    pop     di
    pop     es
    and     word ptr [io_desc+CD_FLAGS], ~CF_SWEEP
    mov     si, offset io_desc
3:  call    run_case
    pop     si
8:  add     si, 6
    jmp     1b
9:  mov     word ptr [tag_sfx], 0
    ret

sec_io:
    mov     si, offset nm_io
    mov     eax, WD_60S
    mov     bx, offset io_exit
    call    sec_begin
    call    gfx_off
    mov     si, offset k_STATE
    call    info_start
    PS      "egc=off grcg=off a6=0 n=1024/row"
    call    out_nl
    mov     si, offset io_list
    call    io_run_list
    mov     word ptr [tag_sfx], 0
    mov     byte ptr [rm_on], 1         /* a flushed ROW line before each GDC case */
    mov     si, offset tab_gdcw
    call    run_list
    mov     byte ptr [rm_on], 0
io_exit:
    call    sec_disarm
    mov     word ptr [tag_sfx], 0
    call    gfx_off
    mov     al, 0
    out     0x7E, al
    out     0x7E, al
    out     0x7E, al
    out     0x7E, al
    out     0xA4, al                    /* display page 0 (the DOS prompt's) */
    mov     dx, 0x4A8
    mov     ax, 0xFFFF
    out     dx, ax
    mov     si, offset n_iowrites
    xor     eax, eax
    call    rs_default
    mov     si, offset n_gdcmask
    mov     eax, 0xFFFF
    call    rs_default
    call    gfx_restore_common
    call    sec_end
    ret

sec_pal:
    mov     si, offset nm_pal
    mov     eax, WD_10S
    mov     bx, offset pal_exit
    call    sec_begin
    mov     al, 0x04
    call    query9a0
    test    al, 1
    jz      1f
    mov     si, offset rs_analog
    call    skip_line
    jmp     pal_end
1:  mov     si, offset pal_list
    call    io_run_list
pal_exit:
    call    sec_disarm
    mov     word ptr [tag_sfx], 0
    mov     al, 0x37
    out     0xA8, al
    mov     al, 0x15
    out     0xAA, al
    mov     al, 0x26
    out     0xAC, al
    mov     al, 0x04
    out     0xAE, al
    mov     si, offset n_pal
    mov     eax, 0x37152604
    push    edx
    push    bx
    push    cx
    mov     edx, eax
    mov     cx, 0x0108
    mov     bl, 2
    call    rs_line
    pop     cx
    pop     bx
    pop     edx
pal_end:
    call    sec_end
    ret

    VARS
io_sfx:     .space 8
    .p2align 1
io_desc:    .space CD_SIZE
    ENDVARS
