/* sec_kit3.inc - XE10Y.COM only: the 2026-11 kit-3 sections /PKAB, /CELLS and /K3M.
 *
 * /PKAB - THE PEGC STORE A/B. The same store code (shell BDFC: 512 word stores to the PEGC
 * packed bank 0 at 0xA8000, DI += 4, 2 ms after the VSYNC fall) reads 182.8 ns per store in
 * XE10X /RDLAT (docs/probes/XE10X-XE10-RDLAT1.TXT:223 PKW_24A, pit=228/230/236) and 145.4 ns in
 * XE10W /MISAL2 (docs/probes/XE10W-XE10-MIS2RUN1.TXT:324 PKW_0_A, pit=181/183/189); MISAL2's
 * misaligned PKW_1_A (:330, pit=226/228/235) reads RDLAT's figure, and each capture repeats
 * within 1 % (RDLAT2 :223 229, MIS2RUN2 :324 183). Both captures' rows are byte-identical code,
 * so the difference is the state or the sequence around them. In ONE binary and one boot,
 * /PKAB runs, three rounds interleaved, with the display of both (INT 18h AH=42h CH=C0, AH=40h,
 * 24 kHz) and every window at the /MISAL `_A` place (win_ph 1):
 *   M  /MISAL2's phase sequence as /MISAL2 runs it (m2_phase: GVRAM reads, TCR, the RMW blit,
 *      the text rows, then the PEGC packed table PKW_0 PKW_1 PKW_3 PKD_0 PKD_1 PKR_*), its own
 *      nop list (sweep_ks); tags <MISAL2 tag>_M<round>
 *   R  /RDLAT's 24 kHz phase sequence as /RDLAT runs it (rd_ph16: GRW GRD GW GLSW GMVR, TCRW
 *      TDW, RMW, the text rows, then PKR and PKW), its nop list (rd_ks); tags <tag>_R<round>
 *   F  the factor rows, nop 0, at the A place (_FA<round>) and from the VSYNC rise (_FV<round>):
 *      PKW1ST straight after the 256-colour mode is turned on (m2_pegc_on), PKRF (a PKR row),
 *      PKWAFT after it, 60 frames of nothing, PKWLATE, PKWODD (DI = 1, /MISAL2's PKW_1), PKWHI
 *      (DI = 0x4000, another part of the bank), PKDF (the dword store, /MISAL2's PKD_0)
 *   C  the L1 cache as found: GRW GW (plane B, the 256-colour mode off), GRS (one GVRAM word
 *      read 512 times: a cached VRAM read would cost a cache hit), RLWH (main memory, the same
 *      1 KiB 4 times: the cache-on control), then PKW PKR PKRS (PKR at one address); _C<round>
 *   N  the same rows with the L1 cache off (CR0.CD = 1, NW = 1, then WBINVD; CR0 put back and
 *      WBINVD after, a RESTORE line): RLWH must slow down, or the cache was not off; _N<round>
 *   D  the C rows with a drain read before every window (time_call: a byte read of 0xA87FF0,
 *      VRAM, which a 486 does not take ahead of its buffered writes); _D<round>
 * Before every row (lib.inc run_case, [k3_rowst]) a STATE line gives the 0x9A0 queries 04 07 08
 * 0A, the BDA 0x054C/0x054D, port 0x09A8, CR0, the PEGC registers E0004 E0006 E0100 E0102 as read,
 * the ARTIC ticks since the last m2_pegc_on (or -), whether the drain is on, and the row's
 * destination and source as its own setup code leaves them (the setup is run alone in a
 * sandbox, SECBUF+0x700): dst=ES:DI lin= al4= (lin mod 4) al16= (lin mod 16) src=DS:SI.
 * The decoder (xe10t_decode.py pkab) prints every PKW figure per sequence, round and factor and
 * names the factor that moves it.
 *
 * /CELLS - item 197: the class-table cells no capture measures, by the /RDLAT method (n = 512
 * per window, DI += 4, every row swept at rd_ks's 0..64 nops, tags FAM_<MODE><PH>, PH A or V):
 *   MODE 31 (640x400 at 31 kHz, 256 colours off): the two-word classes - TCRWM (the TCR word
 *      read at DI = 1, /MISAL2's TCRW_1) and TCRD (dword), GWM and GD (plain store, word at
 *      DI = 1 and dword), TDWM TDD (TDW), RMWM RMD (RMW), XCRM XCWM (text code word at 0xA1001)
 *   MODE 2P (24 kHz 640x400 with the 256-colour mode on, m2_pegc_on): the text rows XCR XCW
 *      XCRS XCWS XARS XAWS XCRM XCWM, PKR PKW (RDLAT's 24 kHz PEGC rows ran in this state), the
 *      GVRAM rows on 0xB8000 (BRW BRD BW BD: the 256-colour mode maps 0xA8000-0xB7FFF to the
 *      packed banks, so B8000 is where a plane access could still go; X B8 says what it is)
 *   MODE 3P (640x400 at 31 kHz with the 256-colour mode on): XCR XCW XCRM XCWM PKR PKW BRW BW
 *   MODE 48 (AH=30h BH=31, 640x480 256 colours, /RDLAT's mode 48): XCRM XCWM BRW BRD BW BD
 *   THE APERTURE (2P and 48): 0x043B bit 2 set (the 15-16 MiB system space; risky /43B wrote it
 *      on the machine, docs/probes/KIT2-XE10-RISKY-43B.TXT), A20 opened if it was closed, 0xE0102
 *      <- 01 (the PEGC's linear-VRAM enable, pc9821_pegc.sv), FS with a 4 GiB limit (unreal
 *      mode, risky.s unreal_fs): PAW (word store at 0xF00000 + EDI), PAR (word load), PAD (dword
 *      store); X APER first proves the window (a word stored through 0xA8000 read at 0xF00000,
 *      and one stored at 0xF00002 read at 0xA8002, each read again after a WBINVD, and the
 *      0xF00002 word read back through the aperture: f0_rb2). Put back: 0xE0102 <- 00, 0x043B as found
 *      (read-back RESTORE), A20 as found (a wrap test, RESTORE), WBINVD after each 0x043B write.
 * The mode switching, the TRAM save and every restore are /RDLAT's (rd_set, rd_exit).
 *
 * /K3M - small read-mostly rows for the open items a probe on this machine can answer:
 *   IDE, only with /ATA (the review's IDENTIFY finding, src/pc9821/storage/pc9821_ata.sv's Sector
 *      Count rule; both kit-3 images ran it by default and the Xe10's CF card answered IDENTIFY PACKET
 *      with a reset to its default translation, so the BIOS's next disk access went to the wrong
 *      sector: docs/probes/XE10Y-XE10-K3M2.TXT; now INITIALIZE DEVICE PARAMETERS follows it with
 *      the geometry of the first IDENTIFY's words 55/56 and a second IDENTIFY DEVICE proves it):
 *      the first ATA device on bank 0 then bank 1 (bank 0 holds the Xe10's CF card,
 *      docs/probes/XE10T-XE10.TXT:471, and the core's disk; DRDY, not the ATAPI signature, and
 *      IDENTIFY DEVICE must return a block with word 0 bit 15 clear, else the next bank); the task file loaded with SC=5A SN=A5 CL=3C CH=C3 and read back (TF0), then
 *      IDENTIFY DEVICE: at DRQ the alternate status, 0x0433 and the task file (TF1), the 256 words
 *      read (a CRC and words 0 1 3 6 47 49 59), the task file again at BSY clear (TF2); then the
 *      same load and IDENTIFY PACKET DEVICE 0xA1 on it (TF3 at BSY clear: an ATA disk aborts it,
 *      ERR + ABRT). Slave IMR bit 1 masked around each command, 0x0432 put back, output held
 *      while another bank is selected (as /IDE). No ATAPI device is addressed.
 *   IDIV (item 168 A): AX = B0F8h / BL = 1Eh (US 5,689,721's worked example): AX after it, or #DE
 *      (an INT 0 stub that skips the 2-byte idiv).
 *   E0000 (item 31): the 0xE0000 dword in the as-found colour mode (read only), then with 0x6A
 *      <- 01 (16 colours): read, 00 FF 55 AA written, read back, the bytes put back, the mode put
 *      back (0x9A0 query 04 RESTORE).
 *   PIT (one-byte count writes): channel 0 under cli with IRQ0 masked as found: mode 0 count 1234h, then a
 *      LSB-only mode-0 write of 56h (retained high byte: 1256h counts, 1.9 ms; zeroed: 56h,
 *      35 us), and count 12F0h then an MSB-only write of 01h (01F0h: 202 us; 0100h: 104 us).
 *      Each to OUT: ARTIC ticks to the read-back status's OUT bit (0x77 <- E2h) and to the
 *      master IRR bit 0, polled; then channel 0 back to mode 0 with CAL's modulus (as /IRQ).
 *      Skipped when IRQ0 is unmasked as found.
 *   HBL (item 23): the master GDC's status (0x60) polled 2048 times under cli from the VSYNC
 *      rise, and the slave's (0xA0) the same, each window timed on the ARTIC: the run lengths of
 *      (VSYNC, HBLANK) give where the blank sits in the line against the VSYNC edge, in polls.
 */

    .equ K3_ROUNDS, 3
    .equ K3_SB,     SECBUF + 0x700          /* the setup sandbox (256 bytes) */

/* /PKAB factor and cache rows */
TPL k_seth,  "mov ax, 0xA800; mov es, ax; mov di, 0x4000; mov eax, 0x55AA55AA"
TPL b_set0,  "mov ax, 0xB800; mov es, ax; xor di, di; mov eax, 0x55AA55AA"
TPL k_aset,  "xor ax, ax; mov fs, ax; mov edi, 0x00F00000; mov eax, 0x55AA55AA"
TPL k_aw16,  "mov word ptr fs:[edi], ax"
TPL k_ar16,  "mov bx, word ptr fs:[edi]"
TPL k_aw32,  "mov dword ptr fs:[edi], eax"
TPL k_aadv,  "add edi, 4"

tab_k3_f1:
    CASE "PKW1ST", "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil
    CASE "PKRF",   "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil
    CASE "PKWAFT", "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil
    ENDTAB
tab_k3_f2:
    CASE "PKWLATE", "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil
    CASE "PKWODD",  "w", 512, 64, 8, m_set1, g_w16, g_adv4, g_nil
    CASE "PKWHI",   "w", 512, 64, 8, k_seth, g_w16, g_adv4, g_nil
    CASE "PKDF",    "d", 512, 64, 8, m_set0, g_w32, g_adv4, g_nil
    ENDTAB
tab_k3_cg:                                  /* the 256-colour mode off, GRCG off */
    CASE "GRW",  "w", 512,  64,  8, m_set0, g_r16, g_adv4, g_nil
    CASE "GW",   "w", 512,  64,  8, m_set0, g_w16, g_adv4, g_nil
    CASE "GRS",  "w", 512,  64,  8, m_set0, g_r16, g_nil,  g_nil
    CASE "RLWH", "w", 4096, 512, 8, r_set0, g_r16, r_advh, g_nil, CF_BUF
    ENDTAB
tab_k3_cp:                                  /* the 256-colour packed bank 0 */
    CASE "PKW",  "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil
    CASE "PKR",  "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil
    CASE "PKRS", "w", 512, 64, 8, m_set0, g_r16, g_nil,  g_nil
    ENDTAB
tl_pkab:    .word tab_k3_f1, tab_k3_f2, tab_k3_cg, tab_k3_cp, 0

/* /CELLS */
tab_c_31:                                   /* 31 kHz, the 256-colour mode off */
    CASE "TCRWM", "w", 512, 64, 8, m_set1, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "TCRD",  "d", 512, 64, 8, m_set0, g_r32, g_adv4, g_nil, CF_SWEEP
    CASE "TDWM",  "w", 512, 64, 8, m_set1, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "TDD",   "d", 512, 64, 8, m_set0, g_w32, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_31r:                                  /* 0x7C = C0 */
    CASE "RMWM",  "w", 512, 64, 8, m_set1, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "RMD",   "d", 512, 64, 8, m_set0, g_w32, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_31p:                                  /* GRCG off */
    CASE "GWM",   "w", 512, 64, 8, m_set1, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "GD",    "d", 512, 64, 8, m_set0, g_w32, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_tx2:                                  /* text, two-word (off screen 0xA1001) */
    CASE "XCRM",  "w", 512, 64, 8, x_c1, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XCWM",  "w", 512, 64, 8, x_c1, g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_tx1:                                  /* text, one-word, off screen and on */
    CASE "XCR",   "w", 512, 64, 8, x_c0,  g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XCW",   "w", 512, 64, 8, x_c0,  g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XCRS",  "w", 512, 64, 8, x_cs0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XCWS",  "w", 512, 64, 8, x_cs0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XARS",  "w", 512, 64, 8, x_as0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XAWS",  "w", 512, 64, 8, x_as0, g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_tx1s:                                 /* text, one-word, off screen only (3P) */
    CASE "XCR",   "w", 512, 64, 8, x_c0,  g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "XCW",   "w", 512, 64, 8, x_c0,  g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_b8:                                   /* 0xB8000 with the 256-colour mode on */
    CASE "BRW",   "w", 512, 64, 8, b_set0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "BRD",   "d", 512, 64, 8, b_set0, g_r32, g_adv4, g_nil, CF_SWEEP
    CASE "BW",    "w", 512, 64, 8, b_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "BD",    "d", 512, 64, 8, b_set0, g_w32, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_b8s:
    CASE "BRW",   "w", 512, 64, 8, b_set0, g_r16, g_adv4, g_nil, CF_SWEEP
    CASE "BW",    "w", 512, 64, 8, b_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    ENDTAB
tab_c_ap:                                   /* the 0xF00000 aperture */
    CASE "PAW",   "w", 512, 64, 8, k_aset, k_aw16, k_aadv, g_nil, CF_SWEEP
    CASE "PAR",   "w", 512, 64, 8, k_aset, k_ar16, k_aadv, g_nil, CF_SWEEP
    CASE "PAD",   "d", 512, 64, 8, k_aset, k_aw32, k_aadv, g_nil, CF_SWEEP
    ENDTAB
tl_cells:   .word tab_c_31, tab_c_31r, tab_c_31p, tab_c_tx2, tab_c_tx1, tab_c_tx1s, tab_c_b8, tab_c_b8s, tab_rd_pk, tab_c_ap, 0

tc_pkab:    .asciz "RAM buffer(scribbled) GVRAM-B/PEGC-bank0(scribbled) TRAM 0xA0000-0xA3FFF(saved,restored) 0x7C=80/C0/00 0x7E 0x6A E0004/E0006/E0100 CR0.CD/NW(restored) INT18h AH=41/42/40 then as found"
tc_cells:   .asciz "RAM buffer GVRAM-B/G,PEGC(scribbled) TRAM(saved,restored) 0x7C 0x7E 0x6A E0004/E0006/E0100 E0102=01/00 0x043B bit2(readback) 0xF6 A20(as found) FS 4GiB limit INT18h AH=30/31/0C/41/42/40 then as found"
tc_k3m:     .asciz "0x432(bank,restored) 0x0A IMR bit1 0x642-0x64E(task file: loaded, IDENTIFY 0xEC, IDENTIFY PACKET 0xA1) IVT 00(stub,restored) 0x6A=01/as found E0000(4 bytes,restored) PIT ch0(mode0, CAL modulus after) OCW3"
nm_pkab:    .asciz "PKAB"
kw_pkab:    .asciz "PKAB"
nm_cells:   .asciz "CELLS"
kw_cells:   .asciz "CELLS"
nm_k3m:     .asciz "K3M"
kw_k3m:     .asciz "K3M"
kw_rep:     .asciz "REP"
kw_k3ab:    .asciz "AB"
kw_k3d:     .asciz "DRAIN"
kw_k3n:     .asciz "L1OFF"
kw_k3ap:    .asciz "APER"
kw_k3noap:  .asciz "NOAPER"
kw_k3ata:   .asciz "ATA"
n_cr0:      .asciz "CR0"
n_43b:      .asciz "P043B"
n_e0102:    .asciz "E0102_APERTURE"
n_a20:      .asciz "A20_WRAP"
n_e0000:    .asciz "E0000_DWORD"
n_vec00:    .asciz "IVT00"
n_k3bank:   .asciz "P432_BANK"
n_k3pmode:  .asciz "PIT_CH0_STATUS"
tg_k3ide:   .asciz "IDE"
tg_k3pit:   .asciz "PIT"
tg_r2p:     .asciz "RASTER_2P"
tg_r3p:     .asciz "RASTER_3P"
rs_k3buf:   .asciz "buffer_under_256k"
rs_k3irq0:  .asciz "irq0_unmasked"
rs_k3noata: .asciz "no_ata_device"
md_2p:      .asciz "2P"
md_3p:      .asciz "3P"
sfx_2pa:    .asciz "_2PA"
sfx_2pv:    .asciz "_2PV"
sfx_3pa:    .asciz "_3PA"
sfx_3pv:    .asciz "_3PV"
k3_sfx:     .asciz "_M1", "_M2", "_M3", "_R1", "_R2", "_R3", "_FA1", "_FA2", "_FA3", "_FV1", "_FV2", "_FV3", "_C1", "_C2", "_C3", "_N1", "_N2", "_N3", "_D1", "_D2", "_D3"
k3_sfxt:    .word k3_sfx, k3_sfx+4, k3_sfx+8, k3_sfx+12, k3_sfx+16, k3_sfx+20
            .word k3_sfx+24, k3_sfx+29, k3_sfx+34, k3_sfx+39, k3_sfx+44, k3_sfx+49
            .word k3_sfx+54, k3_sfx+58, k3_sfx+62, k3_sfx+66, k3_sfx+70, k3_sfx+74
            .word k3_sfx+78, k3_sfx+82, k3_sfx+86

/* ------------------------------------------------------------------ the lib.inc hooks */
/* k3_drain_rd: a VRAM byte read (uncached, not taken ahead of buffered writes), all kept */
k3_drain_rd:
    push    ax
    push    es
    mov     ax, 0xA800
    mov     es, ax
    mov     al, byte ptr es:[0x7FF0]
    pop     es
    pop     ax
    ret

/* k3_rowstate: the STATE line before a row ([cur_case]); every register kept */
k3_rowstate:
    pushad
    push    es
    call    k3_dest
    mov     si, offset k_STATE
    call    info_start
    PS      "row="
    mov     bx, word ptr [cur_case]
    mov     si, word ptr [bx+CD_TAG]
    call    out_s
    mov     si, word ptr [tag_sfx]
    test    si, si
    jz      1f
    call    out_s
1:  PS      " q04="
    mov     al, 0x04
    call    query9a0
    call    out_x2
    PS      " q07="
    mov     al, 0x07
    call    query9a0
    call    out_x2
    PS      " q08="
    mov     al, 0x08
    call    query9a0
    call    out_x2
    PS      " q0A="
    mov     al, 0x0A
    call    query9a0
    call    out_x2
    call    ms_state_bda
    PS      " p9a8="
    mov     dx, 0x09A8
    in      al, dx
    call    out_x2
    PS      " cr0="
    mov     eax, cr0
    call    out_x8
    mov     ax, 0xE000
    mov     es, ax
    PS      " e0004="
    mov     ax, word ptr es:[0x0004]
    call    out_x4
    PS      " e0006="
    mov     ax, word ptr es:[0x0006]
    call    out_x4
    PS      " e0100="
    mov     al, byte ptr es:[0x0100]
    call    out_x2
    PS      " e0102="
    mov     al, byte ptr es:[0x0102]
    call    out_x2
    PS      " pgon="
    movzx   eax, byte ptr [m2_pgon]
    call    out_d
    PS      " since_pegc="
    cmp     byte ptr [m2_pgon], 0
    je      2f
    call    artic_read
    sub     eax, dword ptr [k3_pgt]
    and     eax, 0x00FFFFFF
    call    out_d
    jmp     3f
2:  PS      "-"
3:  PS      " drain="
    movzx   eax, byte ptr [k3_drain]
    call    out_d
    PS      " winph="
    movzx   eax, byte ptr [win_ph]
    call    out_d
    PS      " dst="
    mov     ax, word ptr [k3_es]
    call    out_x4
    mov     al, ':'
    call    out_c
    mov     eax, dword ptr [k3_edi]
    call    out_x8
    PS      " lin="
    movzx   eax, word ptr [k3_es]
    shl     eax, 4
    add     eax, dword ptr [k3_edi]
    push    eax
    call    out_x8
    pop     eax
    push    eax
    PS      " al4="
    and     eax, 3
    call    out_d
    pop     eax
    PS      " al16="
    and     eax, 15
    call    out_d
    PS      " src="
    mov     ax, word ptr [k3_ds]
    call    out_x4
    mov     al, ':'
    call    out_c
    mov     ax, word ptr [k3_si]
    call    out_x4
    call    out_nl
    call    k3_commit                   /* the row's state is on the card before it runs */
    pop     es
    popad
    ret

/* k3_commit: write and commit the capture and flush DOS's buffers (out_flush: AH=68h, then
 * AH=0Dh in this binary), unless an IDE bank is switched (fl_hold). Kit 3's first Xe10 run
 * froze with the FAT and directory still in DOS's buffers. */
k3_commit:
    cmp     byte ptr [fl_hold], 0
    jne     1f
    call    out_flush
1:  ret

/* k3_rowmark: a ROW line for the current case, committed, before it runs (every section) */
k3_rowmark:
    pushad
    mov     bx, word ptr [cur_case]
    mov     si, word ptr [bx+CD_TAG]
    mov     ax, 0xFFFF
    call    row_mark
    popad
    ret

/* k3_dest: run the current case's setup template alone and keep ES, EDI, DS, SI. */
k3_dest:
    pushad
    push    ds
    push    es
    push    fs
    push    gs
    push    cs
    pop     es
    mov     bx, word ptr [cur_case]
    mov     si, word ptr [bx+CD_T]
    mov     cx, word ptr [bx+CD_T+2]
    sub     cx, si
    cmp     cx, 200
    jbe     1f
    mov     cx, 0
1:  mov     di, K3_SB
    cld
    rep     movsb
    mov     si, offset k3_trl
    mov     cx, (k3_trl_e - k3_trl)
    rep     movsb
    mov     ax, sp
    sub     ax, 2
    mov     word ptr [k3_sp], ax
    mov     ax, K3_SB
    call    ax
    pop     gs
    pop     fs
    pop     es
    pop     ds
    popad
    ret
k3_trl:                                     /* copied after the setup bytes */
    mov     word ptr cs:[k3_es], es
    mov     dword ptr cs:[k3_edi], edi
    mov     word ptr cs:[k3_ds], ds
    mov     word ptr cs:[k3_si], si
    mov     sp, word ptr cs:[k3_sp]
    ret
k3_trl_e:

/* ------------------------------------------------------------------ shared */
/* k3_rdinit: /RDLAT's prologue (the state rd_exit restores from): CF = 1 without the buffer */
k3_rdinit:
    mov     byte ptr [win_ph], 0
    mov     word ptr [ms_to], 0
    mov     word ptr [tag_sfx], 0
    mov     byte ptr [rd_tsaved], 0
    mov     byte ptr [rd_sw], 0
    mov     byte ptr [m2_pgon], 0
    mov     byte ptr [k3_apon], 0
    mov     byte ptr [k3_cdoff], 0
    mov     word ptr [ks_ptr0], offset rd_ks
    call    gfx_off
    call    gfx_state
    call    ms_bda
    mov     word ptr [ms_bda0], ax
    call    rd_q31
    mov     al, byte ptr [rd_al]
    mov     byte ptr [rd_al0], al
    mov     al, byte ptr [rd_bh]
    mov     byte ptr [rd_bh0], al
    mov     dx, 0x09A8
    in      al, dx
    mov     byte ptr [rd_p9a8], al
    mov     si, offset k_STATE
    call    info_start
    PS      "as_found"
    call    rd_st
    PS      " cr0="
    mov     eax, cr0
    call    out_x8
    PS      " bufparas="
    movzx   eax, word ptr [buf_paras]
    call    out_x4
    call    out_nl
    cmp     word ptr [buf_paras], 0x4000
    jae     1f
    mov     si, offset rs_k3buf
    call    skip_line
    stc
    ret
1:  mov     al, 0
    call    rd_tram
    mov     byte ptr [rd_tsaved], 1
    mov     byte ptr [ms_disp], 1
    clc
    ret

/* k3_gfx24: the 24 kHz 640x400 colour display on, bank 0 (the /MISAL display) */
k3_gfx24:
    mov     ah, 0x42
    mov     ch, 0xC0
    int     0x18
    mov     ah, 0x40
    int     0x18
    ret

/* ------------------------------------------------------------------ /PKAB */
/* k3_sfx_set: AX = group (0 M, 1 R, 2 FA, 3 FV, 4 C, 5 N, 6 D) -> [tag_sfx] for [k3_round] */
k3_sfx_set:
    push    bx
    imul    bx, ax, 3
    add     bx, word ptr [k3_round]
    dec     bx
    shl     bx, 1
    mov     bx, word ptr [k3_sfxt + bx]
    mov     word ptr [tag_sfx], bx
    pop     bx
    ret

k3_frows:
    call    ms_rearm
    call    m2_pegc_on
    mov     si, offset tab_k3_f1
    call    run_list
    mov     cx, 60                      /* 60 frames of nothing */
1:  call    ms_sync
    loop    1b
    mov     si, offset tab_k3_f2
    call    run_list
    jmp     m2_pegc_off

k3_crows:
    call    ms_rearm
    mov     al, 0
    out     0x7C, al
    mov     si, offset tab_k3_cg
    call    run_list
    call    m2_pegc_on
    mov     si, offset tab_k3_cp
    call    run_list
    jmp     m2_pegc_off

k3_cache_off:
    cli
    mov     eax, cr0
    mov     dword ptr [k3_cr0], eax
    or      eax, 0x60000000             /* CD, NW */
    mov     cr0, eax
    wbinvd
    mov     byte ptr [k3_cdoff], 1
    sti
    mov     si, offset k_STATE
    call    info_start
    PS      "cache=off cr0="
    mov     eax, cr0
    call    out_x8
    jmp     out_nl

k3_cache_on:
    cmp     byte ptr [k3_cdoff], 0
    je      1f
    cli
    mov     eax, dword ptr [k3_cr0]
    mov     cr0, eax
    wbinvd
    mov     byte ptr [k3_cdoff], 0
    sti
    mov     eax, cr0
    mov     edx, eax
    mov     eax, dword ptr [k3_cr0]
    mov     si, offset n_cr0
    mov     cx, 0x0008
    mov     bl, 3
    call    rs_line
1:  ret

sec_pkab:
    mov     si, offset nm_pkab
    mov     eax, WD_60S
    mov     bx, offset k3p_exit
    call    sec_begin
    call    k3_rdinit
    jc      k3p_exit
    mov     byte ptr [m2_tsaved], 1     /* the whole TRAM is saved: /MISAL2's text rows may run */
    call    k3_gfx24
    mov     si, offset k_STATE
    call    info_start
    PS      "mode=24 rounds="
    mov     eax, K3_ROUNDS
    call    out_d
    call    ms_state_bda
    call    out_nl
    mov     si, offset tg_ras_g
    call    ms_raster
    mov     byte ptr [k3_rowst], 1
    mov     word ptr [k3_round], 1
    mov     al, byte ptr [m_k3ab]
    or      al, byte ptr [m_k3d]
    or      al, byte ptr [m_k3n]
    sete    byte ptr [k3_pkall]
1:  call    ms_rearm
    mov     si, offset k_STATE
    call    info_start
    PS      "round="
    movzx   eax, word ptr [k3_round]
    call    out_d
    call    out_nl
    mov     byte ptr [win_ph], 1
    /* /AB /DRAIN /L1OFF pick the parts (kit 3's second image runs each as its own step);
     * none of them: every part */
    mov     al, byte ptr [m_k3ab]
    or      al, byte ptr [k3_pkall]
    jz      11f
    /* M: /MISAL2's sequence */
    mov     word ptr [ks_ptr0], offset sweep_ks
    mov     ax, 0
    call    k3_sfx_set
    call    m2_phase
    /* R: /RDLAT's 24 kHz sequence */
    mov     word ptr [ks_ptr0], offset rd_ks
    mov     ax, 1
    call    k3_sfx_set
    call    rd_ph16
    mov     word ptr [ks_ptr0], offset sweep_ks
    /* F: the factor rows, A then V */
    mov     ax, 2
    call    k3_sfx_set
    call    k3_frows
    mov     byte ptr [win_ph], 2
    mov     ax, 3
    call    k3_sfx_set
    call    k3_frows
    mov     byte ptr [win_ph], 1
11: /* C, N, D: the cache as found (the control of both), the cache off, the drain read */
    mov     al, byte ptr [m_k3d]
    or      al, byte ptr [m_k3n]
    or      al, byte ptr [k3_pkall]
    jz      12f
    mov     ax, 4
    call    k3_sfx_set
    call    k3_crows
    mov     al, byte ptr [m_k3n]
    or      al, byte ptr [k3_pkall]
    jz      13f
    call    k3_cache_off
    mov     ax, 5
    call    k3_sfx_set
    call    k3_crows
    call    k3_cache_on
13: mov     al, byte ptr [m_k3d]
    or      al, byte ptr [k3_pkall]
    jz      12f
    mov     byte ptr [k3_drain], 1
    mov     ax, 6
    call    k3_sfx_set
    call    k3_crows
    mov     byte ptr [k3_drain], 0
12: inc     word ptr [k3_round]
    cmp     word ptr [k3_round], K3_ROUNDS
    jbe     1b
k3p_exit:
    call    sec_disarm
    mov     byte ptr [k3_rowst], 0
    mov     byte ptr [k3_drain], 0
    call    k3_cache_on
    mov     byte ptr [m2_tsaved], 0
    jmp     rd_exit

/* ------------------------------------------------------------------ /CELLS */
k3_run:                                     /* SI = table */
    call    ms_rearm
    jmp     run_list

k3_ph31:
    cmp     byte ptr [m_k3ap], 0         /* /APER: the aperture rows only */
    jne     k3_ret
    mov     al, 0x80
    call    grcg_set
    mov     si, offset tab_c_31
    call    k3_run
    mov     al, 0xC0
    call    grcg_set
    mov     si, offset tab_c_31r
    call    k3_run
    mov     al, 0
    out     0x7C, al
    mov     si, offset tab_c_31p
    call    k3_run
    mov     si, offset tab_c_tx2
    jmp     k3_run

k3_ph2p:
    cmp     byte ptr [m_k3ap], 0         /* /APER: the aperture rows only */
    jne     k3_ret
    mov     si, offset tab_c_tx1
    call    k3_run
    mov     si, offset tab_c_tx2
    call    k3_run
    mov     si, offset tab_rd_pk
    call    k3_run
    mov     si, offset tab_c_b8
    jmp     k3_run

k3_ph3p:
    cmp     byte ptr [m_k3ap], 0         /* /APER: the aperture rows only */
    jne     k3_ret
    mov     si, offset tab_c_tx1s
    call    k3_run
    mov     si, offset tab_c_tx2
    call    k3_run
    mov     si, offset tab_rd_pk
    call    k3_run
    mov     si, offset tab_c_b8s
    jmp     k3_run

k3_ph48:
    cmp     byte ptr [m_k3ap], 0         /* /APER: the aperture rows only */
    jne     k3_ret
    mov     si, offset tab_c_tx2
    call    k3_run
    mov     si, offset tab_c_b8
    jmp     k3_run

k3_ret:
    ret

k3_phap:
    mov     si, offset tab_c_ap
    jmp     k3_run

/* k3_b8probe: what 0xB8000 is with the 256-colour mode on: a word written with it off (plane
 * G), read with it on; a word written with it on, read with it off; the plane word put back. */
k3_b8probe:
    push    es
    mov     ax, 0xB800
    mov     es, ax
    mov     ax, word ptr es:[0]
    mov     word ptr [k3_w0], ax
    mov     word ptr es:[0], 0xA55A
    mov     ax, word ptr es:[0]
    mov     word ptr [k3_w1], ax
    call    m2_pegc_on
    mov     ax, word ptr es:[0]
    mov     word ptr [k3_w2], ax
    mov     word ptr es:[0], 0x3CC3
    mov     ax, word ptr es:[0]
    mov     word ptr [k3_w3], ax
    call    m2_pegc_off
    mov     ax, word ptr es:[0]
    mov     word ptr [k3_w4], ax
    mov     ax, word ptr [k3_w0]
    mov     word ptr es:[0], ax
    pop     es
    mov     si, offset k_X
    call    row_start
    PS      "B8 off_wr=A55A off_rb="
    mov     ax, word ptr [k3_w1]
    call    out_x4
    PS      " on_rb="
    mov     ax, word ptr [k3_w2]
    call    out_x4
    PS      " on_wr=3CC3 on_rb2="
    mov     ax, word ptr [k3_w3]
    call    out_x4
    PS      " off_rb2="
    mov     ax, word ptr [k3_w4]
    call    out_x4
    jmp     out_nl

/* k3_unreal: FS with a 4 GiB limit, back in real mode (risky.s unreal_fs) */
k3_unreal:
    xor     eax, eax
    mov     ax, cs
    shl     eax, 4
    add     eax, offset k3_gdt
    mov     dword ptr [k3_gdtr+2], eax
    pushf
    cli
    .byte 0x66
    lgdt    [k3_gdtr]
    mov     eax, cr0
    or      al, 1
    mov     cr0, eax
    jmp     1f
1:  mov     bx, 8
    mov     fs, bx
    and     al, 0xFE
    mov     cr0, eax
    jmp     2f
2:  xor     ax, ax
    mov     fs, ax
    popf
    ret

/* k3_a20: CF = 1 when A20 is masked (the dword 1 MiB above k3_a20v follows it); FS unreal */
k3_a20:
    push    eax
    push    ebx
    xor     ebx, ebx
    mov     bx, cs
    shl     ebx, 4
    add     ebx, offset k3_a20v
    mov     dword ptr [k3_a20v], 0x5AA5C33C
    mov     eax, dword ptr fs:[ebx + 0x100000]
    cmp     eax, 0x5AA5C33C
    jne     1f
    not     dword ptr [k3_a20v]
    mov     eax, dword ptr fs:[ebx + 0x100000]
    cmp     eax, dword ptr [k3_a20v]
    jne     1f
    stc
    jmp     2f
1:  clc
2:  pop     ebx
    pop     eax
    ret

/* k3_aper_on: 0x043B bit 2, A20, E0102 <- 01, the X APER proof. Needs the 256-colour mode. */
k3_aper_on:
    cmp     byte ptr [k3_apon], 0
    jne     9f
    call    k3_unreal
    call    k3_a20
    setc    byte ptr [k3_a20m]
    mov     dx, 0x043B
    in      al, dx
    mov     byte ptr [k3_43b], al
    mov     byte ptr [k3_apon], 1
    /* 0x043B is left as found: bit 2 SET puts plain RAM at 0xF00000-0xFFFFFF on the Xe10
     * (docs/probes/KIT2-XE10-RISKY-43B.TXT:7, FF), so kit 3's second image, which set it, timed
     * main memory there (docs/probes/XE10Y-XE10-APER.TXT: PAR 65 ns, 30 ns net); the as-found
     * FB is the 15-16 MiB system space the aperture lives in */
    cmp     byte ptr [k3_a20m], 0
    je      1f
    mov     al, 0x02                    /* A20 open */
    out     0xF6, al
1:  push    es
    mov     ax, 0xE000
    mov     es, ax
    mov     al, byte ptr es:[0x0102]
    mov     byte ptr [k3_e0102], al
    mov     byte ptr es:[0x0102], 0x01
    mov     ax, 0xA800
    mov     es, ax
    mov     word ptr es:[0], 0x1357
    mov     eax, 0x00F00000
    mov     bx, word ptr fs:[eax]
    mov     word ptr [k3_w1], bx
    wbinvd                              /* the same read with the L1 emptied first */
    mov     bx, word ptr fs:[eax]
    mov     word ptr [k3_w3], bx
    mov     word ptr fs:[eax + 2], 0x2468
    mov     bx, word ptr es:[2]
    mov     word ptr [k3_w2], bx
    wbinvd
    mov     bx, word ptr es:[2]
    mov     word ptr [k3_w4], bx
    mov     bx, word ptr fs:[eax + 2]
    mov     word ptr [k3_w0], bx
    pop     es
    mov     si, offset k_X
    call    row_start
    PS      "APER 43b="
    mov     al, byte ptr [k3_43b]
    call    out_x2
    PS      " 43b_now="
    mov     dx, 0x043B
    in      al, dx
    call    out_x2
    PS      " a20_masked="
    movzx   eax, byte ptr [k3_a20m]
    call    out_d
    PS      " e0102_was="
    mov     al, byte ptr [k3_e0102]
    call    out_x2
    PS      " a8_wr=1357 f0_rb="
    mov     ax, word ptr [k3_w1]
    call    out_x4
    PS      " f0_rbw="
    mov     ax, word ptr [k3_w3]
    call    out_x4
    PS      " f0_wr=2468 a8_rb="
    mov     ax, word ptr [k3_w2]
    call    out_x4
    PS      " a8_rbw="
    mov     ax, word ptr [k3_w4]
    call    out_x4
    PS      " f0_rb2="
    mov     ax, word ptr [k3_w0]
    call    out_x4
    call    out_nl
9:  ret

k3_aper_off:
    cmp     byte ptr [k3_apon], 0
    je      9f
    mov     byte ptr [k3_apon], 0
    push    es
    mov     ax, 0xE000
    mov     es, ax
    mov     byte ptr es:[0x0102], 0x00
    pop     es
    mov     si, offset n_e0102
    xor     eax, eax
    call    rs_default
    mov     dx, 0x043B
    mov     al, byte ptr [k3_43b]
    mov     si, offset n_43b
    call    rs_port8                    /* never written: the read-back proves it */
    cmp     byte ptr [k3_a20m], 0
    je      1f
    mov     al, 0x03                    /* A20 masked again */
    out     0xF6, al
1:  call    k3_a20
    setc    dl
    movzx   edx, dl
    movzx   eax, byte ptr [k3_a20m]
    mov     si, offset n_a20
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
9:  ret

/* k3_mode256: the 256-colour mode on, STATE and raster: SI = mode name, DI = raster tag */
k3_mode256:
    push    di
    push    si
    call    m2_pegc_on
    mov     al, byte ptr [q_save+0]
    mov     byte ptr [m2_q04], al
    mov     si, offset k_STATE
    call    info_start
    PS      "mode="
    pop     si
    call    out_s
    PS      " pegc=256 packed"
    call    rd_st
    call    out_nl
    pop     si
    jmp     ms_raster

sec_cells:
    mov     si, offset nm_cells
    mov     eax, WD_60S
    mov     bx, offset k3c_exit
    call    sec_begin
    call    k3_rdinit
    jc      k3c_exit
    /* 2P: 24 kHz, 640x400, the 256-colour mode on */
    call    k3_gfx24
    call    k3_b8probe
    mov     si, offset md_2p
    mov     di, offset tg_r2p
    call    k3_mode256
    mov     ax, offset sfx_2pa
    mov     bx, offset sfx_2pv
    mov     dx, offset k3_ph2p
    call    rd_av
    cmp     byte ptr [m_k3noap], 0      /* /NOAPER: no aperture rows */
    jne     21f
    call    ms_rearm
    call    k3_aper_on
    mov     ax, offset sfx_2pa
    mov     bx, offset sfx_2pv
    mov     dx, offset k3_phap
    call    rd_av
    call    k3_aper_off
21:
    call    m2_pegc_off
    /* 31 kHz: the 31 and 48 modes need AH=30h/31h */
    cmp     word ptr [rd_al], 0xFFFF
    jne     1f
    mov     si, offset rs_nobios
    call    skip_line
    jmp     k3c_exit
1:  mov     al, 0x0C
    mov     bh, byte ptr [rd_bh0]
    and     bh, 0x01
    or      bh, 0x20
    mov     si, offset md_31
    call    rd_set
    jnc     2f
    mov     si, offset rs_m31
    call    skip_line
    jmp     3f
2:  call    k3_gfx24
    mov     si, offset tg_r31
    call    ms_raster
    mov     ax, offset sfx_31a
    mov     bx, offset sfx_31v
    mov     dx, offset k3_ph31
    call    rd_av
    /* 3P: the same display with the 256-colour mode on */
    mov     si, offset md_3p
    mov     di, offset tg_r3p
    call    k3_mode256
    mov     ax, offset sfx_3pa
    mov     bx, offset sfx_3pv
    mov     dx, offset k3_ph3p
    call    rd_av
    call    m2_pegc_off
3:  mov     al, 0x0C
    mov     bh, 0x31
    mov     si, offset md_48
    call    rd_set
    jnc     4f
    mov     si, offset rs_m48
    call    skip_line
    jmp     k3c_exit
4:  mov     ah, 0x40
    int     0x18
    mov     si, offset md_48
    mov     di, offset tg_r48
    call    k3_mode256
    mov     ax, offset sfx_48a
    mov     bx, offset sfx_48v
    mov     dx, offset k3_ph48
    call    rd_av
    cmp     byte ptr [m_k3noap], 0
    jne     k3c_exit
    call    ms_rearm
    call    k3_aper_on
    mov     ax, offset sfx_48a
    mov     bx, offset sfx_48v
    mov     dx, offset k3_phap
    call    rd_av
k3c_exit:
    call    sec_disarm
    call    k3_aper_off
    jmp     rd_exit

/* ------------------------------------------------------------------ /K3M */
/* the ATA helpers (sec_storage.inc's, which XE10U and later leave out) */
k3_bank:                                    /* AL -> 0x432 */
    push    dx
    mov     dx, 0x0432
    out     dx, al
    mov     cx, 10
1:  out     0x5F, al
    loop    1b
    pop     dx
    ret

/* k3_bsy: wait BSY clear, at most EAX ticks; AL = status; CF = timeout */
k3_bsy:
    push    cx
    push    dx
    call    dl_start
    mov     dx, 0x064E
1:  mov     cx, 32
2:  in      al, dx
    test    al, 0x80
    jz      3f
    loop    2b
    call    dl_check
    jnc     1b
    stc
    jmp     4f
3:  clc
4:  pop     dx
    pop     cx
    ret

/* k3_tfload: SC=5A SN=A5 CL=3C CH=C3 */
k3_tfload:
    mov     dx, 0x0644
    mov     al, 0x5A
    out     dx, al
    mov     dx, 0x0646
    mov     al, 0xA5
    out     dx, al
    mov     dx, 0x0648
    mov     al, 0x3C
    out     dx, al
    mov     dx, 0x064A
    mov     al, 0xC3
    out     dx, al
    ret

/* k3_tfread: DI -> 8 bytes: 0x642 0x644 0x646 0x648 0x64A 0x64C 0x74C(alt) 0x0433; then the
 * status 0x64E last (it clears INTRQ) as byte 8 */
k3_tfread:
    push    ax
    push    dx
    mov     dx, 0x074C
    in      al, dx
    mov     byte ptr [di+6], al
    mov     dx, 0x0433
    in      al, dx
    mov     byte ptr [di+7], al
    mov     dx, 0x0642
1:  in      al, dx
    mov     bx, dx
    sub     bx, 0x0642
    shr     bx, 1
    mov     byte ptr [di+bx], al
    add     dx, 2
    cmp     dx, 0x064C
    jbe     1b
    mov     dx, 0x064E
    in      al, dx
    mov     byte ptr [di+8], al
    pop     dx
    pop     ax
    ret

/* k3_tfout: SI = name, DI = 9 bytes -> " <name>=er.sc.sn.cl.ch.dh.alt.433.st" */
k3_tfout:
    call    out_sp
    call    out_s
    mov     al, '='
    call    out_c
    xor     bx, bx
1:  mov     al, byte ptr [di+bx]
    call    out_x2
    inc     bx
    cmp     bx, 9
    jae     2f
    mov     al, '.'
    call    out_c
    jmp     1b
2:  ret

k3_ide:
    in      al, 0x0A
    mov     byte ptr [k3_imr], al
    mov     dx, 0x0432
    in      al, dx
    mov     byte ptr [k3_bank0], al
    mov     si, offset tg_k3ide
    mov     ax, 0x0432
    call    row_mark                    /* flushed with the as-found bank */
    mov     byte ptr [fl_hold], 1
    mov     byte ptr [k3_ib], 0         /* bank 0 first: the Xe10's CF card and the core's disk */
1:  mov     al, byte ptr [k3_ib]
    call    k3_bank
    mov     dx, 0x064C
    mov     al, 0xA0
    out     dx, al
    mov     cx, 20
2:  out     0x5F, al
    loop    2b
    mov     dx, 0x064E
    in      al, dx
    mov     byte ptr [k3_ist], al
    mov     dx, 0x0648
    in      al, dx
    mov     ah, al
    mov     dx, 0x064A
    in      al, dx
    mov     word ptr [k3_isig], ax
    mov     si, offset k_X
    call    row_start
    PS      "IDESCAN bank="
    mov     al, byte ptr [k3_ib]
    call    out_x2
    PS      " st="
    mov     al, byte ptr [k3_ist]
    call    out_x2
    PS      " sig="
    mov     ax, word ptr [k3_isig]
    call    out_x4
    call    out_nl
    mov     al, byte ptr [k3_ist]
    cmp     al, 0xFF
    je      3f
    test    al, 0x40
    jz      3f
    test    al, 0x80
    jnz     3f
    cmp     word ptr [k3_isig], 0x14EB
    je      3f
    call    k3_ident
    jnc     5f                          /* an ATA device answered: done */
3:  cmp     byte ptr [k3_ib], 1
    je      4f
    mov     byte ptr [k3_ib], 1
    jmp     1b
4:  mov     si, offset rs_k3noata
    call    skip_line
5:  mov     al, byte ptr [k3_bank0]
    call    k3_bank
    mov     byte ptr [fl_hold], 0
    mov     dx, 0x0432
    mov     al, byte ptr [k3_bank0]
    mov     si, offset n_k3bank
    call    rs_port8
    mov     dx, 0x0A
    mov     al, byte ptr [k3_imr]
    mov     si, offset n_imrs
    jmp     rs_port8

/* k3_ident: IDENTIFY DEVICE then IDENTIFY PACKET DEVICE on the selected ATA device */
k3_ident:
    mov     byte ptr [k3_icmd], 0xEC
    mov     byte ptr [k3_iphase], 0
1:  cli
    mov     al, byte ptr [k3_imr]
    or      al, 0x02
    out     0x0A, al
    mov     eax, T_500MS
    call    k3_bsy
    call    k3_tfload
    mov     di, offset k3_tf0
    call    k3_tfread
    call    k3_tfload
    mov     dx, 0x064E
    mov     al, byte ptr [k3_icmd]
    out     dx, al
    mov     cx, 10
2:  out     0x5F, al
    loop    2b
    /* wait BSY clear (DRQ or ERR then) */
    mov     eax, T_1S
    call    k3_bsy
    setc    byte ptr [k3_ito]
    mov     di, offset k3_tf1
    call    k3_tfread
    mov     dword ptr [k3_icrc], 0
    mov     word ptr [k3_iwn], 0
    test    byte ptr [k3_tf1+8], 0x08
    jz      4f
    /* the block: CRC-16 of the 256 words, words 0 1 3 6 47 49 59 kept */
    mov     dx, 0x0640
    xor     bx, bx
    mov     word ptr [k3_icrc], 0xFFFF
3:  in      ax, dx
    mov     word ptr [SECBUF + bx], ax
    add     bx, 2
    cmp     bx, 512
    jb      3b
    push    si
    mov     si, SECBUF
    mov     cx, 512
    mov     ax, 0xFFFF
31: push    bx
    mov     bl, byte ptr [si]
    call    crc16_step_bl
    pop     bx
    inc     si
    loop    31b
    mov     word ptr [k3_icrc], ax
    pop     si
    mov     word ptr [k3_iwn], 256
4:  mov     eax, T_500MS
    call    k3_bsy
    mov     di, offset k3_tf2
    call    k3_tfread
    mov     al, byte ptr [k3_imr]
    out     0x0A, al
    sti
    mov     si, offset k_X
    call    row_start
    PS      "IDENT cmd="
    mov     al, byte ptr [k3_icmd]
    call    out_x2
    PS      " bank="
    mov     al, byte ptr [k3_ib]
    call    out_x2
    PS      " fmt=er.sc.sn.cl.ch.dh.alt.433.st"
    mov     si, offset n_tf0
    mov     di, offset k3_tf0
    call    k3_tfout
    mov     si, offset n_tf1
    mov     di, offset k3_tf1
    call    k3_tfout
    mov     si, offset n_tf2
    mov     di, offset k3_tf2
    call    k3_tfout
    PS      " to="
    movzx   eax, byte ptr [k3_ito]
    call    out_d
    PS      " words="
    movzx   eax, word ptr [k3_iwn]
    call    out_d
    PS      " crc="
    mov     ax, word ptr [k3_icrc]
    call    out_x4
    cmp     word ptr [k3_iwn], 0
    je      6f
    PS      " w0="
    mov     ax, word ptr [SECBUF + 0]
    call    out_x4
    PS      " w1="
    mov     ax, word ptr [SECBUF + 2]
    call    out_x4
    PS      " w3="
    mov     ax, word ptr [SECBUF + 6]
    call    out_x4
    PS      " w6="
    mov     ax, word ptr [SECBUF + 12]
    call    out_x4
    PS      " w47="
    mov     ax, word ptr [SECBUF + 94]
    call    out_x4
    PS      " w49="
    mov     ax, word ptr [SECBUF + 98]
    call    out_x4
    PS      " w59="
    mov     ax, word ptr [SECBUF + 118]
    call    out_x4
    PS      " w53="                     /* bit 0: words 54-58 (the current geometry) valid */
    mov     ax, word ptr [SECBUF + 106]
    call    out_x4
    PS      " w54="
    mov     ax, word ptr [SECBUF + 108]
    call    out_x4
    PS      " w55="
    mov     ax, word ptr [SECBUF + 110]
    call    out_x4
    PS      " w56="
    mov     ax, word ptr [SECBUF + 112]
    call    out_x4
6:  call    out_nl
    cmp     byte ptr [k3_iphase], 0
    jne     9f
    cmp     word ptr [k3_iwn], 0        /* IDENTIFY DEVICE gave no block: not an ATA disk, */
    je      8f                          /* so no IDENTIFY PACKET (no ATAPI device is addressed) */
    test    byte ptr [SECBUF + 1], 0x80 /* word 0 bit 15: 0 = ATA */
    jnz     8f
    mov     ax, word ptr [SECBUF + 110] /* the geometry the BIOS set, to put back below */
    mov     word ptr [k3_ihd], ax
    mov     ax, word ptr [SECBUF + 112]
    mov     word ptr [k3_ispt], ax
    inc     byte ptr [k3_iphase]
    mov     byte ptr [k3_icmd], 0xA1
    jmp     1b
9:  cmp     byte ptr [k3_iphase], 1
    jne     7f
    /* IDENTIFY PACKET resets the Xe10's CF card to its default translation (SC/SN 01/01, the
     * reset signature; the next BIOS write landed at CHS translated with 16 heads x 63 sectors,
     * docs/probes/XE10Y-XE10-K3M2.TXT and the README row): INITIALIZE DEVICE PARAMETERS puts
     * the BIOS's geometry back, and a second IDENTIFY DEVICE proves words 54-56 */
    call    k3_reinit
    inc     byte ptr [k3_iphase]
    mov     byte ptr [k3_icmd], 0xEC
    jmp     1b
7:  clc
    ret
8:  stc
    ret

/* k3_reinit: INITIALIZE DEVICE PARAMETERS (0x91) with [k3_ihd] heads, [k3_ispt] sectors */
k3_reinit:
    mov     ax, word ptr [k3_ihd]
    test    ax, ax
    jz      5f
    cmp     ax, 16
    ja      5f
    cmp     word ptr [k3_ispt], 0
    je      5f
    cmp     word ptr [k3_ispt], 255
    ja      5f
    cli
    mov     al, byte ptr [k3_imr]
    or      al, 0x02
    out     0x0A, al
    mov     eax, T_500MS
    call    k3_bsy
    mov     dx, 0x0644
    mov     al, byte ptr [k3_ispt]
    out     dx, al
    mov     dx, 0x064C
    mov     al, byte ptr [k3_ihd]
    dec     al
    and     al, 0x0F
    or      al, 0xA0
    out     dx, al
    mov     cx, 10
1:  out     0x5F, al
    loop    1b
    mov     dx, 0x064E
    mov     al, 0x91
    out     dx, al
    mov     cx, 10
2:  out     0x5F, al
    loop    2b
    mov     eax, T_1S
    call    k3_bsy
    setc    byte ptr [k3_ito]
    mov     di, offset k3_tf1
    call    k3_tfread
    mov     dx, 0x064C                  /* the device/head byte back to master, head 0 */
    mov     al, 0xA0
    out     dx, al
    mov     al, byte ptr [k3_imr]
    out     0x0A, al
    sti
    mov     si, offset k_X
    call    row_start
    PS      "IDEINIT cmd=91 heads="
    movzx   eax, word ptr [k3_ihd]
    call    out_d
    PS      " spt="
    movzx   eax, word ptr [k3_ispt]
    call    out_d
    mov     si, offset n_tf1
    mov     di, offset k3_tf1
    call    k3_tfout
    PS      " to="
    movzx   eax, byte ptr [k3_ito]
    call    out_d
    jmp     out_nl
5:  mov     si, offset k_X
    call    row_start
    PS      "IDEINIT skipped=geometry"
    jmp     out_nl

/* IDIV: AX = B0F8h / BL = 1Eh */
k3_isr0:
    push    bp
    mov     bp, sp
    add     word ptr [bp+2], 2          /* past the 2-byte idiv */
    mov     byte ptr cs:[k3_de], 1
    pop     bp
    iret

k3_idiv:
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    mov     eax, dword ptr es:[0]
    mov     dword ptr [k3_v0], eax
    mov     word ptr es:[0], offset k3_isr0
    mov     word ptr es:[2], cs
    mov     byte ptr [k3_de], 0
    mov     ax, 0xB0F8
    mov     bl, 0x1E
    idiv    bl
    mov     word ptr [k3_w1], ax
    pushf
    pop     word ptr [k3_w2]
    mov     eax, dword ptr [k3_v0]
    mov     dword ptr es:[0], eax
    mov     edx, dword ptr es:[0]
    sti
    pop     es
    mov     si, offset k_X
    call    row_start
    PS      "IDIV ax_in=B0F8 bl=1E de="
    movzx   eax, byte ptr [k3_de]
    call    out_d
    PS      " ax="
    mov     ax, word ptr [k3_w1]
    call    out_x4
    PS      " flags="
    mov     ax, word ptr [k3_w2]
    call    out_x4
    call    out_nl
    mov     eax, dword ptr [k3_v0]
    mov     si, offset n_vec00
    mov     cx, 0x0208
    mov     bl, 3
    jmp     rs_line

/* E0000: the dword in the as-found mode, then in the 16-colour mode written and put back */
k3_e0000:
    mov     al, 0x04
    call    query9a0
    mov     byte ptr [k3_q04], al
    push    es
    mov     ax, 0xE000
    mov     es, ax
    mov     eax, dword ptr es:[0]
    mov     dword ptr [k3_v0], eax
    cli
    mov     al, 0x01
    out     0x6A, al
    mov     eax, dword ptr es:[0]
    mov     dword ptr [k3_v1], eax
    mov     dword ptr es:[0], 0xAA55FF00
    mov     eax, dword ptr es:[0]
    mov     dword ptr [k3_v2], eax
    mov     eax, dword ptr [k3_v1]
    mov     dword ptr es:[0], eax
    mov     eax, dword ptr es:[0]
    mov     dword ptr [k3_v3], eax
    mov     al, byte ptr [k3_q04]
    and     al, 1
    out     0x6A, al
    sti
    mov     eax, dword ptr es:[0]
    mov     dword ptr [k3_v4], eax
    pop     es
    mov     si, offset k_X
    call    row_start
    PS      "E0000 q04="
    mov     al, byte ptr [k3_q04]
    call    out_x2
    PS      " asfound="
    mov     eax, dword ptr [k3_v0]
    call    out_x8
    PS      " m16="
    mov     eax, dword ptr [k3_v1]
    call    out_x8
    PS      " m16_wr=AA55FF00 m16_rb="
    mov     eax, dword ptr [k3_v2]
    call    out_x8
    PS      " m16_put="
    mov     eax, dword ptr [k3_v3]
    call    out_x8
    PS      " back="
    mov     eax, dword ptr [k3_v4]
    call    out_x8
    call    out_nl
    mov     eax, dword ptr [k3_v1]
    mov     edx, dword ptr [k3_v3]
    mov     si, offset n_e0000
    mov     cx, 0x0208
    mov     bl, 3
    call    rs_line
    mov     al, 0x04
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [k3_q04]
    mov     si, offset n_q04
    mov     cx, 0x0002
    mov     bl, 3
    jmp     rs_line

/* PIT: one-byte count writes on channel 0 */
/* k3_pitw: AX = count (mode 0, LSB then MSB), then when CL != 0 the control CL (0x10 LSB only,
 * 0x20 MSB only) and the byte CH -> [k3_tout] ARTIC ticks to the read-back status's OUT bit,
 * [k3_tirr] to the master IRR bit 0 (FFFF: not seen in 10 ms), [k3_st0] the first status
 * byte, [k3_irr0] IRR bit 0 at the start. Under cli. */
k3_pitw:
    call    pit0_mode0
    test    cl, cl
    jz      11f
    mov     al, cl
    out     0x77, al
    mov     al, ch
    out     0x71, al
11: mov     al, 0x0A                    /* OCW3: read the IRR */
    out     0x00, al
    in      al, 0x00
    and     al, 1
    mov     byte ptr [k3_irr0], al
    mov     al, 0xE2                    /* read-back: the status of channel 0 */
    out     0x77, al
    in      al, 0x71
    mov     byte ptr [k3_st0], al
    call    artic_read
    mov     esi, eax
    mov     word ptr [k3_tout], 0xFFFF
    mov     word ptr [k3_tirr], 0xFFFF
1:  mov     al, 0xE2
    out     0x77, al
    in      al, 0x71
    mov     bl, al
    in      al, 0x00
    mov     bh, al
    call    artic_read
    sub     eax, esi
    and     eax, 0x00FFFFFF
    cmp     word ptr [k3_tout], 0xFFFF
    jne     2f
    test    bl, 0x80
    jz      2f
    mov     word ptr [k3_tout], ax
2:  cmp     word ptr [k3_tirr], 0xFFFF
    jne     3f
    test    bh, 0x01
    jz      3f
    mov     word ptr [k3_tirr], ax
3:  cmp     word ptr [k3_tout], 0xFFFF
    je      4f
    cmp     word ptr [k3_tirr], 0xFFFF
    jne     5f
4:  cmp     eax, T_10MS
    jb      1b
5:  ret

/* k3_pitrow: SI = case name, the row of the last k3_pitw */
k3_pitrow:
    push    si
    mov     si, offset k_X
    call    row_start
    PS      "PIT case="
    pop     si
    call    out_s
    PS      " st0="
    mov     al, byte ptr [k3_st0]
    call    out_x2
    PS      " irr0="
    movzx   eax, byte ptr [k3_irr0]
    call    out_d
    PS      " out_art="
    movzx   eax, word ptr [k3_tout]
    call    out_d
    PS      " irr_art="
    movzx   eax, word ptr [k3_tirr]
    call    out_d
    jmp     out_nl

/* k3_pit1: SI = case name, AX/CX as k3_pitw */
k3_pit1:
    push    si
    cli
    call    k3_pitw
    sti
    pop     si
    jmp     k3_pitrow

k3_pit:
    test    byte ptr [imr_m_save], 1
    jnz     1f
    mov     si, offset rs_k3irq0
    jmp     skip_line
1:  mov     si, offset tg_k3pit
    mov     ax, 0x0071
    call    row_mark
    cli                                 /* the as-found mode (the Xe10 answers the read-back: */
    mov     al, 0xE2                    /* docs/probes/XE10Y-XE10-K3M.TXT st0=30/10/20) */
    out     0x77, al
    in      al, 0x71
    sti
    mov     byte ptr [k3_pst0], al
    mov     si, offset k3_pn0           /* the controls: plain counts */
    mov     ax, 0x0056
    xor     cx, cx
    call    k3_pit1
    mov     si, offset k3_pn1
    mov     ax, 0x1256
    xor     cx, cx
    call    k3_pit1
    mov     si, offset k3_pn2           /* LSB only after 1234h: 1256h kept, 0056h zeroed */
    mov     ax, 0x1234
    mov     cx, 0x5610
    call    k3_pit1
    mov     si, offset k3_pn3
    mov     ax, 0x0100
    xor     cx, cx
    call    k3_pit1
    mov     si, offset k3_pn4
    mov     ax, 0x01F0
    xor     cx, cx
    call    k3_pit1
    mov     si, offset k3_pn5           /* MSB only after 12F0h: 01F0h kept, 0100h zeroed */
    mov     ax, 0x12F0
    mov     cx, 0x0120
    call    k3_pit1
    /* channel 0 back to its as-found mode with CAL's modulus (kit 3's first run left it in
     * mode 0 where the BIOS had mode 3, CAL's PITEDGE vmin=2 vmax=65534, and the next program
     * froze before its first line: docs/probes/XE10Y-XE10-K3M.TXT); a read-back that is not a
     * channel-0 LSB+MSB status falls back to mode 3 */
    mov     al, byte ptr [k3_pst0]
    mov     ah, al
    and     ah, 0x30
    cmp     ah, 0x30
    je      2f
    mov     al, 0x36
2:  and     al, 0x0E
    or      al, 0x30
    mov     byte ptr [k3_pctl], al
    cli
    out     0x77, al
    mov     eax, dword ptr [pit_mod]
    out     0x71, al
    mov     al, ah
    out     0x71, al
    mov     al, 0x0B                    /* OCW3: the master's read register back to the ISR, */
    out     0x00, al                    /* the state IRQWD and /OPNA2 leave (0x08 selects nothing) */
    mov     al, 0xE2
    out     0x77, al
    in      al, 0x71
    sti
    and     al, 0x3E
    movzx   edx, al
    movzx   eax, byte ptr [k3_pst0]
    and     al, 0x3E
    mov     si, offset n_k3pmode
    mov     cx, 0x0002
    mov     bl, 3
    jmp     rs_line

/* HBL: GDC status runs from the VSYNC rise. DX = port. */
k3_hbl:
    push    dx
    cli
    mov     ecx, MS_SPIN
1:  in      al, dx                      /* VSYNC low, then the rise */
    test    al, 0x20
    jz      2f
    dec     ecx
    jnz     1b
2:  mov     ecx, MS_SPIN
3:  in      al, dx
    test    al, 0x20
    jnz     4f
    dec     ecx
    jnz     3b
4:  call    artic_read
    mov     esi, eax
    mov     di, SECBUF
    mov     cx, 2048
5:  in      al, dx
    mov     byte ptr [di], al
    inc     di
    loop    5b
    call    artic_read
    sub     eax, esi
    and     eax, 0x00FFFFFF
    mov     dword ptr [k3_v0], eax
    sti
    pop     dx
    /* runs of (bit 5, bit 6) */
    mov     si, offset k_X
    call    row_start
    PS      "HBL port="
    mov     ax, dx
    call    out_x4
    PS      " polls=2048 art="
    mov     eax, dword ptr [k3_v0]
    call    out_d
    PS      " runs="
    mov     si, SECBUF
    mov     al, byte ptr [si]
    and     al, 0x60
    mov     bl, al
    xor     cx, cx                      /* run length */
    xor     bp, bp                      /* runs printed */
    mov     di, 2048
6:  mov     al, byte ptr [si]
    and     al, 0x60
    cmp     al, bl
    je      7f
    call    k3_run_out
    mov     bl, al
    xor     cx, cx
7:  inc     cx
    inc     si
    dec     di
    jnz     6b
    call    k3_run_out
    jmp     out_nl
/* k3_run_out: BL = state (bit 5 V, bit 6 H) and CX = length -> "<s><len>," s = 0..3 */
k3_run_out:
    push    ax
    mov     al, bl
    shr     al, 5
    add     al, '0'
    call    out_c
    movzx   eax, cx
    call    out_d
    mov     al, ','
    call    out_c
    pop     ax
    ret

sec_k3m:
    mov     si, offset nm_k3m
    mov     eax, WD_20S
    mov     bx, offset k3m_exit
    call    sec_begin
    call    k3_idiv
    call    k3_e0000
    call    k3_pit
    call    ms_rearm
    mov     dx, 0x60
    call    k3_hbl
    mov     dx, 0xA0
    call    k3_hbl
    cmp     byte ptr [m_k3ata], 0       /* /ATA only: IDENTIFY resets the Xe10's CF card */
    je      k3m_exit
    call    ms_rearm
    call    k3_ide
k3m_exit:
    call    sec_disarm
    mov     byte ptr [fl_hold], 0
    call    sec_end
    ret

k3_pn0:     .asciz "C0056"
k3_pn1:     .asciz "C1256"
k3_pn2:     .asciz "L1234_56"
k3_pn3:     .asciz "C0100"
k3_pn4:     .asciz "C01F0"
k3_pn5:     .asciz "M12F0_01"
n_tf0:      .asciz "tf0"
n_tf1:      .asciz "tf1"
n_tf2:      .asciz "tf2"

    VARS
    .p2align 2
k3_pgt:     .long 0
k3_edi:     .long 0
k3_cr0:     .long 0
k3_v0:      .long 0
k3_v1:      .long 0
k3_v2:      .long 0
k3_v3:      .long 0
k3_v4:      .long 0
k3_a20v:    .long 0
k3_icrc:    .long 0
k3_gdtr:    .word 15
            .long 0
    .p2align 3
k3_gdt:     .quad 0
            .quad 0x00CF92000000FFFF
k3_es:      .word 0
k3_ds:      .word 0
k3_si:      .word 0
k3_sp:      .word 0
k3_round:   .word 0
k3_w0:      .word 0
k3_w1:      .word 0
k3_w2:      .word 0
k3_w3:      .word 0
k3_w4:      .word 0
k3_isig:    .word 0
k3_ihd:     .word 0
k3_ispt:    .word 0
k3_iwn:     .word 0
k3_tout:    .word 0
k3_tirr:    .word 0
k3_rowst:   .byte 0
k3_drain:   .byte 0
k3_cdoff:   .byte 0
k3_apon:    .byte 0
k3_a20m:    .byte 0
k3_43b:     .byte 0
k3_e0102:   .byte 0
k3_q04:     .byte 0
k3_imr:     .byte 0
k3_bank0:   .byte 0
k3_ib:      .byte 0
k3_ist:     .byte 0
k3_icmd:    .byte 0
k3_ito:     .byte 0
k3_de:      .byte 0
k3_st0:     .byte 0
k3_irr0:    .byte 0
k3_pst0:    .byte 0
k3_pkall:   .byte 0
m_k3ata:    .byte 0
k3_iphase:  .byte 0
m_k3ab:     .byte 0
m_k3d:      .byte 0
m_k3n:      .byte 0
m_k3ap:     .byte 0
m_k3noap:   .byte 0
k3_pctl:    .byte 0
k3_part:    .byte 0
k3_tf0:     .space 9
k3_tf1:     .space 9
k3_tf2:     .space 9
    ENDVARS
