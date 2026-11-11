#!/usr/bin/env python3
"""Generate programs/opcode_sweep_486.asm (and an index file): the 0F map, LOCK, FPU-escape and selected
one-byte encodings against the documented Intel486 (no CPUID) behaviour."""
import sys
UD, NM, GP, DB = 6, 7, 13, 1
OK = None
SCR = 0x6000          # scratch dword(s)
FAR = 0x6100          # far pointer: dd 0, dw 0x10
entries = []          # (name, bytes list, expected vector or None, prologue lines, info)
def E(name, b, exp, pro=(), info=False):
    entries.append((name, b, exp, list(pro), info))
def d32(v): return [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]
MEM = lambda reg: [0x05 | (reg << 3)] + d32(SCR)       # [disp32] with reg field
FARM = lambda reg: [0x05 | (reg << 3)] + d32(FAR)
CR0_ = ["mov eax, cr0"]
valid = {}
# ---- 0F map, default UD with ModRM C0 ----
for op in range(256):
    valid[op] = False
for op in [0x00,0x01,0x02,0x03,0x06,0x08,0x09,0x20,0x21,0x22,0x23,0x24,0x26] + \
          list(range(0x80,0xa0)) + [0xa0,0xa1,0xa3,0xa4,0xa5,0xa8,0xa9,0xab,0xac,0xad,0xaf,
           0xb0,0xb1,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xba,0xbb,0xbc,0xbd,0xbe,0xbf,0xc0,0xc1] + \
          list(range(0xc8,0xd0)) + [0x10,0x11,0x12,0x13]:
    valid[op] = True
for op in range(256):
    if not valid[op]:
        E("0F %02X C0" % op, [0x0f, op, 0xc0], UD)
# grp6
E("SLDT eax", [0x0f,0x00,0xc0], OK)
E("STR eax", [0x0f,0x00,0xc8], OK)
E("LLDT null", [0x0f,0x00,0xd0], OK, ["xor eax, eax"])
E("LTR null", [0x0f,0x00,0xd8], GP, ["xor eax, eax"])
E("VERR ax", [0x0f,0x00,0xe0], OK, ["mov eax, 0x10"])
E("VERW ax", [0x0f,0x00,0xe8], OK, ["mov eax, 0x10"])
E("0F 00 /6", [0x0f,0x00,0xf0], UD)
E("0F 00 /7", [0x0f,0x00,0xf8], UD)
# grp7
E("SGDT reg", [0x0f,0x01,0xc0], UD)
E("SGDT mem", [0x0f,0x01]+MEM(0), OK)
E("SIDT reg", [0x0f,0x01,0xc8], UD)
E("SIDT mem", [0x0f,0x01]+MEM(1), OK)
E("LGDT reg", [0x0f,0x01,0xd0], UD)
E("LGDT mem", [0x0f,0x01,0x15]+d32(SCR+0x20), OK, ["sgdt [0x%x]" % (SCR+0x20)])
E("LIDT reg", [0x0f,0x01,0xd8], UD)
E("LIDT mem", [0x0f,0x01,0x1d]+d32(SCR+0x20), OK, ["sidt [0x%x]" % (SCR+0x20)])
E("SMSW reg", [0x0f,0x01,0xe0], OK)
E("SMSW mem", [0x0f,0x01]+MEM(4), OK)
E("0F 01 /5 reg", [0x0f,0x01,0xe8], UD)
E("0F 01 /5 mem", [0x0f,0x01]+MEM(5), UD)
E("LMSW reg", [0x0f,0x01,0xf0], OK, CR0_)
E("INVLPG reg", [0x0f,0x01,0xf8], UD)
E("INVLPG mem", [0x0f,0x01]+MEM(7), OK)
for m in (0xc1,0xc8,0xc9,0xd0,0xd1,0xd8,0xf9):
    E("0F 01 %02X" % m, [0x0f,0x01,m], UD)
E("LAR", [0x0f,0x02,0xc0], OK, ["mov eax, 0x10"])
E("LSL", [0x0f,0x03,0xc0], OK, ["mov eax, 0x10"])
E("CLTS", [0x0f,0x06], OK)
E("INVD", [0x0f,0x08], OK, ["wbinvd"])
E("WBINVD", [0x0f,0x09], OK)
# UMOV (0F 10-13) executes on the 486, no #UD: R. Collins, "Undocumented
# OpCodes: UMOV" (rcollins.org/secrets/opcodes/UMOV.html): "Available on all
# 80386/80486 processors" and "If UMOV is executed by a user program, it will
# appear it is a alias for MOV"; a real Am486DX4 raises no #UD for any form
# (CPUSUITE-XE10-triage: tri_umov).
for op in (0x10,0x11,0x12,0x13):
    E("UMOV 0F %02X C0" % op, [0x0f,op,0xc0], OK)
# MOV CR/DR/TR
for n in range(8):
    E("MOV eax,CR%d" % n, [0x0f,0x20,0xc0|(n<<3)], OK if n in (0,2,3) else UD)
for n in range(8):
    pro = {0:CR0_, 2:["mov eax, cr2"], 3:["mov eax, cr3"]}.get(n, ["xor eax, eax"])
    E("MOV CR%d,eax" % n, [0x0f,0x22,0xc0|(n<<3)], OK if n in (0,2,3) else UD, pro)
E("MOV eax,CR0 mod00", [0x0f,0x20,0x00], OK, info=True)
for n in range(8):
    E("MOV eax,DR%d" % n, [0x0f,0x21,0xc0|(n<<3)], OK)
for n in range(8):
    E("MOV DR%d,eax" % n, [0x0f,0x23,0xc0|(n<<3)], OK, ["xor eax, eax"])
for n in range(8):
    E("MOV eax,TR%d" % n, [0x0f,0x24,0xc0|(n<<3)], OK if n >= 3 else UD)
for n in range(8):
    E("MOV TR%d,eax" % n, [0x0f,0x26,0xc0|(n<<3)], OK if n >= 3 else UD, ["xor eax, eax"])
for op in range(0x80,0x90):
    E("Jcc 0F %02X rel32 0" % op, [0x0f,op,0,0,0,0], OK)
for op in range(0x90,0xa0):
    E("SETcc 0F %02X" % op, [0x0f,op,0xc0], OK)
E("PUSH FS", [0x0f,0xa0], OK)
E("POP FS", [0x0f,0xa1], OK, ["push dword 0x10"])
E("BT", [0x0f,0xa3,0xc0], OK)
E("SHLD imm", [0x0f,0xa4,0xc0,1], OK)
E("SHLD cl", [0x0f,0xa5,0xc0], OK)
E("PUSH GS", [0x0f,0xa8], OK)
E("POP GS", [0x0f,0xa9], OK, ["push dword 0x10"])
E("BTS", [0x0f,0xab,0xc0], OK)
E("SHRD imm", [0x0f,0xac,0xc0,1], OK)
E("SHRD cl", [0x0f,0xad,0xc0], OK)
E("IMUL", [0x0f,0xaf,0xc0], OK)
E("CMPXCHG8", [0x0f,0xb0,0xc0], OK)
E("CMPXCHG", [0x0f,0xb1,0xc0], OK)
E("LSS reg", [0x0f,0xb2,0xc0], UD)
E("LSS mem", [0x0f,0xb2]+FARM(4), OK)      # LSS esp,[FAR] -> esp=0x7f00
E("BTR", [0x0f,0xb3,0xc0], OK)
E("LFS reg", [0x0f,0xb4,0xc0], UD)
E("LFS mem", [0x0f,0xb4]+FARM(0), OK)
E("LGS reg", [0x0f,0xb5,0xc0], UD)
E("LGS mem", [0x0f,0xb5]+FARM(0), OK)
E("MOVZX b", [0x0f,0xb6,0xc0], OK)
E("MOVZX w", [0x0f,0xb7,0xc0], OK)
for r in range(8):
    E("0F BA /%d" % r, [0x0f,0xba,0xc0|(r<<3),1], OK if r >= 4 else UD)
E("BTC", [0x0f,0xbb,0xc0], OK)
E("BSF", [0x0f,0xbc,0xc0], OK, ["mov eax, 1"])
E("BSR", [0x0f,0xbd,0xc0], OK, ["mov eax, 1"])
E("MOVSX b", [0x0f,0xbe,0xc0], OK)
E("MOVSX w", [0x0f,0xbf,0xc0], OK)
E("XADD8", [0x0f,0xc0,0xc0], OK)
E("XADD", [0x0f,0xc1,0xc0], OK)
for op in range(0xc8,0xd0):
    E("BSWAP 0F %02X" % op, [0x0f,op], OK)
E("CMPXCHG8B mem", [0x0f,0xc7]+MEM(1), UD)
E("0F A6 mem", [0x0f,0xa6]+MEM(0), UD)
E("0F A7 mem", [0x0f,0xa7]+MEM(0), UD)
E("0F 0D mem", [0x0f,0x0d]+MEM(1), UD)
E("0F 18 mem", [0x0f,0x18]+MEM(1), UD)
E("0F 1F mem", [0x0f,0x1f]+MEM(0), UD)
# ---- LOCK ----
L = 0xf0
E("LOCK NOP", [L,0x90], UD)
E("LOCK ADD reg", [L,0x01,0xc0], UD)
E("LOCK ADD mem", [L,0x01]+MEM(0), OK)
E("LOCK ADD imm8 mem", [L,0x80]+MEM(0)+[1], OK)
E("LOCK CMP grp1 mem", [L,0x83]+MEM(7)+[1], UD)
E("LOCK CMP mem", [L,0x39]+MEM(0), UD)
E("LOCK MOV mem", [L,0x89]+MEM(0), UD)
E("LOCK MOV imm mem", [L,0xc6]+MEM(0)+[1], UD)
E("LOCK TEST mem", [L,0xf7]+MEM(0)+d32(1), UD)
E("LOCK NOT mem", [L,0xf7]+MEM(2), OK)
E("LOCK NEG byte mem", [L,0xf6]+MEM(3), OK)
E("LOCK MUL mem", [L,0xf7]+MEM(4), UD)
E("LOCK INC byte mem", [L,0xfe]+MEM(0), OK)
E("LOCK DEC mem", [L,0xff]+MEM(1), OK)
E("LOCK PUSH mem", [L,0xff]+MEM(6), UD)
E("LOCK POP mem", [L,0x8f]+MEM(0), UD, ["push dword 0"])
E("LOCK XCHG mem", [L,0x87]+MEM(0), OK)
E("LOCK XCHG reg", [L,0x87,0xc0], UD)
E("LOCK BT mem", [L,0x0f,0xa3]+MEM(0), UD)
E("LOCK BTS mem", [L,0x0f,0xab]+MEM(0), OK)
E("LOCK BTR mem", [L,0x0f,0xb3]+MEM(0), OK)
E("LOCK BTC mem", [L,0x0f,0xbb]+MEM(0), OK)
E("LOCK BT imm mem", [L,0x0f,0xba]+MEM(4)+[1], UD)
E("LOCK BTS imm mem", [L,0x0f,0xba]+MEM(5)+[1], OK)
E("LOCK CMPXCHG mem", [L,0x0f,0xb1]+MEM(0), OK)
E("LOCK CMPXCHG reg", [L,0x0f,0xb1,0xc0], UD)
E("LOCK XADD mem", [L,0x0f,0xc1]+MEM(0), OK)
E("LOCK XADD reg", [L,0x0f,0xc1,0xc0], UD)
E("LOCK BSWAP", [L,0x0f,0xc8], UD)
E("LOCK MOVS", [L,0xa4], UD, ["mov esi, 0x%x" % SCR, "mov edi, 0x%x" % (SCR+8), "cld"])
E("LOCK SHL mem", [L,0xd1]+MEM(4), UD)
E("LOCK ADC mem", [L,0x11]+MEM(0), OK)
E("LOCK OR reg8", [L,0x08,0xc0], UD)
E("LOCK SETcc mem", [L,0x0f,0x94]+MEM(0), UD)
E("LOCK SGDT", [L,0x0f,0x01]+MEM(0), UD)
E("LOCK MOV CR", [L,0x0f,0x20,0xc0], UD)
E("LOCK ADD reg,mem", [L,0x03]+MEM(0), UD)
E("LOCK SUB reg,mem", [L,0x2b]+MEM(0), UD)
E("LOCK MOV reg,mem", [L,0x8b]+MEM(0), UD)
E("LOCK IMUL reg,mem", [L,0x0f,0xaf]+MEM(0), UD)
E("LOCK CMPXCHG8B", [L,0x0f,0xc7]+MEM(1), UD)
E("LOCK SBB mem", [L,0x19]+MEM(0), OK)
E("LOCK XOR imm32 mem", [L,0x81]+MEM(6)+d32(1), OK)
E("LOCK AND mem,reg8", [L,0x20]+MEM(0), OK)
E("LOCK XCHG mem8", [L,0x86]+MEM(0), OK)
E("LOCK XADD mem8", [L,0x0f,0xc0]+MEM(0), OK)
E("LOCK CMPXCHG mem8", [L,0x0f,0xb0]+MEM(0), OK)
E("LOCK NOT reg", [L,0xf7,0xd0], UD)
E("LOCK INC reg 40", [L,0x40], UD)
E("LOCK LEA", [L,0x8d]+MEM(0), UD)
E("LOCK with 66 ADD mem", [0x66,L,0x01]+MEM(0), OK)
E("LOCK seg ovr ADD mem", [L,0x3e,0x01]+MEM(0), OK)
# ---- FPU escapes, 486SX: CR0.EM=1 -> #NM ----
EM = ["mov eax, cr0", "or eax, 4", "mov cr0, eax"]
TSMP = ["mov eax, cr0", "or eax, 0x0a", "and eax, ~4", "mov cr0, eax"]
E("EM FADD", [0xd8,0xc0], NM, EM)
E("EM FNINIT", [0xdb,0xe3], NM, EM)
E("EM FLD mem", [0xd9]+MEM(0), NM, EM)
E("EM FNSTSW ax", [0xdf,0xe0], NM, EM)
E("EM WAIT", [0x9b], OK, EM)
E("TS+MP WAIT", [0x9b], NM, TSMP)
E("TS+MP FADD", [0xd8,0xc0], NM, TSMP)
# ---- one-byte invalid forms ----
E("LES reg", [0xc4,0xc0], UD)
E("LDS reg", [0xc5,0xc0], UD)
E("LDS mem", [0xc5]+FARM(0), OK)
E("LEA reg", [0x8d,0xc0], UD)
E("BOUND reg", [0x62,0xc0], UD)
E("MOV r,seg6", [0x8c,0xf0], UD)
E("MOV CS,r", [0x8e,0xc8], UD, ["mov eax, 8"])
E("MOV seg6,r", [0x8e,0xf0], UD, ["mov eax, 0x10"])
for r in range(2,8):
    E("FE /%d" % r, [0xfe,0xc0|(r<<3)], UD)
E("FF /7", [0xff,0xf8], UD)
E("CALL far reg", [0xff,0xd8], UD)
E("JMP far reg", [0xff,0xe8], UD)
E("SALC", [0xd6], OK, info=True)
E("ICEBP", [0xf1], DB, info=True)
E("ARPL", [0x63,0xc0], OK)

out = []
w = out.append
w("; opcode_sweep_486 - generated by tests/gen_opcode_sweep_486.py: two-byte 0F map, LOCK, FPU")
w("; escapes and invalid one-byte forms against the Intel486 (no CPUID) table.")
w("; RES[n] = vector+1 (0: no fault).  Mismatches go to port 0xE4 as")
w("; (n << 16) | (got << 8) | expected, then 0xFF to 0xE0.")
w("BITS 32\nORG 0\nCODE_BASE equ 0x10000\nRES equ 0x9000\nFEIP equ 0xA000\nCUR equ 0x6ff0\nSAVCR0 equ 0x6ff4\nSTK equ 0x8000")
w("align 8\ngdt:\n    dq 0\n    dq 0x00cf9b010000ffff\n    dq 0x00cf93000000ffff\ngdt_end:")
w("gdtr: dw gdt_end-gdt-1\n      dd CODE_BASE+gdt\nalign 8\nidt:")
for v in range(32):
    w("    dw stub%d, 8\n    db 0, 0x8e\n    dw 0" % v)
w("idt_end:\nidtr: dw idt_end-idt-1\n      dd CODE_BASE+idt")
for v in range(32):
    w("stub%d:" % v)
    if v not in (8,10,11,12,13,14,17):
        w("    push dword 0")
    w("    push dword %d\n    jmp vcommon" % v)
w("""vcommon:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov eax, [CUR]
    mov ecx, [esp]
    inc ecx
    mov [RES + eax], cl
    mov ecx, [esp + 8]
    mov [FEIP + eax*4], ecx
    mov esp, STK
    jmp [cont_tab + CODE_BASE + eax*4]
""")
w("times 0x800-($-$$) db 0x90\nstart:\n    cli\n    mov esp, STK\n    lgdt [cs:gdtr]\n    lidt [cs:idtr]")
w("    mov eax, cr0\n    mov [SAVCR0], eax")
w("    mov dword [0x%x], 0x7f00\n    mov word [0x%x], 0x10" % (FAR, FAR+4))
w("    mov edi, RES\n    mov ecx, %d\n    xor eax, eax\n    rep stosb" % len(entries))
for n, (name, b, exp, pro, info) in enumerate(entries):
    w("; %d: %s" % (n, name))
    w("    mov esp, STK\n    mov ax, 0x10\n    mov ds, ax\n    mov es, ax\n    mov fs, ax\n    mov gs, ax\n    mov ss, ax")
    w("    mov eax, [SAVCR0]\n    mov cr0, eax\n    mov dword [CUR], %d" % n)
    w("    xor eax, eax\n    mov dword [0x%x], 0\n    mov dword [0x%x], 0" % (SCR, SCR+4))
    for p in pro:
        w("    " + p)
    w("ins%d:\n    db %s" % (n, ", ".join("0x%02x" % x for x in b)))
    w("cont%d:" % n)
w("""    mov esp, STK
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov eax, [SAVCR0]
    mov cr0, eax
    xor ebp, ebp            ; mismatch count
    xor esi, esi
chk:
    movzx eax, byte [RES + esi]
    movzx ebx, byte [exp_tab + CODE_BASE + esi]
    test byte [info_tab + CODE_BASE + esi], 1
    jnz .info
    cmp eax, ebx
    je .next
    ; for a matching UD the FEIP check below
    inc ebp
.report:
    mov edx, esi
    shl edx, 16
    shl eax, 8
    or edx, eax
    or edx, ebx
    mov eax, edx
    out 0xe4, eax
    jmp .next
.info:
    cmp eax, ebx
    je .next
    mov edx, esi
    shl edx, 16
    shl eax, 8
    or edx, eax
    or edx, ebx
    or edx, 0x80000000      ; informational
    mov eax, edx
    out 0xe4, eax
.next:
    ; faults must name the instruction (traps: ICEBP excluded)
    movzx eax, byte [RES + esi]
    cmp eax, 0
    je .n2
    cmp eax, 2
    je .n2
    mov eax, [FEIP + esi*4]
    cmp eax, [ins_tab + CODE_BASE + esi*4]
    je .n2
    inc ebp
    mov eax, esi
    or eax, 0x40000000      ; wrong fault EIP
    out 0xe4, eax
.n2:
    inc esi
    cmp esi, %d
    jb chk
    test ebp, ebp
    jnz bad
    mov al, 1
    out 0xe0, al
    hlt
bad:
    mov eax, ebp
    or eax, 0x20000000
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt
align 4""" % len(entries))
w("cont_tab:\n" + "\n".join("    dd cont%d" % n for n in range(len(entries))))
w("ins_tab:\n" + "\n".join("    dd ins%d" % n for n in range(len(entries))))
w("exp_tab:\n" + "\n".join("    db %d" % (0 if e[2] is None else e[2]+1) for e in entries))
w("info_tab:\n" + "\n".join("    db %d" % (1 if e[4] else 0) for e in entries))
open(sys.argv[1], "w").write("\n".join(out) + "\n")
with open(sys.argv[2], "w") as f:
    for n, e in enumerate(entries):
        f.write("%d\t%s\t%s\n" % (n, e[0], "ok" if e[2] is None else e[2]))
print(len(entries), "entries")
