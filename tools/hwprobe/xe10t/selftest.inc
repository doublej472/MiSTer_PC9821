/* selftest.inc - /SELFTEST (R20) and /DRY.
 *
 * /SELFTEST, with no device access beyond the timers (read) and port 0x5F (written, the
 * documented wait port): the CRC-16/CRC-32 known vectors, the sorter, the image CRC
 * against the build stamp, the code generator over EVERY case of EVERY table at every
 * nop count (the control must equal the body with the access removed, R3, and fit its
 * buffer), then the harness itself against a synthetic device - main RAM in place of
 * VRAM, port 0x5F in place of a device port - so the arithmetic and the row path are
 * exercised before any device section runs.
 *
 * /DRY prints the plan: every selected section (all when none is), the ports and
 * memory it writes, and every case it would time. Nothing is run.
 */
st_vec:     .ascii "123456789"
st_sort:    .long 5, 3, 9, 1, 7

sec_selftest:
    mov     si, offset nm_selftest
    mov     eax, WD_20S
    mov     bx, offset st_exit
    call    sec_begin
    /* CRC-16/CCITT-FALSE("123456789") = 29B1 */
    mov     ax, 0xFFFF
    mov     si, offset st_vec
    mov     cx, 9
1:  mov     bl, byte ptr [si]
    call    crc16_step_bl
    inc     si
    loop    1b
    mov     si, offset sn_crc16
    cmp     ax, 0x29B1
    call    self_line
    /* CRC-32("123456789") = CBF43926 */
    push    dword ptr [run_crc]
    mov     dword ptr [run_crc], 0xFFFFFFFF
    mov     si, offset st_vec
    mov     cx, 9
2:  mov     al, byte ptr [si]
    call    crc32_step
    inc     si
    loop    2b
    mov     eax, dword ptr [run_crc]
    pop     dword ptr [run_crc]
    not     eax
    mov     si, offset sn_crc32
    cmp     eax, 0xCBF43926
    call    self_line
    /* the sorter, through the rep array */
    push    word ptr [reps]
    mov     word ptr [reps], 5
    mov     si, offset st_sort
    mov     di, A_ART
    mov     cx, 10
    push    es
    push    cs
    pop     es
    rep     movsw
    pop     es
    mov     bx, A_ART
    call    sort_arr
    pop     word ptr [reps]
    mov     eax, dword ptr [A_ART]
    cmp     eax, 1
    jne     3f
    mov     eax, dword ptr [A_ART + 8]
    cmp     eax, 5
    jne     3f
    mov     eax, dword ptr [A_ART + 16]
    cmp     eax, 9
3:  mov     si, offset sn_sort
    call    self_line
    /* the image against the build stamp */
    call    img_crc
    mov     dword ptr [st_tmp], eax
    cmp     dword ptr [stamp_crc], 0x30303030
    jne     4f
    PS      "SELF IMAGE SKIP unstamped"
    call    out_nl
    jmp     5f
4:  mov     si, offset stamp_crc
    call    hex8_parse
    cmp     eax, dword ptr [st_tmp]
    mov     si, offset sn_image
    call    self_line
5:  /* the generator over every table */
    call    gen_check
    /* the synthetic device */
    cmp     word ptr [buf_seg], 0
    jne     6f
    mov     si, offset rs_nobuf
    call    skip_line
    jmp     st_exit
6:  mov     si, offset tab_selftest
    call    run_list
    /* the watchdog: a 1 s deadline poll under a 50 ms section budget must be cut short by
     * WATCHDOG, unwound to st_exit, and the run must go on (the decoder accepts a WATCHDOG
     * inside SELFTEST only when this SELF line follows it) */
    call    artic_read
    mov     dword ptr [wd_t0], eax
    mov     dword ptr [wd_len], 15360
    mov     byte ptr [st_wdtest], 1
    mov     eax, T_1S
    call    dl_start
7:  call    dl_check
    jnc     7b
    mov     byte ptr [st_wdtest], 2     /* the deadline won: the watchdog did not fire */
st_exit:
    call    sec_disarm
    cmp     byte ptr [st_wdtest], 0
    je      8f
    mov     si, offset sn_wd
    cmp     byte ptr [st_wdtest], 1
    call    self_line
    mov     byte ptr [st_wdtest], 0
8:  call    sec_end
    ret

/* self_line: SI = name, ZF = pass. Prints `SELF <name> OK|FAIL`. */
self_line:
    pushf
    PS      "SELF "
    call    out_s
    popf
    jne     1f
    PS      " OK"
    jmp     2f
1:  PS      " FAIL"
    mov     byte ptr [sec_fault], 1
2:  jmp     out_nl

/* hex8_parse: 8 ASCII hex digits at SI -> EAX */
hex8_parse:
    push    cx
    push    si
    xor     eax, eax
    mov     cx, 8
1:  shl     eax, 4
    mov     dl, byte ptr [si]
    sub     dl, '0'
    cmp     dl, 9
    jbe     2f
    sub     dl, 7
2:  and     dl, 15
    or      al, dl
    inc     si
    loop    1b
    pop     si
    pop     cx
    ret

/* gen_check: every case of every table (and the selftest's) at every nop count of the
 * sweep: body and control generated, shell CRCs equal, both inside GEN_MAX. */
gen_check:
    pushad
    mov     dword ptr [st_cases], 0
    mov     dword ptr [st_bad], 0
    mov     si, offset tl_selftest
    call    gen_check_list
    mov     bx, offset sec_tab
1:  cmp     word ptr [bx], 0
    je      2f
    mov     si, word ptr [bx+6]
    call    gen_check_list
    add     bx, SECT_SIZE
    jmp     1b
2:  PS      "SELF GEN cases="
    mov     eax, dword ptr [st_cases]
    call    out_d
    PS      " bad="
    mov     eax, dword ptr [st_bad]
    call    out_d
    cmp     dword ptr [st_bad], 0
    jne     3f
    PS      " OK"
    jmp     4f
3:  PS      " FAIL"
    mov     byte ptr [sec_fault], 1
4:  call    out_nl
    popad
    ret

gen_check_list:                         /* SI = list of table pointers, 0-terminated */
    push    bx
    push    si
1:  mov     di, word ptr [si]
    test    di, di
    jz      9f
    push    si
    mov     si, di
2:  cmp     word ptr [si], 0
    je      8f
    mov     bx, offset sweep_ks
3:  movzx   ax, byte ptr [bx]
    cmp     al, 0xFF
    je      7f
    mov     word ptr [cur_k], ax
    inc     dword ptr [st_cases]
    mov     di, GEN_CTL
    mov     al, 0
    call    gen_code
    jc      5f
    mov     dx, ax
    mov     di, GEN_BODY
    mov     al, 1
    call    gen_code
    jc      5f
    cmp     ax, dx
    je      6f
5:  inc     dword ptr [st_bad]
    PS      "SELF GENCASE FAIL tag="
    push    si
    mov     si, word ptr [si+CD_TAG]
    call    out_s
    pop     si
    movzx   eax, word ptr [cur_k]
    push    si
    mov     si, offset k_nop
    call    out_kd
    pop     si
    call    out_nl
6:  test    word ptr [si+CD_FLAGS], CF_SWEEP
    jz      7f
    inc     bx
    jmp     3b
7:  add     si, CD_SIZE
    jmp     2b
8:  pop     si
    add     si, 2
    jmp     1b
9:  pop     si
    pop     bx
    ret

/* ---- the synthetic device: main RAM (the buffer) and port 0x5F ---- */
TPL st_set_ram, "mov ax, word ptr [buf_seg]; mov es, ax; xor di, di; xor ax, ax"
TPL st_w16,     "mov word ptr es:[di], ax"
TPL st_r16,     "mov bx, word ptr es:[di]"
TPL st_adv2,    "add di, 2"
TPL st_nil,     ""
TPL st_set_5f,  "mov dx, 0x5F; xor al, al"
TPL st_out,     "out dx, al"

tab_selftest:
    CASE "RAMW16", "w", 8192, 1024, 8, st_set_ram, st_w16, st_adv2, st_nil, CF_SWEEP | CF_BUF
    CASE "RAMR16", "w", 8192, 1024, 8, st_set_ram, st_r16, st_adv2, st_nil, CF_BUF
    CASE "W5F",    "io", 1024, 128, 8, st_set_5f, st_out, st_nil, st_nil, 0
    ENDTAB
tl_selftest: .word tab_selftest, 0

/* ======================================================================== DRY */
sec_dry:
    mov     si, offset nm_dry
    mov     eax, WD_10S
    mov     bx, offset dry_exit
    call    sec_begin
    mov     si, offset k_PLAN
    call    info_start
    PS      "always ID CAL RESTORE touches=0x9A0(query) 0x7C=0 0xA6=0 (RESTORE defaults)"
    call    out_nl
    mov     bx, offset sec_tab
1:  cmp     word ptr [bx], 0
    je      dry_gen
    mov     cx, word ptr [bx+8]
    mov     eax, 1
    shl     eax, cl
    cmp     dword ptr [sel_mask], 0
    je      2f
    test    dword ptr [sel_mask], eax
    jz      5f
2:  mov     si, offset k_PLAN
    call    out_s
    mov     si, word ptr [bx]
    call    out_s
    PS      " touches="
    mov     si, word ptr [bx+4]
    call    out_s
    call    out_nl
    mov     si, word ptr [bx+6]         /* the table list */
3:  mov     di, word ptr [si]
    test    di, di
    jz      5f
4:  cmp     word ptr [di], 0
    je      45f
    push    si
    mov     si, offset k_PLAN
    call    out_s
    mov     si, word ptr [bx]
    call    out_s
    PS      " case="
    mov     si, word ptr [di+CD_TAG]
    call    out_s
    PS      " unit="
    mov     si, word ptr [di+CD_UNIT]
    call    out_s
    mov     eax, dword ptr [di+CD_N]
    mov     si, offset k_n
    call    out_kd
    movzx   eax, word ptr [di+CD_FLAGS]
    PS      " flags="
    call    out_x2
    call    out_nl
    pop     si
    add     di, CD_SIZE
    jmp     4b
45: add     si, 2
    jmp     3b
5:  add     bx, SECT_SIZE
    jmp     1b
dry_gen:
    call    gen_check
dry_exit:
    call    sec_disarm
    call    sec_end
    ret

k_PLAN:     .asciz "PLAN "
sn_crc16:   .asciz "CRC16"
sn_crc32:   .asciz "CRC32"
sn_sort:    .asciz "SORT"
sn_image:   .asciz "IMAGE"
sn_wd:      .asciz "WATCHDOG"
    VARS
    .p2align 2
st_tmp:     .long 0
st_cases:   .long 0
st_bad:     .long 0
st_wdtest:  .byte 0
    ENDVARS
