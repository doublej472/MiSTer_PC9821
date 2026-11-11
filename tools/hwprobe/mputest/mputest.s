/* mputest.s - MPUTEST, the MIDI-interface probe: a Roland MPU-401-family C-bus card
 * (MPU-PC98, MPU-PC98II) on a PC-9821, and the core's model of the MPU-PC98II.
 *
 * WHAT IT DOES. Finds the card, measures what a driver sees (the reset ACK and its latency,
 * the IRQ line the card raises, the BUSY/DRR bit while a UART-mode stream is written at full
 * rate), plays labelled MIDI sequences a listener can follow on a GS synth (SC-88 Pro), and
 * has a fixed byte table mode (/BYTES) for a byte-exact comparison of the MIDI OUT line
 * against the reference stream. RUN IT ON THE CORE FIRST, then on the real machine (the
 * tools/hwprobe rule: the SAME binary on both sides, raw capture to a file).
 *
 * THE TABLES ARE GENERATED. Every byte this program sends lives in mputest_tables.inc, which
 * mputest_decode.py --gen writes from its SCRIPTS; the op encoding is in that file's
 * docstring. The capture's header carries the tables' CRC-32, so the decoder refuses a
 * capture of another build. tests/pc9821/tb_pc9821_mpu_probe.sv runs the same /BYTES script
 * through the core's pc9821_system.
 *
 * USAGE: MPUTEST [/BYTES] [/RAW[:n]] [/NOPLAY] [/NOIRQ] [/P:hhhh] [/O:file]
 *   (default)  DETECT, RESET (+ the IRQ check), UART (FIFO measurement), PLAY, EXIT
 *   /BYTES     DETECT, then only the /BYTES table (nothing else reaches the MIDI line)
 *   /RAW[:n]   adds RAW: an n-byte (default 200, 4..4000) SysEx written BLIND, no BUSY poll -
 *              shows loss; the wire capture says how many bytes survived
 *   /NOPLAY    skips the music; /NOIRQ skips the IRQ check
 *   /P:hhhh    the card's base (data port; status/command is base+2); default: the scan's pick
 *   /O:file    the capture file (default MPUTEST.TXT); everything also goes to the screen
 *   ESC during a WAIT stops the current script (an ABORT row) and goes to the closing reset.
 *
 * PORTS (Roland MPU-401 register pair; NP2kai cbus/mpu98ii.c mpu98ii_bind attaches `port` and
 * `port | 2`): base+0 data (read: the card's response / MIDI IN byte; write: a data byte),
 * base+2 status (read) / command (write). Status bit 7 (DSR) = 0: a byte is waiting at
 * base+0; bit 6 (DRR) = 0: the card accepts a write. The base is one of the 16 option windows
 * 0xC0D0 + k*0x400 (NP2kai `0xc0d0 | ((pConfig->mpuopt & 0xf0) << 6)`), E0D0 the default.
 *
 * TIMING. The ARTIC free-running counter at 005C/005F, 307200 Hz (sndtest.s, the same reader).
 * Every poll is bounded by an ARTIC deadline AND a poll count, so an absent card or a stopped
 * counter costs time, never a hang: BUSY 200 ms, ACK 100 ms.
 *
 * SAFETY. Reads only, until a card is found: the scan reads each window's STATUS port, and its
 * data port only when the status is not open bus. A command is only ever written to the chosen
 * base. The IRQ check masks both 8259s for a few ms with IF=0 (the as-found masks are
 * restored and printed); no vector is touched. MIDI output: GS reset, notes at moderate
 * velocity, non-commercial (ID 0x7D) SysEx no device acts on, the Sound Canvas display-text
 * message, all-notes-off and reset-controllers at the end. The card is left in intelligent
 * mode by the closing 0xFF.
 *
 * OUTPUT (the file and the screen): a header `MPUTEST v1 tables=CRC flow=.. raw=n`, BEGIN:x /
 * END:x around every section (a hang is the BEGIN with no END), PORT/FOUND, CMD, IRQ, FIFO,
 * FIFOST, RAWW, LABEL rows, `MPUTEST DONE` last. The grammar is mputest_decode.py's.
 *
 * BUILD: make -C tools/hwprobe mputest/mputest.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ ST_DSR, 0x80
    .equ ST_DRR, 0x40
    .equ T_BUSY, 61440          /* 200 ms of ARTIC ticks */
    .equ T_ACK, 30720           /* 100 ms */
    .equ POLL_MAX, 0x7FFF       /* x 32 outer: the poll-count bound */
    .equ FIFOST_N, 48

_start:
    jmp     main

    .include "mputest_tables.inc"

main:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    mov     word ptr [raw_n], RAW_DEFAULT
    call    parse_args
    call    open_out
    mov     dx, offset msg_hdr
    call    puts
    mov     dx, offset tables_crc_str
    call    puts
    mov     dx, offset msg_flow
    call    puts
    cmp     byte ptr [f_bytes], 0
    je      m_def
    mov     dx, offset s_bytes
    call    puts
    jmp     m_flow2
m_def:
    mov     dx, offset s_default
    call    puts
    cmp     byte ptr [f_noplay], 0
    je      m_np
    mov     dx, offset s_noplay
    call    puts
m_np:
    cmp     byte ptr [f_raw], 0
    je      m_nr
    mov     dx, offset s_rawf
    call    puts
m_nr:
    cmp     byte ptr [f_noirq], 0
    je      m_flow2
    mov     dx, offset s_noirqf
    call    puts
m_flow2:
    mov     dx, offset msg_raweq
    call    puts
    mov     ax, [raw_n]
    call    putdec
    call    putnl
    mov     dx, offset msg_notes
    call    puts
    call    flush

    call    sec_detect
    cmp     word ptr [base], 0
    je      m_end

    cmp     byte ptr [f_bytes], 0
    je      m_full
    mov     si, offset ops_bytes
    mov     bx, offset nm_bytes
    call    run_section
    jmp     m_end
m_full:
    mov     si, offset ops_reset
    mov     bx, offset nm_reset
    call    run_section_open
    cmp     byte ptr [f_noirq], 0
    jne     m_noirq
    call    irq_check
m_noirq:
    call    section_close
    mov     si, offset ops_uart
    mov     bx, offset nm_uart
    call    run_section
    cmp     byte ptr [f_noplay], 0
    jne     m_noplay
    mov     si, offset ops_play
    mov     bx, offset nm_play
    call    run_section
m_noplay:
    cmp     byte ptr [f_raw], 0
    je      m_noraw
    mov     si, offset ops_raw
    mov     bx, offset nm_raw
    call    run_section
m_noraw:
    mov     byte ptr [aborted], 0       /* the closing reset runs even after an ESC */
    mov     si, offset ops_exit
    mov     bx, offset nm_exit
    call    run_section
m_end:
    mov     dx, offset msg_done
    call    puts
    call    putnl
    call    close_out
    mov     ax, 0x4C00
    int     0x21

/* ==================================================================
 * DETECT: read each option window's status port (and its data port when the status is not
 * open bus); pick /P, else E0D0 when it looks like an idle MPU, else the one window that does.
 * ================================================================== */
sec_detect:
    mov     bx, offset nm_detect
    call    section_begin
    mov     word ptr [cand], 0
    mov     word ptr [ncand], 0
    mov     cx, 16
    mov     ax, 0xC0D0
sd_loop:
    push    cx
    push    ax
    mov     [scan], ax
    mov     dx, ax
    add     dx, 2
    in      al, dx
    mov     [scan_st], al
    mov     byte ptr [scan_dat], 0xFF
    cmp     al, 0xFF
    je      sd_print
    mov     dx, [scan]
    in      al, dx
    mov     [scan_dat], al
    /* an idle MPU: DSR set (nothing waiting) and DRR clear (ready); or anything not 0xFF
     * with bit 6 clear (a byte may be waiting) */
    test    byte ptr [scan_st], ST_DRR
    jnz     sd_print
    inc     word ptr [ncand]
    mov     ax, [scan]
    cmp     word ptr [cand], 0
    je      sd_setc
    cmp     ax, 0xE0D0
    jne     sd_print
sd_setc:
    mov     [cand], ax
sd_print:
    mov     dx, offset msg_port
    call    puts
    mov     ax, [scan]
    call    ph16
    mov     dx, offset msg_st
    call    puts
    mov     al, [scan_st]
    call    ph8
    mov     dx, offset msg_dat
    call    puts
    mov     al, [scan_dat]
    call    ph8
    call    putnl
    pop     ax
    pop     cx
    add     ax, 0x0400
    loop    sd_loop

    mov     ax, [p_base]
    or      ax, ax
    jnz     sd_found
    mov     ax, [cand]
    or      ax, ax
    jz      sd_none
    cmp     ax, 0xE0D0
    je      sd_found
    cmp     word ptr [ncand], 1
    je      sd_found
    mov     dx, offset msg_ambig
    call    puts
    jmp     sd_none
sd_found:
    mov     [base], ax
    mov     dx, offset msg_found
    call    puts
    mov     ax, [base]
    call    ph16
    call    putnl
    jmp     sd_end
sd_none:
    mov     word ptr [base], 0
    mov     dx, offset msg_notfound
    call    puts
    call    putnl
sd_end:
    call    section_close
    ret

/* ==================================================================
 * the script interpreter
 * ================================================================== */
/* run_section: BX = the section name ('$'), SI = its op script. */
run_section:
    call    run_section_open
    call    section_close
    ret

run_section_open:
    call    section_begin
    mov     [secname], bx
rs_loop:
    cmp     byte ptr [aborted], 0
    jne     rs_done
    lodsb
    cmp     al, 0
    je      rs_done
    cmp     al, 1
    je      rs_cmd
    cmp     al, 2
    je      rs_data
    cmp     al, 3
    je      rs_wait
    cmp     al, 4
    je      rs_label
    cmp     al, 5
    je      rs_fifo
    cmp     al, 6
    je      rs_raw
    mov     dx, offset msg_badop
    call    puts
    call    putnl
    jmp     rs_done
rs_cmd:
    lodsb
    call    do_cmd
    jmp     rs_loop
rs_data:
    lodsb
    xor     ch, ch
    mov     cl, al
rs_dl:
    lodsb
    call    do_data
    loop    rs_dl
    jmp     rs_loop
rs_wait:
    lodsw
    call    wait_ms
    jmp     rs_loop
rs_label:
    mov     dx, offset msg_label
    call    puts
    mov     dx, si
    call    puts
rs_skip:
    lodsb
    cmp     al, '$'
    jne     rs_skip
    call    putnl
    jmp     rs_loop
rs_fifo:
    lodsw
    call    do_fifo
    jmp     rs_loop
rs_raw:
    call    do_raw
    jmp     rs_loop
rs_done:
    ret

section_begin:                       /* BX = name */
    mov     dx, offset msg_begin
    call    puts
    mov     dx, bx
    call    puts
    call    putnl
    mov     [cursec], bx
    ret

section_close:
    cmp     byte ptr [aborted], 0
    je      sc_ok
    mov     dx, offset msg_abort
    call    puts
    call    putnl
sc_ok:
    mov     dx, offset msg_end
    call    puts
    mov     dx, [cursec]
    call    puts
    call    putnl
    call    commit
    ret

/* ==================================================================
 * the card primitives
 * ================================================================== */
/* status: AL = in base+2 */
status:
    push    dx
    mov     dx, [base]
    add     dx, 2
    in      al, dx
    pop     dx
    ret

/* wait_ready: poll until DRR (bit 6) is clear. CF = timeout. Adds the polls that saw BUSY to
 * [busy_acc]; [first_busy_seen] = 1 when the first poll saw it. */
wait_ready:
    push    eax
    push    ecx
    mov     byte ptr [first_busy_seen], 0
    call    status
    test    al, ST_DRR
    jz      wr_ok
    mov     byte ptr [first_busy_seen], 1
    call    artic_read
    mov     [t_ref], eax
    mov     cx, 32
wr_o:
    push    cx
    mov     cx, POLL_MAX
wr_i:
    inc     dword ptr [busy_acc]
    call    status
    test    al, ST_DRR
    jz      wr_okp
    call    artic_read
    sub     eax, [t_ref]
    and     eax, 0x00FFFFFF
    cmp     eax, T_BUSY
    jae     wr_top
    loop    wr_i
    pop     cx
    loop    wr_o
    jmp     wr_to
wr_top:
    pop     cx
wr_to:
    inc     word ptr [timeouts]
    pop     ecx
    pop     eax
    stc
    ret
wr_okp:
    pop     cx
wr_ok:
    pop     ecx
    pop     eax
    clc
    ret

/* do_data: AL = byte for base+0, BUSY polled first. */
do_data:
    push    dx
    push    ax
    call    wait_ready
    pop     ax
    mov     dx, [base]
    out     dx, al
    pop     dx
    ret

/* wait_dsr: poll until DSR (bit 7) is clear, bounded by T_ACK. CF = timeout.
 * [polls] = polls made, [t_ack] = ARTIC ticks from [t_ref]. */
wait_dsr:
    push    eax
    push    ecx
    mov     dword ptr [polls], 0
    mov     cx, 32
wd_o:
    push    cx
    mov     cx, POLL_MAX
wd_i:
    inc     dword ptr [polls]
    call    status
    test    al, ST_DSR
    jz      wd_ok
    call    artic_read
    sub     eax, [t_ref]
    and     eax, 0x00FFFFFF
    cmp     eax, T_ACK
    jae     wd_top
    loop    wd_i
    pop     cx
    loop    wd_o
    jmp     wd_to
wd_top:
    pop     cx
wd_to:
    call    artic_read
    sub     eax, [t_ref]
    and     eax, 0x00FFFFFF
    mov     [t_ack], eax
    pop     ecx
    pop     eax
    stc
    ret
wd_ok:
    call    artic_read
    sub     eax, [t_ref]
    and     eax, 0x00FFFFFF
    mov     [t_ack], eax
    pop     cx
    pop     ecx
    pop     eax
    clc
    ret

/* do_cmd: AL = command. Ready, write, wait for the answer, read it, drain the rest; print a
 * CMD row. */
do_cmd:
    push    ax
    push    dx
    mov     [cmd_byte], al
    mov     dword ptr [busy_acc], 0
    call    wait_ready
    call    artic_read
    mov     [t_ref], eax
    mov     al, [cmd_byte]
    mov     dx, [base]
    add     dx, 2
    out     dx, al
    call    cmd_answer
    call    print_cmd
    pop     dx
    pop     ax
    ret

/* cmd_answer: after the command write: [ack] (0xFFFF = none), [extra]. */
cmd_answer:
    push    ax
    push    cx
    push    dx
    mov     word ptr [ack], 0xFFFF
    mov     word ptr [extra], 0
    call    wait_dsr
    jc      ca_done
    mov     dx, [base]
    in      al, dx
    xor     ah, ah
    mov     [ack], ax
    mov     cx, 32
ca_drain:
    call    status
    test    al, ST_DSR
    jnz     ca_done
    mov     dx, [base]
    in      al, dx
    inc     word ptr [extra]
    loop    ca_drain
ca_done:
    pop     dx
    pop     cx
    pop     ax
    ret

print_cmd:
    mov     dx, offset msg_cmd
    call    puts
    mov     dx, [secname]
    call    puts
    mov     dl, ' '
    call    putc
    mov     al, [cmd_byte]
    call    ph8
    mov     dx, offset msg_ack
    call    puts
    cmp     word ptr [ack], 0xFFFF
    jne     pc_ack
    mov     dx, offset msg_dashes
    call    puts
    jmp     pc_ack2
pc_ack:
    mov     al, [ack]
    call    ph8
pc_ack2:
    mov     dx, offset msg_polls
    call    puts
    mov     eax, [polls]
    call    ph32
    mov     dx, offset msg_t
    call    puts
    mov     eax, [t_ack]
    call    ph24
    mov     dx, offset msg_extra
    call    puts
    mov     al, [extra]
    call    ph8
    mov     dx, offset msg_busy
    call    puts
    mov     eax, [busy_acc]
    call    ph32
    call    putnl
    ret

/* sysex_byte: AX = index i, BX = length n -> AL = byte i of F0 7D d.. F7 (d_k = k & 0x7F). */
sysex_byte:
    or      ax, ax
    jnz     sb1
    mov     al, 0xF0
    ret
sb1:
    cmp     ax, 1
    jne     sb2
    mov     al, 0x7D
    ret
sb2:
    push    bx
    dec     bx
    cmp     ax, bx
    pop     bx
    jne     sb3
    mov     al, 0xF7
    ret
sb3:
    sub     ax, 2
    and     al, 0x7F
    ret

/* do_fifo: AX = n. The SysEx with BUSY polled before each write; status after each of the
 * first FIFOST_N writes is kept. Prints FIFO and FIFOST rows. */
do_fifo:
    push    si
    mov     [fifo_n], ax
    mov     word ptr [first_busy], 0xFFFF
    mov     dword ptr [busy_acc], 0
    mov     word ptr [timeouts], 0
    call    artic_read
    mov     [t_fifo], eax
    xor     si, si
df_loop:
    cmp     si, [fifo_n]
    jae     df_done
    call    wait_ready
    cmp     byte ptr [first_busy_seen], 0
    je      df_nb
    cmp     word ptr [first_busy], 0xFFFF
    jne     df_nb
    mov     [first_busy], si
df_nb:
    mov     ax, si
    mov     bx, [fifo_n]
    call    sysex_byte
    mov     dx, [base]
    out     dx, al
    cmp     si, FIFOST_N
    jae     df_next
    call    status
    mov     [fifost + si], al
df_next:
    inc     si
    jmp     df_loop
df_done:
    call    artic_read
    sub     eax, [t_fifo]
    and     eax, 0x00FFFFFF
    mov     [t_fifo], eax
    mov     dx, offset msg_fifo
    call    puts
    mov     ax, [fifo_n]
    call    ph16
    mov     dx, offset msg_fbusy
    call    puts
    mov     ax, [first_busy]
    call    ph16
    mov     dx, offset msg_bpolls
    call    puts
    mov     eax, [busy_acc]
    call    ph32
    mov     dx, offset msg_t
    call    puts
    mov     eax, [t_fifo]
    call    ph24
    mov     dx, offset msg_tmo
    call    puts
    mov     ax, [timeouts]
    call    ph16
    call    putnl
    /* FIFOST rows, 16 per row */
    xor     si, si
dfs_row:
    mov     dx, offset msg_fifost
    call    puts
    mov     cx, 16
dfs_b:
    mov     al, [fifost + si]
    call    ph8
    inc     si
    cmp     cx, 1
    je      dfs_nosp
    mov     dl, ' '
    call    putc
dfs_nosp:
    loop    dfs_b
    call    putnl
    cmp     si, FIFOST_N
    jb      dfs_row
    pop     si
    ret

/* do_raw: [raw_n] bytes of the SysEx, NO poll; then the status once. Prints RAWW. */
do_raw:
    push    si
    call    artic_read
    mov     [t_fifo], eax
    mov     bx, [raw_n]
    mov     dx, [base]
    xor     si, si
dr_loop:
    mov     ax, si
    call    sysex_byte
    out     dx, al
    inc     si
    cmp     si, bx
    jb      dr_loop
    call    artic_read
    sub     eax, [t_fifo]
    and     eax, 0x00FFFFFF
    mov     [t_fifo], eax
    call    status
    mov     [raw_st], al
    mov     dx, offset msg_raww
    call    puts
    mov     ax, [raw_n]
    call    ph16
    mov     dx, offset msg_t
    call    puts
    mov     eax, [t_fifo]
    call    ph24
    mov     dx, offset msg_rst
    call    puts
    mov     al, [raw_st]
    call    ph8
    call    putnl
    pop     si
    ret

/* ==================================================================
 * IRQ: which 8259 line the card raises for a queued response. With IF=0 and both IMRs at
 * 0xFF: IRR before, 0x94 (clock to host off: ACK only, no MIDI byte) written, IRR with the
 * ACK pending, the ACK read, IRR after; the as-found IMRs restored. Prints a CMD row for the
 * 0x94 and an IRQ row ({slave,master} words).
 * ================================================================== */
irq_check:
    cli
    in      al, 0x02
    mov     [imr_m], al
    in      al, 0x0A
    mov     [imr_s], al
    mov     al, 0xFF
    out     0x02, al
    out     0x5F, al
    out     0x0A, al
    out     0x5F, al
    call    irr_word
    mov     [irr_b], ax
    mov     dword ptr [busy_acc], 0
    call    wait_ready
    call    artic_read
    mov     [t_ref], eax
    mov     byte ptr [cmd_byte], 0x94
    mov     al, 0x94
    mov     dx, [base]
    add     dx, 2
    out     dx, al
    mov     word ptr [ack], 0xFFFF
    mov     word ptr [extra], 0
    call    wait_dsr
    pushf
    call    irr_word
    mov     [irr_p], ax
    popf
    jc      ic_noack
    mov     dx, [base]
    in      al, dx
    xor     ah, ah
    mov     [ack], ax
ic_noack:
    call    irr_word
    mov     [irr_a], ax
    /* drain anything else, then restore */
    mov     cx, 32
ic_drain:
    call    status
    test    al, ST_DSR
    jnz     ic_rest
    mov     dx, [base]
    in      al, dx
    inc     word ptr [extra]
    loop    ic_drain
ic_rest:
    mov     al, [imr_s]
    out     0x0A, al
    out     0x5F, al
    mov     al, [imr_m]
    out     0x02, al
    out     0x5F, al
    sti
    mov     ax, [secname]
    push    ax
    mov     word ptr [secname], offset nm_reset
    call    print_cmd
    pop     ax
    mov     [secname], ax
    mov     dx, offset msg_irq
    call    puts
    mov     ah, [imr_s]
    mov     al, [imr_m]
    call    ph16
    mov     dx, offset msg_ibefore
    call    puts
    mov     ax, [irr_b]
    call    ph16
    mov     dx, offset msg_ipend
    call    puts
    mov     ax, [irr_p]
    call    ph16
    mov     dx, offset msg_iafter
    call    puts
    mov     ax, [irr_a]
    call    ph16
    mov     dx, offset msg_ack
    call    puts
    cmp     word ptr [ack], 0xFFFF
    jne     ic_a
    mov     dx, offset msg_dashes
    call    puts
    jmp     ic_a2
ic_a:
    mov     al, [ack]
    call    ph8
ic_a2:
    call    putnl
    ret

/* irr_word: AX = {slave IRR, master IRR} (OCW3 0x0A = read IRR). */
irr_word:
    mov     al, 0x0A
    out     0x08, al
    out     0x5F, al
    in      al, 0x08
    mov     ah, al
    mov     al, 0x0A
    out     0x00, al
    out     0x5F, al
    in      al, 0x00
    ret

/* ==================================================================
 * time
 * ================================================================== */
/* artic_read: EAX = the 24-bit ARTIC count (sndtest.s's reader; EBX/ECX/DX preserved). */
artic_read:
    push    ebx
    push    ecx
    push    dx
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
    je      ar_same
    cmp     ecx, 0x8000
    jb      ar_same
    mov     eax, ebx
ar_same:
    shl     eax, 16
    or      eax, ecx
    pop     dx
    pop     ecx
    pop     ebx
    ret

/* wait_ms: AX = milliseconds (ARTIC: ms * 3072 / 10 ticks). ESC sets [aborted]. Bounded by a
 * poll count too. */
wait_ms:
    push    eax
    push    ebx
    push    ecx
    push    edx
    movzx   eax, ax
    imul    eax, eax, 3072
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    mov     [w_ticks], eax
    call    artic_read
    mov     [w_ref], eax
    mov     cx, 0x0800
wm_o:
    push    cx
    mov     cx, 0x4000
wm_i:
    call    artic_read
    sub     eax, [w_ref]
    and     eax, 0x00FFFFFF
    cmp     eax, [w_ticks]
    jae     wm_donep
    loop    wm_i
    pop     cx
    /* ESC? (DOS: AH=0B status, AH=07 read without echo) */
    mov     ah, 0x0B
    int     0x21
    or      al, al
    jz      wm_nok
    mov     ah, 0x07
    int     0x21
    cmp     al, 0x1B
    jne     wm_nok
    mov     byte ptr [aborted], 1
    jmp     wm_done
wm_nok:
    loop    wm_o
    jmp     wm_done
wm_donep:
    pop     cx
wm_done:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* ==================================================================
 * the command line
 * ================================================================== */
parse_args:
    mov     si, 0x81
    xor     ch, ch
    mov     cl, [0x80]
    mov     bx, si
    add     bx, cx
    mov     byte ptr [bx], 0          /* NUL-terminate the tail */
pa_next:
    lodsb
    or      al, al
    jz      pa_done
    cmp     al, '/'
    jne     pa_next
    lodsb
    call    upcase
    cmp     al, 'B'
    je      pa_b
    cmp     al, 'R'
    je      pa_r
    cmp     al, 'N'
    je      pa_n
    cmp     al, 'P'
    je      pa_p
    cmp     al, 'O'
    je      pa_o
    cmp     al, '?'
    je      pa_help
    jmp     pa_next
pa_b:
    mov     byte ptr [f_bytes], 1
    jmp     pa_next
pa_r:
    mov     byte ptr [f_raw], 1
pa_r1:
    lodsb
    or      al, al
    jz      pa_done
    cmp     al, ':'
    je      pa_rn
    cmp     al, ' '
    je      pa_next
    cmp     al, '/'
    jne     pa_r1
    dec     si
    jmp     pa_next
pa_rn:
    call    getdec
    cmp     ax, 4
    jb      pa_next
    cmp     ax, 4000
    ja      pa_next
    mov     [raw_n], ax
    jmp     pa_next
pa_n:
    lodsb
    call    upcase
    cmp     al, 'O'
    jne     pa_next
    lodsb
    call    upcase
    cmp     al, 'P'
    je      pa_np
    cmp     al, 'I'
    je      pa_ni
    jmp     pa_next
pa_np:
    mov     byte ptr [f_noplay], 1
    jmp     pa_next
pa_ni:
    mov     byte ptr [f_noirq], 1
    jmp     pa_next
pa_p:
    lodsb
    cmp     al, ':'
    jne     pa_next
    call    gethex
    mov     [p_base], ax
    jmp     pa_next
pa_o:
    lodsb
    cmp     al, ':'
    je      pa_o1
    cmp     al, ' '
    jne     pa_next
pa_o1:
    lodsb                             /* skip blanks */
    cmp     al, ' '
    je      pa_o1
    dec     si
    mov     di, offset fname
    mov     cx, 63
pa_oc:
    lodsb
    cmp     al, ' '
    jbe     pa_oe
    cmp     al, '/'
    je      pa_oe
    stosb
    loop    pa_oc
    inc     si
pa_oe:
    dec     si
    mov     byte ptr [di], 0
    jmp     pa_next
pa_help:
    mov     ah, 0x09
    mov     dx, offset msg_usage
    int     0x21
    mov     ax, 0x4C01
    int     0x21
pa_done:
    ret

upcase:
    cmp     al, 'a'
    jb      uc_r
    cmp     al, 'z'
    ja      uc_r
    sub     al, 0x20
uc_r:
    ret

/* getdec: decimal at DS:SI -> AX (stops at a non-digit, SI left on it) */
getdec:
    push    bx
    push    dx
    xor     bx, bx
gd_l:
    mov     al, [si]
    cmp     al, '0'
    jb      gd_d
    cmp     al, '9'
    ja      gd_d
    inc     si
    sub     al, '0'
    xor     ah, ah
    push    ax
    mov     ax, bx
    mov     dx, 10
    mul     dx
    pop     dx
    add     ax, dx
    mov     bx, ax
    jmp     gd_l
gd_d:
    mov     ax, bx
    pop     dx
    pop     bx
    ret

/* gethex: hex at DS:SI -> AX */
gethex:
    push    bx
    xor     bx, bx
gh_l:
    mov     al, [si]
    call    upcase
    cmp     al, '0'
    jb      gh_d
    cmp     al, '9'
    jbe     gh_n
    cmp     al, 'A'
    jb      gh_d
    cmp     al, 'F'
    ja      gh_d
    sub     al, 'A' - 10
    jmp     gh_a
gh_n:
    sub     al, '0'
gh_a:
    inc     si
    shl     bx, 4
    or      bl, al
    jmp     gh_l
gh_d:
    mov     ax, bx
    pop     bx
    ret

/* ==================================================================
 * output: a line buffer, flushed at CRLF to stdout and the capture file
 * ================================================================== */
open_out:
    mov     ah, 0x3C
    xor     cx, cx
    mov     dx, offset fname
    int     0x21
    jnc     oo_ok
    mov     word ptr [fh], 0
    mov     ah, 0x09
    mov     dx, offset msg_nofile
    int     0x21
    ret
oo_ok:
    mov     [fh], ax
    ret

close_out:
    call    flush
    mov     bx, [fh]
    or      bx, bx
    jz      co_r
    mov     ah, 0x3E
    int     0x21
co_r:
    ret

/* commit: flush the file's DOS buffers (AH=68h, DOS 3.3+), so a later hang keeps the rows */
commit:
    call    flush
    mov     bx, [fh]
    or      bx, bx
    jz      cm_r
    mov     ah, 0x68
    int     0x21
cm_r:
    ret

putc:                                /* DL */
    push    bx
    mov     bx, [lb_n]
    mov     [linebuf + bx], dl
    inc     word ptr [lb_n]
    cmp     word ptr [lb_n], 250
    pop     bx
    jb      putc_r
    call    flush
putc_r:
    ret

puts:                                /* DX = '$'-terminated */
    push    si
    push    dx
    mov     si, dx
ps_l:
    mov     dl, [si]
    cmp     dl, '$'
    je      ps_d
    call    putc
    inc     si
    jmp     ps_l
ps_d:
    pop     dx
    pop     si
    ret

putnl:
    push    dx
    mov     dl, 0x0D
    call    putc
    mov     dl, 0x0A
    call    putc
    call    flush
    pop     dx
    ret

flush:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     cx, [lb_n]
    jcxz    fl_r
    mov     ah, 0x40
    mov     bx, 1
    mov     dx, offset linebuf
    int     0x21
    mov     bx, [fh]
    or      bx, bx
    jz      fl_z
    mov     cx, [lb_n]
    mov     ah, 0x40
    mov     dx, offset linebuf
    int     0x21
fl_z:
    mov     word ptr [lb_n], 0
fl_r:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

ph8:                                 /* AL */
    push    ax
    push    dx
    push    ax
    shr     al, 4
    call    phd
    pop     ax
    call    phd
    pop     dx
    pop     ax
    ret
phd:
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     phd_o
    add     al, 7
phd_o:
    mov     dl, al
    call    putc
    ret
ph16:                                /* AX */
    push    ax
    xchg    al, ah
    call    ph8
    xchg    al, ah
    call    ph8
    pop     ax
    ret
ph24:                                /* EAX bits 23:0 */
    push    eax
    shr     eax, 16
    call    ph8
    pop     eax
    call    ph16
    ret
ph32:
    push    eax
    shr     eax, 16
    call    ph16
    pop     eax
    call    ph16
    ret
putdec:                              /* AX, unsigned */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, 10
    xor     cx, cx
pd_l:
    xor     dx, dx
    div     bx
    push    dx
    inc     cx
    or      ax, ax
    jnz     pd_l
pd_o:
    pop     dx
    add     dl, '0'
    call    putc
    loop    pd_o
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ==================================================================
 * strings
 * ================================================================== */
msg_hdr:      .ascii "MPUTEST v1 tables=$"
msg_flow:     .ascii " flow=$"
s_bytes:      .ascii "BYTES$"
s_default:    .ascii "DEFAULT$"
s_noplay:     .ascii ",NOPLAY$"
s_rawf:       .ascii ",RAW$"
s_noirqf:     .ascii ",NOIRQ$"
msg_raweq:    .ascii " raw=$"
msg_notes:
    .ascii "NOTE MPUTEST (tools/hwprobe/mputest): MPU-401-family MIDI card probe. Decode with\r\n"
    .ascii "NOTE mputest_decode.py; its README lists the sources for these expectations.\r\n"
    .ascii "NOTE The core models the MPU-PC98II as NP2kai does: every intelligent-mode command\r\n"
    .ascii "NOTE is ACKed FE at once; 0xFF AND 0x3F each send 16 x Bn 7B 00 (all notes off) on\r\n"
    .ascii "NOTE MIDI OUT; in UART mode only 0xFF is answered: it leaves UART mode with no burst\r\n"
    .ascii "NOTE and, as the Roland MPU-401 manual says (NP2kai differs), NO ACK; BUSY (bit 6) =\r\n"
    .ascii "NOTE its 32-byte output queue half full or a byte waiting for room; base E0D0,\r\n"
    .ascii "NOTE IRQ6 only; no MIDI IN.\r\n"
    .ascii "NOTE Expected to DIFFER on a real card: ACK latency (the card's own CPU), how long\r\n"
    .ascii "NOTE DRR stays busy per byte, whether 0xFF/0x3F put bytes on MIDI OUT (the Roland\r\n"
    .ascii "NOTE MPU-401 manual names none), how many blind /RAW bytes survive.\r\n"
    .ascii "NOTE MPU-PC98 (original): base E0D0 and INT2 (IRQ6) fixed,\r\n"
    .ascii "NOTE tape sync; MPU-PC98II: 16 bases C0D0-FCD0 by DIP switch, INT0/1/2/5 (IRQ\r\n"
    .ascii "NOTE 3/5/6/12) by jumper, default E0D0/INT2. MIDI IN bytes show as extra= on CMD.\r\n$"
msg_begin:    .ascii "BEGIN:$"
msg_end:      .ascii "END:$"
msg_port:     .ascii "PORT base=$"
msg_st:       .ascii " st=$"
msg_dat:      .ascii " dat=$"
msg_found:    .ascii "FOUND base=$"
msg_notfound: .ascii "NOTFOUND (no window answers like an idle MPU; give /P:hhhh)$"
msg_ambig:    .ascii "AMBIGUOUS several windows answer and none is E0D0: give /P:hhhh\r\n$"
msg_cmd:      .ascii "CMD $"
msg_ack:      .ascii " ack=$"
msg_dashes:   .ascii "--$"
msg_polls:    .ascii " polls=$"
msg_t:        .ascii " t=$"
msg_extra:    .ascii " extra=$"
msg_busy:     .ascii " busy=$"
msg_label:    .ascii "LABEL $"
msg_badop:    .ascii "BADOP (the tables are corrupt)$"
msg_abort:    .ascii "ABORT (ESC): the rest of this section was skipped$"
msg_fifo:     .ascii "FIFO n=$"
msg_fbusy:    .ascii " first_busy=$"
msg_bpolls:   .ascii " busy_polls=$"
msg_tmo:      .ascii " timeouts=$"
msg_fifost:   .ascii "FIFOST $"
msg_raww:     .ascii "RAWW n=$"
msg_rst:      .ascii " st=$"
msg_irq:      .ascii "IRQ imr=$"
msg_ibefore:  .ascii " before=$"
msg_ipend:    .ascii " pend=$"
msg_iafter:   .ascii " after=$"
msg_done:     .ascii "MPUTEST DONE$"
msg_nofile:   .ascii "MPUTEST: cannot create the capture file; screen only\r\n$"
msg_usage:
    .ascii "MPUTEST [/BYTES] [/RAW[:n]] [/NOPLAY] [/NOIRQ] [/P:hhhh] [/O:file]\r\n"
    .ascii "  MIDI card probe (MPU-PC98/MPU-PC98II). Default capture MPUTEST.TXT.\r\n$"
nm_detect:    .ascii "DETECT$"
nm_reset:     .ascii "RESET$"
nm_uart:      .ascii "UART$"
nm_play:      .ascii "PLAY$"
nm_raw:       .ascii "RAW$"
nm_exit:      .ascii "EXIT$"
nm_bytes:     .ascii "BYTES$"

/* ==================================================================
 * data
 * ================================================================== */
    .balign 4
t_ref:        .long 0
t_ack:        .long 0
t_fifo:       .long 0
polls:        .long 0
busy_acc:     .long 0
w_ticks:      .long 0
w_ref:        .long 0
base:         .word 0
p_base:       .word 0
cand:         .word 0
ncand:        .word 0
scan:         .word 0
raw_n:        .word 200
fifo_n:       .word 0
first_busy:   .word 0
timeouts:     .word 0
ack:          .word 0
extra:        .word 0
secname:      .word 0
cursec:       .word 0
irr_b:        .word 0
irr_p:        .word 0
irr_a:        .word 0
fh:           .word 0
lb_n:         .word 0
scan_st:      .byte 0
scan_dat:     .byte 0
cmd_byte:     .byte 0
first_busy_seen: .byte 0
raw_st:       .byte 0
imr_m:        .byte 0
imr_s:        .byte 0
aborted:      .byte 0
f_bytes:      .byte 0
f_raw:        .byte 0
f_noplay:     .byte 0
f_noirq:      .byte 0
fname:        .ascii "MPUTEST.TXT"
              .fill 53, 1, 0
fifost:       .fill FIFOST_N, 1, 0
linebuf:      .fill 260, 1, 0
