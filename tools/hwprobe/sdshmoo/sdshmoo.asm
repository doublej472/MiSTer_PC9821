; sdshmoo.asm - SDSHMOO.COM: sweep the SDRAM_CLK phase of a --dbg-sdram-phase build and stress the
; whole guest RAM at every step, to measure the SDRAM read/write window on the card it runs on.
;
;   SDSHMOO [lo [hi [passes [maxMB [stop]]]]]       (decimal; lo may be negative)
;     lo, hi   the step range (PLL phase steps of VCO/8: 154.3 ps at the 90 MHz build's 810 MHz
;              VCO); default -36..36, a whole 11.1 ns period at 90 MHz
;     passes   pattern-set passes per step (default 1)
;     maxMB    test at most this many MiB of extended memory (default 0 = all of it)
;     stop     stop a direction after this many consecutive failing steps (default 4)
;
; THE BUILD. The core's run-time phase instrument (build_profile.py --dbg-sdram-phase; RTL
; src/pc9821/core/pc9821_sdram_phase_ctl.sv): 0x5FF2 takes the requested offset in steps and reads
; back the applied one, 0x5FF0 takes commands (00 keepalive, 03 nominal, 04 clear `reverted`) and
; reads status (0xA in the high nibble, [3] fault, [2] reverted, [1] busy). Without it (any other
; build: the port reads open bus 0xFF) the program runs the pattern set at the nominal phase only,
; which is still a whole-memory RAM test, and never writes the ports.
;
; ORDER. Step 0 first, then +1, -1, +2, -2, ... outward; a direction stops after `stop`
; consecutive failing steps (the window's edge and a margin are found, and no time is spent deep in
; the failing region), or at lo/hi. A FINAL step at 0 closes the run.
;
; WHY IT CANNOT CORRUPT ITSELF AT A BAD PHASE. Everything the step runs lives in GVRAM, which is
; on-chip block RAM, not SDRAM: the protected-mode test code (copied to 0xA8000 and executed there),
; its stack and every result counter (0xA9000). At a shifted phase the only SDRAM accesses are the
; test's own, interrupts are off, and the phase is put back to nominal (command 03, waited for)
; before the code returns to DOS. The instrument's watchdog returns to nominal by itself if the
; keepalives (every 4096 dwords) stop. What a bad OUTPUT phase can still do is make the SDRAM
; mis-take a command (a stray write into DOS's memory, in principle a mode-register write): the
; canary (64 KiB at the start of extended memory, written before the shift, checked after the
; return) reports that as can=<errors>, and a run that shows it should be rebooted.
;
; THE PATTERNS (each a fill pass then a verify pass over every tested region, dword accesses
; through the L1, so every verify read is a cache-line burst from SDRAM):
;   0 address-in-address   [a] = a                  1 its inverse           [a] = ~a
;   2 walking 1 / walking 0 across DQ[15:0]: the dword's two 16-bit beats are 1<<k and ~(1<<k),
;     k = dword index mod 16
;   3 checkerboard: 0xAAAA5555 / 0x5555AAAA on alternate dwords (every DQ toggles every beat)
;   4 0x0000FFFF / 0xFFFF0000 on alternate dwords (all 16 DQ switch together, both polarities)
;   5 bank/row/chip thrash: the region's two halves interleaved dword by dword (on a 128 MB module
;     the halves of a region past 64 MiB sit in different chips), hashed data
;   6 row thrash: a 4100-byte stride through the region (a new row nearly every access)
;   7 mixed byte enables: ~a, then one byte per dword at offset (i mod 4) and a misaligned word at
;     offset 1 every 8th dword, checked as merged
;   8 hashed random data (a per-pass seed)
; Errors are counted per chip half (physical address bit 26: a 128 MB module's second chip) with
; the OR of the failing DQ bits (each dword's two beats folded onto DQ[15:0]), the first failing
; address and its XOR, and per pattern. A step stops early once it has 4096 errors.
;
; OUTPUT. SDSHMOO.TXT in the current directory, each line appended and the file CLOSED before the
; next step (so a hang leaves every finished line on disk), echoed to stdout:
;   SDSHMOO v1 present=P st=SS ext=XXXXXXXX-XXXXXXXX,XXXXXXXX-XXXXXXXX passes=N range=LO..HI stop=S
;   BEGIN <step>                  written before the step starts: a BEGIN with no STEP is a hang
;   STEP <step> st0=SS rb=OO st1=SS err0=.. err1=.. dq0=.... dq1=.... first=........ xor=........
;        pat=P can=........ abort=A pe=p0,p1,...,p8
;   FINAL <same fields>           step 0 again after the sweep
;   END steps=N
; tools/hwprobe/sdshmoo/sdshmoo_decode.py turns it into the pass window per chip half.
;
; RESTORES. The phase (nominal, `reverted` cleared), the 32 KiB of GVRAM it borrows (saved and put
; back), GRCG off. Leaves A20 enabled (port 0xF2) and the tested extended memory overwritten, so run
; it from a freshly booted DOS with no HIMEM/EMM386 (nothing may own extended memory) and reboot
; after it. Interrupts are off for each whole step: the DOS clock loses that time.
;
; BUILD: make -C tools/hwprobe sdshmoo/sdshmoo.com   (NASM)
        cpu 486
        org 100h

GV_BASE   equ 0A8000h        ; the borrowed GVRAM plane (blue), 32 KiB
GV_SEG    equ 0A800h
V_SEG     equ 0A900h         ; the result block, GV_BASE + 0x1000
V_BASE    equ 1000h          ; ... as an offset in the PM data segment (base GV_BASE)
CANARY    equ 10000h         ; bytes of canary at the start of extended memory
ERR_CAP   equ 4096           ; a step stops once it has this many errors
KA_DW     equ 1000h          ; dwords between keepalives (a fill/verify dword costs up to ~80
                             ; clk_sys with its SDRAM miss: 4096 of them stay far inside the
                             ; 100 ms watchdog; 64 Ki did not, measured in the userdisk tier)
NPAT      equ 9
P_CMD     equ 5FF0h
P_OFF     equ 5FF2h

; ---- the result block (offsets from V_BASE; RM reaches it as V_SEG:off) -----------------------
V_OFF     equ 0              ; requested step (signed)
V_NPASS   equ 4
V_PRES    equ 8
V_NREG    equ 12
V_REG     equ 16             ; 2 x {base, end}
V_SEED    equ 32             ; the step's seed (set by the COM)
V_SEED0   equ 36             ; the canary's seed (the step's, before the passes advance it)
V_REGI    equ 40             ; the region loop's index
V_ST0     equ 48             ; status once at the step (bit 31: wait timed out)
V_ST1     equ 52             ; status once back at nominal
V_RB      equ 56             ; applied offset read back at the step
V_ERR0    equ 60
V_ERR1    equ 64
V_DQ0     equ 68
V_DQ1     equ 72
V_FADDR   equ 76
V_FXOR    equ 80
V_FPAT    equ 84
V_PERR    equ 88             ; NPAT dwords
V_CAN     equ 152            ; canary errors
V_TMP     equ 160
V_TMP2    equ 164
V_PAT     equ 168
V_ABORT   equ 172
V_FFLAG   equ 176            ; first error recorded

        bits 16
start:  cld
        mov  [rm_ss],ss
        mov  [rm_sp],sp
        ; the image's own limits (labels are not assembly-time scalars in a bin with sections):
        ; the PM step must end below the result block, the save area below the COM's stack
        mov  ax,pm_size
        cmp  ax,V_BASE
        ja   .big
        mov  ax,gvsave + 8000h
        cmp  ax,0F000h
        jb   .fits
.big:   mov  dx,s_big
        mov  ah,9
        int  21h
        mov  ax,4C01h
        int  21h
.fits:  call parse_args
        ; patch the GDT's cs-based descriptors and the return far jump
        mov  ax,cs
        mov  [rmseg],ax
        movzx eax,ax
        shl  eax,4
        mov  ebx,eax
        mov  di,gdt+20h
        call setbase
        mov  di,gdt+28h
        call setbase
        add  eax,gdt
        mov  [gdtr+2],eax
        ; the machine state the test needs: GRCG off, EGC mode off (0x6A 07/04/06), A20 on
        xor  al,al
        out  7Ch,al
        mov  al,07h
        out  6Ah,al
        mov  al,04h
        out  6Ah,al
        mov  al,06h
        out  6Ah,al
        out  0F2h,al
        ; the extended memory the BIOS reports: 0x0401 (128 KiB units, 1-16 MiB), 0x0594 (MiB > 16)
        push ds
        xor  ax,ax
        mov  ds,ax
        movzx eax,byte [0401h]
        movzx edx,word [0594h]
        pop  ds
        shl  eax,17
        add  eax,100000h
        mov  [ext1_end],eax
        shl  edx,20
        jz   .no2
        add  edx,1000000h
.no2:   mov  [ext2_end],edx
        ; the instrument
        mov  dx,P_CMD
        in   al,dx
        mov  [st_boot],al
        and  al,0F0h
        cmp  al,0A0h
        sete al
        movzx eax,al
        mov  [present],eax
        or   eax,eax             ; a present instrument starts at nominal with no stale flags
        jz   .nopr
        mov  al,03h
        out  dx,al
        mov  al,04h
        out  dx,al
.nopr:
        ; borrow the GVRAM plane: save it, then the PM code goes there
        push ds
        push es
        mov  ax,GV_SEG
        mov  ds,ax
        push cs
        pop  es
        xor  si,si
        mov  di,gvsave
        mov  cx,4000h
        rep  movsw
        pop  es
        pop  ds
        push es
        mov  ax,GV_SEG
        mov  es,ax
        mov  si,section.pm.start
        xor  di,di
        mov  cx,pm_size
        rep  movsb
        pop  es
        call setup_regions
        ; the log
        mov  ah,3Ch
        xor  cx,cx
        mov  dx,fname
        int  21h
        jc   .nolog
        mov  bx,ax
        mov  ah,3Eh
        int  21h
        mov  byte [logok],1
.nolog: call log_header
        ; step 0, then outward
        xor  eax,eax
        call run_step
        call judge
        cmp  dword [present],0
        je   .final
        mov  dword [k],1
        mov  dword [fail_up],0
        mov  dword [fail_dn],0
.out:   mov  eax,[k]
        cmp  eax,[hi]
        jg   .skipu
        mov  edx,[fail_up]
        cmp  edx,[stopn]
        jae  .skipu
        call run_step
        call judge
        jnc  .uok
        inc  dword [fail_up]
        jmp  .skipu
.uok:   mov  dword [fail_up],0
.skipu: mov  eax,[k]
        neg  eax
        cmp  eax,[lo]
        jl   .skipd
        mov  edx,[fail_dn]
        cmp  edx,[stopn]
        jae  .skipd
        call run_step
        call judge
        jnc  .dok
        inc  dword [fail_dn]
        jmp  .skipd
.dok:   mov  dword [fail_dn],0
.skipd: inc  dword [k]
        ; done when both directions are exhausted
        mov  eax,[k]
        cmp  eax,[hi]
        jle  .more
        mov  eax,[k]
        neg  eax
        cmp  eax,[lo]
        jge  .more
        jmp  .final
.more:  mov  eax,[fail_up]
        cmp  eax,[stopn]
        jb   .out
        mov  eax,[fail_dn]
        cmp  eax,[stopn]
        jb   .out
.final: mov  byte [final],1
        xor  eax,eax
        call run_step
        ; END
        mov  di,lbuf
        mov  si,s_end
        call cat
        mov  eax,[nsteps]
        call pdec
        call emit
        ; give the GVRAM plane back
        push es
        mov  ax,GV_SEG
        mov  es,ax
        mov  si,gvsave
        xor  di,di
        mov  cx,4000h
        rep  movsw
        pop  es
        mov  ax,4C00h
        int  21h

; ---- one step: eax = the offset ---------------------------------------------------------------
run_step:
        mov  [cur],eax
        inc  dword [nsteps]
        ; BEGIN line (committed before the step can hang)
        mov  di,lbuf
        mov  si,s_begin
        call cat
        mov  eax,[cur]
        call pdec
        call emit
        ; parameters into the result block
        push es
        mov  ax,V_SEG
        mov  es,ax
        mov  eax,[cur]
        mov  [es:V_OFF],eax
        mov  eax,[npass]
        mov  [es:V_NPASS],eax
        mov  eax,[present]
        mov  [es:V_PRES],eax
        mov  eax,[nreg]
        mov  [es:V_NREG],eax
        mov  eax,[reg0b]
        mov  [es:V_REG],eax
        mov  eax,[reg0e]
        mov  [es:V_REG+4],eax
        mov  eax,[reg1b]
        mov  [es:V_REG+8],eax
        mov  eax,[reg1e]
        mov  [es:V_REG+12],eax
        mov  eax,[nsteps]
        imul eax,eax,2545F491h
        mov  [es:V_SEED],eax
        pop  es
        ; into protected mode, run the step from GVRAM, and back
        mov  [step_sp],sp
        cli
        lgdt [gdtr]
        mov  eax,cr0
        or   al,1
        mov  cr0,eax
        jmp  dword 08h:0
back16: mov  ax,28h
        mov  ds,ax
        mov  es,ax
        mov  fs,ax
        mov  gs,ax
        mov  ss,ax
        mov  eax,cr0
        and  al,0FEh
        mov  cr0,eax
        db   0EAh
        dw   rm_back
rmseg:  dw   0
rm_back:
        mov  ax,cs
        mov  ds,ax
        mov  es,ax
        mov  fs,ax
        mov  gs,ax
        mov  ss,[rm_ss]
        mov  sp,[step_sp]
        sti
        ; the STEP / FINAL line
        mov  di,lbuf
        mov  si,s_step
        cmp  byte [final],0
        je   .s
        mov  si,s_final
.s:     call cat
        mov  eax,[cur]
        call pdec
        push fs
        mov  ax,V_SEG
        mov  fs,ax
        mov  si,s_st0
        call cat
        mov  eax,[fs:V_ST0]
        call pstat
        mov  si,s_rb
        call cat
        mov  al,[fs:V_RB]
        call phex8
        mov  si,s_st1
        call cat
        mov  eax,[fs:V_ST1]
        call pstat
        mov  si,s_err0
        call cat
        mov  eax,[fs:V_ERR0]
        call phex32
        mov  si,s_err1
        call cat
        mov  eax,[fs:V_ERR1]
        call phex32
        mov  si,s_dq0
        call cat
        mov  ax,[fs:V_DQ0]
        call phex16
        mov  si,s_dq1
        call cat
        mov  ax,[fs:V_DQ1]
        call phex16
        mov  si,s_first
        call cat
        mov  eax,[fs:V_FADDR]
        call phex32
        mov  si,s_xor
        call cat
        mov  eax,[fs:V_FXOR]
        call phex32
        mov  si,s_pat
        call cat
        mov  al,[fs:V_FPAT]
        call pnib
        mov  si,s_can
        call cat
        mov  eax,[fs:V_CAN]
        call phex32
        mov  si,s_abort
        call cat
        mov  al,[fs:V_ABORT]
        call pnib
        mov  si,s_pe
        call cat
        xor  bx,bx
.pe:    mov  eax,[fs:V_PERR+bx]
        call phex32
        add  bx,4
        cmp  bx,NPAT*4
        jae  .pe1
        mov  al,','
        stosb
        jmp  .pe
.pe1:   pop  fs
        call emit
        ret

; a status dword: its byte, prefixed T when the wait for idle timed out (bit 31)
pstat:  test eax,80000000h
        jz   .p
        push ax
        mov  al,'T'
        stosb
        pop  ax
.p:     jmp  phex8

; ---- did the step fail? CF=1 when it did -------------------------------------------------------
judge:  push fs
        mov  ax,V_SEG
        mov  fs,ax
        mov  eax,[fs:V_ERR0]
        or   eax,[fs:V_ERR1]
        or   eax,[fs:V_CAN]
        jnz  .bad
        mov  eax,[fs:V_ST0]
        or   eax,[fs:V_ST1]
        test eax,8000000Ch       ; timeout, fault, reverted
        jnz  .bad
        pop  fs
        clc
        ret
.bad:   pop  fs
        stc
        ret

; ---- the tested regions: [1 MiB + canary, ext1_end), [16 MiB, ext2_end), capped at maxMB -------
setup_regions:
        xor  bx,bx               ; regions filled so far (x8)
        mov  eax,[ext1_end]
        cmp  eax,100000h + CANARY + 10000h
        jbe  .r2
        mov  dword [regs+bx],100000h + CANARY
        mov  [regs+bx+4],eax
        add  bx,8
.r2:    mov  eax,[ext2_end]
        or   eax,eax
        jz   .cap
        mov  dword [regs+bx],1000000h
        mov  [regs+bx+4],eax
        add  bx,8
.cap:   shr  bx,3
        mov  [nreg],bx
        mov  ecx,[maxmb]         ; cap the total at maxMB: trim region 0, then drop/trim region 1
        jecxz .done
        shl  ecx,20
        mov  eax,[reg0e]
        sub  eax,[reg0b]
        cmp  eax,ecx
        jb   .c2
        add  ecx,[reg0b]
        mov  [reg0e],ecx
        mov  dword [nreg],1
        ret
.c2:    sub  ecx,eax
        cmp  dword [nreg],2
        jb   .done
        mov  eax,[reg1e]
        sub  eax,[reg1b]
        cmp  eax,ecx
        jbe  .done
        add  ecx,[reg1b]
        mov  [reg1e],ecx
.done:  ret

log_header:
        mov  di,lbuf
        mov  si,s_head
        call cat
        mov  al,[present]
        call pnib
        mov  si,s_st
        call cat
        mov  al,[st_boot]
        call phex8
        mov  si,s_ext
        call cat
        mov  eax,[reg0b]
        call phex32
        mov  al,'-'
        stosb
        mov  eax,[reg0e]
        call phex32
        cmp  dword [nreg],2
        jb   .h1
        mov  al,','
        stosb
        mov  eax,[reg1b]
        call phex32
        mov  al,'-'
        stosb
        mov  eax,[reg1e]
        call phex32
.h1:    mov  si,s_passes
        call cat
        mov  eax,[npass]
        call pdec
        mov  si,s_range
        call cat
        mov  eax,[lo]
        call pdec
        mov  al,'.'
        stosb
        stosb
        mov  eax,[hi]
        call pdec
        mov  si,s_stop
        call cat
        mov  eax,[stopn]
        call pdec
        jmp  emit

; ---- arguments: up to five signed decimals ------------------------------------------------------
parse_args:
        mov  si,81h
        mov  bx,args
        mov  cx,5
.next:  lodsb
        cmp  al,0Dh
        je   .end
        cmp  al,' '
        je   .next
        cmp  al,9
        je   .next
        xor  edx,edx
        xor  bp,bp               ; negative?
        cmp  al,'-'
        jne  .dig
        inc  bp
        lodsb
.dig:   cmp  al,'0'
        jb   .tok
        cmp  al,'9'
        ja   .tok
        sub  al,'0'
        movzx eax,al
        imul edx,edx,10
        add  edx,eax
        lodsb
        jmp  .dig
.tok:   or   bp,bp
        jz   .pos
        neg  edx
.pos:   mov  [bx],edx
        add  bx,4
        dec  si
        loop .next
.end:   ret

; ---- line building (DI into lbuf) and the log ---------------------------------------------------
cat:    lodsb                    ; append the NUL-terminated string at SI
        or   al,al
        jz   .e
        stosb
        jmp  cat
.e:     ret
phex32: push eax
        shr  eax,16
        call phex16
        pop  eax
phex16: push ax
        mov  al,ah
        call phex8
        pop  ax
phex8:  push ax
        shr  al,4
        call pnib
        pop  ax
pnib:   and  al,0Fh
        add  al,'0'
        cmp  al,'9'
        jbe  .o
        add  al,7
.o:     stosb
        ret
pdec:   or   eax,eax             ; signed decimal
        jns  .p
        push eax
        mov  al,'-'
        stosb
        pop  eax
        neg  eax
        jmp  .u
.p:     push eax
        mov  al,'+'
        stosb
        pop  eax
.u:     xor  cx,cx
        mov  ebx,10
.d:     xor  edx,edx
        div  ebx
        push dx
        inc  cx
        or   eax,eax
        jnz  .d
.w:     pop  ax
        add  al,'0'
        stosb
        loop .w
        ret
emit:   mov  ax,0A0Dh            ; CR LF, then the line to stdout and appended to the log
        stosw
        mov  cx,di
        sub  cx,lbuf
        mov  [llen],cx
        mov  ah,40h
        mov  bx,1
        mov  dx,lbuf
        int  21h
        cmp  byte [logok],0
        je   .x
        mov  ax,3D01h
        mov  dx,fname
        int  21h
        jc   .x
        mov  bx,ax
        mov  ax,4202h
        xor  cx,cx
        xor  dx,dx
        int  21h
        mov  ah,40h
        mov  cx,[llen]
        mov  dx,lbuf
        int  21h
        mov  ah,3Eh
        int  21h
.x:     ret

setbase:                         ; [di] descriptor base := ebx
        mov  [di+2],bx
        push ebx
        shr  ebx,16
        mov  [di+4],bl
        mov  [di+7],bh
        pop  ebx
        ret

; ==== THE PROTECTED-MODE STEP: assembled at 0, copied to GVRAM (GV_BASE) and run there ===========
; Selectors: 08 this code (base GV_BASE), 10 the result block and stack (base GV_BASE, 32-bit
; stack), 18 flat 4 GiB (the test's own accesses), 20/28 the COM's 16-bit code/data (the return).
        section pm vstart=0 follows=.text
        bits 32
pm_entry:
        mov  ax,10h
        mov  ds,ax
        mov  ss,ax
        mov  esp,8000h
        mov  ax,18h
        mov  es,ax
        ; clear the results
        xor  eax,eax
        mov  edi,V_BASE+V_ST0
.clr:   mov  [edi],eax
        add  edi,4
        cmp  edi,V_BASE+V_FFLAG+4
        jb   .clr
        mov  ebp,KA_DW
        mov  eax,[V_BASE+V_SEED]
        mov  [V_BASE+V_SEED0],eax
        ; the canary, at nominal
        mov  esi,100000h
        mov  ebx,100000h+CANARY
        mov  edi,esi
.cw:    mov  edx,edi
        xor  edx,[V_BASE+V_SEED0]
        mov  [es:edi],edx
        add  edi,4
        cmp  edi,ebx
        jb   .cw
        ; move to the step
        cmp  dword [V_BASE+V_PRES],0
        je   .tests
        mov  dx,P_OFF
        mov  al,[V_BASE+V_OFF]
        out  dx,al
        call waitidle
        mov  [V_BASE+V_ST0],eax
        mov  dx,P_OFF
        in   al,dx
        movzx eax,al
        mov  [V_BASE+V_RB],eax
.tests: mov  ecx,[V_BASE+V_NPASS]
        or   ecx,ecx
        jnz  .pass
        inc  ecx
.pass:  push ecx
        add  dword [V_BASE+V_SEED],9E3779B9h
        xor  eax,eax
.pat:   mov  [V_BASE+V_PAT],eax
        call [ptab+eax*4]
        mov  eax,[V_BASE+V_ERR0]
        add  eax,[V_BASE+V_ERR1]
        cmp  eax,ERR_CAP
        jae  .abort
        mov  eax,[V_BASE+V_PAT]
        inc  eax
        cmp  eax,NPAT
        jb   .pat
        pop  ecx
        loop .pass
        jmp  .home
.abort: pop  ecx
        mov  dword [V_BASE+V_ABORT],1
        ; back to nominal, then check the canary
.home:  cmp  dword [V_BASE+V_PRES],0
        je   .can
        mov  dx,P_CMD
        mov  al,03h
        out  dx,al
        call waitidle
        mov  [V_BASE+V_ST1],eax
        mov  dx,P_CMD
        mov  al,04h              ; clear `reverted` (its state is already recorded in st1)
        out  dx,al
.can:   mov  esi,100000h
        mov  ebx,100000h+CANARY
        mov  edi,esi
.cv:    mov  edx,edi
        xor  edx,[V_BASE+V_SEED0]
        mov  eax,[es:edi]
        cmp  eax,edx
        je   .cok
        inc  dword [V_BASE+V_CAN]
.cok:   add  edi,4
        cmp  edi,ebx
        jb   .cv
        jmp  dword 20h:back16

; status in eax once the controller is idle (bit 31: it was not within ~10^7 polls)
waitidle:
        push ecx
        push edx
        mov  ecx,10000000
        mov  dx,P_CMD
.w:     in   al,dx
        test al,2
        jz   .ok
        loop .w
        movzx eax,al
        or   eax,80000000h
        jmp  .x
.ok:    movzx eax,al
.x:     pop  edx
        pop  ecx
        ret

kal:    mov  ebp,KA_DW           ; keepalive (only on a build with the instrument)
        cmp  dword [V_BASE+V_PRES],0
        je   .x
        push eax
        push edx
        mov  dx,P_CMD
        xor  al,al
        out  dx,al
        pop  edx
        pop  eax
.x:     ret

; a mismatch: edi = address, eax = read, edx = expected
bad:    push eax
        push ebx
        push ecx
        xor  eax,edx
        mov  ecx,eax
        shr  ecx,16
        or   ecx,eax
        and  ecx,0FFFFh          ; the failing DQ bits, both beats folded
        bt   edi,26
        jc   .c1
        inc  dword [V_BASE+V_ERR0]
        or   [V_BASE+V_DQ0],ecx
        jmp  .f
.c1:    inc  dword [V_BASE+V_ERR1]
        or   [V_BASE+V_DQ1],ecx
.f:     mov  ebx,[V_BASE+V_PAT]
        inc  dword [V_BASE+V_PERR+ebx*4]
        cmp  dword [V_BASE+V_FFLAG],0
        jne  .x
        mov  dword [V_BASE+V_FFLAG],1
        mov  [V_BASE+V_FADDR],edi
        mov  [V_BASE+V_FXOR],eax
        mov  [V_BASE+V_FPAT],ebx
.x:     pop  ecx
        pop  ebx
        pop  eax
        ret

%macro KEEP 0
        dec  ebp
        jnz  %%n
        call kal
%%n:
%endmacro

; each pattern: for every region, ESI = base, EBX = end
%macro REGIONS 1
        xor  eax,eax
%%r:    mov  [V_BASE+V_REGI],eax
        mov  esi,[V_BASE+V_REG+eax*8]
        mov  ebx,[V_BASE+V_REG+eax*8+4]
        call %1
        mov  eax,[V_BASE+V_REGI]
        inc  eax
        cmp  eax,[V_BASE+V_NREG]
        jb   %%r
        ret
%endmacro

; a sequential fill-then-verify with expected value macro %2 (edi -> edx; may use eax, ecx)
%macro SEQ 2
%1:     mov  edi,esi
%%f:    %2
        mov  [es:edi],edx
        add  edi,4
        KEEP
        cmp  edi,ebx
        jb   %%f
        mov  edi,esi
%%v:    %2
        mov  eax,[es:edi]
        cmp  eax,edx
        je   %%ok
        call bad
%%ok:   add  edi,4
        KEEP
        cmp  edi,ebx
        jb   %%v
        ret
%endmacro

%macro V_ADDR 0
        mov  edx,edi
%endmacro
%macro V_NADDR 0
        mov  edx,edi
        not  edx
%endmacro
%macro V_WALK 0
        mov  ecx,edi
        shr  ecx,2
        and  ecx,15
        mov  edx,1
        shl  edx,cl
        mov  ecx,edx
        not  ecx
        shl  ecx,16
        or   edx,ecx
%endmacro
%macro V_CHK 0
        mov  edx,0AAAA5555h
        test edi,4
        jz   %%z
        not  edx
%%z:
%endmacro
%macro V_FLIP 0
        mov  edx,0000FFFFh
        test edi,4
        jz   %%z
        not  edx
%%z:
%endmacro
%macro V_HASH 0
        mov  edx,edi
        xor  edx,[V_BASE+V_SEED]
        imul edx,edx,9E3779B1h
        mov  ecx,edx
        shr  ecx,15
        xor  edx,ecx
        imul edx,edx,85EBCA6Bh
        mov  ecx,edx
        shr  ecx,13
        xor  edx,ecx
%endmacro
%macro V_BYTES 0
        mov  ecx,edi
        shr  ecx,2
        imul eax,ecx,7
        and  eax,0FFh
        and  ecx,3
        shl  ecx,3
        shl  eax,cl
        mov  edx,0FFh
        shl  edx,cl
        not  edx
        mov  ecx,edi
        not  ecx
        and  edx,ecx
        or   edx,eax
        test edi,1Ch
        jnz  %%z
        mov  eax,edi
        shr  eax,2
        xor  eax,0BEEFh
        and  eax,0FFFFh
        shl  eax,8
        and  edx,0FF0000FFh
        or   edx,eax
%%z:
%endmacro

pat0:   REGIONS seq_addr
pat1:   REGIONS seq_naddr
pat2:   REGIONS seq_walk
pat3:   REGIONS seq_chk
pat4:   REGIONS seq_flip
pat5:   REGIONS thrash
pat6:   REGIONS stride
pat7:   REGIONS bytes
pat8:   REGIONS seq_hash

        SEQ seq_addr, V_ADDR
        SEQ seq_naddr, V_NADDR
        SEQ seq_walk, V_WALK
        SEQ seq_chk, V_CHK
        SEQ seq_flip, V_FLIP
        SEQ seq_hash, V_HASH

; the two halves interleaved: [lo+j], [lo+h+j] for j = 0, 4, ...
thrash: mov  eax,ebx
        sub  eax,esi
        shr  eax,1
        and  eax,0FFFFFFFCh
        mov  [V_BASE+V_TMP],eax
        lea  ebx,[esi+eax]       ; the loop runs over the low half
        mov  edi,esi
.f:     V_HASH
        mov  [es:edi],edx
        add  edi,[V_BASE+V_TMP]
        V_HASH
        mov  [es:edi],edx
        sub  edi,[V_BASE+V_TMP]
        add  edi,4
        KEEP
        cmp  edi,ebx
        jb   .f
        mov  edi,esi
.v:     V_HASH
        mov  eax,[es:edi]
        cmp  eax,edx
        je   .o1
        call bad
.o1:    add  edi,[V_BASE+V_TMP]
        V_HASH
        mov  eax,[es:edi]
        cmp  eax,edx
        je   .o2
        call bad
.o2:    sub  edi,[V_BASE+V_TMP]
        add  edi,4
        KEEP
        cmp  edi,ebx
        jb   .v
        ret

; a 4100-byte stride, wrapping inside the region, size/4 accesses
stride: mov  eax,ebx
        sub  eax,esi
        mov  [V_BASE+V_TMP],eax
        shr  eax,2
        mov  [V_BASE+V_TMP2],eax
        mov  edi,esi
.f:     V_NADDR
        mov  [es:edi],edx
        add  edi,1004h
        cmp  edi,ebx
        jb   .f1
        sub  edi,[V_BASE+V_TMP]
.f1:    KEEP
        dec  dword [V_BASE+V_TMP2]
        jnz  .f
        mov  eax,[V_BASE+V_TMP]
        shr  eax,2
        mov  [V_BASE+V_TMP2],eax
        mov  edi,esi
.v:     V_NADDR
        mov  eax,[es:edi]
        cmp  eax,edx
        je   .o
        call bad
.o:     add  edi,1004h
        cmp  edi,ebx
        jb   .v1
        sub  edi,[V_BASE+V_TMP]
.v1:    KEEP
        dec  dword [V_BASE+V_TMP2]
        jnz  .v
        ret

; ~a, then a byte per dword and a misaligned word every 8th dword
bytes:  mov  edi,esi
.f:     V_NADDR
        mov  [es:edi],edx
        add  edi,4
        KEEP
        cmp  edi,ebx
        jb   .f
        mov  edi,esi
.b:     mov  ecx,edi
        shr  ecx,2
        imul eax,ecx,7
        and  ecx,3
        mov  [es:edi+ecx],al
        test edi,1Ch
        jnz  .b1
        mov  eax,edi
        shr  eax,2
        xor  eax,0BEEFh
        mov  [es:edi+1],ax
.b1:    add  edi,4
        KEEP
        cmp  edi,ebx
        jb   .b
        mov  edi,esi
.v:     V_BYTES
        mov  eax,[es:edi]
        cmp  eax,edx
        je   .o
        call bad
.o:     add  edi,4
        KEEP
        cmp  edi,ebx
        jb   .v
        ret

        align 4
ptab:   dd pat0, pat1, pat2, pat3, pat4, pat5, pat6, pat7, pat8
pm_end:

        section .text
pm_size equ pm_end - pm_entry
        bits 16

        align 8
gdt:    dq 0
        dw 0FFFFh,8000h,9A0Ah,0040h   ; 08 code32, base GV_BASE, D=1
        dw 7FFFh,8000h,920Ah,0040h    ; 10 data32/stack, base GV_BASE, limit 32K, B=1
        dw 0FFFFh,0,9200h,00CFh       ; 18 flat 4 GiB
        dw 0FFFFh,0,9A00h,0000h       ; 20 code16, base cs*16
        dw 0FFFFh,0,9200h,0000h       ; 28 data16, base cs*16
gdt_end:
gdtr:   dw gdt_end-gdt-1
        dd 0
rm_ss   dw 0
rm_sp   dw 0
step_sp dw 0
args:
lo      dd -36
hi      dd 36
npass   dd 1
maxmb   dd 0
stopn   dd 4
present dd 0
ext1_end dd 0
ext2_end dd 0
nreg    dd 0
regs:
reg0b   dd 0
reg0e   dd 0
reg1b   dd 0
reg1e   dd 0
cur     dd 0
k       dd 0
fail_up dd 0
fail_dn dd 0
nsteps  dd 0
llen    dw 0
st_boot db 0
logok   db 0
final   db 0
fname   db 'SDSHMOO.TXT',0
s_head  db 'SDSHMOO v1 present=',0
s_st    db ' st=',0
s_ext   db ' ext=',0
s_passes db ' passes=',0
s_range db ' range=',0
s_stop  db ' stop=',0
s_begin db 'BEGIN ',0
s_step  db 'STEP ',0
s_final db 'FINAL ',0
s_st0   db ' st0=',0
s_rb    db ' rb=',0
s_st1   db ' st1=',0
s_err0  db ' err0=',0
s_err1  db ' err1=',0
s_dq0   db ' dq0=',0
s_dq1   db ' dq1=',0
s_first db ' first=',0
s_xor   db ' xor=',0
s_pat   db ' pat=',0
s_can   db ' can=',0
s_abort db ' abort=',0
s_pe    db ' pe=',0
s_end   db 'END steps=',0
s_big   db 'SDSHMOO: image too large (build error)',13,10,'$'
lbuf    times 256 db 0
; 32 KiB for the borrowed GVRAM plane, past the PM image (which the bin output places after .text)
gvsave  equ section.pm.start + (pm_end - pm_entry) + 16
