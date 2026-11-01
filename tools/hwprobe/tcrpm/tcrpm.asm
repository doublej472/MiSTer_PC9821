; tcrpm.asm - the GRCG TDW store / tile reload / TCR compare order, in Viper CTR's own loop.
;
;   TCRPM > TCRPM.TXT
;
; WHY. Viper CTR (SGS386, its protected-mode logo zoom at 0040:0298) draws a column-wise RLE with
; `outsb x4` (the next tile into 0x7E), `stosb` (GRCG TDW: the plane bytes take the tile),
; `add edi,ebp`, `dec ecx / je`, `outsb x4`, `cmp es:[edi-50h],ah` (a TCR read of the byte just
; written against the NEW tile; FF = a repeat, which ends the run), `jne`. A store must take the
; tile in effect when it was issued: the 486 bus is in order, so the four OUTs that follow it
; cannot reach the GRCG first (NP2kai memtdw writes grcg.tile at the store). The core's GVRAM
; accepts a decoupled GRCG store only after the previous store's period, and before 7fedb1f3 the
; walk took the LIVE tile at that accept, so from 80 MHz up the OUTs overtook it (the game drew
; vertical-stripe garbage); tb_pc9821_grcg_tile_order is the unit bench.
;
; WHAT IT DOES. Enters 32-bit protected mode (no paging; DS base 1 MiB 4 GiB as the game's, ES
; base 0xA8000, FS the variables), generates 2000 columns of tiles T0..T(k+1) (k 1..399, T(i+1)
; differs from T(i) - often by one bit - and T(k+1) == T(k)), runs the loop on each, and checks
; the exit (ECX/ESI/EDI must say rows 0..k were written) and every written row's four planes with
; the GRCG off. Six passes over the same data, one per loop shape:
;   0 the game's loop          1 lodsb/out dx,al instead of outsb   2 mov al,mem / cmp al,ah
;   3 a delay before the compare   4 a delay between the store and the tile reload   5 = 0
; A correct core (and the machine) prints exit_err=0 plane_err=0 in every pass. `first` is the
; first bad column's rows-written<<16 | k, `col|tcr` its index<<8 | the TCR re-read after the exit.
;
; SAFETY / RESTORE. cli for each pass (DOS's clock loses that time), A20 left enabled (port 0xF2),
; EGC mode left off (0x6A 07/04/06: the DOS-prompt state), GRCG off at the end. Writes plane-0..3
; GVRAM at 0xA8000/0xB0000/0xB8000/0xE0000 (the screen may show it) and extended memory
; 1 MiB..~3 MiB, so run it from a plain DOS prompt with no HIMEM/EMM386 holding that memory.
;
; BUILD: make -C tools/hwprobe tcrpm/tcrpm.com   (NASM)
        cpu 386
        org 100h
NCOL    equ 2000             ; columns per pass
C0      equ 1000             ; initial ECX (never reaches 0)
SBASE   equ 100000h          ; DS base (the stream)

        bits 16
start:  cld
        mov  ax,cs
        movzx eax,ax
        shl  eax,4
        mov  [cslin],eax
        mov  [rmseg],cs
        ; patch the cs-based descriptors (code32 08, vars 10, code16 30, data16 38)
        mov  ebx,eax
        mov  di,gdt+08h
        call setbase
        mov  di,gdt+10h
        call setbase
        mov  di,gdt+30h
        call setbase
        mov  di,gdt+38h
        call setbase
        add  eax,gdt
        mov  [gdtr+2],eax
        mov  al,07h          ; EGC off
        out  6Ah,al
        mov  al,04h
        out  6Ah,al
        mov  al,06h
        out  6Ah,al
        out  0F2h,al         ; A20 on
        mov  [rm_ss],ss
        mov  [rm_sp],sp
        mov  word [pass],0
passlp:  cli
        lgdt [gdtr]
        mov  eax,cr0
        or   al,1
        mov  cr0,eax
        db   66h,0EAh
        dd   pm32
        dw   08h
back16: mov  eax,cr0
        and  al,0FEh
        mov  cr0,eax
        db   0EAh
        dw   rm
rmseg:  dw   0
rm:     mov  ax,cs
        mov  ds,ax
        mov  es,ax
        mov  fs,ax
        mov  gs,ax
        mov  ss,[rm_ss]
        mov  sp,[rm_sp]
        sti
        ; report
        mov  dx,msg_p
        call puts
        mov  ax,[pass]
        call phex16
        mov  dx,msg_x
        call puts
        mov  eax,[e_exit]
        call phex32
        mov  dx,msg_d
        call puts
        mov  eax,[e_data]
        call phex32
        mov  dx,msg_r
        call puts
        mov  eax,[n_rows]
        call phex32
        mov  dx,msg_f
        call puts
        mov  eax,[f_info]
        call phex32
        mov  dx,sp1
        call puts
        mov  eax,[f_info2]
        call phex32
        mov  dx,crlf
        call puts
        inc  word [pass]
        cmp  word [pass],6
        jb   passlp
        mov  al,0
        out  7Ch,al
        mov  ax,4C00h
        int  21h

setbase:                     ; [di] descriptor base := ebx
        mov  [di+2],bx
        push ebx
        shr  ebx,16
        mov  [di+4],bl
        mov  [di+7],bh
        pop  ebx
        ret

; ------------------------------------------------------------------------------------------
        bits 32
pm32:   mov  ax,10h
        mov  fs,ax
        mov  ss,ax
        mov  ax,18h
        mov  ds,ax
        mov  ax,20h
        mov  es,ax
        mov  dword [fs:e_exit],0
        mov  dword [fs:e_data],0
        mov  dword [fs:n_rows],0
        mov  dword [fs:f_info],0
        mov  dword [fs:f_info2],0
        ; seed differs per pass
        mov  eax,12345h
        imul eax,eax,9E3779B1h
        or   eax,1
        mov  [fs:seed],eax
        ; ---- generate the stream: per column a length k (1..399) and k+2 tiles ----
        xor  esi,esi
        mov  ebx,NCOL
.gcol:  call rnd
        xor  edx,edx
        mov  ecx,399
        div  ecx
        lea  ecx,[edx+1]     ; k
        mov  [esi],ecx       ; column header: k
        add  esi,4
        call rnd
        mov  [esi],eax       ; T0
        add  esi,4
        mov  edi,ecx         ; tiles T1..Tk differ from the previous
.gt:    call rnd
        mov  edx,eax
        test dl,3
        jnz  .gt1
        call rnd             ; 1/4: a fresh random tile
        jmp  .gt2
.gt1:   mov  ecx,edx         ; 3/4: previous with one bit flipped
        shr  ecx,8
        and  ecx,31
        mov  eax,1
        shl  eax,cl
        xor  eax,[esi-4]
.gt2:   cmp  eax,[esi-4]
        jne  .gt3
        xor  eax,1
.gt3:   mov  [esi],eax
        add  esi,4
        dec  edi
        jnz  .gt
        mov  eax,[esi-4]     ; T(k+1) = Tk
        mov  [esi],eax
        add  esi,4
        dec  ebx
        jnz  .gcol
        ; ---- draw and check every column ----
        xor  esi,esi
        mov  dword [fs:col],0
.dcol:  mov  eax,[esi]       ; k
        mov  [fs:kk],eax
        add  esi,4
        mov  [fs:s0],esi
        mov  eax,[fs:col]
        xor  edx,edx
        mov  ecx,80
        div  ecx
        mov  edi,edx         ; column x
        mov  [fs:e0],edi
        mov  al,80h
        out  7Ch,al          ; GRCG TDW (resets the tile pointer)
        mov  edx,7Eh
        mov  ebp,4Fh
        mov  ah,0FFh
        mov  ecx,C0
        movzx ebx,word [fs:pass]
        cmp  ebx,1
        je   .v1
        cmp  ebx,2
        je   .v2
        cmp  ebx,3
        je   .v3
        cmp  ebx,4
        je   .v4
        jmp  .v0
.v0:
        outsb
        outsb
        outsb
        outsb
.L0:    stosb
        add  edi,ebp
        dec  ecx
        je   .zero
        outsb
        outsb
        outsb
        outsb
        cmp  [es:edi-50h],ah
        jne  .L0
        jmp  .zero
.v1:
        lodsb
        out  dx,al
        lodsb
        out  dx,al
        lodsb
        out  dx,al
        lodsb
        out  dx,al
.L1:    stosb
        add  edi,ebp
        dec  ecx
        je   .zero
        lodsb
        out  dx,al
        lodsb
        out  dx,al
        lodsb
        out  dx,al
        lodsb
        out  dx,al
        cmp  [es:edi-50h],ah
        jne  .L1
        jmp  .zero
.v2:
        outsb
        outsb
        outsb
        outsb
.L2:    stosb
        add  edi,ebp
        dec  ecx
        je   .zero
        outsb
        outsb
        outsb
        outsb
        mov  al,[es:edi-50h]
        cmp  al,ah
        jne  .L2
        jmp  .zero
.v3:
        outsb
        outsb
        outsb
        outsb
.L3:    stosb
        add  edi,ebp
        dec  ecx
        je   .zero
        outsb
        outsb
        outsb
        outsb
        push ecx
        mov  ecx,8
.w3:    loop .w3
        pop  ecx
        cmp  [es:edi-50h],ah
        jne  .L3
        jmp  .zero
.v4:
        outsb
        outsb
        outsb
        outsb
.L4:    stosb
        add  edi,ebp
        dec  ecx
        je   .zero
        push ecx
        mov  ecx,8
.u4:    loop .u4
        pop  ecx
        outsb
        outsb
        outsb
        outsb
        cmp  [es:edi-50h],ah
        jne  .L4
        jmp  .zero
.zero:  mov  al,[es:edi-50h]    ; static re-read of the exit compare
        mov  [fs:tcrnow],al
        mov  al,0
        out  7Ch,al
        ; expected: ECX = C0-(k+1), ESI = s0 + 4*(k+2), EDI = e0 + 80*(k+1)
        mov  ebx,[fs:kk]
        lea  eax,[ebx+1]
        add  [fs:n_rows],eax
        mov  edx,C0
        sub  edx,eax
        cmp  ecx,edx
        jne  .bad
        imul edx,eax,80
        add  edx,[fs:e0]
        cmp  edi,edx
        jne  .bad
        lea  edx,[ebx*4+8]
        add  edx,[fs:s0]
        cmp  esi,edx
        je   .ok
.bad:   inc  dword [fs:e_exit]
        cmp  dword [fs:f_info],0
        jne  .ok
        mov  edx,C0
        sub  edx,ecx         ; rows actually written
        shl  edx,16
        or   edx,ebx         ; | k
        mov  [fs:f_info],edx
        mov  eax,[fs:col]
        shl  eax,8
        mov  al,[fs:tcrnow]
        mov  [fs:f_info2],eax
.ok:    ; plane check rows 0..k (min with rows actually written)
        mov  esi,[fs:s0]
        mov  edi,[fs:e0]
        mov  ecx,[fs:kk]
        inc  ecx
.pc:    mov  eax,[esi]       ; Ti = {E,G,R,B}
        push ds
        mov  bx,28h          ; flat
        mov  ds,bx
        cmp  al,[edi+0A8000h]
        jne  .pbad
        cmp  ah,[edi+0B0000h]
        jne  .pbad
        shr  eax,16
        cmp  al,[edi+0B8000h]
        jne  .pbad
        cmp  ah,[edi+0E0000h]
        je   .pok
.pbad:  inc  dword [fs:e_data]
.pok:   pop  ds
        add  esi,4
        add  edi,80
        dec  ecx
        jnz  .pc
        mov  esi,[fs:s0]
        mov  eax,[fs:kk]
        lea  esi,[esi+eax*4+8]
        inc  dword [fs:col]
        cmp  dword [fs:col],NCOL
        jb   .dcol
        ; back to real mode
        jmp  30h:.p16
        bits 16
.p16:   mov  ax,38h
        mov  ds,ax
        mov  es,ax
        mov  fs,ax
        mov  gs,ax
        mov  ss,ax
        jmp  back16
        bits 32
rnd:    mov  eax,[fs:seed]   ; xorshift32
        mov  edx,eax
        shl  edx,13
        xor  eax,edx
        mov  edx,eax
        shr  edx,17
        xor  eax,edx
        mov  edx,eax
        shl  edx,5
        xor  eax,edx
        mov  [fs:seed],eax
        ret

; ------------------------------------------------------------------------------------------
        bits 16
puts:   mov  ah,9
        int  21h
        ret
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
.o:     mov  dl,al
        mov  ah,2
        int  21h
        ret

        align 8
gdt:    dq 0
        dw 0FFFFh,0, 9A00h,0040h      ; 08 code32, base cs*16, limit 64K, D=1
        dw 0FFFFh,0, 9200h,0000h      ; 10 vars/stack, base cs*16, limit 64K, B=0
        dw 0FFFFh,0, 9210h,00CFh      ; 18 stream, base 1 MiB, limit 4G
        dw 7FFFh,8000h,920Ah,0000h    ; 20 GVRAM plane 0, base 0xA8000, limit 32K
        dw 0FFFFh,0, 9200h,00CFh      ; 28 flat
        dw 0FFFFh,0, 9A00h,0000h      ; 30 code16, base cs*16
        dw 0FFFFh,0, 9200h,0000h      ; 38 data16, base cs*16
gdt_end:
gdtr:   dw gdt_end-gdt-1
        dd 0
cslin   dd 0
rm_ss   dw 0
rm_sp   dw 0
pass    dw 0
seed    dd 0
col     dd 0
kk      dd 0
s0      dd 0
e0      dd 0
e_exit  dd 0
e_data  dd 0
n_rows  dd 0
f_info  dd 0
f_info2 dd 0
tcrnow  db 0
msg_p   db 'TCRPM pass $'
msg_x   db ' exit_err=$'
msg_d   db ' plane_err=$'
msg_r   db ' rows=$'
msg_f   db ' first=$'
sp1     db ' col|tcr=$'
crlf    db 13,10,'$'
