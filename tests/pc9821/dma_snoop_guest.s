# The DMA-snoop throttle tier's guest (tests/pc9821/tb_pc9821_dma_snoop_throttle.sv).
# GNU as, 16-bit real mode, assembled into the 32 KiB ITF bank by
# firmware/diagnostic/build.py --itf-src.
#
# It reproduces the held-snoop counterexample end to end: the CPU caches one dword of a
# floppy buffer, a single uPD71071 byte (a count-0 channel-3 transfer) is DMA'd into the
# SAME line by the real FDC, and the CPU re-reads it. With the per-write snoop held for
# the gated CPU clock the read is the byte the FDC wrote; with the pulse dropped in a
# cpu_ce=0 cycle it is the stale cached dword. The bench forces the cpu_ce phase so the
# accept lands in a disabled cycle (the one-byte transfer makes that a single snoop).
#
# It then reproduces the back-pressure counterexample: a TWO-byte software-request transfer
# on channel 0 (port-to-memory, no device, so the uPD71071 engine moves both bytes at bus
# rate - ~8-10 clk_sys each) walks BACKWARDS from 0x2020, so its two bytes land in two
# DIFFERENT 32-byte lines (0x2020 and 0x201F, sets 1 and 0 of the 16-set D$). At the 1 MHz
# setting the disabled run is 49 clk_sys, so both accepts fall inside one run. With a
# one-deep snoop hold the second accept replaces the first address and only the second
# line is invalidated; the bench requires BOTH cached lines to be coherent afterwards.
#
# POST codes on port 0x0EE0 (the bench keys on them):
#   B0 the buffer line is cached (0xA5A51234 written then read back)
#   B1 the DMAC is armed and the FDC READ DATA command is out - the bench's cue to hold
#      cpu_ce=0 and release the media
#   B2 the DMA terminal count was seen
#   5A the re-read saw the FDC's byte (0xA5A51201) - phase 1 PASS
#   E7 the re-read saw the stale cached dword (0xA5A51234) - the F1 under-invalidation
#   E9 the DMA never reached terminal count (phase 1)
#   B3 the two phase-2 lines are cached (0x201C = 0xA5A5BEEF, 0x2020 = 0xA5A55678)
#   B4 the two-byte channel-0 transfer reached terminal count
#   5B both phase-2 lines are coherent (0x2020 = 0xA5A556FF, 0x201C = 0xFFA5BEEF) - PASS
#   EB the 0x2020 line is stale (the FIRST write's invalidate was lost) - the G1 defect
#   EC the 0x201C line is stale (the second write's invalidate was lost)
#   E8 the two-byte transfer never reached terminal count (phase 2)

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

    # Cache one line of the buffer: store a distinctive dword, then read it back so the
    # D$ really holds the line (the store itself does not allocate).
    mov dword ptr [0x2000], 0xa5a51234
    mov eax, dword ptr [0x2000]
    mov al, 0xb0
    mov dx, 0x0ee0
    out dx, al

    # 2DD window (strap bit 0 = 0): IRQ10, DMA channel 3.
    mov dx, 0x00be
    mov al, 0x02
    out dx, al

    # uPD71071 channel 3 -> physical 0x002000, count 0 (ONE byte), port->memory.
    mov dx, 0x001b
    xor al, al
    out dx, al                      # master clear
    mov dx, 0x0019
    xor al, al
    out dx, al                      # clear byte-pointer flip-flop
    mov dx, 0x000d
    xor al, al
    out dx, al                      # address low = 0x00
    mov dx, 0x000d
    mov al, 0x20
    out dx, al                      # address high = 0x20
    mov dx, 0x0025
    xor al, al
    out dx, al                      # bank = 0x00
    mov dx, 0x000f
    xor al, al
    out dx, al                      # count low = 0
    mov dx, 0x000f
    xor al, al
    out dx, al                      # count high = 0
    mov dx, 0x0017
    mov al, 0x07                    # din[3:2]=01 port->memory, channel 3
    out dx, al
    mov dx, 0x0015
    mov al, 0x03                    # unmask channel 3 (bits 2/3 clear)
    out dx, al

    # FDC READ DATA (2DD): command, unit/head 0, C 0, H 0, R 1, N 0, EOT 1, GPL 0, DTL 0.
    mov dx, 0x00ca
    mov al, 0x06
    out dx, al
    xor al, al
    out dx, al                      # unit/head
    out dx, al                      # C
    out dx, al                      # H
    mov al, 0x01
    out dx, al                      # R
    xor al, al
    out dx, al                      # N
    mov al, 0x01
    out dx, al                      # EOT
    xor al, al
    out dx, al                      # GPL
    out dx, al                      # DTL

    # The bench holds cpu_ce=0 and releases the media on this marker, so the accept is
    # guaranteed to be in a disabled cycle.
    mov al, 0xb1
    mov dx, 0x0ee0
    out dx, al

    # Poll the DMAC status: bit 3 is channel 3's terminal count.
    mov cx, 0
poll:
    mov dx, 0x0011
    in al, dx
    test al, 0x08
    jnz done
    inc cx
    jnz poll
    mov al, 0xe9
    mov dx, 0x0ee0
    out dx, al
    hlt

done:
    mov al, 0xb2
    mov dx, 0x0ee0
    out dx, al
    # The FDC's first byte is R ^ 0 = 1; it overwrote only byte 0 of the cached dword.
    mov eax, dword ptr [0x2000]
    cmp eax, 0xa5a51201
    jne stale
    mov al, 0x5a
    mov dx, 0x0ee0
    out dx, al

    # ---- PHASE 2: TWO accepted DMA writes inside one disabled run ----
    # Cache both target lines. 0x201C is in the 0x2000 line (D$ set 0), 0x2020 is the
    # next line (set 1). The transfer below is programmed to walk DOWN from 0x2020, so
    # its two bytes land in 0x2020 (first) and 0x201F (second), one per line.
    mov dword ptr [0x201c], 0xa5a5beef
    mov eax, dword ptr [0x201c]
    mov dword ptr [0x2020], 0xa5a55678
    mov eax, dword ptr [0x2020]
    mov al, 0xb3
    mov dx, 0x0ee0
    out dx, al

    # uPD71071 channel 0 (ports 0x01/0x03, bank 0x27), address 0x00201F... the engine
    # writes the CURRENT address first and then decrements, so programming 0x2020 with
    # count 1 (TWO bytes) writes 0x2020 then 0x201F.
    mov dx, 0x001b
    xor al, al
    out dx, al                      # master clear (masks all channels, zeroes addr/count)
    mov dx, 0x0019
    xor al, al
    out dx, al                      # clear byte-pointer flip-flop
    mov dx, 0x0001
    mov al, 0x20
    out dx, al                      # address low = 0x20
    mov al, 0x20
    out dx, al                      # address high = 0x20
    mov dx, 0x0027
    xor al, al
    out dx, al                      # channel-0 bank = 0x00
    mov dx, 0x0003
    mov al, 0x01
    out dx, al                      # count low = 1  (two bytes: 1 then 0)
    xor al, al
    out dx, al                      # count high = 0
    mov dx, 0x0017
    mov al, 0x24                    # din[3:2]=01 port->memory, channel 0, bit5 = decrement
    out dx, al
    mov dx, 0x0015
    xor al, al
    out dx, al                      # unmask channel 0
    mov dx, 0x0013
    mov al, 0x04                    # software request, channel 0 (no device: the engine
    out dx, al                      # moves both bytes at bus rate)

    # Poll the DMAC status: bit 0 is channel 0's terminal count.
    mov cx, 0
poll0:
    mov dx, 0x0011
    in al, dx
    test al, 0x01
    jnz done0
    inc cx
    jnz poll0
    mov al, 0xe8
    mov dx, 0x0ee0
    out dx, al
    hlt

done0:
    mov al, 0xb4
    mov dx, 0x0ee0
    out dx, al
    # Let any snoop still held for the CPU's next enabled edge be taken before the reads.
    mov cx, 16
delay0:
    loop delay0
    # The DMA byte at 0x2020 is 0xFF (the FDC presents 0xFF when it is not transferring):
    # it replaces the LOW byte of the cached 0xA5A55678. The byte at 0x201F is lane 3 of
    # the dword at 0x201C (0xA5A5BEEF -> 0xFFA5BEEF).
    mov eax, dword ptr [0x2020]
    cmp eax, 0xa5a556ff
    jne bad_first
    mov eax, dword ptr [0x201c]
    cmp eax, 0xffa5beef
    jne bad_second
    mov al, 0x5b
    mov dx, 0x0ee0
    out dx, al
    hlt

bad_first:
    mov al, 0xeb
    mov dx, 0x0ee0
    out dx, al
    hlt

bad_second:
    mov al, 0xec
    mov dx, 0x0ee0
    out dx, al
    hlt

stale:
    mov al, 0xe7
    mov dx, 0x0ee0
    out dx, al
    hlt

# x86 reset starts at FFFFFFF0, mapped to ITF offset 7FF0.
.org 0x7ff0
    ljmp 0xf800, start

.org 0x8000
