// PC-9821 text VRAM (TRAM) and the machine's hardware memory switches.
//
// Extracted from pc9821_crtc (graphics end-state step 3, piece 1). The CRTC owns the
// 24 kHz raster, the text GDC1 model and the text-cell render; the text MEMORY and the
// memory-switch policy are not its job, so they own themselves here.
//
// One clk (clk_sys; clk_vid is the same net at the top level). Port A is the CPU (the
// iobus bridge's TRAM window, gated and seeded by the switches below); port B is the
// text scanout / row-cache walker's read.
//
// THE HARDWARE MEMORY SWITCHES live in this memory's own tail: eight cells at
// 0xA3FE2 + i*4 (NP2kai bios/biosmem.h MEMB_MSW1..8), battery-backed configuration the
// authentic ITF validates. The guest may overwrite them through the normal TRAM window
// when MODE FF1 bit 6 is set (SETUP does); the OSD supplies the power-up value and the
// 0xA3FEA base-memory code is fixed at 640 KB. See the block below for the reference
// readings and the one stated divergence.

`default_nettype none

module pc9821_text_mem (
    input  wire        clk,
    input  wire        rst_n,

    // Port A: the CPU (pc9821_iobus's TRAM bridge), gated and seeded by the switches.
    input  wire [13:0] cpu_addr,
    input  wire  [7:0] cpu_din,
    input  wire        cpu_we,
    output wire  [7:0] cpu_dout,

    // Port B: the text scanout / row-cache walker's read (enabled on the dot clock).
    input  wire        pixel_ce,
    input  wire [13:0] vid_addr,
    output wire  [7:0] vid_q,

    // The memory switches.
    input  wire        mode1_bit6,      // MODE FF1 bit 6: writes to the switch cells enabled
    input  wire  [2:0] cfg_fdd_mode     // the OSD's sample switch position
);

  // The machine's memory switches: eight cells at 0xA3FE2 + i*4 in the text-VRAM tail
  // (NP2kai bios/biosmem.h MEMB_MSW1..8) - battery-backed configuration the authentic ITF
  // validates, stopping on its "SET THE SOFTWARE DIP-SWITCH" screen when missing. These
  // are the values the real PC-9821Xe10 reported (tools/hwprobe;
  // docs/probes/). The guest may overwrite them through the normal VRAM
  // window (SETUP does): a power-up state, not a constant.
  // Write-protected until MODE FF1 bit 6 is set (0x68 = 0x0D on, 0x0C off), which the ITF
  // and the BIOS both bracket their switch writes with (BANK4@0x1D1B). Without the gate
  // the guest's attribute fill overwrites them with its fill attribute 0xE1, and memory
  // switch 3 bit 6 picks the BIOS console colour (BIOS.ROM @0x226F-0x2287) - so the
  // BIOS/BASIC screen turns green where the machine shows white.
  wire tram_msw_cell   = (cpu_addr[1:0] == 2'b10) &&
                         (cpu_addr[13:2] >= 12'hFF8);
  wire cpu_we_ok  = cpu_we && !(tram_msw_cell && !mode1_bit6);

  // ---- THE RESET SEED FOR THE TWO SWITCH CELLS ----------------------------------------
  //
  // The machine's hardware switches are READ by the firmware and written by nothing. Every
  // read of 0xA3FF2 in the dump masks the field (BANK7@0x5991 `mov ah,[es:0x3ff2] / and
  // ah,0xF0`), and every read of 0xA3FEA masks bits 2:0 (BANK4@0x5C3C `mov al,[es:0x3fea]
  // / and al,7 / inc al / shl al,1` = the base memory in 64 KB units, the same decode as
  // NP2kai generic/np2info.c:113-120 and its bios.c:236 BIOS_FLAG1 fill); the ONLY writes to
  // either cell in the whole ROM set are BANK0@0x1208 `and byte [es:0x3ff2],0x0F` and the
  // ITF's own `or byte es:[0x3FEA],8` marker (BANK4@0x1D15) - both outside the fields above,
  // which is why the two masks below keep their bits. The 0xA3FF2 nibble cannot be moved by
  // the guest, so the core seeds it from the OSD at reset; the 0xA3FEA base-memory code is
  // FIXED at 640 KB (MSW_BASEM_CODE) because the machine has no way to change it.
  //
  // WHY A RESET-TIME WRITE AND NOT A READ-SIDE OVERRIDE. The cells are plain write-through
  // VRAM (tram_msw_cell above is only a MODE FF1 bit 6 gate), and on the machine a guest can
  // still store into them: overriding the read would make the OSD value unclobberable, which
  // is more than a switch is. Writing the cell at each machine reset keeps the machine's own
  // semantics - battery-backed content, guest-writable - while making the OSD the
  // power-up source of truth. THE TRADE, stated: a guest's own write to the two cells no
  // longer survives a machine reset (it did not survive a power cycle on the machine
  // either), and the ITF's SETUP still reaches them while the guest runs.
  //
  // THE BYTES. Each seed byte is the INIT_BYTES byte with ONLY the switch field replaced, so
  // entry 0 rewrites the literal's own value (0x01 -> 0x01, 0x0C -> 0x0C) and a card with no
  // config file gets exactly the INIT_BYTES image. The masks are the firmware's
  // own: 0x0F for 0xA3FF2 (the low nibble is a second field BANK0@0x1208 preserves) and 0xF8
  // for 0xA3FEA (bit 3 is the ITF's marker, bits 7:4 the cell's other bits).
  //
  // THE WALK runs while the machine-reset strobe is HELD and for at most one cycle after it,
  // so in every real boot (the strobe is held for the whole pack load) both cells are written
  // many times over before cpu_run rises. A one-cycle strobe would still finish, one cycle
  // into the guest's first fetch - the CPU cannot reach 0xA3FEA in that window (its reset
  // vector fetch alone is a multi-cycle memory read), and the data it would displace is the
  // seed's own, i.e. the same bytes the INIT put there.
  localparam [13:0] MSW_FDD_ADDR    = 14'h3FF2;   // memsw[4]: high nibble = the boot/FDD mode
  localparam [13:0] MSW_BASEM_ADDR  = 14'h3FEA;   // memsw[2]: bits 2:0 = the base memory
  localparam  [7:0] MSW_FDD_INIT    = 8'h01;      // the INIT_BYTES byte at 0xA3FF2
  localparam  [7:0] MSW_BASEM_INIT  = 8'h0C;      // the INIT_BYTES byte at 0xA3FEA
  localparam  [2:0] MSW_BASEM_CODE  = 3'd4;       // 640 KB, fixed: the machine cannot change it

  // ---- POSITION -> SWITCH FIELD, one place, held to CONF_STR by check_osd_contract ----
  //
  // O[42:40],Boot order,Auto,640K,1M,MO,SASI1,SASI2,SCSI - the 0xA3FF2 high nibble, the
  // BOOT/FDD nibble NP2kai reads twice: as the FDD equip-size class (bios.c:254
  // `boot = mem[MEMB_MSW5] & 0xf0`, `!= 0x20` = 1 MB, 0x20 = 640 KB) and as a BOOT-DEVICE
  // selector in its BIOS's bootstrap loader (bios1b.c:883-926 `switch (mem[MEMB_MSW5] &
  // 0xf0)`: 0x00 "normal", 0x20 "640KB FDD", 0x40 "1.2MB FDD", 0x60 "MO", 0xa0 "SASI 1",
  // 0xb0 "SASI 2", 0xc0 "SCSI", default = ROM). POSITIONS 0..2 KEEP THEIR EXACT MEANING from
  // the three-value list (the same nibbles 0x0/0x2/0x4, the same labels): 0x0 is the
  // MEASURED board's nibble and the ITF's own `jz` keep class (BANK7@0x5999), 0x2 is the
  // 0x20 the ITF's boot helper compares against at BANK7@0x599B (its 640 KB arm), 0x4 the
  // 0x40 of BANK7@0x59A0 (its 1.2 MB arm). POSITIONS 3..6 APPEND NP2kai's four boot-device
  // codes 0x60/0xa0/0xb0/0xc0 (bios1b.c:903/906/910/914). The SETUP's own four-value list
  // for the FDD item is 640K / 1M / 自動（６４０Ｋ）/ 自動（１Ｍ） (BANK3@0x4A21-0x4A43); the
  // two 自動 variants differ in a bit the firmware's decode does not distinguish (its one
  // `jz` class), so position 0 is that class and is the MEASURED machine's nibble.
  //
  // THE DIVERGENCE, STATED ONCE AND LOUDLY. The real Xe10 firmware does NOT use this nibble
  // to choose a boot device: its boot helper compares only 0x20/0x40 and KEEPS the FDC's own
  // reported mode for every other value (BANK7@0x599B-0x59A3 `cmp ah,0x20 / jz` / `cmp ah,0x40
  // / jnz keep`), its SETUP's own item for the nibble is フロッピィディスクモード - FDD MODE -
  // with the four values 640K/1M/自動（６４０Ｋ）/自動（１Ｍ） (BANK3@0x4a07-0x4b51), and the
  // whole ROM set reads the cell in exactly two places (that boot helper and the
  // switch-picture render at BANK7@0x7F80). NP2kai's own comment on its switch admits the
  // reading is a stand-in: bios1b.c:883 `うぐぅ…本当はALレジスタの値から` ("it should really be
  // from the AL register value") - on real hardware the caller passes the boot DEVICE in
  // AL/AH (bios1b.c:843-875: codes 0x01-0x04 FDD, 0x0A/0x0B/0x0C HDD1/HDD2/SCSI). So on the
  // machine positions 3..6 land in the same "keep the controller's FDD mode" class as
  // position 0 and change no boot decision; they are offered because they are the primary
  // software reference's legal switch positions, carrying its names, NOT because a captured
  // Xe10 boots MO/SASI/SCSI from them. Whether the machine has ANY boot-order encoding is
  // capture-pending (the SETUP item->cell map, todo item 99).
  //
  // 0xA3FEA[2:0] is the BASE (CONVENTIONAL) MEMORY and it is HARDCODED to 640 KB, not a
  // knob: the size is (code + 1) * 128 KB (NP2kai generic/np2info.c:113-120; the ITF's own
  // count at BANK4@0x5C3C is the same field in 64 KB units, `and al,7 / inc al / shl al,1`),
  // so code 4 = 640 KB = the measured byte 0x0C. The real Xe10 has NO SETUP/DIP option that
  // changes the conventional memory size - its SETUP menu carries no such item, and NP2kai takes the value from
  // the memory-switch cell rather than from a guest setting - so there is no OSD field for it
  // and the code is the MSW_BASEM_CODE localparam. The 0xA3FEA seed keeps bit 3
  // (the ITF's own marker) and bits 7:4 via the mask in msw_base_byte below.
  reg [3:0] msw_fdd_nib;
  always @* begin
    case (cfg_fdd_mode)
      3'd0:    msw_fdd_nib = 4'd0;   // entry 0 -> nibble 0x0, the MEASURED board <-- the DEFAULT
      3'd1:    msw_fdd_nib = 4'd2;   // entry 1 -> nibble 0x20 (NP2kai bios.c:254's 640 KB case)
      3'd2:    msw_fdd_nib = 4'd4;   // entry 2 -> nibble 0x40 (the 1 MB case)
      3'd3:    msw_fdd_nib = 4'd6;   // entry 3 -> nibble 0x60 (NP2kai bios1b.c:903, "MO")
      3'd4:    msw_fdd_nib = 4'd10;  // entry 4 -> nibble 0xa0 (bios1b.c:906, "SASI 1")
      3'd5:    msw_fdd_nib = 4'd11;  // entry 5 -> nibble 0xb0 (bios1b.c:910, "SASI 2")
      3'd6:    msw_fdd_nib = 4'd12;  // entry 6 -> nibble 0xc0 (bios1b.c:914, "SCSI")
      3'd7:    msw_fdd_nib = 4'd0;   // no such option; the measured machine
      default: msw_fdd_nib = 4'd0;   // unreachable, and the captured machine if it ever were
    endcase
  end

  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg [3:0] msw_fdd_eff  = 4'h0;                 // entry 0: the measured 0x00 nibble
  reg       msw_seed_en  = 1'b0;
  reg       msw_seed_sel = 1'b0;                 // 0 = the 0xA3FF2 cell, 1 = the 0xA3FEA one
  /* verilator lint_on PROCASSINIT */

  always @(posedge clk) begin
    if (!rst_n) begin
      msw_fdd_eff  <= msw_fdd_nib;
      // Both cells are rewritten on alternate cycles for as long as the strobe is held, so
      // the value is already in the array before the guest's first access.
      msw_seed_en  <= 1'b1;
      msw_seed_sel <= ~msw_seed_sel;
    end else if (msw_seed_en) begin
      if (msw_seed_sel) msw_seed_en <= 1'b0;
      msw_seed_sel <= ~msw_seed_sel;
    end
  end

  wire [7:0] msw_fdd_byte  = (MSW_FDD_INIT   & 8'h0F) | {msw_fdd_eff, 4'h0};
  wire [7:0] msw_base_byte = (MSW_BASEM_INIT & 8'hF8) | {5'b0, MSW_BASEM_CODE};
  // THE PORT-A MUX: the seed owns the CPU port while it runs, and the guest owns it otherwise.
  // Losing a guest write to the seed's post-release cycle is the case the walk comment above
  // prices out.
  wire [13:0] tram_a_addr = msw_seed_en ? (msw_seed_sel ? MSW_BASEM_ADDR : MSW_FDD_ADDR)
                                        : cpu_addr;
  wire  [7:0] tram_a_data = msw_seed_en ? (msw_seed_sel ? msw_base_byte : msw_fdd_byte)
                                        : cpu_din;
  wire        tram_a_we   = msw_seed_en ? 1'b1 : cpu_we_ok;
  pc9821_dpram #(
      .AW(14),
      .DW(8),
      .INIT_EN(1'b1),
      // The full 32-byte tail, byte for byte as the real PC-9821Xe10 reported it
      // (tools/hwprobe): eight cells of {attribute, 0xFF, switch, 0xFF} at 0xA3FE2 + i*4
      // holding 48 05 0C 00 01 00 00 81. 0xA3FE0 is seeded 0x00 (the machine's 0xE1 there is
      // a post-DOS value). 0xA3FF6 is the keyboard-LED cell, not a switch.
      .INIT_BYTES(256'hff81_ffe1_ff00_ffe1_ff00_ffe1_ff01_ffe1_ff00_ffe1_ff0c_ffe1_ff05_ffe1_ff48_ff00),
      .INIT_LEN(32),
      .INIT_OFFSET(14'h3FE0)
  ) u_tram (
      .clock_a(clk),
      .address_a(tram_a_addr),
      .data_a(tram_a_data),
      .wren_a(tram_a_we),
      .q_a(cpu_dout),
      .clock_b(clk),
      .en_b(pixel_ce),
      .address_b(vid_addr),
      .data_b(8'h00),
      .wren_b(1'b0),
      .q_b(vid_q)
  );


endmodule

`default_nettype wire
