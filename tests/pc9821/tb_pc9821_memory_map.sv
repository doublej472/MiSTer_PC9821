`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MEMORY_MAP:
// The memory map's decode: every region routes where it should, including the 32 MiB open-bus boundary and the absent ROM area at 0xC0000-0xD7FFF minus the 0xCC000-0xCFFFF PC-9801-86 SOUND.ROM window (served from the pack; its 0x461 = 0x0C alias included), which this block decodes and leaves unclaimed rather than serving. The local open-bus path answers in one cycle and these assertions record that shape: it is a z486 hazard, unreachable in the built design, and tb_pc9821_open_bus.sv is the bench that pins the correct phases. It also transforms the 0x043F 0x2-nibble EMS window at 0xB0000-0xBFFFF: the identity state leaves the GVRAM planes there alone, the 0x22 state reads and writes a 64 KiB page in the backend, and the unmapped state reaches neither the planes nor the backend -- and the window is a first-MiB aperture, so a guest address above 1 MiB with the same low 20 bits stays ordinary RAM. And it pins the ROM windows' read-only contract: a store into the 0xE8000-0xF7FFF main BIOS, the 0xD8000-0xD9FFF option-ROM window or the 0xCC000-0xCFFFF SOUND.ROM window is rejected in BOTH 0x053D bit-1 gate states (their only backing is the pack, and NP2kai discards those stores: cpumem.c:135 memnc_wr8), while the 0xF8000-0xFFFFF window's store is gated by 0x053D bit 1 and falls into the BIOS shadow.


module tb_pc9821_memory_map;
  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 0;
  // The IDE work RAM's 0x1E8E visibility gate (bit 0 of the port). Held ON so
  // the identity-RAM expectations below see the connected work RAM; the gated
  // decode itself is checked both ways further down.
  reg ide_ram_gate = 1'b1;
  reg bios_ram_gate = 0;
  // The top-window shadow. fw_shadow_base is what pc9821_memory_subsystem
  // computes (pack_base + PACK_BYTES + 0x58000, above the GVRAM/PCM/EMS block the SDRAM
  // GVRAM move pushed up); top_shadow_en is the iobus's 0x043F
  // 0x8-nibble latch, and fw_shadow_dirty the subsystem's "a store has landed in the
  // shadow since reset" flag.
  reg        top_shadow_en = 0;
  reg        fw_shadow_dirty = 0;
  reg [31:0] fw_shadow_base = 32'h0209_0000;
  wire       fw_shadow_store;
  // 0x0461 window-0 base. 0x08 is the identity the firmware restores, so the
  // default keeps every pre-existing expectation in this bench in the map's
  // identity region.
  reg [7:0] win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg [31:0] pack_base = 32'h0200_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg [31:0] gvram_base = 32'h0300_0000;
  reg gvram_access_page = 0;
  // The plane-window decode pc9821_memory_map exports for the EGC route
  // (pc9821_memory_subsystem.sv). Checked below: it is the same window the
  // mapper's own VRAM path uses.
  wire gvram_window;
  wire [1:0] gvram_win_plane;
  wire [14:0] gvram_win_offset;
  reg [31:0] cpu_addr = 0;
  reg [31:0] cpu_din = 0;
  reg [3:0] cpu_be = 0;
  reg [7:0] cpu_burstcount = 0;
  reg cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout, mem_addr, mem_din;
  wire [31:0] cpu_line_word;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_line_read, mem_valid, mem_write;
  reg [31:0] mem_dout = 32'h89ABCDEF;
  reg [127:0] mem_line_dout = 128'h00112233445566778899AABBCCDDEEFF;
  reg mem_ready = 0, mem_resp_valid = 0, mem_line_resp_valid = 0;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  // The absent ROM area's decode output: asserted for the guest
  // address whose physical target is 0xC0000-0xD7FFF, which this block hands to
  // the subsystem rather than serving.
  wire absent_area;

  // ==== DUT ====
  // 0x043F EMS window select (from pc9821_iobus) and the backend base of the 0x22
  // state's 64 KiB page (pc9821_memory_subsystem computes it above the pack).
  reg  [1:0]  ems_state = 2'd0;
  reg  [31:0] ems_page_base = 32'd0;
  wire        ems_open_bus;
  // The PEGC extended-VRAM window. This bench is about the map's own
  // decode, so the window is tied off here and driven by tb_pc9821_sys16m.sv;
  // tb_pc9821_pegvram.sv reads the bytes back through the subsystem.
  reg         peg_window = 1'b0;
  reg  [31:0] peg_base = 32'd0;
  // The PEGC window-arm state (pegc-scope-REPORT.md 4 row 2): 0 = the pre-PEGC
  // decode; the arms themselves are tb_pc9821_memmap_ref's cases.
  wire        pegc_256 = 1'b0;
  wire        pegc_plane = 1'b0;
  wire  [3:0] pegc_bank_a = 4'd0, pegc_bank_b = 4'd0;
  wire        pegc_packed, pegc_reg_win, pegc_nc;

  // 0x063C bank select into the 0xD8000 window: 0 = the IDE option ROM, the reset bank.

  reg  [1:0] d8_bank = 2'b00;

  wire addr_ge_ram;   // the map's shared compare output, unused here
  // The map's EXPORTED window-0 pair (P2): d_addr is the post-bias address the subsystem's route
  // selects read as route_addr, win0_moved the flag that produced it. check_bias below holds both
  // to the reference expressions over every window-0 value, so the export cannot drift.
  wire [31:0] d_addr;
  wire        win0_moved;
  // No translation in front of the map here: the untranslated address IS cpu_addr.
  wire [31:0] cpu_addr_raw = cpu_addr;
  wire        xl_low20 = 1'b0;
  wire        xl_peg = 1'b0;
  pc9821_memory_map dut (.*);

  integer errors = 0;
  // ==== STIMULUS ====
  // The plane-window decode. The map does not translate these
  // windows: it emits the plane index and the plane offset and
  // pc9821_memory_subsystem routes the access to pc9821_gvram, which owns the
  // planes. `identity` is what mem_addr must still carry -- the map claims no
  // part of the aperture for itself.
  task automatic check_gvram(input [31:0] addr, input [31:0] identity,
                             input [1:0] plane, input [14:0] off);
    begin
      cpu_addr = addr;
      #1;
      if (!gvram_window || gvram_win_plane !== plane ||
          gvram_win_offset !== off || mem_addr !== identity) begin
        $display("FAIL gvram %08x -> win=%b plane=%0d off=%04x mem=%08x, want plane=%0d off=%04x mem=%08x",
                 addr, gvram_window, gvram_win_plane, gvram_win_offset,
                 mem_addr, plane, off, identity);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_addr(input [31:0] addr, input [31:0] expected);
    begin
      cpu_addr = addr;
      #1;
      if (mem_addr !== expected) begin
        $display("FAIL addr %08x -> %08x, want %08x", addr, mem_addr, expected);
        errors = errors + 1;
      end
    end
  endtask
  // The map's EXPORTED window-0 bias (P2): pc9821_memory_subsystem's route_addr/win0_moved are
  // these two wires, so this task is what holds the export to the documented arithmetic. The
  // reference is written out here from the address and the window value, not read back from the
  // DUT, so a wrong export (an unbiased address, a dropped membership bit, a lost carry) fails.
  task automatic check_bias(input [31:0] addr, input [7:0] sel);
    reg        moved_ref;
    reg [8:0]  hi_ref;
    reg [31:0] d_ref;
    begin
      win0_sel = sel;
      cpu_addr = addr;
      #1;
      moved_ref = !(|addr[31:20]) && (addr[19:17] == 3'b100) && (sel != 8'h08);
      hi_ref = {1'b0, sel} + {8'd0, addr[16]};
      d_ref = moved_ref ? {7'd0, hi_ref, addr[15:0]} : addr;
      if (win0_moved !== moved_ref || d_addr !== d_ref) begin
        $display("FAIL bias addr=%08x sel=%02x -> moved=%b d=%08x, want moved=%b d=%08x",
                 addr, sel, win0_moved, d_addr, moved_ref, d_ref);
        errors = errors + 1;
      end
    end
  endtask
  // ==== CHECKS ====

  initial begin
    // Ordinary RAM is an identity mapping.
    check_addr(32'h0000_0000, 32'h0000_0000);
    check_addr(32'h0001_FC00, 32'h0001_FC00);
    check_addr(32'h0010_0000, 32'h0010_0000);
    check_addr(32'h01FF_FFFF, 32'h01FF_FFFF);

    // The PEGC extended-VRAM window: while peg_window is asserted the map turns
    // 0xF00000-0xF7FFFF into an ordinary backend access at peg_base + the in-window offset,
    // and it does so even for a guest whose RAM ends below 0xF00000 (the window is above it).
    // peg_window is the subsystem's decode of the address, so the map is driven with only the
    // two in-window bounds; that the decode itself stops at 0xF7FFFF is tb_pc9821_sys16m.sv's.
    peg_window = 1'b1;
    peg_base = 32'h0218_0000;
    check_addr(32'h00F0_0000, 32'h0218_0000);
    check_addr(32'h00F7_FFFF, 32'h021F_FFFF);
    peg_window = 1'b0;

    // The current platform exposes exactly 32 MiB. The first absent address
    // is completed locally as open bus and must not reach SDRAM.
    // Not a contract: this path answers in one cycle, which wedges z486 (it clears its
    // in-flight flag on the response). Unreachable in the built design (open_select
    // gates cpu_valid).
    cpu_addr = 32'h0200_0000;
    cpu_valid = 1;
    cpu_write = 0;
    cpu_line_read = 0;
    mem_ready = 0;
    #1;
    if (!cpu_ready || !cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF ||
        mem_valid) begin
      $display("FAIL 32 MiB open-bus boundary");
      errors = errors + 1;
    end
    cpu_valid = 0;

    // D8000 is ordinary RAM until the 0x053D gate enables the option ROM.
    check_addr(32'h000D_8000, 32'h000D_8000);
    ide_rom_enable = 1;
    check_addr(32'h000D_8000, 32'h0207_0000);
    check_addr(32'h000D_9FFF, 32'h0207_1FFF);   // 8 KiB, not 32 KiB
    // 0xDA000-0xDBFFF is the IDE BIOS work RAM: identity RAM while the port
    // 0x1E8E gate bit is set (driven ON here) and the absent route's own shape
    // while it is clear - the machine's own gate, docs/probes/SHADOWW.TXT:226-231
    // (the marker reads back FFFF under 0x80, 5AA5 under 0x81). 0xDC000-0xDFFFF,
    // the 16 KiB above the work RAM, is ABSENT IN BOTH GATE STATES: the
    // machine's capture reads 0xFF over all 12 x 2 KiB blocks of DA000..DFFFF
    // with the gate clear (docs/probes/SHADOW.TXT:201-213, ffblocks=000C) and
    // QEMU models the rest of the window as rom_empty (hw/i386/pc98-mem.c
    // d8000_rom, the 0xFF fill; NP2kai's 12 KiB mask is the outlier). The
    // gate-ON state of the tail is capture-pending: one marker write at 0xDC000
    // under 0x1E8E=0x81 settles it (probe2 /IDEGATE, item 34).
    check_addr(32'h000D_A000, 32'h000D_A000);
    check_addr(32'h000D_BFFF, 32'h000D_BFFF);
    // The gated decode, both edges: clear takes exactly 0xDA000-0xDBFFF to the
    // absent route (the option-ROM window's end stays put), set gives the window
    // straight back to the RAM route - while 0xDC000-0xDFFFF stays absent under
    // both, per SHADOW.TXT:201-213.
    cpu_valid = 1;
    cpu_write = 0;
    cpu_line_read = 0;
    ide_ram_gate = 0;
    cpu_addr = 32'h000D_A000;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL gate-off 0xDA000 not decoded absent: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    cpu_addr = 32'h000D_BFFF;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL gate-off 0xDBFFF (work RAM end) not decoded absent: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    cpu_addr = 32'h000D_9FFF;
    #1;
    if (absent_area) begin
      $display("FAIL gate-off swallowed 0xD9FFF, the option-ROM window's end");
      errors = errors + 1;
    end
    cpu_addr = 32'h000D_C000;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL gate-off 0xDC000 (the FF-always tail) not decoded absent: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    cpu_addr = 32'h000D_FFFF;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL gate-off 0xDFFFF (tail end) not decoded absent: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    ide_ram_gate = 1;
    cpu_addr = 32'h000D_A000;
    #1;
    if (absent_area || !mem_valid || mem_addr !== 32'h000D_A000) begin
      $display("FAIL gate-on 0xDA000 is not the work RAM again: absent_area=%b mem_valid=%b addr=%08x",
               absent_area, mem_valid, mem_addr);
      errors = errors + 1;
    end
    cpu_addr = 32'h000D_C000;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL gate-on 0xDC000 (tail) stopped being absent: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    cpu_valid = 0;

    // Firmware-window stores are shadow-RAM writes and exist only while 0x053D
    // bit 1 (the writable BIOS copy) is set: with it clear the machine shows
    // ROM and discards the store. This is what stops a guest permanently
    // overwriting the ITF bank the warm boot re-enters.
    top_bank = 4'd8;
    bios_ram_gate = 0;
    cpu_addr = 32'h000F_8000;
    cpu_valid = 1;
    cpu_write = 1;
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL ROM-window store not blocked with bios_ram_gate=0");
      errors = errors + 1;
    end
    bios_ram_gate = 1;
    #1;
    if (!mem_valid) begin
      $display("FAIL ROM-window store blocked with bios_ram_gate=1");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_write = 0;

    // Plane windows exist only in the first MiB: their 1 MiB aliases must stay
    // ordinary RAM, otherwise 128 KiB of every MiB of guest RAM is relocated.
    check_addr(32'h001A_8000, 32'h001A_8000);
    check_addr(32'h001E_0000, 32'h001E_0000);
    check_addr(32'h001A_FFFF, 32'h001A_FFFF);

    // Fixed lower BIOS: E8000..F7FFF -> hidden pack + 10000..1FFFF.
    check_addr(32'h000E_8000, 32'h0201_0000);
    check_addr(32'h000F_7FFF, 32'h0201_FFFF);

    // ITF selected at reset: F8000 window and 4 GiB alias agree.
    top_bank = 4'd8;
    check_addr(32'h000F_8000, 32'h0200_0000);
    check_addr(32'h000F_FFFF, 32'h0200_7FFF);
    check_addr(32'hFFFF_8000, 32'h0200_0000);
    check_addr(32'hFFFF_FFFF, 32'h0200_7FFF);

    // Main-BIOS top bank uses pack offset 20000.
    top_bank = 4'd9;
    check_addr(32'h000F_8000, 32'h0202_0000);
    check_addr(32'h000F_FFFF, 32'h0202_7FFF);
    check_addr(32'hFFFF_8000, 32'h0202_0000);
    check_addr(32'hFFFF_FFFF, 32'h0202_7FFF);

    // OSD RAM sizing: the reserve and open-bus boundary track the configured
    // guest size. 16 MiB guest -> pack at 0x0100_0000.
    // Port 0x043F banks follow qemu-pc98's enum: banks 0-2 sit in the extended
    // area above the ANK window, bank 3 is the option-ROM slot, and banks 5-7
    // are the main BIOS, so bank 7 and the 0x043D top-BIOS state are the same
    // image (the BIOS top) rather than two different ones.
    top_bank = 4'd0;
    check_addr(32'h000F_8000, 32'h0203_1000);
    check_addr(32'h000F_FFFF, 32'h0203_8FFF);
    check_addr(32'hFFFF_8000, 32'h0203_1000);
    top_bank = 4'd3;
    check_addr(32'h000F_8000, 32'h0207_0000);   // option-ROM slot
    check_addr(32'h000F_FFFF, 32'h0207_7FFF);
    top_bank = 4'd7;
    check_addr(32'h000F_8000, 32'h0202_0000);   // == the top-BIOS image
    check_addr(32'h000F_FFFF, 32'h0202_7FFF);
    top_bank = 4'd5;
    check_addr(32'h000F_8000, 32'h0201_0000);   // main BIOS first half
    top_bank = 4'd6;
    check_addr(32'h000F_8000, 32'h0201_8000);   // main BIOS second half
    // Bank 4 is the ITF image, so it aliases the reset state.
    top_bank = 4'd4;
    check_addr(32'h000F_8000, 32'h0200_0000);
    check_addr(32'h000F_FFFF, 32'h0200_7FFF);

    top_bank = 4'd8;
    pack_base = 32'h0100_0000;
    guest_ram_bytes = 32'h0100_0000;
    check_addr(32'h0000_FFFF, 32'h0000_FFFF);
    check_addr(32'h000F_8000, 32'h0100_0000);
    check_addr(32'hFFFF_FFFF, 32'h0100_7FFF);
    check_addr(32'h000D_8000, 32'h0107_0000);
    cpu_addr = 32'h0100_0000;
    cpu_valid = 1;
    cpu_write = 0;
    cpu_line_read = 0;
    mem_ready = 0;
    #1;
    if (!cpu_ready || !cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF ||
        mem_valid) begin
      $display("FAIL 16 MiB open-bus boundary");
      errors = errors + 1;
    end
    cpu_valid = 0;

    // 96 MiB guest -> pack at 0x0600_0000; the window still maps 4 GiB.
    pack_base = 32'h0600_0000;
    guest_ram_bytes = 32'h0600_0000;
    check_addr(32'h05FF_FFFF, 32'h05FF_FFFF);
    check_addr(32'h000F_8000, 32'h0600_0000);
    check_addr(32'hFFFF_8000, 32'h0600_0000);
    check_addr(32'h000D_9FFF, 32'h0607_1FFF);
    cpu_addr = 32'h0600_0000;
    cpu_valid = 1;
    #1;
    if (!cpu_ready || !cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF ||
        mem_valid) begin
      $display("FAIL 96 MiB open-bus boundary");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_addr = 32'h0010_0000; // restore an ordinary RAM address

    // Native z486 protocol is passed through without reinterpretation.
    cpu_din = 32'h13579BDF;
    cpu_be = 4'b0101;
    cpu_burstcount = 8'd4;
    cpu_line_read = 1;
    cpu_valid = 1;
    cpu_write = 1;
    mem_ready = 1;
    mem_resp_valid = 1;
    #1;
    if (mem_din !== cpu_din || mem_be !== cpu_be ||
        mem_burstcount !== cpu_burstcount ||
        !mem_valid || !mem_write || !cpu_ready ||
        cpu_dout !== mem_dout ||
        !cpu_resp_valid) begin
      $display("FAIL native bus pass-through");
      errors = errors + 1;
    end
    // Every decode check below is a READ, and since the top-window shadow
    // the firmware-window ADDRESS depends on cpu_write: a store
    // while the 0x053D bit-1 gate is set targets the BIOS-top slot whatever the
    // bank register says, a read follows the bank register. Leaving cpu_write
    // asserted from the pass-through test made the read expectations below
    // describe a store. Drive the direction explicitly.
    cpu_write = 0;

    // Graphics VRAM: four 32 KiB planes plus the access-page offset from port
    // 0xA6 (ReC98 page_access). Plane strides are 0x8000 and the page stride is
    // 0x20000, so each window maps to gvram_base + page*0x20000 + plane*0x8000.
    check_gvram(32'h000A_8000, 32'h000A_8000, 2'd0, 15'h0000);  // blue, offset 0
    check_gvram(32'h000A_FFFF, 32'h000A_FFFF, 2'd0, 15'h7FFF);  // blue, end
    check_gvram(32'h000B_0000, 32'h000B_0000, 2'd1, 15'h0000);  // red
    check_gvram(32'h000B_7FFF, 32'h000B_7FFF, 2'd1, 15'h7FFF);
    check_gvram(32'h000B_8000, 32'h000B_8000, 2'd2, 15'h0000);  // green
    check_gvram(32'h000E_0000, 32'h000E_0000, 2'd3, 15'h0000);  // intensity
    check_gvram(32'h000E_7FFF, 32'h000E_7FFF, 2'd3, 15'h7FFF);

    // The access page (port 0xA6) is not part of the map's answer any more: it
    // became pc9821_gvram's `page` field of {page, plane_offset}, so the decode
    // is identical on both pages and only the identity address moves with
    // window 0. That is the change D1 makes -- and the reason the map's address
    // path no longer carries the plane bias arithmetic.
    gvram_access_page = 1;
    check_gvram(32'h000A_8000, 32'h000A_8000, 2'd0, 15'h0000);
    gvram_access_page = 0;

    // A4000 is not a plane (text RAM ends at A3FFF), so it stays identity-mapped
    // RAM rather than being captured by the graphics aperture (in the built
    // design the subsystem's CG window intercepts it). 0xE8000 is
    // deliberately not tested here: it is the lower-BIOS firmware window, not
    // RAM.
    check_addr(32'h000A_4000, 32'h000A_4000);

    // ---- The absent ROM area: 0xC0000-0xD7FFF --------------------
    // The machine's C-Bus option-ROM space with nothing fitted reads 0xFF at
    // every byte and discards stores (docs/probes/SHADOW.TXT "REGION
    // C0000..D7FFF"; docs/probes/WIN.TXT `0461=0C rb=0D b=FFFF a=FFFF`). This
    // block DECODES the range and must not serve it: no backend transaction may
    // be issued, so no SDRAM byte can be returned and no stored signature can
    // make the BIOS's option-ROM scan call into it.
    cpu_valid = 1;
    cpu_write = 0;
    // 0xBFFFF is the green plane's last byte, immediately below the area.
    cpu_addr = 32'h000B_FFFF;
    #1;
    if (absent_area || !mem_valid) begin
      $display("FAIL 0xBFFFF captured or dropped: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    // Every 2 KiB boundary of the area, plus the two ends and the 16 KiB
    // PC-9801-86 SOUND.ROM window inside it (0xCC000-0xCFFFF: measured real
    // code on the machine, SHADOW.TXT:150-199 = bios/xe10/SOUND.ROM),
    // which is SERVED from the pack while the rest of the area stays absent.
    for (integer off = 0; off < 48; off = off + 1) begin
      cpu_addr = 32'h000C_0000 + (off * 32'h800);
      #1;
      if (off >= 24 && off < 32) begin
        if (absent_area || !mem_valid ||
            mem_addr !== (pack_base + 32'h000C_6800 + (cpu_addr - 32'h000C_C000))) begin
          $display("FAIL SOUND.ROM window %05x: absent_area=%b mem_valid=%b mem_addr=%08x, want %08x",
                   cpu_addr[19:0], absent_area, mem_valid, mem_addr,
                   pack_base + 32'h000C_6800 + (cpu_addr - 32'h000C_C000));
          errors = errors + 1;
        end
      end else if (!absent_area || mem_valid) begin
        $display("FAIL absent area %05x: absent_area=%b mem_valid=%b mem_addr=%08x",
                 cpu_addr[19:0], absent_area, mem_valid, mem_addr);
        errors = errors + 1;
      end
    end
    cpu_addr = 32'h000D_7FFF;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL absent area end 0xD7FFF: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    // A store into the area is the same route (the machine discards it): the map
    // must not turn it into a backend write either.
    cpu_write = 1;
    cpu_addr = 32'h000C_0000;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL absent-area store reached the backend: mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end
    // The SOUND.ROM window's store is rejected the same way (its only backing is
    // the pack): read-only like every ROM window, whatever the 0x053D gate says.
    cpu_addr = 32'h000C_C000;
    #1;
    if (absent_area || mem_valid) begin
      $display("FAIL SOUND.ROM store reached the backend: absent_area=%b mem_valid=%b mem_addr=%08x",
               absent_area, mem_valid, mem_addr);
      errors = errors + 1;
    end
    cpu_write = 0;
    // The neighbours are not in the area: 0xD8000 is the option-ROM window
    // (here enabled), 0xDA000-0xDBFFF the IDE option ROM's work RAM (identity
    // RAM while its 0x1E8E gate bit is set - ON here; the gated shape is the
    // decode section above), 0xE8000 the lower BIOS
    // and 0xF8000 the ROM window. 0xDC000-0xDFFFF is NOT a neighbour: it is
    // the absent area's own tail (FF-always, both gate states), so the last
    // neighbour check here is 0xDFFFF -> absent.
    cpu_addr = 32'h000D_8000;
    #1;
    if (absent_area || !mem_valid || mem_addr !== (pack_base + 32'h0007_0000)) begin
      $display("FAIL 0xD8000 is not the option-ROM window: absent_area=%b mem_valid=%b mem_addr=%08x",
               absent_area, mem_valid, mem_addr);
      errors = errors + 1;
    end
    cpu_addr = 32'h000D_A000;
    #1;
    if (absent_area || !mem_valid) begin
      $display("FAIL 0xDA000 (IDE work RAM) captured by the absent area");
      errors = errors + 1;
    end
    // The 0x063C bank select (the EMM386 /UMB boot hang). Measured on the Xe10 (docs/probes/
    // D8BANK-XE10.TXT, the window dumped per select and matched against the dumped
    // ROMs): selects 0 and 2 show the IDE option ROM (BANK3.BIN, the pack's +0x70000);
    // select 1 shows BANK0.BIN 0x0000-0x3FFF and select 3 BANK0.BIN 0x4000-0x7FFF
    // (the pack's +0x31000 extended-ROM bank 0) across 0xD8000-0xDBFFF, the IDE work
    // RAM included; 0xDC000-0xDFFFF reads 0xFF for every select.
    d8_bank = 2'd1;
    check_addr(32'h000D_8000, pack_base + 32'h0003_1000);
    check_addr(32'h000D_8018, pack_base + 32'h0003_1018);
    check_addr(32'h000D_A000, pack_base + 32'h0003_3000);
    check_addr(32'h000D_BFFF, pack_base + 32'h0003_4FFF);
    d8_bank = 2'd3;
    check_addr(32'h000D_8000, pack_base + 32'h0003_5000);
    check_addr(32'h000D_BFFF, pack_base + 32'h0003_8FFF);
    cpu_addr = 32'h000D_C000;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL 0xDC000 under 0x063C select 3 is not the FF tail");
      errors = errors + 1;
    end
    d8_bank = 2'd2;
    check_addr(32'h000D_8018, pack_base + 32'h0007_0018);
    d8_bank = 2'd0;
    cpu_addr = 32'h000D_FFFF;
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL 0xDFFFF (the FF-always tail's end) not captured by the absent area");
      errors = errors + 1;
    end
    cpu_addr = 32'h000E_8000;
    #1;
    if (absent_area || !mem_valid) begin
      $display("FAIL 0xE8000 (lower BIOS) captured by the absent area");
      errors = errors + 1;
    end
    cpu_addr = 32'h000F_8000;
    #1;
    if (absent_area || !mem_valid) begin
      $display("FAIL 0xF8000 (ROM window) captured by the absent area");
      errors = errors + 1;
    end

    // ---- window 0 (0x0461): 0x80000-0x9FFFF aliases value*0x10000 ---------
    // pack_base = 0x01F80000, gvram_base = 0x03000000 and top_bank = 8 (the
    // ITF) here, so the expectations below are the firmware's own arithmetic:
    // with the window at 0x0E the ITF copies 32 KiB from DS=0xF800 to
    // ES=0x9800 and 64 KiB from DS=0xE800 to ES=0x8800 (BANK4@0x01D9-0x01FE),
    // which is a materialise-into-the-shadow at the SAME physical address.
    // The sizing section above moved the reserve, so put it back first.
    pack_base = 32'h0200_0000;
    guest_ram_bytes = 32'h0200_0000;
    win0_sel = 8'h08;                                  // identity, the restore value
    check_addr(32'h0008_0000, 32'h0008_0000);
    check_addr(32'h0009_8000, 32'h0009_8000);
    check_addr(32'h0009_FFFF, 32'h0009_FFFF);

    // THE EXPORTED WINDOW-0 PAIR (P2). d_addr/win0_moved are what pc9821_memory_subsystem's
    // route_addr/win0_moved read, so they carry the whole bias contract: the window's edges, the
    // identity, the top page (whose bias crosses into bit 24), an odd value (unreachable from the
    // iobus, which masks 0xFE, but the documented arithmetic keeps it identical) and an address
    // above the first MiB where the window does not exist.
    check_bias(32'h0008_0000, 8'h0A);
    check_bias(32'h0009_FFFF, 8'h0E);
    check_bias(32'h0009_0000, 8'h0C);
    check_bias(32'h0008_FFFF, 8'h10);
    check_bias(32'h0009_8000, 8'h7E);
    check_bias(32'h0009_8000, 8'hFE);
    check_bias(32'h0008_0000, 8'h0B);
    check_bias(32'h0008_0000, 8'h08);
    check_bias(32'h0018_8000, 8'h0A);
    check_bias(32'hFFF8_0000, 8'h0A);
    win0_sel = 8'h08;

    win0_sel = 8'h0E;                                  // 0xE0000-0xFFFFF
    check_addr(32'h0009_8000, 32'h0200_0000);          // -> the ROM window
    check_addr(32'h0009_FFFF, 32'h0200_7FFF);
    check_addr(32'h0008_8000, 32'h0201_0000);          // -> the lower BIOS
    check_addr(32'h0008_FFFF, 32'h0201_7FFF);
    // 0x80000-0x87FFF is the first 32 KiB of the window, which aliases
    // 0xE0000: the same bytes the intensity window serves with the window at
    // identity. The firmware never touches that part, but it must not be RAM.
    // Measured, at the DOS prompt in TEXT mode the machine answers 0xFFFF there
    // and discards the store (`0461=0E rb=0F b=FFFF a=FFFF`), i.e. the
    // intensity plane is not served in that mode; this core serves it
    // unconditionally and does not model the mode gate (an open question).
    check_gvram(32'h0008_0000, 32'h000E_0000, 2'd3, 15'h0000);  // == 0xE0000
    // The window exists only in the first MiB: its 1 MiB alias is guest RAM.
    check_addr(32'h0018_8000, 32'h0018_8000);
    check_addr(32'h0019_8000, 32'h0019_8000);

    win0_sel = 8'h0C;                                  // 0xC0000-0xDFFFF
    ide_rom_enable = 0;
    check_addr(32'h0009_8000, 32'h000D_8000);          // -> identity address...
    ide_rom_enable = 1;                                // ...which is the option-ROM window
    check_addr(32'h0009_8000, 32'h0207_0000);          // pack option-ROM slot
    check_addr(32'h0009_9FFF, 32'h0207_1FFF);
    // Measured through the same window, the machine reads 0xFFFF at 0xC0000 and
    // 0xD0000 and discards stores there (`0461=0C rb=0D b=FFFF a=FFFF`), so the
    // region the window selects is not backed on the machine at that moment.
    // The window aliases the physical address space, so it inherits the absent
    // area: a marker written through 0x80000 (0xC0000) on the machine did not
    // take (WIN.TXT above). The decode is on the translated address for exactly
    // this reason.
    cpu_addr = 32'h0008_0000;                          // -> 0xC0000
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL window-0 0x0C alias of 0xC0000: absent_area=%b mem_valid=%b mem_addr=%08x",
               absent_area, mem_valid, mem_addr);
      errors = errors + 1;
    end
    cpu_addr = 32'h0008_FFFF;                          // -> 0xCFFFF (the SOUND.ROM window's end)
    #1;
    if (absent_area || !mem_valid ||
        mem_addr !== (pack_base + 32'h000C_6800 + 32'h0000_3FFF)) begin
      $display("FAIL window-0 0x0C alias of 0xCFFFF: absent_area=%b mem_valid=%b mem_addr=%08x",
               absent_area, mem_valid, mem_addr);
      errors = errors + 1;
    end
    cpu_addr = 32'h0009_0000;                          // -> 0xD0000
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL window-0 0x0C alias of 0xD0000: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    cpu_addr = 32'h0009_7FFF;                          // -> 0xD7FFF
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL window-0 0x0C alias of 0xD7FFF: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    cpu_addr = 32'h0009_FFFF;                          // -> 0xDFFFF, the area's end
    #1;
    if (!absent_area || mem_valid) begin
      $display("FAIL window-0 0x0C alias of 0xDFFFF: absent_area=%b mem_valid=%b",
               absent_area, mem_valid);
      errors = errors + 1;
    end
    // ...and the alias of the IDE work RAM at the top of the same window is
    // still RAM, not the absent area.
    cpu_addr = 32'h0009_A000;                          // -> 0xDA000
    #1;
    if (absent_area || !mem_valid) begin
      $display("FAIL window-0 0x0C alias of 0xDA000 captured by the absent area");
      errors = errors + 1;
    end
    ide_rom_enable = 0;
    check_addr(32'h0009_8000, 32'h000D_8000);

    // Values the firmware never writes, as measured (probes/WIN.TXT, /WIN):
    //   0461=0A rb=0B b=0800 a=5AA5 p=FF q=FF  -> both markers were missing
    //                                            from low RAM: on VRAM
    //   0461=10 rb=11 b=1234 a=5AA5 p=FF q=FF  -> above 1 MiB, and writable
    //   0461=41 rb=41 / =7F rb=7F              -> same, far above 1 MiB
    // The source page is (value & 0xFE): 0x10 and above reach above 1 MiB, and
    // bit 0 is not part of the page (the register never presents it, see
    // pc9821_iobus.sv's next_win0). This is QEMU's mem_apply_window rule
    // (pc98-mem.c:295) with the measured confirmation attached.
    win0_sel = 8'h0A;                                  // 0xA0000-0xBFFFF
    // A VRAM window in QEMU's sense: the window covers 0xA0000-0xBFFFF and the
    // graphics planes in it are the ones the core serves. The *low* 32 KiB is
    // NOT the TRAM/CG apertures: those are decoded on the guest address in the
    // subsystem, so this map hands 0xA0000-0xA4FFF straight to the backend
    // (guest RAM) instead of to the TRAM/CG bridges -- see the routing assertion
    // in tb_pc9821_memory_subsystem.sv. The machine's own window base under 0x0A
    // is not the flat 0xA0000 word either (b=0800, markers at no 64 KiB-aligned
    // address of the first MiB), and the 0x463 sweep in the same capture proves
    // 0xA0000's word is the text RAM's 0x0020, so what the machine shows there
    // is undetermined (an open question).
    check_addr(32'h0008_0000, 32'h000A_0000);          // -> RAM at 0xA0000, not TRAM
    check_gvram(32'h0008_8000, 32'h000A_8000, 2'd0, 15'h0000);  // == 0xA8000: B
    check_gvram(32'h0009_0000, 32'h000B_0000, 2'd1, 15'h0000);  // == 0xB0000: R
    check_gvram(32'h0009_8000, 32'h000B_8000, 2'd2, 15'h0000);  // == 0xB8000: G
    win0_sel = 8'h10;
    check_addr(32'h0008_0000, 32'h0010_0000);          // 1 MiB, above the window
    check_addr(32'h0009_FFFF, 32'h0011_FFFF);
    win0_sel = 8'h7E;
    check_addr(32'h0008_0000, 32'h007E_0000);          // the top of the range
    // 0x00 is page 0 by the same rule. The machine reads 0xFFFF at the window
    // base there and discards the store (`0461=00 rb=01 b=FFFF a=FFFF`), which
    // this map does NOT reproduce -- the mechanism is unknown and it is OPEN
    // (Q2 in the same report). The line below freezes the approved rule-(a)
    // arithmetic, not the machine's answer, and is here so the difference is
    // visible rather than silent.
    win0_sel = 8'h00;
    check_addr(32'h0008_0000, 32'h0000_0000);          // page 0

    // ---- the EMS window at 0xB0000-0xBFFFF (0x043F's 0x2 nibble) ------
    // The ITF's own test (BANK4@0xF8296-0xF8317) needs two things of this window:
    // the 0x22 store must DIFFER from the 0x20 state, and 0x22 must be 64 KiB of
    // writable RAM. 0x20 is the IDENTITY -- the state the BIOS's mode-set stub writes
    // (BANK7@0xD2A) and the ITF writes back (BANK4@0xF834D) -- so it must leave the
    // GVRAM plane window at 0xB0000 exactly as it was.
    win0_sel = 8'h08;
    // The page's backend base as pc9821_memory_subsystem computes it: pack_base + PACK_BYTES
    // + 0x48000, with pack_base the 32 MiB default here. The map reads only [31:20] and folds
    // the low half to that 0x48000 constant (tools/check_memmap_addr_equiv.py PREMISES proves
    // the subsystem formula and the map together), so the bench must drive the same shape.
    ems_page_base = 32'h0214_8000;
    ems_state = 2'd0;
    check_gvram(32'h000B_0000, 32'h000B_0000, 2'd1, 15'h0000);   // 0x20: the R plane
    ems_state = 2'd1;
    check_addr(32'h000B_0000, 32'h0214_8000);                    // 0x22: the page's first word
    check_addr(32'h000B_FFFC, 32'h0215_7FFC);                    // and its last: 64 KiB
    cpu_valid = 1; cpu_write = 0;
    #1;
    if (!mem_valid) begin
      $display("FAIL the 0x22 EMS page was not routed to the backend (mem_valid=0)");
      errors = errors + 1;
    end
    // The window is a FIRST-MiB aperture, as the plane windows are: an address above
    // 1 MiB whose low 20 bits look like the window must stay guest RAM, or the 0x22
    // state would swallow memory.
    check_addr(32'h002B_0000, 32'h002B_0000);
    // 0x24 is the machine's unmapped state (reads 0xFFFF, the store does not take):
    // the subsystem hands it to the registered open-bus responder, so this block must
    // neither claim it nor send it to the backend.
    ems_state = 2'd2;
    check_addr(32'h002B_0000, 32'h002B_0000);
    cpu_addr = 32'h000B_0000;
    #1;
    if (mem_valid || gvram_window) begin
      $display("FAIL the unmapped EMS state (0x24) reached the backend or the planes");
      errors = errors + 1;
    end
    cpu_valid = 0;
    ems_state = 2'd0;

    // A store into a window that has NO writable layer is rejected whatever the gate
    // says: the window's only backing is the pack (the firmware image), and a byte
    // written into the pack survives an OSD reset. NP2kai discards exactly these
    // stores (cpumem.c:135 memnc_wr8 is `(void)address; (void)value`, the handler on
    // both ROM windows: cpumem.c:225 memfn0.wr8[0xe8000>>15]/[0xf8000>>15], :269
    // mmaptbl bwr8), and qemu-pc98's 0xd8000 ide_rom is a plain ROM alias. Only the
    // 0xF8000-0xFFFFF window has a writable layer (the BIOS shadow), and THAT store
    // stays gated by 0x053D bit 1.
    //
    // The 0xF8000 window with the gate open: the shadow absorbs the store.
    win0_sel = 8'h0E;
    bios_ram_gate = 0;
    ide_rom_enable = 1;
    cpu_write = 1;
    cpu_addr = 32'h0009_8000;                          // -> the 0xF8000 window
    cpu_valid = 1;
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL 0xF8000 store not blocked with bios_ram_gate=0");
      errors = errors + 1;
    end
    bios_ram_gate = 1;
    #1;
    if (!mem_valid) begin
      $display("FAIL 0xF8000 store blocked with bios_ram_gate=1 (the shadow absorbs it)");
      errors = errors + 1;
    end
    // The option-ROM window (0xD8000-0xD9FFF) is ROM: 0x461 = 0x0C reaches it, and the
    // ITF's 8 KiB copy targets it (BANK4@0x0215) while 0x053D reads 0x10, i.e. bit 1
    // clear. Neither gate state may let a store reach the pack's option-ROM slot.
    win0_sel = 8'h0C;
    bios_ram_gate = 0;
    cpu_addr = 32'h0009_8000;                          // == the option-ROM window
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL option-ROM window store not blocked with bios_ram_gate=0");
      errors = errors + 1;
    end
    bios_ram_gate = 1;
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL option-ROM window store reached the pack with bios_ram_gate=1");
      errors = errors + 1;
    end
    // The 0xE8000-0xF7FFF lower BIOS is the same: window 0 = 0x0E puts
    // 0x88000-0x8FFFF on it, so the ITF's 64 KiB copy (ES=0x8800 <- DS=0xE800,
    // BANK4@0x01ED) targets the pack's banks 5/6. It is a self-copy (a no-op), but a
    // guest store there is a ROM store and must be dropped in BOTH gate states: the
    // ITF's second ROM-sum pass reads 0xE8000-0xF7FFF, and a byte landed there prints
    // ROM SUM ERROR on the next reset.
    ide_rom_enable = 0;
    win0_sel = 8'h0E;
    bios_ram_gate = 0;
    cpu_addr = 32'h000E_8000;                          // the flat address...
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL lower-BIOS store not blocked with bios_ram_gate=0");
      errors = errors + 1;
    end
    cpu_addr = 32'h0008_8000;                          // ...and through window 0
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL window-0 lower-BIOS store not blocked with bios_ram_gate=0");
      errors = errors + 1;
    end
    bios_ram_gate = 1;
    cpu_addr = 32'h000E_8000;
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL lower-BIOS store reached the pack with bios_ram_gate=1");
      errors = errors + 1;
    end
    cpu_addr = 32'h0008_8000;
    #1;
    if (!cpu_ready || mem_valid) begin
      $display("FAIL window-0 lower-BIOS store reached the pack with bios_ram_gate=1");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_write = 0;
    ide_rom_enable = 0;
    win0_sel = 8'h08;                                  // leave the map at identity
    check_addr(32'h0009_8000, 32'h0009_8000);

    // ---- The candidate-drive byte: the store and the read must meet --------
    // The IDE option ROM decides which channels to probe from the byte at physical
    // 0xF8E90 (BANK3@0x078E). The ITF stores it (BANK4@0x19D4) through ES=0x98E8 with
    // window 0 = 0x0E, i.e. CPU address 0x98E90, and the option ROM reads it back later
    // under the BIOS-top bank. THE WINDOW HAS TWO LAYERS: the selected pack bank
    // and a writable shadow in the SDRAM reserve above the pack. The gated STORE goes to
    // the SHADOW whatever bank is selected, and a READ serves the shadow only while it is
    // both enabled (0x043F's 0x8 nibble) and already written since reset. That second term
    // is the whole fix: the ITF sums the window TWICE per POST and the second pass runs
    // AFTER it writes 0x043F=0x80 (BANK4@0x1D0, then `jmp 0x18E` at 0x262), so a read that
    // served the shadow unconditionally would let the previous boot's stored byte fail the
    // sum on every arm of the reset. Both states are asserted here.
    bios_ram_gate = 1;
    win0_sel      = 8'h0E;
    top_bank      = 4'd8;                              // the ITF bank at the store
    cpu_addr      = 32'h0009_8E90;                     // ES=0x98E8, offset 0x10
    cpu_write     = 1;
    cpu_valid     = 1;
    #1;
    if (mem_addr !== (fw_shadow_base + 32'h0000_0E90)) begin
      $display("FAIL drive-byte store -> %08x, want %08x (the top-window shadow)",
               mem_addr, fw_shadow_base + 32'h0000_0E90);
      errors = errors + 1;
    end
    if (!fw_shadow_store) begin
      $display("FAIL a gated top-window store did not report fw_shadow_store");
      errors = errors + 1;
    end
    cpu_write = 0;
    // THE ROM SUM'S SECOND PASS: the shadow is enabled but nothing has been stored since
    // reset. This MUST read the pristine pack, not the shadow.
    top_shadow_en   = 1;
    fw_shadow_dirty = 0;
    top_bank        = 4'd9;
    cpu_addr        = 32'h000F_8E90;
    #1;
    if (mem_addr !== (pack_base + 32'h0002_0E90)) begin
      $display("FAIL shadow-enabled pre-store read -> %08x, want the pack's %08x",
               mem_addr, pack_base + 32'h0002_0E90);
      errors = errors + 1;
    end
    // The option ROM's read, after the store has landed (dirty) with the shadow enabled,
    // and whatever bank the map has selected: the shadow.
    fw_shadow_dirty = 1;
    #1;
    if (mem_addr !== (fw_shadow_base + 32'h0000_0E90)) begin
      $display("FAIL option-ROM drive-byte read -> %08x, want the shadow %08x",
               mem_addr, fw_shadow_base + 32'h0000_0E90);
      errors = errors + 1;
    end
    // With the shadow disabled a read follows the bank register again: the ITF must keep
    // executing its own image, and the sum's first pass must read the ROM.
    top_shadow_en = 0;
    top_bank      = 4'd8;
    #1;
    if (mem_addr !== (pack_base + 32'h0000_0E90)) begin
      $display("FAIL ITF-bank read -> %08x, want the ITF slot %08x",
               mem_addr, pack_base + 32'h0000_0E90);
      errors = errors + 1;
    end
    top_bank = 4'd9;
    #1;
    if (mem_addr !== (pack_base + 32'h0002_0E90)) begin
      $display("FAIL shadow-disabled BIOS-top read -> %08x, want the pack's %08x",
               mem_addr, pack_base + 32'h0002_0E90);
      errors = errors + 1;
    end

    // The shadow store's gate is still 0x053D bit 1: a store with it closed is discarded,
    // so a guest that has not opened the writable-BIOS gate cannot write the shadow -- and
    // must not report fw_shadow_store, which would flip the window's read source.
    bios_ram_gate = 0;
    cpu_valid     = 1;
    cpu_write     = 1;
    top_shadow_en = 1;
    cpu_addr      = 32'h000F_8E90;
    #1;
    if (!cpu_ready || mem_valid || fw_shadow_store) begin
      $display("FAIL gate-closed shadow store not blocked (valid=%b store=%b)",
               mem_valid, fw_shadow_store);
      errors = errors + 1;
    end
    cpu_valid     = 0;
    cpu_write     = 0;
    top_shadow_en = 0;
    win0_sel      = 8'h08;
    top_bank      = 4'd8;
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_MEMORY_MAP: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_MEMORY_MAP: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_MEMORY_MAP: TIMEOUT");
  end

endmodule
