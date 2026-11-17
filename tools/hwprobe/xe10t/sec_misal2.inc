/* sec_misal2.inc - /MISAL2 (opt-in, XE10W.COM only): misaligned accesses beyond the GVRAM
 * store - main memory, GVRAM reads, the GRCG compare read, the text RAM, the PEGC packed VRAM
 * and word I/O at odd ports - each at dword offsets 0, 1 and 3 (2 where it matters), with byte
 * and dword controls.
 *
 * WHY. XE10V /MISAL (docs/probes/XE10V-XE10-MISAL1.TXT) showed that the Xe10 prices a GVRAM
 * word store by the 16-bit GVRAM words it touches, not by CPU accesses. The C-Lab logo wipe's
 * rows (docs/probes/RWIPE-XE10.TXT) still run slower on the core than on the machine, and the
 * rows' other half is main memory: the blit reads its 20 words from a main-RAM copy at an
 * arbitrary offset, and a 486 may split a misaligned cache hit into two cycles. These rows
 * price every other path a misaligned access takes.
 *
 * TAGS: <FAMILY>_<K>[_<PHASE>], K = the access's byte offset (in its dword, or for 13/15 in its
 * 16-byte line), PHASE as /MISAL. The decoder takes the K = 0 row of a family as its base.
 *   Main memory (the 256 KiB buffer; no raster dependence, no phase). "H" families repeat over
 *   1 KiB (64 lines, warm in the 8 KiB L1 after the first pass), "M" families walk 64 KiB at a
 *   16-byte stride (every access a new line: misses), n = 4096 and 4000 (the walk stays inside
 *   its 64 KiB segment: an access past offset 0xFFFF faults in real mode).
 *     RLWH/RLWM  word loads, K = 0 1 3 15 (15: across a 16-byte line)
 *     RLDH/RLDM  dword loads, K = 0 1 2 13 (13: across a line)
 *     RSWH/RSWM, RSDH/RSDM  the same as stores (swept 0..32 nops)
 *     RLBH_0, RSBH_0  byte controls
 *     RMSW_K  `rep movsw` of 2048 words, buffer 0 -> 0x8000 + K (K = 0 1 3)
 *     RMSS_K  the same, buffer K -> 0x8000 (the source misaligned)
 *     RMSD_K  `rep movsd` of 1024 dwords, 0 -> 0x8000 + K (K = 0 1 2)
 *   GVRAM, plane B (0xA8000), in the phases _O/_A/_V of /MISAL (graphics display stopped; on,
 *   windows on the active lines; on, windows in the vertical blank). n = 512.
 *     GRW_K, GRD_K, GRB_0  plain word (K = 0 1 3), dword (0 1 2) and byte loads, DI += 4
 *     GLSW_K, GLSD_K  `rep lodsw` / `rep lodsd` from K = 0 1
 *     GMVR_K  `rep movsw` GVRAM K -> RAM; GMVV_K  GVRAM K -> GVRAM 0x4000 + K
 *     TCRW_K, TCRB_0  the GRCG TCR word (K = 0 1 3) and byte compare reads (0x7C = 80)
 *     BLSS_K  Rusty's row (50 x `mov cx,20; rep movsw`, DI += 80) under the GRCG RMW (0x7C = C0)
 *             from a main-RAM source at SI = 1 to DI = K (0 1); BLSS_9 = SI 0 to DI 1, the
 *             /MISAL BL1 row, the link
 *   Text RAM, the off-screen 0x1000-0x1FFF of the code (0xA0000) and attribute (0xA2000)
 *   planes, saved to the buffer and copied back (verified), in the same phases:
 *     XCW_K, XAW_K  code / attribute word stores, K = 0 1 3 (swept); XCB_0 byte store (swept)
 *     XCR_K, XAR_K  code / attribute word loads, K = 0 1 3
 *   PEGC 256-colour packed, bank 0 through 0xA8000 (/PEGC's setup), in the same phases:
 *     PKW_K  word stores K = 0 1 3, PKD_K dword stores K = 0 1 (swept), PKR_K word loads
 *   Word I/O (no phase), n = 1024, the ports /AUDIT already word-read on the machine
 *   (docs/probes/XE10T-XE10-AUDIT.TXT) and the display/CG latches /TEXT and /IO already write:
 *     IOIW_K  `in ax,dx` at 0x30 + K (K = 0 1 2 3: 8251 data/status, 8255 0x31/0x33; K = 3
 *             reads 0x33 and 0x34, a word across a dword); IOIB_3 `in al` at 0x33 then 0x34
 *     IOOW_K  `out dx,ax` with AX = 0 at 0xA4 + K - 4 for K = 4 5 (0xA4/0xA5: display page and
 *             CG row; 0xA5/0xA6: CG row and access page) and at 0xA3 (K = 3: CG code high and
 *             the display page, across a dword); IOOB_3 `out` 0xA3 then 0xA4 as bytes
 *
 * RESTORE: GRCG off and the tile 0, EGC off, access page 0; the display as /MISAL; the PEGC
 * as /PEGC (its bank registers to 0, FF2 back to the as-found colour mode, RESTORE lines for
 * 0x9A0 queries 0A and 04); the TRAM copied back and compared (kind=self); 0xA1/0xA3 (CG code)
 * and 0xA5 written 0 (the documented default), 0xA4 and 0xA6 0 (the DOS prompt's).
 */

/* main memory */
TPL r_set0,  "mov ax, word ptr [buf_seg]; mov es, ax; xor di, di; mov eax, 0x55AA55AA"
TPL r_set1,  "mov ax, word ptr [buf_seg]; mov es, ax; mov di, 1; mov eax, 0x55AA55AA"
TPL r_set2,  "mov ax, word ptr [buf_seg]; mov es, ax; mov di, 2; mov eax, 0x55AA55AA"
TPL r_set3,  "mov ax, word ptr [buf_seg]; mov es, ax; mov di, 3; mov eax, 0x55AA55AA"
TPL r_set13, "mov ax, word ptr [buf_seg]; mov es, ax; mov di, 13; mov eax, 0x55AA55AA"
TPL r_set15, "mov ax, word ptr [buf_seg]; mov es, ax; mov di, 15; mov eax, 0x55AA55AA"
TPL r_advh,  "add di, 16; and di, 0x03FF"
TPL r_advm,  "add di, 16"           /* M rows: 4000 x 16 + 15 < 0xFFFC */
TPL r_ms0,   "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x8000; mov cx, 2048"
TPL r_ms1,   "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x8001; mov cx, 2048"
TPL r_ms3,   "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x8003; mov cx, 2048"
TPL r_mss1,  "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; mov si, 1; mov di, 0x8000; mov cx, 2048"
TPL r_mss3,  "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; mov si, 3; mov di, 0x8000; mov cx, 2048"
TPL r_md0,   "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x8000; mov cx, 1024"
TPL r_md1,   "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x8001; mov cx, 1024"
TPL r_md2,   "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x8002; mov cx, 1024"

/* GVRAM plane B, the PEGC bank 0 and the TCR: ES = 0xA800 */
TPL v_ls0,   "mov ax, 0xA800; push ds; mov ds, ax; xor si, si; mov cx, 512"
TPL v_ls1,   "mov ax, 0xA800; push ds; mov ds, ax; mov si, 1; mov cx, 512"
TPL v_ld0,   "mov ax, 0xA800; push ds; mov ds, ax; xor si, si; mov cx, 256"
TPL v_ld1,   "mov ax, 0xA800; push ds; mov ds, ax; mov si, 1; mov cx, 256"
TPL v_mr0,   "mov ax, word ptr [buf_seg]; add ax, 0x1000; push ds; mov es, ax; mov ax, 0xA800; mov ds, ax; xor si, si; xor di, di; mov cx, 512"
TPL v_mr1,   "mov ax, word ptr [buf_seg]; add ax, 0x1000; push ds; mov es, ax; mov ax, 0xA800; mov ds, ax; mov si, 1; xor di, di; mov cx, 512"
TPL v_mv0,   "mov ax, 0xA800; push ds; mov ds, ax; mov es, ax; xor si, si; mov di, 0x4000; mov cx, 512"
TPL v_mv1,   "mov ax, 0xA800; push ds; mov ds, ax; mov es, ax; mov si, 1; mov di, 0x4001; mov cx, 512"
TPL v_bl10,  "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; mov si, 1; xor di, di"
TPL v_bl11,  "mov ax, word ptr [buf_seg]; push ds; mov ds, ax; mov ax, 0xA800; mov es, ax; mov si, 1; mov di, 1"
TPL v_bladv, "add di, 40; mov si, 1"

/* text RAM: the code plane 0xA1000 and the attribute plane 0xA3000 */
TPL x_c0,    "mov ax, 0xA000; mov es, ax; mov di, 0x1000; mov ax, 0x0020"
TPL x_c1,    "mov ax, 0xA000; mov es, ax; mov di, 0x1001; mov ax, 0x0020"
TPL x_c3,    "mov ax, 0xA000; mov es, ax; mov di, 0x1003; mov ax, 0x0020"
TPL x_a0,    "mov ax, 0xA200; mov es, ax; mov di, 0x1000; mov ax, 0x00E1"
TPL x_a1,    "mov ax, 0xA200; mov es, ax; mov di, 0x1001; mov ax, 0x00E1"
TPL x_a3,    "mov ax, 0xA200; mov es, ax; mov di, 0x1003; mov ax, 0x00E1"

/* word I/O */
TPL o_i30,   "mov dx, 0x30"
TPL o_i31,   "mov dx, 0x31"
TPL o_i32,   "mov dx, 0x32"
TPL o_i33,   "mov dx, 0x33"
TPL o_ow4,   "mov dx, 0xA4; xor ax, ax"
TPL o_ow5,   "mov dx, 0xA5; xor ax, ax"
TPL o_ow3,   "mov dx, 0xA3; xor ax, ax"
TPL o_inw,   "in ax, dx"
TPL o_inb2,  "in al, dx; inc dx; in al, dx; dec dx"
TPL o_outw,  "out dx, ax"
TPL o_outb2, "out dx, al; inc dx; out dx, al; dec dx"

tab_m2_ram:
    CASE "RLWH_0",  "w", 4096, 512, 8, r_set0,  g_r16, r_advh, g_nil, CF_BUF
    CASE "RLWH_1",  "w", 4096, 512, 8, r_set1,  g_r16, r_advh, g_nil, CF_BUF
    CASE "RLWH_3",  "w", 4096, 512, 8, r_set3,  g_r16, r_advh, g_nil, CF_BUF
    CASE "RLWH_15", "w", 4096, 512, 8, r_set15, g_r16, r_advh, g_nil, CF_BUF
    CASE "RLWM_0",  "w", 4000, 500, 8, r_set0,  g_r16, r_advm, g_nil, CF_BUF
    CASE "RLWM_1",  "w", 4000, 500, 8, r_set1,  g_r16, r_advm, g_nil, CF_BUF
    CASE "RLWM_3",  "w", 4000, 500, 8, r_set3,  g_r16, r_advm, g_nil, CF_BUF
    CASE "RLWM_15", "w", 4000, 500, 8, r_set15, g_r16, r_advm, g_nil, CF_BUF
    CASE "RLDH_0",  "d", 4096, 512, 8, r_set0,  g_r32, r_advh, g_nil, CF_BUF
    CASE "RLDH_1",  "d", 4096, 512, 8, r_set1,  g_r32, r_advh, g_nil, CF_BUF
    CASE "RLDH_2",  "d", 4096, 512, 8, r_set2,  g_r32, r_advh, g_nil, CF_BUF
    CASE "RLDH_13", "d", 4096, 512, 8, r_set13, g_r32, r_advh, g_nil, CF_BUF
    CASE "RLDM_0",  "d", 4000, 500, 8, r_set0,  g_r32, r_advm, g_nil, CF_BUF
    CASE "RLDM_1",  "d", 4000, 500, 8, r_set1,  g_r32, r_advm, g_nil, CF_BUF
    CASE "RLDM_13", "d", 4000, 500, 8, r_set13, g_r32, r_advm, g_nil, CF_BUF
    CASE "RLBH_0",  "b", 4096, 512, 8, r_set0,  g_r8,  r_advh, g_nil, CF_BUF
    CASE "RSWH_0",  "w", 4096, 512, 8, r_set0,  g_w16, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSWH_1",  "w", 4096, 512, 8, r_set1,  g_w16, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSWH_3",  "w", 4096, 512, 8, r_set3,  g_w16, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSWH_15", "w", 4096, 512, 8, r_set15, g_w16, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSWM_0",  "w", 4000, 500, 8, r_set0,  g_w16, r_advm, g_nil, CF_SWEEP | CF_BUF
    CASE "RSWM_1",  "w", 4000, 500, 8, r_set1,  g_w16, r_advm, g_nil, CF_SWEEP | CF_BUF
    CASE "RSWM_15", "w", 4000, 500, 8, r_set15, g_w16, r_advm, g_nil, CF_SWEEP | CF_BUF
    CASE "RSDH_0",  "d", 4096, 512, 8, r_set0,  g_w32, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSDH_1",  "d", 4096, 512, 8, r_set1,  g_w32, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSDH_2",  "d", 4096, 512, 8, r_set2,  g_w32, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSDH_13", "d", 4096, 512, 8, r_set13, g_w32, r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RSDM_0",  "d", 4000, 500, 8, r_set0,  g_w32, r_advm, g_nil, CF_SWEEP | CF_BUF
    CASE "RSDM_13", "d", 4000, 500, 8, r_set13, g_w32, r_advm, g_nil, CF_SWEEP | CF_BUF
    CASE "RSBH_0",  "b", 4096, 512, 8, r_set0,  g_w8,  r_advh, g_nil, CF_SWEEP | CF_BUF
    CASE "RMSW_0",  "w", 2048, 1, 1, r_ms0,  g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "RMSW_1",  "w", 2048, 1, 1, r_ms1,  g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "RMSW_3",  "w", 2048, 1, 1, r_ms3,  g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "RMSS_1",  "w", 2048, 1, 1, r_mss1, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "RMSS_3",  "w", 2048, 1, 1, r_mss3, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "RMSD_0",  "d", 1024, 1, 1, r_md0,  g_movsd, g_nil, g_post_ds, CF_BUF
    CASE "RMSD_1",  "d", 1024, 1, 1, r_md1,  g_movsd, g_nil, g_post_ds, CF_BUF
    CASE "RMSD_2",  "d", 1024, 1, 1, r_md2,  g_movsd, g_nil, g_post_ds, CF_BUF
    ENDTAB
tab_m2_gv:                              /* GRCG off */
    CASE "GRW_0",   "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil
    CASE "GRW_1",   "w", 512, 64, 8, m_set1, g_r16, g_adv4, g_nil
    CASE "GRW_3",   "w", 512, 64, 8, m_set3, g_r16, g_adv4, g_nil
    CASE "GRD_0",   "d", 512, 64, 8, m_set0, g_r32, g_adv4, g_nil
    CASE "GRD_1",   "d", 512, 64, 8, m_set1, g_r32, g_adv4, g_nil
    CASE "GRD_2",   "d", 512, 64, 8, m_set2, g_r32, g_adv4, g_nil
    CASE "GRB_0",   "b", 512, 64, 8, m_set0, g_r8,  g_adv4, g_nil
    CASE "GLSW_0",  "w", 512, 1, 1, v_ls0, g_lodsw, g_nil, g_post_ds
    CASE "GLSW_1",  "w", 512, 1, 1, v_ls1, g_lodsw, g_nil, g_post_ds
    CASE "GLSD_0",  "d", 256, 1, 1, v_ld0, g_lodsd, g_nil, g_post_ds
    CASE "GLSD_1",  "d", 256, 1, 1, v_ld1, g_lodsd, g_nil, g_post_ds
    CASE "GMVR_0",  "w", 512, 1, 1, v_mr0, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "GMVR_1",  "w", 512, 1, 1, v_mr1, g_movsw, g_nil, g_post_ds, CF_BUF
    CASE "GMVV_0",  "w", 512, 1, 1, v_mv0, g_movsw, g_nil, g_post_ds
    CASE "GMVV_1",  "w", 512, 1, 1, v_mv1, g_movsw, g_nil, g_post_ds
    ENDTAB
tab_m2_tcr:                             /* 0x7C = 80: reads are the TCR */
    CASE "TCRW_0",  "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil
    CASE "TCRW_1",  "w", 512, 64, 8, m_set1, g_r16, g_adv4, g_nil
    CASE "TCRW_3",  "w", 512, 64, 8, m_set3, g_r16, g_adv4, g_nil
    CASE "TCRB_0",  "b", 512, 64, 8, m_set0, g_r8,  g_adv4, g_nil
    ENDTAB
tab_m2_bl:                              /* 0x7C = C0 */
    CASE "BLSS_0",  "row", 50, 10, 5, v_bl10, m_blit, v_bladv, g_post_ds, CF_BUF
    CASE "BLSS_1",  "row", 50, 10, 5, v_bl11, m_blit, v_bladv, g_post_ds, CF_BUF
    CASE "BLSS_9",  "row", 50, 10, 5, m_sbl1, m_blit, m_bladv, g_post_ds, CF_BUF
    ENDTAB
tab_m2_tx:
    CASE "XCW_0",   "w", 512, 64, 8, x_c0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XCW_1",   "w", 512, 64, 8, x_c1, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XCW_3",   "w", 512, 64, 8, x_c3, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XCB_0",   "b", 512, 64, 8, x_c0, g_w8,  g_adv4, g_nil, CF_SWEEP
    CASE "XCR_0",   "w", 512, 64, 8, x_c0, g_r16, g_adv4, g_nil
    CASE "XCR_1",   "w", 512, 64, 8, x_c1, g_r16, g_adv4, g_nil
    CASE "XCR_3",   "w", 512, 64, 8, x_c3, g_r16, g_adv4, g_nil
    CASE "XAW_0",   "w", 512, 64, 8, x_a0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XAW_1",   "w", 512, 64, 8, x_a1, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XAW_3",   "w", 512, 64, 8, x_a3, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "XAR_0",   "w", 512, 64, 8, x_a0, g_r16, g_adv4, g_nil
    CASE "XAR_1",   "w", 512, 64, 8, x_a1, g_r16, g_adv4, g_nil
    CASE "XAR_3",   "w", 512, 64, 8, x_a3, g_r16, g_adv4, g_nil
    ENDTAB
tab_m2_pk:
    CASE "PKW_0",   "w", 512, 64, 8, m_set0, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "PKW_1",   "w", 512, 64, 8, m_set1, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "PKW_3",   "w", 512, 64, 8, m_set3, g_w16, g_adv4, g_nil, CF_SWEEP
    CASE "PKD_0",   "d", 512, 64, 8, m_set0, g_w32, g_adv4, g_nil, CF_SWEEP
    CASE "PKD_1",   "d", 512, 64, 8, m_set1, g_w32, g_adv4, g_nil, CF_SWEEP
    CASE "PKR_0",   "w", 512, 64, 8, m_set0, g_r16, g_adv4, g_nil
    CASE "PKR_1",   "w", 512, 64, 8, m_set1, g_r16, g_adv4, g_nil
    CASE "PKR_3",   "w", 512, 64, 8, m_set3, g_r16, g_adv4, g_nil
    ENDTAB
tab_m2_io:
    CASE "IOIW_0",  "io", 1024, 128, 8, o_i30, o_inw,  g_nil, g_nil
    CASE "IOIW_1",  "io", 1024, 128, 8, o_i31, o_inw,  g_nil, g_nil
    CASE "IOIW_2",  "io", 1024, 128, 8, o_i32, o_inw,  g_nil, g_nil
    CASE "IOIW_3",  "io", 1024, 128, 8, o_i33, o_inw,  g_nil, g_nil
    CASE "IOIB_3",  "io", 1024, 128, 8, o_i33, o_inb2, g_nil, g_nil
    CASE "IOOW_4",  "io", 1024, 128, 8, o_ow4, o_outw, g_nil, g_nil
    CASE "IOOW_5",  "io", 1024, 128, 8, o_ow5, o_outw, g_nil, g_nil
    CASE "IOOW_3",  "io", 1024, 128, 8, o_ow3, o_outw, g_nil, g_nil
    CASE "IOOB_3",  "io", 1024, 128, 8, o_ow3, o_outb2, g_nil, g_nil
    ENDTAB
tl_misal2:  .word tab_m2_ram, tab_m2_gv, tab_m2_tcr, tab_m2_bl, tab_m2_tx, tab_m2_pk, tab_m2_io, 0
tc_misal2:  .asciz "RAM buffer(scribbled) GVRAM-B/PEGC-bank0(scribbled) TRAM 0xA1000-0xA1FFF,0xA3000-0xA3FFF(saved,restored) 0x7C=80/C0/00 0x7E 0x6A 0xA3/0xA4/0xA5/0xA6=00 E0004/E0006/E0100 INT18h AH=41/42/40"
nm_misal2:  .asciz "MISAL2"
kw_misal2:  .asciz "MISAL2"
n_tram2:    .asciz "TRAM_1000_1FFF"
n_ioa3:     .asciz "PA3A4A5A6_00"
rs_m2buf:   .asciz "buffer_under_256k"

/* m2_tram_copy: AL = 0 save (TRAM -> buffer+0x3000:0000/1000), 1 restore. */
m2_tram_copy:
    pushad
    push    ds
    push    es
    mov     bx, word ptr [buf_seg]
    add     bx, 0x3000
    mov     dx, 0xA000
    mov     bp, 2
1:  cld
    test    al, al
    jnz     2f
    mov     ds, dx
    mov     es, bx
    mov     si, 0x1000
    xor     di, di
    jmp     3f
2:  mov     ds, bx
    mov     es, dx
    xor     si, si
    mov     di, 0x1000
3:  mov     cx, 0x0800
    rep     movsw
    add     dx, 0x0200
    add     bx, 0x0100
    dec     bp
    jnz     1b
    pop     es
    pop     ds
    popad
    ret

/* m2_tram_cmp: EDX = mismatching words between the TRAM and its saved copy. */
m2_tram_cmp:
    push    ds
    push    es
    push    si
    push    di
    push    cx
    push    bx
    push    ax
    xor     edx, edx
    mov     bx, word ptr [buf_seg]
    add     bx, 0x3000
    mov     ax, 0xA000
1:  mov     ds, bx
    mov     es, ax
    xor     si, si
    mov     di, 0x1000
    mov     cx, 0x0800
2:  push    ax
    mov     ax, word ptr [si]
    cmp     ax, word ptr es:[di]
    pop     ax
    je      3f
    inc     edx
3:  add     si, 2
    add     di, 2
    loop    2b
    add     bx, 0x0100
    add     ax, 0x0200
    cmp     ax, 0xA400
    jb      1b
    pop     ax
    pop     bx
    pop     cx
    pop     di
    pop     si
    pop     es
    pop     ds
    ret

m2_pegc_on:
    .ifdef XE10Y
    push    eax
    call    artic_read                  /* /PKAB's STATE lines print the time since this */
    mov     dword ptr [k3_pgt], eax
    pop     eax
    .endif
    mov     al, 0x04
    call    query9a0
    mov     byte ptr [m2_q04], al
    mov     byte ptr [m2_pgon], 1
    mov     al, 0x01
    out     0x6A, al
    mov     al, 0x07
    out     0x6A, al
    mov     al, 0x21
    out     0x6A, al
    mov     al, 0x06
    out     0x6A, al
    push    es
    mov     ax, 0xE000
    mov     es, ax
    mov     byte ptr es:[0x0100], 0x00
    mov     word ptr es:[0x0004], 0
    mov     word ptr es:[0x0006], 0
    pop     es
    ret

m2_pegc_off:
    cmp     byte ptr [m2_pgon], 0
    je      1f
    mov     byte ptr [m2_pgon], 0
    push    es
    mov     ax, 0xE000
    mov     es, ax
    mov     word ptr es:[0x0004], 0
    mov     word ptr es:[0x0006], 0
    pop     es
    mov     al, 0x07
    out     0x6A, al
    mov     al, 0x20
    out     0x6A, al
    mov     al, 0x06
    out     0x6A, al
    mov     al, byte ptr [m2_q04]
    and     al, 1
    out     0x6A, al
1:  ret

/* m2_phase: the GVRAM, TCR, blit, TRAM and PEGC tables in the phase [tag_sfx] names. */
m2_phase:
    call    ms_rearm
    mov     si, offset k_STATE
    call    info_start
    PS      "grcg=00 gvram reads phase="
    mov     si, word ptr [tag_sfx]
    call    out_s
    call    out_nl
    mov     al, 0
    out     0x7C, al
    mov     si, offset tab_m2_gv
    call    run_list
    mov     al, 0x80
    call    grcg_set
    mov     si, offset tab_m2_tcr
    call    run_list
    call    ms_rearm
    mov     al, 0xC0
    call    grcg_set
    mov     si, offset tab_m2_bl
    call    run_list
    mov     al, 0
    out     0x7C, al
    cmp     byte ptr [m2_tsaved], 0
    je      1f
    call    ms_rearm
    mov     si, offset tab_m2_tx
    call    run_list
1:  call    ms_rearm
    call    m2_pegc_on
    mov     si, offset k_STATE
    call    info_start
    PS      "pegc=256 packed bank0=0 phase="
    mov     si, word ptr [tag_sfx]
    call    out_s
    call    out_nl
    mov     si, offset tab_m2_pk
    call    run_list
    call    m2_pegc_off
    ret

sec_misal2:
    mov     si, offset nm_misal2
    mov     eax, WD_60S
    mov     bx, offset m2_exit
    call    sec_begin
    mov     byte ptr [win_ph], 0
    mov     word ptr [ms_to], 0
    mov     word ptr [tag_sfx], 0
    mov     byte ptr [m2_tsaved], 0
    mov     byte ptr [m2_pgon], 0
    call    gfx_off
    call    gfx_state
    call    ms_bda
    mov     word ptr [ms_bda0], ax
    mov     si, offset k_STATE
    call    info_start
    PS      "as_found"
    call    ms_state_bda
    PS      " bufparas="
    movzx   eax, word ptr [buf_paras]
    call    out_x4
    call    out_nl
    /* main memory and word I/O: no raster dependence */
    mov     si, offset tab_m2_ram
    call    run_list
    call    ms_rearm
    mov     si, offset tab_m2_io
    call    run_list
    call    gfx_off                     /* 0xA6 = 0 again after the IOOW rows */
    /* the TRAM copy (it needs the whole 256 KiB buffer) */
    cmp     word ptr [buf_paras], 0x4000
    jae     1f
    mov     si, offset rs_m2buf
    call    skip_line
    jmp     2f
1:  mov     al, 0
    call    m2_tram_copy
    mov     byte ptr [m2_tsaved], 1
2:  mov     byte ptr [ms_disp], 1
    mov     ah, 0x41
    int     0x18
    mov     si, offset tg_ras_o
    call    ms_raster
    mov     word ptr [tag_sfx], offset sfx_ph_o
    call    m2_phase
    mov     word ptr [tag_sfx], 0
    mov     al, 0
    out     0x7C, al
    mov     ah, 0x42
    mov     ch, 0xC0
    int     0x18
    mov     ah, 0x40
    int     0x18
    mov     si, offset k_STATE
    call    info_start
    PS      "gfx=on ah42=C0"
    call    ms_state_bda
    call    out_nl
    mov     si, offset tg_ras_g
    call    ms_raster
    mov     byte ptr [win_ph], 1
    mov     word ptr [tag_sfx], offset sfx_ph_a
    call    m2_phase
    mov     byte ptr [win_ph], 2
    mov     word ptr [tag_sfx], offset sfx_ph_v
    call    m2_phase
m2_exit:
    call    sec_disarm
    mov     byte ptr [win_ph], 0
    mov     word ptr [tag_sfx], 0
    call    m2_pegc_off
    mov     al, 0x0A
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [q_save+3]
    mov     si, offset n_q0a
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    mov     al, 0x04
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [q_save+0]
    mov     si, offset n_q04
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    mov     si, offset n_pegcbank
    xor     eax, eax
    call    rs_default
    mov     al, 0
    call    grcg_set
    mov     al, 0
    mov     cx, 4
3:  out     0x7E, al
    loop    3b
    mov     si, offset n_7e
    xor     eax, eax
    call    rs_default
    xor     al, al                      /* the CG code, the CG row, the pages: 0 */
    out     0xA1, al
    out     0xA3, al
    out     0xA4, al
    out     0xA5, al
    out     0xA6, al
    mov     si, offset n_ioa3
    xor     eax, eax
    call    rs_default
    cmp     byte ptr [m2_tsaved], 0
    je      4f
    mov     byte ptr [m2_tsaved], 0
    mov     al, 1
    call    m2_tram_copy
    call    m2_tram_cmp
    mov     si, offset n_tram2
    xor     eax, eax
    mov     cx, 0x0204
    mov     bl, 3
    call    rs_line
4:  cmp     byte ptr [ms_disp], 0
    je      6f
    mov     byte ptr [ms_disp], 0
    mov     ah, 0x41
    int     0x18
    mov     ch, 0x80
    test    byte ptr [ms_bda0 + 1], 0x04
    jz      5f
    mov     ch, 0xC0
5:  mov     ah, 0x42
    int     0x18
    test    byte ptr [ms_bda0], 0x80
    jz      51f
    mov     ah, 0x40
    int     0x18
51: call    ms_bda
    and     al, 0x80
    movzx   edx, al
    movzx   eax, byte ptr [ms_bda0]
    and     al, 0x80
    mov     si, offset n_b54c
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    call    ms_bda
    and     ah, 0x04
    movzx   edx, ah
    movzx   eax, byte ptr [ms_bda0 + 1]
    and     al, 0x04
    mov     si, offset n_b54d
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
6:  mov     si, offset k_I
    call    info_start
    PS      "sync_to="
    movzx   eax, word ptr [ms_to]
    call    out_d
    call    out_nl
    call    gfx_restore_common
    call    sec_end
    ret

    VARS
m2_q04:     .byte 0
m2_pgon:    .byte 0
m2_tsaved:  .byte 0
    ENDVARS
