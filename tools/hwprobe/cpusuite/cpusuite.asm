; cpusuite.asm - CPUSUITE.COM: run z486's own self-checking CPU test programs on a PC-98, from DOS.
;
; WHAT IT RUNS. The pack CPUSUITE.BIN that tools/hwprobe/cpusuite/gen_cpusuite.py builds from
; src/z486/tests/programs/: each program re-assembled with prelude.inc, its memory image (page
; tables + code, exactly the bench's layout) and the state tb_protected_mode.sv starts it in.
;
; HOW ONE PROGRAM RUNS. The program owns physical 0-0x7FFFF (the bench's 512 KiB), so all of DOS
; that lives below 0x9F000 is moved out of the way first and put back afterwards:
;   1. the COM masks both 8259s, saves port C (0x35), and moves the engine page 0x9F000-0x9FFFF to
;      the save block (XMS), copies the ENGINE (section .eng below) there and jumps to it;
;   2. the engine (protected mode, flat) saves 0-0x9EFFF to the save block, zeroes 0-0x7FFFF,
;      copies the program's image in, stores the CPU-reset return SS:SP at 0000:0404, clears
;      SHUT0 (port 0x37 BSR 0x0E), and enters the program in the bench's start state;
;   3. the program's verdict write is THE TRAP (prelude.inc): ~AL into the slave 8259's mask
;      (port 0x0A), then `out 0xF0` - the PC-98 CPU-only reset;
;   4. THE RETURN: with SHUT0 clear the firmware's reset entry (BIOS-top bank, F000:FFF0 ->
;      FD80:0000) does `mov ss,[0x406] / mov sp,[0x404]` and RETFs (0x43F/CR0 cache handling in
;      between), which lands in the engine; it reads the mask, restores 0-0x9EFFF from the save
;      block and returns to the COM, which restores the engine page, the masks, port C, and
;      writes the verdict. A program that triple-faults returns the same way, with the mask
;      still 0xFF: that is the verdict of the two programs the bench expects to triple-fault.
;   A program that hangs (a HLT with IF=0, a loop) hangs the machine: the line naming it is
;   already in the result file (committed before the program starts) with no verdict.
;
; FAILURE DETAIL. prelude.inc keeps the program's last DATA_PORT (0xE4) write - the whole EAX at
; that OUT - in DMA channel 1's address/count registers and the EAX the verdict trap was entered
; with in channel 0's (prelude.inc, "THE DETAIL REGISTERS": a CPU reset clears every register but
; EDX). Before each program the COM saves DOS's values of both channels and writes the sentinel
; DETAIL_NONE; after it, it reads them back and restores DOS's. A FAIL row ends
; " data=xxxxxxxx|none eax=xxxxxxxx" (eax only when the trap ran). At start the COM checks that
; the four registers read back what is written; if not, the CPU row says detail=none and the
; FAIL rows carry no detail.
;
; CPU IDENTITY. After a CPU reset EDX holds the processor's component ID (Intel486: DH = 04h the
; family, DL = model and stepping; other vendors' 486s differ), and the firmware's CPU-reset
; return does not touch EDX before its RETF into the engine (BANK7.BIN@0x5804-0x5817, FD80:0004:
; `xor ax,ax / mov ds,ax / in al,0x35 / test al,0x80 / jnz / mov ss,[0x406] / mov sp,[0x404] /
; jmp 0x644`; FD80:0644 reloads SS:SP and jumps to FD80:0780, which `push eax / push dx /
; mov dx,0x43f / mov al,0xa0 / out dx,al / pop dx`, rewrites CR0 (CD/NW cleared unless 0x596
; bit 3, NE set), `pop eax` and jumps to the `retf` at FD80:001A), so the engine's landing
; stores EDX first thing. Before the first
; program the COM does one reset round trip of its own (no program: the engine saves DOS and
; resets) and writes, after BEGIN:
;   CPUSUITE CPU ac=0|1 cpuid=none|<vendor>/<leaf-1 EAX> bda486=xxxx detail=dma|none resetdx=xxxxxxxx
; ac: EFLAGS.AC (bit 18) can be toggled (a 486 or later; a 386 cannot); cpuid: EFLAGS.ID (bit 21)
; can be toggled, so CPUID exists (later 486 steppings), and what leaves 0 and 1 return;
; bda486: the word at 0000:0486, where the firmware's own boot-time reset stores DX
; (BANK7.BIN@0x5878, FD80:0078 `mov [0x486],dx`); resetdx: EDX after the round trip. The
; reset's EDX after every program is compared with it, and a row ends " resetdx=xxxxxxxx" only
; when it differs (it then becomes the value compared with).
;
; USAGE    CPUSUITE [/P:n] [/A] [/FROM:name] [/SKIP:name ...] [name]
;   /P:n        run the whole pack n times (a stress loop; default 1); /Pn is the same
;   /FROM:name  start at the program of that name: the ones before it are not run and get no row
;               (resuming after a lock-up). Only the first pass starts there; later passes of /P:n
;               run the whole pack
;   /SKIP:name  do not run that program; it gets the row "<name> SKIP". Up to MAX_SKIP (16), each
;               with its own /SKIP
;   /A          append to CPUSUITE.TXT instead of replacing it
;   name        run only the program of that name
;   A switch's value follows ':' or '=' (as COMMAND.COM splits a switch) or blanks: /SKIP:x,
;   /SKIP=x and /SKIP x are the same. Switches are case-blind; names are matched lower-cased. A
;   /FROM or /SKIP name the pack does not hold stops CPUSUITE before it writes anything.
; Writes CPUSUITE.TXT in the current directory: "<name> PASS|FAIL <why>" per program and a final
; "CPUSUITE END PASSES=n RUN=r PASS=p FAIL=f", with " SKIP=s" appended when s > 0 programs were
; skipped. /FROM, /SKIP and /A APPEND to an existing CPUSUITE.TXT (a CR LF first, which ends the
; name row a lock-up left without a verdict, then a new BEGIN row with " FROM=name" appended when
; /FROM is given), so the first run's rows are kept; without them the file is replaced. Resuming
; after a lock-up in program X: CPUSUITE /FROM:X /SKIP:X. Needs an XMS driver (HIMEM.SYS) and NO
; EMM386 (virtual 8086 mode cannot run a program that enters protected mode itself).
;
; PACK FORMAT (little-endian; gen_cpusuite.py record()):
;   0   "CPUSUIT1"   8   u32 count   12  u32 offset of the first record (16)
;   records, 128 bytes each:
;     0  name (NUL-padded, 40)   40 u32 data offset  44 u32 data length  48 u8 mode (0 real, 1 prot)
;     49 u8 flags (bit 0: passes by triple-faulting)  50 u16 null-selector mask (bit = sreg number)
;     52 u32 CR0  56 u32 CR3  60 u32 EIP  64 u16 selectors ES,CS,SS,DS,FS,GS  76 6 descriptors
;   data: {u32 physical address, u32 length, bytes, pad to 4}..., {0, 0}
;
; Build: make -C tools/hwprobe cpusuite/cpusuite.com (nasm; the z486 suite's own assembler).

        cpu 486
        org 0x100

ENG             equ 0x9F000             ; the engine page (gen_cpusuite.py ENG_PHYS)
ENGSEG          equ ENG >> 4
SAVE_BYTES      equ 0xA0000             ; 0-0x9FFFF
DETAIL_NONE     equ 0xA5A5A5A5          ; the detail registers' value when nothing was recorded
SEL_C32         equ 0x08                ; the engine's GDT
SEL_D32         equ 0x10
SEL_C16         equ 0x18
SEL_D16         equ 0x20
REC_SIZE        equ 128
MAX_SKIP        equ 16                  ; /SKIP names
NAME_LEN        equ 40                  ; a name buffer: up to 39 characters and the NUL
; STAGE MARKS: each step of one program's run writes a letter into text VRAM, row 0, columns
; 72-78 (cleared by the COM before each program), so a screenshot or the userdisk tier's TRAM dump
; of a machine that did not come back shows how far it got:
;   E engine entered   S DOS saved   I image loaded   J jumping into the program
;   L landed after the CPU reset   R DOS restored   B back in the COM
TVRAM           equ 0xA0000
STG_COL         equ 72 * 2
%macro STAGE16 2        ; column, letter (real mode; uses the stack)
        push    es
        push    word TVRAM >> 4
        pop     es
        mov     word [es:STG_COL + 2 * %1], %2
        mov     byte [es:0x2000 + STG_COL + 2 * %1], 0xE1
        pop     es
%endmacro
%macro STAGE32 2        ; column, letter (flat DS)
        mov     word [TVRAM + STG_COL + 2 * %1], %2
        mov     byte [TVRAM + 0x2000 + STG_COL + 2 * %1], 0xE1
%endmacro
R_MODE          equ 48
R_FLAGS         equ 49
R_NULL          equ 50
R_CR0           equ 52
R_CR3           equ 56
R_EIP           equ 60
R_SEL           equ 64
R_DESC          equ 76

section .text

start:
        cld
        mov     dx, s_banner
        call    puts
        ; the COM's 64 KiB must lie below the engine page
        mov     ax, cs
        cmp     ax, ENGSEG - 0x1000
        jb      .low_ok
        mov     dx, s_toohigh
        jmp     die
.low_ok:
        call    parse_args
        ; ---- XMS
        mov     ax, 0x4300
        int     0x2F
        cmp     al, 0x80
        je      .xms_ok
        mov     dx, s_noxms
        jmp     die
.xms_ok:
        push    es
        mov     ax, 0x4310
        int     0x2F
        mov     [xms_entry], bx
        mov     [xms_entry+2], es
        pop     es
        ; ---- V86 mode (EMM386) cannot run the programs
        smsw    ax
        test    al, 1
        jz      .real_ok
        mov     dx, s_v86
        jmp     die
.real_ok:
        call    cpu_ident
        call    dma_check
        push    word 0                  ; the BDA word, through FS = 0
        pop     fs
        mov     ax, [fs:0x486]
        mov     [bda486], ax
        ; ---- the pack: open, size, read into XMS
        mov     ax, 0x3D00
        mov     dx, s_packname
        int     0x21
        jnc     .open_ok
        mov     dx, s_nopack
        jmp     die
.open_ok:
        mov     [fh_pack], ax
        mov     bx, ax
        mov     ax, 0x4202              ; size = seek to end
        xor     cx, cx
        xor     dx, dx
        int     0x21
        mov     [pack_size], ax
        mov     [pack_size+2], dx
        mov     ax, 0x4200
        mov     bx, [fh_pack]
        xor     cx, cx
        xor     dx, dx
        int     0x21
        ; allocate: the pack (KiB, rounded up) and the 640 KiB save block
        mov     eax, [pack_size]
        add     eax, 1023
        shr     eax, 10
        mov     dx, ax
        call    xms_alloc
        mov     [h_pack], dx
        mov     [lin_pack], eax
        mov     dx, SAVE_BYTES >> 10
        call    xms_alloc
        mov     [h_save], dx
        mov     [lin_save], eax
        ; read the file in 32 KiB pieces, each moved into the pack block
        mov     dword [rd_off], 0       ; offset in the pack
.rd:
        mov     ah, 0x3F
        mov     bx, [fh_pack]
        mov     cx, 0x8000
        mov     dx, iobuf
        int     0x21
        jc      .rd_err
        test    ax, ax
        jz      .rd_done
        movzx   ecx, ax
        inc     ecx
        and     cl, 0xFE                ; XMS moves an even length
        mov     [xm_len], ecx
        mov     word [xm_sh], 0
        mov     word [xm_so], iobuf
        mov     [xm_so+2], ds
        mov     ax, [h_pack]
        mov     [xm_dh], ax
        mov     eax, [rd_off]
        mov     [xm_do], eax
        call    xms_move
        movzx   eax, word [xm_len]
        add     [rd_off], eax
        jmp     .rd
.rd_err:
        mov     dx, s_readerr
        jmp     die
.rd_done:
        mov     ah, 0x3E
        mov     bx, [fh_pack]
        int     0x21
        ; header
        xor     eax, eax
        mov     ebx, rec
        mov     ecx, 16
        call    pack_get
        cmp     dword [rec], 'CPUS'
        jne     .badpack
        cmp     dword [rec+4], 'UIT1'
        je      .pack_ok
.badpack:
        mov     dx, s_badpack
        jmp     die
.pack_ok:
        mov     eax, [rec+8]
        mov     [count], eax
        call    check_names
        ; ---- A20: on now (DOS=HIGH) if 0000:0000 and FFFF:0010 differ
        push    ds
        push    es
        xor     si, si
        mov     ds, si
        mov     di, 0x10
        mov     ax, 0xFFFF
        mov     es, ax
        mov     cx, 32
        repe    cmpsw
        pop     es
        pop     ds
        setne   byte [a20_on]
        ; DOS's CR0, restored after every program
        mov     eax, cr0
        mov     [dos_cr0], eax
        ; ---- the result file: appended to (/A, /FROM, /SKIP) or replaced
        cmp     byte [append], 0
        je      .create
        mov     ax, 0x3D01              ; open, write-only
        mov     dx, s_outname
        int     0x21
        jc      .create                 ; none yet
        mov     [fh_out], ax
        mov     bx, ax
        mov     ax, 0x4202              ; to its end
        xor     cx, cx
        xor     dx, dx
        int     0x21
        mov     si, s_crlf              ; ends a row a lock-up left without a verdict
        call    out_str
        jmp     .out_hdr
.create:
        mov     ah, 0x3C
        xor     cx, cx
        mov     dx, s_outname
        int     0x21
        jnc     .out_ok
        mov     dx, s_noout
        jmp     die
.out_ok:
        mov     [fh_out], ax
.out_hdr:
        mov     si, s_hdr
        call    out_str
        mov     eax, [count]
        call    out_dec
        mov     si, s_hdr2
        call    out_str
        movzx   eax, word [passes]
        call    out_dec
        cmp     byte [from_name], 0
        je      .hdr_end
        mov     si, s_hdr_from
        call    out_str
        mov     si, from_name
        call    out_str
.hdr_end:
        mov     si, s_crlf
        call    out_str
        ; ---- the CPU row: what the COM can see, committed, then one reset round trip for EDX
        mov     si, s_cpu
        call    out_str
        mov     al, [has_ac]
        add     al, '0'
        mov     [numbuf], al
        mov     byte [numbuf+1], 0
        mov     si, numbuf
        call    out_str
        mov     si, s_cpu_id
        call    out_str
        cmp     byte [has_id], 0
        jne     .cpuid
        mov     si, s_none
        call    out_str
        jmp     .cpu_bda
.cpuid: mov     si, cpu_vendor
        call    out_str
        mov     si, s_slash
        call    out_str
        mov     eax, [cpu_sig]
        call    out_hex8
.cpu_bda:
        mov     si, s_cpu_bda
        call    out_str
        mov     ax, [bda486]
        xchg    al, ah
        call    out_hex2
        mov     al, [bda486]
        call    out_hex2
        mov     si, s_cpu_detail
        cmp     byte [dma_ok], 0
        jne     .cpu_dma
        mov     si, s_cpu_nodetail
.cpu_dma:
        call    out_str
        mov     si, s_cpu_reset
        call    out_str
        mov     ah, 0x68
        mov     bx, [fh_out]
        int     0x21
        mov     byte [probe], 1
        call    run_one
        mov     byte [probe], 0
        mov     eax, [last_edx]
        mov     [ref_edx], eax
        call    out_hex8
        mov     si, s_crlf
        call    out_str

; ================================================================ the loop
        mov     word [pass_no], 0
.pass:
        mov     dword [idx], 0
.next:
        mov     eax, [idx]
        cmp     eax, [count]
        jae     .pass_done
        shl     eax, 7                  ; * REC_SIZE
        add     eax, 16
        mov     ebx, rec
        mov     ecx, REC_SIZE
        call    pack_get
        cmp     byte [want], 0
        je      .take
        mov     si, rec
        mov     di, want
.cmpname:
        lodsb
        mov     ah, [di]
        inc     di
        cmp     al, ah
        jne     .skip
        test    al, al
        jnz     .cmpname
.take:
        ; /FROM: nothing runs (and no row is written) until its program, in the first pass only
        cmp     byte [from_wait], 0
        je      .from_done
        mov     di, from_name
        call    name_eq
        jne     .skip
        mov     byte [from_wait], 0
.from_done:
        ; /SKIP: a row that says so, and the program does not run
        xor     bx, bx
.skl:   cmp     bx, [nskip]
        jae     .run
        imul    di, bx, NAME_LEN
        add     di, skip_names
        call    name_eq
        je      .skiprow
        inc     bx
        jmp     .skl
.skiprow:
        mov     si, rec
        call    out_str
        mov     si, s_skip
        call    out_str
        inc     dword [nskipped]
        jmp     .skip
.run:
        ; the name, then commit: if the program hangs the machine, the file ends on its name
        mov     si, rec
        call    out_str
        mov     si, s_sp
        call    out_str
        mov     ah, 0x68
        mov     bx, [fh_out]
        int     0x21
        call    run_one                 ; -> AL = the slave 8259 mask after the program
        call    verdict
        inc     dword [ran]
.skip:
        inc     dword [idx]
        jmp     .next
.pass_done:
        inc     word [pass_no]
        mov     ax, [pass_no]
        cmp     ax, [passes]
        jb      .pass

; ================================================================ the end
        mov     si, s_end
        call    out_str
        movzx   eax, word [pass_no]
        call    out_dec
        mov     si, s_end_run
        call    out_str
        mov     eax, [ran]
        call    out_dec
        mov     si, s_end_pass
        call    out_str
        mov     eax, [npass]
        call    out_dec
        mov     si, s_end_fail
        call    out_str
        mov     eax, [nfail]
        call    out_dec
        mov     eax, [nskipped]         ; " SKIP=s" only when something was skipped
        test    eax, eax
        jz      .end_eol
        mov     si, s_end_skip
        call    out_str
        mov     eax, [nskipped]
        call    out_dec
.end_eol:
        mov     si, s_crlf
        call    out_str
        mov     ah, 0x3E
        mov     bx, [fh_out]
        int     0x21
        call    xms_release
        mov     ax, 0x4C00
        cmp     dword [nfail], 0
        je      .x
        mov     al, 1
.x:     int     0x21

; ---------------------------------------------------------------- run one program
; In: rec = its record. Out: AL = the slave 8259's mask after it ran.
run_one:
        push    es
        push    word TVRAM >> 4
        pop     es
        mov     di, STG_COL
        mov     ax, ' '
        mov     cx, 7
        rep     stosw
        pop     es
        cli
        in      al, 0x02
        mov     [imr_m], al
        in      al, 0x0A
        mov     [imr_s], al
        mov     al, 0xFF
        out     0x02, al
        out     0x0A, al
        in      al, 0x35
        mov     [portc], al
        ; the detail registers: DOS's values kept, the sentinel in
        mov     di, dma_dos
        call    dma_read
        mov     si, dma_sentinel
        call    dma_write
        ; the engine page -> save block + 0x9F000
        mov     dword [xm_len], 0x1000
        mov     word [xm_sh], 0
        mov     dword [xm_so], ENGSEG << 16
        mov     ax, [h_save]
        mov     [xm_dh], ax
        mov     dword [xm_do], ENG
        call    xms_move
        cli
        ; the engine -> 9F00:0000
        push    es
        mov     ax, ENGSEG
        mov     es, ax
        mov     si, eng_image
        xor     di, di
        mov     cx, ENG_SIZE
        rep     movsb
        ; its parameters
        mov     si, rec
        mov     di, p_rec
        mov     cx, REC_SIZE
        rep     movsb
        mov     eax, [lin_pack]
        add     eax, [rec+40]
        mov     [es:p_data], eax
        mov     eax, [lin_save]
        mov     [es:p_save], eax
        mov     word [es:p_ret], .back
        mov     [es:p_ret+2], cs
        mov     [es:p_retss], ss
        mov     ax, sp
        add     ax, 2                   ; the SP of the far jump below, after `pop es`
        mov     [es:p_retsp], ax
        mov     eax, [dos_cr0]
        mov     [es:p_cr0], eax
        mov     al, [portc]
        mov     [es:p_portc], al
        mov     al, [a20_on]
        mov     [es:p_a20], al
        mov     al, [probe]
        mov     [es:p_probe], al
        pop     es
        jmp     ENGSEG:0
.back:
        ; SS:SP are ours again; everything below 0x9F000 is as it was at the jump
        cli
        cld
        mov     bx, cs
        mov     ds, bx
        mov     es, bx
        mov     [last_imr], al
        mov     [last_edx], edx         ; EDX after the CPU reset (the engine's landing)
        mov     dword [xm_len], 0x1000
        mov     ax, [h_save]
        mov     [xm_sh], ax
        mov     dword [xm_so], ENG
        mov     word [xm_dh], 0
        mov     dword [xm_do], ENGSEG << 16
        call    xms_move
        cli
        STAGE16 6, 'B'
        mov     di, dma_rd              ; what the program left, then DOS's values back
        call    dma_read
        mov     si, dma_dos
        call    dma_write
        mov     al, [imr_m]
        out     0x02, al
        mov     al, [imr_s]
        out     0x0A, al
        sti
        mov     al, [last_imr]
        ret

; ---------------------------------------------------------------- the verdict
; In: AL = mask. The trap latched ~verdict (prelude.inc); 0xFF = no trap ran (a reset without a
; verdict: a triple fault, or another reset).
verdict:
        mov     bl, al
        test    byte [rec+R_FLAGS], 1
        jz      .normal
        cmp     bl, 0xFF
        jne     .tf_trapped
        mov     si, s_pass_tf
        jmp     .pass
.tf_trapped:
        mov     si, s_fail_tf
        jmp     .fail_v
.normal:
        cmp     bl, 0xFE
        jne     .n1
        mov     si, s_pass
.pass:
        inc     dword [npass]
        call    out_str
        jmp     .eol
.n1:
        cmp     bl, 0xFF
        jne     .n2
        mov     si, s_fail_reset
        inc     dword [nfail]
        call    out_str
        call    fail_detail
        jmp     .eol
.n2:
        mov     si, s_fail
.fail_v:
        inc     dword [nfail]
        call    out_str
        mov     al, [last_imr]
        not     al
        call    out_hex2
        call    fail_detail
.eol:
        mov     eax, [last_edx]         ; the reset signature, only when it changed
        cmp     eax, [ref_edx]
        je      .eol2
        mov     [ref_edx], eax
        mov     si, s_resetdx
        call    out_str
        mov     eax, [ref_edx]
        call    out_hex8
.eol2:
        mov     si, s_crlf
        call    out_str
        ret

; " data=xxxxxxxx|none" and, when the trap ran, " eax=xxxxxxxx" (the detail registers)
fail_detail:
        cmp     byte [dma_ok], 0
        je      .r
        mov     si, s_data
        call    out_str
        mov     eax, [dma_rd+4]
        cmp     eax, DETAIL_NONE
        jne     .hex
        mov     si, s_none
        call    out_str
        jmp     .eax
.hex:   call    out_hex8
.eax:   mov     eax, [dma_rd]
        cmp     eax, DETAIL_NONE
        je      .r
        mov     si, s_eax
        call    out_str
        mov     eax, [dma_rd]
        call    out_hex8
.r:     ret

; ---------------------------------------------------------------- the detail registers
; DMA channels 0 and 1, address and count, in the order dma_ports names (prelude.inc, "THE
; DETAIL REGISTERS"). Interrupts off: the byte flip-flop is shared.
; dma_read: DI = 8 bytes <- the registers
dma_read:
        out     0x19, al                ; clear the byte flip-flop
        mov     bx, dma_ports
        mov     cx, 8
.l:     movzx   dx, byte [bx]
        inc     bx
        in      al, dx
        stosb
        loop    .l
        ret
; dma_write: SI = 8 bytes -> the registers
dma_write:
        out     0x19, al
        mov     bx, dma_ports
        mov     cx, 8
.l:     movzx   dx, byte [bx]
        inc     bx
        lodsb
        out     dx, al
        loop    .l
        ret
; dma_ok = 1 if a pattern written reads back (DOS's values restored after)
dma_check:
        cli
        mov     di, dma_dos
        call    dma_read
        mov     si, dma_pattern
        call    dma_write
        mov     di, dma_rd
        call    dma_read
        mov     si, dma_dos
        call    dma_write
        sti
        mov     si, dma_pattern
        mov     di, dma_rd
        mov     cx, 8
        repe    cmpsb
        sete    byte [dma_ok]
        ret

; ---------------------------------------------------------------- CPU identity (real mode)
; has_ac: EFLAGS.AC toggles (486+). has_id: EFLAGS.ID toggles, so CPUID exists; then
; cpu_vendor = leaf 0's EBX:EDX:ECX and cpu_sig = leaf 1's EAX (0 when leaf 1 is absent).
cpu_ident:
        mov     ecx, 1 << 18
        call    .toggle
        mov     [has_ac], al
        mov     ecx, 1 << 21
        call    .toggle
        mov     [has_id], al
        test    al, al
        jz      .r
        xor     eax, eax
        db      0x0F, 0xA2              ; cpuid (cpu 486 has no mnemonic for it)
        mov     [cpu_vendor], ebx
        mov     [cpu_vendor+4], edx
        mov     [cpu_vendor+8], ecx
        mov     byte [cpu_vendor+12], 0
        test    eax, eax
        jz      .r
        mov     eax, 1
        db      0x0F, 0xA2              ; cpuid (cpu 486 has no mnemonic for it)
        mov     [cpu_sig], eax
.r:     ret
; ECX = one EFLAGS bit -> AL = 1 if it can be flipped; EFLAGS as it was
.toggle:
        pushfd
        pop     eax
        mov     edx, eax                ; the original
        xor     eax, ecx
        push    eax
        popfd
        pushfd
        pop     eax
        push    edx
        popfd
        xor     eax, edx
        test    eax, ecx
        setnz   al
        ret

; ---------------------------------------------------------------- XMS
; DX = KiB -> DX = handle, EAX = its locked linear address
xms_alloc:
        mov     ah, 0x09
        call    far [xms_entry]
        test    ax, ax
        jz      .err
        push    dx
        mov     ah, 0x0C
        call    far [xms_entry]
        test    ax, ax
        pop     ax                      ; the handle
        jz      .err
        push    dx
        push    bx
        pop     ebx                     ; DX:BX
        mov     dx, ax
        mov     eax, ebx
        ret
.err:
        mov     dx, s_xmserr
        jmp     die

xms_move:
        mov     ah, 0x0B
        mov     si, xm_len
        call    far [xms_entry]
        test    ax, ax
        jnz     .ok
        mov     dx, s_xmserr
        jmp     die
.ok:    ret

xms_release:
        mov     dx, [h_pack]
        call    .one
        mov     dx, [h_save]
.one:
        test    dx, dx
        jz      .r
        push    dx
        mov     ah, 0x0D
        call    far [xms_entry]
        pop     dx
        mov     ah, 0x0A
        call    far [xms_entry]
.r:     ret

; EAX = pack offset, EBX = near destination, ECX = length (even) -> bytes copied from the pack
pack_get:
        mov     [xm_len], ecx
        mov     dx, [h_pack]
        mov     [xm_sh], dx
        mov     [xm_so], eax
        mov     word [xm_dh], 0
        mov     [xm_do], bx
        mov     [xm_do+2], ds
        jmp     xms_move

; ---------------------------------------------------------------- output
; out_str: SI = NUL-terminated string -> the result file and the screen
out_str:
        push    si
        xor     cx, cx
.len:   cmp     byte [si], 0
        je      .go
        inc     si
        inc     cx
        jmp     .len
.go:    pop     dx
        jcxz    .r
        push    cx
        push    dx
        mov     ah, 0x40
        mov     bx, [fh_out]
        int     0x21
        pop     dx
        pop     cx
        mov     ah, 0x40
        mov     bx, 1
        int     0x21
.r:     ret

; EAX -> decimal
out_dec:
        mov     di, numbuf + 11
        mov     byte [di], 0
        mov     ebx, 10
.d:     xor     edx, edx
        div     ebx
        add     dl, '0'
        dec     di
        mov     [di], dl
        test    eax, eax
        jnz     .d
        mov     si, di
        jmp     out_str

; AL -> two hex digits
out_hex2:
        mov     ah, al
        shr     al, 4
        call    .nib
        mov     [numbuf], al
        mov     al, ah
        and     al, 15
        call    .nib
        mov     [numbuf+1], al
        mov     byte [numbuf+2], 0
        mov     si, numbuf
        jmp     out_str
.nib:   add     al, '0'
        cmp     al, '9'
        jbe     .n
        add     al, 7
.n:     ret

; EAX -> eight hex digits
out_hex8:
        mov     cx, 4
.l:     rol     eax, 8
        push    eax
        push    cx
        call    out_hex2
        pop     cx
        pop     eax
        loop    .l
        ret

; DX = '$'-terminated message, screen only
puts:
        mov     ah, 0x09
        int     0x21
        ret

die:
        call    puts
        call    xms_release
        mov     ax, 0x4C02
        int     0x21

; ---------------------------------------------------------------- arguments
; [/P:n] [/A] [/FROM:name] [/SKIP:name ...] [name]; see USAGE at the top
parse_args:
        mov     word [passes], 1
        mov     si, 0x81
.sk:    lodsb
        cmp     al, ' '
        je      .sk
        cmp     al, 9
        je      .sk
        cmp     al, 13
        je      .done
        cmp     al, '/'
        jne     .name
        ; the switch's letters, upper-cased, into kw (at most 4)
        mov     dword [kw], 0
        xor     bx, bx
.kw:    lodsb
        and     al, 0xDF
        cmp     al, 'A'
        jb      .kwend
        cmp     al, 'Z'
        ja      .kwend
        cmp     bx, 4
        jae     .bad
        mov     [kw+bx], al
        inc     bx
        jmp     .kw
.kwend: dec     si                      ; SI = the character after the letters
        cmp     dword [kw], 'P'
        je      .p
        cmp     dword [kw], 'A'
        je      .a
        cmp     dword [kw], 'SKIP'
        je      .skipsw
        cmp     dword [kw], 'FROM'
        je      .from
        jmp     .bad
.p:     lodsb                           ; /P:n or /Pn (a typed ':' is not safe on every keymap)
        cmp     al, ':'
        je      .pnum
        cmp     al, '='
        je      .pnum
        dec     si
.pnum:  xor     bx, bx
.num:   lodsb
        sub     al, '0'
        cmp     al, 9
        ja      .numend
        imul    bx, bx, 10
        movzx   ax, al
        add     bx, ax
        jmp     .num
.numend:
        dec     si
        test    bx, bx
        jz      .bad
        mov     [passes], bx
        jmp     .sk
.a:     mov     byte [append], 1
        jmp     .sk
.skipsw:
        mov     ax, [nskip]
        cmp     ax, MAX_SKIP
        jae     .bad
        imul    di, ax, NAME_LEN
        add     di, skip_names
        call    switch_value
        inc     word [nskip]
        mov     byte [append], 1
        jmp     .sk
.from:
        mov     di, from_name
        call    switch_value
        mov     byte [from_wait], 1
        mov     byte [append], 1
        jmp     .sk
.name:
        dec     si
        mov     di, want
        call    read_name
        jmp     .sk
.bad:
        mov     dx, s_usage
        jmp     die
.done:  ret

; SI = after a switch's letters, DI = the name buffer: the value after ':', '=' or blanks
switch_value:
        lodsb
        cmp     al, ':'
        je      read_name
        cmp     al, '='
        je      read_name
.bl:    cmp     al, ' '
        je      .nx
        cmp     al, 9
        jne     .v
.nx:    lodsb
        jmp     .bl
.v:     dec     si
        ; fall through
; SI = a name's first character, DI = its buffer (NAME_LEN): the name lower-cased, NUL-ended;
; it ends at a control character, a blank or '/'. An empty or over-long name is a usage error.
read_name:
        mov     cx, NAME_LEN
.c:     lodsb
        cmp     al, ' '
        jbe     .e
        cmp     al, '/'
        je      .e
        cmp     al, 'A'
        jb      .st
        cmp     al, 'Z'
        ja      .st
        or      al, 0x20                ; program names are lower case
.st:    dec     cx
        jz      parse_args.bad
        stosb
        jmp     .c
.e:     dec     si
        cmp     cx, NAME_LEN
        je      parse_args.bad
        mov     byte [di], 0
        ret

; DI = a NUL-ended name -> ZF set if it is the name in rec. Keeps BX.
name_eq:
        mov     si, rec
.c:     lodsb
        cmp     al, [di]
        jne     .r
        inc     di
        test    al, al
        jnz     .c
.r:     ret

; every /FROM and /SKIP name must be one of the pack's programs: a mistyped one would otherwise
; run (or skip) nothing, silently. Runs before the result file is opened.
check_names:
        mov     dword [idx], 0
.rec:   mov     eax, [idx]
        cmp     eax, [count]
        jae     .verify
        shl     eax, 7                  ; * REC_SIZE
        add     eax, 16
        mov     ebx, rec
        mov     ecx, REC_SIZE
        call    pack_get
        mov     di, from_name
        call    name_eq
        jne     .sk0
        mov     byte [from_found], 1
.sk0:   xor     bx, bx
.skl:   cmp     bx, [nskip]
        jae     .nx
        imul    di, bx, NAME_LEN
        add     di, skip_names
        call    name_eq
        jne     .skn
        mov     byte [skip_found+bx], 1
.skn:   inc     bx
        jmp     .skl
.nx:    inc     dword [idx]
        jmp     .rec
.verify:
        mov     si, from_name
        cmp     byte [si], 0
        je      .vs
        cmp     byte [from_found], 0
        je      .unknown
.vs:    xor     bx, bx
.vsl:   cmp     bx, [nskip]
        jae     .ok
        imul    si, bx, NAME_LEN
        add     si, skip_names
        cmp     byte [skip_found+bx], 0
        je      .unknown
        inc     bx
        jmp     .vsl
.ok:    ret
.unknown:                               ; SI = the name: screen only
        push    si
        mov     dx, s_unknown
        call    puts
        pop     si
        mov     dx, si
        xor     cx, cx
.ln:    cmp     byte [si], 0
        je      .pr
        inc     si
        inc     cx
        jmp     .ln
.pr:    mov     ah, 0x40
        mov     bx, 1
        int     0x21
        mov     dx, s_crlf_d
        jmp     die

; ---------------------------------------------------------------- data
s_banner        db "CPUSUITE: z486 CPU test programs on the PC-98", 13, 10, "$"
s_toohigh       db "CPUSUITE: loaded too high (must be below 0x8F000)", 13, 10, "$"
s_noxms         db "CPUSUITE: no XMS driver (HIMEM.SYS)", 13, 10, "$"
s_v86           db "CPUSUITE: the CPU is in virtual 8086 mode (EMM386?) - boot without it", 13, 10, "$"
s_nopack        db "CPUSUITE: cannot open CPUSUITE.BIN", 13, 10, "$"
s_readerr       db "CPUSUITE: read error", 13, 10, "$"
s_badpack       db "CPUSUITE: CPUSUITE.BIN is not a CPUSUITE pack", 13, 10, "$"
s_noout         db "CPUSUITE: cannot create CPUSUITE.TXT", 13, 10, "$"
s_xmserr        db "CPUSUITE: XMS call failed", 13, 10, "$"
s_usage         db "usage: CPUSUITE [/P:n] [/A] [/FROM:name] [/SKIP:name ...] [name]", 13, 10, "$"
s_unknown       db "CPUSUITE: not a program of CPUSUITE.BIN: $"
s_crlf_d        db 13, 10, "$"
s_packname      db "CPUSUITE.BIN", 0
s_outname       db "CPUSUITE.TXT", 0
s_hdr           db "CPUSUITE BEGIN V1 PROGRAMS=", 0
s_hdr2          db " PASSES=", 0
s_hdr_from      db " FROM=", 0
s_skip          db " SKIP", 13, 10, 0
s_sp            db " ", 0
s_crlf          db 13, 10, 0
s_pass          db "PASS", 0
s_pass_tf       db "PASS triple fault", 0
s_fail          db "FAIL verdict=", 0
s_fail_tf       db "FAIL no triple fault, verdict=", 0
s_fail_reset    db "FAIL reset without a verdict", 0
s_end           db "CPUSUITE END PASSES=", 0
s_end_run       db " RUN=", 0
s_end_pass      db " PASS=", 0
s_end_fail      db " FAIL=", 0
s_end_skip      db " SKIP=", 0
s_cpu           db "CPUSUITE CPU ac=", 0
s_cpu_id        db " cpuid=", 0
s_cpu_bda       db " bda486=", 0
s_cpu_detail    db " detail=dma", 0
s_cpu_nodetail  db " detail=none", 0
s_cpu_reset     db " resetdx=", 0
s_resetdx       db " resetdx=", 0
s_slash         db "/", 0
s_none          db "none", 0
s_data          db " data=", 0
s_eax           db " eax=", 0
dma_ports       db 0x01, 0x01, 0x03, 0x03, 0x05, 0x05, 0x07, 0x07
dma_pattern     db 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0
dma_sentinel    dd DETAIL_NONE, DETAIL_NONE

        align 4
xms_entry       dd 0
pack_size       dd 0
lin_pack        dd 0
lin_save        dd 0
count           dd 0
idx             dd 0
ran             dd 0
npass           dd 0
nfail           dd 0
nskipped        dd 0
last_edx        dd 0                    ; EDX after the last CPU reset
ref_edx         dd 0                    ; the reset signature rows are compared with
cpu_sig         dd 0
cpu_vendor      times 16 db 0
dma_dos         times 8 db 0            ; DOS's DMA ch0/ch1 address and count
dma_rd          times 8 db 0            ; what the program left there
bda486          dw 0
has_ac          db 0
has_id          db 0
dma_ok          db 0
probe           db 0                    ; 1: the reset round trip, no program
kw              dd 0                    ; parse_args: a switch's letters
dos_cr0         dd 0
rd_off          dd 0
; the XMS move structure (function 0Bh)
xm_len          dd 0
xm_sh           dw 0
xm_so           dd 0
xm_dh           dw 0
xm_do           dd 0
h_pack          dw 0
h_save          dw 0
fh_pack         dw 0
fh_out          dw 0
passes          dw 1
pass_no         dw 0
imr_m           db 0
imr_s           db 0
portc           db 0
a20_on          db 0
last_imr        db 0
numbuf          times 12 db 0
nskip           dw 0
append          db 0                    ; 1: append to CPUSUITE.TXT
from_wait       db 0                    ; 1: /FROM's program not reached yet (first pass)
from_found      db 0
skip_found      times MAX_SKIP db 0
want            times NAME_LEN db 0
from_name       times NAME_LEN db 0
skip_names      times MAX_SKIP * NAME_LEN db 0
rec             times REC_SIZE db 0

        align 16                        ; = the .eng section's file alignment below
eng_image:      ; the engine's bytes follow (section .eng)

; ================================================================ THE ENGINE
; Runs at physical ENG (real-mode CS = ENGSEG); every label below is an offset into that page.
section .eng vstart=0 follows=.text align=16

        bits 16
eng_base:
        jmp     eng_entry
        ; THE RETURN's stack, at a FIXED offset (prelude.inc CPUS_LAND_SP): the firmware's
        ; CPU-reset return loads SS:SP from 0000:0404, PUSHes and POPs EAX below SP (FDF80),
        ; then RETFs: [SP] = IP, [SP+2] = CS. The trap re-stores this SS:SP itself when it runs
        ; in real mode, so a program that used 0000:0404 as scratch still comes back.
        times 0x10 - ($ - eng_base) db 0
land_stack:
        dw      landing, ENGSEG
        align 4
p_rec           times REC_SIZE db 0     ; the program's record
p_data          dd 0                    ; linear: its chunk list
p_save          dd 0                    ; linear: the save block
p_ret           dw 0, 0                 ; the COM's continuation
p_retss         dw 0
p_retsp         dw 0
p_cr0           dd 0                    ; DOS's CR0
p_portc         db 0                    ; DOS's port C
p_a20           db 0                    ; 1: leave A20 enabled
p_probe         db 0                    ; 1: no program, only the reset round trip
r_imr           db 0
        align 4
r_edx           dd 0                    ; EDX at the landing: the reset's component ID

        align 8
gdt_eng:
        dq      0
        dq      0x00CF9B000000FFFF      ; 0x08 code, flat 32-bit
        dq      0x00CF93000000FFFF      ; 0x10 data, flat 32-bit
        dw      0xFFFF, ENG & 0xFFFF    ; 0x18 code, 16-bit, base ENG, 64 KiB
        db      (ENG >> 16) & 0xFF, 0x9B, 0x00, ENG >> 24
        dq      0x000093000000FFFF      ; 0x20 data, 16-bit, base 0, 64 KiB: DOS's real-mode cache
gdt_eng_end:
gdtr_eng:
        dw      gdt_eng_end - gdt_eng - 1
        dd      ENG + gdt_eng
idtr_0:                                 ; the bench's GDTR and IDTR: base 0, limit 0x3FF
        dw      0x3FF
        dd      0

        align 8
; Staging tables: for a protected-mode start, table k (sreg k) holds the program's descriptor k
; at the program's selector index k, so `mov sreg, sel` loads exactly the bench's cache even when
; two registers share a selector with different caches. Table 6 is the real-mode start's.
stg:    times 7 * 64 db 0
stg_gdtr:
%assign k 0
%rep 7
        dw      63
        dd      ENG + stg + 64 * k
%assign k k + 1
%endrep
pm_jmp: dd      0                       ; the program's EIP
        dw      0                       ; and CS


        align 4
        times 256 db 0
eng_stack_top:

; ---------------------------------------------------------------- entry (real mode)
eng_entry:
        cli
        cld
        mov     ax, cs
        mov     ds, ax
        mov     ss, ax
        mov     sp, eng_stack_top
        STAGE16 0, 'E'
        out     0xF2, al                ; A20 on (PC-98: any write to 0xF2)
        o32 lgdt [gdtr_eng]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword SEL_C32:(ENG + pm_entry)

        bits 32
pm_entry:
        mov     ax, SEL_D32
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        mov     gs, ax
        mov     ss, ax
        mov     esp, ENG + eng_stack_top
        ; 0-0x9EFFF -> the save block
        mov     edi, [ENG + p_save]
        xor     esi, esi
        mov     ecx, ENG / 4
        rep     movsd
        STAGE32 1, 'S'
        cmp     byte [ENG + p_probe], 0
        jne     probe_reset
        ; the bench's memory starts zeroed
        xor     eax, eax
        xor     edi, edi
        mov     ecx, 0x80000 / 4
        rep     stosd
        ; the program's image
        mov     esi, [ENG + p_data]
.chunk:
        lodsd
        mov     edi, eax
        lodsd
        mov     ecx, eax
        jecxz   .img_done
        rep     movsb
        add     esi, 3
        and     esi, ~3
        jmp     .chunk
.img_done:
        STAGE32 2, 'I'
        ; THE RETURN: SS:SP for the firmware's CPU-reset entry, and SHUT0 = 0 so it takes it
        mov     word [0x404], land_stack
        mov     word [0x406], ENGSEG
        mov     al, 0x0E
        out     0x37, al
        STAGE32 3, 'J'
        cmp     byte [ENG + p_rec + R_MODE], 0
        je      real_start
        ; the staging tables (protected-mode start)
        mov     ebx, 0
.stg:
        movzx   edi, word [ENG + p_rec + R_SEL + ebx * 2]
        and     edi, 0xFFF8
        jnz     .stg_idx
        mov     edi, 8                  ; a null selector: the detour loads it through 0x08
.stg_idx:
        mov     eax, ebx
        shl     eax, 6
        lea     edi, [ENG + stg + edi + eax]
        lea     esi, [ENG + p_rec + R_DESC + ebx * 8]
        movsd
        movsd
        inc     ebx
        cmp     ebx, 6
        jb      .stg

; ---------------------------------------------------------------- protected-mode start
pm_start:
        mov     eax, [ENG + p_rec + R_EIP]
        mov     [ENG + pm_jmp], eax
        mov     ax, [ENG + p_rec + R_SEL + 2]
        mov     [ENG + pm_jmp + 4], ax
        xor     eax, eax
        lldt    ax                      ; the bench's LDTR is 0
        ; a register whose selector is null but whose cache is valid (the bench writes caches
        ; directly) cannot be loaded in protected mode: load the cache through 0x08, drop to real
        ; mode, load selector 0 there (base 0, attributes kept), and come back. Its MOV below
        ; becomes NOPs.
        movzx   ebx, word [ENG + p_rec + R_NULL]
        test    ebx, ebx
        jz      pm_loads
        ; the NOP patches are written before the loads (DS may be one of them)
        bt      ebx, 0
        jnc     .p0
        mov     word [ENG + ld_es], 0x9090
.p0:    bt      ebx, 2
        jnc     .p2
        mov     word [ENG + ld_ss], 0x9090
.p2:    bt      ebx, 3
        jnc     .p3
        mov     word [ENG + ld_ds], 0x9090
.p3:    bt      ebx, 4
        jnc     .p4
        mov     word [ENG + ld_fs], 0x9090
.p4:    bt      ebx, 5
        jnc     .p5
        mov     word [ENG + ld_gs], 0x9090
.p5:
%macro DETOUR 2
        bt      ebx, %1
        jnc     %%n
        lgdt    [cs:ENG + stg_gdtr + 6 * %1]
        mov     ax, 8
        mov     %2, ax
%%n:
%endmacro
        DETOUR  0, es
        DETOUR  2, ss
        DETOUR  3, ds
        DETOUR  4, fs
        DETOUR  5, gs
        lgdt    [cs:ENG + gdtr_eng]
        jmp     SEL_C16:detour16
        bits 16
detour16:
        mov     eax, cr0
        and     al, 0xFE
        mov     cr0, eax
        jmp     ENGSEG:detour_rm
detour_rm:
        xor     ax, ax
        test    bl, 1 << 0
        jz      .d2
        mov     es, ax
.d2:    test    bl, 1 << 2
        jz      .d3
        mov     ss, ax
.d3:    test    bl, 1 << 3
        jz      .d4
        mov     ds, ax
.d4:    test    bl, 1 << 4
        jz      .d5
        mov     fs, ax
.d5:    test    bl, 1 << 5
        jz      .d6
        mov     gs, ax
.d6:    mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword SEL_C32:(ENG + pm_loads)
        bits 32
pm_loads:
        ; EFLAGS = 2 (the bench's); nothing below writes a flag
        push    dword 2
        popfd
        ; ES, FS, GS, DS, SS through their staging tables (SS last: no stack is used after it)
        lgdt    [cs:ENG + stg_gdtr + 6 * 0]
        mov     ax, [cs:ENG + p_rec + R_SEL + 0]
ld_es:  mov     es, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 4]
        mov     ax, [cs:ENG + p_rec + R_SEL + 8]
ld_fs:  mov     fs, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 5]
        mov     ax, [cs:ENG + p_rec + R_SEL + 10]
ld_gs:  mov     gs, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 3]
        mov     ax, [cs:ENG + p_rec + R_SEL + 6]
ld_ds:  mov     ds, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 2]
        mov     ax, [cs:ENG + p_rec + R_SEL + 4]
ld_ss:  mov     ss, eax
        ; CS's table stays loaded: the far jump reads it (GDTR is the bench's 0/0x3FF only in
        ; the bench; every program loads its own GDT before it needs one)
        lgdt    [cs:ENG + stg_gdtr + 6 * 1]
        lidt    [cs:ENG + idtr_0]
        mov     eax, [cs:ENG + p_rec + R_CR3]
        mov     cr3, eax
        mov     eax, 0
        mov     cr2, eax
        mov     eax, [cs:ENG + p_rec + R_CR0]
        mov     cr0, eax                ; paging may start here: this page has an identity PTE
        mov     eax, 0
        mov     ebx, 0
        mov     ecx, 0
        mov     edx, 0
        mov     esi, 0
        mov     edi, 0
        mov     ebp, 0
        mov     esp, 0xFF00
        jmp     far [cs:ENG + pm_jmp]

; the COM's reset round trip: THE RETURN with no program (and no verdict) in between
probe_reset:
        mov     word [0x404], land_stack
        mov     word [0x406], ENGSEG
        mov     al, 0x0E
        out     0x37, al                ; SHUT0 = 0
        out     0xF0, al                ; the CPU reset
        jmp     $

; ---------------------------------------------------------------- real-mode start
; Every register gets its cache attributes from a protected-mode load (descriptor = the bench's
; cache; CS's with base ENG so this code keeps running in it), then drops to real mode, where a
; selector load sets only the base (z486 segmentation_unit.sv SEG_CMD_SBRM: "Limit and
; granularity are NOT reset") and the far jump into the program sets CS's base and clears D.
real_start:
        mov     esi, ENG + p_rec + R_DESC
        mov     edi, ENG + stg + 6 * 64 + 8
        mov     ecx, 12
        rep     movsd
        mov     word [ENG + stg + 6 * 64 + 2 * 8 + 2], ENG & 0xFFFF
        mov     byte [ENG + stg + 6 * 64 + 2 * 8 + 4], (ENG >> 16) & 0xFF
        mov     byte [ENG + stg + 6 * 64 + 2 * 8 + 7], ENG >> 24
        mov     ax, [ENG + p_rec + R_EIP]
        mov     [ENG + rm_jmp + 1], ax
        mov     ax, [ENG + p_rec + R_SEL + 2]
        mov     [ENG + rm_jmp + 3], ax
        push    dword 2
        popfd                           ; EFLAGS = 2; nothing below writes a flag
        lgdt    [ENG + stg_gdtr + 6 * 6]
        mov     ax, 0x08
        mov     es, ax
        mov     ax, 0x18
        mov     ss, ax
        mov     ax, 0x28
        mov     fs, ax
        mov     ax, 0x30
        mov     gs, ax
        mov     ax, 0x20
        mov     ds, ax
        jmp     0x10:rm_stage16
        bits 16
rm_stage16:
        mov     eax, [cs:p_rec + R_CR3]
        mov     cr3, eax
        mov     eax, [cs:p_rec + R_CR0]
        mov     cr0, eax                ; real mode
        mov     ax, [cs:p_rec + R_SEL + 0]
        mov     es, ax
        mov     ax, [cs:p_rec + R_SEL + 4]
        mov     ss, ax
        mov     ax, [cs:p_rec + R_SEL + 6]
        mov     ds, ax
        mov     ax, [cs:p_rec + R_SEL + 8]
        mov     fs, ax
        mov     ax, [cs:p_rec + R_SEL + 10]
        mov     gs, ax
        o32 lidt [cs:idtr_0]
        o32 lgdt [cs:idtr_0]
        mov     esp, 0xFF00
        mov     eax, 0
        mov     ebx, 0
        mov     ecx, 0
        mov     edx, 0
        mov     esi, 0
        mov     edi, 0
        mov     ebp, 0
rm_jmp: jmp     0:0                     ; patched: the program's CS:IP

; ---------------------------------------------------------------- THE RETURN (real mode)
; The firmware's RETF lands here after the trap's `out 0xF0` (or any other CPU reset).
landing:
        mov     [cs:r_edx], edx         ; first: the reset's EDX (the firmware's path keeps it)
        cli
        in      al, 0x0A                ; the verdict, before anything touches the 8259
        mov     [cs:r_imr], al
        cld
        mov     ax, cs
        mov     ds, ax
        mov     ss, ax
        mov     sp, eng_stack_top
        STAGE16 4, 'L'
        out     0xF2, al                ; `out 0xF0` cleared A20
        o32 lgdt [gdtr_eng]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword SEL_C32:(ENG + restore32)
        bits 32
restore32:
        mov     ax, SEL_D32
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     esp, ENG + eng_stack_top
        mov     esi, [ENG + p_save]
        xor     edi, edi
        mov     ecx, ENG / 4
        rep     movsd
        STAGE32 5, 'R'
        mov     ax, SEL_D16             ; DOS's real-mode caches
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        mov     gs, ax
        mov     ss, ax
        jmp     SEL_C16:back16
        bits 16
back16:
        mov     eax, [cs:p_cr0]
        mov     cr0, eax
        jmp     ENGSEG:back_rm
back_rm:
        mov     ax, cs
        mov     ds, ax
        mov     al, [p_portc]
        out     0x35, al                ; SHUT0 back
        xor     eax, eax
        mov     cr3, eax
        o32 lidt [idtr_0]               ; the real-mode IVT (0/0x3FF)
        cmp     byte [p_a20], 0
        jne     .a20
        mov     al, 0x03
        out     0xF6, al                ; mask A20 again
.a20:
        mov     ss, [p_retss]
        mov     sp, [p_retsp]
        mov     al, [r_imr]
        mov     edx, [r_edx]
        jmp     far [p_ret]

eng_end:
ENG_SIZE        equ eng_end - eng_base
%if ENG_SIZE > 0x1000
 %error the engine must fit its page
%endif

section .text
iobuf   equ     ($ - $$ + 0x100 + ENG_SIZE + 15) & ~15
