/* a20map.s - how the PC-98 A20 mask treats PHYSICAL addresses above 1 MiB.
 *
 * THE QUESTION. With the gate MASKED (OUT 0xF6,0x03; read back in 0xF2 bit 0 = 1: the Xe10
 * reads F2=FE open and FF masked while F6 reads 5E in both states, docs/probes/A20MAP-XE10.TXT
 * `initial A20: F6=5E F2=FE` / `after masking: F6=5E F2=FF`), does the
 * hardware clear ONLY physical address bit 20 (a 486 A20M# pin: 0x200000 stays 0x200000,
 * 0x100000 -> 0x000000, 0x300000 -> 0x200000), or does it wrap EVERYTHING into the first
 * MiB (0x200000 -> 0x000000, the way NP2kai models it)? And does the answer change above
 * 16 MiB (0x1100000), where RAM exists? Only the real machine can say; run this same
 * binary on the Xe10 and on the core and diff the two captures.
 *
 * METHOD. Unreal mode (big real mode): with CLI and BOTH PC-98 PIC data ports masked
 * (master 0x02, slave 0x0A), one protected-mode excursion loads FS and GS with a flat
 * 4 GiB data descriptor and returns to real mode; FS then addresses 32-bit PHYSICAL memory
 * (paging is off, so linear = physical). Test addresses are T[i] = X + {0, 1, 2, 3, 16, 17}
 * MiB. For each pass:
 *   1. A20 open: write marker 0xA20A0000+i to every valid T[i], read all back  (open=)
 *   2. WBINVD, A20 masked, read every T[i]                                     (masked=)
 *      then write marker 0xB0B00000+i to every T[i] IN ORDER, read all back    (mwr=)
 *   3. WBINVD, A20 open, read every T[i]: which physical cells the masked
 *      writes really hit                                                       (after=)
 *   4. restore every original dword (A20 open)
 * Pass 1 runs with the 486 cache as found (WBINVD brackets each A20 change, so the cache
 * cannot hide an alias). Pass 2 repeats it with CR0.CD=1, NW=0 (cache disabled), then
 * restores CR0. Interrupts stay off for the whole measurement and all printing is done
 * afterwards. A20 and the PIC masks are restored as found.
 *
 * WHY X IS WHERE IT IS. X must be a linear address below 1 MiB that this program owns,
 * and X + 1 MiB must lie ABOVE the HMA (0x100000-0x10FFEF), i.e. X >= 0x10000, or DOS=HIGH
 * code would sit under a test cell. The image itself is too low on a PC-98 (CS*16+0x100
 * is often < 0xFFF0), so X is the LAST PARAGRAPH of the program's own DOS memory block:
 * PSP:[0002] (the first segment past our allocation) minus one, times 16. A .COM is
 * handed all free memory, so that paragraph is ours; it is reached only through FS (flat),
 * never through a 16-bit offset. The program refuses to run if X < 0x10000. Cells in the
 * HMA/XMS area (X+1 MiB..) are saved first and restored, and interrupts are off meanwhile,
 * so nothing can run from them; if the originals were not stable (a DMA to XMS memory)
 * a restore could in principle write back a stale value - the window is ~1 ms.
 *
 * INSTALLED RAM comes from the PC-98 BIOS work area: 0x0401 = extended memory 1-16 MiB in
 * 128 KiB units, 0x0594 (word) = memory above 16 MiB in 1 MiB units. A T beyond that is
 * SKIPPED (a write there would hit open bus or the 15-16 MiB system space), and said so.
 *
 * PLAIN DOS ONLY: SMSW shows PE=1 under EMM386/VEM486 (V86), where CR0 and the descriptor
 * tricks are unavailable; the program prints a message and exits with ERRORLEVEL 1.
 *
 * AFTERWARDS the FS/GS segment limits stay 4 GiB (a real-mode segment load does not
 * rewrite the cached limit on a 386+); harmless to DOS, noted for completeness.
 *
 * OUTPUT (stdout, redirectable): header; then per pass a line per T:
 *   T=xxxxxxxx open=xxxxxxxx masked=xxxxxxxx mwr=xxxxxxxx after=xxxxxxxx
 * Marker low word = the INDEX i of the T whose write put it there (A20A000i / B0B0000i).
 * Read the MASKED column: masked(T[2])=A20A0002 and masked(T[1])=A20A0000 means bit 20
 * only; masked(T[2])=A20A0000 means a full wrap into the first MiB. Last line:
 * VERDICT BIT20-ONLY | FULL-1MIB-WRAP | OTHER | UNTESTABLE (computed from masked reads).
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    mov     sp, offset stack_top
    mov     dx, offset msg_banner
    call    puts

    smsw    ax
    test    al, 1
    jz      pe_clear
    mov     dx, offset msg_refuse_pe
    call    puts
    mov     ax, 0x4C01
    int     0x21
pe_clear:
    mov     ax, word ptr ds:[2]         /* PSP:[0002] = first segment past our block */
    dec     ax
    movzx   eax, ax
    shl     eax, 4
    mov     [xlin], eax
    cmp     eax, 0x10000
    jae     x_ok
    mov     dx, offset msg_refuse_x
    call    puts
    mov     ax, 0x4C01
    int     0x21
x_ok:
    xor     ax, ax
    mov     es, ax
    mov     al, es:[0x401]
    mov     [bda401], al
    mov     ax, es:[0x594]
    mov     [bda594], ax
    push    ds
    pop     es

    mov     dx, 0x00F6
    in      al, dx
    mov     [f6_init], al
    mov     dx, 0x00F2
    in      al, dx
    mov     [f2_init], al

    movzx   eax, byte ptr [bda401]
    shl     eax, 17
    add     eax, 0x100000
    mov     [lo_top], eax
    movzx   eax, word ptr [bda594]
    shl     eax, 20
    add     eax, 0x1000000
    mov     [hi_top], eax

    /* HIMEM.SYS takes all extended memory and ZEROES both fields (measured on the core:
     * 0401=00, 0594=0000 under HIMEM), so a zero 0401 does not mean "no RAM". Fall back to
     * assuming RAM up to 18 MiB; each T's open= column (the marker written with A20 open reads
     * back, or not) is then the presence test, and the header says the fallback was taken. */
    cmp     byte ptr [bda401], 0
    jne     bda_ok
    mov     dword ptr [lo_top], 0x1000000
    mov     dword ptr [hi_top], 0x1200000
    mov     byte ptr [bda_fallback], 1
bda_ok:

    /* the test addresses and their validity against installed RAM */
    xor     bx, bx
build:
    mov     eax, [xlin]
    add     eax, [toff+bx]
    mov     [tadr+bx], eax
    lea     ecx, [eax+4]
    xor     edx, edx
    cmp     eax, 0x100000
    jb      v_yes
    cmp     eax, 0x1000000
    jae     v_hi
    cmp     ecx, [lo_top]
    jbe     v_yes
    jmp     v_set
v_hi:
    cmp     ecx, [hi_top]
    jbe     v_yes
    jmp     v_set
v_yes:
    mov     edx, 1
v_set:
    mov     [tval+bx], edx
    add     bx, 4
    cmp     bx, 24
    jb      build

    /* header */
    mov     dx, offset msg_h_init
    call    puts
    mov     al, [f6_init]
    call    puthex8
    mov     dx, offset msg_h_f2
    call    puts
    mov     al, [f2_init]
    call    puthex8
    call    putnl
    mov     dx, offset msg_h_bda
    call    puts
    mov     al, [bda401]
    call    puthex8
    mov     dx, offset msg_h_bda2
    call    puts
    mov     ax, [bda594]
    call    puthex16
    call    putnl
    mov     dx, offset msg_h_x
    call    puts
    mov     eax, [xlin]
    call    puthex32
    mov     dx, offset msg_h_lo
    call    puts
    mov     eax, [lo_top]
    call    puthex32
    mov     dx, offset msg_h_hi
    call    puts
    mov     eax, [hi_top]
    call    puthex32
    call    putnl
    cmp     byte ptr [bda_fallback], 0
    je      no_fb_msg
    mov     dx, offset msg_fallback
    call    puts
    call    putnl
no_fb_msg:
    mov     dx, offset msg_h_note
    call    puts

    /* ---- measurement: no DOS calls, no interrupts, until the restore ---- */
    cli
    mov     dx, 0x0002
    in      al, dx
    mov     [pic_m], al
    mov     al, 0xFF
    out     dx, al
    mov     dx, 0x000A
    in      al, dx
    mov     [pic_s], al
    mov     al, 0xFF
    out     dx, al

    call    unreal_on
    mov     eax, cr0
    mov     [cr0_sv], eax
    call    a20_open

    xor     bx, bx
so_next:
    cmp     dword ptr [tval+bx], 0
    je      so_skip
    mov     esi, [tadr+bx]
    mov     eax, fs:[esi]
    mov     [torig+bx], eax
so_skip:
    add     bx, 4
    cmp     bx, 24
    jb      so_next

    mov     di, offset pass1
    xor     al, al
    call    measure_pass
    mov     di, offset pass2
    mov     al, 1
    call    measure_pass

    test    byte ptr [f2_init], 1       /* A20 back as found: F2 bit 0 = 1 was masked (F6 does
                                           not change with the mask on the Xe10, see the header) */
    jz      fin_open
    call    a20_mask
    jmp     fin_a20
fin_open:
    call    a20_open
fin_a20:
    xor     ax, ax
    mov     fs, ax
    mov     gs, ax
    mov     dx, 0x0002
    mov     al, [pic_m]
    out     dx, al
    mov     dx, 0x000A
    mov     al, [pic_s]
    out     dx, al
    sti

    /* ---- report ---- */
    mov     dx, offset msg_pass1
    mov     si, offset pass1
    call    print_pass
    mov     dx, offset msg_pass2
    mov     si, offset pass2
    call    print_pass

    mov     si, offset pass1
    call    verdict
    mov     [v1], dx
    mov     si, offset pass2
    call    verdict
    mov     [v2], dx
    mov     dx, offset msg_verdict
    call    puts
    mov     dx, [v1]
    cmp     dx, [v2]
    je      vd_same
    mov     dx, offset v_other
    call    puts
    mov     dx, offset msg_disagree
    call    puts
    jmp     vd_end
vd_same:
    call    puts
vd_end:
    call    putnl
    mov     dx, offset msg_done
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* ================================================================== */
/* measurement                                                         */
/* ================================================================== */
/* AL = 1: run with the cache disabled (CD=1, NW=0). DI = result block. Interrupts off. */
measure_pass:
    mov     [cur_blk], di
    mov     [mp_cd], al
    test    al, al
    jz      mp_cache
    mov     eax, [cr0_sv]
    or      eax, 0x40000000
    and     eax, 0xDFFFFFFF
    mov     cr0, eax
    wbinvd
mp_cache:
    call    a20_open
    mov     eax, 0xA20A0000
    call    write_markers
    mov     di, [cur_blk]
    call    read_all                    /* open= */
    wbinvd
    call    a20_mask
    mov     di, [cur_blk]
    mov     dx, 0x00F6
    in      al, dx
    mov     [di+96], al
    mov     dx, 0x00F2
    in      al, dx
    mov     [di+97], al
    mov     di, [cur_blk]
    add     di, 24
    call    read_all                    /* masked= */
    mov     eax, 0xB0B00000
    call    write_markers
    mov     di, [cur_blk]
    add     di, 48
    call    read_all                    /* mwr= */
    wbinvd
    call    a20_open
    mov     di, [cur_blk]
    add     di, 72
    call    read_all                    /* after= */
    xor     bx, bx
ro_next:
    cmp     dword ptr [tval+bx], 0
    je      ro_skip
    mov     esi, [tadr+bx]
    mov     eax, [torig+bx]
    mov     fs:[esi], eax
ro_skip:
    add     bx, 4
    cmp     bx, 24
    jb      ro_next
    wbinvd
    cmp     byte ptr [mp_cd], 0
    je      mp_done
    mov     eax, [cr0_sv]
    mov     cr0, eax
mp_done:
    ret

/* EAX = marker base; T[i] <- base + i, in order, valid T only */
write_markers:
    xor     bx, bx
wm_next:
    cmp     dword ptr [tval+bx], 0
    je      wm_skip
    mov     esi, [tadr+bx]
    movzx   ecx, bx
    shr     ecx, 2
    add     ecx, eax
    mov     fs:[esi], ecx
wm_skip:
    add     bx, 4
    cmp     bx, 24
    jb      wm_next
    ret

/* DI = 6-dword destination; invalid T read as 0 */
read_all:
    xor     bx, bx
ra_next:
    xor     eax, eax
    cmp     dword ptr [tval+bx], 0
    je      ra_store
    mov     esi, [tadr+bx]
    mov     eax, fs:[esi]
ra_store:
    mov     [bx+di], eax
    add     bx, 4
    cmp     bx, 24
    jb      ra_next
    ret

a20_open:                               /* 0xF2 <- any opens A20, 0xF6 <- 0x02 releases the mask
                                           (NP2kai cpuio_of2/cpuio_of6; pc9821_iobus.sv's
                                           HX_00F2/HX_00F6 write decode) */
    push    ax
    push    dx
    xor     al, al
    mov     dx, 0x00F2
    out     dx, al
    mov     al, 0x02
    mov     dx, 0x00F6
    out     dx, al
    pop     dx
    pop     ax
    ret

a20_mask:
    push    ax
    push    dx
    mov     al, 0x03
    mov     dx, 0x00F6
    out     dx, al
    pop     dx
    pop     ax
    ret

/* Flat 4 GiB descriptor into FS and GS, then back to real mode. 0x66 on LGDT: a 16-bit
 * LGDT loads only 24 base bits (Intel 80386 Programmer's Reference Manual, LGDT) and
 * CS*16+offset can exceed them. */
unreal_on:
    xor     eax, eax
    mov     ax, cs
    shl     eax, 4
    add     eax, offset gdt
    mov     [gdtr+2], eax
    .byte 0x66
    lgdt    [gdtr]
    mov     eax, cr0
    or      al, 1
    mov     cr0, eax
    jmp     1f
1:  mov     bx, 8
    mov     fs, bx
    mov     gs, bx
    mov     eax, cr0
    and     al, 0xFE
    mov     cr0, eax
    jmp     2f
2:  ret

/* ================================================================== */
/* verdicts                                                            */
/* ================================================================== */
/* SI = pass block; DX = message. masked[] is at +24. */
verdict:
    cmp     dword ptr [tval+4], 0
    je      vd_untest
    cmp     dword ptr [tval+8], 0
    je      vd_untest
    cmp     dword ptr [si+24+8], 0xA20A0002
    jne     vd_notbit
    cmp     dword ptr [si+24+4], 0xA20A0000
    jne     vd_notbit
    mov     dx, offset v_bit20
    ret
vd_notbit:
    cmp     dword ptr [si+24+8], 0xA20A0000
    jne     vd_oth
    mov     dx, offset v_full
    ret
vd_oth:
    mov     dx, offset v_other
    ret
vd_untest:
    mov     dx, offset v_untest
    ret

/* the above-16 MiB pair: T[4]=X+16M, T[5]=X+17M */
verdict_hi:
    cmp     dword ptr [tval+16], 0
    je      vh_untest
    cmp     dword ptr [tval+20], 0
    je      vh_untest
    cmp     dword ptr [si+24+20], 0xA20A0004
    jne     vh_notbit
    cmp     dword ptr [si+24+16], 0xA20A0004
    jne     vh_notbit
    mov     dx, offset v_bit20
    ret
vh_notbit:
    cmp     dword ptr [si+24+20], 0xA20A0000
    jne     vh_oth
    cmp     dword ptr [si+24+16], 0xA20A0000
    jne     vh_oth
    mov     dx, offset v_full
    ret
vh_oth:
    mov     dx, offset v_other
    ret
vh_untest:
    mov     dx, offset v_untest
    ret

/* ================================================================== */
/* printing                                                            */
/* ================================================================== */
/* DX = title, SI = pass block */
print_pass:
    call    puts
    mov     dx, offset msg_p_f6
    call    puts
    mov     al, [si+96]
    call    puthex8
    mov     dx, offset msg_h_f2
    call    puts
    mov     al, [si+97]
    call    puthex8
    call    putnl
    xor     bx, bx
pp_next:
    mov     dx, offset msg_t
    call    puts
    mov     eax, [tadr+bx]
    call    puthex32
    cmp     dword ptr [tval+bx], 0
    jne     pp_valid
    mov     dx, offset msg_skip
    call    puts
    jmp     pp_end
pp_valid:
    mov     dx, offset msg_open
    call    puts
    mov     eax, [si+bx]
    call    puthex32
    mov     dx, offset msg_masked
    call    puts
    mov     eax, [si+bx+24]
    call    puthex32
    mov     dx, offset msg_mwr
    call    puts
    mov     eax, [si+bx+48]
    call    puthex32
    mov     dx, offset msg_after
    call    puts
    mov     eax, [si+bx+72]
    call    puthex32
pp_end:
    call    putnl
    add     bx, 4
    cmp     bx, 24
    jb      pp_next
    call    verdict
    push    dx
    mov     dx, offset msg_pverdict
    call    puts
    pop     dx
    call    puts
    call    putnl
    call    verdict_hi
    push    dx
    mov     dx, offset msg_hverdict
    call    puts
    pop     dx
    call    puts
    call    putnl
    ret

putc:                           /* DL = character */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

puts:                           /* DX = '$'-terminated string */
    push    ax
    push    dx
    mov     ah, 0x09
    int     0x21
    pop     dx
    pop     ax
    ret

putnl:
    push    dx
    mov     dl, 0x0D
    call    putc
    mov     dl, 0x0A
    call    putc
    pop     dx
    ret

puthex32:                       /* EAX */
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
    call    puthex16
    ret

puthex16:                       /* AX */
    push    ax
    xchg    al, ah
    call    puthex8
    xchg    al, ah
    call    puthex8
    pop     ax
    ret

puthex8:                        /* AL */
    push    ax
    push    ax
    shr     al, 4
    call    puthexdig
    pop     ax
    and     al, 0x0F
    call    puthexdig
    pop     ax
    ret

puthexdig:                      /* AL = 0..15 */
    push    ax
    push    dx
    and     al, 0x0F
    cmp     al, 10
    jb      1f
    add     al, 'A' - 10
    jmp     2f
1:  add     al, '0'
2:  mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret

/* ================================================================== */
/* strings ('$'-terminated, CRLF for DOS)                              */
/* ================================================================== */
msg_banner:   .ascii "A20MAP 1 - how the PC-98 A20 mask treats physical addresses\r\n$"
msg_refuse_pe:.ascii "A20MAP: CR0.PE is set (EMM386/VEM486 V86 monitor resident). Boot plain DOS, at most HIMEM.SYS. Nothing measured.\r\n$"
msg_refuse_x: .ascii "A20MAP: the program block ends below 0x10000 - cannot place X above the HMA. Nothing measured.\r\n$"
msg_h_init:   .ascii "initial A20: F6=$"
msg_h_f2:     .ascii " F2=$"
msg_h_bda:    .ascii "BDA 0x0401=$"
msg_h_bda2:   .ascii " (128 KiB units, 1-16 MiB) 0x0594=$"
msg_h_x:      .ascii "X=$"
msg_h_lo:     .ascii " ram_top_below_16M=$"
msg_h_hi:     .ascii " ram_top_above_16M=$"
msg_h_note:   .ascii "T = X + {0,1,2,3,16,17} MiB; markers A20A000i (open) / B0B0000i (masked write), i = T index.\r\nWBINVD brackets every A20 change; pass 2 repeats with CR0.CD=1 NW=0. IF=0, PICs masked.\r\n$"
msg_pass1:    .ascii "PASS 1 (486 cache as found, WBINVD around mask changes)\r\n$"
msg_pass2:    .ascii "PASS 2 (486 cache disabled: CR0.CD=1 NW=0, WBINVD)\r\n$"
msg_p_f6:     .ascii "  after masking: F6=$"
msg_t:        .ascii "T=$"
msg_skip:     .ascii " SKIPPED (beyond installed RAM per 0401/0594)$"
msg_fallback: .ascii "BDA 0401/0594 are zero (HIMEM owns extended memory): assuming RAM to 18 MiB - check each open= value reads back its marker$"
msg_open:     .ascii " open=$"
msg_masked:   .ascii " masked=$"
msg_mwr:      .ascii " mwr=$"
msg_after:    .ascii " after=$"
msg_pverdict: .ascii "  pass verdict: $"
msg_hverdict: .ascii "  above-16MiB (X+16M,X+17M) verdict: $"
msg_verdict:  .ascii "VERDICT $"
msg_disagree: .ascii " (cache-enabled and cache-disabled passes disagree)$"
msg_done:     .ascii "A20MAP DONE\r\n$"
v_bit20:      .ascii "BIT20-ONLY$"
v_full:       .ascii "FULL-1MIB-WRAP$"
v_other:      .ascii "OTHER$"
v_untest:     .ascii "UNTESTABLE$"

/* ================================================================== */
/* data                                                                */
/* ================================================================== */
    .balign 8
gdt:          .quad 0
              .quad 0x00CF92000000FFFF   /* flat data, base 0, limit 4 GiB, writable */
gdtr:         .word 15
              .long 0

    .balign 4
toff:         .long 0x000000, 0x100000, 0x200000, 0x300000, 0x1000000, 0x1100000
tadr:         .long 0, 0, 0, 0, 0, 0
tval:         .long 0, 0, 0, 0, 0, 0
torig:        .long 0, 0, 0, 0, 0, 0
xlin:         .long 0
lo_top:       .long 0
hi_top:       .long 0
cr0_sv:       .long 0
bda594:       .word 0
bda_fallback: .byte 0
cur_blk:      .word 0
v1:           .word 0
v2:           .word 0
bda401:       .byte 0
f6_init:      .byte 0
f2_init:      .byte 0
pic_m:        .byte 0
pic_s:        .byte 0
mp_cd:        .byte 0
    .balign 4
/* result block: open[6] +0, masked[6] +24, mwr[6] +48, after[6] +72, F6 +96, F2 +97 */
pass1:        .space 100
pass2:        .space 100
              .space 256
stack_top:
