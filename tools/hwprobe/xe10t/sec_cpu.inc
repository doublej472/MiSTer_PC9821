/* sec_cpu.inc - /CPU: the CPU's own rates and main RAM (read-only apart from the buffer).
 *
 * Gap: the core's CPU runs about 0.75-0.8x the machine's (the WIPE W1 ALU row, 80 ns per
 * 8-clock iteration) and the CPU has never been identified (ID prints CPUID). Each row is
 * one instruction group with its own generated control, so a row's net is that group in
 * this loop shape (R2: no row is derived from another). The ALU4I row is W1's body (four
 * independent 8-bit adds); its GROSS per unit includes the loop shell, as W1's did.
 * Main RAM rows are reported only (the policy prices no main-RAM latency).
 * INT n uses vector 0xF5, hooked to an IRET for this section and restored (RESTORE line).
 */
TPL c_nil,      ""
TPL c_add4d,    "add eax, ebx; add eax, ebx; add eax, ebx; add eax, ebx"
TPL c_add4i,    "add al, 1; add bl, 1; add dl, 1; add ah, 1"
TPL c_set_mul,  "mov eax, 3; mov ebx, 5"
TPL c_imul16,   "imul bx"
TPL c_imul32,   "imul ebx"
TPL c_set_div,  "mov ebx, 7; xor edx, edx; mov eax, 1000"   /* acc runs before adv */
TPL c_pre_d16,  "xor dx, dx; mov ax, 1000"
TPL c_idiv16,   "idiv bx"
TPL c_pre_d32,  "xor edx, edx; mov eax, 100000"
TPL c_idiv32,   "idiv ebx"
TPL c_rcl,      "rcl eax, 1"
TPL c_rcr,      "rcr eax, 1"
TPL c_set_si,   "mov si, offset scratch"
TPL c_load,     "mov ebx, dword ptr [si]"
TPL c_store,    "mov dword ptr [si], ebx"
TPL c_set_seg,  "mov ax, ds"
TPL c_segld,    "mov es, ax"
TPL c_pushpop,  "push eax; pop eax"
TPL c_calln,    "call word ptr [stub_np]"
TPL c_callf,    ".byte 0xFF, 0x1E; .word stub_fp"
TPL c_cx2,      "mov cx, 2"
TPL c_loop,     "loop 2f; 2:"
TPL c_decjnz,   "dec cx; jnz 2f; 2:"
TPL c_int,      "int 0xF5"
TPL c_pushfpopf, "pushf; popf"
TPL c_cli,      "cli"
TPL c_sticli,   "sti; cli"
TPL c_set_st4k, "mov ax, word ptr [buf_seg]; mov es, ax; xor eax, eax; xor di, di; mov cx, 1024"
TPL c_pre_st4k, "xor di, di; mov cx, 1024"
TPL c_repstosd, "rep stosd"
TPL c_set_mv4k, "mov ax, word ptr [buf_seg]; push ds; mov es, ax; mov ds, ax; xor si, si; mov di, 0x1000; mov cx, 1024"
TPL c_set_mv32k, "mov ax, word ptr [buf_seg]; push ds; mov es, ax; mov ds, ax; xor si, si; mov di, 0x8000; mov cx, 8192"
TPL c_pre_mv4k, "xor si, si; mov di, 0x1000; mov cx, 1024"
TPL c_repmovsd, "rep movsd"
TPL c_pre_mv32k, "xor si, si; mov di, 0x8000; mov cx, 8192"
TPL c_post_ds,  "pop ds"
TPL c_set_256k, "mov bx, word ptr [buf_seg]; mov es, bx; xor di, di; mov cx, 16384; xor eax, eax"
TPL c_adv_256k, "add bx, 0x1000; mov es, bx; xor di, di; mov cx, 16384"
TPL c_set_chase, "mov fs, word ptr [buf_seg]; xor si, si"
TPL c_chase,    "mov si, word ptr fs:[si]"
TPL c_set_mix,  "mov si, offset scratch; xor bx, bx; mov dx, 1"
TPL c_mix,      "mov ax, word ptr [si]; add ax, bx; cmp ax, dx; jne 2f; inc dx; 2: mov word ptr [si+4], ax; inc bx; shl dx, 1; and dx, 0x0FFF"

tab_cpu:
    CASE "ALU4D",   "4ins",  65536, 65536, 1, c_nil,     c_add4d,  c_nil,     c_nil
    CASE "ALU4I",   "4ins",  65536, 65536, 1, c_nil,     c_add4i,  c_nil,     c_nil
    CASE "IMUL16",  "ins",   16384, 4096,  4, c_set_mul, c_imul16, c_nil,     c_nil
    CASE "IMUL32",  "ins",   16384, 4096,  4, c_set_mul, c_imul32, c_nil,     c_nil
    CASE "IDIV16",  "ins",   8192,  2048,  4, c_set_div, c_idiv16, c_pre_d16, c_nil
    CASE "IDIV32",  "ins",   8192,  2048,  4, c_set_div, c_idiv32, c_pre_d32, c_nil
    CASE "RCL",     "ins",   32768, 4096,  8, c_nil,     c_rcl,    c_nil,     c_nil
    CASE "RCR",     "ins",   32768, 4096,  8, c_nil,     c_rcr,    c_nil,     c_nil
    CASE "LOAD32",  "ins",   32768, 4096,  8, c_set_si,  c_load,   c_nil,     c_nil
    CASE "STORE32", "ins",   32768, 4096,  8, c_set_si,  c_store,  c_nil,     c_nil
    CASE "SEGLD",   "ins",   32768, 4096,  8, c_set_seg, c_segld,  c_nil,     c_nil
    CASE "PUSHPOP", "pair",  16384, 2048,  8, c_nil,     c_pushpop, c_nil,    c_nil
    CASE "CALLN",   "call",  16384, 4096,  4, c_nil,     c_calln,  c_nil,     c_nil
    CASE "CALLF",   "call",  8192,  2048,  4, c_nil,     c_callf,  c_nil,     c_nil
    CASE "LOOP",    "ins",   32768, 4096,  8, c_nil,     c_loop,   c_cx2,     c_nil
    CASE "DECJNZ",  "pair",  32768, 4096,  8, c_nil,     c_decjnz, c_cx2,     c_nil
    CASE "INTIRET", "int",   4096,  1024,  4, c_nil,     c_int,    c_nil,     c_nil
    CASE "PUSHFPOPF", "pair", 16384, 2048, 8, c_nil,     c_pushfpopf, c_nil,  c_nil
    CASE "CLI",     "ins",   32768, 4096,  8, c_nil,     c_cli,    c_nil,     c_nil
    CASE "STICLI",  "pair",  32768, 4096,  8, c_nil,     c_sticli, c_nil,     c_nil
    CASE "MIX",     "grp",   16384, 4096,  4, c_set_mix, c_mix,    c_nil,     c_nil
    CASE "STOSD4K", "4KiB",  16,    16,    1, c_set_st4k, c_repstosd, c_pre_st4k, c_nil, CF_BUF
    CASE "MOVSD4K", "4KiB",  16,    16,    1, c_set_mv4k,  c_repmovsd, c_pre_mv4k, c_post_ds, CF_BUF
    CASE "MOVSD32K", "32KiB", 4,    4,     1, c_set_mv32k,  c_repmovsd, c_pre_mv32k, c_post_ds, CF_BUF
    CASE "STOSD256K", "64KiB", 4,   1,     4, c_set_256k, c_repstosd, c_adv_256k, c_nil, CF_BUF
    CASE "CHASE64", "load",  16384, 2048,  8, c_set_chase, c_chase, c_nil,    c_nil, CF_BUF
    ENDTAB
tl_cpu:     .word tab_cpu, 0
tc_cpu:     .asciz "IVT[F5](hooked,restored) RAM-buffer"

stub_ret:   ret
stub_retf:  retf
stub_iret:  iret
stub_np:    .word stub_ret
n_vecf5:    .asciz "VECF5"
    VARS
stub_fp:    .word stub_retf, 0
    .p2align 2
cpu_vsave:  .long 0
    ENDVARS

sec_cpu:
    mov     si, offset nm_cpu
    mov     eax, WD_20S
    mov     bx, offset cpu_exit
    call    sec_begin
    mov     si, offset k_STATE
    call    info_start
    PS      "cli=1 int=F5"
    call    out_nl
    mov     word ptr [stub_fp+2], cs
    /* the INT 0xF5 vector -> IRET */
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     eax, dword ptr es:[0xF5*4]
    mov     dword ptr [cpu_vsave], eax
    mov     word ptr es:[0xF5*4], offset stub_iret
    mov     word ptr es:[0xF5*4+2], cs
    sti
    pop     es
    /* the stride-64 chain over the buffer's first 64 KiB */
    cmp     word ptr [buf_seg], 0
    je      2f
    push    es
    mov     es, word ptr [buf_seg]
    xor     di, di
1:  lea     ax, [di+64]
    mov     word ptr es:[di], ax
    add     di, 64
    jnz     1b
    pop     es
2:  mov     si, offset tab_cpu
    call    run_list
cpu_exit:
    call    sec_disarm
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     eax, dword ptr [cpu_vsave]
    mov     dword ptr es:[0xF5*4], eax
    mov     edx, dword ptr es:[0xF5*4]
    sti
    pop     es
    mov     si, offset n_vecf5
    mov     cx, 0x0208
    mov     bl, 3
    call    rs_line
    call    sec_end
    ret
