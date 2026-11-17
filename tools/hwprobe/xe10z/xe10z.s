/* xe10z.s - XE10Z, the guest-visible RTL edge cases a code review left open: five small
 * write-then-read and timing sections, one binary, run on the core first and then on the real
 * PC-9821Xe10 (the tools/hwprobe rule: the SAME binary on both sides, raw capture kept).
 *
 *   XE10Z [/ASAL] [/D29] [/SDIP] [/NMX] [/MPU] [/CAL] > XE10Z.TXT   (no argument = every section)
 *
 * SECTIONS (each BEGIN:x ... END:x; a hang is a BEGIN with no END), in the order they run:
 *   SAL   (selected by /A) the undocumented shift-group encoding /6 against /4 (SHL): D0, D1, D2,
 *         D3 (CL = 1), C0, C1 (imm 1), register (AL/AX/EAX) and memory ([BX]) operands, 8/16/32
 *         bits (66h), four operand values (40h -> 80h OF 1, C0h -> 80h OF 0, 80h -> 00h OF 1,
 *         01h -> 02h OF 0, scaled to the width), each from two forced FLAGS images (OF 0 with
 *         CF/PF/AF/ZF/SF 1, and OF 1 with them 0), plus counts 2 and 0 by CL. Result and pushf
 *         of /6 and /4 side by side. /6 is emitted as explicit bytes (no assembler mnemonic).
 *         Pure CPU, no I/O; it runs first.
 *   D29   port 0x29, the DMA bank-boundary register: what a READ returns after writes that name
 *         different channels (the core returns channel 0's bound whatever was written last).
 *         Ends with the firmware's own writes (0x06, 0x07: BANK4@0x6238-0x623F) and 0x00/0x01.
 *   SDIP  the software-DIP store's write masks at 0x841E (bank A and bank B, bits 1 and 0) and at
 *         0x861E (both banks, bit 7, a control): `out 0x8F1F,bank`, was/wrote/got/back, then
 *         `out 0x8F1F,0x80` (the firmware's resting value). Each round trip under cli, restored.
 *   NMX   ATA READ NATIVE MAX ADDRESS (0xF8) to the master of the as-found IDE bank, with LBA=1
 *         and LBA=0, after an IDENTIFY DEVICE that prints words 60/61 (capacity), 82/83/86 (the
 *         Host Protected Area bit is word 82 bit 10). Non-data commands; IRQ9 masked.
 *   MPU   the MPU-401 clock-to-host rate dither: after a reset (tempo 100, timebase 120: a 5 ms
 *         internal clock on both sides), for E7 data 04..0B, clock-to-host ON and the ARTIC
 *         interval of 32 consecutive FD messages. The card's IRQ (master IR6) is masked; polled.
 *   CAL   the uPD4990A TIMESET with invalid BCD: for each pattern, a valid BASE set, then the
 *         pattern, then three reads (at once, +1.1 s, +2.2 s). A read equal to the pattern says
 *         the chip loads it, equal to BASE says it refuses it. Then the clock is put back to the
 *         time read at the section's start plus the seconds elapsed since (sec/min/hour
 *         carried; a run across midnight is off by a day: set DATE).
 *
 * EXPECTED ON THE CORE (step Z0; the machine's capture decides each question):
 *   SAL   DIFF on OF only, count 1 only (the vendored z486 predates the fork's /6 OF fix);
 *         every other row SAME-AS-SHL
 *   D29   CH0;  SDIP  bank A/B 841E bit 1 WITHHELD, every other row STORED;  NMX  COUNT, COUNT;
 *   MPU   CORE (8-phase);  CAL  LOADED for P0 P2 P7 P8 P9 P12 P13, REFUSED for the rest
 *
 * TIMING. The ARTIC free-running counter (0x5C/0x5F, 307200 Hz), the reader of crt31k.s.
 * Every wait is bounded by an ARTIC deadline.
 *
 * OUTPUT: hex only; tools/hwprobe/xe10z/xe10z_decode.py states each section's verdict against
 * the models (core as built, NP2kai, qemu, datasheet).
 *
 * BUILD: make -C tools/hwprobe xe10z/xe10z.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ ARTIC_HZ, 307200
    .equ T_100MS,  30720
    .equ T_60MS,   18432
    .equ T_1100MS, 337920
    .equ MPU_DAT,  0xE0D0
    .equ MPU_ST,   0xE0D2
    .equ NFD,      33               /* FD stamps per rate: 32 intervals */
    .equ SAL_FI0,  0x02D7           /* IF, SF, ZF, AF, PF, CF set; OF clear */
    .equ SAL_FI1,  0x0A02           /* IF, OF set; SF, ZF, AF, PF, CF clear */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    /* argument tail at 0x80: a section is selected by its letter after '/' */
    mov     si, 0x81
    xor     bl, bl
1:  lodsb
    cmp     al, 0x0D
    je      3f
    cmp     al, '/'
    jne     1b
    lodsb
    and     al, 0xDF
    cmp     al, 'D'
    jne     2f
    or      bl, 0x01
2:  cmp     al, 'S'
    jne     21f
    or      bl, 0x02
21: cmp     al, 'N'
    jne     22f
    or      bl, 0x04
22: cmp     al, 'M'
    jne     23f
    or      bl, 0x08
23: cmp     al, 'C'
    jne     24f
    or      bl, 0x10
24: cmp     al, 'A'
    jne     1b
    or      bl, 0x20
    jmp     1b
3:  test    bl, bl
    jnz     4f
    mov     bl, 0x3F
4:  mov     [sel], bl
    mov     dx, offset s_hdr
    call    puts
    mov     al, [sel]
    call    puthex8
    call    putnl
    test    byte ptr [sel], 0x20     /* SAL first: pure CPU, it runs even if a later section hangs */
    jz      41f
    call    sec_sal
41: test    byte ptr [sel], 0x01
    jz      5f
    call    sec_d29
5:  test    byte ptr [sel], 0x02
    jz      6f
    call    sec_sdip
6:  test    byte ptr [sel], 0x04
    jz      7f
    call    sec_nmx
7:  test    byte ptr [sel], 0x08
    jz      8f
    call    sec_mpu
8:  test    byte ptr [sel], 0x10
    jz      9f
    call    sec_cal
9:  mov     dx, offset s_done
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* ======================================================================================== */
/* SAL                                                                                       */
/* ======================================================================================== */
/* For each form (sal_forms: stub /6, stub /4, value table, name, CL), each of its four values and
 * each of the two FLAGS images: run the /6 stub, then the /4 stub, from the same operand and
 * image, and print one row: SAL <form> v=<value> i=<image> r6=<result> f6=<pushf> r4= f4=. The
 * result is EAX for a register form and the dword at [BX] for a memory form (both printed as
 * 32 bits: the bits above the operand width must come back as they went in). */
sec_sal:
    mov     dx, offset s_b_sal
    call    puts
    mov     si, offset sal_forms
1:  cmp     word ptr [si], 0
    je      9f
    mov     word ptr [sal_k], 0 /* value offset 0, 4, 8, 12 */
2:  mov     bx, [si + 4]
    add     bx, [sal_k]
    mov     edx, [bx]
    mov     [sal_v], edx
    mov     word ptr [sal_i], SAL_FI0
3:  mov     di, [si]
    call    sal_exec
    mov     [sal_r6], eax
    mov     ax, [sal_fout]
    mov     [sal_f6], ax
    mov     di, [si + 2]
    call    sal_exec
    mov     [sal_r4], eax
    mov     ax, [sal_fout]
    mov     [sal_f4], ax
    call    sal_print
    cmp     word ptr [sal_i], SAL_FI1
    je      4f
    mov     word ptr [sal_i], SAL_FI1
    jmp     3b
4:  add     word ptr [sal_k], 4
    cmp     word ptr [sal_k], 16
    jb      2b
    add     si, 10
    jmp     1b
9:  mov     dx, offset s_e_sal
    call    puts
    ret

/* sal_exec: DI = the stub, SI the form ([si + 8] CL, [si + 9] 1 = memory form), [sal_v] the
 * operand, [sal_i] the FLAGS image -> EAX the result (EAX, or the dword at [BX]), [sal_fout] */
sal_exec:
    push    bx
    push    cx
    mov     cl, [si + 8]
    mov     eax, [sal_v]
    mov     [sal_mem], eax
    mov     bx, offset sal_mem
    push    word ptr [sal_i]
    popf
    call    di
    pushf
    pop     word ptr [sal_fout]
    cmp     byte ptr [si + 9], 0
    je      1f
    mov     eax, [sal_mem]
1:  pop     cx
    pop     bx
    ret

sal_print:
    push    si
    mov     dx, offset s_sal
    call    puts
    mov     dx, [si + 6]
    call    puts
    mov     dx, offset s_v
    call    puts
    mov     eax, [sal_v]
    call    puthex32
    mov     dx, offset s_i
    call    puts
    mov     ax, [sal_i]
    call    puthex16
    mov     dx, offset s_r6
    call    puts
    mov     eax, [sal_r6]
    call    puthex32
    mov     dx, offset s_f6
    call    puts
    mov     ax, [sal_f6]
    call    puthex16
    mov     dx, offset s_r4
    call    puts
    mov     eax, [sal_r4]
    call    puthex32
    mov     dx, offset s_f4
    call    puts
    mov     ax, [sal_f4]
    call    puthex16
    call    putnl
    pop     si
    ret

/* The stubs: one instruction each, then ret (call and ret leave FLAGS alone). The /6 ModRM
 * bytes are 0xF0 (mod 11, reg 110, rm 000 = AL/AX/EAX) and 0x37 (mod 00, reg 110, rm 111 =
 * [BX]); the /4 twins 0xE0 and 0x27. */
z6_d0r:  .byte 0xD0, 0xF0
    ret
z4_d0r:  .byte 0xD0, 0xE0
    ret
z6_d0m:  .byte 0xD0, 0x37
    ret
z4_d0m:  .byte 0xD0, 0x27
    ret
z6_d1r:  .byte 0xD1, 0xF0
    ret
z4_d1r:  .byte 0xD1, 0xE0
    ret
z6_d1m:  .byte 0xD1, 0x37
    ret
z4_d1m:  .byte 0xD1, 0x27
    ret
z6_d1r32: .byte 0x66, 0xD1, 0xF0
    ret
z4_d1r32: .byte 0x66, 0xD1, 0xE0
    ret
z6_d1m32: .byte 0x66, 0xD1, 0x37
    ret
z4_d1m32: .byte 0x66, 0xD1, 0x27
    ret
z6_d2r:  .byte 0xD2, 0xF0
    ret
z4_d2r:  .byte 0xD2, 0xE0
    ret
z6_d2m:  .byte 0xD2, 0x37
    ret
z4_d2m:  .byte 0xD2, 0x27
    ret
z6_d3r:  .byte 0xD3, 0xF0
    ret
z4_d3r:  .byte 0xD3, 0xE0
    ret
z6_d3m:  .byte 0xD3, 0x37
    ret
z4_d3m:  .byte 0xD3, 0x27
    ret
z6_d3r32: .byte 0x66, 0xD3, 0xF0
    ret
z4_d3r32: .byte 0x66, 0xD3, 0xE0
    ret
z6_d3m32: .byte 0x66, 0xD3, 0x37
    ret
z4_d3m32: .byte 0x66, 0xD3, 0x27
    ret
z6_c0r:  .byte 0xC0, 0xF0, 0x01
    ret
z4_c0r:  .byte 0xC0, 0xE0, 0x01
    ret
z6_c0m:  .byte 0xC0, 0x37, 0x01
    ret
z4_c0m:  .byte 0xC0, 0x27, 0x01
    ret
z6_c1r:  .byte 0xC1, 0xF0, 0x01
    ret
z4_c1r:  .byte 0xC1, 0xE0, 0x01
    ret
z6_c1m:  .byte 0xC1, 0x37, 0x01
    ret
z4_c1m:  .byte 0xC1, 0x27, 0x01
    ret
z6_c1r32: .byte 0x66, 0xC1, 0xF0, 0x01
    ret
z4_c1r32: .byte 0x66, 0xC1, 0xE0, 0x01
    ret
z6_c1m32: .byte 0x66, 0xC1, 0x37, 0x01
    ret
z4_c1m32: .byte 0x66, 0xC1, 0x27, 0x01
    ret

/* ======================================================================================== */
/* D29                                                                                       */
/* ======================================================================================== */
/* The writes name channels 1, 2, 3, 0, 1 with bounds 3, 0, 2, 2, 1, so the "channel 0" model
 * (the core) reads asfound, asfound, asfound, 02, 02, 02 and the "last write" model 03, 00, 02,
 * 02, 01, 01. The restore is the firmware's state: ch0/ch1 bound 0 (the power-up value), ch2
 * and ch3 bound 1 (BANK4@0x6238 `mov al,6 / out 0x29,al / mov al,7 / out 0x29,al`). */
sec_d29:
    mov     dx, offset s_b_d29
    call    puts
    pushf
    cli
    mov     di, offset d29_r
    in      al, 0x29
    stosb
    mov     si, offset d29_w
    mov     cx, 5
1:  lodsb
    out     0x29, al
    call    iodly
    in      al, 0x29
    stosb
    loop    1b
    call    iodly
    in      al, 0x29            /* again, no write between */
    stosb
    mov     al, 0x00
    out     0x29, al
    mov     al, 0x01
    out     0x29, al
    mov     al, 0x06
    out     0x29, al
    mov     al, 0x07
    out     0x29, al
    call    iodly
    in      al, 0x29            /* after the restore: the last write is ch3 bound 1 */
    stosb
    popf
    mov     dx, offset s_d29
    call    puts
    mov     si, offset d29_r
    mov     cx, 8
2:  lodsb
    call    puthex8
    call    putsp
    loop    2b
    call    putnl
    mov     dx, offset s_e_d29
    call    puts
    ret

/* ======================================================================================== */
/* SDIP                                                                                      */
/* ======================================================================================== */
sec_sdip:
    mov     dx, offset s_b_sdip
    call    puts
    mov     si, offset sdip_tab
1:  cmp     byte ptr [si], 0
    je      9f
    mov     bh, [si]            /* bank byte for 0x8F1F */
    mov     cx, [si + 1]        /* port */
    mov     bl, [si + 3]        /* xor mask */
    pushf
    cli
    mov     dx, 0x8F1F
    mov     al, bh
    out     dx, al
    call    iodly
    mov     dx, cx
    in      al, dx
    mov     [rt_was], al
    xor     al, bl
    mov     [rt_wrote], al
    out     dx, al
    call    iodly
    in      al, dx
    mov     [rt_got], al
    mov     al, [rt_was]
    out     dx, al
    call    iodly
    in      al, dx
    mov     [rt_back], al
    mov     dx, 0x8F1F
    mov     al, 0x80
    out     dx, al
    call    iodly
    popf
    push    si
    mov     dx, offset s_sdip
    call    puts
    mov     al, bh
    call    puthex8
    mov     dx, offset s_port
    call    puts
    mov     ax, cx
    call    puthex16
    mov     dx, offset s_was
    call    puts
    mov     al, [rt_was]
    call    puthex8
    mov     dx, offset s_wrote
    call    puts
    mov     al, [rt_wrote]
    call    puthex8
    mov     dx, offset s_got
    call    puts
    mov     al, [rt_got]
    call    puthex8
    mov     dx, offset s_back
    call    puts
    mov     al, [rt_back]
    call    puthex8
    call    putnl
    pop     si
    add     si, 4
    jmp     1b
9:  mov     dx, offset s_e_sdip
    call    puts
    ret

/* ======================================================================================== */
/* NMX                                                                                       */
/* ======================================================================================== */
sec_nmx:
    mov     dx, offset s_b_nmx
    call    puts
    pushf
    cli
    in      al, 0x0A
    mov     [imr_s], al
    or      al, 0x02            /* IRQ9 (the IDE) masked for the section */
    out     0x0A, al
    mov     dx, 0x0432
    in      al, dx
    mov     [nmx_bank], al
    mov     dx, 0x064C
    in      al, dx
    mov     [nmx_dh0], al
    /* IDENTIFY DEVICE to the master */
    mov     al, 0xA0
    out     dx, al
    call    ata_settle
    call    ata_wait_nbsy
    mov     dx, 0x064E
    mov     al, 0xEC
    out     dx, al
    call    ata_settle
    call    ata_wait_drq
    mov     byte ptr [nmx_idok], 0
    jc      1f
    mov     byte ptr [nmx_idok], 1
    mov     dx, 0x0640
    mov     di, offset id_buf
    mov     cx, 256
    rep     insw
1:  mov     dx, 0x064E
    in      al, dx
    mov     [nmx_idst], al
    /* READ NATIVE MAX ADDRESS, LBA=1 then LBA=0 */
    mov     al, 0xE0
    mov     di, offset nmx_r1
    call    nmx_one
    mov     al, 0xA0
    mov     di, offset nmx_r2
    call    nmx_one
    mov     dx, 0x064C
    mov     al, [nmx_dh0]
    out     dx, al
    call    ata_settle
    mov     dx, 0x064E
    in      al, dx              /* acknowledge anything left */
    mov     al, [imr_s]
    out     0x0A, al
    popf
    /* print */
    mov     dx, offset s_nmx_id
    call    puts
    mov     al, [nmx_bank]
    call    puthex8
    mov     dx, offset s_dh
    call    puts
    mov     al, [nmx_dh0]
    call    puthex8
    mov     dx, offset s_idok
    call    puts
    mov     al, [nmx_idok]
    call    puthex8
    mov     dx, offset s_st
    call    puts
    mov     al, [nmx_idst]
    call    puthex8
    mov     dx, offset s_w60
    call    puts
    mov     ax, [id_buf + 120]
    call    puthex16
    mov     dx, offset s_w61
    call    puts
    mov     ax, [id_buf + 122]
    call    puthex16
    mov     dx, offset s_w82
    call    puts
    mov     ax, [id_buf + 164]
    call    puthex16
    mov     dx, offset s_w83
    call    puts
    mov     ax, [id_buf + 166]
    call    puthex16
    mov     dx, offset s_w86
    call    puts
    mov     ax, [id_buf + 172]
    call    puthex16
    call    putnl
    mov     si, offset nmx_r1
    mov     al, 0xE0
    call    nmx_print
    mov     si, offset nmx_r2
    mov     al, 0xA0
    call    nmx_print
    mov     dx, offset s_e_nmx
    call    puts
    ret

/* nmx_one: AL = drive/head byte; DI = 9 bytes: tmo, st_before, err, sc, sn, cl, ch, dh, st */
nmx_one:
    mov     dx, 0x064C
    out     dx, al
    call    ata_settle
    call    ata_wait_nbsy
    setc    byte ptr [di]
    mov     dx, 0x074C
    in      al, dx
    mov     [di + 1], al
    mov     dx, 0x064E
    mov     al, 0xF8
    out     dx, al
    call    ata_settle
    call    ata_wait_nbsy
    jnc     1f
    or      byte ptr [di], 2
1:  mov     dx, 0x0642
    in      al, dx
    mov     [di + 2], al
    mov     dx, 0x0644
    in      al, dx
    mov     [di + 3], al
    mov     dx, 0x0646
    in      al, dx
    mov     [di + 4], al
    mov     dx, 0x0648
    in      al, dx
    mov     [di + 5], al
    mov     dx, 0x064A
    in      al, dx
    mov     [di + 6], al
    mov     dx, 0x064C
    in      al, dx
    mov     [di + 7], al
    mov     dx, 0x064E
    in      al, dx              /* status last: the read acknowledges the IRQ */
    mov     [di + 8], al
    ret

nmx_print:
    push    ax
    mov     dx, offset s_nmx_f8
    call    puts
    pop     ax
    call    puthex8
    mov     dx, offset s_tmo
    call    puts
    lodsb
    call    puthex8
    mov     dx, offset s_st0
    call    puts
    lodsb
    call    puthex8
    mov     dx, offset s_err
    call    puts
    lodsb
    call    puthex8
    mov     dx, offset s_tf
    call    puts
    mov     cx, 5
1:  lodsb
    call    puthex8
    call    putsp
    loop    1b
    mov     dx, offset s_st
    call    puts
    lodsb
    call    puthex8
    call    putnl
    ret

/* ata_settle: a few I/O reads (ideprobe's). */
ata_settle:
    push    ax
    push    cx
    mov     cx, 20
1:  in      al, 0x60
    loop    1b
    pop     cx
    pop     ax
    ret

/* ata_wait_nbsy: alternate status (0x74C) BSY clear within 100 ms of ARTIC; CF on timeout. */
ata_wait_nbsy:
    push    eax
    push    ebx
    push    dx
    call    artic_read
    mov     ebx, eax
1:  mov     dx, 0x074C
    in      al, dx
    test    al, 0x80
    jz      2f
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, T_100MS
    jb      1b
    stc
    jmp     3f
2:  clc
3:  pop     dx
    pop     ebx
    pop     eax
    ret

/* ata_wait_drq: BSY clear and DRQ set within 100 ms; CF on ERR or timeout. */
ata_wait_drq:
    push    eax
    push    ebx
    push    dx
    call    artic_read
    mov     ebx, eax
1:  mov     dx, 0x074C
    in      al, dx
    test    al, 0x80
    jnz     4f
    test    al, 0x08
    jnz     2f
    test    al, 0x01
    jnz     5f
4:  call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, T_100MS
    jb      1b
5:  stc
    jmp     3f
2:  clc
3:  pop     dx
    pop     ebx
    pop     eax
    ret

/* ======================================================================================== */
/* MPU                                                                                       */
/* ======================================================================================== */
sec_mpu:
    mov     dx, offset s_b_mpu
    call    puts
    mov     dx, MPU_ST
    in      al, dx
    cmp     al, 0xFF
    jne     1f
    mov     dx, offset s_mpu_none
    call    puts
    jmp     9f
1:  in      al, 0x02
    mov     [imr_m], al
    or      al, 0x40            /* the card's INT2 = IR6, masked: polled only */
    out     0x02, al
    call    mpu_drain
    mov     al, 0xFF            /* reset: tempo 100, timebase 120 on both sides */
    call    mpu_cmd
    mov     [mpu_rst], al
    mov     dx, offset s_mpu_rst
    call    puts
    mov     al, [mpu_rst]
    call    puthex8
    call    putnl
    mov     byte ptr [mpu_v], 0x04
2:  call    mpu_drain
    mov     al, 0xE7
    call    mpu_cmd
    mov     al, [mpu_v]
    call    mpu_data
    mov     al, 0x95            /* clock to host ON */
    call    mpu_cmd
    mov     [mpu_ack], al
    call    artic_read
    mov     [mpu_t0], eax
    /* NFD FD stamps */
    xor     bx, bx              /* stamps taken */
    mov     byte ptr [mpu_oth], 0
    mov     byte ptr [mpu_tmo], 0
3:  call    artic_read
    mov     ecx, eax
4:  mov     dx, MPU_ST
    in      al, dx
    test    al, 0x80
    jz      5f
    call    artic_read
    sub     eax, ecx
    and     eax, 0x00FFFFFF
    cmp     eax, T_60MS
    jb      4b
    inc     byte ptr [mpu_tmo]
    jmp     6f
5:  call    artic_read
    mov     edi, eax
    mov     dx, MPU_DAT
    in      al, dx
    cmp     al, 0xFD
    je      51f
    inc     byte ptr [mpu_oth]
    jmp     3b
51: mov     si, bx
    shl     si, 2
    mov     [mpu_stamp + si], edi
    inc     bx
    cmp     bx, NFD
    jb      3b
6:  mov     [mpu_n], bx
    mov     al, 0x94            /* clock to host OFF */
    call    mpu_cmd
    call    mpu_drain
    /* print: MPU v=.. ack=.. n=.. oth=.. tmo=.. first=.. d=.. */
    mov     dx, offset s_mpu_v
    call    puts
    mov     al, [mpu_v]
    call    puthex8
    mov     dx, offset s_ack
    call    puts
    mov     al, [mpu_ack]
    call    puthex8
    mov     dx, offset s_n
    call    puts
    mov     ax, [mpu_n]
    call    puthex8
    mov     dx, offset s_oth
    call    puts
    mov     al, [mpu_oth]
    call    puthex8
    mov     dx, offset s_tmo
    call    puts
    mov     al, [mpu_tmo]
    call    puthex8
    mov     dx, offset s_first
    call    puts
    cmp     word ptr [mpu_n], 0
    je      8f
    mov     eax, [mpu_stamp]
    sub     eax, [mpu_t0]
    and     eax, 0x00FFFFFF
    call    puthex16
    mov     dx, offset s_d
    call    puts
    mov     cx, [mpu_n]
    dec     cx
    jz      8f
    xor     si, si
7:  mov     eax, [mpu_stamp + si + 4]
    sub     eax, [mpu_stamp + si]
    and     eax, 0x00FFFFFF
    call    puthex16
    cmp     cx, 1
    je      71f
    mov     dl, ','
    call    putc
71: add     si, 4
    loop    7b
8:  call    putnl
    inc     byte ptr [mpu_v]
    cmp     byte ptr [mpu_v], 0x0C
    jb      2b
    mov     al, 0xFF            /* leave the card reset, in intelligent mode */
    call    mpu_cmd
    call    mpu_drain
    mov     al, [imr_m]
    out     0x02, al
9:  mov     dx, offset s_e_mpu
    call    puts
    ret

/* mpu_cmd: AL = command. Waits DRR (bit 6 = 0) <= 100 ms, writes it, then reads bytes until
 * the ACK 0xFE (FD bytes skipped) <= 100 ms. Returns AL = 0xFE, or 0x00 on a timeout. */
mpu_cmd:
    push    ebx
    push    dx
    mov     ah, al
    call    mpu_wait_drr
    mov     dx, MPU_ST
    mov     al, ah
    out     dx, al
    call    artic_read
    mov     ebx, eax
1:  mov     dx, MPU_ST
    in      al, dx
    test    al, 0x80
    jnz     2f
    mov     dx, MPU_DAT
    in      al, dx
    cmp     al, 0xFE
    je      3f
2:  call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, T_100MS
    jb      1b
    xor     al, al
3:  pop     dx
    pop     ebx
    ret

/* mpu_data: AL = a data byte, written when DRR allows (<= 100 ms). */
mpu_data:
    push    dx
    mov     ah, al
    call    mpu_wait_drr
    mov     dx, MPU_DAT
    mov     al, ah
    out     dx, al
    pop     dx
    ret

mpu_wait_drr:
    push    eax
    push    ebx
    push    dx
    call    artic_read
    mov     ebx, eax
1:  mov     dx, MPU_ST
    in      al, dx
    test    al, 0x40
    jz      2f
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, T_100MS
    jb      1b
2:  pop     dx
    pop     ebx
    pop     eax
    ret

/* mpu_drain: read and drop waiting bytes (<= 64). */
mpu_drain:
    push    ax
    push    cx
    push    dx
    mov     cx, 64
1:  mov     dx, MPU_ST
    in      al, dx
    test    al, 0x80
    jnz     2f
    mov     dx, MPU_DAT
    in      al, dx
    loop    1b
2:  pop     dx
    pop     cx
    pop     ax
    ret

/* ======================================================================================== */
/* CAL                                                                                       */
/* ======================================================================================== */
sec_cal:
    mov     dx, offset s_b_cal
    call    puts
    call    artic_read
    mov     [cal_last], eax
    mov     dword ptr [cal_el], 0
    mov     di, offset cal_t0
    call    cal_read6
    call    cal_tick            /* start the elapsed count at T0's read */
    mov     dword ptr [cal_el], 0
    mov     ecx, T_1100MS
    call    wait_ticks
    mov     di, offset cal_t1
    call    cal_read6
    mov     dx, offset s_cal_live
    call    puts
    mov     si, offset cal_t0
    call    put6
    mov     dx, offset s_t1
    call    puts
    mov     si, offset cal_t1
    call    put6
    call    putnl
    mov     si, offset cal_pat
1:  cmp     byte ptr [si], 0xEE
    je      9f
    push    si
    mov     si, offset cal_base
    call    cal_set
    pop     si
    call    cal_set
    mov     di, offset cal_r0
    call    cal_read6
    mov     ecx, T_1100MS
    call    wait_ticks
    mov     di, offset cal_r1
    call    cal_read6
    mov     ecx, T_1100MS
    call    wait_ticks
    mov     di, offset cal_r2
    call    cal_read6
    push    si
    mov     dx, offset s_cal_set
    call    puts
    call    put6
    mov     dx, offset s_r0
    call    puts
    mov     si, offset cal_r0
    call    put6
    mov     dx, offset s_r1
    call    puts
    mov     si, offset cal_r1
    call    put6
    mov     dx, offset s_r2
    call    puts
    mov     si, offset cal_r2
    call    put6
    call    putnl
    pop     si
    add     si, 6
    jmp     1b
    /* the restore: T0 + the seconds since T0 was read, rounded (sec/min/hour BCD carry) */
9:  call    cal_tick
    mov     eax, [cal_el]
    add     eax, ARTIC_HZ / 2
    xor     edx, edx
    mov     ecx, ARTIC_HZ
    div     ecx
    mov     [cal_secs], ax
    mov     si, offset cal_t0
    mov     di, offset cal_rs
    mov     cx, 6
    rep     movsb
    mov     cx, [cal_secs]
    jcxz    11f
10: call    bcd_add1s
    loop    10b
11: mov     si, offset cal_rs
    call    cal_set
    mov     di, offset cal_r0
    call    cal_read6
    mov     dx, offset s_cal_rs
    call    puts
    mov     ax, [cal_secs]
    call    puthex16
    mov     dx, offset s_rsv
    call    puts
    mov     si, offset cal_rs
    call    put6
    mov     dx, offset s_r0
    call    puts
    mov     si, offset cal_r0
    call    put6
    call    putnl
    mov     dx, offset s_e_cal
    call    puts
    ret

/* cal_tick: add the ARTIC ticks since the last call into cal_el (the 24-bit counter wraps
 * every 54.6 s; every call site is less than 2.3 s after the previous). */
cal_tick:
    push    eax
    push    ebx
    call    artic_read
    mov     ebx, eax
    sub     eax, [cal_last]
    and     eax, 0x00FFFFFF
    add     [cal_el], eax
    mov     [cal_last], ebx
    pop     ebx
    pop     eax
    ret

/* wait_ticks: ECX = ARTIC ticks; cal_tick keeps the elapsed count. */
wait_ticks:
    push    eax
    push    ebx
    call    cal_tick
    mov     ebx, [cal_last]
1:  call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, ecx
    jb      1b
    call    cal_tick
    pop     ebx
    pop     eax
    ret

/* bcd_add1s: cal_rs (wire order sec, min, hour, ...) += 1 s, carried to the hour (a carry out
 * of 23:59:59 wraps the hour without moving the day). */
bcd_add1s:
    push    ax
    push    bx
    xor     bx, bx
1:  mov     al, [cal_rs + bx]
    add     al, 1
    daa
    mov     ah, 0x60
    cmp     bx, 2
    jne     2f
    mov     ah, 0x24
2:  cmp     al, ah
    jb      3f
    mov     byte ptr [cal_rs + bx], 0
    inc     bx
    cmp     bx, 3
    jb      1b
    jmp     4f
3:  mov     [cal_rs + bx], al
4:  pop     bx
    pop     ax
    ret

/* cal_read6: DI = 6 bytes <- the calendar, the ITF's reader (BANK7@0x5D22): TIMEREAD, SHIFT,
 * settle, 48 clocks on 0x33 bit 0 LSB-first, seconds first. cli inside. */
cal_read6:
    push    ax
    push    bx
    push    cx
    push    dx
    pushf
    cli
    mov     ah, 3
    call    cal_send
    mov     ah, 1
    call    cal_send
    call    cal_settle
    mov     bx, 6
1:  mov     cx, 8
    xor     ah, ah
2:  in      al, 0x33
    shr     al, 1
    rcr     ah, 1
    mov     al, 0x17
    out     0x20, al
    call    cal_wait
    mov     al, 0x07
    out     0x20, al
    call    cal_wait
    loop    2b
    mov     [di], ah
    inc     di
    dec     bx
    jnz     1b
    popf
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_set: SI = 6 bytes (wire order). The ITF's TIMESET (BANK7@0x5D62-0x5D9F): opcode 1,
 * 48 bits LSB-first with the field held at 7, opcode 2 (time set), opcode 0 (register hold). */
cal_set:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    pushf
    cli
    mov     ah, 1
    call    cal_send
    mov     bx, 6
1:  mov     ah, [si]
    inc     si
    mov     cx, 8
2:  shr     ah, 1
    mov     al, 0x07
    jae     3f
    mov     al, 0x27
3:  out     0x20, al
    call    cal_wait
    or      al, 0x10
    out     0x20, al
    call    cal_wait
    loop    2b
    dec     bx
    jnz     1b
    mov     al, 0x07
    out     0x20, al
    call    cal_wait
    mov     ah, 2
    call    cal_send
    mov     ah, 0
    call    cal_send
    popf
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_send: AH = 4-bit opcode on the serial command channel (BANK7@0x5DA2), STB to latch. */
cal_send:
    push    ax
    push    cx
    mov     cx, 4
1:  shr     ah, 1
    mov     al, 0x07
    jae     2f
    mov     al, 0x27
2:  out     0x20, al
    call    cal_wait
    or      al, 0x10
    out     0x20, al
    call    cal_wait
    loop    1b
    mov     al, 0x07
    out     0x20, al
    call    cal_wait
    mov     al, 0x0F
    out     0x20, al
    call    cal_wait
    mov     al, 0x07
    out     0x20, al
    call    cal_wait
    pop     cx
    pop     ax
    ret

/* cal_wait: the ITF's bit delay, three writes to 0x5F (BANK7@0x5E3D). */
cal_wait:
    push    ax
    xor     al, al
    out     0x5F, al
    out     0x5F, al
    out     0x5F, al
    pop     ax
    ret

/* cal_settle: the ITF's settle after SHIFT, 36 writes to 0x5F (BANK7@0x5D2D). */
cal_settle:
    push    ax
    push    cx
    mov     cx, 0x24
    xor     al, al
1:  out     0x5F, al
    loop    1b
    pop     cx
    pop     ax
    ret

/* put6: SI = 6 bytes, printed as 12 hex digits in wire order (sec min hour day mon|wday year) */
put6:
    push    cx
    mov     cx, 6
1:  lodsb
    call    puthex8
    loop    1b
    pop     cx
    ret

/* ======================================================================================== */
/* common                                                                                    */
/* ======================================================================================== */
iodly:
    push    ax
    xor     al, al
    out     0x5F, al
    out     0x5F, al
    pop     ax
    ret

artic_read:                     /* EAX = 24-bit ARTIC count (crt31k.s's reader) */
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005F
    in      al, dx
    movzx   ebx, al
    mov     dx, 0x005C
    in      ax, dx
    movzx   ecx, ax
    mov     dx, 0x005F
    in      al, dx
    movzx   eax, al
    cmp     eax, ebx
    je      1f
    cmp     ecx, 0x8000
    jb      1f
    mov     eax, ebx
1:  shl     eax, 16
    or      eax, ecx
    pop     ecx
    pop     ebx
    pop     dx
    ret

puthex32:
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
puthex16:
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
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
putc:
    push    ax
    mov     ah, 0x02
    int     0x21
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

/* ======================================================================================== */
/* data                                                                                      */
/* ======================================================================================== */
s_hdr:      .ascii "XE10Z v2 sel=$"
s_done:     .ascii "XE10Z DONE\r\n$"
s_nl:       .ascii "\r\n$"
s_b_sal:    .ascii "BEGIN:SAL\r\n$"
s_e_sal:    .ascii "END:SAL\r\n$"
s_sal:      .ascii "SAL $"
s_v:        .ascii " v=$"
s_i:        .ascii " i=$"
s_r6:       .ascii " r6=$"
s_f6:       .ascii " f6=$"
s_r4:       .ascii " r4=$"
s_f4:       .ascii " f4=$"
s_b_d29:    .ascii "BEGIN:D29\r\n$"
s_e_d29:    .ascii "END:D29\r\n$"
s_d29:      .ascii "D29 asfound w0D w02 w0B w08 w05 again final = $"
s_b_sdip:   .ascii "BEGIN:SDIP\r\n$"
s_e_sdip:   .ascii "END:SDIP\r\n$"
s_sdip:     .ascii "SDIP bank=$"
s_port:     .ascii " port=$"
s_was:      .ascii " was=$"
s_wrote:    .ascii " wrote=$"
s_got:      .ascii " got=$"
s_back:     .ascii " back=$"
s_b_nmx:    .ascii "BEGIN:NMX\r\n$"
s_e_nmx:    .ascii "END:NMX\r\n$"
s_nmx_id:   .ascii "NMX ID bank=$"
s_dh:       .ascii " dh0=$"
s_idok:     .ascii " idok=$"
s_st:       .ascii " st=$"
s_w60:      .ascii " w60=$"
s_w61:      .ascii " w61=$"
s_w82:      .ascii " w82=$"
s_w83:      .ascii " w83=$"
s_w86:      .ascii " w86=$"
s_nmx_f8:   .ascii "NMX F8 dh=$"
s_tmo:      .ascii " tmo=$"
s_st0:      .ascii " st0=$"
s_err:      .ascii " err=$"
s_tf:       .ascii " sc_sn_cl_ch_dh= $"
s_b_mpu:    .ascii "BEGIN:MPU\r\n$"
s_e_mpu:    .ascii "END:MPU\r\n$"
s_mpu_none: .ascii "MPU none (E0D2 reads FF)\r\n$"
s_mpu_rst:  .ascii "MPU reset ack=$"
s_mpu_v:    .ascii "MPU v=$"
s_ack:      .ascii " ack=$"
s_n:        .ascii " n=$"
s_oth:      .ascii " oth=$"
s_first:    .ascii " first=$"
s_d:        .ascii " d=$"
s_b_cal:    .ascii "BEGIN:CAL\r\n$"
s_e_cal:    .ascii "END:CAL\r\n$"
s_cal_live: .ascii "CAL live t0=$"
s_t1:       .ascii " t1=$"
s_cal_set:  .ascii "CAL set=$"
s_r0:       .ascii " r0=$"
s_r1:       .ascii " r1=$"
s_r2:       .ascii " r2=$"
s_cal_rs:   .ascii "CAL restore secs=$"
s_rsv:      .ascii " set=$"

/* SAL forms: .word stub /6, stub /4, values, name; .byte CL, memory (1) / register (0); 0 ends */
sal_forms:
            .word z6_d0r, z4_d0r, sal_v8, sn_D0r8c1
            .byte 1, 0
            .word z6_d0m, z4_d0m, sal_v8, sn_D0m8c1
            .byte 1, 1
            .word z6_d1r, z4_d1r, sal_v16, sn_D1r16c1
            .byte 1, 0
            .word z6_d1m, z4_d1m, sal_v16, sn_D1m16c1
            .byte 1, 1
            .word z6_d1r32, z4_d1r32, sal_v32, sn_D1r32c1
            .byte 1, 0
            .word z6_d1m32, z4_d1m32, sal_v32, sn_D1m32c1
            .byte 1, 1
            .word z6_d2r, z4_d2r, sal_v8, sn_D2r8c1
            .byte 1, 0
            .word z6_d2m, z4_d2m, sal_v8, sn_D2m8c1
            .byte 1, 1
            .word z6_d3r, z4_d3r, sal_v16, sn_D3r16c1
            .byte 1, 0
            .word z6_d3m, z4_d3m, sal_v16, sn_D3m16c1
            .byte 1, 1
            .word z6_d3r32, z4_d3r32, sal_v32, sn_D3r32c1
            .byte 1, 0
            .word z6_d3m32, z4_d3m32, sal_v32, sn_D3m32c1
            .byte 1, 1
            .word z6_c0r, z4_c0r, sal_v8, sn_C0r8c1
            .byte 1, 0
            .word z6_c0m, z4_c0m, sal_v8, sn_C0m8c1
            .byte 1, 1
            .word z6_c1r, z4_c1r, sal_v16, sn_C1r16c1
            .byte 1, 0
            .word z6_c1m, z4_c1m, sal_v16, sn_C1m16c1
            .byte 1, 1
            .word z6_c1r32, z4_c1r32, sal_v32, sn_C1r32c1
            .byte 1, 0
            .word z6_c1m32, z4_c1m32, sal_v32, sn_C1m32c1
            .byte 1, 1
            .word z6_d2r, z4_d2r, sal_v8, sn_D2r8c2
            .byte 2, 0
            .word z6_d2m, z4_d2m, sal_v8, sn_D2m8c0
            .byte 0, 1
            .word z6_d2r, z4_d2r, sal_v8, sn_D2r8c0
            .byte 0, 0
            .word z6_d3r, z4_d3r, sal_v16, sn_D3r16c2
            .byte 2, 0
            .word z6_d3m, z4_d3m, sal_v16, sn_D3m16c0
            .byte 0, 1
            .word z6_d3r32, z4_d3r32, sal_v32, sn_D3r32c2
            .byte 2, 0
            .word z6_d3m32, z4_d3m32, sal_v32, sn_D3m32c2
            .byte 2, 1
            .word 0
/* the operand values: 40h -> 80h (OF 1, CF 0), C0h -> 80h (OF 0, CF 1), 80h -> 00h (OF 1,
 * CF 1), 01h -> 02h (OF 0, CF 0) at the operand's top; the bits above an 8/16-bit operand A5 */
    .balign 4
sal_v8:     .long 0xA5A5A540, 0xA5A5A5C0, 0xA5A5A580, 0xA5A5A501
sal_v16:    .long 0xA5A54000, 0xA5A5C000, 0xA5A58000, 0xA5A50001
sal_v32:    .long 0x40000000, 0xC0000000, 0x80000000, 0x00000001
sn_D0r8c1:  .ascii "D0r8c1$"
sn_D0m8c1:  .ascii "D0m8c1$"
sn_D1r16c1: .ascii "D1r16c1$"
sn_D1m16c1: .ascii "D1m16c1$"
sn_D1r32c1: .ascii "D1r32c1$"
sn_D1m32c1: .ascii "D1m32c1$"
sn_D2r8c1:  .ascii "D2r8c1$"
sn_D2m8c1:  .ascii "D2m8c1$"
sn_D3r16c1: .ascii "D3r16c1$"
sn_D3m16c1: .ascii "D3m16c1$"
sn_D3r32c1: .ascii "D3r32c1$"
sn_D3m32c1: .ascii "D3m32c1$"
sn_C0r8c1:  .ascii "C0r8c1$"
sn_C0m8c1:  .ascii "C0m8c1$"
sn_C1r16c1: .ascii "C1r16c1$"
sn_C1m16c1: .ascii "C1m16c1$"
sn_C1r32c1: .ascii "C1r32c1$"
sn_C1m32c1: .ascii "C1m32c1$"
sn_D2r8c2:  .ascii "D2r8c2$"
sn_D2m8c0:  .ascii "D2m8c0$"
sn_D2r8c0:  .ascii "D2r8c0$"
sn_D3r16c2: .ascii "D3r16c2$"
sn_D3m16c0: .ascii "D3m16c0$"
sn_D3r32c2: .ascii "D3r32c2$"
sn_D3m32c2: .ascii "D3m32c2$"

d29_w:      .byte 0x0D, 0x02, 0x0B, 0x08, 0x05
/* SDIP rows: bank byte (0x80 = A, 0xC0 = B), port, xor mask; 0 ends */
sdip_tab:   .byte 0x80
            .word 0x841E
            .byte 0x02
            .byte 0x80
            .word 0x841E
            .byte 0x01
            .byte 0xC0
            .word 0x841E
            .byte 0x02
            .byte 0xC0
            .word 0x841E
            .byte 0x01
            .byte 0xC0
            .word 0x851E
            .byte 0x10
            .byte 0x80
            .word 0x861E
            .byte 0x80
            .byte 0xC0
            .word 0x861E
            .byte 0x80
            .byte 0
/* CAL: the BASE (10:00:00, 10 Oct 2010, weekday 1) and the patterns, wire order sec min hour
 * day mon|wday year; the month is the high nibble's VALUE (1..C), the weekday the low nibble. */
cal_base:   .byte 0x00, 0x00, 0x10, 0x10, 0xA1, 0x10
cal_pat:    .byte 0x58, 0x59, 0x23, 0x31, 0xC5, 0x99   /* P0 valid: rolls to 2000-01-01 */
            .byte 0x5A, 0x30, 0x12, 0x15, 0x63, 0x20   /* P1 sec 5A */
            .byte 0x3F, 0x30, 0x12, 0x15, 0x63, 0x20   /* P2 sec 3F */
            .byte 0x58, 0x60, 0x12, 0x15, 0x63, 0x20   /* P3 min 60 */
            .byte 0x58, 0x59, 0x24, 0x15, 0x63, 0x20   /* P4 hour 24 */
            .byte 0x58, 0x59, 0x23, 0x32, 0x63, 0x20   /* P5 day 32 */
            .byte 0x00, 0x30, 0x12, 0x00, 0x63, 0x20   /* P6 day 00 */
            .byte 0x58, 0x59, 0x23, 0x30, 0x21, 0x20   /* P7 Feb 30 */
            .byte 0x58, 0x59, 0x23, 0x28, 0x21, 0x21   /* P8 Feb 28, 2021: Mar 1 or Feb 29 */
            .byte 0x58, 0x59, 0x23, 0x2A, 0x63, 0x20   /* P9 day 2A */
            .byte 0x00, 0x30, 0x12, 0x15, 0xD3, 0x20   /* P10 month 13 */
            .byte 0x00, 0x30, 0x12, 0x15, 0x03, 0x20   /* P11 month 0 */
            .byte 0x00, 0x30, 0x12, 0x15, 0x63, 0xA0   /* P12 year A0 */
            .byte 0x00, 0x30, 0x12, 0x15, 0x67, 0x20   /* P13 weekday 7 */
            .byte 0xEE

    .balign 4
mpu_t0:     .long 0
mpu_stamp:  .space 4 * NFD
cal_last:   .long 0
cal_el:     .long 0
sal_v:      .long 0
sal_mem:    .long 0
sal_r6:     .long 0
sal_r4:     .long 0
sal_k:      .word 0
sal_i:      .word 0
sal_fout:   .word 0
sal_f6:     .word 0
sal_f4:     .word 0
mpu_n:      .word 0
cal_secs:   .word 0
sel:        .byte 0
imr_m:      .byte 0
imr_s:      .byte 0
rt_was:     .byte 0
rt_wrote:   .byte 0
rt_got:     .byte 0
rt_back:    .byte 0
nmx_bank:   .byte 0
nmx_dh0:    .byte 0
nmx_idok:   .byte 0
nmx_idst:   .byte 0
nmx_r1:     .space 9
nmx_r2:     .space 9
mpu_v:      .byte 0
mpu_rst:    .byte 0
mpu_ack:    .byte 0
mpu_oth:    .byte 0
mpu_tmo:    .byte 0
d29_r:      .space 8
cal_t0:     .space 6
cal_t1:     .space 6
cal_r0:     .space 6
cal_r1:     .space 6
cal_r2:     .space 6
cal_rs:     .space 6
    .balign 2
id_buf:     .space 512
