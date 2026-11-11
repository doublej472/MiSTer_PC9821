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
;   0xE4 (DATA_PORT)    failure detail: the whole EAX at the write (whatever the program's
;                       operand width, so an 8- or 16-bit write is its low byte or word) is kept in
;                       DMA channel 1's address (low word) and count (high word) registers, the
;                       last write only (CPUS_DATA below). CPUSUITE.COM reads them back after the
;                       program and puts DOS's values back.
;
; THE DETAIL REGISTERS. A CPU reset clears every general register but EDX (Intel486 reset state:
; EAX = 0 after a passed or skipped self-test, EDX = the component ID, the rest 0), so nothing
; the program leaves in a register reaches the harness. A latch it can read back must hold it:
; the uPD71071's channel 0/1 address and count registers (8237 compatible: port 0x19 clears the
; byte flip-flop, then 0x01/0x05 = ch0/ch1 address and 0x03/0x07 = their counts take the low byte
; then the high one, and read back the same way; NP2kai io/dmac.c). Channels 0 and 1 have no
; consumer on the machines this runs on and no transfer is started, so a value in them moves no
; data; the harness restores both channels' registers after every program.
;
; Every other port passes through unchanged, so an I/O-permission (IOPL / I/O bitmap) check
; still sees the program's own port number. The dispatch preserves every register and flag:
; it uses only XCHG, LEA, MOVZX, JCXZ, BSWAP and OUT imm8,AL, none of which writes a flag, and
; no stack.
;
; THE TRAP, as bytes that decode the same in 16- and 32-bit code where both run. It first keeps
; the EAX it was entered with (the program's AL is the verdict; EAX's upper bytes are often the
; failing case's code) in DMA channel 0:
;   E6 19          out 0x19, al        clear the byte flip-flop
;   E6 01          out 0x01, al        ch0 address low  = EAX[7:0]
;   86 C4          xchg al, ah
;   E6 01          out 0x01, al        ch0 address high = EAX[15:8]
;   86 C4          xchg al, ah
;   C1 C8 10       ror eax, 16 (32-bit) | ror ax, 16 (16-bit: the identity)
;   66 C1 C8 10    ror ax, 16 (32-bit: the identity) | ror eax, 16 (16-bit)
;   E6 03          out 0x03, al        ch0 count low  = EAX[23:16]
;   86 C4          xchg al, ah
;   E6 03          out 0x03, al        ch0 count high = EAX[31:24]
;   86 C4          xchg al, ah
;   C1 C8 10 66 C1 C8 10               EAX rotated back (the trap writes flags: it never returns)
; then the verdict and the reset:
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
%define CPUS_ROR16 0xC1,0xC8,0x10,0x66,0xC1,0xC8,0x10
%define CPUS_TRAP 0xE6,0x19,0xE6,0x01,0x86,0xC4,0xE6,0x01,0x86,0xC4,CPUS_ROR16,0xE6,0x03,0x86,0xC4,0xE6,0x03,0x86,0xC4,CPUS_ROR16,0xF6,0xD0,0xE6,0x0A,0x0F,0x01,0xE1,0xF6,0xC1,0x01,0x75,0x10,0x31,0xC9,0x8E,0xD9,0xC7,0x06,0x04,0x04,CPUS_LAND_SP & 0xFF,CPUS_LAND_SP >> 8,0xC7,0x06,0x06,0x04,CPUS_LAND_SS & 0xFF,CPUS_LAND_SS >> 8,0xE6,0xF0,0xEB,0xFE

; THE DATA RECORD: EAX into DMA channel 1 (address = EAX[15:0], count = EAX[31:16]). Assembled
; for the code's own BITS (BSWAP gets its 0x66 in 16-bit code; spelled as bytes so a program
; that declares CPU 386 still assembles); EAX and every flag kept.
%macro CPUS_BSWAP_EAX 0
 %if __?BITS?__ == 16
    db 0x66
 %endif
    db 0x0F, 0xC8
%endmacro
%macro CPUS_DATA 0
    db 0xE6, 0x19           ; out 0x19, al: clear the byte flip-flop
    db 0xE6, 0x05           ; out 0x05, al: ch1 address low
    xchg al, ah
    db 0xE6, 0x05           ; ch1 address high
    xchg al, ah
    CPUS_BSWAP_EAX          ; AL = EAX[31:24], AH = EAX[23:16]
    xchg al, ah
    db 0xE6, 0x07           ; ch1 count low = EAX[23:16]
    xchg al, ah
    db 0xE6, 0x07           ; ch1 count high = EAX[31:24]
    CPUS_BSWAP_EAX
%endmacro

%macro out 2
 %ifidni %1, dx
  %ifdef CPUS_OUTLINE
    ; The dispatch below is ~120 bytes. A program that pads to a fixed layout (TIMES n-($-$$))
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
    CPUS_DATA
    jmp %%done
  %%e0:
    lea cx, [ecx+0xE0]
    xchg dx, cx             ; DX = 0xE0 again: its 16 bits are free scratch below
    xchg dx, ax             ; DX = caller's AX
    movzx ax, dl            ; AX = caller's AL
    xchg ax, cx             ; CX = caller's AL, AX = caller's CX
    jcxz %%zero
    xchg dx, ax             ; EAX = the caller's EAX again (AL = the verdict) for THE TRAP to
    db CPUS_TRAP            ; keep: `mov al, cl` here left AH = the caller's CH (--simcheck's
                            ; trap-EAX probe catches that)
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
    CPUS_DATA
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
