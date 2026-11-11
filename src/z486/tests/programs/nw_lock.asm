; nw_lock - CR0.CD=1/NW=1: locked RMW on a cached line
;
; A locked read bypasses a valid line and reads memory; with NW=1 the locked
; write hits the line and stays cache-only.  So the second LOCK INC reads the
; memory copy (still 10) and one increment is lost: a real Am486DX4 reads 11
; (CPUSUITE-XE10 run 4: this program's FAIL data 0000000Bh).  z486 observes
; its own cache-only store and reads 12.  Both are accepted; any other value
; (a lost line, a double increment) fails.  Whether z486 should lose the
; increment too is an open owner decision (CD=1/NW=1 is not a run
; configuration of any known guest).
; Failure data = the value read back.
BITS 32
ORG 0
start:
    mov esp, 0x8000
    mov dword [0x34000], 10
    mov eax, [0x34000]                ; allocate the line (CD=0)
    mov ecx, cr0
    or ecx, 0x60000000                ; CD=1, NW=1
    mov cr0, ecx
    lock inc dword [0x34000]
    lock inc dword [0x34000]
    mov ebx, [0x34000]
    and ecx, ~0x60000000
    mov cr0, ecx
    cmp ebx, 11                       ; the Am486DX4 (increment lost)
    je pass
    cmp ebx, 12                       ; z486 (its own store observed)
    jne fail
pass:
    mov al, 1
    out 0xe0, al
    hlt
fail:
    mov eax, ebx
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt
