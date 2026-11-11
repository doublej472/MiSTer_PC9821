/* opnapro.s - the PC-9801-86 OPNA (YM2608) sound-register READ-BACK probe.
 *
 * WHY. The two NP2kai-vs-qemu disagreements the OPNA audit could not settle from
 * the references (ISSUES.md C-5, and the register defect it owns, B-1) are both
 * reads of the board's host ports:
 *
 *   (1) 0x18E read with the extended select at 0x0F. That address is the YM2608's
 *       A/D conversion register. qemu answers the constant 0x80 (2's-complement
 *       mid-scale, hw/audio/fmopn.c:3363); NP2kai answers the register shadow
 *       s.reg[0x10F] (sound/opna.c:630, 0x00 at reset). Our core answers the
 *       chip's ADPCM-B data bus (`{dout_b}` out of jt12_dout's 2'b11 arm), which
 *       matches neither. The two references disagree, so only the machine decides.
 *
 *   (2) status-2 (0x18C read) and its TIMER bits 1:0. qemu masks them with the
 *       flag mask programmed through extended register 0x110
 *       (`FM_STATUS_FLAG & (flagmask|0x80)`, fmopn.c:3353, where writing 0x110
 *       sets flagmask = ~(v & 0x1f)); NP2kai ORs s.status in unmasked
 *       (opna.c:379-397). Our core follows the NP2kai form. Again: the machine
 *       decides.
 *
 * It also measures the neighbouring 0x18A read-back the audit flagged (register
 * 0x08 is the ADPCM-B sample stream on the chip; registers below 0x10 are the
 * SSG/ADPCM shadow in both references), so the three read-backs sit in one
 * capture:
 *
 *   BASE08   0x18A read after 0x188 <- 0x08 and after 0x188 <- 0x0F.
 *   EXT0F    0x18E read after 0x18C <- 0x0F, with and without a marker written
 *            through 0x18E first, which separates a fixed byte (qemu's 0x80), a
 *            writable register shadow (NP2kai) and the chip's data bus.
 *   STATUS2  the 0x188/0x18C timer status read with the 0x110 flag mask written
 *            both ways.
 *
 * PORTS (pc9821_opna.sv's header, NP2kai cbus/board86.c and qemu fmopn.c agree):
 *
 *   0x188  read  the chip's status (BUSY:00000:FLAGB:FLAGA)
 *          write the base-bank register-select latch
 *   0x18A  read  the base-bank register shadow / joystick (reg 0x0E) / chip ID
 *                (reg 0xFF)
 *          write the selected register's data
 *   0x18C  read  the EXTENDED status (0xFF until 0xA460 bit 0 is set)
 *          write the extended-bank register-select latch
 *   0x18E  read  the extended register's data (0xFF until 0xA460 bit 0 is set)
 *          write the extended register's data
 *   0xA460 read  the board ID | the extension-enable bit 0 (0x40 | bit0)
 *          write bit 0 only (NP2kai pcm86_oa460: fmboard_extenable(val & 1))
 *
 * The extended bank is the only way to reach chip register 0x110, so the STATUS2
 * section writes 0x18C <- 0x10 then 0x18E <- the mask value.
 *
 * OUTPUT. A section per question, each bracketed BEGIN:<name> / END:<name>, so a
 * hang attributes to the section after the last complete one and the capture
 * before it stays valid:
 *
 *   SETUP     the five host ports as found, READ-ONLY
 *   CHIPID    the -86 chip ID and SSG register 7 (is the card even present?)
 *   EXT0F     the 0x18E/0x0F read-back question                    [(1) above]
 *   BASE08    the 0x18A read-back question
 *   STATUS2   the status-2 timer bits vs the 0x110 flag mask       [(2) above]
 *   STATUS3   (2026-11 kit, todo item 18 (c)) STATUS2 again with the Timer B flag HELD: the
 *             Xe10's STATUS2 control row read 48 (OPNA.TXT), so its masked row could not be told
 *             from a flag that had gone. Each row is read at once and again after 100 ms (the
 *             timer keeps running, ~37 ms a period, so a flag the mask only hides comes back
 *             in the unmasked rows, and a flag the mask clears is set again 100 ms later)
 *   RESTORE   what was written and what was put back
 *
 * The run ends with `OPNAPRO DONE`, which RUNOPNA.BAT greps for. Redirect it:
 *
 *     A> OPNAPRO > OPNA.TXT
 *
 * RUN IT FROM A FRESHLY BOOTED DOS PROMPT. The SETUP block is the as-found
 * (first-touch) state; anything that writes a register destroys it, and DOS gives
 * a redirected file its size only when the program ends, so an unredirected run
 * is the one that shows where a hang happened.
 *
 * SAFETY AND RESTORE.
 *   - Every write is a register select/data write the machine's own sound drivers
 *     make all day (master.lib, the games, the -86 BIOS), never a port no
 *     reference models. 0x188/0x18A/0x18C/0x18E and 0xA460 bit 0 are the whole set.
 *   - Read-first throughout: the SETUP block reads all five ports before anything
 *     is written. 0x18A and 0x18E are never written except for the one marker byte
 *     the EXT0F section needs to tell a writable shadow from a fixed answer, and
 *     that byte is put back to its reset default (0x00) before the section ends.
 *   - 0xA460 bit 0 is saved first-touch and replayed, and the replay is proved by
 *     re-reading the board ID. The extension enable is the only bit written; the
 *     `val & 1` mask is NP2kai's own.
 *   - The STATUS2 section programs OPNA Timer B and leaves it stopped and both
 *     flags cleared (0x27 <- 0x30), which is what egcport.com's Timer B
 *     calibration already leaves. The 8259 slave's IRQ12 line (slave IMR bit 4)
 *     is masked for the window and the as-found IMR is replayed afterwards, so a
 *     timer overflow cannot be delivered to a resident handler.
 *   - 0x188 and 0x18C are WRITE-ONLY in the sense that matters here: their read is
 *     the chip/extended STATUS, not the select latch, so the as-found select
 *     cannot be read back and replayed. The probe leaves the documented neutral
 *     select/data 0x00 the other hwprobe programs (egcport, ioprobe) leave, and
 *     the RESTORE block says so rather than pretending to restore it.
 *   - Nothing calls DOS inside a `cli` window; the sections buffer into variables
 *     and print after `sti`. No disk access at all (INT 21h AH=02/09/4C only).
 *
 * BUILD: the tree's tools/hwprobe/Makefile, one .COM linked at 0x100:
 *     make -C tools/hwprobe opnapro/opnapro.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ FW_OUTER, 4                    /* flag-wait bound: FW_OUTER * 65536 polls */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es

    mov     dx, offset msg_banner
    call    puts

    call    sec_setup
    call    sec_chipid
    call    sec_ext0f
    call    sec_base08
    call    sec_status2
    call    sec_status3
    call    sec_restore

    mov     dx, offset msg_done
    call    puts
    mov     ax, 0x4C00
    int     0x21
    hlt

/* ==================================================================
 * section: SETUP - the five host ports as found. READ-ONLY.
 * ================================================================== */
sec_setup:
    mov     dx, offset msg_begin_setup
    call    puts
    mov     dx, offset msg_setup_p1
    call    puts

    /* 0xA460 first: its bit 0 is the extension enable every extended read below
     * depends on, and its whole read-back is the board ID | bit 0. */
    mov     dx, 0xA460
    in      al, dx
    mov     [a460_found], al
    mov     dx, 0xA460
    mov     di, offset msg_setup_a460
    call    prd2

    mov     dx, 0x0188
    mov     di, offset msg_setup_188
    call    prd2

    mov     dx, 0x018A
    mov     di, offset msg_setup_18a
    call    prd2

    mov     dx, 0x018C
    mov     di, offset msg_setup_18c
    call    prd2

    mov     dx, 0x018E
    mov     di, offset msg_setup_18e
    call    prd2

    mov     dx, offset msg_setup_note
    call    puts
    mov     dx, offset msg_end_setup
    call    puts
    ret

/* ==================================================================
 * section: CHIPID - is the -86 card (and its YM2608) present at all?
 * ================================================================== */
sec_chipid:
    mov     dx, offset msg_begin_chipid
    call    puts
    mov     dx, offset msg_chipid_p1
    call    puts
    cli
    mov     al, 0xFF                    /* the -86 chip ID register selector */
    call    opna_sello
    mov     dx, 0x018A
    in      al, dx
    mov     [id_ff], al
    mov     al, 0x07                    /* SSG register 7: the reset mixer seed */
    call    opna_sello
    mov     dx, 0x018A
    in      al, dx
    mov     [id_07], al
    xor     al, al                      /* the neutral register-0 select */
    call    opna_sello
    sti

    mov     dx, offset msg_chipid_id
    call    puts
    mov     al, [id_ff]
    call    puthex8
    call    putnl
    mov     dx, offset msg_chipid_ssg7
    call    puts
    mov     al, [id_07]
    call    puthex8
    call    putnl
    mov     dx, offset msg_chipid_note
    call    puts
    mov     dx, offset msg_end_chipid
    call    puts
    ret

/* ==================================================================
 * section: EXT0F - 0x18E read with the extended select at 0x0F   [C-5/B-1 (1)]
 * ================================================================== */
sec_ext0f:
    mov     dx, offset msg_begin_ext0f
    call    puts
    mov     dx, offset msg_ext0f_p1
    call    puts
    cli
    mov     al, 1                       /* open the extended bank: 0xA460 bit 0 */
    call    opna_ext
    mov     dx, 0xA460
    in      al, dx
    mov     [a460_on], al

    mov     al, 0x0F                    /* 0x18C <- 0x0F: select extended register 0F */
    call    opna_selhi
    mov     dx, 0x018E
    in      al, dx
    mov     [e0f_v1], al
    mov     dx, 0x018E
    in      al, dx
    mov     [e0f_v2], al

    mov     al, 0x5A                    /* the marker: write extended register 0F */
    call    opna_exdata
    mov     al, 0x0F
    call    opna_selhi
    mov     dx, 0x018E
    in      al, dx
    mov     [e0f_v3], al
    mov     dx, 0x018E
    in      al, dx
    mov     [e0f_v4], al

    /* put the marker register back to its reset default, then the select latches */
    mov     al, 0x0F
    call    opna_selhi
    xor     al, al
    call    opna_exdata
    xor     al, al
    call    opna_selhi
    mov     al, [a460_found]            /* restore the extension bit */
    and     al, 1
    call    opna_ext
    sti

    mov     dx, offset msg_ext0f_on
    call    puts
    mov     al, [a460_on]
    call    puthex8
    call    putnl
    mov     dx, offset msg_ext0f_l1
    call    puts
    mov     al, [e0f_v1]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [e0f_v2]
    call    puthex8
    call    putnl
    mov     dx, offset msg_ext0f_l2
    call    puts
    mov     al, [e0f_v3]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [e0f_v4]
    call    puthex8
    call    putnl
    mov     dx, offset msg_ext0f_note
    call    puts
    mov     dx, offset msg_end_ext0f
    call    puts
    ret

/* ==================================================================
 * section: BASE08 - 0x18A read after 0x188 <- 0x08 and after 0x188 <- 0x0F
 * ================================================================== */
sec_base08:
    mov     dx, offset msg_begin_base08
    call    puts
    mov     dx, offset msg_base08_p1
    call    puts
    cli
    mov     al, 0x08                    /* register 08: the ADPCM-B sample stream */
    call    opna_sello
    mov     dx, 0x018A
    in      al, dx
    mov     [a08_08a], al
    mov     dx, 0x018A
    in      al, dx
    mov     [a08_08b], al

    mov     al, 0x0F                    /* register 0F: the ADPCM-B level register */
    call    opna_sello
    mov     dx, 0x018A
    in      al, dx
    mov     [a08_0fa], al
    mov     dx, 0x018A
    in      al, dx
    mov     [a08_0fb], al

    xor     al, al                      /* back to the neutral register-0 select */
    call    opna_sello
    sti

    mov     dx, offset msg_base08_08
    call    puts
    mov     al, [a08_08a]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [a08_08b]
    call    puthex8
    call    putnl
    mov     dx, offset msg_base08_0f
    call    puts
    mov     al, [a08_0fa]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [a08_0fb]
    call    puthex8
    call    putnl
    mov     dx, offset msg_base08_note
    call    puts
    mov     dx, offset msg_end_base08
    call    puts
    ret

/* ==================================================================
 * section: STATUS2 - the status-2 TIMER bits vs the 0x110 flag mask  [C-5 (2)]
 * ================================================================== */
sec_status2:
    mov     dx, offset msg_begin_status2
    call    puts
    mov     dx, offset msg_status2_p1
    call    puts
    cli
    /* Mask the slave 8259's IRQ12 (slave IMR bit 4) so a Timer B overflow cannot
     * be delivered to a resident handler inside the window. The as-found IMR is
     * replayed afterwards. */
    mov     dx, 0x000A
    in      al, dx
    mov     [imr_s_found], al
    or      al, 0x10
    out     dx, al

    mov     al, 1                       /* open the extended bank */
    call    opna_ext
    mov     dx, 0xA460
    in      al, dx
    mov     [a460_on], al

    /* flagmask = 0x00: qemu's "no bits masked" (flagmask = ~(v & 0x1f)) */
    mov     al, 0x10
    call    opna_selhi
    xor     al, al
    call    opna_exdata

    /* Timer B: period 0x26 <- 0x00 (256 counts ~ 74 ms at the 7.9872 MHz OPNA
     * clock), then 0x27 <- 0x2A: bit 1 run B, bit 3 its IRQ enable, bit 5 clear
     * its flag. The same sequence egcport.com calibrates against. */
    mov     al, 0x26
    call    opna_sello
    xor     al, al
    call    opna_lo_data
    mov     al, 0x27
    call    opna_sello
    mov     al, 0x2A
    call    opna_lo_data

    call    opna_flag_wait              /* bounded: [flag_seen] = 1 when bit 1 set */

    mov     dx, 0x0188
    in      al, dx
    mov     [s1_nomask], al
    mov     dx, 0x018C
    in      al, dx
    mov     [s2_nomask], al

    /* flagmask = 0x1F: qemu masks status-2's low five flag bits */
    mov     al, 0x10
    call    opna_selhi
    mov     al, 0x1F
    call    opna_exdata

    mov     dx, 0x0188
    in      al, dx
    mov     [s1_mask], al
    mov     dx, 0x018C
    in      al, dx
    mov     [s2_mask], al

    /* control: unmask again and read status-2 once more. The flag is still set
     * (nothing cleared it), so a mask answer that reverts here is the mask. */
    mov     al, 0x10
    call    opna_selhi
    xor     al, al
    call    opna_exdata
    mov     dx, 0x018C
    in      al, dx
    mov     [s2_again], al

    /* Stop both timers and clear both flags (0x27 <- 0x30), the same stop
     * egcport.com leaves the card in. */
    mov     al, 0x27
    call    opna_sello
    mov     al, 0x30
    call    opna_lo_data

    mov     dx, 0x000A                  /* replay the as-found slave IMR */
    mov     al, [imr_s_found]
    out     dx, al
    mov     al, [a460_found]            /* restore the extension bit */
    and     al, 1
    call    opna_ext
    sti

    mov     dx, offset msg_status2_seen
    call    puts
    cmp     byte ptr [flag_seen], 0
    je      st2_notseen
    mov     dl, 'Y'
    call    putc
    jmp     st2_seen_done
st2_notseen:
    mov     dl, 'N'
    call    putc
st2_seen_done:
    call    putnl

    mov     dx, offset msg_status2_nomask
    call    puts
    mov     al, [s1_nomask]
    call    puthex8
    mov     dx, offset msg_status2_18c
    call    puts
    mov     al, [s2_nomask]
    call    puthex8
    call    putnl

    mov     dx, offset msg_status2_mask
    call    puts
    mov     al, [s1_mask]
    call    puthex8
    mov     dx, offset msg_status2_18c
    call    puts
    mov     al, [s2_mask]
    call    puthex8
    call    putnl

    mov     dx, offset msg_status2_again
    call    puts
    mov     al, [s2_again]
    call    puthex8
    call    putnl

    mov     dx, offset msg_status2_note
    call    puts
    mov     dx, offset msg_end_status2
    call    puts
    ret

/* ==================================================================
 * section: STATUS3 - item 18 (c): the 0x110 mask with the Timer B flag held set
 * ================================================================== */
/* Rows (each `S3 <tag> 0188=xx 018C=xx`):
 *   A0   0x110 <- 00, Timer B (0x26 <- 00, 0x27 <- 2A) and the flag seen set: the unmasked read
 *   A1   100 ms later, nothing written: the flag holds (expected: as A0)
 *   B0   0x110 <- 1F, read at once          B1  100 ms later
 *   C0   0x110 <- 00 again, read at once    C1  100 ms later
 * qemu (fmopn.c:3353, a read-side mask): B0/B1 bits 1:0 clear, C0 = A0 again. A mask that
 * resets the flags: B0/B1 clear, C0 clear, C1 = A0 (the running timer sets it again). NP2kai
 * (opna.c:379-397, no mask): every row = A0. */
sec_status3:
    mov     dx, offset msg_begin_status3
    call    puts
    cli
    mov     dx, 0x000A
    in      al, dx
    mov     [imr_s_found], al
    or      al, 0x10
    out     dx, al
    mov     al, 1
    call    opna_ext
    mov     al, 0x10
    call    opna_selhi
    xor     al, al
    call    opna_exdata
    mov     al, 0x26
    call    opna_sello
    xor     al, al
    call    opna_lo_data
    mov     al, 0x27
    call    opna_sello
    mov     al, 0x2A
    call    opna_lo_data
    call    opna_flag_wait
    mov     al, [flag_seen]
    mov     [s3_seen], al
    mov     di, offset s3_val
    call    s3_read             /* A0 */
    call    s3_wait
    call    s3_read             /* A1 */
    mov     al, 0x10
    call    opna_selhi
    mov     al, 0x1F
    call    opna_exdata
    call    s3_read             /* B0 */
    call    s3_wait
    call    s3_read             /* B1 */
    mov     al, 0x10
    call    opna_selhi
    xor     al, al
    call    opna_exdata
    call    s3_read             /* C0 */
    call    s3_wait
    call    s3_read             /* C1 */
    mov     al, 0x27
    call    opna_sello
    mov     al, 0x30
    call    opna_lo_data
    mov     dx, 0x000A
    mov     al, [imr_s_found]
    out     dx, al
    mov     al, [a460_found]
    and     al, 1
    call    opna_ext
    sti
    mov     dx, offset msg_s3_seen
    call    puts
    mov     dl, 'N'
    cmp     byte ptr [s3_seen], 0
    je      1f
    mov     dl, 'Y'
1:  call    putc
    call    putnl
    mov     si, offset s3_val
    mov     bx, offset s3_tags
    mov     cx, 6
2:  mov     dx, offset msg_s3
    call    puts
    mov     dx, [bx]
    call    puts
    mov     dx, offset msg_s3_188
    call    puts
    mov     al, [si]
    call    puthex8
    mov     dx, offset msg_s3_18c
    call    puts
    mov     al, [si + 1]
    call    puthex8
    call    putnl
    add     si, 2
    add     bx, 2
    loop    2b
    mov     dx, offset msg_s3_note
    call    puts
    mov     dx, offset msg_end_status3
    call    puts
    ret

/* s3_read: [DI] = 0x188, [DI+1] = 0x18C (each after the BUSY bit drops, bounded); DI += 2 */
s3_read:
    call    io_delay
    mov     dx, 0x0188
    mov     cx, 0x4000
1:  in      al, dx
    test    al, 0x80
    jz      2f
    loop    1b
2:  mov     [di], al
    mov     dx, 0x018C
    in      al, dx
    mov     [di + 1], al
    add     di, 2
    ret
/* s3_wait: 100 ms of the ARTIC (30720 ticks at 307200 Hz) */
s3_wait:
    push    eax
    push    ebx
    call    s3_artic
    mov     ebx, eax
1:  call    s3_artic
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, 30720
    jb      1b
    pop     ebx
    pop     eax
    ret
s3_artic:                       /* EAX = the 24-bit ARTIC (0x5C word, 0x5F high), as ym29 */
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005F
    in      al, dx
    movzx   ebx, al
    mov     dx, 0x005C
    in      ax, dx
    movzx   ecx, ax
    mov     dx, 0x005F
    in      al, dx
    movzx   eax, al
    cmp     eax, ebx
    je      1f
    cmp     ecx, 0x8000
    jb      1f
    mov     eax, ebx
1:  shl     eax, 16
    or      eax, ecx
    pop     ecx
    pop     ebx
    pop     dx
    ret
s3_seen:    .byte 0
s3_val:     .space 12
    .balign 2
s3_tags:    .word t_a0, t_a1, t_b0, t_b1, t_c0, t_c1
t_a0:       .ascii "A0 0110<-00 flag set$"
t_a1:       .ascii "A1 +100ms$"
t_b0:       .ascii "B0 0110<-1F$"
t_b1:       .ascii "B1 +100ms$"
t_c0:       .ascii "C0 0110<-00$"
t_c1:       .ascii "C1 +100ms$"
msg_begin_status3:
    .ascii "BEGIN:STATUS3\r\nOPNA: the 0110 flag mask with the Timer B flag held set (item 18 c). Each row read at once and 100 ms later; Timer B keeps running (~37 ms a period).\r\n$"
msg_s3_seen: .ascii "  the Timer B flag was observed set: $"
msg_s3:     .ascii "  S3 $"
msg_s3_188: .ascii " 0188=$"
msg_s3_18c: .ascii " 018C=$"
msg_s3_note:
    .ascii "  qemu (a read-side mask): B rows bits 1:0 clear, C0 = A0. A mask that resets the flag: B and C0 clear, C1 = A0. NP2kai (no mask): every row = A0.\r\n$"
msg_end_status3:
    .ascii "END:STATUS3\r\n$"

/* ==================================================================
 * section: RESTORE - what was written and what was put back
 * ================================================================== */
sec_restore:
    mov     dx, offset msg_begin_restore
    call    puts
    mov     dx, offset msg_restore_p1
    call    puts

    /* Leave the base-bank host port in the documented neutral register-0/data-0
     * state (the same state egcport.com and ioprobe.com leave it in), then read
     * the board ID back to prove the extension bit is where it was found. */
    cli
    xor     al, al
    call    opna_sello
    xor     al, al
    call    opna_lo_data
    mov     al, [a460_found]
    and     al, 1
    call    opna_ext
    mov     dx, 0x000A
    in      al, dx
    mov     [imr_s_now], al
    mov     dx, 0xA460
    in      al, dx
    mov     [a460_now], al
    sti

    mov     dx, offset msg_restore_a460
    call    puts
    mov     al, [a460_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [a460_now]
    call    puthex8
    call    putnl

    mov     dx, offset msg_restore_ports
    call    puts
    mov     dx, offset msg_restore_cannot
    call    puts

    mov     dx, offset msg_restore_imr
    call    puts
    mov     al, [imr_s_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [imr_s_now]
    call    puthex8
    call    putnl

    mov     dx, offset msg_restore_note
    call    puts
    mov     dx, offset msg_end_restore
    call    puts
    ret

/* ==================================================================
 * the OPNA host port helpers
 * ================================================================== */
/* opna_ready: wait for the board's write queue to drain. The core folds its
 * WRQ_BUSY into 0x188 bit 7 (and 0x18C bit 7 when the extension is open), so a
 * guest's WAITREADY is `poll 0x188 bit 7`. Bounded: a chip that never clears it
 * costs the bound, not a hang. */
opna_ready:
    push    ax
    push    cx
    push    dx
    mov     cx, 0x2000
ordl:
    mov     dx, 0x0188
    in      al, dx
    test    al, 0x80
    jz      ordd
    loop    ordl
ordd:
    pop     dx
    pop     cx
    pop     ax
    ret

/* opna_sello: AL = the base-bank register-select byte (0x188 <- AL). */
opna_sello:
    push    ax
    push    dx
    mov     dx, 0x0188
    out     dx, al
    call    opna_ready
    call    io_delay
    pop     dx
    pop     ax
    ret

/* opna_lo_data: AL = the selected base-bank register's data (0x18A <- AL). */
opna_lo_data:
    push    ax
    push    dx
    mov     dx, 0x018A
    out     dx, al
    call    opna_ready
    call    io_delay
    pop     dx
    pop     ax
    ret

/* opna_selhi: AL = the extended-bank register-select byte (0x18C <- AL). The
 * card is only listening while 0xA460 bit 0 is set. */
opna_selhi:
    push    ax
    push    dx
    mov     dx, 0x018C
    out     dx, al
    call    opna_ready
    call    io_delay
    pop     dx
    pop     ax
    ret

/* opna_exdata: AL = the selected extended register's data (0x18E <- AL). */
opna_exdata:
    push    ax
    push    dx
    mov     dx, 0x018E
    out     dx, al
    call    opna_ready
    call    io_delay
    pop     dx
    pop     ax
    ret

/* opna_ext: AL bit 0 = the -86 extension enable (0xA460 <- AL & 1). NP2kai's
 * own mask (pcm86_oa460: fmboard_extenable(val & 1)); the read-back's bit 0
 * follows it, so the author and the observer use the same bit. */
opna_ext:
    push    ax
    push    dx
    and     al, 1
    mov     dx, 0xA460
    out     dx, al
    call    io_delay
    pop     dx
    pop     ax
    ret

/* opna_flag_wait: bounded poll of 0x188 bit 1 (the OPNA Timer B flag). Leaves
 * [flag_seen] = 1 when the flag was observed, 0 when the bound ran out. Reads do
 * not clear the flag (only 0x27 bit 5 does), so the status reads after this see
 * the same state. */
opna_flag_wait:
    push    ax
    push    cx
    push    dx
    mov     byte ptr [flag_seen], 0
    mov     word ptr [fw_outer], FW_OUTER
ofw_outer:
    mov     cx, 0
ofw_inner:
    mov     dx, 0x0188
    in      al, dx
    test    al, 0x02
    jnz     ofw_got
    loop    ofw_inner
    dec     word ptr [fw_outer]
    jnz     ofw_outer
    jmp     ofw_done
ofw_got:
    mov     byte ptr [flag_seen], 1
ofw_done:
    pop     dx
    pop     cx
    pop     ax
    ret

/* io_delay: reads of the I/O-wait port so a chipset latch settles before the
 * next access (the same helper probe2.s uses). Reading it is harmless and the
 * games write it for exactly this purpose. */
io_delay:
    push    ax
    push    cx
    push    dx
    mov     dx, 0x005F
    mov     cx, 8
idl:
    in      al, dx
    loop    idl
    pop     dx
    pop     cx
    pop     ax
    ret

/* ==================================================================
 * output helpers
 * ================================================================== */
putc:                               /* DL = character */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

puts:                               /* DX = '$'-terminated string */
    push    ax
    push    dx
    mov     ah, 0x09
    int     0x21
    pop     dx
    pop     ax
    ret

putnl:
    push    dx
    mov     dl, 0x0D
    call    putc
    mov     dl, 0x0A
    call    putc
    pop     dx
    ret

puthex8:                            /* AL */
    push    ax
    push    cx
    mov     cl, al
    shr     al, 4
    call    puthexdig
    mov     al, cl
    and     al, 0x0F
    call    puthexdig
    pop     cx
    pop     ax
    ret

puthexdig:                          /* AL = 0..15 -> one ASCII hex digit */
    push    ax
    push    dx
    and     al, 0x0F
    cmp     al, 10
    jb      phd_lo
    add     al, 'A' - 10
    jmp     phd_out
phd_lo:
    add     al, '0'
phd_out:
    mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret

/* prd2: DX = port, DI = '$'-terminated label. Reads the port twice and prints
 * "<label> V1 V2" + CRLF. The port is kept in memory across the DOS call, so
 * nothing depends on which registers INT 21h/09 happens to preserve. */
prd2:
    push    ax
    push    dx
    mov     [prd_port], dx
    mov     dx, di
    call    puts
    mov     dx, [prd_port]
    in      al, dx
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     dx, [prd_port]
    in      al, dx
    call    puthex8
    call    putnl
    pop     dx
    pop     ax
    ret

/* ==================================================================
 * data
 * ================================================================== */
a460_found: .byte 0
a460_on:    .byte 0
a460_now:   .byte 0
id_ff:      .byte 0
id_07:      .byte 0
e0f_v1:     .byte 0
e0f_v2:     .byte 0
e0f_v3:     .byte 0
e0f_v4:     .byte 0
a08_08a:    .byte 0
a08_08b:    .byte 0
a08_0fa:    .byte 0
a08_0fb:    .byte 0
s1_nomask:  .byte 0
s2_nomask:  .byte 0
s1_mask:    .byte 0
s2_mask:    .byte 0
s2_again:   .byte 0
flag_seen:  .byte 0
fw_outer:   .word 0
imr_s_found: .byte 0
imr_s_now:  .byte 0
prd_port:   .word 0

msg_banner:
    .ascii "OPNAPRO: PC-9801-86 OPNA sound-register read-back probe (PC-9821)\r\nRun from a FRESHLY BOOTED DOS prompt: SETUP is the as-found, first-touch state.\r\nRedirect it: OPNAPRO > OPNA.TXT\r\n$"
msg_done:
    .ascii "OPNAPRO DONE\r\n$"

msg_begin_setup:
    .ascii "BEGIN:SETUP\r\n$"
msg_setup_p1:
    .ascii "OPNA: the -86's four host ports and the board ID, as found. READ-ONLY: nothing is written in this section, so these are the fresh-boot (first-touch) values. Each is read twice, so a port that consumes state on read shows V1 != V2.\r\n$"
msg_setup_a460:
    .ascii "  0xA460 (board ID | extension enable bit 0): $"
msg_setup_188:
    .ascii "  0x188 (write: base-bank select latch / read: the chip STATUS BUSY xxxxx FLAGB FLAGA): $"
msg_setup_18a:
    .ascii "  0x18A (write: the selected register's data / read: shadow, joystick reg 0E, chip ID reg FF; sel_lo = as found): $"
msg_setup_18c:
    .ascii "  0x18C (write: extended select latch / read: EXTENDED status; 0xFF until 0xA460 bit 0 is set): $"
msg_setup_18e:
    .ascii "  0x18E (write: extended data / read: the extended register; 0xFF until 0xA460 bit 0 is set): $"
msg_setup_note:
    .ascii "  0x188/0x18C read the chip's STATUS, not the select latch, so the as-found select cannot be read back - the sections below report what they restore.\r\n$"
msg_end_setup:
    .ascii "END:SETUP\r\n$"

msg_begin_chipid:
    .ascii "BEGIN:CHIPID\r\n$"
msg_chipid_p1:
    .ascii "OPNA: is the card present at all? 0x18A with 0x188 = FF answers the -86 chip ID, and with 0x188 = 07 answers SSG register 7. If the card were absent both would read FF and every read-back below would be open bus.\r\n$"
msg_chipid_id:
    .ascii "  0x18A with 0x188=FF (the -86 card's chip ID; a -86 answers 01): $"
msg_chipid_ssg7:
    .ascii "  0x18A with 0x188=07 (SSG register 7; the references' reset seed is BF): $"
msg_chipid_note:
    .ascii "  a 00 or FF here, or FF for both, means the card (or its chip-ID read) did not answer: treat the sections below as open bus.\r\n$"
msg_end_chipid:
    .ascii "END:CHIPID\r\n$"

msg_begin_ext0f:
    .ascii "BEGIN:EXT0F\r\n$"
msg_ext0f_p1:
    .ascii "OPNA: the 0x18E read with the extended select at 0x0F (the YM2608 A/D conversion register). The two references disagree: qemu answers the constant 0x80 (2's-complement mid-scale), NP2kai answers the register shadow s.reg[10F] (00 at reset), and our core answers the chip's ADPCM-B data bus, which matches neither. Enabling 0xA460 bit 0 first (every write here is saved and restored).\r\n$"
msg_ext0f_on:
    .ascii "  0xA460 after writing bit 0 = 1 (bit 0 set = the extended bank is open): $"
msg_ext0f_l1:
    .ascii "  0x18E with 0x18C=0F, as reset (V1 V2): $"
msg_ext0f_l2:
    .ascii "  0x18E with 0x18C=0F after writing a marker 5A through 0x18E (V1 V2): $"
msg_ext0f_note:
    .ascii "  read L1 and L2 together: L1 = 80 is qemu's constant; L1 = 00 and L2 = 5A is a WRITABLE register shadow (NP2kai's form); L2 != 5A with L1 = 00 is a fixed/other answer (the chip's data bus, or open bus when both are FF).\r\n$"
msg_end_ext0f:
    .ascii "END:EXT0F\r\n$"

msg_begin_base08:
    .ascii "BEGIN:BASE08\r\n$"
msg_base08_p1:
    .ascii "OPNA: the 0x18A read after selecting register 08 (the ADPCM-B sample stream on the chip) and register 0F (the ADPCM-B level register). NP2kai answers the register shadow s.reg[08]/s.reg[0F]; a board that forwards the chip answers the ADPCM-B data bus. Nothing is written to 0x18A here. Two reads each, so a consume-on-read (a FIFO/sample stream) shows V1 != V2.\r\n$"
msg_base08_08:
    .ascii "  0x18A with 0x188=08 (V1 V2): $"
msg_base08_0f:
    .ascii "  0x18A with 0x188=0F (V1 V2): $"
msg_base08_note:
    .ascii "  a stable shadow answer is 00 (NP2kai's reset s.reg[08]/s.reg[0F]); 0F answering FF is the SSG register-15/ADPCM-B-level shadow seed the core carries; V1 != V2 means the read advanced a data bus, not a shadow.\r\n$"
msg_end_base08:
    .ascii "END:BASE08\r\n$"

msg_begin_status2:
    .ascii "BEGIN:STATUS2\r\n$"
msg_status2_p1:
    .ascii "OPNA: status-2's TIMER bits against the 0x110 flag mask. qemu masks status-2's low five flag bits with the mask programmed through extended register 0110 (flagmask = ~(v & 1F)); NP2kai ORs its status in unmasked; our core follows NP2kai. Timer B is programmed to set its flag, IRQ12 is masked for the window, and both timers are stopped and both flags cleared at the end.\r\n$"
msg_status2_18c:
    .ascii " 018C= $"
msg_status2_seen:
    .ascii "  the Timer B flag (0x188 bit 1) was observed set: $"
msg_status2_nomask:
    .ascii "  0110 <- 00 (qemu: no bits masked): 0188= $"
msg_status2_mask:
    .ascii "  0110 <- 1F (qemu: status-2's flag bits masked): 0188= $"
msg_status2_again:
    .ascii "  0110 <- 00 again, flag still set (control): 018C= $"
msg_status2_note:
    .ascii "  the discriminator is the pair of 018C bytes: a lower value (bits 1:0 clear) in the masked row that comes back in the control row is the qemu mask; identical 018C bytes in both rows is the NP2kai unmasked form (or a machine that does not implement the 0110 mask at all - either way the core's unmasked form is the one that matches). 0188 is unmasked in both references, so it should not move.\r\n$"
msg_end_status2:
    .ascii "END:STATUS2\r\n$"

msg_begin_restore:
    .ascii "BEGIN:RESTORE\r\n$"
msg_restore_p1:
    .ascii "RESTORE: what the probe wrote, and what it put back.\r\n$"
msg_restore_a460:
    .ascii "  0xA460 (extension enable bit 0) was ... replayed, now (was -> now): $"
msg_restore_ports:
    .ascii "  0x188/0x18A/0x18C/0x18E left at the neutral select 00 / data 00 state egcport.com and ioprobe.com leave them in. These four are WRITE-ONLY for this purpose: a 0x188/0x18C read answers the chip/extended STATUS, not the latch, so the as-found select cannot be replayed. The SETUP block printed it as found.\r\n$"
msg_restore_cannot:
    .ascii "  the two registers written in the extended bank (0F, the ADPCM-B level, and 0110, the flag mask) were put back to their reset defaults 00; neither is readable on this board, so neither restore is provable from the machine. The OPNA timers are stopped and both flags cleared (0x27 <- 30), the same stop egcport.com leaves.\r\n$"
msg_restore_imr:
    .ascii "  8259 slave IMR (bit 4 = IRQ12, masked for the STATUS2 window) was ... now: $"
msg_restore_note:
    .ascii "  no DOS call was made between a cli and its sti in any section; the disk was never touched.\r\n$"
msg_end_restore:
    .ascii "END:RESTORE\r\n$"
