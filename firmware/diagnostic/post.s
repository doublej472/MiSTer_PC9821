# Redistributable PC-9821 z486 bring-up ROM.
# GNU as, 16-bit real mode. The image occupies the 32 KiB ITF bank and emits
# deterministic POST values on port 0EE0 before writing a TRAM banner.

.intel_syntax noprefix
.code16

.org 0
start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7f00

    # ---------------------------------------------------------------
    # The CPU's own SHUTDOWN (triple fault) must reset the CPU LOCALLY.
    #
    # z486 asserts its triple_fault_reset when a fault arrives while #DF is
    # being delivered -- the CPU's reset pin. On the machine that is the same
    # CPU-reset class as `out 0xF0` below, and it must never depend on the
    # framework: a measurement found the request leaving the FPGA as
    # BUTTONS[1] (the I/O board's USER BUTTON), and user_io.cpp masks that echo
    # while the OSD is visible, which is the OSD-open stall observed on hardware.
    #
    # The fault is the one the z486 suite's sreg_absent_gdt_load proves, in the
    # form a real-mode pack can reach: enter protected mode with an all-zero GDT
    # and IDT in RAM, then load ES with selector 0x30 -- an all-zero (absent)
    # descriptor. The segment load faults (#GP), the #GP gate is itself unusable,
    # so delivery escalates #GP -> #DF -> shutdown. If the platform consumes the
    # shutdown, the CPU re-enters at the reset vector and reaches the POST; if it
    # does not, the bench times out, which is the regression this phase exists for.
    cmp byte ptr [0x0412], 0x5a
    je  tf_once_done
    mov byte ptr [0x0412], 0x5a
    cli
    xor ax, ax
    mov ds, ax
    # The GDT and IDT are INITIALIZED HERE, not borrowed from whatever low RAM holds:
    # real SDRAM powers up RANDOM, so a random present descriptor at 0x830 (selector
    # 0x30's entry) or a random PRESENT gate at 0x1040/0x1058/0x1068 (vectors
    # 0x08/0x0B/0x0D) would divert the fault and the shutdown would never happen - the
    # bench's zero-filling sdram_backend_model was the only thing hiding this. Zero the
    # two regions the descriptors below name (the GDT's 7 entries, the IDT's 256 gates),
    # so the stage is deterministic on hardware and in any simulator.
    mov es, ax
    mov di, 0x0800           # GDT: 0x38 bytes at 0x00000800
    mov cx, 0x001c
    rep stosw
    mov di, 0x1000           # IDT: 0x800 bytes at 0x00001000
    mov cx, 0x0400
    rep stosw
    # GDTR operand at 0x07F0: limit 0x37 (7 entries), base 0x00000800. The GDT is
    # the explicitly zeroed region above, so selector 0x30 is an absent descriptor.
    mov word  ptr [0x07F0], 0x0037
    mov dword ptr [0x07F2], 0x00000800
    lgdt [0x07F0]
    # IDTR operand at 0x07F8: limit 0x07FF, base 0x00001000. The gates are the
    # explicitly zeroed region above, so no exception can be delivered.
    mov word  ptr [0x07F8], 0x07FF
    mov dword ptr [0x07FA], 0x00001000
    lidt [0x07F8]
    mov eax, cr0
    or  al, 1
    mov cr0, eax
    mov ax, 0x30
    mov es, ax                  # absent descriptor: #GP -> #DF -> shutdown
    mov al, 0xe6                # reached only if the shutdown did not take
    mov dx, 0x0ee0
    out dx, al
    cli
    hlt
tf_once_done:

    mov al, 0x10
    mov dx, 0x0ee0          # out takes only an 8-bit immediate port
    out dx, al

    # ---------------------------------------------------------------
    # A20 and the `out 0xF0` CPU-mode reset.
    #
    # Two platform contracts, both observed from the CPU side:
    #
    # 1. A20 masked is a 1 MiB WRAP on the PC-98, not a PC/AT bit-20 clear.
    #    The authentic ITF checks it at BANK4@0xF8358 (`cs mov word [0x8000],
    #    0x55AA` then compare `[0]`), which reaches exactly 1 MiB -- the one
    #    address where the two models agree -- so that is the CONTROL here.
    #    The DISCRIMINATOR cannot be a real-mode data access: in real mode
    #    `seg<<4 + offset` tops out at 0x10FFEF, and over that whole range the
    #    wrap and a bit-20 clear land on the same low byte. A 32-bit offset
    #    such as `[0x00200000]` is also out of the 0xFFFF segment limit, so the
    #    core faults it before A20 is consulted -- it can never be a control.
    #    The legal access above 1 MiB whose result differs is the reset-vector
    #    code fetch, linear 0xFFFFFFF0 with CS=F000: the wrap sends it to
    #    0x000FFFF0, the mapped bank's own vector, while a bit-20 clear sends
    #    it to 0xFFEFFFF0, open bus. That is contract 2 below, and it is the
    #    fixture the bench asserts.
    #
    #    The gate's POWER-ON state is masked (NP2kai i386c/ia32/interface.c:87
    #    resets CPU_ADRSMASK = 0x000fffff, QEMU target/i386/cpu.c:9421 resets
    #    a20_mask = 0xfffff under the pc98-a20-mask property), and that is the
    #    state the ITF's own check needs: no 0xF2/0xF6 write precedes it. The
    #    system PPI's port-C bit 4 is NOT a second control, so the two BSR
    #    directions below are exercised and both must leave the 1 MiB write
    #    wrapping. The ITF itself pulses the same bit with 0x09/0x08
    #    (BANK4@0xF8F19/0xF908D) inside its second protected-mode block, which
    #    has just RELEASED the gate with `out 0xF2,0` / `out 0xF6,2`
    #    (BANK4@0xF8952/0xF8956); a gate that followed the PPI there folds that
    #    block's 128 KiB zero-fill onto the GDT image at 0x8000 and the IDT at
    #    0x9000 it installed.
    # 2. `out 0xF0,<n>` is the CPU-mode request the ITF uses to restart POST
    #    (BANK4@0xFA67D: `mov al,0; out 0xF0,al; hlt`). Its FIRST fetch must be
    #    the reset vector of the window mapped at that moment: 0xFFFFFFF0 with
    #    A20 masked is 0x000FFFF0 under the wrap (this pack's window offset
    #    0x7FF0, which is `ljmp 0xF800,start`) and 0xFFEFFFF0 -- open bus, no
    #    firmware -- under a bit-20 clear. The reset is CPU-only: RAM, the ROM
    #    window and the latches survive, which is what the machine's own
    #    routine relies on (BANK7@0xFD867 saves MSW and ss:sp, requests the
    #    reset and resumes at CS:0x74).
    #
    # [0x0410] is the flag that tells the second pass the reset landed, so the
    # whole stage runs on the first pass only. Each failure writes a POST code
    # and parks, so the bench names the contract that broke.
    cmp byte ptr [0x0410], 0x5a
    je  post_reset_returned

    mov al, 0x08                # port C BSR: index 4, bit 0 = 0
    out 0x37, al
    mov word ptr cs:[0x8000], 0x55aa   # physical 1 MiB: the ITF's own check
    xor ax, ax
    mov ds, ax
    cmp word ptr [0x0000], 0x55aa
    jne fail_a20_line
    mov word ptr [0x0000], 0

    mov al, 0x09                # port C BSR: index 4, bit 0 = 1 -- the gate
    out 0x37, al                # must not follow this direction either
    mov word ptr cs:[0x8000], 0x55aa
    cmp word ptr [0x0000], 0x55aa
    jne fail_a20_line
    mov word ptr [0x0000], 0
    mov al, 0x5e
    mov dx, 0x0ee0
    out dx, al

    # Request CPU mode 0 and let the platform reset the CPU onto the vector.
    # The reset-vector fetch (linear 0xFFFFFFF0, A20-masked) is the wrap's own
    # discriminator: it lands at 0x000FFFF0 and reaches `ljmp 0xF800,start`
    # below, so POST 0x70 can only appear if the wrap is in place.
    mov byte ptr [0x0410], 0x5a
    xor al, al
    out 0xf0, al
    hlt                         # reached only if the reset does not take

post_reset_returned:
    mov al, 0x70                # the reset re-entered through the vector
    mov dx, 0x0ee0
    out dx, al
    # The ITF's own gate continues while 0x9894 bit 3 is CLEAR
    # (BANK4@0xFCAED: `in al,0x9894; test al,0x8; je`), so the reset must leave
    # the mode report in the state that request expects: mode 0.
    mov dx, 0x9894
    in  al, dx
    test al, 0x08
    jnz fail_mode_bit
    mov al, 0x71
    mov dx, 0x0ee0
    out dx, al
    # Release A20 with the machine's own control for the rest of the POST. The
    # PPI bytes above do not move the gate, and no later stage here needs it
    # released; this keeps the payload's behaviour true on the hardware, where
    # 0xF6 is the gate's control.
    mov al, 0x02
    out 0xf6, al
    mov byte ptr [0x0410], 0
    xor ax, ax
    mov ds, ax

    # Basic low-RAM data-path check.
    mov dword ptr [0x0400], 0x5a3c0bad
    cmp dword ptr [0x0400], 0x5a3c0bad
    jne fail_ram
    mov al, 0x20
    mov dx, 0x0ee0          # out takes only an 8-bit immediate port
    out dx, al

    # Start the text GDC. Power-on MODE FF1 already has display enabled.
    mov al, 0x0d
    out 0x62, al

    mov ax, 0xa000
    mov es, ax
    xor di, di
    mov si, offset banner
banner_loop:
    cs lodsb
    test al, al
    jz banner_done
    mov byte ptr es:[di], al
    mov byte ptr es:[di+1], 0
    mov byte ptr es:[di+0x2000], 0xe1
    add di, 2
    jmp banner_loop
banner_done:
    mov al, 0x30
    mov dx, 0x0ee0          # out takes only an 8-bit immediate port
    out dx, al
    mov al, 0x5a
    mov dx, 0x0ee0          # out takes only an 8-bit immediate port
    out dx, al

    # ---------------------------------------------------------------
    # Interrupt-path self-test, using the sequence the Touhou games use
    # (ReC98 th01/hardware/vsync.cpp): program the master 8259, unmask IRQ2,
    # install a handler on the vector the PC-98 maps it to (INT 0Ah), arm the
    # display VSYNC by writing port 64h, wait for the handler, then acknowledge
    # with a non-specific EOI to port 00h and re-arm.
    #
    # This is the only test that exercises the whole chain -- device, PIC, INTA
    # bridge and CPU. A mask write that never reaches the PIC (the ICW
    # sequencing bug) leaves the counter at zero, and a PIC that never sees INTA
    # leaves it at zero too, so both failure modes are caught here rather than
    # on screen.
    # ---------------------------------------------------------------
    xor ax, ax
    mov es, ax
    mov word ptr es:[0x28], offset int_vsync   # vector 0x0A, offset
    mov word ptr es:[0x2a], cs                 # vector 0x0A, segment

    mov al, 0x11                # ICW1: cascade, edge, ICW4 follows
    out 0x00, al
    mov al, 0x08                # ICW2: master base vector
    out 0x02, al
    mov al, 0x80                # ICW3: slave on IR7
    out 0x02, al
    mov al, 0x1d                # ICW4
    out 0x02, al
    mov al, 0xfb                # IMR: unmask IRQ2 (VSYNC) only
    out 0x02, al

    mov byte ptr [0x0500], 0
    sti
    out 0x64, al                # any write to 64h arms the VSYNC interrupt

    mov bx, 8                   # outer timeout: 8 x 65535 iterations
wait_outer:
    mov cx, 0xffff
wait_vsync:
    cmp byte ptr [0x0500], 0
    jne got_vsync
    loop wait_vsync
    dec bx
    jnz wait_outer
    jmp fail_irq
got_vsync:
    cli
    mov al, 0x60
    mov dx, 0x0ee0
    out dx, al
    jmp idle

int_vsync:
    push ax
    inc byte ptr [0x0500]
    mov al, 0x20                # non-specific EOI to the master
    out 0x00, al
    out 0x64, al                # and re-arm, exactly as the games do
    pop ax
    iret

fail_irq:
    mov al, 0xe2
    mov dx, 0x0ee0
    out dx, al
    jmp idle

idle:
    jmp idle

fail_ram:
    mov al, 0xe1
    mov dx, 0x0ee0          # out takes only an 8-bit immediate port
    out dx, al
    jmp idle

fail_a20_line:
    mov al, 0xe3
    mov dx, 0x0ee0
    out dx, al
    jmp idle

fail_mode_bit:
    mov al, 0xe5
    mov dx, 0x0ee0
    out dx, al
    jmp idle

banner:
    .ascii "Z486 PC-9821 NATIVE POST OK"
    .byte 0

# x86 reset starts at FFFFFFF0, mapped to ITF offset 7FF0.
.org 0x7ff0
    ljmp 0xf800, start

.org 0x8000
