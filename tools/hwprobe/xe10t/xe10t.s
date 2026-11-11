/* xe10t.s - XE10T.COM, the unified PC-9821 timing probe (one binary, one harness, one decoder).
 *
 *   XE10T /ALL [/REPS=n] [/QUICK] [/TAG=text] [/O=file]      every media-free section
 *   XE10T /GVRAM /IO ...                                     chosen sections
 *   XE10T /FDC DA=91 /CD                                     the opt-in media sections
 *   XE10T /OPNA2                                             the opt-in sound-chip section
 *   XE10T /RASTER                                            the visual palette-timing picture
 *   XE10T /OPNA3 [/LISTEN]                                   rhythm writes back to back (MDRV2)
 *   XE10T /OPNA3 /SWEEP [/STEP n] [/TO n]                   the rhythm level gap sweep, by ear
 *   XE10T /AUDIT                                             word reads, open ports, IRQ lines
 *   XE10T /FDC2 [DA=90|91]   XE10T /FDC2 /M640               the floppy controller's answers
 *   XE10T /SELFTEST   XE10T /DRY                             internal checks / the plan
 *   XE10T /ALL /SKIP IO   XE10T /ALL /FROM IRQ                 bypass a section / resume
 *
 * WHAT. Every guest-visible timing the core prices (or leaves free) is measured by ONE
 * harness against device clocks, so a capture of this binary on the core and on the
 * Xe10 can be compared row for row (tools/hwprobe/xe10t/README.md; the decoder is
 * xe10t_decode.py). It supersedes gfxbench, gfxbenc2, egcplane, grcgpace, ioprobe, idelat
 * and probe2's timing sections; their captures stay in docs/probes/ as history.
 *
 * THE RULES (the design report's R1-R20, in short):
 *  R1  a posted-capable access is a spacing sweep (0..32 nops after it); the decoder
 *      fits the knee. A net figure is printed only for blocking accesses.
 *  R2  no cost is derived by subtracting another shape's figure.
 *  R3  every row's control is generated from the SAME template with the access bytes
 *      left out (lib.inc gen_code), and both CRCs are printed (shell=, bshell=).
 *  R4  periods are measured edge to edge: t0 on an edge, N whole periods, both stamps.
 *  R5/R6 the PIT is latched; its byte order, modulus and the 0x0501 strap are measured
 *      and printed, raw counts only; ARTIC:PIT is checked in CAL.
 *  R7  every poll loop has an ARTIC deadline and prints TIMEOUT. (Inside a timed body a
 *      timer read would perturb the window, so the few bodies that poll a device bound the
 *      poll by 65535 reads instead, count expiries, and print them as to=.)
 *  R8  one timer library (lib.inc); sections never read a timer themselves.
 *  R9  BEGIN/END with a CRC-16 per section, a CRC-32 over the run; the file is written
 *      and committed after every section; no prompts, no keyboard reads.
 *  R10 /FDC owns the drive state (motor, spin-up by ARTIC, hand-back to the BIOS).
 *  R11 output in device units only (ARTIC ticks, PIT counts); no clk_sys figure.
 *  R12 every memory row stays inside its window (span = n * stride, see each table).
 *  R13 only read-back-proven registers are restored from a read; write-only ones are
 *      restored to a documented default; every restore prints a RESTORE line.
 *  R15 the header carries the build stamp (sha-256 prefix + CRC-32 of the image, written
 *      by the build) and the CRC-32 the program computes over itself at run time.
 *  R16 N repeats (default 5) per row, min/median/max.
 *  R17 each section declares its starting state (STATE lines) and checks preconditions
 *      (V86 mode refused unless /FORCE, sound TSRs refused).
 *  R18 timed windows run under cli.
 *  R20 /SELFTEST runs the arithmetic checks, the generator over every case of every
 *      table, and the harness against a synthetic device (main RAM, port 0x5F).
 *
 * TIME BASES. ARTIC 307200 Hz (3255.208 ns/tick) and PIT ch0 (2.4576 MHz on the 8 MHz-
 * family strap = 8 counts/tick; measured, never assumed). Rows print raw counts.
 *
 * SAFETY. Disk: /IDE issues only READ SECTORS (0x20) of C0/H0/S1..; /CD only TEST UNIT
 * READY, READ(10), READ SUB-CHANNEL, PLAY AUDIO MSF and STOP; /FDC only SENSE, RECALIBRATE,
 * SEEK, READ ID and READ DATA. Nothing writes a disk. GVRAM and PEGC memory are scribbled
 * (no save), TRAM is saved and restored. Every port a section writes is listed by /DRY.
 *
 * BUILD. make -C tools/hwprobe xe10t/xe10t.com (as/ld/objcopy, then xe10t_decode.py
 * --stamp writes the identity block). The image must stay below BSS_BASE (an assembly-time
 * check); buffers live above it in the same 64 KiB segment.
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

/* ---------------------------------------------------------------- layout */
    .equ VERSION,       1
    .equ BSS_BASE,      0xC000          /* the image must end below this */
    .equ OUTBUF,        0xC000          /* 4 KiB output buffer */
    .equ OUTBUF_FLUSH,  0x0F00
    .equ OUTBUF_HARD,   0x0FF0          /* a held buffer (fl_hold) is still written here */
    .equ GEN_BODY,      0xD000          /* generated body (2 KiB, aligned) */
    .equ GEN_CTL,       0xD800          /* generated control */
    .equ GEN_MAX,       0x0800
    .equ A_ART,         0xE000          /* rep arrays: 16 dwords each */
    .equ A_PIT,         0xE040
    .equ A_CART,        0xE080
    .equ A_CPIT,        0xE0C0
    .equ TR_BUF,        0xE100          /* 4 fields x 64 dwords */
    .equ SECBUF,        0xE500          /* 2 KiB section scratch (sector buffer, tags) */
    .equ STACK_TOP,     0xFFFE

    .equ WD_10S,        3072000         /* watchdog budgets, ARTIC ticks */
    .equ WD_20S,        6144000
    .equ WD_60S,        15360000        /* 50 s: a budget must stay below the 24-bit ARTIC wrap (54.6 s) */
    .equ T_1MS,         307
    .equ T_10MS,        3072
    .equ T_100MS,       30720
    .equ T_500MS,       153600
    .equ T_1S,          307200

/* harness descriptor layout and flags (lib.inc), section table */
    .equ CF_SWEEP,   1                  /* nop sweep 0..32 */
    .equ CF_NOCLI,   2                  /* the body needs IF=1 (BIOS/DOS calls) */
    .equ CF_BUF,     4                  /* needs the 256 KiB RAM buffer */
    .equ CF_POLL,    8                  /* the body has a bounded poll: report to= */
    .equ CF_TRAM,    16                 /* needs the TRAM save (buffer) */
    .equ CD_TAG,   0
    .equ CD_UNIT,  2
    .equ CD_N,     4
    .equ CD_ITERS, 8
    .equ CD_UNR,   12
    .equ CD_T,     14                   /* 8 words: setup,setup_e,acc,acc_e,adv,adv_e,post,post_e */
    .equ CD_FLAGS, 30
    .equ CD_SIZE,  32
    .equ TR_MAX, 64
    .equ SECT_SIZE, 10
    .equ ALL_MASK, 0x00003FFC           /* CPU..BIOS; PAL, FDC, CD, OPNA2, RASTER, OPNA3, AUDIT, FDC2 are opt-in */
    .equ NVEC, 9

/* VARS / ENDVARS: mutable data goes to subsection 2, after the constant image, so the
 * run-time image CRC (img_crc) covers exactly the bytes the build stamped (const_end). */
    .macro VARS
    .pushsection .text, 2
    .endm
    .macro ENDVARS
    .popsection
    .endm
    VARS
const_end:
    ENDVARS

/* PS "text": print an inline string to the capture. */
    .macro PS str
    call    out_inline
    .asciz  "\str"
    .endm

/* TPL name, "instr; instr": a code template, the bytes between \name and \name_e. */
    .macro TPL name, text
\name: \text
\name\()_e:
    .endm

/* CASE tag, unit, n, iters, unroll, setup, acc, adv, post, flags: one harness descriptor
 * (lib.inc CD_* layout). n = units per timed window; the loop runs iters x unroll. */
    .macro CASE tag, unit, n, iters, unroll, setup, acc, adv, post, flags=0
    .word   901f
    .word   902f
    .long   \n
    .long   \iters
    .word   \unroll
    .word   \setup, \setup\()_e, \acc, \acc\()_e, \adv, \adv\()_e, \post, \post\()_e
    .word   \flags
    .pushsection .text, 1
901: .asciz "\tag"
902: .asciz "\unit"
    .popsection
    .endm
    .macro ENDTAB
    .word   0
    .endm

/* ======================================================================== start */
_start:
    cld
    mov     sp, STACK_TOP
    push    cs
    pop     ds
    push    cs
    pop     es
    /* zero the buffers above the image */
    mov     di, BSS_BASE
    mov     cx, (0xF000 - BSS_BASE) / 2
    xor     ax, ax
    rep     stosw
    mov     dword ptr [run_crc], 0xFFFFFFFF
    mov     word ptr [out_handle], 1
    mov     word ptr [reps], 5
    mov     dword ptr [pit_mod], 65536

    /* memory: keep 64 KiB, allocate the 256 KiB buffer (128 KiB fallback) */
    mov     bx, 0x1000
    mov     ah, 0x4A
    int     0x21
    mov     bx, 0x4000
    mov     ah, 0x48
    int     0x21
    jnc     1f
    mov     bx, 0x2000
    mov     ah, 0x48
    int     0x21
    jc      2f
1:  mov     word ptr [buf_seg], ax
    mov     word ptr [buf_paras], bx
2:
    call    parse_args
    call    open_out
    call    header

    /* the as-found state every section may disturb, for the final RESTORE */
    call    save_global

    cmp     byte ptr [m_dry], 0
    je      3f
    call    sec_dry
    jmp     run_done
3:  call    sec_id
    cmp     byte ptr [m_selftest], 0
    je      4f
    call    sec_selftest
4:  call    sec_cal
    /* the selected sections, in table order */
    mov     si, offset sec_tab
5:  mov     ax, word ptr [si]
    test    ax, ax
    jz      7f
    mov     cx, word ptr [si+8]         /* bit index */
    mov     eax, 1
    shl     eax, cl
    test    dword ptr [sel_mask], eax
    jz      6f
    push    si
    cmp     byte ptr [v86], 0
    je      55f
    cmp     byte ptr [m_force], 0
    jne     55f
    call    sec_v86skip
    jmp     56f
55: call    word ptr [si+2]
56: pop     si
6:  add     si, SECT_SIZE
    jmp     5b
7:  call    sec_restore
run_done:
    mov     byte ptr [in_sec], 0
    mov     byte ptr [crc_on], 0
    PS      "XE10T DONE sections="
    movzx   eax, word ptr [n_sections]
    call    out_d
    PS      " sum="
    mov     eax, dword ptr [run_crc]
    not     eax
    call    out_x8
    call    out_nl
    call    out_flush
    mov     bx, word ptr [out_handle]
    cmp     bx, 2
    jbe     8f
    mov     ah, 0x3E
    int     0x21
8:  mov     si, offset con_done
    call    con_s
    mov     ax, word ptr [buf_seg]
    test    ax, ax
    jz      9f
    mov     es, ax
    mov     ah, 0x49
    int     0x21
9:  mov     al, byte ptr [run_fault]
    mov     ah, 0x4C
    int     0x21

/* ======================================================================== the section table
 * name, routine, touches (asciz, for /DRY), case-table list, bit index */
sec_tab:
    .word   nm_cpu,   sec_cpu,   tc_cpu,   tl_cpu,   2
    .word   nm_gvram, sec_gvram, tc_gvram, tl_gvram, 3
    .word   nm_grcg,  sec_grcg,  tc_grcg,  tl_grcg,  4
    .word   nm_egc,   sec_egc,   tc_egc,   tl_egc,   5
    .word   nm_pegc,  sec_pegc,  tc_pegc,  tl_pegc,  6
    .word   nm_text,  sec_text,  tc_text,  tl_text,  7
    .word   nm_io,    sec_io,    tc_io,    tl_io,    8
    .word   nm_irq,   sec_irq,   tc_irq,   tl_none,  9
    .word   nm_opna,  sec_opna,  tc_opna,  tl_none,  10
    .word   nm_pcm86, sec_pcm86, tc_pcm86, tl_pcm86, 11
    .ifndef XE10U
    .word   nm_ide,   sec_ide,   tc_ide,   tl_none,  12
    .endif
    .word   nm_bios,  sec_bios,  tc_bios,  tl_bios,  13
    .word   nm_pal,   sec_pal,   tc_pal,   tl_pal,   14
    .ifndef XE10U
    .word   nm_fdc,   sec_fdc,   tc_fdc,   tl_none,  15
    .word   nm_cd,    sec_cd,    tc_cd,    tl_none,  16
    .endif
    .word   nm_opna2, sec_opna2, tc_opna2, tl_none,  17
    .ifndef XE10U
    .word   nm_raster, sec_raster, tc_raster, tl_none, 18
    .endif
    .word   nm_opna3, sec_opna3, tc_opna3, tl_none,  19
    .word   nm_audit, sec_audit, tc_audit, tl_none,  20
    .ifndef XE10U
    .word   nm_fdc2,  sec_fdc2,  tc_fdc2,  tl_none,  21
    .else
    /* XE10U.COM (--defsym XE10U=1): the harness without IDE/FDC/CD/RASTER/FDC2, with /OPNA4
     * (sec_opna4.inc) and /AUDIT2 (sec_audit2.inc); XE10T.COM is built without the symbol and
     * stays byte-identical to the kit-1 binary its /FDC2 captures compare against */
    .word   nm_opna4, sec_opna4, tc_opna4, tl_none,  22
    .word   nm_audit2, sec_audit2, tc_audit2, tl_none, 23
    .endif
    .word   0

tl_none: .word 0

/* keyword table: name, kind, arg.  kind 0 = section bit, 1 = /ALL, 2 = mode byte,
 * 3 = value key (arg = handler) */
kw_tab:
    .word   kw_all, 1, 0
    .word   kw_cpu, 0, 2
    .word   kw_gvram, 0, 3
    .word   kw_grcg, 0, 4
    .word   kw_egc, 0, 5
    .word   kw_pegc, 0, 6
    .word   kw_text, 0, 7
    .word   kw_io, 0, 8
    .word   kw_irq, 0, 9
    .word   kw_opna, 0, 10
    .word   kw_pcm86, 0, 11
    .word   kw_ide, 0, 12
    .word   kw_bios, 0, 13
    .word   kw_pal, 0, 14
    .word   kw_fdc, 0, 15
    .word   kw_cd, 0, 16
    .word   kw_opna2, 0, 17
    .word   kw_raster, 0, 18
    .word   kw_opna3, 0, 19
    .word   kw_audit, 0, 20
    .ifndef XE10U
    .word   kw_fdc2, 0, 21
    .word   kw_m640, 2, m_m640
    .else
    .word   kw_opna4, 0, 22
    .word   kw_audit2, 0, 23
    .endif
    .word   kw_id, 2, m_dummy
    .word   kw_cal, 2, m_dummy
    .word   kw_selftest, 2, m_selftest
    .word   kw_dry, 2, m_dry
    .word   kw_quick, 2, m_quick
    .word   kw_force, 2, m_force
    .word   kw_listen, 2, m_listen
    .word   kw_sweep, 2, m_sweep
    .word   kw_reps, 3, v_reps
    .word   kw_o, 3, v_out
    .word   kw_tag, 3, v_tag
    .word   kw_da, 3, v_da
    .word   kw_skip, 3, v_skip
    .word   kw_from, 3, v_from
    .word   kw_step, 3, v_step
    .word   kw_to, 3, v_to
    .word   0

/* ======================================================================== arguments */
/* parse_args: the PSP command tail -> args_raw (verbatim), args_up (upper case). */
parse_args:
    mov     si, 0x81
    movzx   cx, byte ptr [0x80]
    cmp     cx, 126
    jbe     1f
    mov     cx, 126
1:  mov     di, offset args_raw
    mov     bx, offset args_up
2:  jcxz    4f
    lodsb
    cmp     al, 13
    je      4f
    mov     byte ptr [di], al
    inc     di
    cmp     al, 'a'
    jb      3f
    cmp     al, 'z'
    ja      3f
    sub     al, 0x20
3:  mov     byte ptr [bx], al
    inc     bx
    dec     cx
    jmp     2b
4:  mov     byte ptr [di], 0
    mov     byte ptr [bx], 0
    /* tokens */
    mov     si, offset args_up
pa_next:
    call    pa_skipdelim
    cmp     byte ptr [si], 0
    je      pa_done
    /* DAxx (no separator): COMMAND.COM splits batch arguments at '=' */
    mov     di, offset tok
    xor     cx, cx
5:  mov     al, byte ptr [si]
    call    pa_isdelim
    je      6f
    cmp     al, '='
    je      6f
    cmp     al, ':'
    je      6f
    cmp     cx, 15
    jae     55f
    mov     byte ptr [di], al
    inc     di
    inc     cx
55: inc     si
    jmp     5b
6:  mov     byte ptr [di], 0
    mov     word ptr [val_ptr], 0
    mov     byte ptr [val_tok], 0
    cmp     al, '='
    je      7f
    cmp     al, ':'
    jne     8f
7:  inc     si
    mov     word ptr [val_ptr], si
8:  /* DA91 form */
    cmp     word ptr [tok], 0x4144      /* "DA" */
    jne     9f
    cmp     byte ptr [tok+2], 0
    je      9f
    push    si
    mov     si, offset tok+2
    call    v_da                        /* the value is in the token itself */
    pop     si
    mov     byte ptr [tok+2], 0
    jmp     pa_skipval
9:  mov     bx, offset kw_tab
10: mov     di, word ptr [bx]
    test    di, di
    jz      pa_unknown
    push    si
    mov     si, offset tok
    call    str_eq
    pop     si
    je      11f
    add     bx, 6
    jmp     10b
11: mov     ax, word ptr [bx+2]
    mov     dx, word ptr [bx+4]
    cmp     ax, 0
    jne     12f
    mov     cx, dx
    mov     eax, 1
    shl     eax, cl
    or      dword ptr [sel_mask], eax
    jmp     pa_skipval
12: cmp     ax, 1
    jne     13f
    or      dword ptr [sel_mask], ALL_MASK
    jmp     pa_skipval
13: cmp     ax, 2
    jne     14f
    mov     di, dx
    mov     byte ptr [di], 1
    jmp     pa_skipval
14: /* a value key: the value is after '='/':' or the next token */
    cmp     word ptr [val_ptr], 0
    jne     15f
    call    pa_skipdelim_noslash
    mov     word ptr [val_ptr], si
15: push    si
    mov     si, word ptr [val_ptr]
    call    dx
    pop     si
    cmp     word ptr [val_ptr], si
    jb      pa_skipval
    mov     si, word ptr [val_ptr]
pa_skipval:
    /* skip to the next delimiter */
16: mov     al, byte ptr [si]
    test    al, al
    jz      pa_next
    call    pa_isdelim
    je      pa_next
    inc     si
    jmp     16b
pa_unknown:
    mov     byte ptr [bad_arg], 1
    jmp     pa_skipval
pa_done:
    cmp     byte ptr [m_quick], 0
    je      1f
    mov     word ptr [reps], 3
1:  cmp     byte ptr [m_sweep], 0       /* /SWEEP is /OPNA3's: it selects the section */
    je      11f
    or      dword ptr [sel_mask], 1 << 19
11:  /* /SKIP and /FROM act on the final selection (ID and CAL always run) */
    mov     eax, dword ptr [skip_mask]
    not     eax
    and     dword ptr [sel_mask], eax
    movzx   cx, byte ptr [from_bit]
    jcxz    2f
    mov     eax, 1
    shl     eax, cl
    dec     eax                         /* the sections before it in table (= bit) order */
    not     eax
    and     dword ptr [sel_mask], eax
2:  ret

pa_isdelim:                             /* ZF = AL is a separator */
    cmp     al, ' '
    je      1f
    cmp     al, 9
    je      1f
    cmp     al, '/'
    je      1f
    cmp     al, ','
    je      1f
    cmp     al, 0
1:  ret
pa_skipdelim:
1:  mov     al, byte ptr [si]
    test    al, al
    jz      2f
    call    pa_isdelim
    jne     2f
    inc     si
    jmp     1b
2:  ret
pa_skipdelim_noslash:
1:  mov     al, byte ptr [si]
    cmp     al, ' '
    je      3f
    cmp     al, 9
    je      3f
    cmp     al, ','
    je      3f
    ret
3:  inc     si
    jmp     1b

/* value handlers: SI = value text in args_up; advance [val_ptr] past the value */
pa_valcopy:                             /* DI = dest (max 15 chars) from the RAW tail */
    push    si
    push    cx
    mov     ax, si
    sub     ax, offset args_up
    mov     bx, offset args_raw
    add     bx, ax
    xor     cx, cx
1:  mov     al, byte ptr [si]
    test    al, al
    jz      2f
    call    pa_isdelim
    je      2f
    cmp     cx, 15
    jae     11f
    mov     al, byte ptr [bx]
    mov     byte ptr [di], al
    inc     di
    inc     cx
11: inc     si
    inc     bx
    jmp     1b
2:  mov     byte ptr [di], 0
    mov     word ptr [val_ptr], si
    pop     cx
    pop     si
    ret
v_out:
    mov     di, offset out_name
    jmp     pa_valcopy
v_tag:
    mov     di, offset tag_txt
    jmp     pa_valcopy
v_reps:
    call    pa_num
    cmp     ax, 3
    jae     3f
    mov     ax, 3
3:  cmp     ax, 15
    jbe     4f
    mov     ax, 15
4:  mov     word ptr [reps_arg], ax
    ret
/* pa_num: SI = decimal text -> AX (the digits' value), [val_ptr] past them */
pa_num:
    xor     ax, ax
1:  mov     dl, byte ptr [si]
    sub     dl, '0'
    cmp     dl, 9
    ja      2f
    imul    ax, ax, 10
    movzx   dx, dl
    add     ax, dx
    inc     si
    jmp     1b
2:  mov     word ptr [val_ptr], si
    ret
/* v_step / v_to: /OPNA3 /SWEEP's first and last step (1-based; checked by the section) */
v_step:
    call    pa_num
    mov     word ptr [o3_from], ax
    ret
v_to:
    call    pa_num
    mov     word ptr [o3_to], ax
    ret
/* v_skip / v_from: the value is a section keyword (CPU..CD, an optional leading '/'):
 * /SKIP <SEC> leaves that section out (repeatable); /FROM <SEC> leaves out every section
 * before it in table order, to resume a run past a section that hung. */
v_skip:
    call    v_secbit
    jc      1f
    mov     eax, 1
    shl     eax, cl
    or      dword ptr [skip_mask], eax
1:  ret
v_from:
    call    v_secbit
    jc      1f
    mov     byte ptr [from_bit], cl
1:  ret
/* v_secbit: SI = value text -> CL = the section's bit, CF = 1 (and bad_arg) when unknown */
v_secbit:
    push    bx
    push    di
    cmp     byte ptr [si], '/'
    jne     1f
    inc     si
1:  mov     di, offset tok2
    xor     cx, cx
2:  mov     al, byte ptr [si]
    call    pa_isdelim
    je      3f
    cmp     cx, 15
    jae     21f
    mov     byte ptr [di], al
    inc     di
    inc     cx
21: inc     si
    jmp     2b
3:  mov     byte ptr [di], 0
    mov     word ptr [val_ptr], si
    mov     bx, offset kw_tab
4:  mov     di, word ptr [bx]
    test    di, di
    jz      6f
    cmp     word ptr [bx+2], 0          /* section keywords only */
    jne     5f
    push    si
    mov     si, offset tok2
    call    str_eq
    pop     si
    je      7f
5:  add     bx, 6
    jmp     4b
6:  mov     byte ptr [bad_arg], 1
    stc
    jmp     8f
7:  mov     cx, word ptr [bx+4]
    clc
8:  pop     di
    pop     bx
    ret
v_da:
    xor     ax, ax
    mov     cx, 2
1:  mov     dl, byte ptr [si]
    sub     dl, '0'
    cmp     dl, 9
    jbe     2f
    sub     dl, 7
    cmp     dl, 15
    ja      3f
2:  shl     al, 4
    or      al, dl
    inc     si
    loop    1b
3:  mov     byte ptr [da_arg], al
    mov     word ptr [val_ptr], si
    ret

/* str_eq: ZF = asciz SI equals asciz DI */
str_eq:
    push    si
    push    di
    push    ax
1:  mov     al, byte ptr [si]
    cmp     al, byte ptr [di]
    jne     2f
    test    al, al
    jz      2f
    inc     si
    inc     di
    jmp     1b
2:  pop     ax
    pop     di
    pop     si
    ret

/* ======================================================================== output file */
open_out:
    cmp     word ptr [reps_arg], 0
    je      1f
    mov     ax, word ptr [reps_arg]
    mov     word ptr [reps], ax
1:  mov     dx, offset out_name
    cmp     byte ptr [out_name], 0
    jne     2f
    mov     dx, offset def_out
2:  xor     cx, cx
    mov     ah, 0x3C
    int     0x21
    jc      3f
    mov     word ptr [out_handle], ax
    ret
3:  mov     word ptr [out_handle], 1    /* fall back to stdout */
    ret

/* header: the run identity line (R15). */
header:
    mov     byte ptr [crc_on], 1
    PS      "XE10T v"
    mov     eax, VERSION
    call    out_d
    PS      " sha="
    mov     si, offset stamp_sha
    mov     cx, 16
    call    out_n
    PS      " crc="
    mov     si, offset stamp_crc
    mov     cx, 8
    call    out_n
    PS      " imgcrc="
    call    img_crc
    call    out_x8
    PS      " size="
    mov     eax, offset img_end - 0x100
    call    out_d
    .ifndef XE10U
    PS      " build=gas-xe10t args="
    .else
    PS      " build=gas-xe10u args="
    .endif
    mov     si, offset args_raw
    call    out_s
    PS      " tag="
    mov     si, offset tag_txt
    cmp     byte ptr [si], 0
    jne     1f
    mov     si, offset dash
1:  call    out_s
    call    out_nl
    cmp     dword ptr [sel_mask], 0
    jne     3f
    cmp     byte ptr [m_selftest], 0
    jne     3f
    cmp     byte ptr [m_dry], 0
    jne     3f
    mov     si, offset con_usage
    call    con_s
3:  call    out_flush
    ret

out_n:                                  /* CX chars from SI */
    push    ax
    push    si
1:  lodsb
    call    out_c
    loop    1b
    pop     si
    pop     ax
    ret

/* img_crc: EAX = CRC-32 of the image 0x100..img_end with the stamp's 24 digit bytes
 * counted as ASCII '0' (the build's "zeroed" image). */
img_crc:
    push    ebx
    push    ecx
    push    edx
    push    si
    push    dword ptr [run_crc]
    mov     dword ptr [run_crc], 0xFFFFFFFF
    mov     si, 0x100
1:  cmp     si, offset const_end
    jae     3f
    mov     al, byte ptr [si]
    cmp     si, offset stamp_sha
    jb      2f
    cmp     si, offset stamp_end
    jae     2f
    mov     al, '0'
2:  call    crc32_step
    inc     si
    jmp     1b
3:  mov     eax, dword ptr [run_crc]
    not     eax
    pop     dword ptr [run_crc]
    pop     si
    pop     edx
    pop     ecx
    pop     ebx
    ret

sec_v86skip:                            /* SI = the section table entry */
    push    si
    mov     si, word ptr [si]
    mov     eax, WD_10S
    mov     bx, offset v86_exit
    call    sec_begin
    mov     si, offset rs_v86
    call    skip_line
v86_exit:
    call    sec_disarm
    call    sec_end
    pop     si
    ret

/* ======================================================================== global state */
vec_list:   .byte 0x08, 0x0A, 0x0B, 0x0C, 0x11, 0x12, 0x13, 0x14, 0x1C
q_list:     .byte 0x04, 0x07, 0x08, 0x0A

save_global:
    push    es
    xor     ax, ax
    mov     es, ax
    xor     bx, bx
    mov     di, offset vec_save
1:  movzx   si, byte ptr [vec_list + bx]
    shl     si, 2
    mov     eax, dword ptr es:[si]
    mov     dword ptr [di], eax
    add     di, 4
    inc     bx
    cmp     bx, NVEC
    jb      1b
    pop     es
    in      al, 0x02
    mov     byte ptr [imr_m_save], al
    in      al, 0x0A
    mov     byte ptr [imr_s_save], al
    xor     bx, bx
2:  mov     al, byte ptr [q_list + bx]
    call    query9a0
    mov     byte ptr [q_save + bx], al
    inc     bx
    cmp     bx, 4
    jb      2b
    ret

/* query9a0: AL = index -> AL = the 0x9A0 mode query byte (bit 0 is the mode bit). */
query9a0:
    push    dx
    mov     dx, 0x09A0
    out     dx, al
    out     0x5F, al
    in      al, dx
    pop     dx
    ret

/* ======================================================================== ID */
sec_id:
    mov     si, offset nm_id
    mov     eax, WD_10S
    mov     bx, offset id_exit
    call    sec_begin
    /* CPUID (guarded by the EFLAGS.ID toggle) */
    pushfd
    pop     eax
    mov     ecx, eax
    xor     eax, 0x00200000
    push    eax
    popfd
    pushfd
    pop     eax
    push    ecx
    popfd
    xor     eax, ecx
    and     eax, 0x00200000
    mov     ebx, eax
    mov     si, offset k_I
    call    info_start
    test    ebx, ebx
    jz      1f
    mov     byte ptr [has_cpuid], 1
    PS      "cpuid=1 vendor="
    xor     eax, eax
    cpuid
    mov     dword ptr [cpu_max], eax
    mov     dword ptr [vend], ebx
    mov     dword ptr [vend+4], edx
    mov     dword ptr [vend+8], ecx
    mov     si, offset vend
    mov     cx, 12
    call    out_n
    mov     eax, dword ptr [cpu_max]
    mov     si, offset k_max
    call    out_kd
    cmp     dword ptr [cpu_max], 1
    jb      2f
    mov     eax, 1
    cpuid
    mov     dword ptr [cpu_feat], edx
    PS      " sig="
    call    out_x8
    PS      " ebx="
    mov     eax, ebx
    call    out_x8
    PS      " ecx="
    mov     eax, ecx
    call    out_x8
    PS      " edx="
    mov     eax, edx
    call    out_x8
    test    edx, 0x10
    jz      2f
    mov     byte ptr [has_tsc], 1
    PS      " tsc=1"
    jmp     2f
1:  PS      "cpuid=0"
2:  call    out_nl
    /* MSW / CR0 and V86 */
    mov     si, offset k_I
    call    info_start
    smsw    ax
    PS      "msw="
    call    out_x4
    test    al, 1
    jz      3f
    mov     byte ptr [v86], 1
    PS      " v86=1"
    jmp     4f
3:  mov     eax, cr0
    PS      " cr0="
    call    out_x8
    PS      " v86=0"
4:  call    out_nl
    /* BIOS identification bytes F000:FFF0..FFFF and the date text at FFF5 */
    mov     si, offset k_I
    call    info_start
    PS      "bios_fff0="
    push    es
    mov     ax, 0xF000
    mov     es, ax
    mov     si, 0xFFF0
    mov     cx, 16
5:  mov     al, byte ptr es:[si]
    inc     si
    call    out_x2
    loop    5b
    PS      " bios_date="
    mov     si, 0xFFF5
    mov     cx, 8
6:  mov     al, byte ptr es:[si]
    inc     si
    cmp     al, 0x21
    jb      7f
    cmp     al, 0x7E
    jbe     8f
7:  mov     al, '.'
8:  call    out_c
    loop    6b
    pop     es
    call    out_nl
    /* machine-ID port 0xF0 (READ only - a write resets the CPU), the BDA */
    mov     si, offset k_I
    call    info_start
    in      al, 0xF0
    PS      "port_f0="
    call    out_x2
    push    es
    xor     ax, ax
    mov     es, ax
    mov     bx, offset bda_list
9:  mov     di, word ptr [bx]
    test    di, di
    jz      10f
    PS      " bda"
    mov     ax, di
    call    out_x4
    mov     al, '='
    call    out_c
    mov     al, byte ptr es:[di]
    call    out_x2
    add     bx, 2
    jmp     9b
10: pop     es
    call    out_nl
    /* DOS, memory, the buffer, the selection */
    mov     si, offset k_I
    call    info_start
    mov     ah, 0x30
    int     0x21
    movzx   ebx, ah
    PS      "dos="
    movzx   eax, al
    call    out_d
    mov     al, '.'
    call    out_c
    mov     eax, ebx
    call    out_d
    PS      " bufseg="
    mov     ax, word ptr [buf_seg]
    call    out_x4
    PS      " bufparas="
    mov     ax, word ptr [buf_paras]
    call    out_x4
    PS      " sel="
    mov     eax, dword ptr [sel_mask]
    call    out_x8
    movzx   eax, word ptr [reps]
    mov     si, offset k_rep
    call    out_kd
    movzx   eax, byte ptr [da_arg]
    PS      " da="
    call    out_x2
    movzx   eax, byte ptr [bad_arg]
    PS      " unknown_args="
    call    out_d
    call    out_nl
    /* the global as-found state (the final RESTORE compares against it) */
    mov     si, offset k_STATE
    call    info_start
    PS      "imr_m="
    mov     al, byte ptr [imr_m_save]
    call    out_x2
    PS      " imr_s="
    mov     al, byte ptr [imr_s_save]
    call    out_x2
    in      al, 0x6A
    PS      " p6a="
    call    out_x2
    xor     bx, bx
11: PS      " q"
    mov     al, byte ptr [q_list + bx]
    call    out_x2
    mov     al, '='
    call    out_c
    mov     al, byte ptr [q_save + bx]
    call    out_x2
    inc     bx
    cmp     bx, 4
    jb      11b
    call    out_nl
id_exit:
    call    sec_disarm
    call    sec_end
    ret

bda_list:   .word 0x0401, 0x0458, 0x045C, 0x0480, 0x0481, 0x0500, 0x0501, 0x053C, 0x054C, 0x054D, 0x0594, 0x0595, 0

/* ======================================================================== CAL */
/* The trust gate (always run, read-only): PIT byte order, rate against the ARTIC in
 * windows started just after a reload edge (R4) and the reload period over 0.5 s (so the
 * modulus is measured, R6), the 0x0501 strap, VSYNC over 60 edge-to-edge frames against
 * ARTIC, PIT (unwrapped poll by poll) and the TSC, and the TSC rate. */
sec_cal:
    mov     si, offset nm_cal
    mov     eax, WD_10S
    mov     bx, offset cal_exit
    call    sec_begin
    call    pit_cal
    push    es
    xor     ax, ax
    mov     es, ax
    mov     al, byte ptr es:[0x0501]
    mov     byte ptr [strap0501], al
    pop     es
    mov     si, offset k_I
    call    info_start
    PS      "pit_order="
    movzx   eax, byte ptr [pit_swap]
    call    out_d
    PS      " strap0501="
    mov     al, byte ptr [strap0501]
    call    out_x2
    call    out_nl
    cmp     byte ptr [artic_dead], 0
    je      1f
    mov     si, offset rs_artic
    call    skip_line
    jmp     cal_verdict
1:  /* -------- PITWIN x8 -------- */
    mov     dword ptr [c_sum_pit], 0
    mov     dword ptr [c_sum_art], 0
    xor     cx, cx
cal_win:
    cli
    mov     eax, T_100MS
    call    dl_start
    call    pit_wait_reload             /* AX = count just after a reload, CF = timeout */
    jc      cal_win_to
    call    artic_sync
    mov     dword ptr [c_a0], eax
    call    pit_read
    movzx   ebx, ax                     /* p0 */
    mov     edx, ebx
    shr     edx, 2                      /* stop below p0/4 */
2:  call    dl_check
    jc      cal_win_to
    call    pit_read
    cmp     ax, bx
    ja      cal_win_to                  /* wrapped: a reload came first */
    cmp     ax, dx
    ja      2b
    call    artic_sync
    push    eax
    call    pit_read
    movzx   edx, ax
    pop     eax
    sti
    sub     eax, dword ptr [c_a0]
    and     eax, 0xFFFFFF
    cmp     edx, ebx
    ja      cal_win_to
    push    eax
    mov     eax, ebx
    sub     eax, edx                    /* pit */
    add     dword ptr [c_sum_pit], eax
    mov     edx, eax
    pop     eax
    add     dword ptr [c_sum_art], eax
    push    si
    mov     si, offset k_P
    call    row_start
    PS      "PITWIN i="
    push    eax
    movzx   eax, cx
    call    out_d
    pop     eax
    PS      " art="
    call    out_d
    PS      " pit="
    mov     eax, edx
    call    out_d
    call    out_nl
    pop     si
    inc     cx
    cmp     cx, 8
    jb      cal_win
    jmp     cal_edge
cal_win_to:
    sti
    mov     si, offset to_pitwin
    call    timeout_line
cal_edge:
    /* -------- PITEDGE: reload edges over 0.5 s -------- */
    mov     word ptr [c_edges], 0
    mov     word ptr [c_vmax], 0
    mov     word ptr [c_vmin], 0xFFFF
    cli
    mov     eax, T_500MS + T_100MS
    call    dl_start
    call    pit_read
    mov     bx, ax
3:  call    dl_check
    jc      5f
    call    pit_read
    cmp     ax, word ptr [c_vmax]
    jbe     31f
    mov     word ptr [c_vmax], ax
31: cmp     ax, word ptr [c_vmin]
    jae     32f
    mov     word ptr [c_vmin], ax
32: cmp     ax, bx
    mov     bx, ax
    jbe     3b
    /* a reload edge */
    call    artic_read
    cmp     word ptr [c_edges], 0
    jne     4f
    mov     dword ptr [c_e0], eax
4:  mov     dword ptr [c_e1], eax
    inc     word ptr [c_edges]
    sub     eax, dword ptr [c_e0]
    and     eax, 0xFFFFFF
    cmp     eax, T_500MS
    jb      3b
5:  sti
    mov     si, offset k_P
    call    row_start
    PS      "PITEDGE edges="
    movzx   eax, word ptr [c_edges]
    dec     ax
    jns     6f
    xor     ax, ax
6:  mov     word ptr [c_periods], ax
    call    out_d
    PS      " art="
    mov     eax, dword ptr [c_e1]
    sub     eax, dword ptr [c_e0]
    and     eax, 0xFFFFFF
    mov     dword ptr [c_espan], eax
    call    out_d
    PS      " vmax="
    movzx   eax, word ptr [c_vmax]
    call    out_d
    PS      " vmin="
    movzx   eax, word ptr [c_vmin]
    call    out_d
    call    out_nl
    /* pit_mod = sum_pit * espan / (sum_art * periods), rounded; else 65536 */
    cmp     word ptr [c_periods], 1
    jb      7f
    cmp     dword ptr [c_sum_art], 0
    je      7f
    mov     eax, dword ptr [c_sum_art]
    movzx   ecx, word ptr [c_periods]
    mul     ecx
    mov     ecx, eax                    /* divisor (fits: art sum < 2^20, periods < 2^9) */
    mov     eax, dword ptr [c_sum_pit]
    mul     dword ptr [c_espan]
    mov     ebx, ecx
    shr     ebx, 1
    add     eax, ebx
    adc     edx, 0
    cmp     edx, ecx
    jae     7f
    div     ecx
    cmp     eax, 256
    jb      7f
    cmp     eax, 65536 + 64             /* a free-running counter rounds to 65536 +- a few */
    ja      7f
    cmp     eax, 65536 - 64
    jb      71f
    mov     eax, 65536                  /* within 64: the 16-bit wrap itself */
71:
    mov     dword ptr [pit_mod], eax
    mov     byte ptr [pit_mod_ok], 1
7:  /* ratio x1000 */
    mov     dword ptr [c_ratio], 0
    cmp     dword ptr [c_sum_art], 0
    je      8f
    mov     eax, dword ptr [c_sum_pit]
    mov     ecx, 1000
    mul     ecx
    div     dword ptr [c_sum_art]
    mov     dword ptr [c_ratio], eax
8:  call    cal_vsync
    cmp     byte ptr [has_tsc], 0
    je      cal_verdict
    call    cal_tsc
cal_verdict:
    mov     si, offset k_I
    call    info_start
    PS      "pit_mod="
    cmp     byte ptr [pit_mod_ok], 0
    jne     1f
    PS      "-"
    jmp     2f
1:  mov     eax, dword ptr [pit_mod]
    call    out_d
2:  mov     eax, dword ptr [c_ratio]
    mov     si, offset k_ratio
    call    out_kd
    mov     eax, dword ptr [c_vsx10]
    mov     si, offset k_vsync
    call    out_kd
    PS      " tsc_khz="
    cmp     dword ptr [c_tsckhz], 0
    jne     3f
    PS      "-"
    jmp     4f
3:  mov     eax, dword ptr [c_tsckhz]
    call    out_d
4:  /* verdict: ratio 8000 +- 8, vsync 54450 +- 20 */
    mov     si, offset w_ratio
    mov     eax, dword ptr [c_ratio]
    sub     eax, 8000
    jns     5f
    neg     eax
5:  cmp     eax, 8
    ja      6f
    mov     si, offset w_vsync
    mov     eax, dword ptr [c_vsx10]
    sub     eax, 54450
    jns     55f
    neg     eax
55: cmp     eax, 20
    ja      6f
    PS      " verdict=OK why=-"
    mov     byte ptr [cal_ok], 1
    jmp     7f
6:  PS      " verdict=FAIL why="
    call    out_s
7:  call    out_nl
cal_exit:
    call    sec_disarm
    call    sec_end
    ret

/* pit_wait_reload: wait until the PIT count goes UP (a reload); AX = the count after it.
 * CF = 1 on the deadline. Caller has called dl_start. */
pit_wait_reload:
    push    bx
    call    pit_read
    mov     bx, ax
1:  call    dl_check
    jc      2f
    call    pit_read
    cmp     ax, bx
    mov     bx, ax
    jbe     1b
    clc
2:  pop     bx
    ret

/* cal_vsync: 60 frames, master GDC status 0x60 bit 5, rising edge to rising edge. */
cal_vsync:
    cli
    mov     eax, T_100MS
    call    dl_start
1:  call    dl_check                    /* wait for VSYNC low */
    jc      9f
    in      al, 0x60
    test    al, 0x20
    jnz     1b
2:  call    dl_check                    /* then the rising edge */
    jc      9f
    in      al, 0x60
    test    al, 0x20
    jz      2b
    call    artic_read
    mov     dword ptr [c_a0], eax
    call    tsc_read
    mov     dword ptr [c_t0], eax
    call    pit_read
    mov     bx, ax                      /* previous PIT */
    xor     esi, esi                    /* PIT sum */
    xor     cx, cx                      /* edges */
    mov     dl, 1                       /* last level */
    mov     eax, 4 * T_1S
    call    dl_start
3:  call    dl_check
    jc      9f
    push    edx
    call    pit_read
    movzx   edx, ax
    movzx   eax, bx
    mov     bx, dx
    call    pit_sub
    add     esi, eax
    pop     edx
    in      al, 0x60
    and     al, 0x20
    jz      4f
    cmp     dl, 0
    jne     5f
    inc     cx
    mov     dl, 1
    cmp     cx, 60
    jae     6f
    jmp     3b
4:  mov     dl, 0
5:  jmp     3b
6:  call    artic_read
    sub     eax, dword ptr [c_a0]
    and     eax, 0xFFFFFF
    mov     dword ptr [c_vart], eax
    call    tsc_read
    sub     eax, dword ptr [c_t0]
    mov     dword ptr [c_vtsc], eax
    push    edx
    call    pit_read
    movzx   edx, ax
    movzx   eax, bx
    call    pit_sub
    add     esi, eax
    pop     edx
    sti
    mov     si, offset k_P
    push    esi
    call    row_start
    pop     esi
    PS      "VSYNC edges=60 art="
    mov     eax, dword ptr [c_vart]
    call    out_d
    PS      " pit="
    mov     eax, esi
    call    out_d
    PS      " tsc="
    cmp     byte ptr [has_tsc], 0
    jne     7f
    PS      "-"
    jmp     8f
7:  mov     eax, dword ptr [c_vtsc]
    call    out_d
8:  call    out_nl
    mov     eax, dword ptr [c_vart]
    mov     ecx, 10
    mul     ecx
    mov     ecx, 60
    div     ecx
    mov     dword ptr [c_vsx10], eax
    ret
9:  sti
    mov     si, offset to_vsync
    jmp     timeout_line

tsc_read:                               /* EAX = TSC low (0 without a TSC) */
    xor     eax, eax
    cmp     byte ptr [has_tsc], 0
    je      1f
    push    edx
    rdtsc
    pop     edx
1:  ret

/* cal_tsc: TSC against 0.25 s of ARTIC, both ends on an ARTIC edge. */
cal_tsc:
    cli
    call    artic_sync
    mov     dword ptr [c_a0], eax
    call    tsc_read
    mov     dword ptr [c_t0], eax
1:  mov     eax, dword ptr [c_a0]
    call    artic_since
    cmp     eax, 76800
    jb      1b
    call    artic_sync
    mov     ebx, eax
    call    tsc_read
    sti
    sub     eax, dword ptr [c_t0]
    mov     ecx, eax                    /* tsc delta */
    mov     eax, ebx
    sub     eax, dword ptr [c_a0]
    and     eax, 0xFFFFFF
    mov     ebx, eax                    /* art */
    mov     si, offset k_P
    call    row_start
    PS      "TSC art="
    call    out_d
    PS      " tsc="
    mov     eax, ecx
    call    out_d
    call    out_nl
    /* kHz = tsc * 307.2 / art = tsc * 3072 / (art * 10) */
    mov     eax, ecx
    mov     ecx, 3072
    mul     ecx
    mov     ecx, ebx
    imul    ecx, ecx, 10
    test    ecx, ecx
    jz      2f
    cmp     edx, ecx
    jae     2f
    div     ecx
    mov     dword ptr [c_tsckhz], eax
2:  ret

/* ======================================================================== RESTORE (always) */
/* The global set: interrupt vectors, the PIC masks, the 0x9A0 mode bits, against the
 * as-found values save_global took; the GRCG and access page are put to their documented
 * defaults (write-only registers, R13). */
sec_restore:
    mov     si, offset nm_restore
    mov     eax, WD_10S
    mov     bx, offset rest_exit
    call    sec_begin
    call    sec_disarm
    mov     al, 0
    out     0x7C, al                    /* GRCG off */
    mov     si, offset n_7c
    xor     eax, eax
    call    rs_default
    out     0xA6, al                    /* access page 0 */
    mov     si, offset n_a6
    call    rs_default
    push    es
    xor     ax, ax
    mov     es, ax
    xor     bx, bx
1:  movzx   di, byte ptr [vec_list + bx]
    mov     ax, di
    shl     di, 2
    mov     dword ptr [tmp_name], 0x20434556   /* "VEC " */
    mov     byte ptr [tmp_name+3], 0
    push    bx
    shl     bx, 2
    mov     eax, dword ptr [vec_save + bx]
    mov     edx, dword ptr es:[di]
    pop     bx
    push    eax
    movzx   ax, byte ptr [vec_list + bx]
    call    hex2_to_tmp
    pop     eax
    mov     si, offset tmp_name
    push    bx
    mov     cx, 0x0008
    mov     bl, 3
    call    rs_line
    pop     bx
    inc     bx
    cmp     bx, NVEC
    jb      1b
    pop     es
    mov     dx, 0x02
    mov     al, byte ptr [imr_m_save]
    mov     si, offset n_imrm
    call    rs_port8
    mov     dx, 0x0A
    mov     al, byte ptr [imr_s_save]
    mov     si, offset n_imrs
    call    rs_port8
    xor     bx, bx
2:  mov     al, byte ptr [q_list + bx]
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [q_save + bx]
    mov     dword ptr [tmp_name], 0x00413951    /* "Q9A" */
    mov     byte ptr [tmp_name+3], 0
    push    eax
    movzx   ax, byte ptr [q_list + bx]
    call    hex2_to_tmp
    pop     eax
    mov     si, offset tmp_name
    push    bx
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    pop     bx
    inc     bx
    cmp     bx, 4
    jb      2b
rest_exit:
    call    sec_end
    ret

/* hex2_to_tmp: append AL as 2 hex digits to the asciz at tmp_name. */
hex2_to_tmp:
    push    bx
    push    ax
    mov     bx, offset tmp_name
1:  cmp     byte ptr [bx], 0
    je      2f
    inc     bx
    jmp     1b
2:  push    ax
    shr     al, 4
    call    nib_ch
    mov     byte ptr [bx], al
    pop     ax
    call    nib_ch
    mov     byte ptr [bx+1], al
    mov     byte ptr [bx+2], 0
    pop     ax
    pop     bx
    ret
nib_ch:
    and     al, 15
    add     al, '0'
    cmp     al, '9'
    jbe     1f
    add     al, 7
1:  ret

/* ======================================================================== includes */
    .include "lib.inc"
    .include "selftest.inc"
    .include "sec_cpu.inc"
    .include "sec_gfx.inc"
    .include "sec_io.inc"
    .include "sec_dev.inc"
    .include "sec_opna2.inc"
    .include "sec_opna3.inc"
    .ifndef XE10U
    .include "sec_storage.inc"
    .include "sec_fdc2.inc"
    .include "sec_raster.inc"
    .include "sec_audit.inc"
    .else
    .include "sec_audit.inc"
    .include "sec_opna4.inc"
    .include "sec_audit2.inc"
    .endif

/* ======================================================================== data */
nm_id:      .asciz "ID"
nm_cal:     .asciz "CAL"
nm_cpu:     .asciz "CPU"
nm_gvram:   .asciz "GVRAM"
nm_grcg:    .asciz "GRCG"
nm_egc:     .asciz "EGC"
nm_pegc:    .asciz "PEGC"
nm_text:    .asciz "TEXT"
nm_io:      .asciz "IO"
nm_irq:     .asciz "IRQ"
nm_opna:    .asciz "OPNA"
nm_pcm86:   .asciz "PCM86"
nm_ide:     .asciz "IDE"
nm_bios:    .asciz "BIOS"
nm_pal:     .asciz "PAL"
nm_fdc:     .asciz "FDC"
nm_fdc2:    .asciz "FDC2"
nm_cd:      .asciz "CD"
nm_opna2:   .asciz "OPNA2"
nm_raster:  .asciz "RASTER"
nm_opna3:   .asciz "OPNA3"
nm_restore: .asciz "RESTORE"
nm_selftest: .asciz "SELFTEST"
nm_dry:     .asciz "DRY"

kw_all:     .asciz "ALL"
kw_cpu:     .asciz "CPU"
kw_gvram:   .asciz "GVRAM"
kw_grcg:    .asciz "GRCG"
kw_egc:     .asciz "EGC"
kw_pegc:    .asciz "PEGC"
kw_text:    .asciz "TEXT"
kw_io:      .asciz "IO"
kw_irq:     .asciz "IRQ"
kw_opna:    .asciz "OPNA"
kw_pcm86:   .asciz "PCM86"
kw_ide:     .asciz "IDE"
kw_bios:    .asciz "BIOS"
kw_pal:     .asciz "PAL"
kw_fdc:     .asciz "FDC"
kw_fdc2:    .asciz "FDC2"
kw_m640:    .asciz "M640"
kw_cd:      .asciz "CD"
kw_opna2:   .asciz "OPNA2"
kw_raster:  .asciz "RASTER"
kw_opna3:   .asciz "OPNA3"
kw_id:      .asciz "ID"
kw_cal:     .asciz "CAL"
kw_selftest: .asciz "SELFTEST"
kw_dry:     .asciz "DRY"
kw_quick:   .asciz "QUICK"
kw_force:   .asciz "FORCE"
kw_listen:  .asciz "LISTEN"
kw_sweep:   .asciz "SWEEP"
kw_step:    .asciz "STEP"
kw_to:      .asciz "TO"
kw_reps:    .asciz "REPS"
kw_o:       .asciz "O"
kw_tag:     .asciz "TAG"
kw_da:      .asciz "DA"
kw_skip:    .asciz "SKIP"
kw_from:    .asciz "FROM"

k_R:        .asciz "R "
k_P:        .asciz "P "
k_T:        .asciz "T "
k_X:        .asciz "X "
k_I:        .asciz "I "
k_STATE:    .asciz "STATE "
k_ROW:      .asciz "ROW "
k_n:        .asciz "n"
k_nop:      .asciz "nop"
k_rep:      .asciz "rep"
k_to:       .asciz "to"
k_if1:      .asciz "if1"
k_max:      .asciz "max"
k_trials:   .asciz "trials"
k_ratio:    .asciz "ratio_x1000"
k_vsync:    .asciz "vsync_x10"
k_readback: .asciz "readback"
k_default:  .asciz "default"
k_self:     .asciz "self"
w_ratio:    .asciz "pit_ratio"
w_vsync:    .asciz "vsync"
dash:       .asciz "-"
    .ifndef XE10U
def_out:    .asciz "XE10T.TXT"
    .else
def_out:    .asciz "XE10U.TXT"
    .endif
rs_nobuf:   .asciz "nobuffer"
rs_codebig: .asciz "codesize"
rs_artic:   .asciz "artic_dead"
rs_v86:     .asciz "v86"
to_pitwin:  .asciz "pit_reload"
to_vsync:   .asciz "vsync_edge"
n_7c:       .asciz "P7C_GRCG"
n_a6:       .asciz "PA6_PAGE"
n_imrm:     .asciz "IMR_M"
n_imrs:     .asciz "IMR_S"
con_dot:    .asciz "\r\n"
con_sp:     .asciz " "
con_done:   .asciz "\r\nXE10T done.\r\n"
con_usage:  .asciz "XE10T: no section given (try /ALL, /SELFTEST or /DRY)\r\n"

/* ---- variables (initialised, in the image, after const_end) ---- */
    VARS
    .p2align 2
run_crc:    .long 0
dl_t0:      .long 0
dl_len:     .long 0
wd_t0:      .long 0
wd_len:     .long 0
wd_el:      .long 0
if1_art:    .long 0
pit_mod:    .long 65536
sel_mask:   .long 0
skip_mask:  .long 0
cpu_max:    .long 0
cpu_feat:   .long 0
c_sum_pit:  .long 0
c_sum_art:  .long 0
c_a0:       .long 0
c_t0:       .long 0
c_e0:       .long 0
c_e1:       .long 0
c_espan:    .long 0
c_ratio:    .long 0
c_vart:     .long 0
c_vtsc:     .long 0
c_vsx10:    .long 0
c_tsckhz:   .long 0
vec_save:   .space NVEC * 4
vend:       .space 12
tmp_name:   .space 16
scratch:    .long 0, 0, 0, 0
out_handle: .word 1
ob_len:     .word 0
sec_crc:    .word 0
sec_rows:   .word 0
sec_name:   .word nm_id
fault_sec:  .word nm_id
n_sections: .word 0
wd_sp:      .word 0
wd_exit:    .word 0
reps:       .word 5
reps_arg:   .word 0
buf_seg:    .word 0
buf_paras:  .word 0
val_ptr:    .word 0
gen_crc:    .word 0
gen_base:   .word 0
cur_k:      .word 0
cur_case:   .word 0
cur_flags:  .word 0
k_ptr:      .word 0
shell_c:    .word 0
shell_b:    .word 0
poll_to:    .word 0
tag_sfx:    .word 0
tr_n:       .word 0
tr_names:   .word 0
cur_port:   .word 0
cur_val:    .word 0
c_edges:    .word 0
c_periods:  .word 0
c_vmax:     .word 0
c_vmin:     .word 0
in_sec:     .byte 0
crc_on:     .byte 0
sec_fault:  .byte 0
run_fault:  .byte 0
wd_armed:   .byte 0
pit_swap:   .byte 0
pit_mod_ok: .byte 0
artic_dead: .byte 0
gen_acc:    .byte 0
has_cpuid:  .byte 0
has_tsc:    .byte 0
v86:        .byte 0
cal_ok:     .byte 0
strap0501:  .byte 0
imr_m_save: .byte 0
imr_s_save: .byte 0
q_save:     .byte 0, 0, 0, 0
m_selftest: .byte 0
m_dry:      .byte 0
m_quick:    .byte 0
m_force:    .byte 0
m_listen:   .byte 0
m_sweep:    .byte 0
m_dummy:    .byte 0
bad_arg:    .byte 0
val_tok:    .byte 0
da_arg:     .byte 0
from_bit:   .byte 0
fl_hold:    .byte 0
rm_on:      .byte 0
    .p2align 1
rm_port:    .word 0xFFFF
out_name:   .space 16
tag_txt:    .space 16
tok:        .space 16
tok2:       .space 16
args_raw:   .space 128
args_up:    .space 128
    ENDVARS

/* ---- the build stamp (R15): marker, 16 sha digits, 8 crc digits; written by
 * `xe10t_decode.py --stamp`, '0' digits in the assembled image ---- */
stamp_mark: .ascii "XE10T-STAMP-V1:#"
stamp_sha:  .ascii "0000000000000000"
stamp_crc:  .ascii "00000000"
stamp_end:
stamp_len:  .word const_end - 0x100    /* the CRC covers the image up to const_end */

/* the strings of every CASE (subsection 1) follow here */
    .subsection 3
img_end:
/* The image must end below BSS_BASE (0xC000): the Makefile refuses a larger .COM
 * (48896 bytes), since GAS cannot evaluate a size across subsections here. */
