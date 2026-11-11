; speed.asm - SPEED.COM: the core's effective speed against the real machine's, one binary on both.
;
;   SPEED > SPEED.TXT
;
; WHY. A game that paces itself by its own loops (Galf Streem on the Xe10 vs the core) runs at
; the speed of the CPU, the memory and the I/O it touches, not at the speed of a clock the guest
; can see. This probe puts one number on each of those, on the core and on the machine, with the
; SAME binary and the same time base, so `speed_decode.py A B` can give ratios.
;
; WHAT IT MEASURES (every row timed with the ARTIC, the 307.2 kHz 24-bit counter at 0x5C/0x5E,
; read as xe10t/lib.inc artic_read does; interrupts off while a row runs):
;   ID      the image's CRC-32 and size (speed_decode.py refuses to compare two binaries)
;   PITCAL  PIT channel 0 counted against the ARTIC in windows between two reloads (the time
;           base cross-check: 2457600/307200 = 8.0 or 1996800/307200 = 6.5, by the 0x0501 strap)
;   DHRY    the gate's Dhrystone 2.1 (src/z486/tests/dhrystone, the gate Makefile's CFLAGS, -O2,
;           its dhrystone.ld; built by speed/mkblob.py) at 10000 and 100000 iterations, run in
;           32-bit protected mode from conventional memory (segment base = the image), timed
;           between its own MARK_START and MARK_END (the `out 0xE4` writes, turned into INT 40h),
;           and its own validation result (0 = pass)
;   ROW     LOOP (dec/jnz shell), ALU (4 register ops + shell), IN02/INA0 (`in al,dx` + shell:
;           0x02 the master PIC's mask, 0xA0 the text GDC's status - both side-effect-free reads
;           the Xe10 survived in IO.TXT, see xe10t/sec_io.inc), MOVSD/STOSD/LODSB (rep string
;           ops over 16 KiB of conventional RAM), GSTOSB/GSTOSW/GSTOSD (rep stos over the 32 KiB
;           blue plane at 0xA8000), TSTOSW (rep stosw over 4 KiB of text VRAM at 0xA1000, below
;           the visible 25 lines); three trials each, the fastest kept
;   END:SPEED
;
; SAFETY / RESTORE. Plain DOS, no EMM386 (it enters protected mode directly; HIMEM is harmless:
; only conventional memory is used). Needs 320 KiB free above its own segment. GRCG set off
; (0x7C <- 0, the DOS-prompt state). The blue plane and the 4 KiB of text VRAM are saved first
; and put back. The DOS clock loses the time spent with interrupts off (about 20 s).
;
; BUILD: make -C tools/hwprobe speed/speed.com   (NASM + the gate's Dhrystone, gcc -m32)
        cpu 486
        org 100h
        bits 16

SEGOFF_BLOB equ 1000h        ; segments above CS: the Dhrystone image
SEGOFF_SAVE equ 2000h        ; the VRAM save area
SEGOFF_SRC  equ 3000h        ; string-op source
SEGOFF_DST  equ 4000h        ; string-op destination
SEGOFF_TOP  equ 5000h
NTRIAL      equ 3

start:  cld
        mov  word [lb_len],0
        mov  ax,[2]                ; PSP: first segment past our memory
        mov  bx,cs
        add  bx,SEGOFF_TOP
        cmp  ax,bx
        jae  .memok
        mov  dx,msg_nomem
        mov  ah,9
        int  21h
        mov  ax,4C01h
        int  21h
.memok:
        ; identity: CRC-32 of the pristine image (0x100 .. img_end), before anything is patched
        mov  si,100h
        mov  cx,img_end-100h
        mov  edx,0FFFFFFFFh
.crc:   lodsb
        xor  dl,al
        mov  bx,8
.cb:    shr  edx,1
        jnc  .cn
        xor  edx,0EDB88320h
.cn:    dec  bx
        jnz  .cb
        loop .crc
        not  edx
        mov  [crc],edx
        mov  si,s_id
        call puts
        mov  eax,[crc]
        call px8
        mov  si,s_size
        call puts
        mov  eax,img_end-100h
        call pdec
        call nl

        mov  ax,cs
        movzx eax,ax
        shl  eax,4
        mov  [cslin],eax
        mov  [rmseg],cs
        mov  ebx,eax
        mov  di,gdt+08h
        call setbase
        mov  di,gdt+10h
        call setbase
        mov  di,gdt+28h
        call setbase
        mov  di,gdt+30h
        call setbase
        mov  ebx,eax
        add  ebx,gdt
        mov  [gdtr+2],ebx
        mov  ebx,eax
        add  ebx,idt
        mov  [idtr+2],ebx
        mov  ax,cs
        add  ax,SEGOFF_BLOB
        mov  [seg_blob],ax
        movzx ebx,ax
        shl  ebx,4
        mov  di,gdt+18h
        call setbase
        mov  di,gdt+20h
        call setbase
        ; the IDT: vectors 0-3Fh -> fault, 40h -> mark, 41h -> done (32-bit interrupt gates)
        mov  di,idt
        xor  cx,cx
.idt:   mov  ax,pm_fault
        cmp  cx,40h
        jne  .i1
        mov  ax,pm_mark
.i1:    cmp  cx,41h
        jne  .i2
        mov  ax,pm_done
.i2:    mov  [di],ax
        mov  word [di+2],08h
        mov  word [di+4],8E00h
        mov  word [di+6],0
        add  di,8
        inc  cx
        cmp  cx,42h
        jb   .idt
        call pitcal

        mov  si,blob1
        mov  cx,blob1_end-blob1
        mov  eax,10000
        call dhry
        mov  si,blob2
        mov  cx,blob2_end-blob2
        mov  eax,100000
        call dhry
        mov  si,blob2
        mov  cx,blob2_end-blob2
        mov  eax,100000
        call dhry

        ; the loop rows
        xor  al,al
        out  7Ch,al                ; GRCG off
        push ds
        push es
        mov  ax,0A800h             ; save the blue plane
        mov  ds,ax
        mov  ax,cs
        add  ax,SEGOFF_SAVE
        mov  es,ax
        xor  si,si
        xor  di,di
        mov  cx,4000h
        rep  movsw
        mov  ax,0A000h             ; save text VRAM 0x1000-0x1FFF
        mov  ds,ax
        mov  si,1000h
        mov  di,8000h
        mov  cx,800h
        rep  movsw
        pop  es
        pop  ds

        mov  si,rows
.rl:    cmp  word [si],0
        je   .rdone
        call row
        add  si,ROWSZ
        jmp  .rl
.rdone:
        push ds
        push es
        mov  ax,cs
        add  ax,SEGOFF_SAVE
        mov  ds,ax
        mov  ax,0A800h
        mov  es,ax
        xor  si,si
        xor  di,di
        mov  cx,4000h
        rep  movsw
        mov  ax,0A000h
        mov  es,ax
        mov  si,8000h
        mov  di,1000h
        mov  cx,800h
        rep  movsw
        pop  es
        pop  ds
        mov  si,s_restore
        call puts
        call nl
        mov  si,s_end
        call puts
        call nl
        mov  ax,4C00h
        int  21h

; ------------------------------------------------------------------------------------------
; setbase: DI = descriptor, EBX = base (below 16 MiB)
setbase:
        mov  [di+2],bx
        push ebx
        shr  ebx,16
        mov  [di+4],bl
        mov  [di+7],bh
        pop  ebx
        ret

; artic_read: EAX = the 24-bit ARTIC (xe10t/lib.inc artic_read's method: the high byte at 0x5F
; before and after a coherent low word from two 16-bit reads of 0x5C within 2 ticks)
artic_read:
        push bx
        push cx
        push dx
.a1:    in   al,5Fh
        mov  cl,al
        mov  dx,5Ch
        in   ax,dx
.a2:    mov  bx,ax
        in   ax,dx
        push ax
        sub  ax,bx
        cmp  ax,2
        pop  ax
        ja   .a2
        mov  bx,ax
        in   al,5Fh
        cmp  al,cl
        jne  .a1
        movzx eax,cl
        shl  eax,16
        mov  ax,bx
        pop  dx
        pop  cx
        pop  bx
        ret

; artic_sync: wait for the low byte to change (bounded), then artic_read
artic_sync:
        push cx
        in   al,5Ch
        mov  ah,al
        mov  cx,0FFFFh
.s1:    in   al,5Ch
        cmp  al,ah
        jne  .s2
        loop .s1
.s2:    pop  cx
        jmp  artic_read

; ------------------------------------------------------------------------------------------
; PIT channel 0 against the ARTIC
pit_read:                          ; AX = latched count, in the measured byte order
        push dx
        xor  al,al
        out  77h,al
        in   al,71h
        mov  dl,al
        in   al,71h
        mov  dh,al
        cmp  byte [pit_swap],0
        je   .p1
        xchg dl,dh
.p1:    mov  ax,dx
        pop  dx
        ret

pitcal:
        cli
        ; byte order: over 64 paired reads the LSB changes on almost every read (xe10t pit_cal)
        xor  si,si
        xor  di,di
        xor  al,al
        out  77h,al
        in   al,71h
        mov  bl,al
        in   al,71h
        mov  bh,al
        mov  cx,64
.o1:    xor  al,al
        out  77h,al
        in   al,71h
        cmp  al,bl
        je   .o2
        inc  si
.o2:    mov  bl,al
        in   al,71h
        cmp  al,bh
        je   .o3
        inc  di
.o3:    mov  bh,al
        loop .o1
        mov  byte [pit_swap],0
        cmp  di,si
        jbe  .o4
        mov  byte [pit_swap],1
.o4:    ; the reload value: the largest count seen over 40000 reads
        xor  bx,bx
        mov  ecx,40000
.m1:    call pit_read
        cmp  ax,bx
        jbe  .m2
        mov  bx,ax
.m2:    dec  ecx
        jnz  .m1
        mov  [pit_max],bx
        mov  dword [c_art],0
        mov  dword [c_pit],0
        mov  word [c_win],0
        mov  word [c_try],0
.w0:    inc  word [c_try]
        cmp  word [c_try],64
        ja   .wend
        ; wait for a count above 3/4 of the reload, bounded
        mov  ax,[pit_max]
        shr  ax,2
        mov  dx,ax                 ; lo = max/4
        mov  bx,[pit_max]
        sub  bx,ax                 ; hi = 3/4 max
        mov  ecx,2000000
.w1:    call pit_read
        cmp  ax,bx
        jae  .w2
        dec  ecx
        jnz  .w1
        jmp  .wend
.w2:    call artic_sync
        mov  [c_a0],eax
        call pit_read
        mov  [c_p0],ax
        mov  bp,ax
        mov  ecx,4000000
.w3:    call pit_read
        cmp  ax,bp
        ja   .w0                   ; a reload came first: try again
        mov  bp,ax
        cmp  ax,dx
        jb   .w4
        dec  ecx
        jnz  .w3
        jmp  .wend
.w4:    call artic_sync
        sub  eax,[c_a0]
        and  eax,0FFFFFFh
        push eax
        call pit_read
        movzx eax,ax
        movzx ebx,word [c_p0]
        cmp  eax,ebx
        ja   .w5
        sub  ebx,eax
        pop  eax
        add  [c_art],eax
        add  [c_pit],ebx
        inc  word [c_win]
        cmp  word [c_win],8
        jb   .w0
        jmp  .wend
.w5:    pop  eax
        jmp  .w0
.wend:  sti
        mov  si,s_pitcal
        call puts
        push es
        xor  ax,ax
        mov  es,ax
        mov  al,[es:0501h]
        pop  es
        call px2
        mov  si,s_order
        call puts
        movzx eax,byte [pit_swap]
        call pdec
        mov  si,s_max
        call puts
        movzx eax,word [pit_max]
        call pdec
        mov  si,s_win
        call puts
        movzx eax,word [c_win]
        call pdec
        mov  si,s_art
        call puts
        mov  eax,[c_art]
        call pdec
        mov  si,s_pit
        call puts
        mov  eax,[c_pit]
        call pdec
        call nl
        ret

; ------------------------------------------------------------------------------------------
; dhry: SI = blob, CX = its length, EAX = its DHRY_ITERS
dhry:
        mov  [d_iters],eax
        push es
        mov  es,[seg_blob]
        xor  di,di
        rep  movsb
        pop  es
        mov  dword [d_t0],0
        mov  dword [d_t1],0
        mov  dword [d_res],0FFFFFFFFh
        mov  dword [d_other],0
        mov  byte [d_fault],0
        mov  byte [d_nmark],0
        mov  [rm_ss],ss            ; this call's own stack (the return address is on it)
        mov  [rm_sp],sp
        cli
        call artic_read
        mov  [d_enter],eax
        lidt [idtr]
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
        lidt [rmidtr]
        sti
        ; report
        mov  si,s_dhry
        call puts
        mov  eax,[d_iters]
        call pdec
        mov  si,s_art
        call puts
        mov  eax,[d_t1]
        sub  eax,[d_t0]
        and  eax,0FFFFFFh
        mov  [d_ticks],eax
        call pdec
        mov  si,s_total
        call puts
        mov  eax,[d_done]
        sub  eax,[d_enter]
        and  eax,0FFFFFFh
        call pdec
        mov  si,s_marks
        call puts
        movzx eax,byte [d_nmark]
        call pdec
        mov  si,s_res
        call puts
        mov  eax,[d_res]
        call px8
        mov  si,s_fault
        call puts
        movzx eax,byte [d_fault]
        call pdec
        mov  si,s_dps
        call puts
        mov  ecx,[d_ticks]
        test ecx,ecx
        jz   .z
        mov  eax,[d_iters]
        mov  ebx,307200
        mul  ebx
        div  ecx
        call pdec
        jmp  .v
.z:     mov  al,'-'
        call putc
.v:     mov  si,s_pass
        cmp  dword [d_res],0
        jne  .f
        cmp  byte [d_fault],0
        jne  .f
        cmp  byte [d_nmark],2
        je   .p
.f:     mov  si,s_failv
.p:     call puts
        call nl
        ret

        bits 32
pm32:   mov  ax,10h
        mov  fs,ax
        mov  ax,20h
        mov  ds,ax
        mov  es,ax
        mov  gs,ax
        mov  ss,ax
        mov  esp,0FFF0h
        jmp  18h:0

artic32:                           ; EAX = ARTIC (as artic_read)
        push ebx
        push ecx
        push edx
.a1:    in   al,5Fh
        mov  cl,al
        mov  dx,5Ch
        in   ax,dx
.a2:    mov  bx,ax
        in   ax,dx
        push eax
        sub  ax,bx
        cmp  ax,2
        pop  eax
        ja   .a2
        mov  bx,ax
        in   al,5Fh
        cmp  al,cl
        jne  .a1
        movzx eax,cl
        shl  eax,16
        mov  ax,bx
        pop  edx
        pop  ecx
        pop  ebx
        ret

pm_mark:                           ; INT 40h: MARK_START / MARK_END (EAX = the marker)
        push eax
        push ebx
        mov  ebx,eax
        call artic32
        shr  ebx,16
        cmp  bx,0D001h
        jne  .m1
        mov  [fs:d_t0],eax
        inc  byte [fs:d_nmark]
        jmp  .m3
.m1:    cmp  bx,0D002h
        jne  .m2
        mov  [fs:d_t1],eax
        inc  byte [fs:d_nmark]
        jmp  .m3
.m2:    mov  [fs:d_other],eax
.m3:    pop  ebx
        pop  eax
        iretd

pm_done:                           ; INT 41h: dhrystone_main returned EAX
        mov  [fs:d_res],eax
        call artic32
        mov  [fs:d_done],eax
        jmp  pm_exit
pm_fault:
        mov  byte [fs:d_fault],1
        call artic32
        mov  [fs:d_done],eax
pm_exit:
        jmp  28h:p16
        bits 16
p16:    mov  ax,30h
        mov  ds,ax
        mov  es,ax
        mov  fs,ax
        mov  gs,ax
        mov  ss,ax
        jmp  back16

; ------------------------------------------------------------------------------------------
; row: SI = the row entry (fn, count dword, name, ops dword, bytes dword)
ROWSZ   equ  2+4+2+4+4
row:
        push si
        mov  di,tr
        mov  bp,NTRIAL
.t:     push si
        push di
        push bp
        cli
        call artic_sync
        mov  [r_a0],eax
        mov  ecx,[si+2]
        call [si]
        call artic_read
        sti
        pop  bp
        pop  di
        pop  si
        sub  eax,[r_a0]
        and  eax,0FFFFFFh
        mov  [di],eax
        add  di,4
        dec  bp
        jnz  .t
        mov  si,s_row
        call puts
        pop  si
        push si
        push si
        mov  si,[si+6]
        call puts
        pop  si
        push si
        mov  si,s_n
        call puts
        pop  si
        mov  eax,[si+8]
        call pdec
        push si
        mov  si,s_bytes
        call puts
        pop  si
        mov  eax,[si+12]
        call pdec
        mov  si,s_art
        call puts
        mov  eax,[tr]              ; the fastest trial
        cmp  eax,[tr+4]
        jbe  .m1
        mov  eax,[tr+4]
.m1:    cmp  eax,[tr+8]
        jbe  .m2
        mov  eax,[tr+8]
.m2:    call pdec
        mov  si,s_t
        call puts
        mov  eax,[tr]
        call pdec
        mov  al,','
        call putc
        mov  eax,[tr+4]
        call pdec
        mov  al,','
        call putc
        mov  eax,[tr+8]
        call pdec
        call nl
        pop  si
        ret

f_loop: dec  ecx
        jnz  f_loop
        ret
f_alu:  add  eax,ebx
        xor  edx,eax
        add  ebx,edx
        rol  eax,3
        dec  ecx
        jnz  f_alu
        ret
f_in02: mov  dx,02h
.l:     in   al,dx
        dec  ecx
        jnz  .l
        ret
f_inA0: mov  dx,0A0h
.l:     in   al,dx
        dec  ecx
        jnz  .l
        ret
f_movsd:
        push ds
        push es
        mov  ax,cs
        add  ax,SEGOFF_SRC
        mov  ds,ax
        add  ax,SEGOFF_DST-SEGOFF_SRC
        mov  es,ax
        mov  ebp,ecx
.o:     xor  si,si
        xor  di,di
        mov  cx,1000h
        rep  movsd
        dec  ebp
        jnz  .o
        pop  es
        pop  ds
        ret
f_stosd:
        push es
        mov  ax,cs
        add  ax,SEGOFF_DST
        mov  es,ax
        mov  ebp,ecx
        mov  eax,5A5A5A5Ah
.o:     xor  di,di
        mov  cx,1000h
        rep  stosd
        dec  ebp
        jnz  .o
        pop  es
        ret
f_lodsb:
        push ds
        mov  ax,cs
        add  ax,SEGOFF_SRC
        mov  ds,ax
        mov  ebp,ecx
.o:     xor  si,si
        mov  cx,4000h
        rep  lodsb
        dec  ebp
        jnz  .o
        pop  ds
        ret
f_gstosb:
        push es
        mov  ax,0A800h
        mov  es,ax
        mov  ebp,ecx
        xor  eax,eax
.o:     xor  di,di
        mov  cx,8000h
        rep  stosb
        dec  ebp
        jnz  .o
        pop  es
        ret
f_gstosw:
        push es
        mov  ax,0A800h
        mov  es,ax
        mov  ebp,ecx
        xor  eax,eax
.o:     xor  di,di
        mov  cx,4000h
        rep  stosw
        dec  ebp
        jnz  .o
        pop  es
        ret
f_gstosd:
        push es
        mov  ax,0A800h
        mov  es,ax
        mov  ebp,ecx
        xor  eax,eax
.o:     xor  di,di
        mov  cx,2000h
        rep  stosd
        dec  ebp
        jnz  .o
        pop  es
        ret
f_tstosw:
        push es
        mov  ax,0A000h
        mov  es,ax
        mov  ebp,ecx
        mov  ax,0020h
.o:     mov  di,1000h
        mov  cx,800h
        rep  stosw
        dec  ebp
        jnz  .o
        pop  es
        ret

; fn, count (loop iterations / outer reps), name, ops (elements), bytes
rows:   dw f_loop
        dd 4000000
        dw n_loop
        dd 4000000, 0
        dw f_alu
        dd 4000000
        dw n_alu
        dd 4000000, 0
        dw f_in02
        dd 200000
        dw n_in02
        dd 200000, 0
        dw f_inA0
        dd 200000
        dw n_inA0
        dd 200000, 0
        dw f_movsd
        dd 256
        dw n_movsd
        dd 256*4096, 256*16384
        dw f_stosd
        dd 256
        dw n_stosd
        dd 256*4096, 256*16384
        dw f_lodsb
        dd 64
        dw n_lodsb
        dd 64*16384, 64*16384
        dw f_gstosb
        dd 16
        dw n_gstosb
        dd 16*32768, 16*32768
        dw f_gstosw
        dd 16
        dw n_gstosw
        dd 16*16384, 16*32768
        dw f_gstosd
        dd 16
        dw n_gstosd
        dd 16*8192, 16*32768
        dw f_tstosw
        dd 64
        dw n_tstosw
        dd 64*2048, 64*4096
        dw 0

; ------------------------------------------------------------------------------------------
; output: a line buffer, written to stdout (handle 1) at each nl
putc:   push bx
        mov  bx,[lb_len]
        cmp  bx,250
        jae  .x
        mov  [lb+bx],al
        inc  word [lb_len]
.x:     pop  bx
        ret
puts:   push ax
.l:     lodsb
        test al,al
        jz   .e
        call putc
        jmp  .l
.e:     pop  ax
        ret
nl:     push ax
        push bx
        push cx
        push dx
        mov  al,13
        call putc
        mov  al,10
        call putc
        mov  ah,40h
        mov  bx,1
        mov  cx,[lb_len]
        mov  dx,lb
        int  21h
        mov  word [lb_len],0
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret
pdec:   push eax
        push ebx
        push cx
        push edx
        mov  ebx,10
        xor  cx,cx
.d1:    xor  edx,edx
        div  ebx
        push dx
        inc  cx
        test eax,eax
        jnz  .d1
.d2:    pop  ax
        add  al,'0'
        call putc
        loop .d2
        pop  edx
        pop  cx
        pop  ebx
        pop  eax
        ret
px8:    push eax
        shr  eax,16
        call px4
        pop  eax
px4:    push ax
        mov  al,ah
        call px2
        pop  ax
px2:    push ax
        shr  al,4
        call pnib
        pop  ax
pnib:   push ax
        and  al,0Fh
        add  al,'0'
        cmp  al,'9'
        jbe  .o
        add  al,7
.o:     call putc
        pop  ax
        ret

s_id      db 'ID SPEED v1 crc=',0
s_size    db ' size=',0
s_pitcal  db 'PITCAL strap0501=',0
s_order   db ' order=',0
s_max     db ' pitmax=',0
s_win     db ' win=',0
s_art     db ' art=',0
s_pit     db ' pit=',0
s_dhry    db 'DHRY iters=',0
s_total   db ' total=',0
s_marks   db ' marks=',0
s_res     db ' result=',0
s_fault   db ' fault=',0
s_dps     db ' dps=',0
s_pass    db ' PASS',0
s_failv   db ' FAIL',0
s_row     db 'ROW ',0
s_n       db ' n=',0
s_bytes   db ' bytes=',0
s_t       db ' t=',0
s_restore db 'RESTORE vram=put-back grcg=off',0
s_end     db 'END:SPEED',0
msg_nomem db 'SPEED: not enough memory (needs 320 KiB above itself)',13,10,'$'
n_loop    db 'LOOP',0
n_alu     db 'ALU',0
n_in02    db 'IN02',0
n_inA0    db 'INA0',0
n_movsd   db 'MOVSD',0
n_stosd   db 'STOSD',0
n_lodsb   db 'LODSB',0
n_gstosb  db 'GSTOSB',0
n_gstosw  db 'GSTOSW',0
n_gstosd  db 'GSTOSD',0
n_tstosw  db 'TSTOSW',0

        align 8
gdt:    dq 0
        dw 0FFFFh,0, 9A00h,0040h      ; 08 code32, base cs*16, limit 64K, D=1
        dw 0FFFFh,0, 9200h,0000h      ; 10 vars, base cs*16, limit 64K
        dw 0FFFFh,0, 9A00h,00CFh      ; 18 Dhrystone code32, base = the image, 4 GiB
        dw 0FFFFh,0, 9200h,00CFh      ; 20 Dhrystone data/stack, base = the image, 4 GiB
        dw 0FFFFh,0, 9A00h,0000h      ; 28 code16, base cs*16
        dw 0FFFFh,0, 9200h,0000h      ; 30 data16, base cs*16
gdt_end:
gdtr:   dw gdt_end-gdt-1
        dd 0
idtr:   dw 42h*8-1
        dd 0
rmidtr: dw 3FFh
        dd 0

        align 16
blob1:  incbin "speed/build/d10000.bin"
blob1_end:
        align 16
blob2:  incbin "speed/build/d100000.bin"
blob2_end:
img_end:

        section .bss
        alignb 8
idt     resb 42h*8
crc     resd 1
cslin   resd 1
rm_ss   resw 1
rm_sp   resw 1
seg_blob resw 1
pit_swap resb 1
pit_max resw 1
c_art   resd 1
c_pit   resd 1
c_a0    resd 1
c_p0    resw 1
c_win   resw 1
c_try   resw 1
d_iters resd 1
d_t0    resd 1
d_t1    resd 1
d_enter resd 1
d_done  resd 1
d_res   resd 1
d_other resd 1
d_ticks resd 1
d_fault resb 1
d_nmark resb 1
r_a0    resd 1
tr      resd NTRIAL
lb_len  resw 1
lb      resb 256
