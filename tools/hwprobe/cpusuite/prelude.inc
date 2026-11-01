; prelude.inc - pre-included (nasm -p) into every z486 test program that CPUSUITE runs on a
; PC-98. It emits no bytes of its own; it overrides the OUT mnemonic so the program's two bench
; ports never reach PC-98 hardware:
;
;   0xE0 (STATUS_PORT)  the verdict. A write of 0x01 (pass) or 0xFF (fail) ends the program in
;                       tb_protected_mode.sv; here it becomes THE TRAP: `not al; out 0x0A,al;
;                       (real mode: re-store 0000:0404); out 0xF0,al; jmp $`. The slave 8259's mask register (port 0x0A, which the
;                       harness set to 0xFF) latches ~AL, and `out 0xF0` is the PC-98 CPU-only reset,
;                       which the firmware returns from through the SS:SP stored at 0000:0404
;                       (the BIOS-top bank's reset entry: `in al,0x35 / test al,0x80 / jnz` then
;                       `mov ss,[0x406] / mov sp,[0x404]` ... `retf`). The harness reads the mask
;                       back. A write of 0x00 is the bench's "running" marker: through DX it is
;                       skipped, as the bench skips it.
;   0xE4 (DATA_PORT)    failure detail: dropped.
;
; Every other port passes through unchanged, so an I/O-permission (IOPL / I/O bitmap) check
; still sees the program's own port number. The dispatch preserves every register and flag:
; it uses only XCHG, LEA, MOVZX and JCXZ, none of which writes a flag, and no stack.
;
; THE TRAP, as bytes that decode the same in 16- and 32-bit code where both run:
;   F6 D0          not al
;   E6 0A          out 0x0A, al        the verdict, latched
;   0F 01 E1       smsw cx             CR0.PE ...
;   F6 C1 01       test cl, 1
;   75 10          jnz +16             ... set: skip the real-mode-only part
;   31 C9          xor cx, cx          real mode (16-bit): a program may have used 0000:0404
;   8E D9          mov ds, cx          as scratch, so store the harness's SS:SP there again
;   C7 06 04 04 lo hi   mov word [0x404], CPUS_LAND_SP
;   C7 06 06 04 lo hi   mov word [0x406], CPUS_LAND_SS
;   E6 F0          out 0xF0, al        the CPU reset
;   EB FE          jmp $
CPUS_LAND_SP equ 0x0010          ; cpusuite.asm land_stack (its engine offset)
CPUS_LAND_SS equ 0x9F00          ; cpusuite.asm ENGSEG
%define CPUS_TRAP 0xF6,0xD0,0xE6,0x0A,0x0F,0x01,0xE1,0xF6,0xC1,0x01,0x75,0x10,0x31,0xC9,0x8E,0xD9,0xC7,0x06,0x04,0x04,CPUS_LAND_SP & 0xFF,CPUS_LAND_SP >> 8,0xC7,0x06,0x06,0x04,CPUS_LAND_SS & 0xFF,CPUS_LAND_SS >> 8,0xE6,0xF0,0xEB,0xFE

%macro out 2
 %ifidni %1, dx
  %ifdef CPUS_OUTLINE
    ; The dispatch below is ~66 bytes. A program that pads to a fixed layout (TIMES n-($-$$))
    ; cannot take it inline, so the site holds only a JMP and the dispatch goes to a section of
    ; its own after the program's code (gen_cpusuite.py selects this per program).
    jmp near %%stub
  %%back:
    [section .cpustub align=1]
  %%stub:
  %endif
    xchg dx, cx
    lea cx, [ecx-0xE0]
    jcxz %%e0
    lea cx, [ecx-0x04]
    jcxz %%e4
    lea cx, [ecx+0xE4]
    xchg dx, cx
    out dx, %2
    jmp %%done
  %%e4:
    lea cx, [ecx+0xE4]
    xchg dx, cx
    jmp %%done
  %%e0:
    lea cx, [ecx+0xE0]
    xchg dx, cx             ; DX = 0xE0 again: its 16 bits are free scratch below
    xchg dx, ax             ; DX = caller's AX
    movzx ax, dl            ; AX = caller's AL
    xchg ax, cx             ; CX = caller's AL, AX = caller's CX
    jcxz %%zero
    mov al, cl
    db CPUS_TRAP
  %%zero:
    xchg ax, cx             ; CX = caller's CX, AX = 0 (caller's AL)
    xchg dx, ax             ; AX = caller's AX
    mov dx, 0xE0
  %%done:
  %ifdef CPUS_OUTLINE
    jmp near %%back
    __?SECT?__
  %endif
 %else
  %ifdef CPUS_OUTLINE
    jmp near %%stub
  %%back:
    [section .cpustub align=1]
  %%stub:
  %endif
    ; A constant port. A JMP SHORT picks the variant, so the port may be a symbol defined
    ; later in the file (TIMES would need it defined already).
    db 0xEB, ((%1) == 0xE0) * (%%trap - %%base) + ((%1) == 0xE4) * (%%skip - %%base) + ((%1) != 0xE0 && (%1) != 0xE4) * (%%pass - %%base)
  %%base:
  %%trap:
  %ifdef CPUS_STATIC_E0_PROGRESS
    ; This program writes the bench's "running" marker (0) through a constant port: skip it.
    ; Uses the stack, so it is enabled only for the programs that need it (gen_cpusuite.py).
    pushf
    test al, al
    jz %%zero
    db CPUS_TRAP
  %%zero:
    popf
    jmp %%done
  %else
    db CPUS_TRAP
  %endif
  %%skip:
    jmp %%done
  %%pass:
    out %1, %2
  %%done:
  %ifdef CPUS_OUTLINE
    jmp near %%back
    __?SECT?__
  %endif
 %endif
%endmacro
