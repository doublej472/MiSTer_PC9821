/* fdwrite.s - write a floppy image onto a real 2HD disk through the PC-98 DISK BIOS:
 * format every track with the image's own sector IDs, write it, read it back, compare.
 *
 *   FDWRITE image.FDW drive [/Y] [/NF] [/V]
 *     drive  1 or 2: the machine's floppy drive (DA/UA 0x90 / 0x91). Nothing else is
 *            accepted, so the hard disk (DA/UA 0x80/0x00 class) can never be named.
 *     /Y     no "press Y" question (scripted runs)
 *     /NF    no format: write into the disk's existing format (a target that already has the
 *            image's layout - the core's D88 media cannot be FORMATted, pc9821_fdc.sv)
 *     /V     verify only: read every track and compare it with the image; nothing is written
 *   Exit code (ERRORLEVEL): 0 every track verified, 1 a disk error or a mismatch, 2 bad
 *   arguments or image file, 3 cancelled.
 *
 * THE IMAGE is the .FDW track container made by d88tofdw.py from a D88 (its docstring is the
 * format): per track C, H, nsec, N, MF, fill byte, CRC-16 of the data, the nsec C/H/R/N IDs in
 * physical order, then the data in R order 1..nsec. It is read sequentially; each track's
 * CRC is checked before anything is written, so a damaged file stops the run.
 *
 * THE BIOS CALLS (INT 1Bh; AH = command | flags, AL = DA/UA). The flag bits are the ones the
 * NP2kai BIOS model decodes (bios/bios1b.c fdd_operate): 0x10 seek to CL first
 * (`if (CPU_AH & 0x10) biosfd_seek(CPU_CL, ...)`), 0x40 MF = MFM (fdfmt_biospara
 * `if (!(CPU_AH & 0x40)) off += 4;`, the FM half of the table), 0x80 MT (not used). The
 * head is DH (`hd = ((CPU_DH) ^ (CPU_AL >> 2)) & 1`, AL bit 2 clear here). dmaroute.s reads
 * with the same AH = 0x56 on the Xe10.
 *   0x0D FORMAT: BX = ID list length, CH = N, CL = C, DH = H, DL = fill byte, ES:BP = the
 *        list of nsec 4-byte C,H,R,N entries (NP2kai `fdc.d = CPU_DL; fdc.N = CPU_CH;` and
 *        the loop `MEMR_READS(CPU_ES, pos, ID, 4)` over `fdc.sc` entries; the real BIOS hands
 *        the list to the FDC's WRITE ID by DMA - io/fdc.c FDC_WriteID, `fdc.bufcnt = 4` per
 *        entry). SC and GPL come from the BIOS's own table for N and MF, NOT from BX
 *        (fdfmt_biospara; bios/fdfmt.h fdfmt2hd: MFM N=1 SC 0x1A, FM N=0 SC 0x1A, MFM N=3
 *        SC 0x08), which is why d88tofdw.py refuses a track whose sector count differs.
 *   0x05 WRITE DATA, 0x06 READ DATA: BX = byte count, CH = N, CL = C, DH = H, DL = first R,
 *        ES:BP = buffer. One call per track: the BIOS steps R up to the table's EOT (the
 *        same row) - the whole track, R = 1..nsec.
 *   0x07 RECALIBRATE before a retry; 0x04 SENSE once before the first track (not ready /
 *        no drive answered before the disk is touched).
 * DA/UA 0x90 + unit is the 1 MB interface's 2HD mode: on a 3-mode drive the BIOS selects
 * 360 rpm / 500 kbps for it (NP2kai setfdcmode(drv, type, rpm=0); 0x30 + unit would be the
 * 1.44 MB mode at 300 rpm, `if ((rpm) && (!fdc.support144))`). The Xe10 answers SENSE on
 * DA/UA 0x90 (docs/probes/FDMODE-XE10.TXT `SENSE DA=90 AH=60 CF=1`: NOT READY, no disk in
 * the drive - the 0x60 of NP2kai fdd_operate `ret_ah = 0x60` when !fdd_diskready).
 * A return is good when CF is clear and AH's high nibble is 0 (dmaroute.s's test). AH codes
 * printed by name are NP2kai's: 0x60 not ready, 0x70 write protected (fdd_operate
 * `ret_ah = 0x70` on fdd_diskprotect), 0xC0 sector not found and 0xE0 seek/track error
 * (diskimage/fd/fdd_d88.c fddlasterror), 0x40 the mode/drive is not available
 * (fdd_operate `return (0x40)` from setfdcmode).
 *
 * DMA. The BIOS moves the ID list and the data by DMA (channel 2), and a transfer may not
 * cross a 64 KiB physical boundary (the uPD71071/8237 address counter is 16 bits under a
 * fixed bank register). The two track buffers and the ID list are therefore placed in 8 KiB
 * slots of this program's segment that do not cross one: of five candidate slots at
 * 0x4000..0xC000, one 64 KiB boundary can fall in at most one, so two are always free.
 *
 * RETRIES. A failed format, write, read or compare is retried from the format, after a
 * RECALIBRATE, up to three attempts per track; the third failure stops the run with the
 * operation, the BIOS AH and the track. A mismatch prints the first differing offset.
 *
 * Build: make -C tools/hwprobe fdwrite/fdwrite.com    (installed as FDWRITE.COM)
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .set SLOT0, 0x4000
    .set SLOTSZ, 0x2000
    .set NSLOT, 5
    .set MAXDATA, 0x2000
    .set MAXSEC, 64

_start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    cld
    mov     si, offset msg_banner
    call    puts
    call    parse_args
    jnc     1f
    mov     si, offset msg_usage
    call    puts
    mov     al, 2
    jmp     exit
1:
    /* open the image */
    mov     ax, 0x3D00
    mov     dx, offset fname
    int     0x21
    jnc     2f
    mov     si, offset msg_noopen
    call    puts
    mov     si, offset fname
    call    puts
    call    crlf
    mov     al, 2
    jmp     exit
2:  mov     [fh], ax
    mov     cx, 16
    mov     dx, offset fhdr
    call    fread
    jc      bad_file
    mov     si, offset fhdr
    mov     di, offset magic
    mov     cx, 8
    repe    cmpsb
    jne     bad_file
    mov     ax, [fhdr + 8]
    mov     [ntracks], ax
    test    ax, ax
    jz      bad_file
    cmp     ax, 164
    ja      bad_file
    cmp     byte ptr [fhdr + 10], 0x20
    jne     bad_media
    call    pick_slots
    jc      bad_slots

    /* what is about to happen */
    mov     si, offset msg_img
    call    puts
    mov     si, offset fname
    call    puts
    mov     si, offset msg_tracks
    call    puts
    mov     ax, [ntracks]
    call    putdec
    mov     si, offset msg_drive
    call    puts
    mov     dl, [unitch]
    call    putc
    mov     si, offset msg_daua
    call    puts
    mov     al, [da]
    call    puthex8
    mov     si, offset msg_mode_fwv
    cmp     byte ptr [opt_v], 0
    je      3f
    mov     si, offset msg_mode_v
    jmp     4f
3:  cmp     byte ptr [opt_nf], 0
    je      4f
    mov     si, offset msg_mode_wv
4:  call    puts

    cmp     byte ptr [opt_y], 0
    jne     5f
    mov     si, offset msg_warn
    cmp     byte ptr [opt_v], 0
    je      6f
    mov     si, offset msg_ask_v
6:  call    puts
    mov     dl, [unitch]
    call    putc
    mov     si, offset msg_ask
    call    puts
    mov     ah, 0x08                /* key, no echo */
    int     0x21
    or      al, 0x20
    cmp     al, 'y'
    je      7f
    mov     si, offset msg_cancel
    call    puts
    mov     al, 3
    jmp     exit
7:  call    crlf
5:
    /* SENSE: is the drive there and ready? Its AH is printed for the record; only NOT READY
     * (0x60) and NO DRIVE/MODE (0x40) with CF stop the run here (NP2kai fdd_operate: a ready
     * 2HD unit answers AH = 0x01 | 0x10 when protected, CF clear). A protected disk is
     * then refused by the first format or write (AH = 0x70). */
    mov     ah, 0x04
    mov     al, [da]
    call    int1b
    pushf
    mov     [bios_ah], ah
    mov     si, offset msg_sense
    call    puts
    mov     al, [bios_ah]
    call    puthex8
    call    ah_name
    call    crlf
    popf
    jnc     8f
    mov     al, [bios_ah]
    and     al, 0xF0
    cmp     al, 0x60
    je      9f
    cmp     al, 0x40
    jne     8f
9:  mov     si, offset msg_notready
    call    puts
    mov     al, 1
    jmp     exit
8:
    /* ---- the track loop ---- */
    mov     word ptr [trk], 0
trk_loop:
    mov     ax, [trk]
    cmp     ax, [ntracks]
    jb      1f
    jmp     all_done
1:  call    load_track
    jnc     2f
    jmp     bad_file
2:  /* "C00 H0 MFM 26x256 " */
    mov     dl, 'C'
    call    putc
    mov     al, [t_c]
    xor     ah, ah
    call    putdec2
    mov     si, offset msg_h
    call    puts
    mov     dl, [t_h]
    add     dl, '0'
    call    putc
    mov     si, offset msg_mfm
    cmp     byte ptr [t_mf], 0
    jne     3f
    mov     si, offset msg_fm
3:  call    puts
    mov     al, [t_ns]
    xor     ah, ah
    call    putdec
    mov     dl, 'x'
    call    putc
    mov     ax, [t_secsz]
    call    putdec
    mov     dl, ' '
    call    putc
    mov     byte ptr [tries], 0
attempt:
    inc     byte ptr [tries]
    cmp     byte ptr [opt_v], 0
    jne     do_read
    cmp     byte ptr [opt_nf], 0
    jne     do_write
    /* FORMAT: the ID list, copied into a DMA-safe slot (the read buffer, free until the read) */
    mov     si, offset idlist
    mov     di, [bufr]
    mov     cl, [t_ns]
    xor     ch, ch
    shl     cx, 2
    mov     [t_idlen], cx
    rep     movsb
    mov     ah, 0x0D | 0x10
    or      ah, [t_mf]
    mov     al, [da]
    mov     bx, [t_idlen]
    mov     ch, [t_n]
    mov     cl, [t_c]
    mov     dh, [t_h]
    mov     dl, [t_fill]
    mov     bp, [bufr]
    call    int1b
    mov     byte ptr [op], 'F'
    call    bios_ok
    jc      failed
do_write:
    cmp     byte ptr [opt_v], 0
    jne     do_read
    mov     ah, 0x05 | 0x10
    or      ah, [t_mf]
    mov     al, [da]
    mov     bx, [t_len]
    mov     ch, [t_n]
    mov     cl, [t_c]
    mov     dh, [t_h]
    mov     dl, 1
    mov     bp, [bufw]
    call    int1b
    mov     byte ptr [op], 'W'
    call    bios_ok
    jc      failed
do_read:
    /* clear the read buffer so a short transfer cannot pass the compare on old bytes */
    mov     di, [bufr]
    mov     cx, [t_len]
    mov     al, 0x5A
    rep     stosb
    mov     ah, 0x06 | 0x10
    or      ah, [t_mf]
    mov     al, [da]
    mov     bx, [t_len]
    mov     ch, [t_n]
    mov     cl, [t_c]
    mov     dh, [t_h]
    mov     dl, 1
    mov     bp, [bufr]
    call    int1b
    mov     byte ptr [op], 'R'
    call    bios_ok
    jc      failed
    /* compare */
    mov     si, [bufw]
    mov     di, [bufr]
    mov     cx, [t_len]
    repe    cmpsb
    je      track_ok
    dec     si
    sub     si, [bufw]
    mov     [diffoff], si
    mov     byte ptr [op], 'V'
    mov     byte ptr [bios_ah], 0
    jmp     failed
track_ok:
    mov     si, offset msg_ok
    call    puts
    cmp     byte ptr [tries], 1
    je      1f
    mov     si, offset msg_aftertry
    call    puts
    mov     al, [tries]
    xor     ah, ah
    call    putdec
    mov     dl, ')'
    call    putc
1:  call    crlf
    inc     word ptr [trk]
    jmp     trk_loop

failed:
    /* print "<op> AH=xx" and retry, or stop */
    mov     dl, '['
    call    putc
    mov     si, offset msg_opF
    cmp     byte ptr [op], 'F'
    je      1f
    mov     si, offset msg_opW
    cmp     byte ptr [op], 'W'
    je      1f
    mov     si, offset msg_opR
    cmp     byte ptr [op], 'R'
    je      1f
    mov     si, offset msg_opV
1:  call    puts
    cmp     byte ptr [op], 'V'
    jne     2f
    mov     ax, [diffoff]
    call    puthex16
    jmp     3f
2:  mov     si, offset msg_ah
    call    puts
    mov     al, [bios_ah]
    call    puthex8
    call    ah_name
3:  mov     si, offset msg_rb
    call    puts
    cmp     byte ptr [tries], 3
    jae     give_up
    /* RECALIBRATE, then the whole track again */
    mov     ah, 0x07
    mov     al, [da]
    call    int1b
    jmp     attempt
give_up:
    call    crlf
    mov     si, offset msg_stop
    call    puts
    mov     ax, [trk]
    call    putdec
    mov     si, offset msg_stop2
    call    puts
    mov     al, 1
    jmp     exit

all_done:
    mov     si, offset msg_done
    cmp     byte ptr [opt_v], 0
    je      1f
    mov     si, offset msg_done_v
1:  call    puts
    mov     ax, [ntracks]
    call    putdec
    mov     si, offset msg_done2
    call    puts
    mov     al, 0
    jmp     exit

bad_file:
    mov     si, offset msg_badfile
    call    puts
    mov     al, 2
    jmp     exit
bad_media:
    mov     si, offset msg_badmedia
    call    puts
    mov     al, 2
    jmp     exit
bad_slots:
    mov     si, offset msg_badslots
    call    puts
    mov     al, 2
    jmp     exit

/* exit with code AL; close the file if open */
exit:
    push    ax
    mov     bx, [fh]
    test    bx, bx
    jz      1f
    mov     ah, 0x3E
    int     0x21
1:  pop     ax
    mov     ah, 0x4C
    int     0x21

/* ---- the image ---- */

/* load_track: the next track record into t_*, idlist and [bufw]; CF on a bad record. */
load_track:
    mov     cx, 8
    mov     dx, offset thdr
    call    fread
    jc      9f
    mov     al, [thdr + 0]
    mov     [t_c], al
    mov     al, [thdr + 1]
    mov     [t_h], al
    cmp     al, 1
    ja      9f
    mov     al, [thdr + 2]
    mov     [t_ns], al
    test    al, al
    jz      9f
    cmp     al, MAXSEC
    ja      9f
    mov     al, [thdr + 3]
    mov     [t_n], al
    cmp     al, 3
    ja      9f
    mov     al, [thdr + 4]
    and     al, 0xBF
    jnz     9f
    mov     al, [thdr + 4]
    mov     [t_mf], al
    mov     al, [thdr + 5]
    mov     [t_fill], al
    mov     ax, [thdr + 6]
    mov     [t_crc], ax
    /* sector size and track length */
    mov     cl, [t_n]
    mov     ax, 128
    shl     ax, cl
    mov     [t_secsz], ax
    mov     cl, [t_ns]
    xor     ch, ch
    mul     cx
    test    dx, dx
    jnz     9f
    cmp     ax, MAXDATA
    ja      9f
    mov     [t_len], ax
    /* the ID list, then the data */
    mov     cl, [t_ns]
    xor     ch, ch
    shl     cx, 2
    mov     dx, offset idlist
    call    fread
    jc      9f
    mov     cx, [t_len]
    mov     dx, [bufw]
    call    fread
    jc      9f
    mov     si, [bufw]
    mov     cx, [t_len]
    call    crc16
    cmp     ax, [t_crc]
    jne     9f
    clc
    ret
9:  stc
    ret

/* fread: CX bytes from [fh] into DS:DX; CF unless exactly CX were read. */
fread:
    push    cx
    mov     bx, [fh]
    mov     ah, 0x3F
    int     0x21
    pop     cx
    jc      1f
    cmp     ax, cx
    jne     1f
    clc
    ret
1:  stc
    ret

/* crc16: CRC-16/CCITT (poly 0x1021, init 0xFFFF) of CX bytes at DS:SI -> AX. */
crc16:
    push    bx
    push    cx
    push    si
    mov     bx, 0xFFFF
1:  jcxz    4f
    lodsb
    xor     bh, al
    push    cx
    mov     cx, 8
2:  shl     bx, 1
    jnc     3f
    xor     bx, 0x1021
3:  loop    2b
    pop     cx
    dec     cx
    jmp     1b
4:  mov     ax, bx
    pop     si
    pop     cx
    pop     bx
    ret

/* pick_slots: [bufw], [bufr] = the first two 8 KiB slots whose physical span does not cross
 * a 64 KiB boundary. CF if fewer than two (cannot happen with five slots and one boundary). */
pick_slots:
    /* the code and data end below the first slot, and DOS gave this program the whole 64 KiB
     * segment (PSP:0002 = the first paragraph past its memory) */
    mov     ax, offset code_end
    cmp     ax, SLOT0
    ja      4f
    mov     ax, [0x02]
    mov     bx, cs
    sub     ax, bx
    cmp     ax, 0x1000
    jb      4f
    mov     word ptr [bufw], 0
    mov     word ptr [bufr], 0
    mov     di, SLOT0
    mov     cx, NSLOT
1:  /* low 16 bits of the slot's physical address: (CS << 4) + off */
    mov     ax, cs
    shl     ax, 4
    add     ax, di
    add     ax, SLOTSZ - 1
    jc      3f                      /* the slot's span wraps a 64 KiB boundary */
    cmp     word ptr [bufw], 0
    jne     2f
    mov     [bufw], di
    jmp     3f
2:  cmp     word ptr [bufr], 0
    jne     3f
    mov     [bufr], di
3:  add     di, SLOTSZ
    loop    1b
    cmp     word ptr [bufr], 0
    je      4f
    clc
    ret
4:  stc
    ret

/* ---- the command line ---- */

/* parse_args: fname, da/unitch, opt_*; CF on a bad command line. */
parse_args:
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    mov     bx, si
    add     bx, cx
    mov     byte ptr [bx], 0        /* NUL-terminate the tail (it ends with CR) */
    xor     dx, dx                  /* DL = positional arguments seen */
pa_next:
    call    skip_blanks
    mov     al, [si]
    test    al, al
    jz      pa_end
    cmp     al, 0x0D
    je      pa_end
    cmp     al, '/'
    je      pa_opt
    cmp     dl, 0
    je      pa_file
    cmp     dl, 1
    jne     pa_bad
    /* the drive: exactly "1" or "2" */
    cmp     byte ptr [si + 1], ' '
    ja      pa_bad
    cmp     al, '1'
    je      1f
    cmp     al, '2'
    jne     pa_bad
1:  mov     [unitch], al
    sub     al, '1'
    or      al, 0x90                /* DA/UA 0x90 + unit: 2HD on the 1 MB interface */
    mov     [da], al
    inc     si
    inc     dl
    jmp     pa_next
pa_file:
    mov     di, offset fname
    mov     cx, 79
2:  mov     al, [si]
    cmp     al, ' '
    jbe     3f
    cmp     al, '/'
    je      3f
    mov     [di], al
    inc     di
    inc     si
    loop    2b
    jmp     pa_bad
3:  mov     byte ptr [di], 0
    inc     dl
    jmp     pa_next
pa_opt:
    mov     al, [si + 1]
    and     al, 0xDF                /* upper case */
    cmp     al, 'Y'
    jne     4f
    mov     byte ptr [opt_y], 1
    add     si, 2
    jmp     pa_optend
4:  cmp     al, 'V'
    jne     5f
    mov     byte ptr [opt_v], 1
    add     si, 2
    jmp     pa_optend
5:  cmp     al, 'N'
    jne     pa_bad
    mov     al, [si + 2]
    and     al, 0xDF
    cmp     al, 'F'
    jne     pa_bad
    mov     byte ptr [opt_nf], 1
    add     si, 3
pa_optend:
    mov     al, [si]
    cmp     al, ' '
    jbe     pa_next
    cmp     al, '/'
    je      pa_next
    jmp     pa_bad
pa_end:
    cmp     dl, 2
    jne     pa_bad
    clc
    ret
pa_bad:
    stc
    ret

skip_blanks:
1:  mov     al, [si]
    cmp     al, ' '
    je      2f
    cmp     al, 0x09
    jne     3f
2:  inc     si
    jmp     1b
3:  ret

/* ---- the BIOS ---- */

/* int1b: INT 1Bh with DS/ES(=CS)/SI/DI/BP preserved; ES = CS for the buffer. */
int1b:
    push    ds
    push    es
    push    si
    push    di
    push    bp
    push    cs
    pop     es
    cld
    sti
    int     0x1B
    pop     bp
    pop     di
    pop     si
    pop     es
    pop     ds
    ret

/* bios_ok: after int1b, [bios_ah] = AH; CF if CF was set or AH's high nibble is not 0. */
bios_ok:
    mov     [bios_ah], ah
    jc      1f
    test    ah, 0xF0
    jnz     1f
    clc
    ret
1:  stc
    ret

/* ah_name: " (name)" for [bios_ah]'s high nibble when it is one of the known codes
 * (ahtab: 3-byte entries, code then the name's offset; 0xFF ends it). */
ah_name:
    push    ax
    push    si
    mov     al, [bios_ah]
    and     al, 0xF0
    mov     si, offset ahtab
1:  mov     ah, [si]
    cmp     ah, 0xFF
    je      3f
    cmp     ah, al
    je      2f
    add     si, 3
    jmp     1b
2:  mov     si, [si + 1]
    call    puts
3:  pop     si
    pop     ax
    ret

/* ---- output ---- */

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
1:  mov     al, [si]
    test    al, al
    jz      2f
    mov     dl, al
    call    putc
    inc     si
    jmp     1b
2:  pop     si
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
    jbe     1f
    add     al, 'A' - '9' - 1
1:  mov     dl, al
    call    putc
    ret

puthex16:                               /* AX */
    push    ax
    xchg    al, ah
    call    puthex8
    xchg    al, ah
    call    puthex8
    pop     ax
    ret

putdec2:                                /* AX < 100, two digits */
    push    ax
    push    dx
    cmp     ax, 10
    jae     1f
    mov     dl, '0'
    call    putc
1:  call    putdec
    pop     dx
    pop     ax
    ret

putdec:                                 /* AX, unsigned */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, 10
    xor     cx, cx
1:  xor     dx, dx
    div     bx
    push    dx
    inc     cx
    test    ax, ax
    jnz     1b
2:  pop     dx
    add     dl, '0'
    call    putc
    loop    2b
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ---- data ---- */
magic:          .ascii "FDWIMG1\x1a"
msg_banner:     .asciz "FDWRITE v1 - write a .FDW floppy image through the DISK BIOS\r\n"
msg_usage:      .ascii "usage: FDWRITE image.FDW drive [/Y] [/NF] [/V]\r\n"
                .ascii "  drive 1 or 2 (floppy drives only)\r\n"
                .ascii "  /Y no question  /NF no format  /V verify only (no write)\r\n"
                .asciz "  formats, writes and verifies every track; stops on the first error\r\n"
msg_noopen:     .asciz "cannot open "
msg_badfile:    .asciz "\r\nSTOP: the image file is not a valid .FDW or is damaged (bad header/CRC)\r\n"
msg_badmedia:   .asciz "STOP: the image is not a 2HD image\r\n"
msg_badslots:   .asciz "STOP: no DMA-safe buffer\r\n"
msg_img:        .asciz "image "
msg_tracks:     .asciz ": "
msg_drive:      .asciz " tracks -> drive "
msg_daua:       .asciz " (DA/UA "
msg_mode_fwv:   .asciz "), format + write + verify\r\n"
msg_mode_wv:    .asciz "), write + verify (no format)\r\n"
msg_mode_v:     .asciz "), verify only\r\n"
msg_warn:       .asciz "EVERYTHING on the disk in drive "
msg_ask_v:      .asciz "Verify the disk in drive "
msg_ask:        .asciz " will be replaced. Insert it and press Y (any other key cancels) "
msg_cancel:     .asciz "\r\ncancelled\r\n"
msg_sense:      .asciz "SENSE AH="
msg_notready:   .asciz "STOP: the drive is not ready (no disk in it, or no such drive)\r\n"
msg_h:          .asciz " H"
msg_mfm:        .asciz " MFM "
msg_fm:         .asciz " FM  "
msg_ok:         .asciz "ok"
msg_aftertry:   .asciz " (attempt "
msg_opF:        .asciz "format"
msg_opW:        .asciz "write"
msg_opR:        .asciz "read"
msg_opV:        .asciz "MISMATCH at +"
msg_ah:         .asciz " AH="
msg_rb:         .asciz "] "
msg_stop:       .asciz "STOP: 3 attempts failed on track "
msg_stop2:      .asciz " (C = track/2, H = track&1). Use a different disk; if every disk fails, note the AH code.\r\n"
msg_done:       .asciz "DONE: every track written and verified ("
msg_done_v:     .asciz "DONE: every track verified ("
msg_done2:      .asciz " tracks). END:FDWRITE\r\n"
msg_crlf:       .asciz "\r\n"
n40:            .asciz " (drive/mode not available)"
n60:            .asciz " (not ready: no disk?)"
n70:            .asciz " (write protected)"
nC0:            .asciz " (sector not found)"
nE0:            .asciz " (seek/track error)"
ahtab:          .byte 0x40
                .word n40
                .byte 0x60
                .word n60
                .byte 0x70
                .word n70
                .byte 0xC0
                .word nC0
                .byte 0xE0
                .word nE0
                .byte 0xFF

fh:             .word 0
ntracks:        .word 0
trk:            .word 0
bufw:           .word 0
bufr:           .word 0
diffoff:        .word 0
t_secsz:        .word 0
t_len:          .word 0
t_idlen:        .word 0
t_crc:          .word 0
da:             .byte 0
unitch:         .byte 0
opt_y:          .byte 0
opt_nf:         .byte 0
opt_v:          .byte 0
tries:          .byte 0
op:             .byte 0
bios_ah:        .byte 0
t_c:            .byte 0
t_h:            .byte 0
t_ns:           .byte 0
t_n:            .byte 0
t_mf:           .byte 0
t_fill:         .byte 0
fhdr:           .space 16
thdr:           .space 8
idlist:         .space MAXSEC * 4
fname:          .space 80
code_end:
