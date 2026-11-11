// Native z486 PC-9821 memory-address translator: it translates only the physical backend address,
// preserving z486's valid/ready and response protocols. Firmware-pack
// storage hides in the 1 MiB reserve above guest RAM. NOT MODELLED: writable firmware storage.

`default_nettype none

module pc9821_memory_map (
    // 32 KiB ROM-window state: the pack offset is chosen by bank_offset().
    input wire [3:0] top_bank,
    input wire ide_rom_enable,
      // 0x063C bits 1-0 (pc9821_iobus d8_bank): which ROM the 0xD8000 window shows.
    input wire [1:0] d8_bank,
      // The IDE option ROM's 8 KiB work-RAM visibility gate (port 0x1E8E bit 0,
      // latched in pc9821_iobus). With it clear, 0xDA000-0xDBFFF is the absent
      // area's own shape (see ide_workram below); with it set the window is
      // ordinary identity RAM.
    input wire ide_ram_gate,
      // 0x053D bit 1: with it clear the machine shows ROM and discards stores to the firmware windows.
    input wire bios_ram_gate,
      // 0x043F's 0x8 nibble (pc9821_iobus top_shadow_en): the writable shadow over
      // 0xF8000-0xFFFFF is enabled. See the fw_shadow_read use below.
    input wire top_shadow_en,
      // Set once a gated top-window store has landed in the shadow this power-on/OSD reset.
      // Until then the shadow's content is the pack's, so a read serves the pack -- which is
      // what keeps the ITF's SECOND ROM-sum pass (run after it enables the shadow) pristine.
    input wire fw_shadow_dirty,
      // The 32 KiB shadow store's base in the SDRAM reserve above the pack
      // (pc9821_memory_subsystem computes pack_base + PACK_BYTES + 0x58000).
    input wire [31:0] fw_shadow_base,
    // The EMS page window at 0xB0000-0xBFFFF (0x043F's 0x2 nibble). The machine has three
    // measured states: 0x20 = the identity (the ordinary VRAM planes), 0x22 =
    // the 64 KiB memory window (64 KiB of writable RAM - the ITF fills and verifies all
    // 0x4000 dwords of it, BANK4@0xF82C7-0xF8317), and any other 0x2x = unmapped. pc9821_iobus
    // encodes that as ems_state 0/1/2: only state 1 leaves the planes and takes the page
    // (see ems_page_base), and state 2 is routed to the open-bus responder by the subsystem.
    // A 0x2x other than 0x20/0x22 written from the identity keeps it (pc9821_iobus next_ems_state).
    input wire [1:0]  ems_state,
    // Where the 0x22 state's 64 KiB page lives in the backend (see pc9821_memory_subsystem).
    /* verilator lint_off UNUSEDSIGNAL */   // low 20 bits are the constant 0x48000 (pack_base + PACK_BYTES + 0x48000): the page arm is a splice
    input wire [31:0] ems_page_base,
    /* verilator lint_on UNUSEDSIGNAL */
      // 0x0461: the base of the movable 128 KiB window at 0x80000-0x9FFFF, as a PAGE NUMBER.
    input wire [7:0] win0_sel,
    // pc9821_iobus's registered `win0_sel != 8'h08` (equal to the compare every cycle).
    input wire       win0_sel_moved,

      // Runtime memory sizing: the 1 MiB firmware reserve sits directly above the guest RAM.
    /* verilator lint_off UNUSEDSIGNAL */   // pack_base/guest_ram_bytes are whole MiB: their low 20 bits are zero and not read
    input wire [31:0] pack_base,
    input wire [31:0] guest_ram_bytes,      // size_code_bytes: a whole MiB; the RAM bound reads only [31:20]
    /* verilator lint_on UNUSEDSIGNAL */

      // The PEGC extended-VRAM window: 0xF00000-0xF7FFFF when 0x043B's 15-16 MiB hole is on, and
      // the SDRAM base it lives at. Decoded in pc9821_memory_subsystem because that is
      // where sys16m_en lives; served here so the access takes the ordinary backend route.
    input wire        peg_window,
    /* verilator lint_off UNUSEDSIGNAL */   // peg_base's low 19 bits are zero (0x80000-aligned) and not read
    input wire [31:0] peg_base,
    /* verilator lint_on UNUSEDSIGNAL */

    // THE PEGC 256-COLOUR WINDOW ARMS. `pegc_256` is
    // the 0x6A dat 0x21 select (pc9821_crtc's mode2_256col), and while it is set the
    // four first-MiB graphics windows are NOT the planar planes - NP2kai installs its
    // memvga handlers over 0xA8000/0xB0000/0xB8000/0xE0000 whenever VOPBIT_VGA is set
    // (i386c/cpumem.c), shadowing the planar windows AND the EMS overlay entirely:
    //   0xA8000-0xAFFFF -> the packed store at {bank_a, offset[14:0]}
    //   0xB0000-0xB7FFF -> the packed store at {bank_b, offset[14:0]}
    //   0xB8000-0xBFFFF -> not connected (NP2kai memnc_*; the open-bus responder)
    //   0xE0000-0xE7FFF -> the PEGC register file (NP2kai memvgaio_*; pc9821_pegc)
    // With `pegc_plane` set (0xE0100 bit 0) the two packed windows belong to the
    // plane engine instead - ladder rung L3, deliberately NOT built, so they read
    // open bus here rather than silently corrupting the packed store. The bank
    // registers and the mode come from the register file (pc9821_pegc).
    input wire        pegc_256,
    input wire        pegc_plane,
    input wire [3:0]  pegc_bank_a,
    input wire [3:0]  pegc_bank_b,
    // The map's decode of those three arms, for the subsystem's route selects:
    // pegc_packed takes the ordinary backend route below, pegc_reg_win routes to
    // the register file's responder, pegc_nc to the registered open-bus one.
    output wire        pegc_packed,
    output wire        pegc_reg_win,
    output wire        pegc_nc,

    // THE E PLANE IS AN ANALOG-MODE WINDOW. `mode2_16color` is the 16-colour select (port 0x6A
    // dat 0x00/0x01, FF2 num 0; pc9821_crtc's mode2_16color). With it clear - the digital
    // (8-colour) mode DOS leaves - the machine shows NOTHING at 0xE0000-0xE7FFF: 0xE0004 reads
    // FF and keeps no store (docs/probes/DMAROUTE-XE10.TXT case P4 view V1, `ORIG=FFFFFFFF
    // PRE=FFFFFFFF POST=FFFFFFFF` under `9A0_04/07/08/0A=00 00 00 00`), and 0xE0000 reads
    // FF FF FF FF after `00 FF 55 AA` were written (docs/probes/VRAM2.TXT `E000wrote= 00 FF 55 AA`
    // / `got= FF FF FF FF`). NP2kai agrees: memm_vram installs memnc_* over the 0xE0000 slot
    // whenever VOPBIT_ANALOG (gdc_o6a's num-0 bit) is clear (i386c/cpumem.c). So the intensity
    // window decodes only with the bit set, and `e_plane_nc` names the digital-mode slot for
    // the subsystem's registered open-bus responder (reads 0xFF, stores dropped). The 256-colour
    // view outranks both (pegc_reg_win: NP2kai's VOPBIT_VGA branch takes the slot first).
    input wire        mode2_16color,
    output wire       e_plane_nc,

            // Graphics VRAM sits directly above the 1 MiB firmware reserve; 0xA6 selects the page.

                // The plane-window decode, exported for the EGC route: which window the address hit and its
                // in-plane offset, so a consumer may gate this block's cpu_valid without a loop.
    output wire        gvram_window,
    output wire [1:0]  gvram_win_plane,
    output wire [14:0] gvram_win_offset,

    // z486/native requester
    input  wire [31:0] cpu_addr,
    // THE SAME ACCESS BEFORE THE SUBSYSTEM'S TRANSLATION, and which translation made cpu_addr
    // from it (pc9821_memory_subsystem's eff_addr; its three arms are mutually exclusive):
    //   xl_low20: cpu_addr = {12'd0, cpu_addr_raw[19:0]} (the 15 MiB mirror, the BIOS at 4 GiB)
    //   xl_peg:   cpu_addr = {8'd0,  cpu_addr_raw[23:0]} (the PEGC high alias)
    //   neither:  cpu_addr = cpu_addr_raw
    // The control decodes below (window 0, the region flags, the RAM-bound compare) run on the
    // raw address per arm and select late, so the translation selects are the LAST mux in those
    // cones rather than their first (docs/timing.md P0); cpu_addr still carries the data path.
    // A requester with no translation ties cpu_addr_raw to cpu_addr and both selects low.
    /* verilator lint_off UNUSEDSIGNAL */   // cpu_addr_raw[12:0] is never read: the decoders take [31:13], the win0 slice [19:13]/[16], and the data path prefers cpu_addr
    input  wire [31:0] cpu_addr_raw,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        xl_low20,
    input  wire        xl_peg,
    input  wire [31:0] cpu_din,
    output wire [31:0] cpu_dout,
    input  wire [3:0]  cpu_be,
    input  wire [7:0]  cpu_burstcount,
    input  wire        cpu_line_read,
    input  wire        cpu_valid,
    input  wire        cpu_write,
    output wire        cpu_ready,
    output wire        cpu_resp_valid,

                // Asserted for the absent ROM area so the subsystem routes it away; this block does not serve it.
    output wire        absent_area,
    // d_addr >= guest_ram_bytes: the subsystem's open-bus select reuses this compare instead of
    // building a second 32-bit one on the same post-window-0 address - its `route_addr` IS the
    // d_addr exported just below, so the two cannot disagree.
    output wire        addr_ge_ram,
    // THE WINDOW-0 BIAS, EXPORTED. `d_addr` is the post-window-0 address every decode below uses,
    // and `win0_moved` is the flag that produced it; pc9821_memory_subsystem's route selects
    // (the PEGC/TRAM/CG windows, the open-bus bound) consume THESE instead of recomputing the
    // membership test, the 9-bit bias add and the 32-bit select a second time. One definition,
    // one copy: tools/check_cpu_addr_front_equiv.py proves the exported pair equal to the
    // window-0 bias expressions for every 32-bit address and both window-0 flags.
    output wire [31:0] d_addr,
    output wire        win0_moved,
    // Asserted for the EMS window's measured unmapped state (0x2x other than 0x20/0x22) so
    // the subsystem routes it to the registered open-bus responder, exactly as absent_area
    // is. Decoded here, on the same post-window-0 address every other region uses, so the
    // two cannot disagree about which addresses the window covers.
    output wire        ems_open_bus,
    // A store to the 0xF8000-0xFFFFF shadow is in flight this cycle. The subsystem sets
    // fw_shadow_dirty on its accept, which is what turns the shadow into the window's read
    // source from then on (see pc9821_memory_subsystem).
    output wire        fw_shadow_store,

    // Guest-memory backend
    output wire [31:0] mem_addr,
    output wire [31:0] mem_din,
    input  wire [31:0] mem_dout,
    output wire [3:0]  mem_be,
    output wire [7:0]  mem_burstcount,
    output wire        mem_valid,
    output wire        mem_write,
    input  wire        mem_ready,
    input  wire        mem_resp_valid
);

            // Window 0: 0x80000-0x9FFFF is a 128 KiB alias of the RAM page (value & 0xFE) * 0x10000. 0x08 is
            // the identity, 0x0E points at 0xE0000-0xFFFFF, 0x0C at 0xC0000-0xDFFFF, bit 0 is ignored, and
            // read-back is value|1. Pages 0x00-0x07 are NOT an alias but a hole (win0_hole_page below).
            // BIAS IS APPLIED PRE-DECODE so each region below keeps one comparison:
            // the ITF's 0x9800<-0xF800 copy after 0x461=0x0E needs 0x80000+x == 0xE0000+x.
  // The membership test is a BIT SLICE, not the 32-bit range compare it reads as: [0x80000,0x9FFFF]
  // is exactly "the address is in the first MiB (bits [31:20] all zero) and bits [19:17] are 100",
  // because bit 16 is free inside the window. Bit-equal for every 32-bit input, so the standalone
  // bench's boundaries and its win0 0x00/0x0E/0x10 cases are unchanged. This is the same slice
  // identity the plane windows below already use, and it is on the design's worst 50 MHz cone:
  // the two magnitude compares left a LessThan chain between the CPU address and win0_moved.
  // Tested on the RAW address: no translation arm can move an address into or out of the
  // window (pc9821_memory_subsystem reads this flag; tools/check_cpu_addr_front_equiv.py).
  wire        win0_in_window = !(|cpu_addr_raw[31:20]) && (cpu_addr_raw[19:17] == 3'b100);
  // win0_sel_moved is pc9821_iobus's REGISTERED `win0_sel != 8'h08`, equal to the compare in
  // every cycle (tools/check_win0_moved_inv.py), so the window test is the address slice and one
  // flop, not the slice and an 8-bit compare (the C7 head, docs/timing.md).
  // The exported pair (see the port comment): the module's own consumers read the same wire.
  assign win0_moved = win0_in_window && win0_sel_moved;
  // The bias add is a bit splice, not a carry chain: inside the window cpu_addr - 0x80000 is
  // exactly cpu_addr[16:0], and win0_sel << 16 lands the page in [23:16], so the 32-bit
  // `cpu_addr + {8'd0,win0_sel,16'd0} - 0x80000` is a 9-bit add over a wired-through low half.
  // win0_sel[0] is always 0 (pc9821_iobus masks 0xFE); the cpu_addr[16] carry term keeps the
  // odd-value arithmetic identical anyway. The carry chain it replaces was 2.3 ns of
  wire [8:0] win0_hi = {1'b0, win0_sel} + {8'd0, cpu_addr_raw[16]};   // [16] is never translated
  assign d_addr = win0_moved ? {7'd0, win0_hi, cpu_addr[15:0]} : cpu_addr;
  // THE REGION DECODE IS MUXED LATE. Every window flag below is a pure function of
  // d_addr[31:13], and d_addr is one of exactly two addresses: the raw cpu_addr, or (window 0
  // moved) {7'd0, win0_hi, cpu_addr[15:0]}. So each flag is decoded on BOTH in parallel and
  // win0_moved picks the finished flag, instead of picking the address and decoding after it:
  // win0_moved is the deepest select in the cone (the ext_addr_r -> eff_addr -> win0_moved prefix,
  // docs/timing.md P0), and this leaves one mux level after it where the address-first form
  // left the nibble compares as well (the fitted C7 chain ran win0_moved -> gvram_low[19] ->
  // peg_a8 -> gvram_window). The moved arm's decode reads only win0_sel (a register) and
  // cpu_addr[16:13]. Bit-equal for every input: tools/check_memmap_addr_equiv.py proves every
  // output of the map against the address-first form.
  localparam integer DV_W = 17;
  function automatic [DV_W-1:0] region_dec(input [31:13] a);
    reg first;
    begin
      first = !(|a[31:20]);
      region_dec = {
        first,                                                          // 16 first MiB
        first && (a[19:16] == 4'hD) && (a[15:14] == 2'b10),             // 15 D8000-DBFFF
        first && (a[19:16] == 4'hD) && (a[15:13] == 3'b100),            // 14 D8000-D9FFF
        first && (&a[19:17]) && (a[15] != a[16]),                       // 13 E8000-F7FFF
        first && (&a[19:16]) && a[15],                                  // 12 F8000-FFFFF
        &a[31:15],                                                      // 11 FFFF8000-
        first && (a[19:16] == 4'hC) && a[15] && a[14],                  // 10 CC000-CFFFF
        first && (a[19:16] == 4'hD) && a[15] && !a[14] && a[13],        //  9 DA000-DBFFF
        first && (a[19:16] == 4'hD) && a[15] && a[14],                  //  8 DC000-DFFFF
        first && (a[19:17] == 3'b110) && (!a[16] || !a[15]),            //  7 C0000-D7FFF
        (a[19:16] == 4'hA) && a[15],                                    //  6 A8000-AFFFF
        (a[19:16] == 4'hB) && !a[15],                                   //  5 B0000-B7FFF
        (a[19:16] == 4'hB) && a[15],                                    //  4 B8000-BFFFF
        (a[19:16] == 4'hE) && !a[15],                                   //  3 E0000-E7FFF
        (a[19:16] == 4'hB),                                             //  2 B0000-BFFFF
        a[16:15] - 2'd1                                                 // 1:0 plane index
      };
    end
  endfunction
  // ... and the unmoved address is itself one of three, by the subsystem's translation arm,
  // so it is decoded per arm too and the translation selects pick the finished flag (P0-d).
  wire [DV_W-1:0] dv_raw = region_dec(cpu_addr_raw[31:13]);
  wire [DV_W-1:0] dv_l20 = region_dec({12'd0, cpu_addr_raw[19:13]});
  wire [DV_W-1:0] dv_peg = region_dec({8'd0, cpu_addr_raw[23:13]});
  // WINDOW 0 AT 0x0A IS RAM, NOT THE VRAM WINDOWS. The machine's window-0 page 0x0A/0x0B is
  // storage of its own: docs/probes/DMAROUTE-XE10.TXT cases W1/W2 (0x0461=0x0A) store through
  // 0x88100 and 0x81000 and read the bytes back there (V0 -> D), while plane B at 0xA8100 and
  // the text RAM at 0xA1000 keep their prefills (V1 -> P1) and so does the RAM the window
  // covers (V2 -> P2); the as-found bytes under the window are DRAM-like noise
  // (`V0 ORIG=00200000...`, `V0 ORIG=FFFFFFFFF5FFFFDF...`) where the plane and the text RAM read
  // 00/0x0020 - as docs/probes/WIN.TXT's `0461=0A ... b=0800` already showed against the text
  // RAM's 0x0020. So the moved arm decodes no graphics window on that page (plane, packed,
  // not-connected or EMS arms: bits 6, 5, 4 and 2), and the access falls through to the backend
  // at d_addr, 0xA0000-0xBFFFF, the RAM page QEMU's rule-(a) names (pc98-mem.c:295, the same
  // arithmetic every other page uses here); pc9821_memory_subsystem keeps its text-RAM, CG and
  // gap routes off a moved address the same way. win0_sel[0] is always 0, so 0x0A is the one
  // value whose window lands there. The mask is on a register (win0_sel), off the address cone.
  wire            win0_ram_page = (win0_sel == 8'h0A);
  // WINDOW 0 BELOW PAGE 8 IS A HOLE. docs/probes/KIT2-XE10-RISKY-461.TXT:5-15 (RISKY /461): with
  // 0x0461 = 00, 01, 02, 03, 04 or 06 every window word read at 0x80000/0x80400/0x90000/0x9FFFE
  // is FFFF while the conventional memory the page names reads its contents directly (`R461 00
  // rb=01 win(80000 80400 90000 9FFFE)=FFFF FFFF FFFF FFFF dir=B625 7002 0001 82E8`), and a
  // marker stored through the window at pages 00 and 01 reads FFFF back and never reaches the
  // cell (`mark(win before/after, cell)=FFFF FFFF 3C5A`); page 08 is the identity (line 17).
  // win0_sel[0] is always 0, so 0x07 is 0x06's page. So the moved arm answers the FF-always
  // decode on those pages (bit 8, the bit ide_worktail reads, which routes the access to the
  // open-bus responder: all ones, stores discarded); a page below 8 names RAM below 0x80000,
  // where no other region bit is set. Pages above 0x09 are not measured and keep the alias.
  // Like win0_ram_page the select is on a register, off the address cone.
  wire            win0_hole_page = (win0_sel[7:3] == 5'd0);
  wire [DV_W-1:0] dv_mv_dec = region_dec({7'd0, win0_hi, cpu_addr_raw[15:13]});
  wire [DV_W-1:0] dv_mv  = win0_ram_page  ? (dv_mv_dec & ~17'h00074) :
                           win0_hole_page ? (dv_mv_dec | 17'h00100)  : dv_mv_dec;
  wire [DV_W-1:0] dv     = win0_moved ? dv_mv : xl_low20 ? dv_l20 : xl_peg ? dv_peg : dv_raw;

        // Only the 8 KiB option ROM is a window; 0xDA000-0xDBFFF stays identity RAM because the authentic
        // IDE BIOS keeps its private 8 KiB work RAM there, gated by 0x1E8E -- and that gate is decoded
        // below (ide_workram): the work RAM is RAM only while it is connected. 0xDC000-0xDFFFF is
        // the FF-always tail decoded below (ide_worktail).
  // EVERY FIRST-MiB WINDOW HERE IS A BIT SLICE, NOT THE 32-BIT RANGE COMPARE IT READS AS, for the
  // same reason the plane windows below are: a window inside the first MiB is "the 64 KiB block
  // d_addr[19:16] is one of the window's blocks and d_addr[31:20] is zero", with bit 15 choosing
  // the half where the window is half a block. Each identity below is bit-equal for EVERY 32-bit
  // input, not only the first-MiB ones the guest can present (checked exhaustively below 2^20 and
  // over every high prefix), so the standalone bench's boundary and out-of-range cases are
  // unchanged. The magnitude compares left a carry chain feeding the d_addr mux, which is the
  // shape the plane-window slices below already replaced.
  //   0xD8000-0xD9FFF = block D with bit 15 set (the 8 KiB option-ROM window)
  //   0xE8000-0xF7FFF = block E with bit 15 set, or block F with it clear
  //   0xF8000-0xFFFFF = block F with bit 15 set
  // THE 0x063C BANK SELECT. Bits 1-0 = 1 or 3 replace the IDE option ROM and its work RAM
  // across 0xD8000-0xDBFFF with one 16 KiB half of BANK0.BIN (the pack's extended ROM bank 0
  // at +0x31000): select 1 shows 0x0000-0x3FFF, select 3 shows 0x4000-0x7FFF; selects 0 and 2
  // are the IDE option ROM. Measured: docs/probes/D8BANK-XE10.TXT (each select's 32 KiB
  // dumped on the Xe10 and matched byte for byte against the BANK0/BANK3 dumps; the
  // 0xDC000 half reads 0xFF for every select). The Xe10 BIOS's INT 1Fh AH=CEh path selects 1
  // and far-returns into D800:0018, which EMM386 reaches during its initialisation; showing
  // the IDE ROM there instead hangs MS-DOS 6.2 EMM386's boot. ASSUMPTION: the alternate banks
  // share the IDE ROM's 0x053D gate (ide_rom_enable); the capture was taken with it open.
  wire d8_alt = ide_rom_enable && d8_bank[0];
  wire d8_alt_window = d8_alt && dv[15];
  wire ide_rom_window = ide_rom_enable && !d8_bank[0] && dv[14];
  wire bios_lower = dv[13];
  wire fw_low = dv[12];
  // 0xFFFF8000-0xFFFFFFFF is "every bit from 15 upward": the top-of-4G ROM alias.
  wire fw_high = dv[11];
  wire fw_window = fw_low || fw_high;
        // Out-of-range completion lives here as well as in the subsystem's pc9821_open_bus responder:
        // tb_pc9821_memory_map expects 0xFFFF_FFFF here, and the two cannot both accept.
        // The bound is tested on the BIASSED address: d_addr is the address
        // the backend would serve, so a window-0 target past guest RAM (or past where its
        // direct encoding is RAM) is open bus here exactly as its direct encoding is. Testing
        // cpu_addr would let the overlay's 0x80000-0x9FFFF reach ordinary SDRAM at a target where
        // the direct encoding serves open bus (or PEGC EVRAM). The fw_high guard moves with
        // it because fw_high is decoded on d_addr too; for every access the two agree except
        // through the window-0 bias, which can never land on fw_high.
  // Per arm, like the region flags: d_addr is one of four addresses, each compared on its own
  // and the window-0/translation selects pick the finished compare (the fitted R1 chain ran
  // eff_addr -> d_addr -> this compare -> open_select -> z_ready). `d_addr >= 0xFFFF8000` is
  // &d_addr[31:15], i.e. fw_high.
  //
  // THE BOUND IS A 12-BIT SLICE COMPARE, NOT A 32-BIT MAGNITUDE COMPARE.
  // INVARIANT: guest_ram_bytes is one of the eight OSD sizes, 1/2/4/8/16/32/64/96 MiB
  // (pc9821_system's size_code_bytes, a 3-bit ram_size_sel case), so its bits [19:0] are
  // ZERO in every reachable state. For a MiB-aligned bound B, `A >= B` is exactly
  // `A[31:20] >= B[31:20]` for EVERY 32-bit A: below B's 1 MiB block A cannot reach B
  // whatever its low bits, and inside B's own block A's low bits can only make it greater
  // than or equal to B (A[19:0] >= 0 always). The low 20 bits of each arm's address are
  // therefore not part of the comparison, and no 32-bit magnitude carry chain runs into
  // open_select (the R1/P0 cone, docs/timing.md).
  // The one arm whose address is below the smallest legal size collapses outright:
  //   {12'd0, cpu_addr_raw[19:0]} is in [0, 1 MiB) and the smallest guest size is 1 MiB,
  //   so the 15 MiB / BIOS-high alias arm can never be at or above the bound (ge_l20 = 0).
  // tools/check_memmap_addr_equiv.py proves every output of this map value-identical to
  // the full-width form over every address under these two invariants (guest_ram_bytes
  // from the size table, pack_base/pack-relative bases MiB-aligned), and its plants on
  // each arm must be refuted.
  wire [11:0] ram_mib_hi = guest_ram_bytes[31:20];
  wire ge_raw = (cpu_addr_raw[31:20] >= ram_mib_hi);
  wire ge_l20 = 1'b0;                                    // see the invariant above
  wire ge_peg = ({8'd0, cpu_addr_raw[23:20]} >= ram_mib_hi);
  // The window-0 arm's address is {7'd0, win0_hi, cpu_addr_raw[15:0]}, so its
  // [31:20] is {7'd0, win0_hi[8:4]} (bit 24 is win0_hi[8], bits 23:20 its [7:4]).
  wire ge_mv  = ({7'd0, win0_hi[8:4]} >= ram_mib_hi);
  assign addr_ge_ram = win0_moved ? ge_mv : xl_low20 ? ge_l20 : xl_peg ? ge_peg : ge_raw;
  wire out_of_range = addr_ge_ram && !fw_high && !peg_window;
  wire local_open_bus = out_of_range && cpu_valid;   // the EMS window's unmapped state is answered by the registered
                                                      // open-bus responder, not here (see pc9821_memory_subsystem)


  wire [14:0] fw_offset = d_addr[14:0];

            // ================= ABSENT ROM AREA: 0xC0000-0xD7FFF ======================
            // Measured: 0xFF throughout, and stores discarded. Decoded on d_addr and left
            // UNCLAIMED, not identity RAM: the BIOS's option-ROM scan walks this range and absent != 0xAA55.
            // ONE 16 KiB OF IT IS NOT ABSENT ON THE MACHINE: the fitted PC-9801-86 banks its 16 KiB
            // SOUND.ROM at 0xCC000-0xCFFFF, and the machine answers real code there - the +C000..+F800
            // rows of docs/probes/SHADOW.TXT:150-199 hold it and every other 2 KiB block of the area
            // reads 0xFF (ffblocks=0028 of blocks=0030). That window is decoded below
            // (sound_rom_window, the PC-9801-86 SOUND.ROM) and carved out of this area; the rest stays absent.
  // 0xC0000-0xD7FFF is block C anywhere, or block D with bit 15 clear (see the slice note above).
            // ================= THE PC-9801-86 SOUND.ROM WINDOW: 0xCC000-0xCFFFF =================
            // The fitted -86 card banks its 16 KiB option ROM here and the machine answers real
            // code: docs/probes/SHADOW.TXT:150-199 samples all eight 2 KiB blocks of the window and
            // every sampled byte matches the Xe10's SOUND.ROM dump (sha256 f05b508d...;
            // the +C000 row's 06 1E 56 57 55 53 16 1F is SOUND.ROM[0x0000]), so the dump IS the
            // window's content. Read-only like every ROM window: a store is dropped. Served from
            // the pack's SOUND.ROM region (tools/pack_layout.py SOUND_OFFSET); a pack built
            // without the image is 0xFF there, i.e. the "no card fitted" answer.
  wire sound_rom_window = dv[10];
            // ================= THE 0x1E8E-GATED IDE WORK RAM: 0xDA000-0xDBFFF ======================
            // The IDE option ROM keeps its private 8 KiB work RAM at D800:2000+ (BANK3@0x0B40
            // sets ES=0xD800 and its state tables land at 0xDA066-0xDA2xx), and the machine can
            // DISCONNECT it: with port 0x1E8E bit 0 clear the window reads 0xFF and drops stores,
            // with it set the same address is the work RAM again -- measured end to end by
            // docs/probes/SHADOWW.TXT:226-231 (the 1E8E read-back runs FE FF FE through the
            // probe's 0x80/0x81/restore writes; its DA000 marker reads back FFFF under 0x80 and
            // 5AA5 under 0x81; the IDE ROM's own work bytes reappear under 0x81, so the RAM
            // SURVIVES the disconnect and only its visibility is gated). Gate-off is exactly the
            // absent area's shape (all ones, stores discarded), so it takes the same route: this
            // is what an EMM386 C0000-DFFFF region scan sees on the machine, and why the scan can
            // never claim the IDE ROM's work area as UMB (a failing-boot mechanism; its causal
            // link to that freeze is PLAUSIBLE, not proven - a hardware boot test is the proof). The 8 KiB extent follows QEMU's non-PCI machine class
            // (hw/i386/pc98-mem.c:1427-1433 "its work RAM is paged in at 0xda000"); NP2kai's
            // comment says the same although its page mask 0x1c00 would also cover DC000
            // (cbus/ideio.c:1478-1495). DC000-DFFFF is NOT gated RAM at all: it is the
            // FF-always tail decoded below (ide_worktail).
            // Block D with bit 15 set is the D8000-DFFFF window; bit 14 splits its RAM half
            // (DA000-DBFFF, bit 13 set) from the option-ROM window (D8000-D9FFF) and from
            // the FF-always tail (DC000-DFFFF).
  wire ide_workram = !d8_alt && dv[9];
            // ================ end the 0x1E8E-gated IDE work RAM ================================

            // ================= THE FF-ALWAYS TAIL: 0xDC000-0xDFFFF ==========================
            // The 16 KiB above the work RAM answers all ones and swallows stores in BOTH
            // gate states. Measured: docs/probes/SHADOW.TXT:201-213 reads 0xFF over all 12 x
            // 2 KiB blocks of the DA000..DFFFF region with the gate clear (`summary:
            // blocks=000C bytes=00006000 ... ffblocks=000C`), and QEMU models the rest of the
            // 0xD8000 window as rom_empty - a 0xFF fill with only the 8 KiB ide_ram overlaid
            // at 0xDA000 (hw/i386/pc98-mem.c d8000_rom; NP2kai's 12 KiB gate mask 0x1c00 is
            // the outlier). The gate-ON state is measured too: docs/probes/XE10CFG-XE10-CFGWR.TXT:9-13
            // (`DC000 1E8E was/gate/back FE FF FE`, then `DC000 gate81` and `DC000 marked` read
            // FF x16 after a 5A A5 store under 0x1E8E=0x81), so the tail answers FF in both gate
            // states, as modelled.
  // (The moved window's hole pages set the same bit: see win0_hole_page.)
  wire ide_worktail = dv[8];
            // ================ end the FF-always tail ====================================
  assign absent_area = (dv[7] && !sound_rom_window) ||
                       (ide_workram && !ide_ram_gate) || ide_worktail;
  // ================ end absent ROM area ===================================

                  // Graphics VRAM: 0xA8000-0xBFFFF holds planes B/R/G as three contiguous 32 KiB windows; the
                  // intensity window at 0xE0000 is separate (0xD0000 is the option ROM's). This file only DECODES
                  // them - pc9821_gvram owns the planes and takes {page, plane_offset}.
  wire [15:0] gvram_low    = d_addr[15:0];   // the block nibble [19:16] is decoded in region_dec
  // The PEGC window arms' membership tests are the same nibble slices the plane
  // decodes use: A8000-AFFFF is nibble A with bit 15 set, B0000-B7FFF nibble B with
  // bit 15 clear, B8000-BFFFF nibble B with bit 15 set, E0000-E7FFF nibble E with
  // bit 15 clear - each inside the first MiB (`peg_first`). The packed bank splice is
  // NP2kai's VGARD8: physical offset = {bank, window offset[14:0]} (mem/memvga.c
  // `(mio1[p*2] & 15) << 15`, and MAME pegc_mmio_map's `bank * 0x4000` words).
  wire        peg_first = dv[16];
  wire        peg_a8    = dv[6];
  wire        peg_b0    = dv[5];
  wire        peg_b8    = dv[4];
  wire        peg_e0    = dv[3];
  assign      pegc_packed  = peg_first && pegc_256 && !pegc_plane && (peg_a8 || peg_b0);
  assign      pegc_reg_win = peg_first && pegc_256 && peg_e0;
  assign      pegc_nc      = peg_first && pegc_256 &&
                             (peg_b8 || ((peg_a8 || peg_b0) && pegc_plane));
  // The EMS window is a first-MiB aperture exactly as the plane windows are, so it carries
  // the same `!|d_addr[31:20]` guard: without it a guest store to e.g. 0x2B0000 would be
  // swallowed by the window whenever the guest left the 0x22 state selected.
  // The three window decodes are NIBBLE EQUALITIES, written out of the 20-bit range
  // compares they are: [B0000,BFFFF] is exactly gvram_low[19:16]==B (a 64 KiB aligned
  // block); [A8000,BFFFF] is nibble B plus the half-block nibble A with bit 15 set
  // (A8000-AFFFF); [E0000,E7FFF] is nibble E with bit 15 clear. Each identity holds for
  // every 20-bit value, and taking them as one-LUT slice functions lets the d_addr/win0 mux
  // feed the decode directly instead of through the wide comparators (wide comparators
  // here, LessThan8/ems_in_window, were a fit's worst path). tb_pc9821_gvram_porta_equiv pins the
  // stream through the aliases and the EMS-shaded silence.
  // In 256-colour mode the packed arms above shadow the EMS overlay entirely
  // (NP2kai's memvga handlers take every slot when VOPBIT_VGA is set - cpumem.c),
  // so `ems_in_window` is gated on !pegc_256 and cannot claim 0xB0000-0xBFFFF.
  wire        ems_in_window = dv[2] && dv[16] && !pegc_256;
  wire        ems_page    = ems_in_window && (ems_state == 2'd1);
  wire        ems_unmapped = ems_in_window && (ems_state == 2'd2);
  wire        ems_shadow  = ems_in_window && (ems_state != 2'd0);
  assign ems_open_bus = ems_unmapped;
  wire        gvram_contig = (dv[2] || dv[6]) && !ems_shadow;
  wire        gvram_inten  = dv[3] && mode2_16color;   // analog (16-colour) mode only: see e_plane_nc
  assign      e_plane_nc   = dv[3] && dv[16] && !pegc_256 && !mode2_16color;
              // The plane windows exist only in the first MiB, and the guard is on d_addr - the address the
              // decoders see: with window 0 moved, a guest address can translate to a page whose low 20 bits
              // look like a plane window (0x461 = 0x7F lands on RAM at 0x7E0000). In 256-colour mode the
              // whole plane set is shadowed by the PEGC arms above (NP2kai's memvga handlers), so
              // gvram_window is gated on !pegc_256; the GRCG/EGC see no window access there, which is
              // exactly the references' dispatch (qemu pc98-vga.c's MODE2_256COLOR arm comes before
              // grcg_mem_readb/egc_mem_readb).
  assign      gvram_window = (gvram_contig || gvram_inten) && dv[16] && !pegc_256;

              // The plane index is the window number: 0xA8000 >> 15 is 21, low two bits 1, hence the -1. The
              // in-plane offset is the address's low 15 bits - each window is one 32 KiB plane.
  assign gvram_win_plane  = gvram_contig ? dv[1:0] : 2'd3;
  assign gvram_win_offset = gvram_low[14:0];

                      // Pack offset of the 32 KiB window at 0xF8000-0xFFFFF. Bank roles follow qemu-pc98's enum - 0 PCI,
                      // 1 APIC, 2 BASIC, 3 IDE option ROM, 4 ITF, 5..7 the 96 KiB main BIOS - which is the layout the
                      // firmware assumes; bank 4 is the reset-vector ITF, so banking away and back reaches the rest.
  function automatic [19:0] bank_offset(input [3:0] state);
    case (state)
      4'd0: bank_offset = 20'h31000;
      4'd1: bank_offset = 20'h39000;
      4'd2: bank_offset = 20'h41000;
      4'd3: bank_offset = 20'h70000;   // IDE option ROM slot
      4'd4: bank_offset = 20'h00000;   // ITF slot, bank 4 of the ROM set
      4'd5: bank_offset = 20'h10000;   // main BIOS, first half
      4'd6: bank_offset = 20'h18000;   // main BIOS, second half
      4'd7: bank_offset = 20'h20000;   // main BIOS top: the default window
      4'd8: bank_offset = 20'h00000;   // BANK_ITF (0x043D)
      4'd9: bank_offset = 20'h20000;   // BANK_BIOS_TOP (0x043D)
      default: bank_offset = 20'h00000;
    endcase
  endfunction

                                  // The 8 KiB option-ROM window offset is cpu_addr[12:0], mapping to pack 0x70000.
                                  // THE WRITABLE TOP-WINDOW SHADOW.
                                  // 0xF8000-0xFFFFF has two layers: the selected pack bank and a writable shadow in
                                  // the SDRAM reserve above the pack. The ITF STORES its candidate-drive bitmap at
                                  // 0xF8E90 while the shadow is enabled and the IDE option ROM READS it back under
                                  // the BIOS-top bank, so both must meet in one byte or the BIOS falls to ROM BASIC.
                                  // The gated STORE goes to the SHADOW, never the pack: a store into the pack is what
                                  // an OSD reset carried into the next boot's ROM sum. The READ serves
                                  // the shadow only while it is both enabled and already written since reset; before
                                  // the first store the shadow's content IS the pack's, so the map reads the pack --
                                  // which is what keeps the sum's second pass (run after 0x043F=0x80, BANK4@0x1D2) on
                                  // pristine ROM instead of the previous boot's stored byte.
  assign fw_shadow_store  = fw_window && cpu_write && bios_ram_gate;
  // The writable shadow backs the BIOS-TOP bank ONLY. QEMU's mem_apply_top_bank
  // (qemu-pc98 hw/i386/pc98-mem.c) enables f8000_ram exactly when
  // `top_bank == BANK_BIOS_TOP && bios_ram_gate`, and only then does the window
  // read RAM instead of ROM. This core reaches that same content as top_bank 7
  // (0x043F's 0xE nibble, bank_offset 0x20000) or 9 (BANK_BIOS_TOP, 0x043D), so
  // the read is gated on those. Reading the shadow for EVERY bank is a defect:
  // the ITF executes its OWN bank (bank 8) out of 0xF8000, so the instant its
  // drive-bitmap store set fw_shadow_dirty the window started serving the
  // BIOS-top bank's bytes where the ITF's own code belongs. The fetch at
  // physical 0xF9A10 then decoded as a memory-operand transfer to 0000:0000 and
  // the CPU ran away in low RAM (s5; the site is NOT the jmp 0:0).
  wire   fw_bios_top_visible = (top_bank == 4'd7) || (top_bank == 4'd9);
  wire   fw_shadow_read   = fw_window && !cpu_write && top_shadow_en &&
                            fw_shadow_dirty && fw_bios_top_visible;
  wire   fw_shadow_access = fw_shadow_store || fw_shadow_read;
  // THE BACKEND ADDRESS IS A SPLICE OF {upper 12 bits, low 20 bits}, NOT A CHAIN OF 32-BIT ADDS.
  // Every window base the backend is handed is a whole number of MiB plus a constant below 1 MiB
  // (pack_base is 1/2/4/.../96 MiB; ems_page_base, fw_shadow_base and peg_base are
  // pack_base + PACK_BYTES + 0x48000/0x58000/0x80000 with PACK_BYTES = 1 MiB), and every offset a
  // window adds is a constant plus at most 16 dynamic bits that cannot carry past bit 19. So
  // each arm is {base[31:20], 20-bit sum} and no adder reaches above bit 19; the only carries left
  // are the short constant-plus-field adds below. The 32-bit `peg_base + (d_addr - 0xF00000)` and
  // `peg_base + peg_bank_off` of the full-width form collapse to splices: inside the PEGC window
  // d_addr[31:19] is 0x1E0, so d_addr - 0xF00000 is d_addr[18:0], and peg_base[18:0] is zero
  // with bit 19 set. Bit-equal to the full-width form under those base invariants
  // (tools/check_memmap_addr_equiv.py proves it over every input bit).
  // pack_base's low 20 bits (zero) and peg_base's low 19 bits (zero) are therefore not read.
  // The EMS page base's low 20 bits are the constant 0x48000 (it is pack_base + PACK_BYTES +
  // 0x48000 with both terms MiB-aligned, pc9821_memory_subsystem), so that add collapses to a
  // splice too (lo_ems_page below); the shadow base keeps its own low 20 bits, which the
  // window offset adds to without a carry out. tools/check_memmap_addr_equiv.py pins both
  // premises in text (PREMISES) as well as proving the outputs, so a change to either
  // subsystem formula fails the proof instead of silently breaking the map.
  /* verilator lint_off UNUSEDSIGNAL */   // the bases' zero low bits are not read
  wire [31:20] pack_hi = pack_base[31:20];
  wire [31:20] peg_hi  = peg_base[31:20];
  wire [31:20] ems_hi  = ems_page_base[31:20];
  wire [31:20] shd_hi  = fw_shadow_base[31:20];
  /* verilator lint_on UNUSEDSIGNAL */
  // bios_lower: pack + 0x10000 + (d_addr - 0xE8000). E8000-EFFFF -> 0x0000-0x7FFF and
  // F0000-F7FFF -> 0x8000-0xFFFF, so the offset is {~d_addr[15], d_addr[14:0]}.
  wire [19:0] lo_bios_lower = {3'd0, 1'b1, ~d_addr[15], d_addr[14:0]};
  wire [19:0] lo_ide_rom    = {4'h7, 3'd0, d_addr[12:0]};                  // pack + 0x70000
  wire [19:0] lo_d8_alt     = 20'h31000 + {5'd0, d8_bank[1], d_addr[13:0]};
  wire [19:0] lo_sound_rom  = 20'hC6800 + {6'd0, d_addr[13:0]};
  // 0x48000 + the 16-bit page offset is a bit splice, not an add: 0x48000's bits [14:0] are
  // zero, so they pass through as gvram_low[14:0]; bit 15 is 1 + gvram_low[15], i.e.
  // ~gvram_low[15], which carries into bit 16 exactly when gvram_low[15] is set; bits 17 and
  // 19 are zero and 0x40000 is bit 18. Bit-equal to `ems_page_base[19:0] + offset`
  // for every offset under the 0x48000 premise above.
  wire [19:0] lo_ems_page   = {3'b010, gvram_low[15], ~gvram_low[15], gvram_low[14:0]};
  wire [19:0] bank_off      = bank_offset(top_bank);
  wire [19:0] lo_fw         = (fw_shadow_access ? fw_shadow_base[19:0] : bank_off) +
                              {5'd0, fw_offset};
  wire [31:20] hi_fw        = fw_shadow_access ? shd_hi : pack_hi;
  assign mem_addr = peg_window     ? {peg_hi, peg_base[19], d_addr[18:0]} :
                    pegc_packed    ? {peg_hi, peg_base[19], (peg_b0 ? pegc_bank_b : pegc_bank_a), gvram_low[14:0]} :
                    ide_rom_window ? {pack_hi, lo_ide_rom} :
                    d8_alt_window  ? {pack_hi, lo_d8_alt} :
                    sound_rom_window ? {pack_hi, lo_sound_rom} :
                    ems_page       ? {ems_hi, lo_ems_page} :
                    bios_lower     ? {pack_hi, lo_bios_lower} :
                    fw_window      ? {hi_fw, lo_fw} :
                                     d_addr;

  assign mem_din = cpu_din;
  assign mem_be = cpu_be;
  assign mem_burstcount = cpu_burstcount;
                              // Firmware-window stores are shadow-RAM writes and exist only while 0x053D bit 1 is set; with it
                              // clear the machine shows ROM and discards the store, so accepting every store let a guest
                              // overwrite the ITF bank - including the reset vector the warm boot re-enters.
                              //
                              // THE ROM PACK IS READ-ONLY, and only the 0xF8000-0xFFFFF window has a writable layer here to
                              // absorb a store: the shadow (fw_shadow_store above), whose store stays gated by
                              // 0x053D bit 1 the way the machine's bios_ram_gate is. The 0xE8000-0xF7FFF main BIOS, the
                              // 0xD8000-0xD9FFF option-ROM window and the 0xCC000-0xCFFFF SOUND.ROM window have NO writable layer - their only backing is the pack -
                              // so a store into either is REJECTED whatever the gate says. NP2kai discards exactly those
                              // stores (cpumem.c:135 memnc_wr8 is `(void)address; (void)value`, and it is the write handler
                              // on both windows: cpumem.c:225 memfn0.wr8[0xe8000>>15]/[0xf8000>>15], :269 mmaptbl bwr8),
                              // and qemu-pc98's 0xd8000 ide_rom is a plain ROM alias.
  wire rom_pack_write = (bios_lower || ide_rom_window || d8_alt_window || sound_rom_window) && cpu_write;
  // The store into the window that DOES have a writable layer: the shadow absorbs it, and only 0x053D bit 1
  // opens that gate. With the gate clear the machine shows ROM and discards the store, which is what stops a
  // guest from overwriting the ITF bank the warm boot re-enters with.
  wire fw_shadow_write  = fw_window && cpu_write;
  wire fw_write_blocked = rom_pack_write || (fw_shadow_write && !bios_ram_gate);
              // No backend request is issued for the absent ROM area, so mem_addr is a don't-care there.
  assign mem_valid = cpu_valid && !out_of_range && !fw_write_blocked &&
                     !absent_area && !ems_unmapped;
  assign mem_write = cpu_write;

                              // z486's direct/uncached window covers the first absent 32 MiB range, so sizing writes cannot
                              // survive only in L1 and masquerade as physical RAM. mem_resp_valid is the SHARED backend's
                              // completion and arrives AFTER the accept, several cycles later, by which time the CPU has
                              // dropped cpu_valid - so gating it on cpu_valid discards a legitimate response and hangs the
                              // guest. It is gated by `map_accepted`, and that record must OUTLIVE the accept (p0-reset-fix).
  wire local_accept = local_open_bus || fw_write_blocked;
  assign cpu_ready = (local_accept ? 1'b1 : mem_ready);
  assign cpu_dout = local_open_bus ? 32'hFFFF_FFFF : mem_dout;
  // THE MAP ROUTE HAS NO LINE FORM. A cache-line fill this route serves from the backend
  // is four word beats on mem_resp_valid/cpu_dout; the only LINE reading this map can answer
  // locally is its out-of-range open-bus path (local_open_bus is the sole local_accept term a
  // read can set - the other, fw_write_blocked, is write-only), and that arm is answered as
  // four all-ones beats in pc9821_memory_subsystem, which owns the reset and the counter. The
  // map stays purely combinational.
  assign cpu_resp_valid = mem_resp_valid ||
                          (cpu_valid && local_accept && !cpu_write && !cpu_line_read);

endmodule

`default_nettype wire
