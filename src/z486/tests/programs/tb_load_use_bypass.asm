; Direct-load -> consumer dependency bench.
;
; The pending-load EA interlock exists for exactly one consumer class: an
; instruction whose EA is formed from the register a direct load is about to
; write.  The i486 retains its one-cycle pointer interlock there
; (hardwired_control.sv: "EA base/index dependencies ... retain the i486
; one-cycle pointer-load interlock").  Register-direct consumers have no EA to
; form and read their data operand in EX, one cycle later, from the forwarded
; write-back; they must cost no cycle at all.
;
; This bench asserts both sides on the same loop shape, against a control loop
; whose consumer reads no register the load writes (a 2-byte mov r8,r8, so the
; loop layout and decode grouping are identical):
;
;   * every register-direct consumer class costs at most half a cycle per
;     iteration over its control loop (0 after the interlock is narrowed;
;     1 before, because dec_ea_onehots ignores mod and reports the ModR/M rm
;     field as an EA base even for mod=11);
;   * the memory form, whose base is the loaded register, still costs at least
;     half a cycle per iteration: the real pointer interlock stays;
;   * every class reads the loaded value (architectural guard), and the
;     memory form is a single shot whose producer loads a NEW pointer over an
;     old one, so removing the pointer interlock sends the consumer's EA to
;     the old target and the value check fails.
;
; Port 0xFC reads the testbench cycle counter; port 0xE4 reports each measured
; delta (loop A minus control), port 0xE0 the pass/fail verdict.

BITS 32
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
CYCLE_PORT  equ 0xFC
STATUS_PASS equ 0x01
STATUS_FAIL equ 0xFF

; DS offsets.  ESI points at TGT; PTR sits 0x40 below it, so one register
; serves both loop shapes (and ESI defaults to DS, unlike EBP).
PTR         equ 0x1040
TGT         equ 0x1080
ALT         equ 0x10C0
T0          equ 0x1100
SAVED_ESP   equ 0x1104

R_TEST      equ 0x1110
C_TEST      equ 0x1114
R_CMP       equ 0x1118
C_CMP       equ 0x111c
R_ADD       equ 0x1120
C_ADD       equ 0x1124
R_MOV       equ 0x1128
C_MOV       equ 0x112c
R_AH        equ 0x1130
C_AH        equ 0x1134
R_MZX       equ 0x1138
C_MZX       equ 0x113c
R_MEM       equ 0x1140
C_MEM       equ 0x1144
R_MEM_SUM   equ 0x1148
C_MEM_SUM   equ 0x114c

ITERS       equ 256
MAX_REG     equ ITERS/2     ; register forms: at most half a cycle per iteration
MIN_MEM     equ ITERS/2     ; memory form: at least half a cycle per iteration

VALUE       equ 0x5A17C0DE
ALT_VALUE   equ 0xC01DCAFE
SUM256      equ (VALUE * ITERS) & 0xffffffff

; %1 = producer destination, %2 = consumer instruction, %3 = producer source.
; The consumer issues immediately after the load; the loop tail (dec/jnz) is
; identical everywhere.
%macro TIME_LOOP 3
    in eax, CYCLE_PORT
    mov [T0], eax
    mov edi, ITERS
%%loop:
    mov %1, %3
    %2
    dec edi
    jnz %%loop
    in eax, CYCLE_PORT
    sub eax, [T0]
%endmacro

start:
    mov esi, TGT            ; register classes load the value itself
    mov dword [PTR], TGT
    mov dword [TGT], VALUE
    mov dword [ALT], ALT_VALUE
    mov dword [T0], 0

    ; Fill the code line, the data lines and the TLB so every producer below is
    ; a hot direct load, and drain the initialization stores.
    times 32 nop
    mov eax, [esi]
    mov eax, [esi - 0x40]
    mov ebx, [eax]
    mov eax, [ALT]
    mov dword [PTR], TGT
    mov dword [TGT], VALUE
    mov dword [ALT], ALT_VALUE
    mov ecx, 1
    mov edx, 0
    mov ebx, 0
    mov eax, 0
    times 32 nop

    ; --- (a) architectural: each consumer reads the loaded value ----------
    ; a1: test al,al  (ModR/M rm=000 -> EAX)
    mov eax, 0
    mov eax, [esi]
    test al, al
    jz fail1
    cmp al, VALUE & 0xff
    jne fail1

    ; a2: cmp cl,al   (rm=001 -> ECX)
    mov eax, VALUE & 0xff
    mov ecx, 0
    mov ecx, [esi]
    cmp cl, al
    jne fail2
    cmp ecx, VALUE
    jne fail2

    ; a3: add dl,cl   (rm=010 -> EDX)
    mov ecx, 1
    mov edx, 0
    mov edx, [esi]
    add dl, cl
    cmp dl, (VALUE & 0xff) + 1
    jne fail3

    ; a4: mov bl,bl   (rm=011 -> EBX)
    mov ebx, 0
    mov ebx, [esi]
    mov bl, bl
    cmp bl, VALUE & 0xff
    jne fail4
    cmp ebx, VALUE
    jne fail4

    ; a5: high-byte read of the loaded value.  The byte form's rm=100 names
    ; AH but dec_ea_onehots decodes it as ESP, so this pair is not held today;
    ; it guards the AH forwarding path the AL classes rely on.
    mov eax, 0
    mov eax, [esi]
    test ah, ah
    jz fail5
    cmp ah, (VALUE >> 8) & 0xff
    jne fail5

    ; a6: movzx ebx,al (rm=000 -> EAX)
    mov ebx, 0
    mov eax, 0
    mov eax, [esi]
    movzx ebx, al
    cmp ebx, VALUE & 0xff
    jne fail6

    ; a7: memory consumer, EA base is the loaded pointer.  The old EAX points
    ; at ALT; the load replaces it with TGT.  Without the pointer interlock the
    ; EA adder sees ALT and the value check fails.
    mov eax, ALT
    mov eax, [esi - 0x40]
    cmp eax, TGT
    jne fail8
    mov ebx, [eax]
    cmp ebx, VALUE
    jne fail7

    ; --- (b) cycle cost of each register-direct class ----------------------
    TIME_LOOP eax, {mov bl, bl}, [esi]
    mov [C_TEST], eax
    TIME_LOOP eax, {test al, al}, [esi]
    mov [R_TEST], eax

    TIME_LOOP ecx, {mov dl, dl}, [esi]
    mov [C_CMP], eax
    TIME_LOOP ecx, {cmp cl, al}, [esi]
    mov [R_CMP], eax

    TIME_LOOP edx, {mov bl, bl}, [esi]
    mov [C_ADD], eax
    TIME_LOOP edx, {add dl, cl}, [esi]
    mov [R_ADD], eax

    TIME_LOOP ebx, {mov dl, dl}, [esi]
    mov [C_MOV], eax
    TIME_LOOP ebx, {mov bl, bl}, [esi]
    mov [R_MOV], eax

    mov [SAVED_ESP], esp
    TIME_LOOP esp, {mov bl, bl}, [esi]
    mov [C_AH], eax
    TIME_LOOP esp, {test ah, ah}, [esi]
    mov [R_AH], eax
    mov esp, [SAVED_ESP]

    ; The 0F escape costs a dead-slot handoff on its own (candidate 2 in the
    ; study), so the movzx control is a movzx whose ModR/M rm names a register
    ; the load does not write: same length, same decode path.
    TIME_LOOP eax, {movzx ebx, cl}, [esi]
    mov [C_MZX], eax
    TIME_LOOP eax, {movzx ebx, al}, [esi]
    mov [R_MZX], eax

    ; --- (c) the memory form keeps its one-cycle pointer interlock ---------
    ; The consumer accumulates the loaded dword, so the loop checks the value
    ; as well as the cost: a stale EA base (the old pointer -> ALT) would sum
    ; ALT_VALUE instead of VALUE, and the memory-form delta must stay near one
    ; cycle per iteration.
    mov ebx, 0
    TIME_LOOP eax, {add ebx, [esi]}, [esi - 0x40]
    mov [C_MEM], eax
    mov [C_MEM_SUM], ebx
    mov ebx, 0
    TIME_LOOP eax, {add ebx, [eax]}, [esi - 0x40]
    mov [R_MEM], eax
    mov [R_MEM_SUM], ebx
    cmp dword [C_MEM_SUM], SUM256
    jne fail18
    cmp dword [R_MEM_SUM], SUM256
    jne fail17

    ; --- verdict ----------------------------------------------------------
    mov eax, [R_TEST]
    sub eax, [C_TEST]
    out DATA_PORT, eax
    cmp eax, MAX_REG
    jg fail10

    mov eax, [R_CMP]
    sub eax, [C_CMP]
    out DATA_PORT, eax
    cmp eax, MAX_REG
    jg fail11

    mov eax, [R_ADD]
    sub eax, [C_ADD]
    out DATA_PORT, eax
    cmp eax, MAX_REG
    jg fail12

    mov eax, [R_MOV]
    sub eax, [C_MOV]
    out DATA_PORT, eax
    cmp eax, MAX_REG
    jg fail13

    mov eax, [R_AH]
    sub eax, [C_AH]
    out DATA_PORT, eax
    cmp eax, MAX_REG
    jg fail14

    mov eax, [R_MZX]
    sub eax, [C_MZX]
    out DATA_PORT, eax
    cmp eax, MAX_REG
    jg fail15

    mov eax, [R_MEM]
    sub eax, [C_MEM]
    out DATA_PORT, eax
    cmp eax, MIN_MEM
    jl fail16

pass:
    mov al, STATUS_PASS
    mov dx, STATUS_PORT
    out dx, al
hang:
    hlt
    jmp hang

fail1:  mov eax, 1
    jmp fail
fail2:  mov eax, 2
    jmp fail
fail3:  mov eax, 3
    jmp fail
fail4:  mov eax, 4
    jmp fail
fail5:  mov eax, 5
    jmp fail
fail6:  mov eax, 6
    jmp fail
fail7:  mov eax, ebx
    jmp fail
fail8:  mov eax, eax
    jmp fail
fail10: mov eax, 10
    jmp fail
fail11: mov eax, 11
    jmp fail
fail12: mov eax, 12
    jmp fail
fail13: mov eax, 13
    jmp fail
fail14: mov eax, 14
    jmp fail
fail15: mov eax, 15
    jmp fail
fail16: mov eax, 16
    jmp fail
fail17: mov eax, [R_MEM_SUM]
    jmp fail
fail18: mov eax, 18
fail:
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    jmp hang
